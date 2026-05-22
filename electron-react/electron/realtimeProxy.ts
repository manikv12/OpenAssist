import http from "node:http";
import { EventEmitter } from "node:events";
import { WebSocket, WebSocketServer } from "ws";

type JsonObject = Record<string, unknown>;

export type RealtimeProxyConfig = {
  apiKey?: string;
  model: string;
  voice: string;
  organizationID?: string;
  projectID?: string;
  safetyIdentifier?: string;
};

type PendingHandoff = {
  callID: string;
  prompt: string;
  replyMode: "function" | "message";
};

type DelegationDecision =
  | { allow: true; prompt: string; normalizedPrompt: string }
  | { allow: false; output: string; createResponse: boolean; reason: string };

const defaultRealtimeModel = "gpt-realtime-mini";
const defaultRealtimeVoice = "marin";

function jsonObject(value: unknown): JsonObject | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : undefined;
}

function stringValue(...values: unknown[]) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
}

function parseJSON(value: string) {
  try {
    return JSON.parse(value) as unknown;
  } catch {
    return undefined;
  }
}

function normalizeRealtimeIntent(text: string) {
  return String(text || "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}'\s/-]/gu, " ")
    .replace(/\s+/g, " ")
    .replace(/\bcode base\b/g, "codebase")
    .replace(/\bboard base\b/g, "codebase")
    .replace(/\bcore base\b/g, "codebase")
    .replace(/\bcoat base\b/g, "codebase")
    .replace(/\bways about\b/g, "codebase about")
    .trim();
}

function stripAssistantEchoFragments(text: string) {
  return String(text || "")
    .replace(/\bhey there[,.]?\s*what'?s on your mind today[?]?\s*anything i can help you with[?]?/gi, " ")
    .replace(/\bhello there[!.]?\s*what can i do for you today[?]?/gi, " ")
    .replace(/\byep[,.]?\s*i'?m here[!.]?\s*what'?s on your mind[?]?/gi, " ")
    .replace(/\bi understand you'?re asking about notifications from x on brave browser[.]?\s*i'?m checking for that now[.]?\s*just a moment[.]?/gi, " ")
    .replace(/\byes[,.]?\s*i'?m still working on checking those notifications for you[.]?\s*it'?s taking a little longer than expected[.]?\s*i'?ll let you know as soon as i have an update[.]?/gi, " ")
    .replace(/\bi'?ll let you know as soon as i have an update[.]?/gi, " ")
    .replace(/\bnotifications for you[.]?\s*one moment[.]?/gi, " ")
    .replace(/\bi'?m still waiting for the results from that check on your notifications[.]?\s*i'?ll let you know the moment i have any new information[.]?/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function repairRealtimeDelegationText(text: string) {
  const stripped = stripAssistantEchoFragments(text);
  const normalized = normalizeRealtimeIntent(stripped || text);
  if (/^codebase about$/.test(normalized) || /\bcodebase\b.*\babout\b/.test(normalized)) {
    return "Summarize what this codebase is about.";
  }
  return stripped || text;
}

function isStopOrDismissal(text: string) {
  return [
    "stop",
    "cancel",
    "never mind",
    "nevermind",
    "that's all",
    "that is all",
    "you're done",
    "you are done",
    "done",
    "quit",
    "exit"
  ].some((phrase) => text === phrase || text.startsWith(`${phrase} `));
}

function isShortAcknowledgement(text: string) {
  return /^(mhm+|mm+hmm+|hmm+|hm+|ok|okay|yes|yeah|yep|yup|no|nope|uh|um|thanks|thank you|cool|nice|sure|alright|all right)$/i.test(text);
}

function isVagueRealtimeFollowupTask(text: string) {
  if (!/\b(it|that|this|same|again|previous|last|yesterday|tomorrow)\b/.test(text)) return false;
  if (!/\b(check|inspect|open|read|find|search|look|use|do|run|get|show|compare)\b/.test(text)) return false;
  return !/\b(browser|brave|chrome|square|calendar|notes|mail|finder|repo|repository|codebase|terminal|file|website|webpage|notification|notifications)\b/.test(text);
}

function isConversationFollowupQuestion(text: string) {
  return (
    /\b(tell|say|read|repeat)\b.*\b(it|that|this|the answer|the result|what you said)\b.*\bagain\b/.test(text) ||
    /\b(tell|say|read|repeat)\b.*\bagain\b/.test(text) ||
    /\bwhat (were|was) (we|you) (talking about|discussing|saying|working on)\b/.test(text) ||
    /\bwhat did (we|you) (talk about|discuss|say)\b/.test(text) ||
    /\bcan you tell it to me again\b/.test(text)
  );
}

function isCasualRealtimeQuestion(text: string) {
  const explicitToolRequest =
    /\b(browser|brave|chrome|computer|desktop app|website|webpage|codex|repo|repository|codebase|terminal|file)\b/.test(text)
    && /\b(open|check|inspect|use|search|find|read|look)\b/.test(text);
  if (explicitToolRequest) return false;

  return /\b(joke|funny|laugh|story|weather|time|date|who are you|how are you|what can you do|tell me about yourself|sing|poem)\b/.test(text)
    || isConversationFollowupQuestion(text);
}

function isSideQuestionWhileBusy(text: string) {
  if (!text) return false;
  if (/\b(add|fix|change|update|remove|delete|create|make|implement|wire|connect|hook|run|test|debug|install|start|build|commit|push|deploy|rename|move|refactor|write|edit|patch|verify|clone|pull)\b/.test(text)) {
    return false;
  }
  return /^(what|why|how|where|who|which|can you tell|tell me|explain|summarize)\b/.test(text)
    || /\b(status|what are you doing|what you're doing|what you are doing|working on|progress|codebase|code base|repo|repository|project|app|current folder)\b/.test(text);
}

function looksLikeCodexTask(text: string) {
  if (isCasualRealtimeQuestion(text)) return false;

  if (
    /\b(codebase|repo|repository|project|app|current folder)\b.*\b(about|summary|summarize|explain)\b/.test(text) ||
    /\b(about|summary|summarize|explain)\b.*\b(codebase|repo|repository|project|app|current folder)\b/.test(text)
  ) {
    return true;
  }

  const words = text.split(/\s+/).filter(Boolean);
  if (words.length <= 2 && !/\b(fix|add|run|test|check|open|build)\b/.test(text)) return false;

  const actionPattern = /\b(add|fix|change|update|remove|delete|create|make|implement|wire|connect|hook|run|test|check|inspect|search|find|open|read|review|explain|summarize|debug|look|turn|enable|disable|install|start|build|commit|push|deploy|rename|move|refactor|write|edit|patch|verify|compare|clone|pull)\b/;
  if (actionPattern.test(text)) return true;

  const codeContextPattern = /\b(error|bug|file|code|codebase|test|build|app|repo|repository|project|folder|branch|terminal|cli|server|endpoint|api|config|toml|swift|typescript|javascript|python|rust|node|npm|package|workspace|worktree|diff|changes|realtime|real-time|hook|hooks|integration|implementation|browser|brave|chrome|website|webpage|post|x post|tweet|notification|notifications|feed)\b/;
  if (codeContextPattern.test(text)) return true;

  const askPattern = /^(can you|could you|please|try to|let's|lets|i want|we need|need to|why is|why it|why it's|why does|why doesn't|why isnt|why isn't|why did|how do|where is)\b/;
  return askPattern.test(text) && !/\b(weather|time|date)\b/.test(text);
}

function shouldIgnoreBusyDelegationPrompt(prompt: string) {
  const normalized = normalizeRealtimeIntent(stripAssistantEchoFragments(prompt));
  if (!normalized) return true;
  if (isStopOrDismissal(normalized)) return false;
  if (isCasualRealtimeQuestion(normalized)) return false;
  if (isSideQuestionWhileBusy(normalized)) return false;

  const words = normalized.split(/\s+/).filter(Boolean);
  const clearAction = /\b(add|fix|change|update|remove|delete|create|make|implement|wire|connect|hook|run|test|debug|install|start|build|open|check|inspect|search|find|read|review|explain|summarize)\b/.test(normalized);
  if (/^(up|about|it|this|that|there|here|yes|no|ok|okay|uh|um|hmm|mhm)$/.test(normalized)) return true;
  if (words.length <= 2 && !clearAction) return true;
  if (words.length <= 3 && !looksLikeCodexTask(normalized)) return true;
  return false;
}

function conversationItemUserText(event: JsonObject) {
  if (event.type !== "conversation.item.create") return "";
  const item = jsonObject(event.item);
  if (!item || stringValue(item.role).toLowerCase() !== "user") return "";
  const content = Array.isArray(item.content) ? item.content : [];
  return content
    .map((entry) => {
      const object = jsonObject(entry);
      return stringValue(object?.text, object?.transcript);
    })
    .filter(Boolean)
    .join(" ")
    .trim();
}

function contextualizeRealtimeDelegationPrompt(prompt: string, lastDelegationPrompt: string) {
  const repairedPrompt = repairRealtimeDelegationText(prompt);
  const normalizedPrompt = normalizeRealtimeIntent(repairedPrompt);
  const prior = lastDelegationPrompt.trim();
  if (!prior || !isVagueRealtimeFollowupTask(normalizedPrompt)) return repairedPrompt;
  return [
    "Follow-up to the previous Codex task:",
    prior,
    "",
    "New user request:",
    repairedPrompt
  ].join("\n");
}

function decideRealtimeDelegation(prompt: string, hasActiveHandoff: boolean, lastDelegationPrompt = ""): DelegationDecision {
  const repairedPrompt = contextualizeRealtimeDelegationPrompt(prompt, lastDelegationPrompt);
  const normalizedPrompt = normalizeRealtimeIntent(repairedPrompt);
  const normalizedRawPrompt = normalizeRealtimeIntent(repairRealtimeDelegationText(prompt));

  if (!normalizedPrompt) {
    return {
      allow: false,
      output: "No clear task was heard. Wait for the user.",
      createResponse: false,
      reason: "empty prompt"
    };
  }

  if (isVagueRealtimeFollowupTask(normalizedRawPrompt) && !lastDelegationPrompt.trim()) {
    return {
      allow: false,
      output: "This follow-up is too vague without a previous Codex task. Ask one short clarification question.",
      createResponse: true,
      reason: "vague follow-up"
    };
  }

  if (isShortAcknowledgement(normalizedPrompt)) {
    return {
      allow: false,
      output: "The user only acknowledged. Do not start Codex; wait for the next clear request.",
      createResponse: false,
      reason: "short acknowledgement"
    };
  }

  if (isStopOrDismissal(normalizedPrompt)) {
    return {
      allow: false,
      output: "The user dismissed the task. Do not start Codex.",
      createResponse: true,
      reason: "dismissal"
    };
  }

  if (hasActiveHandoff && shouldIgnoreBusyDelegationPrompt(repairedPrompt)) {
    return {
      allow: false,
      output: "Codex is already working, and this was not a new clear task. Wait for the user.",
      createResponse: false,
      reason: "busy non-task"
    };
  }

  if (isCasualRealtimeQuestion(normalizedPrompt)) {
    return {
      allow: false,
      output: "This is a casual voice question. Answer it directly without starting Codex.",
      createResponse: true,
      reason: "casual question"
    };
  }

  if (!looksLikeCodexTask(normalizedPrompt)) {
    return {
      allow: false,
      output: "This is not a clear Codex task. Answer directly if helpful, otherwise wait.",
      createResponse: true,
      reason: "not a codex task"
    };
  }

  return { allow: true, prompt: repairedPrompt, normalizedPrompt };
}

function openAIRealtimeURL(model: string) {
  const url = new URL("wss://api.openai.com/v1/realtime");
  url.searchParams.set("model", model.trim() || defaultRealtimeModel);
  return url.toString();
}

function realtimeInstructions(codexInstructions: string) {
  return [
    "# Role and Objective",
    "You are the realtime voice layer inside Codex.",
    "Messages from Codex are authoritative. Present the system as one Codex assistant.",
    "",
    "# Voice Style",
    "Speak naturally, briefly, and clearly.",
    "For casual questions, answer directly in one or two short sentences.",
    "Do not read markdown symbols, XML tags, diffs, or asterisks out loud.",
    "",
    "# Listening Control",
    "If the user asks you to stop listening, mute, pause listening, go quiet, or stop responding, call set_listening_mode with mode quiet.",
    "If the user asks you to start listening again, resume listening, or says they are back after quiet mode, call set_listening_mode with mode listening.",
    "",
    "# Silence and Background Audio",
    "If the latest audio is silence, background noise, speaker echo, a side conversation, or speech not addressed to Codex, call wait_for_user.",
    "Do not respond conversationally after calling wait_for_user.",
    "",
    "# Unclear Audio",
    "Only act on clear audio or text.",
    "If the user's audio is unclear, ask one short clarification question.",
    "Do not call tools, guess codebase details, or give a preamble when the audio is unclear.",
    "",
    "# Tools",
    "Before calling background_agent for work that may take noticeable time, say one short preamble immediately, then call the tool.",
    "If the user request is agentic, call background_agent instead of doing it yourself.",
    "Agentic means the request needs tools, files, code changes, terminal commands, browser/computer use, website/app inspection, account data, current/live information, or multi-step work.",
    "For coding, codebase, repo, app, terminal, debugging, install, file, browser, computer, desktop app, website, current/live data, or configuration work, call background_agent with the user's exact request.",
    "Only call background_agent when the user gives a clear task that needs Codex tools.",
    "Follow-up task requests like \"check it for yesterday\" or \"do the same for yesterday\" should call background_agent using the recent Codex task as context.",
    "If the user only says ok, yes, no, mhm, hmm, thanks, or another short acknowledgement, do not call background_agent.",
    "If Codex is already working and the user gives a tiny acknowledgement or vague follow-up, do not start a new background_agent task.",
    "After calling background_agent, wait for the Codex result before giving task details.",
    "Do not invent codebase details.",
    codexInstructions.trim()
      ? ["", "# Codex Session Context", "Use this only as background context. Do not read it aloud unless the user asks.", codexInstructions.trim()].join("\n")
      : ""
  ].filter(Boolean).join("\n");
}

function realtimeSessionConfig(config: RealtimeProxyConfig, codexInstructions: string, quiet: boolean): JsonObject {
  return {
    type: "realtime",
    model: config.model || defaultRealtimeModel,
    instructions: realtimeInstructions(codexInstructions),
    output_modalities: ["audio"],
    audio: {
      input: {
        format: { type: "audio/pcm", rate: 24000 },
        noise_reduction: { type: "near_field" },
        transcription: { model: "gpt-4o-mini-transcribe", language: "en" },
        turn_detection: {
          type: "semantic_vad",
          interrupt_response: !quiet,
          create_response: !quiet
        }
      },
      output: {
        format: { type: "audio/pcm", rate: 24000 },
        voice: config.voice || defaultRealtimeVoice
      }
    },
    tools: [
      {
        type: "function",
        name: "wait_for_user",
        description: "Call this when the latest audio should not receive a spoken response.",
        parameters: { type: "object", properties: {}, required: [], additionalProperties: false }
      },
      {
        type: "function",
        name: "set_listening_mode",
        description: "Switch between normal listening and quiet mode.",
        parameters: {
          type: "object",
          properties: {
            mode: { type: "string", enum: ["quiet", "listening"] }
          },
          required: ["mode"],
          additionalProperties: false
        }
      },
      {
        type: "function",
        name: "background_agent",
        description: "Hand coding, repository, terminal, browser, computer, or app tasks to Codex.",
        parameters: {
          type: "object",
          properties: {
            prompt: { type: "string", description: "The exact task the user wants Codex to perform." }
          },
          required: ["prompt"],
          additionalProperties: false
        }
      }
    ],
    tool_choice: "auto"
  };
}

class RealtimeProxySession {
  private upstream?: WebSocket;
  private upstreamReady?: Promise<WebSocket | null>;
  private codexInstructions = "";
  private quiet = false;
  private audioItemID = "";
  private audioMs = 0;
  private openAIResponseActive = false;
  private pendingHandoffs = new Map<string, PendingHandoff>();
  private handledCalls = new Set<string>();
  private lastDelegationPrompt = "";
  private lastAutoHandoffNormalizedPrompt = "";
  private autoHandoffTimer?: NodeJS.Timeout;
  private autoHandoffSequence = 0;

  constructor(
    private readonly codexSocket: WebSocket,
    private readonly configProvider: () => RealtimeProxyConfig,
    private readonly log: (message: string) => void
  ) {}

  start() {
    this.codexSocket.on("message", (data) => {
      void this.onCodexMessage(data.toString());
    });
    this.codexSocket.on("close", () => this.close());
    this.codexSocket.on("error", (error) => this.log(`[realtime.proxy] client error: ${error.message}`));
  }

  private sendToCodex(event: JsonObject) {
    if (this.codexSocket.readyState !== WebSocket.OPEN) return false;
    this.codexSocket.send(JSON.stringify(event));
    return true;
  }

  private sendUpstream(event: JsonObject) {
    if (this.upstream?.readyState !== WebSocket.OPEN) return false;
    this.upstream.send(JSON.stringify(event));
    return true;
  }

  private async ensureUpstream() {
    if (this.upstream?.readyState === WebSocket.OPEN) return this.upstream;
    if (this.upstreamReady) return this.upstreamReady;

    this.upstreamReady = (async () => {
      const config = this.configProvider();
      const apiKey = config.apiKey?.trim();
      if (!apiKey) {
        this.sendToCodex({
          type: "error",
          error: { message: "Add an OpenAI realtime API key in Settings > Voice & Dictation." }
        });
        return null;
      }

      let connectionErrorMessage = "";
      let rejectConnection: ((error: Error) => void) | undefined;
      const headers: Record<string, string> = { Authorization: `Bearer ${apiKey}` };
      if (config.organizationID) headers["OpenAI-Organization"] = config.organizationID;
      if (config.projectID) headers["OpenAI-Project"] = config.projectID;
      if (config.safetyIdentifier) headers["OpenAI-Safety-Identifier"] = config.safetyIdentifier;

      const ws = new WebSocket(openAIRealtimeURL(config.model), { headers });
      this.upstream = ws;
      ws.on("message", (data) => {
        void this.onOpenAIMessage(data.toString());
      });
      ws.on("error", (error) => {
        const message = connectionErrorMessage || error.message || "OpenAI Realtime connection failed.";
        this.log(`[realtime.proxy] OpenAI websocket error: ${message}`);
        this.sendToCodex({ type: "error", error: { message } });
      });
      ws.on("unexpected-response", (_request, response) => {
        const chunks: Buffer[] = [];
        response.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
        response.on("end", () => {
          const detail = Buffer.concat(chunks).toString("utf8").trim();
          connectionErrorMessage = [
            `OpenAI Realtime rejected the connection (${response.statusCode} ${response.statusMessage || "HTTP error"}).`,
            detail ? detail.slice(0, 240) : "Check the API key, project access, and realtime model."
          ].join(" ");
          this.log(`[realtime.proxy] ${connectionErrorMessage}`);
          this.sendToCodex({ type: "error", error: { message: connectionErrorMessage } });
          rejectConnection?.(new Error(connectionErrorMessage));
          ws.terminate();
        });
      });
      ws.on("close", (_code, reason) => {
        const message = reason?.toString() || connectionErrorMessage || "no reason";
        this.log(`[realtime.proxy] OpenAI websocket closed: ${message}`);
        this.upstream = undefined;
        this.upstreamReady = undefined;
      });

      await new Promise<void>((resolve, reject) => {
        rejectConnection = reject;
        const timer = setTimeout(() => reject(new Error("OpenAI Realtime connection timed out.")), 15_000);
        ws.once("open", () => {
          rejectConnection = undefined;
          clearTimeout(timer);
          resolve();
        });
        ws.once("error", (error) => {
          rejectConnection = undefined;
          clearTimeout(timer);
          reject(connectionErrorMessage ? new Error(connectionErrorMessage) : error);
        });
      });

      this.updateOpenAISession();
      return ws;
    })().catch((error) => {
      this.upstreamReady = undefined;
      this.sendToCodex({
        type: "error",
        error: { message: error instanceof Error ? error.message : "OpenAI Realtime connection failed." }
      });
      return null;
    });

    return this.upstreamReady;
  }

  private updateOpenAISession() {
    this.sendUpstream({
      type: "session.update",
      session: realtimeSessionConfig(this.configProvider(), this.codexInstructions, this.quiet)
    });
  }

  private async onCodexMessage(payload: string) {
    const message = parseJSON(payload);
    const event = jsonObject(message);
    if (!event) return;

    if (event.type === "session.update") {
      const session = jsonObject(event.session) ?? {};
      this.codexInstructions = stringValue(session.instructions);
      const upstream = await this.ensureUpstream();
      if (!upstream) return;
      this.sendToCodex({
        type: "session.updated",
        session: {
          id: stringValue(session.id) || `sess_openassist_${Date.now()}`,
          instructions: "Open Assist realtime proxy is connected to OpenAI Realtime."
        }
      });
      this.updateOpenAISession();
      return;
    }

    if (event.type === "conversation.handoff.append") {
      await this.completeHandoff(event);
      return;
    }

    const userText = conversationItemUserText(event);
    if (userText) this.scheduleAutoHandoff(userText);

    if (event.type === "response.create" && this.quiet) return;

    const upstream = await this.ensureUpstream();
    if (!upstream) return;
    this.sendUpstream(event);
  }

  private async onOpenAIMessage(payload: string) {
    const message = parseJSON(payload);
    const event = jsonObject(message);
    if (!event) return;

    if (event.type === "error") {
      const error = jsonObject(event.error);
      const messageText = stringValue(error?.message, event.message) || "OpenAI Realtime error.";
      this.log(`[realtime.proxy] OpenAI error: ${messageText}`);
      this.sendToCodex({ type: "error", error: { message: messageText } });
      return;
    }

    if (event.type === "session.created" || event.type === "session.updated") return;

    if (event.type === "response.created") {
      this.openAIResponseActive = true;
      this.sendToCodex(event);
      return;
    }

    if (event.type === "input_audio_buffer.speech_started") {
      this.truncateOpenAIAudio();
      this.sendToCodex(event);
      return;
    }

    if (event.type === "conversation.item.input_audio_transcription.completed") {
      const transcript = stringValue(event.transcript, event.text);
      if (transcript) this.scheduleAutoHandoff(transcript);
      this.sendToCodex(event);
      return;
    }

    if (event.type === "response.output_audio.delta" || event.type === "response.audio.delta") {
      const delta = stringValue(event.delta);
      const itemID = stringValue(event.item_id, this.audioItemID) || `item_openai_audio_${Date.now()}`;
      const audio = delta ? Buffer.from(delta, "base64") : Buffer.alloc(0);
      if (this.audioItemID !== itemID) {
        this.audioItemID = itemID;
        this.audioMs = 0;
      }
      if (audio.length) {
        const samples = Math.floor(audio.length / 2);
        this.audioMs += Math.max(1, Math.round((samples * 1000) / 24000));
      }
      this.sendToCodex({
        ...event,
        type: "response.output_audio.delta",
        item_id: itemID,
        delta,
        sample_rate: 24000,
        channels: 1,
        samples_per_channel: Math.floor(audio.length / 2)
      });
      return;
    }

    if (event.type === "response.output_audio.done" || event.type === "response.audio.done") {
      this.sendToCodex({ ...event, type: "response.output_audio.done", item_id: stringValue(event.item_id, this.audioItemID) });
      this.audioItemID = "";
      this.audioMs = 0;
      return;
    }

    if (event.type === "response.output_item.done") {
      const item = jsonObject(event.item);
      if (item?.type === "function_call") {
        await this.handleFunctionCall(item);
        return;
      }
    }

    if (event.type === "response.done") {
      const response = jsonObject(event.response);
      const output = Array.isArray(response?.output) ? response.output : [];
      for (const item of output) {
        const object = jsonObject(item);
        if (object?.type === "function_call") await this.handleFunctionCall(object);
      }
      this.audioItemID = "";
      this.audioMs = 0;
      this.openAIResponseActive = false;
      this.sendToCodex(event);
      return;
    }

    this.sendToCodex(event);
  }

  private async handleFunctionCall(item: JsonObject) {
    const callID = stringValue(item.call_id) || `call_openassist_${Date.now()}`;
    if (this.handledCalls.has(callID)) return;
    this.handledCalls.add(callID);
    if (this.handledCalls.size > 100) {
      const oldest = this.handledCalls.values().next().value;
      if (oldest) this.handledCalls.delete(oldest);
    }

    const name = stringValue(item.name);
    if (name === "wait_for_user") {
      this.sendFunctionOutput(callID, "Waiting for the user.", false);
      return;
    }

    if (name === "set_listening_mode") {
      const args = jsonObject(parseJSON(stringValue(item.arguments))) ?? {};
      const mode = stringValue(args.mode, args.state).toLowerCase();
      this.quiet = /quiet|mute|pause|stop|off|not.listening/.test(mode);
      this.sendFunctionOutput(callID, this.quiet ? "Quiet mode is on." : "Listening mode is on.", !this.quiet);
      this.updateOpenAISession();
      return;
    }

    if (name !== "background_agent") return;

    this.clearAutoHandoff();
    const args = jsonObject(parseJSON(stringValue(item.arguments))) ?? {};
    const rawPrompt = stringValue(args.prompt, args.task, item.arguments) || "Continue the user's requested task.";
    const decision = decideRealtimeDelegation(rawPrompt, this.pendingHandoffs.size > 0, this.lastDelegationPrompt);
    if (!decision.allow) {
      this.log(`[realtime.proxy] ignored background_agent (${decision.reason}): ${rawPrompt.slice(0, 160)}`);
      this.sendFunctionOutput(callID, decision.output, decision.createResponse);
      return;
    }

    const duplicatePrompt = Array.from(this.pendingHandoffs.values()).some(
      (handoff) => normalizeRealtimeIntent(handoff.prompt) === decision.normalizedPrompt
    );
    if (duplicatePrompt) {
      this.log(`[realtime.proxy] ignored duplicate background_agent: ${decision.prompt.slice(0, 160)}`);
      this.sendFunctionOutput(callID, "That Codex task is already running. Do not start a duplicate.", false);
      return;
    }

    this.startCodexHandoff(callID, decision.prompt, "function");
  }

  private scheduleAutoHandoff(transcript: string) {
    if (this.quiet) return;
    const decision = decideRealtimeDelegation(transcript, this.pendingHandoffs.size > 0, this.lastDelegationPrompt);
    if (!decision.allow) return;
    if (decision.normalizedPrompt === this.lastAutoHandoffNormalizedPrompt) return;
    this.clearAutoHandoff();
    this.autoHandoffTimer = setTimeout(() => {
      void this.runAutoHandoff(transcript);
    }, 650);
  }

  private async runAutoHandoff(transcript: string) {
    this.autoHandoffTimer = undefined;
    const decision = decideRealtimeDelegation(transcript, this.pendingHandoffs.size > 0, this.lastDelegationPrompt);
    if (!decision.allow) return;
    const duplicatePrompt = Array.from(this.pendingHandoffs.values()).some(
      (handoff) => normalizeRealtimeIntent(handoff.prompt) === decision.normalizedPrompt
    );
    if (duplicatePrompt || decision.normalizedPrompt === this.lastAutoHandoffNormalizedPrompt) return;
    this.lastAutoHandoffNormalizedPrompt = decision.normalizedPrompt;
    if (this.openAIResponseActive) {
      this.sendUpstream({ type: "response.cancel" });
      this.openAIResponseActive = false;
    }
    this.truncateOpenAIAudio();
    const callID = `call_openassist_auto_${Date.now()}_${++this.autoHandoffSequence}`;
    this.log(`[realtime.proxy] auto background_agent: ${decision.prompt.slice(0, 160)}`);
    this.startCodexHandoff(callID, decision.prompt, "message");
  }

  private clearAutoHandoff() {
    if (!this.autoHandoffTimer) return;
    clearTimeout(this.autoHandoffTimer);
    this.autoHandoffTimer = undefined;
  }

  private startCodexHandoff(callID: string, prompt: string, replyMode: PendingHandoff["replyMode"]) {
    this.lastDelegationPrompt = prompt;
    this.pendingHandoffs.set(callID, { callID, prompt, replyMode });
    const itemID = `item_openassist_handoff_${Date.now()}`;
    this.sendToCodex({ type: "conversation.input_transcript.delta", delta: prompt });
    this.sendToCodex({
      type: "conversation.handoff.requested",
      handoff_id: callID,
      item_id: itemID,
      input_transcript: prompt
    });
    this.sendToCodex({
      type: "conversation.item.done",
      item: {
        id: itemID,
        type: "function_call",
        status: "completed",
        name: "background_agent",
        call_id: callID,
        arguments: JSON.stringify({ prompt })
      }
    });
  }

  private async completeHandoff(event: JsonObject) {
    const callID = stringValue(event.handoff_id, event.call_id)
      || this.pendingHandoffs.keys().next().value
      || "";
    if (!callID) return;
    const handoff = this.pendingHandoffs.get(callID);
    const text = stringValue(
      event.output,
      event.output_text,
      event.text,
      event.transcript,
      jsonObject(event.item)?.output,
      jsonObject(event.item)?.text
    ) || "Codex finished the task.";
    this.pendingHandoffs.delete(callID);
    await this.ensureUpstream();
    if (handoff?.replyMode === "message") {
      this.sendCodexResultMessage(text);
    } else {
      this.sendFunctionOutput(callID, text, true);
    }
  }

  private sendCodexResultMessage(output: string) {
    this.sendUpstream({
      type: "conversation.item.create",
      item: {
        type: "message",
        role: "user",
        content: [
          {
            type: "input_text",
            text: `[Codex task finished]\n${output}`
          }
        ]
      }
    });
    if (!this.quiet) this.sendUpstream({ type: "response.create" });
  }

  private sendFunctionOutput(callID: string, output: string, createResponse: boolean) {
    this.sendUpstream({
      type: "conversation.item.create",
      item: {
        type: "function_call_output",
        call_id: callID,
        output
      }
    });
    if (createResponse && !this.quiet) {
      this.sendUpstream({ type: "response.create" });
    }
  }

  private truncateOpenAIAudio() {
    if (!this.audioItemID) return;
    this.sendUpstream({
      type: "conversation.item.truncate",
      item_id: this.audioItemID,
      content_index: 0,
      audio_end_ms: Math.max(0, Math.round(this.audioMs))
    });
  }

  private close() {
    if (this.upstream?.readyState === WebSocket.OPEN || this.upstream?.readyState === WebSocket.CONNECTING) {
      this.upstream.close();
    }
    this.upstream = undefined;
    this.upstreamReady = undefined;
  }
}

export class CodexRealtimeProxy extends EventEmitter {
  private server?: http.Server;
  private wss?: WebSocketServer;
  private baseURLValue?: string;
  private config: RealtimeProxyConfig = {
    model: defaultRealtimeModel,
    voice: defaultRealtimeVoice
  };

  constructor(private readonly log: (message: string) => void = () => {}) {
    super();
  }

  configure(config: Partial<RealtimeProxyConfig>) {
    this.config = {
      ...this.config,
      ...config,
      model: config.model?.trim() || this.config.model || defaultRealtimeModel,
      voice: config.voice?.trim() || this.config.voice || defaultRealtimeVoice
    };
  }

  async ensureStarted() {
    if (this.server && this.baseURLValue) return this.baseURLValue;

    const server = http.createServer((req, res) => {
      if (req.url === "/health") {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: true, service: "openassist-codex-realtime-proxy" }));
        return;
      }
      res.writeHead(404, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "Use websocket /v1/realtime." }));
    });
    const wss = new WebSocketServer({ noServer: true });

    server.on("upgrade", (req, socket, head) => {
      const url = new URL(req.url || "/", `http://${req.headers.host || "127.0.0.1"}`);
      if (url.pathname !== "/v1/realtime") {
        socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      wss.handleUpgrade(req, socket, head, (ws) => {
        const session = new RealtimeProxySession(ws, () => this.config, this.log);
        session.start();
      });
    });

    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => resolve());
    });

    const address = server.address();
    if (!address || typeof address === "string") {
      server.close();
      throw new Error("Realtime proxy did not bind to a local TCP port.");
    }

    this.server = server;
    this.wss = wss;
    this.baseURLValue = `http://127.0.0.1:${address.port}`;
    this.log(`[realtime.proxy] listening ${this.baseURLValue}/v1/realtime`);
    return this.baseURLValue;
  }

  async stop() {
    for (const client of this.wss?.clients ?? []) {
      client.close();
    }
    await new Promise<void>((resolve) => {
      if (!this.server) {
        resolve();
        return;
      }
      this.server.close(() => resolve());
    });
    this.server = undefined;
    this.wss = undefined;
    this.baseURLValue = undefined;
  }
}
