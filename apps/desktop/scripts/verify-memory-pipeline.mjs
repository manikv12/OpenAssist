import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const desktopRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const core = await import(pathToFileURL(path.join(desktopRoot, "dist-electron", "memoryDreamCore.js")).href);
const {
  appendMemorySessionDigest,
  atomicWriteMemoryFile,
  buildRelevanceInjectionBlock,
  cancelMemoryLearningJob,
  claimMemoryLearningJob,
  completeMemoryLearningJob,
  failMemoryLearningJob,
  formatRawMemoryFile,
  listMemorySessionDigestArtifacts,
  memoryDreamLimits,
  memoryLearningSourceRef,
  normalizeMemoryDreamState,
  parseRawMemoryFile,
  parseStage1Response,
  recoverMemoryLearningJobs,
  retryMemoryLearningJob,
  shouldScheduleMemoryDream,
  threadMemoryPipelineStatus,
  upsertMemoryLearningJob
} = core;

const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-memory-pipeline-"));
const memoryRoot = path.join(temporaryRoot, "Memory");
const sessionsRoot = path.join(memoryRoot, "sessions");
const statePath = path.join(memoryRoot, "dream-state.json");
const now = new Date("2026-07-22T15:30:00.000Z");

const writeState = (state) => atomicWriteMemoryFile(
  statePath,
  `${JSON.stringify(normalizeMemoryDreamState(state), null, 2)}\n`
);
const readState = () => normalizeMemoryDreamState(JSON.parse(fs.readFileSync(statePath, "utf8")));

try {
  // Completed turn -> exact digest artifact -> durable queued job.
  const artifact = appendMemorySessionDigest({
    sessionsRoot,
    dayID: "2026-07-22",
    threadID: "restaurant-launch-thread",
    projectID: "openassist",
    title: "Restaurant launch",
    backend: "codex",
    prompt: "Remember the polished Hollywood-style launch direction for the restaurant.",
    responseText: "Use a restrained neon reveal, a short voiceover, and a clean final logo frame.",
    occurredAt: now
  });
  assert.equal(fs.existsSync(artifact.path), true);
  assert.match(path.basename(artifact.path), /restaurant-launch-thread/);
  const source = memoryLearningSourceRef(artifact, memoryRoot);
  let state = upsertMemoryLearningJob(normalizeMemoryDreamState({}), {
    threadID: artifact.threadID,
    projectID: artifact.projectID,
    sourceFiles: [source],
    now: now.getTime(),
    notBefore: now.getTime()
  });
  writeState(state);
  assert.equal(readState().version, 2);
  assert.equal(readState().jobs[artifact.threadID].sourceFiles[0].path, source.path);
  assert.doesNotMatch(JSON.stringify(readState()), /Hollywood-style|voiceover|logo frame/i);

  // Claim survives a state round trip and uses a lease.
  const claimed = claimMemoryLearningJob(readState(), artifact.threadID, now.getTime(), 5_000);
  assert.equal(claimed.job?.status, "running");
  assert.equal(claimed.job?.leaseUntil, now.getTime() + 5_000);
  writeState(claimed.state);

  // Mock Stage 1 extraction writes the existing Markdown raw-memory format.
  const extraction = parseStage1Response(JSON.stringify({
    hasMemory: true,
    summary: "Restaurant launch creative direction",
    rawMemory: "- Use a polished neon reveal and concise voiceover for the restaurant launch."
  }));
  assert.ok(extraction?.hasMemory);
  const rawPath = path.join(memoryRoot, "raw", "restaurant-launch-thread.md");
  atomicWriteMemoryFile(rawPath, formatRawMemoryFile({
    threadID: artifact.threadID,
    projectID: artifact.projectID,
    scope: "thread",
    title: "Restaurant launch",
    updatedAtISO: now.toISOString(),
    summary: extraction.summary,
    rawMemory: extraction.rawMemory
  }));
  assert.equal(parseRawMemoryFile(fs.readFileSync(rawPath, "utf8"))?.threadID, artifact.threadID);
  state = completeMemoryLearningJob(readState(), artifact.threadID, {
    completedAt: now.getTime() + 1_000,
    producedMemory: true
  });
  writeState(state);
  const readyStatus = threadMemoryPipelineStatus({
    artifacts: [artifact],
    job: state.jobs[artifact.threadID],
    learnedSummaryUpdatedAt: now.getTime()
  });
  assert.equal(readyStatus.conversationHistory.available, true);
  assert.equal(readyStatus.conversationHistory.turnCount, 1);
  assert.equal(readyStatus.learnedSummary.state, "ready");

  // Two IDs with the same suffix no longer collide.
  const collisionA = appendMemorySessionDigest({
    sessionsRoot,
    dayID: "2026-07-22",
    threadID: "first-12345678",
    title: "First",
    backend: "codex",
    prompt: "Store a sufficiently long first collision test request.",
    responseText: "This is a sufficiently long first collision test response.",
    occurredAt: now
  });
  const collisionB = appendMemorySessionDigest({
    sessionsRoot,
    dayID: "2026-07-22",
    threadID: "second-12345678",
    title: "Second",
    backend: "codex",
    prompt: "Store a sufficiently long second collision test request.",
    responseText: "This is a sufficiently long second collision test response.",
    occurredAt: now
  });
  assert.notEqual(collisionA.path, collisionB.path);

  // An existing legacy digest remains canonical; it is never guessed later.
  const legacyThreadID = "legacy-thread-ABCDEFGH";
  const legacyPath = path.join(sessionsRoot, `2026-07-22-${legacyThreadID.slice(-8)}.md`);
  atomicWriteMemoryFile(legacyPath, [
    "# Legacy chat",
    "",
    `Thread: ${legacyThreadID}`,
    "Scope: thread",
    "Date: 2026-07-22",
    "Provider: codex",
    "",
    "- 09:00 · user: prior turn -> assistant: prior answer",
    ""
  ].join("\n"));
  const legacyArtifact = appendMemorySessionDigest({
    sessionsRoot,
    dayID: "2026-07-22",
    threadID: legacyThreadID,
    title: "Legacy chat",
    backend: "codex",
    prompt: "Append to the exact legacy memory digest path.",
    responseText: "The legacy digest remains the canonical source artifact.",
    occurredAt: now
  });
  assert.equal(legacyArtifact.path, legacyPath);
  assert.equal(legacyArtifact.turnCount, 2);

  // Midnight rollover preserves both exact source paths in one coalesced job.
  const nextDayArtifact = appendMemorySessionDigest({
    sessionsRoot,
    dayID: "2026-07-23",
    threadID: artifact.threadID,
    projectID: artifact.projectID,
    title: "Restaurant launch",
    backend: "codex",
    prompt: "Keep the final reveal under eight seconds for tomorrow's revision.",
    responseText: "The new constraint is stored with the next day's exact digest artifact.",
    occurredAt: new Date("2026-07-23T00:05:00.000Z")
  });
  state = upsertMemoryLearningJob(state, {
    threadID: artifact.threadID,
    projectID: artifact.projectID,
    sourceFiles: [memoryLearningSourceRef(nextDayArtifact, memoryRoot)],
    now: now.getTime() + 5_000,
    notBefore: now.getTime() + 65_000
  });
  assert.equal(state.jobs[artifact.threadID].sourceFiles.length, 2);
  assert.deepEqual(
    state.jobs[artifact.threadID].sourceFiles.map((entry) => entry.path),
    [source.path, memoryLearningSourceRef(nextDayArtifact, memoryRoot).path]
  );
  assert.equal(state.jobs[artifact.threadID].status, "queued");

  // Re-queuing an unchanged successfully learned source is a no-op.
  let duplicate = upsertMemoryLearningJob(normalizeMemoryDreamState({}), {
    threadID: "duplicate-thread",
    sourceFiles: [source],
    now: 1,
    notBefore: 1
  });
  duplicate = completeMemoryLearningJob(duplicate, "duplicate-thread", { completedAt: 2, producedMemory: true });
  duplicate = upsertMemoryLearningJob(duplicate, {
    threadID: "duplicate-thread",
    sourceFiles: [source],
    now: 3,
    notBefore: 3
  });
  assert.equal(duplicate.jobs["duplicate-thread"].status, "completed");

  // Restart recovery reclaims expired leases and due retries.
  let recovery = upsertMemoryLearningJob(normalizeMemoryDreamState({}), {
    threadID: "restart-thread",
    sourceFiles: [source],
    now: 10,
    notBefore: 10
  });
  recovery = claimMemoryLearningJob(recovery, "restart-thread", 10, 20).state;
  assert.equal(recoverMemoryLearningJobs(recovery, 29).jobs["restart-thread"].status, "running");
  assert.equal(recoverMemoryLearningJobs(recovery, 30).jobs["restart-thread"].status, "queued");
  recovery = claimMemoryLearningJob(recoverMemoryLearningJobs(recovery, 30), "restart-thread", 30, 20).state;
  assert.equal(recoverMemoryLearningJobs(recovery, 31, { recoverAllRunning: true }).jobs["restart-thread"].status, "queued");

  // Transient failures retry after 1, 5, and 30 minutes, then become blocked.
  let retryState = upsertMemoryLearningJob(normalizeMemoryDreamState({}), {
    threadID: "retry-thread",
    sourceFiles: [source],
    now: 1_000,
    notBefore: 1_000
  });
  retryState = failMemoryLearningJob(retryState, "retry-thread", { errorCode: "network_unavailable", transient: true, failedAt: 1_000 });
  assert.equal(retryState.jobs["retry-thread"].retryAt, 1_000 + memoryDreamLimits.learningRetryDelaysMs[0]);
  retryState = failMemoryLearningJob(retryState, "retry-thread", { errorCode: "rate_limited", transient: true, failedAt: 2_000 });
  assert.equal(retryState.jobs["retry-thread"].retryAt, 2_000 + memoryDreamLimits.learningRetryDelaysMs[1]);
  retryState = failMemoryLearningJob(retryState, "retry-thread", { errorCode: "service_unavailable", transient: true, failedAt: 3_000 });
  assert.equal(retryState.jobs["retry-thread"].retryAt, 3_000 + memoryDreamLimits.learningRetryDelaysMs[2]);
  retryState = failMemoryLearningJob(retryState, "retry-thread", { errorCode: "network_unavailable", transient: true, failedAt: 4_000 });
  assert.equal(retryState.jobs["retry-thread"].status, "blocked");
  assert.equal(threadMemoryPipelineStatus({ artifacts: [artifact], job: retryState.jobs["retry-thread"] }).learnedSummary.state, "error");
  retryState = retryMemoryLearningJob(retryState, "retry-thread", 5_000);
  assert.equal(retryState.jobs["retry-thread"].status, "queued");
  assert.equal(retryState.jobs["retry-thread"].retryCount, 0);

  // Authentication/model failures block immediately and can be retried after settings change.
  let blocked = upsertMemoryLearningJob(normalizeMemoryDreamState({}), {
    threadID: "blocked-thread",
    sourceFiles: [source],
    now: 1,
    notBefore: 1
  });
  blocked = failMemoryLearningJob(blocked, "blocked-thread", {
    errorCode: "authentication_required",
    transient: false,
    failedAt: 2
  });
  assert.equal(blocked.jobs["blocked-thread"].status, "blocked");
  blocked = recoverMemoryLearningJobs(blocked, 3, { includeBlocked: true });
  assert.equal(blocked.jobs["blocked-thread"].status, "queued");

  // Disabling learning cancels pending work without deleting completed files.
  const cancelled = cancelMemoryLearningJob(state, artifact.threadID, now.getTime() + 10_000);
  assert.equal(cancelled.jobs[artifact.threadID].status, "cancelled");
  assert.equal(fs.existsSync(rawPath), true);
  const reenabled = upsertMemoryLearningJob(cancelled, {
    threadID: artifact.threadID,
    sourceFiles: [memoryLearningSourceRef(nextDayArtifact, memoryRoot)],
    now: now.getTime() + 11_000,
    notBefore: now.getTime() + 11_000
  });
  assert.equal(reenabled.jobs[artifact.threadID].status, "queued");

  // Only finalized eligible text turns can schedule learning.
  const eligibleTurn = {
    settings: { memoryEnabled: true, memoryDreamingEnabled: true, knowledgeAccessEnabled: true },
    prompt: "Please keep this finalized Live Voice project decision for later.",
    responseText: "This completed response contains enough useful context to qualify for durable learning. ".repeat(3),
    finalized: true
  };
  assert.equal(shouldScheduleMemoryDream(eligibleTurn), true);
  assert.equal(shouldScheduleMemoryDream({ ...eligibleTurn, interrupted: true }), false);
  assert.equal(shouldScheduleMemoryDream({ ...eligibleTurn, partial: true }), false);
  assert.equal(shouldScheduleMemoryDream({ ...eligibleTurn, finalized: false }), false);
  assert.equal(shouldScheduleMemoryDream({ ...eligibleTurn, settings: { ...eligibleTurn.settings, memoryDreamingEnabled: false } }), false);

  // Citations retain their real source type for UI activity labels.
  const citations = buildRelevanceInjectionBlock([
    { id: "session:chat.md", name: "Restaurant chat", snippet: "Launch direction", sourceType: "chatHistory" },
    { id: "learned:restaurant.md", name: "Restaurant summary", snippet: "Neon reveal", sourceType: "learnedSummary" },
    { id: "memory:project.md", name: "Launch project", snippet: "Opening soon", sourceType: "projectMemory" }
  ]);
  assert.deepEqual(citations?.sources.map((entry) => entry.type), ["chatHistory", "learnedSummary", "projectMemory"]);

  // Startup scans can discover the original and rollover artifacts by thread.
  const discovered = listMemorySessionDigestArtifacts(sessionsRoot, artifact.threadID);
  assert.equal(discovered.length, 2);
  assert.deepEqual(discovered.map((entry) => entry.path), [artifact.path, nextDayArtifact.path]);

  // Integration guards: exact artifacts are queued, startup repairs the ledger,
  // Live Voice uses finalized pairs, and permanent deletion removes thread-owned files.
  const bridge = fs.readFileSync(path.join(desktopRoot, "electron", "openassistBridge.ts"), "utf8");
  const main = fs.readFileSync(path.join(desktopRoot, "electron", "main.ts"), "utf8");
  assert.match(bridge, /const artifact = appendSessionDigest\([\s\S]*?queueMemoryDream\(learningThreadID, artifact\)/);
  assert.match(bridge, /function repairMemoryLearningJobsFromDigests/);
  assert.match(bridge, /recoverMemoryDreamPipelineOnStartup\(\)/);
  assert.match(bridge, /userSource: "realtimeVoice"/);
  assert.match(bridge, /listMemorySessionDigestArtifacts\(memorySessionsRoot\(\), threadID\)/);
  assert.match(bridge, /memory\.scope !== "thread"/);
  assert.doesNotMatch(bridge, /memoryDreamSessionDigestPath/);
  assert.match(main, /openassist:retry-thread-memory/);
} finally {
  fs.rmSync(temporaryRoot, { recursive: true, force: true });
}

console.log("verify-memory-pipeline passed.");
