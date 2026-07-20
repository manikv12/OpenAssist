import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { __realtimeProtocolTestHooks } from "../dist-electron/realtimeProxy.js";

const expected = [
  "assistant_capability",
  "assistant_delegate_work",
  "assistant_task_status",
  "assistant_cancel_task"
];
assert.deepEqual(__realtimeProtocolTestHooks.liveVoicePublicToolSpecs.map((tool) => tool.name), expected);

const source = await readFile(new URL("../electron/realtimeProxy.ts", import.meta.url), "utf8");
assert.doesNotMatch(source, /classifyRealtimeRequest|decideRealtimeDelegation|__realtimeRouterTestHooks/);
assert.match(source, /new LiveVoiceCoordinator/);
assert.match(source, /new LiveVoiceCapabilityRegistry/);
assert.match(source, /selection_required/);

console.log("Realtime coordinator routing checks passed.");
