import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  discoverMemorySources,
  memorySourceDestinationPath,
  memorySourceFingerprint,
  memorySourceFingerprints,
  memorySourceUploadIdempotencyKey,
  updateMemorySourceDeviceIdentity
} from "../dist-electron/memorySourceSyncCore.js";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-memory-source-core-"));
process.on("exit", () => fs.rmSync(root, { recursive: true, force: true }));
const home = path.join(root, "home");
const codexRoot = path.join(home, ".codex", "memories");
const claudeRoot = path.join(home, ".claude");

function write(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content);
}

write(path.join(codexRoot, "memory_summary.md"), "# Current summary\n");
write(path.join(codexRoot, "MEMORY.md"), "# Memory index\n");
write(path.join(codexRoot, "extensions", "ad_hoc", "notes", "preference.md"), "# Preference\nShort answers.\n");
const exactLimitMarkdown = "é".repeat(450_000);
const overLimitMarkdown = `${exactLimitMarkdown}a`;
const exactLimitPath = path.join(codexRoot, "extensions", "ad_hoc", "notes", "exact-limit.md");
const overLimitPath = path.join(codexRoot, "extensions", "ad_hoc", "notes", "over-limit.md");
write(exactLimitPath, exactLimitMarkdown);
write(overLimitPath, overLimitMarkdown);
assert.equal(fs.statSync(exactLimitPath).size, 900_000);
assert.equal(fs.statSync(overLimitPath).size, 900_001);
write(path.join(codexRoot, "extensions", "ad_hoc", "notes", "auth-token.md"), "secret-not-for-sync\n");
write(path.join(codexRoot, "raw", "chat-summary.md"), "conversation-not-for-sync\n");
write(path.join(codexRoot, "rollout_summaries", "turn.md"), "rollout-not-for-sync\n");
write(path.join(codexRoot, "skills", "tool", "SKILL.md"), "skill-not-for-sync\n");
write(path.join(codexRoot, "sessions", "2026", "session.jsonl"), "conversation-not-for-sync\n");
write(path.join(claudeRoot, "projects", "project-a", "memory", "MEMORY.md"), "# Claude project A\n");
write(path.join(claudeRoot, "projects", "project-a", "memory", "decision.md"), "# Decision\nUse SQLite.\n");
write(path.join(claudeRoot, "projects", "project-a", "memory", "credentials.md"), "secret-not-for-sync\n");
write(path.join(claudeRoot, "projects", "project-a", "memory", "tasks.md"), "tasks-not-for-sync\n");
write(path.join(claudeRoot, "projects", "project-a", "memory", "raw", "capture.md"), "raw-not-for-sync\n");
write(path.join(claudeRoot, "projects", "project-a", "memory", "rollouts", "run.md"), "rollout-not-for-sync\n");
write(path.join(claudeRoot, "projects", "project-a", "memory", "skills", "tool.md"), "skill-not-for-sync\n");
write(path.join(claudeRoot, "projects", "project-a", "session.jsonl"), "conversation-not-for-sync\n");
write(path.join(claudeRoot, "tasks", "task.json"), "{}\n");
write(path.join(claudeRoot, "CLAUDE.md"), "config-not-for-sync\n");

const outside = path.join(root, "outside.md");
write(outside, "symlink-secret-not-for-sync\n");
try {
  fs.symlinkSync(outside, path.join(codexRoot, "extensions", "ad_hoc", "notes", "linked.md"));
  fs.symlinkSync(path.dirname(outside), path.join(claudeRoot, "projects", "project-a", "memory", "linked-folder"));
} catch {
  // Some test filesystems do not permit symlinks. The path checks still run
  // in production and the remaining assertions cover the fixed allowlist.
}

const discovery = discoverMemorySources({ homeDir: home, codexRoot, claudeRoot });
assert.deepEqual(discovery.files.map((file) => `${file.source}:${file.relativePath}`), [
  "claude:projects/project-a/memory/MEMORY.md",
  "claude:projects/project-a/memory/decision.md",
  "codex:MEMORY.md",
  "codex:extensions/ad_hoc/notes/exact-limit.md",
  "codex:extensions/ad_hoc/notes/preference.md",
  "codex:memory_summary.md"
]);
assert.deepEqual(discovery.counts, { codex: 4, claude: 2 });
assert.equal(discovery.files.some((file) => file.relativePath.endsWith("over-limit.md")), false,
  "900,001-byte Markdown must be excluded before upload");
assert.equal(memorySourceFingerprint([...discovery.files].reverse()), discovery.fingerprint);

// Each source must report its own manifest hash. A shared combined hash made
// every source look identical on the server.
const codexFiles = discovery.files.filter((file) => file.source === "codex");
const claudeFiles = discovery.files.filter((file) => file.source === "claude");
assert.equal(discovery.fingerprints.codex, memorySourceFingerprint(codexFiles));
assert.equal(discovery.fingerprints.claude, memorySourceFingerprint(claudeFiles));
assert.notEqual(discovery.fingerprints.codex, discovery.fingerprints.claude,
  "two sources with different files must not share a manifest hash");
assert.notEqual(discovery.fingerprints.codex, discovery.fingerprint,
  "a per-source hash must not equal the combined fingerprint");
assert.notEqual(discovery.fingerprints.claude, discovery.fingerprint);
assert.deepEqual(memorySourceFingerprints([...discovery.files].reverse()), discovery.fingerprints,
  "per-source hashes must be order independent");

// A change in one source must move only that source's hash.
write(path.join(claudeRoot, "projects", "project-a", "memory", "decision.md"), "# Decision\nUse Postgres.\n");
const afterClaudeEdit = discoverMemorySources({ homeDir: home, codexRoot, claudeRoot });
assert.equal(afterClaudeEdit.fingerprints.codex, discovery.fingerprints.codex,
  "an unrelated source must keep its manifest hash");
assert.notEqual(afterClaudeEdit.fingerprints.claude, discovery.fingerprints.claude);
assert.notEqual(afterClaudeEdit.fingerprint, discovery.fingerprint,
  "the combined fingerprint still guards preview-to-sync approval");
write(path.join(claudeRoot, "projects", "project-a", "memory", "decision.md"), "# Decision\nUse SQLite.\n");

// An empty source still gets a stable hash of its own.
const emptyClaude = discoverMemorySources({
  homeDir: home,
  codexRoot,
  claudeRoot: path.join(root, "no-such-claude-root")
});
assert.equal(emptyClaude.counts.claude, 0);
assert.equal(emptyClaude.fingerprints.codex, discovery.fingerprints.codex);
assert.equal(emptyClaude.fingerprints.claude, memorySourceFingerprint([]));
assert.notEqual(emptyClaude.fingerprints.claude, emptyClaude.fingerprints.codex);
assert.doesNotMatch(JSON.stringify(discovery.files), /secret-not-for-sync|conversation-not-for-sync|tasks-not-for-sync|raw-not-for-sync|rollout-not-for-sync|skill-not-for-sync/);

const firstIdentity = updateMemorySourceDeviceIdentity(undefined, "DEVICE-123", "Studio Mac", "2026-08-30T10:00:00.000Z");
const renamedIdentity = updateMemorySourceDeviceIdentity(firstIdentity, "device-123", "Office Mac", "2026-08-31T10:00:00.000Z");
assert.equal(renamedIdentity.machineID, "device-123");
assert.equal(renamedIdentity.currentName, "Office Mac");
assert.deepEqual(renamedIdentity.nameHistory.map((entry) => entry.name), ["Studio Mac", "Office Mac"]);
assert.equal(renamedIdentity.firstSeenAt, firstIdentity.firstSeenAt);
const otherIdentity = updateMemorySourceDeviceIdentity(undefined, "device-456", "Office Mac", "2026-08-31T10:00:00.000Z");
assert.notEqual(otherIdentity.machineID, renamedIdentity.machineID, "same-name Macs must remain separate");

const sample = discovery.files[0];
assert.equal(
  memorySourceUploadIdempotencyKey("device-123", sample),
  memorySourceUploadIdempotencyKey("DEVICE-123", sample),
  "retry keys must be deterministic"
);
assert.equal(
  memorySourceDestinationPath("device-123", sample),
  `OpenAssist/Second Brain/Memory Sources/device-123/${sample.source}/${sample.relativePath}`
);

console.log("Memory source sync core verification passed.");
