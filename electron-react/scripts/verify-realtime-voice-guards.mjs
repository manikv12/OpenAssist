// Static wiring check for the realtime voice reliability guards added after the
// July 2026 bug review: knowledge dedupe scoping, Gemini quiet mode, narration
// queue resilience, stale-handoff eviction, double-delegation race guard, and
// Spark recall thread cleanup. Keeps a refactor from silently reintroducing the
// "buggy voice agent" failure modes.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");

function read(rel) {
  return fs.readFileSync(path.join(root, rel), "utf8");
}

const proxy = read("electron/realtimeProxy.ts");
const bridge = read("electron/openassistBridge.ts");
const knowledgeBin = read("bin/openassist-knowledge.mjs");
const main = read("electron/main.ts");
const renderer = read("src/App.tsx");
const shortcutHelper = read("electron/helpers/shortcut-monitor-helper.swift");

const checks = [
  // K1: one utterance may legitimately trigger several different knowledge tools.
  ["proxy: dedupe utterance key scoped by tool name", proxy, /keys\.add\(`\$\{name\} utterance \$\{utterance\}`\)/],
  // K2: a rejected in-flight recall promise must not escape the tool-call handler.
  ["proxy: cached recall promise cannot reject", proxy, /existing\.promise\.catch\(\(\) => undefined\)/],
  // K5: failed recalls must not be replayed from the 5-minute cache.
  ["proxy: failed recall results evicted from cache", proxy, /isFailedPersonalRecallResult\(result\)/],
  // G1: Gemini has no server-side quiet switch; output audio is dropped locally.
  ["proxy: Gemini quiet mode drops output audio", proxy, /sendGeminiAudioDelta\(audio: Buffer\) \{\s*\n\s*if \(!audio\.length\) return;[\s\S]{0,400}if \(this\.quiet\) return;/],
  // G2: stop/interrupt must not immediately narrate the next queued result.
  ["proxy: queue drains only on natural turn completion", proxy, /if \(reason === "turn-complete"\) \{\s*\n\s*this\.onParallelNarrationEnded\(\);/],
  // G3: a dropped Gemini socket must not leave the voice state stuck "speaking".
  ["proxy: Gemini close finishes the audio turn", proxy, /this\.upstreamReady = undefined;[\s\S]{0,250}finishGeminiAudio\("connection-closed"\)/],
  // G4: generationComplete + turnComplete fire once, not twice.
  ["proxy: finishGeminiTurn runs once per turn", proxy, /&& !this\.geminiTurnFinished\) \{\s*\n\s*this\.geminiTurnFinished = true;/],
  // G5/S5: a failed narration send re-queues the result instead of dropping it.
  ["proxy: failed narration send re-queues the result", proxy, /this\.parallelResultQueue\.unshift\(next\);/],
  ["proxy: drain waits for an open OpenAI socket", proxy, /this\.upstream\?\.readyState !== WebSocket\.OPEN\) return;\s*\n\s*const next = this\.parallelResultQueue\.shift\(\)/],
  // S1: results finishing during quiet mode are queued, not dropped.
  ["proxy: completed handoff routes through narration queue", proxy, /this\.enqueueParallelResult\(text, handoff\.agentLabel\);/],
  // S2: a dead delegated run cannot brick delegation for the whole session.
  ["proxy: stale handoff eviction defined", proxy, /private evictStaleHandoffs\(\)/],
  ["proxy: auto handoff evicts stale entries", proxy, /scheduleAutoHandoff\(transcript: string\) \{\s*\n\s*if \(this\.quiet\) return;\s*\n\s*this\.evictStaleHandoffs\(\);/],
  // S3: router await cannot double-delegate the same utterance.
  ["proxy: delegation in-flight race guard", proxy, /private delegationStartInFlight = false;/],
  ["proxy: auto handoff re-checks after router await", proxy, /routeRealtimeDelegation\(transcript, "auto_transcript"\);\s*\n\s*if \(!decision\.allow\) return;\s*\n[\s\S]{0,200}if \(this\.pendingHandoffs\.size > 0\) return;/],
  // S4: status answers know about parallel runs.
  ["proxy: voice state includes parallel runs", proxy, /this\.pendingHandoffs\.size > 0 \|\| this\.activeParallelDelegations > 0\) return "delegating";/],
  ["proxy: status text reports parallel tasks", proxy, /parallel tasks are still running/],
  // S6: repeating a completed request works again.
  ["proxy: auto-handoff dedupe cleared on completion", proxy, /this\.pendingHandoffs\.delete\(callID\);\s*\n[\s\S]{0,150}this\.lastAutoHandoffNormalizedPrompt = "";/],

  // K3: every Spark recall cleans up its temporary Codex thread.
  ["bridge: spark recall deletes its temp thread", bridge, /await deleteCodexProviderThread\(threadID\);/],
  ["bridge: spark recall interrupts a timed-out turn", bridge, /turn\/interrupt", \{ threadId: threadID, turnId: turnID \}/],
  // K4: turn-completion listeners cannot leak on timeout.
  ["bridge: turn wait has a self-cleaning timeout", bridge, /waitForCodexThreadTurnComplete\(providerThreadID: string, getTurnID: \(\) => string, timeoutMs\?: number\)/],
  ["bridge: spark recall passes the turn deadline", bridge, /waitForCodexThreadTurnComplete\(providerThreadID, \(\) => providerTurnID, 120_000\)/],

  // K6: dropped flood requests still get a JSON-RPC error.
  ["knowledge bin: flooded requests get an error reply", knowledgeBin, /Request dropped: too many requests\./],

  // V1: the Live Voice shortcut is a one-shot realtime toggle, not old hold-to-talk dictation.
  ["shortcut helper: assistant live voice is not hold style", shortcutHelper, /private func downPhase\(for target: String\)[\s\S]*case "holdToTalk":\s*\n\s*return "down"[\s\S]*default:\s*\n\s*return "trigger"/],
  ["shortcut helper: assistant live voice emits no up phase", shortcutHelper, /private func emitsUpPhase\(_ target: String\) -> Bool \{\s*\n\s*target == "holdToTalk"\s*\n\s*\}/],
  ["main: live voice shortcut creates hidden renderer", main, /initiallyHidden: isVoiceTranscriptionShortcut \|\| target === "assistantLiveVoice"/],
  ["renderer: live voice shortcut uses the voice-log thread", renderer, /if \(target === "assistantLiveVoice"\) \{[\s\S]{0,220}toggleTodayLiveVoice\(\);[\s\S]{0,80}return;/],
  ["renderer: hold-style shortcut is dictation only", renderer, /const isHoldStyleShortcut = target === "holdToTalk";/],
  ["renderer: floating HUD handles live voice states", renderer, /liveVoiceFloatingHUDStatus\(status: LiveVoiceStatus\)[\s\S]*live-connecting[\s\S]*live-listening[\s\S]*live-speaking[\s\S]*live-delegating/],
  ["renderer: live voice skips archived selected threads", renderer, /const isArchivedThreadID =[\s\S]{0,500}const currentLiveVoiceThreadID =[\s\S]{0,500}isArchivedThreadID\(threadID\)/],
  ["renderer: live voice start can be cancelled while connecting", renderer, /const liveVoiceStartTokenRef = useRef\(0\);[\s\S]*const startStillCurrent = \(\) => liveVoiceStartTokenRef\.current === startToken;[\s\S]*if \(!startStillCurrent\(\)\) \{[\s\S]*await api\.stop\(\)\.catch\(\(\) => undefined\);/],
  ["renderer: live voice shortcut stops every active state", renderer, /if \(liveVoiceStatusRef\.current !== "idle" && liveVoiceStatusRef\.current !== "error"\) \{[\s\S]{0,120}stopLiveVoice\("idle", undefined, \{ stopDelegation: true \}\)/],
  ["renderer: floating HUD receives captions and mute state", renderer, /providerLabel,[\s\S]{0,160}userText: liveVoiceCaptionBus\.user,[\s\S]{0,220}assistantText: spokenAssistant[\s\S]{0,180}muted: liveVoiceMuted/],
  ["main: live voice HUD is a compact panel with controls", main, /hud-live-control is-mute[\s\S]*hud-live-control is-stop[\s\S]*: \{ width: 318, height: 122 \};/],
  ["main: dictation is blocked while unmuted live voice is active", main, /liveVoiceHUDSessionActive\(\) && !liveVoiceHUDMuted\(\)[\s\S]*Stop Live Voice or mute its microphone before starting dictation/],
  ["main: muted live voice stacks dictation above the orb", main, /dictationCapture: !voiceCapture\.processing/],
  ["main: muted live voice HUD has dictation strip", main, /hud-live-dictation/],
  ["main: live voice HUD controls send renderer actions", main, /openassist:live-voice-hud-action[\s\S]*safeSendWindow\(window, "openassist:live-voice-hud-action", action\)/],
  ["main: live voice HUD is interactive", main, /isInteractiveVoiceHUDStatus\(status: VoiceHUDPayload\["status"\]\) \{[\s\S]*isLiveVoiceHUDStatus\(status\)/],
  ["renderer: live voice HUD shows agent work while runs are active", renderer, /const liveVoiceAgentWorkActive = liveVoiceStatus !== "idle"[\s\S]{0,220}activeRunCount > 0[\s\S]{0,220}liveVoiceAgentWorkActive \? "live-delegating"/],
  ["bridge: realtime voice creates a new thread for archived requests", bridge, /session\?\.isArchived === true[\s\S]{0,250}createOpenAssistThread\(undefined, true\)\.session/],
  ["bridge: archived Codex provider sessions start fresh", bridge, /function isArchivedCodexSessionError\(error: unknown\)[\s\S]*const archivedProviderSession = isArchivedCodexSessionError\(error\);[\s\S]{0,300}if \(!missingProviderSession && !archivedProviderSession\) throw error;[\s\S]{0,300}starting fresh provider session after/]
];

let failures = 0;
for (const [label, source, re] of checks) {
  const pass = re.test(source);
  if (!pass) failures += 1;
  console.log(`${pass ? "PASS" : "FAIL"} ${label}`);
}

if (failures > 0) {
  console.error(`\nRealtime voice guard check FAILED (${failures} missing).`);
  process.exit(1);
}
console.log("\nRealtime voice guard check passed.");
