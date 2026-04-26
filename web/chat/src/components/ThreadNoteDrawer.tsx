import {
  Component,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type MouseEvent as ReactMouseEvent,
  type ReactNode,
  type RefObject,
} from "react";
import { EditorContent, useEditor, type Editor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import { Placeholder } from "@tiptap/extension-placeholder";
import { TableKit } from "@tiptap/extension-table";
import { TaskItem } from "@tiptap/extension-task-item";
import { TaskList } from "@tiptap/extension-task-list";
import { Markdown } from "@tiptap/markdown";
import { Fragment } from "@tiptap/pm/model";
import type { Node as ProseMirrorNode, ResolvedPos, Slice } from "@tiptap/pm/model";
import { NodeSelection, Selection, TextSelection } from "@tiptap/pm/state";
import type { EditorView } from "@tiptap/pm/view";
import { all, createLowlight } from "lowlight";
import { ThreadNoteCodeBlock } from "./ThreadNoteCodeBlock";
import { ThreadNoteImage } from "./ThreadNoteImage";
import {
  findCollapsedHeadingSectionAtSelection,
  findContainingHeadingSectionAtSelection,
  findHeadingSectionAtPosition,
  resolveHeadingAlignmentAtSelection,
  ThreadNoteCollapsibleHeading,
  type ThreadNoteHeadingAlignment,
  type ThreadNoteHeadingSection,
  uncollapseHeadingAtPosition,
  updateHeadingAlignmentAtSelection,
  updateHeadingCollapsibleAtSelection,
} from "./ThreadNoteCollapsibleHeading";
import { MarkdownContent } from "./MarkdownContent";
import {
  detectMermaidTemplateType,
  isMermaidLanguage,
  normalizeMermaidSource,
  sanitizeMermaidMarkdownBlocks,
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
import type {
  BatchNotePlanPreview,
  BatchNotePlanProposedLink,
  BatchNotePlanProposedNote,
  BatchNotePlanResolvedTarget,
  BatchNotePlanSourceNote,
  ThreadNoteState,
} from "../types";
import { MermaidDiagram } from "./MermaidDiagram";
import {
  buildInternalNoteHref,
  buildInternalNoteMarkdownLink,
  parseInternalNoteHref,
  type InternalNoteLinkTarget,
} from "./noteLinkUtils";
import {
  buildThreadNoteMarkdownImage,
  normalizeThreadNoteMarkdownForRichText,
} from "./threadNoteImageMarkdown";
import {
  appendMarkdownToNote,
  insertMarkdownAboveSelection,
  insertMarkdownBelowSelection,
  normalizeThreadNoteStoredMarkdown,
  prependMarkdownToNote,
  replaceMarkdownRange,
  replaceSelectionInMarkdown,
} from "./threadNoteMarkdownEditing";
import { groupSlashCommands, matchesSlashCommand } from "./slashCommandUtils";

interface Props {
  state: ThreadNoteState | null;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}

interface ThreadNoteErrorBoundaryProps {
  children: ReactNode;
  resetKey: string;
  state: ThreadNoteState | null;
}

interface ThreadNoteErrorBoundaryState {
  hasError: boolean;
}

class ThreadNoteErrorBoundary extends Component<
  ThreadNoteErrorBoundaryProps,
  ThreadNoteErrorBoundaryState
> {
  state: ThreadNoteErrorBoundaryState = {
    hasError: false,
  };

  static getDerivedStateFromError(): ThreadNoteErrorBoundaryState {
    return { hasError: true };
  }

  componentDidCatch(error: unknown) {
    console.error("Thread note view crashed", error);
  }

  componentDidUpdate(prevProps: ThreadNoteErrorBoundaryProps) {
    if (prevProps.resetKey !== this.props.resetKey && this.state.hasError) {
      this.setState({ hasError: false });
    }
  }

  render() {
    if (!this.state.hasError) {
      return this.props.children;
    }

    return (
      <div className="thread-note-fallback-shell">
        <div className="thread-note-fallback-banner">
          This note had a display problem. Showing the saved Markdown below so nothing is lost.
        </div>
        <div className="thread-note-fallback-title">
          {this.props.state?.selectedNoteTitle?.trim() || "Untitled note"}
        </div>
        <textarea
          className="thread-note-fallback-textarea"
          value={this.props.state?.text ?? ""}
          readOnly
          spellCheck={false}
        />
      </div>
    );
  }
}

interface SlashQueryState {
  query: string;
  replaceFrom: number;
  replaceTo: number;
}

type ThreadNoteFindAction = "search" | "activate" | "clear";

interface ThreadNoteFindResponse {
  handled: boolean;
  matchCount: number;
  currentMatch: number;
}

interface ThreadNoteFindRequestDetail {
  action: ThreadNoteFindAction;
  query?: string;
  index?: number;
  respond: (result: ThreadNoteFindResponse) => void;
}

interface ThreadNoteSearchMatch {
  from: number;
  to: number;
  collapsedHeadingPositions: number[];
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

interface RawMarkdownSelectionOffsets {
  startOffset: number;
  endOffset?: number;
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

type MarkdownInsertAction = "divider" | "table";

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
  from?: number;
  to?: number;
  selectedMarkdown?: string;
  snapshotMarkdown?: string;
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

interface RecoveryPreviewState {
  kind: "history" | "deleted";
  id: string;
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

interface ProjectNoteTransferState {
  selectedText: string;
  selectedMarkdown: string;
  from: number;
  to: number;
  targetProjectId: string;
  targetNoteId: string | null;
  transferMode: "copy" | "move";
  step: "picker" | "preview";
  isApplying: boolean;
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

interface SelectionCollapsibleSectionDraft {
  replaceFrom: number;
  replaceTo: number;
  headingLevel: 1 | 2 | 3;
  headingTitle: string;
  bodyMarkdown: string;
  emptyBodyMarker: string | null;
}

interface SelectedListItemRange {
  typeName: "listItem" | "taskItem";
  pos: number;
  end: number;
  parentNode: ProseMirrorNode;
}

interface ThreadNoteInternalDragData {
  from: number;
  to: number;
  move: boolean;
}

interface ThreadNoteSourceSection {
  source: NonNullable<ThreadNoteState["availableSources"]>[number];
  allNotes: ThreadNoteState["notes"];
  visibleNotes: ThreadNoteState["notes"];
}

interface BatchOrganizerSection {
  source: NonNullable<ThreadNoteState["availableSources"]>[number];
  allNotes: ThreadNoteState["notes"];
  visibleNotes: ThreadNoteState["notes"];
}

interface ChartChoiceOption {
  type: ChartChoiceType;
  label: string;
  description: string;
}

interface SelectedImageState {
  alt: string;
  title: string;
  width: number | null;
}

interface PendingImagePickerInsert {
  from: number;
  to: number;
}

interface ThreadNoteImageUploadResult {
  requestId: string;
  ok: boolean;
  message?: string;
  url?: string;
  relativePath?: string;
}

type ThreadNoteScreenshotImportMode = "rawOCR" | "cleanText" | "cleanTextAndImage";

interface ThreadNoteScreenshotCaptureResult {
  requestId: string;
  ok: boolean;
  cancelled?: boolean;
  message?: string;
  filename?: string;
  mimeType?: string;
  dataUrl?: string;
  captureMode?: ThreadNoteScreenshotCaptureMode;
  segmentCount?: number;
}

interface ThreadNoteScreenshotProcessingResult {
  requestId: string;
  ok: boolean;
  message?: string;
  outputMode?: ThreadNoteScreenshotImportMode;
  markdown?: string;
  rawText?: string;
  usedVision?: boolean;
}

interface ThreadNoteScreenshotImportState {
  captures: ThreadNoteScreenshotCaptureResult[];
  capture: ThreadNoteScreenshotCaptureResult;
  insertRange: PendingImagePickerInsert;
  outputMode: ThreadNoteScreenshotImportMode;
  customInstruction: string;
  isProcessing: boolean;
  processed: ThreadNoteScreenshotProcessingResult | null;
  error: string | null;
}

type ThreadNoteScreenshotCaptureMode = "area" | "scrolling" | "multiple";

const THREAD_NOTE_SCREENSHOT_CAPTURE_MODE_STORAGE_KEY =
  "openassist.thread-note-screenshot-capture-mode";

const THREAD_NOTE_SCREENSHOT_CAPTURE_MODE_OPTIONS: ReadonlyArray<{
  value: ThreadNoteScreenshotCaptureMode;
  label: string;
  chipLabel: string;
  selectionNotice: string;
}> = [
  {
    value: "area",
    label: "Area screenshot",
    chipLabel: "Area",
    selectionNotice: "Screenshot mode set to Area.",
  },
  {
    value: "scrolling",
    label: "Scrolling capture",
    chipLabel: "Scroll",
    selectionNotice:
      "Screenshot mode set to Scrolling. Capture one section, scroll that same content, then add the next section.",
  },
  {
    value: "multiple",
    label: "Multiple captures",
    chipLabel: "Multiple",
    selectionNotice:
      "Screenshot mode set to Multiple. Use this when you want several screenshots. Open Assist will merge useful repeated info into one note when it can.",
  },
];

const THREAD_NOTE_SCREENSHOT_MODE_OPTIONS: ReadonlyArray<{
  value: ThreadNoteScreenshotImportMode;
  label: string;
  description: string;
}> = [
  {
    value: "rawOCR",
    label: "Raw OCR",
    description: "Paste the text exactly as found.",
  },
  {
    value: "cleanText",
    label: "Clean",
    description: "Use AI to make it easier to read.",
  },
  {
    value: "cleanTextAndImage",
    label: "Clean + image",
    description: "Keep the screenshot and add the cleaned note.",
  },
];

interface VisibleTopLevelBlock {
  pos: number;
  node: ProseMirrorNode;
  insertAt: number;
}

const THREAD_NOTE_SAVE_DEBOUNCE_MS = 600;
// Per-save ack timeout. If Swift doesn't ack within this, retry.
const THREAD_NOTE_SAVE_ACK_TIMEOUT_MS = 10000;
const THREAD_NOTE_NAVIGATION_SAVE_TIMEOUT_MS = 3500;
// Backoff steps for save retries on explicit error or timeout.
const THREAD_NOTE_SAVE_RETRY_DELAYS_MS: readonly number[] = [500, 1000, 2000, 4000];
const DEFAULT_COLLAPSIBLE_SECTION_BODY = "Add notes here.";
const THREAD_NOTE_HEADING_DROP_TARGET_CLASS = "is-drop-target";
const THREAD_NOTE_INTERNAL_DRAG_MIME = "application/x-openassist-note-drag";
const THREAD_NOTE_IMAGE_RESULT_EVENT = "openassist:thread-note-image-result";
const THREAD_NOTE_SCREENSHOT_CAPTURE_RESULT_EVENT =
  "openassist:thread-note-screenshot-capture-result";
const THREAD_NOTE_SCREENSHOT_PROCESSING_RESULT_EVENT =
  "openassist:thread-note-screenshot-processing-result";
const THREAD_NOTE_FIND_REQUEST_EVENT = "openassist:thread-note-find-request";
const THREAD_NOTE_IMAGE_UPLOAD_TIMEOUT_MS = 12000;
const THREAD_NOTE_SCREENSHOT_CAPTURE_TIMEOUT_MS = 45000;
const THREAD_NOTE_SCREENSHOT_PROCESSING_TIMEOUT_MS = 45000;
const THREAD_NOTE_SCREENSHOT_PROCESSING_TIMEOUT_MAX_MS = 150000;
const THREAD_NOTE_SUPPORTED_IMAGE_MIME_TYPES = new Set([
  "image/png",
  "image/jpeg",
  "image/jpg",
  "image/gif",
  "image/webp",
  "image/tiff",
]);
const THREAD_NOTE_SUPPORTED_IMAGE_EXTENSIONS = new Set([
  "png",
  "jpg",
  "jpeg",
  "gif",
  "webp",
  "tif",
  "tiff",
]);
const DEFAULT_THREAD_NOTE_MENU_POSITION: ThreadNoteMenuPosition = {
  left: 16,
  top: 16,
  bottom: null,
  maxHeight: 320,
};

function readStoredThreadNoteScreenshotCaptureMode(): ThreadNoteScreenshotCaptureMode {
  if (typeof window === "undefined") {
    return "area";
  }

  try {
    const value = window.localStorage.getItem(THREAD_NOTE_SCREENSHOT_CAPTURE_MODE_STORAGE_KEY);
    if (
      value === "area" ||
      value === "scrolling" ||
      value === "multiple"
    ) {
      return value;
    }
  } catch (error) {
    console.warn("[thread-note screenshot] could not read capture mode", error);
  }

  return "area";
}

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

function noteSourceSectionLabel(source: ThreadNoteSource): string {
  if (source.ownerKind === "thread") {
    return source.ownerTitle?.trim() || source.sourceLabel;
  }
  return source.sourceLabel;
}

function noteTypeLabel(noteType?: string | null): string {
  switch ((noteType ?? "note").trim().toLowerCase()) {
    case "master":
      return "Master";
    case "decision":
      return "Decision";
    case "task":
      return "Task";
    case "reference":
      return "Reference";
    case "question":
      return "Question";
    case "note":
    default:
      return "Note";
  }
}

function batchSourceSelectionKeyFromParts(
  ownerKind: string,
  ownerId: string,
  noteId: string
): string {
  return `${ownerKind}:${ownerId}:${noteId}`;
}

function batchSourceSelectionKeyForNote(note: {
  ownerKind: string;
  ownerId: string;
  id: string;
}): string {
  return batchSourceSelectionKeyFromParts(note.ownerKind, note.ownerId, note.id);
}

function batchSourceSelectionKeyForSourceNote(note: BatchNotePlanSourceNote): string {
  return batchSourceSelectionKeyFromParts(note.ownerKind, note.ownerId, note.noteId);
}

function batchSourceSelectionPayload(selectionKey: string) {
  const [ownerKind, ownerId, noteId, ...rest] = selectionKey.split(":");
  if (!ownerKind || !ownerId || !noteId || rest.length > 0) {
    return null;
  }
  return { ownerKind, ownerId, noteId };
}

function batchResolvedTargetKey(target: BatchNotePlanResolvedTarget): string {
  return [
    target.kind,
    target.tempId ?? "",
    target.ownerKind ?? "",
    target.ownerId ?? "",
    target.noteId ?? "",
  ]
    .join("::")
    .toLowerCase();
}

function batchPlanEditableLinkKey(link: BatchNotePlanProposedLink): string {
  return `${link.fromTempId.toLowerCase()}::${batchResolvedTargetKey(link.toTarget)}`;
}

function batchResolvedTargetLabel(target: BatchNotePlanResolvedTarget): string {
  return normalizeThreadNoteTitle(target.title);
}

function escapeBatchGraphLabel(value: string): string {
  return value
    .replaceAll("\\", "\\\\")
    .replaceAll("\"", "\\\"");
}

function buildBatchNotePlanPreviewGraph(
  sourceNotes: BatchNotePlanSourceNote[],
  proposedNotes: BatchNotePlanProposedNote[],
  proposedLinks: BatchNotePlanProposedLink[]
) {
  const acceptedNotes = proposedNotes.filter((note) => note.accepted);
  if (!acceptedNotes.length) {
    return null;
  }

  const acceptedTempIds = new Set(acceptedNotes.map((note) => note.tempId.toLowerCase()));
  const sourceNodeIds = new Set(
    sourceNotes.map((note) =>
      batchSourceSelectionKeyFromParts(note.ownerKind, note.ownerId, note.noteId)
    )
  );

  const nodes = [
    ...sourceNotes.map((note) => ({
      id: batchSourceSelectionKeyFromParts(note.ownerKind, note.ownerId, note.noteId),
      title: normalizeThreadNoteTitle(note.title),
      kind: "source" as const,
      noteType: note.noteType,
    })),
    ...acceptedNotes.map((note) => ({
      id: note.tempId,
      title: normalizeThreadNoteTitle(note.title),
      kind: "proposed" as const,
      noteType: note.noteType,
    })),
  ];

  const edges = proposedLinks.flatMap((link) => {
    const fromKey = link.fromTempId.toLowerCase();
    if (!link.accepted || !acceptedTempIds.has(fromKey)) {
      return [];
    }

    if (link.toTarget.kind === "proposed") {
      const targetTempId = link.toTarget.tempId?.trim();
      if (!targetTempId || !acceptedTempIds.has(targetTempId.toLowerCase())) {
        return [];
      }
      return [{ fromNodeId: link.fromTempId, toNodeId: targetTempId }];
    }

    const ownerKind = link.toTarget.ownerKind?.trim();
    const ownerId = link.toTarget.ownerId?.trim();
    const noteId = link.toTarget.noteId?.trim();
    if (!ownerKind || !ownerId || !noteId) {
      return [];
    }
    const sourceNodeId = batchSourceSelectionKeyFromParts(ownerKind, ownerId, noteId);
    if (!sourceNodeIds.has(sourceNodeId)) {
      return [];
    }
    return [{ fromNodeId: link.fromTempId, toNodeId: sourceNodeId }];
  });

  if (!edges.length) {
    return {
      mermaidCode: [
        "flowchart LR",
        ...nodes.map((node, index) => `  N${index}["${escapeBatchGraphLabel(node.title)}"]`),
      ].join("\n"),
      nodeCount: nodes.length,
      edgeCount: 0,
    };
  }

  const orderedNodes = [...nodes].sort((left, right) => {
    if (left.kind !== right.kind) {
      return left.kind === "proposed" ? -1 : 1;
    }
    if (left.noteType === "master" || right.noteType === "master") {
      return left.noteType === "master" ? -1 : 1;
    }
    return left.title.localeCompare(right.title, undefined, { sensitivity: "base" });
  });

  const orderedEdges = [...edges].sort((left, right) => {
    const fromCompare = left.fromNodeId.localeCompare(right.fromNodeId, undefined, {
      sensitivity: "base",
    });
    if (fromCompare !== 0) {
      return fromCompare;
    }
    return left.toNodeId.localeCompare(right.toNodeId, undefined, {
      sensitivity: "base",
    });
  });

  const nodeAliasById = new Map(orderedNodes.map((node, index) => [node.id, `N${index}`]));
  const lines = ["flowchart LR"];

  orderedNodes.forEach((node) => {
    lines.push(
      `  ${nodeAliasById.get(node.id)}["${escapeBatchGraphLabel(node.title)}"]`
    );
  });

  orderedEdges.forEach((edge) => {
    const fromAlias = nodeAliasById.get(edge.fromNodeId);
    const toAlias = nodeAliasById.get(edge.toNodeId);
    if (!fromAlias || !toAlias) {
      return;
    }
    lines.push(`  ${fromAlias} --> ${toAlias}`);
  });

  lines.push("  classDef source fill:#7c87961c,stroke:#7c8796,stroke-width:1px;");
  lines.push("  classDef proposed fill:#6aa6ff1f,stroke:#6aa6ff,stroke-width:1.4px;");
  lines.push("  classDef master fill:#f59e0b22,stroke:#f59e0b,stroke-width:2px;");

  const sourceAliases = orderedNodes
    .filter((node) => node.kind === "source")
    .map((node) => nodeAliasById.get(node.id))
    .filter(Boolean);
  if (sourceAliases.length) {
    lines.push(`  class ${sourceAliases.join(",")} source;`);
  }

  const proposedAliases = orderedNodes
    .filter((node) => node.kind === "proposed" && node.noteType !== "master")
    .map((node) => nodeAliasById.get(node.id))
    .filter(Boolean);
  if (proposedAliases.length) {
    lines.push(`  class ${proposedAliases.join(",")} proposed;`);
  }

  const masterAliases = orderedNodes
    .filter((node) => node.noteType === "master")
    .map((node) => nodeAliasById.get(node.id))
    .filter(Boolean);
  if (masterAliases.length) {
    lines.push(`  class ${masterAliases.join(",")} master;`);
  }

  return {
    mermaidCode: lines.join("\n"),
    nodeCount: orderedNodes.length,
    edgeCount: orderedEdges.length,
  };
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
    description: "Regular section heading",
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

function buildImageSlashCommands(
  openImagePicker: (range?: PendingImagePickerInsert) => void
): SlashCommand[] {
  return [
    makeCommand(
      "image",
      "Image",
      "Upload an image from your Mac",
      (editor, range) => {
        editor
          .chain()
          .focus()
          .deleteRange({ from: range.replaceFrom, to: range.replaceTo })
          .run();
        openImagePicker({ from: range.replaceFrom, to: range.replaceFrom });
      },
      BLOCK_GROUP_META,
      ["photo", "picture", "upload"]
    ),
  ];
}

export function ThreadNoteDrawer({ state, onDispatchCommand }: Props) {
  const threadId = state?.threadId ?? null;
  const isNotesWorkspace = state?.presentation === "notesWorkspace";
  const sourceDescriptor = state?.sourceDescriptor ?? null;
  const isExternalMarkdownFile = sourceDescriptor?.sourceKind === "externalMarkdownFile";
  const ownerKind =
    state?.ownerKind ??
    (state?.notesScope === "project" ? "project" : state?.notesScope === "thread" ? "thread" : null);
  const ownerId = state?.ownerId ?? state?.workspaceProjectId ?? null;
  const isProjectFullScreen = state?.presentation === "projectFullScreen";
  const isFullScreenWorkspace = isProjectFullScreen || isNotesWorkspace;
  const isAvailable = isNotesWorkspace
    ? Boolean(state?.isOpen)
    : Boolean((ownerKind && ownerId) || isExternalMarkdownFile) && Boolean(state?.canEdit);
  const isOpen = Boolean(state?.isOpen && isAvailable);
  const layerRef = useRef<HTMLDivElement | null>(null);
  const placeholderText =
    state?.placeholder || "Write your thread note. Type / for Markdown blocks.";
  const statusLabel = state?.isSaving
    ? "Saving..."
    : isExternalMarkdownFile && sourceDescriptor?.isDirty
      ? "Unsaved changes"
      : state?.lastSavedAtLabel || "";

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

      {isOpen && (ownerKind || isExternalMarkdownFile) ? (
        <ThreadNoteErrorBoundary
          resetKey={`${sourceDescriptor?.sourceKind ?? "managedNote"}:${sourceDescriptor?.filePath ?? "no-file"}:${ownerKind ?? "no-owner-kind"}:${ownerId ?? "no-owner"}:${threadId ?? "no-thread"}:${state?.presentation ?? "drawer"}:${state?.viewMode ?? "edit"}:${state?.notesScope ?? "notes"}:${state?.selectedNoteId ?? "no-note"}`}
          state={state}
        >
          <ThreadNoteDrawerOpenContent
            key={`${sourceDescriptor?.sourceKind ?? "managedNote"}:${sourceDescriptor?.filePath ?? "no-file"}:${ownerKind ?? "no-owner-kind"}:${ownerId ?? "no-owner"}:${threadId ?? "no-thread"}:${state?.presentation ?? "drawer"}:${state?.viewMode ?? "edit"}:${state?.notesScope ?? "notes"}:${state?.selectedNoteId ?? "no-note"}`}
            state={state}
            threadId={threadId}
            ownerKind={ownerKind ?? "project"}
            ownerId={ownerId ?? ""}
            isProjectFullScreen={isProjectFullScreen}
            isNotesWorkspace={isNotesWorkspace}
            layerRef={layerRef}
            placeholderText={placeholderText}
            statusLabel={statusLabel}
            onDispatchCommand={onDispatchCommand}
          />
        </ThreadNoteErrorBoundary>
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
  const sourceDescriptor = state?.sourceDescriptor ?? null;
  const isExternalMarkdownFile = sourceDescriptor?.sourceKind === "externalMarkdownFile";
  const drawerRef = useRef<HTMLElement | null>(null);
  const floatingLayerRef = useRef<HTMLDivElement | null>(null);
  const editorBodyRef = useRef<HTMLDivElement>(null);
  const noteContextMenuRef = useRef<HTMLDivElement | null>(null);
  const headingTagSearchRef = useRef<HTMLInputElement | null>(null);
  const selectorButtonRef = useRef<HTMLButtonElement | null>(null);
  const selectorSearchInputRef = useRef<HTMLInputElement | null>(null);
  const noteLinkSearchInputRef = useRef<HTMLInputElement | null>(null);
  const renameInputRef = useRef<HTMLInputElement | null>(null);
  const imageInputRef = useRef<HTMLInputElement | null>(null);
  const liveEditorRef = useRef<Editor | null>(null);
  const rawMarkdownTextareaRef = useRef<HTMLTextAreaElement | null>(null);
  const threadNoteFindStateRef = useRef<{
    query: string;
    matches: ThreadNoteSearchMatch[];
    currentIndex: number;
  }>({
    query: "",
    matches: [],
    currentIndex: -1,
  });
  const isApplyingExternalContentRef = useRef(false);
  const isRichEditorReadyForInputRef = useRef(false);
  const openRef = useRef(false);
  const previousNoteKeyRef = useRef<string | null>(null);
  const slashQueryRef = useRef<SlashQueryState | null>(null);
  const filteredCommandsRef = useRef<SlashCommand[]>(BASE_SLASH_COMMANDS);
  const selectedSlashIndexRef = useRef(0);
  const mermaidPickerStateRef = useRef<MermaidTemplatePickerState | null>(null);
  const selectedMermaidIndexRef = useRef(0);
  const summaryTargetRef = useRef<SummaryTarget | null>(null);
  const pendingImagePickerInsertRef = useRef<PendingImagePickerInsert | null>(null);
  const latestImageUploadContextRef = useRef<{
    threadId: string | null;
    ownerKind: string;
    ownerId: string;
    noteId: string | null;
  }>({
    threadId,
    ownerKind,
    ownerId,
    noteId,
  });
  const pendingImageUploadsRef = useRef(
    new Map<
      string,
      {
        resolve: (result: ThreadNoteImageUploadResult) => void;
      }
    >()
  );
  const pendingScreenshotCapturesRef = useRef(
    new Map<
      string,
      {
        resolve: (result: ThreadNoteScreenshotCaptureResult) => void;
      }
    >()
  );
  const pendingScreenshotProcessingRef = useRef(
    new Map<
      string,
      {
        resolve: (result: ThreadNoteScreenshotProcessingResult) => void;
      }
    >()
  );
  const [noteEditorSurfaceMode, setNoteEditorSurfaceMode] = useState<"rich" | "markdown">("rich");
  const [forcedNoteEditorSurfaceMode, setForcedNoteEditorSurfaceMode] = useState<
    "markdown" | null
  >(null);
  const [draftText, setDraftText] = useState(normalizeLineEndings(state?.text ?? ""));
  const [hasLocalDirtyChanges, setHasLocalDirtyChanges] = useState(false);
  const [isSelectorOpen, setIsSelectorOpen] = useState(false);
  const [selectorFilter, setSelectorFilter] = useState("");
  const [isOverflowMenuOpen, setIsOverflowMenuOpen] = useState(false);
  const overflowMenuRef = useRef<HTMLDivElement | null>(null);
  const overflowMenuTriggerRef = useRef<HTMLButtonElement | null>(null);
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
  const [editorLoadNotice, setEditorLoadNotice] = useState<string | null>(null);
  const [imageNotice, setImageNotice] = useState<string | null>(null);
  const [screenshotNotice, setScreenshotNotice] = useState<string | null>(null);
  const [selectedImage, setSelectedImage] = useState<SelectedImageState | null>(null);
  const [isImageInspectorOpen, setIsImageInspectorOpen] = useState(false);
  const [isUploadingImage, setIsUploadingImage] = useState(false);
  const [isCapturingScreenshot, setIsCapturingScreenshot] = useState(false);
  const [screenshotCaptureMode, setScreenshotCaptureMode] =
    useState<ThreadNoteScreenshotCaptureMode>(readStoredThreadNoteScreenshotCaptureMode);
  const [screenshotCaptureMenuPosition, setScreenshotCaptureMenuPosition] = useState<{
    x: number;
    y: number;
  } | null>(null);
  const [screenshotImportState, setScreenshotImportState] =
    useState<ThreadNoteScreenshotImportState | null>(null);
  const [chartRequestComposer, setChartRequestComposer] =
    useState<ChartRequestComposerState | null>(null);
  const [projectNoteTransfer, setProjectNoteTransfer] =
    useState<ProjectNoteTransferState | null>(null);
  const [isBatchOrganizerOpen, setIsBatchOrganizerOpen] = useState(false);
  const [batchOrganizerSearch, setBatchOrganizerSearch] = useState("");
  const [batchOrganizerSelectedSourceKeys, setBatchOrganizerSelectedSourceKeys] = useState<
    string[]
  >([]);
  const [batchOrganizerSourcePreviewKey, setBatchOrganizerSourcePreviewKey] =
    useState<string | null>(null);
  const [batchOrganizerActiveNoteTempId, setBatchOrganizerActiveNoteTempId] =
    useState<string | null>(null);
  const [batchOrganizerEditableNotes, setBatchOrganizerEditableNotes] = useState<
    BatchNotePlanProposedNote[]
  >([]);
  const [batchOrganizerEditableLinks, setBatchOrganizerEditableLinks] = useState<
    BatchNotePlanProposedLink[]
  >([]);
  const [batchOrganizerIsApplying, setBatchOrganizerIsApplying] = useState(false);
  const [selectedChartType, setSelectedChartType] = useState<ChartChoiceType>("auto");
  const [chartStyleInstruction, setChartStyleInstruction] = useState("");
  const screenshotCaptureMenuRef = useRef<HTMLDivElement | null>(null);
  const activeScreenshotCaptureModeOption =
    THREAD_NOTE_SCREENSHOT_CAPTURE_MODE_OPTIONS.find(
      (option) => option.value === screenshotCaptureMode
    ) ?? THREAD_NOTE_SCREENSHOT_CAPTURE_MODE_OPTIONS[0];
  const activeScreenshotImportCaptureMode =
    screenshotImportState?.capture.captureMode ?? screenshotCaptureMode;
  const canAppendScreenshotImportCaptures = activeScreenshotImportCaptureMode !== "area";
  const screenshotImportAppendLabel =
    activeScreenshotImportCaptureMode === "scrolling"
      ? "Add next section"
      : "Add screenshot";
  const screenshotImportCaptureHint =
    activeScreenshotImportCaptureMode === "scrolling"
      ? "Scrolling keeps one long reading flow. Capture one section, scroll the same content, then add the next section."
      : activeScreenshotImportCaptureMode === "multiple"
        ? "Multiple can still be one topic. Open Assist will combine the useful parts and remove repeated info when that helps."
        : null;
  const activeScreenshotModeOption = screenshotImportState
    ? THREAD_NOTE_SCREENSHOT_MODE_OPTIONS.find(
        (option) => option.value === screenshotImportState.outputMode
      ) ?? THREAD_NOTE_SCREENSHOT_MODE_OPTIONS[0]
    : null;
  const [chartRenderError, setChartRenderError] = useState<string | null>(null);
  const [isChartDraftModalDismissed, setIsChartDraftModalDismissed] = useState(false);
  const [isHistoryPanelOpen, setIsHistoryPanelOpen] = useState(false);
  const [recoveryPreview, setRecoveryPreview] = useState<RecoveryPreviewState | null>(null);
  const notes = state?.notes ?? [];
  const normalizedBatchOrganizerSearch = batchOrganizerSearch.trim().toLowerCase();
  const batchOrganizerSections = useMemo<BatchOrganizerSection[]>(
    () =>
      (state?.availableSources ?? []).map((source) => {
        const sourceKey = noteSourceKey(source.ownerKind, source.ownerId);
        const allSourceNotes = notes.filter(
          (note) => noteSourceKey(note.ownerKind, note.ownerId) === sourceKey
        );
        const visibleSourceNotes = normalizedBatchOrganizerSearch
          ? allSourceNotes.filter((note) => {
              const titleMatch = normalizeThreadNoteTitle(note.title)
                .toLowerCase()
                .includes(normalizedBatchOrganizerSearch);
              const typeMatch = noteTypeLabel(note.noteType)
                .toLowerCase()
                .includes(normalizedBatchOrganizerSearch);
              return titleMatch || typeMatch;
            })
          : allSourceNotes;
        return {
          source,
          allNotes: allSourceNotes,
          visibleNotes: visibleSourceNotes,
        };
      }),
    [batchOrganizerSearch, normalizedBatchOrganizerSearch, notes, state?.availableSources]
  );
  const historyVersions = state?.historyVersions ?? [];
  const recentlyDeletedNotes = state?.recentlyDeletedNotes ?? [];
  const hasRecoveryItems = historyVersions.length > 0 || recentlyDeletedNotes.length > 0;
  const currentProjectTransferProjectId =
    state?.workspaceProjectId?.trim() ||
    state?.availableSources?.find((source) => source.ownerKind === "project")?.ownerId ||
    null;

  const isOpen = Boolean(state?.isOpen && state?.canEdit);
  const noteOwnerKey = `${ownerKind}:${ownerId}`;
  const currentSaveOwnerKey = isExternalMarkdownFile
    ? `external:${sourceDescriptor?.filePath ?? "file"}`
    : noteOwnerKey;
  const currentSaveNoteId = isExternalMarkdownFile
    ? sourceDescriptor?.filePath ?? "external-file"
    : noteId;
  const noteKey = isExternalMarkdownFile
    ? `external:${sourceDescriptor?.filePath ?? "none"}`
    : `${noteOwnerKey}:${noteId ?? "none"}`;
  const isRawMarkdownMode =
    noteEditorSurfaceMode === "markdown" || forcedNoteEditorSurfaceMode === "markdown";
  const isRichEditorMode = !isRawMarkdownMode;
  const isPreviewMode = state?.viewMode === "preview";
  const isSplitMode = state?.viewMode === "split";
  const showsEditorPane = !isPreviewMode;
  const showsPreviewPane = isPreviewMode || isSplitMode;
  const canCloseDrawer = true;
  const isExpanded = Boolean(state?.isExpanded);
  const aiDraftPreview = state?.aiDraftPreview ?? null;
  const projectNoteTransferPreview = state?.projectNoteTransferPreview ?? null;
  const projectNoteTransferOutcome = state?.projectNoteTransferOutcome ?? null;
  const batchNotePlanPreview = state?.batchNotePlanPreview ?? null;
  const aiDraftMode = state?.aiDraftMode ?? aiDraftPreview?.mode ?? null;
  const hasActiveAIDraft = Boolean(aiDraftPreview || (state?.isGeneratingAIDraft && aiDraftMode));
  const isProjectTransferBusy = Boolean(state?.isGeneratingProjectTransferPreview);
  const isBatchNotePlanBusy = Boolean(state?.isGeneratingBatchNotePlanPreview);
  const activeAIDraftMode = aiDraftPreview?.mode ?? aiDraftMode ?? "organize";
  const activeAIDraftSourceKind =
    aiDraftPreview?.sourceKind ??
    (activeAIDraftMode === "chart" ? "chatSelection" : noteSelection?.text ? "selection" : "whole");
  const isChartDraft = activeAIDraftMode === "chart";
  const isChartRequestComposerOpen = Boolean(chartRequestComposer);
  const hasActiveChartDraft = isChartDraft && hasActiveAIDraft;
  const hasChartRenderError = Boolean(chartRenderError?.trim());
  const isAIDraftError = Boolean(aiDraftPreview?.isError);
  const showAIDraftModal = isChartRequestComposerOpen
    ? true
    : isChartDraft
    ? hasActiveChartDraft && !isChartDraftModalDismissed
    : hasActiveAIDraft;
  const showChartDraftStatusCard = hasActiveChartDraft && isChartDraftModalDismissed;
  const shouldBlockDrawerEscape =
    isChartRequestComposerOpen ||
    Boolean(screenshotImportState) ||
    (hasActiveAIDraft && activeAIDraftMode !== "chart") ||
    Boolean(projectNoteTransfer) ||
    isBatchOrganizerOpen;
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
  const previousProjectTransferOutcomeIdRef = useRef<string | null>(null);
  const latestDraftTextRef = useRef(draftText);
  const hasLocalDirtyChangesRef = useRef(hasLocalDirtyChanges);
  const draftRevisionRef = useRef(0);
  const lastSavedDraftRevisionRef = useRef(0);
  // Track the most recent text we have told Swift about (either via
  // updateDraft or save). Used to distinguish a "stale echo" state
  // update (which should NOT overwrite newer local keystrokes) from a
  // genuinely new external change (which should).
  const lastSentToSwiftRef = useRef<string>(normalizeLineEndings(state?.text ?? ""));
  // Track the owner of the previously mounted note so we can flush its
  // pending edits before the UI switches to a different note.
  const previousOwnerKindRef = useRef<string | null>(ownerKind ?? null);
  const previousOwnerIdRef = useRef<string | null>(ownerId ?? null);
  const previousNoteIdRef = useRef<string | null>(noteId ?? null);
  const previousThreadIdRef = useRef<string | null>(threadId ?? null);
  const currentSaveOwnerKeyRef = useRef(currentSaveOwnerKey);
  const currentSaveNoteIdRef = useRef(currentSaveNoteId ?? "external-file");
  const activeSaveRef = useRef<{
    requestId: string;
    text: string;
    revision: number;
    timeoutHandle: number;
    ownerKey: string;
    noteId: string;
    retryCount: number;
  } | null>(null);
  const saveDebounceTimeoutRef = useRef<number | null>(null);
  const saveRetryTimeoutRef = useRef<number | null>(null);
  const requestSaveRef = useRef<(options?: { force?: boolean; retryCount?: number }) => void>(
    () => {}
  );
  const queueAutosaveRef = useRef<() => void>(() => {});
  const pendingNavigationRef = useRef<{
    action: () => void;
    reason: string;
    timeoutHandle: number | null;
  } | null>(null);
  const [leavePrompt, setLeavePrompt] = useState<{
    reason: string;
    message: string;
  } | null>(null);
  // Last ack result (ok/error) per note — drives the "Saved" indicator
  // and the error banner.
  const [saveStatus, setSaveStatus] = useState<
    | { kind: "idle" }
    | { kind: "saving" }
    | { kind: "saved"; at: number }
    | { kind: "error"; message: string; at: number }
  >({ kind: "idle" });
  const saveStatusRef = useRef(saveStatus);
  saveStatusRef.current = saveStatus;
  // Timestamp of the most recent moment the draft contained non-empty
  // text. Used to distinguish a genuine clear from a paste-replace
  // micro-blink that transiently empties the document.
  const lastNonEmptyDraftAtRef = useRef<number>(Date.now());
  const showImageNotice = useCallback((message: string) => {
    setImageNotice(message);
  }, []);
  const showScreenshotNotice = useCallback((message: string) => {
    setScreenshotNotice(message);
  }, []);

  latestDraftTextRef.current = draftText;
  hasLocalDirtyChangesRef.current = hasLocalDirtyChanges;
  currentSaveOwnerKeyRef.current = currentSaveOwnerKey;
  currentSaveNoteIdRef.current = currentSaveNoteId ?? "external-file";
  if (draftText.trim().length > 0) {
    lastNonEmptyDraftAtRef.current = Date.now();
  }

  useEffect(() => {
    latestImageUploadContextRef.current = {
      threadId,
      ownerKind,
      ownerId,
      noteId,
    };
  }, [noteId, ownerId, ownerKind, threadId]);

  useEffect(() => {
    const handleThreadNoteImageResult = (event: Event) => {
      const detail = (event as CustomEvent<ThreadNoteImageUploadResult>).detail;
      if (!detail?.requestId) {
        return;
      }

      const pending = pendingImageUploadsRef.current.get(detail.requestId);
      if (!pending) {
        return;
      }

      pendingImageUploadsRef.current.delete(detail.requestId);
      pending.resolve(detail);
    };

    window.addEventListener(
      THREAD_NOTE_IMAGE_RESULT_EVENT,
      handleThreadNoteImageResult as EventListener
    );
    return () => {
      window.removeEventListener(
        THREAD_NOTE_IMAGE_RESULT_EVENT,
        handleThreadNoteImageResult as EventListener
      );
      pendingImageUploadsRef.current.clear();
    };
  }, []);

  useEffect(() => {
    const handleThreadNoteScreenshotCaptureResult = (event: Event) => {
      const detail = (event as CustomEvent<ThreadNoteScreenshotCaptureResult>).detail;
      if (!detail?.requestId) {
        return;
      }

      const pending = pendingScreenshotCapturesRef.current.get(detail.requestId);
      if (!pending) {
        return;
      }

      pendingScreenshotCapturesRef.current.delete(detail.requestId);
      pending.resolve(detail);
    };

    const handleThreadNoteScreenshotProcessingResult = (event: Event) => {
      const detail = (event as CustomEvent<ThreadNoteScreenshotProcessingResult>).detail;
      if (!detail?.requestId) {
        return;
      }

      const pending = pendingScreenshotProcessingRef.current.get(detail.requestId);
      if (!pending) {
        return;
      }

      pendingScreenshotProcessingRef.current.delete(detail.requestId);
      pending.resolve(detail);
    };

    window.addEventListener(
      THREAD_NOTE_SCREENSHOT_CAPTURE_RESULT_EVENT,
      handleThreadNoteScreenshotCaptureResult as EventListener
    );
    window.addEventListener(
      THREAD_NOTE_SCREENSHOT_PROCESSING_RESULT_EVENT,
      handleThreadNoteScreenshotProcessingResult as EventListener
    );

    return () => {
      window.removeEventListener(
        THREAD_NOTE_SCREENSHOT_CAPTURE_RESULT_EVENT,
        handleThreadNoteScreenshotCaptureResult as EventListener
      );
      window.removeEventListener(
        THREAD_NOTE_SCREENSHOT_PROCESSING_RESULT_EVENT,
        handleThreadNoteScreenshotProcessingResult as EventListener
      );
      pendingScreenshotCapturesRef.current.clear();
      pendingScreenshotProcessingRef.current.clear();
    };
  }, []);

  useEffect(() => {
    if (isNotesWorkspace && state?.workspaceProjectId) {
      return;
    }

    setIsBatchOrganizerOpen(false);
    setBatchOrganizerSearch("");
    setBatchOrganizerSelectedSourceKeys([]);
    setBatchOrganizerSourcePreviewKey(null);
    setBatchOrganizerActiveNoteTempId(null);
    setBatchOrganizerEditableNotes([]);
    setBatchOrganizerEditableLinks([]);
    setBatchOrganizerIsApplying(false);
  }, [isNotesWorkspace, state?.workspaceProjectId]);

  useEffect(() => {
    if (!batchNotePlanPreview) {
      return;
    }

    setIsBatchOrganizerOpen(true);
    setBatchOrganizerSelectedSourceKeys(
      batchNotePlanPreview.sourceNotes.map((sourceNote) =>
        batchSourceSelectionKeyForSourceNote(sourceNote)
      )
    );
    setBatchOrganizerSourcePreviewKey((current) =>
      current &&
      batchNotePlanPreview.sourceNotes.some(
        (sourceNote) => batchSourceSelectionKeyForSourceNote(sourceNote) === current
      )
        ? current
        : batchNotePlanPreview.sourceNotes[0]
          ? batchSourceSelectionKeyForSourceNote(batchNotePlanPreview.sourceNotes[0])
          : null
    );
    setBatchOrganizerEditableNotes(batchNotePlanPreview.proposedNotes);
    setBatchOrganizerEditableLinks(batchNotePlanPreview.proposedLinks);
    setBatchOrganizerActiveNoteTempId((current) =>
      current &&
      batchNotePlanPreview.proposedNotes.some((note) => note.tempId === current)
        ? current
        : batchNotePlanPreview.proposedNotes[0]?.tempId ?? null
    );
  }, [batchNotePlanPreview]);

  useEffect(() => {
    if (batchNotePlanPreview) {
      return;
    }

    if (
      batchOrganizerSourcePreviewKey &&
      batchOrganizerSelectedSourceKeys.includes(batchOrganizerSourcePreviewKey)
    ) {
      return;
    }

    setBatchOrganizerSourcePreviewKey(batchOrganizerSelectedSourceKeys[0] ?? null);
  }, [
    batchNotePlanPreview,
    batchOrganizerSelectedSourceKeys,
    batchOrganizerSourcePreviewKey,
  ]);

  useEffect(() => {
    if (!batchOrganizerIsApplying) {
      return;
    }

    if (batchNotePlanPreview) {
      setBatchOrganizerIsApplying(false);
      return;
    }

    if (!isBatchNotePlanBusy) {
      setBatchOrganizerIsApplying(false);
      setIsBatchOrganizerOpen(false);
      setBatchOrganizerActiveNoteTempId(null);
      setBatchOrganizerEditableNotes([]);
      setBatchOrganizerEditableLinks([]);
    }
  }, [batchNotePlanPreview, batchOrganizerIsApplying, isBatchNotePlanBusy]);

  const requestThreadNoteImageAsset = useCallback(
    async (file: File): Promise<ThreadNoteImageUploadResult> => {
      const {
        threadId: activeThreadId,
        ownerKind: activeOwnerKind,
        ownerId: activeOwnerId,
        noteId: activeNoteId,
      } = latestImageUploadContextRef.current;

      if (!activeOwnerKind || !activeOwnerId || !activeNoteId) {
        return {
          requestId: "",
          ok: false,
          message: "Open a note before adding an image.",
        };
      }

      const dataUrl = await readFileAsDataURL(file);
      if (!dataUrl) {
        return {
          requestId: "",
          ok: false,
          message: "I could not read that image file.",
        };
      }

      const resolvedMimeType = resolveThreadNoteImageMimeType(file, dataUrl);
      if (!isSupportedThreadNoteImageMimeType(resolvedMimeType)) {
        return {
          requestId: "",
          ok: false,
          message: "This image type is not supported yet. Use PNG, JPG, GIF, WebP, or TIFF.",
        };
      }

      const requestId = createThreadNoteImageRequestID();
      const threadNoteCommandHandler = window.webkit?.messageHandlers?.threadNoteCommand;

      if (!threadNoteCommandHandler || typeof threadNoteCommandHandler.postMessage !== "function") {
        return {
          requestId,
          ok: false,
          message:
            "Image paste in notes needs the desktop OpenAssist app bridge. The browser preview cannot save note images.",
        };
      }

      return await new Promise<ThreadNoteImageUploadResult>((resolve) => {
        const timeoutID = window.setTimeout(() => {
          pendingImageUploadsRef.current.delete(requestId);
          resolve({
            requestId,
            ok: false,
            message:
              "Saving the image took too long. Please try again.",
          });
        }, THREAD_NOTE_IMAGE_UPLOAD_TIMEOUT_MS);

        pendingImageUploadsRef.current.set(requestId, {
          resolve: (result) => {
            window.clearTimeout(timeoutID);
            resolve(result);
          },
        });

        try {
          threadNoteCommandHandler.postMessage({
            type: "saveImageAsset",
            ...(activeThreadId ? { threadId: activeThreadId } : {}),
            ownerKind: activeOwnerKind,
            ownerId: activeOwnerId,
            noteId: activeNoteId,
            requestId,
            filename: file.name || undefined,
            mimeType: resolvedMimeType || undefined,
            dataUrl,
          });
        } catch (error) {
          pendingImageUploadsRef.current.delete(requestId);
          window.clearTimeout(timeoutID);
          console.error("[thread-note image] saveImageAsset postMessage threw", error);
          resolve({
            requestId,
            ok: false,
            message:
              error instanceof Error
                ? `Open Assist could not send the image: ${error.message}`
                : "Open Assist could not send the image to the desktop app.",
          });
        }
      });
    },
    []
  );

  const requestThreadNoteClipboardImageAsset = useCallback(
    async (): Promise<ThreadNoteImageUploadResult> => {
      const {
        threadId: activeThreadId,
        ownerKind: activeOwnerKind,
        ownerId: activeOwnerId,
        noteId: activeNoteId,
      } = latestImageUploadContextRef.current;

      if (!activeOwnerKind || !activeOwnerId || !activeNoteId) {
        return {
          requestId: "",
          ok: false,
          message: "Open a note before adding an image.",
        };
      }

      const requestId = createThreadNoteImageRequestID();
      const threadNoteCommandHandler = window.webkit?.messageHandlers?.threadNoteCommand;

      if (!threadNoteCommandHandler || typeof threadNoteCommandHandler.postMessage !== "function") {
        return {
          requestId,
          ok: false,
          message:
            "Image paste in notes needs the desktop OpenAssist app bridge. The browser preview cannot save note images.",
        };
      }

      return await new Promise<ThreadNoteImageUploadResult>((resolve) => {
        const timeoutID = window.setTimeout(() => {
          pendingImageUploadsRef.current.delete(requestId);
          resolve({
            requestId,
            ok: false,
            message: "Reading the pasted image took too long. Please try again.",
          });
        }, THREAD_NOTE_IMAGE_UPLOAD_TIMEOUT_MS);

        pendingImageUploadsRef.current.set(requestId, {
          resolve: (result) => {
            window.clearTimeout(timeoutID);
            resolve(result);
          },
        });

        try {
          threadNoteCommandHandler.postMessage({
            type: "pasteImageFromClipboard",
            ...(activeThreadId ? { threadId: activeThreadId } : {}),
            ownerKind: activeOwnerKind,
            ownerId: activeOwnerId,
            noteId: activeNoteId,
            requestId,
          });
        } catch (error) {
          pendingImageUploadsRef.current.delete(requestId);
          window.clearTimeout(timeoutID);
          console.error("[thread-note image] pasteImageFromClipboard postMessage threw", error);
          resolve({
            requestId,
            ok: false,
            message:
              error instanceof Error
                ? `Open Assist could not read the clipboard image: ${error.message}`
                : "Open Assist could not read the image from the clipboard.",
          });
        }
      });
    },
    []
  );

  const requestThreadNoteScreenshotCapture = useCallback(
    async (
      captureMode: ThreadNoteScreenshotCaptureMode
    ): Promise<ThreadNoteScreenshotCaptureResult> => {
      const {
        threadId: activeThreadId,
        ownerKind: activeOwnerKind,
        ownerId: activeOwnerId,
        noteId: activeNoteId,
      } = latestImageUploadContextRef.current;

      if (!activeOwnerKind || !activeOwnerId || !activeNoteId) {
        return {
          requestId: "",
          ok: false,
          message: "Open a note before adding a screenshot.",
        };
      }

      const requestId = createThreadNoteScreenshotRequestID();
      const threadNoteCommandHandler = window.webkit?.messageHandlers?.threadNoteCommand;

      if (!threadNoteCommandHandler || typeof threadNoteCommandHandler.postMessage !== "function") {
        return {
          requestId,
          ok: false,
          message:
            "Screenshot import needs the desktop OpenAssist app bridge. The browser preview cannot capture screenshots.",
        };
      }

      return await new Promise<ThreadNoteScreenshotCaptureResult>((resolve) => {
        const timeoutID = window.setTimeout(() => {
          pendingScreenshotCapturesRef.current.delete(requestId);
          resolve({
            requestId,
            ok: false,
            message: "Screenshot capture took too long. Please try again.",
          });
        }, THREAD_NOTE_SCREENSHOT_CAPTURE_TIMEOUT_MS);

        pendingScreenshotCapturesRef.current.set(requestId, {
          resolve: (result) => {
            window.clearTimeout(timeoutID);
            resolve(result);
          },
        });

        try {
          threadNoteCommandHandler.postMessage({
            type: "captureScreenshotImport",
            ...(activeThreadId ? { threadId: activeThreadId } : {}),
            ownerKind: activeOwnerKind,
            ownerId: activeOwnerId,
            noteId: activeNoteId,
            requestId,
            captureMode,
          });
        } catch (error) {
          pendingScreenshotCapturesRef.current.delete(requestId);
          window.clearTimeout(timeoutID);
          resolve({
            requestId,
            ok: false,
            message:
              error instanceof Error
                ? `Open Assist could not start screenshot capture: ${error.message}`
                : "Open Assist could not start screenshot capture.",
          });
        }
      });
    },
    []
  );

  const requestThreadNoteScreenshotProcessingPreview = useCallback(
    async (options: {
      capture: ThreadNoteScreenshotCaptureResult;
      outputMode: ThreadNoteScreenshotImportMode;
      customInstruction?: string;
    }): Promise<ThreadNoteScreenshotProcessingResult> => {
      const {
        threadId: activeThreadId,
        ownerKind: activeOwnerKind,
        ownerId: activeOwnerId,
        noteId: activeNoteId,
      } = latestImageUploadContextRef.current;

      if (!activeOwnerKind || !activeOwnerId || !activeNoteId) {
        return {
          requestId: "",
          ok: false,
          message: "Open a note before adding a screenshot.",
        };
      }

      if (!options.capture.dataUrl) {
        return {
          requestId: "",
          ok: false,
          message: "Open Assist could not find the captured screenshot data.",
        };
      }

      const requestId = createThreadNoteScreenshotRequestID();
      const threadNoteCommandHandler = window.webkit?.messageHandlers?.threadNoteCommand;

      if (!threadNoteCommandHandler || typeof threadNoteCommandHandler.postMessage !== "function") {
        return {
          requestId,
          ok: false,
          message:
            "Screenshot import needs the desktop OpenAssist app bridge. The browser preview cannot process screenshots.",
        };
      }

      return await new Promise<ThreadNoteScreenshotProcessingResult>((resolve) => {
        const timeoutMs = threadNoteScreenshotProcessingTimeoutMs(
          options.capture,
          options.outputMode
        );
        const timeoutID = window.setTimeout(() => {
          pendingScreenshotProcessingRef.current.delete(requestId);
          resolve({
            requestId,
            ok: false,
            message:
              "Screenshot processing took too long. Try again, or use fewer screenshots if this batch is very large.",
          });
        }, timeoutMs);

        pendingScreenshotProcessingRef.current.set(requestId, {
          resolve: (result) => {
            window.clearTimeout(timeoutID);
            resolve(result);
          },
        });

        try {
          threadNoteCommandHandler.postMessage({
            type: "processScreenshotImport",
            ...(activeThreadId ? { threadId: activeThreadId } : {}),
            ownerKind: activeOwnerKind,
            ownerId: activeOwnerId,
            noteId: activeNoteId,
            requestId,
            outputMode: options.outputMode,
            filename: options.capture.filename,
            mimeType: options.capture.mimeType,
            dataUrl: options.capture.dataUrl,
            captureMode: options.capture.captureMode,
            captureSegmentCount: options.capture.segmentCount,
            styleInstruction: options.customInstruction?.trim() || undefined,
          });
        } catch (error) {
          pendingScreenshotProcessingRef.current.delete(requestId);
          window.clearTimeout(timeoutID);
          resolve({
            requestId,
            ok: false,
            message:
              error instanceof Error
                ? `Open Assist could not process the screenshot: ${error.message}`
                : "Open Assist could not process the screenshot.",
          });
        }
      });
    },
    []
  );

  const requestThreadNoteImageUploads = useCallback(
    async (files: readonly File[]) => {
      const imageFiles = files.filter((file) => file.size > 0 || file.type.length > 0);
      if (!imageFiles.length) {
        return [];
      }

      setIsUploadingImage(true);
      try {
        const uploaded: ThreadNoteImageUploadResult[] = [];
        for (const file of imageFiles) {
          const result = await requestThreadNoteImageAsset(file);
          uploaded.push(result);
        }
        return uploaded;
      } finally {
        setIsUploadingImage(false);
      }
    },
    [requestThreadNoteImageAsset]
  );

  const dispatchDraftUpdate = useCallback(
    (nextText: string, revision = draftRevisionRef.current) => {
      const normalized = normalizeLineEndings(nextText);
      if (isExternalMarkdownFile) {
        lastSentToSwiftRef.current = normalized;
        onDispatchCommand("updateDraft", {
          draftRevision: revision,
          text: normalized,
        });
        return;
      }
      if (!ownerKind || !ownerId || !noteId) {
        return;
      }
      // Remember what we most recently told Swift about. The external
      // state echo check in the note-sync effect relies on this ref to
      // decide whether an incoming state is "what we asked for" (safe to
      // apply) or "a stale echo" (unsafe — would clobber in-flight keys).
      lastSentToSwiftRef.current = normalized;
      // Telemetry (Step 7).
      console.info("[thread-note save] updateDraft", {
        noteId,
        ownerKind,
        ownerId,
        byteCount: normalized.length,
        revision,
      });
      onDispatchCommand("updateDraft", {
        ...(threadId ? { threadId } : {}),
        ownerKind,
        ownerId,
        noteId,
        draftRevision: revision,
        text: normalized,
      });
    },
    [isExternalMarkdownFile, noteId, onDispatchCommand, ownerId, ownerKind, threadId]
  );

  const updateDraftTextLocally = useCallback(
    (nextText: string) => {
      const normalized = normalizeLineEndings(nextText);
      const nextRevision = draftRevisionRef.current + 1;
      draftRevisionRef.current = nextRevision;
      setDraftText(normalized);
      setHasLocalDirtyChanges(true);
      hasLocalDirtyChangesRef.current = true;
      dispatchDraftUpdate(normalized, nextRevision);
      queueAutosaveRef.current();
      return normalized;
    },
    [dispatchDraftUpdate]
  );

  const readCurrentThreadNoteMarkdown = useCallback(() => {
    const liveEditor = liveEditorRef.current;
    if (isRichEditorMode && liveEditor && resolveEditorView(liveEditor)) {
      try {
        return normalizeLineEndings(
          normalizeThreadNoteStoredMarkdown(liveEditor.getMarkdown())
        );
      } catch (error) {
        console.error("Failed to read live rich note markdown", error);
      }
    }
    return normalizeLineEndings(
      normalizeThreadNoteStoredMarkdown(latestDraftTextRef.current)
    );
  }, [isRichEditorMode]);

  useEffect(() => {
    const flushThreadNoteDraft = () => {
      const text = readCurrentThreadNoteMarkdown();
      let revision = draftRevisionRef.current;
      let isDirty = hasLocalDirtyChangesRef.current;

      if (text !== latestDraftTextRef.current) {
        revision += 1;
        draftRevisionRef.current = revision;
        setDraftText(text);
        latestDraftTextRef.current = text;
        setHasLocalDirtyChanges(true);
        hasLocalDirtyChangesRef.current = true;
        isDirty = true;
      }

      dispatchDraftUpdate(text, revision);

      return {
        ok: true,
        sourceKind: sourceDescriptor?.sourceKind ?? "managedNote",
        ownerKind: isExternalMarkdownFile ? null : ownerKind,
        ownerId: isExternalMarkdownFile ? null : ownerId,
        noteId: isExternalMarkdownFile ? null : noteId,
        text,
        draftRevision: revision,
        isDirty,
      };
    };

    let installedBridge: Window["chatBridge"] | null = null;
    let rafID: number | null = null;
    let isDisposed = false;

    const installFlushBridge = () => {
      if (isDisposed) {
        return;
      }

      const bridge = window.chatBridge;
      if (!bridge) {
        rafID = window.requestAnimationFrame(installFlushBridge);
        return;
      }

      installedBridge = bridge;
      bridge.flushThreadNoteDraft = flushThreadNoteDraft;
    };

    installFlushBridge();

    return () => {
      isDisposed = true;
      if (rafID !== null) {
        window.cancelAnimationFrame(rafID);
      }
      if (installedBridge?.flushThreadNoteDraft === flushThreadNoteDraft) {
        delete installedBridge.flushThreadNoteDraft;
      }
    };
  }, [
    dispatchDraftUpdate,
    isExternalMarkdownFile,
    noteId,
    ownerId,
    ownerKind,
    readCurrentThreadNoteMarkdown,
    sourceDescriptor?.sourceKind,
  ]);

  const editor = useEditor(
    {
      immediatelyRender: false,
      autofocus: false,
      content: normalizeThreadNoteMarkdownForRichText(
        normalizeLineEndings(state?.text ?? "")
      ),
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
        ThreadNoteImage,
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
          spellcheck: "true",
        },
        handlePaste: (_view, event) => {
          const clipboardData = event.clipboardData;
          const liveEditor = liveEditorRef.current;
          console.info("[thread-note image] handlePaste", {
            hasClipboardData: Boolean(clipboardData),
            hasLiveEditor: Boolean(liveEditor),
            types: clipboardData ? Array.from(clipboardData.types) : [],
            itemKinds: clipboardData
              ? Array.from(clipboardData.items).map((i) => `${i.kind}:${i.type}`)
              : [],
            fileCount: clipboardData?.files?.length ?? 0,
          });
          if (!clipboardData) {
            return false;
          }

          const imageFiles = extractThreadNoteImageFiles(clipboardData.items, clipboardData.files);
          console.info("[thread-note image] extracted imageFiles count", imageFiles.length);
          if (!imageFiles.length) {
            const shouldRouteToNative = shouldAttemptNativeThreadNoteClipboardImagePaste(clipboardData);
            console.info("[thread-note image] native clipboard route?", shouldRouteToNative);
            if (!shouldRouteToNative) {
              return false;
            }

            event.preventDefault();
            const selection = liveEditor?.state.selection ?? null;
            void requestThreadNoteClipboardImageAsset().then((result) => {
              console.info("[thread-note image] native clipboard result", result);
              const currentEditor = liveEditorRef.current;
              if (!currentEditor) {
                showImageNotice("Rich editor not available; clipboard paste aborted.");
                return;
              }

              if (!result.ok || !result.url) {
                showImageNotice(
                  result.message ??
                    "Open Assist could not find an image on the clipboard."
                );
                return;
              }

              insertThreadNoteImages(currentEditor, {
                from: selection?.from,
                to: selection?.to,
                images: [
                  {
                    src: result.url,
                    alt: preferredThreadNoteImageAlt(),
                    title: "",
                  },
                ],
              });
              const nextMarkdown = normalizeLineEndings(currentEditor.getMarkdown());
              updateDraftTextLocally(nextMarkdown);
            });
            return true;
          }

          event.preventDefault();
          const selection = liveEditor?.state.selection ?? null;
          console.info("[thread-note image] paste: routing imageFiles to upload", {
            count: imageFiles.length,
            selection: selection ? { from: selection.from, to: selection.to } : null,
          });
          void requestThreadNoteImageUploads(imageFiles).then((results) => {
            console.info("[thread-note image] paste upload results", results);
            const currentEditor = liveEditorRef.current;
            if (!currentEditor) {
              showImageNotice("Rich editor unavailable; paste aborted.");
              console.error("[thread-note image] paste: editor null at result time");
              return;
            }

            const successfulImages = results
              .filter((result) => result.ok && result.url)
              .map((result, index) => ({
                src: result.url!,
                alt: preferredThreadNoteImageAlt(imageFiles[index]?.name),
                title: "",
              }));

            const failedResult = results.find((result) => !result.ok);
            if (failedResult) {
              showImageNotice(
                failedResult.message ??
                  "Image save returned failure with no message."
              );
              console.error("[thread-note image] paste failure", failedResult);
            }
            if (!successfulImages.length) {
              return;
            }

            console.info("[thread-note image] paste: inserting into editor", successfulImages);
            insertThreadNoteImages(currentEditor, {
              from: selection?.from,
              to: selection?.to,
              images: successfulImages,
            });
            const nextMarkdown = normalizeLineEndings(currentEditor.getMarkdown());
            updateDraftTextLocally(nextMarkdown);
          });
          return true;
        },
        handleDrop: (view, event, slice, moved) => {
          const imageFiles = extractThreadNoteImageFiles(
            event.dataTransfer?.items,
            event.dataTransfer?.files
          );
          if (imageFiles.length) {
            event.preventDefault();
            const dropPosition = view.posAtCoords({
              left: event.clientX,
              top: event.clientY,
            })?.pos;

            void requestThreadNoteImageUploads(imageFiles).then((results) => {
              const successfulImages = results
                .filter((result) => result.ok && result.url)
                .map((result, index) => ({
                  src: result.url!,
                  alt: preferredThreadNoteImageAlt(imageFiles[index]?.name),
                  title: "",
                }));
              const failedResult = results.find((result) => !result.ok);
              if (failedResult?.message) {
                showImageNotice(failedResult.message);
              }
              if (!successfulImages.length) {
                return;
              }

              const currentEditor = liveEditorRef.current;
              if (!currentEditor) {
                return;
              }

              insertThreadNoteImages(currentEditor, {
                from: dropPosition,
                to: dropPosition,
                images: successfulImages,
              });
              const nextMarkdown = normalizeLineEndings(currentEditor.getMarkdown());
              updateDraftTextLocally(nextMarkdown);
            });
            return true;
          }

          return handleThreadNoteSectionDrop(view, event, slice, moved);
        },
      },
    },
    [
      placeholderText,
      requestThreadNoteClipboardImageAsset,
      requestThreadNoteImageUploads,
      showImageNotice,
      updateDraftTextLocally,
    ]
  );

  liveEditorRef.current = editor ?? null;

  useEffect(() => {
    const handleOpenInspector = () => {
      setIsImageInspectorOpen(true);
    };
    window.addEventListener(
      "openassist:thread-note-image-inspector-open",
      handleOpenInspector as EventListener
    );
    return () => {
      window.removeEventListener(
        "openassist:thread-note-image-inspector-open",
        handleOpenInspector as EventListener
      );
    };
  }, []);

  useEffect(() => {
    if (!selectedImage) {
      setIsImageInspectorOpen(false);
    }
  }, [selectedImage]);

  const refreshSlashQuery = useCallback(
    (activeEditor: Editor | null = editor) => {
      if (!isRichEditorMode) {
        setSlashQuery(null);
        setMermaidEditingContext(null);
        setHeadingTagEditor(null);
        setIsInTable(false);
        setSelectedImage(null);
        return;
      }

      if (!activeEditor || !isOpen || !noteId) {
        setSlashQuery(null);
        setMermaidEditingContext(null);
        setNoteSelection(null);
        setSelectedImage(null);
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
      setSelectedImage(resolveSelectedThreadNoteImage(activeEditor));

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
    [editor, isOpen, isRichEditorMode, layerRef, noteId]
  );

  const fallbackToRawMarkdownEditor = useCallback((message: string) => {
    isRichEditorReadyForInputRef.current = false;
    setForcedNoteEditorSurfaceMode("markdown");
    setEditorLoadNotice(message);
    setSlashQuery(null);
    setMermaidEditingContext(null);
    setHeadingTagEditor(null);
    setIsInTable(false);
    setSelectedImage(null);
    setNoteSelection(null);
  }, []);

  const syncRichEditorMarkdown = useCallback(
    (
      activeEditor: Editor,
      markdown: string,
      options?: {
        fallbackMessage?: string;
        refreshSelectionState?: boolean;
      }
    ): boolean => {
      try {
        isApplyingExternalContentRef.current = true;
        activeEditor.commands.setContent(normalizeThreadNoteMarkdownForRichText(markdown), {
          contentType: "markdown",
        });
        isApplyingExternalContentRef.current = false;
        isRichEditorReadyForInputRef.current = true;
        setForcedNoteEditorSurfaceMode(null);
        setEditorLoadNotice(null);

        if (options?.refreshSelectionState !== false) {
          try {
            refreshSlashQuery(activeEditor);
          } catch (selectionRefreshError) {
            console.error(
              "Failed to refresh thread note rich editor selection state",
              selectionRefreshError
            );
          }
        }

        return true;
      } catch (error) {
        isApplyingExternalContentRef.current = false;
        console.error("Failed to load thread note into rich editor", error);
        fallbackToRawMarkdownEditor(
          options?.fallbackMessage ??
            "This note opened in Markdown because rich view could not load it safely."
        );
        return false;
      }
    },
    [fallbackToRawMarkdownEditor, refreshSlashQuery]
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

  const handleOpenImagePicker = useCallback(
    (range?: PendingImagePickerInsert) => {
      if (!noteId || !ownerKind || !ownerId) {
        showImageNotice("Open a note before adding an image.");
        return;
      }

      pendingImagePickerInsertRef.current =
        range ??
        (isRichEditorMode && editor
          ? {
              from: editor.state.selection.from,
              to: editor.state.selection.to,
            }
          : resolveCurrentRawMarkdownRange());
      imageInputRef.current?.click();
    },
    [
      editor,
      isRichEditorMode,
      noteId,
      ownerId,
      ownerKind,
      showImageNotice,
    ]
  );

  const slashCommands = useMemo(
    () => [
      ...buildMermaidSlashCommands(openMermaidTemplatePicker),
      ...buildImageSlashCommands(handleOpenImagePicker),
      ...BASE_SLASH_COMMANDS,
    ],
    [handleOpenImagePicker, openMermaidTemplatePicker]
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

  const clearSaveDebounce = useCallback(() => {
    if (saveDebounceTimeoutRef.current !== null) {
      window.clearTimeout(saveDebounceTimeoutRef.current);
      saveDebounceTimeoutRef.current = null;
    }
  }, []);

  const clearActiveSave = useCallback(() => {
    const active = activeSaveRef.current;
    if (active) {
      window.clearTimeout(active.timeoutHandle);
      activeSaveRef.current = null;
    }
  }, []);

  const clearSaveRetry = useCallback(() => {
    if (saveRetryTimeoutRef.current !== null) {
      window.clearTimeout(saveRetryTimeoutRef.current);
      saveRetryTimeoutRef.current = null;
    }
  }, []);

  const clearPendingNavigation = useCallback(() => {
    const pending = pendingNavigationRef.current;
    if (pending?.timeoutHandle !== null && pending?.timeoutHandle !== undefined) {
      window.clearTimeout(pending.timeoutHandle);
    }
    pendingNavigationRef.current = null;
  }, []);

  const finishPendingNavigation = useCallback(() => {
    const pending = pendingNavigationRef.current;
    if (!pending) {
      return;
    }
    clearPendingNavigation();
    setLeavePrompt(null);
    pending.action();
  }, [clearPendingNavigation]);

  const showSaveWarning = useCallback((message?: string) => {
    const pending = pendingNavigationRef.current;
    if (!pending) {
      return;
    }
    if (pending.timeoutHandle !== null) {
      window.clearTimeout(pending.timeoutHandle);
      pendingNavigationRef.current = { ...pending, timeoutHandle: null };
    }
    setLeavePrompt({
      reason: pending.reason,
      message:
        message ??
        "Open Assist has not finished saving your latest note changes yet.",
      });
  }, []);

  const scheduleSaveRetry = useCallback(
    (retryCount: number) => {
      if (retryCount >= THREAD_NOTE_SAVE_RETRY_DELAYS_MS.length) {
        return false;
      }
      clearSaveRetry();
      const delay = THREAD_NOTE_SAVE_RETRY_DELAYS_MS[retryCount];
      const ownerKeyAtSchedule = currentSaveOwnerKeyRef.current;
      const noteIdAtSchedule = currentSaveNoteIdRef.current;
      saveRetryTimeoutRef.current = window.setTimeout(() => {
        saveRetryTimeoutRef.current = null;
        if (
          ownerKeyAtSchedule !== currentSaveOwnerKeyRef.current ||
          noteIdAtSchedule !== currentSaveNoteIdRef.current
        ) {
          return;
        }
        requestSaveRef.current({ force: true, retryCount: retryCount + 1 });
      }, delay);
      return true;
    },
    [clearSaveRetry]
  );

  const startSave = useCallback(
    (text: string, revision: number, retryCount = 0) => {
      clearSaveDebounce();
      clearSaveRetry();
      if (activeSaveRef.current) {
        return;
      }
      if (isExternalMarkdownFile && !(sourceDescriptor?.canSave ?? false)) {
        setSaveStatus({
          kind: "error",
          message: "This Markdown file is read-only right now.",
          at: Date.now(),
        });
        showSaveWarning("This Markdown file is read-only right now.");
        return;
      }
      if (!isExternalMarkdownFile && (!ownerKind || !ownerId || !noteId)) {
        setSaveStatus({
          kind: "error",
          message: "Open Assist could not find the note to save.",
          at: Date.now(),
        });
        showSaveWarning("Open Assist could not find the note to save.");
        return;
      }

      const requestId = createSaveRequestID();
      const timeoutHandle = window.setTimeout(() => {
        const active = activeSaveRef.current;
        if (!active || active.requestId !== requestId) {
          return;
        }
        activeSaveRef.current = null;
        setSaveStatus({
          kind: "error",
          message: "Open Assist is still waiting for the save to finish.",
          at: Date.now(),
        });
        if (!scheduleSaveRetry(retryCount)) {
          showSaveWarning("Open Assist could not confirm that this note was saved.");
        }
      }, THREAD_NOTE_SAVE_ACK_TIMEOUT_MS);

      activeSaveRef.current = {
        requestId,
        text,
        revision,
        timeoutHandle,
        ownerKey: currentSaveOwnerKey,
        noteId: currentSaveNoteId ?? "external-file",
        retryCount,
      };
      lastSentToSwiftRef.current = text;
      setSaveStatus({ kind: "saving" });

      onDispatchCommand("save", {
        ...(threadId && !isExternalMarkdownFile ? { threadId } : {}),
        ...(isExternalMarkdownFile
          ? {}
          : { ownerKind: ownerKind!, ownerId: ownerId!, noteId: noteId! }),
        requestId,
        draftRevision: revision,
        text,
      });
    },
    [
      clearSaveRetry,
      clearSaveDebounce,
      currentSaveNoteId,
      currentSaveOwnerKey,
      isExternalMarkdownFile,
      noteId,
      onDispatchCommand,
      ownerId,
      ownerKind,
      scheduleSaveRetry,
      showSaveWarning,
      sourceDescriptor?.canSave,
      threadId,
    ]
  );

  const requestSave = useCallback(
    (options?: { force?: boolean; retryCount?: number }) => {
      const text = readCurrentThreadNoteMarkdown();
      let revision = draftRevisionRef.current;
      if (text !== latestDraftTextRef.current) {
        revision += 1;
        draftRevisionRef.current = revision;
        setDraftText(text);
        latestDraftTextRef.current = text;
        setHasLocalDirtyChanges(true);
        hasLocalDirtyChangesRef.current = true;
        dispatchDraftUpdate(text, revision);
      }
      const force = options?.force === true;

      if (isExternalMarkdownFile && !force) {
        return;
      }
      if (!force && !hasLocalDirtyChangesRef.current) {
        return;
      }
      if (!force && revision <= lastSavedDraftRevisionRef.current) {
        return;
      }
      if (activeSaveRef.current) {
        return;
      }
      startSave(text, revision, options?.retryCount ?? 0);
    },
    [dispatchDraftUpdate, isExternalMarkdownFile, readCurrentThreadNoteMarkdown, startSave]
  );
  requestSaveRef.current = requestSave;

  const commitSave = useCallback(
    (nextText?: string, options?: { force?: boolean }) => {
      const normalized = normalizeLineEndings(
        nextText ?? readCurrentThreadNoteMarkdown()
      );
      if (normalized !== latestDraftTextRef.current) {
        const nextRevision = draftRevisionRef.current + 1;
        draftRevisionRef.current = nextRevision;
        setDraftText(normalized);
        latestDraftTextRef.current = normalized;
        setHasLocalDirtyChanges(true);
        hasLocalDirtyChangesRef.current = true;
        dispatchDraftUpdate(normalized, nextRevision);
      }
      requestSave({ force: options?.force === true });
    },
    [dispatchDraftUpdate, readCurrentThreadNoteMarkdown, requestSave]
  );

  const queueManagedAutosave = useCallback(() => {
    if (
      isExternalMarkdownFile ||
      !isOpen ||
      !ownerKind ||
      !ownerId ||
      !noteId
    ) {
      return;
    }

    clearSaveDebounce();
    saveDebounceTimeoutRef.current = window.setTimeout(() => {
      saveDebounceTimeoutRef.current = null;
      commitSave();
    }, THREAD_NOTE_SAVE_DEBOUNCE_MS);
  }, [
    clearSaveDebounce,
    commitSave,
    isExternalMarkdownFile,
    isOpen,
    noteId,
    ownerId,
    ownerKind,
  ]);
  queueAutosaveRef.current = queueManagedAutosave;

  const runAfterSave = useCallback(
    (action: () => void, reason: string) => {
      const hasExternalUnsavedChanges =
        isExternalMarkdownFile &&
        (hasLocalDirtyChangesRef.current || sourceDescriptor?.isDirty === true);
      const hasManagedUnfinishedWork =
        !isExternalMarkdownFile &&
        (hasLocalDirtyChangesRef.current || activeSaveRef.current !== null);

      if (!hasExternalUnsavedChanges && !hasManagedUnfinishedWork) {
        action();
        return;
      }

      clearPendingNavigation();
      const timeoutHandle = window.setTimeout(() => {
        showSaveWarning();
      }, THREAD_NOTE_NAVIGATION_SAVE_TIMEOUT_MS);
      pendingNavigationRef.current = {
        action,
        reason,
        timeoutHandle,
      };

      if (isExternalMarkdownFile) {
        showSaveWarning("This file has unsaved changes.");
        return;
      }

      requestSave({ force: true });
    },
    [
      clearPendingNavigation,
      isExternalMarkdownFile,
      requestSave,
      showSaveWarning,
      sourceDescriptor?.isDirty,
    ]
  );

  const handleSaveWarningRetry = useCallback(() => {
    setLeavePrompt(null);
    if (isExternalMarkdownFile) {
      commitSave(undefined, { force: true });
      return;
    }
    requestSave({ force: true });
  }, [commitSave, isExternalMarkdownFile, requestSave]);

  const handleSaveWarningLeave = useCallback(() => {
    const pending = pendingNavigationRef.current;
    if (!pending) {
      setLeavePrompt(null);
      return;
    }
    clearSaveDebounce();
    clearSaveRetry();
    clearActiveSave();
    clearPendingNavigation();
    setLeavePrompt(null);
    pending.action();
  }, [clearActiveSave, clearPendingNavigation, clearSaveDebounce, clearSaveRetry]);

  const handleSaveWarningStay = useCallback(() => {
    clearPendingNavigation();
    setLeavePrompt(null);
  }, [clearPendingNavigation]);

  const commitEditorMarkdown = useCallback(
    (nextMarkdown: string) => {
      const normalized = updateDraftTextLocally(
        normalizeThreadNoteStoredMarkdown(nextMarkdown)
      );
      commitSave(normalized, { force: true });
    },
    [commitSave, updateDraftTextLocally]
  );

  useEffect(() => {
    const handleSaveAck = (event: Event) => {
      const detail = (event as CustomEvent<{
        requestId: string;
        ownerKind?: string;
        ownerId?: string;
        noteId?: string;
        draftRevision?: number | null;
        status: "ok" | "error";
        errorMessage?: string;
      }>).detail;
      if (!detail?.requestId) {
        return;
      }
      const active = activeSaveRef.current;
      if (!active || active.requestId !== detail.requestId) {
        return;
      }
      clearActiveSave();

      if (detail.status === "ok") {
        const acknowledgedRevision = detail.draftRevision ?? active.revision;
        const latestText = normalizeLineEndings(latestDraftTextRef.current);
        const ackMatchesCurrentSurface =
          active.ownerKey === currentSaveOwnerKey &&
          active.noteId === currentSaveNoteId;

        if (!ackMatchesCurrentSurface) {
          return;
        }

        if (
          acknowledgedRevision === draftRevisionRef.current &&
          active.text === latestText
        ) {
          lastSavedDraftRevisionRef.current = acknowledgedRevision;
          setHasLocalDirtyChanges(false);
          hasLocalDirtyChangesRef.current = false;
          setSaveStatus({ kind: "saved", at: Date.now() });
          finishPendingNavigation();
          return;
        }

        setHasLocalDirtyChanges(true);
        hasLocalDirtyChangesRef.current = true;
        requestSave({ force: true });
        return;
      }

      setSaveStatus({
        kind: "error",
        message:
          detail.errorMessage ??
          "Open Assist couldn't save this note. Retrying…",
        at: Date.now(),
      });
      if (!scheduleSaveRetry(active.retryCount)) {
        showSaveWarning(detail.errorMessage ?? "Open Assist could not save this note.");
      }
    };

    window.addEventListener(
      "openassist:thread-note-save-ack",
      handleSaveAck as EventListener
    );
    return () => {
      window.removeEventListener(
        "openassist:thread-note-save-ack",
        handleSaveAck as EventListener
      );
    };
  }, [
    clearActiveSave,
    currentSaveNoteId,
    currentSaveOwnerKey,
    finishPendingNavigation,
    requestSave,
    scheduleSaveRetry,
    showSaveWarning,
  ]);

  const focusRawMarkdownEditor = useCallback(
    (selection?: { start: number; end: number }) => {
      window.requestAnimationFrame(() => {
        const textarea = rawMarkdownTextareaRef.current;
        if (!textarea) {
          return;
        }

        textarea.focus();
        if (selection) {
          textarea.setSelectionRange(selection.start, selection.end);
        }
      });
    },
    []
  );

  const updateRawMarkdownSelection = useCallback(
    (
      start: number,
      end: number,
      markdown: string = latestDraftTextRef.current
    ) => {
      const safeStart = Math.max(0, Math.min(markdown.length, start));
      const safeEnd = Math.max(safeStart, Math.min(markdown.length, end));
      if (safeEnd <= safeStart) {
        setNoteSelection(null);
        return;
      }

      const selectedMarkdown = markdown.slice(safeStart, safeEnd);
      const selectedText = selectedMarkdown.trim();
      if (!selectedText) {
        setNoteSelection(null);
        return;
      }

      setNoteSelection({
        text: selectedText,
        from: safeStart,
        to: safeEnd,
        selectedMarkdown,
        snapshotMarkdown: markdown,
      });
    },
    []
  );

  const refreshRawMarkdownSlashQuery = useCallback(
    (
      target: HTMLTextAreaElement | null = rawMarkdownTextareaRef.current,
      markdown: string = latestDraftTextRef.current
    ) => {
      const normalizedMarkdown = normalizeLineEndings(markdown);
      const selectionStart = target?.selectionStart ?? normalizedMarkdown.length;
      const selectionEnd = target?.selectionEnd ?? selectionStart;

      updateRawMarkdownSelection(selectionStart, selectionEnd, normalizedMarkdown);
      setSelectedImage(null);
      setIsInTable(false);
      setMermaidEditingContext(null);

      if (!isOpen || !noteId) {
        setSlashQuery(null);
        return;
      }

      const nextQuery = detectRawMarkdownSlashQuery(
        normalizedMarkdown,
        selectionStart,
        selectionEnd
      );
      setSlashQuery(nextQuery);
      if (nextQuery || mermaidPickerStateRef.current) {
        setMenuPosition(DEFAULT_THREAD_NOTE_MENU_POSITION);
      }
    },
    [isOpen, noteId, updateRawMarkdownSelection]
  );

  const resolveCurrentRawMarkdownRange = useCallback((): PendingImagePickerInsert => {
    const textarea = rawMarkdownTextareaRef.current;
    if (!textarea) {
      const fallback = latestDraftTextRef.current.length;
      return { from: fallback, to: fallback };
    }

    return {
      from: textarea.selectionStart ?? 0,
      to: textarea.selectionEnd ?? textarea.selectionStart ?? 0,
    };
  }, []);

  const applyRawMarkdownReplacement = useCallback(
    (
      range: PendingImagePickerInsert,
      replacement: string,
      selectionOffsets?: RawMarkdownSelectionOffsets
    ) => {
      const nextMarkdown = replaceMarkdownRange(latestDraftTextRef.current, range, replacement);
      const defaultOffset = replacement.length;
      const start = Math.max(
        0,
        Math.min(
          nextMarkdown.length,
          range.from + (selectionOffsets?.startOffset ?? defaultOffset)
        )
      );
      const end = Math.max(
        start,
        Math.min(
          nextMarkdown.length,
          range.from + (selectionOffsets?.endOffset ?? selectionOffsets?.startOffset ?? defaultOffset)
        )
      );

      commitEditorMarkdown(nextMarkdown);
      updateRawMarkdownSelection(start, end, nextMarkdown);
      focusRawMarkdownEditor({ start, end });

      return {
        markdown: nextMarkdown,
        start,
        end,
      };
    },
    [commitEditorMarkdown, focusRawMarkdownEditor, updateRawMarkdownSelection]
  );

  const replaceRawMarkdownSelection = useCallback(
    (range: PendingImagePickerInsert, replacement: string) => {
      applyRawMarkdownReplacement(range, replacement);
    },
    [applyRawMarkdownReplacement]
  );

  const insertThreadNoteMarkdownAtRange = useCallback(
    (markdown: string, range?: PendingImagePickerInsert | null) => {
      const normalized = normalizeLineEndings(markdown).trim();
      if (!normalized) {
        showScreenshotNotice("There is nothing to insert into the note yet.");
        return false;
      }

      if (isRichEditorMode) {
        if (!editor) {
          showScreenshotNotice("The rich editor is not ready yet. Try again in a moment.");
          return false;
        }

        const documentSize = editor.state.doc.content.size;
        const from = Math.max(0, Math.min(range?.from ?? editor.state.selection.from, documentSize));
        const to = Math.max(from, Math.min(range?.to ?? editor.state.selection.to, documentSize));
        editor.commands.focus();
        const inserted = editor.commands.insertContentAt(
          {
            from,
            to,
          },
          normalized,
          {
            contentType: "markdown",
          }
        );
        if (!inserted) {
          showScreenshotNotice("Open Assist could not insert that content into the note.");
          return false;
        }
        commitEditorMarkdown(normalizeLineEndings(editor.getMarkdown()));
        refreshSlashQuery(editor);
        return true;
      }

      const fallbackRange = range ?? resolveCurrentRawMarkdownRange();
      const replacement =
        fallbackRange.from === fallbackRange.to ? `\n\n${normalized}\n\n` : normalized;
      replaceRawMarkdownSelection(fallbackRange, replacement);
      return true;
    },
    [
      commitEditorMarkdown,
      editor,
      isRichEditorMode,
      refreshSlashQuery,
      replaceRawMarkdownSelection,
      resolveCurrentRawMarkdownRange,
      showScreenshotNotice,
    ]
  );

  const insertThreadNotePlainTextAtRange = useCallback(
    (plainText: string, range?: PendingImagePickerInsert | null) => {
      const normalized = normalizeLineEndings(plainText).trim();
      if (!normalized) {
        showScreenshotNotice("There is nothing to insert into the note yet.");
        return false;
      }

      if (isRichEditorMode) {
        if (!editor) {
          showScreenshotNotice("The rich editor is not ready yet. Try again in a moment.");
          return false;
        }

        const documentSize = editor.state.doc.content.size;
        const from = Math.max(0, Math.min(range?.from ?? editor.state.selection.from, documentSize));
        const to = Math.max(from, Math.min(range?.to ?? editor.state.selection.to, documentSize));
        const inserted = editor
          .chain()
          .focus()
          .insertContentAt(
            {
              from,
              to,
            },
            buildThreadNotePlainTextContent(normalized)
          )
          .run();
        if (!inserted) {
          showScreenshotNotice("Open Assist could not insert that content into the note.");
          return false;
        }
        commitEditorMarkdown(normalizeLineEndings(editor.getMarkdown()));
        refreshSlashQuery(editor);
        return true;
      }

      const fallbackRange = range ?? resolveCurrentRawMarkdownRange();
      const replacement =
        fallbackRange.from === fallbackRange.to ? `\n\n${normalized}\n\n` : normalized;
      replaceRawMarkdownSelection(fallbackRange, replacement);
      return true;
    },
    [
      commitEditorMarkdown,
      editor,
      isRichEditorMode,
      refreshSlashQuery,
      replaceRawMarkdownSelection,
      resolveCurrentRawMarkdownRange,
      showScreenshotNotice,
    ]
  );

  const handleOpenScreenshotImport = useCallback(
    async (requestedCaptureMode?: ThreadNoteScreenshotCaptureMode) => {
      if (!noteId || !ownerKind || !ownerId) {
        showScreenshotNotice("Open a note before adding a screenshot.");
        return;
      }

      const captureMode = requestedCaptureMode ?? screenshotCaptureMode;
      const insertRange =
        isRichEditorMode && editor
          ? {
              from: editor.state.selection.from,
              to: editor.state.selection.to,
            }
          : resolveCurrentRawMarkdownRange();

      setScreenshotImportState(null);
      setScreenshotCaptureMenuPosition(null);
      setIsCapturingScreenshot(true);

      try {
        const capture = await requestThreadNoteScreenshotCapture(captureMode);
        if (capture.cancelled) {
          return;
        }

        if (!capture.ok || !capture.dataUrl) {
          showScreenshotNotice(
            capture.message ?? "Open Assist could not capture a screenshot for this note."
          );
          return;
        }

        setScreenshotImportState({
          captures: [capture],
          capture,
          insertRange,
          outputMode: "cleanTextAndImage",
          customInstruction: "",
          isProcessing: false,
          processed: null,
          error: null,
        });
      } finally {
        setIsCapturingScreenshot(false);
      }
    },
    [
      editor,
      isRichEditorMode,
      noteId,
      ownerId,
      ownerKind,
      requestThreadNoteScreenshotCapture,
      resolveCurrentRawMarkdownRange,
      screenshotCaptureMode,
      showScreenshotNotice,
    ]
  );

  const handleOpenScreenshotCaptureMenu = useCallback(
    (event: ReactMouseEvent<HTMLButtonElement>) => {
      event.preventDefault();
      event.stopPropagation();

      if (isCapturingScreenshot || screenshotImportState?.isProcessing) {
        return;
      }

      const nextX = Math.max(12, Math.min(event.clientX, window.innerWidth - 228));
      const nextY = Math.max(12, Math.min(event.clientY, window.innerHeight - 176));
      setScreenshotCaptureMenuPosition({ x: nextX, y: nextY });
    },
    [isCapturingScreenshot, screenshotImportState?.isProcessing]
  );

  const handleSelectScreenshotCaptureMode = useCallback(
    (nextMode: ThreadNoteScreenshotCaptureMode) => {
      setScreenshotCaptureMode(nextMode);
      setScreenshotCaptureMenuPosition(null);
      const selectedOption =
        THREAD_NOTE_SCREENSHOT_CAPTURE_MODE_OPTIONS.find((option) => option.value === nextMode) ??
        THREAD_NOTE_SCREENSHOT_CAPTURE_MODE_OPTIONS[0];
      showScreenshotNotice(selectedOption.selectionNotice);
    },
    [showScreenshotNotice]
  );

  const handleCloseScreenshotImport = useCallback(() => {
    setScreenshotImportState(null);
  }, []);

  const handleAddScreenshotCapture = useCallback(async () => {
    if (!screenshotImportState) {
      return;
    }

    const captureMode = screenshotImportState.capture.captureMode ?? screenshotCaptureMode;
    setScreenshotCaptureMenuPosition(null);
    setIsCapturingScreenshot(true);

    try {
      const nextCapture = await requestThreadNoteScreenshotCapture(captureMode);
      if (nextCapture.cancelled) {
        return;
      }

      if (!nextCapture.ok || !nextCapture.dataUrl) {
        showScreenshotNotice(
          nextCapture.message ?? "Open Assist could not capture the next screenshot."
        );
        return;
      }

      const currentCaptures = screenshotImportState.captures.length
        ? screenshotImportState.captures
        : [screenshotImportState.capture];
      const combinedCaptures = [...currentCaptures, nextCapture];
      const combinedCapture = await composeThreadNoteScreenshotSessionCapture(
        combinedCaptures,
        captureMode
      );

      if (!combinedCapture) {
        showScreenshotNotice("Open Assist could not combine those screenshots.");
        return;
      }

      setScreenshotImportState((current) => {
        if (!current) {
          return current;
        }

        const baseCaptures = current.captures.length ? current.captures : [current.capture];
        return {
          ...current,
          captures: [...baseCaptures, nextCapture],
          capture: combinedCapture,
          processed: null,
          error: null,
        };
      });
    } finally {
      setIsCapturingScreenshot(false);
    }
  }, [
    requestThreadNoteScreenshotCapture,
    screenshotCaptureMode,
    screenshotImportState,
    showScreenshotNotice,
  ]);

  const handleGenerateScreenshotImportPreview = useCallback(async () => {
    if (!screenshotImportState) {
      return;
    }

    setScreenshotImportState((current) =>
      current
        ? {
            ...current,
            isProcessing: true,
            error: null,
          }
        : current
    );

    const result = await requestThreadNoteScreenshotProcessingPreview({
      capture: screenshotImportState.capture,
      outputMode: screenshotImportState.outputMode,
      customInstruction: screenshotImportState.customInstruction,
    });

    setScreenshotImportState((current) => {
      if (!current || current.capture.requestId !== screenshotImportState.capture.requestId) {
        return current;
      }

      return {
        ...current,
        isProcessing: false,
        processed: result.ok ? result : null,
        error: result.ok
          ? null
          : result.message ?? "Open Assist could not prepare that screenshot import preview.",
      };
    });
  }, [requestThreadNoteScreenshotProcessingPreview, screenshotImportState]);

  const handleApplyScreenshotImport = useCallback(async () => {
    if (!screenshotImportState || !screenshotImportState.processed?.ok) {
      showScreenshotNotice("Generate the screenshot preview first.");
      return;
    }

    const processed = screenshotImportState.processed;
    const insertRange = screenshotImportState.insertRange;
    const outputMode = screenshotImportState.outputMode;
    const cleanedMarkdown = normalizeLineEndings(processed.markdown ?? "").trim();
    const rawText = normalizeLineEndings(processed.rawText ?? "").trim();

    if (outputMode === "cleanTextAndImage") {
      if (!screenshotImportState.capture.dataUrl) {
        showScreenshotNotice("The captured screenshot is no longer available.");
        return;
      }

      if (!cleanedMarkdown) {
        showScreenshotNotice("The screenshot preview is empty. Generate it again and retry.");
        return;
      }

      const screenshotFile = await fileFromThreadNoteDataURL(
        screenshotImportState.capture.dataUrl,
        screenshotImportState.capture.filename ?? "Screenshot.png",
        screenshotImportState.capture.mimeType ?? "image/png"
      );
      if (!screenshotFile) {
        showScreenshotNotice("Open Assist could not reopen the captured screenshot.");
        return;
      }

      const upload = await requestThreadNoteImageAsset(screenshotFile);
      if (!upload.ok || !upload.url) {
        showScreenshotNotice(
          upload.message ?? "Open Assist could not save the screenshot into this note."
        );
        return;
      }

      const combinedMarkdown = [
        buildThreadNoteMarkdownImage({
          src: upload.url,
          alt: preferredThreadNoteImageAlt(screenshotImportState.capture.filename),
          title: "",
        }),
        cleanedMarkdown,
      ]
        .filter(Boolean)
        .join("\n\n");

      if (!insertThreadNoteMarkdownAtRange(combinedMarkdown, insertRange)) {
        return;
      }

      setScreenshotImportState(null);
      return;
    }

    if (outputMode === "rawOCR") {
      const textToInsert = rawText || cleanedMarkdown;
      if (!textToInsert) {
        showScreenshotNotice("The screenshot preview is empty. Generate it again and retry.");
        return;
      }

      if (!insertThreadNotePlainTextAtRange(textToInsert, insertRange)) {
        return;
      }

      setScreenshotImportState(null);
      return;
    }

    if (!cleanedMarkdown) {
      showScreenshotNotice("The screenshot preview is empty. Generate it again and retry.");
      return;
    }

    if (!insertThreadNoteMarkdownAtRange(cleanedMarkdown, insertRange)) {
      return;
    }

    setScreenshotImportState(null);
  }, [
    insertThreadNoteMarkdownAtRange,
    insertThreadNotePlainTextAtRange,
    requestThreadNoteImageAsset,
    screenshotImportState,
    showScreenshotNotice,
  ]);

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

  const hideSelectionAssistantActions = useCallback(() => {
    dispatchThreadNoteCommand("hideSelectionAssistantActions");
  }, [dispatchThreadNoteCommand]);

  const dispatchSelectionAssistantCommand = useCallback(
    (
      type: "showSelectionAssistantActions" | "openSelectionAssistantQuestionComposer",
      options: {
        selectedText: string;
        from?: number;
        to?: number;
        anchorPoint?: { x: number; y: number };
      }
    ) => {
      const selectedText = options.selectedText.trim();
      if (!selectedText) {
        hideSelectionAssistantActions();
        return;
      }

      const rect =
        resolveThreadNoteSelectionAssistantRect(editorBodyRef.current) ??
        (options.anchorPoint
          ? buildThreadNoteSelectionAnchorRect(options.anchorPoint.x, options.anchorPoint.y)
          : null);

      if (!rect) {
        hideSelectionAssistantActions();
        return;
      }

      dispatchThreadNoteCommand(type, {
        selectedText,
        rect,
        ...(typeof options.from === "number"
          ? { sourceSelectionFrom: options.from }
          : {}),
        ...(typeof options.to === "number" ? { sourceSelectionTo: options.to } : {}),
      });
    },
    [dispatchThreadNoteCommand, hideSelectionAssistantActions]
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

  const handleApplyHeadingAlignment = useCallback(
    (alignment: ThreadNoteHeadingAlignment) => {
      if (!editor || !headingTagEditor) {
        return;
      }

      const view = resolveEditorView(editor);
      if (!view) {
        return;
      }

      updateHeadingAlignmentAtSelection(view, headingTagEditor.selectionPos, alignment);
      refreshSlashQuery(editor);
    },
    [editor, headingTagEditor, refreshSlashQuery]
  );

  const handleInsertMarkdownBlock = useCallback(
    (action: MarkdownInsertAction) => {
      if (!editor || !headingTagEditor) {
        return;
      }

      applyMarkdownInsertAction(
        editor,
        headingTagEditor.selectionPos,
        headingTagEditor.insertAt,
        action
      );
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

  const serializeMarkdownForRange = useCallback(
    (from: number, to: number) => {
      if (!editor || from >= to) {
        return "";
      }

      try {
        const selectionDoc = editor.state.doc.cut(from, to);
        const markdown = editor.markdown?.serialize(selectionDoc.toJSON()) ?? "";
        return normalizeLineEndings(markdown).trim();
      } catch {
        return editor.state.doc.textBetween(from, to, "\n\n").trim();
      }
    },
    [editor]
  );

  const buildMarkdownAfterDeletingRange = useCallback(
    (from: number, to: number) => {
      if (!editor || from >= to) {
        return normalizeLineEndings(editor?.getMarkdown() ?? draftText);
      }

      try {
        const transaction = editor.state.tr.deleteRange(from, to);
        const nextState = editor.state.apply(transaction);
        const markdown = editor.markdown?.serialize(nextState.doc.toJSON());
        return normalizeLineEndings(markdown ?? editor.getMarkdown());
      } catch {
        return normalizeLineEndings(editor.getMarkdown());
      }
    },
    [draftText, editor]
  );

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
      runAfterSave(
        () =>
          dispatchThreadNoteCommand("openLinkedNote", {
            ownerKind: target.ownerKind,
            ownerId: target.ownerId,
            noteId: target.noteId,
          }),
        "open the linked note"
      );
    },
    [closeNoteContextMenu, dispatchThreadNoteCommand, notes, runAfterSave, showLinkNotice]
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
      if (!mermaidPicker) {
        return;
      }

      if (isRichEditorMode && editor) {
        editor.commands.insertContentAt(mermaidPicker.insertAt, template.markdown, {
          contentType: "markdown",
        });
      } else {
        replaceRawMarkdownSelection(
          { from: mermaidPicker.insertAt, to: mermaidPicker.insertAt },
          `${template.markdown}\n`
        );
      }

      setMermaidPicker(null);
      setSelectedMermaidIndex(0);

      if (isRichEditorMode && editor) {
        window.requestAnimationFrame(() => {
          editor.chain().focus().run();
          refreshSlashQuery(editor);
        });
        return;
      }

      focusRawMarkdownEditor();
    },
    [
      editor,
      focusRawMarkdownEditor,
      isRichEditorMode,
      mermaidPicker,
      refreshSlashQuery,
      replaceRawMarkdownSelection,
    ]
  );

  useEffect(() => {
    const externalText = normalizeLineEndings(state?.text ?? "");
    const noteChanged = noteKey !== previousNoteKeyRef.current;
    let syncRAF: number | null = null;

    if (noteChanged) {
      previousNoteKeyRef.current = noteKey;
      previousOwnerKindRef.current = ownerKind ?? null;
      previousOwnerIdRef.current = ownerId ?? null;
      previousNoteIdRef.current = noteId ?? null;
      previousThreadIdRef.current = threadId ?? null;
      clearSaveDebounce();
      clearSaveRetry();
      clearActiveSave();
      clearPendingNavigation();
      setLeavePrompt(null);
      // Step 1: seed the "last sent" ref so subsequent external-echo
      // checks know the baseline for this note.
      lastSentToSwiftRef.current = externalText;
      draftRevisionRef.current = 0;
      lastSavedDraftRevisionRef.current = 0;
      isRichEditorReadyForInputRef.current = false;
      setDraftText(externalText);
      setHasLocalDirtyChanges(false);
      hasLocalDirtyChangesRef.current = false;
      setForcedNoteEditorSurfaceMode(null);
      setEditorLoadNotice(null);
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
      setSelectedImage(null);
      setIsHistoryPanelOpen(false);
      setRecoveryPreview(null);
      pendingImagePickerInsertRef.current = null;
      summaryTargetRef.current = null;
      setChartStyleInstruction("");
    } else if (
      // Step 1: only accept external state when it matches what we
      // most recently sent to Swift. Otherwise it's a stale echo that
      // would clobber keystrokes typed during the save round-trip.
      !hasLocalDirtyChanges &&
      draftText !== externalText &&
      externalText === lastSentToSwiftRef.current
    ) {
      setDraftText(externalText);
    }

    const isEditorFocusedSafely =
      isRichEditorMode && editor && resolveEditorView(editor) ? editor.isFocused : false;
    const shouldSyncEditorContent =
      isRichEditorMode &&
      (noteChanged ||
        !isRichEditorReadyForInputRef.current ||
        (!hasLocalDirtyChanges &&
          draftText !== externalText &&
          // Step 1: same echo guard for the TipTap document sync.
          externalText === lastSentToSwiftRef.current &&
          !isEditorFocusedSafely));

    if (editor && shouldSyncEditorContent) {
      const syncEditorContent = () => {
        if (!resolveEditorView(editor)) {
          syncRAF = window.requestAnimationFrame(syncEditorContent);
          return;
        }

        let currentMarkdown = "";
        try {
          currentMarkdown = normalizeLineEndings(editor.getMarkdown());
        } catch (error) {
          console.error("Failed to read current thread note markdown before sync", error);
        }

        if (currentMarkdown !== externalText) {
          const synced = syncRichEditorMarkdown(editor, externalText, {
            fallbackMessage:
              "This note opened in Markdown because rich view could not load it safely.",
            refreshSelectionState: false,
          });
          if (!synced) {
            return;
          }
          isRichEditorReadyForInputRef.current = true;
          setForcedNoteEditorSurfaceMode(null);
          setEditorLoadNotice(null);
        } else {
          isRichEditorReadyForInputRef.current = true;
          setForcedNoteEditorSurfaceMode(null);
          setEditorLoadNotice(null);
        }

        try {
          refreshSlashQuery(editor);
        } catch (refreshError) {
          console.error("Failed to refresh thread note slash query after note switch", refreshError);
        }
      };

      syncEditorContent();
    }

    return () => {
      if (syncRAF !== null) {
        window.cancelAnimationFrame(syncRAF);
      }
    };
  }, [
    clearActiveSave,
    clearPendingNavigation,
    clearSaveDebounce,
    clearSaveRetry,
    draftText,
    editor,
    hasLocalDirtyChanges,
    isExternalMarkdownFile,
    isRichEditorMode,
    isNotesWorkspace,
    noteKey,
    refreshSlashQuery,
    syncRichEditorMarkdown,
    state?.text,
  ]);

  useEffect(() => {
    if (!isRichEditorMode) {
      isRichEditorReadyForInputRef.current = false;
      return;
    }

    if (!isRichEditorMode || !editor) {
      return;
    }

    let editorDom: HTMLElement | null = null;
    let rafID: number | null = null;
    let activeHeadingDropTarget: HTMLElement | null = null;

    const clearHeadingDropTarget = () => {
      if (!activeHeadingDropTarget) {
        return;
      }
      activeHeadingDropTarget.classList.remove(THREAD_NOTE_HEADING_DROP_TARGET_CLASS);
      activeHeadingDropTarget = null;
    };

    const handleUpdate = () => {
      if (isApplyingExternalContentRef.current) {
        return;
      }
      if (!isRichEditorReadyForInputRef.current) {
        return;
      }
      const nextText = normalizeLineEndings(editor.getMarkdown());
      updateDraftTextLocally(nextText);
      setHeadingTagEditor(null);
      refreshSlashQuery(editor);
    };

    const handleSelectionChange = () => {
      refreshSlashQuery(editor);
    };

    const handleBlur = () => {
      if (!isRichEditorReadyForInputRef.current) {
        return;
      }
      if (!isExternalMarkdownFile) {
        commitSave(editor.getMarkdown());
      }
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

    const handleEditorDragStart = (event: DragEvent) => {
      if (!event.altKey || !event.dataTransfer) {
        return;
      }

      const editorView = resolveEditorView(editor);
      if (!editorView || editorView.state.selection.empty) {
        return;
      }

      const selectedText = editorView.state.doc
        .textBetween(
          editorView.state.selection.from,
          editorView.state.selection.to,
          "\n\n"
        )
        .trim();
      if (!selectedText) {
        return;
      }

      try {
        event.dataTransfer.clearData();
      } catch {
        // Some browsers restrict clearing drag data; plain text is enough for our drop flow.
      }

      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", selectedText);
      event.dataTransfer.setData(
        THREAD_NOTE_INTERNAL_DRAG_MIME,
        JSON.stringify({
          from: editorView.state.selection.from,
          to: editorView.state.selection.to,
          move: true,
        } satisfies ThreadNoteInternalDragData)
      );
      editorView.dragging = {
        slice: editorView.state.selection.content(),
        move: true,
      };
    };

    const handleEditorDragOver = (event: DragEvent) => {
      const nextHeadingDropTarget = isNoteContentDragEvent(event)
        ? resolveHeadingDropTargetElement(event.target)
        : null;

      if (activeHeadingDropTarget === nextHeadingDropTarget) {
        if (nextHeadingDropTarget && event.dataTransfer) {
          event.dataTransfer.dropEffect = "move";
        }
        return;
      }

      clearHeadingDropTarget();
      if (!nextHeadingDropTarget) {
        return;
      }

      activeHeadingDropTarget = nextHeadingDropTarget;
      activeHeadingDropTarget.classList.add(THREAD_NOTE_HEADING_DROP_TARGET_CLASS);
      if (event.dataTransfer) {
        event.dataTransfer.dropEffect = "move";
      }
    };

    const handleEditorDragLeave = (event: DragEvent) => {
      const relatedTarget = event.relatedTarget;
      if (relatedTarget instanceof Node && editorDom?.contains(relatedTarget)) {
        return;
      }
      clearHeadingDropTarget();
    };

    const handleEditorDropCleanup = () => {
      clearHeadingDropTarget();
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
        !event.metaKey
      ) {
        if (handleSelectedListIndent(editor, event.shiftKey ? "outdent" : "indent")) {
          event.preventDefault();
          event.stopPropagation();
          refreshSlashQuery(editor);
          return;
        }
      }

      if (
        event.key === "Enter" &&
        !event.altKey &&
        !event.ctrlKey &&
        !event.metaKey
      ) {
        const sectionExitContext = event.shiftKey
          ? resolveSectionLeaveContext(editor)
          : null;
        if (sectionExitContext) {
          event.preventDefault();
          event.stopPropagation();
          if (exitSectionAtLastBlock(editor, sectionExitContext.section, sectionExitContext.block)) {
            return;
          }

          editor.commands.focus("end");
          return;
        }

        const headingSection = findHeadingSectionAtSelection(editor);
        if (!event.shiftKey && headingSection?.isCollapsible) {
          event.preventDefault();
          event.stopPropagation();
          insertParagraphAfterHeading(editor, headingSection);
          return;
        }

        const shouldInsertOutsideCollapsedSection = !event.shiftKey;
        const collapsedSection =
          shouldInsertOutsideCollapsedSection
            ? findCollapsedHeadingSectionAtSelection(editor.state)
            : null;
        const sectionEnd = collapsedSection?.sectionEnd;

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
      editorDom.addEventListener("dragstart", handleEditorDragStart, true);
      editorDom.addEventListener("dragover", handleEditorDragOver, true);
      editorDom.addEventListener("dragleave", handleEditorDragLeave, true);
      editorDom.addEventListener("drop", handleEditorDropCleanup, true);
      editorDom.addEventListener("dragend", handleEditorDropCleanup, true);
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
      clearHeadingDropTarget();
      editorDom?.removeEventListener("scroll", handleScroll);
      editorDom?.removeEventListener("keydown", handleCapturedKeyDown, true);
      editorDom?.removeEventListener("click", handleEditorClick, true);
      editorDom?.removeEventListener("dblclick", handleLineDoubleClick);
      editorDom?.removeEventListener("contextmenu", handleEditorContextMenu);
      editorDom?.removeEventListener("dragstart", handleEditorDragStart, true);
      editorDom?.removeEventListener("dragover", handleEditorDragOver, true);
      editorDom?.removeEventListener("dragleave", handleEditorDragLeave, true);
      editorDom?.removeEventListener("drop", handleEditorDropCleanup, true);
      editorDom?.removeEventListener("dragend", handleEditorDropCleanup, true);
    };
  }, [
    applyMermaidTemplate,
    commitSave,
    closeNoteContextMenu,
    editor,
    isRichEditorMode,
    isExternalMarkdownFile,
    isNotesWorkspace,
    openHeadingTagEditor,
    mermaidPickerItems,
    noteId,
    noteSelection?.from,
    noteSelection?.text,
    noteSelection?.to,
    openMermaidTemplateType,
    openInternalNoteTarget,
    ownerId,
    ownerKind,
    refreshSlashQuery,
    updateDraftTextLocally,
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

    if (!noteId) {
      return;
    }

    if (!showsEditorPane) {
      openRef.current = isOpen;
      return;
    }

    if (isRawMarkdownMode) {
      if (!openRef.current) {
        focusRawMarkdownEditor();
      }

      openRef.current = isOpen;
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
  }, [
    editor,
    focusRawMarkdownEditor,
    isOpen,
    isRawMarkdownMode,
    noteId,
    refreshSlashQuery,
    showsEditorPane,
  ]);

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
    const outcomeId = projectNoteTransferOutcome?.id ?? null;
    if (!outcomeId || outcomeId === previousProjectTransferOutcomeIdRef.current) {
      return;
    }

    previousProjectTransferOutcomeIdRef.current = outcomeId;
    showLinkNotice(projectNoteTransferOutcome?.message ?? "");
    setProjectNoteTransfer(null);
  }, [projectNoteTransferOutcome, showLinkNotice]);

  useEffect(() => {
    if (!projectNoteTransfer?.isApplying || !projectNoteTransferPreview?.isError) {
      return;
    }

    setProjectNoteTransfer((current) =>
      current
        ? {
            ...current,
            isApplying: false,
          }
        : current
    );
  }, [projectNoteTransfer?.isApplying, projectNoteTransferPreview?.isError]);

  useEffect(() => {
    setProjectNoteTransfer(null);
    setScreenshotImportState(null);
    setScreenshotCaptureMenuPosition(null);
  }, [noteKey]);

  useEffect(() => {
    if (!imageNotice) {
      return;
    }

    const timeout = window.setTimeout(() => {
      setImageNotice(null);
    }, 3200);

    return () => window.clearTimeout(timeout);
  }, [imageNotice]);

  useEffect(() => {
    if (!screenshotNotice) {
      return;
    }

    const timeout = window.setTimeout(() => {
      setScreenshotNotice(null);
    }, 3200);

    return () => window.clearTimeout(timeout);
  }, [screenshotNotice]);

  useEffect(() => {
    try {
      window.localStorage.setItem(
        THREAD_NOTE_SCREENSHOT_CAPTURE_MODE_STORAGE_KEY,
        screenshotCaptureMode
      );
    } catch (error) {
      console.warn("[thread-note screenshot] could not store capture mode", error);
    }
  }, [screenshotCaptureMode]);

  useEffect(() => {
    if (!screenshotCaptureMenuPosition) {
      return;
    }

    const handlePointerDown = (event: PointerEvent) => {
      if (!screenshotCaptureMenuRef.current?.contains(event.target as Node)) {
        setScreenshotCaptureMenuPosition(null);
      }
    };

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setScreenshotCaptureMenuPosition(null);
      }
    };

    const handleViewportChange = () => {
      setScreenshotCaptureMenuPosition(null);
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
  }, [screenshotCaptureMenuPosition]);

  useEffect(() => {
    threadNoteFindStateRef.current = {
      query: "",
      matches: [],
      currentIndex: -1,
    };
  }, [noteKey]);

  const clearThreadNoteFind = useCallback((): ThreadNoteFindResponse => {
    threadNoteFindStateRef.current = {
      query: "",
      matches: [],
      currentIndex: -1,
    };

    return {
      handled: true,
      matchCount: 0,
      currentMatch: 0,
    };
  }, []);

  const activateThreadNoteFindMatch = useCallback(
    (requestedIndex: number): ThreadNoteFindResponse => {
      if (!editor || !noteId) {
        return {
          handled: false,
          matchCount: 0,
          currentMatch: 0,
        };
      }

      const activeQuery = threadNoteFindStateRef.current.query.trim();
      if (!activeQuery) {
        return clearThreadNoteFind();
      }

      const matches = collectThreadNoteFindMatches(editor, activeQuery);
      if (!matches.length) {
        threadNoteFindStateRef.current = {
          query: activeQuery,
          matches: [],
          currentIndex: -1,
        };
        return {
          handled: true,
          matchCount: 0,
          currentMatch: 0,
        };
      }

      const currentIndex = Math.max(0, Math.min(requestedIndex, matches.length - 1));
      threadNoteFindStateRef.current = {
        query: activeQuery,
        matches,
        currentIndex,
      };
      focusThreadNoteFindMatch(editor, matches[currentIndex]);

      return {
        handled: true,
        matchCount: matches.length,
        currentMatch: currentIndex + 1,
      };
    },
    [clearThreadNoteFind, editor, noteId]
  );

  const searchThreadNoteText = useCallback(
    (query: string): ThreadNoteFindResponse => {
      if (!editor || !noteId) {
        return {
          handled: false,
          matchCount: 0,
          currentMatch: 0,
        };
      }

      const trimmedQuery = query.trim();
      if (!trimmedQuery) {
        return clearThreadNoteFind();
      }

      const matches = collectThreadNoteFindMatches(editor, trimmedQuery);
      threadNoteFindStateRef.current = {
        query: trimmedQuery,
        matches,
        currentIndex: -1,
      };

      return {
        handled: true,
        matchCount: matches.length,
        currentMatch: 0,
      };
    },
    [clearThreadNoteFind, editor, noteId]
  );

  const shouldHandleThreadNoteFind = useCallback(() => {
    if (!editor || !noteId) {
      return false;
    }

    if (isFullScreenWorkspace) {
      return true;
    }

    if (threadNoteFindStateRef.current.query) {
      return true;
    }

    const activeElement = document.activeElement;
    return Boolean(activeElement && editorBodyRef.current?.contains(activeElement));
  }, [editor, isFullScreenWorkspace, noteId]);

  useEffect(() => {
    const handleThreadNoteFindRequest = (event: Event) => {
      const detail = (event as CustomEvent<ThreadNoteFindRequestDetail>).detail;
      if (!detail?.respond) {
        return;
      }

      if (!shouldHandleThreadNoteFind()) {
        detail.respond({
          handled: false,
          matchCount: 0,
          currentMatch: 0,
        });
        return;
      }

      switch (detail.action) {
        case "search":
          detail.respond(searchThreadNoteText(detail.query ?? ""));
          break;
        case "activate":
          detail.respond(activateThreadNoteFindMatch(detail.index ?? 0));
          break;
        case "clear":
          detail.respond(clearThreadNoteFind());
          break;
        default:
          detail.respond({
            handled: false,
            matchCount: 0,
            currentMatch: 0,
          });
      }
    };

    window.addEventListener(
      THREAD_NOTE_FIND_REQUEST_EVENT,
      handleThreadNoteFindRequest as EventListener
    );
    return () => {
      window.removeEventListener(
        THREAD_NOTE_FIND_REQUEST_EVENT,
        handleThreadNoteFindRequest as EventListener
      );
    };
  }, [
    activateThreadNoteFindMatch,
    clearThreadNoteFind,
    searchThreadNoteText,
    shouldHandleThreadNoteFind,
  ]);

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
    if (
      isExternalMarkdownFile ||
      !isOpen ||
      !ownerKind ||
      !ownerId ||
      !noteId ||
      !hasLocalDirtyChanges
    ) {
      return;
    }

    clearSaveDebounce();
    saveDebounceTimeoutRef.current = window.setTimeout(() => {
      saveDebounceTimeoutRef.current = null;
      commitSave();
    }, THREAD_NOTE_SAVE_DEBOUNCE_MS);

    return () => {
      clearSaveDebounce();
    };
  }, [
    clearSaveDebounce,
    commitSave,
    hasLocalDirtyChanges,
    isExternalMarkdownFile,
    isOpen,
    noteId,
    ownerId,
    ownerKind,
  ]);

  useEffect(() => {
    if (!isOpen || (isExternalMarkdownFile ? !sourceDescriptor?.canSave : (!ownerKind || !ownerId || !noteId))) {
      return;
    }

    const handleSaveShortcut = (event: KeyboardEvent) => {
      const isSaveCombo =
        (event.metaKey || event.ctrlKey) &&
        !event.shiftKey &&
        !event.altKey &&
        (event.key === "s" || event.key === "S");
      if (!isSaveCombo) {
        return;
      }
      event.preventDefault();
      commitSave(undefined, { force: true });
    };

    document.addEventListener("keydown", handleSaveShortcut);
    return () => document.removeEventListener("keydown", handleSaveShortcut);
  }, [commitSave, isExternalMarkdownFile, isOpen, noteId, ownerId, ownerKind, sourceDescriptor?.canSave]);

  // Step 2: page-unload / visibility / blur flush. These fire when the
  // WKWebView is about to be torn down (app quit, window destroyed) or
  // loses focus to another window. If we have dirty changes, force-save
  // synchronously so they don't die with the process.
  useEffect(() => {
    const hasUnfinishedSaveWork = () =>
      hasLocalDirtyChangesRef.current || activeSaveRef.current !== null;

    const flushIfDirty = (reason: string) => {
      if (!hasLocalDirtyChangesRef.current) {
        return;
      }
      console.info("[thread-note save] exit flush", { reason });
      if (!isExternalMarkdownFile) {
        commitSave(undefined, { force: true });
      }
    };

    const handlePageHide = () => flushIfDirty("pagehide");
    const handleBeforeUnload = (event: BeforeUnloadEvent) => {
      if (!hasUnfinishedSaveWork()) {
        return;
      }
      flushIfDirty("beforeunload");
      event.preventDefault();
      event.returnValue = "";
    };
    const handleVisibilityChange = () => {
      if (document.visibilityState === "hidden") {
        flushIfDirty("visibilitychange");
      }
    };
    const handleWindowBlur = () => flushIfDirty("window-blur");

    window.addEventListener("pagehide", handlePageHide);
    window.addEventListener("beforeunload", handleBeforeUnload);
    document.addEventListener("visibilitychange", handleVisibilityChange);
    window.addEventListener("blur", handleWindowBlur);
    return () => {
      flushIfDirty("unmount");
      window.removeEventListener("pagehide", handlePageHide);
      window.removeEventListener("beforeunload", handleBeforeUnload);
      document.removeEventListener("visibilitychange", handleVisibilityChange);
      window.removeEventListener("blur", handleWindowBlur);
    };
  }, [commitSave, isExternalMarkdownFile]);

  useEffect(() => {
    if (!slashQuery && !mermaidPicker) {
      return;
    }

    if (!isRichEditorMode || !editor) {
      setMenuPosition(DEFAULT_THREAD_NOTE_MENU_POSITION);
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
  }, [editor, isRichEditorMode, layerRef, mermaidPicker, slashQuery]);

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

  useEffect(() => {
    const selectedText = noteSelection?.text?.trim() ?? "";
    const shouldShowSelectionActions =
      isOpen &&
      isRichEditorMode &&
      state?.viewMode === "edit" &&
      !noteContextMenu &&
      !headingTagEditor &&
      !slashQuery &&
      !mermaidPicker &&
      !noteLinkPicker &&
      !chartRequestComposer &&
      !isRenamingTitle &&
      Boolean(selectedText);

    if (!shouldShowSelectionActions) {
      hideSelectionAssistantActions();
      return;
    }

    const syncSelectionAssistant = () => {
      dispatchSelectionAssistantCommand("showSelectionAssistantActions", {
        selectedText,
        from: noteSelection?.from,
        to: noteSelection?.to,
      });
    };

    const frame = window.requestAnimationFrame(syncSelectionAssistant);
    const handleResize = () => syncSelectionAssistant();
    const handleViewportChange = () => hideSelectionAssistantActions();

    window.addEventListener("resize", handleResize);
    window.addEventListener("blur", handleViewportChange);
    document.addEventListener("scroll", handleViewportChange, true);

    return () => {
      window.cancelAnimationFrame(frame);
      window.removeEventListener("resize", handleResize);
      window.removeEventListener("blur", handleViewportChange);
      document.removeEventListener("scroll", handleViewportChange, true);
    };
  }, [
    chartRequestComposer,
    dispatchSelectionAssistantCommand,
    headingTagEditor,
    hideSelectionAssistantActions,
    isOpen,
    isRichEditorMode,
    isRenamingTitle,
    mermaidPicker,
    noteContextMenu,
    noteLinkPicker,
    noteSelection?.from,
    noteSelection?.text,
    noteSelection?.to,
    slashQuery,
    state?.viewMode,
  ]);

  const handleCloseDrawer = useCallback(() => {
    if (!canCloseDrawer) {
      return;
    }
    if (isRichEditorMode && editor) {
      editor.commands.blur();
    } else {
      rawMarkdownTextareaRef.current?.blur();
    }
    setIsSelectorOpen(false);
    setSelectorFilter("");
    setIsRenamingTitle(false);
    setHeadingTagEditor(null);
    setSlashQuery(null);
    setMermaidEditingContext(null);
    setMermaidPicker(null);
    closeNoteContextMenu();
    runAfterSave(
      () => dispatchThreadNoteCommand("setOpen", { isOpen: false }),
      "close this note"
    );
  }, [
    canCloseDrawer,
    closeNoteContextMenu,
    dispatchThreadNoteCommand,
    editor,
    isRichEditorMode,
    runAfterSave,
  ]);

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

      const clickedOverflowMenu = Boolean(overflowMenuRef.current?.contains(target));
      const clickedOverflowTrigger = Boolean(
        overflowMenuTriggerRef.current?.contains(target)
      );
      if (
        isOverflowMenuOpen &&
        !clickedOverflowMenu &&
        !clickedOverflowTrigger
      ) {
        setIsOverflowMenuOpen(false);
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
  }, [canCloseDrawer, headingTagEditor, isOpen, isOverflowMenuOpen, isSelectorOpen]);

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
    setChartRenderError(null);
  }, [noteKey]);

  useEffect(() => {
    setChartRenderError(null);
  }, [aiDraftPreview?.isError, aiDraftPreview?.markdown, aiDraftPreview?.mode]);

  const applyRawMarkdownSlashCommand = useCallback(
    (command: SlashCommand, range: SlashQueryState) => {
      const mermaidTypeOption =
        MERMAID_TEMPLATE_TYPES.find((option) => option.commandId === command.id) ?? null;

      setSlashQuery(null);
      setSelectedSlashIndex(0);
      setMermaidEditingContext(null);
      setHeadingTagEditor(null);

      if (command.id === "image") {
        const nextMarkdown = replaceMarkdownRange(latestDraftTextRef.current, range, "");
        commitEditorMarkdown(nextMarkdown);
        updateRawMarkdownSelection(range.replaceFrom, range.replaceFrom, nextMarkdown);
        handleOpenImagePicker({
          from: range.replaceFrom,
          to: range.replaceFrom,
        });
        return;
      }

      if (command.id === "mermaid" || mermaidTypeOption) {
        const nextMarkdown = replaceMarkdownRange(latestDraftTextRef.current, range, "");
        commitEditorMarkdown(nextMarkdown);
        updateRawMarkdownSelection(range.replaceFrom, range.replaceFrom, nextMarkdown);
        setMermaidPicker({
          insertAt: range.replaceFrom,
          step: mermaidTypeOption ? "template" : "type",
          type: mermaidTypeOption?.type ?? null,
          canGoBack: false,
        });
        setSelectedMermaidIndex(0);
        setMenuPosition(DEFAULT_THREAD_NOTE_MENU_POSITION);
        focusRawMarkdownEditor({
          start: range.replaceFrom,
          end: range.replaceFrom,
        });
        return;
      }

      const insert = buildRawMarkdownSlashInsert(command.id);
      if (!insert) {
        focusRawMarkdownEditor();
        return;
      }

      applyRawMarkdownReplacement(range, insert.text, insert.selection);
    },
    [
      applyRawMarkdownReplacement,
      commitEditorMarkdown,
      focusRawMarkdownEditor,
      handleOpenImagePicker,
      updateRawMarkdownSelection,
    ]
  );

  const applySlashCommand = useCallback(
    (command: SlashCommand) => {
      if (!slashQuery) {
        return;
      }

      if (isRawMarkdownMode) {
        applyRawMarkdownSlashCommand(command, slashQuery);
        return;
      }

      if (!editor) {
        return;
      }

      command.run(editor, slashQuery);
      setSlashQuery(null);
      window.requestAnimationFrame(() => {
        editor.chain().focus().run();
        refreshSlashQuery(editor);
      });
    },
    [applyRawMarkdownSlashCommand, editor, isRawMarkdownMode, refreshSlashQuery, slashQuery]
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
    setIsSelectorOpen(false);
    setSelectorFilter("");
    setIsRenamingTitle(false);
    runAfterSave(() => dispatchThreadNoteCommand("createNote"), "create a new note");
  }, [dispatchThreadNoteCommand, runAfterSave]);

  const handleCreateNoteForSource = useCallback(
    (sourceOwnerKind: string, sourceOwnerId: string) => {
      setIsSelectorOpen(false);
      setSelectorFilter("");
      setIsRenamingTitle(false);
      runAfterSave(
        () =>
          onDispatchCommand("createNote", {
            ...(threadId ? { threadId } : {}),
            ownerKind: sourceOwnerKind,
            ownerId: sourceOwnerId,
          }),
        "create a new note"
      );
    },
    [onDispatchCommand, runAfterSave, threadId]
  );

  const handleOpenBatchOrganizer = useCallback(() => {
    if (!isNotesWorkspace || !state?.workspaceProjectId) {
      return;
    }

    commitSave();
    setIsSelectorOpen(false);
    setSelectorFilter("");
    setIsRenamingTitle(false);
    setIsHistoryPanelOpen(false);
    setIsBatchOrganizerOpen(true);

    if (!batchOrganizerSelectedSourceKeys.length && noteId && ownerKind && ownerId) {
      setBatchOrganizerSelectedSourceKeys([
        batchSourceSelectionKeyFromParts(ownerKind, ownerId, noteId),
      ]);
    }
  }, [
    batchOrganizerSelectedSourceKeys.length,
    commitSave,
    isNotesWorkspace,
    noteId,
    ownerId,
    ownerKind,
    state?.workspaceProjectId,
  ]);

  const handleCloseBatchOrganizer = useCallback(() => {
    const targetProjectId = state?.workspaceProjectId?.trim();
    setIsBatchOrganizerOpen(false);
    setBatchOrganizerSearch("");
    setBatchOrganizerActiveNoteTempId(null);
    setBatchOrganizerEditableNotes([]);
    setBatchOrganizerEditableLinks([]);
    setBatchOrganizerIsApplying(false);

    if (targetProjectId && (batchNotePlanPreview || isBatchNotePlanBusy)) {
      dispatchThreadNoteCommand("cancelBatchNotePlanPreview", {
        targetProjectId,
      });
    }
  }, [
    batchNotePlanPreview,
    dispatchThreadNoteCommand,
    isBatchNotePlanBusy,
    state?.workspaceProjectId,
  ]);

  const handleBackToBatchSourceSelection = useCallback(() => {
    const targetProjectId = state?.workspaceProjectId?.trim();
    setBatchOrganizerEditableNotes([]);
    setBatchOrganizerEditableLinks([]);
    setBatchOrganizerActiveNoteTempId(null);
    setBatchOrganizerIsApplying(false);

    if (targetProjectId && (batchNotePlanPreview || isBatchNotePlanBusy)) {
      dispatchThreadNoteCommand("cancelBatchNotePlanPreview", {
        targetProjectId,
      });
    }
  }, [
    batchNotePlanPreview,
    dispatchThreadNoteCommand,
    isBatchNotePlanBusy,
    state?.workspaceProjectId,
  ]);

  const handleToggleBatchOrganizerSource = useCallback(
    (note: NonNullable<ThreadNoteState["notes"]>[number]) => {
      const selectionKey = batchSourceSelectionKeyForNote(note);
      setBatchOrganizerSelectedSourceKeys((current) => {
        const exists = current.includes(selectionKey);
        if (exists) {
          return current.filter((item) => item !== selectionKey);
        }
        return [...current, selectionKey];
      });
      setBatchOrganizerSourcePreviewKey(selectionKey);
    },
    []
  );

  const handleSelectAllVisibleBatchSources = useCallback(() => {
    setBatchOrganizerSelectedSourceKeys((current) => {
      const merged = new Set(current);
      batchOrganizerSections.forEach((section) => {
        section.visibleNotes.forEach((note) => {
          merged.add(batchSourceSelectionKeyForNote(note));
        });
      });
      return Array.from(merged);
    });
  }, [batchOrganizerSections]);

  const handleClearBatchSourceSelection = useCallback(() => {
    setBatchOrganizerSelectedSourceKeys([]);
    setBatchOrganizerSourcePreviewKey(null);
  }, []);

  const handleRequestBatchPlanPreview = useCallback(() => {
    const targetProjectId = state?.workspaceProjectId?.trim();
    if (!targetProjectId) {
      return;
    }

    const sourceNotes = batchOrganizerSelectedSourceKeys
      .map((selectionKey) => batchSourceSelectionPayload(selectionKey))
      .filter((selection): selection is NonNullable<typeof selection> => Boolean(selection));

    if (!sourceNotes.length) {
      return;
    }

    setBatchOrganizerEditableNotes([]);
    setBatchOrganizerEditableLinks([]);
    setBatchOrganizerActiveNoteTempId(null);
    dispatchThreadNoteCommand("requestBatchNotePlanPreview", {
      targetProjectId,
      sourceNotes,
    });
  }, [
    batchOrganizerSelectedSourceKeys,
    dispatchThreadNoteCommand,
    state?.workspaceProjectId,
  ]);

  const handleBatchOrganizerTitleChange = useCallback((tempId: string, title: string) => {
    setBatchOrganizerEditableNotes((current) =>
      current.map((note) =>
        note.tempId === tempId
          ? {
              ...note,
              title,
            }
          : note
      )
    );
  }, []);

  const handleBatchOrganizerTypeChange = useCallback((tempId: string, noteType: string) => {
    setBatchOrganizerEditableNotes((current) => {
      const existing = current.find((note) => note.tempId === tempId);
      if (!existing) {
        return current;
      }

      let updated = current.map((note) =>
        note.tempId === tempId
          ? {
              ...note,
              noteType,
            }
          : note
      );

      if (noteType === "master") {
        updated = updated.map((note) =>
          note.tempId !== tempId && note.noteType === "master"
            ? {
                ...note,
                noteType: "note",
              }
            : note
        );
        return updated;
      }

      if (existing.noteType === "master") {
        const replacementIndex = updated.findIndex(
          (note) => note.tempId !== tempId && note.accepted
        );
        if (replacementIndex >= 0) {
          updated[replacementIndex] = {
            ...updated[replacementIndex],
            noteType: "master",
          };
        } else {
          return current;
        }
      }

      return updated;
    });
  }, []);

  const handleToggleBatchOrganizerNoteAccepted = useCallback((tempId: string) => {
    setBatchOrganizerEditableNotes((current) => {
      const existing = current.find((note) => note.tempId === tempId);
      if (!existing) {
        return current;
      }

      const nextAccepted = !existing.accepted;
      if (!nextAccepted && existing.noteType === "master") {
        const replacementIndex = current.findIndex(
          (note) => note.tempId !== tempId && note.accepted
        );
        if (replacementIndex === -1) {
          return current;
        }
      }

      let updated = current.map((note) =>
        note.tempId === tempId
          ? {
              ...note,
              accepted: nextAccepted,
            }
          : note
      );

      if (existing.noteType === "master") {
        if (nextAccepted) {
          updated = updated.map((note) =>
            note.tempId !== tempId && note.noteType === "master"
              ? {
                  ...note,
                  noteType: "note",
                }
              : note
          );
        } else {
          const replacementIndex = updated.findIndex(
            (note) => note.tempId !== tempId && note.accepted
          );
          if (replacementIndex >= 0) {
            updated[replacementIndex] = {
              ...updated[replacementIndex],
              noteType: "master",
            };
          }
        }
      }

      return updated;
    });
  }, []);

  const handleToggleBatchOrganizerLinkAccepted = useCallback((linkKey: string) => {
    setBatchOrganizerEditableLinks((current) =>
      current.map((link) =>
        batchPlanEditableLinkKey(link) === linkKey
          ? {
              ...link,
              accepted: !link.accepted,
            }
          : link
      )
    );
  }, []);

  const handleApplyBatchPlan = useCallback(() => {
    const targetProjectId = state?.workspaceProjectId?.trim();
    const previewId = batchNotePlanPreview?.previewId?.trim();
    if (!targetProjectId || !previewId) {
      return;
    }

    setBatchOrganizerIsApplying(true);
    dispatchThreadNoteCommand("applyBatchNotePlanPreview", {
      targetProjectId,
      previewId,
      proposedNotes: batchOrganizerEditableNotes,
      proposedLinks: batchOrganizerEditableLinks,
    });
  }, [
    batchNotePlanPreview?.previewId,
    batchOrganizerEditableLinks,
    batchOrganizerEditableNotes,
    dispatchThreadNoteCommand,
    state?.workspaceProjectId,
  ]);

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
    setIsHistoryPanelOpen((current) => {
      const nextOpen = !current;
      if (!nextOpen) {
        setRecoveryPreview(null);
      }
      return nextOpen;
    });
  }, [commitSave]);

  const handleToggleRecoveryPreview = useCallback(
    (kind: "history" | "deleted", id: string) => {
      if (!id) {
        return;
      }
      setRecoveryPreview((current) =>
        current?.kind === kind && current.id === id ? null : { kind, id }
      );
    },
    []
  );

  const handleRestoreHistoryVersion = useCallback(
    (historyVersionId: string) => {
      if (!historyVersionId) {
        return;
      }
      setIsHistoryPanelOpen(false);
      setRecoveryPreview(null);
      runAfterSave(
        () => dispatchThreadNoteCommand("restoreHistoryVersion", { historyVersionId }),
        "restore the saved version"
      );
    },
    [dispatchThreadNoteCommand, runAfterSave]
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
      setIsHistoryPanelOpen(false);
      setRecoveryPreview(null);
      runAfterSave(
        () => dispatchThreadNoteCommand("restoreDeletedNote", { deletedNoteId }),
        "restore the deleted note"
      );
    },
    [dispatchThreadNoteCommand, runAfterSave]
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
      setIsRenamingTitle(false);
      setSelectorFilter("");
      setIsSelectorOpen(false);
      runAfterSave(
        () =>
          onDispatchCommand("selectNote", {
            ...(threadId ? { threadId } : {}),
            ownerKind: nextOwnerKind,
            ownerId: nextOwnerId,
            noteId: nextNoteId,
          }),
        "switch notes"
      );
    },
    [noteId, onDispatchCommand, ownerId, ownerKind, runAfterSave, threadId]
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

      const currentMarkdown = readCurrentThreadNoteMarkdown();
      const normalizedSelectedText = options?.selectedText?.trim() || "";
      const hasSelectedRange =
        typeof options?.from === "number" &&
        typeof options?.to === "number" &&
        options.to > options.from;
      const serializedSelectedMarkdown =
        draftMode === "organize" && hasSelectedRange
          ? serializeEditorMarkdownRange(editor, options?.from, options?.to)
          : "";
      const resolvedSelectedText =
        serializedSelectedMarkdown.trim() || normalizedSelectedText;
      const requestKind = resolvedSelectedText ? "selection" : "whole";
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
        selectedText: resolvedSelectedText || undefined,
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

  const handleAskAssistantAboutSelectionFromMenu = useCallback(() => {
    if (!noteContextMenu || noteContextMenu.sourceKind !== "selection") {
      return;
    }

    closeNoteContextMenu();
    dispatchSelectionAssistantCommand("openSelectionAssistantQuestionComposer", {
      selectedText: noteContextMenu.selectedText,
      from: noteContextMenu.from,
      to: noteContextMenu.to,
      anchorPoint: {
        x: noteContextMenu.x,
        y: noteContextMenu.y,
      },
    });
  }, [closeNoteContextMenu, dispatchSelectionAssistantCommand, noteContextMenu]);

  const handleOpenProjectNoteTransfer = useCallback(() => {
    if (
      !noteContextMenu ||
      noteContextMenu.sourceKind !== "selection" ||
      ownerKind !== "thread" ||
      !currentProjectTransferProjectId
    ) {
      return;
    }

    const selectedMarkdown = serializeMarkdownForRange(
      noteContextMenu.from,
      noteContextMenu.to
    );
    const selectedText = noteContextMenu.selectedText.trim();
    if (!selectedMarkdown && !selectedText) {
      return;
    }

    closeNoteContextMenu();
    dispatchThreadNoteCommand("cancelProjectNoteTransferPreview");
    setProjectNoteTransfer({
      selectedText: selectedText || selectedMarkdown,
      selectedMarkdown: selectedMarkdown || selectedText,
      from: noteContextMenu.from,
      to: noteContextMenu.to,
      targetProjectId: currentProjectTransferProjectId,
      targetNoteId: null,
      transferMode: "copy",
      step: "picker",
      isApplying: false,
    });
  }, [
    closeNoteContextMenu,
    currentProjectTransferProjectId,
    dispatchThreadNoteCommand,
    noteContextMenu,
    ownerKind,
    serializeMarkdownForRange,
  ]);

  const handleCloseProjectNoteTransfer = useCallback(() => {
    setProjectNoteTransfer(null);
    dispatchThreadNoteCommand("cancelProjectNoteTransferPreview");
  }, [dispatchThreadNoteCommand]);

  const handleBackToProjectTransferPicker = useCallback(() => {
    setProjectNoteTransfer((current) =>
      current
        ? {
            ...current,
            step: "picker",
            isApplying: false,
          }
        : current
    );
  }, []);

  const handleChooseProjectTransferTarget = useCallback(
    (targetNoteId: string) => {
      if (!projectNoteTransfer || !noteId) {
        return;
      }

      const sourceMarkdown = readCurrentThreadNoteMarkdown();
      const nextTransferState: ProjectNoteTransferState = {
        ...projectNoteTransfer,
        targetNoteId: targetNoteId,
        step: "preview",
        isApplying: false,
      };
      setProjectNoteTransfer(nextTransferState);
      dispatchThreadNoteCommand("requestProjectNoteTransferPreview", {
        noteId,
        text: sourceMarkdown,
        selectedText: nextTransferState.selectedMarkdown,
        sourceSelectionFrom: nextTransferState.from,
        sourceSelectionTo: nextTransferState.to,
        targetProjectId: nextTransferState.targetProjectId,
        targetNoteId: targetNoteId,
        sourceNoteTitle: state?.selectedNoteTitle?.trim() || undefined,
      });
    },
    [dispatchThreadNoteCommand, draftText, editor, noteId, projectNoteTransfer, state?.selectedNoteTitle]
  );

  const handleApplyProjectNoteTransfer = useCallback(
    (placementChoice: "suggested" | "end") => {
      if (!projectNoteTransfer || !projectNoteTransferPreview || !noteId) {
        return;
      }

      const payload: Record<string, unknown> = {
        noteId,
        transferMode: projectNoteTransfer.transferMode,
        placementChoice,
        sourceFingerprint: projectNoteTransferPreview.sourceFingerprint,
        targetFingerprint: projectNoteTransferPreview.targetFingerprint,
      };

      if (projectNoteTransfer.transferMode === "move") {
        payload.sourceTextAfterMove = buildMarkdownAfterDeletingRange(
          projectNoteTransfer.from,
          projectNoteTransfer.to
        );
      }

      setProjectNoteTransfer((current) =>
        current
          ? {
              ...current,
              isApplying: true,
            }
          : current
      );
      dispatchThreadNoteCommand("applyProjectNoteTransfer", payload);
    },
    [
      buildMarkdownAfterDeletingRange,
      dispatchThreadNoteCommand,
      noteId,
      projectNoteTransfer,
      projectNoteTransferPreview,
    ]
  );

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

  const handleIndentBlockFromMenu = useCallback(() => {
    if (
      !editor ||
      !noteContextMenu ||
      noteContextMenu.sourceKind !== "selection" ||
      !canIndentSelectionAsIndentedBlock(editor, noteContextMenu.from, noteContextMenu.to)
    ) {
      return;
    }

    closeNoteContextMenu();
    editor
      .chain()
      .focus()
      .setTextSelection({ from: noteContextMenu.from, to: noteContextMenu.to })
      .wrapIn("blockquote")
      .run();
    refreshSlashQuery(editor);
  }, [closeNoteContextMenu, editor, noteContextMenu, refreshSlashQuery]);

  const handleOutdentBlockFromMenu = useCallback(() => {
    if (
      !editor ||
      !noteContextMenu ||
      noteContextMenu.sourceKind !== "selection" ||
      !selectionTouchesNodeType(editor.state, noteContextMenu.from, noteContextMenu.to, "blockquote")
    ) {
      return;
    }

    closeNoteContextMenu();
    editor
      .chain()
      .focus()
      .setTextSelection({ from: noteContextMenu.from, to: noteContextMenu.to })
      .lift("blockquote")
      .run();
    refreshSlashQuery(editor);
  }, [closeNoteContextMenu, editor, noteContextMenu, refreshSlashQuery]);

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
      selectionPos:
        noteContextMenu.sourceKind === "selection"
          ? noteContextMenu.from
          : noteContextMenu.lineSelectionPos,
      insertAt: noteContextMenu.lineInsertAt,
      tag: noteContextMenu.lineTag,
      headingCollapsible: noteContextMenu.lineHeadingCollapsible,
      left: noteContextMenu.lineMenuLeft,
      top: noteContextMenu.lineMenuTop,
    });
  }, [closeNoteContextMenu, noteContextMenu]);

  const handleMakeSelectionCollapsibleFromMenu = useCallback(() => {
    if (!editor || !noteContextMenu || noteContextMenu.sourceKind !== "selection") {
      return;
    }

    const sectionDraft = resolveSelectionCollapsibleSectionDraft(
      editor,
      noteContextMenu.from,
      noteContextMenu.to
    );
    if (!sectionDraft) {
      return;
    }

    const nextMarkdown = buildMarkdownWithCollapsibleSectionReplacement(editor, sectionDraft);
    closeNoteContextMenu();

    const didSync = syncRichEditorMarkdown(editor, nextMarkdown, {
      refreshSelectionState: false,
    });
    if (!didSync) {
      return;
    }

    window.requestAnimationFrame(() => {
      const editorView = resolveEditorView(editor);
      if (!editorView) {
        const normalized = updateDraftTextLocally(
          normalizeThreadNoteStoredMarkdown(nextMarkdown)
        );
        commitSave(normalized, { force: true });
        refreshSlashQuery(editor);
        return;
      }

      if (sectionDraft.emptyBodyMarker) {
        const markerRange = findTextRangeInDocument(
          editorView.state.doc,
          sectionDraft.emptyBodyMarker
        );
        if (markerRange) {
          const tr = editorView.state.tr.deleteRange(markerRange.from, markerRange.to);
          tr.setSelection(TextSelection.create(tr.doc, markerRange.from));
          editorView.dispatch(tr.scrollIntoView());
          editorView.focus();
          const normalized = updateDraftTextLocally(
            normalizeThreadNoteStoredMarkdown(editor.getMarkdown())
          );
          commitSave(normalized, { force: true });
          refreshSlashQuery(editor);
          return;
        }
      }

      const targetSection = findClosestCollapsibleSectionByTitle(
        editor,
        sectionDraft.headingTitle,
        sectionDraft.replaceFrom
      );
      if (targetSection) {
        const firstBodyBlock = findFirstTopLevelBlockWithinSection(
          editor,
          targetSection.headingNodeEnd,
          targetSection.sectionEnd
        );
        const targetPos = firstBodyBlock
          ? Math.min(firstBodyBlock.pos + 1, editorView.state.doc.content.size)
          : Math.min(targetSection.headingNodeEnd, editorView.state.doc.content.size);
        const tr = editorView.state.tr.setSelection(
          Selection.near(editorView.state.doc.resolve(targetPos), 1)
        );
        editorView.dispatch(tr.scrollIntoView());
        editorView.focus();
        const normalized = updateDraftTextLocally(
          normalizeThreadNoteStoredMarkdown(editor.getMarkdown())
        );
        commitSave(normalized, { force: true });
        refreshSlashQuery(editor);
        return;
      }

      editor.commands.focus("end");
      const normalized = updateDraftTextLocally(
        normalizeThreadNoteStoredMarkdown(editor.getMarkdown())
      );
      commitSave(normalized, { force: true });
      refreshSlashQuery(editor);
    });
  }, [
    closeNoteContextMenu,
    commitSave,
    editor,
    noteContextMenu,
    refreshSlashQuery,
    syncRichEditorMarkdown,
    updateDraftTextLocally,
  ]);

  const handleToggleHeadingCollapsibleFromMenu = useCallback(() => {
    if (
      !editor ||
      !noteContextMenu ||
      typeof noteContextMenu.lineSelectionPos !== "number" ||
      !isHeadingLineTag(noteContextMenu.lineTag) ||
      noteContextMenu.lineHeadingCollapsible !== true
    ) {
      return;
    }

    const didUpdate = updateHeadingCollapsibleAtSelection(
      resolveEditorView(editor),
      noteContextMenu.lineSelectionPos,
      false
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

  const handleSetNoteEditorSurfaceMode = useCallback(
    (mode: "rich" | "markdown") => {
      const activeSurfaceMode: "rich" | "markdown" = isRawMarkdownMode ? "markdown" : "rich";
      if (mode === activeSurfaceMode) {
        return;
      }

      const nextMarkdown = normalizeLineEndings(
        isRichEditorMode && editor ? editor.getMarkdown() : latestDraftTextRef.current
      );
      const previousMarkdown = normalizeLineEndings(latestDraftTextRef.current);
      setDraftText(nextMarkdown);
      latestDraftTextRef.current = nextMarkdown;
      if (nextMarkdown !== previousMarkdown) {
        const nextRevision = draftRevisionRef.current + 1;
        draftRevisionRef.current = nextRevision;
        setHasLocalDirtyChanges(true);
        hasLocalDirtyChangesRef.current = true;
        dispatchDraftUpdate(nextMarkdown, nextRevision);
      }

      setSelectedImage(null);
      setIsInTable(false);
      setSlashQuery(null);
      setMermaidEditingContext(null);
      setMermaidPicker(null);
      setHeadingTagEditor(null);
      setNoteLinkPicker(null);
      setNoteLinkSearch("");
      closeNoteContextMenu();
      hideSelectionAssistantActions();
      setNoteEditorSurfaceMode(mode);
      if (mode === "rich") {
        setForcedNoteEditorSurfaceMode(null);
        setEditorLoadNotice(null);
      }

      if (mode === "markdown") {
        const fallback = nextMarkdown.length;
        setNoteSelection(null);
        focusRawMarkdownEditor({ start: fallback, end: fallback });
        return;
      }

      if (editor) {
        const synced = syncRichEditorMarkdown(editor, nextMarkdown, {
          fallbackMessage:
            "This note stayed in Markdown because rich view could not load it safely.",
        });
        if (!synced) {
          return;
        }
        window.requestAnimationFrame(() => {
          editor.chain().focus("end").run();
          refreshSlashQuery(editor);
        });
      }
    },
    [
      closeNoteContextMenu,
      editor,
      focusRawMarkdownEditor,
      hideSelectionAssistantActions,
      dispatchDraftUpdate,
      isRawMarkdownMode,
      isRichEditorMode,
      refreshSlashQuery,
      syncRichEditorMarkdown,
    ]
  );

  const updateSelectedImageNode = useCallback(
    (patch: Partial<SelectedImageState>) => {
      if (!editor || !selectedImage) {
        return;
      }

      const nextWidth = (() => {
        if (patch.width === undefined) {
          return selectedImage.width;
        }
        if (patch.width === null) {
          return null;
        }
        if (!Number.isFinite(patch.width)) {
          return selectedImage.width;
        }
        return Math.max(160, Math.round(patch.width));
      })();
      const nextImage: SelectedImageState = {
        alt: patch.alt ?? selectedImage.alt,
        title: patch.title ?? selectedImage.title,
        width: nextWidth,
      };

      setSelectedImage(nextImage);
      editor.commands.updateAttributes("threadNoteImage", nextImage);
      commitEditorMarkdown(normalizeLineEndings(editor.getMarkdown()));
    },
    [commitEditorMarkdown, editor, selectedImage]
  );

  const handleRemoveSelectedImage = useCallback(() => {
    if (!editor || !selectedImage) {
      return;
    }

    editor.commands.deleteSelection();
    setSelectedImage(null);
    commitEditorMarkdown(normalizeLineEndings(editor.getMarkdown()));
  }, [commitEditorMarkdown, editor, selectedImage]);

  const insertUploadedImages = useCallback(
    (
      results: ThreadNoteImageUploadResult[],
      files: readonly File[],
      range?: PendingImagePickerInsert | null
    ) => {
      const successfulUploads = results
        .map((result, index) => ({
          result,
          file: files[index] ?? null,
        }))
        .filter(
          (item): item is { result: ThreadNoteImageUploadResult; file: File | null } =>
            item.result.ok && Boolean(item.result.url)
        );

      console.info(
        "[thread-note image] upload results",
        results.map((r) => ({ ok: r.ok, url: r.url, message: r.message, relativePath: r.relativePath }))
      );
      const failedResult = results.find((result) => !result.ok);
      if (failedResult) {
        showImageNotice(
          failedResult.message ??
            "Open Assist could not save the image (no details were returned from the native bridge)."
        );
        console.error("[thread-note image] upload returned failure", failedResult);
      }
      if (!successfulUploads.length) {
        if (!failedResult) {
          showImageNotice("Upload finished but no image URL was returned.");
          console.error("[thread-note image] all uploads ok but no urls", results);
        }
        return;
      }

      if (isRichEditorMode && !editor) {
        showImageNotice("The rich editor is not ready yet. Try again in a moment.");
        console.error("[thread-note image] rich editor unavailable at insert time");
        return;
      }

      if (isRichEditorMode && editor) {
        const imagesToInsert = successfulUploads.map(({ result, file }) => ({
          src: result.url!,
          alt: preferredThreadNoteImageAlt(file?.name),
          title: "",
        }));
        console.info("[thread-note image] inserting into rich editor", {
          from: range?.from ?? editor.state.selection.from,
          to: range?.to ?? editor.state.selection.to,
          images: imagesToInsert,
        });
        insertThreadNoteImages(editor, {
          from: range?.from ?? editor.state.selection.from,
          to: range?.to ?? editor.state.selection.to,
          images: imagesToInsert,
        });
        const nextMarkdown = normalizeLineEndings(editor.getMarkdown());
        console.info("[thread-note image] post-insert markdown length", nextMarkdown.length);
        commitEditorMarkdown(nextMarkdown);
        refreshSlashQuery(editor);
        return;
      }

      const markdownImages = successfulUploads
        .map(({ result, file }) =>
          buildThreadNoteMarkdownImage({
            src: result.url!,
            alt: preferredThreadNoteImageAlt(file?.name),
            title: "",
          })
        )
        .join("\n\n");
      const insertion = `\n\n${markdownImages}\n\n`;
      replaceRawMarkdownSelection(range ?? resolveCurrentRawMarkdownRange(), insertion);
    },
    [
      commitEditorMarkdown,
      editor,
      isRichEditorMode,
      refreshSlashQuery,
      replaceRawMarkdownSelection,
      resolveCurrentRawMarkdownRange,
      showImageNotice,
    ]
  );

  const handleInsertImagesFromPicker = useCallback(
    async (files: readonly File[]) => {
      const targetRange = pendingImagePickerInsertRef.current;
      pendingImagePickerInsertRef.current = null;

      try {
        const results = await requestThreadNoteImageUploads(files);
        if (!results.length) {
          showImageNotice("No images were returned from the picker.");
          return;
        }
        insertUploadedImages(results, files, targetRange);
      } catch (error) {
        console.error("[thread-note image picker] upload failed", error);
        showImageNotice(
          error instanceof Error
            ? `Image upload failed: ${error.message}`
            : "Image upload failed. See the Web Inspector console for details."
        );
      }
    },
    [insertUploadedImages, requestThreadNoteImageUploads, showImageNotice]
  );

  const handleImageInputChange = useCallback(
    (event: React.ChangeEvent<HTMLInputElement>) => {
      const files = Array.from(event.currentTarget.files ?? []);
      event.currentTarget.value = "";
      if (!files.length) {
        showImageNotice("No file was selected.");
        return;
      }

      void handleInsertImagesFromPicker(files);
    },
    [handleInsertImagesFromPicker, showImageNotice]
  );

  const handleRawMarkdownChange = useCallback(
    (event: React.ChangeEvent<HTMLTextAreaElement>) => {
      const normalized = updateDraftTextLocally(event.target.value);
      refreshRawMarkdownSlashQuery(event.currentTarget, normalized);
    },
    [refreshRawMarkdownSlashQuery, updateDraftTextLocally]
  );

  const handleRawMarkdownSelect = useCallback(
    (event: React.SyntheticEvent<HTMLTextAreaElement>) => {
      refreshRawMarkdownSlashQuery(event.currentTarget);
    },
    [refreshRawMarkdownSlashQuery]
  );

  const handleRawMarkdownPaste = useCallback(
    (event: React.ClipboardEvent<HTMLTextAreaElement>) => {
      const clipboardData = event.clipboardData;
      if (!clipboardData) {
        return;
      }

      const imageFiles = extractThreadNoteImageFiles(clipboardData.items, clipboardData.files);
      if (!imageFiles.length) {
        if (!shouldAttemptNativeThreadNoteClipboardImagePaste(clipboardData)) {
          return;
        }

        event.preventDefault();
        const range = {
          from: event.currentTarget.selectionStart ?? 0,
          to: event.currentTarget.selectionEnd ?? event.currentTarget.selectionStart ?? 0,
        };
        void requestThreadNoteClipboardImageAsset().then((result) => {
          insertUploadedImages(result.ok ? [result] : [result], [], range);
        });
        return;
      }

      event.preventDefault();
      const range = {
        from: event.currentTarget.selectionStart ?? 0,
        to: event.currentTarget.selectionEnd ?? event.currentTarget.selectionStart ?? 0,
      };
      void requestThreadNoteImageUploads(imageFiles).then((results) => {
        insertUploadedImages(results, imageFiles, range);
      });
    },
    [
      insertUploadedImages,
      requestThreadNoteClipboardImageAsset,
      requestThreadNoteImageUploads,
    ]
  );

  const handleRawMarkdownKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
      const activeMermaidPicker = mermaidPickerStateRef.current;
      const activeMermaidItems = mermaidPickerItems;
      if (activeMermaidPicker && activeMermaidItems.length > 0) {
        if (event.key === "ArrowDown") {
          event.preventDefault();
          setSelectedMermaidIndex((current) => (current + 1) % activeMermaidItems.length);
          return;
        }

        if (event.key === "ArrowUp") {
          event.preventDefault();
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
          if ("template" in selectedMermaidItem) {
            applyMermaidTemplate(selectedMermaidItem.template);
          } else {
            openMermaidTemplateType(selectedMermaidItem.type);
          }
          return;
        }

        if (event.key === "Escape") {
          event.preventDefault();
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
          focusRawMarkdownEditor();
          return;
        }
      }

      const activeSlashQuery = slashQueryRef.current;
      const activeCommands = filteredCommandsRef.current;
      if (activeSlashQuery && activeCommands.length > 0) {
        if (event.key === "ArrowDown") {
          event.preventDefault();
          setSelectedSlashIndex((current) => (current + 1) % activeCommands.length);
          return;
        }

        if (event.key === "ArrowUp") {
          event.preventDefault();
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
          applySlashCommand(selectedCommand);
          return;
        }
      }

      if (event.key === "Escape" && slashQueryRef.current) {
        event.preventDefault();
        setSlashQuery(null);
      }
    },
    [
      applyMermaidTemplate,
      applySlashCommand,
      focusRawMarkdownEditor,
      mermaidPickerItems,
      openMermaidTemplateType,
    ]
  );

  const handleRawMarkdownBlur = useCallback(
    (event: React.FocusEvent<HTMLTextAreaElement>) => {
      refreshRawMarkdownSlashQuery(event.currentTarget);
      if (!isExternalMarkdownFile) {
        commitSave(event.currentTarget.value);
      }
      window.requestAnimationFrame(() => {
        const activeElement = document.activeElement;
        const focusInsideFloatingLayer = Boolean(
          activeElement && floatingLayerRef.current?.contains(activeElement)
        );

        if (focusInsideFloatingLayer) {
          return;
        }

        setSlashQuery(null);
        setMermaidPicker(null);
      });
    },
    [commitSave, isExternalMarkdownFile, refreshRawMarkdownSlashQuery]
  );

  const handleApplyOrganizeAIDraft = useCallback(
    (applyMode: "replace" | "insertAbove" | "insertBelow" | "replaceNote" | "insertTop" | "insertBottom") => {
      if (!aiDraftPreview || aiDraftPreview.isError || aiDraftPreview.mode !== "organize") {
        closeAIDraftPreview();
        return;
      }

      const previewMarkdown = normalizeLineEndings(aiDraftPreview.markdown);
      const currentMarkdown = readCurrentThreadNoteMarkdown();
      const selectionSnapshot =
        noteSelection?.selectedMarkdown && noteSelection?.snapshotMarkdown
          ? {
              selectedMarkdown: noteSelection.selectedMarkdown,
              snapshotMarkdown: noteSelection.snapshotMarkdown,
            }
          : null;

      if (selectionSnapshot && applyMode === "replace") {
        const replaced = replaceSelectionInMarkdown(currentMarkdown, selectionSnapshot, previewMarkdown);
        if (replaced !== null) {
          commitEditorMarkdown(replaced);
          closeAIDraftPreview("applyAIDraftPreview");
          return;
        }
      }

      if (selectionSnapshot && applyMode === "insertAbove") {
        const inserted = insertMarkdownAboveSelection(currentMarkdown, selectionSnapshot, previewMarkdown);
        if (inserted !== null) {
          commitEditorMarkdown(inserted);
          closeAIDraftPreview("applyAIDraftPreview");
          return;
        }
      }

      if (selectionSnapshot && applyMode === "insertBelow") {
        const inserted = insertMarkdownBelowSelection(currentMarkdown, selectionSnapshot, previewMarkdown);
        if (inserted !== null) {
          commitEditorMarkdown(inserted);
          closeAIDraftPreview("applyAIDraftPreview");
          return;
        }
      }

      const mergedMarkdown =
        applyMode === "replaceNote"
          ? previewMarkdown
          : applyMode === "insertTop"
            ? prependMarkdownToNote(currentMarkdown, previewMarkdown)
            : appendMarkdownToNote(currentMarkdown, previewMarkdown);

      commitEditorMarkdown(mergedMarkdown);
      closeAIDraftPreview("applyAIDraftPreview");
    },
    [aiDraftPreview, closeAIDraftPreview, commitEditorMarkdown, noteSelection, readCurrentThreadNoteMarkdown]
  );

  const handleAddChartDraftToNote = useCallback(
    (applyMode: "appendBottom" | "insertBelowSelection" = "appendBottom") => {
      if (!aiDraftPreview || aiDraftPreview.isError || aiDraftPreview.mode !== "chart") {
        closeAIDraftPreview();
        return;
      }

      const draftMarkdown = normalizeLineEndings(
        sanitizeMermaidMarkdownBlocks(aiDraftPreview.markdown)
      ).trim();
      const currentMarkdown = readCurrentThreadNoteMarkdown();
      const selectionSnapshot =
        noteSelection?.selectedMarkdown && noteSelection?.snapshotMarkdown
          ? {
              selectedMarkdown: noteSelection.selectedMarkdown,
              snapshotMarkdown: noteSelection.snapshotMarkdown,
            }
          : null;

      if (applyMode === "insertBelowSelection" && selectionSnapshot) {
        const inserted = insertMarkdownBelowSelection(currentMarkdown, selectionSnapshot, draftMarkdown);
        if (inserted !== null) {
          commitEditorMarkdown(inserted);
          closeAIDraftPreview("applyAIDraftPreview");
          return;
        }
      }

      commitEditorMarkdown(appendMarkdownToNote(currentMarkdown, draftMarkdown));
      closeAIDraftPreview("applyAIDraftPreview");
    },
    [aiDraftPreview, closeAIDraftPreview, commitEditorMarkdown, noteSelection, readCurrentThreadNoteMarkdown]
  );

  const handleRegenerateChartDraft = useCallback(() => {
    const normalizedInstruction = buildChartStyleInstruction(
      selectedChartType,
      chartStyleInstruction
    );
    if (!aiDraftPreview || aiDraftPreview.mode !== "chart" || !noteId) {
      return;
    }

    dispatchThreadNoteCommand("regenerateAIDraftPreview", {
      noteId,
      draftMode: "chart",
      styleInstruction: normalizedInstruction,
      currentDraftMarkdown:
        sanitizeMermaidMarkdownBlocks(aiDraftPreview.markdown) || undefined,
    });
  }, [
    aiDraftPreview,
    chartStyleInstruction,
    dispatchThreadNoteCommand,
    noteId,
    selectedChartType,
  ]);

  const handleRepairChartDraft = useCallback(() => {
    const normalizedInstruction = buildChartStyleInstruction(
      selectedChartType,
      chartStyleInstruction
    );
    if (
      !chartRenderError ||
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
      currentDraftMarkdown:
        sanitizeMermaidMarkdownBlocks(aiDraftPreview.markdown) || undefined,
      renderError: chartRenderError,
    });
  }, [
    aiDraftPreview,
    chartRenderError,
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
  const batchOrganizerSelectedSourceNotes = useMemo(
    () =>
      batchOrganizerSelectedSourceKeys
        .map((selectionKey) => {
          const payload = batchSourceSelectionPayload(selectionKey);
          if (!payload) {
            return null;
          }
          return (
            notes.find(
              (note) =>
                note.ownerKind === payload.ownerKind &&
                note.ownerId === payload.ownerId &&
                note.id === payload.noteId
            ) ?? null
          );
        })
        .filter((note): note is NonNullable<typeof note> => Boolean(note)),
    [batchOrganizerSelectedSourceKeys, notes]
  );
  const batchOrganizerSourceNotes = batchNotePlanPreview?.sourceNotes ?? [];
  const batchOrganizerSourcePreview = useMemo(
    () =>
      batchOrganizerSourcePreviewKey
        ? batchOrganizerSourceNotes.find(
            (sourceNote) =>
              batchSourceSelectionKeyForSourceNote(sourceNote) === batchOrganizerSourcePreviewKey
          ) ?? null
        : batchOrganizerSourceNotes[0] ?? null,
    [batchOrganizerSourceNotes, batchOrganizerSourcePreviewKey]
  );
  const batchOrganizerEditableNoteByTempId = useMemo(
    () =>
      new Map(
        batchOrganizerEditableNotes.map((note) => [note.tempId.toLowerCase(), note] as const)
      ),
    [batchOrganizerEditableNotes]
  );
  const batchOrganizerActiveNote = useMemo(
    () =>
      batchOrganizerActiveNoteTempId
        ? batchOrganizerEditableNotes.find((note) => note.tempId === batchOrganizerActiveNoteTempId) ??
          batchOrganizerEditableNotes[0] ??
          null
        : batchOrganizerEditableNotes[0] ?? null,
    [batchOrganizerActiveNoteTempId, batchOrganizerEditableNotes]
  );
  const batchOrganizerLinkRows = useMemo(
    () =>
      batchOrganizerEditableLinks.map((link) => {
        const fromNote = batchOrganizerEditableNoteByTempId.get(link.fromTempId.toLowerCase()) ?? null;
        const toNote =
          link.toTarget.kind === "proposed" && link.toTarget.tempId
            ? batchOrganizerEditableNoteByTempId.get(link.toTarget.tempId.toLowerCase()) ?? null
            : null;
        const toLabel = toNote ? normalizeThreadNoteTitle(toNote.title) : batchResolvedTargetLabel(link.toTarget);
        const isVisible = Boolean(fromNote?.accepted) && (link.toTarget.kind !== "proposed" || Boolean(toNote?.accepted));
        return {
          ...link,
          linkKey: batchPlanEditableLinkKey(link),
          fromTitle: fromNote ? normalizeThreadNoteTitle(fromNote.title) : "Generated note",
          toTitle: toLabel,
          isVisible,
        };
      }),
    [batchOrganizerEditableLinks, batchOrganizerEditableNoteByTempId]
  );
  const batchOrganizerGraph = useMemo(
    () =>
      buildBatchNotePlanPreviewGraph(
        batchOrganizerSourceNotes,
        batchOrganizerEditableNotes,
        batchOrganizerEditableLinks
      ),
    [batchOrganizerEditableLinks, batchOrganizerEditableNotes, batchOrganizerSourceNotes]
  );
  const batchOrganizerAcceptedMasterCount = batchOrganizerEditableNotes.filter(
    (note) => note.accepted && note.noteType === "master"
  ).length;
  const batchOrganizerWarnings = batchNotePlanPreview?.warnings ?? [];
  const batchOrganizerStep =
    batchNotePlanPreview || isBatchNotePlanBusy ? "preview" : "select";
  const canRequestBatchPlanPreview =
    Boolean(state?.workspaceProjectId) &&
    batchOrganizerSelectedSourceKeys.length > 0 &&
    !isBatchNotePlanBusy;
  const canApplyBatchPlan =
    Boolean(batchNotePlanPreview) &&
    !batchNotePlanPreview?.isError &&
    !isBatchNotePlanBusy &&
    !batchOrganizerIsApplying &&
    batchOrganizerEditableNotes.some((note) => note.accepted) &&
    batchOrganizerAcceptedMasterCount === 1;
  const projectNoteTransferTargets = useMemo(
    () =>
      currentProjectTransferProjectId
        ? notes.filter(
            (note) =>
              note.ownerKind === "project" &&
              note.ownerId === currentProjectTransferProjectId
          )
        : [],
    [currentProjectTransferProjectId, notes]
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
  const isAIDraftBusy = !isExternalMarkdownFile && Boolean(state?.isGeneratingAIDraft);
  const selectedChartChoice =
    CHART_TYPE_CHOICES.find((option) => option.type === selectedChartType) ??
    CHART_TYPE_CHOICES[0];
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
    !isExternalMarkdownFile &&
    (isNotesWorkspace || outgoingLinks.length > 0 || backlinks.length > 0 || Boolean(graph));
  const backButtonLabel = state?.previousLinkedNoteTitle?.trim() || "Back";
  const canCreateNote = !isExternalMarkdownFile && (state?.canCreateNote ?? true);
  const workspaceProjectTitle = state?.workspaceProjectTitle?.trim() || "Notes";
  const workspaceOwnerSubtitle = state?.workspaceOwnerSubtitle?.trim() || "";
  const owningThreadId = state?.owningThreadId ?? null;
  const owningThreadTitle = state?.owningThreadTitle?.trim() || "Open thread";
  const noteKindLabel = isExternalMarkdownFile
    ? "Markdown file"
    : currentSourceLabel === "Project notes"
      ? "Project note"
      : "Thread note";
  const noteContextPrefix = isExternalMarkdownFile
    ? "Markdown file"
    : isNotesWorkspace
      ? "Notes"
      : currentSourceLabel;
  const noteContextLabel = isExternalMarkdownFile
    ? sourceDescriptor?.fileName?.trim() || state?.selectedNoteTitle?.trim() || "Markdown file"
    : (isNotesWorkspace ? workspaceProjectTitle : state?.ownerTitle?.trim()) || currentSourceLabel;
  const linkedNotesCount = outgoingLinks.length + backlinks.length;
  const relatedNotePreviewLabels = Array.from(
    new Set(
      [...outgoingLinks, ...backlinks]
        .map((item) => normalizeThreadNoteTitle(item.title).trim())
        .filter(Boolean)
    )
  ).slice(0, 3);
  const relatedNotePreviewText = relatedNotePreviewLabels.length
    ? relatedNotePreviewLabels.join(" • ")
    : graph
      ? "View the local note graph"
      : "No linked notes yet";
  const canRequestSummary =
    !isExternalMarkdownFile && hasAnyNotes && Boolean(draftText.trim() || noteSelection?.text?.trim());
  const canSaveCurrentDocument = isExternalMarkdownFile
    ? Boolean(sourceDescriptor?.canSave)
    : Boolean(state?.canEdit);
  const canUseNoteOnlyActions = !isExternalMarkdownFile && hasAnyNotes;
  const selectedProjectTransferTarget =
    projectNoteTransfer?.targetNoteId
      ? projectNoteTransferTargets.find(
          (note) => note.id === projectNoteTransfer.targetNoteId
        ) ?? null
      : null;
  const projectTransferSuggestionLabel = projectNoteTransferPreview?.fallbackToEnd
    ? "Add at end"
    : projectNoteTransferPreview?.suggestedHeadingPath.length
      ? projectNoteTransferPreview.suggestedHeadingPath.join(" / ")
      : "Suggested section";
  const canApplyProjectTransferSuggestion = Boolean(
    projectNoteTransferPreview &&
      !projectNoteTransferPreview.isError &&
      !projectNoteTransferPreview.fallbackToEnd &&
      projectNoteTransferPreview.suggestedHeadingPath.length > 0
  );
  const handleOpenNoteLinkPicker = useCallback(() => {
    if (!noteContextMenu) {
      const activeRange =
        isRichEditorMode && editor
          ? {
              from: editor.state.selection.from,
              to: editor.state.selection.to,
            }
          : resolveCurrentRawMarkdownRange();
      const selectedLabel =
        noteSelection?.text?.trim() ??
        latestDraftTextRef.current.slice(activeRange.from, activeRange.to).trim();
      setNoteLinkSearch("");
      setNoteLinkPicker({
        mode: selectedLabel ? "wrapSelection" : "insertInline",
        selectedLabel,
        from: selectedLabel ? activeRange.from : undefined,
        to: selectedLabel ? activeRange.to : undefined,
        insertAt: selectedLabel ? activeRange.from : activeRange.to,
      });
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
  }, [
    closeNoteContextMenu,
    editor,
    isRichEditorMode,
    noteContextMenu,
    noteSelection?.text,
    resolveCurrentRawMarkdownRange,
  ]);
  const handleInsertNoteLink = useCallback(
    (targetNote: (typeof notes)[number]) => {
      if (!noteLinkPicker) {
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

      if (isRichEditorMode) {
        if (!editor) {
          return;
        }

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
        return;
      }

      const nextMarkdown = replaceMarkdownRange(
        readCurrentThreadNoteMarkdown(),
        {
          from:
            noteLinkPicker.mode === "wrapSelection" &&
            typeof noteLinkPicker.from === "number"
              ? noteLinkPicker.from
              : noteLinkPicker.insertAt,
          to:
            noteLinkPicker.mode === "wrapSelection" &&
            typeof noteLinkPicker.to === "number"
              ? noteLinkPicker.to
              : noteLinkPicker.insertAt,
        },
        noteLinkPicker.mode === "wrapSelection" ? markdownLink : `${markdownLink} `
      );
      commitEditorMarkdown(nextMarkdown);
      focusRawMarkdownEditor();

      setNoteLinkPicker(null);
      setNoteLinkSearch("");
    },
    [
      commitEditorMarkdown,
      editor,
      focusRawMarkdownEditor,
      isRichEditorMode,
      noteLinkPicker,
      notes,
      readCurrentThreadNoteMarkdown,
      resolveCurrentRawMarkdownRange,
      refreshSlashQuery,
    ]
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
    runAfterSave(() => dispatchThreadNoteCommand("goBackLinkedNote"), "go back");
  }, [dispatchThreadNoteCommand, runAfterSave]);
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
  const handleManualSave = useCallback(() => {
    commitSave(undefined, { force: true });
  }, [commitSave]);
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
  const currentHeadingAlignment =
    headingTagEditor && editor && isHeadingLineTag(headingTagEditor.tag)
      ? resolveHeadingAlignmentAtSelection(editor.state, headingTagEditor.selectionPos)
      : "left";
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
  const canTransferSelectionToProjectNote = Boolean(
    noteContextMenu?.sourceKind === "selection" &&
      ownerKind === "thread" &&
      currentProjectTransferProjectId
  );
  const canIndentBlockFromMenu = Boolean(
    editor &&
      noteContextMenu?.sourceKind === "selection" &&
      canIndentSelectionAsIndentedBlock(editor, noteContextMenu.from, noteContextMenu.to)
  );
  const canOutdentBlockFromMenu = Boolean(
    editor &&
      noteContextMenu?.sourceKind === "selection" &&
      selectionTouchesNodeType(editor.state, noteContextMenu.from, noteContextMenu.to, "blockquote")
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
    shouldShowSummaryAction ||
    linkNotice ||
    imageNotice ||
    screenshotNotice ||
    isUploadingImage ||
    isCapturingScreenshot ? (
      <div
        className={[
          "thread-note-utility-actions",
          isFullScreenWorkspace ? "is-inline-utility" : "",
        ]
          .filter(Boolean)
          .join(" ")}
      >
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
        {linkNotice ? <span className="thread-note-link-notice">{linkNotice}</span> : null}
        {editorLoadNotice ? (
          <span className="thread-note-link-notice">{editorLoadNotice}</span>
        ) : null}
        {saveStatus.kind === "error" ? (
          <span
            className="thread-note-link-notice thread-note-save-error"
            role="status"
          >
            {saveStatus.message}
          </span>
        ) : null}
        {saveStatus.kind === "saving" ? (
          <span className="thread-note-link-notice">Saving...</span>
        ) : null}
        {imageNotice ? <span className="thread-note-link-notice">{imageNotice}</span> : null}
        {screenshotNotice ? (
          <span className="thread-note-link-notice">{screenshotNotice}</span>
        ) : null}
        {isUploadingImage ? (
          <span className="thread-note-link-notice">Saving image...</span>
        ) : null}
        {isCapturingScreenshot ? (
          <span className="thread-note-link-notice">Waiting for screenshot selection...</span>
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
            <span className="thread-note-links-toggle-meta">{relatedNotePreviewText}</span>
          </span>
          <span className="thread-note-links-toggle-side">
            {linkedNotesCount > 0 ? (
              <span className="thread-note-links-toggle-count">{linkedNotesCount}</span>
            ) : null}
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
                    {recoveryPreview?.kind === "history" && recoveryPreview.id === item.id ? (
                      <div className="thread-note-recovery-preview">
                        <div className="thread-note-recovery-preview-header">
                          <span>Preview before restore</span>
                          <span>{item.savedAtLabel}</span>
                        </div>
                        <div className="assistant-markdown-shell oa-markdown-surface thread-note-recovery-preview-surface">
                          <MarkdownContent
                            markdown={item.markdown || item.preview}
                            mermaidDisplayMode="noteCompact"
                            onMermaidRenderErrorChange={setChartRenderError}
                          />
                        </div>
                      </div>
                    ) : null}
                  </div>
                  <div className="thread-note-recovery-actions">
                    <button
                      type="button"
                      className="thread-note-recovery-action"
                      onClick={() => handleToggleRecoveryPreview("history", item.id)}
                    >
                      {recoveryPreview?.kind === "history" && recoveryPreview.id === item.id
                        ? "Hide Preview"
                        : "Preview"}
                    </button>
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
                    {recoveryPreview?.kind === "deleted" && recoveryPreview.id === item.id ? (
                      <div className="thread-note-recovery-preview">
                        <div className="thread-note-recovery-preview-header">
                          <span>Preview before restore</span>
                          <span>{item.deletedAtLabel}</span>
                        </div>
                        <div className="assistant-markdown-shell oa-markdown-surface thread-note-recovery-preview-surface">
                          <MarkdownContent
                            markdown={item.markdown || item.preview}
                            mermaidDisplayMode="noteCompact"
                            onMermaidRenderErrorChange={setChartRenderError}
                          />
                        </div>
                      </div>
                    ) : null}
                  </div>
                  <div className="thread-note-recovery-actions">
                    <button
                      type="button"
                      className="thread-note-recovery-action"
                      onClick={() => handleToggleRecoveryPreview("deleted", item.id)}
                    >
                      {recoveryPreview?.kind === "deleted" && recoveryPreview.id === item.id
                        ? "Hide Preview"
                        : "Preview"}
                    </button>
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
          {isFullScreenWorkspace ? (
            <div className="thread-note-document-meta-row">
              <div className="thread-note-document-path">
                <span>{noteContextPrefix}</span>
                <span>{noteContextLabel}</span>
              </div>
              <div className="thread-note-document-meta-side">
                {statusLabel ? (
                  <span className="thread-note-document-status">{statusLabel}</span>
                ) : null}
                <button
                  type="button"
                  className="thread-note-document-meta-button"
                  onClick={handleToggleHistoryPanel}
                  disabled={!hasRecoveryItems}
                >
                  History
                </button>
              </div>
            </div>
          ) : null}
          <div className="thread-note-workspace-row">
            <div className="thread-note-header-copy">
              <span className="thread-note-eyebrow">{noteKindLabel}</span>
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
                    <span>{workspaceOwnerSubtitle || currentSourceLabel}</span>
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
                          <span>{noteSourceSectionLabel(section.source)}</span>
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
	                {isNotesWorkspace && !isExternalMarkdownFile && owningThreadId ? (
	                  <button
	                    type="button"
	                    className="thread-note-icon-button"
	                    onClick={() =>
	                      runAfterSave(
	                        () =>
	                          dispatchThreadNoteCommand("openOwningThread", {
	                            threadId: owningThreadId,
	                            ownerKind: "thread",
	                            ownerId: owningThreadId,
	                          }),
	                        "open the owning thread"
	                      )
	                    }
                    aria-label={`Open ${owningThreadTitle}`}
                    title={`Open ${owningThreadTitle}`}
                  >
                    <ArrowJumpIcon />
                  </button>
                ) : null}
                {isNotesWorkspace ? (
                  <button
                    type="button"
                    className="thread-note-icon-button"
                    onClick={() => dispatchThreadNoteCommand("openMarkdownFile")}
                    aria-label="Open Markdown file"
                    title="Open Markdown file"
                  >
                    <span aria-hidden="true">#</span>
                  </button>
                ) : null}
                {canUseNoteOnlyActions ? (
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
                {!isExternalMarkdownFile ? (
                <button
                  type="button"
                  className={[
                    "thread-note-icon-button",
                    screenshotImportState ? "is-active" : "",
                    screenshotCaptureMode !== "area" ? "has-secondary-mode" : "",
                  ]
                    .filter(Boolean)
                    .join(" ")}
                  onClick={() => {
                    void handleOpenScreenshotImport();
                  }}
                  onContextMenu={handleOpenScreenshotCaptureMenu}
                  disabled={isCapturingScreenshot || screenshotImportState?.isProcessing}
                  aria-label="Import screenshot"
                  title={`Import screenshot (${activeScreenshotCaptureModeOption.label}). Right-click to change mode.`}
                >
                  <ScreenshotIcon />
                </button>
                ) : null}
                {screenshotCaptureMenuPosition ? (
                  <div
                    ref={screenshotCaptureMenuRef}
                    className="thread-note-screenshot-capture-menu"
                    role="menu"
                    aria-label="Screenshot capture mode"
                    style={
                      {
                        "--thread-note-screenshot-menu-x": `${screenshotCaptureMenuPosition.x}px`,
                        "--thread-note-screenshot-menu-y": `${screenshotCaptureMenuPosition.y}px`,
                      } as CSSProperties
                    }
                  >
                    {THREAD_NOTE_SCREENSHOT_CAPTURE_MODE_OPTIONS.map((option) => (
                      <button
                        key={option.value}
                        type="button"
                        role="menuitemradio"
                        aria-checked={screenshotCaptureMode === option.value}
                        className={[
                          "thread-note-screenshot-capture-menu-item",
                          screenshotCaptureMode === option.value ? "is-active" : "",
                        ]
                          .filter(Boolean)
                          .join(" ")}
                        onClick={() => {
                          void handleSelectScreenshotCaptureMode(option.value);
                        }}
                      >
                        <span>{option.label}</span>
                        {screenshotCaptureMode === option.value ? (
                          <span className="thread-note-screenshot-capture-menu-check">Current</span>
                        ) : null}
                      </button>
                    ))}
                  </div>
                ) : null}
                {hasAnyNotes ? (
                  <div className="thread-note-toolbar-switch" role="group" aria-label="Editor mode">
                    <button
                      type="button"
                      className={[
                        "thread-note-toolbar-switch-button",
                        !isRawMarkdownMode ? "is-active" : "",
                      ]
                        .filter(Boolean)
                        .join(" ")}
                      onClick={() => handleSetNoteEditorSurfaceMode("rich")}
                      disabled={!state?.canEdit}
                      title="Use the normal rich editor"
                    >
                      Rich
                    </button>
                    <button
                      type="button"
                      className={[
                        "thread-note-toolbar-switch-button",
                        isRawMarkdownMode ? "is-active" : "",
                      ]
                        .filter(Boolean)
                        .join(" ")}
                      onClick={() => handleSetNoteEditorSurfaceMode("markdown")}
                      disabled={!state?.canEdit}
                      title="Edit the exact saved markdown"
                    >
                      Markdown
                    </button>
                  </div>
                ) : null}
                {(hasAnyNotes || isExternalMarkdownFile) ? (
                  <button
                    type="button"
                    className="thread-note-icon-button"
                    onClick={handleManualSave}
                    disabled={!canSaveCurrentDocument}
                    aria-label={isExternalMarkdownFile ? "Save Markdown file" : "Save note"}
                    title={`${isExternalMarkdownFile ? "Save Markdown file" : "Save note"} (\u2318S)`}
                  >
                    <SaveIcon />
                  </button>
                ) : null}
                {canUseNoteOnlyActions ? (
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
                ) : null}
                {isExternalMarkdownFile ? (
                  <button
                    type="button"
                    className="thread-note-icon-button"
                    onClick={() =>
                      runAfterSave(
                        () => dispatchThreadNoteCommand("closeMarkdownFile"),
                        "close this Markdown file"
                      )
                    }
                    aria-label="Close Markdown file"
                    title="Close Markdown file"
                  >
                    <span aria-hidden="true">×</span>
                  </button>
                ) : null}
                <div className="thread-note-overflow-wrap">
                  <button
                    ref={overflowMenuTriggerRef}
                    type="button"
                    className="thread-note-icon-button"
                    onClick={() => setIsOverflowMenuOpen((value) => !value)}
                    aria-label="More actions"
                    aria-expanded={isOverflowMenuOpen}
                    aria-haspopup="menu"
                    title="More actions"
                  >
                    <MoreIcon />
                  </button>
                  {isOverflowMenuOpen ? (
                    <div
                      ref={overflowMenuRef}
                      className="thread-note-overflow-menu"
                      role="menu"
                    >
                      <button
                        type="button"
                        role="menuitem"
                        className="thread-note-overflow-item"
                        onClick={() => {
                          setIsOverflowMenuOpen(false);
                          dispatchThreadNoteCommand("openMarkdownFile");
                        }}
                      >
                        <span className="thread-note-overflow-item-glyph">#</span>
                        <span>Open Markdown File</span>
                      </button>
                      {!isExternalMarkdownFile ? (
                      <button
                        type="button"
                        role="menuitem"
                        className="thread-note-overflow-item"
                        onClick={() => {
                          setIsOverflowMenuOpen(false);
                          handleOpenImagePicker();
                        }}
                        disabled={!hasAnyNotes || !state?.canEdit}
                      >
                        <ImageIcon />
                        <span>Add image</span>
                      </button>
                      ) : null}
                      {canUseNoteOnlyActions ? (
                        <button
                          type="button"
                          role="menuitem"
                          className="thread-note-overflow-item"
                          onClick={() => {
                            setIsOverflowMenuOpen(false);
                            handleOpenNoteLinkPicker();
                          }}
                          disabled={!state?.canEdit}
                        >
                          <span className="thread-note-overflow-item-glyph">↗</span>
                          <span>
                            {noteSelection?.text?.trim() ? "Link Selection" : "Insert Link"}
                          </span>
                        </button>
                      ) : null}
                      {!isExternalMarkdownFile ? (
                        <button
                          type="button"
                          role="menuitem"
                          className="thread-note-overflow-item"
                          onClick={() => {
                            setIsOverflowMenuOpen(false);
                            handleCreateNote();
                          }}
                          disabled={!canCreateNote}
                        >
                          <PlusIcon />
                          <span>
                            New {currentSourceLabel.toLowerCase().replace("notes", "note")}
                          </span>
                        </button>
                      ) : null}
                      {isNotesWorkspace && !isExternalMarkdownFile && state?.workspaceProjectId ? (
                        <button
                          type="button"
                          role="menuitem"
                          className="thread-note-overflow-item"
                          onClick={() => {
                            setIsOverflowMenuOpen(false);
                            handleOpenBatchOrganizer();
                          }}
                        >
                          <span className="thread-note-overflow-item-glyph">✨</span>
                          <span>Organize selected notes</span>
                        </button>
                      ) : null}
                      {!isFullScreenWorkspace && !isExternalMarkdownFile ? (
                        <button
                          type="button"
                          role="menuitem"
                          className="thread-note-overflow-item"
                          onClick={() => {
                            setIsOverflowMenuOpen(false);
                            handleToggleHistoryPanel();
                          }}
                          disabled={!hasRecoveryItems}
                        >
                          <HistoryIcon />
                          <span>History</span>
                        </button>
                      ) : null}
                      {!isFullScreenWorkspace ? (
                        <button
                          type="button"
                          role="menuitem"
                          className="thread-note-overflow-item"
                          onClick={() => {
                            setIsOverflowMenuOpen(false);
                            dispatchThreadNoteCommand("setExpanded", {
                              isExpanded: !isExpanded,
                            });
                          }}
                        >
                          <ExpandIcon expanded={isExpanded} />
                          <span>{isExpanded ? "Collapse note" : "Expand note"}</span>
                        </button>
                      ) : null}
                      {isExternalMarkdownFile ? (
                        <button
                          type="button"
                          role="menuitem"
                          className="thread-note-overflow-item"
                          onClick={() => {
                            setIsOverflowMenuOpen(false);
                            runAfterSave(
                              () => dispatchThreadNoteCommand("closeMarkdownFile"),
                              "close this Markdown file"
                            );
                          }}
                        >
                          <span className="thread-note-overflow-item-glyph">←</span>
                          <span>Back to notes</span>
                        </button>
                      ) : null}
                    </div>
                  ) : null}
                </div>
              </div>
            </div>
          </div>

          {!isFullScreenWorkspace ? (
            <div className="thread-note-meta-row">
              {statusLabel ? <span className="thread-note-status">{statusLabel}</span> : null}
              {utilityControls}
            </div>
          ) : null}
        </div>

        <div
          className={[
            "thread-note-surface",
            isNotesWorkspace ? "is-notes-workspace" : "",
          ]
            .filter(Boolean)
            .join(" ")}
        >
          <input
            ref={imageInputRef}
            type="file"
            accept="image/png,image/jpeg,image/gif,image/webp,image/tiff,.tif,.tiff"
            multiple
            style={{
              position: "absolute",
              inset: "auto",
              top: 0,
              left: 0,
              width: 0,
              height: 0,
              opacity: 0,
              pointerEvents: "none",
              overflow: "hidden",
            }}
            aria-hidden="true"
            tabIndex={-1}
            onChange={handleImageInputChange}
          />
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
              {isNotesWorkspace ? (
                <button
                  type="button"
                  className="thread-note-empty-button"
                  onClick={() => dispatchThreadNoteCommand("openMarkdownFile")}
                >
                  Open Markdown File
                </button>
              ) : null}
            </div>
          ) : (
            <div
              className={[
                "thread-note-workspace",
                showsPreviewPane && showsEditorPane ? "is-split" : "",
                isNotesWorkspace ? "is-notes-workspace" : "",
              ]
                .filter(Boolean)
                .join(" ")}
            >
              {showsEditorPane ? (
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

                  {isRichEditorMode && selectedImage && isImageInspectorOpen ? (
                    <div className="thread-note-image-toolbar">
                      <button
                        type="button"
                        className="thread-note-image-toolbar-close"
                        onClick={() => setIsImageInspectorOpen(false)}
                        aria-label="Close image details"
                        title="Close"
                      >
                        ×
                      </button>
                      <div className="thread-note-image-toolbar-copy">
                        <strong>Image details</strong>
                      </div>
                      <label className="thread-note-image-field">
                        <span>Caption</span>
                        <input
                          type="text"
                          value={selectedImage.title}
                          placeholder="Optional caption"
                          onChange={(event) =>
                            updateSelectedImageNode({ title: event.target.value })
                          }
                        />
                      </label>
                      <label className="thread-note-image-field">
                        <span>Alt text</span>
                        <input
                          type="text"
                          value={selectedImage.alt}
                          placeholder="Describe this image"
                          onChange={(event) =>
                            updateSelectedImageNode({ alt: event.target.value })
                          }
                        />
                      </label>
                      <label className="thread-note-image-field thread-note-image-field--width">
                        <span>Width</span>
                        <input
                          type="number"
                          min={160}
                          max={1280}
                          step={10}
                          value={selectedImage.width ?? ""}
                          placeholder="Auto"
                          onChange={(event) =>
                            updateSelectedImageNode({
                              width:
                                event.target.value.trim().length > 0
                                  ? Number.parseInt(event.target.value, 10)
                                  : null,
                            })
                          }
                        />
                      </label>
                      <button
                        type="button"
                        className="thread-note-image-remove-button"
                        onClick={handleRemoveSelectedImage}
                      >
                        Remove image
                      </button>
                    </div>
                  ) : null}

                  {isRichEditorMode && isInTable && editor ? (
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
                    {isRichEditorMode ? (
                      editor ? (
                        <EditorContent editor={editor} className="thread-note-editor-content" />
                      ) : (
                        <div className="thread-note-editor-loading">{placeholderText}</div>
                      )
                    ) : (
                      <textarea
                        ref={rawMarkdownTextareaRef}
                        className="thread-note-raw-markdown"
                        value={draftText}
                        placeholder={placeholderText}
                        onChange={handleRawMarkdownChange}
                        onSelect={handleRawMarkdownSelect}
                        onClick={handleRawMarkdownSelect}
                        onKeyDown={handleRawMarkdownKeyDown}
                        onKeyUp={handleRawMarkdownSelect}
                        onPaste={handleRawMarkdownPaste}
                        onBlur={handleRawMarkdownBlur}
                        spellCheck={false}
                      />
                    )}
                  </div>
                </div>
              ) : null}

              {showsPreviewPane ? (
                <div className="thread-note-preview-shell">
                  <div className="thread-note-preview-header">
                    <span>{isSplitMode ? "Live preview" : "Note preview"}</span>
                    <span className="thread-note-preview-badge">
                      {isSplitMode ? "Preview" : "Read"}
                    </span>
                  </div>
                  <div className="thread-note-preview-surface">
                    {draftText.trim() ? (
                      <div className="assistant-markdown-shell oa-markdown-surface thread-note-summary-preview">
                        <MarkdownContent
                          markdown={draftText}
                          mermaidDisplayMode="noteCompact"
                          onMermaidRenderErrorChange={setChartRenderError}
                        />
                      </div>
                    ) : (
                      <div className="thread-note-preview-empty">
                        This note is empty right now.
                      </div>
                    )}
                  </div>
                </div>
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
                      onMermaidRenderErrorChange={
                        isChartDraft ? setChartRenderError : undefined
                      }
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
                        disabled={isAIDraftBusy}
                        onClick={handleRegenerateChartDraft}
                      >
                        {isAIDraftBusy ? "Working..." : chartRegenerateButtonLabel}
                      </button>
                    ) : null}
                    {aiDraftPreview && hasChartRenderError ? (
                      <button
                        type="button"
                        className="oa-button"
                        disabled={isAIDraftBusy}
                        onClick={handleRepairChartDraft}
                      >
                        {isAIDraftBusy ? "Working..." : "Fix Diagram Error"}
                      </button>
                    ) : null}
                    {aiDraftPreview ? (
                      <button
                        type="button"
                        className="oa-button"
                        disabled={
                          isAIDraftBusy ||
                          hasChartRenderError ||
                          activeAIDraftSourceKind !== "selection"
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
                        disabled={isAIDraftBusy || hasChartRenderError}
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

        {projectNoteTransfer ? (
          <div
            className="thread-note-dialog-layer"
            onClick={
              projectNoteTransfer.isApplying ? undefined : handleCloseProjectNoteTransfer
            }
          >
            <div
              className="thread-note-dialog thread-note-project-transfer-modal"
              onClick={(event) => event.stopPropagation()}
            >
              <div className="thread-note-dialog-header">
                <div className="thread-note-dialog-copy">
                  <h2>Send to project note</h2>
                  <p>
                    {projectNoteTransfer.step === "picker"
                      ? "Pick which shared project note should receive this selected thread-note content."
                      : "Review the AI placement suggestion before the app copies or moves the content."}
                  </p>
                </div>
                <button
                  type="button"
                  className="thread-note-icon-button thread-note-dialog-close"
                  onClick={handleCloseProjectNoteTransfer}
                  disabled={projectNoteTransfer.isApplying}
                  aria-label="Close project note transfer"
                >
                  ×
                </button>
              </div>
              <div className="thread-note-dialog-body thread-note-project-transfer-body">
                <div className="thread-note-project-transfer-mode-toggle">
                  <button
                    type="button"
                    className={[
                      "thread-note-project-transfer-mode-button",
                      projectNoteTransfer.transferMode === "copy" ? "is-active" : "",
                    ]
                      .filter(Boolean)
                      .join(" ")}
                    disabled={projectNoteTransfer.isApplying}
                    onClick={() =>
                      setProjectNoteTransfer((current) =>
                        current
                          ? {
                              ...current,
                              transferMode: "copy",
                            }
                          : current
                      )
                    }
                  >
                    Copy
                  </button>
                  <button
                    type="button"
                    className={[
                      "thread-note-project-transfer-mode-button",
                      projectNoteTransfer.transferMode === "move" ? "is-active" : "",
                    ]
                      .filter(Boolean)
                      .join(" ")}
                    disabled={projectNoteTransfer.isApplying}
                    onClick={() =>
                      setProjectNoteTransfer((current) =>
                        current
                          ? {
                              ...current,
                              transferMode: "move",
                            }
                          : current
                      )
                    }
                  >
                    Move
                  </button>
                </div>
                <div className="thread-note-project-transfer-selection">
                  <span className="thread-note-project-transfer-selection-label">
                    Selected content
                  </span>
                  <div className="thread-note-project-transfer-selection-preview">
                    {truncateContextMenuPreview(projectNoteTransfer.selectedText)}
                  </div>
                </div>
                {projectNoteTransfer.step === "picker" ? (
                  projectNoteTransferTargets.length > 0 ? (
                    <div className="thread-note-project-transfer-list">
                      {projectNoteTransferTargets.map((targetNote) => (
                        <button
                          key={`${targetNote.ownerId}:${targetNote.id}`}
                          type="button"
                          className={[
                            "thread-note-project-transfer-target",
                            projectNoteTransfer.targetNoteId === targetNote.id
                              ? "is-selected"
                              : "",
                          ]
                            .filter(Boolean)
                            .join(" ")}
                          onClick={() => handleChooseProjectTransferTarget(targetNote.id)}
                        >
                          <span className="thread-note-project-transfer-target-copy">
                            <strong>{normalizeThreadNoteTitle(targetNote.title)}</strong>
                            <span>
                              {targetNote.updatedAtLabel
                                ? `Updated ${targetNote.updatedAtLabel}`
                                : "No saved timestamp yet"}
                            </span>
                          </span>
                          <span className="thread-note-project-transfer-target-action">
                            Preview
                          </span>
                        </button>
                      ))}
                    </div>
                  ) : (
                    <div className="thread-note-project-transfer-empty">
                      <strong>No project notes yet</strong>
                      <p>
                        Open this project&apos;s shared notes first, then create a project note
                        there.
                      </p>
                      <button
                        type="button"
                        className="oa-button oa-button--primary"
                        onClick={() => {
                          dispatchThreadNoteCommand("openProjectNotes", {
                            targetProjectId: projectNoteTransfer.targetProjectId,
                            ownerKind: "project",
                            ownerId: projectNoteTransfer.targetProjectId,
                          });
                          setProjectNoteTransfer(null);
                        }}
                      >
                        Open project notes
                      </button>
                    </div>
                  )
                ) : !projectNoteTransferPreview || isProjectTransferBusy ? (
                  <div className="thread-note-ai-loading">
                    <div className="thread-note-ai-loading-spinner" aria-hidden="true" />
                    <div className="thread-note-ai-loading-copy">
                      AI is choosing the best section in the project note and preparing the
                      inserted markdown.
                    </div>
                  </div>
                ) : (
                  <div className="thread-note-project-transfer-preview">
                    <div className="thread-note-project-transfer-summary-card">
                      <div className="thread-note-project-transfer-summary-row">
                        <span>Target note</span>
                        <strong>
                          {projectNoteTransferPreview.targetNoteTitle ||
                            selectedProjectTransferTarget?.title ||
                            "Project note"}
                        </strong>
                      </div>
                      <div className="thread-note-project-transfer-summary-row">
                        <span>Suggested place</span>
                        <strong>{projectTransferSuggestionLabel}</strong>
                      </div>
                      <div className="thread-note-project-transfer-summary-row">
                        <span>Mode</span>
                        <strong>
                          {projectNoteTransfer.transferMode === "move"
                            ? "Move from thread note"
                            : "Copy from thread note"}
                        </strong>
                      </div>
                    </div>
                    {projectNoteTransferPreview.warningMessage ? (
                      <div className="thread-note-project-transfer-warning">
                        {projectNoteTransferPreview.warningMessage}
                      </div>
                    ) : null}
                    {projectNoteTransferPreview.isError ? (
                      <div className="thread-note-summary-error">
                        {projectNoteTransferPreview.reason}
                      </div>
                    ) : (
                      <>
                        <div className="thread-note-project-transfer-reason">
                          {projectNoteTransferPreview.reason}
                        </div>
                        <div className="assistant-markdown-shell oa-markdown-surface thread-note-summary-preview">
                          <MarkdownContent
                            markdown={projectNoteTransferPreview.insertedMarkdown}
                            mermaidDisplayMode="noteCompact"
                          />
                        </div>
                      </>
                    )}
                  </div>
                )}
              </div>
              <div className="thread-note-dialog-footer">
                {projectNoteTransfer.step === "picker" ? (
                  <button
                    type="button"
                    className="oa-button"
                    onClick={handleCloseProjectNoteTransfer}
                  >
                    Cancel
                  </button>
                ) : projectNoteTransferPreview?.isError ? (
                  <>
                    <button
                      type="button"
                      className="oa-button"
                      disabled={projectNoteTransfer.isApplying}
                      onClick={handleBackToProjectTransferPicker}
                    >
                      Back
                    </button>
                    <button
                      type="button"
                      className="oa-button"
                      disabled={projectNoteTransfer.isApplying}
                      onClick={handleCloseProjectNoteTransfer}
                    >
                      Close
                    </button>
                  </>
                ) : (
                  <>
                    <button
                      type="button"
                      className="oa-button"
                      disabled={projectNoteTransfer.isApplying}
                      onClick={handleBackToProjectTransferPicker}
                    >
                      Change note
                    </button>
                    <button
                      type="button"
                      className="oa-button"
                      disabled={projectNoteTransfer.isApplying}
                      onClick={handleCloseProjectNoteTransfer}
                    >
                      Cancel
                    </button>
                    {canApplyProjectTransferSuggestion ? (
                      <button
                        type="button"
                        className="oa-button"
                        disabled={projectNoteTransfer.isApplying}
                        onClick={() => handleApplyProjectNoteTransfer("suggested")}
                      >
                        {projectNoteTransfer.isApplying ? "Working..." : "Use suggestion"}
                      </button>
                    ) : null}
                    <button
                      type="button"
                      className="oa-button oa-button--primary"
                      disabled={projectNoteTransfer.isApplying}
                      onClick={() => handleApplyProjectNoteTransfer("end")}
                    >
                      {projectNoteTransfer.isApplying
                        ? "Working..."
                        : canApplyProjectTransferSuggestion
                        ? "Add at end instead"
                        : "Add at end"}
                    </button>
                  </>
                )}
              </div>
            </div>
          </div>
        ) : null}

        {linkedNotesPanel}

        {isBatchOrganizerOpen && isNotesWorkspace && state?.workspaceProjectId ? (
          <div className="thread-note-dialog-layer" onClick={handleCloseBatchOrganizer}>
            <div
              className="thread-note-dialog thread-note-batch-organizer-modal"
              onClick={(event) => event.stopPropagation()}
            >
              <div className="thread-note-dialog-header">
                <div className="thread-note-dialog-copy">
                  <h2>Batch AI note organizer</h2>
                  <p>
                    Pick project and thread notes, let AI propose a clean note set, then review
                    every new note and link before anything is saved.
                  </p>
                </div>
                <button
                  type="button"
                  className="thread-note-icon-button thread-note-dialog-close"
                  onClick={handleCloseBatchOrganizer}
                  aria-label="Close batch note organizer"
                >
                  ×
                </button>
              </div>
              <div className="thread-note-dialog-body thread-note-batch-organizer-body">
                {batchOrganizerWarnings.length > 0 ? (
                  <div
                    className={[
                      "thread-note-batch-organizer-warning-list",
                      batchNotePlanPreview?.isError ? "is-error" : "",
                    ]
                      .filter(Boolean)
                      .join(" ")}
                  >
                    {batchOrganizerWarnings.map((warning, index) => (
                      <div key={`${warning}-${index}`}>{warning}</div>
                    ))}
                  </div>
                ) : null}

                {batchOrganizerStep === "select" ? (
                  <>
                    <div className="thread-note-batch-organizer-toolbar">
                      <div className="thread-note-selector-search-shell thread-note-batch-organizer-search-shell">
                        <input
                          type="text"
                          className="thread-note-selector-search"
                          value={batchOrganizerSearch}
                          onChange={(event) => setBatchOrganizerSearch(event.target.value)}
                          placeholder="Search project and thread notes"
                          aria-label="Search selected note sources"
                        />
                      </div>
                      <div className="thread-note-batch-organizer-toolbar-actions">
                        <button
                          type="button"
                          className="oa-button"
                          onClick={handleSelectAllVisibleBatchSources}
                        >
                          Pick visible
                        </button>
                        <button
                          type="button"
                          className="oa-button"
                          disabled={!batchOrganizerSelectedSourceKeys.length}
                          onClick={handleClearBatchSourceSelection}
                        >
                          Clear
                        </button>
                      </div>
                    </div>

                    <div className="thread-note-batch-organizer-selection-summary">
                      <strong>
                        {batchOrganizerSelectedSourceKeys.length} source
                        {batchOrganizerSelectedSourceKeys.length === 1 ? "" : "s"} selected
                      </strong>
                      <div className="thread-note-batch-organizer-chip-row">
                        {batchOrganizerSelectedSourceNotes.length > 0 ? (
                          batchOrganizerSelectedSourceNotes.map((note) => (
                            <button
                              key={`selected-source-${batchSourceSelectionKeyForNote(note)}`}
                              type="button"
                              className="thread-note-batch-organizer-chip"
                              onClick={() =>
                                setBatchOrganizerSourcePreviewKey(
                                  batchSourceSelectionKeyForNote(note)
                                )
                              }
                            >
                              <span>{normalizeThreadNoteTitle(note.title)}</span>
                              <span>{note.sourceLabel}</span>
                            </button>
                          ))
                        ) : (
                          <span className="thread-note-batch-organizer-empty-inline">
                            Pick at least one note to start.
                          </span>
                        )}
                      </div>
                    </div>

                    <div className="thread-note-batch-organizer-selection-layout">
                      <div className="thread-note-batch-organizer-source-panel">
                        {batchOrganizerSections.some(
                          (section) =>
                            section.visibleNotes.length > 0 ||
                            (!normalizedBatchOrganizerSearch && section.allNotes.length === 0)
                        ) ? (
                          batchOrganizerSections.map((section) => (
                            <div
                              key={`batch-source-${noteSourceKey(section.source.ownerKind, section.source.ownerId)}`}
                              className="thread-note-batch-organizer-source-group"
                            >
                              <div className="thread-note-selector-section-header">
                                <span>{noteSourceSectionLabel(section.source)}</span>
                                <span>{section.allNotes.length}</span>
                              </div>
                              {section.visibleNotes.map((note) => {
                                const selectionKey = batchSourceSelectionKeyForNote(note);
                                const isSelected =
                                  batchOrganizerSelectedSourceKeys.includes(selectionKey);
                                return (
                                  <label
                                    key={`batch-source-note-${selectionKey}`}
                                    className={[
                                      "thread-note-batch-organizer-source-row",
                                      isSelected ? "is-selected" : "",
                                    ]
                                      .filter(Boolean)
                                      .join(" ")}
                                  >
                                    <input
                                      type="checkbox"
                                      checked={isSelected}
                                      onChange={() => handleToggleBatchOrganizerSource(note)}
                                    />
                                    <span className="thread-note-batch-organizer-source-copy">
                                      <strong>{normalizeThreadNoteTitle(note.title)}</strong>
                                      <span>
                                        {note.updatedAtLabel
                                          ? `Updated ${note.updatedAtLabel}`
                                          : note.sourceLabel}
                                      </span>
                                    </span>
                                    <span className="thread-note-batch-organizer-type-pill">
                                      {noteTypeLabel(note.noteType)}
                                    </span>
                                  </label>
                                );
                              })}
                              {!normalizedBatchOrganizerSearch &&
                              section.visibleNotes.length === 0 &&
                              section.allNotes.length === 0 ? (
                                <div className="thread-note-batch-organizer-empty-block">
                                  No notes in this source yet.
                                </div>
                              ) : null}
                            </div>
                          ))
                        ) : (
                          <div className="thread-note-selector-empty">
                            No notes match "{batchOrganizerSearch.trim()}".
                          </div>
                        )}
                      </div>

                      <aside className="thread-note-batch-organizer-selection-side">
                        <div className="thread-note-batch-organizer-pane-header">
                          <strong>Selected sources</strong>
                          <span>{batchOrganizerSelectedSourceNotes.length}</span>
                        </div>
                        {batchOrganizerSelectedSourceNotes.length > 0 ? (
                          <div className="thread-note-batch-organizer-selected-list">
                            {batchOrganizerSelectedSourceNotes.map((note) => (
                              <button
                                key={`batch-selected-${batchSourceSelectionKeyForNote(note)}`}
                                type="button"
                                className={[
                                  "thread-note-batch-organizer-selected-card",
                                  batchOrganizerSourcePreviewKey ===
                                  batchSourceSelectionKeyForNote(note)
                                    ? "is-active"
                                    : "",
                                ]
                                  .filter(Boolean)
                                  .join(" ")}
                                onClick={() =>
                                  setBatchOrganizerSourcePreviewKey(
                                    batchSourceSelectionKeyForNote(note)
                                  )
                                }
                              >
                                <strong>{normalizeThreadNoteTitle(note.title)}</strong>
                                <span>{note.sourceLabel}</span>
                                <span>{noteTypeLabel(note.noteType)}</span>
                              </button>
                            ))}
                          </div>
                        ) : (
                          <div className="thread-note-batch-organizer-empty-block">
                            Use the checkboxes on the left to build the AI source set.
                          </div>
                        )}
                      </aside>
                    </div>
                  </>
                ) : !batchNotePlanPreview ? (
                  <div className="thread-note-ai-loading thread-note-batch-organizer-loading">
                    <div className="thread-note-ai-loading-spinner" aria-hidden="true" />
                    <div className="thread-note-ai-loading-copy">
                      AI is organizing the selected notes into a master note, child notes, and
                      links.
                    </div>
                  </div>
                ) : (
                  <div className="thread-note-batch-organizer-preview-layout">
                    <section className="thread-note-batch-organizer-pane">
                      <div className="thread-note-batch-organizer-pane-header">
                        <strong>Selected sources</strong>
                        <span>{batchOrganizerSourceNotes.length}</span>
                      </div>
                      <div className="thread-note-batch-organizer-source-preview-list">
                        {batchOrganizerSourceNotes.map((sourceNote) => {
                          const sourceKey = batchSourceSelectionKeyForSourceNote(sourceNote);
                          return (
                            <button
                              key={`batch-preview-source-${sourceKey}`}
                              type="button"
                              className={[
                                "thread-note-batch-organizer-selected-card",
                                batchOrganizerSourcePreview?.noteId === sourceNote.noteId &&
                                batchOrganizerSourcePreview?.ownerId === sourceNote.ownerId
                                  ? "is-active"
                                  : "",
                              ]
                                .filter(Boolean)
                                .join(" ")}
                              onClick={() => setBatchOrganizerSourcePreviewKey(sourceKey)}
                            >
                              <strong>{normalizeThreadNoteTitle(sourceNote.title)}</strong>
                              <span>{sourceNote.sourceLabel}</span>
                              <span>{noteTypeLabel(sourceNote.noteType)}</span>
                            </button>
                          );
                        })}
                      </div>
                      {batchOrganizerSourcePreview ? (
                        <div className="thread-note-batch-organizer-preview-card">
                          <div className="thread-note-batch-organizer-preview-card-header">
                            <strong>{normalizeThreadNoteTitle(batchOrganizerSourcePreview.title)}</strong>
                            <span>{batchOrganizerSourcePreview.sourceLabel}</span>
                          </div>
                          <div className="assistant-markdown-shell oa-markdown-surface thread-note-batch-organizer-markdown">
                            <MarkdownContent
                              markdown={batchOrganizerSourcePreview.markdown}
                              mermaidDisplayMode="noteCompact"
                            />
                          </div>
                        </div>
                      ) : null}
                    </section>

                    <section className="thread-note-batch-organizer-pane">
                      <div className="thread-note-batch-organizer-pane-header">
                        <strong>Proposed notes</strong>
                        <span>
                          {batchOrganizerEditableNotes.filter((note) => note.accepted).length} kept
                        </span>
                      </div>
                      <div className="thread-note-batch-organizer-note-list">
                        {batchOrganizerEditableNotes.map((note) => (
                          <article
                            key={`batch-proposed-note-${note.tempId}`}
                            className={[
                              "thread-note-batch-organizer-note-card",
                              batchOrganizerActiveNote?.tempId === note.tempId ? "is-active" : "",
                              note.accepted ? "" : "is-muted",
                            ]
                              .filter(Boolean)
                              .join(" ")}
                          >
                            <div className="thread-note-batch-organizer-note-card-top">
                              <button
                                type="button"
                                className="thread-note-batch-organizer-preview-toggle"
                                onClick={() => setBatchOrganizerActiveNoteTempId(note.tempId)}
                              >
                                Preview
                              </button>
                              <label className="thread-note-batch-organizer-keep-toggle">
                                <input
                                  type="checkbox"
                                  checked={note.accepted}
                                  onChange={() =>
                                    handleToggleBatchOrganizerNoteAccepted(note.tempId)
                                  }
                                />
                                <span>Keep</span>
                              </label>
                            </div>
                            <label className="thread-note-batch-organizer-field">
                              <span>Title</span>
                              <input
                                type="text"
                                value={note.title}
                                onChange={(event) =>
                                  handleBatchOrganizerTitleChange(
                                    note.tempId,
                                    event.target.value
                                  )
                                }
                              />
                            </label>
                            <label className="thread-note-batch-organizer-field">
                              <span>Type</span>
                              <select
                                value={note.noteType}
                                onChange={(event) =>
                                  handleBatchOrganizerTypeChange(
                                    note.tempId,
                                    event.target.value
                                  )
                                }
                              >
                                {[
                                  "master",
                                  "note",
                                  "decision",
                                  "task",
                                  "reference",
                                  "question",
                                ].map((noteType) => (
                                  <option key={noteType} value={noteType}>
                                    {noteTypeLabel(noteType)}
                                  </option>
                                ))}
                              </select>
                            </label>
                            <div className="thread-note-batch-organizer-chip-row">
                              {note.sourceNoteTargets.map((sourceTarget) => (
                                <span
                                  key={`${note.tempId}-${batchResolvedTargetKey(sourceTarget)}`}
                                  className="thread-note-batch-organizer-chip is-source"
                                >
                                  {batchResolvedTargetLabel(sourceTarget)}
                                </span>
                              ))}
                            </div>
                          </article>
                        ))}
                      </div>
                      {batchOrganizerActiveNote ? (
                        <div className="thread-note-batch-organizer-preview-card">
                          <div className="thread-note-batch-organizer-preview-card-header">
                            <strong>{normalizeThreadNoteTitle(batchOrganizerActiveNote.title)}</strong>
                            <span>{noteTypeLabel(batchOrganizerActiveNote.noteType)}</span>
                          </div>
                          <div className="assistant-markdown-shell oa-markdown-surface thread-note-batch-organizer-markdown">
                            <MarkdownContent
                              markdown={batchOrganizerActiveNote.markdown}
                              mermaidDisplayMode="noteCompact"
                            />
                          </div>
                        </div>
                      ) : (
                        <div className="thread-note-batch-organizer-empty-block">
                          AI has not proposed any notes yet.
                        </div>
                      )}
                    </section>

                    <section className="thread-note-batch-organizer-pane">
                      <div className="thread-note-batch-organizer-pane-header">
                        <strong>Links and graph</strong>
                        <span>
                          {batchOrganizerEditableLinks.filter((link) => link.accepted).length} kept
                        </span>
                      </div>
                      <div className="thread-note-batch-organizer-link-list">
                        {batchOrganizerLinkRows.length > 0 ? (
                          batchOrganizerLinkRows.map((link) => (
                            <label
                              key={`batch-link-${link.linkKey}`}
                              className={[
                                "thread-note-batch-organizer-link-row",
                                link.accepted ? "" : "is-muted",
                                link.isVisible ? "" : "is-hidden-link",
                              ]
                                .filter(Boolean)
                                .join(" ")}
                            >
                              <input
                                type="checkbox"
                                checked={link.accepted}
                                onChange={() =>
                                  handleToggleBatchOrganizerLinkAccepted(link.linkKey)
                                }
                              />
                              <span className="thread-note-batch-organizer-link-copy">
                                <strong>{link.fromTitle}</strong>
                                <span>links to {link.toTitle}</span>
                              </span>
                            </label>
                          ))
                        ) : (
                          <div className="thread-note-batch-organizer-empty-block">
                            AI has not proposed any links yet.
                          </div>
                        )}
                      </div>

                      <div className="thread-note-batch-organizer-preview-card thread-note-batch-organizer-graph-card">
                        <div className="thread-note-batch-organizer-preview-card-header">
                          <strong>Preview graph</strong>
                          <span>
                            {batchOrganizerGraph?.nodeCount ?? 0} nodes •{" "}
                            {batchOrganizerGraph?.edgeCount ?? 0} links
                          </span>
                        </div>
                        {batchOrganizerGraph ? (
                          <MermaidDiagram
                            code={batchOrganizerGraph.mermaidCode}
                            showViewerHint={false}
                            clickAction="none"
                          />
                        ) : (
                          <div className="thread-note-batch-organizer-empty-block">
                            Keep at least one proposed note to see the preview graph.
                          </div>
                        )}
                      </div>
                    </section>
                  </div>
                )}
              </div>
              <div className="thread-note-dialog-footer">
                {batchOrganizerStep === "select" ? (
                  <>
                    <button
                      type="button"
                      className="oa-button"
                      onClick={handleCloseBatchOrganizer}
                    >
                      Cancel
                    </button>
                    <button
                      type="button"
                      className="oa-button oa-button--primary"
                      disabled={!canRequestBatchPlanPreview}
                      onClick={handleRequestBatchPlanPreview}
                    >
                      Generate preview
                    </button>
                  </>
                ) : (
                  <>
                    <button
                      type="button"
                      className="oa-button"
                      disabled={isBatchNotePlanBusy || batchOrganizerIsApplying}
                      onClick={handleBackToBatchSourceSelection}
                    >
                      Change sources
                    </button>
                    <button
                      type="button"
                      className="oa-button"
                      disabled={batchOrganizerIsApplying}
                      onClick={handleCloseBatchOrganizer}
                    >
                      Cancel
                    </button>
                    <button
                      type="button"
                      className="oa-button oa-button--primary"
                      disabled={!canApplyBatchPlan}
                      onClick={handleApplyBatchPlan}
                    >
                      {batchOrganizerIsApplying ? "Applying..." : "Create notes"}
                    </button>
                  </>
                )}
              </div>
            </div>
          </div>
        ) : null}

        {screenshotImportState ? (
          <div className="thread-note-dialog-layer" onClick={handleCloseScreenshotImport}>
            <div
              className="thread-note-dialog thread-note-screenshot-import-modal"
              onClick={(event) => event.stopPropagation()}
            >
              <div className="thread-note-dialog-header">
                <div className="thread-note-dialog-copy">
                  <h2>Import screenshot</h2>
                </div>
                <button
                  type="button"
                  className="thread-note-icon-button thread-note-dialog-close"
                  onClick={handleCloseScreenshotImport}
                  aria-label="Close screenshot import"
                >
                  ×
                </button>
              </div>
              <div className="thread-note-dialog-body thread-note-screenshot-import-body">
                <div className="thread-note-screenshot-toolbar">
                  {screenshotImportState.capture.dataUrl ? (
                    <div className="thread-note-screenshot-capture-chip">
                      <div className="thread-note-screenshot-capture-thumb">
                        <img
                          src={screenshotImportState.capture.dataUrl}
                          alt="Captured screenshot preview"
                          className="thread-note-screenshot-capture-thumb-image"
                        />
                      </div>
                      <div className="thread-note-screenshot-capture-meta">
                        <strong>Capture</strong>
                        <span>
                          {[
                            (
                              THREAD_NOTE_SCREENSHOT_CAPTURE_MODE_OPTIONS.find(
                                (option) =>
                                  option.value ===
                                  (screenshotImportState.capture.captureMode ?? "area")
                              ) ?? THREAD_NOTE_SCREENSHOT_CAPTURE_MODE_OPTIONS[0]
                            ).chipLabel,
                            screenshotImportState.capture.segmentCount &&
                            screenshotImportState.capture.segmentCount > 1
                              ? `${screenshotImportState.capture.segmentCount} shots`
                              : null,
                          ]
                            .filter(Boolean)
                            .join(" · ") || screenshotImportState.capture.filename?.trim() || "Selected area"}
                        </span>
                      </div>
                    </div>
                  ) : null}

                    <div className="thread-note-screenshot-mode-stack">
                      <div className="thread-note-screenshot-meta-row">
                        <span className="thread-note-screenshot-mini-label">Mode</span>
                        {activeScreenshotModeOption ? (
                          <span className="thread-note-screenshot-mode-note">
                            {activeScreenshotModeOption.description}
                          </span>
                        ) : null}
                      </div>
                      {screenshotImportCaptureHint ? (
                        <div className="thread-note-screenshot-mode-help">
                          {screenshotImportCaptureHint}
                        </div>
                      ) : null}
                      <div
                        className="thread-note-screenshot-mode-grid"
                        role="radiogroup"
                        aria-label="Output mode"
                    >
                      {THREAD_NOTE_SCREENSHOT_MODE_OPTIONS.map((option) => (
                        <button
                          key={option.value}
                          type="button"
                          role="radio"
                          aria-checked={screenshotImportState.outputMode === option.value}
                          className={[
                            "thread-note-screenshot-mode-card",
                            screenshotImportState.outputMode === option.value ? "is-active" : "",
                          ]
                            .filter(Boolean)
                            .join(" ")}
                          onClick={() =>
                            setScreenshotImportState((current) =>
                              current
                                ? {
                                    ...current,
                                    outputMode: option.value,
                                    processed: null,
                                    error: null,
                                  }
                                : current
                            )
                          }
                        >
                          <strong>{option.label}</strong>
                        </button>
                      ))}
                    </div>
                  </div>
                </div>

                {screenshotImportState.outputMode !== "rawOCR" ? (
                  <label className="thread-note-screenshot-field">
                    <span>Instruction</span>
                    <textarea
                      value={screenshotImportState.customInstruction}
                      onChange={(event) =>
                        setScreenshotImportState((current) =>
                          current
                            ? {
                                ...current,
                                customInstruction: event.target.value,
                                processed: null,
                                error: null,
                              }
                            : current
                        )
                      }
                      placeholder="Optional: bullet points, checklist, meeting notes"
                      rows={2}
                    />
                  </label>
                ) : null}

                {isCapturingScreenshot ? (
                  <div className="thread-note-screenshot-status-card">
                    {activeScreenshotImportCaptureMode === "scrolling"
                      ? "Capture the next section after you scroll. Open Assist will keep building one long screenshot."
                      : "Capture the next screenshot and Open Assist will add it to this draft."}
                  </div>
                ) : null}

                {screenshotImportState.isProcessing ? (
                  <div className="thread-note-screenshot-status-card">
                    Preparing preview...
                  </div>
                ) : null}

                {screenshotImportState.error ? (
                  <div className="thread-note-screenshot-status-card is-error">
                    {screenshotImportState.error}
                  </div>
                ) : null}

                {screenshotImportState.processed?.ok ? (
                  <div className="thread-note-screenshot-result-shell">
                    <div className="thread-note-screenshot-result-meta">
                      <strong>Preview</strong>
                      <span>
                        {screenshotImportState.processed.usedVision
                          ? "Vision + OCR"
                          : "OCR only"}
                      </span>
                    </div>
                    {screenshotImportState.outputMode === "rawOCR" ? (
                      <pre className="thread-note-screenshot-raw-preview">
                        {screenshotImportState.processed.rawText ||
                          screenshotImportState.processed.markdown ||
                          ""}
                      </pre>
                    ) : (
                      <div className="thread-note-screenshot-markdown-preview">
                        <MarkdownContent
                          markdown={screenshotImportState.processed.markdown ?? ""}
                          mermaidDisplayMode="noteCompact"
                        />
                      </div>
                    )}
                  </div>
                ) : null}
              </div>
              <div className="thread-note-dialog-footer">
                <button type="button" className="oa-button" onClick={handleCloseScreenshotImport}>
                  Cancel
                </button>
                {canAppendScreenshotImportCaptures ? (
                  <button
                    type="button"
                    className="oa-button"
                    disabled={isCapturingScreenshot || screenshotImportState.isProcessing}
                    onClick={() => {
                      void handleAddScreenshotCapture();
                    }}
                  >
                    {isCapturingScreenshot ? "Capturing..." : screenshotImportAppendLabel}
                  </button>
                ) : null}
                <button
                  type="button"
                  className="oa-button"
                  disabled={screenshotImportState.isProcessing || isCapturingScreenshot}
                  onClick={() => {
                    void handleGenerateScreenshotImportPreview();
                  }}
                >
                  {screenshotImportState.processed?.ok ? "Preview again" : "Preview"}
                </button>
                <button
                  type="button"
                  className="oa-button oa-button--primary"
                  disabled={
                    !screenshotImportState.processed?.ok ||
                    screenshotImportState.isProcessing ||
                    isCapturingScreenshot
                  }
                  onClick={() => {
                    void handleApplyScreenshotImport();
                  }}
                >
                  Insert into note
                </button>
              </div>
            </div>
          </div>
        ) : null}

        {leavePrompt ? (
          <div className="thread-note-dialog-layer" onClick={handleSaveWarningStay}>
            <div
              className="thread-note-dialog thread-note-save-warning-modal"
              onClick={(event) => event.stopPropagation()}
            >
              <div className="thread-note-dialog-header">
                <div className="thread-note-dialog-copy">
                  <h2>Save changes first?</h2>
                  <p>
                    {leavePrompt.message} Save before you {leavePrompt.reason}, or stay
                    here and keep editing.
                  </p>
                </div>
                <button
                  type="button"
                  className="thread-note-icon-button thread-note-dialog-close"
                  onClick={handleSaveWarningStay}
                  aria-label="Stay on note"
                >
                  ×
                </button>
              </div>
              <div className="thread-note-dialog-footer">
                <button
                  type="button"
                  className="oa-button"
                  onClick={handleSaveWarningStay}
                >
                  Stay
                </button>
                <button
                  type="button"
                  className="oa-button"
                  onClick={handleSaveWarningLeave}
                >
                  Leave without saving
                </button>
                <button
                  type="button"
                  className="oa-button oa-button--primary"
                  onClick={handleSaveWarningRetry}
                >
                  Save again
                </button>
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
                            <span>{noteSourceSectionLabel(section.source)}</span>
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
                {canIndentBlockFromMenu || canOutdentBlockFromMenu ? (
                  <div className="oa-react-context-menu__separator" />
                ) : null}
                {canIndentBlockFromMenu ? (
                  <button
                    type="button"
                    className="oa-react-context-menu__item"
                    onClick={handleIndentBlockFromMenu}
                  >
                    <span className="oa-react-context-menu__item-main">
                      <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                        <IndentIcon />
                      </span>
                      <span>Indent selected block</span>
                    </span>
                  </button>
                ) : null}
                {canOutdentBlockFromMenu ? (
                  <button
                    type="button"
                    className="oa-react-context-menu__item"
                    onClick={handleOutdentBlockFromMenu}
                  >
                    <span className="oa-react-context-menu__item-main">
                      <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                        <OutdentIcon />
                      </span>
                      <span>Outdent selected block</span>
                    </span>
                  </button>
                ) : null}
                <div className="oa-react-context-menu__separator" />
                <button
                  type="button"
                  className="oa-react-context-menu__item"
                  onClick={handleMakeSelectionCollapsibleFromMenu}
                >
                  <span className="oa-react-context-menu__item-main">
                    <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                      <SectionToggleIcon />
                    </span>
                    <span>Make collapsible section</span>
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
            noteContextMenu.sourceKind === "line" &&
            typeof noteContextMenu.lineSelectionPos === "number" &&
            isHeadingLineTag(noteContextMenu.lineTag) &&
            noteContextMenu.lineHeadingCollapsible === true ? (
              <button
                type="button"
                className="oa-react-context-menu__item"
                onClick={handleToggleHeadingCollapsibleFromMenu}
              >
                <span className="oa-react-context-menu__item-main">
                  <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                    <SectionToggleIcon />
                  </span>
                  <span>Make regular heading</span>
                </span>
              </button>
            ) : null}
            {noteContextMenuLayer === "ai" ? (
              <div className="oa-react-context-menu__separator" />
            ) : null}
            {noteContextMenuLayer === "ai" ? (
              <>
                {noteContextMenu.sourceKind === "selection" ? (
                  <button
                    type="button"
                    className="oa-react-context-menu__item"
                    onClick={handleAskAssistantAboutSelectionFromMenu}
                  >
                    <span className="oa-react-context-menu__item-main">
                      <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                        <SparklesIcon />
                      </span>
                      <span>Ask assistant about selection</span>
                    </span>
                  </button>
                ) : null}
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
                {canTransferSelectionToProjectNote ? (
                  <button
                    type="button"
                    className="oa-react-context-menu__item"
                    onClick={handleOpenProjectNoteTransfer}
                  >
                    <span className="oa-react-context-menu__item-main">
                      <span className="oa-react-context-menu__item-icon" aria-hidden="true">
                        <ArrowJumpIcon />
                      </span>
                      <span>Send to project note</span>
                    </span>
                  </button>
                ) : null}
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
            {headingTagEditor && isHeadingLineTag(headingTagEditor.tag) ? (
              <section className="thread-note-heading-tag-section">
                <div className="thread-note-heading-tag-section-header">Heading alignment</div>
                <div className="thread-note-heading-tag-actions">
                  {[
                    {
                      alignment: "left" as ThreadNoteHeadingAlignment,
                      token: "L",
                      label: "Left",
                      description: "Keep the heading aligned with the rest of the note.",
                    },
                    {
                      alignment: "center" as ThreadNoteHeadingAlignment,
                      token: "C",
                      label: "Center",
                      description: "Center this heading to make the section title stand out.",
                    },
                  ].map((option) => (
                    <button
                      key={option.alignment}
                      type="button"
                      className={[
                        "thread-note-heading-tag-button",
                        currentHeadingAlignment === option.alignment ? "is-selected" : "",
                      ]
                        .filter(Boolean)
                        .join(" ")}
                      onMouseDown={(event) => {
                        event.preventDefault();
                        handleApplyHeadingAlignment(option.alignment);
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

function MoreIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <circle cx="3.25" cy="8" r="1.1" fill="currentColor" stroke="none" />
      <circle cx="8" cy="8" r="1.1" fill="currentColor" stroke="none" />
      <circle cx="12.75" cy="8" r="1.1" fill="currentColor" stroke="none" />
    </svg>
  );
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

function SaveIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M3.75 2.75h7.25l2.25 2.25v7.25a1.5 1.5 0 0 1-1.5 1.5h-8a1.5 1.5 0 0 1-1.5-1.5v-8a1.5 1.5 0 0 1 1.5-1.5Z" />
      <path d="M5.5 2.75v3.25h4.5V2.75" />
      <path d="M5.5 9.25h5v4h-5z" />
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

function ImageIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M3.75 3.25h8.5A1.5 1.5 0 0 1 13.75 4.75v6.5a1.5 1.5 0 0 1-1.5 1.5h-8.5a1.5 1.5 0 0 1-1.5-1.5v-6.5a1.5 1.5 0 0 1 1.5-1.5Z" />
      <circle cx="5.35" cy="5.55" r="0.95" fill="currentColor" stroke="none" />
      <path d="m3.2 10.9 2.45-2.45a.8.8 0 0 1 1.13 0l1.05 1.05 1.95-1.95a.8.8 0 0 1 1.13 0l1.87 1.87" />
    </svg>
  );
}

function ScreenshotIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M5 3.35h1.35l.65-1.05h1.98l.65 1.05H11a1.5 1.5 0 0 1 1.5 1.5v6.3a1.5 1.5 0 0 1-1.5 1.5H5a1.5 1.5 0 0 1-1.5-1.5v-6.3A1.5 1.5 0 0 1 5 3.35Z" />
      <rect x="5.45" y="5.35" width="5.1" height="3.8" rx="0.85" />
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

function IndentIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M3 4.25h3.2" />
      <path d="M3 8h3.2" />
      <path d="M3 11.75h3.2" />
      <path d="M8.15 4.25h4.85" />
      <path d="M8.15 11.75h4.85" />
      <path d="m8.35 8 2.1-2.1" />
      <path d="m8.35 8 2.1 2.1" />
    </svg>
  );
}

function OutdentIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M3 4.25h4.85" />
      <path d="M3 11.75h4.85" />
      <path d="M9.8 4.25H13" />
      <path d="M9.8 8H13" />
      <path d="M9.8 11.75H13" />
      <path d="m7.65 8-2.1-2.1" />
      <path d="m7.65 8-2.1 2.1" />
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

function detectRawMarkdownSlashQuery(
  markdown: string,
  selectionStart: number,
  selectionEnd: number
): SlashQueryState | null {
  if (selectionStart !== selectionEnd) {
    return null;
  }

  const normalizedMarkdown = normalizeLineEndings(markdown);
  const caret = Number.isFinite(selectionStart)
    ? Math.max(0, Math.min(normalizedMarkdown.length, Math.round(selectionStart)))
    : normalizedMarkdown.length;
  const lineStart = normalizedMarkdown.lastIndexOf("\n", Math.max(0, caret - 1)) + 1;
  const beforeCaret = normalizedMarkdown.slice(lineStart, caret);
  const match = beforeCaret.match(/(?:^|\s)\/([a-z0-9-]*)$/i);
  if (!match) {
    return null;
  }

  const query = (match[1] ?? "").toLowerCase();
  const slashWithQuery = `/${query}`;
  const replaceStartInLine = beforeCaret.lastIndexOf(slashWithQuery);
  if (replaceStartInLine < 0) {
    return null;
  }

  return {
    query,
    replaceFrom: lineStart + replaceStartInLine,
    replaceTo: caret,
  };
}

function buildRawMarkdownSlashInsert(
  commandId: string
): { text: string; selection?: RawMarkdownSelectionOffsets } | null {
  switch (commandId) {
    case "h1":
      return {
        text: "# Heading",
        selection: {
          startOffset: 2,
          endOffset: 9,
        },
      };
    case "h2":
      return {
        text: "## Heading",
        selection: {
          startOffset: 3,
          endOffset: 10,
        },
      };
    case "h3":
      return {
        text: "### Heading",
        selection: {
          startOffset: 4,
          endOffset: 11,
        },
      };
    case "bullet":
      return {
        text: "- Item",
        selection: {
          startOffset: 2,
          endOffset: 6,
        },
      };
    case "numbered":
      return {
        text: "1. Item",
        selection: {
          startOffset: 3,
          endOffset: 7,
        },
      };
    case "todo":
      return {
        text: "- [ ] Task",
        selection: {
          startOffset: 6,
          endOffset: 10,
        },
      };
    case "quote":
      return {
        text: "> Quote",
        selection: {
          startOffset: 2,
          endOffset: 7,
        },
      };
    case "code":
      return {
        text: "```text\ncode\n```\n",
        selection: {
          startOffset: 8,
          endOffset: 12,
        },
      };
    case "divider":
      return {
        text: "---",
      };
    case "table":
      return {
        text: "| Column | Value |\n| --- | --- |\n| Item | Detail |\n",
        selection: {
          startOffset: 2,
          endOffset: 8,
        },
      };
    default:
      return null;
  }
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

function serializeEditorRangeToMarkdown(
  editor: Editor,
  from: number,
  to: number
): string {
  if (from >= to) {
    return "";
  }

  try {
    const selectionDoc = editor.state.doc.cut(from, to);
    const markdown = editor.markdown?.serialize(selectionDoc.toJSON()) ?? "";
    return normalizeLineEndings(markdown).trim();
  } catch {
    return editor.state.doc.textBetween(from, to, "\n\n").trim();
  }
}

function resolveSelectionCollapsibleSectionDraft(
  editor: Editor,
  from: number,
  to: number
): SelectionCollapsibleSectionDraft | null {
  if (from >= to) {
    return null;
  }

  const effectiveTo = resolveCollapsibleSectionSelectionEnd(editor, from, to);

  try {
    const startPosition = editor.state.doc.resolve(from);
    const headingDepth = findAncestorDepth(startPosition, "heading");

    if (headingDepth !== null) {
      const headingNode = startPosition.node(headingDepth);
      const headingPos = startPosition.before(headingDepth);
      const headingNodeEnd = startPosition.after(headingDepth);
      const headingTitle = normalizeLineEndings(headingNode.textContent ?? "").trim();
      const bodyMarkdown =
        effectiveTo > headingNodeEnd
          ? serializeEditorRangeToMarkdown(editor, headingNodeEnd, effectiveTo)
          : "";
      if (!headingTitle) {
        return null;
      }

      return {
        replaceFrom: headingPos,
        replaceTo: Math.max(effectiveTo, headingNodeEnd),
        headingLevel: clamp(Number(headingNode.attrs.level ?? 2), 1, 3) as 1 | 2 | 3,
        headingTitle,
        bodyMarkdown,
        emptyBodyMarker: bodyMarkdown.trim().length > 0 ? null : createEmptySectionBodyMarker(),
      };
    }
  } catch {
    return null;
  }

  const selectedMarkdown = serializeEditorRangeToMarkdown(editor, from, effectiveTo);
  const selectedPlainTextLines = normalizeLineEndings(
    editor.state.doc.textBetween(from, effectiveTo, "\n")
  ).split("\n");
  const lines = normalizeLineEndings(selectedMarkdown).split("\n");
  const firstContentIndex = lines.findIndex((line) => line.trim().length > 0);
  const firstPlainTextIndex = selectedPlainTextLines.findIndex((line) => line.trim().length > 0);
  if (firstContentIndex === -1) {
    return null;
  }

  const headingTitle =
    firstPlainTextIndex === -1
      ? lines[firstContentIndex].trim()
      : selectedPlainTextLines[firstPlainTextIndex].trim();
  const bodyLines = lines.slice(firstContentIndex + 1);
  while (bodyLines.length > 0 && bodyLines[0].trim().length === 0) {
    bodyLines.shift();
  }

  const bodyMarkdown = bodyLines.join("\n").trim();
  return {
    replaceFrom: from,
    replaceTo: effectiveTo,
    headingLevel: 2,
    headingTitle,
    bodyMarkdown,
    emptyBodyMarker: bodyMarkdown ? null : createEmptySectionBodyMarker(),
  };
}

function buildCollapsibleSectionMarkdown(
  draft: SelectionCollapsibleSectionDraft
): string {
  const headingPrefix = "#".repeat(draft.headingLevel);
  const bodyMarkdown = draft.bodyMarkdown.trim() || draft.emptyBodyMarker || "";
  return `${headingPrefix} ${draft.headingTitle} <!-- oa:collapsible -->\n\n${bodyMarkdown}`.trim();
}

function buildMarkdownWithCollapsibleSectionReplacement(
  editor: Editor,
  draft: SelectionCollapsibleSectionDraft
): string {
  const beforeMarkdown = serializeEditorRangeToMarkdown(editor, 0, draft.replaceFrom);
  const afterMarkdown = serializeEditorRangeToMarkdown(
    editor,
    draft.replaceTo,
    editor.state.doc.content.size
  );
  const sectionMarkdown = buildCollapsibleSectionMarkdown(draft);
  return normalizeLineEndings(
    [beforeMarkdown, sectionMarkdown, afterMarkdown]
      .map((segment) => normalizeLineEndings(segment).trim())
      .filter(Boolean)
      .join("\n\n")
  );
}

function createEmptySectionBodyMarker(): string {
  return `oa-empty-collapsible-body-${Math.random().toString(36).slice(2, 10)}`;
}

function resolveCollapsibleSectionSelectionEnd(
  editor: Editor,
  from: number,
  to: number
): number {
  if (to <= from) {
    return to;
  }

  const startBlock = findTopLevelBlockAtSelection(editor, from);
  const endBlock = findTopLevelBlockAtSelection(
    editor,
    Math.max(from, Math.min(editor.state.doc.content.size, to - 1))
  );

  if (!startBlock || !endBlock || startBlock.pos === endBlock.pos) {
    return to;
  }

  return endBlock.insertAt;
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

function resolveThreadNoteSelectionAssistantRect(
  container: HTMLElement | null
): { x: number; y: number; width: number; height: number } | null {
  if (!container) {
    return null;
  }

  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
    return null;
  }

  const range = selection.getRangeAt(0);
  const commonAncestor = range.commonAncestorContainer;
  const anchorNode =
    commonAncestor instanceof Element ? commonAncestor : commonAncestor.parentElement;
  if (!anchorNode || !container.contains(anchorNode)) {
    return null;
  }

  const rect = range.getBoundingClientRect();
  if (!rect.width && !rect.height) {
    return null;
  }

  return {
    x: rect.left,
    y: rect.top,
    width: rect.width,
    height: rect.height,
  };
}

function buildThreadNoteSelectionAnchorRect(
  x: number,
  y: number
): { x: number; y: number; width: number; height: number } {
  return {
    x,
    y,
    width: 2,
    height: 2,
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
        insertAt:
          headingSection?.isCollapsible === true
            ? headingSection.sectionEnd
            : resolvedPosition.after(headingDepth),
        tag: headingLevelToTag(Number(headingNode.attrs.level ?? 1)),
        replaceFrom: headingPos,
        replaceTo: resolvedPosition.after(headingDepth),
        previewFrom: resolvedPosition.start(headingDepth),
        previewTo: resolvedPosition.end(headingDepth),
        headingCollapsible: headingSection?.isCollapsible ?? headingNode.attrs.collapsible === true,
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
    currentTag === "paragraph" &&
    nextTag !== "paragraph" &&
    tryApplyMarkdownLineTagWithinParagraphLine(
      editor,
      selectionPos,
      nextTag,
      headingCollapsible
    )
  ) {
    return;
  }

  if (
    isHeadingLineTag(nextTag) &&
    tryApplyHeadingWithinListItem(editor, selectionPos, nextTag, headingCollapsible)
  ) {
    return;
  }

  if (isListLineTag(currentTag) && isListLineTag(nextTag)) {
    applyListLineTag(editor, selectionPos, nextTag);
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
      nextChain.setNode("heading", { level: 1, collapsible: headingCollapsible ?? false }).run();
      return;
    case "heading2":
      nextChain.setNode("heading", { level: 2, collapsible: headingCollapsible ?? false }).run();
      return;
    case "heading3":
      nextChain.setNode("heading", { level: 3, collapsible: headingCollapsible ?? false }).run();
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

function applyListLineTag(
  editor: Editor,
  selectionPos: number,
  nextTag: Extract<MarkdownLineTag, "bullet" | "numbered" | "todo">
): void {
  const chain = editor.chain().focus().setTextSelection(selectionPos);

  switch (nextTag) {
    case "bullet":
      chain.toggleBulletList().run();
      return;
    case "numbered":
      chain.toggleOrderedList().run();
      return;
    case "todo":
      chain.toggleTaskList().run();
      return;
  }
}

function handleSelectedListIndent(
  editor: Editor,
  direction: "indent" | "outdent"
): boolean {
  const { state, view } = editor;
  if (editor.isActive("table")) {
    return false;
  }

  if (state.selection.empty) {
    const currentListItemType = findCurrentListItemType(state);
    if (!currentListItemType) {
      return false;
    }

    return direction === "indent"
      ? editor.commands.sinkListItem(currentListItemType)
      : editor.commands.liftListItem(currentListItemType);
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

function findCurrentListItemType(
  state: Editor["state"]
): "listItem" | "taskItem" | null {
  const { $from } = state.selection;
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    const nodeTypeName = $from.node(depth).type.name;
    if (nodeTypeName === "listItem" || nodeTypeName === "taskItem") {
      return nodeTypeName;
    }
  }

  return null;
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

function canIndentSelectionAsIndentedBlock(
  editor: Editor,
  from: number,
  to: number
): boolean {
  if (from >= to || editor.isActive("table")) {
    return false;
  }

  return Boolean(editor.state.doc.textBetween(from, to, "\n").trim());
}

function selectionTouchesNodeType(
  state: Editor["state"],
  from: number,
  to: number,
  nodeName: string
): boolean {
  let found = false;

  state.doc.nodesBetween(from, to, (node) => {
    if (node.type.name === nodeName) {
      found = true;
      return false;
    }

    return true;
  });

  if (found) {
    return true;
  }

  try {
    const startPos = Math.max(0, Math.min(from, state.doc.content.size));
    const resolvedFrom = state.doc.resolve(startPos);
    if (findAncestorDepth(resolvedFrom, nodeName) !== null) {
      return true;
    }

    const endPos = Math.max(0, Math.min(Math.max(from, to - 1), state.doc.content.size));
    const resolvedTo = state.doc.resolve(endPos);
    return findAncestorDepth(resolvedTo, nodeName) !== null;
  } catch {
    return false;
  }
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

function tryApplyMarkdownLineTagWithinParagraphLine(
  editor: Editor,
  selectionPos: number,
  nextTag: Exclude<MarkdownLineTag, "paragraph">,
  headingCollapsible?: boolean
): boolean {
  const paragraphLine = resolveParagraphLineAtSelection(editor, selectionPos);
  if (!paragraphLine) {
    return false;
  }

  const { schema } = editor.state;
  const replacementNodes: ProseMirrorNode[] = [];
  let targetNodeStart = paragraphLine.paragraphPos;

  paragraphLine.lines.forEach((lineContent, index) => {
    const nodesForLine =
      index === paragraphLine.targetLineIndex
        ? buildNodesForMarkdownLineTag(schema, nextTag, lineContent, headingCollapsible)
        : [createParagraphNodeFromLineFragment(schema, lineContent)];

    if (index < paragraphLine.targetLineIndex) {
      targetNodeStart += nodesForLine.reduce((total, node) => total + node.nodeSize, 0);
    }

    replacementNodes.push(...nodesForLine);
  });

  if (replacementNodes.length === 0) {
    return false;
  }

  const tr = editor.state.tr.replaceWith(
    paragraphLine.paragraphPos,
    paragraphLine.paragraphPos + paragraphLine.paragraphNode.nodeSize,
    replacementNodes
  );
  const focusPos = Math.min(Math.max(0, targetNodeStart + 1), tr.doc.content.size);
  tr.setSelection(Selection.near(tr.doc.resolve(focusPos), 1));

  const editorView = resolveEditorView(editor);
  if (!editorView) {
    return false;
  }

  editorView.dispatch(tr.scrollIntoView());
  editorView.focus();
  return true;
}

function resolveParagraphLineAtSelection(
  editor: Editor,
  selectionPos: number
): {
  paragraphPos: number;
  paragraphNode: ProseMirrorNode;
  targetLineIndex: number;
  lines: Fragment[];
} | null {
  try {
    const resolvedPosition = editor.state.doc.resolve(selectionPos);
    const paragraphDepth = findAncestorDepth(resolvedPosition, "paragraph");
    if (paragraphDepth === null) {
      return null;
    }

    const paragraphNode = resolvedPosition.node(paragraphDepth);
    const lines = splitParagraphNodeIntoLineFragments(paragraphNode);
    if (lines.length <= 1) {
      return null;
    }

    const paragraphPos = resolvedPosition.before(paragraphDepth);
    const paragraphContentStart = resolvedPosition.start(paragraphDepth);
    const relativeSelectionPos = clamp(
      selectionPos - paragraphContentStart,
      0,
      paragraphNode.content.size
    );

    return {
      paragraphPos,
      paragraphNode,
      targetLineIndex: resolveParagraphLineIndex(paragraphNode, relativeSelectionPos),
      lines,
    };
  } catch {
    return null;
  }
}

function splitParagraphNodeIntoLineFragments(paragraphNode: ProseMirrorNode): Fragment[] {
  const lines: Fragment[] = [];
  let currentLineChildren: ProseMirrorNode[] = [];

  paragraphNode.forEach((child) => {
    if (child.type.name === "hardBreak") {
      lines.push(
        currentLineChildren.length > 0
          ? Fragment.fromArray(currentLineChildren)
          : Fragment.empty
      );
      currentLineChildren = [];
      return;
    }

    currentLineChildren.push(child);
  });

  lines.push(
    currentLineChildren.length > 0 ? Fragment.fromArray(currentLineChildren) : Fragment.empty
  );
  return lines;
}

function resolveParagraphLineIndex(
  paragraphNode: ProseMirrorNode,
  relativeSelectionPos: number
): number {
  let lineIndex = 0;

  paragraphNode.forEach((child, offset) => {
    if (child.type.name === "hardBreak" && relativeSelectionPos > offset) {
      lineIndex += 1;
    }
  });

  return lineIndex;
}

function createParagraphNodeFromLineFragment(
  schema: Editor["state"]["schema"],
  lineContent: Fragment
): ProseMirrorNode {
  return schema.nodes.paragraph.create(null, lineContent.size > 0 ? lineContent : undefined);
}

function buildNodesForMarkdownLineTag(
  schema: Editor["state"]["schema"],
  nextTag: Exclude<MarkdownLineTag, "paragraph">,
  lineContent: Fragment,
  headingCollapsible?: boolean
): ProseMirrorNode[] {
  const paragraphNode = createParagraphNodeFromLineFragment(schema, lineContent);

  switch (nextTag) {
    case "heading1":
      return [
        schema.nodes.heading.create(
          { level: 1, collapsible: headingCollapsible ?? false },
          lineContent.size > 0 ? lineContent : undefined
        ),
      ];
    case "heading2":
      return [
        schema.nodes.heading.create(
          { level: 2, collapsible: headingCollapsible ?? false },
          lineContent.size > 0 ? lineContent : undefined
        ),
      ];
    case "heading3":
      return [
        schema.nodes.heading.create(
          { level: 3, collapsible: headingCollapsible ?? false },
          lineContent.size > 0 ? lineContent : undefined
        ),
      ];
    case "bullet":
      return [
        schema.nodes.bulletList.create(
          null,
          schema.nodes.listItem.create(null, paragraphNode)
        ),
      ];
    case "numbered":
      return [
        schema.nodes.orderedList.create(
          null,
          schema.nodes.listItem.create(null, paragraphNode)
        ),
      ];
    case "todo":
      return [
        schema.nodes.taskList.create(
          null,
          schema.nodes.taskItem.create({ checked: false }, paragraphNode)
        ),
      ];
    case "quote":
      return [schema.nodes.blockquote.create(null, paragraphNode)];
    case "code": {
      const codeText = lineContent.textBetween(0, lineContent.size, "", "");
      return [
        schema.nodes.codeBlock.create(
          null,
          codeText ? schema.text(codeText) : undefined
        ),
      ];
    }
  }
}

function headingAttributesForTag(
  tag: MarkdownLineTag,
  headingCollapsible?: boolean
): { level: 1 | 2 | 3; collapsible: boolean } | null {
  switch (tag) {
    case "heading1":
      return { level: 1, collapsible: headingCollapsible ?? false };
    case "heading2":
      return { level: 2, collapsible: headingCollapsible ?? false };
    case "heading3":
      return { level: 3, collapsible: headingCollapsible ?? false };
    default:
      return null;
  }
}

function isListLineTag(
  tag: MarkdownLineTag
): tag is Extract<MarkdownLineTag, "bullet" | "numbered" | "todo"> {
  return tag === "bullet" || tag === "numbered" || tag === "todo";
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
        insertAt:
          headingSection?.isCollapsible === true
            ? headingSection.sectionEnd
            : insertAt ?? startPosition.after(headingDepth),
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

function findClosestCollapsibleSectionByTitle(
  editor: Editor,
  title: string,
  preferredPos: number
): ThreadNoteHeadingSection | null {
  const normalizedTitle = normalizeLineEndings(title).trim();
  if (!normalizedTitle) {
    return null;
  }

  const matchingSections: ThreadNoteHeadingSection[] = [];
  editor.state.doc.forEach((node, offset) => {
    if (node.type.name !== "heading" || normalizeLineEndings(node.textContent ?? "").trim() !== normalizedTitle) {
      return;
    }

    const section = findHeadingSectionAtPosition(editor.state, offset);
    if (section?.isCollapsible) {
      matchingSections.push(section);
    }
  });

  if (matchingSections.length === 0) {
    return null;
  }

  return matchingSections.reduce((closest, section) => {
    if (!closest) {
      return section;
    }

    return Math.abs(section.headingPos - preferredPos) < Math.abs(closest.headingPos - preferredPos)
      ? section
      : closest;
  }, null as ThreadNoteHeadingSection | null);
}

function findTextRangeInDocument(
  doc: Editor["state"]["doc"],
  text: string
): { from: number; to: number } | null {
  if (!text) {
    return null;
  }

  let result: { from: number; to: number } | null = null;
  doc.descendants((node, pos) => {
    if (result || !node.isText || !node.text) {
      return result === null;
    }

    const offset = node.text.indexOf(text);
    if (offset === -1) {
      return true;
    }

    result = {
      from: pos + offset,
      to: pos + offset + text.length,
    };
    return false;
  });

  return result;
}

function insertParagraphAfterSection(
  editor: Editor,
  sectionEnd: number,
  replaceFrom?: number,
  replaceTo?: number
): boolean {
  const editorView = resolveEditorView(editor);
  if (!editorView) {
    return false;
  }

  const insertAt = Math.min(sectionEnd, editor.state.doc.content.size);

  // If the section extends to the document end, the new paragraph would also
  // become part of the section and get hidden. Uncollapse the section first
  // so the new content stays visible.
  if (insertAt >= editor.state.doc.content.size) {
    const section = findCollapsedHeadingSectionAtSelection(
      editor.state,
      Math.max(0, insertAt - 1)
    );
    if (section) {
      uncollapseHeadingAtPosition(editorView, section.headingPos);
    }
  }

  const tr = editor.state.tr;
  if (
    typeof replaceFrom === "number" &&
    typeof replaceTo === "number" &&
    replaceTo > replaceFrom
  ) {
    tr.deleteRange(replaceFrom, replaceTo);
  }

  const newInsertAt = tr.mapping.map(
    Math.min(sectionEnd, editor.state.doc.content.size)
  );
  tr.insert(newInsertAt, editor.state.schema.nodes.paragraph.create());
  tr.setSelection(TextSelection.create(tr.doc, newInsertAt + 1));
  editorView.dispatch(tr.scrollIntoView());
  editorView.focus();
  return true;
}

function insertParagraphAfterHeading(
  editor: Editor,
  headingSection: NonNullable<ReturnType<typeof findHeadingSectionAtSelection>>
): boolean {
  const nextBlock = findFirstTopLevelBlockWithinSection(
    editor,
    headingSection.headingNodeEnd,
    headingSection.sectionEnd
  );

  if (nextBlock) {
    const contentStart = nextBlock.pos + 1;
    const contentEnd = nextBlock.pos + nextBlock.node.nodeSize - 1;

    if (nextBlock.node.type.name === "paragraph" && contentEnd > contentStart) {
      const paragraphText = nextBlock.node.textContent.trim();
      if (paragraphText === DEFAULT_COLLAPSIBLE_SECTION_BODY) {
        return editor
          .chain()
          .focus()
          .setTextSelection({ from: contentStart, to: contentEnd })
          .run();
      }
    }

    return editor.chain().focus().setTextSelection(contentStart).run();
  }

  const insertAt = Math.min(headingSection.headingNodeEnd, editor.state.doc.content.size);
  const view = resolveEditorView(editor);

  if (headingSection.isCollapsed && view) {
    uncollapseHeadingAtPosition(view, headingSection.headingPos);
  }

  return editor
    .chain()
    .focus()
    .insertContentAt(insertAt, [{ type: "paragraph" }])
    .setTextSelection(insertAt + 1)
    .run();
}

function handleThreadNoteSectionDrop(
  view: EditorView,
  event: DragEvent,
  slice: Slice,
  moved: boolean
): boolean {
  const targetSection = resolveHeadingDropTargetSection(view.state, event.target);
  if (!targetSection || slice.size === 0) {
    return false;
  }

  const internalDrag = resolveThreadNoteInternalDragData(event);
  const shouldMove = moved || internalDrag?.move === true;

  if (targetSection.isCollapsed) {
    uncollapseHeadingAtPosition(view, targetSection.headingPos);
  }

  const insertPos = Math.min(targetSection.headingNodeEnd, view.state.doc.content.size);
  let tr = view.state.tr;
  const dragging = view.dragging;

  if (shouldMove) {
    if (internalDrag) {
      const safeFrom = Math.max(0, Math.min(internalDrag.from, internalDrag.to));
      const safeTo = Math.min(
        view.state.doc.content.size,
        Math.max(internalDrag.from, internalDrag.to)
      );
      if (safeTo > safeFrom) {
        tr.deleteRange(safeFrom, safeTo);
      }
    } else if (dragging?.node) {
      dragging.node.replace(tr);
    } else {
      tr.deleteSelection();
    }
  }

  const mappedInsertPos = tr.mapping.map(insertPos);
  const beforeInsert = tr.doc;
  const isSingleNodeSlice =
    slice.openStart === 0 && slice.openEnd === 0 && slice.content.childCount === 1;

  if (isSingleNodeSlice) {
    const node = slice.content.firstChild;
    if (!node) {
      return false;
    }
    tr.replaceRangeWith(mappedInsertPos, mappedInsertPos, node);
  } else {
    tr.replaceRange(mappedInsertPos, mappedInsertPos, slice);
  }

  if (tr.doc.eq(beforeInsert)) {
    return true;
  }

  let selectionEnd = tr.mapping.map(insertPos);
  tr.mapping.maps[tr.mapping.maps.length - 1]?.forEach((_from, _to, _newFrom, newTo) => {
    selectionEnd = newTo;
  });
  tr.setSelection(Selection.near(tr.doc.resolve(selectionEnd), -1));

  view.focus();
  view.dispatch(tr.setMeta("uiEvent", "drop").scrollIntoView());
  return true;
}

function resolveHeadingDropTargetSection(
  state: Editor["state"],
  eventTarget: EventTarget | null
): ThreadNoteHeadingSection | null {
  const headingElement = resolveHeadingDropTargetElement(eventTarget);
  const rawHeadingPos = headingElement?.getAttribute("data-thread-note-heading-pos");
  if (!rawHeadingPos) {
    return null;
  }

  const headingPos = Number.parseInt(rawHeadingPos, 10);
  if (!Number.isFinite(headingPos)) {
    return null;
  }

  return findHeadingSectionAtPosition(state, headingPos);
}

function resolveHeadingDropTargetElement(
  eventTarget: EventTarget | null
): HTMLElement | null {
  if (!(eventTarget instanceof Node)) {
    return null;
  }

  const eventElement = eventTarget instanceof Element ? eventTarget : eventTarget.parentElement;
  return eventElement?.closest<HTMLElement>(".thread-note-heading-node") ?? null;
}

function isNoteContentDragEvent(event: DragEvent): boolean {
  const dragTypes = event.dataTransfer?.types;
  if (!dragTypes) {
    return false;
  }

  return Array.from(dragTypes).some((type) => type === "text/plain" || type === "text/html");
}

function resolveThreadNoteInternalDragData(
  event: DragEvent
): ThreadNoteInternalDragData | null {
  const rawValue = event.dataTransfer?.getData(THREAD_NOTE_INTERNAL_DRAG_MIME);
  if (!rawValue) {
    return null;
  }

  try {
    const parsed = JSON.parse(rawValue) as Partial<ThreadNoteInternalDragData>;
    if (
      typeof parsed.from !== "number" ||
      typeof parsed.to !== "number" ||
      !Number.isFinite(parsed.from) ||
      !Number.isFinite(parsed.to)
    ) {
      return null;
    }

    return {
      from: parsed.from,
      to: parsed.to,
      move: parsed.move !== false,
    };
  } catch {
    return null;
  }
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

  const containingSection = findContainingHeadingSectionAtSelection(
    editor.state,
    Math.min(lastVisibleBlock.insertAt - 1, editor.state.doc.content.size)
  );
  if (
    containingSection &&
    !containingSection.isCollapsed &&
    lastVisibleBlock.insertAt === containingSection.sectionEnd
  ) {
    if (exitSectionAtLastBlock(editor, containingSection, lastVisibleBlock)) {
      return true;
    }

    return editor.commands.focus("end");
  }

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

function findTopLevelBlockAtSelection(
  editor: Editor,
  selectionPos: number = editor.state.selection.from
): VisibleTopLevelBlock | null {
  try {
    const resolvedPosition = editor.state.doc.resolve(
      Math.min(selectionPos, editor.state.doc.content.size)
    );

    for (let depth = resolvedPosition.depth; depth > 0; depth -= 1) {
      if (resolvedPosition.node(depth - 1).type.name !== "doc") {
        continue;
      }

      const pos = resolvedPosition.before(depth);
      const node = resolvedPosition.node(depth);
      return {
        pos,
        node,
        insertAt: pos + node.nodeSize,
      };
    }
  } catch {
    return null;
  }

  return null;
}

function resolveSectionLeaveContext(
  editor: Editor,
  selectionPos: number = editor.state.selection.from
): {
  section: ThreadNoteHeadingSection;
  block: VisibleTopLevelBlock;
} | null {
  const { state } = editor;
  if (!state.selection.empty) {
    return null;
  }

  const containingSection = findContainingHeadingSectionAtSelection(state, selectionPos);
  if (!containingSection || containingSection.isCollapsed) {
    return null;
  }

  const topLevelBlock = findTopLevelBlockAtSelection(editor, selectionPos);
  if (!topLevelBlock) {
    return null;
  }

  if (topLevelBlock.insertAt !== containingSection.sectionEnd) {
    return null;
  }

  return {
    section: containingSection,
    block: topLevelBlock,
  };
}

function resolveBlockInsertTarget(
  editor: Editor,
  selectionPos: number,
  fallbackInsertAt: number
): number {
  return resolveTopLevelBlockInsertAt(editor, selectionPos, fallbackInsertAt);
}

function findFirstTopLevelBlockWithinSection(
  editor: Editor,
  fromPos: number,
  sectionEnd: number
): VisibleTopLevelBlock | null {
  let firstBlock: VisibleTopLevelBlock | null = null;

  editor.state.doc.forEach((node, offset) => {
    if (firstBlock || offset < fromPos || offset >= sectionEnd) {
      return;
    }

    firstBlock = {
      pos: offset,
      node,
      insertAt: offset + node.nodeSize,
    };
  });

  return firstBlock;
}

function resolveTopLevelBlockInsertAt(
  editor: Editor,
  selectionPos: number,
  fallbackInsertAt: number
): number {
  try {
    const resolvedPosition = editor.state.doc.resolve(
      Math.min(selectionPos, editor.state.doc.content.size)
    );

    for (let depth = resolvedPosition.depth; depth > 0; depth -= 1) {
      if (resolvedPosition.node(depth - 1).type.name === "doc") {
        return resolvedPosition.after(depth);
      }
    }
  } catch {
    return Math.min(fallbackInsertAt, editor.state.doc.content.size);
  }

  return Math.min(fallbackInsertAt, editor.state.doc.content.size);
}

function applyMarkdownInsertAction(
  editor: Editor,
  selectionPos: number,
  insertAt: number,
  action: MarkdownInsertAction
) {
  const targetInsertAt = resolveBlockInsertTarget(editor, selectionPos, insertAt);

  switch (action) {
    case "divider":
      editor
        .chain()
        .focus()
        .setTextSelection(targetInsertAt)
        .setHorizontalRule()
        .createParagraphNear()
        .run();
      return;
    case "table":
      editor
        .chain()
        .focus()
        .setTextSelection(targetInsertAt)
        .insertTable({ rows: 3, cols: 2, withHeaderRow: true })
        .run();
      return;
    default:
      return;
  }
}

function exitSectionAtLastBlock(
  editor: Editor,
  section: ThreadNoteHeadingSection,
  block: VisibleTopLevelBlock
): boolean {
  const shouldReplaceEmptyParagraph =
    block.node.type.name === "paragraph" &&
    (block.node.textContent ?? "").trim() === "";
  const replaceFrom = shouldReplaceEmptyParagraph ? block.pos : undefined;
  const replaceTo = shouldReplaceEmptyParagraph ? block.insertAt : undefined;

  if (section.sectionEnd >= editor.state.doc.content.size) {
    return insertDividerAndParagraphOutsideSection(editor, section, replaceFrom, replaceTo);
  }

  return insertParagraphOutsideSection(editor, section, replaceFrom, replaceTo);
}

function insertDividerAndParagraphOutsideSection(
  editor: Editor,
  section: ThreadNoteHeadingSection,
  replaceFrom?: number,
  replaceTo?: number
): boolean {
  const editorView = resolveEditorView(editor);
  if (!editorView) {
    return false;
  }

  const { schema } = editor.state;
  const dividerNode = schema.nodes.horizontalRule.create();
  const paragraphNode = schema.nodes.paragraph.create();
  const tr = editor.state.tr;
  if (
    typeof replaceFrom === "number" &&
    typeof replaceTo === "number" &&
    replaceTo > replaceFrom
  ) {
    tr.deleteRange(replaceFrom, replaceTo);
  }

  // A divider creates a real persisted boundary so the paragraph stays outside
  // the collapsible section after save/reload.
  const insertAt = tr.mapping.map(
    Math.min(section.sectionEnd, editor.state.doc.content.size)
  );
  tr.insert(insertAt, Fragment.fromArray([dividerNode, paragraphNode]));
  tr.setSelection(TextSelection.create(tr.doc, insertAt + dividerNode.nodeSize + 1));
  editorView.dispatch(tr.scrollIntoView());
  editorView.focus();
  return true;
}

function insertParagraphOutsideSection(
  editor: Editor,
  section: ThreadNoteHeadingSection,
  replaceFrom?: number,
  replaceTo?: number
): boolean {
  if (section.sectionEnd >= editor.state.doc.content.size) {
    return false;
  }

  const editorView = resolveEditorView(editor);
  if (!editorView) {
    return false;
  }

  const tr = editor.state.tr;
  if (
    typeof replaceFrom === "number" &&
    typeof replaceTo === "number" &&
    replaceTo > replaceFrom
  ) {
    tr.deleteRange(replaceFrom, replaceTo);
  }

  const insertAt = tr.mapping.map(
    Math.min(section.sectionEnd, editor.state.doc.content.size)
  );
  tr.insert(insertAt, editor.state.schema.nodes.paragraph.create());
  tr.setSelection(TextSelection.create(tr.doc, insertAt + 1));
  editorView.dispatch(tr.scrollIntoView());
  editorView.focus();
  return true;
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

function serializeEditorMarkdownRange(
  editor: Editor | null,
  from?: number,
  to?: number
): string {
  if (!editor || typeof from !== "number" || typeof to !== "number" || from >= to) {
    return "";
  }

  try {
    const selectionDoc = editor.state.doc.cut(from, to);
    const markdown = editor.markdown?.serialize(selectionDoc.toJSON()) ?? "";
    return normalizeLineEndings(markdown).trim();
  } catch {
    return editor.state.doc.textBetween(from, to, "\n\n").trim();
  }
}

function createThreadNoteImageRequestID(): string {
  if (typeof window !== "undefined" && window.crypto?.randomUUID) {
    return window.crypto.randomUUID();
  }

  return `thread-note-image-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function createThreadNoteScreenshotRequestID(): string {
  if (typeof window !== "undefined" && window.crypto?.randomUUID) {
    return window.crypto.randomUUID();
  }

  return `thread-note-screenshot-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function createSaveRequestID(): string {
  if (typeof window !== "undefined" && window.crypto?.randomUUID) {
    return window.crypto.randomUUID();
  }

  return `thread-note-save-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function readFileAsDataURL(file: File): Promise<string | null> {
  return new Promise((resolve) => {
    const reader = new FileReader();
    reader.onload = () => {
      resolve(typeof reader.result === "string" ? reader.result : null);
    };
    reader.onerror = () => resolve(null);
    reader.readAsDataURL(file);
  });
}

function loadThreadNoteScreenshotImage(dataUrl: string): Promise<HTMLImageElement | null> {
  return new Promise((resolve) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => resolve(null);
    image.src = dataUrl;
  });
}

function threadNoteScreenshotSessionFilename(
  captureMode: ThreadNoteScreenshotCaptureMode,
  segmentCount: number
): string {
  const dateStamp = new Date().toISOString().slice(0, 10);
  switch (captureMode) {
    case "scrolling":
      return `Scrolling-Screenshot-${dateStamp}-${Math.max(1, segmentCount)}.png`;
    case "multiple":
      return `Screenshots-${dateStamp}-${Math.max(1, segmentCount)}.png`;
    case "area":
    default:
      return `Screenshot-${dateStamp}.png`;
  }
}

function threadNoteScreenshotProcessingTimeoutMs(
  capture: ThreadNoteScreenshotCaptureResult,
  outputMode: ThreadNoteScreenshotImportMode
): number {
  const segmentCount = Math.max(1, capture.segmentCount ?? 1);
  if (outputMode === "rawOCR") {
    return Math.min(
      THREAD_NOTE_SCREENSHOT_PROCESSING_TIMEOUT_MAX_MS,
      20000 + Math.max(0, segmentCount - 1) * 4000
    );
  }

  const baseTimeout = outputMode === "cleanTextAndImage" ? 50000 : 45000;
  const perExtraSegmentTimeout =
    capture.captureMode === "multiple"
      ? 14000
      : capture.captureMode === "scrolling"
        ? 10000
        : 6000;

  return Math.min(
    THREAD_NOTE_SCREENSHOT_PROCESSING_TIMEOUT_MAX_MS,
    baseTimeout + Math.max(0, segmentCount - 1) * perExtraSegmentTimeout
  );
}

async function composeThreadNoteScreenshotSessionCapture(
  captures: ThreadNoteScreenshotCaptureResult[],
  captureMode: ThreadNoteScreenshotCaptureMode
): Promise<ThreadNoteScreenshotCaptureResult | null> {
  if (!captures.length) {
    return null;
  }

  if (captures.length === 1) {
    return {
      ...captures[0],
      captureMode,
      segmentCount: 1,
      filename: threadNoteScreenshotSessionFilename(captureMode, 1),
    };
  }

  const validCaptures = captures.filter((capture) => capture.ok && capture.dataUrl);
  if (!validCaptures.length) {
    return null;
  }

  const images = await Promise.all(
    validCaptures.map((capture) => loadThreadNoteScreenshotImage(capture.dataUrl ?? ""))
  );
  const loadedImages = images.filter(
    (image): image is HTMLImageElement => image instanceof HTMLImageElement
  );

  if (!loadedImages.length) {
    return null;
  }

  const maxSourceWidth = loadedImages.reduce(
    (maxWidth, image) => Math.max(maxWidth, image.naturalWidth || image.width || 1),
    1
  );
  const scale = Math.min(1, 1680 / maxSourceWidth);
  const isScrolling = captureMode === "scrolling";
  const padding = isScrolling ? 0 : 14;
  const gap = isScrolling ? 0 : 18;
  const drawSizes = loadedImages.map((image) => ({
    width: Math.max(1, image.naturalWidth || image.width || 1) * scale,
    height: Math.max(1, image.naturalHeight || image.height || 1) * scale,
  }));
  const contentWidth = drawSizes.reduce((maxWidth, size) => Math.max(maxWidth, size.width), 1);
  const canvasWidth = Math.ceil(contentWidth + padding * 2);
  const canvasHeight = Math.ceil(
    drawSizes.reduce((sum, size) => sum + size.height, padding * 2 + gap * (drawSizes.length - 1))
  );

  const canvas = document.createElement("canvas");
  canvas.width = canvasWidth;
  canvas.height = canvasHeight;
  const context = canvas.getContext("2d");
  if (!context) {
    return null;
  }

  if (!isScrolling) {
    context.fillStyle = "#0d1016";
    context.fillRect(0, 0, canvasWidth, canvasHeight);
  }

  let currentY = padding;
  loadedImages.forEach((image, index) => {
    const drawSize = drawSizes[index];
    const drawX = padding + (contentWidth - drawSize.width) / 2;

    if (!isScrolling) {
      context.fillStyle = "#161922";
      roundRect(context, drawX - 1, currentY - 1, drawSize.width + 2, drawSize.height + 2, 12);
      context.fill();
    }
    context.drawImage(image, drawX, currentY, drawSize.width, drawSize.height);

    currentY += drawSize.height + gap;
  });

  return {
    requestId: createThreadNoteScreenshotRequestID(),
    ok: true,
    cancelled: false,
    message: null,
    captureMode,
    segmentCount: validCaptures.length,
    filename: threadNoteScreenshotSessionFilename(captureMode, validCaptures.length),
    mimeType: "image/png",
    dataUrl: canvas.toDataURL("image/png"),
  };
}

function roundRect(
  context: CanvasRenderingContext2D,
  x: number,
  y: number,
  width: number,
  height: number,
  radius: number
) {
  const resolvedRadius = Math.max(0, Math.min(radius, width / 2, height / 2));
  context.beginPath();
  context.moveTo(x + resolvedRadius, y);
  context.lineTo(x + width - resolvedRadius, y);
  context.quadraticCurveTo(x + width, y, x + width, y + resolvedRadius);
  context.lineTo(x + width, y + height - resolvedRadius);
  context.quadraticCurveTo(x + width, y + height, x + width - resolvedRadius, y + height);
  context.lineTo(x + resolvedRadius, y + height);
  context.quadraticCurveTo(x, y + height, x, y + height - resolvedRadius);
  context.lineTo(x, y + resolvedRadius);
  context.quadraticCurveTo(x, y, x + resolvedRadius, y);
  context.closePath();
}

async function fileFromThreadNoteDataURL(
  dataUrl: string,
  filename: string,
  fallbackMimeType: string
): Promise<File | null> {
  try {
    const response = await fetch(dataUrl);
    const blob = await response.blob();
    const resolvedMimeType = blob.type || fallbackMimeType || "image/png";
    return new File([blob], filename, { type: resolvedMimeType });
  } catch {
    return null;
  }
}

function buildThreadNotePlainTextContent(value: string) {
  const paragraphs = normalizeLineEndings(value)
    .split(/\n{2,}/)
    .map((paragraph) => paragraph.trim())
    .filter(Boolean);

  if (!paragraphs.length) {
    return [{ type: "paragraph" }];
  }

  return paragraphs.map((paragraph) => {
    const lines = paragraph.split("\n");
    return {
      type: "paragraph",
      content: lines.flatMap((line, index) => {
        const content: Array<{ type: "text"; text: string } | { type: "hardBreak" }> = [];
        if (line.length) {
          content.push({ type: "text", text: line });
        }
        if (index < lines.length - 1) {
          content.push({ type: "hardBreak" });
        }
        return content;
      }),
    };
  });
}

function extractThreadNoteImageFiles(
  items?: DataTransferItemList | null,
  files?: FileList | null
): File[] {
  const itemFiles = Array.from(items ?? [])
    .filter((item) => item.kind === "file" && isPotentialThreadNoteImageType(item.type))
    .map((item) => item.getAsFile())
    .filter((file): file is File => file instanceof File && isPotentialThreadNoteImageFile(file));

  if (itemFiles.length) {
    return itemFiles;
  }

  return Array.from(files ?? []).filter((file) => isPotentialThreadNoteImageFile(file));
}

function shouldAttemptNativeThreadNoteClipboardImagePaste(
  clipboardData?: DataTransfer | null
): boolean {
  const types = Array.from(clipboardData?.types ?? []).map((type) => type.trim().toLowerCase());
  if (types.some((type) => type === "files" || isPotentialThreadNoteImageType(type))) {
    return true;
  }

  if (
    types.some((type) =>
      ["png", "jpeg", "jpg", "gif", "webp", "tiff", "tif", "bmp", "heic"].some((token) =>
        type.includes(token)
      )
    )
  ) {
    return true;
  }

  const html = clipboardData?.getData("text/html")?.trim() ?? "";
  if (html && /<img[\s>]/i.test(html)) {
    return true;
  }

  const items = Array.from(clipboardData?.items ?? []);
  if (items.some((item) => item.kind === "file" || isPotentialThreadNoteImageType(item.type))) {
    return true;
  }

  return types.length === 0 && items.length === 0;
}

function isSupportedThreadNoteImageMimeType(mimeType?: string | null): boolean {
  if (!mimeType) {
    return false;
  }

  return THREAD_NOTE_SUPPORTED_IMAGE_MIME_TYPES.has(mimeType.toLowerCase());
}

function isPotentialThreadNoteImageType(mimeType?: string | null): boolean {
  const normalized = mimeType?.trim().toLowerCase() ?? "";
  return !normalized || normalized.startsWith("image/");
}

function isPotentialThreadNoteImageFile(file: File): boolean {
  if (isPotentialThreadNoteImageType(file.type)) {
    return true;
  }

  const extension = file.name.split(".").pop()?.trim().toLowerCase() ?? "";
  return THREAD_NOTE_SUPPORTED_IMAGE_EXTENSIONS.has(extension);
}

function resolveThreadNoteImageMimeType(file: File, dataUrl?: string | null): string {
  const normalizedFileType = file.type.trim().toLowerCase();
  if (isSupportedThreadNoteImageMimeType(normalizedFileType)) {
    return normalizedFileType;
  }

  const dataUrlMimeType = extractThreadNoteDataUrlMimeType(dataUrl);
  if (isSupportedThreadNoteImageMimeType(dataUrlMimeType)) {
    return dataUrlMimeType!;
  }

  const extension = file.name.split(".").pop()?.trim().toLowerCase() ?? "";
  switch (extension) {
    case "png":
      return "image/png";
    case "jpg":
    case "jpeg":
      return "image/jpeg";
    case "gif":
      return "image/gif";
    case "webp":
      return "image/webp";
    case "tif":
    case "tiff":
      return "image/tiff";
    default:
      return normalizedFileType;
  }
}

function extractThreadNoteDataUrlMimeType(dataUrl?: string | null): string | null {
  const trimmed = dataUrl?.trim();
  if (!trimmed) {
    return null;
  }

  const match = trimmed.match(/^data:([^;,]+)[;,]/i);
  return match?.[1]?.trim().toLowerCase() ?? null;
}

function collectThreadNoteFindMatches(editor: Editor, query: string): ThreadNoteSearchMatch[] {
  const normalizedQuery = query.trim().toLowerCase();
  if (!normalizedQuery) {
    return [];
  }

  const matches: ThreadNoteSearchMatch[] = [];
  editor.state.doc.descendants((node, pos) => {
    if (!node.isText) {
      return true;
    }

    const text = node.text ?? "";
    const normalizedText = text.toLowerCase();
    let searchStart = 0;
    let matchIndex = normalizedText.indexOf(normalizedQuery, searchStart);

    while (matchIndex !== -1) {
      const from = pos + matchIndex;
      const to = from + normalizedQuery.length;
      matches.push({
        from,
        to,
        collapsedHeadingPositions: findCollapsedHeadingPositionsContainingSelection(
          editor.state,
          from
        ),
      });
      searchStart = matchIndex + 1;
      matchIndex = normalizedText.indexOf(normalizedQuery, searchStart);
    }

    return true;
  });

  return matches;
}

function findCollapsedHeadingPositionsContainingSelection(
  state: Editor["state"],
  selectionPos: number
): number[] {
  const collapsedHeadingPositions: number[] = [];

  state.doc.forEach((node, offset) => {
    if (node.type.name !== "heading") {
      return;
    }

    const section = findHeadingSectionAtPosition(state, offset);
    if (!section?.isCollapsed) {
      return;
    }

    if (selectionPos >= section.headingNodeEnd && selectionPos < section.sectionEnd) {
      collapsedHeadingPositions.push(section.headingPos);
    }
  });

  return collapsedHeadingPositions.sort((left, right) => left - right);
}

function focusThreadNoteFindMatch(editor: Editor, match: ThreadNoteSearchMatch): boolean {
  const editorView = resolveEditorView(editor);
  if (!editorView) {
    return false;
  }

  for (const headingPos of match.collapsedHeadingPositions) {
    uncollapseHeadingAtPosition(editorView, headingPos);
  }

  try {
    const selection = TextSelection.create(editorView.state.doc, match.from, match.to);
    editorView.dispatch(editorView.state.tr.setSelection(selection).scrollIntoView());
    editorView.focus();
    return true;
  } catch {
    return false;
  }
}

function preferredThreadNoteImageAlt(filename?: string | null): string {
  const trimmed = filename?.trim();
  if (!trimmed) {
    return "Image";
  }

  const baseName = trimmed.replace(/\.[^.]+$/, "");
  const normalized = baseName.replace(/[-_]+/g, " ").replace(/\s+/g, " ").trim();
  return normalized || "Image";
}

function resolveSelectedThreadNoteImage(editor: Editor): SelectedImageState | null {
  const selection = editor.state.selection;
  if (!(selection instanceof NodeSelection) || selection.node.type.name !== "threadNoteImage") {
    return null;
  }

  const width =
    typeof selection.node.attrs.width === "number" && Number.isFinite(selection.node.attrs.width)
      ? Math.max(160, Math.round(selection.node.attrs.width))
      : null;
  return {
    alt: `${selection.node.attrs.alt ?? ""}`,
    title: `${selection.node.attrs.title ?? ""}`,
    width,
  };
}

function insertThreadNoteImages(
  editor: Editor,
  options: {
    from?: number;
    to?: number;
    images: Array<{ src: string; alt: string; title: string }>;
  }
) {
  if (!options.images.length) {
    return;
  }

  const from = typeof options.from === "number" ? options.from : editor.state.selection.from;
  const to = typeof options.to === "number" ? options.to : editor.state.selection.to;
  const content = [
    ...options.images.map((image) => ({
      type: "threadNoteImage",
      attrs: {
        src: image.src,
        alt: image.alt,
        title: image.title,
      },
    })),
    { type: "paragraph" },
  ];

  editor
    .chain()
    .focus()
    .insertContentAt({ from, to }, content)
    .run();
}

function truncateContextMenuPreview(text: string): string {
  const normalized = text.replace(/\s+/g, " ").trim();
  if (normalized.length <= 120) {
    return normalized;
  }
  return `${normalized.slice(0, 117).trimEnd()}...`;
}
