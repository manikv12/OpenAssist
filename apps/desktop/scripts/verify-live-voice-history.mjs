import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  atomicWriteJSON,
  conversationHistorySegmentFiles,
  extractRealtimeWorkHistory,
  mergeConversationHistorySnapshots,
  readConversationHistorySegments,
  readRecentRealtimeWorkHistory,
  rotateConversationHistory
} from "../dist-electron/conversationHistoryStore.js";

function makeSnapshot(turnCount, options = {}) {
  const timeline = [];
  const transcript = [];
  const turns = [];
  for (let index = 1; index <= turnCount; index += 1) {
    const userID = `user-${index}`;
    const assistantID = `assistant-${index}`;
    const turnID = `turn-${index}`;
    timeline.push({ id: userID, kind: "userMessage", text: `Question ${index}`, isStreaming: false });
    if (options.streamingIndex === index) {
      timeline.push({ id: `activity-${index}`, kind: "activity", isStreaming: true, activity: { status: "running" } });
    }
    timeline.push({ id: assistantID, kind: "assistantFinal", turnID, text: `Answer ${index}`, isStreaming: false });
    transcript.push(
      { id: `transcript-user-${index}`, role: "user", text: `Question ${index}` },
      { id: `transcript-assistant-${index}`, role: "assistant", text: `Answer ${index}` }
    );
    turns.push({ providerTurnID: turnID, openAssistTurnID: turnID, messageIDs: [assistantID] });
  }
  return { version: 2, threadID: "voice-log", timeline, transcript, turns, updatedAt: Date.now() };
}

const root = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-live-history-"));
try {
  const original = makeSnapshot(6);
  const active = rotateConversationHistory(root, original, { maxTurns: 5, maxBytes: Number.MAX_SAFE_INTEGER, retainTurns: 2 });
  assert.equal(active.turns.length, 2);
  assert.equal(active.transcript[0].text, "Question 5");
  assert.equal(conversationHistorySegmentFiles(root).length, 1);
  const segments = readConversationHistorySegments(root);
  assert.equal(segments[0].turns.length, 4);
  const merged = mergeConversationHistorySnapshots([...segments, active]);
  assert.equal(merged.turns.length, 6);
  assert.deepEqual(merged.transcript.map((entry) => entry.text), original.transcript.map((entry) => entry.text));

  // Re-reading a duplicated segment must not duplicate finalized text.
  const deduped = mergeConversationHistorySnapshots([segments[0], segments[0], active]);
  assert.equal(deduped.turns.length, 6);
  assert.equal(deduped.transcript.length, 12);

  const workHistory = extractRealtimeWorkHistory({
    turns: [
      {
        providerTurnID: "agent-task-1",
        realtimeWork: {
          workerProvider: "Codex",
          state: "completed",
          prompt: "Check the build",
          resultPreview: "The build passes.",
          startedAt: 100,
          finishedAt: 250
        }
      },
      { providerTurnID: "direct-voice-turn" }
    ]
  });
  assert.deepEqual(workHistory, [{
    taskID: "agent-task-1",
    workerProvider: "Codex",
    state: "completed",
    prompt: "Check the build",
    resultPreview: "The build passes.",
    startedAt: 100,
    finishedAt: 250
  }]);

  const recentRoot = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-live-work-recent-"));
  atomicWriteJSON(path.join(recentRoot, "conversation-segment-0001.json"), {
    turns: [{ providerTurnID: "older-task", realtimeWork: { workerProvider: "Claude", state: "completed", prompt: "Older run", resultPreview: "Older result", startedAt: 10, finishedAt: 20 } }]
  });
  const recentHistory = readRecentRealtimeWorkHistory(recentRoot, {
    turns: [{ providerTurnID: "newer-task", realtimeWork: { workerProvider: "Codex", state: "completed", prompt: "Newer run", resultPreview: "Newer result", startedAt: 30, finishedAt: 40 } }]
  }, 2);
  assert.deepEqual(recentHistory.map((item) => item.taskID), ["newer-task", "older-task"]);
  fs.rmSync(recentRoot, { recursive: true, force: true });

  // Unfinished work in the archived prefix defers rotation.
  const streamingRoot = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-live-history-streaming-"));
  const streaming = makeSnapshot(6, { streamingIndex: 2 });
  assert.equal(rotateConversationHistory(streamingRoot, streaming, { maxTurns: 5, retainTurns: 2 }), streaming);
  assert.equal(conversationHistorySegmentFiles(streamingRoot).length, 0);
  fs.rmSync(streamingRoot, { recursive: true, force: true });

  // A corrupt old segment is ignored and cannot stop the current Voice Log.
  fs.writeFileSync(path.join(root, "conversation-segment-9999.json"), "not json", "utf8");
  assert.equal(readConversationHistorySegments(root).length, 1);

  const atomicPath = path.join(root, "atomic.json");
  atomicWriteJSON(atomicPath, { ok: true, text: "finalized text only" });
  assert.deepEqual(JSON.parse(fs.readFileSync(atomicPath, "utf8")), { ok: true, text: "finalized text only" });
  assert.equal(fs.readdirSync(root).some((file) => file.includes(".tmp-")), false);
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}

console.log("Live Voice history checks passed.");
