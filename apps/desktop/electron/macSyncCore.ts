import { createHash } from "node:crypto";

export const macSyncProtocolVersion = 2;

export type MacSyncVersion = {
  updatedAt: number;
  machineID: string;
  contentHash: string;
};

export type VersionedRecord<T> = {
  id: string;
  version: MacSyncVersion;
  value: T;
};

function stableValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stableValue);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => [key, stableValue(entry)])
  );
}

export function macSyncStableStringify(value: unknown) {
  return JSON.stringify(stableValue(value));
}

export function macSyncContentHash(value: unknown) {
  return createHash("sha256").update(macSyncStableStringify(value)).digest("hex");
}

export function normalizeMacSyncVersion(value: unknown, fallback: Partial<MacSyncVersion> = {}): MacSyncVersion {
  const object = value && typeof value === "object" ? value as Record<string, unknown> : {};
  const updatedAt = Number(object.updatedAt ?? fallback.updatedAt ?? 0);
  return {
    updatedAt: Number.isFinite(updatedAt) && updatedAt > 0 ? updatedAt : 0,
    machineID: String(object.machineID ?? fallback.machineID ?? "").trim().toLowerCase(),
    contentHash: String(object.contentHash ?? fallback.contentHash ?? "").trim().toLowerCase()
  };
}

export function compareMacSyncVersions(left: MacSyncVersion, right: MacSyncVersion) {
  if (left.updatedAt !== right.updatedAt) return left.updatedAt < right.updatedAt ? -1 : 1;
  const machineCompare = left.machineID.localeCompare(right.machineID);
  if (machineCompare) return machineCompare;
  return left.contentHash.localeCompare(right.contentHash);
}

export function newestMacSyncVersion(left: MacSyncVersion, right: MacSyncVersion) {
  return compareMacSyncVersions(left, right) >= 0 ? left : right;
}

export function macSyncChangedAfter(version: MacSyncVersion, base?: MacSyncVersion | null) {
  return !base || compareMacSyncVersions(version, base) > 0;
}

export type MacSyncReconciliation = "same" | "incoming" | "local" | "conflict-incoming" | "conflict-local";

export function decideMacSyncReconciliation(input: {
  localExists: boolean;
  localVersion: MacSyncVersion;
  incomingVersion: MacSyncVersion;
  baseVersion?: MacSyncVersion | null;
  sameContent: boolean;
  preserveInitialDifference?: boolean;
}): MacSyncReconciliation {
  if (!input.localExists) return "incoming";
  if (input.sameContent) return "same";
  const incomingWins = compareMacSyncVersions(input.incomingVersion, input.localVersion) > 0;
  const conflict = input.baseVersion
    ? macSyncChangedAfter(input.localVersion, input.baseVersion) && macSyncChangedAfter(input.incomingVersion, input.baseVersion)
    : input.preserveInitialDifference === true;
  if (conflict) return incomingWins ? "conflict-incoming" : "conflict-local";
  return incomingWins ? "incoming" : "local";
}

export function macSyncConflictID(noteID: string, losingVersion: MacSyncVersion) {
  const digest = createHash("sha256")
    .update(`${noteID.toLowerCase()}\0${losingVersion.updatedAt}\0${losingVersion.machineID}\0${losingVersion.contentHash}`)
    .digest("hex")
    .slice(0, 24);
  return `conflict_${digest}`;
}

export function macSyncLegacyPlannerItemID(containerID: string, visibleBlock: string, occurrence: number) {
  const digest = createHash("sha256")
    .update(`${containerID.toLowerCase()}\0${visibleBlock.replace(/\r\n/g, "\n").trim()}\0${occurrence}`)
    .digest("hex")
    .slice(0, 24);
  return `legacy_${digest}`;
}

export function macSyncScanCursor(snapshotStartedAt: number) {
  return String(Math.max(1, Math.floor(snapshotStartedAt)));
}

export function macSyncChangedSince(updatedAt: number, since: number) {
  if (!Number.isFinite(updatedAt) || updatedAt <= 0) return false;
  if (!Number.isFinite(since) || since <= 0) return true;
  return updatedAt >= since;
}

export function mergeVersionedRecords<T>(local: VersionedRecord<T>[], incoming: VersionedRecord<T>[]) {
  const records = new Map<string, VersionedRecord<T>>();
  for (const record of [...local, ...incoming]) {
    const existing = records.get(record.id);
    if (!existing || compareMacSyncVersions(record.version, existing.version) > 0) records.set(record.id, record);
  }
  return [...records.values()];
}
