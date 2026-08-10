export type JsonObject = Record<string, unknown>;

export type LiveVoiceProvider = "openaiRealtime" | "geminiLive" | "codexSubscription";
export type RealtimeWorkerPolicy = "auto" | "never";

export type VoiceSessionLifecycle = "connecting" | "open" | "closed" | "error";
export type VoicePhase = "listening" | "speaking" | "quiet" | "stopped";
export type VoiceControlAction = "interrupt" | "quiet" | "resume" | "stop_listening";
export type VoiceTurnPhase =
  | "receiving"
  | "ready"
  | "selecting_capability"
  | "executing_capability"
  | "waiting_for_approval"
  | "waiting_for_permission"
  | "waiting_for_clarification"
  | "delegating"
  | "delivering"
  | "completed"
  | "interrupted"
  | "failed";

export type VoiceTurnActionOwner =
  | "capability"
  | "delegation"
  | "status"
  | "cancellation"
  | "navigation";

export type CapabilityOperation = "discover" | "read" | "search" | "create" | "update" | "move" | "complete" | "delete" | "execute";
export type CapabilityRisk = "read" | "reversible_write" | "sensitive_write";
export type CapabilityExecutionMode = "blocking" | "background";
export type CapabilityOutcomeStatus =
  | "completed"
  | "not_found"
  | "selection_required"
  | "clarification_required"
  // The resolved capability is correct but required arguments are missing.
  // The response carries the capability's inputSchema (via candidates) plus a
  // re-call instruction, so the model can fill arguments from the user's own
  // request instead of asking the user to repeat themselves.
  | "arguments_required"
  | "approval_required"
  | "permission_required"
  | "running"
  | "failed";

export type LiveVoiceContextResource = {
  kind: string;
  id: string;
  title?: string;
  source?: string;
  attributes?: JsonObject;
};

export type CapabilityContextBinding = {
  resourceKind: string;
  argument: string;
  resourceField: "id" | "title" | "source";
};

export type CapabilityArgumentOwner =
  | "goal-derived"
  | "context-resource"
  | "provider-supplied"
  | "user-required";

export type CapabilityArgumentBinding = {
  owner: CapabilityArgumentOwner;
  resourceKind?: string;
  resourceField?: "id" | "title" | "source";
};

export type CapabilityOutputResourceMapping = {
  resourceKind: string;
  path: string[];
  multiple?: boolean;
  idField?: string;
  titleField?: string;
  sourceField?: string;
  attributeFields?: string[];
};

export type CapabilityDescriptor = {
  id: string;
  description: string;
  operations: CapabilityOperation[];
  source: string;
  sourceAliases?: string[];
  keywords?: string[];
  resourceKinds?: string[];
  contextBindings?: CapabilityContextBinding[];
  argumentBindings?: Record<string, CapabilityArgumentBinding>;
  outputResources?: CapabilityOutputResourceMapping[];
  inputSchema: JsonObject;
  // Required fields the executor can derive from an injected `userIntent`
  // (parsed server-side from the user's spoken request). Missing required
  // fields NOT listed here still return arguments_required — e.g. an `id`
  // can never be derived from speech.
  selfDerivedArguments?: string[];
  risk: CapabilityRisk;
  executionMode: CapabilityExecutionMode;
  timeoutMs: number;
  idempotency: "none" | "turn" | "required";
  permissionRequirements?: Array<{
    permissionID: import("../nativeAccess.js").NativePermissionID;
    access: "read" | "write";
  }>;
  enabled?: () => boolean;
};

export type CapabilityRequest = {
  requestID: string;
  turnID: string;
  callID: string;
  goal: string;
  operation: CapabilityOperation;
  sourceHints: string[];
  capabilityID?: string;
  arguments: JsonObject;
  confirmationToken?: string;
  idempotencyKey: string;
  createdAt: number;
};

export type CapabilitySelection = Pick<CapabilityDescriptor, "id" | "description" | "operations" | "source" | "risk" | "inputSchema" | "resourceKinds">;

export type CapabilityResult = {
  requestID: string;
  turnID: string;
  callID: string;
  status: CapabilityOutcomeStatus;
  capabilityID?: string;
  output?: unknown;
  resources?: LiveVoiceContextResource[];
  message?: string;
  error?: string;
  errorCode?: string;
  candidates?: CapabilitySelection[];
  confirmationToken?: string;
  retryable?: boolean;
  permissions?: import("../nativeAccess.js").NativePermissionSnapshot[];
  action?: "request_permission" | "open_settings" | "restart_app";
  startedAt: number;
  finishedAt?: number;
};

export type VoiceTurn = {
  turnID: string;
  provider: LiveVoiceProvider;
  providerItemID?: string;
  text: string;
  phase: VoiceTurnPhase;
  createdAt: number;
  updatedAt: number;
  toolSteps: number;
  ownerCallID?: string;
  actionOwner?: VoiceTurnActionOwner;
  operationID?: string;
  taskID?: string;
  ungroundedActionClaim?: boolean;
  finalDeliveryID?: string;
  interrupted: boolean;
  error?: string;
};

export type ProviderEvent =
  | { type: "transcript_finalized"; provider: LiveVoiceProvider; turnID: string; providerItemID?: string; textLength: number; at: number }
  | { type: "tool_requested"; provider: LiveVoiceProvider; turnID: string; callID: string; toolName: string; at: number }
  | { type: "audio_started"; provider: LiveVoiceProvider; turnID?: string; itemID?: string; at: number }
  | { type: "response_completed"; provider: LiveVoiceProvider; turnID?: string; responseID?: string; at: number }
  | { type: "interrupted"; provider: LiveVoiceProvider; turnID?: string; reason: string; at: number }
  | { type: "connection_closed"; provider: LiveVoiceProvider; reason: string; at: number }
  | { type: "connection_restored"; provider: LiveVoiceProvider; at: number };

export type VoiceBackgroundTask = {
  taskID: string;
  sourceTurnID: string;
  state: "queued" | "running" | "completed" | "failed" | "cancelled";
  updatedAt: number;
};

export type VoiceControlResult = {
  handled: boolean;
  action?: VoiceControlAction;
};

export type VoiceSnapshot = {
  session: VoiceSessionLifecycle;
  voice: VoicePhase;
  activeTurnID?: string;
  turns: Record<string, VoiceTurn>;
  backgroundTasks: Record<string, VoiceBackgroundTask>;
  lastEventAt: number;
  error?: string;
};

export type AssistantCapabilityArguments = {
  goal: string;
  operation?: CapabilityOperation;
  sourceHints?: string[];
  capabilityID?: string;
  arguments?: JsonObject;
  confirmationToken?: string;
};

export type DelegatedWorkDepth = "auto" | "fast" | "deep";
export type DelegatedWorkComplexity = "simple" | "complex";
export type DelegatedWorkImpact = "read_only" | "reversible_write" | "sensitive_write";
export type DelegatedWorkStakes = "normal" | "high";
export type DelegatedWorkModelPreference = "spark" | "sol";

export type DelegatedWorkExecutionProfile = {
  depth?: DelegatedWorkDepth;
  complexity?: DelegatedWorkComplexity;
  impact?: DelegatedWorkImpact;
  stakes?: DelegatedWorkStakes;
  modelPreference?: DelegatedWorkModelPreference;
};

export type WorkerModelRole = "fast" | "deep";

export type WorkerModelMetadata = {
  role: WorkerModelRole;
  modelID: string;
  reasoningEffort: "medium" | "high";
  selectionReason: string;
  explicitlySelected: boolean;
};

export type AssistantDelegateTask = {
  prompt: string;
  userText?: string;
  provider?: string;
  project?: string;
  executionProfile?: DelegatedWorkExecutionProfile;
  freshThread?: boolean;
};

export type AssistantDelegateArguments = {
  goal: string;
  userText?: string;
  tasks?: AssistantDelegateTask[];
  provider?: string;
  project?: string;
  executionProfile?: DelegatedWorkExecutionProfile;
  freshThread?: boolean;
  mode?: "new" | "follow_up" | "rerun";
  taskID?: string;
};

export type LiveVoiceViewDestination =
  | "today"
  | "notes"
  | "threads"
  | "voice_log"
  | "review_inbox"
  | "settings";

export type LiveVoicePublicToolName =
  | "assistant_capability"
  | "assistant_delegate_work"
  | "assistant_task_status"
  | "assistant_cancel_task"
  | "assistant_open_view";
