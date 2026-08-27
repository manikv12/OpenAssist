import { index, integer, primaryKey, sqliteTable, text } from 'drizzle-orm/sqlite-core';

// Live Google content is never stored here. Tables prefixed with `demo_` contain
// only isolated judge-mode data and are automatically expired. Google and the
// Workspace MCP remain the source of truth in Live mode.
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

export const demoWorkspaces = sqliteTable('demo_workspaces', {
  workspaceId: text('workspace_id').primaryKey(),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
  expiresAt: integer('expires_at').notNull(),
}, (table) => [index('demo_workspaces_expires_idx').on(table.expiresAt)]);

export const demoMessages = sqliteTable('demo_messages', {
  workspaceId: text('workspace_id').notNull().references(() => demoWorkspaces.workspaceId, { onDelete: 'cascade' }),
  messageId: text('message_id').notNull(),
  account: text('account').notNull(),
  sender: text('sender').notNull(),
  subject: text('subject').notNull(),
  snippet: text('snippet').notNull(),
  timeLabel: text('time_label').notNull(),
  unread: integer('unread', { mode: 'boolean' }).notNull().default(true),
  urgent: integer('urgent', { mode: 'boolean' }).notNull().default(false),
  hasAttachment: integer('has_attachment', { mode: 'boolean' }).notNull().default(false),
  updatedAt: integer('updated_at').notNull(),
}, (table) => [
  primaryKey({ columns: [table.workspaceId, table.messageId] }),
  index('demo_messages_workspace_unread_idx').on(table.workspaceId, table.unread),
]);

export const demoTasks = sqliteTable('demo_tasks', {
  workspaceId: text('workspace_id').notNull().references(() => demoWorkspaces.workspaceId, { onDelete: 'cascade' }),
  taskId: text('task_id').notNull(),
  title: text('title').notNull(),
  listName: text('list_name').notNull().default('My Tasks'),
  due: text('due').notNull().default('No date'),
  tagsJson: text('tags_json').notNull().default('[]'),
  completed: integer('completed', { mode: 'boolean' }).notNull().default(false),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
}, (table) => [
  primaryKey({ columns: [table.workspaceId, table.taskId] }),
  index('demo_tasks_workspace_list_idx').on(table.workspaceId, table.listName),
  index('demo_tasks_workspace_completed_idx').on(table.workspaceId, table.completed),
]);

export const demoEvents = sqliteTable('demo_events', {
  workspaceId: text('workspace_id').notNull().references(() => demoWorkspaces.workspaceId, { onDelete: 'cascade' }),
  eventId: text('event_id').notNull(),
  title: text('title').notNull(),
  account: text('account').notNull().default('Main'),
  start: text('start').notNull(),
  end: text('end').notNull(),
  dayLabel: text('day_label').notNull().default('Upcoming'),
  reminder: text('reminder').notNull().default('10 minutes before'),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
}, (table) => [
  primaryKey({ columns: [table.workspaceId, table.eventId] }),
  index('demo_events_workspace_day_idx').on(table.workspaceId, table.dayLabel),
]);

export const demoNotes = sqliteTable('demo_notes', {
  workspaceId: text('workspace_id').notNull().references(() => demoWorkspaces.workspaceId, { onDelete: 'cascade' }),
  noteId: text('note_id').notNull(),
  title: text('title').notNull(),
  content: text('content').notNull(),
  updatedLabel: text('updated_label').notNull().default('Just now'),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
}, (table) => [
  primaryKey({ columns: [table.workspaceId, table.noteId] }),
  index('demo_notes_workspace_updated_idx').on(table.workspaceId, table.updatedAt),
]);

export const demoMemory = sqliteTable('demo_memory', {
  workspaceId: text('workspace_id').notNull().references(() => demoWorkspaces.workspaceId, { onDelete: 'cascade' }),
  factId: text('fact_id').notNull(),
  category: text('category').notNull().default('General'),
  fact: text('fact').notNull(),
  createdAt: integer('created_at').notNull(),
  updatedAt: integer('updated_at').notNull(),
}, (table) => [
  primaryKey({ columns: [table.workspaceId, table.factId] }),
  index('demo_memory_workspace_category_idx').on(table.workspaceId, table.category),
]);

export const demoActivity = sqliteTable('demo_activity', {
  workspaceId: text('workspace_id').notNull().references(() => demoWorkspaces.workspaceId, { onDelete: 'cascade' }),
  activityId: text('activity_id').notNull(),
  actor: text('actor').notNull(),
  action: text('action').notNull(),
  timeLabel: text('time_label').notNull().default('Just now'),
  type: text('type', { enum: ['read', 'write'] }).notNull(),
  createdAt: integer('created_at').notNull(),
}, (table) => [
  primaryKey({ columns: [table.workspaceId, table.activityId] }),
  index('demo_activity_workspace_created_idx').on(table.workspaceId, table.createdAt),
]);
