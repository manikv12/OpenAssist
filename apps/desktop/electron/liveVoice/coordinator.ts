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
  ProviderEvent,
  RealtimeWorkerPolicy,
  VoiceSnapshot,
  VoiceTurn,
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

function isTaskCancellation(value: string) {
  return /\b(cancel|stop|end|abort)\b.{0,45}\b(task|job|work|agent|worker)\b/.test(value)
    || /\b(task|job|work|agent|worker)\b.{0,45}\b(cancel|stop|end|abort)\b/.test(value)
    || /^(cancel|abort|end) (it|that|this)( please)?$/.test(value);
}

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
    this.dispatch({ type: "turn_step_recorded", turnID, callID, at: this.now() });
    this.dispatch({ type: "turn_phase_changed", turnID, phase: "selecting_capability", at: this.now() });

    const operation = operationValue(raw.operation);
    const goal = cleanText(raw.goal) || turn.text;
    const sourceHints = stringList(raw.sourceHints);
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
      capabilityID: cleanText(raw.capabilityID),
      arguments: objectValue(raw.arguments),
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
    const capabilityArguments = contextBoundArguments(descriptor, objectValue(raw.arguments), contextResources);
    // The dispatcher tools (assistant_capability) carry the user's request as
    // `goal`, but providers routinely leave the capability's inner arguments
    // empty. Capabilities that declare a `userIntent` parameter (search tools
    // derive their query terms from it) get the goal as a fallback so a bare
    // "check my messages for appointments" still produces search terms.
    const schemaProperties = objectValue((descriptor.inputSchema as JsonObject | undefined)?.properties);
    if (schemaProperties && "userIntent" in schemaProperties && !cleanText(capabilityArguments.userIntent)) {
      capabilityArguments.userIntent = goal;
    }
    const confirmationToken = cleanText(raw.confirmationToken);
    const idempotencyKey = `${turnID}:${descriptor.id}:${hashText(JSON.stringify(capabilityArguments))}`;
    if (descriptor.risk === "sensitive_write" && this.confirmedTokens.get(confirmationToken) !== idempotencyKey) {
      const token = randomUUID();
      this.confirmedTokens.set(token, idempotencyKey);
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "waiting_for_approval", at: this.now() });
      return {
        requestID,
        turnID,
        callID,
        status: "approval_required",
        capabilityID: descriptor.id,
        confirmationToken: token,
        message: `Confirm the ${descriptor.description.toLowerCase()} action before it runs.`,
        startedAt,
        finishedAt: this.now()
      };
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
      if (["selection_required", "clarification_required", "approval_required", "permission_required", "running", "failed"].includes(overrideStatus)) {
        stopProgress();
        const token = overrideStatus === "approval_required" ? randomUUID() : undefined;
        if (token) this.confirmedTokens.set(token, idempotencyKey);
        const phase = overrideStatus === "selection_required"
          ? "selecting_capability"
          : overrideStatus === "clarification_required"
            ? "waiting_for_clarification"
            : overrideStatus === "approval_required"
              ? "waiting_for_approval"
              : overrideStatus === "permission_required"
                ? "waiting_for_permission"
              : overrideStatus === "running"
                ? "delegating"
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
    const transcript = normalizedCommand(turn.text);
    const explicitWorker = ["codex", "claude", "copilot", "computer use", "browser", "terminal"]
      .some((provider) => transcript.includes(provider));
    if (!explicitWorker && this.dependencies.registry.hasCompatibleDirectCapability(goal)) {
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "selecting_capability", at: this.now() });
      return {
        status: "selection_required",
        message: "A direct local capability can handle this. Use assistant_capability instead of delegating."
      };
    }
    this.dispatch({ type: "turn_phase_changed", turnID, phase: "delegating", at: this.now() });
    // Hand the worker the ids this session already discovered (recent first) so
    // follow-up work doesn't have to re-search for them.
    return this.dependencies.delegateWork({ ...raw, goal, turnID, callID, contextResources: this.contextResources().slice(0, 8) });
  }

  async taskStatus(turnID: string, callID: string, taskID?: string) {
    const turn = this.snapshotValue.turns[turnID];
    if (!turn) return { status: "failed", error: "Voice turn was not found.", errorCode: "turn_not_found" };
    if (turn.toolSteps >= 4) return { status: "clarification_required", message: "I could not finish safely in four tool steps." };
    this.dispatch({ type: "turn_step_recorded", turnID, callID, at: this.now() });
    this.dispatch({ type: "turn_phase_changed", turnID, phase: "executing_capability", at: this.now() });
    try {
      const output = await this.dependencies.taskStatus(taskID);
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
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "delivering", at: this.now() });
      return { status: "completed", output };
    } catch (error) {
      const message = error instanceof Error ? error.message : "The task could not be cancelled.";
      this.dispatch({ type: "turn_phase_changed", turnID, phase: "failed", error: message, at: this.now() });
      return { status: "failed", error: message, errorCode: "task_cancel_failed" };
    }
  }
}
