import {
  Node,
  mergeAttributes,
  type JSONContent,
  type MarkdownParseHelpers,
  type MarkdownRendererHelpers,
  type MarkdownToken,
} from "@tiptap/core";
import {
  NodeViewWrapper,
  ReactNodeViewRenderer,
  type NodeViewProps,
} from "@tiptap/react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { NodeSelection, TextSelection } from "@tiptap/pm/state";
import {
  buildThreadNoteMarkdownImage,
  resolveRenderedThreadNoteImage,
} from "./threadNoteImageMarkdown";

const MIN_IMAGE_WIDTH = 160;
const MAX_IMAGE_WIDTH = 1280;

export const ThreadNoteImage = Node.create({
  name: "threadNoteImage",
  group: "block",
  atom: true,
  selectable: true,
  draggable: true,
  markdownTokenName: "image",

  addAttributes() {
    return {
      src: {
        default: "",
      },
      alt: {
        default: "",
      },
      title: {
        default: "",
      },
      width: {
        default: null,
        parseHTML: (element: HTMLElement) => {
          const rawValue =
            element.getAttribute("data-image-width") ??
            element.querySelector("img")?.getAttribute("data-image-width") ??
            "";
          const parsed = Number.parseInt(rawValue, 10);
          return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
        },
        renderHTML: (attributes: Record<string, unknown>) => {
          const width = normalizeImageWidth(attributes.width);
          return width ? { "data-image-width": String(width) } : {};
        },
      },
      collapsed: {
        default: false,
        parseHTML: (element: HTMLElement) => {
          const value =
            element.getAttribute("data-image-collapsed") ??
            element.querySelector("img")?.getAttribute("data-image-collapsed") ??
            "";
          return value === "1" || value === "true";
        },
        renderHTML: (attributes: Record<string, unknown>) => {
          return attributes.collapsed ? { "data-image-collapsed": "1" } : {};
        },
      },
    };
  },

  parseHTML() {
    return [
      {
        tag: "figure[data-thread-note-image]",
        getAttrs: (element) => {
          if (!(element instanceof HTMLElement)) {
            return false;
          }

          const image = element.querySelector("img");
          if (!(image instanceof HTMLImageElement)) {
            return false;
          }

          const collapsedAttr =
            element.getAttribute("data-image-collapsed") ??
            image.getAttribute("data-image-collapsed") ??
            "";
          return {
            src: image.getAttribute("src") ?? "",
            alt: image.getAttribute("alt") ?? "",
            title: image.getAttribute("title") ?? "",
            width: normalizeImageWidth(
              element.getAttribute("data-image-width") ?? image.getAttribute("data-image-width")
            ),
            collapsed: collapsedAttr === "1" || collapsedAttr === "true",
          };
        },
      },
    ];
  },

  renderHTML({ HTMLAttributes }) {
    const width = normalizeImageWidth(HTMLAttributes.width);
    const collapsed = Boolean(HTMLAttributes.collapsed);
    const figureAttributes = mergeAttributes(
      { "data-thread-note-image": "true" },
      width ? { "data-image-width": String(width), style: `width:${width}px;max-width:100%;` } : {},
      collapsed ? { "data-image-collapsed": "1" } : {}
    );
    const imageAttributes = mergeAttributes({
      src: HTMLAttributes.src,
      alt: HTMLAttributes.alt,
      title: HTMLAttributes.title,
      "data-image-width": width ? String(width) : undefined,
      "data-image-collapsed": collapsed ? "1" : undefined,
      draggable: "false",
    });
    const caption =
      typeof HTMLAttributes.title === "string" && HTMLAttributes.title.trim().length > 0
        ? ["figcaption", {}, HTMLAttributes.title.trim()]
        : null;

    return ["figure", figureAttributes, ["img", imageAttributes], ...(caption ? [caption] : [])];
  },

  parseMarkdown(token: MarkdownToken, helpers: MarkdownParseHelpers) {
    const rendered = resolveRenderedThreadNoteImage(token.href || "");
    return helpers.createNode("threadNoteImage", {
      src: rendered.src,
      alt: token.text || "",
      title: token.title || "",
      width: rendered.width,
      collapsed: rendered.collapsed,
    });
  },

  renderMarkdown(node: JSONContent, _helpers: MarkdownRendererHelpers) {
    return buildThreadNoteMarkdownImage({
      src: `${node.attrs?.src ?? ""}`.trim(),
      alt: `${node.attrs?.alt ?? ""}`,
      title: `${node.attrs?.title ?? ""}`.trim(),
      width: normalizeImageWidth(node.attrs?.width) ?? undefined,
      collapsed: Boolean(node.attrs?.collapsed) || undefined,
    });
  },

  addNodeView() {
    return ReactNodeViewRenderer(ThreadNoteImageView);
  },

  addKeyboardShortcuts() {
    return {
      // Override ProseMirror's default Escape (which runs `selectParentNode`
      // and visually outdents the cursor when inside a nested list). We want
      // Escape to be a soft "exit" that keeps the caret at the same depth.
      Escape: ({ editor }) => {
        const { selection } = editor.state;
        if (
          selection instanceof NodeSelection &&
          selection.node.type.name === "threadNoteImage"
        ) {
          // If the image itself is selected, drop the selection right after
          // the image so the caret stays inside its containing block.
          const targetPos = selection.to;
          editor
            .chain()
            .command(({ tr, dispatch }) => {
              if (dispatch) {
                tr.setSelection(TextSelection.create(tr.doc, targetPos));
                dispatch(tr.scrollIntoView());
              }
              return true;
            })
            .focus()
            .run();
          return true;
        }

        // Consume Escape so prosemirror-commands' base keymap can't run
        // `selectParentNode` and bump the caret up an indentation level.
        return true;
      },
    };
  },
});

function ThreadNoteImageView({
  editor,
  getPos,
  node,
  selected,
  updateAttributes,
}: NodeViewProps) {
  const wrapperRef = useRef<HTMLDivElement | null>(null);
  const imageRef = useRef<HTMLImageElement | null>(null);
  const lastWidthRef = useRef<number | null>(null);
  const [dragWidth, setDragWidth] = useState<number | null>(null);
  const storedWidth = normalizeImageWidth(node.attrs.width);
  const width = dragWidth ?? storedWidth;
  const caption = `${node.attrs.title ?? ""}`.trim();
  const altText = `${node.attrs.alt ?? ""}`.trim();
  const isCollapsed = Boolean(node.attrs.collapsed);
  const toggleCollapsed = useCallback(() => {
    updateAttributes({ collapsed: !isCollapsed });
  }, [isCollapsed, updateAttributes]);
  const collapsedLabel = caption || altText || "Image";

  useEffect(() => {
    lastWidthRef.current = storedWidth;
    setDragWidth(null);
  }, [storedWidth, node.attrs.src]);

  const selectImageNode = useCallback(() => {
    const position = resolveNodePosition(getPos);
    if (typeof position !== "number") {
      return;
    }

    editor.chain().focus().setNodeSelection(position).run();
  }, [editor, getPos]);

  const startResize = useCallback(
    (event: React.MouseEvent<HTMLButtonElement>) => {
      event.preventDefault();
      event.stopPropagation();
      selectImageNode();

      const imageRect = imageRef.current?.getBoundingClientRect();
      const shellRect = wrapperRef.current?.closest(".thread-note-editor-body")?.getBoundingClientRect();
      const startWidth = Math.round(
        dragWidth ?? storedWidth ?? imageRect?.width ?? MIN_IMAGE_WIDTH * 2
      );
      const maxWidth = Math.max(
        MIN_IMAGE_WIDTH,
        Math.min(MAX_IMAGE_WIDTH, Math.floor((shellRect?.width ?? window.innerWidth) - 28))
      );
      const startX = event.clientX;

      const handleMouseMove = (moveEvent: MouseEvent) => {
        const nextWidth = clampWidth(startWidth + (moveEvent.clientX - startX), maxWidth);
        lastWidthRef.current = nextWidth;
        setDragWidth(nextWidth);
      };

      const handleMouseUp = () => {
        const nextWidth = clampWidth(lastWidthRef.current ?? startWidth, maxWidth);
        updateAttributes({ width: nextWidth });
        lastWidthRef.current = nextWidth;
        setDragWidth(null);
        window.removeEventListener("mousemove", handleMouseMove);
        window.removeEventListener("mouseup", handleMouseUp);
      };

      window.addEventListener("mousemove", handleMouseMove);
      window.addEventListener("mouseup", handleMouseUp);
    },
    [dragWidth, selectImageNode, storedWidth, updateAttributes]
  );

  const figureStyle = useMemo<React.CSSProperties>(
    () => ({
      width: width ? `${width}px` : undefined,
      maxWidth: "100%",
    }),
    [width]
  );

  return (
    <NodeViewWrapper
      className={[
        "thread-note-image-node",
        selected ? "is-selected" : "",
        dragWidth ? "is-resizing" : "",
        isCollapsed ? "is-collapsed" : "",
      ]
        .filter(Boolean)
        .join(" ")}
      contentEditable={false}
    >
      <div ref={wrapperRef}>
        {isCollapsed ? (
          <button
            type="button"
            className="thread-note-image-collapsed-row"
            onClick={(event) => {
              event.preventDefault();
              event.stopPropagation();
              selectImageNode();
              toggleCollapsed();
            }}
            title="Expand image"
            aria-label={`Expand image: ${collapsedLabel}`}
          >
            <span className="thread-note-image-collapsed-glyph" aria-hidden="true">
              <svg viewBox="0 0 16 16">
                <rect x="2.25" y="3.25" width="11.5" height="9.5" rx="1.5" />
                <circle cx="6" cy="6.75" r="1" />
                <path d="M3 11.5l3.5-3 2.5 2.5 2-1.75 2 1.75" />
              </svg>
            </span>
            <span className="thread-note-image-collapsed-label">{collapsedLabel}</span>
            <span className="thread-note-image-collapsed-hint">Expand</span>
          </button>
        ) : (
          <figure
            className="thread-note-image-frame"
            style={figureStyle}
            onMouseDown={(event) => {
              event.preventDefault();
              selectImageNode();
            }}
            onDoubleClick={(event) => {
              event.preventDefault();
              event.stopPropagation();
              selectImageNode();
              window.dispatchEvent(
                new CustomEvent("openassist:thread-note-image-inspector-open")
              );
            }}
          >
            <img
              ref={imageRef}
              className="thread-note-image-media"
              src={`${node.attrs.src ?? ""}`}
              alt={`${node.attrs.alt ?? ""}`}
              title={caption}
              draggable={false}
            />
            {caption ? (
              <figcaption className="thread-note-image-caption">{caption}</figcaption>
            ) : null}
            <button
              type="button"
              className="thread-note-image-collapse-toggle"
              onClick={(event) => {
                event.preventDefault();
                event.stopPropagation();
                toggleCollapsed();
              }}
              aria-label="Collapse image"
              title="Collapse image"
            >
              <svg viewBox="0 0 16 16" aria-hidden="true">
                <path d="M3.5 8h9" />
              </svg>
            </button>
            {selected ? (
              <>
                <div className="thread-note-image-selection-ring" aria-hidden="true" />
                <button
                  type="button"
                  className="thread-note-image-resize-handle"
                  onMouseDown={startResize}
                  aria-label="Resize image"
                  title="Drag to resize"
                />
              </>
            ) : null}
          </figure>
        )}
      </div>
    </NodeViewWrapper>
  );
}

function resolveNodePosition(getPos: NodeViewProps["getPos"]): number | null {
  if (typeof getPos !== "function") {
    return null;
  }

  try {
    return getPos();
  } catch {
    return null;
  }
}

function normalizeImageWidth(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return Math.max(MIN_IMAGE_WIDTH, Math.min(MAX_IMAGE_WIDTH, Math.round(value)));
  }

  if (typeof value === "string" && value.trim().length > 0) {
    const parsed = Number.parseInt(value, 10);
    if (Number.isFinite(parsed) && parsed > 0) {
      return Math.max(MIN_IMAGE_WIDTH, Math.min(MAX_IMAGE_WIDTH, Math.round(parsed)));
    }
  }

  return null;
}

function clampWidth(width: number, maxWidth: number): number {
  return Math.max(MIN_IMAGE_WIDTH, Math.min(Math.round(width), maxWidth));
}
