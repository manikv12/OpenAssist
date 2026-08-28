import { env } from 'cloudflare:workers';
import { siteRole } from '../lib/site-db';
import { getChatGPTUser } from './chatgpt-auth';
import { WorkspaceApp } from './components/workspace-app';

export default async function Home() {
  const user = await getChatGPTUser();
  const owner = user
    ? (await siteRole(user.userId).catch(() => null)) === 'owner' || env.OWNER_ACCOUNT_USER_ID === user.userId
    : false;

  return (
    <WorkspaceApp
      user={
        user
          ? {
              id: user.userId,
              email: user.email,
              name: user.displayName,
              owner,
            }
          : null
      }
    />
  );
}
