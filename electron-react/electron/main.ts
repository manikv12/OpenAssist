import { app, BrowserWindow, clipboard, dialog, globalShortcut, ipcMain, Menu, nativeImage, nativeTheme, Notification, screen, session, shell, systemPreferences, Tray, type ContextMenuParams, type OpenDialogOptions, type WebContents } from "electron";
import fs from "node:fs";
import { execFileSync, spawn, execFile, type ChildProcess } from "node:child_process";
import path from "node:path";
import os from "node:os";
import { randomUUID } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  appleEventKitStatus,
  buildGoogleCommandPlan,
  connectorSkillGuide,
  createGoogleConnectorAccount,
  googleOAuthSetupStatus,
  importGoogleClientSecret,
  installPinnedGoogleCLI,
  loadConnectorSnapshot,
  loadConnectorReviewInbox,
  markConnectorItem,
  ignoreConnectorReviewItems,
  removeGoogleConnectorAccount,
  requestAppleEventKitAccess,
  reuseGoogleClientSecret,
  saveConnectorItemToBacklogInput,
  setConnectorServiceEnabled,
  setAppleEventKitCommandRunner,
  syncGmailMetadataToReviewInbox,
  type ConnectorItem,
  type ConnectorItemStatus,
  type ConnectorServiceID,
  type GmailSyncOptions,
  type GoogleConnectorOperation
} from "./connectors.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const isDev = Boolean(process.env.VITE_DEV_SERVER_URL);
const isAccessibilityTestMode = process.env.OPENASSIST_ELECTRON_AX_TEST === "1";
const shouldForceAccessibility = process.env.OPENASSIST_ELECTRON_NO_FORCE_AX !== "1";

app.commandLine.appendSwitch("enable-features", "CanvasDrawElement");
app.setName("Open Assist");
const debugLogPath = process.env.OPENASSIST_ELECTRON_DEBUG_LOG;
let mainWindow: BrowserWindow | null = null;
let voiceHUDWindow: BrowserWindow | null = null;
let screenSelectionWindow: BrowserWindow | null = null;
let screenAnalysisFrameWindow: BrowserWindow | null = null;
let screenAnalysisFrameWindowReady = false;
let screenAnalysisWindow: BrowserWindow | null = null;
let screenAnalysisWindowReady = false;
let screenAnalysisFrameVisible = true;
let screenAnalysisPanelExpandedHeight = 380;
let screenAnalysisHiddenMainWindow = false;
let screenAnalysisStatus: "idle" | "prompt" | "analyzing" | "result" = "idle";
let transcriptHistoryWindow: BrowserWindow | null = null;
let settingsWindow: BrowserWindow | null = null;
let menuBarTray: Tray | null = null;
let menuBarPopoverWindow: BrowserWindow | null = null;
let menuBarPopoverShownAt = 0;
let menuBarPopoverBlurTimer: NodeJS.Timeout | null = null;
let menuBarPopoverContentReady = false;
let menuBarPopoverAppearanceSignature = "";
let menuBarPopoverWarmed = false;
// Real height of the popover card, reported by the page so the window hugs
// its content (the content varies with live activity cards).
let menuBarPopoverContentHeight = 0;
let isQuitting = false;
const connectorTerminalSessions = new Map<string, ChildProcess>();
let ollamaQuitCleanupStarted = false;
let ollamaQuitCleanupFinished = false;
let voiceHUDReady = false;
let pendingVoiceHUDPayload: VoiceHUDPayload | null = null;
let voiceHUDLevelTimer: NodeJS.Timeout | null = null;
let voiceHUDLevelMtime = 0;
let smoothedVoiceLevel = 0;
let voiceHUDAutoHideTimer: NodeJS.Timeout | null = null;
// Status|size of the currently presented HUD window; used to skip redundant
// setBounds/showInactive calls on the 120ms live-voice update stream.
let voiceHUDPresentationKey = "";
// Last interactivity applied to the HUD window (null = unknown/new window).
let voiceHUDInteractiveApplied: boolean | null = null;
// Debounce for hiding the LIVE HUD: transient idle/focus blips between turns
// were hiding + re-showing the window in a visible loop. A hide only lands if
// no live payload arrives within the grace window.
let voiceHUDLiveHideTimer: NodeJS.Timeout | null = null;
let lastLiveVoiceHUDSnapshot: VoiceHUDPayload | null = null;
let voiceCaptureHUDKeepAliveTimer: NodeJS.Timeout | null = null;

type SpellcheckContextPayload = {
  misspelledWord: string;
  suggestions: string[];
  isEditable: boolean;
  createdAt: number;
};
const spellcheckContextByWebContentsID = new Map<number, SpellcheckContextPayload>();

function safeSendWebContents(target: WebContents | null | undefined, channel: string, ...args: unknown[]) {
  if (!target || target.isDestroyed()) return false;
  try {
    target.send(channel, ...args);
    return true;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    debugLog(`safe send skipped channel=${channel} error=${message}`);
    return false;
  }
}

function safeSendWindow(window: BrowserWindow | null | undefined, channel: string, ...args: unknown[]) {
  if (!window || window.isDestroyed() || window.webContents.isDestroyed()) return false;
  return safeSendWebContents(window.webContents, channel, ...args);
}

function broadcastRealtimeEvent(payload: unknown, sender?: WebContents) {
  const targets = new Set<WebContents>();
  if (sender && !sender.isDestroyed()) targets.add(sender);
  BrowserWindow.getAllWindows().forEach((window) => {
    if (!window.isDestroyed() && !window.webContents.isDestroyed()) {
      targets.add(window.webContents);
    }
  });
  targets.forEach((target) => safeSendWebContents(target, "openassist:realtime-event", payload));
}

type ConnectorSyncProgress = {
  id: string;
  provider: "google" | "apple" | "local";
  serviceID: string;
  accountID?: string;
  accountLabel?: string;
  status: "running" | "completed" | "failed";
  message: string;
  importedCount?: number;
  reviewCount?: number;
  itemTitles?: string[];
  startedAt?: string;
  finishedAt?: string;
  error?: string;
};

function broadcastConnectorSyncProgress(payload: ConnectorSyncProgress, sender?: WebContents) {
  const targets = new Set<WebContents>();
  if (sender && !sender.isDestroyed()) targets.add(sender);
  BrowserWindow.getAllWindows().forEach((window) => {
    if (!window.isDestroyed() && !window.webContents.isDestroyed()) {
      targets.add(window.webContents);
    }
  });
  targets.forEach((target) => safeSendWebContents(target, "openassist:connector-sync-progress", payload));
}

function normalizeSpellcheckContext(params: ContextMenuParams): SpellcheckContextPayload | null {
  const misspelledWord = String(params.misspelledWord ?? "").trim();
  const suggestions = Array.from(new Set((params.dictionarySuggestions ?? [])
    .map((suggestion) => String(suggestion ?? "").trim())
    .filter(Boolean)))
    .slice(0, 8);
  if (!misspelledWord) return null;
  return {
    misspelledWord,
    suggestions,
    isEditable: Boolean(params.isEditable),
    createdAt: Date.now()
  };
}

function attachSpellcheckContext(window: BrowserWindow) {
  window.webContents.on("context-menu", (_event, params) => {
    const payload = normalizeSpellcheckContext(params);
    if (payload) {
      spellcheckContextByWebContentsID.set(window.webContents.id, payload);
      safeSendWindow(window, "openassist:spellcheck-context", payload);
      return;
    }
    spellcheckContextByWebContentsID.delete(window.webContents.id);
  });
  window.webContents.once("destroyed", () => {
    spellcheckContextByWebContentsID.delete(window.webContents.id);
  });
}

function broadcastThreadsUpdated() {
  BrowserWindow.getAllWindows().forEach((window) => {
    safeSendWindow(window, "openassist:threads-updated");
  });
}

// Background app-state pass updates (plugins, automations, full thread list,
// usage refresh) stream to the renderer here, mirroring the existing
// threads-updated pattern. The renderer subscribes via
// window.openAssistElectron.onAppStateBackgroundReady.
function broadcastAppStateBackgroundUpdate(update: unknown) {
  BrowserWindow.getAllWindows().forEach((window) => {
    safeSendWindow(window, "openassist:app-state-background-update", update);
  });
}

let lastVoiceHUDAppearance: Pick<VoiceHUDPayload, "theme" | "colorTheme" | "chromeStyle"> = {
  theme: "Vibrant Spectrum",
  colorTheme: "Ocean",
  chromeStyle: "Liquid Glass"
};
let frontmostTrackerTimer: NodeJS.Timeout | null = null;
let frontmostSnapshotInFlight: Promise<FrontmostApplicationSnapshot | null> | null = null;
let lastExternalApplication: FrontmostApplicationSnapshot | null = null;
let lastFrontmostSnapshot: FrontmostApplicationSnapshot | null = null;
const frontmostTrackerIntervalMs = 5_000;
type AssistantWindowMode = "full" | "sidebar" | "notch";

let currentWindowMode: AssistantWindowMode = "full";
let currentSidebarOpen = true;
let currentNotchDockRevealed = false;
let currentSidebarEdge: "left" | "right" = "right";
let sidebarPinnedPreference = true;
let sidebarScreenFollowTimer: NodeJS.Timeout | null = null;
let menuBarIconTimer: NodeJS.Timeout | null = null;
let menuBarIconPhase = 0;
let menuBarVoiceStatus: "idle" | "listening" | "processing" | "connecting" | "speaking" | "delegating" | "error" = "idle";
let menuBarVoiceLevel = 0;
let menuBarVoiceText = "";
// Live snapshot of what the renderer is doing (running chats, unread replies),
// reported over IPC so the menu bar popover never shows stale information.
let menuBarAppState: MenuBarAppStateSnapshot = { runs: [], unreadCount: 0, threadCount: 0, updatedAt: 0 };
let voiceCapture: {
  sessionDirectory: string;
  appPath: string;
  engine: "appleSpeech" | "cloudProviders" | "whisperCpp";
  helperProcess?: ChildProcess;
  helperPid?: number;
  startedAt: number;
  audioPath?: string;
  fileName?: string;
  mimeType?: string;
  processing?: boolean;
  voiceOptions?: VoiceStartOptions;
  whisperModelID?: string;
  whisperModelPath?: string;
  whisperUseCoreML?: boolean;
} | null = null;
type WakeWordStatusState = "idle" | "starting" | "listening" | "detected" | "error" | "stopped";
type WakeWordStatusPayload = {
  state: WakeWordStatusState;
  source: "today";
  engine: "openWakeWord" | "appleSpeechPhrase";
  phrase: string;
  enabled?: boolean;
  message?: string;
  error?: string;
  startedAt?: number;
  detectedAt?: number;
};
type WakeWordCaptureState = {
  sessionDirectory: string;
  helperProcess?: ChildProcess;
  helperPid?: number;
  launchedViaLaunchServices?: boolean;
  phrase: string;
  startedAt: number;
  detected: boolean;
  ready: boolean;
  stopping: boolean;
  stdoutBuffer: string;
  fileEventMtimes?: Record<string, number>;
  pollTimer?: NodeJS.Timeout;
};
let wakeWordCapture: WakeWordCaptureState | null = null;
let wakeWordRestartTimer: NodeJS.Timeout | null = null;
let wakeWordCrashCount = 0;
let wakeWordLastCrashAt = 0;
let wakeWordStatus: WakeWordStatusPayload = {
  state: "idle",
  source: "today",
  engine: "appleSpeechPhrase",
  phrase: "Hey Open Assist",
  enabled: false,
  message: "Wake word is off."
};
type OpenAssistBridge = typeof import("./openassistBridge.js");
let bridgeModule: Promise<OpenAssistBridge> | null = null;
type LocalVoiceTranscriptionRequest = {
  audioBase64?: string;
  fileName?: string;
  mimeType?: string;
  transcriptionEngine?: string;
  cloudTranscriptionProvider?: string;
  cloudTranscriptionAPIKeyConfigured?: boolean;
  whisperModel?: string;
  whisperUseCoreML?: boolean;
};
type ScreenRect = {
  x: number;
  y: number;
  width: number;
  height: number;
};
type VoiceHUDPayload = {
  visible?: boolean;
  status?: "idle" | "listening" | "processing" | "unsupported" | "error" | "message" | "correction" | "analyzing" | "analysis-result" | "analyzing-input" | "live-connecting" | "live-listening" | "live-speaking" | "live-delegating";
  text?: string;
  theme?: string;
  colorTheme?: string;
  chromeStyle?: string;
  level?: number;
  tone?: "info" | "success" | "warning" | "error";
  source?: string;
  replacement?: string;
  previewDataURL?: string;
  suppressForAppFocus?: boolean;
  providerLabel?: string;
  userText?: string;
  assistantText?: string;
  // Agent/tool work status; rendered in its own small chip so it never
  // competes with the spoken caption.
  workText?: string;
  muted?: boolean;
  // Pending knowledge approval surfaced in the Live Voice HUD so the user can
  // approve/deny by click without opening the main window.
  approval?: { requestID: string; summary?: string } | null;
  // When Live Voice is muted, dictation capture stacks a small strip above the
  // orb instead of replacing the live HUD in the shared floating window.
  dictationCapture?: boolean;
  dictationLevel?: number;
};
type ScreenAnalysisGeneratedImage = {
  dataURL: string;
  mimeType: string;
  name: string;
  prompt?: string;
};
type MenuBarCommand =
  | "open-assistant"
  | "new-chat"
  | "speak-assistant-task"
  | "toggle-dictation"
  | "open-history"
  | "open-today"
  | "open-models"
  | "open-settings";
type MenuBarAction = MenuBarCommand | "paste-last-transcript" | "quit";
type MenuBarAssistantRun = {
  title: string;
  provider: string;
  statusText: string;
  startedAt: number;
};
type MenuBarAppStateSnapshot = {
  runs: MenuBarAssistantRun[];
  unreadCount: number;
  threadCount: number;
  updatedAt: number;
};
type TranscriptHistoryEntry = {
  id: string;
  text: string;
  createdAt: string;
};
type FrontmostApplicationSnapshot = {
  pid: number;
  bundleIdentifier: string;
  name: string;
  capturedAt: number;
};
type TranscriptInsertionResult = {
  ok: boolean;
  result: "pasted" | "typed" | "not-inserted" | "empty";
  target?: FrontmostApplicationSnapshot;
  error?: string;
  debugStatus?: string;
  method?: string;
};
type ShortcutTarget = "holdToTalk" | "continuousToggle" | "assistantLiveVoice" | "assistantCompact" | "screenAnalysis";
type ShortcutPhase = "trigger" | "down" | "up";
type ShortcutSettingsSnapshot = {
  holdToTalkShortcutKeyCode: number;
  holdToTalkShortcutModifiers: number;
  continuousToggleShortcutKeyCode: number;
  continuousToggleShortcutModifiers: number;
  assistantLiveVoiceShortcutKeyCode: number;
  assistantLiveVoiceShortcutModifiers: number;
  assistantCompactShortcutKeyCode: number;
  assistantCompactShortcutModifiers: number;
  screenAnalysisShortcutKeyCode: number;
  screenAnalysisShortcutModifiers: number;
};
type VoiceStartOptions = {
  transcriptionEngine?: string;
  cloudTranscriptionProvider?: string;
  cloudTranscriptionAPIKeyConfigured?: boolean;
  autoDetectMicrophone?: boolean;
  selectedMicrophoneUID?: string;
  whisperModel?: string;
  whisperUseCoreML?: boolean;
  floatingHUDEnabled?: boolean;
  waveformTheme?: string;
  colorTheme?: string;
  appChromeStyle?: string;
  dictationStartSoundName?: string;
  dictationStopSoundName?: string;
  dictationProcessingSoundName?: string;
  dictationPastedSoundName?: string;
  dictationCorrectionLearnedSoundName?: string;
  dictationFeedbackVolume?: number;
};
type DictationFeedbackCue = "startListening" | "stopListening" | "processing" | "pasted" | "correctionLearned";
type MicrophoneOption = {
  uid: string;
  name: string;
  isDefault?: boolean;
};
const manualModifierOnlyKeyCode = 65535;
const shortcutModifierFlags = {
  shift: 131072,
  control: 262144,
  option: 524288,
  command: 1048576,
  fn: 8388608
} as const;
const registeredAssistantAccelerators = new Set<string>();
const shortcutTargets: ShortcutTarget[] = ["holdToTalk", "continuousToggle", "assistantLiveVoice", "assistantCompact", "screenAnalysis"];
const pasteLastTranscriptAccelerator = process.platform === "darwin" ? "Command+Alt+V" : "CommandOrControl+Alt+V";
const menuBarPopoverSize = { width: 320, height: 510 };
let shortcutMonitorProcess: ChildProcess | null = null;
let shortcutMonitorGeneration = 0;
const noDictationSoundName = "None";
const dictationSoundOptions = new Set([
  noDictationSoundName,
  "Basso",
  "Blow",
  "Bottle",
  "Frog",
  "Funk",
  "Glass",
  "Hero",
  "Ping",
  "Pop",
  "Purr",
  "Sosumi",
  "Submarine",
  "Tink"
]);
const defaultDictationSounds: Record<DictationFeedbackCue, string> = {
  startListening: "Ping",
  stopListening: "Glass",
  processing: "Ping",
  pasted: "Pop",
  correctionLearned: "Purr"
};

const whisperModelIDs = [
  "tiny",
  "tiny.en",
  "tiny-q5_1",
  "tiny.en-q5_1",
  "tiny-q8_0",
  "base",
  "base.en",
  "base-q5_1",
  "base.en-q5_1",
  "base-q8_0",
  "small",
  "small.en",
  "small.en-tdrz",
  "small-q5_1",
  "small.en-q5_1",
  "small-q8_0",
  "medium",
  "medium.en",
  "medium-q5_0",
  "medium.en-q5_0",
  "medium-q8_0",
  "large-v1",
  "large-v2",
  "large-v2-q5_0",
  "large-v2-q8_0",
  "large-v3",
  "large-v3-q5_0",
  "large-v3-turbo",
  "large-v3-turbo-q5_0",
  "large-v3-turbo-q8_0"
] as const;

const enableElectronDebugging = process.env.OPENASSIST_ELECTRON_REMOTE_DEBUG === "1";
const showDeveloperMenuItems = process.env.OPENASSIST_SHOW_DEV_MENU === "1";
if (enableElectronDebugging) {
  app.commandLine.appendSwitch("remote-debugging-port", process.env.OPENASSIST_ELECTRON_REMOTE_DEBUG_PORT || "8315");
}
const autoOpenDevTools = process.env.OPENASSIST_OPEN_DEVTOOLS === "1";
const enableDevTools = autoOpenDevTools || showDeveloperMenuItems || enableElectronDebugging;

function electronDebugLogPath() {
  if (debugLogPath) return debugLogPath;
  try {
    const userDataPath = app.getPath("userData");
    fs.mkdirSync(userDataPath, { recursive: true });
    return path.join(userDataPath, "electron-debug.log");
  } catch {
    return path.join(os.tmpdir(), "openassist-electron-debug.log");
  }
}

// Async batched log writer. fs.appendFileSync is called from 95+ sites,
// some on hot paths (IPC, screen analysis, AppleScript callbacks). Buffering
// the lines and flushing every 250 ms (or when the buffer exceeds 4 KB) keeps
// the main Node event loop unblocked. Synchronous flushes still happen on
// quit so logs aren't lost.
const debugLogBuffer: string[] = [];
let debugLogPending = 0;
let debugLogFlushTimer: NodeJS.Timeout | null = null;
let debugLogWriteInFlight = false;

function flushDebugLogAsync() {
  if (debugLogFlushTimer) {
    clearTimeout(debugLogFlushTimer);
    debugLogFlushTimer = null;
  }
  if (debugLogWriteInFlight) return;
  if (debugLogBuffer.length === 0) return;
  const chunk = debugLogBuffer.join("");
  debugLogBuffer.length = 0;
  debugLogPending = 0;
  debugLogWriteInFlight = true;
  fs.appendFile(electronDebugLogPath(), chunk, "utf8", () => {
    debugLogWriteInFlight = false;
    if (debugLogBuffer.length > 0) flushDebugLogAsync();
  });
}

function flushDebugLogSync() {
  if (debugLogFlushTimer) {
    clearTimeout(debugLogFlushTimer);
    debugLogFlushTimer = null;
  }
  if (debugLogBuffer.length === 0) return;
  const chunk = debugLogBuffer.join("");
  debugLogBuffer.length = 0;
  debugLogPending = 0;
  try {
    fs.appendFileSync(electronDebugLogPath(), chunk, "utf8");
  } catch {
    // Never let logging break shutdown.
  }
}

function debugLog(message: string) {
  const line = `[${new Date().toISOString()}] ${message}\n`;
  debugLogBuffer.push(line);
  debugLogPending += line.length;
  if (debugLogPending >= 4096) {
    flushDebugLogAsync();
    return;
  }
  if (!debugLogFlushTimer) {
    debugLogFlushTimer = setTimeout(flushDebugLogAsync, 250);
    debugLogFlushTimer.unref?.();
  }
}

// High-volume, only-useful-when-debugging tracing. Off unless
// OPENASSIST_VERBOSE_LOG=1. Errors and lifecycle events use debugLog directly.
const verboseMainLoggingEnabled = process.env.OPENASSIST_VERBOSE_LOG === "1";
function verboseLog(message: string) {
  if (verboseMainLoggingEnabled) debugLog(message);
}

function maybeOpenDevTools(window: BrowserWindow, label: string) {
  if (!autoOpenDevTools) return;
  const open = () => {
    if (window.isDestroyed() || window.webContents.isDevToolsOpened()) return;
    debugLog(`open DevTools window=${label}`);
    window.webContents.openDevTools({ mode: "detach" });
  };
  if (window.webContents.isLoading()) {
    window.webContents.once("did-finish-load", () => setTimeout(open, 150));
  } else {
    setTimeout(open, 150);
  }
}

debugLog("main module loaded");

const openAssistDefaultsDomain = "com.developingadventures.OpenAssist";
const liquidGlassChromeStyle = "Liquid Glass";
const liquidGlassDefaultMigrationKey = "OpenAssist.liquidGlassDefaultMigrated";

function readNativeDefaultSync(key: string, fallback: string) {
  try {
    const stdout = execFileSync("defaults", ["read", openAssistDefaultsDomain, key], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"]
    });
    return stdout.trim() || fallback;
  } catch {
    return fallback;
  }
}

function readNativeNumberDefaultSync(key: string, fallback: number) {
  const value = Number(readNativeDefaultSync(key, String(fallback)));
  return Number.isFinite(value) ? value : fallback;
}

function readNativeBoolDefaultSync(key: string, fallback: boolean) {
  const value = readNativeDefaultSync(key, fallback ? "1" : "0").trim().toLowerCase();
  if (["1", "true", "yes"].includes(value)) return true;
  if (["0", "false", "no"].includes(value)) return false;
  return fallback;
}

function writeNativeStringDefaultSync(key: string, value: string) {
  execFileSync("defaults", ["write", openAssistDefaultsDomain, key, "-string", value], { stdio: "ignore" });
}

function writeNativeBoolDefaultSync(key: string, value: boolean) {
  execFileSync("defaults", ["write", openAssistDefaultsDomain, key, "-bool", value ? "true" : "false"], {
    stdio: "ignore"
  });
}

function synchronizeNativeDefaultsSync() {
  try {
    execFileSync("defaults", ["synchronize", openAssistDefaultsDomain], { stdio: "ignore" });
  } catch {
    // The write already happened; synchronize is best effort on macOS.
  }
}

function migrateLiquidGlassDefaultSync() {
  if (readNativeBoolDefaultSync(liquidGlassDefaultMigrationKey, false)) return;
  try {
    writeNativeStringDefaultSync("OpenAssist.appChromeStyle", liquidGlassChromeStyle);
    writeNativeBoolDefaultSync(liquidGlassDefaultMigrationKey, true);
    synchronizeNativeDefaultsSync();
    debugLog("migrated default app chrome style to Liquid Glass");
  } catch (error) {
    debugLog(`liquid glass default migration failed: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function initialAppearanceSettings() {
  migrateLiquidGlassDefaultSync();
  return {
    themeMode: readNativeDefaultSync("OpenAssist.themeMode", "System"),
    colorTheme: readNativeDefaultSync("OpenAssist.colorTheme", "Ocean"),
    appChromeStyle: readNativeDefaultSync("OpenAssist.appChromeStyle", liquidGlassChromeStyle),
    lightThemeAccent: readNativeDefaultSync("OpenAssist.lightTheme.accent", "#0169CC"),
    lightThemeBackground: readNativeDefaultSync("OpenAssist.lightTheme.background", "#FFFFFF"),
    lightThemeForeground: readNativeDefaultSync("OpenAssist.lightTheme.foreground", "#0D0D0D"),
    lightThemeUIFont: readNativeDefaultSync("OpenAssist.lightTheme.uiFont", "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", Arial, sans-serif"),
    lightThemeCodeFont: readNativeDefaultSync("OpenAssist.lightTheme.codeFont", "ui-monospace, SFMono-Regular, Menlo, monospace"),
    lightThemeTranslucentSidebar: readNativeBoolDefaultSync("OpenAssist.lightTheme.translucentSidebar", false),
    lightThemeContrast: readNativeDefaultSync("OpenAssist.lightTheme.contrast", "45"),
    lightThemeCodeThemeID: readNativeDefaultSync("OpenAssist.lightTheme.codeThemeID", "codex"),
    lightThemeDiffAdded: readNativeDefaultSync("OpenAssist.lightTheme.diffAdded", "#00a240"),
    lightThemeDiffRemoved: readNativeDefaultSync("OpenAssist.lightTheme.diffRemoved", "#ba2623"),
    lightThemeSkill: readNativeDefaultSync("OpenAssist.lightTheme.skill", "#924ff7"),
    darkThemeAccent: readNativeDefaultSync("OpenAssist.darkTheme.accent", "#F9861A"),
    darkThemeBackground: readNativeDefaultSync("OpenAssist.darkTheme.background", "#0D1117"),
    darkThemeForeground: readNativeDefaultSync("OpenAssist.darkTheme.foreground", "#E6EDF3"),
    darkThemeUIFont: readNativeDefaultSync("OpenAssist.darkTheme.uiFont", "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", Arial, sans-serif"),
    darkThemeCodeFont: readNativeDefaultSync("OpenAssist.darkTheme.codeFont", "ui-monospace, SFMono-Regular, Menlo, monospace"),
    darkThemeTranslucentSidebar: readNativeBoolDefaultSync("OpenAssist.darkTheme.translucentSidebar", true),
    darkThemeContrast: readNativeDefaultSync("OpenAssist.darkTheme.contrast", "89"),
    darkThemeCodeThemeID: readNativeDefaultSync("OpenAssist.darkTheme.codeThemeID", "github"),
    darkThemeDiffAdded: readNativeDefaultSync("OpenAssist.darkTheme.diffAdded", "#40c977"),
    darkThemeDiffRemoved: readNativeDefaultSync("OpenAssist.darkTheme.diffRemoved", "#fa423e"),
    darkThemeSkill: readNativeDefaultSync("OpenAssist.darkTheme.skill", "#ad7bf9"),
    pointerCursors: readNativeBoolDefaultSync("OpenAssist.usePointerCursors", false),
    fontSmoothing: readNativeBoolDefaultSync("OpenAssist.fontSmoothing", true),
    reduceMotionMode: readNativeDefaultSync("OpenAssist.reduceMotionMode", "System"),
    uiFontSize: readNativeDefaultSync("OpenAssist.uiFontSize", "13"),
    codeFontSize: readNativeDefaultSync("OpenAssist.codeFontSize", "12")
  };
}

function initialAppearanceQuery() {
  return { initialAppearance: JSON.stringify(initialAppearanceSettings()) };
}

function dictationSoundSettingKey(cue: DictationFeedbackCue) {
  switch (cue) {
    case "startListening":
      return "dictationStartSoundName";
    case "stopListening":
      return "dictationStopSoundName";
    case "processing":
      return "dictationProcessingSoundName";
    case "pasted":
      return "dictationPastedSoundName";
    case "correctionLearned":
      return "dictationCorrectionLearnedSoundName";
  }
}

function dictationSoundDefaultsKey(cue: DictationFeedbackCue) {
  switch (cue) {
    case "startListening":
      return "OpenAssist.dictationStartSoundName";
    case "stopListening":
      return "OpenAssist.dictationStopSoundName";
    case "processing":
      return "OpenAssist.dictationProcessingSoundName";
    case "pasted":
      return "OpenAssist.dictationPastedSoundName";
    case "correctionLearned":
      return "OpenAssist.dictationCorrectionLearnedSoundName";
  }
}

function resolvedDictationSoundName(cue: DictationFeedbackCue, options?: VoiceStartOptions) {
  const fallback = defaultDictationSounds[cue];
  const optionValue = options?.[dictationSoundSettingKey(cue)]?.trim();
  const rawValue = optionValue || readNativeDefaultSync(dictationSoundDefaultsKey(cue), fallback);
  if (rawValue === noDictationSoundName) return "";
  return dictationSoundOptions.has(rawValue) ? rawValue : fallback;
}

function dictationFeedbackVolume(options?: VoiceStartOptions) {
  const rawVolume = typeof options?.dictationFeedbackVolume === "number"
    ? options.dictationFeedbackVolume
    : readNativeNumberDefaultSync("OpenAssist.dictationFeedbackVolume", 0.10);
  return Math.max(0, Math.min(1, rawVolume));
}

function dictationFeedbackVolumeMultiplier(cue: DictationFeedbackCue) {
  return cue === "startListening" ? 0.7 : 1;
}

function playDictationFeedbackSound(cue: DictationFeedbackCue, options?: VoiceStartOptions) {
  if (process.platform !== "darwin") return { ok: false, error: "Dictation feedback sounds are only available on macOS." };
  const soundName = resolvedDictationSoundName(cue, options);
  if (!soundName) return { ok: true, skipped: true };
  const soundPath = path.join("/System/Library/Sounds", `${soundName}.aiff`);
  if (!fs.existsSync(soundPath)) return { ok: false, error: `macOS sound not found: ${soundName}` };
  const volume = Math.max(0, Math.min(1, dictationFeedbackVolume(options) * dictationFeedbackVolumeMultiplier(cue)));
  const child = spawn("/usr/bin/afplay", ["-v", volume.toFixed(2), soundPath], {
    detached: true,
    stdio: "ignore"
  });
  child.on("error", (error) => {
    debugLog(`dictation sound failed cue=${cue} sound=${soundName} error=${error instanceof Error ? error.message : String(error)}`);
  });
  child.unref();
  return { ok: true, soundName };
}

function ensureRegularDockPresence(reason: string) {
  if (process.platform !== "darwin") return;
  try {
    const didSetPolicy = app.setActivationPolicy("regular");
    debugLog(`dock presence reason=${reason} activationPolicyRegular=${String(didSetPolicy)}`);
    if (app.dock) void app.dock.show();
  } catch (error) {
    debugLog(`dock presence failed reason=${reason} error=${error instanceof Error ? error.message : String(error)}`);
  }
}

function switchToMenuBarOnlyPresence(reason: string) {
  if (process.platform !== "darwin" || isQuitting) return;
  try {
    const didSetPolicy = app.setActivationPolicy("accessory");
    debugLog(`menu bar presence reason=${reason} activationPolicyAccessory=${String(didSetPolicy)}`);
    if (app.dock) void app.dock.hide();
  } catch (error) {
    debugLog(`menu bar presence failed reason=${reason} error=${error instanceof Error ? error.message : String(error)}`);
  }
}

function appAssetPath(...segments: string[]) {
  const candidates = [
    path.join(app.getAppPath(), ...segments),
    path.join(__dirname, "..", ...segments)
  ];
  return candidates.find((candidate) => fs.existsSync(candidate)) ?? candidates[0];
}

function assetDataURL(relativePath: string, mimeType: string) {
  try {
    const assetPath = appAssetPath(...relativePath.split("/"));
    return `data:${mimeType};base64,${fs.readFileSync(assetPath).toString("base64")}`;
  } catch {
    return "";
  }
}

function openAssistBridge() {
  bridgeModule ??= import("./openassistBridge.js").catch((error) => {
    bridgeModule = null;
    debugLog(`bridge import failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
    throw error;
  });
  return bridgeModule;
}

function stopAssistantVoiceOutputForSessionEnd(reason: string) {
  void openAssistBridge()
    .then((bridge) => bridge.stopAssistantVoiceOutput())
    .catch((error) => {
      debugLog(`${reason} voice cleanup failed: ${error instanceof Error ? error.message : String(error)}`);
    });
}

function isVisibleWindow(window: BrowserWindow | null) {
  return Boolean(window && !window.isDestroyed() && window.isVisible());
}

function isScreenAnalysisSurfaceActive() {
  return isVisibleWindow(screenSelectionWindow)
    || isVisibleWindow(screenAnalysisWindow)
    || isVisibleWindow(screenAnalysisFrameWindow);
}

function hideMainWindowForScreenAnalysis() {
  const window = mainWindow;
  if (!window || window.isDestroyed() || !window.isVisible()) return;
  screenAnalysisHiddenMainWindow = true;
  debugLog("screen analysis hiding main assistant window");
  window.hide();
}

function restoreMainWindowAfterScreenAnalysis(reason: string) {
  if (!screenAnalysisHiddenMainWindow) return;
  screenAnalysisHiddenMainWindow = false;
  const window = mainWindow;
  if (!window || window.isDestroyed()) return;
  debugLog(`screen analysis restoring main assistant window reason=${reason}`);
  if (typeof window.showInactive === "function") {
    window.showInactive();
  } else {
    window.show();
  }
}

function discardScreenAnalysisMainWindowRestore(reason: string) {
  if (!screenAnalysisHiddenMainWindow) return;
  screenAnalysisHiddenMainWindow = false;
  debugLog(`screen analysis leaving main assistant window hidden reason=${reason}`);
}

function escapeHTML(value: string) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function transcriptHistoryPath() {
  return path.join(app.getPath("userData"), "transcript-history.json");
}

function readTranscriptHistory(): TranscriptHistoryEntry[] {
  try {
    const raw = fs.readFileSync(transcriptHistoryPath(), "utf8");
    const parsed = JSON.parse(raw) as TranscriptHistoryEntry[];
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((entry) => typeof entry?.id === "string" && typeof entry.text === "string" && typeof entry.createdAt === "string")
      .slice(0, 40);
  } catch {
    return [];
  }
}

function writeTranscriptHistory(entries: TranscriptHistoryEntry[]) {
  const target = transcriptHistoryPath();
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, JSON.stringify(entries.slice(0, 40), null, 2), "utf8");
}

function addTranscriptHistory(text: string) {
  const trimmed = String(text ?? "").trim();
  if (!trimmed) return readTranscriptHistory();
  const entries = readTranscriptHistory().filter((entry) => entry.text !== trimmed);
  const next = [
    {
      id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
      text: trimmed,
      createdAt: new Date().toISOString()
    },
    ...entries
  ].slice(0, 40);
  writeTranscriptHistory(next);
  return next;
}

function deleteTranscriptHistoryEntry(id: string) {
  const next = readTranscriptHistory().filter((entry) => entry.id !== id);
  writeTranscriptHistory(next);
  return next;
}

function clearTranscriptHistory() {
  writeTranscriptHistory([]);
  return [];
}

async function pasteTranscriptHistoryEntry(id?: string) {
  const entries = readTranscriptHistory();
  const entry = id ? entries.find((item) => item.id === id) : entries[0];
  if (!entry?.text.trim()) {
    return { ok: false, result: "empty" as const, error: "No transcript in Open Assist History" };
  }
  const result = await insertTranscriptText(entry.text);
  if (result.ok) playDictationFeedbackSound("pasted");
  return result;
}

function menuBarSVG(status: typeof menuBarVoiceStatus, level: number, phase: number) {
  const bucketCount = 12;
  const rawFill = status === "listening"
    ? Math.max(0.30, Math.min(1, level))
    : 0.45;
  const fill = Math.round(rawFill * bucketCount) / bucketCount;
  const fillWidth = (28 * fill).toFixed(2);
  const bars = '<path d="M8.1 14v3.2M10.8 10.8v6.4M13.6 8.4v11.2M16.4 11.1v5.8M19.1 12.8v2.4" stroke-linecap="round"/>';
  const circle = '<circle cx="14" cy="14" r="10" />';
  return `
<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 28 28">
  <defs>
    <clipPath id="fill-clip"><rect x="0" y="0" width="${fillWidth}" height="28" /></clipPath>
  </defs>
  <g fill="none" stroke="black" stroke-width="1.7" opacity="0.36">
    ${circle}
    ${bars}
  </g>
  <g fill="none" stroke="black" stroke-width="1.7" opacity="1" clip-path="url(#fill-clip)">
    ${circle}
    ${bars}
  </g>
</svg>`.trim();
}

function menuBarIconBucket(status: typeof menuBarVoiceStatus, level: number, phase = 0) {
  const bucketCount = 12;
  if (status !== "listening") return 5;
  const normalizedLevel = Math.max(0, Math.min(1, level));
  const boostedLevel = Math.min(1, Math.pow(normalizedLevel, 0.82) * 1.05);
  const levelFill = 0.45 + boostedLevel * 0.55;
  const idlePulse = 0.45 + ((Math.sin(phase) + 1) * 0.5) * 0.08;
  const fill = normalizedLevel > 0.04 ? levelFill : idlePulse;
  const bucket = Math.round(fill * bucketCount);
  return Math.max(5, Math.min(bucketCount, bucket));
}

function menuBarIconPath(status: typeof menuBarVoiceStatus, level: number, phase = 0) {
  return appAssetPath("assets", `menu-bar-waveform-fill-${String(menuBarIconBucket(status, level, phase)).padStart(2, "0")}.png`);
}

function menuBarNativeImage(status: typeof menuBarVoiceStatus, level: number, phase: number) {
  const image = nativeImage.createFromPath(menuBarIconPath(status, level, phase));
  const fallback = nativeImage.createFromPath(appAssetPath("icon.icns"));
  const visibleImage = (image.isEmpty() ? fallback : image).resize({ width: 23, height: 23, quality: "best" });
  visibleImage.setTemplateImage(true);
  return visibleImage;
}

function updateMenuBarIcon() {
  if (!menuBarTray) return;
  menuBarTray.setImage(menuBarNativeImage(menuBarVoiceStatus, menuBarVoiceLevel, menuBarIconPhase));
  menuBarTray.setTitle("");
}

function refreshMenuBarPopoverIfVisible() {
  const window = menuBarPopoverWindow;
  if (!window || window.isDestroyed()) return;
  // Update only the dynamic regions in place; no full document reload, so there
  // is no flicker and it stays cheap even while listening.
  refreshMenuBarPopoverDynamicState();
}

function startMenuBarIconAnimation() {
  if (menuBarIconTimer) return;
  menuBarIconTimer = setInterval(() => {
    if (menuBarVoiceStatus !== "listening") {
      if (menuBarIconTimer) {
        clearInterval(menuBarIconTimer);
        menuBarIconTimer = null;
      }
      menuBarIconPhase = 0;
      updateMenuBarIcon();
      return;
    }
    menuBarIconPhase += 0.38;
    if (menuBarIconPhase > Math.PI * 2) menuBarIconPhase -= Math.PI * 2;
    updateMenuBarIcon();
  }, 90);
}

function stopMenuBarIconAnimationIfIdle() {
  if (menuBarVoiceStatus === "listening") return;
  if (menuBarIconTimer) {
    clearInterval(menuBarIconTimer);
    menuBarIconTimer = null;
  }
  menuBarIconPhase = 0;
}

function isLiveVoiceHUDStatus(status: VoiceHUDPayload["status"] | undefined) {
  return status === "live-connecting"
    || status === "live-listening"
    || status === "live-speaking"
    || status === "live-delegating";
}

function liveVoiceHUDSessionActive() {
  return isLiveVoiceHUDStatus(pendingVoiceHUDPayload?.status);
}

function liveVoiceHUDMuted() {
  return pendingVoiceHUDPayload?.muted === true;
}

function updateMenuBarVoiceStatus(payload: VoiceHUDPayload) {
  const previousStatus = menuBarVoiceStatus;
  const previousText = menuBarVoiceText;
  const nextLevel = normalizedVoiceLevel(payload.level);
  if (nextLevel !== null) menuBarVoiceLevel = nextLevel;
  if (typeof payload.text === "string") menuBarVoiceText = payload.text.trim();
  if (payload.visible === false || payload.status === "idle") {
    menuBarVoiceStatus = "idle";
    menuBarVoiceLevel = 0;
    menuBarVoiceText = "";
    stopMenuBarIconAnimationIfIdle();
    updateMenuBarIcon();
    if (previousStatus !== menuBarVoiceStatus || previousText !== menuBarVoiceText) refreshMenuBarPopoverIfVisible();
    return;
  }
  if (isLiveVoiceHUDStatus(payload.status)) {
    menuBarVoiceStatus = payload.status === "live-listening"
      ? "listening"
      : payload.status === "live-connecting"
        ? "connecting"
        : payload.status === "live-speaking"
          ? "speaking"
          : "delegating";
    if (menuBarVoiceStatus === "listening") {
      startMenuBarIconAnimation();
    } else {
      stopMenuBarIconAnimationIfIdle();
    }
    updateMenuBarIcon();
    if (previousStatus !== menuBarVoiceStatus || previousText !== menuBarVoiceText) refreshMenuBarPopoverIfVisible();
    return;
  }
  if (payload.status === "listening") {
    menuBarVoiceStatus = "listening";
    startMenuBarIconAnimation();
    updateMenuBarIcon();
    if (previousStatus !== menuBarVoiceStatus || previousText !== menuBarVoiceText) refreshMenuBarPopoverIfVisible();
    return;
  }
  if (payload.status === "processing") {
    menuBarVoiceStatus = "processing";
    menuBarVoiceLevel = 0;
    stopMenuBarIconAnimationIfIdle();
    updateMenuBarIcon();
    if (previousStatus !== menuBarVoiceStatus || previousText !== menuBarVoiceText) refreshMenuBarPopoverIfVisible();
    return;
  }
  if (payload.status === "error" || payload.status === "unsupported" || payload.status === "message") {
    menuBarVoiceStatus = payload.status === "message" ? "idle" : "error";
    menuBarVoiceLevel = 0;
    stopMenuBarIconAnimationIfIdle();
    updateMenuBarIcon();
    if (previousStatus !== menuBarVoiceStatus || previousText !== menuBarVoiceText) refreshMenuBarPopoverIfVisible();
  }
}

function menuBarHeaderStatusLabel() {
  switch (menuBarVoiceStatus) {
    case "connecting":
      return "Connecting…";
    case "listening":
      return "Listening…";
    case "speaking":
      return "Speaking…";
    case "delegating":
      return "Working…";
    case "processing":
      return "Finalizing…";
    case "error":
      return "Needs attention";
    case "idle":
    default: {
      const running = menuBarAppState.runs.length;
      if (running === 1) return "1 task running";
      if (running > 1) return `${running} tasks running`;
      if (menuBarAppState.unreadCount > 0) {
        return menuBarAppState.unreadCount === 1 ? "1 unread reply" : `${menuBarAppState.unreadCount} unread replies`;
      }
      return "Ready";
    }
  }
}

// "busy" drives the pulsing status dot; "attention" the amber one.
function menuBarHeaderStatusTone(): "ready" | "busy" | "attention" {
  if (menuBarVoiceStatus === "error") return "attention";
  if (menuBarVoiceStatus !== "idle" || menuBarAppState.runs.length > 0) return "busy";
  if (menuBarAppState.unreadCount > 0) return "attention";
  return "ready";
}

function menuBarActivityDetail() {
  if (menuBarVoiceStatus === "idle") return "";
  return menuBarVoiceText;
}

function safePopoverCSSColor(value: string | undefined, fallback: string) {
  const trimmed = String(value || "").trim();
  return /^#[0-9a-fA-F]{3,8}$/.test(trimmed) ? trimmed : fallback;
}

function menuBarPopoverAppearance() {
  const appearance = initialAppearanceSettings();
  const requestedMode = String(appearance.themeMode || "System").toLowerCase();
  const mode = requestedMode === "light"
    ? "light"
    : requestedMode === "dark"
      ? "dark"
      : nativeTheme.shouldUseDarkColors ? "dark" : "light";
  const palette = screenAnalysisAppThemePalette(appearance.colorTheme);
  if (mode === "light") {
    return {
      mode,
      accent: safePopoverCSSColor(appearance.lightThemeAccent, palette[0] || "#0169CC"),
      skill: safePopoverCSSColor(appearance.lightThemeSkill, palette[1] || "#924ff7"),
      background: safePopoverCSSColor(appearance.lightThemeBackground, "#FFFFFF"),
      foreground: safePopoverCSSColor(appearance.lightThemeForeground, "#0D0D0D")
    };
  }
  return {
    mode,
    accent: safePopoverCSSColor(appearance.darkThemeAccent, palette[0] || "#8fb0ff"),
    skill: safePopoverCSSColor(appearance.darkThemeSkill, palette[1] || "#72d99d"),
    background: safePopoverCSSColor(appearance.darkThemeBackground, palette[2] || "#0D1117"),
    foreground: safePopoverCSSColor(appearance.darkThemeForeground, "#E6EDF3")
  };
}

function menuBarPopoverAppearanceSignatureValue() {
  const appearance = menuBarPopoverAppearance();
  return [appearance.mode, appearance.accent, appearance.skill, appearance.background, appearance.foreground].join("|");
}

function menuBarRelativeTimeLabel(timestamp: number) {
  if (!Number.isFinite(timestamp)) return "";
  const seconds = Math.max(0, Math.round((Date.now() - timestamp) / 1000));
  if (seconds < 60) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.round(hours / 24)}d ago`;
}

function menuBarLastTranscriptDetail() {
  const entry = readTranscriptHistory()[0];
  if (!entry) return "No transcripts yet";
  const snippet = entry.text.length > 44 ? `${entry.text.slice(0, 44).trimEnd()}…` : entry.text;
  const when = menuBarRelativeTimeLabel(Date.parse(entry.createdAt));
  return when ? `“${snippet}” · ${when}` : `“${snippet}”`;
}

function menuBarAssistantRowDetail() {
  const unread = menuBarAppState.unreadCount;
  if (unread === 1) return "1 reply waiting for you";
  if (unread > 1) return `${unread} replies waiting for you`;
  return "";
}

// Builds a tiny script that refreshes only the dynamic bits of an already
// loaded popover, so opening it never has to reload the whole document.
function menuBarPopoverDynamicScript() {
  const statusLabel = menuBarHeaderStatusLabel();
  const statusTone = menuBarHeaderStatusTone();
  const dictationLabel = pendingVoiceHUDPayload?.status === "listening" ? "Stop Dictation" : "Start Dictation";
  const activityHTML = menuBarActivityHTML();
  const transcriptDetail = menuBarLastTranscriptDetail();
  const assistantDetail = menuBarAssistantRowDetail();
  return `(() => {
    const status = document.getElementById("oa-status-label");
    if (status) status.textContent = ${JSON.stringify(statusLabel)};
    const pill = document.getElementById("oa-status-pill");
    if (pill) pill.dataset.tone = ${JSON.stringify(statusTone)};
    const dictation = document.getElementById("oa-dictation-label");
    if (dictation) dictation.textContent = ${JSON.stringify(dictationLabel)};
    const activity = document.getElementById("oa-activity");
    if (activity) activity.innerHTML = ${JSON.stringify(activityHTML)};
    const transcript = document.getElementById("oa-transcript-detail");
    if (transcript) transcript.textContent = ${JSON.stringify(transcriptDetail)};
    const assistant = document.getElementById("oa-assistant-detail");
    if (assistant) {
      assistant.textContent = ${JSON.stringify(assistantDetail)};
      assistant.style.display = ${JSON.stringify(assistantDetail)} ? "" : "none";
    }
    if (typeof window.__oaTickElapsed === "function") window.__oaTickElapsed();
  })();`;
}

function refreshMenuBarPopoverDynamicState() {
  const window = menuBarPopoverWindow;
  if (!window || window.isDestroyed() || !menuBarPopoverContentReady) return;
  window.webContents.executeJavaScript(menuBarPopoverDynamicScript()).catch(() => {});
}

function menuBarPopoverHTML() {
  const dictationLabel = pendingVoiceHUDPayload?.status === "listening" ? "Stop Dictation" : "Start Dictation";
  const popoverAppearance = menuBarPopoverAppearance();
  const popoverTheme = popoverAppearance.mode;
  const logoDataURL = assetDataURL("assets/AppLogo.png", "image/png");
  const appVersion = app.getVersion();
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<style>
  :root {
    color-scheme: ${popoverTheme};
    --menu-accent: ${popoverAppearance.accent};
    --menu-skill: ${popoverAppearance.skill};
    --menu-bg: ${popoverAppearance.background};
    --menu-fg: ${popoverAppearance.foreground};
  }
  html, body {
    width: 100%;
    margin: 0;
    overflow: hidden;
    background: transparent;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", sans-serif;
    letter-spacing: 0;
  }
  * { box-sizing: border-box; user-select: none; }
  button { font: inherit; color: inherit; border: 0; background: none; text-align: left; }
  .popover {
    position: relative;
    width: 100%;
    padding: 8px;
    color: color-mix(in srgb, var(--menu-fg) 94%, white 6%);
    background:
      linear-gradient(180deg, color-mix(in srgb, white 8%, transparent), color-mix(in srgb, white 2%, transparent) 46%),
      radial-gradient(130% 64% at 14% -10%, color-mix(in srgb, var(--menu-accent) 11%, transparent), transparent 58%),
      radial-gradient(120% 76% at 102% 8%, color-mix(in srgb, var(--menu-skill) 6%, transparent), transparent 60%),
      color-mix(in srgb, var(--menu-bg) 78%, transparent);
    border: 0.5px solid color-mix(in srgb, white 20%, transparent);
    border-radius: 18px;
    box-shadow:
      0 20px 52px rgba(0, 0, 0, 0.36),
      0 2px 6px rgba(0, 0, 0, 0.22),
      inset 0 1px 0 color-mix(in srgb, white 22%, transparent),
      inset 0 -0.5px 0 color-mix(in srgb, white 6%, transparent);
    backdrop-filter: blur(40px) saturate(1.85);
    -webkit-backdrop-filter: blur(40px) saturate(1.85);
  }
  .popover::before {
    position: absolute;
    inset: 0;
    border-radius: inherit;
    pointer-events: none;
    background: linear-gradient(168deg, color-mix(in srgb, white 6%, transparent), transparent 40%);
    content: "";
  }
  .inner { position: relative; z-index: 1; }
  .header {
    display: grid;
    grid-template-columns: 36px 1fr;
    align-items: center;
    gap: 11px;
    padding: 9px 10px 11px;
  }
  .header-copy { min-width: 0; }
  .logo {
    width: 36px;
    height: 36px;
    display: grid;
    place-items: center;
    border-radius: 10px;
    overflow: hidden;
    border: 0.5px solid color-mix(in srgb, white 26%, transparent);
    color: color-mix(in srgb, var(--menu-accent) 88%, white 12%);
    box-shadow:
      0 5px 14px rgba(0, 0, 0, 0.30),
      inset 0 0.5px 0 color-mix(in srgb, white 28%, transparent);
  }
  .logo img { width: 100%; height: 100%; display: block; object-fit: cover; }
  .logo svg { width: 21px; height: 21px; }
  .title {
    margin: 0;
    font-size: 14px;
    line-height: 1.1;
    font-weight: 650;
    letter-spacing: -0.1px;
    color: color-mix(in srgb, var(--menu-fg) 95%, white 5%);
  }
  .status-line { margin-top: 4px; }
  .status-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    max-width: 100%;
    padding: 2.5px 9px 2.5px 7px;
    border-radius: 999px;
    background: color-mix(in srgb, var(--menu-fg) 7%, transparent);
    box-shadow: inset 0 0 0 0.5px color-mix(in srgb, var(--menu-fg) 11%, transparent);
    color: color-mix(in srgb, var(--menu-fg) 74%, transparent);
    font-size: 10.5px;
    font-weight: 600;
  }
  .status-pill span:last-child {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .status-dot {
    flex: 0 0 auto;
    width: 6px;
    height: 6px;
    border-radius: 999px;
    background: #34c759;
    box-shadow: 0 0 6px rgba(52, 199, 89, 0.72);
  }
  .status-pill[data-tone="busy"] .status-dot {
    background: color-mix(in srgb, var(--menu-accent) 92%, white 8%);
    box-shadow: 0 0 7px color-mix(in srgb, var(--menu-accent) 66%, transparent);
    animation: statusPulse 1.4s ease-in-out infinite;
  }
  .status-pill[data-tone="attention"] .status-dot {
    background: #ff9f0a;
    box-shadow: 0 0 6px rgba(255, 159, 10, 0.72);
  }
  @keyframes statusPulse {
    0%, 100% { opacity: 1; transform: scale(1); }
    50% { opacity: 0.45; transform: scale(0.78); }
  }
  #oa-activity {
    display: grid;
    gap: 6px;
    margin: 0 8px 10px;
  }
  #oa-activity:empty { display: none; margin: 0; }
  .activity-card {
    display: grid;
    grid-template-columns: 24px minmax(0, 1fr);
    align-items: center;
    gap: 11px;
    width: 100%;
    padding: 9px 12px;
    border-radius: 11px;
    background:
      linear-gradient(180deg, rgba(255,255,255,0.070), rgba(255,255,255,0.014)),
      rgba(229, 67, 54, 0.070);
    box-shadow:
      inset 0 0 0 0.5px rgba(229, 67, 54, 0.18),
      inset 0 0.5px 0 rgba(255, 255, 255, 0.08);
  }
  .activity-card.working {
    background:
      linear-gradient(180deg, rgba(255,255,255,0.060), rgba(255,255,255,0.012)),
      color-mix(in srgb, var(--menu-accent) 9%, transparent);
    box-shadow:
      inset 0 0 0 0.5px color-mix(in srgb, var(--menu-accent) 22%, transparent),
      inset 0 0.5px 0 rgba(255, 255, 255, 0.08);
  }
  button.activity-card.working:hover {
    background:
      linear-gradient(180deg, rgba(255,255,255,0.075), rgba(255,255,255,0.02)),
      color-mix(in srgb, var(--menu-accent) 14%, transparent);
  }
  .activity-card.working .activity-label { color: color-mix(in srgb, var(--menu-fg) 92%, white 8%); }
  .activity-card.working .activity-detail { color: color-mix(in srgb, var(--menu-accent) 62%, var(--menu-fg) 24%); }
  .activity-more {
    padding: 0 4px;
    color: color-mix(in srgb, var(--menu-fg) 46%, transparent);
    font-size: 10px;
    font-weight: 560;
  }
  .oa-elapsed { font-variant-numeric: tabular-nums; }
  .recording-dot {
    position: relative;
    width: 24px;
    height: 24px;
    flex: 0 0 auto;
  }
  .recording-dot::before {
    position: absolute;
    inset: 2px;
    border-radius: 999px;
    background: rgba(239, 77, 62, 0.22);
    animation: recordingPulse 1.5s ease-out infinite;
    content: "";
  }
  .recording-dot::after {
    position: absolute;
    top: 8px;
    left: 8px;
    width: 8px;
    height: 8px;
    border-radius: 999px;
    background: rgb(241, 78, 62);
    content: "";
  }
  .activity-text {
    display: grid;
    gap: 5px;
    min-width: 0;
  }
  .activity-label {
    color: rgb(241, 91, 74);
    font-size: 13px;
    font-weight: 650;
    line-height: 1.1;
  }
  .activity-detail {
    max-width: 214px;
    overflow: hidden;
    color: rgba(242, 211, 205, 0.64);
    font-size: 10.5px;
    font-weight: 540;
    line-height: 1.2;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .finalizing-spinner {
    width: 19px;
    height: 19px;
    flex: 0 0 auto;
    border-radius: 999px;
    border: 2px solid color-mix(in srgb, var(--menu-accent) 24%, transparent);
    border-top-color: color-mix(in srgb, var(--menu-accent) 94%, white 6%);
    animation: spin 820ms linear infinite;
  }
  .activity-card.finalizing {
    background:
      linear-gradient(180deg, rgba(255,255,255,0.055), rgba(255,255,255,0.012)),
      color-mix(in srgb, var(--menu-accent) 10%, transparent);
    box-shadow: inset 0 0 0 0.5px color-mix(in srgb, var(--menu-accent) 18%, transparent);
  }
  .activity-card.finalizing .activity-label { color: color-mix(in srgb, var(--menu-accent) 82%, white 18%); }
  @keyframes recordingPulse {
    from { transform: scale(0.72); opacity: 1; }
    to { transform: scale(1.42); opacity: 0; }
  }
  @keyframes spin {
    to { transform: rotate(360deg); }
  }
  .section-title {
    margin: 8px 0 3px;
    padding: 0 10px;
    color: color-mix(in srgb, var(--menu-fg) 46%, transparent);
    font-size: 10px;
    font-weight: 650;
    letter-spacing: 0.55px;
    text-transform: uppercase;
  }
  .menu-row {
    width: 100%;
    min-height: 36px;
    display: grid;
    grid-template-columns: 24px minmax(0, 1fr) auto;
    align-items: center;
    gap: 10px;
    padding: 7px 10px;
    border-radius: 9px;
    transition: background 80ms ease;
  }
  .menu-row:hover {
    background: color-mix(in srgb, var(--menu-accent) 14%, transparent);
    box-shadow: inset 0 0 0 0.5px color-mix(in srgb, var(--menu-accent) 12%, transparent);
  }
  .menu-row:active { background: color-mix(in srgb, var(--menu-accent) 20%, transparent); }
  .menu-icon {
    width: 24px;
    height: 24px;
    display: grid;
    place-items: center;
    border-radius: 7px;
    color: color-mix(in srgb, var(--menu-accent) 90%, white 10%);
    background:
      linear-gradient(180deg, color-mix(in srgb, white 8%, transparent), color-mix(in srgb, white 1%, transparent)),
      color-mix(in srgb, var(--menu-accent) 20%, transparent);
    box-shadow:
      inset 0 0 0 0.5px color-mix(in srgb, var(--menu-fg) 9%, transparent),
      inset 0 0.5px 0 color-mix(in srgb, white 14%, transparent);
  }
  .tone-ai { color: color-mix(in srgb, var(--menu-accent) 82%, white 18%); background-color: color-mix(in srgb, var(--menu-accent) 24%, transparent); }
  .tone-accent { color: color-mix(in srgb, var(--menu-accent) 92%, white 8%); background-color: color-mix(in srgb, var(--menu-accent) 22%, transparent); }
  .tone-history { color: color-mix(in srgb, var(--menu-skill) 82%, white 18%); background-color: color-mix(in srgb, var(--menu-skill) 20%, transparent); }
  .tone-settings { color: color-mix(in srgb, var(--menu-accent) 86%, white 14%); background-color: color-mix(in srgb, var(--menu-accent) 19%, transparent); }
  .tone-neutral { color: color-mix(in srgb, var(--menu-fg) 72%, transparent); background-color: color-mix(in srgb, var(--menu-fg) 7%, transparent); }
  .menu-icon svg { width: 12.5px; height: 12.5px; stroke-width: 2; }
  .row-text {
    display: grid;
    gap: 1px;
    min-width: 0;
  }
  .row-label {
    color: color-mix(in srgb, var(--menu-fg) 91%, white 9%);
    font-size: 13px;
    font-weight: 560;
    line-height: 1.16;
  }
  .row-detail {
    max-width: 208px;
    overflow: hidden;
    color: color-mix(in srgb, var(--menu-fg) 48%, transparent);
    font-size: 10px;
    font-weight: 520;
    line-height: 1.25;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .shortcut {
    color: color-mix(in srgb, var(--menu-fg) 52%, transparent);
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 10.5px;
    font-weight: 450;
  }
  .row-spacer { height: 1px; margin: 7px 10px; background: color-mix(in srgb, var(--menu-fg) 9%, transparent); }
  .footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-top: 7px;
    padding: 8px 10px 3px;
    border-top: 0.5px solid color-mix(in srgb, var(--menu-fg) 10%, transparent);
  }
  .footer-note {
    overflow: hidden;
    color: color-mix(in srgb, var(--menu-fg) 42%, transparent);
    font-size: 10px;
    font-weight: 540;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .quit-button {
    flex: 0 0 auto;
    padding: 4px 11px;
    border-radius: 7px;
    background: color-mix(in srgb, var(--menu-fg) 6%, transparent);
    box-shadow: inset 0 0 0 0.5px color-mix(in srgb, var(--menu-fg) 10%, transparent);
    color: color-mix(in srgb, var(--menu-fg) 72%, transparent);
    font-size: 11px;
    font-weight: 580;
    transition: background 80ms ease, color 80ms ease;
  }
  .quit-button:hover {
    background: rgba(255, 69, 58, 0.16);
    box-shadow: inset 0 0 0 0.5px rgba(255, 69, 58, 0.30);
    color: #ff6f64;
  }
  body[data-theme="light"] .popover {
    color: color-mix(in srgb, var(--menu-fg) 94%, black 6%);
    background:
      linear-gradient(180deg, rgba(255,255,255,0.72), rgba(255,255,255,0.30) 54%),
      radial-gradient(110% 90% at 6% 0%, color-mix(in srgb, var(--menu-accent) 14%, transparent), transparent 62%),
      radial-gradient(94% 90% at 100% 18%, color-mix(in srgb, var(--menu-skill) 9%, transparent), transparent 66%),
      color-mix(in srgb, var(--menu-bg) 66%, transparent);
    border-color: rgba(44, 56, 74, 0.16);
    box-shadow:
      0 22px 48px rgba(48, 60, 78, 0.22),
      0 2px 6px rgba(48, 60, 78, 0.12),
      inset 0 1px 0 rgba(255, 255, 255, 0.80);
  }
  body[data-theme="light"] .popover::before { background: linear-gradient(168deg, rgba(255,255,255,0.35), transparent 42%); }
  body[data-theme="light"] .title { color: color-mix(in srgb, var(--menu-fg) 94%, black 6%); }
  body[data-theme="light"] .logo { border-color: rgba(44, 56, 74, 0.14); box-shadow: 0 4px 12px rgba(48, 60, 78, 0.18); }
  body[data-theme="light"] .status-pill {
    background: rgba(44, 56, 74, 0.06);
    box-shadow: inset 0 0 0 0.5px rgba(44, 56, 74, 0.12);
    color: color-mix(in srgb, var(--menu-fg) 70%, transparent);
  }
  body[data-theme="light"] .section-title,
  body[data-theme="light"] .shortcut,
  body[data-theme="light"] .footer-note {
    color: color-mix(in srgb, var(--menu-fg) 60%, transparent);
  }
  body[data-theme="light"] .row-spacer { background: color-mix(in srgb, var(--menu-fg) 13%, transparent); }
  body[data-theme="light"] .footer { border-top-color: color-mix(in srgb, var(--menu-fg) 13%, transparent); }
  body[data-theme="light"] .activity-card {
    background:
      linear-gradient(180deg, rgba(255,255,255,0.66), rgba(255,255,255,0.14)),
      rgba(229, 67, 54, 0.080);
    box-shadow: inset 0 0 0 0.5px rgba(176, 55, 43, 0.16);
  }
  body[data-theme="light"] .activity-card.finalizing,
  body[data-theme="light"] .activity-card.working {
    background:
      linear-gradient(180deg, rgba(255,255,255,0.66), rgba(255,255,255,0.14)),
      color-mix(in srgb, var(--menu-accent) 11%, transparent);
    box-shadow: inset 0 0 0 0.5px color-mix(in srgb, var(--menu-accent) 16%, transparent);
  }
  body[data-theme="light"] .activity-card.working .activity-label { color: color-mix(in srgb, var(--menu-fg) 92%, black 8%); }
  body[data-theme="light"] .activity-card.working .activity-detail { color: color-mix(in srgb, var(--menu-accent) 64%, var(--menu-fg) 26%); }
  body[data-theme="light"] .menu-row:hover { background: color-mix(in srgb, var(--menu-accent) 9%, transparent); }
  body[data-theme="light"] .menu-icon {
    color: color-mix(in srgb, var(--menu-accent) 82%, black 18%);
    background: color-mix(in srgb, var(--menu-accent) 16%, transparent);
  }
  body[data-theme="light"] .tone-ai { color: color-mix(in srgb, var(--menu-accent) 80%, black 20%); background-color: color-mix(in srgb, var(--menu-accent) 15%, transparent); }
  body[data-theme="light"] .tone-neutral { color: color-mix(in srgb, var(--menu-fg) 70%, transparent); background-color: color-mix(in srgb, var(--menu-fg) 7%, transparent); }
  body[data-theme="light"] .row-label { color: color-mix(in srgb, var(--menu-fg) 92%, black 8%); }
  body[data-theme="light"] .row-detail { color: color-mix(in srgb, var(--menu-fg) 52%, transparent); }
  body[data-theme="light"] .quit-button {
    background: rgba(44, 56, 74, 0.06);
    box-shadow: inset 0 0 0 0.5px rgba(44, 56, 74, 0.12);
    color: color-mix(in srgb, var(--menu-fg) 72%, transparent);
  }
  body[data-theme="light"] .quit-button:hover {
    background: rgba(215, 45, 35, 0.10);
    box-shadow: inset 0 0 0 0.5px rgba(215, 45, 35, 0.28);
    color: #c93028;
  }
</style>
</head>
<body data-theme="${popoverTheme}">
  <main class="popover">
    <div class="inner">
      <header class="header">
        <div class="logo">
          ${logoDataURL ? `<img src="${logoDataURL}" alt="" />` : `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M6 8h12a3 3 0 0 1 3 3v4a3 3 0 0 1-3 3h-5l-4 3v-3H6a3 3 0 0 1-3-3v-4a3 3 0 0 1 3-3Z"/><path d="M8 12h.01M12 12h.01M16 12h.01"/></svg>`}
        </div>
        <div class="header-copy">
          <h1 class="title">Open Assist</h1>
          <div class="status-line">
            <span class="status-pill" id="oa-status-pill" data-tone="${menuBarHeaderStatusTone()}">
              <span class="status-dot" aria-hidden="true"></span>
              <span id="oa-status-label">${escapeHTML(menuBarHeaderStatusLabel())}</span>
            </span>
          </div>
        </div>
      </header>
      <div id="oa-activity">${menuBarActivityHTML()}</div>
      <section>
        <div class="section-title">Assistant</div>
        ${menuBarRow("open-assistant", "Open Assistant", menuBarAssistantRowDetail(), "sparkles", "", "ai", "", "oa-assistant-detail")}
        ${menuBarRow("new-chat", "New Chat", "", "plus", "", "accent")}
        ${menuBarRow("speak-assistant-task", "Speak a Task", "", "wave", "", "accent")}
      </section>
      <div class="row-spacer"></div>
      <section>
        <div class="section-title">Voice & Dictation</div>
        ${menuBarRow("toggle-dictation", dictationLabel, "", "mic", "", "accent", "oa-dictation-label")}
        ${menuBarRow("paste-last-transcript", "Paste Last Transcript", menuBarLastTranscriptDetail(), "clipboard", "⌘⌥V", "accent", "", "oa-transcript-detail")}
      </section>
      <div class="row-spacer"></div>
      <section>
        <div class="section-title">Go To</div>
        ${menuBarRow("open-today", "Today's Planner", "", "calendar", "", "history")}
        ${menuBarRow("open-history", "Dictation History", "", "history", "", "history")}
        ${menuBarRow("open-models", "Models & Connections", "", "brain", "", "ai")}
        ${menuBarRow("open-settings", "Settings", "", "gear", "⌘,", "settings")}
      </section>
      <footer class="footer">
        <span class="footer-note">Open Assist · v${escapeHTML(appVersion)}</span>
        <button class="quit-button" data-action="quit">Quit</button>
      </footer>
    </div>
  </main>
  <script>
    document.addEventListener("click", (event) => {
      const button = event.target.closest("[data-action]");
      if (!button || !window.openAssistElectron) return;
      window.openAssistElectron.menuBarAction(button.dataset.action);
    });
    // Live "elapsed" counters for running assistant tasks.
    window.__oaTickElapsed = () => {
      const now = Date.now();
      document.querySelectorAll(".oa-elapsed").forEach((node) => {
        const started = Number(node.dataset.startedAt || 0);
        if (!Number.isFinite(started) || started <= 0) { node.textContent = ""; return; }
        const total = Math.max(0, Math.floor((now - started) / 1000));
        const hours = Math.floor(total / 3600);
        const minutes = Math.floor((total % 3600) / 60);
        const seconds = total % 60;
        node.textContent = " · " + (hours ? hours + "h " + minutes + "m" : minutes ? minutes + "m " + seconds + "s" : seconds + "s");
      });
    };
    setInterval(window.__oaTickElapsed, 1000);
    window.__oaTickElapsed();
    // The card hugs its content; tell the main process the real height so the
    // window can shrink/grow with it.
    const oaCard = document.querySelector(".popover");
    const oaReportHeight = () => {
      if (!oaCard || !window.openAssistElectron || typeof window.openAssistElectron.menuBarReportHeight !== "function") return;
      window.openAssistElectron.menuBarReportHeight(Math.ceil(oaCard.getBoundingClientRect().height));
    };
    if (oaCard && typeof ResizeObserver === "function") {
      new ResizeObserver(oaReportHeight).observe(oaCard);
    }
    oaReportHeight();
  </script>
</body>
</html>`;
}

function menuBarActivityHTML() {
  const cards: string[] = [];
  if (menuBarVoiceStatus === "listening") {
    const detail = menuBarActivityDetail();
    const label = pendingVoiceHUDPayload?.status === "live-listening" ? "Live Voice listening" : "Listening…";
    cards.push(`<div class="activity-card recording">
      <span class="recording-dot" aria-hidden="true"></span>
      <span class="activity-text">
        <span class="activity-label">${escapeHTML(label)}</span>
        ${detail ? `<span class="activity-detail">${escapeHTML(detail)}</span>` : ""}
      </span>
    </div>`);
  } else if (
    menuBarVoiceStatus === "processing"
    || menuBarVoiceStatus === "connecting"
    || menuBarVoiceStatus === "speaking"
    || menuBarVoiceStatus === "delegating"
  ) {
    const detail = menuBarActivityDetail();
    cards.push(`<div class="activity-card finalizing">
      <span class="finalizing-spinner" aria-hidden="true"></span>
      <span class="activity-text">
        <span class="activity-label">${escapeHTML(menuBarHeaderStatusLabel())}</span>
        ${detail ? `<span class="activity-detail">${escapeHTML(detail)}</span>` : ""}
      </span>
    </div>`);
  }
  // One card per running assistant task, reported live by the renderer.
  // Clicking a card jumps into the app.
  const runs = menuBarAppState.runs;
  for (const run of runs.slice(0, 3)) {
    const status = run.statusText || (run.provider ? `${run.provider} is working` : "Working");
    cards.push(`<button class="activity-card working" data-action="open-assistant">
      <span class="finalizing-spinner" aria-hidden="true"></span>
      <span class="activity-text">
        <span class="activity-label">${escapeHTML(run.title)}</span>
        <span class="activity-detail">${escapeHTML(status)}<span class="oa-elapsed" data-started-at="${Math.round(run.startedAt)}"></span></span>
      </span>
    </button>`);
  }
  if (runs.length > 3) {
    cards.push(`<div class="activity-more">+${runs.length - 3} more running</div>`);
  }
  return cards.join("");
}

function menuBarIconSVG(name: "sparkles" | "plus" | "wave" | "mic" | "clipboard" | "history" | "calendar" | "brain" | "gear" | "power") {
  switch (name) {
    case "plus":
      return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M12 5v14"/><path d="M5 12h14"/></svg>';
    case "calendar":
      return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M8 3v4"/><path d="M16 3v4"/><path d="M3 10h18"/><path d="M8 15h.01M12 15h.01M16 15h.01"/></svg>';
    case "sparkles":
      return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="m12 3 1.7 4.3L18 9l-4.3 1.7L12 15l-1.7-4.3L6 9l4.3-1.7L12 3Z"/><path d="M19 14l.9 2.1L22 17l-2.1.9L19 20l-.9-2.1L16 17l2.1-.9L19 14Z"/></svg>';
    case "wave":
      return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M4 12v3"/><path d="M8 7v10"/><path d="M12 5v14"/><path d="M16 8v8"/><path d="M20 11v2"/></svg>';
    case "mic":
      return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0"/><path d="M12 18v3"/></svg>';
    case "clipboard":
      return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><rect x="8" y="4" width="10" height="16" rx="2"/><path d="M6 8H5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8"/><path d="M10 4h6"/></svg>';
    case "history":
      return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M3 12a9 9 0 1 0 3-6.7"/><path d="M3 4v6h6"/><path d="M12 7v6l4 2"/></svg>';
    case "brain":
      return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M9 4a3 3 0 0 0-3 3v1a4 4 0 0 0 0 8v1a3 3 0 0 0 5 2"/><path d="M15 4a3 3 0 0 1 3 3v1a4 4 0 0 1 0 8v1a3 3 0 0 1-5 2"/><path d="M12 5v14"/></svg>';
    case "gear":
      return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2 3-.2-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.5V21h-3.4v-.2a1.7 1.7 0 0 0-1-1.5 1.7 1.7 0 0 0-1.9.3l-.2.1-2-3 .1-.1A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-1.5-1H3v-4h.2a1.7 1.7 0 0 0 1.5-1 1.7 1.7 0 0 0-.3-1.9l-.1-.1 2-3 .2.1a1.7 1.7 0 0 0 1.9.3 1.7 1.7 0 0 0 1-1.5V3h3.4v.2a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.9-.3l.2-.1 2 3-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.5 1h.2v4H21a1.7 1.7 0 0 0-1.6 1Z"/></svg>';
    case "power":
      return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.8 0"/></svg>';
  }
}

type MenuBarIconTone = "accent" | "ai" | "history" | "settings" | "neutral";

function menuBarRow(
  action: MenuBarAction,
  label: string,
  detail: string,
  icon: Parameters<typeof menuBarIconSVG>[0],
  shortcut = "",
  tone: MenuBarIconTone = "accent",
  labelId = "",
  detailId = ""
) {
  const labelIdAttr = labelId ? ` id="${labelId}"` : "";
  // A row with a detailId keeps its detail span in the DOM even when empty, so
  // the dynamic refresh script can fill it in later without a full reload.
  const detailSpan = detailId
    ? `<span class="row-detail" id="${detailId}"${detail ? "" : ' style="display:none"'}>${escapeHTML(detail)}</span>`
    : detail
      ? `<span class="row-detail">${escapeHTML(detail)}</span>`
      : "";
  return `<button class="menu-row" data-action="${action}">
    <span class="menu-icon tone-${tone}">${menuBarIconSVG(icon)}</span>
    <span class="row-text"><span class="row-label"${labelIdAttr}>${escapeHTML(label)}</span>${detailSpan}</span>
    ${shortcut ? `<span class="shortcut">${escapeHTML(shortcut)}</span>` : ""}
  </button>`;
}

function positionMenuBarPopoverWindow(window: BrowserWindow) {
  const bounds = menuBarTray?.getBounds();
  if (!bounds) return;
  const size = { width: menuBarPopoverSize.width, height: menuBarPopoverContentHeight || menuBarPopoverSize.height };
  const display = screen.getDisplayNearestPoint({ x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 });
  const workArea = display.workArea;
  const x = Math.round(Math.max(workArea.x + 8, Math.min(bounds.x + bounds.width / 2 - size.width / 2, workArea.x + workArea.width - size.width - 8)));
  const belowY = Math.round(bounds.y + bounds.height + 8);
  const aboveY = Math.round(bounds.y - size.height - 8);
  const y = belowY + size.height <= workArea.y + workArea.height ? belowY : Math.max(workArea.y + 8, aboveY);
  window.setBounds({ x, y, ...size }, false);
}

function clearMenuBarPopoverBlurTimer() {
  if (!menuBarPopoverBlurTimer) return;
  clearTimeout(menuBarPopoverBlurTimer);
  menuBarPopoverBlurTimer = null;
}

function hideMenuBarPopover(reason: string) {
  const window = menuBarPopoverWindow;
  if (!window || window.isDestroyed() || !window.isVisible()) return;
  debugLog(`hide menu bar popover reason=${reason}`);
  clearMenuBarPopoverBlurTimer();
  window.hide();
}

function scheduleMenuBarPopoverBlurHide(reason: string) {
  clearMenuBarPopoverBlurTimer();
  menuBarPopoverBlurTimer = setTimeout(() => {
    menuBarPopoverBlurTimer = null;
    const window = menuBarPopoverWindow;
    if (!window || window.isDestroyed() || !window.isVisible()) return;
    if (Date.now() - menuBarPopoverShownAt < 220) return;
    hideMenuBarPopover(reason);
  }, 90);
}

// Loads (or reloads) the popover document. We keep the window alive and only
// reload when the theme/appearance actually changes, so opening the popover is
// instant in the common case.
function loadMenuBarPopoverContent(window: BrowserWindow) {
  const html = menuBarPopoverHTML();
  menuBarPopoverContentReady = false;
  menuBarPopoverAppearanceSignature = menuBarPopoverAppearanceSignatureValue();
  window.loadURL(`data:text/html;base64,${Buffer.from(html).toString("base64")}`);
}

function ensureMenuBarPopoverWindow() {
  if (menuBarPopoverWindow && !menuBarPopoverWindow.isDestroyed()) return menuBarPopoverWindow;
  const window = new BrowserWindow({
    width: menuBarPopoverSize.width,
    height: menuBarPopoverSize.height,
    show: false,
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    fullscreenable: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    focusable: true,
    hasShadow: false,
    visualEffectState: "active",
    vibrancy: process.platform === "darwin" ? "popover" : undefined,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      devTools: enableDevTools,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: false
    }
  });
  window.on("focus", clearMenuBarPopoverBlurTimer);
  window.on("blur", () => scheduleMenuBarPopoverBlurHide("blur"));
  window.on("hide", clearMenuBarPopoverBlurTimer);
  window.webContents.on("before-input-event", (_event, input) => {
    if (input.type === "keyDown" && input.key === "Escape") hideMenuBarPopover("escape");
  });
  window.webContents.on("did-finish-load", () => {
    menuBarPopoverContentReady = true;
    refreshMenuBarPopoverDynamicState();
    warmMenuBarPopoverCompositor(window);
  });
  window.on("closed", () => {
    clearMenuBarPopoverBlurTimer();
    menuBarPopoverContentReady = false;
    menuBarPopoverWarmed = false;
    if (menuBarPopoverWindow === window) menuBarPopoverWindow = null;
  });
  menuBarPopoverWindow = window;
  loadMenuBarPopoverContent(window);
  return window;
}

// macOS only allocates and composites a transparent/vibrancy window's surface on
// its first show, which is the main source of the open lag. Show it once well
// offscreen (no focus, no flash) and immediately hide it so the real first click
// reveals an already-composited window instantly.
function warmMenuBarPopoverCompositor(window: BrowserWindow) {
  if (menuBarPopoverWarmed || window.isDestroyed() || window.isVisible()) return;
  menuBarPopoverWarmed = true;
  try {
    window.setBounds({ x: -32000, y: -32000, ...menuBarPopoverSize }, false);
    window.showInactive();
    setTimeout(() => {
      if (!window.isDestroyed() && !window.isVisible()) return;
      if (!window.isDestroyed()) window.hide();
    }, 60);
  } catch {
    // Non-fatal: if warming fails the first real show just pays the usual cost.
  }
}

// Pre-create and pre-load the popover during startup so the very first click
// is instant instead of paying for window creation + document load.
function prewarmMenuBarPopover() {
  ensureMenuBarPopoverWindow();
}

function showMenuBarPopover() {
  const window = ensureMenuBarPopoverWindow();
  // If the theme changed since we last loaded, refresh the whole document.
  if (menuBarPopoverContentReady && menuBarPopoverAppearanceSignature !== menuBarPopoverAppearanceSignatureValue()) {
    loadMenuBarPopoverContent(window);
  }
  const reveal = () => {
    if (window.isDestroyed()) return;
    menuBarPopoverShownAt = Date.now();
    positionMenuBarPopoverWindow(window);
    window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
    window.show();
    // The popover must become the key window, otherwise macOS never fires the
    // "blur" event when the user clicks another app/the desktop and it would
    // stay open. For an accessory (menu-bar) app, focusing the window is not
    // enough on its own, so we also steal app focus on macOS.
    if (process.platform === "darwin") {
      app.focus({ steal: true });
    }
    window.focus();
    // Refresh dynamic text after showing; executeJavaScript is async so it never
    // delays the window appearing.
    refreshMenuBarPopoverDynamicState();
  };
  if (menuBarPopoverContentReady) {
    reveal();
    return;
  }
  // First load not finished yet: reveal as soon as it is (with a short fallback).
  window.webContents.once("did-finish-load", reveal);
  setTimeout(() => {
    if (!window.isDestroyed() && !window.isVisible()) reveal();
  }, 200);
}

function toggleMenuBarPopover() {
  const window = ensureMenuBarPopoverWindow();
  if (window.isVisible()) {
    if (Date.now() - menuBarPopoverShownAt < 450) return;
    hideMenuBarPopover("tray toggle");
    return;
  }
  showMenuBarPopover();
}

function showMainWindowFromMenuBar(command?: MenuBarCommand, visible = true) {
  const window = mainWindow ?? createMainWindow({ initiallyHidden: !visible });
  if (visible) {
    ensureRegularDockPresence("show main window from menu bar");
    if (window.isMinimized()) window.restore();
    window.show();
    window.focus();
  }
  if (command) {
    const send = () => {
      safeSendWindow(window, "openassist:menu-bar-command", command);
    };
    if (window.webContents.isLoading()) {
      window.webContents.once("did-finish-load", () => setTimeout(send, 20));
    } else {
      setTimeout(send, 20);
    }
  }
  return window;
}

async function handleMenuBarAction(action: MenuBarAction) {
  hideMenuBarPopover(`action ${action}`);
  if (action === "quit") {
    isQuitting = true;
    app.quit();
    return { ok: true };
  }
  if (action === "paste-last-transcript") {
    const result = await pasteTranscriptHistoryEntry();
    if (!result.ok) {
      await updateVoiceHUD({ visible: true, status: "message", text: result.error ?? "No transcript in Open Assist History", tone: "warning" });
    }
    return result;
  }
  if (action === "open-history") {
    return showTranscriptHistoryWindow();
  }
  if (action === "open-settings" || action === "open-models") {
    return showSettingsWindow();
  }
  const shouldShowWindow = action !== "toggle-dictation";
  showMainWindowFromMenuBar(action, shouldShowWindow);
  return { ok: true };
}

async function pasteLastTranscriptFromShortcut() {
  const result = await pasteTranscriptHistoryEntry();
  await updateVoiceHUD({
    visible: true,
    status: "message",
    text: result.ok
      ? result.result === "typed"
        ? "Inserted last transcript by typing."
        : "Pasted last transcript."
      : result.error ?? "No transcript in Open Assist History",
    tone: result.ok ? "success" : "warning"
  });
  return result;
}

function setupMenuBarTray() {
  if (menuBarTray) return;
  menuBarTray = new Tray(menuBarNativeImage("idle", 0, 0));
  menuBarTray.setTitle("");
  menuBarTray.setToolTip("Open Assist");
  menuBarTray.setIgnoreDoubleClickEvents(true);
  menuBarTray.on("click", toggleMenuBarPopover);
  menuBarTray.on("right-click", toggleMenuBarPopover);
  updateMenuBarIcon();
  prewarmMenuBarPopover();
}

function installApplicationMenu() {
  const template: Electron.MenuItemConstructorOptions[] = [
    {
      label: "Open Assist",
      submenu: [
        { role: "about" },
        { type: "separator" },
        { role: "services" },
        { type: "separator" },
        { role: "hide" },
        { role: "hideOthers" },
        { role: "unhide" },
        { type: "separator" },
        { role: "quit" }
      ]
    },
    {
      label: "Edit",
      submenu: [
        { role: "undo" },
        { role: "redo" },
        { type: "separator" },
        { role: "cut" },
        { role: "copy" },
        { role: "paste" },
        { role: "selectAll" }
      ]
    },
	    {
	      label: "View",
	      submenu: [
	        {
	          label: "Show / Hide Assistant",
	          accelerator: "CommandOrControl+Shift+Space",
	          click: () => toggleMainWindowVisibility()
	        },
	        { type: "separator" },
	        ...(showDeveloperMenuItems ? [
	          { role: "reload" as const },
	          { role: "forceReload" as const },
	          { role: "toggleDevTools" as const },
	          { type: "separator" as const }
	        ] : []),
	        { role: "resetZoom" },
	        { role: "zoomIn" },
        { role: "zoomOut" },
        { type: "separator" },
        { role: "togglefullscreen" }
      ]
    },
    {
      label: "Window",
      submenu: [
        { role: "minimize" },
        { role: "zoom" },
        { type: "separator" },
        { role: "front" }
      ]
    },
    {
      label: "Help",
      submenu: []
    }
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function sidebarHandleDisplay(window: BrowserWindow) {
  const handleWidth = 34;
  const bounds = window.getBounds();
  const x = Math.round(
    currentSidebarOpen
      ? currentSidebarEdge === "left"
        ? bounds.x + handleWidth / 2
        : bounds.x + bounds.width - handleWidth / 2
      : currentSidebarEdge === "left"
        ? bounds.x + bounds.width - handleWidth / 2
        : bounds.x + handleWidth / 2
  );
  return screen.getDisplayNearestPoint({
    x,
    y: Math.round(bounds.y + bounds.height / 2)
  });
}

function sidebarTargetDisplay() {
  return screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
}

function stopSidebarScreenFollowTimer() {
  if (!sidebarScreenFollowTimer) return;
  clearInterval(sidebarScreenFollowTimer);
  sidebarScreenFollowTimer = null;
}

function syncSidebarScreenFollowTimer() {
  if (currentWindowMode !== "sidebar" || currentSidebarOpen || sidebarPinnedPreference) {
    stopSidebarScreenFollowTimer();
    return;
  }
  if (sidebarScreenFollowTimer) return;
  sidebarScreenFollowTimer = setInterval(() => {
    const window = mainWindow;
    if (!window || window.isDestroyed() || currentWindowMode !== "sidebar" || currentSidebarOpen || sidebarPinnedPreference) {
      stopSidebarScreenFollowTimer();
      return;
    }
    const targetDisplay = sidebarTargetDisplay();
    const currentDisplay = sidebarHandleDisplay(window);
    if (targetDisplay.id !== currentDisplay.id) {
      applyWindowMode(window, "sidebar", currentSidebarOpen, currentSidebarEdge);
    }
    // 500 ms is imperceptible for "follow the screen the cursor is on" and
    // saves ~4× the wakeups vs the previous 120 ms cadence. The race for
    // very fast cursor moves is fine: applyWindowMode() is idempotent.
  }, 500);
  sidebarScreenFollowTimer.unref?.();
}

function collapseUnpinnedSidebar(reason: string) {
  const window = mainWindow;
  if (
    !window ||
    window.isDestroyed() ||
    currentWindowMode !== "sidebar" ||
    !currentSidebarOpen ||
    sidebarPinnedPreference
  ) {
    return false;
  }
  debugLog(`collapse unpinned sidebar reason=${reason}`);
  currentSidebarOpen = false;
  safeSendWindow(window, "openassist:sidebar-blur-collapse", {
    sidebarOpen: false,
    sidebarEdge: currentSidebarEdge
  });
  setTimeout(() => {
    if (!window.isDestroyed() && currentWindowMode === "sidebar" && !currentSidebarOpen) {
      applyWindowMode(window, "sidebar", false, currentSidebarEdge);
    }
  }, 40);
  return true;
}

function applyWindowMode(
  window: BrowserWindow,
  mode: AssistantWindowMode,
  sidebarOpen = true,
  sidebarEdge: "left" | "right" = "right",
  notchDockRevealed = sidebarOpen
) {
  const previousWindowMode = currentWindowMode;
  const previousSidebarOpen = currentSidebarOpen;
  const previousSidebarEdge = currentSidebarEdge;
  currentWindowMode = mode;
  currentSidebarOpen = mode === "sidebar" || mode === "notch" ? sidebarOpen : true;
  currentNotchDockRevealed = mode === "notch" ? Boolean(sidebarOpen || notchDockRevealed) : false;
  if (mode === "sidebar") currentSidebarEdge = sidebarEdge;
  syncSidebarScreenFollowTimer();
  if (mode === "sidebar") {
    const handleWidth = 34;
    const screenInset = 2;
    const previousSidebarBounds = window.getBounds();
    const previousHandlePoint = {
      x: Math.round(
        previousSidebarOpen
          ? previousSidebarEdge === "left"
            ? previousSidebarBounds.x + handleWidth / 2
            : previousSidebarBounds.x + previousSidebarBounds.width - handleWidth / 2
          : previousSidebarEdge === "left"
            ? previousSidebarBounds.x + previousSidebarBounds.width - handleWidth / 2
            : previousSidebarBounds.x + handleWidth / 2
      ),
      y: Math.round(previousSidebarBounds.y + previousSidebarBounds.height / 2)
    };
    const shouldFollowCurrentScreen = !sidebarPinnedPreference;
    const display = shouldFollowCurrentScreen || previousWindowMode !== "sidebar" || !window.isVisible()
      ? sidebarTargetDisplay()
      : screen.getDisplayNearestPoint(previousHandlePoint);
    const { workArea } = display;
    const handleHeight = 92;
    const minimumPanelHeight = 420;
    const minimumContentWidth = 560;
    const preferredContentWidth = 760;
    const maximumContentWidthFraction = 0.56;
    const availableContentWidth = Math.max(1, workArea.width - screenInset * 2 - handleWidth);
    const desiredContentWidth = Math.min(
      preferredContentWidth,
      Math.max(minimumContentWidth, workArea.width * maximumContentWidthFraction)
    );
    const contentWidth = Math.min(desiredContentWidth, availableContentWidth);
    const openWidth = Math.round(contentWidth + handleWidth);
    const width = sidebarOpen ? openWidth : handleWidth;
    const height = Math.round(sidebarOpen ? Math.max(minimumPanelHeight, workArea.height - screenInset * 2) : handleHeight);
    const y = sidebarOpen
      ? workArea.y + screenInset
      : workArea.y + Math.round((workArea.height - handleHeight) / 2);

    window.setMinimumSize(handleWidth, sidebarOpen ? minimumPanelHeight : handleHeight);
    window.setResizable(false);
    window.setIgnoreMouseEvents(false);
    window.setFocusable(sidebarOpen);
    const keepOnTop = !sidebarOpen || sidebarPinnedPreference;
    window.setAlwaysOnTop(keepOnTop, "floating");
    if (!window.isVisibleOnAllWorkspaces()) {
      window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
    }
    window.setHasShadow(sidebarOpen);
    window.setBackgroundColor("#00000000");
    if (process.platform === "darwin") window.setVibrancy("sidebar");
    if (process.platform === "darwin") window.setWindowButtonVisibility(false);
    const x = sidebarOpen
      ? sidebarEdge === "left"
        ? workArea.x + screenInset
        : workArea.x + workArea.width - screenInset - openWidth
      : sidebarEdge === "left"
        ? workArea.x + screenInset
        : workArea.x + workArea.width - screenInset - handleWidth;
    window.setBounds({
      x: Math.round(x),
      y: Math.round(y),
      width,
      height
    }, false);
    if (sidebarOpen) {
      ensureRegularDockPresence("show sidebar window");
      window.show();
      window.focus();
    } else {
      window.showInactive();
    }
    return;
  }

  if (mode === "notch") {
    stopSidebarScreenFollowTimer();
    const previousBounds = window.getBounds();
    const previousCenter = {
      x: Math.round(previousBounds.x + previousBounds.width / 2),
      y: Math.round(previousBounds.y + Math.min(previousBounds.height / 2, 80))
    };
    const display = previousWindowMode === "notch" && window.isVisible()
      ? screen.getDisplayNearestPoint(previousCenter)
      : sidebarTargetDisplay();
    const { workArea } = display;
    const collapsedSize = { width: 320, height: 50 };
    const hiddenSize = { width: 320, height: 18 };
    const openWidth = Math.min(520, Math.max(320, workArea.width - 32));
    const openHeight = Math.min(480, Math.max(300, workArea.height - 28));
    const isDockRevealed = !sidebarOpen && currentNotchDockRevealed;
    const width = sidebarOpen ? Math.round(openWidth) : isDockRevealed ? collapsedSize.width : hiddenSize.width;
    const height = sidebarOpen ? Math.round(openHeight) : isDockRevealed ? collapsedSize.height : hiddenSize.height;
    const x = workArea.x + Math.round((workArea.width - width) / 2);
    const y = workArea.y + (sidebarOpen || isDockRevealed ? 6 : 0);

    window.setMinimumSize(sidebarOpen ? 520 : 120, sidebarOpen ? 300 : 2);
    window.setResizable(false);
    window.setIgnoreMouseEvents(false);
    window.setFocusable(sidebarOpen);
    window.setAlwaysOnTop(true, "floating");
    if (!window.isVisibleOnAllWorkspaces()) {
      window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
    }
    window.setHasShadow(sidebarOpen || isDockRevealed);
    window.setBackgroundColor("#00000000");
    if (process.platform === "darwin") window.setVibrancy("sidebar");
    if (process.platform === "darwin") window.setWindowButtonVisibility(false);
    window.setBounds({ x, y, width, height }, false);
    if (sidebarOpen) {
      ensureRegularDockPresence("show notch window");
      window.show();
      window.focus();
    } else {
      window.showInactive();
    }
    return;
  }

  window.setFocusable(true);
  window.setIgnoreMouseEvents(false);
  window.setAlwaysOnTop(false);
  if (window.isVisibleOnAllWorkspaces()) {
    window.setVisibleOnAllWorkspaces(false);
  }
  window.setHasShadow(true);
  if (process.platform === "darwin") window.setVibrancy("under-window");
  window.setMinimumSize(940, 620);
  window.setResizable(true);
  if (process.platform === "darwin") window.setWindowButtonVisibility(true);
  window.setBounds({ width: 1220, height: 770 }, true);
  window.center();
  ensureRegularDockPresence("show full window");
  window.show();
  window.focus();
}

function toggleMainWindowVisibility() {
  const window = mainWindow;
  if (!window) {
    ensureRegularDockPresence("toggle created main window");
    createMainWindow();
    return;
  }
  if (!window.isVisible()) {
    ensureRegularDockPresence("toggle show main window");
    window.show();
  }
  safeSendWindow(window, "openassist:toggle-sidebar-shortcut");
}

function voiceHUDHTML() {
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<title>Open Assist Voice HUD</title>
<style>
  html,
  body,
  #root {
    width: 100%;
    height: 100%;
    margin: 0;
    overflow: hidden;
    background: transparent;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Inter", sans-serif;
    pointer-events: auto;
  }
  * {
    box-sizing: border-box;
    user-select: none;
  }
	  .hud {
	    --hud-bg: rgba(26, 26, 30, 0.94);
	    --hud-stroke: transparent;
	    --hud-shadow: rgba(0, 0, 0, 0.35);
	    --hud-dot: #ff3b30;
	    --hud-dot-glow: rgba(255, 59, 48, 0.45);
	    --hud-accent: #7897dc;
	    width: 100%;
	    height: 100%;
	    display: flex;
	    align-items: center;
	    justify-content: center;
	    gap: 6px;
	    padding: 0 7px;
	    color: rgba(245, 247, 250, 0.92);
	    background: var(--hud-bg);
	    border: 0;
	    border-radius: 999px;
	    box-shadow: none;
      position: relative;
      isolation: isolate;
	    backdrop-filter: blur(20px) saturate(1.2);
	    -webkit-backdrop-filter: blur(20px) saturate(1.2);
      transition: all 0.35s cubic-bezier(0.16, 1, 0.3, 1);
	  }
  html[data-chrome-style="classic"] .hud {
    background: linear-gradient(180deg, rgba(42, 43, 48, 0.62), rgba(22, 23, 27, 0.68));
    border-color: rgba(255, 255, 255, 0.14);
    box-shadow: none;
    backdrop-filter: blur(18px) saturate(1.3);
    -webkit-backdrop-filter: blur(18px) saturate(1.3);
  }
  html[data-status="processing"] .hud {
    justify-content: center;
    gap: 0;
    padding: 0;
  }
  html[data-status="toast"] .hud,
  html[data-status="correction"] .hud {
    gap: 7px;
    padding: 0 10px;
  }
  html[data-status="analyzing"] .hud {
    gap: 8px;
    padding: 0 12px;
    justify-content: flex-start;
    border: 1px solid rgba(255, 255, 255, 0.12);
    box-shadow:
      0 0 0 1px rgba(120, 151, 220, 0.24),
      0 0 22px rgba(120, 151, 220, 0.32),
      0 0 34px rgba(255, 122, 143, 0.18),
      0 0 44px rgba(231, 195, 99, 0.12);
    animation: hud-analysis-glow 1.35s ease-in-out infinite;
  }
  html[data-status="analysis-result"] .hud {
    background: rgb(18, 20, 25);
    border: 1px solid rgba(255, 255, 255, 0.14);
    box-shadow: 0 18px 48px rgba(0, 0, 0, 0.56);
    backdrop-filter: none;
    -webkit-backdrop-filter: none;
    border-radius: 16px;
    flex-direction: column;
    align-items: stretch;
    justify-content: flex-start;
    padding: 14px 16px;
    gap: 10px;
    height: 100%;
    width: 100%;
  }
  html[data-status="analyzing-input"] .hud {
    background: rgb(18, 20, 25);
    border: 1px solid rgba(255, 255, 255, 0.14);
    box-shadow: 0 18px 48px rgba(0, 0, 0, 0.56);
    backdrop-filter: none;
    -webkit-backdrop-filter: none;
    border-radius: 16px;
    flex-direction: column;
    align-items: stretch;
    justify-content: flex-start;
    padding: 10px 14px;
    gap: 8px;
    height: 100%;
    width: 100%;
  }
  html[data-chrome-style="liquid-glass"] .hud {
    background:
      linear-gradient(180deg, rgba(255,255,255,0.12), rgba(255,255,255,0.018) 64%),
      radial-gradient(90% 80% at 12% 0%, rgba(120, 151, 220, 0.22), transparent 62%),
      rgba(18, 21, 28, 0.62);
    border: 1px solid rgba(255, 255, 255, 0.14);
    box-shadow:
      inset 0 1px 0 rgba(255, 255, 255, 0.12),
      0 18px 48px rgba(0, 0, 0, 0.26);
    backdrop-filter: blur(24px) saturate(1.22);
    -webkit-backdrop-filter: blur(24px) saturate(1.22);
  }
  html[data-chrome-style="liquid-glass"][data-status="analysis-result"] .hud,
  html[data-chrome-style="liquid-glass"][data-status="analyzing-input"] .hud {
    /* This HUD floats in its own transparent window, so backdrop-filter can't
       blur the app behind it (only same-page content). The frosted look must
       come from opacity: keep it near-opaque like the chat top bar's blur
       band, otherwise the chat text stays readable through the composer. */
    background:
      linear-gradient(180deg, rgba(255,255,255,0.11), rgba(255,255,255,0.020) 64%),
      radial-gradient(110% 90% at 10% 0%, rgba(120, 151, 220, 0.16), transparent 62%),
      rgba(17, 19, 25, 0.96);
    backdrop-filter: blur(28px) saturate(1.18);
    -webkit-backdrop-filter: blur(28px) saturate(1.18);
  }
	  .hud-dot {
	    width: 7px;
	    height: 7px;
	    flex: 0 0 auto;
	    border-radius: 999px;
	    background: radial-gradient(circle at 38% 32%, #ff8076 0%, #ff4438 52%, #e0322a 100%);
	    box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.18);
	    opacity: 1;
	    transition: opacity 220ms ease, transform 260ms ease;
	  }
  html[data-speaking="true"] .hud-dot {
    opacity: 1;
    transform: scale(1.02);
  }
	  .hud-waveform {
	    height: 20px;
	    display: flex;
	    align-items: center;
	    justify-content: center;
	    gap: 2.5px;
	    flex: 0 0 auto;
	    min-width: 0;
	  }
	  .hud-waveform i {
	    width: 3px;
	    height: 3px;
	    flex: 0 0 3px;
	    border-radius: 999px;
	    background: var(--bar-color);
	    opacity: 0.95;
	    will-change: height, opacity;
	  }
  html[data-status="toast"] .hud-dot,
  html[data-status="correction"] .hud-dot {
    width: 7px;
    height: 7px;
    box-shadow: none;
    opacity: 1;
  }
  .hud-spinner {
    width: 12px;
    height: 12px;
    border-radius: 999px;
    border: 1.4px solid rgba(255, 255, 255, 0.14);
    border-top-color: rgba(255, 255, 255, 0.78);
    animation: hud-spin 820ms linear infinite;
    flex-shrink: 0;
  }
  .hud-live-orb {
    width: 40px;
    height: 40px;
    flex: 0 0 40px;
    border-radius: 999px;
    position: relative;
    transform: scale(calc(0.92 + var(--hud-energy, 0) * 0.14));
    transition: transform 90ms ease-out;
  }
  /* Soft Siri-style halo that breathes behind the orb. Colors come from the
     user's selected waveform theme via --orb-c1..c4 (set in JS). */
  .hud-live-orb::before {
    content: "";
    position: absolute;
    inset: -10px;
    border-radius: 999px;
    background: conic-gradient(from 0deg, var(--orb-c1, #6f9dff), var(--orb-c2, #5ee0ae), var(--orb-c3, #e9c76e), var(--orb-c4, #ff8bd2), var(--orb-c1, #6f9dff));
    filter: blur(12px);
    opacity: calc(0.18 + var(--hud-energy, 0) * 0.52);
    transition: opacity 90ms ease-out;
    animation: hud-live-orb-spin 6.5s linear infinite;
  }
  /* Voice energy brightens the orb body as well as the outer halo. */
  .hud-live-orb::after {
    content: "";
    position: absolute;
    inset: 0;
    border-radius: 999px;
    background:
      radial-gradient(circle at 34% 28%, rgba(255, 255, 255, 0.95) 0 14%, transparent 30%),
      conic-gradient(from 215deg, var(--orb-c1, #6f9dff), var(--orb-c2, #5ee0ae), var(--orb-c3, #e9c76e), var(--orb-c4, #ff8bd2), var(--orb-c1, #6f9dff));
    opacity: calc(0.72 + var(--hud-energy, 0) * 0.20);
    box-shadow:
      inset 0 0 0 1px rgba(255, 255, 255, 0.30),
      0 0 calc(6px + var(--hud-energy, 0) * 16px) rgba(111, 157, 255, 0.34);
    transition: opacity 90ms ease-out, box-shadow 90ms ease-out;
  }
  html[data-live-phase="connecting"] .hud-live-orb::before,
  html[data-live-phase="delegating"] .hud-live-orb::before {
    animation-duration: 1.6s;
  }
  html[data-live-phase="speaking"] .hud-live-orb::before {
    animation-duration: 3s;
  }
  /* Live layout: no pill. The orb floats free, the message is its own bubble
     above it, and the controls are a small detached cluster to the right. */
  html[data-status="live"] .hud {
    flex-direction: column;
    /* Anchor the orb row to the bottom: bubbles appear ABOVE it and the orb
       never moves. Centering made the orb jump every time a bubble toggled. */
    justify-content: flex-end;
    align-items: stretch;
    gap: 10px;
    padding: 0 0 6px;
    background: none;
    border: none;
    border-radius: 0;
    box-shadow: none;
    backdrop-filter: none;
    -webkit-backdrop-filter: none;
  }
  .hud-live-main {
    display: grid;
    grid-template-columns: 1fr auto 1fr;
    align-items: center;
    gap: 9px;
    min-width: 0;
    width: 100%;
  }
  .hud-live-spacer {
    justify-self: start;
    /* Mirrors the control cluster width so the orb stays dead-center. */
    width: 62px;
  }
  .hud-live-main .hud-live-controls {
    justify-self: end;
  }
  .hud-live-controls {
    display: flex;
    align-items: center;
    gap: 4px;
    flex: 0 0 auto;
    min-width: 0;
    padding: 3px;
    border-radius: 999px;
    background: rgba(17, 19, 25, 0.90);
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.10);
  }
  .hud-live-control {
    width: 24px;
    height: 24px;
    padding: 0;
    margin: 0;
    line-height: 0;
    border-radius: 999px;
    border: 1px solid rgba(255, 255, 255, 0.13);
    background: rgba(255, 255, 255, 0.06);
    color: rgba(248, 250, 255, 0.82);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    pointer-events: auto;
    -webkit-app-region: no-drag;
  }
  .hud-live-control:hover {
    background: rgba(255, 255, 255, 0.12);
    color: rgba(255, 255, 255, 0.96);
  }
  .hud-live-control.is-muted {
    color: #ffcf70;
    border-color: rgba(255, 207, 112, 0.30);
    background: rgba(255, 207, 112, 0.10);
  }
  .hud-live-control.is-stop {
    color: #ff8b95;
    border-color: rgba(255, 139, 149, 0.24);
  }
  .hud-live-control svg {
    width: 11px;
    height: 11px;
    stroke-width: 2;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
  .hud-live-text {
    flex: 1 1 auto;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 1px;
    padding: 0 2px;
  }
  .hud-live-caption {
    align-self: center;
    max-width: 100%;
    padding: 7px 15px;
    border-radius: 999px;
    background: rgba(17, 19, 25, 0.92);
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.10);
    color: rgba(250, 251, 255, 0.97);
    font-size: 12.5px;
    font-weight: 650;
    letter-spacing: 0.005em;
    line-height: 1.3;
    text-align: center;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  /* No message yet — show just the floating orb, no empty bubble and no
     "Provider listening" filler text. */
  .hud-live-caption.is-empty {
    display: none;
  }
  /* Small professional status chip for agent/tool work — separate from the
     spoken caption so the two never race. */
  .hud-live-work {
    display: none;
    align-self: center;
    align-items: center;
    gap: 6px;
    max-width: 100%;
    padding: 4px 11px;
    border-radius: 999px;
    background: rgba(17, 19, 25, 0.85);
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.08);
    color: rgba(235, 240, 250, 0.74);
    font-size: 10.5px;
    font-weight: 640;
    letter-spacing: 0.015em;
    line-height: 1.25;
  }
  .hud-live-work.is-visible {
    display: inline-flex;
  }
  .hud-live-work-dot {
    width: 5px;
    height: 5px;
    flex: 0 0 5px;
    border-radius: 999px;
    background: var(--orb-c1, #6f9dff);
  }
  .hud-live-work-text {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .hud-live-dictation {
    display: none;
    align-self: center;
    align-items: center;
    gap: 7px;
    padding: 5px 12px;
    border-radius: 999px;
    background: rgba(17, 19, 25, 0.90);
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.10);
  }
  .hud-live-dictation.is-visible {
    display: flex;
  }
  .hud-live-dictation-dot {
    width: 7px;
    height: 7px;
    flex: 0 0 7px;
    border-radius: 999px;
    background: #ff3b30;
    box-shadow: 0 0 calc(4px + var(--hud-dictation-energy, 0) * 10px) rgba(255, 59, 48, 0.55);
    transform: scale(calc(0.90 + var(--hud-dictation-energy, 0) * 0.38));
  }
  .hud-live-dictation-label {
    color: rgba(248, 250, 255, 0.78);
    font-size: 10px;
    font-weight: 720;
    letter-spacing: 0.02em;
    white-space: nowrap;
  }
  .hud-live-meta {
    display: flex;
    align-items: center;
    gap: 5px;
    min-width: 0;
    color: rgba(235, 240, 250, 0.52);
    font-size: 9px;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    line-height: 1.2;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .hud-live-approval {
    display: none;
    width: 100%;
    align-items: center;
    gap: 8px;
    padding: 8px 10px;
    border-radius: 14px;
    background: rgba(17, 19, 25, 0.92);
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.10);
    pointer-events: auto;
    -webkit-app-region: no-drag;
  }
  .hud-live-approval.is-visible {
    display: flex;
  }
  .hud-live-approval-summary {
    flex: 1 1 auto;
    min-width: 0;
    color: rgba(248, 250, 255, 0.90);
    font-size: 11px;
    font-weight: 620;
    line-height: 1.3;
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
  }
  .hud-live-approval button {
    flex: 0 0 auto;
    min-height: 24px;
    padding: 0 11px;
    border: none;
    border-radius: 999px;
    font-size: 10.5px;
    font-weight: 720;
    cursor: pointer;
    pointer-events: auto;
    -webkit-app-region: no-drag;
  }
  .hud-live-approval-approve {
    color: #08110b;
    background: linear-gradient(180deg, #7ce8a8, #4ecd84);
    box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.35);
  }
  .hud-live-approval-approve:hover {
    background: linear-gradient(180deg, #8cf0b4, #5ad892);
  }
  .hud-live-approval-deny {
    color: rgba(255, 190, 196, 0.95);
    background: rgba(255, 139, 149, 0.12);
    box-shadow: inset 0 0 0 1px rgba(255, 139, 149, 0.26);
  }
  .hud-live-approval-deny:hover {
    background: rgba(255, 139, 149, 0.2);
  }
  .hud-live-meta-dot {
    width: 2.5px;
    height: 2.5px;
    flex: 0 0 2.5px;
    border-radius: 999px;
    background: rgba(235, 240, 250, 0.40);
  }
  .hud-live-meta .hud-live-phase {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .hud-symbol {
    width: 13px;
    height: 13px;
    display: grid;
    place-items: center;
    flex: 0 0 auto;
    color: #5fd28a;
  }
  html[data-tone="error"] .hud-symbol {
    color: #ff6672;
  }
  html[data-tone="warning"] .hud-symbol {
    color: #e7c363;
  }
  html[data-tone="info"] .hud-symbol {
    color: #73b9ff;
  }
  .hud-symbol svg {
    width: 13px;
    height: 13px;
    stroke-width: 1.85;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
  .hud-message,
  .hud-correction-copy,
  .hud-correction-label {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: 11.5px;
    font-weight: 700;
    letter-spacing: 0;
  }
  .hud-message {
    color: rgba(248, 249, 252, 0.94);
  }
  .hud-correction-label {
    flex: 0 0 auto;
    color: rgba(248, 249, 252, 0.58);
  }
  .hud-correction-copy {
    flex: 1 1 auto;
    color: rgba(248, 249, 252, 0.94);
  }
  .hud-action {
    flex: 0 0 auto;
    border: 1px solid rgba(255, 255, 255, 0.13);
    border-radius: 999px;
    padding: 3px 9px;
    background: rgba(255, 255, 255, 0.06);
    color: rgba(248, 249, 252, 0.72);
    font-size: 10.5px;
    font-weight: 760;
    pointer-events: auto;
    -webkit-app-region: no-drag;
  }
  input {
    pointer-events: auto;
    user-select: text;
    -webkit-app-region: no-drag;
  }
  .hud-action.accept {
    color: #6fe08e;
    border-color: rgba(111, 224, 142, 0.32);
    background: rgba(111, 224, 142, 0.10);
  }
  .hud-action.reject {
    color: #ff7881;
    border-color: rgba(255, 120, 129, 0.30);
    background: rgba(255, 120, 129, 0.09);
  }
  @keyframes hud-spin {
    to { transform: rotate(360deg); }
  }
  @keyframes hud-live-orb-pulse {
    0%, 100% { transform: scale(0.94); filter: brightness(0.96); }
    50% { transform: scale(1.04); filter: brightness(1.14); }
  }
  @keyframes hud-live-orb-spin {
    to { transform: rotate(360deg); }
  }
  @keyframes hud-analysis-glow {
    0%, 100% {
      box-shadow:
        0 0 0 1px rgba(120, 151, 220, 0.22),
        0 0 18px rgba(120, 151, 220, 0.28),
        0 0 30px rgba(255, 122, 143, 0.14),
        0 0 38px rgba(231, 195, 99, 0.10);
    }
    50% {
      box-shadow:
        0 0 0 1px rgba(120, 151, 220, 0.40),
        0 0 28px rgba(120, 151, 220, 0.48),
        0 0 44px rgba(255, 122, 143, 0.24),
        0 0 58px rgba(231, 195, 99, 0.16);
    }
  }
  /* Custom scrollbars for the analysis result */
  .hud div::-webkit-scrollbar {
    width: 4px;
  }
  .hud div::-webkit-scrollbar-track {
    background: transparent;
  }
  .hud div::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.15);
    border-radius: 99px;
  }
  .hud div::-webkit-scrollbar-thumb:hover {
    background: rgba(255, 255, 255, 0.3);
  }
</style>
</head>
<body>
<div id="root"></div>
<script>
	  const root = document.getElementById("root");
	  const barWeights = [0.42, 0.58, 0.74, 0.92, 1.0, 0.94, 0.78, 0.62];
	  const palettes = {
	    "vibrant-spectrum": ["#4f8fe8", "#6f78de", "#a363b7", "#df4546", "#ee7b25", "#ddb52d", "#91b74b", "#39a268"],
	    "professional-tech": ["#78b7ff", "#5f92ff", "#837bff", "#9b78e8", "#6cc8f2", "#55d0c0", "#69d58c", "#8edb79"],
	    "monochrome": ["#d8dbe0", "#cdd1d7", "#bdc2ca", "#afb5bf", "#dfe2e6", "#c9ced6", "#b9bec6", "#aeb4bd"],
	    "neon-lagoon": ["#74d5ff", "#54e3da", "#56edb2", "#91ef78", "#c7ec5e", "#70dba6", "#49c8df", "#67a8ff"],
	    "sunset-candy": ["#6e8dff", "#9b75d7", "#d45a8b", "#ef4b55", "#f08328", "#ebb934", "#c4bd45", "#70b365"],
	    "cosmic-pop": ["#58a9ff", "#6f74f2", "#945fe3", "#c849cc", "#eb4b82", "#f27d3a", "#d6b83f", "#54bf83"],
	    "mint-blush": ["#6fa7ff", "#8c8bf0", "#c175b7", "#ef6f7f", "#f0a448", "#d7c957", "#9ddc74", "#5bca95"]
	  };
	  let renderedStatus = "";
	  let renderedTheme = "";
	  let barNodes = [];
	  let barStates = [];
	  let currentLevel = 0;
	  let waveformLoopActive = false;
	  let lastFrameTime = 0;
	  let orbEnergyState = 0;
	  let dictationCurrentLevel = 0;
	  let dictationEnergyState = 0;
  let lastLiveHUDAction = { action: "", at: 0 };
  let activeScreenSubmit = null;
  let activeScreenCancel = null;
  window.__openAssistScreenPromptValue = () => "";
  window.__openAssistScreenSubmit = () => false;
  window.__openAssistScreenCancel = () => false;
  const icons = {
    error: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><circle cx="12" cy="12" r="9"/><path d="M12 7v6"/><path d="M12 17h.01"/></svg>',
    success: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M4.5 12.5 10 18l9.5-12"/></svg>',
    warning: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M12 8v5"/><path d="M12 17h.01"/><path d="m10.3 4.2-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.7-2.8l-8-14a2 2 0 0 0-3.4 0Z"/></svg>',
    info: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><circle cx="12" cy="12" r="9"/><path d="M12 11v5"/><path d="M12 8h.01"/></svg>',
    correction: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M21 7v6h-6"/><path d="M3 17v-6h6"/><path d="M7 7a7 7 0 0 1 11 2"/><path d="M17 17a7 7 0 0 1-11-2"/></svg>',
    mic: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3Z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><path d="M12 19v3"/></svg>',
    micOff: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="m2 2 20 20"/><path d="M9 9v3a3 3 0 0 0 5.1 2.1"/><path d="M15 9.3V6a3 3 0 0 0-5.1-2.1"/><path d="M19 10v2a7 7 0 0 1-.7 3"/><path d="M5 10v2a7 7 0 0 0 10 6.3"/><path d="M12 19v3"/></svg>',
    stop: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><rect x="7" y="7" width="10" height="10" rx="2"/></svg>'
  };
  function clampLevel(value) {
    const level = Number(value);
    if (!Number.isFinite(level)) return 0;
    return Math.max(0, Math.min(1, level));
  }
  function themeKey(theme) {
    return String(theme || "vibrant-spectrum").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  }
	  function optionKey(value) {
	    return String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
	  }
	  function waveformPalette(theme) {
	    return palettes[theme] || palettes["vibrant-spectrum"];
	  }
	  function voiceEnergy(level) {
	    // Low floor + strong expansion so normal conversational volume drives
	    // the bars well past half height instead of only reacting to loud speech.
	    const floor = 0.02;
	    if (level <= floor) return 0;
	    return Math.pow(Math.min(1, (level - floor) / (1 - floor)), 0.60);
	  }
	  const MIN_BAR_HEIGHT = 3;
	  const MAX_BAR_HEIGHT = 20;
	  // Asymmetric attack/decay measured in seconds — bars rise fast (attack)
	  // and fall slow (release), like a VU meter / classic audio-level visualizer.
	  // Release is short enough that individual syllables stay visible instead
	  // of blurring into one sustained wave.
	  const BAR_ATTACK = 0.05;
	  const BAR_RELEASE = 0.20;
	  function paintBar(node, value) {
	    const clamped = Math.max(0, Math.min(1, value));
	    node.style.height = (MIN_BAR_HEIGHT + clamped * (MAX_BAR_HEIGHT - MIN_BAR_HEIGHT)).toFixed(2) + "px";
	    node.style.opacity = (0.88 + clamped * 0.12).toFixed(3);
	  }
	  function tickWaveform(now) {
	    if (!waveformLoopActive) {
	      waveformLoopActive = false;
	      return;
	    }
	    const dt = lastFrameTime ? Math.min(0.1, (now - lastFrameTime) / 1000) : 0.016;
	    lastFrameTime = now;
	    const energy = voiceEnergy(currentLevel);
	    let stillMoving = energy > 0.001;
	    // The live orb halo breathes with the same smoothed energy so it reads
	    // as a Siri-style glowing orb instead of a static badge. The waveform
	    // bars below are skipped when no meter is mounted (e.g. the live HUD).
	    const orbRate = energy > orbEnergyState ? BAR_ATTACK : BAR_RELEASE;
	    const orbK = 1 - Math.exp(-dt / Math.max(0.001, orbRate));
	    orbEnergyState += (energy - orbEnergyState) * orbK;
	    if (Math.abs(energy - orbEnergyState) > 0.002) stillMoving = true;
	    document.documentElement.style.setProperty("--hud-energy", orbEnergyState.toFixed(3));
	    const dictationEnergy = voiceEnergy(dictationCurrentLevel);
	    const dictationRate = dictationEnergy > dictationEnergyState ? BAR_ATTACK : BAR_RELEASE;
	    const dictationK = 1 - Math.exp(-dt / Math.max(0.001, dictationRate));
	    dictationEnergyState += (dictationEnergy - dictationEnergyState) * dictationK;
	    if (Math.abs(dictationEnergy - dictationEnergyState) > 0.002) stillMoving = true;
	    document.documentElement.style.setProperty("--hud-dictation-energy", dictationEnergyState.toFixed(3));
	    for (let i = 0; i < barNodes.length; i++) {
	      // Per-bar slow phase modulation so bars don't move in perfect lockstep,
	      // and a tiny stochastic flutter so it feels organic instead of mechanical.
	      const phase = 0.78 + 0.22 * Math.sin(now * 0.0042 + i * 1.13);
	      const flutter = 1 - 0.10 * Math.sin(now * 0.0093 + i * 2.07);
	      const target = energy * barWeights[i] * phase * flutter;
	      const state = barStates[i];
	      const rate = target > state.current ? BAR_ATTACK : BAR_RELEASE;
	      const k = 1 - Math.exp(-dt / Math.max(0.001, rate));
	      state.current += (target - state.current) * k;
	      if (Math.abs(target - state.current) > 0.002) stillMoving = true;
	      paintBar(barNodes[i], state.current);
	    }
	    if (stillMoving) {
	      requestAnimationFrame(tickWaveform);
	    } else {
	      waveformLoopActive = false;
	      lastFrameTime = 0;
	      document.documentElement.style.setProperty("--hud-energy", "0");
	      document.documentElement.style.setProperty("--hud-dictation-energy", "0");
	    }
	  }
	  function ensureWaveformLoop() {
	    if (waveformLoopActive) return;
	    waveformLoopActive = true;
	    lastFrameTime = 0;
	    requestAnimationFrame(tickWaveform);
	  }
	  function waveform(level) {
	    const node = document.createElement("div");
	    node.className = "hud-waveform";
	    const colors = waveformPalette(document.documentElement.dataset.theme);
	    barStates = [];
	    for (let index = 0; index < barWeights.length; index++) {
	      const bar = document.createElement("i");
	      bar.style.setProperty("--bar-color", colors[index % colors.length]);
	      paintBar(bar, 0);
	      node.appendChild(bar);
	      barStates.push({ current: 0 });
	    }
	    barNodes = Array.from(node.querySelectorAll("i"));
	    currentLevel = level;
	    ensureWaveformLoop();
	    return node;
	  }
	  function applyWaveformLevel(level) {
	    currentLevel = level;
	    ensureWaveformLoop();
	  }
  function oneLine(value) {
    return String(value || "").replace(/\\s+/g, " ").trim();
  }
  function livePhaseLabel(phase) {
    if (phase === "connecting") return "Preparing";
    if (phase === "speaking") return "Speaking";
    if (phase === "delegating") return "Agent working";
    return "Listening";
  }
  function liveCaptionFallback(phase, statusText, muted) {
    if (muted) return "Microphone muted";
    if (phase === "speaking") return "Assistant is speaking";
    if (phase === "delegating") return "Agent is working";
    if (phase === "connecting") return statusText || "Starting session";
    return "Listening for your voice";
  }
  function sendLiveHUDAction(action, event) {
    if (event) {
      event.preventDefault();
      event.stopPropagation();
    }
    const now = Date.now();
    if (lastLiveHUDAction.action === action && now - lastLiveHUDAction.at < 220) return;
    lastLiveHUDAction = { action, at: now };
    if (!window.openAssistElectron || !window.openAssistElectron.liveVoiceHUDAction) return;
    window.openAssistElectron.liveVoiceHUDAction(action).catch(() => {});
  }
  function wireLiveHUDButton(button, action) {
    const handler = (event) => sendLiveHUDAction(action, event);
    button.onclick = handler;
    button.onmousedown = handler;
    button.onpointerdown = handler;
  }
  function updateLiveHUDContent(payload, phase, container) {
    // Tint the orb with the user's "Realtime & Snip Glow Color" preset
    // (sent by the main process); fall back to the waveform theme palette.
    const orbColors = (payload && Array.isArray(payload.glowColors) && payload.glowColors.length ? payload.glowColors : waveformPalette(document.documentElement.dataset.theme)) || [];
    const rootStyle = document.documentElement.style;
    rootStyle.setProperty("--orb-c1", orbColors[0] || "#6f9dff");
    rootStyle.setProperty("--orb-c2", orbColors[1] || orbColors[0] || "#5ee0ae");
    rootStyle.setProperty("--orb-c3", orbColors[2] || orbColors[0] || "#e9c76e");
    rootStyle.setProperty("--orb-c4", orbColors[3] || orbColors[1] || "#ff8bd2");
    const provider = oneLine(payload && payload.providerLabel) || "Live Voice";
    const statusText = oneLine(payload && payload.text) || livePhaseLabel(phase);
    const userText = oneLine(payload && payload.userText);
    const assistantText = oneLine(payload && payload.assistantText);
    const muted = Boolean(payload && payload.muted);
    const scope = container || root;
    const captionNode = scope.querySelector(".hud-live-caption");
    const providerNode = scope.querySelector(".hud-live-provider");
    const phaseNode = scope.querySelector(".hud-live-phase");
    const muteButton = scope.querySelector(".hud-live-control.is-mute");
    const phaseLabel = muted ? "Muted" : livePhaseLabel(phase);
    if (providerNode) providerNode.textContent = provider;
    if (phaseNode) phaseNode.textContent = phaseLabel;
    if (captionNode) {
      // Spoken words only — agent/tool status lives in its own chip below,
      // so the two can never race for this bubble.
      const caption = assistantText || userText;
      if (caption) captionNode.textContent = caption;
      captionNode.classList.toggle("is-empty", !caption);
    }
    const workNode = scope.querySelector(".hud-live-work");
    if (workNode) {
      const workText = oneLine(payload && payload.workText);
      workNode.classList.toggle("is-visible", Boolean(workText));
      const workTextNode = workNode.querySelector(".hud-live-work-text");
      if (workText && workTextNode) workTextNode.textContent = workText;
    }
    if (muteButton) {
      muteButton.classList.toggle("is-muted", muted);
      muteButton.title = muted ? "Unmute microphone" : "Mute microphone";
      muteButton.setAttribute("aria-label", muted ? "Unmute microphone" : "Mute microphone");
      muteButton.setAttribute("aria-pressed", muted ? "true" : "false");
      muteButton.innerHTML = muted ? icons.micOff : icons.mic;
    }
    const approvalRow = scope.querySelector(".hud-live-approval");
    if (approvalRow) {
      const approval = payload && payload.approval;
      const hasApproval = Boolean(approval && approval.requestID);
      approvalRow.classList.toggle("is-visible", hasApproval);
      const summaryNode = approvalRow.querySelector(".hud-live-approval-summary");
      if (hasApproval && summaryNode) {
        summaryNode.textContent = oneLine(approval.summary) || "Approve this pending change?";
      }
    }
    const dictationStrip = scope.querySelector(".hud-live-dictation");
    if (dictationStrip) {
      dictationStrip.classList.toggle("is-visible", Boolean(payload && payload.dictationCapture));
    }
  }

  window.closeHUD = function() {
    if (window.openAssistElectron && window.openAssistElectron.stopAssistantVoiceOutput) {
      window.openAssistElectron.stopAssistantVoiceOutput().catch(() => {});
    }
    if (window.openAssistElectron && window.openAssistElectron.updateVoiceHUD) {
      window.openAssistElectron.updateVoiceHUD({ visible: false });
    }
  };

  document.addEventListener("keydown", (e) => {
    const currentStatus = document.documentElement.dataset.status;
    if (currentStatus === "analyzing-input") {
      if (e.key === "Enter" && activeScreenSubmit) {
        e.preventDefault();
        activeScreenSubmit();
        return;
      }
      if (e.key === "Escape" && activeScreenCancel) {
        e.preventDefault();
        activeScreenCancel();
        return;
      }
    }
    if (e.key === "Escape") {
      if (currentStatus === "analyzing-input" || currentStatus === "analyzing" || currentStatus === "analysis-result") {
        if (window.openAssistElectron && window.openAssistElectron.cancelScreenAnalysis) {
          window.openAssistElectron.cancelScreenAnalysis();
          return;
        }
      }
      window.closeHUD();
    }
  });

  window.updateOpenAssistVoiceHUD = function(payload) {
    const rawStatus = payload && payload.status;
    const livePhase = rawStatus === "live-connecting"
      ? "connecting"
      : rawStatus === "live-listening"
        ? "listening"
        : rawStatus === "live-speaking"
          ? "speaking"
          : rawStatus === "live-delegating"
            ? "delegating"
            : "";
    const status = rawStatus === "processing"
      ? "processing"
      : rawStatus === "analyzing"
        ? "analyzing"
        : rawStatus === "analyzing-input"
          ? "analyzing-input"
          : rawStatus === "analysis-result"
            ? "analysis-result"
            : rawStatus === "error" || rawStatus === "unsupported" || rawStatus === "message"
              ? "toast"
              : rawStatus === "correction"
                ? "correction"
                : livePhase
                  ? "live"
                  : "listening";
    const tone = rawStatus === "error" || rawStatus === "unsupported" ? "error" : (payload && payload.tone) || "success";
    const level = clampLevel(payload && payload.level);
    dictationCurrentLevel = Boolean(payload && payload.dictationCapture)
      ? clampLevel(payload && payload.dictationLevel)
      : 0;
    document.documentElement.dataset.status = status;
    document.documentElement.dataset.tone = tone;
    document.documentElement.dataset.theme = themeKey(payload && payload.theme);
    document.documentElement.dataset.colorTheme = optionKey(payload && payload.colorTheme);
    document.documentElement.dataset.chromeStyle = optionKey(payload && payload.chromeStyle);
    document.documentElement.dataset.livePhase = livePhase;
	    document.documentElement.dataset.speaking = level > 0.10 ? "true" : "false";
    if (status === "listening" && renderedStatus === "listening" && renderedTheme === document.documentElement.dataset.theme && root.firstChild) {
      applyWaveformLevel(level);
      return;
    }
    if (status === "live" && renderedStatus === "live" && renderedTheme === document.documentElement.dataset.theme && root.firstChild) {
      applyWaveformLevel(level);
      updateLiveHUDContent(payload, livePhase, root.firstChild);
      return;
    }
    if (status === "processing" && renderedStatus === "processing" && root.firstChild) {
      return;
    }
    root.textContent = "";
    activeScreenSubmit = null;
    activeScreenCancel = null;
    window.__openAssistScreenPromptValue = () => "";
    window.__openAssistScreenSubmit = () => false;
    window.__openAssistScreenCancel = () => false;
    const hud = document.createElement("div");
    hud.className = "hud";
    if (status === "processing") {
      const spinner = document.createElement("span");
      spinner.className = "hud-spinner";
      hud.append(spinner);
        } else if (status === "analyzing") {
      const spinner = document.createElement("span");
      spinner.className = "hud-spinner";
      const text = document.createElement("span");
      text.className = "hud-message";
      text.textContent = (payload && payload.text) || "Analyzing screen...";
      hud.append(spinner, text);
    } else if (status === "analyzing-input") {
      const header = document.createElement("div");
      header.style.display = "flex";
      header.style.justifyContent = "space-between";
      header.style.alignItems = "center";
      header.style.width = "100%";
      header.style.flex = "0 0 auto";

      const titleContainer = document.createElement("div");
      titleContainer.style.display = "flex";
      titleContainer.style.alignItems = "center";
      titleContainer.style.gap = "6px";

      const spark = document.createElement("span");
      spark.style.color = "#7897dc";
      spark.style.display = "flex";
      spark.style.alignItems = "center";
      spark.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" style="width: 14px; height: 14px;"><path d="M4 8V6a2 2 0 0 1 2-2h2"/><path d="M16 4h2a2 2 0 0 1 2 2v2"/><path d="M20 16v2a2 2 0 0 1-2 2h-2"/><path d="M8 20H6a2 2 0 0 1-2-2v-2"/><path d="M12 8.2 13 11l2.8 1-2.8 1-1 2.8-1-2.8L8.2 12l2.8-1 1-2.8z"/></svg>';

      const title = document.createElement("span");
      title.style.fontSize = "11.5px";
      title.style.fontWeight = "800";
      title.style.color = "rgba(255, 255, 255, 0.88)";
      title.textContent = "Ask about screenshot";

      titleContainer.append(spark, title);

      const cancelBtn = document.createElement("button");
      cancelBtn.className = "hud-action reject";
      cancelBtn.style.padding = "2px 8px";
      cancelBtn.style.fontSize = "10px";
      cancelBtn.style.cursor = "pointer";
      cancelBtn.textContent = "Cancel";
      const cancelAnalysis = function() {
        if (window.openAssistElectron && window.openAssistElectron.cancelScreenAnalysis) {
          window.openAssistElectron.cancelScreenAnalysis();
        }
      };
      const cancelFromButton = function(event) {
        event.preventDefault();
        event.stopPropagation();
        cancelAnalysis();
      };
      cancelBtn.onpointerdown = cancelFromButton;
      cancelBtn.onmousedown = cancelFromButton;
      cancelBtn.onclick = cancelAnalysis;

      header.append(titleContainer, cancelBtn);

      const bodyRow = document.createElement("div");
      bodyRow.style.display = "flex";
      bodyRow.style.gap = "10px";
      bodyRow.style.width = "100%";
      bodyRow.style.flex = "1 1 auto";
      bodyRow.style.alignItems = "stretch";

      const preview = document.createElement("div");
      preview.style.width = "104px";
      preview.style.flex = "0 0 104px";
      preview.style.borderRadius = "10px";
      preview.style.overflow = "hidden";
      preview.style.background = "rgba(255, 255, 255, 0.08)";
      preview.style.border = "1px solid rgba(255, 255, 255, 0.13)";
      preview.style.display = "grid";
      preview.style.placeItems = "center";
      preview.style.minHeight = "68px";
      if (payload && payload.previewDataURL) {
        const img = document.createElement("img");
        img.src = payload.previewDataURL;
        img.alt = "Screenshot preview";
        img.style.width = "100%";
        img.style.height = "100%";
        img.style.objectFit = "cover";
        preview.append(img);
      } else {
        const empty = document.createElement("span");
        empty.textContent = "Preview";
        empty.style.fontSize = "11px";
        empty.style.color = "rgba(255, 255, 255, 0.46)";
        preview.append(empty);
      }

      const controls = document.createElement("div");
      controls.style.display = "flex";
      controls.style.flexDirection = "column";
      controls.style.gap = "8px";
      controls.style.minWidth = "0";
      controls.style.flex = "1 1 auto";

      const inputRow = document.createElement("div");
      inputRow.style.display = "flex";
      inputRow.style.gap = "8px";
      inputRow.style.width = "100%";
      inputRow.style.flex = "1 1 auto";
      inputRow.style.alignItems = "center";

      const input = document.createElement("input");
      input.type = "text";
      input.placeholder = "What should I do with this screenshot?";
      input.style.flex = "1";
      input.style.background = "rgba(255, 255, 255, 0.10)";
      input.style.border = "1px solid rgba(255, 255, 255, 0.16)";
      input.style.borderRadius = "6px";
      input.style.padding = "6px 10px";
      input.style.fontSize = "12px";
      input.style.color = "#ffffff";
      input.style.outline = "none";
      input.style.transition = "border-color 0.15s ease";
      input.style.userSelect = "text";
      input.onfocus = () => { input.style.borderColor = "rgba(120, 151, 220, 0.5)"; };
      input.onblur = () => { input.style.borderColor = "rgba(255, 255, 255, 0.12)"; };

      const submit = document.createElement("button");
      submit.className = "hud-action accept";
      submit.style.padding = "5px 12px";
      submit.style.fontSize = "11px";
      submit.style.cursor = "pointer";
      submit.textContent = "Send";

      let submitted = false;
      const hint = document.createElement("div");
      hint.textContent = "Press Enter to send";
      hint.style.fontSize = "10.5px";
      hint.style.fontWeight = "700";
      hint.style.color = "rgba(255, 255, 255, 0.42)";
      const setHint = (message, color) => {
        hint.textContent = message;
        hint.style.color = color || "rgba(255, 255, 255, 0.42)";
      };
      const showSubmitError = (message) => {
        submitted = false;
        submit.disabled = false;
        submit.textContent = "Send";
        input.disabled = false;
        setHint(message, "rgba(255, 120, 129, 0.78)");
        if (window.openAssistElectron && window.openAssistElectron.updateVoiceHUD) {
          window.openAssistElectron.updateVoiceHUD({ visible: true, status: "error", text: message });
        }
      };
      const doSubmit = () => {
        if (submitted) return;
        if (!window.openAssistElectron || !window.openAssistElectron.submitScreenAnalysis) {
          showSubmitError("Screen analysis is not ready. Please try again.");
          return;
        }
        submitted = true;
        const instruction = input.value;
        submit.disabled = true;
        submit.textContent = "Sending";
        input.disabled = true;
        setHint("Sending screenshot...");
        window.openAssistElectron.submitScreenAnalysis(instruction).catch((error) => {
          const message = error && error.message ? error.message : String(error || "Screen analysis failed.");
          showSubmitError(message);
        });
      };

      const submitFromButton = (event) => {
        event.preventDefault();
        event.stopPropagation();
        doSubmit();
      };
      submit.onclick = doSubmit;
      submit.onmousedown = submitFromButton;
      submit.onpointerdown = submitFromButton;
      submit.onmouseup = submitFromButton;
      input.onkeydown = (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          doSubmit();
        } else if (e.key === "Escape") {
          e.preventDefault();
          if (window.openAssistElectron && window.openAssistElectron.cancelScreenAnalysis) {
            window.openAssistElectron.cancelScreenAnalysis();
          }
        }
      };
      input.onkeyup = (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          doSubmit();
        }
      };
      activeScreenSubmit = doSubmit;
      activeScreenCancel = cancelAnalysis;
      window.__openAssistScreenPromptValue = () => input.value || "";
      window.__openAssistScreenSubmit = () => {
        doSubmit();
        return true;
      };
      window.__openAssistScreenCancel = () => {
        cancelAnalysis();
        return true;
      };

      inputRow.append(input, submit);
      controls.append(inputRow, hint);
      bodyRow.append(preview, controls);
      hud.append(header, bodyRow);

      setTimeout(() => {
        input.focus();
      }, 50);
    } else if (status === "live") {
      const orb = document.createElement("span");
      orb.className = "hud-live-orb";

      const caption = document.createElement("span");
      caption.className = "hud-live-caption";

      const controls = document.createElement("div");
      controls.className = "hud-live-controls";
      const mute = document.createElement("button");
      mute.type = "button";
      mute.className = "hud-live-control is-mute";
      wireLiveHUDButton(mute, "toggleMute");
      const stop = document.createElement("button");
      stop.type = "button";
      stop.className = "hud-live-control is-stop";
      stop.title = "Stop Live Voice";
      stop.setAttribute("aria-label", "Stop Live Voice");
      stop.innerHTML = icons.stop;
      wireLiveHUDButton(stop, "stop");
      controls.append(mute, stop);

      // Message bubble on top; the orb floats alone in the center with the
      // control cluster detached to its right. No provider/status label.
      const mainRow = document.createElement("div");
      mainRow.className = "hud-live-main";
      const spacer = document.createElement("span");
      spacer.className = "hud-live-spacer";
      mainRow.append(spacer, orb, controls);

      const approvalRow = document.createElement("div");
      approvalRow.className = "hud-live-approval";
      const approvalSummary = document.createElement("span");
      approvalSummary.className = "hud-live-approval-summary";
      const approvalDeny = document.createElement("button");
      approvalDeny.type = "button";
      approvalDeny.className = "hud-live-approval-deny";
      approvalDeny.textContent = "Deny";
      wireLiveHUDButton(approvalDeny, "rejectRequest");
      const approvalApprove = document.createElement("button");
      approvalApprove.type = "button";
      approvalApprove.className = "hud-live-approval-approve";
      approvalApprove.textContent = "Approve";
      wireLiveHUDButton(approvalApprove, "approveRequest");
      approvalRow.append(approvalSummary, approvalDeny, approvalApprove);

      const dictationStrip = document.createElement("div");
      dictationStrip.className = "hud-live-dictation";
      const dictationDot = document.createElement("span");
      dictationDot.className = "hud-live-dictation-dot";
      const dictationLabel = document.createElement("span");
      dictationLabel.className = "hud-live-dictation-label";
      dictationLabel.textContent = "Dictating";
      dictationStrip.append(dictationDot, dictationLabel);

      // Agent/tool work status chip — its own container, so it never fights
      // the spoken caption for the same spot.
      const workChip = document.createElement("div");
      workChip.className = "hud-live-work";
      const workDot = document.createElement("span");
      workDot.className = "hud-live-work-dot";
      const workLabel = document.createElement("span");
      workLabel.className = "hud-live-work-text";
      workChip.append(workDot, workLabel);

      // mainRow (the orb) stays LAST so it is pinned at the window bottom;
      // approval and text bubbles stack above it without moving the orb.
      hud.append(dictationStrip, caption, workChip, approvalRow, mainRow);
      updateLiveHUDContent(payload, livePhase, hud);
      barNodes = [];
      barStates = [];
      applyWaveformLevel(level);
    } else if (status === "analysis-result") {
      const header = document.createElement("div");
      header.style.display = "flex";
      header.style.justifyContent = "space-between";
      header.style.alignItems = "center";
      header.style.width = "100%";
      header.style.borderBottom = "1px solid rgba(255, 255, 255, 0.08)";
      header.style.paddingBottom = "6px";
      header.style.marginBottom = "2px";
      header.style.flex = "0 0 auto";

      const titleContainer = document.createElement("div");
      titleContainer.style.display = "flex";
      titleContainer.style.alignItems = "center";
      titleContainer.style.gap = "6px";

      const spark = document.createElement("span");
      spark.style.color = "#7897dc";
      spark.style.display = "flex";
      spark.style.alignItems = "center";
      spark.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" style="width: 14px; height: 14px;"><path d="M4 8V6a2 2 0 0 1 2-2h2"/><path d="M16 4h2a2 2 0 0 1 2 2v2"/><path d="M20 16v2a2 2 0 0 1-2 2h-2"/><path d="M8 20H6a2 2 0 0 1-2-2v-2"/><path d="M12 8.2 13 11l2.8 1-2.8 1-1 2.8-1-2.8L8.2 12l2.8-1 1-2.8z"/></svg>';

      const title = document.createElement("span");
      title.style.fontSize = "12px";
      title.style.fontWeight = "800";
      title.style.color = "rgba(255, 255, 255, 0.9)";
      title.textContent = "Screen Analysis";

      titleContainer.append(spark, title);

      const closeBtn = document.createElement("button");
      closeBtn.className = "hud-action reject";
      closeBtn.style.padding = "2px 8px";
      closeBtn.style.fontSize = "10px";
      closeBtn.style.cursor = "pointer";
      closeBtn.textContent = "Close";
      closeBtn.onclick = window.closeHUD;

      header.append(titleContainer, closeBtn);

      const body = document.createElement("div");
      body.style.flex = "1 1 auto";
      body.style.overflowY = "auto";
      body.style.width = "100%";
      body.style.paddingRight = "4px";
      body.style.textAlign = "left";
      body.style.whiteSpace = "pre-wrap";
      body.style.fontSize = "12.5px";
      body.style.lineHeight = "1.5";
      body.style.color = "rgba(240, 242, 245, 0.95)";
      body.style.scrollbarWidth = "thin";
      body.style.scrollbarColor = "rgba(255, 255, 255, 0.15) transparent";

      const text = document.createElement("div");
      text.textContent = (payload && payload.text) || "";
      body.append(text);

      hud.append(header, body);
    } else if (status === "toast") {
      const dot = document.createElement("span");
      dot.className = "hud-dot";
      const symbol = document.createElement("span");
      symbol.className = "hud-symbol";
      symbol.innerHTML = icons[tone] || icons.success;
      const text = document.createElement("span");
      text.className = "hud-message";
      text.textContent = (payload && payload.text) || "Voice input failed.";
      hud.append(dot, symbol, text);
    } else if (status === "correction") {
      const dot = document.createElement("span");
      dot.className = "hud-dot";
      const symbol = document.createElement("span");
      symbol.className = "hud-symbol";
      symbol.innerHTML = icons.correction;
      const label = document.createElement("span");
      label.className = "hud-correction-label";
      label.textContent = "Save correction:";
      const copy = document.createElement("span");
      copy.className = "hud-correction-copy";
      const source = (payload && payload.source) || "before";
      const replacement = (payload && payload.replacement) || (payload && payload.text) || "after";
      copy.textContent = source + " -> " + replacement;
      const reject = document.createElement("button");
      reject.className = "hud-action reject";
      reject.textContent = "Reject";
      const accept = document.createElement("button");
      accept.className = "hud-action accept";
      accept.textContent = "Accept";
      hud.append(dot, symbol, label, copy, reject, accept);
    } else {
      const dot = document.createElement("span");
      dot.className = "hud-dot";
      hud.append(dot, waveform(level));
    }
    root.appendChild(hud);
    renderedStatus = status;
    renderedTheme = document.documentElement.dataset.theme || "";
  };
</script>
</body>
</html>`;
}

// Match the Swift WaveformHUD layout so both apps render at the same screen position.
const HUD_DOCK_RESERVE = 80;
const HUD_TOAST_VERTICAL_GAP = 12;
const HUD_WAVEFORM_HEIGHT = 34;

function voiceHUDSize(payload: VoiceHUDPayload) {
  if (payload.status === "analysis-result") {
    return { width: 520, height: 240 };
  }
  if (payload.status === "analyzing-input") {
    return { width: 620, height: 150 };
  }
  if (payload.status === "analyzing") {
    return { width: 190, height: HUD_WAVEFORM_HEIGHT };
  }
  if (payload.status === "correction") {
    const text = `${payload.text ?? ""}${payload.replacement ?? ""}${payload.source ?? ""}`.trim();
    const textWidth = Math.ceil(text.length * 6.4);
    const width = Math.max(300, Math.min(460, textWidth + 200));
    return { width, height: HUD_WAVEFORM_HEIGHT };
  }
  if (isLiveVoiceHUDStatus(payload.status)) {
    // Detached layout: message bubble on top, floating orb + control cluster
    // below; taller again when a pending approval row is shown.
    const base = payload.approval?.requestID
      ? { width: 380, height: 186 }
      : { width: 318, height: 122 };
    if (payload.dictationCapture) {
      return { width: base.width, height: base.height + 40 };
    }
    return base;
  }
  if (payload.status === "error" || payload.status === "unsupported" || payload.status === "message") {
    const text = String(payload.text ?? "Voice input failed").trim();
    const textWidth = Math.ceil(text.length * 6.5);
    const overhead = 58; // dot + icon + gaps + padding
    const width = Math.max(160, Math.min(420, textWidth + overhead));
    return { width, height: HUD_WAVEFORM_HEIGHT };
  }
  return payload.status === "processing"
    ? { width: 34, height: HUD_WAVEFORM_HEIGHT }
    : { width: 76, height: HUD_WAVEFORM_HEIGHT };
}

function positionVoiceHUDWindow(window: BrowserWindow, payload: VoiceHUDPayload) {
  const size = voiceHUDSize(payload);
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const bounds = display.workArea || display.bounds;
  const margin = 16;
  const maxX = bounds.x + bounds.width - size.width - margin;
  const minX = bounds.x + margin;
  const centeredX = bounds.x + (bounds.width - size.width) / 2;
  const x = Math.max(minX, Math.min(maxX, centeredX));
  const y = Math.max(bounds.y + margin, bounds.y + bounds.height - HUD_DOCK_RESERVE - size.height);
  const useAnim = process.platform === "darwin" && (payload.status === "analysis-result" || payload.status === "analyzing");
  window.setBounds({
    x: Math.round(x),
    y: Math.round(y),
    width: size.width,
    height: size.height
  }, useAnim);
}

function ensureVoiceHUDWindow() {
  if (voiceHUDWindow && !voiceHUDWindow.isDestroyed()) return voiceHUDWindow;
  voiceHUDReady = false;
  voiceHUDInteractiveApplied = null;
  voiceHUDPresentationKey = "";
  const window = new BrowserWindow({
    width: 100,
    height: 34,
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    hasShadow: false,
    resizable: false,
    movable: true,
    focusable: true,
    acceptFirstMouse: true,
    skipTaskbar: true,
    show: false,
    paintWhenInitiallyHidden: true,
    title: "Open Assist Voice HUD",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      devTools: enableDevTools,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: true
    }
  });
  window.setIgnoreMouseEvents(false);
  window.setAlwaysOnTop(true, "screen-saver");
  if (process.platform === "darwin") {
    window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
  }
  window.on("closed", () => {
    if (voiceHUDWindow === window) voiceHUDWindow = null;
    voiceHUDReady = false;
    stopAssistantVoiceOutputForSessionEnd("voice HUD closed");
  });
  window.webContents.on("before-input-event", (event, input) => {
    if (pendingVoiceHUDPayload?.status !== "analyzing-input" || input.type !== "keyDown") return;
    if (input.key === "Escape") {
      event.preventDefault();
      void cancelScreenAnalysisPrompt();
      return;
    }
    if (input.key !== "Enter" && input.key !== "Return") return;
    event.preventDefault();
    void window.webContents.executeJavaScript(
      `(() => {
        if (window.__openAssistScreenPromptValue) return window.__openAssistScreenPromptValue();
        const input = document.querySelector("input");
        return input ? input.value : "";
      })()`
    )
      .then((instruction) => submitScreenAnalysisPrompt(String(instruction ?? "")))
      .catch((error) => {
        const message = error instanceof Error ? error.message : String(error);
        debugLog(`screen analysis keyboard submit failed: ${message}`);
        void updateVoiceHUD({
          visible: true,
          status: "error",
          text: `Screen analysis failed: ${message}`
        });
      });
  });
  window.webContents.once("did-finish-load", () => {
    voiceHUDReady = true;
    void window.webContents.executeJavaScript("Boolean(window.openAssistElectron && window.openAssistElectron.submitScreenAnalysis)")
      .then((ready) => {
        if (!ready) debugLog("voice HUD preload bridge is missing submitScreenAnalysis");
      })
      .catch((error) => {
        debugLog(`voice HUD preload bridge check failed: ${error instanceof Error ? error.message : String(error)}`);
      });
    const payload = pendingVoiceHUDPayload;
    if (payload) void updateVoiceHUD(payload);
  });
  window.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(voiceHUDHTML())}`);
  voiceHUDWindow = window;
  return window;
}

function rememberVoiceHUDAppearance(payload: VoiceHUDPayload) {
  lastVoiceHUDAppearance = {
    theme: payload.theme ?? lastVoiceHUDAppearance.theme,
    colorTheme: payload.colorTheme ?? lastVoiceHUDAppearance.colorTheme,
    chromeStyle: payload.chromeStyle ?? lastVoiceHUDAppearance.chromeStyle
  };
}

function prewarmVoiceHUDWindow() {
  if (process.platform !== "darwin") return;
  const window = ensureVoiceHUDWindow();
  positionVoiceHUDWindow(window, { status: "listening" });
}

function prewarmVoiceHelperBuild() {
  if (process.platform !== "darwin") return;
  void ensureAppleSpeechHelper().catch((error) => {
    debugLog(`voice helper prewarm failed: ${error instanceof Error ? error.message : String(error)}`);
  });
}

function clearVoiceHUDAutoHide() {
  if (voiceHUDAutoHideTimer) {
    clearTimeout(voiceHUDAutoHideTimer);
    voiceHUDAutoHideTimer = null;
  }
}

function scheduleVoiceHUDAutoHide(payload: VoiceHUDPayload) {
  clearVoiceHUDAutoHide();
  const status = payload.status;
  if (status !== "error" && status !== "unsupported" && status !== "message") return;
  voiceHUDAutoHideTimer = setTimeout(() => {
    pendingVoiceHUDPayload = null;
    lastLiveVoiceHUDSnapshot = null;
    voiceHUDWindow?.hide();
    voiceHUDPresentationKey = "";
    voiceHUDAutoHideTimer = null;
  }, status === "message" ? 2400 : 4200);
}

function storedVoiceHUDPayload(payload: VoiceHUDPayload) {
  const { suppressForAppFocus: _suppressForAppFocus, ...storedPayload } = payload;
  if (!voiceCapture) {
    storedPayload.dictationCapture = false;
    storedPayload.dictationLevel = 0;
  }
  return storedPayload;
}

function rememberLiveVoiceHUDSnapshot(payload: VoiceHUDPayload) {
  if (!isLiveVoiceHUDStatus(payload.status)) return;
  lastLiveVoiceHUDSnapshot = storedVoiceHUDPayload({
    ...payload,
    dictationCapture: false,
    dictationLevel: 0
  });
}

function applyLiveVoiceDictationOverlay(nextPayload: VoiceHUDPayload, incoming: VoiceHUDPayload) {
  if (voiceCapture && liveVoiceHUDSessionActive() && liveVoiceHUDMuted()) {
    const liveBase = isLiveVoiceHUDStatus(pendingVoiceHUDPayload?.status)
      ? pendingVoiceHUDPayload
      : isLiveVoiceHUDStatus(lastLiveVoiceHUDSnapshot?.status)
        ? lastLiveVoiceHUDSnapshot
        : null;
    if (!liveBase) return;
    const overlay = activeVoiceCaptureHUDPayload();
    nextPayload.status = liveBase.status;
    nextPayload.visible = true;
    nextPayload.muted = true;
    nextPayload.dictationCapture = overlay?.dictationCapture ?? false;
    nextPayload.dictationLevel = overlay?.dictationLevel ?? 0;
    if (!isLiveVoiceHUDStatus(incoming.status)) {
      nextPayload.providerLabel = liveBase.providerLabel ?? nextPayload.providerLabel;
      nextPayload.userText = liveBase.userText ?? nextPayload.userText;
      nextPayload.assistantText = liveBase.assistantText ?? nextPayload.assistantText;
      nextPayload.text = liveBase.text ?? nextPayload.text;
      nextPayload.level = liveBase.level ?? nextPayload.level;
      nextPayload.approval = liveBase.approval ?? nextPayload.approval;
    }
    return;
  }
  if (!voiceCapture && isLiveVoiceHUDStatus(nextPayload.status)) {
    nextPayload.dictationCapture = false;
    nextPayload.dictationLevel = 0;
  }
}

function refreshLiveVoiceDictationOverlay() {
  if (!voiceCapture || !liveVoiceHUDSessionActive() || !liveVoiceHUDMuted()) return;
  showActiveVoiceCaptureHUD();
}

function restoreLiveVoiceHUDAfterCaptureEnd() {
  stopVoiceCaptureHUDKeepAlive();
  const livePayload = isLiveVoiceHUDStatus(pendingVoiceHUDPayload?.status)
    ? pendingVoiceHUDPayload
    : lastLiveVoiceHUDSnapshot;
  if (!livePayload || !isLiveVoiceHUDStatus(livePayload.status)) return;
  void updateVoiceHUD({
    ...livePayload,
    visible: true,
    dictationCapture: false,
    dictationLevel: 0
  });
}

function shouldSuppressFloatingVoiceHUD(payload: VoiceHUDPayload) {
  if (payload.suppressForAppFocus) return true;
  return false;
}

function isInteractiveVoiceHUDStatus(status: VoiceHUDPayload["status"]) {
  return status === "correction" || status === "analysis-result" || status === "analyzing-input" || isLiveVoiceHUDStatus(status);
}

function activeVoiceCaptureHUDPayload(): VoiceHUDPayload | null {
  if (!voiceCapture) return null;
  if (voiceCapture.voiceOptions?.floatingHUDEnabled === false) return null;
  const appearance = {
    theme: voiceCapture.voiceOptions?.waveformTheme ?? lastVoiceHUDAppearance.theme,
    colorTheme: voiceCapture.voiceOptions?.colorTheme ?? lastVoiceHUDAppearance.colorTheme,
    chromeStyle: voiceCapture.voiceOptions?.appChromeStyle ?? lastVoiceHUDAppearance.chromeStyle
  };
  // Live Voice keeps the orb on screen; when muted, stack dictation above it
  // instead of replacing the HUD with the dictation pill at the same spot.
  if (liveVoiceHUDSessionActive() && liveVoiceHUDMuted() && pendingVoiceHUDPayload) {
    return {
      visible: true,
      status: pendingVoiceHUDPayload.status,
      level: pendingVoiceHUDPayload.level,
      text: pendingVoiceHUDPayload.text,
      providerLabel: pendingVoiceHUDPayload.providerLabel,
      userText: pendingVoiceHUDPayload.userText,
      assistantText: pendingVoiceHUDPayload.assistantText,
      muted: true,
      approval: pendingVoiceHUDPayload.approval ?? null,
      dictationCapture: !voiceCapture.processing,
      dictationLevel: voiceCapture.processing ? undefined : menuBarVoiceLevel,
      ...appearance
    };
  }
  return {
    visible: true,
    status: voiceCapture.processing ? "processing" : "listening",
    level: voiceCapture.processing ? undefined : menuBarVoiceLevel,
    ...appearance
  };
}

function showActiveVoiceCaptureHUD() {
  const payload = activeVoiceCaptureHUDPayload();
  if (!payload) return;
  void updateVoiceHUD(payload);
}

// While a native voice capture is running the main process is the single owner of
// the floating HUD: the renderer cannot hide it (every hide path in updateVoiceHUD
// re-asserts the capture payload), and this keep-alive re-shows the window if it is
// ever hidden out-of-band (app deactivation when the helper launches, Space changes,
// the OS dropping a borderless panel, etc.). It self-terminates when the capture ends.
function ensureVoiceCaptureHUDKeepAlive() {
  if (voiceCaptureHUDKeepAliveTimer) return;
  voiceCaptureHUDKeepAliveTimer = setInterval(() => {
    if (!voiceCapture) {
      stopVoiceCaptureHUDKeepAlive();
      return;
    }
    const payload = activeVoiceCaptureHUDPayload();
    if (!payload) return; // Floating HUD is disabled in settings.
    if (!voiceHUDWindow || voiceHUDWindow.isDestroyed() || !voiceHUDWindow.isVisible()) {
      debugLog("voice capture HUD keep-alive re-showing hidden HUD");
      showActiveVoiceCaptureHUD();
    }
  }, 200);
  voiceCaptureHUDKeepAliveTimer.unref?.();
}

function stopVoiceCaptureHUDKeepAlive() {
  if (!voiceCaptureHUDKeepAliveTimer) return;
  clearInterval(voiceCaptureHUDKeepAliveTimer);
  voiceCaptureHUDKeepAliveTimer = null;
}

async function updateVoiceHUD(payload: VoiceHUDPayload) {
  rememberVoiceHUDAppearance(payload);
  const isLevelOnlyUpdate = (payload.level !== undefined || payload.dictationLevel !== undefined)
    && payload.visible === undefined
    && payload.status === undefined
    && payload.text === undefined
    && payload.theme === undefined
    && payload.colorTheme === undefined
    && payload.chromeStyle === undefined
    && payload.tone === undefined
    && payload.source === undefined
    && payload.replacement === undefined;
  // A live payload without focus-suppression cancels any pending live hide.
  if (voiceHUDLiveHideTimer && isLiveVoiceHUDStatus(payload.status) && !payload.suppressForAppFocus) {
    clearTimeout(voiceHUDLiveHideTimer);
    voiceHUDLiveHideTimer = null;
  }
  // Debounced hide while a live HUD is on screen: transient idle blips
  // between turns must not flap the window in and out.
  const liveHUDOnScreen = isLiveVoiceHUDStatus(pendingVoiceHUDPayload?.status)
    && Boolean(voiceHUDWindow && !voiceHUDWindow.isDestroyed() && voiceHUDWindow.isVisible());
  if ((payload.visible === false || payload.status === "idle") && liveHUDOnScreen && !activeVoiceCaptureHUDPayload()) {
    if (!voiceHUDLiveHideTimer) {
      voiceHUDLiveHideTimer = setTimeout(() => {
        voiceHUDLiveHideTimer = null;
        clearVoiceHUDAutoHide();
        pendingVoiceHUDPayload = null;
        lastLiveVoiceHUDSnapshot = null;
        voiceHUDWindow?.hide();
        voiceHUDPresentationKey = "";
        updateMenuBarVoiceStatus({ visible: false, status: "idle" });
      }, 450);
      voiceHUDLiveHideTimer.unref?.();
    }
    return { ok: true, visible: true };
  }
  if (payload.visible === false || payload.status === "idle") {
    const activeCapturePayload = activeVoiceCaptureHUDPayload();
    if (activeCapturePayload) {
      updateMenuBarVoiceStatus(activeCapturePayload);
      if (payload.suppressForAppFocus) {
        clearVoiceHUDAutoHide();
        pendingVoiceHUDPayload = storedVoiceHUDPayload(activeCapturePayload);
        voiceHUDWindow?.hide();
    voiceHUDPresentationKey = "";
        return { ok: true, visible: false };
      }
      debugLog("voice HUD hide ignored while native capture is active");
      return updateVoiceHUD(activeCapturePayload);
    }
    clearVoiceHUDAutoHide();
    pendingVoiceHUDPayload = null;
    lastLiveVoiceHUDSnapshot = null;
    voiceHUDWindow?.hide();
    voiceHUDPresentationKey = "";
    updateMenuBarVoiceStatus(payload);
    return { ok: true, visible: false };
  }
  if (!isLevelOnlyUpdate) clearVoiceHUDAutoHide();
  const nextPayload = {
    ...lastVoiceHUDAppearance,
    ...(pendingVoiceHUDPayload ?? {}),
    ...payload
  };
  applyLiveVoiceDictationOverlay(nextPayload, payload);
  // Dictation must not replace an active, unmuted Live Voice HUD in the shared
  // floating window — that was hiding the dictation pill behind the live orb.
  if (
    (nextPayload.status === "listening" || nextPayload.status === "processing")
    && liveVoiceHUDSessionActive()
    && !liveVoiceHUDMuted()
    && pendingVoiceHUDPayload
    && isLiveVoiceHUDStatus(pendingVoiceHUDPayload.status)
  ) {
    return updateVoiceHUD({ ...pendingVoiceHUDPayload, visible: true });
  }
  const shouldShow = nextPayload.visible !== false
    && (
      nextPayload.status === "listening"
      || nextPayload.status === "processing"
      || nextPayload.status === "error"
      || nextPayload.status === "unsupported"
      || nextPayload.status === "message"
      || nextPayload.status === "correction"
      || nextPayload.status === "analyzing"
      || nextPayload.status === "analysis-result"
      || nextPayload.status === "analyzing-input"
      || isLiveVoiceHUDStatus(nextPayload.status)
    );
  if (!shouldShow) {
    const activeCapturePayload = activeVoiceCaptureHUDPayload();
    if (activeCapturePayload) {
      debugLog("voice HUD hide ignored (non-visible status) while native capture is active");
      return updateVoiceHUD(activeCapturePayload);
    }
    pendingVoiceHUDPayload = null;
    lastLiveVoiceHUDSnapshot = null;
    voiceHUDWindow?.hide();
    voiceHUDPresentationKey = "";
    updateMenuBarVoiceStatus({ visible: false, status: "idle" });
    return { ok: true, visible: false };
  }
  if (shouldSuppressFloatingVoiceHUD(nextPayload)) {
    const activeCapturePayload = activeVoiceCaptureHUDPayload();
    if (activeCapturePayload) {
      debugLog("voice HUD app-focus suppression ignored while native capture is active");
      return updateVoiceHUD(activeCapturePayload);
    }
    // Focus flaps during live sessions get the same debounce as idle blips.
    if (liveHUDOnScreen && isLiveVoiceHUDStatus(nextPayload.status)) {
      pendingVoiceHUDPayload = storedVoiceHUDPayload(nextPayload);
      if (!voiceHUDLiveHideTimer) {
        voiceHUDLiveHideTimer = setTimeout(() => {
          voiceHUDLiveHideTimer = null;
          clearVoiceHUDAutoHide();
          voiceHUDWindow?.hide();
          voiceHUDPresentationKey = "";
        }, 450);
        voiceHUDLiveHideTimer.unref?.();
      }
      updateMenuBarVoiceStatus(nextPayload);
      return { ok: true, visible: false };
    }
    clearVoiceHUDAutoHide();
    pendingVoiceHUDPayload = storedVoiceHUDPayload(nextPayload);
    voiceHUDWindow?.hide();
    voiceHUDPresentationKey = "";
    updateMenuBarVoiceStatus(nextPayload);
    return { ok: true, visible: false };
  }
  const window = ensureVoiceHUDWindow();
  pendingVoiceHUDPayload = storedVoiceHUDPayload(nextPayload);
  rememberLiveVoiceHUDSnapshot(nextPayload);
  updateMenuBarVoiceStatus(nextPayload);
  if (!isLevelOnlyUpdate) {
    // Only re-position / re-show when the status or panel size actually
    // changed. Live Voice pushes a full payload every ~120ms; calling
    // setBounds + showInactive on every tick made the HUD visibly glitch
    // while the assistant was talking.
    const size = voiceHUDSize(nextPayload);
    // Key on size + interactivity, NOT raw status: live-listening and
    // live-speaking flip every turn and must not trigger a re-present.
    const presentationKey = `${isInteractiveVoiceHUDStatus(nextPayload.status) ? "i" : "p"}|${nextPayload.status === "analyzing-input" ? "focus" : "plain"}|${nextPayload.dictationCapture ? "dict" : "plain"}|${size.width}x${size.height}`;
    const alreadyPresented = window.isVisible() && voiceHUDPresentationKey === presentationKey;
    if (!alreadyPresented) {
      voiceHUDPresentationKey = presentationKey;
      positionVoiceHUDWindow(window, nextPayload);
      // setFocusable/setIgnoreMouseEvents rebuild the NSPanel style mask on
      // macOS, which makes the window blink out and back in. Only touch them
      // when interactivity actually changes.
      const interactiveHUD = isInteractiveVoiceHUDStatus(nextPayload.status);
      if (voiceHUDInteractiveApplied !== interactiveHUD) {
        voiceHUDInteractiveApplied = interactiveHUD;
        window.setIgnoreMouseEvents(!interactiveHUD);
        window.setFocusable(interactiveHUD);
      }
      if (nextPayload.status === "analyzing-input") {
        window.show();
        window.focus();
        window.moveTop();
      } else if (!window.isVisible()) {
        window.showInactive();
      }
    }
  }
  if (!voiceHUDReady) return { ok: true, visible: true, pending: true };
  await window.webContents.executeJavaScript(
    `window.updateOpenAssistVoiceHUD(${JSON.stringify({
      status: nextPayload.status,
      text: nextPayload.text ?? "",
      theme: nextPayload.theme ?? "Vibrant Spectrum",
      colorTheme: nextPayload.colorTheme ?? "Ocean",
      chromeStyle: nextPayload.chromeStyle ?? "Liquid Glass",
      level: nextPayload.level ?? 0,
      tone: nextPayload.tone ?? (nextPayload.status === "error" || nextPayload.status === "unsupported" ? "error" : "success"),
      source: nextPayload.source ?? "",
      replacement: nextPayload.replacement ?? "",
      previewDataURL: nextPayload.previewDataURL ?? "",
      providerLabel: nextPayload.providerLabel ?? "",
      userText: nextPayload.userText ?? "",
      assistantText: nextPayload.assistantText ?? "",
      workText: nextPayload.workText ?? "",
      muted: nextPayload.muted === true,
      approval: nextPayload.approval ?? null,
      dictationCapture: nextPayload.dictationCapture === true,
      dictationLevel: nextPayload.dictationLevel ?? 0,
      // The orb follows the user's "Realtime & Snip Glow Color" preset.
      glowColors: screenAnalysisPalette()
    })})`
  );
  if (!isLevelOnlyUpdate && isInteractiveVoiceHUDStatus(nextPayload.status) && voiceHUDInteractiveApplied !== true) {
    voiceHUDInteractiveApplied = true;
    window.setIgnoreMouseEvents(false);
    window.setFocusable(true);
  }
  if (!isLevelOnlyUpdate) {
    scheduleVoiceHUDAutoHide(nextPayload);
  }
  return { ok: true, visible: true };
}

function acceleratorKeyForMacCode(keyCode: number) {
  const letterCodes: Record<number, string> = {
    0: "A",
    1: "S",
    2: "D",
    3: "F",
    4: "H",
    5: "G",
    6: "Z",
    7: "X",
    8: "C",
    9: "V",
    11: "B",
    12: "Q",
    13: "W",
    14: "E",
    15: "R",
    16: "Y",
    17: "T",
    31: "O",
    32: "U",
    34: "I",
    35: "P",
    37: "L",
    38: "J",
    40: "K",
    45: "N",
    46: "M"
  };
  const digitCodes: Record<number, string> = {
    18: "1",
    19: "2",
    20: "3",
    21: "4",
    22: "6",
    23: "5",
    25: "9",
    26: "7",
    28: "8",
    29: "0"
  };
  const functionCodes: Record<number, string> = {
    64: "F17",
    79: "F18",
    80: "F19",
    90: "F20",
    96: "F5",
    97: "F6",
    98: "F7",
    99: "F3",
    100: "F8",
    101: "F9",
    103: "F11",
    105: "F13",
    106: "F16",
    107: "F14",
    109: "F10",
    111: "F12",
    113: "F15",
    118: "F4",
    120: "F2",
    122: "F1"
  };
  if (keyCode === 36) return "Enter";
  if (keyCode === 49) return "Space";
  if (keyCode === 51) return "Backspace";
  if (keyCode === 53) return "Escape";
  return letterCodes[keyCode] ?? digitCodes[keyCode] ?? functionCodes[keyCode];
}

function acceleratorFromShortcut(keyCode: number, modifiers: number) {
  if (keyCode === manualModifierOnlyKeyCode || (modifiers & shortcutModifierFlags.fn)) return undefined;
  const key = acceleratorKeyForMacCode(keyCode);
  if (!key) return undefined;
  const parts: string[] = [];
  if (modifiers & shortcutModifierFlags.command) parts.push("Command");
  if (modifiers & shortcutModifierFlags.control) parts.push("Control");
  if (modifiers & shortcutModifierFlags.option) parts.push("Alt");
  if (modifiers & shortcutModifierFlags.shift) parts.push("Shift");
  if (parts.length === 0) return undefined;
  parts.push(key);
  return parts.join("+");
}

function shortcutBindingsForSettings(settings: ShortcutSettingsSnapshot) {
  return [
    {
      target: "holdToTalk",
      keyCode: settings.holdToTalkShortcutKeyCode,
      modifiers: settings.holdToTalkShortcutModifiers
    },
    {
      target: "continuousToggle",
      keyCode: settings.continuousToggleShortcutKeyCode,
      modifiers: settings.continuousToggleShortcutModifiers
    },
    {
      target: "assistantLiveVoice",
      keyCode: settings.assistantLiveVoiceShortcutKeyCode,
      modifiers: settings.assistantLiveVoiceShortcutModifiers
    },
    {
      target: "assistantCompact",
      keyCode: settings.assistantCompactShortcutKeyCode,
      modifiers: settings.assistantCompactShortcutModifiers
    },
    {
      target: "screenAnalysis",
      keyCode: settings.screenAnalysisShortcutKeyCode,
      modifiers: settings.screenAnalysisShortcutModifiers
    }
  ] satisfies Array<{ target: ShortcutTarget; keyCode: number; modifiers: number }>;
}

function handleConfiguredShortcut(target: ShortcutTarget, phase: ShortcutPhase = "trigger") {
  if (target === "screenAnalysis") {
    if (phase !== "up") void triggerScreenAnalysis();
    return;
  }
  if (target === "assistantCompact") {
    if (phase !== "up") toggleMainWindowVisibility();
    return;
  }
  const isVoiceTranscriptionShortcut = target === "holdToTalk" || target === "continuousToggle";
  const hadMainWindow = Boolean(mainWindow && !mainWindow.isDestroyed());
  if (!mainWindow) {
    createMainWindow({ initiallyHidden: isVoiceTranscriptionShortcut || target === "assistantLiveVoice" });
  }
  const window = mainWindow;
  if (!window || window.isDestroyed()) return;
  const sendShortcut = () => {
    safeSendWindow(window, "openassist:voice-shortcut", target, phase);
  };
  const sendWhenReady = () => {
    if (window.webContents.isLoading()) {
      window.webContents.once("did-finish-load", () => setTimeout(sendShortcut, 20));
    } else {
      setTimeout(sendShortcut, 20);
    }
  };
  if (
    isVoiceTranscriptionShortcut
    && phase !== "up"
    && hadMainWindow
    && !window.webContents.isLoading()
    && !shouldSuppressFloatingVoiceHUD({ status: "listening" })
    // Respect the floating HUD setting: without this the pill flashes for a
    // second and is then hidden by the renderer when the HUD is disabled.
    && readNativeBoolDefaultSync("OpenAssist.assistantFloatingHUDEnabled", true)
  ) {
    void updateVoiceHUD({ visible: true, status: "listening", ...lastVoiceHUDAppearance });
  }
  sendWhenReady();
}

function unregisterConfiguredShortcuts() {
  for (const accelerator of registeredAssistantAccelerators) {
    globalShortcut.unregister(accelerator);
  }
  registeredAssistantAccelerators.clear();
}

function registerConfiguredShortcuts(settings: ShortcutSettingsSnapshot) {
  unregisterConfiguredShortcuts();
  const shortcuts = shortcutBindingsForSettings(settings);
  for (const shortcut of shortcuts) {
    if (shouldUseShortcutMonitor(shortcut)) continue;
    const accelerator = acceleratorFromShortcut(shortcut.keyCode, shortcut.modifiers);
    if (!accelerator || registeredAssistantAccelerators.has(accelerator)) continue;
    const didRegister = globalShortcut.register(accelerator, () => handleConfiguredShortcut(shortcut.target));
    if (didRegister) {
      registeredAssistantAccelerators.add(accelerator);
    } else {
      debugLog(`could not register shortcut ${shortcut.target} accelerator=${accelerator}`);
    }
  }
  void refreshShortcutMonitor(shortcuts);
}

function shouldUseShortcutMonitor(shortcut: { target: ShortcutTarget; keyCode: number; modifiers: number }) {
  if (process.platform !== "darwin") return false;
  return shortcut.keyCode === manualModifierOnlyKeyCode
    || shortcut.target === "holdToTalk"
    || shortcut.target === "assistantLiveVoice";
}

function isShortcutTarget(value: unknown): value is ShortcutTarget {
  return typeof value === "string" && shortcutTargets.includes(value as ShortcutTarget);
}

function shortcutMonitorHelperSourcePath() {
  const candidates = [
    path.join(app.getAppPath(), "electron", "helpers", "shortcut-monitor-helper.swift"),
    path.join(process.cwd(), "electron", "helpers", "shortcut-monitor-helper.swift"),
    path.join(openAssistRepoRoot(), "electron-react", "electron", "helpers", "shortcut-monitor-helper.swift")
  ];
  return candidates.find((candidate) => fs.existsSync(candidate));
}

async function ensureShortcutMonitorHelper() {
  const sourcePath = shortcutMonitorHelperSourcePath();
  if (!sourcePath) throw new Error("Shortcut monitor helper source was not found.");
  const helperDirectory = path.join(app.getPath("userData"), "helpers", "Open Assist Shortcut Monitor");
  const helperPath = path.join(helperDirectory, "shortcut-monitor-helper");
  const sourceStat = fs.statSync(sourcePath);
  const helperStat = fs.existsSync(helperPath) ? fs.statSync(helperPath) : null;
  if (!helperStat || helperStat.mtimeMs < sourceStat.mtimeMs) {
    fs.mkdirSync(helperDirectory, { recursive: true });
    await runProcess("/usr/bin/swiftc", ["-framework", "AppKit", sourcePath, "-o", helperPath]);
    fs.chmodSync(helperPath, 0o755);
    try {
      await runProcess("/usr/bin/codesign", ["--force", "--sign", "-", helperPath]);
    } catch {
      // The shortcut monitor can still run ad-hoc during local development.
    }
  }
  return helperPath;
}

function stopShortcutMonitor() {
  const processToStop = shortcutMonitorProcess;
  shortcutMonitorProcess = null;
  if (processToStop && !processToStop.killed) {
    processToStop.kill();
  }
}

function handleShortcutMonitorLine(line: string) {
  const trimmed = line.trim();
  if (!trimmed) return;
  try {
    const payload = JSON.parse(trimmed) as { target?: unknown; phase?: unknown; status?: unknown; error?: unknown };
    if (payload.status) {
      debugLog(`shortcut monitor status=${String(payload.status)}`);
      return;
    }
    if (!isShortcutTarget(payload.target)) return;
    const phase: ShortcutPhase = payload.phase === "down" || payload.phase === "up" ? payload.phase : "trigger";
    handleConfiguredShortcut(payload.target, phase);
  } catch (error) {
    debugLog(`shortcut monitor parse failed: ${error instanceof Error ? error.message : String(error)} line=${trimmed}`);
  }
}

async function refreshShortcutMonitor(shortcuts: Array<{ target: ShortcutTarget; keyCode: number; modifiers: number }>) {
  const generation = ++shortcutMonitorGeneration;
  stopShortcutMonitor();
  if (process.platform !== "darwin") return;
  const monitoredShortcuts = shortcuts.filter(
    (shortcut) => shouldUseShortcutMonitor(shortcut) && shortcut.modifiers !== 0
  );
  if (monitoredShortcuts.length === 0) return;

  try {
    const helperPath = await ensureShortcutMonitorHelper();
    if (generation !== shortcutMonitorGeneration) return;
    const helperDirectory = path.join(app.getPath("userData"), "helpers", "Open Assist Shortcut Monitor");
    const configPath = path.join(helperDirectory, "shortcut-monitor-config.json");
    fs.mkdirSync(helperDirectory, { recursive: true });
    fs.writeFileSync(
      configPath,
      JSON.stringify({ shortcuts: monitoredShortcuts }, null, 2),
      "utf8"
    );
    const child = spawn(helperPath, [configPath], { stdio: ["ignore", "pipe", "pipe"] });
    shortcutMonitorProcess = child;
    let stdoutBuffer = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdoutBuffer += chunk;
      const lines = stdoutBuffer.split(/\r?\n/);
      stdoutBuffer = lines.pop() ?? "";
      for (const line of lines) handleShortcutMonitorLine(line);
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      const message = String(chunk).trim();
      if (message) debugLog(`shortcut monitor stderr: ${message}`);
    });
    child.on("error", (error) => {
      if (shortcutMonitorProcess === child) shortcutMonitorProcess = null;
      debugLog(`shortcut monitor failed: ${error instanceof Error ? error.message : String(error)}`);
    });
    child.on("close", (code, signal) => {
      if (shortcutMonitorProcess === child) shortcutMonitorProcess = null;
      if (generation === shortcutMonitorGeneration) {
        debugLog(`shortcut monitor closed code=${code ?? "null"} signal=${signal ?? "null"}`);
      }
    });
  } catch (error) {
    debugLog(`shortcut monitor setup failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
  }
}

async function refreshConfiguredShortcuts() {
  try {
    const state = await (await openAssistBridge()).loadOpenAssistSettingsAppState();
    registerConfiguredShortcuts(state.settings);
  } catch (error) {
    debugLog(`shortcut refresh failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
  }
}

let lastCapturedImageBuffer: Buffer | null = null;
let lastCapturedScreenRect: ScreenRect | null = null;
let lastCapturedPreviewDataURL = "";
let lastScreenAnalysisReferenceImages: Array<{ name: string; data: Buffer; mimeType: string; previewDataURL: string }> = [];
// Conversation turns for the current capture: the user can keep asking
// follow-up questions about the same screenshot until the HUD is closed.
let screenAnalysisConversation: Array<{ role: "user" | "assistant"; text: string }> = [];
// Images generated during this capture's conversation, carried into follow-up
// turns as references so the user can iterate ("make the background darker").
let screenAnalysisGeneratedImageRefs: Array<{ name: string; data: Buffer; mimeType: string }> = [];
// Set when the user drags/resizes the HUD panel; status changes then keep its
// position/size instead of snapping back next to the capture rect.
let screenAnalysisUserMovedPanel = false;
let screenAnalysisUserResizedPanel = false;
// Skills the user attached via the "+" menu for this capture's conversation.
let screenAnalysisSelectedSkills: Array<{ id: string; title: string }> = [];

function screenAnalysisGeneratedRefsFromImages(images: ScreenAnalysisGeneratedImage[]) {
  return images.slice(-2).flatMap((image, index) => {
    const match = /^data:(.+?);base64,(.+)$/.exec(image?.dataURL ?? "");
    if (!match) return [];
    return [{
      name: image.name || `Generated image ${index + 1}`,
      data: Buffer.from(match[2], "base64"),
      mimeType: match[1] || "image/png"
    }];
  });
}
let screenAnalysisBufferEvictionTimer: NodeJS.Timeout | null = null;

// A 4K screenshot is ~10-20 MB and reference images stack up to 4. They live
// in the main process as raw Buffers forever after a single screen-analysis
// session. We evict 30 s after the session goes idle so a long-running
// app's main RSS doesn't carry them indefinitely.
function scheduleScreenAnalysisBufferEviction() {
  if (screenAnalysisBufferEvictionTimer) {
    clearTimeout(screenAnalysisBufferEvictionTimer);
  }
  screenAnalysisBufferEvictionTimer = setTimeout(() => {
    screenAnalysisBufferEvictionTimer = null;
    if (screenAnalysisStatus !== "idle") return;
    if (
      lastCapturedImageBuffer ||
      lastCapturedPreviewDataURL ||
      lastScreenAnalysisReferenceImages.length > 0
    ) {
      debugLog(
        `screen analysis buffer eviction: image=${lastCapturedImageBuffer ? lastCapturedImageBuffer.length : 0}B refs=${lastScreenAnalysisReferenceImages.length}`
      );
    }
    lastCapturedImageBuffer = null;
    lastCapturedScreenRect = null;
    lastCapturedPreviewDataURL = "";
    lastScreenAnalysisReferenceImages = [];
    screenAnalysisConversation = [];
    screenAnalysisGeneratedImageRefs = [];
  }, 30_000);
  screenAnalysisBufferEvictionTimer.unref?.();
}

function cancelScreenAnalysisBufferEviction() {
  if (!screenAnalysisBufferEvictionTimer) return;
  clearTimeout(screenAnalysisBufferEvictionTimer);
  screenAnalysisBufferEvictionTimer = null;
}
let screenAnalysisRunID = 0;
let pendingScreenSelectionResolve: ((rect: ScreenRect) => void) | null = null;
let pendingScreenSelectionReject: ((error: Error) => void) | null = null;

function captureScreen(interactive = false): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const tempPath = path.join(os.tmpdir(), `screenshot-${Date.now()}.png`);
    const args = interactive ? ["-i", "-x", tempPath] : ["-x", tempPath];
    execFile("/usr/sbin/screencapture", args, (error) => {
      fs.readFile(tempPath, (readError, data) => {
        // delete temp file in background
        fs.unlink(tempPath, () => {});
        if (error) {
          reject(new Error(`Failed to capture screen: ${error.message}`));
          return;
        }
        if (readError) {
          reject(new Error(`Failed to read captured screen: ${readError.message}`));
          return;
        }
        if (!data.length) {
          reject(new Error("The captured screenshot was empty. Please try again."));
          return;
        }
        resolve(data);
      });
    });
  });
}

function allDisplayBounds(): ScreenRect {
  const displays = screen.getAllDisplays();
  if (!displays.length) {
    const { bounds } = screen.getPrimaryDisplay();
    return bounds;
  }
  const minX = Math.min(...displays.map((display) => display.bounds.x));
  const minY = Math.min(...displays.map((display) => display.bounds.y));
  const maxX = Math.max(...displays.map((display) => display.bounds.x + display.bounds.width));
  const maxY = Math.max(...displays.map((display) => display.bounds.y + display.bounds.height));
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}

function displayBoundsForRect(rect: ScreenRect): ScreenRect {
  return screen.getDisplayMatching(rect).bounds;
}

function displayBoundsUnderMouse(): ScreenRect {
  return screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).bounds;
}

function normalizeScreenRect(rect: ScreenRect): ScreenRect {
  const x = Math.round(rect.width < 0 ? rect.x + rect.width : rect.x);
  const y = Math.round(rect.height < 0 ? rect.y + rect.height : rect.y);
  const width = Math.round(Math.abs(rect.width));
  const height = Math.round(Math.abs(rect.height));
  return { x, y, width, height };
}

function rectCenterInsideBounds(rect: ScreenRect, bounds: ScreenRect) {
  const centerX = rect.x + rect.width / 2;
  const centerY = rect.y + rect.height / 2;
  return (
    centerX >= bounds.x &&
    centerX <= bounds.x + bounds.width &&
    centerY >= bounds.y &&
    centerY <= bounds.y + bounds.height
  );
}

function intersectScreenRect(rect: ScreenRect, bounds: ScreenRect): ScreenRect {
  const left = Math.max(rect.x, bounds.x);
  const top = Math.max(rect.y, bounds.y);
  const right = Math.min(rect.x + rect.width, bounds.x + bounds.width);
  const bottom = Math.min(rect.y + rect.height, bounds.y + bounds.height);
  return {
    x: Math.round(left),
    y: Math.round(top),
    width: Math.max(0, Math.round(right - left)),
    height: Math.max(0, Math.round(bottom - top))
  };
}

function captureScreenRect(rect: ScreenRect): Promise<Buffer> {
  const normalized = normalizeScreenRect(rect);
  return new Promise((resolve, reject) => {
    const tempPath = path.join(os.tmpdir(), `openassist-screen-analysis-${Date.now()}.png`);
    const region = `${normalized.x},${normalized.y},${normalized.width},${normalized.height}`;
    debugLog(`screencapture region=${region}`);
    execFile("/usr/sbin/screencapture", ["-x", "-R", region, tempPath], (error, _stdout, stderr) => {
      fs.readFile(tempPath, (readError, data) => {
        fs.unlink(tempPath, () => {});
        if (error) {
          const detail = stderr ? stderr.toString().trim() : error.message;
          debugLog(`screencapture failed region=${region} stderr=${detail}`);
          reject(new Error(`Failed to capture selected area (${region}): ${detail || error.message}`));
          return;
        }
        if (readError) {
          reject(new Error(`Failed to read selected screenshot: ${readError.message}`));
          return;
        }
        if (!data.length) {
          reject(new Error("The selected screenshot was empty. Please try again."));
          return;
        }
        resolve(data);
      });
    });
  });
}

function mimeTypeForImagePath(filePath: string) {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === ".jpg" || ext === ".jpeg") return "image/jpeg";
  if (ext === ".webp") return "image/webp";
  if (ext === ".gif") return "image/gif";
  return "image/png";
}

const screenSnipPalettes: Record<string, string[]> = {
  "match-voice-hud": [],
  "prism": ["#4285F4", "#EA4335", "#FBBC05", "#34A853"],
  "aurora": ["#5ee7ff", "#5e8bff", "#a55eff", "#ff5ee0"],
  "sunset": ["#ff9a3d", "#ff5e8a", "#c459ff", "#5b8bff"],
  "cyberpunk": ["#00f0ff", "#ff00d4", "#ffea00", "#7700ff"],
  "mint-glow": ["#43e8a4", "#6ff0d6", "#5cdcff", "#7a9cff"],
  "ocean-glow": ["#3cb1ff", "#5e7dff", "#5ee0d8", "#6effb5"],
  "ember": ["#ff5630", "#ff8a4c", "#ffd166", "#ff7ab6"],
  "lavender-haze": ["#b287ff", "#9b6cff", "#7a8bff", "#5ed1ff"],
  "vibrant-spectrum": ["#4f8fe8", "#a363b7", "#df4546", "#ddb52d", "#39a268"],
  "professional-tech": ["#78b7ff", "#837bff", "#55d0c0", "#69d58c"],
  "monochrome": ["#d8dbe0", "#bdc2ca", "#8d949e", "#f2f4f7"],
  "openai-horizon": ["#1f6fff", "#5fb7ff", "#86e0d6", "#f2efe8"],
  "openai-emotive": ["#2764ff", "#58d1ff", "#b7c7ff", "#f7f2ea"],
  "openai-bloom": ["#2dd4bf", "#73d6ff", "#9f8cff", "#f4efe6"],
  "openai-sky": ["#3a7dff", "#6fd3ff", "#b8e6ff", "#fff4d8"],
  "gpt-5-5-thinking": ["#3157ff", "#6f7dff", "#a685ff", "#f1eaff"],
  "gpt-5-5-pro": ["#2447d8", "#4a9fff", "#7ee7d8", "#fff0c7"],
  "codex-blueprint": ["#3f7dff", "#70b7ff", "#c6e2ff", "#f7fbff"],
  "codex-agent": ["#4d8dff", "#5fd3ff", "#55e0bd", "#eef7ff"],
  "neon-lagoon": ["#74d5ff", "#54e3da", "#56edb2", "#91ef78"],
  "sunset-candy": ["#6e8dff", "#d45a8b", "#ef4b55", "#ebb934"],
  "cosmic-pop": ["#58a9ff", "#945fe3", "#eb4b82", "#f27d3a"],
  "mint-blush": ["#6fa7ff", "#c175b7", "#ef6f7f", "#5bca95"]
};

const screenSnipPaletteLabels: Record<string, string> = {
  "match-voice-hud": "Match Voice HUD",
  "openai-horizon": "OpenAI Horizon",
  "openai-emotive": "OpenAI Emotive",
  "openai-bloom": "OpenAI Bloom",
  "openai-sky": "OpenAI Sky",
  "gpt-5-5-thinking": "GPT-5.5 Thinking",
  "gpt-5-5-pro": "GPT-5.5 Pro",
  "codex-blueprint": "Codex Blueprint",
  "codex-agent": "Codex Agent"
};

const screenAnalysisAppThemePalettes: Record<string, string[]> = {
  ocean: ["#8fb0ff", "#72d99d", "#0b0c0e"],
  violet: ["#aab2ff", "#b1a3ff", "#15101d"],
  midnight: ["#6f9dff", "#a9c4ff", "#101218"],
  forest: ["#70c894", "#a9edc2", "#0d1712"],
  rose: ["#e490ac", "#ffc0d0", "#1b1118"],
  sunset: ["#e0a14f", "#ffd18a", "#18120c"],
  arctic: ["#90d7ec", "#c5f5ff", "#101821"],
  slate: ["#6f9dff", "#a9c4ff", "#101218"],
  amethyst: ["#b696ff", "#d8c8ff", "#121022"],
  "noir-gold": ["#a87f2d", "#c79d42", "#080806"]
};

function screenSnipPresetPath() {
  try {
    return path.join(app.getPath("userData"), "screen-snip-theme.json");
  } catch {
    return path.join(os.tmpdir(), "openassist-screen-snip-theme.json");
  }
}

let cachedScreenSnipTheme: string | null = null;

function readScreenSnipTheme(): string {
  if (cachedScreenSnipTheme !== null) return cachedScreenSnipTheme;
  try {
    const raw = fs.readFileSync(screenSnipPresetPath(), "utf8");
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed.theme === "string") {
      const stored: string = parsed.theme;
      cachedScreenSnipTheme = stored;
      return stored;
    }
  } catch {
    // file missing or unreadable — fall through
  }
  cachedScreenSnipTheme = "match-voice-hud";
  return cachedScreenSnipTheme;
}

function writeScreenSnipTheme(theme: string) {
  cachedScreenSnipTheme = theme;
  try {
    fs.writeFileSync(screenSnipPresetPath(), JSON.stringify({ theme }), "utf8");
  } catch (error) {
    debugLog(`could not save screen snip theme: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function normalizePaletteKey(key?: string) {
  return String(key || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

function screenAnalysisPalette(_theme?: string) {
  const userKey = normalizePaletteKey(readScreenSnipTheme());
  if (
    userKey
    && userKey !== "match-voice-hud"
    && userKey !== "prism"
    && screenSnipPalettes[userKey]
    && screenSnipPalettes[userKey].length
  ) {
    return screenSnipPalettes[userKey];
  }
  const [accent, skill, background, foreground] = screenAnalysisCurrentThemeColors();
  return [accent, skill, foreground, background];
}

function screenAnalysisAppThemePalette(theme?: string) {
  const themeKey = normalizePaletteKey(theme || lastVoiceHUDAppearance.colorTheme || "Ocean");
  return screenAnalysisAppThemePalettes[themeKey] ?? screenAnalysisAppThemePalettes.ocean;
}

function screenAnalysisCurrentThemeColors() {
  const appearance = menuBarPopoverAppearance();
  return [appearance.accent, appearance.skill, appearance.background, appearance.foreground];
}

function listScreenSnipPresets() {
  return Object.entries(screenSnipPalettes).map(([key, colors]) => ({
    key,
    label: screenSnipPaletteLabels[key]
      ?? key.split("-").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" "),
    colors: colors.length ? colors : ["#4f8fe8", "#a363b7", "#df4546", "#ddb52d"]
  }));
}

function screenSelectionHTML(colors: string[]) {
  const palette = (colors && colors.length ? colors : ["#4f8fe8", "#a363b7", "#df4546", "#ddb52d"]).slice(0, 4);
  while (palette.length < 4) palette.push(palette[palette.length - 1]);
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<style>
html, body, #root {
  width: 100%;
  height: 100%;
  margin: 0;
  overflow: hidden;
  cursor: crosshair;
  user-select: none;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
  --c1: ${palette[0]};
  --c2: ${palette[1]};
  --c3: ${palette[2]};
  --c4: ${palette[3]};
}
body {
  background: rgba(5, 7, 10, 0.07);
}
.hint {
  position: fixed;
  top: 20px;
  left: 50%;
  transform: translateX(-50%);
  padding: 9px 16px;
  border-radius: 999px;
  background:
    linear-gradient(155deg, rgba(255,255,255,0.10), rgba(255,255,255,0.02) 55%),
    rgba(15, 18, 24, 0.82);
  border: 1px solid rgba(255,255,255,0.16);
  color: rgba(255,255,255,0.90);
  font-size: 12px;
  font-weight: 720;
  letter-spacing: 0.01em;
  box-shadow:
    inset 0 1px 0 rgba(255,255,255,0.16),
    0 14px 34px rgba(0,0,0,0.34);
  pointer-events: none;
}
.box {
  position: fixed;
  display: none;
  border-radius: 12px;
  border: 1px solid color-mix(in srgb, var(--c1) 60%, white 16%);
  background: linear-gradient(155deg, rgba(255,255,255,0.05), transparent 45%);
  pointer-events: none;
  box-shadow:
    0 0 0 9999px rgba(0, 0, 0, 0.16),
    inset 0 1px 0 rgba(255,255,255,0.18),
    inset 0 0 0 1px rgba(255,255,255,0.05),
    0 0 10px color-mix(in srgb, var(--c1) 22%, transparent),
    0 0 20px color-mix(in srgb, var(--c2) 12%, transparent);
}
</style>
</head>
<body>
<div class="hint">Drag to select an area for screen analysis</div>
<div class="box" id="box"></div>
<script>
	  const box = document.getElementById("box");
let start = null;
let dragging = false;
function rectFromEvent(event) {
  const x = Math.min(start.x, event.clientX);
  const y = Math.min(start.y, event.clientY);
  const width = Math.abs(event.clientX - start.x);
  const height = Math.abs(event.clientY - start.y);
  return { x, y, width, height };
}
function draw(rect) {
  box.style.display = "block";
  box.style.left = rect.x + "px";
  box.style.top = rect.y + "px";
  box.style.width = rect.width + "px";
  box.style.height = rect.height + "px";
}
document.addEventListener("pointerdown", (event) => {
  dragging = true;
  start = { x: event.clientX, y: event.clientY };
  draw({ x: start.x, y: start.y, width: 1, height: 1 });
});
document.addEventListener("pointermove", (event) => {
  if (!dragging || !start) return;
  draw(rectFromEvent(event));
});
document.addEventListener("pointerup", (event) => {
  if (!dragging || !start) return;
  dragging = false;
  const rect = rectFromEvent(event);
  if (rect.width < 12 || rect.height < 12) {
    box.style.display = "none";
    start = null;
    return;
  }
	  window.openAssistElectron.completeScreenSelection({
	    coordinateSpace: "window",
	    x: rect.x,
	    y: rect.y,
	    width: rect.width,
	    height: rect.height
	  });
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") window.openAssistElectron.cancelScreenSelection();
});
</script>
</body>
</html>`;
}

function screenAnalysisHTML() {
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<title>Open Assist Screen Analysis</title>
<style>
html, body, #root {
  width: 100%;
  height: 100%;
  margin: 0;
  overflow: hidden;
  background: transparent;
  color: rgba(246, 248, 252, 0.94);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Inter", sans-serif;
}
* { box-sizing: border-box; }
.panel {
  position: absolute;
  width: 540px;
  min-height: 140px;
  /* The BrowserWindow is sized per status (380 for text results, 470 with
     generated images) — track it instead of hard-coding one height. */
  max-height: calc(100vh - 4px);
  border-radius: 18px;
  /* Glass look via specular highlights on a near-opaque base. Electron
     transparent windows cannot backdrop-blur the desktop behind them, so any
     real see-through shows sharp desktop content and hurts readability —
     keep the base ~solid and let the sheen sell the glass. */
  background:
    linear-gradient(155deg, rgba(255,255,255,0.10), rgba(255,255,255,0.028) 34%, rgba(255,255,255,0.0) 58%, rgba(255,255,255,0.035)),
    radial-gradient(140% 90% at 50% -20%, color-mix(in srgb, var(--theme-accent) 7%, transparent), transparent 60%),
    color-mix(in srgb, var(--theme-base) 97%, transparent);
  border: 1px solid rgba(255,255,255,0.15);
  box-shadow:
    inset 0 1px 0 rgba(255,255,255,0.20),
    inset 0 -1px 0 rgba(255,255,255,0.045),
    inset 0 0 0 1px rgba(255,255,255,0.03);
  padding: 12px 12px 10px;
  display: flex;
  flex-direction: column;
  gap: 10px;
  -webkit-font-smoothing: antialiased;
  backdrop-filter: blur(28px) saturate(1.3);
  -webkit-backdrop-filter: blur(28px) saturate(1.3);
}
::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}
::-webkit-scrollbar-track {
  background: transparent;
}
::-webkit-scrollbar-thumb {
  background: linear-gradient(180deg,
    color-mix(in srgb, var(--theme-accent) 54%, transparent),
    color-mix(in srgb, var(--theme-skill) 46%, transparent));
  border-radius: 999px;
  border: 2px solid transparent;
  background-clip: padding-box;
}
::-webkit-scrollbar-thumb:hover {
  background: linear-gradient(180deg,
    color-mix(in srgb, var(--theme-accent) 72%, transparent),
    color-mix(in srgb, var(--theme-skill) 58%, transparent));
  background-clip: padding-box;
}
.header {
  display: flex;
  align-items: center;
  gap: 9px;
  min-height: 24px;
  -webkit-app-region: drag;
  cursor: move;
}
.title-text {
  font-size: 12.5px;
  font-weight: 720;
  letter-spacing: 0.01em;
  color: rgba(255,255,255,0.88);
  flex: 1 1 auto;
  min-width: 0;
}
.header-actions {
  display: flex;
  align-items: center;
  gap: 5px;
  -webkit-app-region: no-drag;
}
.header-tool-btn {
  width: 24px;
  height: 24px;
  border-radius: 7px;
  border: 1px solid transparent;
  background: transparent;
  color: rgba(255,255,255,0.56);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  cursor: pointer;
  transition: background 0.12s ease, color 0.12s ease, border-color 0.12s ease;
}
.header-tool-btn:hover {
  background: rgba(255,255,255,0.08);
  border-color: rgba(255,255,255,0.08);
  color: rgba(255,255,255,0.92);
}
.header-tool-btn.accent {
  color: color-mix(in srgb, var(--theme-accent) 72%, white 28%);
}
.header-tool-btn svg {
  width: 13px;
  height: 13px;
  stroke-width: 2.2;
}
.spark {
  width: 22px;
  height: 22px;
  border-radius: 6px;
  background: color-mix(in srgb, var(--theme-accent) 12%, rgba(255,255,255,0.06));
  border: 1px solid color-mix(in srgb, var(--theme-accent) 26%, rgba(255,255,255,0.10));
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--theme-accent);
  flex: 0 0 22px;
  box-shadow: none;
}
.spark svg {
  width: 13px;
  height: 13px;
  stroke-width: 2;
}
.body-row {
  display: flex;
  align-items: stretch;
  gap: 10px;
}
.screenshot-preview {
  width: 96px;
  min-height: 72px;
  flex: 0 0 96px;
  border-radius: 10px;
  overflow: hidden;
  background: rgba(255,255,255,0.06);
  border: 1px solid color-mix(in srgb, var(--theme-accent) 22%, rgba(255,255,255,0.12));
  cursor: zoom-in;
  padding: 0;
  transition: transform 0.12s ease, border-color 0.12s ease, box-shadow 0.12s ease;
}
.screenshot-preview:hover {
  transform: scale(1.02);
  border-color: color-mix(in srgb, var(--theme-accent) 52%, white 10%);
  box-shadow: none;
}
.screenshot-preview img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
  pointer-events: none;
}
.composer-col {
  position: relative;
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.attach-menu {
  position: absolute;
  top: 44px;
  left: 0;
  z-index: 30;
  min-width: 220px;
  max-height: 180px;
  overflow: auto;
  padding: 5px;
  border-radius: 10px;
  background: color-mix(in srgb, var(--theme-base) 97%, transparent);
  border: 1px solid rgba(255,255,255,0.14);
  box-shadow:
    inset 0 1px 0 rgba(255,255,255,0.10),
    0 16px 40px rgba(0,0,0,0.45);
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.attach-menu.skill-list {
  min-width: 320px;
  max-height: 400px;
  overflow: hidden;
}
.attach-menu .menu-search {
  flex: 0 0 auto;
  width: 100%;
  box-sizing: border-box;
  margin-bottom: 4px;
  padding: 7px 10px;
  font-size: 12px;
  color: #ffffff;
  background: rgba(255,255,255,0.08);
  border: 1px solid rgba(255,255,255,0.14);
  border-radius: 8px;
  outline: none;
}
.attach-menu .menu-search::placeholder {
  color: rgba(255,255,255,0.42);
}
.attach-menu .menu-search:focus {
  border-color: color-mix(in srgb, var(--theme-accent) 55%, transparent);
}
.attach-menu .menu-options {
  display: flex;
  flex-direction: column;
  gap: 2px;
  overflow: auto;
  min-height: 0;
  flex: 1 1 auto;
}
.attach-menu button {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 30px;
  padding: 0 9px;
  border: none;
  border-radius: 7px;
  background: transparent;
  color: rgba(255,255,255,0.85);
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  text-align: left;
}
.attach-menu button:hover {
  background: rgba(255,255,255,0.08);
}
.attach-menu button.selected {
  color: var(--theme-accent);
}
.attach-menu button svg {
  width: 13px;
  height: 13px;
  flex: 0 0 13px;
  stroke-width: 2;
}
.attach-menu .menu-note {
  padding: 6px 9px;
  color: rgba(255,255,255,0.4);
  font-size: 11px;
}
.reference-chip.skill-chip {
  padding-left: 7px;
  color: color-mix(in srgb, var(--theme-accent) 62%, white 38%);
}
.skill-chip-icon {
  display: inline-flex;
  align-items: center;
  color: var(--theme-accent);
}
.skill-chip-icon svg {
  width: 12px;
  height: 12px;
  stroke-width: 2;
}
.close-btn {
  width: 22px;
  height: 22px;
  border-radius: 6px;
  background: transparent;
  border: 1px solid transparent;
  color: rgba(255,255,255,0.55);
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  flex: 0 0 22px;
  padding: 0;
  transition: background 0.12s ease, color 0.12s ease;
  -webkit-app-region: no-drag;
}
.close-btn:hover {
  background: rgba(255,255,255,0.07);
  color: rgba(255,255,255,0.92);
}
.close-btn svg { width: 11px; height: 11px; stroke-width: 2.4; }
.composer {
  display: flex;
  align-items: center;
  gap: 0;
  background:
    linear-gradient(180deg, rgba(255,255,255,0.085), rgba(255,255,255,0.03));
  border: 1px solid rgba(255,255,255,0.14);
  border-radius: 12px;
  padding: 4px 4px 4px 6px;
  box-shadow: inset 0 1px 0 rgba(255,255,255,0.10);
  transition: border-color 0.15s ease, background 0.15s ease, box-shadow 0.15s ease;
  backdrop-filter: none;
  -webkit-backdrop-filter: none;
}
.composer:focus-within {
  border-color: color-mix(in srgb, var(--theme-accent) 46%, rgba(255,255,255,0.18));
  background:
    linear-gradient(180deg, rgba(255,255,255,0.10), color-mix(in srgb, var(--theme-accent) 6%, rgba(255,255,255,0.035)));
  box-shadow:
    inset 0 1px 0 rgba(255,255,255,0.12),
    0 0 0 3px color-mix(in srgb, var(--theme-accent) 14%, transparent);
}
.composer input {
  flex: 1 1 auto;
  min-width: 0;
  height: 32px;
  border: none;
  background: transparent;
  color: white;
  outline: none;
  padding: 0 8px;
  font-size: 13px;
  font-weight: 500;
}
.composer input::placeholder { color: color-mix(in srgb, var(--theme-accent) 22%, rgba(255,255,255,0.46)); }
.composer,
.screenshot-preview,
.result,
.actions,
button,
input {
  -webkit-app-region: no-drag;
}
.composer input::selection {
  background: color-mix(in srgb, var(--theme-accent) 45%, transparent);
  color: white;
}
::selection {
  background: color-mix(in srgb, var(--theme-accent) 45%, transparent);
  color: white;
}
.icon-btn {
  width: 28px;
  height: 28px;
  border-radius: 8px;
  border: none;
  background: transparent;
  color: rgba(255,255,255,0.62);
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  padding: 0;
  flex: 0 0 28px;
  transition: background 0.12s ease, color 0.12s ease;
}
.icon-btn:hover {
  background: color-mix(in srgb, var(--theme-accent) 12%, rgba(255,255,255,0.06));
  color: color-mix(in srgb, var(--theme-accent) 58%, white 42%);
}
.icon-btn svg { width: 14px; height: 14px; stroke-width: 2; }
.icon-btn:disabled { opacity: 0.45; cursor: not-allowed; }
.send-btn {
  background: color-mix(in srgb, var(--theme-accent) 12%, rgba(255,255,255,0.06));
  border: 1px solid color-mix(in srgb, var(--theme-accent) 24%, rgba(255,255,255,0.10));
  color: var(--theme-accent);
  box-shadow: none;
}
.send-btn:hover {
  background: color-mix(in srgb, var(--theme-accent) 18%, rgba(255,255,255,0.08));
  color: color-mix(in srgb, var(--theme-accent) 72%, white 28%);
}
.send-btn svg { width: 13px; height: 13px; }
.voice-toggle-btn[aria-pressed="true"] {
  color: var(--theme-accent);
  background: color-mix(in srgb, var(--theme-accent) 12%, rgba(255,255,255,0.06));
  border: 1px solid color-mix(in srgb, var(--theme-accent) 22%, rgba(255,255,255,0.10));
  box-shadow: none;
}
.voice-toggle-btn[aria-pressed="true"]:hover {
  background: color-mix(in srgb, var(--theme-accent) 18%, rgba(255,255,255,0.08));
}
.reference-row {
  display: flex;
  align-items: center;
  gap: 6px;
  min-height: 0;
}
.reference-row:empty { display: none; }
.reference-chip {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  max-width: 160px;
  height: 24px;
  padding: 2px 4px 2px 2px;
  border-radius: 7px;
  background: rgba(255,255,255,0.07);
  border: 1px solid color-mix(in srgb, var(--theme-accent) 18%, rgba(255,255,255,0.11));
  color: rgba(255,255,255,0.85);
  font-size: 10px;
  font-weight: 600;
}
.reference-chip-thumb {
  width: 18px;
  height: 18px;
  border-radius: 4px;
  border: none;
  padding: 0;
  background: transparent;
  overflow: hidden;
  cursor: zoom-in;
  flex: 0 0 18px;
  display: block;
}
.reference-chip-thumb img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
  pointer-events: none;
}
.reference-chip-thumb:hover {
  box-shadow: 0 0 0 1.5px color-mix(in srgb, var(--theme-accent) 45%, white 10%);
}
.reference-chip span {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.reference-chip-remove {
  width: 16px;
  height: 16px;
  border-radius: 5px;
  border: none;
  background: transparent;
  color: rgba(255,255,255,0.55);
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  padding: 0;
  flex: 0 0 16px;
  transition: background 0.12s ease, color 0.12s ease;
}
.reference-chip-remove svg { width: 9px; height: 9px; stroke-width: 2.6; }
.reference-chip-remove:hover {
  background: rgba(255, 120, 129, 0.18);
  color: #ff7881;
}
.hint {
  color: rgba(255,255,255,0.40);
  font-size: 10.5px;
  font-weight: 500;
  letter-spacing: 0.005em;
}
button.legacy-btn {
  height: 26px;
  border: 1px solid rgba(255,255,255,0.13);
  border-radius: 7px;
  background: rgba(255,255,255,0.07);
  color: rgba(255,255,255,0.82);
  font-size: 10.5px;
  font-weight: 700;
  padding: 0 10px;
  cursor: pointer;
}
button.legacy-btn.primary {
  color: color-mix(in srgb, var(--theme-accent) 72%, white 28%);
  border-color: color-mix(in srgb, var(--theme-accent) 28%, rgba(255,255,255,0.12));
  background: color-mix(in srgb, var(--theme-accent) 13%, rgba(255,255,255,0.07));
  box-shadow: none;
}
button.legacy-btn.primary:hover {
  background: color-mix(in srgb, var(--theme-accent) 20%, rgba(255,255,255,0.09));
  color: color-mix(in srgb, var(--theme-accent) 60%, white 40%);
}
button.legacy-btn.danger {
  color: #ff7881;
  border-color: rgba(255,120,129,0.32);
  background: rgba(255,120,129,0.08);
}
.actions {
  display: flex;
  gap: 6px;
  justify-content: flex-end;
  align-items: center;
}
.panel.is-collapsed {
  min-height: 0;
  padding-bottom: 12px;
}
.panel.is-collapsed .result,
.panel.is-collapsed .actions {
  display: none;
}
.generated-images {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: 10px;
  margin-top: 10px;
}
.generated-image-card {
  min-width: 0;
  overflow: hidden;
  border-radius: 12px;
  border: 1px solid color-mix(in srgb, var(--theme-accent) 26%, rgba(255,255,255,0.12));
  background: rgba(255,255,255,0.045);
}
.generated-image-preview {
  width: 100%;
  aspect-ratio: 16 / 10;
  border: none;
  padding: 0;
  background: rgba(255,255,255,0.04);
  cursor: zoom-in;
  display: block;
}
.generated-image-preview img {
  width: 100%;
  height: 100%;
  object-fit: contain;
  display: block;
  pointer-events: none;
}
.generated-image-actions {
  display: flex;
  gap: 6px;
  justify-content: flex-end;
  padding: 8px;
}
.generated-image-card .legacy-btn {
  height: 27px;
  font-size: 10.5px;
  padding: 0 10px;
}
.preview-modal {
  position: absolute;
  inset: 0;
  background: rgba(8, 10, 14, 0.96);
  border-radius: 18px;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 18px;
  z-index: 10;
}
.preview-modal img {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
  border-radius: 8px;
  box-shadow: 0 12px 32px rgba(0,0,0,0.45);
}
.preview-modal .close-btn {
  position: absolute;
  top: 10px;
  right: 10px;
  background: rgba(255,255,255,0.08);
}
.result {
  overflow: auto;
  line-height: 1.45;
  font-size: 13px;
  color: rgba(246,248,252,0.88);
  max-height: 290px;
  flex: 0 1 auto;
  min-height: 0;
  padding-right: 4px;
}
.follow-up-composer {
  flex: 0 0 auto;
  margin-top: 2px;
}
.follow-up-composer.thinking {
  opacity: 0.8;
}
.follow-up-composer .spinner {
  width: 13px;
  height: 13px;
}
.image-gen-placeholder {
  height: 56px;
  margin-top: 10px;
  border-radius: 10px;
  background: linear-gradient(100deg, rgba(255,255,255,0.05) 30%, rgba(255,255,255,0.13) 50%, rgba(255,255,255,0.05) 70%);
  background-size: 200% 100%;
  animation: image-gen-shimmer 1.4s ease-in-out infinite;
  box-shadow: inset 0 0 0 1px rgba(255,255,255,0.07);
}
@keyframes image-gen-shimmer {
  0% { background-position: 180% 0; }
  100% { background-position: -80% 0; }
}
/* Result view fills the window so user resizing gives the text more room. */
.panel.status-result {
  height: calc(100vh - 4px);
}
.panel.status-result .result {
  max-height: none;
  flex: 1 1 auto;
}
.result p {
  margin: 0 0 10px;
}
.result p:last-child {
  margin-bottom: 0;
}
.status {
  display: flex;
  align-items: center;
  gap: 9px;
  color: rgba(255,255,255,0.74);
  font-size: 12px;
  font-weight: 760;
}
.spinner {
  width: 14px;
  height: 14px;
  border-radius: 999px;
  border: 2px solid rgba(255,255,255,0.15);
  border-top-color: rgba(255,255,255,0.84);
  animation: hud-spin 0.78s linear infinite;
}
@keyframes hud-spin {
  to { transform: rotate(360deg); }
}
</style>
</head>
<body>
<div id="root"></div>
<script>
const root = document.getElementById("root");
let submitted = false;
function escapeText(text) {
  return String(text || "");
}
function escapeHTML(text) {
  return String(text || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
function markdownToPlainText(markdown) {
  return String(markdown || "")
    .replace(/\\r\\n/g, "\\n")
    .replace(/\\x60\\x60\\x60[a-zA-Z0-9_-]*\\n([\\s\\S]*?)\\x60\\x60\\x60/g, (_, code) => code.trim())
    .replace(/!\\[([^\\]]*)\\]\\([^)]+\\)/g, "$1")
    .replace(/\\[([^\\]]+)\\]\\([^)]+\\)/g, "$1")
    .replace(/^\\s{0,3}#{1,6}\\s+/gm, "")
    .replace(/^\\s*>\\s?/gm, "")
    .replace(/^\\s*[-*+]\\s+/gm, "• ")
    .replace(/\\*\\*([^*]+)\\*\\*/g, "$1")
    .replace(/__([^_]+)__/g, "$1")
    .replace(/\\x60([^\\x60]+)\\x60/g, "$1")
    .replace(/\\*([^*\\n]+)\\*/g, "$1")
    .replace(/_([^_\\n]+)_/g, "$1")
    .replace(/[ \\t]+\\n/g, "\\n")
    .trim();
}
function renderReadableText(text) {
  const plain = markdownToPlainText(text);
  const paragraphs = plain.split(/\\n{2,}/).filter((part) => part.trim());
  if (!paragraphs.length) return "<p>No screen analysis text was returned.</p>";
  return paragraphs
    .map((paragraph) => "<p>" + escapeHTML(paragraph).replace(/\\n/g, "<br>") + "</p>")
    .join("");
}
function update(payload) {
  const panel = payload.panel || { x: 0, y: 0 };
  const colors = payload.colors || ["#4f8fe8", "#a363b7", "#df4546", "#ddb52d"];
  const themeColors = payload.themeColors || ["#8fb0ff", "#72d99d", "#0b0c0e"];
  root.style.setProperty("--c1", colors[0] || "#4f8fe8");
  root.style.setProperty("--c2", colors[1] || "#a363b7");
  root.style.setProperty("--c3", colors[2] || "#df4546");
  root.style.setProperty("--c4", colors[3] || "#ddb52d");
  root.style.setProperty("--theme-accent", themeColors[0] || "#8fb0ff");
  root.style.setProperty("--theme-skill", themeColors[1] || "#72d99d");
  root.style.setProperty("--theme-base", themeColors[2] || "#0b0c0e");
  const status = payload.status || "prompt";
  if (status === "prompt") submitted = false;
  // Follow-up turns: keep the existing result view (size, position, previous
  // answer) and just show a thinking state + stream the new answer in place.
  if (payload.inline && status === "analyzing") {
    const existingPanel = root.querySelector(".panel");
    const existingResult = existingPanel ? existingPanel.querySelector(".result") : null;
    if (existingPanel && existingResult) {
      const followWrap = existingPanel.querySelector(".follow-up-composer");
      if (followWrap && !followWrap.classList.contains("thinking")) {
        followWrap.classList.add("thinking");
        const followInput = followWrap.querySelector("input");
        const followBtn = followWrap.querySelector("button");
        if (followInput) {
          followInput.disabled = true;
          followInput.value = "";
          followInput.placeholder = payload.text || "Thinking...";
        }
        if (followBtn) {
          followBtn.disabled = true;
          followBtn.innerHTML = '<span class="spinner"></span>';
        }
      }
      if (payload.resultText) {
        existingResult.innerHTML = renderReadableText(payload.resultText);
      }
      if (payload.mode === "image" && !existingResult.querySelector(".image-gen-placeholder")) {
        const shimmer = document.createElement("div");
        shimmer.className = "image-gen-placeholder";
        existingResult.append(shimmer);
      }
      return;
    }
  }
  root.innerHTML = "";
  const card = document.createElement("div");
  card.className = "panel status-" + status;
  card.style.left = panel.x + "px";
  card.style.top = panel.y + "px";
  // Track the window instead of a fixed pixel width so user resizes apply.
  card.style.width = "100%";
  const header = document.createElement("div");
  header.className = "header";
  const spark = document.createElement("span");
  spark.className = "spark";
  spark.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8V6a2 2 0 0 1 2-2h2"/><path d="M16 4h2a2 2 0 0 1 2 2v2"/><path d="M20 16v2a2 2 0 0 1-2 2h-2"/><path d="M8 20H6a2 2 0 0 1-2-2v-2"/><path d="M12 8.2 13 11l2.8 1-2.8 1-1 2.8-1-2.8L8.2 12l2.8-1 1-2.8z"/></svg>';
const titleText = document.createElement("span");
titleText.className = "title-text";
titleText.textContent = status === "result" ? "Screen Analysis" : status === "analyzing" ? "Analyzing screenshot" : "Ask about screenshot";
header.append(spark, titleText);

  const headerActions = document.createElement("div");
  headerActions.className = "header-actions";
  function makeHeaderButton(title, svg, extraClass) {
    const button = document.createElement("button");
    button.className = "header-tool-btn" + (extraClass ? " " + extraClass : "");
    button.type = "button";
    button.title = title;
    button.innerHTML = svg;
    return button;
  }
  if (status === "result") {
    let frameVisible = true;
    let collapsed = false;
    const restart = makeHeaderButton("Ask again at this same snip", '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg>', "accent");
    restart.addEventListener("click", () => {
      restart.disabled = true;
      window.openAssistElectron.startScreenAnalysisAtSamePlace().then((response) => {
        if (!response || !response.ok) restart.disabled = false;
      }).catch(() => {
        restart.disabled = false;
      });
    });
    const frameToggle = makeHeaderButton("Hide selected-area outline", '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>');
    frameToggle.addEventListener("click", () => {
      frameVisible = !frameVisible;
      frameToggle.title = frameVisible ? "Hide selected-area outline" : "Show selected-area outline";
      frameToggle.innerHTML = frameVisible
        ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>'
        : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="m3 3 18 18"/><path d="M10.6 10.6a3 3 0 0 0 4.2 4.2"/><path d="M9.88 4.24A10.8 10.8 0 0 1 12 4c6.5 0 10 8 10 8a18.5 18.5 0 0 1-2.7 4.02"/><path d="M6.6 6.6C3.65 8.48 2 12 2 12a18.6 18.6 0 0 0 7.7 7.38"/></svg>';
      window.openAssistElectron.setScreenAnalysisFrameVisible(frameVisible).catch(() => {});
    });
    const collapse = makeHeaderButton("Collapse result", '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="m18 15-6-6-6 6"/></svg>');
    collapse.addEventListener("click", () => {
      collapsed = !collapsed;
      card.classList.toggle("is-collapsed", collapsed);
      collapse.title = collapsed ? "Expand result" : "Collapse result";
      collapse.innerHTML = collapsed
        ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="m6 9 6 6 6-6"/></svg>'
        : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="m18 15-6-6-6 6"/></svg>';
      window.openAssistElectron.setScreenAnalysisPanelCollapsed(collapsed).catch(() => {});
    });
    headerActions.append(restart, frameToggle, collapse);
  }
  const copyCapture = makeHeaderButton("Copy screenshot to clipboard", '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg>');
  copyCapture.addEventListener("click", () => {
    window.openAssistElectron.copyScreenAnalysisCapture().then((response) => {
      copyCapture.title = response && response.ok ? "Copied!" : (response && response.error) || "Copy failed";
      copyCapture.classList.add("accent");
      setTimeout(() => {
        copyCapture.classList.remove("accent");
        copyCapture.title = "Copy screenshot to clipboard";
      }, 1100);
    }).catch(() => {});
  });
  headerActions.append(copyCapture);
  const headerClose = makeHeaderButton("Close", '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M6 6 18 18M18 6 6 18"/></svg>');
  headerClose.addEventListener("pointerdown", (event) => { event.preventDefault(); window.openAssistElectron.cancelScreenAnalysis(); });
  headerClose.addEventListener("click", () => window.openAssistElectron.cancelScreenAnalysis());
  headerActions.append(headerClose);
  header.append(headerActions);
  card.append(header);

  if (status === "prompt") {
    const bodyRow = document.createElement("div");
    bodyRow.className = "body-row";

    const preview = document.createElement("button");
    preview.className = "screenshot-preview";
    preview.type = "button";
    preview.title = "Click to view full screenshot";
    const previewImg = document.createElement("img");
    previewImg.src = payload.previewDataURL || "";
    previewImg.alt = "Screenshot";
    preview.append(previewImg);
    preview.addEventListener("click", () => {
      if (!payload.previewDataURL) return;
      window.openAssistElectron.openImageInPreview(payload.previewDataURL).catch(() => {});
    });

    const composerCol = document.createElement("div");
    composerCol.className = "composer-col";

    const composer = document.createElement("div");
    composer.className = "composer";
    const addImage = document.createElement("button");
    addImage.className = "icon-btn";
    addImage.type = "button";
    addImage.title = "Attach reference image or skill";
    addImage.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M5 12h14"/></svg>';
    const input = document.createElement("input");
    input.placeholder = "What should I do with this screenshot?";
    const send = document.createElement("button");
    send.className = "icon-btn send-btn";
    send.type = "button";
    send.title = "Send (Enter)";
    send.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="m4 12 16-8-6 16-2-7-8-1z"/></svg>';
    const voiceToggle = document.createElement("button");
    voiceToggle.className = "icon-btn voice-toggle-btn";
    voiceToggle.type = "button";
    voiceToggle.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M4 10v4h3l4 4V6l-4 4H4z"/><path d="M15 9.5a4 4 0 0 1 0 5"/><path d="M17.5 7a7 7 0 0 1 0 10"/></svg>';
    function setVoiceToggle(enabled) {
      const isEnabled = Boolean(enabled);
      voiceToggle.dataset.enabled = isEnabled ? "true" : "false";
      voiceToggle.setAttribute("aria-pressed", isEnabled ? "true" : "false");
      voiceToggle.title = isEnabled ? "Read this answer aloud: on" : "Read this answer aloud: off";
    }
    setVoiceToggle(false);
    composer.append(addImage, input, voiceToggle, send);

    const referenceRow = document.createElement("div");
    referenceRow.className = "reference-row";

    const hint = document.createElement("div");
    hint.className = "hint";
    hint.textContent = "Press Enter to send";

    let currentAttachments = [];
    let currentSkills = [];
    function renderChips() {
      referenceRow.innerHTML = "";
      currentAttachments.forEach((item, index) => {
        const chip = document.createElement("div");
        chip.className = "reference-chip";
        const imageBtn = document.createElement("button");
        imageBtn.type = "button";
        imageBtn.className = "reference-chip-thumb";
        imageBtn.title = "Open in Preview";
        const image = document.createElement("img");
        image.src = item.previewDataURL || "";
        image.alt = "";
        imageBtn.append(image);
        imageBtn.addEventListener("click", () => {
          if (!item.previewDataURL) return;
          window.openAssistElectron.openImageInPreview(item.previewDataURL).catch(() => {});
        });
        const label = document.createElement("span");
        label.textContent = item.name || "Image";
        const remove = document.createElement("button");
        remove.type = "button";
        remove.className = "reference-chip-remove";
        remove.title = "Remove";
        remove.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M6 6 18 18M18 6 6 18"/></svg>';
        remove.addEventListener("click", (event) => {
          event.stopPropagation();
          window.openAssistElectron.removeScreenAnalysisReference(index).then((response) => {
            if (response && response.ok) {
              renderReferences(response.attachments || []);
            }
          }).catch(() => {});
        });
        chip.append(imageBtn, label, remove);
        referenceRow.append(chip);
      });
      currentSkills.forEach((skill) => {
        const chip = document.createElement("div");
        chip.className = "reference-chip skill-chip";
        const icon = document.createElement("span");
        icon.className = "skill-chip-icon";
        icon.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 14 9l6 2-6 2-2 6-2-6-6-2 6-2 2-6z"/></svg>';
        const label = document.createElement("span");
        label.textContent = skill.title || skill.id;
        const remove = document.createElement("button");
        remove.type = "button";
        remove.className = "reference-chip-remove";
        remove.title = "Remove skill";
        remove.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M6 6 18 18M18 6 6 18"/></svg>';
        remove.addEventListener("click", (event) => {
          event.stopPropagation();
          window.openAssistElectron.toggleScreenAnalysisSkill(skill.id, skill.title).then((response) => {
            if (response && response.ok) {
              currentSkills = response.skills || [];
              renderChips();
            }
          }).catch(() => {});
        });
        chip.append(icon, label, remove);
        referenceRow.append(chip);
      });
      const hasAny = currentAttachments.length || currentSkills.length;
      hint.textContent = hasAny
        ? (currentSkills.length && !currentAttachments.length
          ? "Skill attached. Press Enter to send."
          : "Attachment added. Press Enter to send.")
        : "Press Enter to send";
      hint.style.color = "rgba(255,255,255,0.40)";
    }
    function renderReferences(items) {
      currentAttachments = items || [];
      renderChips();
    }
    voiceToggle.addEventListener("click", () => {
      const nextEnabled = voiceToggle.dataset.enabled !== "true";
      setVoiceToggle(nextEnabled);
      hint.textContent = nextEnabled ? "This answer will be read aloud. Press Enter to send." : "Voice readback is off. Press Enter to send.";
      hint.style.color = "rgba(255,255,255,0.40)";
    });
    function fail(message) {
      submitted = false;
      send.disabled = false;
      input.disabled = false;
      hint.textContent = message;
      hint.style.color = "rgba(255,120,129,0.82)";
    }
    const attachMenu = document.createElement("div");
    attachMenu.className = "attach-menu";
    attachMenu.style.display = "none";
    let attachMenuOpen = false;
    function closeAttachMenu() {
      attachMenuOpen = false;
      attachMenu.style.display = "none";
      attachMenu.classList.remove("skill-list");
      window.openAssistElectron.setScreenAnalysisMenuExpanded(false).catch(function() {});
    }
    function chooseImages() {
      addImage.disabled = true;
      window.openAssistElectron.chooseScreenAnalysisReferenceImages().then((response) => {
        if (response && response.ok) {
          renderReferences(response.attachments || []);
        } else if (response && response.error) {
          hint.textContent = response.error;
          hint.style.color = "rgba(255,120,129,0.82)";
        }
      }).catch((error) => {
        hint.textContent = error && error.message ? error.message : "Could not add image.";
        hint.style.color = "rgba(255,120,129,0.82)";
      }).finally(() => {
        addImage.disabled = false;
      });
    }
    function showSkillList() {
      // The skill list needs real estate: mark the menu tall and grow the
      // window while it is open (it is clipped at the window edge otherwise).
      attachMenu.classList.add("skill-list");
      window.openAssistElectron.setScreenAnalysisMenuExpanded(true).catch(function() {});
      attachMenu.innerHTML = '<div class="menu-note">Loading skills...</div>';
      window.openAssistElectron.listScreenAnalysisSkills().then((response) => {
        attachMenu.innerHTML = "";
        const skills = (response && response.skills) || [];
        if (!response || !response.ok || !skills.length) {
          attachMenu.innerHTML = '<div class="menu-note">' + ((response && response.error) || "No skills found.") + '</div>';
          return;
        }
        const search = document.createElement("input");
        search.type = "text";
        search.className = "menu-search";
        search.placeholder = "Search skills...";
        const list = document.createElement("div");
        list.className = "menu-options";
        const renderOptions = (filterText) => {
          list.innerHTML = "";
          const query = String(filterText || "").trim().toLowerCase();
          const visible = query
            ? skills.filter((skill) => String(skill.title || skill.id).toLowerCase().includes(query))
            : skills;
          if (!visible.length) {
            const note = document.createElement("div");
            note.className = "menu-note";
            note.textContent = "No matching skills.";
            list.append(note);
            return;
          }
          visible.forEach((skill) => {
            const option = document.createElement("button");
            option.type = "button";
            const isSelected = currentSkills.some((item) => item.id === skill.id);
            if (isSelected) option.className = "selected";
            option.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 14 9l6 2-6 2-2 6-2-6-6-2 6-2 2-6z"/></svg>';
            const optionLabel = document.createElement("span");
            optionLabel.textContent = skill.title || skill.id;
            option.append(optionLabel);
            option.addEventListener("click", () => {
              window.openAssistElectron.toggleScreenAnalysisSkill(skill.id, skill.title).then((result) => {
                if (result && result.ok) {
                  currentSkills = result.skills || [];
                  renderChips();
                }
                closeAttachMenu();
              }).catch(() => closeAttachMenu());
            });
            list.append(option);
          });
        };
        search.addEventListener("input", () => renderOptions(search.value));
        search.addEventListener("keydown", (event) => {
          if (event.key === "Escape") {
            event.preventDefault();
            event.stopPropagation();
            closeAttachMenu();
          }
        });
        renderOptions("");
        attachMenu.append(search, list);
        search.focus();
      }).catch(() => {
        attachMenu.innerHTML = '<div class="menu-note">Could not load skills.</div>';
      });
    }
    function openAttachMenuRoot() {
      attachMenu.innerHTML = "";
      const imageOption = document.createElement("button");
      imageOption.type = "button";
      imageOption.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.5-3.5L9 20"/></svg>';
      const imageLabel = document.createElement("span");
      imageLabel.textContent = "Reference image...";
      imageOption.append(imageLabel);
      imageOption.addEventListener("click", () => {
        closeAttachMenu();
        chooseImages();
      });
      const skillOption = document.createElement("button");
      skillOption.type = "button";
      skillOption.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 14 9l6 2-6 2-2 6-2-6-6-2 6-2 2-6z"/></svg>';
      const skillLabel = document.createElement("span");
      skillLabel.textContent = "Skill...";
      skillOption.append(skillLabel);
      skillOption.addEventListener("click", () => {
        showSkillList();
      });
      attachMenu.append(imageOption, skillOption);
      attachMenu.style.display = "flex";
      attachMenuOpen = true;
    }
    addImage.addEventListener("click", () => {
      if (attachMenuOpen) closeAttachMenu();
      else openAttachMenuRoot();
    });
    document.addEventListener("pointerdown", (event) => {
      if (!attachMenuOpen) return;
      if (attachMenu.contains(event.target) || addImage.contains(event.target)) return;
      closeAttachMenu();
    });
    function submit() {
      if (submitted) return;
      submitted = true;
      send.disabled = true;
      input.disabled = true;
      hint.textContent = "Sending screenshot...";
      window.openAssistElectron.submitScreenAnalysis(input.value || "", {
        readback: voiceToggle.dataset.enabled === "true"
      }).catch((error) => {
        fail(error && error.message ? error.message : String(error || "Screen analysis failed."));
      });
    }
    send.addEventListener("pointerdown", (event) => { event.preventDefault(); submit(); });
    send.addEventListener("click", submit);
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        submit();
      } else if (event.key === "Escape") {
        event.preventDefault();
        window.openAssistElectron.cancelScreenAnalysis();
      }
    });
    function handlePastedImage(file) {
      if (!file) return false;
      hint.textContent = "Attaching pasted image...";
      hint.style.color = "rgba(255,255,255,0.40)";
      const reader = new FileReader();
      reader.onload = () => {
        const dataURL = typeof reader.result === "string" ? reader.result : "";
        window.openAssistElectron.addScreenAnalysisReferenceFromDataURL(dataURL, file.name || "pasted-image.png").then((response) => {
          if (response && response.ok) {
            renderReferences(response.attachments || []);
            if (response.error) {
              hint.textContent = response.error;
              hint.style.color = "rgba(255,120,129,0.82)";
            }
          } else if (response && response.error) {
            hint.textContent = response.error;
            hint.style.color = "rgba(255,120,129,0.82)";
          }
        }).catch((error) => {
          hint.textContent = error && error.message ? error.message : "Could not attach pasted image.";
          hint.style.color = "rgba(255,120,129,0.82)";
        });
      };
      reader.onerror = () => {
        hint.textContent = "Could not read pasted image.";
        hint.style.color = "rgba(255,120,129,0.82)";
      };
      reader.readAsDataURL(file);
      return true;
    }
    input.addEventListener("paste", (event) => {
      const items = event.clipboardData && event.clipboardData.items ? event.clipboardData.items : null;
      if (!items) return;
      for (const item of items) {
        if (item.kind === "file" && item.type && item.type.indexOf("image/") === 0) {
          event.preventDefault();
          handlePastedImage(item.getAsFile());
          return;
        }
      }
    });
    composerCol.append(composer, attachMenu, referenceRow, hint);
    bodyRow.append(preview, composerCol);
    card.append(bodyRow);
    setTimeout(() => input.focus(), 40);
  } else if (status === "analyzing") {
    const statusRow = document.createElement("div");
    statusRow.className = "status";
    const spinner = document.createElement("span");
    spinner.className = "spinner";
    const text = document.createElement("span");
    text.textContent = payload.text || "Reading the selected area...";
    statusRow.append(spinner, text);
    card.append(statusRow);
    if (payload.resultText) {
      const result = document.createElement("div");
      result.className = "result";
      result.innerHTML = renderReadableText(payload.resultText);
      card.append(result);
    }
    if (payload.mode === "image") {
      const shimmer = document.createElement("div");
      shimmer.className = "image-gen-placeholder";
      card.append(shimmer);
    }
  } else {
    const result = document.createElement("div");
    result.className = "result";
    const generatedImages = Array.isArray(payload.images) ? payload.images : [];
    const hasText = Boolean(payload.text && String(payload.text).trim());
    const cleanInsertText = markdownToPlainText(payload.text || "");
    result.innerHTML = renderReadableText(hasText ? payload.text : (generatedImages.length ? "Generated image is ready." : "No screen analysis text was returned."));
    if (generatedImages.length) {
      const grid = document.createElement("div");
      grid.className = "generated-images";
      generatedImages.forEach((image, index) => {
        if (!image || !image.dataURL) return;
        const card = document.createElement("div");
        card.className = "generated-image-card";
        const preview = document.createElement("button");
        preview.type = "button";
        preview.className = "generated-image-preview";
        preview.title = "View image";
        const img = document.createElement("img");
        img.src = image.dataURL;
        img.alt = image.name || "Generated image";
        preview.append(img);
        preview.addEventListener("click", () => {
          window.openAssistElectron.openImageInPreview(image.dataURL).catch(() => {});
        });
        const imageActions = document.createElement("div");
        imageActions.className = "generated-image-actions";
        const view = document.createElement("button");
        view.className = "legacy-btn";
        view.type = "button";
        view.textContent = "View";
        view.addEventListener("click", () => {
          window.openAssistElectron.openImageInPreview(image.dataURL).catch(() => {});
        });
        const save = document.createElement("button");
        save.className = "legacy-btn primary";
        save.type = "button";
        save.textContent = "Download";
        save.addEventListener("click", () => {
          save.disabled = true;
          save.textContent = "Saving";
          window.openAssistElectron.saveImage(image.dataURL, image.name || ("openassist-generated-" + (index + 1) + ".png")).then((response) => {
            if (response && response.ok) {
              save.textContent = "Saved";
            } else {
              save.textContent = response && response.canceled ? "Download" : "Save failed";
              save.disabled = false;
            }
          }).catch(() => {
            save.textContent = "Save failed";
            save.disabled = false;
          });
        });
        imageActions.append(view, save);
        card.append(preview, imageActions);
        grid.append(card);
      });
      result.append(grid);
    }
    const actions = document.createElement("div");
    actions.className = "actions";
    const insert = document.createElement("button");
    insert.className = "legacy-btn primary";
    insert.textContent = "Insert at cursor";
    if (!cleanInsertText) insert.disabled = true;
    insert.addEventListener("click", () => {
      insert.disabled = true;
      insert.textContent = "Inserting";
      window.openAssistElectron.insertTranscriptText(cleanInsertText).then((response) => {
        insert.textContent = response && response.ok ? "Inserted" : "Insert failed";
        if (!response || !response.ok) insert.disabled = false;
      }).catch(() => {
        insert.textContent = "Insert failed";
        insert.disabled = false;
      });
    });
    const readAloud = document.createElement("button");
    readAloud.className = "legacy-btn";
    readAloud.textContent = "Read aloud";
    if (!cleanInsertText) readAloud.disabled = true;
    readAloud.addEventListener("click", () => {
      if (!window.openAssistElectron || !window.openAssistElectron.speakAssistantResponse) {
        readAloud.textContent = "Voice unavailable";
        return;
      }
      readAloud.disabled = true;
      readAloud.textContent = "Reading...";
      window.openAssistElectron.speakAssistantResponse(cleanInsertText, { force: true }).then((response) => {
        readAloud.textContent = response && response.ok ? "Read again" : "Could not read";
        readAloud.disabled = false;
      }).catch(() => {
        readAloud.textContent = "Could not read";
        readAloud.disabled = false;
      });
    });
    if (payload.tone === "error") {
      actions.append(insert);
    } else {
      actions.append(insert, readAloud);
    }
    card.append(result, actions);
    if (payload.tone !== "error") {
      const followComposer = document.createElement("div");
      followComposer.className = "composer follow-up-composer";
      const followInput = document.createElement("input");
      followInput.type = "text";
      followInput.placeholder = "Ask a follow-up about this capture...";
      const followSend = document.createElement("button");
      followSend.type = "button";
      followSend.className = "icon-btn send-btn";
      followSend.title = "Send follow-up";
      followSend.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5"></path><path d="M5 12l7-7 7 7"></path></svg>';
      let followSubmitted = false;
      function submitFollowUp() {
        const value = (followInput.value || "").trim();
        if (!value || followSubmitted) return;
        followSubmitted = true;
        followInput.disabled = true;
        followSend.disabled = true;
        window.openAssistElectron.submitScreenAnalysis(value, { readback: false }).catch((error) => {
          followSubmitted = false;
          followInput.disabled = false;
          followSend.disabled = false;
          followInput.value = value;
          followInput.placeholder = error && error.message ? error.message : "Follow-up failed. Try again.";
        });
      }
      followSend.addEventListener("pointerdown", (event) => { event.preventDefault(); submitFollowUp(); });
      followSend.addEventListener("click", submitFollowUp);
      followInput.addEventListener("keydown", (event) => {
        if (event.key === "Enter") {
          event.preventDefault();
          submitFollowUp();
        } else if (event.key === "Escape") {
          event.preventDefault();
          window.openAssistElectron.cancelScreenAnalysis();
        }
      });
      followComposer.append(followInput, followSend);
      card.append(followComposer);
      setTimeout(() => followInput.focus(), 60);
    }
  }
  root.append(card);
}
window.updateOpenAssistScreenAnalysis = update;
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") window.openAssistElectron.cancelScreenAnalysis();
});
</script>
</body>
</html>`;
}

function screenAnalysisFrameHTML() {
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<title>Open Assist Screen Analysis Frame</title>
<style>
html, body, #root {
  width: 100%;
  height: 100%;
  margin: 0;
  overflow: hidden;
  background: transparent;
  pointer-events: auto;
}
.frame {
  position: absolute;
  border-radius: 12px;
  pointer-events: auto;
  border: 2.5px solid color-mix(in srgb, var(--c1) 70%, white 8%);
  box-shadow:
    0 0 8px color-mix(in srgb, var(--c1) 32%, transparent),
    0 0 18px color-mix(in srgb, var(--c2) 18%, transparent);
}
.frame.analyzing {
  border-color: color-mix(in srgb, var(--c1) 75%, white 10%);
  box-shadow:
    0 0 10px color-mix(in srgb, var(--c1) 38%, transparent),
    0 0 22px color-mix(in srgb, var(--c2) 22%, transparent);
}
.frame.result {
  border-width: 1.5px;
  opacity: 0.82;
  box-shadow:
    0 0 5px color-mix(in srgb, var(--c1) 20%, transparent),
    0 0 12px color-mix(in srgb, var(--c2) 12%, transparent);
}
.frame.analyzing::before {
  content: "";
  position: absolute;
  inset: -2px;
  border-radius: 14px;
  padding: 2.5px;
  background: conic-gradient(
    from var(--angle),
    transparent 0deg,
    transparent 260deg,
    color-mix(in srgb, var(--c1) 90%, white) 310deg,
    color-mix(in srgb, var(--c2) 95%, white) 340deg,
    color-mix(in srgb, var(--c3) 90%, white) 360deg,
    transparent 360deg
  );
  -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
  -webkit-mask-composite: xor;
  mask-composite: exclude;
  filter:
    drop-shadow(0 0 5px color-mix(in srgb, var(--c1) 75%, transparent))
    drop-shadow(0 0 12px color-mix(in srgb, var(--c2) 50%, transparent));
  animation: shimmer-spin 2.8s linear infinite;
  pointer-events: none;
}
@property --angle {
  syntax: "<angle>";
  initial-value: 0deg;
  inherits: false;
}
@keyframes shimmer-spin {
  to { --angle: 360deg; }
}
</style>
</head>
<body>
<div id="root"></div>
<script>
const root = document.getElementById("root");
let currentFrameRect = null;
let isInteractive = false;
const ringOuter = 8;
const ringInner = 6;

function setInteractive(next) {
  if (next === isInteractive) return;
  isInteractive = next;
  if (window.openAssistElectron && typeof window.openAssistElectron.setScreenAnalysisFrameInteractive === "function") {
    window.openAssistElectron.setScreenAnalysisFrameInteractive(next);
  }
}

function pointerOverRing(x, y) {
  const r = currentFrameRect;
  if (!r) return false;
  const outerLeft = r.x - ringOuter;
  const outerTop = r.y - ringOuter;
  const outerRight = r.x + r.width + ringOuter;
  const outerBottom = r.y + r.height + ringOuter;
  if (x < outerLeft || x > outerRight || y < outerTop || y > outerBottom) return false;
  const innerLeft = r.x + ringInner;
  const innerTop = r.y + ringInner;
  const innerRight = r.x + r.width - ringInner;
  const innerBottom = r.y + r.height - ringInner;
  const insideInner = x >= innerLeft && x <= innerRight && y >= innerTop && y <= innerBottom;
  return !insideInner;
}

document.addEventListener("mousemove", (event) => {
  setInteractive(pointerOverRing(event.clientX, event.clientY));
});
document.addEventListener("mouseleave", () => setInteractive(false));

function update(payload) {
  const rect = payload.rect || { x: 8, y: 8, width: 200, height: 120 };
  const colors = payload.colors || ["#4f8fe8", "#a363b7", "#df4546", "#ddb52d"];
  root.style.setProperty("--c1", colors[0] || "#4f8fe8");
  root.style.setProperty("--c2", colors[1] || "#a363b7");
  root.style.setProperty("--c3", colors[2] || "#df4546");
  root.style.setProperty("--c4", colors[3] || "#ddb52d");
  root.innerHTML = "";
  const frame = document.createElement("div");
  frame.className = "frame" + (payload.status === "analyzing" ? " analyzing" : payload.status === "result" ? " result" : "");
  frame.style.left = rect.x + "px";
  frame.style.top = rect.y + "px";
  frame.style.width = rect.width + "px";
  frame.style.height = rect.height + "px";
  root.append(frame);
  currentFrameRect = rect;
  setInteractive(false);
}
window.updateOpenAssistScreenAnalysisFrame = update;
</script>
</body>
</html>`;
}

function screenAnalysisPanel(rect: ScreenRect, width: number, height: number, status: "prompt" | "analyzing" | "result") {
  const bounds = displayBoundsForRect(rect);
  const gap = 14;
  const margin = 16;
  const panelWidth = width;
  const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(value, Math.max(min, max)));
  const minX = bounds.x + margin;
  const maxX = bounds.x + bounds.width - panelWidth - margin;
  const minY = bounds.y + margin;
  const maxY = bounds.y + bounds.height - height - margin;
  const centeredX = clamp(rect.x + Math.round((rect.width - panelWidth) / 2), minX, maxX);
  const belowY = rect.y + rect.height + gap;
  const aboveY = rect.y - height - gap;
  const fitsBelow = belowY + height <= bounds.y + bounds.height - margin;
  const fitsAbove = aboveY >= minY;

  const rightX = rect.x + rect.width + gap;
  const leftX = rect.x - panelWidth - gap;
  const sideY = clamp(rect.y, minY, maxY);
  if (rightX + panelWidth <= bounds.x + bounds.width - margin) {
    return { x: rightX, y: sideY, width: panelWidth, height };
  }
  if (leftX >= minX) {
    return { x: leftX, y: sideY, width: panelWidth, height };
  }

  if (fitsBelow) return { x: centeredX, y: belowY, width: panelWidth, height };
  if (fitsAbove) return { x: centeredX, y: aboveY, width: panelWidth, height };

  return { x: centeredX, y: clamp(rect.y, minY, maxY), width: panelWidth, height };
}

function attachScreenAnalysisCloseMenu(window: BrowserWindow) {
  window.webContents.on("context-menu", () => {
    Menu.buildFromTemplate([
      {
        label: "Close screen snip",
        click: () => {
          void cancelScreenAnalysisPrompt();
        }
      }
    ]).popup({ window });
  });
}

function jsLiteral(value: unknown) {
  return JSON.stringify(value)
    .replace(/</g, "\\u003c")
    .replace(/>/g, "\\u003e")
    .replace(/&/g, "\\u0026")
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029");
}

async function waitForGlobalFunction(window: BrowserWindow, globalName: string, timeoutMs = 1500) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (window.isDestroyed()) return false;
    try {
      const ready = await window.webContents.executeJavaScript(
        `typeof window[${JSON.stringify(globalName)}] === "function"`
      );
      if (ready) return true;
    } catch {
      // ignore — page may still be loading
    }
    await new Promise((resolve) => setTimeout(resolve, 40));
  }
  return false;
}

async function updateScreenAnalysisFrameView(window: BrowserWindow, payload: unknown) {
  try {
    const ready = await waitForGlobalFunction(window, "updateOpenAssistScreenAnalysisFrame");
    if (!ready) {
      debugLog("screen analysis frame update skipped: function never became ready");
      return false;
    }
    const result = await window.webContents.executeJavaScript(
    `(() => {
      try {
        const payload = ${jsLiteral(payload)};
        if (typeof window.updateOpenAssistScreenAnalysisFrame !== "function") {
          return { ok: false, error: "Screen analysis frame is not ready." };
        }
        window.updateOpenAssistScreenAnalysisFrame(payload);
        return { ok: true };
      } catch (error) {
        return { ok: false, error: error && error.message ? error.message : String(error) };
      }
    })()`
    );
    if (!result?.ok) {
      debugLog(`screen analysis frame update failed: ${result?.error ?? "unknown error"}`);
      return false;
    }
    return true;
  } catch (error) {
    debugLog(`screen analysis frame script failed: ${error instanceof Error ? error.message : String(error)}`);
    return false;
  }
}

async function updateScreenAnalysisPanelView(window: BrowserWindow, payload: unknown) {
  try {
    const ready = await waitForGlobalFunction(window, "updateOpenAssistScreenAnalysis");
    if (!ready) {
      debugLog("screen analysis panel update skipped: function never became ready");
      return false;
    }
    const result = await window.webContents.executeJavaScript(
    `(() => {
      try {
        const payload = ${jsLiteral(payload)};
        if (typeof window.updateOpenAssistScreenAnalysis !== "function") {
          return { ok: false, error: "Screen analysis panel is not ready." };
        }
        window.updateOpenAssistScreenAnalysis(payload);
        return { ok: true };
      } catch (error) {
        return { ok: false, error: error && error.message ? error.message : String(error) };
      }
    })()`
    );
    if (!result?.ok) {
      debugLog(`screen analysis panel update failed: ${result?.error ?? "unknown error"}`);
      return false;
    }
    return true;
  } catch (error) {
    debugLog(`screen analysis panel script failed: ${error instanceof Error ? error.message : String(error)}`);
    return false;
  }
}

async function reloadScreenAnalysisPanelWindow(window: BrowserWindow) {
  screenAnalysisWindowReady = false;
  const didLoad = new Promise<void>((resolve) => {
    window.webContents.once("did-finish-load", () => {
      screenAnalysisWindowReady = true;
      resolve();
    });
  });
  await window.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(screenAnalysisHTML())}`);
  await didLoad;
}

function ensureScreenAnalysisWindow() {
  if (screenAnalysisWindow && !screenAnalysisWindow.isDestroyed()) return screenAnalysisWindow;
  screenAnalysisWindowReady = false;
  const window = new BrowserWindow({
    type: "panel",
    width: 520,
    height: 150,
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    hasShadow: false,
    resizable: true,
    minWidth: 420,
    minHeight: 160,
    movable: true,
    focusable: true,
    acceptFirstMouse: true,
    skipTaskbar: true,
    show: false,
    title: "Open Assist Screen Analysis",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      devTools: enableDevTools,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: true
    }
  });
  window.setAlwaysOnTop(true, "pop-up-menu");
  if (process.platform === "darwin") {
    window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
  }
  window.on("moved", () => {
    screenAnalysisUserMovedPanel = true;
  });
  window.on("resized", () => {
    screenAnalysisUserResizedPanel = true;
  });
  window.on("closed", () => {
    if (screenAnalysisWindow === window) screenAnalysisWindow = null;
    screenAnalysisWindowReady = false;
    stopAssistantVoiceOutputForSessionEnd("screen analysis HUD closed");
    screenAnalysisStatus = "idle";
    // Closing the HUD should never pop the assistant window over whatever
    // app the user is working in.
    discardScreenAnalysisMainWindowRestore("screen analysis HUD closed");
    scheduleScreenAnalysisBufferEviction();
  });
  window.webContents.once("did-finish-load", () => {
    screenAnalysisWindowReady = true;
  });
  attachScreenAnalysisCloseMenu(window);
  window.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(screenAnalysisHTML())}`);
  screenAnalysisWindow = window;
  return window;
}

function ensureScreenAnalysisFrameWindow() {
  if (screenAnalysisFrameWindow && !screenAnalysisFrameWindow.isDestroyed()) return screenAnalysisFrameWindow;
  screenAnalysisFrameWindowReady = false;
  const window = new BrowserWindow({
    type: "panel",
    width: 220,
    height: 140,
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    hasShadow: false,
    resizable: false,
    movable: false,
    focusable: false,
    skipTaskbar: true,
    show: false,
    title: "Open Assist Screen Analysis Frame",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      devTools: enableDevTools,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: true
    }
  });
  window.setIgnoreMouseEvents(true, { forward: true });
  window.setAlwaysOnTop(true, "pop-up-menu");
  if (process.platform === "darwin") {
    window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
  }
  window.on("closed", () => {
    if (screenAnalysisFrameWindow === window) screenAnalysisFrameWindow = null;
    screenAnalysisFrameWindowReady = false;
  });
  window.webContents.once("did-finish-load", () => {
    screenAnalysisFrameWindowReady = true;
  });
  attachScreenAnalysisCloseMenu(window);
  window.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(screenAnalysisFrameHTML())}`);
  screenAnalysisFrameWindow = window;
  return window;
}

function waitForScreenAnalysisWindow(window: BrowserWindow) {
  if (screenAnalysisWindowReady) return Promise.resolve();
  return new Promise<void>((resolve) => {
    window.webContents.once("did-finish-load", () => resolve());
  });
}

function waitForScreenAnalysisFrameWindow(window: BrowserWindow) {
  if (screenAnalysisFrameWindowReady) return Promise.resolve();
  return new Promise<void>((resolve) => {
    window.webContents.once("did-finish-load", () => resolve());
  });
}

async function updateScreenAnalysisOverlay(payload: {
  status: "prompt" | "analyzing" | "result";
  rect: ScreenRect;
  previewDataURL?: string;
  text?: string;
  resultText?: string;
  images?: ScreenAnalysisGeneratedImage[];
  tone?: "error" | "success";
  // Follow-up turn: keep the panel where it is (no resize/reposition) and let
  // the HUD update the existing result view in place instead of rebuilding.
  inline?: boolean;
  mode?: "image" | "text";
}) {
  screenAnalysisStatus = payload.status;
  // Any non-idle status means we still want the captured buffers around.
  // (payload.status is typed as "prompt"|"analyzing"|"result", never "idle".)
  cancelScreenAnalysisBufferEviction();
  const window = ensureScreenAnalysisWindow();
  const frameWindow = ensureScreenAnalysisFrameWindow();
  const colors = screenAnalysisPalette(lastVoiceHUDAppearance.theme);
  const themeColors = screenAnalysisCurrentThemeColors();
  if (payload.status !== "result") {
    screenAnalysisFrameVisible = true;
  }
  const framePadding = payload.status === "analyzing" ? 12 : 10;
  const frameBounds = {
    x: payload.rect.x - framePadding,
    y: payload.rect.y - framePadding,
    width: payload.rect.width + framePadding * 2,
    height: payload.rect.height + framePadding * 2
  };
  if (!frameWindow.isDestroyed()) {
    frameWindow.setBounds(frameBounds, false);
    if (screenAnalysisFrameVisible) {
      if (!frameWindow.isVisible()) frameWindow.showInactive();
    } else {
      frameWindow.hide();
    }
    await waitForScreenAnalysisFrameWindow(frameWindow);
    await updateScreenAnalysisFrameView(frameWindow, {
      status: payload.status,
      rect: { x: framePadding, y: framePadding, width: payload.rect.width, height: payload.rect.height },
      colors
    });
  }

  if (window.isDestroyed()) {
    debugLog("screen analysis panel window destroyed before update");
    return;
  }
  const hasGeneratedImages = Boolean(payload.images?.length);
  const panelHeight = payload.status === "result" ? (hasGeneratedImages ? 470 : 380) : payload.status === "analyzing" ? 120 : 158;
  const panelWidth = payload.status === "result" ? (hasGeneratedImages ? 620 : 560) : 540;
  const inlineUpdate = Boolean(payload.inline) && window.isVisible();
  let panel = screenAnalysisPanel(payload.rect, panelWidth, panelHeight, payload.status);
  // If the user dragged/resized the panel, respect that geometry instead of
  // snapping it back next to the capture rect on every status change.
  if ((screenAnalysisUserMovedPanel || screenAnalysisUserResizedPanel) && window.isVisible()) {
    const currentBounds = window.getBounds();
    if (screenAnalysisUserMovedPanel) panel = { ...panel, x: currentBounds.x, y: currentBounds.y };
    if (screenAnalysisUserResizedPanel) panel = { ...panel, width: currentBounds.width, height: currentBounds.height };
  }
  debugLog(`screen analysis overlay status=${payload.status} inline=${inlineUpdate} rect=${JSON.stringify(payload.rect)} frame=${JSON.stringify(frameBounds)} panel=${JSON.stringify(panel)} preview=${lastCapturedPreviewDataURL ? "yes" : "no"}`);
  if (!inlineUpdate) {
    window.setBounds(panel, false);
    screenAnalysisPanelExpandedHeight = panel.height;
  }
  const viewPayload = {
    ...payload,
    panel: { x: 0, y: 0, width: inlineUpdate ? window.getBounds().width : panel.width },
    colors,
    themeColors
  };
  if (!inlineUpdate) {
    if (!window.isVisible()) {
      window.show();
    }
    if (payload.status === "prompt") {
      window.focus();
    } else {
      window.showInactive();
    }
    window.moveTop();
  }
  await waitForScreenAnalysisWindow(window);
  let didUpdatePanel = await updateScreenAnalysisPanelView(window, viewPayload);
  if (!didUpdatePanel && !window.isDestroyed()) {
    await reloadScreenAnalysisPanelWindow(window);
    didUpdatePanel = await updateScreenAnalysisPanelView(window, viewPayload);
  }
  if (!didUpdatePanel) {
    debugLog("screen analysis panel could not be updated after reload");
  } else {
    debugLog(`screen analysis panel updated status=${payload.status}`);
  }
}

function selectScreenRect(): Promise<ScreenRect> {
  const bounds = displayBoundsUnderMouse();
  return new Promise((resolve, reject) => {
    if (screenSelectionWindow && !screenSelectionWindow.isDestroyed()) {
      screenSelectionWindow.close();
    }
    pendingScreenSelectionResolve = resolve;
    pendingScreenSelectionReject = reject;
    const window = new BrowserWindow({
      type: "panel",
      ...bounds,
      frame: false,
      transparent: true,
      backgroundColor: "#00000000",
      hasShadow: false,
      resizable: false,
      movable: false,
      focusable: true,
      acceptFirstMouse: true,
      skipTaskbar: true,
      show: false,
      title: "Open Assist Screen Selection",
      webPreferences: {
        preload: path.join(__dirname, "preload.js"),
        devTools: enableDevTools,
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: false,
        backgroundThrottling: true
      }
    });
    window.setAlwaysOnTop(true, "pop-up-menu");
    if (process.platform === "darwin") {
      window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
    }
    window.on("closed", () => {
      if (screenSelectionWindow === window) screenSelectionWindow = null;
      if (pendingScreenSelectionReject) {
        const reject = pendingScreenSelectionReject;
        pendingScreenSelectionResolve = null;
        pendingScreenSelectionReject = null;
        reject(new Error("Screen analysis cancelled."));
      }
    });
    const colors = screenAnalysisPalette(lastVoiceHUDAppearance.theme);
    window.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(screenSelectionHTML(colors))}`);
    window.once("ready-to-show", () => {
      if (!window.isDestroyed()) {
        window.show();
        window.focus();
      }
    });
    screenSelectionWindow = window;
  });
}

async function runScreenAnalysis(imageBuffer: Buffer, instruction: string, options: { readback?: boolean } = {}) {
  const runID = ++screenAnalysisRunID;
  const bridge = await openAssistBridge();
  const rect = lastCapturedScreenRect;
  const referenceImages = [
    ...lastScreenAnalysisReferenceImages.map((image) => ({
      name: image.name,
      data: image.data,
      mimeType: image.mimeType
    })),
    ...screenAnalysisGeneratedImageRefs
  ];
  let accumulatedText = "";
  let generatedImages: ScreenAnalysisGeneratedImage[] = [];
  const showResult = async (text: string, images: ScreenAnalysisGeneratedImage[] = []) => {
    if (runID !== screenAnalysisRunID) return;
    if (rect) {
      await updateScreenAnalysisOverlay({
        status: "result",
        rect,
        text: text.trim() || (images.length ? "Generated image is ready." : "No screen analysis text was returned."),
        images
      });
    }
  };

  const conversationHistory = screenAnalysisConversation.slice(-12);
  // Follow-up turns update the existing panel in place (inline) so the window
  // keeps its size and position and the previous answer stays visible.
  const isFollowUp = conversationHistory.length > 0;
  const wantsImageGeneration = Boolean(bridge.promptWantsImageGeneration?.(instruction || ""));
  const analyzingText = wantsImageGeneration ? "Generating image..." : "Analyzing the selected area...";

  if (rect) {
    // No previewDataURL here: the analyzing view never renders it, and the
    // multi-MB base64 string would be re-serialized into executeJavaScript
    // on every update, freezing the HUD renderer (beachball, undraggable).
    void updateScreenAnalysisOverlay({
      status: "analyzing",
      rect,
      text: analyzingText,
      inline: isFollowUp,
      mode: wantsImageGeneration ? "image" : "text"
    });
  }

  // Throttle streamed-text updates: each one rebuilds the panel DOM, so
  // per-token updates flood the window and stall it.
  let streamUpdateTimer: NodeJS.Timeout | null = null;
  let streamDone = false;
  const flushStreamUpdate = () => {
    streamUpdateTimer = null;
    if (streamDone || runID !== screenAnalysisRunID || !rect || !accumulatedText.trim()) return;
    void updateScreenAnalysisOverlay({
      status: "analyzing",
      rect,
      text: analyzingText,
      resultText: accumulatedText,
      inline: isFollowUp,
      mode: wantsImageGeneration ? "image" : "text"
    });
  };
  try {
    const finalResult = await bridge.analyzeScreenWithCodex(imageBuffer, instruction, referenceImages, (text) => {
      accumulatedText = text;
      if (!text.trim()) return;
      if (!streamUpdateTimer) streamUpdateTimer = setTimeout(flushStreamUpdate, 200);
    }, conversationHistory, screenAnalysisSelectedSkills.map((skill) => skill.id));
    streamDone = true;
    if (streamUpdateTimer) {
      clearTimeout(streamUpdateTimer);
      streamUpdateTimer = null;
    }
    accumulatedText = accumulatedText || finalResult.text;
    generatedImages = finalResult.images || [];
    if (accumulatedText.trim() || generatedImages.length) {
      if (runID === screenAnalysisRunID) {
        screenAnalysisConversation.push({
          role: "user",
          text: instruction.trim() || "Explain what is on my screen."
        });
        if (accumulatedText.trim()) {
          screenAnalysisConversation.push({ role: "assistant", text: accumulatedText.trim() });
        }
        if (generatedImages.length) {
          screenAnalysisGeneratedImageRefs = screenAnalysisGeneratedRefsFromImages(generatedImages);
        }
      }
      await showResult(accumulatedText, generatedImages);
      if (options.readback && accumulatedText.trim()) {
        void bridge.speakAssistantResponse(accumulatedText, { force: true }).catch((speechError: unknown) => {
          debugLog(`screen analysis voice output failed: ${speechError instanceof Error ? speechError.message : String(speechError)}`);
        });
      }
    } else {
      if (rect) {
        await updateScreenAnalysisOverlay({
          status: "result",
          rect,
          tone: "error",
          text: "Screen analysis finished, but no text came back. Please try again."
        });
      }
    }
  } catch (error) {
    streamDone = true;
    if (streamUpdateTimer) {
      clearTimeout(streamUpdateTimer);
      streamUpdateTimer = null;
    }
    debugLog(`Screen analysis stream error: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
    if (rect) {
      await updateScreenAnalysisOverlay({
        status: "result",
        rect,
        tone: "error",
        text: `Screen analysis failed: ${error instanceof Error ? error.message : String(error)}`
      });
    }
  }
}

async function chooseScreenAnalysisReferenceImages() {
  const ownerWindow = screenAnalysisWindow ?? mainWindow;
  const dialogOptions: OpenDialogOptions = {
    title: "Add reference image",
    properties: ["openFile", "multiSelections"],
    filters: [
      { name: "Images", extensions: ["png", "jpg", "jpeg", "webp", "gif"] }
    ]
  };
  const result = ownerWindow
    ? await dialog.showOpenDialog(ownerWindow, dialogOptions)
    : await dialog.showOpenDialog(dialogOptions);
  if (result.canceled || !result.filePaths.length) {
    return {
      ok: true,
      attachments: lastScreenAnalysisReferenceImages.map((image) => ({
        name: image.name,
        previewDataURL: image.previewDataURL
      }))
    };
  }

  const remainingSlots = Math.max(0, 4 - lastScreenAnalysisReferenceImages.length);
  const selectedPaths = result.filePaths.slice(0, remainingSlots || 0);
  const additions = selectedPaths.map((filePath) => {
    const data = fs.readFileSync(filePath);
    const mimeType = mimeTypeForImagePath(filePath);
    return {
      name: path.basename(filePath),
      data,
      mimeType,
      previewDataURL: `data:${mimeType};base64,${data.toString("base64")}`
    };
  });
  lastScreenAnalysisReferenceImages = [
    ...lastScreenAnalysisReferenceImages,
    ...additions
  ].slice(0, 4);
  return {
    ok: true,
    attachments: lastScreenAnalysisReferenceImages.map((image) => ({
      name: image.name,
      previewDataURL: image.previewDataURL
    })),
    error: result.filePaths.length > additions.length ? "Only 4 reference images can be attached." : undefined
  };
}

function extensionForMime(mimeType: string) {
  if (mimeType === "image/png") return ".png";
  if (mimeType === "image/jpeg") return ".jpg";
  if (mimeType === "image/webp") return ".webp";
  if (mimeType === "image/gif") return ".gif";
  return ".png";
}

async function addScreenAnalysisReferenceFromDataURL(dataURL: string, suggestedName?: string) {
  const match = /^data:(image\/[a-zA-Z0-9+.-]+);base64,(.*)$/.exec(dataURL || "");
  if (!match) return { ok: false, error: "Pasted content is not an image." };
  const mimeType = match[1];
  const data = Buffer.from(match[2], "base64");
  if (!data.length) return { ok: false, error: "Pasted image is empty." };
  if (lastScreenAnalysisReferenceImages.length >= 4) {
    return {
      ok: true,
      attachments: lastScreenAnalysisReferenceImages.map((image) => ({
        name: image.name,
        previewDataURL: image.previewDataURL
      })),
      error: "Only 4 reference images can be attached."
    };
  }
  const baseName = suggestedName && suggestedName.trim() ? suggestedName.trim() : `pasted-${Date.now()}${extensionForMime(mimeType)}`;
  lastScreenAnalysisReferenceImages = [
    ...lastScreenAnalysisReferenceImages,
    { name: baseName, data, mimeType, previewDataURL: `data:${mimeType};base64,${data.toString("base64")}` }
  ].slice(0, 4);
  return {
    ok: true,
    attachments: lastScreenAnalysisReferenceImages.map((image) => ({
      name: image.name,
      previewDataURL: image.previewDataURL
    }))
  };
}

function removeScreenAnalysisReferenceImage(index: number) {
  if (index < 0 || index >= lastScreenAnalysisReferenceImages.length) {
    return { ok: false, error: "Reference image not found." };
  }
  lastScreenAnalysisReferenceImages = [
    ...lastScreenAnalysisReferenceImages.slice(0, index),
    ...lastScreenAnalysisReferenceImages.slice(index + 1)
  ];
  return {
    ok: true,
    attachments: lastScreenAnalysisReferenceImages.map((image) => ({
      name: image.name,
      previewDataURL: image.previewDataURL
    }))
  };
}

async function openImageDataURLInPreview(dataURL: string) {
  const match = /^data:(image\/[a-zA-Z0-9+.-]+);base64,(.*)$/.exec(dataURL || "");
  if (!match) return { ok: false, error: "Not a valid image data URL." };
  const mimeType = match[1];
  const data = Buffer.from(match[2], "base64");
  if (!data.length) return { ok: false, error: "Image is empty." };
  const tempPath = path.join(os.tmpdir(), `openassist-screenshot-${Date.now()}${extensionForMime(mimeType)}`);
  await fs.promises.writeFile(tempPath, data);
  const openError = await shell.openPath(tempPath);
  if (openError) return { ok: false, error: openError };
  return { ok: true };
}

async function saveImageDataURL(dataURL: string, defaultName = "openassist-image.png") {
  const match = /^data:(image\/[a-zA-Z0-9+.-]+);base64,(.*)$/.exec(dataURL || "");
  if (!match) return { ok: false, error: "Not a valid image data URL." };
  const mimeType = match[1];
  const data = Buffer.from(match[2], "base64");
  if (!data.length) return { ok: false, error: "Image is empty." };
  const extension = extensionForMime(mimeType).replace(".", "");
  const safeDefaultName = defaultName.replace(/[/:\\]/g, "-").trim() || `openassist-image.${extension}`;
  const result = await dialog.showSaveDialog({
    title: "Save image",
    defaultPath: safeDefaultName,
    filters: [
      { name: "Image", extensions: [extension] },
      { name: "All Files", extensions: ["*"] }
    ]
  });
  if (result.canceled || !result.filePath) return { ok: false, canceled: true };
  await fs.promises.writeFile(result.filePath, data);
  return { ok: true, path: result.filePath };
}

async function openLocalPath(filePath: string) {
  const rawPath = String(filePath ?? "").trim();
  const targetPath = rawPath.startsWith("~")
    ? path.join(app.getPath("home"), rawPath.slice(1))
    : rawPath;
  if (!targetPath || !fs.existsSync(targetPath)) return { ok: false, error: "File was not found." };
  const openError = await shell.openPath(targetPath);
  return openError ? { ok: false, error: openError, path: targetPath } : { ok: true, path: targetPath };
}

type LocalFilePreviewKind =
  | "image"
  | "pdf"
  | "markdown"
  | "html"
  | "json"
  | "csv"
  | "code"
  | "text"
  | "unsupported";

const LOCAL_FILE_TEXT_PREVIEW_LIMIT = 900 * 1024;
const LOCAL_FILE_BINARY_PREVIEW_LIMIT = 28 * 1024 * 1024;

const markdownPreviewExtensions = new Set([".md", ".markdown", ".mdown", ".mkd"]);
const htmlPreviewExtensions = new Set([".html", ".htm"]);
const csvPreviewExtensions = new Set([".csv", ".tsv"]);
const textPreviewExtensions = new Set([
  ".txt", ".log", ".env", ".gitignore", ".npmrc", ".yml", ".yaml", ".toml", ".ini", ".xml",
  ".svg", ".jsonl", ".ndjson"
]);
const codePreviewExtensions = new Set([
  ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".css", ".scss", ".less", ".sh", ".bash", ".zsh",
  ".py", ".rb", ".go", ".rs", ".java", ".kt", ".swift", ".c", ".cc", ".cpp", ".h", ".hpp", ".cs",
  ".php", ".sql", ".graphql", ".gql", ".feature", ".dockerfile", ".rs", ".lua", ".r", ".pl"
]);

function previewMimeTypeForPath(filePath: string) {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === ".png") return "image/png";
  if (ext === ".jpg" || ext === ".jpeg") return "image/jpeg";
  if (ext === ".webp") return "image/webp";
  if (ext === ".gif") return "image/gif";
  if (ext === ".svg") return "image/svg+xml";
  if (ext === ".pdf") return "application/pdf";
  if (ext === ".html" || ext === ".htm") return "text/html";
  if (ext === ".md" || ext === ".markdown" || ext === ".mdown" || ext === ".mkd") return "text/markdown";
  if (ext === ".json") return "application/json";
  if (ext === ".csv") return "text/csv";
  if (ext === ".tsv") return "text/tab-separated-values";
  if (textPreviewExtensions.has(ext) || codePreviewExtensions.has(ext)) return "text/plain";
  return "application/octet-stream";
}

function previewKindForPath(filePath: string): LocalFilePreviewKind {
  const ext = path.extname(filePath).toLowerCase();
  const name = path.basename(filePath).toLowerCase();
  if ([".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg"].includes(ext)) return "image";
  if (ext === ".pdf") return "pdf";
  if (markdownPreviewExtensions.has(ext)) return "markdown";
  if (htmlPreviewExtensions.has(ext)) return "html";
  if (ext === ".json" || ext === ".jsonc") return "json";
  if (csvPreviewExtensions.has(ext)) return "csv";
  if (codePreviewExtensions.has(ext) || name === "dockerfile" || name === "makefile") return "code";
  if (textPreviewExtensions.has(ext)) return "text";
  return "unsupported";
}

async function readTextPreview(filePath: string, size: number) {
  const byteCount = Math.min(size, LOCAL_FILE_TEXT_PREVIEW_LIMIT + 1);
  const handle = await fs.promises.open(filePath, "r");
  try {
    const buffer = Buffer.alloc(byteCount);
    const { bytesRead } = await handle.read(buffer, 0, byteCount, 0);
    const clipped = buffer.subarray(0, Math.min(bytesRead, LOCAL_FILE_TEXT_PREVIEW_LIMIT));
    return {
      text: clipped.toString("utf8"),
      truncated: bytesRead > LOCAL_FILE_TEXT_PREVIEW_LIMIT || size > LOCAL_FILE_TEXT_PREVIEW_LIMIT
    };
  } finally {
    await handle.close();
  }
}

async function getLocalFilePreview(filePath: string) {
  const targetPath = String(filePath ?? "").trim();
  if (!targetPath || !fs.existsSync(targetPath)) return { ok: false, error: "File was not found.", path: targetPath };
  const stat = await fs.promises.stat(targetPath);
  if (!stat.isFile()) return { ok: false, error: "Only files can be previewed.", path: targetPath, name: path.basename(targetPath) };
  const kind = previewKindForPath(targetPath);
  const mimeType = previewMimeTypeForPath(targetPath);
  const base = {
    ok: true as const,
    path: targetPath,
    name: path.basename(targetPath),
    extension: path.extname(targetPath).toLowerCase(),
    mimeType,
    size: stat.size,
    kind,
    fileURL: pathToFileURL(targetPath).toString()
  };

  if (kind === "image" || kind === "pdf") {
    if (stat.size > LOCAL_FILE_BINARY_PREVIEW_LIMIT) {
      return { ...base, kind: "unsupported" as const, tooLarge: true };
    }
    const data = await fs.promises.readFile(targetPath);
    return { ...base, dataURL: `data:${mimeType};base64,${data.toString("base64")}` };
  }

  if (kind !== "unsupported") {
    const { text, truncated } = await readTextPreview(targetPath, stat.size);
    return { ...base, text, truncated };
  }

  return base;
}

function revealLocalPath(filePath: string) {
  const targetPath = String(filePath ?? "").trim();
  if (!targetPath || !fs.existsSync(targetPath)) return { ok: false, error: "File was not found." };
  shell.showItemInFolder(targetPath);
  return { ok: true, path: targetPath };
}

function setScreenAnalysisFrameVisible(visible: boolean) {
  screenAnalysisFrameVisible = visible;
  if (!screenAnalysisFrameWindow || screenAnalysisFrameWindow.isDestroyed()) {
    return { ok: true };
  }
  if (visible) {
    screenAnalysisFrameWindow.showInactive();
    screenAnalysisFrameWindow.moveTop();
  } else {
    screenAnalysisFrameWindow.hide();
  }
  return { ok: true };
}

// The prompt card window is only ~158px tall, so the attach/skill dropdown
// was clipped at the window edge after two items. While the skill list is
// open the window temporarily grows to fit it, then snaps back.
let screenAnalysisMenuBaseHeight = 0;
function setScreenAnalysisMenuExpanded(expanded: boolean) {
  if (!screenAnalysisWindow || screenAnalysisWindow.isDestroyed()) {
    return { ok: false };
  }
  const bounds = screenAnalysisWindow.getBounds();
  if (expanded) {
    if (!screenAnalysisMenuBaseHeight) screenAnalysisMenuBaseHeight = bounds.height;
    screenAnalysisWindow.setBounds({
      ...bounds,
      height: Math.max(bounds.height, screenAnalysisMenuBaseHeight + 330)
    }, false);
    screenAnalysisWindow.moveTop();
  } else if (screenAnalysisMenuBaseHeight) {
    screenAnalysisWindow.setBounds({
      ...bounds,
      height: screenAnalysisMenuBaseHeight
    }, false);
    screenAnalysisMenuBaseHeight = 0;
  }
  return { ok: true };
}

function setScreenAnalysisPanelCollapsed(collapsed: boolean) {
  if (!screenAnalysisWindow || screenAnalysisWindow.isDestroyed()) {
    return { ok: false };
  }
  const bounds = screenAnalysisWindow.getBounds();
  if (collapsed) {
    screenAnalysisPanelExpandedHeight = Math.max(screenAnalysisPanelExpandedHeight, bounds.height);
    screenAnalysisWindow.setBounds({
      ...bounds,
      height: 54
    }, false);
  } else {
    screenAnalysisWindow.setBounds({
      ...bounds,
      height: Math.max(140, screenAnalysisPanelExpandedHeight)
    }, false);
  }
  screenAnalysisWindow.moveTop();
  return { ok: true };
}

async function restartScreenAnalysisAtSamePlace() {
  const rect = lastCapturedScreenRect;
  if (!rect) {
    return { ok: false, error: "No screen snip is active." };
  }
  screenAnalysisRunID += 1;
  screenAnalysisFrameVisible = true;
  cancelScreenAnalysisBufferEviction();
  const imageBuffer = await captureScreenRect(rect);
  lastCapturedImageBuffer = imageBuffer;
  lastCapturedPreviewDataURL = `data:image/png;base64,${imageBuffer.toString("base64")}`;
  lastScreenAnalysisReferenceImages = [];
  await updateScreenAnalysisOverlay({
    status: "prompt",
    rect,
    previewDataURL: lastCapturedPreviewDataURL
  });
  return { ok: true };
}

async function submitScreenAnalysisPrompt(instruction: string, options: { readback?: boolean } = {}) {
  debugLog(`screen analysis submit requested instructionLength=${instruction.length}`);
  if (!lastCapturedImageBuffer || !lastCapturedScreenRect) {
    throw new Error("No screen capture found to analyze.");
  }
  // Keep the capture in memory so the user can ask follow-up questions about
  // the same screenshot; it is released on cancel/close or buffer eviction.
  await runScreenAnalysis(lastCapturedImageBuffer, instruction, options);
  return { ok: true };
}

async function cancelScreenAnalysisPrompt() {
  const shouldRestoreMainWindow = screenAnalysisStatus !== "result";
  debugLog(`screen analysis prompt cancelled status=${screenAnalysisStatus}`);
  screenAnalysisRunID += 1;
  try {
    (await openAssistBridge()).stopAssistantVoiceOutput();
  } catch (error) {
    debugLog(`screen analysis voice stop failed: ${error instanceof Error ? error.message : String(error)}`);
  }
  lastCapturedImageBuffer = null;
  lastCapturedScreenRect = null;
  lastCapturedPreviewDataURL = "";
  lastScreenAnalysisReferenceImages = [];
  screenAnalysisConversation = [];
  screenAnalysisGeneratedImageRefs = [];
  screenAnalysisUserMovedPanel = false;
  screenAnalysisUserResizedPanel = false;
  screenAnalysisSelectedSkills = [];
  screenAnalysisFrameVisible = true;
  screenSelectionWindow?.close();
  screenSelectionWindow = null;
  screenAnalysisFrameWindow?.hide();
  screenAnalysisWindow?.hide();
  screenAnalysisStatus = "idle";
  scheduleScreenAnalysisBufferEviction();
  // Never bring the assistant window back to front on cancel/escape — the
  // user is in another app; popping the main window over it is intrusive.
  discardScreenAnalysisMainWindowRestore(
    shouldRestoreMainWindow ? "screen analysis cancelled" : "screen analysis result closed"
  );
  return { ok: true };
}

async function triggerScreenAnalysis() {
  let rect: ScreenRect | null = null;
  let imageBuffer: Buffer | null = null;
  try {
    debugLog("Triggering interactive screen analysis...");

    if (voiceHUDWindow && !voiceHUDWindow.isDestroyed()) {
      voiceHUDWindow.hide();
    }
    hideMainWindowForScreenAnalysis();

    rect = await selectScreenRect();
    imageBuffer = await captureScreenRect(rect);
    lastCapturedImageBuffer = imageBuffer;
    lastCapturedScreenRect = rect;
    lastCapturedPreviewDataURL = `data:image/png;base64,${imageBuffer.toString("base64")}`;
    lastScreenAnalysisReferenceImages = [];
    screenAnalysisConversation = [];
    screenAnalysisGeneratedImageRefs = [];
    screenAnalysisUserMovedPanel = false;
    screenAnalysisUserResizedPanel = false;
    screenAnalysisSelectedSkills = [];
  } catch (error) {
    debugLog(`Screen analysis capture error: ${error}`);
    if (error instanceof Error && error.message === "Screen analysis cancelled.") {
      // Escape during the snip: leave every window exactly where it was.
      discardScreenAnalysisMainWindowRestore("screen selection cancelled");
      return;
    }
    restoreMainWindowAfterScreenAnalysis("screen analysis capture failed");
    await updateVoiceHUD({
      visible: true,
      status: "error",
      text: error instanceof Error ? error.message : String(error)
    });
    return;
  }

  if (!rect) return;

  try {
    await updateScreenAnalysisOverlay({
      status: "prompt",
      rect,
      previewDataURL: lastCapturedPreviewDataURL
    });
  } catch (error) {
    debugLog(`Screen analysis overlay error: ${error}`);
    try {
      await reloadScreenAnalysisPanelWindow(ensureScreenAnalysisWindow());
      await updateScreenAnalysisOverlay({
        status: "prompt",
        rect,
        previewDataURL: lastCapturedPreviewDataURL
      });
    } catch (retryError) {
      debugLog(`Screen analysis overlay retry failed: ${retryError}`);
      restoreMainWindowAfterScreenAnalysis("screen analysis overlay failed");
      await updateVoiceHUD({
        visible: true,
        status: "error",
        text: "Could not open the screen analysis panel. Please try again."
      });
    }
  }
}

function registerFixedShortcuts() {
  globalShortcut.unregister(pasteLastTranscriptAccelerator);
  const didRegister = globalShortcut.register(pasteLastTranscriptAccelerator, () => {
    void pasteLastTranscriptFromShortcut();
  });
  if (!didRegister) {
    debugLog(`could not register paste-last-transcript accelerator=${pasteLastTranscriptAccelerator}`);
  }
}

function createMainWindow(options: { initiallyHidden?: boolean } = {}) {
  const { initiallyHidden = false } = options;
  debugLog(`createMainWindow start isDev=${isDev} appPath=${app.getAppPath()} dirname=${__dirname} initiallyHidden=${initiallyHidden}`);
  const window = new BrowserWindow({
    width: 1220,
    height: 770,
    minWidth: 940,
    minHeight: 620,
    title: "Open Assist",
    backgroundColor: isAccessibilityTestMode ? "#111317" : "#00000000",
    transparent: !isAccessibilityTestMode,
    vibrancy: !isAccessibilityTestMode && process.platform === "darwin" ? "menu" : undefined,
    visualEffectState: "active",
    titleBarStyle: isAccessibilityTestMode ? "default" : "hiddenInset",
    trafficLightPosition: { x: 18, y: 18 },
    show: false,
    skipTaskbar: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      accessibleTitle: "Open Assist",
      devTools: enableDevTools,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      spellcheck: true
    }
  });
  attachSpellcheckContext(window);
  window.accessibleTitle = "Open Assist";
  if (!isAccessibilityTestMode && process.platform === "darwin") {
    window.setBackgroundColor("#00000000");
    window.setVibrancy("menu");
  }
  if (process.platform === "darwin") {
    window.setSkipTaskbar(false);
  }

  let didShowWindow = false;
  const showWindow = () => {
    if (initiallyHidden) return;
    if (didShowWindow || window.isDestroyed()) return;
    didShowWindow = true;
    debugLog("showWindow");
    ensureRegularDockPresence("show main window");
    window.show();
  };
  window.once("ready-to-show", () => {
    debugLog("ready-to-show");
    showWindow();
  });
  window.webContents.once("did-finish-load", () => {
    debugLog("did-finish-load");
    window.webContents.setZoomLevel(0);
    window.webContents.setZoomFactor(1);
    showWindow();
  });
  void window.webContents.setVisualZoomLevelLimits(1, 1).catch(() => {});
  window.webContents.on("did-fail-load", (_event, errorCode, errorDescription, validatedURL) => {
    debugLog(`did-fail-load code=${errorCode} description=${errorDescription} url=${validatedURL}`);
  });
  window.webContents.on("render-process-gone", (_event, details) => {
    debugLog(`render-process-gone reason=${details.reason} exitCode=${details.exitCode}`);
  });
  // Single-parameter listener on purpose: declaring the legacy positional
  // params (level, message, line, sourceId) makes Electron emit its
  // "'console-message' arguments are deprecated" warning. The modern event
  // object carries the same fields.
  window.webContents.on("console-message", (event) => {
    const details = event as unknown as { level?: unknown; message?: unknown; lineNumber?: unknown; sourceId?: unknown };
    const level = String(details.level ?? "");
    // Only mirror real errors. Warnings (level 2) are almost entirely React
    // key / CSP noise from rendered artifacts and flooded the debug log with
    // thousands of duplicate lines.
    if (!["error", "3"].includes(level)) return;
    const message = String(details.message ?? "").slice(0, 1200);
    const source = String(details.sourceId ?? "");
    const line = String(details.lineNumber ?? "");
    debugLog(`renderer-console level=${level} source=${source}:${line} message=${message}`);
  });
  // Safety net only: ready-to-show is the normal path. At 2500ms this fired
  // before the renderer's first paint (dev builds take ~3s), so the user saw
  // a blank window for close to a second.
  setTimeout(showWindow, 5000);
  window.on("close", (event) => {
    if (process.platform !== "darwin" || isQuitting) return;
    event.preventDefault();
    window.hide();
    switchToMenuBarOnlyPresence("main window closed");
  });
  window.on("closed", () => {
    if (mainWindow === window) mainWindow = null;
  });
  window.on("blur", () => {
    collapseUnpinnedSidebar("main window blur");
    syncFrontmostApplicationTracker();
  });
  // Keep the frontmost-app poller in step with mainWindow visibility.
  // (No-op when not on darwin.)
  window.on("focus", () => syncFrontmostApplicationTracker());
  window.on("show", () => syncFrontmostApplicationTracker());
  window.on("hide", () => syncFrontmostApplicationTracker());
  window.on("minimize", () => syncFrontmostApplicationTracker());
  window.on("restore", () => syncFrontmostApplicationTracker());
  window.on("app-command", (event, command) => {
    const normalizedCommand = String(command || "").toLowerCase();
    const direction = normalizedCommand === "browser-backward"
      ? "back"
      : normalizedCommand === "browser-forward"
        ? "forward"
        : null;
    if (!direction) return;
    event.preventDefault();
    safeSendWindow(window, "openassist:navigation-command", direction);
  });

  loadRendererWindow(window);
  maybeOpenDevTools(window, "main");

  mainWindow = window;
  debugLog("createMainWindow complete");
  return window;
}

function loadRendererWindow(window: BrowserWindow, query?: Record<string, string>) {
  const fullQuery = { ...initialAppearanceQuery(), ...(query ?? {}) };
  if (isDev && process.env.VITE_DEV_SERVER_URL) {
    const url = new URL(process.env.VITE_DEV_SERVER_URL);
    for (const [key, value] of Object.entries(fullQuery)) url.searchParams.set(key, value);
    debugLog(`loadURL ${url.toString()}`);
    window.loadURL(url.toString());
    return;
  }
  const indexPath = path.join(__dirname, "../dist-renderer/index.html");
  debugLog(`loadFile ${indexPath} exists=${fs.existsSync(indexPath)} query=${JSON.stringify(query ?? {})}`);
  window.loadFile(indexPath, { query: fullQuery });
}

function createTranscriptHistoryWindow() {
  if (transcriptHistoryWindow && !transcriptHistoryWindow.isDestroyed()) return transcriptHistoryWindow;
  const window = new BrowserWindow({
    width: 680,
    height: 560,
    minWidth: 560,
    minHeight: 420,
    center: true,
    title: "Transcript History",
    backgroundColor: isAccessibilityTestMode ? "#111317" : "#00000000",
    transparent: !isAccessibilityTestMode,
    vibrancy: !isAccessibilityTestMode && process.platform === "darwin" ? "menu" : undefined,
    visualEffectState: "active",
    titleBarStyle: isAccessibilityTestMode ? "default" : "hiddenInset",
    trafficLightPosition: { x: 18, y: 18 },
    show: false,
    skipTaskbar: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      accessibleTitle: "Transcript History",
      devTools: enableDevTools,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: true
    }
  });
  window.accessibleTitle = "Transcript History";
  if (!isAccessibilityTestMode && process.platform === "darwin") {
    window.setBackgroundColor("#00000000");
    window.setVibrancy("menu");
  }
  window.on("closed", () => {
    if (transcriptHistoryWindow === window) transcriptHistoryWindow = null;
  });
  loadRendererWindow(window, { window: "history" });
  transcriptHistoryWindow = window;
  return window;
}

function normalizedSettingsSection(section?: string) {
  const value = String(section ?? "").trim();
  return /^[a-z-]+$/.test(value) ? value : "assistant";
}

function createSettingsWindow(section = "assistant") {
  if (settingsWindow && !settingsWindow.isDestroyed()) return settingsWindow;
  const window = new BrowserWindow({
    width: 1180,
    height: 780,
    minWidth: 900,
    minHeight: 620,
    center: true,
    title: "Open Assist Settings",
    backgroundColor: isAccessibilityTestMode ? "#111317" : "#00000000",
    transparent: !isAccessibilityTestMode,
    vibrancy: !isAccessibilityTestMode && process.platform === "darwin" ? "menu" : undefined,
    visualEffectState: "active",
    titleBarStyle: isAccessibilityTestMode ? "default" : "hiddenInset",
    trafficLightPosition: { x: 18, y: 18 },
    show: false,
    skipTaskbar: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      accessibleTitle: "Open Assist Settings",
      devTools: enableDevTools,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: true
    }
  });
  window.accessibleTitle = "Open Assist Settings";
  if (!isAccessibilityTestMode && process.platform === "darwin") {
    window.setBackgroundColor("#00000000");
    window.setVibrancy("menu");
  }
  window.on("close", (event) => {
    if (isQuitting) return;
    event.preventDefault();
    window.hide();
  });
  window.on("closed", () => {
    if (settingsWindow === window) settingsWindow = null;
  });
  loadRendererWindow(window, { window: "settings", section: normalizedSettingsSection(section) });
  maybeOpenDevTools(window, "settings");
  settingsWindow = window;
  return window;
}

function prewarmSettingsWindow() {
  if (isQuitting) return;
  try {
    createSettingsWindow("assistant");
  } catch (error) {
    debugLog(`settings window prewarm failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
  }
}

async function showTranscriptHistoryWindow() {
  await refreshFrontmostApplicationSnapshot();
  const window = createTranscriptHistoryWindow();
  ensureRegularDockPresence("show transcript history");
  if (window.isMinimized()) window.restore();
  window.show();
  window.focus();
  return { ok: true };
}

async function showSettingsWindow(section = "assistant") {
  const targetSection = normalizedSettingsSection(section);
  const window = createSettingsWindow(targetSection);
  ensureRegularDockPresence("show settings window");
  if (window.isMinimized()) window.restore();
  window.show();
  window.focus();
  if (window.webContents.isLoading()) {
    window.webContents.once("did-finish-load", () => {
      safeSendWindow(window, "openassist:settings-section", targetSection);
    });
  } else {
    safeSendWindow(window, "openassist:settings-section", targetSection);
  }
  return { ok: true };
}

function runProcess(command: string, args: string[]) {
  return new Promise<void>((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(stderr.trim() || `${command} exited with code ${code}`));
      }
    });
  });
}

function runProcessWithOutput(command: string, args: string[], timeoutMs: number) {
  return new Promise<{ stdout: string; stderr: string }>((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`${path.basename(command)} timed out.`));
    }, timeoutMs);
    child.stdout.on("data", (chunk) => {
      stdout += String(chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) {
        resolve({ stdout, stderr });
      } else {
        const outputMessage = stdout.trim().split(/\r?\n/).pop() || stderr.trim();
        reject(new Error(outputMessage || `${command} exited with code ${code}`));
      }
    });
  });
}

function delay(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

function appleScriptString(value: string) {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

async function runAppleScript(script: string, timeoutMs = 1800) {
  try {
    await runProcessWithOutput("/usr/bin/osascript", ["-e", script], timeoutMs);
    return true;
  } catch (error) {
    debugLog(`AppleScript failed: ${error instanceof Error ? error.message : String(error)}`);
    return false;
  }
}

function isOwnApplicationSnapshot(snapshot: FrontmostApplicationSnapshot) {
  const bundleID = snapshot.bundleIdentifier.toLowerCase();
  const name = snapshot.name.toLowerCase();
  return (
    bundleID === "com.developingadventures.openassist" ||
    bundleID === "com.developingadventures.openassistelectronreact" ||
    bundleID.includes("openassist.electron") ||
    name === "open assist" ||
    name.includes("open assist voice")
  );
}

async function currentFrontmostApplicationSnapshot() {
  if (process.platform !== "darwin") return null;
  const script = `
tell application "System Events"
  set frontApp to first application process whose frontmost is true
  set frontPid to unix id of frontApp
  set frontName to name of frontApp
  set frontBundle to ""
  try
    set frontBundle to bundle identifier of frontApp
  end try
  return (frontPid as text) & tab & frontBundle & tab & frontName
end tell
`.trim();
  try {
    const output = await runProcessWithOutput("/usr/bin/osascript", ["-e", script], 1600);
    const [rawPid, bundleIdentifier = "", name = ""] = output.stdout.trim().split("\t");
    const pid = Number(rawPid);
    if (!Number.isFinite(pid) || pid <= 0) return null;
    return {
      pid,
      bundleIdentifier,
      name,
      capturedAt: Date.now()
    } satisfies FrontmostApplicationSnapshot;
  } catch (error) {
    debugLog(`frontmost snapshot failed: ${error instanceof Error ? error.message : String(error)}`);
    return null;
  }
}

async function refreshFrontmostApplicationSnapshot() {
  if (frontmostSnapshotInFlight) return frontmostSnapshotInFlight;
  frontmostSnapshotInFlight = currentFrontmostApplicationSnapshot()
    .then((snapshot) => {
      if (snapshot) lastFrontmostSnapshot = snapshot;
      if (snapshot && !isOwnApplicationSnapshot(snapshot)) {
        lastExternalApplication = snapshot;
      }
      return snapshot;
    })
    .finally(() => {
      frontmostSnapshotInFlight = null;
    });
  return frontmostSnapshotInFlight;
}

// Returns a recent frontmost snapshot without paying a fresh ~100-400ms
// osascript round-trip when one was captured moments ago (e.g. at dictation
// stop, while the transcription request was still in flight).
async function frontmostApplicationSnapshotWithMaxAge(maxAgeMs: number) {
  if (lastFrontmostSnapshot && Date.now() - lastFrontmostSnapshot.capturedAt <= maxAgeMs) {
    return lastFrontmostSnapshot;
  }
  return refreshFrontmostApplicationSnapshot();
}

function startFrontmostApplicationTracker() {
  if (process.platform !== "darwin") return;
  // The tracker only does useful work when another app is in front, because
  // refreshFrontmostApplicationSnapshot() filters out our own pid before
  // updating lastExternalApplication. So we only run it while our window is
  // visible and blurred. When our window is focused or hidden, the poll is
  // a wasted osascript fork — at idle that was ~24 wakeups/s on the main
  // process. See docs/perf-audit-idle.md (baseline).
  syncFrontmostApplicationTracker();
}

function syncFrontmostApplicationTracker() {
  if (process.platform !== "darwin") return;
  const window = mainWindow;
  const shouldPoll =
    !!window &&
    !window.isDestroyed() &&
    window.isVisible() &&
    !window.isMinimized() &&
    !window.isFocused();
  if (shouldPoll) {
    if (frontmostTrackerTimer) return;
    void refreshFrontmostApplicationSnapshot();
    frontmostTrackerTimer = setInterval(() => {
      void refreshFrontmostApplicationSnapshot();
    }, frontmostTrackerIntervalMs);
  } else if (frontmostTrackerTimer) {
    clearInterval(frontmostTrackerTimer);
    frontmostTrackerTimer = null;
  }
}

function stopFrontmostApplicationTracker() {
  if (!frontmostTrackerTimer) return;
  clearInterval(frontmostTrackerTimer);
  frontmostTrackerTimer = null;
}

async function activateApplicationSnapshot(target: FrontmostApplicationSnapshot) {
  if (process.platform !== "darwin") return false;
  const script = `
tell application "System Events"
  set frontmost of first application process whose unix id is ${target.pid} to true
end tell
`.trim();
  return runAppleScript(script, 1800);
}

async function sendPasteViaMenuItemAppleScript() {
  const script = `
tell application "System Events"
  tell first application process whose frontmost is true
    click menu item "Paste" of menu 1 of menu bar item "Edit" of menu bar 1
  end tell
end tell
`.trim();
  return runAppleScript(script, 1400);
}

async function sendPasteViaAppleScriptKeystroke() {
  const script = `
tell application "System Events"
  keystroke "v" using command down
end tell
`.trim();
  return runAppleScript(script, 1200);
}

async function triggerPasteShortcutWithRetry() {
  const backoff = [0, 40, 100];
  for (const delayMs of backoff) {
    if (delayMs > 0) await delay(delayMs);
    if (await sendPasteViaMenuItemAppleScript()) return true;
    if (await sendPasteViaAppleScriptKeystroke()) return true;
  }
  return false;
}

async function typeKeyCode(keyCode: number) {
  const script = `
tell application "System Events"
  key code ${keyCode}
end tell
`.trim();
  return runAppleScript(script, 1200);
}

async function typeTextByAppleScript(text: string) {
  const normalized = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  let chunk = "";

  const flushChunk = async () => {
    if (!chunk) return true;
    const textChunk = chunk;
    chunk = "";
    const script = `
tell application "System Events"
  keystroke "${appleScriptString(textChunk)}"
end tell
`.trim();
    return runAppleScript(script, 3000);
  };

  for (const char of Array.from(normalized)) {
    if (char === "\n") {
      if (!(await flushChunk())) return false;
      if (!(await typeKeyCode(36))) return false;
      continue;
    }
    if (char === "\t") {
      if (!(await flushChunk())) return false;
      if (!(await typeKeyCode(48))) return false;
      continue;
    }
    chunk += char;
    if (Array.from(chunk).length >= 48 && !(await flushChunk())) return false;
  }

  return flushChunk();
}

type TextTypingStrategy = "unicode-events" | "applescript-keystroke-preferred" | "accessibility-direct-preferred";

function textInserterHelperSourcePath() {
  const candidates = [
    path.join(app.getAppPath(), "electron", "helpers", "text-inserter-helper.swift"),
    path.join(process.cwd(), "electron", "helpers", "text-inserter-helper.swift"),
    path.join(openAssistRepoRoot(), "electron-react", "electron", "helpers", "text-inserter-helper.swift")
  ];
  return candidates.find((candidate) => fs.existsSync(candidate));
}

async function ensureTextInserterHelper() {
  const sourcePath = textInserterHelperSourcePath();
  if (!sourcePath) throw new Error("Text inserter helper source was not found.");
  const helperDirectory = path.join(app.getPath("userData"), "helpers", "Open Assist Text Inserter");
  const helperPath = path.join(helperDirectory, "text-inserter-helper");
  const sourceStat = fs.statSync(sourcePath);
  const helperStat = fs.existsSync(helperPath) ? fs.statSync(helperPath) : null;
  if (!helperStat || helperStat.mtimeMs < sourceStat.mtimeMs) {
    fs.mkdirSync(helperDirectory, { recursive: true });
    await runProcess("/usr/bin/swiftc", ["-framework", "AppKit", sourcePath, "-o", helperPath]);
    fs.chmodSync(helperPath, 0o755);
    try {
      await runProcess("/usr/bin/codesign", ["--force", "--sign", "-", helperPath]);
    } catch {
      // The helper still works during local development without a full app certificate.
    }
  }
  return helperPath;
}

function typingStrategyForTarget(target: FrontmostApplicationSnapshot | null | undefined): TextTypingStrategy {
  const targetBundle = target?.bundleIdentifier?.trim().toLowerCase() ?? "";
  if (targetBundle === "com.microsoft.rdc.macos") return "applescript-keystroke-preferred";
  if (!targetBundle || targetBundle === "missing value") return "accessibility-direct-preferred";
  return "unicode-events";
}

async function typeTextByNativeHelper(text: string, strategy: TextTypingStrategy) {
  const helperPath = await ensureTextInserterHelper();
  const helperDirectory = path.join(app.getPath("userData"), "helpers", "Open Assist Text Inserter");
  fs.mkdirSync(helperDirectory, { recursive: true });
  const textPath = path.join(helperDirectory, `transcript-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}.txt`);
  fs.writeFileSync(textPath, text, "utf8");
  try {
    const timeoutMs = Math.max(3000, Math.min(45_000, 1400 + Array.from(text).length * 18));
    const { stdout } = await runProcessWithOutput(helperPath, ["--strategy", strategy, "--text-file", textPath], timeoutMs);
    const payload = JSON.parse(stdout.trim().split(/\r?\n/).pop() || "{}") as { ok?: boolean; method?: string };
    return { ok: payload.ok === true, method: payload.method || strategy };
  } finally {
    fs.rmSync(textPath, { force: true });
  }
}

async function pasteTextByNativeHelper(text: string) {
  if (process.platform !== "darwin") return { ok: false, method: "native-transient-paste-unavailable" };
  const helperPath = await ensureTextInserterHelper();
  const helperDirectory = path.join(app.getPath("userData"), "helpers", "Open Assist Text Inserter");
  fs.mkdirSync(helperDirectory, { recursive: true });
  const textPath = path.join(helperDirectory, `transcript-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}.txt`);
  fs.writeFileSync(textPath, text, "utf8");
  try {
    const timeoutMs = Math.max(4000, Math.min(45_000, 1800 + Array.from(text).length * 10));
    const { stdout } = await runProcessWithOutput(helperPath, ["--strategy", "transient-paste", "--text-file", textPath], timeoutMs);
    const payload = JSON.parse(stdout.trim().split(/\r?\n/).pop() || "{}") as { ok?: boolean; method?: string };
    return { ok: payload.ok === true, method: payload.method || "transient-paste" };
  } finally {
    fs.rmSync(textPath, { force: true });
  }
}

async function typeTextForTarget(text: string, target: FrontmostApplicationSnapshot | null | undefined) {
  const strategy = typingStrategyForTarget(target);
  try {
    const helperResult = await typeTextByNativeHelper(text, strategy);
    if (helperResult.ok) return helperResult;
  } catch (error) {
    debugLog(`native text inserter failed: ${error instanceof Error ? error.message : String(error)}`);
  }

  if (await typeTextByAppleScript(text)) {
    return { ok: true, method: "applescript-keystroke-fallback" };
  }

  return { ok: false, method: strategy };
}

async function pasteTextWithTransientClipboard(text: string, target: FrontmostApplicationSnapshot | null | undefined) {
  const targetBundle = target?.bundleIdentifier?.trim().toLowerCase() ?? "";
  const canTrustNativePasteSignal = Boolean(targetBundle && targetBundle !== "missing value");
  if (canTrustNativePasteSignal) {
    try {
      const nativeResult = await pasteTextByNativeHelper(text);
      if (nativeResult.ok) return nativeResult;
    } catch (error) {
      debugLog(`native transient paste failed: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  if (!canTrustNativePasteSignal) {
    return { ok: false, method: "transient-paste-untrusted-target" };
  }

  const previousText = clipboard.readText();
  clipboard.writeText(text);
  const didPaste = await triggerPasteShortcutWithRetry();
  setTimeout(() => {
    try {
      if (clipboard.readText() === text) {
        clipboard.writeText(previousText);
      }
    } catch {
      // Best-effort clipboard restore, same privacy-first shape as the native app.
    }
  }, 450);
  return { ok: didPaste, method: "electron-transient-clipboard" };
}

// Shown when an assistant turn finishes while the user is elsewhere (another
// thread, another app, or the window is hidden). Clicking it brings the app
// forward and opens the finished thread.
function showThreadCompletionNotification(payload: { threadID?: string; title?: string; body?: string }) {
  if (!Notification.isSupported()) return { ok: false };
  const threadID = String(payload.threadID ?? "").trim();
  const notification = new Notification({
    title: payload.title?.trim() || "Chat finished",
    body: (payload.body ?? "").trim().slice(0, 220) || "The response is ready.",
    silent: false
  });
  notification.on("click", () => {
    try {
      app.focus({ steal: true });
    } catch {
      app.focus();
    }
    mainWindow?.show();
    mainWindow?.focus();
    if (threadID) mainWindow?.webContents.send("openassist:open-thread", threadID);
  });
  notification.show();
  return { ok: true };
}

async function insertTranscriptText(text: string): Promise<TranscriptInsertionResult> {
  const trimmed = typeof text === "string" ? text.trim() : "";
  if (!trimmed) return { ok: false, result: "empty" };

  // Reuse the snapshot captured when dictation stopped (fired in
  // stopConfiguredVoiceInput) instead of paying another osascript round-trip.
  const frontmost = await frontmostApplicationSnapshotWithMaxAge(2_500);
  const target = frontmost && !isOwnApplicationSnapshot(frontmost) ? frontmost : lastExternalApplication;
  const resultTarget = target ?? undefined;

  // Only re-activate (and pay the 180ms settle delay) when the target is NOT
  // already the frontmost app. In the normal dictation flow the user never
  // left the target app, so this whole step is skipped.
  if (target && target.pid !== frontmost?.pid) {
    const activated = await activateApplicationSnapshot(target);
    if (activated) await delay(180);
  }

  const targetBundle = target?.bundleIdentifier?.trim().toLowerCase() ?? "";
  const shouldTypeFirst = targetBundle === "com.microsoft.rdc.macos";

  if (shouldTypeFirst) {
    const typed = await typeTextForTarget(trimmed, target);
    if (typed.ok) {
      return { ok: true, result: "typed", target: resultTarget, method: typed.method };
    }
  }

  const pasted = await pasteTextWithTransientClipboard(trimmed, target);
  if (pasted.ok) {
    return { ok: true, result: "pasted", target: resultTarget, method: pasted.method };
  }

  if (!shouldTypeFirst) {
    const typed = await typeTextForTarget(trimmed, target);
    if (typed.ok) {
      return { ok: true, result: "typed", target: resultTarget, method: typed.method };
    }
  }

  return {
    ok: false,
    result: "not-inserted",
    target: resultTarget,
    error: "Could not paste into the focused app.",
    debugStatus: shouldTypeFirst ? "typing-first-and-paste-failed" : "paste-and-typing-failed"
  };
}

function openAssistRepoRoot() {
  return path.basename(process.cwd()) === "electron-react" ? path.dirname(process.cwd()) : process.cwd();
}

type WorkspaceLaunchStyle = "openDocuments" | "revealInFinder";
type WorkspaceLaunchTarget = {
  id: string;
  title: string;
  bundleIdentifiers: string[];
  appNames: string[];
  candidatePaths: string[];
  fallbackSymbol: string;
  launchStyle: WorkspaceLaunchStyle;
  remembersAsPreferred: boolean;
};

const workspaceLaunchTargets: WorkspaceLaunchTarget[] = [
  {
    id: "vscode",
    title: "VS Code",
    bundleIdentifiers: ["com.microsoft.VSCode"],
    appNames: ["Visual Studio Code"],
    candidatePaths: ["/Applications/Visual Studio Code.app"],
    fallbackSymbol: "code",
    launchStyle: "openDocuments",
    remembersAsPreferred: true
  },
  {
    id: "vscodeInsiders",
    title: "VS Code Insiders",
    bundleIdentifiers: ["com.microsoft.VSCodeInsiders"],
    appNames: ["Visual Studio Code - Insiders"],
    candidatePaths: ["/Applications/Visual Studio Code - Insiders.app"],
    fallbackSymbol: "code",
    launchStyle: "openDocuments",
    remembersAsPreferred: true
  },
  {
    id: "cursor",
    title: "Cursor",
    bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
    appNames: ["Cursor"],
    candidatePaths: ["/Applications/Cursor.app"],
    fallbackSymbol: "command",
    launchStyle: "openDocuments",
    remembersAsPreferred: true
  },
  {
    id: "windsurf",
    title: "Windsurf",
    bundleIdentifiers: ["com.exafunction.windsurf"],
    appNames: ["Windsurf"],
    candidatePaths: ["/Applications/Windsurf.app"],
    fallbackSymbol: "wind",
    launchStyle: "openDocuments",
    remembersAsPreferred: true
  },
  {
    id: "antigravity",
    title: "Antigravity",
    bundleIdentifiers: ["com.google.antigravity"],
    appNames: ["Antigravity"],
    candidatePaths: ["/Applications/Antigravity.app"],
    fallbackSymbol: "sparkles",
    launchStyle: "openDocuments",
    remembersAsPreferred: true
  },
  {
    id: "finder",
    title: "Finder",
    bundleIdentifiers: ["com.apple.finder"],
    appNames: ["Finder"],
    candidatePaths: ["/System/Library/CoreServices/Finder.app"],
    fallbackSymbol: "folder",
    launchStyle: "revealInFinder",
    remembersAsPreferred: false
  },
  {
    id: "terminal",
    title: "Terminal",
    bundleIdentifiers: ["com.apple.Terminal"],
    appNames: ["Terminal"],
    candidatePaths: ["/System/Applications/Utilities/Terminal.app", "/Applications/Utilities/Terminal.app"],
    fallbackSymbol: "terminal",
    launchStyle: "openDocuments",
    remembersAsPreferred: false
  },
  {
    id: "xcode",
    title: "Xcode",
    bundleIdentifiers: ["com.apple.dt.Xcode"],
    appNames: ["Xcode"],
    candidatePaths: ["/Applications/Xcode.app"],
    fallbackSymbol: "hammer",
    launchStyle: "openDocuments",
    remembersAsPreferred: true
  },
  {
    id: "androidStudio",
    title: "Android Studio",
    bundleIdentifiers: ["com.google.android.studio"],
    appNames: ["Android Studio"],
    candidatePaths: ["/Applications/Android Studio.app"],
    fallbackSymbol: "code",
    launchStyle: "openDocuments",
    remembersAsPreferred: true
  }
];

function findApplicationByBundleIdentifier(bundleIdentifier: string) {
  if (process.platform !== "darwin") return undefined;
  try {
    const output = execFileSync("mdfind", [`kMDItemCFBundleIdentifier == '${bundleIdentifier}'`], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 800
    });
    return output
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find((line) => line.endsWith(".app") && fs.existsSync(line));
  } catch {
    return undefined;
  }
}

function applicationPathForTarget(target: WorkspaceLaunchTarget) {
  const homeApplications = target.candidatePaths.map((candidate) =>
    candidate.startsWith("/Applications/")
      ? path.join(app.getPath("home"), candidate.replace(/^\/Applications\//, "Applications/"))
      : candidate
  );
  const candidate = [...target.candidatePaths, ...homeApplications].find((item) => fs.existsSync(item));
  if (candidate) return candidate;
  for (const bundleIdentifier of target.bundleIdentifiers) {
    const match = findApplicationByBundleIdentifier(bundleIdentifier);
    if (match) return match;
  }
  return undefined;
}

function applicationBundleIconPath(applicationPath: string) {
  if (!applicationPath.endsWith(".app")) return undefined;
  const resourcesPath = path.join(applicationPath, "Contents", "Resources");
  const plistPath = path.join(applicationPath, "Contents", "Info.plist");
  const candidates: string[] = [];
  if (fs.existsSync(plistPath)) {
    for (const key of ["CFBundleIconFile", "CFBundleIconName"]) {
      try {
        const output = execFileSync("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", plistPath], {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
          timeout: 800
        }).trim();
        if (output) {
          candidates.push(output.endsWith(".icns") ? output : `${output}.icns`);
        }
      } catch {
        // Some apps use only one of these keys.
      }
    }
  }
  if (fs.existsSync(resourcesPath)) {
    const resourceIcons = fs.readdirSync(resourcesPath)
      .filter((fileName) => fileName.toLowerCase().endsWith(".icns"))
      .sort((left, right) => {
        const leftApp = /app|icon/i.test(left) ? 0 : 1;
        const rightApp = /app|icon/i.test(right) ? 0 : 1;
        return leftApp - rightApp || left.localeCompare(right);
      });
    candidates.push(...resourceIcons);
  }
  for (const fileName of candidates) {
    const iconPath = path.isAbsolute(fileName) ? fileName : path.join(resourcesPath, fileName);
    if (fs.existsSync(iconPath)) return iconPath;
  }
  return undefined;
}

function nativeImageDataURLFromPath(iconPath?: string) {
  if (!iconPath) return "";
  const imagePath = iconPath.toLowerCase().endsWith(".icns") ? convertedPNGPathForIcon(iconPath) ?? iconPath : iconPath;
  const image = nativeImage.createFromPath(imagePath);
  if (image.isEmpty()) return "";
  return image.resize({ width: 48, height: 48, quality: "best" }).toDataURL();
}

function convertedPNGPathForIcon(iconPath: string) {
  try {
    const stat = fs.statSync(iconPath);
    const cacheDirectory = path.join(app.getPath("userData"), "workspace-icons");
    fs.mkdirSync(cacheDirectory, { recursive: true });
    const cacheKey = Buffer.from(`${iconPath}:${stat.mtimeMs}:${stat.size}`).toString("base64url");
    const outputPath = path.join(cacheDirectory, `${cacheKey}.png`);
    if (!fs.existsSync(outputPath)) {
      execFileSync("/usr/bin/sips", ["-s", "format", "png", iconPath, "--out", outputPath], {
        stdio: ["ignore", "ignore", "ignore"],
        timeout: 1500
      });
    }
    return fs.existsSync(outputPath) ? outputPath : undefined;
  } catch {
    return undefined;
  }
}

async function workspaceLaunchTargetSnapshots() {
  const snapshots = await Promise.all(workspaceLaunchTargets.map(async (target) => {
    const applicationPath = applicationPathForTarget(target);
    let iconDataURL = applicationPath ? nativeImageDataURLFromPath(applicationBundleIconPath(applicationPath)) : "";
    if (applicationPath) {
      try {
        iconDataURL = iconDataURL || (await app.getFileIcon(applicationPath, { size: "normal" })).toDataURL();
      } catch {
        iconDataURL = "";
      }
    }
    return {
      id: target.id,
      title: target.title,
      isInstalled: target.launchStyle === "revealInFinder" || Boolean(applicationPath),
      remembersAsPreferred: target.remembersAsPreferred,
      fallbackSymbol: target.fallbackSymbol,
      iconDataURL
    };
  }));
  return snapshots;
}

function workspacePathFromRequest(requestedPath?: unknown) {
  const rawPath = typeof requestedPath === "string" ? requestedPath.trim() : "";
  if (!rawPath) {
    const fallbackPath = openAssistRepoRoot();
    return { path: fallbackPath, directory: fallbackPath, isFile: false };
  }
  const expandedPath = rawPath.startsWith("~")
    ? path.join(app.getPath("home"), rawPath.slice(1))
    : rawPath;
  const resolvedPath = path.resolve(expandedPath);
  if (!fs.existsSync(resolvedPath)) {
    const fallbackPath = openAssistRepoRoot();
    return { path: fallbackPath, directory: fallbackPath, isFile: false };
  }
  try {
    const stat = fs.statSync(resolvedPath);
    return {
      path: resolvedPath,
      directory: stat.isDirectory() ? resolvedPath : path.dirname(resolvedPath),
      isFile: stat.isFile()
    };
  } catch {
    const fallbackPath = openAssistRepoRoot();
    return { path: fallbackPath, directory: fallbackPath, isFile: false };
  }
}

async function openWorkspaceLaunchTarget(targetID: string, workspaceRootPath?: unknown) {
  const target = workspaceLaunchTargets.find((item) => item.id === targetID);
  if (!target) return { ok: false, error: "Unknown workspace target." };
  const requested = workspacePathFromRequest(workspaceRootPath);
  if (target.launchStyle === "revealInFinder") {
    if (requested.isFile) {
      shell.showItemInFolder(requested.path);
      return { ok: true, path: requested.path };
    }
    const error = await shell.openPath(requested.directory);
    return error ? { ok: false, error, path: requested.directory } : { ok: true, path: requested.directory };
  }

  const applicationPath = applicationPathForTarget(target);
  if (!applicationPath && !target.bundleIdentifiers[0]) {
    return { ok: false, error: `${target.title} is not installed on this Mac.` };
  }

  const args = applicationPath
    ? ["-a", target.appNames[0], requested.path]
    : ["-b", target.bundleIdentifiers[0], requested.path];
  const child = spawn("open", args, { detached: true, stdio: "ignore" });
  child.unref();
  return { ok: true, path: requested.path };
}

function exactFilePathFromRequest(requestedPath?: unknown) {
  const rawPath = typeof requestedPath === "string" ? requestedPath.trim() : "";
  if (!rawPath) return null;
  const expandedPath = rawPath.startsWith("~")
    ? path.join(app.getPath("home"), rawPath.slice(1))
    : rawPath;
  const resolvedPath = path.resolve(expandedPath);
  if (!fs.existsSync(resolvedPath)) return null;
  try {
    return fs.statSync(resolvedPath).isFile() ? resolvedPath : null;
  } catch {
    return null;
  }
}

async function openFileLaunchTarget(targetID: string, requestedPath?: unknown) {
  const target = workspaceLaunchTargets.find((item) => item.id === targetID);
  if (!target) return { ok: false, error: "Unknown file target." };
  const filePath = exactFilePathFromRequest(requestedPath);
  if (!filePath) return { ok: false, error: "The selected note file was not found." };
  if (target.launchStyle === "revealInFinder") {
    shell.showItemInFolder(filePath);
    return { ok: true, path: filePath };
  }

  const applicationPath = applicationPathForTarget(target);
  if (!applicationPath && !target.bundleIdentifiers[0]) {
    return { ok: false, error: `${target.title} is not installed on this Mac.` };
  }

  const args = applicationPath
    ? ["-a", target.appNames[0], filePath]
    : ["-b", target.bundleIdentifiers[0], filePath];
  const child = spawn("open", args, { detached: true, stdio: "ignore" });
  child.unref();
  return { ok: true, path: filePath };
}

function titleForMarkdownImport(filePath: string, markdown: string) {
  const headingMatch = String(markdown ?? "").match(/^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$/m);
  const rawTitle = headingMatch?.[1] || path.basename(filePath, path.extname(filePath));
  return rawTitle
    .replace(/\[([^\]]*)\]\([^)]+\)/g, "$1")
    .replace(/[*_`~>#]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120) || "Imported note";
}

function appleSpeechHelperSourcePath() {
  const candidates = [
    path.join(app.getAppPath(), "electron", "helpers", "apple-speech-helper.swift"),
    path.join(process.cwd(), "electron", "helpers", "apple-speech-helper.swift")
  ];
  return candidates.find((candidate) => fs.existsSync(candidate));
}

function appleSpeechHelperInfoPlistPath() {
  const candidates = [
    path.join(app.getAppPath(), "electron", "helpers", "apple-speech-helper-info.plist"),
    path.join(process.cwd(), "electron", "helpers", "apple-speech-helper-info.plist")
  ];
  return candidates.find((candidate) => fs.existsSync(candidate));
}

function appleEventKitHelperSourcePath() {
  const candidates = [
    path.join(app.getAppPath(), "electron", "helpers", "apple-eventkit-helper.swift"),
    path.join(process.cwd(), "electron", "helpers", "apple-eventkit-helper.swift"),
    path.join(openAssistRepoRoot(), "electron-react", "electron", "helpers", "apple-eventkit-helper.swift")
  ];
  return candidates.find((candidate) => fs.existsSync(candidate));
}

function appleEventKitHelperInfoPlistPath() {
  const candidates = [
    path.join(app.getAppPath(), "electron", "helpers", "apple-eventkit-helper-info.plist"),
    path.join(process.cwd(), "electron", "helpers", "apple-eventkit-helper-info.plist"),
    path.join(openAssistRepoRoot(), "electron-react", "electron", "helpers", "apple-eventkit-helper-info.plist")
  ];
  return candidates.find((candidate) => fs.existsSync(candidate));
}

async function ensureAppleEventKitHelper() {
  const sourcePath = appleEventKitHelperSourcePath();
  if (!sourcePath) throw new Error("Apple EventKit helper source was not found.");
  const infoPlistPath = appleEventKitHelperInfoPlistPath();
  if (!infoPlistPath) throw new Error("Apple EventKit helper Info.plist was not found.");
  const helperBuildVersion = "2026-06-21-eventkit-helper-v1";
  const helperBundleIdentifier = "com.developingadventures.OpenAssist.ElectronAppleEventKitHelper";
  const helperDirectory = path.join(app.getPath("userData"), "helpers");
  fs.mkdirSync(helperDirectory, { recursive: true });
  const helperAppPath = path.join(helperDirectory, "Open Assist Apple EventKit Helper.app");
  const contentsPath = path.join(helperAppPath, "Contents");
  const macOSPath = path.join(contentsPath, "MacOS");
  const infoPlistOutputPath = path.join(contentsPath, "Info.plist");
  const buildMarkerPath = path.join(helperDirectory, ".openassist-apple-eventkit-helper-build");
  const helperPath = path.join(macOSPath, "apple-eventkit-helper");
  const sourceStat = fs.statSync(sourcePath);
  const plistStat = fs.statSync(infoPlistPath);
  const helperStat = fs.existsSync(helperPath) ? fs.statSync(helperPath) : null;
  const plistOutputStat = fs.existsSync(infoPlistOutputPath) ? fs.statSync(infoPlistOutputPath) : null;
  const buildMarker = fs.existsSync(buildMarkerPath) ? fs.readFileSync(buildMarkerPath, "utf8").trim() : "";
  if (
    !helperStat ||
    !plistOutputStat ||
    helperStat.mtimeMs < sourceStat.mtimeMs ||
    plistOutputStat.mtimeMs < plistStat.mtimeMs ||
    buildMarker !== helperBuildVersion
  ) {
    fs.mkdirSync(macOSPath, { recursive: true });
    fs.copyFileSync(infoPlistPath, infoPlistOutputPath);
    await runProcess("/usr/bin/swiftc", [
      "-target",
      "arm64-apple-macos26.0",
      "-framework",
      "EventKit",
      "-Xlinker",
      "-sectcreate",
      "-Xlinker",
      "__TEXT",
      "-Xlinker",
      "__info_plist",
      "-Xlinker",
      infoPlistPath,
      sourcePath,
      "-o",
      helperPath
    ]);
    fs.chmodSync(helperPath, 0o755);
    await runProcess("/usr/bin/codesign", [
      "--force",
      "--sign",
      "-",
      "--identifier",
      helperBundleIdentifier,
      helperAppPath
    ]);
    fs.writeFileSync(buildMarkerPath, helperBuildVersion, "utf8");
  }
  return helperAppPath;
}

async function runAppleEventKitCommand(command: Record<string, unknown>) {
  if (process.platform !== "darwin") {
    throw new Error("Apple Reminders and Apple Calendar integration is only available on macOS.");
  }
  const helperAppPath = await ensureAppleEventKitHelper();
  const helperPath = path.join(helperAppPath, "Contents", "MacOS", "apple-eventkit-helper");
  const { stdout } = await runProcessWithOutput(helperPath, ["--json", JSON.stringify(command)], 90_000);
  const line = stdout.trim().split(/\r?\n/).filter(Boolean).pop();
  if (!line) throw new Error("Apple EventKit helper did not return a response.");
  let parsed: any;
  try {
    parsed = JSON.parse(line);
  } catch {
    throw new Error(`Apple EventKit helper returned invalid JSON: ${line}`);
  }
  if (parsed?.ok !== true) {
    throw new Error(String(parsed?.error ?? "Apple EventKit helper failed."));
  }
  return parsed.data;
}

setAppleEventKitCommandRunner(runAppleEventKitCommand);

async function ensureAppleSpeechHelper() {
  const sourcePath = appleSpeechHelperSourcePath();
  if (!sourcePath) throw new Error("Apple Speech helper source was not found.");
  const infoPlistPath = appleSpeechHelperInfoPlistPath();
  if (!infoPlistPath) throw new Error("Apple Speech helper Info.plist was not found.");
  const helperBuildVersion = "2026-06-12-launchservices-target-26";
  const helperBundleIdentifier = "com.developingadventures.OpenAssist.ElectronAppleSpeechHelper";
  const helperDirectory = path.join(app.getPath("userData"), "helpers");
  fs.mkdirSync(helperDirectory, { recursive: true });
  const helperAppPath = path.join(helperDirectory, "Open Assist Speech Helper.app");
  const contentsPath = path.join(helperAppPath, "Contents");
  const macOSPath = path.join(contentsPath, "MacOS");
  const infoPlistOutputPath = path.join(contentsPath, "Info.plist");
  const legacyBuildMarkerPath = path.join(contentsPath, ".openassist-helper-build");
  const buildMarkerPath = path.join(helperDirectory, ".openassist-apple-speech-helper-build");
  const helperPath = path.join(macOSPath, "apple-speech-helper");
  const sourceStat = fs.statSync(sourcePath);
  const plistStat = fs.statSync(infoPlistPath);
  const helperStat = fs.existsSync(helperPath) ? fs.statSync(helperPath) : null;
  const plistOutputStat = fs.existsSync(infoPlistOutputPath) ? fs.statSync(infoPlistOutputPath) : null;
  const buildMarker = fs.existsSync(buildMarkerPath) ? fs.readFileSync(buildMarkerPath, "utf8").trim() : "";
  if (
    !helperStat ||
    !plistOutputStat ||
    helperStat.mtimeMs < sourceStat.mtimeMs ||
    plistOutputStat.mtimeMs < plistStat.mtimeMs ||
    buildMarker !== helperBuildVersion ||
    fs.existsSync(legacyBuildMarkerPath)
  ) {
    fs.mkdirSync(macOSPath, { recursive: true });
    fs.copyFileSync(infoPlistPath, infoPlistOutputPath);
    fs.rmSync(legacyBuildMarkerPath, { force: true });
    await runProcess("/usr/bin/swiftc", [
      "-target",
      "arm64-apple-macos26.0",
      "-framework",
      "AVFoundation",
      "-framework",
      "CoreAudio",
      "-framework",
      "Speech",
      "-Xlinker",
      "-sectcreate",
      "-Xlinker",
      "__TEXT",
      "-Xlinker",
      "__info_plist",
      "-Xlinker",
      infoPlistPath,
      sourcePath,
      "-o",
      helperPath
    ]);
    fs.chmodSync(helperPath, 0o755);
    await runProcess("/usr/bin/codesign", [
      "--force",
      "--sign",
      "-",
      "--identifier",
      helperBundleIdentifier,
      helperAppPath
    ]);
    fs.writeFileSync(buildMarkerPath, helperBuildVersion, "utf8");
  }
  return helperAppPath;
}

function whisperHelperSourcePath() {
  const candidates = [
    path.join(app.getAppPath(), "electron", "helpers", "whisper-transcribe-helper.swift"),
    path.join(process.cwd(), "electron", "helpers", "whisper-transcribe-helper.swift"),
    path.join(openAssistRepoRoot(), "electron-react", "electron", "helpers", "whisper-transcribe-helper.swift")
  ];
  return candidates.find((candidate) => fs.existsSync(candidate));
}

function whisperFrameworkSourcePath() {
  const candidates = [
    path.join(app.getAppPath(), "electron", "helpers", "whisper.framework"),
    path.join(process.cwd(), "electron", "helpers", "whisper.framework"),
    path.join(openAssistRepoRoot(), "electron-react", "electron", "helpers", "whisper.framework"),
    path.join(openAssistRepoRoot(), "Vendor", "Whisper", "whisper.xcframework", "macos-arm64_x86_64", "whisper.framework")
  ];
  return candidates.find((candidate) => fs.existsSync(path.join(candidate, "whisper")));
}

async function ensureWhisperHelper() {
  const sourcePath = whisperHelperSourcePath();
  if (!sourcePath) throw new Error("whisper.cpp helper source was not found.");
  const frameworkSourcePath = whisperFrameworkSourcePath();
  if (!frameworkSourcePath) throw new Error("whisper.cpp framework was not found.");

  const helperDirectory = path.join(app.getPath("userData"), "helpers", "Open Assist Whisper Helper");
  const frameworksDirectory = path.join(helperDirectory, "Frameworks");
  const frameworkOutputPath = path.join(frameworksDirectory, "whisper.framework");
  const helperPath = path.join(helperDirectory, "whisper-transcribe-helper");
  const sourceStat = fs.statSync(sourcePath);
  const frameworkSourceBinary = path.join(frameworkSourcePath, "whisper");
  const frameworkOutputBinary = path.join(frameworkOutputPath, "whisper");
  const frameworkSourceStat = fs.statSync(frameworkSourceBinary);
  const helperStat = fs.existsSync(helperPath) ? fs.statSync(helperPath) : null;
  const copiedFrameworkStat = fs.existsSync(frameworkOutputBinary) ? fs.statSync(frameworkOutputBinary) : null;
  const needsFrameworkCopy = !copiedFrameworkStat || copiedFrameworkStat.mtimeMs < frameworkSourceStat.mtimeMs;
  const needsCompile =
    !helperStat ||
    needsFrameworkCopy ||
    helperStat.mtimeMs < sourceStat.mtimeMs ||
    helperStat.mtimeMs < frameworkSourceStat.mtimeMs;

  fs.mkdirSync(frameworksDirectory, { recursive: true });
  if (needsFrameworkCopy) {
    fs.rmSync(frameworkOutputPath, { recursive: true, force: true });
    await runProcess("/usr/bin/ditto", [frameworkSourcePath, frameworkOutputPath]);
  }

  if (needsCompile) {
    await runProcess("/usr/bin/swiftc", [
      "-framework",
      "AVFoundation",
      "-F",
      frameworksDirectory,
      "-framework",
      "whisper",
      "-Xlinker",
      "-rpath",
      "-Xlinker",
      "@executable_path/Frameworks",
      sourcePath,
      "-o",
      helperPath
    ]);
    fs.chmodSync(helperPath, 0o755);
    try {
      await runProcess("/usr/bin/codesign", ["--force", "--sign", "-", frameworkOutputPath]);
      await runProcess("/usr/bin/codesign", ["--force", "--sign", "-", helperPath]);
    } catch {
      // The helper can still run ad-hoc in local development if signing is unavailable.
    }
  }

  return helperPath;
}

function whisperModelsDirectory() {
  return path.join(app.getPath("home"), "Library", "Application Support", "OpenAssist", "Models");
}

function whisperModelPath(modelID: string) {
  return path.join(whisperModelsDirectory(), `ggml-${modelID}.bin`);
}

function whisperCoreMLDirectoryPath(modelID: string) {
  return path.join(whisperModelsDirectory(), `ggml-${modelID}-encoder.mlmodelc`);
}

function installedWhisperModelIDs() {
  return whisperModelIDs.filter((modelID) => fs.existsSync(whisperModelPath(modelID)));
}

function resolveInstalledWhisperModel(preferredModelID: string) {
  const normalizedPreferred = whisperModelIDs.includes(preferredModelID as (typeof whisperModelIDs)[number])
    ? preferredModelID
    : "";
  const candidates = [...new Set([normalizedPreferred, ...whisperModelIDs].filter(Boolean))];
  const modelID = candidates.find((candidate) => fs.existsSync(whisperModelPath(candidate)));
  if (!modelID) return null;
  return {
    modelID,
    modelPath: whisperModelPath(modelID)
  };
}

function readJsonFile<T>(filePath: string): T | null {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8")) as T;
  } catch {
    return null;
  }
}

function waitForVoiceFile(sessionDirectory: string, names: string[], timeoutMs: number) {
  const startedAt = Date.now();
  return new Promise<{
    name: string;
    payload: { type?: string; text?: string; message?: string; audioPath?: string; fileName?: string; mimeType?: string };
  } | null>((resolve) => {
    const timer = setInterval(() => {
      for (const name of names) {
        const payload = readJsonFile<{ type?: string; text?: string; message?: string }>(path.join(sessionDirectory, name));
        if (payload) {
          clearInterval(timer);
          resolve({ name, payload });
          return;
        }
      }
      if (Date.now() - startedAt > timeoutMs) {
        clearInterval(timer);
        resolve(null);
      }
    }, 25);
  });
}

// Keep this stage light: the HUD's waveform applies its own noise floor and
// per-bar attack/release envelope. Stacking a high floor + heavy compression
// + slow EMA here crushed normal speech to ~25% bar height and smeared
// syllables — the "doesn't react to my voice" complaint.
function normalizedVoiceLevel(value: unknown) {
  const level = Number(value);
  if (!Number.isFinite(level)) return null;
  const clamped = Math.max(0, Math.min(1, level));
  const noiseFloor = 0.06;
  if (clamped <= noiseFloor) return 0;
  return Math.pow((clamped - noiseFloor) / (1 - noiseFloor), 0.85);
}

function smoothedVoiceHUDLevel(level: number) {
  // De-jitter only (the file sampling is ~20 Hz); the visual envelope lives
  // in the HUD's per-bar attack/release.
  const smoothing = level > smoothedVoiceLevel ? 0.75 : 0.35;
  smoothedVoiceLevel += (level - smoothedVoiceLevel) * smoothing;
  if (smoothedVoiceLevel < 0.02) return 0;
  return Math.max(0, Math.min(1, smoothedVoiceLevel));
}

function stopVoiceLevelPolling() {
  if (voiceHUDLevelTimer) {
    clearInterval(voiceHUDLevelTimer);
    voiceHUDLevelTimer = null;
  }
  stopVoiceCaptureHUDKeepAlive();
  voiceHUDLevelMtime = 0;
  smoothedVoiceLevel = 0;
}

function voiceStartupTimeoutMessage(sessionDirectory: string, fallback: string) {
  const status = readJsonFile<{ message?: string }>(path.join(sessionDirectory, "status.json"));
  const message = status?.message?.trim();
  if (/Speech Recognition permission/i.test(message ?? "")) {
    return "Apple Speech is waiting for macOS Speech Recognition permission. Open System Settings > Privacy & Security > Speech Recognition, allow Open Assist Speech Helper, then try again.";
  }
  if (/Microphone permission/i.test(message ?? "")) {
    return "Apple Speech is waiting for macOS Microphone permission. Open System Settings > Privacy & Security > Microphone, allow Open Assist Speech Helper, then try again.";
  }
  return message ? `${message} Allow it in the macOS prompt, then try again.` : fallback;
}

function requestVoiceHelperStop(sessionDirectory: string) {
  try {
    fs.writeFileSync(path.join(sessionDirectory, "stop"), "1", "utf8");
  } catch {
    // Best effort. The helper may already be gone.
  }
}

function voiceCaptureRootDirectory() {
  return path.join(app.getPath("userData"), "voice-captures");
}

function isProcessAlive(pid: number) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function terminateVoiceHelperPid(pid: number | undefined, reason: string) {
  if (!pid || !Number.isFinite(pid) || pid <= 0) return;
  if (!isProcessAlive(pid)) return;
  debugLog(`terminating voice helper pid=${pid} reason="${reason}"`);
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    return;
  }
  const timer = setTimeout(() => {
    if (!isProcessAlive(pid)) return;
    try {
      debugLog(`force killing voice helper pid=${pid} reason="${reason}"`);
      process.kill(pid, "SIGKILL");
    } catch {
      // The helper already exited.
    }
  }, 1200);
  timer.unref?.();
}

function terminateVoiceHelperCapture(captureState: NonNullable<typeof voiceCapture>, reason: string) {
  captureState.helperProcess?.kill("SIGTERM");
  terminateVoiceHelperPid(captureState.helperPid, reason);
}

async function listAppleSpeechHelperProcesses() {
  if (process.platform !== "darwin") return [];
  try {
    const { stdout } = await runProcessWithOutput("/bin/ps", ["-axo", "pid=,etimes=,command="], 5000);
    return stdout
      .split(/\r?\n/)
      .map((line) => {
        const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.+)$/);
        if (!match) return null;
        return {
          pid: Number(match[1]),
          ageMs: Number(match[2]) * 1000,
          command: match[3]
        };
      })
      .filter((item): item is { pid: number; ageMs: number; command: string } => Boolean(item))
      .filter((item) => item.command.includes("apple-speech-helper") && item.command.includes("Open Assist Speech Helper.app"));
  } catch (error) {
    verboseLog(`voice helper process scan failed: ${error instanceof Error ? error.message : String(error)}`);
    return [];
  }
}

async function cleanupStaleVoiceHelpers(reason: string, keepPid?: number) {
  const helpers = await listAppleSpeechHelperProcesses();
  let killed = 0;
  for (const helper of helpers) {
    if (keepPid && helper.pid === keepPid) continue;
    killed += 1;
    terminateVoiceHelperPid(helper.pid, reason);
  }
  if (killed > 0) {
    debugLog(`voice helper cleanup reason="${reason}" killed=${killed}`);
  }
}

function cleanupOldVoiceCaptureDirectories() {
  const root = voiceCaptureRootDirectory();
  try {
    if (!fs.existsSync(root)) return;
    const activeDirectory = voiceCapture?.sessionDirectory;
    const entries = fs.readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => {
        const fullPath = path.join(root, entry.name);
        try {
          return { path: fullPath, mtimeMs: fs.statSync(fullPath).mtimeMs };
        } catch {
          return null;
        }
      })
      .filter((entry): entry is { path: string; mtimeMs: number } => Boolean(entry))
      .sort((lhs, rhs) => rhs.mtimeMs - lhs.mtimeMs);
    const maxAgeMs = 24 * 60 * 60 * 1000;
    const maxKeptDirectories = 80;
    let removed = 0;
    entries.forEach((entry, index) => {
      if (activeDirectory && entry.path === activeDirectory) return;
      const isOld = Date.now() - entry.mtimeMs > maxAgeMs;
      const isPastLimit = index >= maxKeptDirectories;
      if (!isOld && !isPastLimit) return;
      fs.rmSync(entry.path, { recursive: true, force: true });
      removed += 1;
    });
    if (removed > 0) {
      debugLog(`voice capture directory cleanup removed=${removed}`);
    }
  } catch (error) {
    debugLog(`voice capture directory cleanup failed: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function clearMismatchedVoiceCapture(engine: NonNullable<typeof voiceCapture>["engine"]) {
  if (!voiceCapture || voiceCapture.engine === engine) return;
  const captureState = voiceCapture;
  requestVoiceHelperStop(captureState.sessionDirectory);
  terminateVoiceHelperCapture(captureState, "switching voice engine");
  voiceCapture = null;
  stopVoiceLevelPolling();
}

function selectedMicrophoneArgument(options?: VoiceStartOptions) {
  if (options?.autoDetectMicrophone !== false) return null;
  const uid = options.selectedMicrophoneUID?.trim();
  return uid ? uid : null;
}

function shouldPreferExternalMicrophone(options?: VoiceStartOptions) {
  return options?.autoDetectMicrophone !== false;
}

async function listMicrophones(): Promise<MicrophoneOption[]> {
  if (process.platform !== "darwin") return [];
  const helperAppPath = await ensureAppleSpeechHelper();
  const helperPath = path.join(helperAppPath, "Contents", "MacOS", "apple-speech-helper");
  const { stdout } = await runProcessWithOutput(helperPath, ["--list-microphones"], 3500);
  try {
    const parsed = JSON.parse(stdout.trim()) as MicrophoneOption[];
    return Array.isArray(parsed)
      ? parsed
          .filter((item) => typeof item?.uid === "string" && typeof item?.name === "string")
          .map((item) => ({ uid: item.uid, name: item.name, isDefault: item.isDefault === true }))
      : [];
  } catch {
    return [];
  }
}

function launchVoiceHelperApp(helperAppPath: string, sessionDirectory: string, mode: "speech" | "recording", options?: VoiceStartOptions) {
  const helperPath = path.join(helperAppPath, "Contents", "MacOS", "apple-speech-helper");
  const args = [sessionDirectory];
  if (mode === "recording") args.push("--record-audio");
  if (shouldPreferExternalMicrophone(options)) args.push("--prefer-external-microphone");
  const microphoneUID = selectedMicrophoneArgument(options);
  if (microphoneUID) args.push("--microphone-uid", microphoneUID);
  const child = mode === "speech"
    ? spawn("/usr/bin/open", ["-n", helperAppPath, "--args", ...args], { detached: true, stdio: "ignore" })
    : spawn(helperPath, args, { detached: true, stdio: "ignore" });
  child.on("error", (error) => {
    debugLog(`voice helper launch failed: ${error instanceof Error ? error.message : String(error)}`);
  });
  child.unref();
  debugLog(`voice helper launched pid=${child.pid ?? "unknown"} mode=${mode} via=${mode === "speech" ? "launchservices" : "direct"} session=${sessionDirectory}`);
  return child;
}

function sanitizeWakePhrase(value?: unknown) {
  const phrase = String(value ?? "Hey Open Assist").replace(/\s+/g, " ").trim();
  return phrase ? phrase.slice(0, 80) : "Hey Open Assist";
}

function wakeWordCaptureRootDirectory() {
  return path.join(app.getPath("userData"), "wake-word-captures");
}

function broadcastWakeWordStatus(patch: Partial<WakeWordStatusPayload>) {
  wakeWordStatus = {
    ...wakeWordStatus,
    ...patch,
    source: "today",
    engine: patch.engine ?? wakeWordStatus.engine ?? "appleSpeechPhrase",
    phrase: sanitizeWakePhrase(patch.phrase ?? wakeWordStatus.phrase),
    message: patch.message ?? (patch.state === "error" ? undefined : wakeWordStatus.message),
    error: patch.state === "error" ? patch.error ?? wakeWordStatus.error : undefined
  };
  debugLog(`wake-word status=${wakeWordStatus.state} enabled=${wakeWordStatus.enabled === true} phrase="${wakeWordStatus.phrase}" message="${wakeWordStatus.message ?? wakeWordStatus.error ?? ""}"`);
  BrowserWindow.getAllWindows().forEach((window) => {
    if (!window.isDestroyed() && !window.webContents.isDestroyed()) {
      safeSendWebContents(window.webContents, "openassist:wake-word-status", wakeWordStatus);
    }
  });
}

function cleanupOldWakeWordCaptureDirectories() {
  const root = wakeWordCaptureRootDirectory();
  try {
    if (!fs.existsSync(root)) return;
    const activeDirectory = wakeWordCapture?.sessionDirectory;
    const entries = fs.readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => {
        const fullPath = path.join(root, entry.name);
        try {
          return { path: fullPath, mtimeMs: fs.statSync(fullPath).mtimeMs };
        } catch {
          return null;
        }
      })
      .filter((entry): entry is { path: string; mtimeMs: number } => Boolean(entry))
      .sort((lhs, rhs) => rhs.mtimeMs - lhs.mtimeMs);
    let removed = 0;
    entries.forEach((entry, index) => {
      if (activeDirectory && entry.path === activeDirectory) return;
      const isOld = Date.now() - entry.mtimeMs > 24 * 60 * 60 * 1000;
      const isPastLimit = index >= 40;
      if (!isOld && !isPastLimit) return;
      fs.rmSync(entry.path, { recursive: true, force: true });
      removed += 1;
    });
    if (removed > 0) debugLog(`wake-word capture directory cleanup removed=${removed}`);
  } catch (error) {
    debugLog(`wake-word capture directory cleanup failed: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function clearWakeWordRestartTimer() {
  if (!wakeWordRestartTimer) return;
  clearTimeout(wakeWordRestartTimer);
  wakeWordRestartTimer = null;
}

function requestWakeWordHelperStop(captureState: WakeWordCaptureState) {
  try {
    fs.writeFileSync(path.join(captureState.sessionDirectory, "stop"), "1", "utf8");
  } catch {
    // Best effort. The helper may already be closed.
  }
}

function clearWakeWordFilePolling(captureState: WakeWordCaptureState) {
  if (!captureState.pollTimer) return;
  clearInterval(captureState.pollTimer);
  captureState.pollTimer = undefined;
}

function terminateWakeWordCapture(captureState: WakeWordCaptureState, reason: string) {
  debugLog(`wake-word helper stop requested pid=${captureState.helperPid ?? "unknown"} reason="${reason}"`);
  captureState.stopping = true;
  clearWakeWordFilePolling(captureState);
  requestWakeWordHelperStop(captureState);
  captureState.helperProcess?.kill("SIGTERM");
  terminateVoiceHelperPid(captureState.helperPid, reason);
}

async function stopWakeWordForToday(reason = "manual") {
  clearWakeWordRestartTimer();
  const captureState = wakeWordCapture;
  if (captureState) {
    terminateWakeWordCapture(captureState, reason);
    wakeWordCapture = null;
  }
  if (!voiceCapture) {
    setTimeout(() => {
      void cleanupStaleVoiceHelpers(`after wake word stop: ${reason}`)
        .catch((error) => {
          debugLog(`wake-word helper cleanup failed: ${error instanceof Error ? error.message : String(error)}`);
        });
    }, 350).unref?.();
  }
  broadcastWakeWordStatus({
    state: "stopped",
    enabled: false,
    message: reason === "paused"
      ? "Wake word is paused so the microphone stays off."
      : reason === "manual"
        ? "Wake word stopped."
        : `Wake word stopped: ${reason}.`
  });
  return { ok: true, status: wakeWordStatus };
}

function scheduleWakeWordRestart(options: WakeWordStartOptions, delayMs = 900) {
  if (isQuitting || wakeWordStatus.enabled !== true) return;
  clearWakeWordRestartTimer();
  wakeWordRestartTimer = setTimeout(() => {
    wakeWordRestartTimer = null;
    void startWakeWordForToday(options).catch((error) => {
      broadcastWakeWordStatus({
        state: "error",
        enabled: true,
        error: error instanceof Error ? error.message : "Could not restart wake word."
      });
    });
  }, delayMs);
  wakeWordRestartTimer.unref?.();
}

function handleWakeWordHelperEvent(captureState: WakeWordCaptureState, payload: Record<string, unknown>, options: WakeWordStartOptions) {
  const type = String(payload.type ?? "");
  if (type === "status") {
    const message = String(payload.message ?? "Wake word is starting.");
    broadcastWakeWordStatus({
      state: "starting",
      enabled: true,
      phrase: captureState.phrase,
      startedAt: captureState.startedAt,
      message
    });
    return;
  }
  if (type === "ready") {
    captureState.ready = true;
    wakeWordCrashCount = 0;
    wakeWordLastCrashAt = 0;
    broadcastWakeWordStatus({
      state: "listening",
      enabled: true,
      phrase: captureState.phrase,
      startedAt: captureState.startedAt,
      message: "Wake word is listening for Today."
    });
    return;
  }
  if (type === "detected") {
    captureState.detected = true;
    wakeWordCrashCount = 0;
    wakeWordLastCrashAt = 0;
    clearWakeWordFilePolling(captureState);
    if (wakeWordCapture === captureState) wakeWordCapture = null;
    broadcastWakeWordStatus({
      state: "detected",
      enabled: true,
      phrase: captureState.phrase,
      detectedAt: Date.now(),
      message: "Wake word heard. Starting Today Live Voice."
    });
    return;
  }
  if (type === "error") {
    const message = String(payload.message ?? "Wake word helper failed.");
    clearWakeWordFilePolling(captureState);
    if (wakeWordCapture === captureState) wakeWordCapture = null;
    broadcastWakeWordStatus({ state: "error", enabled: true, phrase: captureState.phrase, error: message });
    const canRetry = !/(permission|requires on-device|not available for this language|macos 10\.15)/i.test(message);
    if (canRetry) scheduleWakeWordRestart(options, 1800);
  }
}

function startWakeWordFilePolling(captureState: WakeWordCaptureState, options: WakeWordStartOptions) {
  captureState.fileEventMtimes = {};
  const eventFiles = ["status.json", "ready.json", "detected.json", "error.json"];
  const poll = () => {
    if (wakeWordCapture !== captureState) {
      clearWakeWordFilePolling(captureState);
      return;
    }
    for (const fileName of eventFiles) {
      const filePath = path.join(captureState.sessionDirectory, fileName);
      try {
        const stat = fs.statSync(filePath);
        if (captureState.fileEventMtimes?.[fileName] === stat.mtimeMs) continue;
        captureState.fileEventMtimes = {
          ...(captureState.fileEventMtimes ?? {}),
          [fileName]: stat.mtimeMs
        };
        const payload = readJsonFile<Record<string, unknown>>(filePath);
        if (payload) handleWakeWordHelperEvent(captureState, payload, options);
      } catch {
        // The helper writes each event file only when that event happens.
      }
    }
  };
  poll();
  captureState.pollTimer = setInterval(poll, 160);
  captureState.pollTimer.unref?.();
}

type WakeWordStartOptions = Pick<VoiceStartOptions, "autoDetectMicrophone" | "selectedMicrophoneUID"> & {
  phrase?: string;
};

async function startWakeWordForToday(options: WakeWordStartOptions = {}) {
  if (process.platform !== "darwin") {
    const status = {
      ...wakeWordStatus,
      state: "error" as const,
      enabled: false,
      error: "Wake word is only available on macOS in this build."
    };
    broadcastWakeWordStatus(status);
    return { ok: false, status, error: status.error };
  }
  clearWakeWordRestartTimer();
  const phrase = sanitizeWakePhrase(options.phrase);
  if (wakeWordCapture && !wakeWordCapture.stopping) {
    broadcastWakeWordStatus({
      state: wakeWordStatus.state === "listening" ? "listening" : "starting",
      enabled: true,
      phrase,
      message: "Wake word is already running."
    });
    return { ok: true, status: wakeWordStatus };
  }
  await cleanupStaleVoiceHelpers("before wake word start", voiceCapture?.helperPid);
  cleanupOldWakeWordCaptureDirectories();
  const helperAppPath = await ensureAppleSpeechHelper();
  const sessionDirectory = path.join(wakeWordCaptureRootDirectory(), `${Date.now()}-${Math.random().toString(16).slice(2)}`);
  fs.mkdirSync(sessionDirectory, { recursive: true });
  const args = [sessionDirectory, "--wake-word", phrase];
  if (shouldPreferExternalMicrophone(options)) args.push("--prefer-external-microphone");
  const microphoneUID = selectedMicrophoneArgument(options);
  if (microphoneUID) args.push("--microphone-uid", microphoneUID);
  const helperProcess = spawn("/usr/bin/open", ["-n", helperAppPath, "--args", ...args], { stdio: "ignore" });
  const captureState: WakeWordCaptureState = {
    sessionDirectory,
    helperProcess,
    helperPid: helperProcess.pid,
    launchedViaLaunchServices: true,
    phrase,
    startedAt: Date.now(),
    detected: false,
    ready: false,
    stopping: false,
    stdoutBuffer: ""
  };
  wakeWordCapture = captureState;
  broadcastWakeWordStatus({
    state: "starting",
    enabled: true,
    phrase,
    startedAt: captureState.startedAt,
    message: "Starting wake word for Today."
  });
  helperProcess.stdout?.setEncoding("utf8");
  helperProcess.stdout?.on("data", (chunk) => {
    captureState.stdoutBuffer += String(chunk);
    const lines = captureState.stdoutBuffer.split(/\r?\n/);
    captureState.stdoutBuffer = lines.pop() ?? "";
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const payload = JSON.parse(trimmed) as Record<string, unknown>;
        handleWakeWordHelperEvent(captureState, payload, options);
      } catch {
        debugLog(`wake-word helper stdout=${trimmed.slice(0, 300)}`);
      }
    }
  });
  helperProcess.stderr?.setEncoding("utf8");
  helperProcess.stderr?.on("data", (chunk) => {
    const text = String(chunk).trim();
    if (text) debugLog(`wake-word helper stderr=${text.slice(0, 500)}`);
  });
  helperProcess.on("error", (error) => {
    if (wakeWordCapture === captureState) wakeWordCapture = null;
    broadcastWakeWordStatus({
      state: "error",
      enabled: true,
      phrase,
      error: error instanceof Error ? error.message : "Could not start wake word helper."
    });
  });
  helperProcess.on("close", (code, signal) => {
    if (captureState.launchedViaLaunchServices) return;
    debugLog(`wake-word helper closed pid=${captureState.helperPid ?? "unknown"} code=${code ?? "null"} signal=${signal ?? "null"} detected=${captureState.detected} stopping=${captureState.stopping}`);
    if (wakeWordCapture === captureState) wakeWordCapture = null;
    if (isQuitting) return;
    if (captureState.detected) return;
    if (captureState.stopping || wakeWordStatus.enabled !== true) {
      broadcastWakeWordStatus({ state: "stopped", enabled: false, phrase, message: "Wake word stopped." });
      return;
    }
    if (!captureState.ready) {
      const now = Date.now();
      wakeWordCrashCount = now - wakeWordLastCrashAt > 60_000 ? 1 : wakeWordCrashCount + 1;
      wakeWordLastCrashAt = now;
      if (wakeWordCrashCount >= 3) {
        broadcastWakeWordStatus({
          state: "error",
          enabled: true,
          phrase,
          error: "Wake word helper crashed before it could start. Open macOS Settings > Privacy & Security and allow Microphone and Speech Recognition for Open Assist, then restart Open Assist."
        });
        return;
      }
      broadcastWakeWordStatus({
        state: "starting",
        enabled: true,
        phrase,
        message: `Wake word helper stopped while starting. Retrying ${wakeWordCrashCount}/3...`
      });
      scheduleWakeWordRestart(options, wakeWordCrashCount === 1 ? 1800 : 4200);
      return;
    }
    broadcastWakeWordStatus({
      state: "starting",
      enabled: true,
      phrase,
      message: "Wake word helper restarted after it stopped."
    });
    scheduleWakeWordRestart(options);
  });
  startWakeWordFilePolling(captureState, options);
  return { ok: true, status: wakeWordStatus };
}

function startVoiceLevelPolling(sessionDirectory: string) {
  stopVoiceLevelPolling();
  ensureVoiceCaptureHUDKeepAlive();
  updateMenuBarVoiceStatus({ visible: true, status: "listening", level: menuBarVoiceLevel });
  const levelPath = path.join(sessionDirectory, "level.json");
  voiceHUDLevelTimer = setInterval(() => {
    if (menuBarVoiceStatus !== "listening") return;
    try {
      const stat = fs.statSync(levelPath);
      if (stat.mtimeMs === voiceHUDLevelMtime) return;
      voiceHUDLevelMtime = stat.mtimeMs;
      const payload = readJsonFile<{ level?: string | number }>(levelPath);
      const rawLevel = normalizedVoiceLevel(payload?.level);
      if (rawLevel === null) return;
      const level = smoothedVoiceHUDLevel(rawLevel);
      if (pendingVoiceHUDPayload?.status === "listening") {
        void updateVoiceHUD({ level });
      } else if (liveVoiceHUDSessionActive() && liveVoiceHUDMuted() && voiceCapture) {
        void updateVoiceHUD({ dictationLevel: level, dictationCapture: true });
      } else {
        updateMenuBarVoiceStatus({ visible: true, status: "listening", level });
      }
    } catch {
      // The helper creates this file only after the microphone starts producing samples.
    }
    // 30ms poll against the helper's ~50ms writes: mtime-gated, so this only
    // shaves sampling latency, it doesn't add extra HUD updates.
  }, 30);
}

function scheduleProcessingFeedbackSound(captureState: NonNullable<typeof voiceCapture>, delayMs = 180) {
  const timer = setTimeout(() => {
    if (voiceCapture !== captureState || !captureState.processing) return;
    playDictationFeedbackSound("processing", captureState.voiceOptions);
  }, delayMs);
  timer.unref?.();
}

async function startAppleVoiceInput(options?: VoiceStartOptions) {
  if (process.platform !== "darwin") {
    return { ok: false, error: "Native voice input is only available on macOS." };
  }
  await cleanupStaleVoiceHelpers("before Apple Speech start", voiceCapture?.helperPid);
  cleanupOldVoiceCaptureDirectories();
  clearMismatchedVoiceCapture("appleSpeech");
  if (voiceCapture) {
    return { ok: true };
  }

  const helperAppPath = await ensureAppleSpeechHelper();
  const sessionDirectory = path.join(voiceCaptureRootDirectory(), `${Date.now()}-${Math.random().toString(16).slice(2)}`);
  fs.mkdirSync(sessionDirectory, { recursive: true });
  const helperProcess = launchVoiceHelperApp(helperAppPath, sessionDirectory, "speech", options);
  voiceCapture = {
    sessionDirectory,
    appPath: helperAppPath,
    engine: "appleSpeech",
    helperProcess,
    helperPid: helperProcess.pid,
    startedAt: Date.now(),
    voiceOptions: options
  };
  ensureVoiceCaptureHUDKeepAlive();
  showActiveVoiceCaptureHUD();
  const ready = await waitForVoiceFile(sessionDirectory, ["ready.json", "error.json"], 90_000);
  if (!ready) {
    requestVoiceHelperStop(sessionDirectory);
    terminateVoiceHelperCapture(voiceCapture, "Apple Speech startup timeout");
    voiceCapture = null;
    return { ok: false, error: voiceStartupTimeoutMessage(sessionDirectory, "Voice input did not become ready in time.") };
  }
  if (ready.name === "error.json") {
    voiceCapture = null;
    return { ok: false, error: ready.payload.message ?? "Voice input failed." };
  }
  startVoiceLevelPolling(sessionDirectory);
  showActiveVoiceCaptureHUD();
  playDictationFeedbackSound("startListening", options);
  return { ok: true };
}

async function stopAppleVoiceInput() {
  const captureState = voiceCapture;
  if (!captureState) return { ok: false, text: "", error: "Voice input is not running." };
  if (captureState.engine !== "appleSpeech") return { ok: false, text: "", error: "Apple Speech voice input is not running." };
  if (captureState.processing) return { ok: false, text: "", error: "Voice transcription is already processing." };
  captureState.processing = true;
  refreshLiveVoiceDictationOverlay();
  const stopStartedAt = Date.now();
  debugLog(`Apple Speech stop requested pid=${captureState.helperPid ?? "unknown"} session=${captureState.sessionDirectory}`);
  playDictationFeedbackSound("stopListening", captureState.voiceOptions);
  scheduleProcessingFeedbackSound(captureState);
  try {
    fs.writeFileSync(path.join(captureState.sessionDirectory, "stop"), "1", "utf8");
    const finished = await waitForVoiceFile(captureState.sessionDirectory, ["final.json", "error.json"], 9000);
    if (!finished) {
      terminateVoiceHelperCapture(captureState, "Apple Speech finish timeout");
      return { ok: false, text: "", error: "Voice input did not finish in time." };
    }
    if (finished.name === "error.json") return { ok: false, text: "", error: finished.payload.message ?? "Voice input failed." };
    debugLog(`Apple Speech stop completed elapsedMs=${Date.now() - stopStartedAt} chars=${(finished.payload.text ?? "").length}`);
    return {
      ok: true,
      text: (finished.payload.text ?? "").trim()
    };
  } finally {
    terminateVoiceHelperCapture(captureState, "Apple Speech stop cleanup");
    if (voiceCapture === captureState) voiceCapture = null;
    stopVoiceLevelPolling();
    restoreLiveVoiceHUDAfterCaptureEnd();
    updateMenuBarVoiceStatus({ visible: false, status: "idle" });
    setTimeout(() => {
      if (voiceCapture) return;
      void cleanupStaleVoiceHelpers("after Apple Speech stop")
        .catch((error) => {
          debugLog(`post Apple Speech cleanup failed: ${error instanceof Error ? error.message : String(error)}`);
        });
    }, 500).unref?.();
  }
}

function prewarmCloudVoiceTranscription(configuration?: VoiceStartOptions) {
  const provider = configuration?.cloudTranscriptionProvider || "OpenAI";
  if (provider !== "ChatGPT / Codex Session") {
    // Open the provider TLS connection while the user is still recording.
    void openAssistBridge()
      .then((bridge) => bridge.prewarmCloudTranscriptionConnection())
      .catch((error) => {
        debugLog(`cloud transcription connection prewarm failed: ${error instanceof Error ? error.message : String(error)}`);
      });
    return;
  }
  void openAssistBridge()
    .then((bridge) => bridge.prewarmCodexTranscriptionAuthContext())
    .then(() => debugLog("cloud voice transcription auth prewarmed"))
    .catch((error) => {
      debugLog(`cloud voice transcription auth prewarm failed: ${error instanceof Error ? error.message : String(error)}`);
    });
}

async function startCloudVoiceInput(configuration?: VoiceStartOptions) {
  if (process.platform !== "darwin") {
    return { ok: false, error: "Cloud voice capture is only available on macOS in this Electron port." };
  }
  await cleanupStaleVoiceHelpers("before cloud voice start", voiceCapture?.helperPid);
  cleanupOldVoiceCaptureDirectories();
  clearMismatchedVoiceCapture("cloudProviders");
  if (voiceCapture) {
    return { ok: true };
  }

  if (configuration?.transcriptionEngine !== "Cloud Providers") {
    return { ok: false, error: "Cloud voice input is not the selected transcription engine." };
  }
  const provider = configuration.cloudTranscriptionProvider || "OpenAI";
  if (provider !== "ChatGPT / Codex Session" && configuration.cloudTranscriptionAPIKeyConfigured === false) {
    return { ok: false, error: `${provider} transcription needs an API key in Settings > Voice & Dictation.` };
  }

  prewarmCloudVoiceTranscription(configuration);
  const helperAppPath = await ensureAppleSpeechHelper();
  const sessionDirectory = path.join(voiceCaptureRootDirectory(), `${Date.now()}-${Math.random().toString(16).slice(2)}`);
  fs.mkdirSync(sessionDirectory, { recursive: true });
  const helperProcess = launchVoiceHelperApp(helperAppPath, sessionDirectory, "recording", configuration);
  voiceCapture = {
    sessionDirectory,
    appPath: helperAppPath,
    engine: "cloudProviders",
    helperProcess,
    helperPid: helperProcess.pid,
    startedAt: Date.now(),
    voiceOptions: configuration
  };
  ensureVoiceCaptureHUDKeepAlive();
  showActiveVoiceCaptureHUD();
  const ready = await waitForVoiceFile(sessionDirectory, ["ready.json", "error.json"], 12000);
  if (!ready) {
    requestVoiceHelperStop(sessionDirectory);
    terminateVoiceHelperCapture(voiceCapture, "cloud voice startup timeout");
    voiceCapture = null;
    return { ok: false, error: voiceStartupTimeoutMessage(sessionDirectory, "Voice recording did not become ready in time.") };
  }
  if (ready.name === "error.json") {
    voiceCapture = null;
    return { ok: false, error: ready.payload.message ?? "Voice recording failed." };
  }
  startVoiceLevelPolling(sessionDirectory);
  showActiveVoiceCaptureHUD();
  playDictationFeedbackSound("startListening", configuration);
  return { ok: true };
}

async function stopCloudVoiceInput() {
  const captureState = voiceCapture;
  if (!captureState) return { ok: false, text: "", error: "Voice input is not running." };
  if (captureState.engine !== "cloudProviders") return { ok: false, text: "", error: "Cloud voice input is not running." };
  if (captureState.processing) return { ok: false, text: "", error: "Voice transcription is already processing." };
  captureState.processing = true;
  refreshLiveVoiceDictationOverlay();
  const stopStartedAt = Date.now();
  debugLog(`cloud voice stop requested provider=${captureState.voiceOptions?.cloudTranscriptionProvider ?? "unknown"} pid=${captureState.helperPid ?? "unknown"} session=${captureState.sessionDirectory}`);
  playDictationFeedbackSound("stopListening", captureState.voiceOptions);
  scheduleProcessingFeedbackSound(captureState);
  try {
    fs.writeFileSync(path.join(captureState.sessionDirectory, "stop"), "1", "utf8");
    const finished = await waitForVoiceFile(captureState.sessionDirectory, ["final.json", "error.json"], 15000);
    if (!finished) {
      terminateVoiceHelperCapture(captureState, "cloud voice recording finish timeout");
      return { ok: false, text: "", error: "Voice recording did not finish in time." };
    }
    if (finished.name === "error.json") return { ok: false, text: "", error: finished.payload.message ?? "Voice recording failed." };
    const audioPath = finished.payload.audioPath;
    if (!audioPath || !fs.existsSync(audioPath)) {
      return { ok: false, text: "", error: "Voice recording did not produce an audio file." };
    }
    const text = await (await openAssistBridge()).transcribeAudioFile({
      filePath: audioPath,
      fileName: finished.payload.fileName || path.basename(audioPath),
      mimeType: finished.payload.mimeType || "audio/wav"
    });
    debugLog(`cloud voice stop completed elapsedMs=${Date.now() - stopStartedAt} chars=${text.length}`);
    return { ok: true, text: text.trim() };
  } catch (error) {
    return {
      ok: false,
      text: "",
      error: error instanceof Error ? error.message : "Cloud transcription failed."
    };
  } finally {
    terminateVoiceHelperCapture(captureState, "cloud voice stop cleanup");
    if (voiceCapture === captureState) voiceCapture = null;
    stopVoiceLevelPolling();
    restoreLiveVoiceHUDAfterCaptureEnd();
    updateMenuBarVoiceStatus({ visible: false, status: "idle" });
  }
}

function parseWhisperHelperPayload(stdout: string) {
  const lines = stdout.trim().split(/\r?\n/).filter(Boolean).reverse();
  for (const line of lines) {
    try {
      const payload = JSON.parse(line) as { ok?: boolean; text?: string; error?: string };
      if (typeof payload.ok === "boolean") return payload;
    } catch {
      // whisper.cpp can write diagnostic lines; keep looking for the final JSON payload.
    }
  }
  return null;
}

async function transcribeWithLocalWhisper(audioPath: string, modelPath: string, useCoreML: boolean) {
  const helperPath = await ensureWhisperHelper();
  try {
    const { stdout } = await runProcessWithOutput(helperPath, [
      "--audio",
      audioPath,
      "--model",
      modelPath,
      "--language",
      "en",
      "--coreml",
      useCoreML ? "true" : "false"
    ], 180000);
    const payload = parseWhisperHelperPayload(stdout);
    if (payload?.ok) return (payload.text ?? "").trim();
    throw new Error(payload?.error || "whisper.cpp transcription failed.");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const payload = parseWhisperHelperPayload(message);
    throw new Error(payload?.error || message || "whisper.cpp transcription failed.");
  }
}

function localVoiceCaptureDirectory() {
  return path.join(app.getPath("userData"), "local-voice-agent");
}

function audioBufferFromBase64(rawValue: string) {
  const trimmed = rawValue.trim();
  const base64 = trimmed.includes(",") ? trimmed.slice(trimmed.indexOf(",") + 1) : trimmed;
  return Buffer.from(base64, "base64");
}

function writeLocalVoiceAudioFile(request?: LocalVoiceTranscriptionRequest) {
  const buffer = audioBufferFromBase64(request?.audioBase64 ?? "");
  if (!buffer.length) throw new Error("Local Voice Agent did not capture audio.");
  const directory = localVoiceCaptureDirectory();
  fs.mkdirSync(directory, { recursive: true });
  const requestedName = request?.fileName?.trim() || "local-voice.wav";
  const extension = path.extname(requestedName).replace(/[^a-zA-Z0-9.]/g, "") || ".wav";
  const audioPath = path.join(directory, `utterance-${Date.now()}-${Math.random().toString(16).slice(2)}${extension}`);
  fs.writeFileSync(audioPath, buffer);
  return {
    audioPath,
    fileName: requestedName,
    mimeType: request?.mimeType || "audio/wav",
    byteLength: buffer.length
  };
}

async function transcribeLocalVoiceAudio(request?: LocalVoiceTranscriptionRequest) {
  const engine = request?.transcriptionEngine || "whisper.cpp";
  let audioPath = "";
  const startedAt = Date.now();
  try {
    const written = writeLocalVoiceAudioFile(request);
    audioPath = written.audioPath;
    debugLog(
      `local voice stt started engine=${engine} provider=${request?.cloudTranscriptionProvider || ""} bytes=${written.byteLength}`
    );
    if (engine === "Cloud Providers") {
      const provider = request?.cloudTranscriptionProvider || "OpenAI";
      if (provider !== "ChatGPT / Codex Session" && request?.cloudTranscriptionAPIKeyConfigured === false) {
        return { ok: false, text: "", error: `${provider} transcription needs an API key in Settings > Voice & Dictation.` };
      }
      const text = await (await openAssistBridge()).transcribeAudioFile({
        filePath: written.audioPath,
        fileName: written.fileName,
        mimeType: written.mimeType
      });
      debugLog(`local voice stt completed engine=${engine} provider=${provider} chars=${text.trim().length} elapsedMs=${Date.now() - startedAt}`);
      return { ok: true, text: text.trim(), engine };
    }
    if (engine !== "whisper.cpp") {
      return {
        ok: false,
        text: "",
        error: "Local Voice Agent needs whisper.cpp or Cloud Providers. Apple Speech is only for normal dictation."
      };
    }
    const resolvedModel = resolveInstalledWhisperModel(request?.whisperModel || "base.en");
    if (!resolvedModel) {
      return {
        ok: false,
        text: "",
        error: "whisper.cpp model is not installed. Open Settings > Voice & Dictation and install a Whisper model first."
      };
    }
    const modelID = resolvedModel.modelID;
    const shouldForceCPUForStability = modelID.startsWith("small") || modelID.startsWith("medium");
    const useCoreML = Boolean(request?.whisperUseCoreML)
      && fs.existsSync(whisperCoreMLDirectoryPath(modelID))
      && !shouldForceCPUForStability;
    const text = await transcribeWithLocalWhisper(written.audioPath, resolvedModel.modelPath, useCoreML);
    debugLog(`local voice stt completed engine=${engine} model=${modelID} coreML=${String(useCoreML)} chars=${text.trim().length} elapsedMs=${Date.now() - startedAt}`);
    return { ok: true, text: text.trim(), engine, modelID, useCoreML };
  } catch (error) {
    debugLog(`local voice stt failed engine=${engine} elapsedMs=${Date.now() - startedAt}: ${error instanceof Error ? error.message : String(error)}`);
    return {
      ok: false,
      text: "",
      error: error instanceof Error ? error.message : "Local voice transcription failed."
    };
  } finally {
    if (audioPath) {
      fs.promises.rm(audioPath, { force: true }).catch(() => undefined);
    }
  }
}

async function startWhisperVoiceInput(configuration?: VoiceStartOptions) {
  if (process.platform !== "darwin") {
    return { ok: false, error: "whisper.cpp voice input is only available on macOS in this Electron port." };
  }
  await cleanupStaleVoiceHelpers("before whisper voice start", voiceCapture?.helperPid);
  cleanupOldVoiceCaptureDirectories();
  clearMismatchedVoiceCapture("whisperCpp");
  if (voiceCapture) {
    return { ok: true };
  }

  if (configuration?.transcriptionEngine !== "whisper.cpp") {
    return { ok: false, error: "whisper.cpp voice input is not the selected transcription engine." };
  }

  const resolvedModel = resolveInstalledWhisperModel(configuration.whisperModel || "base.en");
  if (!resolvedModel) {
    return {
      ok: false,
      error: "whisper.cpp model is not installed. Open native OpenAssist Settings > Voice & Dictation and download a Whisper model first."
    };
  }

  const helperAppPath = await ensureAppleSpeechHelper();
  const sessionDirectory = path.join(voiceCaptureRootDirectory(), `${Date.now()}-${Math.random().toString(16).slice(2)}`);
  const modelID = resolvedModel.modelID;
  const coreMLDirectoryPath = whisperCoreMLDirectoryPath(modelID);
  const shouldForceCPUForStability = modelID.startsWith("small") || modelID.startsWith("medium");
  const useCoreML = Boolean(configuration.whisperUseCoreML)
    && fs.existsSync(coreMLDirectoryPath)
    && !shouldForceCPUForStability;
  fs.mkdirSync(sessionDirectory, { recursive: true });
  const helperProcess = launchVoiceHelperApp(helperAppPath, sessionDirectory, "recording", configuration);
  voiceCapture = {
    sessionDirectory,
    appPath: helperAppPath,
    engine: "whisperCpp",
    helperProcess,
    helperPid: helperProcess.pid,
    startedAt: Date.now(),
    voiceOptions: configuration,
    whisperModelID: modelID,
    whisperModelPath: resolvedModel.modelPath,
    whisperUseCoreML: useCoreML
  };
  ensureVoiceCaptureHUDKeepAlive();
  showActiveVoiceCaptureHUD();
  const ready = await waitForVoiceFile(sessionDirectory, ["ready.json", "error.json"], 12000);
  if (!ready) {
    requestVoiceHelperStop(sessionDirectory);
    terminateVoiceHelperCapture(voiceCapture, "whisper voice startup timeout");
    voiceCapture = null;
    return { ok: false, error: voiceStartupTimeoutMessage(sessionDirectory, "whisper.cpp voice recording did not become ready in time.") };
  }
  if (ready.name === "error.json") {
    voiceCapture = null;
    return { ok: false, error: ready.payload.message ?? "whisper.cpp voice recording failed." };
  }
  startVoiceLevelPolling(sessionDirectory);
  showActiveVoiceCaptureHUD();
  playDictationFeedbackSound("startListening", configuration);
  return { ok: true, modelID, useCoreML };
}

async function stopWhisperVoiceInput() {
  const captureState = voiceCapture;
  if (!captureState) return { ok: false, text: "", error: "Voice input is not running." };
  if (captureState.engine !== "whisperCpp") return { ok: false, text: "", error: "whisper.cpp voice input is not running." };
  if (captureState.processing) return { ok: false, text: "", error: "Voice transcription is already processing." };
  captureState.processing = true;
  refreshLiveVoiceDictationOverlay();
  const stopStartedAt = Date.now();
  debugLog(`whisper voice stop requested model=${captureState.whisperModelID ?? "unknown"} pid=${captureState.helperPid ?? "unknown"} session=${captureState.sessionDirectory}`);
  playDictationFeedbackSound("stopListening", captureState.voiceOptions);
  scheduleProcessingFeedbackSound(captureState);
  try {
    fs.writeFileSync(path.join(captureState.sessionDirectory, "stop"), "1", "utf8");
    const finished = await waitForVoiceFile(captureState.sessionDirectory, ["final.json", "error.json"], 15000);
    if (!finished) {
      terminateVoiceHelperCapture(captureState, "whisper voice recording finish timeout");
      return { ok: false, text: "", error: "whisper.cpp voice recording did not finish in time." };
    }
    if (finished.name === "error.json") return { ok: false, text: "", error: finished.payload.message ?? "whisper.cpp voice recording failed." };
    const audioPath = finished.payload.audioPath;
    if (!audioPath || !fs.existsSync(audioPath)) {
      return { ok: false, text: "", error: "whisper.cpp voice recording did not produce an audio file." };
    }
    const modelPath = captureState.whisperModelPath;
    if (!modelPath || !fs.existsSync(modelPath)) {
      return { ok: false, text: "", error: "Selected whisper.cpp model is not installed." };
    }
    const text = await transcribeWithLocalWhisper(audioPath, modelPath, captureState.whisperUseCoreML === true);
    debugLog(`whisper voice stop completed elapsedMs=${Date.now() - stopStartedAt} chars=${text.length}`);
    return { ok: true, text };
  } catch (error) {
    return {
      ok: false,
      text: "",
      error: error instanceof Error ? error.message : "whisper.cpp transcription failed."
    };
  } finally {
    terminateVoiceHelperCapture(captureState, "whisper voice stop cleanup");
    if (voiceCapture === captureState) voiceCapture = null;
    stopVoiceLevelPolling();
    restoreLiveVoiceHUDAfterCaptureEnd();
    updateMenuBarVoiceStatus({ visible: false, status: "idle" });
  }
}

async function startConfiguredVoiceInput(options?: VoiceStartOptions) {
  if (liveVoiceHUDSessionActive() && !liveVoiceHUDMuted()) {
    return {
      ok: false,
      error: "Stop Live Voice or mute its microphone before starting dictation."
    };
  }
  void refreshFrontmostApplicationSnapshot();
  const configuration = options?.transcriptionEngine
    ? options
    : await (await openAssistBridge()).voiceInputConfiguration();
  if (configuration.transcriptionEngine === "Apple Speech") return startAppleVoiceInput(configuration);
  if (configuration.transcriptionEngine === "Cloud Providers") return startCloudVoiceInput(configuration);
  if (configuration.transcriptionEngine === "whisper.cpp") return startWhisperVoiceInput(configuration);
  return { ok: false, error: `Unsupported transcription engine: ${configuration.transcriptionEngine}` };
}

async function stopConfiguredVoiceInput() {
  // Overlap slow side-work with transcription instead of paying for it later:
  // - capture the frontmost app NOW (it is the paste target) so the insert
  //   step doesn't need its own ~100-400ms osascript round-trip;
  // - open the TLS connection to the cloud transcription provider so the
  //   upload that follows reuses it instead of doing a cold handshake.
  void refreshFrontmostApplicationSnapshot();
  if (voiceCapture?.engine === "cloudProviders") {
    void openAssistBridge()
      .then((bridge) => bridge.prewarmCloudTranscriptionConnection())
      .catch((error) => {
        debugLog(`cloud transcription connection prewarm failed: ${error instanceof Error ? error.message : String(error)}`);
      });
  }
  if (voiceCapture?.engine === "whisperCpp") return stopWhisperVoiceInput();
  if (voiceCapture?.engine === "cloudProviders") return stopCloudVoiceInput();
  return stopAppleVoiceInput();
}

function openAssistTargetPath(target: string) {
  const home = app.getPath("home");
  const supportRoot = path.join(home, "Library/Application Support/OpenAssist");
  const logRoot = path.join(home, "Library/Logs/OpenAssist");
  const repoRoot = openAssistRepoRoot();
  switch (target) {
    case "repo":
      return repoRoot;
    case "support":
      return supportRoot;
    case "logs":
      return logRoot;
    case "helperLogs":
      return fs.existsSync(logRoot) ? logRoot : supportRoot;
    case "insertionDiagnostics":
      return fs.existsSync("/tmp/openassist-insertion-diagnostics.log")
        ? "/tmp/openassist-insertion-diagnostics.log"
        : "/tmp";
    case "remoteAccess":
      return path.join(supportRoot, "RemoteAccess");
    case "voiceData":
      return path.join(supportRoot, "AssistantVoice");
    default:
      return null;
  }
}

app.whenReady().then(() => {
  debugLog("app ready");
  void cleanupStaleVoiceHelpers("app ready")
    .then(() => cleanupOldVoiceCaptureDirectories())
    .catch((error) => {
      debugLog(`startup voice cleanup failed: ${error instanceof Error ? error.message : String(error)}`);
    });
  // Kill Computer Use helpers orphaned by a previous crash so they don't pile up.
  void openAssistBridge()
    .then((bridge) => bridge.cleanupOrphanedComputerUseHelpersOnStartup())
    .then((result) => {
      if (result.killed.length) debugLog(`startup: cleaned ${result.killed.length} orphaned Computer Use helper(s)`);
    })
    .catch((error) => {
      debugLog(`startup Computer Use cleanup failed: ${error instanceof Error ? error.message : String(error)}`);
    });
  // Temporary threads left behind by a crash/force-quit must not come back as
  // saved chats.
  void openAssistBridge()
    .then((bridge) => bridge.purgeTemporaryThreadsOnStartup())
    .then((result) => {
      if (result.removed) debugLog(`startup: purged ${result.removed} leftover temporary thread(s)`);
    })
    .catch((error) => {
      debugLog(`startup temporary thread purge failed: ${error instanceof Error ? error.message : String(error)}`);
    });
  if (process.platform === "darwin") {
    ensureRegularDockPresence("app ready");
    try {
      const candidateIconPaths = [
        path.join(__dirname, "..", "icon.icns"),
        path.join(app.getAppPath(), "icon.icns"),
        path.join(app.getAppPath(), "..", "icon.icns"),
        path.join(process.cwd(), "icon.icns"),
        path.join(process.resourcesPath ?? "", "icon.icns")
      ];
      const iconPath = candidateIconPaths.find((candidate) => candidate && fs.existsSync(candidate));
      debugLog(`dock icon candidates considered=${candidateIconPaths.join("|")} resolved=${iconPath ?? "<none>"}`);
      if (app.dock) {
        if (iconPath) {
          const dockIcon = nativeImage.createFromPath(iconPath);
          debugLog(`dock icon image isEmpty=${dockIcon.isEmpty()} size=${JSON.stringify(dockIcon.getSize())}`);
          if (!dockIcon.isEmpty()) {
            app.dock.setIcon(dockIcon);
          }
        }
      }
    } catch (error) {
      debugLog(`dock icon setup failed: ${error instanceof Error ? error.message : String(error)}`);
    }
    ensureRegularDockPresence("after dock icon setup");
  }
  if (process.env.OPENASSIST_ELECTRON_AX_FEATURES) {
    const features = process.env.OPENASSIST_ELECTRON_AX_FEATURES.split(",")
      .map((feature) => feature.trim())
      .filter(Boolean);
    app.setAccessibilitySupportFeatures(features);
  } else if (shouldForceAccessibility) {
    app.setAccessibilitySupportEnabled(true);
  }
  app.setAboutPanelOptions({ applicationName: "Open Assist" });
  installApplicationMenu();
  void openAssistBridge()
    .then((bridge) => {
      bridge.setThreadsChangedListener(broadcastThreadsUpdated);
      bridge.setAppStateBackgroundUpdateListener(broadcastAppStateBackgroundUpdate);
      bridge.setConnectorSyncProgressListener((progress) => broadcastConnectorSyncProgress(progress));
      return bridge.prewarmAssistantVoiceOutput();
    })
    .catch((error) => {
      debugLog(`assistant voice prewarm failed: ${error instanceof Error ? error.message : String(error)}`);
    });
  // Restore Remote Access (local server + public Easy QR link) if the user left
  // it on, so they don't have to re-enable it after every launch.
  void openAssistBridge()
    .then((bridge) => bridge.restoreRemoteAccessOnStartup())
    .catch((error) => {
      debugLog(`Remote Access startup restore failed: ${error instanceof Error ? error.message : String(error)}`);
    });
  session.defaultSession.setPermissionRequestHandler((_webContents, permission, callback, details) => {
    const requestDetails = details as { mediaTypes?: string[] };
    const mediaTypes = Array.isArray(requestDetails.mediaTypes) ? requestDetails.mediaTypes : [];
    callback(permission === "media" && mediaTypes.includes("audio"));
  });

  ipcMain.handle("open-external", async (_event, url: string) => {
    if (typeof url === "string" && /^(https?:\/\/|mailto:|tel:|x-apple\.systempreferences:)/i.test(url)) {
      await shell.openExternal(url);
    }
  });

  // Dev-only perf snapshot. Gated on the same env var that opens CDP so it
  // cannot be hit from a packaged production build.
  ipcMain.handle("openassist:__perf-snapshot", async () => {
    if (!enableElectronDebugging) return { error: "disabled" } as const;
    let v8Stats: unknown = null;
    try {
      const v8 = await import("node:v8");
      v8Stats = v8.getHeapStatistics();
    } catch {
      v8Stats = null;
    }
    let processMemoryInfo: unknown = null;
    try {
      processMemoryInfo = await process.getProcessMemoryInfo();
    } catch {
      processMemoryInfo = null;
    }
    return {
      capturedAt: Date.now(),
      appMetrics: app.getAppMetrics(),
      processMemoryInfo,
      v8: v8Stats,
      resourceUsage: process.resourceUsage(),
      mainPid: process.pid,
      uptimeSeconds: process.uptime()
    };
  });

  ipcMain.handle("openassist:get-macos-permissions", async () => {
    if (process.platform !== "darwin") {
      return {
        platformSupported: false,
        accessibility: "unknown" as const,
        screenRecording: "unknown" as const,
        microphone: "unknown" as const
      };
    }
    const accessibilityTrusted = systemPreferences.isTrustedAccessibilityClient(false);
    let screenRecording: "granted" | "denied" | "not-determined" | "unknown" = "unknown";
    try {
      const status = systemPreferences.getMediaAccessStatus("screen");
      screenRecording = status === "granted"
        ? "granted"
        : status === "denied" || status === "restricted"
          ? "denied"
          : "not-determined";
    } catch {
      screenRecording = "unknown";
    }
    let microphone: "granted" | "denied" | "not-determined" | "unknown" = "unknown";
    try {
      const status = systemPreferences.getMediaAccessStatus("microphone");
      microphone = status === "granted"
        ? "granted"
        : status === "denied" || status === "restricted"
          ? "denied"
          : "not-determined";
    } catch {
      microphone = "unknown";
    }
    return {
      platformSupported: true,
      accessibility: accessibilityTrusted ? "granted" : "denied",
      screenRecording,
      microphone
    };
  });

  ipcMain.handle("openassist:request-macos-permission", async (_event, kind: string) => {
    if (process.platform !== "darwin") return { ok: false, opened: false };
    switch (kind) {
      case "accessibility": {
        // Triggers the system prompt the first time; on later calls macOS just
        // remembers the previous answer, so we also open the pane below so the
        // user can flip it back on if they denied it earlier.
        systemPreferences.isTrustedAccessibilityClient(true);
        await shell.openExternal(
          "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        );
        return { ok: true, opened: true };
      }
      case "screenRecording": {
        try {
          // Asking for "screen" via getMediaAccessStatus does not prompt, but a
          // CGRequestScreenCaptureAccess-style call does. Electron exposes that
          // indirectly by accessing the desktop capturer; the most reliable
          // cross-version path is to just open the System Settings pane.
          await shell.openExternal(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
          );
        } catch {
          // Ignore — opening the pane is best-effort.
        }
        return { ok: true, opened: true };
      }
      case "microphone": {
        try {
          await systemPreferences.askForMediaAccess("microphone");
        } catch {
          // Some macOS versions throw if Info.plist usage strings are missing;
          // fall back to opening the pane.
        }
        await shell.openExternal(
          "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        );
        return { ok: true, opened: true };
      }
      case "speechRecognition": {
        await shell.openExternal(
          "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        );
        return { ok: true, opened: true };
      }
      case "automation": {
        await shell.openExternal(
          "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        );
        return { ok: true, opened: true };
      }
      case "fullDiskAccess": {
        await shell.openExternal(
          "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        );
        return { ok: true, opened: true };
      }
      default:
        return { ok: false, opened: false, error: `Unknown permission kind: ${kind}` };
    }
  });

  ipcMain.handle("openassist:get-computer-use-activity", async () => {
    try {
      return await (await openAssistBridge()).getComputerUseActivity();
    } catch (error) {
      return { active: false, activeToolCalls: 0, helpers: [], error: error instanceof Error ? error.message : String(error) };
    }
  });
  ipcMain.handle("openassist:force-stop-computer-use", async () => {
    try {
      return await (await openAssistBridge()).forceStopComputerUse();
    } catch (error) {
      return { stopped: false, killed: [], restarted: false, error: error instanceof Error ? error.message : String(error) };
    }
  });

  ipcMain.handle("openassist:workspace-launch-targets", async () => workspaceLaunchTargetSnapshots());
  ipcMain.handle("openassist:read-clipboard-text", async () => clipboard.readText());
  ipcMain.handle("openassist:write-clipboard-text", async (_event, text: string) => {
    clipboard.writeText(String(text ?? ""));
    return { ok: true };
  });
  // Copy a chat image (generated artifact, attachment, inline image) to the
  // system clipboard as an actual image. Prefers the file on disk (full
  // resolution) over the preview data URL.
  ipcMain.handle("openassist:copy-image-to-clipboard", async (_event, source: { dataURL?: string; filePath?: string }) => {
    try {
      const fromPath = source?.filePath && fs.existsSync(source.filePath)
        ? nativeImage.createFromPath(source.filePath)
        : null;
      const image = fromPath && !fromPath.isEmpty()
        ? fromPath
        : nativeImage.createFromDataURL(String(source?.dataURL ?? ""));
      if (!image || image.isEmpty()) return { ok: false, error: "Image could not be read." };
      clipboard.writeImage(image);
      return { ok: true };
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  });
  ipcMain.handle("openassist:get-spellcheck-context", async (event) => {
    const payload = spellcheckContextByWebContentsID.get(event.sender.id);
    if (!payload || Date.now() - payload.createdAt > 4000) return null;
    return payload;
  });
  ipcMain.handle("openassist:replace-misspelling", async (event, text: string) => {
    const replacement = String(text ?? "").trim();
    if (!replacement) return { ok: false, error: "No spelling suggestion selected." };
    try {
      event.sender.replaceMisspelling(replacement);
      spellcheckContextByWebContentsID.delete(event.sender.id);
      return { ok: true };
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  });
  ipcMain.handle("openassist:insert-transcript-text", async (_event, text: string) => insertTranscriptText(text));
  ipcMain.handle("openassist:notify-thread-complete", (_event, payload: { threadID?: string; title?: string; body?: string }) => {
    return showThreadCompletionNotification(payload ?? {});
  });
  ipcMain.handle("openassist:add-transcript-history", async (_event, text: string) => addTranscriptHistory(text));
  ipcMain.handle("openassist:load-transcript-history", async () => readTranscriptHistory());
  ipcMain.handle("openassist:delete-transcript-history-entry", async (_event, id: string) => deleteTranscriptHistoryEntry(id));
  ipcMain.handle("openassist:clear-transcript-history", async () => clearTranscriptHistory());
  ipcMain.handle("openassist:paste-transcript-history-entry", async (_event, id?: string) => pasteTranscriptHistoryEntry(id));
  ipcMain.handle("openassist:paste-last-transcript-shortcut", async () => pasteLastTranscriptFromShortcut());
  ipcMain.handle("openassist:play-dictation-feedback-sound", async (_event, cue: DictationFeedbackCue) => {
    if (!["startListening", "stopListening", "processing", "pasted", "correctionLearned"].includes(String(cue))) {
      return { ok: false, error: "Unknown dictation sound." };
    }
    return playDictationFeedbackSound(cue);
  });
  ipcMain.handle("openassist:open-transcript-history-window", async () => showTranscriptHistoryWindow());
  ipcMain.handle("openassist:open-settings-window", async (_event, section?: string) => showSettingsWindow(section));
  ipcMain.handle("openassist:menu-bar-action", async (_event, action: MenuBarAction) => handleMenuBarAction(action));
  // Live app status pushed by the renderer (running chats, unread replies) so
  // the menu bar popover shows current information instead of a stale snapshot.
  ipcMain.on("openassist:menu-bar-state", (_event, snapshot: unknown) => {
    const raw = (snapshot ?? {}) as Partial<MenuBarAppStateSnapshot>;
    const cleanLine = (value: unknown, max: number) => String(value ?? "").replace(/\s+/g, " ").trim().slice(0, max);
    const runs = Array.isArray(raw.runs)
      ? raw.runs.slice(0, 6).map((run) => ({
          title: cleanLine(run?.title, 80) || "Untitled chat",
          provider: cleanLine(run?.provider, 40),
          statusText: cleanLine(run?.statusText, 120),
          startedAt: Number(run?.startedAt) || Date.now()
        }))
      : [];
    menuBarAppState = {
      runs,
      unreadCount: Math.max(0, Math.min(99, Math.round(Number(raw.unreadCount) || 0))),
      threadCount: Math.max(0, Math.round(Number(raw.threadCount) || 0)),
      updatedAt: Date.now()
    };
    refreshMenuBarPopoverIfVisible();
  });
  ipcMain.on("openassist:menu-bar-report-height", (event, height: unknown) => {
    const window = menuBarPopoverWindow;
    if (!window || window.isDestroyed() || event.sender !== window.webContents) return;
    const next = Math.max(240, Math.min(760, Math.round(Number(height) || 0)));
    if (!next || Math.abs(next - menuBarPopoverContentHeight) < 2) return;
    menuBarPopoverContentHeight = next;
    if (window.isVisible()) positionMenuBarPopoverWindow(window);
  });
  ipcMain.handle("openassist:open-target", async (_event, target: string, workspaceRootPath?: string | null) => {
    if (target.startsWith("workspace:")) {
      return openWorkspaceLaunchTarget(target.slice("workspace:".length), workspaceRootPath);
    }
    if (target.startsWith("file:")) {
      return openFileLaunchTarget(target.slice("file:".length), workspaceRootPath);
    }
    if (target === "repoInVSCode") {
      return openWorkspaceLaunchTarget("vscode", workspaceRootPath);
    }
    const targetPath = openAssistTargetPath(target);
    if (!targetPath) return { ok: false, error: "Unknown OpenAssist target." };
    if (!fs.existsSync(targetPath)) {
      if (path.extname(targetPath)) {
        fs.mkdirSync(path.dirname(targetPath), { recursive: true });
        fs.closeSync(fs.openSync(targetPath, "a"));
      } else {
        fs.mkdirSync(targetPath, { recursive: true });
      }
    }
    const error = await shell.openPath(targetPath);
    return error ? { ok: false, error } : { ok: true, path: targetPath };
  });
  ipcMain.handle("openassist:load-app-state", async () => (await openAssistBridge()).loadOpenAssistAppState());
  ipcMain.handle("openassist:load-settings-app-state", async () => (await openAssistBridge()).loadOpenAssistSettingsAppState());
  ipcMain.handle("openassist:connectors-load", async () => loadConnectorSnapshot());
  ipcMain.handle("openassist:connectors-load-review-inbox", async () => loadConnectorReviewInbox());
  ipcMain.handle("openassist:apple-eventkit-status", async () => appleEventKitStatus());
  ipcMain.handle("openassist:apple-eventkit-request-access", async (_event, service: string) =>
    requestAppleEventKitAccess(service === "calendar" ? "calendar" : "reminders")
  );
  ipcMain.handle("openassist:connectors-create-google-account", async (_event, label: string) =>
    createGoogleConnectorAccount(label)
  );
  ipcMain.handle("openassist:connectors-remove-google-account", async (_event, accountID: string) =>
    removeGoogleConnectorAccount(accountID)
  );
  ipcMain.handle("openassist:connectors-set-service-enabled", async (_event, accountID: string, serviceID: ConnectorServiceID, enabled: boolean) =>
    setConnectorServiceEnabled(accountID, serviceID, enabled)
  );
  ipcMain.handle("openassist:connectors-install-gws", async () => installPinnedGoogleCLI());
  ipcMain.handle("openassist:connectors-google-command-plan", async (_event, accountID: string, operation: GoogleConnectorOperation, approved?: boolean) =>
    buildGoogleCommandPlan(accountID, operation, approved === true)
  );
  ipcMain.handle("openassist:connectors-google-oauth-status", async (_event, accountID: string) =>
    googleOAuthSetupStatus(accountID)
  );
  ipcMain.handle("openassist:connectors-open-google-oauth-page", async (_event, accountID: string, page: string) => {
    const status = googleOAuthSetupStatus(accountID);
    const url = page === "credentials"
      ? status.credentialsURL
      : page === "apiLibrary"
        ? status.apiLibraryURL
        : status.consentURL;
    await shell.openExternal(url);
    return { ok: true, status };
  });
  ipcMain.handle("openassist:connectors-import-google-client-secret", async (event, accountID: string) => {
    const owner = BrowserWindow.fromWebContents(event.sender) ?? settingsWindow ?? mainWindow;
    const dialogOptions: Electron.OpenDialogOptions = {
      title: "Choose Google Desktop OAuth client JSON",
      properties: ["openFile"],
      filters: [
        { name: "Google OAuth Client JSON", extensions: ["json"] }
      ]
    };
    const result = owner
      ? await dialog.showOpenDialog(owner, dialogOptions)
      : await dialog.showOpenDialog(dialogOptions);
    if (result.canceled || !result.filePaths[0]) {
      return { ok: false, cancelled: true, status: googleOAuthSetupStatus(accountID) };
    }
    const status = importGoogleClientSecret(accountID, result.filePaths[0]);
    return { ok: true, status };
  });
  ipcMain.handle("openassist:connectors-reuse-google-client-secret", async (_event, accountID: string) => {
    const status = reuseGoogleClientSecret(accountID);
    return { ok: true, status };
  });
  ipcMain.handle("openassist:connectors-open-google-config-folder", async (_event, accountID: string) => {
    const status = googleOAuthSetupStatus(accountID);
    fs.mkdirSync(status.configPath, { recursive: true });
    const error = await shell.openPath(status.configPath);
    return { ok: !error, error, status };
  });
  const runGoogleConnectorTerminalCommand = (
    event: { sender: WebContents },
    accountID: string,
    operation: GoogleConnectorOperation
  ) => {
    const sessionID = `gws-${operation.kind}-${randomUUID()}`;
    const commandLabel = operation.kind === "authSetup" ? "setup" : "login";
    const plan = buildGoogleCommandPlan(accountID, operation);
    const env = { ...process.env, ...plan.environment };
    const child = spawn(plan.executablePath, plan.arguments, {
      env,
      stdio: ["pipe", "pipe", "pipe"]
    });
    connectorTerminalSessions.set(sessionID, child);
    const sendProgress = (payload: Record<string, unknown>) => {
      safeSendWebContents(event.sender, "openassist:connector-login-progress", {
        sessionID,
        accountID,
        ...payload
      });
    };
    const openURLs = new Set<string>();
    const shouldAutoOpenURL = (url: string) => {
      if (operation.kind !== "authLogin") return false;
      try {
        const parsed = new URL(url);
        return parsed.hostname === "accounts.google.com" || parsed.hostname.endsWith(".googleusercontent.com");
      } catch {
        return false;
      }
    };
    const handleOutput = (stream: "stdout" | "stderr", chunk: Buffer) => {
      const text = chunk.toString("utf8");
      sendProgress({ type: stream, text });
      const urls = text.match(/https?:\/\/[^\s"'<>]+/g) ?? [];
      for (const rawURL of urls) {
        const url = rawURL.replace(/[),.]+$/g, "");
        if (!shouldAutoOpenURL(url)) continue;
        if (openURLs.has(url)) continue;
        openURLs.add(url);
        shell.openExternal(url).catch((error) => {
          sendProgress({
            type: "stderr",
            text: `Could not open URL: ${error instanceof Error ? error.message : String(error)}\n`
          });
        });
      }
    };
    child.stdout?.on("data", (chunk) => handleOutput("stdout", chunk));
    child.stderr?.on("data", (chunk) => handleOutput("stderr", chunk));
    child.on("error", (error) => {
      connectorTerminalSessions.delete(sessionID);
      sendProgress({
        type: "error",
        text: error instanceof Error ? error.message : String(error)
      });
    });
    child.on("close", (code, signal) => {
      connectorTerminalSessions.delete(sessionID);
      sendProgress({
        type: "close",
        code,
        signal,
        text: code === 0
          ? `Google ${commandLabel} completed.\n`
          : `Google ${commandLabel} exited with code ${code ?? "unknown"}.\n`
      });
    });
    sendProgress({
      type: "start",
      text: operation.kind === "authSetup"
        ? `Running ${plan.displayCommand}\nSetup may print Google Cloud links. OpenAssist will show them here, not open them automatically.\n`
        : `Running ${plan.displayCommand}\n`
    });
    return { ok: true, sessionID };
  };
  ipcMain.handle("openassist:connectors-run-google-setup", async (event, accountID: string) =>
    runGoogleConnectorTerminalCommand(event, accountID, { kind: "authSetup" })
  );
  ipcMain.handle("openassist:connectors-run-google-login", async (event, accountID: string) =>
    runGoogleConnectorTerminalCommand(event, accountID, {
      kind: "authLogin",
      scopes: ["gmail", "calendar", "tasks", "drive", "people"]
    })
  );
  ipcMain.handle("openassist:connectors-send-terminal-input", async (_event, sessionID: string, input: string) => {
    const child = connectorTerminalSessions.get(sessionID);
    if (!child || child.exitCode !== null || child.killed) {
      throw new Error("Connector terminal session is not running.");
    }
    const text = String(input ?? "");
    if (!text) return { ok: true };
    child.stdin?.write(text.endsWith("\n") ? text : `${text}\n`);
    return { ok: true };
  });
  ipcMain.handle("openassist:connectors-stop-terminal", async (_event, sessionID: string) => {
    const child = connectorTerminalSessions.get(sessionID);
    if (!child || child.exitCode !== null || child.killed) return { ok: true, stopped: false };
    child.kill("SIGTERM");
    connectorTerminalSessions.delete(sessionID);
    return { ok: true, stopped: true };
  });
  const gmailSyncProgressMessage = (accountLabel: string, importedCount: number, reviewCount: number) => {
    if (importedCount > 0) {
      return `Gmail sync complete for ${accountLabel}. Found ${importedCount} actionable ${importedCount === 1 ? "candidate" : "candidates"}. ${reviewCount} ${reviewCount === 1 ? "item is" : "items are"} waiting in Review Inbox.`;
    }
    return `Gmail sync complete for ${accountLabel}. No new actionable email candidates found.`;
  };
  const connectorItemTitles = (items: ConnectorItem[] | undefined) => (items ?? [])
    .slice(0, 3)
    .map((item) => item.title.trim())
    .filter(Boolean);
  ipcMain.handle("openassist:connectors-sync-gmail", async (event, accountID: string, options?: GmailSyncOptions) => {
    const account = loadConnectorSnapshot().accounts.find((candidate) => candidate.id === accountID && candidate.provider === "google");
    const accountLabel = account?.label || "Gmail";
    const progressID = `gmail-sync-${randomUUID()}`;
    const startedAt = new Date().toISOString();
    broadcastConnectorSyncProgress({
      id: progressID,
      provider: "google",
      serviceID: "gmail",
      accountID,
      accountLabel,
      status: "running",
      message: `Syncing Gmail for ${accountLabel}...`,
      startedAt
    }, event.sender);
    try {
      const result = await syncGmailMetadataToReviewInbox(accountID, options ?? {});
      const reviewCount = result.reviewItems.length;
      broadcastConnectorSyncProgress({
        id: progressID,
        provider: "google",
        serviceID: "gmail",
        accountID,
        accountLabel,
        status: "completed",
        message: gmailSyncProgressMessage(accountLabel, result.importedCount, reviewCount),
        importedCount: result.importedCount,
        reviewCount,
        itemTitles: connectorItemTitles(result.reviewItems),
        startedAt,
        finishedAt: new Date().toISOString()
      }, event.sender);
      return result;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      broadcastConnectorSyncProgress({
        id: progressID,
        provider: "google",
        serviceID: "gmail",
        accountID,
        accountLabel,
        status: "failed",
        message: `Gmail sync failed for ${accountLabel}: ${message}`,
        startedAt,
        finishedAt: new Date().toISOString(),
        error: message
      }, event.sender);
      throw error;
    }
  });
  ipcMain.handle("openassist:connectors-mark-item", async (_event, itemID: string, status: ConnectorItemStatus) =>
    markConnectorItem(itemID, status)
  );
  ipcMain.handle("openassist:connectors-ignore-review-items", async (_event, accountID?: string) =>
    ignoreConnectorReviewItems(accountID?.trim() || undefined)
  );
  ipcMain.handle("openassist:connectors-save-item-to-backlog", async (_event, itemID: string) => {
    const result = await (await openAssistBridge()).upsertBacklogItem(saveConnectorItemToBacklogInput(itemID) as any);
    markConnectorItem(itemID, "approved");
    return { ok: true, result, snapshot: loadConnectorSnapshot() };
  });
  ipcMain.handle("openassist:connectors-skill-guide", async () => connectorSkillGuide());
  ipcMain.handle("openassist:integrations-status", async () => (await openAssistBridge()).loadOpenAssistIntegrationStatus());
  ipcMain.handle("openassist:integrations-connect", async (_event, targetID: string) =>
    (await openAssistBridge()).connectOpenAssistIntegration(targetID)
  );
  ipcMain.handle("openassist:integrations-copy-config", async (_event, targetID: string) => {
    const text = await (await openAssistBridge()).openAssistIntegrationConfigText(targetID);
    clipboard.writeText(text);
    return { ok: true };
  });
  ipcMain.handle("openassist:integrations-reveal-config", async (_event, targetID: string) => {
    const configPath = (await openAssistBridge()).openAssistIntegrationConfigPath(targetID);
    if (!configPath) return { ok: false, error: "This target does not have a config file path." };
    if (fs.existsSync(configPath)) {
      shell.showItemInFolder(configPath);
      return { ok: true, path: configPath };
    }
    fs.mkdirSync(path.dirname(configPath), { recursive: true });
    const error = await shell.openPath(path.dirname(configPath));
    return error ? { ok: false, error, path: configPath } : { ok: true, path: configPath };
  });
  ipcMain.handle("openassist:integrations-test", async () => (await openAssistBridge()).testOpenAssistKnowledgeIntegration());
  ipcMain.handle("openassist:integrations-skill", async (_event, targetID?: string) =>
    (await openAssistBridge()).openAssistIntegrationSkillGuide(targetID)
  );
  ipcMain.handle("openassist:integrations-copy-skill", async (_event, targetID?: string) => {
    const guide = (await openAssistBridge()).openAssistIntegrationSkillGuide(targetID);
    clipboard.writeText(guide.markdown);
    return { ok: true, skillPath: guide.skillPath };
  });
  ipcMain.handle("openassist:integrations-install-skill", async (_event, targetID: string) =>
    (await openAssistBridge()).installOpenAssistIntegrationSkill(targetID)
  );
  ipcMain.handle("openassist:integrations-reveal-skill", async (_event, targetID?: string) => {
    const guide = (await openAssistBridge()).openAssistIntegrationSkillGuide(targetID);
    if (!guide.skillPath) return { ok: false, error: "This skill has no file path." };
    if (fs.existsSync(guide.skillPath)) {
      shell.showItemInFolder(guide.skillPath);
      return { ok: true, path: guide.skillPath };
    }
    fs.mkdirSync(path.dirname(guide.skillPath), { recursive: true });
    const error = await shell.openPath(path.dirname(guide.skillPath));
    return error ? { ok: false, error, path: guide.skillPath } : { ok: true, path: guide.skillPath };
  });
  ipcMain.handle("openassist:list-provider-models", async (_event, backend: string) => (await openAssistBridge()).listProviderModels(backend));
  ipcMain.handle("openassist:list-ollama-catalog-models", async () => (await openAssistBridge()).listOllamaCatalogModels());
  ipcMain.handle("openassist:refresh-ollama-website-catalog", async () => (await openAssistBridge()).refreshOllamaWebsiteCatalog());
  ipcMain.handle("openassist:pull-ollama-model", async (event, modelID: string) => {
    const sender = event.sender;
    return (await openAssistBridge()).pullOllamaModel(modelID, (progress: unknown) => {
      if (!sender.isDestroyed()) sender.send("openassist:ollama-model-download-progress", progress);
    });
  });
  ipcMain.handle("openassist:delete-ollama-model", async (_event, modelID: string) => (await openAssistBridge()).deleteOllamaModel(modelID));
  ipcMain.handle("openassist:get-ollama-runtime-status", async () => (await openAssistBridge()).getOllamaRuntimeStatus());
  ipcMain.handle("openassist:start-ollama-runtime", async () => (await openAssistBridge()).startOllamaRuntime());
  ipcMain.handle("openassist:stop-ollama-runtime", async () => (await openAssistBridge()).stopOllamaRuntime());
  ipcMain.handle("openassist:open-ollama-download", async () => (await openAssistBridge()).openOllamaDownloadPage());
  ipcMain.handle("openassist:update-ollama-runtime", async (event) => {
    const sender = event.sender;
    return (await openAssistBridge()).updateOllamaRuntime((progress: unknown) => {
      if (!sender.isDestroyed()) sender.send("openassist:ollama-runtime-update-progress", progress);
    });
  });
  ipcMain.handle("openassist:load-thread", async (_event, threadID: string) => (await openAssistBridge()).loadThreadMessages(threadID));
  ipcMain.handle(
    "openassist:load-thread-messages-before",
    async (_event, threadID: string, beforeMessageID: string, turnLimit?: number) =>
      (await openAssistBridge()).loadThreadMessages(threadID, { beforeMessageID, turnLimit })
  );
  ipcMain.handle("openassist:load-code-tracking-state", async (_event, threadID: string) =>
    (await openAssistBridge()).loadCodeTrackingState(threadID)
  );
  ipcMain.handle("openassist:open-code-review", async (_event, threadID: string, checkpointID?: string) =>
    (await openAssistBridge()).openCodeReview(threadID, checkpointID)
  );
  ipcMain.handle("openassist:restore-code-checkpoint", async (_event, threadID: string, checkpointID: string) =>
    (await openAssistBridge()).restoreCodeCheckpoint(threadID, checkpointID)
  );
  ipcMain.handle("openassist:load-thread-note", async (_event, threadID: string) => (await openAssistBridge()).loadThreadNoteWorkspace(threadID));
  ipcMain.handle("openassist:create-thread-note", async (_event, threadID: string, title?: string) =>
    (await openAssistBridge()).createThreadNote(threadID, title)
  );
  ipcMain.handle("openassist:save-thread-note", async (_event, threadID: string, noteID: string | undefined, markdown: string) =>
    (await openAssistBridge()).saveThreadNote(threadID, noteID, markdown)
  );
  ipcMain.handle("openassist:rename-thread-note", async (_event, threadID: string, noteID: string, title: string) =>
    (await openAssistBridge()).renameThreadNote(threadID, noteID, title)
  );
  ipcMain.handle("openassist:select-thread-note", async (_event, threadID: string, noteID: string) =>
    (await openAssistBridge()).selectThreadNote(threadID, noteID)
  );
  ipcMain.handle("openassist:load-planner-day", async (_event, dayID?: string) =>
    (await openAssistBridge()).loadPlannerDay(dayID)
  );
  ipcMain.handle("openassist:load-planner-backlog", async () =>
    (await openAssistBridge()).loadPlannerBacklog()
  );
  ipcMain.handle("openassist:list-planner-days", async (_event, limit?: number, activeDayID?: string) =>
    (await openAssistBridge()).listPlannerDays(limit, activeDayID)
  );
  ipcMain.handle("openassist:list-planner-categories", async () =>
    (await openAssistBridge()).listPlannerCategories()
  );
  ipcMain.handle("openassist:list-planner-lists", async () =>
    (await openAssistBridge()).listPlannerLists()
  );
  ipcMain.handle("openassist:create-planner-list", async (_event, input: unknown) =>
    (await openAssistBridge()).createPlannerList(input as any)
  );
  ipcMain.handle("openassist:update-planner-list-color-and-area", async (_event, projectID: string, area?: string | null, color?: string | null) =>
    (await openAssistBridge()).updatePlannerListColorAndArea(projectID, area, color)
  );
  ipcMain.handle("openassist:hide-planner-list", async (_event, projectID: string) =>
    (await openAssistBridge()).hidePlannerList(projectID)
  );
  ipcMain.handle("openassist:list-planner-smart-lists", async () =>
    (await openAssistBridge()).listPlannerSmartLists()
  );
  ipcMain.handle("openassist:list-planner-smart-list-items", async (_event, smartListID: string) =>
    (await openAssistBridge()).listPlannerSmartListItems(smartListID)
  );
  ipcMain.handle("openassist:upsert-planner-category", async (_event, category: unknown) =>
    (await openAssistBridge()).upsertPlannerCategory(category as any)
  );
  ipcMain.handle("openassist:delete-planner-category", async (_event, categoryID: string) =>
    (await openAssistBridge()).deletePlannerCategory(categoryID)
  );
  ipcMain.handle("openassist:save-planner-day", async (_event, dayID: string | undefined, markdown: string) =>
    (await openAssistBridge()).savePlannerDay(dayID, markdown)
  );
  ipcMain.handle("openassist:schedule-selection-to-planner", async (_event, request: unknown) =>
    (await openAssistBridge()).scheduleSelectionToPlanner(request as any)
  );
  ipcMain.handle("openassist:list-daily-items", async (_event, dayID?: string) =>
    (await openAssistBridge()).listDailyItems(dayID)
  );
  ipcMain.handle("openassist:list-backlog-items", async () =>
    (await openAssistBridge()).listBacklogItems()
  );
  ipcMain.handle("openassist:upsert-daily-item", async (_event, item: unknown) =>
    (await openAssistBridge()).upsertDailyItem(item as any)
  );
  ipcMain.handle("openassist:toggle-daily-item", async (_event, dayID: string | undefined, itemID: string, checked: boolean) =>
    (await openAssistBridge()).toggleDailyItem(dayID, itemID, checked)
  );
  ipcMain.handle("openassist:delete-daily-item", async (_event, dayID: string | undefined, itemID: string) =>
    (await openAssistBridge()).deleteDailyItem(dayID, itemID)
  );
  ipcMain.handle("openassist:link-daily-item-note", async (_event, dayID: string | undefined, itemID: string, target: unknown) =>
    (await openAssistBridge()).linkDailyItemNote(dayID, itemID, target as any)
  );
  ipcMain.handle("openassist:upsert-backlog-item", async (_event, item: unknown) =>
    (await openAssistBridge()).upsertBacklogItem(item as any)
  );
  ipcMain.handle("openassist:toggle-backlog-item", async (_event, itemID: string, checked: boolean) =>
    (await openAssistBridge()).toggleBacklogItem(itemID, checked)
  );
  ipcMain.handle("openassist:delete-backlog-item", async (_event, itemID: string) =>
    (await openAssistBridge()).deleteBacklogItem(itemID)
  );
  ipcMain.handle("openassist:move-daily-item-to-backlog", async (_event, dayID: string | undefined, itemID: string) =>
    (await openAssistBridge()).moveDailyItemToBacklog(dayID, itemID)
  );
  ipcMain.handle("openassist:schedule-backlog-item", async (_event, itemID: string, targetDayID: string) =>
    (await openAssistBridge()).scheduleBacklogItem(itemID, targetDayID)
  );
  ipcMain.handle("openassist:load-thread-memory", async (_event, threadID: string) => (await openAssistBridge()).loadThreadMemory(threadID));
  ipcMain.handle("openassist:thread-agent-files-path", async (_event, threadID: string) =>
    (await openAssistBridge()).threadAgentFilesPath(threadID)
  );
  ipcMain.handle("openassist:create-thread", async (_event, projectID?: string, isTemporary?: boolean) =>
    (await openAssistBridge()).createAssistantThread(projectID, false, isTemporary === true)
  );
  ipcMain.handle("openassist:destroy-temporary-thread", async (_event, threadID: string) =>
    (await openAssistBridge()).destroyTemporaryThread(threadID)
  );
  ipcMain.handle("openassist:create-project", async (_event, name: string, kind: "project" | "folder", parentID?: string) =>
    (await openAssistBridge()).createProject(name, kind, parentID)
  );
  ipcMain.handle("openassist:rename-project", async (_event, projectID: string, name: string) =>
    (await openAssistBridge()).renameProject(projectID, name)
  );
  ipcMain.handle("openassist:update-project-icon", async (_event, projectID: string, symbol?: string | null) =>
    (await openAssistBridge()).updateProjectIcon(projectID, symbol)
  );
  ipcMain.handle("openassist:update-project-area", async (_event, projectID: string, area?: string | null) =>
    (await openAssistBridge()).updateProjectColorAndArea(projectID, area)
  );
  ipcMain.handle("openassist:choose-project-folder", async (_event, projectID: string) => {
    const owner = BrowserWindow.fromWebContents(_event.sender) ?? mainWindow;
    const options: Electron.OpenDialogOptions = {
      title: "Choose Project Folder",
      properties: ["openDirectory", "createDirectory"]
    };
    const result = owner ? await dialog.showOpenDialog(owner, options) : await dialog.showOpenDialog(options);
    if (result.canceled || !result.filePaths[0]) return null;
    return (await openAssistBridge()).updateProjectLinkedFolder(projectID, result.filePaths[0]);
  });
  ipcMain.handle("openassist:open-project-folder", async (_event, parentID?: string | null) => {
    const owner = BrowserWindow.fromWebContents(_event.sender) ?? mainWindow;
    const options: Electron.OpenDialogOptions = {
      title: "Open Existing Project Folder",
      properties: ["openDirectory"]
    };
    const result = owner ? await dialog.showOpenDialog(owner, options) : await dialog.showOpenDialog(options);
    if (result.canceled || !result.filePaths[0]) return null;
    return (await openAssistBridge()).createProjectFromFolder(result.filePaths[0], parentID);
  });
  ipcMain.handle("openassist:remove-project-folder-link", async (_event, projectID: string) =>
    (await openAssistBridge()).updateProjectLinkedFolder(projectID, null)
  );
  ipcMain.handle("openassist:move-project-to-folder", async (_event, projectID: string, folderID?: string | null) =>
    (await openAssistBridge()).moveProjectToFolder(projectID, folderID)
  );
  ipcMain.handle("openassist:hide-project", async (_event, projectID: string) =>
    (await openAssistBridge()).hideProject(projectID)
  );
  ipcMain.handle("openassist:unhide-project", async (_event, projectID: string) =>
    (await openAssistBridge()).unhideProject(projectID)
  );
  ipcMain.handle("openassist:delete-project", async (_event, projectID: string) =>
    (await openAssistBridge()).deleteProject(projectID)
  );
  ipcMain.handle("openassist:load-project-memory", async (_event, projectID: string) =>
    (await openAssistBridge()).loadProjectMemory(projectID)
  );
  ipcMain.handle("openassist:set-thread-provider", async (_event, threadID: string, backend: string, modelID?: string) =>
    (await openAssistBridge()).setThreadProvider(threadID, backend, modelID)
  );
  ipcMain.handle("openassist:rename-session", async (_event, threadID: string, title: string) =>
    (await openAssistBridge()).renameSession(threadID, title)
  );
  ipcMain.handle("openassist:promote-temporary-session", async (_event, threadID: string) =>
    (await openAssistBridge()).promoteTemporarySession(threadID)
  );
  ipcMain.handle("openassist:assign-session-to-project", async (_event, threadID: string, projectID?: string | null) =>
    (await openAssistBridge()).assignSessionToProject(threadID, projectID)
  );
  ipcMain.handle("openassist:archive-session", async (_event, threadID: string) =>
    (await openAssistBridge()).archiveSession(threadID)
  );
  ipcMain.handle("openassist:unarchive-session", async (_event, threadID: string) =>
    (await openAssistBridge()).unarchiveSession(threadID)
  );
  ipcMain.handle("openassist:delete-session-permanently", async (_event, threadID: string) =>
    (await openAssistBridge()).deleteSessionPermanently(threadID)
  );
  ipcMain.handle("openassist:load-note", async (_event, projectID: string, noteID: string) => (await openAssistBridge()).loadNote(projectID, noteID));
  ipcMain.handle("openassist:list-note-history", async (_event, projectID: string, noteID: string) =>
    (await openAssistBridge()).listProjectNoteHistory(projectID, noteID)
  );
  ipcMain.handle("openassist:restore-note-history", async (_event, projectID: string, noteID: string, historyID: string) =>
    (await openAssistBridge()).restoreProjectNoteHistory(projectID, noteID, historyID)
  );
  ipcMain.handle("openassist:load-note-links", async (_event, target: unknown, currentMarkdown?: string) =>
    (await openAssistBridge()).loadNoteLinks(target, currentMarkdown)
  );
  ipcMain.handle("openassist:read-note-image", async (_event, notePath: string, imageSrc: string) =>
    (await openAssistBridge()).readNoteImageDataURL(notePath, imageSrc)
  );
  ipcMain.handle("openassist:open-markdown-file-for-import", async (_event) => {
    const owner = BrowserWindow.fromWebContents(_event.sender) ?? mainWindow;
    const options: Electron.OpenDialogOptions = {
      title: "Open Markdown File",
      properties: ["openFile"],
      filters: [
        { name: "Markdown", extensions: ["md", "markdown", "mdown", "mkd"] },
        { name: "All Files", extensions: ["*"] }
      ]
    };
    const result = owner ? await dialog.showOpenDialog(owner, options) : await dialog.showOpenDialog(options);
    if (result.canceled || !result.filePaths[0]) return null;
    const filePath = result.filePaths[0];
    const markdown = fs.readFileSync(filePath, "utf8").replace(/\r\n/g, "\n");
    return {
      path: filePath,
      fileName: path.basename(filePath),
      title: titleForMarkdownImport(filePath, markdown),
      markdown
    };
  });
  ipcMain.handle("openassist:create-note", async (_event, projectID: string) => (await openAssistBridge()).createProjectNote(projectID));
  ipcMain.handle("openassist:rename-note", async (_event, projectID: string, noteID: string, title: string) =>
    (await openAssistBridge()).renameProjectNote(projectID, noteID, title)
  );
  ipcMain.handle("openassist:save-note", async (_event, projectID: string, noteID: string, markdown: string) =>
    (await openAssistBridge()).saveProjectNote(projectID, noteID, markdown)
  );
  ipcMain.handle("openassist:cleanup-note-with-codex", async (_event, request: unknown) =>
    (await openAssistBridge()).cleanupNoteWithCodex(request as any)
  );
  ipcMain.handle("openassist:delete-note", async (_event, projectID: string, noteID: string) =>
    (await openAssistBridge()).deleteProjectNote(projectID, noteID)
  );
  ipcMain.handle("openassist:archive-note", async (_event, projectID: string, noteID: string) =>
    (await openAssistBridge()).archiveProjectNote(projectID, noteID)
  );
  ipcMain.handle("openassist:restore-note", async (_event, projectID: string, noteID: string) =>
    (await openAssistBridge()).restoreProjectNote(projectID, noteID)
  );
  ipcMain.handle("openassist:delete-note-permanently", async (_event, projectID: string, noteID: string) =>
    (await openAssistBridge()).deleteProjectNotePermanently(projectID, noteID)
  );
  ipcMain.handle("openassist:create-note-folder", async (_event, projectID: string, name: string, parentFolderID?: string | null) =>
    (await openAssistBridge()).createProjectNoteFolder(projectID, name, parentFolderID ?? null)
  );
  ipcMain.handle("openassist:rename-note-folder", async (_event, projectID: string, folderID: string, name: string) =>
    (await openAssistBridge()).renameProjectNoteFolder(projectID, folderID, name)
  );
  ipcMain.handle("openassist:delete-note-folder", async (_event, projectID: string, folderID: string) =>
    (await openAssistBridge()).deleteProjectNoteFolder(projectID, folderID)
  );
  ipcMain.handle("openassist:move-note-folder", async (_event, projectID: string, folderID: string, parentFolderID: string | null) =>
    (await openAssistBridge()).moveProjectNoteFolder(projectID, folderID, parentFolderID)
  );
  ipcMain.handle("openassist:move-note-to-folder", async (_event, projectID: string, noteID: string, folderID: string | null) =>
    (await openAssistBridge()).moveProjectNoteToFolder(projectID, noteID, folderID)
  );
  ipcMain.handle("openassist:delete-thread-note", async (_event, threadID: string, noteID: string) =>
    (await openAssistBridge()).deleteThreadNote(threadID, noteID)
  );
  ipcMain.handle("openassist:archive-thread-note", async (_event, threadID: string, noteID: string) =>
    (await openAssistBridge()).archiveThreadNote(threadID, noteID)
  );
  ipcMain.handle("openassist:restore-thread-note", async (_event, threadID: string, noteID: string) =>
    (await openAssistBridge()).restoreThreadNote(threadID, noteID)
  );
  ipcMain.handle("openassist:delete-thread-note-permanently", async (_event, threadID: string, noteID: string) =>
    (await openAssistBridge()).deleteThreadNotePermanently(threadID, noteID)
  );
  ipcMain.handle("openassist:toggle-skill", async (_event, threadID: string, skillID: string, attached: boolean) =>
    (await openAssistBridge()).toggleThreadSkill(threadID, skillID, attached)
  );
  ipcMain.handle("openassist:import-skill-folder", async (_event) => {
    const window = BrowserWindow.fromWebContents(_event.sender) ?? mainWindow;
    const options: Electron.OpenDialogOptions = {
      title: "Import Skill",
      properties: ["openDirectory"]
    };
    const result = window ? await dialog.showOpenDialog(window, options) : await dialog.showOpenDialog(options);
    if (result.canceled || !result.filePaths[0]) return null;
    return (await openAssistBridge()).importSkillFolder(result.filePaths[0]);
  });
  ipcMain.handle("openassist:import-skill-github", async (_event, reference: string) =>
    (await openAssistBridge()).importSkillFromGitHub(reference)
  );
  ipcMain.handle("openassist:create-skill", async (_event, name: string, description: string) =>
    (await openAssistBridge()).createSkill(name, description)
  );
  ipcMain.handle("openassist:create-scheduled-job", async (_event, name: string, prompt: string) =>
    (await openAssistBridge()).createScheduledJob(name, prompt)
  );
  ipcMain.handle("openassist:toggle-scheduled-job", async (_event, jobID: string, enabled: boolean) =>
    (await openAssistBridge()).toggleScheduledJob(jobID, enabled)
  );
  ipcMain.handle("openassist:update-setting", async (_event, key: string, value: boolean | string | number) => {
    const updated = await (await openAssistBridge()).updateSetting(
      key as Parameters<OpenAssistBridge["updateSetting"]>[0],
      value
    );
    // Broadcast so other open windows (settings ↔ main) stay in sync.
    for (const window of BrowserWindow.getAllWindows()) {
      safeSendWindow(window, "openassist:settings-updated", updated);
    }
    return updated;
  });
  ipcMain.handle("openassist:update-settings", async (_event, updates: Parameters<OpenAssistBridge["updateSettings"]>[0]) => {
    const updated = await (await openAssistBridge()).updateSettings(updates);
    // Broadcast once for grouped edits like color theme presets.
    for (const window of BrowserWindow.getAllWindows()) {
      safeSendWindow(window, "openassist:settings-updated", updated);
    }
    return updated;
  });
  ipcMain.handle("openassist:preview-color-theme", async (_event, theme: string | null) => {
    const nextTheme = typeof theme === "string" && theme.trim() ? theme.trim() : null;
    for (const window of BrowserWindow.getAllWindows()) {
      safeSendWindow(window, "openassist:color-theme-preview", nextTheme);
    }
    return { ok: true };
  });
  ipcMain.handle("openassist:knowledge-status", async () =>
    (await openAssistBridge()).loadKnowledgeStatus()
  );
  ipcMain.handle("openassist:list-knowledge-requests", async (_event, status?: "pending" | "applied" | "rejected") =>
    (await openAssistBridge()).listKnowledgeWriteRequests(status)
  );
  ipcMain.handle("openassist:apply-knowledge-preview", async (_event, requestID: string) =>
    (await openAssistBridge()).applyKnowledgePreview(requestID)
  );
  ipcMain.handle("openassist:reject-knowledge-request", async (_event, requestID: string) =>
    (await openAssistBridge()).rejectKnowledgeRequest(requestID)
  );
  ipcMain.handle("openassist:update-shortcut", async (_event, target: string, keyCode: number, modifiers: number) => {
    const settings = await (await openAssistBridge()).updateShortcut(
      target as Parameters<OpenAssistBridge["updateShortcut"]>[0],
      keyCode,
      modifiers
    );
    registerConfiguredShortcuts(settings);
    return settings;
  });
  ipcMain.handle("openassist:submit-screen-analysis", async (_event, instruction: string, options?: { readback?: boolean }) =>
    submitScreenAnalysisPrompt(instruction, options)
  );
  ipcMain.handle("openassist:cancel-screen-analysis", async () => cancelScreenAnalysisPrompt());
  ipcMain.handle("openassist:copy-screen-analysis-capture", async () => {
    if (!lastCapturedImageBuffer) return { ok: false, error: "No capture available to copy." };
    clipboard.writeImage(nativeImage.createFromBuffer(lastCapturedImageBuffer));
    return { ok: true };
  });
  ipcMain.handle("openassist:list-screen-analysis-skills", async () => {
    try {
      const skills = (await openAssistBridge()).listScreenAnalysisSkills() as Array<{ id: string; title: string; group?: string }>;
      return { ok: true, skills, selected: screenAnalysisSelectedSkills };
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  });
  ipcMain.handle("openassist:toggle-screen-analysis-skill", async (_event, id: string, title: string) => {
    const skillID = String(id ?? "").trim();
    if (!skillID) return { ok: false, error: "Missing skill id.", skills: screenAnalysisSelectedSkills };
    const existingIndex = screenAnalysisSelectedSkills.findIndex((skill) => skill.id === skillID);
    if (existingIndex >= 0) {
      screenAnalysisSelectedSkills.splice(existingIndex, 1);
    } else {
      screenAnalysisSelectedSkills.push({ id: skillID, title: String(title ?? skillID) });
    }
    return { ok: true, skills: screenAnalysisSelectedSkills };
  });
  ipcMain.handle("openassist:add-screen-analysis-reference-from-data-url", async (_event, dataURL: string, name?: string) =>
    addScreenAnalysisReferenceFromDataURL(dataURL, name)
  );
  ipcMain.handle("openassist:remove-screen-analysis-reference", async (_event, index: number) =>
    removeScreenAnalysisReferenceImage(index)
  );
  ipcMain.handle("openassist:open-image-in-preview", async (_event, dataURL: string) =>
    openImageDataURLInPreview(dataURL)
  );
  ipcMain.handle("openassist:save-image", async (_event, dataURL: string, defaultName?: string) =>
    saveImageDataURL(dataURL, defaultName)
  );
  ipcMain.handle("openassist:open-local-path", async (_event, filePath: string) =>
    openLocalPath(filePath)
  );
  ipcMain.handle("openassist:get-local-file-preview", async (_event, filePath: string) =>
    getLocalFilePreview(filePath)
  );
  ipcMain.handle("openassist:reveal-local-path", async (_event, filePath: string) =>
    revealLocalPath(filePath)
  );
  ipcMain.handle("openassist:set-screen-analysis-frame-visible", async (_event, visible: boolean) =>
    setScreenAnalysisFrameVisible(visible)
  );
  ipcMain.handle("openassist:set-screen-analysis-menu-expanded", async (_event, expanded: boolean) =>
    setScreenAnalysisMenuExpanded(expanded)
  );
  ipcMain.handle("openassist:set-screen-analysis-panel-collapsed", async (_event, collapsed: boolean) =>
    setScreenAnalysisPanelCollapsed(collapsed)
  );
  ipcMain.handle("openassist:start-screen-analysis-at-same-place", async () =>
    restartScreenAnalysisAtSamePlace()
  );
  ipcMain.handle("openassist:list-screen-snip-presets", async () => ({
    presets: listScreenSnipPresets(),
    selected: readScreenSnipTheme()
  }));
  ipcMain.handle("openassist:set-screen-snip-theme", async (_event, theme: string) => {
    const key = normalizePaletteKey(theme);
    if (!screenSnipPalettes[key]) return { ok: false, error: "Unknown theme." };
    writeScreenSnipTheme(key);
    const payload = { selected: key, colors: screenSnipPalettes[key] };
    BrowserWindow.getAllWindows().forEach((window) => {
      safeSendWindow(window, "openassist:screen-snip-theme-changed", payload);
    });
    return { ok: true, selected: key };
  });
  ipcMain.handle("openassist:choose-screen-analysis-reference-images", async () =>
    chooseScreenAnalysisReferenceImages()
  );
  ipcMain.handle("openassist:complete-screen-selection", async (event, rect: ScreenRect) => {
    const senderWindow = BrowserWindow.fromWebContents(event.sender);
    const contentBounds = senderWindow?.getContentBounds();
    const inputRect = normalizeScreenRect(rect);
    const coordinateSpace = (rect as ScreenRect & { coordinateSpace?: string }).coordinateSpace;
    const normalized = contentBounds && (
      coordinateSpace === "window" ||
      (coordinateSpace !== "screen" && !rectCenterInsideBounds(inputRect, contentBounds))
    )
      ? normalizeScreenRect({
          x: contentBounds.x + inputRect.x,
          y: contentBounds.y + inputRect.y,
          width: inputRect.width,
          height: inputRect.height
        })
      : inputRect;
    debugLog(`screen selection completed input=${JSON.stringify(rect)} content=${JSON.stringify(contentBounds)} screen-rect=${JSON.stringify(normalized)}`);
    if (normalized.width < 12 || normalized.height < 12) {
      throw new Error("Selected area is too small.");
    }
    const display = screen.getDisplayMatching(normalized);
    const clamped = intersectScreenRect(normalized, display.bounds);
    if (clamped.width < 12 || clamped.height < 12) {
      const fallbackBounds = contentBounds ?? display.bounds;
      const fallbackRect = intersectScreenRect(normalized, fallbackBounds);
      if (fallbackRect.width < 12 || fallbackRect.height < 12) {
        throw new Error(`Selected area could not be matched to a display. input=${JSON.stringify(rect)} content=${JSON.stringify(contentBounds)} display=${JSON.stringify(display.bounds)}`);
      }
      const resolve = pendingScreenSelectionResolve;
      pendingScreenSelectionResolve = null;
      pendingScreenSelectionReject = null;
      screenSelectionWindow?.close();
      screenSelectionWindow = null;
      resolve?.(fallbackRect);
      return { ok: true };
    }
    const resolve = pendingScreenSelectionResolve;
    pendingScreenSelectionResolve = null;
    pendingScreenSelectionReject = null;
    screenSelectionWindow?.close();
    screenSelectionWindow = null;
    resolve?.(clamped);
    return { ok: true };
  });
  ipcMain.handle("openassist:cancel-screen-selection", async () => {
    const reject = pendingScreenSelectionReject;
    pendingScreenSelectionResolve = null;
    pendingScreenSelectionReject = null;
    screenSelectionWindow?.close();
    screenSelectionWindow = null;
    reject?.(new Error("Screen analysis cancelled."));
    return { ok: true };
  });
  ipcMain.handle("openassist:set-screen-analysis-frame-interactive", async (event, interactive: boolean) => {
    const senderWindow = BrowserWindow.fromWebContents(event.sender);
    if (!senderWindow || senderWindow.isDestroyed()) return { ok: false };
    if (interactive) {
      senderWindow.setIgnoreMouseEvents(false);
    } else {
      senderWindow.setIgnoreMouseEvents(true, { forward: true });
    }
    return { ok: true };
  });
  ipcMain.handle("openassist:save-prompt-rewrite-api-key", async (_event, provider: string, token: string) =>
    (await openAssistBridge()).savePromptRewriteAPIKey(provider, token)
  );
  ipcMain.handle("openassist:clear-prompt-rewrite-api-key", async (_event, provider: string) =>
    (await openAssistBridge()).clearPromptRewriteAPIKey(provider)
  );
  ipcMain.handle("openassist:save-cloud-transcription-api-key", async (_event, provider: string, token: string) =>
    (await openAssistBridge()).saveCloudTranscriptionAPIKey(provider, token)
  );
  ipcMain.handle("openassist:clear-cloud-transcription-api-key", async (_event, provider: string) =>
    (await openAssistBridge()).clearCloudTranscriptionAPIKey(provider)
  );
  ipcMain.handle("openassist:save-realtime-openai-api-key", async (_event, token: string) =>
    (await openAssistBridge()).saveRealtimeOpenAIAPIKey(token)
  );
  ipcMain.handle("openassist:clear-realtime-openai-api-key", async () =>
    (await openAssistBridge()).clearRealtimeOpenAIAPIKey()
  );
  ipcMain.handle("openassist:save-realtime-gemini-api-key", async (_event, token: string) =>
    (await openAssistBridge()).saveRealtimeGeminiAPIKey(token)
  );
  ipcMain.handle("openassist:clear-realtime-gemini-api-key", async () =>
    (await openAssistBridge()).clearRealtimeGeminiAPIKey()
  );
  ipcMain.handle("openassist:save-telegram-bot-token", async (_event, token: string) =>
    (await openAssistBridge()).saveTelegramBotToken(token)
  );
  ipcMain.handle("openassist:clear-telegram-bot-token", async () =>
    (await openAssistBridge()).clearTelegramBotToken()
  );
  ipcMain.handle("openassist:approve-telegram-pairing", async () =>
    (await openAssistBridge()).approveTelegramPairing()
  );
  ipcMain.handle("openassist:decline-telegram-pairing", async () =>
    (await openAssistBridge()).declineTelegramPairing()
  );
  ipcMain.handle("openassist:forget-telegram-pairing", async () =>
    (await openAssistBridge()).forgetTelegramPairing()
  );
  ipcMain.handle("openassist:test-telegram-connection", async (_event, token?: string) =>
    (await openAssistBridge()).testTelegramConnection(token)
  );
  ipcMain.handle("openassist:rotate-remote-access-pairing-code", async () =>
    (await openAssistBridge()).rotateRemoteAccessPairingCode()
  );
  ipcMain.handle("openassist:clear-remote-access-pairing-code", async () =>
    (await openAssistBridge()).clearRemoteAccessPairingCode()
  );
  ipcMain.handle("openassist:start-remote-access-easy-qr", async () =>
    (await openAssistBridge()).startRemoteAccessEasyQR()
  );
  ipcMain.handle("openassist:stop-remote-access-easy-qr", async () =>
    (await openAssistBridge()).stopRemoteAccessEasyQR()
  );
  ipcMain.handle("openassist:get-remote-access-status", async () =>
    (await openAssistBridge()).getRemoteAccessStatus()
  );
  ipcMain.handle("openassist:send-message", async (
    event,
    prompt: string,
    threadID?: string,
    pluginIDs?: string[],
    sessionInstructions?: string,
    reasoningEffort?: string,
    interactionMode?: string,
    permissionMode?: string,
    skillIDs?: string[],
    clientRunID?: string,
    attachments?: unknown[]
  ) => {
    const bridge = await openAssistBridge();
    const replyTarget = event.sender;
    const sendProviderEvent = (providerEvent: unknown) => {
      safeSendWebContents(replyTarget, "openassist:provider-event", providerEvent);
    };
    try {
      return await bridge.sendCodexMessage(
        prompt,
        threadID,
        pluginIDs,
        sessionInstructions,
        reasoningEffort,
        interactionMode,
        permissionMode,
        skillIDs,
        clientRunID,
        attachments,
        sendProviderEvent
      );
    } catch (error) {
      sendProviderEvent({
        runID: clientRunID,
        threadID: threadID || "new",
        type: "failed",
        provider: "Assistant",
        error: error instanceof Error ? error.message : "The provider failed before returning a response."
      });
      throw error;
    }
  });
  ipcMain.handle("openassist:codex-runtime-parity-probe", async (_event, options?: unknown) =>
    (await openAssistBridge()).codexRuntimeParityProbe(options as Parameters<(typeof import("./openassistBridge.js"))["codexRuntimeParityProbe"]>[0])
  );
  ipcMain.handle("openassist:stop-message", async (_event, clientRunID?: string) =>
    (await openAssistBridge()).stopProviderRun(clientRunID)
  );
  ipcMain.handle("openassist:respond-provider-request", async (_event, requestID: string | number, result: unknown) =>
    (await openAssistBridge()).respondToProviderRequest(requestID, result)
  );
  ipcMain.handle("openassist:install-kokoro-voice-model", async (_event, voiceID?: string) =>
    (await openAssistBridge()).installKokoroVoiceModel(voiceID)
  );
  ipcMain.handle("openassist:speak-assistant-response", async (_event, text: string, options?: { force?: boolean; engine?: string; voice?: string }) =>
    (await openAssistBridge()).speakAssistantResponse(text, options)
  );
  ipcMain.handle("openassist:prepare-read-aloud-audio", async (_event, text: string, options?: { engine?: string; voice?: string; model?: string }) =>
    (await openAssistBridge()).prepareReadAloudAudio(text, options)
  );
  ipcMain.handle("openassist:start-note-read-aloud", async (event, request?: { text?: string; source?: "selection" | "whole-note" | "message"; title?: string; targetID?: string }) => {
    const replyTarget = event.sender;
    return (await openAssistBridge()).startNoteReadAloud(
      {
        text: request?.text ?? "",
        source: request?.source,
        title: request?.title,
        targetID: request?.targetID
      },
      (state: unknown) => safeSendWebContents(replyTarget, "openassist:note-read-aloud-state", state)
    );
  });
  ipcMain.handle("openassist:pause-note-read-aloud", async () =>
    (await openAssistBridge()).pauseNoteReadAloud()
  );
  ipcMain.handle("openassist:resume-note-read-aloud", async () =>
    (await openAssistBridge()).resumeNoteReadAloud()
  );
  ipcMain.handle("openassist:stop-note-read-aloud", async () =>
    (await openAssistBridge()).stopNoteReadAloud()
  );
  ipcMain.handle("openassist:prewarm-assistant-voice-output", async (_event, options?: { engine?: string; voice?: string }) =>
    (await openAssistBridge()).prewarmAssistantVoiceOutput(options)
  );
  ipcMain.handle("openassist:stop-assistant-voice-output", async () =>
    (await openAssistBridge()).stopAssistantVoiceOutput()
  );
  ipcMain.handle("openassist:start-wake-word-for-today", async (_event, options?: WakeWordStartOptions) =>
    startWakeWordForToday(options)
  );
  ipcMain.handle("openassist:stop-wake-word-for-today", async (_event, reason?: string) =>
    stopWakeWordForToday(typeof reason === "string" && reason.trim() ? reason.trim() : "manual")
  );
  ipcMain.handle("openassist:get-wake-word-status", async () => wakeWordStatus);
  ipcMain.handle("openassist:voice-input-configuration", async () => (await openAssistBridge()).voiceInputConfiguration());
  ipcMain.handle("openassist:list-microphones", async () => listMicrophones());
  ipcMain.handle("openassist:start-voice-input", async (_event, options?: VoiceStartOptions) => startConfiguredVoiceInput(options));
  ipcMain.handle("openassist:stop-voice-input", async () => stopConfiguredVoiceInput());
  ipcMain.handle("openassist:local-voice-transcribe", async (_event, request?: LocalVoiceTranscriptionRequest) =>
    transcribeLocalVoiceAudio(request)
  );
  ipcMain.handle("openassist:local-voice-classify", async (_event, input: unknown) =>
    (await openAssistBridge()).classifyLocalVoiceTranscript(input as Parameters<(typeof import("./openassistBridge.js"))["classifyLocalVoiceTranscript"]>[0])
  );
  ipcMain.handle("openassist:local-voice-direct-knowledge", async (_event, input: unknown) =>
    (await openAssistBridge()).handleLocalVoiceDirectKnowledge(input as Parameters<(typeof import("./openassistBridge.js"))["handleLocalVoiceDirectKnowledge"]>[0])
  );
  ipcMain.handle("openassist:realtime-start", async (event, options?: {
    threadID?: string;
    threadId?: string;
    provider?: string;
    interactionMode?: string;
    permissionMode?: string;
    reasoningEffort?: string;
    pluginIDs?: string[];
    skillIDs?: string[];
    contextHint?: string;
  }) =>
    (await openAssistBridge()).startCodexRealtimeVoice(
      {
        threadID: options?.threadID ?? options?.threadId,
        provider: options?.provider,
        interactionMode: options?.interactionMode,
        permissionMode: options?.permissionMode,
        reasoningEffort: options?.reasoningEffort,
        pluginIDs: options?.pluginIDs,
        skillIDs: options?.skillIDs,
        contextHint: options?.contextHint
      },
      (payload: unknown) => {
        broadcastRealtimeEvent(payload, event.sender);
      }
    )
  );
  ipcMain.handle("openassist:realtime-append-audio", async (_event, audio: unknown) =>
    (await openAssistBridge()).appendCodexRealtimeAudio(audio as Parameters<(typeof import("./openassistBridge.js"))["appendCodexRealtimeAudio"]>[0])
  );
  ipcMain.handle("openassist:realtime-append-text", async (_event, text: string) =>
    (await openAssistBridge()).appendCodexRealtimeText(text)
  );
  ipcMain.handle("openassist:realtime-append-images", async (_event, input: unknown) =>
    (await openAssistBridge()).appendCodexRealtimeImages(input)
  );
  ipcMain.handle("openassist:realtime-stop", async () =>
    (await openAssistBridge()).stopCodexRealtimeVoice()
  );
  ipcMain.handle("openassist:realtime-stop-delegation", async () =>
    (await openAssistBridge()).stopCodexRealtimeDelegation()
  );
  ipcMain.handle("openassist:realtime-list-voices", async () =>
    (await openAssistBridge()).listCodexRealtimeVoices()
  );
  ipcMain.handle("openassist:update-voice-hud", async (_event, payload: VoiceHUDPayload) => updateVoiceHUD(payload ?? { visible: false }));
  ipcMain.handle("openassist:live-voice-hud-action", async (_event, action: "toggleMute" | "stop" | "approveRequest" | "rejectRequest") => {
    if (action !== "toggleMute" && action !== "stop") return { ok: false };
    BrowserWindow.getAllWindows().forEach((window) => {
      if (window === voiceHUDWindow) return;
      safeSendWindow(window, "openassist:live-voice-hud-action", action);
    });
    return { ok: true };
  });
  ipcMain.handle("openassist:set-window-mode", async (
    _event,
    mode: AssistantWindowMode,
    sidebarOpen?: boolean,
    sidebarEdge?: "left" | "right",
    notchDockRevealed?: boolean
  ) => {
    const window = mainWindow;
    if (window && !window.isDestroyed()) {
      const nextMode: AssistantWindowMode = mode === "sidebar" || mode === "notch" ? mode : "full";
      applyWindowMode(
        window,
        nextMode,
        sidebarOpen !== false,
        sidebarEdge === "left" ? "left" : "right",
        Boolean(notchDockRevealed)
      );
    }
    return { ok: true };
  });
  ipcMain.handle("openassist:hide-window", async (_event) => {
    const window = BrowserWindow.fromWebContents(_event.sender) ?? mainWindow;
    window?.hide();
    switchToMenuBarOnlyPresence("hide window request");
    return { ok: true };
  });
  ipcMain.handle("openassist:set-sidebar-pinned", async (_event, pinned: boolean) => {
    sidebarPinnedPreference = pinned;
    const window = BrowserWindow.fromWebContents(_event.sender) ?? mainWindow;
    if (window && currentWindowMode === "sidebar" && currentSidebarOpen) {
      if (pinned) {
        window.setAlwaysOnTop(true, "floating");
      } else {
        window.setAlwaysOnTop(false);
      }
    }
    syncSidebarScreenFollowTimer();
    return { ok: true };
  });

  createMainWindow();
  setupMenuBarTray();
  setTimeout(prewarmVoiceHUDWindow, 250);
  setTimeout(prewarmVoiceHelperBuild, 700);
  setTimeout(installApplicationMenu, 800);
  setTimeout(prewarmSettingsWindow, 2200);
  startFrontmostApplicationTracker();
  globalShortcut.register("CommandOrControl+Shift+Space", toggleMainWindowVisibility);
  registerFixedShortcuts();
  void refreshConfiguredShortcuts();

  app.on("activate", () => {
    ensureRegularDockPresence("app activate");
    if (isScreenAnalysisSurfaceActive()) {
      debugLog("app activate ignored while screen analysis surface is active");
      return;
    }
    if (BrowserWindow.getAllWindows().length === 0) {
      createMainWindow();
    } else {
      mainWindow?.show();
      mainWindow?.focus();
    }
  });
});

app.on("before-quit", (event) => {
  isQuitting = true;
  if (!ollamaQuitCleanupStarted && !ollamaQuitCleanupFinished) {
    event.preventDefault();
    ollamaQuitCleanupStarted = true;
    debugLog("before-quit: unloading Ollama models used by Open Assist");
    const cleanupTimeout = new Promise<void>((resolve) => setTimeout(resolve, 3_500));
    void Promise.race([
      openAssistBridge()
        .then((bridge) => bridge.unloadOllamaModelsUsedThisSession())
        .then((result) => {
          debugLog(`before-quit: Ollama unload result=${JSON.stringify(result)}`);
        })
        .catch((error) => {
          debugLog(`before-quit: Ollama unload failed=${error instanceof Error ? error.message : String(error)}`);
        }),
      cleanupTimeout
    ]).finally(() => {
      ollamaQuitCleanupFinished = true;
      flushDebugLogSync();
      app.quit();
    });
    return;
  }
  flushDebugLogSync();
});

app.on("will-quit", () => {
  isQuitting = true;
  const wakeCapture = wakeWordCapture;
  if (wakeCapture) {
    terminateWakeWordCapture(wakeCapture, "app quit");
    wakeWordCapture = null;
  }
  clearWakeWordRestartTimer();
  stopAssistantVoiceOutputForSessionEnd("app quit");
  shortcutMonitorGeneration += 1;
  stopShortcutMonitor();
  stopFrontmostApplicationTracker();
  flushDebugLogSync();
  stopVoiceLevelPolling();
  if (menuBarIconTimer) {
    clearInterval(menuBarIconTimer);
    menuBarIconTimer = null;
  }
  menuBarPopoverWindow?.close();
  menuBarPopoverWindow = null;
  menuBarTray?.destroy();
  menuBarTray = null;
  clearVoiceHUDAutoHide();
  voiceHUDWindow?.close();
  voiceHUDWindow = null;
  screenSelectionWindow?.close();
  screenSelectionWindow = null;
  screenAnalysisFrameWindow?.close();
  screenAnalysisFrameWindow = null;
  screenAnalysisWindow?.close();
  screenAnalysisWindow = null;
  transcriptHistoryWindow?.close();
  transcriptHistoryWindow = null;
  settingsWindow?.close();
  settingsWindow = null;
  globalShortcut.unregisterAll();
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});
