import type { JsonObject, LiveVoiceProvider, ProviderEvent } from "./contracts.js";

export type LiveVoiceToolSpec = {
  name: string;
  description: string;
  parameters: JsonObject;
  geminiBehavior?: "NON_BLOCKING" | "BLOCKING";
};

const delegatedWorkExecutionProfileSchema: JsonObject = {
  type: "object",
  description: "Describe the work so OpenAssist can choose the Codex worker before execution. Set modelPreference only when the user explicitly asks for Spark or Sol.",
  properties: {
    depth: { type: "string", enum: ["auto", "fast", "deep"] },
    complexity: { type: "string", enum: ["simple", "complex"] },
    impact: { type: "string", enum: ["read_only", "reversible_write", "sensitive_write"] },
    stakes: { type: "string", enum: ["normal", "high"] },
    modelPreference: { type: "string", enum: ["spark", "sol"], description: "Only when the finalized user request explicitly selects Spark or Sol." }
  },
  required: ["depth", "complexity", "impact", "stakes"],
  additionalProperties: false
};

export const liveVoicePublicToolSpecs: LiveVoiceToolSpec[] = [
  {
    name: "assistant_capability",
    description: "Discover or execute one exact local capability for personal data, tasks, notes, recall, local MCP, or image work. If discovery returns choices, select one exact capabilityID and call again. A candidate list is never the user's answer.",
    geminiBehavior: "BLOCKING",
    parameters: {
      type: "object",
      properties: {
        goal: { type: "string", description: "The user's complete goal in their own words." },
        operation: { type: "string", enum: ["discover", "read", "search", "create", "update", "move", "complete", "delete", "execute"] },
        sourceHints: { type: "array", items: { type: "string" }, description: "Sources explicitly named by the user, such as OpenAssist, Apple Reminders, memory, or an MCP server." },
        capabilityID: { type: "string", description: "Exact capability selected from a prior discovery result." },
        arguments: { type: "object", additionalProperties: true },
        confirmationToken: { type: "string", description: "Approval token returned by a prior approval_required result." }
      },
      required: ["goal"],
      additionalProperties: false
    }
  },
  {
    name: "assistant_delegate_work",
    description: "Delegate genuine Codex agent work such as current web research, code, terminal, browser, Computer Use, or a Codex skill. Do not use when assistant_capability can directly do the request. One or more explicit tasks may run in the background.",
    geminiBehavior: "NON_BLOCKING",
    parameters: {
      type: "object",
      properties: {
        goal: { type: "string", description: "The complete work request." },
        tasks: {
          type: "array",
          items: {
            type: "object",
            properties: {
              prompt: { type: "string" },
              provider: { type: "string" },
              project: { type: "string" },
              executionProfile: delegatedWorkExecutionProfileSchema,
              freshThread: { type: "boolean", description: "Set true only when the user explicitly asks to start over in a new thread or to drop earlier task context." }
            },
            required: ["prompt", "executionProfile"],
            additionalProperties: false
          }
        },
        provider: { type: "string", description: "Only set when the user explicitly names a worker/provider." },
        project: { type: "string", description: "Only set when the user explicitly names a destination project." },
        executionProfile: delegatedWorkExecutionProfileSchema,
        freshThread: { type: "boolean", description: "Set true only when the user explicitly asks to start over in a new thread or to drop earlier task context. Follow-up work otherwise continues in the same worker thread automatically." }
      },
      required: ["goal", "executionProfile"],
      additionalProperties: false
    }
  },
  {
    name: "assistant_task_status",
    description: "Read the authoritative state of current or recently finished background work. Always call this before answering whether delegated work is done, still running, waiting, failed, or has findings. Progress text is not a completion result.",
    geminiBehavior: "BLOCKING",
    parameters: {
      type: "object",
      properties: { taskID: { type: "string" } },
      required: [],
      additionalProperties: false
    }
  },
  {
    name: "assistant_cancel_task",
    description: "Cancel explicit background work only when the user clearly asks to cancel that work. Stopping Live Voice does not cancel work.",
    geminiBehavior: "BLOCKING",
    parameters: {
      type: "object",
      properties: { taskID: { type: "string" } },
      required: [],
      additionalProperties: false
    }
  }
];

export function providerTranscriptFinalized(provider: LiveVoiceProvider, turnID: string, text: string, providerItemID = ""): ProviderEvent {
  return { type: "transcript_finalized", provider, turnID, providerItemID: providerItemID || undefined, textLength: text.length, at: Date.now() };
}

export function providerToolRequested(provider: LiveVoiceProvider, turnID: string, callID: string, toolName: string): ProviderEvent {
  return { type: "tool_requested", provider, turnID, callID, toolName, at: Date.now() };
}

export function providerAudioStarted(provider: LiveVoiceProvider, turnID = "", itemID = ""): ProviderEvent {
  return {
    type: "audio_started",
    provider,
    turnID: turnID || undefined,
    itemID: itemID || undefined,
    at: Date.now()
  };
}

export function providerResponseCompleted(provider: LiveVoiceProvider, turnID = "", responseID = ""): ProviderEvent {
  return {
    type: "response_completed",
    provider,
    turnID: turnID || undefined,
    responseID: responseID || undefined,
    at: Date.now()
  };
}

export function providerInterrupted(provider: LiveVoiceProvider, turnID = "", reason = "interrupted"): ProviderEvent {
  return { type: "interrupted", provider, turnID: turnID || undefined, reason, at: Date.now() };
}

export function providerConnectionClosed(provider: LiveVoiceProvider, reason = "connection closed"): ProviderEvent {
  return { type: "connection_closed", provider, reason, at: Date.now() };
}

export function providerConnectionRestored(provider: LiveVoiceProvider): ProviderEvent {
  return { type: "connection_restored", provider, at: Date.now() };
}

export function openAIFunctionOutput(callID: string, output: unknown) {
  return {
    type: "conversation.item.create",
    item: { type: "function_call_output", call_id: callID, output: typeof output === "string" ? output : JSON.stringify(output) }
  } satisfies JsonObject;
}

export function geminiFunctionResponse(id: string, name: string, output: unknown) {
  return { id, name, response: { output } } satisfies JsonObject;
}
