export type LiveVoiceHistoryRole = "user" | "assistant";

export type LiveVoiceHistoryMessage = {
  role: LiveVoiceHistoryRole;
  text: string;
};

export type LiveVoiceCompletedTurn = {
  id: string;
  userText: string;
  assistantText: string;
  ownedExternally: boolean;
};

export type LiveVoiceBootstrapContext = {
  earlierHighlights: string;
  messages: LiveVoiceHistoryMessage[];
};

export const liveVoiceContinuityLimits = {
  recentTurns: 10,
  recentCharacters: 12_000,
  earlierTurns: 10,
  earlierCharacters: 4_000,
  messageCharacters: 2_000,
  geminiResumeTtlMs: 2 * 60 * 60 * 1_000,
  geminiResumeMaxEntries: 8
} as const;

function compactText(value: unknown, maxCharacters: number = liveVoiceContinuityLimits.messageCharacters) {
  const text = typeof value === "string" ? value.replace(/\s+/g, " ").trim() : "";
  if (text.length <= maxCharacters) return text;
  return text.slice(0, Math.max(0, maxCharacters - 1)).trimEnd() + "…";
}

function historyRole(value: unknown): LiveVoiceHistoryRole | undefined {
  const role = typeof value === "string" ? value.trim().toLowerCase() : "";
  return role === "user" || role === "assistant" ? role : undefined;
}

export function pairLiveVoiceTranscript(
  entries: ReadonlyArray<{ role?: unknown; text?: unknown }>
): Array<{ user: LiveVoiceHistoryMessage; assistant: LiveVoiceHistoryMessage }> {
  const turns: Array<{ user: LiveVoiceHistoryMessage; assistant: LiveVoiceHistoryMessage }> = [];
  const seen = new Set<string>();
  let pendingUser: LiveVoiceHistoryMessage | undefined;

  for (const entry of entries) {
    const role = historyRole(entry.role);
    const text = compactText(entry.text);
    if (!role || !text) continue;
    if (role === "user") {
      if (pendingUser && pendingUser.text === text) continue;
      pendingUser = { role, text };
      continue;
    }
    if (!pendingUser) continue;
    const assistant: LiveVoiceHistoryMessage = { role, text };
    const key = `${pendingUser.text.toLocaleLowerCase()}\u0000${assistant.text.toLocaleLowerCase()}`;
    if (!seen.has(key)) {
      seen.add(key);
      turns.push({ user: pendingUser, assistant });
    }
    pendingUser = undefined;
  }

  return turns;
}

function fitMessages(messages: LiveVoiceHistoryMessage[], maxCharacters: number) {
  let remaining = maxCharacters;
  return messages.map((message, index) => {
    const remainingMessages = messages.length - index;
    const allowance = Math.min(
      liveVoiceContinuityLimits.messageCharacters,
      Math.max(1, Math.floor(remaining / remainingMessages))
    );
    const text = compactText(message.text, allowance);
    remaining = Math.max(0, remaining - text.length);
    return { ...message, text };
  });
}

export function buildLiveVoiceBootstrapContext(
  entries: ReadonlyArray<{ role?: unknown; text?: unknown }>
): LiveVoiceBootstrapContext {
  const turns = pairLiveVoiceTranscript(entries);
  const recentTurns = turns.slice(-liveVoiceContinuityLimits.recentTurns);
  const earlierTurns = turns.slice(
    Math.max(0, turns.length - liveVoiceContinuityLimits.recentTurns - liveVoiceContinuityLimits.earlierTurns),
    Math.max(0, turns.length - liveVoiceContinuityLimits.recentTurns)
  );
  const messages = fitMessages(
    recentTurns.flatMap((turn) => [turn.user, turn.assistant]),
    liveVoiceContinuityLimits.recentCharacters
  );
  const earlierHighlights = compactText(
    earlierTurns.map((turn) => [
      `User: ${compactText(turn.user.text, 180)}`,
      `Assistant: ${compactText(turn.assistant.text, 220)}`
    ].join("\n")).join("\n\n"),
    liveVoiceContinuityLimits.earlierCharacters
  );
  return { earlierHighlights, messages };
}

export class LiveVoiceCompletedTurnTracker {
  private current?: {
    id: string;
    userText: string;
    assistantText: string;
    ownedExternally: boolean;
    interrupted: boolean;
  };
  private completedIDs = new Set<string>();
  private nextTurnOwnedExternally = false;

  beginUser(id: string, text: string) {
    const userText = compactText(text);
    if (!id || !userText) return;
    if (this.current?.id === id) {
      this.current.userText = userText;
      return;
    }
    this.current = {
      id,
      userText,
      assistantText: "",
      ownedExternally: this.nextTurnOwnedExternally,
      interrupted: false
    };
    this.nextTurnOwnedExternally = false;
  }

  appendAssistant(text: string) {
    if (!this.current) return;
    this.current.assistantText = compactText(
      `${this.current.assistantText}${this.current.assistantText ? " " : ""}${text}`
    );
  }

  setAssistant(text: string) {
    if (!this.current) return;
    this.current.assistantText = compactText(text);
  }

  markOwnedExternally() {
    if (this.current) this.current.ownedExternally = true;
    else this.nextTurnOwnedExternally = true;
  }

  markInterrupted() {
    if (this.current) this.current.interrupted = true;
  }

  finish(): LiveVoiceCompletedTurn | null {
    const turn = this.current;
    this.current = undefined;
    if (!turn || turn.interrupted || !turn.userText || !turn.assistantText || this.completedIDs.has(turn.id)) {
      return null;
    }
    this.completedIDs.add(turn.id);
    if (this.completedIDs.size > 100) {
      const oldest = this.completedIDs.values().next().value;
      if (oldest) this.completedIDs.delete(oldest);
    }
    return {
      id: turn.id,
      userText: turn.userText,
      assistantText: turn.assistantText,
      ownedExternally: turn.ownedExternally
    };
  }
}

type GeminiResumeEntry = { handle: string; expiresAt: number; touchedAt: number };

export class GeminiResumptionHandleCache {
  private entries = new Map<string, GeminiResumeEntry>();

  constructor(
    private readonly now: () => number = () => Date.now(),
    private readonly ttlMs = liveVoiceContinuityLimits.geminiResumeTtlMs,
    private readonly maxEntries = liveVoiceContinuityLimits.geminiResumeMaxEntries
  ) {}

  get(key: string) {
    this.prune();
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    entry.touchedAt = this.now();
    return entry.handle;
  }

  set(key: string, handle: string) {
    if (!key || !handle) return;
    const now = this.now();
    this.entries.set(key, { handle, expiresAt: now + this.ttlMs, touchedAt: now });
    this.prune();
    if (this.entries.size <= this.maxEntries) return;
    const oldest = [...this.entries.entries()].sort((left, right) => left[1].touchedAt - right[1].touchedAt)[0];
    if (oldest) this.entries.delete(oldest[0]);
  }

  delete(key: string) {
    this.entries.delete(key);
  }

  get size() {
    this.prune();
    return this.entries.size;
  }

  private prune() {
    const now = this.now();
    for (const [key, entry] of this.entries) {
      if (entry.expiresAt <= now) this.entries.delete(key);
    }
  }
}

export const geminiResumptionHandles = new GeminiResumptionHandleCache();

export function geminiResumptionCacheKey(input: {
  threadKey: string;
  model: string;
  voice: string;
  instructionVersion: string;
}) {
  return [input.threadKey, input.model, input.voice, input.instructionVersion]
    .map((part) => part.trim())
    .join("\u0000");
}
