import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();
const read = (relativePath) => readFile(path.join(root, relativePath), 'utf8');

test('D1 contains pointers, preferences, encrypted tokens, and hashes only', async () => {
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

test('server code does not log private Workspace content', async () => {
  const files = [
    'lib/mcp-client.ts',
    'lib/site-db.ts',
    'app/api/workspace/tool/route.ts',
    'app/api/actions/execute/route.ts',
  ];
  for (const file of files) assert.doesNotMatch(await read(file), /console\.(log|info|debug)\s*\(/, file);
});
