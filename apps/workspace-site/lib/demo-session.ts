import { cookieHeader, parseCookie } from './http';
import { createDemoWorkspace, destroyDemoWorkspace, ensureDemoWorkspace } from './demo-store';
import {
  randomBase64Url,
  signDemoSessionToken,
  verifyDemoSessionToken,
  type DemoSessionTokenPayload,
} from './security';
import { requiredSecret } from './server-auth';

export const DEMO_SESSION_COOKIE = 'openassist_demo';

export type DemoSession = {
  workspaceId: string;
  expiresAt: number;
  setCookie?: string;
};

function cookieFor(request: Request, payload: DemoSessionTokenPayload, token: string): string {
  const maxAge = Math.max(0, Math.floor((payload.expiresAt - Date.now()) / 1000));
  return cookieHeader(DEMO_SESSION_COOKIE, token, request, maxAge, '/');
}

async function issueDemoSession(request: Request): Promise<DemoSession> {
  const { workspaceId, expiresAt } = await createDemoWorkspace();
  const payload: DemoSessionTokenPayload = {
    version: 1,
    purpose: 'demo_workspace',
    workspaceId,
    nonce: randomBase64Url(24),
    issuedAt: Date.now(),
    expiresAt,
  };
  const token = await signDemoSessionToken(payload, requiredSecret('ACTION_SIGNING_KEY'));
  return { workspaceId, expiresAt, setCookie: cookieFor(request, payload, token) };
}

export async function getOrCreateDemoSession(request: Request): Promise<DemoSession> {
  const token = parseCookie(request, DEMO_SESSION_COOKIE);
  if (token) {
    try {
      const payload = await verifyDemoSessionToken(token, requiredSecret('ACTION_SIGNING_KEY'));
      if (payload.expiresAt > Date.now() && await ensureDemoWorkspace(payload.workspaceId, payload.expiresAt)) {
        return { workspaceId: payload.workspaceId, expiresAt: payload.expiresAt };
      }
    } catch {
      // A missing, expired, or changed cookie starts a fresh isolated demo.
    }
  }
  return issueDemoSession(request);
}

export async function replaceDemoSession(request: Request, currentWorkspaceId?: string): Promise<DemoSession> {
  if (currentWorkspaceId) await destroyDemoWorkspace(currentWorkspaceId);
  return issueDemoSession(request);
}

export function attachDemoCookie(response: Response, session: DemoSession): Response {
  if (!session.setCookie) return response;
  const headers = new Headers(response.headers);
  headers.append('set-cookie', session.setCookie);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}
