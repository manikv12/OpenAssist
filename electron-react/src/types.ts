export type ViewKey = "threads" | "notes" | "history" | "automations" | "skills" | "plugins" | "settings";

export type ProjectItem = {
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

export type ThreadItem = {
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

export type ComposerImageAttachment = {
  id: string;
  name: string;
  mimeType: string;
  dataURL: string;
  size?: number;
};

export type MessageArtifact = {
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

export type ChatMessage = {
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
  approvalRequestID?: string | number;
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

export type CodeCheckpointTurnStatus = "completed" | "failed" | "cancelled";

export type GitCheckpointPathState = {
  blobID: string | null;
  mode: string | null;
  objectType: string | null;
};

export type GitCheckpointSnapshot = {
  worktreeRef: string;
  worktreeCommit: string;
  worktreeTree: string;
  indexRef: string;
  indexCommit: string;
  indexTree: string;
  ignoredFingerprints: Record<string, never>;
};

export type CodeCheckpointFile = {
  path: string;
  changeKind: "added" | "modified" | "deleted" | "changed" | "typeChanged";
  beforeWorktree: GitCheckpointPathState;
  afterWorktree: GitCheckpointPathState;
  beforeIndex: GitCheckpointPathState;
  afterIndex: GitCheckpointPathState;
  isBinary: boolean;
};

export type CodeCheckpointSummary = {
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

export type CodeTrackingState = {
  sessionID: string;
  availability: "available" | "unavailable" | "error";
  repoRootPath?: string;
  repoLabel?: string;
  checkpoints: CodeCheckpointSummary[];
  currentCheckpointPosition: number;
  errorMessage?: string;
};

export type CodeReviewPanelState = {
  sessionID: string;
  repoRootPath: string;
  repoLabel: string;
  checkpoints: CodeCheckpointSummary[];
  currentCheckpointPosition: number;
  selectedCheckpointID: string;
  hasActiveTurn: boolean;
  actionsLocked: boolean;
};

export type MessageCheckpointInfo = {
  checkpoint: CodeCheckpointSummary;
  checkpointIndex: number;
  currentCheckpointPosition: number;
  totalCheckpointCount: number;
  hasActiveTurn: boolean;
  actionsLocked: boolean;
  futureTurnsHidden: boolean;
};

export type ProviderRunEvent =
  | { runID?: string; threadID: string; type: "status"; provider: string; text: string }
  | { runID?: string; threadID: string; type: "assistant-delta"; provider: string; delta: string }
  | { runID?: string; threadID: string; type: "activity"; provider: string; activity: ChatMessage }
  | { runID?: string; threadID: string; type: "completed"; provider: string }
  | { runID?: string; threadID: string; type: "failed"; provider: string; error: string };

export type NoteItem = {
  id: string;
  title: string;
  subtitle: string;
  projectID: string;
  projectName?: string;
  folderID?: string | null;
  updatedAt?: number;
  active?: boolean;
};

export type ThreadNoteListItem = {
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

export type NoteFolderItem = {
  id: string;
  name: string;
  projectID: string;
  noteCount: number;
};

export type NoteDetail = {
  id: string;
  title: string;
  markdown: string;
  path?: string;
};

export type AutomationItem = {
  id: string;
  title: string;
  prompt?: string;
  schedule: string;
  enabled: boolean;
};

export type TranscriptHistoryEntry = {
  id: string;
  text: string;
  createdAt: string;
};

export type SkillItem = {
  id: string;
  title: string;
  description: string;
  group: "built-in" | "my-skills" | "imported";
  attached?: boolean;
  path?: string;
  readOnly?: boolean;
  iconPath?: string | null;
};

export type PluginItem = {
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

export type ProviderModelOption = {
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

export type SettingsSnapshot = {
  appVersion: string;
  buildNumber: string;
  assistantBackend: string;
  availableAssistantBackends?: string[];
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

export type UsageWindowSnapshot = {
  label: string;
  usedPercent: number;
  resetsAt?: string | null;
  resetsInLabel?: string | null;
};

export type ContextUsageSnapshot = {
  usedPercent: number;
  summary: string;
  detail?: string | null;
};

export type ProviderUsageSnapshot = {
  providerBackend: string;
  providerLabel: string;
  planType?: string | null;
  primary?: UsageWindowSnapshot | null;
  secondary?: UsageWindowSnapshot | null;
  context?: ContextUsageSnapshot | null;
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

export type ThreadNoteDetail = ThreadNoteSummary & {
  markdown: string;
  path: string;
};

export type ThreadNoteWorkspace = {
  threadID: string;
  notes: ThreadNoteSummary[];
  selectedNoteID?: string;
  selectedNote?: ThreadNoteDetail;
};

export type ThreadMemorySnapshot = {
  threadID: string;
  exists: boolean;
  path?: string;
  markdown: string;
};

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
  usageByBackend?: Partial<Record<string, ProviderUsageSnapshot | null>>;
  activeThreadID?: string;
  activeProjectID?: string;
  activeNoteID?: string;
};

export type SettingsUpdateKey =
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

export type SettingsUpdateValue = boolean | string | number;
