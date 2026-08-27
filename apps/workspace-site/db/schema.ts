import { index, integer, sqliteTable, text } from 'drizzle-orm/sqlite-core';

// This database intentionally contains no Gmail, attachment, task, calendar,
// note, memory, audio, or transcript content. Google and the Workspace MCP stay
// the source of truth for that data.
export const siteUsers = sqliteTable('site_users', {
  userId: text('user_id').primaryKey(),
  role: text('role', { enum: ['owner', 'viewer'] }).notNull().default('viewer'),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
});

export const workspaceLinks = sqliteTable('workspace_links', {
  userId: text('user_id').primaryKey(),
  accessTokenCiphertext: text('access_token_ciphertext').notNull(),
  refreshTokenCiphertext: text('refresh_token_ciphertext'),
  expiresAt: integer('expires_at'),
  scope: text('scope').notNull().default('workspace.manage'),
  revision: integer('revision').notNull().default(1),
  updatedAt: integer('updated_at').notNull(),
});

export const sitePreferences = sqliteTable('site_preferences', {
  userId: text('user_id').primaryKey(),
  defaultView: text('default_view').notNull().default('today'),
  density: text('density', { enum: ['comfortable', 'compact'] }).notNull().default('comfortable'),
  timeZone: text('time_zone').notNull().default('America/Chicago'),
  updatedAt: integer('updated_at').notNull(),
});

export const voiceAuth = sqliteTable('voice_auth', {
  userId: text('user_id').primaryKey(),
  r2ObjectKey: text('r2_object_key').notNull(),
  status: text('status', { enum: ['disconnected', 'pending', 'ready', 'unavailable'] }).notNull(),
  revision: integer('revision').notNull().default(1),
  updatedAt: integer('updated_at').notNull(),
});

// Only a one-way request hash is retained to prevent duplicate writes. The
// original tool arguments and Google content are never placed in D1.
export const actionReceipts = sqliteTable('action_receipts', {
  idempotencyHash: text('idempotency_hash').primaryKey(),
  userId: text('user_id').notNull(),
  toolName: text('tool_name').notNull(),
  createdAt: integer('created_at').notNull(),
  expiresAt: integer('expires_at').notNull(),
}, (table) => [index('action_receipts_user_expires_idx').on(table.userId, table.expiresAt)]);
