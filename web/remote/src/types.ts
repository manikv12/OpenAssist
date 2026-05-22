export type RemoteAccessActionType =
  | "selectSession"
  | "newSession"
  | "sendPrompt"
  | "stopTurn"
  | "chooseModel"
  | "chooseBackend"
  | "setMode"
  | "setReasoningEffort"
  | "applyPlugins"
  | "resolvePermission"
  | "cancelPermission"
  | "deleteSession";

export interface RemoteProfile {
  id: string;
  machineID: string;
  name: string;
  baseURL: string;
  token: string;
  lastUsedAt: string;
}

export interface RemoteAccessSession {
  id: string;
  title: string;
  summary?: string | null;
  projectID?: string | null;
  projectName?: string | null;
  backend?: string | null;
  modelID?: string | null;
  interactionMode?: string | null;
  reasoningEffort?: string | null;
  isTemporary: boolean;
  hasActiveTurn: boolean;
  updatedAt?: string | null;
}

export interface RemoteAccessToolCall {
  id: string;
  title: string;
  status: string;
  detail?: string | null;
}

export interface RemoteAccessPermissionOption {
  id: string;
  title: string;
  kind?: string | null;
  isDefault: boolean;
}

export interface RemoteAccessPermissionQuestionOption {
  id: string;
  label: string;
  detail?: string | null;
}

export interface RemoteAccessPermissionQuestion {
  id: string;
  header: string;
  prompt: string;
  allowsCustomAnswer: boolean;
  options: RemoteAccessPermissionQuestionOption[];
}

export interface RemoteAccessPermissionRequest {
  id: number;
  toolTitle: string;
  toolKind?: string | null;
  rationale?: string | null;
  rawPayloadSummary?: string | null;
  requiresDesktopAppConfirmation: boolean;
  options: RemoteAccessPermissionOption[];
  questions: RemoteAccessPermissionQuestion[];
}

export interface RemoteAccessTranscriptEntry {
  id: string;
  role: string;
  text: string;
  createdAt: string;
  isStreaming: boolean;
  providerBackend?: string | null;
  providerModelID?: string | null;
  selectedPluginIDs: string[];
}

export interface RemoteAccessSessionDetail {
  session: RemoteAccessSession;
  transcript: RemoteAccessTranscriptEntry[];
  activeToolCalls: RemoteAccessToolCall[];
  recentToolCalls: RemoteAccessToolCall[];
  pendingPermission?: RemoteAccessPermissionRequest | null;
  selectedPluginIDs: string[];
  pendingOutgoingMessage?: string | null;
  activeTurnID?: string | null;
  awaitingAssistantStart: boolean;
  queuedPromptCount: number;
}

export interface RemoteAccessBackendOption {
  id: string;
  displayName: string;
}

export interface RemoteAccessModelOption {
  id: string;
  displayName: string;
  description: string;
  isDefault: boolean;
  inputModalities: string[];
  supportedReasoningEfforts: string[];
}

export interface RemoteAccessPlugin {
  id: string;
  displayName: string;
  summary?: string | null;
  needsSetup: boolean;
  iconDataURL?: string | null;
}

export interface RemoteAccessProject {
  id: string;
  name: string;
  kind: string;
  parentID?: string | null;
  sessionCount: number;
}

export interface RemoteAccessPairedDevice {
  id: string;
  name: string;
  createdAt: string;
  lastSeenAt?: string | null;
  userAgent?: string | null;
  isCurrent: boolean;
}

export interface RemoteAccessControlState {
  sessionID: string;
  deviceID: string;
  deviceName: string;
  acquiredAt: string;
  activeTurnID?: string | null;
}

export interface RemoteAccessTunnelStatus {
  mode: "disabled" | "quick" | "named";
  transport: "auto" | "quic" | "http2";
  configured: boolean;
  isRunning: boolean;
  publicURL?: string | null;
  warning?: string | null;
  detail?: string | null;
  executablePath?: string | null;
}

export interface RemoteAccessUsageWindow {
  label: string;
  usedPercent: number;
  resetsAt?: string | null;
  resetsInLabel?: string | null;
}

export interface RemoteAccessContextUsage {
  usedPercent: number;
  summary: string;
  detail?: string | null;
}

export interface RemoteAccessUsage {
  providerBackend: string;
  providerLabel: string;
  planType?: string | null;
  primary?: RemoteAccessUsageWindow | null;
  secondary?: RemoteAccessUsageWindow | null;
  context?: RemoteAccessContextUsage | null;
}

export interface RemoteAccessStatus {
  runtimeAvailability: string;
  runtimeSummary: string;
  runtimeDetail?: string | null;
  helperState: string;
  helperMessage?: string | null;
  tunnel: RemoteAccessTunnelStatus;
  usage?: RemoteAccessUsage | null;
}

export interface RemoteAccessMachine {
  machineID: string;
  displayName: string;
  hostName: string;
  appVersion: string;
  operatingSystem: string;
  localBaseURL: string;
  publicBaseURL?: string | null;
}

export interface RemoteAccessHealthResponse {
  ok: boolean;
  helperState: string;
  helperMessage?: string | null;
  machineID: string;
  machineName: string;
  appVersion: string;
  localBaseURL: string;
  publicBaseURL?: string | null;
  tunnelMode: string;
  adminPasswordRequired: boolean;
}

export interface RemoteAccessSnapshot {
  machine: RemoteAccessMachine;
  status: RemoteAccessStatus;
  pairedDevice?: RemoteAccessPairedDevice | null;
  sessions: RemoteAccessSession[];
  selectedSessionID?: string | null;
  selectedSession?: RemoteAccessSessionDetail | null;
  remoteControl?: RemoteAccessControlState | null;
  availableBackends: RemoteAccessBackendOption[];
  availableModels: RemoteAccessModelOption[];
  installedPlugins: RemoteAccessPlugin[];
  projects: RemoteAccessProject[];
}

export interface RemoteAccessEvent {
  sequence: number;
  type: "snapshot" | "sessionUpdated" | "permissionUpdated" | "statusChanged";
  snapshot?: RemoteAccessSnapshot | null;
}

export interface RemoteAccessPairClaimResponse {
  ok: boolean;
  machineID?: string | null;
  deviceToken?: string | null;
  snapshot?: RemoteAccessSnapshot | null;
  error?: string | null;
}

export interface RemoteAccessActionResponse {
  id: string;
  ok: boolean;
  snapshot?: RemoteAccessSnapshot | null;
  error?: string | null;
}
