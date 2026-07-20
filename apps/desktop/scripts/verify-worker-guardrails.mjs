import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const bridge = await readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");
const proxy = await readFile(new URL("../electron/realtimeProxy.ts", import.meta.url), "utf8");
const coordinator = await readFile(new URL("../electron/liveVoice/coordinator.ts", import.meta.url), "utf8");
const taskCoordinator = await readFile(new URL("../electron/realtimeTaskCoordinator.ts", import.meta.url), "utf8");

// Worker guardrails: oa_* tools only for user data, no osascript/db improvising,
// report exact errors instead of inventing alternate paths.
const workerPrompt = bridge.match(/function realtimeWorkerExecutionPrompt[\s\S]*?\n}\n/)?.[0] ?? "";
assert.ok(workerPrompt, "realtimeWorkerExecutionPrompt must exist");
assert.match(workerPrompt, /use the oa_\* tools only/);
assert.match(workerPrompt, /Never use AppleScript\/osascript/);
assert.match(workerPrompt, /stop and report the exact error; do not invent an alternate path/);

// Result contract: plain-text headings the narration layer can rely on.
assert.match(workerPrompt, /Result, Sources, Actions taken, and Open questions/);

// Delegation briefs: session-discovered resource ids reach the worker prompt.
assert.match(workerPrompt, /Known context \(ids you can use directly\):/);
assert.match(coordinator, /contextResources: this\.contextResources\(\)\.slice\(0, 8\)/, "coordinator.delegate must attach discovered resources");
assert.match(proxy, /contextResources: request\.contextResources/, "delegateCoordinatorWork must forward contextResources");
assert.match(proxy, /contextResources: options\.contextResources/, "startCodexHandoff must store contextResources on the task");
assert.match(proxy, /contextResources: task\.contextResources/, "startExternalHandoff must pass contextResources to the handoff run");
assert.match(taskCoordinator, /contextResources\?: LiveVoiceContextResource\[\]/, "task records must carry contextResources");
assert.match(bridge, /realtimeWorkerExecutionPrompt\(promptText, worker, contextResources\)/, "the bridge handoff must feed contextResources into the worker prompt");

console.log("Worker guardrail and delegation brief checks passed.");
