import assert from "node:assert/strict";
import { RealtimeTaskCoordinator } from "../dist-electron/realtimeTaskCoordinator.js";

let now = 100;
const tasks = new RealtimeTaskCoordinator(4, () => now);
assert.equal(tasks.start({ taskID: "first", sourceTurnID: "turn-1", prompt: "Inspect the build", kind: "parallel" }).ok, true);
assert.equal(tasks.start({ taskID: "second", sourceTurnID: "turn-2", prompt: "Review the test output", kind: "parallel" }).ok, true);
tasks.complete("second", "Second finished first.");
tasks.enqueueResult({ deliveryID: "second-result", sourceTurnID: "turn-2", taskID: "second", kind: "delegated", text: "Second finished first.", label: "Worker", createdAt: now });
now += 10;
tasks.complete("first", "First finished later.");
tasks.enqueueResult({ deliveryID: "first-result", sourceTurnID: "turn-1", taskID: "first", kind: "delegated", text: "First finished later.", label: "Worker", createdAt: now });
assert.equal(tasks.nextResult()?.deliveryID, "second-result");
tasks.markResultDelivery("second-result", "delivered");
assert.equal(tasks.nextResult()?.deliveryID, "first-result");
assert.equal(tasks.get("first")?.sourceTurnID, "turn-1");
assert.equal(tasks.get("second")?.sourceTurnID, "turn-2");

console.log("Parallel task and FIFO delivery checks passed.");
