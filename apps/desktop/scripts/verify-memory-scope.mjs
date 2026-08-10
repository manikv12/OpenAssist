import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const core = await import(pathToFileURL(path.join(root, "dist-electron", "memoryDreamCore.js")).href);
const {
  automaticMemoryQueryAllowed,
  memoryRecallTokens,
  parseMemorySessionDigest,
  rankScopedMemoryCatalog,
  redactMemorySecrets,
  resolveThreadMemoryPolicy,
  scopedMemoryFileSlug
} = core;

const now = Date.now();
const entry = (id, scope, owner, name, content, automaticRecallEligible = true) => ({
  id,
  name,
  description: `${name} details`,
  content,
  scope,
  projectID: scope === "project" ? owner : scope === "thread" ? "project-a" : undefined,
  originThreadID: scope === "thread" ? owner : undefined,
  automaticRecallEligible,
  updatedAt: now
});

const catalog = [
  entry("thread-a", "thread", "thread-a", "Launch decision", "OpenAssist launch architecture uses a voice shelf."),
  entry("thread-b", "thread", "thread-b", "Private detail", "OpenAssist launch architecture has a private chat detail."),
  entry("project-a", "project", "project-a", "OpenAssist architecture", "OpenAssist launch architecture keeps the Voice Log separate."),
  entry("project-b", "project", "project-b", "Other project architecture", "OpenAssist launch architecture belongs to another project."),
  entry("global", "global", undefined, "Short answers", "The user prefers short direct answers for OpenAssist architecture questions."),
  {
    id: "ambiguous-legacy",
    name: "Legacy detail",
    description: "Ambiguous old memory",
    content: "OpenAssist launch architecture legacy detail",
    automaticRecallEligible: false,
    updatedAt: now
  }
];

const ids = (results) => results.map((result) => result.id);

// Same chat receives its own chat memory plus project and global facts.
assert.deepEqual(
  ids(rankScopedMemoryCatalog(catalog, "OpenAssist launch architecture", {
    threadID: "thread-a",
    projectID: "project-a"
  })),
  ["thread-a", "project-a", "global"]
);

// Another chat in the same project receives project and global facts, never a
// private detail from either chat.
assert.deepEqual(
  ids(rankScopedMemoryCatalog(catalog, "OpenAssist launch architecture", {
    threadID: "thread-c",
    projectID: "project-a"
  })),
  ["project-a", "global"]
);

// Another project receives only global facts automatically.
assert.deepEqual(
  ids(rankScopedMemoryCatalog(catalog, "OpenAssist launch architecture", {
    threadID: "thread-z",
    projectID: "project-z"
  })),
  ["global"]
);

// Explicit historical recall may search every scope, including ambiguous
// legacy memory that is unsafe for automatic injection.
assert.deepEqual(
  new Set(ids(rankScopedMemoryCatalog(catalog, "OpenAssist launch architecture", {
    threadID: "thread-z",
    projectID: "project-z",
    explicitRecall: true
  }, 10))),
  new Set(["thread-a", "thread-b", "project-a", "project-b", "global", "ambiguous-legacy"])
);

// Common words and short tokens cannot wake memory by themselves.
assert.deepEqual(memoryRecallTokens("Can you please tell me what was there?"), []);
assert.deepEqual(rankScopedMemoryCatalog(catalog, "Can you please tell me what was there?", {
  threadID: "thread-a",
  projectID: "project-a"
}), []);

// Older digests with a Thread line remain usable only in that thread without
// rewriting the file. A digest with no origin is explicit-recall-only.
const legacyDigest = parseMemorySessionDigest([
  "# Launch discussion",
  "Thread: thread-a",
  "Date: 2026-07-20",
  "",
  "- OpenAssist launch architecture decision"
].join("\n"));
assert.equal(legacyDigest?.scope, "thread");
assert.equal(legacyDigest?.threadID, "thread-a");
assert.equal(legacyDigest?.automaticRecallEligible, true);
const ambiguousDigest = parseMemorySessionDigest("# Old memory\n\n- No origin metadata");
assert.equal(ambiguousDigest?.scope, undefined);
assert.equal(ambiguousDigest?.automaticRecallEligible, false);

// Global filenames stay compatible. Project and thread memories get stable,
// collision-safe owner suffixes.
assert.equal(scopedMemoryFileSlug("short-answers", "global"), "short-answers");
assert.notEqual(
  scopedMemoryFileSlug("architecture", "project", "project-a"),
  scopedMemoryFileSlug("architecture", "project", "project-b")
);
assert.notEqual(
  scopedMemoryFileSlug("decision", "thread", undefined, "thread-a"),
  scopedMemoryFileSlug("decision", "thread", undefined, "thread-b")
);

// Credentials are removed before extraction or disk writes.
const secretText = [
  "api_key=supersecretvalue123",
  "Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456",
  "-----BEGIN PRIVATE KEY-----\nprivate-material\n-----END PRIVATE KEY-----"
].join("\n");
const redacted = redactMemorySecrets(secretText);
assert.doesNotMatch(redacted, /supersecretvalue123|abcdefghijklmnopqrstuvwxyz123456|private-material/);
assert.match(redacted, /REDACTED/);

// Missing per-chat values default on. Side chats, temporary chats, and explicit
// user controls enforce the expected privacy boundaries.
const enabledSettings = {
  memoryEnabled: true,
  memoryDreamingEnabled: true,
  knowledgeAccessEnabled: true
};
assert.deepEqual(resolveThreadMemoryPolicy(enabledSettings), {
  useMemory: true,
  learnFromChat: true,
  canUseMemory: true,
  canLearnFromChat: true
});
assert.equal(resolveThreadMemoryPolicy({ ...enabledSettings, memoryUseEnabled: false }).useMemory, false);
assert.equal(resolveThreadMemoryPolicy({ ...enabledSettings, memoryLearnEnabled: false }).learnFromChat, false);
assert.equal(resolveThreadMemoryPolicy({ ...enabledSettings, sessionKind: "sideChat" }).learnFromChat, false);
assert.equal(resolveThreadMemoryPolicy({ ...enabledSettings, isTemporary: true }).useMemory, false);
assert.equal(resolveThreadMemoryPolicy({ ...enabledSettings, knowledgeAccessEnabled: false }).learnFromChat, false);

assert.equal(automaticMemoryQueryAllowed("How should I organize my week?"), true);
assert.equal(automaticMemoryQueryAllowed("Check the logs and fix the worker"), false);
assert.equal(automaticMemoryQueryAllowed("Use the browser to find the release"), false);
assert.equal(automaticMemoryQueryAllowed("What did we fix in the logs yesterday?"), true);

// Cached local ranking remains comfortably inside the existing soft budget and
// has no model or network dependency.
const largeCatalog = Array.from({ length: 5_000 }, (_, index) => ({
  id: `large-${index}`,
  name: `OpenAssist architecture ${index}`,
  description: "OpenAssist launch architecture",
  content: `Local memory record ${index} for OpenAssist launch architecture decisions.`,
  scope: "project",
  projectID: "project-a",
  automaticRecallEligible: true,
  updatedAt: now - index
}));
const startedAt = performance.now();
const benchmarkResults = rankScopedMemoryCatalog(largeCatalog, "OpenAssist launch architecture", {
  threadID: "thread-a",
  projectID: "project-a"
});
const elapsedMs = performance.now() - startedAt;
assert.equal(benchmarkResults.length, 3);
assert.ok(elapsedMs < 250, `5,000-record lookup took ${elapsedMs.toFixed(1)} ms`);

// Integration wiring: per-chat IPC, selected Live Voice scope, finalized-pair
// learning, and direct planner/delegated work exclusions.
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");
const bridge = read("electron/openassistBridge.ts");
const main = read("electron/main.ts");
const app = read("src/App.tsx");
assert.match(main, /openassist:set-thread-memory-policy/);
assert.match(main, /openassist:flush-thread-memory/);
assert.match(app, /Use memory in this chat/);
assert.match(app, /Learn from this chat/);
assert.match(bridge, /rankScopedMemoryCatalog\(\s*memoryCatalogEntries\(\)/s);
assert.match(bridge, /threadID:\s*selectedRecallThreadID/);
assert.match(bridge, /projectID:\s*selectedRecallProjectID/);
assert.match(bridge, /targetThreadID:\s*selectedRecallThreadID/);
assert.match(bridge, /memoryLearning:\s*\{\s*enabled:\s*false\s*\}/s);

console.log(`verify-memory-scope passed (${elapsedMs.toFixed(1)} ms for 5,000 records).`);
