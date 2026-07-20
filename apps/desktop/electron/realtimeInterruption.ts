export type OpenAIInterruptionReason = "speech" | "manual" | "shutdown";

export type OpenAIInterruptionState = {
  responseID: string;
  responseActive: boolean;
  audioItemID: string;
  audioMs: number;
};

export type OpenAIInterruptionPlan = {
  reason: OpenAIInterruptionReason;
  responseID: string;
  audioItemID: string;
  audioEndMs: number;
  shouldCancelResponse: boolean;
  shouldTruncateAudio: boolean;
  shouldClearPendingResponse: boolean;
};

export function playedOpenAIAudioMs(receivedAudioMs: number, playbackStartedAt: number, now = Date.now()) {
  const received = Math.max(0, Math.round(Number(receivedAudioMs) || 0));
  const startedAt = Number(playbackStartedAt) || 0;
  if (!received || !startedAt) return 0;
  return Math.min(received, Math.max(0, Math.round(now - startedAt)));
}

export function planOpenAIInterruption(
  state: OpenAIInterruptionState,
  reason: OpenAIInterruptionReason
): OpenAIInterruptionPlan {
  const responseID = state.responseID.trim();
  const audioItemID = state.audioItemID.trim();
  return {
    reason,
    responseID,
    audioItemID,
    audioEndMs: Math.max(0, Math.round(Number(state.audioMs) || 0)),
    // Speech-start uses the server's interrupt_response setting. Sending another
    // response.cancel races the automatic cancellation and creates stale errors.
    shouldCancelResponse: reason === "manual" && state.responseActive,
    shouldTruncateAudio: Boolean(audioItemID),
    shouldClearPendingResponse: reason !== "shutdown"
  };
}

function boundedAdd(values: Set<string>, value: string, limit: number) {
  const normalized = value.trim();
  if (!normalized) return;
  values.delete(normalized);
  values.add(normalized);
  while (values.size > limit) {
    const oldest = values.values().next().value;
    if (typeof oldest === "string") values.delete(oldest);
    else break;
  }
}

export class OpenAIInterruptedResponseTracker {
  private readonly responseIDs = new Set<string>();
  private readonly itemIDs = new Set<string>();

  constructor(private readonly limit = 24) {}

  mark(responseID: string, itemID: string) {
    boundedAdd(this.responseIDs, responseID, this.limit);
    boundedAdd(this.itemIDs, itemID, this.limit);
  }

  matches(responseID: string, itemID: string) {
    return Boolean(
      (responseID && this.responseIDs.has(responseID))
      || (itemID && this.itemIDs.has(itemID))
    );
  }

  finish(responseID: string, itemID = "") {
    if (responseID) this.responseIDs.delete(responseID);
    if (itemID) this.itemIDs.delete(itemID);
  }

  clear() {
    this.responseIDs.clear();
    this.itemIDs.clear();
  }

  snapshot() {
    return {
      responseIDs: [...this.responseIDs],
      itemIDs: [...this.itemIDs]
    };
  }
}

export type RealtimeAudioSourceLike = {
  stop: () => void;
  disconnect: () => void;
};

export function stopRealtimeAudioSources<T extends RealtimeAudioSourceLike>(sources: Set<T>) {
  let stopped = 0;
  for (const source of sources) {
    try {
      source.stop();
      stopped += 1;
    } catch {
      // The source may already have ended.
    }
    try {
      source.disconnect();
    } catch {
      // The source may already be disconnected.
    }
  }
  sources.clear();
  return stopped;
}
