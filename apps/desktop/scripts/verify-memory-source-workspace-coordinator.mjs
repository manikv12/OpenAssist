import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  MemorySourceWorkspaceCoordinator,
  memorySourceFileSyncToolName,
  memorySourceStatusToolName
} from "../dist-electron/memorySourceWorkspaceCoordinator.js";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-memory-source-workspace-"));
process.on("exit", () => fs.rmSync(root, { recursive: true, force: true }));
const home = path.join(root, "home");
const codexRoot = path.join(home, ".codex", "memories");
const claudeRoot = path.join(home, ".claude");
const statePath = path.join(root, "state", "memory-sources.json");

function write(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content);
}

write(path.join(codexRoot, "MEMORY.md"), "# Codex index\nA safe preference.\n");
write(path.join(codexRoot, "sessions", "secret.md"), "must never sync\n");
write(path.join(claudeRoot, "projects", "openassist", "memory", "decision.md"), "# Decision\nUse Markdown.\n");
write(path.join(claudeRoot, "projects", "openassist", "memory", "skills", "SKILL.md"), "must never sync\n");

const calls = [];
let rejectFileSync = false;
const callWorkspaceTool = async (toolName, args) => {
  calls.push({ toolName, args });
  if (toolName === memorySourceFileSyncToolName) {
    if (rejectFileSync) return { ok: false, isError: true, resultText: "Workspace rejected the upload." };
    return { result: { file: { id: `file-${calls.length}`, webViewLink: `https://drive.example/file-${calls.length}` } } };
  }
  if (toolName === memorySourceStatusToolName) return { source: { id: `source-${args.sourceId}` } };
  throw new Error(`Unexpected tool: ${toolName}`);
};

let clock = Date.parse("2026-08-30T12:00:00.000Z");
const coordinator = (machineName) => new MemorySourceWorkspaceCoordinator({
  statePath,
  machineID: "stable-device-123",
  machineName,
  homeDir: home,
  codexRoot,
  claudeRoot,
  now: () => new Date(clock),
  callWorkspaceTool
});

const studioCoordinator = coordinator("Studio Mac");
const preview = studioCoordinator.preview();
assert.equal(preview.changed.length, 2);
assert.equal(preview.unchangedCount, 0);
assert.deepEqual(preview.counts, { codex: 1, claude: 1 });
assert.equal(JSON.stringify(preview).includes(home), false, "preview must not expose absolute local paths");
assert.equal(JSON.stringify(preview).includes("must never sync"), false);

const synced = await studioCoordinator.sync();
assert.equal(synced.ok, true);
assert.equal(synced.uploaded, 2);
assert.equal(synced.destinationRoot, "OpenAssist/Second Brain/Memory Sources/stable-device-123");

const fileCalls = calls.filter((call) => call.toolName === memorySourceFileSyncToolName);
assert.equal(fileCalls.length, 2);
for (const call of fileCalls) {
  assert.deepEqual(Object.keys(call.args).sort(), [
    "content", "contentHash", "deviceId", "displayName", "idempotencyKey", "mimeType",
    "nameHistory", "relativePath", "sourceId", "sourceKind"
  ]);
  assert.equal(call.args.deviceId, "stable-device-123");
  assert.equal(call.args.sourceId, call.args.sourceKind);
  assert.equal(call.args.mimeType, "text/markdown");
  assert.match(call.args.relativePath, /\.md$/);
  assert.doesNotMatch(call.args.relativePath, /^(?:\/|[A-Za-z]:)/);
}
assert.equal(calls.some((call) => call.toolName === "create_google_drive_text_file"), false,
  "the coordinator must never fake folders with the generic Drive text-file tool");

const statusCalls = calls.filter((call) => call.toolName === memorySourceStatusToolName);
assert.equal(statusCalls.length, 2);
for (const call of statusCalls) {
  assert.equal(call.args.deviceId, "stable-device-123");
  assert.equal(call.args.status, "current");
  assert.equal(call.args.manifestCount, 1);
  assert.ok(call.args.manifestHash, "every source must report a manifest hash");
  assert.equal(Object.hasOwn(call.args, "content"), false, "status rows must never receive memory text");
  assert.equal(Object.hasOwn(call.args, "relativePath"), false, "status rows must never receive local paths");
}

// Two sources holding different files must report different manifest hashes.
// Reporting the combined fingerprint made every source look identical.
const codexStatus = statusCalls.find((call) => call.args.sourceId === "codex");
const claudeStatus = statusCalls.find((call) => call.args.sourceId === "claude");
assert.notEqual(codexStatus.args.manifestHash, claudeStatus.args.manifestHash,
  "the Codex and Claude sources must not share one manifest hash");
const syncedState = JSON.parse(fs.readFileSync(statePath, "utf8"));
assert.equal(codexStatus.args.manifestHash, syncedState.sources.codex.fingerprint,
  "the reported hash must be that source's own fingerprint");
assert.equal(claudeStatus.args.manifestHash, syncedState.sources.claude.fingerprint);

clock += 60_000;
const renamedCoordinator = coordinator("Office Mac");
renamedCoordinator.preview();
const renamed = await renamedCoordinator.sync();
assert.equal(renamed.uploaded, 0);
assert.deepEqual(renamed.preview.device.previousNames, ["Studio Mac"]);
const renamedStatuses = calls.filter((call) => call.toolName === memorySourceStatusToolName).slice(-2);
assert.deepEqual(renamedStatuses.map((call) => call.args.displayName), ["Office Mac", "Office Mac"]);
assert.notEqual(renamedStatuses[0].args.manifestHash, renamedStatuses[1].args.manifestHash,
  "an unchanged re-sync must still report distinct per-source hashes");
assert.equal(renamedStatuses.find((call) => call.args.sourceId === "codex").args.manifestHash,
  codexStatus.args.manifestHash, "an unchanged source keeps its manifest hash");

const changedCoordinator = coordinator("Office Mac");
changedCoordinator.preview();
write(path.join(codexRoot, "MEMORY.md"), "# Codex index\nA changed safe preference.\n");
await assert.rejects(
  () => changedCoordinator.sync(),
  /changed after the preview/,
  "sync approval must stay bound to the exact preview fingerprint"
);
clock += 60_000;
rejectFileSync = true;
const rejectedCoordinator = coordinator("Office Mac");
rejectedCoordinator.preview();
const rejected = await rejectedCoordinator.sync();
assert.equal(rejected.ok, false, "a failed Workspace tool result must not be recorded as an uploaded file");
assert.equal(rejected.uploaded, 0);
assert.equal(rejected.failed.length, 1);
assert.match(rejected.failed[0].error, /Workspace rejected the upload/);
const errorStatus = calls.filter((call) => call.toolName === memorySourceStatusToolName && call.args.sourceId === "codex").at(-1);
assert.equal(errorStatus.args.status, "error");
assert.equal(errorStatus.args.errorCode, "sync_failed");

console.log("Memory source Workspace coordinator verification passed.");

// Production MCP broker responses nest the current pointer in structuredContent.
write(path.join(codexRoot, 'MEMORY.md'), '# Production response\nVerified pointer.\n');
const realShape = new MemorySourceWorkspaceCoordinator({
 statePath:path.join(root,'real-shape.json'),machineID:'stable-device-456',machineName:'Test Mac',homeDir:home,codexRoot,claudeRoot,
 callWorkspaceTool:async(name) => name === memorySourceFileSyncToolName
   ? {ok:true,response:{structuredContent:{memoryFile:{id:'logical-memory-id',currentFileId:'actual-drive-file'}}}}
   : {ok:true,response:{structuredContent:{source:{id:'source'}}}}
});
realShape.preview();
assert.equal((await realShape.sync()).ok,true);
const realState=JSON.parse(fs.readFileSync(path.join(root,'real-shape.json'),'utf8'));
assert.equal(Object.values(realState.files)[0].remoteID,'actual-drive-file');
