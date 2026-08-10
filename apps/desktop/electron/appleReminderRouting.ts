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

// ---------------------------------------------------------------------------
// Natural-language "add a reminder" parsing.
//
// Voice models routinely call the add-reminder tool with EMPTY arguments even
// though the user's sentence contains everything ("add a reminder to take out
// the trash every Friday at 8am"). Instruction-level fixes did not stick, so
// the server derives {title, dueDate, recurrence} from the utterance itself.
// Deterministic and unit-tested; returns null when no confident title remains
// so callers can still ask a clarifying question.
// ---------------------------------------------------------------------------

export type ParsedAppleReminderAdd = {
  title: string;
  dueDateISO?: string;
  recurrence?: { frequency: "daily" | "weekly" | "monthly" | "yearly"; interval?: number };
};

const WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"] as const;

function nextWeekdayDate(base: Date, weekday: number, hour: number, minute: number) {
  const result = new Date(base);
  result.setHours(hour, minute, 0, 0);
  let delta = (weekday - base.getDay() + 7) % 7;
  // "on Friday" said ON a Friday before the time → today; after it → next week.
  if (delta === 0 && result.getTime() <= base.getTime()) delta = 7;
  result.setDate(result.getDate() + delta);
  return result;
}

export function parseAppleReminderAddRequest(rawText: string, now: Date = new Date()): ParsedAppleReminderAdd | null {
  let text = String(rawText || "")
    .toLowerCase()
    // "8:00 a.m." must survive punctuation stripping as "8:00 am".
    .replace(/\b([ap])\.?\s*m\.?(?=\s|$|[.?!,])/g, "$1m")
    .replace(/[.?!,]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!text) return null;

  // --- schedule extraction (matched fragments are removed from the title) ---
  let recurrence: ParsedAppleReminderAdd["recurrence"];
  let weekday: number | undefined;
  let dayOffset: number | undefined;
  let hour: number | undefined;
  let minute = 0;

  const strip = (pattern: RegExp, onMatch?: (match: RegExpMatchArray) => void) => {
    const match = text.match(pattern);
    if (!match) return false;
    onMatch?.(match);
    text = text.replace(pattern, " ").replace(/\s+/g, " ").trim();
    return true;
  };

  strip(/\bevery\s+(day|morning|evening|night)\b/, () => { recurrence = { frequency: "daily" }; });
  strip(/\b(daily)\b/, () => { recurrence = { frequency: "daily" }; });
  strip(/\bevery\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)s?\b/, (match) => {
    recurrence = { frequency: "weekly" };
    weekday = WEEKDAYS.indexOf(match[1] as typeof WEEKDAYS[number]);
  });
  strip(/\bevery\s+week\b|\bweekly\b/, () => { recurrence = recurrence ?? { frequency: "weekly" }; });
  strip(/\bevery\s+month\b|\bmonthly\b/, () => { recurrence = { frequency: "monthly" }; });
  strip(/\bevery\s+year\b|\byearly\b|\bannually\b/, () => { recurrence = { frequency: "yearly" }; });

  strip(/\b(?:on|this|next)?\s*(sunday|monday|tuesday|wednesday|thursday|friday|saturday)s?\b/, (match) => {
    if (weekday === undefined) weekday = WEEKDAYS.indexOf(match[1] as typeof WEEKDAYS[number]);
  });
  strip(/\btomorrow\b/, () => { dayOffset = 1; });
  strip(/\btonight\b/, () => { dayOffset = 0; if (hour === undefined) hour = 21; });
  strip(/\btoday\b/, () => { dayOffset = 0; });

  strip(/\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?|o'?clock)\b/, (match) => {
    hour = Number(match[1]) % 12;
    minute = match[2] ? Number(match[2]) : 0;
    if (/^p/.test(match[3])) hour += 12;
  });
  if (hour === undefined) {
    strip(/\bat\s+(\d{1,2})(?::(\d{2}))?\b/, (match) => {
      hour = Number(match[1]);
      minute = match[2] ? Number(match[2]) : 0;
    });
  }
  strip(/\b(?:in\s+the\s+)?morning\b/, () => { if (hour === undefined) hour = 9; });
  strip(/\b(?:in\s+the\s+)?afternoon\b/, () => { if (hour === undefined) hour = 15; });
  strip(/\b(?:in\s+the\s+)?evening\b/, () => { if (hour === undefined) hour = 18; });
  strip(/\b(?:at\s+)?night\b/, () => { if (hour === undefined) hour = 21; });
  strip(/\b(?:at\s+)?noon\b/, () => { hour = 12; minute = 0; });

  // --- title extraction ---
  text = text
    .replace(/\b(?:hey|ok|okay|so|um|uh)\b/g, " ")
    .replace(/\b(?:can|could|would|will)\s+you\b/g, " ")
    .replace(/\bplease\b/g, " ")
    .replace(/\b(?:add|create|set|make|put)\s+(?:a\s+|an\s+|another\s+)?(?:new\s+)?(?:repeating\s+|recurring\s+)?reminders?\b/g, " ")
    .replace(/\bremind\s+me\b/g, " ")
    .replace(/\b(?:in|to|on)\s+(?:my\s+|the\s+)?(?:apple\s+|icloud\s+)?reminders?(?:\s+app|\s+list)?\b/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^(?:to|that|for|about|says?|saying|titled|called)\s+/, "")
    .replace(/^(?:to|that|for|about)\s+/, "")
    .replace(/\s+(?:at|on|in|every|for)$/, "")
    .trim();

  // Spoken titles arrive quoted ("take out the trash") often enough that the
  // quotes would end up in the visible reminder; strip wrapping quotes only
  // (apostrophes inside words must survive).
  text = text.replace(/^["'‘’“”`]+/, "").replace(/["'‘’“”`]+$/, "").trim();
  if (text.length < 3) return null;
  // Bare confirmations ("yeah", "do it") answer a question; they are never
  // the reminder itself.
  if (/^(?:yeah|yes|yep|yup|no|nope|okay|ok|sure|please|thanks|thank you|do it|go ahead|sounds good|correct|right)$/.test(text)) {
    return null;
  }
  const title = text.charAt(0).toUpperCase() + text.slice(1);

  // --- due date assembly ---
  let dueDateISO: string | undefined;
  const wantsDate = weekday !== undefined || dayOffset !== undefined || hour !== undefined || recurrence !== undefined;
  if (wantsDate) {
    const resolvedHour = hour ?? 9;
    let due: Date;
    if (weekday !== undefined) {
      due = nextWeekdayDate(now, weekday, resolvedHour, minute);
    } else {
      due = new Date(now);
      due.setHours(resolvedHour, minute, 0, 0);
      const offset = dayOffset ?? (due.getTime() <= now.getTime() ? 1 : 0);
      due.setDate(due.getDate() + offset);
    }
    dueDateISO = due.toISOString();
  }

  return { title, dueDateISO, recurrence };
}

// Rename phrasing for update calls ("rename it to take out trash",
// 'update the title to "X"'). Returns the new title or null.
export function parseAppleReminderRenameTarget(rawText: string): string | null {
  const text = String(rawText || "")
    .replace(/\s+/g, " ")
    .trim();
  if (!text) return null;
  const match = text.match(
    /\b(?:rename(?:\s+(?:it|this|that|the\s+reminder(?:\s+with\s+id\s+\S+)?))?|retitle|change\s+(?:the\s+)?title(?:\s+of\s+[^]*?)?|(?:to\s+have\s+)?the\s+title|title\s+it|call\s+it|name\s+it)\s*(?:to|as|:)?\s+(.+)$/i
  );
  if (!match) return null;
  let title = match[1].trim()
    // Location suffix first — qualifiers below are end-anchored.
    .replace(/\s+in\s+(?:my\s+)?(?:apple\s+|icloud\s+)?reminders?(?:\s+app)?\s*$/i, "")
    // Trailing qualifiers said out loud, not part of the title.
    .replace(/\s*\((?:without|no)\s+(?:the\s+)?quot[^)]*\)\s*$/i, "")
    .replace(/\s+(?:without|with\s+no)\s+(?:the\s+)?quot(?:es|ation\s+marks?)?\s*$/i, "")
    .replace(/[.?!]+$/, "")
    .trim();
  title = title.replace(/^["'‘’“”`]+/, "").replace(/["'‘’“”`]+$/, "").trim();
  return title.length >= 2 ? title : null;
}
