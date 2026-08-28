import { env } from 'cloudflare:workers';
import { siteRole } from '../lib/site-db';
import { requireChatGPTUser } from './chatgpt-auth';
import { WorkspaceApp } from './components/workspace-app';

export const dynamic = 'force-dynamic';

export default async function Home() {
  const user = await requireChatGPTUser('/');
  const owner = (await siteRole(user.userId).catch(() => null)) === 'owner'
    || env.OWNER_ACCOUNT_USER_ID === user.userId;

  return (
    <WorkspaceApp
      user={{
        id: user.userId,
        email: user.email,
        name: user.displayName,
        owner,
      }}
    />
  );
}
