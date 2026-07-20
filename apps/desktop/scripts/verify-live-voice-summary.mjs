import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const bridge = await readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");

// Summary generator uses the Codex subscription endpoint pattern (same as the
// daily digest) and reads the full day transcript including rotated history.
const summaryFn = bridge.match(/async function generateLiveVoiceSessionSummary[\s\S]*?\n}\n/)?.[0] ?? "";
assert.ok(summaryFn, "generateLiveVoiceSessionSummary must exist");
assert.match(summaryFn, /resolveCodexTranscriptionAuthContext/);
assert.match(summaryFn, /chatgpt\.com\/backend-api\/codex\/responses/);
assert.match(bridge, /readConversationSnapshotWithHistory\(threadID\)/, "summary input must include rotated history segments");

// Cost guard: sessions with too few substantive user turns skip the model call.
assert.match(summaryFn, /userTurns < liveVoiceSummaryMinUserTurns/);

// The summary is written into the thread's "Session Summary" note, replace-style.
assert.match(summaryFn, /resolveCanonicalThreadReferenceNote\(threadID, "Session Summary"\)/);
assert.match(summaryFn, /replaceMarkdownSection\(note\.markdown, "Summary"/);

// Triggers: explicit stop, transport close, and day-log rotation (finalize).
assert.match(bridge, /activeRealtimeSession = null;\s*\n\s*queueLiveVoiceSessionSummary\(active\.openAssistThreadID\);/, "stopActiveRealtimeSession must queue a summary");
assert.match(bridge, /cleanupRealtimeStart\(\);\s*\n\s*queueLiveVoiceSessionSummary\(openAssistThreadID\);/, "client_closed must queue a summary");
assert.match(bridge, /function finalizeLiveVoiceDayLog[\s\S]{0,400}?generateLiveVoiceSessionSummary\(threadID, \{ finalize: true \}\)/, "rotation must finalize the closing day's summary");
assert.match(bridge, /finalizeLiveVoiceDayLog\(rotatedID\)/, "rotation branch must call the finalize hook");

// Debounce: queued summaries are cancelled when a new session starts on the thread.
assert.match(bridge, /cancelQueuedLiveVoiceSummary\(openAssistThreadID\);/, "new sessions must cancel a pending summary");
assert.match(bridge, /\}, liveVoiceSummaryDebounceMs\);/, "summaries must be debounced");

// Fire-and-forget: every generate call is voided with a catch, never awaited by
// stop/rotation paths.
assert.doesNotMatch(bridge, /await generateLiveVoiceSessionSummary/, "summary generation must never block stop or rotation");

console.log("Live Voice session summary checks passed.");
