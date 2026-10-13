import path from "node:path";
import {
  MemorySourceSyncService,
  type MemorySourceSyncResult,
  type MemorySourceSyncServiceOptions,
  type MemorySourceUploadRequest
} from "./memorySourceSyncService.js";
import type { MemorySourceKind, MemorySourcePreview } from "./memorySourceSyncCore.js";

type JsonObject = Record<string, unknown>;

export const memorySourceFileSyncToolName = "sync_second_brain_memory_source_file";
export const memorySourceStatusToolName = "upsert_second_brain_memory_source";

export type AuthenticatedWorkspaceToolCaller = (toolName: string, argumentsValue: JsonObject) => Promise<unknown>;

export type NamedWorkspaceToolBroker = {
  callNamedTool: (toolName: string, argumentsValue: JsonObject, confirmed: boolean) => Promise<unknown>;
};

/** Build a caller from the existing Codex-authenticated Workspace broker. */
export function authenticatedWorkspaceToolCaller(broker: NamedWorkspaceToolBroker): AuthenticatedWorkspaceToolCaller {
  return (toolName, argumentsValue) => broker.callNamedTool(toolName, argumentsValue, true);
}

export type MemorySourceWorkspaceCoordinatorOptions = Omit<MemorySourceSyncServiceOptions, "upload"> & {
  callWorkspaceTool: AuthenticatedWorkspaceToolCaller;
};

export type MemorySourcePreviewFile = {
  source: MemorySourceKind;
  relativePath: string;
  size: number;
};

export type MemorySourceSyncPreviewSummary = {
  device: {
    id: string;
    name: string;
    previousNames: string[];
  };
  changed: MemorySourcePreviewFile[];
  removedLocally: MemorySourcePreviewFile[];
  unchangedCount: number;
  counts: Record<MemorySourceKind, number>;
  note: string;
};

function objectValue(value: unknown): JsonObject | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : null;
}

function firstString(...values: unknown[]) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
}

function nestedResult(value: unknown): JsonObject {
  const root = objectValue(value) ?? {};
  if (root.response) return nestedResult(root.response);
  for (const key of ["result", "structuredContent", "output"]) {
    const nested = objectValue(root[key]);
    if (nested) return nested;
  }
  const texts = Array.isArray(root.content) ? root.content.map((item) => objectValue(item)?.text) : [root.resultText];
  for (const text of texts) {
    if (typeof text !== "string") continue;
    try { const parsed = objectValue(JSON.parse(text)); if (parsed) return parsed; } catch { /* A prose notice is not the result. */ }
  }
  return root;
}

function requireSuccessfulToolResult(value: unknown, toolName: string) {
  const root = objectValue(value) ?? {};
  const response = objectValue(root.response);
  if (root.ok === false || root.isError === true || response?.isError === true) {
    throw new Error(firstString(root.error, root.message, root.resultText)
      || `${toolName} could not complete the request.`);
  }
  return value;
}

function uploadResult(value: unknown) {
  const result = nestedResult(value);
  const file = objectValue(result.file) ?? objectValue(result.driveFile) ?? objectValue(result.memoryFile) ?? result;
  const remoteID = firstString(file.currentFileId, file.fileId, file.driveFileId, file.id);
  if (!remoteID) throw new Error("Workspace did not return a saved memory file pointer.");
  const remoteURL = firstString(file.url, file.webViewLink, file.link) || `https://drive.google.com/file/d/${encodeURIComponent(remoteID)}/view`;
  return {
    ...(remoteID ? { remoteID } : {}),
    ...(remoteURL ? { remoteURL } : {})
  };
}

function safeErrorCode(result: MemorySourceSyncResult, source: MemorySourceKind) {
  return result.failed.some((failure) => failure.source === source) ? "sync_failed" : undefined;
}

function sourceLabel(source: MemorySourceKind) {
  return source === "codex" ? "Codex memory" : "Claude memory";
}

function ms(value: string | undefined) {
  if (!value) return undefined;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function safePreview(preview: MemorySourcePreview): MemorySourceSyncPreviewSummary {
  const present = (file: { source: MemorySourceKind; relativePath: string; size: number }): MemorySourcePreviewFile => ({
    source: file.source,
    relativePath: file.relativePath,
    size: file.size
  });
  return {
    device: {
      id: preview.device.machineID,
      name: preview.device.currentName,
      previousNames: preview.device.nameHistory
        .map((entry) => entry.name)
        .filter((name) => name !== preview.device.currentName)
    },
    changed: preview.changed.map(present),
    removedLocally: preview.removed.map(present),
    unchangedCount: preview.unchanged.length,
    counts: preview.counts,
    note: "Only curated Markdown memory files are included. Conversations, sessions, credentials, raw histories, rollout summaries, tasks, and skills are excluded. Local removals are recorded but never delete Drive files."
  };
}

/**
 * A narrow bridge between local curated-memory discovery and authenticated
 * OpenAssist Workspace tools. It deliberately requires the dedicated memory
 * file tool; it never falls back to a generic Drive text upload because that
 * cannot safely create the nested Second Brain folder tree.
 */
export class MemorySourceWorkspaceCoordinator {
  private readonly service: MemorySourceSyncService;
  private approvedFingerprint = "";

  constructor(private readonly options: MemorySourceWorkspaceCoordinatorOptions) {
    this.service = new MemorySourceSyncService({
      ...options,
      upload: (request) => this.upload(request)
    });
  }

  private async upload(request: MemorySourceUploadRequest) {
    const result = requireSuccessfulToolResult(await this.options.callWorkspaceTool(memorySourceFileSyncToolName, {
      deviceId: request.machineID,
      sourceId: request.source,
      sourceKind: request.source,
      displayName: request.machineName,
      nameHistory: request.machineNameHistory,
      relativePath: request.relativePath,
      content: request.content,
      contentHash: request.contentHash,
      mimeType: request.mimeType,
      idempotencyKey: request.idempotencyKey
    }), memorySourceFileSyncToolName);
    return uploadResult(result);
  }

  preview() {
    const preview = this.service.preview();
    this.approvedFingerprint = preview.fingerprint;
    return safePreview(preview);
  }

  async sync() {
    if (!this.approvedFingerprint) {
      throw new Error("Preview the memory files before syncing.");
    }
    const expectedFingerprint = this.approvedFingerprint;
    this.approvedFingerprint = "";
    const result = await this.service.sync(expectedFingerprint);
    const statusErrors: Array<{ source: MemorySourceKind; error: string }> = [];
    for (const source of ["codex", "claude"] as const) {
      const sourceState = result.state.sources[source];
      try {
        requireSuccessfulToolResult(await this.options.callWorkspaceTool(memorySourceStatusToolName, {
          deviceId: result.state.device.machineID,
          sourceId: source,
          kind: source,
          displayName: result.state.device.currentName,
          locationLabel: sourceLabel(source),
          // Per-source manifest hash only. The combined fingerprint would make
          // every source look identical on the server.
          manifestHash: sourceState.fingerprint ?? result.preview.fingerprints[source],
          manifestCount: result.preview.counts[source],
          lastAttemptedAt: ms(sourceState.lastAttemptAt ?? result.state.lastAttemptAt),
          lastSuccessAt: ms(sourceState.lastSuccessfulAt ?? result.state.lastSuccessfulAt),
          status: safeErrorCode(result, source) ? "error" : "current",
          ...(safeErrorCode(result, source) ? { errorCode: safeErrorCode(result, source) } : {})
        }), memorySourceStatusToolName);
      } catch (error) {
        statusErrors.push({
          source,
          error: error instanceof Error ? error.message : "Could not report memory-source status."
        });
      }
    }
    return {
      ok: result.ok && statusErrors.length === 0,
      preview: safePreview(result.preview),
      uploaded: result.uploaded,
      skipped: result.skipped,
      removedLocally: result.removed,
      failed: result.failed,
      statusErrors,
      lastSuccessfulAt: result.state.lastSuccessfulAt,
      destinationRoot: path.posix.join(
        "OpenAssist",
        "Second Brain",
        "Memory Sources",
        result.state.device.machineID
      )
    };
  }
}
