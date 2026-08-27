import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

async function text(relativePath) {
  return readFile(path.join(root, relativePath), 'utf8');
}

test('the website registers the complete 23-tool Workspace contract', async () => {
  const contract = JSON.parse(await text('test/tool-names.json'));
  const registry = await text('lib/tool-registry.ts');
  const registered = [...registry.matchAll(/name: '(workspace_[a-z_]+)'/g)].map((match) => match[1]);

  assert.equal(contract.length, 23);
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

test('demo and owner Live mode remain separate', async () => {
  const component = await text('app/components/workspace-app.tsx');
  assert.match(component, /modeRef\.current === 'demo'/);
  assert.match(component, /Switch to owner Live mode first/);
  assert.match(component, /Public synthetic judge data\. No private content/);
});
