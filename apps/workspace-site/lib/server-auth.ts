import { env } from 'cloudflare:workers';
import { getChatGPTUser, type ChatGPTUser } from '../app/chatgpt-auth';
import { siteRole, upsertSiteUser } from './site-db';

export async function requireSignedInUser(): Promise<ChatGPTUser> {
  const user = await getChatGPTUser();
  if (!user) throw new Response('ChatGPT sign-in is required.', { status: 401 });
  await upsertSiteUser(user);
  return user;
}

export async function requireOwner(): Promise<ChatGPTUser> {
  const user = await requireSignedInUser();
  if ((await siteRole(user.userId)) !== 'owner') throw new Response('Owner access is required.', { status: 403 });
  return user;
}

export function requiredSecret(name: 'TOKEN_ENCRYPTION_KEY' | 'ACTION_SIGNING_KEY' | 'VOICE_GATEWAY_SHARED_SECRET'): string {
  const value = env[name];
  if (!value) throw new Error(`${name} is not configured.`);
  return value;
}

export function publicOrigin(request: Request): string {
  if (env.SITE_PUBLIC_ORIGIN) return new URL(env.SITE_PUBLIC_ORIGIN).origin;
  return new URL(request.url).origin;
}
