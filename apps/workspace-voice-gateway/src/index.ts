import { Container } from '@cloudflare/containers';
import {
  decryptAuth,
  encryptAuth,
  randomToken,
  signGatewayToken,
  verifyGatewayToken,
  type GatewayToken,
} from './security';

interface Env {
  VOICE_CONTAINER: DurableObjectNamespace<VoiceContainer>;
  VOICE_AUTH: R2Bucket;
  VOICE_GATEWAY_SHARED_SECRET: string;
  VOICE_AUTH_ENCRYPTION_KEY: string;
  CONTAINER_INTERNAL_TOKEN: string;
  SITE_ORIGIN: string;
  CODEX_RUNTIME_VERSION: string;
}

const AUTH_LIMIT = 256_000;
const SDP_LIMIT = 300_000;
const THREAD_STATE_LIMIT = 24_000_000;

export class VoiceContainer extends Container<Env> {
  defaultPort = 8080;
  requiredPorts = [8080];
  sleepAfter = '15m';
  // Codex subscription sign-in and realtime both require outbound HTTPS.
  // Cloudflare Containers currently exposes this as an all-or-nothing switch;
  // the runtime itself still exposes no shell, files, computer, or API-key tools.
  enableInternet = true;
  pingEndpoint = '/health';
  envVars: Record<string, string> = {
    CONTAINER_INTERNAL_TOKEN: this.env.CONTAINER_INTERNAL_TOKEN,
    CODEX_RUNTIME_VERSION: this.env.CODEX_RUNTIME_VERSION,
  };

  async bindThreadOwner(userHash: string): Promise<void> {
    if (!/^[A-Za-z0-9_-]{32,128}$/.test(userHash)) throw new Error('Voice owner identity is invalid.');
    await this.ctx.storage.put('threadOwnerHash', userHash);
  }

  async checkpointThreadState(): Promise<void> {
    const userHash = await this.ctx.storage.get<string>('threadOwnerHash');
    if (!userHash) return;
    const response = await this.containerFetch('http://container/threads/export', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-openassist-container-token': this.env.CONTAINER_INTERNAL_TOKEN,
      },
      body: '{}',
    });
    if (!response.ok) throw new Error('Voice conversation checkpoint failed.');
    const result = await response.json() as { snapshot?: unknown };
    await saveEncryptedThreadState(this.env, userHash, result.snapshot);
  }

  override async onActivityExpired(): Promise<void> {
    try {
      await this.checkpointThreadState();
    } finally {
      await this.stop();
    }
  }
}

function json(value: unknown, init: ResponseInit = {}): Response {
  const headers = new Headers(init.headers);
  headers.set('content-type', 'application/json; charset=utf-8');
  headers.set('cache-control', 'no-store');
  headers.set('x-content-type-options', 'nosniff');
  return new Response(JSON.stringify(value), { ...init, headers });
}

async function readJson(request: Request, limit = 32_000): Promise<Record<string, unknown>> {
  const declared = Number(request.headers.get('content-length') ?? 0);
  if (declared > limit) throw new Response('Request is too large.', { status: 413 });
  const text = await request.text();
  if (text.length > limit) throw new Response('Request is too large.', { status: 413 });
  let parsed: unknown;
  try {
    parsed = JSON.parse(text || '{}');
  } catch {
    throw new Response('Request must be valid JSON.', { status: 400 });
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Response('Request must be a JSON object.', { status: 400 });
  }
  return parsed as Record<string, unknown>;
}

function bearer(request: Request): string {
  const value = request.headers.get('authorization') ?? '';
  if (!value.startsWith('Bearer ')) throw new Response('Voice authorization is required.', { status: 401 });
  return value.slice(7).trim();
}

function ownerContainer(env: Env) {
  return env.VOICE_CONTAINER.get(env.VOICE_CONTAINER.idFromName('openassist-owner-voice'));
}

async function containerJson(
  container: ReturnType<typeof ownerContainer>,
  env: Env,
  path: string,
  body?: unknown,
): Promise<Record<string, unknown>> {
  const response = await container.fetch(`http://container${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: {
      'content-type': 'application/json',
      'x-openassist-container-token': env.CONTAINER_INTERNAL_TOKEN,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const responseText = await response.text();
  let result: Record<string, unknown> = {};
  try {
    const parsed: unknown = JSON.parse(responseText || '{}');
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) result = parsed as Record<string, unknown>;
  } catch {
    // Platform startup failures may not return JSON. Never echo their raw body.
  }
  if (!response.ok) {
    const safePlatformMessage = /^(Failed to start container:|Error proxying request to container:|Container suddenly disconnected)/.test(responseText)
      ? responseText.slice(0, 500)
      : '';
    const message = typeof result.message === 'string'
      ? result.message
      : typeof result.error === 'string'
        ? result.error
        : safePlatformMessage || `The subscription voice container returned HTTP ${response.status}.`;
    throw new Response(message, { status: response.status });
  }
  return result;
}

function authObjectKey(userHash: string): string {
  return `chatgpt-auth/${userHash}.enc`;
}

function threadStateObjectKey(userHash: string): string {
  return `codex-thread-state/${userHash}.enc`;
}

async function saveEncryptedAuth(env: Env, objectKey: string, authJson: unknown): Promise<void> {
  if (typeof authJson !== 'string' || authJson.length > AUTH_LIMIT) {
    throw new Response('ChatGPT sign-in data is unexpectedly large.', { status: 400 });
  }
  JSON.parse(authJson);
  const encrypted = await encryptAuth(authJson, env.VOICE_AUTH_ENCRYPTION_KEY);
  await env.VOICE_AUTH.put(objectKey, encrypted, {
    httpMetadata: { contentType: 'application/octet-stream' },
    customMetadata: { version: '1' },
  });
}

async function saveEncryptedThreadState(env: Env, userHash: string, snapshot: unknown): Promise<void> {
  if (typeof snapshot !== 'string' || snapshot.length > THREAD_STATE_LIMIT || !snapshot.startsWith('v1.')) {
    throw new Response('Voice conversation checkpoint is invalid.', { status: 400 });
  }
  const encrypted = await encryptAuth(snapshot, env.VOICE_AUTH_ENCRYPTION_KEY);
  await env.VOICE_AUTH.put(threadStateObjectKey(userHash), encrypted, {
    httpMetadata: { contentType: 'application/octet-stream' },
    customMetadata: { version: '1', kind: 'codex-thread-state' },
  });
}

async function restoreThreadState(container: ReturnType<typeof ownerContainer>, env: Env, userHash: string): Promise<void> {
  const saved = await env.VOICE_AUTH.get(threadStateObjectKey(userHash));
  const snapshot = saved ? await decryptAuth(await saved.text(), env.VOICE_AUTH_ENCRYPTION_KEY) : null;
  if (snapshot && snapshot.length > THREAD_STATE_LIMIT) throw new Response('Saved voice conversation history is invalid.', { status: 400 });
  await containerJson(container, env, '/threads/restore', { snapshot });
}

async function checkpointThreadState(container: ReturnType<typeof ownerContainer>, env: Env, userHash: string): Promise<boolean> {
  const state = await container.getState().catch(() => ({ status: 'stopped' as const, lastChange: 0 }));
  if (state.status !== 'running' && state.status !== 'healthy') return false;
  const result = await containerJson(container, env, '/threads/export', {});
  await saveEncryptedThreadState(env, userHash, result.snapshot);
  return true;
}

async function requireSiteToken(request: Request, env: Env): Promise<GatewayToken> {
  return verifyGatewayToken(bearer(request), env.VOICE_GATEWAY_SHARED_SECRET, 'voice_gateway', new URL(env.SITE_ORIGIN).origin);
}

async function handleAuthorized(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const sessionMatch = url.pathname.match(/^\/tools\/([A-Za-z0-9_-]{8,128})$/);
  if (sessionMatch) {
    const origin = request.headers.get('origin') ?? '';
    if (origin !== new URL(env.SITE_ORIGIN).origin || request.headers.get('upgrade')?.toLowerCase() !== 'websocket') {
      throw new Response('Voice tool connection is not allowed.', { status: 403 });
    }
    const protocols = (request.headers.get('sec-websocket-protocol') ?? '')
      .split(',')
      .map((protocol) => protocol.trim());
    const tokenProtocol = protocols.find((protocol) => protocol.startsWith('openassist-token.')) ?? '';
    const token = tokenProtocol.slice('openassist-token.'.length);
    const payload = await verifyGatewayToken(token, env.VOICE_GATEWAY_SHARED_SECRET, 'voice_tool_socket', origin);
    if (payload.sessionId !== sessionMatch[1]) throw new Response('Voice tool session is invalid.', { status: 401 });
    const headers = new Headers(request.headers);
    headers.set('x-openassist-container-token', env.CONTAINER_INTERNAL_TOKEN);
    headers.set('sec-websocket-protocol', 'openassist-tools');
    const internal = new Request(`http://container/session/${encodeURIComponent(sessionMatch[1])}/tools`, {
      method: 'GET',
      headers,
    });
    return ownerContainer(env).fetch(internal);
  }

  const payload = await requireSiteToken(request, env);
  const container = ownerContainer(env);
  const objectKey = authObjectKey(payload.userHash);
  await container.bindThreadOwner(payload.userHash);

  if (request.method === 'POST' && url.pathname === '/auth/start') {
    const result = await containerJson(container, env, '/auth/start', {});
    return json({ status: 'pending', verificationUrl: result.verificationUrl, userCode: result.userCode, expiresInSeconds: result.expiresInSeconds });
  }

  if (request.method === 'GET' && url.pathname === '/auth/status') {
    const saved = await env.VOICE_AUTH.head(objectKey);
    if (saved) return json({ status: 'ready', runtimeVersion: env.CODEX_RUNTIME_VERSION });
    const result = await containerJson(container, env, '/auth/status');
    if (result.status !== 'ready' || typeof result.authJson !== 'string') {
      return json({
        status: result.status === 'failed' ? 'failed' : result.status === 'disconnected' ? 'disconnected' : 'pending',
        message: result.message,
        verificationUrl: result.verificationUrl,
        userCode: result.userCode,
        expiresInSeconds: result.expiresInSeconds,
      });
    }
    await saveEncryptedAuth(env, objectKey, result.authJson);
    return json({ status: 'ready', runtimeVersion: env.CODEX_RUNTIME_VERSION });
  }

  if (request.method === 'POST' && url.pathname === '/disconnect') {
    await checkpointThreadState(container, env, payload.userHash).catch(() => undefined);
    await env.VOICE_AUTH.delete(objectKey);
    await containerJson(container, env, '/disconnect', {}).catch(() => undefined);
    await container.stop('SIGTERM').catch(() => undefined);
    return json({ status: 'disconnected' });
  }

  if (request.method === 'GET' && url.pathname === '/threads') {
    const saved = await env.VOICE_AUTH.get(objectKey);
    if (!saved) return json({ status: 'auth_required', message: 'Connect your ChatGPT subscription to see saved conversations.' }, { status: 409 });
    const authJson = await decryptAuth(await saved.text(), env.VOICE_AUTH_ENCRYPTION_KEY);
    if (authJson.length > AUTH_LIMIT) throw new Response('Saved ChatGPT sign-in data is invalid.', { status: 400 });
    JSON.parse(authJson);
    await restoreThreadState(container, env, payload.userHash);
    const result = await containerJson(container, env, '/threads/list', { authJson });
    return json({ status: 'ready', threads: Array.isArray(result.threads) ? result.threads : [] });
  }

  if (request.method === 'POST' && url.pathname === '/session/stop') {
    const saved = await env.VOICE_AUTH.head(objectKey);
    if (!saved) return json({ status: 'disconnected' });
    await checkpointThreadState(container, env, payload.userHash);
    return json({ status: 'saved' });
  }

  if (request.method === 'POST' && url.pathname === '/session') {
    const body = await readJson(request, SDP_LIMIT + 2_000);
    const sdp = typeof body.sdp === 'string' ? body.sdp : '';
    const threadId = body.threadId == null || body.threadId === '' ? null : body.threadId;
    if (!sdp || sdp.length > SDP_LIMIT) throw new Response('A valid WebRTC offer is required.', { status: 400 });
    if (threadId != null && (typeof threadId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f-]{27,40}$/i.test(threadId))) {
      throw new Response('The selected voice conversation is invalid.', { status: 400 });
    }
    const saved = await env.VOICE_AUTH.get(objectKey);
    if (!saved) return json({ status: 'auth_required', message: 'Connect your ChatGPT subscription for voice first.' }, { status: 409 });
    const authJson = await decryptAuth(await saved.text(), env.VOICE_AUTH_ENCRYPTION_KEY);
    if (authJson.length > AUTH_LIMIT) throw new Response('Saved ChatGPT sign-in data is invalid.', { status: 400 });
    JSON.parse(authJson);
    await restoreThreadState(container, env, payload.userHash);
    const result = await containerJson(container, env, '/session/start', { sdp, authJson, threadId });
    const sessionId = typeof result.sessionId === 'string' ? result.sessionId : '';
    const answerSdp = typeof result.sdp === 'string' ? result.sdp : '';
    if (!sessionId || !answerSdp) throw new Response('The subscription realtime compatibility check did not return audio.', { status: 503 });
    const refreshedAuth = await containerJson(container, env, '/auth/snapshot');
    await saveEncryptedAuth(env, objectKey, refreshedAuth.authJson);
    const socketToken = await signGatewayToken({
      version: 1,
      purpose: 'voice_tool_socket',
      userHash: payload.userHash,
      origin: new URL(env.SITE_ORIGIN).origin,
      issuedAt: Date.now(),
      expiresAt: Date.now() + 31 * 60_000,
      nonce: randomToken(),
      sessionId,
    }, env.VOICE_GATEWAY_SHARED_SECRET);
    const socketUrl = new URL(request.url);
    socketUrl.protocol = socketUrl.protocol === 'https:' ? 'wss:' : 'ws:';
    socketUrl.pathname = `/tools/${sessionId}`;
    socketUrl.search = '';
    return json({ status: 'ready', sessionId, threadId: result.threadId, resumed: result.resumed === true, sdp: answerSdp, toolSocketUrl: socketUrl.toString(), toolSocketToken: socketToken, warningAfterSeconds: 1_500, expiresAfterSeconds: 1_800 });
  }

  throw new Response('Not found.', { status: 404 });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (request.method === 'GET' && url.pathname === '/health') {
        const state = await ownerContainer(env).getState().catch(() => ({ status: 'stopped' as const, lastChange: 0 }));
        return json({ status: 'ok', container: state.status, runtimeVersion: env.CODEX_RUNTIME_VERSION });
      }
      return await handleAuthorized(request, env);
    } catch (error) {
      if (error instanceof Response) {
        return json({ error: await error.text() }, { status: error.status || 400 });
      }
      return json({ error: 'The voice gateway could not complete this request.' }, { status: 500 });
    }
  },
} satisfies ExportedHandler<Env>;
