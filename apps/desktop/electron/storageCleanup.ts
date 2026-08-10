import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export type StorageCleanupCategory =
  | "generatedImages"
  | "imageJobs"
  | "generatedVideos"
  | "videoJobs"
  | "logs"
  | "backups";

export type StorageCleanupCategorySummary = {
  category: StorageCleanupCategory;
  label: string;
  itemCount: number;
  sizeBytes: number;
};

export type StorageCleanupPreview = {
  retentionDays: number;
  cutoffAt: string;
  itemCount: number;
  sizeBytes: number;
  categories: StorageCleanupCategorySummary[];
  protectedData: string[];
};

export type StorageCleanupResult = StorageCleanupPreview & {
  deletedItemCount: number;
  freedBytes: number;
  errors: string[];
  completedAt: string;
};

type StorageCleanupCandidate = {
  category: StorageCleanupCategory;
  itemPath: string;
  sizeBytes: number;
  modifiedAtMs: number;
};

type StorageCleanupOptions = {
  supportRoot?: string;
  logRoot?: string;
  retentionDays: number;
  nowMs?: number;
  approved?: boolean;
};

const categoryLabels: Record<StorageCleanupCategory, string> = {
  generatedImages: "Generated images",
  imageJobs: "Finished image jobs",
  generatedVideos: "Generated videos and keyframes",
  videoJobs: "Finished video jobs",
  logs: "Old diagnostic logs",
  backups: "Old safety and build backups"
};

const protectedData = [
  "Notes and planner items",
  "Normal chats and voice history",
  "Durable memories",
  "AI models and active work"
];

const backupDirectoryNames = [
  "BuildBackups",
  "CleanupBackups",
  "RecoveryBackups",
  "CodexThreadRewriteBackups"
];

function normalizedRetentionDays(value: number) {
  const days = Math.floor(Number(value));
  if (!Number.isFinite(days) || days < 1 || days > 3650) {
    throw new Error("Cleanup retention must be between 1 and 3650 days.");
  }
  return days;
}

function isInsideRoot(root: string, candidate: string) {
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return relative !== "" && !relative.startsWith("..") && !path.isAbsolute(relative);
}

async function statWithoutFollowingLinks(itemPath: string) {
  try {
    const stats = await fs.promises.lstat(itemPath);
    return stats.isSymbolicLink() ? null : stats;
  } catch {
    return null;
  }
}

async function entrySizeBytes(itemPath: string): Promise<number> {
  const stats = await statWithoutFollowingLinks(itemPath);
  if (!stats) return 0;
  if (!stats.isDirectory()) return stats.size;
  let total = 0;
  let entries: fs.Dirent[] = [];
  try {
    entries = await fs.promises.readdir(itemPath, { withFileTypes: true });
  } catch {
    return 0;
  }
  for (const entry of entries) {
    if (entry.isSymbolicLink()) continue;
    total += await entrySizeBytes(path.join(itemPath, entry.name));
  }
  return total;
}

async function directEntries(directory: string) {
  try {
    const names = await fs.promises.readdir(directory);
    const entries = await Promise.all(names.map(async (name) => {
      const itemPath = path.join(directory, name);
      const stats = await statWithoutFollowingLinks(itemPath);
      return stats ? { itemPath, stats } : null;
    }));
    return entries.filter((entry): entry is NonNullable<typeof entry> => Boolean(entry));
  } catch {
    return [];
  }
}

async function oldDirectFiles(
  directory: string,
  category: StorageCleanupCategory,
  cutoffMs: number,
  filter?: (itemPath: string) => Promise<boolean>
) {
  const candidates: StorageCleanupCandidate[] = [];
  for (const entry of await directEntries(directory)) {
    if (!entry.stats.isFile() || entry.stats.mtimeMs >= cutoffMs) continue;
    if (filter && !(await filter(entry.itemPath))) continue;
    candidates.push({
      category,
      itemPath: entry.itemPath,
      sizeBytes: entry.stats.size,
      modifiedAtMs: entry.stats.mtimeMs
    });
  }
  return candidates;
}

async function oldLogFiles(directory: string, cutoffMs: number): Promise<StorageCleanupCandidate[]> {
  const candidates: StorageCleanupCandidate[] = [];
  let entries: fs.Dirent[] = [];
  try {
    entries = await fs.promises.readdir(directory, { withFileTypes: true });
  } catch {
    return candidates;
  }
  for (const entry of entries) {
    if (entry.isSymbolicLink()) continue;
    const itemPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      candidates.push(...await oldLogFiles(itemPath, cutoffMs));
      continue;
    }
    const stats = await statWithoutFollowingLinks(itemPath);
    if (!stats?.isFile() || stats.mtimeMs >= cutoffMs) continue;
    candidates.push({ category: "logs", itemPath, sizeBytes: stats.size, modifiedAtMs: stats.mtimeMs });
  }
  return candidates;
}

async function oldFinishedJobs(
  directory: string,
  category: "imageJobs" | "videoJobs",
  cutoffMs: number
) {
  return oldDirectFiles(directory, category, cutoffMs, async (itemPath) => {
    if (path.extname(itemPath).toLowerCase() !== ".json") return false;
    try {
      const record = JSON.parse(await fs.promises.readFile(itemPath, "utf8")) as { status?: string };
      return record.status === "completed" || record.status === "failed" || record.status === "cancelled";
    } catch {
      return false;
    }
  });
}

async function oldGeneratedVideoEntries(directory: string, cutoffMs: number) {
  const candidates = await oldDirectFiles(directory, "generatedVideos", cutoffMs);
  const keyframeDirectory = path.join(directory, "Keyframes");
  for (const entry of await directEntries(keyframeDirectory)) {
    if (!entry.stats.isDirectory() || entry.stats.mtimeMs >= cutoffMs) continue;
    candidates.push({
      category: "generatedVideos",
      itemPath: entry.itemPath,
      sizeBytes: await entrySizeBytes(entry.itemPath),
      modifiedAtMs: entry.stats.mtimeMs
    });
  }
  return candidates;
}

async function oldBackupEntries(root: string, cutoffMs: number) {
  const candidates: StorageCleanupCandidate[] = [];
  for (const directoryName of backupDirectoryNames) {
    const directory = path.join(root, directoryName);
    const entries = (await directEntries(directory))
      .sort((left, right) => right.stats.mtimeMs - left.stats.mtimeMs);
    const retainedPaths = new Set(entries.slice(0, 1).map((entry) => entry.itemPath));
    for (const entry of entries) {
      if (retainedPaths.has(entry.itemPath) || entry.stats.mtimeMs >= cutoffMs) continue;
      candidates.push({
        category: "backups",
        itemPath: entry.itemPath,
        sizeBytes: await entrySizeBytes(entry.itemPath),
        modifiedAtMs: entry.stats.mtimeMs
      });
    }
  }
  return candidates;
}

async function collectCandidates(options: StorageCleanupOptions) {
  const retentionDays = normalizedRetentionDays(options.retentionDays);
  const nowMs = options.nowMs ?? Date.now();
  const support = options.supportRoot ?? path.join(os.homedir(), "Library/Application Support/OpenAssist");
  const logs = options.logRoot ?? path.join(os.homedir(), "Library/Logs/OpenAssist");
  const cutoffMs = nowMs - retentionDays * 24 * 60 * 60 * 1000;
  const knowledgeRoot = path.join(support, "Knowledge");
  const candidates = [
    ...await oldDirectFiles(path.join(knowledgeRoot, "Generated Images"), "generatedImages", cutoffMs),
    ...await oldFinishedJobs(path.join(knowledgeRoot, "Image Jobs"), "imageJobs", cutoffMs),
    ...await oldGeneratedVideoEntries(path.join(knowledgeRoot, "Generated Videos"), cutoffMs),
    ...await oldFinishedJobs(path.join(knowledgeRoot, "Short Video Jobs"), "videoJobs", cutoffMs),
    ...await oldLogFiles(logs, cutoffMs),
    ...await oldBackupEntries(support, cutoffMs)
  ];
  return { candidates, cutoffMs, retentionDays, support, logs };
}

function summarize(candidates: StorageCleanupCandidate[], retentionDays: number, cutoffMs: number): StorageCleanupPreview {
  const categories = (Object.keys(categoryLabels) as StorageCleanupCategory[]).map((category) => {
    const matching = candidates.filter((candidate) => candidate.category === category);
    return {
      category,
      label: categoryLabels[category],
      itemCount: matching.length,
      sizeBytes: matching.reduce((total, candidate) => total + candidate.sizeBytes, 0)
    };
  });
  return {
    retentionDays,
    cutoffAt: new Date(cutoffMs).toISOString(),
    itemCount: candidates.length,
    sizeBytes: candidates.reduce((total, candidate) => total + candidate.sizeBytes, 0),
    categories,
    protectedData
  };
}

export async function previewStorageCleanup(options: StorageCleanupOptions): Promise<StorageCleanupPreview> {
  const collected = await collectCandidates(options);
  return summarize(collected.candidates, collected.retentionDays, collected.cutoffMs);
}

export async function executeStorageCleanup(options: StorageCleanupOptions): Promise<StorageCleanupResult> {
  if (options.approved !== true) {
    throw new Error("Storage cleanup requires explicit approval.");
  }
  const collected = await collectCandidates(options);
  const errors: string[] = [];
  let deletedItemCount = 0;
  let freedBytes = 0;
  const allowedRoots = [
    path.join(collected.support, "Knowledge", "Generated Images"),
    path.join(collected.support, "Knowledge", "Image Jobs"),
    path.join(collected.support, "Knowledge", "Generated Videos"),
    path.join(collected.support, "Knowledge", "Short Video Jobs"),
    ...backupDirectoryNames.map((name) => path.join(collected.support, name)),
    collected.logs
  ];
  for (const candidate of collected.candidates) {
    const allowed = allowedRoots.some((root) => isInsideRoot(root, candidate.itemPath));
    if (!allowed) {
      errors.push(`Skipped an item outside the cleanup folders: ${candidate.itemPath}`);
      continue;
    }
    try {
      const stats = await statWithoutFollowingLinks(candidate.itemPath);
      if (!stats || stats.mtimeMs !== candidate.modifiedAtMs) continue;
      await fs.promises.rm(candidate.itemPath, { recursive: stats.isDirectory(), force: true });
      deletedItemCount += 1;
      freedBytes += candidate.sizeBytes;
    } catch (error) {
      errors.push(`${path.basename(candidate.itemPath)}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return {
    ...summarize(collected.candidates, collected.retentionDays, collected.cutoffMs),
    deletedItemCount,
    freedBytes,
    errors,
    completedAt: new Date().toISOString()
  };
}

export const __storageCleanupTestHooks = {
  backupDirectoryNames,
  protectedData
};
