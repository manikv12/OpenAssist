/// <reference types="vite/client" />

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

type LocalFilePreview = {
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

interface Window {
  openAssistElectron?: {
    platform: string;
    openExternal: (url: string) => Promise<void>;
    getMacOSPermissions: () => Promise<{
      platformSupported: boolean;
      accessibility: "granted" | "denied" | "not-determined" | "unknown";
      screenRecording: "granted" | "denied" | "not-determined" | "unknown";
      microphone: "granted" | "denied" | "not-determined" | "unknown";
    }>;
    requestMacOSPermission: (
      kind: "accessibility" | "screenRecording" | "microphone" | "speechRecognition" | "automation" | "fullDiskAccess"
    ) => Promise<{ ok: boolean; opened: boolean; error?: string }>;
    getComputerUseActivity: () => Promise<{
      active: boolean;
      activeToolCalls: number;
      helpers: Array<{ pid: number; kind: string; elapsedSeconds: number }>;
      error?: string;
    }>;
    forceStopComputerUse: () => Promise<{
      stopped: boolean;
      killed: number[];
      restarted: boolean;
      error?: string;
    }>;
    openTarget: (target: string, workspaceRootPath?: string | null) => Promise<{ ok: boolean; path?: string; error?: string }>;
    workspaceLaunchTargets: () => Promise<Array<{
      id: string;
      title: string;
      isInstalled: boolean;
      remembersAsPreferred: boolean;
      fallbackSymbol: string;
      iconDataURL: string;
    }>>;
    readClipboardText: () => Promise<string>;
    writeClipboardText: (text: string) => Promise<{ ok: boolean }>;
    copyImageToClipboard: (source: { dataURL?: string; filePath?: string }) => Promise<{ ok: boolean; error?: string }>;
    getSpellcheckContext: () => Promise<{
      misspelledWord: string;
      suggestions: string[];
      isEditable: boolean;
      createdAt: number;
    } | null>;
    spellcheckWord: (word: string) => {
      misspelledWord: string;
      suggestions: string[];
      isEditable: boolean;
      createdAt: number;
    } | null;
    replaceMisspelling: (text: string) => Promise<{ ok: boolean; error?: string }>;
    insertTranscriptText: (text: string) => Promise<{
      ok: boolean;
      result: "pasted" | "typed" | "not-inserted" | "empty";
      error?: string;
      debugStatus?: string;
      method?: string;
      target?: {
        pid: number;
        bundleIdentifier: string;
        name: string;
        capturedAt: number;
      };
    }>;
    notifyThreadComplete: (payload: { threadID: string; title: string; body?: string }) => Promise<{ ok: boolean }>;
    onOpenThread: (callback: (threadID: string) => void) => (() => void);
    addTranscriptHistory: (text: string) => Promise<import("./types").TranscriptHistoryEntry[]>;
    loadTranscriptHistory: () => Promise<import("./types").TranscriptHistoryEntry[]>;
    deleteTranscriptHistoryEntry: (id: string) => Promise<import("./types").TranscriptHistoryEntry[]>;
    clearTranscriptHistory: () => Promise<import("./types").TranscriptHistoryEntry[]>;
    pasteTranscriptHistoryEntry: (id?: string) => Promise<{
      ok: boolean;
      result: "pasted" | "typed" | "not-inserted" | "empty";
      error?: string;
      debugStatus?: string;
      method?: string;
    }>;
    playDictationFeedbackSound: (
      cue: "startListening" | "stopListening" | "processing" | "pasted" | "correctionLearned"
    ) => Promise<{ ok: boolean; error?: string; skipped?: boolean; soundName?: string }>;
    openTranscriptHistoryWindow: () => Promise<{ ok: boolean }>;
    openSettingsWindow: (section?: string) => Promise<{ ok: boolean }>;
    onSettingsSection: (listener: (section: string) => void) => () => void;
    menuBarAction: (action: string) => Promise<{ ok: boolean }>;
    loadAppState: () => Promise<import("./types").OpenAssistAppState>;
    loadSettingsAppState: () => Promise<import("./types").OpenAssistAppState>;
    loadConnectorSnapshot: () => Promise<import("./types").ConnectorSnapshot>;
    loadConnectorReviewInbox: () => Promise<import("./types").ConnectorReviewInboxSnapshot>;
    appleEventKitStatus: () => Promise<import("./types").AppleEventKitStatus>;
    requestAppleEventKitAccess: (service: "reminders" | "calendar") => Promise<import("./types").AppleEventKitStatus>;
    createGoogleConnectorAccount: (label: string) => Promise<import("./types").ConnectorSnapshot>;
    removeGoogleConnectorAccount: (accountID: string) => Promise<import("./types").ConnectorSnapshot>;
    setConnectorServiceEnabled: (
      accountID: string,
      serviceID: import("./types").ConnectorServiceID,
      enabled: boolean
    ) => Promise<import("./types").ConnectorSnapshot>;
    installGoogleWorkspaceCLI: () => Promise<{
      ok: boolean;
      output: string;
      snapshot: import("./types").ConnectorSnapshot;
    }>;
    googleConnectorCommandPlan: (
      accountID: string,
      operation: import("./types").GoogleConnectorOperation,
      approved?: boolean
    ) => Promise<import("./types").GoogleCommandPlan>;
    googleConnectorOAuthStatus: (accountID: string) => Promise<import("./types").GoogleOAuthSetupStatus>;
    openGoogleConnectorOAuthPage: (
      accountID: string,
      page: "consent" | "credentials" | "apiLibrary"
    ) => Promise<{ ok: boolean; status: import("./types").GoogleOAuthSetupStatus }>;
    importGoogleConnectorClientSecret: (accountID: string) => Promise<{
      ok: boolean;
      cancelled?: boolean;
      status: import("./types").GoogleOAuthSetupStatus;
    }>;
    reuseGoogleConnectorClientSecret: (accountID: string) => Promise<{
      ok: boolean;
      status: import("./types").GoogleOAuthSetupStatus;
    }>;
    openGoogleConnectorConfigFolder: (accountID: string) => Promise<{
      ok: boolean;
      error?: string;
      status: import("./types").GoogleOAuthSetupStatus;
    }>;
    runGoogleConnectorSetup: (accountID: string) => Promise<{ ok: boolean; sessionID: string }>;
    runGoogleConnectorLogin: (accountID: string) => Promise<{ ok: boolean; sessionID: string }>;
    sendConnectorTerminalInput: (sessionID: string, input: string) => Promise<{ ok: boolean }>;
    stopConnectorTerminal: (sessionID: string) => Promise<{ ok: boolean; stopped: boolean }>;
    onConnectorLoginProgress: (
      callback: (payload: import("./types").ConnectorLoginProgress) => void
    ) => () => void;
    onConnectorSyncProgress: (
      callback: (payload: import("./types").ConnectorSyncProgress) => void
    ) => () => void;
    syncGmailConnector: (accountID: string, options?: import("./types").GmailSyncOptions) => Promise<{
      ok: boolean;
      importedCount: number;
      queries?: string[];
      reviewItems: import("./types").ConnectorItem[];
      snapshot: import("./types").ConnectorSnapshot;
    }>;
    markConnectorItem: (
      itemID: string,
      status: import("./types").ConnectorItemStatus
    ) => Promise<import("./types").ConnectorSnapshot>;
    ignoreConnectorReviewItems: (accountID?: string) => Promise<{
      count: number;
      snapshot: import("./types").ConnectorReviewInboxSnapshot;
    }>;
    saveConnectorItemToBacklog: (itemID: string) => Promise<{
      ok: boolean;
      result: import("./types").BacklogItemMutationResult;
      snapshot: import("./types").ConnectorSnapshot;
    }>;
    connectorSkillGuide: () => Promise<Array<{ id: import("./types").ConnectorServiceID; title: string; rules: string[] }>>;
    integrationStatus: () => Promise<import("./types").OpenAssistIntegrationStatus>;
    connectIntegration: (
      targetID: import("./types").OpenAssistIntegrationTargetID
    ) => Promise<import("./types").OpenAssistIntegrationConnectResult>;
    copyIntegrationConfig: (targetID: import("./types").OpenAssistIntegrationTargetID) => Promise<{ ok: boolean }>;
    revealIntegrationConfig: (targetID: import("./types").OpenAssistIntegrationTargetID) => Promise<{ ok: boolean; path?: string; error?: string }>;
    testIntegrationConnection: () => Promise<{
      ok: boolean;
      toolCount: number;
      mcpURL: string;
      mode: import("./types").KnowledgeExternalAccessMode;
      resourcesVisible: boolean;
    }>;
    integrationSkillGuide: (
      targetID?: import("./types").OpenAssistIntegrationTargetID
    ) => Promise<import("./types").OpenAssistIntegrationSkillGuide>;
    copyIntegrationSkill: (targetID?: import("./types").OpenAssistIntegrationTargetID) => Promise<{ ok: boolean; skillPath?: string }>;
    installIntegrationSkill: (
      targetID: import("./types").OpenAssistIntegrationTargetID
    ) => Promise<import("./types").OpenAssistIntegrationSkillInstallResult>;
    revealIntegrationSkill: (targetID?: import("./types").OpenAssistIntegrationTargetID) => Promise<{ ok: boolean; path?: string; error?: string }>;
    listProviderModels: (backend: string) => Promise<import("./types").ProviderModelOption[]>;
    listOllamaCatalogModels: () => Promise<import("./types").OllamaCatalogModelOption[]>;
    refreshOllamaWebsiteCatalog: () => Promise<{
      ok: boolean;
      models: import("./types").OllamaCatalogModelOption[];
      statusMessage: string;
    }>;
    pullOllamaModel: (modelID: string) => Promise<{ ok: boolean; modelID: string; models: import("./types").ProviderModelOption[] }>;
    deleteOllamaModel: (modelID: string) => Promise<{ ok: boolean; modelID: string; models: import("./types").ProviderModelOption[] }>;
    getOllamaRuntimeStatus: () => Promise<import("./types").OllamaRuntimeStatus>;
    startOllamaRuntime: () => Promise<{ ok: boolean; status: import("./types").OllamaRuntimeStatus }>;
    stopOllamaRuntime: () => Promise<{ ok: boolean; status: import("./types").OllamaRuntimeStatus }>;
    openOllamaDownloadPage: () => Promise<{ ok: boolean; url: string }>;
    updateOllamaRuntime: () => Promise<{
      ok: boolean;
      openedExternal?: boolean;
      status: import("./types").OllamaRuntimeStatus;
    }>;
    onOllamaRuntimeUpdateProgress: (
      callback: (progress: import("./types").OllamaRuntimeUpdateProgress) => void
    ) => () => void;
    onOllamaModelDownloadProgress: (
      callback: (progress: import("./types").OllamaModelDownloadProgress) => void
    ) => () => void;
    loadThread: (threadID: string) => Promise<import("./types").ThreadDetail>;
    loadOlderThreadMessages: (
      threadID: string,
      beforeMessageID: string,
      turnLimit?: number
    ) => Promise<import("./types").ThreadDetail>;
    loadCodeTrackingState: (threadID: string) => Promise<import("./types").CodeTrackingState>;
    openCodeReview: (threadID: string, checkpointID?: string) => Promise<import("./types").CodeReviewPanelState | null>;
    restoreCodeCheckpoint: (
      threadID: string,
      checkpointID: string
    ) => Promise<{ ok: boolean; state: import("./types").CodeTrackingState; panel: import("./types").CodeReviewPanelState | null }>;
    createThread: (projectID?: string, isTemporary?: boolean) => Promise<{
      thread: import("./types").ThreadItem;
      detail: import("./types").ThreadDetail;
    }>;
    destroyTemporaryThread: (threadID: string) => Promise<{ ok: boolean; kept?: boolean }>;
    createProject: (
      name: string,
      kind: "project" | "folder",
      parentID?: string
    ) => Promise<import("./types").ProjectItem>;
    renameProject: (projectID: string, name: string) => Promise<import("./types").ProjectItem | null>;
    updateProjectIcon: (projectID: string, symbol?: string | null) => Promise<import("./types").ProjectItem | null>;
    updateProjectArea: (projectID: string, area?: string | null) => Promise<import("./types").ProjectItem | null>;
    chooseProjectFolder: (projectID: string) => Promise<import("./types").ProjectItem | null>;
    openProjectFolder: (parentID?: string | null) => Promise<import("./types").ProjectItem | null>;
    removeProjectFolderLink: (projectID: string) => Promise<import("./types").ProjectItem | null>;
    moveProjectToFolder: (projectID: string, folderID?: string | null) => Promise<import("./types").ProjectItem | null>;
    hideProject: (projectID: string) => Promise<{ ok: boolean }>;
    unhideProject: (projectID: string) => Promise<import("./types").ProjectItem | null>;
    deleteProject: (projectID: string) => Promise<{ ok: boolean }>;
    loadProjectMemory: (projectID: string) => Promise<import("./types").ThreadMemorySnapshot>;
    renameSession: (threadID: string, title: string) => Promise<import("./types").ThreadItem | null>;
    promoteTemporarySession: (threadID: string) => Promise<import("./types").ThreadItem | null>;
    assignSessionToProject: (threadID: string, projectID?: string | null) => Promise<import("./types").ThreadItem | null>;
    archiveSession: (threadID: string) => Promise<import("./types").ThreadItem | null>;
    unarchiveSession: (threadID: string) => Promise<import("./types").ThreadItem | null>;
    deleteSessionPermanently: (threadID: string) => Promise<{ ok: boolean }>;
    loadThreadNote: (threadID: string) => Promise<import("./types").ThreadNoteWorkspace>;
	    createThreadNote: (threadID: string, title?: string) => Promise<import("./types").ThreadNoteWorkspace>;
	    saveThreadNote: (
	      threadID: string,
	      noteID: string | undefined,
	      markdown: string
	    ) => Promise<import("./types").ThreadNoteWorkspace>;
	    renameThreadNote: (
	      threadID: string,
	      noteID: string,
	      title: string
	    ) => Promise<import("./types").ThreadNoteWorkspace>;
	    selectThreadNote: (threadID: string, noteID: string) => Promise<import("./types").ThreadNoteWorkspace>;
    loadPlannerDay: (dayID?: string) => Promise<import("./types").PlannerDayDetail>;
    loadPlannerBacklog: () => Promise<import("./types").PlannerBacklogDetail>;
    listPlannerDays: (limit?: number, activeDayID?: string) => Promise<import("./types").PlannerDaySummary[]>;
    listPlannerCategories: () => Promise<import("./types").PlannerCategory[]>;
    listPlannerLists: () => Promise<import("./types").ProjectItem[]>;
    createPlannerList: (input: { name?: string; title?: string; area?: string; category?: string }) => Promise<{
      list: import("./types").ProjectItem;
      lists: import("./types").ProjectItem[];
      projects?: import("./types").ProjectItem[];
      hiddenProjects?: import("./types").ProjectItem[];
    }>;
    updatePlannerListColorAndArea: (projectID: string, area?: string | null, color?: string | null) => Promise<{
      list: import("./types").ProjectItem | null;
      lists: import("./types").ProjectItem[];
      projects?: import("./types").ProjectItem[];
      hiddenProjects?: import("./types").ProjectItem[];
    }>;
    hidePlannerList: (projectID: string) => Promise<import("./types").ProjectItem[]>;
    listPlannerSmartLists: () => Promise<import("./types").PlannerSmartListSummary[]>;
    listPlannerSmartListItems: (smartListID: string) => Promise<import("./types").PlannerSmartListDetail>;
    upsertPlannerCategory: (category: Partial<import("./types").PlannerCategory> & { name?: string }) => Promise<{
      category: import("./types").PlannerCategory;
      categories: import("./types").PlannerCategory[];
    }>;
    deletePlannerCategory: (categoryID: string) => Promise<import("./types").PlannerCategory[]>;
    savePlannerDay: (dayID: string | undefined, markdown: string) => Promise<import("./types").PlannerDayDetail>;
    scheduleSelectionToPlanner: (request: import("./types").PlannerScheduleRequest) => Promise<import("./types").PlannerDayDetail>;
    listDailyItems: (dayID?: string) => Promise<import("./types").DailyItem[]>;
    listBacklogItems: () => Promise<import("./types").DailyItem[]>;
    upsertDailyItem: (item: import("./types").DailyItemInput) => Promise<import("./types").DailyItemMutationResult>;
    toggleDailyItem: (dayID: string | undefined, itemID: string, checked: boolean) => Promise<import("./types").DailyItemMutationResult>;
    deleteDailyItem: (dayID: string | undefined, itemID: string) => Promise<import("./types").DailyItemMutationResult>;
    linkDailyItemNote: (
      dayID: string | undefined,
      itemID: string,
      target: import("./types").NoteLinkTarget
    ) => Promise<import("./types").DailyItemMutationResult | import("./types").BacklogItemMutationResult>;
    upsertBacklogItem: (item: import("./types").DailyItemInput) => Promise<import("./types").BacklogItemMutationResult>;
    toggleBacklogItem: (itemID: string, checked: boolean) => Promise<import("./types").BacklogItemMutationResult>;
    deleteBacklogItem: (itemID: string) => Promise<import("./types").BacklogItemMutationResult>;
    moveDailyItemToBacklog: (dayID: string | undefined, itemID: string) => Promise<import("./types").BacklogItemMutationResult>;
    scheduleBacklogItem: (itemID: string, targetDayID: string) => Promise<import("./types").BacklogItemMutationResult>;
    loadThreadMemory: (threadID: string) => Promise<import("./types").ThreadMemorySnapshot>;
    threadAgentFilesPath: (threadID: string) => Promise<{ ok: boolean; path?: string; error?: string }>;
    setThreadProvider: (threadID: string, backend: string, modelID?: string) => Promise<import("./types").ThreadItem | null>;
    loadNote: (projectID: string, noteID: string) => Promise<import("./types").NoteDetail>;
	    loadNoteLinks: (
	      target: import("./types").NoteLinkTarget,
	      currentMarkdown?: string
	    ) => Promise<import("./types").NoteLinksSnapshot>;
		    readNoteImageDataURL: (notePath: string, imageSrc: string) => Promise<string | null>;
		    cleanupNoteWithCodex: (request: import("./types").NoteAICleanupRequest) => Promise<import("./types").NoteAICleanupResult>;
		    openMarkdownFileForImport: () => Promise<import("./types").MarkdownImportFile | null>;
		    createNote: (projectID: string) => Promise<{ note: import("./types").NoteItem; detail: import("./types").NoteDetail }>;
		    renameNote: (projectID: string, noteID: string, title: string) => Promise<import("./types").NoteDetail>;
	    saveNote: (projectID: string, noteID: string, markdown: string) => Promise<import("./types").NoteDetail>;
	    listNoteHistory: (projectID: string, noteID: string) => Promise<import("./types").NoteHistoryItem[]>;
	    restoreNoteHistory: (
	      projectID: string,
	      noteID: string,
	      historyID: string
	    ) => Promise<import("./types").NoteDetail>;
	    deleteNote: (projectID: string, noteID: string) => Promise<{ projectID: string; archivedNoteID: string }>;
	    archiveNote: (projectID: string, noteID: string) => Promise<{ projectID: string; archivedNoteID: string }>;
	    restoreNote: (projectID: string, noteID: string) => Promise<{ projectID: string; restoredNoteID: string }>;
	    deleteNotePermanently: (projectID: string, noteID: string) => Promise<{ projectID: string; deletedNoteID: string }>;
	    createNoteFolder: (projectID: string, name: string, parentFolderID?: string | null) => Promise<import("./types").NoteFolderItem>;
	    renameNoteFolder: (projectID: string, folderID: string, name: string) => Promise<import("./types").NoteFolderItem>;
	    deleteNoteFolder: (projectID: string, folderID: string) => Promise<{ projectID: string; deletedFolderID: string; deletedFolderIDs?: string[] }>;
	    moveNoteFolder: (projectID: string, folderID: string, parentFolderID: string | null) => Promise<import("./types").NoteFolderItem>;
	    moveNoteToFolder: (projectID: string, noteID: string, folderID: string | null) => Promise<{ projectID: string; noteID: string; folderID: string | null }>;
	    deleteThreadNote: (threadID: string, noteID: string) => Promise<import("./types").ThreadNoteWorkspace>;
	    archiveThreadNote: (threadID: string, noteID: string) => Promise<import("./types").ThreadNoteWorkspace>;
	    restoreThreadNote: (threadID: string, noteID: string) => Promise<import("./types").ThreadNoteWorkspace>;
	    deleteThreadNotePermanently: (threadID: string, noteID: string) => Promise<import("./types").ThreadNoteWorkspace>;
    toggleSkill: (threadID: string, skillID: string, attached: boolean) => Promise<{ ok: boolean }>;
    importSkillFolder: () => Promise<import("./types").SkillItem | null>;
    importSkillFromGitHub: (reference: string) => Promise<import("./types").SkillItem>;
    createSkill: (name: string, description: string) => Promise<import("./types").SkillItem>;
    createScheduledJob: (name: string, prompt: string) => Promise<import("./types").AutomationItem>;
    toggleScheduledJob: (jobID: string, enabled: boolean) => Promise<{ ok: boolean }>;
		    updateSetting: (
		      key: import("./types").SettingsUpdateKey,
		      value: import("./types").SettingsUpdateValue
		    ) => Promise<import("./types").SettingsSnapshot>;
		    updateSettings: (
		      updates: Array<{
		        key: import("./types").SettingsUpdateKey;
		        value: import("./types").SettingsUpdateValue;
		      }>
		    ) => Promise<import("./types").SettingsSnapshot>;
		    previewColorTheme: (theme: string | null) => Promise<{ ok: boolean }>;
		    knowledgeStatus: () => Promise<import("./types").KnowledgeStatus>;
	    listKnowledgeRequests: (
	      status?: "pending" | "applied" | "rejected"
	    ) => Promise<import("./types").KnowledgeWriteRequest[]>;
	    applyKnowledgePreview: (
	      requestID: string
	    ) => Promise<import("./types").KnowledgeWriteRequest>;
	    rejectKnowledgeRequest: (
	      requestID: string
	    ) => Promise<import("./types").KnowledgeWriteRequest>;
	    updateShortcut: (
      target: "holdToTalk" | "continuousToggle" | "assistantLiveVoice" | "assistantCompact" | "screenAnalysis",
      keyCode: number,
      modifiers: number
    ) => Promise<import("./types").SettingsSnapshot>;
    savePromptRewriteAPIKey: (provider: string, token: string) => Promise<import("./types").SettingsSnapshot>;
    clearPromptRewriteAPIKey: (provider: string) => Promise<import("./types").SettingsSnapshot>;
    saveCloudTranscriptionAPIKey: (provider: string, token: string) => Promise<import("./types").SettingsSnapshot>;
    clearCloudTranscriptionAPIKey: (provider: string) => Promise<import("./types").SettingsSnapshot>;
    saveRealtimeOpenAIAPIKey: (token: string) => Promise<import("./types").SettingsSnapshot>;
    clearRealtimeOpenAIAPIKey: () => Promise<import("./types").SettingsSnapshot>;
    saveRealtimeGeminiAPIKey: (token: string) => Promise<import("./types").SettingsSnapshot>;
    clearRealtimeGeminiAPIKey: () => Promise<import("./types").SettingsSnapshot>;
    saveTelegramBotToken: (token: string) => Promise<import("./types").SettingsSnapshot>;
    clearTelegramBotToken: () => Promise<import("./types").SettingsSnapshot>;
    approveTelegramPairing: () => Promise<import("./types").SettingsSnapshot>;
    declineTelegramPairing: () => Promise<import("./types").SettingsSnapshot>;
    forgetTelegramPairing: () => Promise<import("./types").SettingsSnapshot>;
    testTelegramConnection: (token?: string) => Promise<{ ok: boolean; username?: string; message: string }>;
    rotateRemoteAccessPairingCode: () => Promise<import("./types").SettingsSnapshot>;
    clearRemoteAccessPairingCode: () => Promise<import("./types").SettingsSnapshot>;
    startRemoteAccessEasyQR: () => Promise<import("./types").SettingsSnapshot>;
    stopRemoteAccessEasyQR: () => Promise<import("./types").SettingsSnapshot>;
    getRemoteAccessStatus: () => Promise<Partial<import("./types").SettingsSnapshot>>;
    sendMessage: (
      prompt: string,
      threadID?: string,
      pluginIDs?: string[],
      sessionInstructions?: string,
      reasoningEffort?: string,
      interactionMode?: string,
      permissionMode?: string,
      skillIDs?: string[],
      clientRunID?: string,
      attachments?: import("./types").ComposerImageAttachment[]
    ) => Promise<{
      threadID: string;
      title?: string;
      thread?: import("./types").ThreadItem;
      user: import("./types").ChatMessage;
      assistant: import("./types").ChatMessage;
    }>;
    codexRuntimeParityProbe: (options?: {
      prompt?: string;
      cwd?: string;
      pluginIDs?: string[];
      skillIDs?: string[];
      sessionInstructions?: string;
      reasoningEffort?: string;
      interactionMode?: string;
      permissionMode?: string;
      modelID?: string;
    }) => Promise<{
      threadStart: Record<string, unknown>;
      threadResume: Record<string, unknown>;
      turnStart: Record<string, unknown>;
      pluginItems: Array<Record<string, unknown>>;
      desktopToolSuppression: { baseline: string[]; filtered: string[] };
      approvalProbes: Record<string, unknown>;
    }>;
    stopMessage: (clientRunID?: string) => Promise<{ ok: boolean; error?: string; interrupted?: boolean; restarted?: boolean; restartError?: string }>;
    respondProviderRequest: (requestID: string | number, result: unknown) => Promise<{ ok: boolean; error?: string }>;
    installKokoroVoiceModel: (voiceID?: string) => Promise<import("./types").SettingsSnapshot>;
    speakAssistantResponse: (
      text: string,
      options?: { force?: boolean; engine?: string; voice?: string }
    ) => Promise<{ ok: boolean; skipped?: boolean; reason?: string; error?: string; engine?: string; path?: string }>;
    prepareReadAloudAudio: (
      text: string,
      options?: { engine?: string; voice?: string; model?: string }
    ) => Promise<import("./types").ReadAloudAudioResult>;
    startNoteReadAloud: (
      request: import("./types").NoteReadAloudRequest
    ) => Promise<import("./types").NoteReadAloudState>;
    pauseNoteReadAloud: () => Promise<import("./types").NoteReadAloudState>;
    resumeNoteReadAloud: () => Promise<import("./types").NoteReadAloudState>;
    stopNoteReadAloud: () => Promise<import("./types").NoteReadAloudState>;
    onNoteReadAloudState: (callback: (state: import("./types").NoteReadAloudState) => void) => () => void;
    startWakeWordForToday: (options?: {
      phrase?: string;
      autoDetectMicrophone?: boolean;
      selectedMicrophoneUID?: string;
    }) => Promise<{ ok: boolean; status: import("./types").WakeWordStatus; error?: string }>;
    stopWakeWordForToday: (reason?: string) => Promise<{ ok: boolean; status: import("./types").WakeWordStatus }>;
    getWakeWordStatus: () => Promise<import("./types").WakeWordStatus>;
    onWakeWordStatus: (callback: (status: import("./types").WakeWordStatus) => void) => () => void;
    prewarmAssistantVoiceOutput: (
      options?: { engine?: string; voice?: string }
    ) => Promise<{ ok: boolean; skipped?: boolean; reason?: string; error?: string }>;
    stopAssistantVoiceOutput: () => Promise<{ ok: boolean }>;
    onProviderEvent: (callback: (event: import("./types").ProviderRunEvent) => void) => () => void;
    voiceInputConfiguration: () => Promise<{
      transcriptionEngine: string;
      whisperModel: string;
      whisperUseCoreML: boolean;
      whisperModelInstalled: boolean;
      whisperInstalledModels: string[];
      cloudTranscriptionProvider: string;
      cloudTranscriptionModel: string;
      cloudTranscriptionBaseURL: string;
      cloudTranscriptionProviderRequiresKey: boolean;
      cloudTranscriptionAPIKeyConfigured: boolean;
      dictationStartSoundName: string;
      dictationStopSoundName: string;
      dictationProcessingSoundName: string;
      dictationPastedSoundName: string;
      dictationCorrectionLearnedSoundName: string;
      dictationFeedbackVolume: number;
      autoDetectMicrophone: boolean;
      selectedMicrophoneUID: string;
      availableMicrophones: Array<{ uid: string; name: string; isDefault?: boolean }>;
    }>;
    listMicrophones: () => Promise<Array<{ uid: string; name: string; isDefault?: boolean }>>;
    startVoiceInput: (options?: {
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
    }) => Promise<{ ok: boolean; error?: string; modelID?: string; useCoreML?: boolean }>;
    stopVoiceInput: () => Promise<{ ok: boolean; text: string; error?: string }>;
    localVoiceTranscribe: (input: {
      audioBase64?: string;
      fileName?: string;
      mimeType?: string;
      transcriptionEngine?: string;
      cloudTranscriptionProvider?: string;
      cloudTranscriptionAPIKeyConfigured?: boolean;
      whisperModel?: string;
      whisperUseCoreML?: boolean;
    }) => Promise<{ ok: boolean; text: string; error?: string; engine?: string; modelID?: string; useCoreML?: boolean }>;
    classifyLocalVoiceTranscript: (input: {
      transcript: string;
      lastUserTask?: string;
      agentRunning?: boolean;
      surface?: string;
      voiceState?: string;
    }) => Promise<{
      decision: "ignore" | "follow_up" | "new_task" | "clarify" | "control";
      taskText: string;
      confidence: number;
      reason: string;
    }>;
    handleLocalVoiceDirectKnowledge: (input: {
      transcript?: string;
      taskText?: string;
    }) => Promise<{
      handled: boolean;
      route?: string;
      responseText?: string;
      reason?: string;
    }>;
    updateVoiceHUD: (payload: {
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
      workText?: string;
      muted?: boolean;
      approval?: { requestID: string; summary?: string } | null;
    }) => Promise<{ ok: boolean; visible: boolean; pending?: boolean }>;
    liveVoiceHUDAction: (action: "toggleMute" | "stop" | "approveRequest" | "rejectRequest") => Promise<{ ok: boolean }>;
    onLiveVoiceHUDAction: (callback: (action: "toggleMute" | "stop" | "approveRequest" | "rejectRequest") => void) => (() => void);
    submitScreenAnalysis: (instruction: string, options?: { readback?: boolean }) => Promise<{ ok: boolean }>;
    cancelScreenAnalysis: () => Promise<{ ok: boolean }>;
    chooseScreenAnalysisReferenceImages: () => Promise<{
      ok: boolean;
      attachments: Array<{ name: string; previewDataURL: string }>;
      error?: string;
    }>;
    addScreenAnalysisReferenceFromDataURL: (dataURL: string, name?: string) => Promise<{
      ok: boolean;
      attachments: Array<{ name: string; previewDataURL: string }>;
      error?: string;
    }>;
    removeScreenAnalysisReference: (index: number) => Promise<{
      ok: boolean;
      attachments?: Array<{ name: string; previewDataURL: string }>;
      error?: string;
    }>;
    openImageInPreview: (dataURL: string) => Promise<{ ok: boolean; error?: string }>;
    saveImage: (dataURL: string, defaultName?: string) => Promise<{ ok: boolean; path?: string; canceled?: boolean; error?: string }>;
    openLocalPath: (filePath: string) => Promise<{ ok: boolean; path?: string; error?: string }>;
    getLocalFilePreview: (filePath: string) => Promise<LocalFilePreview>;
    revealLocalPath: (filePath: string) => Promise<{ ok: boolean; path?: string; error?: string }>;
    setScreenAnalysisFrameVisible: (visible: boolean) => Promise<{ ok: boolean; error?: string }>;
    setScreenAnalysisPanelCollapsed: (collapsed: boolean) => Promise<{ ok: boolean; error?: string }>;
    startScreenAnalysisAtSamePlace: () => Promise<{ ok: boolean; error?: string }>;
    completeScreenSelection: (rect: { x: number; y: number; width: number; height: number }) => Promise<{ ok: boolean }>;
    cancelScreenSelection: () => Promise<{ ok: boolean }>;
	    setWindowMode: (
	      mode: "full" | "sidebar" | "notch",
	      sidebarOpen?: boolean,
	      sidebarEdge?: "left" | "right",
	      notchDockRevealed?: boolean
	    ) => Promise<{ ok: boolean }>;
    hideWindow: () => Promise<{ ok: boolean }>;
    setSidebarPinned: (pinned: boolean) => Promise<{ ok: boolean }>;
    onSidebarShortcutToggle: (callback: () => void) => () => void;
    onSidebarBlurCollapse: (
      callback: (state?: { sidebarOpen?: boolean; sidebarEdge?: "left" | "right" }) => void
    ) => () => void;
    onVoiceShortcut: (
      callback: (
        target: "holdToTalk" | "continuousToggle" | "assistantLiveVoice" | "assistantCompact" | "screenAnalysis",
        phase?: "trigger" | "down" | "up"
      ) => void
    ) => () => void;
    onNavigationCommand: (callback: (direction: "back" | "forward") => void) => () => void;
    onMenuBarCommand: (
      callback: (
        command: "open-assistant" | "new-chat" | "speak-assistant-task" | "toggle-dictation" | "open-history" | "open-today" | "open-models" | "open-settings"
      ) => void
    ) => () => void;
    setMenuBarState?: (state: {
      runs: Array<{ title: string; provider: string; statusText: string; startedAt: number }>;
      unreadCount: number;
      threadCount: number;
    }) => void;
    menuBarReportHeight?: (height: number) => void;
    onThreadsUpdated: (callback: () => void) => () => void;
    onSettingsUpdated: (callback: (settings: unknown) => void) => () => void;
    onColorThemePreview: (callback: (theme: string | null) => void) => () => void;
    onAppStateBackgroundUpdate: (callback: (update: unknown) => void) => () => void;
  };
  openAssistRealtime?: {
    start: (options?: {
      threadId?: string;
      threadID?: string;
      provider?: string;
      interactionMode?: string;
      permissionMode?: string;
      reasoningEffort?: string;
      pluginIDs?: string[];
      skillIDs?: string[];
      contextHint?: string;
	    }) => Promise<{
	      ok: boolean;
	      threadId?: string;
	      providerThreadId?: string;
	      thread?: import("./types").ThreadItem;
	      error?: string;
	    }>;
    appendAudio: (chunk: {
      data: string;
      sampleRate: number;
      numChannels: number;
      samplesPerChannel: number | null;
      itemId: string | null;
    }) => Promise<{ ok: boolean; error?: string }>;
    appendText: (text: string) => Promise<{ ok: boolean; error?: string }>;
    appendImages: (input: {
      images: import("./types").ComposerImageAttachment[];
      text?: string;
      createResponse?: boolean;
    }) => Promise<{ ok: boolean; sent?: number; error?: string }>;
    stop: () => Promise<{ ok: boolean; error?: string }>;
    stopDelegation: () => Promise<{ ok: boolean; error?: string }>;
    listVoices: () => Promise<{ ok: boolean; voices?: unknown; error?: string }>;
    onEvent: (callback: (event: { type: string; payload?: unknown }) => void) => () => void;
  };
}
