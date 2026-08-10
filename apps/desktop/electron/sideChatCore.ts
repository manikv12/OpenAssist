// Pure helpers for the Side Chat feature: an ephemeral forked conversation
// docked beside a main thread. Kept dependency-free so verify-side-chat.mjs can
// unit-test the compiled dist-electron/sideChatCore.js directly.

export type SideChatTranscriptEntry = {
  role?: string;
  text?: string;
};

export type SideChatLimits = {
  maxMessages: number;
  maxCharsPerMessage: number;
  totalBudgetChars: number;
  idleLimitMs: number;
  sweepIntervalMs: number;
};

export const sideChatLimits: SideChatLimits = {
  maxMessages: 40,
  maxCharsPerMessage: 1_200,
  totalBudgetChars: 24_000,
  idleLimitMs: 30 * 60 * 1000,
  sweepIntervalMs: 5 * 60 * 1000
};

function truncatedEntryText(text: string, maxChars: number): string {
  const trimmed = text.trim();
  if (trimmed.length <= maxChars) return trimmed;
  return `${trimmed.slice(0, Math.max(0, maxChars - 1)).trimEnd()}…`;
}

// Deep copy of the tail of the parent conversation, newest-biased: walk from
// the end, keep user/assistant entries until the message or character budget is
// reached, then restore chronological order (oldest kept first, newest last).
export function buildSideChatSeedContext(
  transcript: SideChatTranscriptEntry[] | undefined | null,
  limits: SideChatLimits = sideChatLimits
): string {
  if (!Array.isArray(transcript) || transcript.length === 0) return "";
  const kept: string[] = [];
  let usedChars = 0;
  for (let index = transcript.length - 1; index >= 0; index -= 1) {
    if (kept.length >= limits.maxMessages) break;
    const entry = transcript[index];
    const role = String(entry?.role ?? "").trim().toLowerCase();
    if (role !== "user" && role !== "assistant") continue;
    const text = truncatedEntryText(String(entry?.text ?? ""), limits.maxCharsPerMessage);
    if (!text) continue;
    const line = `${role === "user" ? "User" : "Assistant"}: ${text}`;
    if (usedChars + line.length > limits.totalBudgetChars) break;
    usedChars += line.length;
    kept.push(line);
  }
  return kept.reverse().join("\n\n");
}

// Wraps the seed context and the user's first side-chat prompt. Returns the
// prompt unchanged when there is no context to copy.
export function composeSideChatFirstTurnPrompt(context: string, prompt: string): string {
  const trimmedContext = String(context ?? "").trim();
  const trimmedPrompt = String(prompt ?? "");
  if (!trimmedContext) return trimmedPrompt;
  return [
    "This is a side chat forked from an Open Assist conversation. Context copied from the main chat (newest last):",
    "",
    trimmedContext,
    "",
    "Rules for this side chat:",
    "- Answer only the Current user task below.",
    "- Parent context is background only. Do not continue unfinished main-chat workflows (Canva edits, tool runs, commits) unless the user clearly asks to continue them.",
    "- If the user asks to generate an image, file, or other output, do that request directly and return the result here.",
    "- Do not repeat the parent context back.",
    "",
    "Current user task:",
    trimmedPrompt
  ].join("\n");
}

// Incremental context sync: format only the parent-transcript entries past the
// watermark index. nextWatermark is the transcript length the caller should
// store so the same messages are never copied twice.
export function buildSideChatSyncContext(
  transcript: SideChatTranscriptEntry[] | undefined | null,
  fromIndex: number,
  limits: SideChatLimits = sideChatLimits
): { context: string; nextWatermark: number } {
  const list = Array.isArray(transcript) ? transcript : [];
  const startIndex = Math.max(0, Math.min(Math.floor(Number(fromIndex) || 0), list.length));
  return {
    context: buildSideChatSeedContext(list.slice(startIndex), limits),
    nextWatermark: list.length
  };
}

// Wraps a synced context delta plus the user's next question.
export function composeSideChatSyncPrompt(context: string, prompt: string): string {
  const trimmedContext = String(context ?? "").trim();
  const trimmedPrompt = String(prompt ?? "");
  if (!trimmedContext) return trimmedPrompt;
  return [
    "Update — new messages in the main Open Assist chat since you last saw it (newest last):",
    "",
    trimmedContext,
    "",
    "Answer only the Current user task below. Use the update as background context, not as a job to finish unless the user asks.",
    "",
    "Current user task:",
    trimmedPrompt
  ].join("\n");
}

// Pure expiry decision for the idle sweeper. A missing or invalid timestamp
// counts as expired so orphaned side chats cannot linger forever.
export function sideChatIdleExpired(
  lastActivityAt: number | undefined | null,
  now: number,
  idleLimitMs: number = sideChatLimits.idleLimitMs
): boolean {
  const last = Number(lastActivityAt);
  if (!Number.isFinite(last) || last <= 0) return true;
  return now - last >= idleLimitMs;
}
