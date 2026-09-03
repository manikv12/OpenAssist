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
    demoOnly: Boolean(tool.demoOnly),
    ownerOnly: Boolean(tool.ownerOnly),
    approval: tool.approval ?? 'always',
  }));
  assert.deepEqual(voice, shared);
  assert.deepEqual(voiceManifest, sharedManifest);
  assert.deepEqual(voiceManifest, siteManifest);
  assert.deepEqual(voiceManifest.map((tool) => tool.name), voice);
  assert.equal(voice.length, 43);

  const ownerTools = voiceManifest.filter((tool) => !tool.demoOnly).map((tool) => tool.name);
  const demoTools = voiceManifest.filter((tool) => !tool.ownerOnly).map((tool) => tool.name);
  const secondBrainTools = voiceManifest.filter((tool) => tool.ownerOnly).map((tool) => tool.name);
  assert.deepEqual(secondBrainTools, [
    'workspace_get_work_dashboard',
    'workspace_search_second_brain',
    'workspace_list_agent_assignments',
    'workspace_create_project',
    'workspace_capture_work_item',
    'workspace_organize_inbox_item',
    'workspace_promote_work_item_to_task',
    'workspace_assign_work_item',
    'workspace_claim_agent_work',
    'workspace_claim_next_agent_work',
    'workspace_renew_agent_work',
    'workspace_report_agent_progress',
    'workspace_resume_agent_work',
    'workspace_submit_agent_result',
  ]);
  assert.ok(secondBrainTools.every((name) => ownerTools.includes(name)));
  assert.ok(secondBrainTools.every((name) => !demoTools.includes(name)));
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
  assert.match(server, /this\.session\.toolManifest\.map/);
  assert.match(server, /toolManifest\.filter\(\(tool\) => this\.access === 'owner' \? !tool\.demoOnly : !tool\.ownerOnly\)/);
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

test('revoked subscription auth is removed and requires a clear reconnect', async () => {
  const worker = await read('src/index.ts');
  assert.match(worker, /token_revoked\|invalidated oauth token/);
  assert.match(worker, /payload\.access === 'owner'\) await deleteOwnerAndDemoAuth\(env, payload, objectKey\)/);
  assert.match(worker, /else await env\.VOICE_AUTH\.delete\(objectKey\)/);
  assert.match(worker, /ChatGPT subscription sign-in expired\. Reconnect ChatGPT to continue\./);
  assert.match(worker, /Included judge voice needs the owner to reconnect ChatGPT\./);
});

test('judge voice reuses the owner container while chats and tools stay isolated', async () => {
  const worker = await read('src/index.ts');
  const server = await read('container/server.mjs');
  assert.match(worker, /DEMO_SUBSCRIPTION_AUTH_OBJECT_KEY\?: string/);
  assert.match(worker, /function subscriptionAuthObjectKey/);
  assert.match(worker, /function subscriptionContainerUserHash/);
  assert.match(worker, /function configuredDemoSubscriptionAuthObjectKey/);
  assert.match(worker, /mirrorStoredOwnerAuthForDemo\(env, payload, objectKey\)/);
  assert.match(worker, /mirrorOwnerAuthForDemo\(env, payload, result\.authJson\)/);
  assert.match(worker, /deleteOwnerAndDemoAuth\(env, payload, objectKey\)/);
  assert.match(worker, /payload\.access !== 'demo'/);
  assert.match(worker, /subscriptionAuthObjectKey\(env, payload\)/);
  assert.match(worker, /voiceContainer\(env, subscriptionContainerUserHash\(env, payload\)\)/);
  assert.match(worker, /const containerUserHash = subscriptionContainerUserHash\(env, payload\)/);
  assert.match(worker, /payload\.access === 'owner'\) await restoreThreadState\(container, env, containerUserHash\)/);
  assert.match(worker, /payload\.access === 'demo'\) return json\(\{ status: 'ready', threads: \[\] \}\)/);
  assert.match(worker, /Judge voice always starts a private temporary conversation/);
  assert.match(worker, /containerJson\(container, env, '\/session\/stop', \{ sessionId \}\)/);
  assert.match(server, /this\.access === 'owner' \? !tool\.demoOnly : !tool\.ownerOnly/);
  assert.match(server, /ephemeral: this\.session\.access === 'demo'/);
  assert.match(server, /sessionId === activeSessionId/);
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
  assert.match(worker, /DEFAULT_DEMO_SECONDS = 300/);
  assert.match(worker, /DEFAULT_DEMO_TOOL_LIMIT = 12/);
  assert.match(worker, /warningAfterSeconds: Math\.max\(30, funding\.sessionSeconds - 60\)/);
  assert.match(worker, /expiresAfterSeconds: funding\.sessionSeconds/);
  assert.match(worker, /maxToolCalls: funding\.maxToolCalls/);
  assert.match(config, /"max_instances": 10/);
});

test('the selected realtime voice reaches both subscription and funded sessions', async () => {
  const worker = await read('src/index.ts');
  const server = await read('container/server.mjs');
  const options = JSON.parse(await read('container/realtime-voices.json'));

  assert.deepEqual(options.map((voice) => voice.id), ['marin', 'cedar', 'coral', 'sage', 'verse', 'ash', 'sol']);
  assert.match(worker, /parseRealtimeVoice\(body\.voice\)/);
  assert.match(worker, /voice === 'sol'/);
  assert.match(worker, /output: \{ voice \}/);
  assert.match(server, /startRealtime\(offerSdp, requestedThreadId = null, voice = defaultRealtimeVoice\)/);
  assert.match(server, /outputModality: 'audio',[\s\S]{0,80}voice,/);
});

test('Codex realtime transcripts are forwarded to the visible Site voice panel', async () => {
  const server = await read('container/server.mjs');
  assert.match(server, /thread\/realtime\/started/);
  assert.match(server, /thread\/realtime\/transcript\/delta/);
  assert.match(server, /thread\/realtime\/transcript\/done/);
  assert.match(server, /thread\/realtime\/error/);
  assert.match(server, /type: 'transcript'/);
  assert.match(server, /waiter\.reject\(new Error\(errorMessage\)\)/);
  assert.match(server, /realtimeSessionId: null/);
  assert.match(server, /Realtime started without a session ID/);
});

test('the funded demo fallback is server-side, synthetic-only, and uses the exact visible tools', async () => {
  const worker = await read('src/index.ts');
  const config = await read('wrangler.jsonc');
  assert.match(worker, /OPENAI_API_KEY\?: string/);
  assert.match(worker, /payload\.access !== 'demo'/);
  assert.match(worker, /env\.DEMO_REALTIME_MODEL \|\| 'gpt-realtime-2\.1-mini'/);
  assert.match(worker, /toolManifest\.filter\(\(tool\) => !tool\.ownerOnly\)\.map/);
  assert.match(worker, /parallel_tool_calls: false/);
  assert.match(worker, /max_output_tokens: 512/);
  assert.match(worker, /OpenAI-Safety-Identifier/);
  assert.match(worker, /https:\/\/api\.openai\.com\/v1\/realtime\/calls/);
  assert.match(worker, /\/hangup/);
  assert.match(worker, /synthetic workspace visible in the current browser tab/);
  assert.match(config, /"DEMO_REALTIME_MODEL": "gpt-realtime-2\.1-mini"/);
});

test('owner-funded judge voice settings are encrypted and never returned with the key', async () => {
  const worker = await read('src/index.ts');
  assert.match(worker, /DEMO_FUNDING_OBJECT_KEY = 'admin\/judge-voice-funding\.enc'/);
  assert.match(worker, /encryptAuth\(JSON\.stringify\(config\), env\.VOICE_AUTH_ENCRYPTION_KEY\)/);
  assert.match(worker, /payload\.access === 'owner'/);
  assert.match(worker, /url\.pathname === '\/admin\/demo-config'/);
  const publicStatus = worker.match(/function publicFundingStatus[\s\S]*?\n}/)?.[0] ?? '';
  assert.doesNotMatch(publicStatus, /apiKey/);
  assert.match(publicStatus, /keyConfigured/);
});

test('Linux Codex conversations are saved, encrypted, listed, and resumable', async () => {
  const worker = await read('src/index.ts');
  const server = await read('container/server.mjs');
  assert.match(server, /ephemeral: this\.session\.access === 'demo'/);
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
