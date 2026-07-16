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
const styles = read("src/styles.css");
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
  ["proxy: completed handoff routes through narration queue", proxy, /this\.enqueueParallelResult\(completed\.taskID, text, handoff\.agentLabel\);/],
  // S2: a dead delegated run cannot brick delegation for the whole session.
  ["proxy: stale handoff eviction defined", proxy, /private evictStaleHandoffs\(\)/],
  ["proxy: auto handoff evicts stale entries", proxy, /scheduleAutoHandoff\(transcript: string[\s\S]{0,180}if \(this\.quiet\) return;[\s\S]{0,120}this\.evictStaleHandoffs\(\);/],
  // S3: router await cannot double-delegate the same utterance.
  ["proxy: delegation in-flight race guard", proxy, /private delegationStartInFlight = false;/],
  ["proxy: tool call reserves the turn before transcript auto-routing", proxy, /response\.output_item\.added[\s\S]{0,520}reserveVoiceToolCall\(stringValue\(item\.call_id\)\)/],
  ["proxy: pre-transcript tool reservation attaches to the completed user turn", proxy, /beginContinuityUser\([\s\S]{0,700}pendingVoiceToolCallIDs[\s\S]{0,180}claimVoiceTurn\("routing"/],
  ["proxy: reserved tool owner can become the final route owner", proxy, /existing\.callID === callID && existing\.owner === "routing"[\s\S]{0,180}voiceTurnOwners\.set\(turnID, \{ owner, callID \}\)/],
  ["proxy: auto handoff re-checks shared task registry after router await", proxy, /routeRealtimeDelegation\(transcript, "auto_transcript"\);\s*\n\s*if \(!decision\.allow\) return;[\s\S]{0,900}taskCoordinator\.hasActivePrompt\(decision\.prompt, this\.taskScopeKey\(\)\)/],
  ["proxy: note and planner work cannot be forced into Always Delegate", proxy, /routeRealtimeDelegation\(rawPrompt[\s\S]{0,700}blockRealtimeKnowledgeTasks: true/],
  ["proxy: mistaken note delegation is rescued into direct Knowledge", proxy, /shouldUseDirectKnowledgeInsteadOfAgent\(userPrompt\)[\s\S]{0,700}tryDirectKnowledgeRequest\(callID, userPrompt, "function"\)/],
  // S4: voice state and delegated work are separate, and status sees every task.
  ["proxy: voice snapshot keeps voice phase separate from tasks", proxy, /const voicePhase:[\s\S]{0,700}voicePhase,[\s\S]{0,500}tasks: this\.taskCoordinator\.visible\(this\.taskScopeKey\(\)\)[\s\S]{0,900}progressEntries/],
  ["proxy: status text reports other running tasks", proxy, /otherHandoffs[\s\S]{0,900}Also running:/],
  // S6: repeating a completed request works again.
  ["proxy: auto-handoff dedupe cleared on completion", proxy, /completeHandoff\(callID: string[\s\S]{0,900}this\.lastAutoHandoffNormalizedPrompt = "";/],

  // K3: every Spark recall cleans up its temporary Codex thread.
  ["bridge: spark recall deletes its temp thread", bridge, /await deleteCodexProviderThread\(threadID\);/],
  ["bridge: spark recall interrupts a timed-out turn", bridge, /turn\/interrupt", \{ threadId: threadID, turnId: turnID \}/],
  // K4: turn-completion listeners cannot leak on timeout.
  ["bridge: turn wait has a self-cleaning timeout", bridge, /waitForCodexThreadTurnComplete\(providerThreadID: string, getTurnID: \(\) => string, timeoutMs\?: number\)/],
  ["bridge: spark recall uses a bounded turn deadline", bridge, /waitForCodexThreadTurnComplete\(providerThreadID, \(\) => providerTurnID, 30_000\)/],

  // K6: dropped flood requests still get a JSON-RPC error.
  ["knowledge bin: flooded requests get an error reply", knowledgeBin, /Request dropped: too many requests\./],

  // V1: the Live Voice shortcut is a one-shot realtime toggle, not old hold-to-talk dictation.
  ["shortcut helper: assistant live voice is not hold style", shortcutHelper, /private func downPhase\(for target: String\)[\s\S]*case "holdToTalk":\s*\n\s*return "down"[\s\S]*default:\s*\n\s*return "trigger"/],
  ["shortcut helper: assistant live voice emits no up phase", shortcutHelper, /private func emitsUpPhase\(_ target: String\) -> Bool \{\s*\n\s*target == "holdToTalk"\s*\n\s*\}/],
  ["main: live voice shortcut creates hidden renderer", main, /initiallyHidden: isVoiceTranscriptionShortcut \|\| target === "assistantLiveVoice"/],
  ["renderer: live voice shortcut uses the voice-log thread", renderer, /if \(target === "assistantLiveVoice"\) \{[\s\S]{0,220}toggleTodayLiveVoice\(\);[\s\S]{0,80}return;/],
  ["renderer: Voice Log is removed from the normal thread list", renderer, /const liveVoiceThreads = appState\.threads[\s\S]*?const sidebarThreads = appState\.threads\.filter\(\(thread\) => \{[\s\S]{0,240}isTodayLiveVoiceThread\(thread\)\) return false;/],
  ["renderer: Live Voice has a separate sidebar section", renderer, /className="sidebar-live-voice-section"[\s\S]{0,1400}liveVoiceThreads\.map\(renderSidebarThread\)/],
  ["renderer: Voice Log row opens current and recent Agent Work", renderer, /className=\{cx\("live-voice-work-button"[\s\S]{0,500}onOpenLiveVoiceWork\(thread\.id\)/],
  ["renderer: Agent Work shelf is stacked inside the Voice Log dock", renderer, /<RealtimeTranscript[\s\S]{0,500}\{realtimeWorkShelf\}[\s\S]{0,120}<div className="realtime-voice-composer-lock/],
  ["renderer: thread views do not use the floating Agent Work shelf", renderer, /!showNotchMiniTray[\s\S]{0,120}activeView !== "threads"[\s\S]{0,260}<div className=\{cx\("realtime-work-surface"/],
  ["renderer: Notes starts Live Voice without leaving the note", renderer, /const toggleSurfaceLiveVoice = \(\) => \{[\s\S]{0,320}activeViewRef\.current !== "notes"[\s\S]{0,260}keepCurrentSurface: true/],
  ["renderer: Today and Notes use the compact Live Voice overlay", renderer, /compactOverlay=\{activeView === "today" \|\| activeView === "notes"\}/],
  ["renderer: Today and Notes show only active delegated work", renderer, /activeView !== "threads"[\s\S]{0,180}activeRealtimeWorkTasks\.length > 0[\s\S]{0,220}is-compact-context/],
  ["renderer: Voice Log transcript uses normal layout instead of overlaying the dock", styles, /\.realtime-transcript\.is-composer \{[\s\S]{0,180}position: relative;[\s\S]{0,180}bottom: auto;/],
  ["styles: compact Live Voice stays in the lower-right corner", styles, /\.realtime-transcript\.is-compact-overlay \{[\s\S]{0,120}right: 18px;[\s\S]{0,120}width: min\(380px, calc\(100vw - 48px\)\);/],
  ["bridge: every live voice start resolves the shared Voice Log", bridge, /let session = ensureRemoteLiveVoiceThread\(options\.threadID\);\s*\n\s*const openAssistThreadID = session\.id;/],
  ["bridge: active Live Voice receives Knowledge permission changes", bridge, /finalizeSettingsUpdate\(keys:[\s\S]{0,900}codexRealtimeProxy\.configure\(\{[\s\S]{0,280}knowledge: realtimeKnowledgeProvider\(nextSettings\)[\s\S]{0,220}directKnowledgeRequest: realtimeDirectKnowledgeRequestProvider\(nextSettings\)/],
  ["bridge: general day tasks combine OpenAssist and Apple Reminders", bridge, /createCombinedTodayTaskVoiceResponse[\s\S]{0,2600}addEntry\(dailyItemVisibleTitle\(item\), "OpenAssist"\)[\s\S]{0,2600}listAppleReminders/],
  ["renderer: delegated work has a global progress surface", renderer, /function RealtimeWorkShelf[\s\S]{0,12000}function RealtimeWorkDrawer[\s\S]{0,12000}Stop this task[\s\S]{0,8000}Open Voice Log/],
  ["renderer: hold-style shortcut is dictation only", renderer, /const isHoldStyleShortcut = target === "holdToTalk";/],
  ["renderer: floating HUD handles live voice states", renderer, /liveVoiceFloatingHUDStatus\(status: LiveVoiceStatus\)[\s\S]*live-connecting[\s\S]*live-listening[\s\S]*live-speaking[\s\S]*live-delegating/],
  ["renderer: live voice skips archived selected threads", renderer, /const isArchivedThreadID =[\s\S]{0,500}const currentLiveVoiceThreadID =[\s\S]{0,500}isArchivedThreadID\(threadID\)/],
  ["renderer: live voice start can be cancelled while connecting", renderer, /const liveVoiceStartTokenRef = useRef\(0\);[\s\S]*const startStillCurrent = \(\) => liveVoiceStartTokenRef\.current === startToken;[\s\S]*if \(!startStillCurrent\(\)\) \{[\s\S]*await api\.stop\(\)\.catch\(\(\) => undefined\);/],
  ["renderer: stale audio failures cannot stop a newer voice session", renderer, /const sessionToken = liveVoiceStartTokenRef\.current;[\s\S]{0,2400}sessionToken !== liveVoiceStartTokenRef\.current \|\| !liveVoiceActiveRef\.current/],
  ["renderer: ended backend session cleans up locally without an error banner", renderer, /const sessionEnded = isRealtimeNotRunningError\(message\);[\s\S]{0,350}sessionEnded \? "idle" : "error"[\s\S]{0,180}cancelPendingStart: false/],
  ["renderer: live voice shortcut stops voice without cancelling tasks", renderer, /const toggleLiveVoice[\s\S]{0,240}liveVoiceStatusRef\.current !== "idle"[\s\S]{0,140}stopLiveVoice\("idle"\)/],
  ["renderer: floating HUD receives captions and mute state", renderer, /providerLabel,[\s\S]{0,160}userText: liveVoiceCaptionBus\.user,[\s\S]{0,220}assistantText: spokenAssistant[\s\S]{0,180}muted: liveVoiceMuted/],
  ["main: live voice HUD has stable transcript and controls", main, /hud-live-transcript[\s\S]*createLiveMessage\("assistant", "Assistant"\)[\s\S]*createLiveMessage\("user", "You"\)[\s\S]*hud-live-control is-mute[\s\S]*hud-live-control is-stop[\s\S]*return \{ width: 460, height \};/],
  ["renderer: playback completion waits for queued audio", renderer, /source\.onended = \(\) => \{[\s\S]{0,500}liveVoiceOutputSourcesRef\.current\.size === 0[\s\S]{0,300}setLiveVoiceListeningStatus\("Ready for your voice"\)/],
  ["renderer: done events do not end speaking while audio plays", renderer, /if \(lowerType\.includes\("done"\) \|\| lowerType\.includes\("completed"\)\) \{[\s\S]{0,180}if \(liveVoiceMeterBus\.outputPlaying\) return;[\s\S]{0,100}setLiveVoiceListeningStatus\(\)/],
  ["main: dictation is blocked while unmuted live voice is active", main, /liveVoiceHUDSessionActive\(\) && !liveVoiceHUDMuted\(\)[\s\S]*Stop Live Voice or mute its microphone before starting dictation/],
  ["main: muted live voice stacks dictation above the orb", main, /dictationCapture: !voiceCapture\.processing/],
  ["main: muted live voice HUD has dictation strip", main, /hud-live-dictation/],
  ["main: live voice HUD controls send renderer actions", main, /openassist:live-voice-hud-action[\s\S]*safeSendWindow\(window, "openassist:live-voice-hud-action", action\)/],
  ["main: live voice HUD forwards approval actions", main, /action !== "toggleMute" && action !== "stop" && action !== "approveRequest" && action !== "rejectRequest"/],
  ["main: live voice HUD is interactive", main, /isInteractiveVoiceHUDStatus\(status: VoiceHUDPayload\["status"\]\) \{[\s\S]*isLiveVoiceHUDStatus\(status\)/],
  ["main: live voice HUD hides while the app window is visible", main, /isLiveVoiceHUDStatus\(payload\.status\)[\s\S]{0,220}mainWindow\.isVisible\(\)[\s\S]{0,120}!mainWindow\.isMinimized\(\)/],
  ["proxy: Gemini turn completion cannot reopen on late model parts", proxy, /const parts = Array\.isArray\(modelTurn\?\.parts\)[\s\S]{0,700}content\.turnComplete \|\| content\.generationComplete[\s\S]{0,120}!this\.geminiTurnFinished/],
  ["proxy: Gemini starts a new completion only from new input", proxy, /private beginGeminiResponseTurn\(\)[\s\S]{0,240}this\.geminiTurnFinished = false;[\s\S]{0,900}private async sendGeminiText\(text: string\)[\s\S]{0,180}this\.beginGeminiResponseTurn\(\)/],
  ["renderer: live voice HUD shows agent work while runs are active", renderer, /const liveVoiceAgentWorkActive = liveVoiceStatus !== "idle"[\s\S]{0,600}hasActiveRealtimeDelegationRun\(\)[\s\S]{0,600}liveVoiceAgentWorkActive \? "live-delegating"/],
  ["renderer: active note follow-ups carry the selected note itemID", renderer, /Active source note itemID:[\s\S]{0,650}knowledge_quick_save_note or knowledge_request_reference with this exact itemID[\s\S]{0,220}Do not target the List or create another note/],
  ["proxy: quick note save accepts an exact itemID", proxy, /name: "knowledge_quick_save_note"[\s\S]{0,900}itemID: \{ type: "string"[\s\S]{0,180}Always use this when the live context names the active source note/],
  ["proxy: note follow-up instructions forbid duplicate creation", proxy, /Active source note itemID[\s\S]{0,280}pass that exact itemID to knowledge_quick_save_note or knowledge_request_reference[\s\S]{0,220}never a request to create another note/],
  ["proxy: execution requests veto personal recall", proxy, /function requiresAgentExecution[\s\S]*function recallRouteForToolCall[\s\S]{0,500}requiresAgentExecution\(normalizedUtterance\)/],
  ["proxy: real execution is high-confidence delegation", proxy, /function isHighConfidenceRealtimeDelegation[\s\S]{0,500}requiresAgentExecution\(normalized\)\) return true/],
  ["proxy: delegated tasks acknowledge, wait, then narrate completion", proxy, /function delegatedTaskStartedText[\s\S]*startCodexHandoff\(callID, decision\.prompt, "message"\)[\s\S]*startExternalHandoff[\s\S]*completeHandoff[\s\S]*enqueueParallelResult/],
  ["bridge: personal recall removes internal session records", bridge, /function isInternalPersonalRecallNoise[\s\S]{0,700}queue operation[\s\S]*isInternalPersonalRecallNoise\(result\)/],
  ["bridge: archived Voice Logs are ignored when resolving the shared thread", bridge, /ensureRemoteLiveVoiceThread\(requestedThreadID\?: string\)[\s\S]{0,520}requested\?\.isArchived !== true[\s\S]{0,520}session\.isArchived !== true/],
  ["bridge: archived Codex provider sessions start fresh", bridge, /function isArchivedCodexSessionError\(error: unknown\)[\s\S]*const archivedProviderSession = isArchivedCodexSessionError\(error\);[\s\S]{0,300}if \(!missingProviderSession && !archivedProviderSession\) throw error;[\s\S]{0,300}starting fresh provider session after/],
  ["bridge: Codex CLI lookup supports Finder PATH", bridge, /path\.join\(home, "\.npm-global", "bin", "codex"\)/],
  ["bridge: Codex spawn failures reject pending work", bridge, /Codex App Server failed to start:/]
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
