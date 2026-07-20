import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const read = (file) => fs.readFileSync(path.resolve(file), "utf8");
const app = read("src/App.tsx");
const bridge = read("electron/openassistBridge.ts");
const main = read("electron/main.ts");
const preload = read("electron/preload.ts");
const types = read("src/vite-env.d.ts");

assert.ok(bridge.includes("function moveProjectNoteToProject"), "cross-List note move backend must exist");
assert.ok(bridge.includes("copyMovePath(sourceFilePath, destinationFilePath)"), "note Markdown must move with the note");
assert.ok(bridge.includes("copyMovePath(sourceAssetsPath, destinationAssetsPath)"), "note attachments must move with the note");
assert.ok(bridge.includes("copyMovePath(sourceHistoryPath, destinationHistoryPath)"), "note history must move with the note");
assert.ok(bridge.includes("writeNoteManifest(sourceID, sourceManifest)"), "failed moves must restore the source manifest");
assert.ok(bridge.includes("writeNoteManifest(destinationID, destinationManifest)"), "failed moves must restore the destination manifest");

assert.ok(main.includes('"openassist:move-note-to-project"'), "main process IPC must expose cross-List moves");
assert.ok(preload.includes("moveNoteToProject"), "preload must expose cross-List moves");
assert.ok(types.includes("moveNoteToProject:"), "renderer API types must include cross-List moves");

assert.ok(app.includes('label: "Move to List"'), "note menu must include Move to List");
assert.ok(app.includes("draggable={!showArchived}"), "active notes must be draggable");
assert.ok(app.includes("onDrop={(event) =>"), "List rows must accept dropped notes");
assert.ok(app.includes("setSelectedProjectID(result.destinationProjectID)"), "an open moved note must follow its destination List");
assert.ok(app.includes("appState.notes.find((item) => sameID(item.id, target.noteId))"), "old note links must follow a moved note by stable ID");
assert.ok(app.includes("setNoteNavigationBackStack((stack)"), "note navigation history must follow moved notes");
assert.ok(bridge.includes("canonicalLinkTarget"), "backlinks must follow moved notes without rewriting note content");

console.log("Note List move checks passed.");
