import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

// Guards for the dictation stop→paste latency fixes (2026-07-02). The old
// pipeline serialized: transcript history write → fresh osascript frontmost
// query → re-activating the already-frontmost app (+180ms) → paste → 450ms
// clipboard-restore block, and every cloud upload paid a cold TLS handshake.

const main = fs.readFileSync(path.resolve("electron/main.ts"), "utf8");
const bridge = fs.readFileSync(path.resolve("electron/openassistBridge.ts"), "utf8");
const app = fs.readFileSync(path.resolve("src/App.tsx"), "utf8");
const inserter = fs.readFileSync(path.resolve("electron/helpers/text-inserter-helper.swift"), "utf8");

// Cloud connection prewarm exists and fires on dictation stop.
assert.match(
  bridge,
  /async function prewarmCloudTranscriptionConnection\(/,
  "Bridge must expose the cloud transcription connection prewarm."
);
const stopConfigured = main.slice(
  main.indexOf("async function stopConfiguredVoiceInput"),
  main.indexOf("function openAssistTargetPath")
);
assert.match(
  stopConfigured,
  /refreshFrontmostApplicationSnapshot\(\)/,
  "Dictation stop must capture the frontmost app in parallel with transcription."
);
assert.match(
  stopConfigured,
  /prewarmCloudTranscriptionConnection\(\)/,
  "Dictation stop must prewarm the cloud provider connection."
);

// Paste path reuses the recent snapshot and skips redundant re-activation.
const insert = main.slice(
  main.indexOf("async function insertTranscriptText"),
  main.indexOf("function openAssistRepoRoot")
);
assert.match(
  insert,
  /frontmostApplicationSnapshotWithMaxAge\(/,
  "insertTranscriptText must reuse a recent frontmost snapshot instead of a fresh osascript round-trip."
);
assert.match(
  insert,
  /target\.pid !== frontmost\?\.pid/,
  "insertTranscriptText must skip activation (and its 180ms delay) when the target is already frontmost."
);

// Clipboard restore no longer blocks for 450ms.
assert.match(
  inserter,
  /let clipboardRestoreDelay: useconds_t = 250_000/,
  "Clipboard restore delay must stay at 250ms — 450ms made every dictation feel slow."
);

// History save is off the paste critical path.
assert.doesNotMatch(
  app,
  /await window\.openAssistElectron\?\.addTranscriptHistory\?\.\(transcript\);/,
  "Saving transcript history must not be awaited before pasting."
);

console.log("Dictation latency guards verified.");
