import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("openAssistElectron", {
  platform: process.platform,
  openExternal: (url: string) => ipcRenderer.invoke("open-external", url),
  getMacOSPermissions: () => ipcRenderer.invoke("openassist:get-macos-permissions"),
  requestMacOSPermission: (kind: string) => ipcRenderer.invoke("openassist:request-macos-permission", kind),
  openTarget: (target: string, workspaceRootPath?: string | null) => ipcRenderer.invoke("openassist:open-target", target, workspaceRootPath),
  workspaceLaunchTargets: () => ipcRenderer.invoke("openassist:workspace-launch-targets"),
  readClipboardText: () => ipcRenderer.invoke("openassist:read-clipboard-text"),
  writeClipboardText: (text: string) => ipcRenderer.invoke("openassist:write-clipboard-text", text),
  insertTranscriptText: (text: string) => ipcRenderer.invoke("openassist:insert-transcript-text", text),
  addTranscriptHistory: (text: string) => ipcRenderer.invoke("openassist:add-transcript-history", text),
  loadTranscriptHistory: () => ipcRenderer.invoke("openassist:load-transcript-history"),
  deleteTranscriptHistoryEntry: (id: string) => ipcRenderer.invoke("openassist:delete-transcript-history-entry", id),
  clearTranscriptHistory: () => ipcRenderer.invoke("openassist:clear-transcript-history"),
  pasteTranscriptHistoryEntry: (id?: string) => ipcRenderer.invoke("openassist:paste-transcript-history-entry", id),
  playDictationFeedbackSound: (cue: "startListening" | "stopListening" | "processing" | "pasted" | "correctionLearned") =>
    ipcRenderer.invoke("openassist:play-dictation-feedback-sound", cue),
  openTranscriptHistoryWindow: () => ipcRenderer.invoke("openassist:open-transcript-history-window"),
  openSettingsWindow: (section?: string) => ipcRenderer.invoke("openassist:open-settings-window", section),
  onSettingsSection: (listener: (section: string) => void) => {
    const wrapped = (_event: Electron.IpcRendererEvent, section: string) => listener(section);
    ipcRenderer.on("openassist:settings-section", wrapped);
    return () => ipcRenderer.removeListener("openassist:settings-section", wrapped);
  },
  menuBarAction: (action: string) => ipcRenderer.invoke("openassist:menu-bar-action", action),
  loadAppState: () => ipcRenderer.invoke("openassist:load-app-state"),
  listProviderModels: (backend: string) => ipcRenderer.invoke("openassist:list-provider-models", backend),
  loadThread: (threadID: string) => ipcRenderer.invoke("openassist:load-thread", threadID),
  loadCodeTrackingState: (threadID: string) => ipcRenderer.invoke("openassist:load-code-tracking-state", threadID),
  openCodeReview: (threadID: string, checkpointID?: string) => ipcRenderer.invoke("openassist:open-code-review", threadID, checkpointID),
  restoreCodeCheckpoint: (threadID: string, checkpointID: string) =>
    ipcRenderer.invoke("openassist:restore-code-checkpoint", threadID, checkpointID),
  loadThreadNote: (threadID: string) => ipcRenderer.invoke("openassist:load-thread-note", threadID),
  createThreadNote: (threadID: string, title?: string) => ipcRenderer.invoke("openassist:create-thread-note", threadID, title),
  saveThreadNote: (threadID: string, noteID: string | undefined, markdown: string) =>
    ipcRenderer.invoke("openassist:save-thread-note", threadID, noteID, markdown),
  selectThreadNote: (threadID: string, noteID: string) => ipcRenderer.invoke("openassist:select-thread-note", threadID, noteID),
  loadThreadMemory: (threadID: string) => ipcRenderer.invoke("openassist:load-thread-memory", threadID),
  setThreadProvider: (threadID: string, backend: string, modelID?: string) =>
    ipcRenderer.invoke("openassist:set-thread-provider", threadID, backend, modelID),
  createThread: (projectID?: string, isTemporary?: boolean) => ipcRenderer.invoke("openassist:create-thread", projectID, isTemporary),
  destroyTemporaryThread: (threadID: string) => ipcRenderer.invoke("openassist:destroy-temporary-thread", threadID),
  createProject: (name: string, kind: "project" | "folder", parentID?: string) =>
    ipcRenderer.invoke("openassist:create-project", name, kind, parentID),
  renameProject: (projectID: string, name: string) => ipcRenderer.invoke("openassist:rename-project", projectID, name),
  updateProjectIcon: (projectID: string, symbol?: string | null) => ipcRenderer.invoke("openassist:update-project-icon", projectID, symbol),
  chooseProjectFolder: (projectID: string) => ipcRenderer.invoke("openassist:choose-project-folder", projectID),
  removeProjectFolderLink: (projectID: string) => ipcRenderer.invoke("openassist:remove-project-folder-link", projectID),
  moveProjectToFolder: (projectID: string, folderID?: string | null) =>
    ipcRenderer.invoke("openassist:move-project-to-folder", projectID, folderID),
  hideProject: (projectID: string) => ipcRenderer.invoke("openassist:hide-project", projectID),
  unhideProject: (projectID: string) => ipcRenderer.invoke("openassist:unhide-project", projectID),
  deleteProject: (projectID: string) => ipcRenderer.invoke("openassist:delete-project", projectID),
  loadProjectMemory: (projectID: string) => ipcRenderer.invoke("openassist:load-project-memory", projectID),
  renameSession: (threadID: string, title: string) => ipcRenderer.invoke("openassist:rename-session", threadID, title),
  promoteTemporarySession: (threadID: string) => ipcRenderer.invoke("openassist:promote-temporary-session", threadID),
  assignSessionToProject: (threadID: string, projectID?: string | null) =>
    ipcRenderer.invoke("openassist:assign-session-to-project", threadID, projectID),
  archiveSession: (threadID: string) => ipcRenderer.invoke("openassist:archive-session", threadID),
  unarchiveSession: (threadID: string) => ipcRenderer.invoke("openassist:unarchive-session", threadID),
  deleteSessionPermanently: (threadID: string) => ipcRenderer.invoke("openassist:delete-session-permanently", threadID),
  loadNote: (projectID: string, noteID: string) => ipcRenderer.invoke("openassist:load-note", projectID, noteID),
  readNoteImageDataURL: (notePath: string, imageSrc: string) => ipcRenderer.invoke("openassist:read-note-image", notePath, imageSrc),
  createNote: (projectID: string) => ipcRenderer.invoke("openassist:create-note", projectID),
  saveNote: (projectID: string, noteID: string, markdown: string) =>
    ipcRenderer.invoke("openassist:save-note", projectID, noteID, markdown),
  toggleSkill: (threadID: string, skillID: string, attached: boolean) =>
    ipcRenderer.invoke("openassist:toggle-skill", threadID, skillID, attached),
  importSkillFolder: () => ipcRenderer.invoke("openassist:import-skill-folder"),
  importSkillFromGitHub: (reference: string) => ipcRenderer.invoke("openassist:import-skill-github", reference),
  createSkill: (name: string, description: string) => ipcRenderer.invoke("openassist:create-skill", name, description),
  createScheduledJob: (name: string, prompt: string) =>
    ipcRenderer.invoke("openassist:create-scheduled-job", name, prompt),
  toggleScheduledJob: (jobID: string, enabled: boolean) =>
    ipcRenderer.invoke("openassist:toggle-scheduled-job", jobID, enabled),
  updateSetting: (key: string, value: boolean | string | number) =>
    ipcRenderer.invoke("openassist:update-setting", key, value),
  updateShortcut: (target: string, keyCode: number, modifiers: number) =>
    ipcRenderer.invoke("openassist:update-shortcut", target, keyCode, modifiers),
  savePromptRewriteAPIKey: (provider: string, token: string) =>
    ipcRenderer.invoke("openassist:save-prompt-rewrite-api-key", provider, token),
  clearPromptRewriteAPIKey: (provider: string) =>
    ipcRenderer.invoke("openassist:clear-prompt-rewrite-api-key", provider),
  saveCloudTranscriptionAPIKey: (provider: string, token: string) =>
    ipcRenderer.invoke("openassist:save-cloud-transcription-api-key", provider, token),
  clearCloudTranscriptionAPIKey: (provider: string) =>
    ipcRenderer.invoke("openassist:clear-cloud-transcription-api-key", provider),
  saveRealtimeOpenAIAPIKey: (token: string) =>
    ipcRenderer.invoke("openassist:save-realtime-openai-api-key", token),
  clearRealtimeOpenAIAPIKey: () =>
    ipcRenderer.invoke("openassist:clear-realtime-openai-api-key"),
  saveTelegramBotToken: (token: string) => ipcRenderer.invoke("openassist:save-telegram-bot-token", token),
  clearTelegramBotToken: () => ipcRenderer.invoke("openassist:clear-telegram-bot-token"),
  approveTelegramPairing: () => ipcRenderer.invoke("openassist:approve-telegram-pairing"),
  declineTelegramPairing: () => ipcRenderer.invoke("openassist:decline-telegram-pairing"),
  forgetTelegramPairing: () => ipcRenderer.invoke("openassist:forget-telegram-pairing"),
  testTelegramConnection: (token?: string) => ipcRenderer.invoke("openassist:test-telegram-connection", token),
  sendMessage: (prompt: string, threadID?: string, pluginIDs?: string[], sessionInstructions?: string, reasoningEffort?: string, interactionMode?: string, permissionMode?: string, skillIDs?: string[], clientRunID?: string, attachments?: unknown[]) =>
    ipcRenderer.invoke("openassist:send-message", prompt, threadID, pluginIDs, sessionInstructions, reasoningEffort, interactionMode, permissionMode, skillIDs, clientRunID, attachments),
  codexRuntimeParityProbe: (options?: unknown) => ipcRenderer.invoke("openassist:codex-runtime-parity-probe", options),
  stopMessage: (clientRunID?: string) => ipcRenderer.invoke("openassist:stop-message", clientRunID),
  respondProviderRequest: (requestID: string | number, result: unknown) =>
    ipcRenderer.invoke("openassist:respond-provider-request", requestID, result),
  installKokoroVoiceModel: (voiceID?: string) =>
    ipcRenderer.invoke("openassist:install-kokoro-voice-model", voiceID),
  speakAssistantResponse: (text: string, options?: { force?: boolean }) =>
    ipcRenderer.invoke("openassist:speak-assistant-response", text, options),
  stopAssistantVoiceOutput: () => ipcRenderer.invoke("openassist:stop-assistant-voice-output"),
  onProviderEvent: (callback: (event: unknown) => void) => {
    const listener = (_event: unknown, payload: unknown) => callback(payload);
    ipcRenderer.on("openassist:provider-event", listener);
    return () => ipcRenderer.off("openassist:provider-event", listener);
  },
  voiceInputConfiguration: () => ipcRenderer.invoke("openassist:voice-input-configuration"),
  listMicrophones: () => ipcRenderer.invoke("openassist:list-microphones"),
  startVoiceInput: (options?: {
    transcriptionEngine?: string;
    cloudTranscriptionProvider?: string;
    cloudTranscriptionAPIKeyConfigured?: boolean;
    autoDetectMicrophone?: boolean;
    selectedMicrophoneUID?: string;
    whisperModel?: string;
    whisperUseCoreML?: boolean;
  }) => ipcRenderer.invoke("openassist:start-voice-input", options),
  stopVoiceInput: () => ipcRenderer.invoke("openassist:stop-voice-input"),
  updateVoiceHUD: (payload: {
    visible?: boolean;
    status?: string;
    text?: string;
    theme?: string;
    colorTheme?: string;
    chromeStyle?: string;
    level?: number;
    tone?: string;
    source?: string;
    replacement?: string;
    previewDataURL?: string;
    suppressForAppFocus?: boolean;
  }) =>
    ipcRenderer.invoke("openassist:update-voice-hud", payload),
  submitScreenAnalysis: (instruction: string, options?: { readback?: boolean }) =>
    ipcRenderer.invoke("openassist:submit-screen-analysis", instruction, options),
  cancelScreenAnalysis: () =>
    ipcRenderer.invoke("openassist:cancel-screen-analysis"),
  chooseScreenAnalysisReferenceImages: () =>
    ipcRenderer.invoke("openassist:choose-screen-analysis-reference-images"),
  addScreenAnalysisReferenceFromDataURL: (dataURL: string, name?: string) =>
    ipcRenderer.invoke("openassist:add-screen-analysis-reference-from-data-url", dataURL, name),
  removeScreenAnalysisReference: (index: number) =>
    ipcRenderer.invoke("openassist:remove-screen-analysis-reference", index),
  openImageInPreview: (dataURL: string) =>
    ipcRenderer.invoke("openassist:open-image-in-preview", dataURL),
  saveImage: (dataURL: string, defaultName?: string) =>
    ipcRenderer.invoke("openassist:save-image", dataURL, defaultName),
  openLocalPath: (filePath: string) =>
    ipcRenderer.invoke("openassist:open-local-path", filePath),
  revealLocalPath: (filePath: string) =>
    ipcRenderer.invoke("openassist:reveal-local-path", filePath),
  setScreenAnalysisFrameVisible: (visible: boolean) =>
    ipcRenderer.invoke("openassist:set-screen-analysis-frame-visible", visible),
  setScreenAnalysisPanelCollapsed: (collapsed: boolean) =>
    ipcRenderer.invoke("openassist:set-screen-analysis-panel-collapsed", collapsed),
  startScreenAnalysisAtSamePlace: () =>
    ipcRenderer.invoke("openassist:start-screen-analysis-at-same-place"),
  listScreenSnipPresets: () =>
    ipcRenderer.invoke("openassist:list-screen-snip-presets"),
  setScreenSnipTheme: (theme: string) =>
    ipcRenderer.invoke("openassist:set-screen-snip-theme", theme),
  completeScreenSelection: (rect: { x: number; y: number; width: number; height: number }) =>
    ipcRenderer.invoke("openassist:complete-screen-selection", rect),
  cancelScreenSelection: () =>
    ipcRenderer.invoke("openassist:cancel-screen-selection"),
  setScreenAnalysisFrameInteractive: (interactive: boolean) =>
    ipcRenderer.invoke("openassist:set-screen-analysis-frame-interactive", interactive),
  setWindowMode: (mode: "full" | "sidebar", sidebarOpen?: boolean, sidebarEdge?: "left" | "right") =>
    ipcRenderer.invoke("openassist:set-window-mode", mode, sidebarOpen, sidebarEdge),
  hideWindow: () => ipcRenderer.invoke("openassist:hide-window"),
  setSidebarPinned: (pinned: boolean) => ipcRenderer.invoke("openassist:set-sidebar-pinned", pinned),
  onSidebarShortcutToggle: (callback: () => void) => {
    const listener = () => callback();
    ipcRenderer.on("openassist:toggle-sidebar-shortcut", listener);
    return () => ipcRenderer.removeListener("openassist:toggle-sidebar-shortcut", listener);
  },
  onSidebarBlurCollapse: (callback: (state?: { sidebarOpen?: boolean; sidebarEdge?: "left" | "right" }) => void) => {
    const listener = (
      _event: Electron.IpcRendererEvent,
      state?: { sidebarOpen?: boolean; sidebarEdge?: "left" | "right" }
    ) => callback(state);
    ipcRenderer.on("openassist:sidebar-blur-collapse", listener);
    return () => ipcRenderer.removeListener("openassist:sidebar-blur-collapse", listener);
  },
  onVoiceShortcut: (callback: (target: string, phase?: "trigger" | "down" | "up") => void) => {
    const listener = (_event: Electron.IpcRendererEvent, target: string, phase?: "trigger" | "down" | "up") =>
      callback(target, phase);
    ipcRenderer.on("openassist:voice-shortcut", listener);
    return () => ipcRenderer.removeListener("openassist:voice-shortcut", listener);
  },
  onMenuBarCommand: (callback: (command: string) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, command: string) => callback(command);
    ipcRenderer.on("openassist:menu-bar-command", listener);
    return () => ipcRenderer.removeListener("openassist:menu-bar-command", listener);
  },
  onThreadsUpdated: (callback: () => void) => {
    const listener = () => callback();
    ipcRenderer.on("openassist:threads-updated", listener);
    return () => ipcRenderer.removeListener("openassist:threads-updated", listener);
  }
});

contextBridge.exposeInMainWorld("openAssistRealtime", {
  start: (options?: {
    threadId?: string;
    threadID?: string;
    provider?: string;
    interactionMode?: string;
    permissionMode?: string;
    reasoningEffort?: string;
    pluginIDs?: string[];
    skillIDs?: string[];
  }) =>
    ipcRenderer.invoke("openassist:realtime-start", options),
  appendAudio: (chunk: {
    data: string;
    sampleRate: number;
    numChannels: number;
    samplesPerChannel: number | null;
    itemId: string | null;
  }) => ipcRenderer.invoke("openassist:realtime-append-audio", chunk),
  appendText: (text: string) => ipcRenderer.invoke("openassist:realtime-append-text", text),
  stop: () => ipcRenderer.invoke("openassist:realtime-stop"),
  stopDelegation: () => ipcRenderer.invoke("openassist:realtime-stop-delegation"),
  listVoices: () => ipcRenderer.invoke("openassist:realtime-list-voices"),
  onEvent: (callback: (event: { type: string; payload?: unknown }) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, payload: { type: string; payload?: unknown }) => callback(payload);
    ipcRenderer.on("openassist:realtime-event", listener);
    return () => ipcRenderer.removeListener("openassist:realtime-event", listener);
  }
});
