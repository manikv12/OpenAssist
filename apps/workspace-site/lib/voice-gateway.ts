import { env } from 'cloudflare:workers';
import { opaqueUserHash, randomBase64Url, signVoiceGatewayToken } from './security';
import { publicOrigin, requiredSecret } from './server-auth';

export async function callVoiceGateway(
  request: Request,
  userId: string,
  path: string,
  init: RequestInit = {},
): Promise<Response> {
  if (!env.VOICE_GATEWAY_URL) {
    return new Response(JSON.stringify({ status: 'unavailable', message: 'Voice is temporarily unavailable until the subscription realtime canary passes.' }), {
      status: 503,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    });
  }
  const origin = publicOrigin(request);
  const token = await signVoiceGatewayToken({
    version: 1,
    purpose: 'voice_gateway',
    userHash: await opaqueUserHash(userId),
    origin,
    issuedAt: Date.now(),
    expiresAt: Date.now() + 60_000,
    nonce: randomBase64Url(),
  }, requiredSecret('VOICE_GATEWAY_SHARED_SECRET'));
  const headers = new Headers(init.headers);
  headers.set('authorization', `Bearer ${token}`);
  if (init.body) headers.set('content-type', 'application/json');
  return fetch(`${env.VOICE_GATEWAY_URL.replace(/\/$/, '')}${path}`, { ...init, headers });
}

export async function voiceAuthPointer(userId: string): Promise<string> {
  return `chatgpt-auth/${await opaqueUserHash(userId)}.enc`;
}
