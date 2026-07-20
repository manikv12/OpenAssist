import assert from "node:assert/strict";
import { LiveVoiceCompletedTurnTracker } from "../dist-electron/liveVoiceContinuity.js";
import {
  OpenAIInterruptedResponseTracker,
  playedOpenAIAudioMs,
  planOpenAIInterruption,
  stopRealtimeAudioSources
} from "../dist-electron/realtimeInterruption.js";
import { RealtimeTaskCoordinator } from "../dist-electron/realtimeTaskCoordinator.js";

const activeResponse = {
  responseID: "resp-old",
  responseActive: true,
  audioItemID: "item-old",
  audioMs: 123.6
};
assert.equal(playedOpenAIAudioMs(800, 1_000, 1_124), 124);
assert.equal(playedOpenAIAudioMs(800, 1_000, 2_500), 800, "Played audio cannot exceed received audio.");
assert.equal(playedOpenAIAudioMs(800, 0, 2_500), 0);
const speechPlan = planOpenAIInterruption(activeResponse, "speech");
assert.equal(speechPlan.shouldCancelResponse, false, "VAD barge-in must rely on OpenAI automatic cancellation.");
assert.equal(speechPlan.shouldTruncateAudio, true);
assert.equal(speechPlan.audioEndMs, 124, "Truncation must use the audio duration actually played.");
assert.equal(speechPlan.shouldClearPendingResponse, true);

const manualPlan = planOpenAIInterruption(activeResponse, "manual");
assert.equal(manualPlan.shouldCancelResponse, true, "A manual Stop must send one response.cancel.");
assert.equal(planOpenAIInterruption({ ...activeResponse, responseActive: false }, "manual").shouldCancelResponse, false);
assert.equal(planOpenAIInterruption(activeResponse, "shutdown").shouldCancelResponse, false);
assert.equal(planOpenAIInterruption(activeResponse, "shutdown").shouldClearPendingResponse, false);

const interrupted = new OpenAIInterruptedResponseTracker(2);
interrupted.mark("resp-old", "item-old");
assert.equal(interrupted.matches("resp-old", ""), true);
assert.equal(interrupted.matches("", "item-old"), true);
assert.equal(interrupted.matches("resp-next", "item-next"), false, "The next user turn must remain clean.");
interrupted.mark("resp-second", "item-second");
interrupted.mark("resp-third", "item-third");
assert.equal(interrupted.matches("resp-old", ""), false, "Stale response tracking must stay bounded.");
assert.equal(interrupted.matches("", "item-old"), false);
interrupted.finish("resp-second", "item-second");
assert.equal(interrupted.matches("resp-second", "item-second"), false);

const stopped = [];
const sources = new Set([
  {
    stop: () => stopped.push("first-stop"),
    disconnect: () => stopped.push("first-disconnect")
  },
  {
    stop: () => {
      stopped.push("second-stop");
      throw new Error("already stopped");
    },
    disconnect: () => stopped.push("second-disconnect")
  }
]);
assert.equal(stopRealtimeAudioSources(sources), 1);
assert.equal(sources.size, 0, "Every scheduled source must be removed immediately.");
assert.deepEqual(stopped, ["first-stop", "first-disconnect", "second-stop", "second-disconnect"]);

const continuity = new LiveVoiceCompletedTurnTracker();
continuity.beginUser("turn-interrupted", "Tell me the result.");
continuity.setAssistant("This sentence was cut off.");
continuity.markInterrupted();
assert.equal(continuity.finish(), null, "Interrupted assistant output must not be persisted as a completed answer.");
continuity.beginUser("turn-next", "Please continue.");
continuity.setAssistant("Here is the fresh answer.");
assert.deepEqual(continuity.finish(), {
  id: "turn-next",
  userText: "Please continue.",
  assistantText: "Here is the fresh answer.",
  ownedExternally: false
});

const tasks = new RealtimeTaskCoordinator();
assert.equal(tasks.start({
  taskID: "codex-background",
  scopeKey: "today-live-voice",
  prompt: "Check the repository build",
  workerProvider: "Codex"
}).ok, true);
planOpenAIInterruption(activeResponse, "speech");
assert.equal(tasks.get("codex-background")?.state, "running", "Voice interruption must not cancel delegated work.");

console.log("Realtime interruption checks passed.");
