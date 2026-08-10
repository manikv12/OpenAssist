export type NarrationState = "queued" | "reserved" | "streaming" | "playing" | "interrupted" | "delivered";
export type NarrationKind = "conversation" | "knowledge" | "delegated" | "status" | "failure" | "approval";

export type NarrationEnvelope = {
  deliveryID: string;
  sourceTurnID?: string;
  kind: NarrationKind;
  priority: number;
  text?: string;
  providerResponseID?: string;
  state: NarrationState;
  interruptionCount: number;
  createdAt: number;
};

export type NarrationInterruption = {
  envelope?: NarrationEnvelope;
  action: "none" | "retry-short" | "leave-silent";
};

export class NarrationRequestQueue<T extends { deliveryID: string }> {
  private readonly values: T[] = [];
  private readonly ids = new Set<string>();

  enqueue(value: T) {
    if (this.ids.has(value.deliveryID)) return false;
    this.ids.add(value.deliveryID);
    this.values.push(value);
    return true;
  }

  shift() {
    const value = this.values.shift();
    if (value) this.ids.delete(value.deliveryID);
    return value;
  }

  clear() {
    this.values.length = 0;
    this.ids.clear();
  }

  removeWhere(predicate: (value: T) => boolean) {
    const removed: T[] = [];
    for (let index = this.values.length - 1; index >= 0; index -= 1) {
      const value = this.values[index];
      if (!value || !predicate(value)) continue;
      removed.unshift(value);
      this.values.splice(index, 1);
      this.ids.delete(value.deliveryID);
    }
    return removed;
  }

  get size() {
    return this.values.length;
  }

  entries() {
    return this.values.slice();
  }
}

export class NarrationArbiter {
  private readonly entries = new Map<string, NarrationEnvelope>();
  private activeID = "";

  enqueue(input: Omit<NarrationEnvelope, "state" | "interruptionCount">) {
    const existing = this.entries.get(input.deliveryID);
    if (existing) return existing;
    const entry: NarrationEnvelope = { ...input, state: "queued", interruptionCount: 0 };
    this.entries.set(entry.deliveryID, entry);
    return entry;
  }

  reserve(deliveryID: string) {
    if (this.activeID && this.activeID !== deliveryID) return false;
    const entry = this.entries.get(deliveryID);
    if (!entry || !["queued", "interrupted"].includes(entry.state)) return false;
    this.activeID = deliveryID;
    entry.state = "reserved";
    return true;
  }

  active() {
    return this.activeID ? this.entries.get(this.activeID) : undefined;
  }

  isFree() {
    return !this.activeID;
  }

  markStreaming(deliveryID: string, providerResponseID?: string) {
    const entry = this.entries.get(deliveryID);
    if (!entry || this.activeID !== deliveryID) return false;
    entry.state = "streaming";
    if (providerResponseID) entry.providerResponseID = providerResponseID;
    return true;
  }

  markPlaying(deliveryID: string) {
    const entry = this.entries.get(deliveryID);
    if (!entry || this.activeID !== deliveryID) return false;
    entry.state = "playing";
    return true;
  }

  finishPlayback(deliveryID: string) {
    const entry = this.entries.get(deliveryID);
    if (!entry || this.activeID !== deliveryID) return undefined;
    entry.state = "delivered";
    this.activeID = "";
    return entry;
  }

  finishWithoutAudio(deliveryID: string) {
    return this.finishPlayback(deliveryID);
  }

  interruptActive() : NarrationInterruption {
    const entry = this.active();
    if (!entry) return { action: "none" };
    entry.interruptionCount += 1;
    entry.state = "interrupted";
    this.activeID = "";
    if (entry.kind === "delegated" && entry.interruptionCount === 1) {
      entry.state = "queued";
      return { envelope: entry, action: "retry-short" };
    }
    if (entry.kind === "delegated") {
      entry.state = "delivered";
      return { envelope: entry, action: "leave-silent" };
    }
    return { envelope: entry, action: "none" };
  }

  queued() {
    return [...this.entries.values()]
      .filter((entry) => entry.state === "queued")
      .sort((left, right) => right.priority - left.priority || left.createdAt - right.createdAt);
  }

  get(deliveryID: string) {
    return this.entries.get(deliveryID);
  }
}
