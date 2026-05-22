/// <reference types="vite/client" />

interface Window {
  openAssistElectron?: {
    platform: string;
    openExternal: (url: string) => Promise<void>;
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
    listProviderModels: (backend: string) => Promise<import("./types").ProviderModelOption[]>;
    loadThread: (threadID: string) => Promise<import("./types").ThreadDetail>;
    createThread: (projectID?: string, isTemporary?: boolean) => Promise<{
      thread: import("./types").ThreadItem;
      detail: import("./types").ThreadDetail;
    }>;
    destroyTemporaryThread: (threadID: string) => Promise<{ ok: boolean }>;
    createProject: (
      name: string,
      kind: "project" | "folder",
      parentID?: string
    ) => Promise<import("./types").ProjectItem>;
    renameProject: (projectID: string, name: string) => Promise<import("./types").ProjectItem | null>;
    updateProjectIcon: (projectID: string, symbol?: string | null) => Promise<import("./types").ProjectItem | null>;
    chooseProjectFolder: (projectID: string) => Promise<import("./types").ProjectItem | null>;
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
    selectThreadNote: (threadID: string, noteID: string) => Promise<import("./types").ThreadNoteWorkspace>;
    loadThreadMemory: (threadID: string) => Promise<import("./types").ThreadMemorySnapshot>;
    setThreadProvider: (threadID: string, backend: string, modelID?: string) => Promise<import("./types").ThreadItem | null>;
    loadNote: (projectID: string, noteID: string) => Promise<import("./types").NoteDetail>;
    readNoteImageDataURL: (notePath: string, imageSrc: string) => Promise<string | null>;
    createNote: (projectID: string) => Promise<{ note: import("./types").NoteItem; detail: import("./types").NoteDetail }>;
    saveNote: (projectID: string, noteID: string, markdown: string) => Promise<import("./types").NoteDetail>;
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
    saveTelegramBotToken: (token: string) => Promise<import("./types").SettingsSnapshot>;
    clearTelegramBotToken: () => Promise<import("./types").SettingsSnapshot>;
    approveTelegramPairing: () => Promise<import("./types").SettingsSnapshot>;
    declineTelegramPairing: () => Promise<import("./types").SettingsSnapshot>;
    forgetTelegramPairing: () => Promise<import("./types").SettingsSnapshot>;
    testTelegramConnection: (token?: string) => Promise<{ ok: boolean; username?: string; message: string }>;
    sendMessage: (
      prompt: string,
      threadID?: string,
      pluginIDs?: string[],
      sessionInstructions?: string,
      reasoningEffort?: string,
      interactionMode?: string,
      permissionMode?: string,
      skillIDs?: string[],
      clientRunID?: string
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
      options?: { force?: boolean }
    ) => Promise<{ ok: boolean; skipped?: boolean; reason?: string; error?: string; engine?: string; path?: string }>;
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
      dictationStartSoundName?: string;
      dictationStopSoundName?: string;
      dictationProcessingSoundName?: string;
      dictationPastedSoundName?: string;
      dictationCorrectionLearnedSoundName?: string;
      dictationFeedbackVolume?: number;
    }) => Promise<{ ok: boolean; error?: string; modelID?: string; useCoreML?: boolean }>;
    stopVoiceInput: () => Promise<{ ok: boolean; text: string; error?: string }>;
    updateVoiceHUD: (payload: {
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
    }) => Promise<{ ok: boolean; visible: boolean; pending?: boolean }>;
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
    setScreenAnalysisFrameVisible: (visible: boolean) => Promise<{ ok: boolean; error?: string }>;
    setScreenAnalysisPanelCollapsed: (collapsed: boolean) => Promise<{ ok: boolean; error?: string }>;
    startScreenAnalysisAtSamePlace: () => Promise<{ ok: boolean; error?: string }>;
    completeScreenSelection: (rect: { x: number; y: number; width: number; height: number }) => Promise<{ ok: boolean }>;
    cancelScreenSelection: () => Promise<{ ok: boolean }>;
    setWindowMode: (mode: "full" | "sidebar", sidebarOpen?: boolean, sidebarEdge?: "left" | "right") => Promise<{ ok: boolean }>;
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
    onMenuBarCommand: (
      callback: (
        command: "open-assistant" | "speak-assistant-task" | "toggle-dictation" | "open-history" | "open-models" | "open-settings"
      ) => void
    ) => () => void;
  };
  openAssistRealtime?: {
    start: (options?: {
      threadId?: string;
      threadID?: string;
      provider?: string;
      interactionMode?: string;
      permissionMode?: string;
      reasoningEffort?: string;
    }) => Promise<{
      ok: boolean;
      threadId?: string;
      providerThreadId?: string;
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
    stop: () => Promise<{ ok: boolean; error?: string }>;
    stopDelegation: () => Promise<{ ok: boolean; error?: string }>;
    listVoices: () => Promise<{ ok: boolean; voices?: unknown; error?: string }>;
    onEvent: (callback: (event: { type: string; payload?: unknown }) => void) => () => void;
  };
}
