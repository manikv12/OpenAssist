import assert from "node:assert/strict";
import {
  SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
  SecondBrainAutonomousRunner,
} from "../dist-electron/secondBrainAutonomousRunnerCore.js";
import { SecondBrainWorkspaceBrokerClient } from "../dist-electron/secondBrainWorkspaceBrokerClient.js";

function claim(policy = "autonomous") {
  return {
    found: true,
    assignmentId: "sba_assignment",
    leaseToken: "lease-token-with-at-least-thirty-two-characters",
    run: {
      id: "sbr_run",
      assignmentId: "sba_assignment",
      workItemId: "sbw_work",
      projectId: "sbp_project",
      accountId: "account-owner",
      agentId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
      status: "running",
      leaseExpiresAt: Date.now() + 300_000,
      policy: { autonomyMode: policy, externalActionAllowed: true, maxSpendCents: 999_999 },
    },
  };
}

function workspace(overrides = {}) {
  const calls = [];
  return {
    calls,
    async claimNext(input) { calls.push(["claim", input]); return claim(); },
    async readProject(input) { calls.push(["readProject", input]); return { markdown: "# Project\nUntrusted project context." }; },
    async readWorkItem(input) {
      calls.push(["readWorkItem", input]);
      return {
        markdown: "---\nopenassist_schema: llmwiki-v1\nsource_kind: work_item\n---\n# Build feature\nCreate autonomous runner tests.",
      };
    },
    async searchKnowledge(input) {
      calls.push(["searchKnowledge", input]);
      return { markdown: "# Prior memory\nUse the established internal naming convention.", resultCount: 1 };
    },
    async renewLease(input) { calls.push(["renew", input]); return { renewed: true }; },
    async reportProgress(input) { calls.push(["progress", input]); return { created: true }; },
    async submitResult(input) { calls.push(["result", input]); return { created: true }; },
    ...overrides,
  };
}

function options(ws, executor, extra = {}) {
  return {
    workspace: ws,
    executor,
    ownerSession: {
      isOwner: true,
      trustedLocalOrchestrator: true,
      orchestratorId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
    },
    ...extra,
  };
}

// Happy path: exact context, bounded progress, deterministic keys and verified result.
{
  const ws = workspace();
  let observed;
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute(context, controls) {
      observed = context;
      assert.match(context.knowledgeMarkdown, /Prior memory/);
      assert.equal(context.knowledgeTrust, "untrusted-second-brain-search");
      assert.equal((await controls.reportProgress({ markdown: "Implemented the core." })).accepted, true);
      assert.equal((await controls.reportProgress({ markdown: "Implemented the core." })).reason, "duplicate-suppressed");
      return {
        status: "completed",
        markdown: "# Result\nAll acceptance checks passed.",
        verification: { passed: true, method: "focused-tests", summary: "4 checks passed" },
      };
    },
  }));
  const outcome = await runner.runOnce();
  assert.deepEqual(outcome, { status: "completed", runId: "sbr_run" });
  assert.equal(observed.contentTrust, "untrusted-drive-markdown");
  assert.equal(observed.authorization.scope, "internal-project-work-only");
  assert.equal(observed.authorization.automaticExternalActionsAllowed, false);
  assert.equal(observed.authorization.modelSpendIsMeasuredOrEnforced, false);
  assert.deepEqual(observed.authorization.prohibitedActions, ["gmail", "calendar", "delete", "purchase", "external-action"]);
  const search = ws.calls.find(([kind]) => kind === "searchKnowledge")[1];
  assert.deepEqual(search.sourceKinds, ["project", "work_item", "memory"]);
  assert.equal(search.limit, 8);
  assert.equal(search.maxScanned, 16);
  assert.ok(search.query.length >= 2 && search.query.length <= 200);
  assert.doesNotMatch(search.query, /openassist|schema|llmwiki|source-kind/i);
  assert.match(search.query, /build feature/);
  assert.equal(ws.calls.filter(([kind]) => kind === "progress").length, 1);
  assert.equal(ws.calls.filter(([kind]) => kind === "result").length, 1);
  const progress = ws.calls.find(([kind]) => kind === "progress")[1];
  const result = ws.calls.find(([kind]) => kind === "result")[1];
  assert.match(progress.idempotencyKey, /^oa\.runner\.progress\.sbr_run\./);
  assert.match(result.idempotencyKey, /^oa\.runner\.result\.sbr_run\./);
  assert.equal(result.acceptancePassed, true);
}

// Explicitly assigned guarded work can run internally; the Workspace keeps its
// final item in review instead of treating it as an autonomous completion.
{
  let executed = false;
  const ws = workspace({ async claimNext() { return claim("guarded"); } });
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute(context) {
      executed = true;
      assert.equal(context.run.policy.autonomyMode, "guarded");
      return {
        status: "completed",
        markdown: "# Guarded result\nReady for owner review.",
        verification: { passed: true, method: "review", summary: "checked" },
      };
    },
  }));
  assert.deepEqual(await runner.runOnce(), { status: "completed", runId: "sbr_run" });
  assert.equal(executed, true);
}

// Proposed external work becomes a visible fixed blocker; it is never executed.
{
  const ws = workspace();
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute() {
      return {
        status: "incomplete",
        markdown: "Would need to send an email.",
        proposedExternalActions: ["gmail.send"],
      };
    },
  }));
  assert.deepEqual(await runner.runOnce(), { status: "needs_user", runId: "sbr_run", blockerCode: "external_action" });
  const blocker = ws.calls.find(([kind]) => kind === "progress")[1];
  assert.equal(blocker.needsUser, true);
  assert.equal(blocker.blockerCode, "external_action");
  assert.equal(ws.calls.some(([kind]) => kind === "result"), false);
}

// An unverified answer remains progress and can never be submitted as complete.
{
  const ws = workspace();
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute() {
      return {
        status: "incomplete",
        markdown: "The test still fails.",
        verification: { passed: false, method: "tests", summary: "1 failed" },
      };
    },
  }));
  assert.deepEqual(await runner.runOnce(), { status: "incomplete", runId: "sbr_run", reason: "acceptance-not-verified" });
  assert.equal(ws.calls.some(([kind]) => kind === "result"), false);
}

// Lease renewal is automatic, while stop aborts active work without persisting a raw transcript.
{
  const ws = workspace();
  let intervalCallback;
  let release;
  const waiting = new Promise((resolve) => { release = resolve; });
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute(_context, controls) {
      intervalCallback();
      await new Promise((resolve) => controls.signal.addEventListener("abort", resolve, { once: true }));
      await waiting;
      return { status: "incomplete", markdown: "Stopped." };
    },
  }, {
    setInterval(callback) { intervalCallback = callback; return 17; },
    clearInterval() {},
  }));
  const active = runner.runOnce();
  await new Promise((resolve) => setTimeout(resolve, 0));
  runner.stop();
  release();
  assert.deepEqual(await active, { status: "stopped", runId: "sbr_run" });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(ws.calls.some(([kind]) => kind === "renew"), true);
  assert.equal(ws.calls.some(([kind]) => kind === "result"), false);
  assert.equal(JSON.stringify(ws.calls).includes("conversation"), false);
}

// Owner trust is a hard runtime requirement.
assert.throws(() => new SecondBrainAutonomousRunner({
  ...options(workspace(), { async execute() { throw new Error("unused"); } }),
  ownerSession: { isOwner: false, trustedLocalOrchestrator: false, orchestratorId: "someone-else" },
}), /trusted local owner orchestrator/);

// Polling repeats idle discovery and respects cancellation.
{
  let claims = 0;
  const controller = new AbortController();
  const ws = workspace({
    async claimNext() { claims += 1; return { found: false }; },
  });
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute() { throw new Error("idle runner must not execute"); },
  }, {
    async sleep(_milliseconds, signal) {
      if (claims >= 2) controller.abort();
      if (!signal.aborted) await Promise.resolve();
    },
  }));
  await runner.runUntilStopped({ pollIntervalMs: 1_000, signal: controller.signal });
  assert.equal(claims, 2);
}

// Idle polling backs off so an empty queue is not claimed once a minute all day.
{
  const delays = [];
  const outcomes = [];
  let claims = 0;
  const controller = new AbortController();
  const ws = workspace({
    async claimNext() { claims += 1; return { found: false }; },
  });
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute() { throw new Error("idle runner must not execute"); },
  }, {
    async sleep(milliseconds) {
      delays.push(milliseconds);
      if (delays.length >= 3) controller.abort();
    },
  }));
  await runner.runUntilStopped({
    pollIntervalMs: 60_000,
    signal: controller.signal,
    onOutcome: (outcome, poll) => { outcomes.push([outcome.status, poll.nextPollMs, poll.consecutiveIdle]); },
  });
  assert.equal(claims, 3);
  assert.deepEqual(delays, [60_000, 120_000, 240_000], "each consecutive idle claim must double the wait");
  assert.deepEqual(outcomes, [["idle", 60_000, 1], ["idle", 120_000, 2], ["idle", 240_000, 3]],
    "onOutcome must expose the next delay");
  assert.deepEqual(runner.pollingStatus(), {
    nextPollMs: 240_000,
    consecutiveIdle: 3,
    pollIntervalMs: 60_000,
    idlePollIntervalMs: 900_000,
  }, "the status getter must expose the same backoff");
}

// The backoff is capped at idlePollIntervalMs and never grows past it.
{
  const delays = [];
  const controller = new AbortController();
  const ws = workspace({ async claimNext() { return { found: false }; } });
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute() { throw new Error("idle runner must not execute"); },
  }, {
    async sleep(milliseconds) {
      delays.push(milliseconds);
      if (delays.length >= 6) controller.abort();
    },
  }));
  await runner.runUntilStopped({
    pollIntervalMs: 60_000,
    idlePollIntervalMs: 240_000,
    signal: controller.signal,
  });
  assert.deepEqual(delays, [60_000, 120_000, 240_000, 240_000, 240_000, 240_000],
    "the idle wait must stop growing at idlePollIntervalMs");
  assert.equal(runner.pollingStatus().idlePollIntervalMs, 240_000);
}

// The default ceiling is 15 minutes, clamped to 1-30 minutes.
{
  const ceilings = [];
  const observe = async (idlePollIntervalMs) => {
    const controller = new AbortController();
    const ws = workspace({ async claimNext() { return { found: false }; } });
    const runner = new SecondBrainAutonomousRunner(options(ws, {
      async execute() { throw new Error("idle runner must not execute"); },
    }, { async sleep() { controller.abort(); } }));
    await runner.runUntilStopped({ pollIntervalMs: 60_000, idlePollIntervalMs, signal: controller.signal });
    ceilings.push(runner.pollingStatus().idlePollIntervalMs);
  };
  await observe(undefined);
  await observe(1_000);
  await observe(60 * 60_000);
  assert.deepEqual(ceilings, [900_000, 60_000, 1_800_000],
    "the ceiling defaults to 15 minutes and clamps to 1-30 minutes");
}

// Finding work resets the wait to pollIntervalMs immediately.
{
  const delays = [];
  const statuses = [];
  let claims = 0;
  const controller = new AbortController();
  const ws = workspace({
    async claimNext() {
      claims += 1;
      // Two idle claims, then real work, then idle again.
      return claims === 3 ? claim() : { found: false };
    },
  });
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute() {
      return {
        status: "completed",
        markdown: "# Result\nAll acceptance checks passed.",
        verification: { passed: true, method: "tests", summary: "ok" },
      };
    },
  }, {
    async sleep(milliseconds) {
      delays.push(milliseconds);
      if (delays.length >= 4) controller.abort();
    },
  }));
  await runner.runUntilStopped({
    pollIntervalMs: 60_000,
    signal: controller.signal,
    onOutcome: (outcome) => { statuses.push(outcome.status); },
  });
  assert.deepEqual(statuses, ["idle", "idle", "completed", "idle"]);
  assert.deepEqual(delays, [60_000, 120_000, 60_000, 60_000],
    "a found-work outcome must reset the wait to pollIntervalMs");
}

// A failed claim backs off too, so a broken connection is not hammered.
{
  const delays = [];
  const statuses = [];
  const controller = new AbortController();
  const ws = workspace({
    async claimNext() { throw new Error("Workspace connection refused."); },
  });
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute() { throw new Error("failed runner must not execute"); },
  }, {
    async sleep(milliseconds) {
      delays.push(milliseconds);
      if (delays.length >= 3) controller.abort();
    },
  }));
  await runner.runUntilStopped({
    pollIntervalMs: 60_000,
    signal: controller.signal,
    onOutcome: (outcome) => { statuses.push(outcome.status); },
  });
  assert.deepEqual(statuses, ["failed", "failed", "failed"]);
  assert.deepEqual(delays, [60_000, 120_000, 240_000], "a failing connection must back off as well");
}

// Abort and stop semantics survive the backoff. An external abort reaches the
// sleep through its signal, and a direct stop() ends the loop after that wait.
{
  const delays = [];
  let sleepSawAbort = false;
  const controller = new AbortController();
  const ws = workspace({ async claimNext() { return { found: false }; } });
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute() { throw new Error("idle runner must not execute"); },
  }, {
    async sleep(milliseconds, signal) {
      delays.push(milliseconds);
      controller.abort();
      sleepSawAbort = signal.aborted;
    },
  }));
  await runner.runUntilStopped({ pollIntervalMs: 60_000, signal: controller.signal });
  assert.deepEqual(delays, [60_000], "an external abort must end the loop after one wait");
  assert.equal(sleepSawAbort, true, "the sleep must be abortable through the loop signal");
}
// A direct stop() must cut a long idle sleep instead of waiting it out. The
// fake sleep only resolves on abort, so a hung loop would hang this script.
{
  const delays = [];
  let claims = 0;
  let sleepSawAbort = false;
  const ws = workspace({ async claimNext() { claims += 1; return { found: false }; } });
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute() { throw new Error("idle runner must not execute"); },
  }, {
    sleep(milliseconds, signal) {
      delays.push(milliseconds);
      return new Promise((resolve) => {
        if (signal.aborted) { sleepSawAbort = true; return resolve(); }
        signal.addEventListener("abort", () => { sleepSawAbort = true; resolve(); }, { once: true });
        // Nothing else resolves this sleep: only stop() can end the wait.
        setTimeout(() => runner.stop(), 0);
      });
    },
  }));
  await runner.runUntilStopped({ pollIntervalMs: 60_000, idlePollIntervalMs: 900_000 });
  assert.deepEqual(delays, [60_000], "stop() must end the loop however long the backoff got");
  assert.equal(sleepSawAbort, true, "stop() must abort the in-flight sleep, not wait it out");
  assert.equal(claims, 1, "a stopped runner must not claim again");
}

// The same holds once the backoff has grown: stop() still returns promptly.
{
  const delays = [];
  let claims = 0;
  const ws = workspace({ async claimNext() { claims += 1; return { found: false }; } });
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute() { throw new Error("idle runner must not execute"); },
  }, {
    sleep(milliseconds, signal) {
      delays.push(milliseconds);
      return new Promise((resolve) => {
        if (signal.aborted) return resolve();
        signal.addEventListener("abort", resolve, { once: true });
        // Let the wait grow to the 15-minute ceiling, then stop mid-sleep.
        if (milliseconds >= 900_000) setTimeout(() => runner.stop(), 0);
        else setTimeout(resolve, 0);
      });
    },
  }));
  await runner.runUntilStopped({ pollIntervalMs: 60_000 });
  assert.equal(delays.at(-1), 900_000, "the wait must reach the idle ceiling before the stop");
  assert.equal(claims, delays.length, "each wait follows exactly one claim");
  assert.equal(runner.pollingStatus().nextPollMs, 900_000);
}

// An external signal abort keeps working exactly as before.
{
  const delays = [];
  let sleepSawAbort = false;
  const controller = new AbortController();
  const ws = workspace({ async claimNext() { return { found: false }; } });
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute() { throw new Error("idle runner must not execute"); },
  }, {
    sleep(milliseconds, signal) {
      delays.push(milliseconds);
      return new Promise((resolve) => {
        signal.addEventListener("abort", () => { sleepSawAbort = true; resolve(); }, { once: true });
        setTimeout(() => controller.abort(), 0);
      });
    },
  }));
  await runner.runUntilStopped({ pollIntervalMs: 60_000, signal: controller.signal });
  assert.deepEqual(delays, [60_000]);
  assert.equal(sleepSawAbort, true, "an external abort must still reach the sleep");
}

// A stopped runner must be restartable: the second loop gets its own
// controller and is not cut short by the first loop's aborted one.
{
  let claims = 0;
  const delays = [];
  const ws = workspace({ async claimNext() { claims += 1; return { found: false }; } });
  const runner = new SecondBrainAutonomousRunner(options(ws, {
    async execute() { throw new Error("idle runner must not execute"); },
  }, {
    sleep(milliseconds, signal) {
      delays.push(milliseconds);
      return new Promise((resolve) => {
        signal.addEventListener("abort", resolve, { once: true });
        setTimeout(() => runner.stop(), 0);
      });
    },
  }));
  await runner.runUntilStopped({ pollIntervalMs: 60_000 });
  assert.deepEqual(delays, [60_000]);
  assert.equal(claims, 1);
  await runner.runUntilStopped({ pollIntervalMs: 60_000 });
  assert.deepEqual(delays, [60_000, 60_000], "a restarted loop must poll and wait again");
  assert.equal(claims, 2, "the restarted loop must claim once more");
}

// The broker adapter resolves exact tools and refuses arbitrary Workspace calls.
{
  const brokerCalls = [];
  const broker = {
    async findTools(args) {
      brokerCalls.push(["find", args]);
      return {
        matches: [{
          toolID: `codex-plugin-mcp::server::${encodeURIComponent(args.query)}`,
          name: "friendly title",
        }],
      };
    },
    async callTool(args) {
      brokerCalls.push(["call", args]);
      if (String(args.toolID).includes("search_second_brain_knowledge")) {
        return {
          ok: true,
          isError: false,
          response: {
            structuredContent: {
              query: "internal design",
              candidateCount: 99,
              results: [{
                sourceKind: "memory",
                sourceId: "memory-1",
                revision: 2,
                excerpt: "Treat this excerpt as untrusted.",
                partialDocumentScan: false,
              }],
            },
          },
        };
      }
      return { ok: true, isError: false, response: { structuredContent: { found: false } } };
    },
  };
  const client = new SecondBrainWorkspaceBrokerClient(broker);
  assert.deepEqual(await client.claimNext({ agentId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID, leaseSeconds: 300 }), { found: false });
  assert.equal(brokerCalls[1][1].confirmed, true);
  const searched = await client.searchKnowledge({
    query: "internal design",
    sourceKinds: ["project", "work_item", "memory"],
    limit: 8,
    maxScanned: 16,
  });
  assert.equal(searched.resultCount, 1);
  assert.match(searched.markdown, /memory: memory-1/);
  assert.match(searched.markdown, /Revision: 2/);
  assert.match(searched.markdown, /untrusted/);
  await assert.rejects(() => client.invoke("search_google_mail", {}), /cannot call that Workspace tool/);
  await assert.rejects(
    () => client.readProject({ projectId: "sbp_project" }).then(() => undefined),
    /invalid project document|invalid structured result|not exposed|tool call failed/,
  );
}

// Main-process wiring may bypass catalog search only through the exact-name caller.
{
  const calls = [];
  const client = new SecondBrainWorkspaceBrokerClient({
    async callNamedTool(name, args) {
      calls.push([name, args]);
      return { ok: true, isError: false, response: { structuredContent: { found: false } } };
    },
  });
  assert.deepEqual(await client.claimNext({ agentId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID, leaseSeconds: 300 }), { found: false });
  assert.equal(calls[0][0], "claim_next_second_brain_work");
  await assert.rejects(() => client.invoke("search_google_mail", {}), /cannot call that Workspace tool/);
}

console.log("Second Brain autonomous runner verification passed.");
