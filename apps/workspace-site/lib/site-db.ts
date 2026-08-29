import { env } from 'cloudflare:workers';
import type { ChatGPTUser } from '../app/chatgpt-auth';

export type SiteRole = 'owner' | 'viewer';

export type WorkspaceLink = {
  accessTokenCiphertext: string;
  refreshTokenCiphertext: string | null;
  expiresAt: number | null;
  scope: string;
  revision: number;
};

function database(): D1Database {
  if (!env.DB) throw new Error('The site database is unavailable.');
  return env.DB;
}

export async function upsertSiteUser(user: ChatGPTUser): Promise<void> {
  const now = Date.now();
  await database().prepare(
    `INSERT INTO site_users (user_id, role, created_at, updated_at)
     VALUES (?, 'viewer', ?, ?)
     ON CONFLICT(user_id) DO UPDATE SET updated_at = excluded.updated_at`,
  ).bind(user.userId, now, now).run();
}

export async function siteRole(userId: string): Promise<SiteRole | null> {
  const row = await database().prepare('SELECT role FROM site_users WHERE user_id = ?').bind(userId).first<{ role: SiteRole }>();
  return row?.role ?? null;
}

export async function bootstrapOwner(user: ChatGPTUser): Promise<void> {
  const currentOwner = await database().prepare("SELECT user_id FROM site_users WHERE role = 'owner' LIMIT 1").first<{ user_id: string }>();
  if (currentOwner && currentOwner.user_id !== user.userId) throw new Error('An owner is already bound to this site.');
  await upsertSiteUser(user);
  await database().prepare("UPDATE site_users SET role = 'owner', updated_at = ? WHERE user_id = ?").bind(Date.now(), user.userId).run();
}

export async function getWorkspaceLink(userId: string): Promise<WorkspaceLink | null> {
  const row = await database().prepare(
    `SELECT access_token_ciphertext, refresh_token_ciphertext, expires_at, scope, revision
     FROM workspace_links WHERE user_id = ?`,
  ).bind(userId).first<{
    access_token_ciphertext: string;
    refresh_token_ciphertext: string | null;
    expires_at: number | null;
    scope: string;
    revision: number;
  }>();
  if (!row) return null;
  return {
    accessTokenCiphertext: row.access_token_ciphertext,
    refreshTokenCiphertext: row.refresh_token_ciphertext,
    expiresAt: row.expires_at,
    scope: row.scope,
    revision: row.revision,
  };
}

export async function saveWorkspaceLink(userId: string, input: Omit<WorkspaceLink, 'revision'>): Promise<void> {
  const now = Date.now();
  await database().prepare(
    `INSERT INTO workspace_links
      (user_id, access_token_ciphertext, refresh_token_ciphertext, expires_at, scope, revision, updated_at)
     VALUES (?, ?, ?, ?, ?, 1, ?)
     ON CONFLICT(user_id) DO UPDATE SET
       access_token_ciphertext = excluded.access_token_ciphertext,
       refresh_token_ciphertext = COALESCE(excluded.refresh_token_ciphertext, workspace_links.refresh_token_ciphertext),
       expires_at = excluded.expires_at,
       scope = excluded.scope,
       revision = workspace_links.revision + 1,
       updated_at = excluded.updated_at`,
  ).bind(
    userId,
    input.accessTokenCiphertext,
    input.refreshTokenCiphertext,
    input.expiresAt,
    input.scope,
    now,
  ).run();
}

export async function acquireWorkspaceRefreshLease(userId: string, lifetimeMs = 15_000): Promise<string | null> {
  const now = Date.now();
  const leaseId = crypto.randomUUID();
  await database().prepare('DELETE FROM workspace_refresh_locks WHERE expires_at <= ?').bind(now).run();
  const result = await database().prepare(
    `INSERT OR IGNORE INTO workspace_refresh_locks (user_id, lease_id, expires_at)
     VALUES (?, ?, ?)`,
  ).bind(userId, leaseId, now + lifetimeMs).run();
  return Number(result.meta.changes ?? 0) === 1 ? leaseId : null;
}

export async function releaseWorkspaceRefreshLease(userId: string, leaseId: string): Promise<void> {
  await database().prepare(
    'DELETE FROM workspace_refresh_locks WHERE user_id = ? AND lease_id = ?',
  ).bind(userId, leaseId).run();
}

export async function claimIdempotency(hash: string, userId: string, toolName: string): Promise<boolean> {
  const now = Date.now();
  await database().prepare('DELETE FROM action_receipts WHERE expires_at < ?').bind(now).run();
  const result = await database().prepare(
    `INSERT OR IGNORE INTO action_receipts
      (idempotency_hash, user_id, tool_name, created_at, expires_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).bind(hash, userId, toolName, now, now + 24 * 60 * 60 * 1000).run();
  return Number(result.meta.changes ?? 0) === 1;
}

export type VoiceAuthState = {
  status: 'disconnected' | 'pending' | 'ready' | 'unavailable';
  r2ObjectKey: string;
  revision: number;
};

export async function getVoiceAuthState(userId: string): Promise<VoiceAuthState | null> {
  const row = await database().prepare(
    'SELECT status, r2_object_key, revision FROM voice_auth WHERE user_id = ?',
  ).bind(userId).first<{ status: VoiceAuthState['status']; r2_object_key: string; revision: number }>();
  return row ? { status: row.status, r2ObjectKey: row.r2_object_key, revision: row.revision } : null;
}

export async function saveVoiceAuthState(
  userId: string,
  r2ObjectKey: string,
  status: VoiceAuthState['status'],
): Promise<void> {
  await database().prepare(
    `INSERT INTO voice_auth (user_id, r2_object_key, status, revision, updated_at)
     VALUES (?, ?, ?, 1, ?)
     ON CONFLICT(user_id) DO UPDATE SET
       r2_object_key = excluded.r2_object_key,
       status = excluded.status,
       revision = voice_auth.revision + 1,
       updated_at = excluded.updated_at`,
  ).bind(userId, r2ObjectKey, status, Date.now()).run();
}
