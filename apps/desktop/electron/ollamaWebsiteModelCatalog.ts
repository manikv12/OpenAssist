import {
  curatedOllamaCatalog,
  type OllamaCatalogModelOption,
  physicalMemoryBytes
} from "./ollamaModelCatalog.js";

const WEBSITE_TAGS_ENDPOINT = "https://ollama.com/api/tags";
const LIBRARY_BASE_URL = "https://ollama.com/library";
const MIN_SMALL_MODEL_SIZE_BYTES = 700_000_000;
const MAX_SMALL_MODEL_SIZE_BYTES = 12_000_000_000;
const EXCLUDED_KEYWORDS = [
  "embed",
  "embedding",
  "vision",
  ":vl",
  "-vl",
  "audio",
  "tts",
  "whisper"
];
const SUPPLEMENTAL_FAMILY_SLUGS = ["qwen3", "gemma3n", "ministral-3"];

type WebsiteTagModel = {
  model: string;
  size: number;
  modified_at?: string;
};

type WebsiteModelCandidate = {
  option: OllamaCatalogModelOption;
  modifiedAt: number;
  sizeBytes: number;
};

function familySlugFromModelID(modelID: string): string | null {
  const normalized = modelID.trim();
  if (!normalized) return null;
  const [family] = normalized.split(":", 1);
  const slug = family?.trim();
  return slug || null;
}

function targetFamilySlugs(): string[] {
  const slugs = new Set<string>();
  for (const option of curatedOllamaCatalog(physicalMemoryBytes())) {
    const slug = familySlugFromModelID(option.id);
    if (slug) slugs.add(slug);
  }
  for (const slug of SUPPLEMENTAL_FAMILY_SLUGS) {
    slugs.add(slug);
  }
  return [...slugs].sort();
}

function isBeginnerFriendlyVariant(normalizedModelID: string): boolean {
  const separatorIndex = normalizedModelID.indexOf(":");
  if (separatorIndex < 0) return true;
  const variant = normalizedModelID.slice(separatorIndex + 1);
  if (!variant) return true;
  const disallowedMarkers = [
    "q2",
    "q3",
    "q4",
    "q5",
    "q6",
    "q8",
    "fp16",
    "bf16",
    "_",
    "-it",
    "instruct",
    "thinking",
    "reasoning"
  ];
  return !disallowedMarkers.some((marker) => variant.includes(marker));
}

function performanceLabelForGigabytes(sizeInGigabytes: number): string {
  if (sizeInGigabytes < 4) return "Very Fast";
  if (sizeInGigabytes < 9) return "Fast";
  return "Balanced";
}

function displayNameForModelID(modelID: string): string {
  const cleaned = modelID
    .replace(/:/g, " ")
    .replace(/-/g, " ")
    .replace(/_/g, " ");
  const tokens = cleaned.split(/\s+/).filter(Boolean).map((token) => {
    if (/^\d+b$/i.test(token)) return `${token.slice(0, -1)}B`;
    if (/^\d+m$/i.test(token)) return `${token.slice(0, -1)}M`;
    if (/^\d+$/.test(token)) return token;
    return token.charAt(0).toUpperCase() + token.slice(1);
  });
  const prettyName = tokens.join(" ").trim();
  return prettyName || modelID;
}

function parseModifiedAt(rawValue?: string): number {
  if (!rawValue?.trim()) return 0;
  const parsed = Date.parse(rawValue);
  return Number.isFinite(parsed) ? parsed : 0;
}

function smallCandidate(
  modelID: string,
  sizeBytes: number,
  modifiedAt?: string,
  summary = "Fetched from ollama.com website catalog."
): WebsiteModelCandidate | null {
  const normalized = modelID.trim();
  if (!normalized) return null;
  const normalizedID = normalized.toLowerCase();
  if (normalizedID.endsWith(":latest")) return null;
  if (normalizedID.includes("-cloud")) return null;
  if (EXCLUDED_KEYWORDS.some((keyword) => normalizedID.includes(keyword))) return null;
  if (!isBeginnerFriendlyVariant(normalizedID)) return null;
  if (sizeBytes < MIN_SMALL_MODEL_SIZE_BYTES || sizeBytes > MAX_SMALL_MODEL_SIZE_BYTES) return null;

  const sizeInGigabytes = sizeBytes / 1_000_000_000;
  return {
    option: {
      id: normalized,
      displayName: displayNameForModelID(normalized),
      sizeLabel: `~${sizeInGigabytes.toFixed(1)} GB`,
      performanceLabel: performanceLabelForGigabytes(sizeInGigabytes),
      description: summary,
      isRecommended: false,
      source: "website"
    },
    modifiedAt: parseModifiedAt(modifiedAt),
    sizeBytes
  };
}

function isPreferred(left: WebsiteModelCandidate, right: WebsiteModelCandidate): boolean {
  if (left.modifiedAt !== right.modifiedAt) return left.modifiedAt > right.modifiedAt;
  return left.sizeBytes < right.sizeBytes;
}

function dedupeCandidates(candidates: WebsiteModelCandidate[]): WebsiteModelCandidate[] {
  const bestByID = new Map<string, WebsiteModelCandidate>();
  for (const candidate of candidates) {
    const key = candidate.option.id.toLowerCase();
    const existing = bestByID.get(key);
    if (!existing || isPreferred(candidate, existing)) {
      bestByID.set(key, candidate);
    }
  }
  return [...bestByID.values()];
}

async function fetchWithTimeout(url: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function fetchAPIEndpointCandidates(): Promise<WebsiteModelCandidate[]> {
  const response = await fetchWithTimeout(WEBSITE_TAGS_ENDPOINT, {
    method: "GET",
    headers: { Accept: "application/json" }
  }, 20_000);
  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(detail.trim() || `Website catalog request failed (${response.status}).`);
  }
  const payload = await response.json() as { models?: WebsiteTagModel[] };
  const rows = Array.isArray(payload.models) ? payload.models : [];
  return rows
    .map((row) => smallCandidate(row.model, row.size, row.modified_at))
    .filter(Boolean) as WebsiteModelCandidate[];
}

function parseFamilyTagCandidates(html: string, familySlug: string): WebsiteModelCandidate[] {
  const modelAnchorRegex = /<a href="\/library\/([^"]+:[^"]+)"[^>]*>"/gi;
  const sizeRegex = /([0-9]+(?:\.[0-9]+)?)([MG])B/gi;
  const candidatesByModelID = new Map<string, WebsiteModelCandidate>();
  let match: RegExpExecArray | null;
  while ((match = modelAnchorRegex.exec(html)) !== null) {
    const modelID = match[1];
    const windowStart = match.index + match[0].length;
    const window = html.slice(windowStart, windowStart + 1500);
    sizeRegex.lastIndex = 0;
    const sizeMatch = sizeRegex.exec(window);
    if (!sizeMatch) continue;
    const magnitude = Number(sizeMatch[1]);
    const unit = sizeMatch[2]?.toUpperCase();
    if (!Number.isFinite(magnitude)) continue;
    const multiplier = unit === "G" ? 1_000_000_000 : unit === "M" ? 1_000_000 : 0;
    if (!multiplier) continue;
    const bytes = Math.round(magnitude * multiplier);
    const candidate = smallCandidate(
      modelID,
      bytes,
      undefined,
      `Fetched from ollama.com/${familySlug} tags page.`
    );
    if (!candidate) continue;
    const dedupeKey = candidate.option.id.toLowerCase();
    const existing = candidatesByModelID.get(dedupeKey);
    if (!existing || isPreferred(candidate, existing)) {
      candidatesByModelID.set(dedupeKey, candidate);
    }
  }
  return [...candidatesByModelID.values()];
}

async function fetchFamilyPageCandidates(): Promise<WebsiteModelCandidate[]> {
  const familySlugs = targetFamilySlugs();
  const results = await Promise.all(familySlugs.map(async (familySlug) => {
    try {
      const url = `${LIBRARY_BASE_URL}/${familySlug}/tags`;
      const response = await fetchWithTimeout(url, {
        method: "GET",
        headers: { Accept: "text/html" }
      }, 15_000);
      if (!response.ok) return [];
      const html = await response.text();
      if (!html.trim()) return [];
      return parseFamilyTagCandidates(html, familySlug);
    } catch {
      return [];
    }
  }));
  return results.flat();
}

export async function fetchOllamaWebsiteModelOptions(limit = 12): Promise<OllamaCatalogModelOption[]> {
  let primaryError: Error | null = null;
  const mergedCandidates: WebsiteModelCandidate[] = [];
  try {
    mergedCandidates.push(...await fetchAPIEndpointCandidates());
  } catch (error) {
    primaryError = error instanceof Error ? error : new Error(String(error));
  }
  mergedCandidates.push(...await fetchFamilyPageCandidates());
  const deduped = dedupeCandidates(mergedCandidates);
  if (!deduped.length) {
    if (primaryError) throw primaryError;
    throw new Error("Website catalog returned an invalid response.");
  }
  const sorted = deduped.sort((left, right) => {
    if (left.modifiedAt !== right.modifiedAt) return right.modifiedAt - left.modifiedAt;
    if (left.sizeBytes !== right.sizeBytes) return left.sizeBytes - right.sizeBytes;
    return left.option.id.localeCompare(right.option.id, undefined, { sensitivity: "base" });
  });
  const capped = limit > 0 ? sorted.slice(0, limit) : sorted;
  return capped.map((candidate) => candidate.option);
}

export function websiteCatalogStatusMessage(
  mergedCatalog: OllamaCatalogModelOption[],
  curatedCount: number,
  error?: string | null
): string {
  if (error?.trim()) {
    return `Could not fetch website catalog: ${error.trim()}`;
  }
  const addedCount = Math.max(0, mergedCatalog.length - curatedCount);
  if (!mergedCatalog.length) {
    return "No small website models matched the filter. Showing curated catalog.";
  }
  if (addedCount > 0) {
    return `Fetched latest website catalog. Added ${addedCount} new small-model options.`;
  }
  return "Fetched latest website catalog. No additional small models beyond curated options.";
}
