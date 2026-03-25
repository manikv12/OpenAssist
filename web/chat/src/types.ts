export interface ChatMessage {
  id: string;
  type: "user" | "assistant" | "activity" | "activityGroup" | "system";
  text?: string;
  isStreaming: boolean;
  timestamp: number; // Unix ms
  turnID?: string;
  images?: string[]; // base64 data URIs
  emphasis?: boolean;
  canUndo?: boolean;
  canEdit?: boolean;
  rewriteAnchorID?: string;
  providerLabel?: string;
  transitionState?: "removing";

  // Activity-specific
  activityIcon?: string;
  activityTitle?: string;
  activityDetail?: string;
  activityStatus?: "running" | "completed" | "failed";
  activityStatusLabel?: string;
  detailSections?: ActivityDetailSection[];
  activityTargets?: ActivityTarget[];

  // Activity group
  groupItems?: ActivityGroupItem[];
}

export interface ActivityGroupItem {
  id: string;
  icon?: string;
  title: string;
  detail?: string;
  status: "running" | "completed" | "failed";
  statusLabel?: string;
  timestamp: number;
  detailSections?: ActivityDetailSection[];
  activityTargets?: ActivityTarget[];
}

export interface ActivityDetailSection {
  title: string;
  text: string;
}

export interface ActivityTarget {
  kind: "file" | "webSearch" | "url";
  label: string;
  detail?: string;
}

export type ProviderTone = "codex" | "copilot" | "default";

export interface TypingState {
  visible: boolean;
  title?: string;
  detail?: string;
}

export interface RuntimeBackendOption {
  id: string;
  label: string;
  isSelected: boolean;
  isDisabled: boolean;
}

export interface RuntimePanelState {
  tone: "ready" | "connecting" | "failed" | "idle";
  statusSummary: string;
  statusDetail?: string;
  accountSummary?: string;
  backendHelpText?: string;
  backends: RuntimeBackendOption[];
  setupButtonTitle?: string;
}

export interface CodeReviewFile {
  path: string;
  changeKind: "added" | "modified" | "deleted" | "typeChanged" | "changed";
  isBinary: boolean;
}

export interface CodeReviewCheckpoint {
  id: string;
  checkpointNumber: number;
  createdAt: number;
  summary: string;
  patch: string;
  turnStatus: "completed" | "interrupted" | "failed";
  ignoredTouchedPaths: string[];
  changedFiles: CodeReviewFile[];
  associatedMessageID?: string;
  associatedTurnID?: string;
  associatedUserMessageID?: string;
  associatedUserAnchorID?: string;
}

export interface MessageCheckpointInfo {
  checkpoint: CodeReviewCheckpoint;
  checkpointIndex: number;
  currentCheckpointPosition: number;
  totalCheckpointCount: number;
  hasActiveTurn: boolean;
  actionsLocked: boolean;
  futureTurnsHidden?: boolean;
}

export interface CodeReviewPanelState {
  repoLabel: string;
  repoRootPath: string;
  currentCheckpointPosition: number;
  selectedCheckpointID: string;
  hasActiveTurn: boolean;
  actionsLocked: boolean;
  embedded: boolean;
  checkpoints: CodeReviewCheckpoint[];
}

export interface RewindState {
  kind: "undo" | "edit" | "checkpoint";
  canStepBackward: boolean;
  redoHostMessageID?: string;
}

export interface ScrollState {
  isPinned: boolean;
  isScrolledUp: boolean;
  distanceFromTop: number;
}
