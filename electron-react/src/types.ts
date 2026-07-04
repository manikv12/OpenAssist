export type ViewKey = "threads" | "today" | "notes" | "reviewInbox" | "history" | "automations" | "skills" | "plugins" | "settings";

export type ProjectItem = {
  id: string;
  title: string;
  subtitle: string;
  icon: string;
  kind?: "folder" | "project";
  parentID?: string | null;
  linkedFolderPath?: string | null;
  peerLinkedFolders?: Array<{ machineID?: string; machineName?: string; path?: string }>;
  area?: string;
  color?: string;
  plannerOnly?: boolean;
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
  hasUnread?: boolean;
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
  area?: string;
  tags?: string[];
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
  parentFolderID: string | null;
  noteCount: number;
};

export type NoteDetail = {
  id: string;
  title: string;
  markdown: string;
  path?: string;
  area?: string;
  tags?: string[];
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

export type PlannerCategory = {
  id: string;
  name: string;
  color?: string;
  icon?: string;
  createdAt: string;
  updatedAt: string;
  order: number;
  hidden?: boolean;
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
  kind: "category" | "project" | "folder" | "unresolved";
  id?: string;
  color?: string;
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
  section?: string;
  tags?: string[];
  scopeTags?: DailyItemScopeTag[];
  detailsMarkdown: string;
  steps: DailyItemStep[];
  links: NoteLinkTarget[];
  reminderAt?: string | null;
  reminderTimezone?: string | null;
  reminderDeliveredAt?: string | null;
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

export type PlannerSmartListSummary = {
  id: string;
  title: string;
  subtitle: string;
  count: number;
};

export type PlannerSmartListDetail = PlannerSmartListSummary & {
  items: DailyItem[];
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
  knowledgeExternalAccessMode: "simple" | "advanced" | "full";
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
  remoteAccessNetworkMode: "localOnly" | "localNetwork";
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
  remoteAccessSyncPeerCount: number;
  remoteAccessSyncPeers: MacSyncPeerStatus[];
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

export type MacSyncPeerStatus = {
  id: string;
  machineID: string;
  name: string;
  localBaseURL?: string;
  tunnelBaseURL?: string;
  lastSuccessfulBaseURL?: string;
  lastRemoteCursor?: string;
  lastLocalCursor?: string;
  lastSyncedAt?: string;
  lastError?: string;
  syncing: boolean;
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

export type KnowledgeExternalAccessMode = "simple" | "advanced" | "full";

export type OpenAssistIntegrationTargetID = "cursor" | "codex" | "claude" | "generic";

export type OpenAssistIntegrationTargetStatus = {
  id: OpenAssistIntegrationTargetID;
  title: string;
  description: string;
  configPath?: string;
  skillPath?: string;
  detected: boolean;
  connected: boolean;
  configKind: "json" | "toml" | "copy";
  skillMode: "cursor-rule" | "codex-agents" | "markdown-copy";
};

export type OpenAssistIntegrationStatus = {
  targets: OpenAssistIntegrationTargetStatus[];
  proxyPath: string;
  externalMode: KnowledgeExternalAccessMode;
  exposedToolCount: number;
  resourcesVisible: boolean;
  modeDescription: string;
};

export type OpenAssistIntegrationConnectResult = {
  ok: boolean;
  targetID: OpenAssistIntegrationTargetID;
  action: "written" | "created";
  configPath: string;
  backupPath?: string;
};

export type OpenAssistIntegrationSkillGuide = {
  title: string;
  markdown: string;
  targetID: OpenAssistIntegrationTargetID;
  skillPath?: string;
  installMode: "cursor-rule" | "codex-agents" | "markdown-copy";
};

export type OpenAssistIntegrationSkillInstallResult = {
  ok: boolean;
  targetID: OpenAssistIntegrationTargetID;
  skillPath: string;
  backupPath?: string;
  action: "written" | "created";
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
  plannerCategories?: PlannerCategory[];
  plannerLists?: ProjectItem[];
  plannerSmartLists?: PlannerSmartListSummary[];
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

export type ConnectorProvider = "google" | "apple" | "local";

export type ConnectorServiceID =
  | "gmail"
  | "googleCalendar"
  | "googleTasks"
  | "googleDriveDocs"
  | "googlePeople"
  | "appleReminders"
  | "appleCalendar"
  | "appleContacts"
  | "appleNotes"
  | "messages";

export type ConnectorItemKind =
  | "task"
  | "backlog"
  | "followUp"
  | "waitingFor"
  | "replyDraft"
  | "event"
  | "file"
  | "document"
  | "person"
  | "note"
  | "message"
  | "projectHint";

export type ConnectorItemStatus = "candidate" | "review" | "approved" | "ignored" | "synced" | "failed" | "conflict";
export type ConnectorSyncState = "externalOnly" | "localOnly" | "synced" | "pendingWrite" | "writePreview" | "failed" | "conflict";

export type ConnectorServiceDefinition = {
  id: ConnectorServiceID;
  provider: ConnectorProvider;
  displayName: string;
  purpose: string;
  syncMode: string;
};

export type ConnectorAccount = {
  id: string;
  provider: ConnectorProvider;
  label: string;
  configPath?: string;
  enabledServiceIDs: ConnectorServiceID[];
  syncCursors: Record<string, string>;
  createdAt: string;
  updatedAt: string;
  lastSyncAt?: string;
};

export type ConnectorItem = {
  id: string;
  sourceService: ConnectorServiceID;
  accountId: string;
  externalId: string;
  threadId?: string;
  kind: ConnectorItemKind;
  title: string;
  snippet: string;
  date: string;
  status: ConnectorItemStatus;
  dueDate?: string;
  person?: string;
  projectHint?: string;
  syncState: ConnectorSyncState;
  lastExternalVersion?: string;
  lastLocalVersion?: string;
  fullBodyFetched: boolean;
  rawMetadata: Record<string, string>;
  createdAt: string;
  updatedAt: string;
};

export type ConnectorConflictRecord = {
  id: string;
  itemId: string;
  sourceService: ConnectorServiceID;
  accountId: string;
  externalSummary: string;
  localSummary: string;
  externalVersion?: string;
  localVersion?: string;
  detectedAt: string;
  resolvedAt?: string;
};

export type ConnectorMutationRequest = {
  id: string;
  operation: string;
  serviceId: ConnectorServiceID;
  accountId: string;
  externalId?: string;
  title: string;
  preview: string;
  approved: boolean;
  createdAt: string;
};

export type GoogleCLIStatus = {
  pinnedVersion: string;
  bundledPath: string;
  pathExecutable?: string;
  resolvedExecutable?: string;
  version?: string;
  supported: boolean;
  installCommand: string;
  setupCommand: string;
};

export type ConnectorReviewInboxSnapshot = {
  version: 1;
  services: ConnectorServiceDefinition[];
  accounts: ConnectorAccount[];
  items: ConnectorItem[];
  updatedAt: string;
};

export type ConnectorAccessStatus = {
  serviceID: ConnectorServiceID;
  status: "granted" | "blocked" | "notSupported" | "unknown";
  label: string;
  detail: string;
  permissionKind?: "fullDiskAccess" | "appleEventKit";
};

export type AppleEventKitStatus = {
  reminders: ConnectorAccessStatus;
  calendar: ConnectorAccessStatus;
};

export type ConnectorSnapshot = {
  version: 1;
  services: ConnectorServiceDefinition[];
  accounts: ConnectorAccount[];
  localAccessStatuses: ConnectorAccessStatus[];
  items: ConnectorItem[];
  conflicts: ConnectorConflictRecord[];
  mutationRequests: ConnectorMutationRequest[];
  gwsStatus: GoogleCLIStatus;
  updatedAt: string;
};

export type ConnectorSyncProgress = {
  id: string;
  provider: ConnectorProvider;
  serviceID: ConnectorServiceID;
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

export type GoogleConnectorOperation =
  | { kind: "authSetup" }
  | { kind: "authLogin"; scopes?: string[] }
  | { kind: "authStatus" }
  | { kind: "gmailSearchMetadata"; query: string; maxResults?: number }
  | { kind: "gmailFetchMetadata"; messageId: string }
  | { kind: "gmailFetchBody"; messageId: string }
  | { kind: "calendarList"; timeMin: string; timeMax: string }
  | { kind: "calendarAgenda" }
  | { kind: "tasksList" }
  | { kind: "driveSearch"; query: string; pageSize?: number }
  | { kind: "peopleSearch"; query: string; pageSize?: number }
  | { kind: "applyGmailLabel"; messageId: string; labelName: string }
  | { kind: "sendEmail"; to: string; subject: string; body: string }
  | { kind: "archiveEmail"; messageId: string }
  | { kind: "deleteEmail"; messageId: string }
  | { kind: "createTask"; title: string; notes?: string; dueDate?: string }
  | { kind: "updateTask"; taskListId: string; taskId: string; title?: string; notes?: string }
  | { kind: "markTaskDone"; taskListId: string; taskId: string }
  | { kind: "deleteTask"; taskListId: string; taskId: string }
  | { kind: "createCalendarEvent"; summary: string; start: string; end: string }
  | { kind: "updateCalendarEvent"; calendarId: string; eventId: string; summary?: string }
  | { kind: "deleteCalendarEvent"; calendarId: string; eventId: string };

export type GmailSyncOptions = {
  userIntent?: string;
  query?: string;
  timeframeDays?: number;
  maxResults?: number;
};

export type GoogleCommandPlan = {
  executablePath: string;
  arguments: string[];
  environment: Record<string, string>;
  requiresApproval: boolean;
  displayCommand: string;
};

export type GoogleOAuthSetupStatus = {
  accountID: string;
  accountLabel: string;
  configPath: string;
  clientSecretPath: string;
  hasClientSecret: boolean;
  isLoggedIn: boolean;
  authMethod?: string;
  credentialStorage?: string;
  clientID?: string;
  projectID?: string;
  consentURL: string;
  credentialsURL: string;
  apiLibraryURL: string;
};

export type ConnectorLoginProgress = {
  sessionID: string;
  accountID: string;
  type: "start" | "stdout" | "stderr" | "error" | "close";
  text?: string;
  code?: number | null;
  signal?: string | null;
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
  | "knowledgeExternalAccessMode"
  | "knowledgeAgentAccessEnabled"
  | "knowledgeRealtimeVoiceAccessEnabled"
  | "knowledgeOrganizerEnabled"
  | "knowledgeServerPort"
  | "assistantTrackCodeChangesInGitRepos"
  | "archiveAutoDeleteDays"
  | "telegramEnabled"
  | "remoteAccessEnabled"
  | "remoteAccessNetworkMode"
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
  | {
      kind: "daily_items_batch";
      sourceItemID: string;
      sourceTitle: string;
      sourceTarget?: NoteLinkTarget;
      target: "backlog" | "day";
      dayID?: string;
      items: DailyItemInput[];
    }
  | { kind: "daily_item_delete"; dayID: string; itemID: string }
  | { kind: "reference_note_create"; ownerKind: "project" | "thread"; ownerId: string; title: string; markdown: string }
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
