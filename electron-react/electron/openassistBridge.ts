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
import {
  GitCheckpointService,
  type CodeCheckpointFile,
  type CodeCheckpointPhase,
  type GitCheckpointRepositoryContext,
  type GitCheckpointSnapshot
} from "./gitCheckpointService.js";

const execFileAsync = promisify(execFile);
const macAbsoluteEpochOffset = 978_307_200;
const secureCredentialsFileName = "electron-secure-credentials.json";
const transcriptionRequestTimeoutMs = 35_000;
const gitCheckpointService = new GitCheckpointService();

let threadsChangedListener: (() => void) | null = null;
export function setThreadsChangedListener(listener: (() => void) | null) {
  threadsChangedListener = listener;
}
function notifyThreadsChanged() {
  if (!threadsChangedListener) return;
  try {
    threadsChangedListener();
  } catch (error) {
    bridgeDebugLog(`threads-changed broadcast failed: ${error instanceof Error ? error.message : String(error)}`);
  }
}
const pendingCodeCheckpointBaselinesBySessionID = new Map<string, {
  sessionID: string;
  checkpointID: string;
  repository: GitCheckpointRepositoryContext;
  beforeSnapshot: GitCheckpointSnapshot;
  startedAt: number;
}>();
type KokoroVoiceID = NonNullable<import("kokoro-js").GenerateOptions["voice"]>;

type JsonObject = Record<string, unknown>;
type JsonRequestID = string | number;
type AssistantBackend =
  | "codex"
  | "copilot"
  | "claudeCode"
  | "antigravityCLI"
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
  isRunning?: boolean;
  runStatusText?: string;
  active?: boolean;
};

type ChatMessage = {
  id: string;
  role: "user" | "assistant" | "activity";
  text: string;
  attachments?: ComposerImageAttachment[];
  artifacts?: MessageArtifact[];
  provider?: string;
  status?: "completed" | "running";
  turnID?: string;
  checkpointInfo?: MessageCheckpointInfo;
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

type MessageArtifact = {
  id: string;
  kind: "image" | "file";
  name: string;
  path: string;
  mimeType?: string;
  dataURL?: string;
  size?: number;
  width?: number;
  height?: number;
};

type ComposerImageAttachment = {
  id: string;
  name: string;
  mimeType: string;
  dataURL: string;
  size?: number;
};

type CodeCheckpointTurnStatus = "completed" | "failed" | "cancelled";

type CodeCheckpointSummary = {
  id: string;
  checkpointNumber: number;
  createdAt: number;
  turnStatus: CodeCheckpointTurnStatus;
  summary: string;
  patch: string;
  changedFiles: CodeCheckpointFile[];
  ignoredTouchedPaths: string[];
  beforeSnapshot: GitCheckpointSnapshot;
  afterSnapshot: GitCheckpointSnapshot;
  associatedMessageID?: string;
  associatedTurnID?: string;
  associatedUserMessageID?: string;
};

type CodeTrackingState = {
  sessionID: string;
  availability: "available" | "unavailable" | "error";
  repoRootPath?: string;
  repoLabel?: string;
  checkpoints: CodeCheckpointSummary[];
  currentCheckpointPosition: number;
  errorMessage?: string;
};

type CodeReviewPanelState = {
  sessionID: string;
  repoRootPath: string;
  repoLabel: string;
  checkpoints: CodeCheckpointSummary[];
  currentCheckpointPosition: number;
  selectedCheckpointID: string;
  hasActiveTurn: boolean;
  actionsLocked: boolean;
};

type MessageCheckpointInfo = {
  checkpoint: CodeCheckpointSummary;
  checkpointIndex: number;
  currentCheckpointPosition: number;
  totalCheckpointCount: number;
  hasActiveTurn: boolean;
  actionsLocked: boolean;
  futureTurnsHidden: boolean;
};

type ProviderRunEvent =
  | { runID?: string; threadID: string; type: "status"; provider: string; text: string }
  | { runID?: string; threadID: string; type: "assistant-delta"; provider: string; delta: string }
  | { runID?: string; threadID: string; type: "activity"; provider: string; activity: ChatMessage }
  | { runID?: string; threadID: string; type: "completed"; provider: string }
  | { runID?: string; threadID: string; type: "failed"; provider: string; error: string };
type CapturedOutputSource = "stdout" | "stderr";
type CapturedOutputHandler = (source: CapturedOutputSource, chunk: string, stdout: string, stderr: string) => void;

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
  bridgeDebugLog(`terminating provider helper tree reason="${reason}" pids=${tree.join(",")}`);
  for (const pid of tree) killProcessQuietly(pid, "SIGTERM");
  await delay(900);
  for (const pid of tree) {
    if (isProcessAlive(pid)) killProcessQuietly(pid, "SIGKILL");
  }
}

function elapsedProcessSeconds(value: string) {
  const text = value.trim();
  if (!text) return 0;
  const daySplit = text.split("-");
  const dayCount = daySplit.length > 1 ? Number.parseInt(daySplit[0] ?? "0", 10) : 0;
  const timePart = daySplit.length > 1 ? daySplit.slice(1).join("-") : text;
  const timeParts = timePart.split(":").map((part) => Number.parseInt(part, 10));
  if (timeParts.some((part) => !Number.isFinite(part))) return 0;
  const [hours, minutes, seconds] = timeParts.length === 3
    ? timeParts
    : timeParts.length === 2
      ? [0, timeParts[0], timeParts[1]]
      : [0, 0, timeParts[0]];
  return (Number.isFinite(dayCount) ? dayCount : 0) * 86_400
    + (hours ?? 0) * 3_600
    + (minutes ?? 0) * 60
    + (seconds ?? 0);
}

function parseProcessSnapshotLine(line: string) {
  const match = line.match(/^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.+)$/);
  if (!match) return null;
  return {
    pid: Number.parseInt(match[1] ?? "", 10),
    ppid: Number.parseInt(match[2] ?? "", 10),
    elapsedSeconds: elapsedProcessSeconds(match[3] ?? ""),
    command: match[4] ?? ""
  };
}

async function processSnapshot() {
  try {
    const { stdout } = await execFileAsync("ps", ["-axo", "pid=,ppid=,etime=,command="], { maxBuffer: 2_000_000 });
    return stdout
      .split(/\r?\n/)
      .map(parseProcessSnapshotLine)
      .filter((entry): entry is NonNullable<ReturnType<typeof parseProcessSnapshotLine>> => Boolean(entry));
  } catch (error) {
    bridgeDebugLog(`process snapshot failed: ${error instanceof Error ? error.message : String(error)}`);
    return [];
  }
}

function computerUseHelperKind(command: string): "mcp" | "turn-ended" | "service" | "browser-mcp" | "browser-chrome" | null {
  if (command.includes("SkyComputerUseClient")) {
    if (/(^|\s)mcp($|\s)/.test(command)) return "mcp";
    if (/(^|\s)turn-ended($|\s)/.test(command)) return "turn-ended";
  }
  if (command.includes("SkyComputerUseService")) return "service";
  if (
    command.includes(".codex/playwright-chrome-profile")
    && (command.includes("playwright-mcp") || command.includes("@playwright/mcp"))
  ) {
    return "browser-mcp";
  }
  if (
    command.includes("/Applications/Google Chrome.app/")
    && command.includes(".codex/playwright-chrome-profile")
  ) {
    return "browser-chrome";
  }
  return null;
}

function isCodexAppServerCommand(command: string) {
  return /\bcodex(?:\s+|\S*\/codex\s+)app-server\b/.test(command);
}

async function cleanupOpenAssistOwnedCodexAppServers(currentAppServerPID?: number, reason = "OpenAssist Codex app-server cleanup") {
  const protectedPIDs = new Set<number>();
  if (currentAppServerPID && Number.isFinite(currentAppServerPID)) {
    protectedPIDs.add(currentAppServerPID);
    for (const descendant of await descendantProcessIDs(currentAppServerPID)) {
      protectedPIDs.add(descendant);
    }
  }
  const snapshot = await processSnapshot();
  const ownedServers = snapshot
    .filter((entry) => entry.ppid === process.pid && isCodexAppServerCommand(entry.command))
    .filter((entry) => !protectedPIDs.has(entry.pid))
    .filter((entry) => entry.elapsedSeconds >= 15);
  if (!ownedServers.length) return { killed: [] as number[] };
  bridgeDebugLog(`${reason} killing roots=${ownedServers.map((entry) => entry.pid).join(",")} details=${ownedServers.map((entry) => `${entry.pid}:${entry.elapsedSeconds}s:${entry.command.slice(0, 120)}`).join(" | ")}`);
  const killed = new Set<number>();
  for (const entry of ownedServers) {
    const descendants = await descendantProcessIDs(entry.pid);
    for (const descendant of descendants) killed.add(descendant);
    killed.add(entry.pid);
    await terminateProcessTree(entry.pid, reason);
  }
  return { killed: Array.from(killed) };
}

function staleComputerUseHelperThresholdSeconds(kind: ReturnType<typeof computerUseHelperKind>) {
  if (kind === "turn-ended") return 60;
  if (kind === "service") return 180;
  if (kind === "browser-mcp" || kind === "browser-chrome") return 180;
  return 180;
}

async function cleanupStaleComputerUseHelpers(currentAppServerPID?: number, options: { allowDuringActiveToolCall?: boolean } = {}) {
  if (!options.allowDuringActiveToolCall && activeComputerUseToolCalls.size > 0) {
    bridgeDebugLog(`Computer Use stale helper cleanup skipped because ${activeComputerUseToolCalls.size} tool call(s) are still active.`);
    return { killed: [] as number[] };
  }
  const protectedPIDs = new Set<number>();
  if (currentAppServerPID && Number.isFinite(currentAppServerPID)) {
    protectedPIDs.add(currentAppServerPID);
  }
  const staleHelpers = (await processSnapshot())
    .map((entry) => ({ ...entry, kind: computerUseHelperKind(entry.command) }))
    .filter((entry) => Boolean(entry.kind))
    .filter((entry) => !protectedPIDs.has(entry.pid) && !protectedPIDs.has(entry.ppid))
    .filter((entry) => entry.elapsedSeconds >= staleComputerUseHelperThresholdSeconds(entry.kind));
  if (!staleHelpers.length) {
    bridgeDebugLog("Computer Use stale helper cleanup found no stale helpers.");
    return { killed: [] as number[] };
  }
  const selectedPIDs = new Set(staleHelpers.map((entry) => entry.pid));
  const rootPIDs = staleHelpers
    .filter((entry) => !selectedPIDs.has(entry.ppid))
    .map((entry) => entry.pid);
  bridgeDebugLog(`Computer Use stale helper cleanup killing roots=${rootPIDs.join(",")} details=${staleHelpers.map((entry) => `${entry.pid}:${entry.kind}:${entry.elapsedSeconds}s`).join(",")}`);
  const killed = new Set<number>();
  for (const pid of rootPIDs) {
    const descendants = await descendantProcessIDs(pid);
    for (const descendant of descendants) killed.add(descendant);
    killed.add(pid);
    await terminateProcessTree(pid, "Computer Use stale helper cleanup");
  }
  return { killed: Array.from(killed) };
}

async function resetCodexIfCurrentComputerUseHelperExists(reason: string) {
  const currentPID = codexTransport.currentPID();
  if (!currentPID || !Number.isFinite(currentPID) || activeComputerUseToolCalls.size > 0) {
    return false;
  }
  await cleanupOpenAssistOwnedCodexAppServers(currentPID, "Clean stale OpenAssist Codex app-servers before Computer Use").catch((error) => {
    bridgeDebugLog(`OpenAssist Codex app-server cleanup before Computer Use failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
  });
  const currentHelpers = (await processSnapshot())
    .map((entry) => ({ ...entry, kind: computerUseHelperKind(entry.command) }))
    .filter((entry) => Boolean(entry.kind))
    .filter((entry) => entry.pid !== currentPID && entry.ppid === currentPID);
  if (!currentHelpers.length) return false;
  bridgeDebugLog(`Computer Use helper already attached before turn; restarting Codex reason="${reason}" details=${currentHelpers.map((entry) => `${entry.pid}:${entry.kind}:${entry.elapsedSeconds}s`).join(",")}`);
  await codexTransport.restart(reason);
  await cleanupStaleComputerUseHelpers(undefined, { allowDuringActiveToolCall: true }).catch((error) => {
    bridgeDebugLog(`Computer Use cleanup after current-helper restart failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
  });
  return true;
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

const maxComposerImageAttachments = 6;
const maxComposerImageAttachmentBytes = 12 * 1024 * 1024;

function dataURLImageMimeType(rawValue: string) {
  const match = /^data:([^;,]+);base64,/i.exec(rawValue.trim());
  return match?.[1]?.trim().toLowerCase() || "";
}

function normalizedComposerAttachmentName(rawValue: unknown, fallbackIndex: number, mimeType: string) {
  const fallbackExtension = mimeType === "image/jpeg" ? "jpg" : mimeType.split("/")[1]?.split("+")[0] || "png";
  const fallback = `attached-image-${fallbackIndex}.${fallbackExtension}`;
  const value = typeof rawValue === "string" ? rawValue.trim() : "";
  if (!value) return fallback;
  const basename = path.basename(value).replace(/[/:\\]/g, "-").trim();
  return basename || fallback;
}

function normalizeComposerImageAttachments(rawValue: unknown): ComposerImageAttachment[] {
  if (!Array.isArray(rawValue)) return [];
  return rawValue.slice(0, maxComposerImageAttachments).map((item, index) => {
    if (!item || typeof item !== "object") {
      throw new Error("Image attachment data was not valid.");
    }
    const object = item as Record<string, unknown>;
    const dataURL = typeof object.dataURL === "string" ? object.dataURL.trim() : "";
    const commaIndex = dataURL.indexOf(",");
    if (commaIndex <= 0 || !dataURL.toLowerCase().startsWith("data:image/")) {
      throw new Error("Only image attachments can be sent right now.");
    }
    const mimeType = dataURLImageMimeType(dataURL) || "image/png";
    const encodedPayload = dataURL.slice(commaIndex + 1).replace(/\s+/g, "");
    if (!encodedPayload) {
      throw new Error("Image attachment data was empty.");
    }
    const imageData = Buffer.from(encodedPayload, "base64");
    if (!imageData.length) {
      throw new Error("Image attachment data was empty.");
    }
    if (imageData.length > maxComposerImageAttachmentBytes) {
      throw new Error("One image is too large. Please attach an image under 12 MB.");
    }
    return {
      id: typeof object.id === "string" && object.id.trim() ? object.id.trim() : `attachment-${randomUUID().toLowerCase()}`,
      name: normalizedComposerAttachmentName(object.name, index + 1, mimeType),
      mimeType,
      dataURL: `data:${mimeType};base64,${encodedPayload}`,
      size: typeof object.size === "number" && Number.isFinite(object.size) ? object.size : imageData.length
    };
  });
}

function composerImageInputItems(attachments: ComposerImageAttachment[]) {
  return attachments.flatMap((attachment, index) => [
    {
      type: "text",
      text: `Attached image ${index + 1}: ${attachment.name}`,
      text_elements: []
    },
    {
      type: "image",
      url: attachment.dataURL
    }
  ] satisfies JsonObject[]);
}

function composerImageInstructionItems(attachments: ComposerImageAttachment[]) {
  if (!attachments.length) return [] as JsonObject[];
  return [{
    type: "text",
    text: "If image attachments are present, analyze those attached images directly. Do not use tools or browser/app automation just to inspect attached images.",
    text_elements: []
  } as JsonObject];
}

async function materializeComposerImageAttachments(threadID: string, attachments: ComposerImageAttachment[]) {
  if (!attachments.length) return "";
  const directory = path.join(os.tmpdir(), `openassist-chat-images-${threadID.replace(/[^a-z0-9_-]/gi, "-")}-${randomUUID().toLowerCase()}`);
  fs.mkdirSync(directory, { recursive: true });
  const lines = [
    "Image attachments are available on disk for this turn.",
    "Open and inspect these files directly if the user's request depends on the image:"
  ];
  attachments.forEach((attachment, index) => {
    const commaIndex = attachment.dataURL.indexOf(",");
    const data = Buffer.from(attachment.dataURL.slice(commaIndex + 1), "base64");
    const filename = normalizedComposerAttachmentName(attachment.name, index + 1, attachment.mimeType);
    const filePath = path.join(directory, filename);
    fs.writeFileSync(filePath, data);
    lines.push(`- ${attachment.name} [${attachment.mimeType}]: ${filePath}`);
  });
  return lines.join("\n");
}

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

function pluginBackedSkillPluginName(skillID: string) {
  const trimmed = skillID.trim();
  const separatorIndex = trimmed.indexOf(":");
  if (separatorIndex <= 0) return "";
  return trimmed.slice(0, separatorIndex).trim().toLowerCase();
}

async function normalizeCodexToolSelection(pluginIDs: string[] = [], skillIDs: string[] = []) {
  const canonicalPluginIDs = canonicalizeCodexPluginIDs(pluginIDs);
  const pluginSkillIDs = skillIDs.filter((id) => typeof id === "string" && pluginBackedSkillPluginName(id));
  if (!pluginSkillIDs.length) return { pluginIDs: canonicalPluginIDs, skillIDs };

  const pluginByName = new Map<string, string>();
  try {
    const plugins = await loadPlugins();
    for (const plugin of plugins) {
      if (plugin.status !== "Installed") continue;
      const canonicalID = canonicalizeCodexPluginID(plugin.id);
      const candidates = [
        plugin.pluginName,
        plugin.id.split("@")[0],
        plugin.title
      ];
      for (const candidate of candidates) {
        const key = candidate?.trim().toLowerCase();
        if (key && !pluginByName.has(key)) pluginByName.set(key, canonicalID);
      }
    }
  } catch (error) {
    bridgeDebugLog(`Could not normalize plugin-backed skill selections: ${error instanceof Error ? error.message : String(error)}`);
  }

  const pluginIDsByKey = new Map<string, string>();
  for (const pluginID of canonicalPluginIDs) pluginIDsByKey.set(pluginID.toLowerCase(), pluginID);

  const nextSkillIDs: string[] = [];
  const seenSkillIDs = new Set<string>();
  for (const skillID of skillIDs) {
    const pluginName = pluginBackedSkillPluginName(skillID);
    const pluginID = pluginName ? pluginByName.get(pluginName) : undefined;
    if (pluginID) {
      pluginIDsByKey.set(pluginID.toLowerCase(), pluginID);
      continue;
    }
    const skillKey = normalizedSkillID(skillID);
    if (!skillKey || seenSkillIDs.has(skillKey)) continue;
    seenSkillIDs.add(skillKey);
    nextSkillIDs.push(skillID);
  }

  return { pluginIDs: Array.from(pluginIDsByKey.values()), skillIDs: nextSkillIDs };
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

async function writeCloudTranscriptionProviderSelection(provider: string, resetProviderDefaults: boolean) {
  await writeStringDefault("OpenAssist.cloudTranscriptionProvider", provider);
  if (!resetProviderDefaults) return;
  await writeStringDefault("OpenAssist.cloudTranscriptionModel", cloudTranscriptionDefaultModel(provider));
  await writeStringDefault("OpenAssist.cloudTranscriptionBaseURL", cloudTranscriptionDefaultBaseURL(provider));
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
    cloudTranscriptionModel: settings.cloudTranscriptionProvider === "ChatGPT / Codex Session"
      ? cloudTranscriptionDefaultModel(settings.cloudTranscriptionProvider)
      : settings.cloudTranscriptionModel,
    cloudTranscriptionBaseURL: settings.cloudTranscriptionProvider === "ChatGPT / Codex Session"
      ? cloudTranscriptionDefaultBaseURL(settings.cloudTranscriptionProvider)
      : settings.cloudTranscriptionBaseURL,
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
  const model = provider === "ChatGPT / Codex Session"
    ? cloudTranscriptionDefaultModel(provider)
    : settings.cloudTranscriptionModel || cloudTranscriptionDefaultModel(provider);
  const baseURL = provider === "ChatGPT / Codex Session"
    ? cloudTranscriptionDefaultBaseURL(provider)
    : settings.cloudTranscriptionBaseURL || cloudTranscriptionDefaultBaseURL(provider);
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
  if (!primary && !secondary && !context && !planType) return null;
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
    antigravityCLI: usageSnapshotForBackend("antigravityCLI"),
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

function antigravityModelID(displayName: string) {
  return displayName
    .trim()
    .toLowerCase()
    .replace(/\(([^)]+)\)/g, "$1")
    .replace(/[^a-z0-9.]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function antigravityModelOptions(): ProviderModelOption[] {
  return [
    {
      ...providerModelOption(
        "gemini-3.5-flash-high",
        "Gemini 3.5 Flash (High)",
        "Fast · Limited time"
      ),
      isDefault: true
    },
    providerModelOption(
      "gemini-3.5-flash-low",
      "Gemini 3.5 Flash (Low)",
      "Fast · Limited time"
    ),
    providerModelOption(
      "gemini-3.1-pro-high",
      "Gemini 3.1 Pro (High)",
      "Antigravity reasoning model from local Antigravity account state."
    ),
    providerModelOption(
      "gemini-3.1-pro-low",
      "Gemini 3.1 Pro (Low)",
      "Antigravity reasoning model from local Antigravity account state."
    ),
    providerModelOption(
      "claude-sonnet-4.6-thinking",
      "Claude Sonnet 4.6 (Thinking)",
      "Antigravity reasoning model from local Antigravity account state."
    ),
    providerModelOption(
      "claude-opus-4.6-thinking",
      "Claude Opus 4.6 (Thinking)",
      "Antigravity reasoning model from local Antigravity account state."
    ),
    providerModelOption(
      "gpt-oss-120b-medium",
      "GPT-OSS 120B (Medium)",
      "Recommended"
    ),
    {
      ...providerModelOption(
        "antigravity-default",
        "Gemini 3.5 Flash (High)",
        "Legacy Open Assist default. Antigravity will use its selected reasoning model."
      ),
      hidden: true
    }
  ];
}

function readProtoVarint(buffer: Buffer, offset: number): [number, number] | null {
  let value = 0;
  let shift = 0;
  for (let cursor = offset; cursor < buffer.length; cursor += 1) {
    const byte = buffer[cursor];
    value += (byte & 0x7f) * (2 ** shift);
    if ((byte & 0x80) === 0) return [value, cursor + 1];
    shift += 7;
    if (shift > 49) return null;
  }
  return null;
}

function lengthDelimitedProtoFields(buffer: Buffer) {
  const fields: Buffer[] = [];
  let offset = 0;
  while (offset < buffer.length) {
    const tag = readProtoVarint(buffer, offset);
    if (!tag) return fields;
    offset = tag[1];
    const wireType = tag[0] & 7;
    if (wireType === 0) {
      const next = readProtoVarint(buffer, offset);
      if (!next) return fields;
      offset = next[1];
    } else if (wireType === 1) {
      offset += 8;
    } else if (wireType === 2) {
      const lengthValue = readProtoVarint(buffer, offset);
      if (!lengthValue) return fields;
      const length = lengthValue[0];
      offset = lengthValue[1];
      if (length < 0 || offset + length > buffer.length) return fields;
      const value = buffer.subarray(offset, offset + length);
      if (value.length > 0) fields.push(value);
      offset += length;
    } else if (wireType === 5) {
      offset += 4;
    } else {
      return fields;
    }
  }
  return fields;
}

function printableStrings(buffer: Buffer) {
  const strings: string[] = [];
  let start = -1;
  for (let index = 0; index <= buffer.length; index += 1) {
    const byte = index < buffer.length ? buffer[index] : 0;
    const printable = byte >= 32 && byte <= 126;
    if (printable && start < 0) start = index;
    if ((!printable || index === buffer.length) && start >= 0) {
      if (index - start >= 4) strings.push(buffer.toString("utf8", start, index));
      start = -1;
    }
  }
  return strings;
}

function base64Decode(value: string): Buffer | null {
  const compact = value.trim().replace(/\s+/g, "");
  if (!compact || compact.length < 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(compact)) return null;
  try {
    const padded = compact.padEnd(Math.ceil(compact.length / 4) * 4, "=");
    const decoded = Buffer.from(padded, "base64");
    return decoded.length ? decoded : null;
  } catch {
    return null;
  }
}

function antigravityDecodedStateBuffers(rawBase64: string) {
  const first = base64Decode(rawBase64);
  if (!first) return [];
  const buffers: Buffer[] = [];
  const queue = [first];
  const seen = new Set<string>();
  while (queue.length && buffers.length < 300) {
    const buffer = queue.shift();
    if (!buffer || buffer.length > 1_000_000) continue;
    const key = `${buffer.length}:${buffer.subarray(0, 16).toString("hex")}`;
    if (seen.has(key)) continue;
    seen.add(key);
    buffers.push(buffer);
    for (const field of lengthDelimitedProtoFields(buffer)) {
      queue.push(field);
      for (const text of printableStrings(field)) {
        if (text.length >= 16) {
          const decoded = base64Decode(text);
          if (decoded) queue.push(decoded);
        }
      }
    }
    for (const text of printableStrings(buffer)) {
      if (text.length >= 16) {
        const decoded = base64Decode(text);
        if (decoded) queue.push(decoded);
      }
    }
  }
  return buffers;
}

function isAntigravityModelName(value: string) {
  return /^(Gemini|Claude|GPT-OSS)\b/i.test(value)
    && value.length <= 80
    && !value.includes("/")
    && !value.includes("@")
    && (/\d/.test(value) || /^Claude\b/i.test(value));
}

function antigravityModelsFromState(rawBase64: string): ProviderModelOption[] {
  const descriptors = new Set(["Fast", "Limited time", "Recommended"]);
  const strings = antigravityDecodedStateBuffers(rawBase64)
    .flatMap(printableStrings)
    .map((value) => value.replace(/\s+/g, " ").trim())
    .filter(Boolean);
  const models: ProviderModelOption[] = [];
  const seen = new Set<string>();
  for (let index = 0; index < strings.length; index += 1) {
    const displayName = strings[index];
    if (!isAntigravityModelName(displayName)) continue;
    const normalized = displayName.toLowerCase();
    if (seen.has(normalized)) continue;
    seen.add(normalized);
    const notes: string[] = [];
    for (const next of strings.slice(index + 1, index + 5)) {
      if (isAntigravityModelName(next)) break;
      if (descriptors.has(next) && !notes.includes(next)) notes.push(next);
    }
    models.push({
      ...providerModelOption(
        antigravityModelID(displayName),
        displayName,
        notes.length ? notes.join(" · ") : "Antigravity reasoning model from local Antigravity account state."
      ),
      isDefault: models.length === 0
    });
  }
  if (!models.length) return [];
  return [
    ...models,
    {
      ...providerModelOption(
        "antigravity-default",
        models[0].displayName,
        "Legacy Open Assist default. Antigravity will use its selected reasoning model."
      ),
      hidden: true
    }
  ];
}

let antigravityModelCache: { expiresAt: number; value: ProviderModelOption[] } | null = null;

function antigravityGlobalStorageDatabase() {
  return path.join(os.homedir(), "Library", "Application Support", "Antigravity", "User", "globalStorage", "state.vscdb");
}

async function readAntigravityUnifiedStateValue(key: string) {
  const database = antigravityGlobalStorageDatabase();
  if (!fs.existsSync(database)) return "";
  const { stdout } = await execFileAsync("sqlite3", [
    "-noheader",
    "-batch",
    database,
    `select value from ItemTable where key='${key.replace(/'/g, "''")}' limit 1;`
  ], { timeout: 2500 });
  return stdout.trim();
}

async function loadAntigravityModelsFromState(): Promise<ProviderModelOption[]> {
  const now = Date.now();
  if (antigravityModelCache && antigravityModelCache.expiresAt > now) return antigravityModelCache.value;
  const rawState = await readAntigravityUnifiedStateValue("antigravityUnifiedStateSync.userStatus");
  const models = uniqueProviderModels(antigravityModelsFromState(String(rawState)));
  const value = models.length ? models : fallbackModelOptionsForBackend("antigravityCLI");
  antigravityModelCache = { expiresAt: now + 60_000, value };
  return value;
}

function antigravityPlanFromState(rawBase64: string) {
  const strings = antigravityDecodedStateBuffers(rawBase64)
    .flatMap(printableStrings)
    .map((value) => value.replace(/\s+/g, " ").trim());
  return strings.find((value) => /^Google AI (Pro|Ultra)$/i.test(value))
    ?? strings.find((value) => /^Google AI\b/i.test(value))
    ?? null;
}

async function refreshAntigravityUsageFromState() {
  const rawState = await readAntigravityUnifiedStateValue("antigravityUnifiedStateSync.userStatus");
  const planType = antigravityPlanFromState(String(rawState));
  if (!planType) return;
  const existing = runtimeUsageByBackend.antigravityCLI;
  runtimeUsageByBackend.antigravityCLI = makeProviderUsage(
    "antigravityCLI",
    existing?.primary ?? null,
    existing?.secondary ?? null,
    existing?.context ?? null,
    planType
  ) ?? existing;
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
  if (backend === "antigravityCLI") {
    return antigravityModelOptions();
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
  if (backend === "antigravityCLI") {
    try {
      return await loadAntigravityModelsFromState();
    } catch {
      return fallbackModelOptionsForBackend("antigravityCLI");
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

function attachActivityArtifactsToAssistantMessages(messages: ChatMessage[]) {
  let pendingArtifacts: MessageArtifact[] = [];
  return messages.map((message) => {
    if (message.role === "user") {
      pendingArtifacts = [];
      return message;
    }
    if (message.role === "activity") {
      pendingArtifacts = uniqueArtifacts([...pendingArtifacts, ...(message.artifacts ?? [])]);
      return message;
    }
    if (message.role === "assistant") {
      const existingArtifacts = message.artifacts ?? [];
      const artifacts = existingArtifacts.length ? existingArtifacts : pendingArtifacts;
      pendingArtifacts = [];
      return artifacts.length ? { ...message, artifacts } : message;
    }
    return message;
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

async function loadThreadMessages(threadID: string): Promise<ThreadDetail> {
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
          artifacts: messageArtifactsFromStored(entry.artifacts),
          provider: typeof entry.providerBackend === "string" ? providerLabel(entry.providerBackend) : undefined,
          status: entry.isStreaming === true ? "running" : "completed",
          turnID: firstRuntimeString(entry.turnID, entry.turnId) || undefined,
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
        const storedArtifacts = messageArtifactsFromStored(activity.artifacts);
        const inferredArtifacts = storedArtifacts.length ? storedArtifacts : messageArtifactsFromText(detail);
        const imageArtifact = inferredArtifacts.find((artifact) => artifact.kind === "image" && artifact.dataURL);
        const imageDataURL = storedImageDataURL || imageDataURLFromFile(imagePath, imageMimeType) || imageArtifact?.dataURL;
        const artifacts = inferredArtifacts;
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
          artifacts,
          status: activityStatus === "running" || activityStatus === "waiting" || activityStatus === "pending" ? "running" : "completed",
          activityTitle: title,
          activityKind,
          activityStatus,
          activityDetail: detail || undefined,
          imageDataURL,
          imagePath: imagePath || imageArtifact?.path || undefined,
          imagePrompt: firstRuntimeString(activity.imagePrompt, activity.image_prompt) || undefined,
          imageMimeType: imageDataURL || imagePath || imageArtifact ? imageArtifact?.mimeType || imageMimeType : undefined,
          imageName: firstRuntimeString(activity.imageName, activity.image_name) || imageFileNameFromPath(imagePath) || imageArtifact?.name,
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
  const messagesWithArtifacts = attachActivityArtifactsToAssistantMessages(messages);
  const codeTrackingState = await loadCodeTrackingState(threadID).catch(() => readCodeTrackingState(threadID));
  return {
    threadID,
    title: messagesWithArtifacts.find((message) => message.role === "user")?.text.slice(0, 80) || "Untitled chat",
    messages: attachCodeCheckpointInfo(messagesWithArtifacts, codeTrackingState)
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

function codeTrackingStatePath(threadID: string) {
  return path.join(conversationStoreRoot(), threadID, "code-tracking.json");
}

function emptyCodeTrackingState(threadID: string): CodeTrackingState {
  return {
    sessionID: threadID,
    availability: "unavailable",
    checkpoints: [],
    currentCheckpointPosition: -1
  };
}

function readCodeTrackingState(threadID: string): CodeTrackingState {
  const snapshot = readJSON<Partial<CodeTrackingState>>(codeTrackingStatePath(threadID), emptyCodeTrackingState(threadID));
  return {
    sessionID: String(snapshot.sessionID || threadID),
    availability: snapshot.availability === "available" || snapshot.availability === "error" ? snapshot.availability : "unavailable",
    repoRootPath: typeof snapshot.repoRootPath === "string" ? snapshot.repoRootPath : undefined,
    repoLabel: typeof snapshot.repoLabel === "string" ? snapshot.repoLabel : undefined,
    checkpoints: Array.isArray(snapshot.checkpoints) ? snapshot.checkpoints as CodeCheckpointSummary[] : [],
    currentCheckpointPosition: typeof snapshot.currentCheckpointPosition === "number" && Number.isFinite(snapshot.currentCheckpointPosition)
      ? Number(snapshot.currentCheckpointPosition)
      : -1,
    errorMessage: typeof snapshot.errorMessage === "string" ? snapshot.errorMessage : undefined
  };
}

function writeCodeTrackingState(state: CodeTrackingState) {
  writeJSON(codeTrackingStatePath(state.sessionID), {
    version: 1,
    ...state
  });
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

function clampCodeTrackingState(state: CodeTrackingState): CodeTrackingState {
  const maxPosition = state.checkpoints.length - 1;
  const currentCheckpointPosition = state.checkpoints.length
    ? Math.max(-1, Math.min(state.currentCheckpointPosition, maxPosition))
    : -1;
  return {
    ...state,
    currentCheckpointPosition
  };
}

function saveCodeTrackingState(state: CodeTrackingState) {
  const normalized = clampCodeTrackingState(state);
  writeCodeTrackingState(normalized);
  return normalized;
}

async function repositoryForTrackedCode(threadID: string, fallbackState?: CodeTrackingState): Promise<GitCheckpointRepositoryContext | null> {
  const session = findSession(threadID);
  const cwd = sessionWorkingDirectory(session)?.trim() || fallbackState?.repoRootPath?.trim();
  if (!cwd) return null;
  return gitCheckpointService.repositoryContext(cwd);
}

async function loadCodeTrackingState(threadID: string): Promise<CodeTrackingState> {
  let state = readCodeTrackingState(threadID);
  const repository = await repositoryForTrackedCode(threadID, state);
  if (!repository) {
    state = saveCodeTrackingState({
      ...state,
      availability: "unavailable",
      repoRootPath: undefined,
      repoLabel: undefined
    });
    return state;
  }

  state = {
    ...state,
    availability: "available",
    repoRootPath: repository.rootPath,
    repoLabel: repository.label
  };

  state = await recoverIncompleteTrackedCodeCheckpoints(threadID, repository, state);
  return saveCodeTrackingState(state);
}

async function recoverIncompleteTrackedCodeCheckpoints(
  threadID: string,
  repository: GitCheckpointRepositoryContext,
  state: CodeTrackingState
): Promise<CodeTrackingState> {
  const existingIDs = new Set(state.checkpoints.map((checkpoint) => checkpoint.id));
  const storedRefs = await gitCheckpointService.storedCheckpointRefs(repository, threadID);
  let nextState = state;
  for (const refState of storedRefs) {
    if (existingIDs.has(refState.checkpointID)) continue;
    if (!refState.hasBeforeWorktreeRef || !refState.hasBeforeIndexRef) continue;
    try {
      const beforeSnapshot = await gitCheckpointService.loadSnapshot(repository, threadID, refState.checkpointID, "before");
      if (!beforeSnapshot) continue;
      const afterSnapshot = refState.hasAfterWorktreeRef && refState.hasAfterIndexRef
        ? await gitCheckpointService.loadSnapshot(repository, threadID, refState.checkpointID, "after")
        : await gitCheckpointService.captureSnapshot(repository, threadID, refState.checkpointID, "after");
      if (!afterSnapshot) continue;
      const capture = await gitCheckpointService.buildCaptureResult(repository, beforeSnapshot, afterSnapshot);
      if (!capture.changedFiles.length) {
        await gitCheckpointService.deleteRefs(repository.rootPath, [
          beforeSnapshot.worktreeRef,
          beforeSnapshot.indexRef,
          afterSnapshot.worktreeRef,
          afterSnapshot.indexRef
        ]);
        continue;
      }
      const checkpoint: CodeCheckpointSummary = {
        id: refState.checkpointID,
        checkpointNumber: nextState.checkpoints.length + 1,
        createdAt: currentSwiftDate(),
        turnStatus: "completed",
        summary: capture.summary,
        patch: capture.patch,
        changedFiles: capture.changedFiles,
        ignoredTouchedPaths: capture.ignoredTouchedPaths,
        beforeSnapshot,
        afterSnapshot
      };
      nextState = {
        ...nextState,
        checkpoints: [...nextState.checkpoints, checkpoint],
        currentCheckpointPosition: nextState.checkpoints.length
      };
      existingIDs.add(refState.checkpointID);
      bridgeDebugLog(`recovered Electron code checkpoint threadID=${threadID} checkpointID=${refState.checkpointID}`);
    } catch (error) {
      bridgeDebugLog(`failed to recover Electron code checkpoint threadID=${threadID} checkpointID=${refState.checkpointID} error=${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return nextState;
}

async function beginTrackedCodeCheckpointIfNeeded(
  threadID: string,
  interactionMode: string | undefined,
  settings: SettingsSnapshot
) {
  if (!settings.assistantTrackCodeChangesInGitRepos) return;
  if (normalizeCodexInteractionMode(interactionMode) !== "agentic") return;
  if (pendingCodeCheckpointBaselinesBySessionID.has(threadID)) return;
  const repository = await repositoryForTrackedCode(threadID);
  if (!repository) {
    saveCodeTrackingState({
      ...readCodeTrackingState(threadID),
      sessionID: threadID,
      availability: "unavailable",
      repoRootPath: undefined,
      repoLabel: undefined
    });
    return;
  }
  const checkpointID = randomUUID().toLowerCase();
  try {
    const beforeSnapshot = await gitCheckpointService.captureSnapshot(repository, threadID, checkpointID, "before");
    pendingCodeCheckpointBaselinesBySessionID.set(threadID, {
      sessionID: threadID,
      checkpointID,
      repository,
      beforeSnapshot,
      startedAt: currentSwiftDate()
    });
    saveCodeTrackingState({
      ...readCodeTrackingState(threadID),
      sessionID: threadID,
      availability: "available",
      repoRootPath: repository.rootPath,
      repoLabel: repository.label
    });
    bridgeDebugLog(`started Electron code checkpoint threadID=${threadID} checkpointID=${checkpointID}`);
  } catch (error) {
    saveCodeTrackingState({
      ...readCodeTrackingState(threadID),
      sessionID: threadID,
      availability: "error",
      repoRootPath: repository.rootPath,
      repoLabel: repository.label,
      errorMessage: error instanceof Error ? error.message : String(error)
    });
    bridgeDebugLog(`failed to start Electron code checkpoint threadID=${threadID} error=${error instanceof Error ? error.message : String(error)}`);
  }
}

async function finalizeTrackedCodeCheckpointIfNeeded(options: {
  threadID: string;
  turnID?: string;
  assistantMessageID?: string;
  userMessageID?: string;
  turnStatus: CodeCheckpointTurnStatus;
}) {
  const baseline = pendingCodeCheckpointBaselinesBySessionID.get(options.threadID);
  if (!baseline) return undefined;
  pendingCodeCheckpointBaselinesBySessionID.delete(options.threadID);
  try {
    const afterSnapshot = await gitCheckpointService.captureSnapshot(
      baseline.repository,
      options.threadID,
      baseline.checkpointID,
      "after"
    );
    const capture = await gitCheckpointService.buildCaptureResult(
      baseline.repository,
      baseline.beforeSnapshot,
      afterSnapshot
    );
    if (!capture.changedFiles.length) {
      await gitCheckpointService.deleteRefs(baseline.repository.rootPath, [
        baseline.beforeSnapshot.worktreeRef,
        baseline.beforeSnapshot.indexRef,
        afterSnapshot.worktreeRef,
        afterSnapshot.indexRef
      ]);
      await loadCodeTrackingState(options.threadID);
      return undefined;
    }
    const state = await loadCodeTrackingState(options.threadID);
    const retainedCheckpoints = state.checkpoints.slice(0, Math.max(0, state.currentCheckpointPosition + 1));
    const checkpoint: CodeCheckpointSummary = {
      id: baseline.checkpointID,
      checkpointNumber: retainedCheckpoints.length + 1,
      createdAt: currentSwiftDate(),
      turnStatus: options.turnStatus,
      summary: capture.summary,
      patch: capture.patch,
      changedFiles: capture.changedFiles,
      ignoredTouchedPaths: capture.ignoredTouchedPaths,
      beforeSnapshot: baseline.beforeSnapshot,
      afterSnapshot,
      associatedMessageID: options.assistantMessageID,
      associatedTurnID: options.turnID,
      associatedUserMessageID: options.userMessageID
    };
    const nextState = saveCodeTrackingState({
      ...state,
      availability: "available",
      repoRootPath: baseline.repository.rootPath,
      repoLabel: baseline.repository.label,
      checkpoints: [...retainedCheckpoints, checkpoint],
      currentCheckpointPosition: retainedCheckpoints.length
    });
    bridgeDebugLog(`finalized Electron code checkpoint threadID=${options.threadID} checkpointID=${checkpoint.id} files=${checkpoint.changedFiles.length}`);
    return { checkpoint, state: nextState };
  } catch (error) {
    saveCodeTrackingState({
      ...readCodeTrackingState(options.threadID),
      sessionID: options.threadID,
      availability: "error",
      repoRootPath: baseline.repository.rootPath,
      repoLabel: baseline.repository.label,
      errorMessage: error instanceof Error ? error.message : String(error)
    });
    bridgeDebugLog(`failed to finalize Electron code checkpoint threadID=${options.threadID} checkpointID=${baseline.checkpointID} error=${error instanceof Error ? error.message : String(error)}`);
    return undefined;
  }
}

function checkpointInfoFor(checkpoint: CodeCheckpointSummary, state: CodeTrackingState): MessageCheckpointInfo {
  const checkpointIndex = Math.max(0, state.checkpoints.findIndex((item) => item.id === checkpoint.id));
  return {
    checkpoint,
    checkpointIndex,
    currentCheckpointPosition: state.currentCheckpointPosition,
    totalCheckpointCount: state.checkpoints.length,
    hasActiveTurn: false,
    actionsLocked: false,
    futureTurnsHidden: checkpointIndex > state.currentCheckpointPosition
  };
}

function attachCodeCheckpointInfo(messages: ChatMessage[], state: CodeTrackingState) {
  if (state.availability !== "available" || !state.checkpoints.length) return messages;
  const byID = new Map(messages.map((message) => [message.id, message]));
  for (let index = 0; index < state.checkpoints.length; index += 1) {
    const checkpoint = state.checkpoints[index];
    if (!checkpoint) continue;
    let target = checkpoint.associatedMessageID ? byID.get(checkpoint.associatedMessageID) : undefined;
    if (!target && checkpoint.associatedTurnID) {
      target = messages.find((message) =>
        message.role === "assistant" && message.turnID === checkpoint.associatedTurnID
      );
    }
    if (!target) {
      const checkpointCreatedAtMs = swiftDateToMs(checkpoint.createdAt) ?? Date.now();
      target = [...messages]
        .reverse()
        .find((message) => message.role === "assistant" && (message.createdAt ?? 0) <= checkpointCreatedAtMs);
    }
    if (!target || target.role !== "assistant") continue;
    target.checkpointInfo = {
      checkpoint,
      checkpointIndex: index,
      currentCheckpointPosition: state.currentCheckpointPosition,
      totalCheckpointCount: state.checkpoints.length,
      hasActiveTurn: false,
      actionsLocked: false,
      futureTurnsHidden: index > state.currentCheckpointPosition
    };
  }
  return messages;
}

async function openCodeReview(threadID: string, checkpointID?: string): Promise<CodeReviewPanelState | null> {
  const state = await loadCodeTrackingState(threadID);
  if (state.availability !== "available" || !state.repoRootPath || !state.repoLabel || !state.checkpoints.length) {
    return null;
  }
  const selectedCheckpointID = checkpointID && state.checkpoints.some((checkpoint) => checkpoint.id === checkpointID)
    ? checkpointID
    : state.checkpoints[Math.max(0, state.currentCheckpointPosition)]?.id ?? state.checkpoints.at(-1)?.id ?? "";
  if (!selectedCheckpointID) return null;
  return {
    sessionID: threadID,
    repoRootPath: state.repoRootPath,
    repoLabel: state.repoLabel,
    checkpoints: state.checkpoints,
    currentCheckpointPosition: state.currentCheckpointPosition,
    selectedCheckpointID,
    hasActiveTurn: pendingCodeCheckpointBaselinesBySessionID.has(threadID),
    actionsLocked: false
  };
}

async function restoreCodeCheckpoint(threadID: string, checkpointID: string) {
  const state = await loadCodeTrackingState(threadID);
  const repository = await repositoryForTrackedCode(threadID, state);
  if (!repository) throw new Error("Open Assist could not find a Git repository for this chat.");
  const checkpointIndex = state.checkpoints.findIndex((checkpoint) => checkpoint.id === checkpointID);
  if (checkpointIndex < 0) throw new Error("Open Assist could not find that saved checkpoint.");
  const checkpoint = state.checkpoints[checkpointIndex];
  const isUndo = checkpointIndex === state.currentCheckpointPosition;
  const isRedo = checkpointIndex === state.currentCheckpointPosition + 1;
  if (!isUndo && !isRedo) {
    throw new Error("Open Assist can only restore the current checkpoint or the next hidden checkpoint.");
  }
  const expectedSnapshot = isUndo ? checkpoint.afterSnapshot : checkpoint.beforeSnapshot;
  const guard = await gitCheckpointService.restoreGuard(
    repository,
    expectedSnapshot.worktreeTree,
    expectedSnapshot.indexTree
  );
  if (!guard.isAllowed) throw new Error(guard.message ?? "Open Assist can’t restore this checkpoint right now.");
  await gitCheckpointService.restore(repository, checkpoint.changedFiles, isUndo ? "before" : "after");
  const nextState = saveCodeTrackingState({
    ...state,
    currentCheckpointPosition: isUndo ? checkpointIndex - 1 : checkpointIndex
  });
  return {
    ok: true,
    state: nextState,
    panel: await openCodeReview(threadID, checkpointID)
  };
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
  if (backend === "antigravityCLI") {
    if (!requested || lowered === "antigravity-default") return "gemini-3.5-flash-high";
    return requested;
  }
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
    throw new Error("Main chat runtime must be Codex, Claude, Copilot, Antigravity, or Ollama.");
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
  if (raw === "antigravityCLI") return "Antigravity";
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
  const appStatuses = await listPluginAppStatuses().catch((error) => {
    bridgeDebugLog(`Codex app/list failed while building plugin prompt items: ${error instanceof Error ? error.message : String(error)}`);
    return [] as PluginAppStatus[];
  });
  const seenAppMentionPaths = new Set<string>();
  for (const plugin of plugins) {
    const detail = await readPluginDetail(plugin).catch(() => null);
    if (!detail) continue;
    for (const skill of detail.skills) {
      if (skill.path) {
        inputItems.push({ type: "skill", name: pluginSkillInputName(plugin, skill), path: skill.path });
      }
    }
    for (const app of matchingPluginAppStatuses(plugin, prompt, detail.apps, appStatuses)) {
      const appName = app.name.trim();
      const mentionPath = `app://${app.id}`;
      const key = mentionPath.toLowerCase();
      if (!app.id || !appName || seenAppMentionPaths.has(key)) continue;
      seenAppMentionPaths.add(key);
      inputItems.push({ type: "mention", name: appName, path: mentionPath });
    }
  }
  const selectionContext = codexPluginSelectionContextText(plugins);
  if (selectionContext) {
    inputItems.push({ type: "text", text: selectionContext });
  }
  const computerUseGuidance = computerUsePluginTurnGuidance(canonicalIDs);
  if (computerUseGuidance) {
    inputItems.push({ type: "text", text: computerUseGuidance });
  }
  return inputItems;
}

function codexPluginSelectionContextText(plugins: PluginItem[]) {
  const installed = plugins.filter((plugin) => plugin.status === "Installed");
  if (!installed.length) return "";
  const lines = installed.map((plugin) => `- ${plugin.title}`);
  return [
    "Selected installed plugins for this turn:",
    lines.join("\n"),
    "",
    "Treat these plugins as the required path for this request.",
    "Use them first and do not switch to unrelated tools or a generic fallback just because it seems easier.",
    "If the selected plugins cannot handle the request, say that clearly instead of silently doing the task another way."
  ].join("\n");
}

function computerUsePluginTurnGuidance(pluginIDs: string[]) {
  if (!shouldPreferCodexComputerUsePlugin(pluginIDs)) return "";
  return [
    "Computer Use is selected for this turn.",
    "If app metadata or an app mention is present in this turn, use that selected app with Computer Use instead of guessing another app.",
    "Call Computer Use directly for the named visible Mac app when the target is clear.",
    "If direct app access fails with an \"Invalid app\" error, retry once with the nearest app display name from app metadata. If it still fails, report the failed app name and ask the user to bring the app forward."
  ].join("\n");
}

function pluginSkillInputName(
  plugin: PluginItem,
  skill: { name?: string; displayName?: string }
) {
  const rawName = pluginString(skill.displayName, skill.name);
  if (!rawName) return plugin.title;
  const normalizedName = rawName.trim().toLowerCase();
  const normalizedPluginName = plugin.pluginName?.trim().toLowerCase();
  if (
    normalizedName.includes(":")
    || normalizedName === normalizedPluginName
    || (normalizedPluginName && normalizedName === `${normalizedPluginName}:${normalizedPluginName}`)
  ) {
    return plugin.title;
  }
  return rawName;
}

async function pluginSelectionGuidanceText(pluginIDs: string[]) {
  const canonicalIDs = canonicalizeCodexPluginIDs(pluginIDs);
  if (!canonicalIDs.length) return "";
  const normalizedIDs = new Set(canonicalIDs.map(normalizedCodexPluginID).filter((id): id is string => Boolean(id)));
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
  return [
    codexPluginSelectionContextText(plugins),
    computerUsePluginTurnGuidance(canonicalIDs)
  ].filter(Boolean).join("\n\n");
}

type PluginAppStatus = {
  id: string;
  name: string;
  isAccessible: boolean;
  isEnabled: boolean;
  pluginDisplayNames: string[];
};

let pluginAppStatusCache: { expiresAt: number; value: PluginAppStatus[] } | null = null;
let localMacApplicationNameCache: { expiresAt: number; value: string[] } | null = null;

type ComputerUseAppTarget = {
  name: string;
  appID?: string;
  aliases: string[];
  source: "codex-app-list" | "mac-applications";
};

function pluginBool(value: unknown, fallback: boolean) {
  if (typeof value === "boolean") return value;
  if (typeof value === "number") return value !== 0;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (["true", "yes", "1", "enabled"].includes(normalized)) return true;
    if (["false", "no", "0", "disabled"].includes(normalized)) return false;
  }
  return fallback;
}

function parsePluginAppStatuses(raw: unknown) {
  const payload = asObject(raw);
  const rawItems = Array.isArray(payload?.data)
    ? payload?.data
    : Array.isArray(payload?.apps)
      ? payload?.apps
      : Array.isArray(raw)
        ? raw
        : [];
  const items = rawItems
    .map(asObject)
    .filter(Boolean)
    .map((item) => {
      const id = pluginString(item?.id, item?.connectorId, item?.name) ?? "";
      const name = pluginString(item?.name, item?.displayName, item?.id) ?? id;
      const pluginDisplayNames = Array.isArray(item?.pluginDisplayNames)
        ? item.pluginDisplayNames.map(String).map((value) => value.trim()).filter(Boolean)
        : [];
      return {
        id,
        name: titleFromSkill(name),
        isAccessible: pluginBool(item?.isAccessible, false),
        isEnabled: pluginBool(item?.isEnabled, true),
        pluginDisplayNames
      } satisfies PluginAppStatus;
    })
    .filter((item) => item.id && item.name);
  return {
    items,
    nextCursor: pluginString(payload?.nextCursor)
  };
}

async function listPluginAppStatuses() {
  const now = Date.now();
  if (pluginAppStatusCache && pluginAppStatusCache.expiresAt > now) {
    return pluginAppStatusCache.value;
  }
  const apps: PluginAppStatus[] = [];
  const seen = new Set<string>();
  let cursor: string | undefined;
  for (let page = 0; page < 8; page += 1) {
    const response = await withTimeout(
      codexTransport.request("app/list", cursor ? { cursor } : {}),
      8_000
    );
    const parsed = parsePluginAppStatuses(response);
    for (const app of parsed.items) {
      const key = app.id.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      apps.push(app);
    }
    if (!parsed.nextCursor) break;
    cursor = parsed.nextCursor;
  }
  pluginAppStatusCache = {
    expiresAt: Date.now() + 30_000,
    value: apps
  };
  bridgeDebugLog(`Codex app/list returned ${apps.length} app status item(s).`);
  return apps;
}

function promptContainsStandalonePhrase(phrase: string, prompt: string) {
  const trimmed = phrase.trim();
  if (!trimmed) return false;
  const escaped = trimmed.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(^|[^A-Za-z0-9])${escaped}([^A-Za-z0-9]|$)`, "i").test(prompt);
}

function appMatchedAliases(app: Pick<PluginAppStatus, "id" | "name">, prompt: string) {
  const appName = app.name.trim().toLowerCase();
  return appMatchCandidates(app)
    .filter((candidate) => promptContainsStandalonePhrase(candidate, prompt))
    .filter((candidate) => candidate.trim().toLowerCase() !== appName);
}

function appMatchCandidates(app: Pick<PluginAppStatus, "id" | "name">) {
  const rawCandidates = [
    app.name,
    app.id,
    app.id.replace(/[._-]+/g, " ")
  ];
  const loweredName = app.name.toLowerCase();
  for (const prefix of ["microsoft ", "google ", "apple "]) {
    if (loweredName.startsWith(prefix)) rawCandidates.push(app.name.slice(prefix.length));
  }
  for (const suffix of [" browser", " app", " application"]) {
    if (loweredName.endsWith(suffix) && app.name.length > suffix.length) {
      rawCandidates.push(app.name.slice(0, -suffix.length));
    }
  }
  const idTokens = app.id
    .split(/[._\-\s]+/g)
    .map((token) => token.trim())
    .filter(Boolean);
  const genericIDTokens = new Set(["app", "application", "browser", "com", "helper", "mac", "macos", "osx"]);
  for (const token of idTokens) {
    const key = token.toLowerCase();
    if (key.length >= 3 && !genericIDTokens.has(key)) {
      rawCandidates.push(token);
    }
  }
  const seen = new Set<string>();
  return rawCandidates
    .map((value) => value.trim())
    .filter(Boolean)
    .filter((value) => {
      const key = value.toLowerCase();
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .sort((a, b) => b.length - a.length || a.localeCompare(b));
}

function collectLocalAppBundleNames(root: string, depth = 0): string[] {
  if (depth > 3 || !fs.existsSync(root)) return [];
  const names: string[] = [];
  let entries: fs.Dirent[] = [];
  try {
    entries = fs.readdirSync(root, { withFileTypes: true });
  } catch {
    return names;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const fullPath = path.join(root, entry.name);
    if (entry.name.endsWith(".app")) {
      names.push(entry.name.replace(/\.app$/i, ""));
      continue;
    }
    names.push(...collectLocalAppBundleNames(fullPath, depth + 1));
  }
  return names;
}

function localMacApplicationNames() {
  const now = Date.now();
  if (localMacApplicationNameCache && localMacApplicationNameCache.expiresAt > now) {
    return localMacApplicationNameCache.value;
  }
  const roots = [
    "/Applications",
    "/System/Applications",
    path.join(os.homedir(), "Applications")
  ];
  const seen = new Set<string>();
  const value = roots
    .flatMap((root) => collectLocalAppBundleNames(root))
    .map((name) => name.trim())
    .filter(Boolean)
    .filter((name) => {
      const key = name.toLowerCase();
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  localMacApplicationNameCache = { expiresAt: now + 120_000, value };
  return value;
}

function localComputerUseAppTargets(prompt: string): ComputerUseAppTarget[] {
  const promptText = prompt.trim();
  if (!promptText) return [];
  return localMacApplicationNames()
    .map((name) => {
      const aliases = appMatchedAliases({ id: name, name }, promptText);
      return { name, aliases };
    })
    .filter((target) => promptContainsStandalonePhrase(target.name, promptText) || target.aliases.length > 0)
    .map((target) => ({
      name: target.name,
      aliases: target.aliases,
      source: "mac-applications" as const
    }))
    .sort((a, b) => b.name.length - a.name.length || a.name.localeCompare(b.name))
    .slice(0, 3);
}

function mergeComputerUseAppTargets(targets: ComputerUseAppTarget[]) {
  const merged = new Map<string, ComputerUseAppTarget>();
  for (const target of targets) {
    const name = target.name.trim();
    if (!name) continue;
    const key = name.toLowerCase();
    const existing = merged.get(key);
    if (!existing) {
      merged.set(key, {
        ...target,
        name,
        aliases: Array.from(new Set(target.aliases.map((alias) => alias.trim()).filter(Boolean)))
      });
      continue;
    }
    existing.appID ||= target.appID;
    existing.aliases = Array.from(new Set([...existing.aliases, ...target.aliases].map((alias) => alias.trim()).filter(Boolean)));
    if (existing.source !== "codex-app-list" && target.source === "codex-app-list") {
      existing.source = target.source;
    }
  }
  return Array.from(merged.values());
}

function computerUseTargetAppGuidance(pluginIDs: string[], targets: ComputerUseAppTarget[]) {
  if (!shouldPreferCodexComputerUsePlugin(pluginIDs) || !targets.length) return "";
  const lines = targets.slice(0, 3).map((target) => {
    const aliases = target.aliases.length
      ? ` Matched user wording: ${target.aliases.map((alias) => `"${alias}"`).join(", ")}.`
      : "";
    const id = target.appID ? ` App mention path: app://${target.appID}.` : "";
    return `- Use app: "${target.name}".${aliases}${id}`;
  });
  return [
    "Resolved Computer Use target app from installed app metadata:",
    lines.join("\n"),
    "Use the exact app display name above in Computer Use tool arguments.",
    "Do not pass the shorter wording from the user prompt when an exact app display name is listed.",
    "Do not call list_apps only to resolve an app target already listed here."
  ].join("\n");
}

function appStatusBelongsToPlugin(
  status: PluginAppStatus,
  plugin: PluginItem,
  detailApps: Array<{ id: string; name: string }>
) {
  if (shouldPreferCodexComputerUsePlugin([plugin.id])) {
    return true;
  }
  if (detailApps.some((app) =>
    app.id.localeCompare(status.id, undefined, { sensitivity: "accent" }) === 0
    || app.name.localeCompare(status.name, undefined, { sensitivity: "accent" }) === 0
  )) {
    return true;
  }
  return status.pluginDisplayNames.some((name) =>
    name.localeCompare(plugin.title, undefined, { sensitivity: "accent" }) === 0
    || (plugin.pluginName ? name.localeCompare(plugin.pluginName, undefined, { sensitivity: "accent" }) === 0 : false)
  );
}

function matchingPluginAppStatuses(
  plugin: PluginItem,
  prompt: string,
  detailApps: Array<{ id: string; name: string }>,
  appStatuses: PluginAppStatus[]
) {
  const promptText = prompt.trim();
  if (!promptText) return [];
  const accessible = appStatuses.filter((status) =>
    status.isAccessible
    && status.isEnabled
    && appStatusBelongsToPlugin(status, plugin, detailApps)
  );
  return accessible
    .filter((status) => appMatchCandidates(status).some((candidate) => promptContainsStandalonePhrase(candidate, promptText)))
    .sort((a, b) => b.name.length - a.name.length || a.name.localeCompare(b.name))
    .slice(0, 3);
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
      await writeCloudTranscriptionProviderSelection(nextProvider, true);
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
  const currentProvider = await readDefault("OpenAssist.cloudTranscriptionProvider", "OpenAI");
  await writeCloudTranscriptionProviderSelection(provider, currentProvider !== provider);
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
  const currentProvider = await readDefault("OpenAssist.cloudTranscriptionProvider", "OpenAI");
  await writeCloudTranscriptionProviderSelection(provider, currentProvider !== provider);
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
    await cleanupOpenAssistOwnedCodexAppServers(undefined, "Clean stale OpenAssist Codex app-servers before Codex start").catch((error) => {
      bridgeDebugLog(`OpenAssist Codex app-server pre-start cleanup failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
    });
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
      "realtime.type=\"conversational\"",
      // OpenAssist owns the turn lifecycle; do not inherit user-level Codex
      // notify hooks that can launch stale Computer Use helpers after a turn.
      "-c",
      "notify=[]"
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
      RUST_LOG: process.env.RUST_LOG ?? "warn",
      // When Codex (and the SkyComputerUseClient MCP helper it spawns) runs
      // with stdout piped to us instead of a TTY, libc switches to fully
      // buffered mode. Small JSON-RPC replies (e.g. get_app_state) sit in
      // the child's stdout buffer until it fills, and the parent's read
      // hangs forever. See openai/codex#23840. These env vars ask the
      // Foundation/Python/coreutils stacks to keep line buffering.
      NSUnbufferedIO: process.env.NSUnbufferedIO ?? "YES",
      PYTHONUNBUFFERED: process.env.PYTHONUNBUFFERED ?? "1",
      STDBUF: process.env.STDBUF ?? "L"
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
      clearActiveComputerUseToolCalls("Codex App Server exited");
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

  currentPID() {
    const pid = this.process?.pid;
    return typeof pid === "number" && Number.isFinite(pid) ? pid : undefined;
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
    clearActiveComputerUseToolCalls(reason);
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
  processPID?: number;
  terminateProcess?: (reason: string) => Promise<void>;
  turnID?: string;
  stopped?: boolean;
  rejectStop?: (error: Error) => void;
  emitStatus?: (text: string) => void;
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
  if (run.backend === "codex") {
    try {
      await interruptCodexRun(run, 5_000);
    } catch (error) {
      interruptError = error instanceof Error ? error.message : "Could not interrupt the active turn.";
    }
  } else if (run.terminateProcess) {
    await run.terminateProcess("user stopped turn");
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
  options: {
    threadID?: string;
    provider?: string;
    interactionMode?: string;
    permissionMode?: string;
    reasoningEffort?: string;
    pluginIDs?: string[];
    skillIDs?: string[];
  } = {},
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
  const normalizedToolSelection = await normalizeCodexToolSelection(options.pluginIDs ?? [], options.skillIDs ?? []);
  const realtimeRuntimeOptions: CodexRuntimeOptions = {
    interactionMode: options.interactionMode ?? session.latestInteractionMode ?? "agentic",
    permissionMode: options.permissionMode ?? session.latestPermissionMode ?? "fullAccess",
    reasoningEffort: normalizeCodexReasoningEffort(options.reasoningEffort ?? session.latestReasoningEffort),
    pluginIDs: normalizedToolSelection.pluginIDs
  };
  let providerThreadID: string;
  let insertedSystemMessage = false;
  try {
    if (shouldPreferCodexComputerUsePlugin(realtimeRuntimeOptions.pluginIDs)) {
      const didResetActiveComputerUse = await resetCodexIfComputerUseAlreadyActive("Reset stale active Computer Use tool before starting Live Voice");
      if (didResetActiveComputerUse) {
        bridgeDebugLog("[realtime.voice] reset active Computer Use before realtime start");
      }
      const didResetExistingHelper = await resetCodexIfCurrentComputerUseHelperExists("Reset existing Computer Use helper before starting Live Voice");
      if (didResetExistingHelper) {
        bridgeDebugLog("[realtime.voice] reset existing Computer Use helper before realtime start");
      }
      await cleanupStaleComputerUseHelpers(codexTransport.currentPID()).catch((error) => {
        bridgeDebugLog(`[realtime.voice] Computer Use stale helper cleanup failed: ${error instanceof Error ? error.message : String(error)}`);
      });
    }
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
    const realtimeStartPrompt = [
      "Start a live voice session for this OpenAssist Codex thread.",
      await pluginSelectionGuidanceText(realtimeRuntimeOptions.pluginIDs ?? [])
    ].filter(Boolean).join("\n\n");
    bridgeDebugLog(`[realtime.voice] sending thread/realtime/start providerThread=${providerThreadID}`);
    await liveVoiceStartTimeout(Promise.race([
      codexTransport.request("thread/realtime/start", {
        threadId: providerThreadID,
        outputModality: "audio",
        transport: { type: "websocket" },
        voice: settings.realtimeOpenAIVoice || defaultRealtimeOpenAIVoice,
        prompt: realtimeStartPrompt
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
const computerUseToolNames = new Set([
  "get_app_state",
  "list_apps",
  "click",
  "double_click",
  "right_click",
  "type_text",
  "set_value",
  "scroll",
  "press_key"
]);
const activeComputerUseToolCalls = new Map<string, {
  startMs: number;
  toolName: string;
  args: string;
}>();
const computerUseLongRunningLastLogAt = new Map<string, number>();

function compactArgsForLog(value: unknown): string {
  if (value == null) return "";
  try {
    const text = typeof value === "string" ? value : JSON.stringify(value);
    return text.length > 200 ? `${text.slice(0, 197)}...` : text;
  } catch {
    return String(value);
  }
}

function isComputerUseRuntimeToolCall(toolName: string, params: JsonObject, item: JsonObject) {
  const normalizedToolName = toolName.trim().toLowerCase();
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
  return serverName.includes("computer-use") || computerUseToolNames.has(normalizedToolName);
}

function clearActiveComputerUseToolCalls(reason: string) {
  if (!activeComputerUseToolCalls.size) return;
  const details = Array.from(activeComputerUseToolCalls.entries())
    .map(([callID, call]) => `${callID}:${call.toolName}:${Date.now() - call.startMs}ms`)
    .join(",");
  bridgeDebugLog(`clearing active Computer Use tool calls reason="${reason}" details=${details}`);
  activeComputerUseToolCalls.clear();
  computerUseLongRunningLastLogAt.clear();
}

function activeComputerUseToolCallDetails() {
  const now = Date.now();
  return Array.from(activeComputerUseToolCalls.entries()).map(([callID, call]) => ({
    callID,
    ...call,
    elapsedMs: now - call.startMs
  }));
}

async function resetCodexIfComputerUseAlreadyActive(reason: string) {
  const activeCalls = activeComputerUseToolCallDetails();
  if (!activeCalls.length) return false;
  bridgeDebugLog(`Computer Use active before new turn; restarting Codex reason="${reason}" details=${activeCalls.map((call) => `${call.callID}:${call.toolName}:${call.elapsedMs}ms`).join(",")}`);
  await codexTransport.restart(reason);
  clearActiveComputerUseToolCalls(reason);
  await cleanupStaleComputerUseHelpers(undefined, { allowDuringActiveToolCall: true }).catch((error) => {
    bridgeDebugLog(`Computer Use cleanup after restart failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
  });
  return true;
}

const COMPUTER_USE_LONG_RUNNING_LOG_MS = (() => {
  const raw = Number(process.env.OPENASSIST_COMPUTER_USE_LONG_RUNNING_LOG_MS);
  return Number.isFinite(raw) && raw >= 30_000 ? raw : 120_000;
})();
const COMPUTER_USE_LONG_RUNNING_POLL_MS = 15_000;
const COMPUTER_USE_LONG_RUNNING_REPEAT_MS = 60_000;

const computerUseLongRunningMonitor = setInterval(() => {
  if (!activeComputerUseToolCalls.size) return;
  const now = Date.now();
  for (const call of activeComputerUseToolCallDetails()) {
    if (call.elapsedMs < COMPUTER_USE_LONG_RUNNING_LOG_MS) continue;
    const lastLogAt = computerUseLongRunningLastLogAt.get(call.callID) ?? 0;
    if (now - lastLogAt < COMPUTER_USE_LONG_RUNNING_REPEAT_MS) continue;
    computerUseLongRunningLastLogAt.set(call.callID, now);
    bridgeDebugLog(
      `Computer Use tool call still running; leaving Codex active callID=${call.callID} tool="${call.toolName}" elapsedMs=${call.elapsedMs} args=${call.args}`
    );
  }
}, COMPUTER_USE_LONG_RUNNING_POLL_MS);
computerUseLongRunningMonitor.unref?.();

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
  const computerUseTool = isComputerUseRuntimeToolCall(toolName, params, item);
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
    if (computerUseTool) {
      activeComputerUseToolCalls.set(callID, { startMs: Date.now(), toolName, args: argsCompact });
      bridgeDebugLog(`Computer Use tool call active callID=${callID} tool="${toolName}" args=${argsCompact}`);
    }
    return;
  }
  if (isEnd) {
    const start = codexToolCallStartTimes.get(callID);
    if (start) {
      const elapsedMs = Date.now() - start.startMs;
      const resolvedStatus = status || (lowerMethod.endsWith("/failed") ? "failed" : "completed");
      bridgeDebugLog(`codex tool call end tool="${start.toolName}" callID=${callID} status=${resolvedStatus} elapsedMs=${elapsedMs}`);
      codexToolCallStartTimes.delete(callID);
      if (activeComputerUseToolCalls.delete(callID)) {
        computerUseLongRunningLastLogAt.delete(callID);
        bridgeDebugLog(`Computer Use tool call cleared callID=${callID} status=${resolvedStatus} elapsedMs=${elapsedMs}`);
      }
    } else if (looksLikeToolCall) {
      const resolvedStatus = status || (lowerMethod.endsWith("/failed") ? "failed" : "completed");
      bridgeDebugLog(`codex tool call end tool="${toolName}" callID=${callID} method=${method} type=${itemType} status=${resolvedStatus} elapsedMs=unknown`);
      if (activeComputerUseToolCalls.delete(callID)) {
        computerUseLongRunningLastLogAt.delete(callID);
        bridgeDebugLog(`Computer Use tool call cleared callID=${callID} status=${resolvedStatus} elapsedMs=unknown`);
      }
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
  if (backend === "antigravityCLI") {
    try {
      await refreshAntigravityUsageFromState();
    } catch {
      usageSnapshotForBackend("antigravityCLI");
    }
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
  if (lowered === "antigravity" || lowered === "antigravitycli" || lowered === "googleantigravity" || lowered === "agy") return "antigravityCLI";
  if (lowered === "ollama" || lowered === "ollamalocal" || lowered === "ollama (local)") return "ollamaLocal";
  return "codex";
}

const runtimeBackendOrder: RuntimeAssistantBackend[] = ["codex", "copilot", "claudeCode", "antigravityCLI", "ollamaLocal"];
const runtimeBackendExecutable: Record<RuntimeAssistantBackend, string> = {
  codex: "codex",
  claudeCode: "claude",
  antigravityCLI: "agy",
  copilot: "copilot",
  ollamaLocal: "ollama"
};

function isRuntimeBackend(backend: AssistantBackend): backend is RuntimeAssistantBackend {
  return backend === "codex" || backend === "copilot" || backend === "claudeCode" || backend === "antigravityCLI" || backend === "ollamaLocal";
}

function assistantPATH() {
  const additions = [
    path.join(os.homedir(), ".npm-global/bin"),
    path.join(os.homedir(), ".local/bin"),
    path.join(os.homedir(), "Library", "Application Support", "Antigravity", "bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin"
  ];
  return [process.env.PATH, ...additions].filter(Boolean).join(path.delimiter);
}

const antigravityCLIInstallCommand = "curl -fsSL https://antigravity.google/cli/install.sh | bash";

function antigravityCLIExecutableCandidates() {
  return [
    path.join(os.homedir(), ".local/bin", "agy"),
    path.join(os.homedir(), ".npm-global/bin", "agy"),
    path.join(os.homedir(), "Library", "Application Support", "Antigravity", "bin", "agy"),
    "/opt/homebrew/bin/agy",
    "/usr/local/bin/agy",
    "/usr/bin/agy"
  ];
}

function executableFileExists(filePath: string) {
  try {
    fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

async function resolveExecutablePath(executable: string) {
  if (executable === "agy") {
    const direct = antigravityCLIExecutableCandidates().find(executableFileExists);
    if (direct) return direct;
  }
  try {
    const { stdout } = await execFileAsync("/usr/bin/env", ["which", executable], {
      env: { ...process.env, PATH: assistantPATH() }
    });
    return stdout.trim() || null;
  } catch {
    return null;
  }
}

async function executableExists(executable: string) {
  return Boolean(await resolveExecutablePath(executable));
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
      backend === "antigravityCLI"
        ? `Antigravity CLI was not found. Install it with: ${antigravityCLIInstallCommand}`
        : `${runtimeBackendExecutable[backend]} was not found on PATH.`,
      "warning",
      backend === "antigravityCLI" ? antigravityCLIInstallCommand : `Install ${runtimeBackendExecutable[backend]}`
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
  } else if (backend === "antigravityCLI") {
    value = {
      assistantRuntimeStatus: "Runtime detected",
      assistantRuntimeDetail: "Antigravity CLI is installed. Run agy in Terminal if Google sign-in is needed.",
      assistantRuntimeAccount: "Handled by Antigravity CLI",
      assistantRuntimeAuthMode: "Google Antigravity subscription",
      assistantRuntimeLoginCommand: "agy",
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
  if (backend === "antigravityCLI") return "Started a new Antigravity thread.";
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

function timelineAssistantFinal(
  threadID: string,
  text: string,
  backend: AssistantBackend,
  modelID: string,
  turnID: string,
  createdAt: number,
  id = `assistant-final-${makeID()}`,
  checkpointReferences: string[] = [],
  artifacts: MessageArtifact[] = []
): JsonObject {
  return {
    id,
    kind: "assistantFinal",
    sessionID: threadID,
    source: "runtime",
    text,
    emphasis: false,
    isStreaming: false,
    providerBackend: backend,
    providerModelID: modelID,
    turnID,
    checkpointReferences,
    artifacts,
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

function imageMimeTypeFromFile(filePath?: string) {
  const resolved = filePath?.trim();
  if (!resolved || !fs.existsSync(resolved)) return imageMimeTypeFromPath(resolved);
  try {
    const header = fs.readFileSync(resolved).subarray(0, 12);
    if (header[0] === 0xff && header[1] === 0xd8) return "image/jpeg";
    if (header.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
    if (header.subarray(0, 4).toString("ascii") === "GIF8") return "image/gif";
    if (header.subarray(0, 4).toString("ascii") === "RIFF" && header.subarray(8, 12).toString("ascii") === "WEBP") return "image/webp";
  } catch {
    // Fall back to the extension below.
  }
  return imageMimeTypeFromPath(resolved);
}

function jpegDimensions(buffer: Buffer) {
  let offset = 2;
  while (offset + 9 < buffer.length) {
    if (buffer[offset] !== 0xff) {
      offset += 1;
      continue;
    }
    const marker = buffer[offset + 1];
    const length = buffer.readUInt16BE(offset + 2);
    if (length < 2) return null;
    const isStartOfFrame = (marker >= 0xc0 && marker <= 0xc3)
      || (marker >= 0xc5 && marker <= 0xc7)
      || (marker >= 0xc9 && marker <= 0xcb)
      || (marker >= 0xcd && marker <= 0xcf);
    if (isStartOfFrame && offset + 8 < buffer.length) {
      return {
        width: buffer.readUInt16BE(offset + 7),
        height: buffer.readUInt16BE(offset + 5)
      };
    }
    offset += 2 + length;
  }
  return null;
}

function imageDimensionsFromFile(filePath?: string): { width?: number; height?: number } {
  const resolved = filePath?.trim();
  if (!resolved || !fs.existsSync(resolved)) return {};
  try {
    const buffer = fs.readFileSync(resolved).subarray(0, 512 * 1024);
    if (buffer.length >= 24 && buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
      return {
        width: buffer.readUInt32BE(16),
        height: buffer.readUInt32BE(20)
      };
    }
    if (buffer.length >= 10 && buffer[0] === 0xff && buffer[1] === 0xd8) {
      return jpegDimensions(buffer) ?? {};
    }
  } catch {
    // Dimensions are helpful metadata only; do not block artifact display.
  }
  return {};
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

function isImageArtifactPath(filePath: string) {
  return /\.(png|jpe?g|webp|gif)$/i.test(filePath);
}

function normalizeArtifactPath(rawPath: string) {
  let filePath = rawPath.trim().replace(/^file:\/\//i, "");
  filePath = filePath.replace(/[)\].,;:]+$/g, "");
  if (filePath.startsWith("~")) filePath = path.join(os.homedir(), filePath.slice(1));
  try {
    filePath = decodeURI(filePath);
  } catch {
    // Keep the original path if it is not URI-encoded.
  }
  return path.resolve(filePath);
}

function messageArtifactFromPath(rawPath: string): MessageArtifact | null {
  const filePath = normalizeArtifactPath(rawPath);
  if (!fs.existsSync(filePath)) return null;
  const stat = fs.statSync(filePath);
  if (!stat.isFile()) return null;
  const isImage = isImageArtifactPath(filePath);
  const mimeType = isImage ? imageMimeTypeFromFile(filePath) : undefined;
  const dimensions = isImage ? imageDimensionsFromFile(filePath) : {};
  return {
    id: `artifact-${Buffer.from(filePath).toString("base64url").slice(0, 48)}`,
    kind: isImage ? "image" : "file",
    name: path.basename(filePath),
    path: filePath,
    mimeType,
    dataURL: isImage ? imageDataURLFromFile(filePath, mimeType) : undefined,
    size: stat.size,
    width: dimensions.width,
    height: dimensions.height
  };
}

function uniqueArtifacts(artifacts: MessageArtifact[]) {
  const seen = new Set<string>();
  const result: MessageArtifact[] = [];
  for (const artifact of artifacts) {
    if (seen.has(artifact.path)) continue;
    seen.add(artifact.path);
    result.push(artifact);
  }
  return result;
}

function artifactPathsFromText(value: string) {
  const paths: string[] = [];
  const text = value.replace(/\r/g, "\n");
  const pathPattern = /(?:file:\/\/)?(\/(?:Users|Volumes|private|var|tmp)\/[^\n\r`"']+?\.(?:png|jpe?g|webp|gif|svg|pdf|html?|mp4|mov|txt|md|csv|json))/gi;
  for (const match of text.matchAll(pathPattern)) {
    if (match[1]) paths.push(match[1]);
  }
  return paths;
}

function messageArtifactsFromText(value: string) {
  return uniqueArtifacts(
    artifactPathsFromText(value)
      .map(messageArtifactFromPath)
      .filter((artifact): artifact is MessageArtifact => Boolean(artifact))
  );
}

function messageArtifactsFromStored(value: unknown) {
  if (!Array.isArray(value)) return [];
  return uniqueArtifacts(value
    .map((raw) => {
      const object = asObject(raw);
      if (!object) return null;
      const artifactPath = firstRuntimeString(object.path, object.filePath, object.file_path);
      if (!artifactPath) return null;
      const fromDisk = messageArtifactFromPath(artifactPath);
      if (fromDisk) return fromDisk;
      const name = firstRuntimeString(object.name) || path.basename(artifactPath);
      const kind = String(object.kind ?? "").toLowerCase() === "image" ? "image" : "file";
      return {
        id: firstRuntimeString(object.id) || `artifact-${Buffer.from(artifactPath).toString("base64url").slice(0, 48)}`,
        kind,
        name,
        path: artifactPath,
        mimeType: firstRuntimeString(object.mimeType, object.mime_type) || undefined,
        dataURL: firstRawRuntimeString(object.dataURL, object.data_url) || undefined,
        size: Number.isFinite(Number(object.size)) ? Number(object.size) : undefined,
        width: Number.isFinite(Number(object.width)) ? Number(object.width) : undefined,
        height: Number.isFinite(Number(object.height)) ? Number(object.height) : undefined
      } satisfies MessageArtifact;
    })
    .filter((artifact): artifact is MessageArtifact => Boolean(artifact)));
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
      artifacts: activity.artifacts,
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
  assistantMessageID,
  checkpointReferences = [],
  assistantArtifacts = [],
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
  assistantMessageID?: string;
  checkpointReferences?: string[];
  assistantArtifacts?: MessageArtifact[];
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
  const turnCheckpointReferences = [...checkpointReferences];
  const assistantTimeline = timelineAssistantFinal(
    threadID,
    responseText,
    backend,
    modelID,
    providerTurnID,
    assistantCreatedAt,
    assistantMessageID,
    turnCheckpointReferences,
    assistantArtifacts
  );
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
    checkpointReferences: turnCheckpointReferences
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
  notifyThreadsChanged();
  return {
    session: updatedSession,
    thread,
    title: thread.title,
    assistantMessageID: String(assistantTimeline.id ?? "")
  };
}

async function ensureCodexProviderSession(threadID: string, modelID: string, options: CodexRuntimeOptions = {}) {
  const session = findSession(threadID) ?? ensureOpenAssistSessionRecord(threadID, "codex", modelID);
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
  return sessionWorkingDirectory(session) || openAssistRepoRoot();
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

async function execCaptured(
  command: string,
  args: string[],
  cwd: string,
  timeoutMs = 180_000,
  run?: ActiveProviderRun,
  failFast?: (stdout: string, stderr: string) => Error | null,
  onOutput?: CapturedOutputHandler
) {
  return new Promise<{ stdout: string; stderr: string }>((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: { ...process.env, PATH: assistantPATH() },
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";
    let forcedError: Error | null = null;
    let settled = false;
    const commandLabel = path.basename(command);
    const terminateWithError = (error: Error, reason: string) => {
      if (forcedError) return;
      Object.assign(error, { stdout, stderr });
      forcedError = error;
      clearTimeout(timer);
      if (child.pid) {
        void terminateProcessTree(child.pid, reason);
      } else {
        child.kill("SIGTERM");
      }
    };
    const clearRunProcess = () => {
      if (run && run.processPID === child.pid) {
        run.processPID = undefined;
        run.terminateProcess = undefined;
      }
    };
    const timer = setTimeout(() => {
      const error = new Error(`${commandLabel} timed out.`);
      terminateWithError(error, `${commandLabel} timed out`);
    }, timeoutMs);
    if (run && child.pid) {
      run.processPID = child.pid;
      run.terminateProcess = async (reason: string) => {
        const error = new ProviderRunStoppedError(run.provider);
        Object.assign(error, { stdout, stderr });
        forcedError = error;
        clearTimeout(timer);
        await terminateProcessTree(child.pid!, `${commandLabel}: ${reason}`);
      };
    }
    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => {
      const text = String(chunk);
      stdout += text;
      if (stdout.length > 8_000_000) stdout = stdout.slice(-4_000_000);
      onOutput?.("stdout", text, stdout, stderr);
      const error = failFast?.(stdout, stderr);
      if (error) terminateWithError(error, `${commandLabel} output matched fail-fast condition`);
    });
    child.stderr?.on("data", (chunk) => {
      const text = String(chunk);
      stderr += text;
      if (stderr.length > 2_000_000) stderr = stderr.slice(-1_000_000);
      onOutput?.("stderr", text, stdout, stderr);
      const error = failFast?.(stdout, stderr);
      if (error) terminateWithError(error, `${commandLabel} output matched fail-fast condition`);
    });
    child.on("error", (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearRunProcess();
      Object.assign(error, { stdout, stderr });
      reject(error);
    });
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearRunProcess();
      if (forcedError) {
        Object.assign(forcedError, { stdout, stderr });
        reject(forcedError);
        return;
      }
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

function isAntigravityProgressText(value: string) {
  const normalized = value.replace(/\s+/g, " ").trim().toLowerCase();
  if (!normalized) return true;
  return normalized.includes("no tool calls made in this turn")
    && normalized.includes("waiting for background task updates");
}

function antigravityTimedOut(value: string) {
  return /error:\s*timed out waiting for response/i.test(value);
}

function antigravityAuthRequired(value: string) {
  return /authentication required/i.test(value)
    || /authentication timed out/i.test(value)
    || /accounts\.google\.com\/o\/oauth2/i.test(value)
    || /paste the authorization code/i.test(value);
}

function antigravityAuthRequiredMessage() {
  return "Antigravity CLI needs Google sign-in. Run `agy` in Terminal, finish the Google login, then try again in OpenAssist.";
}

function cleanAntigravityText(value: string) {
  let text = value.replace(/\r/g, "").trim();
  text = text.replace(/^message:[a-z0-9-]+/i, "").trim();
  const taskMarker = text.match(/\/task-\s*/);
  if (taskMarker?.index != null) {
    text = text.slice(taskMarker.index + taskMarker[0].length).trim();
  }
  text = text
    .replace(/^\{?Status:[\s\S]*?\/task-\s*/i, "")
    .replace(/\n?}\s*$/g, "")
    .trim();
  return text;
}

function antigravityTaskStatusText(stdout: string, stderr: string) {
  const source = `${stdout}\n${stderr}`.replace(/\r/g, "");
  const eventStart = source.lastIndexOf("message:task-status-changed");
  if (eventStart < 0) return "";
  const eventText = source.slice(eventStart);
  const taskMarker = eventText.match(/\/task-\s*/);
  if (!taskMarker?.index) return "";
  let text = eventText.slice(taskMarker.index + taskMarker[0].length);
  const nextEvent = text.search(/\nmessage:[a-z0-9-]+/i);
  if (nextEvent >= 0) text = text.slice(0, nextEvent);
  return cleanAntigravityText(text);
}

function antigravityCLIText(stdout: string, stderr: string) {
  if (antigravityAuthRequired(`${stdout}\n${stderr}`)) return "";
  const taskText = antigravityTaskStatusText(stdout, stderr);
  if (taskText && !isAntigravityProgressText(taskText) && !antigravityTimedOut(taskText)) return taskText;
  const lines = `${stdout}\n${stderr}`
    .split(/\r?\n/)
    .map(cleanAntigravityText)
    .filter((line) => line && !isAntigravityProgressText(line) && !antigravityTimedOut(line));
  return lines.join("\n").trim();
}

function providerCLIText(stdout: string, stderr: string, backend?: RuntimeAssistantBackend) {
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
  if (backend === "antigravityCLI") {
    const antigravityText = antigravityCLIText(stdout, stderr);
    if (antigravityText) return antigravityText;
    return "";
  }
  const plain = stdout.trim();
  if (plain) return plain;
  return stderr.trim();
}

function providerCLIJSONObjects(stdout: string, stderr: string): JsonObject[] {
  const objects: JsonObject[] = [];
  for (const line of `${stdout}\n${stderr}`.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) continue;
    try {
      const parsed = JSON.parse(trimmed);
      if (Array.isArray(parsed)) {
        objects.push(...parsed.map(asObject).filter(Boolean) as JsonObject[]);
      } else {
        const object = asObject(parsed);
        if (object) objects.push(object);
      }
    } catch {
      // Keep reading; provider CLIs can mix JSON metadata with plain progress text.
    }
  }
  return objects;
}

function recordUsageFromProviderCLIOutput(backend: RuntimeAssistantBackend, stdout: string, stderr: string) {
  for (const object of providerCLIJSONObjects(stdout, stderr)) {
    const metadata = asObject(object.metadata) ?? asObject(object.meta) ?? {};
    const stats = asObject(object.stats) ?? asObject(object.metrics) ?? {};
    const usage = object.tokenUsage
      ?? object.token_usage
      ?? object.usage
      ?? metadata.tokenUsage
      ?? metadata.token_usage
      ?? metadata.usage
      ?? stats.tokenUsage
      ?? stats.token_usage
      ?? stats.usage;
    if (usage) recordTokenUsage(backend, usage);

    const rateLimits = object.rateLimits
      ?? object.rate_limits
      ?? metadata.rateLimits
      ?? metadata.rate_limits
      ?? stats.rateLimits
      ?? stats.rate_limits;
    if (rateLimits) recordRateLimits(backend, { rateLimits });
  }
}

async function sendCopilotMessage(
  providerSessionID: string,
  session: SessionSummary | undefined,
  prompt: string,
  modelID: string,
  run?: ActiveProviderRun
) {
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
  const { stdout, stderr } = await execCaptured("copilot", args, providerWorkingDirectory(session), undefined, run);
  return providerCLIText(stdout, stderr) || "GitHub Copilot completed without a text response.";
}

async function sendClaudeCodeMessage(
  providerSessionID: string,
  session: SessionSummary | undefined,
  prompt: string,
  modelID: string,
  isNewSession: boolean,
  run?: ActiveProviderRun
) {
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
  const { stdout, stderr } = await execCaptured("claude", args, providerWorkingDirectory(session), undefined, run);
  return providerCLIText(stdout, stderr) || "Claude Code completed without a text response.";
}

function promptWithSessionInstructions(prompt: string, sessionInstructions?: string) {
  const instructions = sessionInstructions?.trim();
  if (!instructions) return prompt;
  return `Session instructions for this chat:\n${instructions}\n\nUser task:\n${prompt}`;
}

function promptWithRecentConversationContext(threadID: string, prompt: string) {
  const snapshot = readConversationSnapshot(threadID);
  const context = (snapshot.transcript ?? [])
    .filter((entry) => entry.role === "user" || entry.role === "assistant")
    .map((entry) => {
      const role = entry.role === "assistant" ? "Assistant" : "User";
      const text = String(entry.text ?? "").replace(/\s+/g, " ").trim();
      return text ? `${role}: ${text}` : "";
    })
    .filter(Boolean)
    .slice(-12)
    .join("\n");
  if (!context) return prompt;
  return `Conversation context from this Open Assist chat:\n${context}\n\nCurrent user task:\n${prompt}`;
}

function isSimpleChatPrompt(prompt: string) {
  const normalized = prompt
    .trim()
    .toLowerCase()
    .replace(/[!.?\s]+$/g, "")
    .replace(/\s+/g, " ");
  return [
    "hi",
    "hello",
    "hey",
    "yo",
    "ok",
    "okay",
    "thanks",
    "thank you",
    "hmm",
    "mmh",
    "test"
  ].includes(normalized);
}

function looksLikeImageArtifactTask(prompt: string) {
  const normalized = prompt.toLowerCase();
  const mentionsImage = /\b(image|photo|picture|screenshot|thumbnail|banner|cover|mockup|gradient|background|wallpaper|attached image)\b/.test(normalized);
  const asksVisualWork = /\b(generate|create|make|edit|enhance|upscale|resize|crop|add|put|place|remove|replace|style|mockup|gradient)\b/.test(normalized);
  return mentionsImage && asksVisualWork;
}

function antigravityImageQualityGuidance(prompt: string) {
  if (!looksLikeImageArtifactTask(prompt)) return "";
  return [
    "Image artifact quality:",
    "- For attached screenshot/photo edits, preserve the original image pixels when possible.",
    "- Prefer local image composition or editing scripts for simple edits like adding a gradient, frame, crop, resize, or background.",
    "- Avoid using generative image recreation for screenshots because it can make text/UI blurry and low-resolution.",
    "- Save final image artifacts as PNG when possible, at the source image size or larger.",
    "- If you must use generate_image, request the highest available resolution and state any quality limitation plainly.",
    "- Do not say only \"workspace artifacts\"; include the absolute saved file path so OpenAssist can render the artifact card."
  ].join("\n");
}

function antigravityPrompt(threadID: string, prompt: string, cwd: string) {
  const currentTask = prompt.trim();
  const imageQualityGuidance = antigravityImageQualityGuidance(currentTask);
  const header = [
    "OpenAssist is sending one user task to Antigravity.",
    `Workspace: ${cwd}`,
    "Reply only to the current user task.",
    "If the current task is a greeting, reply briefly and ask how you can help.",
    "Do not inspect repo files or run commands unless the current user task clearly asks for that.",
    imageQualityGuidance
  ].filter(Boolean).join("\n");

  if (isSimpleChatPrompt(currentTask)) {
    return `The user said: ${currentTask}. Respond with one short friendly greeting and ask how you can help.`;
  }

  const withContext = promptWithRecentConversationContext(threadID, currentTask);
  return `${header}\n\n${withContext}`;
}

type AntigravityProgressCallbacks = {
  emitActivity: (activity: ChatMessage) => void;
  emitStatus?: (text: string) => void;
};

function antigravityProgressLogPath(providerTurnID: string) {
  return path.join(os.tmpdir(), `openassist-antigravity-${providerTurnID}.log`);
}

function antigravityConversationIDFromLog(value: string) {
  const match = value.match(/(?:conversation=|Created conversation )([0-9a-f-]{36})/i);
  return match?.[1]?.toLowerCase() ?? "";
}

function antigravityTranscriptPath(conversationID: string) {
  return path.join(
    os.homedir(),
    ".gemini",
    "antigravity-cli",
    "brain",
    conversationID,
    ".system_generated",
    "logs",
    "transcript.jsonl"
  );
}

function antigravityActivityStatus(raw: unknown): ChatMessage["activityStatus"] {
  const value = String(raw ?? "").toLowerCase();
  if (value.includes("fail") || value.includes("error")) return "failed";
  if (value.includes("done") || value.includes("complete") || value.includes("success")) return "completed";
  if (value.includes("wait")) return "waiting";
  if (value.includes("pending")) return "pending";
  return "running";
}

function antigravityActivityTime(raw: unknown) {
  const parsed = Date.parse(String(raw ?? ""));
  return Number.isFinite(parsed) ? parsed : Date.now();
}

function antigravityReadableType(raw: unknown) {
  const value = String(raw ?? "Tool").toLowerCase().replace(/[_-]+/g, " ");
  return value.replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function cleanAntigravityArg(value: string) {
  const trimmed = value.trim();
  if (trimmed.length >= 2 && trimmed.startsWith("\"") && trimmed.endsWith("\"")) {
    try {
      return JSON.parse(trimmed) as string;
    } catch {
      return trimmed.slice(1, -1);
    }
  }
  return trimmed;
}

function antigravityToolCallDetail(toolName: string, args: JsonObject) {
  const commandLine = cleanAntigravityArg(firstRuntimeString(args.CommandLine, args.commandLine, args.command, args.Command));
  const cwd = cleanAntigravityArg(firstRuntimeString(args.Cwd, args.cwd, args.WorkingDirectory, args.workingDirectory));
  const absolutePath = cleanAntigravityArg(firstRuntimeString(args.AbsolutePath, args.absolutePath, args.path, args.filePath));
  const toolAction = cleanAntigravityArg(firstRuntimeString(args.toolAction, args.action));
  const lines: string[] = [];
  if (commandLine) lines.push(`Command\n${commandLine}`);
  else if (absolutePath) lines.push(`File\n${absolutePath}`);
  if (cwd) lines.push(`Working directory\n${cwd}`);
  if (toolAction && !lines.length) lines.push(toolAction);
  if (!lines.length && Object.keys(args).length) {
    lines.push(JSON.stringify(args, null, 2).slice(0, 1600));
  }
  return lines.join("\n\n") || toolName;
}

function antigravityToolActivityKind(toolName: string) {
  const normalized = toolName.replace(/[_\s-]+/g, "").toLowerCase();
  if (normalized.includes("generateimage") || normalized.includes("imagegeneration")) return "imageGeneration";
  if (normalized.includes("command") || normalized.includes("terminal")) return "terminal";
  if (normalized.includes("browser") || normalized.includes("chrome")) return "browserAutomation";
  if (normalized.includes("file")) return "fileChange";
  return "mcpToolCall";
}

function cleanAntigravityToolResultContent(content: string) {
  const artifacts = messageArtifactsFromText(content);
  if (artifacts.some((artifact) => artifact.kind === "image")) return "Generated image is ready.";
  if (artifacts.length) return `Saved ${artifacts[0].name}.`;
  let text = content
    .replace(/\r/g, "")
    .replace(/\t+/g, "")
    .split("\n")
    .map((line) => line.trimEnd())
    .join("\n")
    .replace(/^Created At:.*$/gmi, "")
    .replace(/^Completed At:.*$/gmi, "")
    .replace(/^The following is the entire, complete content of the requested file\.\s*$/gmi, "")
    .replace(/^The above content shows the entire, complete file contents of the requested file\.\s*$/gmi, "")
    .trim();
  const filePath = text.match(/File Path:\s*`?file:\/\/([^`\n]+)`?/i)?.[1];
  if (filePath) {
    const totalLines = text.match(/Total Lines:\s*(\d+)/i)?.[1];
    const lineText = totalLines ? ` · ${totalLines} lines` : "";
    return `Viewed ${path.basename(filePath)}${lineText}`;
  }
  const failed = text.match(/The command failed with exit code:\s*(\d+)/i)?.[1];
  text = text
    .replace(/The command completed successfully\.\s*/gi, "")
    .replace(/The command failed with exit code:\s*\d+\s*/gi, "")
    .trim();
  const outputMatch = text.match(/(?:^|\n)\s*Output:\s*\n([\s\S]*?)(?=\n\s*(?:Stdout|Stderr):|\s*$)/i);
  const stdoutMatch = text.match(/(?:^|\n)\s*Stdout:\s*\n([\s\S]*?)(?=\n\s*Stderr:|\s*$)/i);
  const stderrMatch = text.match(/(?:^|\n)\s*Stderr:\s*\n([\s\S]*?)$/i);
  const output = (outputMatch?.[1] || stdoutMatch?.[1] || "").trim();
  const stderr = (stderrMatch?.[1] || "").trim();
  if (output) return output.length > 1800 ? `${output.slice(0, 1800)}...` : output;
  if (stderr) return stderr.length > 1800 ? `${stderr.slice(0, 1800)}...` : stderr;
  const cleaned = text
    .replace(/(?:^|\n)\s*(?:Output|Stdout|Stderr):\s*/gi, "\n")
    .trim();
  if (cleaned) return cleaned.length > 1800 ? `${cleaned.slice(0, 1800)}...` : cleaned;
  return failed ? `Command failed with exit code ${failed}.` : "Command completed.";
}

function antigravityToolResultDetail(previousDetail: string, content: string) {
  const cleaned = cleanAntigravityToolResultContent(content);
  if (!cleaned) return previousDetail;
  return previousDetail ? `${previousDetail}\n\nResult\n${cleaned}` : cleaned;
}

function antigravityActivity(
  providerTurnID: string,
  suffix: string,
  title: string,
  detail: string,
  kind: string,
  status: ChatMessage["activityStatus"],
  createdAt = Date.now()
): ChatMessage {
  return {
    id: `activity-antigravity-${providerTurnID}-${suffix}`,
    role: "activity",
    text: detail,
    provider: "Antigravity",
    status: status === "completed" || status === "failed" ? "completed" : "running",
    activityTitle: title,
    activityKind: kind,
    activityStatus: status,
    activityDetail: detail,
    createdAt,
    updatedAt: Date.now()
  };
}

function cleanAntigravityReasoning(value: string) {
  return value
    .replace(/\r/g, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function antigravityPlannerReasoning(entry: JsonObject, includeContent: boolean) {
  const content = includeContent ? cleanAntigravityReasoning(String(entry.content ?? "")) : "";
  const thinking = cleanAntigravityReasoning(String(entry.thinking ?? ""));
  return [content, thinking]
    .filter((part) => part && !/^(reasoning|thinking|\[\]|\{\}|null|undefined|"")$/i.test(part))
    .join("\n\n");
}

function antigravityTranscriptEntries(conversationID: string) {
  const transcriptPath = antigravityTranscriptPath(conversationID);
  if (!fs.existsSync(transcriptPath)) return [];
  return fs.readFileSync(transcriptPath, "utf8")
    .split(/\r?\n/)
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed) return null;
      try {
        return asObject(JSON.parse(trimmed));
      } catch {
        return null;
      }
    })
    .filter(Boolean) as JsonObject[];
}

function antigravityFinalResponseFromTranscript(conversationID: string) {
  const candidates = antigravityTranscriptEntries(conversationID)
    .filter((entry) => String(entry.type ?? "").toUpperCase() === "PLANNER_RESPONSE")
    .filter((entry) => typeof entry.content === "string" && entry.content.trim())
    .filter((entry) => !Array.isArray(entry.tool_calls) || entry.tool_calls.length === 0)
    .map((entry) => String(entry.content).trim());
  return candidates[candidates.length - 1] ?? "";
}

function antigravityArtifactsFromTranscript(conversationID: string) {
  if (!conversationID) return [];
  const artifacts = antigravityTranscriptEntries(conversationID).flatMap((entry) => {
    const content = String(entry.content ?? "");
    return content ? messageArtifactsFromText(content) : [];
  });
  return uniqueArtifacts(artifacts);
}

function antigravityConversationIDFromLogFile(logPath: string) {
  if (!fs.existsSync(logPath)) return "";
  try {
    return antigravityConversationIDFromLog(fs.readFileSync(logPath, "utf8"));
  } catch {
    return "";
  }
}

function startAntigravityProgressWatcher(
  threadID: string,
  providerTurnID: string,
  logPath: string,
  callbacks: AntigravityProgressCallbacks
) {
  let logOffset = 0;
  let transcriptOffset = 0;
  let transcriptRemainder = "";
  let conversationID = "";
  let ticking = false;
  const emittedStatuses = new Set<string>();
  const pendingToolActivityIDs: string[] = [];
  const toolActivities = new Map<string, ChatMessage>();
  const startupActivityID = `activity-antigravity-${providerTurnID}-startup`;

  const emitStatusOnce = (key: string, text: string) => {
    if (emittedStatuses.has(key)) return;
    emittedStatuses.add(key);
    callbacks.emitStatus?.(text);
  };

  const emitActivity = (activity: ChatMessage) => {
    callbacks.emitActivity(activity);
    upsertRuntimeActivity(threadID, activity, providerTurnID);
  };

  const emitStartupActivity = (status: ChatMessage["activityStatus"], detail: string) => {
    emitActivity({
      ...antigravityActivity(
        providerTurnID,
        "startup",
        "Preparing Antigravity",
        detail,
        "providerProgress",
        status
      ),
      id: startupActivityID
    });
  };

  const readChunk = (filePath: string, offset: number) => {
    if (!fs.existsSync(filePath)) return { chunk: "", offset };
    const text = fs.readFileSync(filePath, "utf8");
    const safeOffset = text.length < offset ? 0 : offset;
    return { chunk: text.slice(safeOffset), offset: text.length };
  };

  const handlePlannerToolCalls = (entry: JsonObject) => {
    const toolCalls = Array.isArray(entry.tool_calls) ? entry.tool_calls : [];
    const stepIndex = Number(entry.step_index ?? Date.now());
    const createdAt = antigravityActivityTime(entry.created_at);
    const reasoning = antigravityPlannerReasoning(entry, toolCalls.length > 0);
    if (reasoning) {
      emitActivity(antigravityActivity(
        providerTurnID,
        `reasoning-${stepIndex}`,
        "Reasoning",
        reasoning,
        "reasoning",
        "completed",
        createdAt
      ));
    }
    toolCalls.forEach((rawCall, index) => {
      const call = asObject(rawCall);
      if (!call) return;
      const toolName = firstRuntimeString(call.name, call.tool_name, call.type) || "tool";
      const args = asObject(call.args) ?? {};
      const title = firstRuntimeString(args.toolSummary, args.toolAction, call.friendlySummary)
        || antigravityReadableType(toolName);
      const detail = antigravityToolCallDetail(toolName, args);
      const idSuffix = `tool-${stepIndex}-${index}`;
      const activity = antigravityActivity(
        providerTurnID,
        idSuffix,
        title,
        detail,
        antigravityToolActivityKind(toolName),
        "running",
        createdAt
      );
      toolActivities.set(activity.id, activity);
      pendingToolActivityIDs.push(activity.id);
      emitActivity(activity);
    });
  };

  const handleToolResult = (entry: JsonObject) => {
    const content = String(entry.content ?? "").trim();
    const artifacts = messageArtifactsFromText(content);
    const imageArtifact = artifacts.find((artifact) => artifact.kind === "image" && artifact.dataURL);
    const queuedID = pendingToolActivityIDs.shift();
    const fallbackSuffix = `result-${entry.step_index ?? Date.now()}`;
    const previous = queuedID ? toolActivities.get(queuedID) : undefined;
    const baseID = queuedID ?? `activity-antigravity-${providerTurnID}-${fallbackSuffix}`;
    const nextDetail = antigravityToolResultDetail(previous?.activityDetail || "", content);
    const activity = {
      ...antigravityActivity(
        providerTurnID,
        baseID.replace(`activity-antigravity-${providerTurnID}-`, ""),
        previous?.activityTitle || antigravityReadableType(entry.type),
        imageArtifact ? "Generated image is ready." : nextDetail,
        imageArtifact ? "imageGeneration" : previous?.activityKind || antigravityToolActivityKind(String(entry.type ?? "tool")),
        entry.error ? "failed" : antigravityActivityStatus(entry.status),
        previous?.createdAt ?? antigravityActivityTime(entry.created_at)
      ),
      id: baseID,
      artifacts,
      imageDataURL: imageArtifact?.dataURL ?? previous?.imageDataURL,
      imagePath: imageArtifact?.path ?? previous?.imagePath,
      imageMimeType: imageArtifact?.mimeType ?? previous?.imageMimeType,
      imageName: imageArtifact?.name ?? previous?.imageName
    };
    toolActivities.set(activity.id, activity);
    emitActivity(activity);
  };

  const handleTranscriptLine = (line: string) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let parsed: JsonObject | null = null;
    try {
      parsed = asObject(JSON.parse(trimmed));
    } catch {
      return;
    }
    if (!parsed) return;
    const type = String(parsed.type ?? "").toUpperCase();
    if (type === "PLANNER_RESPONSE") {
      handlePlannerToolCalls(parsed);
      if (parsed.content) emitStatusOnce("final-response", "Antigravity is finishing the answer...");
      return;
    }
    if (type === "USER_INPUT" || type === "CONVERSATION_HISTORY") return;
    if (pendingToolActivityIDs.length) {
      handleToolResult(parsed);
      return;
    }
    const content = String(parsed.content ?? "").trim();
    if (!content) return;
    emitActivity(antigravityActivity(
      providerTurnID,
      `step-${parsed.step_index ?? Date.now()}`,
      antigravityReadableType(type),
      content.slice(0, 3000),
      antigravityToolActivityKind(type),
      antigravityActivityStatus(parsed.status),
      antigravityActivityTime(parsed.created_at)
    ));
  };

  const processTranscript = () => {
    if (!conversationID) return;
    const transcriptPath = antigravityTranscriptPath(conversationID);
    const result = readChunk(transcriptPath, transcriptOffset);
    transcriptOffset = result.offset;
    if (!result.chunk) return;
    const combined = `${transcriptRemainder}${result.chunk}`;
    const lastNewline = combined.lastIndexOf("\n");
    if (lastNewline < 0) {
      transcriptRemainder = combined;
      return;
    }
    const complete = combined.slice(0, lastNewline);
    transcriptRemainder = combined.slice(lastNewline + 1);
    for (const line of complete.split(/\r?\n/)) handleTranscriptLine(line);
  };

  const tick = () => {
    if (ticking) return;
    ticking = true;
    try {
      const result = readChunk(logPath, logOffset);
      logOffset = result.offset;
      const logChunk = result.chunk;
      if (logChunk) {
        if (!conversationID) {
          conversationID = antigravityConversationIDFromLog(logChunk);
          if (conversationID) {
            emitStatusOnce("conversation", "Antigravity started the task...");
            emitStartupActivity("completed", "Antigravity started the task.");
          }
        }
        if (/not authenticated, trying silent auth/i.test(logChunk)) emitStatusOnce("auth", "Antigravity is signing in...");
        if (/silent auth succeeded/i.test(logChunk)) emitStatusOnce("auth-ok", "Antigravity signed in.");
        if (/sending message/i.test(logChunk)) emitStatusOnce("message", "Antigravity is reading the task...");
        if (/streamGenerateContent/i.test(logChunk)) emitStatusOnce("generate", "Antigravity is generating...");
      }
      processTranscript();
    } catch (error) {
      bridgeDebugLog(`Antigravity progress watcher ignored error: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      ticking = false;
    }
  };

  const timer = setInterval(tick, 500);
  emitStartupActivity("running", "Starting Antigravity CLI and waiting for live steps.");
  tick();
  return {
    flush: tick,
    conversationID: () => conversationID,
    stop: () => {
      clearInterval(timer);
      tick();
      if (transcriptRemainder.trim()) {
        handleTranscriptLine(transcriptRemainder);
        transcriptRemainder = "";
      }
      emitStartupActivity("completed", conversationID ? "Antigravity finished reading the task." : "Antigravity finished.");
    }
  };
}

async function sendAntigravityMessage(
  session: SessionSummary | undefined,
  threadID: string,
  prompt: string,
  providerTurnID: string,
  run?: ActiveProviderRun,
  callbacks?: AntigravityProgressCallbacks
) {
  const executablePath = await resolveExecutablePath("agy");
  if (!executablePath) {
    throw new Error(`Antigravity CLI is not installed yet. Install it with: ${antigravityCLIInstallCommand}`);
  }
  const cwd = providerWorkingDirectory(session);
  const promptWithContext = antigravityPrompt(threadID, prompt, cwd);
  const logPath = antigravityProgressLogPath(providerTurnID);
  try {
    fs.rmSync(logPath, { force: true });
  } catch {
    // The log is best-effort progress UI. A stale cleanup failure should not block the run.
  }
  const progressWatcher = callbacks
    ? startAntigravityProgressWatcher(threadID, providerTurnID, logPath, callbacks)
    : null;
  const args = [
    "--print",
    promptWithContext,
    "--dangerously-skip-permissions",
    "--print-timeout",
    "20m",
    "--add-dir",
    cwd,
    "--log-file",
    logPath
  ];
  let stdout = "";
  let stderr = "";
  try {
    const result = await execCaptured(
      executablePath,
      args,
      cwd,
      20 * 60_000,
      run,
      (currentStdout, currentStderr) => antigravityAuthRequired(`${currentStdout}\n${currentStderr}`)
        ? new Error(antigravityAuthRequiredMessage())
        : null,
      () => progressWatcher?.flush()
    );
    stdout = result.stdout;
    stderr = result.stderr;
  } catch (error) {
    const captured = error as Error & { stdout?: string; stderr?: string };
    const output = `${captured.stdout ?? ""}\n${captured.stderr ?? ""}\n${captured.message}`;
    if (antigravityAuthRequired(output)) {
      throw new Error(antigravityAuthRequiredMessage());
    }
    throw error;
  } finally {
    progressWatcher?.stop();
  }
  recordUsageFromProviderCLIOutput("antigravityCLI", stdout, stderr);
  if (antigravityAuthRequired(`${stdout}\n${stderr}`)) {
    throw new Error(antigravityAuthRequiredMessage());
  }
  const conversationID = progressWatcher?.conversationID() || antigravityConversationIDFromLogFile(logPath);
  const responseText = (conversationID ? antigravityFinalResponseFromTranscript(conversationID) : "")
    || providerCLIText(stdout, stderr, "antigravityCLI");
  const artifacts = conversationID ? antigravityArtifactsFromTranscript(conversationID) : messageArtifactsFromText(`${stdout}\n${stderr}`);
  if (!responseText && antigravityTimedOut(`${stdout}\n${stderr}`)) {
    throw new Error("Antigravity timed out waiting for a response.");
  }
  if (responseText && antigravityTimedOut(responseText)) {
    throw new Error("Antigravity timed out waiting for a response.");
  }
  return {
    text: responseText || "Antigravity completed without a text response.",
    artifacts
  };
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
  attachments?: unknown[],
  eventSink?: (event: ProviderRunEvent) => void
) {
  const normalized = prompt.trim();
  const imageAttachments = normalizeComposerImageAttachments(attachments);
  if (!normalized && !imageAttachments.length) throw new Error("Message is empty.");
  const normalizedToolSelection = await normalizeCodexToolSelection(pluginIDs, skillIDs);
  pluginIDs = normalizedToolSelection.pluginIDs;
  skillIDs = normalizedToolSelection.skillIDs;
  const providerPrompt = normalized || "Please analyze the attached image.";
  let runtimePrompt = promptWithSessionInstructions(providerPrompt, sessionInstructions);
  const visibleUserText = normalized || (imageAttachments.length === 1 ? "Attached image" : `${imageAttachments.length} attached images`);
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
  if (backend !== "codex" && imageAttachments.length) {
    const imageAttachmentContext = await materializeComposerImageAttachments(openAssistThreadID, imageAttachments);
    runtimePrompt = [runtimePrompt, imageAttachmentContext].filter(Boolean).join("\n\n");
  }
  const supportsStopping = backend === "codex" || backend === "copilot" || backend === "claudeCode" || backend === "antigravityCLI";
  const activeRun: ActiveProviderRun | undefined = clientRunID && supportsStopping
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
  if (activeRun) {
    activeRun.emitStatus = (text: string) => emitRunEvent({ type: "status", text });
  }
  emitRunEvent({ type: "status", text: `Loading ${providerLabel(backend)} provider...` });
  if (backend === "ollamaLocal") {
    const existing = providerBinding(session, "ollamaLocal")?.providerSessionID;
    updateProviderBinding(openAssistThreadID, "ollamaLocal", openAssistThreadID, modelID);
    await beginTrackedCodeCheckpointIfNeeded(openAssistThreadID, interactionMode, settings);
    const providerTurnID = `ollama-turn-${randomUUID().toLowerCase()}`;
    let responseText = "";
    try {
      responseText = await sendOllamaMessage(openAssistThreadID, runtimePrompt, modelID);
    } catch (error) {
      await finalizeTrackedCodeCheckpointIfNeeded({
        threadID: openAssistThreadID,
        turnID: providerTurnID,
        turnStatus: "failed"
      });
      throw error;
    }
    const assistantMessageID = `assistant-final-${makeID()}`;
    const finalizedCheckpoint = await finalizeTrackedCodeCheckpointIfNeeded({
      threadID: openAssistThreadID,
      turnID: providerTurnID,
      assistantMessageID,
      turnStatus: "completed"
    });
    const completedTurn = persistCompletedTurn({
      threadID: openAssistThreadID,
      backend,
      providerSessionID: openAssistThreadID,
      providerTurnID,
      modelID,
      prompt: providerPrompt,
      responseText,
      insertedSystemMessage: !(typeof existing === "string" && existing.trim()),
      assistantMessageID,
      checkpointReferences: finalizedCheckpoint ? [finalizedCheckpoint.checkpoint.id] : [],
      reasoningEffort: codexReasoningEffort,
      interactionMode,
      permissionMode
    });
    emitRunEvent({ type: "completed" });
    return {
      threadID: openAssistThreadID,
      title: completedTurn.title,
      thread: completedTurn.thread,
      user: { id: `user-${Date.now()}`, role: "user", text: visibleUserText, attachments: imageAttachments } satisfies ChatMessage,
      assistant: {
        id: assistantMessageID,
        role: "assistant",
        text: responseText,
        provider: providerLabel(backend),
        turnID: providerTurnID,
        checkpointInfo: finalizedCheckpoint
          ? checkpointInfoFor(finalizedCheckpoint.checkpoint, finalizedCheckpoint.state)
          : undefined
      } satisfies ChatMessage
    };
  }
  if (backend === "copilot" || backend === "claudeCode" || backend === "antigravityCLI") {
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
    const providerTurnPrefix = backend === "copilot"
      ? "copilot"
      : backend === "claudeCode"
        ? "claude"
        : "antigravity";
    const providerTurnID = `${providerTurnPrefix}-turn-${randomUUID().toLowerCase()}`;
    let responseText = "";
    let assistantArtifacts: MessageArtifact[] = [];
    try {
      await beginTrackedCodeCheckpointIfNeeded(openAssistThreadID, interactionMode, settings);
      if (backend === "copilot") {
        responseText = await Promise.race([
          sendCopilotMessage(providerSession.providerSessionID, session, runtimePrompt, modelID, activeRun),
          stopPromise
        ]);
      } else if (backend === "claudeCode") {
        responseText = await Promise.race([
          sendClaudeCodeMessage(providerSession.providerSessionID, session, runtimePrompt, modelID, providerSession.insertedSystemMessage, activeRun),
          stopPromise
        ]);
      } else {
        const emitAntigravityActivity = (activity: ChatMessage) => {
          emitRunEvent({ type: "activity", activity });
        };
        const antigravityResult = await Promise.race([
          sendAntigravityMessage(session, openAssistThreadID, runtimePrompt, providerTurnID, activeRun, {
            emitActivity: emitAntigravityActivity,
            emitStatus: (text) => emitRunEvent({ type: "status", text })
          }),
          stopPromise
        ]);
        responseText = antigravityResult.text;
        assistantArtifacts = antigravityResult.artifacts;
      }
    } catch (error) {
      await finalizeTrackedCodeCheckpointIfNeeded({
        threadID: openAssistThreadID,
        turnID: providerTurnID,
        turnStatus: error instanceof ProviderRunStoppedError ? "cancelled" : "failed"
      });
      if (clientRunID) activeProviderRuns.delete(clientRunID);
      throw error;
    }
    const assistantMessageID = `assistant-final-${makeID()}`;
    const finalizedCheckpoint = await finalizeTrackedCodeCheckpointIfNeeded({
      threadID: openAssistThreadID,
      turnID: providerTurnID,
      assistantMessageID,
      turnStatus: "completed"
    });
    const completedTurn = persistCompletedTurn({
      threadID: openAssistThreadID,
      backend,
      providerSessionID: providerSession.providerSessionID,
      providerTurnID,
      modelID,
      prompt: providerPrompt,
      responseText,
      insertedSystemMessage: providerSession.insertedSystemMessage,
      assistantMessageID,
      checkpointReferences: finalizedCheckpoint ? [finalizedCheckpoint.checkpoint.id] : [],
      assistantArtifacts,
      reasoningEffort: codexReasoningEffort,
      interactionMode,
      permissionMode
    });
    emitRunEvent({ type: "completed" });
    if (clientRunID) activeProviderRuns.delete(clientRunID);
    return {
      threadID: openAssistThreadID,
      title: completedTurn.title,
      thread: completedTurn.thread,
      user: { id: `user-${Date.now()}`, role: "user", text: visibleUserText, attachments: imageAttachments } satisfies ChatMessage,
      assistant: {
        id: assistantMessageID,
        role: "assistant",
        text: responseText,
        artifacts: assistantArtifacts,
        provider: providerLabel(backend),
        turnID: providerTurnID,
        checkpointInfo: finalizedCheckpoint
          ? checkpointInfoFor(finalizedCheckpoint.checkpoint, finalizedCheckpoint.state)
          : undefined
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
  if (shouldPreferCodexComputerUsePlugin(pluginIDs)) {
    emitRunEvent({ type: "status", text: "Preparing Computer Use..." });
    try {
      const didResetActiveComputerUse = await resetCodexIfComputerUseAlreadyActive("Reset stale active Computer Use tool before starting a new turn");
      if (didResetActiveComputerUse) {
        emitRunEvent({ type: "status", text: "Reset stale Computer Use work. Starting clean..." });
      }
      const didResetExistingHelper = await resetCodexIfCurrentComputerUseHelperExists("Reset existing Computer Use helper before starting a new turn");
      if (didResetExistingHelper) {
        emitRunEvent({ type: "status", text: "Reset existing Computer Use helper. Starting clean..." });
      }
      const cleanup = await cleanupStaleComputerUseHelpers(codexTransport.currentPID());
      if (cleanup.killed.length) {
        bridgeDebugLog(`Computer Use stale helper cleanup completed before provider session killed=${cleanup.killed.join(",")}`);
        emitRunEvent({ type: "status", text: "Cleaned up stale Computer Use helpers. Starting Codex..." });
      }
    } catch (error) {
      bridgeDebugLog(`Computer Use stale helper cleanup failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
    }
  }
  const providerSession = await ensureCodexProviderSession(openAssistThreadID, modelID, codexRuntimeOptions);
  await beginTrackedCodeCheckpointIfNeeded(openAssistThreadID, interactionMode, settings);
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
    const pluginItems = await pluginPromptItems(pluginIDs, providerPrompt);
    const structuredItems = [
      ...composerImageInputItems(imageAttachments),
      ...dedupeInputItems([
        ...(await threadSkillPromptItems(openAssistThreadID)),
        ...(await selectedSkillPromptItems(skillIDs)),
        ...imageGenerationSkillPromptItems(providerPrompt),
        ...pluginItems
      ]),
      ...composerImageInstructionItems(imageAttachments)
    ];
    const startedTurn = await Promise.race([
      codexTransport.request(
        "turn/start",
        codexTurnStartParams(providerSession.providerSessionID, providerPrompt, structuredItems, modelID, codexRuntimeOptions)
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
  } catch (error) {
    await finalizeTrackedCodeCheckpointIfNeeded({
      threadID: openAssistThreadID,
      turnID: providerTurnID,
      turnStatus: error instanceof ProviderRunStoppedError ? "cancelled" : "failed"
    });
    throw error;
  } finally {
    codexTransport.off("notification", onNotification);
    if (clientRunID) activeProviderRuns.delete(clientRunID);
  }
  const finalText = responseText.trim() || (didGenerateImage ? "Generated image is ready." : "The Codex turn completed without a text response.");
  const shouldRestartAfterComputerUseTimeout = didObserveComputerUseToolFailure || responseIndicatesComputerUseTimeout(finalText);
  const assistantMessageID = `assistant-final-${makeID()}`;
  const finalizedCheckpoint = await finalizeTrackedCodeCheckpointIfNeeded({
    threadID: openAssistThreadID,
    turnID: providerTurnID,
    assistantMessageID,
    turnStatus: "completed"
  });
  const completedTurn = persistCompletedTurn({
    threadID: openAssistThreadID,
    backend,
    providerSessionID: providerSession.providerSessionID,
    providerTurnID,
    activityTurnIDs: Array.from(activityTurnIDs),
    modelID,
    prompt: providerPrompt,
    responseText: finalText,
    insertedSystemMessage: providerSession.insertedSystemMessage,
    assistantMessageID,
    checkpointReferences: finalizedCheckpoint ? [finalizedCheckpoint.checkpoint.id] : [],
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
    await cleanupStaleComputerUseHelpers(undefined, { allowDuringActiveToolCall: true }).catch((error) => {
      bridgeDebugLog(`cleanup after Computer Use timeout failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
    });
  }
  emitRunEvent({ type: "completed" });
  return {
    threadID: openAssistThreadID,
    title: completedTurn.title,
    thread: completedTurn.thread,
    user: { id: `user-${Date.now()}`, role: "user", text: visibleUserText, attachments: imageAttachments } satisfies ChatMessage,
    assistant: {
      id: assistantMessageID,
      role: "assistant",
      text: finalText,
      provider: "Codex",
      turnID: providerTurnID,
      checkpointInfo: finalizedCheckpoint
        ? checkpointInfoFor(finalizedCheckpoint.checkpoint, finalizedCheckpoint.state)
        : undefined
    } satisfies ChatMessage
  };
}

export async function codexRuntimeParityProbe(options: {
  prompt?: string;
  cwd?: string;
  pluginIDs?: string[];
  skillIDs?: string[];
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
  const normalizedToolSelection = await normalizeCodexToolSelection(options.pluginIDs ?? [], options.skillIDs ?? []);
  const canonicalPluginIDs = normalizedToolSelection.pluginIDs;
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
  const skillItems = await selectedSkillPromptItems(normalizedToolSelection.skillIDs);
  const structuredInputItems = dedupeInputItems([...skillItems, ...pluginItems]);
  const appStatuses = await listPluginAppStatuses().catch(() => [] as PluginAppStatus[]);
  const appStatusProbeMatches = appStatuses
    .filter((status) => appMatchCandidates(status).some((candidate) => promptContainsStandalonePhrase(candidate, prompt)))
    .slice(0, 20)
    .map((status) => ({
      id: status.id,
      name: status.name,
      isAccessible: status.isAccessible,
      isEnabled: status.isEnabled,
      pluginDisplayNames: status.pluginDisplayNames
    }));
  const appStatusProbeSample = appStatuses.slice(0, 20).map((status) => ({
    id: status.id,
    name: status.name,
    isAccessible: status.isAccessible,
    isEnabled: status.isEnabled,
    pluginDisplayNames: status.pluginDisplayNames
  }));
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
    appStatusProbeMatches,
    appStatusProbeSample,
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
  loadCodeTrackingState,
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
  openCodeReview,
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
  restoreCodeCheckpoint,
  voiceInputConfiguration,
  writeThreadSkillBinding as toggleThreadSkill
};
