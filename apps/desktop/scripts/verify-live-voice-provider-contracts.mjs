import assert from "node:assert/strict";
import { liveVoicePublicToolSpecs } from "../dist-electron/liveVoice/providerAdapters.js";
import { __realtimeProtocolTestHooks } from "../dist-electron/realtimeProxy.js";

const expectedNames = [
  "assistant_capability",
  "assistant_delegate_work",
  "assistant_task_status",
  "assistant_cancel_task",
  "assistant_open_view"
];

assert.deepEqual(liveVoicePublicToolSpecs.map((tool) => tool.name), expectedNames);
assert.deepEqual(__realtimeProtocolTestHooks.liveVoicePublicToolSpecs.map((tool) => tool.name), expectedNames);

const config = {
  model: "gpt-realtime",
  voice: "marin",
  handoff: { agentLabel: "Worker" }
};
const openAI = __realtimeProtocolTestHooks.realtimeSessionConfig(config, "", false);
const gemini = __realtimeProtocolTestHooks.geminiLiveSessionConfig(
  { AUDIO: "AUDIO" },
  { ...config, model: "gemini-live-model" },
  ""
);

const openAITools = openAI.tools;
const geminiTools = gemini.tools[0].functionDeclarations;
assert.deepEqual(openAITools.map((tool) => tool.name), expectedNames);
assert.deepEqual(geminiTools.map((tool) => tool.name), expectedNames);
for (let index = 0; index < expectedNames.length; index += 1) {
  assert.equal(openAITools[index].description, geminiTools[index].description);
  assert.deepEqual(Object.keys(openAITools[index].parameters.properties), Object.keys(geminiTools[index].parameters.properties));
}

const delegateTool = openAITools.find((tool) => tool.name === "assistant_delegate_work");
const geminiDelegateTool = geminiTools.find((tool) => tool.name === "assistant_delegate_work");
assert.ok(delegateTool.parameters.properties.executionProfile);
assert.ok(geminiDelegateTool.parameters.properties.executionProfile);
assert.deepEqual(delegateTool.parameters.properties.mode.enum, ["new", "follow_up", "rerun"]);
assert.ok(delegateTool.parameters.properties.taskID);
assert.ok(geminiDelegateTool.parameters.properties.taskID);
assert.deepEqual(
  Object.keys(delegateTool.parameters.properties.executionProfile.properties),
  ["depth", "complexity", "impact", "stakes", "modelPreference"]
);
assert.equal(JSON.stringify(openAI.tools).includes("web_search"), false);
assert.equal(JSON.stringify(gemini.tools).toLowerCase().includes("googlesearch"), false);
assert.equal(openAI.audio.input.turn_detection.type, "semantic_vad");
assert.equal(
  gemini.realtimeInputConfig.automaticActivityDetection.startOfSpeechSensitivity,
  "START_SENSITIVITY_HIGH"
);
assert.equal(gemini.realtimeInputConfig.turnCoverage, "TURN_INCLUDES_ONLY_ACTIVITY");

assert.match(openAI.instructions, /exactly five OpenAssist tools/i);
assert.match(gemini.systemInstruction, /exactly five OpenAssist tools/i);
assert.match(openAI.instructions, /candidate counts or candidate lists are private working context/i);
assert.match(gemini.systemInstruction, /do not switch source, provider, worker, or tool after a failure/i);
assert.match(openAI.instructions, /current web research/i);
assert.match(gemini.systemInstruction, /modelPreference to spark or sol only when the user explicitly names that model/i);
assert.match(openAI.instructions, /mode=follow_up/i);
assert.match(gemini.systemInstruction, /must not create another agent/i);
assert.match(openAI.instructions, /mode=rerun/i);
assert.match(gemini.systemInstruction, /backend reuses the original work goal/i);

const descriptors = __realtimeProtocolTestHooks.liveVoiceCapabilityDescriptors(() => ({
  knowledge: { enabled: true },
  localMCP: { enabled: true },
  codexImageGeneration: {}
}));
assert.ok(descriptors.some((item) => item.id === "knowledge_personal_recall"));
assert.ok(descriptors.some((item) => item.id === "knowledge_today_tasks_combined"));
assert.ok(descriptors.some((item) => item.id === "local_mcp_discover"));
assert.ok(descriptors.some((item) => item.id === "local_mcp_execute"));
assert.ok(descriptors.some((item) => item.id === "codex_image_generation"));

for (const descriptor of descriptors) {
  assert.ok(descriptor.id);
  assert.ok(descriptor.description);
  assert.ok(descriptor.operations.length);
  assert.ok(descriptor.source);
  assert.ok(descriptor.inputSchema);
  assert.ok(["read", "reversible_write", "sensitive_write"].includes(descriptor.risk));
  assert.ok(["blocking", "background"].includes(descriptor.executionMode));
  assert.ok(descriptor.timeoutMs > 0);
}

console.log("Live Voice provider contract verification passed.");
