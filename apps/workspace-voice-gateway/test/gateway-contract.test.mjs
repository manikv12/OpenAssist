import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import ts from 'typescript';

const root = process.cwd();
const read = (relativePath) => readFile(path.join(root, relativePath), 'utf8');

test('voice has the same Workspace tool contract as the Site', async () => {
  const voice = JSON.parse(await read('container/tool-names.json'));
  const shared = JSON.parse(await read('../../packages/workspace-tool-contract/tool-names.json'));
  const voiceManifest = JSON.parse(await read('container/tool-manifest.json'));
  const sharedManifest = JSON.parse(await read('../../packages/workspace-tool-contract/tool-manifest.json'));
  const registrySource = await read('../../apps/workspace-site/lib/tool-registry.ts');
  const registryCompiled = ts.transpileModule(registrySource, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  const registry = await import(`data:text/javascript;base64,${Buffer.from(registryCompiled).toString('base64')}`);
  const siteManifest = registry.WORKSPACE_TOOLS.map((tool) => ({
    name: tool.name,
    title: tool.title,
    description: tool.description,
    inputSchema: tool.inputSchema,
    readOnly: Boolean(tool.readOnly),
    untrustedContent: Boolean(tool.untrustedContent),
    destructive: Boolean(tool.destructive),
  }));
  assert.deepEqual(voice, shared);
  assert.deepEqual(voiceManifest, sharedManifest);
  assert.deepEqual(voiceManifest, siteManifest);
  assert.deepEqual(voiceManifest.map((tool) => tool.name), voice);
  assert.equal(voice.length, 23);
});

test('subscription containers remove API-key variables and force ChatGPT sign-in', async () => {
  const server = await read('container/server.mjs');
  const config = await read('container/config.toml');
  const worker = await read('src/index.ts');
  assert.match(config, /forced_login_method = "chatgpt"/);
  assert.match(server, /OPENAI_API_KEY\|CODEX_API_KEY\|AZURE_OPENAI_API_KEY/);
  assert.match(server, /API-key authentication is not allowed/);
  assert.doesNotMatch(server, /process\.env\.OPENAI_API_KEY/);
  assert.match(config, /cli_auth_credentials_store = "file"/);
  assert.match(config, /realtime_conversation = true/);
  assert.match(server, /'--strict-config', '--enable', 'realtime_conversation', 'app-server'/);
  const containerEnv = worker.match(/envVars: Record<string, string> = \{([\s\S]*?)\n  \};/)?.[1] ?? '';
  assert.doesNotMatch(containerEnv, /OPENAI_API_KEY|CODEX_API_KEY|AZURE_OPENAI_API_KEY/);
});

test('voice is isolated and directly exposes only visible Site tools', async () => {
  const worker = await read('src/index.ts');
  const server = await read('container/server.mjs');
  const config = await read('container/config.toml');
  assert.match(server, /sandbox: 'read-only'/);
  assert.match(server, /selectedCapabilityRoots: \[\]/);
  assert.match(server, /\.\.\.toolManifest\.map/);
  assert.match(server, /name: 'assistant_confirm_site_preview'/);
  assert.match(server, /Only the registered visible Workspace tools are allowed/);
  assert.match(server, /includeStartupContext: true/);
  assert.doesNotMatch(server, /assistant_use_site_tool/);
  assert.match(server, /Delete, trash, and forget always require a screen tap/);
  assert.match(config, /shell_tool = false/);
  assert.match(config, /unified_exec = false/);
  assert.match(config, /persistence = "none"/);
  assert.match(worker, /enableInternet = true/);
});

test('refreshed ChatGPT subscription auth is re-encrypted by the Worker', async () => {
  const worker = await read('src/index.ts');
  const server = await read('container/server.mjs');
  assert.match(server, /url\.pathname === '\/auth\/snapshot'/);
  assert.match(worker, /containerJson\(container, env, '\/auth\/snapshot'\)/);
  assert.match(worker, /saveEncryptedAuth\(env, objectKey, refreshedAuth\.authJson\)/);
});

test('pending device sign-in keeps its code available across status checks', async () => {
  const worker = await read('src/index.ts');
  const server = await read('container/server.mjs');
  assert.match(server, /verificationUrl: loginState\?\.userCode \? loginState\.verificationUrl : undefined/);
  assert.match(worker, /verificationUrl: result\.verificationUrl/);
  assert.match(worker, /userCode: result\.userCode/);
});

test('voice has strict per-user, time, and instance limits', async () => {
  const worker = await read('src/index.ts');
  const server = await read('container/server.mjs');
  const config = await read('wrangler.jsonc');
  assert.match(worker, /idFromName\(`openassist-voice-\$\{userHash\}`\)/);
  assert.match(worker, /sleepAfter = '15m'/);
  assert.match(server, /25 \* 60_000/);
  assert.match(server, /30 \* 60_000/);
  assert.match(worker, /warningAfterSeconds: 240/);
  assert.match(worker, /expiresAfterSeconds: 300/);
  assert.match(worker, /maxToolCalls: 12/);
  assert.match(config, /"max_instances": 10/);
});

test('the funded demo fallback is server-side, synthetic-only, and uses the exact visible tools', async () => {
  const worker = await read('src/index.ts');
  const config = await read('wrangler.jsonc');
  assert.match(worker, /OPENAI_API_KEY\?: string/);
  assert.match(worker, /payload\.access !== 'demo'/);
  assert.match(worker, /env\.DEMO_REALTIME_MODEL \|\| 'gpt-realtime-2\.1-mini'/);
  assert.match(worker, /toolManifest\.map/);
  assert.match(worker, /parallel_tool_calls: false/);
  assert.match(worker, /max_output_tokens: 512/);
  assert.match(worker, /OpenAI-Safety-Identifier/);
  assert.match(worker, /https:\/\/api\.openai\.com\/v1\/realtime\/calls/);
  assert.match(worker, /\/hangup/);
  assert.match(worker, /synthetic workspace visible in the current browser tab/);
  assert.match(config, /"DEMO_REALTIME_MODEL": "gpt-realtime-2\.1-mini"/);
});

test('Linux Codex conversations are saved, encrypted, listed, and resumable', async () => {
  const worker = await read('src/index.ts');
  const server = await read('container/server.mjs');
  assert.match(server, /ephemeral: false/);
  assert.match(server, /this\.request\('thread\/resume'/);
  assert.match(server, /this\.request\('thread\/list'/);
  assert.match(server, /sourceKinds: \['appServer'\]/);
  assert.match(server, /normalized\.startsWith\('sessions\/'\)/);
  assert.match(server, /normalized\.startsWith\('archived_sessions\/'\)/);
  assert.doesNotMatch(server, /memories\//);
  assert.match(worker, /codex-thread-state\/\$\{userHash\}\.enc/);
  assert.match(worker, /encryptAuth\(snapshot, env\.VOICE_AUTH_ENCRYPTION_KEY\)/);
  assert.match(worker, /override async onActivityExpired/);
  assert.match(worker, /await this\.checkpointThreadState\(\)/);
});

test('voice socket authorization stays out of URLs and logs', async () => {
  const worker = await read('src/index.ts');
  const site = await read('../../apps/workspace-site/app/components/workspace-app.tsx');
  assert.match(worker, /sec-websocket-protocol/);
  assert.match(worker, /toolSocketToken: socketToken/);
  assert.doesNotMatch(worker, /searchParams\.set\(['"]token/);
  assert.doesNotMatch(worker, /new URLSearchParams\(\{ token:/);
  assert.match(site, /openassist-token\.\$\{body\.toolSocketToken\}/);
});
