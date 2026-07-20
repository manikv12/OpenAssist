import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { __realtimeProtocolTestHooks } from "../dist-electron/realtimeProxy.js";

const descriptors = __realtimeProtocolTestHooks.liveVoiceCapabilityDescriptors(() => ({ knowledge: { enabled: true } }));
assert.ok(descriptors.some((item) => item.id === "knowledge_list_projects"));
assert.ok(descriptors.some((item) => item.id === "knowledge_create_project"));

const bridge = await readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");
assert.match(bridge, /name: "oa_list_projects"/);
assert.match(bridge, /name: "oa_create_project"/);
assert.match(bridge, /function createKnowledgeProject[\s\S]{0,900}confirmation_required/);
assert.match(bridge, /function emitProjectsChanged/);

console.log("Project capability checks passed.");
