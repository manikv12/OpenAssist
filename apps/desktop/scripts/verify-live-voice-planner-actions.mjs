import assert from "node:assert/strict";
import { __realtimeProtocolTestHooks } from "../dist-electron/realtimeProxy.js";
import { LiveVoiceCapabilityRegistry } from "../dist-electron/liveVoice/capabilityRegistry.js";
import { LiveVoiceCoordinator } from "../dist-electron/liveVoice/coordinator.js";

const descriptors = __realtimeProtocolTestHooks.liveVoiceCapabilityDescriptors(() => ({
  knowledge: { enabled: true }
}));
const registry = new LiveVoiceCapabilityRegistry(descriptors);

const exactMoveGoal = 'Move the existing OpenAssist planner task "Make the curry for the restaurant" from Backlog to Today';
const exactMoveCandidates = registry.discover(exactMoveGoal, "move");
assert.equal(
  exactMoveCandidates[0]?.descriptor.id,
  "knowledge_move_daily_item",
  "One named Backlog-to-Today move must use the lossless exact-move capability."
);

const bulkMoveCandidates = registry.discover("Move all older unfinished tasks to Backlog", "move");
assert.equal(
  bulkMoveCandidates[0]?.descriptor.id,
  "knowledge_request_move_to_backlog",
  "Bulk cleanup must keep using the dedicated older-task capability."
);

const plainReminderCandidates = registry.discover("Add a reminder to make curry today", "create");
assert.equal(
  plainReminderCandidates.some(({ descriptor }) => descriptor.source === "apple_reminders"),
  false,
  "A plain reminder request belongs to the OpenAssist planner."
);

const appleReminderCandidates = registry.discover("Add this to Apple Reminders", "create");
assert.equal(
  appleReminderCandidates[0]?.descriptor.source,
  "apple_reminders",
  "An explicitly named Apple Reminders request must still use Apple Reminders."
);

const executions = [];
let now = 10_000;
const coordinator = new LiveVoiceCoordinator({
  registry,
  now: () => now,
  executeCapability: async (descriptor, request) => {
    executions.push({ descriptor, request });
    return { ok: true, status: "applied", item: { id: request.arguments.itemID } };
  },
  delegateWork: async () => ({ status: "running", summary: "" }),
  taskStatus: async () => ({}),
  cancelTask: async () => ({ ok: true }),
  openView: async () => ({ ok: true })
});

const deleteGoal = 'Remove the old Backlog copy of "Make the curry for the restaurant"';
const deleteTurn = coordinator.beginTurn("codexSubscription", deleteGoal, "delete-request");
const approval = await coordinator.capability(deleteTurn, "delete-call", {
  goal: deleteGoal,
  operation: "delete",
  capabilityID: "knowledge_delete_daily_item",
  arguments: {
    dayID: "backlog",
    itemID: "f9824cf2-50ae-4f8e-89d6-e9d6ea001023",
    query: "Make the curry for the restaurant"
  }
});
assert.equal(approval.status, "approval_required");
assert.ok(approval.confirmationToken, "The exact delete must return one reusable confirmation token.");
assert.equal(executions.length, 0, "A sensitive delete must not run before confirmation.");

now += 1_000;
const confirmationTurn = coordinator.beginTurn("codexSubscription", "Yes", "delete-confirmation");
const completed = await coordinator.capability(confirmationTurn, "delete-confirmed-call", {
  goal: "Yes",
  operation: "delete",
  arguments: {}
});
assert.equal(completed.status, "completed", "A clear spoken Yes must complete the pending delete.");
assert.equal(executions.length, 1, "The confirmed delete must execute exactly once.");
assert.equal(executions[0].descriptor.id, "knowledge_delete_daily_item");
assert.equal(executions[0].request.arguments.dayID, "backlog");
assert.equal(executions[0].request.arguments.itemID, "f9824cf2-50ae-4f8e-89d6-e9d6ea001023");
assert.equal(
  executions[0].request.confirmationToken,
  approval.confirmationToken,
  "The spoken confirmation must be attached to the same exact operation."
);

console.log("Live Voice planner action checks passed.");
