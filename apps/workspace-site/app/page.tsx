import { getChatGPTUser } from './chatgpt-auth';
import { WorkspaceApp } from './components/workspace-app';

export default async function Home() {
  const user = await getChatGPTUser();

  return (
    <WorkspaceApp
      user={
        user
          ? {
              id: user.userId,
              email: user.email,
              name: user.displayName,
            }
          : null
      }
    />
  );
}
