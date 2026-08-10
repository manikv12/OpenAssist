export type VoiceResultEnvelope = {
  deliveryID: string;
  sourceTurnID: string;
  kind: "capability" | "delegated";
  text: string;
  label: string;
  taskID?: string;
  callID?: string;
  capabilityID?: string;
  metadata?: Record<string, unknown>;
  createdAt: number;
  state: "queued" | "speaking" | "delivered";
};

export class VoiceResultOutbox {
  private readonly entries = new Map<string, VoiceResultEnvelope>();

  enqueue(input: Omit<VoiceResultEnvelope, "state">) {
    const existing = this.entries.get(input.deliveryID);
    if (existing) return existing;
    const entry: VoiceResultEnvelope = { ...input, state: "queued" };
    this.entries.set(entry.deliveryID, entry);
    this.prune();
    return entry;
  }

  next() {
    return [...this.entries.values()]
      .filter((entry) => entry.state === "queued")
      .sort((left, right) => left.createdAt - right.createdAt)[0];
  }

  mark(deliveryID: string, state: VoiceResultEnvelope["state"]) {
    const entry = this.entries.get(deliveryID);
    if (!entry) return false;
    if (entry.state === "delivered") return state === "delivered";
    entry.state = state;
    this.prune();
    return true;
  }

  pending() {
    return [...this.entries.values()]
      .filter((entry) => entry.state !== "delivered")
      .sort((left, right) => left.createdAt - right.createdAt);
  }

  get(deliveryID: string) {
    return this.entries.get(deliveryID);
  }

  removeTasks(taskIDs: ReadonlySet<string>) {
    if (!taskIDs.size) return 0;
    let removed = 0;
    for (const [deliveryID, entry] of this.entries) {
      if (!entry.taskID || !taskIDs.has(entry.taskID)) continue;
      this.entries.delete(deliveryID);
      removed += 1;
    }
    return removed;
  }

  private prune() {
    if (this.entries.size <= 100) return;
    const removable = [...this.entries.values()]
      .filter((entry) => entry.state === "delivered")
      .sort((left, right) => left.createdAt - right.createdAt);
    while (this.entries.size > 100 && removable.length) {
      const entry = removable.shift();
      if (entry) this.entries.delete(entry.deliveryID);
    }
  }
}
