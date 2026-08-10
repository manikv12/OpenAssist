import { createHash } from "node:crypto";

export type KnowledgeResolveRequest = {
  userIntent: string;
  projectID?: string;
  projectName?: string;
  selectedNoteID?: string;
  limit?: number;
};

export type KnowledgeResolveNote = {
  id: string;
  title: string;
  projectID?: string;
  projectName?: string;
  sourceLabel?: string;
  markdown: string;
  updatedAt?: number;
};

export type KnowledgeResolveCandidate = Omit<KnowledgeResolveNote, "markdown"> & {
  snippet: string;
  score: number;
};

export type KnowledgeResolveResult =
  | { status: "resolved"; query: string; note: KnowledgeResolveNote; candidates: KnowledgeResolveCandidate[]; message: string }
  | { status: "selection_required"; query: string; candidates: KnowledgeResolveCandidate[]; message: string }
  | { status: "not_found"; query: string; candidates: []; message: string };

const fillerWords = new Set([
  "a", "about", "all", "an", "and", "before", "can", "check", "did", "do", "find",
  "for", "from", "inside", "in", "it", "made", "me", "my", "note", "notes", "of",
  "on", "open", "openassist", "please", "project", "read", "saved", "show", "tell", "the",
  "to", "we", "what", "which", "write", "wrote", "you", "your"
]);

function normalized(value: string) {
  return value.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").replace(/\s+/g, " ").trim();
}

function meaningfulTerms(value: string, projectName = "") {
  const projectTerms = new Set(normalized(projectName).split(" ").filter(Boolean));
  return [...new Set(normalized(value).split(" ").filter((term) =>
    term.length > 1 && !fillerWords.has(term) && !projectTerms.has(term)
  ))];
}

function snippet(markdown: string, terms: string[]) {
  const text = markdown.replace(/```[\s\S]*?```/g, " ").replace(/[#>*_`[\]()!-]/g, " ").replace(/\s+/g, " ").trim();
  if (!text) return "";
  const lower = text.toLowerCase();
  const index = terms.map((term) => lower.indexOf(term)).filter((value) => value >= 0).sort((a, b) => a - b)[0] ?? 0;
  const start = Math.max(0, index - 70);
  return `${start ? "..." : ""}${text.slice(start, start + 220)}${start + 220 < text.length ? "..." : ""}`;
}

function contentFingerprint(note: KnowledgeResolveNote) {
  return createHash("sha1").update(normalized(`${note.title}\n${note.markdown}`)).digest("hex");
}

function candidate(note: KnowledgeResolveNote, score: number, terms: string[]): KnowledgeResolveCandidate {
  return {
    id: note.id,
    title: note.title,
    projectID: note.projectID,
    projectName: note.projectName,
    sourceLabel: note.sourceLabel,
    updatedAt: note.updatedAt,
    snippet: snippet(note.markdown, terms),
    score
  };
}

function listMessage(candidates: KnowledgeResolveCandidate[]) {
  const titles = candidates.map((item, index) => `${index + 1}. ${item.title}`).join("; ");
  return `I found these recent notes: ${titles}. Which one should I open?`;
}

export function resolveKnowledgeInformation(
  request: KnowledgeResolveRequest,
  notes: KnowledgeResolveNote[]
): KnowledgeResolveResult {
  const intent = request.userIntent.replace(/\s+/g, " ").trim();
  const requestedProjectID = request.projectID?.trim().toLowerCase();
  const requestedProjectName = normalized(request.projectName ?? "");
  const intentKey = normalized(intent).replace(/\s/g, "");
  const namedProject = notes
    .map((note) => ({ id: note.projectID?.trim(), name: note.projectName?.trim() }))
    .filter((project): project is { id: string; name: string } => Boolean(project.id && project.name))
    .sort((left, right) => right.name.length - left.name.length)
    .find((project) => intentKey.includes(normalized(project.name).replace(/\s/g, "")));
  const effectiveProjectID = requestedProjectID || namedProject?.id.toLowerCase();
  const effectiveProjectName = request.projectName?.trim() || namedProject?.name || "";
  const scoped = notes.filter((note) => {
    if (effectiveProjectID) return note.projectID?.trim().toLowerCase() === effectiveProjectID;
    if (requestedProjectName) return normalized(note.projectName ?? "") === requestedProjectName;
    return true;
  });
  const selected = request.selectedNoteID?.trim();
  if (selected) {
    const note = scoped.find((entry) => entry.id === selected) ?? notes.find((entry) => entry.id === selected);
    if (note) return { status: "resolved", query: intent, note, candidates: [candidate(note, 1000, [])], message: `Opened ${note.title}.` };
  }

  const terms = meaningfulTerms(intent, effectiveProjectName);
  const limit = Math.max(1, Math.min(5, Number(request.limit) || 5));
  if (!terms.length) {
    const recent = scoped
      .sort((left, right) => (right.updatedAt ?? 0) - (left.updatedAt ?? 0))
      .slice(0, limit)
      .map((note) => candidate(note, 1, []));
    if (!recent.length) return { status: "not_found", query: intent, candidates: [], message: "I could not find any notes in that project." };
    return { status: "selection_required", query: intent, candidates: recent, message: listMessage(recent) };
  }

  const ranked = scoped.map((note) => {
    const title = normalized(note.title);
    const body = normalized(note.markdown);
    let score = 0;
    for (const term of terms) {
      if (title.includes(term)) score += 6;
      if (body.includes(term)) score += 2;
    }
    if (terms.every((term) => title.includes(term))) score += 10;
    else if (terms.every((term) => body.includes(term) || title.includes(term))) score += 4;
    return { note, score };
  }).filter((entry) => entry.score > 0)
    .sort((left, right) => right.score - left.score || (right.note.updatedAt ?? 0) - (left.note.updatedAt ?? 0));

  if (!ranked.length) return { status: "not_found", query: terms.join(" "), candidates: [], message: "I could not find a matching OpenAssist note." };
  const top = ranked[0];
  const peers = ranked.filter((entry) => entry.score === top.score);
  const distinctPeers = new Set(peers.map((entry) => contentFingerprint(entry.note)));
  const clear = peers.length === 1 || distinctPeers.size === 1 || top.score >= (ranked[1]?.score ?? 0) + 4;
  const candidates = ranked.slice(0, limit).map((entry) => candidate(entry.note, entry.score, terms));
  if (!clear) return { status: "selection_required", query: terms.join(" "), candidates, message: listMessage(candidates) };
  return {
    status: "resolved",
    query: terms.join(" "),
    note: top.note,
    candidates,
    message: `Opened ${top.note.title}.`
  };
}
