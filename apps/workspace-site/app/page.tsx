import { headers } from 'next/headers';
import { getSiteAccess } from '../lib/server-auth';
import { chatGPTSignInPath, chatGPTSignOutPath, getChatGPTUser } from './chatgpt-auth';
import { AccessGate } from './components/access-gate';
import { WorkspaceApp } from './components/workspace-app';

export const dynamic = 'force-dynamic';

export default async function Home() {
  const requestHeaders = await headers();
  const host = requestHeaders.get('host') ?? 'app.local';
  const protocol = requestHeaders.get('x-forwarded-proto') ?? 'https';
  const request = new Request(`${protocol}://${host}/`, { headers: new Headers(requestHeaders) });
  const access = await getSiteAccess(request);

  if (!access) {
    const signedIn = await getChatGPTUser();
    return (
      <AccessGate
        ownerSignInPath={signedIn ? chatGPTSignOutPath('/') : chatGPTSignInPath('/')}
        ownerButtonLabel={signedIn ? 'Switch ChatGPT account' : 'Continue with ChatGPT'}
        signedInEmail={signedIn?.email ?? null}
      />
    );
  }

  if (access.kind === 'judge') {
    return (
      <WorkspaceApp
        user={{
          id: `judge:${access.sessionId}`,
          email: 'Private judge session',
          name: 'WebMCP Judge',
          owner: false,
          access: 'judge',
        }}
      />
    );
  }

  return (
    <WorkspaceApp
      user={{
        id: access.user.userId,
        email: access.user.email,
        name: access.user.displayName,
        owner: true,
        access: 'owner',
      }}
    />
  );
}
