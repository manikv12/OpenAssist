import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

const root = process.cwd();
const bridgePath = path.join(root, "electron", "openassistBridge.ts");
const preloadPath = path.join(root, "electron", "preload.ts");
const mainPath = path.join(root, "electron", "main.ts");
const appPath = path.join(root, "src", "App.tsx");
const typesPath = path.join(root, "src", "types.ts");

const bridge = fs.readFileSync(bridgePath, "utf8");
const preload = fs.readFileSync(preloadPath, "utf8");
const main = fs.readFileSync(mainPath, "utf8");
const app = fs.readFileSync(appPath, "utf8");
const types = fs.readFileSync(typesPath, "utf8");

function includes(source, text, label) {
  assert.ok(source.includes(text), `${label}: expected ${text}`);
}

includes(bridge, "kind?: \"mobile\" | \"peer-mac\"", "paired device kind");
includes(bridge, "SyncPeers.json", "sync peer store");
includes(bridge, "SyncTombstones.json", "sync tombstones");
includes(bridge, "connectMacSyncPeer", "machine-id verified reconnect");
includes(bridge, "machineID !== peer.machineID", "machine-id mismatch guard");
includes(bridge, "macSyncAssertClockClose", "clock skew guard");
includes(bridge, "/remote/v1/sync/changes", "changes endpoint");
includes(bridge, "/remote/v1/sync/push", "push endpoint");
includes(bridge, "device.kind !== \"peer-mac\"", "peer-only sync endpoints");
includes(bridge, "recordMacSyncTombstone(\"project\"", "project tombstone");
includes(bridge, "recordMacSyncTombstone(\"note\"", "note tombstone");
includes(bridge, "macSyncSafeNoteFileName", "safe note filename");
includes(bridge, "removeRemoteAccessPeerDevice", "revoke removes peer device token");
includes(bridge, "linkedFolderPath = project.linkedFolderPath", "local folder path preserved");
includes(bridge, "createMacSyncConflictNote", "note conflict copy");
includes(bridge, "workingManifest = readNoteManifest(projectID)", "conflict note manifest preservation");
includes(bridge, "macSyncMergePlannerMarkdown", "planner markdown merge");
includes(bridge, "snapshotStartedAt", "cursor race guard");
includes(preload, "pairMacSyncPeer", "preload pair API");
includes(main, "openassist:pair-mac-sync-peer", "main pair IPC");
includes(app, "Mac Sync", "settings Mac Sync UI");
includes(app, "askThreadFolderWarning", "thread-start folder warning promise");
includes(app, "thread-folder-warning-dialog", "thread-start folder warning dialog");
includes(types, "remoteAccessSyncPeers", "settings peer type");

console.log("Mac sync verifier passed.");
