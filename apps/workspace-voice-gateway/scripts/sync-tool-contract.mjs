import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import ts from 'typescript';

const appRoot = process.cwd();
const repoRoot = path.resolve(appRoot, '../..');
const registryPath = path.join(repoRoot, 'apps/workspace-site/lib/tool-registry.ts');
const source = await readFile(registryPath, 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.ESNext,
    target: ts.ScriptTarget.ES2022,
  },
  fileName: registryPath,
}).outputText;
const moduleUrl = `data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`;
const imported = await import(moduleUrl);
const tools = imported.WORKSPACE_TOOLS;

if (!Array.isArray(tools) || tools.length === 0) {
  throw new Error('The Site Workspace tool registry could not be loaded.');
}

const manifest = tools.map((tool) => ({
  name: tool.name,
  title: tool.title,
  description: tool.description,
  inputSchema: tool.inputSchema,
  readOnly: Boolean(tool.readOnly),
  untrustedContent: Boolean(tool.untrustedContent),
  destructive: Boolean(tool.destructive),
}));
const names = manifest.map((tool) => tool.name);

for (const tool of manifest) {
  if (!/^workspace_[a-z0-9_]+$/.test(tool.name)) throw new Error(`Invalid Workspace tool name: ${tool.name}`);
  if (!tool.description || tool.inputSchema?.type !== 'object') throw new Error(`Incomplete Workspace tool contract: ${tool.name}`);
}
if (new Set(names).size !== names.length) throw new Error('Workspace tool names must be unique.');

const outputs = [
  [path.join(appRoot, 'container/tool-manifest.json'), manifest],
  [path.join(appRoot, 'container/tool-names.json'), names],
  [path.join(repoRoot, 'packages/workspace-tool-contract/tool-manifest.json'), manifest],
  [path.join(repoRoot, 'packages/workspace-tool-contract/tool-names.json'), names],
];

for (const [outputPath, value] of outputs) {
  await writeFile(outputPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

console.log(`Synced ${manifest.length} Workspace tools from ${pathToFileURL(registryPath).pathname}.`);
