/**
 * Owner-only Second Brain runner core.
 *
 * This module intentionally has no Electron, UI, Codex, or filesystem imports.
 * A host may inject a Codex/delegation executor, but it must not give that
 * executor general Google or external-action tools. Project Markdown is passed
 * in memory for one run and this core never stores a chat or transcript.
 */
import { createHash } from "node:crypto";

export const SECOND_BRAIN_OWNER_ORCHESTRATOR_ID = "openassist.owner.orchestrator";

export const SECOND_BRAIN_FIXED_BLOCKERS = [
  "missing_credential",
  "material_decision",
  "spending_limit",
  "external_action",
  "technical_blocker",
] as const;

export type SecondBrainBlockerCode = (typeof SECOND_BRAIN_FIXED_BLOCKERS)[number];

export type SecondBrainArtifactPointer = {
  fileId: string;
  mimeType: string;
  sha256: string;
};

export type SecondBrainClaim = {
  found: boolean;
  assignmentId?: string;
  leaseToken?: string;
  run?: {
    id: string;
    assignmentId: string;
    workItemId: string;
    projectId: string;
    accountId: string;
    parentId?: string;
    agentId: string;
    status: string;
    leaseExpiresAt: number;
    policy: {
      autonomyMode: "autonomous" | "guarded";
      externalActionAllowed: boolean;
      maxSpendCents: number;
    };
  };
};

export type SecondBrainSourceDocument = {
  markdown: string;
  truncated?: boolean;
  project?: Record<string, unknown>;
  workItem?: Record<string, unknown>;
};

export type SecondBrainKnowledgeSearchResult = {
  markdown: string;
  resultCount: number;
  truncated?: boolean;
};

export interface SecondBrainWorkspacePort {
  claimNext(input: { agentId: string; leaseSeconds: number }): Promise<SecondBrainClaim>;
  readProject(input: { projectId: string }): Promise<SecondBrainSourceDocument>;
  readWorkItem(input: { workItemId: string }): Promise<SecondBrainSourceDocument>;
  searchKnowledge(input: {
    query: string;
    sourceKinds: readonly ["project", "work_item", "memory"];
    limit: number;
    maxScanned: number;
  }): Promise<SecondBrainKnowledgeSearchResult>;
  renewLease(input: {
    runId: string;
    agentId: string;
    leaseToken: string;
    leaseSeconds: number;
  }): Promise<unknown>;
  reportProgress(input: {
    runId: string;
    agentId: string;
    leaseToken: string;
    idempotencyKey: string;
    markdown: string;
    artifacts?: SecondBrainArtifactPointer[];
    needsUser?: boolean;
    blockerCode?: SecondBrainBlockerCode;
  }): Promise<unknown>;
  submitResult(input: {
    runId: string;
    agentId: string;
    leaseToken: string;
    idempotencyKey: string;
    markdown: string;
    artifacts?: SecondBrainArtifactPointer[];
    acceptancePassed: true;
  }): Promise<unknown>;
}

export type SecondBrainExecutionContext = {
  run: NonNullable<SecondBrainClaim["run"]>;
  projectMarkdown: string;
  workItemMarkdown: string;
  knowledgeMarkdown: string;
  contentTrust: "untrusted-drive-markdown";
  knowledgeTrust: "untrusted-second-brain-search";
  authorization: {
    scope: "internal-project-work-only";
    ownerOrchestratorId: typeof SECOND_BRAIN_OWNER_ORCHESTRATOR_ID;
    automaticExternalActionsAllowed: false;
    prohibitedActions: readonly [
      "gmail",
      "calendar",
      "delete",
      "purchase",
      "external-action",
    ];
    modelSpendIsMeasuredOrEnforced: false;
  };
};

export type SecondBrainProgressInput = {
  markdown: string;
  artifacts?: SecondBrainArtifactPointer[];
};

export type SecondBrainExecutorControls = {
  signal: AbortSignal;
  reportProgress(input: SecondBrainProgressInput): Promise<{ accepted: boolean; reason?: string }>;
};

export type SecondBrainExecutionResult =
  | {
      status: "completed";
      markdown: string;
      artifacts?: SecondBrainArtifactPointer[];
      verification: { passed: true; method: string; summary: string };
      proposedExternalActions?: never;
    }
  | {
      status: "needs_user";
      blockerCode: SecondBrainBlockerCode;
      markdown: string;
      proposedExternalActions?: readonly string[];
    }
  | {
      status: "incomplete";
      markdown: string;
      verification?: { passed: false; method: string; summary: string };
      proposedExternalActions?: readonly string[];
    };

export interface SecondBrainDelegationExecutor {
  execute(
    context: SecondBrainExecutionContext,
    controls: SecondBrainExecutorControls,
  ): Promise<SecondBrainExecutionResult>;
}

export type SecondBrainRunOutcome =
  | { status: "idle" }
  | { status: "completed"; runId: string }
  | { status: "needs_user"; runId: string; blockerCode: SecondBrainBlockerCode }
  | { status: "incomplete"; runId: string; reason: string }
  | { status: "stopped"; runId?: string }
  | { status: "failed"; runId?: string; error: string };

/** How long the loop will wait before the next claim attempt. */
export type SecondBrainPollStatus = {
  /** Delay applied after the outcome that produced this status. */
  nextPollMs: number;
  /** How many idle or failed outcomes have run back-to-back. */
  consecutiveIdle: number;
  /** The floor the loop returns to as soon as real work appears. */
  pollIntervalMs: number;
  /** The ceiling the backoff never exceeds. */
  idlePollIntervalMs: number;
};

type IntervalHandle = ReturnType<typeof setInterval>;

export type SecondBrainAutonomousRunnerOptions = {
  workspace: SecondBrainWorkspacePort;
  executor: SecondBrainDelegationExecutor;
  ownerSession: {
    isOwner: true;
    trustedLocalOrchestrator: true;
    orchestratorId: typeof SECOND_BRAIN_OWNER_ORCHESTRATOR_ID;
  };
  leaseSeconds?: number;
  maxProgressEvents?: number;
  maxProgressCharacters?: number;
  maxResultCharacters?: number;
  maxKnowledgeCharacters?: number;
  setInterval?: (callback: () => void, milliseconds: number) => IntervalHandle;
  clearInterval?: (handle: IntervalHandle) => void;
  sleep?: (milliseconds: number, signal: AbortSignal) => Promise<void>;
};

function safeMarkdown(value: unknown, limit: number, label: string) {
  const markdown = String(value ?? "").replace(/\u0000/g, "").trim();
  if (!markdown) throw new Error(`${label} cannot be empty.`);
  if (markdown.length > limit) throw new Error(`${label} is too large.`);
  return markdown;
}

function stableKey(kind: "progress" | "result" | "blocked", runId: string, value: string) {
  const hash = createHash("sha256").update(`${kind}:${runId}:${value}`).digest("hex").slice(0, 24);
  return `oa.runner.${kind}.${runId}.${hash}`.slice(0, 200);
}

function isFixedBlocker(value: unknown): value is SecondBrainBlockerCode {
  return SECOND_BRAIN_FIXED_BLOCKERS.includes(value as SecondBrainBlockerCode);
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error ?? "Unknown runner error");
}

function abortableSleep(milliseconds: number, signal: AbortSignal) {
  return new Promise<void>((resolve) => {
    if (signal.aborted) return resolve();
    const timer = setTimeout(resolve, milliseconds);
    signal.addEventListener("abort", () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
  });
}

export class SecondBrainAutonomousRunner {
  private readonly leaseSeconds: number;
  private readonly maxProgressEvents: number;
  private readonly maxProgressCharacters: number;
  private readonly maxResultCharacters: number;
  private readonly maxKnowledgeCharacters: number;
  private readonly setIntervalFn: NonNullable<SecondBrainAutonomousRunnerOptions["setInterval"]>;
  private readonly clearIntervalFn: NonNullable<SecondBrainAutonomousRunnerOptions["clearInterval"]>;
  private readonly sleepFn: NonNullable<SecondBrainAutonomousRunnerOptions["sleep"]>;
  private activeAbort: AbortController | null = null;
  /** The running poll loop's controller, so stop() can cut a long idle sleep. */
  private loopAbort: AbortController | null = null;
  private activeRun: Promise<SecondBrainRunOutcome> | null = null;
  private stopped = false;
  private pollStatus: SecondBrainPollStatus | null = null;

  constructor(private readonly options: SecondBrainAutonomousRunnerOptions) {
    if (
      options.ownerSession.isOwner !== true
      || options.ownerSession.trustedLocalOrchestrator !== true
      || options.ownerSession.orchestratorId !== SECOND_BRAIN_OWNER_ORCHESTRATOR_ID
    ) {
      throw new Error("Second Brain automation requires the trusted local owner orchestrator.");
    }
    this.leaseSeconds = Math.min(900, Math.max(60, Math.trunc(options.leaseSeconds ?? 300)));
    this.maxProgressEvents = Math.min(25, Math.max(1, Math.trunc(options.maxProgressEvents ?? 12)));
    this.maxProgressCharacters = Math.min(20_000, Math.max(500, Math.trunc(options.maxProgressCharacters ?? 8_000)));
    this.maxResultCharacters = Math.min(200_000, Math.max(1_000, Math.trunc(options.maxResultCharacters ?? 100_000)));
    this.maxKnowledgeCharacters = Math.min(60_000, Math.max(2_000, Math.trunc(options.maxKnowledgeCharacters ?? 30_000)));
    this.setIntervalFn = options.setInterval ?? setInterval;
    this.clearIntervalFn = options.clearInterval ?? clearInterval;
    this.sleepFn = options.sleep ?? abortableSleep;
  }

  stop() {
    this.stopped = true;
    this.activeAbort?.abort(new Error("Second Brain runner stopped."));
    // Cut the poll wait too. With a 15-minute idle backoff, waiting for the
    // sleep to finish on its own would delay a stop by up to that long.
    this.loopAbort?.abort();
  }

  resume() {
    this.stopped = false;
  }

  /**
   * The current poll backoff, or null before the loop has run. The desktop
   * reads this to show when the next cloud claim will happen.
   */
  pollingStatus(): SecondBrainPollStatus | null {
    return this.pollStatus ? { ...this.pollStatus } : null;
  }

  runOnce(): Promise<SecondBrainRunOutcome> {
    if (this.stopped) return Promise.resolve({ status: "stopped" });
    if (this.activeRun) return this.activeRun;
    const run = this.executeOne().finally(() => {
      if (this.activeRun === run) this.activeRun = null;
    });
    this.activeRun = run;
    return run;
  }

  async runUntilStopped(input: {
    pollIntervalMs?: number;
    /**
     * The ceiling the idle backoff grows to. Default 15 minutes, clamped to
     * 1-30 minutes. An empty queue must not be polled once a minute all day.
     */
    idlePollIntervalMs?: number;
    signal?: AbortSignal;
    onOutcome?: (outcome: SecondBrainRunOutcome, poll: SecondBrainPollStatus) => Promise<void> | void;
  } = {}) {
    const pollIntervalMs = Math.min(60_000, Math.max(1_000, Math.trunc(input.pollIntervalMs ?? 10_000)));
    const idlePollIntervalMs = Math.max(
      pollIntervalMs,
      Math.min(1_800_000, Math.max(60_000, Math.trunc(input.idlePollIntervalMs ?? 900_000)))
    );
    let consecutiveIdle = 0;
    const loopAbort = new AbortController();
    const previousLoopAbort = this.loopAbort;
    this.loopAbort = loopAbort;
    const externalStop = () => {
      loopAbort.abort();
      this.stop();
    };
    input.signal?.addEventListener("abort", externalStop, { once: true });
    if (input.signal?.aborted) {
      externalStop();
      input.signal.removeEventListener("abort", externalStop);
      this.loopAbort = previousLoopAbort;
      return;
    }
    // resume() clears the stopped flag, so the loop controller is adopted after
    // it: a stop() from here on must still reach this loop's sleep.
    this.resume();
    try {
      while (!this.stopped && !loopAbort.signal.aborted) {
        const outcome = await this.runOnce();
        // Idle and failed outcomes back off: an empty queue is not worth
        // polling every minute, and a broken connection must not be hammered.
        const backOff = outcome.status === "idle" || outcome.status === "failed";
        consecutiveIdle = backOff ? consecutiveIdle + 1 : 0;
        const nextPollMs = backOff
          ? Math.min(idlePollIntervalMs, pollIntervalMs * 2 ** (consecutiveIdle - 1))
          : pollIntervalMs;
        const poll: SecondBrainPollStatus = {
          nextPollMs,
          consecutiveIdle,
          pollIntervalMs,
          idlePollIntervalMs,
        };
        this.pollStatus = poll;
        await input.onOutcome?.(outcome, { ...poll });
        if (this.stopped || loopAbort.signal.aborted) break;
        await this.sleepFn(nextPollMs, loopAbort.signal);
      }
    } finally {
      input.signal?.removeEventListener("abort", externalStop);
      if (this.loopAbort === loopAbort) this.loopAbort = previousLoopAbort;
    }
  }

  private async executeOne(): Promise<SecondBrainRunOutcome> {
    let claimedRunId: string | undefined;
    try {
      const claim = await this.options.workspace.claimNext({
        agentId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
        leaseSeconds: this.leaseSeconds,
      });
      if (this.stopped) return { status: "stopped" };
      if (!claim.found) return { status: "idle" };
      if (!claim.run || !claim.leaseToken) throw new Error("Workspace returned an incomplete Second Brain lease.");
      const run = claim.run;
      claimedRunId = run.id;
      if (run.agentId !== SECOND_BRAIN_OWNER_ORCHESTRATOR_ID) {
        throw new Error("Workspace returned work for a different orchestrator label.");
      }
      if (run.status !== "running") throw new Error("Workspace returned a run that is not active.");
      const [project, workItem] = await Promise.all([
        this.options.workspace.readProject({ projectId: run.projectId }),
        this.options.workspace.readWorkItem({ workItemId: run.workItemId }),
      ]);
      if (project.truncated || workItem.truncated) {
        await this.reportBlocker(run.id, claim.leaseToken, "technical_blocker", "The project context was truncated and cannot be executed safely.");
        return { status: "needs_user", runId: run.id, blockerCode: "technical_blocker" };
      }
      const knowledge = await this.options.workspace.searchKnowledge({
        query: this.knowledgeQuery(project.markdown, workItem.markdown),
        sourceKinds: ["project", "work_item", "memory"],
        limit: 8,
        maxScanned: 16,
      });
      if (knowledge.truncated) {
        await this.reportBlocker(run.id, claim.leaseToken, "technical_blocker", "The relevant Second Brain knowledge excerpts were truncated and cannot be executed safely.");
        return { status: "needs_user", runId: run.id, blockerCode: "technical_blocker" };
      }

      const abort = new AbortController();
      this.activeAbort = abort;
      let leaseFailure = "";
      let renewalActive = false;
      const renewalMilliseconds = Math.max(20_000, Math.floor(this.leaseSeconds * 1_000 / 3));
      const renewal = this.setIntervalFn(() => {
        if (renewalActive || abort.signal.aborted) return;
        renewalActive = true;
        void this.options.workspace.renewLease({
          runId: run.id,
          agentId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
          leaseToken: claim.leaseToken!,
          leaseSeconds: this.leaseSeconds,
        }).catch((error) => {
          leaseFailure = errorMessage(error);
          abort.abort(new Error("The Second Brain work lease could not be renewed."));
        }).finally(() => {
          renewalActive = false;
        });
      }, renewalMilliseconds);

      let progressCount = 0;
      const progressKeys = new Set<string>();
      try {
        const result = await this.options.executor.execute({
          run,
          projectMarkdown: project.markdown,
          workItemMarkdown: workItem.markdown,
          knowledgeMarkdown: String(knowledge.markdown ?? "").slice(0, this.maxKnowledgeCharacters),
          contentTrust: "untrusted-drive-markdown",
          knowledgeTrust: "untrusted-second-brain-search",
          authorization: {
            scope: "internal-project-work-only",
            ownerOrchestratorId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
            automaticExternalActionsAllowed: false,
            prohibitedActions: ["gmail", "calendar", "delete", "purchase", "external-action"],
            modelSpendIsMeasuredOrEnforced: false,
          },
        }, {
          signal: abort.signal,
          reportProgress: async (input) => {
            if (abort.signal.aborted) return { accepted: false, reason: "stopped" };
            const markdown = safeMarkdown(input.markdown, this.maxProgressCharacters, "Progress Markdown");
            const key = stableKey("progress", run.id, JSON.stringify({ markdown, artifacts: input.artifacts ?? [] }));
            if (progressKeys.has(key)) return { accepted: true, reason: "duplicate-suppressed" };
            if (progressCount >= this.maxProgressEvents) return { accepted: false, reason: "progress-limit" };
            progressCount += 1;
            await this.options.workspace.reportProgress({
              runId: run.id,
              agentId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
              leaseToken: claim.leaseToken!,
              idempotencyKey: key,
              markdown,
              artifacts: input.artifacts,
            });
            progressKeys.add(key);
            return { accepted: true };
          },
        });

        if (this.stopped) return { status: "stopped", runId: run.id };
        if (leaseFailure) return { status: "failed", runId: run.id, error: leaseFailure };
        const proposedExternalActions = result.proposedExternalActions ?? [];
        if (proposedExternalActions.length > 0) {
          await this.reportBlocker(
            run.id,
            claim.leaseToken,
            "external_action",
            "The work reached an external action. OpenAssist did not run it. Review and approve it separately if you want to continue.",
          );
          return { status: "needs_user", runId: run.id, blockerCode: "external_action" };
        }
        if (result.status === "needs_user") {
          if (!isFixedBlocker(result.blockerCode)) throw new Error("The executor returned an unsupported blocker category.");
          await this.reportBlocker(run.id, claim.leaseToken, result.blockerCode, result.markdown);
          return { status: "needs_user", runId: run.id, blockerCode: result.blockerCode };
        }
        if (result.status === "incomplete" || result.verification?.passed !== true) {
          const markdown = safeMarkdown(result.markdown, this.maxProgressCharacters, "Incomplete-work Markdown");
          await this.options.workspace.reportProgress({
            runId: run.id,
            agentId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
            leaseToken: claim.leaseToken,
            idempotencyKey: stableKey("progress", run.id, `incomplete:${markdown}`),
            markdown,
          });
          return { status: "incomplete", runId: run.id, reason: "acceptance-not-verified" };
        }
        const markdown = safeMarkdown(result.markdown, this.maxResultCharacters, "Result Markdown");
        await this.options.workspace.submitResult({
          runId: run.id,
          agentId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
          leaseToken: claim.leaseToken,
          idempotencyKey: stableKey("result", run.id, JSON.stringify({ markdown, artifacts: result.artifacts ?? [] })),
          markdown,
          artifacts: result.artifacts,
          acceptancePassed: true,
        });
        return { status: "completed", runId: run.id };
      } finally {
        this.clearIntervalFn(renewal);
        if (this.activeAbort === abort) this.activeAbort = null;
      }
    } catch (error) {
      if (this.stopped) return { status: "stopped", runId: claimedRunId };
      return { status: "failed", runId: claimedRunId, error: errorMessage(error) };
    }
  }

  private knowledgeQuery(projectMarkdown: string, workItemMarkdown: string) {
    const stopWords = new Set([
      "a", "an", "and", "as", "at", "be", "by", "do", "for", "from", "in", "into", "is", "it",
      "of", "on", "or", "project", "task", "the", "this", "to", "we", "with", "work", "item",
    ]);
    const tokens = (value: string) => value
      .replace(/^---\s*\n[\s\S]*?\n---\s*(?:\n|$)/, "")
      .replace(/```[\s\S]*?```/g, " ")
      .replace(/https?:\/\/\S+/g, " ")
      .replace(/<[^>]+>/g, " ")
      .toLowerCase()
      .match(/[a-z0-9][a-z0-9-]{1,}/g)
      ?.filter((token) => !stopWords.has(token)) ?? [];
    const selected: string[] = [];
    const add = (values: string[]) => {
      for (const token of values) {
        if (!selected.includes(token)) selected.push(token);
        if (selected.length >= 6) break;
      }
    };
    add(tokens(workItemMarkdown));
    if (selected.length < 2) add(tokens(projectMarkdown));
    if (selected.length < 2) add(["internal", "work"]);
    return safeMarkdown(selected.slice(0, 6).join(" ").slice(0, 200), 200, "Knowledge search query");
  }

  private async reportBlocker(
    runId: string,
    leaseToken: string,
    blockerCode: SecondBrainBlockerCode,
    value: string,
  ) {
    if (!isFixedBlocker(blockerCode)) throw new Error("Unsupported Second Brain blocker category.");
    const markdown = safeMarkdown(value, this.maxProgressCharacters, "Blocker Markdown");
    await this.options.workspace.reportProgress({
      runId,
      agentId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
      leaseToken,
      idempotencyKey: stableKey("blocked", runId, `${blockerCode}:${markdown}`),
      markdown,
      needsUser: true,
      blockerCode,
    });
  }
}
