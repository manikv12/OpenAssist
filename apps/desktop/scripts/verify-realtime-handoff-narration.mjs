import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { RealtimeTaskCoordinator } from "../dist-electron/realtimeTaskCoordinator.js";

const tasks = new RealtimeTaskCoordinator();
tasks.enqueueResult({ deliveryID: "result-1", sourceTurnID: "turn-1", kind: "delegated", text: "The work finished.", label: "Worker", createdAt: 1 });
assert.equal(tasks.nextResult()?.deliveryID, "result-1");
tasks.markResultDelivery("result-1", "speaking");
tasks.markResultDelivery("result-1", "queued");
assert.equal(tasks.nextResult()?.deliveryID, "result-1", "Barge-in must requeue the same result.");
tasks.markResultDelivery("result-1", "delivered");
assert.equal(tasks.nextResult(), undefined);

const source = await readFile(new URL("../electron/realtimeProxy.ts", import.meta.url), "utf8");
assert.match(source, /interruptResultNarration\(reason === "speech"\)/);
assert.match(source, /claimFinalDelivery\(finished\.sourceTurnID, finished\.id\)/);
assert.match(source, /taskCoordinator\.nextResult\(\)/);
assert.match(source, /taskCoordinator\.markResultDelivery\(next\.id, "speaking"\)/);

// Delegated results must be narrated with a short recap of the task they answer,
// because the user may have moved on to other topics while the worker ran.
assert.match(source, /Start with one very short clause naming what this answers/);
assert.match(source, /The task this result answers: \$\{recap\}/);

// Single delegated tasks reuse one shared Codex worker thread per Live Voice
// session (context carries across follow-ups) unless freshThread is requested.
const bridgeSource = await readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");
assert.match(bridgeSource, /liveVoiceWorkerThreadID/);
assert.match(bridgeSource, /if \(freshThread\) retireLiveVoiceWorkerThread\(\);/);
assert.match(bridgeSource, /usesSessionWorkerThread/);
assert.match(source, /freshThread: task\.freshThread,/);

console.log("Realtime result narration checks passed.");
