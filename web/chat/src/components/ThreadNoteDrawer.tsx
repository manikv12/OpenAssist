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
import type { Node as ProseMirrorNode, ResolvedPos } from "@tiptap/pm/model";
import { TextSelection } from "@tiptap/pm/state";
import { all, createLowlight } from "lowlight";
import { ThreadNoteCodeBlock } from "./ThreadNoteCodeBlock";
import {
  findCollapsedHeadingSectionAtSelection,
  findHeadingSectionAtPosition,
  ThreadNoteCollapsibleHeading,
  uncollapseHeadingAtPosition,
  updateHeadingCollapsibleAtSelection,
} from "./ThreadNoteCollapsibleHeading";
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
import { MermaidDiagram } from "./MermaidDiagram";
import {
  buildInternalNoteHref,
  buildInternalNoteMarkdownLink,
  parseInternalNoteHref,
  type InternalNoteLinkTarget,
} from "./noteLinkUtils";

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
  headingCollapsible?: boolean;
  left: number;
  top: number;
}

interface NoteSelectionState {
  text: string;
  from: number;
  to: number;
}

interface NoteContextMenuState {
  x: number;
  y: number;
  selectedText: string;
  sourceKind: "selection" | "line";
  from: number;
  to: number;
  insertAt: number;
  cursorPos?: number;
  lineSelectionPos?: number;
  lineInsertAt?: number;
  lineTag?: MarkdownLineTag;
  lineHeadingCollapsible?: boolean;
  lineMenuLeft?: number;
  lineMenuTop?: number;
  linkTarget?: InternalNoteLinkTarget | null;
}

type NoteContextMenuLayer = "root" | "format" | "links" | "ai";
type ChartChoiceType = MermaidTemplateType | "auto";

interface MermaidEditingContext {
  type: MermaidTemplateType | null;
  typeLabel: string;
}

interface SummaryTarget {
  kind: "selection" | "whole";
  from?: number;
  to?: number;
  insertAt?: number;
}

interface DeleteConfirmationState {
  noteId: string;
  title: string;
}

interface NoteLinkPickerState {
  mode: "wrapSelection" | "insertInline";
  selectedLabel: string;
  from?: number;
  to?: number;
  insertAt: number;
}

interface ChartRequestComposerState {
  selectedText?: string;
  from?: number;
  to?: number;
  insertAt?: number;
  sourceKind: "selection" | "line" | "chatSelection" | "whole";
}

interface ResolvedMarkdownLine {
  selectionPos: number;
  insertAt: number;
  tag: MarkdownLineTag;
  replaceFrom: number;
  replaceTo: number;
  previewFrom: number;
  previewTo: number;
  text: string;
  headingCollapsible?: boolean;
}

interface SelectedListItemRange {
  typeName: "listItem" | "taskItem";
  pos: number;
  end: number;
  parentNode: ProseMirrorNode;
}

interface ThreadNoteSourceSection {
  source: NonNullable<ThreadNoteState["availableSources"]>[number];
  allNotes: ThreadNoteState["notes"];
  visibleNotes: ThreadNoteState["notes"];
}

interface ChartChoiceOption {
  type: ChartChoiceType;
  label: string;
  description: string;
}

interface VisibleTopLevelBlock {
  pos: number;
  node: ProseMirrorNode;
  insertAt: number;
}

const THREAD_NOTE_SAVE_DEBOUNCE_MS = 500;
const DEFAULT_THREAD_NOTE_MENU_POSITION: ThreadNoteMenuPosition = {
  left: 16,
  top: 16,
  bottom: null,
  maxHeight: 320,
};

const CHART_TYPE_CHOICES: ChartChoiceOption[] = [
  {
    type: "auto",
    label: "Let AI choose",
    description: "Best when you want the app to pick the clearest layout.",
  },
  ...MERMAID_TEMPLATE_TYPES.map((option) => ({
    type: option.type,
    label: option.label,
    description: option.description,
  })),
];

const CHART_TYPE_INSTRUCTIONS: Record<MermaidTemplateType, string> = {
  flowchart: "Use a flowchart with short boxes and clear arrows for the main steps.",
  sequence: "Use a sequence diagram that shows the key actors and message flow.",
  class: "Use a class diagram with the main entities, fields, and relationships.",
  state: "Use a state diagram that shows the important states and transitions.",
  er: "Use an ER diagram with tables and their relationships.",
  journey: "Use a journey diagram with the main stages and experience steps.",
  gantt: "Use a gantt chart with the work phases arranged over time.",
  pie: "Use a pie chart with only a few simple slices.",
  gitgraph: "Use a gitGraph chart showing the important branches, commits, and merges.",
  mindmap: "Use a mindmap with one clear center topic and short branches.",
  timeline: "Use a timeline with events in chronological order.",
  quadrant: "Use a quadrant chart with two clear axes and positioned items.",
  architecture: "Use an architecture-beta diagram with high-level system parts and connections.",
  block: "Use a block-beta diagram with simple grouped blocks and links.",
};

function noteSourceKey(ownerKind: string, ownerId: string): string {
  return `${ownerKind}:${ownerId}`;
}

function noteSourceLabelForOwner(ownerKind?: string | null): string {
  return ownerKind === "project" ? "Project notes" : "Thread notes";
}

function chartChoiceLabel(type: ChartChoiceType): string {
  return CHART_TYPE_CHOICES.find((option) => option.type === type)?.label ?? "Chart";
}

function buildChartStyleInstruction(
  chartType: ChartChoiceType,
  extraInstruction: string
): string | undefined {
  const normalizedExtraInstruction = extraInstruction.trim();
  const typeInstruction =
    chartType === "auto" ? "" : CHART_TYPE_INSTRUCTIONS[chartType];

  if (!typeInstruction && !normalizedExtraInstruction) {
    return undefined;
  }

  if (typeInstruction && normalizedExtraInstruction) {
    return `${typeInstruction} Also: ${normalizedExtraInstruction}`;
  }

  return typeInstruction || normalizedExtraInstruction;
}

function chartSourceLabel(sourceKind: ChartRequestComposerState["sourceKind"]): string {
  switch (sourceKind) {
    case "chatSelection":
      return "Selected chat text";
    case "whole":
      return "Current note";
    case "line":
      return "Chosen note line";
    case "selection":
    default:
      return "Selected note text";
  }
}

function detectChartTypeFromDraftMarkdown(markdown: string): MermaidTemplateType | null {
  const mermaidMatch = markdown.match(/```mermaid\s*([\s\S]*?)```/i);
  if (!mermaidMatch) {
    return null;
  }

  return detectMermaidTemplateType(
    normalizeMermaidSource("mermaid", mermaidMatch[1] ?? "")
  );
}

function ChartTypePreview({ type }: { type: ChartChoiceType }) {
  const stroke = {
    stroke: "currentColor",
    strokeWidth: 2.2,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    fill: "none",
  };

  const dot = (cx: number, cy: number, radius = 2.8) => (
    <circle cx={cx} cy={cy} r={radius} fill="currentColor" />
  );

  switch (type) {
    case "auto":
      return (
        <svg viewBox="0 0 96 56" className="thread-note-chart-choice-preview" aria-hidden="true">
          <path d="M18 28h16M62 18h16M62 38h16" {...stroke} />
          <rect x="34" y="18" width="28" height="20" rx="8" {...stroke} />
          {dot(18, 28)}
          {dot(78, 18)}
          {dot(78, 38)}
        </svg>
      );
    case "flowchart":
      return (
        <svg viewBox="0 0 96 56" className="thread-note-chart-choice-preview" aria-hidden="true">
          <rect x="10" y="16" width="22" height="14" rx="5" {...stroke} />
          <rect x="38" y="16" width="22" height="14" rx="5" {...stroke} />
          <rect x="66" y="16" width="20" height="14" rx="5" {...stroke} />
          <path d="M32 23h6M60 23h6M64 23l-4-3M64 23l-4 3" {...stroke} />
        </svg>
      );
    case "sequence":
      return (
        <svg viewBox="0 0 96 56" className="thread-note-chart-choice-preview" aria-hidden="true">
          <path d="M20 10v36M48 10v36M76 10v36" {...stroke} />
          <path d="M20 18h28M48 30h28" {...stroke} />
          <path d="M46 18l-4-3M46 18l-4 3M74 30l-4-3M74 30l-4 3" {...stroke} />
        </svg>
      );
    case "class":
    case "er":
      return (
        <svg viewBox="0 0 96 56" className="thread-note-chart-choice-preview" aria-hidden="true">
          <rect x="8" y="12" width="30" height="30" rx="6" {...stroke} />
          <rect x="58" y="12" width="30" height="30" rx="6" {...stroke} />
          <path d="M8 22h30M58 22h30M38 27h20" {...stroke} />
          <path d="M54 27l4-3M54 27l4 3" {...stroke} />
        </svg>
      );
    case "state":
      return (
        <svg viewBox="0 0 96 56" className="thread-note-chart-choice-preview" aria-hidden="true">
          <rect x="10" y="20" width="22" height="16" rx="8" {...stroke} />
          <rect x="38" y="10" width="22" height="16" rx="8" {...stroke} />
          <rect x="66" y="20" width="20" height="16" rx="8" {...stroke} />
          <path d="M32 28h6M60 18h6M58 24l6 6" {...stroke} />
        </svg>
      );
    case "journey":
      return (
        <svg viewBox="0 0 96 56" className="thread-note-chart-choice-preview" aria-hidden="true">
          <path d="M12 40l20-16 18 6 16-14 18 4" {...stroke} />
          {dot(12, 40)}
          {dot(32, 24)}
          {dot(50, 30)}
          {dot(66, 16)}
          {dot(84, 20)}
        </svg>
      );
    case "gantt":
      return (
        <svg viewBox="0 0 96 56" className="thread-note-chart-choice-preview" aria-hidden="true">
          <path d="M20 12v30M36 12v30M52 12v30M68 12v30" {...stroke} />
          <path d="M22 18h30M36 30h34M28 40h20" {...stroke} />
        </svg>
      );
    case "pie":
      return (
        <svg viewBox="0 0 96 56" className="thread-note-chart-choice-preview" aria-hidden="true">
          <circle cx="48" cy="28" r="18" {...stroke} />
          <path d="M48 28V10M48 28l14 10M48 28 34 42" {...stroke} />
        </svg>
      );
    case "gitgraph":
      return (
        <svg viewBox="0 0 96 56" className="thread-note-chart-choice-preview" aria-hidden="true">
          <path d="M16 16v22M40 14v26M64 10v30M80 24v16" {...stroke} />
          <path d="M16 24h24M40 20h24M64 28h16" {...stroke} />
          <path d="M40 20c6 0 8 4 8 8M64 20c6 0 8 4 8 8" {...stroke} />
          {dot(16, 24)}
          {dot(40, 20)}
          {dot(64, 20)}
          {dot(80, 28)}
        </svg>
      );
    case "mindmap":
      return (
        <svg viewBox="0 0 96 56" className="thread-note-chart-choice-preview" aria-hidden="true">
          <rect x="34" y="18" width="28" height="20" rx="8" {...stroke} />
          <path d="M34 24H18M34 32H16M62 24h16M62 32h18" {...stroke} />
          {dot(16, 32, 2.4)}
          {dot(18, 24, 2.4)}
          {dot(78, 24, 2.4)}
          {dot(80, 32, 2.4)}
        </svg>
      );
    case "timeline":
      return (
        <svg viewBox="0 0 96 56" className="thread-note-chart-choice-preview" aria-hidden="true">
          <path d="M12 28h72" {...stroke} />
          <path d="M24 28v-10M48 28v10M72 28v-8" {...stroke} />
          {dot(24, 28)}
          {dot(48, 28)}
          {dot(72, 28)}
        </svg>
      );
    case "quadrant":
      return (
        <svg viewBox="0 0 96 56" className="thread-note-chart-choice-preview" aria-hidden="true">
          <path d="M48 8v40M18 28h60" {...stroke} />
          {dot(34, 18)}
          {dot(62, 18)}
          {dot(38, 38)}
          {dot(68, 34)}
        </svg>
      );
    case "architecture":
    case "block":
      return (
        <svg viewBox="0 0 96 56" className="thread-note-chart-choice-preview" aria-hidden="true">
          <rect x="34" y="8" width="28" height="14" rx="5" {...stroke} />
          <rect x="10" y="32" width="24" height="14" rx="5" {...stroke} />
          <rect x="38" y="32" width="20" height="14" rx="5" {...stroke} />
          <rect x="62" y="32" width="24" height="14" rx="5" {...stroke} />
          <path d="M48 22v8M22 32l8-8h36l8 8" {...stroke} />
        </svg>
      );
    default:
      return null;
  }
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
    HEADING_GROUP_META,
    ["h1"]
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
    HEADING_GROUP_META,
    ["h2"]
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
    HEADING_GROUP_META,
    ["h3"]
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
  const isNotesWorkspace = state?.presentation === "notesWorkspace";
  const ownerKind =
    state?.ownerKind ??
    (state?.notesScope === "project" ? "project" : state?.notesScope === "thread" ? "thread" : null);
  const ownerId = state?.ownerId ?? state?.workspaceProjectId ?? null;
  const isProjectFullScreen = state?.presentation === "projectFullScreen";
  const isFullScreenWorkspace = isProjectFullScreen || isNotesWorkspace;
  const isAvailable = isNotesWorkspace
    ? Boolean(state?.isOpen)
    : Boolean(ownerKind && ownerId && state?.canEdit);
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
        isFullScreenWorkspace ? "is-project-fullscreen" : "",
        isNotesWorkspace ? "is-notes-workspace" : "",
      ]
        .filter(Boolean)
        .join(" ")}
    >
      {isAvailable && !isOpen && !isNotesWorkspace ? (
        <button
          className="thread-note-handle-hitbox"
          type="button"
          aria-label={`Open ${noteSourceLabelForOwner(ownerKind).toLowerCase().replace("notes", "note")}`}
          aria-expanded={false}
          onClick={handleToggleDrawer}
        >
          <span className="thread-note-handle-chevron" aria-hidden="true">
            ‹
          </span>
        </button>
      ) : null}

      {isOpen && ownerKind ? (
        <ThreadNoteDrawerOpenContent
          key={`${ownerKind}:${ownerId ?? "no-owner"}:${threadId ?? "no-thread"}:${state?.presentation ?? "drawer"}`}
          state={state}
          threadId={threadId}
          ownerKind={ownerKind}
          ownerId={ownerId ?? ""}
          isProjectFullScreen={isProjectFullScreen}
          isNotesWorkspace={isNotesWorkspace}
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
  isNotesWorkspace: boolean;
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
  isNotesWorkspace,
  layerRef,
  placeholderText,
  statusLabel,
  onDispatchCommand,
}: ThreadNoteDrawerOpenContentProps) {
  const isFullScreenWorkspace = isProjectFullScreen || isNotesWorkspace;
  const noteId = state?.selectedNoteId ?? null;
  const drawerRef = useRef<HTMLElement | null>(null);
  const floatingLayerRef = useRef<HTMLDivElement | null>(null);
  const editorBodyRef = useRef<HTMLDivElement>(null);
  const noteContextMenuRef = useRef<HTMLDivElement | null>(null);
  const headingTagSearchRef = useRef<HTMLInputElement | null>(null);
  const selectorButtonRef = useRef<HTMLButtonElement | null>(null);
  const selectorSearchInputRef = useRef<HTMLInputElement | null>(null);
  const noteLinkSearchInputRef = useRef<HTMLInputElement | null>(null);
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
  const [noteContextMenu, setNoteContextMenu] = useState<NoteContextMenuState | null>(null);
  const [noteContextMenuLayer, setNoteContextMenuLayer] = useState<NoteContextMenuLayer>("root");
  const [noteContextMenuPosition, setNoteContextMenuPosition] = useState<{
    x: number;
    y: number;
  } | null>(null);
  const [noteLinkPicker, setNoteLinkPicker] = useState<NoteLinkPickerState | null>(null);
  const [noteLinkSearch, setNoteLinkSearch] = useState("");
  const [isLinkedNotesOpen, setIsLinkedNotesOpen] = useState(false);
  const [isGraphOpen, setIsGraphOpen] = useState(false);
  const [linkNotice, setLinkNotice] = useState<string | null>(null);
  const [chartRequestComposer, setChartRequestComposer] =
    useState<ChartRequestComposerState | null>(null);
  const [selectedChartType, setSelectedChartType] = useState<ChartChoiceType>("auto");
  const [chartStyleInstruction, setChartStyleInstruction] = useState("");
  const [isChartDraftModalDismissed, setIsChartDraftModalDismissed] = useState(false);
  const [isHistoryPanelOpen, setIsHistoryPanelOpen] = useState(false);
  const notes = state?.notes ?? [];
  const historyVersions = state?.historyVersions ?? [];
  const recentlyDeletedNotes = state?.recentlyDeletedNotes ?? [];
  const hasRecoveryItems = historyVersions.length > 0 || recentlyDeletedNotes.length > 0;

  const isOpen = Boolean(state?.isOpen && state?.canEdit);
  const noteOwnerKey = `${ownerKind}:${ownerId}`;
  const noteKey = `${noteOwnerKey}:${noteId ?? "none"}`;
  const canCloseDrawer = true;
  const isExpanded = Boolean(state?.isExpanded);
  const aiDraftPreview = state?.aiDraftPreview ?? null;
  const aiDraftMode = state?.aiDraftMode ?? aiDraftPreview?.mode ?? null;
  const hasActiveAIDraft = Boolean(aiDraftPreview || (state?.isGeneratingAIDraft && aiDraftMode));
  const activeAIDraftMode = aiDraftPreview?.mode ?? aiDraftMode ?? "organize";
  const activeAIDraftSourceKind =
    aiDraftPreview?.sourceKind ??
    (activeAIDraftMode === "chart" ? "chatSelection" : noteSelection?.text ? "selection" : "whole");
  const isChartDraft = activeAIDraftMode === "chart";
  const isChartRequestComposerOpen = Boolean(chartRequestComposer);
  const hasActiveChartDraft = isChartDraft && hasActiveAIDraft;
  const isAIDraftError = Boolean(aiDraftPreview?.isError);
  const showAIDraftModal = isChartRequestComposerOpen
    ? true
    : isChartDraft
    ? hasActiveChartDraft && !isChartDraftModalDismissed
    : hasActiveAIDraft;
  const showChartDraftStatusCard = hasActiveChartDraft && isChartDraftModalDismissed;
  const shouldBlockDrawerEscape =
    isChartRequestComposerOpen ||
    (hasActiveAIDraft && activeAIDraftMode !== "chart");
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
        headingCollapsible: markdownLine.headingCollapsible,
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
        nextTag,
        headingTagEditor.headingCollapsible
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

  const closeNoteContextMenu = useCallback(() => {
    setNoteContextMenu(null);
    setNoteContextMenuLayer("root");
    setNoteContextMenuPosition(null);
  }, []);

  const showLinkNotice = useCallback((message: string) => {
    setLinkNotice(message);
  }, []);

  const openInternalNoteTarget = useCallback(
    (target: InternalNoteLinkTarget | null | undefined) => {
      if (!target) {
        return;
      }

      const targetExists = notes.some(
        (note) =>
          note.ownerKind === target.ownerKind &&
          note.ownerId === target.ownerId &&
          note.id === target.noteId
      );
      if (!targetExists) {
        showLinkNotice("That linked note no longer exists.");
        return;
      }

      closeNoteContextMenu();
      setNoteLinkPicker(null);
      setNoteLinkSearch("");
      commitSave();
      dispatchThreadNoteCommand("openLinkedNote", {
        ownerKind: target.ownerKind,
        ownerId: target.ownerId,
        noteId: target.noteId,
      });
    },
    [closeNoteContextMenu, commitSave, dispatchThreadNoteCommand, notes, showLinkNotice]
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
      setIsLinkedNotesOpen(false);
      setIsSelectorOpen(false);
      setSelectorFilter("");
      setIsRenamingTitle(false);
      setRenameTitleDraft(normalizeThreadNoteTitle(state?.selectedNoteTitle));
      setDeleteConfirmation(null);
      setOrganizeConfirmation(null);
      setHeadingTagEditor(null);
      setSlashQuery(null);
      setMermaidEditingContext(null);
      setNoteContextMenu(null);
      setNoteContextMenuPosition(null);
      setSelectedSlashIndex(0);
      setExpandedSlashGroups({});
      setMermaidPicker(null);
      setSelectedMermaidIndex(0);
      setIsInTable(false);
      setNoteSelection(null);
      setIsHistoryPanelOpen(false);
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
    isNotesWorkspace,
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

      window.requestAnimationFrame(() => {
        const selectedText = window.getSelection()?.toString().trim() ?? "";
        if (selectedText) {
          return;
        }
        openHeadingTagEditor(lineElement);
      });
    };

    const handleEditorContextMenu = (event: MouseEvent) => {
      const target = event.target;
      if (!(target instanceof Element)) {
        return;
      }

      if (!editorBodyRef.current?.contains(target)) {
        return;
      }

      const lineElement = target.closest<HTMLElement>(
        ".thread-note-heading-node, .thread-note-code-block-node:not(.is-mermaid), p, li, blockquote"
      );
      const clickedAnchor = target.closest<HTMLAnchorElement>("a[href]");
      const linkTarget = parseInternalNoteHref(clickedAnchor?.getAttribute("href"));
      const resolvedLine = lineElement
        ? resolveMarkdownLineFromDOM(editor, lineElement)
        : null;
      const lineMenuPosition = lineElement
        ? resolveHeadingTagMenuPosition(lineElement, layerRef.current)
        : null;

      const selectedText = noteSelection?.text?.trim() || "";
      if (selectedText && noteSelection?.from && noteSelection?.to) {
        event.preventDefault();
        setHeadingTagEditor(null);
        setSlashQuery(null);
        setMermaidEditingContext(null);
        setMermaidPicker(null);
        setNoteContextMenuLayer("root");
        setNoteContextMenu({
          x: event.clientX,
          y: event.clientY,
          selectedText,
          sourceKind: "selection",
          from: noteSelection.from,
          to: noteSelection.to,
          insertAt: resolvedLine?.insertAt ?? noteSelection.to,
          cursorPos: editor.state.selection.from,
          lineSelectionPos: resolvedLine?.selectionPos,
          lineInsertAt: resolvedLine?.insertAt,
          lineTag: resolvedLine?.tag,
          lineHeadingCollapsible: resolvedLine?.headingCollapsible,
          lineMenuLeft: lineMenuPosition?.left,
          lineMenuTop: lineMenuPosition?.top,
          linkTarget,
        });
        setNoteContextMenuPosition(null);
        return;
      }

      if (!lineElement) {
        return;
      }

      const lineText = resolvedLine?.text.trim() ?? "";
      if (!resolvedLine || !lineText) {
        return;
      }

      event.preventDefault();
      setHeadingTagEditor(null);
      setSlashQuery(null);
      setMermaidEditingContext(null);
      setMermaidPicker(null);
      setNoteContextMenuLayer("root");
      setNoteContextMenu({
        x: event.clientX,
        y: event.clientY,
        selectedText: lineText,
        sourceKind: "line",
        from: resolvedLine.replaceFrom,
        to: resolvedLine.replaceTo,
        insertAt: resolvedLine.insertAt,
        cursorPos: editor.state.selection.from,
        lineSelectionPos: resolvedLine.selectionPos,
        lineInsertAt: resolvedLine.insertAt,
        lineTag: resolvedLine.tag,
        lineHeadingCollapsible: resolvedLine.headingCollapsible,
        lineMenuLeft: lineMenuPosition?.left,
        lineMenuTop: lineMenuPosition?.top,
        linkTarget,
      });
      setNoteContextMenuPosition(null);
    };

    const handleEditorClick = (event: MouseEvent) => {
      const target = event.target;
      if (!(target instanceof Element)) {
        return;
      }

      const anchor = target.closest<HTMLAnchorElement>("a[href]");
      const linkTarget = parseInternalNoteHref(anchor?.getAttribute("href"));
      if (!linkTarget) {
        if (
          state?.viewMode === "edit" &&
          focusBlankEditorSpace(editor, target, event, editorBodyRef.current)
        ) {
          return;
        }
        return;
      }

      const shouldOpenLink =
        isNotesWorkspace || state?.viewMode !== "edit" || event.metaKey || event.ctrlKey;
      if (!shouldOpenLink) {
        return;
      }

      event.preventDefault();
      event.stopPropagation();
      openInternalNoteTarget(linkTarget);

      return;
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
      if (activeSlashQuery && activeCommands.length > 0) {
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
          return;
        }
      }

      if (
        event.key === "Tab" &&
        !event.altKey &&
        !event.ctrlKey &&
        !event.metaKey &&
        handleSelectedListIndent(editor, event.shiftKey ? "outdent" : "indent")
      ) {
        event.preventDefault();
        event.stopPropagation();
        refreshSlashQuery(editor);
        return;
      }

      if (
        event.key === "Enter" &&
        !event.altKey &&
        !event.ctrlKey &&
        !event.metaKey
      ) {
        const shouldInsertOutsideCollapsedSection = !event.shiftKey;
        const collapsedSection =
          shouldInsertOutsideCollapsedSection
            ? findCollapsedHeadingSectionAtSelection(editor.state)
            : null;
        const headingSection = event.shiftKey
          ? findHeadingSectionAtSelection(editor)
          : null;
        const sectionEnd = collapsedSection?.sectionEnd ?? headingSection?.sectionEnd;

        if (sectionEnd !== undefined) {
          event.preventDefault();
          event.stopPropagation();
          insertParagraphAfterSection(editor, sectionEnd);
          return;
        }
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
      editorDom.addEventListener("click", handleEditorClick, true);
      editorDom.addEventListener("dblclick", handleLineDoubleClick);
      editorDom.addEventListener("contextmenu", handleEditorContextMenu);
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
      editorDom?.removeEventListener("click", handleEditorClick, true);
      editorDom?.removeEventListener("dblclick", handleLineDoubleClick);
      editorDom?.removeEventListener("contextmenu", handleEditorContextMenu);
    };
  }, [
    applyMermaidTemplate,
    commitSave,
    closeNoteContextMenu,
    editor,
    isNotesWorkspace,
    openHeadingTagEditor,
    mermaidPickerItems,
    noteId,
    noteSelection?.from,
    noteSelection?.text,
    noteSelection?.to,
    onDispatchCommand,
    openMermaidTemplateType,
    openInternalNoteTarget,
    ownerId,
    ownerKind,
    refreshSlashQuery,
    state?.viewMode,
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
      setNoteContextMenu(null);
      setNoteContextMenuPosition(null);
      setNoteLinkPicker(null);
      setNoteLinkSearch("");
      setIsGraphOpen(false);
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
      return;
    }

    if (noteLinkPicker) {
      noteLinkSearchInputRef.current?.focus();
      noteLinkSearchInputRef.current?.select();
    }
  }, [isRenamingTitle, isSelectorOpen, noteLinkPicker]);

  useEffect(() => {
    if (!linkNotice) {
      return;
    }

    const timeout = window.setTimeout(() => {
      setLinkNotice(null);
    }, 3200);

    return () => window.clearTimeout(timeout);
  }, [linkNotice]);

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

  useEffect(() => {
    if (!noteContextMenu || !noteContextMenuRef.current) {
      return;
    }

    const rect = noteContextMenuRef.current.getBoundingClientRect();
    const padding = 12;
    const nextX = Math.max(
      padding,
      Math.min(noteContextMenu.x, window.innerWidth - rect.width - padding)
    );
    const nextY = Math.max(
      padding,
      Math.min(noteContextMenu.y, window.innerHeight - rect.height - padding)
    );

    if (
      !noteContextMenuPosition ||
      noteContextMenuPosition.x !== nextX ||
      noteContextMenuPosition.y !== nextY
    ) {
      setNoteContextMenuPosition({ x: nextX, y: nextY });
    }
  }, [noteContextMenu, noteContextMenuPosition]);

  useEffect(() => {
    if (!noteContextMenu) {
      return;
    }

    const handlePointerDown = (event: PointerEvent) => {
      if (!noteContextMenuRef.current?.contains(event.target as Node)) {
        closeNoteContextMenu();
      }
    };

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        closeNoteContextMenu();
      }
    };

    const handleViewportChange = () => {
      closeNoteContextMenu();
    };

    document.addEventListener("pointerdown", handlePointerDown);
    document.addEventListener("keydown", handleKeyDown);
    document.addEventListener("scroll", handleViewportChange, true);
    window.addEventListener("resize", handleViewportChange);
    window.addEventListener("blur", handleViewportChange);

    return () => {
      document.removeEventListener("pointerdown", handlePointerDown);
      document.removeEventListener("keydown", handleKeyDown);
      document.removeEventListener("scroll", handleViewportChange, true);
      window.removeEventListener("resize", handleViewportChange);
      window.removeEventListener("blur", handleViewportChange);
    };
  }, [closeNoteContextMenu, noteContextMenu]);

  const handleCloseDrawer = useCallback(() => {
    if (!canCloseDrawer) {
      return;
    }
    commitSave();
    editor?.commands.blur();
    setIsSelectorOpen(false);
    setSelectorFilter("");
    setIsRenamingTitle(false);
    setHeadingTagEditor(null);
    setSlashQuery(null);
    setMermaidEditingContext(null);
    setMermaidPicker(null);
    closeNoteContextMenu();
    dispatchThreadNoteCommand("setOpen", { isOpen: false });
  }, [canCloseDrawer, closeNoteContextMenu, commitSave, dispatchThreadNoteCommand, editor]);

  useEffect(() => {
    if (!isOpen || !canCloseDrawer) {
      return;
    }

    const handlePointerDown = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) {
        return;
      }
      const targetElement = target instanceof Element ? target : null;
      const clickedInsideDrawer = Boolean(drawerRef.current?.contains(target));
      const clickedInsideFloatingLayer = Boolean(floatingLayerRef.current?.contains(target));
      const clickedEditableMarkdownLine =
        Boolean(
          targetElement?.closest(
            ".thread-note-heading-node, .thread-note-code-block-node:not(.is-mermaid), p, li, blockquote"
          )
        );
      const clickedSelectorMenu = Boolean(targetElement?.closest(".thread-note-selector-menu"));
      const clickedSelectorTrigger = Boolean(selectorButtonRef.current?.contains(target));

      if (
        isSelectorOpen &&
        !clickedSelectorMenu &&
        !clickedSelectorTrigger
      ) {
        setIsSelectorOpen(false);
        setSelectorFilter("");
      }

      if (
        headingTagEditor &&
        !clickedInsideFloatingLayer &&
        !clickedEditableMarkdownLine
      ) {
        setHeadingTagEditor(null);
      }
    };

    window.addEventListener("pointerdown", handlePointerDown, true);
    return () => {
      window.removeEventListener("pointerdown", handlePointerDown, true);
    };
  }, [canCloseDrawer, headingTagEditor, isOpen, isSelectorOpen]);

  useEffect(() => {
    if (!isOpen || !canCloseDrawer || shouldBlockDrawerEscape) {
      return;
    }

    const handleDoubleClick = (event: MouseEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) {
        return;
      }
      const targetElement = target instanceof Element ? target : null;
      const clickedInsideDrawer = Boolean(drawerRef.current?.contains(target));
      const clickedInsideFloatingLayer = Boolean(floatingLayerRef.current?.contains(target));
      const clickedInteractiveChatContent = Boolean(
        targetElement?.closest(
          "button, a, input, textarea, select, [contenteditable='true']"
        )
      );
      const clickedChatBackdrop = Boolean(
        targetElement?.closest(".chat-shell, .chat-container, .chat-messages")
      );

      if (clickedInsideDrawer || clickedInsideFloatingLayer) {
        return;
      }
      if (!clickedChatBackdrop || clickedInteractiveChatContent) {
        return;
      }
      handleCloseDrawer();
    };

    window.addEventListener("dblclick", handleDoubleClick, true);
    return () => {
      window.removeEventListener("dblclick", handleDoubleClick, true);
    };
  }, [canCloseDrawer, handleCloseDrawer, isOpen, shouldBlockDrawerEscape]);

  useEffect(() => {
    if (!isOpen || shouldBlockDrawerEscape || !canCloseDrawer) {
      return;
    }

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") {
        return;
      }
      event.preventDefault();
      if (noteContextMenu) {
        closeNoteContextMenu();
        return;
      }
      if (headingTagEditor) {
        setHeadingTagEditor(null);
        return;
      }
      if (noteLinkPicker) {
        setNoteLinkPicker(null);
        setNoteLinkSearch("");
        return;
      }
      if (isGraphOpen) {
        setIsGraphOpen(false);
        return;
      }
      if (isHistoryPanelOpen) {
        setIsHistoryPanelOpen(false);
        return;
      }
      if (chartRequestComposer) {
        setChartRequestComposer(null);
        return;
      }
      handleCloseDrawer();
    };

    window.addEventListener("keydown", handleKeyDown, true);
    return () => {
      window.removeEventListener("keydown", handleKeyDown, true);
    };
  }, [
    canCloseDrawer,
    chartRequestComposer,
    closeNoteContextMenu,
    handleCloseDrawer,
    headingTagEditor,
    isHistoryPanelOpen,
    isGraphOpen,
    isOpen,
    noteContextMenu,
    noteLinkPicker,
    shouldBlockDrawerEscape,
  ]);

  useEffect(() => {
    if (
      chartRequestComposer ||
      (aiDraftMode === "chart" && (aiDraftPreview || state?.isGeneratingAIDraft))
    ) {
      return;
    }
    setSelectedChartType("auto");
    setChartStyleInstruction("");
  }, [aiDraftMode, aiDraftPreview, chartRequestComposer, state?.isGeneratingAIDraft]);

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
    setChartRequestComposer(null);
    setSelectedChartType("auto");
    setChartStyleInstruction("");
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

  const handleToggleHistoryPanel = useCallback(() => {
    commitSave();
    setIsSelectorOpen(false);
    setSelectorFilter("");
    setIsRenamingTitle(false);
    setIsHistoryPanelOpen((current) => !current);
  }, [commitSave]);

  const handleRestoreHistoryVersion = useCallback(
    (historyVersionId: string) => {
      if (!historyVersionId) {
        return;
      }
      commitSave();
      dispatchThreadNoteCommand("restoreHistoryVersion", { historyVersionId });
      setIsHistoryPanelOpen(false);
    },
    [commitSave, dispatchThreadNoteCommand]
  );

  const handleDeleteHistoryVersion = useCallback(
    (historyVersionId: string) => {
      if (!historyVersionId) {
        return;
      }
      dispatchThreadNoteCommand("deleteHistoryVersion", { historyVersionId });
    },
    [dispatchThreadNoteCommand]
  );

  const handleRestoreDeletedNote = useCallback(
    (deletedNoteId: string) => {
      if (!deletedNoteId) {
        return;
      }
      commitSave();
      dispatchThreadNoteCommand("restoreDeletedNote", { deletedNoteId });
      setIsHistoryPanelOpen(false);
    },
    [commitSave, dispatchThreadNoteCommand]
  );

  const handleDeleteDeletedNote = useCallback(
    (deletedNoteId: string) => {
      if (!deletedNoteId) {
        return;
      }
      dispatchThreadNoteCommand("deleteDeletedNote", { deletedNoteId });
    },
    [dispatchThreadNoteCommand]
  );

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

  const requestThreadNoteAIDraft = useCallback(
    (
      draftMode: "organize" | "chart",
      options?: {
        selectedText?: string;
        from?: number;
        to?: number;
        insertAt?: number;
        styleInstruction?: string;
      }
    ) => {
      if (!noteId) {
        return;
      }

      const currentMarkdown = normalizeLineEndings(editor?.getMarkdown() ?? draftText);
      const normalizedSelectedText = options?.selectedText?.trim() || "";
      const hasSelectedRange =
        typeof options?.from === "number" &&
        typeof options?.to === "number" &&
        options.to > options.from;
      const requestKind = normalizedSelectedText ? "selection" : "whole";
      const selectionTarget =
        requestKind === "selection" && hasSelectedRange
          ? resolveSummaryTargetFromSelection(
              editor,
              options?.from,
              options?.to,
              options?.insertAt
            )
          : null;

      summaryTargetRef.current =
        selectionTarget
          ? selectionTarget
          : { kind: "whole" };

      dispatchThreadNoteCommand("requestAIDraftPreview", {
        noteId,
        draftMode,
        text: currentMarkdown,
        selectedText: normalizedSelectedText || undefined,
        requestKind,
        styleInstruction: options?.styleInstruction?.trim() || undefined,
      });
    },
    [dispatchThreadNoteCommand, draftText, editor, noteId]
  );

  const handleRequestAIDraft = useCallback(() => {
    requestThreadNoteAIDraft("organize", {
      selectedText: noteSelection?.text,
      from: noteSelection?.from,
      to: noteSelection?.to,
      insertAt: noteSelection?.to,
    });
  }, [noteSelection?.from, noteSelection?.text, noteSelection?.to, requestThreadNoteAIDraft]);

  const handleRequestChartDraftFromMenu = useCallback(() => {
    if (!noteContextMenu) {
      return;
    }

    closeNoteContextMenu();
    setIsChartDraftModalDismissed(false);
    setSelectedChartType("auto");
    setChartStyleInstruction("");
    setChartRequestComposer({
      selectedText: noteContextMenu.selectedText,
      from: noteContextMenu.from,
      to: noteContextMenu.to,
      insertAt: noteContextMenu.insertAt,
      sourceKind: noteContextMenu.sourceKind,
    });
  }, [closeNoteContextMenu, noteContextMenu]);

  const handleRequestOrganizeDraftFromMenu = useCallback(() => {
    if (!noteContextMenu) {
      return;
    }

    closeNoteContextMenu();
    requestThreadNoteAIDraft("organize", {
      selectedText: noteContextMenu.selectedText,
      from: noteContextMenu.from,
      to: noteContextMenu.to,
      insertAt: noteContextMenu.insertAt,
    });
  }, [closeNoteContextMenu, noteContextMenu, requestThreadNoteAIDraft]);

  const handleApplyInlineMarkFromMenu = useCallback(
    (markType: "bold" | "italic" | "code") => {
      if (!editor || !noteContextMenu || noteContextMenu.sourceKind !== "selection") {
        return;
      }

      closeNoteContextMenu();
      const chain = editor
        .chain()
        .focus()
        .setTextSelection({ from: noteContextMenu.from, to: noteContextMenu.to });

      switch (markType) {
        case "bold":
          chain.toggleBold().run();
          break;
        case "italic":
          chain.toggleItalic().run();
          break;
        case "code":
          chain.toggleCode().run();
          break;
        default:
          chain.run();
      }

      refreshSlashQuery(editor);
    },
    [closeNoteContextMenu, editor, noteContextMenu, refreshSlashQuery]
  );

  const handleOpenLineFormatFromMenu = useCallback(() => {
    if (
      !noteContextMenu ||
      typeof noteContextMenu.lineSelectionPos !== "number" ||
      typeof noteContextMenu.lineInsertAt !== "number" ||
      !noteContextMenu.lineTag ||
      typeof noteContextMenu.lineMenuLeft !== "number" ||
      typeof noteContextMenu.lineMenuTop !== "number"
    ) {
      return;
    }

    closeNoteContextMenu();
    setHeadingTagEditor({
      selectionPos: noteContextMenu.lineSelectionPos,
      insertAt: noteContextMenu.lineInsertAt,
      tag: noteContextMenu.lineTag,
      headingCollapsible: noteContextMenu.lineHeadingCollapsible,
      left: noteContextMenu.lineMenuLeft,
      top: noteContextMenu.lineMenuTop,
    });
  }, [closeNoteContextMenu, noteContextMenu]);

  const handleToggleHeadingCollapsibleFromMenu = useCallback(() => {
    if (
      !editor ||
      !noteContextMenu ||
      typeof noteContextMenu.lineSelectionPos !== "number" ||
      !isHeadingLineTag(noteContextMenu.lineTag)
    ) {
      return;
    }

    const nextCollapsible = noteContextMenu.lineHeadingCollapsible === false;
    const didUpdate = updateHeadingCollapsibleAtSelection(
      resolveEditorView(editor),
      noteContextMenu.lineSelectionPos,
      nextCollapsible
    );
    if (!didUpdate) {
      return;
    }

    closeNoteContextMenu();
    refreshSlashQuery(editor);
  }, [closeNoteContextMenu, editor, noteContextMenu, refreshSlashQuery]);

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
    setIsChartDraftModalDismissed(true);
  }, []);

  const closeChartRequestComposer = useCallback(() => {
    setChartRequestComposer(null);
  }, []);

  const reopenChartDraftModal = useCallback(() => {
    setIsChartDraftModalDismissed(false);
  }, []);

  const discardChartDraft = useCallback(() => {
    setIsChartDraftModalDismissed(false);
    clearAIDraftPreview();
  }, [clearAIDraftPreview]);

  const handleGenerateChartDraft = useCallback(() => {
    if (!chartRequestComposer) {
      return;
    }

    const nextStyleInstruction = buildChartStyleInstruction(
      selectedChartType,
      chartStyleInstruction
    );

    setChartRequestComposer(null);
    requestThreadNoteAIDraft("chart", {
      selectedText: chartRequestComposer.selectedText,
      from: chartRequestComposer.from,
      to: chartRequestComposer.to,
      insertAt: chartRequestComposer.insertAt,
      styleInstruction: nextStyleInstruction,
    });
  }, [
    chartRequestComposer,
    chartStyleInstruction,
    requestThreadNoteAIDraft,
    selectedChartType,
  ]);

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

      if (
        summaryTarget?.kind === "selection" &&
        typeof summaryTarget.from === "number" &&
        typeof summaryTarget.to === "number"
      ) {
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
          editor.commands.insertContentAt(
            summaryTarget.insertAt ?? summaryTarget.to,
            `\n\n${previewMarkdown}`,
            {
              contentType: "markdown",
            }
          );
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

  const handleAddChartDraftToNote = useCallback(
    (applyMode: "appendBottom" | "insertBelowSelection" = "appendBottom") => {
      if (!editor || !aiDraftPreview || aiDraftPreview.isError || aiDraftPreview.mode !== "chart") {
        closeAIDraftPreview();
        return;
      }

      const draftMarkdown = normalizeLineEndings(aiDraftPreview.markdown).trim();
      const summaryTarget = summaryTargetRef.current;

      if (
        applyMode === "insertBelowSelection" &&
        summaryTarget?.kind === "selection" &&
        typeof (summaryTarget.insertAt ?? summaryTarget.to) === "number"
      ) {
        editor.commands.insertContentAt(summaryTarget.insertAt ?? summaryTarget.to!, `\n\n${draftMarkdown}`, {
          contentType: "markdown",
        });
        commitEditorMarkdown(normalizeLineEndings(editor.getMarkdown()));
        closeAIDraftPreview("applyAIDraftPreview");
        return;
      }

      const currentMarkdown = normalizeLineEndings(editor.getMarkdown()).trim();
      const mergedMarkdown = [currentMarkdown, draftMarkdown].filter(Boolean).join("\n\n");
      editor.commands.setContent(mergedMarkdown, { contentType: "markdown" });
      commitEditorMarkdown(normalizeLineEndings(editor.getMarkdown()));
      closeAIDraftPreview("applyAIDraftPreview");
    },
    [aiDraftPreview, closeAIDraftPreview, commitEditorMarkdown, editor]
  );

  const handleRegenerateChartDraft = useCallback(() => {
    const normalizedInstruction = buildChartStyleInstruction(
      selectedChartType,
      chartStyleInstruction
    );
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
  }, [
    aiDraftPreview,
    chartStyleInstruction,
    dispatchThreadNoteCommand,
    noteId,
    selectedChartType,
  ]);

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
  const normalizedNoteLinkSearch = noteLinkSearch.trim().toLowerCase();
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
  const linkableSourceSections = useMemo<ThreadNoteSourceSection[]>(
    () =>
      (state?.availableSources ?? []).map((source) => {
        const sourceKey = noteSourceKey(source.ownerKind, source.ownerId);
        const allSourceNotes = notes.filter(
          (note) =>
            noteSourceKey(note.ownerKind, note.ownerId) === sourceKey &&
            !(note.id === noteId && note.ownerKind === ownerKind && note.ownerId === ownerId)
        );
        const visibleSourceNotes = normalizedNoteLinkSearch
          ? allSourceNotes.filter((note) =>
              normalizeThreadNoteTitle(note.title)
                .toLowerCase()
                .includes(normalizedNoteLinkSearch)
            )
          : allSourceNotes;
        return {
          source,
          allNotes: allSourceNotes,
          visibleNotes: visibleSourceNotes,
        };
      }),
    [
      normalizedNoteLinkSearch,
      noteId,
      notes,
      ownerId,
      ownerKind,
      state?.availableSources,
    ]
  );
  const isAIDraftBusy = Boolean(state?.isGeneratingAIDraft);
  const selectedChartChoice =
    CHART_TYPE_CHOICES.find((option) => option.type === selectedChartType) ??
    CHART_TYPE_CHOICES[0];
  const chartDraftInstruction = buildChartStyleInstruction(
    selectedChartType,
    chartStyleInstruction
  );
  const currentChartDraftType =
    aiDraftPreview && aiDraftPreview.mode === "chart" && !aiDraftPreview.isError
      ? detectChartTypeFromDraftMarkdown(aiDraftPreview.markdown)
      : null;
  const currentChartDraftLabel = currentChartDraftType
    ? chartChoiceLabel(currentChartDraftType)
    : null;
  const chartGenerateButtonLabel =
    selectedChartType === "auto"
      ? "Generate Chart"
      : `Generate ${selectedChartChoice.label}`;
  const chartRegenerateButtonLabel =
    selectedChartType === "auto"
      ? "Regenerate"
      : `Regenerate ${selectedChartChoice.label}`;
  const chartComposerSourceText = chartRequestComposer?.selectedText?.trim() ?? "";
  const chartRequestSourceKind = chartRequestComposer?.sourceKind ?? "selection";
  const selectedNoteIndex =
    noteId && noteCount > 0
      ? Math.max(0, notesForCurrentSource.findIndex((note) => note.id === noteId)) + 1
      : 0;
  const selectedNoteBadge =
    selectedNoteIndex > 0 && noteCount > 1 ? `${selectedNoteIndex}/${noteCount}` : null;
  const selectorLabel =
    state?.selectedNoteTitle?.trim() ||
    (noteCount > 0 ? "Untitled note" : currentSourceLabel);
  const outgoingLinks = state?.outgoingLinks ?? [];
  const backlinks = state?.backlinks ?? [];
  const graph = state?.graph ?? null;
  const hasLinkedNotesPanel =
    isNotesWorkspace || outgoingLinks.length > 0 || backlinks.length > 0 || Boolean(graph);
  const backButtonLabel = state?.previousLinkedNoteTitle?.trim() || "Back";
  const canCreateNote = state?.canCreateNote ?? true;
  const workspaceProjectTitle = state?.workspaceProjectTitle?.trim() || "Notes";
  const workspaceOwnerSubtitle = state?.workspaceOwnerSubtitle?.trim() || "";
  const owningThreadId = state?.owningThreadId ?? null;
  const owningThreadTitle = state?.owningThreadTitle?.trim() || "Open thread";
  const canRequestSummary = hasAnyNotes && Boolean(draftText.trim() || noteSelection?.text?.trim());
  const handleOpenNoteLinkPicker = useCallback(() => {
    if (!noteContextMenu) {
      return;
    }

    const isSelectionLink = noteContextMenu.sourceKind === "selection";
    setNoteContextMenuLayer("root");
    closeNoteContextMenu();
    setNoteLinkSearch("");
    setNoteLinkPicker({
      mode: isSelectionLink ? "wrapSelection" : "insertInline",
      selectedLabel: isSelectionLink ? noteContextMenu.selectedText : "",
      from: isSelectionLink ? noteContextMenu.from : undefined,
      to: isSelectionLink ? noteContextMenu.to : undefined,
      insertAt: isSelectionLink
        ? noteContextMenu.from
        : noteContextMenu.cursorPos ?? noteContextMenu.to,
    });
  }, [closeNoteContextMenu, noteContextMenu]);
  const handleInsertNoteLink = useCallback(
    (targetNote: (typeof notes)[number]) => {
      if (!editor || !noteLinkPicker) {
        return;
      }

      const target = {
        ownerKind: targetNote.ownerKind,
        ownerId: targetNote.ownerId,
        noteId: targetNote.id,
      };
      const fallbackLabel = normalizeThreadNoteTitle(targetNote.title);
      const linkLabel = noteLinkPicker.mode === "wrapSelection"
        ? noteLinkPicker.selectedLabel.trim() || fallbackLabel
        : fallbackLabel;
      const markdownLink = buildInternalNoteMarkdownLink(linkLabel, target);

      if (
        noteLinkPicker.mode === "wrapSelection" &&
        typeof noteLinkPicker.from === "number" &&
        typeof noteLinkPicker.to === "number" &&
        noteLinkPicker.to > noteLinkPicker.from
      ) {
        editor
          .chain()
          .focus()
          .deleteRange({ from: noteLinkPicker.from, to: noteLinkPicker.to })
          .insertContentAt(noteLinkPicker.from, markdownLink, {
            contentType: "markdown",
          })
          .run();
      } else {
        editor
          .chain()
          .focus()
          .insertContentAt(noteLinkPicker.insertAt, `${markdownLink} `, {
            contentType: "markdown",
          })
          .run();
      }

      setNoteLinkPicker(null);
      setNoteLinkSearch("");
      refreshSlashQuery(editor);
    },
    [editor, noteLinkPicker, notes, refreshSlashQuery]
  );
  const handleOpenLinkedNoteFromMenu = useCallback(() => {
    openInternalNoteTarget(noteContextMenu?.linkTarget);
  }, [noteContextMenu?.linkTarget, openInternalNoteTarget]);
  const handleOpenRelationshipLink = useCallback(
    (item: { ownerKind: string; ownerId: string; noteId: string; isMissing: boolean }) => {
      if (item.isMissing) {
        showLinkNotice("That linked note no longer exists.");
        return;
      }
      openInternalNoteTarget({
        ownerKind: item.ownerKind,
        ownerId: item.ownerId,
        noteId: item.noteId,
      });
    },
    [openInternalNoteTarget, showLinkNotice]
  );
  const handleGoBackLinkedNote = useCallback(() => {
    commitSave();
    dispatchThreadNoteCommand("goBackLinkedNote");
  }, [commitSave, dispatchThreadNoteCommand]);
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
  const noteContextMenuHasFormattingActions = Boolean(
    noteContextMenu &&
      (noteContextMenu.sourceKind === "selection" ||
        typeof noteContextMenu.lineSelectionPos === "number")
  );
  const noteContextMenuHasAIActions = Boolean(
    noteContextMenu &&
      (noteContextMenu.sourceKind === "selection" ||
        typeof noteContextMenu.lineSelectionPos === "number")
  );
  const noteContextMenuHasLinkActions = Boolean(
    noteContextMenu &&
      (noteContextMenu.sourceKind === "selection" ||
        typeof noteContextMenu.lineSelectionPos === "number" ||
        noteContextMenu.linkTarget)
  );
  const noteContextMenuTitle = noteContextMenuLayer === "format"
    ? "Formatting"
    : noteContextMenuLayer === "links"
      ? "Links"
    : noteContextMenuLayer === "ai"
      ? "AI actions"
      : noteContextMenu?.sourceKind === "selection"
        ? "Selected note text"
        : "Note row";
  const floatingMenuStyle = resolveFloatingMenuStyle(menuPosition);
  const noteContextMenuStyle = (
    noteContextMenuPosition ?? (noteContextMenu ? { x: noteContextMenu.x, y: noteContextMenu.y } : null)
  )
    ? ({
        "--oa-context-menu-x": `${(noteContextMenuPosition ?? noteContextMenu)!.x}px`,
        "--oa-context-menu-y": `${(noteContextMenuPosition ?? noteContextMenu)!.y}px`,
      } as CSSProperties)
    : undefined;
  const headingTagMenuStyle = headingTagEditor
    ? ({
        left: `${headingTagEditor.left}px`,
        top: `${headingTagEditor.top}px`,
      } satisfies CSSProperties)
    : undefined;
  const chartTypePicker = (
    <div className="thread-note-chart-picker-shell">
      <div className="thread-note-chart-picker-header">
        <div className="thread-note-chart-picker-copy">
          <span className="thread-note-chart-picker-kicker">
            {isChartRequestComposerOpen ? "Choose chart type" : "Switch chart type"}
          </span>
          <h3>{selectedChartChoice.label}</h3>
          <p>{selectedChartChoice.description}</p>
        </div>
        {currentChartDraftLabel && !isChartRequestComposerOpen ? (
          <div className="thread-note-chart-current-type">
            Current: {currentChartDraftLabel}
          </div>
        ) : null}
      </div>

      <div className="thread-note-chart-choice-grid" role="list" aria-label="Chart types">
        {CHART_TYPE_CHOICES.map((option) => {
          const isActive = option.type === selectedChartType;
          return (
            <button
              key={option.type}
              type="button"
              className={`thread-note-chart-choice${isActive ? " is-active" : ""}`}
              aria-pressed={isActive}
              onClick={() => setSelectedChartType(option.type)}
            >
              <div className="thread-note-chart-choice-visual">
                <ChartTypePreview type={option.type} />
              </div>
              <div className="thread-note-chart-choice-copy">
                <span className="thread-note-chart-choice-label">{option.label}</span>
                <span className="thread-note-chart-choice-description">
                  {option.description}
                </span>
              </div>
            </button>
          );
        })}
      </div>

      <div className="thread-note-chart-guidance-shell">
        <label
          className="thread-note-chart-regenerate-label"
          htmlFor="thread-note-chart-style"
        >
          Extra instructions (optional)
        </label>
        <input
          id="thread-note-chart-style"
          type="text"
          className="thread-note-chart-regenerate-input"
          value={chartStyleInstruction}
          onChange={(event) => setChartStyleInstruction(event.target.value)}
          placeholder="Example: group by stage, use muted blue and green sections, keep only the main steps"
          disabled={isAIDraftBusy}
        />
        <p className="thread-note-chart-regenerate-hint">
          Example: &ldquo;group by stage&rdquo;, &ldquo;use muted blue and green sections&rdquo;, or &ldquo;make it an explainer flow with short labels&rdquo;.
        </p>
      </div>

      {isChartRequestComposerOpen && chartComposerSourceText ? (
        <div className="thread-note-chart-source-card">
          <span className="thread-note-chart-source-label">
            {chartSourceLabel(chartRequestSourceKind)}
          </span>
          <p>{chartComposerSourceText}</p>
        </div>
      ) : null}
    </div>
  );
  const utilityControls =
    statusLabel || shouldShowSummaryAction || linkNotice ? (
      <div
        className={[
          "thread-note-meta-row",
          isFullScreenWorkspace ? "is-inline-utility" : "",
        ]
          .filter(Boolean)
          .join(" ")}
      >
        {statusLabel ? <span className="thread-note-status">{statusLabel}</span> : null}
        {linkNotice ? <span className="thread-note-link-notice">{linkNotice}</span> : null}
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
    ) : null;
  const linkedNotesPanel =
    hasAnyNotes && hasLinkedNotesPanel ? (
      <div
        className={[
          "thread-note-links-panel",
          isNotesWorkspace ? "is-notes-workspace" : "",
        ]
          .filter(Boolean)
          .join(" ")}
      >
        <button
          type="button"
          className="thread-note-links-toggle"
          onClick={() => setIsLinkedNotesOpen((value) => !value)}
          aria-expanded={isLinkedNotesOpen}
        >
          <span className="thread-note-links-toggle-main">
            <span className="thread-note-links-toggle-label">Linked Notes</span>
            <span className="thread-note-links-toggle-meta">
              {outgoingLinks.length} outgoing, {backlinks.length} backlinks
            </span>
          </span>
          <span
            className={[
              "thread-note-selector-chevron",
              isLinkedNotesOpen ? "is-open" : "",
            ]
              .filter(Boolean)
              .join(" ")}
            aria-hidden="true"
          >
            ▾
          </span>
        </button>
        {isLinkedNotesOpen ? (
          <div className="thread-note-links-body">
            <div className="thread-note-links-section">
              <div className="thread-note-links-section-header">
                <span>Links from this note</span>
                <span>{outgoingLinks.length}</span>
              </div>
              {outgoingLinks.length > 0 ? (
                <div className="thread-note-links-chip-grid">
                  {outgoingLinks.map((item) => (
                    <button
                      key={`outgoing-${item.ownerKind}-${item.ownerId}-${item.noteId}`}
                      type="button"
                      className={[
                        "thread-note-link-chip",
                        item.isMissing ? "is-missing" : "",
                      ]
                        .filter(Boolean)
                        .join(" ")}
                      onClick={() => handleOpenRelationshipLink(item)}
                    >
                      <span className="thread-note-link-chip-title">{item.title}</span>
                      <span className="thread-note-link-chip-meta">
                        {item.sourceLabel}
                        {item.occurrenceCount > 1 ? ` • ${item.occurrenceCount} links` : ""}
                      </span>
                    </button>
                  ))}
                </div>
              ) : (
                <div className="thread-note-links-empty">
                  No note links in this note yet.
                </div>
              )}
            </div>

            <div className="thread-note-links-section">
              <div className="thread-note-links-section-header">
                <span>Referenced by</span>
                <span>{backlinks.length}</span>
              </div>
              {backlinks.length > 0 ? (
                <div className="thread-note-links-chip-grid">
                  {backlinks.map((item) => (
                    <button
                      key={`backlink-${item.ownerKind}-${item.ownerId}-${item.noteId}`}
                      type="button"
                      className="thread-note-link-chip"
                      onClick={() => handleOpenRelationshipLink(item)}
                    >
                      <span className="thread-note-link-chip-title">{item.title}</span>
                      <span className="thread-note-link-chip-meta">
                        {item.sourceLabel}
                        {item.occurrenceCount > 1 ? ` • ${item.occurrenceCount} links` : ""}
                      </span>
                    </button>
                  ))}
                </div>
              ) : (
                <div className="thread-note-links-empty">
                  No other notes link back here yet.
                </div>
              )}
            </div>

            {graph ? (
              <div className="thread-note-links-section thread-note-links-graph-row">
                <div className="thread-note-links-section-header">
                  <span>Open graph</span>
                  <span>
                    {graph.nodeCount} nodes • {graph.edgeCount} links
                  </span>
                </div>
                <button
                  type="button"
                  className="thread-note-graph-button"
                  onClick={() => setIsGraphOpen(true)}
                >
                  <GraphIcon />
                  <span>View local note graph</span>
                </button>
              </div>
            ) : null}
          </div>
        ) : null}
      </div>
    ) : null;
  const historyPanel =
    isHistoryPanelOpen && hasRecoveryItems ? (
      <div className="thread-note-recovery-panel">
        <div className="thread-note-recovery-section">
          <div className="thread-note-recovery-section-header">
            <span>History</span>
            <span>{historyVersions.length}</span>
          </div>
          {historyVersions.length ? (
            <div className="thread-note-recovery-list">
              {historyVersions.map((item) => (
                <article key={item.id} className="thread-note-recovery-item">
                  <div className="thread-note-recovery-copy">
                    <div className="thread-note-recovery-title-row">
                      <strong>{normalizeThreadNoteTitle(item.title)}</strong>
                      <span>{item.savedAtLabel}</span>
                    </div>
                    <p>{item.preview}</p>
                  </div>
                  <div className="thread-note-recovery-actions">
                    <button
                      type="button"
                      className="thread-note-recovery-action is-primary"
                      onClick={() => handleRestoreHistoryVersion(item.id)}
                    >
                      Restore
                    </button>
                    <button
                      type="button"
                      className="thread-note-recovery-action"
                      onClick={() => handleDeleteHistoryVersion(item.id)}
                    >
                      Delete
                    </button>
                  </div>
                </article>
              ))}
            </div>
          ) : (
            <div className="thread-note-recovery-empty">
              Open Assist has not saved an older version of this note yet.
            </div>
          )}
        </div>

        <div className="thread-note-recovery-section">
          <div className="thread-note-recovery-section-header">
            <span>Recently Deleted</span>
            <span>{recentlyDeletedNotes.length}</span>
          </div>
          {recentlyDeletedNotes.length ? (
            <div className="thread-note-recovery-list">
              {recentlyDeletedNotes.map((item) => (
                <article key={item.id} className="thread-note-recovery-item">
                  <div className="thread-note-recovery-copy">
                    <div className="thread-note-recovery-title-row">
                      <strong>{normalizeThreadNoteTitle(item.title)}</strong>
                      <span>{item.deletedAtLabel}</span>
                    </div>
                    <p>{item.preview}</p>
                  </div>
                  <div className="thread-note-recovery-actions">
                    <button
                      type="button"
                      className="thread-note-recovery-action is-primary"
                      onClick={() => handleRestoreDeletedNote(item.id)}
                    >
                      Restore Note
                    </button>
                    <button
                      type="button"
                      className="thread-note-recovery-action"
                      onClick={() => handleDeleteDeletedNote(item.id)}
                    >
                      Delete Forever
                    </button>
                  </div>
                </article>
              ))}
            </div>
          ) : (
            <div className="thread-note-recovery-empty">
              No deleted notes are waiting here right now.
            </div>
          )}
        </div>
      </div>
    ) : null;

  return (
    <>
      <aside
        ref={drawerRef}
        className={[
          "thread-note-drawer",
          isExpanded ? "is-expanded" : "",
          isFullScreenWorkspace ? "is-project-fullscreen" : "",
          isNotesWorkspace ? "is-notes-workspace" : "",
        ]
          .filter(Boolean)
          .join(" ")}
        aria-hidden={!isOpen}
      >
        <div
          className={[
            "thread-note-header",
            isFullScreenWorkspace ? "is-project-document" : "",
            isNotesWorkspace ? "is-notes-workspace" : "",
          ]
            .filter(Boolean)
            .join(" ")}
        >
          <div className="thread-note-workspace-row">
            <div className="thread-note-header-copy">
              <span className="thread-note-eyebrow">
                {isNotesWorkspace ? workspaceProjectTitle : currentSourceLabel}
              </span>
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
              ) : isNotesWorkspace ? (
                <div className="thread-note-notes-title-block">
                  <div className="thread-note-notes-title-row">
                    <h1 className="thread-note-notes-title">{selectorLabel}</h1>
                    {selectedNoteBadge ? (
                      <span className="thread-note-selector-count">{selectedNoteBadge}</span>
                    ) : null}
                  </div>
                  <div className="thread-note-notes-subtitle">
                    <span>{currentSourceLabel}</span>
                    {workspaceOwnerSubtitle ? <span>{workspaceOwnerSubtitle}</span> : null}
                  </div>
                </div>
              ) : (
                <div className="thread-note-selector-row">
                  <button
                    ref={selectorButtonRef}
                    type="button"
                    className={[
                      "thread-note-selector-trigger",
                      !isFullScreenWorkspace ? "is-side-drawer" : "",
                    ]
                      .filter(Boolean)
                      .join(" ")}
                    onClick={handleToggleSelectorMenu}
                    disabled={!state?.availableSources?.length}
                    aria-label="Choose note source"
                    aria-expanded={isSelectorOpen}
                  >
                    <span className="thread-note-selector-main">
                      {!isProjectFullScreen ? (
                        <span className="thread-note-selector-kicker">Current note</span>
                      ) : null}
                      <span className="thread-note-selector-title">{selectorLabel}</span>
                    </span>
                    <span className="thread-note-selector-trailing">
                      {!isProjectFullScreen ? (
                        <span className="thread-note-selector-hint">Switch</span>
                      ) : null}
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
              {isSelectorOpen && !isNotesWorkspace ? (
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

            <div
              className={[
                "thread-note-header-actions",
                isFullScreenWorkspace ? "is-project-document" : "",
              ]
                .filter(Boolean)
                .join(" ")}
            >
              {isFullScreenWorkspace ? utilityControls : null}
              <div className="thread-note-toolbar">
                {state?.canNavigateBack ? (
                  <button
                    type="button"
                    className="thread-note-icon-button"
                    onClick={handleGoBackLinkedNote}
                    aria-label={`Back to ${backButtonLabel}`}
                    title={`Back to ${backButtonLabel}`}
                  >
                    <BackIcon />
                  </button>
                ) : null}
                {isNotesWorkspace && owningThreadId ? (
                  <button
                    type="button"
                    className="thread-note-icon-button"
                    onClick={() =>
                      dispatchThreadNoteCommand("openOwningThread", {
                        threadId: owningThreadId,
                        ownerKind: "thread",
                        ownerId: owningThreadId,
                      })
                    }
                    aria-label={`Open ${owningThreadTitle}`}
                    title={`Open ${owningThreadTitle}`}
                  >
                    <ArrowJumpIcon />
                  </button>
                ) : null}
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
                  type="button"
                  className="thread-note-icon-button"
                  onClick={handleToggleHistoryPanel}
                  disabled={!hasRecoveryItems}
                  aria-label="Open note history"
                  title="Open note history"
                >
                  <HistoryIcon />
                </button>
                <button
                  className="thread-note-icon-button"
                  type="button"
                  onClick={handleCreateNote}
                  disabled={!canCreateNote}
                  aria-label={`New ${currentSourceLabel.toLowerCase().replace("notes", "note")}`}
                  title={`New ${currentSourceLabel.toLowerCase().replace("notes", "note")}`}
                >
                  <PlusIcon />
                </button>
                {!isFullScreenWorkspace ? (
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
          </div>

          {!isFullScreenWorkspace ? utilityControls : null}
        </div>

        {!isNotesWorkspace ? linkedNotesPanel : null}

        <div
          className={[
            "thread-note-surface",
            isNotesWorkspace ? "is-notes-workspace" : "",
          ]
            .filter(Boolean)
            .join(" ")}
        >
          {historyPanel}
          {!hasAnyNotes ? (
            <div className="thread-note-empty-shell">
              <div className="thread-note-empty-copy">
                <h3>
                  {currentSourceLabel === "Project notes"
                    ? "No project notes yet"
                    : "No thread notes yet"}
                </h3>
                <p>
                  {!canCreateNote
                    ? "This project does not have thread notes yet. Open a chat inside this project and create one there first."
                    : currentSourceLabel === "Project notes"
                    ? "Create a shared project note for decisions, architecture, and next steps."
                    : "Create a note for this thread and start collecting key points."}
                </p>
              </div>
              {canCreateNote ? (
                <button
                  type="button"
                  className="thread-note-empty-button"
                  onClick={handleCreateNote}
                >
                  {currentSourceLabel === "Project notes"
                    ? "New project note"
                    : "New thread note"}
                </button>
              ) : null}
            </div>
          ) : (
            <div
              className={[
                "thread-note-workspace",
                isNotesWorkspace ? "is-notes-workspace" : "",
              ]
                .filter(Boolean)
                .join(" ")}
            >
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
              {isNotesWorkspace && linkedNotesPanel ? (
                <aside className="thread-note-notes-float">{linkedNotesPanel}</aside>
              ) : null}
            </div>
          )}
        </div>
        {showAIDraftModal ? (
          <div
            className="thread-note-dialog-layer"
            onClick={
              isChartRequestComposerOpen
                ? closeChartRequestComposer
                : isChartDraft
                  ? dismissChartDraftModal
                  : clearAIDraftPreview
            }
          >
            <div
              className="thread-note-dialog thread-note-summary-modal"
              onClick={(event) => event.stopPropagation()}
            >
              <div className="thread-note-dialog-header">
                <div className="thread-note-dialog-copy">
                  <h2>
                    {isChartRequestComposerOpen
                      ? "Choose AI chart"
                      : isChartDraft
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
                    {isChartRequestComposerOpen
                      ? chartRequestSourceKind === "line"
                        ? "Pick the chart type first. Then AI will build that chart from the note line you opened from the right-click menu."
                        : "Pick the chart type first. Then AI will build that chart from the note text you selected."
                      : isChartDraft
                      ? activeAIDraftSourceKind === "chatSelection"
                        ? "This chart comes from the text you selected in the chat. You can regenerate it in a different style before adding it."
                        : activeAIDraftSourceKind === "selection"
                          ? "This chart comes from the note text you selected. You can insert it below that text without replacing anything."
                        : "This chart draft is ready to review before it is added to the note."
                      : activeAIDraftSourceKind === "selection"
                        ? "This draft was made from the text you selected in this note."
                        : "This draft was made from the current note."}
                  </p>
                </div>
                <button
                  type="button"
                  className="thread-note-icon-button thread-note-dialog-close"
                  onClick={
                    isChartRequestComposerOpen
                      ? closeChartRequestComposer
                      : isChartDraft
                        ? dismissChartDraftModal
                        : clearAIDraftPreview
                  }
                  aria-label="Close AI draft"
                >
                  ×
                </button>
              </div>
              <div className="thread-note-dialog-body">
                {isChartRequestComposerOpen ? (
                  chartTypePicker
                ) : !aiDraftPreview ? (
                  <div className="thread-note-ai-loading">
                    <div className="thread-note-ai-loading-spinner" aria-hidden="true" />
                    <div className="thread-note-ai-loading-copy">
                      {isChartDraft
                        ? selectedChartType === "auto"
                          ? "AI is choosing the best Mermaid style and building the first chart draft."
                          : `AI is building a ${selectedChartChoice.label.toLowerCase()} draft for this text.`
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
                  chartTypePicker
                ) : null}
              </div>
              <div className="thread-note-dialog-footer">
                {isChartRequestComposerOpen ? (
                  <>
                    <button
                      type="button"
                      className="oa-button"
                      onClick={closeChartRequestComposer}
                    >
                      Cancel
                    </button>
                    <button
                      type="button"
                      className="oa-button oa-button--primary"
                      onClick={handleGenerateChartDraft}
                    >
                      {chartGenerateButtonLabel}
                    </button>
                  </>
                ) : isAIDraftError && isChartDraft ? (
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
                        disabled={isAIDraftBusy || !chartDraftInstruction}
                        onClick={handleRegenerateChartDraft}
                      >
                        {isAIDraftBusy ? "Working..." : chartRegenerateButtonLabel}
                      </button>
                    ) : null}
                    {aiDraftPreview ? (
                      <button
                        type="button"
                        className="oa-button"
                        disabled={
                          isAIDraftBusy || activeAIDraftSourceKind !== "selection"
                        }
                        onClick={() => handleAddChartDraftToNote("insertBelowSelection")}
                      >
                        Insert Below Selection
                      </button>
                    ) : null}
                    {aiDraftPreview ? (
                      <button
                        type="button"
                        className="oa-button oa-button--primary"
                        disabled={isAIDraftBusy}
                        onClick={() => handleAddChartDraftToNote("appendBottom")}
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

        {noteLinkPicker ? (
          <div
            className="thread-note-dialog-layer"
            onClick={() => {
              setNoteLinkPicker(null);
              setNoteLinkSearch("");
            }}
          >
            <div
              className="thread-note-dialog thread-note-link-modal"
              onClick={(event) => event.stopPropagation()}
            >
              <div className="thread-note-dialog-header">
                <div className="thread-note-dialog-copy">
                  <h2>
                    {noteLinkPicker.mode === "wrapSelection"
                      ? "Link selected text to another note"
                      : "Insert note link"}
                  </h2>
                  <p>
                    {noteLinkPicker.mode === "wrapSelection"
                      ? "Choose a note to connect this highlighted text to. Clicking the link later will open that note."
                      : "Choose a note to insert here. The note title will become the clickable link text."}
                  </p>
                </div>
                <button
                  type="button"
                  className="thread-note-icon-button thread-note-dialog-close"
                  onClick={() => {
                    setNoteLinkPicker(null);
                    setNoteLinkSearch("");
                  }}
                  aria-label="Close note link picker"
                >
                  ×
                </button>
              </div>
              <div className="thread-note-dialog-body">
                {noteLinkPicker.mode === "wrapSelection" ? (
                  <div className="thread-note-link-selection-preview">
                    {truncateContextMenuPreview(noteLinkPicker.selectedLabel)}
                  </div>
                ) : null}
                <div className="thread-note-selector-search-shell">
                  <input
                    ref={noteLinkSearchInputRef}
                    type="text"
                    className="thread-note-selector-search"
                    value={noteLinkSearch}
                    onChange={(event) => setNoteLinkSearch(event.target.value)}
                    placeholder="Search notes to link"
                    aria-label="Search notes to link"
                  />
                </div>
                <div className="thread-note-link-list">
                  {linkableSourceSections.some((section) => section.visibleNotes.length > 0) ? (
                    linkableSourceSections.map((section) =>
                      section.visibleNotes.length > 0 ? (
                        <div
                          key={`link-${noteSourceKey(section.source.ownerKind, section.source.ownerId)}`}
                        >
                          <div className="thread-note-selector-section-header">
                            <span>{section.source.sourceLabel}</span>
                            <span>{section.allNotes.length}</span>
                          </div>
                          {section.visibleNotes.map((note) => (
                            <button
                              key={`link-target-${section.source.ownerKind}:${section.source.ownerId}:${note.id}`}
                              type="button"
                              className="thread-note-selector-option"
                              onClick={() => handleInsertNoteLink(note)}
                            >
                              <span className="thread-note-selector-option-copy">
                                <span className="thread-note-selector-option-title">
                                  {normalizeThreadNoteTitle(note.title)}
                                </span>
                                <span className="thread-note-selector-option-subtitle">
                                  {note.updatedAtLabel
                                    ? `Updated ${note.updatedAtLabel}`
                                    : section.source.ownerTitle}
                                </span>
                              </span>
                              <span className="thread-note-selector-option-meta">
                                {section.source.sourceLabel}
                              </span>
                            </button>
                          ))}
                        </div>
                      ) : null
                    )
                  ) : (
                    <div className="thread-note-selector-empty">
                      No notes match "{noteLinkSearch.trim()}".
                    </div>
                  )}
                </div>
              </div>
              <div className="thread-note-dialog-footer">
                <button
                  type="button"
                  className="oa-button"
                  onClick={() => {
                    setNoteLinkPicker(null);
                    setNoteLinkSearch("");
                  }}
                >
                  Cancel
                </button>
              </div>
            </div>
          </div>
        ) : null}

        {isGraphOpen && graph ? (
          <div className="thread-note-dialog-layer" onClick={() => setIsGraphOpen(false)}>
            <div
              className="thread-note-dialog thread-note-graph-modal"
              onClick={(event) => event.stopPropagation()}
            >
              <div className="thread-note-dialog-header">
                <div className="thread-note-dialog-copy">
                  <h2>Local note graph</h2>
                  <p>
                    This shows the current note and the notes directly connected to it. Click a node to open that note.
                  </p>
                </div>
                <button
                  type="button"
                  className="thread-note-icon-button thread-note-dialog-close"
                  onClick={() => setIsGraphOpen(false)}
                  aria-label="Close note graph"
                >
                  ×
                </button>
              </div>
              <div className="thread-note-dialog-body">
                <MermaidDiagram
                  code={graph.mermaidCode}
                  showViewerHint={false}
                  clickAction="none"
                />
              </div>
              <div className="thread-note-dialog-footer">
                <button
                  type="button"
                  className="oa-button"
                  onClick={() => setIsGraphOpen(false)}
                >
                  Close
                </button>
              </div>
            </div>
          </div>
        ) : null}
      </aside>
      <div ref={floatingLayerRef} className="thread-note-floating-layer">
        {isOpen && noteContextMenu ? (
          <div
            ref={noteContextMenuRef}
            className="oa-react-context-menu"
            data-layer={noteContextMenuLayer}
            style={noteContextMenuStyle}
            onContextMenu={(event) => event.preventDefault()}
          >
            <div className="oa-react-context-menu__header">
              {noteContextMenuLayer !== "root" ? (
                <button
                  type="button"
                  className="oa-react-context-menu__back"
                  onClick={() => setNoteContextMenuLayer("root")}
                >
                  <BackIcon />
                  <span>Back</span>
                </button>
              ) : null}
              <span className="oa-react-context-menu__title">
                {noteContextMenuTitle}
              </span>
            </div>
            {noteContextMenuLayer === "root" && noteContextMenuHasFormattingActions ? (
              <button
                type="button"
                className="oa-react-context-menu__item oa-react-context-menu__item--submenu"
                onClick={() => setNoteContextMenuLayer("format")}
              >
                <span className="oa-react-context-menu__item-main">
                  <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                    <LineFormatIcon />
                  </span>
                  <span className="oa-react-context-menu__item-copy">
                    <span className="oa-react-context-menu__item-label">Formatting</span>
                    <span className="oa-react-context-menu__item-description">
                      Bold, italic, headings, and line styles
                    </span>
                  </span>
                </span>
                <span className="oa-react-context-menu__item-trailing" aria-hidden="true">
                  <ChevronRightIcon />
                </span>
              </button>
            ) : null}
            {noteContextMenuLayer === "root" && noteContextMenuHasLinkActions ? (
              <button
                type="button"
                className="oa-react-context-menu__item oa-react-context-menu__item--submenu"
                onClick={() => setNoteContextMenuLayer("links")}
              >
                <span className="oa-react-context-menu__item-main">
                  <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                    <LinkIcon />
                  </span>
                  <span className="oa-react-context-menu__item-copy">
                    <span className="oa-react-context-menu__item-label">Links</span>
                    <span className="oa-react-context-menu__item-description">
                      Connect notes and jump between them
                    </span>
                  </span>
                </span>
                <span className="oa-react-context-menu__item-trailing" aria-hidden="true">
                  <ChevronRightIcon />
                </span>
              </button>
            ) : null}
            {noteContextMenuLayer === "root" && noteContextMenuHasAIActions ? (
              <button
                type="button"
                className="oa-react-context-menu__item oa-react-context-menu__item--submenu"
                onClick={() => setNoteContextMenuLayer("ai")}
              >
                <span className="oa-react-context-menu__item-main">
                  <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                    <SparklesIcon />
                  </span>
                  <span className="oa-react-context-menu__item-copy">
                    <span className="oa-react-context-menu__item-label">AI actions</span>
                    <span className="oa-react-context-menu__item-description">
                      Charts, cleanup, and smart note edits
                    </span>
                  </span>
                </span>
                <span className="oa-react-context-menu__item-trailing" aria-hidden="true">
                  <ChevronRightIcon />
                </span>
              </button>
            ) : null}
            {noteContextMenuLayer === "links" ? (
              <>
                {noteContextMenu.linkTarget ? (
                  <button
                    type="button"
                    className="oa-react-context-menu__item"
                    onClick={handleOpenLinkedNoteFromMenu}
                  >
                    <span className="oa-react-context-menu__item-main">
                      <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                        <ArrowJumpIcon />
                      </span>
                      <span>Open linked note</span>
                    </span>
                  </button>
                ) : null}
                <button
                  type="button"
                  className="oa-react-context-menu__item"
                  onClick={handleOpenNoteLinkPicker}
                >
                  <span className="oa-react-context-menu__item-main">
                    <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                      <LinkIcon />
                    </span>
                    <span>
                      {noteContextMenu.sourceKind === "selection"
                        ? "Link selected text to note"
                        : "Insert note link"}
                    </span>
                  </span>
                </button>
                <div className="oa-react-context-menu__separator" />
                <div className="oa-react-context-menu__note">
                  Use note links to build a master note and jump into related notes.
                </div>
              </>
            ) : null}
            {noteContextMenuLayer === "format" && noteContextMenu.sourceKind === "selection" ? (
              <>
                <button
                  type="button"
                  className="oa-react-context-menu__item"
                  onClick={() => handleApplyInlineMarkFromMenu("bold")}
                >
                  <span className="oa-react-context-menu__item-main">
                    <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                      <BoldIcon />
                    </span>
                    <span>Bold selected words</span>
                  </span>
                </button>
                <button
                  type="button"
                  className="oa-react-context-menu__item"
                  onClick={() => handleApplyInlineMarkFromMenu("italic")}
                >
                  <span className="oa-react-context-menu__item-main">
                    <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                      <ItalicIcon />
                    </span>
                    <span>Italic selected words</span>
                  </span>
                </button>
              </>
            ) : null}
            {noteContextMenuLayer === "format" &&
            typeof noteContextMenu.lineSelectionPos === "number" ? (
              <button
                type="button"
                className="oa-react-context-menu__item"
                onClick={handleOpenLineFormatFromMenu}
              >
                <span className="oa-react-context-menu__item-main">
                  <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                    <LineFormatIcon />
                  </span>
                  <span>Change whole line format</span>
                </span>
              </button>
            ) : null}
            {noteContextMenuLayer === "format" &&
            typeof noteContextMenu.lineSelectionPos === "number" &&
            isHeadingLineTag(noteContextMenu.lineTag) ? (
              <button
                type="button"
                className="oa-react-context-menu__item"
                onClick={handleToggleHeadingCollapsibleFromMenu}
              >
                <span className="oa-react-context-menu__item-main">
                  <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                    <SectionToggleIcon />
                  </span>
                  <span>
                    {noteContextMenu.lineHeadingCollapsible === false
                      ? "Make collapsible section"
                      : "Make regular heading"}
                  </span>
                </span>
              </button>
            ) : null}
            {noteContextMenuLayer === "ai" ? (
              <div className="oa-react-context-menu__separator" />
            ) : null}
            {noteContextMenuLayer === "ai" ? (
              <>
                <button
                  type="button"
                  className="oa-react-context-menu__item"
                  onClick={handleRequestChartDraftFromMenu}
                >
                  <span className="oa-react-context-menu__item-main">
                    <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                      <ChartIcon />
                    </span>
                    <span>Generate Mermaid chart</span>
                  </span>
                </button>
                <button
                  type="button"
                  className="oa-react-context-menu__item"
                  onClick={handleRequestOrganizeDraftFromMenu}
                >
                  <span className="oa-react-context-menu__item-main">
                    <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                      <SparklesIcon />
                    </span>
                    <span>Organize with AI</span>
                  </span>
                </button>
                <div className="oa-react-context-menu__separator" />
                <div className="oa-react-context-menu__note">
                  {noteContextMenu.sourceKind === "selection"
                    ? `Chart drafts can be inserted below this highlighted text without replacing it.`
                    : `Chart drafts can be inserted below this note row without replacing it.`}
                </div>
              </>
            ) : null}
            {noteContextMenuLayer === "root" &&
            ((noteContextMenuHasFormattingActions && noteContextMenuHasAIActions) ||
              (noteContextMenuHasFormattingActions && noteContextMenuHasLinkActions) ||
              (noteContextMenuHasLinkActions && noteContextMenuHasAIActions)) ? (
              <div className="oa-react-context-menu__separator" />
            ) : null}
            <div className="oa-react-context-menu__note">
              {truncateContextMenuPreview(noteContextMenu.selectedText)}
            </div>
          </div>
        ) : null}

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
  groupMeta: SlashCommandGroupMeta,
  searchKeywords?: string[]
): SlashCommand {
  return {
    id,
    label,
    subtitle,
    groupId: groupMeta.groupId,
    groupLabel: groupMeta.groupLabel,
    groupTone: groupMeta.groupTone,
    groupOrder: groupMeta.groupOrder,
    searchKeywords: [...(groupMeta.searchKeywords ?? []), ...(searchKeywords ?? [])],
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

function HistoryIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M2.75 8a5.25 5.25 0 1 0 1.45-3.6" />
      <path d="M2.75 3.45v2.3h2.3" />
      <path d="M8 4.8v3.4l2.2 1.4" />
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

function ChartIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M2.75 12.5h10.5" />
      <path d="M4.25 11.75V8.5" />
      <path d="M7.25 11.75V5.25" />
      <path d="M10.25 11.75V7" />
      <path d="M4.25 7.1 7.25 4.1 10.25 5.85" />
      <circle cx="4.25" cy="7.1" r="0.7" fill="currentColor" stroke="none" />
      <circle cx="7.25" cy="4.1" r="0.7" fill="currentColor" stroke="none" />
      <circle cx="10.25" cy="5.85" r="0.7" fill="currentColor" stroke="none" />
    </svg>
  );
}

function SparklesIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M8 2.3 9.15 5.35 12.2 6.5 9.15 7.65 8 10.7 6.85 7.65 3.8 6.5 6.85 5.35 8 2.3Z" />
      <path d="M12.35 9.45 12.9 10.95 14.4 11.5 12.9 12.05 12.35 13.55 11.8 12.05 10.3 11.5 11.8 10.95 12.35 9.45Z" />
      <path d="M3.55 9.9 4 11.1 5.2 11.55 4 12 3.55 13.2 3.1 12 1.9 11.55 3.1 11.1 3.55 9.9Z" />
    </svg>
  );
}

function BoldIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M5.2 3.2h3.2c1.55 0 2.5.83 2.5 2.1 0 .93-.5 1.55-1.35 1.83 1.02.2 1.7.98 1.7 2.05 0 1.48-1.13 2.42-2.92 2.42H5.2V3.2Zm1.7 3.38h1.18c.86 0 1.38-.36 1.38-1s-.48-.97-1.34-.97H6.9v1.97Zm0 3.58h1.38c1 0 1.57-.4 1.57-1.1 0-.68-.57-1.08-1.58-1.08H6.9v2.18Z" />
    </svg>
  );
}

function ItalicIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M6.8 3.25h5.2" />
      <path d="M4 12.75h5.2" />
      <path d="M9.3 3.25 6 12.75" />
    </svg>
  );
}

function LineFormatIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M3 4.25h2.1" />
      <path d="M6.8 4.25h6.2" />
      <path d="M3 8h2.1" />
      <path d="M6.8 8h6.2" />
      <path d="M3 11.75h2.1" />
      <path d="M6.8 11.75h6.2" />
    </svg>
  );
}

function LinkIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M6.15 9.85 4.5 11.5a2.15 2.15 0 1 1-3.05-3.05L3.1 6.8" />
      <path d="M9.85 6.15 11.5 4.5a2.15 2.15 0 1 1 3.05 3.05L12.9 9.2" />
      <path d="M5.2 10.8 10.8 5.2" />
    </svg>
  );
}

function ArrowJumpIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M6.25 4h5.75v5.75" />
      <path d="M12 4 6.35 9.65" />
      <path d="M9.75 6.25v-2.5H4v8h8v-5.75" />
    </svg>
  );
}

function SectionToggleIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M3.1 4.25h2.2" />
      <path d="M7.1 4.25h5.8" />
      <path d="M3.1 8h2.2" />
      <path d="M7.1 8h5.8" />
      <path d="M4.15 11.2 2.75 12.6 2.75 9.8 4.15 11.2Z" fill="currentColor" stroke="none" />
      <path d="M7.1 11.2h5.8" />
    </svg>
  );
}

function BackIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M9.75 3.25 5 8l4.75 4.75" />
      <path d="M5.25 8h6.25" />
    </svg>
  );
}

function ChevronRightIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="m6.25 3.25 4.5 4.75-4.5 4.75" />
    </svg>
  );
}

function GraphIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <circle cx="3.5" cy="8" r="1.4" fill="currentColor" stroke="none" />
      <circle cx="8.2" cy="4" r="1.4" fill="currentColor" stroke="none" />
      <circle cx="12.5" cy="10.8" r="1.4" fill="currentColor" stroke="none" />
      <path d="M4.75 7.15 6.95 5.3" />
      <path d="M9 5.25 11.6 9.55" />
      <path d="M4.7 8.55 11.2 10.2" />
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
  // Allow numeric shortcuts like /h1, /h2, and /h3.
  const match = beforeCaret.match(/(?:^|\s)\/([a-z0-9-]*)$/i);
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
        attrs: { level, collapsible: true },
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
): ResolvedMarkdownLine | null {
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
      const headingPos = resolvedPosition.before(headingDepth);
      const headingSection = findHeadingSectionAtPosition(editor.state, headingPos);
      return buildResolvedMarkdownLine(editor, {
        selectionPos: resolvedPosition.start(headingDepth),
        insertAt: headingSection?.sectionEnd ?? resolvedPosition.after(headingDepth),
        tag: headingLevelToTag(Number(headingNode.attrs.level ?? 1)),
        replaceFrom: headingPos,
        replaceTo: resolvedPosition.after(headingDepth),
        previewFrom: resolvedPosition.start(headingDepth),
        previewTo: resolvedPosition.end(headingDepth),
        headingCollapsible: headingSection?.isCollapsible ?? headingNode.attrs.collapsible !== false,
      });
    }

    const codeBlockDepth = findAncestorDepth(resolvedPosition, "codeBlock");
    if (codeBlockDepth !== null) {
      return buildResolvedMarkdownLine(editor, {
        selectionPos: resolvedPosition.start(codeBlockDepth),
        insertAt: resolvedPosition.after(codeBlockDepth),
        tag: "code",
        replaceFrom: resolvedPosition.before(codeBlockDepth),
        replaceTo: resolvedPosition.after(codeBlockDepth),
        previewFrom: resolvedPosition.start(codeBlockDepth),
        previewTo: resolvedPosition.end(codeBlockDepth),
      });
    }

    const listItemDepth = findAncestorDepth(resolvedPosition, "listItem");
    if (listItemDepth !== null) {
      if (findAncestorDepth(resolvedPosition, "taskList") !== null) {
        return buildResolvedMarkdownLine(editor, {
          selectionPos: resolvedPosition.pos,
          insertAt: resolvedPosition.after(listItemDepth),
          tag: "todo",
          replaceFrom: resolvedPosition.before(listItemDepth),
          replaceTo: resolvedPosition.after(listItemDepth),
          previewFrom: resolvedPosition.start(listItemDepth),
          previewTo: resolvedPosition.end(listItemDepth),
        });
      }
      if (findAncestorDepth(resolvedPosition, "orderedList") !== null) {
        return buildResolvedMarkdownLine(editor, {
          selectionPos: resolvedPosition.pos,
          insertAt: resolvedPosition.after(listItemDepth),
          tag: "numbered",
          replaceFrom: resolvedPosition.before(listItemDepth),
          replaceTo: resolvedPosition.after(listItemDepth),
          previewFrom: resolvedPosition.start(listItemDepth),
          previewTo: resolvedPosition.end(listItemDepth),
        });
      }
      if (findAncestorDepth(resolvedPosition, "bulletList") !== null) {
        return buildResolvedMarkdownLine(editor, {
          selectionPos: resolvedPosition.pos,
          insertAt: resolvedPosition.after(listItemDepth),
          tag: "bullet",
          replaceFrom: resolvedPosition.before(listItemDepth),
          replaceTo: resolvedPosition.after(listItemDepth),
          previewFrom: resolvedPosition.start(listItemDepth),
          previewTo: resolvedPosition.end(listItemDepth),
        });
      }
    }

    const blockquoteDepth = findAncestorDepth(resolvedPosition, "blockquote");
    if (blockquoteDepth !== null) {
      return buildResolvedMarkdownLine(editor, {
        selectionPos: resolvedPosition.pos,
        insertAt: resolvedPosition.after(blockquoteDepth),
        tag: "quote",
        replaceFrom: resolvedPosition.before(blockquoteDepth),
        replaceTo: resolvedPosition.after(blockquoteDepth),
        previewFrom: resolvedPosition.start(blockquoteDepth),
        previewTo: resolvedPosition.end(blockquoteDepth),
      });
    }

    const paragraphDepth = findAncestorDepth(resolvedPosition, "paragraph");
    if (paragraphDepth !== null) {
      return buildResolvedMarkdownLine(editor, {
        selectionPos: resolvedPosition.pos,
        insertAt: resolvedPosition.after(paragraphDepth),
        tag: "paragraph",
        replaceFrom: resolvedPosition.before(paragraphDepth),
        replaceTo: resolvedPosition.after(paragraphDepth),
        previewFrom: resolvedPosition.start(paragraphDepth),
        previewTo: resolvedPosition.end(paragraphDepth),
      });
    }

    return buildResolvedMarkdownLine(editor, {
      selectionPos: resolvedPosition.pos,
      insertAt: resolvedPosition.pos,
      tag: "paragraph",
      replaceFrom: resolvedPosition.pos,
      replaceTo: resolvedPosition.pos,
      previewFrom: resolvedPosition.pos,
      previewTo: resolvedPosition.pos,
    });
  } catch {
    return null;
  }
}

function buildResolvedMarkdownLine(
  editor: Editor,
  base: Omit<ResolvedMarkdownLine, "text">
): ResolvedMarkdownLine {
  const text = editor.state.doc
    .textBetween(base.previewFrom, base.previewTo, "\n\n")
    .trim();
  return {
    ...base,
    text,
  };
}

function applyMarkdownLineTag(
  editor: Editor,
  selectionPos: number,
  currentTag: MarkdownLineTag,
  nextTag: MarkdownLineTag,
  headingCollapsible?: boolean
) {
  if (
    isHeadingLineTag(nextTag) &&
    tryApplyHeadingWithinListItem(editor, selectionPos, nextTag, headingCollapsible)
  ) {
    return;
  }

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
      nextChain.setNode("heading", { level: 1, collapsible: headingCollapsible ?? true }).run();
      return;
    case "heading2":
      nextChain.setNode("heading", { level: 2, collapsible: headingCollapsible ?? true }).run();
      return;
    case "heading3":
      nextChain.setNode("heading", { level: 3, collapsible: headingCollapsible ?? true }).run();
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

function handleSelectedListIndent(
  editor: Editor,
  direction: "indent" | "outdent"
): boolean {
  const { state, view } = editor;
  if (state.selection.empty || editor.isActive("table")) {
    return false;
  }

  const selectedItems = collectSelectedTopLevelListItems(state);
  if (selectedItems.length === 0) {
    return false;
  }

  const [firstItem] = selectedItems;
  if (
    !selectedItems.every(
      (item) => item.typeName === firstItem.typeName && item.parentNode === firstItem.parentNode
    )
  ) {
    return false;
  }

  const lastItem = selectedItems[selectedItems.length - 1];
  const selection = TextSelection.between(
    state.doc.resolve(firstItem.pos + 1),
    state.doc.resolve(lastItem.end - 1)
  );

  view.dispatch(state.tr.setSelection(selection));

  return direction === "indent"
    ? editor.commands.sinkListItem(firstItem.typeName)
    : editor.commands.liftListItem(firstItem.typeName);
}

function collectSelectedTopLevelListItems(
  state: Editor["state"]
): SelectedListItemRange[] {
  const { from, to } = state.selection;
  const ranges: SelectedListItemRange[] = [];

  state.doc.nodesBetween(from, to, (node, pos, parent) => {
    if (!parent) {
      return true;
    }

    if (node.type.name !== "listItem" && node.type.name !== "taskItem") {
      return true;
    }

    ranges.push({
      typeName: node.type.name,
      pos,
      end: pos + node.nodeSize,
      parentNode: parent,
    });
    return false;
  });

  return ranges;
}

function tryApplyHeadingWithinListItem(
  editor: Editor,
  selectionPos: number,
  nextTag: Extract<MarkdownLineTag, "heading1" | "heading2" | "heading3">,
  headingCollapsible?: boolean
): boolean {
  try {
    const resolvedPosition = editor.state.doc.resolve(selectionPos);
    if (findAncestorDepth(resolvedPosition, "listItem") === null) {
      return false;
    }

    const headingAttrs = headingAttributesForTag(nextTag, headingCollapsible);
    if (!headingAttrs) {
      return false;
    }

    return editor
      .chain()
      .focus()
      .setTextSelection(selectionPos)
      .setNode("heading", headingAttrs)
      .run();
  } catch {
    return false;
  }
}

function headingAttributesForTag(
  tag: MarkdownLineTag,
  headingCollapsible?: boolean
): { level: 1 | 2 | 3; collapsible: boolean } | null {
  switch (tag) {
    case "heading1":
      return { level: 1, collapsible: headingCollapsible ?? true };
    case "heading2":
      return { level: 2, collapsible: headingCollapsible ?? true };
    case "heading3":
      return { level: 3, collapsible: headingCollapsible ?? true };
    default:
      return null;
  }
}

function resolveSummaryTargetFromSelection(
  editor: Editor | null,
  from?: number,
  to?: number,
  insertAt?: number
): SummaryTarget | null {
  if (typeof from !== "number" || typeof to !== "number" || to <= from) {
    return null;
  }

  if (!editor) {
    return {
      kind: "selection",
      from,
      to,
      insertAt: insertAt ?? to,
    };
  }

  const editorView = resolveEditorView(editor);
  if (!editorView) {
    return {
      kind: "selection",
      from,
      to,
      insertAt: insertAt ?? to,
    };
  }

  try {
    const startPosition = editor.state.doc.resolve(from);
    const endPosition = editor.state.doc.resolve(Math.max(from, to - 1));
    const headingDepth = findAncestorDepth(startPosition, "heading");
    const matchesSingleHeading =
      headingDepth !== null &&
      findAncestorDepth(endPosition, "heading") === headingDepth &&
      startPosition.before(headingDepth) === endPosition.before(headingDepth);

    if (matchesSingleHeading && headingDepth !== null) {
      const headingPos = startPosition.before(headingDepth);
      const headingSection = findHeadingSectionAtPosition(editor.state, headingPos);
      return {
        kind: "selection",
        from: headingPos,
        to: startPosition.after(headingDepth),
        insertAt: headingSection?.sectionEnd ?? insertAt ?? startPosition.after(headingDepth),
      };
    }
  } catch {
    return {
      kind: "selection",
      from,
      to,
      insertAt: insertAt ?? to,
    };
  }

  return {
    kind: "selection",
    from,
    to,
    insertAt: insertAt ?? to,
  };
}

function findHeadingSectionAtSelection(
  editor: Editor,
  selectionPos: number = editor.state.selection.from
) {
  try {
    const resolvedPosition = editor.state.doc.resolve(selectionPos);
    const headingDepth = findAncestorDepth(resolvedPosition, "heading");
    if (headingDepth === null) {
      return null;
    }

    return findHeadingSectionAtPosition(
      editor.state,
      resolvedPosition.before(headingDepth)
    );
  } catch {
    return null;
  }
}

function insertParagraphAfterSection(editor: Editor, sectionEnd: number): boolean {
  const insertAt = Math.min(sectionEnd, editor.state.doc.content.size);

  // If the section extends to the document end, the new paragraph would also
  // become part of the section and get hidden. Uncollapse the section first
  // so the new content stays visible.
  if (insertAt >= editor.state.doc.content.size) {
    const view = resolveEditorView(editor);
    if (view) {
      const section = findCollapsedHeadingSectionAtSelection(
        editor.state,
        Math.max(0, insertAt - 1)
      );
      if (section) {
        uncollapseHeadingAtPosition(view, section.headingPos);
      }
    }
  }

  const newInsertAt = Math.min(sectionEnd, editor.state.doc.content.size);
  return editor
    .chain()
    .focus()
    .insertContentAt(newInsertAt, [{ type: "paragraph" }])
    .setTextSelection(newInsertAt + 1)
    .run();
}

function focusBlankEditorSpace(
  editor: Editor,
  target: Element,
  event: MouseEvent,
  editorBody: HTMLDivElement | null
): boolean {
  if (!editorBody || !editorBody.contains(target)) {
    return false;
  }

  const editorView = resolveEditorView(editor);
  const editorDom = resolveEditorDOM(editor);
  if (!editorView || !editorDom) {
    return false;
  }

  const clickedDirectlyOnEditorChrome =
    target === editorBody ||
    target === editorDom ||
    target.classList.contains("thread-note-editor-content");
  if (!clickedDirectlyOnEditorChrome) {
    return false;
  }

  const lastVisibleBlock = findLastVisibleTopLevelBlock(editor);
  if (!lastVisibleBlock) {
    return false;
  }

  const lastVisibleDOMNode = editorView.nodeDOM(lastVisibleBlock.pos);
  const lastVisibleElement =
    lastVisibleDOMNode instanceof Element ? lastVisibleDOMNode : lastVisibleDOMNode?.parentElement;
  if (!lastVisibleElement) {
    return false;
  }

  const bodyRect = editorBody.getBoundingClientRect();
  const lastVisibleRect = lastVisibleElement.getBoundingClientRect();
  const clickedBelowLastVisibleBlock =
    event.clientY > lastVisibleRect.bottom + 2 && event.clientY <= bodyRect.bottom;
  if (!clickedBelowLastVisibleBlock) {
    return false;
  }

  event.preventDefault();
  event.stopPropagation();

  if (lastVisibleBlock.node.type.name === "paragraph") {
    return editor.commands.focus("end");
  }

  return insertParagraphAfterSection(editor, lastVisibleBlock.insertAt);
}

function findLastVisibleTopLevelBlock(editor: Editor): VisibleTopLevelBlock | null {
  const blocks: Array<{ pos: number; node: ProseMirrorNode }> = [];

  editor.state.doc.forEach((node, offset) => {
    blocks.push({
      pos: offset,
      node,
    });
  });

  let lastVisibleBlock: VisibleTopLevelBlock | null = null;

  for (let index = 0; index < blocks.length; index += 1) {
    const block = blocks[index];
    if (block.node.type.name === "heading") {
      const headingSection = findHeadingSectionAtPosition(editor.state, block.pos);
      if (headingSection?.isCollapsed) {
        lastVisibleBlock = {
          pos: block.pos,
          node: block.node,
          insertAt: headingSection.sectionEnd,
        };

        while (index + 1 < blocks.length && blocks[index + 1].pos < headingSection.sectionEnd) {
          index += 1;
        }
        continue;
      }
    }

    lastVisibleBlock = {
      pos: block.pos,
      node: block.node,
      insertAt: block.pos + block.node.nodeSize,
    };
  }

  return lastVisibleBlock;
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

function isHeadingLineTag(tag?: MarkdownLineTag): tag is "heading1" | "heading2" | "heading3" {
  return tag === "heading1" || tag === "heading2" || tag === "heading3";
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

function truncateContextMenuPreview(text: string): string {
  const normalized = text.replace(/\s+/g, " ").trim();
  if (normalized.length <= 120) {
    return normalized;
  }
  return `${normalized.slice(0, 117).trimEnd()}...`;
}
