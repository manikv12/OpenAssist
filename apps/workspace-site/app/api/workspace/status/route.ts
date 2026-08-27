import { safeRoute } from '../../../../lib/http';
import { requireOwner } from '../../../../lib/server-auth';
import { getWorkspaceLink } from '../../../../lib/site-db';

export async function GET(): Promise<Response> {
  return safeRoute(async () => {
    const user = await requireOwner();
    const link = await getWorkspaceLink(user.userId);
    return {
      connected: Boolean(link),
      expiresAt: link?.expiresAt ?? null,
      scope: link?.scope ?? null,
      revision: link?.revision ?? 0,
    };
  });
}
