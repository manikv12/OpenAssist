import { contextBridge, ipcRenderer, webFrame } from "electron";

contextBridge.exposeInMainWorld("openAssistElectron", {
  platform: process.platform,
  openExternal: (url: string) => ipcRenderer.invoke("open-external", url),
  // Dev-only perf snapshot. The main-process handler is gated on
  // OPENASSIST_ELECTRON_REMOTE_DEBUG=1 and returns { error: "disabled" }
  // otherwise — safe to expose unconditionally.
  __perfSnapshot: () => ipcRenderer.invoke("openassist:__perf-snapshot"),
  getMacOSPermissions: () => ipcRenderer.invoke("openassist:get-macos-permissions"),
  requestMacOSPermission: (kind: string) => ipcRenderer.invoke("openassist:request-macos-permission", kind),
  getComputerUseActivity: () => ipcRenderer.invoke("openassist:get-computer-use-activity"),
  forceStopComputerUse: () => ipcRenderer.invoke("openassist:force-stop-computer-use"),
  openTarget: (target: string, workspaceRootPath?: string | null) => ipcRenderer.invoke("openassist:open-target", target, workspaceRootPath),
  workspaceLaunchTargets: () => ipcRenderer.invoke("openassist:workspace-launch-targets"),
  readClipboardText: () => ipcRenderer.invoke("openassist:read-clipboard-text"),
  writeClipboardText: (text: string) => ipcRenderer.invoke("openassist:write-clipboard-text", text),
  copyImageToClipboard: (source: { dataURL?: string; filePath?: string }) =>
    ipcRenderer.invoke("openassist:copy-image-to-clipboard", source),
  getSpellcheckContext: () => ipcRenderer.invoke("openassist:get-spellcheck-context"),
  spellcheckWord: (word: string) => {
    const misspelledWord = String(word ?? "").trim();
    if (!misspelledWord) return null;
    const suggestions = Array.from(new Set(webFrame.getWordSuggestions(misspelledWord).map((suggestion) => suggestion.trim()).filter(Boolean)));
    const isMisspelled = suggestions.length > 0 || webFrame.isWordMisspelled(misspelledWord);
    if (!isMisspelled) return null;
    return {
      misspelledWord,
      suggestions: suggestions.slice(0, 8),
      isEditable: true,
      createdAt: Date.now()
    };
  },
  replaceMisspelling: (text: string) => ipcRenderer.invoke("openassist:replace-misspelling", text),
  insertTranscriptText: (text: string) => ipcRenderer.invoke("openassist:insert-transcript-text", text),
  notifyThreadComplete: (payload: { threadID: string; title: string; body?: string }) =>
    ipcRenderer.invoke("openassist:notify-thread-complete", payload),
  onOpenThread: (callback: (threadID: string) => void) => {
    const listener = (_event: unknown, threadID: unknown) => callback(String(threadID ?? ""));
    ipcRenderer.on("openassist:open-thread", listener);
    return () => ipcRenderer.off("openassist:open-thread", listener);
  },
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
  setMenuBarState: (state: unknown) => ipcRenderer.send("openassist:menu-bar-state", state),
  menuBarReportHeight: (height: number) => ipcRenderer.send("openassist:menu-bar-report-height", height),
  loadAppState: () => ipcRenderer.invoke("openassist:load-app-state"),
  loadSettingsAppState: () => ipcRenderer.invoke("openassist:load-settings-app-state"),
  loadConnectorSnapshot: () => ipcRenderer.invoke("openassist:connectors-load"),
  loadConnectorReviewInbox: () => ipcRenderer.invoke("openassist:connectors-load-review-inbox"),
  appleEventKitStatus: () => ipcRenderer.invoke("openassist:apple-eventkit-status"),
  requestAppleEventKitAccess: (service: string) => ipcRenderer.invoke("openassist:apple-eventkit-request-access", service),
  createGoogleConnectorAccount: (label: string) => ipcRenderer.invoke("openassist:connectors-create-google-account", label),
  removeGoogleConnectorAccount: (accountID: string) => ipcRenderer.invoke("openassist:connectors-remove-google-account", accountID),
  setConnectorServiceEnabled: (accountID: string, serviceID: string, enabled: boolean) =>
    ipcRenderer.invoke("openassist:connectors-set-service-enabled", accountID, serviceID, enabled),
  installGoogleWorkspaceCLI: () => ipcRenderer.invoke("openassist:connectors-install-gws"),
  googleConnectorCommandPlan: (accountID: string, operation: unknown, approved?: boolean) =>
    ipcRenderer.invoke("openassist:connectors-google-command-plan", accountID, operation, approved),
  googleConnectorOAuthStatus: (accountID: string) => ipcRenderer.invoke("openassist:connectors-google-oauth-status", accountID),
  openGoogleConnectorOAuthPage: (accountID: string, page: string) =>
    ipcRenderer.invoke("openassist:connectors-open-google-oauth-page", accountID, page),
  importGoogleConnectorClientSecret: (accountID: string) =>
    ipcRenderer.invoke("openassist:connectors-import-google-client-secret", accountID),
  reuseGoogleConnectorClientSecret: (accountID: string) =>
    ipcRenderer.invoke("openassist:connectors-reuse-google-client-secret", accountID),
  openGoogleConnectorConfigFolder: (accountID: string) =>
    ipcRenderer.invoke("openassist:connectors-open-google-config-folder", accountID),
  runGoogleConnectorSetup: (accountID: string) => ipcRenderer.invoke("openassist:connectors-run-google-setup", accountID),
  runGoogleConnectorLogin: (accountID: string) => ipcRenderer.invoke("openassist:connectors-run-google-login", accountID),
  sendConnectorTerminalInput: (sessionID: string, input: string) =>
    ipcRenderer.invoke("openassist:connectors-send-terminal-input", sessionID, input),
  stopConnectorTerminal: (sessionID: string) => ipcRenderer.invoke("openassist:connectors-stop-terminal", sessionID),
  onConnectorLoginProgress: (callback: (payload: unknown) => void) => {
    const listener = (_event: unknown, payload: unknown) => callback(payload);
    ipcRenderer.on("openassist:connector-login-progress", listener);
    return () => ipcRenderer.off("openassist:connector-login-progress", listener);
  },
  onConnectorSyncProgress: (callback: (payload: unknown) => void) => {
    const listener = (_event: unknown, payload: unknown) => callback(payload);
    ipcRenderer.on("openassist:connector-sync-progress", listener);
    return () => ipcRenderer.off("openassist:connector-sync-progress", listener);
  },
  syncGmailConnector: (accountID: string, options?: unknown) => ipcRenderer.invoke("openassist:connectors-sync-gmail", accountID, options),
  markConnectorItem: (itemID: string, status: string) => ipcRenderer.invoke("openassist:connectors-mark-item", itemID, status),
  ignoreConnectorReviewItems: (accountID?: string) => ipcRenderer.invoke("openassist:connectors-ignore-review-items", accountID),
  saveConnectorItemToBacklog: (itemID: string) => ipcRenderer.invoke("openassist:connectors-save-item-to-backlog", itemID),
  connectorSkillGuide: () => ipcRenderer.invoke("openassist:connectors-skill-guide"),
  integrationStatus: () => ipcRenderer.invoke("openassist:integrations-status"),
  connectIntegration: (targetID: string) => ipcRenderer.invoke("openassist:integrations-connect", targetID),
  copyIntegrationConfig: (targetID: string) => ipcRenderer.invoke("openassist:integrations-copy-config", targetID),
  revealIntegrationConfig: (targetID: string) => ipcRenderer.invoke("openassist:integrations-reveal-config", targetID),
  testIntegrationConnection: () => ipcRenderer.invoke("openassist:integrations-test"),
  integrationSkillGuide: (targetID?: string) => ipcRenderer.invoke("openassist:integrations-skill", targetID),
  copyIntegrationSkill: (targetID?: string) => ipcRenderer.invoke("openassist:integrations-copy-skill", targetID),
  installIntegrationSkill: (targetID: string) => ipcRenderer.invoke("openassist:integrations-install-skill", targetID),
  revealIntegrationSkill: (targetID?: string) => ipcRenderer.invoke("openassist:integrations-reveal-skill", targetID),
  listProviderModels: (backend: string) => ipcRenderer.invoke("openassist:list-provider-models", backend),
  listOllamaCatalogModels: () => ipcRenderer.invoke("openassist:list-ollama-catalog-models"),
  refreshOllamaWebsiteCatalog: () => ipcRenderer.invoke("openassist:refresh-ollama-website-catalog"),
  pullOllamaModel: (modelID: string) => ipcRenderer.invoke("openassist:pull-ollama-model", modelID),
  deleteOllamaModel: (modelID: string) => ipcRenderer.invoke("openassist:delete-ollama-model", modelID),
  getOllamaRuntimeStatus: () => ipcRenderer.invoke("openassist:get-ollama-runtime-status"),
  startOllamaRuntime: () => ipcRenderer.invoke("openassist:start-ollama-runtime"),
  stopOllamaRuntime: () => ipcRenderer.invoke("openassist:stop-ollama-runtime"),
  openOllamaDownloadPage: () => ipcRenderer.invoke("openassist:open-ollama-download"),
  updateOllamaRuntime: () => ipcRenderer.invoke("openassist:update-ollama-runtime"),
  onOllamaRuntimeUpdateProgress: (callback: (progress: unknown) => void) => {
    const listener = (_event: unknown, payload: unknown) => callback(payload);
    ipcRenderer.on("openassist:ollama-runtime-update-progress", listener);
    return () => ipcRenderer.off("openassist:ollama-runtime-update-progress", listener);
  },
  onOllamaModelDownloadProgress: (callback: (progress: unknown) => void) => {
    const listener = (_event: unknown, payload: unknown) => callback(payload);
    ipcRenderer.on("openassist:ollama-model-download-progress", listener);
    return () => ipcRenderer.off("openassist:ollama-model-download-progress", listener);
  },
  loadThread: (threadID: string) => ipcRenderer.invoke("openassist:load-thread", threadID),
  loadOlderThreadMessages: (threadID: string, beforeMessageID: string, turnLimit?: number) =>
    ipcRenderer.invoke("openassist:load-thread-messages-before", threadID, beforeMessageID, turnLimit),
  loadCodeTrackingState: (threadID: string) => ipcRenderer.invoke("openassist:load-code-tracking-state", threadID),
  openCodeReview: (threadID: string, checkpointID?: string) => ipcRenderer.invoke("openassist:open-code-review", threadID, checkpointID),
  restoreCodeCheckpoint: (threadID: string, checkpointID: string) =>
    ipcRenderer.invoke("openassist:restore-code-checkpoint", threadID, checkpointID),
  loadThreadNote: (threadID: string) => ipcRenderer.invoke("openassist:load-thread-note", threadID),
  createThreadNote: (threadID: string, title?: string) => ipcRenderer.invoke("openassist:create-thread-note", threadID, title),
  saveThreadNote: (threadID: string, noteID: string | undefined, markdown: string) =>
    ipcRenderer.invoke("openassist:save-thread-note", threadID, noteID, markdown),
  renameThreadNote: (threadID: string, noteID: string, title: string) =>
    ipcRenderer.invoke("openassist:rename-thread-note", threadID, noteID, title),
  selectThreadNote: (threadID: string, noteID: string) => ipcRenderer.invoke("openassist:select-thread-note", threadID, noteID),
  loadPlannerDay: (dayID?: string) => ipcRenderer.invoke("openassist:load-planner-day", dayID),
  loadPlannerBacklog: () => ipcRenderer.invoke("openassist:load-planner-backlog"),
  listPlannerDays: (limit?: number, activeDayID?: string) => ipcRenderer.invoke("openassist:list-planner-days", limit, activeDayID),
  listPlannerCategories: () => ipcRenderer.invoke("openassist:list-planner-categories"),
  listPlannerLists: () => ipcRenderer.invoke("openassist:list-planner-lists"),
  createPlannerList: (input: unknown) => ipcRenderer.invoke("openassist:create-planner-list", input),
  updatePlannerListColorAndArea: (projectID: string, area?: string | null, color?: string | null) =>
    ipcRenderer.invoke("openassist:update-planner-list-color-and-area", projectID, area, color),
  hidePlannerList: (projectID: string) => ipcRenderer.invoke("openassist:hide-planner-list", projectID),
  listPlannerSmartLists: () => ipcRenderer.invoke("openassist:list-planner-smart-lists"),
  listPlannerSmartListItems: (smartListID: string) => ipcRenderer.invoke("openassist:list-planner-smart-list-items", smartListID),
  upsertPlannerCategory: (category: unknown) => ipcRenderer.invoke("openassist:upsert-planner-category", category),
  deletePlannerCategory: (categoryID: string) => ipcRenderer.invoke("openassist:delete-planner-category", categoryID),
  savePlannerDay: (dayID: string | undefined, markdown: string) =>
    ipcRenderer.invoke("openassist:save-planner-day", dayID, markdown),
  scheduleSelectionToPlanner: (request: unknown) => ipcRenderer.invoke("openassist:schedule-selection-to-planner", request),
  listDailyItems: (dayID?: string) => ipcRenderer.invoke("openassist:list-daily-items", dayID),
  listBacklogItems: () => ipcRenderer.invoke("openassist:list-backlog-items"),
  upsertDailyItem: (item: unknown) => ipcRenderer.invoke("openassist:upsert-daily-item", item),
  toggleDailyItem: (dayID: string | undefined, itemID: string, checked: boolean) =>
    ipcRenderer.invoke("openassist:toggle-daily-item", dayID, itemID, checked),
  deleteDailyItem: (dayID: string | undefined, itemID: string) =>
    ipcRenderer.invoke("openassist:delete-daily-item", dayID, itemID),
  linkDailyItemNote: (dayID: string | undefined, itemID: string, target: unknown) =>
    ipcRenderer.invoke("openassist:link-daily-item-note", dayID, itemID, target),
  upsertBacklogItem: (item: unknown) => ipcRenderer.invoke("openassist:upsert-backlog-item", item),
  toggleBacklogItem: (itemID: string, checked: boolean) =>
    ipcRenderer.invoke("openassist:toggle-backlog-item", itemID, checked),
  deleteBacklogItem: (itemID: string) => ipcRenderer.invoke("openassist:delete-backlog-item", itemID),
  moveDailyItemToBacklog: (dayID: string | undefined, itemID: string) =>
    ipcRenderer.invoke("openassist:move-daily-item-to-backlog", dayID, itemID),
  scheduleBacklogItem: (itemID: string, targetDayID: string) =>
    ipcRenderer.invoke("openassist:schedule-backlog-item", itemID, targetDayID),
  loadThreadMemory: (threadID: string) => ipcRenderer.invoke("openassist:load-thread-memory", threadID),
  threadAgentFilesPath: (threadID: string) => ipcRenderer.invoke("openassist:thread-agent-files-path", threadID),
  setThreadProvider: (threadID: string, backend: string, modelID?: string) =>
    ipcRenderer.invoke("openassist:set-thread-provider", threadID, backend, modelID),
  createThread: (projectID?: string, isTemporary?: boolean) => ipcRenderer.invoke("openassist:create-thread", projectID, isTemporary),
  destroyTemporaryThread: (threadID: string) => ipcRenderer.invoke("openassist:destroy-temporary-thread", threadID),
  createProject: (name: string, kind: "project" | "folder", parentID?: string) =>
    ipcRenderer.invoke("openassist:create-project", name, kind, parentID),
  renameProject: (projectID: string, name: string) => ipcRenderer.invoke("openassist:rename-project", projectID, name),
  updateProjectIcon: (projectID: string, symbol?: string | null) => ipcRenderer.invoke("openassist:update-project-icon", projectID, symbol),
  updateProjectArea: (projectID: string, area?: string | null) => ipcRenderer.invoke("openassist:update-project-area", projectID, area),
  chooseProjectFolder: (projectID: string) => ipcRenderer.invoke("openassist:choose-project-folder", projectID),
  openProjectFolder: (parentID?: string | null) => ipcRenderer.invoke("openassist:open-project-folder", parentID),
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
  loadNoteLinks: (target: unknown, currentMarkdown?: string) => ipcRenderer.invoke("openassist:load-note-links", target, currentMarkdown),
  readNoteImageDataURL: (notePath: string, imageSrc: string) => ipcRenderer.invoke("openassist:read-note-image", notePath, imageSrc),
  cleanupNoteWithCodex: (request: unknown) => ipcRenderer.invoke("openassist:cleanup-note-with-codex", request),
  openMarkdownFileForImport: () => ipcRenderer.invoke("openassist:open-markdown-file-for-import"),
  createNote: (projectID: string) => ipcRenderer.invoke("openassist:create-note", projectID),
  renameNote: (projectID: string, noteID: string, title: string) =>
    ipcRenderer.invoke("openassist:rename-note", projectID, noteID, title),
  saveNote: (projectID: string, noteID: string, markdown: string) =>
    ipcRenderer.invoke("openassist:save-note", projectID, noteID, markdown),
  listNoteHistory: (projectID: string, noteID: string) => ipcRenderer.invoke("openassist:list-note-history", projectID, noteID),
  restoreNoteHistory: (projectID: string, noteID: string, historyID: string) =>
    ipcRenderer.invoke("openassist:restore-note-history", projectID, noteID, historyID),
  deleteNote: (projectID: string, noteID: string) =>
    ipcRenderer.invoke("openassist:delete-note", projectID, noteID),
  archiveNote: (projectID: string, noteID: string) =>
    ipcRenderer.invoke("openassist:archive-note", projectID, noteID),
  restoreNote: (projectID: string, noteID: string) =>
    ipcRenderer.invoke("openassist:restore-note", projectID, noteID),
  deleteNotePermanently: (projectID: string, noteID: string) =>
    ipcRenderer.invoke("openassist:delete-note-permanently", projectID, noteID),
  createNoteFolder: (projectID: string, name: string, parentFolderID?: string | null) =>
    ipcRenderer.invoke("openassist:create-note-folder", projectID, name, parentFolderID ?? null),
  renameNoteFolder: (projectID: string, folderID: string, name: string) =>
    ipcRenderer.invoke("openassist:rename-note-folder", projectID, folderID, name),
  deleteNoteFolder: (projectID: string, folderID: string) =>
    ipcRenderer.invoke("openassist:delete-note-folder", projectID, folderID),
  moveNoteFolder: (projectID: string, folderID: string, parentFolderID: string | null) =>
    ipcRenderer.invoke("openassist:move-note-folder", projectID, folderID, parentFolderID),
  moveNoteToFolder: (projectID: string, noteID: string, folderID: string | null) =>
    ipcRenderer.invoke("openassist:move-note-to-folder", projectID, noteID, folderID),
  deleteThreadNote: (threadID: string, noteID: string) =>
    ipcRenderer.invoke("openassist:delete-thread-note", threadID, noteID),
  archiveThreadNote: (threadID: string, noteID: string) =>
    ipcRenderer.invoke("openassist:archive-thread-note", threadID, noteID),
  restoreThreadNote: (threadID: string, noteID: string) =>
    ipcRenderer.invoke("openassist:restore-thread-note", threadID, noteID),
  deleteThreadNotePermanently: (threadID: string, noteID: string) =>
    ipcRenderer.invoke("openassist:delete-thread-note-permanently", threadID, noteID),
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
  updateSettings: (updates: Array<{ key: string; value: boolean | string | number }>) =>
    ipcRenderer.invoke("openassist:update-settings", updates),
  previewColorTheme: (theme: string | null) =>
    ipcRenderer.invoke("openassist:preview-color-theme", theme),
  knowledgeStatus: () => ipcRenderer.invoke("openassist:knowledge-status"),
  listKnowledgeRequests: (status?: "pending" | "applied" | "rejected") =>
    ipcRenderer.invoke("openassist:list-knowledge-requests", status),
  applyKnowledgePreview: (requestID: string) =>
    ipcRenderer.invoke("openassist:apply-knowledge-preview", requestID),
  rejectKnowledgeRequest: (requestID: string) =>
    ipcRenderer.invoke("openassist:reject-knowledge-request", requestID),
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
  saveRealtimeGeminiAPIKey: (token: string) =>
    ipcRenderer.invoke("openassist:save-realtime-gemini-api-key", token),
  clearRealtimeGeminiAPIKey: () =>
    ipcRenderer.invoke("openassist:clear-realtime-gemini-api-key"),
  saveTelegramBotToken: (token: string) => ipcRenderer.invoke("openassist:save-telegram-bot-token", token),
  clearTelegramBotToken: () => ipcRenderer.invoke("openassist:clear-telegram-bot-token"),
  approveTelegramPairing: () => ipcRenderer.invoke("openassist:approve-telegram-pairing"),
  declineTelegramPairing: () => ipcRenderer.invoke("openassist:decline-telegram-pairing"),
  forgetTelegramPairing: () => ipcRenderer.invoke("openassist:forget-telegram-pairing"),
  testTelegramConnection: (token?: string) => ipcRenderer.invoke("openassist:test-telegram-connection", token),
  rotateRemoteAccessPairingCode: () => ipcRenderer.invoke("openassist:rotate-remote-access-pairing-code"),
  clearRemoteAccessPairingCode: () => ipcRenderer.invoke("openassist:clear-remote-access-pairing-code"),
  startRemoteAccessEasyQR: () => ipcRenderer.invoke("openassist:start-remote-access-easy-qr"),
  stopRemoteAccessEasyQR: () => ipcRenderer.invoke("openassist:stop-remote-access-easy-qr"),
  getRemoteAccessStatus: () => ipcRenderer.invoke("openassist:get-remote-access-status"),
  sendMessage: (prompt: string, threadID?: string, pluginIDs?: string[], sessionInstructions?: string, reasoningEffort?: string, interactionMode?: string, permissionMode?: string, skillIDs?: string[], clientRunID?: string, attachments?: unknown[]) =>
    ipcRenderer.invoke("openassist:send-message", prompt, threadID, pluginIDs, sessionInstructions, reasoningEffort, interactionMode, permissionMode, skillIDs, clientRunID, attachments),
  codexRuntimeParityProbe: (options?: unknown) => ipcRenderer.invoke("openassist:codex-runtime-parity-probe", options),
  stopMessage: (clientRunID?: string) => ipcRenderer.invoke("openassist:stop-message", clientRunID),
  respondProviderRequest: (requestID: string | number, result: unknown) =>
    ipcRenderer.invoke("openassist:respond-provider-request", requestID, result),
  installKokoroVoiceModel: (voiceID?: string) =>
    ipcRenderer.invoke("openassist:install-kokoro-voice-model", voiceID),
  speakAssistantResponse: (text: string, options?: { force?: boolean; engine?: string; voice?: string }) =>
    ipcRenderer.invoke("openassist:speak-assistant-response", text, options),
  prepareReadAloudAudio: (text: string, options?: { engine?: string; voice?: string; model?: string }) =>
    ipcRenderer.invoke("openassist:prepare-read-aloud-audio", text, options),
  startNoteReadAloud: (request: { text: string; source?: "selection" | "whole-note" | "message"; title?: string; targetID?: string }) =>
    ipcRenderer.invoke("openassist:start-note-read-aloud", request),
  pauseNoteReadAloud: () => ipcRenderer.invoke("openassist:pause-note-read-aloud"),
  resumeNoteReadAloud: () => ipcRenderer.invoke("openassist:resume-note-read-aloud"),
  stopNoteReadAloud: () => ipcRenderer.invoke("openassist:stop-note-read-aloud"),
  onNoteReadAloudState: (callback: (state: unknown) => void) => {
    const listener = (_event: unknown, payload: unknown) => callback(payload);
    ipcRenderer.on("openassist:note-read-aloud-state", listener);
    return () => ipcRenderer.off("openassist:note-read-aloud-state", listener);
  },
  startWakeWordForToday: (options?: { phrase?: string; autoDetectMicrophone?: boolean; selectedMicrophoneUID?: string }) =>
    ipcRenderer.invoke("openassist:start-wake-word-for-today", options),
  stopWakeWordForToday: (reason?: string) => ipcRenderer.invoke("openassist:stop-wake-word-for-today", reason),
  getWakeWordStatus: () => ipcRenderer.invoke("openassist:get-wake-word-status"),
  onWakeWordStatus: (callback: (status: unknown) => void) => {
    const listener = (_event: unknown, payload: unknown) => callback(payload);
    ipcRenderer.on("openassist:wake-word-status", listener);
    return () => ipcRenderer.off("openassist:wake-word-status", listener);
  },
  prewarmAssistantVoiceOutput: (options?: { engine?: string; voice?: string }) =>
    ipcRenderer.invoke("openassist:prewarm-assistant-voice-output", options),
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
    floatingHUDEnabled?: boolean;
    waveformTheme?: string;
    colorTheme?: string;
    appChromeStyle?: string;
  }) => ipcRenderer.invoke("openassist:start-voice-input", options),
  stopVoiceInput: () => ipcRenderer.invoke("openassist:stop-voice-input"),
  localVoiceTranscribe: (input: {
    audioBase64?: string;
    fileName?: string;
    mimeType?: string;
    transcriptionEngine?: string;
    cloudTranscriptionProvider?: string;
    cloudTranscriptionAPIKeyConfigured?: boolean;
    whisperModel?: string;
    whisperUseCoreML?: boolean;
  }) => ipcRenderer.invoke("openassist:local-voice-transcribe", input),
  classifyLocalVoiceTranscript: (input: {
    transcript: string;
    lastUserTask?: string;
    agentRunning?: boolean;
    surface?: string;
    voiceState?: string;
  }) => ipcRenderer.invoke("openassist:local-voice-classify", input),
  handleLocalVoiceDirectKnowledge: (input: { transcript?: string; taskText?: string }) =>
    ipcRenderer.invoke("openassist:local-voice-direct-knowledge", input),
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
    providerLabel?: string;
    userText?: string;
    assistantText?: string;
    workText?: string;
    muted?: boolean;
    approval?: { requestID: string; summary?: string } | null;
  }) =>
    ipcRenderer.invoke("openassist:update-voice-hud", payload),
  liveVoiceHUDAction: (action: "toggleMute" | "stop" | "approveRequest" | "rejectRequest") =>
    ipcRenderer.invoke("openassist:live-voice-hud-action", action),
  onLiveVoiceHUDAction: (callback: (action: "toggleMute" | "stop" | "approveRequest" | "rejectRequest") => void) => {
    const listener = (_event: unknown, action: "toggleMute" | "stop" | "approveRequest" | "rejectRequest") => callback(action);
    ipcRenderer.on("openassist:live-voice-hud-action", listener);
    return () => ipcRenderer.off("openassist:live-voice-hud-action", listener);
  },
  submitScreenAnalysis: (instruction: string, options?: { readback?: boolean }) =>
    ipcRenderer.invoke("openassist:submit-screen-analysis", instruction, options),
  cancelScreenAnalysis: () =>
    ipcRenderer.invoke("openassist:cancel-screen-analysis"),
  copyScreenAnalysisCapture: () =>
    ipcRenderer.invoke("openassist:copy-screen-analysis-capture"),
  listScreenAnalysisSkills: () =>
    ipcRenderer.invoke("openassist:list-screen-analysis-skills"),
  toggleScreenAnalysisSkill: (id: string, title: string) =>
    ipcRenderer.invoke("openassist:toggle-screen-analysis-skill", id, title),
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
  getLocalFilePreview: (filePath: string) =>
    ipcRenderer.invoke("openassist:get-local-file-preview", filePath),
  revealLocalPath: (filePath: string) =>
    ipcRenderer.invoke("openassist:reveal-local-path", filePath),
  setScreenAnalysisFrameVisible: (visible: boolean) =>
    ipcRenderer.invoke("openassist:set-screen-analysis-frame-visible", visible),
  setScreenAnalysisPanelCollapsed: (collapsed: boolean) =>
    ipcRenderer.invoke("openassist:set-screen-analysis-panel-collapsed", collapsed),
  setScreenAnalysisMenuExpanded: (expanded: boolean) =>
    ipcRenderer.invoke("openassist:set-screen-analysis-menu-expanded", expanded),
  startScreenAnalysisAtSamePlace: () =>
    ipcRenderer.invoke("openassist:start-screen-analysis-at-same-place"),
  listScreenSnipPresets: () =>
    ipcRenderer.invoke("openassist:list-screen-snip-presets"),
  setScreenSnipTheme: (theme: string) =>
    ipcRenderer.invoke("openassist:set-screen-snip-theme", theme),
  onScreenSnipThemeChanged: (callback: (payload: { selected: string; colors: string[] }) => void) => {
    const listener = (_event: unknown, payload: { selected: string; colors: string[] }) => callback(payload);
    ipcRenderer.on("openassist:screen-snip-theme-changed", listener);
    return () => ipcRenderer.removeListener("openassist:screen-snip-theme-changed", listener);
  },
  completeScreenSelection: (rect: { x: number; y: number; width: number; height: number }) =>
    ipcRenderer.invoke("openassist:complete-screen-selection", rect),
  cancelScreenSelection: () =>
    ipcRenderer.invoke("openassist:cancel-screen-selection"),
  setScreenAnalysisFrameInteractive: (interactive: boolean) =>
    ipcRenderer.invoke("openassist:set-screen-analysis-frame-interactive", interactive),
  setWindowMode: (
    mode: "full" | "sidebar" | "notch",
    sidebarOpen?: boolean,
    sidebarEdge?: "left" | "right",
    notchDockRevealed?: boolean
  ) =>
    ipcRenderer.invoke("openassist:set-window-mode", mode, sidebarOpen, sidebarEdge, notchDockRevealed),
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
  onNavigationCommand: (callback: (direction: "back" | "forward") => void) => {
    const listener = (_event: Electron.IpcRendererEvent, direction: "back" | "forward") => callback(direction);
    ipcRenderer.on("openassist:navigation-command", listener);
    return () => ipcRenderer.removeListener("openassist:navigation-command", listener);
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
  },
  // Background app-state updates (plugins, automations, full thread list,
  // usage) arrive here after the initial loadAppState returned a fast shell.
  // The callback receives a typed union; the renderer is responsible for
  // merging each shape into appState.
  onAppStateBackgroundUpdate: (callback: (update: unknown) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, update: unknown) => callback(update);
    ipcRenderer.on("openassist:app-state-background-update", listener);
    return () => ipcRenderer.removeListener("openassist:app-state-background-update", listener);
  },
  onSettingsUpdated: (callback: (settings: unknown) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, settings: unknown) => callback(settings);
    ipcRenderer.on("openassist:settings-updated", listener);
    return () => ipcRenderer.removeListener("openassist:settings-updated", listener);
  },
  onColorThemePreview: (callback: (theme: string | null) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, theme: string | null) => callback(theme);
    ipcRenderer.on("openassist:color-theme-preview", listener);
    return () => ipcRenderer.removeListener("openassist:color-theme-preview", listener);
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
    contextHint?: string;
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
  appendImages: (input: unknown) => ipcRenderer.invoke("openassist:realtime-append-images", input),
  stop: () => ipcRenderer.invoke("openassist:realtime-stop"),
  stopDelegation: () => ipcRenderer.invoke("openassist:realtime-stop-delegation"),
  listVoices: () => ipcRenderer.invoke("openassist:realtime-list-voices"),
  onEvent: (callback: (event: { type: string; payload?: unknown }) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, payload: { type: string; payload?: unknown }) => callback(payload);
    ipcRenderer.on("openassist:realtime-event", listener);
    return () => ipcRenderer.removeListener("openassist:realtime-event", listener);
  }
});
