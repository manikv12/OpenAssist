export type VoiceRouteKind = "control" | "recall" | "write" | "read" | "parallel" | "delegate" | "ignore";

export type VoiceRouteDecision = {
  kind: VoiceRouteKind;
  reason: string;
  confidence: "high" | "medium" | "low";
};

export function normalizeVoiceRouteText(text: string) {
  return String(text || "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}'\s/-]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export type TodayTaskSourceSelection = {
  matches: boolean;
  includeOpenAssist: boolean;
  includeAppleReminders: boolean;
};

export function todayTaskSourceSelection(text: string): TodayTaskSourceSelection {
  const normalized = normalizeVoiceRouteText(text);
  const noMatch = { matches: false, includeOpenAssist: false, includeAppleReminders: false };
  if (!normalized) return noMatch;
  if (/\b(add|create|put|save|insert|append|delete|remove|move|schedule|rename|update|change|complete|finish|mark|check off|cross off)\b/.test(normalized)) {
    return noMatch;
  }

  const hasTaskSubject = /\b(to-?do|todos?|tasks?|reminders?|planner|daily items?|today list|day plan)\b/.test(normalized);
  const hasReadIntent = /\b(what|which|show|read|check|list|how many|do i have|do we have|anything|any|unfinished|pending|open)\b/.test(normalized);
  if (!hasTaskSubject || !hasReadIntent) return noMatch;

  const appleSource = /\b(apple reminders?|reminders app|icloud reminders?)\b/.test(normalized);
  const openAssistSource = /\b(openassist|open assist|today planner|openassist today|open assist today)\b/.test(normalized);
  const onlyApple = appleSource && (/\bonly\b.{0,30}\b(apple reminders?|reminders app|icloud reminders?)\b/.test(normalized)
    || /\b(apple reminders?|reminders app|icloud reminders?)\b.{0,30}\bonly\b/.test(normalized));
  const onlyOpenAssist = openAssistSource && (/\bonly\b.{0,30}\b(openassist|open assist|today planner)\b/.test(normalized)
    || /\b(openassist|open assist|today planner)\b.{0,30}\bonly\b/.test(normalized));

  return {
    matches: true,
    includeOpenAssist: !onlyApple,
    includeAppleReminders: !onlyOpenAssist
  };
}

const ACKNOWLEDGEMENT_WORDS = new Set([
  "ok", "okay", "yes", "yeah", "yep", "yup", "no", "nope", "mhm", "mm", "hmm", "hm",
  "uh", "um", "thanks", "thank", "you", "cool", "nice", "sure", "alright", "all",
  "right", "please", "good", "great", "perfect", "sounds"
]);

export function classifyVoiceRoute(text: string): VoiceRouteDecision {
  const normalized = normalizeVoiceRouteText(text);
  if (!normalized) return { kind: "ignore", reason: "empty", confidence: "high" };

  if (/^(stop|cancel|never mind|nevermind|wait|hold on|pause|quiet|mute)(\s|$)/.test(normalized)) {
    return { kind: "control", reason: "stop or listening control", confidence: "high" };
  }

  if (/\b(stop|cancel|pause|quiet|mute)\b.{0,30}\b(listening|talking|speaking|voice|audio|microphone|mic|live voice)\b/.test(normalized)) {
    return { kind: "control", reason: "stop or listening control", confidence: "high" };
  }

  // Only pure acknowledgements are ignored. Requiring EVERY word to be an
  // acknowledgement word keeps short commands like "yes run it" or
  // "ok add milk" routable instead of silently dropped.
  const words = normalized.split(/\s+/);
  if (words.length <= 4 && words.every((word) => ACKNOWLEDGEMENT_WORDS.has(word))) {
    return { kind: "ignore", reason: "short acknowledgement", confidence: "high" };
  }

  if (
    /\b(memory|memories|remember|saved|previous|earlier|last time|old conversation|past conversation|all chats?|all threads?|codex said|claude said|spark said)\b/.test(normalized)
    && !/\b(save|add|create|delete|forget|remove)\b.{0,40}\b(memory|memories)\b/.test(normalized)
    && !/\b(online|web|internet|website|current|latest)\b/.test(normalized)
  ) {
    return { kind: "recall", reason: "saved memory or past conversation", confidence: "high" };
  }

  if (/\b(at the same time|in parallel|both|two tasks|these tasks)\b/.test(normalized)) {
    return { kind: "parallel", reason: "parallel task request", confidence: "medium" };
  }

  if (
    /\b(online|web|internet|website|current|latest|browse)\b/.test(normalized)
    && /\b(check|search|find|look up|lookup|browse)\b/.test(normalized)
  ) {
    return { kind: "delegate", reason: "current web or external lookup", confidence: "high" };
  }

  if (
    /\b(check|inspect|run|query|read|search|find|debug|open|use|calculate|verify|review|investigate|trace|diagnose|what happened|why)\b/.test(normalized)
    && (
      /\b(agent|codex|claude|coding assistant)\b/.test(normalized)
      || /\b(using|via|through|with)\b.{0,60}\b(cli|tool|app|service|system|api|console|dashboard)\b/.test(normalized)
      || /\b(cli|terminal|shell|command line|logs?|database|server|deployment|build|tests?|repo|repository|codebase|runtime|debugger|admin console)\b/.test(normalized)
    )
  ) {
    return { kind: "delegate", reason: "request requires agent execution", confidence: "high" };
  }

  const hasMutation = /\b(add|create|put|save|insert|append|delete|remove|move|schedule|rename|update|change|complete|finish|mark|check off|cross off)\b/.test(normalized);
  if (hasMutation) {
    return { kind: "write", reason: "mutation verb", confidence: "high" };
  }

  if (todayTaskSourceSelection(normalized).matches) {
    return { kind: "read", reason: "today task read", confidence: "high" };
  }

  const hasExplicitRead = /\b(what|which|show|read|check|list out|list all|how many|do i have|do we have|any pending|unfinished|open tasks?)\b/.test(normalized);
  if (hasExplicitRead) {
    return { kind: "read", reason: "explicit read question", confidence: "medium" };
  }

  return { kind: "delegate", reason: "model or agent should decide", confidence: "low" };
}
