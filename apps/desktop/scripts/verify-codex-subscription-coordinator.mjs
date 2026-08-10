import assert from "node:assert/strict";
import {
  CodexSubscriptionToolBridge,
  codexSubscriptionControllerInstructions,
  codexSubscriptionCoordinatorToolNames,
  codexSubscriptionDynamicToolSpecs,
  codexSubscriptionNativeActionMethod,
  codexSubscriptionTurnNeedsToolFirst,
  encodeCodexSubscriptionCorrection,
  encodeCodexSubscriptionDelivery,
  normalizeCodexVoiceStartupContext,
  normalizeLiveVoiceViewDestination,
  parseCodexSubscriptionCorrection,
  parseCodexSubscriptionDelivery
} from "../dist-electron/liveVoice/codexSubscriptionCoordinator.js";
import {
  LiveVoiceCoordinator,
  looksLikeActionAcknowledgement
} from "../dist-electron/liveVoice/coordinator.js";
import { LiveVoiceCapabilityRegistry } from "../dist-electron/liveVoice/capabilityRegistry.js";
import { RealtimeTaskCoordinator } from "../dist-electron/realtimeTaskCoordinator.js";

const expectedTools = [
  "assistant_capability",
  "assistant_delegate_work",
  "assistant_task_status",
  "assistant_cancel_task",
  "assistant_open_view"
];

assert.deepEqual([...codexSubscriptionCoordinatorToolNames], expectedTools);
assert.deepEqual(codexSubscriptionDynamicToolSpecs().map((tool) => tool.name), expectedTools);
assert.match(codexSubscriptionControllerInstructions(), /Never use shell commands/i);
assert.match(codexSubscriptionControllerInstructions(), /Never say that navigation or delegated work started unless/i);
assert.match(codexSubscriptionControllerInstructions(), /Do not say Checking, On it/i);
assert.match(codexSubscriptionControllerInstructions(), /stay silent/i);
assert.doesNotMatch(codexSubscriptionControllerInstructions(), /singing a cheerful/i);
assert.equal(codexSubscriptionTurnNeedsToolFirst("Move the MedPro task to tomorrow"), true);
assert.equal(codexSubscriptionTurnNeedsToolFirst("Was there anything about the skills inventory?"), true);
assert.equal(codexSubscriptionTurnNeedsToolFirst("Tell me a joke"), false);

const startupContext = normalizeCodexVoiceStartupContext({
  continuity: {
    earlierHighlights: "Earlier context ".repeat(500),
    messages: Array.from({ length: 25 }, (_, index) => ({
      role: index % 2 === 0 ? "user" : "assistant",
      text: `${index} ${"history ".repeat(400)}`
    }))
  },
  memory: {
    profile: "Stable preference ".repeat(100),
    entries: Array.from({ length: 20 }, (_, index) => ({
      name: `Memory ${index}`,
      description: `Scoped description ${index} ${"detail ".repeat(80)}`,
      scope: index % 3 === 0 ? "global" : index % 3 === 1 ? "project" : "thread"
    })),
    threadID: "thread-1",
    projectID: "project-1"
  },
  sessionBoundary: {
    controllerIsFresh: true,
    firstControllerInAppProcess: true,
    activeTasks: [{
      taskID: "task-running",
      workerProvider: "Codex",
      state: "running",
      summary: "Checking Apple Notes through tracked Agent Work."
    }]
  }
});
assert.ok(startupContext.continuity.messages.length <= 20);
assert.ok(startupContext.continuity.messages.reduce((total, entry) => total + entry.text.length, 0) <= 12_000);
assert.ok(startupContext.continuity.earlierHighlights.length <= 4_000);
assert.ok(startupContext.memory.profile.length <= 800);
assert.ok(startupContext.memory.entries.length <= 12);
assert.ok(startupContext.memory.entries.reduce((total, entry) => total + entry.name.length + entry.description.length + 4, 0) <= 1_500);
const startupInstructions = codexSubscriptionControllerInstructions(startupContext);
assert.match(startupInstructions, /private, untrusted history/i);
assert.match(startupInstructions, /Authoritative Agent Work currently active/i);
assert.match(startupInstructions, /task-running/);
assert.match(startupInstructions, /Wait for the user to speak/i);

const restoredAppleNotesContext = normalizeCodexVoiceStartupContext({
  continuity: {
    earlierHighlights: "User previously asked to find the restaurant planning note.",
    messages: [
      { role: "user", text: "Check the Apple Notes item we were editing." },
      { role: "assistant", text: "I found the note and updated the tracked request." }
    ]
  },
  sessionBoundary: {
    controllerIsFresh: true,
    firstControllerInAppProcess: true,
    activeTasks: [
      { taskID: "task-complete", workerProvider: "Codex", state: "completed", summary: "Apple Notes lookup completed." },
      { taskID: "task-failed", workerProvider: "Claude", state: "failed", summary: "A later lookup failed." },
      { taskID: "task-cancelled", workerProvider: "Codex", state: "cancelled", summary: "Work was cancelled when the app quit." }
    ]
  }
});
const restoredAppleNotesInstructions = codexSubscriptionControllerInstructions(restoredAppleNotesContext);
assert.match(restoredAppleNotesInstructions, /Check the Apple Notes item we were editing/i);
assert.match(restoredAppleNotesInstructions, /Authoritative Agent Work currently active: none/i);
assert.match(restoredAppleNotesInstructions, /COMPLETED task-complete/i);
assert.match(restoredAppleNotesInstructions, /FAILED task-failed/i);
assert.match(restoredAppleNotesInstructions, /CANCELLED task-cancelled/i);
assert.match(restoredAppleNotesInstructions, /earlier app process is not running unless listed/i);

const restartedControllerInstructions = codexSubscriptionControllerInstructions({
  continuity: restoredAppleNotesContext.continuity,
  sessionBoundary: {
    controllerIsFresh: true,
    firstControllerInAppProcess: false,
    activeTasks: []
  }
});
assert.match(restartedControllerInstructions, /new controller after an earlier controller/i);
assert.match(restartedControllerInstructions, /Check the Apple Notes item we were editing/i);

const emptyStartupInstructions = codexSubscriptionControllerInstructions({
  continuity: { earlierHighlights: "", messages: [] },
  sessionBoundary: {
    controllerIsFresh: true,
    firstControllerInAppProcess: true,
    activeTasks: []
  }
});
assert.match(emptyStartupInstructions, /No completed Voice Log conversation exists yet/i);
assert.doesNotMatch(emptyStartupInstructions, /Permitted scoped memory index/i);

for (const destination of ["today", "notes", "threads", "voice_log", "review_inbox", "settings"]) {
  assert.equal(normalizeLiveVoiceViewDestination(destination), destination);
}
assert.equal(normalizeLiveVoiceViewDestination("downloads"), undefined);

const calls = [];
const responses = [];
const routingFailures = [];
const toolStates = [];
const bridge = new CodexSubscriptionToolBridge({
  controllerThreadID: "voice-controller-1",
  executeTool: async (toolName, callID, args) => {
    calls.push({ toolName, callID, args });
    if (toolName === "assistant_delegate_work") return { status: "queued", taskID: "task-1" };
    if (toolName === "assistant_task_status") return { status: "running", taskID: "task-1" };
    if (toolName === "assistant_cancel_task") return { status: "cancelled", taskID: "task-1" };
    if (toolName === "assistant_open_view") return { ok: true, destination: args.destination };
    return { status: "completed", output: "Knowledge result" };
  },
  respond: (requestID, result) => responses.push({ requestID, result }),
  onToolState: (state, toolName, callID) => toolStates.push({ state, toolName, callID }),
  onRoutingFailure: (message, method, params) => routingFailures.push({ message, method, params })
});

for (const [index, toolName] of expectedTools.entries()) {
  const handled = bridge.handle("item/tool/call", {
    threadId: "voice-controller-1",
    callId: `call-${index}`,
    tool: { name: toolName },
    arguments: JSON.stringify(toolName === "assistant_open_view"
      ? { destination: "today" }
      : { taskID: "task-1", request: "Check Downloads" })
  }, index + 1);
  assert.equal(handled, true);
}
await new Promise((resolve) => setImmediate(resolve));
assert.deepEqual(calls.map((call) => call.toolName), expectedTools);
assert.equal(responses.length, expectedTools.length);
assert.equal(responses.every(({ result }) => result.success === true), true);
assert.equal(toolStates.filter(({ state }) => state === "started").length, expectedTools.length);
assert.equal(toolStates.filter(({ state }) => state === "completed").length, expectedTools.length);

assert.equal(bridge.handle("item/toolCall", {
  threadId: "voice-controller-1",
  toolCall: {
    id: "nested-call",
    name: "assistant_task_status",
    input: { taskID: "task-1" }
  }
}, 10), true);
await new Promise((resolve) => setImmediate(resolve));
assert.equal(calls.at(-1).callID, "nested-call");
assert.equal(calls.at(-1).toolName, "assistant_task_status");

bridge.handle("item/tool/call", {
  threadId: "some-normal-chat",
  callId: "wrong-thread",
  name: "assistant_delegate_work",
  arguments: "{}"
}, 20);
bridge.handle("item/tool/call", {
  threadId: "voice-controller-1",
  name: "assistant_delegate_work",
  arguments: "{}"
}, 21);
bridge.handle("item/tool/call", {
  threadId: "voice-controller-1",
  callId: "unsupported",
  name: "computer_use",
  arguments: "{}"
}, 22);
assert.equal(responses.at(-3).result.success, false);
assert.match(responses.at(-3).result.contentItems[0].text, /does not belong/i);
assert.match(responses.at(-2).result.contentItems[0].text, /without a call ID/i);
assert.match(responses.at(-1).result.contentItems[0].text, /unsupported/i);

assert.equal(codexSubscriptionNativeActionMethod("item/commandExecution/requestApproval"), true);
assert.equal(codexSubscriptionNativeActionMethod("item/collabAgentSpawn/request"), true);
assert.equal(codexSubscriptionNativeActionMethod("item/tool/call"), false);
assert.equal(bridge.handle("item/commandExecution/requestApproval", {
  threadId: "voice-controller-1"
}, 30), true);
assert.equal(routingFailures.length, 1);
assert.match(responses.at(-1).result.contentItems[0].text, /assistant_delegate_work/i);

const hiddenDelivery = encodeCodexSubscriptionDelivery(
  "delivery-task-1",
  "The Downloads check finished.",
  "Claude"
);
assert.equal(parseCodexSubscriptionDelivery(hiddenDelivery)?.deliveryID, "delivery-task-1");
assert.equal(parseCodexSubscriptionDelivery("The Downloads check finished."), null);
const hiddenCorrection = encodeCodexSubscriptionCorrection("correction-1");
assert.equal(parseCodexSubscriptionCorrection(hiddenCorrection)?.correctionID, "correction-1");
assert.equal(parseCodexSubscriptionCorrection("Checking now."), null);
assert.doesNotMatch(JSON.stringify(responses), /OPENASSIST_INTERNAL_DELIVERY/);

assert.equal(looksLikeActionAcknowledgement("Checking now."), true);
assert.equal(looksLikeActionAcknowledgement("On it."), true);
assert.equal(looksLikeActionAcknowledgement("Sorry, I didn't check that yet."), true);
assert.equal(looksLikeActionAcknowledgement("Let me take a quick look."), true);
assert.equal(looksLikeActionAcknowledgement("One moment, moving that."), true);
assert.equal(looksLikeActionAcknowledgement("Finishing up."), true);
assert.equal(looksLikeActionAcknowledgement("Sure, hold on."), true);
assert.equal(looksLikeActionAcknowledgement("The note says the meeting is Friday."), false);

const actionRegistry = new LiveVoiceCapabilityRegistry([{
  id: "test_note_read",
  description: "Read a test note",
  operations: ["read"],
  source: "test_notes",
  keywords: ["apple notes", "read note"],
  inputSchema: { type: "object", properties: {}, required: [], additionalProperties: false },
  risk: "read",
  executionMode: "blocking",
  timeoutMs: 1_000,
  idempotency: "turn"
}]);
const actionCoordinator = new LiveVoiceCoordinator({
  registry: actionRegistry,
  executeCapability: async () => ({ note: "A tracked note result" }),
  delegateWork: async () => ({ status: "running", taskID: "task-real" }),
  taskStatus: async () => ({ status: "running", taskID: "task-real" }),
  cancelTask: async () => ({ status: "cancelled", taskID: "task-real" }),
  openView: async (destination) => ({ ok: true, destination })
});
const emptyActionTurn = actionCoordinator.beginTurn("codexSubscription", "Check Apple Notes", "turn-empty");
const firstUngrounded = actionCoordinator.assessAssistantActionClaim(emptyActionTurn, "Checking now.");
assert.equal(firstUngrounded.grounded, false);
assert.equal(firstUngrounded.shouldCorrect, true);
assert.equal(actionCoordinator.assessAssistantActionClaim(emptyActionTurn, "On it.").shouldCorrect, false);

const capabilityTurn = actionCoordinator.beginTurn("codexSubscription", "Read Apple Notes", "turn-capability");
const capabilityResult = await actionCoordinator.capability(capabilityTurn, "call-capability", {
  goal: "Read Apple Notes",
  operation: "read",
  capabilityID: "test_note_read",
  arguments: {}
});
assert.equal(capabilityResult.status, "completed");
assert.equal(actionCoordinator.assessAssistantActionClaim(capabilityTurn, "Checking now.").grounded, true);
assert.equal(actionCoordinator.snapshot().turns[capabilityTurn].actionOwner, "capability");
assert.ok(actionCoordinator.snapshot().turns[capabilityTurn].operationID);

const delegationTurn = actionCoordinator.beginTurn("codexSubscription", "Ask Codex to inspect Downloads", "turn-delegation");
const delegationResult = await actionCoordinator.delegate(delegationTurn, "call-delegation", {
  goal: "Ask Codex to inspect Downloads",
  provider: "codex"
});
assert.equal(delegationResult.taskID, "task-real");
assert.equal(actionCoordinator.snapshot().turns[delegationTurn].actionOwner, "delegation");
assert.equal(actionCoordinator.snapshot().turns[delegationTurn].taskID, "task-real");

const taskCoordinator = new RealtimeTaskCoordinator(6, () => 1_000);
const claudeTask = taskCoordinator.start({
  taskID: "live-task-claude",
  callID: "delegate-claude",
  sourceTurnID: "turn-claude",
  prompt: "Check Downloads",
  workerProvider: "Claude",
  requestedProvider: "claude",
  kind: "single"
});
assert.equal(claudeTask.ok, true);
assert.equal(claudeTask.task.workerProvider, "Claude");
assert.equal(claudeTask.task.requestedProvider, "claude");

const codexTask = taskCoordinator.start({
  taskID: "live-task-codex",
  callID: "delegate-codex",
  sourceTurnID: "turn-codex",
  prompt: "Inspect repository logs",
  workerProvider: "Codex",
  requestedProvider: "codex",
  kind: "parallel"
});
assert.equal(codexTask.ok, true);
assert.equal(codexTask.task.workerProvider, "Codex");
assert.equal(codexTask.task.requestedProvider, "codex");

console.log("Codex subscription coordinator checks passed.");
