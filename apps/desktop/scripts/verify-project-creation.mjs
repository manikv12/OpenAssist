import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const proxy = fs.readFileSync(path.join(root, "electron", "realtimeProxy.ts"), "utf8");
const bridge = fs.readFileSync(path.join(root, "electron", "openassistBridge.ts"), "utf8");

const checks = [
  ["realtime lists sidebar projects", proxy, /name: "knowledge_list_projects"/],
  ["realtime can create projects", proxy, /name: "knowledge_create_project"[\s\S]{0,1600}confirmed/],
  ["realtime explains folders cannot hold work", proxy, /A folder cannot hold notes or chats by itself/],
  ["background agent accepts a project destination", proxy, /name: "background_agent"[\s\S]{0,900}projectID here/],
  ["single delegated project uses child-thread machinery", proxy, /requestedProject[\s\S]{0,900}startParallelDelegation/],
  ["bridge exposes project listing", bridge, /name: "oa_list_projects"/],
  ["bridge exposes project creation", bridge, /name: "oa_create_project"/],
  ["creation requires confirmation", bridge, /function createKnowledgeProject[\s\S]{0,700}confirmation_required/],
  ["creation reuses an existing destination", bridge, /const existing = loadProjects\(\)\.projects\.find[\s\S]{0,900}status: existing \? "existing" : "applied"/],
  ["project can create an approved parent folder", bridge, /createParentFolderIfMissing[\s\S]{0,500}createProject\(requestedParentName, "folder"\)/],
  ["project creation refreshes renderer state", bridge, /function emitProjectsChanged\(\)[\s\S]{0,350}type: "projects"/],
  ["missing delegated project never falls back silently", bridge, /task\.project && !requestedProjectID[\s\S]{0,700}task was not started/],
  ["new project ID can feed note creation", bridge, /case "knowledge_quick_save_note"[\s\S]{0,550}projectID: args\.projectID/]
];

for (const [label, source, pattern] of checks) {
  assert.match(source, pattern, label);
  console.log(`PASS ${label}`);
}

console.log("\nProject creation checks passed.");
