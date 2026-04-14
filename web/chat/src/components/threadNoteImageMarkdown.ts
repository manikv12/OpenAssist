const MARKDOWN_IMAGE_PATTERN =
  /!\[((?:\\.|[^\]])*)\]\(([^)\s]+)(?:\s+"((?:\\.|[^"])*)")?\)(?:\{([^}]*)\})?/g;
const FENCED_CODE_SEGMENT_PATTERN = /(```[\s\S]*?```|~~~[\s\S]*?~~~)/g;
const DISPLAY_ATTR_FRAGMENT = "#oa-note-attrs=";

export interface ThreadNoteMarkdownImage {
  alt: string;
  src: string;
  title?: string;
  width?: number;
  collapsed?: boolean;
}

export function buildThreadNoteMarkdownImage(image: ThreadNoteMarkdownImage): string {
  const normalizedWidth =
    typeof image.width === "number" && Number.isFinite(image.width) && image.width > 0
      ? Math.max(80, Math.round(image.width))
      : null;
  const escapedAlt = escapeMarkdownImageText(image.alt);
  const escapedTitle =
    image.title && image.title.trim().length > 0
      ? escapeMarkdownTitleText(image.title.trim())
      : null;

  const modifiers: string[] = [];
  if (normalizedWidth) {
    modifiers.push(`width=${normalizedWidth}`);
  }
  if (image.collapsed) {
    modifiers.push("collapsed");
  }

  return `![${escapedAlt}](${image.src}${escapedTitle ? ` "${escapedTitle}"` : ""})${
    modifiers.length > 0 ? `{${modifiers.join(",")}}` : ""
  }`;
}

export function normalizeThreadNoteMarkdownForRichText(markdown: string): string {
  return rewriteThreadNoteMarkdownImages(markdown, (image) => ({
    ...image,
    src:
      typeof image.width === "number" || image.collapsed
        ? withDisplayAttrFragment(image.src, image.width, image.collapsed)
        : image.src,
    width: undefined,
    collapsed: undefined,
  }));
}

export function resolveRenderedThreadNoteImage(src: string): {
  src: string;
  width: number | null;
  collapsed: boolean;
} {
  const match = src.match(/#oa-note-attrs=([^#]+)$/i);
  if (!match) {
    return { src, width: null, collapsed: false };
  }

  const params = match[1].split(",").filter(Boolean);
  let width: number | null = null;
  let collapsed = false;
  for (const part of params) {
    if (part === "collapsed") {
      collapsed = true;
      continue;
    }
    const widthMatch = part.match(/^width=(\d+)$/i);
    if (widthMatch) {
      const parsed = Number.parseInt(widthMatch[1], 10);
      if (Number.isFinite(parsed) && parsed > 0) {
        width = parsed;
      }
    }
  }

  return {
    src: src.slice(0, match.index),
    width,
    collapsed,
  };
}

function rewriteThreadNoteMarkdownImages(
  markdown: string,
  transform: (image: ThreadNoteMarkdownImage) => ThreadNoteMarkdownImage
): string {
  return markdown
    .replace(/\r\n/g, "\n")
    .split(FENCED_CODE_SEGMENT_PATTERN)
    .map((segment) => {
      if (segment.startsWith("```") || segment.startsWith("~~~")) {
        return segment;
      }

      return segment.replace(
        MARKDOWN_IMAGE_PATTERN,
        (_match, alt = "", src = "", title = "", modifiers = "") => {
          const parsed = parseImageModifiers(modifiers);
          const nextImage = transform({
            alt: unescapeMarkdownImageText(alt),
            src,
            title: title ? unescapeMarkdownTitleText(title) : undefined,
            width: parsed.width,
            collapsed: parsed.collapsed || undefined,
          });
          return buildThreadNoteMarkdownImage(nextImage);
        }
      );
    })
    .join("");
}

function withDisplayAttrFragment(
  src: string,
  width: number | undefined,
  collapsed: boolean | undefined
): string {
  const cleanSrc = src
    .replace(/#oa-note-width=\d+$/i, "")
    .replace(/#oa-note-attrs=[^#]+$/i, "");
  const parts: string[] = [];
  if (typeof width === "number" && Number.isFinite(width) && width > 0) {
    parts.push(`width=${Math.max(80, Math.round(width))}`);
  }
  if (collapsed) {
    parts.push("collapsed");
  }
  if (parts.length === 0) {
    return cleanSrc;
  }
  return `${cleanSrc}${DISPLAY_ATTR_FRAGMENT}${parts.join(",")}`;
}

function parseImageModifiers(rawValue: string): {
  width: number | undefined;
  collapsed: boolean;
} {
  if (!rawValue) {
    return { width: undefined, collapsed: false };
  }

  let width: number | undefined;
  let collapsed = false;
  for (const token of rawValue.split(/[,\s]+/).filter(Boolean)) {
    if (token === "collapsed") {
      collapsed = true;
      continue;
    }
    const widthMatch = token.match(/^width=(\d+)$/i);
    if (widthMatch) {
      const parsed = Number.parseInt(widthMatch[1], 10);
      if (Number.isFinite(parsed) && parsed > 0) {
        width = parsed;
      }
    }
  }
  return { width, collapsed };
}

function escapeMarkdownImageText(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/\]/g, "\\]");
}

function escapeMarkdownTitleText(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function unescapeMarkdownImageText(value: string): string {
  return value.replace(/\\([\]\\])/g, "$1");
}

function unescapeMarkdownTitleText(value: string): string {
  return value.replace(/\\(["\\])/g, "$1");
}
