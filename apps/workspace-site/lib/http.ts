import { publicOrigin } from './server-auth';

export function assertSameOrigin(request: Request): void {
  const origin = request.headers.get('origin');
  if (origin && new URL(origin).origin !== publicOrigin(request)) {
    throw new Response('Cross-site requests are not allowed.', { status: 403 });
  }
}

export async function readJsonObject(request: Request, maxBytes = 32_000): Promise<Record<string, unknown>> {
  const length = Number(request.headers.get('content-length') ?? 0);
  if (length > maxBytes) throw new Response('Request is too large.', { status: 413 });
  const text = await request.text();
  if (text.length > maxBytes) throw new Response('Request is too large.', { status: 413 });
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

export function json(data: unknown, init: ResponseInit = {}): Response {
  const headers = new Headers(init.headers);
  headers.set('content-type', 'application/json; charset=utf-8');
  headers.set('cache-control', 'no-store');
  headers.set('x-content-type-options', 'nosniff');
  return new Response(JSON.stringify(data), { ...init, headers });
}

export async function safeRoute<T>(work: () => Promise<T | Response>): Promise<Response> {
  try {
    const result = await work();
    return result instanceof Response ? result : json(result);
  } catch (error) {
    const status = error instanceof Response ? error.status : 400;
    const message = error instanceof Response
      ? await error.clone().text().catch(() => 'Request failed.')
      : error instanceof Error ? error.message : 'Request failed.';
    const safe = /^(Invalid tool input:|Workspace is not connected|Workspace must be reconnected|Workspace authorization expired|Workspace refresh|No connected Google account|Owner access|ChatGPT sign-in|Judge |An owner is already bound|Approval preview|Demo session|The demo|The capped demo|The funded judge|The judge|This demo|At least one demo|This tool|Google Tasks list|Voice is)/.test(message)
      ? message
      : 'The request could not be completed.';
    return json({ error: safe }, { status });
  }
}

export function parseCookie(request: Request, name: string): string | null {
  const cookie = request.headers.get('cookie') ?? '';
  for (const part of cookie.split(';')) {
    const [key, ...value] = part.trim().split('=');
    if (key === name) return decodeURIComponent(value.join('='));
  }
  return null;
}

export function cookieHeader(name: string, value: string, request: Request, maxAge: number, path = '/api/workspace'): string {
  const secure = new URL(request.url).protocol === 'https:' ? '; Secure' : '';
  return `${name}=${encodeURIComponent(value)}; HttpOnly; SameSite=Lax; Path=${path}; Max-Age=${maxAge}${secure}`;
}
