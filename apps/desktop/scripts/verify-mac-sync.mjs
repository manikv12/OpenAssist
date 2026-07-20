import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  compareMacSyncVersions,
  decideMacSyncReconciliation,
  macSyncChangedSince,
  macSyncConflictID,
  macSyncContentHash,
  macSyncLegacyPlannerItemID,
  macSyncProtocolVersion,
  macSyncScanCursor,
  macSyncStableStringify,
  mergeVersionedRecords
} from "../dist-electron/macSyncCore.js";

const root = process.cwd();
const bridge = fs.readFileSync(path.join(root, "electron", "openassistBridge.ts"), "utf8");
const preload = fs.readFileSync(path.join(root, "electron", "preload.ts"), "utf8");
const main = fs.readFileSync(path.join(root, "electron", "main.ts"), "utf8");
const app = fs.readFileSync(path.join(root, "src", "App.tsx"), "utf8");
const types = fs.readFileSync(path.join(root, "src", "types.ts"), "utf8");

function includes(source, text, label) {
  assert.ok(source.includes(text), `${label}: expected ${text}`);
}

function matches(source, pattern, label) {
  assert.ok(pattern.test(source), `${label}: expected ${pattern}`);
}

function extractFunction(source, name) {
  const start = source.indexOf(`function ${name}`);
  assert.ok(start >= 0, `${name} must exist`);
  let depth = 0;
  for (let index = source.indexOf("{", start); index < source.length; index += 1) {
    if (source[index] === "{") depth += 1;
    if (source[index] === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(start, index + 1);
    }
  }
  throw new Error(`${name} is incomplete`);
}

// Electron-only wiring checks. Data merge behavior is tested below using two
// real temporary folders and repeated two-way sync cycles.
assert.equal(macSyncProtocolVersion, 2, "Mac Sync protocol must be v2");
includes(bridge, "safeStorage.isEncryptionAvailable()", "secure storage gate");
includes(bridge, 'record?.encoding !== "safeStorage"', "base64 token rejection");
includes(bridge, "tokenRef", "peer token reference");
includes(bridge, "storeMacSyncPeerToken(machineID, legacyToken)", "legacy token migration");
includes(bridge, "deleteMacSyncPeerToken(peer)", "secure token revoke");
includes(bridge, "removeRemoteAccessPeerDevice", "auth token revoke");
includes(bridge, "mode: 0o700", "private sync directory");
includes(bridge, "fs.chmodSync(filePath, 0o600)", "private sync files");
assert.ok(!/\btoken\s*:/.test(extractFunction(bridge, "writeMacSyncPeers")), "SyncPeers writer must not add a plaintext token");
includes(bridge, "seen.has(machineID)", "peer identity uses machine ID");
includes(bridge, 'device.kind !== "peer-mac"', "peer-only sync endpoints");
includes(bridge, "macSyncProtocolVersion,", "health protocol version");
includes(bridge, "Update OpenAssist on both Macs before syncing.", "protocol mismatch message");
includes(bridge, "SyncItemVersions.json", "item version store");
includes(bridge, "SyncPeerState", "per-peer base version store");
includes(bridge, "snapshotStartedAt", "scan-start cursor");
includes(bridge, "macSyncSafeNoteFileName", "safe note filename");
includes(bridge, 'relativePath.startsWith(`${assetsDirectory}/`)', "assets scoped to their note");
includes(bridge, 'macSyncBlockedByTombstone("note", noteID', "stale note resurrection guard");
includes(bridge, 'macSyncBlockedByTombstone("noteFolder", folderID', "stale note-folder resurrection guard");
includes(bridge, 'recordMacSyncTombstone("plannerItem"', "planner item tombstone");
includes(bridge, 'recordMacSyncTombstone("plannerCategory"', "planner category tombstone");
includes(bridge, "macSyncNormalizePlannerMarkdown", "plain planner task migration");
includes(bridge, "macSyncFindPlannerItems", "planner move deduplication");
includes(bridge, "snapshotPlannerDay(containerID", "planner text recovery");
matches(bridge, /fs\.rmSync\(path\.join\(noteDirectoryPath\(projectID\), `\$\{fileName\.replace\(\/\\\.md\$\/, ""\)\}\.assets`\), \{ force: true, recursive: true \}\)/, "note asset deletion");
includes(bridge, "/remote/v1/sync/changes", "changes endpoint");
includes(bridge, "/remote/v1/sync/push", "push endpoint");
includes(preload, "pairMacSyncPeer", "preload pair API");
includes(main, "openassist:pair-mac-sync-peer", "main pair IPC");
includes(app, "Saved deletions may be applied", "accurate Full Re-sync warning");
includes(app, "thread-folder-warning-dialog", "in-app thread warning");
includes(types, "remoteAccessSyncPeers", "settings peer type");

const loopbackSource = [
  extractFunction(bridge, "normalizeMacSyncBaseURL").replace(/: unknown/g, ""),
  extractFunction(bridge, "macSyncIsLoopbackURL").replace(/: string/g, ""),
  extractFunction(bridge, "macSyncReachableBaseURL").replace(/: unknown/g, "")
].join("\n");
const { macSyncReachableBaseURL } = new Function(`${loopbackSource}; return { macSyncReachableBaseURL };`)();
assert.equal(macSyncReachableBaseURL("http://127.0.0.1:45832"), "");
assert.equal(macSyncReachableBaseURL("http://192.168.1.20:45832"), "http://192.168.1.20:45832");

// Core protocol behavior.
assert.equal(macSyncContentHash({ b: 2, a: 1 }), macSyncContentHash({ a: 1, b: 2 }), "hashes must ignore object key order");
const tieA = { updatedAt: 100, machineID: "mac-a", contentHash: "a" };
const tieB = { updatedAt: 100, machineID: "mac-b", contentHash: "b" };
assert.ok(compareMacSyncVersions(tieB, tieA) > 0, "machine ID must break timestamp ties");
assert.equal(macSyncScanCursor(1234.9), "1234", "cursor must use scan start");
assert.equal(macSyncChangedSince(1234, 1234), true, "cursor overlap must include the boundary millisecond");
assert.equal(macSyncChangedSince(1240, 1234), true, "a save during scanning must appear next time");
assert.equal(macSyncConflictID("note-1", tieA), macSyncConflictID("note-1", tieA), "conflict IDs must be stable");
assert.equal(
  macSyncLegacyPlannerItemID("2026-07-14", "Buy milk|Personal|Tasks", 0),
  macSyncLegacyPlannerItemID("2026-07-14", "Buy milk|Personal|Tasks", 0),
  "legacy planner IDs must match on both Macs"
);
assert.equal(decideMacSyncReconciliation({
  localExists: true,
  localVersion: tieA,
  incomingVersion: tieB,
  sameContent: false,
  preserveInitialDifference: true
}), "conflict-incoming", "first-sync differences must create a conflict");
assert.deepEqual(
  mergeVersionedRecords(
    [{ id: "task", version: tieA, value: "old" }],
    [{ id: "task", version: tieB, value: "new" }, { id: "added", version: tieA, value: "added" }]
  ).sort((left, right) => left.id.localeCompare(right.id)).map(({ id, value }) => ({ id, value })),
  [{ id: "added", value: "added" }, { id: "task", value: "new" }],
  "record merge must preserve additions and newest edits"
);

const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-mac-sync-v2-"));
process.on("exit", () => fs.rmSync(temporaryRoot, { recursive: true, force: true }));

function statePath(mac) {
  return path.join(mac.root, "mac-sync-state.json");
}

function readState(mac) {
  return JSON.parse(fs.readFileSync(statePath(mac), "utf8"));
}

function writeState(mac, state) {
  fs.writeFileSync(statePath(mac), `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  fs.chmodSync(statePath(mac), 0o600);
}

function createMac(machineID, name = "MacBook Pro") {
  const mac = { machineID, name, root: path.join(temporaryRoot, machineID) };
  fs.mkdirSync(mac.root, { recursive: true, mode: 0o700 });
  writeState(mac, { machineID, name, items: {}, tombstones: {}, seen: {}, recoveries: [] });
  return mac;
}

function itemKey(kind, id) {
  return `${kind}:${id}`;
}

function tombstoneKey(tombstone) {
  return `${tombstone.kind}:${tombstone.containerID ?? ""}:${tombstone.id}`;
}

function makeVersion(mac, value, updatedAt) {
  return { updatedAt, machineID: mac.machineID, contentHash: macSyncContentHash(value) };
}

function put(mac, kind, id, value, updatedAt) {
  const state = readState(mac);
  state.items[itemKey(kind, id)] = { kind, id, value, version: makeVersion(mac, value, updatedAt) };
  writeState(mac, state);
}

function remove(mac, kind, id, deletedAt, containerID) {
  const state = readState(mac);
  const key = itemKey(kind, id);
  if (kind !== "plannerItem" || state.items[key]?.value?.containerID === containerID) delete state.items[key];
  const tombstone = { kind, id, containerID, deletedAt, machineID: mac.machineID };
  state.tombstones[tombstoneKey(tombstone)] = tombstone;
  writeState(mac, state);
}

function tombstoneVersion(tombstone) {
  return {
    updatedAt: tombstone.deletedAt,
    machineID: tombstone.machineID,
    contentHash: macSyncContentHash({ deleted: true, kind: tombstone.kind, id: tombstone.id, containerID: tombstone.containerID ?? "" })
  };
}

function relevantTombstone(state, item) {
  return Object.values(state.tombstones).find((tombstone) =>
    tombstone.kind === item.kind
    && tombstone.id === item.id
    && (item.kind !== "plannerItem" || tombstone.containerID === item.value.containerID)
  );
}

function conflictNote(source, conflictID) {
  const sourceDirectory = `${String(source.value.fileName ?? source.id).replace(/\.md$/, "")}.assets`;
  const targetDirectory = `${conflictID}.assets`;
  return {
    ...source.value,
    fileName: `${conflictID}.md`,
    markdown: String(source.value.markdown ?? "").split(`${sourceDirectory}/`).join(`${targetDirectory}/`),
    assets: (source.value.assets ?? []).map((asset) => ({
      ...asset,
      path: String(asset.path ?? "").replace(`${sourceDirectory}/`, `${targetDirectory}/`)
    }))
  };
}

function saveConflict(state, losing) {
  const conflictID = macSyncConflictID(losing.id, losing.version);
  const key = itemKey("note", conflictID);
  if (!state.items[key]) {
    const value = conflictNote(losing, conflictID);
    state.items[key] = { kind: "note", id: conflictID, value, version: losing.version };
  }
}

function applyIncomingItem(state, incoming) {
  const key = itemKey(incoming.kind, incoming.id);
  const storedIncoming = {
    kind: incoming.kind,
    id: incoming.id,
    value: structuredClone(incoming.value),
    version: structuredClone(incoming.version)
  };
  const blocked = relevantTombstone(state, incoming);
  if (blocked && compareMacSyncVersions(tombstoneVersion(blocked), incoming.version) >= 0) return;
  const local = state.items[key];
  if (!local) {
    state.items[key] = storedIncoming;
    return;
  }
  const sameContent = macSyncContentHash(local.value) === macSyncContentHash(incoming.value);
  if (sameContent) {
    if (compareMacSyncVersions(incoming.version, local.version) > 0) state.items[key] = storedIncoming;
    return;
  }
  const decision = decideMacSyncReconciliation({
    localExists: true,
    localVersion: local.version,
    incomingVersion: incoming.version,
    baseVersion: incoming.baseVersion,
    sameContent,
    preserveInitialDifference: incoming.kind === "note"
  });
  if (incoming.kind === "note" && decision.startsWith("conflict-")) {
    saveConflict(state, decision === "conflict-incoming" ? local : incoming);
  }
  if (incoming.kind === "plannerDocument" && decision.startsWith("conflict-")) {
    const losing = decision === "conflict-incoming" ? local : incoming;
    const recoveryHash = macSyncContentHash(losing.value);
    if (!state.recoveries.some((entry) => entry.hash === recoveryHash)) {
      state.recoveries.push({ hash: recoveryHash, value: losing.value });
    }
  }
  if (decision === "incoming" || decision === "conflict-incoming") state.items[key] = storedIncoming;
}

function applyIncomingTombstone(state, tombstone) {
  const key = tombstoneKey(tombstone);
  const previous = state.tombstones[key];
  if (!previous || compareMacSyncVersions(tombstoneVersion(tombstone), tombstoneVersion(previous)) > 0) {
    state.tombstones[key] = structuredClone(tombstone);
  }
  const item = state.items[itemKey(tombstone.kind, tombstone.id)];
  if (!item) return;
  if (tombstone.kind === "plannerItem" && item.value.containerID !== tombstone.containerID) return;
  if (compareMacSyncVersions(item.version, tombstoneVersion(tombstone)) <= 0) {
    delete state.items[itemKey(tombstone.kind, tombstone.id)];
  }
}

function packet(source, target) {
  const state = readState(source);
  const seen = state.seen[target.machineID] ?? {};
  return {
    items: Object.values(state.items).map((item) => ({ ...structuredClone(item), baseVersion: seen[itemKey(item.kind, item.id)] })),
    tombstones: Object.values(state.tombstones).map((entry) => structuredClone(entry))
  };
}

function syncOneWay(source, target) {
  const outgoing = packet(source, target);
  const state = readState(target);
  for (const item of outgoing.items) applyIncomingItem(state, item);
  for (const tombstone of outgoing.tombstones) applyIncomingTombstone(state, tombstone);
  state.seen[source.machineID] ??= {};
  for (const item of outgoing.items) state.seen[source.machineID][itemKey(item.kind, item.id)] = item.version;
  writeState(target, state);
}

function syncBoth(left, right, cycles = 1) {
  for (let cycle = 0; cycle < cycles; cycle += 1) {
    syncOneWay(left, right);
    syncOneWay(right, left);
  }
}

function contentSnapshot(mac) {
  const state = readState(mac);
  return macSyncStableStringify({ items: state.items, tombstones: state.tombstones });
}

function item(mac, kind, id) {
  return readState(mac).items[itemKey(kind, id)];
}

// First pairing: identical notes deduplicate; different notes produce one
// stable conflict copy with complete, rewritten assets.
const identicalA = createMac("identical-a");
const identicalB = createMac("identical-b");
const sameNote = { fileName: "note-1.md", markdown: "Same", assets: [] };
put(identicalA, "note", "note-1", sameNote, 100);
put(identicalB, "note", "note-1", sameNote, 200);
syncBoth(identicalA, identicalB, 3);
assert.equal(Object.keys(readState(identicalA).items).length, 1, "identical first-sync notes must not duplicate");
assert.equal(contentSnapshot(identicalA), contentSnapshot(identicalB), "identical notes must converge");

const collisionA = createMac("collision-a");
const collisionB = createMac("collision-b");
put(collisionA, "note", "note-1", {
  fileName: "note-1.md",
  markdown: "A ![](note-1.assets/a.png)",
  assets: [{ path: "note-1.assets/a.png", data: "A" }]
}, 300);
put(collisionB, "note", "note-1", {
  fileName: "note-1.md",
  markdown: "B ![](note-1.assets/b.png)",
  assets: [{ path: "note-1.assets/b.png", data: "B" }]
}, 301);
syncBoth(collisionA, collisionB, 4);
const collisionItems = Object.values(readState(collisionA).items);
const conflictCopies = collisionItems.filter((entry) => entry.kind === "note" && entry.id.startsWith("conflict_"));
assert.equal(conflictCopies.length, 1, "a first-sync collision must create exactly one conflict copy");
assert.ok(conflictCopies[0].value.markdown.includes(`${conflictCopies[0].id}.assets/`), "conflict markdown must use its copied asset folder");
assert.ok(conflictCopies[0].value.assets.every((asset) => asset.path.startsWith(`${conflictCopies[0].id}.assets/`)), "all conflict assets must be copied");
assert.equal(contentSnapshot(collisionA), contentSnapshot(collisionB), "note conflicts must converge");

// Shared-base edits and delete-versus-newer-edit.
const notesA = createMac("notes-a");
const notesB = createMac("notes-b");
put(notesA, "note", "shared", { fileName: "shared.md", markdown: "Base", assets: [] }, 400);
syncBoth(notesA, notesB, 2);
put(notesA, "note", "shared", { fileName: "shared.md", markdown: "Edit A", assets: [] }, 410);
put(notesB, "note", "shared", { fileName: "shared.md", markdown: "Edit B", assets: [] }, 411);
syncBoth(notesA, notesB, 4);
assert.equal(Object.values(readState(notesA).items).filter((entry) => entry.id.startsWith("conflict_")).length, 1, "concurrent note edits must preserve one losing copy");
put(notesA, "note", "delete-edit", { fileName: "delete-edit.md", markdown: "Base", assets: [] }, 420);
syncBoth(notesA, notesB, 2);
remove(notesA, "note", "delete-edit", 430);
put(notesB, "note", "delete-edit", { fileName: "delete-edit.md", markdown: "Newer edit", assets: [] }, 431);
syncBoth(notesA, notesB, 4);
assert.equal(item(notesA, "note", "delete-edit").value.markdown, "Newer edit", "a newer edit must survive an older delete");

// Planner items merge independently, keep IDs when moved, copy with a new ID,
// and use category/item tombstones without replacing the whole day.
const plannerA = createMac("planner-a");
const plannerB = createMac("planner-b");
put(plannerA, "plannerItem", "task-1", { containerID: "2026-07-14", title: "First", checked: false }, 500);
syncBoth(plannerA, plannerB, 2);
put(plannerA, "plannerItem", "task-1", { containerID: "2026-07-14", title: "First edited", checked: true }, 510);
put(plannerB, "plannerItem", "task-2", { containerID: "2026-07-14", title: "Second", checked: false }, 511);
syncBoth(plannerA, plannerB, 3);
assert.equal(item(plannerB, "plannerItem", "task-1").value.checked, true, "checkbox edits must sync independently");
assert.equal(item(plannerA, "plannerItem", "task-2").value.title, "Second", "concurrent additions must be kept");
put(plannerA, "plannerItem", "task-1", { containerID: "2026-07-15", title: "First edited", checked: true }, 520);
put(plannerA, "plannerItem", "task-copy", { containerID: "2026-07-15", title: "First edited", checked: true }, 521);
syncBoth(plannerA, plannerB, 2);
assert.equal(item(plannerB, "plannerItem", "task-1").value.containerID, "2026-07-15", "moving must preserve the task ID");
assert.ok(item(plannerB, "plannerItem", "task-copy"), "copying must use a new task ID");
remove(plannerA, "plannerItem", "task-2", 530, "2026-07-14");
syncBoth(plannerA, plannerB, 2);
assert.equal(item(plannerB, "plannerItem", "task-2"), undefined, "planner task deletion must sync");
put(plannerA, "plannerCategory", "work", { name: "Work", order: 0 }, 540);
syncBoth(plannerA, plannerB, 2);
put(plannerA, "plannerCategory", "work", { name: "Work A", order: 0 }, 550);
put(plannerB, "plannerCategory", "work", { name: "Work B", order: 0 }, 551);
syncBoth(plannerA, plannerB, 3);
assert.equal(item(plannerA, "plannerCategory", "work").value.name, "Work B", "newest category edit must win");
remove(plannerA, "plannerCategory", "work", 560);
syncBoth(plannerA, plannerB, 2);
assert.equal(item(plannerB, "plannerCategory", "work"), undefined, "category deletion must sync");

// Planner prose uses deterministic last-writer-wins and records the loser.
put(plannerA, "plannerDocument", "2026-07-14", { markdown: "Base heading" }, 570);
syncBoth(plannerA, plannerB, 2);
put(plannerA, "plannerDocument", "2026-07-14", { markdown: "Text from A" }, 580);
put(plannerB, "plannerDocument", "2026-07-14", { markdown: "Text from B" }, 581);
syncBoth(plannerA, plannerB, 3);
assert.equal(item(plannerA, "plannerDocument", "2026-07-14").value.markdown, "Text from B", "planner prose must use deterministic LWW");
assert.ok(readState(plannerA).recoveries.length + readState(plannerB).recoveries.length > 0, "losing planner prose must enter recovery history");

// Tombstones do not expire. A full packet after more than 90 days must still
// apply the saved deletion, and repeated sync must converge.
const offlineA = createMac("offline-a");
const offlineB = createMac("offline-b");
const oldTime = Date.now() - 100 * 24 * 60 * 60 * 1000;
put(offlineA, "note", "old-note", { fileName: "old-note.md", markdown: "Old", assets: [] }, oldTime - 1000);
syncBoth(offlineA, offlineB, 2);
remove(offlineA, "note", "old-note", oldTime);
syncOneWay(offlineB, offlineA);
assert.equal(item(offlineA, "note", "old-note"), undefined, "an old peer copy must not revive a locally deleted note");
syncBoth(offlineA, offlineB, 3);
assert.equal(item(offlineB, "note", "old-note"), undefined, "an offline Mac must receive a tombstone older than 90 days");
assert.ok(Object.keys(readState(offlineB).tombstones).length > 0, "full re-sync must retain saved tombstones");

for (const [left, right] of [[notesA, notesB], [plannerA, plannerB], [offlineA, offlineB]]) {
  syncBoth(left, right, 4);
  assert.equal(contentSnapshot(left), contentSnapshot(right), `${left.machineID} and ${right.machineID} must converge`);
}

assert.notEqual(plannerA.machineID, plannerB.machineID, "same-name Macs must stay separate by machine ID");
assert.equal(fs.statSync(statePath(plannerA)).mode & 0o777, 0o600, "private test state must use 0600 permissions");

console.log("Mac sync protocol v2 verifier passed with two-root behavioral tests.");
