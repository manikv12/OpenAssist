import { createHash, randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export const peerFileFetchMaxBytes = 25 * 1024 * 1024;
export const peerFileSearchMaxResults = 100;
export const peerFileSearchDefaultResults = 25;
export const peerFileSearchMaxScanned = 50_000;
export const peerFileSearchMaxDepth = 12;
export const peerFileSearchMaxQueryLength = 256;

export type PeerFileSearchResult = {
  relativePath: string;
  size: number;
  mtimeMs: number;
};

export type PeerFileFetchResult = PeerFileSearchResult & {
  sha256: string;
  contentBase64: string;
};

export type PeerFileErrorCode =
  | "invalid_path"
  | "invalid_query"
  | "excluded"
  | "not_found"
  | "not_file"
  | "too_large"
  | "unsafe_symlink";

export class PeerFileError extends Error {
  readonly code: PeerFileErrorCode;

  constructor(code: PeerFileErrorCode, message: string) {
    super(message);
    this.name = "PeerFileError";
    this.code = code;
  }
}

const blockedSegments = new Set([".git", "node_modules", ".ds_store"]);
const blockedExtensions = new Set([".pem", ".key", ".p12", ".pfx", ".jks", ".ppk", ".keystore", ".kdbx"]);
const privateKeyNamePattern = /^id_(?:rsa|ed25519|ecdsa|dsa)(?:\..*)?$/i;

export function peerFileSafeRelativePath(value: unknown) {
  const raw = String(value ?? "").trim().replace(/\\/g, "/");
  if (!raw || raw.length > 2_048 || raw.includes("\0") || raw.startsWith("/") || /^[a-z]:\//i.test(raw)) return "";
  if (raw.split("/").includes("..")) return "";
  const normalized = path.posix.normalize(raw).replace(/^\.\//, "");
  if (!normalized || normalized === "." || normalized === ".." || normalized.startsWith("../")) return "";
  return normalized;
}

export function peerFileExcluded(relativePath: string) {
  const safePath = peerFileSafeRelativePath(relativePath);
  if (!safePath) return false;
  const segments = safePath.split("/").map((segment) => segment.toLowerCase());
  if (segments.some((segment) => blockedSegments.has(segment) || segment.startsWith(".env"))) return true;
  const basename = segments.at(-1) ?? "";
  return privateKeyNamePattern.test(basename) || blockedExtensions.has(path.posix.extname(basename));
}

export function peerFileMatchScore(relativePath: string, query: string) {
  const normalizedQuery = query.trim().toLowerCase();
  if (!normalizedQuery) return 0;
  const normalizedPath = relativePath.toLowerCase();
  const basename = path.posix.basename(normalizedPath);
  if (basename === normalizedQuery) return 100;
  if (normalizedPath === normalizedQuery) return 95;
  if (basename.startsWith(normalizedQuery)) return 80;
  if (basename.includes(normalizedQuery)) return 60;
  if (normalizedPath.includes(normalizedQuery)) return 40;
  const tokens = normalizedQuery.split(/\s+/).filter(Boolean);
  return tokens.length && tokens.every((token) => normalizedPath.includes(token)) ? 30 : 0;
}

function canonicalPeerRoot(root: string) {
  let resolved: string;
  try {
    resolved = fs.realpathSync(root);
  } catch {
    throw new PeerFileError("not_found", "The linked project folder is missing on this Mac.");
  }
  let stat: fs.Stats;
  try {
    stat = fs.statSync(resolved);
  } catch {
    throw new PeerFileError("not_found", "The linked project folder is missing on this Mac.");
  }
  if (!stat.isDirectory()) throw new PeerFileError("not_found", "The linked project folder is not a folder.");
  return resolved;
}

function pathInsideRoot(root: string, candidate: string) {
  const relative = path.relative(root, candidate);
  return Boolean(relative) && relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function checkedRelativePath(rawRelativePath: unknown) {
  const relativePath = peerFileSafeRelativePath(rawRelativePath);
  if (!relativePath) throw new PeerFileError("invalid_path", "Invalid relative path.");
  if (peerFileExcluded(relativePath)) {
    throw new PeerFileError("excluded", "This file is excluded from peer sharing by the sensitive file rule.");
  }
  return relativePath;
}

function inspectPathUnderRoot(root: string, relativePath: string, requireFile: boolean) {
  const rootPath = canonicalPeerRoot(root);
  const targetPath = path.resolve(rootPath, ...relativePath.split("/"));
  if (!pathInsideRoot(rootPath, targetPath)) throw new PeerFileError("invalid_path", "Invalid relative path.");

  const segments = relativePath.split("/");
  let currentPath = rootPath;
  let existingTarget = false;
  for (let index = 0; index < segments.length; index += 1) {
    currentPath = path.join(currentPath, segments[index]);
    let stat: fs.Stats;
    try {
      stat = fs.lstatSync(currentPath);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        if (requireFile) throw new PeerFileError("not_found", "The requested peer file was not found.");
        break;
      }
      throw error;
    }
    if (stat.isSymbolicLink()) {
      throw new PeerFileError("unsafe_symlink", "Peer file paths cannot use symbolic links.");
    }
    const isTarget = index === segments.length - 1;
    if (!isTarget && !stat.isDirectory()) {
      throw new PeerFileError("not_file", "A parent path for this file is not a folder.");
    }
    if (isTarget) {
      existingTarget = true;
      if (!stat.isFile()) throw new PeerFileError("not_file", "The requested peer path is not a regular file.");
    }
  }

  if (existingTarget || requireFile) {
    let realTarget: string;
    try {
      realTarget = fs.realpathSync(targetPath);
    } catch {
      throw new PeerFileError("not_found", "The requested peer file was not found.");
    }
    if (!pathInsideRoot(rootPath, realTarget)) {
      throw new PeerFileError("unsafe_symlink", "The requested peer file resolves outside the linked project folder.");
    }
  } else {
    let ancestorPath = path.dirname(targetPath);
    while (!fs.existsSync(ancestorPath) && pathInsideRoot(rootPath, ancestorPath)) {
      ancestorPath = path.dirname(ancestorPath);
    }
    const realAncestor = fs.realpathSync(ancestorPath);
    if (realAncestor !== rootPath && !pathInsideRoot(rootPath, realAncestor)) {
      throw new PeerFileError("unsafe_symlink", "The requested peer path resolves outside the linked project folder.");
    }
  }

  return { rootPath, targetPath, existingTarget };
}

export function walkPeerProjectFiles(root: string) {
  const rootPath = canonicalPeerRoot(root);
  const files: PeerFileSearchResult[] = [];
  const stack: Array<{ directoryPath: string; relativePath: string; depth: number }> = [
    { directoryPath: rootPath, relativePath: "", depth: 0 }
  ];
  let scanned = 0;
  let truncated = false;

  while (stack.length && scanned < peerFileSearchMaxScanned) {
    const current = stack.pop();
    if (!current) break;
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(current.directoryPath, { withFileTypes: true })
        .sort((left, right) => left.name.localeCompare(right.name));
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (scanned >= peerFileSearchMaxScanned) {
        truncated = true;
        break;
      }
      scanned += 1;
      const relativePath = current.relativePath ? `${current.relativePath}/${entry.name}` : entry.name;
      if (!peerFileSafeRelativePath(relativePath) || peerFileExcluded(relativePath) || entry.isSymbolicLink()) continue;
      const entryPath = path.join(current.directoryPath, entry.name);
      let stat: fs.Stats;
      try {
        stat = fs.lstatSync(entryPath);
      } catch {
        continue;
      }
      if (stat.isSymbolicLink()) continue;
      if (stat.isDirectory()) {
        if (current.depth >= peerFileSearchMaxDepth) {
          truncated = true;
        } else {
          stack.push({ directoryPath: entryPath, relativePath, depth: current.depth + 1 });
        }
        continue;
      }
      if (stat.isFile()) files.push({ relativePath, size: stat.size, mtimeMs: stat.mtimeMs });
    }
  }
  if (stack.length) truncated = true;
  return { files, truncated, scanned };
}

export function searchPeerProjectFiles(root: string, query: string, maxResults = peerFileSearchDefaultResults) {
  const normalizedQuery = String(query ?? "").trim();
  if (!normalizedQuery) throw new PeerFileError("invalid_query", "Enter a file name or search text.");
  if (normalizedQuery.length > peerFileSearchMaxQueryLength) {
    throw new PeerFileError("invalid_query", `Search text must be ${peerFileSearchMaxQueryLength} characters or fewer.`);
  }
  const limit = Math.max(1, Math.min(peerFileSearchMaxResults, Math.floor(Number(maxResults) || peerFileSearchDefaultResults)));
  const walked = walkPeerProjectFiles(root);
  const results = walked.files
    .map((file) => ({ file, score: peerFileMatchScore(file.relativePath, normalizedQuery) }))
    .filter((entry) => entry.score > 0)
    .sort((left, right) => right.score - left.score
      || left.file.relativePath.length - right.file.relativePath.length
      || left.file.relativePath.localeCompare(right.file.relativePath))
    .slice(0, limit)
    .map((entry) => entry.file);
  return { results, truncated: walked.truncated };
}

export function sha256OfBuffer(buffer: Buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

export function sha256OfFile(filePath: string) {
  const hash = createHash("sha256");
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  const descriptor = fs.openSync(filePath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    if (!fs.fstatSync(descriptor).isFile()) throw new Error("The file is not a regular file.");
    while (true) {
      const bytesRead = fs.readSync(descriptor, buffer, 0, buffer.length, null);
      if (!bytesRead) break;
      hash.update(buffer.subarray(0, bytesRead));
    }
  } finally {
    fs.closeSync(descriptor);
  }
  return hash.digest("hex");
}

export function decodePeerFilePayload(file: Record<string, unknown>, expectedRelativePath: string) {
  const relativePath = peerFileSafeRelativePath(file.relativePath);
  if (!relativePath || relativePath !== expectedRelativePath || peerFileExcluded(relativePath)) {
    throw new Error("The peer returned an invalid or unexpected relative path.");
  }
  const size = Number(file.size ?? -1);
  const sha256 = String(file.sha256 ?? "").trim().toLowerCase();
  const contentBase64 = typeof file.contentBase64 === "string" ? file.contentBase64 : "";
  const maxBase64Bytes = Math.ceil(peerFileFetchMaxBytes * 4 / 3) + 4;
  if (!Number.isInteger(size) || size < 0 || size > peerFileFetchMaxBytes || !/^[a-f0-9]{64}$/.test(sha256)) {
    throw new Error("The peer returned invalid file metadata.");
  }
  if (contentBase64.length > maxBase64Bytes
      || (contentBase64 && !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(contentBase64))) {
    throw new Error("The peer returned invalid file content.");
  }
  const buffer = Buffer.from(contentBase64, "base64");
  if (buffer.length !== size || buffer.toString("base64") !== contentBase64 || sha256OfBuffer(buffer) !== sha256) {
    throw new Error("The peer file failed its size or integrity check.");
  }
  return { relativePath, size, sha256, buffer };
}

export function readPeerProjectFile(root: string, rawRelativePath: unknown): PeerFileFetchResult {
  const relativePath = checkedRelativePath(rawRelativePath);
  const { targetPath } = inspectPathUnderRoot(root, relativePath, true);
  let descriptor: number;
  try {
    descriptor = fs.openSync(targetPath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ELOOP") {
      throw new PeerFileError("unsafe_symlink", "Peer file paths cannot use symbolic links.");
    }
    throw error;
  }
  try {
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) throw new PeerFileError("not_file", "The requested peer path is not a regular file.");
    if (stat.size > peerFileFetchMaxBytes) {
      throw new PeerFileError("too_large", `Peer files must be ${peerFileFetchMaxBytes} bytes or smaller.`);
    }
    const buffer = fs.readFileSync(descriptor);
    if (buffer.length > peerFileFetchMaxBytes) {
      throw new PeerFileError("too_large", `Peer files must be ${peerFileFetchMaxBytes} bytes or smaller.`);
    }
    return {
      relativePath,
      size: buffer.length,
      mtimeMs: stat.mtimeMs,
      sha256: sha256OfBuffer(buffer),
      contentBase64: buffer.toString("base64")
    };
  } finally {
    fs.closeSync(descriptor);
  }
}

export function classifyPeerFetchTarget(root: string, rawRelativePath: unknown) {
  const relativePath = checkedRelativePath(rawRelativePath);
  const inspected = inspectPathUnderRoot(root, relativePath, false);
  return { relativePath, targetPath: inspected.targetPath, overwrites: inspected.existingTarget };
}

export function applyStagedPeerFile(stagedPath: string, expectedSha256: string, root: string, rawRelativePath: unknown) {
  let stagedDescriptor: number;
  try {
    stagedDescriptor = fs.openSync(stagedPath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ELOOP") {
      throw new PeerFileError("not_file", "The fetched copy is not a regular staged file. Fetch it again.");
    }
    throw new PeerFileError("not_found", "The fetched copy is no longer staged. Fetch the file again.");
  }
  let buffer: Buffer;
  try {
    const stagedStat = fs.fstatSync(stagedDescriptor);
    if (!stagedStat.isFile()) {
      throw new PeerFileError("not_file", "The fetched copy is not a regular staged file. Fetch it again.");
    }
    if (stagedStat.size > peerFileFetchMaxBytes) {
      throw new PeerFileError("too_large", `Peer files must be ${peerFileFetchMaxBytes} bytes or smaller.`);
    }
    buffer = fs.readFileSync(stagedDescriptor);
  } finally {
    fs.closeSync(stagedDescriptor);
  }
  if (sha256OfBuffer(buffer) !== String(expectedSha256 ?? "").trim().toLowerCase()) {
    throw new Error("The staged peer file changed after download. Fetch the file again.");
  }

  let target = classifyPeerFetchTarget(root, rawRelativePath);
  fs.mkdirSync(path.dirname(target.targetPath), { recursive: true, mode: 0o700 });
  target = classifyPeerFetchTarget(root, rawRelativePath);
  const temporaryPath = path.join(
    path.dirname(target.targetPath),
    `.${path.basename(target.targetPath)}.openassist-${randomUUID()}.tmp`
  );
  let descriptor: number | undefined;
  try {
    descriptor = fs.openSync(temporaryPath, "wx", 0o600);
    fs.writeFileSync(descriptor, buffer);
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(temporaryPath, target.targetPath);
  } catch (error) {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    fs.rmSync(temporaryPath, { force: true });
    throw error;
  }
  return { relativePath: target.relativePath, targetPath: target.targetPath, overwrote: target.overwrites, size: buffer.length };
}
