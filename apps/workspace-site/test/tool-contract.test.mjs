import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

async function text(relativePath) {
  return readFile(path.join(root, relativePath), 'utf8');
}

test('the website registers the complete 43-tool Workspace contract', async () => {
  const contract = JSON.parse(await text('test/tool-names.json'));
  const registry = await text('lib/tool-registry.ts');
  const registered = [...registry.matchAll(/name: '(workspace_[a-z_]+)'/g)].map((match) => match[1]);

  assert.equal(contract.length, 43);
  assert.deepEqual(registered, contract);
  assert.equal(new Set(contract).size, contract.length);
});

test('WebMCP annotations and visible approval previews are always registered', async () => {
  const component = await text('app/components/workspace-app.tsx');
  assert.match(component, /readOnlyHint: tool\.readOnly/);
  assert.match(component, /untrustedContentHint: tool\.untrustedContent/);
  assert.match(component, /status: 'approval_required'/);
  assert.match(component, /A visible preview is open/);
  assert.match(component, /Voice confirmation cannot approve it/);
});

test('judge readiness reports only the tools exposed in judge mode', async () => {
  const component = await text('app/components/workspace-app.tsx');
  assert.match(component, /Judge Demo ready · \$\{webMcpTools\.length\} WebMCP tools available\./);
  assert.doesNotMatch(component, /Judge Demo ready · \$\{WORKSPACE_TOOLS\.length\}/);
});

test('mail attachment tools accept the opaque references returned by message reads', async () => {
  const registry = await text('lib/tool-registry.ts');
  const client = await text('lib/mcp-client.ts');
  const attachmentTool = registry.slice(
    registry.indexOf("name: 'workspace_read_mail_attachment'"),
    registry.indexOf("name: 'workspace_set_mail_read_state'"),
  );

  assert.match(attachmentTool, /Opaque attachment reference from message metadata/);
  assert.match(attachmentTool, /4_096/);
  assert.doesNotMatch(attachmentTool, /attachmentId: id\(/);
  assert.match(client, /attachmentRef: args\.attachmentId,[\s\S]*filename: args\.filename/);
});

test('calendar reads use the saved calendar-default account when none is supplied', async () => {
  const client = await text('lib/mcp-client.ts');
  const calendarRead = client.slice(
    client.indexOf("if (name === 'workspace_list_calendar')"),
    client.indexOf("if (name === 'workspace_create_calendar_event')"),
  );

  assert.match(calendarRead, /resolveAccount\(accessToken, args\.account, 'calendar', requestCall\)/);
  assert.match(calendarRead, /accounts: \[account\]/);
  assert.doesNotMatch(calendarRead, /args\.account \? \[args\.account\]/);
});

test('live task updates keep tags and live note queries filter returned note titles', async () => {
  const client = await text('lib/mcp-client.ts');
  const taskUpdate = client.slice(
    client.indexOf("name === 'workspace_update_task'"),
    client.indexOf("name === 'workspace_delete_task'"),
  );
  assert.match(taskUpdate, /tags: args\.tags/);

  const notes = client.slice(
    client.indexOf("name === 'workspace_list_notes'"),
    client.indexOf("name === 'workspace_read_note'"),
  );
  assert.match(notes, /args\.query\.trim\(\)\.toLowerCase\(\)/);
  assert.match(notes, /String\(note\.title \?\? ''\)\.toLowerCase\(\)\.includes\(query\)/);
});

test('demo and owner Live mode remain separate', async () => {
  const component = await text('app/components/workspace-app.tsx');
  assert.match(component, /modeRef\.current === 'demo'/);
  assert.match(component, /Private synthetic judge workspace · no Google data/);
  assert.match(component, /ownerAccess &&/);
  assert.match(component, /Judge · isolated Demo only/);
  assert.match(component, /\/api\/demo\/tool/);
  assert.match(component, /\/api\/workspace\/tool/);
  assert.match(component, /\/api\/demo\/voice\/capped\/session/);
  assert.match(component, /\/api\/demo\/voice\/subscription/);
  assert.match(component, /currentMode === 'live' \|\| currentAccess === 'subscription'/);
  assert.match(component, /Reset demo/);
  assert.match(component, /ItemEditor/);
  assert.match(component, /workspace_create_task/);
  assert.match(component, /workspace_save_note/);
  assert.match(component, /workspace_search_supplies/);
  assert.match(component, /workspace_update_supply_cart/);
});

test('Shopify results render real images and show the two separate demo paths', async () => {
  const component = await text('app/components/workspace-app.tsx');
  const demoData = await text('lib/demo-data.ts');
  const storefront = await text('lib/shopify-storefront.ts');

  assert.match(component, /Demo video · fixed story/);
  assert.match(component, /Judge test · free sandbox/);
  assert.match(component, /product\.imageUrl/);
  assert.match(component, /alt=\{`\$\{product\.title\} product`\}/);
  assert.equal([...demoData.matchAll(/imageUrl: '\/catalog\/[a-z0-9-]+\.webp'/g)].length, 6);
  assert.match(storefront, /imageUrl: textValue\(image\.url \?\? image\.src\) \|\| curated\?\.imageUrl/);
});

test('live reads reuse one MCP session and ignore disconnected automatic-search accounts', async () => {
  const client = await text('lib/mcp-client.ts');
  assert.match(client, /function createWorkspaceMcpCaller/);
  assert.match(client, /initializedPromise \?\?= initialize\(\)/);
  assert.match(client, /const requestCall = createWorkspaceMcpCaller\(accessToken\)/);

  const brief = client.slice(
    client.indexOf("name === 'workspace_get_daily_brief'"),
    client.indexOf("name === 'workspace_search_mail'"),
  );
  assert.match(brief, /includedInAutomaticSearch !== false/);
  assert.match(brief, /supportsService\(account, 'search'\)/);
  assert.match(brief, /accounts: mailAccounts/);
  assert.doesNotMatch(brief, /accounts: args\.account \? \[args\.account\] : undefined/);
});

test('owner workspace removes stale date and fake Live activity, and filters loaded rows', async () => {
  const component = await text('app/components/workspace-app.tsx');
  assert.doesNotMatch(component, /Thursday · August 27/);
  assert.match(component, /ownerAccess \? \[\] : DEMO_ACTIVITY/);
  assert.match(component, /Object\.values\(item\)\.some/);
  assert.match(component, /placeholder=\{view === 'work' \? 'Use Knowledge search below' : 'Filter this view'\}/);
  assert.match(component, /function LiveTodayDashboard/);
  assert.match(component, /function WorkspaceLoading/);
});

test('WebMCP focus opens cached search results and never claims a missing item opened', async () => {
  const component = await text('app/components/workspace-app.tsx');
  assert.match(component, /const toolRowsRef = useRef/);
  assert.match(component, /if \(rows\.length > 0\) toolRowsRef\.current\[resultView\] = rows/);
  assert.match(component, /let opened = false/);
  assert.match(component, /return \{ status: 'focused', view: nextView, itemId: resolvedItemId \?\? null, opened \}/);
  assert.doesNotMatch(component, /opened: Boolean\(resolvedItemId\)/);
});

test('voice failures return an error and approved Live writes refresh the affected view', async () => {
  const component = await text('app/components/workspace-app.tsx');
  assert.match(component, /openassist:site-tool-result[\s\S]*requestId: detail\.requestId, error: message/);
  assert.match(component, /const updatedView = viewForTool\(action\.tool\)/);
  assert.match(component, /focusView\(updatedView, itemId\)[\s\S]*setLiveRefreshKey/);
});

test('initial Live loading reuses the account ref and navigation clears stale filters', async () => {
  const component = await text('app/components/workspace-app.tsx');
  assert.match(component, /setSearch\(''\)/);
  assert.match(component, /const accountsPromise = liveRef\.current\.accounts/);
  assert.doesNotMatch(component, /\[invokeTool, live\.accounts, liveRefreshKey/);
  assert.match(component, /No connected Gmail account\|Connect the required Google service\|Gmail is disconnected/);
  assert.match(component, /<JudgeQuickStart onNavigate=\{focusView\} toolCount=\{webMcpTools\.length\}/);
});

test('daily brief limits unread metadata work while keeping every enabled account', async () => {
  const client = await text('lib/mcp-client.ts');
  assert.match(client, /get_google_mail_attention', \{ accounts: mailAccounts, maxPerAccount: 2 \}/);
  assert.match(client, /includedInAutomaticSearch !== false/);
});
