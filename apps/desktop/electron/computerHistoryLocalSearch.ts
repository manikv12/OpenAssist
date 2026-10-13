import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";

export type ComputerHistoryLocalSearchRequest = {
  query: string;
  fromDate?: string;
  toDate?: string;
  app?: string;
  project?: string;
};

export type ComputerHistoryLocalSearchSource = {
  observedAt?: string;
  app?: string;
  title?: string;
  detail?: string;
};

export type ComputerHistoryLocalSearchResult = {
  answer: string;
  confidence: "high" | "medium" | "low";
  sources: ComputerHistoryLocalSearchSource[];
};

type HistoryEvent = {
  timestamp?: string;
  kind?: string;
  app?: { name?: string; bundleIdentifier?: string };
  window?: { title?: string; url?: string };
  ax?: { text?: string };
  mouse?: { target?: { description?: string; role?: string } };
};

type SearchMatch = {
  timestampMs: number;
  observedAt: string;
  app: string;
  title: string;
  detail: string;
  score: number;
  meetingLike: boolean;
};

const stopWords = new Set([
  "a", "about", "all", "an", "and", "any", "app", "apps", "attend", "attended", "check",
  "did", "do", "document", "documents", "for", "from", "history", "i", "include", "in", "is",
  "me", "meeting", "meetings", "my", "of", "on", "or", "project", "projects", "show", "site",
  "sites", "that", "the", "this", "today", "use", "used", "was", "website", "websites", "what",
  "when", "which", "with", "work", "worked", "yesterday"
]);

const instructionMarkers = [
  "selected installed plugins for this turn",
  "treat these plugins as the required path",
  "return only json matching the requested schema",
  "search the user's computer history",
  "computer history search is ready",
  "oa_get_computer_history_search",
  "oa_request_computer_history_search"
];

const meetingAppPattern = /\b(zoom|microsoft teams|google meet|meet\.google|webex|facetime)\b/i;
const meetingTitlePattern = /\b(meeting|conference|video call)\b/i;
const maxSegments = 2_100;
const maxEventLines = 120_000;
const maxAxCharacters = 36_000;

function cleanText(value: unknown, maxLength: number) {
  if (typeof value !== "string") return "";
  return value
    .replace(/[\u0000-\u001f\u007f]+/g, " ")
    .replace(/\b(?:Bearer|token|password|secret|api[_ -]?key)\s*[:=]\s*\S+/gi, "[redacted]")
    .replace(/file:\/\/\S+/gi, "[local path]")
    .replace(/\/(?:Users|home)\/[^\s/]+\/[^\s,;)}\]]+/g, "[local path]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxLength);
}

function tokens(value: string) {
  return Array.from(new Set(value
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, " ")
    .split(/\s+/)
    .filter((token) => token.length >= 2 && !stopWords.has(token))));
}

function containsToken(value: string, token: string) {
  return new RegExp(`(?:^|[^a-z0-9])${token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?:$|[^a-z0-9])`, "i").test(value);
}

function localDayBoundary(value: string, endOfDay: boolean) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value.trim());
  if (!match) return Number.NaN;
  const date = new Date(
    Number(match[1]),
    Number(match[2]) - 1,
    Number(match[3]),
    endOfDay ? 23 : 0,
    endOfDay ? 59 : 0,
    endOfDay ? 59 : 0,
    endOfDay ? 999 : 0
  );
  return date.getTime();
}

function parseBoundary(value: string | undefined, endOfDay: boolean) {
  if (!value) return Number.NaN;
  const local = localDayBoundary(value, endOfDay);
  if (Number.isFinite(local)) return local;
  return Date.parse(value);
}

function dayRange(nowMs: number, dayOffset: number) {
  const date = new Date(nowMs);
  date.setDate(date.getDate() + dayOffset);
  const start = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
  const end = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 23, 59, 59, 999).getTime();
  return { start, end };
}

export function computerHistorySearchRange(request: ComputerHistoryLocalSearchRequest, nowMs = Date.now()) {
  const query = request.query.toLowerCase();
  const explicitStart = parseBoundary(request.fromDate, false);
  const explicitEnd = parseBoundary(request.toDate, true);
  const relative = /\byesterday\b/.test(query)
    ? dayRange(nowMs, -1)
    : /\btoday\b/.test(query)
      ? dayRange(nowMs, 0)
      : null;
  let start = Number.isFinite(explicitStart)
    ? explicitStart
    : relative?.start ?? nowMs - 7 * 24 * 60 * 60_000;
  let end = Number.isFinite(explicitEnd)
    ? explicitEnd
    : relative?.end ?? nowMs;
  // Ignore the just-recorded search prompt itself.
  end = Math.min(end, nowMs - 10_000);
  if (!Number.isFinite(start) || !Number.isFinite(end) || start > end) {
    throw new Error("Computer History received an invalid date range.");
  }
  return { start, end };
}

function eventTimestamp(value: HistoryEvent) {
  const parsed = Date.parse(value.timestamp ?? "");
  return Number.isFinite(parsed) ? parsed : Number.NaN;
}

function segmentTimestamp(directoryName: string) {
  const direct = Date.parse(directoryName);
  if (Number.isFinite(direct)) return direct;
  const compact = /^(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})(?:\.(\d+))?Z$/.exec(directoryName);
  if (!compact) return Number.NaN;
  return Date.parse(`${compact[1]}T${compact[2]}:${compact[3]}:${compact[4]}${compact[5] ? `.${compact[5]}` : ""}Z`);
}

function safeUrlLabel(rawUrl: string) {
  if (!rawUrl) return "";
  try {
    const url = new URL(rawUrl);
    return cleanText(url.hostname.replace(/^www\./, ""), 100);
  } catch {
    return "";
  }
}

function cleanAxLine(line: string) {
  return cleanText(line
    .replace(/^\s*[|+`\-]+\s*/, "")
    .replace(/^~?\d+\s+(?:container|button|text|image|group|heading|standard window|html content)\b(?:\s+\(collapsed\))?\s*/i, "")
    .replace(/^~?\d+\s+/, ""), 220);
}

function searchableAxLines(axText: string, exactQuery: string) {
  return axText
    .split(/\r?\n/)
    .map(cleanAxLine)
    .filter((line) => line.length >= 4)
    .filter((line) => !instructionMarkers.some((marker) => line.toLowerCase().includes(marker)))
    .filter((line) => !exactQuery || !line.toLowerCase().includes(exactQuery));
}

function usefulAxLine(lines: string[], meaningfulTokens: string[]) {
  return lines.find((line) => meaningfulTokens.some((token) => containsToken(line, token)))
    ?? "";
}

function isMeetingSurface(app: string, title: string, site: string) {
  const surface = `${app} ${title} ${site}`;
  if (meetingAppPattern.test(surface)) return true;
  return meetingTitlePattern.test(title) && /\b(teams|zoom|meet|webex|facetime)\b/i.test(surface);
}

function eventMatch(
  event: HistoryEvent,
  request: ComputerHistoryLocalSearchRequest,
  meaningfulTokens: string[],
  projectTokens: string[],
  appTokens: string[],
  range: { start: number; end: number }
): SearchMatch | null {
  const timestampMs = eventTimestamp(event);
  if (!Number.isFinite(timestampMs) || timestampMs < range.start || timestampMs > range.end) return null;
  const app = cleanText(event.app?.name || event.app?.bundleIdentifier, 120);
  const title = cleanText(event.window?.title, 240);
  const site = safeUrlLabel(event.window?.url ?? "");
  const rawAx = typeof event.ax?.text === "string" ? event.ax.text.slice(0, maxAxCharacters) : "";
  const exactQuery = request.query.trim().toLowerCase();
  const promptEcho = exactQuery
    && rawAx.toLowerCase().includes(exactQuery)
    && /\b(codex|chatgpt|openassist)\b/i.test(`${app} ${title}`);
  const searchDebugEcho = /\b(codex|chatgpt|claude)\b/i.test(app)
    && /\b(computer history|openassist mcp|history search|plugin instructions?|matching activity)\b/i.test(rawAx);
  if (promptEcho || searchDebugEcho) return null;
  const axLines = searchableAxLines(rawAx, exactQuery);
  const searchableAx = axLines.join("\n");
  const haystack = `${app}\n${event.app?.bundleIdentifier ?? ""}\n${title}\n${site}\n${searchableAx}`.toLowerCase();
  if (appTokens.length > 0 && !appTokens.every((token) => containsToken(`${app} ${event.app?.bundleIdentifier ?? ""}`, token))) {
    return null;
  }
  if (projectTokens.length > 0 && !projectTokens.some((token) => containsToken(haystack, token))) return null;
  const hits = meaningfulTokens.filter((token) => containsToken(haystack, token));
  const broadInventoryQuery = meaningfulTokens.length === 0;
  if (!broadInventoryQuery && hits.length === 0) return null;

  let score = hits.length * 2;
  score += projectTokens.filter((token) => hits.includes(token)).length * 3;
  if (title && hits.some((token) => containsToken(title, token))) score += 4;
  if (appTokens.length > 0) score += 5;
  const meetingLike = isMeetingSurface(app, title, site);
  if (meetingLike) score += 2;
  const detail = usefulAxLine(axLines, meaningfulTokens)
    || cleanText(event.mouse?.target?.description, 180)
    || cleanText(event.kind, 100);
  return {
    timestampMs,
    observedAt: new Date(timestampMs).toISOString(),
    app: app || "Unknown app",
    title: title || site || "Activity",
    detail: site && site !== title ? cleanText(`${site}${detail ? ` - ${detail}` : ""}`, 260) : cleanText(detail, 260),
    score,
    meetingLike
  };
}

function dedupeMatches(matches: SearchMatch[]) {
  const byWindow = new Map<string, SearchMatch>();
  for (const match of matches) {
    const key = `${match.app.toLowerCase()}|${match.title.toLowerCase()}`;
    const existing = byWindow.get(key);
    if (!existing || match.score > existing.score || (match.score === existing.score && match.timestampMs > existing.timestampMs)) {
      byWindow.set(key, match);
    }
  }
  return Array.from(byWindow.values())
    .sort((left, right) => right.score - left.score || right.timestampMs - left.timestampMs);
}

function summarize(
  request: ComputerHistoryLocalSearchRequest,
  matches: SearchMatch[]
): ComputerHistoryLocalSearchResult {
  if (matches.length === 0) {
    return {
      answer: "I did not find matching Computer History activity in that time range. This means no matching evidence was found; it does not prove that no work happened.",
      confidence: "low",
      sources: []
    };
  }
  const selected = matches.slice(0, 8);
  const appCounts = new Map<string, number>();
  for (const match of matches) appCounts.set(match.app, (appCounts.get(match.app) ?? 0) + 1);
  const topApps = Array.from(appCounts.entries())
    .sort((left, right) => right[1] - left[1])
    .slice(0, 4)
    .map(([app]) => app);
  const topic = cleanText(request.project || tokens(request.query).slice(0, 3).join(" "), 100);
  const wantsMeetings = /\b(meeting|meetings|attend|attended|call|calls)\b/i.test(request.query);
  const meetingCount = matches.filter((match) => match.meetingLike).length;
  const examples = selected.slice(0, 4).map((match) => `${match.app}: ${match.title}`).join("; ");
  const subject = topic ? ` related to ${topic}` : "";
  const resultCount = selected.length;
  const additionalCount = Math.max(0, matches.length - resultCount);
  let answer = `I found ${resultCount} strong matching ${resultCount === 1 ? "activity" : "activities"}${subject}. The main apps were ${topApps.join(", ")}. Examples: ${examples}.`;
  if (additionalCount > 0) answer += ` ${additionalCount} lower-ranked matching surfaces were omitted from this summary.`;
  if (wantsMeetings) {
    answer += meetingCount > 0
      ? ` I also found ${meetingCount} possible ${meetingCount === 1 ? "meeting" : "meetings"}. This shows meeting-app activity, not guaranteed attendance.`
      : " I did not find clear meeting-app evidence in the matching activity.";
  }
  return {
    answer: cleanText(answer, 4_000),
    confidence: matches.length >= 4 ? "high" : "medium",
    sources: selected.map((match) => ({
      observedAt: match.observedAt,
      app: match.app,
      title: match.title,
      detail: match.detail || undefined
    }))
  };
}

export async function searchComputerHistoryLocally(
  rootPath: string,
  request: ComputerHistoryLocalSearchRequest,
  options: { nowMs?: number } = {}
): Promise<ComputerHistoryLocalSearchResult> {
  if (!path.isAbsolute(rootPath)) throw new Error("Computer History returned an invalid activity folder.");
  const root = fs.realpathSync(rootPath);
  const segmentsDirectory = path.join(root, "segments");
  if (!fs.existsSync(segmentsDirectory) || !fs.statSync(segmentsDirectory).isDirectory()) {
    throw new Error("Computer History activity segments are not available.");
  }
  const nowMs = options.nowMs ?? Date.now();
  const range = computerHistorySearchRange(request, nowMs);
  const projectTokens = tokens(request.project ?? "");
  const appTokens = tokens(request.app ?? "");
  const meaningfulTokens = Array.from(new Set([...tokens(request.query), ...projectTokens]));
  const segmentEntries = fs.readdirSync(segmentsDirectory, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => ({ entry, startedAt: segmentTimestamp(entry.name) }))
    .filter(({ startedAt }) => Number.isFinite(startedAt) && startedAt <= range.end && startedAt + 15 * 60_000 >= range.start)
    .sort((left, right) => right.startedAt - left.startedAt)
    .slice(0, maxSegments);

  const matches: SearchMatch[] = [];
  let lineCount = 0;
  for (const { entry } of segmentEntries) {
    const segmentPath = fs.realpathSync(path.join(segmentsDirectory, entry.name));
    if (segmentPath !== root && !segmentPath.startsWith(`${root}${path.sep}`)) continue;
    const eventsPath = path.join(segmentPath, "events.jsonl");
    if (!fs.existsSync(eventsPath) || !fs.statSync(eventsPath).isFile()) continue;
    const input = fs.createReadStream(eventsPath, { encoding: "utf8" });
    const lines = readline.createInterface({ input, crlfDelay: Infinity });
    for await (const line of lines) {
      lineCount += 1;
      if (lineCount > maxEventLines) {
        lines.close();
        input.destroy();
        break;
      }
      if (!line.trim() || line.length > 2_000_000) continue;
      try {
        const event = JSON.parse(line) as HistoryEvent;
        const match = eventMatch(event, request, meaningfulTokens, projectTokens, appTokens, range);
        if (match) matches.push(match);
      } catch {
        // A corrupt event line must not stop the remaining private history search.
      }
    }
    if (lineCount > maxEventLines) break;
  }
  return summarize(request, dedupeMatches(matches));
}
