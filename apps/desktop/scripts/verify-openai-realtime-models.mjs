import assert from "node:assert/strict";
import {
  buildOpenAIRealtimeURL,
  defaultOpenAIRealtimeModel,
  liveVoiceSettingsAreLocked,
  openAIRealtimeModels,
  readableOpenAIRealtimeConnectionError,
  requireOpenAIRealtimeConversationModel,
  validateOpenAIRealtimeConversationModel
} from "../dist-electron/openAIRealtimeModels.js";
import { __realtimeProtocolTestHooks } from "../dist-electron/realtimeProxy.js";

const recommended = openAIRealtimeModels
  .filter((model) => model.group === "recommended")
  .map((model) => model.id);
const older = openAIRealtimeModels
  .filter((model) => model.group === "older")
  .map((model) => model.id);

assert.equal(defaultOpenAIRealtimeModel, "gpt-realtime-2.1");
assert.deepEqual(recommended, ["gpt-realtime-2.1", "gpt-realtime-2.1-mini"]);
assert.deepEqual(older, [
  "gpt-realtime-2",
  "gpt-realtime-1.5",
  "gpt-realtime",
  "gpt-realtime-mini"
]);

for (const model of [...recommended, ...older]) {
  assert.equal(requireOpenAIRealtimeConversationModel(model), model);
  const url = new URL(buildOpenAIRealtimeURL(model));
  assert.equal(url.protocol, "wss:");
  assert.equal(url.pathname, "/v1/realtime");
  assert.equal(url.searchParams.get("model"), model);

  const session = __realtimeProtocolTestHooks.realtimeSessionConfig({
    model,
    voice: "marin"
  }, "", false);
  assert.equal(session.model, model, `The URL and session.update must use ${model}.`);
  assert.equal(session.audio.input.turn_detection.type, "semantic_vad");
  assert.equal(session.audio.input.turn_detection.interrupt_response, true);
  assert.equal(session.audio.input.noise_reduction.type, "near_field");
}

const whisper = validateOpenAIRealtimeConversationModel("gpt-realtime-whisper");
assert.equal(whisper.ok, false);
assert.match(whisper.message, /transcription-only/i);
const translate = validateOpenAIRealtimeConversationModel("gpt-realtime-translate");
assert.equal(translate.ok, false);
assert.match(translate.message, /translation workflow/i);
const retired = validateOpenAIRealtimeConversationModel("gpt-4o-realtime-preview");
assert.equal(retired.ok, false);
assert.match(retired.message, /no longer supported/i);
assert.throws(() => requireOpenAIRealtimeConversationModel("made-up-realtime-model"), /not a supported/i);

assert.equal(liveVoiceSettingsAreLocked("idle"), false);
assert.equal(liveVoiceSettingsAreLocked("error"), false);
for (const status of ["connecting", "listening", "speaking", "transcribing", "delegating"]) {
  assert.equal(liveVoiceSettingsAreLocked(status), true, `${status} must lock model settings.`);
}

assert.match(
  readableOpenAIRealtimeConnectionError({ model: "gpt-realtime-2.1", statusCode: 403 }),
  /does not have access/i
);
assert.match(
  readableOpenAIRealtimeConnectionError({ model: "gpt-realtime-2.1", statusCode: 429 }),
  /rate limited/i
);
assert.match(
  readableOpenAIRealtimeConnectionError({ model: "gpt-realtime-2.1", statusCode: 503 }),
  /temporarily unavailable/i
);

console.log("OpenAI Realtime model registry checks passed.");
