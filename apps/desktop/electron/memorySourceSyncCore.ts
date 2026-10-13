import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export const memorySourceSyncSchemaVersion = 1;

export type MemorySourceKind = "codex" | "claude";

export type MemorySourceNameHistoryEntry = {
  name: string;
  firstSeenAt: string;
  lastSeenAt: string;
};

export type MemorySourceDeviceIdentity = {
  machineID: string;
  currentName: string;
  nameHistory: MemorySourceNameHistoryEntry[];
  firstSeenAt: string;
  lastSeenAt: string;
};

export type DiscoveredMemorySourceFile = {
  key: string;
  source: MemorySourceKind;
  relativePath: string;
  absolutePath: string;
  size: number;
  modifiedAt: number;
  contentHash: string;
};

export type MemorySourceFingerprints = Record<MemorySourceKind, string>;

export type MemorySourceDiscovery = {
  files: DiscoveredMemorySourceFile[];
  /** Fingerprint of every discovered file, used for preview-to-sync approval. */
  fingerprint: string;
  /** One manifest hash per source, so each source reports its own state. */
  fingerprints: MemorySourceFingerprints;
  counts: Record<MemorySourceKind, number>;
};

export type MemorySourceSyncedFile = {
  source: MemorySourceKind;
  relativePath: string;
  size: number;
  modifiedAt: number;
  contentHash: string;
  lastUploadedAt: string;
  remoteID?: string;
  remoteURL?: string;
  localMissing?: boolean;
  removedAt?: string;
};

export type MemorySourceStatus = {
  lastAttemptAt?: string;
  lastSuccessfulAt?: string;
  lastError?: string;
  fingerprint?: string;
  fileCount: number;
};

export type MemorySourceSyncState = {
  schemaVersion: 1;
  device: MemorySourceDeviceIdentity;
  files: Record<string, MemorySourceSyncedFile>;
  sources: Record<MemorySourceKind, MemorySourceStatus>;
  lastAttemptAt?: string;
  lastSuccessfulAt?: string;
  lastError?: string;
};

export type MemorySourcePreview = {
  device: MemorySourceDeviceIdentity;
  fingerprint: string;
  fingerprints: MemorySourceFingerprints;
  changed: DiscoveredMemorySourceFile[];
  removed: MemorySourceSyncedFile[];
  unchanged: DiscoveredMemorySourceFile[];
  counts: Record<MemorySourceKind, number>;
};

export type DiscoverMemorySourcesOptions = {
  homeDir: string;
  codexRoot?: string;
  claudeRoot?: string;
  maxFileBytes?: number;
  maxFiles?: number;
};

// Keep this exact decimal-byte limit aligned with the Workspace Worker. The
// filesystem stat size is bytes, so multibyte Markdown is bounded correctly.
const defaultMaxFileBytes = 900_000;
const defaultMaxFiles = 2_000;
const sensitiveFileSegment = /^(?:auth|authorization|config|configuration|credential|credentials|secret|secrets|session|sessions|conversation|conversations|task|tasks|raw|rollout|rollouts|skill|skills)(?:[._-]|$)/i;

function sha256(value: string | Buffer) {
  return createHash("sha256").update(value).digest("hex");
}

function compareText(left: string, right: string) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function normalizedMachineID(value: unknown) {
  const machineID = String(value ?? "").trim().toLowerCase();
  if (!machineID) throw new Error("A stable machine ID is required.");
  if (machineID.length > 160 || /[^a-z0-9._:-]/.test(machineID)) {
    throw new Error("The stable machine ID contains unsupported characters.");
  }
  return machineID;
}

function normalizedMachineName(value: unknown) {
  const name = String(value ?? "").replace(/\s+/g, " ").trim().slice(0, 120);
  return name || "This Mac";
}

function isoTimestamp(value: unknown, fallback: string) {
  const date = new Date(String(value ?? ""));
  return Number.isFinite(date.getTime()) ? date.toISOString() : fallback;
}

export function updateMemorySourceDeviceIdentity(
  existing: MemorySourceDeviceIdentity | undefined,
  machineIDValue: unknown,
  machineNameValue: unknown,
  nowValue = new Date().toISOString()
): MemorySourceDeviceIdentity {
  const machineID = normalizedMachineID(machineIDValue);
  const currentName = normalizedMachineName(machineNameValue);
  const now = isoTimestamp(nowValue, new Date().toISOString());
  const sameDevice = existing?.machineID === machineID;
  const firstSeenAt = sameDevice ? isoTimestamp(existing.firstSeenAt, now) : now;
  const history = sameDevice
    ? (existing.nameHistory ?? []).map((entry) => ({
        name: normalizedMachineName(entry.name),
        firstSeenAt: isoTimestamp(entry.firstSeenAt, firstSeenAt),
        lastSeenAt: isoTimestamp(entry.lastSeenAt, now)
      }))
    : [];
  const matching = history.find((entry) => entry.name.toLocaleLowerCase() === currentName.toLocaleLowerCase());
  if (matching) {
    matching.lastSeenAt = now;
    matching.name = currentName;
  } else {
    history.push({ name: currentName, firstSeenAt: now, lastSeenAt: now });
  }
  history.sort((left, right) => compareText(left.firstSeenAt, right.firstSeenAt) || compareText(left.name, right.name));
  return {
    machineID,
    currentName,
    nameHistory: history,
    firstSeenAt,
    lastSeenAt: now
  };
}

function posixRelativePath(root: string, filePath: string) {
  return path.relative(root, filePath).split(path.sep).join("/");
}

function sourceFileKey(source: MemorySourceKind, relativePath: string) {
  return `${source}:${relativePath}`;
}

function pathIsInside(root: string, candidate: string) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative));
}

function fileHasSensitiveSegment(relativePath: string) {
  return relativePath.split("/").some((segment) => sensitiveFileSegment.test(segment));
}

function safeMarkdownFile(root: string, filePath: string, maxFileBytes: number): DiscoveredMemorySourceFile | null {
  try {
    const rootRealPath = fs.realpathSync(root);
    const stat = fs.lstatSync(filePath);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > maxFileBytes) return null;
    const realPath = fs.realpathSync(filePath);
    if (!pathIsInside(rootRealPath, realPath)) return null;
    const relativePath = posixRelativePath(rootRealPath, realPath);
    if (!relativePath || relativePath.startsWith("../") || path.isAbsolute(relativePath)) return null;
    if (!relativePath.toLowerCase().endsWith(".md") || fileHasSensitiveSegment(relativePath)) return null;
    const content = fs.readFileSync(realPath);
    if (content.includes(0)) return null;
    return {
      key: "",
      source: "codex",
      relativePath,
      absolutePath: realPath,
      size: stat.size,
      modifiedAt: stat.mtimeMs,
      contentHash: sha256(content)
    };
  } catch {
    return null;
  }
}

function walkMarkdownFiles(root: string, maxFiles: number) {
  const files: string[] = [];
  if (!fs.existsSync(root)) return files;
  const stack = [root];
  while (stack.length && files.length < maxFiles) {
    const directory = stack.pop();
    if (!directory) break;
    let entries: fs.Dirent[];
    try {
      if (fs.lstatSync(directory).isSymbolicLink()) continue;
      entries = fs.readdirSync(directory, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries.sort((left, right) => compareText(left.name, right.name))) {
      const entryPath = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) stack.push(entryPath);
      else if (entry.isFile() && entry.name.toLowerCase().endsWith(".md")) files.push(entryPath);
      if (files.length >= maxFiles) break;
    }
  }
  return files;
}

function collectCodexFiles(root: string, maxFiles: number) {
  const candidates = [
    path.join(root, "memory_summary.md"),
    path.join(root, "MEMORY.md")
  ];
  candidates.push(...walkMarkdownFiles(path.join(root, "extensions", "ad_hoc", "notes"), maxFiles));
  return [...new Set(candidates)].slice(0, maxFiles);
}

function collectClaudeFiles(root: string, maxFiles: number) {
  const projectsRoot = path.join(root, "projects");
  if (!fs.existsSync(projectsRoot)) return [];
  const files: string[] = [];
  let projects: fs.Dirent[] = [];
  try {
    projects = fs.readdirSync(projectsRoot, { withFileTypes: true });
  } catch {
    return [];
  }
  for (const project of projects.sort((left, right) => compareText(left.name, right.name))) {
    if (!project.isDirectory() || project.isSymbolicLink()) continue;
    const memoryRoot = path.join(projectsRoot, project.name, "memory");
    files.push(...walkMarkdownFiles(memoryRoot, maxFiles - files.length));
    if (files.length >= maxFiles) break;
  }
  return files;
}

function discoveredFile(source: MemorySourceKind, root: string, candidate: string, maxFileBytes: number) {
  const file = safeMarkdownFile(root, candidate, maxFileBytes);
  if (!file) return null;
  const result = { ...file, source };
  result.key = sourceFileKey(source, result.relativePath);
  return result;
}

export function memorySourceFingerprint(files: Array<Pick<DiscoveredMemorySourceFile, "source" | "relativePath" | "contentHash">>) {
  const rows = files
    .map((file) => `${file.source}\0${file.relativePath}\0${file.contentHash}`)
    .sort(compareText);
  return sha256(rows.join("\n"));
}

/**
 * One manifest hash per source. Each hash covers only that source's files, so
 * two sources with different files never report the same hash upstream.
 */
export function memorySourceFingerprints(
  files: Array<Pick<DiscoveredMemorySourceFile, "source" | "relativePath" | "contentHash">>
): MemorySourceFingerprints {
  return {
    codex: memorySourceFingerprint(files.filter((file) => file.source === "codex")),
    claude: memorySourceFingerprint(files.filter((file) => file.source === "claude"))
  };
}

export function discoverMemorySources(options: DiscoverMemorySourcesOptions): MemorySourceDiscovery {
  const homeDir = path.resolve(options.homeDir);
  const codexRoot = path.resolve(options.codexRoot ?? path.join(homeDir, ".codex", "memories"));
  const claudeRoot = path.resolve(options.claudeRoot ?? path.join(homeDir, ".claude"));
  const maxFileBytes = Math.max(1, Math.floor(options.maxFileBytes ?? defaultMaxFileBytes));
  const maxFiles = Math.max(1, Math.floor(options.maxFiles ?? defaultMaxFiles));
  const files = [
    ...collectCodexFiles(codexRoot, maxFiles)
      .map((candidate) => discoveredFile("codex", codexRoot, candidate, maxFileBytes)),
    ...collectClaudeFiles(claudeRoot, maxFiles)
      .map((candidate) => discoveredFile("claude", claudeRoot, candidate, maxFileBytes))
  ]
    .filter((file): file is DiscoveredMemorySourceFile => Boolean(file))
    .sort((left, right) => compareText(left.source, right.source) || compareText(left.relativePath, right.relativePath))
    .slice(0, maxFiles);
  return {
    files,
    fingerprint: memorySourceFingerprint(files),
    fingerprints: memorySourceFingerprints(files),
    counts: {
      codex: files.filter((file) => file.source === "codex").length,
      claude: files.filter((file) => file.source === "claude").length
    }
  };
}

export function emptyMemorySourceSyncState(device: MemorySourceDeviceIdentity): MemorySourceSyncState {
  return {
    schemaVersion: memorySourceSyncSchemaVersion,
    device,
    files: {},
    sources: {
      codex: { fileCount: 0 },
      claude: { fileCount: 0 }
    }
  };
}

export function buildMemorySourcePreview(
  state: MemorySourceSyncState,
  discovery: MemorySourceDiscovery,
  device: MemorySourceDeviceIdentity
): MemorySourcePreview {
  const currentKeys = new Set(discovery.files.map((file) => file.key));
  const changed: DiscoveredMemorySourceFile[] = [];
  const unchanged: DiscoveredMemorySourceFile[] = [];
  for (const file of discovery.files) {
    const previous = state.files[file.key];
    if (!previous || previous.localMissing || previous.contentHash !== file.contentHash) changed.push(file);
    else unchanged.push(file);
  }
  const removed = Object.entries(state.files)
    .filter(([key, file]) => !currentKeys.has(key) && !file.localMissing)
    .map(([, file]) => file)
    .sort((left, right) => compareText(left.source, right.source) || compareText(left.relativePath, right.relativePath));
  return {
    device,
    fingerprint: discovery.fingerprint,
    fingerprints: discovery.fingerprints,
    changed,
    removed,
    unchanged,
    counts: discovery.counts
  };
}

export function memorySourceUploadIdempotencyKey(
  machineID: string,
  file: Pick<DiscoveredMemorySourceFile, "source" | "relativePath" | "contentHash">
) {
  return sha256(`openassist-memory-source-v1\0${normalizedMachineID(machineID)}\0${file.source}\0${file.relativePath}\0${file.contentHash}`);
}

export function memorySourceDestinationPath(
  machineID: string,
  file: Pick<DiscoveredMemorySourceFile, "source" | "relativePath">
) {
  return ["OpenAssist", "Second Brain", "Memory Sources", normalizedMachineID(machineID), file.source, file.relativePath].join("/");
}
