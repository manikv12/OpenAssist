import { env } from 'cloudflare:workers';
import { assertSameOrigin, readJsonObject, safeRoute } from '../../../../lib/http';
import { constantTimeTextEqual } from '../../../../lib/security';
import { requireSignedInUser } from '../../../../lib/server-auth';
import { bootstrapOwner } from '../../../../lib/site-db';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    const user = await requireSignedInUser();
    const body = await readJsonObject(request, 2_000);
    const supplied = typeof body.code === 'string' ? body.code : '';
    if (!env.OWNER_BOOTSTRAP_CODE || !supplied || !await constantTimeTextEqual(supplied, env.OWNER_BOOTSTRAP_CODE)) {
      return new Response('Invalid bootstrap code.', { status: 403 });
    }
    await bootstrapOwner(user);
    return { status: 'owner_bound' };
  });
}
