import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

async function text(relativePath) {
  return readFile(path.join(root, relativePath), 'utf8');
}

test('Second Brain is an owner-only Work view with the five intended sections', async () => {
  const shell = await text('app/components/workspace-app.tsx');
  const work = await text('app/components/second-brain-workspace.tsx');

  assert.match(shell, /view: 'work'.*ownerOnly: true/);
  assert.match(shell, /ownerAccess \? NAVIGATION\.filter\(\(item\) => !item\.demoOnly\)/);
  assert.match(shell, /NAVIGATION\.filter\(\(item\) => !item\.ownerOnly\)/);
  for (const label of ['Capture', 'Projects', 'Knowledge', 'Agent work', 'Memory sources']) {
    assert.match(work, new RegExp(`label: '${label}'`));
  }
  assert.match(work, /never conversation history/);
  assert.match(work, /Device IDs stay stable when a Mac is renamed/);
  assert.match(work, /Inbox — organize later/);
  assert.match(work, /stage: selectedProject \? 'backlog' : 'inbox'/);
  assert.match(work, /Organize captured ideas/);
  assert.match(work, /workspace_organize_inbox_item/);
  assert.match(work, /Add to Google Tasks/);
  assert.match(work, /In Google Tasks/);
  assert.match(work, /Google Tasks destination/);
  assert.match(work, /data-untrusted-knowledge/);
});

test('routine agent coordination follows policy while user and external writes still preview', async () => {
  const registry = await text('lib/tool-registry.ts');
  const shell = await text('app/components/workspace-app.tsx');
  const route = await text('app/api/workspace/tool/route.ts');

  for (const name of [
    'workspace_claim_agent_work',
    'workspace_renew_agent_work',
    'workspace_report_agent_progress',
    'workspace_submit_agent_result',
  ]) {
    const start = registry.indexOf(`name: '${name}'`);
    const end = registry.indexOf("\n  {", start + 1);
    assert.ok(start >= 0, `${name} is registered`);
    assert.match(registry.slice(start, end < 0 ? undefined : end), /approval: 'policy'/);
  }

  for (const name of ['workspace_create_project', 'workspace_capture_work_item', 'workspace_organize_inbox_item', 'workspace_promote_work_item_to_task', 'workspace_assign_work_item']) {
    const start = registry.indexOf(`name: '${name}'`);
    const end = registry.indexOf("\n  {", start + 1);
    assert.match(registry.slice(start, end < 0 ? undefined : end), /approval: 'always'/);
  }

  assert.match(shell, /!tool\.readOnly && tool\.approval !== 'policy'/);
  assert.match(route, /tool\.approval !== 'policy'/);
  assert.match(registry, /workspace_delete_task[\s\S]*?destructive: true/);
  assert.doesNotMatch(registry.slice(registry.indexOf("name: 'workspace_delete_task'"), registry.indexOf("name: 'workspace_list_calendar'")), /approval: 'policy'/);
  const search = registry.slice(registry.indexOf("name: 'workspace_search_second_brain'"), registry.indexOf("name: 'workspace_list_agent_assignments'"));
  assert.match(search, /readOnly: true/);
  assert.match(search, /untrustedContent: true/);
  assert.match(search, /ownerOnly: true/);
});

test('live adapter maps the Site tools to Drive-backed Second Brain MCP tools', async () => {
  const client = await text('lib/mcp-client.ts');
  const registry = await text('lib/tool-registry.ts');
  const work = await text('app/components/second-brain-workspace.tsx');
  for (const tool of [
    'list_second_brain_projects',
    'list_second_brain_assignments',
    'read_second_brain_project',
    'search_second_brain_knowledge',
    'capture_second_brain_work_item',
    'organize_second_brain_work_item',
    'promote_second_brain_work_item_to_google_task',
    'assign_second_brain_work_item',
    'claim_second_brain_work',
    'claim_next_second_brain_work',
    'renew_second_brain_work_lease',
    'report_second_brain_progress',
    'requeue_second_brain_needs_user',
    'submit_second_brain_result',
    'list_second_brain_memory_sources',
  ]) {
    assert.match(client, new RegExp(`'${tool}'`));
  }
  assert.match(client, /acceptancePassed: args\.acceptancePassed === true/);
  assert.match(client, /needsUser: args\.needsUser === true/);
  const search = client.slice(client.indexOf("name === 'workspace_search_second_brain'"), client.indexOf("name === 'workspace_create_project'"));
  assert.match(search, /sourceKinds: args\.sourceKinds/);
  assert.match(search, /maxScanned: args\.maxScanned/);
  assert.doesNotMatch(search, /projectId/);
  const promotion = client.slice(client.indexOf("name === 'workspace_promote_work_item_to_task'"), client.indexOf("name === 'workspace_assign_work_item'"));
  assert.match(promotion, /userConfirmed: true/);
  assert.match(promotion, /resolveAccount\(accessToken, args\.account, 'tasks', requestCall\)/);
  assert.match(promotion, /stableSiteAttemptKey\('site-promote-work-item'\)/);
  assert.doesNotMatch(promotion, /await taskListId/);

  const promotionTool = registry.slice(registry.indexOf("name: 'workspace_promote_work_item_to_task'"), registry.indexOf("name: 'workspace_assign_work_item'"));
  assert.match(promotionTool, /\['workItemId', 'account', 'taskListId', 'title'\]/);
  assert.match(work, /disabled=\{saving \|\| !taskAccount \|\| !effectiveTaskListId/);
  assert.match(work, /onPromote\(\{ workItemId: itemId, account: taskAccount, taskListId: effectiveTaskListId, title \}\)/);
});

test('work dashboard preserves every project and work item returned by its bounded MCP queries', async () => {
  const client = await text('lib/mcp-client.ts');
  const dashboard = client.slice(
    client.indexOf("name === 'workspace_get_work_dashboard'"),
    client.indexOf("name === 'workspace_search_second_brain'"),
  );
  assert.match(dashboard, /list_second_brain_projects', \{ limit: 25 \}/);
  assert.match(dashboard, /list_second_brain_work_items'.*limit: 50/s);
  assert.match(dashboard, /mapWithConcurrency\(visibleProjectRows, 3/);
  assert.match(dashboard, /mapWithConcurrency\(workRows, 3/);
  assert.doesNotMatch(dashboard, /projectRows\.slice\(0, 8\)/);
  assert.doesNotMatch(dashboard, /workRows\.slice\(0, 20\)/);
});

test('owner UI routes queued and resumed work to the exact orchestrator', async () => {
  const work = await text('app/components/second-brain-workspace.tsx');
  assert.match(work, /const OWNER_AGENT_ID = 'openassist\.owner\.orchestrator'/);
  assert.match(work, /agentId: OWNER_AGENT_ID, agentLabel: 'OpenAssist Agent'/);
  assert.match(work, /textValue\(run, \['agentId', 'assignedAgentId'\], OWNER_AGENT_ID\)/);
  assert.doesNotMatch(work, /'openassist-agent'/);
});
