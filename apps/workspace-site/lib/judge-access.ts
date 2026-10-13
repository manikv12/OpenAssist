import { env } from 'cloudflare:workers';
import { cookieHeader, parseCookie } from './http';
import {
  constantTimeTextEqual,
  randomBase64Url,
  sha256,
  signJudgeAccessToken,
  verifyJudgeAccessToken,
} from './security';

export const JUDGE_ACCESS_COOKIE = 'openassist_judge_access';
const SESSION_LIFETIME_MS = 12 * 60 * 60 * 1000;
const ATTEMPT_WINDOW_MS = 15 * 60 * 1000;
const MAX_ATTEMPTS = 5;

function signingSecret(): string {
  const value = env.ACTION_SIGNING_KEY;
  if (!value) throw new Error('ACTION_SIGNING_KEY is not configured.');
  return value;
}

export type JudgeAccess = {
  kind: 'judge';
  sessionId: string;
  expiresAt: number;
};

function configuredCredentials(): { username: string; code: string; revision: Promise<string> } {
  const username = env.JUDGE_ACCESS_USERNAME?.trim() ?? '';
  const code = env.JUDGE_ACCESS_CODE?.trim() ?? '';
  if (username.length < 3 || code.length < 20) {
    throw new Response('Judge access is not configured.', { status: 503 });
  }
  return {
    username,
    code,
    revision: sha256({ purpose: 'judge_access_revision', username, code }),
  };
}

function configuredExpiry(): number | null {
  const value = env.JUDGE_ACCESS_EXPIRES_AT?.trim();
  if (!value) return null;
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) throw new Response('Judge access is not configured.', { status: 503 });
  return parsed;
}

function requestAddress(request: Request): string {
  return request.headers.get('cf-connecting-ip')
    ?? request.headers.get('x-forwarded-for')?.split(',')[0]?.trim()
    ?? 'unknown';
}

async function attemptKey(request: Request, username: string): Promise<string> {
  const windowStart = Math.floor(Date.now() / ATTEMPT_WINDOW_MS) * ATTEMPT_WINDOW_MS;
  return sha256({
    purpose: 'judge_login_limit',
    secret: signingSecret(),
    address: requestAddress(request),
    username: username.toLowerCase(),
    windowStart,
  });
}

async function assertLoginAllowed(request: Request, username: string): Promise<void> {
  const now = Date.now();
  await env.DB.prepare('DELETE FROM judge_login_limits WHERE expires_at < ?').bind(now).run();
  const row = await env.DB.prepare(
    'SELECT attempts FROM judge_login_limits WHERE attempt_key = ?',
  ).bind(await attemptKey(request, username)).first<{ attempts: number }>();
  if ((row?.attempts ?? 0) >= MAX_ATTEMPTS) {
    throw new Response('Judge access is temporarily locked. Try again in 15 minutes.', { status: 429 });
  }
}

async function recordLoginFailure(request: Request, username: string): Promise<void> {
  const key = await attemptKey(request, username);
  await env.DB.prepare(
    `INSERT INTO judge_login_limits (attempt_key, attempts, expires_at)
     VALUES (?, 1, ?)
     ON CONFLICT(attempt_key) DO UPDATE SET attempts = attempts + 1`,
  ).bind(key, Date.now() + ATTEMPT_WINDOW_MS).run();
}

export async function createJudgeAccess(request: Request, username: string, code: string): Promise<{ access: JudgeAccess; setCookie: string }> {
  await assertLoginAllowed(request, username);
  const configured = configuredCredentials();
  const [usernameMatches, codeMatches] = await Promise.all([
    constantTimeTextEqual(username.trim(), configured.username),
    constantTimeTextEqual(code.trim(), configured.code),
  ]);
  if (!usernameMatches || !codeMatches) {
    await recordLoginFailure(request, username);
    throw new Response('Judge username or access code is incorrect.', { status: 401 });
  }

  const now = Date.now();
  const sharedExpiry = configuredExpiry();
  if (sharedExpiry != null && sharedExpiry <= now) {
    throw new Response('Judge access has expired.', { status: 403 });
  }
  const expiresAt = Math.min(now + SESSION_LIFETIME_MS, sharedExpiry ?? Number.MAX_SAFE_INTEGER);
  const payload = {
    version: 1 as const,
    purpose: 'judge_access' as const,
    sessionId: randomBase64Url(24),
    credentialRevision: await configured.revision,
    issuedAt: now,
    expiresAt,
  };
  const token = await signJudgeAccessToken(payload, signingSecret());
  return {
    access: { kind: 'judge', sessionId: payload.sessionId, expiresAt },
    setCookie: cookieHeader(
      JUDGE_ACCESS_COOKIE,
      token,
      request,
      Math.floor((expiresAt - now) / 1000),
      '/',
    ),
  };
}

export async function getJudgeAccess(request: Request): Promise<JudgeAccess | null> {
  const token = parseCookie(request, JUDGE_ACCESS_COOKIE);
  if (!token) return null;
  try {
    const configured = configuredCredentials();
    const payload = await verifyJudgeAccessToken(token, signingSecret());
    if (payload.expiresAt <= Date.now() || payload.credentialRevision !== await configured.revision) return null;
    const sharedExpiry = configuredExpiry();
    if (sharedExpiry != null && sharedExpiry <= Date.now()) return null;
    return { kind: 'judge', sessionId: payload.sessionId, expiresAt: payload.expiresAt };
  } catch {
    return null;
  }
}

export function clearJudgeAccessCookie(request: Request): string {
  return cookieHeader(JUDGE_ACCESS_COOKIE, '', request, 0, '/');
}
