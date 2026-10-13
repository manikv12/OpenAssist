import type { SecondBrainPollStatus, SecondBrainRunOutcome } from "./secondBrainAutonomousRunnerCore.js";

export type SecondBrainOwnerRunnerHostPort = {
  runUntilStopped(input: {
    pollIntervalMs: number;
    idlePollIntervalMs: number;
    signal: AbortSignal;
    onOutcome: (outcome: SecondBrainRunOutcome, poll?: SecondBrainPollStatus) => void;
  }): Promise<void>;
  stop(): Promise<void> | void;
};

export type SecondBrainOwnerRunnerStatus = {
  enabled: boolean;
  running: boolean;
  paused: boolean;
  reason: string;
  lastOutcome?: SecondBrainRunOutcome;
  /** Backoff state so the desktop can show when the next claim happens. */
  poll?: SecondBrainPollStatus;
  lastError?: string;
};

/** Main-process lifecycle wrapper. It never receives renderer data or auth. */
export class SecondBrainOwnerRunnerService {
  private host?: SecondBrainOwnerRunnerHostPort;
  private abort?: AbortController;
  private loop?: Promise<void>;
  private state: SecondBrainOwnerRunnerStatus;

  constructor(private readonly options: {
    createHost(): Promise<SecondBrainOwnerRunnerHostPort> | SecondBrainOwnerRunnerHostPort;
    enabled: boolean;
    pollIntervalMs?: number;
    /** Idle backoff ceiling. Default 15 minutes, clamped to 1-30 minutes. */
    idlePollIntervalMs?: number;
    onStatus?: (status: SecondBrainOwnerRunnerStatus) => void;
  }) {
    this.state = { enabled: options.enabled, running: false, paused: false, reason: "not-started" };
  }

  status() {
    return structuredClone(this.state);
  }

  async setEnabled(enabled: boolean) {
    this.state.enabled = enabled;
    if (!enabled) await this.stop("disabled");
    else await this.start("enabled");
    return this.status();
  }

  async start(reason = "manual") {
    if (!this.state.enabled || this.loop) return this.status();
    const abort = new AbortController();
    this.abort = abort;
    this.state = { ...this.state, running: true, paused: false, reason, lastError: undefined };
    this.emit();
    try {
      const host = await this.options.createHost();
      if (abort.signal.aborted) {
        await host.stop();
        return this.status();
      }
      this.host = host;
      const pollIntervalMs = Math.min(60_000, Math.max(30_000, this.options.pollIntervalMs ?? 60_000));
      const idlePollIntervalMs = Math.max(
        pollIntervalMs,
        Math.min(1_800_000, Math.max(60_000, this.options.idlePollIntervalMs ?? 900_000))
      );
      const loop = host.runUntilStopped({
        pollIntervalMs,
        idlePollIntervalMs,
        signal: abort.signal,
        onOutcome: (lastOutcome, poll) => {
          this.state = { ...this.state, lastOutcome, ...(poll ? { poll } : {}) };
          this.emit();
        },
      }).catch((error) => {
        this.state = { ...this.state, lastError: error instanceof Error ? error.message : String(error) };
      }).finally(async () => {
        await Promise.resolve(host.stop()).catch(() => undefined);
        if (this.host === host) this.host = undefined;
        if (this.loop === loop) this.loop = undefined;
        if (this.abort === abort) this.abort = undefined;
        this.state = { ...this.state, running: false };
        this.emit();
      });
      this.loop = loop;
    } catch (error) {
      this.abort = undefined;
      this.state = {
        ...this.state,
        running: false,
        lastError: error instanceof Error ? error.message : String(error),
      };
      this.emit();
    }
    return this.status();
  }

  async stop(reason = "manual") {
    const loop = this.loop;
    this.abort?.abort();
    if (this.host) await Promise.resolve(this.host.stop()).catch(() => undefined);
    if (loop) await loop.catch(() => undefined);
    this.state = { ...this.state, running: false, reason };
    this.emit();
    return this.status();
  }

  async pause(reason: "sleep" | "lock") {
    await this.stop(reason);
    this.state = { ...this.state, paused: true, reason };
    this.emit();
    return this.status();
  }

  async resume(reason: "wake" | "unlock") {
    this.state = { ...this.state, paused: false, reason };
    this.emit();
    return this.start(reason);
  }

  private emit() {
    this.options.onStatus?.(this.status());
  }
}
