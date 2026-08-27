import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();
const read = (relativePath) => readFile(path.join(root, relativePath), 'utf8');

test('Live D1 tables contain pointers, preferences, encrypted tokens, and hashes only', async () => {
  const migration = (await read('drizzle/0000_spicy_rocket_raccoon.sql')).toLowerCase();
  for (const forbidden of [
    'email text',
    'gmail',
    'message_id',
    'thread_id',
    'attachment',
    'task_text',
    'calendar_text',
    'note_text',
    'memory_text',
    'audio',
    'transcript',
  ]) {
    assert.equal(migration.includes(forbidden), false, `D1 must not contain ${forbidden}`);
  }
  assert.match(migration, /access_token_ciphertext/);
  assert.match(migration, /refresh_token_ciphertext/);
  assert.match(migration, /r2_object_key/);
  assert.match(migration, /idempotency_hash/);
});

test('judge data exists only in explicit expiring demo tables', async () => {
  const migrationFiles = (await readdir(path.join(root, 'drizzle'))).filter((file) => file.endsWith('.sql')).sort();
  const migrations = (await Promise.all(migrationFiles.map((file) => read(`drizzle/${file}`)))).join('\n').toLowerCase();
  for (const table of ['demo_workspaces', 'demo_messages', 'demo_tasks', 'demo_events', 'demo_notes', 'demo_memory', 'demo_activity']) {
    assert.match(migrations, new RegExp('create table `' + table + '`'));
  }
  assert.match(migrations, /demo_workspaces[\s\S]*expires_at/);
  assert.match(migrations, /on delete cascade/);

  const store = await read('lib/demo-store.ts');
  assert.match(store, /const DEMO_LIFETIME_MS = 24 \* 60 \* 60 \* 1000/);
  assert.doesNotMatch(store, /mcp-client|Composio|executeLiveWorkspaceTool/);
  assert.doesNotMatch(store, /console\.(log|info|debug)\s*\(/);
});

test('OAuth uses PKCE, state, a short lifetime, and the exact callback URL', async () => {
  const connect = await read('app/api/workspace/connect/route.ts');
  const callback = await read('app/api/workspace/callback/route.ts');
  assert.match(connect, /code_challenge_method', 'S256'/);
  assert.match(connect, /state/);
  assert.match(callback, /payload\.state !== state/);
  assert.match(callback, /payload\.redirectUri !== exactRedirect/);
  assert.match(callback, /600_000/);
});

test('approved writes are exact, short-lived, idempotent, and never silently retried', async () => {
  const propose = await read('app/api/actions/propose/route.ts');
  const execute = await read('app/api/actions/execute/route.ts');
  assert.match(propose, /argsHash: await sha256\(args\)/);
  assert.match(propose, /expiresAt: issuedAt \+ 120_000/);
  assert.match(execute, /payload\.argsHash !== await sha256\(args\)/);
  assert.match(execute, /payload\.destructive && body\.confirmationMethod !== 'tap'/);
  assert.match(execute, /body\.confirmationMethod !== 'tap' && body\.confirmationMethod !== 'voice'/);
  assert.match(execute, /claimIdempotency/);
  assert.match(execute, /never retried silently/);
});

test('demo writes use the same signed preview and approval boundary', async () => {
  const propose = await read('app/api/demo/actions/propose/route.ts');
  const execute = await read('app/api/demo/actions/execute/route.ts');
  const session = await read('lib/demo-session.ts');
  assert.match(propose, /argsHash: await sha256\(args\)/);
  assert.match(propose, /expiresAt: issuedAt \+ 120_000/);
  assert.match(execute, /payload\.argsHash !== await sha256\(args\)/);
  assert.match(execute, /payload\.destructive && body\.confirmationMethod !== 'tap'/);
  assert.match(execute, /claimIdempotency/);
  assert.match(session, /signDemoSessionToken/);
  assert.match(session, /HttpOnly|cookieHeader/);
});

test('demo routes never call the Live Workspace MCP', async () => {
  const files = [
    'app/api/demo/workspace/route.ts',
    'app/api/demo/tool/route.ts',
    'app/api/demo/actions/propose/route.ts',
    'app/api/demo/actions/execute/route.ts',
  ];
  for (const file of files) {
    const source = await read(file);
    assert.doesNotMatch(source, /mcp-client|workspaceAccessToken|executeLiveWorkspaceTool/, file);
    assert.match(source, /getOrCreateDemoSession/, file);
  }
});

test('server code does not log private Workspace content', async () => {
  const files = [
    'lib/mcp-client.ts',
    'lib/site-db.ts',
    'app/api/workspace/tool/route.ts',
    'app/api/actions/execute/route.ts',
    'lib/demo-store.ts',
    'app/api/demo/tool/route.ts',
    'app/api/demo/actions/execute/route.ts',
  ];
  for (const file of files) assert.doesNotMatch(await read(file), /console\.(log|info|debug)\s*\(/, file);
});

test('API errors stay JSON so the owner UI can show a useful reconnect message', async () => {
  const http = await read('lib/http.ts');
  assert.match(http, /error instanceof Response[\s\S]*error\.clone\(\)\.text/);
  assert.match(http, /return json\(\{ error: safe \}, \{ status \}\)/);
});

test('owner bootstrap is restricted to the exact temporary Sites account ID', async () => {
  const auth = await read('lib/server-auth.ts');
  assert.match(auth, /env\.OWNER_ACCOUNT_USER_ID && user\.userId === env\.OWNER_ACCOUNT_USER_ID/);
  assert.match(auth, /await bootstrapOwner\(user\)/);
});

test('voice errors are shown instead of being mislabeled as pending', async () => {
  const app = await read('app/components/workspace-app.tsx');
  assert.match(app, /if \(!authResponse\.ok\) throw new Error\(auth\.error \?\? auth\.message/);
});
