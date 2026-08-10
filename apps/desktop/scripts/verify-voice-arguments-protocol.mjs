// The dispatcher protocol's arguments_required state: voice models cannot see
// a capability's argument schema when calling assistant_capability and
// routinely send empty arguments. The coordinator must validate required
// fields BEFORE approval/execution and hand the schema back with a re-call
// instruction, instead of executing into a bridge error that models answer by
// interrogating the user ("What should I add to Apple Reminders?" loops).
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const { LiveVoiceCoordinator } = await import("../dist-electron/liveVoice/coordinator.js");
const { LiveVoiceCapabilityRegistry } = await import("../dist-electron/liveVoice/capabilityRegistry.js");

const executed = [];
const registry = new LiveVoiceCapabilityRegistry([
  {
    id: "knowledge_update_daily_item",
    description: "Update a planner task.",
    operations: ["update"],
    source: "openassist_planner",
    sourceAliases: ["planner", "today"],
    keywords: ["update daily item"],
    inputSchema: { type: "object", properties: { userIntent: { type: "string" }, id: { type: "string" }, newTitle: { type: "string" } }, required: ["id"] },
    selfDerivedArguments: ["newTitle"],
    risk: "reversible_write",
    executionMode: "blocking",
    timeoutMs: 2000,
    idempotency: "required"
  },
  {
    id: "knowledge_connector_search_messages",
    description: "Search Messages.",
    operations: ["search"],
    source: "connected_sources",
    sourceAliases: ["messages"],
    keywords: ["search messages"],
    inputSchema: { type: "object", properties: { userIntent: { type: "string" }, query: { type: "string" } }, required: ["query"] },
    selfDerivedArguments: ["query"],
    risk: "read",
    executionMode: "blocking",
    timeoutMs: 2000,
    idempotency: "turn"
  }
]);
const coordinator = new LiveVoiceCoordinator({
  registry,
  executeCapability: async (descriptor, request) => {
    executed.push({ id: descriptor.id, args: request.arguments });
    return { ok: true };
  },
  delegateWork: async () => ({ status: "running", summary: "" }),
  taskStatus: async () => ({}),
  cancelTask: async () => ({ ok: true, summary: "" })
});
coordinator.beginTurn("geminiLive", "update my planner task", "item-1");
const turnID = Object.keys(coordinator.snapshot().turns)[0];

const missing = await coordinator.capability(turnID, "call-1", {
  goal: "rename my planner task to buy milk",
  capabilityID: "knowledge_update_daily_item",
  arguments: {}
});
assert.equal(missing.status, "arguments_required", "missing required args must return arguments_required, not execute");
// userIntent can derive a title but NEVER an id: the gate must still fire for
// the id even though the capability is userIntent-capable.
assert.ok(missing.message.includes("id"), "missing-field list must name the underivable id");
assert.ok(missing.message.includes("knowledge_update_daily_item"), "message must name the capability to re-call");
assert.ok(missing.message.includes('"required":["id"]'), "message must embed the input schema");
assert.ok(missing.candidates?.[0]?.inputSchema, "candidates must carry the schema for structured consumers");
assert.equal(executed.length, 0, "the capability must not execute with missing required arguments");

const filled = await coordinator.capability(turnID, "call-2", {
  goal: "rename my planner task to buy milk",
  capabilityID: "knowledge_update_daily_item",
  arguments: { id: "task-9", newTitle: "Buy milk" }
});
assert.equal(filled.status, "completed");
assert.equal(executed[0].args.id, "task-9", "re-call with filled args must execute");

const derive = await coordinator.capability(turnID, "call-3", {
  goal: "check my messages for the dentist",
  capabilityID: "knowledge_connector_search_messages",
  arguments: {}
});
assert.equal(derive.status, "completed", "userIntent-capable capabilities must skip the round-trip");
assert.equal(executed[1].args.userIntent, "check my messages for the dentist", "goal must be injected as userIntent");

// Source needles: both providers must be told how to answer arguments_required.
const proxy = fs.readFileSync(path.join(root, "electron", "realtimeProxy.ts"), "utf8");
assert.ok(proxy.includes("If the result is arguments_required"), "realtime instructions must explain arguments_required");
const contracts = fs.readFileSync(path.join(root, "electron", "liveVoice", "contracts.ts"), "utf8");
assert.ok(contracts.includes('"arguments_required"'), "contracts must declare the arguments_required status");

console.log("Voice arguments protocol checks passed.");
