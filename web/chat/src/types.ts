export interface ChatMessage {
  id: string;
  type: "user" | "assistant" | "activity" | "activityGroup" | "activitySummary" | "system";
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
  transitionState?: "removing" | "entering";

  // Activity-specific
  activityIcon?: string;
  activityTitle?: string;
  activityDetail?: string;
  activityStatus?: "running" | "completed" | "failed";
  activityStatusLabel?: string;
  detailSections?: ActivityDetailSection[];
  activityTargets?: ActivityTarget[];
  loadActivityDetailsID?: string;
  collapseActivityDetailsID?: string;

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

export interface ThreadNoteState {
  threadId: string | null;
  text: string;
  isOpen: boolean;
  hasNote: boolean;
  isSaving: boolean;
  lastSavedAtLabel?: string | null;
  canEdit: boolean;
  placeholder: string;
}

export interface ScrollState {
  isPinned: boolean;
  isScrolledUp: boolean;
  distanceFromTop: number;
}

export type AssistantSidebarPaneID = "threads" | "archived" | "automations" | "skills";
export type AssistantSidebarCollapsedPreviewPane =
  | AssistantSidebarPaneID
  | "projects";

export interface AssistantSidebarNavItem {
  id: Exclude<AssistantSidebarPaneID, "archived">;
  label: string;
  symbol: string;
}

export interface AssistantSidebarProjectItem {
  id: string;
  name: string;
  symbol: string;
  subtitle: string;
  isSelected: boolean;
  hasLinkedFolder: boolean;
  hasCustomIcon: boolean;
}

export interface AssistantSidebarHiddenProjectItem {
  id: string;
  name: string;
  symbol: string;
}

export interface AssistantSidebarSessionItem {
  id: string;
  title: string;
  subtitle: string;
  timeLabel?: string;
  isSelected: boolean;
  isTemporary: boolean;
  projectId?: string;
}

export interface AssistantSidebarState {
  selectedPane: AssistantSidebarPaneID;
  isCollapsed: boolean;
  collapsedPreviewPane?: AssistantSidebarCollapsedPreviewPane;
  canCreateThread: boolean;
  canCollapse: boolean;
  projectsTitle: string;
  projectsHelperText?: string;
  threadsTitle: string;
  threadsHelperText?: string;
  archivedTitle: string;
  archivedHelperText?: string;
  projectsExpanded: boolean;
  threadsExpanded: boolean;
  archivedExpanded: boolean;
  canLoadMoreThreads: boolean;
  canLoadMoreArchived: boolean;
  archivedCount: number;
  hiddenProjectCount: number;
  navItems: AssistantSidebarNavItem[];
  allProjects: AssistantSidebarProjectItem[];
  hiddenProjects: AssistantSidebarHiddenProjectItem[];
  projects: AssistantSidebarProjectItem[];
  threads: AssistantSidebarSessionItem[];
  archived: AssistantSidebarSessionItem[];
}

export interface AssistantComposerOption {
  id: string;
  label: string;
}

export interface AssistantComposerAttachment {
  id: string;
  filename: string;
  kind: "file" | "image";
  previewDataUrl?: string;
}

export interface AssistantComposerSkill {
  skillName: string;
  displayName: string;
  isMissing: boolean;
}

export interface AssistantComposerState {
  draftText: string;
  placeholder: string;
  isEnabled: boolean;
  canSend: boolean;
  isBusy: boolean;
  isVoiceCapturing: boolean;
  canUseVoiceInput: boolean;
  showStopVoicePlayback: boolean;
  canOpenSkills: boolean;
  selectedInteractionMode: string;
  interactionModes: AssistantComposerOption[];
  selectedModelId?: string;
  modelOptions: AssistantComposerOption[];
  selectedReasoningId: string;
  reasoningOptions: AssistantComposerOption[];
  activeSkills: AssistantComposerSkill[];
  attachments: AssistantComposerAttachment[];
}
