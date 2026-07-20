import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const source = await readFile(new URL("../electron/realtimeProxy.ts", import.meta.url), "utf8");
assert.match(source, /function isAnswerBearingRealtimeTool[\s\S]{0,500}assistant_capability[\s\S]{0,300}assistant_cancel_task/);
assert.match(source, /response\.output_item\.added[\s\S]{0,700}gateAnswerBearingToolSpeech/);
assert.match(source, /response\.output_item\.done[\s\S]{0,800}handleFunctionCall/);
assert.match(source, /shouldDropGatedOpenAIAudio/);
assert.match(source, /onGeminiToolCalls[\s\S]{0,1800}toolGateDropActive = true/);
assert.match(source, /clearToolGate\("response\.done"\)/);
const openAIHandler = source.slice(
  source.indexOf("private async handleFunctionCall"),
  source.indexOf("private pendingOpenAIAudioPlayback")
);
const geminiHandler = source.slice(
  source.indexOf("private async onGeminiToolCalls"),
  source.indexOf("private sendGeminiAudioDelta")
);
assert.doesNotMatch(openAIHandler, /name === "knowledge_[^"]+"/);
assert.doesNotMatch(geminiHandler, /name === "knowledge_[^"]+"/);

console.log("Realtime four-tool gate checks passed.");
