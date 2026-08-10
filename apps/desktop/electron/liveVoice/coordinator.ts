import { createHash, randomUUID } from "node:crypto";
import type {
  AssistantCapabilityArguments,
  AssistantDelegateArguments,
  CapabilityDescriptor,
  CapabilityOperation,
  CapabilityRequest,
  CapabilityResult,
  JsonObject,
  LiveVoiceContextResource,
  LiveVoiceProvider,
  LiveVoiceViewDestination,
  ProviderEvent,
  RealtimeWorkerPolicy,
  VoiceSnapshot,
  VoiceTurn,
  VoiceTurnActionOwner,
  VoiceBackgroundTask,
  VoiceControlResult
} from "./contracts.js";
import { LiveVoiceCapabilityRegistry } from "./capabilityRegistry.js";
import { initialVoiceSnapshot, reduceVoiceSnapshot, type VoiceStateEvent } from "./state.js";
import type { LiveVoiceTrace } from "./trace.js";
import { NativePermissionRequiredError, type NativePermissionID, type NativePermissionSnapshot } from "../nativeAccess.js";

export type LiveVoiceCoordinatorDependencies = {
  registry: LiveVoiceCapabilityRegistry;
  executeCapability: (descriptor: CapabilityDescriptor, request: CapabilityRequest) => Promise<unknown>;
  delegateWork: (request: AssistantDelegateArguments & { turnID: string; callID: string; contextResources?: LiveVoiceContextResource[] }) => Promise<unknown>;
  taskStatus: (taskID?: string) => Promise<unknown>;
  cancelTask: (taskID?: string) => Promise<unknown>;
  openView: (destination: LiveVoiceViewDestination) => Promise<unknown> | unknown;
  checkPermissions?: (permissionIDs: NativePermissionID[]) => Promise<NativePermissionSnapshot[]>;
  requestPermission?: (permissionID: NativePermissionID) => Promise<NativePermissionSnapshot>;
  contextResources?: () => LiveVoiceContextResource[];
  onProgress?: (event: { turnID: string; callID: string; stage: string; detail: string }) => void;
  trace?: LiveVoiceTrace;
  workerPolicy?: RealtimeWorkerPolicy;
  now?: () => number;
};

function cleanText(value: unknown) {
  return typeof value === "string" ? value.replace(/\s+/g, " ").trim() : "";
}

function operationValue(value: unknown): CapabilityOperation {
  const operation = cleanText(value) as CapabilityOperation;
  return ["discover", "read", "search", "create", "update", "move", "complete", "delete", "execute"].includes(operation)
    ? operation
    : "discover";
}

function stringList(value: unknown) {
  return Array.isArray(value) ? value.map(cleanText).filter(Boolean).slice(0, 8) : [];
}

function objectValue(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : {};
}

function timeout<T>(promise: Promise<T>, timeoutMs: number) {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Capability timed out.")), timeoutMs);
    if (typeof timer.unref === "function") timer.unref();
    promise.then(
      (value) => { clearTimeout(timer); resolve(value); },
      (error) => { clearTimeout(timer); reject(error); }
    );
  });
}

function hashText(value: string) {
  return createHash("sha256").update(value).digest("hex").slice(0, 16);
}

function capabilitySelectionKey(goal: string, operation: CapabilityOperation, sourceHints: string[]) {
  return hashText(JSON.stringify({
    goal: cleanText(goal).toLowerCase(),
    operation,
    sourceHints: [...sourceHints].map((hint) => cleanText(hint).toLowerCase()).sort()
  }));
}

function contextBoundArguments(
  descriptor: CapabilityDescriptor,
  argumentsValue: JsonObject,
  resources: LiveVoiceContextResource[]
) {
  const next = { ...argumentsValue };
  for (const binding of descriptor.contextBindings ?? []) {
    if (next[binding.argument] !== undefined && next[binding.argument] !== null && cleanText(next[binding.argument])) continue;
    const matchingResources = resources.filter((candidate) => candidate.kind === binding.resourceKind);
    if (matchingResources.length !== 1) continue;
    const resource = matchingResources[0];
    const value = resource[binding.resourceField];
    if (typeof value === "string" && value.trim()) next[binding.argument] = value.trim();
  }
  return next;
}

function declarativelyBoundArguments(
  descriptor: CapabilityDescriptor,
  argumentsValue: JsonObject,
  goal: string,
  resources: LiveVoiceContextResource[]
) {
  const next = contextBoundArguments(descriptor, argumentsValue, resources);
  for (const [argument, binding] of Object.entries(descriptor.argumentBindings ?? {})) {
    const current = next[argument];
    if (current !== undefined && current !== null && (typeof current !== "string" || current.trim())) continue;
    if (binding.owner === "goal-derived") {
      next[argument] = goal;
      continue;
    }
    if (binding.owner !== "context-resource" || !binding.resourceKind) continue;
    const matching = resources.filter((resource) => resource.kind === binding.resourceKind);
    if (matching.length !== 1) continue;
    const field = binding.resourceField ?? "id";
    const value = matching[0][field];
    if (typeof value === "string" && value.trim()) next[argument] = value.trim();
  }
  return next;
}

function valueAtPath(value: unknown, path: string[]) {
  let current = value;
  for (const segment of path) {
    if (!current || typeof current !== "object" || Array.isArray(current)) return undefined;
    current = (current as JsonObject)[segment];
  }
  return current;
}

function resourcesFromOutput(
  descriptor: CapabilityDescriptor,
  output: unknown
) {
  const resources: LiveVoiceContextResource[] = [];
  for (const mapping of descriptor.outputResources ?? []) {
    const mapped = valueAtPath(output, mapping.path);
    const values = mapping.multiple ? (Array.isArray(mapped) ? mapped : []) : [mapped];
    for (const value of values) {
      if (!value || typeof value !== "object" || Array.isArray(value)) continue;
      const record = value as JsonObject;
      const id = cleanText(record[mapping.idField ?? "id"]);
      if (!id) continue;
      const title = cleanText(record[mapping.titleField ?? "title"]);
      const source = cleanText(record[mapping.sourceField ?? "source"]) || descriptor.source;
      const attributes = Object.fromEntries(
        (mapping.attributeFields ?? [])
          .filter((field) => record[field] !== undefined)
          .map((field) => [field, record[field]])
      );
      resources.push({
        kind: mapping.resourceKind,
        id,
        title: title || undefined,
        source: source || undefined,
        attributes: Object.keys(attributes).length ? attributes : undefined
      });
    }
  }
  return resources;
}

function resourcesForCandidates(
  candidates: CapabilityResult["candidates"],
  resources: LiveVoiceContextResource[]
) {
  const kinds = new Set((candidates ?? []).flatMap((candidate) => candidate.resourceKinds ?? []));
  return kinds.size ? resources.filter((resource) => kinds.has(resource.kind)) : [];
}

function normalizedCommand(value: string) {
  return value
    .toLowerCase()
    .replace(/[^\p{L}\p{N}'\s-]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export function looksLikeActionAcknowledgement(value: string) {
  const text = normalizedCommand(value);
  if (!text || text.length > 280) return false;
  return /^(?:okay[, ]+|ok[, ]+|sure[, ]+|got it[, ]+)?(?:i(?:'m| am| will|'ll)?\s+)?(?:checking|on it|starting(?: that| this| the task)?|working on it|taking care of it|finishing up)\b/.test(text)
    || /^(?:okay[, ]+|ok[, ]+|sure[, ]+|got it[, ]+)?(?:let me|i(?:'ll| will))\s+(?:check|look(?: into| that up)?|take (?:a )?(?:quick )?look|open|move|update|change|create|start|run|take care of)\b/.test(text)
    || /^(?:one|a)\s+(?:second|moment|sec)[, ]+(?:i(?:'m| am|'ll| will)\s+)?(?:checking|looking|moving|opening|updating|starting|working)\b/.test(text)
    || /^(?:okay[, ]+|ok[, ]+|sure[, ]+)?(?:hold on|hang on|just a moment|give me a moment)\b/.test(text)
    || /\b(?:i started|i have started|i've started|work has started|the task is running)\b/.test(text)
    || /^(?:(?:i'm|i am)\s+)?sorry[, ]+i\s+(?:haven't|have not|didn't|did not|can't|cannot|couldn't|could not|wasn't able to|was not able to)\s+(?:check|look|find|access|open|move|add|create|delete|remove|update|edit|change|rename|save|run|start)\b/.test(text)
    || /^i\s+(?:haven't|have not|didn't|did not|can't|cannot|couldn't|could not|wasn't able to|was not able to)\s+(?:check|look|find|access|open|move|add|create|delete|remove|update|edit|change|rename|save|run|start)\b/.test(text);
}

function resultRecord(value: unknown) {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : {};
}

function isTaskCancellation(value: string) {
  return /\b(cancel|stop|end|abort)\b.{0,45}\b(task|job|work|agent|worker)\b/.test(value)
    || /\b(task|job|work|agent|worker)\b.{0,45}\b(cancel|stop|end|abort)\b/.test(value)
    || /^(cancel|abort|end) (it|that|this)( please)?$/.test(value);
}

const approvalPhrases = new Set([
  "approve",
  "approved",
  "confirm",
  "confirmed",
  "do it",
  "go ahead",
  "ok",
  "ok confirmed",
  "okay",
  "okay confirmed",
  "please do",
  "proceed",
  "sounds good",
  "sure",
  "yes",
  "yes confirmed",
  "yes go ahead",
  "yes please",
  "yeah",
  "yeah go ahead",
  "yep",
  "yup"
]);

export function isClearApprovalText(value: string) {
  return approvalPhrases.has(normalizedCommand(value));
}

function isApprovalRejection(value: string) {
  const command = normalizedCommand(value);
  return /^(cancel|cancel it|don't|don't do it|do not|do not do it|no|no thanks|nope|reject|stop|stop it)( please)?$/.test(command);
}

type PendingApproval = {
  token: string;
  actionKey: string;
  originTurnID: string;
  goal: string;
  operation: CapabilityOperation;
  sourceHints: string[];
  capabilityID: string;
  arguments: JsonObject;
  createdAt: number;
};

const pendingApprovalLifetimeMs = 5 * 60 * 1_000;

export function voiceControlForText(text: string): VoiceControlResult {
  const command = normalizedCommand(text);
  if (!command || isTaskCancellation(command)) return { handled: false };
  if (
    /^(stop listening|stop live voice|stop live mode|end live voice|close live voice|turn off live voice)( please)?$/.test(command)
  ) return { handled: true, action: "stop_listening" };
  if (
    /^(resume listening|resume live voice|start listening|listen again|listen now|unmute|unmute yourself|i'm back|i am back|you can listen again|you can listen now|you can talk again|you can respond again|speak again)( please)?$/.test(command)
  ) return { handled: true, action: "resume" };
  if (
    /^(be quiet|go quiet|stay quiet|quiet mode|mute|mute yourself|don't respond|do not respond|don't listen to me|do not listen to me)( please)?$/.test(command)
  ) return { handled: true, action: "quiet" };
  if (
    /^(stop|never mind|nevermind|that's all|that is all|done|wait|hold on|hold up|hang on|one second|one sec|one moment|just a second|just a moment|give me a second|give me a moment)( please)?$/.test(command)
    || /\b(stop talking|stop speaking|shut up|shush|that's enough)\b/.test(command)
  ) return { handled: true, action: "interrupt" };
  return { handled: false };
}

export class LiveVoiceCoordinator {
  private snapshotValue: VoiceSnapshot;
  private sequence = 0;
  private readonly providerTurns = new Map<string, string>();
  private readonly confirmedTokens = new Map<string, string>();
  private readonly pendingApprovals = new Map<string, PendingApproval>();
  private readonly idempotentResults = new Map<string, CapabilityResult>();
  private readonly selectionGrants = new Map<string, { key: string; capabilityIDs: string[] }>();
  private recentResources: LiveVoiceContextResource[] = [];
  private readonly now: () => number;

  constructor(private readonly dependencies: LiveVoiceCoordinatorDependencies) {
    this.now = dependencies.now ?? (() => Date.now());
    this.snapshotValue = initialVoiceSnapshot(this.now());
  }

  snapshot() {
    return this.snapshotValue;
  }

  contextResources() {
    return [...this.recentResources];
  }

  private rememberResources(resources: LiveVoiceContextResource[]) {
    for (const resource of resources) {
      this.recentResources = this.recentResources.filter((candidate) =>
        candidate.kind !== resource.kind || candidate.id !== resource.id
      );
      this.recentResources.unshift(resource);
    }
    this.recentResources = this.recentResources.slice(0, 32);
  }

  private dispatch(event: VoiceStateEvent) {
    this.snapshotValue = reduceVoiceSnapshot(this.snapshotValue, event);
  }

  private clearPendingApprovals() {
    for (const token of this.pendingApprovals.keys()) this.confirmedTokens.delete(token);
    this.pendingApprovals.clear();
  }

  private prunePendingApprovals() {
    const cutoff = this.now() - pendingApprovalLifetimeMs;
    for (const [token, approval] of this.pendingApprovals) {
      if (approval.createdAt >= cutoff) continue;
      this.pendingApprovals.delete(token);
      this.confirmedTokens.delete(token);
    }
  }

  private rememberPendingApproval(approval: PendingApproval) {
    this.pendingApprovals.set(approval.token, approval);
    this.confirmedTokens.set(approval.token, approval.actionKey);
    // Keep the set tiny without invalidating an earlier token merely because a
    // provider accidentally proposed a different action before the user spoke.
    const oldest = [...this.pendingApprovals.values()].sort((a, b) => a.createdAt - b.createdAt);
    for (const stale of oldest.slice(0, Math.max(0, oldest.length - 4))) {
      this.pendingApprovals.delete(stale.token);
      this.confirmedTokens.delete(stale.token);
    }
  }

  private consumePendingApproval(token: string) {
    this.pendingApprovals.delete(token);
    this.confirmedTokens.delete(token);
  }

  private approvedRequestForTurn(turn: VoiceTurn, raw: AssistantCapabilityArguments) {
    this.prunePendingApprovals();
    if (!isClearApprovalText(turn.text)) return null;
    const requestedToken = cleanText(raw.confirmationToken);
    if (requestedToken) return this.pendingApprovals.get(requestedToken) ?? null;
    if (this.pendingApprovals.size !== 1) return null;
    return this.pendingApprovals.values().next().value as PendingApproval | undefined ?? null;
  }

  open() {
    this.dispatch({ type: "session_opened", at: this.now() });
  }

  close() {
    this.dispatch({ type: "session_closed", at: this.now() });
  }

  fail(error: string) {
    this.dispatch({ type: "session_failed", error, at: this.now() });
  }

  setVoicePhase(phase: VoiceSnapshot["voice"]) {
    this.dispatch({ type: "voice_phase_changed", phase, at: this.now() });
  }

  handleVoiceControl(text: string) {
    const control = voiceControlForText(text);
    if (!control.handled) return control;
    if (control.action === "quiet") this.setVoicePhase("quiet");
    if (control.action === "resume") this.setVoicePhase("listening");
    if (control.action === "stop_listening") this.setVoicePhase("stopped");
    return control;
  }

  updateBackgroundTask(task: VoiceBackgroundTask) {
    this.dispatch({ type: "task_changed", task, at: this.now() });
  }

  removeBackgroundTask(taskID: string) {
    this.dispatch({ type: "task_removed", taskID, at: this.now() });
  }

  shouldPreserveTurnOnInterruption(turnID: string) {
    const phase = this.snapshotValue.turns[turnID]?.phase;
    return Boolean(phase && [
      "selecting_capability",
      "executing_capability",
      "waiting_for_approval",
      "waiting_for_permission",
      "waiting_for_clarification",
      "delegating",
      "delivering"
    ].includes(phase));
  }

  beginTurn(provider: LiveVoiceProvider, text: string, providerItemID = "") {
    const clean = cleanText(text);
    const key = providerItemID ? `${provider}:${providerItemID}` : "";
    const existing = key ? this.providerTurns.get(key) : undefined;
    if (existing && this.snapshotValue.turns[existing] && !this.snapshotValue.turns[existing].interrupted) {
      if (clean.length > this.snapshotValue.turns[existing].text.length) {
        this.dispatch({ type: "turn_text_updated", turnID: existing, text: clean, at: this.now() });
      }
      return existing;
    }
    this.prunePendingApprovals();
    if (this.pendingApprovals.size && !isClearApprovalText(clean) && (isApprovalRejection(clean) || clean.length > 0)) {
      this.clearPendingApprovals();
    }
    const at = this.now();
    const turnID = `voice-${provider}-${at.toString(36)}-${(++this.sequence).toString(36)}`;
    const turn: VoiceTurn = {
      turnID,
      provider,
      providerItemID: providerItemID || undefined,
      text: clean,
      phase: "ready",
      createdAt: at,
      updatedAt: at,
      toolSteps: 0,
      interrupted: false
    };
    if (key) this.providerTurns.set(key, turnID);
    this.dispatch({ type: "turn_started", turn, at });
    this.dependencies.trace?.record({ at, type: "transcript_finalized", turnID, provider, textLength: clean.length, textHash: hashText(clean) });
    return turnID;
  }

  recordProviderEvent(event: ProviderEvent) {
    const eventTurn = "turnID" in event && event.turnID
      ? this.snapshotValue.turns[event.turnID]
      : undefined;
    const eventTurnFinished = Boolean(eventTurn && ["completed", "interrupted", "failed"].includes(eventTurn.phase));
    if (
      event.type === "interrupted"
      && event.turnID
      && !this.shouldPreserveTurnOnInterruption(event.turnID)
    ) this.interruptTurn(event.turnID, event.reason);
    if (event.type === "connection_closed") this.dispatch({ type: "session_connecting", at: event.at });
    if (event.type === "connection_restored") this.open();
    if (
      event.type === "audio_started"
      && !eventTurnFinished
      && !["quiet", "stopped"].includes(this.snapshotValue.voice)
    ) {
      this.setVoicePhase("speaking");
    }
    if (event.type === "response_completed" && !["quiet", "stopped"].includes(this.snapshotValue.voice)) {
      this.setVoicePhase("listening");
    }
    this.dependencies.trace?.record({
      at: event.at,
      type: event.type,
      turnID: "turnID" in event ? event.turnID : undefined,
      callID: "callID" in event ? event.callID : undefined,
      provider: event.provider,
      textLength: "textLength" in event ? event.textLength : undefined,
      detail: "reason" in event
        ? event.reason
        : event.type === "tool_requested"
          ? event.toolName
          : undefined
    });
  }

  interruptTurn(turnID: string, reason: string) {
    const turn = this.snapshotValue.turns[turnID];
    if (!turn || ["completed", "interrupted", "failed"].includes(turn.phase)) return;
    this.dispatch({ type: "turn_interrupted", turnID, at: this.now() });
    this.selectionGrants.delete(turnID);
    this.dependencies.trace?.record({ at: this.now(), type: "turn_interrupted", turnID, detail: reason });
  }

  claimFinalDelivery(turnID: string, deliveryID: string) {
    const turn = this.snapshotValue.turns[turnID];
    if (!turn || turn.interrupted || turn.finalDeliveryID) return false;
    this.dispatch({ type: "turn_delivery_claimed", turnID, deliveryID, at: this.now() });
    this.dependencies.trace?.record({ at: this.now(), type: "final_delivery_claimed", turnID, detail: deliveryID });
    return true;
  }

  completeTurn(turnID: string) {
    this.dispatch({ type: "turn_phase_changed", turnID, phase: "completed", at: this.now() });
    this.selectionGrants.delete(turnID);
  }

  private claimAction(
    turnID: string,
    actionOwner: VoiceTurnActionOwner,
    options: { operationID?: string; taskID?: string } = {}
  ) {
    this.dispatch({
      type: "turn_action_owned",
      turnID,
      actionOwner,
      operationID: options.operationID,
      taskID: options.taskID,
      at: this.now()
    });
  }

  assessAssistantActionClaim(turnID: string, text: string) {
    const turn = this.snapshotValue.turns[turnID];
    const actionClaim = looksLikeActionAcknowledgement(text);
    if (!turn || !actionClaim || turn.actionOwner) {
      return {
        actionClaim,
        grounded: Boolean(!actionClaim || turn?.actionOwner),
        shouldCorrect: false,
        actionOwner: turn?.actionOwner,
        operationID: turn?.operationID,
        taskID: turn?.taskID
      };
    }
    const shouldCorrect = turn.ungroundedActionClaim !== true;
    this.dispatch({ type: "turn_ungrounded_action_claimed", turnID, at: this.now() });
    return {
      actionClaim: true,
      grounded: false,
      shouldCorrect,
      actionOwner: undefined,
      operationID: undefined,
      taskID: undefined
    };
  }

  async capability(turnID: string, callID: string, raw: AssistantCapabilityArguments): Promise<CapabilityResult> {
    const turn = this.snapshotValue.turns[turnID];
    const startedAt = this.now();
    const requestID = randomUUID();
    if (!turn) return { requestID, turnID, callID, status: "failed", error: "Voice turn was not found.", errorCode: "turn_not_found", startedAt, finishedAt: this.now() };
    if (turn.interrupted) return { requestID, turnID, callID, status: "failed", error: "The voice turn was interrupted.", errorCode: "turn_interrupted", startedAt, finishedAt: this.now() };
    if (turn.toolSteps >= 8) {
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "waiting_for_clarification", at: this.now() });
      return {
        requestID,
        turnID,
        callID,
        status: "clarification_required",
        message: "I could not finish safely in eight tool steps. Ask one short clarification question.",
        errorCode: "tool_step_limit",
        startedAt,
        finishedAt: this.now()
      };
    }
    const pendingApproval = this.approvedRequestForTurn(turn, raw);
    const effectiveRaw: AssistantCapabilityArguments = pendingApproval
      ? {
          goal: pendingApproval.goal,
          operation: pendingApproval.operation,
          sourceHints: pendingApproval.sourceHints,
          capabilityID: pendingApproval.capabilityID,
          arguments: pendingApproval.arguments,
          confirmationToken: pendingApproval.token
        }
      : raw;
    this.dispatch({ type: "turn_step_recorded", turnID, callID, at: this.now() });
    this.dispatch({ type: "turn_phase_changed", turnID, phase: "selecting_capability", at: this.now() });

    const operation = operationValue(effectiveRaw.operation);
    const goal = cleanText(effectiveRaw.goal) || turn.text;
    const sourceHints = stringList(effectiveRaw.sourceHints);
    const contextResources = [
      ...(this.dependencies.contextResources?.() ?? []),
      ...this.recentResources
    ];
    const selectionKey = capabilitySelectionKey(goal, operation, sourceHints);
    const selectionGrant = this.selectionGrants.get(turnID);
    const resolution = this.dependencies.registry.resolve({
      goal,
      operation,
      sourceHints,
      capabilityID: cleanText(effectiveRaw.capabilityID),
      arguments: objectValue(effectiveRaw.arguments),
      contextResources,
      authorizedCapabilityIDs: selectionGrant?.key === selectionKey ? selectionGrant.capabilityIDs : []
    });

    // Trace every resolution outcome. Instant non-executing replies
    // (selection/clarification/failed) were previously invisible in the
    // trace, which made "the model says it has no tool" undiagnosable.
    this.dependencies.trace?.record({
      at: this.now(),
      type: "capability_resolution",
      turnID,
      callID,
      detail: resolution.kind === "selected"
        ? `selected:${resolution.descriptor.id}`
        : resolution.kind === "failed"
          ? `failed:${resolution.errorCode}`
          : `${resolution.kind}:${resolution.candidates.map((candidate) => candidate.id).join(",") || "no-candidates"}`
    });
    if (resolution.kind === "failed") {
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "failed", error: resolution.message, at: this.now() });
      return { requestID, turnID, callID, status: "failed", error: resolution.message, errorCode: resolution.errorCode, startedAt, finishedAt: this.now() };
    }
    if (resolution.kind === "selection_required" || resolution.kind === "clarification_required") {
      if (resolution.kind === "selection_required") {
        this.selectionGrants.set(turnID, {
          key: selectionKey,
          capabilityIDs: resolution.candidates.map((candidate) => candidate.id)
        });
      }
      this.dispatch({
        type: "turn_phase_changed",
        turnID,
        phase: resolution.kind === "selection_required" ? "selecting_capability" : "waiting_for_clarification",
        at: this.now()
      });
      return {
        requestID,
        turnID,
        callID,
        status: resolution.kind,
        candidates: resolution.candidates,
        resources: resourcesForCandidates(resolution.candidates, contextResources),
        message: resolution.message,
        startedAt,
        finishedAt: this.now()
      };
    }

    const descriptor = resolution.descriptor;
    const capabilityArguments = declarativelyBoundArguments(
      descriptor,
      objectValue(effectiveRaw.arguments),
      goal,
      contextResources
    );
    // The dispatcher tools (assistant_capability) carry the user's request as
    // `goal`, but providers routinely leave the capability's inner arguments
    // empty. Capabilities that declare a `userIntent` parameter (search tools
    // derive their query terms from it) get the goal as a fallback so a bare
    // "check my messages for appointments" still produces search terms.
    const schemaProperties = objectValue((descriptor.inputSchema as JsonObject | undefined)?.properties);
    if (schemaProperties && "userIntent" in schemaProperties && !cleanText(capabilityArguments.userIntent)) {
      capabilityArguments.userIntent = goal;
    }
    // Architectural gate for the dispatcher protocol: the model cannot see a
    // capability's argument schema when it calls assistant_capability, so it
    // routinely sends empty arguments (and per-phrase server parsing does not
    // scale). Validate the schema's required fields BEFORE approval/execution
    // and, when missing, hand the schema back with a re-call instruction — a
    // self-describing protocol state any provider can follow. Capabilities
    // that declare `userIntent` self-derive their fields server-side and skip
    // the round-trip.
    const requiredFields = Array.isArray((descriptor.inputSchema as JsonObject | undefined)?.required)
      ? ((descriptor.inputSchema as JsonObject).required as unknown[]).map((field) => String(field))
      : [];
    // Only the fields a capability explicitly declares as derivable from the
    // injected userIntent may skip validation (a title can be parsed from
    // speech; an id never can — skipping ALL fields let update calls through
    // without an id, straight into an execution error).
    const userIntentAvailable = Boolean(schemaProperties && "userIntent" in schemaProperties && cleanText(capabilityArguments.userIntent));
    const derivableFields = new Set(userIntentAvailable ? descriptor.selfDerivedArguments ?? [] : []);
    const missingRequired = requiredFields.filter((field) => {
      if (field === "userIntent" || derivableFields.has(field)) return false;
      const owner = descriptor.argumentBindings?.[field]?.owner;
      if (owner === "goal-derived") return false;
      const value = capabilityArguments[field];
      if (value === undefined || value === null) return true;
      return typeof value === "string" && !value.trim();
    });
    if (missingRequired.length) {
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "waiting_for_clarification", at: this.now() });
      this.dependencies.trace?.record({
        at: this.now(),
        type: "arguments_required",
        turnID,
        callID,
        capabilityID: descriptor.id,
        detail: missingRequired.join(",")
      });
      return {
        requestID,
        turnID,
        callID,
        status: "arguments_required",
        capabilityID: descriptor.id,
        candidates: [{
          id: descriptor.id,
          description: descriptor.description,
          operations: descriptor.operations,
          source: descriptor.source,
          risk: descriptor.risk,
          inputSchema: descriptor.inputSchema,
          resourceKinds: descriptor.resourceKinds
        }],
        message: `The tool did NOT run — required arguments are missing: ${missingRequired.join(", ")}. The user's request was: "${goal}". Immediately call assistant_capability again with capabilityID "${descriptor.id}" and an arguments object filled from the user's request, following this schema: ${JSON.stringify(descriptor.inputSchema)}. Do not ask the user to repeat details already in the request; ask one short question only if a required detail is truly absent.`,
        errorCode: "arguments_required",
        startedAt,
        finishedAt: this.now()
      };
    }
    const confirmationToken = cleanText(effectiveRaw.confirmationToken);
    const idempotencyKey = `${turnID}:${descriptor.id}:${hashText(JSON.stringify(capabilityArguments))}`;
    const approvalActionKey = `${descriptor.id}:${hashText(JSON.stringify(capabilityArguments))}`;
    if (descriptor.risk === "sensitive_write" && this.confirmedTokens.get(confirmationToken) !== approvalActionKey) {
      const token = randomUUID();
      this.rememberPendingApproval({
        token,
        actionKey: approvalActionKey,
        originTurnID: turnID,
        goal,
        operation,
        sourceHints,
        capabilityID: descriptor.id,
        arguments: capabilityArguments,
        createdAt: this.now()
      });
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "waiting_for_approval", at: this.now() });
      return {
        requestID,
        turnID,
        callID,
        status: "approval_required",
        capabilityID: descriptor.id,
        confirmationToken: token,
        // The action only resumes when the model calls the tool AGAIN after
        // the user's spoken yes. Without this spelled out, the model heard
        // "yes", said "One moment", and stalled forever (seen live with a
        // planner delete).
        message: `Confirmation needed before this runs. Ask the user one short spoken yes/no question about this exact action. After they say yes, you MUST immediately call assistant_capability again with capabilityID "${descriptor.id}", the same arguments, and confirmationToken "${token}" — that call performs the action. Never just acknowledge the yes without making that call, and never say it is done before the call returns.`,
        startedAt,
        finishedAt: this.now()
      };
    }
    if (descriptor.risk === "sensitive_write" && confirmationToken) {
      this.consumePendingApproval(confirmationToken);
    }

    const cached = this.idempotentResults.get(idempotencyKey);
    if (cached && descriptor.idempotency !== "none") return cached;

    const request: CapabilityRequest = {
      requestID,
      turnID,
      callID,
      goal,
      operation,
      sourceHints,
      capabilityID: descriptor.id,
      arguments: capabilityArguments,
      confirmationToken: confirmationToken || undefined,
      idempotencyKey,
      createdAt: startedAt
    };
    const requirements = descriptor.permissionRequirements ?? [];
    if (requirements.length && this.dependencies.checkPermissions) {
      const permissionIDs = [...new Set(requirements.map((requirement) => requirement.permissionID))];
      let permissions = await this.dependencies.checkPermissions(permissionIDs);
      const missing = () => permissions.filter((permission) => requirements.some((requirement) =>
        requirement.permissionID === permission.id
        && !(requirement.access === "read" ? permission.canRead : permission.canWrite)
      ));
      if (
        descriptor.risk === "read"
        && missing().length === 1
        && missing()[0].state === "notDetermined"
        && this.dependencies.requestPermission
      ) {
        this.dispatch({ type: "turn_phase_changed", turnID, phase: "waiting_for_permission", at: this.now() });
        this.dependencies.onProgress?.({
          turnID,
          callID,
          stage: "permission",
          detail: `Waiting for ${missing()[0].owner.displayName} permission.`
        });
        await this.dependencies.requestPermission(missing()[0].id).catch(() => undefined);
        permissions = await this.dependencies.checkPermissions(permissionIDs);
      }
      const unavailable = missing();
      if (unavailable.length) {
        const action = unavailable.some((permission) => permission.needsRestart)
          ? "restart_app"
          : unavailable.some((permission) => permission.state === "notDetermined")
            ? "request_permission"
            : "open_settings";
        this.dispatch({ type: "turn_phase_changed", turnID, phase: "waiting_for_permission", at: this.now() });
        return {
          requestID,
          turnID,
          callID,
          status: "permission_required",
          capabilityID: descriptor.id,
          permissions: unavailable,
          action,
          message: unavailable.map((permission) => permission.detail).join(" "),
          errorCode: "native_permission_required",
          startedAt,
          finishedAt: this.now()
        };
      }
    }
    this.dispatch({ type: "turn_phase_changed", turnID, phase: "executing_capability", at: this.now() });
    const progress = () => this.dependencies.onProgress?.({ turnID, callID, stage: "executing", detail: `Still using ${descriptor.source}.` });
    const firstProgress = setTimeout(progress, 1_000);
    const continuedProgress = setInterval(progress, 8_000);
    if (typeof firstProgress.unref === "function") firstProgress.unref();
    if (typeof continuedProgress.unref === "function") continuedProgress.unref();
    const stopProgress = () => {
      clearTimeout(firstProgress);
      clearInterval(continuedProgress);
    };
    this.dependencies.trace?.record({ at: this.now(), type: "capability_started", turnID, callID, capabilityID: descriptor.id });
    try {
      let output: unknown;
      try {
        output = await timeout(this.dependencies.executeCapability(descriptor, request), descriptor.timeoutMs);
      } catch (error) {
        if (descriptor.risk !== "read") throw error;
        this.dependencies.onProgress?.({ turnID, callID, stage: "retrying", detail: `Retrying ${descriptor.source} once.` });
        output = await timeout(this.dependencies.executeCapability(descriptor, request), descriptor.timeoutMs);
      }
      const outputObject = objectValue(output);
      const overrideStatus = cleanText(outputObject.__voiceCapabilityStatus);
      if (["selection_required", "clarification_required", "not_found", "arguments_required", "approval_required", "permission_required", "running", "failed"].includes(overrideStatus)) {
        stopProgress();
        const token = overrideStatus === "approval_required" ? randomUUID() : undefined;
        if (token) {
          this.rememberPendingApproval({
            token,
            actionKey: approvalActionKey,
            originTurnID: turnID,
            goal,
            operation,
            sourceHints,
            capabilityID: descriptor.id,
            arguments: capabilityArguments,
            createdAt: this.now()
          });
        }
        const phase = overrideStatus === "selection_required"
          ? "selecting_capability"
          : overrideStatus === "clarification_required" || overrideStatus === "arguments_required"
            ? "waiting_for_clarification"
            : overrideStatus === "approval_required"
              ? "waiting_for_approval"
              : overrideStatus === "permission_required"
                ? "waiting_for_permission"
              : overrideStatus === "running"
                ? "delegating"
                : overrideStatus === "not_found"
                  ? "delivering"
                  : "failed";
        this.dispatch({ type: "turn_phase_changed", turnID, phase, at: this.now(), error: overrideStatus === "failed" ? cleanText(outputObject.error) : undefined });
        const result: CapabilityResult = {
          requestID,
          turnID,
          callID,
          status: overrideStatus as CapabilityResult["status"],
          capabilityID: descriptor.id,
          output: outputObject.output,
          message: cleanText(outputObject.message) || undefined,
          error: cleanText(outputObject.error) || undefined,
          errorCode: cleanText(outputObject.errorCode) || undefined,
          confirmationToken: token,
          startedAt,
          finishedAt: this.now()
        };
        if (descriptor.risk !== "read" && overrideStatus === "failed" && descriptor.idempotency !== "none") {
          this.idempotentResults.set(idempotencyKey, result);
        }
        if (overrideStatus === "running") {
          this.claimAction(turnID, "capability", { operationID: requestID });
        }
        return result;
      }
      const result: CapabilityResult = {
        requestID,
        turnID,
        callID,
        status: descriptor.executionMode === "background" ? "running" : "completed",
        capabilityID: descriptor.id,
        output,
        resources: resourcesFromOutput(descriptor, output),
        startedAt,
        finishedAt: this.now()
      };
      this.rememberResources(result.resources ?? []);
      this.claimAction(turnID, "capability", { operationID: requestID });
      if (descriptor.idempotency !== "none") this.idempotentResults.set(idempotencyKey, result);
      stopProgress();
      this.dispatch({
        type: "turn_phase_changed",
        turnID,
        phase: descriptor.executionMode === "background" ? "delegating" : "delivering",
        at: this.now()
      });
      this.dependencies.trace?.record({
        at: this.now(),
        type: "capability_finished",
        turnID,
        callID,
        capabilityID: descriptor.id,
        durationMs: this.now() - startedAt
      });
      return result;
    } catch (error) {
      stopProgress();
      if (error instanceof NativePermissionRequiredError) {
        this.dispatch({ type: "turn_phase_changed", turnID, phase: "waiting_for_permission", at: this.now() });
        return {
          requestID,
          turnID,
          callID,
          status: "permission_required",
          capabilityID: descriptor.id,
          permissions: [error.snapshot],
          action: error.snapshot.needsRestart
            ? "restart_app"
            : error.snapshot.state === "notDetermined"
              ? "request_permission"
              : "open_settings",
          message: error.message,
          errorCode: "native_permission_required",
          startedAt,
          finishedAt: this.now()
        };
      }
      const message = error instanceof Error ? error.message : "The capability failed.";
      // Bridge validators reject incomplete input by throwing the question to
      // ask the user ("What task should I add?"). Surfacing that as a failed
      // status made voice models apologize about "a problem" instead of just
      // asking — return it as a clarification so the model relays the question.
      if (/\?\s*$/.test(message.trim())) {
        this.dispatch({ type: "turn_phase_changed", turnID, phase: "waiting_for_clarification", at: this.now() });
        this.dependencies.trace?.record({
          at: this.now(),
          type: "capability_failed",
          turnID,
          callID,
          capabilityID: descriptor.id,
          durationMs: this.now() - startedAt,
          errorCode: "clarification_required",
          detail: message
        });
        return {
          requestID,
          turnID,
          callID,
          status: "clarification_required",
          capabilityID: descriptor.id,
          // Providers routinely leave the capability's inner arguments empty
          // even when the user's request contains every needed detail
          // ("add a reminder to take out the trash every Friday at 8am").
          // Telling the model to ask the user first caused endless
          // "What should I add?" loops. Retry-with-arguments comes first;
          // asking the user is the fallback.
          message: `INTERNAL INSTRUCTION — never read any part of this aloud and never tell the user that nothing happened, that a tool failed, or that "nothing was done". Context for you only: The tool did NOT run because a required detail is missing — nothing was read or changed. The user's request was: "${goal}". If that request already contains the missing detail, immediately and SILENTLY call assistant_capability again with capabilityID "${descriptor.id}" and the arguments object filled in explicitly from the user's words (for example title, dueDate, recurrence) — do NOT ask the user to repeat what they already said, and do not announce the retry. Then answer with the final result only. Only if the request truly does not contain it, ask exactly: ${message}`,
          errorCode: "missing_input",
          startedAt,
          finishedAt: this.now()
        };
      }
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "failed", error: message, at: this.now() });
      this.dependencies.trace?.record({
        at: this.now(),
        type: "capability_failed",
        turnID,
        callID,
        capabilityID: descriptor.id,
        durationMs: this.now() - startedAt,
        errorCode: "capability_failed",
        detail: message
      });
      const result: CapabilityResult = {
        requestID,
        turnID,
        callID,
        status: "failed",
        capabilityID: descriptor.id,
        error: message,
        errorCode: "capability_failed",
        retryable: false,
        startedAt,
        finishedAt: this.now()
      };
      if (descriptor.risk !== "read" && descriptor.idempotency !== "none") {
        this.idempotentResults.set(idempotencyKey, result);
      }
      return result;
    }
  }

  async delegate(turnID: string, callID: string, raw: AssistantDelegateArguments) {
    const turn = this.snapshotValue.turns[turnID];
    const goal = cleanText(raw.goal) || turn?.text || "";
    if (!turn) return { status: "failed", error: "Voice turn was not found.", errorCode: "turn_not_found" };
    if (turn.toolSteps >= 4) return { status: "clarification_required", message: "I need one short clarification before starting work." };
    this.dispatch({ type: "turn_step_recorded", turnID, callID, at: this.now() });
    if ((this.dependencies.workerPolicy ?? "auto") === "never") {
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "failed", error: "Background workers are disabled for Live Voice.", at: this.now() });
      return { status: "failed", error: "Background workers are disabled for Live Voice.", errorCode: "worker_disabled" };
    }
    if (raw.mode === "follow_up" || raw.mode === "rerun") {
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "delegating", at: this.now() });
      const output = await this.dependencies.delegateWork({ ...raw, goal, turnID, callID, contextResources: this.contextResources().slice(0, 8) });
      const taskID = cleanText(resultRecord(output).taskID);
      if (taskID) this.claimAction(turnID, "delegation", { taskID });
      return output;
    }
    const transcript = normalizedCommand(turn.text);
    const explicitWorker = ["codex", "claude", "copilot", "computer use", "browser", "terminal"]
      .some((provider) => transcript.includes(provider));
    // Delegated workers have NO Apple Reminders/Calendar tools (the knowledge
    // MCP cannot tell workers apart from external agents, so those tools are
    // withheld). Delegating native Apple work is guaranteed to fail — run it
    // directly even when the user names a worker ("ask codex to do it").
    const asksAppleNativeWork = /\b(?:apple|icloud)\s+(?:reminders?|calendar)\b|\breminders?\s+app\b|\bcalendar\s+app\b|\breminder\b/
      .test(`${transcript} ${normalizedCommand(goal)}`);
    if ((!explicitWorker || asksAppleNativeWork) && this.dependencies.registry.hasCompatibleDirectCapability(goal)) {
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "selecting_capability", at: this.now() });
      return {
        status: "selection_required",
        message: asksAppleNativeWork && explicitWorker
          ? "Delegated workers cannot access Apple Reminders or Apple Calendar, so delegating this would fail. Do it yourself right now with assistant_capability — do not delegate."
          : "A direct local capability can handle this. Use assistant_capability instead of delegating."
      };
    }
    this.dispatch({ type: "turn_phase_changed", turnID, phase: "delegating", at: this.now() });
    // Hand the worker the ids this session already discovered (recent first) so
    // follow-up work doesn't have to re-search for them.
    const output = await this.dependencies.delegateWork({ ...raw, goal, turnID, callID, contextResources: this.contextResources().slice(0, 8) });
    const taskID = cleanText(resultRecord(output).taskID);
    if (taskID) this.claimAction(turnID, "delegation", { taskID });
    return output;
  }

  async taskStatus(turnID: string, callID: string, taskID?: string) {
    const turn = this.snapshotValue.turns[turnID];
    if (!turn) return { status: "failed", error: "Voice turn was not found.", errorCode: "turn_not_found" };
    if (turn.toolSteps >= 4) return { status: "clarification_required", message: "I could not finish safely in four tool steps." };
    this.dispatch({ type: "turn_step_recorded", turnID, callID, at: this.now() });
    this.dispatch({ type: "turn_phase_changed", turnID, phase: "executing_capability", at: this.now() });
    try {
      const output = await this.dependencies.taskStatus(taskID);
      this.claimAction(turnID, "status", { taskID: cleanText(resultRecord(output).taskID) || taskID });
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "delivering", at: this.now() });
      if (output && typeof output === "object" && !Array.isArray(output)) {
        return { lookupStatus: "completed", ...output };
      }
      return { lookupStatus: "completed", result: output };
    } catch (error) {
      const message = error instanceof Error ? error.message : "Task status could not be read.";
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "failed", error: message, at: this.now() });
      return { lookupStatus: "failed", error: message, errorCode: "task_status_failed" };
    }
  }

  async cancelTask(turnID: string, callID: string, taskID?: string) {
    const turn = this.snapshotValue.turns[turnID];
    if (!turn) return { status: "failed", error: "Voice turn was not found.", errorCode: "turn_not_found" };
    if (turn.toolSteps >= 4) return { status: "clarification_required", message: "I could not finish safely in four tool steps." };
    this.dispatch({ type: "turn_step_recorded", turnID, callID, at: this.now() });
    if (!isTaskCancellation(normalizedCommand(turn.text))) {
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "waiting_for_clarification", at: this.now() });
      return { status: "clarification_required", message: "Ask whether the user wants to cancel the task." };
    }
    this.dispatch({ type: "turn_phase_changed", turnID, phase: "executing_capability", at: this.now() });
    try {
      const output = await this.dependencies.cancelTask(taskID);
      this.claimAction(turnID, "cancellation", { taskID });
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "delivering", at: this.now() });
      return { status: "completed", output };
    } catch (error) {
      const message = error instanceof Error ? error.message : "The task could not be cancelled.";
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "failed", error: message, at: this.now() });
      return { status: "failed", error: message, errorCode: "task_cancel_failed" };
    }
  }

  async openView(turnID: string, callID: string, destination: LiveVoiceViewDestination) {
    const turn = this.snapshotValue.turns[turnID];
    if (!turn) return { status: "failed", error: "Voice turn was not found.", errorCode: "turn_not_found" };
    if (turn.toolSteps >= 4) return { status: "clarification_required", message: "I could not finish safely in four tool steps." };
    const allowed: LiveVoiceViewDestination[] = ["today", "notes", "threads", "voice_log", "review_inbox", "settings"];
    if (!allowed.includes(destination)) {
      return { status: "failed", error: "That OpenAssist view is not available to Live Voice.", errorCode: "view_not_allowed" };
    }
    this.dispatch({ type: "turn_step_recorded", turnID, callID, at: this.now() });
    this.dispatch({ type: "turn_phase_changed", turnID, phase: "executing_capability", at: this.now() });
    try {
      const output = await this.dependencies.openView(destination);
      this.claimAction(turnID, "navigation", { operationID: `open-view:${destination}` });
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "delivering", at: this.now() });
      return { status: "completed", destination, output };
    } catch (error) {
      const message = error instanceof Error ? error.message : "The OpenAssist view could not be opened.";
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "failed", error: message, at: this.now() });
      return { status: "failed", error: message, errorCode: "view_open_failed" };
    }
  }
}
