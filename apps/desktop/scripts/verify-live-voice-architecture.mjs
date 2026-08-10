import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { LiveVoiceCapabilityRegistry } from "../dist-electron/liveVoice/capabilityRegistry.js";
import { LiveVoiceCoordinator, voiceControlForText } from "../dist-electron/liveVoice/coordinator.js";
import {
  providerConnectionClosed,
  providerConnectionRestored,
  providerInterrupted
} from "../dist-electron/liveVoice/providerAdapters.js";
import { RealtimeTaskCoordinator } from "../dist-electron/realtimeTaskCoordinator.js";
import { NativePermissionBroker } from "../dist-electron/nativeAccess.js";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const desktopRoot = path.resolve(scriptDirectory, "..");

function descriptor(overrides) {
  return {
    id: "openassist_note_read",
    description: "Read a saved note.",
    operations: ["read"],
    source: "openassist_notes",
    sourceAliases: ["notes", "OpenAssist Notes"],
    keywords: ["note", "saved document"],
    inputSchema: { type: "object", properties: {} },
    risk: "read",
    executionMode: "blocking",
    timeoutMs: 1_000,
    idempotency: "turn",
    ...overrides
  };
}

function makeCoordinator({ descriptors, executeCapability, delegateWork, taskStatus, cancelTask, checkPermissions, requestPermission, contextResources, now } = {}) {
  const registry = new LiveVoiceCapabilityRegistry(descriptors ?? [
    descriptor({}),
    descriptor({
      id: "apple_reminders_read",
      description: "Read Apple Reminders.",
      source: "apple_reminders",
      sourceAliases: ["Apple Reminders"],
      keywords: ["reminder", "todo"]
    })
  ]);
  return new LiveVoiceCoordinator({
    registry,
    executeCapability: executeCapability ?? (async (selected) => ({ ok: true, capabilityID: selected.id })),
    delegateWork: delegateWork ?? (async () => ({ status: "running", taskID: "task-1" })),
    taskStatus: taskStatus ?? (async () => ({ tasks: [] })),
    cancelTask: cancelTask ?? (async () => ({ cancelled: true })),
    checkPermissions,
    requestPermission,
    contextResources: contextResources ? () => contextResources : undefined,
    now
  });
}

function begin(coordinator, text = "Read my saved note.", provider = "openaiRealtime") {
  coordinator.open();
  return coordinator.beginTurn(provider, text, `${provider}-item-${Math.random()}`);
}

async function grantCapability(coordinator, turnID, callID, request) {
  assert.ok(coordinator && turnID && callID && request.capabilityID);
  // A single unambiguous capability now executes immediately. Explicit IDs
  // are still checked against discovery, so tests can call the exact
  // capability directly without a separate selection-grant round trip.
  return { status: "not_required" };
}

assert.equal(voiceControlForText("Stop listening").action, "stop_listening");
assert.equal(voiceControlForText("Please cancel the background task").handled, false, "Task cancellation is not a voice-stop command.");
assert.equal(voiceControlForText("Thanks").handled, false);

{
  const coordinator = makeCoordinator();
  const turnID = begin(coordinator);
  const automatic = await coordinator.capability(turnID, "call-select", {
    goal: "Read a saved item.",
    operation: "read"
  });
  assert.equal(automatic.status, "completed");
  assert.equal(automatic.capabilityID, "openassist_note_read");

  const selection = await coordinator.capability(turnID, "call-exact", {
    goal: "Read my saved note.",
    operation: "read",
    sourceHints: ["OpenAssist Notes"]
  });
  assert.equal(selection.status, "completed");
  assert.equal(selection.capabilityID, "openassist_note_read");
  const selected = await coordinator.capability(turnID, "call-execute", {
    goal: "Read my saved note.",
    operation: "read",
    sourceHints: ["OpenAssist Notes"],
    capabilityID: "openassist_note_read"
  });
  assert.equal(selected.status, "completed");
  assert.equal(selected.capabilityID, "openassist_note_read");
}

{
  let executed = 0;
  let executedArguments;
  const coordinator = makeCoordinator({
    descriptors: [
      descriptor({
        id: "knowledge_read",
        description: "Read and summarize the selected OpenAssist note.",
        resourceKinds: ["openassist_note"],
        contextBindings: [{ resourceKind: "openassist_note", argument: "itemID", resourceField: "id" }]
      }),
      descriptor({
        id: "knowledge_note_style_guide",
        description: "Read the note formatting syntax guide.",
        source: "openassist_note_formatting",
        sourceAliases: ["note formatting"],
        keywords: ["format syntax callouts columns"]
      })
    ],
    contextResources: [{ kind: "openassist_note", id: "project_note:project-1:note-1", title: "OpenAssitWork" }],
    executeCapability: async (_descriptor, request) => {
      executed += 1;
      executedArguments = request.arguments;
      return { ok: true };
    }
  });
  const turnID = begin(coordinator, "Summarize the currently selected OpenAssist note.");
  const rejectedShortcut = await coordinator.capability(turnID, "call-wrong-shortcut", {
    goal: "Summarize the currently selected OpenAssist note.",
    operation: "read",
    capabilityID: "knowledge_note_style_guide"
  });
  assert.equal(rejectedShortcut.status, "selection_required");
  assert.deepEqual(rejectedShortcut.candidates?.map((candidate) => candidate.id), ["knowledge_read"]);
  assert.equal(executed, 0, "A provider-selected capability cannot bypass coordinator selection.");

  const completed = await coordinator.capability(turnID, "call-selected-note", {
    goal: "Summarize the currently selected OpenAssist note.",
    operation: "read",
    capabilityID: "knowledge_read",
    arguments: {}
  });
  assert.equal(completed.status, "completed");
  assert.equal(executedArguments?.itemID, "project_note:project-1:note-1", "Selected UI resource identity must bind into the capability arguments.");
}

{
  let calls = 0;
  const coordinator = makeCoordinator({
    descriptors: [descriptor({ id: "memory_read", source: "personal_memory", sourceAliases: ["memory"] })],
    executeCapability: async () => {
      calls += 1;
      if (calls === 1) throw new Error("temporary read failure");
      return { ok: true, answer: "Recovered on the same source." };
    }
  });
  const turnID = begin(coordinator, "Check memory.");
  await grantCapability(coordinator, turnID, "call-read", {
    goal: "Check memory.", operation: "read", capabilityID: "memory_read"
  });
  const result = await coordinator.capability(turnID, "call-read", {
    goal: "Check memory.",
    operation: "read",
    capabilityID: "memory_read"
  });
  assert.equal(result.status, "completed");
  assert.equal(calls, 2, "A read may retry once on the same capability.");
}

{
  let updateArguments;
  const reminderList = descriptor({
    id: "knowledge_apple_list_reminders",
    description: "List Apple Reminders.",
    source: "apple_reminders",
    sourceAliases: ["Apple Reminders"],
    keywords: ["reminders list"],
    resourceKinds: ["apple_reminder"],
    outputResources: [{
      resourceKind: "apple_reminder",
      path: ["reminders"],
      multiple: true,
      attributeFields: ["calendar", "completed"]
    }]
  });
  const reminderUpdate = descriptor({
    id: "knowledge_apple_update_reminder",
    description: "Update an Apple Reminder title or details.",
    operations: ["update"],
    source: "apple_reminders",
    sourceAliases: ["Apple Reminders"],
    keywords: ["edit rename reminder"],
    resourceKinds: ["apple_reminder"],
    contextBindings: [{ resourceKind: "apple_reminder", argument: "id", resourceField: "id" }],
    risk: "reversible_write",
    idempotency: "required"
  });
  const reminderComplete = descriptor({
    id: "knowledge_apple_complete_reminder",
    description: "Complete an Apple Reminder.",
    operations: ["complete"],
    source: "apple_reminders",
    sourceAliases: ["Apple Reminders"],
    keywords: ["finish done reminder"],
    resourceKinds: ["apple_reminder"],
    risk: "reversible_write",
    idempotency: "required"
  });
  const coordinator = makeCoordinator({
    descriptors: [reminderList, reminderUpdate, reminderComplete],
    executeCapability: async (selected, request) => {
      if (selected.id === reminderList.id) {
        return {
          ok: true,
          reminders: [{ id: "reminder-costco-ladder", title: "Get a ladder at Costco", calendar: "Costco", completed: false }]
        };
      }
      if (selected.id === reminderUpdate.id) updateArguments = request.arguments;
      return { ok: true, reminder: { id: request.arguments.id, title: request.arguments.title, completed: false } };
    }
  });

  const readTurn = begin(coordinator, "Show my Costco list in Apple Reminders.");
  await grantCapability(coordinator, readTurn, "call-reminder-list", {
    goal: "Show my Costco list in Apple Reminders.",
    operation: "read",
    sourceHints: ["Apple Reminders"],
    capabilityID: reminderList.id
  });
  const listed = await coordinator.capability(readTurn, "call-reminder-list-run", {
    goal: "Show my Costco list in Apple Reminders.",
    operation: "read",
    sourceHints: ["Apple Reminders"],
    capabilityID: reminderList.id
  });
  assert.equal(listed.status, "completed");
  assert.deepEqual(listed.resources?.map((resource) => resource.id), ["reminder-costco-ladder"]);

  const updateTurn = coordinator.beginTurn("geminiLive", "Rename Get a ladder at Costco to Ladder.", "gemini-reminder-update");
  const updated = await coordinator.capability(updateTurn, "call-reminder-update-run", {
    goal: "Rename Get a ladder at Costco to Ladder.",
    operation: "update",
    sourceHints: ["Apple Reminders"],
    capabilityID: reminderUpdate.id,
    arguments: { title: "Ladder" }
  });
  assert.equal(updated.status, "completed");
  assert.equal(updateArguments?.id, "reminder-costco-ladder", "A single recent reminder must bind by stable ID on the follow-up turn.");
  assert.equal(updateArguments?.title, "Ladder");
}

{
  let calls = 0;
  const coordinator = makeCoordinator({
    descriptors: [descriptor({
      id: "task_add",
      description: "Add one task.",
      operations: ["create"],
      source: "openassist_planner",
      risk: "reversible_write",
      idempotency: "required"
    })],
    executeCapability: async () => {
      calls += 1;
      throw new Error("write result unknown");
    }
  });
  const turnID = begin(coordinator, "Add a task.");
  const request = {
    goal: "Add a task.",
    operation: "create",
    capabilityID: "task_add",
    arguments: { title: "Prepare release notes" }
  };
  await grantCapability(coordinator, turnID, "call-write", request);
  assert.equal((await coordinator.capability(turnID, "call-write-1", request)).status, "failed");
  assert.equal((await coordinator.capability(turnID, "call-write-2", request)).status, "failed");
  assert.equal(calls, 1, "A write with an unknown result must never be blindly retried.");
}

{
  let executed = 0;
  const sensitiveA = descriptor({
    id: "note_replace",
    description: "Replace a full note.",
    operations: ["update"],
    source: "openassist_notes",
    risk: "sensitive_write",
    idempotency: "required"
  });
  const sensitiveB = descriptor({
    id: "task_batch_move",
    description: "Move several tasks.",
    operations: ["move"],
    source: "openassist_planner",
    risk: "sensitive_write",
    idempotency: "required"
  });
  const coordinator = makeCoordinator({
    descriptors: [sensitiveA, sensitiveB],
    executeCapability: async () => { executed += 1; return { ok: true }; }
  });
  const turnID = begin(coordinator, "Replace this note.");
  await grantCapability(coordinator, turnID, "call-approval-a", {
    goal: "Replace this note.", operation: "update", capabilityID: "note_replace"
  });
  const approval = await coordinator.capability(turnID, "call-approval-a", {
    goal: "Replace this note.", operation: "update", capabilityID: "note_replace", arguments: { body: "Updated" }
  });
  assert.equal(approval.status, "approval_required");

  await grantCapability(coordinator, turnID, "call-approval-b", {
    goal: "Move these tasks.", operation: "move", capabilityID: "task_batch_move"
  });
  const wrongAction = await coordinator.capability(turnID, "call-approval-b", {
    goal: "Move these tasks.", operation: "move", capabilityID: "task_batch_move", arguments: { count: 4 }, confirmationToken: approval.confirmationToken
  });
  assert.equal(wrongAction.status, "approval_required", "An approval token cannot authorize a different action.");

  await grantCapability(coordinator, turnID, "call-approved", {
    goal: "Replace this note.", operation: "update", capabilityID: "note_replace"
  });
  const completed = await coordinator.capability(turnID, "call-approved", {
    goal: "Replace this note.", operation: "update", capabilityID: "note_replace", arguments: { body: "Updated" }, confirmationToken: approval.confirmationToken
  });
  assert.equal(completed.status, "completed");
  assert.equal(executed, 1);
}

{
  let executed = 0;
  let executedArguments;
  const reminderWrite = descriptor({
    id: "knowledge_apple_add_reminder",
    description: "Create an Apple Reminder.",
    operations: ["create"],
    source: "apple_reminders",
    sourceAliases: ["Apple Reminders"],
    keywords: ["create recurring reminder"],
    risk: "sensitive_write",
    idempotency: "required"
  });
  const coordinator = makeCoordinator({
    descriptors: [reminderWrite],
    executeCapability: async (_descriptor, request) => {
      executed += 1;
      executedArguments = request.arguments;
      return { ok: true };
    }
  });
  const requestTurnID = begin(coordinator, "Create a weekly Apple Reminder for taking out the trash.");
  const approval = await coordinator.capability(requestTurnID, "call-reminder-approval", {
    goal: "Create a weekly Apple Reminder for taking out the trash.",
    operation: "create",
    capabilityID: "knowledge_apple_add_reminder",
    arguments: {
      title: "Take out the trash",
      dueDate: "2026-07-24T09:00:00-05:00",
      recurrence: { frequency: "weekly" }
    }
  });
  assert.equal(approval.status, "approval_required");

  const confirmationTurnID = begin(coordinator, "Yes confirmed");
  const completed = await coordinator.capability(confirmationTurnID, "call-reminder-confirmed", {
    goal: "Yes confirmed",
    operation: "create",
    capabilityID: "knowledge_apple_add_reminder",
    arguments: {}
  });
  assert.equal(completed.status, "completed", "A clear confirmation on the next voice turn must execute the saved action once.");
  assert.equal(executed, 1);
  assert.equal(executedArguments?.title, "Take out the trash");
  assert.deepEqual(executedArguments?.recurrence, { frequency: "weekly" });

  const duplicate = await coordinator.capability(confirmationTurnID, "call-reminder-confirmed-again", {
    goal: "Yes confirmed",
    operation: "create",
    capabilityID: "knowledge_apple_add_reminder",
    arguments: {}
  });
  assert.notEqual(duplicate.status, "completed", "A consumed approval must not execute a second time.");
  assert.equal(executed, 1);
}

{
  let resolveRead;
  const pendingRead = new Promise((resolve) => { resolveRead = resolve; });
  const coordinator = makeCoordinator({
    descriptors: [descriptor({})],
    executeCapability: async () => pendingRead
  });
  const turnID = begin(coordinator);
  await grantCapability(coordinator, turnID, "call-pending", {
    goal: "Read my note.", operation: "read", capabilityID: "openassist_note_read"
  });
  const running = coordinator.capability(turnID, "call-pending", {
    goal: "Read my note.", operation: "read", capabilityID: "openassist_note_read"
  });
  await Promise.resolve();
  assert.equal(coordinator.snapshot().turns[turnID].phase, "executing_capability");
  coordinator.recordProviderEvent(providerInterrupted("openaiRealtime", turnID, "speech"));
  assert.equal(coordinator.snapshot().turns[turnID].interrupted, false, "Barge-in must not kill an active capability result.");
  resolveRead({ ok: true });
  await running;
}

{
  const coordinator = makeCoordinator();
  const turnID = begin(coordinator, "Tell me a joke.");
  coordinator.recordProviderEvent(providerInterrupted("geminiLive", turnID, "speech"));
  assert.equal(coordinator.snapshot().turns[turnID].phase, "interrupted");
  coordinator.recordProviderEvent(providerConnectionClosed("geminiLive", "network changed"));
  assert.equal(coordinator.snapshot().session, "connecting");
  coordinator.recordProviderEvent(providerConnectionRestored("geminiLive"));
  assert.equal(coordinator.snapshot().session, "open");
}

{
  const coordinator = makeCoordinator();
  const turnID = begin(coordinator, "Give me the result.");
  assert.equal(coordinator.claimFinalDelivery(turnID, "delivery-1"), true);
  assert.equal(coordinator.claimFinalDelivery(turnID, "delivery-2"), false, "A voice turn may have only one final answer.");
  coordinator.completeTurn(turnID);
  coordinator.recordProviderEvent(providerInterrupted("openaiRealtime", turnID, "late duplicate"));
  assert.equal(coordinator.snapshot().turns[turnID].phase, "completed", "Late provider events cannot reopen a completed turn.");
}

{
  let cancelCalls = 0;
  const coordinator = makeCoordinator({ cancelTask: async () => { cancelCalls += 1; return { cancelled: true }; } });
  const unclearTurn = begin(coordinator, "What is happening with that task?");
  assert.equal((await coordinator.cancelTask(unclearTurn, "call-cancel-unclear")).status, "clarification_required");
  assert.equal(cancelCalls, 0);
  const cancelTurn = coordinator.beginTurn("openaiRealtime", "Cancel the background task.", "cancel-item");
  assert.equal((await coordinator.cancelTask(cancelTurn, "call-cancel-explicit")).status, "completed");
  assert.equal(cancelCalls, 1);
}

{
  let statusCalls = 0;
  const coordinator = makeCoordinator({
    taskStatus: async () => {
      statusCalls += 1;
      return {
        ok: true,
        taskID: "task-running",
        state: "running",
        terminal: false,
        summary: "The worker is still running."
      };
    }
  });
  const turnID = begin(coordinator, "Is that background work done?");
  const result = await coordinator.taskStatus(turnID, "call-task-status", "task-running");
  assert.equal(result.lookupStatus, "completed");
  assert.equal(result.state, "running");
  assert.equal(result.terminal, false, "Running work must never be reported as terminal.");
  assert.equal("status" in result, false, "The status lookup must not wrap running work in an ambiguous completed status.");
  assert.equal(statusCalls, 1, "Status questions must read the authoritative task source.");
}

{
  let delegated = 0;
  const coordinator = makeCoordinator({ delegateWork: async () => { delegated += 1; return { status: "running" }; } });
  const directTurn = begin(coordinator, "Read my project note.");
  assert.equal((await coordinator.delegate(directTurn, "call-direct-worker", { goal: "Read my project note." })).status, "selection_required");
  const workTurn = coordinator.beginTurn("openaiRealtime", "Fix the compiler errors in the repository.", "work-item");
  assert.equal((await coordinator.delegate(workTurn, "call-real-work", { goal: "Fix the compiler errors in the repository." })).status, "running");
  assert.equal(delegated, 1);
}

{
  let delegatedRequest;
  const coordinator = makeCoordinator({
    delegateWork: async (request) => {
      delegatedRequest = request;
      return { status: "running", taskID: "task-existing" };
    }
  });
  const turnID = begin(coordinator, "Send this correction to the agent that is already working.");
  const result = await coordinator.delegate(turnID, "call-follow-up", {
    goal: "Use the other signed-in account instead.",
    mode: "follow_up",
    taskID: "task-existing"
  });
  assert.equal(result.status, "running");
  assert.equal(delegatedRequest?.mode, "follow_up");
  assert.equal(delegatedRequest?.taskID, "task-existing");
}

{
  let delegatedRequest;
  const coordinator = makeCoordinator({
    delegateWork: async (request) => {
      delegatedRequest = request;
      return { status: "running", taskID: "task-rerun" };
    }
  });
  const turnID = begin(coordinator, "Run that finished work again with Sol.");
  const result = await coordinator.delegate(turnID, "call-rerun", {
    goal: "Run that finished work again with Sol.",
    mode: "rerun",
    taskID: "task-finished",
    executionProfile: { modelPreference: "sol" }
  });
  assert.equal(result.status, "running");
  assert.equal(delegatedRequest?.mode, "rerun");
  assert.equal(delegatedRequest?.taskID, "task-finished");
  assert.equal(delegatedRequest?.executionProfile?.modelPreference, "sol");
}

{
  let delegated = 0;
  const coordinator = makeCoordinator({ delegateWork: async () => { delegated += 1; return { status: "running" }; } });
  const turnID = begin(coordinator, "Read my project note.");
  const result = await coordinator.delegate(turnID, "call-invented-worker", {
    goal: "Read my project note.",
    provider: "Codex"
  });
  assert.equal(result.status, "selection_required", "A model-supplied worker name cannot bypass a direct capability.");
  assert.equal(delegated, 0);
}

{
  let executed = 0;
  const broker = new NativePermissionBroker();
  broker.register({
    id: "eventkit.reminders",
    owner: { kind: "eventkitHelper", displayName: "Signed Reminders Helper" },
    probe: () => ({ state: "denied", settingsURL: "x-apple.systempreferences:reminders" })
  });
  const coordinator = makeCoordinator({
    descriptors: [descriptor({
      id: "apple_reminders_read",
      description: "Read Apple Reminders.",
      source: "apple_reminders",
      sourceAliases: ["Apple Reminders"],
      permissionRequirements: [{ permissionID: "eventkit.reminders", access: "read" }]
    })],
    executeCapability: async () => { executed += 1; return { ok: true }; },
    checkPermissions: async (ids) => Promise.all(ids.map((id) => broker.get(id))),
    requestPermission: async (id) => broker.request(id)
  });
  const turnID = begin(coordinator, "Read Apple Reminders.");
  await grantCapability(coordinator, turnID, "call-reminders", {
    goal: "Read Apple Reminders.", operation: "read", capabilityID: "apple_reminders_read"
  });
  const result = await coordinator.capability(turnID, "call-reminders", {
    goal: "Read Apple Reminders.",
    operation: "read",
    capabilityID: "apple_reminders_read"
  });
  assert.equal(result.status, "permission_required");
  assert.equal(result.action, "open_settings");
  assert.equal(result.permissions?.[0]?.owner.displayName, "Signed Reminders Helper");
  assert.equal(executed, 0, "A blocked native capability must not execute or silently switch paths.");
}

{
  const coordinator = makeCoordinator({
    descriptors: [
      descriptor({ id: "saved_note_read_a" }),
      descriptor({ id: "saved_note_read_b" })
    ]
  });
  const turnID = begin(coordinator, "Find a saved item.");
  for (let step = 0; step < 8; step += 1) {
    const result = await coordinator.capability(turnID, `call-step-${step}`, { goal: "Find a saved item.", operation: "read" });
    assert.equal(result.status, "selection_required");
  }
  const limited = await coordinator.capability(turnID, "call-step-9", { goal: "Find a saved item.", operation: "read" });
  assert.equal(limited.status, "clarification_required");
  assert.equal(limited.errorCode, "tool_step_limit");
}

{
  const coordinator = makeCoordinator();
  coordinator.open();
  coordinator.updateBackgroundTask({ taskID: "task-pending", sourceTurnID: "turn-old", state: "running", updatedAt: 10 });
  coordinator.close();
  assert.equal(coordinator.snapshot().session, "closed");
  assert.equal(coordinator.snapshot().backgroundTasks["task-pending"].state, "running", "Stopping voice must not cancel background work.");
}

{
  const tasks = new RealtimeTaskCoordinator(6, () => 100);
  tasks.enqueueResult({
    deliveryID: "later",
    sourceTurnID: "turn-later",
    kind: "delegated",
    text: "Later result",
    label: "Agent",
    createdAt: 20
  });
  tasks.enqueueResult({
    deliveryID: "earlier",
    sourceTurnID: "turn-earlier",
    kind: "delegated",
    text: "Earlier result",
    label: "Agent",
    createdAt: 10
  });
  assert.equal(tasks.nextResult()?.deliveryID, "earlier");
  tasks.markResultDelivery("earlier", "speaking");
  tasks.markResultDelivery("earlier", "queued");
  assert.equal(tasks.nextResult()?.deliveryID, "earlier", "A result interrupted by a later utterance stays first in FIFO order.");
}

{
  let now = 100;
  const tasks = new RealtimeTaskCoordinator(6, () => now);
  const running = tasks.start({ taskID: "still-running", prompt: "Research current policy." });
  assert.equal(running.ok, true);
  now = 200;
  const finished = tasks.start({ taskID: "already-finished", prompt: "Read a local note." });
  assert.equal(finished.ok, true);
  now = 300;
  tasks.complete("already-finished", "Done.");
  assert.equal(
    tasks.latestRelevant()?.taskID,
    "still-running",
    "An active task must remain the relevant status even when another task finished more recently."
  );
  assert.deepEqual(
    tasks.recentFinished().map((task) => task.taskID),
    ["already-finished"],
    "The bounded result context must include terminal work without mixing in running tasks."
  );
}

const proxySource = await readFile(path.join(desktopRoot, "electron", "realtimeProxy.ts"), "utf8");
const bridgeSource = await readFile(path.join(desktopRoot, "electron", "openassistBridge.ts"), "utf8");
const appServerEnvironment = bridgeSource.slice(
  bridgeSource.indexOf("const appServerEnv = {"),
  bridgeSource.indexOf("bridgeDebugLog(`starting Codex app-server")
);
assert.match(
  appServerEnvironment,
  /PATH:\s*assistantPATH\(\)/,
  "The packaged app must provide Node's PATH when spawning the npm Codex app-server."
);
assert.match(proxySource, /appendUserText[\s\S]{0,800}beginContinuityUser/, "Typed input must enter the shared coordinator turn path.");
assert.match(proxySource, /input_audio_transcription\.completed[\s\S]{0,400}beginContinuityUser/, "Microphone input must enter the shared coordinator turn path.");
assert.match(proxySource, /# Authoritative Background Work State/, "An active worker must be published into the provider's current instructions.");
assert.match(proxySource, /Before answering whether delegated work is done[\s\S]{0,160}assistant_task_status/, "Status answers must consult the task coordinator.");
assert.match(proxySource, /statusSource:\s*"task_coordinator"[\s\S]{0,100}followUpAction:\s*"assistant_task_status"/, "Delegation must identify the authoritative status source.");
assert.match(proxySource, /request\.mode === "follow_up"[\s\S]{0,180}followUpCodexHandoff/, "Follow-ups must enter the existing-task continuation path.");
assert.match(proxySource, /request\.mode === "rerun"[\s\S]{0,120}rerunCodexHandoff/, "Finished work reruns must enter the coordinator's rerun path.");
assert.match(proxySource, /startCodexHandoff\(request\.callID, requested\.prompt/, "Reruns must reuse the original task goal instead of sending routing words to the worker.");
assert.match(proxySource, /sendClientContent\(\{ turns: text, turnComplete: true \}\)/, "Gemini text and worker results must use ordered durable conversation content.");
assert.match(proxySource, /Recent terminal Agent Work results/, "Completed worker results must remain in bounded provider context for follow-up questions.");
assert.match(bridgeSource, /const liveVoiceWorkerFollowUps = new Map/, "The Codex handoff must own a follow-up queue for running tasks.");
assert.match(bridgeSource, /providerPrompt = realtimeWorkerFollowUpPrompt\(followUp\.prompt\)/, "Queued follow-ups must continue in the same Codex worker thread.");
assert.match(proxySource, /name:\s*"knowledge_apple_update_reminder"[\s\S]{0,1600}operations:\s*\["update"\]/, "Live Voice must expose a dedicated Apple reminder update capability.");
assert.match(proxySource, /Never replace one operation with a different write operation/, "Providers must preserve the requested write operation.");
assert.doesNotMatch(proxySource, /function classifyRealtimeRequest|function decideRealtimeDelegation|Ollama delegation router/i);

console.log("Live Voice architecture verification passed.");
