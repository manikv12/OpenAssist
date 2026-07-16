import http from "node:http";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { WebSocket, WebSocketServer } from "ws";
import {
  buildLiveVoiceBootstrapContext,
  geminiResumptionCacheKey,
  geminiResumptionHandles,
  LiveVoiceCompletedTurnTracker,
  type LiveVoiceBootstrapContext,
  type LiveVoiceCompletedTurn,
  type LiveVoiceHistoryMessage
} from "./liveVoiceContinuity.js";
import {
  RealtimeTaskCoordinator,
  type RealtimeTaskRecord
} from "./realtimeTaskCoordinator.js";
import { classifyVoiceRoute } from "./voiceRouting.js";

type JsonObject = Record<string, unknown>;
export type RealtimeHandoffReplyMode = "function" | "message";
export type RealtimeCloudProvider = "openaiRealtime" | "geminiLive";
export type RealtimeDelegationRouteDecision = "delegate" | "answer_direct" | "clarify" | "ignore" | "control";
export type RealtimeDelegationRouteSource = "tool_call" | "auto_transcript";
export type RealtimeDelegationMode = "autoHardTasksOnly" | "alwaysDelegate" | "neverDelegate";
export type RealtimeDelegationRouteInput = {
  source: RealtimeDelegationRouteSource;
  provider: RealtimeCloudProvider;
  agentLabel: string;
  prompt: string;
  proposedTaskText: string;
  lastDelegationPrompt: string;
  lastDelegationResult: string;
  hasActiveHandoff: boolean;
  voiceState: "listening" | "speaking" | "delegating" | "quiet";
};
export type RealtimeSessionState = "idle" | "listening" | "speaking" | "toolPending" | "delegating" | "narrating" | "quiet";
export type RealtimeSessionStateSnapshot = {
  state: RealtimeSessionState;
  previousState?: RealtimeSessionState;
  reason: string;
  quiet: boolean;
  pendingHandoffs: number;
  activeParallelDelegations: number;
  queuedNarrations: number;
  responseActive: boolean;
  voicePhase: "connecting" | "listening" | "speaking" | "quiet" | "closed" | "error";
  foregroundWork?: "knowledge" | "tool";
  voiceProvider: RealtimeCloudProvider;
  workerProvider: string;
  tasks: Array<{
    taskID: string;
    sourceTurnID: string;
    prompt: string;
    workerProvider: string;
    state: RealtimeTaskRecord["state"];
    progress: string;
    progressEntries: RealtimeTaskRecord["progressEntries"];
    result: string;
    error: string;
    deliveryState: RealtimeTaskRecord["deliveryState"];
    startedAt: number;
    updatedAt: number;
    finishedAt?: number;
  }>;
};
export type RealtimeDelegationRouteResult = {
  decision: RealtimeDelegationRouteDecision;
  taskText?: string;
  responseText?: string;
  confidence?: number;
  reason?: string;
};
export type RealtimeVisualContextImage = {
  dataURL: string;
  mimeType?: string;
  name?: string;
};
export type RealtimeVisualContext = {
  images: RealtimeVisualContextImage[];
  text?: string;
  createResponse?: boolean;
};

export type RealtimeProxyConfig = {
  provider?: RealtimeCloudProvider;
  apiKey?: string;
  model: string;
  voice: string;
  organizationID?: string;
  projectID?: string;
  safetyIdentifier?: string;
  handoff?: {
    agentLabel: string;
    run: (request: {
      taskID: string;
      sourceTurnID: string;
      callID: string;
      prompt: string;
      replyMode: RealtimeHandoffReplyMode;
      signal: AbortSignal;
      onProgress: (detail: string) => void;
    }) => Promise<{ output: string; workerProvider?: string } | string>;
    cancel?: (taskID: string) => Promise<void> | void;
  };
  // Runs several delegated tasks at once, each in its own thread / provider / folder,
  // and reports back one result per task as soon as that task finishes. The proxy
  // narrates the results one at a time (never overlapping) via reportTaskResult.
  parallelDelegation?: {
    maxTasks: number;
    run: (request: {
      callID: string;
      tasks: Array<{ prompt: string; provider?: string; project?: string }>;
      reportTaskResult: (result: {
        index: number;
        label: string;
        agentLabel: string;
        provider?: string;
        project?: string;
        prompt: string;
        text: string;
        failed: boolean;
      }) => void;
    }) => Promise<{ accepted: number; skipped: number; note?: string }>;
  };
	  knowledge?: {
	    enabled: boolean;
	    context?: {
	      projectID?: string;
	      projectName?: string;
	      threadID?: string;
	    };
	    call: (name: string, args: JsonObject) => Promise<unknown>;
	  };
	  codexImageGeneration?: {
	    run: (request: { callID: string; args: JsonObject; prompt: string }) => Promise<unknown>;
	  };
	  directKnowledgeRequest?: {
	    run: (request: { callID: string; prompt: string; replyMode: RealtimeHandoffReplyMode }) => Promise<string | undefined | null>;
	  };
  directWork?: {
    onEvent: (event: {
      callID: string;
      toolName: string;
      status: "running" | "completed" | "failed";
      prompt: string;
      detail: string;
      error?: string;
      args?: JsonObject;
      result?: unknown;
    }) => void;
  };
	  connection?: {
	    onEvent: (event: {
	      type: "client_closed" | "upstream_closed" | "upstream_reconnect_scheduled" | "upstream_reconnected" | "upstream_reconnect_failed" | "state_changed";
	      reason?: string;
	      attempt?: number;
	      delayMs?: number;
	      message?: string;
	      state?: RealtimeSessionState;
	      previousState?: RealtimeSessionState;
	      snapshot?: RealtimeSessionStateSnapshot;
	    }) => void;
	  };
  delegationRouter?: {
    route: (input: RealtimeDelegationRouteInput) => Promise<RealtimeDelegationRouteResult>;
  };
  delegationMode?: RealtimeDelegationMode;
  continuity?: {
    threadKey: string;
    bootstrap: LiveVoiceBootstrapContext;
    onCompletedTurn: (turn: LiveVoiceCompletedTurn & {
      provider: RealtimeCloudProvider;
      source?: "direct" | "delegated";
      workerProvider?: string;
      taskState?: "completed" | "failed" | "cancelled";
      taskStartedAt?: number;
      taskFinishedAt?: number;
      progressEntries?: Array<{ id: string; text: string; createdAt: number }>;
    }) => Promise<void> | void;
    onStatus?: (event: { status: "restored" | "restore_failed" | "persist_failed"; message?: string }) => void;
  };
};

type PendingHandoff = RealtimeTaskRecord;

type PersonalRecallCacheEntry = {
  promise?: Promise<unknown>;
  result?: unknown;
  updatedAt: number;
};

type GeminiLiveSession = {
  sendRealtimeInput: (input: unknown) => void;
  sendClientContent: (input: unknown) => void;
  sendToolResponse: (response: unknown) => void;
  close: () => void;
};

type DelegationDecision =
  | { allow: true; prompt: string; normalizedPrompt: string }
  | { allow: false; output: string; createResponse: boolean; reason: string };

const defaultRealtimeModel = "gpt-realtime-mini";
const defaultRealtimeVoice = "marin";
const defaultGeminiLiveModel = "gemini-3.1-flash-live-preview";
const defaultGeminiLiveVoice = "Aoede";
const autoHandoffDelayMs = 900;
// Reliability tuning for the OpenAI realtime upstream socket.
const upstreamKeepAliveIntervalMs = 15_000;
const upstreamReconnectBaseDelayMs = 400;
const upstreamReconnectMaxDelayMs = 5_000;
const maxUpstreamReconnectAttempts = 5;
// How eagerly OpenAI's semantic VAD decides the user has started speaking.
// Keep this conservative: the app already sends gated mic audio, and false
// speech-starts cut off spoken replies.
const realtimeVADEagerness = "low";
// Safety net: max time we keep believing a response is "active" without a
// response.done before we force-clear the flag so the assistant is never stuck mute.
// Kept short for fast recovery; the watchdog re-arms instead of firing while audio
// is still actively streaming, so it never cuts a long but legitimate spoken answer.
const openAIResponseWatchdogMs = 5_000;
const openAIDirectResultAudioRetryMs = 9_000;
const geminiSetupTimeoutMs = 12_000;
const personalRecallResultCacheMs = 5 * 60_000;

function unrefTimer(timer: ReturnType<typeof setTimeout> | ReturnType<typeof setInterval>) {
  const maybeTimer = timer as { unref?: () => void };
  if (typeof maybeTimer.unref === "function") maybeTimer.unref();
}

function makeShortRealtimeID(prefix: string, sequence = 0) {
  const safePrefix = prefix.replace(/[^a-z0-9_]/gi, "").slice(0, 10) || "oa";
  const timestamp = Date.now().toString(36);
  const seq = Math.max(0, sequence).toString(36);
  const suffix = Math.random().toString(36).slice(2, 8);
  return `${safePrefix}_${timestamp}_${seq}_${suffix}`.slice(0, 32);
}

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

function openAIResponseTranscript(response: JsonObject | undefined) {
  const output = Array.isArray(response?.output) ? response.output : [];
  const chunks: string[] = [];
  for (const rawItem of output) {
    const item = jsonObject(rawItem);
    if (!item || item.type === "function_call") continue;
    const content = Array.isArray(item.content) ? item.content : [];
    for (const rawContent of content) {
      const part = jsonObject(rawContent);
      const text = stringValue(part?.transcript, part?.text);
      if (text) chunks.push(text);
    }
  }
  return chunks.join(" ").replace(/\s+/g, " ").trim();
}

function dataURLParts(dataURL: string, fallbackMimeType = "image/png") {
  const match = /^data:([^;,]+);base64,(.+)$/i.exec(dataURL.trim());
  if (!match) return null;
  return {
    mimeType: match[1] || fallbackMimeType,
    base64: match[2] || ""
  };
}

function isBenignRealtimeCancelError(message: string) {
  const normalized = String(message || "").toLowerCase();
  return normalized.includes("cancel") && normalized.includes("no active response");
}

function isFatalGeminiLiveCloseReason(reason: string) {
  return (
    /\b(quota|billing|api key|apikey|permission|unauthori[sz]ed|forbidden|resource exhausted|exceeded)\b/i.test(reason) ||
    /BidiGenerateContentRequest\.setup|function_declarations|missing field|invalid argument/i.test(reason)
  );
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
  // Phrases that should match as the whole utterance or at its start.
  const prefixPhrases = [
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
    "exit",
    // Natural ways people interrupt the assistant while it is talking.
    "can you stop",
    "could you stop",
    "would you stop",
    "please stop",
    "stop please",
    "wait",
    "wait wait",
    "hold on",
    "hold up",
    "hang on",
    "one second",
    "one sec",
    "one moment",
    "just a second",
    "just a moment",
    "give me a second",
    "give me a moment"
  ];
  if (prefixPhrases.some((phrase) => text === phrase || text.startsWith(`${phrase} `))) {
    return true;
  }
  // Clear interruptions that count even if they appear mid-utterance.
  return /\b(stop talking|stop speaking|be quiet|shut up|shush|that'?s enough|enough enough)\b/.test(text);
}

function isShortAcknowledgement(text: string) {
  return /^(mhm+|mm+hmm+|hmm+|hm+|ok|okay|yes|yeah|yep|yup|no|nope|uh|um|thanks|thank you|cool|nice|sure|alright|all right)(\s+(thanks|thank you))?$/i.test(text)
    || /^(thanks|thank you)\s+(ok|okay|yes|yeah|yep|yup|sure)$/i.test(text);
}

function isVagueRealtimeFollowupTask(text: string) {
  if (!/\b(it|that|this|same|again|previous|last|yesterday|tomorrow)\b/.test(text)) return false;
  if (!/\b(check|inspect|open|read|find|search|look|use|do|run|get|show|compare)\b/.test(text)) return false;
  return !/\b(browser|brave|chrome|square|calendar|notes|mail|finder|repo|repository|codebase|terminal|file|website|webpage|notification|notifications)\b/.test(text);
}

function isVagueRealtimeHelpRequest(text: string) {
  return /^(hey\s+)?(open assist|openassist|assistant|codex)?\s*(can|could|would|will)\s+you\s+help(\s+me)?(\s+with\s+(something|this|that))?$/.test(text)
    || /^(hey\s+)?(open assist|openassist|assistant|codex)?\s*i\s+(need|want)\s+help(\s+with\s+(something|this|that))?$/.test(text)
    || /^(hey\s+)?(open assist|openassist|assistant|codex)?\s*(are you there|hello|hi|hey)$/.test(text);
}

function isCasualRealtimeGreeting(text: string) {
  const normalized = normalizeRealtimeIntent(text);
  return /^(hey|hi|hello|hallo|hej|ei|good morning|good afternoon|good evening|how are you|are you there|open assist|openassist|assistant|codex)$/.test(normalized)
    || /^(hey|hi|hello|hallo|hej|ei)\s+(open assist|openassist|assistant|codex)$/.test(normalized);
}

function looksIncompleteForDelegation(text: string) {
  const raw = String(text || "").trim();
  const normalized = normalizeRealtimeIntent(raw);
  if (!normalized) return true;
  const words = normalized.split(/\s+/).filter(Boolean);
  if (words.length <= 3 && !/\b(open|check|inspect|search|find|read|fix|add|run|test)\b/.test(normalized)) {
    return true;
  }
  if (/\b(and|or|then|to|for|with|using|about|because|so|if|when|while)$/i.test(normalized)) {
    return true;
  }
  if (/^(if|whether|when|while|because|so|and|also|then)\b/.test(normalized)) {
    return !/\b(check|find|search|look up|open|inspect|tell me|let me know|report|answer|summarize|explain)\b/.test(normalized);
  }
  return /[,;:]$/.test(raw);
}

function looksLikeMissingReferenceFollowup(text: string) {
  const normalized = normalizeRealtimeIntent(text);
  if (!normalized) return false;
  const asksWhichThing = /\b(which|what|where)\b.{0,45}\b(node|step|item|file|screen|workflow|one)\b/.test(normalized);
  const refersToUnspecifiedChange = /\b(updated|changed|modified|added|removed|created|done|fixed)\b/.test(normalized);
  const reportsMissingContext = /\b(i\s+(do not|don't|cannot|can't)\s+(see|find|tell|know)|not\s+sure|which\s+one)\b/.test(normalized);
  const namesAConcreteTarget = /\b(repo|repository|project|path|file\s+named|node\s+named|workflow\s+named|called)\b/.test(normalized);
  return asksWhichThing && refersToUnspecifiedChange && reportsMissingContext && !namesAConcreteTarget;
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

function isExplicitRealtimeRerunRequest(text: string) {
  return /\b(recheck|rerun|redo|retry|start over)\b/.test(text)
    || /\b(check|search|find|run|do|try|look|scan|open|inspect)\b.{0,80}\b(again|one more time|another time)\b/.test(text)
    || /\b(again|one more time|another time)\b.{0,80}\b(check|search|find|run|do|try|look|scan|open|inspect)\b/.test(text);
}

type ConversationRecallRoute = "none" | "personal" | "current" | "clarify";

// "Save this to memory" / "forget that memory" are write tasks, not recall.
function isMemoryWriteRequest(normalized: string) {
  return /\b(add|save|store|create|write|put|update|edit|delete|remove|clear|forget)\b.{0,50}\b(memory|memories)\b/.test(normalized)
    || /\b(memory|memories)\b.{0,30}\b(add|save|store|create|write|update|edit|delete|remove|clear|forget)\b/.test(normalized);
}

// Possessive/state memory questions ("what memory do I have from codex",
// "list my saved memories", "what's in my memory") have no check/search verb,
// so the verb-based recall patterns miss them. Catch them explicitly.
function asksAboutStoredMemories(normalized: string) {
  if (!/\b(memory|memories)\b/.test(normalized)) return false;
  if (isMemoryWriteRequest(normalized)) return false;
  return /\b(what|which|any|how many)\b.{0,60}\b(memory|memories)\b/.test(normalized)
    || /\b(list|show|read|tell me)\b.{0,60}\b(memory|memories)\b/.test(normalized)
    || /\b(do|does|did)\b.{0,25}\b(i|you|we|it|codex|claude|spark|gemini|chatgpt)\b.{0,40}\bhave\b.{0,50}\b(memory|memories)\b/.test(normalized)
    || /\b(memory|memories)\b.{0,50}\b(do|does|did)\b.{0,25}\b(i|you|we|it|codex|claude|spark|gemini|chatgpt)\b.{0,25}\bhave\b/.test(normalized)
    || /\b(memory|memories)\b.{0,40}\b(have been|has been|are|is|were|was)\b.{0,25}\b(saved|stored)\b/.test(normalized)
    || /\bin\b.{0,20}\b(my|the|your)\b.{0,25}\b(memory|memories)\b/.test(normalized)
    || /\b(know|knows)\b.{0,25}\babout\b.{0,12}\b(me|us)\b.{0,30}\b(memory|memories)\b/.test(normalized);
}

// "What does Codex remember about me" — recall even without the word memory.
function asksWhatAgentRemembers(normalized: string) {
  return /\b(you|codex|claude|spark|gemini|chatgpt|assistant)\b.{0,30}\b(remember|remembers|know|knows)\b.{0,25}\babout\b.{0,12}\b(me|us)\b/.test(normalized);
}

function currentConversationRecallText() {
  return "Answer from this current thread or live conversation only. Do not search saved memory or start a background task.";
}

function recallScopeClarificationText() {
  return "Do you mean this thread, or should I search all saved memory?";
}

function notPersonalRecallToolText() {
  return "This is not a memory recall request. Use the correct realtime tool or background_agent for the user's actual task instead of knowledge_personal_recall.";
}

function realtimePromptWantsImageGeneration(text: string) {
  const normalized = normalizeRealtimeIntent(text);
  const asksForCreation = /\b(generate|create|make|draw|render|design|illustrate|paint|mock up|mockup|turn|convert)\b/.test(normalized);
  const asksForImage = /\b(image|picture|photo|logo|icon|illustration|mockup|poster|banner|cover|thumbnail|wallpaper|avatar|sticker|graphic|visual)\b/.test(normalized);
  const editsReferenceImage = /\b(use|edit|change|update|improve|build on|work on)\b.{0,80}\b(latest|attached|this|that)\b.{0,80}\b(image|photo|picture|poster|banner|logo|mockup|graphic)\b/.test(normalized);
  return (asksForCreation && asksForImage) || editsReferenceImage;
}

function hasCurrentConversationScope(normalized: string) {
  return /\b(this|current|same)\s+(thread|chat|conversation|session|live)\b/.test(normalized)
    || /\b(in|from|inside)\s+(this|current)\s+(thread|chat|conversation|session|live)\b/.test(normalized)
    || /\bthis thread itself\b/.test(normalized)
    || /\bin here\b/.test(normalized);
}

function hasPersonalRecallSourceScope(normalized: string) {
  return /\b(memory|memories|saved|history|timeline|previous|earlier|last time|old conversation|past conversation|conversation we had|conversations we had|chat we had|chat that we had|saved chats?|saved conversations?|all chats?|all threads?|all sessions?|codex thread|claude code|sessions?|transcript)\b/.test(normalized);
}

function hasAgentRecallSubject(normalized: string) {
  if (!/\b(codex|claude|spark|gemini|chatgpt|agent|assistant)\b/.test(normalized)) return false;
  return /\b(what did|where did|when did|did we|did you|have we|have you)\b.{0,90}\b(say|answer|respond|tell|find|decide|talk|discuss|work|do|check)\b/.test(normalized)
    || /\b(said|answered|responded|told|found|decided|talked|discussed|worked on|previous|earlier|last time|memory|remember)\b/.test(normalized);
}

function looksLikeExternalLookupTask(normalized: string) {
  return /\b(prompt|ask|tell)?\b.{0,30}\b(check|search|find|look up|look|browse|open|inspect)\b.{0,80}\b(online|on ine|web|internet|website|site|google|current|latest|live)\b/.test(normalized)
    || /\b(check|search|find|look up|look|browse|open|inspect)\b.{0,80}\b(online|on ine|web|internet|website|site|google|current|latest|live)\b/.test(normalized);
}

function requiresAgentExecution(normalized: string) {
  const asksForWork = /\b(check|inspect|run|query|read|search|find|debug|open|use|calculate|verify|review|investigate|pull|fetch|download|trace|diagnose|what happened|why)\b/.test(normalized);
  if (!asksForWork) return false;
  const asksForPastResult = /\bwhat did\b.{0,60}\b(we|you|the agent|codex|claude)\b.{0,80}\b(find|see|say|answer|conclude|discover)\b/.test(normalized)
    || /\b(previous|earlier|last)\b.{0,60}\b(result|answer|finding|conclusion)\b/.test(normalized);
  if (asksForPastResult) return false;
  const explicitAgent = /\b(agent|codex|claude|coding assistant)\b/.test(normalized);
  const namedToolRequest = /\b(using|via|through|with)\b.{0,60}\b(cli|tool|app|service|system|api|console|dashboard)\b/.test(normalized);
  const executionContext = /\b(cli|terminal|shell|command line|logs?|database|sql|server|deployment|deploy|build|tests?|repo|repository|codebase|package manager|runtime|debugger|admin console)\b/.test(normalized);
  const savedRecallContext = /\b(memory|memories|saved chats?|saved conversations?|all chats?|all threads?|all sessions?|conversation history|chat history)\b/.test(normalized);
  if (savedRecallContext && !namedToolRequest && !executionContext) return false;
  return explicitAgent || namedToolRequest || executionContext;
}

function asksForPastLookupResult(normalized: string) {
  return /\b(previous|earlier|last|old|saved)\b.{0,90}\b(search|searched|lookup|looked up|online|web|internet|result|answer|response)\b/.test(normalized)
    || /\bwhat did\b.{0,80}\b(you|we|the agent|codex|claude|spark|gemini|chatgpt|assistant)\b.{0,80}\b(find|say|answer|respond)\b.{0,80}\b(online|web|internet|search|searched|lookup)\b/.test(normalized);
}

function hasExplicitRecallSubject(normalized: string) {
  const blockedFirstWords = new Set([
    "this",
    "current",
    "same",
    "that",
    "it",
    "here",
    "today",
    "yesterday",
    "tomorrow",
    "last",
    "earlier",
    "previous",
    "the",
    "a",
    "an",
    "my",
    "your",
    "our"
  ]);
  const subjectPattern = /\b(on|about|for|with|inside)\s+((?:the\s+)?[a-z0-9][a-z0-9'/-]+(?:\s+(?!on\b|about\b|for\b|with\b|inside\b|today\b|yesterday\b|tomorrow\b|last\b|earlier\b|previous\b)[a-z0-9][a-z0-9'/-]+){0,5})/g;
  for (const match of normalized.matchAll(subjectPattern)) {
    const phrase = String(match[2] || "").replace(/^the\s+/, "").trim();
    const words = phrase.split(/\s+/).filter(Boolean);
    if (!words.length || blockedFirstWords.has(words[0])) continue;
    if (words.length >= 2) return true;
    if (/\b(openassist|atoms|rapid|widgtimator|tax-claim-it|taxclaim|amwins|qualitynails)\b/.test(phrase)) return true;
  }
  return false;
}

function isBroadWorkHistoryQuestion(normalized: string) {
  return /\bwhat did\b.{0,30}\b(you|we|the agent|codex|claude|spark|gemini|chatgpt|assistant)\b.{0,60}\b(work|worked|working|do|doing)\b.{0,50}\b(today|yesterday|tomorrow|last night|last week|this week|earlier|previously)\b/.test(normalized)
    || /\bwhat (are|were)\b.{0,30}\b(you|we|the agent|codex|claude|spark|gemini|chatgpt|assistant)\b.{0,60}\b(work|worked|working|do|doing)\b.{0,50}\b(today|yesterday|tomorrow|last night|last week|this week|earlier|previously)\b/.test(normalized)
    || /\b(did|have|had)\b.{0,30}\b(you|we|i|the agent|codex|claude|spark|gemini|chatgpt|assistant)\b.{0,70}\b(work|worked|working|do|done|doing|anything)\b/.test(normalized);
}

function conversationRecallRoute(text: string): ConversationRecallRoute {
  const normalized = normalizeRealtimeIntent(text);
  if (!normalized) return "none";
  if (hasCurrentConversationScope(normalized)) return "current";
  if (requiresAgentExecution(normalized)) return "none";

  const hasRecallSource = hasPersonalRecallSourceScope(normalized);
  if (looksLikeExternalLookupTask(normalized) && !asksForPastLookupResult(normalized)) return "none";

  const asksWhetherAlready =
    /\b(wants?|asked|asks?|wondering)\b.{0,80}\b(if|whether)\b.{0,80}\balready\b/.test(normalized)
    || /\b(did|have|had|were|was)\b.{0,20}\b(you|we|the agent|codex|claude|assistant)\b.{0,100}\balready\b/.test(normalized);
  if (asksWhetherAlready) return "personal";
  if (asksAboutStoredMemories(normalized) || asksWhatAgentRemembers(normalized)) return "personal";
  if (isExplicitRealtimeRerunRequest(normalized)) return "none";

  if (isBroadWorkHistoryQuestion(normalized)) {
    if (hasPersonalRecallSourceScope(normalized) || hasAgentRecallSubject(normalized) || hasExplicitRecallSubject(normalized)) return "personal";
    return "clarify";
  }

  if (hasRecallSource && (
    /\b(check|search|look|look into|find|read|scan)\b.{0,50}\b(memory|memories|saved|history|timeline|previous|earlier|all chats?|all threads?|all sessions?)\b/.test(normalized)
    || /\b(memory|memories|saved|history|timeline|previous|earlier|all chats?|all threads?|all sessions?|chat|conversation|thread|session|transcript)\b.{0,70}\b(check|search|look|look into|find|read|scan|had|talked|discussed)\b/.test(normalized)
    || /\b(check|search|look|look into|find|read|scan)\b.{0,70}\b(chat|conversation|thread|session|transcript)\b.{0,50}\b(had|talked|discussed|yesterday|today|earlier|previous)\b/.test(normalized)
    || /\b(do you|can you)\b.{0,30}\bremember\b/.test(normalized)
  )) return "personal";
  if (/\bwhere (are|were)\b.{0,80}\b(we|i|you)\b.{0,80}\b(on|with|in|at)\b/.test(normalized)) {
    return hasExplicitRecallSubject(normalized) ? "personal" : "clarify";
  }

  const isRecall = /\balready\b.{0,60}\b(found|find|figured|figure|checked|searched|ran|did|done|finished|answered|responded|looked)\b/.test(normalized)
    || /\b(previous|last|earlier)\b.{0,80}\b(turn|message|answer|response|task|result|conversation|thing)\b/.test(normalized)
    || /\bwhat\b.{0,30}\b(note|task|item|reminder|file|document|project)\b.{0,80}\b(added|created|saved|updated|edited|made|worked on)\b.{0,40}\b(last time|previously|earlier)\b/.test(normalized)
    || /\b(last time|previously|earlier)\b.{0,60}\bwhat\b.{0,30}\b(note|task|item|reminder|file|document|project)\b/.test(normalized)
    || /\bwhat did\b.{0,30}\b(you|we|the agent|codex|claude|spark|gemini|chatgpt|assistant)\b.{0,60}\b(find|say|do|answer|respond|figure out|check)\b/.test(normalized)
    || /\bwhat (was|were)\b.{0,70}\b(result|answer|plan|decision|status|state|process|last thing|previous thing)\b/.test(normalized)
    || /\bdid (we|i|you)\b.{0,80}\b(talk|discuss|decide|plan|ask|mention)\b/.test(normalized)
    || /\b(do you|can you)\b.{0,30}\bremember\b/.test(normalized);
  return isRecall ? "personal" : "none";
}

function isConversationRecallQuestion(text: string) {
  return conversationRecallRoute(text) !== "none";
}

// Route guard for a model-initiated knowledge_personal_recall call. The model
// may rephrase the user's question into wording the regexes miss, so check the
// model's query AND the raw utterance and take the most permissive result.
// A user-stated "this thread" scope still wins over everything else.
function recallRouteForToolCall(query: string, utterance: string): ConversationRecallRoute {
  const texts = [query, utterance].map((text) => String(text || "").trim()).filter(Boolean);
  const normalizedUtterance = normalizeRealtimeIntent(utterance);
  // The raw user request wins over a model-rephrased recall query. A request
  // that requires real tool execution is current agent work, never memory.
  if (requiresAgentExecution(normalizedUtterance)) return "none";
  const routes = texts.map((text) => conversationRecallRoute(text));
  if (routes.includes("current")) return "current";
  if (routes.includes("personal")) return "personal";
  if (routes.includes("clarify")) return "clarify";
  // The model already chose the recall tool. If the text plainly talks about
  // memory/remembering and is not a memory write or a new external lookup,
  // trust that choice instead of vetoing it.
  for (const text of texts) {
    const normalized = normalizeRealtimeIntent(text);
    if (!normalized) continue;
    if (!/\b(memory|memories|remember|remembers)\b/.test(normalized)) continue;
    if (isMemoryWriteRequest(normalized)) continue;
    if (looksLikeExternalLookupTask(normalized)) continue;
    return "personal";
  }
  return "none";
}

function isCasualRealtimeQuestion(text: string) {
  if (isConversationRecallQuestion(text)) return true;

  const explicitToolRequest =
    /\b(browser|brave|chrome|computer|desktop app|website|webpage|codex|repo|repository|codebase|terminal|file)\b/.test(text)
    && /\b(open|check|inspect|use|search|find|read|look)\b/.test(text);
  if (explicitToolRequest) return false;

  return /\b(joke|funny|laugh|story|weather|time|date|who are you|how are you|what can you do|tell me about yourself|sing|poem)\b/.test(text)
    || /\b(are you|is it)\s+ready\b/.test(text)
    || isConversationFollowupQuestion(text);
}

function looksLikeRealtimeKnowledgeTask(text: string) {
  const normalized = normalizeRealtimeIntent(text);
  if (!normalized) return false;
  if (/\b(codebase|repo|repository|terminal|logs?|debug|build|test|install|package|browser|chrome|brave|computer|desktop|downloads|file system|folder)\b/.test(normalized)) {
    return false;
  }
  const knowledgeSubject = /\b(my notes?|notes?|today|tomorrow|yesterday|planner|journal|to-?do|tasks?|items?|reminders?|backlog|follow-?ups?|later)\b/.test(normalized);
  if (!knowledgeSubject) return false;
  return /\b(what|which|list|show|read|open|unfinished|done|complete|mark|add|create|move|carry|schedule|reschedule|remove|delete|check|do we have|any|how many)\b/.test(normalized)
    || /\b(on|for)\s+(today|tomorrow|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/.test(normalized);
}

function looksLikeNoteOrganizeTask(text: string) {
  const normalized = normalizeRealtimeIntent(text);
  if (!normalized) return false;
  if (/\b(codebase|repo|repository|terminal|logs?|debug|build|test|install|package|browser|chrome|brave|computer|desktop|downloads|file system|folder)\b/.test(normalized)) {
    return false;
  }
  const noteSubject = /\b(my notes?|notes?|this note|that note|current note|open note|project note|thread note|journal)\b/.test(normalized);
  if (!noteSubject) return false;
  return /\b(organize|reorganize|structure|restructure|clean up|cleanup|tidy|reformat|format|rewrite|rework|make it readable|make .* easier to scan|use .*style|style it|summarize into sections)\b/.test(normalized);
}

function shouldUseDirectKnowledgeInsteadOfAgent(text: string) {
  return looksLikeRealtimeKnowledgeTask(text) && !looksLikeNoteOrganizeTask(text);
}

function isSideQuestionWhileBusy(text: string) {
  if (!text) return false;
  if (/\b(add|fix|change|update|remove|delete|create|make|implement|wire|connect|hook|run|test|debug|install|start|build|commit|push|deploy|rename|move|refactor|write|edit|patch|verify|clone|pull)\b/.test(text)) {
    return false;
  }
  return /^(what|why|how|where|who|which|can you tell|tell me|explain|summarize)\b/.test(text)
    || /\b(status|what are you doing|what you're doing|what you are doing|working on|progress|codebase|code base|repo|repository|project|app|current folder)\b/.test(text);
}

function isDelegatedStatusQuestion(text: string) {
  const normalized = normalizeRealtimeIntent(text);
  if (!normalized) return false;
  return /\b(status|progress|stuck|still working|still running|still going|done yet|finished yet|complete yet|current status|current step|current tool)\b/.test(normalized)
    || /^(is|are)\s+(it|that|this|the task|the job|codex|the agent|you)\s+(done|finished|complete)(\s+now)?$/.test(normalized)
    || /\b(what|which|show|give|tell)\b.{0,45}\b(result|response|answer|outcome)\b/.test(normalized)
    || /\b(result|response|answer|outcome)\b.{0,35}\b(ready|done|finished|complete|come back|returned)\b/.test(normalized)
    || /\b(what are you doing|what you are doing|what you're doing|what is it doing|what's it doing|what is the agent doing)\b/.test(normalized)
    || /\b(what's happening|what is happening|what happened|where is it at|where it is at|where it's at|where its at|where is it right now|where it is right now|where are we at|where we are at|what step is it on)\b/.test(normalized)
    || /\b(check on it|check on that|check on the task|check on the agent|check on codex)\b/.test(normalized)
    || /\b(why is it taking|why is this taking|why so long|why did it stop|why it stopped)\b/.test(normalized)
    || /^why\b.*\bstuck\b/.test(normalized);
}

function isDelegatedTaskCancellationRequest(text: string) {
  const normalized = normalizeRealtimeIntent(text);
  if (!normalized) return false;
  return /\b(cancel|stop|abort|end|kill)\b.{0,30}\b(task|job|work|run|agent|codex|claude)\b/.test(normalized)
    || /\b(task|job|work|run|agent|codex|claude)\b.{0,30}\b(cancel|stop|abort|end|kill)\b/.test(normalized);
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

  const actionPattern = /\b(add|fix|change|update|remove|delete|create|make|implement|wire|connect|hook|run|test|check|inspect|search|find|open|read|review|explain|summarize|debug|look|turn|enable|disable|install|start|build|commit|push|deploy|rename|move|organize|clean|cleanup|sort|schedule|reschedule|plan|refactor|write|edit|patch|verify|compare|clone|pull)\b/;
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
  const clearAction = /\b(add|fix|change|update|remove|delete|create|make|implement|wire|connect|hook|run|test|debug|install|start|build|open|check|inspect|search|find|read|review|explain|summarize|organize|clean|cleanup|sort|schedule|reschedule|plan)\b/.test(normalized);
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

function isBackendProgressMessage(text: string) {
  const trimmed = String(text || "").trim();
  if (!trimmed) return false;
  const normalized = trimmed.toLowerCase();
  return normalized.startsWith("[backend]")
    || normalized.startsWith("[codex progress]")
    || normalized.startsWith("[codex status]")
    || normalized.startsWith("[agent progress]")
    || normalized.startsWith("[agent status]");
}

function isRealtimeControlTool(name: string) {
  return name === "wait_for_user" || name === "set_listening_mode";
}

function isAnswerBearingRealtimeTool(name: string) {
  if (!name || isRealtimeControlTool(name)) return false;
  return name === "background_agent"
    || name === "delegate_parallel_tasks"
    || name === "get_delegated_task_status"
    || name === "cancel_delegated_task"
    || name === "request_codex_image_generation"
    || name === "knowledge_personal_recall"
    || name.startsWith("knowledge_");
}

function realtimeFunctionCallName(item: JsonObject | undefined) {
  return stringValue(item?.name, item?.function_name, item?.tool_name);
}

function isAnswerBearingFunctionCallItem(item: JsonObject | undefined) {
  return item?.type === "function_call" && isAnswerBearingRealtimeTool(realtimeFunctionCallName(item));
}

function isCodexFinalResultMessage(text: string) {
  const normalized = String(text || "").trim().toLowerCase();
  return normalized.startsWith("[codex task finished]") || normalized.startsWith("[agent task finished]");
}

function extractRealtimeText(value: unknown): string {
  if (typeof value === "string") return value.trim();
  const object = jsonObject(value);
  if (!object) return "";
  const direct = stringValue(object.output, object.output_text, object.text, object.transcript, object.delta);
  if (direct) return direct;
  const nestedItem = extractRealtimeText(object.item);
  if (nestedItem) return nestedItem;
  const content = Array.isArray(object.content) ? object.content : [];
  return content
    .map((entry) => extractRealtimeText(entry))
    .filter(Boolean)
    .join(" ")
    .trim();
}

function appendHandoffText(existing: string, next: string) {
  const clean = String(next || "")
    .replace(/^\s*\[BACKEND\]\s*/i, "")
    .replace(/^\s*\[Codex progress\]\s*/i, "")
    .replace(/^\s*\[Codex status\]\s*/i, "")
    .trim();
  if (!clean) return existing;
  if (!existing.trim()) return clean;
  if (existing.includes(clean)) return existing;
  return `${existing.trim()}\n\n${clean}`;
}

function compactRealtimeStatusText(text: string, maxLength = 900) {
  const clean = String(text || "").replace(/\s+/g, " ").trim();
  if (clean.length <= maxLength) return clean;
  return `${clean.slice(0, Math.max(0, maxLength - 1)).trim()}…`;
}

function latestStatusLine(text: string) {
  return String(text || "")
    .split(/\n+/)
    .map((line) => line.trim())
    .filter(Boolean)
    .at(-1) || "";
}

function formatRealtimeElapsed(ms: number) {
  const totalSeconds = Math.max(0, Math.round(ms / 1000));
  if (totalSeconds < 5) return "a few seconds";
  if (totalSeconds < 60) return `${totalSeconds} seconds`;
  const totalMinutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  if (totalMinutes < 60) return seconds ? `${totalMinutes} min ${seconds} sec` : `${totalMinutes} min`;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return minutes ? `${hours} hr ${minutes} min` : `${hours} hr`;
}

function isBackgroundAgentFinishedOutput(text: string) {
  return /^background agent (finished|completed|failed)\b/i.test(String(text || "").trim());
}

function formatAgentResultForRealtime(output: string, agentLabel: string) {
  const label = agentLabel.trim() || "Agent";
  const cleanOutput = compactRealtimeStatusText(String(output || "").trim() || `${label} finished the task.`, 1_600);
  return [
    `Narrate this ${label} result to the user now.`,
    "Keep it short and natural, usually one or two sentences.",
    "Do not restate the user's question. Do not add extra commentary.",
    "Do not mention hidden tools or internal routing.",
    "",
    cleanOutput
  ].join("\n");
}

function delegatedTaskFunctionOutput(agentLabel: string) {
  const label = agentLabel.trim() || "Agent";
  return `${label} finished. The proxy will narrate the result separately.`;
}

function directSpeechInstructions(output: string, agentLabel: string) {
  const label = agentLabel.trim() || "OpenAssist";
  const cleanOutput = compactRealtimeStatusText(String(output || "").trim() || `${label} finished the task.`, 1_600);
  return [
    `Answer the user with this ${label} result now.`,
    "Keep it short and natural, usually one or two sentences.",
    "Do not restate the user's question. Do not add extra commentary.",
    "Do not mention hidden tools, internal routing, Spark, or source labels unless the result itself says to.",
    "Do not read markdown symbols, backticks, or brackets out loud.",
    "",
    cleanOutput
  ].join("\n");
}

function personalRecallAnswerFromResult(result: unknown) {
  const object = jsonObject(result);
  return stringValue(object?.spokenAnswer, object?.answer, object?.summary, object?.output, object?.text);
}

function personalRecallRunningDetail(argsOrPrompt?: JsonObject | string) {
  const prompt = typeof argsOrPrompt === "string"
    ? argsOrPrompt
    : stringValue(argsOrPrompt?.query, argsOrPrompt?.question, argsOrPrompt?.prompt, argsOrPrompt?.text);
  const normalized = normalizeRealtimeIntent(prompt);
  const wantsMemory = /\b(memory|memories|saved)\b/.test(normalized);
  const wantsChats = /\b(chat|chats|conversation|conversations|thread|threads|session|sessions|transcript|codex|claude|spark|gemini|recent|latest|yesterday|today)\b/.test(normalized);
  if (wantsMemory && wantsChats) return "Checking memory and saved conversations.";
  if (wantsChats) return "Checking saved conversations.";
  if (wantsMemory) return "Checking memory.";
  return "Checking saved context.";
}

function isFailedPersonalRecallResult(result: unknown) {
  const object = jsonObject(result);
  return !!object && object.ok === false;
}

function knowledgeCompletionDetail(name: string, result: unknown) {
  if (name === "knowledge_personal_recall") {
    return personalRecallAnswerFromResult(result) || "Completed personal recall.";
  }
  return `Completed ${name.replace(/^knowledge_/, "").replace(/_/g, " ")}.`;
}

function contextualizeRealtimeDelegationPrompt(prompt: string, lastDelegationPrompt: string) {
  const repairedPrompt = repairRealtimeDelegationText(prompt);
  const normalizedPrompt = normalizeRealtimeIntent(repairedPrompt);
  const prior = lastDelegationPrompt.trim();
  if (!prior || !isVagueRealtimeFollowupTask(normalizedPrompt)) return repairedPrompt;
  return [
    "Follow-up to the previous delegated task:",
    prior,
    "",
    "New user request:",
    repairedPrompt
  ].join("\n");
}

type RealtimeDelegationOptions = {
  blockRealtimeKnowledgeTasks?: boolean;
  recentKnowledgePrompt?: string;
};

function shouldUseRecentKnowledgeContext(prompt: string, recentKnowledgePrompt: string) {
  if (!recentKnowledgePrompt.trim()) return false;
  const normalized = normalizeRealtimeIntent(prompt);
  const asksForAnotherItem = /\b(add|create|put|schedule|move|update|remove)\b/.test(normalized)
    && /\b(another|one|also|too|as well|next)\b/.test(normalized);
  if (!asksForAnotherItem) return false;
  // An explicit file, workflow, browser, or command request really belongs to
  // an agent. A lone speech-to-text word such as "node" does not override the
  // immediately preceding reminder or planner request.
  return !/\b(workflow|n8n|code|codebase|repo|repository|file|folder|terminal|cli|browser|website|api|server|logs?)\b/.test(normalized);
}

function decideRealtimeDelegation(
  prompt: string,
  hasActiveHandoff: boolean,
  lastDelegationPrompt = "",
  options: RealtimeDelegationOptions = {}
): DelegationDecision {
  const knowledgeContext = shouldUseRecentKnowledgeContext(prompt, options.recentKnowledgePrompt || "")
    ? options.recentKnowledgePrompt?.trim() || ""
    : "";
  const repairedPrompt = knowledgeContext
    ? [
      "Follow-up to the previous OpenAssist planner, note, or reminder request:",
      knowledgeContext,
      "",
      "New user request:",
      repairRealtimeDelegationText(prompt)
    ].join("\n")
    : contextualizeRealtimeDelegationPrompt(prompt, lastDelegationPrompt);
  const normalizedPrompt = normalizeRealtimeIntent(repairedPrompt);
	  const normalizedRawPrompt = normalizeRealtimeIntent(repairRealtimeDelegationText(prompt));
	  const blockRealtimeKnowledgeTasks = options.blockRealtimeKnowledgeTasks !== false;
	  const routeIntent = classifyVoiceRoute(prompt);
	  const recallRoute = conversationRecallRoute(normalizedRawPrompt) !== "none"
	    ? conversationRecallRoute(normalizedRawPrompt)
	    : conversationRecallRoute(normalizedPrompt);

  if (!normalizedPrompt) {
    return {
      allow: false,
      output: "No clear task was heard. Wait for the user.",
      createResponse: false,
      reason: "empty prompt"
    };
	  }

	  if (routeIntent.kind === "ignore") {
	    return {
	      allow: false,
	      output: "The user did not give a new task. Wait for the next clear request.",
	      createResponse: false,
	      reason: routeIntent.reason
	    };
	  }

	  if (recallRoute === "none" && isVagueRealtimeFollowupTask(normalizedRawPrompt) && !lastDelegationPrompt.trim()) {
    return {
      allow: false,
      output: "This follow-up is too vague without a previous delegated task. Ask one short clarification question.",
      createResponse: true,
      reason: "vague follow-up"
    };
  }

  if (isVagueRealtimeHelpRequest(normalizedRawPrompt) || isVagueRealtimeHelpRequest(normalizedPrompt)) {
    return {
      allow: false,
      output: "The user is asking for help but has not given a task yet. Ask one short question, like: Sure, what do you need help with?",
      createResponse: true,
      reason: "vague help request"
    };
  }

	  if (isShortAcknowledgement(normalizedPrompt)) {
	    return {
      allow: false,
      output: "The user only acknowledged. Do not start the agent; wait for the next clear request.",
      createResponse: false,
      reason: "short acknowledgement"
    };
	  }

	  if (routeIntent.kind === "control" || isStopOrDismissal(normalizedPrompt)) {
	    return {
      allow: false,
      output: "The user dismissed the task. Do not start the agent.",
      createResponse: true,
      reason: "dismissal"
    };
  }

  const asksWhereActiveTaskIs = /\bcheck\b.{0,40}\b(where|status|progress)\b/.test(normalizedRawPrompt)
    || /\bwhere\b.{0,30}\b(it|that|task|agent|we)\b.{0,30}\b(at|now|status|progress)\b/.test(normalizedRawPrompt);
  const requiresFreshExecution = requiresAgentExecution(normalizedRawPrompt);
  if (!requiresFreshExecution && (asksWhereActiveTaskIs || isDelegatedStatusQuestion(normalizedRawPrompt) || isDelegatedStatusQuestion(normalizedPrompt))) {
    return {
      allow: false,
      output: hasActiveHandoff
        ? "The user is asking for the current delegated task status. Call get_delegated_task_status and answer from that result. Do not start a new background_agent task."
        : "This is a status follow-up. Answer from the recent conversation or completed task state. Do not start a new background_agent task.",
      createResponse: true,
      reason: "delegated status question"
    };
  }

  if (recallRoute !== "none") {
    if (recallRoute === "current") {
      return {
        allow: false,
        output: currentConversationRecallText(),
        createResponse: true,
        reason: "current conversation recall"
      };
    }
    if (recallRoute === "clarify") {
      return {
        allow: false,
        output: recallScopeClarificationText(),
        createResponse: true,
        reason: "ambiguous recall scope"
      };
    }
    return {
      allow: false,
      output: "This is a personal recall question. Use knowledge_personal_recall if knowledge tools are available. Do not start background_agent or repeat the task unless the user explicitly asks to run it again.",
      createResponse: true,
      reason: "conversation recall"
    };
  }

  if (looksLikeMissingReferenceFollowup(normalizedRawPrompt) || looksLikeMissingReferenceFollowup(normalizedPrompt)) {
    return {
      allow: false,
      output: "There is not enough context to identify the exact item. Ask one short clarification question and do not start a background task yet.",
      createResponse: true,
      reason: "missing reference context"
    };
  }

  if (lastDelegationPrompt.trim() && looksLikeExternalLookupTask(normalizedRawPrompt)) {
    return {
      allow: true,
      prompt: repairedPrompt,
      normalizedPrompt
    };
  }

  const isNoteOrganizeTask = looksLikeNoteOrganizeTask(normalizedRawPrompt) || looksLikeNoteOrganizeTask(normalizedPrompt);
  if (blockRealtimeKnowledgeTasks && !isNoteOrganizeTask && (looksLikeRealtimeKnowledgeTask(normalizedRawPrompt) || looksLikeRealtimeKnowledgeTask(normalizedPrompt))) {
    return {
      allow: false,
      output: "This is an OpenAssist planner, backlog, notes, or journal request. Use the matching OpenAssist knowledge tool directly. Do not start background_agent.",
      createResponse: true,
      reason: "realtime knowledge tool"
    };
  }

  if (hasActiveHandoff && shouldIgnoreBusyDelegationPrompt(repairedPrompt)) {
    return {
      allow: false,
      output: "The agent is already working, and this was not a new clear task. Wait for the user.",
      createResponse: false,
      reason: "busy non-task"
    };
  }

  if (isCasualRealtimeQuestion(normalizedPrompt)) {
    return {
      allow: false,
      output: "This is a casual voice question. Answer it directly without starting the agent.",
      createResponse: true,
      reason: "casual question"
    };
  }

  if (looksIncompleteForDelegation(repairedPrompt)) {
    return {
      allow: false,
      output: "The user may still be speaking. Wait for the complete request.",
      createResponse: false,
      reason: "incomplete request"
    };
  }

  if (!isNoteOrganizeTask && !looksLikeCodexTask(normalizedPrompt)) {
    return {
      allow: false,
      output: "This is not a clear delegated task. Answer directly if helpful, otherwise wait.",
      createResponse: true,
      reason: "not a codex task"
    };
  }

  return { allow: true, prompt: repairedPrompt, normalizedPrompt };
}

type RealtimeParallelTask = { prompt: string; provider?: string; project?: string };

type ParallelDelegationRoute =
  | { action: "proceed"; tasks: RealtimeParallelTask[] }
  | { action: "image"; prompt: string; reason: string }
  | { action: "recall"; query: string; reason: string }
  | { action: "output"; output: string; reason: string };

// delegate_parallel_tasks must not be an unguarded side door around the
// background_agent router: a trigger-happy voice model (Gemini Live especially)
// can wrap a memory question or a lone vague task in it. A single task goes
// through the same router background_agent uses; a multi-task call where every
// entry is really a recall question gets rerouted to personal recall.
function routeParallelDelegation(
  tasks: RealtimeParallelTask[],
  hasActiveHandoff: boolean,
  lastDelegationPrompt = "",
  options: RealtimeDelegationOptions = {}
): ParallelDelegationRoute {
  if (!tasks.length) {
    return { action: "output", output: "No tasks were provided. Ask the user what to run.", reason: "no tasks" };
  }
  if (tasks.length === 1) {
    const prompt = tasks[0].prompt;
    if (realtimePromptWantsImageGeneration(prompt)) {
      return { action: "image", prompt, reason: "image generation" };
    }
    const decision = decideRealtimeDelegation(prompt, hasActiveHandoff, lastDelegationPrompt, options);
    if (decision.allow) {
      return { action: "proceed", tasks: [{ ...tasks[0], prompt: decision.prompt || prompt }] };
    }
    if (decision.reason === "conversation recall") {
      return { action: "recall", query: prompt, reason: decision.reason };
    }
    return {
      action: "output",
      output: decision.output || "This is not a clear delegated task. Answer directly if helpful, otherwise wait.",
      reason: decision.reason || "blocked"
    };
  }
  const routes = tasks.map((task) => conversationRecallRoute(task.prompt));
  if (routes.every((route) => route !== "none")) {
    if (routes.includes("clarify")) {
      return { action: "output", output: recallScopeClarificationText(), reason: "ambiguous recall scope" };
    }
    if (routes.every((route) => route === "current")) {
      return { action: "output", output: currentConversationRecallText(), reason: "current conversation recall" };
    }
    return { action: "recall", query: tasks.map((task) => task.prompt).join("\n"), reason: "conversation recall" };
  }
  return { action: "proceed", tasks };
}

function isHighConfidenceRealtimeDelegation(prompt: string, _source: RealtimeDelegationRouteSource) {
  const repairedPrompt = repairRealtimeDelegationText(prompt);
  const normalized = normalizeRealtimeIntent(repairedPrompt);
  if (!normalized) return false;
  if (isConversationRecallQuestion(normalized) || isCasualRealtimeQuestion(normalized) || isVagueRealtimeHelpRequest(normalized)) return false;
  if (looksLikeMissingReferenceFollowup(normalized)) return false;
  if (looksLikeNoteOrganizeTask(normalized)) return true;
  if (requiresAgentExecution(normalized)) return true;
  if (looksLikeRealtimeKnowledgeTask(normalized)) return false;
  if (looksIncompleteForDelegation(repairedPrompt)) return false;
  const actionPattern = /\b(add|fix|change|update|remove|delete|create|make|implement|wire|connect|hook|run|test|debug|install|start|build|open|check|inspect|search|find|read|review|summarize|organize|clean|cleanup|sort|schedule|reschedule|plan|write|edit|patch|verify|compare|clone|pull)\b/;
  const toolContextPattern = /\b(codebase|repo|repository|file|folder|downloads|terminal|browser|chrome|brave|website|webpage|app|notes|today|tomorrow|yesterday|next week|this week|task|tasks|item|items|todo|to-do|reminder|backlog|planner|calendar|computer|desktop|screenshot|image|project|settings|config|server|build|test|bug|error)\b/;
  return actionPattern.test(normalized) && toolContextPattern.test(normalized);
}

function routerConfidence(value: unknown) {
  const number = Number(value);
  if (!Number.isFinite(number)) return 0;
  return Math.max(0, Math.min(1, number));
}

function routerDecisionName(value: unknown): RealtimeDelegationRouteDecision {
  const decision = String(value || "").trim().toLowerCase();
  return ["delegate", "answer_direct", "clarify", "ignore", "control"].includes(decision)
    ? decision as RealtimeDelegationRouteDecision
    : "answer_direct";
}

function routerFallbackDecision(source: RealtimeDelegationRouteSource, reason: string): DelegationDecision {
  if (source === "auto_transcript") {
    return {
      allow: false,
      output: "The voice router could not confirm this was a task. Wait for a clearer request.",
      createResponse: false,
      reason
    };
  }
  return {
    allow: false,
    output: "This may not need the background agent. Answer directly from the conversation if possible, or ask one short clarification question.",
    createResponse: true,
    reason
  };
}

function openAIRealtimeURL(model: string) {
  const url = new URL("wss://api.openai.com/v1/realtime");
  url.searchParams.set("model", model.trim() || defaultRealtimeModel);
  return url.toString();
}

function isGemini31LiveModel(model: string) {
  return /gemini-3\.1.*live/i.test(model);
}

function localPlannerDayID(date = new Date()) {
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function realtimeLocalTimeInstruction() {
  const now = new Date();
  const dayID = localPlannerDayID(now);
  const display = new Intl.DateTimeFormat(undefined, {
    weekday: "long",
    year: "numeric",
    month: "long",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short"
  }).format(now);
  return [
    "# Current Local Time",
    `The user's local date and time at session start is ${display}.`,
    `The local planner day id for "today" is ${dayID}.`,
    `If the user says "today", use ${dayID} unless they explicitly ask for another date.`,
    "Do not use UTC or an ISO timestamp to decide Today, tomorrow, or weekdays."
  ].join("\n");
}

type RealtimeVoiceToolSpec = {
  name: string;
  description: string;
  parameters: JsonObject;
  geminiBehavior?: "NON_BLOCKING" | "BLOCKING";
};

const realtimeVoiceControlToolSpecs: RealtimeVoiceToolSpec[] = [
  {
    name: "wait_for_user",
    description: "Call this when the latest audio should not receive a spoken response.",
    parameters: { type: "object", properties: {}, required: [], additionalProperties: false }
  },
  {
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
  }
];

function realtimeBackgroundAgentToolSpec(agentLabel: string): RealtimeVoiceToolSpec {
  return {
    name: "background_agent",
    description: `Hand coding, repository, terminal, browser, computer, or app tasks to ${agentLabel}. Can be called again while a previous task is still running — new clear tasks run side by side and each result is spoken when it finishes.`,
    geminiBehavior: "NON_BLOCKING",
    parameters: {
      type: "object",
      properties: {
        prompt: { type: "string", description: `The exact task the user wants ${agentLabel} to perform.` },
        project: { type: "string", description: "Optional existing OpenAssist project name or project ID for the new agent thread. If a new destination is needed, call knowledge_create_project first and pass its returned projectID here. Project folders cannot directly contain threads." }
      },
      required: ["prompt"],
      additionalProperties: false
    }
  };
}

function delegatedTaskStartedText(_agentLabel: string) {
  return "I'm checking that now. I'll let you know as soon as I have the answer.";
}

const realtimeCodexImageGenerationToolSpec: RealtimeVoiceToolSpec = {
  name: "request_codex_image_generation",
  description: "Create or edit an image through Codex as the hidden OpenAssist image worker. Use this for image, photo, poster, banner, logo, mockup, or graphic generation.",
  geminiBehavior: "BLOCKING",
  parameters: {
    type: "object",
    properties: {
      prompt: { type: "string", description: "The image request to send to Codex." },
      mode: { type: "string", enum: ["auto", "new_image", "edit_reference"] },
      referenceArtifactIds: {
        type: "array",
        items: { type: "string" },
        description: "Optional image artifact IDs or paths from this thread."
      },
      referenceImagePaths: {
        type: "array",
        items: { type: "string" },
        description: "Optional local image paths to use as references."
      },
      useLatestImage: { type: "boolean", description: "Use the latest image artifact in this thread as a reference." }
    },
    required: ["prompt"],
    additionalProperties: false
  }
};

function realtimeParallelDelegationToolSpec(agentLabel: string): RealtimeVoiceToolSpec {
  return {
    name: "delegate_parallel_tasks",
    description:
      `Hand TWO OR MORE separate tasks to ${agentLabel} so they run AT THE SAME TIME, each in its own chat. ` +
      "Use this only when the user clearly asks for multiple distinct tasks at once (for example \"do A and B at the same time\"). " +
      "For a single task use background_agent instead. " +
      "Split the user's request into one entry per task. Set provider only if the user names a model for that task (for example claude, codex, copilot, antigravity, ollama); otherwise leave it empty to use the current assistant. " +
      "Set project only if the user names a folder or project for that task; otherwise leave it empty to use the current project.",
    geminiBehavior: "NON_BLOCKING",
    parameters: {
      type: "object",
      properties: {
        tasks: {
          type: "array",
          description: "The list of separate tasks to run in parallel. Provide at least two.",
          minItems: 2,
          items: {
            type: "object",
            properties: {
              prompt: { type: "string", description: "The exact task to perform." },
              provider: {
                type: "string",
                description: "Optional model/provider for this task: claude, codex, copilot, antigravity, or ollama. Leave empty to use the current assistant."
              },
              project: {
                type: "string",
                description: "Optional folder or project name for this task. Leave empty to use the current project."
              }
            },
            required: ["prompt"],
            additionalProperties: false
          }
        }
      },
      required: ["tasks"],
      additionalProperties: false
    }
  };
}

function realtimeDelegatedStatusToolSpec(agentLabel: string): RealtimeVoiceToolSpec {
  const label = agentLabel.trim() || "Agent";
  return {
    name: "get_delegated_task_status",
    description: `Get the live status of the current delegated ${label} task, including the latest progress and active tool if available.`,
    geminiBehavior: "BLOCKING",
    parameters: { type: "object", properties: {}, required: [], additionalProperties: false }
  };
}

function realtimeDelegatedCancelToolSpec(agentLabel: string): RealtimeVoiceToolSpec {
  const label = agentLabel.trim() || "Agent";
  return {
    name: "cancel_delegated_task",
    description: `Cancel the newest running delegated ${label} task. Use this only when the user clearly asks to cancel agent work, not when they only want Live Voice or the microphone stopped.`,
    geminiBehavior: "BLOCKING",
    parameters: { type: "object", properties: {}, required: [], additionalProperties: false }
  };
}

const realtimeScopeTagsSchema: JsonObject = {
  type: "array",
  items: {
    type: "object",
    properties: {
      marker: { type: "string" },
      label: { type: "string" },
      type: { type: "string" },
      id: { type: "string" },
      unresolved: { type: "boolean" }
    },
    additionalProperties: true
  }
};

const realtimeDailyStepsSchema: JsonObject = {
  type: "array",
  items: {
    type: "object",
    properties: {
      text: { type: "string" },
      checked: { type: "boolean" }
    },
    required: ["text"],
    additionalProperties: true
  }
};

const realtimeDailyLinksSchema: JsonObject = {
  type: "array",
  items: {
    type: "object",
    properties: {
      id: { type: "string" },
      title: { type: "string" },
      kind: { type: "string" },
      projectID: { type: "string" },
      noteID: { type: "string" }
    },
    additionalProperties: true
  }
};

const realtimeVoiceKnowledgeToolSpecs: RealtimeVoiceToolSpec[] = [
  {
    name: "knowledge_personal_recall",
    description: "Fast personal recall lane using hidden Spark. Use only when the user clearly asks about saved memory, previous chats, past work, earlier decisions/plans, or what Codex/Claude/Spark/Gemini previously said/found. Do not use it for new/current work, online/web/public-data checks, browsing, files, planner edits, or vague 'check it' follow-ups. The user does not need to say 'check Codex thread' when the intent is clearly recall.",
    parameters: {
      type: "object",
      properties: {
        query: { type: "string", description: "The user's exact memory or past-work question." },
        projectID: { type: "string", description: "Exact OpenAssist project ID when the user names or selects a project." },
        projectName: { type: "string", description: "Exact OpenAssist project name when the user names a project." },
        threadID: { type: "string", description: "Exact conversation ID only when the user asks about one specific conversation." },
        sourceGroup: { type: "string", enum: ["codex", "claude"], description: "Limit recall to one agent only when the user names it." },
        fromDate: { type: "string" },
        toDate: { type: "string" }
      },
      required: ["query"],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_search",
    description: "Search the user's OpenAssist notes, Today planner, backlog, and daily journal.",
    parameters: {
      type: "object",
      properties: {
        query: { type: "string" },
        source: { type: "string", enum: ["project_note", "thread_note", "planner_day", "journal_day"] },
        limit: { type: "number" }
      },
      required: ["query"],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_search_everything",
    description: "Search across the user's OpenAssist chat threads, realtime turns, notes, planner days, backlog, approvals, and artifact metadata. Use this for memory/history questions like 'when did we', 'where did I mention', 'what did we decide', or 'find the earlier discussion'. Returns small snippets only.",
    parameters: {
      type: "object",
      properties: {
        query: { type: "string" },
        sourceTypes: {
          type: "array",
          items: {
            type: "string",
            enum: [
              "project_note",
              "thread_note",
              "planner_day",
              "journal_day",
              "thread_message",
              "thread_activity",
              "realtime_delegation",
              "backlog_item",
              "knowledge_request",
              "artifact",
              "codex_memory",
              "codex_session",
              "claude_memory",
              "claude_task",
              "claude_session"
            ]
          }
        },
        fromDate: { type: "string" },
        toDate: { type: "string" },
        limit: { type: "number" }
      },
      required: ["query"],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_read_search_result",
    description: "Read one Search Everything result by id with a small nearby thread window when available. Use after knowledge_search_everything.",
    parameters: {
      type: "object",
      properties: {
        resultID: { type: "string" },
        window: { type: "number" }
      },
      required: ["resultID"],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_read",
    description: "Read the full markdown content of one note or item by its itemID. Use the id returned by knowledge_search. Required before organizing a note: you must read the full content first so you can compose exact replacement markdown.",
    parameters: {
      type: "object",
      properties: {
        itemID: { type: "string" }
      },
      required: ["itemID"],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_read_today",
    description: "Read today's planner day, or a specific date if provided.",
    parameters: {
      type: "object",
      properties: { dayID: { type: "string" }, date: { type: "string" } },
      required: [],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_daily_items",
    description: "List structured Today/daily items for a date, including category, list, section, tags, details, steps, and linked notes. When there are no structured items, also returns freeTextItems and noteMarkdown from the planner day so free-text notes are visible.",
    parameters: {
      type: "object",
      properties: { dayID: { type: "string" }, date: { type: "string" } },
      required: [],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_backlog_items",
    description: "List unscheduled backlog items and follow-ups that do not have a planner date yet.",
    parameters: { type: "object", properties: {}, required: [], additionalProperties: false }
  },
  {
    name: "knowledge_planner_categories",
    description: "List planner categories and available Planner Lists. Call this before assigning category/list when the user has not named an exact category or list.",
    parameters: { type: "object", properties: {}, required: [], additionalProperties: false }
  },
  {
    name: "knowledge_planner_lists",
    description: "List Planner Lists. These are the same buckets used across Planner, Backlog, Notes, and Threads; planner-created Lists also appear as Thread Projects.",
    parameters: { type: "object", properties: {}, required: [], additionalProperties: false }
  },
  {
    name: "knowledge_list_projects",
    description: "List the user's OpenAssist sidebar Projects and project folders, including their IDs and parent folders. Use this before suggesting or creating a destination for a new note, thread, or delegated task.",
    parameters: { type: "object", properties: {}, required: [], additionalProperties: false }
  },
  {
    name: "knowledge_create_project",
    description: "Create an OpenAssist sidebar project or project folder after the user explicitly asks for it or confirms your suggestion. A folder only groups projects and cannot directly contain notes or chats. To create a project inside a folder, set kind=project and provide parentFolderName or parentFolderID. Set createParentFolderIfMissing only when the user also approved creating that folder. The result returns the projectID to use for the next note or task call.",
    parameters: {
      type: "object",
      properties: {
        name: { type: "string", description: "Name of the new project or folder." },
        kind: { type: "string", enum: ["project", "folder"] },
        parentFolderID: { type: "string", description: "Existing parent folder ID for a new project." },
        parentFolderName: { type: "string", description: "Existing or approved new parent folder name for a new project." },
        createParentFolderIfMissing: { type: "boolean", description: "Create parentFolderName when it does not exist. Use only after explicit user approval." },
        confirmed: { type: "boolean", description: "True only when the user explicitly requested this creation or confirmed the assistant's suggestion." }
      },
      required: ["name", "kind", "confirmed"],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_plan_write",
    description: "Dry-run OpenAssist's backend write router before mutating planner or notes. Use before ambiguous adds/edits, mixed task/reference requests, or anything that might need a new List or note. Returns intent, target, confidence, approval requirement, reason, and the recommended tool call.",
    parameters: {
      type: "object",
      properties: {
        action: { type: "string" },
        userRequest: { type: "string" },
        title: { type: "string" },
        text: { type: "string" },
        detailsMarkdown: { type: "string" },
        dayID: { type: "string" },
        when: { type: "string" },
        listName: { type: "string" },
        listID: { type: "string" },
        noteTitle: { type: "string" },
        noteItemID: { type: "string" },
        itemID: { type: "string" },
        query: { type: "string" }
      },
      required: [],
      additionalProperties: true
    }
  },
  {
    name: "knowledge_quick_add_task",
    description: "FAST PATH: add one OpenAssist planner task in one call. Use for simple task/reminder/to-do captures. If `when` is today, tomorrow, a weekday, or YYYY-MM-DD, adds to that planner day; if omitted/backlog/later, adds to Backlog. Planner tasks should be short action pointers; put detailed specs, dimensions, reference facts, and long checklists in a linked note, then pass noteItemID/noteTitle/links. Set listName/category/section/tags only when clear; do not infer a List from old note content.",
    parameters: {
      type: "object",
      properties: {
        title: { type: "string" },
        when: { type: "string", description: "today, tomorrow, backlog, later, weekday, or YYYY-MM-DD. Omit for Backlog." },
        listID: { type: "string" },
        listName: { type: "string" },
        projectID: { type: "string" },
        category: { type: "string" },
        section: { type: "string" },
        tags: { type: "array", items: { type: "string" } },
        reminderAt: { type: "string", description: "ISO datetime for an OpenAssist planner local notification." },
        reminderTimezone: { type: "string", description: "IANA timezone for reminderAt, if known." },
        dueAt: { type: "string", description: "Alias for reminderAt." },
        notifyAt: { type: "string", description: "Alias for reminderAt." },
        details: { type: "string", description: "Short action context only. Do not paste full reference notes, specs, dimensions, or long checklists here; put them in a note and link it." },
        detailsMode: { type: "string", enum: ["replace", "append"] },
        replaceDetails: { type: "boolean" },
        links: realtimeDailyLinksSchema,
        noteItemID: { type: "string", description: "Knowledge item id for a note to link to this task." },
        noteTitle: { type: "string", description: "Existing note title to link. Do not also put this note title in listName unless the user explicitly named that planner List." },
        referenceNoteTitle: { type: "string" }
      },
      required: ["title"],
      additionalProperties: true
    }
  },
  {
    name: "knowledge_quick_save_note",
    description: "FAST PATH: save one piece of reference information or detailed checklist to an existing OpenAssist List/thread note. Use for facts, links, specs, dimensions, contacts, prices, fit checks, and other non-task information. Applies immediately only when the target note already exists; missing notes create a pending approval preview.",
    parameters: {
      type: "object",
      properties: {
        text: { type: "string" },
        title: { type: "string" },
        listID: { type: "string" },
        listName: { type: "string" },
        projectID: { type: "string" },
        threadID: { type: "string" },
        itemID: { type: "string", description: "Exact existing note itemID. Always use this when the live context names the active source note." },
        noteTitle: { type: "string", description: "Existing note title. Prefer itemID when available." },
        section: { type: "string" }
      },
      required: ["text"],
      additionalProperties: true
    }
  },
  {
    name: "knowledge_list_approvals",
    description: "List OpenAssist approval previews that are pending, applied, or rejected. Use when the user asks what needs approval or wants to review pending edits without opening the app.",
    parameters: {
      type: "object",
      properties: {
        status: { type: "string", enum: ["pending", "applied", "rejected"] },
        limit: { type: "number" }
      },
      required: [],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_apply_approval",
    description: "Apply one pending OpenAssist approval preview by requestID after the user confirms it.",
    parameters: {
      type: "object",
      properties: {
        requestID: { type: "string" }
      },
      required: ["requestID"],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_reject_approval",
    description: "Reject one pending OpenAssist approval preview by requestID after the user declines it.",
    parameters: {
      type: "object",
      properties: {
        requestID: { type: "string" }
      },
      required: ["requestID"],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_quick_read",
    description: "FAST PATH: read a common OpenAssist target such as today, tomorrow, backlog, open tasks, or a short search query.",
    parameters: {
      type: "object",
      properties: {
        target: { type: "string" },
        limit: { type: "number" }
      },
      required: ["target"],
      additionalProperties: true
    }
  },
  {
    name: "knowledge_connector_status",
    description: "List configured connector accounts, enabled services, gws status, and Review Inbox count. Use before syncing connector data.",
    parameters: { type: "object", properties: {}, required: [], additionalProperties: false }
  },
  {
    name: "knowledge_connector_sync_gmail",
    description: "Safely search Gmail for task/follow-up candidates using the user's intent, then place metadata-only candidates in Review Inbox. OpenAssist builds strict Gmail queries internally; do not pass raw broad Gmail searches. Does not fetch full email body and does not send, archive, delete, or label mail.",
    parameters: {
      type: "object",
      properties: {
        accountID: { type: "string" },
        accountLabel: { type: "string" },
        userIntent: {
          type: "string",
          description: "The user's natural-language request, for example: find email tasks for today, follow-ups from clients, or invoices I need to act on."
        },
        timeframeDays: {
          type: "number",
          description: "Optional lookback window. Keep small; defaults to 7, today requests use about 2."
        },
        maxResults: {
          type: "number",
          description: "Optional per-query cap. Keep small; defaults to 8 and is capped by OpenAssist."
        }
      },
      required: [],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_connector_search_gmail",
    description: "Search Gmail metadata for a specific email or email type and return matching snippets directly. Use this when the user asks to find/show/search for a particular email. Do not sync Review Inbox for direct email search.",
    parameters: {
      type: "object",
      properties: {
        accountID: { type: "string" },
        accountLabel: { type: "string" },
        query: {
          type: "string",
          description: "Natural-language keywords or Gmail search syntax for the exact email being searched."
        },
        gmailQuery: {
          type: "string",
          description: "Optional exact Gmail query syntax when known. Keep narrow; do not use broad all-mail queries."
        },
        userIntent: {
          type: "string",
          description: "The user's exact request in natural language."
        },
        timeframeDays: {
          type: "number",
          description: "Optional lookback window. Defaults to 30 for direct search."
        },
        maxResults: {
          type: "number",
          description: "Optional result cap. Defaults to 10 and is capped by OpenAssist."
        }
      },
      required: ["query"],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_connector_search_messages",
    description: "Search local macOS Messages/iMessage text metadata for a specific person, word, appointment, or follow-up. Read-only. Use this when the user asks to check iMessage/Messages/texts.",
    parameters: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Specific person, phone/email, or keywords to search in Messages."
        },
        userIntent: {
          type: "string",
          description: "The user's exact request in natural language."
        },
        timeframeDays: {
          type: "number",
          description: "Optional lookback window. Defaults to 30."
        },
        maxResults: {
          type: "number",
          description: "Optional result cap. Defaults to 10 and is capped by OpenAssist."
        }
      },
      required: ["query"],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_apple_add_reminder",
    description: "Create a real Apple Reminders reminder on this Mac. Use only when the user explicitly asks for Apple Reminders or the Reminders app.",
    parameters: {
      type: "object",
      properties: {
        title: { type: "string" },
        notes: { type: "string" },
        dueDate: { type: "string" },
        calendar: { type: "string" },
        list: { type: "string" }
      },
      required: ["title"],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_apple_list_reminders",
    description: "List real Apple Reminders reminders on this Mac.",
    parameters: {
      type: "object",
      properties: {
        calendar: { type: "string" },
        dueBefore: { type: "string" },
        dueAfter: { type: "string" },
        includeCompleted: { type: "boolean" },
        limit: { type: "number" }
      },
      required: [],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_apple_complete_reminder",
    description: "Mark a real Apple Reminders reminder complete or incomplete by ID. List reminders first if you need the ID.",
    parameters: {
      type: "object",
      properties: {
        id: { type: "string" },
        completed: { type: "boolean" }
      },
      required: ["id"],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_apple_add_event",
    description: "Create a real Apple Calendar event on this Mac. Use only when the user explicitly asks for Apple Calendar or the Calendar app.",
    parameters: {
      type: "object",
      properties: {
        title: { type: "string" },
        startDate: { type: "string" },
        endDate: { type: "string" },
        isAllDay: { type: "boolean" },
        notes: { type: "string" },
        location: { type: "string" },
        calendar: { type: "string" }
      },
      required: ["title", "startDate"],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_apple_list_events",
    description: "List real Apple Calendar events on this Mac for a date range.",
    parameters: {
      type: "object",
      properties: {
        startDate: { type: "string" },
        endDate: { type: "string" },
        calendar: { type: "string" },
        limit: { type: "number" }
      },
      required: [],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_read_journal",
    description: "Read the daily journal section for today, or a specific date if provided.",
    parameters: {
      type: "object",
      properties: { dayID: { type: "string" }, date: { type: "string" } },
      required: [],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_open_tasks",
    description: "List unfinished tasks from OpenAssist notes and planner days.",
    parameters: {
      type: "object",
      properties: { limit: { type: "number" } },
      required: [],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_request_reference",
    description: "Append small reference information (dimensions, links, specs, prices, addresses, contact info, model numbers, detailed checklists, or 'save this' facts) to an existing canonical note for a Planner List or thread. This is for additive information, fit checks, measurements, and checklist work, not top-level planner actions and not full-note reorganization. New Lists and new notes are never created silently; missing notes create a pending approval preview. For cleanup/restructure/rewrite, use knowledge_request_organize.",
    parameters: {
      type: "object",
      properties: {
        title: { type: "string", description: "Short reference title or topic, such as TV dimensions." },
        text: { type: "string", description: "Reference text to save." },
        content: { type: "string" },
        detailsMarkdown: { type: "string", description: "Detailed reference lines, dimensions, specs, or checklist items to append." },
        listID: { type: "string" },
        listName: { type: "string" },
        projectID: { type: "string" },
        threadID: { type: "string" },
        itemID: { type: "string", description: "Existing project_note or thread_note itemID when known." },
        noteTitle: { type: "string", description: "Optional canonical note title override. Defaults to the List name or Reference." },
        section: { type: "string", description: "Section/topic inside the note, such as TV, Fridge, Appliances, Contacts, Links, or Measurements." },
        goal: { type: "string" }
      },
      required: [],
      additionalProperties: true
    }
  },
  {
    name: "knowledge_request_daily_item",
    description: "Add one structured task to a planner DAY (Today or a specific date). Use this ONLY when the user named a date or said today, tonight, tomorrow, or a weekday. If the user did not pick a date, use knowledge_request_backlog_item instead. Planner tasks should be short: what to do, where to do it, and a few high-level steps. Put detailed specs, dimensions, reference facts, and long checklists in a linked note, then pass noteItemID/noteTitle/links. Use Category -> List -> Section -> Item. Adding is applied immediately.",
    parameters: {
      type: "object",
      properties: {
        dayID: { type: "string" },
        title: { type: "string" },
        listID: { type: "string" },
        listName: { type: "string" },
        projectID: { type: "string" },
        folderID: { type: "string" },
        area: { type: "string", description: "Optional planner category name such as Work, Personal, Business, Home, or another user-created category." },
        category: { type: "string", description: "Alias for area/category." },
        section: { type: "string", description: "Optional grouping inside the selected List, such as Food, Household, This week, or Follow-ups." },
        tags: { type: "array", items: { type: "string" }, description: "Optional cross-category filter tags, such as Shopping, Errands, Waiting For, or Follow-up." },
        scopeTags: realtimeScopeTagsSchema,
        reminderAt: { type: "string", description: "ISO datetime for an OpenAssist planner local notification." },
        reminderTimezone: { type: "string", description: "IANA timezone for reminderAt, if known." },
        dueAt: { type: "string", description: "Alias for reminderAt." },
        notifyAt: { type: "string", description: "Alias for reminderAt." },
        detailsMarkdown: { type: "string", description: "Short action context only. Do not put detailed specs, dimensions, copied note bodies, or long checklists here; link a note instead." },
        detailsMode: { type: "string", enum: ["replace", "append"] },
        replaceDetails: { type: "boolean" },
        steps: { ...realtimeDailyStepsSchema, description: "High-level planner steps only; detailed checklists belong in the linked note." },
        links: { ...realtimeDailyLinksSchema, description: "Notes that hold details, dimensions, reference facts, or checklists." },
        noteItemID: { type: "string" },
        noteTitle: { type: "string" },
        goal: { type: "string" }
      },
      required: ["title"],
      additionalProperties: true
    }
  },
  {
    name: "knowledge_update_daily_item",
    description: "Update an existing planner task by itemID or current task text. Use this for rename, category/list/section/tag/details/date changes. It replaces the matched old item instead of adding a duplicate. Use area/category for a Category such as Work; use listID/listName only for a real @List. If the user says an item is not for the current List and only gives a Category, set clearList=true. Keep task details short; move detailed specs/dimensions/checklists into a linked note and attach it with noteItemID/noteTitle/links. Call knowledge_daily_items first if unsure of the exact text.",
    parameters: {
      type: "object",
      properties: {
        dayID: { type: "string" },
        itemID: { type: "string" },
        query: { type: "string", description: "Current task text to match when itemID is unknown." },
        oldTitle: { type: "string", description: "Alias for query/current task text." },
        title: { type: "string", description: "Current task text if no query is supplied." },
        newTitle: { type: "string", description: "Replacement title. Omit to keep the existing title." },
        targetDayID: { type: "string", description: "Optional new planner day when moving the item." },
        listID: { type: "string" },
        listName: { type: "string" },
        projectID: { type: "string" },
        folderID: { type: "string" },
        clearList: { type: "boolean", description: "True to remove the existing @List/project from the task while keeping/setting its category." },
        area: { type: "string", description: "Optional planner category name such as Work, Personal, Business, Home, or another user-created category." },
        category: { type: "string", description: "Alias for area/category." },
        section: { type: "string", description: "Optional grouping inside the selected List." },
        tags: { type: "array", items: { type: "string" }, description: "Optional replacement free-form tags." },
        scopeTags: realtimeScopeTagsSchema,
        reminderAt: { type: "string", description: "ISO datetime for the OpenAssist planner local notification. Pass empty/null to clear when supported." },
        reminderTimezone: { type: "string", description: "IANA timezone for reminderAt, if known." },
        dueAt: { type: "string", description: "Alias for reminderAt." },
        notifyAt: { type: "string", description: "Alias for reminderAt." },
        detailsMarkdown: { type: "string", description: "Short replacement action context only. Do not paste detailed note content here; put it in a linked note." },
        detailsMode: { type: "string", enum: ["replace", "append"] },
        replaceDetails: { type: "boolean" },
        steps: { ...realtimeDailyStepsSchema, description: "High-level planner steps only; detailed checklists belong in the linked note." },
        links: { ...realtimeDailyLinksSchema, description: "Notes that hold details, dimensions, reference facts, or checklists." },
        noteItemID: { type: "string" },
        noteTitle: { type: "string" },
        checked: { type: "boolean" },
        status: { type: "string" }
      },
      required: [],
      additionalProperties: true
    }
  },
  {
    name: "knowledge_request_backlog_item",
    description: "Add one task or follow-up to the OpenAssist backlog. This is the DEFAULT target for new tasks whenever the user has not picked a date, including plain captures and items aimed at a specific @List. Keep backlog items short: what to do plus a few high-level steps. Put detailed specs, dimensions, reference facts, and long checklists in a linked note, then pass noteItemID/noteTitle/links. Applied immediately.",
    parameters: {
      type: "object",
      properties: {
        title: { type: "string" },
        listID: { type: "string" },
        listName: { type: "string" },
        projectID: { type: "string" },
        folderID: { type: "string" },
        area: { type: "string", description: "Optional planner category name such as Work, Personal, Business, Home, or another user-created category." },
        category: { type: "string", description: "Alias for area/category." },
        section: { type: "string", description: "Optional grouping inside the selected List, such as Food, Household, This week, or Follow-ups." },
        tags: { type: "array", items: { type: "string" }, description: "Optional cross-category filter tags, such as Shopping, Errands, Waiting For, or Follow-up." },
        scopeTags: realtimeScopeTagsSchema,
        reminderAt: { type: "string", description: "ISO datetime for an OpenAssist planner local notification. Backlog items can still have reminders." },
        reminderTimezone: { type: "string", description: "IANA timezone for reminderAt, if known." },
        dueAt: { type: "string", description: "Alias for reminderAt." },
        notifyAt: { type: "string", description: "Alias for reminderAt." },
        detailsMarkdown: { type: "string", description: "Short action context only. Do not put detailed specs, dimensions, copied note bodies, or long checklists here; link a note instead." },
        steps: { ...realtimeDailyStepsSchema, description: "High-level planner steps only; detailed checklists belong in the linked note." },
        links: { ...realtimeDailyLinksSchema, description: "Notes that hold details, dimensions, reference facts, or checklists." },
        noteItemID: { type: "string" },
        noteTitle: { type: "string" },
        goal: { type: "string" }
      },
      required: ["title"],
      additionalProperties: true
    }
  },
  {
    name: "knowledge_request_tasks_from_note",
    description: "Create a Review Inbox preview that turns a source note into multiple linked Backlog or planner-day tasks. Read the full note first, then call this with sourceItemID and proposed items. Default target is backlog unless the user gave a date. Do not claim tasks were created until approved.",
    parameters: {
      type: "object",
      properties: {
        sourceItemID: { type: "string" },
        target: { type: "string", enum: ["backlog", "day"] },
        dayID: { type: "string" },
        items: {
          type: "array",
          items: {
            type: "object",
            properties: {
              title: { type: "string" },
              detailsMarkdown: { type: "string" },
              steps: realtimeDailyStepsSchema,
              area: { type: "string" },
              category: { type: "string" },
              listID: { type: "string" },
              listName: { type: "string" },
              projectID: { type: "string" },
              folderID: { type: "string" },
              section: { type: "string" },
              tags: { type: "array", items: { type: "string" } }
            },
            required: ["title"],
            additionalProperties: true
          }
        },
        goal: { type: "string" }
      },
      required: ["sourceItemID", "items"],
      additionalProperties: true
    }
  },
  {
    name: "knowledge_complete_daily_item",
    description: "Mark a planner task or daily item as done by its text. Applied immediately, no approval needed. Set checked to false to mark it not done again.",
    parameters: {
      type: "object",
      properties: {
        dayID: { type: "string" },
        title: { type: "string" },
        checked: { type: "boolean" }
      },
      required: ["title"],
      additionalProperties: true
    }
  },
  {
    name: "knowledge_request_move_to_backlog",
    description: "Move unfinished planner tasks to the Backlog. Adds each task to Backlog and removes it from its source planner day. Use for requests like 'move older unfinished tasks to backlog'. Applied immediately, no approval needed.",
    parameters: {
      type: "object",
      properties: {
        fromDayID: { type: "string" },
        beforeDayID: { type: "string" },
        includeToday: { type: "boolean" },
        goal: { type: "string" }
      },
      required: [],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_request_carry_forward",
    description: "Move unfinished tasks from one planner day to another planner day. Not for Backlog. Applied immediately, no approval needed. Use only when both source and target days are clear.",
    parameters: {
      type: "object",
      properties: {
        fromDayID: { type: "string" },
        targetDayID: { type: "string" },
        goal: { type: "string" }
      },
      required: [],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_note_style_guide",
    description: "Return the OpenAssist note formatting guide covering callout kinds (decision, warning, info, success, next, comment), collapsible sections, 2-column and 3-column table layouts, how to structure long multi-area reference notes, and when not to use rich blocks. Call this before organizing/restructuring/replacing a note so you produce exact replacement markdown with correct OpenAssist syntax.",
    parameters: {
      type: "object",
      properties: {},
      required: [],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_request_organize",
    description: "Request a full-note organization/restructure/rewrite preview. OpenAssist notes are NOT append-only: this tool safely replaces the note body after approval, without duplicating content. You MUST supply itemID and the full replacement markdown containing everything that should remain. Pattern: (1) find/read the note with knowledge_search/knowledge_read, (2) call knowledge_note_style_guide, (3) produce exact replacement markdown using OpenAssist blocks, (4) call this tool with itemID + markdown. Then tell the user it is ready for approval. Do not answer that the MCP cannot reorganize a note.",
    parameters: {
      type: "object",
      properties: {
        goal: { type: "string" },
        itemID: { type: "string", description: "The note or item ID to organize." },
        markdown: { type: "string", description: "Full replacement markdown using OpenAssist-supported blocks." },
        scope: { type: "string" },
        query: { type: "string" }
      },
      required: ["goal", "itemID", "markdown"],
      additionalProperties: true
    }
  }
];

function realtimeVoiceToolSpecs(knowledgeEnabled: boolean, agentLabel: string) {
	  return [
	    ...realtimeVoiceControlToolSpecs,
	    realtimeDelegatedStatusToolSpec(agentLabel),
	    realtimeDelegatedCancelToolSpec(agentLabel),
	    realtimeCodexImageGenerationToolSpec,
	    realtimeBackgroundAgentToolSpec(agentLabel),
    realtimeParallelDelegationToolSpec(agentLabel),
    ...(knowledgeEnabled ? realtimeVoiceKnowledgeToolSpecs : [])
  ];
}

function openAIRealtimeTool(spec: RealtimeVoiceToolSpec): JsonObject {
  return {
    type: "function",
    name: spec.name,
    description: spec.description,
    parameters: spec.parameters
  };
}

function hasGeminiSchemaType(value: unknown) {
  const object = jsonObject(value);
  return typeof object?.type === "string" && object.type.trim().length > 0;
}

function geminiSchemaFromJSONSchema(schema: unknown): unknown {
  const object = jsonObject(schema);
  if (!object) return schema;
  const next: JsonObject = {};
  let schemaType = "";
  for (const [key, value] of Object.entries(object)) {
    if (key === "additionalProperties") continue;
    // The Live API schema parser is stricter than JSON Schema; size constraints
    // are enforced at runtime in routeParallelDelegation instead.
    if (key === "minItems" || key === "maxItems") continue;
    if (key === "type" && typeof value === "string") {
      schemaType = value.toUpperCase();
      next.type = schemaType;
    } else if (key === "properties" && jsonObject(value)) {
      next.properties = Object.fromEntries(
        Object.entries(value as JsonObject).map(([propertyName, propertySchema]) => [
          propertyName,
          geminiSchemaFromJSONSchema(propertySchema)
        ])
      );
    } else if (key === "items") {
      next.items = geminiSchemaFromJSONSchema(value);
    } else {
      next[key] = value;
    }
  }
  if (schemaType === "ARRAY" && !hasGeminiSchemaType(next.items)) {
    next.items = { type: "STRING" };
  }
  if (schemaType === "OBJECT" && !jsonObject(next.properties)) {
    next.properties = {};
  }
  return next;
}

function geminiFunctionDeclaration(spec: RealtimeVoiceToolSpec): JsonObject {
  return {
    name: spec.name,
    description: spec.description,
    ...(spec.geminiBehavior ? { behavior: spec.geminiBehavior } : {}),
    parameters: geminiSchemaFromJSONSchema(spec.parameters)
  };
}

function realtimeInstructions(codexInstructions: string, knowledgeEnabled: boolean, agentLabel: string) {
  const label = agentLabel.trim() || "Agent";
  return [
    "# Role and Objective",
    "You are the realtime voice layer inside OpenAssist.",
    `Messages from ${label} are authoritative. Present the system as one OpenAssist assistant.`,
    "",
    realtimeLocalTimeInstruction(),
    "",
    "# Voice Style",
    "Always speak English. Even if the audio is unclear, noisy, or sounds like another language, reply in English unless the user clearly asks you to switch languages.",
    "Speak naturally, briefly, and clearly.",
    "For casual questions, answer directly in one or two short sentences.",
    "Do not read markdown symbols, XML tags, diffs, or asterisks out loud.",
    "",
    "# Listening Control",
    "If the user only says stop, stop talking, stop speaking, wait, or hold on, stop the current spoken response and keep listening. Do not enter quiet mode for those interruption phrases.",
    "Only if the user clearly asks you to stop listening, mute the microphone, pause listening, go quiet, or pause Live Voice, call set_listening_mode with mode quiet.",
    "If the user asks you to start listening again, resume listening, or says they are back after quiet mode, call set_listening_mode with mode listening.",
    "",
    "# Silence and Background Audio",
    "If the latest audio is silence, background noise, speaker echo, a side conversation, or speech not addressed to OpenAssist, call wait_for_user.",
    "Do not respond conversationally after calling wait_for_user.",
    "",
    "# Unclear Audio",
    "Only act on clear audio or text.",
    "If the user's audio is unclear, ask one short clarification question.",
    "Do not call tools, guess codebase details, or give a preamble when the audio is unclear.",
    "",
	    "# Tools",
	    "Never answer from guesswork when a tool will provide the answer. When you decide to call a tool, call it immediately WITHOUT speaking first — anything spoken in the same turn as a tool call is cut off. Stay silent while the tool runs, then answer once from the tool result.",
	    "Never claim there are no tasks, notes, emails, results, or pending items before a tool result confirms it. Saying \"no\" and then checking is wrong; check first, then answer.",
	    "Use direct OpenAssist knowledge tools before calling background_agent.",
	    "For image/photo/logo/poster/banner/mockup/graphic generation or edits, call request_codex_image_generation. Do not call background_agent for image generation.",
	    "Call request_codex_image_generation without speaking first; when the tool result arrives, tell the user briefly that Codex is generating it.",
	    "Use knowledge_personal_recall only when the user clearly asks about saved memory, previous chats, past work, earlier decisions/plans, or what Codex/Claude/Spark/Gemini previously said or found. The user does not need to say 'check Codex thread' when the intent is clearly recall.",
    "Do not use knowledge_personal_recall for new/current work, online/web/public-data checks, browsing, files, planner edits, or vague 'check it' follow-ups. Use the correct direct tool or background_agent for those.",
	    `If the user asks for status, progress, why the task is stuck, what ${label} is doing, or where the delegated task is at, call get_delegated_task_status and answer from that result.`,
	    `If the user clearly asks to cancel or stop delegated agent work, call cancel_delegated_task. Stopping Live Voice or the microphone must not cancel delegated work.`,
    "Do not call background_agent for status checks about the task that is already running.",
	    "Call background_agent immediately without a spoken preamble. After it starts, acknowledge it once in natural language without naming the worker unless the user asks.",
    "If the user request is agentic and no direct realtime tool can handle it, call background_agent instead of doing it yourself.",
    "If the user clearly asks for TWO OR MORE separate tasks to run at the same time (for example \"do A and B at the same time\", \"run these in parallel\", or two clearly different jobs in one breath), call delegate_parallel_tasks with one entry per task instead of background_agent. Use background_agent for a single task.",
    "When using delegate_parallel_tasks, only set a task's provider if the user names a model for that specific task (claude, codex, copilot, antigravity, ollama), and only set a task's project if the user names a folder or project for it; otherwise leave them empty.",
    "After calling delegate_parallel_tasks, say one short preamble like \"Starting both now\" and then stay quiet. Each task will report its own result when it finishes; speak each result as it arrives, one at a time, without interrupting yourself.",
    "Agentic means the request needs tools, files, code changes, terminal commands, browser/computer use, website/app inspection, account data, current/live information, or multi-step work.",
	    "For coding, codebase, repo, app, terminal, debugging, install, file, browser, computer, desktop app, website, current/live data, or configuration work, call background_agent with the user's exact request.",
	    "When delegated work belongs in a specific sidebar Project, pass its exact name or projectID to background_agent. If no existing project fits, suggest one and use knowledge_create_project after user confirmation, then pass the returned projectID. Never silently use the current project when the requested destination is missing.",
    `Only call background_agent when the user gives a clear task that needs ${label} or provider tools.`,
    "If the user asks what happened in the previous or last turn, whether you already found/did/checked something, or what the previous result was, answer from the conversation context. Do not call background_agent unless the user clearly asks you to run/check/search again.",
    "Do not call background_agent while the user sounds mid-sentence, is pausing, or has only said the first part of a longer task.",
    "If the request starts like a fragment, for example \"if...\", \"when...\", \"and...\", or \"also...\", call wait_for_user and wait for the complete request.",
    "Follow-up task requests like \"check it for yesterday\" or \"do the same for yesterday\" should call background_agent using the recent delegated task as context.",
    "If the user only says ok, yes, no, mhm, hmm, thanks, or another short acknowledgement, do not call background_agent.",
    `If ${label} is already working and the user gives a tiny acknowledgement or vague follow-up, do not start a new background_agent task.`,
    `After calling background_agent, stay quiet about task progress and wait for the final ${label} result before giving task details.`,
    `OpenAssist hides ${label} progress from the model conversation. Do not guess, summarize, or invent task progress.`,
    `While ${label} is working, keep listening and keep helping like a personal assistant. Answer direct questions, and if the user gives ANOTHER clear task, call background_agent again — tasks run side by side.`,
    "When several tasks are running, results arrive one at a time in the order they finish. Speak only the result that just arrived, name which task it belongs to, and never mix it with other tasks or re-summarize earlier results.",
    "Do not guess or report on tasks that have not finished; if asked about them, use get_delegated_task_status.",
    "Delegated task results are narrated by OpenAssist with per-response instructions. Use only the narrated result and do not add new facts.",
    "Do not invent codebase details.",
    knowledgeEnabled
      ? [
        "",
        "# OpenAssist Knowledge",
	      "For quick questions about the user's notes, Today planner, Backlog, journal, or open tasks, use the knowledge tools.",
	      "Use knowledge tools only when the user asks for personal OpenAssist knowledge. Do not read all notes into the voice prompt.",
		      "For connected Gmail/Google/Messages data, call knowledge_connector_status first. If the user asks to find/show/search for a specific email or email type, call knowledge_connector_search_gmail with a narrow query and do not sync Review Inbox. If the user asks to check iMessage, Messages, texts, or SMS for a person, appointment, or follow-up, call knowledge_connector_search_messages with a narrow query and do not ask what they mean by Messages. If the user asks for Gmail to-dos, backlog items, follow-ups, waiting-for items, or task candidates, call knowledge_connector_sync_gmail with userIntent set to the user's exact request. Do not fetch full email bodies or ask for all mail in realtime.",
      "For greetings and small talk like 'hello', 'hi', 'hey', 'ei', 'how are you', or 'good morning', just reply naturally in one short sentence. Do NOT call knowledge_daily_items or any tool for a greeting.",
      "Only call a knowledge tool when the user actually asks about their tasks, notes, planner, backlog, or journal. A greeting alone is not such a request.",
      "For questions like 'what's on today', 'today's plan', 'today's list', or 'today's note', call knowledge_read_today first so you see the full planner markdown, including free-text lines. ALWAYS pass the Selected planner day ID from your context as the `dayID` argument so you read the exact note the user is viewing. If you omit it, you might read the wrong day.",
      "Use knowledge_daily_items for structured checkbox/planner items with categories, lists, and tags. If it returns no structured items but freeTextItems or noteMarkdown is present, read those and report them. Never tell the user today is empty based only on an empty knowledge_daily_items result.",
      "Use knowledge_open_tasks for unfinished checkbox tasks across notes and planner days.",
	      "Use knowledge_backlog_items for backlog or later/follow-up questions.",
		      "Use knowledge_planner_categories or knowledge_planner_lists to see available Categories and Lists before assigning them when the user has not named an exact match.",
		      "Use knowledge_list_projects to inspect the sidebar Projects and folders before choosing where a new note, chat, or delegated task belongs. If no existing project fits, suggest one short project name and, when useful, one parent folder. Ask for confirmation unless the user already explicitly asked you to create it.",
		      "After the user requests or confirms the new destination, call knowledge_create_project with confirmed=true. A folder cannot hold notes or chats by itself, so create or choose a project inside it, then use the returned projectID for the note or task. Never silently fall back to an unrelated existing project.",
		      "For clear memory/history questions like 'when did we', 'where did I mention', 'what did we decide', 'what did Codex or Claude say', 'did we work on anything for Quality Nails', or 'find the earlier discussion', call knowledge_personal_recall. It searches the right saved memory/chat/session sources automatically, including Codex and Claude Code. Do not make the user ask for a specific Codex thread. Do not call background_agent for clear recall.",
	      "When the user names a project, pass its exact projectName or projectID. When they say this project or this conversation, OpenAssist applies the selected context. Never broaden a project-scoped recall to unrelated projects; ask one short question when the project is missing or unclear.",
	      "If the user asks to check/search something now, check online, browse a site, inspect files, update tasks/notes, or use an agent/tool for a new task, do not call knowledge_personal_recall.",
	      "When a request requires real execution with an agent, computer, external tool, CLI, app, service, logs, database, build, test, or repository, call background_agent with the full request. Do not use personal recall and do not pretend the work was done. Acknowledge the start once, stay conversational while it runs, then answer only from the final result.",
	      "If the user asks to add a reminder, task, or to-do in OpenAssist, treat it as an OpenAssist planner item, not as Apple Calendar or Apple Reminders. For simple adds, use knowledge_quick_add_task first. By default it goes to the Backlog: only set `when` to a planner day when the user explicitly names a date or says today, tonight, tomorrow, or a specific weekday. If they give an alert time, set `reminderAt` as an ISO datetime and `reminderTimezone` when known; do not store the reminder time only as plain details. If they just say 'add X' or 'add X to @List' with no timing, leave `when` empty or set it to backlog.",
	      "Reference info is NOT a task: measurements/dimensions, links/URLs, model or SKU numbers, prices, addresses, phone/email, specs, product details, realtor info, and 'save this' facts must go to the existing List/thread reference note with knowledge_quick_save_note or knowledge_request_reference, not Today or Backlog. Reference captures apply immediately only when the target note already exists.",
	      "Actions are tasks: buy, order, research, decide, schedule, call, message, finish, follow up, or fix. Use knowledge_quick_add_task for a single action. Date-less actions go to Backlog; dated actions go to the named day.",
	      "Before saving reference info, reuse the existing List/thread note. New Lists and new notes are never created silently: call knowledge_plan_write for uncertain cases, and if the router says approval is required, tell the user the pending preview needs approval.",
	      "When the live context includes an Active source note itemID and the user says this note, that note, the note, add that as well, save that there, or append to it, pass that exact itemID to knowledge_quick_save_note or knowledge_request_reference. This is an update to the selected note, never a request to create another note with the same title.",
	      "Call knowledge_plan_write before ambiguous adds/edits, mixed task/reference requests, unknown Lists, possible duplicate/update cases, or anything that might need a new note/List.",
	      "If the user gives both an action and a fact, handle both intelligently: create the action task and save the concrete reference facts to the note. Example: 'buy a 57 inch TV for @New Home Stuff' is a Backlog task plus a 57 inch TV reference.",
	      "Planner items are lightweight execution pointers: what to do, when/where, and a few high-level steps. Notes hold detailed working material such as specs, dimensions, copied source content, and long checklists. Example: 'go to Maryland Ave tomorrow and check TV/laundry fit' is one short Tomorrow task linked to New Home Stuff; the TV dimensions, LG WashCombo dimensions, and measurement checklist belong inside the linked note.",
	      "If a task should refer to a note, attach it with noteItemID, noteTitle, or links on knowledge_quick_add_task, knowledge_request_daily_item, knowledge_request_backlog_item, or knowledge_update_daily_item. Use listName only for a real planner List, not as the note name. Keep details/detailsMarkdown short and never paste the full note body into the task.",
	      "If reference-vs-action is ambiguous or the user only gives a #Category without a clear @List/thread/note, ask one short clarification instead of guessing.",
	      "When you create a Today item, put it under the right category heading by setting area/category when the user gives or implies one.",
	      "Use knowledge_quick_add_task for simple Today/Backlog/date adds. Use knowledge_request_daily_item or knowledge_request_backlog_item only when you need the fuller schema. For date-less ACTIONS, including plain actionable captures aimed at a specific @List, default to Backlog. Reference captures use knowledge_quick_save_note or knowledge_request_reference; they apply immediately only for existing notes and otherwise create a pending approval preview. Never silently add a date-less task to Today. Do not also add Today items to Backlog.",
	      "When the user asks to create tasks from a note, split a note into tasks, or do sprint planning from a note, first find/read the full source note with knowledge_search/knowledge_read, then call knowledge_request_tasks_from_note with sourceItemID and proposed items. Default to target backlog unless the user gives a date. This creates a Review Inbox preview; do not claim tasks were created until approved.",
	      "If the user asks to change, rename, move, recategorize, or add details to an existing planner item, use knowledge_update_daily_item with itemID or the current task text in query. Do not use knowledge_request_daily_item for edits, because that creates a duplicate. When replacing task details, set detailsMode='replace' or replaceDetails=true; append only when the user explicitly asks to add a small note. If they say it is not for the current @List and only name a Category such as Work, set area/category and clearList=true.",
	      "When the user only asks to set/change a reminder or to complete/uncomplete a task, call knowledge_update_daily_item with ONLY itemID or query plus the reminder or checked fields. NEVER include area/category/listName on those calls — guessing a category there moves the task to another section.",
	      "If the user asks for subtasks, sub-items, sub-checkboxes, or a checklist UNDER an existing task, put them in the `steps` array of knowledge_update_daily_item (one short step per entry, e.g. steps: [{\"text\": \"Costco delivery 11a-2p\"}]). Steps render as checkboxes under the task. Do NOT write subtasks into detailsMarkdown — details are plain text, not checkboxes. When converting existing details into steps, also set detailsMode='replace' with a shorter detailsMarkdown (or empty) so the same content is not duplicated in both places.",
	      "When you create a Today or Backlog item, use Category -> List -> Section -> Item. The inline shorthand is #Category and @List. If only @List is used, use that List's default Category. Explicit #Category wins. Work, Personal, Business, and Home are Categories, not Lists. Set area/category, listID or listName, section, and tags when the user gives them. If the user names a project/context phrase but not an exact List, call knowledge_planner_lists; if no exact match is clear, omit the List or ask one short clarification. Do not use broad note history to guess the List.",
	      "Use tags only for cross-category filters such as Shopping, Errands, Waiting For, or Follow-up.",
	      "Do not assume business-related tasks are Work if a Business category exists; use Business only when knowledge_planner_categories shows it, otherwise ask or omit area.",
	      "If the user says a task is done, finished, or completed, call knowledge_complete_daily_item with the task text. It is applied immediately, so say it was marked done.",
	      "To move unfinished or older planner tasks into the Backlog, use knowledge_request_move_to_backlog.",
	      "To move unfinished tasks from one planner day to another planner day, use knowledge_request_carry_forward.",
	      "For organizing, correcting, or changing planner content, use knowledge_request_carry_forward or a direct knowledge request only when the source, target, and exact preview are clear; otherwise ask a short question or call background_agent for complex work.",
	      "OpenAssist notes are not append-only. Use knowledge_quick_save_note/knowledge_request_reference only for small additive reference captures. For reorganize, restructure, cleanup, rewrite, formatting, or make-it-easier-to-scan requests, the safe path is a full replacement approval preview with knowledge_request_organize after reading the note and calling knowledge_note_style_guide.",
	      `For substantial note organization, restructuring, cleanup, rewriting, or styling requests, call background_agent with the user's exact request so ${label} can read the full note, use OpenAssist note style tools, and create that approval preview. Do not try to do heavy note rewriting in realtime voice, and do not say the MCP can only append.`,
	      "Use realtime knowledge tools for quick note reads/searches, reference captures, small exact note edits, simple Today/Backlog adds, small tasks-from-note previews, planner item updates, mark-done actions, and planner moves. Delegate full-note organization/restructure/cleanup tasks or large sprint-planning notes.",
	      "Do not claim a note was organized, changed, or updated until a tool or delegated agent result confirms an approval preview was created.",
	      "knowledge_request_organize creates a full-note replacement preview that needs the user's approval. After calling it, tell the user the organized version is ready for approval and can be applied in Review Inbox or through knowledge_apply_approval after listing it with knowledge_list_approvals. Do not claim the note was already changed.",
		      "If background_agent is handling organize, stay quiet until OpenAssist narrates the final result. If the result says a preview is pending, tell the user it is ready for approval in Review Inbox.",
	      "OpenAssist notes support rich blocks: callouts (::: decision, ::: warning, ::: info, ::: success, ::: next, ::: comment), collapsible sections (## Area <!-- oa:collapsible -->), and 2/3-column table layouts. Always use knowledge_note_style_guide before writing organized markdown so the output uses valid OpenAssist syntax.",
	      "When a reference note covers multiple areas/items (specs, checklists, option comparisons, on-site references), keep it scannable: short intro and a clear heading per area, then prefer 2/3-column layouts to use horizontal space (compare options side by side, or put saved facts next to the fit/decision fields), the interactive checklist at full width, and derived fields (max-that-fits, final yes/no) in a short decision block. Do not put checkbox items inside table cells. For values the user fills in on-site, use an empty 'Actual'/'Value' table cell (tap to type) and checkboxes for yes/no instead of inline '____' blanks, which are hard to edit on phone. Collapsible sections are optional and only for very long notes.",
	      `Complex multi-step work should go to background_agent; ${label} can use the same knowledge access.`
      ].join("\n")
      : "",
    codexInstructions.trim()
      ? ["", "# Codex Session Context", "Use this only as background context. Do not read it aloud unless the user asks.", codexInstructions.trim()].join("\n")
      : ""
  ].filter(Boolean).join("\n");
}

function realtimeSessionConfig(config: RealtimeProxyConfig, codexInstructions: string, quiet: boolean): JsonObject {
  const knowledgeEnabled = Boolean(config.knowledge?.enabled);
  const agentLabel = config.handoff?.agentLabel || "Codex";
  const tools = realtimeVoiceToolSpecs(knowledgeEnabled, agentLabel).map(openAIRealtimeTool);
  return {
    type: "realtime",
    model: config.model || defaultRealtimeModel,
    instructions: realtimeInstructions(codexInstructions, knowledgeEnabled, agentLabel),
    output_modalities: ["audio"],
    audio: {
      input: {
        format: { type: "audio/pcm", rate: 24000 },
        noise_reduction: { type: "near_field" },
        transcription: { model: "gpt-4o-mini-transcribe", language: "en" },
        turn_detection: {
          type: "semantic_vad",
          eagerness: realtimeVADEagerness,
          // Keep barge-in enabled even in quiet mode so the user can always cut in;
          // quiet mode only suppresses the assistant auto-replying (create_response).
          interrupt_response: true,
          create_response: !quiet
        }
      },
      output: {
        format: { type: "audio/pcm", rate: 24000 },
        voice: config.voice || defaultRealtimeVoice
      }
    },
    tools,
    tool_choice: "auto"
  };
}

function geminiLiveSessionConfig(
  Modality: { AUDIO: unknown },
  config: RealtimeProxyConfig,
  codexInstructions: string,
  resumeHandle?: string,
  bootstrap?: LiveVoiceBootstrapContext
) {
  const knowledgeEnabled = Boolean(config.knowledge?.enabled);
  const agentLabel = config.handoff?.agentLabel || "Codex";
  const voiceName = (config.voice || defaultGeminiLiveVoice).trim();
  const model = config.model?.trim() || defaultGeminiLiveModel;
  const bootstrapMessages = bootstrap?.messages.map((message) =>
    `${message.role === "assistant" ? "Assistant" : "User"}: ${message.text}`
  ).join("\n") || "";
  const bootstrapInstruction = [
    bootstrap?.earlierHighlights
      ? `Earlier Live Voice highlights:\n${bootstrap.earlierHighlights}`
      : "",
    bootstrapMessages ? `Recent completed Live Voice turns:\n${bootstrapMessages}` : ""
  ].filter(Boolean).join("\n\n");
  const geminiConfig: JsonObject = {
    responseModalities: [Modality.AUDIO],
    systemInstruction: [
      realtimeInstructions(codexInstructions, knowledgeEnabled, agentLabel),
      bootstrapInstruction
        ? `Use the following restored text only as private conversation context. Do not repeat it and do not respond until the user speaks:\n${bootstrapInstruction}`
        : ""
    ].filter(Boolean).join("\n\n"),
    temperature: 0.7,
    inputAudioTranscription: {},
    outputAudioTranscription: {},
    realtimeInputConfig: {
      automaticActivityDetection: {
        // LOW start sensitivity requires clearer/louder speech to open a turn,
        // so faint background voices no longer trigger Gemini. Paired with the
        // client-side noise gate that replaces background with clean silence.
        startOfSpeechSensitivity: "START_SENSITIVITY_LOW",
        endOfSpeechSensitivity: "END_SENSITIVITY_HIGH",
        // Slightly longer trailing silence so a brief pause mid-thought does not
        // cut the user off, while clean gated silence still ends the turn.
        silenceDurationMs: 800
      },
      activityHandling: "START_OF_ACTIVITY_INTERRUPTS",
      turnCoverage: "TURN_INCLUDES_ONLY_ACTIVITY"
    },
    thinkingConfig: isGemini31LiveModel(model)
      ? {
        includeThoughts: false,
        thinkingLevel: "minimal"
      }
      : {
        includeThoughts: false,
        thinkingBudget: 0
      },
	    tools: [
      {
        functionDeclarations: realtimeVoiceToolSpecs(knowledgeEnabled, agentLabel).map(geminiFunctionDeclaration)
      }
	    ],
    contextWindowCompression: {
      slidingWindow: {}
    },
    sessionResumption: resumeHandle ? { handle: resumeHandle } : {}
  };

  if (voiceName) {
    geminiConfig.speechConfig = {
      voiceConfig: {
        prebuiltVoiceConfig: { voiceName }
      }
    };
  }
  return geminiConfig;
}

function appendTranscriptChunk(existing: string, next: string) {
  const cleanNext = String(next || "").trim();
  if (!cleanNext) return existing;
  const cleanExisting = existing.trim();
  if (!cleanExisting) return cleanNext;
  if (cleanExisting.endsWith(cleanNext)) return cleanExisting;
  if (cleanNext.startsWith(cleanExisting)) return cleanNext;
  return `${cleanExisting}${/[.!?,;:]$/.test(cleanExisting) ? " " : " "}${cleanNext}`.replace(/\s+/g, " ").trim();
}

class RealtimeProxySession {
  private upstream?: WebSocket;
  private upstreamReady?: Promise<WebSocket | GeminiLiveSession | null>;
  private geminiSession?: GeminiLiveSession;
  private codexInstructions = "";
  private state: RealtimeSessionState = "idle";
  private quiet = false;
  private audioItemID = "";
  private audioMs = 0;
  private activeOpenAIResponseID = "";
  private toolGateDropActive = false;
  private gatedToolResponseIDs = new Set<string>();
  private gatedToolAudioItemIDs = new Set<string>();
  private sampleRate = 24000;
  private geminiInputTranscript = "";
  private geminiOutputTranscript = "";
  private geminiContinuityItemID = "";
  private geminiAudioItemID = "";
  private geminiFailureMessage = "";
  private openAIResponseActive = false;
  private openAIOutputTranscript = "";
  private openAIResponseCreatePending: { reason: string; response: JsonObject } | null = null;
  // Watchdog: if a response we believe is active never reports response.done (e.g. it
  // was cancelled by a barge-in, or the server/proxy state desynced), force-clear the
  // flag so the assistant can speak again instead of going permanently silent.
  private openAIResponseWatchdog?: NodeJS.Timeout;
  private openAIDirectResultAudioRetry?: NodeJS.Timeout;
  private readonly taskAbortControllers = new Map<string, AbortController>();
  // Results from parallel-delegated tasks waiting to be spoken. They are narrated
  // strictly one at a time (FIFO): the next one only starts once the current spoken
  // response has finished, so two tasks finishing close together never overlap.
  private parallelResultQueue: Array<{ taskID: string; text: string; agentLabel: string }> = [];
  private parallelResultSpeaking = false;
  private parallelResultSpeakingTaskID = "";
  // Gemini Live sends generationComplete and turnComplete as separate messages
  // for the same turn; finishGeminiTurn must only run once per turn.
  private geminiTurnFinished = false;
  // True while a delegation decision (router call) is being awaited, so the
  // auto-handoff timer and an explicit background_agent tool call cannot both
  // pass their "nothing running" checks and start the same task twice.
  private delegationStartInFlight = false;
  private handledCalls = new Set<string>();
  private handledKnowledgePrompts = new Map<string, number>();
  private personalRecallCache = new Map<string, PersonalRecallCacheEntry>();
  private localMessageHandoffCallIDs = new Set<string>();
  private lastUserUtterance = "";
  private currentVoiceTurnID = "";
  private currentVoiceProviderItemID = "";
  private readonly voiceTurnOwners = new Map<string, { owner: string; callID: string }>();
  private readonly pendingVoiceToolCallIDs = new Set<string>();
  private recentUserUtterances: string[] = [];
  private lastDelegationPrompt = "";
  private lastKnowledgePrompt = "";
  private lastKnowledgePromptAt = 0;
  // Set while a personal recall is running; used to defer parallel
  // model-initiated knowledge searches that would answer with stale queries.
  private personalRecallInFlightSince: number | null = null;
  private lastDelegationResult = "";
  private lastAutoHandoffNormalizedPrompt = "";
  private autoHandoffTimer?: NodeJS.Timeout;
  private autoHandoffSequence = 0;
  private closed = false;
  // Reliability: automatic reconnect + keepalive for the OpenAI upstream socket.
  private reconnectAttempts = 0;
  private reconnectTimer?: NodeJS.Timeout;
  private keepAliveTimer?: NodeJS.Timeout;
  private fatalUpstreamError = false;
  private readonly continuityTracker = new LiveVoiceCompletedTurnTracker();
  private readonly continuitySessionID = makeShortRealtimeID("voice");
  private continuityTurnSequence = 0;
  private continuityRuntimeMessages: LiveVoiceHistoryMessage[] = [];
  private openAIHistoryRestoredFor?: WebSocket;
  private geminiHistoryRestored = false;
  private geminiResumeKey = "";
  private geminiResumeHandleUsed = false;

  constructor(
    private readonly codexSocket: WebSocket,
    private readonly configProvider: () => RealtimeProxyConfig,
    private readonly log: (message: string) => void,
    private readonly taskCoordinator: RealtimeTaskCoordinator,
    private readonly onClose: (session: RealtimeProxySession) => void = () => {},
    private readonly onTasksIdle: (session: RealtimeProxySession) => void = () => {}
	  ) {}

  private taskScopeKey() {
    return this.configProvider().continuity?.threadKey?.trim() || this.continuitySessionID;
  }

  private get pendingHandoffs() {
    return this.taskCoordinator.activeMap(this.taskScopeKey());
  }

  private get activeParallelDelegations() {
    return this.taskCoordinator.activeCount("parallel", this.taskScopeKey());
  }

  private continuityTurnID(provider: RealtimeCloudProvider, providerItemID = "") {
    const item = providerItemID.replace(/[^a-z0-9_-]/gi, "").slice(-48);
    const sequence = ++this.continuityTurnSequence;
    return `live-voice-${provider}-${this.continuitySessionID}-${item || sequence}`;
  }

  private beginContinuityUser(provider: RealtimeCloudProvider, text: string, providerItemID = "") {
    const clean = String(text || "").replace(/\s+/g, " ").trim();
    if (!clean || isBackendProgressMessage(clean) || isCodexFinalResultMessage(clean)) return "";
    const normalizedItemID = providerItemID.trim();
    if (!this.currentVoiceTurnID || !normalizedItemID || normalizedItemID !== this.currentVoiceProviderItemID) {
      this.currentVoiceTurnID = this.continuityTurnID(provider, normalizedItemID);
      this.currentVoiceProviderItemID = normalizedItemID;
    }
    this.continuityTracker.beginUser(this.currentVoiceTurnID, clean);
    for (const callID of this.pendingVoiceToolCallIDs) {
      this.claimVoiceTurn("routing", callID, this.currentVoiceTurnID);
    }
    this.pendingVoiceToolCallIDs.clear();
    return this.currentVoiceTurnID;
  }

  private reserveVoiceToolCall(callID: string) {
    if (!callID) return false;
    if (!this.currentVoiceTurnID) {
      this.pendingVoiceToolCallIDs.add(callID);
      return true;
    }
    return this.claimVoiceTurn("routing", callID);
  }

  private claimVoiceTurn(owner: string, callID: string, turnID = this.currentVoiceTurnID) {
    if (!turnID) return true;
    const existing = this.voiceTurnOwners.get(turnID);
    if (existing) {
      if (existing.callID === callID && existing.owner === "routing") {
        this.voiceTurnOwners.set(turnID, { owner, callID });
        return true;
      }
      if (existing.owner !== owner) return false;
      return owner === "knowledge" || owner === "status" || owner === "control"
        ? true
        : existing.callID === callID;
    }
    this.voiceTurnOwners.set(turnID, { owner, callID });
    if (this.voiceTurnOwners.size > 100) {
      const oldest = this.voiceTurnOwners.keys().next().value;
      if (oldest) this.voiceTurnOwners.delete(oldest);
    }
    return true;
  }

  private markContinuityOwnedExternally() {
    this.continuityTracker.markOwnedExternally();
  }

  private interruptContinuityTurn() {
    this.continuityTracker.markInterrupted();
  }

  private completeContinuityTurn(assistantText: string) {
    this.continuityTracker.setAssistant(assistantText);
    const turn = this.continuityTracker.finish();
    if (!turn) return;
    this.continuityRuntimeMessages.push(
      { role: "user", text: turn.userText },
      { role: "assistant", text: turn.assistantText }
    );
    this.continuityRuntimeMessages = buildLiveVoiceBootstrapContext(this.continuityRuntimeMessages).messages;
    if (turn.ownedExternally) return;
    const continuity = this.configProvider().continuity;
    if (!continuity) return;
    void Promise.resolve(continuity.onCompletedTurn({
      ...turn,
      provider: this.isGeminiLive() ? "geminiLive" : "openaiRealtime"
    })).catch(() => {
      continuity.onStatus?.({
        status: "persist_failed",
        message: "The live conversation continued, but this turn could not be added to the Voice Log."
      });
    });
  }

  private resetCurrentVoiceTurn() {
    this.currentVoiceTurnID = "";
    this.currentVoiceProviderItemID = "";
  }

  private continuityContext() {
    const bootstrap = this.configProvider().continuity?.bootstrap ?? { earlierHighlights: "", messages: [] };
    const bounded = buildLiveVoiceBootstrapContext([
      ...bootstrap.messages,
      ...this.continuityRuntimeMessages
    ]);
    return {
      earlierHighlights: bootstrap.earlierHighlights,
      messages: bounded.messages
    } satisfies LiveVoiceBootstrapContext;
  }

  private stateSnapshot(reason: string, previousState?: RealtimeSessionState): RealtimeSessionStateSnapshot {
    const responseActive = this.openAIResponseActive || Boolean(this.geminiAudioItemID);
    const voicePhase: RealtimeSessionStateSnapshot["voicePhase"] = this.closed
      ? "closed"
      : this.quiet
        ? "quiet"
        : responseActive || this.parallelResultSpeaking
          ? "speaking"
          : "listening";
    return {
      state: this.state,
      previousState,
      reason,
      quiet: this.quiet,
      pendingHandoffs: this.pendingHandoffs.size,
      activeParallelDelegations: this.activeParallelDelegations,
      queuedNarrations: this.parallelResultQueue.length,
      responseActive,
      voicePhase,
      foregroundWork: this.toolGateDropActive ? "tool" : undefined,
      voiceProvider: this.realtimeProvider(),
      workerProvider: this.configProvider().handoff?.agentLabel || "Codex",
      tasks: this.taskCoordinator.visible(this.taskScopeKey()).map((task) => ({
        taskID: task.taskID,
        sourceTurnID: task.sourceTurnID,
        prompt: task.prompt,
        workerProvider: task.workerProvider,
        state: task.state,
        progress: task.progress,
        progressEntries: task.progressEntries.map((entry) => ({ ...entry })),
        result: task.result,
        error: task.error,
        deliveryState: task.deliveryState,
        startedAt: task.startedAt,
        updatedAt: task.updatedAt,
        finishedAt: task.finishedAt
      }))
    };
  }

  private transition(to: RealtimeSessionState, reason: string) {
    const next = this.quiet && to !== "idle" ? "quiet" : to;
    if (this.state === next) return;
    const previous = this.state;
    this.state = next;
    this.log(`[realtime.proxy] state: ${previous} -> ${next} (${reason})`);
    const snapshot = this.stateSnapshot(reason, previous);
    this.configProvider().connection?.onEvent({
      type: "state_changed",
      state: next,
      previousState: previous,
      reason,
      snapshot
    });
  }

  private publishSessionSnapshot(reason: string) {
    this.configProvider().connection?.onEvent({
      type: "state_changed",
      state: this.state,
      previousState: this.state,
      reason,
      snapshot: this.stateSnapshot(reason, this.state)
    });
  }

  private refreshSessionState(reason: string) {
    if (this.quiet) {
      this.transition("quiet", reason);
      return;
    }
    if (this.toolGateDropActive) {
      this.transition("toolPending", reason);
      return;
    }
    if (this.parallelResultSpeaking) {
      this.transition("narrating", reason);
      return;
    }
    if (this.openAIResponseActive || this.geminiAudioItemID) {
      this.transition("speaking", reason);
      return;
    }
    this.transition("listening", reason);
  }

	  start() {
	    this.transition("listening", "client connected");
	    this.codexSocket.on("message", (data) => {
	      void this.onCodexMessage(data.toString());
    });
    this.codexSocket.on("close", (_code, reason) => {
      const message = reason?.toString() || "no reason";
      this.log(`[realtime.proxy] client websocket closed: ${message}`);
      this.configProvider().connection?.onEvent({ type: "client_closed", reason: message });
      this.closeVoice();
    });
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

  private restoreOpenAIHistory() {
    const upstream = this.upstream;
    if (!upstream || upstream.readyState !== WebSocket.OPEN || this.openAIHistoryRestoredFor === upstream) return;
    this.openAIHistoryRestoredFor = upstream;
    const continuity = this.configProvider().continuity;
    if (!continuity) return;
    try {
      const context = this.continuityContext();
      if (context.earlierHighlights) {
        if (!this.sendUpstream({
          type: "conversation.item.create",
          item: {
            type: "message",
            role: "system",
            content: [{
              type: "input_text",
              text: `Earlier Live Voice context. Use silently as background and do not answer it:\n${context.earlierHighlights}`
            }]
          }
        })) throw new Error("OpenAI Realtime socket was not ready for context restore.");
      }
      for (const message of context.messages) {
        if (!this.sendUpstream({
          type: "conversation.item.create",
          item: {
            type: "message",
            role: message.role,
            content: [{
              type: message.role === "assistant" ? "output_text" : "input_text",
              text: message.text
            }]
          }
        })) throw new Error("OpenAI Realtime socket closed during context restore.");
      }
      continuity.onStatus?.({ status: "restored" });
      this.log(`[realtime.proxy] restored OpenAI Live Voice context messages=${context.messages.length}`);
    } catch (error) {
      continuity.onStatus?.({
        status: "restore_failed",
        message: "Live Voice started without earlier conversation context."
      });
      this.log(`[realtime.proxy] OpenAI context restore failed: ${error instanceof Error ? error.message : "unknown error"}`);
    }
  }

  private restoreGeminiHistory() {
    if (this.geminiHistoryRestored) return;
    this.geminiHistoryRestored = true;
    const continuity = this.configProvider().continuity;
    if (!continuity) return;
    if (this.geminiResumeHandleUsed) {
      continuity.onStatus?.({ status: "restored" });
      this.log("[realtime.proxy] resumed Gemini Live context from memory-only handle");
      return;
    }
    try {
      const context = this.continuityContext();
      continuity.onStatus?.({ status: "restored" });
      this.log(`[realtime.proxy] restored Gemini Live setup context messages=${context.messages.length}`);
    } catch (error) {
      continuity.onStatus?.({
        status: "restore_failed",
        message: "Live Voice started without earlier conversation context."
      });
      this.log(`[realtime.proxy] Gemini context restore failed: ${error instanceof Error ? error.message : "unknown error"}`);
    }
  }

  private rememberToolGateResponse(event: JsonObject, item: JsonObject) {
    const response = jsonObject(event.response);
    const responseID = stringValue(event.response_id, item.response_id, response?.id, this.activeOpenAIResponseID);
    const itemID = stringValue(event.item_id, item.id, item.item_id);
    if (responseID) this.gatedToolResponseIDs.add(responseID);
    if (itemID) this.gatedToolAudioItemIDs.add(itemID);
    this.toolGateDropActive = true;
  }

  private gateAnswerBearingToolSpeech(event: JsonObject, item: JsonObject) {
    if (!isAnswerBearingFunctionCallItem(item)) return false;
    const name = realtimeFunctionCallName(item);
    this.rememberToolGateResponse(event, item);
    this.transition("toolPending", `function_call:${name}`);
    if (this.audioItemID || this.openAIResponseActive) {
      this.log(`[realtime.proxy] gated spoken guess before ${name}; truncating current response audio`);
      this.truncateOpenAIAudio();
      this.sendToCodex({ type: "output_audio_buffer.cleared" });
    }
    return true;
  }

  private shouldDropGatedOpenAIAudio(event: JsonObject) {
    if (!this.toolGateDropActive) return false;
    const responseID = stringValue(event.response_id, jsonObject(event.response)?.id, this.activeOpenAIResponseID);
    const itemID = stringValue(event.item_id, event.output_item_id, this.audioItemID);
    if (responseID && this.gatedToolResponseIDs.has(responseID)) return true;
    if (itemID && this.gatedToolAudioItemIDs.has(itemID)) return true;
    // Some Realtime deltas omit response_id. While the current response is gated,
    // fail closed and drop audio until response.done clears the gate.
    return this.toolGateDropActive && this.gatedToolResponseIDs.size === 0;
  }

  private clearToolGate(reason: string) {
    if (!this.toolGateDropActive && this.gatedToolResponseIDs.size === 0 && this.gatedToolAudioItemIDs.size === 0) return;
    this.toolGateDropActive = false;
    this.gatedToolResponseIDs.clear();
    this.gatedToolAudioItemIDs.clear();
    this.refreshSessionState(reason);
  }

  private rememberRecentUserUtterance(text: string) {
    const prompt = String(text || "").replace(/\s+/g, " ").trim();
    if (!prompt || isBackendProgressMessage(prompt) || isCodexFinalResultMessage(prompt)) return;
    const normalized = normalizeRealtimeIntent(prompt);
    const previous = this.recentUserUtterances[this.recentUserUtterances.length - 1] || "";
    if (normalized && normalizeRealtimeIntent(previous) === normalized) return;
    this.recentUserUtterances.push(prompt);
    if (this.recentUserUtterances.length > 8) this.recentUserUtterances.splice(0, this.recentUserUtterances.length - 8);
  }

  private recentRecallContext(query: string) {
    const normalizedQuery = normalizeRealtimeIntent(query);
    if (!normalizedQuery) return "";
    const needsContext = /\b(it|that|this|they|them|latest|recent|conversation|conversations|chat|chats|thread|threads|session|sessions|codex|claude|spark|gemini|agent)\b/.test(normalizedQuery);
    if (!needsContext) return "";
    const recent = this.recentUserUtterances
      .filter((item) => normalizeRealtimeIntent(item) !== normalizedQuery)
      .slice(-5);
    if (!recent.length) return "";
    return [
      "Recent live user context:",
      ...recent.map((item) => `- ${item}`)
    ].join("\n");
  }

	  private personalRecallArgs(args: JsonObject, fallback?: string): JsonObject {
	    const query = stringValue(args.query, args.question, args.prompt, args.text, fallback, this.lastUserUtterance);
	    const context = this.recentRecallContext(query);
	    const recallContext = this.configProvider().knowledge?.context;
	    return {
      ...args,
      query,
	      ...(context ? { context } : {}),
	      ...(recallContext?.projectID ? { contextProjectID: recallContext.projectID } : {}),
	      ...(recallContext?.projectName ? { contextProjectName: recallContext.projectName } : {}),
	      ...(recallContext?.threadID ? { contextThreadID: recallContext.threadID } : {})
	    };
	  }

	  private codexImageGenerationArgs(args: JsonObject, fallback?: string): JsonObject {
	    const prompt = stringValue(args.prompt, args.request, args.text, args.description, fallback, this.lastUserUtterance);
	    return {
	      ...args,
	      prompt: prompt || "Generate the requested image."
	    };
	  }

	  private async codexImageGenerationToolOutput(callID: string, args: JsonObject, fallback?: string) {
	    const worker = this.configProvider().codexImageGeneration;
	    const effectiveArgs = this.codexImageGenerationArgs(args, fallback);
	    const prompt = stringValue(effectiveArgs.prompt, fallback, this.lastUserUtterance);
	    if (!worker) {
	      const result = {
	        ok: false,
	        summary: "Codex image generation is not available in this Live session.",
	        error: "Codex image generation is not configured."
	      };
	      this.notifyDirectWork(callID, "request_codex_image_generation", "failed", result.summary, result.error, { args: effectiveArgs, result });
	      return JSON.stringify(result, null, 2);
	    }
	    try {
	      const result = await worker.run({ callID, args: effectiveArgs, prompt });
	      return JSON.stringify(result, null, 2);
	    } catch (error) {
	      const message = error instanceof Error ? error.message : "Codex image generation failed.";
	      const result = {
	        ok: false,
	        summary: "Codex image generation failed.",
	        error: message
	      };
	      this.notifyDirectWork(callID, "request_codex_image_generation", "failed", message, message, { args: effectiveArgs, result });
	      return JSON.stringify(result, null, 2);
	    }
	  }

	  async appendUserText(text: string) {
    const prompt = String(text || "").trim();
    if (!prompt) return false;
    this.rememberRecentUserUtterance(prompt);
    this.lastUserUtterance = prompt;
    this.log(`[realtime.proxy] typed text received chars=${prompt.length}`);
    this.sendToCodex({ type: "conversation.input_transcript.delta", delta: prompt });
    this.sendToCodex({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: makeShortRealtimeID("itemtxt"),
      content_index: 0,
      transcript: prompt
    });
    if (this.handleStopCommand(prompt)) return true;

    const recallRoute = conversationRecallRoute(prompt);
    if (recallRoute === "personal") {
      const callID = makeShortRealtimeID("callrec", ++this.autoHandoffSequence);
      void this.tryPersonalRecallRequest(callID, prompt, "message");
      return true;
    }
    if (recallRoute === "clarify") {
      void this.speakDirectText(recallScopeClarificationText());
      return true;
    }

    this.scheduleAutoHandoff(prompt);
    if (this.isGeminiLive()) {
      return this.sendGeminiText(prompt);
    }

    const upstream = await this.ensureUpstream();
    if (!upstream) return false;
    this.sendUpstream({
      type: "conversation.item.create",
      item: {
        type: "message",
        role: "user",
        content: [
          {
            type: "input_text",
            text: prompt
          }
        ]
      }
    });
    this.requestOpenAIResponseCreate("agent result");
    this.scheduleOpenAIDirectResultAudioRetry("agent result");
    return true;
  }

  private pruneHandledKnowledgePrompts() {
    const cutoff = Date.now() - 90_000;
    for (const [prompt, timestamp] of this.handledKnowledgePrompts) {
      if (timestamp < cutoff) this.handledKnowledgePrompts.delete(prompt);
    }
  }

  private rememberKnowledgeHandled(prompt: string, reason: string) {
    const normalized = normalizeRealtimeIntent(prompt);
    if (!normalized) return;
    this.pruneHandledKnowledgePrompts();
    this.handledKnowledgePrompts.set(normalized, Date.now());
    this.log(`[realtime.proxy] knowledge handled route=${reason} chars=${normalized.length}`);
  }

  private wasKnowledgeHandled(prompt: string) {
    const normalized = normalizeRealtimeIntent(prompt);
    if (!normalized) return false;
    this.pruneHandledKnowledgePrompts();
    return this.handledKnowledgePrompts.has(normalized);
  }

  private knowledgeDedupeKeys(name: string, args: JsonObject) {
    const keys = new Set<string>();
    const utterance = this.lastUserUtterance.trim();
    // Scope the utterance key by tool name: one spoken sentence legitimately
    // triggers multi-step flows (read_today then daily_items, search then read),
    // so only the SAME tool repeating for the same utterance is a duplicate.
    if (utterance) keys.add(`${name} utterance ${utterance}`);
    // Targeted edits legitimately hit the SAME task several times in a row with
    // different arguments ("add details", then "turn them into steps", then
    // "rename it"). Keying those on the task text vetoed the second edit as a
    // duplicate — and the model then claimed the change was "already made".
    // Same-utterance and identical-args repeats are still deduped below.
    const isTargetedEdit = name === "knowledge_update_daily_item"
      || name === "knowledge_complete_daily_item";
    if (!isTargetedEdit) {
      const primaryText = stringValue(
        args.title,
        args.text,
        args.task,
        args.query,
        args.prompt,
        args.item,
        args.dayID,
        args.date
      );
      if (primaryText) keys.add(`${name} ${primaryText}`);
    }
    keys.add(`${name} ${JSON.stringify(args)}`);
    return Array.from(keys);
  }

  private wasKnowledgeRequestHandled(name: string, args: JsonObject) {
    return this.knowledgeDedupeKeys(name, args).some((key) => this.wasKnowledgeHandled(key));
  }

  private rememberKnowledgeRequestHandled(name: string, args: JsonObject, reason: string) {
    for (const key of this.knowledgeDedupeKeys(name, args)) {
      this.rememberKnowledgeHandled(key, reason);
    }
    if (!/pending/i.test(reason)) this.rememberKnowledgeContext();
  }

  private rememberKnowledgeContext(prompt = this.lastUserUtterance) {
    const cleanPrompt = String(prompt || "").trim();
    if (!cleanPrompt) return;
    this.lastKnowledgePrompt = cleanPrompt;
    this.lastKnowledgePromptAt = Date.now();
  }

  private recentKnowledgePrompt() {
    if (!this.lastKnowledgePrompt || Date.now() - this.lastKnowledgePromptAt > 2 * 60_000) return "";
    return this.lastKnowledgePrompt;
  }

  private personalRecallCacheKey(args: JsonObject) {
    const primaryText = stringValue(
      args.query,
      args.question,
      args.prompt,
      args.text,
      this.lastUserUtterance,
      JSON.stringify(args)
    );
    const context = stringValue(args.context, args.recentContext, args.liveContext);
    return normalizeRealtimeIntent(`knowledge_personal_recall ${primaryText}\n${context}`);
  }

  private prunePersonalRecallCache() {
    const cutoff = Date.now() - personalRecallResultCacheMs;
    for (const [key, entry] of this.personalRecallCache) {
      if (entry.updatedAt < cutoff) this.personalRecallCache.delete(key);
    }
  }

  private async existingPersonalRecallResult(args: JsonObject) {
    this.prunePersonalRecallCache();
    const key = this.personalRecallCacheKey(args);
    if (!key) return undefined;
    const existing = this.personalRecallCache.get(key);
    if (!existing) return undefined;
    if (existing.result !== undefined) return existing.result;
    // Callers await this outside their try/catch; a rejected in-flight recall
    // must resolve to undefined so they fall through to a fresh run instead of
    // leaving the tool call without any output.
    if (existing.promise) return existing.promise.catch(() => undefined);
    return undefined;
  }

  private async runPersonalRecall(
    args: JsonObject,
    run: () => Promise<unknown>
  ) {
    this.prunePersonalRecallCache();
    const key = this.personalRecallCacheKey(args);
    // While a recall actually runs, concurrent model-initiated knowledge
    // searches are deferred (see the personalRecallInFlight guard) so the
    // model cannot narrate a contradictory "found nothing" from a stale
    // parallel search. Cache hits are instant and skip the flag.
    if (!key) {
      this.personalRecallInFlightSince = Date.now();
      return run().finally(() => {
        this.personalRecallInFlightSince = null;
      });
    }
    const existing = this.personalRecallCache.get(key);
    if (existing?.result !== undefined) {
      this.log("[realtime.proxy] reused completed personal recall result");
      return existing.result;
    }
    if (existing?.promise) {
      this.log("[realtime.proxy] joined active personal recall result");
      return existing.promise;
    }
    const entry: PersonalRecallCacheEntry = { updatedAt: Date.now() };
    this.personalRecallInFlightSince = Date.now();
    entry.promise = run()
      .finally(() => {
        this.personalRecallInFlightSince = null;
      })
      .then((result) => {
        if (isFailedPersonalRecallResult(result)) {
          // Do not replay a failed recall (Spark down, no sourced answer) for
          // 5 minutes; the next ask should retry fresh.
          this.personalRecallCache.delete(key);
          entry.promise = undefined;
          return result;
        }
        entry.result = result;
        entry.promise = undefined;
        entry.updatedAt = Date.now();
        return result;
      })
      .catch((error) => {
        this.personalRecallCache.delete(key);
        throw error;
      });
    this.personalRecallCache.set(key, entry);
    return entry.promise;
  }

  private notifyDirectWork(
    callID: string,
    toolName: string,
    status: "running" | "completed" | "failed",
    detail: string,
    error?: string,
    extra?: { args?: JsonObject; result?: unknown }
  ) {
    const prompt = this.lastUserUtterance.trim() || detail || toolName;
    if (status === "running") this.markContinuityOwnedExternally();
    this.configProvider().directWork?.onEvent({
      callID,
      toolName,
      status,
      prompt,
      detail,
      error,
      args: extra?.args,
      result: extra?.result
    });
  }

  private knowledgeUnavailableText(callID: string) {
    const message = "Knowledge access is off. Enable Knowledge in Settings to search saved notes, tasks, reminders, and memory.";
    this.notifyDirectWork(callID, "knowledge_access", "failed", message, message);
    return message;
  }

  private startDirectWorkProgress(
    callID: string,
    toolName: string,
    args?: JsonObject
  ) {
    const label = toolName.replace(/^knowledge_/, "").replace(/_/g, " ");
    const messages = toolName === "knowledge_personal_recall"
      ? [
        personalRecallRunningDetail(args),
        "Still checking saved context...",
        "Waiting for Spark recall to finish..."
      ]
      : [
        `Still running ${label}...`,
        `Waiting for ${label} to finish...`
      ];
    let index = 0;
    const sendProgress = () => {
      const detail = messages[Math.min(index, messages.length - 1)] || `Still running ${label}...`;
      index += 1;
      this.notifyDirectWork(callID, toolName, "running", detail, undefined, { args });
      this.log(`[realtime.proxy] direct work progress tool=${toolName} call_id=${callID} detail=${detail}`);
    };
    const first = setTimeout(sendProgress, 1_200);
    const interval = setInterval(sendProgress, 4_500);
    unrefTimer(first);
    unrefTimer(interval);
    return () => {
      clearTimeout(first);
      clearInterval(interval);
    };
  }

  private realtimeProvider() {
    return this.configProvider().provider || "openaiRealtime";
  }

  private isGeminiLive() {
    return this.realtimeProvider() === "geminiLive";
  }

  private currentVoiceState(): RealtimeDelegationRouteInput["voiceState"] {
    if (this.quiet) return "quiet";
    if (this.openAIResponseActive || this.geminiAudioItemID) return "speaking";
    return "listening";
  }

  private routerDelegationDecision(
    result: RealtimeDelegationRouteResult,
    baseDecision: Extract<DelegationDecision, { allow: true }>,
    source: RealtimeDelegationRouteSource
  ): DelegationDecision {
    const decision = routerDecisionName(result?.decision);
    const confidence = routerConfidence(result?.confidence);
    const responseText = stringValue(result?.responseText);
    const reason = stringValue(result?.reason, `router ${decision}`);

    if (decision === "delegate") {
      if (confidence < 0.7) return routerFallbackDecision(source, `router low confidence ${confidence.toFixed(2)}`);
      const routedPrompt = contextualizeRealtimeDelegationPrompt(stringValue(result?.taskText, baseDecision.prompt), this.lastDelegationPrompt);
      const normalizedPrompt = normalizeRealtimeIntent(routedPrompt);
      if (!normalizedPrompt) return routerFallbackDecision(source, "router empty task");
      return { allow: true, prompt: routedPrompt, normalizedPrompt };
    }

    if (decision === "clarify") {
      return {
        allow: false,
        output: responseText || "Ask one short clarification question before starting the background agent.",
        createResponse: true,
        reason
      };
    }

    if (decision === "ignore") {
      return {
        allow: false,
        output: responseText || "This does not need a response or background agent task. Wait for the user.",
        createResponse: Boolean(responseText),
        reason
      };
    }

    if (decision === "control") {
      return {
        allow: false,
        output: responseText || "Follow the user's voice control request. Do not start the background agent.",
        createResponse: Boolean(responseText),
        reason
      };
    }

    return {
      allow: false,
      output: responseText || "Answer this directly from the current conversation context. Do not start the background agent.",
      createResponse: true,
      reason
    };
  }

  private async routeRealtimeDelegation(rawPrompt: string, source: RealtimeDelegationRouteSource): Promise<DelegationDecision> {
    const delegationMode = this.configProvider().delegationMode || "autoHardTasksOnly";
    if (delegationMode === "neverDelegate") {
      return {
        allow: false,
        output: "Live Voice is set to answer directly. Do not start the background agent.",
        createResponse: true,
        reason: "delegation disabled"
      };
    }
    const baseDecision = decideRealtimeDelegation(rawPrompt, this.pendingHandoffs.size > 0, this.lastDelegationPrompt, {
      blockRealtimeKnowledgeTasks: true,
      recentKnowledgePrompt: this.recentKnowledgePrompt()
    });
    if (!baseDecision.allow) return baseDecision;
    if (this.wasKnowledgeHandled(baseDecision.prompt)) {
      return {
        allow: false,
        output: "This request was already handled by an OpenAssist knowledge tool. Do not start the background agent.",
        createResponse: false,
        reason: "already handled by knowledge"
      };
    }
    if (delegationMode === "alwaysDelegate") return baseDecision;

    const router = this.configProvider().delegationRouter;
    if (!router?.route || isHighConfidenceRealtimeDelegation(baseDecision.prompt, source)) return baseDecision;

    const startedAt = Date.now();
    const config = this.configProvider();
    const agentLabel = config.handoff?.agentLabel || "Codex";
    try {
      const result = await router.route({
        source,
        provider: this.realtimeProvider(),
        agentLabel,
        prompt: rawPrompt,
        proposedTaskText: baseDecision.prompt,
        lastDelegationPrompt: this.lastDelegationPrompt,
        lastDelegationResult: this.lastDelegationResult,
        hasActiveHandoff: this.pendingHandoffs.size > 0,
        voiceState: this.currentVoiceState()
      });
      const routedDecision = this.routerDelegationDecision(result, baseDecision, source);
      const decision = routerDecisionName(result?.decision);
      const confidence = routerConfidence(result?.confidence);
      this.log(
        `[realtime.proxy] delegation router decision=${decision} allow=${String(routedDecision.allow)} confidence=${confidence.toFixed(2)} source=${source} elapsedMs=${Date.now() - startedAt} reason=${stringValue(result?.reason).slice(0, 120)}`
      );
      return routedDecision;
    } catch (error) {
      this.log(
        `[realtime.proxy] delegation router unavailable; using deterministic decision source=${source} elapsedMs=${Date.now() - startedAt}: ${error instanceof Error ? error.message : String(error)}`
      );
      return baseDecision;
    }
  }

  // A delegated run that dies without ever sending its "background agent
  // finished" message would otherwise gate delegation forever ("already
  // working"). Treat a handoff with no progress for 10 minutes as dead.
  private evictStaleHandoffs() {
    const staleAfterMs = 10 * 60_000;
    for (const handoff of this.taskCoordinator.evictStale(staleAfterMs, this.taskScopeKey())) {
      this.taskAbortControllers.get(handoff.taskID)?.abort();
      this.taskAbortControllers.delete(handoff.taskID);
      this.log(`[realtime.proxy] evicted stale delegated task task_id=${handoff.taskID} promptChars=${handoff.prompt.length}`);
      void this.persistDelegatedTask(handoff);
    }
    this.notifyTasksIdleIfNeeded();
  }

  private async delegatedTaskStatusText() {
    this.evictStaleHandoffs();
    const handoff = this.taskCoordinator.latestRelevant(this.taskScopeKey());
    if (!handoff) {
      return "No delegated task is running right now.";
    }

    if (handoff.state === "completed") {
      const result = compactRealtimeStatusText(handoff.result, 700);
      return result
        ? `${handoff.agentLabel} finished the task. Result: ${result}`
        : `${handoff.agentLabel} finished the task.`;
    }
    if (handoff.state === "failed") {
      return `${handoff.agentLabel} could not finish the task: ${compactRealtimeStatusText(handoff.error, 700)}`;
    }
    if (handoff.state === "cancelled") {
      return `${handoff.agentLabel} task was cancelled.`;
    }

    const now = Date.now();
    const elapsed = formatRealtimeElapsed(now - handoff.startedAt);
    const staleElapsed = formatRealtimeElapsed(now - handoff.updatedAt);
    const latest = compactRealtimeStatusText(handoff.lastActivity || latestStatusLine(handoff.backendText), 500);
    // Report every running task, not just the newest — with side-by-side
    // delegation the user may have several in flight.
    const otherHandoffs = this.taskCoordinator.active(this.taskScopeKey()).filter((entry) => entry.taskID !== handoff.taskID);
    const lines = [
      `${handoff.agentLabel || "Agent"} is still working for ${elapsed}.`,
      handoff.prompt ? `Task: ${compactRealtimeStatusText(handoff.prompt, 360)}` : "",
      latest ? `Latest update: ${latest}` : "No detailed progress update has arrived yet.",
      now - handoff.updatedAt > 120_000 ? `No new progress has arrived for ${staleElapsed}. It may be stuck.` : "",
      ...otherHandoffs.map((entry) => `Also running: ${compactRealtimeStatusText(entry.prompt, 200)} (${formatRealtimeElapsed(now - entry.startedAt)}).`),
      otherHandoffs.length
        ? `${otherHandoffs.length} other ${otherHandoffs.length === 1 ? "task is" : "tasks are"} also running.`
        : ""
    ].filter(Boolean);
    return lines.join("\n");
  }

  async cancelDelegatedTask(taskID?: string) {
    this.evictStaleHandoffs();
    const task = taskID
      ? this.taskCoordinator.get(taskID)
      : this.taskCoordinator.latestActive(this.taskScopeKey());
    if (task?.scopeKey !== this.taskScopeKey()) return "No delegated task is running right now.";
    if (!task) return "No delegated task is running right now.";
    this.taskCoordinator.cancel(task.taskID, "Cancelled by the user.");
    this.taskAbortControllers.get(task.taskID)?.abort();
    this.taskAbortControllers.delete(task.taskID);
    try {
      await this.configProvider().handoff?.cancel?.(task.taskID);
    } catch (error) {
      this.log(`[realtime.proxy] delegated task cancel adapter failed task_id=${task.taskID}: ${error instanceof Error ? error.message : String(error)}`);
    }
    await this.persistDelegatedTask(task);
    this.taskCoordinator.markDelivery(task.taskID, "delivered");
    this.publishSessionSnapshot("delegated task cancelled");
    this.notifyTasksIdleIfNeeded();
    return `${task.agentLabel} task was cancelled.`;
  }

  ownsDelegatedTask(taskID: string) {
    return this.taskCoordinator.get(taskID)?.scopeKey === this.taskScopeKey();
  }

  hasActiveDelegatedTasks() {
    return this.taskCoordinator.activeCount(undefined, this.taskScopeKey()) > 0;
  }

  isVoiceClosed() {
    return this.closed;
  }

  private notifyTasksIdleIfNeeded() {
    if (!this.hasActiveDelegatedTasks()) this.onTasksIdle(this);
  }

  private async ensureGeminiLive() {
    if (this.geminiSession) return this.geminiSession;
    if (this.geminiFailureMessage) {
      this.sendToCodex({ type: "error", error: { message: this.geminiFailureMessage } });
      return null;
    }
    if (this.upstreamReady) return this.upstreamReady as Promise<GeminiLiveSession | null>;

    this.upstreamReady = (async () => {
    const config = this.configProvider();
    const apiKey = config.apiKey?.trim();
    if (!apiKey) {
      this.sendToCodex({
        type: "error",
        error: { message: "Add a Google Gemini API key in Settings > Voice & Dictation." }
      });
      return null;
    }

    const startedAt = Date.now();
    const { GoogleGenAI, Modality } = await import("@google/genai") as unknown as {
      GoogleGenAI: new (options: { apiKey: string }) => {
        live: {
          connect: (request: {
            model: string;
            config: unknown;
            callbacks: {
              onopen: () => void;
              onmessage: (message: unknown) => void;
              onerror: (event: unknown) => void;
              onclose: (event: unknown) => void;
            };
          }) => Promise<GeminiLiveSession>;
        };
      };
      Modality: { AUDIO: unknown };
    };
	    const ai = new GoogleGenAI({ apiKey });
	    const model = config.model?.trim() || defaultGeminiLiveModel;
      const continuity = config.continuity;
      const instructionVersion = createHash("sha256")
        .update(`live-voice-continuity-v1\u0000${realtimeInstructions(
          this.codexInstructions,
          Boolean(config.knowledge?.enabled),
          config.handoff?.agentLabel || "Codex"
        )}`)
        .digest("hex")
        .slice(0, 20);
      this.geminiResumeKey = continuity
        ? geminiResumptionCacheKey({
            threadKey: continuity.threadKey,
            model,
            voice: config.voice || defaultGeminiLiveVoice,
            instructionVersion
          })
        : "";
      this.geminiHistoryRestored = false;
      this.geminiResumeHandleUsed = false;
      let resumeHandle = this.geminiResumeKey ? geminiResumptionHandles.get(this.geminiResumeKey) : undefined;
      const connectAndConfirm = async (handle?: string) => {
        let attemptSession: GeminiLiveSession | undefined;
        let setupState: "pending" | "ready" | "failed" = "pending";
        let resolveSetup: (() => void) | undefined;
        let rejectSetup: ((error: Error) => void) | undefined;
        const setup = new Promise<void>((resolve, reject) => {
          resolveSetup = resolve;
          rejectSetup = reject;
        });
        const callbacks = {
          onopen: () => this.log(`[realtime.proxy] Gemini Live websocket opened model=${model}`),
          onmessage: (message: unknown) => {
            if (jsonObject(message)?.setupComplete && setupState === "pending") {
              setupState = "ready";
              resolveSetup?.();
            }
            void this.onGeminiLiveMessage(message).catch((error: unknown) => {
              this.log(`[realtime.proxy] Gemini Live message handler failed: ${error instanceof Error ? error.message : String(error)}`);
            });
          },
          onerror: (event: unknown) => {
            const error = jsonObject(event);
            const message = stringValue(error?.message, jsonObject(error?.error)?.message, event) || "Gemini Live connection failed.";
            if (setupState === "pending") {
              setupState = "failed";
              rejectSetup?.(new Error("Gemini Live setup failed."));
              return;
            }
            if (setupState === "failed") return;
            this.log("[realtime.proxy] Gemini Live websocket error");
            if (isFatalGeminiLiveCloseReason(message)) this.geminiFailureMessage = message;
            this.sendToCodex({ type: "error", error: { message } });
          },
          onclose: (event: unknown) => {
            const close = jsonObject(event);
            const reason = stringValue(close?.reason) || "no reason";
            if (setupState === "pending") {
              setupState = "failed";
              rejectSetup?.(new Error("Gemini Live closed before setup completed."));
              return;
            }
            if (setupState === "failed") return;
            this.log("[realtime.proxy] Gemini Live websocket closed");
            if (attemptSession && this.geminiSession === attemptSession) {
              this.geminiSession = undefined;
              this.upstreamReady = undefined;
              this.interruptContinuityTurn();
              this.finishGeminiAudio("connection-closed");
            }
            if (reason !== "no reason" && isFatalGeminiLiveCloseReason(reason)) {
              this.geminiFailureMessage = `Gemini Live connection failed: ${reason}`;
              this.sendToCodex({ type: "error", error: { message: this.geminiFailureMessage } });
            }
          }
        };
        attemptSession = await ai.live.connect({
          model,
          config: geminiLiveSessionConfig(
            Modality,
            config,
            this.codexInstructions,
            handle,
            handle ? undefined : this.continuityContext()
          ),
          callbacks
        });
        const timer = setTimeout(() => {
          if (setupState !== "pending") return;
          setupState = "failed";
          rejectSetup?.(new Error("Gemini Live setup timed out."));
        }, geminiSetupTimeoutMs);
        unrefTimer(timer);
        try {
          await setup;
          return attemptSession;
        } catch (error) {
          try {
            attemptSession.close();
          } catch {
            // Best effort cleanup before a fresh connection attempt.
          }
          throw error;
        } finally {
          clearTimeout(timer);
        }
      };
      let session: GeminiLiveSession;
      try {
        session = await connectAndConfirm(resumeHandle);
      } catch (error) {
        if (!resumeHandle) throw error;
        geminiResumptionHandles.delete(this.geminiResumeKey);
        resumeHandle = undefined;
        this.geminiResumeHandleUsed = false;
        this.log("[realtime.proxy] Gemini Live resumption failed; retrying with bounded text context");
        session = await connectAndConfirm();
      }
	    this.geminiResumeHandleUsed = Boolean(resumeHandle);
	    if (this.geminiFailureMessage) {
      try {
        session.close();
      } catch {
        // Best effort cleanup after Gemini rejected the session.
      }
      return null;
	    }
	    this.geminiSession = session;
	    this.restoreGeminiHistory();
	    this.log(`[realtime.proxy] Gemini Live connected model=${model} elapsedMs=${Date.now() - startedAt}`);
    return session;
    })().catch((error) => {
      const message = error instanceof Error ? error.message : "Gemini Live connection failed.";
      if (isFatalGeminiLiveCloseReason(message)) this.geminiFailureMessage = message;
      this.log(`[realtime.proxy] Gemini Live connect failed: ${message}`);
      this.sendToCodex({ type: "error", error: { message } });
      return null;
    }).finally(() => {
      if (!this.geminiSession) this.upstreamReady = undefined;
    });

    return this.upstreamReady as Promise<GeminiLiveSession | null>;
  }

  private async ensureUpstream() {
    if (this.isGeminiLive()) return this.ensureGeminiLive();
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
          // A rejected handshake (bad key, no project access, wrong model) will not
          // succeed on retry — mark it fatal so we do not reconnect in a loop.
          this.fatalUpstreamError = true;
          this.sendToCodex({ type: "error", error: { message: connectionErrorMessage } });
          rejectConnection?.(new Error(connectionErrorMessage));
          ws.terminate();
        });
      });
      ws.on("close", (_code, reason) => {
        const message = reason?.toString() || connectionErrorMessage || "no reason";
        this.log(`[realtime.proxy] OpenAI websocket closed: ${message}`);
        this.stopKeepAlive();
        if (this.upstream === ws) this.upstream = undefined;
        this.upstreamReady = undefined;
        this.configProvider().connection?.onEvent({ type: "upstream_closed", reason: message });
        this.scheduleUpstreamReconnect();
      });

      await new Promise<void>((resolve, reject) => {
        rejectConnection = reject;
        const timer = setTimeout(() => reject(new Error("OpenAI Realtime connection timed out.")), 15_000);
        ws.once("open", () => {
          rejectConnection = undefined;
          clearTimeout(timer);
          this.reconnectAttempts = 0;
          this.startKeepAlive(ws);
          resolve();
        });
        ws.once("error", (error) => {
          rejectConnection = undefined;
          clearTimeout(timer);
          reject(connectionErrorMessage ? new Error(connectionErrorMessage) : error);
        });
      });

      this.updateOpenAISession();
      // Speak any task results that queued up while the socket was down.
      this.drainParallelResults();
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

  // Keep the OpenAI realtime socket warm so an idle pause cannot trigger a silent
  // server-side close. ws.ping() is a no-op control frame the server answers with pong.
  private startKeepAlive(ws: WebSocket) {
    this.stopKeepAlive();
    this.keepAliveTimer = setInterval(() => {
      if (ws.readyState !== WebSocket.OPEN) {
        this.stopKeepAlive();
        return;
      }
      try {
        ws.ping();
      } catch {
        // Best effort; a failed ping will surface through the close handler.
      }
    }, upstreamKeepAliveIntervalMs);
    if (typeof this.keepAliveTimer.unref === "function") this.keepAliveTimer.unref();
  }

  private stopKeepAlive() {
    if (!this.keepAliveTimer) return;
    clearInterval(this.keepAliveTimer);
    this.keepAliveTimer = undefined;
  }

  // When the OpenAI socket drops unexpectedly (not a user stop, not a fatal auth
  // error), reconnect automatically with a short exponential backoff instead of
  // dying and forcing the user back to push-to-talk.
  private scheduleUpstreamReconnect() {
    if (this.closed) return;
    if (this.isGeminiLive()) return;
    if (this.fatalUpstreamError) {
      this.log("[realtime.proxy] not reconnecting: fatal upstream error");
      return;
    }
    if (this.reconnectTimer) return;
    if (this.upstream || this.upstreamReady) return;
    if (this.reconnectAttempts >= maxUpstreamReconnectAttempts) {
      this.log(`[realtime.proxy] giving up reconnect after ${this.reconnectAttempts} attempts`);
      this.sendToCodex({
        type: "error",
        error: { message: "Live Voice lost its connection and could not reconnect. Please restart Live Voice." }
      });
      return;
    }
    const attempt = this.reconnectAttempts + 1;
    this.reconnectAttempts = attempt;
    const delay = Math.min(upstreamReconnectBaseDelayMs * 2 ** (attempt - 1), upstreamReconnectMaxDelayMs);
    this.log(`[realtime.proxy] scheduling upstream reconnect attempt=${attempt} delayMs=${delay}`);
    this.configProvider().connection?.onEvent({ type: "upstream_reconnect_scheduled", attempt, delayMs: delay });
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      if (this.closed || this.upstream || this.upstreamReady) return;
      void this.ensureUpstream().then((upstream) => {
        if (upstream) {
          this.log(`[realtime.proxy] upstream reconnected attempt=${attempt}`);
          this.configProvider().connection?.onEvent({ type: "upstream_reconnected", attempt });
        } else {
          this.configProvider().connection?.onEvent({
            type: "upstream_reconnect_failed",
            attempt,
            message: "OpenAI Realtime reconnect attempt did not return an upstream socket."
          });
        }
      });
    }, delay);
    if (typeof this.reconnectTimer.unref === "function") this.reconnectTimer.unref();
  }

  private async onCodexMessage(payload: string) {
    const message = parseJSON(payload);
    const event = jsonObject(message);
    if (!event) return;

    if (event.type === "session.update") {
      const session = jsonObject(event.session) ?? {};
      this.codexInstructions = stringValue(session.instructions);
      const audio = jsonObject(session.audio);
      const input = jsonObject(audio?.input);
      const format = jsonObject(input?.format);
      const configuredSampleRate = Number(format?.rate);
      if (Number.isFinite(configuredSampleRate) && configuredSampleRate > 0) {
        this.sampleRate = configuredSampleRate;
      }
      const upstream = await this.ensureUpstream();
      if (!upstream) return;
      this.sendToCodex({
        type: "session.updated",
        session: {
          id: stringValue(session.id) || `sess_openassist_${Date.now()}`,
          instructions: this.isGeminiLive()
            ? "Open Assist realtime proxy is connected to Gemini Live."
            : "Open Assist realtime proxy is connected to OpenAI Realtime."
        }
      });
      if (!this.isGeminiLive()) this.updateOpenAISession();
      return;
    }

    if (event.type === "conversation.handoff.append") {
      this.appendHandoff(event);
      return;
    }

    if (await this.handleHandoffFinishedItem(event)) {
      return;
    }

    if (this.isLocalMessageHandoffOutput(event)) return;

    const userText = conversationItemUserText(event);
    if (userText && this.pendingHandoffs.size > 0 && isBackendProgressMessage(userText)) {
      this.appendTextToLatestHandoff(userText);
      this.log(`[realtime.proxy] swallowed backend progress while delegated task is running: ${userText.slice(0, 160)}`);
      return;
    }
    if (userText && !isBackendProgressMessage(userText) && !isCodexFinalResultMessage(userText)) {
      if (!this.handleStopCommand(userText)) this.scheduleAutoHandoff(userText);
    }

    if (event.type === "response.create" && this.quiet) return;
    if (event.type === "response.cancel") this.interruptContinuityTurn();

	    if (this.isGeminiLive()) {
      await this.onGeminiCodexMessage(event, userText);
      return;
    }

    const upstream = await this.ensureUpstream();
    if (!upstream) return;
    this.sendUpstream(event);
  }

  private async onGeminiCodexMessage(event: JsonObject, userText: string) {
	    if (event.type === "response.cancel") {
	      this.interruptContinuityTurn();
	      this.finishGeminiAudio("cancelled");
      this.sendToCodex({ type: "output_audio_buffer.cleared" });
      return;
    }

    const session = await this.ensureGeminiLive();
    if (!session) return;

    if (event.type === "input_audio_buffer.append") {
      const audio = stringValue(event.audio, event.delta);
      if (audio) {
        this.beginGeminiResponseTurn();
        session.sendRealtimeInput({
          audio: {
            data: audio,
            mimeType: `audio/pcm;rate=${this.sampleRate || 24000}`
          }
        });
      }
      return;
    }

    if (userText) {
      this.beginGeminiResponseTurn();
      session.sendRealtimeInput({ text: userText });
    }
  }

  private async onGeminiLiveMessage(message: unknown) {
	    const event = jsonObject(message);
	    if (!event) return;

    const resumptionUpdate = jsonObject(event.sessionResumptionUpdate);
    const newHandle = stringValue(resumptionUpdate?.newHandle);
    if (this.geminiResumeKey && resumptionUpdate?.resumable === true && newHandle) {
      geminiResumptionHandles.set(this.geminiResumeKey, newHandle);
    }

	    if (event.setupComplete) {
	      this.log("[realtime.proxy] Gemini Live setup complete");
	      if (this.geminiSession) this.restoreGeminiHistory();
	      return;
	    }

    const toolCall = jsonObject(event.toolCall);
    const functionCalls = Array.isArray(toolCall?.functionCalls) ? toolCall.functionCalls : [];
    if (functionCalls.length) {
      await this.onGeminiToolCalls(functionCalls);
    }

    const content = jsonObject(event.serverContent);
    if (!content) return;

	    if (content.interrupted) {
	      this.log("[realtime.proxy] Gemini Live interrupted");
	      this.interruptContinuityTurn();
      this.sendToCodex({
        type: "input_audio_buffer.speech_started",
        item_id: `item_gemini_interrupt_${Date.now()}`
      });
      this.finishGeminiAudio("interrupted");
      this.sendToCodex({ type: "output_audio_buffer.cleared" });
      return;
    }

    const inputTranscription = jsonObject(content.inputTranscription);
    const inputTranscript = stringValue(inputTranscription?.text);
	    if (inputTranscript) {
	      this.geminiInputTranscript = appendTranscriptChunk(this.geminiInputTranscript, inputTranscript);
	      this.geminiContinuityItemID ||= makeShortRealtimeID("gemturn", ++this.continuityTurnSequence);
	      this.beginContinuityUser("geminiLive", this.geminiInputTranscript, this.geminiContinuityItemID);
	      this.log(`[realtime.proxy] Gemini input transcript updated chars=${this.geminiInputTranscript.length}`);
      if (!this.handleStopCommand(this.geminiInputTranscript)) this.scheduleAutoHandoff(this.geminiInputTranscript);
      this.sendToCodex({
        type: "conversation.item.input_audio_transcription.completed",
        item_id: `item_gemini_input_${Date.now()}`,
        content_index: 0,
        transcript: this.geminiInputTranscript
      });
    }

    const outputTranscription = jsonObject(content.outputTranscription);
    const outputTranscript = stringValue(outputTranscription?.text);
    if (outputTranscript) {
      this.geminiOutputTranscript = appendTranscriptChunk(this.geminiOutputTranscript, outputTranscript);
    }

    const modelTurn = jsonObject(content.modelTurn);
    const parts = Array.isArray(modelTurn?.parts) ? modelTurn.parts : [];
    for (const rawPart of parts) {
      const part = jsonObject(rawPart);
      if (!part) continue;
      const text = stringValue(part.text);
      if (text && !part.thought) {
        this.geminiOutputTranscript = appendTranscriptChunk(this.geminiOutputTranscript, text);
      }
      const inlineData = jsonObject(part.inlineData);
      const data = stringValue(inlineData?.data);
      if (data) {
        this.sendGeminiAudioDelta(Buffer.from(data, "base64"));
      }
    }

    if ((content.turnComplete || content.generationComplete) && !this.geminiTurnFinished) {
      this.geminiTurnFinished = true;
      this.finishGeminiTurn();
    }
  }

	  private async onGeminiToolCalls(functionCalls: unknown[]) {
	    if (functionCalls.length) {
	      if (this.geminiInputTranscript.trim()) {
	        this.geminiContinuityItemID ||= makeShortRealtimeID("gemturn", ++this.continuityTurnSequence);
	        this.beginContinuityUser("geminiLive", this.geminiInputTranscript, this.geminiContinuityItemID);
	      }
	      this.markContinuityOwnedExternally();
	    }
	    const responses: JsonObject[] = [];
	    let gatedToolSpeech = false;
	    for (const rawCall of functionCalls) {
	      const call = jsonObject(rawCall);
	      if (!call) continue;
	      const name = stringValue(call.name);
	      if (!name) continue;
	      const callID = stringValue(call.id, call.call_id) || makeShortRealtimeID("gemcall");
	      const args = jsonObject(call.args) ?? jsonObject(parseJSON(stringValue(call.arguments))) ?? {};
	      if (isAnswerBearingRealtimeTool(name) && !this.reserveVoiceToolCall(callID)) {
	        responses.push({ id: callID, name, response: { output: "This voice turn is already being handled." } });
	        continue;
	      }
	      if (isAnswerBearingRealtimeTool(name)) {
	        gatedToolSpeech = true;
	        this.toolGateDropActive = true;
	        this.transition("toolPending", `gemini_function_call:${name}`);
	        this.finishGeminiAudio("function-call");
	        this.sendToCodex({ type: "output_audio_buffer.cleared" });
	      }
	      if (name === "wait_for_user") {
	        responses.push({ id: callID, name, response: { output: "Waiting for the user." } });
	        continue;
      }

	      if (name === "set_listening_mode") {
	        const mode = stringValue(args.mode, args.state).toLowerCase();
	        this.quiet = /quiet|mute|pause|stop|off|not.listening/.test(mode);
	        this.refreshSessionState(this.quiet ? "gemini quiet mode" : "gemini listening mode");
	        responses.push({ id: callID, name, response: { output: this.quiet ? "Quiet mode is on." : "Listening mode is on." } });
        if (this.quiet) {
          // Cut any answer that is currently playing and clear the renderer's
          // audio buffer so going quiet takes effect immediately.
          this.finishGeminiAudio("quiet");
          this.sendToCodex({ type: "output_audio_buffer.cleared" });
        } else {
          this.drainParallelResults();
        }
        continue;
      }

	      if (name === "get_delegated_task_status") {
	        this.claimVoiceTurn("status", callID);
	        responses.push({ id: callID, name, response: { output: await this.delegatedTaskStatusText() } });
	        continue;
	      }

	      if (name === "cancel_delegated_task") {
	        this.claimVoiceTurn("cancel", callID);
	        responses.push({ id: callID, name, response: { output: await this.cancelDelegatedTask() } });
	        continue;
	      }

	      if (name === "request_codex_image_generation") {
	        responses.push({
	          id: callID,
	          name,
	          response: { output: await this.codexImageGenerationToolOutput(callID, args, this.geminiInputTranscript || this.lastUserUtterance) }
	        });
	        continue;
	      }

	      if (name.startsWith("knowledge_")) {
	        if (!this.claimVoiceTurn("knowledge", callID)) {
	          responses.push({ id: callID, name, response: { output: "This voice turn is already being handled." } });
	          continue;
	        }
        if (isCasualRealtimeGreeting(this.geminiInputTranscript || this.lastUserUtterance)) {
          responses.push({ id: callID, name, response: { output: "The user only greeted you. Reply naturally in one short sentence. Do not use knowledge tools for this." } });
          continue;
        }
        const knowledge = this.configProvider().knowledge;
        if (!knowledge?.enabled) {
          responses.push({ id: callID, name, response: { output: this.knowledgeUnavailableText(callID) } });
          continue;
        }
        const effectiveArgs = name === "knowledge_personal_recall"
          ? this.personalRecallArgs(args, this.geminiInputTranscript || this.lastUserUtterance)
          : args;
        const promptSnippet = this.geminiInputTranscript || this.lastUserUtterance || JSON.stringify(args);
        // A memory recall is already running for this turn: a parallel search
        // (often carrying the PREVIOUS utterance's query) must not race it and
        // narrate a contradictory "found nothing" before the recall answers.
        if (
          name === "knowledge_search_everything"
          && this.personalRecallInFlightSince
          && Date.now() - this.personalRecallInFlightSince < 30_000
        ) {
          this.log(`[realtime.proxy] deferred ${name} while personal recall in flight promptChars=${promptSnippet.length}`);
          responses.push({
            id: callID,
            name,
            response: { output: "A saved-memory recall for this request is already running. Wait for its result and answer only from it. Do not tell the user nothing was found." }
          });
          continue;
        }
        if (this.wasKnowledgeRequestHandled(name, effectiveArgs)) {
          if (name === "knowledge_personal_recall") {
            const cachedResult = await this.existingPersonalRecallResult(effectiveArgs);
            if (cachedResult !== undefined) {
              this.log(`[realtime.proxy] reused duplicate Gemini personal recall promptChars=${promptSnippet.length}`);
              this.notifyDirectWork(callID, name, "completed", knowledgeCompletionDetail(name, cachedResult), undefined, { args: effectiveArgs, result: cachedResult });
              responses.push({ id: callID, name, response: { output: JSON.stringify(cachedResult, null, 2) } });
              continue;
            }
            this.log(`[realtime.proxy] stale Gemini personal recall dedupe; running recall promptChars=${promptSnippet.length}`);
          } else {
            this.log(`[realtime.proxy] ignored duplicate Gemini knowledge ${name} promptChars=${promptSnippet.length}`);
            responses.push({
              id: callID,
              name,
              response: {
                output: "This exact request already ran a moment ago, so it was skipped. Do NOT tell the user you just made a change — nothing new was written. If the user asked for something different, call the tool again with the new arguments; otherwise refer to the earlier result."
              }
            });
            continue;
          }
        }
        if (name === "knowledge_personal_recall") {
          const query = stringValue(effectiveArgs.query, effectiveArgs.question, effectiveArgs.prompt, effectiveArgs.text);
          const recallRoute = recallRouteForToolCall(query, this.geminiInputTranscript || this.lastUserUtterance);
          if (recallRoute === "none") {
            responses.push({ id: callID, name, response: { output: notPersonalRecallToolText() } });
            continue;
          }
          if (recallRoute === "clarify") {
            responses.push({ id: callID, name, response: { output: recallScopeClarificationText() } });
            continue;
          }
          if (recallRoute === "current") {
            responses.push({ id: callID, name, response: { output: currentConversationRecallText() } });
            continue;
          }
        }
        const runningDetail = name === "knowledge_personal_recall"
          ? personalRecallRunningDetail(effectiveArgs)
          : `Running ${name.replace(/^knowledge_/, "").replace(/_/g, " ")}.`;
        this.notifyDirectWork(callID, name, "running", runningDetail, undefined, { args: effectiveArgs });
        const stopProgress = this.startDirectWorkProgress(callID, name, effectiveArgs);
        try {
          const result = name === "knowledge_personal_recall"
            ? await this.runPersonalRecall(effectiveArgs, () => knowledge.call(name, effectiveArgs))
            : await knowledge.call(name, effectiveArgs);
          this.clearAutoHandoff();
          this.rememberKnowledgeRequestHandled(name, effectiveArgs, name);
          this.notifyDirectWork(callID, name, "completed", knowledgeCompletionDetail(name, result), undefined, { args: effectiveArgs, result });
          responses.push({ id: callID, name, response: { output: JSON.stringify(result, null, 2) } });
        } catch (error) {
          const message = error instanceof Error ? error.message : "Knowledge access failed.";
          this.notifyDirectWork(callID, name, "failed", message, message);
          responses.push({ id: callID, name, response: { output: message } });
        } finally {
          stopProgress();
        }
        continue;
      }

      if (name === "delegate_parallel_tasks") {
        if (!this.claimVoiceTurn("delegate", callID)) {
          responses.push({ id: callID, name, response: { output: "This voice turn is already being handled." } });
          continue;
        }
        const ack = await this.startParallelDelegation(callID, args);
        responses.push({ id: callID, name, response: { output: ack } });
        continue;
      }

      if (name !== "background_agent") {
        responses.push({ id: callID, name, response: { output: `Unknown tool: ${name}` } });
        continue;
      }

		      const rawPrompt = stringValue(args.prompt, args.task, this.geminiInputTranscript) || "Continue the user's requested task.";
		      const requestedProject = stringValue(args.project, args.projectID, args.projectName).trim();
	      if (realtimePromptWantsImageGeneration(rawPrompt)) {
	        responses.push({
	          id: callID,
	          name,
	          response: {
	            output: await this.codexImageGenerationToolOutput(callID, { ...args, prompt: rawPrompt }, rawPrompt)
	          }
	        });
	        continue;
	      }
	      if (this.pendingHandoffs.size > 0 && isDelegatedStatusQuestion(rawPrompt)) {
        responses.push({ id: callID, name, response: { output: await this.delegatedTaskStatusText() } });
        continue;
      }
      const userPrompt = (this.geminiInputTranscript || this.lastUserUtterance).trim();
      if (shouldUseDirectKnowledgeInsteadOfAgent(userPrompt)) {
        if (!this.claimVoiceTurn("knowledge", callID)) {
          responses.push({ id: callID, name, response: { output: "This voice turn is already being handled." } });
          continue;
        }
        const knowledge = this.configProvider().knowledge;
        if (!knowledge?.enabled) {
          responses.push({ id: callID, name, response: { output: this.knowledgeUnavailableText(callID) } });
          continue;
        }
        if (await this.tryDirectKnowledgeRequest(callID, userPrompt, "function")) continue;
        responses.push({
          id: callID,
          name,
          response: { output: "Use the matching OpenAssist knowledge tool for this note, planner, task, or reminder request. Do not start a background agent." }
        });
        continue;
      }
      const recallRoute = conversationRecallRoute(rawPrompt);
      if (recallRoute !== "none") {
        if (recallRoute === "clarify") {
          responses.push({ id: callID, name, response: { output: recallScopeClarificationText() } });
          continue;
        }
        if (recallRoute === "current") {
          responses.push({ id: callID, name, response: { output: currentConversationRecallText() } });
          continue;
        }
        const knowledge = this.configProvider().knowledge;
        if (!knowledge?.enabled) {
          responses.push({
            id: callID,
            name,
            response: { output: this.knowledgeUnavailableText(callID) }
          });
          continue;
        }
        const recallArgs = this.personalRecallArgs({ query: rawPrompt }, rawPrompt);
        this.notifyDirectWork(callID, "knowledge_personal_recall", "running", personalRecallRunningDetail(recallArgs), undefined, { args: recallArgs });
        const stopProgress = this.startDirectWorkProgress(callID, "knowledge_personal_recall", recallArgs);
        try {
          const result = await this.runPersonalRecall(recallArgs, () => knowledge.call("knowledge_personal_recall", recallArgs));
          this.clearAutoHandoff();
          this.rememberKnowledgeRequestHandled("knowledge_personal_recall", recallArgs, "knowledge_personal_recall");
          this.notifyDirectWork(callID, "knowledge_personal_recall", "completed", knowledgeCompletionDetail("knowledge_personal_recall", result), undefined, { args: recallArgs, result });
          this.log(`[realtime.proxy] Gemini recall background_agent rerouted to knowledge_personal_recall call_id=${callID}`);
          responses.push({ id: callID, name, response: { output: JSON.stringify(result, null, 2) } });
        } catch (error) {
          const message = error instanceof Error ? error.message : "Personal recall failed.";
          this.notifyDirectWork(callID, "knowledge_personal_recall", "failed", message, message, { args: recallArgs });
          responses.push({ id: callID, name, response: { output: message } });
        } finally {
          stopProgress();
        }
        continue;
      }
      this.evictStaleHandoffs();
      const decision = await this.routeRealtimeDelegation(rawPrompt, "tool_call");
      if (!decision.allow) {
        responses.push({
          id: callID,
          name,
          response: { output: decision.output }
        });
        continue;
      }

	      if (await this.tryDirectKnowledgeRequest(callID, decision.prompt, "message")) continue;
	      if (requestedProject && this.configProvider().parallelDelegation) {
	        const ack = await this.startParallelDelegation(callID, { tasks: [{ prompt: decision.prompt, project: requestedProject }] });
	        responses.push({ id: callID, name, response: { output: ack } });
	        continue;
	      }
        this.log(`[realtime.proxy] Gemini Live background_agent routed call_id=${callID}`);
	      if (!this.claimVoiceTurn("delegate", callID)) {
	        responses.push({ id: callID, name, response: { output: "This voice turn is already being handled." } });
	        continue;
	      }
	      const start = this.startCodexHandoff(callID, decision.prompt, "message");
	      responses.push({
          id: callID,
          name,
          response: {
	          output: start.message
          }
        });
    }

	    if (responses.length) {
	      await this.sendGeminiToolResponses(responses);
	    }
	    if (gatedToolSpeech) this.clearToolGate("gemini tool responses sent");
	  }

	  private sendGeminiAudioDelta(audio: Buffer) {
	    if (!audio.length) return;
    // Quiet mode: Gemini Live has no server-side "don't auto-reply" switch like
    // OpenAI's create_response flag, so the mic keeps streaming (the model must
	    // still hear "start listening again") but its spoken output is dropped here.
	    if (this.quiet) return;
	    if (this.toolGateDropActive) return;
	    if (!this.geminiAudioItemID) {
	      this.geminiAudioItemID = `item_gemini_audio_${Date.now()}`;
	      this.markOpenAIResponseActive();
	    }
    this.sendToCodex({
      type: "response.output_audio.delta",
      item_id: this.geminiAudioItemID,
      delta: audio.toString("base64"),
      sample_rate: 24000,
      channels: 1,
      samples_per_channel: Math.floor(audio.length / 2)
    });
  }

	  private finishGeminiTurn() {
	    const audioItemID = this.geminiAudioItemID || `item_gemini_audio_${Date.now()}`;
	    const wasDelegatedResultNarration = this.parallelResultSpeaking;
    this.finishGeminiAudio("turn-complete");
	    const transcript = this.geminiOutputTranscript.trim();
    if (transcript) {
      this.sendToCodex({
        type: "response.output_audio_transcript.done",
        item_id: audioItemID,
        output_index: 0,
        content_index: 0,
        transcript
      });
	    }
	    if (!wasDelegatedResultNarration && this.geminiInputTranscript.trim() && transcript) {
	      this.geminiContinuityItemID ||= makeShortRealtimeID("gemturn", ++this.continuityTurnSequence);
	      this.beginContinuityUser("geminiLive", this.geminiInputTranscript, this.geminiContinuityItemID);
	      this.claimVoiceTurn("direct", audioItemID);
	      this.completeContinuityTurn(transcript);
	    } else if (wasDelegatedResultNarration && transcript) {
	      this.log("[realtime.proxy] skipped continuity persistence for delegated Gemini narration");
	    }
	    this.sendToCodex({ type: "response.done", response: { id: `resp_gemini_${Date.now()}`, output: [] } });
	    this.geminiInputTranscript = "";
	    this.geminiOutputTranscript = "";
	    this.geminiContinuityItemID = "";
	    this.resetCurrentVoiceTurn();
  }

  private beginGeminiResponseTurn() {
    if (!this.geminiTurnFinished) return;
    this.geminiTurnFinished = false;
	    this.geminiInputTranscript = "";
	    this.geminiOutputTranscript = "";
	    this.geminiContinuityItemID = "";
  }

  private finishGeminiAudio(reason: string) {
    if (this.geminiAudioItemID) {
      this.sendToCodex({
        type: "response.output_audio.done",
        item_id: this.geminiAudioItemID,
        reason
      });
    }
	    this.geminiAudioItemID = "";
	    this.clearOpenAIResponseActive();
	    this.flushOpenAIResponseCreate();
    if (reason === "turn-complete") {
      this.onParallelNarrationEnded();
    } else {
      // Stop, interrupt, quiet, or connection loss must not immediately start
      // narrating the next queued result over the user; just unblock the queue
      // so it drains at the next natural pause (turn complete / unmute).
      this.parallelResultSpeaking = false;
    }
  }

  private async sendGeminiText(text: string) {
    const session = await this.ensureGeminiLive();
    if (!session) return false;
    this.beginGeminiResponseTurn();
    session.sendRealtimeInput({ text });
    return true;
  }

  async appendVisualContext(context: RealtimeVisualContext) {
    const images = context.images
      .map((image) => {
        const parts = dataURLParts(image.dataURL, image.mimeType || "image/png");
        if (!parts?.base64) return null;
        return {
          ...image,
          mimeType: image.mimeType || parts.mimeType,
          base64: parts.base64,
          dataURL: image.dataURL
        };
      })
      .filter((image): image is RealtimeVisualContextImage & { mimeType: string; base64: string } => Boolean(image));
    if (!images.length) return false;

    if (this.isGeminiLive()) {
      const session = await this.ensureGeminiLive();
      if (!session) return false;
      for (const image of images) {
        session.sendRealtimeInput({
          video: {
            data: image.base64,
            mimeType: image.mimeType
          }
        });
      }
      this.log(`[realtime.proxy] sent ${images.length} image(s) to Gemini Live visual context`);
      return true;
    }

    const upstream = await this.ensureUpstream();
    if (!upstream) return false;
    const content: JsonObject[] = [];
    const text = stringValue(context.text);
    if (text) {
      content.push({
        type: "input_text",
        text
      });
    }
    for (const image of images) {
      content.push({
        type: "input_image",
        image_url: image.dataURL
      });
    }
    this.sendUpstream({
      type: "conversation.item.create",
      item: {
        type: "message",
        role: "user",
        content
      }
    });
    if (context.createResponse && !this.quiet) this.requestOpenAIResponseCreate();
    this.log(`[realtime.proxy] sent ${images.length} image(s) to OpenAI Realtime visual context`);
    return true;
  }

  private async sendGeminiToolResponses(functionResponses: JsonObject[]) {
    const session = await this.ensureGeminiLive();
    if (!session) return false;
    this.beginGeminiResponseTurn();
    session.sendToolResponse({ functionResponses });
    return true;
  }

  private async onOpenAIMessage(payload: string) {
    const message = parseJSON(payload);
    const event = jsonObject(message);
    if (!event) return;

    if (event.type === "error") {
      const error = jsonObject(event.error);
      const messageText = stringValue(error?.message, event.message) || "OpenAI Realtime error.";
      if (isBenignRealtimeCancelError(messageText)) {
        this.clearOpenAIResponseActive();
        this.log(`[realtime.proxy] ignored stale cancel: ${messageText}`);
        return;
      }
      if (/active response in progress/i.test(messageText)) {
        // The server says a response is already running; sync our flag to match so
        // we stop sending premature response.create calls. The pending one will be
        // flushed when the active response's response.done arrives (or the watchdog).
        this.markOpenAIResponseActive();
        this.openAIResponseCreatePending ??= { reason: "active-response error", response: {} };
        this.log(`[realtime.proxy] delayed response.create after active-response error: ${messageText}`);
        return;
      }
      this.log(`[realtime.proxy] OpenAI error: ${messageText}`);
      this.sendToCodex({ type: "error", error: { message: messageText } });
      return;
    }

    if (event.type === "session.created") return;
    if (event.type === "session.updated") {
      this.restoreOpenAIHistory();
      return;
    }

	    if (event.type === "response.created") {
	      const response = jsonObject(event.response);
	      this.activeOpenAIResponseID = stringValue(response?.id, event.response_id);
	      this.markOpenAIResponseActive();
	      this.sendToCodex(event);
	      return;
	    }

    if (event.type === "input_audio_buffer.speech_started") {
      const hasAssistantAudio = Boolean(this.audioItemID);
      if (hasAssistantAudio || this.openAIResponseActive) this.interruptContinuityTurn();
      this.log(
        `[realtime.audio-diag] speech_started ${hasAssistantAudio ? "interrupt" : "ignored"} ` +
        `(responseActive=${String(this.openAIResponseActive)} audioItem=${hasAssistantAudio ? this.audioItemID : "none"})`
      );
      if (hasAssistantAudio) {
        this.truncateOpenAIAudio();
        this.sendToCodex(event);
      }
      return;
    }

    if (event.type === "conversation.item.input_audio_transcription.completed") {
      const transcript = stringValue(event.transcript, event.text);
      if (transcript) {
        this.openAIOutputTranscript = "";
        this.beginContinuityUser("openaiRealtime", transcript, stringValue(event.item_id, event.itemId));
        this.log(`[realtime.proxy] OpenAI input transcript completed chars=${transcript.length}`);
      }
      if (transcript && (isBackendProgressMessage(transcript) || isCodexFinalResultMessage(transcript))) {
        this.log(`[realtime.proxy] ignored backend transcript from OpenAI chars=${transcript.length}`);
      } else if (transcript && this.handleStopCommand(transcript)) {
        // User asked the assistant to stop; already silenced. Do not start a task.
      } else if (transcript) {
        this.scheduleAutoHandoff(transcript);
      }
      this.sendToCodex(event);
      return;
    }

    if (event.type === "response.output_audio_transcript.delta" || event.type === "response.audio_transcript.delta") {
      const delta = stringValue(event.delta, event.transcript, event.text);
      if (delta) this.openAIOutputTranscript = appendTranscriptChunk(this.openAIOutputTranscript, delta);
      this.sendToCodex(event);
      return;
    }

    if (event.type === "response.output_audio_transcript.done" || event.type === "response.audio_transcript.done") {
      const transcript = stringValue(event.transcript, event.text);
      if (transcript) this.openAIOutputTranscript = transcript;
      this.sendToCodex(event);
      return;
    }

	    if (event.type === "response.output_item.added") {
	      const item = jsonObject(event.item);
	      if (item?.type === "function_call") {
	        this.markContinuityOwnedExternally();
	        this.gateAnswerBearingToolSpeech(event, item);
	        if (isAnswerBearingFunctionCallItem(item)) {
	          this.reserveVoiceToolCall(stringValue(item.call_id));
	        }
	      }
	      this.sendToCodex(event);
	      return;
	    }

	    if (event.type === "response.output_audio.delta" || event.type === "response.audio.delta") {
	      if (this.shouldDropGatedOpenAIAudio(event)) {
	        this.log("[realtime.proxy] dropped gated OpenAI audio delta for tool-call response");
	        return;
	      }
	      const delta = stringValue(event.delta);
	      const itemID = stringValue(event.item_id, this.audioItemID) || `item_openai_audio_${Date.now()}`;
	      const audio = delta ? Buffer.from(delta, "base64") : Buffer.alloc(0);
      if (audio.length) this.clearOpenAIDirectResultAudioRetry();
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
	      if (this.shouldDropGatedOpenAIAudio(event)) {
	        return;
	      }
	      this.sendToCodex({ ...event, type: "response.output_audio.done", item_id: stringValue(event.item_id, this.audioItemID) });
	      this.audioItemID = "";
	      this.audioMs = 0;
      return;
    }

	    if (event.type === "response.output_item.done") {
	      const item = jsonObject(event.item);
	      if (item?.type === "function_call") {
	        this.markContinuityOwnedExternally();
	        this.gateAnswerBearingToolSpeech(event, item);
	        if (isAnswerBearingFunctionCallItem(item)) {
	          this.reserveVoiceToolCall(stringValue(item.call_id));
	        }
	        await this.handleFunctionCall(item);
	        return;
	      }
    }

	    if (event.type === "response.done") {
	      const wasDelegatedResultNarration = this.parallelResultSpeaking;
      // This response has ended, so clear the active flag FIRST. Otherwise any
      // function-call handler below (e.g. a knowledge tool) calls
      // requestOpenAIResponseCreate() while the flag is still set, the spoken reply
      // gets queued as "pending", and a race with incoming audio can leave it stuck.
	      this.audioItemID = "";
	      this.audioMs = 0;
	      this.activeOpenAIResponseID = "";
	      this.clearOpenAIResponseActive();
	      this.sendToCodex(event);
	      const response = jsonObject(event.response);
	      const output = Array.isArray(response?.output) ? response.output : [];
	      const responseStatus = stringValue(response?.status).toLowerCase();
	      if (responseStatus && responseStatus !== "completed") this.interruptContinuityTurn();
	      for (const item of output) {
	        const object = jsonObject(item);
	        if (object?.type === "function_call") {
	          this.markContinuityOwnedExternally();
	          this.gateAnswerBearingToolSpeech(event, object);
	          await this.handleFunctionCall(object);
	        }
	      }
	      const completedTranscript = this.openAIOutputTranscript.trim() || openAIResponseTranscript(response);
	      if (completedTranscript) {
	        this.clearOpenAIDirectResultAudioRetry();
	        if (wasDelegatedResultNarration) {
	          this.log("[realtime.proxy] skipped continuity persistence for delegated OpenAI narration");
	        } else {
	          this.claimVoiceTurn("direct", stringValue(response?.id) || `direct-${Date.now()}`);
	          this.completeContinuityTurn(completedTranscript);
	        }
	      }
	      this.openAIOutputTranscript = "";
	      this.resetCurrentVoiceTurn();
	      this.clearToolGate("response.done");
	      this.flushOpenAIResponseCreate();
	      this.onParallelNarrationEnded();
	      return;
    }

    this.sendToCodex(event);
  }

  private async handleFunctionCall(item: JsonObject) {
    const callID = stringValue(item.call_id);
    if (!callID) {
      this.log(`[realtime.proxy] ignored function call without call_id: ${stringValue(item.name) || "unknown"}`);
      return;
    }
    if (this.handledCalls.has(callID)) return;
    const name = stringValue(item.name);
    if (isAnswerBearingRealtimeTool(name) && !this.reserveVoiceToolCall(callID)) {
      this.sendFunctionOutput(callID, "This voice turn is already being handled.", false);
      return;
    }
    this.handledCalls.add(callID);
    if (this.handledCalls.size > 100) {
      const oldest = this.handledCalls.values().next().value;
      if (oldest) this.handledCalls.delete(oldest);
    }

    if (name === "wait_for_user") {
      this.sendFunctionOutput(callID, "Waiting for the user.", false);
      return;
    }

	    if (name === "set_listening_mode") {
	      const args = jsonObject(parseJSON(stringValue(item.arguments))) ?? {};
	      const mode = stringValue(args.mode, args.state).toLowerCase();
	      this.quiet = /quiet|mute|pause|stop|off|not.listening/.test(mode);
	      this.refreshSessionState(this.quiet ? "quiet mode" : "listening mode");
	      this.sendFunctionOutput(callID, this.quiet ? "Quiet mode is on." : "Listening mode is on.", !this.quiet);
      this.updateOpenAISession();
      // Coming out of quiet mode: speak any parallel-task results that finished while
      // we were muted, so they are not lost.
      if (!this.quiet) this.drainParallelResults();
      return;
    }

	    if (name === "get_delegated_task_status") {
	      this.claimVoiceTurn("status", callID);
	      this.sendFunctionOutput(callID, await this.delegatedTaskStatusText(), true);
	      return;
	    }

	    if (name === "cancel_delegated_task") {
	      this.claimVoiceTurn("cancel", callID);
	      this.sendFunctionOutput(callID, await this.cancelDelegatedTask(), true);
	      return;
	    }

	    if (name === "request_codex_image_generation") {
	      const args = jsonObject(parseJSON(stringValue(item.arguments))) ?? {};
	      this.sendFunctionOutput(callID, await this.codexImageGenerationToolOutput(callID, args, this.lastUserUtterance), true);
	      return;
	    }

	    if (name === "delegate_parallel_tasks") {
	      if (!this.claimVoiceTurn("delegate", callID)) {
	        this.sendFunctionOutput(callID, "This voice turn is already being handled.", false);
	        return;
	      }
	      await this.handleParallelDelegation(callID, item);
	      return;
    }

    if (name.startsWith("knowledge_")) {
      if (!this.claimVoiceTurn("knowledge", callID)) {
        this.sendFunctionOutput(callID, "This voice turn is already being handled.", false);
        return;
      }
      if (isCasualRealtimeGreeting(this.lastUserUtterance)) {
        this.sendFunctionOutput(callID, "The user only greeted you. Reply naturally in one short sentence. Do not use knowledge tools for this.", true);
        return;
      }
      const knowledge = this.configProvider().knowledge;
      if (!knowledge?.enabled) {
        this.sendFunctionOutput(callID, this.knowledgeUnavailableText(callID), true);
        return;
      }
      const args = jsonObject(parseJSON(stringValue(item.arguments))) ?? {};
      const effectiveArgs = name === "knowledge_personal_recall"
        ? this.personalRecallArgs(args, this.lastUserUtterance)
        : args;
      if (
        name === "knowledge_search_everything"
        && this.personalRecallInFlightSince
        && Date.now() - this.personalRecallInFlightSince < 30_000
      ) {
        this.log(`[realtime.proxy] deferred ${name} while personal recall in flight`);
        this.sendFunctionOutput(callID, "A saved-memory recall for this request is already running. Wait for its result and answer only from it. Do not tell the user nothing was found.", true);
        return;
      }
      if (this.wasKnowledgeRequestHandled(name, effectiveArgs)) {
        if (name === "knowledge_personal_recall") {
          const cachedResult = await this.existingPersonalRecallResult(effectiveArgs);
          if (cachedResult !== undefined) {
            this.log("[realtime.proxy] reused duplicate personal recall");
            this.notifyDirectWork(callID, name, "completed", knowledgeCompletionDetail(name, cachedResult), undefined, { args: effectiveArgs, result: cachedResult });
            this.sendFunctionOutput(callID, JSON.stringify(cachedResult, null, 2), true);
            return;
          }
          this.log("[realtime.proxy] stale personal recall dedupe; running recall");
        } else {
          this.log(`[realtime.proxy] ignored duplicate knowledge ${name}`);
          this.sendFunctionOutput(callID, "This exact request already ran a moment ago, so it was skipped. Do NOT tell the user you just made a change — nothing new was written. If the user asked for something different, call the tool again with the new arguments; otherwise refer to the earlier result.", true);
          return;
        }
      }
      if (name === "knowledge_personal_recall") {
        const query = stringValue(effectiveArgs.query, effectiveArgs.question, effectiveArgs.prompt, effectiveArgs.text);
        const recallRoute = recallRouteForToolCall(query, this.lastUserUtterance);
        if (recallRoute === "none") {
          this.sendFunctionOutput(callID, notPersonalRecallToolText(), true);
          return;
        }
        if (recallRoute === "clarify") {
          this.sendFunctionOutput(callID, recallScopeClarificationText(), true);
          return;
        }
        if (recallRoute === "current") {
          this.sendFunctionOutput(callID, currentConversationRecallText(), true);
          return;
        }
      }
      const runningDetail = name === "knowledge_personal_recall"
        ? personalRecallRunningDetail(effectiveArgs)
        : `Running ${name.replace(/^knowledge_/, "").replace(/_/g, " ")}.`;
      this.notifyDirectWork(callID, name, "running", runningDetail, undefined, { args: effectiveArgs });
      const stopProgress = this.startDirectWorkProgress(callID, name, effectiveArgs);
      try {
        const result = name === "knowledge_personal_recall"
          ? await this.runPersonalRecall(effectiveArgs, () => knowledge.call(name, effectiveArgs))
          : await knowledge.call(name, effectiveArgs);
        this.clearAutoHandoff();
        this.rememberKnowledgeRequestHandled(name, effectiveArgs, name);
        this.notifyDirectWork(callID, name, "completed", knowledgeCompletionDetail(name, result), undefined, { args: effectiveArgs, result });
        this.log(`[realtime.audio-diag] knowledge ${name} result sent; requesting spoken reply (active=${String(this.openAIResponseActive)})`);
        this.sendFunctionOutput(callID, JSON.stringify(result, null, 2), true);
      } catch (error) {
        const message = error instanceof Error ? error.message : "Knowledge access failed.";
        this.notifyDirectWork(callID, name, "failed", message, message);
        this.sendFunctionOutput(callID, message, true);
      } finally {
        stopProgress();
      }
      return;
    }

    if (name !== "background_agent") return;

	    this.clearAutoHandoff();
	    const args = jsonObject(parseJSON(stringValue(item.arguments))) ?? {};
	    const rawPrompt = stringValue(args.prompt, args.task, item.arguments) || "Continue the user's requested task.";
	    const requestedProject = stringValue(args.project, args.projectID, args.projectName).trim();
	    if (realtimePromptWantsImageGeneration(rawPrompt)) {
	      this.sendFunctionOutput(callID, await this.codexImageGenerationToolOutput(callID, { ...args, prompt: rawPrompt }, rawPrompt), true);
	      return;
	    }
	    if (this.pendingHandoffs.size > 0 && isDelegatedStatusQuestion(rawPrompt)) {
      this.sendFunctionOutput(callID, await this.delegatedTaskStatusText(), true);
      return;
    }
    const userPrompt = this.lastUserUtterance.trim();
    if (shouldUseDirectKnowledgeInsteadOfAgent(userPrompt)) {
      if (!this.claimVoiceTurn("knowledge", callID)) {
        this.sendFunctionOutput(callID, "This voice turn is already being handled.", false);
        return;
      }
      const knowledge = this.configProvider().knowledge;
      if (!knowledge?.enabled) {
        this.sendFunctionOutput(callID, this.knowledgeUnavailableText(callID), true);
        return;
      }
      if (await this.tryDirectKnowledgeRequest(callID, userPrompt, "function")) return;
      this.sendFunctionOutput(
        callID,
        "Use the matching OpenAssist knowledge tool for this note, planner, task, or reminder request. Do not start a background agent.",
        true
      );
      return;
    }
    const recallRoute = conversationRecallRoute(rawPrompt);
    if (recallRoute !== "none") {
      if (recallRoute === "clarify") {
        this.sendFunctionOutput(callID, recallScopeClarificationText(), true);
        return;
      }
      if (recallRoute === "current") {
        this.sendFunctionOutput(callID, currentConversationRecallText(), true);
        return;
      }
      const knowledge = this.configProvider().knowledge;
      if (!knowledge?.enabled) {
        this.log(`[realtime.proxy] blocked recall background_agent without knowledge promptChars=${rawPrompt.length}`);
        this.sendFunctionOutput(callID, this.knowledgeUnavailableText(callID), true);
        return;
      }
      const recallArgs = this.personalRecallArgs({ query: rawPrompt }, rawPrompt);
      this.notifyDirectWork(callID, "knowledge_personal_recall", "running", personalRecallRunningDetail(recallArgs), undefined, { args: recallArgs });
      const stopProgress = this.startDirectWorkProgress(callID, "knowledge_personal_recall", recallArgs);
      try {
        const result = await this.runPersonalRecall(recallArgs, () => knowledge.call("knowledge_personal_recall", recallArgs));
        this.clearAutoHandoff();
        this.rememberKnowledgeRequestHandled("knowledge_personal_recall", recallArgs, "knowledge_personal_recall");
        this.notifyDirectWork(callID, "knowledge_personal_recall", "completed", knowledgeCompletionDetail("knowledge_personal_recall", result), undefined, { args: recallArgs, result });
        this.log(`[realtime.proxy] rerouted recall background_agent to knowledge_personal_recall call_id=${callID}`);
        this.sendFunctionOutput(callID, JSON.stringify(result, null, 2), true);
      } catch (error) {
        const message = error instanceof Error ? error.message : "Personal recall failed.";
        this.notifyDirectWork(callID, "knowledge_personal_recall", "failed", message, message, { args: recallArgs });
        this.sendFunctionOutput(callID, message, true);
      } finally {
        stopProgress();
      }
      return;
    }
    this.evictStaleHandoffs();
    const decision = await this.routeRealtimeDelegation(rawPrompt, "tool_call");
    if (!decision.allow) {
      this.log(`[realtime.proxy] ignored background_agent (${decision.reason}): ${rawPrompt.slice(0, 160)}`);
      this.sendFunctionOutput(callID, decision.output, decision.createResponse);
      return;
    }

      const duplicatePrompt = Array.from(this.pendingHandoffs.values()).some(
        (handoff) => normalizeRealtimeIntent(handoff.prompt) === decision.normalizedPrompt
      );
      if (duplicatePrompt) {
        this.log(`[realtime.proxy] ignored duplicate background_agent promptChars=${decision.prompt.length}`);
        const agentLabel = this.configProvider().handoff?.agentLabel || "Codex";
        this.sendFunctionOutput(callID, `That ${agentLabel} task is already running. Do not start a duplicate.`, false);
        return;
      }

	      if (await this.tryDirectKnowledgeRequest(callID, decision.prompt, "function")) return;
	      if (requestedProject && this.configProvider().parallelDelegation) {
	        const ack = await this.startParallelDelegation(callID, { tasks: [{ prompt: decision.prompt, project: requestedProject }] });
	        this.sendFunctionOutput(callID, ack, true);
	        return;
	      }
	      if (!this.claimVoiceTurn("delegate", callID)) {
	        this.sendFunctionOutput(callID, "This voice turn is already being handled.", false);
	        return;
	      }
	    const start = this.startCodexHandoff(callID, decision.prompt, "message");
	    this.sendFunctionOutput(callID, start.message, true);
  }

  // Returns true when the transcript is a stop/interrupt phrase. Immediately
  // silences the assistant (truncate audio + cancel the active response) so the
  // user can cut in. A background task that is already running is left to finish.
  private handleStopCommand(transcript: string) {
    const normalized = normalizeRealtimeIntent(transcript);
    if (isDelegatedTaskCancellationRequest(normalized)) return false;
    if (!normalized || !isStopOrDismissal(normalized)) return false;
    this.interruptContinuityTurn();
    this.log("[realtime.proxy] stop phrase heard; silencing assistant");
    this.clearAutoHandoff();
    this.lastAutoHandoffNormalizedPrompt = normalized;
    if (this.isGeminiLive()) {
      this.finishGeminiAudio("user-stop");
      this.sendToCodex({ type: "output_audio_buffer.cleared" });
      return true;
    }
    if (this.openAIResponseActive) {
      this.sendUpstream({ type: "response.cancel" });
      this.clearOpenAIResponseActive();
    }
    this.openAIResponseCreatePending = null;
    this.truncateOpenAIAudio();
    this.sendToCodex({ type: "output_audio_buffer.cleared" });
    return true;
  }

  private scheduleAutoHandoff(transcript: string, turnID = this.currentVoiceTurnID) {
    if (this.quiet) return;
    this.evictStaleHandoffs();
	    this.rememberRecentUserUtterance(transcript);
	    this.lastUserUtterance = transcript;
	    const stableTurnID = turnID || this.continuityTurnID(this.realtimeProvider());
	    if (!this.currentVoiceTurnID) this.currentVoiceTurnID = stableTurnID;
	    if (isDelegatedTaskCancellationRequest(transcript)) {
	      const callID = makeShortRealtimeID("callcancel", ++this.autoHandoffSequence);
	      if (this.claimVoiceTurn("cancel", callID, stableTurnID)) {
	        void this.cancelDelegatedTask().then((text) => this.speakDirectText(text));
	      }
	      return;
	    }
	    if (isDelegatedStatusQuestion(transcript) && this.taskCoordinator.latestRelevant(this.taskScopeKey())) {
	      const callID = makeShortRealtimeID("callstatus", ++this.autoHandoffSequence);
	      if (this.claimVoiceTurn("status", callID, stableTurnID)) {
	        void this.delegatedTaskStatusText().then((text) => this.speakDirectText(text));
	      }
	      return;
	    }
	    if (this.wasKnowledgeHandled(transcript)) return;
	    if (realtimePromptWantsImageGeneration(transcript)) return;
    const decision = decideRealtimeDelegation(transcript, this.pendingHandoffs.size > 0, this.lastDelegationPrompt, {
      blockRealtimeKnowledgeTasks: true,
      recentKnowledgePrompt: this.recentKnowledgePrompt()
    });
	    this.log(
	      `[realtime.proxy] auto route decision allow=${String(decision.allow)} ` +
	      `reason=${decision.allow ? "delegate" : decision.reason} chars=${transcript.length}`
	    );
    if (!decision.allow) {
      if (decision.reason === "conversation recall") {
        const callID = makeShortRealtimeID("callrec", ++this.autoHandoffSequence);
	        if (this.claimVoiceTurn("knowledge", callID, stableTurnID)) {
	          void this.tryPersonalRecallRequest(callID, transcript, "message");
	        }
      } else if (decision.reason === "ambiguous recall scope") {
        void this.speakDirectText(recallScopeClarificationText());
      }
      return;
    }
    if (decision.normalizedPrompt === this.lastAutoHandoffNormalizedPrompt) return;
    this.clearAutoHandoff();
    this.autoHandoffTimer = setTimeout(() => {
      void this.runAutoHandoff(transcript, stableTurnID);
    }, autoHandoffDelayMs);
  }

  private async runAutoHandoff(transcript: string, turnID: string) {
    this.autoHandoffTimer = undefined;
    this.evictStaleHandoffs();
    if (this.delegationStartInFlight) return;
    if (this.wasKnowledgeHandled(transcript)) return;
    if (realtimePromptWantsImageGeneration(transcript)) return;
    this.delegationStartInFlight = true;
    try {
      if (this.openAIOutputTranscript.trim() || this.geminiOutputTranscript.trim()) {
        this.claimVoiceTurn("direct", `direct-${turnID}`, turnID);
        this.log("[realtime.proxy] skipped automatic delegation because the assistant already started a direct reply");
        return;
      }
      const decision = await this.routeRealtimeDelegation(transcript, "auto_transcript");
      if (!decision.allow) return;
      if (this.openAIOutputTranscript.trim() || this.geminiOutputTranscript.trim()) {
        this.claimVoiceTurn("direct", `direct-${turnID}`, turnID);
        this.log("[realtime.proxy] skipped automatic delegation because a direct reply started while routing");
        return;
      }
      const duplicatePrompt = this.taskCoordinator.hasActivePrompt(decision.prompt, this.taskScopeKey());
      if (duplicatePrompt || decision.normalizedPrompt === this.lastAutoHandoffNormalizedPrompt) return;
      const callID = makeShortRealtimeID("calloa", ++this.autoHandoffSequence);
      if (!this.claimVoiceTurn("delegate", callID, turnID)) return;
      this.lastAutoHandoffNormalizedPrompt = decision.normalizedPrompt;
      if (this.openAIResponseActive) {
        this.sendUpstream({ type: "response.cancel" });
        this.clearOpenAIResponseActive();
      }
      this.truncateOpenAIAudio();
      this.log(`[realtime.proxy] auto background_agent promptChars=${decision.prompt.length}`);
      if (await this.tryDirectKnowledgeRequest(callID, decision.prompt, "message")) return;
      const start = this.startCodexHandoff(callID, decision.prompt, "message", {
        sourceTurnID: turnID,
        userText: transcript
      });
      void this.speakDirectText(start.message);
    } finally {
      this.delegationStartInFlight = false;
    }
  }

  private rememberLocalMessageHandoffCallID(callID: string) {
    this.localMessageHandoffCallIDs.add(callID);
    if (this.localMessageHandoffCallIDs.size <= 100) return;
    const oldest = this.localMessageHandoffCallIDs.values().next().value;
    if (oldest) this.localMessageHandoffCallIDs.delete(oldest);
  }

  private latestPendingHandoff() {
    return Array.from(this.pendingHandoffs.values()).at(-1);
  }

  private appendTextToLatestHandoff(text: string) {
    const handoff = this.latestPendingHandoff();
    if (!handoff) return false;
    const next = appendHandoffText(handoff.backendText, text);
    if (next === handoff.backendText) return false;
    handoff.backendText = next;
    handoff.lastActivity = compactRealtimeStatusText(text, 500);
    handoff.updatedAt = Date.now();
    return true;
  }

  private appendHandoff(event: JsonObject) {
    const callID = stringValue(event.handoff_id, event.call_id)
      || this.pendingHandoffs.keys().next().value
      || "";
    const handoff = callID ? this.pendingHandoffs.get(callID) : this.latestPendingHandoff();
    const text = extractRealtimeText(event);
    if (!handoff || !text) {
      this.log(`[realtime.proxy] ignored handoff append call_id=${callID || "none"} textChars=${text.length}`);
      return;
    }
    handoff.backendText = appendHandoffText(handoff.backendText, text);
    handoff.lastActivity = compactRealtimeStatusText(text, 500);
    handoff.updatedAt = Date.now();
    this.log(`[realtime.proxy] buffered agent handoff output call_id=${handoff.callID} chars=${handoff.backendText.length}`);
  }

  private async handleHandoffFinishedItem(event: JsonObject) {
    if (event.type !== "conversation.item.create") return false;
    const item = jsonObject(event.item);
    if (item?.type !== "function_call_output") return false;
    const callID = stringValue(item.call_id, event.call_id)
      || this.pendingHandoffs.keys().next().value
      || "";
    const output = extractRealtimeText(item.output ?? item);
    if (!isBackgroundAgentFinishedOutput(output)) return false;
    const handoff = callID ? this.pendingHandoffs.get(callID) : this.latestPendingHandoff();
    if (!handoff) {
      this.log(`[realtime.proxy] ignored completed handoff with no pending call: ${callID || "none"}`);
      return true;
    }
    await this.completeHandoff(handoff.callID, output);
    return true;
  }

  private isLocalMessageHandoffOutput(event: JsonObject) {
    if (event.type !== "conversation.item.create") return false;
    const item = jsonObject(event.item);
    if (item?.type !== "function_call_output") return false;
    const callID = stringValue(item.call_id, event.call_id);
    if (!callID || !this.localMessageHandoffCallIDs.has(callID)) return false;
    this.log(`[realtime.proxy] swallowed local auto-handoff output: ${callID}`);
    return true;
  }

  private clearAutoHandoff() {
    if (!this.autoHandoffTimer) return;
    clearTimeout(this.autoHandoffTimer);
    this.autoHandoffTimer = undefined;
  }

  private async tryDirectKnowledgeRequest(
    callID: string,
    prompt: string,
    replyMode: PendingHandoff["replyMode"]
  ) {
    if (isCasualRealtimeGreeting(prompt)) return false;
    const shortcut = this.configProvider().directKnowledgeRequest;
    if (!shortcut?.run) return false;
    try {
      const output = (await shortcut.run({ callID, prompt, replyMode }))?.trim();
      if (!output) return false;
      const agentLabel = "OpenAssist";
      this.log(`[realtime.proxy] background_agent handled by direct knowledge request call_id=${callID}`);
      this.clearAutoHandoff();
      this.rememberKnowledgeHandled(prompt, "directKnowledgeRequest");
      this.rememberKnowledgeContext(prompt);
      this.lastDelegationPrompt = prompt;
      this.lastDelegationResult = output.slice(0, 2_000);
      this.sendToCodex({ type: "conversation.input_transcript.delta", delta: prompt });
      if (replyMode === "message") {
        await this.ensureUpstream();
        this.sendAgentResultMessage(output, agentLabel);
      } else {
        this.sendFunctionOutput(callID, output, true, { agentResult: true, agentLabel });
      }
      return true;
    } catch (error) {
      this.log(`[realtime.proxy] direct knowledge request failed: ${error instanceof Error ? error.message : String(error)}`);
      return false;
    }
  }

  private async tryPersonalRecallRequest(
    callID: string,
    prompt: string,
    replyMode: PendingHandoff["replyMode"]
  ) {
    const knowledge = this.configProvider().knowledge;
    if (!knowledge?.enabled) {
      const output = this.knowledgeUnavailableText(callID);
      if (replyMode === "message") {
        await this.ensureUpstream();
        this.sendAgentResultMessage(output, "OpenAssist");
      } else {
        this.sendFunctionOutput(callID, output, true);
      }
      return true;
    }
    const args = this.personalRecallArgs({ query: prompt }, prompt);
    this.rememberKnowledgeHandled(prompt, "knowledge_personal_recall_pending");
    this.rememberKnowledgeRequestHandled("knowledge_personal_recall", args, "knowledge_personal_recall_pending");
    this.notifyDirectWork(callID, "knowledge_personal_recall", "running", personalRecallRunningDetail(args), undefined, { args });
    const stopProgress = this.startDirectWorkProgress(callID, "knowledge_personal_recall", args);
    try {
      const result = await this.runPersonalRecall(args, () => knowledge.call("knowledge_personal_recall", args));
      this.clearAutoHandoff();
      this.rememberKnowledgeRequestHandled("knowledge_personal_recall", args, "knowledge_personal_recall");
      const answer = knowledgeCompletionDetail("knowledge_personal_recall", result);
      this.notifyDirectWork(callID, "knowledge_personal_recall", "completed", answer, undefined, { args, result });
      this.lastDelegationPrompt = prompt;
      this.lastDelegationResult = answer.slice(0, 2_000);
      this.log(`[realtime.proxy] personal recall handled directly call_id=${callID}`);
      if (replyMode === "message") {
        await this.ensureUpstream();
        this.cancelOpenAIResponseBeforeDirectResult("personal recall completed");
        this.sendAgentResultMessage(answer, "OpenAssist Spark Recall");
      } else {
        this.sendFunctionOutput(callID, JSON.stringify(result, null, 2), true);
      }
      return true;
    } catch (error) {
      const message = error instanceof Error ? error.message : "Personal recall failed.";
      this.notifyDirectWork(callID, "knowledge_personal_recall", "failed", message, message, { args });
      if (replyMode === "message") {
        await this.ensureUpstream();
        this.cancelOpenAIResponseBeforeDirectResult("personal recall failed");
        this.sendAgentResultMessage(message, "OpenAssist Spark Recall");
      } else {
        this.sendFunctionOutput(callID, message, true);
      }
      return true;
    } finally {
      stopProgress();
    }
  }

  private startCodexHandoff(
    callID: string,
    prompt: string,
    replyMode: PendingHandoff["replyMode"],
    options: { sourceTurnID?: string; userText?: string; kind?: PendingHandoff["kind"] } = {}
  ) {
    const handoff = this.configProvider().handoff;
    if (!handoff) {
      return { started: false, message: "No background agent is available for this Live Voice session." };
    }
    const sourceTurnID = options.sourceTurnID || this.currentVoiceTurnID || callID;
    const taskID = options.kind === "parallel"
      ? `live-task-${sourceTurnID}-${callID}`
      : `live-task-${sourceTurnID}`;
    const userText = options.userText?.trim()
      || (options.kind === "parallel" ? prompt : this.lastUserUtterance.trim())
      || prompt;
    const started = this.taskCoordinator.start({
      taskID,
      scopeKey: this.taskScopeKey(),
      callID,
      sourceTurnID,
      userText,
      prompt,
      workerProvider: handoff.agentLabel || "Agent",
      replyMode,
      kind: options.kind || "single"
    });
    if (!started.ok) {
      if (started.reason === "duplicate") {
        return { started: false, message: "That task is already running. I will share the result when it finishes." };
      }
      if (started.reason === "limit") {
        return { started: false, message: "Six delegated tasks are already running. Please wait for one to finish." };
      }
      return { started: false, message: "I could not start that task because the request was empty." };
    }

    this.markContinuityOwnedExternally();
    this.lastDelegationPrompt = prompt;
    this.log(`[realtime.proxy] background_agent routed to ${started.task.agentLabel} task_id=${taskID}`);
    this.publishSessionSnapshot("delegated task started");
    this.startExternalHandoff(started.task, handoff);
    return { started: true, task: started.task, message: delegatedTaskStartedText(started.task.agentLabel) };
  }

  private startExternalHandoff(
    task: PendingHandoff,
    handoff: NonNullable<RealtimeProxyConfig["handoff"]>
  ) {
    const controller = new AbortController();
    this.taskAbortControllers.set(task.taskID, controller);
    void (async () => {
      try {
        const rawOutput = await handoff.run({
          taskID: task.taskID,
          sourceTurnID: task.sourceTurnID,
          callID: task.callID,
          prompt: task.prompt,
          replyMode: task.replyMode,
          signal: controller.signal,
          onProgress: (detail) => {
            this.taskCoordinator.updateProgress(task.taskID, detail);
            this.publishSessionSnapshot("delegated task progress");
          }
        });
        const output = typeof rawOutput === "string" ? rawOutput : rawOutput.output;
        const workerProvider = typeof rawOutput === "string" ? "" : rawOutput.workerProvider?.trim() || "";
        const active = this.taskCoordinator.get(task.taskID);
        if (active && workerProvider) {
          active.workerProvider = workerProvider;
          active.agentLabel = workerProvider;
        }
        await this.completeHandoff(task.callID, output);
      } catch (error) {
        const active = this.taskCoordinator.get(task.taskID);
        if (active?.state === "cancelled") return;
        const message = error instanceof Error ? error.message : "The selected provider could not finish the task.";
        await this.failHandoff(task.callID, message);
      } finally {
        this.taskAbortControllers.delete(task.taskID);
      }
    })();
  }

  // OpenAI Realtime entry: parse the tool args, start the parallel run, and send a
  // short function_call_output ack. The real results arrive later via the narration
  // queue (reportTaskResult -> enqueueParallelResult), one spoken reply per task.
  private async handleParallelDelegation(callID: string, item: JsonObject) {
    const args = jsonObject(parseJSON(stringValue(item.arguments))) ?? {};
    const ack = await this.startParallelDelegation(callID, args);
    this.sendFunctionOutput(callID, ack, true);
  }

  // Shared logic for both OpenAI and Gemini paths. Returns the immediate ack text
  // the model should say; queues each task's result as it finishes.
  private async startParallelDelegation(callID: string, args: JsonObject): Promise<string> {
    const config = this.configProvider();
    const agentLabel = config.handoff?.agentLabel || "Codex";
    const parallel = config.parallelDelegation;
    const route = routeParallelDelegation(
      this.parseParallelTasks(args),
      this.pendingHandoffs.size > 0,
      this.lastDelegationPrompt,
      { blockRealtimeKnowledgeTasks: true }
    );
    if (route.action !== "proceed") {
      this.log(`[realtime.proxy] delegate_parallel_tasks guarded call_id=${callID} reason=${route.reason}`);
      if (route.action === "image") {
        return this.codexImageGenerationToolOutput(callID, { prompt: route.prompt }, route.prompt);
      }
      if (route.action === "recall") {
        return this.personalRecallRerouteOutput(callID, route.query, "delegate_parallel_tasks");
      }
      if (route.reason === "delegated status question") {
        return this.delegatedTaskStatusText();
      }
      return route.output;
    }
    this.markContinuityOwnedExternally();
    const tasks = route.tasks.filter((task) => !this.taskCoordinator.hasActivePrompt(task.prompt, this.taskScopeKey()));
    if (!tasks.length) {
      this.log(`[realtime.proxy] delegate_parallel_tasks all duplicates call_id=${callID}`);
      return "That task is already running. Do not start a duplicate; wait for its result.";
    }
    const wasAlreadyBusy = this.taskCoordinator.activeCount(undefined, this.taskScopeKey()) > 0;
    const availableSlots = Math.max(0, 6 - this.taskCoordinator.activeCount());
    if (!availableSlots) return "Six delegated tasks are already running. Please wait for one to finish.";
    const selectedTasks = tasks.slice(0, availableSlots);
    if (!parallel) {
      for (const task of selectedTasks) {
        const subCallID = makeShortRealtimeID("callpar", ++this.autoHandoffSequence);
        this.startCodexHandoff(subCallID, task.prompt, "message", {
          sourceTurnID: this.currentVoiceTurnID || callID,
          kind: "parallel"
        });
      }
      return `Running ${selectedTasks.length} ${selectedTasks.length === 1 ? "task" : "tasks"} with ${agentLabel}. I will share each result when it finishes.`;
    }

    this.clearAutoHandoff();
    const sourceTurnID = this.currentVoiceTurnID || callID;
    const coordinatedTasks = selectedTasks.flatMap((task, index) => {
      const subCallID = `${callID}-${index + 1}`;
      const started = this.taskCoordinator.start({
        taskID: `live-task-${sourceTurnID}-${subCallID}`,
        scopeKey: this.taskScopeKey(),
        callID: subCallID,
        sourceTurnID,
        userText: task.prompt,
        prompt: task.prompt,
        workerProvider: task.provider || agentLabel,
        replyMode: "message",
        kind: "parallel"
      });
      return started.ok ? [{ input: task, task: started.task }] : [];
    });
    if (!coordinatedTasks.length) return "Those tasks are already running.";
    this.publishSessionSnapshot("parallel delegation started");
    this.log(`[realtime.proxy] delegate_parallel_tasks call_id=${callID} count=${coordinatedTasks.length}`);

    void (async () => {
      try {
        const summary = await parallel.run({
          callID,
          tasks: coordinatedTasks.map((entry) => entry.input),
          reportTaskResult: (result) => {
            const coordinated = coordinatedTasks[result.index]?.task;
            if (!coordinated) return;
            const provider = result.agentLabel || result.provider || agentLabel;
            coordinated.workerProvider = provider;
            coordinated.agentLabel = provider;
            const failLabel = result.failed ? " (failed)" : "";
            const where = [result.provider, result.project].filter(Boolean).join(", ");
            const heading = where
              ? `${result.label} — ${where}${failLabel}`
              : `${result.label}${failLabel}`;
            const body = [heading, result.text].filter(Boolean).join("\n");
            if (result.failed) void this.failHandoff(coordinated.callID, result.text || "The task failed.");
            else void this.completeHandoff(coordinated.callID, body);
          }
        });
        if (summary.note) this.log(`[realtime.proxy] parallel delegation note: ${summary.note}`);
      } catch (error) {
        const message = error instanceof Error ? error.message : "Parallel tasks could not be started.";
        this.log(`[realtime.proxy] delegate_parallel_tasks failed: ${message}`);
        for (const coordinated of coordinatedTasks) {
          void this.failHandoff(coordinated.task.callID, message);
        }
      }
    })();

    const max = Math.max(1, parallel.maxTasks || 6);
    const skipped = tasks.length - coordinatedTasks.length;
    const note = skipped > 0 || tasks.length > max
      ? ` ${Math.max(skipped, tasks.length - max)} task(s) could not start because six is the active-task limit.`
      : "";
    if (wasAlreadyBusy) {
      return `Also started: ${coordinatedTasks.map((entry) => entry.input.prompt.slice(0, 80)).join("; ")}.${note} I will share each result when it finishes.`;
    }
    return `Starting ${coordinatedTasks.length} ${coordinatedTasks.length === 1 ? "task" : "tasks"} in parallel with ${agentLabel}.${note} I will share each result when it finishes.`;
  }

  // Run a misrouted recall question through Spark personal recall and return the
  // tool output text, mirroring the background_agent recall reroute.
  private async personalRecallRerouteOutput(callID: string, query: string, sourceTool: string): Promise<string> {
    const knowledge = this.configProvider().knowledge;
    if (!knowledge?.enabled) {
      this.log(`[realtime.proxy] blocked recall ${sourceTool} without knowledge promptChars=${query.length}`);
      return this.knowledgeUnavailableText(callID);
    }
    const recallArgs = this.personalRecallArgs({ query }, query);
    this.notifyDirectWork(callID, "knowledge_personal_recall", "running", personalRecallRunningDetail(recallArgs), undefined, { args: recallArgs });
    const stopProgress = this.startDirectWorkProgress(callID, "knowledge_personal_recall", recallArgs);
    try {
      const result = await this.runPersonalRecall(recallArgs, () => knowledge.call("knowledge_personal_recall", recallArgs));
      this.clearAutoHandoff();
      this.rememberKnowledgeRequestHandled("knowledge_personal_recall", recallArgs, "knowledge_personal_recall");
      this.notifyDirectWork(callID, "knowledge_personal_recall", "completed", knowledgeCompletionDetail("knowledge_personal_recall", result), undefined, { args: recallArgs, result });
      this.log(`[realtime.proxy] rerouted recall ${sourceTool} to knowledge_personal_recall call_id=${callID}`);
      return JSON.stringify(result, null, 2);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Personal recall failed.";
      this.notifyDirectWork(callID, "knowledge_personal_recall", "failed", message, message, { args: recallArgs });
      return message;
    } finally {
      stopProgress();
    }
  }

  private parseParallelTasks(args: JsonObject): Array<{ prompt: string; provider?: string; project?: string }> {
    const rawList = Array.isArray(args.tasks) ? args.tasks : [];
    const tasks: Array<{ prompt: string; provider?: string; project?: string }> = [];
    for (const raw of rawList) {
      const entry = jsonObject(raw);
      if (!entry) continue;
      const prompt = stringValue(entry.prompt, entry.task).trim();
      if (!prompt) continue;
      const provider = stringValue(entry.provider, entry.model).trim();
      const project = stringValue(entry.project, entry.folder, entry.group).trim();
      tasks.push({
        prompt,
        provider: provider || undefined,
        project: project || undefined
      });
    }
    return tasks;
  }

  // Queue a finished-task result for narration. Speaks immediately if nothing is
  // currently being spoken; otherwise it waits its turn so two results never overlap.
  private enqueueParallelResult(taskID: string, text: string, agentLabel: string) {
	    this.parallelResultQueue.push({ taskID, text, agentLabel });
	    this.taskCoordinator.markDelivery(taskID, "queued");
	    this.drainParallelResults();
	  }

  // Speak the next queued result only when the channel is free: not in quiet mode,
  // no active spoken response, and not already mid-narration of a previous result.
  private drainParallelResults() {
    if (this.parallelResultSpeaking) return;
    if (this.quiet) return;
    if (this.openAIResponseActive || this.geminiAudioItemID) return;
    // A reconnecting OpenAI socket silently swallows response.create; leave the
    // queue intact and retry after the reconnect (ensureUpstream drains again).
    if (!this.isGeminiLive() && this.upstream?.readyState !== WebSocket.OPEN) return;
	    const next = this.parallelResultQueue.shift();
	    if (!next) return;
	    this.parallelResultSpeaking = true;
	    this.parallelResultSpeakingTaskID = next.taskID;
	    this.taskCoordinator.markDelivery(next.taskID, "speaking");
	    this.transition("narrating", "parallel result narration");
	    void this.sendAgentResultMessage(next.text, next.agentLabel).then((sent) => {
      if (!sent) {
        // Gemini session unavailable; put the result back and retry at the next
        // drain trigger instead of wedging the queue with speaking=true forever.
	        this.parallelResultQueue.unshift(next);
	        this.parallelResultSpeaking = false;
	        this.parallelResultSpeakingTaskID = "";
	        this.taskCoordinator.markDelivery(next.taskID, "queued");
	        this.refreshSessionState("parallel narration retry queued");
	      }
	    });
    // sendAgentResultMessage requests a spoken response; the speaking flag is cleared
    // and the next item drained when that response ends (response.done / Gemini audio
    // done) via onParallelNarrationEnded().
  }

  // Called when a spoken response finishes, so the next queued parallel result (if any)
  // can start. Hooked from response.done and finishGeminiAudio.
  private onParallelNarrationEnded() {
	    if (this.parallelResultSpeaking) {
	      if (this.parallelResultSpeakingTaskID) {
	        this.taskCoordinator.markDelivery(this.parallelResultSpeakingTaskID, "delivered");
	      }
	      this.parallelResultSpeaking = false;
	      this.parallelResultSpeakingTaskID = "";
	    }
	    if (this.parallelResultQueue.length) {
	      this.drainParallelResults();
	    } else {
	      this.refreshSessionState("parallel narration ended");
	    }
	  }

  private async completeHandoff(callID: string, fallbackOutput = "") {
    const handoff = this.taskCoordinator.getByCallID(callID, this.taskScopeKey());
    if (!handoff) {
      this.log(`[realtime.proxy] ignored completed handoff with no pending call: ${callID}`);
      return;
    }
    if (handoff.state !== "queued" && handoff.state !== "running") {
      this.log(`[realtime.proxy] ignored duplicate completed handoff: ${callID}`);
      return;
    }
    const resultText = String(fallbackOutput || "").replace(/^background agent (finished|completed):?\s*/i, "").trim();
    if (!resultText) {
      await this.failHandoff(callID, "The agent finished without returning an answer.");
      return;
    }
    const completed = this.taskCoordinator.complete(handoff.taskID, resultText);
    if (!completed || completed.state !== "completed") return;
    // Allow the same request to be delegated again after this one finished.
    this.lastAutoHandoffNormalizedPrompt = "";
	    this.publishSessionSnapshot("handoff completed");
    // When other tasks are still running, name the task this result belongs to
    // so the spoken answer can't be mistaken for one of the others.
    const othersStillRunning = this.pendingHandoffs.size > 0 || this.activeParallelDelegations > 0;
    const text = othersStillRunning
      ? `Finished task: ${handoff.prompt.slice(0, 90)}\n${resultText}`
      : resultText;
    this.lastDelegationResult = text.slice(0, 2_000);
    await this.persistDelegatedTask(completed);
    this.notifyTasksIdleIfNeeded();
    if (this.closed || this.codexSocket.readyState !== WebSocket.OPEN) {
      this.taskCoordinator.markDelivery(completed.taskID, "delivered");
      return;
    }
    await this.ensureUpstream();
    if (handoff.replyMode === "message") {
      // Route through the narration queue: it survives quiet mode (results are
      // spoken after unmute instead of dropped) and never overlaps other results.
      this.enqueueParallelResult(completed.taskID, text, handoff.agentLabel);
    } else {
      this.sendFunctionOutput(callID, text, true, { agentResult: true, agentLabel: handoff.agentLabel });
      this.taskCoordinator.markDelivery(completed.taskID, "delivered");
    }
  }

  private async failHandoff(callID: string, error: string) {
    const handoff = this.taskCoordinator.getByCallID(callID, this.taskScopeKey());
    if (!handoff || (handoff.state !== "queued" && handoff.state !== "running")) return;
    const failed = this.taskCoordinator.fail(handoff.taskID, error);
    if (!failed) return;
    this.lastAutoHandoffNormalizedPrompt = "";
    this.publishSessionSnapshot("handoff failed");
    await this.persistDelegatedTask(failed);
    this.notifyTasksIdleIfNeeded();
    const text = `${failed.agentLabel} could not finish the task: ${failed.error}`;
    if (this.closed || this.codexSocket.readyState !== WebSocket.OPEN) {
      this.taskCoordinator.markDelivery(failed.taskID, "delivered");
      return;
    }
    if (failed.replyMode === "message") {
      this.enqueueParallelResult(failed.taskID, text, failed.agentLabel);
    } else {
      this.sendFunctionOutput(failed.callID, text, true, { agentResult: true, agentLabel: failed.agentLabel });
      this.taskCoordinator.markDelivery(failed.taskID, "delivered");
    }
  }

  private async persistDelegatedTask(task: PendingHandoff) {
    if (!this.taskCoordinator.markPersisted(task.taskID)) return;
    const assistantText = task.state === "completed"
      ? task.result
      : task.error || `${task.agentLabel} could not finish the task.`;
    const continuity = this.configProvider().continuity;
    if (!continuity || !task.userText.trim() || !assistantText.trim()) return;
    try {
      await continuity.onCompletedTurn({
        id: task.taskID,
        userText: task.userText,
        assistantText,
        ownedExternally: true,
        provider: this.realtimeProvider(),
        source: "delegated",
        workerProvider: task.workerProvider,
        taskState: task.state === "failed" || task.state === "cancelled" ? task.state : "completed",
        taskStartedAt: task.startedAt,
        taskFinishedAt: task.finishedAt,
        progressEntries: task.progressEntries.map((entry) => ({ ...entry })).slice(-20)
      });
    } catch {
      continuity.onStatus?.({
        status: "persist_failed",
        message: "The agent finished, but its result could not be added to the Voice Log."
      });
    }
  }

	  private async sendAgentResultMessage(output: string, agentLabel: string): Promise<boolean> {
	    if (this.isGeminiLive()) {
	      return this.sendGeminiText(directSpeechInstructions(output, agentLabel));
	    }
	    const response: JsonObject = {
	      instructions: directSpeechInstructions(output, agentLabel),
      input: []
    };
    this.requestOpenAIResponseCreate("agent result", response);
    this.scheduleOpenAIDirectResultAudioRetry("agent result", response);
    return true;
  }

  private cancelOpenAIResponseBeforeDirectResult(reason: string) {
    if (this.isGeminiLive()) return;
    if (!this.openAIResponseActive && !this.audioItemID) return;
    this.log(`[realtime.proxy] cancelling active OpenAI response before direct result: ${reason}`);
    if (this.openAIResponseActive) this.sendUpstream({ type: "response.cancel" });
    this.openAIResponseCreatePending = null;
    this.clearOpenAIResponseActive();
    this.truncateOpenAIAudio();
    this.sendToCodex({ type: "output_audio_buffer.cleared" });
  }

  private async speakDirectText(text: string) {
    const cleanText = compactRealtimeStatusText(text, 500);
    if (!cleanText) return false;
    const instruction = `Say exactly this to the user, and do not add anything else:\n${cleanText}`;
    if (this.isGeminiLive()) {
      return this.sendGeminiText(instruction);
    }
    const upstream = await this.ensureUpstream();
    if (!upstream) return false;
    const response: JsonObject = {
      instructions: instruction,
      input: []
    };
    this.requestOpenAIResponseCreate("direct text", response);
    this.scheduleOpenAIDirectResultAudioRetry("direct text", response);
    return true;
  }

	  private sendFunctionOutput(
    callID: string,
    output: string,
    createResponse: boolean,
    options: { agentResult?: boolean; agentLabel?: string } = {}
	  ) {
	    if (this.isGeminiLive()) {
	      const agentLabel = options.agentLabel || "Agent";
	      const text = options.agentResult ? delegatedTaskFunctionOutput(agentLabel) : output;
	      void this.sendGeminiToolResponses([
	        {
	          id: callID,
          name: "background_agent",
          response: { output: text }
	        }
	      ]);
	      if (createResponse && !this.quiet) {
	        void (options.agentResult
	          ? this.sendAgentResultMessage(output, agentLabel)
	          : this.sendGeminiText(text));
	      }
	      return;
	    }
	    const agentLabel = options.agentLabel || "Agent";
	    this.sendUpstream({
	      type: "conversation.item.create",
	      item: {
	        type: "function_call_output",
	        call_id: callID,
	        output: options.agentResult ? delegatedTaskFunctionOutput(agentLabel) : output
	      }
	    });
	    if (options.agentResult) {
	      if (createResponse && !this.quiet) void this.sendAgentResultMessage(output, agentLabel);
	      return;
	    }
	    if (createResponse && !this.quiet) {
	      this.requestOpenAIResponseCreate("function output");
	    }
  }

  // Mark a response active and arm the watchdog. Any code path that believes a
  // response started should go through here so the flag can never get stuck on.
	  private markOpenAIResponseActive() {
	    this.openAIResponseActive = true;
	    this.armOpenAIResponseWatchdog();
	    this.refreshSessionState("response active");
	  }

  private armOpenAIResponseWatchdog() {
    if (this.openAIResponseWatchdog) clearTimeout(this.openAIResponseWatchdog);
    this.openAIResponseWatchdog = setTimeout(() => {
      this.openAIResponseWatchdog = undefined;
      if (!this.openAIResponseActive) return;
      // If audio is still streaming, this is a long but real answer — re-arm and wait,
      // do not cut it off.
      if (this.audioItemID) {
        this.armOpenAIResponseWatchdog();
        return;
      }
	      this.log("[realtime.proxy] response watchdog fired; clearing stuck active-response flag");
	      this.clearOpenAIResponseActive();
      this.flushOpenAIResponseCreate();
      this.onParallelNarrationEnded();
    }, openAIResponseWatchdogMs);
    if (typeof this.openAIResponseWatchdog.unref === "function") this.openAIResponseWatchdog.unref();
  }

	  private clearOpenAIResponseActive() {
	    this.openAIResponseActive = false;
	    if (this.openAIResponseWatchdog) {
	      clearTimeout(this.openAIResponseWatchdog);
	      this.openAIResponseWatchdog = undefined;
	    }
	    this.refreshSessionState("response inactive");
	  }

  private clearOpenAIDirectResultAudioRetry() {
    if (!this.openAIDirectResultAudioRetry) return;
    clearTimeout(this.openAIDirectResultAudioRetry);
    this.openAIDirectResultAudioRetry = undefined;
  }

  private scheduleOpenAIDirectResultAudioRetry(reason: string, response: JsonObject = {}) {
    if (this.isGeminiLive() || this.quiet) return;
    this.clearOpenAIDirectResultAudioRetry();
    this.openAIDirectResultAudioRetry = setTimeout(() => {
      this.openAIDirectResultAudioRetry = undefined;
      if (this.closed || this.quiet || this.isGeminiLive()) return;
      if (this.audioItemID) return;
      this.log(`[realtime.proxy] retrying OpenAI spoken direct result; no audio started reason=${reason}`);
      this.sendUpstream({ type: "response.cancel" });
      this.clearOpenAIResponseActive();
      this.openAIResponseCreatePending = null;
      this.requestOpenAIResponseCreate(`${reason} retry`, response);
    }, openAIDirectResultAudioRetryMs);
    unrefTimer(this.openAIDirectResultAudioRetry);
  }

  private requestOpenAIResponseCreate(reason = "response", response: JsonObject = {}) {
    if (this.quiet) return;
    if (this.isGeminiLive()) return;
    if (this.openAIResponseActive) {
      this.openAIResponseCreatePending = { reason, response };
      this.log(`[realtime.proxy] delayed response.create because OpenAI response is still active reason=${reason}.`);
      return;
    }
    this.markOpenAIResponseActive();
    this.log(`[realtime.proxy] sending response.create reason=${reason}`);
    this.sendUpstream({
      type: "response.create",
      response: { output_modalities: ["audio"], ...response }
    });
  }

  private flushOpenAIResponseCreate() {
    const pending = this.openAIResponseCreatePending;
    if (!pending) return;
    this.openAIResponseCreatePending = null;
    this.log(`[realtime.audio-diag] flushing queued response.create (active=${String(this.openAIResponseActive)})`);
    this.requestOpenAIResponseCreate(pending.reason || "queued response", pending.response || {});
  }

  private truncateOpenAIAudio() {
    if (this.isGeminiLive()) {
      this.finishGeminiAudio("truncated");
      return;
    }
    if (!this.audioItemID) return;
    const itemID = this.audioItemID;
    const audioEndMs = Math.max(0, Math.round(this.audioMs));
    this.audioItemID = "";
    this.audioMs = 0;
    this.sendUpstream({
      type: "conversation.item.truncate",
      item_id: itemID,
      content_index: 0,
      audio_end_ms: audioEndMs
    });
  }

  private closeVoice() {
    if (this.closed) return;
    this.closed = true;
    this.onClose(this);
    this.clearAutoHandoff();
    this.stopKeepAlive();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = undefined;
    }
	    this.clearOpenAIResponseActive();
	    this.transition("idle", "session closed");
    this.openAIResponseCreatePending = null;
    if (this.upstream?.readyState === WebSocket.OPEN || this.upstream?.readyState === WebSocket.CONNECTING) {
      this.upstream.close();
    }
    if (this.geminiSession) {
      try {
        this.geminiSession.close();
      } catch {
        // Best-effort cleanup.
      }
    }
    this.upstream = undefined;
    this.upstreamReady = undefined;
    this.geminiSession = undefined;
  }

  dispose() {
    for (const controller of this.taskAbortControllers.values()) controller.abort();
    this.taskAbortControllers.clear();
    this.taskCoordinator.cancelActive("OpenAssist closed before the delegated task finished.", this.taskScopeKey());
    this.notifyTasksIdleIfNeeded();
    this.closeVoice();
  }
}

export const __realtimeRouterTestHooks = {
  decideRealtimeDelegation,
  isHighConfidenceRealtimeDelegation,
  normalizeRealtimeIntent,
  recallRouteForToolCall,
  realtimeVoiceKnowledgeToolSpecs,
  routeParallelDelegation,
  shouldUseDirectKnowledgeInsteadOfAgent
};

export class CodexRealtimeProxy extends EventEmitter {
  private server?: http.Server;
  private wss?: WebSocketServer;
  private baseURLValue?: string;
  private sessions = new Set<RealtimeProxySession>();
  private workerSessions = new Set<RealtimeProxySession>();
  private readonly taskCoordinator = new RealtimeTaskCoordinator(6);
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
        // Each voice socket keeps the callbacks and thread identity it started
        // with. A later Live Voice start must not redirect an older worker's
        // result into the new thread.
        const sessionConfig = { ...this.config };
        const session = new RealtimeProxySession(
          ws,
          () => {
            const liveKnowledge = this.config.knowledge;
            return {
              ...sessionConfig,
              // Permissions can change while Live Voice is open. Keep the
              // session's original recall scope, but read the current access
              // state and current direct-knowledge callback.
              knowledge: liveKnowledge
                ? { ...liveKnowledge, context: sessionConfig.knowledge?.context }
                : undefined,
              directKnowledgeRequest: this.config.directKnowledgeRequest,
              delegationMode: this.config.delegationMode
            };
          },
          this.log,
          this.taskCoordinator,
          (closedSession) => {
            this.sessions.delete(closedSession);
            if (closedSession.hasActiveDelegatedTasks()) this.workerSessions.add(closedSession);
          },
          (idleSession) => {
            if (idleSession.isVoiceClosed()) this.workerSessions.delete(idleSession);
          }
        );
        this.sessions.add(session);
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

  async appendVisualContext(context: RealtimeVisualContext) {
    if (!this.sessions.size) return { ok: false, error: "Live Voice is not running." };
    const results = await Promise.all(Array.from(this.sessions).map((session) => session.appendVisualContext(context)));
    const sent = results.filter(Boolean).length;
    return sent > 0
      ? { ok: true, sent }
      : { ok: false, error: "Could not send image context to Live Voice." };
  }

  async appendText(text: string) {
    if (!this.sessions.size) return { ok: false, error: "Live Voice is not running." };
    const results = await Promise.all(Array.from(this.sessions).map((session) => session.appendUserText(text)));
    const sent = results.filter(Boolean).length;
    return sent > 0
      ? { ok: true, sent }
      : { ok: false, error: "Could not send text to Live Voice." };
  }

  async cancelDelegatedTask(taskID?: string) {
    const task = taskID?.trim()
      ? this.taskCoordinator.get(taskID.trim())
      : this.taskCoordinator.latestActive();
    if (task && task.state !== "queued" && task.state !== "running") {
      return { ok: false, error: "That delegated task has already finished." };
    }
    if (!task) return { ok: false, error: "No delegated task is running." };
    const sessions = new Set([...this.sessions, ...this.workerSessions]);
    const owner = [...sessions].find((session) => session.ownsDelegatedTask(task.taskID));
    if (!owner) return { ok: false, error: "The delegated task can no longer be cancelled." };
    const message = await owner.cancelDelegatedTask(task.taskID);
    return /no delegated task/i.test(message)
      ? { ok: false, error: message }
      : { ok: true, message };
  }

  async stop() {
    for (const session of new Set([...this.sessions, ...this.workerSessions])) {
      session.dispose();
    }
    this.sessions.clear();
    this.workerSessions.clear();
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
