import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const gitMaxBuffer = 64 * 1024 * 1024;

export type CodeCheckpointPhase = "before" | "after";
export type CodeCheckpointChangeKind = "added" | "modified" | "deleted" | "changed" | "typeChanged";

export type GitCheckpointRepositoryContext = {
  rootPath: string;
  label: string;
};

export type GitCheckpointPathState = {
  blobID: string | null;
  mode: string | null;
  objectType: string | null;
};

export type GitCheckpointSnapshot = {
  worktreeRef: string;
  worktreeCommit: string;
  worktreeTree: string;
  indexRef: string;
  indexCommit: string;
  indexTree: string;
  ignoredFingerprints: Record<string, never>;
};

export type CodeCheckpointFile = {
  path: string;
  changeKind: CodeCheckpointChangeKind;
  beforeWorktree: GitCheckpointPathState;
  afterWorktree: GitCheckpointPathState;
  beforeIndex: GitCheckpointPathState;
  afterIndex: GitCheckpointPathState;
  isBinary: boolean;
};

export type GitCheckpointCaptureResult = {
  patch: string;
  changedFiles: CodeCheckpointFile[];
  summary: string;
  ignoredTouchedPaths: string[];
};

export type GitStoredCheckpointRefState = {
  checkpointID: string;
  hasBeforeWorktreeRef: boolean;
  hasBeforeIndexRef: boolean;
  hasAfterWorktreeRef: boolean;
  hasAfterIndexRef: boolean;
};

type GitRunOptions = {
  env?: Record<string, string>;
  allowNonZeroExit?: boolean;
};

type GitRunResult = {
  stdout: string;
  stderr: string;
  exitCode: number;
};

const missingPathState: GitCheckpointPathState = {
  blobID: null,
  mode: null,
  objectType: null
};

function checkpointError(message: string) {
  return new Error(message || "Open Assist could not complete the Git checkpoint operation.");
}

function asNonEmpty(value: string) {
  const trimmed = value.trim();
  return trimmed.length ? trimmed : undefined;
}

function sanitizeRefPathComponent(value: string) {
  return value.trim().replace(/[^A-Za-z0-9._-]+/g, "-") || "session";
}

function refNames(sessionID: string, checkpointID: string, phase: CodeCheckpointPhase) {
  const safeSessionID = sanitizeRefPathComponent(sessionID);
  const safeCheckpointID = sanitizeRefPathComponent(checkpointID);
  const prefix = `refs/openassist/checkpoints/${safeSessionID}/${safeCheckpointID}/${phase}`;
  return {
    worktreeRef: `${prefix}-worktree`,
    indexRef: `${prefix}-index`
  };
}

function refPrefix(sessionID: string) {
  return `refs/openassist/checkpoints/${sanitizeRefPathComponent(sessionID)}`;
}

function changeKindFromStatus(status: string): CodeCheckpointChangeKind {
  const symbol = status.trim().charAt(0).toUpperCase();
  if (symbol === "A") return "added";
  if (symbol === "D") return "deleted";
  if (symbol === "T") return "typeChanged";
  if (symbol === "M") return "modified";
  return "changed";
}

function pathStateExists(state: GitCheckpointPathState) {
  return Boolean(state.blobID && state.mode);
}

async function runGit(cwd: string, args: string[], options: GitRunOptions = {}): Promise<GitRunResult> {
  try {
    const { stdout, stderr } = await execFileAsync("git", args, {
      cwd,
      env: { ...process.env, ...(options.env ?? {}) },
      maxBuffer: gitMaxBuffer
    });
    return { stdout, stderr, exitCode: 0 };
  } catch (error) {
    const gitError = error as Error & { stdout?: string; stderr?: string; code?: number | string };
    const stdout = typeof gitError.stdout === "string" ? gitError.stdout : "";
    const stderr = typeof gitError.stderr === "string" ? gitError.stderr : "";
    const exitCode = typeof gitError.code === "number" ? gitError.code : 1;
    if (options.allowNonZeroExit) {
      return { stdout, stderr, exitCode };
    }
    throw checkpointError(asNonEmpty(stderr) ?? asNonEmpty(stdout) ?? gitError.message);
  }
}

async function repositoryHasHead(repositoryRootPath: string) {
  const result = await runGit(repositoryRootPath, ["rev-parse", "--verify", "HEAD"], { allowNonZeroExit: true });
  return result.exitCode === 0;
}

async function createHiddenCommit(
  repositoryRootPath: string,
  treeID: string,
  refName: string,
  message: string,
  persistRef = true
) {
  const commitResult = await runGit(repositoryRootPath, ["commit-tree", treeID, "-m", message], {
    env: {
      GIT_AUTHOR_NAME: "Open Assist",
      GIT_AUTHOR_EMAIL: "openassist@local.invalid",
      GIT_COMMITTER_NAME: "Open Assist",
      GIT_COMMITTER_EMAIL: "openassist@local.invalid"
    }
  });
  const commitID = asNonEmpty(commitResult.stdout);
  if (!commitID) throw checkpointError("Open Assist could not create a hidden Git checkpoint commit.");
  if (persistRef) {
    await runGit(repositoryRootPath, ["update-ref", refName, commitID]);
  }
  return commitID;
}

async function captureWorktreeCommit(
  repositoryRootPath: string,
  refName: string,
  message: string,
  persistRef = true
) {
  const tempIndexPath = path.join(os.tmpdir(), `OpenAssist-Worktree-${randomUUID()}.index`);
  try {
    const env = { GIT_INDEX_FILE: tempIndexPath };
    if (await repositoryHasHead(repositoryRootPath)) {
      await runGit(repositoryRootPath, ["read-tree", "HEAD"], { env });
    } else {
      await runGit(repositoryRootPath, ["read-tree", "--empty"], { env });
    }
    await runGit(repositoryRootPath, ["add", "-A", "--", "."], { env });
    const treeWrite = await runGit(repositoryRootPath, ["write-tree"], { env });
    const treeID = asNonEmpty(treeWrite.stdout);
    if (!treeID) throw checkpointError("Open Assist could not create a saved Git tree for this turn.");
    const commitID = await createHiddenCommit(repositoryRootPath, treeID, refName, message, persistRef);
    return { commitID, treeID };
  } finally {
    fs.rmSync(tempIndexPath, { force: true });
  }
}

async function captureIndexCommit(
  repositoryRootPath: string,
  refName: string,
  message: string,
  persistRef = true
) {
  const treeWrite = await runGit(repositoryRootPath, ["write-tree"]);
  const treeID = asNonEmpty(treeWrite.stdout);
  if (!treeID) throw checkpointError("Open Assist could not capture the Git index state for this turn.");
  const commitID = await createHiddenCommit(repositoryRootPath, treeID, refName, message, persistRef);
  return { commitID, treeID };
}

async function changedPathStatuses(
  repositoryRootPath: string,
  beforeCommit: string,
  afterCommit: string
) {
  const result = await runGit(repositoryRootPath, [
    "diff",
    "--no-renames",
    "--name-status",
    "-z",
    beforeCommit,
    afterCommit,
    "--"
  ]);
  const chunks = result.stdout.split("\0").filter((chunk) => chunk.length > 0);
  const statuses: Array<{ path: string; kind: CodeCheckpointChangeKind }> = [];
  for (let index = 0; index + 1 < chunks.length; index += 2) {
    const status = chunks[index]?.trim() ?? "";
    const filePath = chunks[index + 1] ?? "";
    if (!filePath) continue;
    statuses.push({ path: filePath, kind: changeKindFromStatus(status) });
  }
  return statuses;
}

async function binaryPathSet(repositoryRootPath: string, beforeCommit: string, afterCommit: string) {
  const result = await runGit(repositoryRootPath, [
    "diff",
    "--no-renames",
    "--numstat",
    "-z",
    beforeCommit,
    afterCommit,
    "--"
  ]);
  const rows = result.stdout.split("\0").filter((row) => row.length > 0);
  const paths = new Set<string>();
  for (const row of rows) {
    const columns = row.split("\t");
    if (columns.length >= 3 && (columns[0] === "-" || columns[1] === "-")) {
      paths.add(columns[2] ?? "");
    }
  }
  paths.delete("");
  return paths;
}

async function diffPatch(repositoryRootPath: string, beforeCommit: string, afterCommit: string) {
  const result = await runGit(repositoryRootPath, [
    "diff",
    "--no-renames",
    "--binary",
    beforeCommit,
    afterCommit,
    "--"
  ]);
  return result.stdout;
}

async function treeEntry(repositoryRootPath: string, commit: string, filePath: string): Promise<GitCheckpointPathState> {
  const result = await runGit(repositoryRootPath, ["ls-tree", "-z", commit, "--", filePath], {
    allowNonZeroExit: true
  });
  if (result.exitCode !== 0) return missingPathState;
  const line = result.stdout.replace(/\0+$/g, "");
  const tabIndex = line.indexOf("\t");
  if (tabIndex < 0) return missingPathState;
  const metadata = line.slice(0, tabIndex).split(/\s+/);
  if (metadata.length < 3) return missingPathState;
  return {
    mode: metadata[0] ?? null,
    objectType: metadata[1] ?? null,
    blobID: metadata[2] ?? null
  };
}

function plainEnglishSummary(files: CodeCheckpointFile[]) {
  const added = files.filter((file) => file.changeKind === "added").length;
  const deleted = files.filter((file) => file.changeKind === "deleted").length;
  const modified = files.filter((file) =>
    file.changeKind === "modified" || file.changeKind === "changed" || file.changeKind === "typeChanged"
  ).length;
  const parts: string[] = [];
  if (added > 0) parts.push(`added ${added} file${added === 1 ? "" : "s"}`);
  if (modified > 0) parts.push(`updated ${modified} file${modified === 1 ? "" : "s"}`);
  if (deleted > 0) parts.push(`removed ${deleted} file${deleted === 1 ? "" : "s"}`);
  if (!parts.length) return "Saved a Git-backed code checkpoint.";
  if (parts.length === 1) return `Saved a checkpoint that ${parts[0]}.`;
  if (parts.length === 2) return `Saved a checkpoint that ${parts[0]} and ${parts[1]}.`;
  return `Saved a checkpoint that ${parts[0]}, ${parts[1]}, and ${parts[2]}.`;
}

async function restoreIndexState(repositoryRootPath: string, filePath: string, state: GitCheckpointPathState) {
  if (pathStateExists(state) && state.mode && state.blobID) {
    await runGit(repositoryRootPath, ["update-index", "--add", "--cacheinfo", state.mode, state.blobID, filePath]);
  } else {
    await runGit(repositoryRootPath, ["update-index", "--force-remove", "--", filePath], { allowNonZeroExit: true });
  }
}

async function seedTemporaryIndex(
  repositoryRootPath: string,
  temporaryIndexPath: string,
  filePath: string,
  state: GitCheckpointPathState
) {
  if (!pathStateExists(state) || !state.mode || !state.blobID) return;
  await runGit(repositoryRootPath, ["update-index", "--add", "--cacheinfo", state.mode, state.blobID, filePath], {
    env: { GIT_INDEX_FILE: temporaryIndexPath }
  });
}

function removeWorktreePath(repositoryRootPath: string, relativePath: string) {
  const absolutePath = path.join(repositoryRootPath, relativePath);
  if (!fs.existsSync(absolutePath)) return;
  fs.rmSync(absolutePath, { recursive: true, force: true });
  let currentDirectory = path.dirname(absolutePath);
  while (currentDirectory.startsWith(repositoryRootPath) && currentDirectory !== repositoryRootPath) {
    try {
      if (fs.readdirSync(currentDirectory).length > 0) break;
      fs.rmdirSync(currentDirectory);
      currentDirectory = path.dirname(currentDirectory);
    } catch {
      break;
    }
  }
}

function removeDirectoryIfNeeded(repositoryRootPath: string, relativePath: string) {
  const absolutePath = path.join(repositoryRootPath, relativePath);
  if (!fs.existsSync(absolutePath)) return;
  if (fs.statSync(absolutePath).isDirectory()) {
    fs.rmSync(absolutePath, { recursive: true, force: true });
  }
}

export class GitCheckpointService {
  async repositoryContext(forPath: string): Promise<GitCheckpointRepositoryContext | null> {
    const trimmedPath = forPath.trim();
    if (!trimmedPath) return null;
    const result = await runGit(trimmedPath, ["rev-parse", "--show-toplevel"], { allowNonZeroExit: true });
    const rootPath = asNonEmpty(result.stdout);
    if (result.exitCode !== 0 || !rootPath) return null;
    return {
      rootPath,
      label: path.basename(rootPath)
    };
  }

  async captureSnapshot(
    repository: GitCheckpointRepositoryContext,
    sessionID: string,
    checkpointID: string,
    phase: CodeCheckpointPhase
  ): Promise<GitCheckpointSnapshot> {
    const refs = refNames(sessionID, checkpointID, phase);
    const worktreeSnapshot = await captureWorktreeCommit(
      repository.rootPath,
      refs.worktreeRef,
      `Open Assist ${phase} worktree snapshot`
    );
    const indexSnapshot = await captureIndexCommit(
      repository.rootPath,
      refs.indexRef,
      `Open Assist ${phase} index snapshot`
    );
    return {
      worktreeRef: refs.worktreeRef,
      worktreeCommit: worktreeSnapshot.commitID,
      worktreeTree: worktreeSnapshot.treeID,
      indexRef: refs.indexRef,
      indexCommit: indexSnapshot.commitID,
      indexTree: indexSnapshot.treeID,
      ignoredFingerprints: {}
    };
  }

  async captureCurrentState(repository: GitCheckpointRepositoryContext) {
    const checkpointID = `state-${randomUUID()}`;
    const refs = refNames("transient", checkpointID, "after");
    const worktreeSnapshot = await captureWorktreeCommit(
      repository.rootPath,
      refs.worktreeRef,
      "Open Assist transient worktree state",
      false
    );
    const indexSnapshot = await captureIndexCommit(
      repository.rootPath,
      refs.indexRef,
      "Open Assist transient index state",
      false
    );
    return {
      worktreeTree: worktreeSnapshot.treeID,
      indexTree: indexSnapshot.treeID
    };
  }

  async loadSnapshot(
    repository: GitCheckpointRepositoryContext,
    sessionID: string,
    checkpointID: string,
    phase: CodeCheckpointPhase
  ): Promise<GitCheckpointSnapshot | null> {
    const refs = refNames(sessionID, checkpointID, phase);
    const worktreeCommitResult = await runGit(repository.rootPath, ["rev-parse", `${refs.worktreeRef}^{commit}`], {
      allowNonZeroExit: true
    });
    const indexCommitResult = await runGit(repository.rootPath, ["rev-parse", `${refs.indexRef}^{commit}`], {
      allowNonZeroExit: true
    });
    const worktreeCommit = asNonEmpty(worktreeCommitResult.stdout);
    const indexCommit = asNonEmpty(indexCommitResult.stdout);
    if (worktreeCommitResult.exitCode !== 0 || indexCommitResult.exitCode !== 0 || !worktreeCommit || !indexCommit) {
      return null;
    }
    const worktreeTree = asNonEmpty((await runGit(repository.rootPath, ["show", "-s", "--format=%T", worktreeCommit])).stdout);
    const indexTree = asNonEmpty((await runGit(repository.rootPath, ["show", "-s", "--format=%T", indexCommit])).stdout);
    if (!worktreeTree || !indexTree) return null;
    return {
      worktreeRef: refs.worktreeRef,
      worktreeCommit,
      worktreeTree,
      indexRef: refs.indexRef,
      indexCommit,
      indexTree,
      ignoredFingerprints: {}
    };
  }

  async buildCaptureResult(
    repository: GitCheckpointRepositoryContext,
    before: GitCheckpointSnapshot,
    after: GitCheckpointSnapshot
  ): Promise<GitCheckpointCaptureResult> {
    const changedStatuses = await changedPathStatuses(repository.rootPath, before.worktreeCommit, after.worktreeCommit);
    if (!changedStatuses.length) {
      return {
        patch: "",
        changedFiles: [],
        summary: "No Git-tracked code changes were saved in this turn.",
        ignoredTouchedPaths: []
      };
    }
    const binaryPaths = await binaryPathSet(repository.rootPath, before.worktreeCommit, after.worktreeCommit);
    const patch = await diffPatch(repository.rootPath, before.worktreeCommit, after.worktreeCommit);
    const files: CodeCheckpointFile[] = [];
    for (const status of changedStatuses) {
      files.push({
        path: status.path,
        changeKind: status.kind,
        beforeWorktree: await treeEntry(repository.rootPath, before.worktreeCommit, status.path),
        afterWorktree: await treeEntry(repository.rootPath, after.worktreeCommit, status.path),
        beforeIndex: await treeEntry(repository.rootPath, before.indexCommit, status.path),
        afterIndex: await treeEntry(repository.rootPath, after.indexCommit, status.path),
        isBinary: binaryPaths.has(status.path)
      });
    }
    return {
      patch,
      changedFiles: files,
      summary: plainEnglishSummary(files),
      ignoredTouchedPaths: []
    };
  }

  async storedCheckpointRefs(repository: GitCheckpointRepositoryContext, sessionID: string): Promise<GitStoredCheckpointRefState[]> {
    const result = await runGit(repository.rootPath, ["for-each-ref", "--format=%(refname)", refPrefix(sessionID)], {
      allowNonZeroExit: true
    });
    if (result.exitCode !== 0) return [];
    const byCheckpointID = new Map<string, GitStoredCheckpointRefState>();
    for (const ref of result.stdout.split(/\r?\n/).map((line) => line.trim()).filter(Boolean)) {
      const match = ref.match(/\/([^/]+)\/(before|after)-(worktree|index)$/);
      if (!match) continue;
      const checkpointID = match[1] ?? "";
      const phase = match[2] ?? "";
      const scope = match[3] ?? "";
      if (!checkpointID) continue;
      const current = byCheckpointID.get(checkpointID) ?? {
        checkpointID,
        hasBeforeWorktreeRef: false,
        hasBeforeIndexRef: false,
        hasAfterWorktreeRef: false,
        hasAfterIndexRef: false
      };
      if (phase === "before" && scope === "worktree") current.hasBeforeWorktreeRef = true;
      if (phase === "before" && scope === "index") current.hasBeforeIndexRef = true;
      if (phase === "after" && scope === "worktree") current.hasAfterWorktreeRef = true;
      if (phase === "after" && scope === "index") current.hasAfterIndexRef = true;
      byCheckpointID.set(checkpointID, current);
    }
    return [...byCheckpointID.values()].sort((left, right) => left.checkpointID.localeCompare(right.checkpointID));
  }

  async deleteRefs(repositoryRootPath: string, refs: string[]) {
    for (const ref of refs) {
      await runGit(repositoryRootPath, ["update-ref", "-d", ref], { allowNonZeroExit: true });
    }
  }

  async restoreGuard(repository: GitCheckpointRepositoryContext, expectedWorktreeTree: string, expectedIndexTree: string) {
    const current = await this.captureCurrentState(repository);
    if (current.worktreeTree !== expectedWorktreeTree || current.indexTree !== expectedIndexTree) {
      return {
        isAllowed: false,
        message: "Open Assist can’t undo right now because the repository changed after the last saved checkpoint."
      };
    }
    return { isAllowed: true, message: null };
  }

  async restore(repository: GitCheckpointRepositoryContext, files: CodeCheckpointFile[], target: CodeCheckpointPhase) {
    if (!files.length) return;
    const tempIndexPath = path.join(os.tmpdir(), `OpenAssist-Restore-${randomUUID()}.index`);
    try {
      await runGit(repository.rootPath, ["read-tree", "--empty"], { env: { GIT_INDEX_FILE: tempIndexPath } });
      for (const file of files) {
        const targetIndexState = target === "before" ? file.beforeIndex : file.afterIndex;
        await restoreIndexState(repository.rootPath, file.path, targetIndexState);
        const targetWorktreeState = target === "before" ? file.beforeWorktree : file.afterWorktree;
        if (pathStateExists(targetWorktreeState)) {
          await seedTemporaryIndex(repository.rootPath, tempIndexPath, file.path, targetWorktreeState);
          removeDirectoryIfNeeded(repository.rootPath, file.path);
        } else {
          removeWorktreePath(repository.rootPath, file.path);
        }
      }
      await runGit(repository.rootPath, ["checkout-index", "--all", "--force"], {
        env: { GIT_INDEX_FILE: tempIndexPath }
      });
    } finally {
      fs.rmSync(tempIndexPath, { force: true });
    }
  }
}
