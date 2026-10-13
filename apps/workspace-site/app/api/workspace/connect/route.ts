import { env } from 'cloudflare:workers';
import { cookieHeader, safeRoute } from '../../../../lib/http';
import { encryptSecret, pkceChallenge, randomBase64Url } from '../../../../lib/security';
import { publicOrigin, requireOwner, requiredSecret } from '../../../../lib/server-auth';

const OAUTH_COOKIE = 'oa_workspace_oauth';

export async function GET(request: Request): Promise<Response> {
  return safeRoute(async () => {
    const user = await requireOwner();
    if (!env.WORKSPACE_OAUTH_CLIENT_ID) throw new Error('Workspace OAuth is not configured.');
    const origin = publicOrigin(request);
    const redirectUri = `${origin}/api/workspace/callback`;
    const verifier = randomBase64Url(48);
    const state = randomBase64Url(32);
    const issuedAt = Date.now();
    const cookie = await encryptSecret(JSON.stringify({ version: 1, userId: user.userId, state, verifier, redirectUri, issuedAt }), requiredSecret('TOKEN_ENCRYPTION_KEY'));
    const issuer = env.WORKSPACE_OAUTH_ISSUER ?? 'https://mail-mcp.developingadventures.com';
    const url = new URL('/authorize', issuer);
    url.searchParams.set('response_type', 'code');
    url.searchParams.set('client_id', env.WORKSPACE_OAUTH_CLIENT_ID);
    url.searchParams.set('redirect_uri', redirectUri);
    url.searchParams.set('scope', 'workspace.manage');
    url.searchParams.set('state', state);
    url.searchParams.set('code_challenge', await pkceChallenge(verifier));
    url.searchParams.set('code_challenge_method', 'S256');
    url.searchParams.set('resource', env.WORKSPACE_MCP_URL ?? 'https://mail-mcp.developingadventures.com/mcp');
    return new Response(null, {
      status: 302,
      headers: {
        location: url.toString(),
        'set-cookie': cookieHeader(OAUTH_COOKIE, cookie, request, 600),
        'cache-control': 'no-store',
      },
    });
  });
}
