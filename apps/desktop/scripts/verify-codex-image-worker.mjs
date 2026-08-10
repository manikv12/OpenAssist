import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { __realtimeProtocolTestHooks } from "../dist-electron/realtimeProxy.js";

const bridge = await readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");
const app = await readFile(new URL("../src/App.tsx", import.meta.url), "utf8");
const nativeHelperBuild = await readFile(new URL("./build-native-helpers.sh", import.meta.url), "utf8");
assert.match(bridge, /async function runCodexImageGenerationJob/);
assert.match(bridge, /ephemeral: true/);
assert.match(bridge, /persistExtendedHistory: false/);
assert.match(bridge, /imageGenerationSkillPromptItems\(promptText, true\)/);
assert.match(bridge, /saveCodexGeneratedImageArtifact/);
assert.match(bridge, /prepareCodexImageBackground/);
assert.match(bridge, /codexImageBackgroundInstructions/);
assert.match(bridge, /background was removed locally with macOS Vision/);
assert.match(bridge, /removeImageBackgroundWithVision/);
assert.match(bridge, /backgroundMode/);
assert.match(bridge, /codex-image-worker-records\.jsonl/);
assert.match(bridge, /<openassist_tool_call>/);
assert.match(app, /codexImageWorkerMentionID/);

const descriptors = __realtimeProtocolTestHooks.liveVoiceCapabilityDescriptors(() => ({ codexImageGeneration: {} }));
const image = descriptors.find((item) => item.id === "codex_image_generation");
assert.ok(image);
assert.equal(image.source, "codex_image");
assert.equal(image.idempotency, "required");
const imageBackground = await readFile(new URL("../electron/imageBackground.ts", import.meta.url), "utf8");
const visionBackgroundHelper = await readFile(new URL("../electron/helpers/vision-background-helper.swift", import.meta.url), "utf8");
assert.match(imageBackground, /apple_vision_mask/);
assert.doesNotMatch(imageBackground, /BiRefNet|chromaKey|colorKey/i);
assert.match(visionBackgroundHelper, /VNGenerateForegroundInstanceMaskRequest/);
assert.doesNotMatch(visionBackgroundHelper, /chroma|greenKey|colorKey/i);
assert.match(nativeHelperBuild, /vision-background-helper\.swift/);
assert.match(nativeHelperBuild, /-framework Vision/);
assert.doesNotMatch(imageBackground, /greenKeyStrength|isChromaGreen|remove_chroma_key/);
assert.deepEqual(__realtimeProtocolTestHooks.liveVoicePublicToolSpecs.map((item) => item.name).slice(0, 4), [
  "assistant_capability",
  "assistant_delegate_work",
  "assistant_task_status",
  "assistant_cancel_task"
]);

console.log("Codex image capability checks passed.");
