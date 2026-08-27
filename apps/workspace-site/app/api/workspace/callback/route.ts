import { env } from 'cloudflare:workers';
import { cookieHeader, parseCookie, safeRoute } from '../../../../lib/http';
import { decryptSecret, encryptSecret } from '../../../../lib/security';
import { publicOrigin, requireOwner, requiredSecret } from '../../../../lib/server-auth';
import { saveWorkspaceLink } from '../../../../lib/site-db';

const OAUTH_COOKIE = 'oa_workspace_oauth';

type OAuthCookie = {
  version: 1;
  userId: string;
  state: string;
  verifier: string;
  redirectUri: string;
  issuedAt: number;
};

export async function GET(request: Request): Promise<Response> {
  return safeRoute(async () => {
    const user = await requireOwner();
    const url = new URL(request.url);
    const code = url.searchParams.get('code');
    const state = url.searchParams.get('state');
    const stored = parseCookie(request, OAUTH_COOKIE);
    if (!code || !state || !stored) throw new Error('Workspace connection response is invalid.');
    const payload = JSON.parse(await decryptSecret(stored, requiredSecret('TOKEN_ENCRYPTION_KEY'))) as OAuthCookie;
    const exactRedirect = `${publicOrigin(request)}/api/workspace/callback`;
    if (payload.version !== 1 || payload.userId !== user.userId || payload.state !== state || payload.redirectUri !== exactRedirect || Date.now() - payload.issuedAt > 600_000) {
      throw new Error('Workspace connection response is invalid.');
    }
    if (!env.WORKSPACE_OAUTH_CLIENT_ID) throw new Error('Workspace OAuth is not configured.');
    const body = new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      client_id: env.WORKSPACE_OAUTH_CLIENT_ID,
      redirect_uri: exactRedirect,
      code_verifier: payload.verifier,
    });
    const headers = new Headers({ 'content-type': 'application/x-www-form-urlencoded' });
    if (env.WORKSPACE_OAUTH_CLIENT_SECRET) {
      headers.set('authorization', `Basic ${btoa(`${env.WORKSPACE_OAUTH_CLIENT_ID}:${env.WORKSPACE_OAUTH_CLIENT_SECRET}`)}`);
    }
    const issuer = env.WORKSPACE_OAUTH_ISSUER ?? 'https://mail-mcp.developingadventures.com';
    const response = await fetch(`${issuer}/oauth/token`, { method: 'POST', headers, body });
    const token = await response.json() as { access_token?: string; refresh_token?: string; expires_in?: number; scope?: string };
    if (!response.ok || !token.access_token) throw new Error('Workspace connection could not be completed.');
    const secret = requiredSecret('TOKEN_ENCRYPTION_KEY');
    await saveWorkspaceLink(user.userId, {
      accessTokenCiphertext: await encryptSecret(token.access_token, secret),
      refreshTokenCiphertext: token.refresh_token ? await encryptSecret(token.refresh_token, secret) : null,
      expiresAt: token.expires_in ? Date.now() + token.expires_in * 1000 : null,
      scope: token.scope ?? 'workspace.manage',
    });
    return new Response(null, {
      status: 302,
      headers: {
        location: `${publicOrigin(request)}/?workspace=connected`,
        'set-cookie': cookieHeader(OAUTH_COOKIE, '', request, 0),
        'cache-control': 'no-store',
      },
    });
  });
}
