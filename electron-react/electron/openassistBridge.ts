import { spawn, execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { app, safeStorage } from "electron";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { Worker } from "node:worker_threads";
import { CodexRealtimeProxy } from "./realtimeProxy.js";

const execFileAsync = promisify(execFile);
const macAbsoluteEpochOffset = 978_307_200;
const secureCredentialsFileName = "electron-secure-credentials.json";
const transcriptionRequestTimeoutMs = 35_000;
type KokoroVoiceID = NonNullable<import("kokoro-js").GenerateOptions["voice"]>;

type JsonObject = Record<string, unknown>;
type JsonRequestID = string | number;
type AssistantBackend =
  | "codex"
  | "copilot"
  | "claudeCode"
  | "ollamaLocal";
type RuntimeAssistantBackend = AssistantBackend;
type CodexReasoningEffort = "none" | "minimal" | "low" | "medium" | "high" | "xhigh";
type ProviderModelOption = {
  id: string;
  displayName: string;
  description?: string;
  isDefault?: boolean;
  hidden?: boolean;
  supportedReasoningEfforts?: string[];
  defaultReasoningEffort?: string | null;
  inputModalities?: string[];
  isInstalled?: boolean;
  disabled?: boolean;
};

const keychainService = "com.developingadventures.OpenAssist";
const telegramBotTokenKeychainAccount = "telegram-bot-token";
const googleAIStudioAPIKeychainAccount = "google-ai-studio-api-key";
const promptRewriteProviderAPIKeychainAccountPrefix = "prompt-rewrite-provider-api-key";
const cloudTranscriptionProviderAPIKeychainAccountPrefix = "cloud-transcription-provider-api-key";
const realtimeOpenAIAPIKeychainAccount = "realtime-openai-api-key";
const defaultRealtimeOpenAIModel = "gpt-realtime-mini";
const defaultRealtimeOpenAIVoice = "marin";
const codexRealtimePlaceholderAPIKey = "local-realtime-placeholder";
const codexRealtimeStartTimeoutMs = 8_000;
const promptRewriteProviders = [
  "OpenAI",
  "Google AI Studio (Gemini)",
  "OpenRouter",
  "Groq",
  "Anthropic",
  "Ollama (Local)"
] as const;
const cloudTranscriptionProviders = [
  "OpenAI",
  "Groq",
  "Deepgram",
  "Google Gemini (AI Studio)",
  "ChatGPT / Codex Session"
] as const;
const noDictationSoundName = "None";
const dictationSoundOptions = [
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
] as const;
const defaultDictationStartSoundName = "Ping";
const defaultDictationStopSoundName = "Glass";
const defaultDictationProcessingSoundName = "Ping";
const defaultDictationPastedSoundName = "Pop";
const defaultDictationCorrectionLearnedSoundName = "Purr";
const defaultDictationFeedbackVolume = 0.10;
const kokoroModelID = "onnx-community/Kokoro-82M-v1.0-ONNX";
const defaultKokoroVoiceID: KokoroVoiceID = "af_heart";
const assistantSpeechChunkCharacters = 1_100;
const kokoroVoiceIDs = new Set<KokoroVoiceID>([
  "af_heart",
  "af_alloy",
  "af_aoede",
  "af_bella",
  "af_jessica",
  "af_kore",
  "af_nicole",
  "af_nova",
  "af_river",
  "af_sarah",
  "af_sky",
  "am_adam",
  "am_echo",
  "am_eric",
  "am_fenrir",
  "am_liam",
  "am_michael",
  "am_onyx",
  "am_puck",
  "am_santa",
  "bf_emma",
  "bf_isabella",
  "bf_alice",
  "bf_lily",
  "bm_daniel",
  "bm_fable",
  "bm_george",
  "bm_lewis"
]);
let assistantSpeechProcess: ReturnType<typeof spawn> | null = null;
let assistantSpeechRunID = 0;
let kokoroWorker: Worker | null = null;
const kokoroWorkerRequests = new Map<string, {
  resolve: (outputPath?: string) => void;
  reject: (error: Error) => void;
}>();
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

type ProjectItem = {
  id: string;
  title: string;
  subtitle: string;
  icon: string;
  kind?: "folder" | "project";
  parentID?: string | null;
  linkedFolderPath?: string | null;
  hidden?: boolean;
  active?: boolean;
};

type ThreadItem = {
  id: string;
  title: string;
  projectID?: string;
  project?: string;
  activeProvider?: string;
  modelID?: string;
  age: string;
  updatedAt?: number;
  isArchived?: boolean;
  isTemporary?: boolean;
  active?: boolean;
};

type ChatMessage = {
  id: string;
  role: "user" | "assistant" | "activity";
  text: string;
  provider?: string;
  status?: "completed" | "running";
  activityTitle?: string;
  activityKind?: string;
  activityStatus?: "pending" | "running" | "completed" | "failed" | "waiting";
  activityDetail?: string;
  imageDataURL?: string;
  imagePath?: string;
  imagePrompt?: string;
  imageMimeType?: string;
  imageName?: string;
  approvalRequestID?: JsonRequestID;
  approvalKind?: "command" | "fileChange" | "permissions" | "mcpElicitation" | "userInput";
  approvalPrompt?: string;
  approvalOptions?: Array<{
    id: string;
    label: string;
    description?: string;
    tone?: "approve" | "neutral" | "danger";
    result: unknown;
  }>;
  approvalResolved?: boolean;
  createdAt?: number;
  updatedAt?: number;
};

type ProviderRunEvent =
  | { runID?: string; threadID: string; type: "status"; provider: string; text: string }
  | { runID?: string; threadID: string; type: "assistant-delta"; provider: string; delta: string }
  | { runID?: string; threadID: string; type: "activity"; provider: string; activity: ChatMessage }
  | { runID?: string; threadID: string; type: "completed"; provider: string }
  | { runID?: string; threadID: string; type: "failed"; provider: string; error: string };

type NoteItem = {
  id: string;
  title: string;
  subtitle: string;
  projectID: string;
  projectName?: string;
  folderID?: string | null;
  updatedAt?: number;
  active?: boolean;
};

type ThreadNoteListItem = {
  id: string;
  title: string;
  subtitle: string;
  threadID: string;
  threadTitle: string;
  projectID?: string;
  projectName?: string;
  updatedAt?: number;
  isArchived?: boolean;
  active?: boolean;
};

type NoteFolderItem = {
  id: string;
  name: string;
  projectID: string;
  noteCount: number;
};

type AutomationItem = {
  id: string;
  title: string;
  prompt?: string;
  schedule: string;
  enabled: boolean;
};

type SkillItem = {
  id: string;
  title: string;
  description: string;
  group: "built-in" | "my-skills" | "imported";
  attached?: boolean;
  path?: string;
  readOnly?: boolean;
  iconPath?: string | null;
};

type PluginItem = {
  id: string;
  pluginName?: string;
  marketplaceName?: string;
  marketplacePath?: string;
  title: string;
  description: string;
  status: "Installed" | "Available" | "Needs Setup";
  selected?: boolean;
  logoPath?: string | null;
  longDescription?: string;
  starterPrompts?: string[];
  appNames?: string[];
};

type SettingsSnapshot = {
  appVersion: string;
  buildNumber: string;
  assistantBackend: string;
  availableAssistantBackends: string[];
  assistantRuntimeStatus: string;
  assistantRuntimeDetail: string;
  assistantRuntimeAccount: string;
  assistantRuntimeAuthMode: string;
  assistantRuntimeLoginCommand: string;
  assistantRuntimeStatusTone: "ready" | "warning" | "muted";
  model: string;
  subAgentModel: string;
  compactStyle: string;
  compactEdge: string;
  themeMode: string;
  colorTheme: string;
  appChromeStyle: string;
  lightThemeAccent: string;
  lightThemeBackground: string;
  lightThemeForeground: string;
  lightThemeUIFont: string;
  lightThemeCodeFont: string;
  lightThemeTranslucentSidebar: boolean;
  lightThemeContrast: string;
  lightThemeCodeThemeID: string;
  lightThemeDiffAdded: string;
  lightThemeDiffRemoved: string;
  lightThemeSkill: string;
  darkThemeAccent: string;
  darkThemeBackground: string;
  darkThemeForeground: string;
  darkThemeUIFont: string;
  darkThemeCodeFont: string;
  darkThemeTranslucentSidebar: boolean;
  darkThemeContrast: string;
  darkThemeCodeThemeID: string;
  darkThemeDiffAdded: string;
  darkThemeDiffRemoved: string;
  darkThemeSkill: string;
  pointerCursors: boolean;
  reduceMotionMode: string;
  uiFontSize: string;
  codeFontSize: string;
  assistantEnabled: boolean;
  assistantFloatingHUDEnabled: boolean;
  voiceEnabled: boolean;
  realtimeVoiceEnabled: boolean;
  realtimeOpenAIAPIKeyConfigured: boolean;
  realtimeDedicatedOpenAIAPIKeyConfigured: boolean;
  realtimeOpenAIAPIKeySource: "dedicated" | "shared-openai" | "missing";
  realtimeMaskedOpenAIAPIKey: string;
  realtimeOpenAIModel: string;
  realtimeOpenAIVoice: string;
  assistantVoiceOutputEnabled: boolean;
  computerUseEnabled: boolean;
  memoryEnabled: boolean;
  assistantTrackCodeChangesInGitRepos: boolean;
  automationAPIPort: string;
  browserProfile: string;
  holdToTalkShortcut: string;
  holdToTalkShortcutKeyCode: number;
  holdToTalkShortcutModifiers: number;
  continuousToggleShortcut: string;
  continuousToggleShortcutKeyCode: number;
  continuousToggleShortcutModifiers: number;
  assistantLiveVoiceShortcut: string;
  assistantLiveVoiceShortcutKeyCode: number;
  assistantLiveVoiceShortcutModifiers: number;
  assistantCompactShortcut: string;
  assistantCompactShortcutKeyCode: number;
  assistantCompactShortcutModifiers: number;
  screenAnalysisShortcut: string;
  screenAnalysisShortcutKeyCode: number;
  screenAnalysisShortcutModifiers: number;
  transcriptionEngine: string;
  autoDetectMicrophone: boolean;
  selectedMicrophoneUID: string;
  availableMicrophones: Array<{ uid: string; name: string; isDefault?: boolean }>;
  whisperModel: string;
  whisperUseCoreML: boolean;
  whisperInstalledModels: string[];
  whisperModelInstalled: boolean;
  voiceEngine: string;
  kokoroVoice: string;
  kokoroModelInstalled: boolean;
  kokoroModelPath: string;
  kokoroModelDetail: string;
  waveformTheme: string;
  telegramEnabled: boolean;
  telegramBotToken: string;
  telegramMaskedToken: string;
  telegramTokenConfigured: boolean;
  telegramOwnerUserID: string;
  telegramOwnerChatID: string;
  telegramPendingUserID: string;
  telegramPendingChatID: string;
  telegramPendingDisplayName: string;
  telegramSelectedSessionID: string;
  telegramBotUsername: string;
  remoteAccessEnabled: boolean;
  remoteAccessPort: string;
  remoteAccessPublicURL: string;
  localAIRuntimeVersion: string;
  promptRewriteProvider: string;
  promptRewriteModel: string;
  promptRewriteBaseURL: string;
  promptRewriteAPIKeyConfigured: boolean;
  promptRewriteMaskedAPIKey: string;
  cloudTranscriptionProvider: string;
  cloudTranscriptionModel: string;
  cloudTranscriptionBaseURL: string;
  cloudTranscriptionAPIKeyConfigured: boolean;
  cloudTranscriptionMaskedAPIKey: string;
  dictationStartSoundName: string;
  dictationStopSoundName: string;
  dictationProcessingSoundName: string;
  dictationPastedSoundName: string;
  dictationCorrectionLearnedSoundName: string;
  dictationFeedbackVolume: number;
  assistantTextScale: string;
};

type AssistantRuntimeSetupSnapshot = Pick<
  SettingsSnapshot,
  | "assistantRuntimeStatus"
  | "assistantRuntimeDetail"
  | "assistantRuntimeAccount"
  | "assistantRuntimeAuthMode"
  | "assistantRuntimeLoginCommand"
  | "assistantRuntimeStatusTone"
>;

type UsageWindowSnapshot = {
  label: string;
  usedPercent: number;
  resetsAt?: string | null;
  resetsInLabel?: string | null;
};

type ContextUsageSnapshot = {
  usedPercent: number;
  summary: string;
  detail?: string | null;
};

type ProviderUsageSnapshot = {
  providerBackend: string;
  providerLabel: string;
  planType?: string | null;
  primary?: UsageWindowSnapshot | null;
  secondary?: UsageWindowSnapshot | null;
  context?: ContextUsageSnapshot | null;
};

type SettingsUpdateKey =
  | "assistantEnabled"
  | "assistantFloatingHUDEnabled"
  | "voiceEnabled"
  | "realtimeVoiceEnabled"
  | "realtimeOpenAIModel"
  | "realtimeOpenAIVoice"
  | "assistantVoiceOutputEnabled"
  | "computerUseEnabled"
  | "memoryEnabled"
  | "assistantTrackCodeChangesInGitRepos"
  | "telegramEnabled"
  | "remoteAccessEnabled"
  | "compactStyle"
  | "compactEdge"
  | "assistantBackend"
  | "model"
  | "themeMode"
  | "colorTheme"
  | "appChromeStyle"
  | "lightThemeAccent"
  | "lightThemeBackground"
  | "lightThemeForeground"
  | "lightThemeUIFont"
  | "lightThemeCodeFont"
  | "lightThemeTranslucentSidebar"
  | "lightThemeContrast"
  | "lightThemeCodeThemeID"
  | "lightThemeDiffAdded"
  | "lightThemeDiffRemoved"
  | "lightThemeSkill"
  | "darkThemeAccent"
  | "darkThemeBackground"
  | "darkThemeForeground"
  | "darkThemeUIFont"
  | "darkThemeCodeFont"
  | "darkThemeTranslucentSidebar"
  | "darkThemeContrast"
  | "darkThemeCodeThemeID"
  | "darkThemeDiffAdded"
  | "darkThemeDiffRemoved"
  | "darkThemeSkill"
  | "pointerCursors"
  | "reduceMotionMode"
  | "uiFontSize"
  | "codeFontSize"
  | "waveformTheme"
  | "promptRewriteProvider"
  | "promptRewriteModel"
  | "promptRewriteBaseURL"
  | "cloudTranscriptionProvider"
  | "cloudTranscriptionModel"
  | "cloudTranscriptionBaseURL"
  | "dictationStartSoundName"
  | "dictationStopSoundName"
  | "dictationProcessingSoundName"
  | "dictationPastedSoundName"
  | "dictationCorrectionLearnedSoundName"
  | "dictationFeedbackVolume"
  | "autoDetectMicrophone"
  | "selectedMicrophoneUID"
  | "voiceEngine"
  | "kokoroVoice"
  | "whisperModel"
  | "whisperUseCoreML"
  | "transcriptionEngine";

export type OpenAssistAppState = {
  projects: ProjectItem[];
  hiddenProjects: ProjectItem[];
  threads: ThreadItem[];
  notes: NoteItem[];
  threadNotes: ThreadNoteListItem[];
  noteFolders: NoteFolderItem[];
  automations: AutomationItem[];
  skills: SkillItem[];
  plugins: PluginItem[];
  settings: SettingsSnapshot;
  usage?: ProviderUsageSnapshot | null;
  usageByBackend?: Partial<Record<RuntimeAssistantBackend, ProviderUsageSnapshot | null>>;
  activeThreadID?: string;
  activeProjectID?: string;
  activeNoteID?: string;
};

export type ThreadDetail = {
  threadID: string;
  title: string;
  messages: ChatMessage[];
};

export type ThreadNoteSummary = {
  id: string;
  title: string;
  fileName: string;
  updatedAt?: number;
};

export type ThreadNoteWorkspace = {
  threadID: string;
  notes: ThreadNoteSummary[];
  selectedNoteID?: string;
  selectedNote?: ThreadNoteSummary & {
    markdown: string;
    path: string;
  };
};

export type NoteDetail = {
  id: string;
  title: string;
  markdown: string;
  path?: string;
};

type SessionSummary = JsonObject & {
  id: string;
  title: string;
  source: string;
  threadArchitectureVersion?: number;
  conversationPersistence?: number;
  activeProvider?: AssistantBackend;
  providerBindingsByBackend?: JsonObject[];
  status?: string;
  cwd?: string;
  effectiveCWD?: string;
  createdAt?: number;
  updatedAt?: number;
  latestUserMessage?: string;
  latestAssistantMessage?: string;
  latestModel?: string;
  latestInteractionMode?: string;
  latestReasoningEffort?: string;
  latestPermissionMode?: string;
  isArchived?: boolean;
  isTemporary?: boolean;
  projectID?: string;
  projectName?: string;
  linkedProjectFolderPath?: string;
};

type LoadedProjects = {
  projects: ProjectItem[];
  hiddenProjects: ProjectItem[];
  hiddenProjectIDs: Set<string>;
  projectNameByID: Map<string, string>;
  projectNotesByID: Map<string, number>;
  threadAssignments: Record<string, string>;
  threadTitles: Map<string, string>;
};

function supportRoot() {
  return path.join(os.homedir(), "Library/Application Support/OpenAssist");
}

function assistantVoiceLog(message: string) {
  try {
    const logRoot = path.join(os.homedir(), "Library/Logs/OpenAssist");
    fs.mkdirSync(logRoot, { recursive: true });
    fs.appendFileSync(path.join(logRoot, "assistant-voice.log"), `[${new Date().toISOString()}] ${message}\n`, "utf8");
  } catch {
    // Voice logging should never interrupt speech.
  }
}

function projectStoreRoot() {
  return path.join(supportRoot(), "AssistantProjects");
}

function conversationStoreRoot() {
  return path.join(supportRoot(), "AssistantConversationStore");
}

function sessionRegistryPath() {
  return path.join(supportRoot(), "AssistantSessionRegistry", "session-registry.json");
}

function codexRoot() {
  return path.join(os.homedir(), ".codex");
}

function bundledCodexExecutable() {
  const appBundleBinary = "/Applications/Codex.app/Contents/Resources/codex";
  return fs.existsSync(appBundleBinary) ? appBundleBinary : undefined;
}

function resolveCodexExecutable() {
  const override = process.env.OPENASSIST_CODEX_EXECUTABLE?.trim();
  if (override && (!path.isAbsolute(override) || fs.existsSync(override))) return override;
  return bundledCodexExecutable() ?? "codex";
}

function bridgeDebugLog(message: string) {
  try {
    const logRoot = app?.isReady?.() ? app.getPath("userData") : supportRoot();
    fs.mkdirSync(logRoot, { recursive: true });
    fs.appendFileSync(path.join(logRoot, "electron-debug.log"), `[${new Date().toISOString()}] ${message}\n`, "utf8");
  } catch {
    // Debug logging must never break the provider bridge.
  }
}

function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isProcessAlive(pid: number) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function childProcessIDs(pid: number): Promise<number[]> {
  try {
    const { stdout } = await execFileAsync("/usr/bin/pgrep", ["-P", String(pid)]);
    return stdout
      .split(/\s+/)
      .map((value) => Number.parseInt(value, 10))
      .filter((value) => Number.isFinite(value));
  } catch {
    return [];
  }
}

async function descendantProcessIDs(pid: number): Promise<number[]> {
  const directChildren = await childProcessIDs(pid);
  const descendants: number[] = [];
  for (const childPID of directChildren) {
    descendants.push(childPID, ...(await descendantProcessIDs(childPID)));
  }
  return descendants;
}

function killProcessQuietly(pid: number, signal: NodeJS.Signals) {
  try {
    process.kill(pid, signal);
  } catch {
    // The process may already be gone.
  }
}

async function terminateProcessTree(rootPID: number, reason: string) {
  const descendants = await descendantProcessIDs(rootPID);
  const tree = [...descendants.reverse(), rootPID];
  bridgeDebugLog(`terminating Codex helper tree reason="${reason}" pids=${tree.join(",")}`);
  for (const pid of tree) killProcessQuietly(pid, "SIGTERM");
  await delay(900);
  for (const pid of tree) {
    if (isProcessAlive(pid)) killProcessQuietly(pid, "SIGKILL");
  }
}

function codexConfigPath() {
  return path.join(codexRoot(), "config.toml");
}

function openAssistRepoRoot() {
  return path.basename(process.cwd()) === "electron-react" ? path.dirname(process.cwd()) : process.cwd();
}

function sessionWorkingDirectory(session: SessionSummary | undefined) {
  return session?.effectiveCWD || session?.cwd || undefined;
}

type CodexInteractionMode = "conversational" | "plan" | "agentic";
type CodexPermissionMode = "default" | "autoReview" | "fullAccess" | "custom";

type CodexRuntimeOptions = {
  interactionMode?: string;
  permissionMode?: string;
  reasoningEffort?: CodexReasoningEffort;
  pluginIDs?: string[];
  sessionInstructions?: string;
};

const codexComputerUsePluginIDs = new Set([
  "computer-use@openai-bundled",
  "computer-use@openai-curated"
]);

const codexPreferredComputerUsePluginID = "computer-use@openai-bundled";

function canonicalizeCodexPluginID(raw: string): string {
  const normalized = raw.trim().toLowerCase();
  if (codexComputerUsePluginIDs.has(normalized)) {
    return codexPreferredComputerUsePluginID;
  }
  return raw;
}

function canonicalizeCodexPluginIDs(pluginIDs: string[] = []): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const raw of pluginIDs) {
    if (typeof raw !== "string") continue;
    const trimmed = raw.trim();
    if (!trimmed) continue;
    const canonical = canonicalizeCodexPluginID(trimmed);
    const key = canonical.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(canonical);
  }
  return result;
}

const localDesktopAutomationToolNames = new Set([
  "app_action",
  "browser_use",
  "computer_use",
  "computer_batch",
  "screen_capture",
  "window_list",
  "window_capture",
  "list_displays",
  "ui_inspect",
  "ui_click",
  "ui_type",
  "ui_press_key"
]);

function normalizeCodexInteractionMode(raw?: string): CodexInteractionMode {
  const normalized = (raw ?? "").trim().toLowerCase().replace(/[\s_-]+/g, "");
  if (normalized === "chat" || normalized === "conversational") return "conversational";
  if (normalized === "plan") return "plan";
  return "agentic";
}

function codexModeKind(mode: CodexInteractionMode) {
  return mode === "plan" ? "plan" : "default";
}

function normalizeCodexPermissionMode(raw?: string): CodexPermissionMode {
  const normalized = (raw ?? "").trim().toLowerCase().replace(/[\s_-]+/g, "");
  if (normalized === "autoreview" || normalized === "reviewer") return "autoReview";
  if (normalized === "fullaccess" || normalized === "dangerfullaccess" || normalized === "yolo") return "fullAccess";
  if (normalized === "custom" || normalized === "config" || normalized === "configtoml") return "custom";
  return "default";
}

function codexPermissionProfile(id: string): JsonObject {
  return { type: "profile", id };
}

function codexThreadPermissionParams(modeInput?: string): JsonObject {
  const mode = normalizeCodexPermissionMode(modeInput);
  if (mode === "custom") return {};
  if (mode === "fullAccess") {
    return {
      approvalPolicy: "never",
      sandbox: "danger-full-access"
    };
  }
  return {
    approvalPolicy: "on-request",
    approvalsReviewer: mode === "autoReview" ? "auto_review" : "user",
    permissions: codexPermissionProfile(":workspace")
  };
}

function codexTurnPermissionParams(modeInput?: string): JsonObject {
  const mode = normalizeCodexPermissionMode(modeInput);
  if (mode === "custom") return {};
  if (mode === "fullAccess") {
    return {
      approvalPolicy: "never",
      sandboxPolicy: { type: "dangerFullAccess" }
    };
  }
  return {
    approvalPolicy: "on-request",
    approvalsReviewer: mode === "autoReview" ? "auto_review" : "user",
    permissions: codexPermissionProfile(":workspace")
  };
}

function normalizedCodexPluginID(raw?: string) {
  return raw?.trim().toLowerCase() || undefined;
}

function shouldPreferCodexComputerUsePlugin(pluginIDs: string[] = []) {
  return pluginIDs
    .map(normalizedCodexPluginID)
    .some((pluginID) => pluginID ? codexComputerUsePluginIDs.has(pluginID) : false);
}

function codexDynamicToolSpecs(pluginIDs: string[] = [], baseSpecs: JsonObject[] = []) {
  if (!shouldPreferCodexComputerUsePlugin(pluginIDs)) return baseSpecs;
  return baseSpecs.filter((spec) => {
    const name = String(spec.name ?? "").trim();
    return !name || !localDesktopAutomationToolNames.has(name);
  });
}

function codexCollaborationMode(mode: CodexInteractionMode, modelID?: string, reasoningEffort?: CodexReasoningEffort): JsonObject | undefined {
  const model = modelID?.trim();
  if (!model) return undefined;
  const settings: JsonObject = { model };
  if (reasoningEffort) settings.reasoningEffort = reasoningEffort;
  return {
    mode: codexModeKind(mode),
    settings
  };
}

function codexModeInstructions(mode: CodexInteractionMode) {
  if (mode === "conversational") {
    return [
      "# Chat Mode",
      "",
      "You are in Chat mode. Reply with normal helpful text.",
      "You may inspect available context and run safe read-only checks when needed.",
      "Do not edit files or perform higher-risk actions in this mode."
    ].join("\n");
  }
  if (mode === "plan") {
    return [
      "# Plan Mode",
      "",
      "You are in Plan mode. Produce a clear plan only.",
      "Ground the plan in available context when needed.",
      "Do not claim to have executed the work."
    ].join("\n");
  }
  return [
    "# Agentic Mode",
    "",
    "You are in Agentic mode. Use the available tools to complete the user's task.",
    "Ask for approval when the runtime or selected tools require it."
  ].join("\n");
}

function codexWorkspaceBoundaryInstructions(session: SessionSummary | undefined) {
  const cwd = sessionWorkingDirectory(session)?.trim();
  if (cwd) {
    return [
      "# Workspace Boundary",
      "",
      `This thread is attached to the workspace \`${cwd}\`.`,
      "Stay inside this workspace unless the user clearly asks you to inspect somewhere else.",
      "Do not search parent folders, sibling projects, or the user's home directory just to guess where files live."
    ].join("\n");
  }
  return [
    "# Workspace Boundary",
    "",
    "This thread does not have an attached workspace folder.",
    "Do not scan the user's home directory or unrelated folders trying to guess where the project lives.",
    "Work only with the files already provided in the thread, selected skills, selected plugins, or paths the user explicitly names."
  ].join("\n");
}

function buildCodexRuntimeInstructions(session: SessionSummary | undefined, options: CodexRuntimeOptions = {}) {
  const mode = normalizeCodexInteractionMode(options.interactionMode);
  const sections = [
    codexModeInstructions(mode),
    codexWorkspaceBoundaryInstructions(session)
  ];
  if (shouldPreferCodexComputerUsePlugin(options.pluginIDs)) {
    sections.push([
      "# Computer Use In OpenAssist",
      "",
      "OpenAssist can launch Computer Use from a different macOS permission path than Codex.app.",
      "For Apple apps like Notes, Calendar, Mail, and Finder, first use direct read-only macOS commands such as osascript when the task is only to search or read content.",
      "Use Computer Use for visible UI interaction. If a Computer Use app-state call fails or times out, do not retry it in the same turn; switch to a direct fallback and report the result."
    ].join("\n"));
  }
  const sessionInstructions = options.sessionInstructions?.trim();
  if (sessionInstructions) {
    sections.push(`# Custom Instructions\n\n${sessionInstructions}`);
  }
  return sections.join("\n\n");
}

function codexThreadStartParams(session: SessionSummary | undefined, modelID: string, options: CodexRuntimeOptions = {}) {
  const cwd = sessionWorkingDirectory(session);
  const params: JsonObject = {
    ...codexThreadPermissionParams(options.permissionMode),
    personality: "friendly",
    serviceName: "Open Assist",
    ephemeral: false,
    dynamicTools: codexDynamicToolSpecs(options.pluginIDs)
  };
  if (cwd) params.cwd = cwd;
  if (modelID) params.model = modelID;
  const instructions = buildCodexRuntimeInstructions(session, options);
  if (instructions) params.developerInstructions = instructions;
  return params;
}

function codexThreadResumeParams(threadID: string, session: SessionSummary | undefined, modelID: string, options: CodexRuntimeOptions = {}) {
  const startParams = codexThreadStartParams(session, modelID, options);
  const params: JsonObject = {
    threadId: threadID,
    approvalPolicy: startParams.approvalPolicy,
    approvalsReviewer: startParams.approvalsReviewer,
    sandbox: startParams.sandbox
  };
  for (const key of ["approvalPolicy", "approvalsReviewer", "sandbox"] as const) {
    if (params[key] === undefined) delete params[key];
  }
  if (startParams.cwd) params.cwd = startParams.cwd;
  if (startParams.model) params.model = startParams.model;
  if (startParams.developerInstructions) params.developerInstructions = startParams.developerInstructions;
  return params;
}

function codexTurnStartParams(
  providerThreadID: string,
  prompt: string,
  structuredInputItems: JsonObject[],
  modelID: string,
  options: CodexRuntimeOptions = {}
) {
  const mode = normalizeCodexInteractionMode(options.interactionMode);
  const input = [...structuredInputItems];
  if (prompt.trim()) input.push({ type: "text", text: prompt.trim() });
  const params: JsonObject = {
    threadId: providerThreadID,
    input,
    ...codexTurnPermissionParams(options.permissionMode)
  };
  if (modelID) params.model = modelID;
  if (options.reasoningEffort) params.effort = options.reasoningEffort;
  const collaborationMode = codexCollaborationMode(mode, modelID, options.reasoningEffort);
  if (collaborationMode) params.collaborationMode = collaborationMode;
  return params;
}

function readJSON<T>(filePath: string, fallback: T): T {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8")) as T;
  } catch {
    return fallback;
  }
}

async function readDefault(key: string, fallback: string) {
  try {
    const { stdout } = await execFileAsync("defaults", ["read", "com.developingadventures.OpenAssist", key]);
    return stdout.trim() || fallback;
  } catch {
    return fallback;
  }
}

async function readBoolDefault(key: string, fallback: boolean) {
  const value = (await readDefault(key, fallback ? "1" : "0")).toLowerCase();
  return value === "1" || value === "true" || value === "yes";
}

async function readNumberDefault(key: string, fallback: number) {
  const value = Number(await readDefault(key, String(fallback)));
  return Number.isFinite(value) ? value : fallback;
}

async function writeStringDefault(defaultsKey: string, nextValue: string) {
  await execFileAsync("defaults", ["write", "com.developingadventures.OpenAssist", defaultsKey, "-string", nextValue]);
  await synchronizeDefaults();
}

async function writeNumberDefault(defaultsKey: string, nextValue: number) {
  await execFileAsync("defaults", ["write", "com.developingadventures.OpenAssist", defaultsKey, "-float", String(nextValue)]);
  await synchronizeDefaults();
}

async function writeBoolDefault(defaultsKey: string, nextValue: boolean) {
  await execFileAsync("defaults", [
    "write",
    "com.developingadventures.OpenAssist",
    defaultsKey,
    "-bool",
    nextValue ? "true" : "false"
  ]);
  await synchronizeDefaults();
}

async function writeIntDefault(defaultsKey: string, nextValue: number) {
  await execFileAsync("defaults", [
    "write",
    "com.developingadventures.OpenAssist",
    defaultsKey,
    "-int",
    String(nextValue)
  ]);
  await synchronizeDefaults();
}

async function deleteDefault(defaultsKey: string) {
  try {
    await execFileAsync("defaults", ["delete", "com.developingadventures.OpenAssist", defaultsKey]);
    await synchronizeDefaults();
  } catch {
    // Missing defaults are already cleared.
  }
}

async function synchronizeDefaults() {
  try {
    await execFileAsync("defaults", ["synchronize", "com.developingadventures.OpenAssist"]);
  } catch {
    // Some macOS versions ignore this command for app domains; the write already happened.
  }
}

type SecureCredentialRecord = {
  encoding: "safeStorage" | "base64";
  value: string;
};

function secureCredentialsPath() {
  return path.join(app.getPath("userData"), secureCredentialsFileName);
}

function loadSecureCredentials() {
  const filePath = secureCredentialsPath();
  if (!fs.existsSync(filePath)) return {} as Record<string, SecureCredentialRecord>;
  try {
    const raw = JSON.parse(fs.readFileSync(filePath, "utf8")) as Record<string, SecureCredentialRecord>;
    return raw && typeof raw === "object" ? raw : {};
  } catch {
    return {};
  }
}

function saveSecureCredentials(records: Record<string, SecureCredentialRecord>) {
  const filePath = secureCredentialsPath();
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(records, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
  try {
    fs.chmodSync(filePath, 0o600);
  } catch {
    // Best effort. The file still lives under the app support directory.
  }
}

function readSecureCredential(account: string) {
  const record = loadSecureCredentials()[account];
  if (!record?.value) return "";
  try {
    if (record.encoding === "safeStorage") {
      return safeStorage.decryptString(Buffer.from(record.value, "base64")).trim();
    }
    if (record.encoding === "base64") {
      return Buffer.from(record.value, "base64").toString("utf8").trim();
    }
  } catch {
    return "";
  }
  return "";
}

function storeSecureCredential(account: string, rawValue: string) {
  const value = rawValue.trim();
  const records = loadSecureCredentials();
  if (!value) {
    delete records[account];
    saveSecureCredentials(records);
    return;
  }
  const encrypted = safeStorage.isEncryptionAvailable();
  records[account] = encrypted
    ? { encoding: "safeStorage", value: safeStorage.encryptString(value).toString("base64") }
    : { encoding: "base64", value: Buffer.from(value, "utf8").toString("base64") };
  saveSecureCredentials(records);
}

function shouldUseSystemKeychainFallback() {
  return process.env.OPENASSIST_ELECTRON_USE_SYSTEM_KEYCHAIN === "1";
}

async function readKeychainPassword(account: string) {
  const secureCredential = readSecureCredential(account);
  if (secureCredential) return secureCredential;
  if (!shouldUseSystemKeychainFallback()) return "";
  try {
    const { stdout } = await execFileAsync("security", [
      "find-generic-password",
      "-s",
      keychainService,
      "-a",
      account,
      "-w"
    ], { timeout: 1500 });
    return stdout.trim();
  } catch {
    return "";
  }
}

async function readGenericKeychainPassword(service: string, account?: string | null) {
  const args = [
    "find-generic-password",
    "-s",
    service,
    "-w"
  ];
  if (account?.trim()) args.splice(3, 0, "-a", account.trim());
  try {
    const { stdout } = await execFileAsync("security", args, { timeout: 1500 });
    return stdout.trim();
  } catch {
    return "";
  }
}

async function hasKeychainPassword(account: string) {
  if (readSecureCredential(account)) return true;
  if (!shouldUseSystemKeychainFallback()) return false;
  try {
    await execFileAsync("security", [
      "find-generic-password",
      "-s",
      keychainService,
      "-a",
      account
    ], { timeout: 1200 });
    return true;
  } catch {
    return false;
  }
}

async function storeKeychainPassword(account: string, rawValue: string) {
  const value = rawValue.trim();
  storeSecureCredential(account, value);
  if (!shouldUseSystemKeychainFallback()) return;
  if (!value) {
    await deleteKeychainPassword(account);
    return;
  }
  await deleteKeychainPassword(account);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await execFileAsync("security", [
      "add-generic-password",
      "-s",
      keychainService,
      "-a",
      account,
      "-w",
      value
    ], { timeout: 2500 });
    if (await hasKeychainPassword(account)) return;
    await new Promise((resolve) => setTimeout(resolve, 120));
  }
  throw new Error("Could not confirm Keychain credential was saved.");
}

async function deleteKeychainPassword(account: string) {
  storeSecureCredential(account, "");
  if (!shouldUseSystemKeychainFallback()) return;
  for (let attempt = 0; attempt < 20; attempt += 1) {
    try {
      await execFileAsync("security", ["delete-generic-password", "-s", keychainService, "-a", account], { timeout: 1500 });
    } catch {
      if (!(await hasKeychainPassword(account))) return;
    }
    if (!(await hasKeychainPassword(account))) return;
    await new Promise((resolve) => setTimeout(resolve, 80));
  }
  throw new Error(`Could not clear Keychain credential for ${account}.`);
}

function maskedSecret(value: string) {
  const trimmed = value.trim();
  if (!trimmed) return "Not configured";
  if (trimmed.length <= 8) return "****";
  return `${trimmed.slice(0, 4)}****${trimmed.slice(-4)}`;
}

function keychainStatus(configured: boolean, requiresKey = true) {
  if (!requiresKey) return "Not required";
  return configured ? "Configured securely" : "Not configured";
}

function shortcutDisplay(keyCodeRaw: string, modifiersRaw: string, fallbackKeyCode: number, fallbackModifiers: number) {
  const parsedKeyCode = Number.parseInt(keyCodeRaw, 10);
  const parsedModifiers = Number.parseInt(modifiersRaw, 10);
  const keyCode = Number.isFinite(parsedKeyCode) ? parsedKeyCode : fallbackKeyCode;
  const modifiers = Number.isFinite(parsedModifiers) ? parsedModifiers : fallbackModifiers;
  const segments: string[] = [];
  if (modifiers & 262144) segments.push("Control");
  if (modifiers & 524288) segments.push("Option");
  if (modifiers & 131072) segments.push("Shift");
  if (modifiers & 1048576) segments.push("Command");
  if (modifiers & 8388608) segments.push("Fn");
  const keyNames: Record<number, string> = {
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
    18: "1",
    19: "2",
    20: "3",
    21: "4",
    22: "6",
    23: "5",
    24: "=",
    25: "9",
    26: "7",
    27: "-",
    28: "8",
    29: "0",
    30: "]",
    31: "O",
    32: "U",
    33: "[",
    34: "I",
    35: "P",
    36: "Return",
    37: "L",
    38: "J",
    39: "'",
    40: "K",
    41: ";",
    42: "\\",
    43: ",",
    44: "/",
    45: "N",
    46: "M",
    47: ".",
    48: "`",
    49: "Space",
    50: "`",
    51: "Delete",
    53: "Esc",
    63: "Fn",
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
  if (keyCode !== 65535) {
    segments.push(keyNames[keyCode] ?? `Key ${keyCode}`);
  }
  return segments.join(" ");
}

function parsedShortcutValue(rawValue: string, fallback: number) {
  const parsed = Number.parseInt(rawValue, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function isPromptRewriteProvider(rawValue: string): rawValue is (typeof promptRewriteProviders)[number] {
  return (promptRewriteProviders as readonly string[]).includes(rawValue);
}

function isCloudTranscriptionProvider(rawValue: string): rawValue is (typeof cloudTranscriptionProviders)[number] {
  return (cloudTranscriptionProviders as readonly string[]).includes(rawValue);
}

function promptRewriteProviderRequiresKey(provider: string) {
  return provider !== "Ollama (Local)";
}

function cloudTranscriptionProviderRequiresKey(provider: string) {
  return provider !== "ChatGPT / Codex Session";
}

function isWhisperModelID(rawValue: string): rawValue is (typeof whisperModelIDs)[number] {
  return (whisperModelIDs as readonly string[]).includes(rawValue);
}

function whisperModelsDirectory() {
  return path.join(os.homedir(), "Library", "Application Support", "OpenAssist", "Models");
}

function whisperModelPath(modelID: string) {
  return path.join(whisperModelsDirectory(), `ggml-${modelID}.bin`);
}

function installedWhisperModelIDs() {
  return whisperModelIDs.filter((modelID) => fs.existsSync(whisperModelPath(modelID)));
}

function assistantVoiceRoot() {
  return path.join(supportRoot(), "AssistantVoice");
}

function kokoroVoiceDirectory() {
  return path.join(assistantVoiceRoot(), "Kokoro");
}

function kokoroModelCacheDirectory() {
  return path.join(kokoroVoiceDirectory(), "model-cache");
}

function kokoroOutputDirectory() {
  return path.join(kokoroVoiceDirectory(), "generated");
}

function isGeneratedAssistantVoiceFile(filePath: string) {
  const outputRoot = path.resolve(kokoroOutputDirectory());
  const resolvedPath = path.resolve(filePath);
  return (
    path.dirname(resolvedPath) === outputRoot &&
    /^assistant-reply-\d+(?:-\d+)?\.wav$/.test(path.basename(resolvedPath))
  );
}

function removeGeneratedAssistantVoiceFile(filePath: string) {
  if (!isGeneratedAssistantVoiceFile(filePath)) return;
  try {
    fs.unlinkSync(filePath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      console.warn(`assistant voice cleanup failed for ${filePath}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
}

function cleanupGeneratedAssistantVoiceFiles(exceptPath?: string) {
  const outputDirectory = kokoroOutputDirectory();
  if (!fs.existsSync(outputDirectory)) return;
  const exceptResolvedPath = exceptPath ? path.resolve(exceptPath) : "";
  for (const fileName of fs.readdirSync(outputDirectory)) {
    const filePath = path.join(outputDirectory, fileName);
    if (exceptResolvedPath && path.resolve(filePath) === exceptResolvedPath) continue;
    if (isGeneratedAssistantVoiceFile(filePath)) removeGeneratedAssistantVoiceFile(filePath);
  }
}

function kokoroInstallMarkerPath() {
  return path.join(kokoroVoiceDirectory(), "install.json");
}

function kokoroInstalled() {
  return fs.existsSync(kokoroInstallMarkerPath());
}

function safeKokoroVoiceID(rawValue: string): KokoroVoiceID {
  const value = rawValue.trim() as KokoroVoiceID;
  return kokoroVoiceIDs.has(value) ? value : defaultKokoroVoiceID;
}

function rejectPendingKokoroWorkerRequests(error: Error) {
  for (const request of kokoroWorkerRequests.values()) {
    request.reject(error);
  }
  kokoroWorkerRequests.clear();
}

function resetKokoroWorker(reason: string) {
  const worker = kokoroWorker;
  if (!worker) return;
  kokoroWorker = null;
  rejectPendingKokoroWorkerRequests(new Error(`Kokoro voice generation was cancelled: ${reason}.`));
  worker.terminate().catch((error) => {
    assistantVoiceLog(`kokoro worker terminate failed: ${error instanceof Error ? error.message : String(error)}`);
  });
}

function resetKokoroWorkerIfBusy(reason: string) {
  if (kokoroWorkerRequests.size > 0) resetKokoroWorker(reason);
}

function ensureKokoroWorker() {
  if (kokoroWorker) return kokoroWorker;
  const worker = new Worker(new URL("./kokoroVoiceWorker.js", import.meta.url));
  kokoroWorker = worker;
  worker.on("message", (message: unknown) => {
    const response = message as { requestID?: string; ok?: boolean; outputPath?: string; error?: string };
    const requestID = response.requestID;
    if (!requestID) return;
    const request = kokoroWorkerRequests.get(requestID);
    if (!request) return;
    kokoroWorkerRequests.delete(requestID);
    if (response.ok) {
      request.resolve(response.outputPath);
    } else {
      request.reject(new Error(response.error || "Kokoro voice generation failed."));
    }
  });
  worker.once("error", (error) => {
    if (kokoroWorker === worker) kokoroWorker = null;
    rejectPendingKokoroWorkerRequests(error instanceof Error ? error : new Error(String(error)));
  });
  worker.once("exit", (code) => {
    if (kokoroWorker === worker) kokoroWorker = null;
    if (code !== 0 && kokoroWorkerRequests.size > 0) {
      rejectPendingKokoroWorkerRequests(new Error(`Kokoro voice worker exited with code ${code}.`));
    }
  });
  return worker;
}

function runKokoroWorkerRequest(message: Omit<{
  type: "prewarm" | "generate";
  requestID: string;
  modelID: string;
  cacheDir: string;
  text?: string;
  voiceID?: string;
  outputPath?: string;
}, "requestID" | "modelID" | "cacheDir">) {
  const worker = ensureKokoroWorker();
  const requestID = randomUUID().toLowerCase();
  return new Promise<string | undefined>((resolve, reject) => {
    kokoroWorkerRequests.set(requestID, { resolve, reject });
    worker.postMessage({
      ...message,
      requestID,
      modelID: kokoroModelID,
      cacheDir: kokoroModelCacheDirectory()
    });
  });
}

async function prewarmKokoroWorker() {
  await runKokoroWorkerRequest({ type: "prewarm" });
}

function assistantSpeechText(rawText: string) {
  return rawText
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/!\[[^\]]*]\([^)]+\)/g, " ")
    .replace(/\[([^\]]+)]\([^)]+\)/g, "$1")
    .replace(/^[#>*\-\s]+/gm, "")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/\*([^*]+)\*/g, "$1")
    .replace(/[_~]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function splitLongSpeechPart(part: string, maxLength: number) {
  const words = part.match(/\S+\s*/g) ?? [];
  const chunks: string[] = [];
  let current = "";
  for (const word of words) {
    if (current && current.length + word.length > maxLength) {
      chunks.push(current.trim());
      current = "";
    }
    current += word;
  }
  if (current.trim()) chunks.push(current.trim());
  return chunks;
}

function splitAssistantSpeechSegments(text: string, maxLength = assistantSpeechChunkCharacters) {
  const parts = text
    .replace(/\s+/g, " ")
    .split(/(?<=[.!?])\s+(?=[A-Z0-9"'])/g)
    .map((part) => part.trim())
    .filter(Boolean);
  const segments: string[] = [];
  let current = "";
  for (const part of parts.length ? parts : [text.trim()]) {
    if (part.length > maxLength) {
      if (current) {
        segments.push(current.trim());
        current = "";
      }
      segments.push(...splitLongSpeechPart(part, maxLength));
      continue;
    }
    if (current && current.length + part.length + 1 > maxLength) {
      segments.push(current.trim());
      current = part;
    } else {
      current = current ? `${current} ${part}` : part;
    }
  }
  if (current.trim()) segments.push(current.trim());
  return segments.length ? segments : [];
}

function stopAssistantSpeechProcess() {
  if (assistantSpeechProcess && !assistantSpeechProcess.killed) {
    assistantSpeechProcess.kill();
  }
  assistantSpeechProcess = null;
}

function beginAssistantSpeechRun() {
  assistantSpeechRunID += 1;
  stopAssistantSpeechProcess();
  resetKokoroWorkerIfBusy("new voice playback started");
  return assistantSpeechRunID;
}

function stopAssistantSpeech() {
  assistantSpeechRunID += 1;
  stopAssistantSpeechProcess();
  resetKokoroWorkerIfBusy("voice playback stopped");
  cleanupGeneratedAssistantVoiceFiles();
}

function playAudioFile(filePath: string, options: { deleteAfterPlayback?: boolean } = {}) {
  return new Promise<void>((resolve, reject) => {
    stopAssistantSpeechProcess();
    const child = spawn("/usr/bin/afplay", [filePath], { stdio: "ignore" });
    assistantSpeechProcess = child;
    let settled = false;
    const finish = (error?: Error) => {
      if (settled) return;
      settled = true;
      if (assistantSpeechProcess === child) assistantSpeechProcess = null;
      if (options.deleteAfterPlayback) removeGeneratedAssistantVoiceFile(filePath);
      error ? reject(error) : resolve();
    };
    child.once("error", finish);
    child.once("exit", (code) => {
      code === 0 || code === null ? finish() : finish(new Error(`Audio playback exited with code ${code}.`));
    });
  });
}

async function generateKokoroAudioFile(
  text: string,
  voiceID: string,
  outputDirectory: string,
  runID: number,
  index: number
) {
  const outputPath = path.join(outputDirectory, `assistant-reply-${Date.now()}-${index}.wav`);
  if (runID !== assistantSpeechRunID) {
    return "";
  }
  await runKokoroWorkerRequest({
    type: "generate",
    text,
    voiceID: safeKokoroVoiceID(voiceID),
    outputPath
  });
  if (runID !== assistantSpeechRunID) {
    removeGeneratedAssistantVoiceFile(outputPath);
    return "";
  }
  return outputPath;
}

async function generateKokoroAudioFilesForSegment(
  text: string,
  voiceID: string,
  outputDirectory: string,
  runID: number,
  index: number
) {
  try {
    const outputPath = await generateKokoroAudioFile(text, voiceID, outputDirectory, runID, index);
    return outputPath ? [outputPath] : [];
  } catch (error) {
    assistantVoiceLog(
      `kokoro segment ${index} failed length=${text.length}: ${error instanceof Error ? error.stack ?? error.message : String(error)}`
    );
    const smallerSegments = text.length > 420
      ? splitAssistantSpeechSegments(text, Math.max(360, Math.floor(assistantSpeechChunkCharacters / 2)))
      : [];
    if (smallerSegments.length <= 1) throw error;
    assistantVoiceLog(`kokoro segment ${index} retrying as ${smallerSegments.length} smaller parts`);
    const outputPaths: string[] = [];
    for (let partIndex = 0; partIndex < smallerSegments.length; partIndex += 1) {
      if (runID !== assistantSpeechRunID) return [];
      const outputPath = await generateKokoroAudioFile(
        smallerSegments[partIndex],
        voiceID,
        outputDirectory,
        runID,
        index * 100 + partIndex
      );
      if (outputPath) outputPaths.push(outputPath);
    }
    return outputPaths;
  }
}

function promptRewriteDefaultModel(provider: string) {
  switch (provider) {
    case "OpenAI":
      return "gpt-4.1-mini";
    case "Google AI Studio (Gemini)":
      return "gemini-3-flash-preview";
    case "OpenRouter":
      return "openai/gpt-4.1-mini";
    case "Groq":
      return "llama-3.3-70b-versatile";
    case "Anthropic":
      return "claude-3-5-sonnet-latest";
    case "Ollama (Local)":
    default:
      return "llama3.1";
  }
}

function promptRewriteDefaultBaseURL(provider: string) {
  switch (provider) {
    case "OpenAI":
      return "https://api.openai.com/v1";
    case "Google AI Studio (Gemini)":
      return "https://generativelanguage.googleapis.com/v1beta/openai";
    case "OpenRouter":
      return "https://openrouter.ai/api/v1";
    case "Groq":
      return "https://api.groq.com/openai/v1";
    case "Anthropic":
      return "https://api.anthropic.com/v1";
    case "Ollama (Local)":
    default:
      return "http://localhost:11434/v1";
  }
}

function cloudTranscriptionDefaultModel(provider: string) {
  switch (provider) {
    case "OpenAI":
      return "gpt-4o-mini-transcribe";
    case "Groq":
      return "whisper-large-v3-turbo";
    case "Deepgram":
      return "nova-3";
    case "Google Gemini (AI Studio)":
      return "gemini-2.5-flash";
    case "ChatGPT / Codex Session":
    default:
      return "gpt-4o-mini-transcribe";
  }
}

function cloudTranscriptionDefaultBaseURL(provider: string) {
  switch (provider) {
    case "OpenAI":
      return "https://api.openai.com/v1";
    case "Groq":
      return "https://api.groq.com/openai/v1";
    case "Deepgram":
      return "https://api.deepgram.com/v1/listen";
    case "Google Gemini (AI Studio)":
      return "https://generativelanguage.googleapis.com/v1beta";
    case "ChatGPT / Codex Session":
    default:
      return "https://chatgpt.com/backend-api";
  }
}

function promptRewriteKeychainAccount(provider: string) {
  if (provider === "Google AI Studio (Gemini)") return googleAIStudioAPIKeychainAccount;
  const normalized = provider.toLowerCase().replace(/[()]/g, "").replace(/ /g, "-");
  return `${promptRewriteProviderAPIKeychainAccountPrefix}.${normalized}`;
}

function cloudTranscriptionKeychainAccount(provider: string) {
  if (provider === "Google Gemini (AI Studio)") return googleAIStudioAPIKeychainAccount;
  const normalized = provider.toLowerCase().replace(/[()]/g, "").replace(/\//g, "-").replace(/ /g, "-");
  return `${cloudTranscriptionProviderAPIKeychainAccountPrefix}.${normalized}`;
}

async function resolveRealtimeOpenAIAPIKey() {
  const dedicatedKey = await readKeychainPassword(realtimeOpenAIAPIKeychainAccount);
  if (dedicatedKey) {
    return {
      apiKey: dedicatedKey,
      configured: true,
      dedicatedConfigured: true,
      source: "dedicated" as const,
      label: keychainStatus(true, true)
    };
  }

  const sharedOpenAIKey = await readKeychainPassword(cloudTranscriptionKeychainAccount("OpenAI"));
  if (sharedOpenAIKey) {
    return {
      apiKey: sharedOpenAIKey,
      configured: true,
      dedicatedConfigured: false,
      source: "shared-openai" as const,
      label: "Using saved OpenAI key"
    };
  }

  const promptRewriteOpenAIKey = await readKeychainPassword(promptRewriteKeychainAccount("OpenAI"));
  if (promptRewriteOpenAIKey) {
    return {
      apiKey: promptRewriteOpenAIKey,
      configured: true,
      dedicatedConfigured: false,
      source: "shared-openai" as const,
      label: "Using saved OpenAI key"
    };
  }

  return {
    apiKey: undefined,
    configured: false,
    dedicatedConfigured: false,
    source: "missing" as const,
    label: keychainStatus(false, true)
  };
}

function normalizedDictationSoundName(value: string, fallback: string) {
  return (dictationSoundOptions as readonly string[]).includes(value) ? value : fallback;
}

type AudioTranscriptionFile = {
  filePath: string;
  fileName?: string;
  mimeType?: string;
};

type TranscriptionAuthMode = "chatGPT" | "apiKey" | "none";
type CodexTranscriptionAuthContext = {
  token: string;
  authMode: Exclude<TranscriptionAuthMode, "none">;
};

const openAICompatibleUploadLimitBytes = 24_000_000;
const chatGPTTranscriptionsURL = "https://chatgpt.com/backend-api/transcribe";
const chatGPTWebUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
const codexTranscriptionAuthCacheMs = 8 * 60_000;
let codexTranscriptionAuthCache: { context: CodexTranscriptionAuthContext; expiresAt: number } | null = null;
let codexTranscriptionAuthInFlight: Promise<CodexTranscriptionAuthContext> | null = null;

function compactNonEmpty(values: Array<string | undefined>) {
  return values
    .map((value) => value?.trim())
    .filter((value): value is string => Boolean(value));
}

function firstNonEmptyString(...values: Array<unknown>) {
  return compactNonEmpty(values.map((value) => (typeof value === "string" ? value : undefined)))[0];
}

function normalizedFileName(rawValue: string | undefined, fallback: string) {
  const value = rawValue?.trim();
  return value || fallback;
}

function normalizedMimeType(rawValue: string | undefined, fallback: string) {
  const value = rawValue?.trim();
  return value || fallback;
}

function validatedBaseURL(rawValue: string) {
  let url: URL;
  try {
    url = new URL(rawValue);
  } catch {
    throw new Error("Invalid provider base URL.");
  }
  const scheme = url.protocol.replace(":", "").toLowerCase();
  const host = url.hostname.toLowerCase();
  const isLoopback = ["localhost", "127.0.0.1", "::1", "[::1]"].includes(host);
  if (scheme !== "https" && !(scheme === "http" && isLoopback)) {
    throw new Error("Invalid provider base URL.");
  }
  url.hash = "";
  return url;
}

function urlByAppendingPath(baseURL: string, suffix: string) {
  const url = validatedBaseURL(baseURL);
  const existingPath = url.pathname.replace(/^\/+|\/+$/g, "");
  const nextPath = suffix.replace(/^\/+|\/+$/g, "");
  url.pathname = `/${[existingPath, nextPath].filter(Boolean).join("/")}`;
  return url;
}

function transcriptionPrompt() {
  return "Transcribe this audio verbatim. Preserve wording and punctuation when clear.";
}

function makeMultipartFormData({
  fields,
  fileFieldName,
  fileName,
  fileMimeType,
  fileData
}: {
  fields: Array<[string, string]>;
  fileFieldName: string;
  fileName: string;
  fileMimeType: string;
  fileData: Buffer;
}) {
  const boundary = `Boundary-${randomUUID()}`;
  const chunks: Buffer[] = [];
  for (const [name, value] of fields) {
    const trimmed = value.trim();
    if (!trimmed) continue;
    chunks.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${trimmed}\r\n`));
  }
  chunks.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${fileFieldName}"; filename="${fileName}"\r\nContent-Type: ${fileMimeType}\r\n\r\n`));
  chunks.push(fileData);
  chunks.push(Buffer.from(`\r\n--${boundary}--\r\n`));
  return { boundary, body: Buffer.concat(chunks) };
}

async function responsePayload(response: Response) {
  const body = Buffer.from(await response.arrayBuffer());
  let json: unknown;
  try {
    json = JSON.parse(body.toString("utf8"));
  } catch {
    json = null;
  }
  return { body, json };
}

async function fetchWithTimeout(
  input: Parameters<typeof fetch>[0],
  init: Parameters<typeof fetch>[1],
  timeoutMs: number,
  timeoutMessage: string
) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(input, { ...init, signal: controller.signal });
  } catch (error) {
    if (error instanceof Error && error.name === "AbortError") {
      throw new Error(timeoutMessage);
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function providerErrorFromPayload(json: unknown, body: Buffer, status: number) {
  if (json && typeof json === "object") {
    const object = json as JsonObject;
    const error = object.error;
    if (error && typeof error === "object") {
      const message = firstNonEmptyString((error as JsonObject).message);
      if (message) return message;
    }
    const message = firstNonEmptyString(object.message, object.err_msg, object.error);
    if (message) return message;
  }
  return body.toString("utf8").trim() || `HTTP ${status}`;
}

function decodeOpenAICompatibleText(json: unknown) {
  if (!json || typeof json !== "object") return "";
  const object = json as JsonObject;
  return firstNonEmptyString(object.text, object.transcript) ?? "";
}

function decodeDeepgramText(json: unknown) {
  if (!json || typeof json !== "object") return "";
  const root = json as JsonObject;
  const results = root.results as JsonObject | undefined;
  const channels = Array.isArray(results?.channels) ? results.channels : [];
  const firstChannel = channels[0] as JsonObject | undefined;
  const alternatives = Array.isArray(firstChannel?.alternatives) ? firstChannel.alternatives : [];
  const firstAlternative = alternatives[0] as JsonObject | undefined;
  return firstNonEmptyString(firstAlternative?.transcript) ?? "";
}

function decodeGeminiText(json: unknown) {
  if (!json || typeof json !== "object") return "";
  const root = json as JsonObject;
  const candidates = Array.isArray(root.candidates) ? root.candidates : [];
  const parts = candidates.flatMap((candidate) => {
    const content = (candidate as JsonObject).content as JsonObject | undefined;
    return Array.isArray(content?.parts) ? content.parts : [];
  });
  return compactNonEmpty(parts.map((part) => firstNonEmptyString((part as JsonObject).text))).join(" ").trim();
}

function ensureUploadableAudio(audio: Buffer) {
  if (!audio.length) throw new Error("No speech captured.");
  if (audio.length > openAICompatibleUploadLimitBytes) {
    throw new Error("Captured audio is too large for this provider upload limit.");
  }
}

async function transcribeWithOpenAICompatibleAPI({
  audio,
  provider,
  model,
  baseURL,
  apiKey,
  fileName,
  mimeType
}: {
  audio: Buffer;
  provider: string;
  model: string;
  baseURL: string;
  apiKey: string;
  fileName: string;
  mimeType: string;
}) {
  ensureUploadableAudio(audio);
  const trimmedAPIKey = apiKey.trim();
  if (!trimmedAPIKey) throw new Error("Cloud API key is missing.");
  const endpoint = urlByAppendingPath(baseURL, "audio/transcriptions");
  const { boundary, body } = makeMultipartFormData({
    fields: [
      ["model", model],
      ["prompt", transcriptionPrompt()]
    ],
    fileFieldName: "file",
    fileName,
    fileMimeType: mimeType,
    fileData: audio
  });
  const response = await fetchWithTimeout(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${trimmedAPIKey}`,
      "Content-Type": `multipart/form-data; boundary=${boundary}`
    },
    body: body as never
  }, transcriptionRequestTimeoutMs, `${provider} transcription timed out. Check your internet connection and API key, then try again.`);
  const payload = await responsePayload(response);
  if (!response.ok) throw new Error(providerErrorFromPayload(payload.json, payload.body, response.status));
  const text = decodeOpenAICompatibleText(payload.json);
  if (text) return text;
  throw new Error(`${provider} returned an unsupported transcription response.`);
}

async function transcribeWithDeepgram({
  audio,
  model,
  baseURL,
  apiKey,
  mimeType
}: {
  audio: Buffer;
  model: string;
  baseURL: string;
  apiKey: string;
  mimeType: string;
}) {
  if (!audio.length) throw new Error("No speech captured.");
  const trimmedAPIKey = apiKey.trim();
  if (!trimmedAPIKey) throw new Error("Cloud API key is missing.");
  const endpoint = validatedBaseURL(baseURL);
  const currentPath = endpoint.pathname.replace(/\/+$/g, "");
  endpoint.pathname = currentPath.endsWith("/listen") ? currentPath : `${currentPath || "/v1"}/listen`;
  if (!endpoint.searchParams.has("model")) endpoint.searchParams.set("model", model);
  if (!endpoint.searchParams.has("smart_format")) endpoint.searchParams.set("smart_format", "true");
  const response = await fetchWithTimeout(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Token ${trimmedAPIKey}`,
      "Content-Type": mimeType
    },
    body: audio as never
  }, transcriptionRequestTimeoutMs, "Deepgram transcription timed out. Check your internet connection and API key, then try again.");
  const payload = await responsePayload(response);
  if (!response.ok) throw new Error(providerErrorFromPayload(payload.json, payload.body, response.status));
  const text = decodeDeepgramText(payload.json);
  if (text) return text;
  throw new Error("Deepgram returned an unsupported transcription response.");
}

async function transcribeWithGemini({
  audio,
  model,
  baseURL,
  apiKey,
  mimeType
}: {
  audio: Buffer;
  model: string;
  baseURL: string;
  apiKey: string;
  mimeType: string;
}) {
  if (!audio.length) throw new Error("No speech captured.");
  const trimmedAPIKey = apiKey.trim();
  if (!trimmedAPIKey) throw new Error("Cloud API key is missing.");
  const encodedModel = encodeURIComponent(model);
  const endpoint = urlByAppendingPath(baseURL, `models/${encodedModel}:generateContent`);
  endpoint.searchParams.set("key", trimmedAPIKey);
  const response = await fetchWithTimeout(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      contents: [
        {
          role: "user",
          parts: [
            { text: transcriptionPrompt() },
            {
              inline_data: {
                mime_type: mimeType,
                data: audio.toString("base64")
              }
            }
          ]
        }
      ],
      generationConfig: { temperature: 0 }
    })
  }, transcriptionRequestTimeoutMs, "Google Gemini transcription timed out. Check your internet connection and API key, then try again.");
  const payload = await responsePayload(response);
  if (!response.ok) throw new Error(providerErrorFromPayload(payload.json, payload.body, response.status));
  const text = decodeGeminiText(payload.json);
  if (text) return text;
  throw new Error("Google Gemini returned an unsupported transcription response.");
}

function assistantAccountAuthMode(rawValue: string): TranscriptionAuthMode | undefined {
  const normalized = rawValue.trim().toLowerCase();
  if (!normalized) return undefined;
  if (normalized.includes("chatgpt") || normalized.includes("chat_gpt") || normalized.includes("session")) return "chatGPT";
  if (normalized.includes("api") || normalized.includes("key")) return "apiKey";
  if (normalized === "none" || normalized === "signedout" || normalized === "signed_out") return "none";
  return undefined;
}

function transcriptionAuthCandidateDictionaries(raw: unknown) {
  if (!raw || typeof raw !== "object") return [];
  const dictionaries: JsonObject[] = [raw as JsonObject];
  const nestedKeys = ["result", "status", "auth", "data", "credentials", "tokens", "account"];
  for (let index = 0; index < dictionaries.length; index += 1) {
    const dictionary = dictionaries[index];
    for (const key of nestedKeys) {
      const nested = dictionary[key];
      if (nested && typeof nested === "object" && !Array.isArray(nested) && !dictionaries.includes(nested as JsonObject)) {
        dictionaries.push(nested as JsonObject);
      }
    }
  }
  return dictionaries;
}

function parseTranscriptionAuthContext(raw: unknown): CodexTranscriptionAuthContext {
  const dictionaries = transcriptionAuthCandidateDictionaries(raw);
  if (!dictionaries.length) throw new Error("Codex returned an empty transcription auth response.");
  const responseError = dictionaries
    .map((dictionary) => {
      const detail = dictionary.detail as JsonObject | undefined;
      const details = dictionary.details as JsonObject | undefined;
      return firstNonEmptyString(dictionary.error, dictionary.message, detail?.message, details?.message);
    })
    .find(Boolean);
  if (responseError) throw new Error(responseError);
  const token = dictionaries
    .map((dictionary) => firstNonEmptyString(
      dictionary.token,
      dictionary.accessToken,
      dictionary.access_token,
      dictionary.apiKey,
      dictionary.api_key,
      dictionary.authToken
    ))
    .find(Boolean);
  if (!token) throw new Error("Codex did not return a reusable transcription token.");
  const authMode = dictionaries
    .map((dictionary) => firstNonEmptyString(
      dictionary.authMode,
      dictionary.authMethod,
      dictionary.method,
      dictionary.type,
      dictionary.provider
    ))
    .filter((value): value is string => Boolean(value))
    .map(assistantAccountAuthMode)
    .find(Boolean) ?? "none";
  if (authMode === "none") {
    throw new Error("Codex did not indicate whether transcription auth is ChatGPT or API key based.");
  }
  return { token, authMode };
}

function clearCodexTranscriptionAuthCache() {
  codexTranscriptionAuthCache = null;
}

async function fetchCodexTranscriptionAuthContext(refreshToken: boolean) {
  let lastError: unknown;
  for (const method of ["getAuthStatus", "account/getAuthStatus"]) {
    try {
      const response = await codexTransport.request(method, {
        includeToken: true,
        refreshToken
      });
      return parseTranscriptionAuthContext(response);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError instanceof Error ? lastError : new Error("Codex did not provide a transcription auth status response.");
}

async function resolveCodexTranscriptionAuthContext(options: { forceRefresh?: boolean } = {}) {
  const now = Date.now();
  if (!options.forceRefresh && codexTranscriptionAuthCache && codexTranscriptionAuthCache.expiresAt > now) {
    return codexTranscriptionAuthCache.context;
  }
  if (!options.forceRefresh && codexTranscriptionAuthInFlight) {
    return codexTranscriptionAuthInFlight;
  }
  if (options.forceRefresh) clearCodexTranscriptionAuthCache();
  codexTranscriptionAuthInFlight = fetchCodexTranscriptionAuthContext(true)
    .then((context) => {
      codexTranscriptionAuthCache = {
        context,
        expiresAt: Date.now() + codexTranscriptionAuthCacheMs
      };
      return context;
    })
    .finally(() => {
      codexTranscriptionAuthInFlight = null;
    });
  return codexTranscriptionAuthInFlight;
}

async function prewarmCodexTranscriptionAuthContext() {
  await resolveCodexTranscriptionAuthContext();
  return { ok: true };
}

function screenAnalysisImageResultFromFields(fields: Pick<ChatMessage, "imageDataURL" | "imagePrompt" | "imageMimeType" | "imageName">) {
  if (!fields.imageDataURL) return null;
  return {
    dataURL: fields.imageDataURL,
    mimeType: fields.imageMimeType || "image/png",
    name: fields.imageName || "openassist-generated-image.png",
    prompt: fields.imagePrompt
  };
}

function waitForCodexThreadTurnComplete(providerThreadID: string, getTurnID: () => string) {
  return new Promise<{ turnID?: string; failed?: boolean; error?: string }>((resolve) => {
    const done = (method: string, params: JsonObject) => {
      if (method !== "turn/completed" && method !== "turn/failed") return;
      const incomingThreadID = firstRuntimeString(params.threadId, params.threadID);
      if (incomingThreadID && incomingThreadID !== providerThreadID) return;
      const turn = runtimeObject(params.turn);
      const incomingTurnID = firstRuntimeString(params.turnId, params.turnID, turn?.id);
      const expectedTurnID = getTurnID();
      if (expectedTurnID && incomingTurnID && incomingTurnID !== expectedTurnID) return;
      codexTransport.off("notification", done);
      resolve({
        turnID: incomingTurnID || expectedTurnID,
        failed: method === "turn/failed",
        error: providerErrorMessage(params)
      });
    };
    codexTransport.on("notification", done);
  });
}

async function analyzeScreenWithCodexImageGeneration(
  imageBuffer: Buffer,
  promptText: string,
  referenceImages: Array<{ name: string; data: Buffer; mimeType: string }> = [],
  callback: (text: string) => void
): Promise<{
  text: string;
  images: Array<{ dataURL: string; mimeType: string; name: string; prompt?: string }>;
  tools: { webSearch: boolean; imageGeneration: boolean };
}> {
  const settings = await loadSettings();
  const model = normalizedModelForBackend("codex", settings.model || readCodexDefaultModel());
  const started = await codexTransport.request("thread/start", {
    approvalPolicy: "on-request",
    sandbox: "workspace-write",
    cwd: openAssistRepoRoot(),
    model,
    personality: "friendly",
    serviceName: "Open Assist Screen Analysis",
    ephemeral: true,
    experimentalRawEvents: false,
    persistExtendedHistory: true
  }) as JsonObject;
  const thread = runtimeObject(started.thread);
  const providerThreadID = firstRuntimeString(thread?.id);
  if (!providerThreadID) throw new Error("Codex did not return a screen-analysis thread id.");

  const primaryImageURL = `data:image/png;base64,${imageBuffer.toString("base64")}`;
  const input: JsonObject[] = dedupeInputItems([
    ...imageGenerationSkillPromptItems(promptText),
    {
      type: "text",
      text: [
        "Generate an actual image for the user's request.",
        "Do not only write a prompt or describe what should be generated.",
        "Use the attached screenshot only as visual/context reference when helpful.",
        "",
        `User request: ${promptText}`
      ].join("\n"),
      text_elements: []
    },
    { type: "image", url: primaryImageURL },
    ...referenceImages.flatMap((image, index) => [
      {
        type: "text",
        text: `Reference image ${index + 1}: ${image.name || "Image"}`,
        text_elements: []
      },
      {
        type: "image",
        url: `data:${image.mimeType || "image/png"};base64,${image.data.toString("base64")}`
      }
    ] as JsonObject[])
  ]);

  let responseText = "";
  let providerTurnID = "";
  const images: Array<{ dataURL: string; mimeType: string; name: string; prompt?: string }> = [];
  const imageKeys = new Set<string>();
  const appendImage = (item: JsonObject) => {
    const result = screenAnalysisImageResultFromFields(imageGenerationMessageFields(item));
    if (!result) return;
    const key = result.dataURL.slice(0, 160);
    if (imageKeys.has(key)) return;
    imageKeys.add(key);
    images.push(result);
    callback("Generated image is ready.");
  };
  const onNotification = (method: string, params: JsonObject, requestID?: JsonRequestID) => {
    const turn = runtimeObject(params.turn);
    const notificationTurnID = firstRuntimeString(params.turnId, params.turnID, turn?.id);
    if (notificationTurnID) providerTurnID = notificationTurnID;
    if (method === "item/agentMessage/delta" && typeof params.delta === "string") {
      const channel = String(params.channel ?? "").toLowerCase();
      if (channel !== "commentary") {
        responseText += params.delta;
        callback(responseText);
      }
    }
    const item = runtimeItemPayload(params);
    if (runtimeActivityKind(method, item) === "imageGeneration") {
      appendImage(item);
    }
  };

  callback("Generating image...");
  codexTransport.on("notification", onNotification);
  try {
    const turnComplete = waitForCodexThreadTurnComplete(providerThreadID, () => providerTurnID);
    const startedTurn = await codexTransport.request("turn/start", {
      threadId: providerThreadID,
      input,
      approvalPolicy: "on-request",
      effort: "low"
    }) as JsonObject;
    const turn = runtimeObject(startedTurn.turn);
    providerTurnID = firstRuntimeString(turn?.id, providerTurnID);
    const completed = await turnComplete;
    if (completed.failed) {
      throw new Error(completed.error || "Codex image generation failed.");
    }
  } finally {
    codexTransport.off("notification", onNotification);
  }

  return {
    text: responseText.trim() || (images.length ? "Generated image is ready." : "Image generation finished, but no image came back."),
    images,
    tools: {
      webSearch: false,
      imageGeneration: true
    }
  };
}

async function analyzeScreenWithCodex(
  imageBuffer: Buffer,
  instruction: string | undefined,
  referenceImages: Array<{ name: string; data: Buffer; mimeType: string }> = [],
  callback: (text: string) => void
): Promise<{
  text: string;
  images: Array<{ dataURL: string; mimeType: string; name: string; prompt?: string }>;
  tools: { webSearch: boolean; imageGeneration: boolean };
}> {
  const promptText = instruction && instruction.trim()
    ? instruction.trim()
    : "Explain what is on my screen or answer any visible questions or problems.";
  if (promptWantsImageGeneration(promptText)) {
    return analyzeScreenWithCodexImageGeneration(imageBuffer, promptText, referenceImages, callback);
  }

  const auth = await resolveCodexTranscriptionAuthContext();
  const settings = await loadSettings();
  let model = settings.model || "gpt-4o";
  if (!model.startsWith("gpt-") && !model.startsWith("o1") && !model.startsWith("o3")) {
    model = "gpt-4o";
  }

  const base64Image = imageBuffer.toString("base64");
  const imageDataURL = `data:image/png;base64,${base64Image}`;
  const referenceContent = referenceImages.flatMap((image, index) => [
    {
      type: "input_text",
      text: `Reference image ${index + 1}: ${image.name || "Image"}`
    },
    {
      type: "input_image",
      image_url: `data:${image.mimeType || "image/png"};base64,${image.data.toString("base64")}`
    }
  ]);
  const lowerPrompt = promptText.toLowerCase();
  const wantsWebSearch = /\b(web|search|browse|browser|internet|online|latest|current|today|news|verify|source|look\s*up|find\s+out|google|x\/twitter|tweet|post)\b/.test(lowerPrompt);
  const tools: JsonObject[] = [];
  if (wantsWebSearch) tools.push({ type: "web_search" });
  const analysisInstructions = "You are a helpful assistant. Analyze the screenshot provided by the user and answer their question directly, clearly, and concisely. Reply in plain text. Do not use Markdown formatting symbols unless the user explicitly asks for Markdown. If web_search is available and the user asks for current, online, latest, search, source, or verification work, use it.";

  const payload: JsonObject = {
    model: model,
    store: false,
    stream: true,
    instructions: analysisInstructions,
    input: [
      {
        role: "system",
        content: [
          { type: "input_text", text: analysisInstructions }
        ]
      },
      {
        role: "user",
        content: [
          { type: "input_text", text: promptText },
          { type: "input_text", text: "Primary screenshot:" },
          { type: "input_image", image_url: imageDataURL },
          ...referenceContent
        ]
      }
    ]
  };
  if (tools.length) {
    payload.tools = tools;
    payload.tool_choice = "auto";
  }

  const response = await fetchWithTimeout("https://chatgpt.com/backend-api/codex/responses", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${auth.token}`,
      "Content-Type": "application/json",
      "User-Agent": chatGPTWebUserAgent,
      "Origin": "https://chatgpt.com"
    },
    body: JSON.stringify(payload)
  }, 60000, "Codex screen analysis request timed out.");

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Codex API request failed: ${response.status} ${errorText}`);
  }

  const reader = response.body?.getReader();
  if (!reader) {
    throw new Error("Response body is not readable");
  }

  const decoder = new TextDecoder();
  let buffer = "";
  let fullText = "";
  const generatedImages: Array<{ dataURL: string; mimeType: string; name: string; prompt?: string }> = [];
  const generatedImageKeys = new Set<string>();
  const appendText = (text: string) => {
    if (!text) return;
    fullText += text;
    callback(fullText);
  };
  const replaceText = (text: string) => {
    fullText = text;
    callback(fullText);
  };
  const applyTextDelta = (delta: unknown) => {
    if (typeof delta === "string") appendText(delta);
    else if (delta && typeof delta === "object" && typeof (delta as { text?: unknown }).text === "string") {
      appendText((delta as { text: string }).text);
    }
  };
  const applyFullText = (text: unknown) => {
    if (typeof text === "string") replaceText(text);
  };
  const textFromContent = (content: unknown): string | undefined => {
    if (!Array.isArray(content)) return undefined;
    const parts: string[] = [];
    for (const entry of content) {
      if (!entry || typeof entry !== "object") continue;
      const text = (entry as { text?: unknown }).text;
      if (typeof text === "string") parts.push(text);
    }
    return parts.length ? parts.join("") : undefined;
  };
  const firstString = (...values: unknown[]) => {
    for (const value of values) {
      if (typeof value === "string" && value.trim()) return value.trim();
    }
    return "";
  };
  const mimeTypeForGeneratedImage = (base64: string) => {
    const header = Buffer.from(base64.slice(0, 48), "base64");
    if (header.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
    if (header.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff]))) return "image/jpeg";
    if (header.subarray(0, 4).toString("ascii") === "RIFF" && header.subarray(8, 12).toString("ascii") === "WEBP") return "image/webp";
    return "image/png";
  };
  const maybeAddGeneratedImage = (rawValue: unknown, prompt?: string) => {
    if (typeof rawValue !== "string") return;
    const trimmed = rawValue.trim();
    const dataURLMatch = /^data:(image\/[a-zA-Z0-9+.-]+);base64,(.+)$/.exec(trimmed);
    const base64 = dataURLMatch ? dataURLMatch[2] : trimmed;
    if (base64.length < 200 || /[^a-zA-Z0-9+/=]/.test(base64)) return;
    const key = base64.slice(0, 96);
    if (generatedImageKeys.has(key)) return;
    generatedImageKeys.add(key);
    const mimeType = dataURLMatch?.[1] || mimeTypeForGeneratedImage(base64);
    generatedImages.push({
      dataURL: `data:${mimeType};base64,${base64}`,
      mimeType,
      name: `openassist-generated-${generatedImages.length + 1}${mimeType === "image/jpeg" ? ".jpg" : mimeType === "image/webp" ? ".webp" : ".png"}`,
      prompt
    });
  };
  const collectGeneratedImages = (value: unknown) => {
    if (!value || typeof value !== "object") return;
    if (Array.isArray(value)) {
      value.forEach(collectGeneratedImages);
      return;
    }
    const object = value as JsonObject;
    const rawType = String(object.type ?? object.kind ?? object.name ?? "");
    const isImageGeneration = rawType.includes("image_generation") || rawType.includes("image-generation");
    if (isImageGeneration) {
      const prompt = firstString(object.revised_prompt, object.revisedPrompt, object.prompt);
      maybeAddGeneratedImage(object.result, prompt);
      maybeAddGeneratedImage(object.image, prompt);
      maybeAddGeneratedImage(object.b64_json, prompt);
      maybeAddGeneratedImage(object.base64, prompt);
      maybeAddGeneratedImage(object.data, prompt);
    }
    for (const nestedValue of Object.values(object)) {
      if (nestedValue && typeof nestedValue === "object") collectGeneratedImages(nestedValue);
    }
  };
  const extractOutputText = (value: unknown): string | undefined => {
    if (!value || typeof value !== "object") return undefined;
    const directText = (value as { text?: unknown; output_text?: unknown }).text
      ?? (value as { text?: unknown; output_text?: unknown }).output_text;
    if (typeof directText === "string") return directText;
    const contentText = textFromContent((value as { content?: unknown }).content);
    if (contentText) return contentText;
    const output = (value as { output?: unknown }).output;
    if (!Array.isArray(output)) return undefined;
    const parts: string[] = [];
    for (const item of output) {
      const text = extractOutputText(item);
      if (text) parts.push(text);
    }
    return parts.length ? parts.join("") : undefined;
  };
  const handleStreamEvent = (event: unknown) => {
    if (!event || typeof event !== "object") return;
    const typedEvent = event as {
      type?: string;
      delta?: unknown;
      text?: unknown;
      item?: unknown;
      part?: unknown;
      response?: unknown;
      output_text?: unknown;
      error?: { message?: unknown };
    };
    collectGeneratedImages(event);
    if (typedEvent.type === "response.failed") {
      throw new Error(
        (typedEvent.response as { error?: { message?: unknown } } | undefined)?.error?.message as string
          || typedEvent.error?.message as string
          || "Screen analysis failed."
      );
    }
    if (typedEvent.type?.endsWith(".delta")) {
      applyTextDelta(typedEvent.delta);
      return;
    }
    if (typedEvent.type?.endsWith(".done")) {
      applyFullText(
        typedEvent.text
          ?? extractOutputText(typedEvent.item)
          ?? extractOutputText(typedEvent.part)
          ?? typedEvent.output_text
      );
      return;
    }
    if (typedEvent.type === "response.completed") {
      applyFullText(extractOutputText(typedEvent.response));
      return;
    }
    applyTextDelta(typedEvent.delta);
    applyFullText(typedEvent.output_text ?? extractOutputText(typedEvent.response));
  };
  const handleDataPayload = (dataStr: string) => {
    if (!dataStr.trim() || dataStr.trim() === "[DONE]") return;
    handleStreamEvent(JSON.parse(dataStr));
  };

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("data: ")) continue;
        const dataStr = trimmed.slice(6);
        if (dataStr === "[DONE]") continue;
        try {
          handleDataPayload(dataStr);
        } catch (e) {
          if (e instanceof SyntaxError) {
            // ignore parsing error for partial lines
            continue;
          }
          throw e;
        }
      }
    }
    const trailing = buffer.trim();
    if (trailing.startsWith("data: ")) {
      try {
        handleDataPayload(trailing.slice(6));
      } catch (error) {
        if (!(error instanceof SyntaxError)) throw error;
      }
    } else if (trailing.startsWith("{")) {
      try {
        const parsed = JSON.parse(trailing);
        collectGeneratedImages(parsed);
        applyFullText(extractOutputText(parsed));
      } catch (error) {
        if (!(error instanceof SyntaxError)) throw error;
      }
    }
  } finally {
    reader.releaseLock();
  }

  return {
    text: fullText,
    images: generatedImages,
    tools: {
      webSearch: wantsWebSearch,
      imageGeneration: false
    }
  };
}

async function postChatGPTTranscription({
  auth,
  audio,
  fileName,
  mimeType
}: {
  auth: CodexTranscriptionAuthContext;
  audio: Buffer;
  fileName: string;
  mimeType: string;
}) {
  const { boundary, body } = makeMultipartFormData({
    fields: [],
    fileFieldName: "file",
    fileName,
    fileMimeType: mimeType,
    fileData: audio
  });
  return fetchWithTimeout(chatGPTTranscriptionsURL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${auth.token}`,
      "Content-Type": `multipart/form-data; boundary=${boundary}`,
      "User-Agent": chatGPTWebUserAgent,
      Origin: "https://chatgpt.com",
      Referer: "https://chatgpt.com/",
      Accept: "application/json, text/plain, */*",
      "Accept-Language": "en-US,en;q=0.9"
    },
    body: body as never
  }, transcriptionRequestTimeoutMs, "ChatGPT session transcription timed out. Check your connection, then try again.");
}

async function transcribeWithCodexSession({
  audio,
  model,
  fileName,
  mimeType
}: {
  audio: Buffer;
  model: string;
  fileName: string;
  mimeType: string;
}) {
  ensureUploadableAudio(audio);
  let auth = await resolveCodexTranscriptionAuthContext();
  if (auth.authMode === "apiKey") {
    return transcribeWithOpenAICompatibleAPI({
      audio,
      provider: "OpenAI",
      model,
      baseURL: cloudTranscriptionDefaultBaseURL("OpenAI"),
      apiKey: auth.token,
      fileName,
      mimeType
    });
  }
  let response = await postChatGPTTranscription({ auth, audio, fileName, mimeType });
  if (response.status === 401 || response.status === 403) {
    clearCodexTranscriptionAuthCache();
    auth = await resolveCodexTranscriptionAuthContext({ forceRefresh: true });
    if (auth.authMode === "apiKey") {
      return transcribeWithOpenAICompatibleAPI({
        audio,
        provider: "OpenAI",
        model,
        baseURL: cloudTranscriptionDefaultBaseURL("OpenAI"),
        apiKey: auth.token,
        fileName,
        mimeType
      });
    }
    response = await postChatGPTTranscription({ auth, audio, fileName, mimeType });
  }
  const payload = await responsePayload(response);
  if (response.status === 401 || response.status === 403) {
    clearCodexTranscriptionAuthCache();
    throw new Error("Your ChatGPT session expired. Sign in again in Open Assist to keep using session transcription, or switch to another provider in Settings > Voice & Dictation.");
  }
  if (!response.ok) throw new Error(providerErrorFromPayload(payload.json, payload.body, response.status));
  const text = decodeOpenAICompatibleText(payload.json);
  if (text) return text;
  throw new Error("ChatGPT / Codex Session returned an unsupported transcription response.");
}

async function voiceInputConfiguration() {
  const settings = await loadSettings();
  return {
    transcriptionEngine: settings.transcriptionEngine,
    whisperModel: settings.whisperModel,
    whisperUseCoreML: settings.whisperUseCoreML,
    whisperModelInstalled: settings.whisperModelInstalled,
    whisperInstalledModels: settings.whisperInstalledModels,
    cloudTranscriptionProvider: settings.cloudTranscriptionProvider,
    cloudTranscriptionModel: settings.cloudTranscriptionModel,
    cloudTranscriptionBaseURL: settings.cloudTranscriptionBaseURL,
    cloudTranscriptionProviderRequiresKey: cloudTranscriptionProviderRequiresKey(settings.cloudTranscriptionProvider),
    cloudTranscriptionAPIKeyConfigured: settings.cloudTranscriptionAPIKeyConfigured,
    dictationStartSoundName: settings.dictationStartSoundName,
    dictationStopSoundName: settings.dictationStopSoundName,
    dictationProcessingSoundName: settings.dictationProcessingSoundName,
    dictationPastedSoundName: settings.dictationPastedSoundName,
    dictationCorrectionLearnedSoundName: settings.dictationCorrectionLearnedSoundName,
    dictationFeedbackVolume: settings.dictationFeedbackVolume
  };
}

async function cloudVoiceInputReadiness() {
  const settings = await loadSettings();
  if (settings.transcriptionEngine !== "Cloud Providers") {
    return { ok: false, error: "Cloud voice input is not the selected transcription engine." };
  }

  const provider = settings.cloudTranscriptionProvider;
  if (provider === "ChatGPT / Codex Session") {
    try {
      await resolveCodexTranscriptionAuthContext();
      return { ok: true };
    } catch (error) {
      return {
        ok: false,
        error: error instanceof Error ? error.message : "ChatGPT session transcription is not ready."
      };
    }
  }

  const apiKey = await readKeychainPassword(cloudTranscriptionKeychainAccount(provider));
  if (!apiKey.trim()) {
    return {
      ok: false,
      error: `${provider} transcription needs an API key in Settings > Voice & Dictation.`
    };
  }

  return { ok: true };
}

async function transcribeAudioFile(input: AudioTranscriptionFile) {
  const settings = await loadSettings();
  if (settings.transcriptionEngine !== "Cloud Providers") {
    throw new Error("Cloud transcription is not the selected voice engine.");
  }
  if (!fs.existsSync(input.filePath)) throw new Error("Captured audio file was not found.");
  const audio = fs.readFileSync(input.filePath);
  const provider = settings.cloudTranscriptionProvider;
  const model = settings.cloudTranscriptionModel || cloudTranscriptionDefaultModel(provider);
  const baseURL = settings.cloudTranscriptionBaseURL || cloudTranscriptionDefaultBaseURL(provider);
  const fileName = normalizedFileName(input.fileName, "voice-input.wav");
  const mimeType = normalizedMimeType(input.mimeType, "audio/wav");
  if (provider === "ChatGPT / Codex Session") {
    return transcribeWithCodexSession({ audio, model, fileName, mimeType });
  }
  const apiKey = await readKeychainPassword(cloudTranscriptionKeychainAccount(provider));
  if (provider === "OpenAI" || provider === "Groq") {
    return transcribeWithOpenAICompatibleAPI({ audio, provider, model, baseURL, apiKey, fileName, mimeType });
  }
  if (provider === "Deepgram") {
    return transcribeWithDeepgram({ audio, model, baseURL, apiKey, mimeType });
  }
  if (provider === "Google Gemini (AI Studio)") {
    return transcribeWithGemini({ audio, model, baseURL, apiKey, mimeType });
  }
  throw new Error("Cloud transcription provider must match a native OpenAssist provider.");
}

function clampPercent(value: number) {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(100, Math.round(value)));
}

function numberFromUnknown(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return undefined;
}

function parseResetDate(value: unknown): Date | undefined {
  const numeric = numberFromUnknown(value);
  if (numeric != null) {
    return new Date(numeric > 10_000_000_000 ? numeric : numeric * 1000);
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = new Date(value);
    if (Number.isFinite(parsed.getTime())) return parsed;
  }
  return undefined;
}

function resetLabel(date?: Date) {
  if (!date) return null;
  const diff = date.getTime() - Date.now();
  if (diff <= 0) return "now";
  const minutes = Math.round(diff / 60_000);
  if (minutes < 90) return `${Math.max(1, minutes)}m`;
  const hours = Math.round(minutes / 60);
  if (hours < 36) return `${hours}h`;
  return `${Math.round(hours / 24)}d`;
}

function usageWindowLabel(windowDurationMins?: number, fallback = "Usage") {
  if (!windowDurationMins || windowDurationMins <= 0) return fallback;
  if (windowDurationMins >= 10_080) return "Weekly";
  if (windowDurationMins >= 1_440) return "Daily";
  const hours = Math.floor(windowDurationMins / 60);
  return hours > 0 ? `${hours}h` : `${windowDurationMins}m`;
}

function makeUsageWindow(rawValue: unknown, fallbackLabel: string): UsageWindowSnapshot | null {
  const raw = asObject(rawValue);
  if (!raw) return null;
  const usedPercent =
    numberFromUnknown(raw.usedPercent)
    ?? numberFromUnknown(raw.used_percent)
    ?? numberFromUnknown(raw.utilization)
    ?? numberFromUnknown(raw.usagePercent)
    ?? numberFromUnknown(raw.usage_percent);
  if (usedPercent == null) return null;
  const windowDurationMins =
    numberFromUnknown(raw.windowDurationMins)
    ?? numberFromUnknown(raw.window_minutes)
    ?? numberFromUnknown(raw.windowMinutes)
    ?? numberFromUnknown(raw.window_duration_mins);
  const resetsAt = parseResetDate(raw.resetsAt ?? raw.resets_at);
  return {
    label: usageWindowLabel(windowDurationMins, fallbackLabel),
    usedPercent: clampPercent(usedPercent),
    resetsAt: resetsAt?.toISOString() ?? null,
    resetsInLabel: resetLabel(resetsAt)
  };
}

function makeContextUsage(rawValue: unknown): ContextUsageSnapshot | null {
  const raw = asObject(rawValue);
  if (!raw) return null;
  const last = asObject(raw.last) ?? {};
  const currentContextTokens =
    numberFromUnknown(last.inputTokens)
    ?? numberFromUnknown(last.input_tokens)
    ?? numberFromUnknown(raw.currentContextTokens)
    ?? 0;
  const modelContextWindow =
    numberFromUnknown(raw.modelContextWindow)
    ?? numberFromUnknown(raw.model_context_window);
  if (!modelContextWindow || modelContextWindow <= 0) return null;
  const usedPercent = clampPercent((currentContextTokens / modelContextWindow) * 100);
  const summary = `${formatTokenCount(currentContextTokens)} / ${formatTokenCount(modelContextWindow)}`;
  return {
    usedPercent,
    summary,
    detail: `${usedPercent}% of context used`
  };
}

function formatTokenCount(count: number) {
  if (count >= 1_000_000) return `${(count / 1_000_000).toFixed(1)}M`;
  if (count >= 1_000) return `${(count / 1_000).toFixed(1)}K`;
  return String(Math.max(0, Math.round(count)));
}

const runtimeUsageByBackend: Partial<Record<RuntimeAssistantBackend, ProviderUsageSnapshot>> = {};

function makeProviderUsage(
  backend: RuntimeAssistantBackend,
  primary: UsageWindowSnapshot | null,
  secondary: UsageWindowSnapshot | null,
  context: ContextUsageSnapshot | null,
  planType?: string | null
): ProviderUsageSnapshot | null {
  if (backend === "ollamaLocal") return null;
  if (!primary && !secondary && !context) return null;
  return {
    providerBackend: backend,
    providerLabel: providerLabel(backend),
    planType: planType ?? null,
    primary,
    secondary,
    context
  };
}

function recordTokenUsage(backend: RuntimeAssistantBackend, tokenUsage: unknown) {
  const context = makeContextUsage(tokenUsage);
  if (!context) return;
  const existing = runtimeUsageByBackend[backend];
  runtimeUsageByBackend[backend] = makeProviderUsage(
    backend,
    existing?.primary ?? null,
    existing?.secondary ?? null,
    context,
    existing?.planType ?? null
  ) ?? existing;
}

function recordRateLimits(backend: RuntimeAssistantBackend, payload: unknown) {
  const object = asObject(payload);
  if (!object) return;
  const defaultBucket = asObject(object.rateLimits) ?? asObject(object.rate_limits) ?? object;
  const primary = makeUsageWindow(defaultBucket.primary, "5h");
  const secondary = makeUsageWindow(defaultBucket.secondary, "Weekly");
  if (!primary && !secondary) return;
  const existing = runtimeUsageByBackend[backend];
  runtimeUsageByBackend[backend] = makeProviderUsage(
    backend,
    primary,
    secondary,
    existing?.context ?? null,
    pluginString(defaultBucket.planType) ?? pluginString(defaultBucket.plan_type) ?? existing?.planType ?? null
  ) ?? existing;
}

function recordUsageNotification(backend: RuntimeAssistantBackend, method: string, params: JsonObject) {
  if (method === "thread/tokenUsage/updated" || params.tokenUsage || params.token_usage) {
    recordTokenUsage(backend, params.tokenUsage ?? params.token_usage);
  }
  if (
    method === "thread/rateLimits/updated"
    || method === "account/rateLimits/updated"
    || params.rateLimits
    || params.rate_limits
  ) {
    recordRateLimits(backend, params);
  }
}

function claudeCachedUsage(): ProviderUsageSnapshot | null {
  for (const cachePath of claudeUsageCachePaths()) {
    if (!fs.existsSync(cachePath)) continue;
    const payload = readJSON<JsonObject>(cachePath, {});
    const primary = makeUsageWindow(payload.five_hour, "5h");
    const secondary = makeUsageWindow(payload.seven_day, "Weekly");
    const existing = runtimeUsageByBackend.claudeCode;
    const usage = makeProviderUsage(
      "claudeCode",
      primary,
      secondary,
      existing?.context ?? null,
      pluginString(payload.planType, payload.plan_type, payload.rateLimitTier, payload.rate_limit_tier, existing?.planType)
    );
    if (usage) {
      runtimeUsageByBackend.claudeCode = usage;
      return usage;
    }
  }
  return runtimeUsageByBackend.claudeCode ?? null;
}

function usageSnapshotForBackend(backend: RuntimeAssistantBackend): ProviderUsageSnapshot | null {
  if (backend === "claudeCode") return claudeCachedUsage();
  if (backend === "ollamaLocal") return null;
  return runtimeUsageByBackend[backend] ?? null;
}

function claudeUsageCachePaths() {
  const roots: string[] = [];
  const configured = process.env.CLAUDE_CONFIG_DIR?.split(",")
    .map((value) => value.trim())
    .filter(Boolean) ?? [];
  roots.push(...configured);
  if (process.env.XDG_CONFIG_HOME?.trim()) {
    roots.push(path.join(process.env.XDG_CONFIG_HOME.trim(), "claude"));
  }
  roots.push(path.join(os.homedir(), ".claude"));
  roots.push(path.join(os.homedir(), ".config", "claude"));
  return uniquePaths(roots.map((root) => path.join(root, "usage-cache.json")));
}

function uniquePaths(paths: string[]) {
  const seen = new Set<string>();
  return paths.filter((candidate) => {
    const normalized = path.normalize(candidate);
    if (!normalized || seen.has(normalized)) return false;
    seen.add(normalized);
    return true;
  });
}

function copilotConfigPaths() {
  const paths: string[] = [];
  if (process.env.XDG_CONFIG_HOME?.trim()) {
    const root = process.env.XDG_CONFIG_HOME.trim();
    paths.push(path.join(root, "config.json"));
    paths.push(path.join(root, "copilot", "config.json"));
  }
  paths.push(path.join(os.homedir(), ".copilot", "config.json"));
  return uniquePaths(paths);
}

function copilotStoredAccounts(config: JsonObject | null) {
  const accounts: string[] = [];
  const seen = new Set<string>();
  const append = (value: unknown) => {
    const user = asObject(value);
    const host = pluginString(user?.host);
    const login = pluginString(user?.login);
    if (!host || !login) return;
    const account = `${host}:${login}`;
    const normalized = account.toLowerCase();
    if (seen.has(normalized)) return;
    seen.add(normalized);
    accounts.push(account);
  };

  append(config?.last_logged_in_user);
  if (Array.isArray(config?.logged_in_users)) config.logged_in_users.forEach(append);
  return accounts;
}

function readCopilotStoredConfig() {
  for (const configPath of copilotConfigPaths()) {
    if (!fs.existsSync(configPath)) continue;
    const config = readJSON<JsonObject | null>(configPath, null);
    if (config) return config;
  }
  return null;
}

function readCopilotPlaintextToken(config: JsonObject | null) {
  if (config?.store_token_plaintext !== true) return "";
  const tokens = asObject(config?.copilot_tokens);
  if (!tokens) return "";
  const accounts = copilotStoredAccounts(config);
  for (const account of accounts) {
    const token = pluginString(tokens[account]);
    if (token) return token;
  }
  for (const value of Object.values(tokens)) {
    const token = pluginString(value);
    if (token) return token;
  }
  return "";
}

async function readGitHubCLIToken() {
  const rawHost = process.env.GH_HOST?.trim() || "github.com";
  let hostname = rawHost;
  try {
    hostname = new URL(rawHost).host || rawHost;
  } catch {
    hostname = rawHost;
  }
  try {
    const { stdout } = await execFileAsync("/usr/bin/env", ["gh", "auth", "token", "--hostname", hostname], {
      env: { ...process.env, PATH: assistantPATH() },
      timeout: 2500
    });
    return stdout.trim();
  } catch {
    return "";
  }
}

async function resolveCopilotGitHubToken() {
  for (const key of ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"]) {
    const token = process.env[key]?.trim();
    if (token) return token;
  }

  const config = readCopilotStoredConfig();
  const plaintextToken = readCopilotPlaintextToken(config);
  if (plaintextToken) return plaintextToken;

  const ghToken = await readGitHubCLIToken();
  if (ghToken) return ghToken;

  for (const account of copilotStoredAccounts(config)) {
    const token = await readGenericKeychainPassword("copilot-cli", account);
    if (token) return token;
  }

  return await readGenericKeychainPassword("copilot-cli", "github.com")
    || await readGenericKeychainPassword("copilot-cli", null);
}

function copilotQuotaSnapshot(rawValue: unknown) {
  const raw = asObject(rawValue);
  if (!raw) return null;
  const entitlement = numberFromUnknown(raw.entitlement) ?? 0;
  const remaining = numberFromUnknown(raw.remaining) ?? 0;
  const percentRemaining =
    numberFromUnknown(raw.percent_remaining)
    ?? numberFromUnknown(raw.percentRemaining)
    ?? (entitlement > 0 ? (remaining / entitlement) * 100 : undefined);
  const quotaID = pluginString(raw.quota_id, raw.quotaID) ?? "";
  if (entitlement === 0 && remaining === 0 && (percentRemaining ?? 0) === 0 && !quotaID) return null;
  if (percentRemaining == null) return null;
  return {
    usedPercent: clampPercent(100 - percentRemaining),
    unlimited: raw.unlimited === true
  };
}

function copilotQuotaFromCounts(monthlyValue: unknown, limitedValue: unknown) {
  const monthly = numberFromUnknown(monthlyValue);
  const limited = numberFromUnknown(limitedValue);
  if (!monthly || monthly <= 0 || limited == null) return null;
  return {
    usedPercent: clampPercent(100 - (limited / monthly) * 100),
    unlimited: false
  };
}

function copilotUsageFromPayload(payload: JsonObject): ProviderUsageSnapshot | null {
  const quotaSnapshots = asObject(payload.quota_snapshots);
  const monthlyQuotas = asObject(payload.monthly_quotas);
  const limitedQuotas = asObject(payload.limited_user_quotas);
  let premium = copilotQuotaSnapshot(quotaSnapshots?.premium_interactions)
    ?? copilotQuotaFromCounts(monthlyQuotas?.completions, limitedQuotas?.completions);
  let chat = copilotQuotaSnapshot(quotaSnapshots?.chat)
    ?? copilotQuotaFromCounts(monthlyQuotas?.chat, limitedQuotas?.chat);

  if (quotaSnapshots && (!premium || !chat)) {
    let firstUsable: ReturnType<typeof copilotQuotaSnapshot> = null;
    for (const [key, value] of Object.entries(quotaSnapshots)) {
      const snapshot = copilotQuotaSnapshot(value);
      if (!snapshot) continue;
      firstUsable ??= snapshot;
      const normalizedKey = key.toLowerCase();
      if (!chat && normalizedKey.includes("chat")) chat = snapshot;
      if (!premium && (normalizedKey.includes("premium") || normalizedKey.includes("completion") || normalizedKey.includes("code"))) {
        premium = snapshot;
      }
    }
    if (!premium && !chat) chat = firstUsable;
  }

  const primary = premium ? makeUsageWindow(premium, "Premium") : null;
  const secondary = chat ? makeUsageWindow(chat, "Chat") : null;
  const existing = runtimeUsageByBackend.copilot;
  return makeProviderUsage(
    "copilot",
    primary,
    secondary,
    existing?.context ?? null,
    pluginString(payload.copilot_plan, payload.planType, payload.plan_type, existing?.planType)
  );
}

function usageSnapshotsByBackend(): Partial<Record<RuntimeAssistantBackend, ProviderUsageSnapshot | null>> {
  return {
    codex: usageSnapshotForBackend("codex"),
    copilot: usageSnapshotForBackend("copilot"),
    claudeCode: usageSnapshotForBackend("claudeCode"),
    ollamaLocal: null
  };
}

function readCodexDefaultModel() {
  try {
    const config = fs.readFileSync(codexConfigPath(), "utf8");
    const match = /^\s*model\s*=\s*"([^"]+)"/m.exec(config);
    return match?.[1]?.trim() || "gpt-5.5";
  } catch {
    return "gpt-5.5";
  }
}

function providerModelOption(id: string, displayName = id, description = displayName): ProviderModelOption {
  return { id, displayName, description, hidden: false, isInstalled: true };
}

function fallbackModelOptionsForBackend(backend: AssistantBackend): ProviderModelOption[] {
  if (backend === "copilot") {
    return [
      providerModelOption("auto", "Auto", "Let Copilot pick the best model"),
      providerModelOption("gpt-5.4", "GPT-5.4"),
      providerModelOption("gpt-5.3-codex", "GPT-5.3-Codex"),
      providerModelOption("gpt-5.2-codex", "GPT-5.2-Codex"),
      providerModelOption("gpt-5.2", "GPT-5.2"),
      providerModelOption("gpt-5.4-mini", "GPT-5.4 mini"),
      providerModelOption("gpt-5-mini", "GPT-5 mini"),
      providerModelOption("gpt-4.1", "GPT-4.1"),
      providerModelOption("claude-sonnet-4.6", "Claude Sonnet 4.6"),
      providerModelOption("claude-sonnet-4.5", "Claude Sonnet 4.5"),
      providerModelOption("claude-haiku-4.5", "Claude Haiku 4.5")
    ];
  }
  if (backend === "claudeCode") {
    return [
      providerModelOption("sonnet", "Claude Sonnet", "Balanced Claude Code model alias"),
      providerModelOption("opus", "Claude Opus", "Higher-capability Claude Code model alias"),
      providerModelOption("haiku", "Claude Haiku", "Fast Claude Code model alias")
    ];
  }
  if (backend === "ollamaLocal") {
    return [
      providerModelOption("gemma4:e2b", "gemma4:e2b"),
      providerModelOption("llama3.1", "llama3.1"),
      providerModelOption("gpt-oss:20b", "gpt-oss:20b")
    ];
  }
  return [
    providerModelOption(readCodexDefaultModel(), readCodexDefaultModel()),
    providerModelOption("gpt-5.5", "GPT-5.5"),
    providerModelOption("gpt-5.4", "GPT-5.4"),
    providerModelOption("gpt-5.2", "GPT-5.2"),
    providerModelOption("gpt-5.3-codex", "GPT-5.3-Codex")
  ];
}

function uniqueProviderModels(models: ProviderModelOption[]) {
  const seen = new Set<string>();
  return models.filter((model) => {
    const normalized = model.id.trim().toLowerCase();
    if (!normalized || seen.has(normalized)) return false;
    seen.add(normalized);
    return true;
  });
}

function flattenCopilotConfigOptions(rawOptions: unknown): JsonObject[] {
  if (!Array.isArray(rawOptions)) return [];
  const flattened: JsonObject[] = [];
  for (const item of rawOptions) {
    const object = asObject(item);
    if (!object) continue;
    if (object.value !== undefined || object.modelId !== undefined) {
      flattened.push(object);
      continue;
    }
    flattened.push(...flattenCopilotConfigOptions(object.options));
  }
  return flattened;
}

function copilotModelFromRow(row: JsonObject, currentModelID?: string): ProviderModelOption | null {
  const id = pluginString(row.modelId, row.value)?.trim();
  if (!id) return null;
  const displayName = pluginString(row.name, row.displayName, id) ?? id;
  return {
    id,
    displayName,
    description: pluginString(row.description, displayName, id) ?? displayName,
    isDefault: Boolean(currentModelID && id.toLowerCase() === currentModelID.toLowerCase()),
    hidden: false,
    supportedReasoningEfforts: id.toLowerCase().startsWith("gpt-") ? ["low", "medium", "high", "xhigh"] : [],
    defaultReasoningEffort: id.toLowerCase().startsWith("gpt-") ? "high" : null,
    inputModalities: [],
    isInstalled: true
  };
}

let copilotModelCache: { expiresAt: number; value: ProviderModelOption[] } | null = null;

async function loadCopilotModelsFromACP(): Promise<ProviderModelOption[]> {
  const now = Date.now();
  if (copilotModelCache && copilotModelCache.expiresAt > now) return copilotModelCache.value;

  const models = await new Promise<ProviderModelOption[]>((resolve, reject) => {
    const child = spawn("copilot", ["--acp", "--stdio"], {
      cwd: openAssistRepoRoot(),
      env: { ...process.env, PATH: assistantPATH() },
      stdio: ["pipe", "pipe", "pipe"]
    });
    let buffer = "";
    let nextID = 0;
    let settled = false;
    const pending = new Map<number, {
      resolve: (value: JsonObject) => void;
      reject: (error: Error) => void;
      timer: ReturnType<typeof setTimeout>;
    }>();
    const finish = (callback: () => void) => {
      if (settled) return;
      settled = true;
      for (const item of pending.values()) {
        clearTimeout(item.timer);
      }
      pending.clear();
      child.kill("SIGTERM");
      callback();
    };
    const fail = (error: Error) => finish(() => reject(error));
    const send = (method: string, params: JsonObject) => {
      const id = nextID;
      nextID += 1;
      const message = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
      return new Promise<JsonObject>((requestResolve, requestReject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          requestReject(new Error(`${method} timed out.`));
        }, 12_000);
        pending.set(id, { resolve: requestResolve, reject: requestReject, timer });
        child.stdin?.write(message, (error) => {
          if (!error) return;
          clearTimeout(timer);
          pending.delete(id);
          requestReject(error);
        });
      });
    };
    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => {
      buffer += String(chunk);
      let newlineIndex = buffer.indexOf("\n");
      while (newlineIndex >= 0) {
        const line = buffer.slice(0, newlineIndex).trim();
        buffer = buffer.slice(newlineIndex + 1);
        newlineIndex = buffer.indexOf("\n");
        if (!line) continue;
        let message: JsonObject;
        try {
          message = JSON.parse(line) as JsonObject;
        } catch {
          continue;
        }
        const id = typeof message.id === "number" ? message.id : undefined;
        if (id === undefined || !pending.has(id)) continue;
        const request = pending.get(id);
        if (!request) continue;
        pending.delete(id);
        clearTimeout(request.timer);
        const error = asObject(message.error);
        if (error) {
          request.reject(new Error(pluginString(error.message) ?? "Copilot request failed."));
        } else {
          request.resolve((asObject(message.result) ?? {}) as JsonObject);
        }
      }
    });
    child.on("error", fail);
    child.on("close", (code) => {
      if (!settled && code !== 0) fail(new Error(`Copilot model list exited with code ${code}.`));
    });

    void (async () => {
      try {
        await send("initialize", {
          protocolVersion: 1,
          clientInfo: { name: "Open Assist", version: "1.0" },
          capabilities: {}
        });
        const session = await send("session/new", {
          cwd: openAssistRepoRoot(),
          mcpServers: []
        });
        const modelConfig = (Array.isArray(session.configOptions) ? session.configOptions : [])
          .map(asObject)
          .find((option) => option?.id === "model");
        const currentModelID = pluginString(asObject(session.models)?.currentModelId, modelConfig?.currentValue);
        const availableRows = flattenCopilotConfigOptions(asObject(session.models)?.availableModels);
        const configRows = flattenCopilotConfigOptions(modelConfig?.options);
        const rows = availableRows.length ? availableRows : configRows;
        const parsed = uniqueProviderModels(rows
          .map((row) => copilotModelFromRow(row, currentModelID))
          .filter(Boolean) as ProviderModelOption[]);
        finish(() => resolve(parsed.length ? parsed : fallbackModelOptionsForBackend("copilot")));
      } catch (error) {
        fail(error instanceof Error ? error : new Error("Could not load Copilot models."));
      }
    })();
  });

  copilotModelCache = { expiresAt: Date.now() + 60_000, value: models };
  return models;
}

export async function listProviderModels(rawBackend: string): Promise<ProviderModelOption[]> {
  const backend = normalizeBackend(rawBackend);
  if (backend === "copilot") {
    try {
      return await loadCopilotModelsFromACP();
    } catch {
      return fallbackModelOptionsForBackend("copilot");
    }
  }
  return fallbackModelOptionsForBackend(backend);
}

function normalizeCodexReasoningEffort(raw?: string): CodexReasoningEffort | undefined {
  const normalized = (raw ?? "").trim().toLowerCase().replace(/[\s_-]+/g, "");
  if (normalized === "none") return "none";
  if (normalized === "minimal") return "minimal";
  if (normalized === "low") return "low";
  if (normalized === "medium") return "medium";
  if (normalized === "high") return "high";
  if (normalized === "xhigh" || normalized === "extrahigh") return "xhigh";
  return undefined;
}

function swiftDateToMs(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  return (value + macAbsoluteEpochOffset) * 1000;
}

function currentSwiftDate() {
  return Date.now() / 1000 - macAbsoluteEpochOffset;
}

function writeJSON(filePath: string, value: unknown) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function makeID(prefix = "") {
  return `${prefix}${randomUUID().toUpperCase()}`;
}

function makeOpenAssistThreadID() {
  return `openassist-${randomUUID().toLowerCase()}`;
}

function relativeAge(ms?: number) {
  if (!ms) return "";
  const diff = Math.max(0, Date.now() - ms);
  const minutes = Math.floor(diff / 60_000);
  if (minutes < 60) return `${Math.max(1, minutes)}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.floor(hours / 24);
  if (days < 31) return `${days}d`;
  const months = Math.floor(days / 30);
  if (months < 12) return `${months}mo`;
  return `${Math.floor(months / 12)}y`;
}

function noteSubtitle(updatedAt?: number) {
  const age = relativeAge(updatedAt);
  return age ? `Saved ${age} ago` : "Saved";
}

function normalizeTitle(value: unknown, fallback = "Untitled") {
  const text = typeof value === "string" ? value.trim() : "";
  return text || fallback;
}

function iconForProject(rawIcon: unknown, kind?: string, linkedFolderPath?: unknown): ProjectItem["icon"] {
  const icon = typeof rawIcon === "string" ? rawIcon.trim() : "";
  if (icon) return icon;
  if (kind === "folder") return "folder.fill";
  if (typeof linkedFolderPath === "string" && linkedFolderPath.trim()) return "folder.fill";
  return "book.closed.fill";
}

function loadProjects(): LoadedProjects {
  const filePath = path.join(projectStoreRoot(), "projects.json");
  const snapshot = readJSON<{ projects?: JsonObject[]; threadAssignments?: Record<string, string>; brainByProjectID?: Record<string, JsonObject> }>(
    filePath,
    {}
  );
  const projectNotesByID = new Map<string, number>();
  const threadTitles = new Map<string, string>();
  const projectNameByID = new Map<string, string>();
  const recordsByID = new Map<string, JsonObject>();

  for (const project of snapshot.projects ?? []) {
    const projectID = String(project.id ?? "");
    if (!projectID) continue;
    const kind = String(project.kind ?? "project") as "folder" | "project";
    const title = normalizeTitle(project.name, kind === "folder" ? "Group" : "Project");
    projectNameByID.set(projectID, title);
    projectNameByID.set(projectID.toUpperCase(), title);
    projectNameByID.set(projectID.toLowerCase(), title);
    recordsByID.set(projectID.toLowerCase(), project);
    const manifestPath = path.join(projectStoreRoot(), "ProjectNotes", projectID.toUpperCase(), "notes", "manifest.json");
    const manifest = readJSON<{ notes?: unknown[] }>(manifestPath, {});
    projectNotesByID.set(projectID, manifest.notes?.length ?? 0);
  }

  for (const [projectID, brain] of Object.entries(snapshot.brainByProjectID ?? {})) {
    const digests = (brain.threadDigestsByThreadID as Record<string, JsonObject> | undefined) ?? {};
    for (const [threadID, digest] of Object.entries(digests)) {
      const title = normalizeTitle(digest.threadTitle, "");
      if (title) threadTitles.set(threadID, title);
    }
    if (!projectNotesByID.has(projectID)) {
      const manifestPath = path.join(projectStoreRoot(), "ProjectNotes", projectID.toUpperCase(), "notes", "manifest.json");
      const manifest = readJSON<{ notes?: unknown[] }>(manifestPath, {});
      projectNotesByID.set(projectID, manifest.notes?.length ?? 0);
    }
  }

  const assignments = snapshot.threadAssignments ?? {};
  const chatsByProject = new Map<string, number>();
  for (const projectID of Object.values(assignments)) {
    chatsByProject.set(projectID, (chatsByProject.get(projectID) ?? 0) + 1);
  }

  const hiddenProjectIDs = new Set<string>();
  const isProjectEffectivelyHidden = (project: JsonObject, visited = new Set<string>()): boolean => {
    const id = String(project.id ?? "").trim().toLowerCase();
    if (!id || visited.has(id)) return false;
    if (project.isHidden === true) {
      hiddenProjectIDs.add(id);
      return true;
    }
    visited.add(id);
    const parentID = String(project.parentID ?? "").trim().toLowerCase();
    const parent = parentID ? recordsByID.get(parentID) : undefined;
    const hiddenByParent = parent ? isProjectEffectivelyHidden(parent, visited) : false;
    if (hiddenByParent) hiddenProjectIDs.add(id);
    return hiddenByParent;
  };

  for (const project of snapshot.projects ?? []) {
    isProjectEffectivelyHidden(project);
  }

  const itemForProject = (project: JsonObject) => {
    const id = String(project.id ?? "");
    return projectItemFromSnapshot(project, projectNotesByID.get(id) ?? 0, chatsByProject.get(id) ?? 0);
  };

  const projects: ProjectItem[] = (snapshot.projects ?? [])
    .filter((project) => {
      const id = String(project.id ?? "").trim().toLowerCase();
      return id && !hiddenProjectIDs.has(id);
    })
    .map(itemForProject);
  const hiddenProjects: ProjectItem[] = (snapshot.projects ?? [])
    .filter((project) => project.isHidden === true)
    .map(itemForProject);

  if (projects.length) projects[0].active = true;
  return { projects, hiddenProjects, hiddenProjectIDs, projectNameByID, projectNotesByID, threadAssignments: assignments, threadTitles };
}

function latestTranscriptText(transcript: JsonObject[] | undefined, role: "user" | "assistant") {
  const item = [...(transcript ?? [])].reverse().find((entry) => entry.role === role);
  return typeof item?.text === "string" ? item.text : "";
}

function conversationHasVisibleMessages(snapshot: { transcript?: JsonObject[] }) {
  return (snapshot.transcript ?? []).some((entry) => {
    if (entry.role !== "user" && entry.role !== "assistant") return false;
    return normalizeTitle(entry.text, "") !== "";
  });
}

function conversationHasThreadNotes(threadID: string) {
  const notesRoot = threadNotesDirectory(threadID);
  if (!fs.existsSync(notesRoot)) return false;
  const manifest = readJSON<{ notes?: JsonObject[] }>(path.join(notesRoot, "manifest.json"), {});
  if ((manifest.notes ?? []).length > 0) return true;
  return fs.readdirSync(notesRoot).some((entry) => entry !== ".DS_Store");
}

function cleanupEmptyConversationThreads() {
  const root = conversationStoreRoot();
  if (!fs.existsSync(root)) return 0;
  const removedThreadIDs: string[] = [];
  for (const dir of fs.readdirSync(root)) {
    const filePath = path.join(root, dir, "conversation.json");
    if (!fs.existsSync(filePath)) continue;
    const snapshot = readJSON<{ threadID?: string; transcript?: JsonObject[] }>(filePath, {});
    const threadID = snapshot.threadID ?? dir;
    if (conversationHasVisibleMessages(snapshot) || conversationHasThreadNotes(threadID)) continue;
    fs.rmSync(path.join(root, dir), { recursive: true, force: true });
    removeProjectThreadAssignment(threadID);
    removedThreadIDs.push(threadID.toLowerCase());
  }
  if (removedThreadIDs.length) {
    const removed = new Set(removedThreadIDs);
    const registry = loadSessionRegistry();
    saveSessionRegistry(registry.sessions.filter((session) => !removed.has(session.id.toLowerCase())));
  }
  return removedThreadIDs.length;
}

function loadThreads(projects: LoadedProjects): ThreadItem[] {
  const root = conversationStoreRoot();
  if (!fs.existsSync(root)) return [];
  const registryByID = new Map(loadSessionRegistry().sessions.map((session) => [session.id.toLowerCase(), session]));
  const threads: ThreadItem[] = [];
  for (const dir of fs.readdirSync(root)) {
    const filePath = path.join(root, dir, "conversation.json");
    if (!fs.existsSync(filePath)) continue;
    const snapshot = readJSON<{ threadID?: string; updatedAt?: number; transcript?: JsonObject[]; timeline?: JsonObject[] }>(filePath, {});
    if (!conversationHasVisibleMessages(snapshot)) continue;
    const threadID = snapshot.threadID ?? dir;
    const registrySession = registryByID.get(threadID.toLowerCase());
    const updatedAt = swiftDateToMs(snapshot.updatedAt);
    const title =
      (registrySession?.title && registrySession.title !== "New Assistant Session" ? registrySession.title : "") ||
      registrySession?.latestUserMessage ||
      projects.threadTitles.get(threadID) ||
      latestTranscriptText(snapshot.transcript, "user") ||
      latestTranscriptText(snapshot.transcript, "assistant") ||
      "Untitled chat";
    const projectID = projects.threadAssignments[threadID];
    if (projectID && projects.hiddenProjectIDs.has(projectID.toLowerCase())) continue;
    threads.push({
      id: threadID,
      title: title.length > 74 ? `${title.slice(0, 73).trimEnd()}...` : title,
      projectID,
      project: projectID ? projects.projectNameByID.get(projectID) : undefined,
      activeProvider: normalizeBackend(String(registrySession?.activeProvider ?? pluginString(registrySession?.providerBackend) ?? "codex")),
      modelID: pluginString(registrySession?.modelID, registrySession?.latestModel),
      age: relativeAge(updatedAt),
      updatedAt,
      isArchived: registrySession?.isArchived === true,
      isTemporary: registrySession?.isTemporary === true
    });
  }
  threads.sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0));
  if (threads.length) threads[0].active = true;
  return threads.slice(0, 120);
}

function loadThreadMessages(threadID: string): ThreadDetail {
  const filePath = path.join(conversationStoreRoot(), threadID, "conversation.json");
  const snapshot = readJSON<{ threadID?: string; transcript?: JsonObject[]; timeline?: JsonObject[] }>(filePath, {});
  const transcript = snapshot.transcript ?? [];
  const timelineMessages: ChatMessage[] = displayOrderedTimeline(snapshot.timeline ?? [])
    .map((entry, index): ChatMessage | null => {
      const kind = String(entry.kind ?? "");
      const activity = runtimeObject(entry.activity);
      if (kind === "userMessage") {
        const text = normalizeTitle(entry.text, "");
        if (!text) return null;
        return {
          id: String(entry.id ?? `${threadID}-timeline-user-${index}`),
          role: "user",
          text,
          createdAt: swiftDateToMs(entry.createdAt),
          updatedAt: swiftDateToMs(entry.updatedAt)
        };
      }
      if (kind === "assistantFinal" || kind === "assistantProgress") {
        const text = normalizeTitle(entry.text, "");
        if (!text) return null;
        return {
          id: String(entry.id ?? `${threadID}-timeline-assistant-${index}`),
          role: "assistant",
          text,
          provider: typeof entry.providerBackend === "string" ? providerLabel(entry.providerBackend) : undefined,
          status: entry.isStreaming === true ? "running" : "completed",
          createdAt: swiftDateToMs(entry.createdAt),
          updatedAt: swiftDateToMs(entry.updatedAt)
        };
      }
      if (kind === "activity" && activity) {
        const activityKind = firstRuntimeString(activity.kind, "tool");
        const title = firstRuntimeString(activity.title, activity.friendlySummary, entry.title, "Tool");
        const detail = storedRuntimeString(activity.rawDetails, activity.detail, entry.text);
        const imagePath = firstRuntimeString(activity.imagePath, activity.image_path);
        const imageMimeType = firstRuntimeString(activity.imageMimeType, activity.image_mime_type) || imageMimeTypeFromPath(imagePath) || "image/png";
        const storedImageDataURL = firstRawRuntimeString(activity.imageDataURL, activity.image_data_url);
        const imageDataURL = storedImageDataURL || imageDataURLFromFile(imagePath, imageMimeType);
        const normalizedTitle = title.replace(/\s+/g, " ").trim().toLowerCase();
        if (normalizedTitle === "user message") return null;
        if (isRuntimeMessageItemType(activityKind)) return null;
        if ((activityKind === "reasoning" || normalizedTitle === "reasoning") && isGenericRuntimeDetail(detail || title)) return null;
        if (normalizedTitle === "agent message" && isGenericRuntimeDetail(detail)) return null;
        const createdAtValue = isStoredRealtimeDelegationEntry(entry)
          ? activity.startedAt ?? activity.updatedAt ?? entry.createdAt
          : entry.createdAt ?? activity.startedAt;
        const rawStatus = String(activity.status ?? "completed").toLowerCase();
        const activityStatus: ChatMessage["activityStatus"] = rawStatus.includes("fail")
          ? "failed"
          : rawStatus.includes("wait")
            ? "waiting"
            : rawStatus.includes("pending")
              ? "pending"
              : rawStatus.includes("run") || entry.isStreaming === true
                ? "running"
                : "completed";
        return {
          id: String(activity.id ?? entry.id ?? `${threadID}-activity-${index}`),
          role: "activity",
          provider: typeof entry.providerBackend === "string" ? providerLabel(entry.providerBackend) : undefined,
          text: detail || title,
          status: activityStatus === "running" || activityStatus === "waiting" || activityStatus === "pending" ? "running" : "completed",
          activityTitle: title,
          activityKind,
          activityStatus,
          activityDetail: detail || undefined,
          imageDataURL,
          imagePath: imagePath || undefined,
          imagePrompt: firstRuntimeString(activity.imagePrompt, activity.image_prompt) || undefined,
          imageMimeType: imageDataURL || imagePath ? imageMimeType : undefined,
          imageName: firstRuntimeString(activity.imageName, activity.image_name) || imageFileNameFromPath(imagePath),
          approvalRequestID: validJsonRequestID(activity.approvalRequestID ?? activity.approval_request_id),
          approvalKind: firstRuntimeString(activity.approvalKind, activity.approval_kind) as ChatMessage["approvalKind"],
          approvalPrompt: firstRuntimeString(activity.approvalPrompt, activity.approval_prompt) || undefined,
          approvalOptions: Array.isArray(activity.approvalOptions) ? activity.approvalOptions as ChatMessage["approvalOptions"] : undefined,
          approvalResolved: activity.approvalResolved === true || activity.approval_resolved === true,
          createdAt: swiftDateToMs(createdAtValue),
          updatedAt: swiftDateToMs(entry.updatedAt ?? activity.updatedAt)
        };
      }
      return null;
    })
    .filter((message): message is ChatMessage => Boolean(message));
  const messages: ChatMessage[] = timelineMessages.length
    ? timelineMessages
    : transcript
        .filter((entry) => entry.role === "user" || entry.role === "assistant")
        .map((entry, index) => ({
          id: String(entry.id ?? `${threadID}-${index}`),
          role: entry.role as "user" | "assistant",
          text: normalizeTitle(entry.text, ""),
          provider: typeof entry.providerBackend === "string" ? providerLabel(entry.providerBackend) : undefined
        }))
        .filter((message) => message.text);
  return {
    threadID,
    title: messages.find((message) => message.role === "user")?.text.slice(0, 80) || "Untitled chat",
    messages
  };
}

function timelineEntryKind(entry: JsonObject) {
  return String(entry.kind ?? "");
}

function timelineEntryTurnID(entry: JsonObject) {
  const activity = runtimeObject(entry.activity);
  return firstRuntimeString(entry.turnID, entry.turnId, activity?.turnID, activity?.turnId);
}

function isStoredRealtimeDelegationEntry(entry: JsonObject) {
  const activity = runtimeObject(entry.activity);
  const kind = String(activity?.kind ?? "").replace(/[_\s-]+/g, "").toLowerCase();
  const title = String(activity?.title ?? activity?.friendlySummary ?? entry.title ?? "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
  const id = String(activity?.id ?? entry.id ?? "");
  return kind === "realtimedelegation"
    || (kind === "subagent" && title.includes("realtime"))
    || id.includes("realtime-delegation");
}

function timelineEntryCreatedAt(entry: JsonObject) {
  const activity = runtimeObject(entry.activity);
  const value = Number(
    isStoredRealtimeDelegationEntry(entry)
      ? activity?.startedAt ?? activity?.updatedAt ?? entry.createdAt ?? entry.updatedAt ?? 0
      : entry.createdAt ?? entry.updatedAt ?? activity?.startedAt ?? activity?.updatedAt ?? 0
  );
  return Number.isFinite(value) ? value : 0;
}

function sortedTimelineActivities(activities: JsonObject[]) {
  return [...activities].sort((left, right) => timelineEntryCreatedAt(left) - timelineEntryCreatedAt(right));
}

function activityRunBelongsToAssistant(activities: JsonObject[], assistant: JsonObject) {
  const assistantTurnID = timelineEntryTurnID(assistant);
  if (!assistantTurnID) return false;
  let matched = false;
  for (const activity of activities) {
    const activityTurnID = timelineEntryTurnID(activity);
    if (!activityTurnID) continue;
    if (activityTurnID !== assistantTurnID) return false;
    matched = true;
  }
  return matched;
}

function displayOrderedTimeline(timeline: JsonObject[]) {
  const source = timeline
    .map((entry, originalIndex) => ({ entry, originalIndex }))
    .sort((left, right) => {
      const byCreatedAt = timelineEntryCreatedAt(left.entry) - timelineEntryCreatedAt(right.entry);
      return byCreatedAt || left.originalIndex - right.originalIndex;
    })
    .map((item) => item.entry);
  const ordered: JsonObject[] = [];
  let index = 0;
  while (index < source.length) {
    const entry = source[index];
    if (timelineEntryKind(entry) !== "activity") {
      ordered.push(entry);
      index += 1;
      continue;
    }

    const activities: JsonObject[] = [];
    while (index < source.length && timelineEntryKind(source[index]) === "activity") {
      activities.push(source[index]);
      index += 1;
    }

    const user = source[index];
    const assistant = source[index + 1];
    const assistantKind = assistant ? timelineEntryKind(assistant) : "";
    if (
      user
      && assistant
      && timelineEntryKind(user) === "userMessage"
      && (assistantKind === "assistantFinal" || assistantKind === "assistantProgress")
      && activityRunBelongsToAssistant(activities, assistant)
    ) {
      ordered.push(user, ...sortedTimelineActivities(activities), assistant);
      index += 2;
      continue;
    }

    ordered.push(...sortedTimelineActivities(activities));
  }
  return ordered;
}

function threadNotesDirectory(threadID: string) {
  return path.join(conversationStoreRoot(), threadID, "notes");
}

function threadNoteManifestPath(threadID: string) {
  return path.join(threadNotesDirectory(threadID), "manifest.json");
}

function normalizeThreadNoteTitle(value?: string) {
  const normalized = String(value ?? "").replace(/\s+/g, " ").trim();
  return normalized || "Untitled note";
}

function readThreadNoteManifest(threadID: string) {
  return readJSON<{
    version?: number;
    selectedNoteID?: string;
    notes?: (ThreadNoteSummary & { createdAt?: number; order?: number; noteType?: string })[];
    folders?: JsonObject[];
  }>(threadNoteManifestPath(threadID), { version: 2, notes: [], folders: [] });
}

function writeThreadNoteManifest(threadID: string, manifest: JsonObject) {
  writeJSON(threadNoteManifestPath(threadID), {
    version: 2,
    notes: [],
    folders: [],
    ...manifest
  });
}

function loadThreadNoteWorkspace(threadID: string): ThreadNoteWorkspace {
  const manifest = readThreadNoteManifest(threadID);
  const notes = [...(manifest.notes ?? [])]
    .filter((note) => note.id && note.fileName)
    .sort((a, b) => Number(a.order ?? 0) - Number(b.order ?? 0))
    .map((note) => ({
      id: String(note.id),
      title: normalizeThreadNoteTitle(note.title),
      fileName: String(note.fileName),
      updatedAt: swiftDateToMs(note.updatedAt)
    }));
  const selectedNoteID = notes.some((note) => note.id === manifest.selectedNoteID)
    ? manifest.selectedNoteID
    : notes[0]?.id;
  const selectedSummary = notes.find((note) => note.id === selectedNoteID);
  const selectedPath = selectedSummary ? path.join(threadNotesDirectory(threadID), selectedSummary.fileName) : undefined;
  const selectedMarkdown = selectedPath && fs.existsSync(selectedPath) ? fs.readFileSync(selectedPath, "utf8").replace(/\r\n/g, "\n") : "";

  return {
    threadID,
    notes,
    selectedNoteID,
    selectedNote: selectedSummary && selectedPath
      ? { ...selectedSummary, markdown: selectedMarkdown, path: selectedPath }
      : undefined
  };
}

function loadThreadNoteList(threads: ThreadItem[]): ThreadNoteListItem[] {
  const items: ThreadNoteListItem[] = [];
  for (const thread of threads) {
    const manifest = readThreadNoteManifest(thread.id);
    for (const note of manifest.notes ?? []) {
      if (!note.id || !note.fileName) continue;
      const updatedAt = swiftDateToMs(note.updatedAt);
      items.push({
        id: String(note.id),
        title: normalizeThreadNoteTitle(note.title),
        subtitle: `${thread.title}${thread.isArchived ? " · Archived" : ""} · ${noteSubtitle(updatedAt)}`,
        threadID: thread.id,
        threadTitle: thread.title,
        projectID: thread.projectID,
        projectName: thread.project,
        updatedAt,
        isArchived: thread.isArchived,
        active: manifest.selectedNoteID === note.id
      });
    }
  }
  items.sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0));
  return items;
}

function createThreadNote(threadID: string, title = "Untitled note"): ThreadNoteWorkspace {
  const manifest = readThreadNoteManifest(threadID);
  const noteID = randomUUID().toLowerCase();
  const now = currentSwiftDate();
  const note = {
    id: noteID,
    title: normalizeThreadNoteTitle(title),
    fileName: `${noteID}.md`,
    noteType: "note",
    order: manifest.notes?.length ?? 0,
    createdAt: now,
    updatedAt: now
  };
  fs.mkdirSync(threadNotesDirectory(threadID), { recursive: true });
  fs.writeFileSync(path.join(threadNotesDirectory(threadID), note.fileName), "", "utf8");
  writeThreadNoteManifest(threadID, {
    ...manifest,
    selectedNoteID: noteID,
    notes: [...(manifest.notes ?? []), note]
  });
  return loadThreadNoteWorkspace(threadID);
}

function saveThreadNote(threadID: string, noteID: string | undefined, markdown: string): ThreadNoteWorkspace {
  let workspace = loadThreadNoteWorkspace(threadID);
  if (!noteID || !workspace.notes.some((note) => note.id === noteID)) {
    workspace = createThreadNote(threadID);
    noteID = workspace.selectedNoteID;
  }
  const manifest = readThreadNoteManifest(threadID);
  const notes = (manifest.notes ?? []).map((note) => (
    note.id === noteID ? { ...note, updatedAt: currentSwiftDate() } : note
  ));
  const target = notes.find((note) => note.id === noteID);
  if (!target) return workspace;
  fs.mkdirSync(threadNotesDirectory(threadID), { recursive: true });
  fs.writeFileSync(path.join(threadNotesDirectory(threadID), target.fileName), markdown.replace(/\r\n/g, "\n"), "utf8");
  writeThreadNoteManifest(threadID, { ...manifest, selectedNoteID: noteID, notes });
  return loadThreadNoteWorkspace(threadID);
}

function selectThreadNote(threadID: string, noteID: string): ThreadNoteWorkspace {
  const manifest = readThreadNoteManifest(threadID);
  const selectedNoteID = (manifest.notes ?? []).some((note) => note.id === noteID) ? noteID : manifest.selectedNoteID;
  writeThreadNoteManifest(threadID, { ...manifest, selectedNoteID });
  return loadThreadNoteWorkspace(threadID);
}

function loadThreadMemory(threadID: string) {
  const memoryPath = path.join(supportRoot(), "AssistantMemory", threadID, "memory.md");
  const exists = fs.existsSync(memoryPath);
  return {
    threadID,
    exists,
    path: exists ? memoryPath : undefined,
    markdown: exists ? fs.readFileSync(memoryPath, "utf8").replace(/\r\n/g, "\n") : ""
  };
}

function conversationSnapshotPath(threadID: string) {
  return path.join(conversationStoreRoot(), threadID, "conversation.json");
}

function readConversationSnapshot(threadID: string) {
  return readJSON<{
    version?: number;
    threadID?: string;
    timeline?: JsonObject[];
    transcript?: JsonObject[];
    turns?: JsonObject[];
    updatedAt?: number;
    lastAppliedEventSequence?: number;
  }>(conversationSnapshotPath(threadID), {
    version: 2,
    threadID,
    timeline: [],
    transcript: [],
    turns: [],
    updatedAt: currentSwiftDate(),
    lastAppliedEventSequence: 0
  });
}

function writeConversationSnapshot(threadID: string, snapshot: JsonObject) {
  writeJSON(conversationSnapshotPath(threadID), {
    version: 2,
    threadID,
    timeline: [],
    transcript: [],
    turns: [],
    lastAppliedEventSequence: 0,
    ...snapshot,
    updatedAt: currentSwiftDate()
  });
}

function loadSessionRegistry() {
  const snapshot = readJSON<{ version?: number; sessions?: SessionSummary[] }>(sessionRegistryPath(), { version: 2, sessions: [] });
  return {
    version: Math.max(2, Number(snapshot.version ?? 2)),
    sessions: (snapshot.sessions ?? []).filter((session): session is SessionSummary => Boolean(session?.id))
  };
}

function saveSessionRegistry(sessions: SessionSummary[]) {
  const sorted = sessions
    .filter((session) => session.id)
    .sort((a, b) => (Number(b.updatedAt ?? b.createdAt ?? 0) - Number(a.updatedAt ?? a.createdAt ?? 0)));
  const seen = new Set<string>();
  const normalized: SessionSummary[] = [];
  for (const session of sorted) {
    const key = `${session.source.toLowerCase()}::${session.id.toLowerCase()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    normalized.push(session);
    if (normalized.length >= 200) break;
  }
  writeJSON(sessionRegistryPath(), { version: 2, sessions: normalized });
}

function findSession(threadID: string) {
  const registry = loadSessionRegistry();
  return registry.sessions.find((session) => session.id.toLowerCase() === threadID.toLowerCase());
}

function updateSession(session: SessionSummary) {
  const registry = loadSessionRegistry();
  const next = [
    { ...session, updatedAt: currentSwiftDate() },
    ...registry.sessions.filter((item) => item.id.toLowerCase() !== session.id.toLowerCase() || item.source !== session.source)
  ];
  saveSessionRegistry(next);
  return next[0];
}

function clearProviderBindingsForBackend(backend: AssistantBackend) {
  const registry = loadSessionRegistry();
  const next = registry.sessions.map((session) => {
    const bindings = session.providerBindingsByBackend ?? [];
    const filtered = bindings.filter((binding) => binding.backend !== backend);
    if (filtered.length === bindings.length) return session;
    return {
      ...session,
      providerBindingsByBackend: filtered,
      updatedAt: currentSwiftDate()
    };
  });
  saveSessionRegistry(next);
}

function providerBinding(session: SessionSummary | undefined, backend: AssistantBackend) {
  return (session?.providerBindingsByBackend ?? []).find((binding) => binding.backend === backend);
}

function projectContextForThread(threadID: string) {
  const loadedProjects = loadProjects();
  const projectID = loadedProjects.threadAssignments[threadID];
  const project = projectID
    ? loadedProjects.projects.find((item) => item.kind !== "folder" && item.id.toLowerCase() === projectID.toLowerCase())
    : undefined;
  return { project, projectID: project?.id ?? projectID };
}

function ensureOpenAssistSessionRecord(threadID: string, backend?: AssistantBackend, modelID?: string) {
  const existing = findSession(threadID);
  if (existing) return existing;
  const { project, projectID } = projectContextForThread(threadID);
  const now = currentSwiftDate();
  const cwd = project?.linkedFolderPath ?? undefined;
  const session: SessionSummary = {
    id: threadID,
    title: "New Assistant Session",
    source: "openAssist",
    threadArchitectureVersion: 2,
    conversationPersistence: 2,
    providerBindingsByBackend: [],
    status: "idle",
    cwd,
    effectiveCWD: cwd,
    createdAt: now,
    updatedAt: now,
    latestTaskMode: "chat",
    latestModel: modelID,
    latestInteractionMode: "agentic",
    latestReasoningEffort: "high",
    latestPermissionMode: "fullAccess",
    isArchived: false,
    isTemporary: false,
    projectID,
    projectName: project?.title,
    linkedProjectFolderPath: cwd,
    projectFolderMissing: false,
    activeProvider: backend
  };
  return updateSession(session);
}

function updateProviderBinding(threadID: string, backend: AssistantBackend, providerSessionID: string, modelID?: string) {
  const session = ensureOpenAssistSessionRecord(threadID, backend, modelID);
  const existing = session.providerBindingsByBackend ?? [];
  const nextBinding = {
    ...(existing.find((binding) => binding.backend === backend) ?? {}),
    backend,
    providerSessionID,
    latestModelID: modelID || String((existing.find((binding) => binding.backend === backend) ?? {}).latestModelID ?? ""),
    latestInteractionMode: "agentic",
    latestReasoningEffort: "high",
    lastConnectedAt: currentSwiftDate()
  };
  session.providerBindingsByBackend = [nextBinding, ...existing.filter((binding) => binding.backend !== backend)];
  session.activeProvider = backend;
  return updateSession(session);
}

function updateProjectThreadAssignment(threadID: string, projectID?: string | null) {
  if (!projectID) return;
  const filePath = path.join(projectStoreRoot(), "projects.json");
  const snapshot = readJSON<JsonObject & { threadAssignments?: Record<string, string> }>(filePath, {});
  snapshot.threadAssignments = { ...(snapshot.threadAssignments ?? {}), [threadID]: projectID };
  writeJSON(filePath, snapshot);
}

function removeProjectThreadAssignment(threadID: string) {
  const filePath = path.join(projectStoreRoot(), "projects.json");
  const snapshot = readJSON<JsonObject & { threadAssignments?: Record<string, string> }>(filePath, {});
  const assignments = { ...(snapshot.threadAssignments ?? {}) };
  delete assignments[threadID];
  snapshot.threadAssignments = assignments;
  writeJSON(filePath, snapshot);
}

function normalizeProjectName(name: string) {
  return name.replace(/\s+/g, " ").trim();
}

function projectStoreSnapshot() {
  const filePath = path.join(projectStoreRoot(), "projects.json");
  const snapshot = readJSON<JsonObject & {
    version?: number;
    projects?: JsonObject[];
    threadAssignments?: Record<string, string>;
    brainByProjectID?: Record<string, JsonObject>;
  }>(filePath, {});
  snapshot.projects = snapshot.projects ?? [];
  snapshot.threadAssignments = snapshot.threadAssignments ?? {};
  snapshot.brainByProjectID = snapshot.brainByProjectID ?? {};
  return { filePath, snapshot };
}

function saveProjectStoreSnapshot(filePath: string, snapshot: JsonObject) {
  snapshot.version = Math.max(1, Number(snapshot.version ?? 1));
  writeJSON(filePath, snapshot);
}

function projectRecord(snapshot: { projects?: JsonObject[] }, projectID: string) {
  const id = projectID.trim().toLowerCase();
  return (snapshot.projects ?? []).find((project) => String(project.id ?? "").trim().toLowerCase() === id);
}

function loadedProjectItem(projectID: string) {
  return loadProjects().projects.find((project) => project.id.toLowerCase() === projectID.toLowerCase()) ?? null;
}

function renameProject(projectID: string, name: string) {
  const { filePath, snapshot } = projectStoreSnapshot();
  const project = projectRecord(snapshot, projectID);
  if (!project) throw new Error("Project was not found.");
  const nextName = normalizeProjectName(name);
  if (!nextName) throw new Error("Project name is required.");
  project.name = nextName;
  project.updatedAt = currentSwiftDate();
  saveProjectStoreSnapshot(filePath, snapshot);
  return loadedProjectItem(projectID);
}

function updateProjectIcon(projectID: string, symbol?: string | null) {
  const { filePath, snapshot } = projectStoreSnapshot();
  const project = projectRecord(snapshot, projectID);
  if (!project) throw new Error("Project was not found.");
  if (symbol?.trim()) project.iconSymbolName = symbol.trim();
  else delete project.iconSymbolName;
  project.updatedAt = currentSwiftDate();
  saveProjectStoreSnapshot(filePath, snapshot);
  return loadedProjectItem(projectID);
}

function updateProjectLinkedFolder(projectID: string, folderPath?: string | null) {
  const { filePath, snapshot } = projectStoreSnapshot();
  const project = projectRecord(snapshot, projectID);
  if (!project) throw new Error("Project was not found.");
  if (String(project.kind ?? "project") !== "project") throw new Error("Only projects can link folders.");
  const normalized = folderPath?.trim();
  if (normalized) project.linkedFolderPath = normalized;
  else delete project.linkedFolderPath;
  project.updatedAt = currentSwiftDate();
  saveProjectStoreSnapshot(filePath, snapshot);
  return loadedProjectItem(projectID);
}

function moveProjectToFolder(projectID: string, folderID?: string | null) {
  const { filePath, snapshot } = projectStoreSnapshot();
  const project = projectRecord(snapshot, projectID);
  if (!project) throw new Error("Project was not found.");
  const normalizedFolderID = folderID?.trim();
  if (normalizedFolderID) {
    const folder = projectRecord(snapshot, normalizedFolderID);
    if (!folder || String(folder.kind ?? "") !== "folder") throw new Error("Group was not found.");
    project.parentID = String(folder.id);
  } else {
    delete project.parentID;
  }
  project.updatedAt = currentSwiftDate();
  saveProjectStoreSnapshot(filePath, snapshot);
  return loadedProjectItem(projectID);
}

function hideProject(projectID: string) {
  const { filePath, snapshot } = projectStoreSnapshot();
  const project = projectRecord(snapshot, projectID);
  if (!project) throw new Error("Project was not found.");
  project.isHidden = true;
  project.updatedAt = currentSwiftDate();
  saveProjectStoreSnapshot(filePath, snapshot);
  return { ok: true };
}

function unhideProject(projectID: string) {
  const { filePath, snapshot } = projectStoreSnapshot();
  const project = projectRecord(snapshot, projectID);
  if (!project) throw new Error("Project was not found.");
  project.isHidden = false;
  project.updatedAt = currentSwiftDate();
  saveProjectStoreSnapshot(filePath, snapshot);
  return loadedProjectItem(projectID);
}

function deleteProject(projectID: string) {
  const { filePath, snapshot } = projectStoreSnapshot();
  const normalizedID = projectID.trim().toLowerCase();
  const projectIDsToDelete = new Set<string>([normalizedID]);
  for (const project of snapshot.projects ?? []) {
    const parentID = String(project.parentID ?? "").trim().toLowerCase();
    if (projectIDsToDelete.has(parentID)) {
      projectIDsToDelete.add(String(project.id ?? "").trim().toLowerCase());
    }
  }
  snapshot.projects = (snapshot.projects ?? []).filter((project) => !projectIDsToDelete.has(String(project.id ?? "").trim().toLowerCase()));
  const assignments = { ...(snapshot.threadAssignments ?? {}) };
  for (const [threadID, assignedProjectID] of Object.entries(assignments)) {
    if (projectIDsToDelete.has(String(assignedProjectID).trim().toLowerCase())) delete assignments[threadID];
  }
  snapshot.threadAssignments = assignments;
  for (const projectKey of Object.keys(snapshot.brainByProjectID ?? {})) {
    if (projectIDsToDelete.has(projectKey.trim().toLowerCase())) delete snapshot.brainByProjectID?.[projectKey];
  }
  saveProjectStoreSnapshot(filePath, snapshot);
  return { ok: true };
}

function loadProjectMemory(projectID: string) {
  const { filePath, snapshot } = projectStoreSnapshot();
  const project = projectRecord(snapshot, projectID);
  const title = normalizeTitle(project?.name, "Project");
  const brain = snapshot.brainByProjectID?.[projectID]
    ?? snapshot.brainByProjectID?.[projectID.toUpperCase()]
    ?? snapshot.brainByProjectID?.[projectID.toLowerCase()];
  const summary = normalizeTitle(brain?.projectSummary, "");
  const digests = Object.values((brain?.threadDigestsByThreadID as Record<string, JsonObject> | undefined) ?? {});
  const digestLines = digests.slice(0, 24).map((digest) => {
    const threadTitle = normalizeTitle(digest.threadTitle, "Untitled chat");
    const digestText = normalizeTitle(digest.digest, normalizeTitle(digest.summary, ""));
    return digestText ? `- ${threadTitle}: ${digestText}` : `- ${threadTitle}`;
  });
  const markdown = [
    `# ${title} Memory`,
    "",
    summary || "No project summary has been saved yet.",
    digestLines.length ? "\n## Chat Digests" : "",
    ...digestLines
  ].filter(Boolean).join("\n");
  return {
    threadID: `project:${projectID}`,
    exists: Boolean(summary || digestLines.length),
    path: filePath,
    markdown
  };
}

function projectItemFromSnapshot(project: JsonObject, notes = 0, chats = 0): ProjectItem {
  const id = String(project.id ?? "");
  const kind = String(project.kind ?? "project") as "folder" | "project";
  const subtitle = kind === "folder"
    ? `${chats} ${chats === 1 ? "chat" : "chats"}`
    : `${chats ? `${chats} ${chats === 1 ? "chat" : "chats"}` : "No chats yet"}${notes ? ` · ${notes} notes` : ""}`;
  return {
    id,
    title: normalizeTitle(project.name, kind === "folder" ? "Group" : "Project"),
    subtitle,
    icon: iconForProject(project.iconSymbolName, kind, project.linkedFolderPath),
    kind,
    parentID: (project.parentID as string | undefined) ?? null,
    linkedFolderPath: (project.linkedFolderPath as string | undefined) ?? null,
    hidden: project.isHidden === true
  };
}

function uniqueProjectName(snapshot: { projects?: JsonObject[] }, name: string, parentID?: string | null) {
  const base = normalizeProjectName(name);
  if (!base) throw new Error("Project name is required.");
  const normalizedParent = parentID?.trim().toLowerCase() || "";
  const siblings = new Set(
    (snapshot.projects ?? [])
      .filter((project) => String(project.parentID ?? "").trim().toLowerCase() === normalizedParent)
      .map((project) => normalizeProjectName(String(project.name ?? "")).toLowerCase())
      .filter(Boolean)
  );
  if (!siblings.has(base.toLowerCase())) return base;
  for (let index = 2; index < 100; index += 1) {
    const candidate = `${base} ${index}`;
    if (!siblings.has(candidate.toLowerCase())) return candidate;
  }
  return `${base} ${Date.now()}`;
}

function createProject(name: string, kind: "project" | "folder" = "project", parentID?: string | null) {
  const filePath = path.join(projectStoreRoot(), "projects.json");
  const snapshot = readJSON<JsonObject & {
    version?: number;
    projects?: JsonObject[];
    threadAssignments?: Record<string, string>;
    brainByProjectID?: Record<string, JsonObject>;
  }>(filePath, {});
  const projects = snapshot.projects ?? [];
  const normalizedKind = kind === "folder" ? "folder" : "project";
  const normalizedParentID = normalizedKind === "project"
    && parentID
    && projects.some((project) => String(project.id ?? "").toLowerCase() === parentID.toLowerCase() && project.kind === "folder")
    ? parentID
    : undefined;
  const projectID = randomUUID().toUpperCase();
  const now = currentSwiftDate();
  const project: JsonObject = {
    id: projectID,
    kind: normalizedKind,
    name: uniqueProjectName(snapshot, name, normalizedParentID),
    isHidden: false,
    createdAt: now,
    updatedAt: now,
    iconSymbolName: normalizedKind === "folder" ? "folder.fill" : "book.closed.fill"
  };
  if (normalizedParentID) project.parentID = normalizedParentID;
  snapshot.version = Math.max(1, Number(snapshot.version ?? 1));
  snapshot.projects = [...projects, project];
  snapshot.threadAssignments = snapshot.threadAssignments ?? {};
  snapshot.brainByProjectID = snapshot.brainByProjectID ?? {};
  if (normalizedKind === "project") {
    snapshot.brainByProjectID[projectID] = { projectSummary: "", processedThreadIDs: [], threadDigestsByThreadID: {} };
  }
  writeJSON(filePath, snapshot);
  return projectItemFromSnapshot(project);
}

function createEmptyConversation(threadID: string) {
  writeConversationSnapshot(threadID, {
    threadID,
    timeline: [],
    transcript: [],
    turns: [],
    lastAppliedEventSequence: 0
  });
}

function createOpenAssistThread(projectID?: string, persistEmptyConversation = true, isTemporary = false) {
  const loadedProjects = loadProjects();
  const normalizedProjectID = projectID?.trim().toLowerCase();
  const project = normalizedProjectID
    ? loadedProjects.projects.find((item) => item.kind !== "folder" && item.id.toLowerCase() === normalizedProjectID)
    : undefined;
  const threadID = makeOpenAssistThreadID();
  const now = currentSwiftDate();
  const cwd = project?.linkedFolderPath ?? undefined;
  const session: SessionSummary = {
    id: threadID,
    title: "New Assistant Session",
    source: "openAssist",
    threadArchitectureVersion: 2,
    conversationPersistence: isTemporary ? 0 : 2,
    providerBindingsByBackend: [],
    status: "idle",
    cwd,
    effectiveCWD: cwd,
    createdAt: now,
    updatedAt: now,
    latestTaskMode: "chat",
    latestInteractionMode: "agentic",
    latestReasoningEffort: "high",
    latestPermissionMode: "fullAccess",
    isArchived: false,
    isTemporary,
    projectID: project?.id,
    projectName: project?.title,
    linkedProjectFolderPath: cwd,
    projectFolderMissing: false
  };
  updateSession(session);
  updateProjectThreadAssignment(threadID, project?.id);
  if (!isTemporary && persistEmptyConversation) createEmptyConversation(threadID);
  return {
    session,
    thread: {
      id: threadID,
      title: session.title,
      projectID: project?.id,
      project: project?.title,
      activeProvider: session.activeProvider,
      modelID: pluginString(session.modelID, session.latestModel),
      age: "1m",
      updatedAt: Date.now(),
      isTemporary,
      active: true
    } satisfies ThreadItem,
    detail: {
      threadID,
      title: session.title,
      messages: []
    } satisfies ThreadDetail
  };
}

export function destroyTemporaryThread(threadID: string) {
  const session = findSession(threadID);
  const conversationPath = path.join(conversationStoreRoot(), threadID);
  if (!session || (session.isTemporary !== true && session.conversationPersistence !== 0)) {
    fs.rmSync(conversationPath, { recursive: true, force: true });
    removeProjectThreadAssignment(threadID);
    return { ok: !fs.existsSync(conversationPath) };
  }
  const registry = loadSessionRegistry();
  saveSessionRegistry(registry.sessions.filter((item) => item.id.toLowerCase() !== threadID.toLowerCase()));
  fs.rmSync(conversationPath, { recursive: true, force: true });
  removeProjectThreadAssignment(threadID);
  return { ok: true };
}

function normalizedModelForBackend(backend: AssistantBackend, rawModelID?: unknown) {
  const requested = pluginString(rawModelID)?.trim() ?? "";
  const lowered = requested.toLowerCase();
  if (backend === "ollamaLocal") return requested || "gemma4:e2b";
  if (backend === "claudeCode") {
    if (lowered.includes("opus")) return "opus";
    if (lowered.includes("haiku")) return "haiku";
    if (lowered.includes("sonnet")) return "sonnet";
    return "sonnet";
  }
  if (backend === "copilot") {
    return requested || "auto";
  }
  return lowered.startsWith("gpt-") ? requested : readCodexDefaultModel();
}

export async function setThreadProvider(threadID: string, rawBackend: string, rawModelID?: string) {
  const backend = normalizeBackend(rawBackend);
  if (!isRuntimeBackend(backend)) {
    throw new Error("Main chat runtime must be Codex, Claude, Copilot, or Ollama.");
  }
  const session = ensureOpenAssistSessionRecord(threadID, backend);
  const existing = session.providerBindingsByBackend ?? [];
  const existingBinding = existing.find((binding) => binding.backend === backend);
  const modelID = normalizedModelForBackend(
    backend,
    rawModelID ?? existingBinding?.latestModelID ?? session.modelID ?? session.latestModel
  );
  const nextBinding = {
    ...(existingBinding ?? {}),
    backend,
    latestModelID: modelID,
    latestInteractionMode: "agentic",
    latestReasoningEffort: "high",
    lastConnectedAt: currentSwiftDate()
  };
  session.providerBindingsByBackend = [nextBinding, ...existing.filter((binding) => binding.backend !== backend)];
  session.activeProvider = backend;
  session.modelID = modelID;
  session.latestModel = modelID;
  updateSession(session);
  await refreshUsageForBackend(backend, { threadID, modelID, connectThread: true });
  const projects = loadProjects();
  return loadThreads(projects).find((thread) => thread.id.toLowerCase() === threadID.toLowerCase()) ?? null;
}

function renameSession(threadID: string, title: string) {
  const session = ensureOpenAssistSessionRecord(threadID);
  const nextTitle = normalizeTitle(title, "");
  if (!nextTitle) throw new Error("Chat title is required.");
  session.title = nextTitle;
  updateSession(session);
  const projects = loadProjects();
  return loadThreads(projects).find((thread) => thread.id.toLowerCase() === threadID.toLowerCase()) ?? null;
}

function promoteTemporarySession(threadID: string) {
  const session = ensureOpenAssistSessionRecord(threadID);
  session.isTemporary = false;
  session.conversationPersistence = 2;
  updateSession(session);
  const conversationPath = path.join(conversationStoreRoot(), threadID, "conversation.json");
  if (!fs.existsSync(conversationPath)) createEmptyConversation(threadID);
  const projects = loadProjects();
  return loadThreads(projects).find((thread) => thread.id.toLowerCase() === threadID.toLowerCase()) ?? null;
}

function assignSessionToProject(threadID: string, projectID?: string | null) {
  const session = ensureOpenAssistSessionRecord(threadID);
  const loadedProjects = loadProjects();
  const project = projectID
    ? loadedProjects.projects.find((item) => item.id.toLowerCase() === projectID.toLowerCase() && item.kind !== "folder")
    : undefined;
  if (projectID && !project) throw new Error("Project was not found.");
  if (project) {
    session.projectID = project.id;
    session.projectName = project.title;
    session.cwd = project.linkedFolderPath ?? session.cwd;
    session.effectiveCWD = project.linkedFolderPath ?? session.effectiveCWD;
    if (project.linkedFolderPath) {
      session.linkedProjectFolderPath = project.linkedFolderPath;
    } else {
      delete session.linkedProjectFolderPath;
    }
    updateProjectThreadAssignment(threadID, project.id);
  } else {
    delete session.projectID;
    delete session.projectName;
    delete session.linkedProjectFolderPath;
    removeProjectThreadAssignment(threadID);
  }
  updateSession(session);
  const projects = loadProjects();
  return loadThreads(projects).find((thread) => thread.id.toLowerCase() === threadID.toLowerCase()) ?? null;
}

function archiveSession(threadID: string) {
  const session = ensureOpenAssistSessionRecord(threadID);
  session.isArchived = true;
  updateSession(session);
  const projects = loadProjects();
  return loadThreads(projects).find((thread) => thread.id.toLowerCase() === threadID.toLowerCase()) ?? null;
}

function unarchiveSession(threadID: string) {
  const session = ensureOpenAssistSessionRecord(threadID);
  session.isArchived = false;
  updateSession(session);
  const projects = loadProjects();
  return loadThreads(projects).find((thread) => thread.id.toLowerCase() === threadID.toLowerCase()) ?? null;
}

function deleteSessionPermanently(threadID: string) {
  const registry = loadSessionRegistry();
  saveSessionRegistry(registry.sessions.filter((session) => session.id.toLowerCase() !== threadID.toLowerCase()));
  fs.rmSync(path.join(conversationStoreRoot(), threadID), { recursive: true, force: true });
  removeProjectThreadAssignment(threadID);
  return { ok: true };
}

function providerLabel(raw: string) {
  if (raw === "claudeCode") return "Claude";
  if (raw === "copilot") return "Copilot";
  if (raw === "ollamaLocal") return "Ollama";
  if (raw === "githubCopilot") return "Copilot";
  return raw.charAt(0).toUpperCase() + raw.slice(1);
}

function loadNotes(projects: LoadedProjects) {
  const notes: NoteItem[] = [];
  const noteFolders: NoteFolderItem[] = [];
  const notesRoot = path.join(projectStoreRoot(), "ProjectNotes");
  if (!fs.existsSync(notesRoot)) return { notes, noteFolders };
  for (const projectDir of fs.readdirSync(notesRoot)) {
    const projectID = projectDir.toUpperCase();
    if (projects.hiddenProjectIDs.has(projectID.toLowerCase())) continue;
    const projectName = projects.projectNameByID.get(projectID) ?? projects.projectNameByID.get(projectDir) ?? "Project";
    const manifestPath = path.join(notesRoot, projectDir, "notes", "manifest.json");
    const manifest = readJSON<{ notes?: JsonObject[]; folders?: JsonObject[]; selectedNoteID?: string }>(manifestPath, {});
    const folderCounts = new Map<string, number>();
    for (const note of manifest.notes ?? []) {
      const folderID = typeof note.folderID === "string" ? note.folderID : null;
      if (folderID) folderCounts.set(folderID, (folderCounts.get(folderID) ?? 0) + 1);
    }
    for (const folder of manifest.folders ?? []) {
      const id = String(folder.id ?? "");
      if (!id) continue;
      noteFolders.push({
        id,
        name: normalizeTitle(folder.name, "Folder"),
        projectID,
        noteCount: folderCounts.get(id) ?? 0
      });
    }
    for (const note of manifest.notes ?? []) {
      const id = String(note.id ?? "");
      if (!id) continue;
      const updatedAt = swiftDateToMs(note.updatedAt);
      notes.push({
        id,
        projectID,
        projectName,
        folderID: typeof note.folderID === "string" ? note.folderID : null,
        title: normalizeTitle(note.title, "Untitled note"),
        subtitle: noteSubtitle(updatedAt),
        updatedAt,
        active: manifest.selectedNoteID === id
      });
    }
  }
  notes.sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0));
  if (!notes.some((note) => note.active) && notes.length) notes[0].active = true;
  return { notes, noteFolders };
}

function noteManifestPath(projectID: string) {
  return path.join(projectStoreRoot(), "ProjectNotes", projectID.toUpperCase(), "notes", "manifest.json");
}

function noteDirectoryPath(projectID: string) {
  return path.join(projectStoreRoot(), "ProjectNotes", projectID.toUpperCase(), "notes");
}

function readNoteManifest(projectID: string) {
  return readJSON<{ version?: number; selectedNoteID?: string; notes?: JsonObject[]; folders?: JsonObject[] }>(
    noteManifestPath(projectID),
    { version: 3, notes: [], folders: [] }
  );
}

function writeNoteManifest(projectID: string, manifest: { version?: number; selectedNoteID?: string; notes?: JsonObject[]; folders?: JsonObject[] }) {
  writeJSON(noteManifestPath(projectID), {
    version: Math.max(3, Number(manifest.version ?? 3)),
    selectedNoteID: manifest.selectedNoteID,
    folders: manifest.folders ?? [],
    notes: manifest.notes ?? []
  });
}

function loadNote(projectID: string, noteID: string): NoteDetail {
  const manifest = readNoteManifest(projectID);
  const note = (manifest.notes ?? []).find((entry) => entry.id === noteID);
  const fileName = typeof note?.fileName === "string" ? note.fileName : `${noteID}.md`;
  if (note && manifest.selectedNoteID !== noteID) {
    manifest.selectedNoteID = noteID;
    writeNoteManifest(projectID, manifest);
  }
  const filePath = path.join(noteDirectoryPath(projectID), fileName);
  return {
    id: noteID,
    title: normalizeTitle(note?.title, "Untitled note"),
    markdown: fs.existsSync(filePath) ? fs.readFileSync(filePath, "utf8") : "",
    path: filePath
  };
}

function createProjectNote(projectID: string) {
  const manifest = readNoteManifest(projectID);
  const noteID = randomUUID().toLowerCase();
  const now = currentSwiftDate();
  const note: JsonObject = {
    id: noteID,
    title: "Untitled note",
    noteType: "note",
    fileName: `${noteID}.md`,
    order: (manifest.notes ?? []).length,
    createdAt: now,
    updatedAt: now
  };
  manifest.notes = [...(manifest.notes ?? []), note];
  manifest.selectedNoteID = noteID;
  writeNoteManifest(projectID, manifest);
  const noteItem: NoteItem = {
    id: noteID,
    title: "Untitled note",
    subtitle: "Saved just now",
    projectID: projectID.toUpperCase(),
    updatedAt: Date.now(),
    active: true
  };
  return {
    note: noteItem,
    detail: {
      id: noteID,
      title: "Untitled note",
      markdown: "",
      path: path.join(noteDirectoryPath(projectID), `${noteID}.md`)
    } satisfies NoteDetail
  };
}

function saveProjectNote(projectID: string, noteID: string, markdown: string): NoteDetail {
  const manifest = readNoteManifest(projectID);
  const note = (manifest.notes ?? []).find((entry) => entry.id === noteID);
  if (!note) throw new Error("Note was not found.");
  const now = currentSwiftDate();
  note.updatedAt = now;
  manifest.selectedNoteID = noteID;
  writeNoteManifest(projectID, manifest);
  const fileName = typeof note.fileName === "string" ? note.fileName : `${noteID}.md`;
  const filePath = path.join(noteDirectoryPath(projectID), fileName);
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, markdown.replace(/\r\n/g, "\n"), "utf8");
  return {
    id: noteID,
    title: normalizeTitle(note.title, "Untitled note"),
    markdown,
    path: filePath
  };
}

function noteImageMimeType(filePath: string) {
  const extension = path.extname(filePath).toLowerCase();
  if (extension === ".jpg" || extension === ".jpeg") return "image/jpeg";
  if (extension === ".gif") return "image/gif";
  if (extension === ".webp") return "image/webp";
  if (extension === ".svg") return "image/svg+xml";
  if (extension === ".tif" || extension === ".tiff") return "image/tiff";
  return "image/png";
}

function readNoteImageDataURL(notePath: string, imageSrc: string) {
  const sourcePath = String(notePath ?? "").trim();
  const rawSource = String(imageSrc ?? "").trim();
  if (!sourcePath || !rawSource) return null;
  if (/^(https?:|data:|blob:|openassist-note-asset:)/i.test(rawSource)) return rawSource;

  const withoutDisplayFragment = rawSource
    .replace(/#oa-note-attrs=[^#]+$/i, "")
    .replace(/#oa-note-width=\d+$/i, "");
  const sourceWithoutHash = withoutDisplayFragment.split("#")[0] || withoutDisplayFragment;
  const decodedSource = decodeURIComponent(sourceWithoutHash);
  let candidatePath = "";
  try {
    if (/^file:/i.test(decodedSource)) {
      candidatePath = fileURLToPath(decodedSource);
    } else if (path.isAbsolute(decodedSource)) {
      candidatePath = decodedSource;
    } else {
      candidatePath = path.resolve(path.dirname(sourcePath), decodedSource);
    }
  } catch {
    return null;
  }

  if (!candidatePath || !fs.existsSync(candidatePath)) return null;
  const stat = fs.statSync(candidatePath);
  if (!stat.isFile()) return null;
  return `data:${noteImageMimeType(candidatePath)};base64,${fs.readFileSync(candidatePath).toString("base64")}`;
}

async function loadAutomations(): Promise<AutomationItem[]> {
  const database = path.join(supportRoot(), "scheduled_jobs.sqlite");
  if (!fs.existsSync(database)) return [];
  try {
    const { stdout } = await execFileAsync("sqlite3", [
      "-json",
      database,
      "select id,name,prompt,recurrence,hour,minute,weekday,interval_minutes,is_enabled from scheduled_jobs order by created_at asc;"
    ]);
    const rows = JSON.parse(stdout || "[]") as Array<Record<string, unknown>>;
    return rows.map((row) => ({
      id: String(row.id),
      title: normalizeTitle(row.name, "Scheduled job"),
      prompt: typeof row.prompt === "string" ? row.prompt : undefined,
      schedule: scheduleLabel(row),
      enabled: Number(row.is_enabled) === 1
    }));
  } catch {
    return [];
  }
}

function scheduleLabel(row: Record<string, unknown>) {
  const recurrence = String(row.recurrence ?? "daily");
  const hour = Number(row.hour ?? 9);
  const minute = Number(row.minute ?? 0);
  const suffix = hour >= 12 ? "PM" : "AM";
  const displayHour = hour % 12 === 0 ? 12 : hour % 12;
  const time = `${displayHour}:${String(minute).padStart(2, "0")} ${suffix}`;
  if (recurrence === "weekdays") return `Weekdays at ${time}`;
  if (recurrence === "weekends") return `Weekends at ${time}`;
  if (recurrence === "weekly") return `Weekly at ${time}`;
  if (recurrence === "everyHour") return `Every hour at :${String(minute).padStart(2, "0")}`;
  if (recurrence === "interval" || recurrence === "everyNMinutes") return `Every ${row.interval_minutes ?? 60} min`;
  return `Daily at ${time}`;
}

function sqliteText(value: string) {
  return `'${value.replace(/'/g, "''")}'`;
}

async function ensureScheduledJobSchema(database: string) {
  fs.mkdirSync(path.dirname(database), { recursive: true });
  const schema = `
PRAGMA foreign_keys=ON;
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS scheduled_jobs (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  prompt TEXT NOT NULL,
  job_type TEXT NOT NULL DEFAULT 'general',
  recurrence TEXT NOT NULL DEFAULT 'daily',
  hour INTEGER NOT NULL DEFAULT 9,
  minute INTEGER NOT NULL DEFAULT 0,
  weekday INTEGER NOT NULL DEFAULT 2,
  interval_minutes INTEGER NOT NULL DEFAULT 60,
  is_enabled INTEGER NOT NULL DEFAULT 1,
  last_run_at REAL,
  next_run_at REAL,
  created_at REAL NOT NULL,
  preferred_model_id TEXT,
  reasoning_effort TEXT,
  last_run_note TEXT,
  dedicated_session_id TEXT,
  last_run_outcome TEXT,
  last_run_started_at REAL,
  last_run_finished_at REAL,
  last_run_first_issue_at REAL,
  last_run_summary TEXT,
  last_learned_lesson_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS scheduled_job_runs (
  id TEXT PRIMARY KEY,
  job_id TEXT NOT NULL,
  session_id TEXT,
  started_at REAL NOT NULL,
  finished_at REAL,
  outcome TEXT,
  first_issue_at REAL,
  status_note TEXT,
  summary_text TEXT,
  learned_lesson_count INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY(job_id) REFERENCES scheduled_jobs(id) ON DELETE CASCADE
);
`;
  await execFileAsync("sqlite3", [database, schema]);
}

function defaultNextDailyRunTimestamp() {
  const nextRun = new Date();
  nextRun.setHours(9, 0, 0, 0);
  if (nextRun.getTime() <= Date.now()) nextRun.setDate(nextRun.getDate() + 1);
  return nextRun.getTime() / 1000;
}

async function createScheduledJob(name: string, prompt: string) {
  const title = name.replace(/\s+/g, " ").trim();
  const body = prompt.trim();
  if (!title || !body) throw new Error("Scheduled job name and prompt are required.");
  const database = path.join(supportRoot(), "scheduled_jobs.sqlite");
  await ensureScheduledJobSchema(database);
  const id = randomUUID().toUpperCase();
  const createdAt = Date.now() / 1000;
  const nextRunAt = defaultNextDailyRunTimestamp();
  const sql = `
INSERT INTO scheduled_jobs (
  id, name, prompt, job_type, recurrence, hour, minute, weekday,
  interval_minutes, is_enabled, next_run_at, created_at, last_learned_lesson_count
) VALUES (
  ${sqliteText(id)}, ${sqliteText(title)}, ${sqliteText(body)}, 'general', 'daily', 9, 0, 2,
  60, 1, ${nextRunAt}, ${createdAt}, 0
);
`;
  await execFileAsync("sqlite3", [database, sql]);
  return {
    id,
    title,
    prompt: body,
    schedule: "Daily at 9:00 AM",
    enabled: true
  } satisfies AutomationItem;
}

async function toggleScheduledJob(jobID: string, enabled: boolean) {
  const database = path.join(supportRoot(), "scheduled_jobs.sqlite");
  if (!fs.existsSync(database)) return { ok: false };
  await execFileAsync("sqlite3", [database, `update scheduled_jobs set is_enabled=${enabled ? 1 : 0} where id='${jobID.replace(/'/g, "''")}';`]);
  return { ok: true };
}

function threadSkillStorePath() {
  return path.join(supportRoot(), "AssistantThreadSkills", "thread-skills.json");
}

function normalizedSkillID(value: string) {
  return value.trim().toLowerCase();
}

function activeSkillIDs(threadID?: string) {
  const normalizedThreadID = threadID?.trim().toLowerCase();
  if (!normalizedThreadID) return new Set<string>();
  const snapshot = readJSON<{ bindings?: JsonObject[] }>(threadSkillStorePath(), {});
  return new Set(
    (snapshot.bindings ?? [])
      .filter((binding) => String(binding.threadID ?? "").toLowerCase() === normalizedThreadID)
      .map((binding) => normalizedSkillID(String(binding.skillName ?? "")))
      .filter(Boolean)
  );
}

function writeThreadSkillBinding(threadID: string, skillID: string, attached: boolean) {
  const normalizedThreadID = threadID.trim().toLowerCase();
  const normalizedSkill = normalizedSkillID(skillID);
  if (!normalizedThreadID || !normalizedSkill) return { ok: false };
  const snapshot = readJSON<{ version?: number; bindings?: JsonObject[] }>(threadSkillStorePath(), { version: 1, bindings: [] });
  const bindings = (snapshot.bindings ?? []).filter(
    (binding) =>
      String(binding.threadID ?? "").toLowerCase() !== normalizedThreadID ||
      normalizedSkillID(String(binding.skillName ?? "")) !== normalizedSkill
  );
  if (attached) {
    bindings.push({ threadID: normalizedThreadID, skillName: normalizedSkill, attachedAt: currentSwiftDate() });
  }
  writeJSON(threadSkillStorePath(), { version: 1, bindings });
  return { ok: true };
}

function loadSkills(threadID?: string): SkillItem[] {
  const roots = [path.join(codexRoot(), "skills")];
  const items: SkillItem[] = [];
  const attachedIDs = activeSkillIDs(threadID);
  for (const root of roots) {
    if (!fs.existsSync(root)) continue;
    for (const filePath of walk(root, "SKILL.md", 5)) {
      const markdown = fs.readFileSync(filePath, "utf8");
      const metadata = parseFrontmatter(markdown);
      const id = path.basename(path.dirname(filePath));
      const iconPath = resolveSkillIcon(filePath, metadata);
      items.push({
        id,
        title: titleFromSkill(id, metadata.name),
        description: normalizeTitle(metadata.description, firstParagraph(markdown)),
        group: filePath.includes(`${path.sep}.system${path.sep}`) ? "built-in" : "my-skills",
        path: filePath,
        readOnly: filePath.includes(`${path.sep}.system${path.sep}`),
        iconPath,
        attached: attachedIDs.has(normalizedSkillID(String(metadata.name ?? id))) || attachedIDs.has(normalizedSkillID(id))
      });
    }
  }
  for (const pluginFilePath of walk(path.join(codexRoot(), "plugins/cache"), "plugin.json", 8)) {
    const plugin = readJSON<JsonObject>(pluginFilePath, {});
    const iface = asObject(plugin.interface);
    const pluginName = pluginString(plugin.name, path.basename(path.dirname(path.dirname(pluginFilePath))));
    const skillsPath = pluginString(plugin.skills);
    if (!pluginName || !skillsPath) continue;
    const pluginIcon = resolveCachedPluginAsset(pluginName, undefined, pluginString(iface?.composerIcon, iface?.logo), pluginFilePath);
    const pluginRoot = path.resolve(path.dirname(pluginFilePath), "..");
    const skillRoot = path.resolve(pluginRoot, skillsPath);
    if (!fs.existsSync(skillRoot)) continue;
    for (const filePath of walk(skillRoot, "SKILL.md", 6)) {
      const markdown = fs.readFileSync(filePath, "utf8");
      const metadata = parseFrontmatter(markdown);
      const localID = path.basename(path.dirname(filePath));
      const id = `${pluginName}:${localID}`;
      const iconPath = resolveSkillIcon(filePath, metadata, pluginIcon);
      items.push({
        id,
        title: titleFromSkill(localID, metadata.name),
        description: normalizeTitle(metadata.description, firstParagraph(markdown)),
        group: "imported",
        path: filePath,
        readOnly: true,
        iconPath,
        attached: attachedIDs.has(normalizedSkillID(id)) || attachedIDs.has(normalizedSkillID(String(metadata.name ?? localID)))
      });
    }
  }
  const seen = new Set<string>();
  return items
    .filter((item) => {
      const key = `${item.id}:${item.path ?? ""}`.toLowerCase();
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .sort((a, b) => a.title.localeCompare(b.title));
}

function skillItemForDirectory(directory: string): SkillItem {
  const skillPath = path.join(directory, "SKILL.md");
  const markdown = fs.readFileSync(skillPath, "utf8");
  const metadata = parseFrontmatter(markdown);
  const id = path.basename(directory);
  const iconPath = resolveSkillIcon(skillPath, metadata);
  return {
    id,
    title: titleFromSkill(id, metadata.name),
    description: normalizeTitle(metadata.description, firstParagraph(markdown)),
    group: "my-skills",
    path: skillPath,
    readOnly: false,
    iconPath,
    attached: false
  };
}

function normalizedSkillFolderName(value: string) {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
}

function uniqueSkillFolderName(baseName: string) {
  const root = path.join(codexRoot(), "skills");
  const base = normalizedSkillFolderName(baseName) || "new-skill";
  for (let index = 0; index < 200; index += 1) {
    const candidate = index === 0 ? base : `${base}-${index + 1}`;
    if (!fs.existsSync(path.join(root, candidate))) return candidate;
  }
  return `${base}-${Date.now()}`;
}

function writeSkillOriginMetadata(directory: string, source: "imported" | "generated", originalReference?: string) {
  writeJSON(path.join(directory, ".openassist-skill.json"), {
    version: 1,
    source,
    originalReference,
    createdAt: currentSwiftDate()
  });
}

function importSkillFolder(sourcePath: string) {
  const resolved = path.resolve(sourcePath);
  const stats = fs.statSync(resolved);
  const sourceDirectory = stats.isDirectory() ? resolved : path.dirname(resolved);
  const skillPath = path.join(sourceDirectory, "SKILL.md");
  if (!fs.existsSync(skillPath)) throw new Error("That folder does not contain SKILL.md.");
  const markdown = fs.readFileSync(skillPath, "utf8");
  const metadata = parseFrontmatter(markdown);
  const destinationName = uniqueSkillFolderName(String(metadata.name ?? path.basename(sourceDirectory)));
  const destinationDirectory = path.join(codexRoot(), "skills", destinationName);
  fs.mkdirSync(path.dirname(destinationDirectory), { recursive: true });
  fs.cpSync(sourceDirectory, destinationDirectory, { recursive: true, force: false, errorOnExist: true });
  writeSkillOriginMetadata(destinationDirectory, "imported", sourceDirectory);
  return skillItemForDirectory(destinationDirectory);
}

function skillMarkdown(name: string, description: string) {
  const normalizedName = normalizedSkillFolderName(name) || "new-skill";
  const trimmedDescription = description.replace(/\s+/g, " ").trim() || "Use this skill for repeatable Open Assist work.";
  return [
    "---",
    `name: ${normalizedName}`,
    `description: ${trimmedDescription}`,
    "metadata:",
    `  short-description: ${JSON.stringify(trimmedDescription)}`,
    "---",
    "",
    `# ${titleFromSkill(normalizedName)}`,
    "",
    `Use this skill when ${trimmedDescription}`,
    "",
    "## Workflow",
    "",
    "- Read this skill before doing the task.",
    "- Keep the work practical and grounded in the current repo or app state.",
    "- Explain the result in simple language."
  ].join("\n");
}

function createSkill(name: string, description: string) {
  const destinationName = uniqueSkillFolderName(name);
  const destinationDirectory = path.join(codexRoot(), "skills", destinationName);
  fs.mkdirSync(destinationDirectory, { recursive: true });
  fs.writeFileSync(path.join(destinationDirectory, "SKILL.md"), `${skillMarkdown(destinationName, description)}\n`, "utf8");
  writeSkillOriginMetadata(destinationDirectory, "generated");
  return skillItemForDirectory(destinationDirectory);
}

function parseGitHubSkillReference(reference: string) {
  const trimmed = reference.trim();
  const treeMatch = /^https:\/\/github\.com\/([^/]+)\/([^/]+)\/tree\/([^/]+)\/(.+)$/i.exec(trimmed);
  if (treeMatch) {
    return {
      repoURL: `https://github.com/${treeMatch[1]}/${treeMatch[2]}.git`,
      ref: treeMatch[3],
      path: treeMatch[4]
    };
  }
  const repoMatch = /^(?:https:\/\/github\.com\/)?([^/\s]+)\/([^/\s]+)(?:\/(.+))?$/i.exec(trimmed.replace(/\.git$/, ""));
  if (repoMatch) {
    return {
      repoURL: `https://github.com/${repoMatch[1]}/${repoMatch[2]}.git`,
      ref: "main",
      path: repoMatch[3] ?? ""
    };
  }
  throw new Error("Use a GitHub URL or owner/repo/path reference.");
}

async function importSkillFromGitHub(reference: string) {
  const parsed = parseGitHubSkillReference(reference);
  const tempRoot = path.join(os.tmpdir(), `openassist-electron-skill-${randomUUID().toLowerCase()}`);
  try {
    await execFileAsync("git", ["clone", "--depth", "1", "--branch", parsed.ref, parsed.repoURL, tempRoot]);
  } catch {
    await execFileAsync("git", ["clone", "--depth", "1", parsed.repoURL, tempRoot]);
  }
  try {
    return importSkillFolder(path.join(tempRoot, parsed.path));
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

function fileURLForLocalPath(filePath?: string | null) {
  if (!filePath) return null;
  if (/^(https?:|data:|blob:)/i.test(filePath)) return filePath;
  if (/^file:/i.test(filePath) || path.isAbsolute(filePath)) return localImageDataURL(filePath);
  return null;
}

function localImageDataURL(rawPath?: string | null) {
  const source = pluginString(rawPath);
  if (!source) return null;
  if (/^(https?:|data:|blob:)/i.test(source)) return source;
  let filePath = source;
  try {
    if (/^file:/i.test(filePath)) filePath = fileURLToPath(filePath);
  } catch {
    return null;
  }
  if (!path.isAbsolute(filePath) || !fs.existsSync(filePath)) return null;
  try {
    const stat = fs.statSync(filePath);
    if (!stat.isFile() || stat.size > 5_000_000) return null;
    return `data:${noteImageMimeType(filePath)};base64,${fs.readFileSync(filePath).toString("base64")}`;
  } catch {
    return null;
  }
}

function resolveSkillIcon(filePath: string, metadata: Record<string, string>, fallbackIcon?: string | null) {
  const directory = path.dirname(filePath);
  const metadataIcon = pluginString(metadata.icon, metadata.logo, metadata.composerIcon);
  if (metadataIcon) {
    const candidate = /^(https?:|file:|data:|blob:)/i.test(metadataIcon) || path.isAbsolute(metadataIcon)
      ? metadataIcon
      : path.resolve(directory, metadataIcon);
    const resolved = fileURLForLocalPath(candidate);
    if (resolved) return resolved;
  }
  for (const fileName of ["icon.png", "icon.svg", "icon.jpg", "icon.jpeg", "icon.webp", "logo.png", "logo.svg"]) {
    const resolved = fileURLForLocalPath(path.join(directory, fileName));
    if (resolved) return resolved;
  }
  return fallbackIcon ?? null;
}

function resolveCachedPluginAsset(pluginName?: string, marketplacePath?: string, rawAssetPath?: string | null, pluginFilePath?: string) {
  const rawPath = pluginString(rawAssetPath);
  if (!rawPath) return null;
  if (/^(https?:|file:|data:|blob:)/i.test(rawPath) || path.isAbsolute(rawPath)) return fileURLForLocalPath(rawPath);
  if (pluginFilePath) {
    const fromPluginFile = path.resolve(path.dirname(pluginFilePath), "..", rawPath);
    if (fs.existsSync(fromPluginFile)) return fileURLForLocalPath(fromPluginFile);
  }
  const cacheRoot = path.join(codexRoot(), "plugins/cache");
  if (!fs.existsSync(cacheRoot)) return null;
  const pluginNameKey = (pluginName ?? "").trim().toLowerCase();
  const marketplaceKey = (marketplacePath ?? "").trim().toLowerCase();
  for (const filePath of walk(cacheRoot, "plugin.json", 8)) {
    const plugin = readJSON<JsonObject>(filePath, {});
    const candidateName = pluginString(plugin.name, path.basename(path.dirname(path.dirname(filePath))))?.toLowerCase();
    const parts = filePath.split(path.sep);
    const cacheIndex = parts.lastIndexOf("cache");
    const candidateMarketplace = cacheIndex >= 0 ? parts[cacheIndex + 1]?.toLowerCase() : "";
    const marketplaceMatches = !marketplaceKey
      || !candidateMarketplace
      || marketplaceKey === candidateMarketplace
      || marketplaceKey.startsWith(`${candidateMarketplace}/`);
    if (pluginNameKey && candidateName !== pluginNameKey) continue;
    if (!marketplaceMatches) continue;
    const candidate = path.resolve(path.dirname(filePath), "..", rawPath);
    if (fs.existsSync(candidate)) return fileURLForLocalPath(candidate);
  }
  return null;
}

function loadPluginsFromCache(): PluginItem[] {
  const cache = path.join(codexRoot(), "plugins/cache");
  if (!fs.existsSync(cache)) return [];
  return walk(cache, "plugin.json", 8)
    .map((filePath) => {
      const plugin = readJSON<JsonObject>(filePath, {});
      const iface = (plugin.interface as JsonObject | undefined) ?? {};
      const parts = filePath.split(path.sep);
      const cacheIndex = parts.lastIndexOf("cache");
      const marketplacePath = cacheIndex >= 0 ? parts[cacheIndex + 1] : undefined;
      const pluginName = pluginString(plugin.name, cacheIndex >= 0 ? parts[cacheIndex + 2] : undefined, path.basename(path.dirname(path.dirname(filePath))));
      const id = pluginName && marketplacePath
        ? `${pluginName}@${marketplacePath}`
        : normalizeTitle(pluginName, path.basename(path.dirname(path.dirname(filePath))));
      return {
        id,
        pluginName,
        marketplacePath,
        marketplaceName: marketplacePath ? titleFromSkill(marketplacePath) : undefined,
        title: normalizeTitle(iface.displayName, titleFromSkill(id)),
        description: normalizeTitle(iface.shortDescription, normalizeTitle(plugin.description, "")),
        longDescription: normalizeTitle(iface.longDescription, ""),
        status: "Installed" as const,
        logoPath: resolveCachedPluginAsset(id, undefined, pluginString(iface.composerIcon, iface.logo, plugin.composerIcon, plugin.logo, plugin.icon), filePath),
        starterPrompts: Array.isArray(iface.defaultPrompt) ? iface.defaultPrompt.map(String) : [],
        appNames: typeof plugin.apps === "string" ? [normalizeTitle(iface.displayName, id)] : []
      };
    })
    .sort((a, b) => a.title.localeCompare(b.title));
}

function pluginMentionName(pluginID: string, plugin?: PluginItem) {
  const title = plugin?.title?.trim();
  if (title) return title;
  const pluginName = pluginID.split("@")[0]?.trim() || pluginID;
  return titleFromSkill(pluginName);
}

function pluginIDCandidates(plugin: PluginItem) {
  const candidates = [
    plugin.id,
    canonicalizeCodexPluginID(plugin.id),
    plugin.pluginName && plugin.marketplacePath ? `${plugin.pluginName}@${plugin.marketplacePath}` : undefined
  ];
  return candidates
    .map((candidate) => candidate ? canonicalizeCodexPluginID(candidate).toLowerCase() : "")
    .filter(Boolean);
}

function dedupeComputerUsePluginVariants(plugins: PluginItem[]): PluginItem[] {
  const hasBundled = plugins.some(
    (plugin) => plugin.id.toLowerCase() === codexPreferredComputerUsePluginID
  );
  if (!hasBundled) return plugins;
  return plugins.filter(
    (plugin) =>
      plugin.id.toLowerCase() !== "computer-use@openai-curated"
  );
}

async function loadPlugins(): Promise<PluginItem[]> {
  try {
    const raw = await withTimeout(codexTransport.request("plugin/list", {}), 20_000);
    const plugins = parseCodexPluginList(raw);
    if (plugins.length) return dedupeComputerUsePluginVariants(plugins);
  } catch {
    // Fall back to the local cache so the plugins screen still reflects real installed files.
  }
  return dedupeComputerUsePluginVariants(loadPluginsFromCache());
}

function parseCodexPluginList(raw: unknown): PluginItem[] {
  const plugins: PluginItem[] = [];
  const payload = asObject(raw);
  const marketplaces = Array.isArray(payload?.marketplaces) ? payload.marketplaces : [];
  if (marketplaces.length) {
    for (const marketRaw of marketplaces) {
      const market = asObject(marketRaw);
      const marketInterface = asObject(market?.interface);
      const marketplaceName = pluginString(marketInterface?.displayName, market?.name, market?.path) ?? "Codex";
      const marketplacePath = pluginString(market?.path, market?.marketplacePath, market?.name) ?? "default";
      const items = Array.isArray(market?.plugins) ? market.plugins : [];
      for (const itemRaw of items) {
        const item = parsePluginSummary(itemRaw, marketplaceName, marketplacePath);
        if (item) plugins.push(item);
      }
    }
  } else {
    const items = Array.isArray(payload?.plugins)
      ? payload?.plugins
      : Array.isArray(payload?.items)
        ? payload?.items
        : Array.isArray(raw)
          ? raw
          : [];
    for (const itemRaw of items) {
      const item = parsePluginSummary(itemRaw, "Codex", "default");
      if (item) plugins.push(item);
    }
  }
  const seen = new Set<string>();
  return plugins
    .filter((plugin) => {
      const key = plugin.id.toLowerCase();
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .sort((a, b) => {
      if (a.status !== b.status) return a.status === "Installed" ? -1 : b.status === "Installed" ? 1 : 0;
      return a.title.localeCompare(b.title);
    });
}

function parsePluginSummary(raw: unknown, marketplaceName: string, marketplacePath: string): PluginItem | null {
  const item = asObject(raw);
  if (!item) return null;
  const iface = asObject(item.interface);
  const pluginName = pluginString(item.name, item.pluginName, item.id?.toString().split("@")[0]);
  if (!pluginName) return null;
  const id = pluginString(item.id, `${pluginName}@${marketplacePath}`) ?? pluginName;
  const installed = Boolean(item.installed);
  const enabled = item.enabled !== false;
  const status: PluginItem["status"] = installed && enabled ? "Installed" : installed ? "Needs Setup" : "Available";
  return {
    id,
    pluginName,
    marketplaceName,
    marketplacePath,
    title: pluginString(iface?.displayName, pluginName) ?? titleFromSkill(pluginName),
    description: pluginString(iface?.shortDescription, item.description, iface?.longDescription) ?? "",
    longDescription: pluginString(iface?.longDescription, item.description, iface?.shortDescription) ?? "",
    status,
    logoPath: resolveCachedPluginAsset(
      pluginName,
      marketplacePath,
      pluginString(iface?.composerIcon, iface?.logo, item.composerIcon, item.logo, item.iconPath, item.logoPath, item.icon)
    ),
    starterPrompts: Array.isArray(iface?.defaultPrompt) ? iface.defaultPrompt.map(String) : [],
    appNames: [],
    selected: false
  };
}

async function pluginPromptItems(pluginIDs: string[], prompt: string) {
  const canonicalIDs = canonicalizeCodexPluginIDs(pluginIDs);
  const normalizedIDs = new Set(canonicalIDs.map(normalizedCodexPluginID).filter((id): id is string => Boolean(id)));
  if (!canonicalIDs.length) return [];
  const installedPlugins = (await loadPlugins()).filter((plugin) => plugin.status === "Installed");
  const pluginByID = new Map<string, PluginItem>();
  for (const plugin of installedPlugins) {
    for (const candidate of pluginIDCandidates(plugin)) {
      if (normalizedIDs.has(candidate)) pluginByID.set(candidate, plugin);
    }
  }
  const plugins = canonicalIDs
    .map((pluginID) => pluginByID.get(pluginID.toLowerCase()))
    .filter((plugin): plugin is PluginItem => Boolean(plugin));
  const inputItems: JsonObject[] = canonicalIDs.map((pluginID) => ({
    type: "mention",
    name: pluginMentionName(pluginID, pluginByID.get(pluginID.toLowerCase())),
    path: `plugin://${pluginID}`
  }));
  if (shouldPreferCodexComputerUsePlugin(canonicalIDs)) {
    inputItems.push({
      type: "text",
      text: [
        "OpenAssist Computer Use note: Computer Use app-state calls can time out from this app.",
        "For a Notes read/search request, use read-only osascript first instead of waiting on get_app_state/list_apps.",
        "If a Computer Use call fails once, do not retry it in this turn."
      ].join(" ")
    });
  }
  for (const plugin of plugins) {
    const detail = await readPluginDetail(plugin).catch(() => null);
    if (!detail) continue;
    for (const skill of detail.skills) {
      if (skill.path) {
        inputItems.push({ type: "skill", name: skill.displayName || skill.name || plugin.title, path: skill.path });
      }
    }
    for (const app of detail.apps) {
      const appName = String(app.name ?? "").trim();
      if (app.id && appName && prompt.toLowerCase().includes(appName.toLowerCase())) {
        inputItems.push({ type: "mention", name: appName || plugin.title, path: `app://${app.id}` });
      }
    }
  }
  return inputItems;
}

async function readPluginDetail(plugin: PluginItem) {
  if (!plugin.marketplacePath || !plugin.pluginName) return { skills: [], apps: [] };
  const raw = await withTimeout(
    codexTransport.request("plugin/read", {
      marketplacePath: plugin.marketplacePath,
      pluginName: plugin.pluginName
    }),
    10_000
  );
  const payload = asObject(raw);
  const detail = asObject(payload?.plugin) ?? payload;
  const skills = (Array.isArray(detail?.skills) ? detail.skills : [])
    .map(asObject)
    .filter(Boolean)
    .map((skill) => ({
      name: pluginString(skill?.name) ?? "",
      displayName: pluginString(skill?.displayName, skill?.name) ?? "",
      path: pluginString(skill?.path) ?? ""
    }));
  const apps = (Array.isArray(detail?.apps) ? detail.apps : [])
    .map(asObject)
    .filter(Boolean)
    .map((app) => ({
      id: pluginString(app?.id) ?? "",
      name: pluginString(app?.name, app?.id) ?? ""
    }));
  return { skills, apps };
}

function asObject(value: unknown): JsonObject | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : null;
}

function pluginString(...values: unknown[]) {
  for (const value of values) {
    if (typeof value !== "string") continue;
    const trimmed = value.trim();
    if (trimmed) return trimmed;
  }
  return undefined;
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Timed out.")), ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      }
    );
  });
}

function objectCandidateDictionaries(raw: unknown, nestedKeys = ["result", "status", "auth", "data", "credentials", "account"]) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return [];
  const dictionaries: JsonObject[] = [raw as JsonObject];
  for (let index = 0; index < dictionaries.length; index += 1) {
    const dictionary = dictionaries[index];
    for (const key of nestedKeys) {
      const nested = dictionary[key];
      if (nested && typeof nested === "object" && !Array.isArray(nested) && !dictionaries.includes(nested as JsonObject)) {
        dictionaries.push(nested as JsonObject);
      }
    }
  }
  return dictionaries;
}

function parseAssistantAccountSnapshot(raw: unknown) {
  const dictionaries = objectCandidateDictionaries(raw);
  const responseError = dictionaries
    .map((dictionary) => {
      const detail = dictionary.detail as JsonObject | undefined;
      const details = dictionary.details as JsonObject | undefined;
      return firstNonEmptyString(dictionary.error, dictionary.message, detail?.message, details?.message);
    })
    .find(Boolean);
  if (responseError) throw new Error(responseError);

  const rawAuthMode = dictionaries
    .map((dictionary) => firstNonEmptyString(
      dictionary.authMode,
      dictionary.authMethod,
      dictionary.method,
      dictionary.type,
      dictionary.provider,
      dictionary.accountType
    ))
    .find(Boolean);
  const authMode = rawAuthMode ? assistantAccountAuthMode(rawAuthMode) : undefined;
  const email = dictionaries
    .map((dictionary) => firstNonEmptyString(dictionary.email, dictionary.accountEmail, dictionary.userEmail))
    .find(Boolean);
  const planType = dictionaries
    .map((dictionary) => firstNonEmptyString(dictionary.planType, dictionary.plan, dictionary.subscriptionPlan, dictionary.tier))
    .find(Boolean);
  const requiresOpenAIAuth = dictionaries.some((dictionary) =>
    dictionary.requiresOpenaiAuth === true
    || dictionary.requiresOpenAIAuth === true
    || dictionary.requiresAuth === true
    || dictionary.signedIn === false
    || dictionary.isAuthenticated === false
  );
  const hasSignedInSignal = dictionaries.some((dictionary) =>
    dictionary.signedIn === true
    || dictionary.isAuthenticated === true
    || dictionary.authenticated === true
    || dictionary.loggedIn === true
  );
  const resolvedMode = authMode ?? (email || planType || hasSignedInSignal ? "chatGPT" : "none");
  const signedIn = !requiresOpenAIAuth && (hasSignedInSignal || Boolean(email) || resolvedMode === "apiKey" || resolvedMode === "chatGPT");
  return {
    authMode: resolvedMode,
    email,
    planType,
    requiresOpenAIAuth,
    signedIn
  };
}

function assistantAccountSummary(snapshot: ReturnType<typeof parseAssistantAccountSnapshot>) {
  if (snapshot.email && snapshot.planType) return `${snapshot.email} (${snapshot.planType})`;
  if (snapshot.email) return snapshot.email;
  if (snapshot.authMode === "chatGPT") return "Signed in with ChatGPT";
  if (snapshot.authMode === "apiKey") return "Using an OpenAI API key";
  return "Not signed in";
}

function assistantAuthModeLabel(mode: TranscriptionAuthMode | undefined) {
  if (mode === "chatGPT") return "ChatGPT subscription";
  if (mode === "apiKey") return "OpenAI API key";
  return "Not connected";
}

function walk(root: string, filename: string, maxDepth: number) {
  const results: string[] = [];
  function visit(current: string, depth: number) {
    if (depth > maxDepth) return;
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const child = path.join(current, entry.name);
      if (entry.isFile() && entry.name === filename) results.push(child);
      if (entry.isDirectory()) visit(child, depth + 1);
    }
  }
  visit(root, 0);
  return results;
}

function parseFrontmatter(markdown: string) {
  if (!markdown.startsWith("---")) return {} as Record<string, string>;
  const end = markdown.indexOf("\n---", 3);
  if (end < 0) return {} as Record<string, string>;
  const block = markdown.slice(3, end);
  const result: Record<string, string> = {};
  for (const line of block.split(/\r?\n/)) {
    const match = /^([A-Za-z0-9_-]+):\s*(.*)$/.exec(line);
    if (match) result[match[1]] = match[2].replace(/^["']|["']$/g, "").trim();
  }
  return result;
}

function firstParagraph(markdown: string) {
  return markdown
    .replace(/^---[\s\S]*?---/, "")
    .split(/\n\s*\n/)
    .map((part) => part.replace(/^#+\s*/, "").trim())
    .find(Boolean) ?? "";
}

function titleFromSkill(id: string, name?: unknown) {
  const source = normalizeTitle(name, id);
  return source
    .split(/[-_: ]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

async function loadSettings(): Promise<SettingsSnapshot> {
  const readInfoPlist = async (key: string, fallback: string) => {
    const plist = path.join(openAssistRepoRoot(), "dist/Open Assist.app/Contents/Info.plist");
    if (!fs.existsSync(plist)) return fallback;
    try {
      const { stdout } = await execFileAsync("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", plist]);
      return stdout.trim() || fallback;
    } catch {
      return fallback;
    }
  };
  const assistantBackendRaw = await readDefault("OpenAssist.assistantBackend", "codex");
  const normalizedBackend = normalizeBackend(assistantBackendRaw);
  const assistantBackend = isRuntimeBackend(normalizedBackend) ? normalizedBackend : "codex";
  const promptRewriteProviderRaw = await readDefault("OpenAssist.promptRewriteProviderMode", "Ollama (Local)");
  const promptRewriteProvider = isPromptRewriteProvider(promptRewriteProviderRaw) ? promptRewriteProviderRaw : "Ollama (Local)";
  const promptRewriteModel = await readDefault("OpenAssist.promptRewriteOpenAIModel", promptRewriteDefaultModel(promptRewriteProvider));
  const promptRewriteBaseURL = await readDefault("OpenAssist.promptRewriteOpenAIBaseURL", promptRewriteDefaultBaseURL(promptRewriteProvider));
  const cloudTranscriptionProviderRaw = await readDefault("OpenAssist.cloudTranscriptionProvider", "OpenAI");
  const cloudTranscriptionProvider = isCloudTranscriptionProvider(cloudTranscriptionProviderRaw) ? cloudTranscriptionProviderRaw : "OpenAI";
  const cloudTranscriptionModel = await readDefault("OpenAssist.cloudTranscriptionModel", cloudTranscriptionDefaultModel(cloudTranscriptionProvider));
  const cloudTranscriptionBaseURL = await readDefault("OpenAssist.cloudTranscriptionBaseURL", cloudTranscriptionDefaultBaseURL(cloudTranscriptionProvider));
  const promptRewriteNeedsKey = promptRewriteProviderRequiresKey(promptRewriteProvider);
  const cloudTranscriptionNeedsKey = cloudTranscriptionProviderRequiresKey(cloudTranscriptionProvider);
  const promptRewriteAPIKeyConfigured = promptRewriteNeedsKey
    ? await hasKeychainPassword(promptRewriteKeychainAccount(promptRewriteProvider))
    : false;
  const cloudTranscriptionAPIKeyConfigured = cloudTranscriptionNeedsKey
    ? await hasKeychainPassword(cloudTranscriptionKeychainAccount(cloudTranscriptionProvider))
    : false;
  const realtimeOpenAIAPIKey = await resolveRealtimeOpenAIAPIKey();
  const assistantPreferredModel = await readDefault("OpenAssist.assistantPreferredModelID", readCodexDefaultModel());
  const availableAssistantBackends: RuntimeAssistantBackend[] = await selectableAssistantBackends(assistantBackend);
  const runtimeSetup = await runtimeSetupSnapshot(assistantBackend, availableAssistantBackends);
  const whisperModel = await readDefault("OpenAssist.selectedWhisperModelID", "base.en");
  const whisperInstalledModels = installedWhisperModelIDs();
  const telegramTokenConfigured = await hasKeychainPassword(telegramBotTokenKeychainAccount);
  const telegramOwnerUserID = await readDefault("OpenAssist.telegramOwnerUserID", "");
  const telegramOwnerChatID = await readDefault("OpenAssist.telegramOwnerChatID", "");
  const telegramPendingUserID = await readDefault("OpenAssist.telegramPendingUserID", "");
  const telegramPendingChatID = await readDefault("OpenAssist.telegramPendingChatID", "");
  const telegramPendingDisplayName = await readDefault("OpenAssist.telegramPendingDisplayName", "");
  const holdToTalkShortcutKeyCode = parsedShortcutValue(await readDefault("OpenAssist.shortcutKeyCode", "49"), 49);
  const holdToTalkShortcutModifiers = parsedShortcutValue(await readDefault("OpenAssist.shortcutModifiers", "1835008"), 1835008);
  const continuousToggleShortcutKeyCode = parsedShortcutValue(await readDefault("OpenAssist.continuousToggleShortcutKeyCode", "49"), 49);
  const continuousToggleShortcutModifiers = parsedShortcutValue(await readDefault("OpenAssist.continuousToggleShortcutModifiers", "1835008"), 1835008);
  const assistantLiveVoiceShortcutKeyCode = parsedShortcutValue(await readDefault("OpenAssist.assistantLiveVoiceShortcutKeyCode", "37"), 37);
  const assistantLiveVoiceShortcutModifiers = parsedShortcutValue(await readDefault("OpenAssist.assistantLiveVoiceShortcutModifiers", "1835008"), 1835008);
  const assistantCompactShortcutKeyCode = parsedShortcutValue(await readDefault("OpenAssist.assistantCompactShortcutKeyCode", "1"), 1);
  const assistantCompactShortcutModifiers = parsedShortcutValue(await readDefault("OpenAssist.assistantCompactShortcutModifiers", "1835008"), 1835008);
  const screenAnalysisShortcutKeyCode = parsedShortcutValue(await readDefault("OpenAssist.screenAnalysisShortcutKeyCode", "1"), 1);
  const screenAnalysisShortcutModifiers = parsedShortcutValue(await readDefault("OpenAssist.screenAnalysisShortcutModifiers", "1703936"), 1703936);
  const holdToTalkShortcut = shortcutDisplay(String(holdToTalkShortcutKeyCode), String(holdToTalkShortcutModifiers), 49, 1835008);
  const continuousToggleShortcut = shortcutDisplay(String(continuousToggleShortcutKeyCode), String(continuousToggleShortcutModifiers), 49, 1835008);
  const assistantLiveVoiceShortcut = shortcutDisplay(String(assistantLiveVoiceShortcutKeyCode), String(assistantLiveVoiceShortcutModifiers), 37, 1835008);
  const assistantCompactShortcut = shortcutDisplay(String(assistantCompactShortcutKeyCode), String(assistantCompactShortcutModifiers), 1, 1835008);
  const screenAnalysisShortcut = shortcutDisplay(String(screenAnalysisShortcutKeyCode), String(screenAnalysisShortcutModifiers), 1, 1703936);
  const dictationFeedbackVolume = Math.min(
    1,
    Math.max(
      0,
      await readNumberDefault("OpenAssist.dictationFeedbackVolume", defaultDictationFeedbackVolume)
    )
  );
  return {
    appVersion: await readInfoPlist("CFBundleShortVersionString", "1.0.7"),
    buildNumber: await readInfoPlist("CFBundleVersion", "69"),
    assistantBackend,
    availableAssistantBackends,
    ...runtimeSetup,
    model: assistantBackend === "ollamaLocal" ? promptRewriteModel : assistantPreferredModel,
    subAgentModel: await readDefault("OpenAssist.assistantPreferredSubagentModelID", "Same as main model"),
    compactStyle: await readDefault("OpenAssist.assistantCompactPresentationStyle", "sidebar"),
    compactEdge: await readDefault("OpenAssist.assistantCompactSidebarEdge", "right"),
    themeMode: await readDefault("OpenAssist.themeMode", "System"),
    colorTheme: await readDefault("OpenAssist.colorTheme", "Ocean"),
    appChromeStyle: await readDefault("OpenAssist.appChromeStyle", "Glass (High Contrast)"),
    lightThemeAccent: await readDefault("OpenAssist.lightTheme.accent", "#0169CC"),
    lightThemeBackground: await readDefault("OpenAssist.lightTheme.background", "#FFFFFF"),
    lightThemeForeground: await readDefault("OpenAssist.lightTheme.foreground", "#0D0D0D"),
    lightThemeUIFont: await readDefault("OpenAssist.lightTheme.uiFont", "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", Arial, sans-serif"),
    lightThemeCodeFont: await readDefault("OpenAssist.lightTheme.codeFont", "ui-monospace, SFMono-Regular, Menlo, monospace"),
    lightThemeTranslucentSidebar: await readBoolDefault("OpenAssist.lightTheme.translucentSidebar", false),
    lightThemeContrast: await readDefault("OpenAssist.lightTheme.contrast", "45"),
    lightThemeCodeThemeID: await readDefault("OpenAssist.lightTheme.codeThemeID", "codex"),
    lightThemeDiffAdded: await readDefault("OpenAssist.lightTheme.diffAdded", "#00a240"),
    lightThemeDiffRemoved: await readDefault("OpenAssist.lightTheme.diffRemoved", "#ba2623"),
    lightThemeSkill: await readDefault("OpenAssist.lightTheme.skill", "#924ff7"),
    darkThemeAccent: await readDefault("OpenAssist.darkTheme.accent", "#1F6FEB"),
    darkThemeBackground: await readDefault("OpenAssist.darkTheme.background", "#0D1117"),
    darkThemeForeground: await readDefault("OpenAssist.darkTheme.foreground", "#E6EDF3"),
    darkThemeUIFont: await readDefault("OpenAssist.darkTheme.uiFont", "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", Arial, sans-serif"),
    darkThemeCodeFont: await readDefault("OpenAssist.darkTheme.codeFont", "ui-monospace, SFMono-Regular, Menlo, monospace"),
    darkThemeTranslucentSidebar: await readBoolDefault("OpenAssist.darkTheme.translucentSidebar", true),
    darkThemeContrast: await readDefault("OpenAssist.darkTheme.contrast", "89"),
    darkThemeCodeThemeID: await readDefault("OpenAssist.darkTheme.codeThemeID", "github"),
    darkThemeDiffAdded: await readDefault("OpenAssist.darkTheme.diffAdded", "#40c977"),
    darkThemeDiffRemoved: await readDefault("OpenAssist.darkTheme.diffRemoved", "#fa423e"),
    darkThemeSkill: await readDefault("OpenAssist.darkTheme.skill", "#ad7bf9"),
    pointerCursors: await readBoolDefault("OpenAssist.usePointerCursors", false),
    reduceMotionMode: await readDefault("OpenAssist.reduceMotionMode", "System"),
    uiFontSize: await readDefault("OpenAssist.uiFontSize", "13"),
    codeFontSize: await readDefault("OpenAssist.codeFontSize", "12"),
    assistantEnabled: await readBoolDefault("OpenAssist.assistantBetaEnabled", false),
    assistantFloatingHUDEnabled: await readBoolDefault("OpenAssist.assistantFloatingHUDEnabled", true),
    voiceEnabled: await readBoolDefault("OpenAssist.assistantVoiceTaskEntryEnabled", true),
    realtimeVoiceEnabled: await readBoolDefault("OpenAssist.realtimeVoice.enabled", true),
    realtimeOpenAIAPIKeyConfigured: realtimeOpenAIAPIKey.configured,
    realtimeDedicatedOpenAIAPIKeyConfigured: realtimeOpenAIAPIKey.dedicatedConfigured,
    realtimeOpenAIAPIKeySource: realtimeOpenAIAPIKey.source,
    realtimeMaskedOpenAIAPIKey: realtimeOpenAIAPIKey.label,
    realtimeOpenAIModel: await readDefault("OpenAssist.realtimeVoice.openAIModel", defaultRealtimeOpenAIModel),
    realtimeOpenAIVoice: await readDefault("OpenAssist.realtimeVoice.openAIVoice", defaultRealtimeOpenAIVoice),
    assistantVoiceOutputEnabled: await readBoolDefault("OpenAssist.assistantVoiceOutputEnabled", false),
    computerUseEnabled: await readBoolDefault("OpenAssist.assistantComputerUseEnabled", false),
    memoryEnabled: await readBoolDefault("OpenAssist.assistantMemoryEnabled", true),
    assistantTrackCodeChangesInGitRepos: await readBoolDefault("OpenAssist.assistantTrackCodeChangesInGitRepos", true),
    automationAPIPort: await readDefault("OpenAssist.automationAPIPort", "45831"),
    browserProfile: await readDefault("OpenAssist.browserSelectedProfileID", "Default"),
    holdToTalkShortcut,
    holdToTalkShortcutKeyCode,
    holdToTalkShortcutModifiers,
    continuousToggleShortcut,
    continuousToggleShortcutKeyCode,
    continuousToggleShortcutModifiers,
    assistantLiveVoiceShortcut,
    assistantLiveVoiceShortcutKeyCode,
    assistantLiveVoiceShortcutModifiers,
    assistantCompactShortcut,
    assistantCompactShortcutKeyCode,
    assistantCompactShortcutModifiers,
    screenAnalysisShortcut,
    screenAnalysisShortcutKeyCode,
    screenAnalysisShortcutModifiers,
    transcriptionEngine: await readDefault("OpenAssist.transcriptionEngine", "Apple Speech"),
    autoDetectMicrophone: await readBoolDefault("OpenAssist.autoDetectMicrophone", true),
    selectedMicrophoneUID: await readDefault("OpenAssist.selectedMicrophoneUID", ""),
    availableMicrophones: [],
    whisperModel,
    whisperUseCoreML: await readBoolDefault("OpenAssist.whisperUseCoreML", true),
    whisperInstalledModels,
    whisperModelInstalled: fs.existsSync(whisperModelPath(whisperModel)),
    voiceEngine: await readDefault("OpenAssist.assistantVoiceEngine", "humeOctave"),
    kokoroVoice: safeKokoroVoiceID(await readDefault("OpenAssist.assistantKokoroVoiceID", defaultKokoroVoiceID)),
    kokoroModelInstalled: kokoroInstalled(),
    kokoroModelPath: kokoroVoiceDirectory(),
    kokoroModelDetail: kokoroInstalled()
      ? `Installed locally in ${kokoroVoiceDirectory()}`
      : "Not installed",
    waveformTheme: await readDefault("OpenAssist.waveformTheme", "Vibrant Spectrum"),
    telegramEnabled: await readBoolDefault("OpenAssist.telegramRemoteEnabled", false),
    telegramBotToken: "",
    telegramMaskedToken: telegramTokenConfigured ? "Configured in Keychain" : "Not configured",
    telegramTokenConfigured,
    telegramOwnerUserID,
    telegramOwnerChatID,
    telegramPendingUserID,
    telegramPendingChatID,
    telegramPendingDisplayName,
    telegramSelectedSessionID: await readDefault("OpenAssist.telegramSelectedSessionID", ""),
    telegramBotUsername: await readDefault("OpenAssist.telegramBotUsername", ""),
    remoteAccessEnabled: await readBoolDefault("OpenAssist.remoteAccess.enabled", false),
    remoteAccessPort: await readDefault("OpenAssist.remoteAccess.port", "45831"),
    remoteAccessPublicURL: await readDefault("OpenAssist.remoteAccess.namedTunnelPublicURL", ""),
    localAIRuntimeVersion: await readDefault("OpenAssist.localAIRuntimeVersion", "Unknown"),
    promptRewriteProvider,
    promptRewriteModel,
    promptRewriteBaseURL,
    promptRewriteAPIKeyConfigured,
    promptRewriteMaskedAPIKey: keychainStatus(promptRewriteAPIKeyConfigured, promptRewriteNeedsKey),
    cloudTranscriptionProvider,
    cloudTranscriptionModel,
    cloudTranscriptionBaseURL,
    cloudTranscriptionAPIKeyConfigured,
    cloudTranscriptionMaskedAPIKey: keychainStatus(cloudTranscriptionAPIKeyConfigured, cloudTranscriptionNeedsKey),
    dictationStartSoundName: normalizedDictationSoundName(
      await readDefault("OpenAssist.dictationStartSoundName", defaultDictationStartSoundName),
      defaultDictationStartSoundName
    ),
    dictationStopSoundName: normalizedDictationSoundName(
      await readDefault("OpenAssist.dictationStopSoundName", defaultDictationStopSoundName),
      defaultDictationStopSoundName
    ),
    dictationProcessingSoundName: normalizedDictationSoundName(
      await readDefault("OpenAssist.dictationProcessingSoundName", defaultDictationProcessingSoundName),
      defaultDictationProcessingSoundName
    ),
    dictationPastedSoundName: normalizedDictationSoundName(
      await readDefault("OpenAssist.dictationPastedSoundName", defaultDictationPastedSoundName),
      defaultDictationPastedSoundName
    ),
    dictationCorrectionLearnedSoundName: normalizedDictationSoundName(
      await readDefault("OpenAssist.dictationCorrectionLearnedSoundName", defaultDictationCorrectionLearnedSoundName),
      defaultDictationCorrectionLearnedSoundName
    ),
    dictationFeedbackVolume,
    assistantTextScale: await readDefault("assistantChatTextScale", "1.0")
  };
}

const writableSettingKeys: Record<SettingsUpdateKey, { defaultsKey: string; type: "bool" | "string" | "number" }> = {
  assistantEnabled: { defaultsKey: "OpenAssist.assistantBetaEnabled", type: "bool" },
  assistantFloatingHUDEnabled: { defaultsKey: "OpenAssist.assistantFloatingHUDEnabled", type: "bool" },
  voiceEnabled: { defaultsKey: "OpenAssist.assistantVoiceTaskEntryEnabled", type: "bool" },
  realtimeVoiceEnabled: { defaultsKey: "OpenAssist.realtimeVoice.enabled", type: "bool" },
  realtimeOpenAIModel: { defaultsKey: "OpenAssist.realtimeVoice.openAIModel", type: "string" },
  realtimeOpenAIVoice: { defaultsKey: "OpenAssist.realtimeVoice.openAIVoice", type: "string" },
  assistantVoiceOutputEnabled: { defaultsKey: "OpenAssist.assistantVoiceOutputEnabled", type: "bool" },
  computerUseEnabled: { defaultsKey: "OpenAssist.assistantComputerUseEnabled", type: "bool" },
  memoryEnabled: { defaultsKey: "OpenAssist.assistantMemoryEnabled", type: "bool" },
  assistantTrackCodeChangesInGitRepos: { defaultsKey: "OpenAssist.assistantTrackCodeChangesInGitRepos", type: "bool" },
  telegramEnabled: { defaultsKey: "OpenAssist.telegramRemoteEnabled", type: "bool" },
  remoteAccessEnabled: { defaultsKey: "OpenAssist.remoteAccess.enabled", type: "bool" },
  compactStyle: { defaultsKey: "OpenAssist.assistantCompactPresentationStyle", type: "string" },
  compactEdge: { defaultsKey: "OpenAssist.assistantCompactSidebarEdge", type: "string" },
  assistantBackend: { defaultsKey: "OpenAssist.assistantBackend", type: "string" },
  model: { defaultsKey: "OpenAssist.assistantPreferredModelID", type: "string" },
  themeMode: { defaultsKey: "OpenAssist.themeMode", type: "string" },
  colorTheme: { defaultsKey: "OpenAssist.colorTheme", type: "string" },
  appChromeStyle: { defaultsKey: "OpenAssist.appChromeStyle", type: "string" },
  lightThemeAccent: { defaultsKey: "OpenAssist.lightTheme.accent", type: "string" },
  lightThemeBackground: { defaultsKey: "OpenAssist.lightTheme.background", type: "string" },
  lightThemeForeground: { defaultsKey: "OpenAssist.lightTheme.foreground", type: "string" },
  lightThemeUIFont: { defaultsKey: "OpenAssist.lightTheme.uiFont", type: "string" },
  lightThemeCodeFont: { defaultsKey: "OpenAssist.lightTheme.codeFont", type: "string" },
  lightThemeTranslucentSidebar: { defaultsKey: "OpenAssist.lightTheme.translucentSidebar", type: "bool" },
  lightThemeContrast: { defaultsKey: "OpenAssist.lightTheme.contrast", type: "string" },
  lightThemeCodeThemeID: { defaultsKey: "OpenAssist.lightTheme.codeThemeID", type: "string" },
  lightThemeDiffAdded: { defaultsKey: "OpenAssist.lightTheme.diffAdded", type: "string" },
  lightThemeDiffRemoved: { defaultsKey: "OpenAssist.lightTheme.diffRemoved", type: "string" },
  lightThemeSkill: { defaultsKey: "OpenAssist.lightTheme.skill", type: "string" },
  darkThemeAccent: { defaultsKey: "OpenAssist.darkTheme.accent", type: "string" },
  darkThemeBackground: { defaultsKey: "OpenAssist.darkTheme.background", type: "string" },
  darkThemeForeground: { defaultsKey: "OpenAssist.darkTheme.foreground", type: "string" },
  darkThemeUIFont: { defaultsKey: "OpenAssist.darkTheme.uiFont", type: "string" },
  darkThemeCodeFont: { defaultsKey: "OpenAssist.darkTheme.codeFont", type: "string" },
  darkThemeTranslucentSidebar: { defaultsKey: "OpenAssist.darkTheme.translucentSidebar", type: "bool" },
  darkThemeContrast: { defaultsKey: "OpenAssist.darkTheme.contrast", type: "string" },
  darkThemeCodeThemeID: { defaultsKey: "OpenAssist.darkTheme.codeThemeID", type: "string" },
  darkThemeDiffAdded: { defaultsKey: "OpenAssist.darkTheme.diffAdded", type: "string" },
  darkThemeDiffRemoved: { defaultsKey: "OpenAssist.darkTheme.diffRemoved", type: "string" },
  darkThemeSkill: { defaultsKey: "OpenAssist.darkTheme.skill", type: "string" },
  pointerCursors: { defaultsKey: "OpenAssist.usePointerCursors", type: "bool" },
  reduceMotionMode: { defaultsKey: "OpenAssist.reduceMotionMode", type: "string" },
  uiFontSize: { defaultsKey: "OpenAssist.uiFontSize", type: "string" },
  codeFontSize: { defaultsKey: "OpenAssist.codeFontSize", type: "string" },
  waveformTheme: { defaultsKey: "OpenAssist.waveformTheme", type: "string" },
  promptRewriteProvider: { defaultsKey: "OpenAssist.promptRewriteProviderMode", type: "string" },
  promptRewriteModel: { defaultsKey: "OpenAssist.promptRewriteOpenAIModel", type: "string" },
  promptRewriteBaseURL: { defaultsKey: "OpenAssist.promptRewriteOpenAIBaseURL", type: "string" },
  cloudTranscriptionProvider: { defaultsKey: "OpenAssist.cloudTranscriptionProvider", type: "string" },
  cloudTranscriptionModel: { defaultsKey: "OpenAssist.cloudTranscriptionModel", type: "string" },
  cloudTranscriptionBaseURL: { defaultsKey: "OpenAssist.cloudTranscriptionBaseURL", type: "string" },
  dictationStartSoundName: { defaultsKey: "OpenAssist.dictationStartSoundName", type: "string" },
  dictationStopSoundName: { defaultsKey: "OpenAssist.dictationStopSoundName", type: "string" },
  dictationProcessingSoundName: { defaultsKey: "OpenAssist.dictationProcessingSoundName", type: "string" },
  dictationPastedSoundName: { defaultsKey: "OpenAssist.dictationPastedSoundName", type: "string" },
  dictationCorrectionLearnedSoundName: { defaultsKey: "OpenAssist.dictationCorrectionLearnedSoundName", type: "string" },
  dictationFeedbackVolume: { defaultsKey: "OpenAssist.dictationFeedbackVolume", type: "number" },
  autoDetectMicrophone: { defaultsKey: "OpenAssist.autoDetectMicrophone", type: "bool" },
  selectedMicrophoneUID: { defaultsKey: "OpenAssist.selectedMicrophoneUID", type: "string" },
  voiceEngine: { defaultsKey: "OpenAssist.assistantVoiceEngine", type: "string" },
  kokoroVoice: { defaultsKey: "OpenAssist.assistantKokoroVoiceID", type: "string" },
  whisperModel: { defaultsKey: "OpenAssist.selectedWhisperModelID", type: "string" },
  whisperUseCoreML: { defaultsKey: "OpenAssist.whisperUseCoreML", type: "bool" },
  transcriptionEngine: { defaultsKey: "OpenAssist.transcriptionEngine", type: "string" }
};

const shortcutTargetDefaultsKeys = {
  holdToTalk: {
    keyCode: "OpenAssist.shortcutKeyCode",
    modifiers: "OpenAssist.shortcutModifiers"
  },
  continuousToggle: {
    keyCode: "OpenAssist.continuousToggleShortcutKeyCode",
    modifiers: "OpenAssist.continuousToggleShortcutModifiers"
  },
  assistantLiveVoice: {
    keyCode: "OpenAssist.assistantLiveVoiceShortcutKeyCode",
    modifiers: "OpenAssist.assistantLiveVoiceShortcutModifiers"
  },
  assistantCompact: {
    keyCode: "OpenAssist.assistantCompactShortcutKeyCode",
    modifiers: "OpenAssist.assistantCompactShortcutModifiers"
  },
  screenAnalysis: {
    keyCode: "OpenAssist.screenAnalysisShortcutKeyCode",
    modifiers: "OpenAssist.screenAnalysisShortcutModifiers"
  }
} as const;

async function updateSetting(key: SettingsUpdateKey, value: boolean | string | number) {
  const setting = writableSettingKeys[key];
  if (!setting) throw new Error(`Unsupported setting: ${key}`);
  if (setting.type === "bool") {
    await writeBoolDefault(setting.defaultsKey, Boolean(value));
  } else if (setting.type === "number") {
    const numberValue = Number(value);
    if (!Number.isFinite(numberValue)) throw new Error(`Invalid number for setting: ${key}`);
    await writeNumberDefault(
      setting.defaultsKey,
      key === "dictationFeedbackVolume" ? Math.min(1, Math.max(0, numberValue)) : numberValue
    );
  } else {
    if (key === "assistantBackend") {
      const backend = normalizeBackend(String(value));
      if (!isRuntimeBackend(backend)) {
        throw new Error("Main chat runtime must be Codex, Claude, Copilot, or Ollama.");
      }
      await writeStringDefault(setting.defaultsKey, backend);
    } else if (key === "promptRewriteProvider") {
      const nextProvider = String(value);
      if (!isPromptRewriteProvider(nextProvider)) {
        throw new Error("Prompt rewrite provider must match a native OpenAssist provider.");
      }
      await writeStringDefault(setting.defaultsKey, nextProvider);
    } else if (key === "cloudTranscriptionProvider") {
      const nextProvider = String(value);
      if (!isCloudTranscriptionProvider(nextProvider)) {
        throw new Error("Cloud transcription provider must match a native OpenAssist provider.");
      }
      await writeStringDefault(setting.defaultsKey, nextProvider);
    } else if (key === "transcriptionEngine") {
      const validEngines = new Set(["Apple Speech", "whisper.cpp", "Cloud Providers"]);
      const nextEngine = String(value);
      if (!validEngines.has(nextEngine)) {
        throw new Error("Transcription engine must match a native OpenAssist engine.");
      }
      await writeStringDefault(setting.defaultsKey, nextEngine);
    } else if (
      key === "dictationStartSoundName"
      || key === "dictationStopSoundName"
      || key === "dictationProcessingSoundName"
      || key === "dictationPastedSoundName"
      || key === "dictationCorrectionLearnedSoundName"
    ) {
      const nextSoundName = String(value);
      if (!(dictationSoundOptions as readonly string[]).includes(nextSoundName)) {
        throw new Error("Dictation sound must match a native macOS alert sound.");
      }
      await writeStringDefault(setting.defaultsKey, nextSoundName);
    } else if (key === "whisperModel") {
      const nextModel = String(value);
      if (!isWhisperModelID(nextModel)) {
        throw new Error("Whisper model must match a native OpenAssist model.");
      }
      await writeStringDefault(setting.defaultsKey, nextModel);
    } else {
      await writeStringDefault(setting.defaultsKey, String(value));
    }
    if (key === "model") {
      const settings = await loadSettings();
      const backend = normalizeBackend(settings.assistantBackend);
      if (backend === "ollamaLocal") {
        await writeStringDefault("OpenAssist.promptRewriteOpenAIModel", String(value));
      }
    }
  }
  return loadSettings();
}

async function updateShortcut(
  target: keyof typeof shortcutTargetDefaultsKeys,
  keyCode: number,
  modifiers: number
) {
  const defaultsKeys = shortcutTargetDefaultsKeys[target];
  if (!defaultsKeys) throw new Error(`Unsupported shortcut target: ${target}`);
  if (!Number.isInteger(keyCode) || keyCode < 0 || keyCode > 65535) {
    throw new Error("Shortcut key code must be a valid macOS key code.");
  }
  if (!Number.isInteger(modifiers) || modifiers < 0) {
    throw new Error("Shortcut modifiers must be valid macOS modifier flags.");
  }
  await writeIntDefault(defaultsKeys.keyCode, keyCode);
  await writeIntDefault(defaultsKeys.modifiers, modifiers);
  return loadSettings();
}

async function clearTelegramPairingState() {
  await writeStringDefault("OpenAssist.telegramOwnerUserID", "");
  await writeStringDefault("OpenAssist.telegramOwnerChatID", "");
  await writeStringDefault("OpenAssist.telegramPendingUserID", "");
  await writeStringDefault("OpenAssist.telegramPendingChatID", "");
  await writeStringDefault("OpenAssist.telegramPendingDisplayName", "");
  await writeIntDefault("OpenAssist.telegramLastProcessedUpdateID", 0);
  await writeStringDefault("OpenAssist.telegramSelectedSessionID", "");
  await deleteDefault("OpenAssist.telegramTrackedMessageIDs");
}

async function saveTelegramBotToken(rawToken: string) {
  const next = rawToken.trim();
  await clearTelegramPairingState();
  await storeKeychainPassword(telegramBotTokenKeychainAccount, next);
  return loadSettings();
}

async function clearTelegramBotToken() {
  await clearTelegramPairingState();
  await deleteKeychainPassword(telegramBotTokenKeychainAccount);
  return loadSettings();
}

async function savePromptRewriteAPIKey(provider: string, rawValue: string) {
  if (!isPromptRewriteProvider(provider)) {
    throw new Error("Prompt rewrite provider must match a native OpenAssist provider.");
  }
  await writeStringDefault("OpenAssist.promptRewriteProviderMode", provider);
  if (!promptRewriteProviderRequiresKey(provider)) {
    await deleteKeychainPassword(promptRewriteKeychainAccount(provider));
    const settings = await loadSettings();
    return {
      ...settings,
      promptRewriteAPIKeyConfigured: false,
      promptRewriteMaskedAPIKey: keychainStatus(false, false)
    };
  }
  await storeKeychainPassword(promptRewriteKeychainAccount(provider), rawValue);
  const settings = await loadSettings();
  return {
    ...settings,
    promptRewriteAPIKeyConfigured: true,
    promptRewriteMaskedAPIKey: keychainStatus(true, true)
  };
}

async function clearPromptRewriteAPIKey(provider: string) {
  if (!isPromptRewriteProvider(provider)) {
    throw new Error("Prompt rewrite provider must match a native OpenAssist provider.");
  }
  await writeStringDefault("OpenAssist.promptRewriteProviderMode", provider);
  await deleteKeychainPassword(promptRewriteKeychainAccount(provider));
  const settings = await loadSettings();
  return {
    ...settings,
    promptRewriteAPIKeyConfigured: false,
    promptRewriteMaskedAPIKey: keychainStatus(false, promptRewriteProviderRequiresKey(provider))
  };
}

async function saveCloudTranscriptionAPIKey(provider: string, rawValue: string) {
  if (!isCloudTranscriptionProvider(provider)) {
    throw new Error("Cloud transcription provider must match a native OpenAssist provider.");
  }
  await writeStringDefault("OpenAssist.cloudTranscriptionProvider", provider);
  if (!cloudTranscriptionProviderRequiresKey(provider)) {
    await deleteKeychainPassword(cloudTranscriptionKeychainAccount(provider));
    const settings = await loadSettings();
    return {
      ...settings,
      cloudTranscriptionAPIKeyConfigured: false,
      cloudTranscriptionMaskedAPIKey: keychainStatus(false, false)
    };
  }
  await storeKeychainPassword(cloudTranscriptionKeychainAccount(provider), rawValue);
  const settings = await loadSettings();
  return {
    ...settings,
    cloudTranscriptionAPIKeyConfigured: true,
    cloudTranscriptionMaskedAPIKey: keychainStatus(true, true)
  };
}

async function clearCloudTranscriptionAPIKey(provider: string) {
  if (!isCloudTranscriptionProvider(provider)) {
    throw new Error("Cloud transcription provider must match a native OpenAssist provider.");
  }
  await writeStringDefault("OpenAssist.cloudTranscriptionProvider", provider);
  await deleteKeychainPassword(cloudTranscriptionKeychainAccount(provider));
  const settings = await loadSettings();
  return {
    ...settings,
    cloudTranscriptionAPIKeyConfigured: false,
    cloudTranscriptionMaskedAPIKey: keychainStatus(false, cloudTranscriptionProviderRequiresKey(provider))
  };
}

async function saveRealtimeOpenAIAPIKey(rawValue: string) {
  await storeKeychainPassword(realtimeOpenAIAPIKeychainAccount, rawValue);
  const settings = await loadSettings();
  return {
    ...settings,
    realtimeOpenAIAPIKeyConfigured: true,
    realtimeDedicatedOpenAIAPIKeyConfigured: true,
    realtimeOpenAIAPIKeySource: "dedicated" as const,
    realtimeMaskedOpenAIAPIKey: keychainStatus(true, true)
  };
}

async function clearRealtimeOpenAIAPIKey() {
  await deleteKeychainPassword(realtimeOpenAIAPIKeychainAccount);
  const realtimeOpenAIAPIKey = await resolveRealtimeOpenAIAPIKey();
  const settings = await loadSettings();
  return {
    ...settings,
    realtimeOpenAIAPIKeyConfigured: realtimeOpenAIAPIKey.configured,
    realtimeDedicatedOpenAIAPIKeyConfigured: realtimeOpenAIAPIKey.dedicatedConfigured,
    realtimeOpenAIAPIKeySource: realtimeOpenAIAPIKey.source,
    realtimeMaskedOpenAIAPIKey: realtimeOpenAIAPIKey.label
  };
}

async function installKokoroVoiceModel(voiceID: string = defaultKokoroVoiceID) {
  const normalizedVoice = safeKokoroVoiceID(voiceID);
  fs.mkdirSync(kokoroVoiceDirectory(), { recursive: true });
  fs.mkdirSync(kokoroOutputDirectory(), { recursive: true });
  cleanupGeneratedAssistantVoiceFiles();
  await writeStringDefault("OpenAssist.assistantVoiceEngine", "kokoroLocal");
  await writeStringDefault("OpenAssist.assistantKokoroVoiceID", normalizedVoice);
  await prewarmKokoroWorker();
  fs.writeFileSync(
    kokoroInstallMarkerPath(),
    JSON.stringify({
      modelID: kokoroModelID,
      dtype: "q8",
      device: "cpu",
      voiceID: normalizedVoice,
      installedAt: new Date().toISOString()
    }, null, 2),
    "utf8"
  );
  return loadSettings();
}

async function speakWithMacOS(text: string) {
  return new Promise<void>((resolve, reject) => {
    beginAssistantSpeechRun();
    const child = spawn("/usr/bin/say", [text], { stdio: "ignore" });
    assistantSpeechProcess = child;
    child.once("error", reject);
    child.once("exit", (code) => {
      if (assistantSpeechProcess === child) assistantSpeechProcess = null;
      code === 0 || code === null ? resolve() : reject(new Error(`Speech playback exited with code ${code}.`));
    });
  });
}

async function speakWithKokoroLocal(text: string, voiceID: string) {
  const speechRunID = beginAssistantSpeechRun();
  if (speechRunID !== assistantSpeechRunID) {
    return { ok: true, skipped: true, reason: "Assistant voice output was stopped." };
  }
  const outputDirectory = kokoroOutputDirectory();
  fs.mkdirSync(outputDirectory, { recursive: true });
  cleanupGeneratedAssistantVoiceFiles();
  const segments = splitAssistantSpeechSegments(text);
  if (!segments.length) return { ok: true, skipped: true, reason: "No assistant text to speak." };
  assistantVoiceLog(`kokoro run started segments=${segments.length} chars=${text.length}`);

  let nextFilePromise: Promise<string[]> | null = generateKokoroAudioFilesForSegment(
    segments[0],
    voiceID,
    outputDirectory,
    speechRunID,
    0
  );

  for (let index = 0; index < segments.length; index += 1) {
    let outputPaths: string[] = [];
    try {
      outputPaths = nextFilePromise ? await nextFilePromise : [];
    } catch (error) {
      assistantVoiceLog(
        `kokoro segment ${index} skipped after retry failure: ${error instanceof Error ? error.stack ?? error.message : String(error)}`
      );
    }
    if (speechRunID !== assistantSpeechRunID) {
      for (const outputPath of outputPaths) removeGeneratedAssistantVoiceFile(outputPath);
      return { ok: true, skipped: true, reason: "Assistant voice output was stopped." };
    }
    nextFilePromise = index + 1 < segments.length
      ? generateKokoroAudioFilesForSegment(segments[index + 1], voiceID, outputDirectory, speechRunID, index + 1)
      : null;
    for (const outputPath of outputPaths) {
      if (speechRunID !== assistantSpeechRunID) {
        for (const pendingPath of outputPaths) removeGeneratedAssistantVoiceFile(pendingPath);
        return { ok: true, skipped: true, reason: "Assistant voice output was stopped." };
      }
      await playAudioFile(outputPath, { deleteAfterPlayback: true });
    }
  }

  if (speechRunID === assistantSpeechRunID) {
    assistantVoiceLog(`kokoro run completed segments=${segments.length}`);
    return { ok: true, engine: "kokoroLocal", streamed: segments.length > 1, segments: segments.length };
  }
  assistantVoiceLog("kokoro run stopped before completion");
  return { ok: true, skipped: true, reason: "Assistant voice output was stopped." };
}

async function speakAssistantResponse(rawText: string, options: { force?: boolean } = {}) {
  const settings = await loadSettings();
  if (!options.force && !settings.assistantVoiceOutputEnabled) {
    return { ok: true, skipped: true, reason: "Assistant reply voice output is off." };
  }
  const text = assistantSpeechText(rawText);
  if (!text) return { ok: true, skipped: true, reason: "No assistant text to speak." };
  if (settings.voiceEngine === "macos") {
    await speakWithMacOS(text);
    return { ok: true, engine: "macos" };
  }
  if (settings.voiceEngine !== "kokoroLocal") {
    return {
      ok: true,
      skipped: true,
      reason: "Select Kokoro Local or macOS as the assistant voice engine to play replies."
    };
  }
  if (!kokoroInstalled()) {
    return { ok: false, error: "Kokoro Local Voice is not installed yet. Install it from Voice Reply Output settings." };
  }
  return speakWithKokoroLocal(text, settings.kokoroVoice || defaultKokoroVoiceID);
}

async function prewarmAssistantVoiceOutput() {
  const settings = await loadSettings();
  if (settings.voiceEngine !== "kokoroLocal" || !kokoroInstalled()) {
    return { ok: true, skipped: true };
  }
  await prewarmKokoroWorker();
  return { ok: true };
}

function stopAssistantVoiceOutput() {
  stopAssistantSpeech();
  cleanupGeneratedAssistantVoiceFiles();
  return { ok: true };
}

async function forgetTelegramPairing() {
  await writeStringDefault("OpenAssist.telegramOwnerUserID", "");
  await writeStringDefault("OpenAssist.telegramOwnerChatID", "");
  await writeStringDefault("OpenAssist.telegramSelectedSessionID", "");
  await deleteDefault("OpenAssist.telegramTrackedMessageIDs");
  return loadSettings();
}

async function approveTelegramPairing() {
  const pendingUserID = await readDefault("OpenAssist.telegramPendingUserID", "");
  const pendingChatID = await readDefault("OpenAssist.telegramPendingChatID", "");
  if (!pendingUserID.trim() || !pendingChatID.trim()) return loadSettings();
  await writeStringDefault("OpenAssist.telegramOwnerUserID", pendingUserID.trim());
  await writeStringDefault("OpenAssist.telegramOwnerChatID", pendingChatID.trim());
  await writeStringDefault("OpenAssist.telegramPendingUserID", "");
  await writeStringDefault("OpenAssist.telegramPendingChatID", "");
  await writeStringDefault("OpenAssist.telegramPendingDisplayName", "");
  return loadSettings();
}

async function declineTelegramPairing() {
  await writeStringDefault("OpenAssist.telegramPendingUserID", "");
  await writeStringDefault("OpenAssist.telegramPendingChatID", "");
  await writeStringDefault("OpenAssist.telegramPendingDisplayName", "");
  return loadSettings();
}

async function testTelegramConnection(rawToken?: string) {
  const token = rawToken === undefined
    ? await readKeychainPassword(telegramBotTokenKeychainAccount)
    : rawToken.trim();
  if (!token.trim()) {
    return { ok: false, message: "Add a Telegram bot token first." };
  }
  try {
    const response = await fetch(`https://api.telegram.org/bot${token.trim()}/getMe`);
    const body = await response.json().catch(() => ({})) as JsonObject;
    const result = body.result as JsonObject | undefined;
    if (response.ok && body.ok === true && result) {
      const username = pluginString(result.username);
      if (username) await writeStringDefault("OpenAssist.telegramBotUsername", username);
      return {
        ok: true,
        username,
        message: username ? `Telegram bot connected as @${username}.` : "Telegram bot connection works."
      };
    }
    const description = pluginString(body.description) || response.statusText || "Telegram rejected the token.";
    return { ok: false, message: description };
  } catch (error) {
    return {
      ok: false,
      message: error instanceof Error ? error.message : "Could not test Telegram connection."
    };
  }
}

export async function loadOpenAssistAppState(): Promise<OpenAssistAppState> {
  cleanupEmptyConversationThreads();
  const loadedProjects = loadProjects();
  const threads = loadThreads(loadedProjects);
  const { notes, noteFolders } = loadNotes(loadedProjects);
  const threadNotes = loadThreadNoteList(threads);
  const automations = await loadAutomations();
  const activeThreadID = threads[0]?.id;
  const skills = loadSkills(activeThreadID);
  const plugins = await loadPlugins();
  const settings = await loadSettings();
  const activeNote = notes.find((note) => note.active) ?? notes[0];
  const activeThread = activeThreadID ? threads.find((thread) => thread.id === activeThreadID) : undefined;
  const normalizedUsageBackend = normalizeBackend(activeThread?.activeProvider ?? settings.assistantBackend);
  const usageBackend: RuntimeAssistantBackend = isRuntimeBackend(normalizedUsageBackend) ? normalizedUsageBackend : "codex";
  await refreshUsageForBackend(usageBackend, {
    threadID: activeThreadID,
    modelID: activeThread?.modelID ?? modelForBackend(usageBackend, settings, activeThread as SessionSummary | undefined)
  });
  const usageByBackend = usageSnapshotsByBackend();
  return {
    projects: loadedProjects.projects,
    hiddenProjects: loadedProjects.hiddenProjects,
    threads,
    notes,
    threadNotes,
    noteFolders,
    automations,
    skills,
    plugins,
    settings,
    usage: usageByBackend[usageBackend] ?? null,
    usageByBackend,
    activeThreadID,
    activeProjectID: activeNote?.projectID ?? loadedProjects.projects[0]?.id,
    activeNoteID: activeNote?.id
  };
}

const codexRealtimeProxy = new CodexRealtimeProxy((message) => bridgeDebugLog(message));

async function configureCodexRealtimeProxy(settings?: SettingsSnapshot) {
  const snapshot = settings ?? await loadSettings();
  const realtimeOpenAIAPIKey = await resolveRealtimeOpenAIAPIKey();
  codexRealtimeProxy.configure({
    apiKey: realtimeOpenAIAPIKey.apiKey,
    model: snapshot.realtimeOpenAIModel || defaultRealtimeOpenAIModel,
    voice: snapshot.realtimeOpenAIVoice || defaultRealtimeOpenAIVoice,
    organizationID: process.env.OPENAI_ORG_ID,
    projectID: process.env.OPENAI_PROJECT_ID,
    safetyIdentifier: process.env.OPENAI_SAFETY_IDENTIFIER
  });
  return codexRealtimeProxy.ensureStarted();
}

class CodexAppServerTransport extends EventEmitter {
  private process?: ReturnType<typeof spawn>;
  private startPromise?: Promise<void>;
  private restartPromise?: Promise<void>;
  private nextID = 1;
  private buffer = "";
  private pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();

  async start() {
    if (this.restartPromise) await this.restartPromise;
    if (this.process) return;
    if (this.startPromise) return this.startPromise;
    this.startPromise = this.startProcess().finally(() => {
      this.startPromise = undefined;
    });
    return this.startPromise;
  }

  private async startProcess() {
    if (this.process) return;
    const codexExecutable = resolveCodexExecutable();
    const realtimeProxyBaseURL = await configureCodexRealtimeProxy();
    const appServerArgs = [
      "app-server",
      "--analytics-default-enabled",
      "--enable",
      "realtime_conversation",
      "-c",
      `experimental_realtime_ws_base_url=${JSON.stringify(realtimeProxyBaseURL)}`,
      "-c",
      "experimental_realtime_ws_model=\"local-codex-realtime\"",
      "-c",
      "realtime.transport=\"websocket\"",
      "-c",
      "realtime.version=\"v2\"",
      "-c",
      "realtime.type=\"conversational\""
    ];
    const appServerEnv = {
      ...process.env,
      OPENAI_API_KEY: process.env.LOCAL_REALTIME_CODEX_PLACEHOLDER_API_KEY?.trim() || codexRealtimePlaceholderAPIKey,
      // Match Codex.app's own environment so the Computer Use MCP plugin (and
      // any other curated/bundled plugins that gate on the originator) treat
      // us as the official Codex client. Without this, SkyComputerUseClient
      // accepts the request but never responds to tool calls like list_apps.
      CODEX_INTERNAL_ORIGINATOR_OVERRIDE: process.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE ?? "Codex",
      LOG_FORMAT: process.env.LOG_FORMAT ?? "json",
      RUST_LOG: process.env.RUST_LOG ?? "warn"
    };
    bridgeDebugLog(`starting Codex app-server executable=${codexExecutable} realtimeProxy=${realtimeProxyBaseURL}`);
    this.emit("status", `Starting Codex App Server: ${codexExecutable}`);
    const child = spawn(codexExecutable, appServerArgs, {
      stdio: ["pipe", "pipe", "pipe"],
      env: appServerEnv
    });
    if (!child.stdin || !child.stdout || !child.stderr) {
      throw new Error("Codex App Server did not expose stdio streams.");
    }
    this.process = child;
    bridgeDebugLog(`Codex app-server started pid=${child.pid ?? "unknown"}`);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => this.consume(String(chunk)));
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      const text = String(chunk);
      const trimmed = text.trim();
      if (trimmed) bridgeDebugLog(`Codex app-server stderr: ${trimmed}`);
      this.emit("status", text);
    });
    child.on("error", (error) => {
      bridgeDebugLog(`Codex app-server process error: ${error.stack ?? error.message}`);
    });
    child.on("exit", (code, signal) => {
      if (this.process !== child) return;
      bridgeDebugLog(`Codex app-server exited pid=${child.pid ?? "unknown"} code=${code ?? "null"} signal=${signal ?? "null"}`);
      this.process = undefined;
      this.rejectPending(new Error("Codex App Server exited."));
      clearProviderBindingsForBackend("codex");
      bridgeDebugLog(`Codex provider bindings cleared after unexpected exit pid=${child.pid ?? "unknown"}`);
    });
    await this.request("initialize", {
      protocolVersion: 2,
      clientInfo: { name: "Open Assist Electron", version: "0.1.0" },
      capabilities: { experimentalApi: true }
    }, 0, 10_000);
    this.notify("initialized");
  }

  async restart(reason: string) {
    if (this.restartPromise) return this.restartPromise;
    this.restartPromise = this.stopForRestart(reason).finally(() => {
      this.restartPromise = undefined;
    });
    return this.restartPromise;
  }

  async request(method: string, params: JsonObject = {}, forcedID?: number, timeoutMs = 120_000) {
    await this.startIfNeeded(method);
    const id = forcedID ?? this.nextID++;
    const message = { jsonrpc: "2.0", id, method, params };
    const isInterestingMethod = method === "turn/start"
      || method === "turn/interrupt"
      || method === "thread/start"
      || method === "thread/resume"
      || method === "thread/realtime/start";
    const startMs = Date.now();
    if (isInterestingMethod) {
      bridgeDebugLog(`codex request method=${method} id=${id}`);
    }
    const promise = new Promise<unknown>((resolve, reject) => {
      this.pending.set(id, {
        resolve: (value: unknown) => {
          if (isInterestingMethod) {
            bridgeDebugLog(`codex request resolved method=${method} id=${id} elapsedMs=${Date.now() - startMs}`);
          }
          resolve(value);
        },
        reject: (error: Error) => {
          if (isInterestingMethod) {
            bridgeDebugLog(`codex request rejected method=${method} id=${id} elapsedMs=${Date.now() - startMs} error=${error.message}`);
          }
          reject(error);
        }
      });
      setTimeout(() => {
        if (this.pending.delete(id)) {
          bridgeDebugLog(`codex request timed out method=${method} id=${id} timeoutMs=${timeoutMs}`);
          reject(new Error(`${method} timed out.`));
        }
      }, timeoutMs);
    });
    this.write(message);
    return promise;
  }

  notify(method: string, params?: JsonObject) {
    this.write(params ? { jsonrpc: "2.0", method, params } : { jsonrpc: "2.0", method });
  }

  respond(id: JsonRequestID, result: unknown) {
    this.write({ jsonrpc: "2.0", id, result });
  }

  private async startIfNeeded(method: string) {
    if (method === "initialize") return;
    if (!this.process) await this.start();
  }

  private rejectPending(error: Error) {
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }

  private async stopForRestart(reason: string) {
    const child = this.process;
    this.process = undefined;
    this.buffer = "";
    this.rejectPending(new Error(`Codex App Server restarted: ${reason}`));
    clearProviderBindingsForBackend("codex");
    bridgeDebugLog(`Codex provider bindings cleared on restart reason="${reason}"`);
    if (!child) {
      bridgeDebugLog(`Codex app-server restart requested with no running process reason="${reason}"`);
      return;
    }
    const pid = child.pid;
    bridgeDebugLog(`Codex app-server restart requested reason="${reason}" pid=${pid ?? "unknown"}`);
    if (pid && Number.isFinite(pid)) {
      await terminateProcessTree(pid, reason);
    } else {
      child.kill("SIGTERM");
    }
  }

  private write(message: unknown) {
    const child = this.process;
    if (!child?.stdin || !child.stdin.writable) throw new Error("Codex App Server is not running.");
    child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  private consume(chunk: string) {
    this.buffer += chunk;
    let index: number;
    while ((index = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, index).trim();
      this.buffer = this.buffer.slice(index + 1);
      if (!line) continue;
      let message: JsonObject;
      try {
        message = JSON.parse(line) as JsonObject;
      } catch {
        continue;
      }
      if (message.id != null && !message.method) {
        const id = Number(message.id);
        const pending = this.pending.get(id);
        if (pending) {
          this.pending.delete(id);
          if (message.error) pending.reject(new Error(String((message.error as JsonObject).message ?? "Codex request failed.")));
          else pending.resolve(message.result);
        }
        continue;
      }
      if (typeof message.method === "string") {
        this.emit("notification", message.method, (message.params as JsonObject | undefined) ?? {}, message.id);
      }
    }
  }
}

const codexTransport = new CodexAppServerTransport();

class ProviderRunStoppedError extends Error {
  constructor(provider: string) {
    super(`${provider} was stopped.`);
    this.name = "ProviderRunStoppedError";
  }
}

type ActiveProviderRun = {
  backend: AssistantBackend;
  provider: string;
  openAssistThreadID: string;
  pluginIDs?: string[];
  providerThreadID?: string;
  turnID?: string;
  stopped?: boolean;
  rejectStop?: (error: Error) => void;
};

const activeProviderRuns = new Map<string, ActiveProviderRun>();

type RealtimeAudioChunk = {
  data: string;
  sampleRate: number;
  numChannels: number;
  samplesPerChannel: number | null;
  itemId: string | null;
};

type ActiveRealtimeSession = {
  openAssistThreadID: string;
  providerThreadID: string;
  provider: string;
  currentTurnID?: string;
  onNotification: (method: string, params: JsonObject, requestID?: JsonRequestID) => void;
  eventSink?: (event: { type: string; payload?: unknown }) => void;
};

let activeRealtimeSession: ActiveRealtimeSession | null = null;

async function interruptCodexRun(run: ActiveProviderRun, timeoutMs = 15_000) {
  if (run.backend !== "codex" || !run.providerThreadID || !run.turnID) return;
  await codexTransport.request("turn/interrupt", {
    threadId: run.providerThreadID,
    turnId: run.turnID
  }, undefined, timeoutMs);
}

async function restartCodexAfterStoppedRunIfNeeded(run: ActiveProviderRun, interruptError?: string) {
  if (run.backend !== "codex") return { restarted: false };
  const usesOfficialComputerUse = shouldPreferCodexComputerUsePlugin(run.pluginIDs);
  if (!usesOfficialComputerUse && !interruptError) {
    return { restarted: false };
  }
  const reason = interruptError
    ? `Stopped Codex turn after interrupt failed: ${interruptError}`
    : "Stopped Codex turn using official Computer Use plugin";
  try {
    await codexTransport.restart(reason);
    return { restarted: true };
  } catch (error) {
    const restartError = error instanceof Error ? error.message : "Could not restart Codex.";
    bridgeDebugLog(`restart after stopped Codex run failed: ${restartError}`);
    return { restarted: false, restartError };
  }
}

export async function stopProviderRun(clientRunID?: string) {
  const runID = clientRunID?.trim();
  if (!runID) return { ok: false, error: "No active turn to stop." };
  const run = activeProviderRuns.get(runID);
  if (!run) return { ok: false, error: "That turn already finished." };

  run.stopped = true;
  let interruptError: string | undefined;
  try {
    await interruptCodexRun(run, 5_000);
  } catch (error) {
    interruptError = error instanceof Error ? error.message : "Could not interrupt the active turn.";
  }
  run.rejectStop?.(new ProviderRunStoppedError(run.provider));
  const restartResult = await restartCodexAfterStoppedRunIfNeeded(run, interruptError);
  return {
    ok: true,
    interrupted: !interruptError,
    restarted: restartResult.restarted,
    restartError: restartResult.restartError
  };
}

function realtimeEventPayload(method: string, params: JsonObject, providerThreadID: string, openAssistThreadID: string) {
  return {
    ...params,
    method,
    threadId: openAssistThreadID,
    providerThreadId: providerThreadID
  };
}

function realtimeErrorMessage(method: string, params: JsonObject) {
  const error = params.error;
  const errorObject = error && typeof error === "object" && !Array.isArray(error) ? error as JsonObject : undefined;
  const message = [
    errorObject?.message,
    params.message,
    params.reason,
    typeof error === "string" ? error : undefined
  ].find((value) => typeof value === "string" && value.trim());
  return String(message || (method === "thread/realtime/closed"
    ? "Live Voice closed before it finished connecting."
    : "Live Voice failed to connect."));
}

function realtimeDelegationPromptFromItem(params: JsonObject) {
  const item = runtimeObject(params.item);
  if (!item) return "";
  const name = firstRuntimeString(item.name, item.tool, item.toolName);
  if (name !== "background_agent") return "";
  const rawArguments = firstRawRuntimeString(item.arguments);
  let parsedArguments: JsonObject | undefined;
  if (rawArguments) {
    try {
      parsedArguments = runtimeObject(JSON.parse(rawArguments));
    } catch {
      parsedArguments = undefined;
    }
  }
  return firstRawRuntimeString(parsedArguments?.prompt, parsedArguments?.task, rawArguments);
}

function liveVoiceStartTimeout<T>(promise: Promise<T>) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error("Live Voice connection timed out. Check your Realtime API key and internet connection.")), codexRealtimeStartTimeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}

async function stopActiveRealtimeSession(reason = "stopped") {
  const active = activeRealtimeSession;
  if (!active) return { ok: true };
  activeRealtimeSession = null;
  codexTransport.off("notification", active.onNotification);
  try {
    await codexTransport.request("thread/realtime/stop", {
      threadId: active.providerThreadID
    }, undefined, 10_000);
  } catch (error) {
    bridgeDebugLog(`Codex realtime stop failed: ${error instanceof Error ? error.message : String(error)}`);
  }
  active.eventSink?.({
    type: "thread/realtime/closed",
    payload: {
      threadId: active.openAssistThreadID,
      providerThreadId: active.providerThreadID,
      reason
    }
  });
  return { ok: true };
}

async function stopCodexRealtimeDelegation() {
  const active = activeRealtimeSession;
  if (!active?.providerThreadID || !active.currentTurnID) {
    return { ok: false, error: "No delegated Codex task is running." };
  }
  try {
    await codexTransport.request("turn/interrupt", {
      threadId: active.providerThreadID,
      turnId: active.currentTurnID
    }, undefined, 5_000);
    const now = Date.now();
    const activity: ChatMessage = {
      id: `activity-realtime-delegation-${active.currentTurnID}`,
      role: "activity",
      provider: active.provider,
      text: "Codex delegated task was stopped.",
      status: "completed",
      activityTitle: "Delegated task",
      activityKind: "realtimeDelegation",
      activityStatus: "completed",
      activityDetail: "Codex delegated task was stopped.",
      createdAt: now,
      updatedAt: now
    };
    upsertRuntimeActivity(active.openAssistThreadID, activity, active.currentTurnID);
    active.eventSink?.({
      type: "thread/realtime/activity",
      payload: {
        threadId: active.openAssistThreadID,
        providerThreadId: active.providerThreadID,
        providerTurnId: active.currentTurnID,
        activity
      }
    });
    active.eventSink?.({
      type: "thread/realtime/delegation/stopped",
      payload: {
        threadId: active.openAssistThreadID,
        providerThreadId: active.providerThreadID,
        providerTurnId: active.currentTurnID
      }
    });
    return { ok: true };
  } catch (error) {
    const message = error instanceof Error ? error.message : "Could not stop the delegated Codex task.";
    bridgeDebugLog(`Codex realtime delegation stop failed: ${message}`);
    return { ok: false, error: message };
  }
}

async function startCodexRealtimeVoice(
  options: { threadID?: string; provider?: string; interactionMode?: string; permissionMode?: string; reasoningEffort?: string } = {},
  eventSink?: (event: { type: string; payload?: unknown }) => void
) {
  const requestedThreadID = options.threadID?.trim() || "new";
  bridgeDebugLog(`[realtime.voice] start requested thread=${requestedThreadID} provider=${options.provider ?? "current"}`);
  const settings = await loadSettings();
  if (!settings.realtimeVoiceEnabled) {
    bridgeDebugLog("[realtime.voice] start blocked: setting disabled");
    return { ok: false, error: "Realtime Voice is turned off in Settings." };
  }
  if (!settings.realtimeOpenAIAPIKeyConfigured) {
    bridgeDebugLog("[realtime.voice] start blocked: missing realtime API key");
    return { ok: false, error: "Add an OpenAI API key in Settings > Voice & Dictation." };
  }
  if (options.provider && normalizeBackend(options.provider) !== "codex") {
    bridgeDebugLog(`[realtime.voice] start blocked: unsupported provider=${options.provider}`);
    return { ok: false, error: "Realtime Voice works with the Codex provider only." };
  }

  let openAssistThreadID = options.threadID?.startsWith("openassist-")
    ? options.threadID
    : createOpenAssistThread(undefined, true).session.id;
  let session = findSession(openAssistThreadID);
  if (!session) {
    const created = createOpenAssistThread(undefined, true).session;
    openAssistThreadID = created.id;
    session = created;
  }

  const backend = normalizeBackend(String(session.activeProvider ?? settings.assistantBackend ?? "codex"));
  if (backend !== "codex") {
    bridgeDebugLog(`[realtime.voice] start blocked: active backend=${backend}`);
    return { ok: false, error: "Realtime Voice works with the Codex provider only." };
  }

  try {
    const proxyURL = await liveVoiceStartTimeout(configureCodexRealtimeProxy(settings));
    bridgeDebugLog(`[realtime.voice] proxy ready url=${proxyURL}`);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Live Voice proxy failed to start.";
    bridgeDebugLog(`[realtime.voice] proxy start failed: ${message}`);
    return { ok: false, error: message };
  }
  await stopActiveRealtimeSession("replaced");

  const modelID = modelForBackend("codex", settings, session);
  bridgeDebugLog(`[realtime.voice] ensuring Codex provider session thread=${openAssistThreadID} model=${modelID}`);
  const realtimeRuntimeOptions: CodexRuntimeOptions = {
    interactionMode: options.interactionMode ?? session.latestInteractionMode ?? "agentic",
    permissionMode: options.permissionMode ?? session.latestPermissionMode ?? "fullAccess",
    reasoningEffort: normalizeCodexReasoningEffort(options.reasoningEffort ?? session.latestReasoningEffort)
  };
  let providerThreadID: string;
  let insertedSystemMessage = false;
  try {
    const providerSession = await liveVoiceStartTimeout(ensureCodexProviderSession(openAssistThreadID, modelID, realtimeRuntimeOptions));
    providerThreadID = providerSession.providerSessionID;
    insertedSystemMessage = providerSession.insertedSystemMessage;
  } catch (error) {
    const message = error instanceof Error ? error.message : "Could not create the Codex realtime thread.";
    bridgeDebugLog(`[realtime.voice] provider session failed thread=${openAssistThreadID}: ${message}`);
    return { ok: false, error: message };
  }
  let rejectStart: ((error: Error) => void) | undefined;
  const startFailure = new Promise<never>((_resolve, reject) => {
    rejectStart = reject;
  });
  const cleanupStartFailure = () => {
    rejectStart = undefined;
  };
  const cleanupRealtimeStart = () => {
    codexTransport.off("notification", onNotification);
    const active = activeRealtimeSession;
    if (active?.providerThreadID === providerThreadID) {
      activeRealtimeSession = null;
    }
  };
  let lastUserTranscript = "";
  let delegationPrompt = "";
  let responseText = "";
  const makeRealtimeProviderTurnID = () => `codex-realtime-turn-${randomUUID().toLowerCase()}`;
  const isReusableCodexRealtimeTurnID = (turnID: string) => /^auto-compact-\d+$/i.test(turnID.trim());
  let providerTurnID = makeRealtimeProviderTurnID();
  let didGenerateImage = false;
  let activityTurnIDs = new Set<string>([providerTurnID]);
  const activityDetailBuffers = new Map<string, string>();
  const itemPhases = new Map<string, string>();
  const isCommentaryPhase = (phase: string) =>
    phase === "commentary" || phase === "prework" || phase === "creating";
  const noteItemPhase = (params: JsonObject) => {
    const id = runtimeItemID(params);
    const phase = runtimeItemPhase(params);
    if (id && phase) {
      const prior = itemPhases.get(id);
      itemPhases.set(id, phase);
      if (prior !== phase) {
        bridgeDebugLog(`codex item phase id=${id} phase=${phase}`);
      }
    }
  };
  const isDeltaForCommentary = (params: JsonObject) => {
    const inlinePhase = runtimeItemPhase(params);
    if (inlinePhase) return isCommentaryPhase(inlinePhase);
    const id = runtimeItemID(params);
    if (!id) return false;
    const tracked = itemPhases.get(id);
    return Boolean(tracked && isCommentaryPhase(tracked));
  };
  const completedTurnIDs = new Set<string>();
  const emitDelegationRefresh = (type: string, extra: JsonObject = {}) => {
    eventSink?.({
      type,
      payload: {
        threadId: openAssistThreadID,
        providerThreadId: providerThreadID,
        providerTurnId: providerTurnID,
        ...extra
      }
    });
  };
  const emitRealtimeActivity = (activity: ChatMessage) => {
    eventSink?.({
      type: "thread/realtime/activity",
      payload: {
        threadId: openAssistThreadID,
        providerThreadId: providerThreadID,
        providerTurnId: providerTurnID,
        activity
      }
    });
  };
  const bufferedActivity = (activity: ChatMessage, method: string): ChatMessage | null => {
    const normalizedTitle = String(activity.activityTitle ?? "").replace(/\s+/g, " ").trim().toLowerCase();
    if (normalizedTitle === "user message") return null;
    if (isRuntimeMessageItemType(activity.activityKind)) return null;
    const existingDetail = activityDetailBuffers.get(activity.id) ?? "";
    const incomingDetail = isGenericRuntimeDetail(activity.activityDetail || activity.text)
      ? ""
      : String(activity.activityDetail || activity.text || "");
    const isDelta = method.toLowerCase().includes("delta");
    const mergedDetail = isDelta && incomingDetail
      ? appendRuntimeDelta(existingDetail, incomingDetail)
      : incomingDetail || existingDetail;
    if (mergedDetail) {
      activityDetailBuffers.set(activity.id, mergedDetail);
    }
    if (activity.activityKind === "reasoning" && !mergedDetail) {
      return null;
    }
    if (normalizedTitle === "agent message" && isGenericRuntimeDetail(mergedDetail)) return null;
    return {
      ...activity,
      text: mergedDetail || activity.text,
      activityDetail: mergedDetail || activity.activityDetail
    };
  };
  const realtimeDelegationActivity = (status: ChatMessage["activityStatus"], detail?: string): ChatMessage => {
    const now = Date.now();
    const text = detail?.trim() || "Codex is handling the voice task.";
    return {
      id: `activity-realtime-delegation-${providerTurnID}`,
      role: "activity",
      provider: "Codex",
      text,
      status: status === "completed" || status === "failed" ? "completed" : "running",
      activityTitle: "Delegated task",
      activityKind: "realtimeDelegation",
      activityStatus: status,
      activityDetail: text,
      createdAt: now,
      updatedAt: now
    };
  };
  const currentDelegationPrompt = () => lastUserTranscript || delegationPrompt;
  const refreshRealtimeDelegationPrompt = () => {
    const prompt = currentDelegationPrompt();
    const active = activeRealtimeSession;
    if (!prompt || active?.providerThreadID !== providerThreadID || !active.currentTurnID) return;
    const activity = realtimeDelegationActivity("running", prompt);
    upsertRuntimeActivity(openAssistThreadID, activity, providerTurnID);
    emitRealtimeActivity(activity);
    emitDelegationRefresh("thread/realtime/delegation/updated", { prompt });
  };
  const commentaryActivityFromDelta = (method: string, params: JsonObject): ChatMessage | null => {
    const delta = typeof params.delta === "string" ? params.delta : "";
    if (!delta) return null;
    const item = runtimeItemPayload(params);
    const rawID = firstRuntimeString(params.itemId, params.item_id, item.id);
    const id = rawID || `${method}:realtime-assistant-progress`;
    const now = Date.now();
    return bufferedActivity({
      id: `activity-${id}`,
      role: "activity",
      provider: "Codex",
      text: delta,
      status: "running",
      activityTitle: "Agent Message",
      activityKind: "assistantProgress",
      activityStatus: "running",
      activityDetail: delta,
      createdAt: now,
      updatedAt: now
    }, method);
  };
  const persistRealtimeDelegation = (failed: boolean, error?: string) => {
    const turnID = providerTurnID || `codex-realtime-turn-${randomUUID().toLowerCase()}`;
    if (completedTurnIDs.has(turnID)) return;
    completedTurnIDs.add(turnID);
    const prompt = currentDelegationPrompt() || "Realtime voice delegation";
    const finalText = responseText.trim()
      || (didGenerateImage ? "Generated image is ready." : "")
      || (failed && error ? `Codex could not finish this realtime task: ${error}` : "Codex completed the realtime task.");
    persistCompletedTurn({
      threadID: openAssistThreadID,
      backend: "codex",
      providerSessionID: providerThreadID,
      providerTurnID: turnID,
      activityTurnIDs: Array.from(activityTurnIDs),
      modelID,
      prompt,
      responseText: finalText,
      insertedSystemMessage,
      reasoningEffort: realtimeRuntimeOptions.reasoningEffort,
      interactionMode: realtimeRuntimeOptions.interactionMode,
      permissionMode: realtimeRuntimeOptions.permissionMode
    });
    insertedSystemMessage = false;
    emitDelegationRefresh(failed ? "thread/realtime/delegation/failed" : "thread/realtime/delegation/completed", {
      prompt,
      failed,
      error: error || "",
      responseText: finalText
    });
  };
  const onNotification = (method: string, params: JsonObject, requestID?: JsonRequestID) => {
    const notificationThreadID = String(params.threadId ?? params.threadID ?? "");
    if (notificationThreadID && notificationThreadID !== providerThreadID) return;

    if (method.startsWith("thread/realtime/")) {
      const payload = realtimeEventPayload(method, params, providerThreadID, openAssistThreadID);
      eventSink?.({ type: method, payload });
      if (method === "thread/realtime/transcript/done") {
        const role = firstRuntimeString(params.role).toLowerCase();
        const text = firstRawRuntimeString(params.text, params.transcript);
        if (role === "user" && text) {
          lastUserTranscript = text;
          refreshRealtimeDelegationPrompt();
        }
      }
      if (method === "thread/realtime/itemAdded") {
        const prompt = realtimeDelegationPromptFromItem(params);
        if (prompt) {
          delegationPrompt = prompt;
          refreshRealtimeDelegationPrompt();
        }
      }
      if (method === "thread/realtime/closed" || method === "thread/realtime/error") {
        const message = realtimeErrorMessage(method, params);
        bridgeDebugLog(`[realtime.voice] notification ${method}: ${message}`);
        rejectStart?.(new Error(message));
        const active = activeRealtimeSession;
        if (active?.providerThreadID === providerThreadID) {
          activeRealtimeSession = null;
          codexTransport.off("notification", active.onNotification);
        }
      }
      if (requestID != null) {
        try {
          codexTransport.respond(requestID, { ok: true });
        } catch {
          // Experimental realtime notifications are best-effort.
        }
      }
      return;
    }

    const turn = runtimeObject(params.turn);
    const notificationTurnID = firstRuntimeString(params.turnId, params.turnID, turn?.id);
    if (method === "turn/started") {
      providerTurnID = notificationTurnID && !isReusableCodexRealtimeTurnID(notificationTurnID)
        ? notificationTurnID
        : makeRealtimeProviderTurnID();
      if (activeRealtimeSession?.providerThreadID === providerThreadID) {
        activeRealtimeSession.currentTurnID = providerTurnID;
      }
      activityTurnIDs = new Set<string>([providerTurnID]);
      activityDetailBuffers.clear();
      itemPhases.clear();
      responseText = "";
      didGenerateImage = false;
      bridgeDebugLog(`[realtime.voice] delegated Codex turn started providerTurn=${providerTurnID}`);
      const prompt = currentDelegationPrompt();
      const activity = realtimeDelegationActivity("running", prompt || "Codex is starting the voice task.");
      upsertRuntimeActivity(openAssistThreadID, activity, providerTurnID);
      emitRealtimeActivity(activity);
      emitDelegationRefresh("thread/realtime/delegation/started", { prompt });
      return;
    }
    if (notificationTurnID && !isReusableCodexRealtimeTurnID(notificationTurnID)) {
      providerTurnID = notificationTurnID;
      activityTurnIDs.add(notificationTurnID);
    }
    if (method === "item/started" || method === "item/completed") {
      noteItemPhase(params);
    }
    if (method === "item/agentMessage/delta" && typeof params.delta === "string") {
      if (isDeltaForCommentary(params)) {
        const commentaryActivity = commentaryActivityFromDelta(method, params);
        if (commentaryActivity) {
          upsertRuntimeActivity(openAssistThreadID, commentaryActivity, providerTurnID);
          emitRealtimeActivity(commentaryActivity);
        }
      } else {
        responseText += params.delta;
      }
    }
    const activity = providerActivityFromNotification(openAssistThreadID, "Codex", method, params, validJsonRequestID(requestID));
    if (activity) {
      if (activity.activityKind === "imageGeneration" && (activity.imageDataURL || activity.imagePath || activity.activityStatus === "completed")) {
        didGenerateImage = true;
      }
      const storedActivity = bufferedActivity(activity, method);
      if (!storedActivity) return;
      upsertRuntimeActivity(openAssistThreadID, storedActivity, providerTurnID);
      emitRealtimeActivity(storedActivity);
    }
    if (method === "turn/completed" || method === "turn/failed") {
      const failed = method === "turn/failed";
      const error = providerErrorMessage(params);
      bridgeDebugLog(`[realtime.voice] delegated Codex turn ${failed ? "failed" : "completed"} providerTurn=${providerTurnID}`);
      const prompt = currentDelegationPrompt() || "Voice task";
      const finalActivity = realtimeDelegationActivity(failed ? "failed" : "completed", failed && error ? error : prompt);
      upsertRuntimeActivity(openAssistThreadID, finalActivity, providerTurnID);
      emitRealtimeActivity(finalActivity);
      persistRealtimeDelegation(failed, error);
      if (activeRealtimeSession?.providerThreadID === providerThreadID && activeRealtimeSession.currentTurnID === providerTurnID) {
        activeRealtimeSession.currentTurnID = undefined;
      }
    }
  };

  activeRealtimeSession = {
    openAssistThreadID,
    providerThreadID,
    provider: "Codex",
    onNotification,
    eventSink
  };
  codexTransport.on("notification", onNotification);

  try {
    bridgeDebugLog(`[realtime.voice] sending thread/realtime/start providerThread=${providerThreadID}`);
    await liveVoiceStartTimeout(Promise.race([
      codexTransport.request("thread/realtime/start", {
        threadId: providerThreadID,
        outputModality: "audio",
        transport: { type: "websocket" },
        voice: settings.realtimeOpenAIVoice || defaultRealtimeOpenAIVoice,
        prompt: "Start a live voice session for this OpenAssist Codex thread."
      }, undefined, codexRealtimeStartTimeoutMs),
      startFailure
    ]));
    cleanupStartFailure();
    bridgeDebugLog(`[realtime.voice] start succeeded thread=${openAssistThreadID} providerThread=${providerThreadID}`);
    eventSink?.({
      type: "thread/realtime/started",
      payload: {
        threadId: openAssistThreadID,
        providerThreadId: providerThreadID,
        version: "v2"
      }
    });
    return { ok: true, threadId: openAssistThreadID, providerThreadId: providerThreadID };
  } catch (error) {
    cleanupStartFailure();
    cleanupRealtimeStart();
    const message = error instanceof Error ? error.message : "Could not start Codex realtime voice.";
    bridgeDebugLog(`[realtime.voice] start failed thread=${openAssistThreadID} providerThread=${providerThreadID}: ${message}`);
    return {
      ok: false,
      error: message
    };
  }
}

async function appendCodexRealtimeAudio(audio: RealtimeAudioChunk) {
  const active = activeRealtimeSession;
  if (!active) return { ok: false, error: "Realtime Voice is not running." };
  if (!audio?.data || typeof audio.data !== "string") {
    return { ok: false, error: "Realtime audio chunk is empty." };
  }
  await codexTransport.request("thread/realtime/appendAudio", {
    threadId: active.providerThreadID,
    audio: {
      data: audio.data,
      sampleRate: Number(audio.sampleRate) || 24000,
      numChannels: Number(audio.numChannels) || 1,
      samplesPerChannel: audio.samplesPerChannel == null ? null : Number(audio.samplesPerChannel),
      itemId: audio.itemId ?? null
    }
  }, undefined, 10_000);
  return { ok: true };
}

async function appendCodexRealtimeText(text: string) {
  const active = activeRealtimeSession;
  if (!active) return { ok: false, error: "Realtime Voice is not running." };
  const trimmed = text.trim();
  if (!trimmed) return { ok: false, error: "Realtime text is empty." };
  await codexTransport.request("thread/realtime/appendText", {
    threadId: active.providerThreadID,
    text: trimmed
  }, undefined, 15_000);
  return { ok: true };
}

async function stopCodexRealtimeVoice() {
  return stopActiveRealtimeSession("stopped");
}

async function listCodexRealtimeVoices() {
  try {
    const response = await codexTransport.request("thread/realtime/listVoices", {}, undefined, 15_000);
    return { ok: true, ...(jsonObject(response) ?? {}) };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : "Could not list Codex realtime voices."
    };
  }
}

export async function respondToProviderRequest(requestID: JsonRequestID, result: unknown) {
  if (typeof requestID !== "string" && typeof requestID !== "number") {
    return { ok: false, error: "The approval request id is missing." };
  }
  try {
    codexTransport.respond(requestID, result);
    return { ok: true };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : "Could not answer the approval request."
    };
  }
}

codexTransport.on("notification", (method: string, params: JsonObject) => {
  recordUsageNotification("codex", method, params);
  logCodexToolCallActivity(method, params);
});

const codexToolCallStartTimes = new Map<string, { startMs: number; toolName: string; args: string }>();

function compactArgsForLog(value: unknown): string {
  if (value == null) return "";
  try {
    const text = typeof value === "string" ? value : JSON.stringify(value);
    return text.length > 200 ? `${text.slice(0, 197)}...` : text;
  } catch {
    return String(value);
  }
}

function logCodexToolCallActivity(method: string, params: JsonObject) {
  const item = runtimeItemPayload(params);
  const callID = firstRuntimeString(
    params.callId,
    params.call_id,
    params.itemId,
    params.item_id,
    item.id,
    item.callId,
    item.call_id
  );
  if (!callID) return;
  const lowerMethod = method.toLowerCase();
  const itemType = firstRuntimeString(item.type, item.kind).toLowerCase();
  const looksLikeToolCall = lowerMethod.includes("toolcall")
    || lowerMethod.includes("tool/call")
    || lowerMethod.includes("mcptoolcall")
    || lowerMethod.includes("functioncall")
    || lowerMethod.includes("commandexecution")
    || itemType.includes("tool")
    || itemType.includes("command")
    || itemType.includes("mcp")
    || itemType.includes("function");
  const isStartMethod = lowerMethod === "item/started"
    || lowerMethod.endsWith("/started")
    || lowerMethod.endsWith("/begin")
    || lowerMethod.includes("requestapproval");
  const isEndMethod = lowerMethod === "item/completed"
    || lowerMethod.endsWith("/completed")
    || lowerMethod.endsWith("/end")
    || lowerMethod.endsWith("/failed");
  const tracked = codexToolCallStartTimes.has(callID);
  if (!tracked && !looksLikeToolCall) return;
  if (!tracked && !isStartMethod && !isEndMethod) return;
  const toolName = firstRuntimeString(
    item.toolName,
    item.tool_name,
    item.name,
    item.tool,
    params.toolName,
    params.tool_name,
    params.name,
    params.tool,
    itemType
  ) || "(unknown-tool)";
  const argsRaw = params.arguments ?? params.args ?? item.arguments ?? item.args ?? item.command ?? params.command;
  const argsCompact = compactArgsForLog(argsRaw);
  const status = firstRuntimeString(
    params.status,
    item.status,
    params.state,
    item.state
  ).toLowerCase();
  const isStart = isStartMethod
    || (looksLikeToolCall && !tracked && (status === "running" || status === "in_progress" || status === "pending" || status === ""));
  const isEnd = isEndMethod
    || status === "completed"
    || status === "succeeded"
    || status === "failed"
    || status === "errored"
    || status === "cancelled"
    || status === "canceled";
  if (isStart && !codexToolCallStartTimes.has(callID)) {
    codexToolCallStartTimes.set(callID, { startMs: Date.now(), toolName, args: argsCompact });
    bridgeDebugLog(`codex tool call start tool="${toolName}" callID=${callID} method=${method} type=${itemType} args=${argsCompact}`);
    return;
  }
  if (isEnd) {
    const start = codexToolCallStartTimes.get(callID);
    if (start) {
      const elapsedMs = Date.now() - start.startMs;
      const resolvedStatus = status || (lowerMethod.endsWith("/failed") ? "failed" : "completed");
      bridgeDebugLog(`codex tool call end tool="${start.toolName}" callID=${callID} status=${resolvedStatus} elapsedMs=${elapsedMs}`);
      codexToolCallStartTimes.delete(callID);
    } else if (looksLikeToolCall) {
      const resolvedStatus = status || (lowerMethod.endsWith("/failed") ? "failed" : "completed");
      bridgeDebugLog(`codex tool call end tool="${toolName}" callID=${callID} method=${method} type=${itemType} status=${resolvedStatus} elapsedMs=unknown`);
    }
  }
}

async function refreshUsageForBackend(
  backend: RuntimeAssistantBackend,
  options: { threadID?: string; modelID?: string; connectThread?: boolean } = {}
) {
  if (backend === "claudeCode") {
    usageSnapshotForBackend("claudeCode");
    return;
  }
  if (backend === "copilot") {
    try {
      const token = await resolveCopilotGitHubToken();
      if (!token) return;
      const response = await fetchWithTimeout("https://api.github.com/copilot_internal/user", {
        headers: {
          Authorization: `token ${token}`,
          Accept: "application/json",
          "Editor-Version": "vscode/1.96.2",
          "Editor-Plugin-Version": "copilot-chat/0.26.7",
          "User-Agent": "GitHubCopilotChat/0.26.7",
          "X-GitHub-Api-Version": "2025-04-01"
        }
      }, 12_000, "Copilot usage refresh timed out.");
      if (!response.ok) return;
      const payload = asObject(await response.json());
      if (!payload) return;
      const usage = copilotUsageFromPayload(payload);
      if (usage) runtimeUsageByBackend.copilot = usage;
    } catch {
      // Keep the UI usable if Copilot auth or network usage refresh fails.
    }
    return;
  }
  if (backend !== "codex") return;
  try {
    const response = await codexTransport.request("account/rateLimits/read", {}, undefined, 12_000);
    recordRateLimits("codex", response);
  } catch {
    // Keep the UI usable if Codex is not signed in or the app server is unavailable.
  }
  if (!options.threadID) return;
  const session = findSession(options.threadID);
  const existingCodexThreadID = providerBinding(session, "codex")?.providerSessionID;
  if (!options.connectThread && !(typeof existingCodexThreadID === "string" && existingCodexThreadID.trim())) return;
  try {
    await ensureCodexProviderSession(options.threadID, options.modelID || readCodexDefaultModel());
  } catch {
    // Rate-limit usage can still show even if the thread could not be resumed yet.
  }
}

async function threadSkillPromptItems(threadID?: string) {
  if (!threadID) return [];
  return loadSkills(threadID)
    .filter((skill) => skill.attached && skill.path)
    .map((skill) => ({ type: "skill", name: skill.title, path: skill.path }) as JsonObject);
}

async function selectedSkillPromptItems(skillIDs: string[] = []) {
  const selected = new Set(skillIDs.map((id) => normalizedSkillID(id)).filter(Boolean));
  if (!selected.size) return [];
  return loadSkills()
    .filter((skill) =>
      skill.path &&
      (selected.has(normalizedSkillID(skill.id)) || selected.has(normalizedSkillID(skill.title)))
    )
    .map((skill) => ({ type: "skill", name: skill.title, path: skill.path }) as JsonObject);
}

function promptWantsImageGeneration(prompt: string) {
  const text = prompt.toLowerCase();
  const asksForCreation = /\b(generate|create|make|draw|render|design|illustrate|paint|mock\s*up|mockup|turn\s+.*\s+into|convert\s+.*\s+into)\b/.test(text);
  const asksForImage = /\b(image|picture|photo|logo|icon|illustration|mockup|poster|banner|cover|thumbnail|wallpaper|avatar|sticker|graphic|visual|ui mock|product shot)\b/.test(text);
  return text.trim().startsWith("/image") || (asksForCreation && asksForImage);
}

function imageGenerationSkillPromptItems(prompt: string) {
  if (!promptWantsImageGeneration(prompt)) return [];
  const skill = loadSkills().find((item) => {
    const normalizedID = normalizedSkillID(item.id);
    const normalizedTitle = normalizedSkillID(item.title);
    const skillPath = item.path ?? "";
    return Boolean(item.path)
      && (normalizedID === "imagegen"
        || normalizedTitle === "imagegen"
        || skillPath.endsWith(`${path.sep}imagegen${path.sep}SKILL.md`));
  });
  if (!skill?.path) return [];
  return [{ type: "skill", name: skill.title, path: skill.path } as JsonObject];
}

function dedupeInputItems(items: JsonObject[]) {
  const seen = new Set<string>();
  return items.filter((item) => {
    const key = `${item.type ?? "item"}:${item.path ?? item.name ?? item.text ?? JSON.stringify(item)}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function normalizeBackend(raw?: string): AssistantBackend {
  const value = (raw ?? "").trim();
  const lowered = value.toLowerCase();
  if (lowered === "copilot" || lowered === "githubcopilot") return "copilot";
  if (lowered === "claude" || lowered === "claudecode" || lowered === "anthropic-cli") return "claudeCode";
  if (lowered === "ollama" || lowered === "ollamalocal" || lowered === "ollama (local)") return "ollamaLocal";
  return "codex";
}

const runtimeBackendOrder: RuntimeAssistantBackend[] = ["codex", "copilot", "claudeCode", "ollamaLocal"];
const runtimeBackendExecutable: Record<RuntimeAssistantBackend, string> = {
  codex: "codex",
  claudeCode: "claude",
  copilot: "copilot",
  ollamaLocal: "ollama"
};

function isRuntimeBackend(backend: AssistantBackend): backend is RuntimeAssistantBackend {
  return backend === "codex" || backend === "copilot" || backend === "claudeCode" || backend === "ollamaLocal";
}

function assistantPATH() {
  const additions = [
    path.join(os.homedir(), ".npm-global/bin"),
    path.join(os.homedir(), ".local/bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin"
  ];
  return [process.env.PATH, ...additions].filter(Boolean).join(path.delimiter);
}

async function executableExists(executable: string) {
  try {
    await execFileAsync("/usr/bin/env", ["which", executable], {
      env: { ...process.env, PATH: assistantPATH() }
    });
    return true;
  } catch {
    return false;
  }
}

async function selectableAssistantBackends(preferred: RuntimeAssistantBackend): Promise<RuntimeAssistantBackend[]> {
  const detected: RuntimeAssistantBackend[] = [];
  for (const backend of runtimeBackendOrder) {
    if (await executableExists(runtimeBackendExecutable[backend])) {
      detected.push(backend);
    }
  }

  if (!detected.length) {
    return preferred === "ollamaLocal" ? ["ollamaLocal"] : [preferred, "ollamaLocal"];
  }
  if (detected.includes("ollamaLocal")) {
    return detected;
  }
  return [...detected, "ollamaLocal"];
}

let runtimeSetupSnapshotCache: { key: string; expiresAt: number; value: AssistantRuntimeSetupSnapshot } | null = null;

function runtimeSetupFallback(
  assistantRuntimeStatus: string,
  assistantRuntimeDetail: string,
  assistantRuntimeStatusTone: AssistantRuntimeSetupSnapshot["assistantRuntimeStatusTone"] = "muted",
  assistantRuntimeLoginCommand = "No extra setup"
): AssistantRuntimeSetupSnapshot {
  return {
    assistantRuntimeStatus,
    assistantRuntimeDetail,
    assistantRuntimeAccount: "Not connected",
    assistantRuntimeAuthMode: "Not connected",
    assistantRuntimeLoginCommand,
    assistantRuntimeStatusTone
  };
}

async function ollamaServerIsRunning() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 1200);
  try {
    const response = await fetch("http://127.0.0.1:11434/api/tags", { signal: controller.signal });
    return response.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

async function runtimeSetupSnapshot(
  backend: RuntimeAssistantBackend,
  availableAssistantBackends: RuntimeAssistantBackend[]
): Promise<AssistantRuntimeSetupSnapshot> {
  const cacheKey = `${backend}:${availableAssistantBackends.join(",")}`;
  const now = Date.now();
  if (runtimeSetupSnapshotCache?.key === cacheKey && runtimeSetupSnapshotCache.expiresAt > now) {
    return runtimeSetupSnapshotCache.value;
  }

  const installed = availableAssistantBackends.includes(backend) || await executableExists(runtimeBackendExecutable[backend]);
  let value: AssistantRuntimeSetupSnapshot;

  if (!installed && backend !== "ollamaLocal") {
    value = runtimeSetupFallback(
      "Install required",
      `${runtimeBackendExecutable[backend]} was not found on PATH.`,
      "warning",
      `Install ${runtimeBackendExecutable[backend]}`
    );
  } else if (backend === "codex") {
    value = {
      assistantRuntimeStatus: "Runtime detected",
      assistantRuntimeDetail: "Codex account access is used when a chat or transcription starts, so settings does not trigger Keychain prompts.",
      assistantRuntimeAccount: "Handled by Codex login",
      assistantRuntimeAuthMode: "ChatGPT subscription or OpenAI API key",
      assistantRuntimeLoginCommand: "codex login",
      assistantRuntimeStatusTone: "ready"
    };
  } else if (backend === "copilot") {
    value = {
      assistantRuntimeStatus: "Runtime detected",
      assistantRuntimeDetail: "GitHub Copilot CLI is installed. Use the login command if Copilot asks for auth.",
      assistantRuntimeAccount: "Handled by GitHub Copilot CLI",
      assistantRuntimeAuthMode: "GitHub Copilot subscription",
      assistantRuntimeLoginCommand: "copilot login",
      assistantRuntimeStatusTone: "ready"
    };
  } else if (backend === "claudeCode") {
    value = {
      assistantRuntimeStatus: "Runtime detected",
      assistantRuntimeDetail: "Claude Code CLI is installed. Use the login command if Claude asks for auth.",
      assistantRuntimeAccount: "Handled by Claude Code CLI",
      assistantRuntimeAuthMode: "Claude subscription or API key",
      assistantRuntimeLoginCommand: "claude auth login",
      assistantRuntimeStatusTone: "ready"
    };
  } else {
    const running = await ollamaServerIsRunning();
    value = {
      assistantRuntimeStatus: running ? "Local server running" : "Local server not running",
      assistantRuntimeDetail: running
        ? "Ollama is reachable on localhost and can be used for local chat."
        : "Start Ollama before using the local provider.",
      assistantRuntimeAccount: "Local only",
      assistantRuntimeAuthMode: "No cloud account",
      assistantRuntimeLoginCommand: "ollama serve",
      assistantRuntimeStatusTone: running ? "ready" : "warning"
    };
  }

  runtimeSetupSnapshotCache = { key: cacheKey, expiresAt: now + 8000, value };
  return value;
}

function startedSessionMessage(backend: AssistantBackend) {
  if (backend === "copilot") return "Started a new GitHub Copilot thread.";
  if (backend === "claudeCode") return "Started a new Claude Code thread.";
  if (backend === "ollamaLocal") return "Started a new Ollama (Local) thread.";
  return "Started a new Codex thread.";
}

function titleForPrompt(prompt: string) {
  const squashed = prompt.replace(/\s+/g, " ").trim();
  return squashed.length > 78 ? `${squashed.slice(0, 77).trimEnd()}...` : squashed || "New Assistant Session";
}

function isGenericThreadTitle(title?: string) {
  return !title?.trim() || title.trim() === "New Assistant Session";
}

function threadItemForCompletedSession(session: SessionSummary) {
  const loadedThread = loadThreads(loadProjects()).find((thread) => thread.id.toLowerCase() === session.id.toLowerCase());
  if (loadedThread) return loadedThread;

  const { project, projectID } = projectContextForThread(session.id);
  const updatedAt = swiftDateToMs(session.updatedAt) ?? Date.now();
  const title = isGenericThreadTitle(session.title)
    ? titleForPrompt(session.latestUserMessage ?? "")
    : session.title.trim();
  return {
    id: session.id,
    title: title.length > 74 ? `${title.slice(0, 73).trimEnd()}...` : title,
    projectID: session.projectID ?? projectID,
    project: session.projectName ?? project?.title,
    activeProvider: normalizeBackend(String(session.activeProvider ?? pluginString(session.providerBackend) ?? "codex")),
    modelID: pluginString(session.modelID, session.latestModel),
    age: relativeAge(updatedAt),
    updatedAt,
    isArchived: session.isArchived === true,
    isTemporary: session.isTemporary === true
  } satisfies ThreadItem;
}

function modelForBackend(backend: AssistantBackend, settings: SettingsSnapshot, session?: SessionSummary) {
  const binding = providerBinding(session, backend);
  const requested = pluginString(
    binding?.latestModelID,
    session?.modelID,
    session?.latestModel,
    backend === "ollamaLocal" ? settings.promptRewriteModel : settings.model
  );
  return normalizedModelForBackend(backend, requested);
}

function transcriptEntry(role: "system" | "user" | "assistant", text: string, backend: AssistantBackend, modelID: string, emphasis = false): JsonObject {
  return {
    id: makeID(),
    role,
    text,
    emphasis,
    isStreaming: false,
    providerBackend: backend,
    providerModelID: modelID,
    createdAt: currentSwiftDate()
  };
}

function timelineUserMessage(threadID: string, text: string, createdAt: number): JsonObject {
  return {
    id: makeID(),
    kind: "userMessage",
    sessionID: threadID,
    source: "runtime",
    text,
    emphasis: false,
    isStreaming: false,
    createdAt,
    updatedAt: createdAt
  };
}

function timelineAssistantFinal(threadID: string, text: string, backend: AssistantBackend, modelID: string, turnID: string, createdAt: number): JsonObject {
  return {
    id: `assistant-final-${makeID()}`,
    kind: "assistantFinal",
    sessionID: threadID,
    source: "runtime",
    text,
    emphasis: false,
    isStreaming: false,
    providerBackend: backend,
    providerModelID: modelID,
    turnID,
    createdAt,
    updatedAt: createdAt
  };
}

function compactRuntimeDetail(value: unknown, maxLength = 320) {
  let text = "";
  if (typeof value === "string") {
    text = value;
  } else if (value != null) {
    try {
      text = JSON.stringify(value);
    } catch {
      text = String(value);
    }
  }
  text = text.replace(/\s+/g, " ").trim();
  if (text.length > maxLength) return `${text.slice(0, maxLength - 1).trimEnd()}...`;
  return text;
}

function firstRuntimeString(...values: unknown[]) {
  for (const value of values) {
    const text = compactRuntimeDetail(value, 800);
    if (text) return text;
  }
  return "";
}

function firstRawRuntimeString(...values: unknown[]) {
  for (const value of values) {
    if (typeof value === "string") {
      const text = value.trim();
      if (text) return text;
    }
  }
  return "";
}

function storedRuntimeString(...values: unknown[]) {
  for (const value of values) {
    const text = typeof value === "string"
      ? value.trim()
      : compactRuntimeDetail(value, 12_000);
    if (text) return text.length > 12_000 ? `${text.slice(0, 11_999).trimEnd()}...` : text;
  }
  return "";
}

function runtimeObject(value: unknown): JsonObject | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : undefined;
}

function jsonObject(value: unknown): JsonObject | undefined {
  return runtimeObject(value);
}

function normalizedRuntimeItemType(value: unknown) {
  return String(value ?? "").replace(/[_\s-]+/g, "").toLowerCase();
}

function isImageGenerationRuntimeType(value: unknown) {
  const normalized = normalizedRuntimeItemType(value);
  return normalized === "imagegeneration" || normalized === "imagegenerationcall" || normalized === "imagegen";
}

function isRuntimeMessageItemType(value: unknown) {
  const normalized = normalizedRuntimeItemType(value);
  return normalized === "message"
    || normalized === "agentmessage"
    || normalized === "assistantmessage"
    || normalized === "usermessage";
}

function isEmptyRuntimeDetail(value: unknown) {
  const normalized = String(value ?? "").replace(/\s+/g, " ").trim().toLowerCase();
  return !normalized
    || normalized === "[]"
    || normalized === "{}"
    || normalized === "null"
    || normalized === "undefined"
    || normalized === "\"\"";
}

function isGenericRuntimeDetail(value: unknown) {
  const normalized = String(value ?? "").replace(/\s+/g, " ").trim().toLowerCase();
  return isEmptyRuntimeDetail(normalized)
    || normalized === "reasoning"
    || normalized === "thinking"
    || normalized === "agent message"
    || normalized === "assistant message"
    || normalized === "user message";
}

function imageMimeTypeFromPath(filePath?: string) {
  if (!filePath?.trim()) return undefined;
  const extension = path.extname(filePath ?? "").toLowerCase();
  if (extension === ".jpg" || extension === ".jpeg") return "image/jpeg";
  if (extension === ".webp") return "image/webp";
  if (extension === ".gif") return "image/gif";
  return "image/png";
}

function imageMimeTypeFromBase64(value: string) {
  const sample = value.trim().slice(0, 24);
  if (sample.startsWith("/9j/")) return "image/jpeg";
  if (sample.startsWith("UklGR")) return "image/webp";
  if (sample.startsWith("R0lGOD")) return "image/gif";
  return "image/png";
}

function imageDataURLFromBase64(value?: string, mimeType?: string) {
  const raw = value?.trim();
  if (!raw) return undefined;
  if (raw.startsWith("data:image/")) return raw;
  if (/^https?:\/\//i.test(raw)) return undefined;
  const normalized = raw.replace(/\s+/g, "");
  if (!/^[A-Za-z0-9+/=]+$/.test(normalized)) return undefined;
  return `data:${mimeType || imageMimeTypeFromBase64(normalized)};base64,${normalized}`;
}

function imageDataURLFromFile(filePath?: string, mimeType?: string) {
  const resolved = filePath?.trim();
  if (!resolved || !fs.existsSync(resolved)) return undefined;
  try {
    return `data:${mimeType || imageMimeTypeFromPath(resolved)};base64,${fs.readFileSync(resolved).toString("base64")}`;
  } catch {
    return undefined;
  }
}

function imageFileNameFromPath(filePath?: string) {
  const name = path.basename(filePath ?? "").trim();
  return name || undefined;
}

function imageGenerationMessageFields(item: JsonObject): Pick<ChatMessage, "imageDataURL" | "imagePath" | "imagePrompt" | "imageMimeType" | "imageName"> {
  const imagePath = firstRuntimeString(item.saved_path, item.savedPath, item.path);
  const prompt = firstRuntimeString(item.revised_prompt, item.revisedPrompt, item.prompt);
  const result = firstRawRuntimeString(item.result, item.b64_json, item.b64Json, item.image, item.data);
  const mimeType = imageMimeTypeFromPath(imagePath) || imageMimeTypeFromBase64(result);
  const imageDataURL = imageDataURLFromBase64(result, mimeType) || imageDataURLFromFile(imagePath, mimeType);
  const rawID = firstRuntimeString(item.id, item.call_id, item.callId);
  const fallbackName = rawID ? `${rawID.replace(/[^a-z0-9._-]+/gi, "-")}.png` : "openassist-generated-image.png";
  return {
    imageDataURL,
    imagePath: imagePath || undefined,
    imagePrompt: prompt || undefined,
    imageMimeType: mimeType,
    imageName: imageFileNameFromPath(imagePath) || fallbackName
  };
}

function runtimeImageFieldsFromValue(value: unknown, depth = 0): Pick<ChatMessage, "imageDataURL" | "imagePath" | "imageMimeType" | "imageName"> | null {
  if (depth > 5 || value == null) return null;
  if (typeof value === "string") {
    const direct = value.trim();
    if (direct.startsWith("data:image/")) {
      const mimeType = direct.match(/^data:(image\/[a-zA-Z0-9+.-]+);base64,/)?.[1] || "image/png";
      return {
        imageDataURL: direct,
        imageMimeType: mimeType,
        imageName: `computer-use-screenshot-${Date.now()}.${mimeType.includes("jpeg") ? "jpg" : "png"}`
      };
    }
    if (path.isAbsolute(direct) && fs.existsSync(direct) && /\.(png|jpe?g|webp|gif)$/i.test(direct)) {
      const mimeType = imageMimeTypeFromPath(direct) || "image/png";
      return {
        imageDataURL: imageDataURLFromFile(direct, mimeType),
        imagePath: direct,
        imageMimeType: mimeType,
        imageName: imageFileNameFromPath(direct)
      };
    }
    return null;
  }
  if (Array.isArray(value)) {
    for (const entry of value) {
      const found = runtimeImageFieldsFromValue(entry, depth + 1);
      if (found?.imageDataURL || found?.imagePath) return found;
    }
    return null;
  }
  const object = runtimeObject(value);
  if (!object) return null;
  const mimeType = firstRuntimeString(
    object.mimeType,
    object.mime_type,
    object.mediaType,
    object.media_type,
    object.contentType,
    object.content_type
  ) || "image/png";
  const objectType = firstRuntimeString(object.type, object.kind).toLowerCase();
  const explicitDataURL = firstRawRuntimeString(
    object.imageDataURL,
    object.image_data_url,
    object.screenshotDataURL,
    object.screenshot_data_url,
    object.dataURL,
    object.data_url,
    object.imageURL,
    object.image_url,
    object.src,
    object.url
  );
  if (explicitDataURL.startsWith("data:image/")) {
    return {
      imageDataURL: explicitDataURL,
      imageMimeType: explicitDataURL.match(/^data:(image\/[a-zA-Z0-9+.-]+);base64,/)?.[1] || mimeType,
      imageName: firstRuntimeString(object.name, object.filename, object.fileName) || `computer-use-screenshot-${Date.now()}.png`
    };
  }
  const imagePath = firstRuntimeString(
    object.imagePath,
    object.image_path,
    object.screenshotPath,
    object.screenshot_path,
    object.filePath,
    object.file_path
  );
  if (imagePath && fs.existsSync(imagePath) && /\.(png|jpe?g|webp|gif)$/i.test(imagePath)) {
    const resolvedMimeType = imageMimeTypeFromPath(imagePath) || mimeType;
    return {
      imageDataURL: imageDataURLFromFile(imagePath, resolvedMimeType),
      imagePath,
      imageMimeType: resolvedMimeType,
      imageName: imageFileNameFromPath(imagePath)
    };
  }
  const base64Image = firstRawRuntimeString(
    object.imageBase64,
    object.image_base64,
    object.screenshotBase64,
    object.screenshot_base64,
    object.b64_json,
    object.b64Json,
    object.image,
    object.screenshot,
    objectType.includes("image") ? object.data : undefined
  );
  if (base64Image) {
    const imageDataURL = imageDataURLFromBase64(base64Image, mimeType);
    if (imageDataURL) {
      return {
        imageDataURL,
        imageMimeType: mimeType,
        imageName: firstRuntimeString(object.name, object.filename, object.fileName) || `computer-use-screenshot-${Date.now()}.png`
      };
    }
  }
  const likelyImageContainers = [
    object.screenshot,
    object.image,
    object.images,
    object.content,
    object.output,
    object.result,
    object.payload,
    object.resource,
    object.resources,
    object.artifacts,
    object.attachments
  ];
  for (const candidate of likelyImageContainers) {
    const found = runtimeImageFieldsFromValue(candidate, depth + 1);
    if (found?.imageDataURL || found?.imagePath) return found;
  }
  return null;
}

function runtimeToolImageFields(params: JsonObject, item: JsonObject): Pick<ChatMessage, "imageDataURL" | "imagePath" | "imagePrompt" | "imageMimeType" | "imageName"> {
  const found = runtimeImageFieldsFromValue([item, params]);
  if (!found) return {};
  return found;
}

function appendRuntimeDelta(existing: string, delta: string) {
  const nextDelta = String(delta ?? "");
  if (!nextDelta) return existing;
  if (!existing) return nextDelta;
  if (existing.includes(nextDelta)) return existing;
  if (nextDelta.includes(existing)) return nextDelta;
  const needsSpace = !/\s$/.test(existing)
    && !/^\s/.test(nextDelta)
    && /[A-Za-z0-9)`\]]$/.test(existing)
    && /^[A-Za-z0-9`([]/.test(nextDelta);
  return `${existing}${needsSpace ? " " : ""}${nextDelta}`;
}

function runtimeItemPayload(params: JsonObject) {
  return runtimeObject(params.item)
    ?? runtimeObject(params.toolCall)
    ?? runtimeObject(params.tool_call)
    ?? runtimeObject(params.activity)
    ?? params;
}

function runtimeItemID(params: JsonObject): string {
  const item = runtimeItemPayload(params);
  return firstRuntimeString(
    params.itemId,
    params.item_id,
    item.id,
    item.itemId,
    item.item_id
  );
}

function runtimeItemPhase(params: JsonObject): string {
  const item = runtimeItemPayload(params);
  const raw = firstRuntimeString(
    params.phase,
    item.phase,
    params.channel,
    item.channel
  );
  return raw.trim().toLowerCase();
}

function runtimeActivityStatus(method: string, item: JsonObject): ChatMessage["activityStatus"] {
  const raw = String(item.status ?? "").toLowerCase();
  if (method.includes("requestApproval") || method.includes("requestUserInput") || method.includes("elicitation/request") || method === "elicitation/create") return "waiting";
  if (method.includes("/completed") || method.endsWith("/end")) return "completed";
  if (raw.includes("failed") || raw.includes("error")) return "failed";
  if (raw.includes("completed") || raw.includes("success")) return "completed";
  if (raw.includes("waiting") || raw.includes("pending")) return "waiting";
  return "running";
}

function runtimeActivityKind(method: string, item: JsonObject) {
  const rawType = String(item.type ?? item.kind ?? "").toLowerCase();
  const toolName = String(item.name ?? item.tool ?? item.toolName ?? item.tool_name ?? "");
  if (isImageGenerationRuntimeType(rawType) || isImageGenerationRuntimeType(toolName)) return "imageGeneration";
  if (method.includes("commandExecution") || rawType.includes("command") || toolName === "exec_command") return "commandExecution";
  if (method.includes("fileChange") || rawType.includes("file_change") || toolName === "apply_patch") return "fileChange";
  if (method.includes("mcpServer") || method.includes("mcpTool") || rawType.includes("mcp") || toolName.startsWith("mcp__")) return "mcpToolCall";
  if (method.includes("collab")) return "subagent";
  if (rawType.includes("web_search") || toolName.includes("web_search")) return "webSearch";
  if (rawType.includes("browser") || toolName.includes("browser")) return "browserAutomation";
  if (toolName === "update_plan" || method.includes("plan")) return "plan";
  if (method.includes("reasoning")) return "reasoning";
  return rawType || "tool";
}

function humanizeRuntimeName(value: string) {
  const normalized = value
    .replace(/^mcp__/, "")
    .replace(/__/g, " ")
    .replace(/[._-]+/g, " ")
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .trim();
  if (!normalized) return "Tool";
  return normalized.replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function runtimeActivityTitle(method: string, item: JsonObject, kind: string) {
  const toolName = firstRuntimeString(item.name, item.tool, item.toolName, item.tool_name);
  if (kind === "commandExecution") return "Command";
  if (kind === "fileChange") return "File Changes";
  if (method.includes("requestApproval")) return "Approval";
  if (kind === "mcpToolCall") {
    const server = firstRuntimeString(item.server, item.serverName, item.mcpServer);
    const tool = firstRuntimeString(item.tool, item.name, item.toolName);
    if (method.includes("elicitation")) return server ? `${humanizeRuntimeName(server)} Approval` : "Approval";
    if (server && tool) return `${humanizeRuntimeName(server)}: ${humanizeRuntimeName(tool)}`;
    return tool ? humanizeRuntimeName(tool) : "MCP Tool";
  }
  if (kind === "webSearch") return "Web Search";
  if (kind === "imageGeneration") return "Image Generation";
  if (kind === "browserAutomation") return "Browser";
  if (kind === "subagent") return "Subagent";
  if (kind === "plan") return "Plan Update";
  if (kind === "reasoning") return "Reasoning";
  return humanizeRuntimeName(toolName || firstRuntimeString(item.title, item.type, method.split("/")[1]) || "Tool");
}

function runtimeActivityDetail(method: string, params: JsonObject, item: JsonObject) {
  const nestedAction = runtimeObject(item.action);
  const command = firstRuntimeString(item.command, item.cmd, item.script);
  if (command) return compactRuntimeDetail(command);
  const delta = storedRuntimeString(params.delta);
  if (delta) return delta;
  return compactRuntimeDetail(firstRuntimeString(
    params.text,
    params.summary,
    params.content,
    params.message,
    item.query,
    item.text,
    item.summary,
    item.content,
    nestedAction?.query,
    item.action,
    item.arguments,
    item.input,
    item.result,
    item.output,
    item.message
  ));
}

function validJsonRequestID(value: unknown): JsonRequestID | undefined {
  return typeof value === "string" || typeof value === "number" ? value : undefined;
}

function runtimeArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function runtimeObjectRecord(value: unknown): Record<string, unknown> {
  return runtimeObject(value) ?? {};
}

function simpleApprovalOption(
  id: string,
  label: string,
  result: unknown,
  tone: "approve" | "neutral" | "danger" = "neutral",
  description?: string
) {
  return { id, label, result, tone, description };
}

function commandApprovalLabel(decision: unknown) {
  if (typeof decision === "string") {
    if (decision === "accept") return "Allow";
    if (decision === "acceptForSession") return "Allow for Session";
    if (decision === "decline") return "Deny";
    if (decision === "cancel") return "Stop Turn";
  }
  const objectDecision = runtimeObject(decision);
  if (objectDecision?.acceptWithExecpolicyAmendment) return "Allow Similar Commands";
  if (objectDecision?.applyNetworkPolicyAmendment) return "Apply Network Rule";
  return "Allow";
}

function commandApprovalTone(decision: unknown): "approve" | "neutral" | "danger" {
  return decision === "decline" || decision === "cancel" ? "danger" : "approve";
}

function mcpSchemaOptionValues(schema: JsonObject): unknown[] {
  const direct = runtimeArray(schema.enum);
  if (direct.length) return direct;
  const oneOf = runtimeArray(schema.oneOf);
  const oneOfValues = oneOf
    .map((entry) => runtimeObject(entry))
    .map((entry) => entry?.const ?? entry?.value ?? entry?.title)
    .filter((entry) => entry != null);
  if (oneOfValues.length) return oneOfValues;
  const anyOf = runtimeArray(schema.anyOf);
  return anyOf
    .map((entry) => runtimeObject(entry))
    .map((entry) => entry?.const ?? entry?.value ?? entry?.title)
    .filter((entry) => entry != null);
}

function mcpPositiveAnswerValue(schema: JsonObject, fallback: string) {
  const options = mcpSchemaOptionValues(schema);
  const positiveTerms = ["allow", "accept", "approved", "approve", "yes", "true", "ok", "confirm"];
  for (const option of options) {
    const normalized = String(option ?? "").trim().toLowerCase();
    if (positiveTerms.some((term) => normalized === term || normalized.includes(term))) return option;
  }
  return options[0] ?? fallback;
}

function coerceMcpScalarValue(value: unknown, schema: JsonObject) {
  const rawType = String(schema.type ?? "").toLowerCase();
  const normalized = String(value ?? "").trim().toLowerCase();
  if (rawType === "boolean") return normalized === "true" || normalized === "yes" || normalized === "allow" || normalized === "accept" || normalized === "confirm";
  if (rawType === "integer") {
    const parsed = Number.parseInt(String(value ?? ""), 10);
    return Number.isFinite(parsed) ? parsed : 1;
  }
  if (rawType === "number") {
    const parsed = Number(String(value ?? ""));
    return Number.isFinite(parsed) ? parsed : 1;
  }
  if (typeof value === "boolean" || typeof value === "number") return value;
  return String(value ?? "");
}

function mcpRequestedSchema(params: JsonObject) {
  const request = runtimeObject(params.request);
  return runtimeObject(params.requestedSchema)
    ?? runtimeObject(params.requested_schema)
    ?? runtimeObject(request?.requestedSchema)
    ?? runtimeObject(request?.requested_schema);
}

function simpleMcpElicitationResult(action: "accept" | "decline" | "cancel", params: JsonObject) {
  if (action !== "accept") return { action, content: null, _meta: null };
  const schema = mcpRequestedSchema(params);
  if (!schema) return { action, content: null, _meta: null };
  const properties = runtimeObjectRecord(schema.properties);
  const propertyKeys = Object.keys(properties);
  if (!propertyKeys.length) return { action, content: { response: "Allow" }, _meta: null };

  const required = new Set(runtimeArray(schema.required).map((value) => String(value)));
  const targetKeys = propertyKeys.filter((key) => !required.size || required.has(key));
  const content: Record<string, unknown> = {};
  for (const key of targetKeys.length ? targetKeys : propertyKeys) {
    const propertySchema = runtimeObjectRecord(properties[key]);
    content[key] = coerceMcpScalarValue(mcpPositiveAnswerValue(propertySchema, "Allow"), propertySchema);
  }
  return { action, content, _meta: null };
}

function approvalFromRuntimeRequest(method: string, params: JsonObject, requestID?: JsonRequestID): Pick<ChatMessage, "approvalRequestID" | "approvalKind" | "approvalPrompt" | "approvalOptions"> | undefined {
  if (requestID == null) return undefined;
  if (method === "item/commandExecution/requestApproval" || method === "execCommandApproval") {
    const decisions = runtimeArray(params.availableDecisions).length
      ? runtimeArray(params.availableDecisions)
      : ["accept", "acceptForSession", "decline", "cancel"];
    return {
      approvalRequestID: requestID,
      approvalKind: "command",
      approvalPrompt: firstRuntimeString(params.reason, params.command, "Codex wants to run a command."),
      approvalOptions: decisions.map((decision) => simpleApprovalOption(
        typeof decision === "string" ? decision : Object.keys(runtimeObjectRecord(decision))[0] || "accept",
        commandApprovalLabel(decision),
        { decision },
        commandApprovalTone(decision)
      ))
    };
  }

  if (method === "item/fileChange/requestApproval" || method === "applyPatchApproval") {
    return {
      approvalRequestID: requestID,
      approvalKind: "fileChange",
      approvalPrompt: firstRuntimeString(params.reason, params.grantRoot, "Codex wants to change files."),
      approvalOptions: [
        simpleApprovalOption("accept", "Allow", { decision: "accept" }, "approve"),
        simpleApprovalOption("acceptForSession", "Allow for Session", { decision: "acceptForSession" }, "approve"),
        simpleApprovalOption("decline", "Deny", { decision: "decline" }, "danger"),
        simpleApprovalOption("cancel", "Stop Turn", { decision: "cancel" }, "danger")
      ]
    };
  }

  if (method === "item/permissions/requestApproval") {
    const permissions = runtimeObjectRecord(params.permissions);
    return {
      approvalRequestID: requestID,
      approvalKind: "permissions",
      approvalPrompt: firstRuntimeString(params.reason, "Codex wants extra permissions."),
      approvalOptions: [
        simpleApprovalOption("allow-turn", "Allow", { permissions, scope: "turn" }, "approve", "Only for this turn"),
        simpleApprovalOption("allow-session", "Allow for Session", { permissions, scope: "session" }, "approve"),
        simpleApprovalOption("deny", "Deny", { permissions: {}, scope: "turn" }, "danger")
      ]
    };
  }

  if (method === "mcpServer/elicitation/request" || method === "elicitation/create") {
    const prompt = firstRuntimeString(params.message, runtimeObject(params.request)?.message, "Codex needs your approval.");
    return {
      approvalRequestID: requestID,
      approvalKind: "mcpElicitation",
      approvalPrompt: prompt,
      approvalOptions: [
        simpleApprovalOption("accept", "Allow", simpleMcpElicitationResult("accept", params), "approve"),
        simpleApprovalOption("decline", "Decline", simpleMcpElicitationResult("decline", params), "danger"),
        simpleApprovalOption("cancel", "Cancel", simpleMcpElicitationResult("cancel", params), "danger")
      ]
    };
  }

  if (method === "item/tool/requestUserInput") {
    const questions = runtimeArray(params.questions).map((question) => runtimeObject(question)).filter(Boolean) as JsonObject[];
    if (questions.length !== 1) return undefined;
    const question = questions[0];
    const questionID = firstRuntimeString(question.id);
    const options = runtimeArray(question.options).map((option) => runtimeObject(option)).filter(Boolean) as JsonObject[];
    if (!questionID || !options.length) return undefined;
    return {
      approvalRequestID: requestID,
      approvalKind: "userInput",
      approvalPrompt: firstRuntimeString(question.question, question.header, "Codex needs input."),
      approvalOptions: options.map((option, index) => {
        const label = firstRuntimeString(option.label, `Option ${index + 1}`);
        return simpleApprovalOption(
          label.toLowerCase().replace(/[^a-z0-9]+/g, "-") || `option-${index + 1}`,
          label,
          { answers: { [questionID]: { answers: [label] } } },
          index === 0 ? "approve" : "neutral",
          firstRuntimeString(option.description)
        );
      })
    };
  }

  return undefined;
}

function providerActivityFromNotification(threadID: string, provider: string, method: string, params: JsonObject, requestID?: JsonRequestID): ChatMessage | null {
  const visibleMethods = [
    "turn/plan/updated",
    "item/plan/delta",
    "item/reasoning/summaryTextDelta",
    "item/reasoning/textDelta",
    "item/started",
    "item/completed",
    "item/commandExecution/outputDelta",
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/permissions/requestApproval",
    "item/tool/requestUserInput",
    "item/tool/call",
    "item/toolCall",
    "item/mcpToolCall",
    "item/functionCall",
    "mcpServer/elicitation/request",
    "elicitation/create",
    "item/collabAgentSpawn/begin",
    "item/collabAgentSpawn/end",
    "item/collabAgentInteraction/begin",
    "item/collabAgentInteraction/end",
    "item/collabWaiting/begin",
    "item/collabWaiting/end"
  ];
  if (!visibleMethods.some((candidate) => method === candidate || method.startsWith(candidate))) return null;
  const item = runtimeItemPayload(params);
  const rawType = firstRuntimeString(item.type, item.kind);
  const rawID = firstRuntimeString(requestID, params.itemId, params.item_id, params.callId, params.call_id, item.id, item.callId, item.call_id);
  const kind = runtimeActivityKind(method, item);
  const approval = approvalFromRuntimeRequest(method, params, requestID);
  if (isRuntimeMessageItemType(rawType) || isRuntimeMessageItemType(kind)) return null;
  const imageFields: Pick<ChatMessage, "imageDataURL" | "imagePath" | "imagePrompt" | "imageMimeType" | "imageName"> = kind === "imageGeneration"
    ? imageGenerationMessageFields(item)
    : runtimeToolImageFields(params, item);
  const detail = kind === "imageGeneration"
    ? (imageFields.imagePrompt || (imageFields.imageDataURL || imageFields.imagePath ? "Generated image" : "Generating image..."))
    : (approval?.approvalPrompt || runtimeActivityDetail(method, params, item));
  if (kind === "reasoning" && isGenericRuntimeDetail(detail)) return null;
  const status = runtimeActivityStatus(method, item);
  const title = runtimeActivityTitle(method, item, kind);
  const normalizedTitle = title.replace(/\s+/g, " ").trim().toLowerCase();
  if (normalizedTitle === "user message") return null;
  if (normalizedTitle === "agent message" && isGenericRuntimeDetail(detail)) return null;
  const now = Date.now();
  const id = rawID || `${method}:${kind}:${title}`.toLowerCase().replace(/[^a-z0-9]+/g, "-");
  return {
    id: `activity-${id}`,
    role: "activity",
    provider,
    text: detail || title,
    status: status === "completed" || status === "failed" ? "completed" : "running",
    activityTitle: title,
    activityKind: kind,
    activityStatus: status,
    activityDetail: detail || undefined,
    ...approval,
    ...imageFields,
    createdAt: now,
    updatedAt: now
  };
}

function timelineActivity(threadID: string, activity: ChatMessage, turnID: string, swiftNow: number): JsonObject {
  return {
    id: activity.id,
    kind: "activity",
    sessionID: threadID,
    source: "runtime",
    turnID,
    activity: {
      id: activity.id,
      sessionID: threadID,
      turnID,
      kind: activity.activityKind ?? "tool",
      title: activity.activityTitle ?? "Tool",
      status: activity.activityStatus ?? "running",
      friendlySummary: activity.activityTitle ?? "Tool",
      rawDetails: activity.activityDetail ?? activity.text,
      imagePath: activity.imagePath,
      imageDataURL: activity.imagePath ? undefined : activity.imageDataURL,
      imagePrompt: activity.imagePrompt,
      imageMimeType: activity.imageMimeType,
      imageName: activity.imageName,
      approvalRequestID: activity.approvalRequestID,
      approvalKind: activity.approvalKind,
      approvalPrompt: activity.approvalPrompt,
      approvalOptions: activity.approvalOptions,
      approvalResolved: activity.approvalResolved,
      startedAt: swiftNow,
      updatedAt: swiftNow,
      source: "runtime"
    },
    isStreaming: activity.status === "running",
    createdAt: swiftNow,
    updatedAt: swiftNow
  };
}

function isRealtimeDelegationActivity(activity: ChatMessage) {
  const kind = String(activity.activityKind ?? "").replace(/[_\s-]+/g, "").toLowerCase();
  const title = String(activity.activityTitle ?? "").replace(/\s+/g, " ").trim().toLowerCase();
  return kind === "realtimedelegation"
    || (kind === "subagent" && title.includes("realtime"))
    || activity.id.includes("realtime-delegation");
}

function upsertRuntimeActivity(threadID: string, activity: ChatMessage, turnID: string) {
  const existingSession = findSession(threadID);
  if (existingSession?.isTemporary === true || existingSession?.conversationPersistence === 0) return;
  const snapshot = readConversationSnapshot(threadID);
  const timeline = snapshot.timeline ?? [];
  const swiftNow = currentSwiftDate();
  const next = timelineActivity(threadID, activity, turnID, swiftNow);
  const index = timeline.findIndex((item) => String(item.id ?? "") === activity.id);
  if (index >= 0) {
    const existing = timeline[index];
    const existingActivity = runtimeObject(existing.activity);
    const nextActivity = runtimeObject(next.activity);
    const existingDetail = storedRuntimeString(existingActivity?.rawDetails, existingActivity?.detail, existing.text);
    const nextDetail = storedRuntimeString(nextActivity?.rawDetails, nextActivity?.detail, next.text);
    const safeNextDetail = isGenericRuntimeDetail(nextDetail) ? "" : nextDetail;
    const mergedDetail = isRealtimeDelegationActivity(activity)
      ? (safeNextDetail || existingDetail)
      : safeNextDetail
        ? appendRuntimeDelta(isGenericRuntimeDetail(existingDetail) ? "" : existingDetail, safeNextDetail)
        : existingDetail;
    const mergedActivity = {
      ...(existingActivity ?? {}),
      ...(nextActivity ?? {})
    };
    if (mergedDetail) {
      mergedActivity.rawDetails = mergedDetail;
    }
    const existingCreatedAt = Number(existing.createdAt ?? 0);
    const nextCreatedAt = Number(next.createdAt ?? 0);
    const shouldMoveActivityStart = isRealtimeDelegationActivity(activity)
      && Number.isFinite(nextCreatedAt)
      && nextCreatedAt > existingCreatedAt;
    timeline[index] = {
      ...existing,
      ...next,
      createdAt: shouldMoveActivityStart ? next.createdAt : existing.createdAt ?? next.createdAt,
      activity: mergedActivity
    };
  } else {
    timeline.push(next);
  }
  writeConversationSnapshot(threadID, {
    ...snapshot,
    threadID,
    timeline,
    lastAppliedEventSequence: snapshot.lastAppliedEventSequence ?? 0
  });
}

function splitTimelineForCompletedTurn(timeline: JsonObject[], turnIDs: string[]) {
  const normalizedTurnIDs = new Set(turnIDs.map((turnID) => turnID.trim()).filter(Boolean));
  const timelineWithoutTurnActivities: JsonObject[] = [];
  const currentTurnActivities: JsonObject[] = [];

  for (const entry of timeline) {
    if (timelineEntryKind(entry) === "activity") {
      const turnID = timelineEntryTurnID(entry);
      if (turnID && normalizedTurnIDs.has(turnID)) {
        currentTurnActivities.push(entry);
        continue;
      }
    }
    timelineWithoutTurnActivities.push(entry);
  }

  return {
    timelineWithoutTurnActivities,
    currentTurnActivities: sortedTimelineActivities(currentTurnActivities)
  };
}

function finalizedTimelineActivity(entry: JsonObject, completedAt: number) {
  const activity = runtimeObject(entry.activity);
  if (!activity) return { ...entry, isStreaming: false, updatedAt: completedAt };
  const statusText = firstRuntimeString(activity.status).toLowerCase();
  const nextStatus = statusText.includes("fail") || statusText.includes("error") ? "failed" : "completed";
  return {
    ...entry,
    isStreaming: false,
    updatedAt: completedAt,
    activity: {
      ...activity,
      status: nextStatus,
      updatedAt: completedAt
    }
  };
}

function persistCompletedTurn({
  threadID,
  backend,
  providerSessionID,
  providerTurnID,
  activityTurnIDs = [],
  modelID,
  prompt,
  responseText,
  insertedSystemMessage,
  reasoningEffort,
  interactionMode,
  permissionMode
}: {
  threadID: string;
  backend: AssistantBackend;
  providerSessionID: string;
  providerTurnID: string;
  activityTurnIDs?: string[];
  modelID: string;
  prompt: string;
  responseText: string;
  insertedSystemMessage: boolean;
  reasoningEffort?: string;
  interactionMode?: string;
  permissionMode?: string;
}) {
  const existingSession = findSession(threadID);
  const isTransient = existingSession?.isTemporary === true || existingSession?.conversationPersistence === 0;
  const snapshot = readConversationSnapshot(threadID);
  const timeline = snapshot.timeline ?? [];
  const transcript = snapshot.transcript ?? [];
  const turns = snapshot.turns ?? [];
  if (insertedSystemMessage) {
    transcript.push(transcriptEntry("system", startedSessionMessage(backend), backend, modelID, true));
  }
  const {
    timelineWithoutTurnActivities,
    currentTurnActivities
  } = splitTimelineForCompletedTurn(timeline, [providerTurnID, ...activityTurnIDs]);
  const firstActivityCreatedAt = currentTurnActivities
    .map(timelineEntryCreatedAt)
    .filter((createdAt) => createdAt > 0)
    .sort((left, right) => left - right)[0];
  const userCreatedAt = firstActivityCreatedAt ? Math.max(0, firstActivityCreatedAt - 0.000001) : currentSwiftDate();
  const assistantCreatedAt = currentSwiftDate();
  const finalizedTurnActivities = currentTurnActivities.map((entry) => finalizedTimelineActivity(entry, assistantCreatedAt));
  const userTimeline = timelineUserMessage(threadID, prompt, userCreatedAt);
  const assistantTimeline = timelineAssistantFinal(threadID, responseText, backend, modelID, providerTurnID, assistantCreatedAt);
  timeline.length = 0;
  timeline.push(...timelineWithoutTurnActivities, userTimeline, ...finalizedTurnActivities, assistantTimeline);
  const userTranscript = transcriptEntry("user", prompt, backend, modelID);
  const assistantTranscript = transcriptEntry("assistant", responseText, backend, modelID);
  transcript.push(userTranscript, assistantTranscript);
  turns.push({
    threadID,
    openAssistTurnID: providerTurnID,
    provider: backend,
    providerSessionID,
    providerTurnID,
    messageIDs: [assistantTimeline.id],
    createdAt: assistantCreatedAt,
    updatedAt: assistantCreatedAt,
    checkpointReferences: []
  });
  if (!isTransient) {
    writeConversationSnapshot(threadID, {
      threadID,
      timeline,
      transcript,
      turns,
      lastAppliedEventSequence: snapshot.lastAppliedEventSequence ?? 0
    });
  }
  const session = ensureOpenAssistSessionRecord(threadID, backend, modelID);
  session.title = isGenericThreadTitle(session.title) ? titleForPrompt(prompt) : session.title;
  session.latestUserMessage = prompt;
  session.latestAssistantMessage = responseText;
  session.latestModel = modelID;
  session.latestInteractionMode = normalizeCodexInteractionMode(interactionMode);
  session.latestReasoningEffort = reasoningEffort || session.latestReasoningEffort || "high";
  session.latestPermissionMode = normalizeCodexPermissionMode(permissionMode);
  session.activeProvider = backend;
  const updatedSession = updateSession(session);
  const thread = threadItemForCompletedSession(updatedSession);
  return {
    session: updatedSession,
    thread,
    title: thread.title
  };
}

async function ensureCodexProviderSession(threadID: string, modelID: string, options: CodexRuntimeOptions = {}) {
  const session = findSession(threadID);
  if (!session) throw new Error("OpenAssist thread was not found.");
  const existing = providerBinding(session, "codex")?.providerSessionID;
  if (typeof existing === "string" && existing.trim()) {
    await codexTransport.request("thread/resume", codexThreadResumeParams(existing, session, modelID, options));
    updateProviderBinding(threadID, "codex", existing, modelID);
    return { providerSessionID: existing, insertedSystemMessage: false };
  }
  const started = await codexTransport.request("thread/start", codexThreadStartParams(session, modelID, options)) as JsonObject;
  const thread = started.thread as JsonObject | undefined;
  const providerSessionID = String(thread?.id ?? "");
  if (!providerSessionID) throw new Error("Codex did not return a thread id.");
  updateProviderBinding(threadID, "codex", providerSessionID, modelID);
  return { providerSessionID, insertedSystemMessage: true };
}

async function sendOllamaMessage(threadID: string, prompt: string, modelID: string) {
  const snapshot = readConversationSnapshot(threadID);
  const messages = (snapshot.transcript ?? [])
    .filter((entry) => entry.role === "user" || entry.role === "assistant")
    .map((entry) => ({ role: entry.role === "assistant" ? "assistant" : "user", content: String(entry.text ?? "") }))
    .filter((entry) => entry.content);
  messages.push({ role: "user", content: prompt });
  const response = await fetch("http://127.0.0.1:11434/api/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ model: modelID || "gemma4:e2b", messages, stream: false })
  });
  if (!response.ok) throw new Error(`Ollama returned ${response.status}.`);
  const payload = await response.json() as JsonObject;
  const message = payload.message as JsonObject | undefined;
  return String(message?.content ?? "").trim() || "Ollama completed without a text response.";
}

function providerWorkingDirectory(session: SessionSummary | undefined) {
  return sessionWorkingDirectory(session) || os.homedir();
}

function ensureCLIProviderSession(threadID: string, backend: Exclude<AssistantBackend, "codex" | "ollamaLocal">, modelID: string) {
  const session = findSession(threadID);
  if (!session) throw new Error("OpenAssist thread was not found.");
  const existing = providerBinding(session, backend)?.providerSessionID;
  if (typeof existing === "string" && existing.trim()) {
    updateProviderBinding(threadID, backend, existing, modelID);
    return { providerSessionID: existing, insertedSystemMessage: false };
  }
  const providerSessionID = randomUUID().toLowerCase();
  updateProviderBinding(threadID, backend, providerSessionID, modelID);
  return { providerSessionID, insertedSystemMessage: true };
}

async function execCaptured(command: string, args: string[], cwd: string) {
  return new Promise<{ stdout: string; stderr: string }>((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      const error = new Error(`${command} timed out.`);
      Object.assign(error, { stdout, stderr });
      reject(error);
    }, 180_000);
    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => {
      stdout += String(chunk);
      if (stdout.length > 8_000_000) stdout = stdout.slice(-4_000_000);
    });
    child.stderr?.on("data", (chunk) => {
      stderr += String(chunk);
      if (stderr.length > 2_000_000) stderr = stderr.slice(-1_000_000);
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      Object.assign(error, { stdout, stderr });
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) {
        resolve({ stdout, stderr });
        return;
      }
      const message = stderr.trim() || stdout.trim() || `${command} exited with code ${code}.`;
      const error = new Error(message);
      Object.assign(error, { stdout, stderr });
      reject(error);
    });
  });
}

function textFromUnknown(value: unknown): string[] {
  if (typeof value === "string") return [value];
  if (Array.isArray(value)) return value.flatMap(textFromUnknown);
  const object = asObject(value);
  if (!object) return [];
  const directKeys = ["result", "response", "text", "message", "content", "output", "summary"];
  const direct = directKeys.flatMap((key) => textFromUnknown(object[key]));
  if (direct.length) return direct;
  return [];
}

function providerCLIText(stdout: string, stderr: string) {
  const candidates: string[] = [];
  for (const line of stdout.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) continue;
    try {
      candidates.push(...textFromUnknown(JSON.parse(trimmed)));
    } catch {
      // Keep reading; some CLIs print progress lines around JSON.
    }
  }
  const cleanCandidates = candidates
    .map((candidate) => candidate.trim())
    .filter((candidate) => candidate && candidate.length > 2);
  if (cleanCandidates.length) return cleanCandidates[cleanCandidates.length - 1];
  const plain = stdout.trim();
  if (plain) return plain;
  return stderr.trim();
}

async function sendCopilotMessage(providerSessionID: string, session: SessionSummary | undefined, prompt: string, modelID: string) {
  const args = [
    "--prompt",
    prompt,
    "--silent",
    "--stream",
    "off",
    "--output-format",
    "json",
    `--resume=${providerSessionID}`
  ];
  if (modelID && modelID !== "default") args.push("--model", modelID);
  const { stdout, stderr } = await execCaptured("copilot", args, providerWorkingDirectory(session));
  return providerCLIText(stdout, stderr) || "GitHub Copilot completed without a text response.";
}

async function sendClaudeCodeMessage(providerSessionID: string, session: SessionSummary | undefined, prompt: string, modelID: string, isNewSession: boolean) {
  const args = [
    "-p",
    prompt,
    "--output-format",
    "json",
    "--permission-mode",
    "default"
  ];
  if (isNewSession) args.push("--session-id", providerSessionID);
  else args.push("--resume", providerSessionID);
  if (modelID && modelID !== "default") args.push("--model", modelID);
  const { stdout, stderr } = await execCaptured("claude", args, providerWorkingDirectory(session));
  return providerCLIText(stdout, stderr) || "Claude Code completed without a text response.";
}

function promptWithSessionInstructions(prompt: string, sessionInstructions?: string) {
  const instructions = sessionInstructions?.trim();
  if (!instructions) return prompt;
  return `Session instructions for this chat:\n${instructions}\n\nUser task:\n${prompt}`;
}

function diagnosticString(value: unknown) {
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value ?? "");
  }
}

function responseIndicatesComputerUseTimeout(text: string) {
  const compact = text.replace(/\s+/g, " ");
  return /\b(screen read|list apps|computer\s*use|notes|google chrome|chrome|brave(?:\s+browser)?|safari|firefox|microsoft\s+edge|edge|arc|vivaldi|opera)\b.{0,240}\btimed out after 120 seconds\b/i.test(compact);
}

function notificationIsFailedComputerUseToolCall(method: string, params: JsonObject) {
  const item = runtimeItemPayload(params);
  const toolName = firstRuntimeString(
    item.toolName,
    item.tool_name,
    item.name,
    item.tool,
    params.toolName,
    params.tool_name,
    params.name,
    params.tool
  ).toLowerCase();
  const serverName = firstRuntimeString(
    item.server,
    item.serverName,
    item.server_name,
    item.mcpServer,
    item.mcp_server,
    params.server,
    params.serverName,
    params.server_name
  ).toLowerCase();
  const detail = diagnosticString(params.error ?? item.error ?? params.message ?? item.message ?? item.output ?? "").toLowerCase();
  const status = firstRuntimeString(params.status, item.status, params.state, item.state).toLowerCase();
  const failed = method.toLowerCase().endsWith("/failed")
    || status === "failed"
    || status === "errored"
    || detail.includes("timed out awaiting tools/call");
  const computerUseTool = serverName.includes("computer-use")
    || detail.includes("computer-use/")
    || [
      "get_app_state",
      "list_apps",
      "click",
      "double_click",
      "right_click",
      "type_text",
      "set_value",
      "scroll",
      "press_key"
    ].includes(toolName);
  return failed && computerUseTool;
}

export async function sendCodexMessage(
  prompt: string,
  threadID?: string,
  pluginIDs: string[] = [],
  sessionInstructions = "",
  reasoningEffort?: string,
  interactionMode?: string,
  permissionMode?: string,
  skillIDs: string[] = [],
  clientRunID?: string,
  eventSink?: (event: ProviderRunEvent) => void
) {
  const normalized = prompt.trim();
  if (!normalized) throw new Error("Message is empty.");
  pluginIDs = canonicalizeCodexPluginIDs(pluginIDs);
  const runtimePrompt = promptWithSessionInstructions(normalized, sessionInstructions);
  const codexReasoningEffort = normalizeCodexReasoningEffort(reasoningEffort);
  const settings = await loadSettings();
  let openAssistThreadID = threadID?.startsWith("openassist-")
    ? threadID
    : createOpenAssistThread(undefined, true).session.id;
  let session = findSession(openAssistThreadID);
  if (!session) {
    const { projectID } = projectContextForThread(openAssistThreadID);
    session = createOpenAssistThread(projectID, true).session;
    openAssistThreadID = session.id;
  }
  const backend = normalizeBackend(String(session.activeProvider ?? settings.assistantBackend ?? "codex"));
  const modelID = modelForBackend(backend, settings, session);
  const activeRun: ActiveProviderRun | undefined = clientRunID && backend === "codex"
    ? {
        backend,
        provider: providerLabel(backend),
        openAssistThreadID,
        pluginIDs: [...pluginIDs]
      }
    : undefined;
  let rejectStop: ((error: Error) => void) | undefined;
  const stopPromise = new Promise<never>((_resolve, reject) => {
    rejectStop = reject;
  });
  if (activeRun && clientRunID) {
    activeRun.rejectStop = rejectStop;
    activeProviderRuns.set(clientRunID, activeRun);
  }
  const emitRunEvent = (event: Partial<ProviderRunEvent> & { type: ProviderRunEvent["type"] }) => {
    eventSink?.({
      runID: clientRunID,
      threadID: openAssistThreadID,
      provider: providerLabel(backend),
      ...event
    } as ProviderRunEvent);
  };
  emitRunEvent({ type: "status", text: `Loading ${providerLabel(backend)} provider...` });
  if (backend === "ollamaLocal") {
    const existing = providerBinding(session, "ollamaLocal")?.providerSessionID;
    updateProviderBinding(openAssistThreadID, "ollamaLocal", openAssistThreadID, modelID);
    const responseText = await sendOllamaMessage(openAssistThreadID, runtimePrompt, modelID);
    const providerTurnID = `ollama-turn-${randomUUID().toLowerCase()}`;
    const completedTurn = persistCompletedTurn({
      threadID: openAssistThreadID,
      backend,
      providerSessionID: openAssistThreadID,
      providerTurnID,
      modelID,
      prompt: normalized,
      responseText,
      insertedSystemMessage: !(typeof existing === "string" && existing.trim()),
      reasoningEffort: codexReasoningEffort,
      interactionMode,
      permissionMode
    });
    emitRunEvent({ type: "completed" });
    return {
      threadID: openAssistThreadID,
      title: completedTurn.title,
      thread: completedTurn.thread,
      user: { id: `user-${Date.now()}`, role: "user", text: normalized } satisfies ChatMessage,
      assistant: {
        id: `assistant-${Date.now()}`,
        role: "assistant",
        text: responseText,
        provider: providerLabel(backend)
      } satisfies ChatMessage
    };
  }
  if (backend === "copilot" || backend === "claudeCode") {
    const providerSession = ensureCLIProviderSession(openAssistThreadID, backend, modelID);
    session = findSession(openAssistThreadID);
    emitRunEvent({ type: "activity", activity: {
      id: `activity-${backend}-${Date.now()}`,
      role: "activity",
      text: `Running ${providerLabel(backend)}...`,
      provider: providerLabel(backend),
      status: "running",
      activityTitle: providerLabel(backend),
      activityKind: "provider",
      activityStatus: "running",
      activityDetail: modelID,
      createdAt: Date.now(),
      updatedAt: Date.now()
    } });
    const responseText = backend === "copilot"
      ? await sendCopilotMessage(providerSession.providerSessionID, session, runtimePrompt, modelID)
      : await sendClaudeCodeMessage(providerSession.providerSessionID, session, runtimePrompt, modelID, providerSession.insertedSystemMessage);
    const providerTurnID = `${backend === "copilot" ? "copilot" : "claude"}-turn-${randomUUID().toLowerCase()}`;
    const completedTurn = persistCompletedTurn({
      threadID: openAssistThreadID,
      backend,
      providerSessionID: providerSession.providerSessionID,
      providerTurnID,
      modelID,
      prompt: normalized,
      responseText,
      insertedSystemMessage: providerSession.insertedSystemMessage,
      reasoningEffort: codexReasoningEffort,
      interactionMode,
      permissionMode
    });
    emitRunEvent({ type: "completed" });
    return {
      threadID: openAssistThreadID,
      title: completedTurn.title,
      thread: completedTurn.thread,
      user: { id: `user-${Date.now()}`, role: "user", text: normalized } satisfies ChatMessage,
      assistant: {
        id: `assistant-${Date.now()}`,
        role: "assistant",
        text: responseText,
        provider: providerLabel(backend)
      } satisfies ChatMessage
    };
  }
  if (backend !== "codex") {
    throw new Error(`${providerLabel(backend)} chat creation is wired to the OpenAssist session registry, but prompt execution is not ported in this Electron bridge yet.`);
  }
  const codexRuntimeOptions: CodexRuntimeOptions = {
    interactionMode,
    permissionMode,
    reasoningEffort: codexReasoningEffort,
    pluginIDs,
    sessionInstructions
  };
  const providerSession = await ensureCodexProviderSession(openAssistThreadID, modelID, codexRuntimeOptions);
  if (activeRun) {
    activeRun.providerThreadID = providerSession.providerSessionID;
  }
  let responseText = "";
  let providerTurnID = `codex-turn-${randomUUID().toLowerCase()}`;
  let didGenerateImage = false;
  let didObserveComputerUseToolFailure = false;
  const activityTurnIDs = new Set<string>([providerTurnID]);
  const activityDetailBuffers = new Map<string, string>();
  const itemPhases = new Map<string, string>();
  const isCommentaryPhase = (phase: string) =>
    phase === "commentary" || phase === "prework" || phase === "creating";
  const noteItemPhase = (params: JsonObject) => {
    const id = runtimeItemID(params);
    const phase = runtimeItemPhase(params);
    if (id && phase) {
      const prior = itemPhases.get(id);
      itemPhases.set(id, phase);
      if (prior !== phase) {
        bridgeDebugLog(`codex item phase id=${id} phase=${phase}`);
      }
    }
  };
  const isDeltaForCommentary = (params: JsonObject) => {
    const inlinePhase = runtimeItemPhase(params);
    if (inlinePhase) return isCommentaryPhase(inlinePhase);
    const id = runtimeItemID(params);
    if (!id) return false;
    const tracked = itemPhases.get(id);
    return Boolean(tracked && isCommentaryPhase(tracked));
  };
  const bufferedActivity = (activity: ChatMessage, method: string): ChatMessage | null => {
    const normalizedTitle = String(activity.activityTitle ?? "").replace(/\s+/g, " ").trim().toLowerCase();
    if (normalizedTitle === "user message") return null;
    if (isRuntimeMessageItemType(activity.activityKind)) return null;
    const existingDetail = activityDetailBuffers.get(activity.id) ?? "";
    const incomingDetail = isGenericRuntimeDetail(activity.activityDetail || activity.text)
      ? ""
      : String(activity.activityDetail || activity.text || "");
    const isDelta = method.toLowerCase().includes("delta");
    const mergedDetail = isDelta && incomingDetail
      ? appendRuntimeDelta(existingDetail, incomingDetail)
      : incomingDetail || existingDetail;
    if (mergedDetail) {
      activityDetailBuffers.set(activity.id, mergedDetail);
    }
    if (activity.activityKind === "reasoning" && !mergedDetail) {
      return null;
    }
    if (normalizedTitle === "agent message" && isGenericRuntimeDetail(mergedDetail)) return null;
    return {
      ...activity,
      text: mergedDetail || activity.text,
      activityDetail: mergedDetail || activity.activityDetail
    };
  };
  const commentaryActivityFromDelta = (method: string, params: JsonObject): ChatMessage | null => {
    const delta = typeof params.delta === "string" ? params.delta : "";
    if (!delta) return null;
    const item = runtimeItemPayload(params);
    const rawID = firstRuntimeString(params.itemId, params.item_id, item.id);
    const id = rawID || `${method}:assistant-progress`;
    const now = Date.now();
    return bufferedActivity({
      id: `activity-${id}`,
      role: "activity",
      provider: "Codex",
      text: delta,
      status: "running",
      activityTitle: "Agent Message",
      activityKind: "assistantProgress",
      activityStatus: "running",
      activityDetail: delta,
      createdAt: now,
      updatedAt: now
    }, method);
  };
  emitRunEvent({ type: "status", text: "Codex is working..." });
  const onNotification = (method: string, params: JsonObject, requestID?: JsonRequestID) => {
    recordUsageNotification("codex", method, params);
    if (notificationIsFailedComputerUseToolCall(method, params)) {
      didObserveComputerUseToolFailure = true;
    }
    const turn = params.turn as JsonObject | undefined;
    const notificationTurnID = String(params.turnId ?? params.turnID ?? turn?.id ?? "");
    if (notificationTurnID) {
      providerTurnID = notificationTurnID;
      activityTurnIDs.add(notificationTurnID);
    }
    if (method === "item/started" || method === "item/completed") {
      noteItemPhase(params);
    }
    if (method === "item/agentMessage/delta" && typeof params.delta === "string") {
      if (isDeltaForCommentary(params)) {
        const commentaryActivity = commentaryActivityFromDelta(method, params);
        if (commentaryActivity) {
          emitRunEvent({ type: "activity", activity: commentaryActivity });
          upsertRuntimeActivity(openAssistThreadID, commentaryActivity, providerTurnID);
        }
      } else {
        responseText += params.delta;
        emitRunEvent({ type: "assistant-delta", delta: params.delta });
      }
    }
    const activity = providerActivityFromNotification(openAssistThreadID, "Codex", method, params, validJsonRequestID(requestID));
    if (activity) {
      if (activity.activityKind === "imageGeneration" && (activity.imageDataURL || activity.imagePath || activity.activityStatus === "completed")) {
        didGenerateImage = true;
      }
      const storedActivity = bufferedActivity(activity, method);
      if (!storedActivity) return;
      emitRunEvent({ type: "activity", activity: storedActivity });
      upsertRuntimeActivity(openAssistThreadID, storedActivity, providerTurnID);
    }
  };
  codexTransport.on("notification", onNotification);
  try {
    const turnComplete = waitForTurnComplete();
    const pluginItems = await pluginPromptItems(pluginIDs, normalized);
    const structuredItems = dedupeInputItems([
      ...(await threadSkillPromptItems(openAssistThreadID)),
      ...(await selectedSkillPromptItems(skillIDs)),
      ...imageGenerationSkillPromptItems(normalized),
      ...pluginItems
    ]);
    const startedTurn = await Promise.race([
      codexTransport.request(
        "turn/start",
        codexTurnStartParams(providerSession.providerSessionID, normalized, structuredItems, modelID, codexRuntimeOptions)
      ) as Promise<JsonObject>,
      stopPromise
    ]);
    const turn = startedTurn.turn as JsonObject | undefined;
    providerTurnID = String(turn?.id ?? providerTurnID);
    activityTurnIDs.add(providerTurnID);
    if (activeRun) {
      activeRun.turnID = providerTurnID;
      if (activeRun.stopped) {
        await interruptCodexRun(activeRun);
        throw new ProviderRunStoppedError(activeRun.provider);
      }
    }
    const completed = await Promise.race([turnComplete, stopPromise]);
    if (completed.failed) {
      throw new Error(completed.error || "Codex turn failed.");
    }
    providerTurnID = completed.turnID ?? providerTurnID;
    activityTurnIDs.add(providerTurnID);
  } finally {
    codexTransport.off("notification", onNotification);
    if (clientRunID) activeProviderRuns.delete(clientRunID);
  }
  const finalText = responseText.trim() || (didGenerateImage ? "Generated image is ready." : "The Codex turn completed without a text response.");
  const shouldRestartAfterComputerUseTimeout = didObserveComputerUseToolFailure || responseIndicatesComputerUseTimeout(finalText);
  const completedTurn = persistCompletedTurn({
    threadID: openAssistThreadID,
    backend,
    providerSessionID: providerSession.providerSessionID,
    providerTurnID,
    activityTurnIDs: Array.from(activityTurnIDs),
    modelID,
    prompt: normalized,
    responseText: finalText,
    insertedSystemMessage: providerSession.insertedSystemMessage,
    reasoningEffort: codexReasoningEffort,
    interactionMode,
    permissionMode
  });
  if (shouldRestartAfterComputerUseTimeout) {
    bridgeDebugLog(`Codex Computer Use failure observed providerThreadID=${providerSession.providerSessionID} turnID=${providerTurnID}`);
    emitRunEvent({ type: "status", text: "Computer Use had trouble. Restarting helper for the next try..." });
    await codexTransport.restart("Codex reported a Computer Use timeout").catch((error) => {
      bridgeDebugLog(`restart after Computer Use timeout failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
    });
  }
  emitRunEvent({ type: "completed" });
  return {
    threadID: openAssistThreadID,
    title: completedTurn.title,
    thread: completedTurn.thread,
    user: { id: `user-${Date.now()}`, role: "user", text: normalized } satisfies ChatMessage,
    assistant: {
      id: `assistant-${Date.now()}`,
      role: "assistant",
      text: finalText,
      provider: "Codex"
    } satisfies ChatMessage
  };
}

export async function codexRuntimeParityProbe(options: {
  prompt?: string;
  cwd?: string;
  pluginIDs?: string[];
  sessionInstructions?: string;
  reasoningEffort?: string;
  interactionMode?: string;
  permissionMode?: string;
  modelID?: string;
} = {}) {
  const prompt = options.prompt?.trim() || "Check the current app state.";
  const cwd = options.cwd?.trim() || undefined;
  const modelID = options.modelID?.trim() || readCodexDefaultModel();
  const reasoningEffort = normalizeCodexReasoningEffort(options.reasoningEffort);
  const canonicalPluginIDs = canonicalizeCodexPluginIDs(options.pluginIDs ?? []);
  const runtimeOptions: CodexRuntimeOptions = {
    interactionMode: options.interactionMode,
    permissionMode: options.permissionMode,
    reasoningEffort,
    pluginIDs: canonicalPluginIDs,
    sessionInstructions: options.sessionInstructions
  };
  const session: SessionSummary = {
    id: "openassist-codex-runtime-probe",
    title: "Codex Runtime Probe",
    source: "openAssist",
    status: "idle",
    ...(cwd ? { cwd, effectiveCWD: cwd } : {})
  };
  const pluginItems = await pluginPromptItems(canonicalPluginIDs, prompt);
  const structuredInputItems = dedupeInputItems(pluginItems);
  const sampleDesktopSpecs = [
    { name: "app_action" },
    { name: "computer_use" },
    { name: "exec_command" }
  ];
  const filteredSampleSpecs = codexDynamicToolSpecs(canonicalPluginIDs, sampleDesktopSpecs);
  const approvalProbes = {
    mcpServerRequest: approvalFromRuntimeRequest(
      "mcpServer/elicitation/request",
      { message: "Allow Computer Use?" },
      "codex-runtime-probe-mcp-server"
    ),
    elicitationCreate: approvalFromRuntimeRequest(
      "elicitation/create",
      { request: { message: "Allow Computer Use?" } },
      "codex-runtime-probe-elicitation-create"
    )
  };
  return {
    threadStart: codexThreadStartParams(session, modelID, runtimeOptions),
    threadResume: codexThreadResumeParams("codex-runtime-probe-thread", session, modelID, runtimeOptions),
    turnStart: codexTurnStartParams("codex-runtime-probe-thread", prompt, structuredInputItems, modelID, runtimeOptions),
    pluginItems: structuredInputItems,
    desktopToolSuppression: {
      baseline: sampleDesktopSpecs.map((spec) => spec.name),
      filtered: filteredSampleSpecs.map((spec) => spec.name)
    },
    approvalProbes
  };
}

function providerErrorMessage(params: JsonObject) {
  const error = runtimeObject(params.error);
  return firstRuntimeString(
    error?.message,
    params.message,
    params.error,
    params.reason,
    params.details
  );
}

function waitForTurnComplete() {
  return new Promise<{ turnID?: string; failed?: boolean; error?: string }>((resolve) => {
    const done = (method: string, params: JsonObject) => {
      if (method === "turn/completed" || method === "turn/failed") {
        codexTransport.off("notification", done);
        const turn = params.turn as JsonObject | undefined;
        const turnID = String(params.turnId ?? params.turnID ?? turn?.id ?? "");
        resolve({
          turnID: turnID || undefined,
          failed: method === "turn/failed",
          error: providerErrorMessage(params)
        });
      }
    };
    codexTransport.on("notification", done);
  });
}

export {
  analyzeScreenWithCodex,
  archiveSession,
  assignSessionToProject,
  createOpenAssistThread as createAssistantThread,
  createProject,
  createProjectNote,
  createSkill,
  createThreadNote,
  deleteProject,
  deleteSessionPermanently,
  hideProject,
  unhideProject,
  installKokoroVoiceModel,
  importSkillFolder,
  importSkillFromGitHub,
  loadProjectMemory,
  loadThreadMessages,
  loadThreadMemory,
  loadThreadNoteWorkspace,
  loadNote,
  readNoteImageDataURL,
  moveProjectToFolder,
  promoteTemporarySession,
  renameProject,
  renameSession,
  createScheduledJob,
  saveThreadNote,
  saveProjectNote,
  selectThreadNote,
  approveTelegramPairing,
  clearCloudTranscriptionAPIKey,
  clearPromptRewriteAPIKey,
  clearTelegramBotToken,
  declineTelegramPairing,
  forgetTelegramPairing,
  appendCodexRealtimeAudio,
  appendCodexRealtimeText,
  saveCloudTranscriptionAPIKey,
  savePromptRewriteAPIKey,
  saveRealtimeOpenAIAPIKey,
  saveTelegramBotToken,
  stopCodexRealtimeVoice,
  testTelegramConnection,
  clearRealtimeOpenAIAPIKey,
  cloudVoiceInputReadiness,
  listCodexRealtimeVoices,
  prewarmCodexTranscriptionAuthContext,
  prewarmAssistantVoiceOutput,
  speakAssistantResponse,
  startCodexRealtimeVoice,
  stopAssistantVoiceOutput,
  stopCodexRealtimeDelegation,
  transcribeAudioFile,
  toggleScheduledJob,
  unarchiveSession,
  updateProjectIcon,
  updateProjectLinkedFolder,
  updateSetting,
  updateShortcut,
  voiceInputConfiguration,
  writeThreadSkillBinding as toggleThreadSkill
};
