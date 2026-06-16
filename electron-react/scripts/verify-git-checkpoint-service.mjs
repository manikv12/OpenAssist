import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function git(cwd, args) {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"]
  }).trim();
}

function write(filePath, contents) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, contents, "utf8");
}

const serviceModuleURL = pathToFileURL(path.join(process.cwd(), "dist-electron", "gitCheckpointService.js")).href;
const { GitCheckpointService } = await import(serviceModuleURL);

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-git-checkpoints-"));
try {
  const repoPath = path.join(tempRoot, "repo");
  fs.mkdirSync(repoPath, { recursive: true });
  git(repoPath, ["init"]);
  git(repoPath, ["config", "user.name", "OpenAssist Verify"]);
  git(repoPath, ["config", "user.email", "openassist-verify@example.local"]);
  write(path.join(repoPath, "tracked.txt"), "one\n");
  fs.mkdirSync(path.join(repoPath, "nested"), { recursive: true });
  git(repoPath, ["add", "."]);
  git(repoPath, ["commit", "-m", "initial"]);

  const service = new GitCheckpointService();
  const repository = await service.repositoryContext(path.join(repoPath, "nested"));
  assert(
    repository && fs.realpathSync(repository.rootPath) === fs.realpathSync(repoPath),
    "detects repo root from a working directory inside the repo"
  );

  const before = await service.captureSnapshot(repository, "thread-verify", "checkpoint-one", "before");
  write(path.join(repoPath, "tracked.txt"), "one\ntwo\n");
  write(path.join(repoPath, "added.txt"), "new file\n");
  git(repoPath, ["add", "added.txt"]);
  const after = await service.captureSnapshot(repository, "thread-verify", "checkpoint-one", "after");
  const capture = await service.buildCaptureResult(repository, before, after);
  assert(capture.changedFiles.length === 2, "captures changed-file summary");
  assert(capture.patch.includes("two"), "creates unified patch content");
  assert(capture.summary.length > 0, `creates readable summary: ${capture.summary}`);
  assert(capture.changedFiles.some((file) => file.path === "tracked.txt"), "includes modified tracked file");
  assert(capture.changedFiles.some((file) => file.path === "added.txt" && file.changeKind === "added"), "includes added file");

  const emptyBefore = await service.captureSnapshot(repository, "thread-verify", "checkpoint-empty", "before");
  const emptyAfter = await service.captureSnapshot(repository, "thread-verify", "checkpoint-empty", "after");
  const emptyCapture = await service.buildCaptureResult(repository, emptyBefore, emptyAfter);
  assert(emptyCapture.changedFiles.length === 0, "ignores empty diffs");

  write(path.join(repoPath, "drift.txt"), "outside change\n");
  const blocked = await service.restoreGuard(repository, after.worktreeTree, after.indexTree);
  assert(blocked.isAllowed === false, "blocks restore when repo drift is detected");
  fs.unlinkSync(path.join(repoPath, "drift.txt"));

  const allowed = await service.restoreGuard(repository, after.worktreeTree, after.indexTree);
  assert(allowed.isAllowed === true, "allows restore when repo still matches checkpoint");
  await service.restore(repository, capture.changedFiles, "before");
  assert(fs.readFileSync(path.join(repoPath, "tracked.txt"), "utf8") === "one\n", "restores modified file");
  assert(!fs.existsSync(path.join(repoPath, "added.txt")), "removes file added by checkpoint");

  console.log("Git checkpoint service verifier passed.");
} finally {
  fs.rmSync(tempRoot, { recursive: true, force: true });
}
