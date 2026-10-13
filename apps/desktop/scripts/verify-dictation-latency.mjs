import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

// Guards for the dictation stop→paste latency fixes (2026-07-02). The old
// pipeline serialized: transcript history write → fresh osascript frontmost
// query → re-activating the already-frontmost app (+180ms) → paste → 450ms
// clipboard-restore block, and every cloud upload paid a cold TLS handshake.

const main = fs.readFileSync(path.resolve("electron/main.ts"), "utf8");
const bridge = fs.readFileSync(path.resolve("electron/openassistBridge.ts"), "utf8");
const app = fs.readFileSync(path.resolve("src/App.tsx"), "utf8");
const inserter = fs.readFileSync(path.resolve("electron/helpers/text-inserter-helper.swift"), "utf8");

// Cloud connection prewarm exists and fires on dictation stop.
assert.match(
  bridge,
  /async function prewarmCloudTranscriptionConnection\(/,
  "Bridge must expose the cloud transcription connection prewarm."
);
const stopConfigured = main.slice(
  main.indexOf("async function stopConfiguredVoiceInput"),
  main.indexOf("function openAssistTargetPath")
);
assert.match(
  stopConfigured,
  /pendingTranscriptTargetApplication = targetApplication/,
  "Dictation stop must preserve the exact app captured when the shortcut started."
);
assert.match(
  stopConfigured,
  /refreshFrontmostApplicationSnapshot\(\)/,
  "Dictation stop must capture the frontmost app in parallel with transcription."
);
assert.match(
  stopConfigured,
  /prewarmCloudTranscriptionConnection\(\)/,
  "Dictation stop must prewarm the cloud provider connection."
);

// Paste path reuses the recent snapshot and skips redundant re-activation.
const insert = main.slice(
  main.indexOf("async function insertTranscriptText"),
  main.indexOf("function openAssistRepoRoot")
);
assert.match(
  insert,
  /frontmostApplicationSnapshotWithMaxAge\(/,
  "insertTranscriptText must reuse a recent frontmost snapshot instead of a fresh osascript round-trip."
);
assert.match(
  insert,
  /const capturedTarget = pendingTranscriptTargetApplication/,
  "Transcript insertion must prefer the app captured at shortcut key-down."
);
assert.match(
  insert,
  /insertTranscriptInOpenAssistRenderer\(trimmed\)/,
  "Open Assist must insert through its renderer instead of sending synthetic keystrokes to itself."
);
assert.ok(
  insert.indexOf("typeTextForTarget") < insert.indexOf("pasteTextWithTransientClipboard"),
  "Transcript insertion must type directly before using clipboard paste as a fallback."
);
assert.match(
  insert,
  /target\.pid !== frontmost\?\.pid/,
  "insertTranscriptText must skip activation (and its 180ms delay) when the target is already frontmost."
);

// Clipboard restore no longer blocks for 450ms.
assert.match(
  inserter,
  /let clipboardRestoreDelay: useconds_t = 250_000/,
  "Clipboard restore delay must stay at 250ms — 450ms made every dictation feel slow."
);

// History save is off the paste critical path.
assert.doesNotMatch(
  app,
  /await window\.openAssistElectron\?\.addTranscriptHistory\?\.\(transcript\);/,
  "Saving transcript history must not be awaited before pasting."
);
assert.match(
  app,
  /dictationTargetRef\.current = captureFocusedAppField\(\)\s*\?\? \(document\.hasFocus\(\) \? connectedEditableTargetSnapshot\(lastEditableTargetRef\.current\) : null\)/,
  "Dictation must remember the exact Open Assist field and cursor where recording started — but only while the Open Assist window is focused, so global-hotkey dictation from another app pastes there instead of the composer."
);
assert.match(
  app,
  /const inAppDefaultAllowed = Boolean\(dictationTarget\) \|\| document\.hasFocus\(\);/,
  "The composer/note default insert must be gated on window focus so external-app dictation reaches the native paste path."
);
assert.match(
  app,
  /inAppDefaultAllowed && insertTranscriptIntoComposer\(transcript, dictationTarget\)/,
  "The composer must not swallow transcripts dictated into another app."
);
assert.match(
  app,
  /lastEditableTargetRef\.current = snapshot/,
  "Open Assist must continuously remember the last real editable field before its voice UI changes focus."
);
assert.match(
  app,
  /const targetField = rememberedTarget[\s\S]*?connectedEditableTargetSnapshot\(lastEditableTargetRef\.current\)/,
  "Returned transcripts must prefer the saved dictation cursor over the field focused after capture."
);
assert.match(
  app,
  /insertTranscriptIntoComposer\(transcript, dictationTarget\)[\s\S]*?insertTextIntoAppFieldSnapshot\(transcript, dictationTarget\)/,
  "Finished dictation must update the React composer directly before trying generic field insertion."
);
assert.match(
  app,
  /onInsertTranscriptInApp\?\.\(/,
  "The renderer must listen for paste-last requests from the installed app shortcut."
);
assert.match(
  app,
  /data-openassist-composer="true"/,
  "The main composer must be an explicit fallback target for internal transcript insertion."
);
assert.match(
  app,
  /const insertTranscriptIntoComposer = useCallback\([\s\S]*?setComposerText\(nextValue\)/,
  "Internal composer insertion must update React state directly instead of relying on a synthetic input event."
);
assert.match(
  app,
  /if \(snapshot && !rememberedComposer\) return false;/,
  "Composer insertion must not steal dictation captured from another OpenAssist field."
);
const rendererInsertion = app.slice(
  app.indexOf("onInsertTranscriptInApp?.("),
  app.indexOf("onVoiceShortcut?.(")
);
assert.match(
  rendererInsertion,
  /insertTranscriptIntoComposer\(text, targetField\)[\s\S]*?insertTextIntoAppFieldSnapshot\(text, targetField\)/,
  "Paste-last must prefer the direct React composer path while retaining generic app-field support."
);
assert.match(
  main,
  /openassist:insert-transcript-in-app-result/,
  "The main process must wait for renderer confirmation before reporting that internal paste succeeded."
);

console.log("Dictation latency guards verified.");

// ---- Warm dictation start (2026-07-16) ----
// A pre-armed recording helper (mic OFF, kqueue-blocked) must exist so the
// shortcut press skips process spawn + permission round-trips.
const speechHelper = fs.readFileSync(path.resolve("electron/helpers/apple-speech-helper.swift"), "utf8");
assert.match(
  speechHelper,
  /--arm-recording/,
  "The Swift helper must support --arm-recording warm mode."
);
assert.match(
  speechHelper,
  /makeFileSystemObjectSource/,
  "The armed helper must block on a kqueue watch, not poll."
);
assert.match(
  speechHelper,
  /let routeSwitchNeeded[\s\S]*?if !routeSwitchNeeded[\s\S]*?try capture\.prepare\(\)/,
  "The armed helper must prepare AVAudioRecorder before the shortcut press whenever no mic route switch is needed."
);
assert.match(
  speechHelper,
  /pthread_set_qos_class_self_np\(QOS_CLASS_USER_INTERACTIVE, 0\)/,
  "The helper must raise its QoS so dictation start is not starved under system load."
);
assert.match(
  main,
  /deferVoiceCaptureDirectoryCleanup\(\);/,
  "Start paths must defer old-session disk cleanup off the latency-sensitive path."
);
assert.match(
  main,
  /watcher = fs\.watch\(sessionDirectory, \(\) => check\(\)\);/,
  "waitForVoiceFile must react to the helper's file instantly via fs.watch, with polling as fallback."
);
assert.match(
  main,
  /adoptArmedVoiceHelper\(configuration\)/,
  "Voice starts must adopt the armed helper when available."
);
assert.match(
  main,
  /armedVoiceHelper\?\.helperPid === helper\.pid\) continue;/,
  "The stale-helper sweep must never kill the parked warm helper."
);
assert.match(
  main,
  /voice start timing engine=/,
  "Start timing logs must exist so warm vs cold can be measured."
);
assert.match(
  main,
  /disarmVoiceHelper\("app quitting"\)/,
  "The armed helper must be torn down on quit (no orphan processes)."
);
assert.match(
  main,
  /const shouldStartHoldCapture = target === "holdToTalk"[\s\S]*startConfiguredVoiceInput\(warmConfiguration\)/,
  "Hold-to-talk must start capture in the main process without waiting for the renderer."
);
assert.match(
  main,
  /if \(voiceStartInFlight\) return voiceStartInFlight;/,
  "Renderer and main-process starts must join one in-flight capture operation."
);
assert.doesNotMatch(
  main,
  /armedVoiceHelperMaxAgeMs|armed helper expired/,
  "A healthy parked helper must not be discarded only because it has been idle."
);
assert.match(
  main,
  /hold shortcut HUD visible elapsedMs=/,
  "The shortcut-to-HUD timing must be logged."
);
assert.match(
  main,
  /hold shortcut microphone ready elapsedMs=/,
  "The shortcut-to-microphone timing must be logged."
);
assert.match(
  main,
  /if \(armed\) \{\s*void cleanupStaleVoiceHelpers\("after warm cloud voice start", armed\.helperPid\);/,
  "A warm cloud capture must not wait for the stale-process scan."
);
assert.match(
  main,
  /function shouldPreferExternalMicrophone[\s\S]*?return false;/,
  "Automatic microphone selection must use the macOS default instead of an arbitrary external or virtual device."
);
assert.match(
  main,
  /title: "Open Assist Voice HUD"[\s\S]*?backgroundThrottling: false/,
  "The preloaded HUD must not wait on Chromium's hidden-window timer throttling."
);
assert.match(
  main,
  /function prepaintVoiceHUDListeningState[\s\S]*?window\.updateOpenAssistVoiceHUD/,
  "The hidden HUD must paint its listening UI before the first shortcut press."
);
const holdShortcutHUD = main.indexOf("const hudPresentation = shouldShowStandaloneHUD");
const holdShortcutStart = main.indexOf("startConfiguredVoiceInput(warmConfiguration).then", holdShortcutHUD);
assert.ok(
  holdShortcutHUD >= 0 && holdShortcutStart > holdShortcutHUD,
  "The prepainted HUD must be presented before capture work can block its first frame."
);
assert.match(
  main,
  /const voiceStart = hudPresentation\.then\([\s\S]*?setImmediate\(\(\) => \{[\s\S]*?startConfiguredVoiceInput\(warmConfiguration\)/,
  "Capture must start on the next event-loop turn instead of blocking the HUD presentation."
);
