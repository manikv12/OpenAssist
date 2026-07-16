import fs from "node:fs";
import path from "node:path";

export type ConversationHistoryObject = Record<string, unknown>;

export type ConversationHistorySnapshot = {
  version?: number;
  threadID?: string;
  timeline?: ConversationHistoryObject[];
  transcript?: ConversationHistoryObject[];
  turns?: ConversationHistoryObject[];
  updatedAt?: number;
  lastAppliedEventSequence?: number;
};

export type RealtimeWorkHistoryItem = {
  taskID: string;
  workerProvider: string;
  state: "completed" | "failed" | "cancelled";
  prompt: string;
  resultPreview: string;
  progressEntries?: Array<{
    id: string;
    text: string;
    createdAt: number;
  }>;
  startedAt: number;
  finishedAt: number;
};

type ConversationHistoryManifest = {
  version: 1;
  segments: Array<{
    file: string;
    turnCount: number;
    firstMessageID?: string;
    lastMessageID?: string;
    createdAt: number;
  }>;
};

const SEGMENT_PATTERN = /^conversation-segment-(\d+)\.json$/;

export function atomicWriteJSON(filePath: string, value: unknown) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const temporaryPath = `${filePath}.tmp-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  fs.writeFileSync(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  fs.renameSync(temporaryPath, filePath);
}

function readJSON<T>(filePath: string): T | null {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8")) as T;
  } catch {
    return null;
  }
}

export function conversationHistorySegmentFiles(directory: string) {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory)
    .flatMap((file) => {
      const match = file.match(SEGMENT_PATTERN);
      return match ? [{ file, sequence: Number(match[1]) }] : [];
    })
    .sort((left, right) => left.sequence - right.sequence);
}

export function readConversationHistorySegments(directory: string) {
  return conversationHistorySegmentFiles(directory)
    .flatMap(({ file }) => {
      const snapshot = readJSON<ConversationHistorySnapshot>(path.join(directory, file));
      return snapshot ? [snapshot] : [];
    });
}

function objectID(item: ConversationHistoryObject, fallback: string) {
  return String(item.id ?? item.providerTurnID ?? item.openAssistTurnID ?? fallback);
}

export function mergeConversationHistorySnapshots(snapshots: ConversationHistorySnapshot[]) {
  const timeline: ConversationHistoryObject[] = [];
  const transcript: ConversationHistoryObject[] = [];
  const turns: ConversationHistoryObject[] = [];
  const timelineIDs = new Set<string>();
  const transcriptIDs = new Set<string>();
  const turnIDs = new Set<string>();
  snapshots.forEach((snapshot, snapshotIndex) => {
    (snapshot.timeline ?? []).forEach((item, index) => {
      const id = objectID(item, `timeline-${snapshotIndex}-${index}`);
      if (timelineIDs.has(id)) return;
      timelineIDs.add(id);
      timeline.push(item);
    });
    (snapshot.transcript ?? []).forEach((item, index) => {
      const id = objectID(item, `transcript-${snapshotIndex}-${index}`);
      if (transcriptIDs.has(id)) return;
      transcriptIDs.add(id);
      transcript.push(item);
    });
    (snapshot.turns ?? []).forEach((item, index) => {
      const id = objectID(item, `turn-${snapshotIndex}-${index}`);
      if (turnIDs.has(id)) return;
      turnIDs.add(id);
      turns.push(item);
    });
  });
  const latest = snapshots.at(-1) ?? {};
  return {
    ...latest,
    timeline,
    transcript,
    turns
  } satisfies ConversationHistorySnapshot;
}

export function extractRealtimeWorkHistory(snapshot: ConversationHistorySnapshot, limit = 30): RealtimeWorkHistoryItem[] {
  return (snapshot.turns ?? [])
    .flatMap((turn): RealtimeWorkHistoryItem[] => {
      const work = turn.realtimeWork;
      if (!work || typeof work !== "object" || Array.isArray(work)) return [];
      const record = work as ConversationHistoryObject;
      const taskID = String(turn.providerTurnID ?? turn.openAssistTurnID ?? "").trim();
      const state = String(record.state ?? "");
      const prompt = String(record.prompt ?? "").replace(/\s+/g, " ").trim().slice(0, 700);
      const resultPreview = String(record.resultPreview ?? "").replace(/\s+/g, " ").trim().slice(0, 1200);
      if (!taskID || !prompt || !["completed", "failed", "cancelled"].includes(state)) return [];
      const startedAt = Number(record.startedAt ?? turn.createdAt ?? 0);
      const finishedAt = Number(record.finishedAt ?? turn.updatedAt ?? startedAt);
      const rawSteps = Array.isArray(record.progressEntries) ? record.progressEntries : [];
      const progressEntries = rawSteps.flatMap((item, index) => {
        if (!item || typeof item !== "object" || Array.isArray(item)) return [];
        const entry = item as ConversationHistoryObject;
        const text = String(entry.text ?? "").replace(/\s+/g, " ").trim().slice(0, 700);
        if (!text) return [];
        const createdAt = Number(entry.createdAt ?? startedAt + index);
        return [{
          id: String(entry.id ?? `${taskID}-progress-${index}`),
          text,
          createdAt: Number.isFinite(createdAt) ? createdAt : startedAt + index
        }];
      }).slice(-20);
      return [{
        taskID,
        workerProvider: String(record.workerProvider ?? "Agent").trim() || "Agent",
        state: state as RealtimeWorkHistoryItem["state"],
        prompt,
        resultPreview,
        ...(progressEntries.length ? { progressEntries } : {}),
        startedAt: Number.isFinite(startedAt) ? startedAt : 0,
        finishedAt: Number.isFinite(finishedAt) ? finishedAt : startedAt
      }];
    })
    .sort((left, right) => right.finishedAt - left.finishedAt)
    .slice(0, Math.max(0, limit));
}

export function readRecentRealtimeWorkHistory(
  directory: string,
  currentSnapshot: ConversationHistorySnapshot,
  limit = 30
) {
  const found = new Map<string, RealtimeWorkHistoryItem>();
  for (const item of extractRealtimeWorkHistory(currentSnapshot, limit)) found.set(item.taskID, item);
  const segmentFiles = conversationHistorySegmentFiles(directory).reverse();
  for (const { file } of segmentFiles) {
    if (found.size >= limit) break;
    const snapshot = readJSON<ConversationHistorySnapshot>(path.join(directory, file));
    for (const item of extractRealtimeWorkHistory(snapshot ?? {}, limit)) found.set(item.taskID, item);
  }
  return [...found.values()]
    .sort((left, right) => right.finishedAt - left.finishedAt)
    .slice(0, Math.max(0, limit));
}

function itemKind(item: ConversationHistoryObject) {
  return String(item.kind ?? "").replace(/[_\s-]+/g, "").toLowerCase();
}

function isUnfinished(item: ConversationHistoryObject) {
  if (item.isStreaming === true) return true;
  const activity = item.activity && typeof item.activity === "object" ? item.activity as ConversationHistoryObject : null;
  const status = String(activity?.status ?? "").toLowerCase();
  return status === "running" || status === "pending" || status === "waiting";
}

function splitSnapshot(snapshot: ConversationHistorySnapshot, retainTurns: number) {
  const turns = snapshot.turns ?? [];
  if (turns.length <= retainTurns) return null;
  const activeTurns = turns.slice(-retainTurns);
  const archivedTurns = turns.slice(0, -retainTurns);
  const firstActiveTurn = activeTurns[0];
  const firstAssistantID = Array.isArray(firstActiveTurn?.messageIDs) ? String(firstActiveTurn.messageIDs[0] ?? "") : "";
  const timeline = snapshot.timeline ?? [];
  const assistantIndex = timeline.findIndex((item) => String(item.id ?? "") === firstAssistantID);
  if (assistantIndex < 0) return null;
  let timelineCut = assistantIndex;
  for (let index = assistantIndex - 1; index >= 0; index -= 1) {
    if (itemKind(timeline[index] ?? {}) === "usermessage") {
      timelineCut = index;
      break;
    }
  }
  const transcript = snapshot.transcript ?? [];
  const userIndexes = transcript.flatMap((item, index) => item.role === "user" ? [index] : []);
  if (userIndexes.length < retainTurns) return null;
  const transcriptCut = userIndexes[userIndexes.length - retainTurns] ?? 0;
  const archivedTimeline = timeline.slice(0, timelineCut);
  if (archivedTimeline.some(isUnfinished)) return null;
  return {
    archived: {
      ...snapshot,
      timeline: archivedTimeline,
      transcript: transcript.slice(0, transcriptCut),
      turns: archivedTurns
    } satisfies ConversationHistorySnapshot,
    active: {
      ...snapshot,
      timeline: timeline.slice(timelineCut),
      transcript: transcript.slice(transcriptCut),
      turns: activeTurns
    } satisfies ConversationHistorySnapshot
  };
}

export function rotateConversationHistory(
  directory: string,
  snapshot: ConversationHistorySnapshot,
  options: { maxTurns?: number; maxBytes?: number; retainTurns?: number } = {}
) {
  const maxTurns = options.maxTurns ?? 500;
  const maxBytes = options.maxBytes ?? 5 * 1024 * 1024;
  const turns = snapshot.turns ?? [];
  const estimatedBytes = Buffer.byteLength(JSON.stringify(snapshot), "utf8");
  if (turns.length < maxTurns && estimatedBytes < maxBytes) return snapshot;
  const preferredRetain = options.retainTurns ?? 100;
  const retainTurns = turns.length <= preferredRetain ? Math.min(20, Math.max(1, turns.length - 1)) : preferredRetain;
  const split = splitSnapshot(snapshot, retainTurns);
  if (!split || !(split.archived.turns?.length)) return snapshot;

  const existing = conversationHistorySegmentFiles(directory);
  const nextSequence = (existing.at(-1)?.sequence ?? 0) + 1;
  const segmentFile = `conversation-segment-${String(nextSequence).padStart(4, "0")}.json`;
  atomicWriteJSON(path.join(directory, segmentFile), split.archived);

  const manifestPath = path.join(directory, "conversation-history.json");
  const manifest = readJSON<ConversationHistoryManifest>(manifestPath) ?? { version: 1, segments: [] };
  const archivedTranscript = split.archived.transcript ?? [];
  manifest.segments = [
    ...manifest.segments.filter((entry) => entry.file !== segmentFile),
    {
      file: segmentFile,
      turnCount: split.archived.turns?.length ?? 0,
      firstMessageID: archivedTranscript[0] ? String(archivedTranscript[0].id ?? "") || undefined : undefined,
      lastMessageID: archivedTranscript.at(-1) ? String(archivedTranscript.at(-1)?.id ?? "") || undefined : undefined,
      createdAt: Date.now()
    }
  ];
  atomicWriteJSON(manifestPath, manifest);
  return split.active;
}
