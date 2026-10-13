const encoder = new TextEncoder();
const decoder = new TextDecoder();

function toBase64Url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function fromBase64Url(value: string): Uint8Array {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}

function equal(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left[index] ^ right[index];
  return difference === 0;
}

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .filter(([, item]) => item !== undefined)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, item]) => [key, canonical(item)]),
    );
  }
  return value;
}

async function hmac(value: string, secret: string): Promise<Uint8Array> {
  if (secret.length < 32) throw new Error('Voice gateway signing is not configured securely.');
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode(value)));
}

export type GatewayToken = {
  version: 1;
  purpose: 'voice_gateway' | 'voice_tool_socket';
  access: 'owner' | 'demo';
  userHash: string;
  origin: string;
  issuedAt: number;
  expiresAt: number;
  nonce: string;
  sessionId?: string;
};

export async function signGatewayToken(payload: GatewayToken, secret: string): Promise<string> {
  const encoded = toBase64Url(encoder.encode(JSON.stringify(canonical(payload))));
  return `${encoded}.${toBase64Url(await hmac(encoded, secret))}`;
}

export async function verifyGatewayToken(
  token: string,
  secret: string,
  expectedPurpose: GatewayToken['purpose'],
  expectedOrigin: string,
): Promise<GatewayToken> {
  const [encoded, signature] = token.split('.');
  if (!encoded || !signature || !equal(await hmac(encoded, secret), fromBase64Url(signature))) {
    throw new Response('Voice authorization is invalid.', { status: 401 });
  }
  let payload: GatewayToken;
  try {
    payload = JSON.parse(decoder.decode(fromBase64Url(encoded))) as GatewayToken;
  } catch {
    throw new Response('Voice authorization is invalid.', { status: 401 });
  }
  if (
    payload.version !== 1
    || payload.purpose !== expectedPurpose
    || (payload.access !== 'owner' && payload.access !== 'demo')
    || payload.origin !== expectedOrigin
    || !payload.userHash
    || !payload.nonce
    || payload.issuedAt > Date.now() + 30_000
    || payload.expiresAt < Date.now()
  ) {
    throw new Response('Voice authorization expired or is invalid.', { status: 401 });
  }
  return payload;
}

async function encryptionKey(secret: string): Promise<CryptoKey> {
  if (secret.length < 32) throw new Error('Voice authentication encryption is not configured securely.');
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(secret));
  return crypto.subtle.importKey('raw', digest, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
}

export async function encryptAuth(plaintext: string, secret: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv },
    await encryptionKey(secret),
    encoder.encode(plaintext),
  );
  return `v1.${toBase64Url(iv)}.${toBase64Url(new Uint8Array(ciphertext))}`;
}

export async function decryptAuth(value: string, secret: string): Promise<string> {
  const [version, encodedIv, encodedCiphertext] = value.split('.');
  if (version !== 'v1' || !encodedIv || !encodedCiphertext) throw new Error('Saved voice authentication is invalid.');
  const iv = Uint8Array.from(fromBase64Url(encodedIv));
  const ciphertext = Uint8Array.from(fromBase64Url(encodedCiphertext));
  const plaintext = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv },
    await encryptionKey(secret),
    ciphertext,
  );
  return decoder.decode(plaintext);
}

export async function digestUserId(userId: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(userId));
  return toBase64Url(new Uint8Array(digest));
}

export function randomToken(bytes = 24): string {
  return toBase64Url(crypto.getRandomValues(new Uint8Array(bytes)));
}
