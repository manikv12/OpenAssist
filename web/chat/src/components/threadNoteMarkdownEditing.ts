import { buildThreadNoteMarkdownImage } from "./threadNoteImageMarkdown";

const FENCED_CODE_SEGMENT_PATTERN = /(```[\s\S]*?```|~~~[\s\S]*?~~~)/g;

export interface ThreadNoteSelectionSnapshot {
  selectedMarkdown: string;
  snapshotMarkdown: string;
}

export interface ThreadNoteMarkdownRange {
  from: number;
  to: number;
}

export function normalizeThreadNoteStoredMarkdown(markdown: string): string {
  return normalizeThreadNoteHtmlImages(normalizeLineEndings(markdown));
}

export function replaceSelectionInMarkdown(
  markdown: string,
  selection: ThreadNoteSelectionSnapshot | null,
  replacement: string
): string | null {
  const range = resolveSelectionRange(markdown, selection);
  if (!range) {
    return null;
  }

  return replaceMarkdownRange(markdown, range, replacement);
}

export function insertMarkdownAboveSelection(
  markdown: string,
  selection: ThreadNoteSelectionSnapshot | null,
  insertion: string
): string | null {
  const range = resolveSelectionRange(markdown, selection);
  if (!range) {
    return null;
  }

  const trimmedInsertion = normalizeLineEndings(insertion).trim();
  if (!trimmedInsertion) {
    return markdown;
  }

  const prefix = markdown.slice(0, range.from).replace(/\s*$/, "");
  const suffix = markdown.slice(range.from).replace(/^\s*/, "");
  return normalizeLineEndings([prefix, trimmedInsertion, suffix].filter(Boolean).join("\n\n"));
}

export function insertMarkdownBelowSelection(
  markdown: string,
  selection: ThreadNoteSelectionSnapshot | null,
  insertion: string
): string | null {
  const range = resolveSelectionRange(markdown, selection);
  if (!range) {
    return null;
  }

  const trimmedInsertion = normalizeLineEndings(insertion).trim();
  if (!trimmedInsertion) {
    return markdown;
  }

  const prefix = markdown.slice(0, range.to).replace(/\s*$/, "");
  const suffix = markdown.slice(range.to).replace(/^\s*/, "");
  return normalizeLineEndings([prefix, trimmedInsertion, suffix].filter(Boolean).join("\n\n"));
}

export function appendMarkdownToNote(markdown: string, addition: string): string {
  const trimmedBase = normalizeLineEndings(markdown).trim();
  const trimmedAddition = normalizeLineEndings(addition).trim();
  return [trimmedBase, trimmedAddition].filter(Boolean).join("\n\n");
}

export function prependMarkdownToNote(markdown: string, addition: string): string {
  const trimmedBase = normalizeLineEndings(markdown).trim();
  const trimmedAddition = normalizeLineEndings(addition).trim();
  return [trimmedAddition, trimmedBase].filter(Boolean).join("\n\n");
}

export function replaceMarkdownRange(
  markdown: string,
  range: ThreadNoteMarkdownRange,
  replacement: string
): string {
  const normalized = normalizeLineEndings(markdown);
  const safeStart = clampRangeBoundary(range.from, normalized.length);
  const safeEnd = clampRangeBoundary(range.to, normalized.length);
  const start = Math.min(safeStart, safeEnd);
  const end = Math.max(safeStart, safeEnd);
  return normalizeLineEndings(
    `${normalized.slice(0, start)}${replacement}${normalized.slice(end)}`
  );
}

function resolveSelectionRange(
  markdown: string,
  selection: ThreadNoteSelectionSnapshot | null
): ThreadNoteMarkdownRange | null {
  if (!selection?.selectedMarkdown.trim()) {
    return null;
  }

  const selected = normalizeLineEndings(selection.selectedMarkdown).trim();
  const snapshot = normalizeLineEndings(selection.snapshotMarkdown);
  const normalizedMarkdown = normalizeLineEndings(markdown);

  const snapshotIndex = snapshot.indexOf(selected);
  if (snapshotIndex >= 0) {
    const candidate = normalizedMarkdown.indexOf(selected, snapshotIndex);
    if (candidate >= 0) {
      return { from: candidate, to: candidate + selected.length };
    }
  }

  const exactIndex = normalizedMarkdown.indexOf(selected);
  if (exactIndex >= 0) {
    return { from: exactIndex, to: exactIndex + selected.length };
  }

  return null;
}

function normalizeThreadNoteHtmlImages(markdown: string): string {
  return markdown
    .split(FENCED_CODE_SEGMENT_PATTERN)
    .map((segment) => {
      if (segment.startsWith("```") || segment.startsWith("~~~")) {
        return segment;
      }

      return segment.replace(/<img\s+([^>]*?)\/?>/gi, (match, rawAttributes = "") => {
        const attributes = parseHtmlAttributes(rawAttributes);
        const src = attributes.src?.trim();
        if (!src) {
          return match;
        }

        const width = parseOptionalInteger(attributes.width);
        return buildThreadNoteMarkdownImage({
          src,
          alt: attributes.alt ?? "",
          title: attributes.title,
          width: width ?? undefined,
        });
      });
    })
    .join("");
}

function parseHtmlAttributes(rawAttributes: string): Record<string, string> {
  const attributes: Record<string, string> = {};
  for (const match of rawAttributes.matchAll(/([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*"([^"]*)"/g)) {
    attributes[match[1].toLowerCase()] = decodeHtmlEntity(match[2]);
  }
  return attributes;
}

function decodeHtmlEntity(value: string): string {
  return value
    .replaceAll("&quot;", '"')
    .replaceAll("&amp;", "&")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">");
}

function parseOptionalInteger(value: string | null | undefined): number | null {
  if (!value) {
    return null;
  }

  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function clampRangeBoundary(value: number, maxLength: number): number {
  if (!Number.isFinite(value)) {
    return maxLength;
  }

  return Math.max(0, Math.min(maxLength, Math.round(value)));
}

function normalizeLineEndings(value: string): string {
  return value.replace(/\r\n/g, "\n");
}
