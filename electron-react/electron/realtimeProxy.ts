import http from "node:http";
import { EventEmitter } from "node:events";
import { WebSocket, WebSocketServer } from "ws";

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
    run: (request: { callID: string; prompt: string; replyMode: RealtimeHandoffReplyMode }) => Promise<string>;
  };
  knowledge?: {
    enabled: boolean;
    call: (name: string, args: JsonObject) => Promise<unknown>;
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
      type: "client_closed" | "upstream_closed" | "upstream_reconnect_scheduled" | "upstream_reconnected" | "upstream_reconnect_failed";
      reason?: string;
      attempt?: number;
      delayMs?: number;
      message?: string;
    }) => void;
  };
  delegatedStatus?: {
    current: () => Promise<string> | string;
  };
  delegationRouter?: {
    route: (input: RealtimeDelegationRouteInput) => Promise<RealtimeDelegationRouteResult>;
  };
  delegationMode?: RealtimeDelegationMode;
};

type PendingHandoff = {
  callID: string;
  prompt: string;
  replyMode: RealtimeHandoffReplyMode;
  backendText: string;
  answerSent: boolean;
  agentLabel: string;
  startedAt: number;
  updatedAt: number;
  lastActivity: string;
};

type GeminiLiveSession = {
  sendRealtimeInput: (input: unknown) => void;
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
// How eagerly OpenAI's semantic VAD decides the user has started speaking (for
// barge-in). "medium" balances fast cut-in against false triggers from noise.
const realtimeVADEagerness = "medium";
// Safety net: max time we keep believing a response is "active" without a
// response.done before we force-clear the flag so the assistant is never stuck mute.
// Kept short for fast recovery; the watchdog re-arms instead of firing while audio
// is still actively streaming, so it never cuts a long but legitimate spoken answer.
const openAIResponseWatchdogMs = 5_000;

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

function isConversationRecallQuestion(text: string) {
  const normalized = normalizeRealtimeIntent(text);
  if (!normalized) return false;

  const asksWhetherAlready =
    /\b(wants?|asked|asks?|wondering)\b.{0,80}\b(if|whether)\b.{0,80}\balready\b/.test(normalized)
    || /\b(did|have|had|were|was)\b.{0,20}\b(you|we|the agent|codex|claude|assistant)\b.{0,100}\balready\b/.test(normalized);
  if (asksWhetherAlready) return true;

  if (isExplicitRealtimeRerunRequest(normalized)) return false;

  return /\balready\b.{0,60}\b(found|find|figured|figure|checked|searched|ran|did|done|finished|answered|responded|looked)\b/.test(normalized)
    || /\b(previous|last|earlier)\b.{0,80}\b(turn|message|answer|response|task|result|conversation|thing)\b/.test(normalized)
    || /\bwhat did\b.{0,30}\b(you|we|the agent|codex|claude|assistant)\b.{0,50}\b(find|say|do|answer|respond|figure out|check)\b/.test(normalized)
    || /\bwhat (was|were)\b.{0,50}\b(result|answer|last thing|previous thing)\b/.test(normalized)
    || /\b(do you|can you)\b.{0,30}\bremember\b/.test(normalized);
}

function isCasualRealtimeQuestion(text: string) {
  if (isConversationRecallQuestion(text)) return true;

  const explicitToolRequest =
    /\b(browser|brave|chrome|computer|desktop app|website|webpage|codex|repo|repository|codebase|terminal|file)\b/.test(text)
    && /\b(open|check|inspect|use|search|find|read|look)\b/.test(text);
  if (explicitToolRequest) return false;

  return /\b(joke|funny|laugh|story|weather|time|date|who are you|how are you|what can you do|tell me about yourself|sing|poem)\b/.test(text)
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
    || /\b(what are you doing|what you are doing|what you're doing|what is it doing|what's it doing|what is the agent doing)\b/.test(normalized)
    || /\b(what's happening|what is happening|what happened|where is it at|where it is at|where it's at|where its at|where is it right now|where it is right now|where are we at|where we are at|what step is it on)\b/.test(normalized)
    || /\b(check on it|check on that|check on the task|check on the agent|check on codex)\b/.test(normalized)
    || /\b(why is it taking|why is this taking|why so long|why did it stop|why it stopped)\b/.test(normalized)
    || /^why\b.*\bstuck\b/.test(normalized);
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
  const cleanOutput = String(output || "").trim() || `${label} finished the task.`;
  return [
    "[Agent task finished]",
    cleanOutput,
    "",
    `Speak only the ${label} answer above. Do not add new facts or contradict it.`
  ].join("\n");
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

function decideRealtimeDelegation(
  prompt: string,
  hasActiveHandoff: boolean,
  lastDelegationPrompt = "",
  options: { blockRealtimeKnowledgeTasks?: boolean } = {}
): DelegationDecision {
  const repairedPrompt = contextualizeRealtimeDelegationPrompt(prompt, lastDelegationPrompt);
  const normalizedPrompt = normalizeRealtimeIntent(repairedPrompt);
  const normalizedRawPrompt = normalizeRealtimeIntent(repairRealtimeDelegationText(prompt));
  const blockRealtimeKnowledgeTasks = options.blockRealtimeKnowledgeTasks !== false;

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

  if (isStopOrDismissal(normalizedPrompt)) {
    return {
      allow: false,
      output: "The user dismissed the task. Do not start the agent.",
      createResponse: true,
      reason: "dismissal"
    };
  }

  const asksWhereActiveTaskIs = /\bcheck\b.{0,40}\b(where|status|progress)\b/.test(normalizedRawPrompt)
    || /\bwhere\b.{0,30}\b(it|that|task|agent|we)\b.{0,30}\b(at|now|status|progress)\b/.test(normalizedRawPrompt);
  if (hasActiveHandoff && (asksWhereActiveTaskIs || isDelegatedStatusQuestion(normalizedRawPrompt) || isDelegatedStatusQuestion(normalizedPrompt))) {
    return {
      allow: false,
      output: "The user is asking for the current delegated task status. Call get_delegated_task_status and answer from that result. Do not start a new background_agent task.",
      createResponse: true,
      reason: "delegated status question"
    };
  }

  if (isConversationRecallQuestion(normalizedRawPrompt) || isConversationRecallQuestion(normalizedPrompt)) {
    return {
      allow: false,
      output: "This is a question about the existing conversation or previous task result. Answer from the conversation context. Do not start the agent or repeat the task unless the user explicitly asks to run it again.",
      createResponse: true,
      reason: "conversation recall"
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

function isHighConfidenceRealtimeDelegation(prompt: string, _source: RealtimeDelegationRouteSource) {
  const repairedPrompt = repairRealtimeDelegationText(prompt);
  const normalized = normalizeRealtimeIntent(repairedPrompt);
  if (!normalized) return false;
  if (isConversationRecallQuestion(normalized) || isCasualRealtimeQuestion(normalized) || isVagueRealtimeHelpRequest(normalized)) return false;
  if (looksLikeNoteOrganizeTask(normalized)) return true;
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
    description: `Hand coding, repository, terminal, browser, computer, or app tasks to ${agentLabel}.`,
    geminiBehavior: "NON_BLOCKING",
    parameters: {
      type: "object",
      properties: {
        prompt: { type: "string", description: `The exact task the user wants ${agentLabel} to perform.` }
      },
      required: ["prompt"],
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
              "artifact"
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
    description: "List structured Today/daily items for a date, including project, area, details, steps, and linked notes.",
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
    name: "knowledge_request_daily_item",
    description: "Add one structured daily item. Set area to Work or Personal. Keep title short; put time and extra context in detailsMarkdown. Put project/folder scope in the title with @Project or #Folder when known. Ask if the category is unclear. Adding is applied immediately (no approval needed).",
    parameters: {
      type: "object",
      properties: {
        dayID: { type: "string" },
        title: { type: "string" },
        projectID: { type: "string" },
        folderID: { type: "string" },
        area: { type: "string", enum: ["Work", "Personal"] },
        scopeTags: realtimeScopeTagsSchema,
        detailsMarkdown: { type: "string" },
        steps: realtimeDailyStepsSchema,
        links: realtimeDailyLinksSchema,
        goal: { type: "string" }
      },
      required: ["title"],
      additionalProperties: true
    }
  },
  {
    name: "knowledge_request_backlog_item",
    description: "Add one task or follow-up to the OpenAssist backlog when the user wants to do it later but has not picked a date. Applied immediately, no approval needed.",
    parameters: {
      type: "object",
      properties: {
        title: { type: "string" },
        projectID: { type: "string" },
        folderID: { type: "string" },
        area: { type: "string", enum: ["Work", "Personal"] },
        scopeTags: realtimeScopeTagsSchema,
        detailsMarkdown: { type: "string" },
        steps: realtimeDailyStepsSchema,
        links: realtimeDailyLinksSchema,
        goal: { type: "string" }
      },
      required: ["title"],
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
    description: "Create an approval preview that moves unfinished planner tasks to the Backlog. Adds each task to Backlog and removes it from its source planner day. Use for requests like 'move older unfinished tasks to backlog'. Needs approval.",
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
    description: "Create an approval preview that moves unfinished tasks from one planner day to another planner day. Not for Backlog. Use only when both source and target days are clear.",
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
    description: "Return the OpenAssist note formatting guide covering callout kinds (decision, warning, info, success, next, comment), 2-column and 3-column table layouts, and when not to use rich blocks. Call this before organizing a note so you produce exact replacement markdown with correct OpenAssist syntax.",
    parameters: {
      type: "object",
      properties: {},
      required: [],
      additionalProperties: false
    }
  },
  {
    name: "knowledge_request_organize",
    description: "Request a note organization preview. You MUST supply itemID and the full replacement markdown to make this actionable. Pattern: (1) read the note with knowledge_search or equivalent, (2) call knowledge_note_style_guide, (3) produce exact replacement markdown using OpenAssist blocks, (4) call this tool with itemID + markdown. For planner tasks use knowledge_request_daily_item.",
    parameters: {
      type: "object",
      properties: {
        goal: { type: "string" },
        itemID: { type: "string", description: "The note or item ID to organize." },
        markdown: { type: "string", description: "Full replacement markdown using OpenAssist-supported blocks." },
        scope: { type: "string" },
        query: { type: "string" }
      },
      required: ["goal"],
      additionalProperties: true
    }
  }
];

function realtimeVoiceToolSpecs(knowledgeEnabled: boolean, agentLabel: string) {
  return [
    ...realtimeVoiceControlToolSpecs,
    realtimeDelegatedStatusToolSpec(agentLabel),
    realtimeBackgroundAgentToolSpec(agentLabel),
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
    "Use direct OpenAssist knowledge tools before calling background_agent.",
    `If the user asks for status, progress, why the task is stuck, what ${label} is doing, or where the delegated task is at, call get_delegated_task_status and answer from that result.`,
    "Do not call background_agent for status checks about the task that is already running.",
    "Before calling background_agent for hard work that may take noticeable time, say one short preamble immediately, then call the tool.",
    "If the user request is agentic and no direct realtime tool can handle it, call background_agent instead of doing it yourself.",
    "Agentic means the request needs tools, files, code changes, terminal commands, browser/computer use, website/app inspection, account data, current/live information, or multi-step work.",
    "For coding, codebase, repo, app, terminal, debugging, install, file, browser, computer, desktop app, website, current/live data, or configuration work, call background_agent with the user's exact request.",
    `Only call background_agent when the user gives a clear task that needs ${label} or provider tools.`,
    "If the user asks what happened in the previous or last turn, whether you already found/did/checked something, or what the previous result was, answer from the conversation context. Do not call background_agent unless the user clearly asks you to run/check/search again.",
    "Do not call background_agent while the user sounds mid-sentence, is pausing, or has only said the first part of a longer task.",
    "If the request starts like a fragment, for example \"if...\", \"when...\", \"and...\", or \"also...\", call wait_for_user and wait for the complete request.",
    "Follow-up task requests like \"check it for yesterday\" or \"do the same for yesterday\" should call background_agent using the recent delegated task as context.",
    "If the user only says ok, yes, no, mhm, hmm, thanks, or another short acknowledgement, do not call background_agent.",
    `If ${label} is already working and the user gives a tiny acknowledgement or vague follow-up, do not start a new background_agent task.`,
    `After calling background_agent, stay quiet about task progress and wait for the final ${label} result before giving task details.`,
    `Messages that start with [BACKEND], [Codex progress], or [Codex status] are hidden progress from ${label}. Do not read, summarize, or respond to them out loud.`,
    `While ${label} is working, keep listening to the user. Answer a new direct user question if needed, but do not start another background_agent task until the current one finishes.`,
    "Only speak the delegated task result when a message or background_agent result starts with [Agent task finished] or [Codex task finished].",
    `When you see [Agent task finished] or [Codex task finished], use only that ${label} result. Do not add new facts, search your memory, or contradict the result.`,
    "Do not invent codebase details.",
    knowledgeEnabled
      ? [
        "",
        "# OpenAssist Knowledge",
      "For quick questions about the user's notes, Today planner, Backlog, journal, or open tasks, use the knowledge tools.",
      "Use knowledge tools only when the user asks for personal OpenAssist knowledge. Do not read all notes into the voice prompt.",
      "For greetings and small talk like 'hello', 'hi', 'hey', 'ei', 'how are you', or 'good morning', just reply naturally in one short sentence. Do NOT call knowledge_daily_items or any tool for a greeting.",
      "Only call a knowledge tool when the user actually asks about their tasks, notes, planner, backlog, or journal. A greeting alone is not such a request.",
	      "Use knowledge_daily_items or knowledge_open_tasks for questions like 'what tasks are open today' or 'do I have anything today'. Do not call background_agent for those.",
	      "Use knowledge_backlog_items for backlog or later/follow-up questions.",
	      "For memory/history questions like 'when did we', 'where did I mention', 'what did we decide', or 'find the earlier discussion', call knowledge_search_everything first. If one hit matters, call knowledge_read_search_result. Do not call background_agent for simple recall.",
	      "If the user asks to add a reminder, task, or to-do in OpenAssist, treat it as a Today planner item, not as Apple Calendar or Apple Reminders.",
	      "If the user asks to add a later/follow-up item without a date, use knowledge_request_backlog_item.",
	      "When you create a Today planner item, set area to exactly Work or Personal. Work means job, client, coding, project, meeting, ticket, repo, or business tasks. Personal means home, family, errands, appointments, calls, service/repair, bills, or shopping.",
	      "If you are not sure whether the task is Work or Personal, ask one short clarification question before creating it.",
	      "If the user says a task is done, finished, or completed, call knowledge_complete_daily_item with the task text. It is applied immediately, so say it was marked done.",
	      "To move unfinished or older planner tasks into the Backlog, use knowledge_request_move_to_backlog.",
	      "To move unfinished tasks from one planner day to another planner day, use knowledge_request_carry_forward.",
	      "For organizing, correcting, or changing planner content, use knowledge_request_carry_forward or a direct knowledge request only when the source, target, and exact preview are clear; otherwise ask a short question or call background_agent for complex work.",
	      `For substantial note organization, restructuring, cleanup, rewriting, or styling requests, call background_agent with the user's exact request so ${label} can read the full note, use OpenAssist note style tools, and create an approval preview. Do not try to do heavy note rewriting in realtime voice.`,
	      "Use realtime knowledge tools for quick note reads/searches, small exact note edits, simple Today/Backlog adds, mark-done actions, and planner moves. Delegate full-note organization/restructure/cleanup tasks.",
	      "Do not claim a note was organized until a tool or delegated agent result says an approval preview was created.",
	      "knowledge_request_organize creates a preview that needs the user's approval. After calling it, tell the user the organized version is ready for approval. Do not claim the note was already changed.",
	      "OpenAssist notes support rich blocks: callouts (::: decision, ::: warning, ::: info, ::: success, ::: next, ::: comment) and 2/3-column table layouts. Always use knowledge_note_style_guide before writing organized markdown so the output uses valid OpenAssist syntax.",
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

function geminiLiveSessionConfig(Modality: { AUDIO: unknown }, config: RealtimeProxyConfig, codexInstructions: string) {
  const knowledgeEnabled = Boolean(config.knowledge?.enabled);
  const agentLabel = config.handoff?.agentLabel || "Codex";
  const voiceName = (config.voice || defaultGeminiLiveVoice).trim();
  const model = config.model?.trim() || defaultGeminiLiveModel;
  const geminiConfig: JsonObject = {
    responseModalities: [Modality.AUDIO],
    systemInstruction: realtimeInstructions(codexInstructions, knowledgeEnabled, agentLabel),
    temperature: 0.7,
    inputAudioTranscription: {},
    outputAudioTranscription: {},
    realtimeInputConfig: {
      automaticActivityDetection: {
        startOfSpeechSensitivity: "START_SENSITIVITY_HIGH",
        endOfSpeechSensitivity: "END_SENSITIVITY_HIGH",
        silenceDurationMs: 600
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
    ]
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
  private quiet = false;
  private audioItemID = "";
  private audioMs = 0;
  private sampleRate = 24000;
  private geminiInputTranscript = "";
  private geminiOutputTranscript = "";
  private geminiAudioItemID = "";
  private geminiFailureMessage = "";
  private openAIResponseActive = false;
  private openAIResponseCreatePending = false;
  // Watchdog: if a response we believe is active never reports response.done (e.g. it
  // was cancelled by a barge-in, or the server/proxy state desynced), force-clear the
  // flag so the assistant can speak again instead of going permanently silent.
  private openAIResponseWatchdog?: NodeJS.Timeout;
  private pendingHandoffs = new Map<string, PendingHandoff>();
  private handledCalls = new Set<string>();
  private handledKnowledgePrompts = new Map<string, number>();
  private localMessageHandoffCallIDs = new Set<string>();
  private lastUserUtterance = "";
  private lastDelegationPrompt = "";
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

  constructor(
    private readonly codexSocket: WebSocket,
    private readonly configProvider: () => RealtimeProxyConfig,
    private readonly log: (message: string) => void,
    private readonly onClose: (session: RealtimeProxySession) => void = () => {}
  ) {}

  start() {
    this.codexSocket.on("message", (data) => {
      void this.onCodexMessage(data.toString());
    });
    this.codexSocket.on("close", (_code, reason) => {
      const message = reason?.toString() || "no reason";
      this.log(`[realtime.proxy] client websocket closed: ${message}`);
      this.configProvider().connection?.onEvent({ type: "client_closed", reason: message });
      this.close();
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
    this.log(`[realtime.proxy] knowledge handled route=${reason} prompt=${normalized.slice(0, 120)}`);
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
    if (utterance) keys.add(`utterance ${utterance}`);
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

  private realtimeProvider() {
    return this.configProvider().provider || "openaiRealtime";
  }

  private isGeminiLive() {
    return this.realtimeProvider() === "geminiLive";
  }

  private currentVoiceState(): RealtimeDelegationRouteInput["voiceState"] {
    if (this.quiet) return "quiet";
    if (this.pendingHandoffs.size > 0) return "delegating";
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
      blockRealtimeKnowledgeTasks: delegationMode !== "alwaysDelegate"
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

  private async delegatedTaskStatusText() {
    const statusProvider = this.configProvider().delegatedStatus;
    if (statusProvider?.current) {
      try {
        const status = compactRealtimeStatusText(await statusProvider.current());
        if (status) return status;
      } catch (error) {
        this.log(`[realtime.proxy] delegated status provider failed: ${error instanceof Error ? error.message : String(error)}`);
      }
    }

    const handoff = this.latestPendingHandoff();
    if (!handoff) {
      return "No delegated task is running right now.";
    }

    const now = Date.now();
    const elapsed = formatRealtimeElapsed(now - handoff.startedAt);
    const staleElapsed = formatRealtimeElapsed(now - handoff.updatedAt);
    const latest = compactRealtimeStatusText(handoff.lastActivity || latestStatusLine(handoff.backendText), 500);
    const lines = [
      `${handoff.agentLabel || "Agent"} is still working for ${elapsed}.`,
      handoff.prompt ? `Task: ${compactRealtimeStatusText(handoff.prompt, 360)}` : "",
      latest ? `Latest update: ${latest}` : "No detailed progress update has arrived yet.",
      now - handoff.updatedAt > 120_000 ? `No new progress has arrived for ${staleElapsed}. It may be stuck.` : ""
    ].filter(Boolean);
    return lines.join("\n");
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
    let connectedSession: GeminiLiveSession | undefined;
    const session = await ai.live.connect({
      model,
      config: geminiLiveSessionConfig(Modality, config, this.codexInstructions),
      callbacks: {
        onopen: () => this.log(`[realtime.proxy] Gemini Live websocket opened model=${model}`),
        onmessage: (message: unknown) => {
          void this.onGeminiLiveMessage(message).catch((error: unknown) => {
            this.log(`[realtime.proxy] Gemini Live message handler failed: ${error instanceof Error ? error.message : String(error)}`);
          });
        },
        onerror: (event: unknown) => {
          const error = jsonObject(event);
          const message = stringValue(error?.message, jsonObject(error?.error)?.message, event) || "Gemini Live connection failed.";
          this.log(`[realtime.proxy] Gemini Live websocket error: ${message}`);
          if (isFatalGeminiLiveCloseReason(message)) this.geminiFailureMessage = message;
          this.sendToCodex({ type: "error", error: { message } });
        },
        onclose: (event: unknown) => {
          const close = jsonObject(event);
          const reason = stringValue(close?.reason) || "no reason";
          this.log(`[realtime.proxy] Gemini Live websocket closed: ${reason}`);
          if (!connectedSession || this.geminiSession === connectedSession) {
            this.geminiSession = undefined;
            this.upstreamReady = undefined;
          }
          if (reason !== "no reason" && isFatalGeminiLiveCloseReason(reason)) {
            this.geminiFailureMessage = `Gemini Live connection failed: ${reason}`;
            this.sendToCodex({ type: "error", error: { message: this.geminiFailureMessage } });
          }
        }
      }
    });
    connectedSession = session;
    if (this.geminiFailureMessage) {
      try {
        session.close();
      } catch {
        // Best effort cleanup after Gemini rejected the session.
      }
      return null;
    }
    this.geminiSession = session;
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
    if (event.type === "response.create" && this.pendingHandoffs.size > 0) {
      this.log("[realtime.proxy] ignored response.create while agent handoff is active; waiting for final agent result.");
      return;
    }

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
      this.finishGeminiAudio("cancelled");
      this.sendToCodex({ type: "output_audio_buffer.cleared" });
      return;
    }

    const session = await this.ensureGeminiLive();
    if (!session) return;

    if (event.type === "input_audio_buffer.append") {
      const audio = stringValue(event.audio, event.delta);
      if (audio) {
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
      session.sendRealtimeInput({ text: userText });
    }
  }

  private async onGeminiLiveMessage(message: unknown) {
    const event = jsonObject(message);
    if (!event) return;

    if (event.setupComplete) {
      const setupComplete = jsonObject(event.setupComplete);
      this.log(`[realtime.proxy] Gemini Live setup complete session=${stringValue(setupComplete?.sessionId) || "unknown"}`);
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

    if (content.turnComplete || content.generationComplete) {
      this.finishGeminiTurn();
    }
  }

  private async onGeminiToolCalls(functionCalls: unknown[]) {
    const responses: JsonObject[] = [];
    for (const rawCall of functionCalls) {
      const call = jsonObject(rawCall);
      if (!call) continue;
      const name = stringValue(call.name);
      if (!name) continue;
      const callID = stringValue(call.id, call.call_id) || makeShortRealtimeID("gemcall");
      const args = jsonObject(call.args) ?? jsonObject(parseJSON(stringValue(call.arguments))) ?? {};
      if (name === "wait_for_user") {
        responses.push({ id: callID, name, response: { output: "Waiting for the user." } });
        continue;
      }

      if (name === "set_listening_mode") {
        const mode = stringValue(args.mode, args.state).toLowerCase();
        this.quiet = /quiet|mute|pause|stop|off|not.listening/.test(mode);
        responses.push({ id: callID, name, response: { output: this.quiet ? "Quiet mode is on." : "Listening mode is on." } });
        continue;
      }

      if (name === "get_delegated_task_status") {
        responses.push({ id: callID, name, response: { output: await this.delegatedTaskStatusText() } });
        continue;
      }

      if (name.startsWith("knowledge_")) {
        if (isCasualRealtimeGreeting(this.geminiInputTranscript || this.lastUserUtterance)) {
          responses.push({ id: callID, name, response: { output: "The user only greeted you. Reply naturally in one short sentence. Do not use knowledge tools for this." } });
          continue;
        }
        const knowledge = this.configProvider().knowledge;
        if (!knowledge?.enabled) {
          responses.push({ id: callID, name, response: { output: "OpenAssist Knowledge access is off in Settings." } });
          continue;
        }
        const promptSnippet = this.geminiInputTranscript || this.lastUserUtterance || JSON.stringify(args);
        if (this.wasKnowledgeRequestHandled(name, args)) {
          this.log(`[realtime.proxy] ignored duplicate Gemini knowledge ${name} prompt=${promptSnippet.slice(0, 160)}`);
          responses.push({
            id: callID,
            name,
            response: { output: "That realtime knowledge request was already handled a moment ago. Do not repeat it unless the user asks again." }
          });
          continue;
        }
        this.notifyDirectWork(callID, name, "running", `Running ${name.replace(/^knowledge_/, "").replace(/_/g, " ")}.`, undefined, { args });
        try {
          const result = await knowledge.call(name, args);
          this.clearAutoHandoff();
          this.rememberKnowledgeRequestHandled(name, args, name);
          this.notifyDirectWork(callID, name, "completed", `Completed ${name.replace(/^knowledge_/, "").replace(/_/g, " ")}.`, undefined, { args, result });
          responses.push({ id: callID, name, response: { output: JSON.stringify(result, null, 2) } });
        } catch (error) {
          const message = error instanceof Error ? error.message : "Knowledge access failed.";
          this.notifyDirectWork(callID, name, "failed", message, message);
          responses.push({ id: callID, name, response: { output: message } });
        }
        continue;
      }

      if (name !== "background_agent") {
        responses.push({ id: callID, name, response: { output: `Unknown tool: ${name}` } });
        continue;
      }

      const rawPrompt = stringValue(args.prompt, args.task, this.geminiInputTranscript) || "Continue the user's requested task.";
      if (this.pendingHandoffs.size > 0 && isDelegatedStatusQuestion(rawPrompt)) {
        responses.push({ id: callID, name, response: { output: await this.delegatedTaskStatusText() } });
        continue;
      }
      if (this.pendingHandoffs.size > 0) {
        const agentLabel = this.configProvider().handoff?.agentLabel || "Agent";
        responses.push({
          id: callID,
          name,
          response: {
            output: `${agentLabel} is already working on the delegated task. Wait for the final result.`
          }
        });
        continue;
      }

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
      this.log(`[realtime.proxy] Gemini Live background_agent routed call_id=${callID}`);
      this.startCodexHandoff(callID, decision.prompt, "message");
      responses.push({
        id: callID,
        name,
        response: {
          output: `${this.configProvider().handoff?.agentLabel || "Agent"} is handling this request. Wait for the final result before giving task details.`
        }
      });
    }

    if (responses.length) {
      await this.sendGeminiToolResponses(responses);
    }
  }

  private sendGeminiAudioDelta(audio: Buffer) {
    if (!audio.length) return;
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
    this.sendToCodex({ type: "response.done", response: { id: `resp_gemini_${Date.now()}`, output: [] } });
    this.geminiInputTranscript = "";
    this.geminiOutputTranscript = "";
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
  }

  private async sendGeminiText(text: string) {
    const session = await this.ensureGeminiLive();
    if (!session) return false;
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
        this.openAIResponseCreatePending = true;
        this.log(`[realtime.proxy] delayed response.create after active-response error: ${messageText}`);
        return;
      }
      this.log(`[realtime.proxy] OpenAI error: ${messageText}`);
      this.sendToCodex({ type: "error", error: { message: messageText } });
      return;
    }

    if (event.type === "session.created" || event.type === "session.updated") return;

    if (event.type === "response.created") {
      this.markOpenAIResponseActive();
      this.sendToCodex(event);
      return;
    }

    if (event.type === "input_audio_buffer.speech_started") {
      // TEMP DIAGNOSTIC: confirm OpenAI's barge-in VAD is firing while the assistant
      // is speaking (responseActive=true means we just cut off a live response).
      this.log(`[realtime.audio-diag] speech_started -> truncate (responseActive=${String(this.openAIResponseActive)})`);
      this.truncateOpenAIAudio();
      this.sendToCodex(event);
      return;
    }

    if (event.type === "conversation.item.input_audio_transcription.completed") {
      const transcript = stringValue(event.transcript, event.text);
      if (transcript && (isBackendProgressMessage(transcript) || isCodexFinalResultMessage(transcript))) {
        this.log(`[realtime.proxy] ignored backend transcript from OpenAI: ${transcript.slice(0, 160)}`);
      } else if (transcript && this.handleStopCommand(transcript)) {
        // User asked the assistant to stop; already silenced. Do not start a task.
      } else if (transcript) {
        this.scheduleAutoHandoff(transcript);
      }
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
      // This response has ended, so clear the active flag FIRST. Otherwise any
      // function-call handler below (e.g. a knowledge tool) calls
      // requestOpenAIResponseCreate() while the flag is still set, the spoken reply
      // gets queued as "pending", and a race with incoming audio can leave it stuck.
      this.audioItemID = "";
      this.audioMs = 0;
      this.clearOpenAIResponseActive();
      this.sendToCodex(event);
      const response = jsonObject(event.response);
      const output = Array.isArray(response?.output) ? response.output : [];
      for (const item of output) {
        const object = jsonObject(item);
        if (object?.type === "function_call") await this.handleFunctionCall(object);
      }
      this.flushOpenAIResponseCreate();
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

    if (name === "get_delegated_task_status") {
      this.sendFunctionOutput(callID, await this.delegatedTaskStatusText(), true);
      return;
    }

    if (name.startsWith("knowledge_")) {
      if (isCasualRealtimeGreeting(this.lastUserUtterance)) {
        this.sendFunctionOutput(callID, "The user only greeted you. Reply naturally in one short sentence. Do not use knowledge tools for this.", true);
        return;
      }
      const knowledge = this.configProvider().knowledge;
      if (!knowledge?.enabled) {
        this.sendFunctionOutput(callID, "OpenAssist Knowledge access is off in Settings.", true);
        return;
      }
      const args = jsonObject(parseJSON(stringValue(item.arguments))) ?? {};
      if (this.wasKnowledgeRequestHandled(name, args)) {
        this.log(`[realtime.proxy] ignored duplicate knowledge ${name} prompt=${(this.lastUserUtterance || JSON.stringify(args)).slice(0, 160)}`);
        this.sendFunctionOutput(callID, "That realtime knowledge request was already handled a moment ago. Do not repeat it unless the user asks again.", true);
        return;
      }
      this.notifyDirectWork(callID, name, "running", `Running ${name.replace(/^knowledge_/, "").replace(/_/g, " ")}.`, undefined, { args });
      try {
        const result = await knowledge.call(name, args);
        this.clearAutoHandoff();
        this.rememberKnowledgeRequestHandled(name, args, name);
        this.notifyDirectWork(callID, name, "completed", `Completed ${name.replace(/^knowledge_/, "").replace(/_/g, " ")}.`, undefined, { args, result });
        this.log(`[realtime.audio-diag] knowledge ${name} result sent; requesting spoken reply (active=${String(this.openAIResponseActive)})`);
        this.sendFunctionOutput(callID, JSON.stringify(result, null, 2), true);
      } catch (error) {
        const message = error instanceof Error ? error.message : "Knowledge access failed.";
        this.notifyDirectWork(callID, name, "failed", message, message);
        this.sendFunctionOutput(callID, message, true);
      }
      return;
    }

    if (name !== "background_agent") return;

    this.clearAutoHandoff();
    const args = jsonObject(parseJSON(stringValue(item.arguments))) ?? {};
    const rawPrompt = stringValue(args.prompt, args.task, item.arguments) || "Continue the user's requested task.";
    if (this.pendingHandoffs.size > 0 && isDelegatedStatusQuestion(rawPrompt)) {
      this.sendFunctionOutput(callID, await this.delegatedTaskStatusText(), true);
      return;
    }
    if (this.pendingHandoffs.size > 0) {
      const agentLabel = this.configProvider().handoff?.agentLabel || "Codex";
      this.log(`[realtime.proxy] ignored background_agent while ${agentLabel} task is already running: ${rawPrompt.slice(0, 160)}`);
      this.sendFunctionOutput(callID, `${agentLabel} is already working on the delegated task. Stay quiet about progress and wait for the final result.`, false);
      return;
    }
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
      this.log(`[realtime.proxy] ignored duplicate background_agent: ${decision.prompt.slice(0, 160)}`);
      const agentLabel = this.configProvider().handoff?.agentLabel || "Codex";
      this.sendFunctionOutput(callID, `That ${agentLabel} task is already running. Do not start a duplicate.`, false);
      return;
    }

    if (await this.tryDirectKnowledgeRequest(callID, decision.prompt, "function")) return;
    this.startCodexHandoff(callID, decision.prompt, "function");
  }

  // Returns true when the transcript is a stop/interrupt phrase. Immediately
  // silences the assistant (truncate audio + cancel the active response) so the
  // user can cut in. A background task that is already running is left to finish.
  private handleStopCommand(transcript: string) {
    const normalized = normalizeRealtimeIntent(transcript);
    if (!normalized || !isStopOrDismissal(normalized)) return false;
    this.log(`[realtime.proxy] stop phrase heard; silencing assistant: ${normalized.slice(0, 80)}`);
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
    this.openAIResponseCreatePending = false;
    this.truncateOpenAIAudio();
    this.sendToCodex({ type: "output_audio_buffer.cleared" });
    return true;
  }

  private scheduleAutoHandoff(transcript: string) {
    if (this.quiet) return;
    if (this.pendingHandoffs.size > 0) return;
    this.lastUserUtterance = transcript;
    if (this.wasKnowledgeHandled(transcript)) return;
    const delegationMode = this.configProvider().delegationMode || "autoHardTasksOnly";
    const decision = decideRealtimeDelegation(transcript, this.pendingHandoffs.size > 0, this.lastDelegationPrompt, {
      blockRealtimeKnowledgeTasks: delegationMode !== "alwaysDelegate"
    });
    if (!decision.allow) return;
    if (decision.normalizedPrompt === this.lastAutoHandoffNormalizedPrompt) return;
    this.clearAutoHandoff();
    this.autoHandoffTimer = setTimeout(() => {
      void this.runAutoHandoff(transcript);
    }, autoHandoffDelayMs);
  }

  private async runAutoHandoff(transcript: string) {
    this.autoHandoffTimer = undefined;
    if (this.pendingHandoffs.size > 0) return;
    if (this.wasKnowledgeHandled(transcript)) return;
    const decision = await this.routeRealtimeDelegation(transcript, "auto_transcript");
    if (!decision.allow) return;
    const duplicatePrompt = Array.from(this.pendingHandoffs.values()).some(
      (handoff) => normalizeRealtimeIntent(handoff.prompt) === decision.normalizedPrompt
    );
    if (duplicatePrompt || decision.normalizedPrompt === this.lastAutoHandoffNormalizedPrompt) return;
    this.lastAutoHandoffNormalizedPrompt = decision.normalizedPrompt;
    if (this.openAIResponseActive) {
      this.sendUpstream({ type: "response.cancel" });
      this.clearOpenAIResponseActive();
    }
    this.truncateOpenAIAudio();
    const callID = makeShortRealtimeID("calloa", ++this.autoHandoffSequence);
    this.log(`[realtime.proxy] auto background_agent: ${decision.prompt.slice(0, 160)}`);
    if (await this.tryDirectKnowledgeRequest(callID, decision.prompt, "message")) return;
    this.startCodexHandoff(callID, decision.prompt, "message");
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
      this.log(`[realtime.proxy] ignored handoff append call_id=${callID || "none"} text=${text.slice(0, 120)}`);
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
    if ((this.configProvider().delegationMode || "autoHardTasksOnly") === "alwaysDelegate") return false;
    if (isCasualRealtimeGreeting(prompt)) return false;
    const shortcut = this.configProvider().directKnowledgeRequest;
    if (!shortcut?.run) return false;
    try {
      const output = (await shortcut.run({ callID, prompt, replyMode }))?.trim();
      if (!output) return false;
      const agentLabel = this.configProvider().handoff?.agentLabel || "OpenAssist";
      this.log(`[realtime.proxy] background_agent handled by direct knowledge request call_id=${callID}`);
      this.clearAutoHandoff();
      this.rememberKnowledgeHandled(prompt, "directKnowledgeRequest");
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

  private startCodexHandoff(callID: string, prompt: string, replyMode: PendingHandoff["replyMode"]) {
    const externalHandoff = this.configProvider().handoff;
    if (externalHandoff) {
      this.log(`[realtime.proxy] background_agent routed to ${externalHandoff.agentLabel || "Agent"} call_id=${callID}`);
      this.startExternalHandoff(callID, prompt, replyMode, externalHandoff);
      return;
    }
    this.log(`[realtime.proxy] background_agent routed to Codex call_id=${callID}`);
    this.lastDelegationPrompt = prompt;
    const now = Date.now();
    this.pendingHandoffs.set(callID, { callID, prompt, replyMode, backendText: "", answerSent: false, agentLabel: "Codex", startedAt: now, updatedAt: now, lastActivity: "" });
    if (replyMode === "message") this.rememberLocalMessageHandoffCallID(callID);
    const itemID = makeShortRealtimeID("itemoa", this.autoHandoffSequence);
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

  private startExternalHandoff(
    callID: string,
    prompt: string,
    replyMode: PendingHandoff["replyMode"],
    handoff: NonNullable<RealtimeProxyConfig["handoff"]>
  ) {
    this.lastDelegationPrompt = prompt;
    const now = Date.now();
    this.pendingHandoffs.set(callID, {
      callID,
      prompt,
      replyMode,
      backendText: "",
      answerSent: false,
      agentLabel: handoff.agentLabel || "Agent",
      startedAt: now,
      updatedAt: now,
      lastActivity: ""
    });
    if (replyMode === "message") this.rememberLocalMessageHandoffCallID(callID);
    this.sendToCodex({ type: "conversation.input_transcript.delta", delta: prompt });
    void (async () => {
      try {
        const output = await handoff.run({ callID, prompt, replyMode });
        const active = this.pendingHandoffs.get(callID);
        if (active && output) {
          active.backendText = appendHandoffText(active.backendText, output);
          active.lastActivity = compactRealtimeStatusText(output, 500);
          active.updatedAt = Date.now();
        }
        await this.completeHandoff(callID, `${handoff.agentLabel || "Agent"} completed: ${output || "Task complete."}`);
      } catch (error) {
        const message = error instanceof Error ? error.message : "The selected provider could not finish the task.";
        const active = this.pendingHandoffs.get(callID);
        if (active) {
          active.backendText = `${handoff.agentLabel || "Agent"} could not finish the task: ${message}`;
          active.lastActivity = active.backendText;
          active.updatedAt = Date.now();
        }
        await this.completeHandoff(callID, active?.backendText || message);
      }
    })();
  }

  private async completeHandoff(callID: string, fallbackOutput = "") {
    const handoff = this.pendingHandoffs.get(callID);
    if (!handoff) {
      this.log(`[realtime.proxy] ignored completed handoff with no pending call: ${callID}`);
      return;
    }
    if (handoff.answerSent) {
      this.log(`[realtime.proxy] ignored duplicate completed handoff: ${callID}`);
      return;
    }
    handoff.answerSent = true;
    const text = handoff.backendText.trim()
      || String(fallbackOutput || "").replace(/^background agent (finished|completed|failed):?\s*/i, "").trim()
      || `${handoff.agentLabel || "Agent"} finished the task.`;
    this.lastDelegationResult = text.slice(0, 2_000);
    this.pendingHandoffs.delete(callID);
    await this.ensureUpstream();
    if (handoff.replyMode === "message") {
      this.sendAgentResultMessage(text, handoff.agentLabel);
    } else {
      this.sendFunctionOutput(callID, text, true, { agentResult: true, agentLabel: handoff.agentLabel });
    }
  }

  private sendAgentResultMessage(output: string, agentLabel: string) {
    if (this.isGeminiLive()) {
      void this.sendGeminiText(formatAgentResultForRealtime(output, agentLabel));
      return;
    }
    this.sendUpstream({
      type: "conversation.item.create",
      item: {
        type: "message",
        role: "user",
        content: [
          {
            type: "input_text",
            text: formatAgentResultForRealtime(output, agentLabel)
          }
        ]
      }
    });
    this.requestOpenAIResponseCreate();
  }

  private sendFunctionOutput(
    callID: string,
    output: string,
    createResponse: boolean,
    options: { agentResult?: boolean; agentLabel?: string } = {}
  ) {
    if (this.isGeminiLive()) {
      const text = options.agentResult ? formatAgentResultForRealtime(output, options.agentLabel || "Agent") : output;
      void this.sendGeminiToolResponses([
        {
          id: callID,
          name: "background_agent",
          response: { output: text }
        }
      ]);
      if (createResponse && !this.quiet && !options.agentResult) {
        void this.sendGeminiText(text);
      }
      return;
    }
    this.sendUpstream({
      type: "conversation.item.create",
      item: {
        type: "function_call_output",
        call_id: callID,
        output: options.agentResult ? formatAgentResultForRealtime(output, options.agentLabel || "Agent") : output
      }
    });
    if (createResponse && !this.quiet) {
      this.requestOpenAIResponseCreate();
    }
  }

  // Mark a response active and arm the watchdog. Any code path that believes a
  // response started should go through here so the flag can never get stuck on.
  private markOpenAIResponseActive() {
    this.openAIResponseActive = true;
    this.armOpenAIResponseWatchdog();
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
    }, openAIResponseWatchdogMs);
    if (typeof this.openAIResponseWatchdog.unref === "function") this.openAIResponseWatchdog.unref();
  }

  private clearOpenAIResponseActive() {
    this.openAIResponseActive = false;
    if (this.openAIResponseWatchdog) {
      clearTimeout(this.openAIResponseWatchdog);
      this.openAIResponseWatchdog = undefined;
    }
  }

  private requestOpenAIResponseCreate() {
    if (this.quiet) return;
    if (this.isGeminiLive()) return;
    if (this.openAIResponseActive) {
      this.openAIResponseCreatePending = true;
      this.log("[realtime.proxy] delayed response.create because OpenAI response is still active.");
      return;
    }
    this.markOpenAIResponseActive();
    this.sendUpstream({
      type: "response.create",
      response: { output_modalities: ["audio"] }
    });
  }

  private flushOpenAIResponseCreate() {
    if (!this.openAIResponseCreatePending) return;
    this.openAIResponseCreatePending = false;
    this.log(`[realtime.audio-diag] flushing queued response.create (active=${String(this.openAIResponseActive)})`);
    this.requestOpenAIResponseCreate();
  }

  private truncateOpenAIAudio() {
    if (this.isGeminiLive()) {
      this.finishGeminiAudio("truncated");
      return;
    }
    if (!this.audioItemID) return;
    this.sendUpstream({
      type: "conversation.item.truncate",
      item_id: this.audioItemID,
      content_index: 0,
      audio_end_ms: Math.max(0, Math.round(this.audioMs))
    });
  }

  private close() {
    if (this.closed) return;
    this.closed = true;
    this.onClose(this);
    this.clearAutoHandoff();
    this.stopKeepAlive();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = undefined;
    }
    this.pendingHandoffs.clear();
    this.clearOpenAIResponseActive();
    this.openAIResponseCreatePending = false;
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
    this.close();
  }
}

export const __realtimeRouterTestHooks = {
  decideRealtimeDelegation,
  isHighConfidenceRealtimeDelegation,
  normalizeRealtimeIntent,
  realtimeVoiceKnowledgeToolSpecs
};

export class CodexRealtimeProxy extends EventEmitter {
  private server?: http.Server;
  private wss?: WebSocketServer;
  private baseURLValue?: string;
  private sessions = new Set<RealtimeProxySession>();
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
        const session = new RealtimeProxySession(ws, () => this.config, this.log, (closedSession) => {
          this.sessions.delete(closedSession);
        });
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

  async stop() {
    for (const session of this.sessions) {
      session.dispose();
    }
    this.sessions.clear();
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
