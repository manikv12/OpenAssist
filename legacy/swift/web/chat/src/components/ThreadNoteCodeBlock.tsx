import CodeBlockLowlight from "@tiptap/extension-code-block-lowlight";
import {
  NodeViewContent,
  NodeViewWrapper,
  ReactNodeViewRenderer,
  type NodeViewProps,
} from "@tiptap/react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { MermaidDiagram } from "./MermaidDiagram";
import {
  detectMermaidTemplateType,
  isMermaidLanguage,
  normalizeMermaidSource,
} from "./mermaidUtils";
import { MERMAID_TEMPLATE_TYPES } from "./threadNoteMermaidTemplates";

export const ThreadNoteCodeBlock = CodeBlockLowlight.extend({
  addNodeView() {
    return ReactNodeViewRenderer(ThreadNoteCodeBlockView);
  },
});

function ThreadNoteCodeBlockView({
  deleteNode,
  editor,
  getPos,
  node,
}: NodeViewProps) {
  const language = `${node.attrs.language ?? ""}`.trim();
  const isMermaid = isMermaidLanguage(language);
  const normalizedMermaidSource = useMemo(
    () => normalizeMermaidSource(language || "mermaid", node.textContent ?? ""),
    [language, node.textContent]
  );
  const mermaidType = useMemo(
    () => detectMermaidTemplateType(normalizedMermaidSource),
    [normalizedMermaidSource]
  );
  const mermaidTypeLabel = useMemo(
    () =>
      mermaidType
        ? MERMAID_TEMPLATE_TYPES.find((option) => option.type === mermaidType)?.label ??
          "Mermaid"
        : "Mermaid",
    [mermaidType]
  );
  const [isEditingMermaid, setIsEditingMermaid] = useState(false);

  useEffect(() => {
    if (!isMermaid) {
      setIsEditingMermaid(false);
      return;
    }

    const syncEditingState = () => {
      const position = resolveNodePosition(getPos);
      if (typeof position !== "number") {
        return;
      }

      const contentStart = position + 1;
      const contentEnd = position + node.nodeSize - 1;
      const { from, to } = editor.state.selection;
      const nextIsEditing =
        editor.isFocused && from >= contentStart && to <= contentEnd;
      setIsEditingMermaid(nextIsEditing);
    };

    syncEditingState();
    editor.on("selectionUpdate", syncEditingState);
    editor.on("focus", syncEditingState);
    editor.on("blur", syncEditingState);

    return () => {
      editor.off("selectionUpdate", syncEditingState);
      editor.off("focus", syncEditingState);
      editor.off("blur", syncEditingState);
    };
  }, [editor, getPos, isMermaid, node.nodeSize]);

  const focusMermaidEditor = useCallback(() => {
    const position = resolveNodePosition(getPos);
    if (typeof position !== "number") {
      return;
    }

    const contentStart = position + 1;
    const contentEnd = Math.max(contentStart, position + node.nodeSize - 1);
    editor.chain().focus().setTextSelection(contentEnd).run();
  }, [editor, getPos, node.nodeSize]);

  if (!isMermaid) {
    return (
      <NodeViewWrapper className="thread-note-code-block-node">
        <pre className="thread-note-code-block-surface">
          <NodeViewContent
            as="code"
            className={[
              "thread-note-code-block-content",
              language ? `language-${language}` : "",
            ]
              .filter(Boolean)
              .join(" ")}
          />
        </pre>
      </NodeViewWrapper>
    );
  }

  return (
    <NodeViewWrapper
      className={[
        "thread-note-code-block-node",
        "is-mermaid",
        isEditingMermaid ? "is-editing" : "is-previewing",
      ]
        .filter(Boolean)
        .join(" ")}
    >
      {!isEditingMermaid ? (
        <div
          className="thread-note-mermaid-preview-shell"
          contentEditable={false}
          onDoubleClick={(event) => {
            event.preventDefault();
            event.stopPropagation();
            focusMermaidEditor();
          }}
        >
          <div className="thread-note-mermaid-preview-toolbar">
            <div className="thread-note-mermaid-preview-copy">
              <span className="thread-note-mermaid-preview-badge">
                {mermaidTypeLabel}
              </span>
              <span className="thread-note-mermaid-preview-hint">
                Click edit to change the Mermaid text.
              </span>
            </div>
            <div className="thread-note-mermaid-preview-actions" contentEditable={false}>
              <button
                type="button"
                className="thread-note-mermaid-preview-action"
                onMouseDown={(event) => {
                  event.preventDefault();
                  focusMermaidEditor();
                }}
              >
                Edit
              </button>
              <button
                type="button"
                className="thread-note-mermaid-preview-action is-danger is-icon-only"
                aria-label="Delete Mermaid block"
                title="Delete Mermaid block"
                onMouseDown={(event) => {
                  event.preventDefault();
                  event.stopPropagation();
                  deleteNode();
                }}
              >
                <TrashIcon />
              </button>
            </div>
          </div>
          <MermaidDiagram
            code={normalizedMermaidSource}
            showViewerHint={false}
            displayMode="noteCompact"
          />
        </div>
      ) : (
        <div className="thread-note-mermaid-editor-toolbar" contentEditable={false}>
          <div className="thread-note-mermaid-preview-copy">
            <span className="thread-note-mermaid-preview-badge">
              {mermaidTypeLabel}
            </span>
            <span className="thread-note-mermaid-preview-hint">
              Type `/` here for Mermaid helpers.
            </span>
          </div>
          <div className="thread-note-mermaid-preview-actions" contentEditable={false}>
            <button
              type="button"
              className="thread-note-mermaid-preview-action is-danger is-icon-only"
              aria-label="Delete Mermaid block"
              title="Delete Mermaid block"
              onMouseDown={(event) => {
                event.preventDefault();
                event.stopPropagation();
                deleteNode();
              }}
            >
              <TrashIcon />
            </button>
          </div>
        </div>
      )}

      <pre
        className={[
          "thread-note-code-block-surface",
          "thread-note-mermaid-editor-surface",
          !isEditingMermaid ? "is-hidden" : "",
        ]
          .filter(Boolean)
          .join(" ")}
      >
        <NodeViewContent
          as="code"
          className={[
            "thread-note-code-block-content",
            "thread-note-mermaid-editor-content",
            language ? `language-${language}` : "",
          ]
            .filter(Boolean)
            .join(" ")}
        />
      </pre>
    </NodeViewWrapper>
  );
}

function resolveNodePosition(
  getPos: NodeViewProps["getPos"]
): number | null {
  if (typeof getPos !== "function") {
    return null;
  }

  try {
    return getPos();
  } catch {
    return null;
  }
}

function TrashIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true" focusable="false">
      <path
        d="M6 2.75h4a1 1 0 0 1 1 1V4h2.25a.75.75 0 0 1 0 1.5h-.58l-.55 7.08A1.75 1.75 0 0 1 10.37 14H5.63a1.75 1.75 0 0 1-1.74-1.42L3.33 5.5h-.58a.75.75 0 0 1 0-1.5H5v-.25a1 1 0 0 1 1-1ZM9.5 4v-.25a.25.25 0 0 0-.25-.25h-2.5a.25.25 0 0 0-.25.25V4h3Zm-3.62 8.47a.25.25 0 0 0 .25.22h4.74a.25.25 0 0 0 .25-.22l.54-6.97H5.34l.54 6.97ZM6.75 7a.75.75 0 0 1 .75.75v2.5a.75.75 0 0 1-1.5 0v-2.5A.75.75 0 0 1 6.75 7Zm2.5 0a.75.75 0 0 1 .75.75v2.5a.75.75 0 0 1-1.5 0v-2.5A.75.75 0 0 1 9.25 7Z"
        fill="currentColor"
      />
    </svg>
  );
}
