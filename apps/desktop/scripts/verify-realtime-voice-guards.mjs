import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { voiceControlForText } from "../dist-electron/liveVoice/coordinator.js";

assert.equal(voiceControlForText("Stop listening").action, "stop_listening");
assert.equal(voiceControlForText("Mute yourself").action, "quiet");
assert.equal(voiceControlForText("Don't listen to me").action, "quiet");
assert.equal(voiceControlForText("Resume listening").action, "resume");
assert.equal(voiceControlForText("I'm back").action, "resume");
assert.equal(voiceControlForText("Cancel the running task").handled, false);

const proxy = await readFile(new URL("../electron/realtimeProxy.ts", import.meta.url), "utf8");
const reducer = await readFile(new URL("../electron/liveVoice/state.ts", import.meta.url), "utf8");
const renderer = await readFile(new URL("../src/App.tsx", import.meta.url), "utf8");
assert.match(proxy, /handleVoiceControlCommand/);
assert.match(proxy, /create_response:\s*false/);
assert.match(proxy, /requestOpenAIResponseCreate\("finalized transcript"/);
assert.match(proxy, /stopVoiceManually[\s\S]{0,400}closeVoice/);
assert.match(proxy, /finishGeminiAudio\("connection-closed"\)/);
// The OpenAI-compatible upstream is shared by openaiRealtime and
// codexSubscription; the restore event carries the connecting provider.
assert.match(proxy, /providerConnectionRestored\(input\.provider\)/);
assert.match(proxy, /providerConnectionRestored\("geminiLive"\)/);
assert.match(reducer, /backgroundTasks/);
assert.match(reducer, /terminalTurnPhases/);
assert.doesNotMatch(proxy, /stopVoiceManually[\s\S]{0,500}cancelActive/);
assert.match(renderer, /isIntentionalLiveVoiceCloseReason[\s\S]{0,500}live voice stopped/);
assert.match(renderer, /liveVoiceStoppedProviderThreadIDsRef/);
assert.match(renderer, /providerThreadID !== currentProviderThreadID/);
assert.doesNotMatch(renderer, /liveVoiceExpectedStopRef\.current = false;\s*\}, 250/);

console.log("Realtime voice control and state guard checks passed.");
