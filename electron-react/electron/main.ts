import { app, BrowserWindow, clipboard, dialog, globalShortcut, ipcMain, Menu, nativeImage, nativeTheme, screen, session, shell, Tray, type OpenDialogOptions, type WebContents } from "electron";
import fs from "node:fs";
import { execFileSync, spawn, execFile, type ChildProcess } from "node:child_process";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const isDev = Boolean(process.env.VITE_DEV_SERVER_URL);
const isAccessibilityTestMode = process.env.OPENASSIST_ELECTRON_AX_TEST === "1";
const shouldForceAccessibility = process.env.OPENASSIST_ELECTRON_NO_FORCE_AX !== "1";

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
let transcriptHistoryWindow: BrowserWindow | null = null;
let settingsWindow: BrowserWindow | null = null;
let menuBarTray: Tray | null = null;
let menuBarPopoverWindow: BrowserWindow | null = null;
let menuBarPopoverShownAt = 0;
let menuBarPopoverBlurTimer: NodeJS.Timeout | null = null;
let isQuitting = false;
let voiceHUDReady = false;
let pendingVoiceHUDPayload: VoiceHUDPayload | null = null;
let voiceHUDLevelTimer: NodeJS.Timeout | null = null;
let voiceHUDLevelMtime = 0;
let smoothedVoiceLevel = 0;
let voiceHUDAutoHideTimer: NodeJS.Timeout | null = null;

function broadcastRealtimeEvent(payload: unknown, sender?: WebContents) {
  const targets = new Set<WebContents>();
  if (sender && !sender.isDestroyed()) targets.add(sender);
  BrowserWindow.getAllWindows().forEach((window) => {
    if (!window.isDestroyed() && !window.webContents.isDestroyed()) {
      targets.add(window.webContents);
    }
  });
  targets.forEach((target) => target.send("openassist:realtime-event", payload));
}

let lastVoiceHUDAppearance: Pick<VoiceHUDPayload, "theme" | "colorTheme" | "chromeStyle"> = {
  theme: "Vibrant Spectrum",
  colorTheme: "Ocean",
  chromeStyle: "Glass (High Contrast)"
};
let frontmostTrackerTimer: NodeJS.Timeout | null = null;
let lastExternalApplication: FrontmostApplicationSnapshot | null = null;
let currentWindowMode: "full" | "sidebar" = "full";
let currentSidebarOpen = true;
let currentSidebarEdge: "left" | "right" = "right";
let sidebarPinnedPreference = true;
let sidebarScreenFollowTimer: NodeJS.Timeout | null = null;
let menuBarIconTimer: NodeJS.Timeout | null = null;
let menuBarIconPhase = 0;
let menuBarVoiceStatus: "idle" | "listening" | "processing" | "error" = "idle";
let menuBarVoiceLevel = 0;
let menuBarVoiceText = "";
let voiceCapture: {
  sessionDirectory: string;
  appPath: string;
  engine: "appleSpeech" | "cloudProviders" | "whisperCpp";
  audioPath?: string;
  fileName?: string;
  mimeType?: string;
  processing?: boolean;
  voiceOptions?: VoiceStartOptions;
  whisperModelID?: string;
  whisperModelPath?: string;
  whisperUseCoreML?: boolean;
} | null = null;
type OpenAssistBridge = typeof import("./openassistBridge.js");
let bridgeModule: Promise<OpenAssistBridge> | null = null;
type ScreenRect = {
  x: number;
  y: number;
  width: number;
  height: number;
};
type VoiceHUDPayload = {
  visible?: boolean;
  status?: "idle" | "listening" | "processing" | "unsupported" | "error" | "message" | "correction" | "analyzing" | "analysis-result" | "analyzing-input";
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
};
type ScreenAnalysisGeneratedImage = {
  dataURL: string;
  mimeType: string;
  name: string;
  prompt?: string;
};
type MenuBarCommand =
  | "open-assistant"
  | "speak-assistant-task"
  | "toggle-dictation"
  | "open-history"
  | "open-models"
  | "open-settings";
type MenuBarAction = MenuBarCommand | "paste-last-transcript" | "quit";
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

function debugLog(message: string) {
  try {
    fs.appendFileSync(electronDebugLogPath(), `[${new Date().toISOString()}] ${message}\n`, "utf8");
  } catch {
    // Never let logging break the app.
  }
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

function readNativeDefaultSync(key: string, fallback: string) {
  try {
    const stdout = execFileSync("defaults", ["read", "com.developingadventures.OpenAssist", key], {
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
  if (!window || window.isDestroyed() || !window.isVisible()) return;
  positionMenuBarPopoverWindow(window);
  window.loadURL(`data:text/html;base64,${Buffer.from(menuBarPopoverHTML()).toString("base64")}`);
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
    case "listening":
      return "Listening...";
    case "processing":
      return "Finalizing...";
    case "error":
      return "Needs attention";
    case "idle":
    default:
      return "Permissions ready";
  }
}

function menuBarActivityDetail() {
  if (menuBarVoiceStatus !== "listening" && menuBarVoiceStatus !== "processing" && menuBarVoiceStatus !== "error") return "";
  return menuBarVoiceText;
}

function menuBarPopoverHTML() {
  const dictationLabel = menuBarVoiceStatus === "listening" ? "Stop Dictation" : "Start Dictation";
  const popoverTheme = nativeTheme.shouldUseDarkColors ? "dark" : "light";
  const logoDataURL = assetDataURL("assets/AppLogo.png", "image/png");
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<style>
  :root { color-scheme: ${popoverTheme}; }
  html, body {
    width: 100%;
    height: 100%;
    margin: 0;
    overflow: hidden;
    background: transparent;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Inter", sans-serif;
    letter-spacing: 0;
  }
  * { box-sizing: border-box; user-select: none; }
  button { font: inherit; color: inherit; border: 0; background: none; text-align: left; }
  .popover {
    position: relative;
    width: 100%;
    height: 100%;
    padding: 12px;
    color: rgba(242, 238, 232, 0.94);
    background:
      radial-gradient(120% 92% at 0% 100%, rgba(134, 55, 34, 0.40), transparent 58%),
      radial-gradient(100% 90% at 100% 0%, rgba(45, 74, 100, 0.26), transparent 60%),
      linear-gradient(180deg, rgba(61, 42, 32, 0.965), rgba(34, 20, 14, 0.985));
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 24px;
    box-shadow:
      0 24px 52px rgba(0, 0, 0, 0.42),
      0 2px 10px rgba(0, 0, 0, 0.18),
      inset 0 1px 0 rgba(255,255,255,0.08);
    backdrop-filter: blur(30px) saturate(1.28);
  }
  .popover::before {
    position: absolute;
    top: -11px;
    left: calc(50% - 13px);
    width: 0;
    height: 0;
    border-left: 13px solid transparent;
    border-right: 13px solid transparent;
    border-bottom: 13px solid rgba(55, 34, 24, 0.98);
    background: transparent;
    filter: none;
    content: "";
  }
  .popover::after {
    position: absolute;
    inset: 0;
    border-radius: inherit;
    pointer-events: none;
    box-shadow: inset 0 0 0 0.5px rgba(255,255,255,0.08);
    content: "";
  }
  .inner { position: relative; z-index: 1; }
  .header {
    display: grid;
    grid-template-columns: 34px 1fr;
    align-items: center;
    gap: 12px;
    padding: 10px 10px 12px;
  }
  .header-copy { min-width: 0; }
  .logo {
    width: 34px;
    height: 34px;
    display: grid;
    place-items: center;
    border-radius: 999px;
    overflow: hidden;
    border: 1px solid rgba(238, 206, 91, 0.72);
    color: rgba(241, 207, 94, 0.96);
    box-shadow: 0 0 18px rgba(238, 169, 73, 0.16);
  }
  .logo img { width: 100%; height: 100%; display: block; object-fit: cover; }
  .logo svg { width: 21px; height: 21px; }
  .title {
    margin: 0;
    font-size: 15px;
    line-height: 1.1;
    font-weight: 650;
    color: rgba(255, 255, 255, 0.95);
  }
  .status-line {
    display: grid;
    grid-template-columns: minmax(0, max-content) auto;
    align-items: baseline;
    gap: 7px;
    margin-top: 3px;
    color: rgba(225, 215, 204, 0.66);
    font-size: 11px;
    font-weight: 560;
  }
  .status-line span:first-child {
    min-width: 0;
    max-width: 120px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .status-line span:last-child {
    font-size: 10px;
    font-weight: 650;
    color: rgba(225, 215, 204, 0.54);
    white-space: nowrap;
  }
  .activity-card {
    display: grid;
    grid-template-columns: 26px minmax(0, 1fr);
    align-items: center;
    gap: 12px;
    min-height: 56px;
    margin: 0 10px 10px;
    padding: 10px 14px;
    border-radius: 12px;
    background:
      linear-gradient(180deg, rgba(255,255,255,0.070), rgba(255,255,255,0.014)),
      rgba(229, 67, 54, 0.070);
    box-shadow: inset 0 0 0 0.5px rgba(229, 67, 54, 0.16);
  }
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
    border: 2px solid rgba(231, 151, 74, 0.22);
    border-top-color: rgba(231, 151, 74, 0.96);
    animation: spin 820ms linear infinite;
  }
  .activity-card.finalizing {
    background:
      linear-gradient(180deg, rgba(255,255,255,0.055), rgba(255,255,255,0.012)),
      rgba(231, 151, 74, 0.075);
    box-shadow: inset 0 0 0 0.5px rgba(231, 151, 74, 0.16);
  }
  .activity-card.finalizing .activity-label { color: rgba(236, 174, 92, 0.96); }
  @keyframes recordingPulse {
    from { transform: scale(0.72); opacity: 1; }
    to { transform: scale(1.42); opacity: 0; }
  }
  @keyframes spin {
    to { transform: rotate(360deg); }
  }
  .divider {
    height: 1px;
    margin: 0 -12px 8px;
    background: rgba(255, 255, 255, 0.10);
  }
  .section-title {
    margin: 9px 0 4px;
    padding: 0 6px;
    color: rgba(218, 207, 195, 0.58);
    font-size: 10px;
    font-weight: 650;
  }
  .menu-row {
    width: 100%;
    min-height: 38px;
    display: grid;
    grid-template-columns: 22px minmax(0, 1fr) auto;
    align-items: center;
    gap: 12px;
    padding: 8px 10px;
    border-radius: 7px;
  }
  .menu-row:hover { background: rgba(255, 255, 255, 0.078); }
  .menu-icon {
    width: 22px;
    height: 22px;
    display: grid;
    place-items: center;
    border-radius: 7px;
    color: rgba(236, 168, 77, 0.94);
    background:
      linear-gradient(180deg, rgba(255,255,255,0.07), rgba(255,255,255,0.01)),
      rgba(184, 106, 37, 0.22);
    box-shadow: inset 0 0 0 0.5px rgba(255,255,255,0.075);
  }
  .tone-ai { color: rgba(240, 190, 86, 0.96); background-color: rgba(190, 119, 39, 0.24); }
  .tone-accent { color: rgba(231, 147, 65, 0.96); background-color: rgba(184, 106, 37, 0.22); }
  .tone-history { color: rgba(230, 176, 70, 0.94); background-color: rgba(157, 114, 34, 0.20); }
  .tone-settings { color: rgba(235, 168, 79, 0.95); background-color: rgba(177, 103, 38, 0.20); }
  .tone-neutral { color: rgba(204, 199, 194, 0.72); background-color: rgba(255,255,255,0.07); }
  .menu-icon svg { width: 12px; height: 12px; stroke-width: 2.15; }
  .row-text {
    display: grid;
    gap: 1px;
    min-width: 0;
  }
  .row-label {
    color: rgba(247, 245, 242, 0.91);
    font-size: 13px;
    font-weight: 560;
    line-height: 1.16;
  }
  .row-detail {
    max-width: 190px;
    overflow: hidden;
    color: rgba(226, 217, 206, 0.48);
    font-size: 10px;
    font-weight: 520;
    line-height: 1.25;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .shortcut {
    color: rgba(226, 217, 206, 0.58);
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 11px;
    font-weight: 450;
  }
  .row-spacer { height: 1px; margin: 8px 0; background: rgba(255, 255, 255, 0.10); }
  body[data-theme="light"] .popover {
    color: rgba(35, 31, 27, 0.94);
    background:
      radial-gradient(115% 95% at 0% 100%, rgba(218, 157, 81, 0.22), transparent 58%),
      radial-gradient(100% 95% at 100% 0%, rgba(112, 138, 172, 0.18), transparent 60%),
      linear-gradient(180deg, rgba(255, 251, 246, 0.985), rgba(238, 229, 219, 0.985));
    border-color: rgba(44, 36, 28, 0.14);
    box-shadow: 0 22px 46px rgba(68, 54, 42, 0.22), inset 0 1px 0 rgba(255,255,255,0.72);
  }
  body[data-theme="light"] .popover::before {
    border-bottom-color: rgba(247, 238, 228, 0.98);
  }
  body[data-theme="light"] .title { color: rgba(33, 29, 26, 0.95); }
  body[data-theme="light"] .status-line,
  body[data-theme="light"] .section-title,
  body[data-theme="light"] .shortcut {
    color: rgba(77, 65, 55, 0.66);
  }
  body[data-theme="light"] .divider,
  body[data-theme="light"] .row-spacer {
    background: rgba(70, 55, 42, 0.13);
  }
  body[data-theme="light"] .activity-card {
    background:
      linear-gradient(180deg, rgba(255,255,255,0.66), rgba(255,255,255,0.14)),
      rgba(229, 67, 54, 0.080);
    box-shadow: inset 0 0 0 0.5px rgba(176, 55, 43, 0.16);
  }
  body[data-theme="light"] .activity-card.finalizing {
    background:
      linear-gradient(180deg, rgba(255,255,255,0.66), rgba(255,255,255,0.14)),
      rgba(190, 119, 39, 0.095);
    box-shadow: inset 0 0 0 0.5px rgba(151, 86, 28, 0.16);
  }
  body[data-theme="light"] .menu-row:hover { background: rgba(80, 58, 37, 0.07); }
  body[data-theme="light"] .menu-icon {
    color: rgba(151, 86, 28, 0.94);
    background: rgba(187, 118, 51, 0.16);
  }
  body[data-theme="light"] .tone-ai { color: rgba(135, 82, 22, 0.94); background-color: rgba(190, 119, 39, 0.15); }
  body[data-theme="light"] .tone-neutral { color: rgba(94, 86, 79, 0.70); background-color: rgba(70,55,42,0.07); }
  body[data-theme="light"] .row-label { color: rgba(39, 34, 30, 0.92); }
  body[data-theme="light"] .row-detail { color: rgba(82, 70, 60, 0.52); }
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
          <div class="status-line"><span>${escapeHTML(menuBarHeaderStatusLabel())}</span><span>Quick Controls</span></div>
        </div>
      </header>
      ${menuBarActivityHTML()}
      <div class="divider"></div>
      <section>
        <div class="section-title">Assistant</div>
        ${menuBarRow("open-assistant", "Open Assistant", "", "sparkles", "", "ai")}
        ${menuBarRow("speak-assistant-task", "Speak Assistant Task", "", "wave", "", "accent")}
      </section>
      <div class="row-spacer"></div>
      <section>
        <div class="section-title">Voice & Dictation</div>
        ${menuBarRow("toggle-dictation", dictationLabel, "", "mic", "", "accent")}
        ${menuBarRow("paste-last-transcript", "Paste Last Transcript", "", "clipboard", "⌘⌥V", "accent")}
      </section>
      <div class="row-spacer"></div>
      <section>
        <div class="section-title">Open</div>
        ${menuBarRow("open-history", "History", "", "history", "", "history")}
        ${menuBarRow("open-models", "Models & Connections", "", "brain", "", "ai")}
        ${menuBarRow("open-settings", "Settings", "", "gear", "⌘,", "settings")}
      </section>
      <div class="row-spacer"></div>
      <section>
        <div class="section-title">System</div>
        ${menuBarRow("quit", "Quit Open Assist", "", "power", "", "neutral")}
      </section>
    </div>
  </main>
  <script>
    document.addEventListener("click", (event) => {
      const button = event.target.closest("[data-action]");
      if (!button || !window.openAssistElectron) return;
      window.openAssistElectron.menuBarAction(button.dataset.action);
    });
  </script>
</body>
</html>`;
}

function menuBarActivityHTML() {
  if (menuBarVoiceStatus === "listening") {
    const detail = menuBarActivityDetail();
    return `<div class="activity-card recording">
      <span class="recording-dot" aria-hidden="true"></span>
      <span class="activity-text">
        <span class="activity-label">Listening...</span>
        ${detail ? `<span class="activity-detail">${escapeHTML(detail)}</span>` : ""}
      </span>
    </div>`;
  }
  if (menuBarVoiceStatus === "processing") {
    const detail = menuBarActivityDetail();
    return `<div class="activity-card finalizing">
      <span class="finalizing-spinner" aria-hidden="true"></span>
      <span class="activity-text">
        <span class="activity-label">${escapeHTML(menuBarHeaderStatusLabel())}</span>
        ${detail ? `<span class="activity-detail">${escapeHTML(detail)}</span>` : ""}
      </span>
    </div>`;
  }
  return "";
}

function menuBarIconSVG(name: "sparkles" | "wave" | "mic" | "clipboard" | "history" | "brain" | "gear" | "power") {
  switch (name) {
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
  tone: MenuBarIconTone = "accent"
) {
  return `<button class="menu-row" data-action="${action}">
    <span class="menu-icon tone-${tone}">${menuBarIconSVG(icon)}</span>
    <span class="row-text"><span class="row-label">${escapeHTML(label)}</span>${detail ? `<span class="row-detail">${escapeHTML(detail)}</span>` : ""}</span>
    ${shortcut ? `<span class="shortcut">${escapeHTML(shortcut)}</span>` : ""}
  </button>`;
}

function positionMenuBarPopoverWindow(window: BrowserWindow) {
  const bounds = menuBarTray?.getBounds();
  if (!bounds) return;
  const size = menuBarPopoverSize;
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
      sandbox: false
    }
  });
  window.on("focus", clearMenuBarPopoverBlurTimer);
  window.on("blur", () => scheduleMenuBarPopoverBlurHide("blur"));
  window.on("hide", clearMenuBarPopoverBlurTimer);
  window.webContents.on("before-input-event", (_event, input) => {
    if (input.type === "keyDown" && input.key === "Escape") hideMenuBarPopover("escape");
  });
  window.on("closed", () => {
    clearMenuBarPopoverBlurTimer();
    if (menuBarPopoverWindow === window) menuBarPopoverWindow = null;
  });
  menuBarPopoverWindow = window;
  return window;
}

function showMenuBarPopover() {
  const window = ensureMenuBarPopoverWindow();
  menuBarPopoverShownAt = Date.now();
  positionMenuBarPopoverWindow(window);
  const html = menuBarPopoverHTML();
  window.loadURL(`data:text/html;base64,${Buffer.from(html).toString("base64")}`);
  const showLoadedPopover = () => {
    if (window.isDestroyed()) return;
    menuBarPopoverShownAt = Date.now();
    positionMenuBarPopoverWindow(window);
    window.show();
    window.focus();
  };
  window.once("ready-to-show", showLoadedPopover);
  setTimeout(() => {
    if (!window.isDestroyed() && !window.isVisible()) showLoadedPopover();
  }, 160);
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
      if (!window.isDestroyed()) window.webContents.send("openassist:menu-bar-command", command);
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
  }, 120);
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
  window.webContents.send("openassist:sidebar-blur-collapse", {
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

function applyWindowMode(window: BrowserWindow, mode: "full" | "sidebar", sidebarOpen = true, sidebarEdge: "left" | "right" = "right") {
  const previousWindowMode = currentWindowMode;
  const previousSidebarOpen = currentSidebarOpen;
  const previousSidebarEdge = currentSidebarEdge;
  currentWindowMode = mode;
  currentSidebarOpen = mode === "sidebar" ? sidebarOpen : true;
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
    window.setFocusable(sidebarOpen);
    const keepOnTop = !sidebarOpen || sidebarPinnedPreference;
    window.setAlwaysOnTop(keepOnTop, "floating");
    if (!window.isVisibleOnAllWorkspaces()) {
      window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
    }
    window.setHasShadow(sidebarOpen);
    window.setBackgroundColor("#00000000");
    if (process.platform === "darwin") window.setVibrancy(null);
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

  window.setFocusable(true);
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
  window.webContents.send("openassist:toggle-sidebar-shortcut");
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
    correction: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M21 7v6h-6"/><path d="M3 17v-6h6"/><path d="M7 7a7 7 0 0 1 11 2"/><path d="M17 17a7 7 0 0 1-11-2"/></svg>'
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
	    const floor = 0.06;
	    if (level <= floor) return 0;
	    return Math.pow(Math.min(1, (level - floor) / (1 - floor)), 0.68);
	  }
	  const MIN_BAR_HEIGHT = 3;
	  const MAX_BAR_HEIGHT = 20;
	  // Asymmetric attack/decay measured in seconds — bars rise fast (attack)
	  // and fall slow (release), like a VU meter / classic audio-level visualizer.
	  const BAR_ATTACK = 0.06;
	  const BAR_RELEASE = 0.34;
	  function paintBar(node, value) {
	    const clamped = Math.max(0, Math.min(1, value));
	    node.style.height = (MIN_BAR_HEIGHT + clamped * (MAX_BAR_HEIGHT - MIN_BAR_HEIGHT)).toFixed(2) + "px";
	    node.style.opacity = (0.88 + clamped * 0.12).toFixed(3);
	  }
	  function tickWaveform(now) {
	    if (!waveformLoopActive || !barNodes.length) {
	      waveformLoopActive = false;
	      return;
	    }
	    const dt = lastFrameTime ? Math.min(0.1, (now - lastFrameTime) / 1000) : 0.016;
	    lastFrameTime = now;
	    const energy = voiceEnergy(currentLevel);
	    let stillMoving = energy > 0.001;
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
                : "listening";
    const tone = rawStatus === "error" || rawStatus === "unsupported" ? "error" : (payload && payload.tone) || "success";
    const level = clampLevel(payload && payload.level);
    document.documentElement.dataset.status = status;
    document.documentElement.dataset.tone = tone;
    document.documentElement.dataset.theme = themeKey(payload && payload.theme);
    document.documentElement.dataset.colorTheme = optionKey(payload && payload.colorTheme);
    document.documentElement.dataset.chromeStyle = optionKey(payload && payload.chromeStyle);
	    document.documentElement.dataset.speaking = level > 0.10 ? "true" : "false";
    if (status === "listening" && renderedStatus === "listening" && renderedTheme === document.documentElement.dataset.theme && root.firstChild) {
      applyWaveformLevel(level);
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
      spark.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="width: 14px; height: 14px;"><path d="m12 3-1.912 5.813a2 2 0 0 1-1.275 1.275L3 12l5.813 1.912a2 2 0 0 1 1.275 1.275L12 21l1.912-5.813a2 2 0 0 1 1.275-1.275L21 12l-5.813-1.912a2 2 0 0 1-1.275-1.275L12 3Z"/></svg>';

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
      spark.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="width: 14px; height: 14px;"><path d="m12 3-1.912 5.813a2 2 0 0 1-1.275 1.275L3 12l5.813 1.912a2 2 0 0 1 1.275 1.275L12 21l1.912-5.813a2 2 0 0 1 1.275-1.275L21 12l-5.813-1.912a2 2 0 0 1-1.275-1.275L12 3Z"/></svg>';

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
  const { bounds } = display;
  const y = bounds.y + bounds.height - HUD_DOCK_RESERVE - size.height;
  const useAnim = process.platform === "darwin" && (payload.status === "analysis-result" || payload.status === "analyzing");
  window.setBounds({
    x: Math.round(bounds.x + (bounds.width - size.width) / 2),
    y: Math.round(y),
    width: size.width,
    height: size.height
  }, useAnim);
}

function ensureVoiceHUDWindow() {
  if (voiceHUDWindow && !voiceHUDWindow.isDestroyed()) return voiceHUDWindow;
  voiceHUDReady = false;
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
      sandbox: false
    }
  });
  window.setIgnoreMouseEvents(false);
  window.setAlwaysOnTop(true, "status");
  if (process.platform === "darwin") {
    window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
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
    voiceHUDWindow?.hide();
    voiceHUDAutoHideTimer = null;
  }, status === "message" ? 2400 : 4200);
}

function storedVoiceHUDPayload(payload: VoiceHUDPayload) {
  const { suppressForAppFocus: _suppressForAppFocus, ...storedPayload } = payload;
  return storedPayload;
}

function shouldSuppressFloatingVoiceHUD(payload: VoiceHUDPayload) {
  if (payload.suppressForAppFocus) return true;
  return false;
}

function isInteractiveVoiceHUDStatus(status: VoiceHUDPayload["status"]) {
  return status === "correction" || status === "analysis-result" || status === "analyzing-input";
}

function activeVoiceCaptureHUDPayload(): VoiceHUDPayload | null {
  if (!voiceCapture) return null;
  return {
    visible: true,
    status: voiceCapture.processing ? "processing" : "listening",
    level: voiceCapture.processing ? undefined : menuBarVoiceLevel
  };
}

async function updateVoiceHUD(payload: VoiceHUDPayload) {
  rememberVoiceHUDAppearance(payload);
  const isLevelOnlyUpdate = payload.level !== undefined
    && payload.visible === undefined
    && payload.status === undefined
    && payload.text === undefined
    && payload.theme === undefined
    && payload.colorTheme === undefined
    && payload.chromeStyle === undefined
    && payload.tone === undefined
    && payload.source === undefined
    && payload.replacement === undefined;
  if (payload.visible === false || payload.status === "idle") {
    const activeCapturePayload = activeVoiceCaptureHUDPayload();
    if (activeCapturePayload) {
      updateMenuBarVoiceStatus(activeCapturePayload);
      if (payload.suppressForAppFocus) {
        clearVoiceHUDAutoHide();
        pendingVoiceHUDPayload = storedVoiceHUDPayload(activeCapturePayload);
        voiceHUDWindow?.hide();
        return { ok: true, visible: false };
      }
      debugLog("voice HUD hide ignored while native capture is active");
      return updateVoiceHUD(activeCapturePayload);
    }
    clearVoiceHUDAutoHide();
    pendingVoiceHUDPayload = null;
    voiceHUDWindow?.hide();
    updateMenuBarVoiceStatus(payload);
    return { ok: true, visible: false };
  }
  if (!isLevelOnlyUpdate) clearVoiceHUDAutoHide();
  const nextPayload = {
    ...lastVoiceHUDAppearance,
    ...(pendingVoiceHUDPayload ?? {}),
    ...payload
  };
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
    );
  if (!shouldShow) {
    pendingVoiceHUDPayload = null;
    voiceHUDWindow?.hide();
    updateMenuBarVoiceStatus({ visible: false, status: "idle" });
    return { ok: true, visible: false };
  }
  if (shouldSuppressFloatingVoiceHUD(nextPayload)) {
    clearVoiceHUDAutoHide();
    pendingVoiceHUDPayload = storedVoiceHUDPayload(nextPayload);
    voiceHUDWindow?.hide();
    updateMenuBarVoiceStatus(nextPayload);
    return { ok: true, visible: false };
  }
  const window = ensureVoiceHUDWindow();
  pendingVoiceHUDPayload = storedVoiceHUDPayload(nextPayload);
  updateMenuBarVoiceStatus(nextPayload);
  if (!isLevelOnlyUpdate) {
    positionVoiceHUDWindow(window, nextPayload);
    const interactiveHUD = isInteractiveVoiceHUDStatus(nextPayload.status);
    window.setIgnoreMouseEvents(!interactiveHUD);
    window.setFocusable(interactiveHUD);
    if (nextPayload.status === "analyzing-input") {
      window.show();
      window.focus();
      window.moveTop();
    } else {
      window.showInactive();
    }
  }
  if (!voiceHUDReady) return { ok: true, visible: true, pending: true };
  await window.webContents.executeJavaScript(
    `window.updateOpenAssistVoiceHUD(${JSON.stringify({
      status: nextPayload.status,
      text: nextPayload.text ?? "",
      theme: nextPayload.theme ?? "Vibrant Spectrum",
      colorTheme: nextPayload.colorTheme ?? "Ocean",
      chromeStyle: nextPayload.chromeStyle ?? "Glass (High Contrast)",
      level: nextPayload.level ?? 0,
      tone: nextPayload.tone ?? (nextPayload.status === "error" || nextPayload.status === "unsupported" ? "error" : "success"),
      source: nextPayload.source ?? "",
      replacement: nextPayload.replacement ?? "",
      previewDataURL: nextPayload.previewDataURL ?? ""
    })})`
  );
  if (!isLevelOnlyUpdate && isInteractiveVoiceHUDStatus(nextPayload.status)) {
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

function showAssistantForVoiceShortcut() {
  const window = mainWindow;
  if (!window) {
    createMainWindow();
    return;
  }
  if (!window.isVisible()) window.show();
  window.focus();
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
  if (target === "assistantLiveVoice") {
    showAssistantForVoiceShortcut();
  } else if (!mainWindow) {
    createMainWindow({ initiallyHidden: isVoiceTranscriptionShortcut });
  }
  const window = mainWindow;
  if (!window || window.isDestroyed()) return;
  const sendShortcut = () => {
    if (!window.isDestroyed()) window.webContents.send("openassist:voice-shortcut", target, phase);
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
    const state = await (await openAssistBridge()).loadOpenAssistAppState();
    registerConfiguredShortcuts(state.settings);
  } catch (error) {
    debugLog(`shortcut refresh failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
  }
}

let lastCapturedImageBuffer: Buffer | null = null;
let lastCapturedScreenRect: ScreenRect | null = null;
let lastCapturedPreviewDataURL = "";
let lastScreenAnalysisReferenceImages: Array<{ name: string; data: Buffer; mimeType: string; previewDataURL: string }> = [];
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
  "neon-lagoon": ["#74d5ff", "#54e3da", "#56edb2", "#91ef78"],
  "sunset-candy": ["#6e8dff", "#d45a8b", "#ef4b55", "#ebb934"],
  "cosmic-pop": ["#58a9ff", "#945fe3", "#eb4b82", "#f27d3a"],
  "mint-blush": ["#6fa7ff", "#c175b7", "#ef6f7f", "#5bca95"]
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
  cachedScreenSnipTheme = "prism";
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
  if (userKey && userKey !== "match-voice-hud" && screenSnipPalettes[userKey] && screenSnipPalettes[userKey].length) {
    return screenSnipPalettes[userKey];
  }
  const fallbackKey = normalizePaletteKey(lastVoiceHUDAppearance.theme) || "vibrant-spectrum";
  return screenSnipPalettes[fallbackKey] ?? screenSnipPalettes["vibrant-spectrum"];
}

function screenAnalysisAppThemePalette(theme?: string) {
  const themeKey = normalizePaletteKey(theme || lastVoiceHUDAppearance.colorTheme || "Ocean");
  return screenAnalysisAppThemePalettes[themeKey] ?? screenAnalysisAppThemePalettes.ocean;
}

function listScreenSnipPresets() {
  return Object.entries(screenSnipPalettes).map(([key, colors]) => ({
    key,
    label: key === "match-voice-hud"
      ? "Match Voice HUD"
      : key.split("-").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" "),
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
  padding: 8px 12px;
  border-radius: 999px;
  background: rgba(17, 20, 26, 0.86);
  border: 1px solid rgba(255,255,255,0.12);
  color: rgba(255,255,255,0.86);
  font-size: 12px;
  font-weight: 720;
  box-shadow: 0 14px 34px rgba(0,0,0,0.32);
  pointer-events: none;
}
.box {
  position: fixed;
  display: none;
  border-radius: 12px;
  border: 1px solid color-mix(in srgb, var(--c1) 55%, white 10%);
  background: transparent;
  pointer-events: none;
  box-shadow:
    0 0 0 9999px rgba(0, 0, 0, 0.11),
    0 0 6px color-mix(in srgb, var(--c1) 18%, transparent),
    0 0 14px color-mix(in srgb, var(--c2) 10%, transparent);
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
  max-height: 380px;
  border-radius: 16px;
  background: rgba(20, 22, 28, 0.97);
  border: 1px solid color-mix(in srgb, var(--theme-accent) 18%, rgba(255,255,255,0.10));
  box-shadow:
    0 18px 56px rgba(0,0,0,0.50),
    0 0 18px color-mix(in srgb, var(--theme-accent) 10%, transparent);
  padding: 12px 12px 10px;
  display: flex;
  flex-direction: column;
  gap: 10px;
  -webkit-font-smoothing: antialiased;
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
  box-shadow: 0 0 14px color-mix(in srgb, var(--theme-accent) 18%, transparent);
}
.screenshot-preview img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
  pointer-events: none;
}
.composer-col {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 8px;
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
  background: rgba(255,255,255,0.06);
  border: 1px solid rgba(255,255,255,0.13);
  border-radius: 12px;
  padding: 4px 4px 4px 6px;
  transition: border-color 0.15s ease, background 0.15s ease;
}
.composer:focus-within {
  border-color: color-mix(in srgb, var(--theme-accent) 45%, white 10%);
  background: rgba(255,255,255,0.08);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--theme-accent) 12%, transparent);
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
.composer input::placeholder { color: rgba(255,255,255,0.42); }
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
.icon-btn:hover { background: rgba(255,255,255,0.08); color: rgba(255,255,255,0.95); }
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
  border-radius: 16px;
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
  padding-right: 4px;
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
  root.innerHTML = "";
  const card = document.createElement("div");
  card.className = "panel";
  card.style.left = panel.x + "px";
  card.style.top = panel.y + "px";
  card.style.width = (panel.width || 520) + "px";
  const header = document.createElement("div");
  header.className = "header";
  const spark = document.createElement("span");
  spark.className = "spark";
  spark.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 14 9l6 2-6 2-2 6-2-6-6-2 6-2 2-6z"/></svg>';
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
    addImage.title = "Attach reference image";
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

    function renderReferences(items) {
      referenceRow.innerHTML = "";
      (items || []).forEach((item, index) => {
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
      hint.textContent = items && items.length
        ? "Reference image added. Press Enter to send."
        : "Press Enter to send";
      hint.style.color = "rgba(255,255,255,0.40)";
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
    addImage.addEventListener("click", () => {
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
    composerCol.append(composer, referenceRow, hint);
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
    width: 520,
    height: 150,
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
    title: "Open Assist Screen Analysis",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      devTools: enableDevTools,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });
  window.setAlwaysOnTop(true, "status");
  if (process.platform === "darwin") {
    window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  }
  window.on("closed", () => {
    if (screenAnalysisWindow === window) screenAnalysisWindow = null;
    screenAnalysisWindowReady = false;
    stopAssistantVoiceOutputForSessionEnd("screen analysis HUD closed");
    restoreMainWindowAfterScreenAnalysis("screen analysis HUD closed");
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
      sandbox: false
    }
  });
  window.setIgnoreMouseEvents(true, { forward: true });
  window.setAlwaysOnTop(true, "status");
  if (process.platform === "darwin") {
    window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
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
}) {
  const window = ensureScreenAnalysisWindow();
  const frameWindow = ensureScreenAnalysisFrameWindow();
  const colors = screenAnalysisPalette(lastVoiceHUDAppearance.theme);
  const themeColors = screenAnalysisAppThemePalette(lastVoiceHUDAppearance.colorTheme);
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
  const panel = screenAnalysisPanel(payload.rect, panelWidth, panelHeight, payload.status);
  debugLog(`screen analysis overlay status=${payload.status} rect=${JSON.stringify(payload.rect)} frame=${JSON.stringify(frameBounds)} panel=${JSON.stringify(panel)} preview=${lastCapturedPreviewDataURL ? "yes" : "no"}`);
  window.setBounds(panel, false);
  screenAnalysisPanelExpandedHeight = panel.height;
  const viewPayload = {
    ...payload,
    panel: { x: 0, y: 0, width: panel.width },
    colors,
    themeColors
  };
  if (!window.isVisible()) {
    window.show();
  }
  if (payload.status === "prompt") {
    window.focus();
  } else {
    window.showInactive();
  }
  window.moveTop();
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
        sandbox: false
      }
    });
    window.setAlwaysOnTop(true, "screen-saver");
    if (process.platform === "darwin") {
      window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
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
  const referenceImages = lastScreenAnalysisReferenceImages.map((image) => ({
    name: image.name,
    data: image.data,
    mimeType: image.mimeType
  }));
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

  if (rect) {
    void updateScreenAnalysisOverlay({
      status: "analyzing",
      rect,
      previewDataURL: lastCapturedPreviewDataURL,
      text: "Analyzing the selected area..."
    });
  }

  try {
    const finalResult = await bridge.analyzeScreenWithCodex(imageBuffer, instruction, referenceImages, (text) => {
      accumulatedText = text;
      if (!text.trim()) return;
      if (rect) {
        void updateScreenAnalysisOverlay({
          status: "analyzing",
          rect,
          previewDataURL: lastCapturedPreviewDataURL,
          text: "Analyzing the selected area...",
          resultText: text
        });
      }
    });
    accumulatedText = accumulatedText || finalResult.text;
    generatedImages = finalResult.images || [];
    if (accumulatedText.trim() || generatedImages.length) {
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
  const imageBuffer = lastCapturedImageBuffer;
  lastCapturedImageBuffer = null;
  await runScreenAnalysis(imageBuffer, instruction, options);
  return { ok: true };
}

async function cancelScreenAnalysisPrompt() {
  debugLog("screen analysis prompt cancelled");
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
  screenAnalysisFrameVisible = true;
  screenSelectionWindow?.close();
  screenSelectionWindow = null;
  screenAnalysisFrameWindow?.hide();
  screenAnalysisWindow?.hide();
  restoreMainWindowAfterScreenAnalysis("screen analysis cancelled");
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
  } catch (error) {
    debugLog(`Screen analysis capture error: ${error}`);
    restoreMainWindowAfterScreenAnalysis("screen analysis capture failed");
    if (error instanceof Error && error.message === "Screen analysis cancelled.") {
      return;
    }
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
      sandbox: false
    }
  });
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
  setTimeout(showWindow, 2500);
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
  });

  if (isDev && process.env.VITE_DEV_SERVER_URL) {
    debugLog(`loadURL ${process.env.VITE_DEV_SERVER_URL}`);
    window.loadURL(process.env.VITE_DEV_SERVER_URL);
  } else {
    const indexPath = path.join(__dirname, "../dist-renderer/index.html");
    debugLog(`loadFile ${indexPath} exists=${fs.existsSync(indexPath)}`);
    window.loadFile(indexPath);
  }
  maybeOpenDevTools(window, "main");

  mainWindow = window;
  debugLog("createMainWindow complete");
  return window;
}

function loadRendererWindow(window: BrowserWindow, query?: Record<string, string>) {
  if (isDev && process.env.VITE_DEV_SERVER_URL) {
    const url = new URL(process.env.VITE_DEV_SERVER_URL);
    for (const [key, value] of Object.entries(query ?? {})) url.searchParams.set(key, value);
    debugLog(`loadURL ${url.toString()}`);
    window.loadURL(url.toString());
    return;
  }
  const indexPath = path.join(__dirname, "../dist-renderer/index.html");
  debugLog(`loadFile ${indexPath} exists=${fs.existsSync(indexPath)} query=${JSON.stringify(query ?? {})}`);
  window.loadFile(indexPath, query ? { query } : undefined);
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
      sandbox: false
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
      sandbox: false
    }
  });
  window.accessibleTitle = "Open Assist Settings";
  if (!isAccessibilityTestMode && process.platform === "darwin") {
    window.setBackgroundColor("#00000000");
    window.setVibrancy("menu");
  }
  window.on("closed", () => {
    if (settingsWindow === window) settingsWindow = null;
  });
  loadRendererWindow(window, { window: "settings", section: normalizedSettingsSection(section) });
  maybeOpenDevTools(window, "settings");
  settingsWindow = window;
  return window;
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
      window.webContents.send("openassist:settings-section", targetSection);
    });
  } else {
    window.webContents.send("openassist:settings-section", targetSection);
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
  const snapshot = await currentFrontmostApplicationSnapshot();
  if (snapshot && !isOwnApplicationSnapshot(snapshot)) {
    lastExternalApplication = snapshot;
  }
  return snapshot;
}

function startFrontmostApplicationTracker() {
  if (process.platform !== "darwin" || frontmostTrackerTimer) return;
  void refreshFrontmostApplicationSnapshot();
  frontmostTrackerTimer = setInterval(() => {
    void refreshFrontmostApplicationSnapshot();
  }, 1200);
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

async function insertTranscriptText(text: string): Promise<TranscriptInsertionResult> {
  const trimmed = typeof text === "string" ? text.trim() : "";
  if (!trimmed) return { ok: false, result: "empty" };

  const frontmost = await refreshFrontmostApplicationSnapshot();
  const target = frontmost && !isOwnApplicationSnapshot(frontmost) ? frontmost : lastExternalApplication;
  const resultTarget = target ?? undefined;

  if (target) {
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

function workspaceRootFromRequest(requestedPath?: unknown) {
  const rawPath = typeof requestedPath === "string" ? requestedPath.trim() : "";
  if (!rawPath) return openAssistRepoRoot();
  const expandedPath = rawPath.startsWith("~")
    ? path.join(app.getPath("home"), rawPath.slice(1))
    : rawPath;
  const resolvedPath = path.resolve(expandedPath);
  if (!fs.existsSync(resolvedPath)) return openAssistRepoRoot();
  try {
    const stat = fs.statSync(resolvedPath);
    return stat.isDirectory() ? resolvedPath : path.dirname(resolvedPath);
  } catch {
    return openAssistRepoRoot();
  }
}

async function openWorkspaceLaunchTarget(targetID: string, workspaceRootPath?: unknown) {
  const target = workspaceLaunchTargets.find((item) => item.id === targetID);
  if (!target) return { ok: false, error: "Unknown workspace target." };
  const workspaceRoot = workspaceRootFromRequest(workspaceRootPath);
  if (target.launchStyle === "revealInFinder") {
    const error = await shell.openPath(workspaceRoot);
    return error ? { ok: false, error, path: workspaceRoot } : { ok: true, path: workspaceRoot };
  }

  const applicationPath = applicationPathForTarget(target);
  if (!applicationPath && !target.bundleIdentifiers[0]) {
    return { ok: false, error: `${target.title} is not installed on this Mac.` };
  }

  const args = applicationPath
    ? ["-a", target.appNames[0], workspaceRoot]
    : ["-b", target.bundleIdentifiers[0], workspaceRoot];
  const child = spawn("open", args, { detached: true, stdio: "ignore" });
  child.unref();
  return { ok: true, path: workspaceRoot };
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

async function ensureAppleSpeechHelper() {
  const sourcePath = appleSpeechHelperSourcePath();
  if (!sourcePath) throw new Error("Apple Speech helper source was not found.");
  const infoPlistPath = appleSpeechHelperInfoPlistPath();
  if (!infoPlistPath) throw new Error("Apple Speech helper Info.plist was not found.");
  const helperDirectory = path.join(app.getPath("userData"), "helpers");
  fs.mkdirSync(helperDirectory, { recursive: true });
  const helperAppPath = path.join(helperDirectory, "Open Assist Speech Helper.app");
  const contentsPath = path.join(helperAppPath, "Contents");
  const macOSPath = path.join(contentsPath, "MacOS");
  const infoPlistOutputPath = path.join(contentsPath, "Info.plist");
  const helperPath = path.join(macOSPath, "apple-speech-helper");
  const sourceStat = fs.statSync(sourcePath);
  const plistStat = fs.statSync(infoPlistPath);
  const helperStat = fs.existsSync(helperPath) ? fs.statSync(helperPath) : null;
  const plistOutputStat = fs.existsSync(infoPlistOutputPath) ? fs.statSync(infoPlistOutputPath) : null;
  if (!helperStat || !plistOutputStat || helperStat.mtimeMs < sourceStat.mtimeMs || plistOutputStat.mtimeMs < plistStat.mtimeMs) {
    fs.mkdirSync(macOSPath, { recursive: true });
    fs.copyFileSync(infoPlistPath, infoPlistOutputPath);
    await runProcess("/usr/bin/swiftc", [
      "-framework",
      "AVFoundation",
      "-framework",
      "CoreAudio",
      "-framework",
      "Speech",
      sourcePath,
      "-o",
      helperPath
    ]);
    fs.chmodSync(helperPath, 0o755);
    try {
      await runProcess("/usr/bin/codesign", ["--force", "--sign", "-", helperAppPath]);
    } catch {
      // Ad-hoc signing is helpful for TCC, but the helper can still run unsigned in dev.
    }
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

function normalizedVoiceLevel(value: unknown) {
  const level = Number(value);
  if (!Number.isFinite(level)) return null;
  const clamped = Math.max(0, Math.min(1, level));
  const noiseFloor = 0.15;
  if (clamped <= noiseFloor) return 0;
  return Math.pow((clamped - noiseFloor) / (1 - noiseFloor), 0.78);
}

function smoothedVoiceHUDLevel(level: number) {
  const smoothing = level > smoothedVoiceLevel ? 0.45 : 0.14;
  smoothedVoiceLevel += (level - smoothedVoiceLevel) * smoothing;
  if (smoothedVoiceLevel < 0.03) return 0;
  return Math.max(0, Math.min(1, smoothedVoiceLevel));
}

function stopVoiceLevelPolling() {
  if (voiceHUDLevelTimer) {
    clearInterval(voiceHUDLevelTimer);
    voiceHUDLevelTimer = null;
  }
  voiceHUDLevelMtime = 0;
  smoothedVoiceLevel = 0;
}

function voiceStartupTimeoutMessage(sessionDirectory: string, fallback: string) {
  const status = readJsonFile<{ message?: string }>(path.join(sessionDirectory, "status.json"));
  const message = status?.message?.trim();
  return message ? `${message} Allow it in the macOS prompt, then try again.` : fallback;
}

function requestVoiceHelperStop(sessionDirectory: string) {
  try {
    fs.writeFileSync(path.join(sessionDirectory, "stop"), "1", "utf8");
  } catch {
    // Best effort. The helper may already be gone.
  }
}

function clearMismatchedVoiceCapture(engine: NonNullable<typeof voiceCapture>["engine"]) {
  if (!voiceCapture || voiceCapture.engine === engine) return;
  requestVoiceHelperStop(voiceCapture.sessionDirectory);
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
  const child = spawn(helperPath, args, { detached: true, stdio: "ignore" });
  child.on("error", (error) => {
    debugLog(`voice helper launch failed: ${error instanceof Error ? error.message : String(error)}`);
  });
  child.unref();
}

function startVoiceLevelPolling(sessionDirectory: string) {
  stopVoiceLevelPolling();
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
      } else {
        updateMenuBarVoiceStatus({ visible: true, status: "listening", level });
      }
    } catch {
      // The helper creates this file only after the microphone starts producing samples.
    }
  }, 45);
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
  clearMismatchedVoiceCapture("appleSpeech");
  if (voiceCapture) {
    return { ok: true };
  }

  const helperAppPath = await ensureAppleSpeechHelper();
  const sessionDirectory = path.join(app.getPath("userData"), "voice-captures", `${Date.now()}-${Math.random().toString(16).slice(2)}`);
  fs.mkdirSync(sessionDirectory, { recursive: true });
  voiceCapture = { sessionDirectory, appPath: helperAppPath, engine: "appleSpeech", voiceOptions: options };
  launchVoiceHelperApp(helperAppPath, sessionDirectory, "speech", options);
  const ready = await waitForVoiceFile(sessionDirectory, ["ready.json", "error.json"], 12000);
  if (!ready) {
    requestVoiceHelperStop(sessionDirectory);
    voiceCapture = null;
    return { ok: false, error: voiceStartupTimeoutMessage(sessionDirectory, "Voice input did not become ready in time.") };
  }
  if (ready.name === "error.json") {
    voiceCapture = null;
    return { ok: false, error: ready.payload.message ?? "Voice input failed." };
  }
  startVoiceLevelPolling(sessionDirectory);
  playDictationFeedbackSound("startListening", options);
  return { ok: true };
}

async function stopAppleVoiceInput() {
  const captureState = voiceCapture;
  if (!captureState) return { ok: false, text: "", error: "Voice input is not running." };
  if (captureState.engine !== "appleSpeech") return { ok: false, text: "", error: "Apple Speech voice input is not running." };
  if (captureState.processing) return { ok: false, text: "", error: "Voice transcription is already processing." };
  captureState.processing = true;
  playDictationFeedbackSound("stopListening", captureState.voiceOptions);
  scheduleProcessingFeedbackSound(captureState);
  try {
    fs.writeFileSync(path.join(captureState.sessionDirectory, "stop"), "1", "utf8");
    const finished = await waitForVoiceFile(captureState.sessionDirectory, ["final.json", "error.json"], 9000);
    if (!finished) return { ok: false, text: "", error: "Voice input did not finish in time." };
    if (finished.name === "error.json") return { ok: false, text: "", error: finished.payload.message ?? "Voice input failed." };
    return {
      ok: true,
      text: (finished.payload.text ?? "").trim()
    };
  } finally {
    if (voiceCapture === captureState) voiceCapture = null;
    stopVoiceLevelPolling();
    updateMenuBarVoiceStatus({ visible: false, status: "idle" });
  }
}

function prewarmCloudVoiceTranscription(configuration?: VoiceStartOptions) {
  const provider = configuration?.cloudTranscriptionProvider || "OpenAI";
  if (provider !== "ChatGPT / Codex Session") return;
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
  const sessionDirectory = path.join(app.getPath("userData"), "voice-captures", `${Date.now()}-${Math.random().toString(16).slice(2)}`);
  fs.mkdirSync(sessionDirectory, { recursive: true });
  voiceCapture = { sessionDirectory, appPath: helperAppPath, engine: "cloudProviders", voiceOptions: configuration };
  launchVoiceHelperApp(helperAppPath, sessionDirectory, "recording", configuration);
  const ready = await waitForVoiceFile(sessionDirectory, ["ready.json", "error.json"], 12000);
  if (!ready) {
    requestVoiceHelperStop(sessionDirectory);
    voiceCapture = null;
    return { ok: false, error: voiceStartupTimeoutMessage(sessionDirectory, "Voice recording did not become ready in time.") };
  }
  if (ready.name === "error.json") {
    voiceCapture = null;
    return { ok: false, error: ready.payload.message ?? "Voice recording failed." };
  }
  startVoiceLevelPolling(sessionDirectory);
  playDictationFeedbackSound("startListening", configuration);
  return { ok: true };
}

async function stopCloudVoiceInput() {
  const captureState = voiceCapture;
  if (!captureState) return { ok: false, text: "", error: "Voice input is not running." };
  if (captureState.engine !== "cloudProviders") return { ok: false, text: "", error: "Cloud voice input is not running." };
  if (captureState.processing) return { ok: false, text: "", error: "Voice transcription is already processing." };
  captureState.processing = true;
  playDictationFeedbackSound("stopListening", captureState.voiceOptions);
  scheduleProcessingFeedbackSound(captureState);
  try {
    fs.writeFileSync(path.join(captureState.sessionDirectory, "stop"), "1", "utf8");
    const finished = await waitForVoiceFile(captureState.sessionDirectory, ["final.json", "error.json"], 15000);
    if (!finished) return { ok: false, text: "", error: "Voice recording did not finish in time." };
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
    return { ok: true, text: text.trim() };
  } catch (error) {
    return {
      ok: false,
      text: "",
      error: error instanceof Error ? error.message : "Cloud transcription failed."
    };
  } finally {
    if (voiceCapture === captureState) voiceCapture = null;
    stopVoiceLevelPolling();
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

async function startWhisperVoiceInput(configuration?: VoiceStartOptions) {
  if (process.platform !== "darwin") {
    return { ok: false, error: "whisper.cpp voice input is only available on macOS in this Electron port." };
  }
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
  const sessionDirectory = path.join(app.getPath("userData"), "voice-captures", `${Date.now()}-${Math.random().toString(16).slice(2)}`);
  const modelID = resolvedModel.modelID;
  const coreMLDirectoryPath = whisperCoreMLDirectoryPath(modelID);
  const shouldForceCPUForStability = modelID.startsWith("small") || modelID.startsWith("medium");
  const useCoreML = Boolean(configuration.whisperUseCoreML)
    && fs.existsSync(coreMLDirectoryPath)
    && !shouldForceCPUForStability;
  fs.mkdirSync(sessionDirectory, { recursive: true });
  voiceCapture = {
    sessionDirectory,
    appPath: helperAppPath,
    engine: "whisperCpp",
    voiceOptions: configuration,
    whisperModelID: modelID,
    whisperModelPath: resolvedModel.modelPath,
    whisperUseCoreML: useCoreML
  };
  launchVoiceHelperApp(helperAppPath, sessionDirectory, "recording", configuration);
  const ready = await waitForVoiceFile(sessionDirectory, ["ready.json", "error.json"], 12000);
  if (!ready) {
    requestVoiceHelperStop(sessionDirectory);
    voiceCapture = null;
    return { ok: false, error: voiceStartupTimeoutMessage(sessionDirectory, "whisper.cpp voice recording did not become ready in time.") };
  }
  if (ready.name === "error.json") {
    voiceCapture = null;
    return { ok: false, error: ready.payload.message ?? "whisper.cpp voice recording failed." };
  }
  startVoiceLevelPolling(sessionDirectory);
  playDictationFeedbackSound("startListening", configuration);
  return { ok: true, modelID, useCoreML };
}

async function stopWhisperVoiceInput() {
  const captureState = voiceCapture;
  if (!captureState) return { ok: false, text: "", error: "Voice input is not running." };
  if (captureState.engine !== "whisperCpp") return { ok: false, text: "", error: "whisper.cpp voice input is not running." };
  if (captureState.processing) return { ok: false, text: "", error: "Voice transcription is already processing." };
  captureState.processing = true;
  playDictationFeedbackSound("stopListening", captureState.voiceOptions);
  scheduleProcessingFeedbackSound(captureState);
  try {
    fs.writeFileSync(path.join(captureState.sessionDirectory, "stop"), "1", "utf8");
    const finished = await waitForVoiceFile(captureState.sessionDirectory, ["final.json", "error.json"], 15000);
    if (!finished) return { ok: false, text: "", error: "whisper.cpp voice recording did not finish in time." };
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
    return { ok: true, text };
  } catch (error) {
    return {
      ok: false,
      text: "",
      error: error instanceof Error ? error.message : "whisper.cpp transcription failed."
    };
  } finally {
    if (voiceCapture === captureState) voiceCapture = null;
    stopVoiceLevelPolling();
    updateMenuBarVoiceStatus({ visible: false, status: "idle" });
  }
}

async function startConfiguredVoiceInput(options?: VoiceStartOptions) {
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
    .then((bridge) => bridge.prewarmAssistantVoiceOutput())
    .catch((error) => {
      debugLog(`assistant voice prewarm failed: ${error instanceof Error ? error.message : String(error)}`);
    });
  session.defaultSession.setPermissionRequestHandler((_webContents, permission, callback, details) => {
    const requestDetails = details as { mediaTypes?: string[] };
    const mediaTypes = Array.isArray(requestDetails.mediaTypes) ? requestDetails.mediaTypes : [];
    callback(permission === "media" && mediaTypes.includes("audio"));
  });

  ipcMain.handle("open-external", async (_event, url: string) => {
    if (typeof url === "string" && /^(https?:\/\/|x-apple\.systempreferences:)/.test(url)) {
      await shell.openExternal(url);
    }
  });
  ipcMain.handle("openassist:workspace-launch-targets", async () => workspaceLaunchTargetSnapshots());
  ipcMain.handle("openassist:read-clipboard-text", async () => clipboard.readText());
  ipcMain.handle("openassist:write-clipboard-text", async (_event, text: string) => {
    clipboard.writeText(String(text ?? ""));
    return { ok: true };
  });
  ipcMain.handle("openassist:insert-transcript-text", async (_event, text: string) => insertTranscriptText(text));
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
  ipcMain.handle("openassist:open-target", async (_event, target: string, workspaceRootPath?: string | null) => {
    if (target.startsWith("workspace:")) {
      return openWorkspaceLaunchTarget(target.slice("workspace:".length), workspaceRootPath);
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
  ipcMain.handle("openassist:list-provider-models", async (_event, backend: string) => (await openAssistBridge()).listProviderModels(backend));
  ipcMain.handle("openassist:load-thread", async (_event, threadID: string) => (await openAssistBridge()).loadThreadMessages(threadID));
  ipcMain.handle("openassist:load-thread-note", async (_event, threadID: string) => (await openAssistBridge()).loadThreadNoteWorkspace(threadID));
  ipcMain.handle("openassist:create-thread-note", async (_event, threadID: string, title?: string) =>
    (await openAssistBridge()).createThreadNote(threadID, title)
  );
  ipcMain.handle("openassist:save-thread-note", async (_event, threadID: string, noteID: string | undefined, markdown: string) =>
    (await openAssistBridge()).saveThreadNote(threadID, noteID, markdown)
  );
  ipcMain.handle("openassist:select-thread-note", async (_event, threadID: string, noteID: string) =>
    (await openAssistBridge()).selectThreadNote(threadID, noteID)
  );
  ipcMain.handle("openassist:load-thread-memory", async (_event, threadID: string) => (await openAssistBridge()).loadThreadMemory(threadID));
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
  ipcMain.handle("openassist:read-note-image", async (_event, notePath: string, imageSrc: string) =>
    (await openAssistBridge()).readNoteImageDataURL(notePath, imageSrc)
  );
  ipcMain.handle("openassist:create-note", async (_event, projectID: string) => (await openAssistBridge()).createProjectNote(projectID));
  ipcMain.handle("openassist:save-note", async (_event, projectID: string, noteID: string, markdown: string) =>
    (await openAssistBridge()).saveProjectNote(projectID, noteID, markdown)
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
  ipcMain.handle("openassist:update-setting", async (_event, key: string, value: boolean | string | number) =>
    (await openAssistBridge()).updateSetting(key as Parameters<OpenAssistBridge["updateSetting"]>[0], value)
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
  ipcMain.handle("openassist:set-screen-analysis-frame-visible", async (_event, visible: boolean) =>
    setScreenAnalysisFrameVisible(visible)
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
    clientRunID?: string
  ) => {
    const bridge = await openAssistBridge();
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
        (providerEvent: unknown) => {
          if (!event.sender.isDestroyed()) {
            event.sender.send("openassist:provider-event", providerEvent);
          }
        }
      );
    } catch (error) {
      if (!event.sender.isDestroyed()) {
        event.sender.send("openassist:provider-event", {
          runID: clientRunID,
          threadID: threadID || "new",
          type: "failed",
          provider: "Assistant",
          error: error instanceof Error ? error.message : "The provider failed before returning a response."
        });
      }
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
  ipcMain.handle("openassist:speak-assistant-response", async (_event, text: string, options?: { force?: boolean }) =>
    (await openAssistBridge()).speakAssistantResponse(text, options)
  );
  ipcMain.handle("openassist:stop-assistant-voice-output", async () =>
    (await openAssistBridge()).stopAssistantVoiceOutput()
  );
  ipcMain.handle("openassist:voice-input-configuration", async () => (await openAssistBridge()).voiceInputConfiguration());
  ipcMain.handle("openassist:list-microphones", async () => listMicrophones());
  ipcMain.handle("openassist:start-voice-input", async (_event, options?: VoiceStartOptions) => startConfiguredVoiceInput(options));
  ipcMain.handle("openassist:stop-voice-input", async () => stopConfiguredVoiceInput());
  ipcMain.handle("openassist:realtime-start", async (event, options?: {
    threadID?: string;
    threadId?: string;
    provider?: string;
    interactionMode?: string;
    permissionMode?: string;
    reasoningEffort?: string;
  }) =>
    (await openAssistBridge()).startCodexRealtimeVoice(
      {
        threadID: options?.threadID ?? options?.threadId,
        provider: options?.provider,
        interactionMode: options?.interactionMode,
        permissionMode: options?.permissionMode,
        reasoningEffort: options?.reasoningEffort
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
  ipcMain.handle("openassist:set-window-mode", async (_event, mode: "full" | "sidebar", sidebarOpen?: boolean, sidebarEdge?: "left" | "right") => {
    const window = BrowserWindow.fromWebContents(_event.sender) ?? mainWindow;
    if (window) applyWindowMode(window, mode === "sidebar" ? "sidebar" : "full", sidebarOpen !== false, sidebarEdge === "left" ? "left" : "right");
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

app.on("before-quit", () => {
  isQuitting = true;
});

app.on("will-quit", () => {
  isQuitting = true;
  stopAssistantVoiceOutputForSessionEnd("app quit");
  shortcutMonitorGeneration += 1;
  stopShortcutMonitor();
  stopFrontmostApplicationTracker();
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
