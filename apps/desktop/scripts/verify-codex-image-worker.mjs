import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { __realtimeProtocolTestHooks } from "../dist-electron/realtimeProxy.js";

const bridge = await readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");
const app = await readFile(new URL("../src/App.tsx", import.meta.url), "utf8");
assert.match(bridge, /async function runCodexImageGenerationJob/);
assert.match(bridge, /ephemeral: true/);
assert.match(bridge, /persistExtendedHistory: false/);
assert.match(bridge, /imageGenerationSkillPromptItems\(promptText, true\)/);
assert.match(bridge, /saveCodexGeneratedImageArtifact/);
assert.match(bridge, /codex-image-worker-records\.jsonl/);
assert.match(bridge, /<openassist_tool_call>/);
assert.match(app, /codexImageWorkerMentionID/);

const descriptors = __realtimeProtocolTestHooks.liveVoiceCapabilityDescriptors(() => ({ codexImageGeneration: {} }));
const image = descriptors.find((item) => item.id === "codex_image_generation");
assert.ok(image);
assert.equal(image.source, "codex_image");
assert.equal(image.idempotency, "required");
assert.deepEqual(__realtimeProtocolTestHooks.liveVoicePublicToolSpecs.map((item) => item.name), [
  "assistant_capability",
  "assistant_delegate_work",
  "assistant_task_status",
  "assistant_cancel_task"
]);

console.log("Codex image capability checks passed.");
