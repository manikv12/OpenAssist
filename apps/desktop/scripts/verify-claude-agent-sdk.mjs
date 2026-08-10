import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  claudeAgentAuthProfile,
  claudeAgentEnvironment,
  claudeAgentEffort,
  claudeAgentPermissionOptions,
  claudeScopedUsageLimits
} from "../dist-electron/claudeAgentCore.js";
import {
  listClaudeAgentModels,
  resolveClaudeAgentRequest,
  runClaudeAgentTurn
} from "../dist-electron/claudeAgentDriver.js";

assert.equal(claudeAgentPermissionOptions("default").permissionMode, "default");
assert.equal(claudeAgentPermissionOptions("autoReview").permissionMode, "acceptEdits");
assert.equal(claudeAgentPermissionOptions("fullAccess").permissionMode, "bypassPermissions");
assert.equal(claudeAgentPermissionOptions("fullAccess").allowDangerouslySkipPermissions, true);
assert.equal(claudeAgentPermissionOptions("custom").permissionMode, undefined);
assert.equal(claudeAgentEffort("minimal"), "low");
assert.equal(claudeAgentEffort("extra high"), "xhigh");
assert.equal(claudeAgentAuthProfile({}), "personal");
assert.equal(claudeAgentAuthProfile({ OPENASSIST_CLAUDE_AUTH_PROFILE: "personal" }), "personal");
assert.equal(claudeAgentAuthProfile({ OPENASSIST_CLAUDE_AUTH_PROFILE: "public" }), "public");
const personalEnvironment = claudeAgentEnvironment({
  environment: { CLAUDE_CODE_OAUTH_TOKEN: "secret", ANTHROPIC_API_KEY: "external" },
  authProfile: "personal",
  publicConfigDirectory: "/tmp/openassist-public-claude"
});
assert.equal(personalEnvironment.CLAUDE_CODE_OAUTH_TOKEN, "secret");
assert.equal(personalEnvironment.ANTHROPIC_API_KEY, undefined);
const publicEnvironment = claudeAgentEnvironment({
  environment: { CLAUDE_CODE_OAUTH_TOKEN: "secret", ANTHROPIC_API_KEY: "external" },
  authProfile: "public",
  publicConfigDirectory: "/tmp/openassist-public-claude"
});
assert.equal(publicEnvironment.CLAUDE_CODE_OAUTH_TOKEN, undefined);
assert.equal(publicEnvironment.ANTHROPIC_API_KEY, "external");
assert.equal(publicEnvironment.CLAUDE_CONFIG_DIR, "/tmp/openassist-public-claude");
assert.deepEqual(claudeScopedUsageLimits({
  limits: [
    { kind: "weekly_all", percent: 36, scope: null },
    {
      kind: "weekly_scoped",
      percent: 67,
      resets_at: "2026-08-01T12:00:00Z",
      scope: { model: { id: null, display_name: "Example model" } }
    }
  ]
}), [{
  modelID: undefined,
  modelName: "Example model",
  usedPercent: 67,
  resetsAt: "2026-08-01T12:00:00Z"
}]);

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-claude-sdk-test-"));
const deltas = [];
const activities = [];
let capturedOptions;
const fakeQuery = ({ options }) => {
  capturedOptions = options;
  return (async function* () {
    yield { type: "system", subtype: "init", session_id: "11111111-1111-4111-8111-111111111111", uuid: "init" };
    yield {
      type: "stream_event",
      event: {
        type: "content_block_delta",
        delta: { type: "thinking_delta", thinking: "", estimated_tokens: 96, estimated_tokens_delta: 96 }
      },
      parent_tool_use_id: null,
      session_id: "11111111-1111-4111-8111-111111111111",
      uuid: "thinking"
    };
    yield {
      type: "stream_event",
      event: { type: "content_block_delta", delta: { type: "text_delta", text: "Hello" } },
      parent_tool_use_id: null,
      session_id: "11111111-1111-4111-8111-111111111111",
      uuid: "delta"
    };
    yield {
      type: "assistant",
      message: { content: [{ type: "tool_use", id: "tool-1", name: "Read", input: { file_path: "/tmp/example" } }] },
      parent_tool_use_id: null,
      session_id: "11111111-1111-4111-8111-111111111111",
      uuid: "assistant"
    };
    yield {
      type: "user",
      message: { content: [{ type: "tool_result", tool_use_id: "tool-1", content: "done" }] },
      parent_tool_use_id: null,
      session_id: "11111111-1111-4111-8111-111111111111",
      uuid: "user"
    };
    yield {
      type: "result",
      subtype: "success",
      result: "Hello from Claude",
      session_id: "11111111-1111-4111-8111-111111111111",
      uuid: "result"
    };
  })();
};

const streamed = await runClaudeAgentTurn({
  prompt: "Say hello",
  sessionID: "11111111-1111-4111-8111-111111111111",
  isNewSession: true,
  cwd: tempRoot,
  modelID: "sonnet",
  reasoningEffort: "medium",
  adaptiveThinking: true,
  permissionMode: "autoReview",
  publicConfigDirectory: path.join(tempRoot, "public-config"),
  authProfile: "personal",
  localMCP: {
    findTools: async () => ({ ok: true, matches: [] }),
    callTool: async () => ({ ok: true, resultText: "done" })
  },
  queryImplementation: fakeQuery,
  onDelta: (delta) => deltas.push(delta),
  onActivity: (activity) => activities.push(activity)
});

assert.equal(streamed.text, "Hello from Claude");
assert.deepEqual(deltas, ["Hello"]);
assert.equal(capturedOptions.sessionId, "11111111-1111-4111-8111-111111111111");
assert.equal(capturedOptions.permissionMode, "acceptEdits");
assert.equal(capturedOptions.effort, "medium");
assert.deepEqual(capturedOptions.thinking, { type: "adaptive" });
assert.equal(capturedOptions.showThinkingSummaries, true);
assert.equal(capturedOptions.mcpServers.openassist_local_mcp.type, "sdk");
assert.equal(capturedOptions.allowedTools.includes("mcp__openassist_local_mcp__find_tools"), true);
assert.equal(capturedOptions.allowedTools.includes("mcp__openassist_local_mcp__call_tool"), true);
assert.equal(capturedOptions.allowedTools.includes("mcp__openassist_local_mcp__call_tool_confirmed"), false);
assert.equal(activities.some((activity) => activity.kind === "reasoning" && activity.status === "running"), true);
assert.equal(activities.some((activity) => activity.kind === "reasoning" && activity.status === "completed"), true);
assert.equal(activities.some((activity) => activity.id.includes("tool-1") && activity.status === "running"), true);
assert.equal(activities.some((activity) => activity.id.includes("tool-1") && activity.status === "completed"), true);
assert.equal(
  activities.find((activity) => activity.id.includes("tool-1") && activity.status === "completed")?.title,
  "Read"
);

let approvalResult;
const approvalQuery = ({ options }) => (async function* () {
  approvalResult = await options.canUseTool("Bash", { command: "pwd" }, {
    signal: new AbortController().signal,
    toolUseID: "approval-tool",
    title: "Run pwd?",
    displayName: "Run command",
    description: "Claude wants to print the working directory.",
    suggestions: []
  });
  yield {
    type: "result",
    subtype: "success",
    result: "Approved",
    session_id: "22222222-2222-4222-8222-222222222222",
    uuid: "result"
  };
})();

await runClaudeAgentTurn({
  prompt: "Run pwd",
  sessionID: "22222222-2222-4222-8222-222222222222",
  isNewSession: true,
  cwd: tempRoot,
  permissionMode: "default",
  publicConfigDirectory: path.join(tempRoot, "public-config"),
  authProfile: "personal",
  queryImplementation: approvalQuery,
  onActivity: (activity) => {
    if (activity.approvalRequestID) {
      assert.equal(resolveClaudeAgentRequest(activity.approvalRequestID, { decision: "allow" }), true);
    }
  }
});
assert.equal(approvalResult.behavior, "allow");

let questionResult;
const questionQuery = ({ options }) => (async function* () {
  questionResult = await options.canUseTool("AskUserQuestion", {
    questions: [
      { id: "color", question: "Choose a color", multiSelect: false, options: [{ label: "Blue" }, { label: "Green" }] },
      { id: "features", question: "Choose features", multiSelect: true, options: [{ label: "Search" }, { label: "Notes" }] }
    ]
  }, {
    signal: new AbortController().signal,
    toolUseID: "questions-tool",
    suggestions: []
  });
  yield {
    type: "result",
    subtype: "success",
    result: "Questions answered",
    session_id: "33333333-3333-4333-8333-333333333333",
    uuid: "result"
  };
})();

await runClaudeAgentTurn({
  prompt: "Ask questions",
  sessionID: "33333333-3333-4333-8333-333333333333",
  isNewSession: true,
  cwd: tempRoot,
  publicConfigDirectory: path.join(tempRoot, "public-config"),
  authProfile: "personal",
  queryImplementation: questionQuery,
  onActivity: (activity) => {
    if (!activity.approvalRequestID) return;
    assert.equal(activity.approvalQuestions?.length, 2);
    resolveClaudeAgentRequest(activity.approvalRequestID, {
      decision: "answers",
      answers: { color: "Blue", features: ["Search", "Notes"] }
    });
  }
});
assert.equal(questionResult.behavior, "allow");
assert.deepEqual(questionResult.updatedInput.answers, {
  "Choose a color": "Blue",
  "Choose features": "Search, Notes"
});

let openedURL = "";
let elicitationResult;
const elicitationQuery = ({ options }) => (async function* () {
  elicitationResult = await options.onElicitation({
    serverName: "example",
    message: "Sign in to continue",
    mode: "url",
    url: "https://example.com/sign-in"
  }, { signal: new AbortController().signal });
  yield {
    type: "result",
    subtype: "success",
    result: "Signed in",
    session_id: "44444444-4444-4444-8444-444444444444",
    uuid: "result"
  };
})();

await runClaudeAgentTurn({
  prompt: "Sign in",
  sessionID: "44444444-4444-4444-8444-444444444444",
  isNewSession: true,
  cwd: tempRoot,
  publicConfigDirectory: path.join(tempRoot, "public-config"),
  authProfile: "personal",
  queryImplementation: elicitationQuery,
  onOpenURL: async (url) => {
    openedURL = url;
  },
  onActivity: (activity) => {
    if (activity.approvalRequestID) {
      resolveClaudeAgentRequest(activity.approvalRequestID, { decision: "accept" });
    }
  }
});
assert.equal(openedURL, "https://example.com/sign-in");
assert.equal(elicitationResult.action, "accept");

let resumeOptions;
const resumeQuery = ({ options }) => {
  resumeOptions = options;
  return (async function* () {
    yield {
      type: "result",
      subtype: "success",
      result: "Resumed",
      session_id: "33333333-3333-4333-8333-333333333333",
      uuid: "result"
    };
  })();
};
await runClaudeAgentTurn({
  prompt: "Continue",
  sessionID: "33333333-3333-4333-8333-333333333333",
  isNewSession: false,
  cwd: tempRoot,
  publicConfigDirectory: path.join(tempRoot, "public-config"),
  authProfile: "personal",
  queryImplementation: resumeQuery
});
assert.equal(resumeOptions.resume, "33333333-3333-4333-8333-333333333333");
assert.equal(resumeOptions.sessionId, undefined);

let modelCatalogClosed = false;
const catalogQuery = () => {
  const session = (async function* () {})();
  session.supportedModels = async () => [
    {
      value: "default",
      resolvedModel: "claude-sonnet-5",
      displayName: "Default (recommended)",
      description: "Uses the recommended Claude model.",
      supportsEffort: true,
      supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"],
      supportsAdaptiveThinking: true
    },
    {
      value: "haiku",
      resolvedModel: "claude-haiku-4-5-20251001",
      displayName: "Claude Haiku 4.5",
      description: "Fast model.",
      supportsEffort: false,
      supportedEffortLevels: [],
      supportsAdaptiveThinking: false
    }
  ];
  session.close = () => {
    modelCatalogClosed = true;
  };
  return session;
};
const catalog = await listClaudeAgentModels({
  cwd: tempRoot,
  publicConfigDirectory: path.join(tempRoot, "public-config"),
  authProfile: "personal",
  queryImplementation: catalogQuery
});
assert.equal(catalog.length, 2);
assert.equal(catalog[0].resolvedModel, "claude-sonnet-5");
assert.deepEqual(catalog[0].supportedEffortLevels, ["low", "medium", "high", "xhigh", "max"]);
assert.equal(modelCatalogClosed, true);

fs.rmSync(tempRoot, { recursive: true, force: true });
console.log(JSON.stringify({
  claudeAgentSDK: true,
  streaming: true,
  privateThinkingActivity: true,
  liveModelCatalog: true,
  modelSpecificUsage: true,
  approvals: true,
  structuredQuestions: true,
  mcpURLApproval: true,
  resume: true,
  permissionModes: true
}));
