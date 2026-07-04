import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");

function read(rel) {
  return fs.readFileSync(path.join(root, rel), "utf8");
}

function assertIncludes(source, needle, label) {
  if (!source.includes(needle)) {
    throw new Error(`${label} missing: ${needle}`);
  }
}

function assertMatches(source, pattern, label) {
  if (!pattern.test(source)) {
    throw new Error(`${label} missing pattern: ${pattern}`);
  }
}

const bridge = read("electron/openassistBridge.ts");
const realtime = read("electron/realtimeProxy.ts");
const app = read("src/App.tsx");
const packageJSON = JSON.parse(read("package.json"));

assertIncludes(bridge, "async function runCodexImageGenerationJob", "shared Codex image job");
assertIncludes(bridge, "ephemeral: true", "hidden Codex image worker thread");
assertIncludes(bridge, "persistExtendedHistory: false", "hidden Codex image worker history policy");
assertIncludes(bridge, "imageGenerationSkillPromptItems(promptText, true)", "forced imagegen skill attachment");
assertIncludes(bridge, "async function requestCodexImageGenerationForThread", "OpenAssist image worker");
assertIncludes(bridge, "codexImageWorkerMentionSkillID", "backend image worker mention id");
assertIncludes(bridge, "hasCodexImageWorkerSelection", "backend image worker mention detection");
assertIncludes(bridge, "promptWithOpenAssistImageWorkerProtocol(runtimePrompt, codexImageWorkerSelected)", "typed providers force image worker mention");
assertIncludes(bridge, "if (!imageToolRun.hadToolCalls && codexImageWorkerSelected)", "typed provider ignored-tag guard");
assertIncludes(bridge, "Codex Image Worker is selected for this Live session", "Live selected image worker guidance");
assertIncludes(bridge, "saveCodexGeneratedImageArtifact", "saved image artifact helper");
assertIncludes(bridge, "codex-image-worker-records.jsonl", "compact image worker records");
assertIncludes(bridge, "<openassist_tool_call>", "typed provider image protocol");
assertIncludes(bridge, "promptWithOpenAssistImageWorkerProtocol", "typed provider prompt injection");
assertIncludes(bridge, "runOpenAssistImageToolCallsFromProvider", "typed provider tool interception");
assertIncludes(bridge, "providerImageToolContinuationPrompt", "typed provider continuation");
assertIncludes(bridge, 'name: "oa_request_codex_image_generation"', "Ollama image worker tool");
assertIncludes(bridge, 'case "request_codex_image_generation"', "Ollama canonical image tool alias");
assertIncludes(bridge, "requestCodexImageGenerationForThread(context.threadID", "Ollama image worker execution");
assertIncludes(bridge, "turnID?: string;", "image worker parent turn option");
assertIncludes(bridge, "const activityTurnID = options.turnID || options.callID || activityID;", "image worker activity turn binding");
assertIncludes(bridge, "turnID: providerTurnID", "typed provider image activity turn binding");
assertIncludes(bridge, "realtimeCodexImageGeneration", "Realtime bridge image worker hook");
assertIncludes(bridge, 'source: "realtimeVoice"', "Realtime image worker source");
assertMatches(
  bridge,
  /configureCodexRealtimeProxy\([\s\S]*realtimeParallelDelegation,\s*realtimeCodexImageGeneration\)/,
  "Realtime proxy receives image worker hook"
);

assertIncludes(realtime, "codexImageGeneration?:", "Realtime image worker config");
assertIncludes(realtime, 'name: "request_codex_image_generation"', "Realtime image tool spec");
assertIncludes(realtime, "realtimeCodexImageGenerationToolSpec", "Realtime tool registration");
assertIncludes(realtime, "private async codexImageGenerationToolOutput", "Realtime image tool handler");
assertIncludes(realtime, "realtimePromptWantsImageGeneration", "Realtime image background-agent guard");
assertIncludes(realtime, "Do not call background_agent for image generation", "Realtime image instructions");
assertMatches(
  realtime,
  /name === "request_codex_image_generation"[\s\S]{0,220}codexImageGenerationToolOutput/,
  "OpenAI realtime image tool handler"
);
assertMatches(
  realtime,
  /name === "request_codex_image_generation"[\s\S]{0,260}responses\.push/,
  "Gemini Live image tool handler"
);

assertIncludes(app, "codexImageWorkerMentionID", "composer image worker mention id");
assertIncludes(app, '"codex-image"', "composer codex-image mention");
assertIncludes(app, '"imagegen"', "composer imagegen mention alias");
assertIncludes(app, '"codex-image-worker"', "composer codex-image-worker mention alias");
assertIncludes(app, "addBuiltInComposerMentions(catalog)", "composer built-in mention catalog");

if (packageJSON.scripts?.["verify:codex-image-worker"] !== "node scripts/verify-codex-image-worker.mjs") {
  throw new Error("package.json missing verify:codex-image-worker script.");
}

console.log("Codex image worker wiring check passed.");
