import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { executeStorageCleanup, previewStorageCleanup } from "../dist-electron/storageCleanup.js";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-storage-cleanup-"));
const supportRoot = path.join(root, "support");
const logRoot = path.join(root, "logs");
const nowMs = Date.parse("2026-07-25T12:00:00.000Z");
const oldMs = nowMs - 40 * 24 * 60 * 60 * 1000;
const recentMs = nowMs - 2 * 24 * 60 * 60 * 1000;

function writeFile(filePath, content, modifiedAtMs) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content);
  const date = new Date(modifiedAtMs);
  fs.utimesSync(filePath, date, date);
}

function makeDirectory(directory, modifiedAtMs) {
  fs.mkdirSync(directory, { recursive: true });
  writeFile(path.join(directory, "payload.bin"), "backup", modifiedAtMs);
  const date = new Date(modifiedAtMs);
  fs.utimesSync(directory, date, date);
}

try {
  const generatedRoot = path.join(supportRoot, "Knowledge", "Generated Images");
  const jobsRoot = path.join(supportRoot, "Knowledge", "Image Jobs");
  const generatedVideoRoot = path.join(supportRoot, "Knowledge", "Generated Videos");
  const videoJobsRoot = path.join(supportRoot, "Knowledge", "Short Video Jobs");
  const oldImage = path.join(generatedRoot, "old.png");
  const recentImage = path.join(generatedRoot, "recent.png");
  writeFile(oldImage, "old-image", oldMs);
  writeFile(recentImage, "recent-image", recentMs);

  const completedJob = path.join(jobsRoot, "completed.json");
  const runningJob = path.join(jobsRoot, "running.json");
  writeFile(completedJob, JSON.stringify({ status: "completed" }), oldMs);
  writeFile(runningJob, JSON.stringify({ status: "running" }), oldMs);

  const oldVideo = path.join(generatedVideoRoot, "old.mp4");
  const recentVideo = path.join(generatedVideoRoot, "recent.mp4");
  const oldKeyframes = path.join(generatedVideoRoot, "Keyframes", "mcp-video-old");
  writeFile(oldVideo, "old-video", oldMs);
  writeFile(recentVideo, "recent-video", recentMs);
  makeDirectory(oldKeyframes, oldMs);
  const completedVideoJob = path.join(videoJobsRoot, "completed.json");
  const runningVideoJob = path.join(videoJobsRoot, "running.json");
  writeFile(completedVideoJob, JSON.stringify({ status: "completed" }), oldMs);
  writeFile(runningVideoJob, JSON.stringify({ status: "running" }), oldMs);

  const oldLog = path.join(logRoot, "old.log");
  writeFile(oldLog, "old-log", oldMs);
  writeFile(path.join(logRoot, "recent.log"), "recent-log", recentMs);

  const backupRoot = path.join(supportRoot, "BuildBackups");
  const backupPaths = [1, 2, 3, 4].map((ageIndex) => {
    const directory = path.join(backupRoot, `backup-${ageIndex}`);
    makeDirectory(directory, nowMs - (40 + ageIndex) * 24 * 60 * 60 * 1000);
    return directory;
  });

  const protectedNote = path.join(supportRoot, "AssistantProjects", "project", "note.md");
  writeFile(protectedNote, "keep me", oldMs);

  const preview = await previewStorageCleanup({ supportRoot, logRoot, retentionDays: 30, nowMs });
  assert.equal(preview.itemCount, 9, "preview should include old generated media, finished jobs, one log, and three old backups");
  assert.equal(preview.categories.find((entry) => entry.category === "generatedImages")?.itemCount, 1);
  assert.equal(preview.categories.find((entry) => entry.category === "imageJobs")?.itemCount, 1);
  assert.equal(preview.categories.find((entry) => entry.category === "generatedVideos")?.itemCount, 2);
  assert.equal(preview.categories.find((entry) => entry.category === "videoJobs")?.itemCount, 1);
  assert.equal(preview.categories.find((entry) => entry.category === "logs")?.itemCount, 1);
  assert.equal(preview.categories.find((entry) => entry.category === "backups")?.itemCount, 3);
  await assert.rejects(
    executeStorageCleanup({ supportRoot, logRoot, retentionDays: 30, nowMs }),
    /requires explicit approval/
  );
  assert.equal(fs.existsSync(oldImage), true, "an unapproved cleanup must not remove files");

  const result = await executeStorageCleanup({ supportRoot, logRoot, retentionDays: 30, nowMs, approved: true });
  assert.equal(result.deletedItemCount, 9);
  assert.equal(result.errors.length, 0);
  assert.equal(fs.existsSync(oldImage), false);
  assert.equal(fs.existsSync(completedJob), false);
  assert.equal(fs.existsSync(oldLog), false);
  assert.equal(fs.existsSync(oldVideo), false);
  assert.equal(fs.existsSync(oldKeyframes), false);
  assert.equal(fs.existsSync(completedVideoJob), false);
  assert.equal(fs.existsSync(backupPaths[1]), false);
  assert.equal(fs.existsSync(backupPaths[2]), false);
  assert.equal(fs.existsSync(backupPaths[3]), false);
  assert.equal(fs.existsSync(recentImage), true);
  assert.equal(fs.existsSync(recentVideo), true);
  assert.equal(fs.existsSync(runningJob), true);
  assert.equal(fs.existsSync(runningVideoJob), true);
  assert.equal(fs.existsSync(backupPaths[0]), true);
  assert.equal(fs.existsSync(protectedNote), true);

  console.log("Storage cleanup verification passed.");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
