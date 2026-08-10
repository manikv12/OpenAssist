import assert from "node:assert/strict";
import { RealtimeTaskCoordinator } from "../dist-electron/realtimeTaskCoordinator.js";

function deferredWorker() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

async function runMockWorker(coordinator, input, worker) {
  const started = coordinator.start(input);
  if (!started.ok) return started;
  try {
    const result = await worker({
      taskID: started.task.taskID,
      prompt: started.task.prompt,
      onProgress: (progress) => coordinator.updateProgress(started.task.taskID, progress)
    });
    coordinator.complete(started.task.taskID, result);
  } catch (error) {
    if (coordinator.get(started.task.taskID)?.state !== "cancelled") {
      coordinator.fail(started.task.taskID, error instanceof Error ? error.message : String(error));
    }
  }
  return started;
}

let now = 1_000;
const coordinator = new RealtimeTaskCoordinator(6, () => now);
const firstWorker = deferredWorker();
const firstRun = runMockWorker(
  coordinator,
  {
    taskID: "task-1",
    scopeKey: "voice-log-a",
    sourceTurnID: "turn-1",
    userText: "Can you check whether the repository build passes?",
    prompt: "Check the repository build",
    workerProvider: "Codex"
  },
  async ({ onProgress }) => {
    onProgress("Reading package.json");
    return firstWorker.promise;
  }
);

await Promise.resolve();
assert.equal(coordinator.activeCount(), 1);
assert.equal(coordinator.get("task-1")?.progress, "Reading package.json");
for (let index = 0; index < 25; index += 1) {
  coordinator.updateProgress("task-1", `Progress update ${index}`);
}
assert.equal(coordinator.get("task-1")?.progressEntries.length, 20, "Progress history must stay bounded.");
assert.equal(coordinator.get("task-1")?.progressEntries[0]?.text, "Progress update 5");
assert.equal(coordinator.visible("voice-log-a").some((task) => task.taskID === "task-1"), true);
assert.equal(
  coordinator.get("task-1")?.userText,
  "Can you check whether the repository build passes?",
  "The Voice Log must keep the user's words rather than the worker's rewritten prompt."
);

// Normal conversation stays responsive while the worker is still pending.
const directAnswer = await Promise.resolve("You have one reminder today.");
assert.equal(directAnswer, "You have one reminder today.");
assert.equal(coordinator.get("task-1")?.state, "running");

// A follow-up belongs to the existing running task and cannot create another
// Agent Work item. Keep only compact, bounded follow-up history.
coordinator.addFollowUp("task-1", "Use the other signed-in account instead.");
assert.equal(coordinator.activeCount(), 1);
assert.equal(coordinator.get("task-1")?.followUps.length, 1);
assert.match(coordinator.get("task-1")?.progress ?? "", /Follow-up queued/i);
for (let index = 0; index < 12; index += 1) {
  coordinator.addFollowUp("task-1", `Refinement ${index}`);
}
assert.equal(coordinator.get("task-1")?.followUps.length, 10, "Follow-up history must stay bounded.");

// Duplicate protection is scoped to one Voice Log, not the whole app.
const duplicate = coordinator.start({
  taskID: "task-duplicate",
  scopeKey: "voice-log-a",
  sourceTurnID: "turn-duplicate",
  prompt: "  Check the repository build!  ",
  workerProvider: "Codex"
});
assert.equal(duplicate.ok, false);
assert.equal(duplicate.reason, "duplicate");
assert.equal(coordinator.start({
  taskID: "task-other-log",
  scopeKey: "voice-log-b",
  prompt: "Check the repository build"
}).ok, true);

firstWorker.resolve("The build passes.");
await firstRun;
assert.equal(coordinator.get("task-1")?.result, "The build passes.");
assert.equal(coordinator.latestRelevant("voice-log-a")?.state, "completed");

// Persistence and delivery are each one-shot, and delivery is FIFO.
assert.equal(coordinator.markPersisted("task-1"), true);
assert.equal(coordinator.markPersisted("task-1"), false);
now += 100;
coordinator.complete("task-other-log", "The second scope also passes.");
assert.deepEqual(coordinator.pendingDelivery().map((task) => task.taskID), ["task-1", "task-other-log"]);
assert.equal(coordinator.markDelivery("task-1", "queued"), true);
assert.equal(coordinator.markDelivery("task-1", "speaking"), true);
assert.equal(coordinator.markDelivery("task-1", "delivered"), true);
assert.equal(coordinator.markDelivery("task-1", "queued"), false);

// An empty worker response is a failure, never a fake completion message.
await runMockWorker(
  coordinator,
  { taskID: "task-empty", scopeKey: "voice-log-a", prompt: "Inspect the logs" },
  async () => ""
);
assert.equal(coordinator.get("task-empty")?.state, "failed");
assert.match(coordinator.get("task-empty")?.error ?? "", /without returning an answer/i);

// Cancellation belongs to the selected task and does not stop voice itself.
const cancellableWorker = deferredWorker();
const cancelRun = runMockWorker(
  coordinator,
  { taskID: "task-cancel", scopeKey: "voice-log-a", prompt: "Watch the deployment" },
  async () => cancellableWorker.promise
);
await Promise.resolve();
const cancelled = coordinator.cancel("task-cancel", "Stopped by the user.");
cancellableWorker.reject(new Error("aborted"));
await cancelRun;
assert.equal(cancelled?.state, "cancelled");
assert.equal(coordinator.get("task-cancel")?.error, "Stopped by the user.");

// The six-task cap applies across workers and scopes.
const limited = new RealtimeTaskCoordinator(6, () => now);
for (let index = 1; index <= 6; index += 1) {
  assert.equal(limited.start({
    taskID: `limit-${index}`,
    scopeKey: index % 2 ? "voice-log-a" : "voice-log-b",
    prompt: `Run independent task ${index}`,
    workerProvider: index % 2 ? "Codex" : "Claude",
    kind: "parallel"
  }).ok, true);
}
assert.equal(limited.activeCount(), 6);
assert.equal(limited.start({ taskID: "limit-7", prompt: "One task too many" }).reason, "limit");

// Status still finds a completed result, including after it has been spoken.
const statusCoordinator = new RealtimeTaskCoordinator(6, () => now);
statusCoordinator.start({ taskID: "status-task", prompt: "Check my reminders" });
statusCoordinator.complete("status-task", "You have one reminder.");
assert.equal(statusCoordinator.latestRelevant()?.state, "completed");
statusCoordinator.markDelivery("status-task", "delivered");
assert.equal(statusCoordinator.latestRelevant()?.state, "completed");
assert.equal(statusCoordinator.visible().some((task) => task.taskID === "status-task"), true, "A fresh completed task remains visible briefly.");

limited.complete("limit-1", "Finished task one.");
limited.markDelivery("limit-1", "delivered");
for (let index = 2; index <= 6; index += 1) limited.cancel(`limit-${index}`);

// Stalled work is cancelled cleanly so it cannot become a phantom task.
const staleCoordinator = new RealtimeTaskCoordinator(6, () => now);
staleCoordinator.start({ taskID: "stale", prompt: "Wait forever" });
now += 11 * 60_000;
const stale = staleCoordinator.evictStale(10 * 60_000);
assert.equal(stale.length, 1);
assert.equal(stale[0].state, "cancelled");

// Clearing one day's Voice Log removes only that scope's finished Agent Work.
// Running work blocks the clear so a late result cannot be lost.
const clearCoordinator = new RealtimeTaskCoordinator(6, () => now);
clearCoordinator.start({ taskID: "clear-active", scopeKey: "voice-log-clear", prompt: "Finish this first" });
assert.deepEqual(clearCoordinator.clearScope("voice-log-clear"), { ok: false, reason: "active", removed: 0 });
clearCoordinator.complete("clear-active", "Finished.");
clearCoordinator.start({ taskID: "keep-other-day", scopeKey: "voice-log-keep", prompt: "Keep this result" });
clearCoordinator.complete("keep-other-day", "Kept.");
assert.deepEqual(clearCoordinator.clearScope("voice-log-clear"), { ok: true, removed: 1 });
assert.equal(clearCoordinator.get("clear-active"), undefined);
assert.equal(clearCoordinator.get("keep-other-day")?.result, "Kept.");
assert.deepEqual(clearCoordinator.pendingDelivery().map((task) => task.taskID), ["keep-other-day"]);

console.log("Live Voice orchestration checks passed.");
