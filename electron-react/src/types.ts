export type ViewKey = "threads" | "today" | "notes" | "history" | "automations" | "skills" | "plugins" | "settings";

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
  archivedAt?: number;
  autoDeleteAfter?: number | null;
  isTemporary?: boolean;
  isRunning?: boolean;
  runStatusText?: string;
  runElapsedText?: string;
  active?: boolean;
};

export type ComposerImageAttachment = {
  id: string;
  name: string;
  mimeType: string;
  dataURL: string;
  size?: number;
  // "image" attachments are sent inline to the model as images.
  // "file" attachments are written to disk and the path is given to the agent.
  // Missing value is treated as "image" for backward compatibility.
  kind?: "image" | "file";
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

export type LocalFilePreviewKind =
  | "image"
  | "pdf"
  | "markdown"
  | "html"
  | "json"
  | "csv"
  | "code"
  | "text"
  | "unsupported";

export type LocalFilePreview = {
  ok: true;
  path: string;
  name: string;
  extension: string;
  mimeType: string;
  size: number;
  kind: LocalFilePreviewKind;
  text?: string;
  dataURL?: string;
  fileURL?: string;
  truncated?: boolean;
  tooLarge?: boolean;
} | {
  ok: false;
  path?: string;
  name?: string;
  error: string;
};

export type ChatMessage = {
  id: string;
  role: "user" | "assistant" | "activity";
  text: string;
  source?: "runtime" | "realtimeVoice" | string;
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

export type WakeWordStatusState = "idle" | "starting" | "listening" | "detected" | "error" | "stopped";

export type WakeWordStatus = {
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

export type NoteItem = {
  id: string;
  title: string;
  subtitle: string;
  projectID: string;
  projectName?: string;
  folderID?: string | null;
  updatedAt?: number;
  isArchived?: boolean;
  archivedAt?: number;
  autoDeleteAfter?: number | null;
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
  archivedAt?: number;
  autoDeleteAfter?: number | null;
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

export type NoteHistoryItem = {
  id: string;
  title: string;
  savedAtLabel: string;
  preview: string;
  markdown: string;
};

export type NoteAICleanupMode = "cleanup" | "summarize" | "decisions" | "custom";

export type NoteAICleanupScope = "selection" | "whole-note";

export type NoteAICleanupRequest = {
  noteID?: string;
  projectID?: string;
  title?: string;
  markdown: string;
  scope: NoteAICleanupScope;
  mode: NoteAICleanupMode;
  instruction?: string;
};

export type NoteAICleanupResult = {
  ok: boolean;
  markdown?: string;
  title?: string;
  summary?: string;
  confidence?: number;
  warnings?: string[];
  usedBlocks?: string[];
  rawText?: string;
  error?: string;
};

export type MarkdownImportFile = {
  path: string;
  fileName: string;
  title: string;
  markdown: string;
};

export type NoteLinkOwnerKind = "project" | "thread" | "planner";

export type NoteLinkTarget = {
  ownerKind: NoteLinkOwnerKind;
  ownerId: string;
  noteId: string;
};

export type NoteLinkRelation = NoteLinkTarget & {
  title: string;
  sourceLabel: string;
  occurrenceCount: number;
  isMissing?: boolean;
};

export type NoteLinkGraphNode = NoteLinkTarget & {
  id: string;
  title: string;
  sourceLabel: string;
  isCurrent?: boolean;
  isMissing?: boolean;
};

export type NoteLinkGraphEdge = {
  from: string;
  to: string;
  occurrenceCount: number;
};

export type NoteLinkGraph = {
  nodeCount: number;
  edgeCount: number;
  mermaidCode: string;
  nodes: NoteLinkGraphNode[];
  edges: NoteLinkGraphEdge[];
};

export type NoteLinksSnapshot = {
  outgoingLinks: NoteLinkRelation[];
  backlinks: NoteLinkRelation[];
  graph: NoteLinkGraph | null;
};

export type PlannerDaySummary = {
  id: string;
  title: string;
  subtitle: string;
  path: string;
  updatedAt?: number;
  active?: boolean;
};

export type PlannerDayDetail = PlannerDaySummary & {
  markdown: string;
};

export type PlannerBacklogDetail = PlannerDaySummary & {
  markdown: string;
};

export type DailyItemStatus = "todo" | "doing" | "done";

export type DailyItemStep = {
  id: string;
  text: string;
  checked: boolean;
};

export type DailyItemScopeTag = {
  marker: "@" | "#";
  label: string;
  kind: "project" | "folder" | "unresolved";
  id?: string;
};

export type DailyItem = {
  id: string;
  dayID: string;
  title: string;
  status: DailyItemStatus;
  checked: boolean;
  projectID?: string;
  folderID?: string;
  projectName?: string;
  folderName?: string;
  area?: string;
  scopeTags?: DailyItemScopeTag[];
  detailsMarkdown: string;
  steps: DailyItemStep[];
  links: NoteLinkTarget[];
  createdAt: string;
  updatedAt: string;
  order: number;
  structured?: boolean;
  line?: number;
};

export type DailyItemInput = Partial<Omit<DailyItem, "id" | "createdAt" | "updatedAt" | "structured" | "line">> & {
  id?: string;
  dayID?: string;
  title: string;
};

export type DailyItemMutationResult = {
  day: PlannerDayDetail;
  items: DailyItem[];
  item?: DailyItem | null;
};

export type BacklogItemMutationResult = {
  backlog: PlannerBacklogDetail;
  items: DailyItem[];
  item?: DailyItem | null;
  scheduledDay?: PlannerDayDetail;
  scheduledItems?: DailyItem[];
};

export type PlannerScheduleRequest = {
  mode?: "move" | "copy" | "link";
  targetDayID?: string;
  selectedText?: string;
  sourceTextAfterMove?: string;
  sourceTitle?: string;
  sourceTarget?: NoteLinkTarget | null;
  sourceDayID?: string;
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

export type OllamaCatalogModelOption = {
  id: string;
  displayName: string;
  description?: string;
  sizeLabel?: string;
  performanceLabel?: string;
  isRecommended?: boolean;
  isInstalled?: boolean;
  source?: "curated" | "website";
};

export type OllamaModelDownloadProgress = {
  modelID: string;
  status: string;
  completed?: number;
  total?: number;
  percent?: number;
  done?: boolean;
  error?: string;
};

export type OllamaInstallKind =
  | "homebrew-formula"
  | "homebrew-cask"
  | "native-app"
  | "managed"
  | "unknown"
  | "none";

export type OllamaRuntimeStatus = {
  installed: boolean;
  isHealthy: boolean;
  installKind: OllamaInstallKind;
  installLabel: string;
  currentVersion?: string;
  latestVersion?: string;
  updateAvailable: boolean;
  canAutoUpdate: boolean;
  updateActionLabel: string;
  updateCheckError?: string;
  statusMessage: string;
  installMessage?: string;
  downloadURL: string;
};

export type OllamaRuntimeUpdateProgress = {
  status: string;
  error?: string;
  done?: boolean;
};

export type NoteReadAloudSource = "selection" | "whole-note" | "message";
export type NoteReadAloudStatus = "idle" | "preparing" | "playing" | "paused" | "finished" | "error";

export type NoteReadAloudRequest = {
  text: string;
  source?: NoteReadAloudSource;
  title?: string;
  targetID?: string;
};

export type NoteReadAloudState = {
  status: NoteReadAloudStatus;
  source?: NoteReadAloudSource;
  title?: string;
  targetID?: string;
  currentSegment: number;
  totalSegments: number;
  progressLabel?: string;
  error?: string;
  engine?: string;
  voice?: string;
  model?: string;
  audioDataURL?: string;
  mimeType?: string;
};

export type ReadAloudAudioResult = {
  ok: boolean;
  audioDataURL?: string;
  mimeType?: string;
  engine?: string;
  model?: string;
  voice?: string;
  label?: string;
  error?: string;
  fallbackAvailable?: boolean;
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
  fontSmoothing: boolean;
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
  realtimeVoiceProvider: string;
  realtimeGeminiAPIKeyConfigured: boolean;
  realtimeMaskedGeminiAPIKey: string;
  realtimeGeminiModel: string;
  realtimeGeminiVoice: string;
  liveVoiceMode: string;
  todayWakeWordEnabled: boolean;
  todayWakeWordPhrase: string;
  realtimeDelegationMode: "autoHardTasksOnly" | "alwaysDelegate" | "neverDelegate";
  localVoiceModel: string;
  speechOutputRewriteModel: string;
  assistantVoiceOutputEnabled: boolean;
  computerUseEnabled: boolean;
  memoryEnabled: boolean;
  knowledgeAccessEnabled: boolean;
  knowledgeExternalAccessEnabled: boolean;
  knowledgeAgentAccessEnabled: boolean;
  knowledgeRealtimeVoiceAccessEnabled: boolean;
  knowledgeOrganizerEnabled: boolean;
  knowledgeServerPort: string;
  knowledgeServerURL: string;
  knowledgeTokenConfigured: boolean;
  knowledgePendingRequestCount: number;
  assistantTrackCodeChangesInGitRepos: boolean;
  archiveAutoDeleteDays: number | null;
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
  pocketTTSVoice: string;
  openAITTSModel: string;
  openAITTSVoice: string;
  noteCleanupModel: string;
  noteCleanupReasoningEffort: string;
  geminiTTSModel: string;
  geminiTTSVoice: string;
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
  remoteAccessNetworkMode: "localOnly" | "localNetwork" | "tailscale";
  remoteAccessTailscaleHost: string;
  remoteAccessLocalNetworkURL: string;
  remoteAccessTailscaleURL: string;
  remoteAccessEasyTunnelURL: string;
  remoteAccessEasyTunnelRunning: boolean;
  remoteAccessEasyTunnelStatusMessage: string;
  remoteAccessTunnelHelperInstalled: boolean;
  remoteAccessTunnelHelperInstalling: boolean;
  remoteAccessTailscaleInstalled: boolean;
  remoteAccessTailscaleRunning: boolean;
  remoteAccessDetectedTailscaleHost: string;
  remoteAccessTailscaleAppPath: string;
  remoteAccessTailscaleInstallURL: string;
  remoteAccessTailscaleStatusMessage: string;
  remoteAccessPairingCode: string;
  remoteAccessPairingURL: string;
  remoteAccessPairingExpiresAt: number | null;
  remoteAccessServerRunning: boolean;
  remoteAccessDeviceCount: number;
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
  hasMoreBefore?: boolean;
  oldestMessageID?: string;
  loadedTurnCount?: number;
};

export type ThreadNoteSummary = {
  id: string;
  title: string;
  fileName: string;
  updatedAt?: number;
  isArchived?: boolean;
  archivedAt?: number;
  autoDeleteAfter?: number | null;
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
  plannerDays: PlannerDaySummary[];
  plannerBacklog?: PlannerBacklogDetail | null;
  backlogItems?: DailyItem[];
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
  | "realtimeVoiceProvider"
  | "realtimeGeminiModel"
  | "realtimeGeminiVoice"
  | "liveVoiceMode"
  | "todayWakeWordEnabled"
  | "todayWakeWordPhrase"
  | "realtimeDelegationMode"
  | "localVoiceModel"
  | "speechOutputRewriteModel"
  | "assistantVoiceOutputEnabled"
  | "computerUseEnabled"
  | "memoryEnabled"
  | "knowledgeAccessEnabled"
  | "knowledgeExternalAccessEnabled"
  | "knowledgeAgentAccessEnabled"
  | "knowledgeRealtimeVoiceAccessEnabled"
  | "knowledgeOrganizerEnabled"
  | "knowledgeServerPort"
  | "assistantTrackCodeChangesInGitRepos"
  | "archiveAutoDeleteDays"
  | "telegramEnabled"
  | "remoteAccessEnabled"
  | "remoteAccessNetworkMode"
  | "remoteAccessTailscaleHost"
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
  | "fontSmoothing"
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
  | "pocketTTSVoice"
  | "openAITTSModel"
  | "openAITTSVoice"
  | "noteCleanupModel"
  | "noteCleanupReasoningEffort"
  | "geminiTTSModel"
  | "geminiTTSVoice"
  | "whisperModel"
  | "whisperUseCoreML"
  | "transcriptionEngine";

export type SettingsUpdateValue = boolean | string | number;

export type KnowledgePreview =
  | { kind: "planner_append"; dayID: string; section: string; content: string }
  | { kind: "planner_move"; fromDayID: string; dayID: string; section: string; content: string; removeTexts: string[] }
  | { kind: "planner_backlog_move"; entries: { dayID: string; text: string }[] }
  | { kind: "daily_item_upsert"; item: DailyItemInput }
  | { kind: "daily_item_delete"; dayID: string; itemID: string }
  | { kind: "replace_markdown"; itemID: string; markdown: string; previousMarkdown?: string; title?: string };

export type KnowledgeWriteRequest = {
  id: string;
  action: string;
  source: "http" | "mcp" | "voice" | "app";
  status: "pending" | "applied" | "rejected";
  createdAt: string;
  updatedAt: string;
  goal: string;
  payload: Record<string, unknown>;
  preview?: KnowledgePreview;
  appliedAt?: string;
  rejectedAt?: string;
};

export type KnowledgeStatus = {
  tokenConfigured: boolean;
  server?: Record<string, unknown>;
  pendingRequests: KnowledgeWriteRequest[];
};
