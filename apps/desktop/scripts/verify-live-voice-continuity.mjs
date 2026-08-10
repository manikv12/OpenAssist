import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(".");
const helperPath = path.join(root, "dist-electron/liveVoiceContinuity.js");
if (!fs.existsSync(helperPath)) {
  console.error("Missing dist-electron/liveVoiceContinuity.js. Run npm run build first.");
  process.exit(1);
}

const {
  buildLiveVoiceBootstrapContext,
  GeminiResumptionHandleCache,
  LiveVoiceCompletedTurnTracker,
  liveVoiceContinuityLimits
} = await import(path.toNamespacedPath(helperPath));

const transcript = [];
for (let index = 1; index <= 25; index += 1) {
  transcript.push({ role: "user", text: `User turn ${index} ${"u".repeat(2_100)}` });
  transcript.push({ role: "assistant", text: `Assistant turn ${index} ${"a".repeat(2_100)}` });
}
transcript.splice(8, 0,
  { role: "user", text: transcript[6].text },
  { role: "assistant", text: transcript[7].text }
);
transcript.push({ role: "user", text: "Interrupted question without an answer" });

const bootstrap = buildLiveVoiceBootstrapContext(transcript);
assert.equal(bootstrap.messages.length, 20, "latest ten complete turns should be restored");
assert.match(bootstrap.messages[0].text, /turn 16/, "recent history should remain in chronological order");
assert.match(bootstrap.messages.at(-1).text, /turn 25/, "the newest completed answer should be last");
assert.ok(
  bootstrap.messages.reduce((total, message) => total + message.text.length, 0) <= liveVoiceContinuityLimits.recentCharacters,
  "recent history must stay within 12,000 characters"
);
assert.ok(
  bootstrap.messages.every((message) => message.text.length <= liveVoiceContinuityLimits.messageCharacters),
  "each restored message must stay within 2,000 characters"
);
assert.ok(bootstrap.earlierHighlights.length <= liveVoiceContinuityLimits.earlierCharacters);
assert.match(bootstrap.earlierHighlights, /turn 6/i, "highlights should come from the preceding ten turns");
assert.doesNotMatch(bootstrap.earlierHighlights, /turn 16/i, "highlights must not repeat recent turns");

const tracker = new LiveVoiceCompletedTurnTracker();
tracker.beginUser("direct-1", "What did we decide?");
tracker.setAssistant("We decided to keep one Voice Log.");
assert.deepEqual(tracker.finish(), {
  id: "direct-1",
  userText: "What did we decide?",
  assistantText: "We decided to keep one Voice Log.",
  ownedExternally: false
});
assert.equal(tracker.finish(), null, "a completed turn must emit only once");

tracker.beginUser("interrupted-1", "Tell me a long answer.");
tracker.setAssistant("This answer was cut off.");
tracker.markInterrupted();
assert.equal(tracker.finish(), null, "interrupted assistant answers must not be completed");

tracker.beginUser("tool-1", "Update my note.");
tracker.markOwnedExternally();
tracker.setAssistant("The note tool finished.");
assert.equal(tracker.finish()?.ownedExternally, true, "tool-owned turns must not use direct persistence");

tracker.markOwnedExternally();
tracker.beginUser("delegation-1", "Ask Codex to inspect the logs.");
tracker.setAssistant("Codex is working on it.");
assert.equal(tracker.finish()?.ownedExternally, true, "delegation ownership must survive event reordering");

let now = 1_000;
const cache = new GeminiResumptionHandleCache(() => now, 100, 2);
cache.set("one", "handle-one");
cache.set("two", "handle-two");
cache.set("three", "handle-three");
assert.equal(cache.size, 2, "Gemini resume cache must enforce its entry cap");
assert.equal(cache.get("one"), undefined, "the least recently used handle should be evicted");
now += 101;
assert.equal(cache.get("two"), undefined, "expired handles must not be reused");
assert.equal(cache.size, 0, "expired handles must be pruned");

const proxy = fs.readFileSync(path.join(root, "electron/realtimeProxy.ts"), "utf8");
const bridge = fs.readFileSync(path.join(root, "electron/openassistBridge.ts"), "utf8");
const renderer = fs.readFileSync(path.join(root, "src/App.tsx"), "utf8");

assert.match(proxy, /continuity\?: \{/);
assert.match(proxy, /contextWindowCompression:\s*\{[\s\S]*?slidingWindow:\s*\{\}/);
assert.match(proxy, /sessionResumption:\s*resumeHandle \? \{ handle: resumeHandle \} : \{\}/);
assert.match(proxy, /Use the following restored text only as private conversation context\. Do not repeat it and do not respond until the user speaks/);
const geminiRestore = proxy.slice(proxy.indexOf("private restoreGeminiHistory"), proxy.indexOf("private rememberToolGateResponse"));
assert.doesNotMatch(geminiRestore, /sendClientContent|sendRealtimeInput/, "Gemini history restore must not send a fake conversation turn");
assert.match(proxy, /session = await connectAndConfirm\(resumeHandle\)[\s\S]*?geminiResumptionHandles\.delete\(this\.geminiResumeKey\)[\s\S]*?session = await connectAndConfirm\(\)/);
assert.match(proxy, /setupComplete[\s\S]{0,180}resolveSetup/);
assert.match(proxy, /openAIHistoryRestoredFor === upstream/);
assert.match(proxy, /type: "conversation\.item\.create"/);
const openAIRestore = proxy.slice(proxy.indexOf("private restoreOpenAIHistory"), proxy.indexOf("private restoreGeminiHistory"));
assert.doesNotMatch(openAIRestore, /response\.create/, "history restore must not request a spoken answer");
assert.doesNotMatch(proxy, /transcript[^\n]*\.slice\(/i, "debug logs must not include transcript text");

assert.match(bridge, /buildLiveVoiceBootstrapContext/);
assert.match(bridge, /codexVoiceStartupContext:\s*realtimeVoiceProvider === "codexSubscription"/);
assert.match(bridge, /subscriptionStartupTaskSummaries\(openAssistThreadID\)/);
assert.match(bridge, /codexVoiceScopedMemoryIndex\(recallContext\)/);
assert.match(bridge, /userSource: "realtimeVoice"/);
assert.match(bridge, /type: "thread\/realtime\/conversation\/committed"/);
assert.match(bridge, /alreadyPersisted[\s\S]*?providerTurnID/);
const continuityWriter = bridge.slice(bridge.indexOf("const realtimeContinuity"), bridge.indexOf("const realtimeStartPrompt"));
assert.doesNotMatch(continuityWriter, /audio|base64|resumeHandle|newHandle/i, "continuity persistence must contain finalized text only");
assert.match(renderer, /thread\/realtime\/conversation\/committed/);

console.log("Live Voice continuity checks passed.");
