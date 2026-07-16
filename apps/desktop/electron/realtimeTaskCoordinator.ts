export type RealtimeTaskState = "queued" | "running" | "completed" | "failed" | "cancelled";

export type RealtimeTaskDeliveryState = "pending" | "queued" | "speaking" | "delivered";

export type RealtimeTaskKind = "single" | "parallel";

export type RealtimeTaskProgressEntry = {
  id: string;
  text: string;
  createdAt: number;
};

export type RealtimeTaskRecord = {
  taskID: string;
  scopeKey: string;
  callID: string;
  sourceTurnID: string;
  userText: string;
  prompt: string;
  normalizedPrompt: string;
  workerProvider: string;
  agentLabel: string;
  replyMode: "message" | "function";
  kind: RealtimeTaskKind;
  state: RealtimeTaskState;
  progress: string;
  progressEntries: RealtimeTaskProgressEntry[];
  lastActivity: string;
  result: string;
  backendText: string;
  error: string;
  createdAt: number;
  startedAt: number;
  updatedAt: number;
  finishedAt?: number;
  deliveryState: RealtimeTaskDeliveryState;
  answerSent: boolean;
  persisted: boolean;
};

export type RealtimeTaskStartInput = {
  taskID: string;
  scopeKey?: string;
  callID?: string;
  sourceTurnID?: string;
  userText?: string;
  prompt: string;
  workerProvider?: string;
  replyMode?: "message" | "function";
  kind?: RealtimeTaskKind;
};

export type RealtimeTaskStartResult =
  | { ok: true; task: RealtimeTaskRecord }
  | { ok: false; reason: "duplicate" | "limit" | "invalid"; task?: RealtimeTaskRecord };

export function normalizeRealtimeTaskPrompt(prompt: string) {
  return String(prompt || "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}'\s/-]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export class RealtimeTaskCoordinator {
  private readonly tasks = new Map<string, RealtimeTaskRecord>();

  constructor(
    private readonly maxActiveTasks = 6,
    private readonly now: () => number = () => Date.now()
  ) {}

  start(input: RealtimeTaskStartInput): RealtimeTaskStartResult {
    const taskID = input.taskID.trim();
    const prompt = input.prompt.trim();
    const normalizedPrompt = normalizeRealtimeTaskPrompt(prompt);
    if (!taskID || !prompt || !normalizedPrompt) return { ok: false, reason: "invalid" };

    const existingID = this.tasks.get(taskID);
    if (existingID) {
      return { ok: false, reason: "duplicate", task: existingID };
    }
    const scopeKey = input.scopeKey?.trim() || "default";
    const duplicate = this.active(scopeKey).find((task) => task.normalizedPrompt === normalizedPrompt);
    if (duplicate) return { ok: false, reason: "duplicate", task: duplicate };
    if (this.active().length >= this.maxActiveTasks) return { ok: false, reason: "limit" };

    const now = this.now();
    const workerProvider = input.workerProvider?.trim() || "Agent";
    const task: RealtimeTaskRecord = {
      taskID,
      scopeKey,
      callID: input.callID?.trim() || taskID,
      sourceTurnID: input.sourceTurnID?.trim() || taskID,
      userText: input.userText?.trim() || prompt,
      prompt,
      normalizedPrompt,
      workerProvider,
      agentLabel: workerProvider,
      replyMode: input.replyMode ?? "message",
      kind: input.kind ?? "single",
      state: "running",
      progress: "",
      progressEntries: [],
      lastActivity: "",
      result: "",
      backendText: "",
      error: "",
      createdAt: now,
      startedAt: now,
      updatedAt: now,
      deliveryState: "pending",
      answerSent: false,
      persisted: false
    };
    this.tasks.set(taskID, task);
    this.prune();
    return { ok: true, task };
  }

  get(taskID: string) {
    return this.tasks.get(taskID);
  }

  getByCallID(callID: string, scopeKey?: string) {
    return [...this.tasks.values()].find((task) => task.callID === callID && (!scopeKey || task.scopeKey === scopeKey));
  }

  all(scopeKey?: string) {
    return [...this.tasks.values()]
      .filter((task) => !scopeKey || task.scopeKey === scopeKey)
      .sort((left, right) => left.createdAt - right.createdAt);
  }

  active(scopeKey?: string) {
    return [...this.tasks.values()]
      .filter((task) => this.isActive(task) && (!scopeKey || task.scopeKey === scopeKey))
      .sort((left, right) => left.createdAt - right.createdAt);
  }

  activeMap(scopeKey?: string) {
    return new Map(this.active(scopeKey).map((task) => [task.callID, task]));
  }

  activeCount(kind?: RealtimeTaskKind, scopeKey?: string) {
    return this.active(scopeKey).filter((task) => !kind || task.kind === kind).length;
  }

  hasActivePrompt(prompt: string, scopeKey?: string) {
    const normalized = normalizeRealtimeTaskPrompt(prompt);
    return this.active(scopeKey).some((task) => task.normalizedPrompt === normalized);
  }

  latestActive(scopeKey?: string) {
    return this.active(scopeKey).at(-1);
  }

  latestRelevant(scopeKey?: string) {
    const tasks = [...this.tasks.values()]
      .filter((task) => !scopeKey || task.scopeKey === scopeKey)
      .sort((left, right) => right.updatedAt - left.updatedAt);
    return tasks.find((task) => this.isActive(task))
      ?? tasks.find((task) => task.deliveryState !== "delivered")
      ?? tasks[0];
  }

  updateProgress(taskID: string, progress: string) {
    const task = this.tasks.get(taskID);
    const detail = progress.replace(/\s+/g, " ").trim().slice(0, 700);
    if (!task || !this.isActive(task) || !detail) return task;
    if (task.progressEntries.at(-1)?.text !== detail) {
      const createdAt = this.now();
      task.progressEntries.push({
        id: `${task.taskID}-progress-${createdAt}-${task.progressEntries.length}`,
        text: detail,
        createdAt
      });
      if (task.progressEntries.length > 20) {
        task.progressEntries.splice(0, task.progressEntries.length - 20);
      }
    }
    task.progress = detail;
    task.lastActivity = detail;
    // Keep only a compact compatibility value. Full provider output and raw
    // events must never accumulate in the coordinator or Voice Log.
    task.backendText = task.progressEntries.map((entry) => entry.text).join("\n");
    task.updatedAt = this.now();
    return task;
  }

  complete(taskID: string, result: string) {
    const text = result.trim();
    if (!text) return this.fail(taskID, "The agent finished without returning an answer.");
    return this.finish(taskID, "completed", text, "");
  }

  fail(taskID: string, error: string) {
    const message = error.trim() || "The agent could not finish the task.";
    return this.finish(taskID, "failed", "", message);
  }

  cancel(taskID: string, reason = "The task was cancelled.") {
    return this.finish(taskID, "cancelled", "", reason.trim() || "The task was cancelled.");
  }

  markDelivery(taskID: string, state: RealtimeTaskDeliveryState) {
    const task = this.tasks.get(taskID);
    if (!task) return false;
    if (task.deliveryState === "delivered") return state === "delivered";
    task.deliveryState = state;
    task.answerSent = state === "delivered";
    task.updatedAt = this.now();
    this.prune();
    return true;
  }

  markPersisted(taskID: string) {
    const task = this.tasks.get(taskID);
    if (!task || task.persisted) return false;
    task.persisted = true;
    task.updatedAt = this.now();
    return true;
  }

  pendingDelivery(scopeKey?: string) {
    return [...this.tasks.values()]
      .filter((task) => !this.isActive(task) && task.deliveryState !== "delivered" && (!scopeKey || task.scopeKey === scopeKey))
      .sort((left, right) => (left.finishedAt ?? left.updatedAt) - (right.finishedAt ?? right.updatedAt));
  }

  visible(scopeKey?: string, recentFinishedMs = 15_000) {
    const now = this.now();
    return this.all(scopeKey).filter((task) =>
      this.isActive(task)
      || task.deliveryState !== "delivered"
      || Boolean(task.finishedAt && now - task.finishedAt <= recentFinishedMs)
    );
  }

  evictStale(maxIdleMs: number, scopeKey?: string) {
    const now = this.now();
    const evicted: RealtimeTaskRecord[] = [];
    for (const task of this.active(scopeKey)) {
      if (now - task.updatedAt < maxIdleMs) continue;
      const cancelled = this.cancel(task.taskID, "The delegated task stopped responding.");
      if (cancelled) evicted.push(cancelled);
    }
    return evicted;
  }

  cancelActive(reason = "The app closed before the delegated task finished.", scopeKey?: string) {
    return this.active(scopeKey)
      .map((task) => this.cancel(task.taskID, reason))
      .filter((task): task is RealtimeTaskRecord => Boolean(task));
  }

  snapshot() {
    return [...this.tasks.values()].map((task) => ({ ...task }));
  }

  private finish(taskID: string, state: Exclude<RealtimeTaskState, "queued" | "running">, result: string, error: string) {
    const task = this.tasks.get(taskID);
    if (!task || !this.isActive(task)) return task;
    const now = this.now();
    // Close the step trail so every finished card has a visible history —
    // fast runs that emitted no activities otherwise show an empty step log.
    const closingStep = state === "completed"
      ? "Delivered the result."
      : state === "cancelled"
        ? "Stopped by the user."
        : (error || "The task failed.").replace(/\s+/g, " ").trim().slice(0, 700);
    if (closingStep && task.progressEntries.at(-1)?.text !== closingStep) {
      task.progressEntries.push({
        id: `${task.taskID}-progress-${now}-${task.progressEntries.length}`,
        text: closingStep,
        createdAt: now
      });
      if (task.progressEntries.length > 20) {
        task.progressEntries.splice(0, task.progressEntries.length - 20);
      }
    }
    task.state = state;
    task.result = result;
    if (result) task.backendText = result;
    task.error = error;
    task.updatedAt = now;
    task.finishedAt = now;
    task.deliveryState = "pending";
    this.prune();
    return task;
  }

  private isActive(task: RealtimeTaskRecord) {
    return task.state === "queued" || task.state === "running";
  }

  private prune() {
    if (this.tasks.size <= 100) return;
    const removable = [...this.tasks.values()]
      .filter((task) => !this.isActive(task) && task.deliveryState === "delivered")
      .sort((left, right) => left.updatedAt - right.updatedAt);
    while (this.tasks.size > 100 && removable.length) {
      const task = removable.shift();
      if (task) this.tasks.delete(task.taskID);
    }
  }
}
