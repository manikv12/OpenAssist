import { randomUUID } from "node:crypto";
import fs from "node:fs";
import type {
  ElicitationRequest,
  ElicitationResult,
  McpServerConfig,
  ModelInfo,
  Options,
  PermissionResult,
  PermissionUpdate,
  SDKMessage
} from "@anthropic-ai/claude-agent-sdk";
import { createSdkMcpServer, query, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import {
  claudeAgentAuthProfile,
  claudeAgentEffort,
  claudeAgentEnvironment,
  claudeAgentModel,
  claudeAgentPermissionOptions,
  claudeAgentToolTitle,
  claudeAgentValuePreview,
  type ClaudeAgentAuthProfile
} from "./claudeAgentCore.js";

export type ClaudeAgentApprovalOption = {
  id: string;
  label: string;
  description?: string;
  tone?: "approve" | "neutral" | "danger";
  result: unknown;
};

export type ClaudeAgentApprovalQuestion = {
  id: string;
  header?: string;
  prompt: string;
  multiSelect: boolean;
  allowFreeText: boolean;
  options: Array<{ label: string; description?: string }>;
};

export type ClaudeAgentActivity = {
  id: string;
  title: string;
  kind: string;
  status: "running" | "completed" | "failed" | "waiting";
  detail: string;
  parentToolUseID?: string;
  approvalRequestID?: string;
  approvalKind?: "command" | "fileChange" | "permissions" | "mcpElicitation" | "userInput";
  approvalPrompt?: string;
  approvalOptions?: ClaudeAgentApprovalOption[];
  approvalQuestions?: ClaudeAgentApprovalQuestion[];
};

export type RunClaudeAgentTurnInput = {
  prompt: string;
  sessionID: string;
  isNewSession: boolean;
  // Fork a parent Claude session into sessionID for the first side-chat turn.
  // Requires the same cwd the parent session ran in.
  forkFromSessionID?: string;
  cwd: string;
  modelID?: string;
  reasoningEffort?: string;
  adaptiveThinking?: boolean;
  permissionMode?: string;
  systemInstructions?: string;
  mcpServers?: Record<string, McpServerConfig>;
  localMCP?: {
    findTools: (args: Record<string, unknown>) => Promise<unknown>;
    callTool: (args: Record<string, unknown>) => Promise<unknown>;
  };
  strictMcpConfig?: boolean;
  // Attach the official Claude in Chrome extension bridge (adds --chrome).
  enableChromeIntegration?: boolean;
  safeReadTools?: string[];
  authProfile?: ClaudeAgentAuthProfile;
  publicConfigDirectory: string;
  abortController?: AbortController;
  onSessionID?: (sessionID: string) => void;
  onDelta?: (delta: string) => void;
  onStatus?: (status: string) => void;
  onActivity?: (activity: ClaudeAgentActivity) => void;
  onTokenUsage?: (usage: { currentContextTokens: number; modelContextWindow?: number; modelID?: string }) => void;
  onSupportedModels?: (models: ModelInfo[]) => void;
  onOpenURL?: (url: string) => Promise<void> | void;
  queryImplementation?: typeof query;
};

const localMCPServerName = "openassist_local_mcp";
const localMCPFindToolName = `mcp__${localMCPServerName}__find_tools`;
const localMCPCallToolName = `mcp__${localMCPServerName}__call_tool`;

function localMCPResult(value: unknown) {
  let text = "";
  try {
    text = JSON.stringify(value);
  } catch {
    text = String(value || "The MCP operation completed without a readable result.");
  }
  return { content: [{ type: "text" as const, text }] };
}

function claudeLocalMCPServer(localMCP: NonNullable<RunClaudeAgentTurnInput["localMCP"]>) {
  return createSdkMcpServer({
    name: "OpenAssist Local MCP",
    version: "1.0.0",
    instructions: [
      "This server exposes the local MCP servers approved in OpenAssist settings.",
      "Call find_tools before claiming an MCP server or connector is unavailable.",
      "Use call_tool for a discovered read action. If it reports confirmationRequired, ask for approval and then use call_tool_confirmed."
    ].join(" "),
    alwaysLoad: true,
    tools: [
      tool(
        "find_tools",
        "Find exact tools across the local MCP servers approved in OpenAssist. Use this when the user names MCP, an external service, or asks what an MCP can do.",
        {
          query: z.string().min(1),
          server: z.string().optional(),
          limit: z.number().int().min(1).max(8).optional()
        },
        async (args) => localMCPResult(await localMCP.findTools(args)),
        { alwaysLoad: true }
      ),
      tool(
        "call_tool",
        "Run one exact read-only MCP tool returned by find_tools. Write tools return confirmationRequired and are not executed.",
        {
          toolID: z.string().min(1),
          arguments: z.record(z.string(), z.unknown()).optional()
        },
        async (args) => localMCPResult(await localMCP.callTool({ ...args, confirmed: false })),
        { alwaysLoad: true }
      ),
      tool(
        "call_tool_confirmed",
        "Run one exact MCP write tool after the user approves it. This tool is intentionally not pre-approved.",
        {
          toolID: z.string().min(1),
          arguments: z.record(z.string(), z.unknown()).optional()
        },
        async (args) => localMCPResult(await localMCP.callTool({ ...args, confirmed: true })),
        { alwaysLoad: true }
      )
    ]
  });
}

export type ListClaudeAgentModelsInput = {
  cwd: string;
  publicConfigDirectory: string;
  authProfile?: ClaudeAgentAuthProfile;
  timeoutMs?: number;
  queryImplementation?: typeof query;
};

type PendingClaudeRequest = {
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
};

const pendingClaudeRequests = new Map<string, PendingClaudeRequest>();

export function resolveClaudeAgentRequest(requestID: string | number, result: unknown) {
  const pending = pendingClaudeRequests.get(String(requestID));
  if (!pending) return false;
  pendingClaudeRequests.delete(String(requestID));
  pending.resolve(result);
  return true;
}

function recordValue(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function stringValue(...values: unknown[]) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
}

function permissionKind(toolName: string): ClaudeAgentActivity["approvalKind"] {
  if (toolName === "AskUserQuestion") return "userInput";
  if (/^(Edit|Write|NotebookEdit|MultiEdit)$/i.test(toolName)) return "fileChange";
  if (/^(Bash|KillShell|TaskStop)$/i.test(toolName)) return "command";
  return "permissions";
}

function toolActivityID(toolUseID: string) {
  return `claude-tool-${toolUseID}`;
}

function exactPermissionFingerprint(toolName: string, input: Record<string, unknown>) {
  return `${toolName}:${claudeAgentValuePreview(input, 2_000)}`;
}

function approvalQuestions(input: Record<string, unknown>): ClaudeAgentApprovalQuestion[] {
  return arrayValue(input.questions).map((rawQuestion, index) => {
    const question = recordValue(rawQuestion);
    return {
      id: stringValue(question.id) || `question-${index + 1}`,
      header: stringValue(question.header) || undefined,
      prompt: stringValue(question.question, question.prompt, question.header) || `Question ${index + 1}`,
      multiSelect: question.multiSelect === true || question.multi_select === true,
      allowFreeText: true,
      options: arrayValue(question.options).map((rawOption) => {
        const option = recordValue(rawOption);
        return {
          label: stringValue(option.label, option.value) || "Option",
          description: stringValue(option.description) || undefined
        };
      })
    };
  });
}

function schemaQuestions(schema: Record<string, unknown> | undefined): ClaudeAgentApprovalQuestion[] {
  const properties = recordValue(schema?.properties);
  const required = new Set(arrayValue(schema?.required).map(String));
  return Object.entries(properties).map(([id, rawProperty]) => {
    const property = recordValue(rawProperty);
    const enumValues = arrayValue(property.enum).map(String);
    return {
      id,
      header: stringValue(property.title) || undefined,
      prompt: stringValue(property.description, property.title) || id,
      multiSelect: property.type === "array",
      allowFreeText: enumValues.length === 0,
      options: enumValues.map((label) => ({ label })),
      required: required.has(id)
    } as ClaudeAgentApprovalQuestion & { required: boolean };
  });
}

function elicitationContent(value: unknown): Record<string, string | number | boolean | string[]> {
  const content: Record<string, string | number | boolean | string[]> = {};
  for (const [key, raw] of Object.entries(recordValue(value))) {
    if (typeof raw === "string" || typeof raw === "number" || typeof raw === "boolean") {
      content[key] = raw;
      continue;
    }
    if (Array.isArray(raw)) content[key] = raw.map(String);
  }
  return content;
}

function waitForRequest(
  requestID: string,
  signal: AbortSignal,
  onAbortMessage: string,
  ownedRequests: Set<string>
) {
  return new Promise<unknown>((resolve, reject) => {
    ownedRequests.add(requestID);
    let settled = false;
    let abort: () => void = () => {};
    const cleanup = () => {
      pendingClaudeRequests.delete(requestID);
      ownedRequests.delete(requestID);
      signal.removeEventListener("abort", abort);
    };
    const resolveRequest = (result: unknown) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(result);
    };
    const rejectRequest = (error: Error) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(error);
    };
    pendingClaudeRequests.set(requestID, { resolve: resolveRequest, reject: rejectRequest });
    abort = () => rejectRequest(new Error(onAbortMessage));
    if (signal.aborted) {
      abort();
      return;
    }
    signal.addEventListener("abort", abort, { once: true });
  });
}

function activityFromToolUse(block: Record<string, unknown>, parentToolUseID?: string | null): ClaudeAgentActivity | null {
  const toolUseID = stringValue(block.id);
  const toolName = stringValue(block.name);
  if (!toolUseID || !toolName) return null;
  return {
    id: toolActivityID(toolUseID),
    title: claudeAgentToolTitle(toolName),
    kind: toolName.startsWith("mcp__") ? "mcpToolCall" : "tool",
    status: "running",
    detail: claudeAgentValuePreview(block.input) || "Working...",
    parentToolUseID: parentToolUseID || undefined
  };
}

function toolResultBlocks(message: SDKMessage): Array<Record<string, unknown>> {
  const rawMessage = recordValue((message as unknown as Record<string, unknown>).message);
  return arrayValue(rawMessage.content)
    .map(recordValue)
    .filter((block) => block.type === "tool_result");
}

function resultError(message: SDKMessage) {
  const row = message as unknown as Record<string, unknown>;
  const errors = arrayValue(row.errors).map(String).filter(Boolean);
  return errors.join("\n") || stringValue(row.error, row.stop_reason) || "Claude Agent SDK did not finish the turn.";
}

function textDeltaFromStream(message: SDKMessage) {
  const event = recordValue((message as unknown as Record<string, unknown>).event);
  if (event.type !== "content_block_delta") return "";
  const delta = recordValue(event.delta);
  return delta.type === "text_delta" ? stringValue(delta.text) : "";
}

function numberValue(...values: unknown[]) {
  for (const value of values) {
    if (typeof value === "number" && Number.isFinite(value)) return value;
  }
  return 0;
}

function thinkingUpdateFromMessage(message: SDKMessage) {
  const row = message as unknown as Record<string, unknown>;
  if (row.type === "system" && row.subtype === "thinking_tokens") {
    return {
      text: "",
      estimatedTokens: numberValue(row.estimated_tokens),
      estimatedTokensDelta: numberValue(row.estimated_tokens_delta)
    };
  }
  const event = recordValue((message as unknown as Record<string, unknown>).event);
  if (event.type !== "content_block_delta") return null;
  const delta = recordValue(event.delta);
  if (delta.type !== "thinking_delta") return null;
  return {
    text: stringValue(delta.thinking),
    estimatedTokens: numberValue(delta.estimated_tokens),
    estimatedTokensDelta: numberValue(delta.estimated_tokens_delta)
  };
}

export async function listClaudeAgentModels(input: ListClaudeAgentModelsInput): Promise<ModelInfo[]> {
  const abortController = new AbortController();
  const timeout = setTimeout(() => abortController.abort(), Math.max(1_000, input.timeoutMs ?? 10_000));
  fs.mkdirSync(input.publicConfigDirectory, { recursive: true });
  const runQuery = input.queryImplementation ?? query;
  const querySession = runQuery({
    prompt: "",
    options: {
      abortController,
      cwd: input.cwd,
      persistSession: false,
      settingSources: ["user", "project", "local"],
      env: claudeAgentEnvironment({
        authProfile: input.authProfile ?? claudeAgentAuthProfile(),
        publicConfigDirectory: input.publicConfigDirectory
      })
    }
  });
  try {
    return await querySession.supportedModels();
  } finally {
    clearTimeout(timeout);
    querySession.close();
  }
}

async function handleElicitation(
  request: ElicitationRequest,
  signal: AbortSignal,
  emit: (activity: ClaudeAgentActivity) => void,
  ownedRequests: Set<string>,
  onOpenURL?: (url: string) => Promise<void> | void
): Promise<ElicitationResult> {
  const requestID = `claude-elicitation-${randomUUID()}`;
  const questions = request.mode === "form" ? schemaQuestions(request.requestedSchema) : [];
  const pendingResult = waitForRequest(requestID, signal, "Claude elicitation was cancelled.", ownedRequests);
  emit({
    id: `activity-${requestID}`,
    title: request.displayName || request.title || "Claude connection",
    kind: "mcpElicitation",
    status: "waiting",
    detail: request.description || request.message,
    approvalRequestID: requestID,
    approvalKind: "mcpElicitation",
    approvalPrompt: request.message,
    approvalQuestions: questions.length ? questions : undefined,
    approvalOptions: questions.length ? undefined : [
      { id: "accept", label: request.mode === "url" ? "Open" : "Allow", tone: "approve", result: { decision: "accept" } },
      { id: "decline", label: "Decline", tone: "danger", result: { decision: "decline" } },
      { id: "cancel", label: "Cancel", tone: "danger", result: { decision: "cancel" } }
    ]
  });
  const result = recordValue(await pendingResult);
  const decision = stringValue(result.decision);
  if (decision === "answers") return { action: "accept", content: elicitationContent(result.answers) };
  if (decision === "accept") {
    if (request.mode === "url" && request.url) await onOpenURL?.(request.url);
    return { action: "accept", content: elicitationContent(result.content) };
  }
  return { action: decision === "cancel" ? "cancel" : "decline" };
}

export async function runClaudeAgentTurn(input: RunClaudeAgentTurnInput) {
  const abortController = input.abortController ?? new AbortController();
  const sessionAllows = new Set<string>();
  const emittedTools = new Set<string>();
  // Stable WITHIN this turn (streamed reasoning updates merge into one entry)
  // but unique ACROSS turns. Keying it on the session ID made every turn
  // update the PREVIOUS turn's reasoning entry in place — it kept the old
  // createdAt, the turn finalizer back-dated the new user message before it,
  // and the display sort then merged both turns' tool steps into one group.
  const reasoningActivityID = `claude-reasoning-${randomUUID()}`;
  const toolActivities = new Map<string, ClaudeAgentActivity>();
  const ownedRequests = new Set<string>();
  const authProfile = input.authProfile ?? claudeAgentAuthProfile();
  fs.mkdirSync(input.publicConfigDirectory, { recursive: true });

  const emit = (activity: ClaudeAgentActivity) => {
    if (activity.kind === "tool" || activity.kind === "mcpToolCall") {
      toolActivities.set(activity.id, activity);
    }
    input.onActivity?.(activity);
  };
  const canUseTool: NonNullable<Options["canUseTool"]> = async (toolName, toolInput, context): Promise<PermissionResult> => {
    const fingerprint = exactPermissionFingerprint(toolName, toolInput);
    if (sessionAllows.has(fingerprint)) return { behavior: "allow", updatedInput: toolInput };
    const questions = toolName === "AskUserQuestion" ? approvalQuestions(toolInput) : [];
    const requestID = `claude-approval-${randomUUID()}`;
    const activityID = toolActivityID(context.toolUseID);
    const pendingAnswer = waitForRequest(requestID, context.signal, "Claude approval was cancelled.", ownedRequests);
    emit({
      id: activityID,
      title: context.displayName || claudeAgentToolTitle(toolName),
      kind: questions.length ? "userInput" : toolName.startsWith("mcp__") ? "mcpToolCall" : "tool",
      status: "waiting",
      detail: context.description || context.decisionReason || claudeAgentValuePreview(toolInput) || "Claude needs approval.",
      approvalRequestID: requestID,
      approvalKind: permissionKind(toolName),
      approvalPrompt: context.title || context.description || `${claudeAgentToolTitle(toolName)} needs approval.`,
      approvalQuestions: questions.length ? questions : undefined,
      approvalOptions: questions.length ? undefined : [
        { id: "allow", label: "Allow", tone: "approve", result: { decision: "allow" } },
        { id: "allow-session", label: "Allow for Session", tone: "approve", result: { decision: "allowSession" } },
        { id: "deny", label: "Deny", tone: "danger", result: { decision: "deny" } },
        { id: "stop", label: "Stop", tone: "danger", result: { decision: "stop" } }
      ]
    });
    const answer = recordValue(await pendingAnswer);
    const decision = stringValue(answer.decision);
    if (questions.length && decision === "answers") {
      // The tool expects answers keyed by the QUESTION TEXT with plain string
      // values. The UI keys them by our invented per-question ids (and sends
      // arrays for multi-select), so translate — passing them through raw made
      // the tool report "The user did not answer the questions."
      const rawAnswers = recordValue(answer.answers);
      const inputQuestions = arrayValue(toolInput.questions).map(recordValue);
      const normalizedAnswers: Record<string, string> = {};
      questions.forEach((question, index) => {
        const key = stringValue(inputQuestions[index]?.question) || question.prompt;
        const value = rawAnswers[question.id];
        const text = Array.isArray(value)
          ? value.map((entry) => String(entry).trim()).filter(Boolean).join(", ")
          : String(value ?? "").trim();
        if (key && text) normalizedAnswers[key] = text;
      });
      return { behavior: "allow", updatedInput: { ...toolInput, answers: normalizedAnswers } };
    }
    if (decision === "allowSession") {
      sessionAllows.add(fingerprint);
      const suggestions = context.suggestions?.filter((suggestion): suggestion is PermissionUpdate => Boolean(suggestion));
      return {
        behavior: "allow",
        updatedInput: toolInput,
        updatedPermissions: suggestions?.length ? suggestions : undefined
      };
    }
    if (decision === "allow") return { behavior: "allow", updatedInput: toolInput };
    if (decision === "stop") return { behavior: "deny", message: "Stopped by the user.", interrupt: true };
    return { behavior: "deny", message: "Denied by the user." };
  };

  const localMCPServer = input.localMCP ? claudeLocalMCPServer(input.localMCP) : undefined;
  const mcpServers = {
    ...(input.mcpServers || {}),
    ...(localMCPServer ? { [localMCPServerName]: localMCPServer } : {})
  };
  const safeReadTools = [
    ...(input.safeReadTools || []),
    ...(localMCPServer ? [localMCPFindToolName, localMCPCallToolName] : [])
  ];
  const options: Options = {
    abortController,
    cwd: input.cwd,
    ...(input.forkFromSessionID
      ? { resume: input.forkFromSessionID, forkSession: true, sessionId: input.sessionID }
      : input.isNewSession ? { sessionId: input.sessionID } : { resume: input.sessionID }),
    model: claudeAgentModel(input.modelID),
    effort: claudeAgentEffort(input.reasoningEffort),
    ...(input.adaptiveThinking ? {
      thinking: { type: "adaptive" as const },
      showThinkingSummaries: true
    } : {}),
    includePartialMessages: true,
    forwardSubagentText: false,
    persistSession: true,
    tools: { type: "preset", preset: "claude_code" },
    systemPrompt: input.systemInstructions
      ? { type: "preset", preset: "claude_code", append: input.systemInstructions }
      : { type: "preset", preset: "claude_code" },
    mcpServers,
    strictMcpConfig: input.strictMcpConfig,
    ...(input.enableChromeIntegration ? { extraArgs: { chrome: null } } : {}),
    allowedTools: safeReadTools,
    canUseTool,
    onElicitation: (request, context) => handleElicitation(
      request,
      context.signal,
      emit,
      ownedRequests,
      input.onOpenURL
    ),
    env: claudeAgentEnvironment({
      authProfile,
      publicConfigDirectory: input.publicConfigDirectory
    }),
    ...claudeAgentPermissionOptions(input.permissionMode)
  };

  let finalResult = "";
  let terminalError = "";
  let reasoningBuffer = "";
  let sawReasoning = false;
  let lastContextTokens = 0;
  let reasoningTokenEstimate = 0;
  let lastReasoningEmit = 0;
  input.onStatus?.("Claude is working...");

  try {
    const runQuery = input.queryImplementation ?? query;
    const querySession = runQuery({ prompt: input.prompt, options });
    const supportedModels = (querySession as { supportedModels?: () => Promise<ModelInfo[]> }).supportedModels;
    if (typeof supportedModels === "function") {
      void supportedModels.call(querySession)
        .then((models) => input.onSupportedModels?.(models))
        .catch(() => undefined);
    }
    for await (const message of querySession) {
      if (message.session_id) input.onSessionID?.(message.session_id);
      const thinking = thinkingUpdateFromMessage(message);
      if (thinking && !(message as unknown as { parent_tool_use_id?: string | null }).parent_tool_use_id) {
        sawReasoning = true;
        if (thinking.text) reasoningBuffer += thinking.text;
        reasoningTokenEstimate = Math.max(
          reasoningTokenEstimate + thinking.estimatedTokensDelta,
          thinking.estimatedTokens
        );
        const now = Date.now();
        if (now - lastReasoningEmit >= 250) {
          lastReasoningEmit = now;
          emit({
            id: reasoningActivityID,
            title: "Reasoning",
            kind: "reasoning",
            status: "running",
            detail: reasoningBuffer.slice(-2_000) || "Claude is thinking through the request..."
          });
        }
      }
      if (message.type === "stream_event") {
        const delta = textDeltaFromStream(message);
        if (delta && !message.parent_tool_use_id) input.onDelta?.(delta);
        continue;
      }
      if (message.type === "assistant") {
        if (message.error) terminalError = `Claude reported ${message.error.replace(/_/g, " ")}.`;
        // The latest API call's input side (prompt + cache reads/writes) is the
        // best live estimate of how full the model's context window is.
        const usage = recordValue((message.message as unknown as Record<string, unknown>).usage);
        const usageTokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
          .reduce((sum, key) => sum + (typeof usage[key] === "number" ? usage[key] as number : 0), 0);
        if (usageTokens > 0) lastContextTokens = usageTokens;
        const content = arrayValue((message.message as unknown as Record<string, unknown>).content).map(recordValue);
        for (const block of content) {
          if (block.type !== "tool_use") continue;
          const activity = activityFromToolUse(block, message.parent_tool_use_id);
          if (activity && !emittedTools.has(activity.id)) {
            emittedTools.add(activity.id);
            emit(activity);
          }
        }
        continue;
      }
      if (message.type === "user") {
        for (const block of toolResultBlocks(message)) {
          const toolUseID = stringValue(block.tool_use_id);
          if (!toolUseID) continue;
          const failed = block.is_error === true;
          const activityID = toolActivityID(toolUseID);
          const previous = toolActivities.get(activityID);
          emit({
            id: activityID,
            title: previous?.title || "Claude tool",
            kind: previous?.kind || "tool",
            status: failed ? "failed" : "completed",
            detail: claudeAgentValuePreview(block.content) || (failed ? "Tool failed." : "Tool completed."),
            parentToolUseID: previous?.parentToolUseID
          });
        }
        continue;
      }
      if (message.type === "system" && message.subtype === "permission_denied") {
        emit({
          id: toolActivityID(message.tool_use_id),
          title: claudeAgentToolTitle(message.tool_name),
          kind: "tool",
          status: "failed",
          detail: message.message || message.decision_reason || "Permission denied."
        });
        continue;
      }
      if (message.type === "system" && message.subtype === "api_retry") {
        input.onStatus?.(`Claude is retrying after ${message.error.replace(/_/g, " ")}...`);
        continue;
      }
      if (message.type === "result") {
        if (message.subtype === "success") finalResult = message.result.trim();
        else terminalError = resultError(message);
        const modelEntries = Object.entries(message.modelUsage ?? {})
          .filter(([, entry]) => entry && typeof entry.contextWindow === "number" && entry.contextWindow > 0)
          .sort(([, left], [, right]) =>
            (right.inputTokens + right.cacheReadInputTokens) - (left.inputTokens + left.cacheReadInputTokens)
          );
        const [mainModelID, mainModel] = modelEntries[0] ?? [];
        const contextTokens = lastContextTokens
          || (mainModel ? mainModel.inputTokens + mainModel.cacheReadInputTokens + mainModel.cacheCreationInputTokens : 0);
        if (contextTokens > 0 || mainModel) {
          input.onTokenUsage?.({
            currentContextTokens: contextTokens,
            modelContextWindow: mainModel?.contextWindow,
            modelID: mainModelID
          });
        }
      }
    }
  } finally {
    for (const requestID of ownedRequests) {
      const pending = pendingClaudeRequests.get(requestID);
      if (!pending) continue;
      pendingClaudeRequests.delete(requestID);
      pending.reject(new Error("Claude turn ended before the request was answered."));
    }
  }

  if (sawReasoning) {
    emit({
      id: reasoningActivityID,
      title: "Reasoning",
      kind: "reasoning",
      status: terminalError || !finalResult ? "failed" : "completed",
      detail: reasoningBuffer.slice(-2_000)
        || (reasoningTokenEstimate > 0
          ? `Claude used private reasoning for this answer.`
          : "Claude finished thinking through the request.")
    });
  }
  if (terminalError) throw new Error(terminalError);
  if (!finalResult) throw new Error("Claude Agent SDK completed without a final response.");
  return { text: finalResult, sessionID: input.sessionID, authProfile };
}
