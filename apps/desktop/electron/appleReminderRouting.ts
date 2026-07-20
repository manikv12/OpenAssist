// Dependency-free routing for quick_read targets that name Apple Reminders.
// Kept free of electron imports so verify scripts can unit-test the compiled
// dist-electron output under plain node.

export type AppleRemindersQuickReadPlan = {
  // Leftover title keywords after stripping the trigger phrase; when present the
  // caller should run a title search, otherwise a plain list.
  query?: string;
  includeCompleted: boolean;
  completedOnly: boolean;
};

const APPLE_REMINDERS_TRIGGERS = [
  /\b(apple|icloud)\s+reminders?\b/,
  /\breminders?\s+(app|list)\b/
];

const COMPLETED_WORDS = /\b(completed?|finished|done)\b/;

// Filler stripped from the leftover query (mirrors the quick_read note-query
// strip list in openassistBridge.ts so both paths tokenize alike).
const FILLER_PATTERNS = [
  /\b(can|could|would|will)\s+you\b/g,
  /\b(please|summarize|summary|read|open|show|find|search|check|look up|pull up|tell me about|what does|what is in|do we have|that we have|for me)\b/g,
  /\b(my|the|a|an|any|all|in|on|from|of)\b/g
];

export function parseAppleRemindersQuickReadTarget(rawTarget: string): AppleRemindersQuickReadPlan | null {
  const normalized = String(rawTarget || "")
    .toLowerCase()
    .replace(/[^a-z0-9'&+\s-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!normalized) return null;

  // "check the completed reminders" → "completed reminders" for the bare-form test.
  const core = normalized
    .replace(/^(?:(?:please|can you|could you)\s+)?(?:check|show|read|open|list|see|get|find|search|pull up|look at)\s+/g, "")
    .replace(/\b(my|the|all)\s+/g, "")
    .trim();
  const bareForm = /^(?:(?:completed|finished|done|open|incomplete|unfinished|pending)\s+)?reminders$/.test(core);
  const triggered = bareForm || APPLE_REMINDERS_TRIGGERS.some((pattern) => pattern.test(normalized));
  if (!triggered) return null;

  const completedIntent = COMPLETED_WORDS.test(normalized);
  const openIntent = /\b(open|incomplete|unfinished|pending)\b/.test(normalized);

  let leftover = normalized
    .replace(/\b(apple|icloud)\s+reminders?\b/g, " ")
    .replace(/\breminders?\s+(app|list)\b/g, " ")
    .replace(/\breminders?\b/g, " ")
    .replace(COMPLETED_WORDS, " ")
    .replace(/\b(open|incomplete|unfinished|pending)\b/g, " ");
  for (const pattern of FILLER_PATTERNS) leftover = leftover.replace(pattern, " ");
  const query = leftover.replace(/\s+/g, " ").trim();

  return {
    query: query.length > 1 ? query : undefined,
    includeCompleted: completedIntent || !openIntent,
    completedOnly: completedIntent && query.length <= 1
  };
}
