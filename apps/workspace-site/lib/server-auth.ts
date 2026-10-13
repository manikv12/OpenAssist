import { env } from 'cloudflare:workers';
import { getChatGPTUser, type ChatGPTUser } from '../app/chatgpt-auth';
import { getJudgeAccess, type JudgeAccess } from './judge-access';
import { bootstrapOwner, siteRole, upsertSiteUser } from './site-db';

export async function requireSignedInUser(): Promise<ChatGPTUser> {
  const user = await getChatGPTUser();
  if (!user) throw new Response('ChatGPT sign-in is required.', { status: 401 });
  await upsertSiteUser(user);
  return user;
}

export async function requireOwner(): Promise<ChatGPTUser> {
  const user = await requireSignedInUser();
  if ((await siteRole(user.userId)) === 'owner') return user;

  // A newly deployed private Site can bind its exact Sites owner once without
  // exposing the bootstrap secret to browser JavaScript. Remove this temporary
  // environment value immediately after the first successful owner request.
  if (env.OWNER_ACCOUNT_USER_ID && user.userId === env.OWNER_ACCOUNT_USER_ID) {
    await bootstrapOwner(user);
    return user;
  }

  throw new Response('Owner access is required.', { status: 403 });
}

export type SiteAccess =
  | { kind: 'owner'; user: ChatGPTUser }
  | JudgeAccess;

export async function getSiteAccess(request: Request): Promise<SiteAccess | null> {
  const user = await getChatGPTUser();
  if (user) {
    const role = await siteRole(user.userId).catch(() => null);
    if (role === 'owner' || (env.OWNER_ACCOUNT_USER_ID && user.userId === env.OWNER_ACCOUNT_USER_ID)) {
      await upsertSiteUser(user);
      return { kind: 'owner', user };
    }
  }
  return getJudgeAccess(request);
}

export async function requireDemoAccess(request: Request): Promise<SiteAccess> {
  const access = await getSiteAccess(request);
  if (!access) throw new Response('Judge or owner access is required.', { status: 401 });
  return access;
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
