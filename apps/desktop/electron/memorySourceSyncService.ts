import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  buildMemorySourcePreview,
  discoverMemorySources,
  emptyMemorySourceSyncState,
  memorySourceDestinationPath,
  memorySourceSyncSchemaVersion,
  memorySourceUploadIdempotencyKey,
  updateMemorySourceDeviceIdentity,
  type DiscoveredMemorySourceFile,
  type MemorySourceDeviceIdentity,
  type MemorySourceKind,
  type MemorySourcePreview,
  type MemorySourceSyncState
} from "./memorySourceSyncCore.js";

export type MemorySourceUploadRequest = {
  machineID: string;
  machineName: string;
  machineNameHistory: string[];
  source: MemorySourceKind;
  relativePath: string;
  destinationPath: string;
  mimeType: "text/markdown";
  content: string;
  contentHash: string;
  idempotencyKey: string;
};

export type MemorySourceUploadResult = {
  remoteID?: string;
  remoteURL?: string;
};

export type MemorySourceUploader = (request: MemorySourceUploadRequest) => Promise<MemorySourceUploadResult | void>;

export type MemorySourceSyncServiceOptions = {
  statePath: string;
  machineID: string;
  machineName: string;
  homeDir: string;
  codexRoot?: string;
  claudeRoot?: string;
  now?: () => Date;
  upload: MemorySourceUploader;
};

export type MemorySourceSyncResult = {
  ok: boolean;
  preview: MemorySourcePreview;
  uploaded: number;
  skipped: number;
  removed: number;
  failed: Array<{ source: MemorySourceKind; relativePath: string; error: string }>;
  state: MemorySourceSyncState;
};

function safeError(error: unknown) {
  return error instanceof Error ? error.message : String(error || "Memory source upload failed.");
}

function stateDirectory(statePath: string) {
  return path.dirname(path.resolve(statePath));
}

export function writeMemorySourceSyncState(statePath: string, state: MemorySourceSyncState) {
  const directory = stateDirectory(statePath);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(directory, 0o700); } catch { /* best effort */ }
  const temporaryPath = path.join(directory, `.${path.basename(statePath)}.${process.pid}.${randomUUID()}.tmp`);
  try {
    fs.writeFileSync(temporaryPath, `${JSON.stringify(state, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
    try { fs.chmodSync(temporaryPath, 0o600); } catch { /* best effort */ }
    fs.renameSync(temporaryPath, statePath);
    try { fs.chmodSync(statePath, 0o600); } catch { /* best effort */ }
  } finally {
    try { fs.rmSync(temporaryPath, { force: true }); } catch { /* best effort */ }
  }
}

export function readStoredState(statePath: string) {
  try {
    const parsed = JSON.parse(fs.readFileSync(statePath, "utf8")) as Partial<MemorySourceSyncState>;
    if (parsed.schemaVersion !== memorySourceSyncSchemaVersion || !parsed.device || !parsed.files || !parsed.sources) return null;
    return parsed as MemorySourceSyncState;
  } catch {
    return null;
  }
}

function sourceFileCount(files: Record<string, { source: MemorySourceKind; localMissing?: boolean }>, source: MemorySourceKind) {
  return Object.values(files).filter((file) => file.source === source && !file.localMissing).length;
}

export class MemorySourceSyncService {
  constructor(private readonly options: MemorySourceSyncServiceOptions) {}

  private nowISO() {
    return (this.options.now?.() ?? new Date()).toISOString();
  }

  private identity(existing?: MemorySourceDeviceIdentity) {
    return updateMemorySourceDeviceIdentity(existing, this.options.machineID, this.options.machineName, this.nowISO());
  }

  loadState() {
    const stored = readStoredState(this.options.statePath);
    if (stored) return { ...stored, device: this.identity(stored.device) };
    return emptyMemorySourceSyncState(this.identity());
  }

  preview(): MemorySourcePreview {
    const state = this.loadState();
    const discovery = discoverMemorySources({
      homeDir: this.options.homeDir,
      codexRoot: this.options.codexRoot,
      claudeRoot: this.options.claudeRoot
    });
    return buildMemorySourcePreview(state, discovery, state.device);
  }

  private readVerifiedContent(file: DiscoveredMemorySourceFile) {
    const content = fs.readFileSync(file.absolutePath, "utf8");
    const current = discoverMemorySources({
      homeDir: this.options.homeDir,
      codexRoot: file.source === "codex" ? this.options.codexRoot : path.join(this.options.homeDir, ".missing-codex-source"),
      claudeRoot: file.source === "claude" ? this.options.claudeRoot : path.join(this.options.homeDir, ".missing-claude-source"),
      maxFiles: 2_000
    }).files.find((candidate) => candidate.key === file.key);
    if (!current || current.contentHash !== file.contentHash) {
      throw new Error("The memory file changed while it was being prepared. Try syncing again.");
    }
    return content;
  }

  async sync(expectedFingerprint?: string): Promise<MemorySourceSyncResult> {
    const state = this.loadState();
    const discovery = discoverMemorySources({
      homeDir: this.options.homeDir,
      codexRoot: this.options.codexRoot,
      claudeRoot: this.options.claudeRoot
    });
    const preview = buildMemorySourcePreview(state, discovery, state.device);
    if (expectedFingerprint && discovery.fingerprint !== expectedFingerprint) {
      throw new Error("The memory files changed after the preview. Preview them again before syncing.");
    }
    const attemptAt = this.nowISO();
    const previousLastSuccessfulAt = state.lastSuccessfulAt;
    state.lastAttemptAt = attemptAt;
    state.lastError = undefined;
    for (const source of ["codex", "claude"] as const) {
      state.sources[source] = {
        ...state.sources[source],
        lastAttemptAt: attemptAt,
        lastError: undefined
      };
    }
    writeMemorySourceSyncState(this.options.statePath, state);

    const failed: MemorySourceSyncResult["failed"] = [];
    let uploaded = 0;
    for (const file of preview.changed) {
      try {
        const content = this.readVerifiedContent(file);
        const result = await this.options.upload({
          machineID: state.device.machineID,
          machineName: state.device.currentName,
          machineNameHistory: state.device.nameHistory.map((entry) => entry.name),
          source: file.source,
          relativePath: file.relativePath,
          destinationPath: memorySourceDestinationPath(state.device.machineID, file),
          mimeType: "text/markdown",
          content,
          contentHash: file.contentHash,
          idempotencyKey: memorySourceUploadIdempotencyKey(state.device.machineID, file)
        });
        const uploadedAt = this.nowISO();
        state.files[file.key] = {
          source: file.source,
          relativePath: file.relativePath,
          size: file.size,
          modifiedAt: file.modifiedAt,
          contentHash: file.contentHash,
          lastUploadedAt: uploadedAt,
          ...(result?.remoteID ? { remoteID: result.remoteID } : {}),
          ...(result?.remoteURL ? { remoteURL: result.remoteURL } : {})
        };
        uploaded += 1;
        // Save every completed file. A retry skips these files even when a
        // later upload in the same run fails.
        writeMemorySourceSyncState(this.options.statePath, state);
      } catch (error) {
        failed.push({ source: file.source, relativePath: file.relativePath, error: safeError(error) });
      }
    }

    const removedAt = this.nowISO();
    for (const removed of preview.removed) {
      const key = `${removed.source}:${removed.relativePath}`;
      state.files[key] = {
        ...removed,
        localMissing: true,
        removedAt: removed.removedAt ?? removedAt
      };
    }

    if (failed.length) {
      const message = `${failed.length} memory file${failed.length === 1 ? "" : "s"} could not be uploaded.`;
      state.lastSuccessfulAt = previousLastSuccessfulAt;
      state.lastError = message;
      for (const source of ["codex", "claude"] as const) {
        const sourceFailed = failed.filter((item) => item.source === source);
        state.sources[source] = {
          ...state.sources[source],
          fileCount: sourceFileCount(state.files, source),
          fingerprint: discovery.fingerprints[source],
          lastError: sourceFailed.length ? `${sourceFailed.length} file${sourceFailed.length === 1 ? "" : "s"} failed.` : undefined
        };
      }
    } else {
      const completedAt = this.nowISO();
      state.lastSuccessfulAt = completedAt;
      state.lastError = undefined;
      for (const source of ["codex", "claude"] as const) {
        state.sources[source] = {
          ...state.sources[source],
          fileCount: discovery.counts[source],
          fingerprint: discovery.fingerprints[source],
          lastSuccessfulAt: completedAt,
          lastError: undefined
        };
      }
    }
    writeMemorySourceSyncState(this.options.statePath, state);
    return {
      ok: failed.length === 0,
      preview,
      uploaded,
      skipped: preview.unchanged.length,
      removed: preview.removed.length,
      failed,
      state
    };
  }
}
