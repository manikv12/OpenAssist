import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();
const read = (relativePath) => readFile(path.join(root, relativePath), 'utf8');

test('voice has the same Workspace tool contract as the Site', async () => {
  const voice = JSON.parse(await read('container/tool-names.json'));
  const shared = JSON.parse(await read('../../packages/workspace-tool-contract/tool-names.json'));
  assert.deepEqual(voice, shared);
  assert.equal(voice.length, 23);
});

test('voice removes API-key variables and forces ChatGPT sign-in', async () => {
  const server = await read('container/server.mjs');
  assert.match(server, /forced_login_method = "chatgpt"/);
  assert.match(server, /OPENAI_API_KEY\|CODEX_API_KEY\|AZURE_OPENAI_API_KEY/);
  assert.match(server, /API-key authentication is not allowed/);
  assert.doesNotMatch(server, /process\.env\.OPENAI_API_KEY/);
});

test('voice is isolated and only exposes the visible Site bridge', async () => {
  const server = await read('container/server.mjs');
  assert.match(server, /sandbox: 'read-only'/);
  assert.match(server, /selectedCapabilityRoots: \[\]/);
  assert.match(server, /name: 'assistant_use_site_tool'/);
  assert.match(server, /Only the visible Workspace site tool is allowed/);
  assert.match(server, /Delete, trash, and forget always require a screen tap/);
});

test('voice has strict owner, time, and instance limits', async () => {
  const worker = await read('src/index.ts');
  const server = await read('container/server.mjs');
  const config = await read('wrangler.jsonc');
  assert.match(worker, /openassist-owner-voice/);
  assert.match(worker, /sleepAfter = '15m'/);
  assert.match(server, /25 \* 60_000/);
  assert.match(server, /30 \* 60_000/);
  assert.match(config, /"max_instances": 1/);
});
