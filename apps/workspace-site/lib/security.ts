const encoder = new TextEncoder();
const decoder = new TextDecoder();

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function base64UrlToBytes(value: string): Uint8Array {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function timingSafeEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left[index] ^ right[index];
  return difference === 0;
}

async function derivedAesKey(secret: string): Promise<CryptoKey> {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(secret));
  return crypto.subtle.importKey('raw', digest, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
}

export async function encryptSecret(value: string, secret: string): Promise<string> {
  if (secret.length < 24) throw new Error('The token encryption secret is not configured securely.');
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await derivedAesKey(secret), encoder.encode(value));
  return `v1.${bytesToBase64Url(iv)}.${bytesToBase64Url(new Uint8Array(ciphertext))}`;
}

export async function decryptSecret(value: string, secret: string): Promise<string> {
  const [version, encodedIv, encodedCiphertext] = value.split('.');
  if (version !== 'v1' || !encodedIv || !encodedCiphertext) throw new Error('Encrypted value is invalid.');
  const iv = new Uint8Array(base64UrlToBytes(encodedIv));
  const ciphertext = new Uint8Array(base64UrlToBytes(encodedCiphertext));
  const plaintext = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv },
    await derivedAesKey(secret),
    ciphertext,
  );
  return decoder.decode(plaintext);
}

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .filter(([, item]) => item !== undefined)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, item]) => [key, canonicalize(item)]),
    );
  }
  return value;
}

export function canonicalJson(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}

export async function sha256(value: unknown): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(canonicalJson(value)));
  return bytesToBase64Url(new Uint8Array(digest));
}

async function hmac(value: string, secret: string): Promise<Uint8Array> {
  if (secret.length < 24) throw new Error('The action signing secret is not configured securely.');
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode(value)));
}

export async function constantTimeTextEqual(left: string, right: string): Promise<boolean> {
  const [leftDigest, rightDigest] = await Promise.all([
    crypto.subtle.digest('SHA-256', encoder.encode(left)),
    crypto.subtle.digest('SHA-256', encoder.encode(right)),
  ]);
  return timingSafeEqual(new Uint8Array(leftDigest), new Uint8Array(rightDigest));
}

export type VoiceGatewayTokenPayload = {
  version: 1;
  purpose: 'voice_gateway';
  access: 'owner' | 'demo';
  userHash: string;
  origin: string;
  issuedAt: number;
  expiresAt: number;
  nonce: string;
};

export async function signVoiceGatewayToken(payload: VoiceGatewayTokenPayload, secret: string): Promise<string> {
  const encodedPayload = bytesToBase64Url(encoder.encode(canonicalJson(payload)));
  return `${encodedPayload}.${bytesToBase64Url(await hmac(encodedPayload, secret))}`;
}

export async function opaqueUserHash(userId: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(userId));
  return bytesToBase64Url(new Uint8Array(digest));
}

export type ActionPreviewPayload = {
  version: 1;
  previewId: string;
  userId: string;
  tool: string;
  argsHash: string;
  nonce: string;
  issuedAt: number;
  expiresAt: number;
  destructive: boolean;
};

export type DemoSessionTokenPayload = {
  version: 1;
  purpose: 'demo_workspace';
  workspaceId: string;
  nonce: string;
  issuedAt: number;
  expiresAt: number;
};

export type JudgeAccessTokenPayload = {
  version: 1;
  purpose: 'judge_access';
  sessionId: string;
  credentialRevision: string;
  issuedAt: number;
  expiresAt: number;
};

export async function signJudgeAccessToken(payload: JudgeAccessTokenPayload, secret: string): Promise<string> {
  const encodedPayload = bytesToBase64Url(encoder.encode(canonicalJson(payload)));
  const signature = await hmac(encodedPayload, secret);
  return `${encodedPayload}.${bytesToBase64Url(signature)}`;
}

export async function verifyJudgeAccessToken(token: string, secret: string): Promise<JudgeAccessTokenPayload> {
  const [encodedPayload, encodedSignature] = token.split('.');
  if (!encodedPayload || !encodedSignature) throw new Error('Judge access session is invalid.');
  const expected = await hmac(encodedPayload, secret);
  if (!timingSafeEqual(expected, base64UrlToBytes(encodedSignature))) throw new Error('Judge access session is invalid.');
  const payload = JSON.parse(decoder.decode(base64UrlToBytes(encodedPayload))) as JudgeAccessTokenPayload;
  if (
    payload.version !== 1 ||
    payload.purpose !== 'judge_access' ||
    !payload.sessionId ||
    !payload.credentialRevision ||
    !Number.isFinite(payload.issuedAt) ||
    !Number.isFinite(payload.expiresAt)
  ) {
    throw new Error('Judge access session is invalid.');
  }
  return payload;
}

export async function signDemoSessionToken(payload: DemoSessionTokenPayload, secret: string): Promise<string> {
  const encodedPayload = bytesToBase64Url(encoder.encode(canonicalJson(payload)));
  const signature = await hmac(encodedPayload, secret);
  return `${encodedPayload}.${bytesToBase64Url(signature)}`;
}

export async function verifyDemoSessionToken(token: string, secret: string): Promise<DemoSessionTokenPayload> {
  const [encodedPayload, encodedSignature] = token.split('.');
  if (!encodedPayload || !encodedSignature) throw new Error('Demo session is invalid.');
  const expected = await hmac(encodedPayload, secret);
  if (!timingSafeEqual(expected, base64UrlToBytes(encodedSignature))) throw new Error('Demo session is invalid.');
  const payload = JSON.parse(decoder.decode(base64UrlToBytes(encodedPayload))) as DemoSessionTokenPayload;
  if (
    payload.version !== 1 ||
    payload.purpose !== 'demo_workspace' ||
    !payload.workspaceId ||
    !payload.nonce ||
    !Number.isFinite(payload.issuedAt) ||
    !Number.isFinite(payload.expiresAt)
  ) {
    throw new Error('Demo session is invalid.');
  }
  return payload;
}

export async function signActionPreview(payload: ActionPreviewPayload, secret: string): Promise<string> {
  const encodedPayload = bytesToBase64Url(encoder.encode(canonicalJson(payload)));
  const signature = await hmac(encodedPayload, secret);
  return `${encodedPayload}.${bytesToBase64Url(signature)}`;
}

export async function verifyActionPreview(token: string, secret: string): Promise<ActionPreviewPayload> {
  const [encodedPayload, encodedSignature] = token.split('.');
  if (!encodedPayload || !encodedSignature) throw new Error('Approval preview is invalid.');
  const expected = await hmac(encodedPayload, secret);
  if (!timingSafeEqual(expected, base64UrlToBytes(encodedSignature))) throw new Error('Approval preview was changed.');
  const payload = JSON.parse(decoder.decode(base64UrlToBytes(encodedPayload))) as ActionPreviewPayload;
  if (payload.version !== 1 || !payload.previewId || !payload.userId || !payload.tool || !payload.argsHash) {
    throw new Error('Approval preview is invalid.');
  }
  return payload;
}

export function randomBase64Url(bytes = 32): string {
  return bytesToBase64Url(crypto.getRandomValues(new Uint8Array(bytes)));
}

export async function pkceChallenge(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(verifier));
  return bytesToBase64Url(new Uint8Array(digest));
}
