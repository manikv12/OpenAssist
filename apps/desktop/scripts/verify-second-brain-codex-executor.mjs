import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import {
  SecondBrainCodexExecutor,
  createIsolatedSecondBrainCodexRuntimeDirectory,
  IsolatedSecondBrainCodexTransport,
  isolatedSecondBrainCodexArgs,
  isolatedSecondBrainCodexEnvironment,
} from "../dist-electron/secondBrainCodexExecutor.js";
import { SECOND_BRAIN_OWNER_ORCHESTRATOR_ID } from "../dist-electron/secondBrainAutonomousRunnerCore.js";

function context() {
  return {
    run: {
      id: "sbr_run",
      assignmentId: "sba_assignment",
      workItemId: "sbw_work",
      projectId: "sbp_project",
      accountId: "owner",
      agentId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
      status: "running",
      leaseExpiresAt: Date.now() + 300_000,
      policy: { autonomyMode: "autonomous", externalActionAllowed: false, maxSpendCents: 0 },
    },
    projectMarkdown: "# Safe project\nShip an internal design.",
    workItemMarkdown: "# Work item\nWrite a verified implementation note.",
    knowledgeMarkdown: "# Memory excerpt\nUse the internal naming rule.",
    contentTrust: "untrusted-drive-markdown",
    knowledgeTrust: "untrusted-second-brain-search",
    authorization: {
      scope: "internal-project-work-only",
      ownerOrchestratorId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
      automaticExternalActionsAllowed: false,
      prohibitedActions: ["gmail", "calendar", "delete", "purchase", "external-action"],
      modelSpendIsMeasuredOrEnforced: false,
    },
  };
}

// A failed app-server initialization cannot leave a child runtime directory behind.
{
  const listRuntimeDirectories = () => new Set(fs.readdirSync(os.tmpdir()).filter((name) => name.startsWith("openassist-second-brain-")));
  const before = listRuntimeDirectories();
  const transport = new IsolatedSecondBrainCodexTransport({ executable: "/usr/bin/false" });
  await assert.rejects(() => transport.request("thread/start", {}), /exited|stopped|available/i);
  await transport.stop();
  const after = listRuntimeDirectories();
  assert.deepEqual(after, before);
}

class FakeTransport extends EventEmitter {
  calls = [];
  mode = "complete";
  async request(method, params) {
    this.calls.push([method, params]);
    if (method === "thread/start") return { thread: { id: "codex-ephemeral" } };
    if (method === "turn/start") {
      queueMicrotask(() => {
        this.emit("notification", "mcpServer/startupStatus/updated", { server: "none", status: "complete" });
        this.emit("notification", "turn/started", { threadId: "codex-ephemeral", turn: { id: "turn-1" } });
        if (this.mode === "tool") {
          this.emit("notification", "item/started", {
            threadId: "codex-ephemeral",
            turnId: "turn-1",
            item: { type: "mcpToolCall", server: "google-mail-hub" },
          });
          return;
        }
        const result = JSON.stringify({
          status: "completed",
          markdown: "# Result\nThe internal design is complete.",
          blockerCode: null,
          proposedExternalActions: [],
          verification: { passed: true, method: "context-check", summary: "All requested sections are present." },
        });
        this.emit("notification", "item/agentMessage/delta", {
          threadId: "codex-ephemeral",
          turnId: "turn-1",
          delta: result,
          channel: "final",
        });
        this.emit("notification", "turn/completed", { threadId: "codex-ephemeral", turn: { id: "turn-1" } });
      });
      return { turn: { id: "turn-1" } };
    }
    return {};
  }
}

// The standalone app-server has no app/plugin/MCP/shell/browser/computer path.
{
  const args = isolatedSecondBrainCodexArgs();
  assert.deepEqual(args.slice(0, 2), ["app-server", "--stdio"]);
  for (const feature of ["apps", "plugins", "shell_tool", "unified_exec", "computer_use", "browser_use", "in_app_browser", "multi_agent", "memories"]) {
    const index = args.findIndex((value, position) => value === "--disable" && args[position + 1] === feature);
    assert.ok(index >= 0, `${feature} must be disabled`);
  }
  assert.ok(args.some((value) => value === "mcp_servers={}"), "configured MCP servers are replaced with an empty map");
  assert.equal(args.includes("--enable"), false);
  const environment = isolatedSecondBrainCodexEnvironment({
    PATH: "/usr/bin",
    OPENAI_API_KEY: "must-not-leak",
    CODEX_API_KEY: "must-not-leak",
    OPENAI_BASE_URL: "https://example.invalid",
    AWS_SECRET_ACCESS_KEY: "must-not-leak",
    GITHUB_TOKEN: "must-not-leak",
    COMPOSIO_API_KEY: "must-not-leak",
  });
  assert.equal(environment.OPENAI_API_KEY, undefined);
  assert.equal(environment.CODEX_API_KEY, undefined);
  assert.equal(environment.OPENAI_BASE_URL, undefined);
  assert.equal(environment.AWS_SECRET_ACCESS_KEY, undefined);
  assert.equal(environment.GITHUB_TOKEN, undefined);
  assert.equal(environment.COMPOSIO_API_KEY, undefined);
  const runtimeDirectory = createIsolatedSecondBrainCodexRuntimeDirectory();
  try {
    assert.equal(fs.statSync(runtimeDirectory).mode & 0o777, 0o700);
    assert.deepEqual(fs.readdirSync(runtimeDirectory), []);
  } finally {
    fs.rmSync(runtimeDirectory, { recursive: true, force: true });
  }
}

// One ephemeral, tool-free Codex turn produces a verified internal result.
{
  const transport = new FakeTransport();
  const progress = [];
  const executor = new SecondBrainCodexExecutor({ transport, model: "gpt-5.6-sol", reasoningEffort: "high" });
  const result = await executor.execute(context(), {
    signal: new AbortController().signal,
    async reportProgress(input) { progress.push(input); return { accepted: true }; },
  });
  assert.equal(result.status, "completed");
  assert.equal(result.verification.passed, true);
  assert.equal(progress.length, 1);
  const threadStart = transport.calls.find(([method]) => method === "thread/start")[1];
  assert.equal(threadStart.ephemeral, true);
  assert.equal(threadStart.persistExtendedHistory, false);
  assert.deepEqual(threadStart.dynamicTools, []);
  assert.equal(threadStart.approvalPolicy, "never");
  assert.equal(threadStart.sandbox, "read-only");
  assert.match(threadStart.developerInstructions, /no tools/i);
  const turnStart = transport.calls.find(([method]) => method === "turn/start")[1];
  assert.deepEqual(turnStart.sandboxPolicy, { type: "readOnly", networkAccess: false });
  assert.equal(turnStart.model, "gpt-5.6-sol");
  assert.equal(turnStart.effort, "high");
  assert.equal(turnStart.input.length, 1);
  assert.match(turnStart.input[0].text, /untrusted="true"/);
  assert.match(turnStart.input[0].text, /second_brain_knowledge_excerpts/);
  assert.match(turnStart.input[0].text, /Memory excerpt/);
  assert.ok(turnStart.outputSchema);
  assert.equal(transport.calls.some(([method]) => method === "thread/delete"), true);
  assert.equal(JSON.stringify(transport.calls).includes("raw conversation"), false);
}

// Any unexpected tool event fails closed and interrupts the turn.
{
  const transport = new FakeTransport();
  transport.mode = "tool";
  const executor = new SecondBrainCodexExecutor({ transport });
  await assert.rejects(() => executor.execute(context(), {
    signal: new AbortController().signal,
    async reportProgress() { return { accepted: true }; },
  }), /attempted a disabled tool/);
  assert.equal(transport.calls.some(([method]) => method === "turn/interrupt"), true);
  assert.equal(transport.calls.some(([method]) => method === "thread/delete"), true);
}

// Oversized source data never reaches Codex.
{
  const transport = new FakeTransport();
  const executor = new SecondBrainCodexExecutor({ transport, maxContextCharacters: 10_000 });
  const large = context();
  large.projectMarkdown = "x".repeat(10_001);
  const result = await executor.execute(large, {
    signal: new AbortController().signal,
    async reportProgress() { return { accepted: true }; },
  });
  assert.equal(result.status, "needs_user");
  assert.equal(result.blockerCode, "technical_blocker");
  assert.equal(transport.calls.length, 0);
}

console.log("Second Brain Codex executor verification passed.");
