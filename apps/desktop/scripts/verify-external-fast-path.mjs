import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { __realtimeProtocolTestHooks } from "../dist-electron/realtimeProxy.js";

const descriptors = __realtimeProtocolTestHooks.liveVoiceCapabilityDescriptors(() => ({ knowledge: { enabled: true } }));
const recall = descriptors.find((item) => item.id === "knowledge_personal_recall");
assert.ok(recall);
assert.equal(recall.source, "personal_memory");
assert.equal(recall.executionMode, "blocking");

const bridge = await readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");
assert.match(bridge, /ephemeral: true/);
assert.match(bridge, /persistExtendedHistory: false/);
assert.match(bridge, /Spark recall returned no sourced answer/);
assert.doesNotMatch(bridge, /fallback.*personal recall|personal recall.*fallback/i);

console.log("Personal recall isolation checks passed.");
