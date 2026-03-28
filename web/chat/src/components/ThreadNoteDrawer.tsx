import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { EditorContent, useEditor, type Editor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import { Placeholder } from "@tiptap/extension-placeholder";
import { TableKit } from "@tiptap/extension-table";
import { TaskItem } from "@tiptap/extension-task-item";
import { TaskList } from "@tiptap/extension-task-list";
import { Markdown } from "@tiptap/markdown";
import type { ThreadNoteState } from "../types";

interface Props {
  state: ThreadNoteState | null;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}

interface SlashQueryState {
  query: string;
  replaceFrom: number;
  replaceTo: number;
}

interface SlashCommand {
  id: string;
  label: string;
  subtitle: string;
  run: (editor: Editor, range: SlashQueryState) => void;
}

const THREAD_NOTE_SAVE_DEBOUNCE_MS = 500;

const SLASH_COMMANDS: SlashCommand[] = [
  makeCommand("h1", "Heading 1", "Large section heading", (editor, range) => {
    editor
      .chain()
      .focus()
      .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
      .setNode("heading", { level: 1 })
      .run();
  }),
  makeCommand("h2", "Heading 2", "Medium section heading", (editor, range) => {
    editor
      .chain()
      .focus()
      .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
      .setNode("heading", { level: 2 })
      .run();
  }),
  makeCommand("h3", "Heading 3", "Small section heading", (editor, range) => {
    editor
      .chain()
      .focus()
      .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
      .setNode("heading", { level: 3 })
      .run();
  }),
  makeCommand("bullet", "Bullet List", "Start a bulleted list", (editor, range) => {
    editor
      .chain()
      .focus()
      .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
      .toggleBulletList()
      .run();
  }),
  makeCommand("numbered", "Numbered List", "Start a numbered list", (editor, range) => {
    editor
      .chain()
      .focus()
      .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
      .toggleOrderedList()
      .run();
  }),
  makeCommand("todo", "To-do Item", "Start a checklist row", (editor, range) => {
    editor
      .chain()
      .focus()
      .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
      .toggleTaskList()
      .run();
  }),
  makeCommand("quote", "Quote", "Add a quoted block", (editor, range) => {
    editor
      .chain()
      .focus()
      .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
      .toggleBlockquote()
      .run();
  }),
  makeCommand("code", "Code Block", "Insert a fenced code block", (editor, range) => {
    editor
      .chain()
      .focus()
      .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
      .setCodeBlock()
      .run();
  }),
  makeCommand("divider", "Divider", "Insert a section divider", (editor, range) => {
    editor
      .chain()
      .focus()
      .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
      .setHorizontalRule()
      .createParagraphNear()
      .run();
  }),
  makeCommand("table", "Table", "Insert a simple Markdown table", (editor, range) => {
    editor
      .chain()
      .focus()
      .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
      .insertTable({ rows: 3, cols: 2, withHeaderRow: true })
      .run();
  }),
];

export function ThreadNoteDrawer({ state, onDispatchCommand }: Props) {
  const threadId = state?.threadId ?? null;
  const isAvailable = Boolean(threadId && state?.canEdit);
  const isOpen = Boolean(state?.isOpen && isAvailable);
  const placeholderText =
    state?.placeholder || "Write your thread note. Type / for Markdown blocks.";
  const statusLabel = state?.isSaving
    ? "Saving..."
    : state?.lastSavedAtLabel || (state?.hasNote ? "Saved" : "Markdown ready");

  const handleToggleDrawer = useCallback(() => {
    if (!threadId) {
      return;
    }

    if (isOpen) {
      onDispatchCommand("save", { threadId });
    }

    onDispatchCommand("setOpen", {
      threadId,
      isOpen: !isOpen,
    });
  }, [isOpen, onDispatchCommand, threadId]);

  return (
    <div
      className={[
        "thread-note-layer",
        isAvailable ? "is-available" : "",
        isOpen ? "is-open" : "",
      ]
        .filter(Boolean)
        .join(" ")}
    >
      {isAvailable ? (
        <button
          className="thread-note-handle-hitbox"
          type="button"
          aria-label={isOpen ? "Close thread note" : "Open thread note"}
          aria-expanded={isOpen}
          onClick={handleToggleDrawer}
        >
          <span className="thread-note-handle-chevron" aria-hidden="true">
            {isOpen ? "›" : "‹"}
          </span>
        </button>
      ) : null}

      {isOpen && threadId ? (
        <ThreadNoteDrawerOpenContent
          key={threadId}
          state={state}
          threadId={threadId}
          placeholderText={placeholderText}
          statusLabel={statusLabel}
          onDispatchCommand={onDispatchCommand}
        />
      ) : null}
    </div>
  );
}

interface ThreadNoteDrawerOpenContentProps {
  state: ThreadNoteState | null;
  threadId: string;
  placeholderText: string;
  statusLabel: string;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}

function ThreadNoteDrawerOpenContent({
  state,
  threadId,
  placeholderText,
  statusLabel,
  onDispatchCommand,
}: ThreadNoteDrawerOpenContentProps) {
  const editorBodyRef = useRef<HTMLDivElement>(null);
  const isApplyingExternalContentRef = useRef(false);
  const openRef = useRef(false);
  const previousThreadIdRef = useRef<string | null>(null);
  const [draftText, setDraftText] = useState(normalizeLineEndings(state?.text ?? ""));
  const [hasLocalDirtyChanges, setHasLocalDirtyChanges] = useState(false);
  const [slashQuery, setSlashQuery] = useState<SlashQueryState | null>(null);
  const [selectedSlashIndex, setSelectedSlashIndex] = useState(0);
  const [menuPosition, setMenuPosition] = useState({ left: 20, top: 20 });
  const [isInTable, setIsInTable] = useState(false);

  const isOpen = Boolean(state?.isOpen && state?.canEdit);

  const editor = useEditor(
    {
      immediatelyRender: false,
      autofocus: false,
      content: normalizeLineEndings(state?.text ?? ""),
      contentType: "markdown",
      extensions: [
        StarterKit,
        Markdown,
        Placeholder.configure({
          placeholder: placeholderText,
          emptyEditorClass: "is-editor-empty",
        }),
        TableKit.configure({
          table: {
            resizable: true,
          },
        }),
        TaskList,
        TaskItem.configure({
          nested: true,
        }),
      ],
      editorProps: {
        attributes: {
          class: "thread-note-tiptap",
        },
      },
    },
    [threadId, placeholderText]
  );

  const filteredCommands = useMemo(() => {
    if (!slashQuery) {
      return SLASH_COMMANDS;
    }
    const query = slashQuery.query.trim().toLowerCase();
    if (!query) {
      return SLASH_COMMANDS;
    }
    return SLASH_COMMANDS.filter((command) =>
      command.id.startsWith(query) || command.label.toLowerCase().includes(query)
    );
  }, [slashQuery]);

  const refreshSlashQuery = useCallback(
    (activeEditor: Editor | null = editor) => {
      if (!activeEditor || !isOpen) {
        setSlashQuery(null);
        return;
      }

      const nextQuery = detectSlashQuery(activeEditor);
      setSlashQuery(nextQuery);
      setIsInTable(activeEditor.isActive("table"));

      if (nextQuery) {
        setMenuPosition(measureMenuPosition(activeEditor, editorBodyRef.current));
      }
    },
    [editor, isOpen]
  );

  const commitSave = useCallback(
    (nextText?: string) => {
      const normalized = normalizeLineEndings(
        nextText ?? editor?.getMarkdown() ?? draftText
      );
      if (!threadId) {
        return;
      }
      if (!hasLocalDirtyChanges && normalized === normalizeLineEndings(state?.text ?? "")) {
        return;
      }
      onDispatchCommand("save", {
        threadId,
        text: normalized,
      });
      setHasLocalDirtyChanges(false);
    },
    [draftText, editor, hasLocalDirtyChanges, onDispatchCommand, state?.text, threadId]
  );

  useEffect(() => {
    const externalText = normalizeLineEndings(state?.text ?? "");
    const threadChanged = threadId !== previousThreadIdRef.current;

    if (threadChanged) {
      previousThreadIdRef.current = threadId;
      setDraftText(externalText);
      setHasLocalDirtyChanges(false);
      setSlashQuery(null);
      setSelectedSlashIndex(0);
      setIsInTable(false);
    } else if (!hasLocalDirtyChanges && draftText !== externalText) {
      setDraftText(externalText);
    }

    if (!editor) {
      return;
    }

    if (!threadChanged && (hasLocalDirtyChanges || draftText === externalText)) {
      return;
    }

    isApplyingExternalContentRef.current = true;
    editor.commands.setContent(externalText, { contentType: "markdown" });
    isApplyingExternalContentRef.current = false;
    refreshSlashQuery(editor);
  }, [
    draftText,
    editor,
    hasLocalDirtyChanges,
    refreshSlashQuery,
    state?.text,
    threadId,
  ]);

  useEffect(() => {
    if (!editor) {
      return;
    }

    const handleUpdate = () => {
      if (isApplyingExternalContentRef.current) {
        return;
      }
      const nextText = normalizeLineEndings(editor.getMarkdown());
      setDraftText(nextText);
      setHasLocalDirtyChanges(true);
      if (threadId) {
        onDispatchCommand("updateDraft", {
          threadId,
          text: nextText,
        });
      }
      refreshSlashQuery(editor);
    };

    const handleSelectionChange = () => {
      refreshSlashQuery(editor);
    };

    const handleBlur = () => {
      commitSave(editor.getMarkdown());
      setSlashQuery(null);
      setIsInTable(editor.isActive("table"));
    };

    const handleFocus = () => {
      refreshSlashQuery(editor);
    };

    const handleScroll = () => {
      refreshSlashQuery(editor);
    };

    editor.on("update", handleUpdate);
    editor.on("selectionUpdate", handleSelectionChange);
    editor.on("blur", handleBlur);
    editor.on("focus", handleFocus);
    editor.view.dom.addEventListener("scroll", handleScroll, { passive: true });

    return () => {
      editor.off("update", handleUpdate);
      editor.off("selectionUpdate", handleSelectionChange);
      editor.off("blur", handleBlur);
      editor.off("focus", handleFocus);
      editor.view.dom.removeEventListener("scroll", handleScroll);
    };
  }, [commitSave, editor, onDispatchCommand, refreshSlashQuery, threadId]);

  useEffect(() => {
    if (!isOpen) {
      setSlashQuery(null);
      return;
    }

    if (!editor) {
      return;
    }

    if (!openRef.current) {
      window.requestAnimationFrame(() => {
        editor.chain().focus("end").run();
        refreshSlashQuery(editor);
      });
    }

    openRef.current = isOpen;
  }, [editor, isOpen, refreshSlashQuery]);

  useEffect(() => {
    if (selectedSlashIndex >= filteredCommands.length) {
      setSelectedSlashIndex(0);
    }
  }, [filteredCommands.length, selectedSlashIndex]);

  useEffect(() => {
    setSelectedSlashIndex(0);
  }, [slashQuery?.query]);

  useEffect(() => {
    if (!isOpen || !threadId || !hasLocalDirtyChanges) {
      return;
    }

    const timeout = window.setTimeout(() => {
      commitSave();
    }, THREAD_NOTE_SAVE_DEBOUNCE_MS);

    return () => window.clearTimeout(timeout);
  }, [commitSave, hasLocalDirtyChanges, isOpen, threadId]);

  const applySlashCommand = useCallback(
    (command: SlashCommand) => {
      if (!editor || !slashQuery) {
        return;
      }
      command.run(editor, slashQuery);
      setSlashQuery(null);
      window.requestAnimationFrame(() => {
        editor.chain().focus().run();
        refreshSlashQuery(editor);
      });
    },
    [editor, refreshSlashQuery, slashQuery]
  );

  const handleCloseDrawer = useCallback(() => {
    commitSave();
    editor?.commands.blur();
    setSlashQuery(null);
    onDispatchCommand("setOpen", {
      threadId,
      isOpen: false,
    });
  }, [commitSave, editor, onDispatchCommand, threadId]);

  const handleEditorKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLDivElement>) => {
      if (!slashQuery || filteredCommands.length === 0) {
        return;
      }

      if (event.key === "ArrowDown") {
        event.preventDefault();
        setSelectedSlashIndex((current) => (current + 1) % filteredCommands.length);
        return;
      }

      if (event.key === "ArrowUp") {
        event.preventDefault();
        setSelectedSlashIndex((current) =>
          (current - 1 + filteredCommands.length) % filteredCommands.length
        );
        return;
      }

      if (event.key === "Enter") {
        event.preventDefault();
        applySlashCommand(filteredCommands[selectedSlashIndex]);
        return;
      }

      if (event.key === "Escape") {
        event.preventDefault();
        setSlashQuery(null);
      }
    },
    [applySlashCommand, filteredCommands, selectedSlashIndex, slashQuery]
  );

  const runTableCommand = useCallback(
    (command: (activeEditor: Editor) => boolean) => {
      if (!editor) {
        return;
      }
      command(editor);
      window.requestAnimationFrame(() => {
        editor.chain().focus().run();
        refreshSlashQuery(editor);
      });
    },
    [editor, refreshSlashQuery]
  );

  return (
    <>
      <button
        className="thread-note-dismiss-scrim"
        type="button"
        aria-label="Close thread note"
        onClick={handleCloseDrawer}
      />

      <aside className="thread-note-drawer" aria-hidden={!isOpen}>
        <div className="thread-note-header">
          <div className="thread-note-header-copy">
            <span className="thread-note-eyebrow">Thread Note</span>
            <span className="thread-note-status">{statusLabel}</span>
          </div>

          <button
            className="thread-note-close"
            type="button"
            onClick={handleCloseDrawer}
          >
            Close
          </button>
        </div>

        <div className="thread-note-surface">
          <div className="thread-note-editor-shell">
            {isInTable && editor ? (
              <div className="thread-note-table-toolbar">
                <button
                  className="thread-note-table-action"
                  type="button"
                  disabled={!editor.can().addRowAfter()}
                  onMouseDown={(event) => {
                    event.preventDefault();
                    runTableCommand((activeEditor) => activeEditor.chain().focus().addRowAfter().run());
                  }}
                >
                  + Row
                </button>
                <button
                  className="thread-note-table-action"
                  type="button"
                  disabled={!editor.can().addColumnAfter()}
                  onMouseDown={(event) => {
                    event.preventDefault();
                    runTableCommand((activeEditor) =>
                      activeEditor.chain().focus().addColumnAfter().run()
                    );
                  }}
                >
                  + Column
                </button>
                <button
                  className="thread-note-table-action"
                  type="button"
                  disabled={!editor.can().deleteRow()}
                  onMouseDown={(event) => {
                    event.preventDefault();
                    runTableCommand((activeEditor) => activeEditor.chain().focus().deleteRow().run());
                  }}
                >
                  Delete Row
                </button>
                <button
                  className="thread-note-table-action"
                  type="button"
                  disabled={!editor.can().deleteColumn()}
                  onMouseDown={(event) => {
                    event.preventDefault();
                    runTableCommand((activeEditor) =>
                      activeEditor.chain().focus().deleteColumn().run()
                    );
                  }}
                >
                  Delete Column
                </button>
              </div>
            ) : null}

            <div
              ref={editorBodyRef}
              className="thread-note-editor-body"
              onKeyDown={handleEditorKeyDown}
            >
              {editor ? (
                <EditorContent editor={editor} className="thread-note-editor-content" />
              ) : (
                <div className="thread-note-editor-loading">{placeholderText}</div>
              )}

              {isOpen && slashQuery && filteredCommands.length > 0 ? (
                <div
                  className="thread-note-slash-menu"
                  style={{
                    left: `${menuPosition.left}px`,
                    top: `${menuPosition.top}px`,
                  }}
                >
                  {filteredCommands.map((command, index) => (
                    <button
                      key={command.id}
                      className={[
                        "thread-note-slash-option",
                        index === selectedSlashIndex ? "is-selected" : "",
                      ]
                        .filter(Boolean)
                        .join(" ")}
                      type="button"
                      onMouseDown={(event) => {
                        event.preventDefault();
                        applySlashCommand(command);
                      }}
                    >
                      <span className="thread-note-slash-option-label">
                        /{command.id}
                      </span>
                      <span className="thread-note-slash-option-copy">
                        {command.subtitle}
                      </span>
                    </button>
                  ))}
                </div>
              ) : null}
            </div>
          </div>
        </div>
      </aside>
    </>
  );
}

function makeCommand(
  id: string,
  label: string,
  subtitle: string,
  run: SlashCommand["run"]
): SlashCommand {
  return {
    id,
    label,
    subtitle,
    run,
  };
}

function normalizeLineEndings(value: string): string {
  return value.replace(/\r\n/g, "\n");
}

function detectSlashQuery(editor: Editor): SlashQueryState | null {
  const { from, empty, $from } = editor.state.selection;
  if (!empty || !$from.parent.isTextblock) {
    return null;
  }

  const parentText = $from.parent.textContent ?? "";
  const beforeCaret = parentText.slice(0, $from.parentOffset);
  const match = beforeCaret.match(/(?:^|\s)\/([a-z]*)$/i);
  if (!match) {
    return null;
  }

  const query = (match[1] ?? "").toLowerCase();
  const slashWithQuery = `/${query}`;
  const replaceStartInParent = beforeCaret.lastIndexOf(slashWithQuery);
  if (replaceStartInParent < 0) {
    return null;
  }

  return {
    query,
    replaceFrom: $from.start() + replaceStartInParent,
    replaceTo: from,
  };
}

function measureMenuPosition(
  editor: Editor,
  container: HTMLDivElement | null
): { left: number; top: number } {
  if (!container) {
    return { left: 20, top: 20 };
  }

  const coords = editor.view.coordsAtPos(editor.state.selection.from);
  const containerRect = container.getBoundingClientRect();
  const left = clamp(coords.left - containerRect.left + 10, 16, containerRect.width - 280);
  const top = clamp(coords.bottom - containerRect.top + 12, 16, containerRect.height - 220);

  return {
    left,
    top,
  };
}

function clamp(value: number, min: number, max: number): number {
  if (max <= min) {
    return min;
  }
  return Math.min(Math.max(value, min), max);
}
