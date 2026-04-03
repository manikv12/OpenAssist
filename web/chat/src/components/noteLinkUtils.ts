export interface InternalNoteLinkTarget {
  ownerKind: string;
  ownerId: string;
  noteId: string;
}

const NOTE_LINK_SCHEME = "oa-note:";
const NOTE_LINK_HOST = "open";

export function buildInternalNoteHref(target: InternalNoteLinkTarget): string {
  const url = new URL(`${NOTE_LINK_SCHEME}//${NOTE_LINK_HOST}`);
  url.searchParams.set("ownerKind", target.ownerKind);
  url.searchParams.set("ownerId", target.ownerId);
  url.searchParams.set("noteId", target.noteId);
  return url.toString();
}

export function parseInternalNoteHref(href: string | null | undefined): InternalNoteLinkTarget | null {
  if (!href) {
    return null;
  }

  try {
    const url = new URL(href);
    if (url.protocol !== NOTE_LINK_SCHEME || url.hostname !== NOTE_LINK_HOST) {
      return null;
    }

    const ownerKind = url.searchParams.get("ownerKind")?.trim();
    const ownerId = url.searchParams.get("ownerId")?.trim();
    const noteId = url.searchParams.get("noteId")?.trim();
    if (!ownerKind || !ownerId || !noteId) {
      return null;
    }

    return {
      ownerKind,
      ownerId,
      noteId,
    };
  } catch {
    return null;
  }
}

export function isInternalNoteHref(href: string | null | undefined): boolean {
  return parseInternalNoteHref(href) !== null;
}

export function buildInternalNoteMarkdownLink(
  label: string,
  target: InternalNoteLinkTarget
): string {
  return `[${sanitizeMarkdownLinkLabel(label)}](${buildInternalNoteHref(target)})`;
}

function sanitizeMarkdownLinkLabel(label: string): string {
  return label
    .replaceAll("\\", "\\\\")
    .replaceAll("[", "\\[")
    .replaceAll("]", "\\]")
    .trim();
}
