import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type RefObject,
} from "react";
import { EditorContent, useEditor, type Editor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import { Placeholder } from "@tiptap/extension-placeholder";
import { TableKit } from "@tiptap/extension-table";
import { TaskItem } from "@tiptap/extension-task-item";
import { TaskList } from "@tiptap/extension-task-list";
import { Markdown } from "@tiptap/markdown";
import type { ResolvedPos } from "@tiptap/pm/model";
import { all, createLowlight } from "lowlight";
import { ThreadNoteCodeBlock } from "./ThreadNoteCodeBlock";
import { ThreadNoteCollapsibleHeading } from "./ThreadNoteCollapsibleHeading";
import { MarkdownContent } from "./MarkdownContent";
import {
  detectMermaidTemplateType,
  isMermaidLanguage,
  normalizeMermaidSource,
} from "./mermaidUtils";
import {
  mermaidSnippetsForType,
  type MermaidSnippetDefinition,
} from "./threadNoteMermaidSnippets";
import {
  MERMAID_TEMPLATE_TYPES,
  mermaidTemplatesForType,
  type MermaidTemplateDefinition,
  type MermaidTemplateType,
} from "./threadNoteMermaidTemplates";
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

type SlashCommandGroupTone =
  | "mermaid"
  | "flow"
  | "structure"
  | "insight"
  | "heading"
  | "list"
  | "block"
  | "detail";

interface SlashCommandGroupMeta {
  groupId: string;
  groupLabel: string;
  groupTone: SlashCommandGroupTone;
  groupOrder: number;
  searchKeywords?: string[];
}

interface SlashCommand {
  id: string;
  label: string;
  subtitle: string;
  groupId: string;
  groupLabel: string;
  groupTone: SlashCommandGroupTone;
  groupOrder: number;
  searchKeywords?: string[];
  run: (editor: Editor, range: SlashQueryState) => void;
}

interface SlashCommandGroup {
  id: string;
  label: string;
  tone: SlashCommandGroupTone;
  order: number;
  commands: SlashCommand[];
}

interface MermaidTemplatePickerState {
  insertAt: number;
  step: "type" | "template";
  type: MermaidTemplateType | null;
  canGoBack: boolean;
}

interface ThreadNoteMenuPosition {
  left: number;
  top: number | null;
  bottom: number | null;
  maxHeight: number;
}

type MarkdownLineTag =
  | "paragraph"
  | "heading1"
  | "heading2"
  | "heading3"
  | "bullet"
  | "numbered"
  | "todo"
  | "quote"
  | "code";

type MarkdownInsertAction = "section" | "divider" | "table";

type MarkdownTagGroupId = "structure" | "lists" | "blocks";

interface MarkdownTagGroupDefinition {
  id: MarkdownTagGroupId;
  label: string;
}

interface MarkdownLineTagOption {
  id: MarkdownLineTag;
  token: string;
  label: string;
  description: string;
  groupId: MarkdownTagGroupId;
}

interface MarkdownInsertOption {
  id: MarkdownInsertAction;
  token: string;
  label: string;
  description: string;
}

interface HeadingTagEditorState {
  selectionPos: number;
  insertAt: number;
  tag: MarkdownLineTag;
  left: number;
  top: number;
}

interface NoteSelectionState {
  text: string;
  from: number;
  to: number;
}

interface MermaidEditingContext {
  type: MermaidTemplateType | null;
  typeLabel: string;
}

interface SummaryTarget {
  kind: "selection" | "whole";
  from?: number;
  to?: number;
}

interface DeleteConfirmationState {
  noteId: string;
  title: string;
}

interface ThreadNoteSourceSection {
  source: NonNullable<ThreadNoteState["availableSources"]>[number];
  allNotes: ThreadNoteState["notes"];
  visibleNotes: ThreadNoteState["notes"];
}

const THREAD_NOTE_SAVE_DEBOUNCE_MS = 500;
const DEFAULT_THREAD_NOTE_MENU_POSITION: ThreadNoteMenuPosition = {
  left: 16,
  top: 16,
  bottom: null,
  maxHeight: 320,
};

function noteSourceKey(ownerKind: string, ownerId: string): string {
  return `${ownerKind}:${ownerId}`;
}

function noteSourceLabelForOwner(ownerKind?: string | null): string {
  return ownerKind === "project" ? "Project notes" : "Thread notes";
}
const HEADING_GROUP_META: SlashCommandGroupMeta = {
  groupId: "headings",
  groupLabel: "Headings",
  groupTone: "heading",
  groupOrder: 10,
  searchKeywords: ["title", "section"],
};
const LIST_GROUP_META: SlashCommandGroupMeta = {
  groupId: "lists",
  groupLabel: "Lists",
  groupTone: "list",
  groupOrder: 11,
  searchKeywords: ["bullets", "checklist", "todo"],
};
const BLOCK_GROUP_META: SlashCommandGroupMeta = {
  groupId: "blocks",
  groupLabel: "Blocks",
  groupTone: "block",
  groupOrder: 12,
  searchKeywords: ["quote", "code", "divider", "table"],
};

const MARKDOWN_TAG_GROUPS: MarkdownTagGroupDefinition[] = [
  { id: "structure", label: "Line styles" },
  { id: "lists", label: "Lists" },
  { id: "blocks", label: "Blocks" },
];

const MARKDOWN_LINE_TAG_OPTIONS: MarkdownLineTagOption[] = [
  {
    id: "paragraph",
    token: "Aa",
    label: "Text",
    description: "Plain paragraph",
    groupId: "structure",
  },
  {
    id: "heading1",
    token: "#",
    label: "Title",
    description: "Large heading",
    groupId: "structure",
  },
  {
    id: "heading2",
    token: "##",
    label: "Section",
    description: "Collapsible section heading",
    groupId: "structure",
  },
  {
    id: "heading3",
    token: "###",
    label: "Subsection",
    description: "Smaller heading",
    groupId: "structure",
  },
  {
    id: "bullet",
    token: "-",
    label: "Bullet list",
    description: "Simple bullet row",
    groupId: "lists",
  },
  {
    id: "numbered",
    token: "1.",
    label: "Numbered list",
    description: "Ordered steps",
    groupId: "lists",
  },
  {
    id: "todo",
    token: "[ ]",
    label: "Checklist",
    description: "Task row",
    groupId: "lists",
  },
  {
    id: "quote",
    token: ">",
    label: "Quote",
    description: "Quoted block",
    groupId: "blocks",
  },
  {
    id: "code",
    token: "```",
    label: "Code block",
    description: "Code or Mermaid block",
    groupId: "blocks",
  },
];

const MARKDOWN_INSERT_OPTIONS: MarkdownInsertOption[] = [
  {
    id: "section",
    token: "+ ##",
    label: "New section",
    description: "Insert a collapsible section below",
  },
  {
    id: "divider",
    token: "---",
    label: "Divider",
    description: "Add a visual break",
  },
  {
    id: "table",
    token: "| |",
    label: "Table",
    description: "Insert a simple table",
  },
];

const MARKDOWN_LINE_TAG_OPTION_BY_ID = new Map(
  MARKDOWN_LINE_TAG_OPTIONS.map((option) => [option.id, option])
);

const threadNoteLowlight = createLowlight(all);
threadNoteLowlight.register("mermaid", mermaidHighlightGrammar);
threadNoteLowlight.registerAlias({
  mermaid: ["mmd"],
});

const BASE_SLASH_COMMANDS: SlashCommand[] = [
  makeCommand(
    "section",
    "Collapsible Section",
    "Insert a heading with notes underneath",
    (editor, range) => {
      insertCollapsibleSection(editor, range, 2);
    },
    HEADING_GROUP_META
  ),
  makeCommand(
    "h1",
    "Heading 1",
    "Large section heading",
    (editor, range) => {
      editor
        .chain()
        .focus()
        .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
        .setNode("heading", { level: 1 })
        .run();
    },
    HEADING_GROUP_META
  ),
  makeCommand(
    "h2",
    "Heading 2",
    "Medium section heading",
    (editor, range) => {
      editor
        .chain()
        .focus()
        .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
        .setNode("heading", { level: 2 })
        .run();
    },
    HEADING_GROUP_META
  ),
  makeCommand(
    "h3",
    "Heading 3",
    "Small section heading",
    (editor, range) => {
      editor
        .chain()
        .focus()
        .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
        .setNode("heading", { level: 3 })
        .run();
    },
    HEADING_GROUP_META
  ),
  makeCommand(
    "bullet",
    "Bullet List",
    "Start a bulleted list",
    (editor, range) => {
      editor
        .chain()
        .focus()
        .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
        .toggleBulletList()
        .run();
    },
    LIST_GROUP_META
  ),
  makeCommand(
    "numbered",
    "Numbered List",
    "Start a numbered list",
    (editor, range) => {
      editor
        .chain()
        .focus()
        .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
        .toggleOrderedList()
        .run();
    },
    LIST_GROUP_META
  ),
  makeCommand(
    "todo",
    "To-do Item",
    "Start a checklist row",
    (editor, range) => {
      editor
        .chain()
        .focus()
        .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
        .toggleTaskList()
        .run();
    },
    LIST_GROUP_META
  ),
  makeCommand(
    "quote",
    "Quote",
    "Add a quoted block",
    (editor, range) => {
      editor
        .chain()
        .focus()
        .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
        .toggleBlockquote()
        .run();
    },
    BLOCK_GROUP_META
  ),
  makeCommand(
    "code",
    "Code Block",
    "Insert a fenced code block",
    (editor, range) => {
      editor
        .chain()
        .focus()
        .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
        .setCodeBlock()
        .run();
    },
    BLOCK_GROUP_META
  ),
  makeCommand(
    "divider",
    "Divider",
    "Insert a section divider",
    (editor, range) => {
      editor
        .chain()
        .focus()
        .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
        .setHorizontalRule()
        .createParagraphNear()
        .run();
    },
    BLOCK_GROUP_META
  ),
  makeCommand(
    "table",
    "Table",
    "Insert a simple Markdown table",
    (editor, range) => {
      editor
        .chain()
        .focus()
        .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
        .insertTable({ rows: 3, cols: 2, withHeaderRow: true })
        .run();
    },
    BLOCK_GROUP_META
  ),
];

function buildMermaidSlashCommands(
  openMermaidTemplatePicker: (
    editor: Editor,
    range: SlashQueryState,
    type: MermaidTemplateType | null
  ) => void
): SlashCommand[] {
  return [
    makeCommand(
      "mermaid",
      "Mermaid Diagram",
      "Pick a Mermaid diagram type and starter template",
      (editor, range) => openMermaidTemplatePicker(editor, range, null),
      mermaidStarterGroupMeta(null)
    ),
    ...MERMAID_TEMPLATE_TYPES.map((option) =>
      makeCommand(
        option.commandId,
        `Mermaid ${option.label}`,
        `Insert a ${option.label.toLowerCase()} starter template`,
        (editor, range) => openMermaidTemplatePicker(editor, range, option.type),
        mermaidStarterGroupMeta(option.type)
      )
    ),
  ];
}

export function ThreadNoteDrawer({ state, onDispatchCommand }: Props) {
  const threadId = state?.threadId ?? null;
  const ownerKind = state?.ownerKind ?? null;
  const ownerId = state?.ownerId ?? null;
  const isProjectFullScreen = state?.presentation === "projectFullScreen";
  const isAvailable = Boolean(ownerKind && ownerId && state?.canEdit);
  const isOpen = Boolean(state?.isOpen && isAvailable);
  const layerRef = useRef<HTMLDivElement | null>(null);
  const placeholderText =
    state?.placeholder || "Write your thread note. Type / for Markdown blocks.";
  const statusLabel = state?.isSaving ? "Saving..." : state?.lastSavedAtLabel || "";

  const handleToggleDrawer = useCallback(() => {
    if (!ownerKind || !ownerId) {
      return;
    }

    if (isOpen) {
      onDispatchCommand("save", {
        ...(threadId ? { threadId } : {}),
        ownerKind,
        ownerId,
        noteId: state?.selectedNoteId ?? null,
      });
    }

    onDispatchCommand("setOpen", {
      ...(threadId ? { threadId } : {}),
      ownerKind,
      ownerId,
      isOpen: !isOpen,
    });
  }, [isOpen, onDispatchCommand, ownerId, ownerKind, state?.selectedNoteId, threadId]);

  return (
    <div
      ref={layerRef}
      className={[
        "thread-note-layer",
        isAvailable ? "is-available" : "",
        isOpen ? "is-open" : "",
        state?.isExpanded ? "is-expanded" : "",
        isProjectFullScreen ? "is-project-fullscreen" : "",
      ]
        .filter(Boolean)
        .join(" ")}
    >
      {isAvailable && !isOpen && !isProjectFullScreen ? (
        <button
          className="thread-note-handle-hitbox"
          type="button"
          aria-label="Open thread note"
          aria-expanded={false}
          onClick={handleToggleDrawer}
        >
          <span className="thread-note-handle-chevron" aria-hidden="true">
            ‹
          </span>
        </button>
      ) : null}

      {isOpen && ownerKind && ownerId ? (
        <ThreadNoteDrawerOpenContent
          key={`${ownerKind}:${ownerId}:${threadId ?? "no-thread"}`}
          state={state}
          threadId={threadId}
          ownerKind={ownerKind}
          ownerId={ownerId}
          isProjectFullScreen={isProjectFullScreen}
          layerRef={layerRef}
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
  threadId: string | null;
  ownerKind: string;
  ownerId: string;
  isProjectFullScreen: boolean;
  layerRef: RefObject<HTMLDivElement | null>;
  placeholderText: string;
  statusLabel: string;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}

function ThreadNoteDrawerOpenContent({
  state,
  threadId,
  ownerKind,
  ownerId,
  isProjectFullScreen,
  layerRef,
  placeholderText,
  statusLabel,
  onDispatchCommand,
}: ThreadNoteDrawerOpenContentProps) {
  const noteId = state?.selectedNoteId ?? null;
  const drawerRef = useRef<HTMLElement | null>(null);
  const floatingLayerRef = useRef<HTMLDivElement | null>(null);
  const editorBodyRef = useRef<HTMLDivElement>(null);
  const headingTagSearchRef = useRef<HTMLInputElement | null>(null);
  const selectorButtonRef = useRef<HTMLButtonElement | null>(null);
  const selectorSearchInputRef = useRef<HTMLInputElement | null>(null);
  const renameInputRef = useRef<HTMLInputElement | null>(null);
  const isApplyingExternalContentRef = useRef(false);
  const openRef = useRef(false);
  const previousNoteKeyRef = useRef<string | null>(null);
  const slashQueryRef = useRef<SlashQueryState | null>(null);
  const filteredCommandsRef = useRef<SlashCommand[]>(BASE_SLASH_COMMANDS);
  const selectedSlashIndexRef = useRef(0);
  const mermaidPickerStateRef = useRef<MermaidTemplatePickerState | null>(null);
  const selectedMermaidIndexRef = useRef(0);
  const summaryTargetRef = useRef<SummaryTarget | null>(null);
  const [draftText, setDraftText] = useState(normalizeLineEndings(state?.text ?? ""));
  const [hasLocalDirtyChanges, setHasLocalDirtyChanges] = useState(false);
  const [isSelectorOpen, setIsSelectorOpen] = useState(false);
  const [selectorFilter, setSelectorFilter] = useState("");
  const [isRenamingTitle, setIsRenamingTitle] = useState(false);
  const [renameTitleDraft, setRenameTitleDraft] = useState(
    normalizeThreadNoteTitle(state?.selectedNoteTitle)
  );
  const [slashQuery, setSlashQuery] = useState<SlashQueryState | null>(null);
  const [selectedSlashIndex, setSelectedSlashIndex] = useState(0);
  const [expandedSlashGroups, setExpandedSlashGroups] = useState<Record<string, boolean>>({});
  const [mermaidPicker, setMermaidPicker] = useState<MermaidTemplatePickerState | null>(null);
  const [selectedMermaidIndex, setSelectedMermaidIndex] = useState(0);
  const [mermaidEditingContext, setMermaidEditingContext] =
    useState<MermaidEditingContext | null>(null);
  const [menuPosition, setMenuPosition] = useState<ThreadNoteMenuPosition>(
    DEFAULT_THREAD_NOTE_MENU_POSITION
  );
  const [isInTable, setIsInTable] = useState(false);
  const [noteSelection, setNoteSelection] = useState<NoteSelectionState | null>(null);
  const [deleteConfirmation, setDeleteConfirmation] = useState<DeleteConfirmationState | null>(null);
  const [organizeConfirmation, setOrganizeConfirmation] = useState<"whole" | "selection" | null>(
    null
  );
  const [headingTagEditor, setHeadingTagEditor] = useState<HeadingTagEditorState | null>(null);
  const [headingTagSearch, setHeadingTagSearch] = useState("");
  const [chartStyleInstruction, setChartStyleInstruction] = useState("");
  const [isChartDraftModalDismissed, setIsChartDraftModalDismissed] = useState(false);

  const isOpen = Boolean(state?.isOpen && state?.canEdit);
  const noteOwnerKey = `${ownerKind}:${ownerId}`;
  const noteKey = `${noteOwnerKey}:${noteId ?? "none"}`;
  const canCloseDrawer = !isProjectFullScreen;
  const isExpanded = Boolean(state?.isExpanded);
  const aiDraftPreview = state?.aiDraftPreview ?? null;
  const aiDraftMode = state?.aiDraftMode ?? aiDraftPreview?.mode ?? null;
  const hasActiveAIDraft = Boolean(aiDraftPreview || (state?.isGeneratingAIDraft && aiDraftMode));
  const activeAIDraftMode = aiDraftPreview?.mode ?? aiDraftMode ?? "organize";
  const activeAIDraftSourceKind =
    aiDraftPreview?.sourceKind ??
    (activeAIDraftMode === "chart" ? "chatSelection" : noteSelection?.text ? "selection" : "whole");
  const isChartDraft = activeAIDraftMode === "chart";
  const hasActiveChartDraft = isChartDraft && hasActiveAIDraft;
  const isAIDraftError = Boolean(aiDraftPreview?.isError);
  const showAIDraftModal = isChartDraft
    ? hasActiveChartDraft && !isChartDraftModalDismissed
    : hasActiveAIDraft;
  const showChartDraftStatusCard = hasActiveChartDraft && isChartDraftModalDismissed;
  const shouldBlockDrawerEscape = hasActiveAIDraft && activeAIDraftMode !== "chart";
  const chartDraftStatusTitle = !aiDraftPreview
    ? "Chart generation is running"
    : aiDraftPreview.isError
      ? "Chart generation needs attention"
      : "Chart draft is ready";
  const chartDraftStatusDetail = !aiDraftPreview
    ? "You can keep chatting and open this note again later to check the result."
    : aiDraftPreview.isError
      ? "Open the chart panel to see the error or try again."
      : "Open the chart panel to review it, regenerate it, or add it to the note.";
  const previousDrawerOpenRef = useRef(isOpen);
  const previousChartDraftActiveRef = useRef(hasActiveChartDraft);

  const editor = useEditor(
    {
      immediatelyRender: false,
      autofocus: false,
      content: normalizeLineEndings(state?.text ?? ""),
      contentType: "markdown",
      extensions: [
        StarterKit.configure({
          codeBlock: false,
          heading: false,
        }),
        ThreadNoteCollapsibleHeading.configure({
          levels: [1, 2, 3],
        }),
        ThreadNoteCodeBlock.configure({
          lowlight: threadNoteLowlight,
        }),
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
    [placeholderText]
  );

  const refreshSlashQuery = useCallback(
    (activeEditor: Editor | null = editor) => {
      if (!activeEditor || !isOpen || !noteId) {
        setSlashQuery(null);
        setMermaidEditingContext(null);
        setNoteSelection(null);
        return;
      }

      const nextQuery = detectSlashQuery(activeEditor);
      const nextMermaidEditingContext = detectMermaidEditingContext(activeEditor);
      setSlashQuery(nextQuery);
      setMermaidEditingContext(nextMermaidEditingContext);
      if (nextQuery || nextMermaidEditingContext) {
        setHeadingTagEditor(null);
      }
      setIsInTable(activeEditor.isActive("table"));

      const { from, to, empty } = activeEditor.state.selection;
      if (!empty && to > from) {
        const selectedText = activeEditor.state.doc
          .textBetween(from, to, "\n\n")
          .trim();
        if (selectedText) {
          setNoteSelection({ text: selectedText, from, to });
        } else {
          setNoteSelection(null);
        }
      } else {
        setNoteSelection(null);
      }

      if (nextQuery || mermaidPickerStateRef.current) {
        setMenuPosition(
          measureMenuPosition(activeEditor, editorBodyRef.current, layerRef.current)
        );
      }
    },
    [editor, isOpen, layerRef, noteId]
  );

  const openMermaidTemplatePicker = useCallback(
    (activeEditor: Editor, range: SlashQueryState, type: MermaidTemplateType | null) => {
      activeEditor
        .chain()
        .focus()
        .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
        .run();
      const nextPicker: MermaidTemplatePickerState = {
        insertAt: range.replaceFrom,
        step: type ? "template" : "type",
        type,
        canGoBack: false,
      };
      setSlashQuery(null);
      setSelectedSlashIndex(0);
      setMermaidPicker(nextPicker);
      setSelectedMermaidIndex(0);
      window.requestAnimationFrame(() => {
        setMenuPosition(
          measureMenuPosition(activeEditor, editorBodyRef.current, layerRef.current)
        );
        refreshSlashQuery(activeEditor);
      });
    },
    [layerRef, refreshSlashQuery]
  );

  const slashCommands = useMemo(
    () => [...buildMermaidSlashCommands(openMermaidTemplatePicker), ...BASE_SLASH_COMMANDS],
    [openMermaidTemplatePicker]
  );

  const mermaidSnippetCommands = useMemo(
    () =>
      buildMermaidSnippetSlashCommands(
        mermaidEditingContext,
        (activeEditor, range, snippet) => {
          insertMermaidSnippet(activeEditor, range, snippet);
        }
      ),
    [mermaidEditingContext]
  );

  const activeSlashCommands = mermaidEditingContext
    ? mermaidSnippetCommands
    : slashCommands;

  const matchingSlashCommands = useMemo(() => {
    if (!slashQuery) {
      return activeSlashCommands;
    }
    const query = slashQuery.query.trim().toLowerCase();
    if (!query) {
      return activeSlashCommands;
    }
    return activeSlashCommands.filter((command) => matchesSlashCommand(command, query));
  }, [activeSlashCommands, slashQuery]);

  const groupedSlashCommands = useMemo(
    () => groupSlashCommands(matchingSlashCommands),
    [matchingSlashCommands]
  );
  const slashSearchText = slashQuery?.query.trim().toLowerCase() ?? "";
  const isSearchingSlashCommands = slashSearchText.length > 0;
  const visibleSlashCommands = useMemo(
    () =>
      groupedSlashCommands.flatMap((group) =>
        isSearchingSlashCommands || expandedSlashGroups[group.id] ? group.commands : []
      ),
    [expandedSlashGroups, groupedSlashCommands, isSearchingSlashCommands]
  );
  const slashMenuSessionKey = slashQuery
    ? `${slashQuery.replaceFrom}:${mermaidEditingContext?.type ?? "note"}`
    : null;

  const mermaidPickerItems = useMemo(() => {
    if (!mermaidPicker) {
      return [];
    }

    if (mermaidPicker.step === "type") {
      return MERMAID_TEMPLATE_TYPES.map((option) => ({
        id: option.commandId,
        title: option.label,
        description: option.description,
        type: option.type,
      }));
    }

    if (!mermaidPicker.type) {
      return [];
    }

    return mermaidTemplatesForType(mermaidPicker.type).map((template) => ({
      id: template.id,
      title: template.title,
      description: template.description,
      type: template.type,
      template,
    }));
  }, [mermaidPicker]);

  slashQueryRef.current = slashQuery;
  filteredCommandsRef.current = visibleSlashCommands;
  selectedSlashIndexRef.current = selectedSlashIndex;
  mermaidPickerStateRef.current = mermaidPicker;
  selectedMermaidIndexRef.current = selectedMermaidIndex;

  const commitSave = useCallback(
    (nextText?: string) => {
      const normalized = normalizeLineEndings(
        nextText ?? editor?.getMarkdown() ?? draftText
      );
      if (!ownerKind || !ownerId || !noteId) {
        return;
      }
      if (!hasLocalDirtyChanges && normalized === normalizeLineEndings(state?.text ?? "")) {
        return;
      }
      onDispatchCommand("save", {
        ...(threadId ? { threadId } : {}),
        ownerKind,
        ownerId,
        noteId,
        text: normalized,
      });
      setHasLocalDirtyChanges(false);
    },
    [
      draftText,
      editor,
      hasLocalDirtyChanges,
      noteId,
      onDispatchCommand,
      ownerId,
      ownerKind,
      state?.text,
      threadId,
    ]
  );

  const dispatchThreadNoteCommand = useCallback(
    (type: string, payload?: Record<string, unknown>) => {
      onDispatchCommand(type, {
        ...(threadId ? { threadId } : {}),
        ownerKind,
        ownerId,
        noteId,
        ...(payload ?? {}),
      });
    },
    [noteId, onDispatchCommand, ownerId, ownerKind, threadId]
  );

  const openHeadingTagEditor = useCallback(
    (lineElement: HTMLElement) => {
      if (!editor) {
        return;
      }

      const markdownLine = resolveMarkdownLineFromDOM(editor, lineElement);
      if (!markdownLine) {
        return;
      }

      const menuPosition = resolveHeadingTagMenuPosition(lineElement, layerRef.current);
      setHeadingTagEditor({
        selectionPos: markdownLine.selectionPos,
        insertAt: markdownLine.insertAt,
        tag: markdownLine.tag,
        left: menuPosition.left,
        top: menuPosition.top,
      });
    },
    [editor, layerRef]
  );

  const handleApplyHeadingTag = useCallback(
    (nextTag: MarkdownLineTag) => {
      if (!editor || !headingTagEditor) {
        return;
      }

      applyMarkdownLineTag(
        editor,
        headingTagEditor.selectionPos,
        headingTagEditor.tag,
        nextTag
      );
      setHeadingTagEditor(null);
      refreshSlashQuery(editor);
    },
    [editor, headingTagEditor, refreshSlashQuery]
  );

  const handleInsertMarkdownBlock = useCallback(
    (action: MarkdownInsertAction) => {
      if (!editor || !headingTagEditor) {
        return;
      }

      applyMarkdownInsertAction(editor, headingTagEditor.insertAt, action);
      setHeadingTagEditor(null);
      refreshSlashQuery(editor);
    },
    [editor, headingTagEditor, refreshSlashQuery]
  );

  useEffect(() => {
    if (!headingTagEditor) {
      setHeadingTagSearch("");
      return;
    }

    setHeadingTagSearch("");
    const focusHandle = window.requestAnimationFrame(() => {
      headingTagSearchRef.current?.focus();
      headingTagSearchRef.current?.select();
    });

    return () => {
      window.cancelAnimationFrame(focusHandle);
    };
  }, [headingTagEditor]);

  const openMermaidTemplateType = useCallback((type: MermaidTemplateType) => {
    setMermaidPicker((current) => {
      if (!current) {
        return current;
      }
      return {
        ...current,
        step: "template",
        type,
        canGoBack: true,
      };
    });
    setSelectedMermaidIndex(0);
  }, []);

  const applyMermaidTemplate = useCallback(
    (template: MermaidTemplateDefinition) => {
      if (!editor || !mermaidPicker) {
        return;
      }
      editor.commands.insertContentAt(mermaidPicker.insertAt, template.markdown, {
        contentType: "markdown",
      });
      setMermaidPicker(null);
      setSelectedMermaidIndex(0);
      window.requestAnimationFrame(() => {
        editor.chain().focus().run();
        refreshSlashQuery(editor);
      });
    },
    [editor, mermaidPicker, refreshSlashQuery]
  );

  useEffect(() => {
    const externalText = normalizeLineEndings(state?.text ?? "");
    const noteChanged = noteKey !== previousNoteKeyRef.current;
    let syncRAF: number | null = null;

    if (noteChanged) {
      previousNoteKeyRef.current = noteKey;
      setDraftText(externalText);
      setHasLocalDirtyChanges(false);
      setIsSelectorOpen(false);
      setSelectorFilter("");
      setIsRenamingTitle(false);
      setRenameTitleDraft(normalizeThreadNoteTitle(state?.selectedNoteTitle));
      setDeleteConfirmation(null);
      setOrganizeConfirmation(null);
      setHeadingTagEditor(null);
      setSlashQuery(null);
      setMermaidEditingContext(null);
      setSelectedSlashIndex(0);
      setExpandedSlashGroups({});
      setMermaidPicker(null);
      setSelectedMermaidIndex(0);
      setIsInTable(false);
      setNoteSelection(null);
      summaryTargetRef.current = null;
      setChartStyleInstruction("");
    } else if (!hasLocalDirtyChanges && draftText !== externalText) {
      setDraftText(externalText);
    }

    if (editor && (noteChanged || (!hasLocalDirtyChanges && draftText !== externalText))) {
      const syncEditorContent = () => {
        if (!resolveEditorView(editor)) {
          syncRAF = window.requestAnimationFrame(syncEditorContent);
          return;
        }

        const currentMarkdown = normalizeLineEndings(editor.getMarkdown());
        if (currentMarkdown !== externalText) {
          isApplyingExternalContentRef.current = true;
          editor.commands.setContent(externalText, { contentType: "markdown" });
          isApplyingExternalContentRef.current = false;
        }
        refreshSlashQuery(editor);
      };

      syncEditorContent();
    }

    return () => {
      if (syncRAF !== null) {
        window.cancelAnimationFrame(syncRAF);
      }
    };
  }, [
    draftText,
    editor,
    hasLocalDirtyChanges,
    noteKey,
    refreshSlashQuery,
    state?.text,
  ]);

  useEffect(() => {
    if (!editor) {
      return;
    }

    let editorDom: HTMLElement | null = null;
    let rafID: number | null = null;

    const handleUpdate = () => {
      if (isApplyingExternalContentRef.current) {
        return;
      }
      const nextText = normalizeLineEndings(editor.getMarkdown());
      setDraftText(nextText);
      setHasLocalDirtyChanges(true);
      if (ownerKind && ownerId && noteId) {
        onDispatchCommand("updateDraft", {
          ...(threadId ? { threadId } : {}),
          ownerKind,
          ownerId,
          noteId,
          text: nextText,
        });
      }
      setHeadingTagEditor(null);
      refreshSlashQuery(editor);
    };

    const handleSelectionChange = () => {
      refreshSlashQuery(editor);
    };

    const handleBlur = () => {
      commitSave(editor.getMarkdown());
      setIsInTable(editor.isActive("table"));
      window.requestAnimationFrame(() => {
        const activeElement = document.activeElement;
        const focusInsideFloatingLayer = Boolean(
          activeElement && floatingLayerRef.current?.contains(activeElement)
        );

        if (focusInsideFloatingLayer) {
          return;
        }

        setSlashQuery(null);
        setMermaidEditingContext(null);
        setMermaidPicker(null);
        setHeadingTagEditor(null);
      });
    };

    const handleFocus = () => {
      refreshSlashQuery(editor);
    };

    const handleScroll = () => {
      if (slashQueryRef.current || mermaidPickerStateRef.current) {
        setMenuPosition(measureMenuPosition(editor, editorBodyRef.current, layerRef.current));
      }
      refreshSlashQuery(editor);
    };

    const handleLineDoubleClick = (event: MouseEvent) => {
      const target = event.target;
      if (!(target instanceof Element)) {
        return;
      }

      const lineElement = target.closest<HTMLElement>(
        ".thread-note-heading-node, .thread-note-code-block-node:not(.is-mermaid), p, li, blockquote"
      );
      if (!lineElement) {
        return;
      }

      openHeadingTagEditor(lineElement);
    };

    const handleCapturedKeyDown = (event: KeyboardEvent) => {
      const activeMermaidPicker = mermaidPickerStateRef.current;
      const activeMermaidItems = mermaidPickerItems;
      if (activeMermaidPicker && activeMermaidItems.length > 0) {
        if (event.key === "ArrowDown") {
          event.preventDefault();
          event.stopPropagation();
          setSelectedMermaidIndex((current) => (current + 1) % activeMermaidItems.length);
          return;
        }

        if (event.key === "ArrowUp") {
          event.preventDefault();
          event.stopPropagation();
          setSelectedMermaidIndex((current) =>
            (current - 1 + activeMermaidItems.length) % activeMermaidItems.length
          );
          return;
        }

        if (event.key === "Enter") {
          const selectedMermaidItem =
            activeMermaidItems[selectedMermaidIndexRef.current] ?? activeMermaidItems[0];
          if (!selectedMermaidItem) {
            return;
          }
          event.preventDefault();
          event.stopPropagation();
          if ("template" in selectedMermaidItem) {
            applyMermaidTemplate(selectedMermaidItem.template);
          } else {
            openMermaidTemplateType(selectedMermaidItem.type);
          }
          return;
        }

        if (event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
          if (activeMermaidPicker.step === "template" && activeMermaidPicker.canGoBack) {
            setMermaidPicker({
              ...activeMermaidPicker,
              step: "type",
              type: null,
              canGoBack: false,
            });
            setSelectedMermaidIndex(0);
            return;
          }
          setMermaidPicker(null);
          return;
        }
      }

      const activeSlashQuery = slashQueryRef.current;
      const activeCommands = filteredCommandsRef.current;
      if (!activeSlashQuery || activeCommands.length === 0) {
        return;
      }

      if (event.key === "ArrowDown") {
        event.preventDefault();
        event.stopPropagation();
        setSelectedSlashIndex((current) => (current + 1) % activeCommands.length);
        return;
      }

      if (event.key === "ArrowUp") {
        event.preventDefault();
        event.stopPropagation();
        setSelectedSlashIndex((current) =>
          (current - 1 + activeCommands.length) % activeCommands.length
        );
        return;
      }

      if (event.key === "Enter") {
        const selectedCommand =
          activeCommands[selectedSlashIndexRef.current] ?? activeCommands[0];
        if (!selectedCommand) {
          return;
        }
        event.preventDefault();
        event.stopPropagation();
        selectedCommand.run(editor, activeSlashQuery);
        setSlashQuery(null);
        window.requestAnimationFrame(() => {
          editor.chain().focus().run();
          refreshSlashQuery(editor);
        });
        return;
      }

      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        setSlashQuery(null);
      }
    };

    editor.on("update", handleUpdate);
    editor.on("selectionUpdate", handleSelectionChange);
    editor.on("blur", handleBlur);
    editor.on("focus", handleFocus);

    const attachDomListeners = () => {
      if (editorDom) {
        return;
      }

      const nextEditorDom = resolveEditorDOM(editor);
      if (!nextEditorDom) {
        rafID = window.requestAnimationFrame(attachDomListeners);
        return;
      }

      editorDom = nextEditorDom;
      editorDom.addEventListener("scroll", handleScroll, { passive: true });
      editorDom.addEventListener("keydown", handleCapturedKeyDown, true);
      editorDom.addEventListener("dblclick", handleLineDoubleClick);
    };

    attachDomListeners();

    return () => {
      if (rafID !== null) {
        window.cancelAnimationFrame(rafID);
      }
      editor.off("update", handleUpdate);
      editor.off("selectionUpdate", handleSelectionChange);
      editor.off("blur", handleBlur);
      editor.off("focus", handleFocus);
      editorDom?.removeEventListener("scroll", handleScroll);
      editorDom?.removeEventListener("keydown", handleCapturedKeyDown, true);
      editorDom?.removeEventListener("dblclick", handleLineDoubleClick);
    };
  }, [
    applyMermaidTemplate,
    commitSave,
    editor,
    openHeadingTagEditor,
    mermaidPickerItems,
    noteId,
    onDispatchCommand,
    openMermaidTemplateType,
    ownerId,
    ownerKind,
    refreshSlashQuery,
    threadId,
  ]);

  useEffect(() => {
    if (isRenamingTitle) {
      return;
    }

    setRenameTitleDraft(normalizeThreadNoteTitle(state?.selectedNoteTitle));
  }, [isRenamingTitle, state?.selectedNoteTitle]);

  useEffect(() => {
    if (!isOpen) {
      setSlashQuery(null);
      setMermaidEditingContext(null);
      setExpandedSlashGroups({});
      setMermaidPicker(null);
      return;
    }

    if (!editor || !noteId) {
      return;
    }

    if (!openRef.current) {
      window.requestAnimationFrame(() => {
        editor.chain().focus("end").run();
        refreshSlashQuery(editor);
      });
    }

    openRef.current = isOpen;
  }, [editor, isOpen, noteId, refreshSlashQuery]);

  useEffect(() => {
    if (isRenamingTitle) {
      renameInputRef.current?.focus();
      renameInputRef.current?.select();
      return;
    }

    if (isSelectorOpen) {
      selectorSearchInputRef.current?.focus();
      selectorSearchInputRef.current?.select();
    }
  }, [isRenamingTitle, isSelectorOpen]);

  useEffect(() => {
    if (selectedSlashIndex >= visibleSlashCommands.length) {
      setSelectedSlashIndex(0);
    }
  }, [selectedSlashIndex, visibleSlashCommands.length]);

  useEffect(() => {
    setSelectedSlashIndex(0);
  }, [slashQuery?.query]);

  useEffect(() => {
    setExpandedSlashGroups({});
  }, [slashMenuSessionKey]);

  useEffect(() => {
    if (selectedMermaidIndex >= mermaidPickerItems.length) {
      setSelectedMermaidIndex(0);
    }
  }, [mermaidPickerItems.length, selectedMermaidIndex]);

  useEffect(() => {
    setSelectedMermaidIndex(0);
  }, [mermaidPicker?.step, mermaidPicker?.type]);

  useEffect(() => {
    if (!isOpen || !ownerKind || !ownerId || !noteId || !hasLocalDirtyChanges) {
      return;
    }

    const timeout = window.setTimeout(() => {
      commitSave();
    }, THREAD_NOTE_SAVE_DEBOUNCE_MS);

    return () => window.clearTimeout(timeout);
  }, [commitSave, hasLocalDirtyChanges, isOpen, noteId, ownerId, ownerKind]);

  useEffect(() => {
    if ((!slashQuery && !mermaidPicker) || !editor) {
      return;
    }

    const refreshMenuPosition = () => {
      setMenuPosition(measureMenuPosition(editor, editorBodyRef.current, layerRef.current));
    };

    refreshMenuPosition();
    window.addEventListener("resize", refreshMenuPosition);
    return () => {
      window.removeEventListener("resize", refreshMenuPosition);
    };
  }, [editor, layerRef, mermaidPicker, slashQuery]);

  const handleCloseDrawer = useCallback(() => {
    if (!canCloseDrawer) {
      return;
    }
    commitSave();
    editor?.commands.blur();
    setHeadingTagEditor(null);
    setSlashQuery(null);
    setMermaidEditingContext(null);
    setMermaidPicker(null);
    dispatchThreadNoteCommand("setOpen", { isOpen: false });
  }, [canCloseDrawer, commitSave, dispatchThreadNoteCommand, editor]);

  useEffect(() => {
    if (!isOpen || !canCloseDrawer) {
      return;
    }

    const handlePointerDown = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) {
        return;
      }
      const clickedInsideDrawer = Boolean(drawerRef.current?.contains(target));
      const clickedInsideFloatingLayer = Boolean(floatingLayerRef.current?.contains(target));
      const clickedEditableMarkdownLine =
        target instanceof Element &&
        Boolean(
          target.closest(
            ".thread-note-heading-node, .thread-note-code-block-node:not(.is-mermaid), p, li, blockquote"
          )
        );

      if (
        headingTagEditor &&
        !clickedInsideFloatingLayer &&
        !clickedEditableMarkdownLine
      ) {
        setHeadingTagEditor(null);
      }

      if (clickedInsideDrawer) {
        return;
      }
      if (clickedInsideFloatingLayer) {
        return;
      }
      handleCloseDrawer();
    };

    window.addEventListener("pointerdown", handlePointerDown, true);
    return () => {
      window.removeEventListener("pointerdown", handlePointerDown, true);
    };
  }, [canCloseDrawer, handleCloseDrawer, headingTagEditor, isOpen]);

  useEffect(() => {
    if (!isOpen || shouldBlockDrawerEscape || !canCloseDrawer) {
      return;
    }

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") {
        return;
      }
      event.preventDefault();
      if (headingTagEditor) {
        setHeadingTagEditor(null);
        return;
      }
      handleCloseDrawer();
    };

    window.addEventListener("keydown", handleKeyDown, true);
    return () => {
      window.removeEventListener("keydown", handleKeyDown, true);
    };
  }, [canCloseDrawer, handleCloseDrawer, headingTagEditor, isOpen, shouldBlockDrawerEscape]);

  useEffect(() => {
    if (aiDraftMode === "chart" && (aiDraftPreview || state?.isGeneratingAIDraft)) {
      return;
    }
    setChartStyleInstruction("");
  }, [aiDraftMode, aiDraftPreview, state?.isGeneratingAIDraft]);

  useEffect(() => {
    if (!hasActiveChartDraft) {
      setIsChartDraftModalDismissed(false);
    }
  }, [hasActiveChartDraft]);

  useEffect(() => {
    if (!previousChartDraftActiveRef.current && hasActiveChartDraft) {
      setIsChartDraftModalDismissed(false);
    }
    previousChartDraftActiveRef.current = hasActiveChartDraft;
  }, [hasActiveChartDraft]);

  useEffect(() => {
    if (isOpen && !previousDrawerOpenRef.current && hasActiveChartDraft) {
      setIsChartDraftModalDismissed(false);
    }
    previousDrawerOpenRef.current = isOpen;
  }, [hasActiveChartDraft, isOpen]);

  useEffect(() => {
    setIsChartDraftModalDismissed(false);
  }, [noteKey]);

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

  const toggleSlashGroup = useCallback((groupId: string) => {
    setExpandedSlashGroups((current) => ({
      ...current,
      [groupId]: !current[groupId],
    }));
  }, []);

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

  const handleCreateNote = useCallback(() => {
    commitSave();
    setIsSelectorOpen(false);
    setSelectorFilter("");
    setIsRenamingTitle(false);
    dispatchThreadNoteCommand("createNote");
  }, [commitSave, dispatchThreadNoteCommand]);

  const handleCreateNoteForSource = useCallback(
    (sourceOwnerKind: string, sourceOwnerId: string) => {
      commitSave();
      setIsSelectorOpen(false);
      setSelectorFilter("");
      setIsRenamingTitle(false);
      onDispatchCommand("createNote", {
        ...(threadId ? { threadId } : {}),
        ownerKind: sourceOwnerKind,
        ownerId: sourceOwnerId,
      });
    },
    [commitSave, onDispatchCommand, threadId]
  );

  const handleDeleteNote = useCallback(() => {
    if (!noteId) {
      return;
    }
    const label = state?.selectedNoteTitle?.trim() || "this note";
    setIsSelectorOpen(false);
    setSelectorFilter("");
    setDeleteConfirmation({
      noteId,
      title: label,
    });
  }, [dispatchThreadNoteCommand, noteId, state?.selectedNoteTitle]);

  const handleConfirmDelete = useCallback(() => {
    if (!deleteConfirmation) {
      return;
    }
    dispatchThreadNoteCommand("deleteNote", { noteId: deleteConfirmation.noteId });
    setDeleteConfirmation(null);
  }, [deleteConfirmation, dispatchThreadNoteCommand]);

  const handleSelectNote = useCallback(
    (nextNoteId: string, nextOwnerKind: string, nextOwnerId: string) => {
      if (
        !nextNoteId ||
        (nextNoteId === noteId &&
          nextOwnerKind === ownerKind &&
          nextOwnerId === ownerId)
      ) {
        setIsSelectorOpen(false);
        return;
      }
      commitSave();
      setIsRenamingTitle(false);
      setSelectorFilter("");
      onDispatchCommand("selectNote", {
        ...(threadId ? { threadId } : {}),
        ownerKind: nextOwnerKind,
        ownerId: nextOwnerId,
        noteId: nextNoteId,
      });
      setIsSelectorOpen(false);
    },
    [commitSave, noteId, onDispatchCommand, ownerId, ownerKind, threadId]
  );

  const handleToggleSelectorMenu = useCallback(() => {
    if (!selectorButtonRef.current || !state?.availableSources?.length) {
      return;
    }
    commitSave();
    setIsSelectorOpen((current) => {
      const nextOpen = !current;
      if (!nextOpen) {
        setSelectorFilter("");
      }
      return nextOpen;
    });
  }, [commitSave, state?.availableSources?.length]);

  const handleStartRenameTitle = useCallback(() => {
    if (!noteId) {
      return;
    }

    setIsSelectorOpen(false);
    setSelectorFilter("");
    setRenameTitleDraft(normalizeThreadNoteTitle(state?.selectedNoteTitle));
    setIsRenamingTitle(true);
  }, [noteId, state?.selectedNoteTitle]);

  const handleCancelRenameTitle = useCallback(() => {
    setRenameTitleDraft(normalizeThreadNoteTitle(state?.selectedNoteTitle));
    setIsRenamingTitle(false);
  }, [state?.selectedNoteTitle]);

  const handleCommitRenameTitle = useCallback(() => {
    if (!noteId) {
      return;
    }

    const nextTitle = normalizeThreadNoteTitle(renameTitleDraft);
    if (nextTitle === normalizeThreadNoteTitle(state?.selectedNoteTitle)) {
      setIsRenamingTitle(false);
      return;
    }

    commitSave();
    dispatchThreadNoteCommand("renameNote", {
      noteId,
      title: nextTitle,
    });
    setIsRenamingTitle(false);
  }, [
    commitSave,
    dispatchThreadNoteCommand,
    noteId,
    renameTitleDraft,
    state?.selectedNoteTitle,
  ]);

  const handleRequestAIDraft = useCallback(() => {
    if (!noteId) {
      return;
    }
    const currentMarkdown = normalizeLineEndings(editor?.getMarkdown() ?? draftText);
    const selectedText = noteSelection?.text?.trim() || "";
    const requestKind = selectedText ? "selection" : "whole";
    summaryTargetRef.current = selectedText
      ? {
          kind: "selection",
          from: noteSelection?.from,
          to: noteSelection?.to,
        }
      : { kind: "whole" };

    dispatchThreadNoteCommand("requestAIDraftPreview", {
      noteId,
      draftMode: "organize",
      text: currentMarkdown,
      selectedText: selectedText || undefined,
      requestKind,
    });
  }, [dispatchThreadNoteCommand, draftText, editor, noteId, noteSelection]);

  const closeAIDraftPreview = useCallback(
    (
      commandType:
        | "cancelAIDraftPreview"
        | "applyAIDraftPreview"
        | "clearAIDraftPreview" = "cancelAIDraftPreview"
    ) => {
      summaryTargetRef.current = null;
      dispatchThreadNoteCommand(commandType);
    },
    [dispatchThreadNoteCommand]
  );

  const clearAIDraftPreview = useCallback(() => {
    summaryTargetRef.current = null;
    dispatchThreadNoteCommand("cancelAIDraftPreview");
  }, [dispatchThreadNoteCommand]);

  const dismissChartDraftModal = useCallback(() => {
    summaryTargetRef.current = null;
    setIsChartDraftModalDismissed(true);
  }, []);

  const reopenChartDraftModal = useCallback(() => {
    setIsChartDraftModalDismissed(false);
  }, []);

  const discardChartDraft = useCallback(() => {
    setIsChartDraftModalDismissed(false);
    clearAIDraftPreview();
  }, [clearAIDraftPreview]);

  const commitEditorMarkdown = useCallback(
    (nextMarkdown: string) => {
      const normalized = normalizeLineEndings(nextMarkdown);
      setDraftText(normalized);
      setHasLocalDirtyChanges(true);
      if (ownerKind && ownerId && noteId) {
        onDispatchCommand("updateDraft", {
          ...(threadId ? { threadId } : {}),
          ownerKind,
          ownerId,
          noteId,
          text: normalized,
        });
      }
      commitSave(normalized);
    },
    [commitSave, noteId, onDispatchCommand, ownerId, ownerKind, threadId]
  );

  const handleApplyOrganizeAIDraft = useCallback(
    (applyMode: "replace" | "insertAbove" | "insertBelow" | "replaceNote" | "insertTop" | "insertBottom") => {
      if (!editor || !aiDraftPreview || aiDraftPreview.isError || aiDraftPreview.mode !== "organize") {
        closeAIDraftPreview();
        return;
      }

      const previewMarkdown = normalizeLineEndings(aiDraftPreview.markdown);
      const currentMarkdown = normalizeLineEndings(editor.getMarkdown());
      const summaryTarget = summaryTargetRef.current;

      if (summaryTarget?.kind === "selection" && summaryTarget.from && summaryTarget.to) {
        if (applyMode === "replace") {
          editor.commands.insertContentAt(
            { from: summaryTarget.from, to: summaryTarget.to },
            previewMarkdown,
            { contentType: "markdown" }
          );
        } else if (applyMode === "insertAbove") {
          editor.commands.insertContentAt(summaryTarget.from, `${previewMarkdown}\n\n`, {
            contentType: "markdown",
          });
        } else if (applyMode === "insertBelow") {
          editor.commands.insertContentAt(summaryTarget.to, `\n\n${previewMarkdown}`, {
            contentType: "markdown",
          });
        }
        const nextMarkdown = normalizeLineEndings(editor.getMarkdown());
        commitEditorMarkdown(nextMarkdown);
        closeAIDraftPreview("applyAIDraftPreview");
        return;
      }

      const mergedMarkdown =
        applyMode === "replaceNote"
          ? previewMarkdown
          : applyMode === "insertTop"
            ? [previewMarkdown.trim(), currentMarkdown.trim()].filter(Boolean).join("\n\n")
            : [currentMarkdown.trim(), previewMarkdown.trim()].filter(Boolean).join("\n\n");

      editor.commands.setContent(mergedMarkdown, { contentType: "markdown" });
      commitEditorMarkdown(normalizeLineEndings(editor.getMarkdown()));
      closeAIDraftPreview("applyAIDraftPreview");
    },
    [aiDraftPreview, closeAIDraftPreview, commitEditorMarkdown, editor]
  );

  const handleAddChartDraftToNote = useCallback(() => {
    if (!editor || !aiDraftPreview || aiDraftPreview.isError || aiDraftPreview.mode !== "chart") {
      closeAIDraftPreview();
      return;
    }

    const currentMarkdown = normalizeLineEndings(editor.getMarkdown()).trim();
    const draftMarkdown = normalizeLineEndings(aiDraftPreview.markdown).trim();
    const mergedMarkdown = [currentMarkdown, draftMarkdown].filter(Boolean).join("\n\n");
    editor.commands.setContent(mergedMarkdown, { contentType: "markdown" });
    commitEditorMarkdown(normalizeLineEndings(editor.getMarkdown()));
    closeAIDraftPreview("applyAIDraftPreview");
  }, [aiDraftPreview, closeAIDraftPreview, commitEditorMarkdown, editor]);

  const handleRegenerateChartDraft = useCallback(() => {
    const normalizedInstruction = chartStyleInstruction.trim();
    if (
      !normalizedInstruction ||
      !aiDraftPreview ||
      aiDraftPreview.mode !== "chart" ||
      !noteId
    ) {
      return;
    }

    dispatchThreadNoteCommand("regenerateAIDraftPreview", {
      noteId,
      draftMode: "chart",
      styleInstruction: normalizedInstruction,
      currentDraftMarkdown: aiDraftPreview.markdown || undefined,
    });
  }, [aiDraftPreview, chartStyleInstruction, dispatchThreadNoteCommand, noteId]);

  const notes = state?.notes ?? [];
  const currentSourceKey = noteSourceKey(ownerKind, ownerId);
  const currentSourceLabel = state?.availableSources.find(
    (source) => noteSourceKey(source.ownerKind, source.ownerId) === currentSourceKey
  )?.sourceLabel ?? noteSourceLabelForOwner(ownerKind);
  const notesForCurrentSource = useMemo(
    () =>
      notes.filter(
        (note) => noteSourceKey(note.ownerKind, note.ownerId) === currentSourceKey
      ),
    [currentSourceKey, notes]
  );
  const hasAnyNotes = notesForCurrentSource.length > 0;
  const noteCount = notesForCurrentSource.length;
  const notePositionById = useMemo(
    () =>
      new Map(notesForCurrentSource.map((note, index) => [note.id, index + 1])),
    [notesForCurrentSource]
  );
  const normalizedSelectorFilter = selectorFilter.trim().toLowerCase();
  const sourceSections = useMemo<ThreadNoteSourceSection[]>(
    () =>
      (state?.availableSources ?? []).map((source) => {
        const allSourceNotes = notes.filter(
          (note) => noteSourceKey(note.ownerKind, note.ownerId) === noteSourceKey(source.ownerKind, source.ownerId)
        );
        const visibleSourceNotes = normalizedSelectorFilter
          ? allSourceNotes.filter((note) =>
              normalizeThreadNoteTitle(note.title)
                .toLowerCase()
                .includes(normalizedSelectorFilter)
            )
          : allSourceNotes;
        return {
          source,
          allNotes: allSourceNotes,
          visibleNotes: visibleSourceNotes,
        };
      }),
    [normalizedSelectorFilter, notes, state?.availableSources]
  );
  const isAIDraftBusy = Boolean(state?.isGeneratingAIDraft);
  const selectedNoteIndex =
    noteId && noteCount > 0
      ? Math.max(0, notesForCurrentSource.findIndex((note) => note.id === noteId)) + 1
      : 0;
  const selectedNoteBadge =
    selectedNoteIndex > 0 && noteCount > 1 ? `${selectedNoteIndex}/${noteCount}` : null;
  const selectorLabel =
    state?.selectedNoteTitle?.trim() ||
    (noteCount > 0 ? "Untitled note" : currentSourceLabel);
  const canRequestSummary = hasAnyNotes && Boolean(draftText.trim() || noteSelection?.text?.trim());
  const shouldShowSummaryAction = Boolean(canRequestSummary || state?.isGeneratingAIDraft);
  const handleOpenOrganizeConfirmation = useCallback(() => {
    if (!canRequestSummary || state?.isGeneratingAIDraft) {
      return;
    }

    setOrganizeConfirmation(noteSelection?.text?.trim() ? "selection" : "whole");
  }, [canRequestSummary, noteSelection?.text, state?.isGeneratingAIDraft]);
  const handleConfirmOrganize = useCallback(() => {
    setOrganizeConfirmation(null);
    handleRequestAIDraft();
  }, [handleRequestAIDraft]);
  const aiButtonLabel = noteSelection?.text ? "Organize Selection" : "Organize Note";
  const selectedMermaidType = mermaidPicker?.type
    ? MERMAID_TEMPLATE_TYPES.find((option) => option.type === mermaidPicker.type) ?? null
    : null;
  const normalizedHeadingTagSearch = headingTagSearch.trim().toLowerCase();
  const filteredMarkdownTagOptions = MARKDOWN_LINE_TAG_OPTIONS.filter((option) =>
    matchesMarkdownPickerOption(option, normalizedHeadingTagSearch)
  );
  const filteredMarkdownInsertOptions = MARKDOWN_INSERT_OPTIONS.filter((option) =>
    matchesMarkdownPickerOption(option, normalizedHeadingTagSearch)
  );
  const currentMarkdownTagOption = headingTagEditor
    ? MARKDOWN_LINE_TAG_OPTION_BY_ID.get(headingTagEditor.tag) ??
      MARKDOWN_LINE_TAG_OPTIONS[0]
    : null;
  const mermaidPickerTitle =
    mermaidPicker?.step === "template"
      ? selectedMermaidType?.label ?? "Choose a template"
      : "Choose a Mermaid type";
  const floatingMenuStyle = resolveFloatingMenuStyle(menuPosition);
  const headingTagMenuStyle = headingTagEditor
    ? ({
        left: `${headingTagEditor.left}px`,
        top: `${headingTagEditor.top}px`,
      } satisfies CSSProperties)
    : undefined;

  return (
    <>
      <aside
        ref={drawerRef}
        className={[
          "thread-note-drawer",
          isExpanded ? "is-expanded" : "",
          isProjectFullScreen ? "is-project-fullscreen" : "",
        ]
          .filter(Boolean)
          .join(" ")}
        aria-hidden={!isOpen}
      >
        <div className="thread-note-header">
          <div className="thread-note-workspace-row">
            <div className="thread-note-header-copy">
              <span className="thread-note-eyebrow">{currentSourceLabel}</span>
              {isRenamingTitle ? (
                <div className="thread-note-title-editor">
                  <input
                    ref={renameInputRef}
                    type="text"
                    className="thread-note-title-input"
                    value={renameTitleDraft}
                    onChange={(event) => setRenameTitleDraft(event.target.value)}
                    onKeyDown={(event) => {
                      if (event.key === "Enter") {
                        event.preventDefault();
                        handleCommitRenameTitle();
                      } else if (event.key === "Escape") {
                        event.preventDefault();
                        handleCancelRenameTitle();
                      }
                    }}
                    placeholder="Untitled note"
                    aria-label="Rename note"
                  />
                  <button
                    type="button"
                    className="thread-note-title-action is-primary"
                    onMouseDown={(event) => event.preventDefault()}
                    onClick={handleCommitRenameTitle}
                  >
                    Save
                  </button>
                  <button
                    type="button"
                    className="thread-note-title-action"
                    onMouseDown={(event) => event.preventDefault()}
                    onClick={handleCancelRenameTitle}
                  >
                    Cancel
                  </button>
                </div>
              ) : (
                <div className="thread-note-selector-row">
                  <button
                    ref={selectorButtonRef}
                    type="button"
                    className="thread-note-selector-trigger"
                    onClick={handleToggleSelectorMenu}
                    disabled={!state?.availableSources?.length}
                    aria-label="Choose note source"
                    aria-expanded={isSelectorOpen}
                  >
                    <span className="thread-note-selector-main">
                      <span className="thread-note-selector-title">{selectorLabel}</span>
                    </span>
                    <span className="thread-note-selector-trailing">
                      {selectedNoteBadge ? (
                        <span className="thread-note-selector-count">{selectedNoteBadge}</span>
                      ) : null}
                      <span
                        className={[
                          "thread-note-selector-chevron",
                          isSelectorOpen ? "is-open" : "",
                        ]
                          .filter(Boolean)
                          .join(" ")}
                        aria-hidden="true"
                      >
                        ▾
                      </span>
                    </span>
                  </button>
                </div>
              )}
              {isSelectorOpen ? (
                <div className="thread-note-selector-menu">
                  <div className="thread-note-selector-menu-header">
                    <div className="thread-note-selector-menu-copy">
                      <span className="thread-note-selector-menu-title">Select note source</span>
                      <span className="thread-note-selector-menu-subtitle">
                        Pick from thread notes and project notes, then switch faster.
                      </span>
                    </div>
                    <span className="thread-note-selector-menu-count">
                      {notes.length} note{notes.length === 1 ? "" : "s"}
                    </span>
                  </div>
                  <div className="thread-note-selector-search-shell">
                    <input
                      ref={selectorSearchInputRef}
                      type="text"
                      className="thread-note-selector-search"
                      value={selectorFilter}
                      onChange={(event) => setSelectorFilter(event.target.value)}
                      placeholder="Search notes"
                      aria-label="Search notes"
                    />
                  </div>
                  <div className="thread-note-selector-list">
                    {sourceSections.some(
                      (section) =>
                        section.visibleNotes.length > 0 ||
                        (!normalizedSelectorFilter && section.allNotes.length === 0)
                    ) ? sourceSections.map((section) => (
                      <div key={noteSourceKey(section.source.ownerKind, section.source.ownerId)}>
                        <div className="thread-note-selector-section-header">
                          <span>{section.source.sourceLabel}</span>
                          <span>{section.allNotes.length}</span>
                        </div>
                        {section.visibleNotes.map((note, index) => (
                          <button
                            key={`${section.source.ownerKind}:${section.source.ownerId}:${note.id}`}
                            type="button"
                            className={[
                              "thread-note-selector-option",
                              note.id === noteId &&
                              note.ownerKind === ownerKind &&
                              note.ownerId === ownerId
                                ? "is-selected"
                                : "",
                            ]
                              .filter(Boolean)
                              .join(" ")}
                            onClick={() =>
                              handleSelectNote(note.id, note.ownerKind, note.ownerId)
                            }
                          >
                            <span className="thread-note-selector-option-copy">
                              <span className="thread-note-selector-option-title">
                                {normalizeThreadNoteTitle(note.title)}
                              </span>
                              <span className="thread-note-selector-option-subtitle">
                                {note.updatedAtLabel
                                  ? `Updated ${note.updatedAtLabel}`
                                  : "No saved timestamp yet"}
                              </span>
                            </span>
                            <span className="thread-note-selector-option-meta">
                              {noteSourceKey(note.ownerKind, note.ownerId) === currentSourceKey
                                ? `${notePositionById.get(note.id) ?? index + 1} of ${Math.max(
                                    1,
                                    noteCount
                                  )}`
                                : section.source.ownerTitle}
                            </span>
                          </button>
                        ))}
                        {!normalizedSelectorFilter && section.allNotes.length === 0 ? (
                          <button
                            type="button"
                            className="thread-note-selector-create-option"
                            onClick={() =>
                              handleCreateNoteForSource(
                                section.source.ownerKind,
                                section.source.ownerId
                              )
                            }
                          >
                            Create {section.source.sourceLabel.toLowerCase().replace("notes", "note")}
                          </button>
                        ) : null}
                      </div>
                    )) : (
                      <div className="thread-note-selector-empty">
                        No notes match "{selectorFilter.trim()}".
                      </div>
                    )}
                  </div>
                </div>
              ) : null}
            </div>

            <div className="thread-note-toolbar">
              {hasAnyNotes ? (
                <button
                  type="button"
                  className="thread-note-icon-button"
                  onClick={handleStartRenameTitle}
                  aria-label="Rename note"
                  title="Rename note"
                >
                  <EditIcon />
                </button>
              ) : null}
              <button
                className="thread-note-icon-button"
                type="button"
                onClick={handleCreateNote}
                aria-label={`New ${currentSourceLabel.toLowerCase().replace("notes", "note")}`}
                title={`New ${currentSourceLabel.toLowerCase().replace("notes", "note")}`}
              >
                <PlusIcon />
              </button>
              {!isProjectFullScreen ? (
                <button
                  className="thread-note-icon-button"
                  type="button"
                  onClick={() =>
                    dispatchThreadNoteCommand("setExpanded", {
                      isExpanded: !isExpanded,
                    })
                  }
                  aria-label={isExpanded ? "Collapse note" : "Expand note"}
                  title={isExpanded ? "Collapse note" : "Expand note"}
                >
                  <ExpandIcon expanded={isExpanded} />
                </button>
              ) : null}
              <button
                className="thread-note-icon-button is-danger"
                type="button"
                onClick={handleDeleteNote}
                disabled={!hasAnyNotes}
                aria-label={`Delete ${currentSourceLabel.toLowerCase().replace("notes", "note")}`}
                title={`Delete ${currentSourceLabel.toLowerCase().replace("notes", "note")}`}
              >
                <TrashIcon />
              </button>
            </div>
          </div>

          {(statusLabel || shouldShowSummaryAction || hasAnyNotes) ? (
            <div className="thread-note-meta-row">
              {statusLabel ? (
                <span className="thread-note-status">{statusLabel}</span>
              ) : null}
              {shouldShowSummaryAction ? (
                <button
                  type="button"
                  className="thread-note-ai-button"
                  onClick={handleOpenOrganizeConfirmation}
                  disabled={!canRequestSummary || state?.isGeneratingAIDraft}
                >
                  {state?.isGeneratingAIDraft ? "Working..." : aiButtonLabel}
                </button>
              ) : null}
            </div>
          ) : null}
        </div>

        <div className="thread-note-surface">
          {!hasAnyNotes ? (
            <div className="thread-note-empty-shell">
              <div className="thread-note-empty-copy">
                <h3>
                  {currentSourceLabel === "Project notes"
                    ? "No project notes yet"
                    : "No thread notes yet"}
                </h3>
                <p>
                  {currentSourceLabel === "Project notes"
                    ? "Create a shared project note for decisions, architecture, and next steps."
                    : "Create a note for this thread and start collecting key points."}
                </p>
              </div>
              <button
                type="button"
                className="thread-note-empty-button"
                onClick={handleCreateNote}
              >
                {currentSourceLabel === "Project notes" ? "New project note" : "New thread note"}
              </button>
            </div>
          ) : (
            <div className="thread-note-workspace">
              <div className="thread-note-editor-shell">
                {showChartDraftStatusCard ? (
                  <div className="thread-note-ai-status-card">
                    <div className="thread-note-ai-status-copy">
                      <strong>{chartDraftStatusTitle}</strong>
                      <span>{chartDraftStatusDetail}</span>
                    </div>
                    <div className="thread-note-ai-status-actions">
                      <button
                        type="button"
                        className="oa-button"
                        onClick={reopenChartDraftModal}
                      >
                        Open chart
                      </button>
                      {aiDraftPreview ? (
                        <button
                          type="button"
                          className="oa-button"
                          onClick={discardChartDraft}
                        >
                          Discard
                        </button>
                      ) : null}
                    </div>
                  </div>
                ) : null}

                {isInTable && editor ? (
                  <div className="thread-note-table-toolbar">
                    <button
                      className="thread-note-table-action"
                      type="button"
                      disabled={!editor.can().addRowAfter()}
                      onMouseDown={(event) => {
                        event.preventDefault();
                        runTableCommand((activeEditor) =>
                          activeEditor.chain().focus().addRowAfter().run()
                        );
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
                        runTableCommand((activeEditor) =>
                          activeEditor.chain().focus().deleteRow().run()
                        );
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

                <div ref={editorBodyRef} className="thread-note-editor-body">
                  {editor ? (
                    <EditorContent editor={editor} className="thread-note-editor-content" />
                  ) : (
                    <div className="thread-note-editor-loading">{placeholderText}</div>
                  )}
                </div>
              </div>
            </div>
          )}
        </div>
        {showAIDraftModal ? (
          <div
            className="thread-note-dialog-layer"
            onClick={isChartDraft ? dismissChartDraftModal : clearAIDraftPreview}
          >
            <div
              className="thread-note-dialog thread-note-summary-modal"
              onClick={(event) => event.stopPropagation()}
            >
              <div className="thread-note-dialog-header">
                <div className="thread-note-dialog-copy">
                  <h2>
                    {isChartDraft
                      ? isAIDraftError
                        ? "AI could not make this chart"
                        : aiDraftPreview
                          ? "Review AI chart"
                          : "Generating AI chart"
                      : isAIDraftError
                        ? "AI could not organize this note"
                        : aiDraftPreview
                          ? "Review AI draft"
                          : "Organizing note"}
                  </h2>
                  <p>
                    {isChartDraft
                      ? activeAIDraftSourceKind === "chatSelection"
                        ? "This chart comes from the text you selected in the chat. You can regenerate it in a different style before adding it."
                        : "This chart draft is ready to review before it is added to the note."
                      : activeAIDraftSourceKind === "selection"
                        ? "This draft was made from the text you selected in this note."
                        : "This draft was made from the current note."}
                  </p>
                </div>
                <button
                  type="button"
                  className="thread-note-icon-button thread-note-dialog-close"
                  onClick={isChartDraft ? dismissChartDraftModal : clearAIDraftPreview}
                  aria-label="Close AI draft"
                >
                  ×
                </button>
              </div>
              <div className="thread-note-dialog-body">
                {!aiDraftPreview ? (
                  <div className="thread-note-ai-loading">
                    <div className="thread-note-ai-loading-spinner" aria-hidden="true" />
                    <div className="thread-note-ai-loading-copy">
                      {isChartDraft
                        ? "AI is choosing a Mermaid style and building the first chart draft."
                        : "AI is organizing the note into a cleaner draft."}
                    </div>
                  </div>
                ) : aiDraftPreview.isError ? (
                  <div className="thread-note-summary-error">{aiDraftPreview.markdown}</div>
                ) : (
                  <div className="assistant-markdown-shell oa-markdown-surface thread-note-summary-preview">
                    <MarkdownContent
                      markdown={aiDraftPreview.markdown}
                      mermaidDisplayMode="noteCompact"
                    />
                  </div>
                )}
                {isChartDraft && aiDraftPreview && !aiDraftPreview.isError ? (
                  <div className="thread-note-chart-regenerate-shell">
                    <label className="thread-note-chart-regenerate-label" htmlFor="thread-note-chart-style">
                      Regenerate with a different style
                    </label>
                    <input
                      id="thread-note-chart-style"
                      type="text"
                      className="thread-note-chart-regenerate-input"
                      value={chartStyleInstruction}
                      onChange={(event) => setChartStyleInstruction(event.target.value)}
                      placeholder="Try: make it a tree, use mindmap, simpler layout"
                      disabled={isAIDraftBusy}
                    />
                    <p className="thread-note-chart-regenerate-hint">
                      Example: &ldquo;make it a tree&rdquo; or &ldquo;use sequence style&rdquo;.
                    </p>
                  </div>
                ) : null}
              </div>
              <div className="thread-note-dialog-footer">
                {isAIDraftError && isChartDraft ? (
                  <>
                    <button
                      type="button"
                      className="oa-button"
                      onClick={dismissChartDraftModal}
                    >
                      Hide
                    </button>
                    <button
                      type="button"
                      className="oa-button"
                      onClick={discardChartDraft}
                    >
                      Discard
                    </button>
                  </>
                ) : isAIDraftError ? (
                  <>
                    <button
                      type="button"
                      className="oa-button"
                      onClick={() => dispatchThreadNoteCommand("openSettings")}
                    >
                      Open Settings
                    </button>
                    <button
                      type="button"
                      className="oa-button"
                      onClick={clearAIDraftPreview}
                    >
                      Close
                    </button>
                  </>
                ) : isChartDraft ? (
                  <>
                    <button
                      type="button"
                      className="oa-button"
                      onClick={dismissChartDraftModal}
                    >
                      Hide
                    </button>
                    {aiDraftPreview ? (
                      <button
                        type="button"
                        className="oa-button"
                        onClick={discardChartDraft}
                      >
                        Discard
                      </button>
                    ) : null}
                    {aiDraftPreview ? (
                      <button
                        type="button"
                        className="oa-button"
                        disabled={isAIDraftBusy || !chartStyleInstruction.trim()}
                        onClick={handleRegenerateChartDraft}
                      >
                        {isAIDraftBusy ? "Working..." : "Regenerate"}
                      </button>
                    ) : null}
                    {aiDraftPreview ? (
                      <button
                        type="button"
                        className="oa-button oa-button--primary"
                        disabled={isAIDraftBusy}
                        onClick={handleAddChartDraftToNote}
                      >
                        Add to Note
                      </button>
                    ) : null}
                  </>
                ) : activeAIDraftSourceKind === "selection" ? (
                  <>
                    <button
                      type="button"
                      className="oa-button"
                      disabled={isAIDraftBusy}
                      onClick={() => handleApplyOrganizeAIDraft("replace")}
                    >
                      Replace
                    </button>
                    <button
                      type="button"
                      className="oa-button"
                      disabled={isAIDraftBusy}
                      onClick={() => handleApplyOrganizeAIDraft("insertAbove")}
                    >
                      Insert Above
                    </button>
                    <button
                      type="button"
                      className="oa-button"
                      disabled={isAIDraftBusy}
                      onClick={() => handleApplyOrganizeAIDraft("insertBelow")}
                    >
                      Insert Below
                    </button>
                    <button
                      type="button"
                      className="oa-button"
                      onClick={clearAIDraftPreview}
                    >
                      Cancel
                    </button>
                  </>
                ) : (
                  <>
                    <button
                      type="button"
                      className="oa-button"
                      disabled={isAIDraftBusy}
                      onClick={() => handleApplyOrganizeAIDraft("replaceNote")}
                    >
                      Replace Note
                    </button>
                    <button
                      type="button"
                      className="oa-button"
                      disabled={isAIDraftBusy}
                      onClick={() => handleApplyOrganizeAIDraft("insertTop")}
                    >
                      Insert at Top
                    </button>
                    <button
                      type="button"
                      className="oa-button"
                      disabled={isAIDraftBusy}
                      onClick={() => handleApplyOrganizeAIDraft("insertBottom")}
                    >
                      Insert at Bottom
                    </button>
                    <button
                      type="button"
                      className="oa-button"
                      onClick={clearAIDraftPreview}
                    >
                      Cancel
                    </button>
                  </>
                )}
              </div>
            </div>
          </div>
        ) : null}

        {deleteConfirmation ? (
          <div className="thread-note-dialog-layer" onClick={() => setDeleteConfirmation(null)}>
            <div
              className="thread-note-dialog thread-note-delete-modal"
              onClick={(event) => event.stopPropagation()}
            >
              <div className="thread-note-dialog-header">
                <div className="thread-note-dialog-copy">
                  <h2>Delete note?</h2>
                  <p>
                    This will remove &ldquo;{deleteConfirmation.title}&rdquo; from{" "}
                    {currentSourceLabel === "Project notes" ? "this project" : "this thread"}.
                  </p>
                </div>
                <button
                  type="button"
                  className="thread-note-icon-button thread-note-dialog-close"
                  onClick={() => setDeleteConfirmation(null)}
                  aria-label="Close delete dialog"
                >
                  ×
                </button>
              </div>
              <div className="thread-note-dialog-footer">
                <button
                  type="button"
                  className="oa-button"
                  onClick={() => setDeleteConfirmation(null)}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  className="oa-button oa-button--danger"
                  onClick={handleConfirmDelete}
                >
                  Delete
                </button>
              </div>
            </div>
          </div>
        ) : null}

        {organizeConfirmation ? (
          <div className="thread-note-dialog-layer" onClick={() => setOrganizeConfirmation(null)}>
            <div
              className="thread-note-dialog thread-note-organize-modal"
              onClick={(event) => event.stopPropagation()}
            >
              <div className="thread-note-dialog-header">
                <div className="thread-note-dialog-copy">
                  <h2>
                    {organizeConfirmation === "selection"
                      ? "Organize selected text?"
                      : `Organize this ${currentSourceLabel === "Project notes" ? "project" : "thread"} note?`}
                  </h2>
                  <p>
                    {organizeConfirmation === "selection"
                      ? "This asks AI to organize only the text you selected. You will still review the draft before anything changes."
                      : `This asks AI to organize the current ${currentSourceLabel === "Project notes" ? "project" : "thread"} note. You will still review the draft before anything changes.`}
                  </p>
                </div>
                <button
                  type="button"
                  className="thread-note-icon-button thread-note-dialog-close"
                  onClick={() => setOrganizeConfirmation(null)}
                  aria-label="Close organize dialog"
                >
                  ×
                </button>
              </div>
              <div className="thread-note-dialog-footer">
                <button
                  type="button"
                  className="oa-button"
                  onClick={() => setOrganizeConfirmation(null)}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  className="oa-button oa-button--primary"
                  onClick={handleConfirmOrganize}
                >
                  Continue
                </button>
              </div>
            </div>
          </div>
        ) : null}
      </aside>
      <div ref={floatingLayerRef} className="thread-note-floating-layer">
        {isOpen && headingTagEditor && !mermaidPicker && !slashQuery ? (
          <div
            className="thread-note-heading-tag-menu thread-note-floating-menu"
            style={headingTagMenuStyle}
          >
            <div className="thread-note-heading-tag-copy">
              <span className="thread-note-heading-tag-title">Line format</span>
            </div>
            {currentMarkdownTagOption ? (
              <div className="thread-note-heading-tag-current">
                <span className="thread-note-heading-tag-current-eyebrow">Current tag</span>
                <div className="thread-note-heading-tag-current-card">
                  <span className="thread-note-heading-tag-current-token">
                    {currentMarkdownTagOption.token}
                  </span>
                  <span className="thread-note-heading-tag-current-copy">
                    <span className="thread-note-heading-tag-current-label">
                      {currentMarkdownTagOption.label}
                    </span>
                    <span className="thread-note-heading-tag-current-description">
                      {currentMarkdownTagOption.description}
                    </span>
                  </span>
                </div>
              </div>
            ) : null}
            <div className="thread-note-heading-tag-search-shell">
              <input
                ref={headingTagSearchRef}
                type="text"
                className="thread-note-heading-tag-search"
                value={headingTagSearch}
                onChange={(event) => setHeadingTagSearch(event.target.value)}
                placeholder="Search tags or blocks"
                aria-label="Search line format options"
              />
            </div>
            <div className="thread-note-heading-tag-scroll">
              {MARKDOWN_TAG_GROUPS.map((group) => {
                const options = filteredMarkdownTagOptions.filter(
                  (option) => option.groupId === group.id
                );
                if (options.length === 0) {
                  return null;
                }

                return (
                  <section key={group.id} className="thread-note-heading-tag-section">
                    <div className="thread-note-heading-tag-section-header">
                      {group.label}
                    </div>
                    <div className="thread-note-heading-tag-actions">
                      {options.map((option) => (
                        <button
                          key={option.id}
                          type="button"
                          className={[
                            "thread-note-heading-tag-button",
                            headingTagEditor.tag === option.id ? "is-selected" : "",
                          ]
                            .filter(Boolean)
                            .join(" ")}
                          onMouseDown={(event) => {
                            event.preventDefault();
                            handleApplyHeadingTag(option.id);
                          }}
                        >
                          <span className="thread-note-heading-tag-button-token">
                            {option.token}
                          </span>
                          <span className="thread-note-heading-tag-button-copy">
                            <span className="thread-note-heading-tag-button-label">
                              {option.label}
                            </span>
                            <span className="thread-note-heading-tag-button-description">
                              {option.description}
                            </span>
                          </span>
                        </button>
                      ))}
                    </div>
                  </section>
                );
              })}
              <section className="thread-note-heading-tag-section">
                {filteredMarkdownInsertOptions.length > 0 ? (
                  <>
                    <div className="thread-note-heading-tag-section-header">
                      Insert blocks
                    </div>
                    <div className="thread-note-heading-tag-insert-list">
                      {filteredMarkdownInsertOptions.map((option) => (
                        <button
                          key={option.id}
                          type="button"
                          className="thread-note-heading-tag-insert-button"
                          onMouseDown={(event) => {
                            event.preventDefault();
                            handleInsertMarkdownBlock(option.id);
                          }}
                        >
                          <span className="thread-note-heading-tag-insert-token">
                            {option.token}
                          </span>
                          <span className="thread-note-heading-tag-insert-copy">
                            <span className="thread-note-heading-tag-insert-label">
                              {option.label}
                            </span>
                            <span className="thread-note-heading-tag-insert-description">
                              {option.description}
                            </span>
                          </span>
                        </button>
                      ))}
                    </div>
                  </>
                ) : null}
              </section>
              {filteredMarkdownTagOptions.length === 0 &&
              filteredMarkdownInsertOptions.length === 0 ? (
                <div className="thread-note-heading-tag-empty">
                  No matching tag found.
                </div>
              ) : null}
            </div>
          </div>
        ) : null}

        {isOpen && mermaidPicker && mermaidPickerItems.length > 0 ? (
          <div
            className="thread-note-slash-menu thread-note-template-menu thread-note-floating-menu"
            style={floatingMenuStyle}
          >
            <div className="thread-note-template-menu-header">
              <div className="thread-note-template-menu-copy">
                <span className="thread-note-template-menu-title">{mermaidPickerTitle}</span>
                <span className="thread-note-template-menu-subtitle">
                  {mermaidPicker?.step === "template"
                    ? "Pick a starter, then edit the Mermaid text."
                    : "Choose the Mermaid chart style you want to start from."}
                </span>
              </div>
              {mermaidPicker.step === "template" && mermaidPicker.canGoBack ? (
                <button
                  type="button"
                  className="thread-note-template-menu-back"
                  onMouseDown={(event) => {
                    event.preventDefault();
                    setMermaidPicker({
                      ...mermaidPicker,
                      step: "type",
                      type: null,
                      canGoBack: false,
                    });
                    setSelectedMermaidIndex(0);
                  }}
                >
                  Back
                </button>
              ) : null}
            </div>

            {mermaidPickerItems.map((item, index) => (
              <button
                key={item.id}
                className={[
                  "thread-note-slash-option",
                  index === selectedMermaidIndex ? "is-selected" : "",
                ]
                  .filter(Boolean)
                  .join(" ")}
                type="button"
                onMouseDown={(event) => {
                  event.preventDefault();
                  if ("template" in item) {
                    applyMermaidTemplate(item.template);
                  } else {
                    openMermaidTemplateType(item.type);
                  }
                }}
              >
                <span className="thread-note-slash-option-label">{item.title}</span>
                <span className="thread-note-slash-option-copy">{item.description}</span>
                {"template" in item ? (
                  <span className="thread-note-template-chip">
                    {selectedMermaidType?.label ?? item.type}
                  </span>
                ) : null}
              </button>
            ))}
          </div>
        ) : isOpen && slashQuery ? (
          <div className="thread-note-slash-menu thread-note-floating-menu" style={floatingMenuStyle}>
            <div className="thread-note-slash-menu-header">
              <span className="thread-note-slash-menu-title">
                {mermaidEditingContext ? `${mermaidEditingContext.typeLabel} helpers` : "Command palette"}
              </span>
              <span className="thread-note-slash-menu-subtitle">
                Type after / to filter and press Enter to insert.
              </span>
            </div>
            <div className="thread-note-slash-search-row">
              <span className="thread-note-slash-search-label">Search</span>
              <span
                className={[
                  "thread-note-slash-search-chip",
                  slashSearchText ? "has-value" : "",
                ]
                  .filter(Boolean)
                  .join(" ")}
              >
                {slashSearchText ? `/${slashSearchText}` : "Type after /"}
              </span>
            </div>
            {groupedSlashCommands.length > 0 ? (
              <div className="thread-note-slash-groups">
                {(() => {
                  let visibleCommandIndex = -1;
                  return groupedSlashCommands.map((group) => {
                    const isExpanded =
                      isSearchingSlashCommands || Boolean(expandedSlashGroups[group.id]);
                    return (
                      <section
                        key={group.id}
                        className={[
                          "thread-note-slash-group",
                          isExpanded ? "is-expanded" : "",
                        ]
                          .filter(Boolean)
                          .join(" ")}
                        data-tone={group.tone}
                      >
                        <button
                          type="button"
                          className="thread-note-slash-group-toggle"
                          onMouseDown={(event) => event.preventDefault()}
                          onClick={() => toggleSlashGroup(group.id)}
                          aria-expanded={isExpanded}
                        >
                          <span className="thread-note-slash-group-copy">
                            <span className="thread-note-slash-group-topline">
                              <span className="thread-note-slash-group-chip">{group.label}</span>
                              <span className="thread-note-slash-group-count">
                                {group.commands.length}
                              </span>
                            </span>
                            {isSearchingSlashCommands ? (
                              <span className="thread-note-slash-group-subtitle">
                                Matching commands
                              </span>
                            ) : (
                              <span className="thread-note-slash-group-preview">
                                {group.commands.slice(0, 3).map((command) => (
                                  <span
                                    key={`${group.id}-${command.id}-preview`}
                                    className="thread-note-slash-mini-chip"
                                  >
                                    /{command.id}
                                  </span>
                                ))}
                                {group.commands.length > 3 ? (
                                  <span className="thread-note-slash-group-more">
                                    +{group.commands.length - 3}
                                  </span>
                                ) : null}
                              </span>
                            )}
                          </span>
                          <span
                            className={[
                              "thread-note-slash-group-chevron",
                              isExpanded ? "is-open" : "",
                            ]
                              .filter(Boolean)
                              .join(" ")}
                            aria-hidden="true"
                          >
                            ▾
                          </span>
                        </button>
                        {isExpanded ? (
                          <div className="thread-note-slash-group-options">
                            {group.commands.map((command) => {
                              visibleCommandIndex += 1;
                              const commandIndex = visibleCommandIndex;
                              return (
                                <button
                                  key={command.id}
                                  className={[
                                    "thread-note-slash-option",
                                    commandIndex === selectedSlashIndex ? "is-selected" : "",
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
                              );
                            })}
                          </div>
                        ) : null}
                      </section>
                    );
                  });
                })()}
              </div>
            ) : (
              <div className="thread-note-slash-menu-header">
                <span className="thread-note-slash-menu-title">No matches</span>
                <span className="thread-note-slash-menu-subtitle">
                  Nothing matches "/{slashSearchText}". Try a shorter word.
                </span>
              </div>
            )}
          </div>
        ) : null}
      </div>
    </>
  );
}

function makeCommand(
  id: string,
  label: string,
  subtitle: string,
  run: SlashCommand["run"],
  groupMeta: SlashCommandGroupMeta
): SlashCommand {
  return {
    id,
    label,
    subtitle,
    groupId: groupMeta.groupId,
    groupLabel: groupMeta.groupLabel,
    groupTone: groupMeta.groupTone,
    groupOrder: groupMeta.groupOrder,
    searchKeywords: groupMeta.searchKeywords,
    run,
  };
}

function PlusIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M8 3.25v9.5" />
      <path d="M3.25 8h9.5" />
    </svg>
  );
}

function TrashIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M3.5 4.75h9" />
      <path d="M6.1 4.75V3.4h3.8v1.35" />
      <path d="M4.9 4.75l.55 7.1h5.1l.55-7.1" />
    </svg>
  );
}

function EditIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M11.9 2.9a1.4 1.4 0 0 1 2 2L6.2 12.6l-3 0.6 0.6-3 8.1-7.3Z" />
      <path d="M10.7 4.1l1.2 1.2" />
    </svg>
  );
}

function ExpandIcon({ expanded }: { expanded: boolean }) {
  return expanded ? (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M6.4 4.7H4.7v1.7" />
      <path d="M9.6 4.7h1.7v1.7" />
      <path d="M11.3 9.6v1.7H9.6" />
      <path d="M6.4 11.3H4.7V9.6" />
    </svg>
  ) : (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M6 3.25H3.25V6" />
      <path d="M10 3.25h2.75V6" />
      <path d="M12.75 10v2.75H10" />
      <path d="M6 12.75H3.25V10" />
    </svg>
  );
}

function mermaidHighlightGrammar() {
  return {
    name: "Mermaid",
    keywords: {
      keyword:
        "graph flowchart sequenceDiagram classDiagram stateDiagram stateDiagram-v2 erDiagram journey gantt pie gitGraph mindmap timeline subgraph end click style class classDef linkStyle direction",
      literal: "TB TD BT RL LR true false",
    },
    contains: [
      {
        scope: "comment",
        begin: /%%/,
        end: /$/,
      },
      {
        scope: "string",
        begin: /"/,
        end: /"/,
      },
      {
        scope: "string",
        begin: /'/,
        end: /'/,
      },
      {
        scope: "number",
        begin: /\b\d+(?:\.\d+)?\b/,
      },
      {
        scope: "operator",
        begin: /-->|==>|-.->|---|--|==|-.|:::|:\|/,
      },
      {
        scope: "punctuation",
        begin: /[()[\]{};,]/,
      },
    ],
  };
}

function normalizeLineEndings(value: string): string {
  return value.replace(/\r\n/g, "\n");
}

function normalizeThreadNoteTitle(value?: string | null): string {
  const normalized = value?.trim();
  return normalized && normalized.length > 0 ? normalized : "Untitled note";
}

function createSlashGroupMeta(
  groupId: string,
  groupLabel: string,
  groupTone: SlashCommandGroupTone,
  groupOrder: number,
  searchKeywords: string[] = []
): SlashCommandGroupMeta {
  return {
    groupId,
    groupLabel,
    groupTone,
    groupOrder,
    searchKeywords,
  };
}

function mermaidStarterGroupMeta(type: MermaidTemplateType | null): SlashCommandGroupMeta {
  if (!type) {
    return createSlashGroupMeta(
      "mermaid-basics",
      "Mermaid basics",
      "mermaid",
      0,
      ["diagram", "starter", "template"]
    );
  }

  if (
    type === "flowchart" ||
    type === "sequence" ||
    type === "state" ||
    type === "journey" ||
    type === "gantt" ||
    type === "timeline" ||
    type === "gitgraph"
  ) {
    return createSlashGroupMeta(
      "mermaid-flow",
      "Flow diagrams",
      "flow",
      1,
      ["process", "steps", "timeline", "sequence"]
    );
  }

  if (
    type === "class" ||
    type === "er" ||
    type === "mindmap" ||
    type === "architecture" ||
    type === "block"
  ) {
    return createSlashGroupMeta(
      "mermaid-structure",
      "Structure diagrams",
      "structure",
      2,
      ["system", "data", "model", "architecture"]
    );
  }

  return createSlashGroupMeta(
    "mermaid-charts",
    "Charts & maps",
    "insight",
    3,
    ["chart", "pie", "quadrant"]
  );
}

function mermaidSnippetGroupMeta(
  type: MermaidTemplateType | null,
  snippet: MermaidSnippetDefinition
): SlashCommandGroupMeta {
  if (snippet.id === "comment") {
    return createSlashGroupMeta(
      "mermaid-helpers",
      "General helpers",
      "detail",
      90,
      ["comment", "helper"]
    );
  }

  if (!type) {
    return mermaidStarterGroupMeta(
      MERMAID_TEMPLATE_TYPES.find((option) => option.commandId === snippet.id)?.type ?? null
    );
  }

  switch (type) {
    case "flowchart":
      if (snippet.id === "step" || snippet.id === "decision") {
        return createSlashGroupMeta("flowchart-nodes", "Nodes", "structure", 0);
      }
      if (snippet.id === "link" || snippet.id === "branch") {
        return createSlashGroupMeta("flowchart-paths", "Paths", "flow", 1);
      }
      return createSlashGroupMeta("flowchart-layout", "Layout", "detail", 2);
    case "sequence":
      if (snippet.id === "participant" || snippet.id === "actor") {
        return createSlashGroupMeta("sequence-actors", "Actors", "structure", 0);
      }
      if (snippet.id === "message" || snippet.id === "reply") {
        return createSlashGroupMeta("sequence-messages", "Messages", "flow", 1);
      }
      return createSlashGroupMeta("sequence-logic", "Logic", "detail", 2);
    case "class":
      if (
        snippet.id === "classbox" ||
        snippet.id === "property" ||
        snippet.id === "method"
      ) {
        return createSlashGroupMeta("class-members", "Classes", "structure", 0);
      }
      return createSlashGroupMeta("class-links", "Relationships", "flow", 1);
    case "state":
      if (snippet.id === "state" || snippet.id === "choice") {
        return createSlashGroupMeta("state-states", "States", "structure", 0);
      }
      return createSlashGroupMeta("state-flow", "Flow", "flow", 1);
    case "er":
      if (snippet.id === "entity" || snippet.id === "field") {
        return createSlashGroupMeta("er-entities", "Entities", "structure", 0);
      }
      return createSlashGroupMeta("er-links", "Relationships", "flow", 1);
    case "journey":
      if (snippet.id === "title" || snippet.id === "section") {
        return createSlashGroupMeta("journey-setup", "Story setup", "structure", 0);
      }
      return createSlashGroupMeta("journey-steps", "Steps", "flow", 1);
    case "gantt":
      if (snippet.id === "title" || snippet.id === "section") {
        return createSlashGroupMeta("gantt-setup", "Timeline setup", "structure", 0);
      }
      return createSlashGroupMeta("gantt-work", "Tasks", "flow", 1);
    case "pie":
      if (snippet.id === "title") {
        return createSlashGroupMeta("pie-setup", "Chart setup", "detail", 0);
      }
      return createSlashGroupMeta("pie-slices", "Slices", "insight", 1);
    case "gitgraph":
      if (snippet.id === "commit") {
        return createSlashGroupMeta("gitgraph-commits", "Commits", "detail", 0);
      }
      return createSlashGroupMeta("gitgraph-branches", "Branches", "flow", 1);
    case "mindmap":
      if (snippet.id === "root") {
        return createSlashGroupMeta("mindmap-root", "Main topic", "structure", 0);
      }
      return createSlashGroupMeta("mindmap-branches", "Branches", "flow", 1);
    case "timeline":
      if (snippet.id === "title") {
        return createSlashGroupMeta("timeline-setup", "Timeline setup", "detail", 0);
      }
      if (snippet.id === "period") {
        return createSlashGroupMeta("timeline-periods", "Periods", "structure", 1);
      }
      return createSlashGroupMeta("timeline-events", "Events", "flow", 2);
    case "quadrant":
      if (snippet.id === "title" || snippet.id === "quadrant") {
        return createSlashGroupMeta("quadrant-axes", "Axes", "structure", 0);
      }
      return createSlashGroupMeta("quadrant-points", "Points", "insight", 1);
    case "architecture":
      if (snippet.id === "group") {
        return createSlashGroupMeta("architecture-groups", "Groups", "detail", 0);
      }
      if (snippet.id === "service" || snippet.id === "database") {
        return createSlashGroupMeta("architecture-nodes", "Nodes", "structure", 1);
      }
      return createSlashGroupMeta("architecture-links", "Links", "flow", 2);
    case "block":
      if (snippet.id === "columns") {
        return createSlashGroupMeta("block-layout", "Layout", "detail", 0);
      }
      if (snippet.id === "block" || snippet.id === "child") {
        return createSlashGroupMeta("block-blocks", "Blocks", "structure", 1);
      }
      return createSlashGroupMeta("block-links", "Links", "flow", 2);
    default:
      return createSlashGroupMeta("mermaid-helpers", "General helpers", "detail", 90);
  }
}

function matchesSlashCommand(command: SlashCommand, query: string): boolean {
  const haystack = [
    command.id,
    command.label,
    command.subtitle,
    command.groupLabel,
    ...(command.searchKeywords ?? []),
  ]
    .join(" ")
    .toLowerCase();

  return haystack.includes(query);
}

function groupSlashCommands(commands: SlashCommand[]): SlashCommandGroup[] {
  const groups = new Map<string, SlashCommandGroup>();

  commands.forEach((command) => {
    const existingGroup = groups.get(command.groupId);
    if (existingGroup) {
      existingGroup.commands.push(command);
      return;
    }

    groups.set(command.groupId, {
      id: command.groupId,
      label: command.groupLabel,
      tone: command.groupTone,
      order: command.groupOrder,
      commands: [command],
    });
  });

  return [...groups.values()].sort((left, right) => left.order - right.order);
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

function detectMermaidEditingContext(
  editor: Editor
): MermaidEditingContext | null {
  const { $from } = editor.state.selection;
  const parent = $from.parent;
  if (parent.type.name !== "codeBlock") {
    return null;
  }

  const language = `${parent.attrs.language ?? ""}`.trim();
  if (!isMermaidLanguage(language)) {
    return null;
  }

  const mermaidType = detectMermaidTemplateType(
    normalizeMermaidSource(language || "mermaid", parent.textContent ?? "")
  );
  const typeLabel = mermaidType
    ? MERMAID_TEMPLATE_TYPES.find((option) => option.type === mermaidType)?.label ??
      "Mermaid"
    : "Mermaid";

  return {
    type: mermaidType,
    typeLabel,
  };
}

function buildMermaidSnippetSlashCommands(
  context: MermaidEditingContext | null,
  insertSnippet: (
    editor: Editor,
    range: SlashQueryState,
    snippet: MermaidSnippetDefinition
  ) => void
): SlashCommand[] {
  return mermaidSnippetsForType(context?.type ?? null).map((snippet) =>
    makeCommand(
      snippet.id,
      snippet.label,
      snippet.subtitle,
      (editor, range) => insertSnippet(editor, range, snippet),
      mermaidSnippetGroupMeta(context?.type ?? null, snippet)
    )
  );
}

function insertMermaidSnippet(
  editor: Editor,
  range: SlashQueryState,
  snippet: MermaidSnippetDefinition
) {
  const indent = detectCurrentLineIndent(editor);
  const text = indentMultilineText(snippet.insertText, indent);
  editor.view.dispatch(editor.state.tr.insertText(text, range.replaceFrom, range.replaceTo));
  editor.chain().focus().run();
}

function insertCollapsibleSection(
  editor: Editor,
  range: SlashQueryState,
  level: 1 | 2 | 3
) {
  const title = level === 1 ? "New major section" : "New section";
  const body = "Add notes here.";
  const insertAt = range.replaceFrom;

  editor
    .chain()
    .focus()
    .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
    .insertContentAt(insertAt, [
      {
        type: "heading",
        attrs: { level },
        content: [{ type: "text", text: title }],
      },
      {
        type: "paragraph",
        content: [{ type: "text", text: body }],
      },
      {
        type: "paragraph",
      },
    ])
    .setTextSelection({
      from: insertAt + 1,
      to: insertAt + 1 + title.length,
    })
    .run();
}

function detectCurrentLineIndent(editor: Editor): string {
  const { $from } = editor.state.selection;
  const parentText = $from.parent.textContent ?? "";
  const beforeCaret = parentText.slice(0, $from.parentOffset);
  const currentLine = beforeCaret.split("\n").pop() ?? "";
  return currentLine.match(/^\s*/)?.[0] ?? "";
}

function indentMultilineText(text: string, indent: string): string {
  if (!indent) {
    return text;
  }

  return text
    .split("\n")
    .map((line) => `${indent}${line}`)
    .join("\n");
}

function measureMenuPosition(
  editor: Editor,
  container: HTMLDivElement | null,
  boundary: HTMLElement | null
): ThreadNoteMenuPosition {
  if (!container) {
    return DEFAULT_THREAD_NOTE_MENU_POSITION;
  }

  const editorView = resolveEditorView(editor);
  if (!editorView) {
    return DEFAULT_THREAD_NOTE_MENU_POSITION;
  }

  const menuGap = 12;
  const menuMargin = 16;
  const menuWidth = 372;
  const preferredMenuHeight = 430;
  const minimumMenuHeight = 140;
  const coords = editorView.coordsAtPos(editor.state.selection.from);
  const containerRect = container.getBoundingClientRect();
  const boundaryRect = boundary?.getBoundingClientRect() ?? containerRect;
  const relativeTop = coords.top - boundaryRect.top;
  const relativeBottom = coords.bottom - boundaryRect.top;
  const availableBelow = boundaryRect.height - relativeBottom - menuGap - menuMargin;
  const availableAbove = relativeTop - menuGap - menuMargin;
  const openAbove = availableBelow < minimumMenuHeight && availableAbove > availableBelow;
  const availableSpace = openAbove ? availableAbove : availableBelow;
  const containerMaxHeight = Math.max(72, boundaryRect.height - menuMargin * 2);
  const minimumUsableHeight = Math.min(minimumMenuHeight, containerMaxHeight);
  const maxHeight = Math.min(
    preferredMenuHeight,
    Math.max(availableSpace, minimumUsableHeight),
    containerMaxHeight
  );
  const left = clamp(
    coords.left - boundaryRect.left + 10,
    menuMargin,
    boundaryRect.width - menuWidth - menuMargin
  );

  if (openAbove) {
    const bottom = clamp(
      boundaryRect.height - relativeTop + menuGap,
      menuMargin,
      boundaryRect.height - menuMargin - maxHeight
    );

    return {
      left,
      top: null,
      bottom,
      maxHeight,
    };
  }

  const top = clamp(
    relativeBottom + menuGap,
    menuMargin,
    boundaryRect.height - menuMargin - maxHeight
  );

  return {
    left,
    top,
    bottom: null,
    maxHeight,
  };
}

function resolveMarkdownLineFromDOM(
  editor: Editor,
  lineElement: HTMLElement
): { selectionPos: number; insertAt: number; tag: MarkdownLineTag } | null {
  const editorView = resolveEditorView(editor);
  if (!editorView) {
    return null;
  }

  try {
    const domPosition = editorView.posAtDOM(lineElement, 0);
    const resolvedPosition = editor.state.doc.resolve(domPosition);
    const headingDepth = findAncestorDepth(resolvedPosition, "heading");
    if (headingDepth !== null) {
      const headingNode = resolvedPosition.node(headingDepth);
      return {
        selectionPos: resolvedPosition.start(headingDepth),
        insertAt: resolvedPosition.after(headingDepth),
        tag: headingLevelToTag(Number(headingNode.attrs.level ?? 1)),
      };
    }

    const codeBlockDepth = findAncestorDepth(resolvedPosition, "codeBlock");
    if (codeBlockDepth !== null) {
      return {
        selectionPos: resolvedPosition.start(codeBlockDepth),
        insertAt: resolvedPosition.after(codeBlockDepth),
        tag: "code",
      };
    }

    const listItemDepth = findAncestorDepth(resolvedPosition, "listItem");
    if (listItemDepth !== null) {
      if (findAncestorDepth(resolvedPosition, "taskList") !== null) {
        return {
          selectionPos: resolvedPosition.pos,
          insertAt: resolvedPosition.after(listItemDepth),
          tag: "todo",
        };
      }
      if (findAncestorDepth(resolvedPosition, "orderedList") !== null) {
        return {
          selectionPos: resolvedPosition.pos,
          insertAt: resolvedPosition.after(listItemDepth),
          tag: "numbered",
        };
      }
      if (findAncestorDepth(resolvedPosition, "bulletList") !== null) {
        return {
          selectionPos: resolvedPosition.pos,
          insertAt: resolvedPosition.after(listItemDepth),
          tag: "bullet",
        };
      }
    }

    const blockquoteDepth = findAncestorDepth(resolvedPosition, "blockquote");
    if (blockquoteDepth !== null) {
      return {
        selectionPos: resolvedPosition.pos,
        insertAt: resolvedPosition.after(blockquoteDepth),
        tag: "quote",
      };
    }

    const paragraphDepth = findAncestorDepth(resolvedPosition, "paragraph");
    if (paragraphDepth !== null) {
      return {
        selectionPos: resolvedPosition.pos,
        insertAt: resolvedPosition.after(paragraphDepth),
        tag: "paragraph",
      };
    }

    return {
      selectionPos: resolvedPosition.pos,
      insertAt: resolvedPosition.pos,
      tag: "paragraph",
    };
  } catch {
    return null;
  }
}

function applyMarkdownLineTag(
  editor: Editor,
  selectionPos: number,
  currentTag: MarkdownLineTag,
  nextTag: MarkdownLineTag
) {
  const chain = editor.chain().focus().setTextSelection(selectionPos);

  if (currentTag === nextTag) {
    chain.run();
    return;
  }

  if (currentTag === "bullet") {
    chain.toggleBulletList().run();
  } else if (currentTag === "numbered") {
    chain.toggleOrderedList().run();
  } else if (currentTag === "todo") {
    chain.toggleTaskList().run();
  } else if (currentTag === "quote") {
    chain.toggleBlockquote().run();
  } else if (currentTag === "code") {
    chain.clearNodes().run();
  }

  const nextChain = editor.chain().focus().setTextSelection(selectionPos);

  switch (nextTag) {
    case "paragraph":
      nextChain.setParagraph().run();
      return;
    case "heading1":
      nextChain.setNode("heading", { level: 1 }).run();
      return;
    case "heading2":
      nextChain.setNode("heading", { level: 2 }).run();
      return;
    case "heading3":
      nextChain.setNode("heading", { level: 3 }).run();
      return;
    case "bullet":
      nextChain.toggleBulletList().run();
      return;
    case "numbered":
      nextChain.toggleOrderedList().run();
      return;
    case "todo":
      nextChain.toggleTaskList().run();
      return;
    case "quote":
      nextChain.toggleBlockquote().run();
      return;
    case "code":
      nextChain.setCodeBlock().run();
      return;
    default:
      nextChain.run();
  }
}

function applyMarkdownInsertAction(
  editor: Editor,
  insertAt: number,
  action: MarkdownInsertAction
) {
  switch (action) {
    case "section":
      insertCollapsibleSection(editor, {
        query: "",
        replaceFrom: insertAt,
        replaceTo: insertAt,
      }, 2);
      return;
    case "divider":
      editor
        .chain()
        .focus()
        .setTextSelection(insertAt)
        .setHorizontalRule()
        .createParagraphNear()
        .run();
      return;
    case "table":
      editor
        .chain()
        .focus()
        .setTextSelection(insertAt)
        .insertTable({ rows: 3, cols: 2, withHeaderRow: true })
        .run();
      return;
    default:
      return;
  }
}

function matchesMarkdownPickerOption(
  option:
    | Pick<MarkdownLineTagOption, "token" | "label" | "description">
    | Pick<MarkdownInsertOption, "token" | "label" | "description">,
  query: string
): boolean {
  if (!query) {
    return true;
  }

  const haystack = [option.token, option.label, option.description]
    .join(" ")
    .toLowerCase();
  return haystack.includes(query);
}

function findAncestorDepth(
  resolvedPosition: ResolvedPos,
  nodeName: string
): number | null {
  for (let depth = resolvedPosition.depth; depth > 0; depth -= 1) {
    if (resolvedPosition.node(depth).type.name === nodeName) {
      return depth;
    }
  }

  return null;
}

function headingLevelToTag(level: number): MarkdownLineTag {
  if (level <= 1) {
    return "heading1";
  }
  if (level === 2) {
    return "heading2";
  }
  return "heading3";
}

function resolveHeadingTagMenuPosition(
  lineElement: HTMLElement,
  boundary: HTMLElement | null
): { left: number; top: number } {
  const menuWidth = 340;
  const menuHeight = 392;
  const menuGap = 10;
  const menuMargin = 16;
  const lineRect = lineElement.getBoundingClientRect();
  const boundaryRect = boundary?.getBoundingClientRect() ?? lineRect;
  const availableBelow = boundaryRect.height - (lineRect.bottom - boundaryRect.top) - menuMargin;
  const openAbove = availableBelow < menuHeight;

  return {
    left: clamp(
      lineRect.left - boundaryRect.left,
      menuMargin,
      boundaryRect.width - menuWidth - menuMargin
    ),
    top: openAbove
      ? clamp(
          lineRect.top - boundaryRect.top - menuHeight - menuGap,
          menuMargin,
          boundaryRect.height - menuHeight - menuMargin
        )
      : clamp(
          lineRect.bottom - boundaryRect.top + menuGap,
          menuMargin,
          boundaryRect.height - menuHeight - menuMargin
        ),
  };
}

function clamp(value: number, min: number, max: number): number {
  if (max <= min) {
    return min;
  }
  return Math.min(Math.max(value, min), max);
}

function resolveFloatingMenuStyle(menuPosition: ThreadNoteMenuPosition): CSSProperties {
  return {
    left: `${menuPosition.left}px`,
    top: menuPosition.top !== null ? `${menuPosition.top}px` : undefined,
    bottom: menuPosition.bottom !== null ? `${menuPosition.bottom}px` : undefined,
    maxHeight: `${menuPosition.maxHeight}px`,
  };
}

function resolveEditorView(editor: Editor): Editor["view"] | null {
  try {
    return editor.view;
  } catch {
    return null;
  }
}

function resolveEditorDOM(editor: Editor): HTMLElement | null {
  return resolveEditorView(editor)?.dom ?? null;
}
