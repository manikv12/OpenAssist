import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { MemorySourceSyncService } from "../dist-electron/memorySourceSyncService.js";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-memory-source-service-"));
process.on("exit", () => fs.rmSync(root, { recursive: true, force: true }));
const home = path.join(root, "home");
const codexRoot = path.join(home, ".codex", "memories");
const claudeRoot = path.join(home, ".claude");
const statePath = path.join(root, "private", "state.json");

function write(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content);
}

const summaryPath = path.join(codexRoot, "memory_summary.md");
const notePath = path.join(codexRoot, "extensions", "ad_hoc", "notes", "preference.md");
const claudePath = path.join(claudeRoot, "projects", "openassist", "memory", "decision.md");
write(summaryPath, "# Summary\nKeep answers direct.\n");
write(notePath, "# Preference\nUse gold, not yellow.\n");
write(claudePath, "# Decision\nMarkdown is the source of truth.\n");

let clock = Date.parse("2026-08-30T10:00:00.000Z");
const attempts = [];
let failPath = "extensions/ad_hoc/notes/preference.md";
const uploader = async (request) => {
  attempts.push(request);
  assert.equal(request.mimeType, "text/markdown");
  assert.match(request.destinationPath, /^OpenAssist\/Second Brain\/Memory Sources\/device-123\//);
  if (request.relativePath === failPath) throw new Error("temporary upload failure");
  return { remoteID: `remote:${request.source}:${request.relativePath}` };
};
const createService = (machineName = "Studio Mac") => new MemorySourceSyncService({
  statePath,
  machineID: "device-123",
  machineName,
  homeDir: home,
  codexRoot,
  claudeRoot,
  now: () => new Date(clock),
  upload: uploader
});

const firstService = createService();
const firstPreview = firstService.preview();
assert.equal(firstPreview.changed.length, 3);
assert.equal(firstPreview.unchanged.length, 0);
assert.equal(firstPreview.removed.length, 0);
const firstRun = await firstService.sync();
assert.equal(firstRun.ok, false);
assert.equal(firstRun.uploaded, 2);
assert.equal(firstRun.failed.length, 1);
assert.equal(firstRun.state.lastSuccessfulAt, undefined, "partial failure must not advance lastSuccessfulAt");
assert.equal(fs.statSync(statePath).mode & 0o777, 0o600, "state must be private");
const storedText = fs.readFileSync(statePath, "utf8");
assert.doesNotMatch(storedText, /Keep answers direct|Use gold, not yellow|Markdown is the source of truth/);
assert.doesNotMatch(storedText, /"content"\s*:/, "state must store metadata only");

const failedAttempt = attempts.find((attempt) => attempt.relativePath === failPath);
assert.ok(failedAttempt);
clock += 60_000;
failPath = "";
const retryStart = attempts.length;
const retryRun = await createService().sync();
const retryAttempts = attempts.slice(retryStart);
assert.equal(retryRun.ok, true);
assert.equal(retryRun.uploaded, 1, "retry must skip files already uploaded successfully");
assert.deepEqual(retryAttempts.map((attempt) => attempt.relativePath), ["extensions/ad_hoc/notes/preference.md"]);
assert.equal(retryAttempts[0].idempotencyKey, failedAttempt.idempotencyKey, "retry must reuse the same idempotency key");
assert.equal(retryRun.state.lastSuccessfulAt, new Date(clock).toISOString());

// Each source must persist its own manifest hash, never the combined one.
// Codex and Claude hold different files here, so their hashes must differ.
assert.notEqual(retryRun.state.sources.codex.fingerprint, retryRun.state.sources.claude.fingerprint,
  "two sources with different files must not persist the same manifest hash");
assert.equal(retryRun.state.sources.codex.fingerprint, retryRun.preview.fingerprints.codex);
assert.equal(retryRun.state.sources.claude.fingerprint, retryRun.preview.fingerprints.claude);
assert.notEqual(retryRun.state.sources.codex.fingerprint, retryRun.preview.fingerprint,
  "the combined fingerprint must not be persisted as a source manifest hash");
assert.notEqual(retryRun.state.sources.claude.fingerprint, retryRun.preview.fingerprint);
const persistedState = JSON.parse(fs.readFileSync(statePath, "utf8"));
assert.equal(persistedState.sources.codex.fingerprint, retryRun.preview.fingerprints.codex,
  "the per-source fingerprint must survive to disk");
assert.equal(persistedState.sources.claude.fingerprint, retryRun.preview.fingerprints.claude);

clock += 60_000;
const renamedRunStart = attempts.length;
const renamedRun = await createService("Office Mac").sync();
assert.equal(renamedRun.ok, true);
assert.equal(renamedRun.uploaded, 0);
assert.equal(attempts.length, renamedRunStart);
assert.deepEqual(renamedRun.state.device.nameHistory.map((entry) => entry.name), ["Studio Mac", "Office Mac"]);

write(summaryPath, "# Summary\nKeep answers very direct.\n");
fs.rmSync(claudePath);
const changePreview = createService("Office Mac").preview();
assert.deepEqual(changePreview.changed.map((file) => file.relativePath), ["memory_summary.md"]);
assert.deepEqual(changePreview.removed.map((file) => file.relativePath), ["projects/openassist/memory/decision.md"]);
assert.equal(changePreview.unchanged.length, 1);

clock += 60_000;
const finalStart = attempts.length;
const finalRun = await createService("Office Mac").sync();
assert.equal(finalRun.ok, true);
assert.equal(finalRun.uploaded, 1);
assert.equal(finalRun.removed, 1);
assert.equal(attempts.length, finalStart + 1, "removed files must never call the uploader or a remote delete path");
// Only the edited source's hash moves; the untouched source keeps its own.
assert.notEqual(finalRun.state.sources.codex.fingerprint, retryRun.state.sources.codex.fingerprint,
  "an edited source must report a new manifest hash");
assert.notEqual(finalRun.state.sources.codex.fingerprint, finalRun.state.sources.claude.fingerprint);
assert.equal(finalRun.state.sources.claude.fingerprint, finalRun.preview.fingerprints.claude);
const removedRecord = finalRun.state.files["claude:projects/openassist/memory/decision.md"];
assert.equal(removedRecord.localMissing, true);
assert.ok(removedRecord.removedAt);

clock += 60_000;
const settledPreview = createService("Office Mac").preview();
assert.equal(settledPreview.removed.length, 0, "an acknowledged local removal must not repeat on every sync");

const exactLimitMarkdown = "é".repeat(450_000);
const overLimitMarkdown = `${exactLimitMarkdown}a`;
const exactLimitPath = path.join(codexRoot, "extensions", "ad_hoc", "notes", "exact-limit.md");
const overLimitPath = path.join(codexRoot, "extensions", "ad_hoc", "notes", "over-limit.md");
write(exactLimitPath, exactLimitMarkdown);
write(overLimitPath, overLimitMarkdown);
assert.equal(fs.statSync(exactLimitPath).size, 900_000);
assert.equal(fs.statSync(overLimitPath).size, 900_001);
const boundaryPreview = createService("Office Mac").preview();
assert.deepEqual(boundaryPreview.changed.map((file) => file.relativePath), ["extensions/ad_hoc/notes/exact-limit.md"]);
clock += 60_000;
const boundaryStart = attempts.length;
const boundaryRun = await createService("Office Mac").sync(boundaryPreview.fingerprint);
assert.equal(boundaryRun.ok, true);
assert.equal(boundaryRun.uploaded, 1);
const boundaryAttempts = attempts.slice(boundaryStart);
assert.equal(boundaryAttempts.length, 1, "oversized Markdown must be excluded before the uploader is called");
assert.equal(boundaryAttempts[0].relativePath, "extensions/ad_hoc/notes/exact-limit.md");
assert.equal(Buffer.byteLength(boundaryAttempts[0].content, "utf8"), 900_000,
  "the accepted boundary is measured in UTF-8 bytes, not characters");

console.log("Memory source sync service verification passed.");
