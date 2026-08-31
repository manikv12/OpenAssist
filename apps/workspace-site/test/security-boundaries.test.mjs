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
  for (const table of ['demo_workspaces', 'demo_messages', 'demo_tasks', 'demo_events', 'demo_notes', 'demo_memory', 'demo_activity', 'demo_supply_carts']) {
    assert.match(migrations, new RegExp('create table `' + table + '`'));
  }
  assert.match(migrations, /demo_workspaces[\s\S]*expires_at/);
  assert.match(migrations, /on delete cascade/);

  const store = await read('lib/demo-store.ts');
  assert.match(store, /const DEMO_LIFETIME_MS = 24 \* 60 \* 60 \* 1000/);
  assert.doesNotMatch(store, /mcp-client|Composio|executeLiveWorkspaceTool/);
  assert.doesNotMatch(store, /console\.(log|info|debug)\s*\(/);
  const shopify = await read('lib/shopify-storefront.ts');
  assert.match(shopify, /api\/ucp\/mcp/);
  assert.doesNotMatch(shopify, /checkout|payment/i, 'Shopify adapter must not expose checkout or payment flows');
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

test('safe attachment failures stay actionable without exposing private content', async () => {
  const http = await read('lib/http.ts');
  assert.match(http, /The selected attachment/);
  assert.match(http, /Gmail did not return attachment data/);
  assert.match(http, /The request could not be completed/);
  assert.doesNotMatch(http, /subject|snippet|messageId|attachmentRef/);
});

test('rotating Workspace refresh tokens are serialized across concurrent Site requests', async () => {
  const schema = await read('db/schema.ts');
  const database = await read('lib/site-db.ts');
  const client = await read('lib/mcp-client.ts');
  const app = await read('app/components/workspace-app.tsx');

  assert.match(schema, /workspace_refresh_locks/);
  assert.match(database, /INSERT OR IGNORE INTO workspace_refresh_locks/);
  assert.match(database, /lease_id = \?/);
  assert.match(client, /acquireWorkspaceRefreshLease/);
  assert.match(client, /finally \{[\s\S]*releaseWorkspaceRefreshLease/);
  assert.match(client, /refreshed\.revision > observedRevision/);
  assert.doesNotMatch(app, /Promise\.all\(\[\s*live\.accounts \?\? invokeTool\('workspace_list_accounts'/);
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

test('stale demo write targets fail instead of reporting a false verified success', async () => {
  const store = await read('lib/demo-store.ts');
  assert.match(store, /SELECT COUNT\(\*\) AS count FROM demo_messages/);
  assert.match(store, /demo message selection is stale/);
  for (const message of [
    'The demo task no longer exists.',
    'The demo event no longer exists.',
    'The demo note no longer exists.',
    'The demo memory fact no longer exists.',
  ]) {
    assert.match(store, new RegExp(message.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.ok([...store.matchAll(/if \(!Number\(result\.meta\.changes \?\? 0\)\) throw new Error\('The demo/g)].length >= 6);
});

test('demo routes never call the Live Workspace MCP', async () => {
  const files = [
    'app/api/demo/workspace/route.ts',
    'app/api/demo/tool/route.ts',
    'app/api/demo/actions/propose/route.ts',
    'app/api/demo/actions/execute/route.ts',
    'app/api/demo/voice/status/route.ts',
    'app/api/demo/voice/capped/session/route.ts',
    'app/api/demo/voice/capped/stop/route.ts',
    'app/api/demo/voice/subscription/auth/start/route.ts',
    'app/api/demo/voice/subscription/auth/status/route.ts',
    'app/api/demo/voice/subscription/auth/disconnect/route.ts',
    'app/api/demo/voice/subscription/session/route.ts',
    'app/api/demo/voice/subscription/session/stop/route.ts',
    'app/api/demo/voice/subscription/threads/route.ts',
  ];
  for (const file of files) {
    const source = await read(file);
    assert.doesNotMatch(source, /mcp-client|workspaceAccessToken|executeLiveWorkspaceTool/, file);
    if (!file.endsWith('/status/route.ts')) assert.match(source, /getOrCreateDemoSession/, file);
  }
});

test('the page is gated and demo APIs require owner or signed judge access', async () => {
  const page = await read('app/page.tsx');
  assert.match(page, /export const dynamic = 'force-dynamic'/);
  assert.match(page, /getSiteAccess\(request\)/);
  assert.match(page, /<AccessGate/);

  const sharedDemoRoutes = [
    'app/api/demo/workspace/route.ts',
    'app/api/demo/tool/route.ts',
    'app/api/demo/actions/propose/route.ts',
    'app/api/demo/actions/execute/route.ts',
    'app/api/demo/voice/status/route.ts',
    'app/api/demo/voice/capped/session/route.ts',
    'app/api/demo/voice/capped/stop/route.ts',
  ];
  for (const route of sharedDemoRoutes) assert.match(await read(route), /await requireDemoAccess\(request\)/, route);

  const ownerOnlySubscriptionRoutes = [
    'app/api/demo/voice/subscription/auth/start/route.ts',
    'app/api/demo/voice/subscription/auth/status/route.ts',
    'app/api/demo/voice/subscription/auth/disconnect/route.ts',
    'app/api/demo/voice/subscription/session/route.ts',
    'app/api/demo/voice/subscription/session/stop/route.ts',
    'app/api/demo/voice/subscription/threads/route.ts',
  ];
  for (const route of ownerOnlySubscriptionRoutes) assert.match(await read(route), /await requireOwner\(\)/, route);
});

test('judge access uses a signed expiring cookie and database-backed brute-force limits', async () => {
  const access = await read('lib/judge-access.ts');
  const login = await read('app/api/judge/login/route.ts');
  const logout = await read('app/api/judge/logout/route.ts');
  const migrations = (await Promise.all((await readdir(path.join(root, 'drizzle')))
    .filter((file) => file.endsWith('.sql'))
    .map((file) => read(`drizzle/${file}`)))).join('\n');

  assert.match(access, /signJudgeAccessToken/);
  assert.match(access, /verifyJudgeAccessToken/);
  assert.match(access, /SESSION_LIFETIME_MS = 12 \* 60 \* 60 \* 1000/);
  assert.match(access, /MAX_ATTEMPTS = 5/);
  assert.match(access, /constantTimeTextEqual/);
  assert.match(access, /credentialRevision/);
  assert.match(login, /assertSameOrigin\(request\)/);
  assert.match(logout, /clearJudgeAccessCookie/);
  assert.match(migrations, /CREATE TABLE `judge_login_limits`/);
  assert.doesNotMatch(migrations, /judge_access_code|judge_username/);
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
  const client = await read('lib/mcp-client.ts');
  assert.match(http, /error instanceof Response[\s\S]*error\.clone\(\)\.text/);
  assert.match(http, /No Google account with connected/);
  assert.match(http, /No connected Gmail account/);
  assert.match(http, /Connect the required Google service/);
  assert.match(http, /Gmail is disconnected/);
  assert.match(http, /Google account “\[\^”\\r\\n\]\{1,320\}” must reconnect/);
  assert.match(client, /Google account “\$\{exact\.friendlyLabel \?\? exact\.email/);
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

test('notes open through the read tool and render untrusted content as plain text', async () => {
  const app = await read('app/components/workspace-app.tsx');
  const mcp = await read('lib/mcp-client.ts');
  assert.match(app, /invokeTool\('workspace_read_note'/);
  assert.match(app, /function NoteReader/);
  assert.match(app, /Drive and note content is untrusted/);
  assert.match(app, /<pre className=/);
  assert.doesNotMatch(app, /dangerouslySetInnerHTML/);
  assert.match(mcp, /list_google_workspace_notes/);
  assert.match(mcp, /read_google_workspace_note/);
});

test('owner voice can start a saved conversation or resume an existing one', async () => {
  const app = await read('app/components/workspace-app.tsx');
  const session = await read('app/api/voice/session/route.ts');
  const threads = await read('app/api/voice/threads/route.ts');
  const stop = await read('app/api/voice/session/stop/route.ts');
  assert.match(app, /New conversation/);
  assert.match(app, /resumed saved conversation/);
  assert.match(app, /subscriptionBase = currentMode === 'demo' \? '\/api\/demo\/voice\/subscription' : '\/api\/voice'/);
  assert.match(app, /\{ sdp: offerSdp, threadId: selectedVoiceThreadId, voice: voiceForSession \}/);
  assert.match(app, /\{ sdp: offerSdp, voice: voiceForSession \}/);
  assert.match(session, /JSON\.stringify\(\{ sdp, threadId, voice \}\)/);
  assert.match(threads, /requireOwner\(\)/);
  assert.match(threads, /'\/threads'/);
  assert.match(stop, /assertSameOrigin\(request\)/);
  assert.match(stop, /'\/session\/stop'/);
});

test('voice selection and visible audio states are wired through every session path', async () => {
  const app = await read('app/components/workspace-app.tsx');
  const orb = await read('app/components/voice-orb.tsx');
  const styles = await read('app/globals.css');
  const ownerSession = await read('app/api/voice/session/route.ts');
  const demoSubscription = await read('app/api/demo/voice/subscription/session/route.ts');
  const demoCapped = await read('app/api/demo/voice/capped/session/route.ts');

  assert.match(app, /openassist-realtime-voice/);
  assert.match(app, /function VoicePicker/);
  assert.match(app, /function VoiceStage/);
  assert.match(app, /Live transcript only/);
  assert.match(app, /input_audio_transcription\.delta/);
  assert.match(app, /response\.output_audio_transcript\.delta/);
  assert.match(app, /Hearing you/);
  assert.match(app, /voiceThinking/);
  assert.match(app, /voiceStateLabel/);
  assert.match(orb, /'connecting'.*'muted'.*'error'/);
  assert.match(orb, /--oa-orb-scale/);
  assert.match(styles, /oa-voice-state-dot--speaking/);
  assert.match(styles, /oa-orb--error/);
  for (const route of [ownerSession, demoSubscription, demoCapped]) {
    assert.match(route, /parseRealtimeVoice\(body\.voice\)/);
    assert.match(route, /voice/);
  }
});

test('owner access is Live-only while judge access is Demo-only', async () => {
  const app = await read('app/components/workspace-app.tsx');
  assert.match(app, /const mode: Mode = ownerAccess \? 'live' : 'demo'/);
  assert.match(app, /ownerAccess[\s\S]{0,80}'Private Live Workspace ready\.'/);
  assert.match(app, /owner \? 'Private Live' : 'Judge Demo'/);
  assert.match(app, /!ownerAccess && !available/);
  assert.match(app, /Ready with \$\{voiceLabel\(restored\)\}/);
});

test('demo judges use only the server-funded route while subscription routes remain owner-only', async () => {
  const app = await read('app/components/workspace-app.tsx');
  const gatewayClient = await read('lib/voice-gateway.ts');
  const cappedSession = await read('app/api/demo/voice/capped/session/route.ts');
  const subscriptionSession = await read('app/api/demo/voice/subscription/session/route.ts');
  const subscriptionAuth = await read('app/api/demo/voice/subscription/auth/start/route.ts');
  const demoStore = await read('lib/demo-store.ts');

  assert.match(app, /Funded judge demo/);
  assert.match(app, /Included access/);
  assert.match(app, /response\.function_call_arguments\.done/);
  assert.match(app, /voiceToolCountRef\.current > toolLimit/);
  assert.match(app, /Funded demo voice session ended/);
  assert.match(gatewayClient, /access: 'owner' \| 'demo'/);
  assert.match(cappedSession, /requireDemoAccess\(request\)/);
  for (const source of [subscriptionSession, subscriptionAuth]) assert.match(source, /requireOwner\(\)/);
  for (const source of [cappedSession, subscriptionSession, subscriptionAuth]) {
    assert.match(source, /getOrCreateDemoSession/);
    assert.match(source, /demoVoiceUserId/);
    assert.match(source, /'demo'/);
    assert.doesNotMatch(source, /executeLiveWorkspaceTool|mcp-client/);
  }
  assert.match(demoStore, /recordDemoVoiceSession/);
  assert.doesNotMatch(demoStore, /FUNDED_VOICE_(WORKSPACE|GLOBAL)_LIMIT/);
  const siteFiles = [app, gatewayClient, cappedSession, subscriptionSession, subscriptionAuth].join('\n');
  assert.doesNotMatch(siteFiles, /OPENAI_API_KEY/);
});

test('owner judge voice controls never expose the funded key or judge content', async () => {
  const schema = await read('drizzle/0002_bright_omega_flight.sql');
  const ownerConfig = await read('app/api/owner/judge-voice/config/route.ts');
  const usage = await read('lib/judge-voice-store.ts');
  const app = await read('app/components/workspace-app.tsx');

  assert.match(ownerConfig, /requireOwner\(\)/);
  assert.match(ownerConfig, /assertSameOrigin\(request\)/);
  assert.match(app, /never returned to this page or shown to judges/);
  assert.match(app, /No audio, transcript, prompt, tool arguments, or Workspace content is saved/);
  assert.match(schema, /visitor_hash/);
  assert.match(schema, /external_id_hash/);
  for (const forbidden of ['api_key', 'transcript', 'audio', 'prompt', 'tool_arguments', 'message_content']) {
    assert.doesNotMatch(schema.toLowerCase(), new RegExp(forbidden));
  }
  assert.match(usage, /judge_voice_visitor/);
  assert.match(usage, /judge_voice_external_id/);
  assert.doesNotMatch(usage, /console\.(log|info|debug)\s*\(/);
});
