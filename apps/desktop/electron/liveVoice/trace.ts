import { appendFile, mkdir, rename, stat } from "node:fs/promises";
import path from "node:path";

export type LiveVoiceTraceEvent = {
  at: number;
  type: string;
  turnID?: string;
  callID?: string;
  capabilityID?: string;
  durationMs?: number;
  provider?: string;
  textLength?: number;
  textHash?: string;
  errorCode?: string;
  detail?: string;
};

export class LiveVoiceTrace {
  private writeQueue = Promise.resolve();

  constructor(
    private readonly directory: string,
    private readonly maxBytes = 512 * 1024,
    private readonly maxFiles = 4
  ) {}

  record(event: LiveVoiceTraceEvent) {
    const safe = {
      ...event,
      detail: event.detail?.replace(/\s+/g, " ").trim().slice(0, 240)
    };
    this.writeQueue = this.writeQueue
      .then(() => this.append(safe))
      .catch(() => undefined);
  }

  async flush() {
    await this.writeQueue;
  }

  private async append(event: LiveVoiceTraceEvent) {
    await mkdir(this.directory, { recursive: true });
    const file = path.join(this.directory, "live-voice.jsonl");
    const line = `${JSON.stringify(event)}\n`;
    const size = await stat(file).then((value) => value.size).catch(() => 0);
    if (size + Buffer.byteLength(line) > this.maxBytes) await this.rotate(file);
    await appendFile(file, line, "utf8");
  }

  private async rotate(file: string) {
    for (let index = this.maxFiles - 1; index >= 1; index -= 1) {
      const source = index === 1 ? file : `${file}.${index - 1}`;
      const destination = `${file}.${index}`;
      await rename(source, destination).catch(() => undefined);
    }
  }
}
