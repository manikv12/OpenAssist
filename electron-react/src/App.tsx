import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ComponentType, type CSSProperties, type ChangeEvent, type KeyboardEvent, type MutableRefObject, type PointerEvent as ReactPointerEvent, type ReactNode, type RefObject } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { EditorContent, useEditor, type Editor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import { Placeholder } from "@tiptap/extension-placeholder";
import { Image } from "@tiptap/extension-image";
import { TableKit } from "@tiptap/extension-table";
import { TaskList } from "@tiptap/extension-task-list";
import { TaskItem } from "@tiptap/extension-task-item";
import { Markdown } from "@tiptap/markdown";
import { createPortal } from "react-dom";
import ReactMarkdown, { type Components } from "react-markdown";
import { Prism as SyntaxHighlighter } from "react-syntax-highlighter";
import remarkGfm from "remark-gfm";
import {
  ArrowDownCircle,
  BookOpen,
  Bot,
  Bold,
  Brain,
  BriefcaseBusiness,
  CircleGauge,
  ClipboardPaste,
  Command,
  Cpu,
  Eye,
  EyeOff,
  FileText,
  FilePlus2,
  FolderMinus,
  Gauge,
  GitBranch,
  Hammer,
  Heading2,
  Italic,
  Keyboard,
  Layers3,
  List,
  ListTodo,
  MessageSquare,
  Maximize2,
  Mic,
  Minus,
  Monitor,
  Moon,
  PackageCheck,
  Paintbrush,
  PanelLeftClose,
  PanelLeftOpen,
  PanelRightClose,
  Pin,
  PinOff,
  RefreshCw,
  Save,
  Send,
  Shield,
  ShieldPlus,
  Square,
  Star,
  Sun,
  Table2,
  UserCircle,
  Volume2,
  WandSparkles,
  Wind,
  Workflow,
  Zap
} from "lucide-react";
import {
  Archive,
  ArrowLeft,
  ArrowUp,
  ArrowUpRightSquare,
  CalendarClock,
  Check,
  CheckCircle2,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  Code2,
  Copy,
  ExternalLink,
  Folder,
  FolderPlus,
  HistoryIcon,
  MessageSquarePlus,
  MoreHorizontalIcon,
  NotebookTabs,
  Pencil,
  Plug,
  Plus,
  Search,
  Settings,
  Sparkles,
  SidebarOpen,
  Tasks,
  Terminal,
  Trash2,
  X
} from "./components/CodexIcons";
import claudeMark from "./assets/provider-marks/claude.svg";
import codexMark from "./assets/provider-marks/codex.svg";
import copilotMark from "./assets/provider-marks/copilot.svg";
import ollamaMark from "./assets/provider-marks/ollama.svg";
import { settingsSections } from "./data";
import type {
  AutomationItem,
  ChatMessage,
  NoteDetail,
  NoteFolderItem,
  NoteItem,
  OpenAssistAppState,
  PluginItem,
  ProviderModelOption,
  ProviderRunEvent,
  ProviderUsageSnapshot,
  ProjectItem,
  SettingsSnapshot,
  SettingsUpdateKey,
  SettingsUpdateValue,
  SkillItem,
  ThreadDetail,
  TranscriptHistoryEntry,
  ThreadMemorySnapshot,
  ThreadNoteListItem,
  ThreadNoteWorkspace,
  ThreadItem,
  ViewKey
} from "./types";

type SettingsKey = (typeof settingsSections)[number]["id"];
function settingsKeyFromString(value?: string | null): SettingsKey | undefined {
  const normalized = String(value ?? "").trim();
  return settingsSections.some((section) => section.id === normalized) ? normalized as SettingsKey : undefined;
}
type ProviderKey =
  | "codex"
  | "copilot"
  | "claudeCode"
  | "ollamaLocal";
type ApprovalOption = NonNullable<ChatMessage["approvalOptions"]>[number];
type ApprovalResponder = (message: ChatMessage, option: ApprovalOption) => void;
type RuntimeProviderKey = Extract<ProviderKey, "codex" | "copilot" | "claudeCode" | "ollamaLocal">;
type CodexPermissionMode = "default" | "autoReview" | "fullAccess" | "custom";
type VoiceInputStatus = "idle" | "listening" | "processing" | "unsupported" | "error";
type LiveVoiceStatus = "idle" | "connecting" | "listening" | "speaking" | "delegating" | "error";
const DEFAULT_THREAD_TITLE = "New Assistant Session";

function usableThreadTitle(title?: string | null) {
  const trimmed = title?.replace(/\s+/g, " ").trim();
  return trimmed && trimmed !== DEFAULT_THREAD_TITLE ? trimmed : undefined;
}

function chatTitleForPrompt(prompt: string) {
  const squashed = prompt.replace(/\s+/g, " ").trim();
  return squashed.length > 78 ? `${squashed.slice(0, 77).trimEnd()}...` : squashed || DEFAULT_THREAD_TITLE;
}

type RealtimeAudioChunk = {
  data: string;
  sampleRate: number;
  numChannels: number;
  samplesPerChannel: number | null;
  itemId: string | null;
};
type RealtimeStartResult = { ok: boolean; threadId?: string; error?: string; voices?: unknown };
type OpenAssistRealtimeAPI = {
  start: (options?: {
    threadId?: string;
    provider?: string;
    interactionMode?: string;
    permissionMode?: string;
    reasoningEffort?: string;
  }) => Promise<RealtimeStartResult>;
  appendAudio: (chunk: RealtimeAudioChunk) => Promise<{ ok: boolean; error?: string }>;
  appendText: (text: string) => Promise<{ ok: boolean; error?: string }>;
  stop: () => Promise<{ ok: boolean; error?: string }>;
  stopDelegation?: () => Promise<{ ok: boolean; error?: string }>;
  onEvent: (listener: (event: { type: string; payload?: any }) => void) => () => void;
};
type AssistantPanelKey = "thread-note" | "session-instructions" | "memory" | null;
type RuntimeProviderOption = { key: RuntimeProviderKey; label: string; detail: string };
type CodexPermissionOption = {
  value: CodexPermissionMode;
  label: string;
  shortLabel: string;
  detail: string;
  Icon: ComponentType<{ size?: number; strokeWidth?: number; className?: string }>;
};
type ShortcutTarget = "holdToTalk" | "continuousToggle" | "assistantLiveVoice" | "assistantCompact" | "screenAnalysis";
type ShortcutPhase = "trigger" | "down" | "up";
type NotesScope = "project" | "thread";
type SelectedNoteTarget =
  | { scope: "project"; projectID: string; noteID: string }
  | { scope: "thread"; threadID: string; noteID: string; projectID?: string };
type NoteSaveStatus = { kind: "idle" | "dirty" | "saving" | "saved" | "error"; message?: string; at?: number };
type WorkspaceLaunchTargetSnapshot = {
  id: string;
  title: string;
  isInstalled: boolean;
  remembersAsPreferred: boolean;
  fallbackSymbol: string;
  iconDataURL: string;
};

const realtimeSampleRate = 24_000;
const liveVoiceConnectTimeoutMs = 12_000;

function openAssistRealtimeAPI() {
  return (window as unknown as { openAssistRealtime?: OpenAssistRealtimeAPI }).openAssistRealtime;
}

function mergeFloatChunks(chunks: Float32Array[]) {
  const length = chunks.reduce((total, chunk) => total + chunk.length, 0);
  const merged = new Float32Array(length);
  let offset = 0;
  chunks.forEach((chunk) => {
    merged.set(chunk, offset);
    offset += chunk.length;
  });
  return merged;
}

function downsampleToPCM16(input: Float32Array, inputSampleRate: number, outputSampleRate = realtimeSampleRate) {
  if (!input.length) return new Int16Array();
  const sampleRateRatio = inputSampleRate / outputSampleRate;
  const outputLength = Math.max(1, Math.round(input.length / sampleRateRatio));
  const output = new Int16Array(outputLength);
  for (let index = 0; index < outputLength; index += 1) {
    const start = Math.floor(index * sampleRateRatio);
    const end = Math.min(input.length, Math.floor((index + 1) * sampleRateRatio));
    let total = 0;
    const count = Math.max(1, end - start);
    for (let sourceIndex = start; sourceIndex < end; sourceIndex += 1) total += input[sourceIndex] ?? 0;
    const sample = Math.max(-1, Math.min(1, total / count));
    output[index] = sample < 0 ? sample * 0x8000 : sample * 0x7fff;
  }
  return output;
}

function pcm16ToBase64(samples: Int16Array) {
  const bytes = new Uint8Array(samples.buffer, samples.byteOffset, samples.byteLength);
  let binary = "";
  for (let index = 0; index < bytes.length; index += 1) binary += String.fromCharCode(bytes[index]);
  return btoa(binary);
}

function base64ToPCM16(data: string) {
  const binary = atob(data);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return new Int16Array(bytes.buffer);
}

function realtimePayloadText(payload: any) {
  if (typeof payload === "string") return payload;
  return payload?.delta ?? payload?.text ?? payload?.transcript ?? payload?.message ?? "";
}

function realtimePayloadRole(payload: any) {
  if (!payload || typeof payload !== "object") return "";
  return String(payload.role ?? payload.item?.role ?? payload.response?.role ?? "").trim().toLowerCase();
}

function realtimeEventNames(event: { type?: string; payload?: any }) {
  const payload = event.payload && typeof event.payload === "object" ? event.payload : {};
  return [
    event.type,
    payload.type,
    payload.method,
    payload.event?.type
  ].filter((value): value is string => typeof value === "string" && value.trim().length > 0);
}

function realtimePayloadAudio(payload: any): { data: string; sampleRate: number; numChannels: number } | null {
  const audio = payload?.audio && typeof payload.audio === "object" ? payload.audio : undefined;
  const data = typeof payload === "string" ? payload : payload?.data ?? audio?.data ?? payload?.delta;
  if (typeof data !== "string" || !data) return null;
  return {
    data,
    sampleRate: Number(audio?.sampleRate ?? audio?.sample_rate ?? payload?.sampleRate ?? payload?.sample_rate ?? realtimeSampleRate) || realtimeSampleRate,
    numChannels: Number(audio?.numChannels ?? audio?.channels ?? payload?.numChannels ?? payload?.channels ?? 1) || 1
  };
}

function mediaErrorName(error: unknown) {
  return error && typeof error === "object" && "name" in error ? String((error as { name?: unknown }).name ?? "") : "";
}

function mediaErrorMessage(error: unknown) {
  const name = mediaErrorName(error);
  if (name === "OverconstrainedError" || name === "NotFoundError") {
    return "Selected microphone was not found. Pick System Default in Settings, or reconnect the microphone.";
  }
  if (name === "NotAllowedError" || name === "SecurityError") {
    return "Microphone permission is blocked. Allow microphone access for Open Assist.";
  }
  if (name === "NotReadableError") {
    return "Microphone is busy or could not be opened.";
  }
  return error instanceof Error && error.message ? error.message : "Could not open the microphone.";
}

function noteTargetKey(target?: SelectedNoteTarget | null) {
  if (!target) return null;
  return target.scope === "thread"
    ? `thread:${target.threadID.toLowerCase()}:${target.noteID.toLowerCase()}`
    : `project:${target.projectID.toLowerCase()}:${target.noteID.toLowerCase()}`;
}

const manualModifierOnlyKeyCode = 65535;
const modifierFlags = {
  shift: 131072,
  control: 262144,
  option: 524288,
  command: 1048576,
  fn: 8388608
} as const;

const macKeyCodeByEventCode: Record<string, number> = {
  KeyA: 0,
  KeyS: 1,
  KeyD: 2,
  KeyF: 3,
  KeyH: 4,
  KeyG: 5,
  KeyZ: 6,
  KeyX: 7,
  KeyC: 8,
  KeyV: 9,
  KeyB: 11,
  KeyQ: 12,
  KeyW: 13,
  KeyE: 14,
  KeyR: 15,
  KeyY: 16,
  KeyT: 17,
  Digit1: 18,
  Digit2: 19,
  Digit3: 20,
  Digit4: 21,
  Digit6: 22,
  Digit5: 23,
  Equal: 24,
  Digit9: 25,
  Digit7: 26,
  Minus: 27,
  Digit8: 28,
  Digit0: 29,
  BracketRight: 30,
  KeyO: 31,
  KeyU: 32,
  BracketLeft: 33,
  KeyI: 34,
  KeyP: 35,
  Enter: 36,
  KeyL: 37,
  KeyJ: 38,
  Quote: 39,
  KeyK: 40,
  Semicolon: 41,
  Backslash: 42,
  Comma: 43,
  Slash: 44,
  KeyN: 45,
  KeyM: 46,
  Period: 47,
  Tab: 48,
  Space: 49,
  Backquote: 50,
  Backspace: 51,
  Escape: 53,
  F1: 122,
  F2: 120,
  F3: 99,
  F4: 118,
  F5: 96,
  F6: 97,
  F7: 98,
  F8: 100,
  F9: 101,
  F10: 109,
  F11: 103,
  F12: 111,
  F13: 105,
  F14: 107,
  F15: 113,
  F16: 106,
  F17: 64,
  F18: 79,
  F19: 80,
  F20: 90
};

const keyNameByMacCode: Record<number, string> = {
  0: "A",
  1: "S",
  2: "D",
  3: "F",
  4: "H",
  5: "G",
  6: "Z",
  7: "X",
  8: "C",
  9: "V",
  11: "B",
  12: "Q",
  13: "W",
  14: "E",
  15: "R",
  16: "Y",
  17: "T",
  18: "1",
  19: "2",
  20: "3",
  21: "4",
  22: "6",
  23: "5",
  24: "=",
  25: "9",
  26: "7",
  27: "-",
  28: "8",
  29: "0",
  30: "]",
  31: "O",
  32: "U",
  33: "[",
  34: "I",
  35: "P",
  36: "Return",
  37: "L",
  38: "J",
  39: "'",
  40: "K",
  41: ";",
  42: "\\",
  43: ",",
  44: "/",
  45: "N",
  46: "M",
  47: ".",
  48: "`",
  49: "Space",
  50: "`",
  51: "Delete",
  53: "Esc",
  63: "Fn",
  64: "F17",
  79: "F18",
  80: "F19",
  90: "F20",
  96: "F5",
  97: "F6",
  98: "F7",
  99: "F3",
  100: "F8",
  101: "F9",
  103: "F11",
  105: "F13",
  106: "F16",
  107: "F14",
  109: "F10",
  111: "F12",
  113: "F15",
  118: "F4",
  120: "F2",
  122: "F1"
};

const runtimeProviderOptions: RuntimeProviderOption[] = [
  { key: "codex", label: "Codex", detail: "Uses your signed-in ChatGPT/Codex subscription" },
  { key: "copilot", label: "Copilot", detail: "GitHub Copilot CLI session" },
  { key: "claudeCode", label: "Claude", detail: "Claude Code CLI session" },
  { key: "ollamaLocal", label: "Ollama", detail: "Local Ollama chat model" }
];

const codexPermissionOptions: CodexPermissionOption[] = [
  { value: "default", label: "Default permissions", shortLabel: "Default", detail: "Workspace profile, ask when needed", Icon: Shield },
  { value: "autoReview", label: "Auto-review", shortLabel: "Auto-review", detail: "Codex reviewer handles approval prompts", Icon: CheckCircle2 },
  { value: "fullAccess", label: "Full access", shortLabel: "Full access", detail: "No local sandbox or approval prompts", Icon: ShieldPlus },
  { value: "custom", label: "Custom (config.toml)", shortLabel: "Custom", detail: "Use your Codex config.toml settings", Icon: Settings }
];

const messageMotion = {
  initial: { opacity: 0, y: 8, scale: 0.985 },
  animate: { opacity: 1, y: 0, scale: 1 },
  transition: { duration: 0.2, ease: "easeOut" }
} as const;

const popoverMotion = {
  initial: { opacity: 0, y: 6, scale: 0.985 },
  animate: { opacity: 1, y: 0, scale: 1 },
  exit: { opacity: 0, y: 4, scale: 0.985 },
  transition: { duration: 0.16, ease: "easeOut" }
} as const;

const fallbackWorkspaceTargets: WorkspaceLaunchTargetSnapshot[] = [
  { id: "vscode", title: "VS Code", isInstalled: false, remembersAsPreferred: true, fallbackSymbol: "code", iconDataURL: "" },
  { id: "vscodeInsiders", title: "VS Code Insiders", isInstalled: false, remembersAsPreferred: true, fallbackSymbol: "code", iconDataURL: "" },
  { id: "cursor", title: "Cursor", isInstalled: false, remembersAsPreferred: true, fallbackSymbol: "command", iconDataURL: "" },
  { id: "windsurf", title: "Windsurf", isInstalled: false, remembersAsPreferred: true, fallbackSymbol: "wind", iconDataURL: "" },
  { id: "antigravity", title: "Antigravity", isInstalled: false, remembersAsPreferred: true, fallbackSymbol: "sparkles", iconDataURL: "" },
  { id: "finder", title: "Finder", isInstalled: true, remembersAsPreferred: false, fallbackSymbol: "folder", iconDataURL: "" },
  { id: "terminal", title: "Terminal", isInstalled: true, remembersAsPreferred: false, fallbackSymbol: "terminal", iconDataURL: "" },
  { id: "xcode", title: "Xcode", isInstalled: false, remembersAsPreferred: true, fallbackSymbol: "hammer", iconDataURL: "" },
  { id: "androidStudio", title: "Android Studio", isInstalled: false, remembersAsPreferred: true, fallbackSymbol: "code", iconDataURL: "" }
];

function readSystemThemeMode(): "dark" | "light" {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") return "dark";
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function normalizeThemeMode(mode?: string): "system" | "dark" | "light" {
  const normalized = String(mode || "System").trim().toLowerCase();
  if (normalized === "dark" || normalized === "light") return normalized;
  return "system";
}

function resolveThemeMode(mode: string | undefined, systemMode: "dark" | "light") {
  const normalized = normalizeThemeMode(mode);
  return normalized === "system" ? systemMode : normalized;
}

type CodexThemeTone = "light" | "dark";
type CodexThemeShare = {
  codeThemeId: string;
  variant: CodexThemeTone;
  theme: {
    accent: string;
    contrast: number;
    fonts: {
      code: string | null;
      ui: string | null;
    };
    ink: string;
    opaqueWindows: boolean;
    semanticColors: {
      diffAdded: string;
      diffRemoved: string;
      skill: string;
    };
    surface: string;
  };
};

function isHexColor(value: unknown): value is string {
  return typeof value === "string" && /^#[0-9a-fA-F]{6}$/.test(value.trim());
}

function sanitizeHexColor(value: unknown, fallback: string) {
  return isHexColor(value) ? value.trim().toUpperCase() : fallback;
}

function sanitizeContrast(value: unknown, fallback: number) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return fallback;
  return String(Math.min(100, Math.max(0, Math.round(numeric))));
}

function normalizeFontValue(value: unknown, fallback: string) {
  if (typeof value !== "string") return fallback;
  const trimmed = value.trim();
  return trimmed || fallback;
}

const systemUIFontStack = 'ui-sans-serif, -apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", "Inter", "Helvetica Neue", Arial, sans-serif';

const uiFontPresets: Array<{ label: string; value: string; sample: string }> = [
  { label: "System", value: systemUIFontStack, sample: "System" },
  { label: "SF Pro Display", value: '"SF Pro Display", -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif', sample: "SF Pro Display" },
  { label: "SF Pro Text", value: '"SF Pro Text", -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif', sample: "SF Pro Text" },
  { label: "New York (serif)", value: 'ui-serif, "New York", "Iowan Old Style", "Hoefler Text", Georgia, serif', sample: "New York" },
  { label: "Helvetica Neue", value: '"Helvetica Neue", Helvetica, Arial, sans-serif', sample: "Helvetica Neue" },
  { label: "Inter (if installed)", value: 'Inter, "Inter var", -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif', sample: "Inter" },
  { label: "Avenir Next", value: '"Avenir Next", Avenir, "Helvetica Neue", Arial, sans-serif', sample: "Avenir Next" },
  { label: "Optima", value: 'Optima, Candara, "Trebuchet MS", "Helvetica Neue", Arial, sans-serif', sample: "Optima" },
  { label: "Charter (serif)", value: 'Charter, "Iowan Old Style", "Hoefler Text", Georgia, serif', sample: "Charter" },
  { label: "Georgia (serif)", value: 'Georgia, "Iowan Old Style", "Hoefler Text", serif', sample: "Georgia" }
];

const codeFontPresets: Array<{ label: string; value: string }> = [
  { label: "System Mono", value: "ui-monospace, SFMono-Regular, Menlo, monospace" },
  { label: "SF Mono", value: '"SF Mono", SFMono-Regular, Menlo, Monaco, Consolas, monospace' },
  { label: "Menlo", value: 'Menlo, Monaco, Consolas, "Courier New", monospace' },
  { label: "Monaco", value: 'Monaco, Menlo, Consolas, "Courier New", monospace' },
  { label: "JetBrains Mono", value: '"JetBrains Mono", "Fira Code", ui-monospace, SFMono-Regular, Menlo, monospace' },
  { label: "Fira Code", value: '"Fira Code", "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace' }
];

function normalizeUIFontValue(value: unknown) {
  return normalizeFontValue(value, systemUIFontStack);
}

function normalizeUIFontSize(value: unknown) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return "13";
  return `${Math.min(18, Math.max(12, Math.round(parsed)))}`;
}

function normalizeRendererSettings(settings: SettingsSnapshot): SettingsSnapshot {
  return {
    ...settings,
    lightThemeUIFont: normalizeUIFontValue(settings.lightThemeUIFont),
    darkThemeUIFont: normalizeUIFontValue(settings.darkThemeUIFont),
    realtimeOpenAIAPIKeySource: settings.realtimeOpenAIAPIKeySource ?? "missing",
    realtimeDedicatedOpenAIAPIKeyConfigured: settings.realtimeDedicatedOpenAIAPIKeyConfigured ?? false,
    uiFontSize: normalizeUIFontSize(settings.uiFontSize)
  };
}

function normalizeRendererAppState(state: OpenAssistAppState): OpenAssistAppState {
  return {
    ...state,
    projects: state.projects ?? [],
    hiddenProjects: state.hiddenProjects ?? [],
    threads: state.threads ?? [],
    notes: state.notes ?? [],
    threadNotes: state.threadNotes ?? [],
    noteFolders: state.noteFolders ?? [],
    settings: normalizeRendererSettings(state.settings)
  };
}

function parseCodexThemeShare(value: string): CodexThemeShare {
  const trimmed = value.trim();
  if (!trimmed.startsWith(codexThemeSharePrefix)) {
    throw new Error("Theme must start with codex-theme-v1:");
  }
  const payload = trimmed.slice(codexThemeSharePrefix.length);
  const jsonText = payload.startsWith("{") ? payload : decodeURIComponent(payload);
  const parsed = JSON.parse(jsonText) as Partial<CodexThemeShare>;
  if (parsed.variant !== "light" && parsed.variant !== "dark") {
    throw new Error("Theme variant must be light or dark.");
  }
  const defaults = codexThemeDefaults[parsed.variant];
  const theme = parsed.theme ?? {};
  return {
    codeThemeId: typeof parsed.codeThemeId === "string" && parsed.codeThemeId.trim()
      ? parsed.codeThemeId.trim()
      : defaults.codeThemeId,
    variant: parsed.variant,
    theme: {
      accent: sanitizeHexColor(theme.accent, defaults.accent),
      contrast: Number(sanitizeContrast(theme.contrast, defaults.contrast)),
      fonts: {
        code: typeof theme.fonts?.code === "string" && theme.fonts.code.trim() ? theme.fonts.code.trim() : null,
        ui: typeof theme.fonts?.ui === "string" && theme.fonts.ui.trim() ? theme.fonts.ui.trim() : null
      },
      ink: sanitizeHexColor(theme.ink, defaults.ink),
      opaqueWindows: Boolean(theme.opaqueWindows),
      semanticColors: {
        diffAdded: sanitizeHexColor(theme.semanticColors?.diffAdded, defaults.semanticColors.diffAdded),
        diffRemoved: sanitizeHexColor(theme.semanticColors?.diffRemoved, defaults.semanticColors.diffRemoved),
        skill: sanitizeHexColor(theme.semanticColors?.skill, defaults.semanticColors.skill)
      },
      surface: sanitizeHexColor(theme.surface, defaults.surface)
    }
  };
}

function codexThemeFromSettings(settings: SettingsSnapshot, tone: CodexThemeTone): CodexThemeShare {
  const defaults = codexThemeDefaults[tone];
  const prefix = tone === "light" ? "lightTheme" : "darkTheme";
  const stringValue = (key: keyof SettingsSnapshot, fallback: string) =>
    typeof settings[key] === "string" && String(settings[key]).trim() ? String(settings[key]).trim() : fallback;
  return {
    codeThemeId: stringValue(`${prefix}CodeThemeID` as keyof SettingsSnapshot, defaults.codeThemeId),
    variant: tone,
    theme: {
      accent: sanitizeHexColor(settings[`${prefix}Accent` as keyof SettingsSnapshot], defaults.accent),
      contrast: Number(sanitizeContrast(settings[`${prefix}Contrast` as keyof SettingsSnapshot], defaults.contrast)),
      fonts: {
        code: normalizeFontValue(settings[`${prefix}CodeFont` as keyof SettingsSnapshot], defaults.fonts.code),
        ui: normalizeFontValue(settings[`${prefix}UIFont` as keyof SettingsSnapshot], defaults.fonts.ui)
      },
      ink: sanitizeHexColor(settings[`${prefix}Foreground` as keyof SettingsSnapshot], defaults.ink),
      opaqueWindows: !Boolean(settings[`${prefix}TranslucentSidebar` as keyof SettingsSnapshot]),
      semanticColors: {
        diffAdded: sanitizeHexColor(settings[`${prefix}DiffAdded` as keyof SettingsSnapshot], defaults.semanticColors.diffAdded),
        diffRemoved: sanitizeHexColor(settings[`${prefix}DiffRemoved` as keyof SettingsSnapshot], defaults.semanticColors.diffRemoved),
        skill: sanitizeHexColor(settings[`${prefix}Skill` as keyof SettingsSnapshot], defaults.semanticColors.skill)
      },
      surface: sanitizeHexColor(settings[`${prefix}Background` as keyof SettingsSnapshot], defaults.surface)
    }
  };
}

function codexThemeShareString(settings: SettingsSnapshot, tone: CodexThemeTone) {
  return `${codexThemeSharePrefix}${JSON.stringify(codexThemeFromSettings(settings, tone))}`;
}

function modifierCount(modifiers: number) {
  return [modifierFlags.fn, modifierFlags.control, modifierFlags.option, modifierFlags.shift, modifierFlags.command]
    .reduce((count, flag) => count + ((modifiers & flag) ? 1 : 0), 0);
}

function shortcutSegments(keyCode: number, modifiers: number) {
  const segments: string[] = [];
  if (modifiers & modifierFlags.fn) segments.push("Fn");
  if (modifiers & modifierFlags.control) segments.push("Control");
  if (modifiers & modifierFlags.option) segments.push("Option");
  if (modifiers & modifierFlags.shift) segments.push("Shift");
  if (modifiers & modifierFlags.command) segments.push("Command");
  if (keyCode !== manualModifierOnlyKeyCode) segments.push(keyNameByMacCode[keyCode] ?? `Key ${keyCode}`);
  return segments.length ? segments : ["Not set"];
}

function shortcutLabel(keyCode: number, modifiers: number) {
  return shortcutSegments(keyCode, modifiers).join(" ");
}

const shortcutRows: Array<{
  target: ShortcutTarget;
  label: string;
  shortLabel: string;
  keyCodeKey:
    | "holdToTalkShortcutKeyCode"
    | "continuousToggleShortcutKeyCode"
    | "assistantLiveVoiceShortcutKeyCode"
    | "assistantCompactShortcutKeyCode"
    | "screenAnalysisShortcutKeyCode";
  modifiersKey:
    | "holdToTalkShortcutModifiers"
    | "continuousToggleShortcutModifiers"
    | "assistantLiveVoiceShortcutModifiers"
    | "assistantCompactShortcutModifiers"
    | "screenAnalysisShortcutModifiers";
  fallbackKeyCode: number;
  fallbackModifiers: number;
}> = [
  {
    target: "holdToTalk",
    label: "Hold-to-talk shortcut",
    shortLabel: "hold-to-talk shortcut",
    keyCodeKey: "holdToTalkShortcutKeyCode",
    modifiersKey: "holdToTalkShortcutModifiers",
    fallbackKeyCode: 49,
    fallbackModifiers: modifierFlags.control | modifierFlags.shift
  },
  {
    target: "continuousToggle",
    label: "Continuous toggle shortcut",
    shortLabel: "continuous toggle shortcut",
    keyCodeKey: "continuousToggleShortcutKeyCode",
    modifiersKey: "continuousToggleShortcutModifiers",
    fallbackKeyCode: 49,
    fallbackModifiers: modifierFlags.control | modifierFlags.option | modifierFlags.command
  },
  {
    target: "assistantLiveVoice",
    label: "Agent voice shortcut",
    shortLabel: "agent shortcut",
    keyCodeKey: "assistantLiveVoiceShortcutKeyCode",
    modifiersKey: "assistantLiveVoiceShortcutModifiers",
    fallbackKeyCode: 37,
    fallbackModifiers: modifierFlags.control | modifierFlags.option | modifierFlags.command
  },
  {
    target: "assistantCompact",
    label: "Compact assistant shortcut",
    shortLabel: "compact assistant shortcut",
    keyCodeKey: "assistantCompactShortcutKeyCode",
    modifiersKey: "assistantCompactShortcutModifiers",
    fallbackKeyCode: 1,
    fallbackModifiers: modifierFlags.control | modifierFlags.option | modifierFlags.command
  },
  {
    target: "screenAnalysis",
    label: "Screen analysis shortcut",
    shortLabel: "screen analysis shortcut",
    keyCodeKey: "screenAnalysisShortcutKeyCode",
    modifiersKey: "screenAnalysisShortcutModifiers",
    fallbackKeyCode: 1,
    fallbackModifiers: modifierFlags.shift | modifierFlags.option | modifierFlags.command
  }
];

const shortcutSettingGroups: Array<{
  id: "dictation" | "assistant";
  title: string;
  subtitle: string;
  targets: ShortcutTarget[];
}> = [
  {
    id: "dictation",
    title: "Dictation & Voice",
    subtitle: "Recording, continuous voice, and agent voice hotkeys.",
    targets: ["holdToTalk", "continuousToggle", "assistantLiveVoice"]
  },
  {
    id: "assistant",
    title: "Assistant & Screen",
    subtitle: "Compact assistant and screen analysis hotkeys.",
    targets: ["assistantCompact", "screenAnalysis"]
  }
];

function shortcutValueFor(settings: SettingsSnapshot | undefined, target: ShortcutTarget) {
  const row = shortcutRows.find((item) => item.target === target) ?? shortcutRows[0];
  const keyCode = settings?.[row.keyCodeKey];
  const modifiers = settings?.[row.modifiersKey];
  return {
    ...row,
    keyCode: typeof keyCode === "number" ? keyCode : row.fallbackKeyCode,
    modifiers: typeof modifiers === "number" ? modifiers : row.fallbackModifiers
  };
}

function shortcutConflictMessage(
  target: ShortcutTarget,
  candidate: { keyCode: number; modifiers: number },
  settings: SettingsSnapshot | undefined
) {
  const conflict = shortcutRows.find((row) => {
    if (row.target === target) return false;
    const current = shortcutValueFor(settings, row.target);
    return current.keyCode === candidate.keyCode && current.modifiers === candidate.modifiers;
  });
  if (conflict) {
    return `${shortcutLabel(candidate.keyCode, candidate.modifiers)} already matches the ${conflict.shortLabel}.`;
  }
  if (candidate.keyCode === 9 && candidate.modifiers === (modifierFlags.option | modifierFlags.command)) {
    return "Shortcut cannot match Paste Last Transcript (Option Command V).";
  }
  return undefined;
}

function readableProviderError(error: unknown) {
  const raw = error instanceof Error ? error.message : String(error ?? "");
  const cleaned = raw
    .replace(/^Error invoking remote method '[^']+':\s*/i, "")
    .replace(/^Error:\s*/i, "")
    .trim();
  return cleaned || "The provider failed before returning a response.";
}

function eventModifierRaw(event: KeyboardEvent) {
  let raw = 0;
  if (event.shiftKey) raw |= modifierFlags.shift;
  if (event.ctrlKey) raw |= modifierFlags.control;
  if (event.altKey) raw |= modifierFlags.option;
  if (event.metaKey) raw |= modifierFlags.command;
  if (event.getModifierState?.("Fn") || event.getModifierState?.("FnLock")) raw |= modifierFlags.fn;
  return raw;
}

function isValidShortcut(keyCode: number, modifiers: number) {
  const count = modifierCount(modifiers);
  if (keyCode === manualModifierOnlyKeyCode) return count >= 2 && count <= 4;
  return count >= 1 && count <= 3;
}

function shortcutFromKeyboardEvent(event: KeyboardEvent): { keyCode: number; modifiers: number } | null {
  const modifiers = eventModifierRaw(event);
  const keyCode = macKeyCodeByEventCode[event.code];
  if (typeof keyCode === "number") {
    if (["ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight", "AltLeft", "AltRight", "MetaLeft", "MetaRight", "Fn"].includes(event.code)) {
      return modifierCount(modifiers) >= 2 ? { keyCode: manualModifierOnlyKeyCode, modifiers } : null;
    }
    return { keyCode, modifiers };
  }
  if (modifierCount(modifiers) >= 2 && ["Shift", "Control", "Alt", "Meta"].includes(event.key)) {
    return { keyCode: manualModifierOnlyKeyCode, modifiers };
  }
  return null;
}

const promptRewriteProviderOptions = [
  "OpenAI",
  "Google AI Studio (Gemini)",
  "OpenRouter",
  "Groq",
  "Anthropic",
  "Ollama (Local)"
];

const transcriptionEngineOptions = ["Apple Speech", "whisper.cpp", "Cloud Providers"];
const whisperModelOptions = [
  "tiny",
  "tiny.en",
  "tiny-q5_1",
  "tiny.en-q5_1",
  "tiny-q8_0",
  "base",
  "base.en",
  "base-q5_1",
  "base.en-q5_1",
  "base-q8_0",
  "small",
  "small.en",
  "small.en-tdrz",
  "small-q5_1",
  "small.en-q5_1",
  "small-q8_0",
  "medium",
  "medium.en",
  "medium-q5_0",
  "medium.en-q5_0",
  "medium-q8_0",
  "large-v1",
  "large-v2",
  "large-v2-q5_0",
  "large-v2-q8_0",
  "large-v3",
  "large-v3-q5_0",
  "large-v3-turbo",
  "large-v3-turbo-q5_0",
  "large-v3-turbo-q8_0"
];
const assistantVoiceEngineOptions = [
  { value: "kokoroLocal", label: "Kokoro Local" },
  { value: "humeOctave", label: "Hume Octave" },
  { value: "macos", label: "macOS" }
];
const kokoroVoiceOptions = [
  { value: "af_heart", label: "Heart" },
  { value: "af_bella", label: "Bella" },
  { value: "af_nova", label: "Nova" },
  { value: "af_sarah", label: "Sarah" },
  { value: "am_michael", label: "Michael" },
  { value: "am_puck", label: "Puck" },
  { value: "bf_emma", label: "Emma" },
  { value: "bm_george", label: "George" }
];
const colorThemeOptions = [
  "Ocean",
  "Violet",
  "Midnight",
  "Forest",
  "Rose",
  "Sunset",
  "Arctic",
  "Slate",
  "Amethyst",
  "Noir Gold"
];
const themeModeOptions = ["System", "Dark", "Light"];
const appChromeStyleOptions = ["Glass (High Contrast)", "Classic"];
const reduceMotionOptions = ["System", "On", "Off"];
const codexThemeSharePrefix = "codex-theme-v1:";
const codexThemePresets: Record<string, string> = {
  ayu: "Ayu",
  absolutely: "Absolutely",
  codex: "Codex",
  catppuccin: "Catppuccin",
  dracula: "Dracula",
  everforest: "Everforest",
  github: "GitHub",
  gruvbox: "Gruvbox",
  linear: "Linear",
  lobster: "Lobster",
  material: "Material",
  matrix: "Matrix",
  monokai: "Monokai",
  "night-owl": "Night Owl",
  nord: "Nord",
  notion: "Notion",
  oscurange: "Oscurange",
  one: "One",
  proof: "Proof",
  raycast: "Raycast",
  "rose-pine": "Rose Pine",
  sentry: "Sentry",
  solarized: "Solarized",
  "tokyo-night": "Tokyo Night",
  temple: "Temple",
  vercel: "Vercel",
  "vscode-plus": "VS Code Plus",
  xcode: "Xcode"
};
const codexCodeThemeOptions = Object.entries(codexThemePresets).map(([value, label]) => ({ value, label }));
type CodexCodeThemeSeed = {
  surface: string;
  ink: string;
  accent: string;
  diffAdded: string;
  diffRemoved: string;
  skill: string;
  keyword: string;
  builtin: string;
  function: string;
  string: string;
  number: string;
  comment: string;
  contrast?: number;
  opaqueWindows?: boolean;
};
const codexCodeThemeSeeds: Record<string, Partial<Record<CodexThemeTone, CodexCodeThemeSeed>>> = {
  ayu: { dark: { surface: "#0B0E14", ink: "#BFBDB6", accent: "#E6B450", diffAdded: "#7FD962", diffRemoved: "#F26D78", skill: "#CDA1FA", keyword: "#FF8F40", string: "#AAD94C", number: "#D2A6FF", comment: "#ACB6BF", function: "#FFB454", builtin: "#59C2FF" } },
  absolutely: {
    dark: { surface: "#2D2D2B", ink: "#F9F9F7", accent: "#CC7D5E", diffAdded: "#40C977", diffRemoved: "#FA423E", skill: "#AD7BF9", keyword: "#FF5F38", string: "#00C853", number: "#FF5F38", comment: "#B2B2B0", function: "#F9F9F7", builtin: "#D28E73" },
    light: { surface: "#F9F9F7", ink: "#2D2D2B", accent: "#CC7D5E", diffAdded: "#00A240", diffRemoved: "#BA2623", skill: "#924FF7", keyword: "#FF5F38", string: "#00C853", number: "#FF5F38", comment: "#939391", function: "#2D2D2B", builtin: "#BC7559" }
  },
  catppuccin: {
    dark: { surface: "#1E1E2E", ink: "#CDD6F4", accent: "#CBA6F7", diffAdded: "#A6E3A1", diffRemoved: "#F38BA8", skill: "#CBA6F7", keyword: "#FAB387", string: "#A6E3A1", number: "#FAB387", comment: "#9399B2", function: "#89B4FA", builtin: "#CBA6F7" },
    light: { surface: "#EFF1F5", ink: "#4C4F69", accent: "#8839EF", diffAdded: "#40A02B", diffRemoved: "#D20F39", skill: "#8839EF", keyword: "#FE640B", string: "#40A02B", number: "#FE640B", comment: "#7C7F93", function: "#1E66F5", builtin: "#8839EF" }
  },
  codex: {
    dark: { surface: "#111111", ink: "#FCFCFC", accent: "#0169CC", diffAdded: "#00A240", diffRemoved: "#E02E2A", skill: "#B06DFF", keyword: "#F67576", string: "#85DF7B", number: "#6DCBF4", comment: "#999999", function: "#B06DFF", builtin: "#B06DFF" },
    light: { surface: "#FFFFFF", ink: "#0D0D0D", accent: "#0169CC", diffAdded: "#00A240", diffRemoved: "#E02E2A", skill: "#751ED9", keyword: "#D53538", string: "#008809", number: "#0071EA", comment: "#666666", function: "#751ED9", builtin: "#751ED9" }
  },
  dracula: { dark: { surface: "#282A36", ink: "#F8F8F2", accent: "#FF79C6", diffAdded: "#50FA7B", diffRemoved: "#FF5555", skill: "#FF79C6", keyword: "#BD93F9", string: "#FF79C6", number: "#FF79C6", comment: "#6272A4", function: "#50FA7B", builtin: "#8BE9FD" } },
  everforest: {
    dark: { surface: "#2D353B", ink: "#D3C6AA", accent: "#A7C080", diffAdded: "#A7C080", diffRemoved: "#E67E80", skill: "#D699B6", keyword: "#E67E80", string: "#DBBC7F", number: "#D699B6", comment: "#859289", function: "#A7C080", builtin: "#83C092" },
    light: { surface: "#FDF6E3", ink: "#5C6A72", accent: "#93B259", diffAdded: "#8DA101", diffRemoved: "#F85552", skill: "#DF69BA", keyword: "#F85552", string: "#DFA000", number: "#DF69BA", comment: "#939F91", function: "#8DA101", builtin: "#35A77C" }
  },
  github: {
    dark: { surface: "#0D1117", ink: "#E6EDF3", accent: "#1F6FEB", diffAdded: "#3FB950", diffRemoved: "#F85149", skill: "#BC8CFF", keyword: "#FF7B72", string: "#8B949E", number: "#1F6FEB", comment: "#8B949E", function: "#D2A8FF", builtin: "#7EE787" },
    light: { surface: "#FFFFFF", ink: "#1F2328", accent: "#0969DA", diffAdded: "#1A7F37", diffRemoved: "#CF222E", skill: "#8250DF", keyword: "#CF222E", string: "#6E7781", number: "#0969DA", comment: "#6E7781", function: "#8250DF", builtin: "#116329" }
  },
  gruvbox: {
    dark: { surface: "#282828", ink: "#EBDBB2", accent: "#458588", diffAdded: "#EBDBB2", diffRemoved: "#CC241D", skill: "#B16286", keyword: "#FB4934", string: "#B8BB26", number: "#458588", comment: "#928374", function: "#689D6A", builtin: "#689D6A" },
    light: { surface: "#FBF1C7", ink: "#3C3836", accent: "#458588", diffAdded: "#3C3836", diffRemoved: "#CC241D", skill: "#B16286", keyword: "#9D0006", string: "#79740E", number: "#458588", comment: "#928374", function: "#689D6A", builtin: "#689D6A" }
  },
  linear: {
    dark: { surface: "#0F0F11", ink: "#E3E4E6", accent: "#606ACC", diffAdded: "#40C977", diffRemoved: "#FA423E", skill: "#AD7BF9", keyword: "#8C97FF", string: "#7AD9C0", number: "#F5C56A", comment: "#636B7B", function: "#C2A1FF", builtin: "#73B7FF", opaqueWindows: true },
    light: { surface: "#FCFCFD", ink: "#1B1B1B", accent: "#5E6AD2", diffAdded: "#00A240", diffRemoved: "#BA2623", skill: "#924FF7", keyword: "#5E6AD2", string: "#0F8F83", number: "#B4831F", comment: "#8A93A6", function: "#8160D8", builtin: "#4380D8", opaqueWindows: true }
  },
  lobster: { dark: { surface: "#111827", ink: "#E4E4E7", accent: "#FF5C5C", diffAdded: "#40C977", diffRemoved: "#FA423E", skill: "#AD7BF9", keyword: "#FF5C5C", string: "#14B8A6", number: "#F59E0B", comment: "#71717A", function: "#22C55E", builtin: "#3B82F6" } },
  material: { dark: { surface: "#212121", ink: "#EEFFFF", accent: "#80CBC4", diffAdded: "#C3E88D", diffRemoved: "#F07178", skill: "#C792EA", keyword: "#F78C6C", string: "#C3E88D", number: "#F78C6C", comment: "#545454", function: "#EEFFFF", builtin: "#89DDFF" } },
  matrix: { dark: { surface: "#040805", ink: "#B8FFCA", accent: "#1EFF5A", diffAdded: "#40C977", diffRemoved: "#FA423E", skill: "#AD7BF9", keyword: "#1EFF5A", string: "#7DFF95", number: "#55FF7D", comment: "#3F8F52", function: "#9BFFB8", builtin: "#3ADF6A", opaqueWindows: true } },
  monokai: { dark: { surface: "#272822", ink: "#F8F8F2", accent: "#F8F8F0", diffAdded: "#86B42B", diffRemoved: "#C4265E", skill: "#8C6BC8", keyword: "#F92672", string: "#F8F8F2", number: "#AE81FF", comment: "#88846F", function: "#A6E22E", builtin: "#A6E22E" } },
  "night-owl": { dark: { surface: "#011627", ink: "#D6DEEB", accent: "#44596B", diffAdded: "#C5E478", diffRemoved: "#EF5350", skill: "#C792EA", keyword: "#5CA7E4", string: "#ECC48D", number: "#F78C6C", comment: "#637777", function: "#C792EA", builtin: "#FFCB8B" } },
  nord: { dark: { surface: "#2E3440", ink: "#D8DEE9", accent: "#88C0D0", diffAdded: "#A3BE8C", diffRemoved: "#BF616A", skill: "#B48EAD", keyword: "#81A1C1", string: "#A3BE8C", number: "#B48EAD", comment: "#616E88", function: "#88C0D0", builtin: "#8FBCBB" } },
  notion: {
    dark: { surface: "#191919", ink: "#D9D9D8", accent: "#3183D8", diffAdded: "#40C977", diffRemoved: "#FA423E", skill: "#AD7BF9", keyword: "#569CD6", string: "#CE9178", number: "#B5CEA8", comment: "#6A9955", function: "#DCDCAA", builtin: "#4EC9B0", opaqueWindows: true },
    light: { surface: "#FFFFFF", ink: "#37352F", accent: "#3183D8", diffAdded: "#00A240", diffRemoved: "#BA2623", skill: "#924FF7", keyword: "#0000FF", string: "#A31515", number: "#098658", comment: "#008000", function: "#795E26", builtin: "#267F99", opaqueWindows: true }
  },
  oscurange: { dark: { surface: "#0B0B0F", ink: "#E6E6E6", accent: "#F9B98C", diffAdded: "#40C977", diffRemoved: "#FA423E", skill: "#AD7BF9", keyword: "#9099A1", string: "#E6E6E6", number: "#F9B98C", comment: "#46474F", function: "#F9B98C", builtin: "#9592A4" } },
  one: {
    dark: { surface: "#282C34", ink: "#ABB2BF", accent: "#4D78CC", diffAdded: "#8CC265", diffRemoved: "#E05561", skill: "#C162DE", keyword: "#C678DD", string: "#98C379", number: "#D19A66", comment: "#5C6370", function: "#61AFEF", builtin: "#56B6C2" },
    light: { surface: "#FAFAFA", ink: "#383A42", accent: "#526FFF", diffAdded: "#00A240", diffRemoved: "#BA2623", skill: "#924FF7", keyword: "#A626A4", string: "#50A14F", number: "#986801", comment: "#A0A1A7", function: "#0184BC", builtin: "#C18401" }
  },
  proof: { light: { surface: "#F5F3ED", ink: "#2F312D", accent: "#3D755D", diffAdded: "#00A240", diffRemoved: "#BA2623", skill: "#924FF7", keyword: "#5F6AC2", string: "#3D755D", number: "#D3B45B", comment: "#8B877C", function: "#3D755D", builtin: "#5F6AC2" } },
  raycast: {
    dark: { surface: "#101010", ink: "#FEFEFE", accent: "#FF6363", diffAdded: "#59D499", diffRemoved: "#FF6363", skill: "#CF2F98", keyword: "#FFFFFF", string: "#FF6363", number: "#FFFFFF", comment: "#666666", function: "#999999", builtin: "#999999" },
    light: { surface: "#FFFFFF", ink: "#030303", accent: "#FF6363", diffAdded: "#006B4F", diffRemoved: "#B12424", skill: "#9A1B6E", keyword: "#000000", string: "#C03030", number: "#000000", comment: "#999999", function: "#666666", builtin: "#666666" }
  },
  "rose-pine": {
    dark: { surface: "#232136", ink: "#E0DEF4", accent: "#EA9A97", diffAdded: "#9CCFD8", diffRemoved: "#908CAA", skill: "#C4A7E7", keyword: "#3E8FB0", string: "#F6C177", number: "#EA9A97", comment: "#6E6A86", function: "#EB6F92", builtin: "#9CCFD8" },
    light: { surface: "#FAF4ED", ink: "#575279", accent: "#D7827E", diffAdded: "#56949F", diffRemoved: "#797593", skill: "#907AA9", keyword: "#286983", string: "#EA9D34", number: "#D7827E", comment: "#9893A5", function: "#B4637A", builtin: "#56949F" }
  },
  sentry: { dark: { surface: "#2D2935", ink: "#E6DFF9", accent: "#7055F6", diffAdded: "#40C977", diffRemoved: "#FA423E", skill: "#AD7BF9", keyword: "#7055F6", string: "#8EE6D7", number: "#F4C46A", comment: "#8D849F", function: "#A58CFF", builtin: "#C39BFF" } },
  solarized: {
    dark: { surface: "#002B36", ink: "#839496", accent: "#D30102", diffAdded: "#859900", diffRemoved: "#DC322F", skill: "#D33682", keyword: "#859900", string: "#839496", number: "#D33682", comment: "#586E75", function: "#268BD2", builtin: "#CB4B16" },
    light: { surface: "#FDF6E3", ink: "#657B83", accent: "#B58900", diffAdded: "#859900", diffRemoved: "#DC322F", skill: "#D33682", keyword: "#859900", string: "#657B83", number: "#D33682", comment: "#93A1A1", function: "#268BD2", builtin: "#CB4B16" }
  },
  "tokyo-night": { dark: { surface: "#1A1B26", ink: "#A9B1D6", accent: "#3D59A1", diffAdded: "#449DAB", diffRemoved: "#914C54", skill: "#9D7CD8", keyword: "#5A638C", string: "#51597D", number: "#FF9E64", comment: "#51597D", function: "#0DB9D7", builtin: "#5A638C" } },
  temple: { dark: { surface: "#02120C", ink: "#C7E6DA", accent: "#E4F222", diffAdded: "#40C977", diffRemoved: "#FA423E", skill: "#AD7BF9", keyword: "#E4F222", string: "#E4F222", number: "#E4F222", comment: "#394D46", function: "#E4F222", builtin: "#859419" } },
  vercel: {
    dark: { surface: "#000000", ink: "#EDEDED", accent: "#006EFE", diffAdded: "#40C977", diffRemoved: "#FA423E", skill: "#AD7BF9", keyword: "#006EFE", string: "#00AD3A", number: "#9540D5", comment: "#666666", function: "#9540D5", builtin: "#52A8FF", contrast: 50, opaqueWindows: true },
    light: { surface: "#FFFFFF", ink: "#171717", accent: "#006AFF", diffAdded: "#00A240", diffRemoved: "#BA2623", skill: "#924FF7", keyword: "#006AFF", string: "#28A948", number: "#A100F8", comment: "#666666", function: "#A100F8", builtin: "#0059D1", contrast: 40, opaqueWindows: true }
  },
  "vscode-plus": {
    dark: { surface: "#1E1E1E", ink: "#D4D4D4", accent: "#007ACC", diffAdded: "#40C977", diffRemoved: "#FA423E", skill: "#AD7BF9", keyword: "#B5CEA8", string: "#D4D4D4", number: "#B5CEA8", comment: "#6A9955", function: "#569CD6", builtin: "#9CDCFE" },
    light: { surface: "#FFFFFF", ink: "#000000", accent: "#007ACC", diffAdded: "#00A240", diffRemoved: "#BA2623", skill: "#924FF7", keyword: "#098658", string: "#000000", number: "#098658", comment: "#008000", function: "#0000FF", builtin: "#E50000" }
  },
  xcode: {
    dark: { surface: "#1F1F24", ink: "#FFFFFF", accent: "#5482FF", diffAdded: "#40C977", diffRemoved: "#FA423E", skill: "#AD7BF9", keyword: "#FC5FA3", string: "#FC6A5D", number: "#D0BF69", comment: "#6C7986", function: "#67B7A4", builtin: "#5DD8FF" },
    light: { surface: "#FFFFFF", ink: "#000000", accent: "#0E0EFF", diffAdded: "#00A240", diffRemoved: "#BA2623", skill: "#924FF7", keyword: "#9B2393", string: "#C41A16", number: "#1C00CF", comment: "#5D6C79", function: "#326D74", builtin: "#0B4F79" }
  }
};
function codexSeedFor(codeThemeId: string, tone: CodexThemeTone): CodexCodeThemeSeed {
  return codexCodeThemeSeeds[codeThemeId]?.[tone]
    ?? codexCodeThemeSeeds[codeThemeId]?.dark
    ?? codexCodeThemeSeeds.github[tone]
    ?? codexCodeThemeSeeds.codex[tone]
    ?? codexCodeThemeSeeds.codex.dark!;
}
const codexThemeDefaults = {
  light: {
    accent: "#0169CC",
    surface: "#FFFFFF",
    ink: "#0D0D0D",
    contrast: 45,
    codeThemeId: "codex",
    fonts: {
      ui: systemUIFontStack,
      code: "ui-monospace, SFMono-Regular, Menlo, monospace"
    },
    semanticColors: { diffAdded: "#00a240", diffRemoved: "#ba2623", skill: "#924ff7" }
  },
  dark: {
    accent: "#1F6FEB",
    surface: "#0D1117",
    ink: "#E6EDF3",
    contrast: 89,
    codeThemeId: "github",
    fonts: {
      ui: systemUIFontStack,
      code: "ui-monospace, SFMono-Regular, Menlo, monospace"
    },
    semanticColors: { diffAdded: "#40c977", diffRemoved: "#fa423e", skill: "#ad7bf9" }
  }
} as const;
const waveformThemeOptions = [
  "Vibrant Spectrum",
  "Professional Tech",
  "Monochrome",
  "Neon Lagoon",
  "Sunset Candy",
  "Cosmic Pop",
  "Mint Blush"
];
const colorThemeMeta: Record<string, { description: string; swatches: [string, string, string] }> = {
  Ocean: { description: "Codex-like graphite with soft blue and mint highlights.", swatches: ["#0b0c0e", "#8fb0ff", "#72d99d"] },
  Violet: { description: "Dark violet with soft lavender highlights.", swatches: ["#15101d", "#aab2ff", "#b1a3ff"] },
  Midnight: { description: "Neutral midnight with crisp blue highlights.", swatches: ["#101218", "#6f9dff", "#a9c4ff"] },
  Forest: { description: "Deep green with quiet mint highlights.", swatches: ["#0d1712", "#70c894", "#a9edc2"] },
  Rose: { description: "Muted rose with warm pink highlights.", swatches: ["#1b1118", "#e490ac", "#ffc0d0"] },
  Sunset: { description: "Warm dusk with amber highlights.", swatches: ["#18120c", "#e0a14f", "#ffd18a"] },
  Arctic: { description: "Cool graphite with icy cyan highlights.", swatches: ["#101821", "#90d7ec", "#c5f5ff"] },
  Slate: { description: "Quiet slate with classic blue highlights.", swatches: ["#101218", "#6f9dff", "#a9c4ff"] },
  Amethyst: { description: "Dark amethyst with soft purple highlights.", swatches: ["#121022", "#b696ff", "#d8c8ff"] },
  "Noir Gold": { description: "Near-black with antique gold accents.", swatches: ["#080806", "#a87f2d", "#c79d42"] }
};
function codexThemePresetPatch(theme: string, tone: CodexThemeTone) {
  const meta = colorThemeMeta[theme] ?? colorThemeMeta.Ocean;
  return {
    background: tone === "light" ? "#FFFFFF" : meta.swatches[0],
    foreground: tone === "light" ? "#0D0D0D" : "#E6EDF3",
    accent: meta.swatches[1],
    skill: meta.swatches[2],
    diffAdded: tone === "light" ? "#00A240" : "#40C977",
    diffRemoved: tone === "light" ? "#BA2623" : "#FA423E"
  };
}
const cloudTranscriptionProviderOptions = [
  "OpenAI",
  "Groq",
  "Deepgram",
  "Google Gemini (AI Studio)",
  "ChatGPT / Codex Session"
];
const realtimeOpenAIModelOptions = [
  { value: "gpt-realtime-mini", label: "gpt-realtime-mini · lower cost" },
  { value: "gpt-realtime", label: "gpt-realtime · best quality" }
];
const realtimeOpenAIVoiceOptions = [
  { value: "marin", label: "marin · recommended" },
  { value: "cedar", label: "cedar · recommended" },
  { value: "alloy", label: "alloy" },
  { value: "ash", label: "ash" },
  { value: "ballad", label: "ballad" },
  { value: "coral", label: "coral" },
  { value: "echo", label: "echo" },
  { value: "sage", label: "sage" },
  { value: "shimmer", label: "shimmer" },
  { value: "verse", label: "verse" }
];
const dictationSoundOptions = [
  "None",
  "Basso",
  "Blow",
  "Bottle",
  "Frog",
  "Funk",
  "Glass",
  "Hero",
  "Ping",
  "Pop",
  "Purr",
  "Sosumi",
  "Submarine",
  "Tink"
];
const dictationSoundRows: Array<{
  key: SettingsUpdateKey;
  cue: "startListening" | "stopListening" | "processing" | "pasted" | "correctionLearned";
  label: string;
}> = [
  { key: "dictationStartSoundName", cue: "startListening", label: "Start listening" },
  { key: "dictationStopSoundName", cue: "stopListening", label: "Stop / finalize" },
  { key: "dictationProcessingSoundName", cue: "processing", label: "Processing" },
  { key: "dictationPastedSoundName", cue: "pasted", label: "Pasted" },
  { key: "dictationCorrectionLearnedSoundName", cue: "correctionLearned", label: "Correction learned" }
];

const setupRequiredDetails: Record<RuntimeProviderKey, string> = {
  codex: "Install or sign in to Codex from Open Assist",
  copilot: "Install or sign in to GitHub Copilot",
  claudeCode: "Install or sign in to Claude Code",
  ollamaLocal: "Open Local AI Setup for Ollama"
};

function modelOption(id: string, displayName = id, description = displayName, disabled = false): ProviderModelOption {
  return { id, displayName, description, hidden: false, isInstalled: true, disabled };
}

const fallbackModelOptionsByProvider: Partial<Record<ProviderKey, ProviderModelOption[]>> = {
  codex: [
    modelOption("gpt-5.5", "GPT-5.5"),
    modelOption("gpt-5.4", "GPT-5.4"),
    modelOption("gpt-5.2", "GPT-5.2"),
    modelOption("gpt-5.3-codex", "GPT-5.3-Codex")
  ],
  claudeCode: [
    modelOption("sonnet", "Claude Sonnet"),
    modelOption("opus", "Claude Opus"),
    modelOption("haiku", "Claude Haiku")
  ],
  copilot: [
    modelOption("auto", "Auto", "Let Copilot pick the best model"),
    modelOption("gpt-5.4", "GPT-5.4"),
    modelOption("gpt-5.3-codex", "GPT-5.3-Codex"),
    modelOption("gpt-5.2-codex", "GPT-5.2-Codex"),
    modelOption("gpt-5.2", "GPT-5.2"),
    modelOption("gpt-5.4-mini", "GPT-5.4 mini"),
    modelOption("gpt-5-mini", "GPT-5 mini"),
    modelOption("gpt-4.1", "GPT-4.1"),
    modelOption("claude-sonnet-4.6", "Claude Sonnet 4.6"),
    modelOption("claude-sonnet-4.5", "Claude Sonnet 4.5"),
    modelOption("claude-haiku-4.5", "Claude Haiku 4.5")
  ],
  ollamaLocal: [
    modelOption("gemma4:e2b"),
    modelOption("llama3.1"),
    modelOption("gpt-oss:20b")
  ]
};

function fallbackModelOptionsForProvider(provider: ProviderKey) {
  return fallbackModelOptionsByProvider[provider] ?? [];
}

function providerModelIDs(provider: ProviderKey, loadedModels?: ProviderModelOption[]) {
  const options = loadedModels?.length ? loadedModels : fallbackModelOptionsForProvider(provider);
  return options.map((option) => option.id);
}

function modelMatchesProvider(provider: ProviderKey, model?: string | null, loadedModels?: ProviderModelOption[]) {
  const normalized = (model ?? "").trim().toLowerCase();
  if (!normalized) return false;
  return providerModelIDs(provider, loadedModels).some((option) => option.toLowerCase() === normalized);
}

function defaultModelForProvider(provider: ProviderKey, settings?: SettingsSnapshot, loadedModels?: ProviderModelOption[]) {
  const ids = providerModelIDs(provider, loadedModels);
  if (provider === "ollamaLocal") return settings?.promptRewriteModel || ids[0] || "gemma4:e2b";
  const currentModel = settings?.model?.trim();
  if (modelMatchesProvider(provider, currentModel, loadedModels)) return currentModel;
  return ids[0] || currentModel || "gpt-5.5";
}

function displayModelForProvider(
  provider: ProviderKey,
  thread: ThreadItem | undefined,
  settings: SettingsSnapshot,
  loadedModels?: ProviderModelOption[]
) {
  if (provider === "ollamaLocal") return settings.promptRewriteModel || defaultModelForProvider(provider, settings, loadedModels);
  if (provider === "copilot") {
    const threadModel = thread?.modelID?.trim();
    if (modelMatchesProvider(provider, threadModel, loadedModels)) return threadModel;
    return defaultModelForProvider(provider, settings, loadedModels);
  }
  return modelMatchesProvider(provider, thread?.modelID, loadedModels)
    ? thread?.modelID ?? defaultModelForProvider(provider, settings, loadedModels)
    : defaultModelForProvider(provider, settings, loadedModels);
}

function compactComposerModelName(modelName: string) {
  const trimmed = modelName.trim();
  if (!trimmed) return "Model";
  return trimmed
    .replace(/^gpt-/i, "")
    .replace(/^claude-/i, "")
    .replace(/-codex$/i, " Codex")
    .replace(/-/g, " ");
}

function sameID(left?: string | null, right?: string | null) {
  return (left ?? "").trim().toLowerCase() === (right ?? "").trim().toLowerCase();
}

function linkedFolderPathForProject(projects: ProjectItem[], projectID?: string | null): string | undefined {
  const visitedProjectIDs = new Set<string>();
  let currentProjectID = projectID?.trim();
  while (currentProjectID && !visitedProjectIDs.has(currentProjectID.toLowerCase())) {
    visitedProjectIDs.add(currentProjectID.toLowerCase());
    const project = projects.find((item) => sameID(item.id, currentProjectID));
    if (!project) return undefined;
    const linkedPath = project.linkedFolderPath?.trim();
    if (linkedPath) return linkedPath;
    currentProjectID = project.parentID?.trim();
  }
  return undefined;
}

function usageForProvider(appState: OpenAssistAppState, provider: ProviderKey) {
  const byBackend = appState.usageByBackend?.[provider];
  if (byBackend && providerKey(byBackend.providerBackend) === provider) return byBackend;
  if (appState.usage && providerKey(appState.usage.providerBackend) === provider) return appState.usage;
  return null;
}

const threadNoteChartTemplates = [
  {
    id: "flow",
    label: "Flowchart",
    description: "Simple process or decision path.",
    markdown: [
      "```mermaid",
      "flowchart TD",
      "  A[Idea] --> B[Plan]",
      "  B --> C[Build]",
      "  C --> D[Review]",
      "```"
    ].join("\n")
  },
  {
    id: "sequence",
    label: "Sequence",
    description: "Messages between people or systems.",
    markdown: [
      "```mermaid",
      "sequenceDiagram",
      "  participant U as User",
      "  participant A as Open Assist",
      "  participant S as Service",
      "  U->>A: Start request",
      "  A->>S: Run action",
      "  S-->>A: Return result",
      "  A-->>U: Show update",
      "```"
    ].join("\n")
  },
  {
    id: "state",
    label: "State",
    description: "Status changes over time.",
    markdown: [
      "```mermaid",
      "stateDiagram-v2",
      "  [*] --> Draft",
      "  Draft --> InReview : submit",
      "  InReview --> ChangesNeeded : feedback",
      "  ChangesNeeded --> Draft : revise",
      "  InReview --> Approved : approve",
      "  Approved --> [*]",
      "```"
    ].join("\n")
  },
  {
    id: "er",
    label: "ER Diagram",
    description: "Tables and database relationships.",
    markdown: [
      "```mermaid",
      "erDiagram",
      "  PROJECT ||--o{ THREAD : contains",
      "  THREAD ||--o{ NOTE : stores",
      "  THREAD ||--o{ MESSAGE : records",
      "  PROJECT {",
      "    string id",
      "    string name",
      "  }",
      "  NOTE {",
      "    string id",
      "    string title",
      "  }",
      "```"
    ].join("\n")
  },
  {
    id: "bar",
    label: "Bar chart",
    description: "Quick xychart-beta comparison.",
    markdown: [
      "```mermaid",
      "xychart-beta",
      "  title \"Progress\"",
      "  x-axis [\"Start\", \"Middle\", \"Now\"]",
      "  y-axis \"Score\" 0 --> 100",
      "  bar [20, 55, 85]",
      "```"
    ].join("\n")
  },
  {
    id: "pie",
    label: "Pie chart",
    description: "Part-of-whole split.",
    markdown: [
      "```mermaid",
      "pie title Work Mix",
      "  \"Research\" : 35",
      "  \"Implementation\" : 45",
      "  \"Review\" : 20",
      "```"
    ].join("\n")
  },
  {
    id: "gantt",
    label: "Gantt",
    description: "Tasks on a timeline.",
    markdown: [
      "```mermaid",
      "gantt",
      "  title Release Plan",
      "  dateFormat  YYYY-MM-DD",
      "  section Build",
      "  Scope feature      :done,    t1, 2026-05-01, 2d",
      "  Implement UI       :active,  t2, after t1, 3d",
      "  section Validate",
      "  QA review          :         t3, after t2, 2d",
      "  Ship release       :milestone, t4, after t3, 1d",
      "```"
    ].join("\n")
  },
  {
    id: "mindmap",
    label: "Mindmap",
    description: "Ideas branching from one topic.",
    markdown: [
      "```mermaid",
      "mindmap",
      "  root((Open Assist))",
      "    Chat",
      "      Providers",
      "      Threads",
      "    Notes",
      "      Project notes",
      "      Thread notes",
      "    Automation",
      "      Skills",
      "      Plugins",
      "```"
    ].join("\n")
  },
  {
    id: "timeline",
    label: "Timeline",
    description: "Events in chronological order.",
    markdown: [
      "```mermaid",
      "timeline",
      "  title Migration Plan",
      "  Discovery : Inventory repos : Find blockers",
      "  Build : Port UI : Wire providers",
      "  Validate : Test flows : Review parity",
      "```"
    ].join("\n")
  }
];

type NoteSlashCommand = {
  id: string;
  label: string;
  description: string;
  aliases: string[];
  icon: ReactNode;
  markdown: string;
};

const noteSlashCommands: NoteSlashCommand[] = [
  {
    id: "heading",
    label: "Heading",
    description: "Start a new section.",
    aliases: ["h1", "h2", "title", "section"],
    icon: <Heading2 size={15} />,
    markdown: "## Heading\n"
  },
  {
    id: "todo",
    label: "Todo list",
    description: "Track tasks inside the note.",
    aliases: ["task", "checklist", "checkbox"],
    icon: <ListTodo size={15} />,
    markdown: "- [ ] First task\n- [ ] Second task\n"
  },
  {
    id: "bullets",
    label: "Bulleted list",
    description: "Add a clean list.",
    aliases: ["list", "ul", "points"],
    icon: <List size={15} />,
    markdown: "- First point\n- Second point\n"
  },
  {
    id: "numbers",
    label: "Numbered list",
    description: "Add ordered steps.",
    aliases: ["ordered", "steps", "ol"],
    icon: <List size={15} />,
    markdown: "1. First step\n2. Second step\n"
  },
  {
    id: "quote",
    label: "Quote",
    description: "Call out important text.",
    aliases: ["blockquote", "callout"],
    icon: <MessageSquare size={15} />,
    markdown: "> Important note\n"
  },
  {
    id: "code",
    label: "Code block",
    description: "Paste commands or code.",
    aliases: ["snippet", "terminal", "command"],
    icon: <Code2 size={15} />,
    markdown: "```text\nPaste code here\n```\n"
  },
  {
    id: "table",
    label: "Table",
    description: "Add a simple two-column table.",
    aliases: ["grid", "columns"],
    icon: <Table2 size={15} />,
    markdown: "| Column | Value |\n| --- | --- |\n| Item | Detail |\n"
  },
  {
    id: "divider",
    label: "Divider",
    description: "Separate note sections.",
    aliases: ["line", "rule", "hr"],
    icon: <Sparkles size={15} />,
    markdown: "---\n"
  },
  {
    id: "link",
    label: "Link",
    description: "Insert a Markdown link.",
    aliases: ["url", "website"],
    icon: <ExternalLink size={15} />,
    markdown: "[Title](https://example.com)\n"
  },
  {
    id: "collapsible",
    label: "Collapsible section",
    description: "Hide extra detail behind a summary.",
    aliases: ["details", "collapse", "fold"],
    icon: <PanelLeftClose size={15} />,
    markdown: "<!-- oa:collapsible title=\"Details\" -->\nWrite details here.\n<!-- /oa:collapsible -->\n"
  },
  ...threadNoteChartTemplates.map((template): NoteSlashCommand => ({
    id: `chart-${template.id}`,
    label: template.label,
    description: template.description,
    aliases: [template.id, "chart", "diagram", "mermaid", template.label.toLowerCase()],
    icon: template.id === "flow"
      ? <Workflow size={15} />
      : template.id === "sequence"
        ? <GitBranch size={15} />
        : template.id === "gantt" || template.id === "timeline"
          ? <CalendarClock size={15} />
          : <CircleGauge size={15} />,
    markdown: template.markdown
  }))
];

function uniqueModelOptions(models: ProviderModelOption[]) {
  const seen = new Set<string>();
  return models.filter((model) => {
    const normalized = model.id.trim().toLowerCase();
    if (!normalized || model.hidden || seen.has(normalized)) return false;
    seen.add(normalized);
    return true;
  });
}

function visibleModelOptions(
  provider: ProviderKey,
  currentModel: string,
  loadedModels?: ProviderModelOption[]
) {
  const baseModels = loadedModels?.length ? loadedModels : fallbackModelOptionsForProvider(provider);
  const currentID = currentModel.trim();
  const hasCurrentModel = baseModels.some((model) => model.id.toLowerCase() === currentID.toLowerCase());
  const currentOption = currentID && !hasCurrentModel && provider !== "copilot"
    ? modelOption(currentID, compactComposerModelName(currentID))
    : null;
  return uniqueModelOptions([
    ...(currentOption ? [currentOption] : []),
    ...baseModels
  ]).slice(0, provider === "copilot" ? 32 : 8);
}

function copilotModelFamily(model: ProviderModelOption) {
  const haystack = `${model.id} ${model.displayName} ${model.description ?? ""}`.toLowerCase();
  if (haystack.includes("gemini") || haystack.includes("google")) return { key: "google", label: "Google Gemini" };
  if (haystack.includes("raptor") || haystack.includes("goldeneye") || haystack.includes("fine-tuned")) return { key: "fine-tuned", label: "Fine-tuned" };
  if (haystack.includes("claude") || haystack.includes("anthropic")) return { key: "anthropic", label: "Claude" };
  if (haystack.includes("grok") || haystack.includes("xai")) return { key: "xai", label: "xAI" };
  if (haystack.includes("gpt") || haystack.includes("codex") || model.id === "auto") return { key: "openai", label: "OpenAI" };
  return { key: "other", label: "Other" };
}

function modelFamilySections(
  provider: RuntimeProviderKey,
  currentModel: string,
  loadedModels?: ProviderModelOption[]
) {
  const models = visibleModelOptions(provider, currentModel, loadedModels);
  if (provider !== "copilot") {
    return [{
      key: provider,
      label: "Models",
      detail: providerLabel(provider),
      models
    }];
  }
  const sections: Array<{ key: string; label: string; detail: string; models: ProviderModelOption[] }> = [];
  for (const model of models) {
    const family = copilotModelFamily(model);
    let section = sections.find((item) => item.key === family.key);
    if (!section) {
      section = { key: family.key, label: family.label, detail: "", models: [] };
      sections.push(section);
    }
    section.models.push(model);
  }
  return sections;
}

type MarkdownAction = "heading" | "bold" | "italic" | "quote" | "bullet" | "task" | "code" | "table";

function lineRange(value: string, start: number, end: number) {
  const lineStart = value.lastIndexOf("\n", Math.max(0, start - 1)) + 1;
  const nextBreak = value.indexOf("\n", end);
  return {
    start: lineStart,
    end: nextBreak === -1 ? value.length : nextBreak
  };
}

function prefixMarkdownLines(value: string, start: number, end: number, prefix: string) {
  const range = lineRange(value, start, end);
  const selected = value.slice(range.start, range.end);
  const nextSelected = selected
    .split("\n")
    .map((line) => `${prefix}${line || ""}`)
    .join("\n");
  return {
    value: `${value.slice(0, range.start)}${nextSelected}${value.slice(range.end)}`,
    start: range.start,
    end: range.start + nextSelected.length
  };
}

function applyMarkdownAction(value: string, start: number, end: number, action: MarkdownAction) {
  const selected = value.slice(start, end);
  const fallback = selected || "text";
  if (action === "heading") return prefixMarkdownLines(value, start, end, "## ");
  if (action === "quote") return prefixMarkdownLines(value, start, end, "> ");
  if (action === "bullet") return prefixMarkdownLines(value, start, end, "- ");
  if (action === "task") return prefixMarkdownLines(value, start, end, "- [ ] ");
  if (action === "bold") {
    const replacement = `**${fallback}**`;
    return { value: `${value.slice(0, start)}${replacement}${value.slice(end)}`, start: start + 2, end: start + 2 + fallback.length };
  }
  if (action === "italic") {
    const replacement = `*${fallback}*`;
    return { value: `${value.slice(0, start)}${replacement}${value.slice(end)}`, start: start + 1, end: start + 1 + fallback.length };
  }
  if (action === "code") {
    const replacement = selected.includes("\n") || !selected
      ? ["```", selected || "code", "```"].join("\n")
      : `\`${selected}\``;
    return { value: `${value.slice(0, start)}${replacement}${value.slice(end)}`, start, end: start + replacement.length };
  }
  const table = [
    "| Column | Value |",
    "| --- | --- |",
    "| Item | Detail |"
  ].join("\n");
  const replacement = `${value.slice(0, start).endsWith("\n") || start === 0 ? "" : "\n\n"}${table}${value.slice(end).startsWith("\n") || end === value.length ? "" : "\n\n"}`;
  return { value: `${value.slice(0, start)}${replacement}${value.slice(end)}`, start: start + replacement.length, end: start + replacement.length };
}

const markdownRemarkPlugins = [remarkGfm];

const noteMarkdownImagePattern =
  /!\[((?:\\.|[^\]])*)\]\(([^)\s]+)(?:\s+"((?:\\.|[^"])*)")?\)(?:\{([^}]*)\})?/g;
const fencedCodeSegmentPattern = /(```[\s\S]*?```|~~~[\s\S]*?~~~)/g;

type NotePreviewBlock =
  | { type: "markdown"; markdown: string }
  | { type: "collapsible"; title: string; level: number; body: string };

function writeTextToClipboard(text: string) {
  const value = String(text ?? "");
  if (window.openAssistElectron?.writeClipboardText) {
    void window.openAssistElectron.writeClipboardText(value).catch(() => {
      void navigator.clipboard?.writeText(value).catch(() => {});
    });
    return;
  }
  void navigator.clipboard?.writeText(value).catch(() => {});
}

function parseNoteImageModifiers(rawValue: string) {
  let width: number | null = null;
  let collapsed = false;
  for (const token of rawValue.split(/[,\s]+/).filter(Boolean)) {
    if (token === "collapsed") {
      collapsed = true;
      continue;
    }
    const widthMatch = token.match(/^width=(\d+)$/i);
    if (widthMatch) {
      const parsed = Number.parseInt(widthMatch[1], 10);
      if (Number.isFinite(parsed) && parsed > 0) width = Math.max(80, parsed);
    }
  }
  return { width, collapsed };
}

function escapeMarkdownImageText(value: string) {
  return value.replace(/\\/g, "\\\\").replace(/\]/g, "\\]");
}

function escapeMarkdownTitleText(value: string) {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function unescapeMarkdownImageText(value: string) {
  return value.replace(/\\([\]\\])/g, "$1");
}

function unescapeMarkdownTitleText(value: string) {
  return value.replace(/\\(["\\])/g, "$1");
}

function withNoteDisplayAttrFragment(src: string, width: number | null, collapsed: boolean) {
  const cleanSrc = src
    .replace(/#oa-note-width=\d+$/i, "")
    .replace(/#oa-note-attrs=[^#]+$/i, "");
  const parts: string[] = [];
  if (width) parts.push(`width=${width}`);
  if (collapsed) parts.push("collapsed");
  return parts.length ? `${cleanSrc}#oa-note-attrs=${parts.join(",")}` : cleanSrc;
}

function normalizeNoteMarkdownImagesForPreview(markdown: string) {
  return markdown
    .replace(/\r\n/g, "\n")
    .split(fencedCodeSegmentPattern)
    .map((segment) => {
      if (segment.startsWith("```") || segment.startsWith("~~~")) return segment;
      return segment.replace(noteMarkdownImagePattern, (_match, alt = "", src = "", title = "", modifiers = "") => {
        const parsed = parseNoteImageModifiers(modifiers);
        const resolvedSrc = parsed.width || parsed.collapsed
          ? withNoteDisplayAttrFragment(src, parsed.width, parsed.collapsed)
          : src;
        const escapedAlt = escapeMarkdownImageText(unescapeMarkdownImageText(alt));
        const escapedTitle = title ? escapeMarkdownTitleText(unescapeMarkdownTitleText(title)) : "";
        return `![${escapedAlt}](${resolvedSrc}${escapedTitle ? ` "${escapedTitle}"` : ""})`;
      });
    })
    .join("");
}

function resolveRenderedNoteImage(src: string) {
  const match = src.match(/#oa-note-attrs=([^#]+)$/i);
  if (!match) return { src, width: null as number | null, collapsed: false };
  const parsed = parseNoteImageModifiers(match[1]);
  return {
    src: src.slice(0, match.index),
    width: parsed.width,
    collapsed: parsed.collapsed
  };
}

function parseNotePreviewBlocks(markdown: string): NotePreviewBlock[] {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const blocks: NotePreviewBlock[] = [];
  let buffer: string[] = [];
  let index = 0;
  let inFence: string | null = null;
  const flush = () => {
    const markdownBlock = buffer.join("\n");
    if (markdownBlock.trim()) blocks.push({ type: "markdown", markdown: markdownBlock });
    buffer = [];
  };
  const fenceMarker = (line: string) => line.match(/^\s*(```|~~~)/)?.[1] ?? null;
  const isClosingFence = (line: string, fence: string) => line.trimStart().startsWith(fence);
  const headingLevel = (line: string) => line.match(/^(#{1,6})\s+/)?.[1].length ?? null;

  while (index < lines.length) {
    const line = lines[index];
    const marker = fenceMarker(line);
    if (inFence) {
      buffer.push(line);
      if (marker && isClosingFence(line, inFence)) inFence = null;
      index += 1;
      continue;
    }
    if (marker) {
      inFence = marker;
      buffer.push(line);
      index += 1;
      continue;
    }

    const explicitStart = line.match(/^<!--\s*oa:collapsible(?:\s+title=(?:"([^"]*)"|'([^']*)'|([^\s]+)))?\s*-->\s*$/i);
    if (explicitStart) {
      flush();
      const title = (explicitStart[1] ?? explicitStart[2] ?? explicitStart[3] ?? "Details").trim() || "Details";
      const body: string[] = [];
      index += 1;
      while (index < lines.length && !/^<!--\s*\/oa:collapsible\s*-->\s*$/i.test(lines[index])) {
        body.push(lines[index]);
        index += 1;
      }
      if (index < lines.length) index += 1;
      blocks.push({ type: "collapsible", title, level: 2, body: body.join("\n") });
      continue;
    }

    const headingStart = line.match(/^(#{1,6})\s+(.+?)\s*<!--\s*oa:collapsible\s*-->\s*$/i);
    if (headingStart) {
      flush();
      const level = headingStart[1].length;
      const title = headingStart[2].trim() || "Details";
      const body: string[] = [];
      index += 1;
      let bodyFence: string | null = null;
      while (index < lines.length) {
        const bodyLine = lines[index];
        const bodyMarker = fenceMarker(bodyLine);
        if (bodyFence) {
          body.push(bodyLine);
          if (bodyMarker && isClosingFence(bodyLine, bodyFence)) bodyFence = null;
          index += 1;
          continue;
        }
        if (bodyMarker) {
          bodyFence = bodyMarker;
          body.push(bodyLine);
          index += 1;
          continue;
        }
        const nextLevel = headingLevel(bodyLine);
        if (nextLevel && nextLevel <= level) break;
        if (/^\s*(?:---|\*\*\*|___)\s*$/.test(bodyLine)) break;
        body.push(bodyLine);
        index += 1;
      }
      blocks.push({ type: "collapsible", title, level, body: body.join("\n") });
      continue;
    }

    buffer.push(line);
    index += 1;
  }
  flush();
  return blocks;
}

const noteCodeTheme: Record<string, CSSProperties> = {
  'code[class*="language-"]': {
    color: "var(--note-code-text)",
    fontFamily: "var(--theme-code-font, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace)",
    fontSize: "var(--code-font-size, 12.2px)",
    lineHeight: "1.58",
    background: "none"
  },
  'pre[class*="language-"]': {
    color: "var(--note-code-text)",
    fontFamily: "var(--theme-code-font, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace)",
    fontSize: "var(--code-font-size, 12.2px)",
    lineHeight: "1.58",
    background: "transparent",
    margin: "0",
    overflow: "auto"
  },
  keyword: { color: "var(--note-code-keyword)" },
  builtin: { color: "var(--note-code-builtin)" },
  function: { color: "var(--note-code-function)" },
  "class-name": { color: "var(--note-code-class)" },
  boolean: { color: "var(--note-code-number)" },
  number: { color: "var(--note-code-number)" },
  string: { color: "var(--note-code-string)" },
  comment: { color: "var(--note-code-comment)", fontStyle: "italic" },
  punctuation: { color: "var(--note-code-punctuation)" },
  operator: { color: "var(--note-code-operator)" },
  property: { color: "var(--note-code-property)" },
  tag: { color: "var(--note-code-tag)" },
  "attr-name": { color: "var(--note-code-attr-name)" },
  "attr-value": { color: "var(--note-code-attr-value)" },
  selector: { color: "var(--note-code-selector)" },
  variable: { color: "var(--note-code-variable)" },
  inserted: { color: "var(--note-code-inserted)" },
  deleted: { color: "var(--note-code-deleted)" }
};

type MermaidModule = typeof import("mermaid");

let mermaidModulePromise: Promise<MermaidModule> | null = null;

const noteMermaidConfig = {
  startOnLoad: false,
  securityLevel: "strict",
  theme: "dark",
  themeVariables: {
    darkMode: true,
    background: "transparent",
    primaryColor: "#262a2e",
    primaryTextColor: "#f2f3f5",
    primaryBorderColor: "#b78935",
    lineColor: "#8f9297",
    secondaryColor: "#1a1d21",
    tertiaryColor: "#101317",
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, Helvetica Neue, Arial, sans-serif"
  }
} as const;

async function loadMermaid() {
  if (!mermaidModulePromise) {
    mermaidModulePromise = import("mermaid").then((module) => {
      module.default.initialize(noteMermaidConfig);
      return module;
    });
  }
  return mermaidModulePromise;
}

/*
  This mirrors the native/web chat Markdown stack: ReactMarkdown + GFM for
  text, syntax-highlighter for code, and Mermaid only when a diagram appears.
*/
function hashNoteMarkdown(value: string) {
  let hash = 0;
  for (let index = 0; index < value.length; index += 1) {
    hash = Math.imul(31, hash) + value.charCodeAt(index) | 0;
  }
  return Math.abs(hash).toString(36);
}

function normalizeMarkdownStructure(markdown: string): string {
  const normalized = markdown.replace(/\r\n/g, "\n");
  const segments = normalized.split(/(```[\s\S]*?```|~~~[\s\S]*?~~~)/g);
  return segments
    .map((segment) => {
      if (segment.startsWith("```") || segment.startsWith("~~~")) return segment;
      return expandCompactOrderedLists(segment);
    })
    .join("");
}

function expandCompactOrderedLists(segment: string): string {
  const prepared = segment.replace(/(:)\s+(?=1\.\s)/g, "$1\n");
  return prepared
    .split("\n")
    .map((line) => {
      const prefixMatch = line.match(/^(\s*(?:>\s*)*)\d+\.\s/);
      if (!prefixMatch) return line;
      const splitStarts = [...line.matchAll(/(\s+)(\d+)\.\s/g)]
        .map((marker) => marker.index)
        .filter((index): index is number => typeof index === "number");
      if (splitStarts.length === 0) return line;
      const prefix = prefixMatch[1] || "";
      const rebuilt: string[] = [];
      let sliceStart = 0;
      for (const markerIndex of splitStarts) {
        const whitespace = line.slice(markerIndex).match(/^\s+/)?.[0] || "";
        const itemStart = markerIndex + whitespace.length;
        rebuilt.push(line.slice(sliceStart, itemStart).trimEnd());
        sliceStart = itemStart;
      }
      rebuilt.push(line.slice(sliceStart));
      return rebuilt.filter(Boolean).join(`\n${prefix}`);
    })
    .join("\n");
}

const MERMAID_VIEWER_MIN_SCALE = 0.3;
const MERMAID_VIEWER_MAX_SCALE = 3.5;
const MERMAID_VIEWER_FALLBACK_WIDTH = 960;
const MERMAID_VIEWER_FALLBACK_HEIGHT = 620;

type MermaidPoint = { x: number; y: number };
type MermaidSize = { width: number; height: number };

function clampNumber(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value));
}

function measureMermaidSvg(svgEl: SVGSVGElement | null): MermaidSize {
  if (!svgEl) {
    return { width: MERMAID_VIEWER_FALLBACK_WIDTH, height: MERMAID_VIEWER_FALLBACK_HEIGHT };
  }

  try {
    const viewBox = svgEl.viewBox?.baseVal;
    if (viewBox && viewBox.width > 0 && viewBox.height > 0) {
      return { width: viewBox.width, height: viewBox.height };
    }

    const width = parseFloat(svgEl.getAttribute("width") || "0");
    const height = parseFloat(svgEl.getAttribute("height") || "0");
    if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
      return { width, height };
    }

    const box = svgEl.getBBox();
    if (Number.isFinite(box.width) && Number.isFinite(box.height) && box.width > 0 && box.height > 0) {
      return { width: box.width, height: box.height };
    }
  } catch {
    // Use the stable fallback below when the browser cannot measure the SVG yet.
  }

  return { width: MERMAID_VIEWER_FALLBACK_WIDTH, height: MERMAID_VIEWER_FALLBACK_HEIGHT };
}

function MermaidDiagramViewer({ svg, onClose }: { svg: string; onClose: () => void }) {
  const viewportRef = useRef<HTMLDivElement>(null);
  const surfaceRef = useRef<HTMLDivElement>(null);
  const dragRef = useRef<{
    pointerId: number;
    startX: number;
    startY: number;
    startOffset: MermaidPoint;
  } | null>(null);
  const [diagramSize, setDiagramSize] = useState<MermaidSize>({
    width: MERMAID_VIEWER_FALLBACK_WIDTH,
    height: MERMAID_VIEWER_FALLBACK_HEIGHT
  });
  const [offset, setOffset] = useState<MermaidPoint>({ x: 0, y: 0 });
  const [scale, setScale] = useState(1);
  const [isDragging, setIsDragging] = useState(false);
  const [copiedSvg, setCopiedSvg] = useState(false);

  const fitDiagram = () => {
    const viewport = viewportRef.current;
    const surface = surfaceRef.current;
    if (!viewport || !surface) return;

    const svgEl = surface.querySelector("svg") as SVGSVGElement | null;
    const nextSize = measureMermaidSvg(svgEl);
    const availableWidth = Math.max(180, viewport.clientWidth - 72);
    const availableHeight = Math.max(180, viewport.clientHeight - 72);
    const nextScale = clampNumber(
      Math.min(availableWidth / nextSize.width, availableHeight / nextSize.height, 1.45),
      MERMAID_VIEWER_MIN_SCALE,
      MERMAID_VIEWER_MAX_SCALE
    );

    setDiagramSize(nextSize);
    setScale(nextScale);
    setOffset({
      x: (viewport.clientWidth - nextSize.width * nextScale) / 2,
      y: (viewport.clientHeight - nextSize.height * nextScale) / 2
    });
  };

  const zoomAt = (factor: number, anchor?: MermaidPoint) => {
    const viewport = viewportRef.current;
    const point = anchor ?? (
      viewport
        ? { x: viewport.clientWidth / 2, y: viewport.clientHeight / 2 }
        : { x: 0, y: 0 }
    );

    setScale((currentScale) => {
      const safeScale = currentScale || 1;
      const nextScale = clampNumber(safeScale * factor, MERMAID_VIEWER_MIN_SCALE, MERMAID_VIEWER_MAX_SCALE);
      setOffset((currentOffset) => ({
        x: point.x - ((point.x - currentOffset.x) / safeScale) * nextScale,
        y: point.y - ((point.y - currentOffset.y) / safeScale) * nextScale
      }));
      return nextScale;
    });
  };

  useLayoutEffect(() => {
    const frame = window.requestAnimationFrame(fitDiagram);
    return () => window.cancelAnimationFrame(frame);
  }, [svg]);

  useEffect(() => {
    const viewport = viewportRef.current;
    if (!viewport) return;

    const handleWheel = (event: WheelEvent) => {
      event.preventDefault();
      const rect = viewport.getBoundingClientRect();
      zoomAt(event.deltaY < 0 ? 1.12 : 0.88, {
        x: event.clientX - rect.left,
        y: event.clientY - rect.top
      });
    };

    viewport.addEventListener("wheel", handleWheel, { passive: false });
    return () => viewport.removeEventListener("wheel", handleWheel);
  });

  useEffect(() => {
    const handleResize = () => fitDiagram();
    const handleKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
        return;
      }
      if (event.key === "+" || event.key === "=") {
        zoomAt(1.15);
        return;
      }
      if (event.key === "-") {
        zoomAt(0.87);
        return;
      }
      if (event.key === "0") {
        fitDiagram();
      }
    };

    window.addEventListener("resize", handleResize);
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("resize", handleResize);
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [onClose]);

  const handlePointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    dragRef.current = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      startOffset: offset
    };
    setIsDragging(true);
  };

  const handlePointerMove = (event: ReactPointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    setOffset({
      x: drag.startOffset.x + event.clientX - drag.startX,
      y: drag.startOffset.y + event.clientY - drag.startY
    });
  };

  const stopDragging = (event: ReactPointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (drag?.pointerId === event.pointerId) {
      try {
        event.currentTarget.releasePointerCapture(event.pointerId);
      } catch {
        // The pointer may already be released if the window lost focus.
      }
      dragRef.current = null;
      setIsDragging(false);
    }
  };

  const handleCopySvg = () => {
    writeTextToClipboard(svg);
    setCopiedSvg(true);
    window.setTimeout(() => setCopiedSvg(false), 1600);
  };

  const portalTarget = document.querySelector(".app-shell") ?? document.body;

  return createPortal(
    <div className="mermaid-viewer-overlay" role="presentation" onClick={onClose}>
      <section
        className="mermaid-viewer-shell"
        role="dialog"
        aria-modal="true"
        aria-label="Mermaid diagram viewer"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="mermaid-viewer-toolbar">
          <div className="mermaid-viewer-title">Diagram</div>
          <div className="mermaid-viewer-controls">
            <div className="mermaid-viewer-zoom-group" aria-label="Zoom controls">
              <button type="button" className="mermaid-viewer-icon-button" title="Zoom out" aria-label="Zoom out" onClick={() => zoomAt(0.87)}>
                <Minus size={14} />
              </button>
              <span className="mermaid-viewer-scale">{Math.round(scale * 100)}%</span>
              <button type="button" className="mermaid-viewer-icon-button" title="Zoom in" aria-label="Zoom in" onClick={() => zoomAt(1.15)}>
                <Plus size={14} />
              </button>
            </div>
            <button type="button" className="mermaid-viewer-chip" title="Fit" aria-label="Fit diagram" onClick={fitDiagram}>
              <Maximize2 size={14} />
              <span>Fit</span>
            </button>
            <button type="button" className="mermaid-viewer-chip" title="Copy SVG" aria-label="Copy SVG" onClick={handleCopySvg}>
              {copiedSvg ? <Check size={14} /> : <Copy size={14} />}
              <span>{copiedSvg ? "Copied" : "Copy"}</span>
            </button>
            <button type="button" className="mermaid-viewer-icon-button mermaid-viewer-close" title="Close" aria-label="Close diagram viewer" onClick={onClose}>
              <X size={15} />
            </button>
          </div>
        </div>
        <div
          ref={viewportRef}
          className={cx("mermaid-viewer-viewport", isDragging && "is-dragging")}
          onPointerDown={handlePointerDown}
          onPointerMove={handlePointerMove}
          onPointerUp={stopDragging}
          onPointerCancel={stopDragging}
        >
          <div
            ref={surfaceRef}
            className="mermaid-viewer-surface"
            style={{
              width: `${diagramSize.width}px`,
              height: `${diagramSize.height}px`,
              transform: `translate3d(${offset.x}px, ${offset.y}px, 0) scale(${scale})`
            }}
            dangerouslySetInnerHTML={{ __html: svg }}
          />
        </div>
      </section>
    </div>,
    portalTarget
  );
}

function MermaidPreview({ code }: { code: string }) {
  const idPrefix = useRef(`note-mermaid-${Math.random().toString(36).slice(2)}`);
  const [svg, setSvg] = useState("");
  const [error, setError] = useState("");
  const [viewerOpen, setViewerOpen] = useState(false);

  useEffect(() => {
    let cancelled = false;
    const source = code.trim();
    if (!source) {
      setSvg("");
      setError("");
      return;
    }
    const renderID = `${idPrefix.current}-${hashNoteMarkdown(source)}`;
    loadMermaid()
      .then((module) => module.default.render(renderID, source))
      .then((result) => {
        if (cancelled) return;
        setSvg(result.svg);
        setError("");
      })
      .catch((renderError: unknown) => {
        if (cancelled) return;
        setSvg("");
        setError(renderError instanceof Error ? renderError.message : "Could not render this Mermaid diagram.");
      });
    return () => {
      cancelled = true;
    };
  }, [code]);

  if (svg) {
    return (
      <>
        <button
          type="button"
          className="note-mermaid-preview note-mermaid-preview-button"
          aria-label="Open diagram viewer"
          title="Open diagram viewer"
          onClick={() => setViewerOpen(true)}
          dangerouslySetInnerHTML={{ __html: svg }}
        />
        {viewerOpen ? <MermaidDiagramViewer svg={svg} onClose={() => setViewerOpen(false)} /> : null}
      </>
    );
  }
  return (
    <div className="note-mermaid-preview is-error">
      <strong>{error ? "Mermaid preview error" : "Rendering diagram..."}</strong>
      {error && <pre>{code}</pre>}
    </div>
  );
}

function MarkdownCodeBlock({ code, language }: { code: string; language: string }) {
  const [copied, setCopied] = useState(false);
  const normalizedLanguage = language.toLowerCase();
  if (normalizedLanguage === "mermaid" || normalizedLanguage.startsWith("mermaid")) {
    return <MermaidPreview code={code} />;
  }
  const handleCopy = () => {
    writeTextToClipboard(code);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1600);
  };
  return (
    <div className="note-code-block-wrapper">
      <div className="note-code-block-header">
        <span>{language || "text"}</span>
        <button type="button" onClick={handleCopy}>
          {copied ? <Check size={13} /> : <Copy size={13} />}
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
      <SyntaxHighlighter
        style={noteCodeTheme}
        language={language || "text"}
        PreTag="div"
        customStyle={{ margin: 0, padding: "15px 17px", background: "transparent" }}
        codeTagProps={{
          style: {
            fontFamily: "var(--theme-code-font, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace)",
            fontSize: "var(--code-font-size, 12.2px)",
            lineHeight: "1.58"
          }
        }}
      >
        {code}
      </SyntaxHighlighter>
    </div>
  );
}

function NotePreviewImage({
  src,
  alt,
  title,
  sourcePath,
  rest
}: {
  src: string;
  alt?: string;
  title?: string;
  sourcePath?: string;
  rest: Record<string, unknown>;
}) {
  const rendered = useMemo(() => resolveRenderedNoteImage(src), [src]);
  const [resolvedSrc, setResolvedSrc] = useState(rendered.src);

  useEffect(() => {
    let cancelled = false;
    setResolvedSrc(rendered.src);
    if (!sourcePath || !rendered.src || /^(https?:|data:|blob:)/i.test(rendered.src)) return undefined;
    void window.openAssistElectron?.readNoteImageDataURL(sourcePath, rendered.src)
      .then((dataURL) => {
        if (!cancelled && dataURL) setResolvedSrc(dataURL);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [rendered.src, sourcePath]);

  const maxWidthStyle =
    typeof rendered.width === "number"
      ? ({ maxWidth: `${rendered.width}px`, width: "100%" } satisfies CSSProperties)
      : undefined;
  const media = (
    <img
      {...rest}
      className="thread-note-rendered-image-media"
      src={resolvedSrc}
      alt={alt ?? ""}
      title={title}
      style={maxWidthStyle}
      draggable={false}
    />
  );
  const caption = title?.trim();
  const figure = caption ? (
    <figure className="thread-note-rendered-image" style={maxWidthStyle}>
      {media}
      <figcaption className="thread-note-rendered-image-caption">{caption}</figcaption>
    </figure>
  ) : media;

  if (rendered.collapsed) {
    return (
      <details className="note-collapsible-image">
        <summary>
          <ChevronRight size={14} />
          <span>{caption || alt || "Image"}</span>
        </summary>
        {figure}
      </details>
    );
  }
  return figure;
}

function MarkdownPreview({
  markdown,
  sourcePath,
  className,
  emptyText = "No note content yet."
}: {
  markdown: string;
  sourcePath?: string;
  className?: string;
  emptyText?: string;
}) {
  const renderedMarkdown = useMemo(
    () => normalizeNoteMarkdownImagesForPreview(normalizeMarkdownStructure(markdown)),
    [markdown]
  );
  const blocks = useMemo(() => parseNotePreviewBlocks(renderedMarkdown), [renderedMarkdown]);
  const components = useMemo<Components>(() => ({
    a: ({ href, children, ...props }) => (
      <a
        href={href}
        onClick={(event) => {
          event.preventDefault();
          if (href) window.open(href, "_blank", "noopener,noreferrer");
        }}
        {...props}
      >
        {children}
      </a>
    ),
    code: ({ className, children, ...props }) => {
      const match = /language-([\w-]+)/.exec(className || "");
      const codeString = String(children).replace(/\n$/, "");
      if (match) {
        return <MarkdownCodeBlock code={codeString} language={match[1]} />;
      }
      return (
        <code className="inline-code" {...props}>
          {children}
        </code>
      );
    },
    img: ({ src, alt, title, node: _node, ...props }) => {
      return (
        <NotePreviewImage
          src={src ?? ""}
          alt={alt ?? ""}
          title={typeof title === "string" ? title : undefined}
          sourcePath={sourcePath}
          rest={props as Record<string, unknown>}
        />
      );
    }
  }), [sourcePath]);

  const renderMarkdown = (source: string, key: string) => (
    <ReactMarkdown key={key} remarkPlugins={markdownRemarkPlugins} components={components}>
      {source}
    </ReactMarkdown>
  );

  return (
    <div className={cx("markdown-preview-surface markdown-preview-rich", className)}>
      {renderedMarkdown.trim() ? (
        blocks.map((block, index) => {
          if (block.type === "markdown") return renderMarkdown(block.markdown, `markdown-${index}`);
          return (
            <details key={`collapsible-${index}`} className={`note-collapsible-section level-${block.level}`} open>
              <summary>
                <ChevronRight size={15} />
                <span>{block.title}</span>
              </summary>
              <div className="note-collapsible-body">
                {block.body.trim() ? renderMarkdown(block.body, `collapsible-body-${index}`) : <p className="empty-inline">No details yet.</p>}
              </div>
            </details>
          );
        })
      ) : emptyText ? (
        <p className="empty-inline">{emptyText}</p>
      ) : null}
    </div>
  );
}

function detectSlashCommandToken(value: string, cursor: number) {
  const beforeCursor = value.slice(0, cursor);
  const match = beforeCursor.match(/(^|[\s([{])\/([a-z0-9_-]*)$/i);
  if (!match) return null;
  const start = cursor - match[0].length + (match[1] ? match[1].length : 0);
  return {
    start,
    end: cursor,
    query: match[2] ?? ""
  };
}

function normalizeEditorMarkdown(value: string) {
  return value.replace(/\r\n/g, "\n");
}

function MarkdownEditorSurface({
  value,
  onChange,
  placeholder,
  textareaRef,
  compact = false,
  sourcePath,
  saveStatusLabel,
  saveStatusKind,
  onSave,
  showSaveButton = false
}: {
  value: string;
  onChange: (value: string) => void;
  placeholder: string;
  textareaRef?: MutableRefObject<HTMLTextAreaElement | null>;
  compact?: boolean;
  sourcePath?: string;
  saveStatusLabel?: string;
  saveStatusKind?: string;
  onSave?: () => void;
  showSaveButton?: boolean;
}) {
  const [mode, setMode] = useState<"markdown" | "preview">("preview");
  const [chartMenuOpen, setChartMenuOpen] = useState(false);
  const [slashMenuOpen, setSlashMenuOpen] = useState(false);
  const [slashQuery, setSlashQuery] = useState("");
  const [slashRange, setSlashRange] = useState<{ start: number; end: number } | null>(null);
  const [richSlashRange, setRichSlashRange] = useState<{ from: number; to: number } | null>(null);
  const [activeSlashIndex, setActiveSlashIndex] = useState(0);
  const [editorContextMenu, setEditorContextMenu] = useState<FloatingContextMenuState | null>(null);
  const chartMenuRef = useRef<HTMLDivElement | null>(null);
  const localTextareaRef = useRef<HTMLTextAreaElement | null>(null);
  const latestValueRef = useRef(normalizeEditorMarkdown(value));
  const richExtensions = useMemo(
    () => [
      StarterKit.configure({ codeBlock: false }),
      Markdown,
      Placeholder.configure({
        placeholder,
        emptyEditorClass: "is-editor-empty"
      }),
      Image.configure({
        inline: false,
        allowBase64: true
      }),
      TableKit.configure({
        table: {
          resizable: true
        }
      }),
      TaskList,
      TaskItem.configure({
        nested: true
      })
    ],
    [placeholder]
  );
  const richEditor = useEditor(
    {
      immediatelyRender: false,
      autofocus: false,
      content: normalizeEditorMarkdown(value),
      contentType: "markdown",
      extensions: richExtensions,
      editorProps: {
        attributes: {
          class: "rich-note-tiptap",
          spellcheck: "true"
        }
      },
      onUpdate: ({ editor }: { editor: Editor }) => {
        const nextMarkdown = normalizeEditorMarkdown(editor.getMarkdown());
        if (nextMarkdown === latestValueRef.current) return;
        latestValueRef.current = nextMarkdown;
        onChange(nextMarkdown);
      }
    },
    [richExtensions, onChange]
  );
  useEffect(() => {
    latestValueRef.current = normalizeEditorMarkdown(value);
  }, [value]);
  useEffect(() => {
    if (!richEditor) return;
    const nextMarkdown = normalizeEditorMarkdown(value);
    const currentMarkdown = normalizeEditorMarkdown(richEditor.getMarkdown());
    if (nextMarkdown === currentMarkdown) return;
    richEditor.commands.setContent(nextMarkdown, {
      contentType: "markdown",
      emitUpdate: false
    });
  }, [richEditor, value]);
  const filteredSlashCommands = useMemo(() => {
    const query = slashQuery.trim().toLowerCase();
    if (!query) return noteSlashCommands;
    return noteSlashCommands.filter((command) => {
      const haystack = [command.label, command.description, ...command.aliases].join(" ").toLowerCase();
      return haystack.includes(query);
    });
  }, [slashQuery]);
  const visibleSlashCommands = filteredSlashCommands;
  useEffect(() => {
    setActiveSlashIndex(0);
  }, [slashQuery, slashMenuOpen]);
  useOutsideDismiss(chartMenuOpen, chartMenuRef, () => setChartMenuOpen(false));
  const assignTextareaRef = (node: HTMLTextAreaElement | null) => {
    localTextareaRef.current = node;
    if (textareaRef) textareaRef.current = node;
  };
  const setEditorMode = (nextMode: "markdown" | "preview") => {
    setMode(nextMode);
  };
  const updateSlashState = (source: string, cursor: number) => {
    const token = detectSlashCommandToken(source, cursor);
    if (!token) {
      setSlashMenuOpen(false);
      setSlashRange(null);
      setRichSlashRange(null);
      setSlashQuery("");
      return;
    }
    setSlashMenuOpen(true);
    setSlashRange({ start: token.start, end: token.end });
    setRichSlashRange(null);
    setSlashQuery(token.query);
    setChartMenuOpen(false);
  };
  const replaceRange = (start: number, end: number, markdown: string) => {
    const source = localTextareaRef.current?.value ?? value;
    const before = source.slice(0, start);
    const after = source.slice(end);
    const needsPrefix = before && !before.endsWith("\n") ? "\n" : "";
    const needsSuffix = after && !after.startsWith("\n") ? "\n" : "";
    const inserted = `${needsPrefix}${markdown}${markdown.endsWith("\n") ? "" : "\n"}${needsSuffix}`;
    onChange(`${before}${inserted}${after}`);
    setEditorMode("markdown");
    setSlashMenuOpen(false);
    setSlashRange(null);
    setChartMenuOpen(false);
    window.requestAnimationFrame(() => {
      const cursor = before.length + inserted.length;
      localTextareaRef.current?.focus();
      localTextareaRef.current?.setSelectionRange(cursor, cursor);
    });
  };
  const runRichSlashCommand = (command: NoteSlashCommand) => {
    if (!richEditor) return;
    const range = richSlashRange;
    const chain = richEditor.chain().focus();
    if (range) {
      chain.deleteRange(range).run();
    }
    if (command.id === "heading") richEditor.chain().focus().toggleHeading({ level: 2 }).run();
    else if (command.id === "todo") (richEditor.chain().focus() as any).toggleTaskList().run();
    else if (command.id === "bullets") richEditor.chain().focus().toggleBulletList().run();
    else if (command.id === "numbers") richEditor.chain().focus().toggleOrderedList().run();
    else if (command.id === "quote") richEditor.chain().focus().toggleBlockquote().run();
    else if (command.id === "code") richEditor.chain().focus().toggleCodeBlock().run();
    else if (command.id === "table") (richEditor.chain().focus() as any).insertTable({ rows: 3, cols: 2, withHeaderRow: true }).run();
    else if (command.id === "divider") richEditor.chain().focus().setHorizontalRule().run();
    else (richEditor.chain().focus() as any).insertContent(command.markdown, { contentType: "markdown" }).run();
    syncRichDraft();
    setSlashMenuOpen(false);
    setSlashRange(null);
    setRichSlashRange(null);
    setChartMenuOpen(false);
  };
  const runSlashCommand = (command: NoteSlashCommand) => {
    const textarea = localTextareaRef.current;
    const start = slashRange?.start ?? textarea?.selectionStart ?? value.length;
    const end = slashRange?.end ?? textarea?.selectionEnd ?? start;
    replaceRange(start, end, command.markdown);
  };
  const syncRichDraft = () => {
    if (!richEditor) return;
    const nextMarkdown = normalizeEditorMarkdown(richEditor.getMarkdown());
    if (nextMarkdown === latestValueRef.current) return;
    latestValueRef.current = nextMarkdown;
    onChange(nextMarkdown);
  };
  const applyRichAction = (action: MarkdownAction) => {
    if (!richEditor) return false;
    if (action === "heading") richEditor.chain().focus().toggleHeading({ level: 2 }).run();
    if (action === "bold") richEditor.chain().focus().toggleBold().run();
    if (action === "italic") richEditor.chain().focus().toggleItalic().run();
    if (action === "quote") richEditor.chain().focus().toggleBlockquote().run();
    if (action === "bullet") richEditor.chain().focus().toggleBulletList().run();
    if (action === "task") (richEditor.chain().focus() as any).toggleTaskList().run();
    if (action === "code") richEditor.chain().focus().toggleCodeBlock().run();
    if (action === "table") (richEditor.chain().focus() as any).insertTable({ rows: 3, cols: 2, withHeaderRow: true }).run();
    syncRichDraft();
    return true;
  };
  const applyAction = (action: MarkdownAction) => {
    const textarea = localTextareaRef.current;
    const start = textarea?.selectionStart ?? value.length;
    const end = textarea?.selectionEnd ?? value.length;
    const result = applyMarkdownAction(value, start, end, action);
    onChange(result.value);
    setEditorMode("markdown");
    window.requestAnimationFrame(() => {
      localTextareaRef.current?.focus();
      localTextareaRef.current?.setSelectionRange(result.start, result.end);
    });
  };
  const handleEditorChange = (event: ChangeEvent<HTMLTextAreaElement>) => {
    const nextValue = event.target.value;
    onChange(nextValue);
    updateSlashState(nextValue, event.target.selectionStart ?? nextValue.length);
  };
  const handleEditorKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (!slashMenuOpen) return;
    if (event.key === "Escape") {
      event.preventDefault();
      setSlashMenuOpen(false);
      return;
    }
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setActiveSlashIndex((index) => Math.min(index + 1, Math.max(visibleSlashCommands.length - 1, 0)));
      return;
    }
    if (event.key === "ArrowUp") {
      event.preventDefault();
      setActiveSlashIndex((index) => Math.max(index - 1, 0));
      return;
    }
    if ((event.key === "Enter" || event.key === "Tab") && visibleSlashCommands[activeSlashIndex]) {
      event.preventDefault();
      runSlashCommand(visibleSlashCommands[activeSlashIndex]);
    }
  };
  const updateRichSlashState = () => {
    if (!richEditor || mode !== "preview") return;
    const { from } = richEditor.state.selection;
    const lookBehindFrom = Math.max(0, from - 64);
    const beforeCursor = richEditor.state.doc.textBetween(lookBehindFrom, from, "\n", "\n");
    const match = beforeCursor.match(/(^|[\s([{])\/([a-z0-9_-]*)$/i);
    if (!match) {
      setSlashMenuOpen(false);
      setSlashQuery("");
      setRichSlashRange(null);
      return;
    }
    const query = match[2] ?? "";
    const tokenLength = query.length + 1;
    setSlashMenuOpen(true);
    setSlashRange(null);
    setRichSlashRange({ from: Math.max(0, from - tokenLength), to: from });
    setSlashQuery(query);
    setChartMenuOpen(false);
  };
  const handleRichKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (!slashMenuOpen) return;
    if (event.key === "Escape") {
      event.preventDefault();
      setSlashMenuOpen(false);
      setRichSlashRange(null);
      return;
    }
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setActiveSlashIndex((index) => Math.min(index + 1, Math.max(visibleSlashCommands.length - 1, 0)));
      return;
    }
    if (event.key === "ArrowUp") {
      event.preventDefault();
      setActiveSlashIndex((index) => Math.max(index - 1, 0));
      return;
    }
    if ((event.key === "Enter" || event.key === "Tab") && visibleSlashCommands[activeSlashIndex]) {
      event.preventDefault();
      runRichSlashCommand(visibleSlashCommands[activeSlashIndex]);
    }
  };
  const handleRichKeyUp = (event: KeyboardEvent<HTMLDivElement>) => {
    if (["ArrowDown", "ArrowUp", "Enter", "Tab", "Escape"].includes(event.key)) return;
    updateRichSlashState();
  };
  const insertMermaid = (markdown: string) => {
    const textarea = localTextareaRef.current;
    const source = textarea?.value ?? value;
    const start = textarea?.selectionStart ?? source.length;
    const end = textarea?.selectionEnd ?? source.length;
    const before = source.slice(0, start);
    const after = source.slice(end);
    const prefix = before && !before.endsWith("\n") ? "\n\n" : "";
    const suffix = after && !after.startsWith("\n") ? "\n\n" : "";
    const inserted = `${prefix}${markdown}${suffix}`;
    onChange(`${before}${inserted}${after}`);
    setChartMenuOpen(false);
    setEditorMode("markdown");
    window.requestAnimationFrame(() => {
      const cursor = before.length + inserted.length;
      localTextareaRef.current?.focus();
      localTextareaRef.current?.setSelectionRange(cursor, cursor);
    });
  };
  const selectedText = () => {
    const textarea = localTextareaRef.current;
    if (!textarea) return "";
    return textarea.value.slice(textarea.selectionStart, textarea.selectionEnd);
  };
  const selectedRichText = () => {
    if (!richEditor) return "";
    const { from, to } = richEditor.state.selection;
    if (from === to) return "";
    return richEditor.state.doc.textBetween(from, to, "\n", "\n");
  };
  const replaceSelectionWith = (text: string) => {
    const textarea = localTextareaRef.current;
    const source = textarea?.value ?? value;
    const start = textarea?.selectionStart ?? source.length;
    const end = textarea?.selectionEnd ?? start;
    const nextValue = `${source.slice(0, start)}${text}${source.slice(end)}`;
    onChange(nextValue);
    setEditorMode("markdown");
    window.requestAnimationFrame(() => {
      localTextareaRef.current?.focus();
      const cursor = start + text.length;
      localTextareaRef.current?.setSelectionRange(cursor, cursor);
    });
  };
  const pasteFromClipboard = async () => {
    const text = await (window.openAssistElectron?.readClipboardText?.() ?? navigator.clipboard?.readText?.() ?? Promise.resolve(""));
    if (text) replaceSelectionWith(text);
  };
  const pasteIntoRichEditor = async () => {
    if (!richEditor) return;
    const text = await (window.openAssistElectron?.readClipboardText?.() ?? navigator.clipboard?.readText?.() ?? Promise.resolve(""));
    if (!text) return;
    (richEditor.chain().focus() as any).insertContent(text, { contentType: "markdown" }).run();
    syncRichDraft();
  };
  const richFormattingItems = (): SidebarMenuItem[] => [
    { id: "rich-heading", label: "Heading", icon: <Heading2 size={14} />, onSelect: () => applyRichAction("heading") },
    { id: "rich-bold", label: "Bold", icon: <Bold size={14} />, onSelect: () => applyRichAction("bold") },
    { id: "rich-italic", label: "Italic", icon: <Italic size={14} />, onSelect: () => applyRichAction("italic") },
    { id: "rich-bullet", label: "Bulleted List", icon: <List size={14} />, onSelect: () => applyRichAction("bullet") },
    { id: "rich-task", label: "Task List", icon: <ListTodo size={14} />, onSelect: () => applyRichAction("task") },
    { id: "rich-quote", label: "Quote", icon: <MessageSquare size={14} />, onSelect: () => applyRichAction("quote") },
    { id: "rich-code", label: "Code Block", icon: <Code2 size={14} />, onSelect: () => applyRichAction("code") },
    { id: "rich-table", label: "Table", icon: <Table2 size={14} />, onSelect: () => applyRichAction("table") }
  ];
  const openEditorContextMenu = (event: React.MouseEvent<HTMLTextAreaElement>) => {
    event.preventDefault();
    event.stopPropagation();
    const text = selectedText();
    setEditorContextMenu({
      ...menuPosition(event),
      title: "Edit note",
      items: [
        {
          id: "cut",
          label: "Cut",
          icon: <ClipboardPaste size={14} />,
          disabled: !text,
          onSelect: () => {
            writeTextToClipboard(text);
            replaceSelectionWith("");
          }
        },
        {
          id: "copy",
          label: "Copy",
          icon: <Copy size={14} />,
          disabled: !text,
          onSelect: () => writeTextToClipboard(text)
        },
        {
          id: "paste",
          label: "Paste",
          icon: <ClipboardPaste size={14} />,
          onSelect: () => { void pasteFromClipboard(); }
        },
        { id: "divider-edit", label: "" },
        {
          id: "select-all",
          label: "Select All",
          icon: <Command size={14} />,
          onSelect: () => {
            window.requestAnimationFrame(() => {
              localTextareaRef.current?.focus();
              localTextareaRef.current?.select();
            });
          }
        },
        { id: "divider-format", label: "" },
        {
          id: "format-menu",
          label: "Formatting",
          icon: <Heading2 size={14} />,
          children: [
            { id: "format-heading", label: "Heading", icon: <Heading2 size={14} />, onSelect: () => applyAction("heading") },
            { id: "format-bold", label: "Bold", icon: <Bold size={14} />, onSelect: () => applyAction("bold") },
            { id: "format-italic", label: "Italic", icon: <Italic size={14} />, onSelect: () => applyAction("italic") },
            { id: "format-bullets", label: "Bulleted List", icon: <List size={14} />, onSelect: () => applyAction("bullet") },
            { id: "format-task", label: "Task List", icon: <ListTodo size={14} />, onSelect: () => applyAction("task") },
            { id: "format-code", label: "Code Block", icon: <Code2 size={14} />, onSelect: () => applyAction("code") }
          ]
        },
        {
          id: "slash-commands",
          label: "Slash Commands",
          icon: <WandSparkles size={14} />,
          onSelect: () => {
            setSlashQuery("");
            setSlashMenuOpen(true);
          }
        }
      ]
    });
  };
  const openRichEditorContextMenu = (event: React.MouseEvent<HTMLDivElement>) => {
    if (!richEditor) return;
    event.preventDefault();
    event.stopPropagation();
    const text = selectedRichText();
    setEditorContextMenu({
      ...menuPosition(event),
      title: text ? "Selection" : "Edit note",
      items: [
        {
          id: "rich-cut",
          label: "Cut",
          icon: <ClipboardPaste size={14} />,
          disabled: !text,
          onSelect: () => {
            writeTextToClipboard(text);
            richEditor.chain().focus().deleteSelection().run();
            syncRichDraft();
          }
        },
        {
          id: "rich-copy",
          label: "Copy",
          icon: <Copy size={14} />,
          disabled: !text,
          onSelect: () => writeTextToClipboard(text)
        },
        {
          id: "rich-paste",
          label: "Paste",
          icon: <ClipboardPaste size={14} />,
          onSelect: () => { void pasteIntoRichEditor(); }
        },
        {
          id: "rich-select-all",
          label: "Select All",
          icon: <Command size={14} />,
          onSelect: () => richEditor.chain().focus().selectAll().run()
        },
        { id: "rich-divider-format", label: "" },
        {
          id: "rich-format-menu",
          label: "Formatting",
          icon: <Heading2 size={14} />,
          children: richFormattingItems()
        },
        {
          id: "rich-link",
          label: "Insert Link",
          icon: <ExternalLink size={14} />,
          onSelect: () => runRichSlashCommand(noteSlashCommands.find((command) => command.id === "link") ?? noteSlashCommands[0])
        },
        {
          id: "rich-slash-commands",
          label: "Slash Commands",
          icon: <WandSparkles size={14} />,
          onSelect: () => {
            richEditor.commands.focus();
            setSlashQuery("");
            setRichSlashRange(null);
            setSlashMenuOpen(true);
          }
        }
      ]
    });
  };
  const renderSlashMenu = () => slashMenuOpen ? (
    <div className="slash-command-popover" role="listbox" aria-label="Note slash commands">
      <div className="slash-command-header">
        <WandSparkles size={15} />
        <span>{slashQuery ? `/${slashQuery}` : "Slash commands"}</span>
      </div>
      {visibleSlashCommands.length > 0 ? (
        visibleSlashCommands.map((command, index) => (
          <button
            key={command.id}
            className={cx(index === activeSlashIndex && "active")}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => runSlashCommand(command)}
          >
            <span className="slash-command-icon">{command.icon}</span>
            <span>
              <strong>{command.label}</strong>
              <small>{command.description}</small>
            </span>
          </button>
        ))
      ) : (
        <p>No command found.</p>
      )}
    </div>
  ) : null;

  return (
    <div className={cx("markdown-editor-surface", compact && "compact")}>
      <div className="note-format-toolbar">
        <button type="button" title="Heading" onClick={() => applyAction("heading")}><Heading2 size={15} /></button>
        <button type="button" title="Bold" onClick={() => applyAction("bold")}><Bold size={15} /></button>
        <button type="button" title="Italic" onClick={() => applyAction("italic")}><Italic size={15} /></button>
        <button type="button" title="Quote" onClick={() => applyAction("quote")}><MessageSquare size={15} /></button>
        <button type="button" title="Bulleted list" onClick={() => applyAction("bullet")}><List size={15} /></button>
        <button type="button" title="Task list" onClick={() => applyAction("task")}><ListTodo size={15} /></button>
        <button type="button" title="Code" onClick={() => applyAction("code")}><Code2 size={15} /></button>
        <button type="button" title="Table" onClick={() => applyAction("table")}><Table2 size={15} /></button>
        <span className="toolbar-divider" />
        <div className="chart-template-wrap" ref={chartMenuRef}>
          <button type="button" onClick={() => setChartMenuOpen((current) => !current)}>
            <CircleGauge size={15} />
            Insert chart
          </button>
          {chartMenuOpen && (
            <div className="chart-template-popover">
              {threadNoteChartTemplates.map((template) => (
                <button type="button" key={template.id} onClick={() => insertMermaid(template.markdown)}>
                  <strong>{template.label}</strong>
                  <small>{template.description}</small>
                </button>
              ))}
            </div>
          )}
        </div>
        <span className="toolbar-spacer" />
        {saveStatusLabel && (
          <span className={cx("note-format-toolbar-status", saveStatusKind && `state-${saveStatusKind}`)}>
            {saveStatusLabel}
          </span>
        )}
        {showSaveButton && onSave && (
          <button
            type="button"
            title="Save note"
            className="note-format-toolbar-save"
            onClick={onSave}
          >
            <Save size={13} />
          </button>
        )}
        <button type="button" className={cx(mode === "markdown" && "active")} onClick={() => setEditorMode("markdown")}>Markdown</button>
        <button type="button" className={cx(mode === "preview" && "active")} onClick={() => setEditorMode("preview")}>Preview</button>
      </div>
      {mode === "preview" ? (
        <div className="markdown-editor-body preview-editor-body">
          <MarkdownPreview markdown={value} sourcePath={sourcePath} />
        </div>
      ) : (
        <div className="markdown-editor-body">
          {renderSlashMenu()}
          <textarea
            ref={assignTextareaRef}
            value={value}
            onChange={handleEditorChange}
            onKeyDown={handleEditorKeyDown}
            onClick={(event) => updateSlashState(event.currentTarget.value, event.currentTarget.selectionStart ?? value.length)}
            onContextMenu={openEditorContextMenu}
            placeholder={placeholder}
            spellCheck={false}
          />
          <FloatingContextMenu menu={editorContextMenu} onClose={() => setEditorContextMenu(null)} />
        </div>
      )}
    </div>
  );
}

type SpeechRecognitionLike = {
  continuous: boolean;
  interimResults: boolean;
  lang: string;
  start: () => void;
  stop: () => void;
  abort: () => void;
  onstart: (() => void) | null;
  onend: (() => void) | null;
  onerror: ((event: { error?: string; message?: string }) => void) | null;
  onresult: ((event: {
    resultIndex: number;
    results: ArrayLike<{ isFinal: boolean; 0: { transcript: string } }>;
  }) => void) | null;
};

type SpeechRecognitionConstructor = new () => SpeechRecognitionLike;

const providerMarks: Partial<Record<ProviderKey, string>> = {
  codex: codexMark,
  copilot: copilotMark,
  claudeCode: claudeMark,
  ollamaLocal: ollamaMark
};

type SidebarIconComponent = ComponentType<{ size?: number | string; strokeWidth?: number | string; className?: string }>;

const viewItems: Array<{ key: ViewKey; label: string; icon: SidebarIconComponent }> = [
  { key: "threads", label: "Threads", icon: MessageSquare },
  { key: "notes", label: "Notes", icon: NotebookTabs },
  { key: "automations", label: "Automations", icon: CalendarClock },
  { key: "skills", label: "Skills", icon: Sparkles },
  { key: "plugins", label: "Plugins", icon: Plug }
];

type ProjectIconPreset = {
  id: string;
  label: string;
  symbol: string;
  keywords: string[];
  Icon: SidebarIconComponent;
};

const projectIconPresets: ProjectIconPreset[] = [
  { id: "folder", label: "Folder", symbol: "folder.fill", keywords: ["folder", "directory"], Icon: Folder },
  { id: "stack", label: "Stack", symbol: "square.stack.3d.up.fill", keywords: ["stack", "layer", "square.stack"], Icon: Layers3 },
  { id: "briefcase", label: "Briefcase", symbol: "briefcase.fill", keywords: ["briefcase", "bag", "suitcase"], Icon: BriefcaseBusiness },
  { id: "book", label: "Book", symbol: "book.closed.fill", keywords: ["book", "library", "read", "journal"], Icon: BookOpen },
  { id: "terminal", label: "Terminal", symbol: "terminal.fill", keywords: ["terminal", "command", "shell", "prompt"], Icon: Terminal },
  { id: "sparkles", label: "Sparkles", symbol: "sparkles", keywords: ["sparkle", "magic", "wand", "shine", "ai"], Icon: Sparkles },
  { id: "star", label: "Star", symbol: "star.fill", keywords: ["star", "favorite"], Icon: Star },
  { id: "brain", label: "Brain", symbol: "brain.head.profile", keywords: ["brain", "mind", "intelligence", "head.profile"], Icon: Brain },
  { id: "code", label: "Code", symbol: "chevron.left.forwardslash.chevron.right", keywords: ["code", "forwardslash", "developer", "bracket", "brace"], Icon: Code2 },
  { id: "cpu", label: "CPU", symbol: "cpu.fill", keywords: ["cpu", "chip", "processor", "server"], Icon: Cpu },
  { id: "monitor", label: "Monitor", symbol: "display.2", keywords: ["display", "screen", "monitor", "desktop", "computer"], Icon: Monitor },
  { id: "paintbrush", label: "Paintbrush", symbol: "paintbrush.fill", keywords: ["paint", "brush", "palette", "color", "art"], Icon: Paintbrush },
  { id: "hammer", label: "Hammer", symbol: "hammer.fill", keywords: ["hammer", "tool", "build", "repair", "wrench"], Icon: Hammer },
  { id: "shield", label: "Shield", symbol: "shield.fill", keywords: ["shield", "lock", "secure", "security"], Icon: Shield },
  { id: "package", label: "Package", symbol: "shippingbox.fill", keywords: ["shippingbox", "package", "box", "archive"], Icon: PackageCheck },
  { id: "message", label: "Message", symbol: "message.fill", keywords: ["message", "chat", "bubble", "comment"], Icon: MessageSquare },
  { id: "zap", label: "Zap", symbol: "bolt.fill", keywords: ["bolt", "zap", "flash", "lightning"], Icon: Zap },
  { id: "git", label: "Branch", symbol: "arrow.triangle.branch", keywords: ["branch", "git", "merge", "source control"], Icon: GitBranch },
  { id: "gauge", label: "Gauge", symbol: "gauge.with.dots.needle.50percent", keywords: ["gauge", "chart", "meter", "dashboard", "speed"], Icon: CircleGauge },
  { id: "file", label: "Document", symbol: "doc.text.fill", keywords: ["doc", "document", "file", "text", "paper"], Icon: FileText }
];

const projectIconPresetBySymbol = new Map(projectIconPresets.map((preset) => [preset.symbol.toLowerCase(), preset]));

function defaultProjectIconSymbol(project?: Pick<ProjectItem, "kind" | "linkedFolderPath">) {
  if (project?.kind === "folder") return "folder.fill";
  if (project?.linkedFolderPath?.trim()) return "folder.fill";
  return "book.closed.fill";
}

function projectIconPreset(project?: Pick<ProjectItem, "icon" | "kind" | "linkedFolderPath">) {
  const normalized = String(project?.icon || defaultProjectIconSymbol(project)).trim().toLowerCase();
  const directMatch = projectIconPresetBySymbol.get(normalized);
  if (directMatch) return directMatch;
  return projectIconPresets.find((preset) => preset.keywords.some((keyword) => normalized.includes(keyword)))
    ?? projectIconPresetBySymbol.get(defaultProjectIconSymbol(project).toLowerCase())
    ?? projectIconPresets[0];
}

function projectIcon(project: ProjectItem) {
  const iconProps = { size: 18, strokeWidth: 1.9 };
  const { Icon } = projectIconPreset(project);
  return <Icon {...iconProps} />;
}

function cx(...classes: Array<string | false | null | undefined>) {
  return classes.filter(Boolean).join(" ");
}

function useOutsideDismiss(active: boolean, containerRef: RefObject<HTMLElement | null>, onDismiss: () => void) {
  const dismissRef = useRef(onDismiss);

  useEffect(() => {
    dismissRef.current = onDismiss;
  }, [onDismiss]);

  useEffect(() => {
    if (!active) return undefined;

    const handlePointerDown = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (containerRef.current?.contains(target)) return;
      dismissRef.current();
    };

    const handleKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") dismissRef.current();
    };

    document.addEventListener("pointerdown", handlePointerDown, true);
    document.addEventListener("keydown", handleKeyDown, true);
    return () => {
      document.removeEventListener("pointerdown", handlePointerDown, true);
      document.removeEventListener("keydown", handleKeyDown, true);
    };
  }, [active, containerRef]);
}

function cssKey(value?: string) {
  return (value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function providerKey(raw?: string): ProviderKey {
  const value = (raw || "").toLowerCase();
  if (value.includes("copilot") || value.includes("github")) return "copilot";
  if (value.includes("claude")) return "claudeCode";
  if (value.includes("ollama")) return "ollamaLocal";
  return "codex";
}

function isRuntimeProviderKey(key: ProviderKey): key is RuntimeProviderKey {
  return key === "codex" || key === "copilot" || key === "claudeCode" || key === "ollamaLocal";
}

function runtimeProviderKey(raw?: string): RuntimeProviderKey {
  const key = providerKey(raw);
  return isRuntimeProviderKey(key) ? key : "codex";
}

function availableRuntimeProviderOptions(settings?: SettingsSnapshot): RuntimeProviderOption[] {
  const current = runtimeProviderKey(settings?.assistantBackend || "codex");
  const allowed = new Set<RuntimeProviderKey>();
  for (const rawBackend of settings?.availableAssistantBackends ?? []) {
    const key = providerKey(rawBackend);
    if (isRuntimeProviderKey(key)) allowed.add(key);
  }
  if (!allowed.size) {
    for (const option of runtimeProviderOptions) allowed.add(option.key);
  }
  allowed.add(current);
  return runtimeProviderOptions.map((option) => ({
    ...option,
    detail: allowed.has(option.key) ? option.detail : setupRequiredDetails[option.key]
  }));
}

function speechRecognitionConstructor(): SpeechRecognitionConstructor | undefined {
  const speechWindow = window as Window & {
    SpeechRecognition?: SpeechRecognitionConstructor;
    webkitSpeechRecognition?: SpeechRecognitionConstructor;
  };
  return speechWindow.SpeechRecognition ?? speechWindow.webkitSpeechRecognition;
}

function appendVoiceDraft(baseText: string, voiceText: string) {
  const base = baseText.trimEnd();
  const voice = voiceText.trim();
  if (!base) return voice;
  if (!voice) return base;
  return `${base}${base.endsWith("\n") ? "" : " "}${voice}`;
}

function isEditableTextInput(element: Element | null): element is HTMLInputElement | HTMLTextAreaElement {
  if (element instanceof HTMLTextAreaElement) return !element.disabled && !element.readOnly;
  if (!(element instanceof HTMLInputElement) || element.disabled || element.readOnly) return false;
  const editableTypes = new Set(["", "text", "search", "url", "tel", "email", "password"]);
  return editableTypes.has(element.type);
}

function insertTextIntoFocusedAppField(text: string) {
  const activeElement = document.activeElement;
  if (isEditableTextInput(activeElement)) {
    const start = activeElement.selectionStart ?? activeElement.value.length;
    const end = activeElement.selectionEnd ?? activeElement.value.length;
    const before = activeElement.value.slice(0, start);
    const after = activeElement.value.slice(end);
    const normalizedText = text.trim();
    const leadingSpace = before && !/\s$/.test(before) ? " " : "";
    const trailingSpace = after && !/^\s/.test(after) ? " " : "";
    const insertedText = `${leadingSpace}${normalizedText}${trailingSpace}`;
    const nextValue = `${before}${insertedText}${after}`;
    const valueSetter = Object.getOwnPropertyDescriptor(
      activeElement instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype,
      "value"
    )?.set;
    valueSetter?.call(activeElement, nextValue);
    if (!valueSetter) activeElement.value = nextValue;
    const nextCursor = before.length + insertedText.length;
    try {
      activeElement.setSelectionRange(nextCursor, nextCursor);
    } catch {
      // Some input types do not support selection ranges.
    }
    activeElement.dispatchEvent(new Event("input", { bubbles: true }));
    return true;
  }

  if (activeElement instanceof HTMLElement && activeElement.isContentEditable) {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || !activeElement.contains(selection.anchorNode)) return false;
    const range = selection.getRangeAt(0);
    range.deleteContents();
    const textNode = document.createTextNode(text.trim());
    range.insertNode(textNode);
    range.setStartAfter(textNode);
    range.setEndAfter(textNode);
    selection.removeAllRanges();
    selection.addRange(range);
    activeElement.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text.trim() }));
    return true;
  }

  return false;
}

function withTimeout<T>(promise: Promise<T> | undefined, timeoutMs: number, message: string) {
  if (!promise) return Promise.resolve(undefined);
  return new Promise<T>((resolve, reject) => {
    const timeout = window.setTimeout(() => reject(new Error(message)), timeoutMs);
    promise
      .then(resolve, reject)
      .finally(() => window.clearTimeout(timeout));
  });
}

function ProviderMark({ provider, className }: { provider?: string; className?: string }) {
  const key = providerKey(provider);
  const mark = providerMarks[key];
  return (
    <span className={cx("provider-mark", `provider-mark-${key}`, className)} aria-hidden="true">
      {mark ? (
        <span
          className="provider-mark-glyph provider-mark-image"
          style={{
            WebkitMaskImage: `url("${mark}")`,
            maskImage: `url("${mark}")`
          } as CSSProperties}
        />
      ) : (
        <Bot size={14} />
      )}
    </span>
  );
}

function RealtimeVoiceMark({ size = 16, active = false }: { size?: number; active?: boolean }) {
  return (
    <svg
      className={cx("realtime-voice-mark", active && "active")}
      width={size}
      height={size}
      viewBox="0 0 32 32"
      role="img"
      aria-label="Realtime voice"
      focusable="false"
    >
      <circle className="realtime-voice-mark-disc" cx="16" cy="16" r="15" />
      <rect className="realtime-voice-mark-bar" x="6.7" y="13.2" width="2.8" height="5.6" rx="1.4" />
      <rect className="realtime-voice-mark-bar" x="10.9" y="8.8" width="2.8" height="14.4" rx="1.4" />
      <rect className="realtime-voice-mark-bar" x="15.1" y="5.6" width="2.8" height="20.8" rx="1.4" />
      <rect className="realtime-voice-mark-bar" x="19.3" y="8.8" width="2.8" height="14.4" rx="1.4" />
      <rect className="realtime-voice-mark-bar" x="23.5" y="13.2" width="2.8" height="5.6" rx="1.4" />
    </svg>
  );
}

function formatWorkingElapsed(seconds: number) {
  if (seconds < 3) return "";
  if (seconds < 60) return `${seconds}s`;
  if (seconds >= 3600) {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    return minutes ? `${hours}h ${minutes}m` : `${hours}h`;
  }
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = seconds % 60;
  return `${minutes}m ${remainingSeconds}s`;
}

function activityStatusLabel(status: ChatMessage["activityStatus"]) {
  if (status === "running") return "Running";
  if (status === "waiting") return "Waiting";
  if (status === "failed") return "Failed";
  if (status === "pending") return "Pending";
  return "Done";
}

function fileNameFromPath(value?: string | null) {
  const text = String(value ?? "").trim();
  if (!text) return "";
  return text.split(/[\\/]/).filter(Boolean).pop() ?? text;
}

function compactPath(value?: string | null) {
  const text = String(value ?? "").trim();
  if (!text) return "";
  const parts = text.split(/[\\/]/).filter(Boolean);
  if (parts.length <= 2) return text;
  return `${parts[parts.length - 2]}/${parts[parts.length - 1]}`;
}

function normalizeActivityRawDetail(raw: string) {
  let detail = raw.replace(/^Command\n/, "").trim();
  while (detail.startsWith("{}")) detail = detail.slice(2).trim();
  return detail;
}

function parseActivityPayload(detail: string): Record<string, unknown> | null {
  if (!detail.startsWith("{") || !detail.endsWith("}")) return null;
  try {
    const parsed = JSON.parse(detail);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : null;
  } catch {
    return null;
  }
}

function stringValue(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}

function numberValue(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function activitySummaryFromPayload(title: string, payload: Record<string, unknown>) {
  const filePath = stringValue(payload.file_path ?? payload.filePath ?? payload.path);
  const pattern = stringValue(payload.pattern ?? payload.query ?? payload.q);
  const command = stringValue(payload.command ?? payload.cmd);
  const url = stringValue(payload.url);
  const offset = numberValue(payload.offset);
  const limit = numberValue(payload.limit ?? payload.line_count ?? payload.head_limit);
  const outputMode = stringValue(payload.output_mode);

  if (/grep|search/i.test(title) && pattern) {
    return [pattern, filePath ? `in ${compactPath(filePath)}` : "", outputMode ? `as ${outputMode}` : ""]
      .filter(Boolean)
      .join(" ");
  }
  if (/read file/i.test(title) && filePath) {
    return [
      compactPath(filePath),
      offset !== null ? `offset ${offset}` : "",
      limit !== null ? `${limit} lines` : ""
    ].filter(Boolean).join(" · ");
  }
  if (filePath) return compactPath(filePath);
  if (command) return command;
  if (url) return url;
  if (pattern) return pattern;
  return "";
}

function fallbackActivitySummary(detail: string) {
  const filePath = detail.match(/"file_path"\s*:\s*"([^"]+)"/)?.[1]
    ?? detail.match(/"path"\s*:\s*"([^"]+)"/)?.[1];
  const pattern = detail.match(/"pattern"\s*:\s*"([^"]+)"/)?.[1];
  const offset = detail.match(/"offset"\s*:\s*(\d+)/)?.[1];
  const limit = detail.match(/"limit"\s*:\s*(\d+)/)?.[1];
  if (pattern && filePath) return `${pattern} in ${compactPath(filePath)}`;
  if (filePath) return [compactPath(filePath), offset ? `offset ${offset}` : "", limit ? `${limit} lines` : ""].filter(Boolean).join(" · ");
  return "";
}

function formatActivityDetail(detail: string, payload: Record<string, unknown> | null) {
  if (payload) return JSON.stringify(payload, null, 2);
  return detail;
}

function activityPresentation(title: string, rawDetail: string) {
  const detail = normalizeActivityRawDetail(rawDetail);
  const payload = parseActivityPayload(detail);
  const payloadSummary = payload ? activitySummaryFromPayload(title, payload) : "";
  const summary = payloadSummary || fallbackActivitySummary(detail) || detail;
  return {
    summary: summary.length > 170 ? `${summary.slice(0, 167)}...` : summary,
    detail: formatActivityDetail(detail, payload)
  };
}

function activityPreviewURL(activity: ChatMessage) {
  const dataURL = String(activity.imageDataURL ?? "").trim();
  return dataURL.startsWith("data:image/") ? dataURL : "";
}

function openImagePreviewDataURL(dataURL?: string) {
  const normalized = String(dataURL ?? "").trim();
  if (!normalized.startsWith("data:image/")) return;
  void window.openAssistElectron?.openImageInPreview?.(normalized);
}

function openActivityPreview(event: React.MouseEvent, activity: ChatMessage) {
  event.preventDefault();
  event.stopPropagation();
  openImagePreviewDataURL(activityPreviewURL(activity));
}

function ActivityImageThumbnail({
  activity,
  className,
  label = "Open image in Preview"
}: {
  activity: ChatMessage;
  className?: string;
  label?: string;
}) {
  const dataURL = activityPreviewURL(activity);
  if (!dataURL) return null;
  const alt = activity.imageName || activity.imagePrompt || activity.activityTitle || "Tool image";
  return (
    <button
      type="button"
      className={cx("activity-image-thumb", className)}
      aria-label={label}
      title={label}
      onClick={(event) => openActivityPreview(event, activity)}
    >
      <img src={dataURL} alt={alt} draggable={false} />
      <span className="activity-image-thumb-icon" aria-hidden="true">
        <Eye size={11} />
      </span>
    </button>
  );
}

function ActivityPreviewStrip({
  activities,
  className
}: {
  activities: ChatMessage[];
  className?: string;
}) {
  const previewActivities = activities.filter(activityPreviewURL).slice(-4);
  if (!previewActivities.length) return null;
  return (
    <div className={cx("activity-preview-strip", className)} aria-label="Tool images">
      {previewActivities.map((activity) => (
        <ActivityImageThumbnail key={activity.id} activity={activity} label="Open image in Preview" />
      ))}
    </div>
  );
}

function WorkspaceTargetIcon({ target, size = 20 }: { target?: WorkspaceLaunchTargetSnapshot; size?: number }) {
  if (target?.iconDataURL) {
    return <img className="workspace-target-icon" src={target.iconDataURL} alt="" draggable={false} style={{ width: size, height: size }} />;
  }
  const iconSize = Math.max(14, size - 1);
  if (target?.fallbackSymbol === "folder") return <Folder className="workspace-target-fallback" size={iconSize} />;
  if (target?.fallbackSymbol === "terminal") return <Terminal className="workspace-target-fallback" size={iconSize} />;
  if (target?.fallbackSymbol === "sparkles") return <Sparkles className="workspace-target-fallback" size={iconSize} />;
  if (target?.fallbackSymbol === "command") return <Command className="workspace-target-fallback" size={iconSize} />;
  if (target?.fallbackSymbol === "wind") return <Wind className="workspace-target-fallback" size={iconSize} />;
  if (target?.fallbackSymbol === "hammer") return <Hammer className="workspace-target-fallback" size={iconSize} />;
  return <Code2 className="workspace-target-fallback" size={iconSize} />;
}

function AppMark() {
  return (
    <div className="app-mark" aria-hidden="true">
      <span />
      <Code2 size={16} strokeWidth={2.1} />
    </div>
  );
}

function IconButton({
  label,
  children,
  tone = "subtle",
  active,
  className,
  disabled,
  onClick
}: {
  label: string;
  children: React.ReactNode;
  tone?: "subtle" | "gold" | "blue" | "danger";
  active?: boolean;
  className?: string;
  disabled?: boolean;
  onClick?: () => void;
}) {
  return (
    <button
      className={cx("icon-button", `icon-button-${tone}`, active && "active", className)}
      aria-label={label}
      title={label}
      disabled={disabled}
      onClick={onClick}
    >
      {children}
    </button>
  );
}

function PillButton({
  children,
  active,
  className,
  icon,
  onClick
}: {
  children: React.ReactNode;
  active?: boolean;
  className?: string;
  icon?: React.ReactNode;
  onClick?: () => void;
}) {
  if (!onClick) {
    return (
      <span className={cx("pill-button", className, "pill-static", active && "pill-button-active")}>
        {icon}
        <span>{children}</span>
      </span>
    );
  }
  return (
    <button className={cx("pill-button", className, active && "pill-button-active")} onClick={onClick}>
      {icon}
      <span>{children}</span>
    </button>
  );
}

type SidebarContextMenuState =
  | { kind: "projects"; x: number; y: number }
  | { kind: "project"; x: number; y: number; projectID: string }
  | { kind: "thread"; x: number; y: number; threadID: string };

type SidebarMenuItem = {
  id: string;
  label: string;
  icon?: ReactNode;
  danger?: boolean;
  disabled?: boolean;
  onSelect?: () => void;
  children?: SidebarMenuItem[];
};

type FloatingContextMenuState = {
  x: number;
  y: number;
  title: string;
  items: SidebarMenuItem[];
};

function menuPosition(event: React.MouseEvent) {
  const width = 312;
  const height = 360;
  return {
    x: Math.min(event.clientX, Math.max(12, window.innerWidth - width - 12)),
    y: Math.min(event.clientY, Math.max(12, window.innerHeight - height - 12))
  };
}

function FloatingContextMenu({
  menu,
  onClose
}: {
  menu: FloatingContextMenuState | null;
  onClose: () => void;
}) {
  const [submenu, setSubmenu] = useState<string | null>(null);
  useEffect(() => setSubmenu(null), [menu]);
  if (!menu) return null;

  const renderItem = (item: SidebarMenuItem, depth = 0) => {
    if (!item.label) return <div key={item.id} className="sidebar-context-divider" />;
    const hasChildren = Boolean(item.children?.length);
    return (
      <div
        key={item.id}
        className="sidebar-context-item-wrap"
        onMouseEnter={() => {
          if (hasChildren) setSubmenu(item.id);
          else if (depth === 0) setSubmenu(null);
        }}
      >
        <button
          className={cx("sidebar-context-item", item.danger && "danger")}
          disabled={item.disabled}
          onClick={() => {
            if (item.disabled) return;
            if (hasChildren) {
              setSubmenu(item.id);
              return;
            }
            onClose();
            item.onSelect?.();
          }}
        >
          <span className="sidebar-context-icon">{item.icon}</span>
          <span>{item.label}</span>
          {hasChildren && <ChevronRight size={13} />}
        </button>
        {hasChildren && submenu === item.id && (
          <div className="sidebar-context-submenu">
            {item.children?.map((child) => renderItem(child, depth + 1))}
          </div>
        )}
      </div>
    );
  };

  return createPortal(
    <>
      <button className="sidebar-context-scrim" aria-label="Close context menu" onClick={onClose} onContextMenu={(event) => { event.preventDefault(); onClose(); }} />
      <div className="sidebar-context-menu" style={{ left: menu.x, top: menu.y }} role="menu" onContextMenu={(event) => event.preventDefault()}>
        <div className="sidebar-context-title">{menu.title}</div>
        {menu.items.map(renderItem)}
      </div>
    </>,
    document.body
  );
}


function SidebarContextMenu({
  state,
  projects,
  hiddenProjects,
  threads,
  selectedThreadID,
  onClose,
  onCreateProject,
  onOpenProjectNotes,
  onOpenThreadNote,
  onCreateThreadNote,
  onOpenThreadMemory,
  onOpenThreadInstructions,
  onOpenProjectMemory,
  onRenameProject,
  onUpdateProjectIcon,
  onLinkProjectFolder,
  onRemoveProjectFolderLink,
  onMoveProjectToFolder,
  onHideProject,
  onUnhideProject,
  onDeleteProject,
  onRenameThread,
  onPromoteTemporaryThread,
  onAssignThreadToProject,
  onArchiveThread,
  onUnarchiveThread,
  onDeleteThreadPermanently
}: {
  state: SidebarContextMenuState | null;
  projects: ProjectItem[];
  hiddenProjects: ProjectItem[];
  threads: ThreadItem[];
  selectedThreadID?: string;
  onClose: () => void;
  onCreateProject: (name: string, kind: "project" | "folder", parentID?: string) => Promise<void>;
  onOpenProjectNotes: (projectID: string) => void;
  onOpenThreadNote: (thread: ThreadItem) => void;
  onCreateThreadNote: (thread: ThreadItem) => void;
  onOpenThreadMemory: (thread: ThreadItem) => void;
  onOpenThreadInstructions: (thread: ThreadItem) => void;
  onOpenProjectMemory: (projectID: string) => void;
  onRenameProject: (project: ProjectItem) => void;
  onUpdateProjectIcon: (project: ProjectItem, symbol?: string | null) => void;
  onLinkProjectFolder: (project: ProjectItem) => void;
  onRemoveProjectFolderLink: (project: ProjectItem) => void;
  onMoveProjectToFolder: (project: ProjectItem, folderID?: string | null) => void;
  onHideProject: (project: ProjectItem) => void;
  onUnhideProject: (project: ProjectItem) => void;
  onDeleteProject: (project: ProjectItem) => void;
  onRenameThread: (thread: ThreadItem) => void;
  onPromoteTemporaryThread: (thread: ThreadItem) => void;
  onAssignThreadToProject: (thread: ThreadItem, projectID?: string | null) => void;
  onArchiveThread: (thread: ThreadItem) => void;
  onUnarchiveThread: (thread: ThreadItem) => void;
  onDeleteThreadPermanently: (thread: ThreadItem) => void;
}) {
  const [submenu, setSubmenu] = useState<string | null>(null);
  useEffect(() => setSubmenu(null), [state]);
  if (!state) return null;

  const selectedThread = selectedThreadID ? threads.find((thread) => thread.id === selectedThreadID) : undefined;
  const leafProjects = projects.filter((project) => project.kind !== "folder");
  const folders = projects.filter((project) => project.kind === "folder");
  const projectMoveItems = (project: ProjectItem): SidebarMenuItem[] => [
    ...folders
      .filter((folder) => folder.id !== project.id)
      .map((folder) => ({
        id: `move-project-${folder.id}`,
        label: folder.title,
        icon: <Folder size={14} />,
        disabled: project.parentID === folder.id,
        onSelect: () => onMoveProjectToFolder(project, folder.id)
      })),
    {
      id: "move-project-root",
      label: "No Group",
      icon: <FolderMinus size={14} />,
      disabled: !project.parentID,
      onSelect: () => onMoveProjectToFolder(project, null)
    }
  ];
  const threadProjectItems = (thread: ThreadItem): SidebarMenuItem[] => leafProjects.map((project) => ({
    id: `thread-project-${project.id}`,
    label: project.title,
    icon: projectIcon(project),
    disabled: thread.projectID === project.id,
    onSelect: () => onAssignThreadToProject(thread, project.id)
  }));
  const projectIconItems = (project: ProjectItem): SidebarMenuItem[] => [
    {
      id: "project-icon-default",
      label: "Use Default Icon",
      icon: <RefreshCw size={14} />,
      onSelect: () => onUpdateProjectIcon(project, null)
    },
    { id: "divider-project-icons-a", label: "" },
    ...projectIconPresets.map((preset) => ({
      id: `project-icon-${preset.id}`,
      label: preset.label,
      icon: <preset.Icon size={14} />,
      onSelect: () => onUpdateProjectIcon(project, preset.symbol)
    }))
  ];

  let title = "";
  let items: SidebarMenuItem[] = [];
  if (state.kind === "projects") {
    title = "Projects";
    items = [
      {
        id: "create-project",
        label: "New Project",
        icon: <FolderPlus size={14} />,
        onSelect: () => {
          const name = window.prompt("Project name");
          if (name?.trim()) void onCreateProject(name.trim(), "project");
        }
      },
      {
        id: "create-group",
        label: "New Group",
        icon: <Folder size={14} />,
        onSelect: () => {
          const name = window.prompt("Group name");
          if (name?.trim()) void onCreateProject(name.trim(), "folder");
        }
      },
      { id: "divider-hidden-projects", label: "" },
      ...(hiddenProjects.length ? [
        {
          id: "unhide-projects",
          label: "Unhide Project or Group",
          icon: <Eye size={14} />,
          children: hiddenProjects.map((project) => ({
            id: `unhide-project-${project.id}`,
            label: `${project.kind === "folder" ? "Group" : "Project"}: ${project.title}`,
            icon: project.kind === "folder" ? <Folder size={14} /> : projectIcon(project),
            onSelect: () => onUnhideProject(project)
          }))
        }
      ] : [
        {
          id: "no-hidden-projects",
          label: "No Hidden Projects",
          icon: <EyeOff size={14} />,
          disabled: true
        }
      ])
    ];
  } else if (state.kind === "project") {
    const project = projects.find((item) => item.id === state.projectID);
    if (!project) return null;
    const isProject = project.kind !== "folder";
    const canMoveSelectedThread = Boolean(selectedThread && selectedThread.projectID !== project.id && isProject);
    title = project.title;
    items = [
      ...(isProject ? [
        { id: "project-notes", label: "Project Notes", icon: <NotebookTabs size={14} />, onSelect: () => onOpenProjectNotes(project.id) },
        { id: "project-memory", label: "View Memory", icon: <Brain size={14} />, onSelect: () => onOpenProjectMemory(project.id) },
        ...(canMoveSelectedThread && selectedThread ? [
          { id: "move-current-here", label: `Move "${selectedThread.title}" Here`, icon: <ArrowDownCircle size={14} />, onSelect: () => onAssignThreadToProject(selectedThread, project.id) }
        ] : []),
        { id: "divider-project-top", label: "" }
      ] : []),
      { id: "rename-project", label: isProject ? "Rename Project" : "Rename Group", icon: <Pencil size={14} />, onSelect: () => onRenameProject(project) },
      { id: "change-project-icon", label: "Change Icon", icon: projectIcon(project), children: projectIconItems(project) },
      ...(isProject ? [
        { id: "link-folder", label: project.linkedFolderPath ? "Change Folder" : "Link Folder", icon: <FolderPlus size={14} />, onSelect: () => onLinkProjectFolder(project) },
        { id: "move-project", label: "Move to Group", icon: <Folder size={14} />, children: projectMoveItems(project) },
        ...(project.linkedFolderPath ? [
          { id: "remove-folder-link", label: "Remove Folder Link", icon: <FolderMinus size={14} />, onSelect: () => onRemoveProjectFolderLink(project) }
        ] : [])
      ] : [
        {
          id: "create-inside-group",
          label: "Create Project Inside Group",
          icon: <Plus size={14} />,
          onSelect: () => {
            const name = window.prompt("Project name");
            if (name?.trim()) void onCreateProject(name.trim(), "project", project.id);
          }
        }
      ]),
      { id: "divider-project-bottom", label: "" },
      { id: "hide-project", label: isProject ? "Hide Project" : "Hide Group", icon: <EyeOff size={14} />, onSelect: () => onHideProject(project) },
      { id: "delete-project", label: isProject ? "Delete Project" : "Delete Group", icon: <Trash2 size={14} />, danger: true, onSelect: () => onDeleteProject(project) }
    ];
  } else {
    const thread = threads.find((item) => item.id === state.threadID);
    if (!thread) return null;
    title = thread.title;
    if (thread.isArchived) {
      items = [
        { id: "unarchive-session", label: "Unarchive Session", icon: <Archive size={14} />, onSelect: () => onUnarchiveThread(thread) },
        { id: "divider-archived", label: "" },
        { id: "delete-session", label: "Delete Permanently", icon: <Trash2 size={14} />, danger: true, onSelect: () => onDeleteThreadPermanently(thread) }
      ];
    } else {
      items = [
        { id: "open-thread-note", label: "Open Thread Notes", icon: <NotebookTabs size={14} />, onSelect: () => onOpenThreadNote(thread) },
        { id: "new-thread-note", label: "New Thread Note", icon: <FilePlus2 size={14} />, onSelect: () => onCreateThreadNote(thread) },
        { id: "thread-memory", label: "View Memory", icon: <Brain size={14} />, onSelect: () => onOpenThreadMemory(thread) },
        { id: "thread-instructions", label: "Session Instructions", icon: <ListTodo size={14} />, onSelect: () => onOpenThreadInstructions(thread) },
        { id: "divider-thread-side-panel", label: "" },
        { id: "rename-session", label: "Rename Session", icon: <Pencil size={14} />, onSelect: () => onRenameThread(thread) },
        ...(thread.isTemporary ? [
          { id: "promote-session", label: "Keep as Regular Chat", icon: <Pin size={14} />, onSelect: () => onPromoteTemporaryThread(thread) }
        ] : []),
        { id: "divider-thread-top", label: "" },
        leafProjects.length ? {
          id: "move-thread-project",
          label: thread.projectID ? "Move to Project" : "Add to Project",
          icon: <FolderPlus size={14} />,
          children: threadProjectItems(thread)
        } : {
          id: "create-project",
          label: "Create Project",
          icon: <Plus size={14} />,
          onSelect: () => {
            const name = window.prompt("Project name");
            if (name?.trim()) void onCreateProject(name.trim(), "project");
          }
        },
        ...(thread.projectID ? [
          { id: "remove-thread-project", label: "Remove from Project", icon: <FolderMinus size={14} />, onSelect: () => onAssignThreadToProject(thread, null) }
        ] : []),
        { id: "divider-thread-bottom", label: "" },
        { id: "archive-session", label: "Archive Session", icon: <Archive size={14} />, onSelect: () => onArchiveThread(thread) }
      ];
    }
  }

  const renderItem = (item: SidebarMenuItem, depth = 0) => {
    if (!item.label) return <div key={item.id} className="sidebar-context-divider" />;
    const hasChildren = Boolean(item.children?.length);
    return (
      <div
        key={item.id}
        className="sidebar-context-item-wrap"
        onMouseEnter={() => {
          if (hasChildren) setSubmenu(item.id);
          else if (depth === 0) setSubmenu(null);
        }}
      >
        <button
          className={cx("sidebar-context-item", item.danger && "danger")}
          disabled={item.disabled}
          onClick={() => {
            if (item.disabled) return;
            if (hasChildren) {
              setSubmenu(item.id);
              return;
            }
            onClose();
            item.onSelect?.();
          }}
        >
          <span className="sidebar-context-icon">{item.icon}</span>
          <span>{item.label}</span>
          {hasChildren && <ChevronRight size={13} />}
        </button>
        {hasChildren && submenu === item.id && (
          <div className="sidebar-context-submenu">
            {item.children?.map((child) => renderItem(child, depth + 1))}
          </div>
        )}
      </div>
    );
  };

  return createPortal(
    <>
      <button className="sidebar-context-scrim" aria-label="Close sidebar menu" onClick={onClose} onContextMenu={(event) => { event.preventDefault(); onClose(); }} />
      <div data-sidebar-context-menu="true" className="sidebar-context-menu" style={{ left: state.x, top: state.y }} role="menu" onContextMenu={(event) => event.preventDefault()}>
        <div className="sidebar-context-title">{title}</div>
        {items.map(renderItem)}
      </div>
    </>,
    document.body
  );
}

function SidebarNotesSection({
  projects,
  selectedProjectID,
  notesScope,
  notes,
  threadNotes,
  noteFolders,
  activeNoteTarget,
  onSelectScope,
  onSelectNote,
  onSelectThreadNoteItem,
  onOpenThreadFromNote
}: {
  projects: ProjectItem[];
  selectedProjectID?: string;
  notesScope: NotesScope;
  notes: NoteItem[];
  threadNotes: ThreadNoteListItem[];
  noteFolders: NoteFolderItem[];
  activeNoteTarget?: SelectedNoteTarget | null;
  onSelectScope: (scope: NotesScope) => void;
  onSelectNote: (note: NoteItem) => void;
  onSelectThreadNoteItem: (note: ThreadNoteListItem) => void;
  onOpenThreadFromNote: (note: ThreadNoteListItem) => void;
}) {
  const [selectedFolderID, setSelectedFolderID] = useState<string | null>(null);
  const [noteSearch, setNoteSearch] = useState("");
  const [noteContextMenu, setNoteContextMenu] = useState<FloatingContextMenuState | null>(null);
  const visibleProjects = useMemo(
    () => projects.filter((project) => project.kind !== "folder"),
    [projects]
  );
  const selectedProject =
    visibleProjects.find((project) => sameID(project.id, selectedProjectID))
    ?? visibleProjects[0];
  const projectNotes = useMemo(
    () => notes.filter((note) => selectedProject && sameID(note.projectID, selectedProject.id)),
    [notes, selectedProject]
  );
  const projectThreadNotes = useMemo(
    () => threadNotes.filter((note) => selectedProject && sameID(note.projectID, selectedProject.id)),
    [threadNotes, selectedProject]
  );
  const projectFolders = useMemo(
    () => noteFolders.filter((folder) => selectedProject && sameID(folder.projectID, selectedProject.id)),
    [noteFolders, selectedProject]
  );

  useEffect(() => {
    setSelectedFolderID(null);
    setNoteSearch("");
  }, [selectedProject?.id, notesScope]);

  const filteredProjectNotes = useMemo(() => {
    const query = noteSearch.trim().toLowerCase();
    return projectNotes
      .filter((note) => !selectedFolderID || note.folderID === selectedFolderID)
      .filter((note) => {
        if (!query) return true;
        return [note.title, note.subtitle, note.projectName]
          .filter(Boolean)
          .some((value) => String(value).toLowerCase().includes(query));
      })
      .slice(0, 32);
  }, [noteSearch, projectNotes, selectedFolderID]);

  const filteredThreadNotes = useMemo(() => {
    const query = noteSearch.trim().toLowerCase();
    return projectThreadNotes
      .filter((note) => {
        if (!query) return true;
        return [note.title, note.subtitle, note.threadTitle, note.projectName]
          .filter(Boolean)
          .some((value) => String(value).toLowerCase().includes(query));
      })
      .slice(0, 32);
  }, [noteSearch, projectThreadNotes]);

  const activeFolder = selectedFolderID
    ? projectFolders.find((folder) => sameID(folder.id, selectedFolderID))
    : null;
  const projectNoteCountLabel = `${projectNotes.length} ${projectNotes.length === 1 ? "note" : "notes"}`;
  const threadNoteCountLabel = `${projectThreadNotes.length} ${projectThreadNotes.length === 1 ? "note" : "notes"}`;
  const activeFolderCountLabel = activeFolder
    ? `${activeFolder.noteCount} ${activeFolder.noteCount === 1 ? "note" : "notes"}`
    : "";
  const helperText = !selectedProject
    ? "Choose which project's notes you want to browse."
    : notesScope === "project"
      ? projectNotes.length
        ? `Shared notes for ${selectedProject.title}.`
        : `Shared notes for ${selectedProject.title} will show here.`
      : projectThreadNotes.length
        ? `Thread notes from chats that belong to ${selectedProject.title}.`
      : `No thread notes yet for ${selectedProject.title}.`;

  const openProjectNoteMenu = (event: React.MouseEvent, note: NoteItem) => {
    event.preventDefault();
    event.stopPropagation();
    setNoteContextMenu({
      ...menuPosition(event),
      title: note.title,
      items: [
        { id: "open-note", label: "Open Note", icon: <BookOpen size={14} />, onSelect: () => onSelectNote(note) },
        { id: "copy-note-title", label: "Copy Note Title", icon: <Copy size={14} />, onSelect: () => writeTextToClipboard(note.title) },
        { id: "copy-note-id", label: "Copy Note ID", icon: <Command size={14} />, onSelect: () => writeTextToClipboard(note.id) }
      ]
    });
  };

  const openThreadNoteMenu = (event: React.MouseEvent, note: ThreadNoteListItem) => {
    event.preventDefault();
    event.stopPropagation();
    setNoteContextMenu({
      ...menuPosition(event),
      title: note.title,
      items: [
        { id: "open-thread-note", label: "Open Thread Note", icon: <MessageSquare size={14} />, onSelect: () => onSelectThreadNoteItem(note) },
        { id: "open-owning-thread", label: "Open Owning Thread", icon: <ArrowUpRightSquare size={14} />, onSelect: () => onOpenThreadFromNote(note) },
        { id: "divider-thread-note-link", label: "" },
        { id: "copy-thread-note-title", label: "Copy Note Title", icon: <Copy size={14} />, onSelect: () => writeTextToClipboard(note.title) },
        { id: "copy-thread-title", label: "Copy Chat Title", icon: <MessageSquare size={14} />, onSelect: () => writeTextToClipboard(note.threadTitle) }
      ]
    });
  };

  return (
    <div className="sidebar-notes-block">
      <p className="sidebar-section-helper">{helperText}</p>
      <div className="sidebar-note-scope segmented">
        <button className={cx(notesScope === "project" && "selected")} onClick={() => onSelectScope("project")}>
          Project notes
        </button>
        <button className={cx(notesScope === "thread" && "selected")} onClick={() => onSelectScope("thread")}>
          Thread notes
        </button>
      </div>
      <label className="search-field sidebar-search-field">
        <Search size={15} />
        <input
          placeholder={notesScope === "project" ? "Search notes" : "Search thread notes"}
          value={noteSearch}
          onChange={(event) => setNoteSearch(event.target.value)}
        />
      </label>
      {notesScope === "project" && (
        <>
          {selectedFolderID && (
            <button className="note-row" onClick={() => setSelectedFolderID(null)}>
              <NotebookTabs size={16} />
              <span>
                All project notes
                <small>{projectNoteCountLabel}</small>
              </span>
            </button>
          )}
          {activeFolder && (
            <button className="note-row active" onClick={() => setSelectedFolderID(null)}>
              <Folder size={16} />
              <span>
                {activeFolder.name}
                <small>{activeFolderCountLabel}</small>
              </span>
            </button>
          )}
          {!activeFolder && projectFolders.slice(0, 8).map((folder) => (
            <button key={`${folder.projectID}-${folder.id}`} className="note-row" onClick={() => setSelectedFolderID(folder.id)}>
              <Folder size={16} />
              <span>
                {folder.name}
                <small>{folder.noteCount} notes</small>
              </span>
            </button>
          ))}
          {filteredProjectNotes.map((note) => (
            <button
              key={`${note.projectID}-${note.id}`}
              className={cx("note-row", activeNoteTarget?.scope === "project" && sameID(note.id, activeNoteTarget.noteID) && "active")}
              onClick={() => onSelectNote(note)}
              onContextMenu={(event) => openProjectNoteMenu(event, note)}
            >
              <BookOpen size={16} />
              <span>
                {note.title}
                <small>{note.subtitle}</small>
              </span>
            </button>
          ))}
          {filteredProjectNotes.length === 0 && <p className="empty-inline">No project notes match this view.</p>}
        </>
      )}
      {notesScope === "thread" && (
        <>
          <div className="notes-scope-summary">
            <MessageSquare size={15} />
            <span>{threadNoteCountLabel}</span>
          </div>
          {filteredThreadNotes.map((note) => (
            <button
              key={`${note.threadID}-${note.id}`}
              className={cx("note-row", activeNoteTarget?.scope === "thread" && sameID(note.id, activeNoteTarget.noteID) && sameID(note.threadID, activeNoteTarget.threadID) && "active")}
              onClick={() => onSelectThreadNoteItem(note)}
              onContextMenu={(event) => openThreadNoteMenu(event, note)}
            >
              <MessageSquare size={16} />
              <span>
                {note.title}
                <small>{note.subtitle}</small>
              </span>
            </button>
          ))}
          {filteredThreadNotes.length === 0 && <p className="empty-inline">No thread notes match this view.</p>}
        </>
      )}
      <FloatingContextMenu menu={noteContextMenu} onClose={() => setNoteContextMenu(null)} />
    </div>
  );
}

function Sidebar({
  activeView,
  onChangeView,
  onOpenSettings,
  compact,
  onCollapseSidebar,
  projects,
  hiddenProjects,
  threads,
  notes,
  threadNotes,
  noteFolders,
  selectedProjectID,
  selectedThreadID,
  activeNoteTarget,
  notesScope,
  showArchivedThreads,
  archivedCount,
  onSelectProject,
  onClearProjectFilter,
  onSelectThread,
  onSelectNotesScope,
  onSelectNote,
  onSelectThreadNoteItem,
  onOpenThreadFromNote,
  onToggleArchivedThreads,
  onCreateProject,
  onCreateThread,
  onCreateTemporaryThread,
  onCreateNote,
  sidebarWidth,
  onResizeSidebar,
  onResizingSidebarChange,
  onHideSidebar,
  onOpenProjectNotes,
  onOpenProjectMemory,
  onOpenThreadNote,
  onCreateThreadNote,
  onOpenThreadMemory,
  onOpenThreadInstructions,
  onRenameProject,
  onUpdateProjectIcon,
  onLinkProjectFolder,
  onRemoveProjectFolderLink,
  onMoveProjectToFolder,
  onHideProject,
  onUnhideProject,
  onDeleteProject,
  onRenameThread,
  onPromoteTemporaryThread,
  onAssignThreadToProject,
  onArchiveThread,
  onUnarchiveThread,
  onDeleteThreadPermanently
}: {
  activeView: ViewKey;
  onChangeView: (view: ViewKey) => void;
  onOpenSettings: () => void;
  compact: boolean;
  onCollapseSidebar: () => void;
  projects: ProjectItem[];
  hiddenProjects: ProjectItem[];
  threads: ThreadItem[];
  notes: NoteItem[];
  threadNotes: ThreadNoteListItem[];
  noteFolders: NoteFolderItem[];
  selectedProjectID?: string;
  selectedThreadID?: string;
  activeNoteTarget?: SelectedNoteTarget | null;
  notesScope: NotesScope;
  showArchivedThreads: boolean;
  archivedCount: number;
  onSelectProject: (projectID: string) => void;
  onClearProjectFilter: () => void;
  onSelectThread: (threadID: string) => void;
  onSelectNotesScope: (scope: NotesScope) => void;
  onSelectNote: (note: NoteItem) => void;
  onSelectThreadNoteItem: (note: ThreadNoteListItem) => void;
  onOpenThreadFromNote: (note: ThreadNoteListItem) => void;
  onToggleArchivedThreads: () => void;
  onCreateProject: (name: string, kind: "project" | "folder", parentID?: string) => Promise<void>;
  onCreateThread: () => void;
  onCreateTemporaryThread: () => void;
  onCreateNote: () => void;
  sidebarWidth: number;
  onResizeSidebar: (next: number) => void;
  onResizingSidebarChange: (resizing: boolean) => void;
  onHideSidebar: () => void;
  onOpenProjectNotes: (projectID: string) => void;
  onOpenProjectMemory: (projectID: string) => void;
  onOpenThreadNote: (thread: ThreadItem) => void;
  onCreateThreadNote: (thread: ThreadItem) => void;
  onOpenThreadMemory: (thread: ThreadItem) => void;
  onOpenThreadInstructions: (thread: ThreadItem) => void;
  onRenameProject: (project: ProjectItem) => void;
  onUpdateProjectIcon: (project: ProjectItem, symbol?: string | null) => void;
  onLinkProjectFolder: (project: ProjectItem) => void;
  onRemoveProjectFolderLink: (project: ProjectItem) => void;
  onMoveProjectToFolder: (project: ProjectItem, folderID?: string | null) => void;
  onHideProject: (project: ProjectItem) => void;
  onUnhideProject: (project: ProjectItem) => void;
  onDeleteProject: (project: ProjectItem) => void;
  onRenameThread: (thread: ThreadItem) => void;
  onPromoteTemporaryThread: (thread: ThreadItem) => void;
  onAssignThreadToProject: (thread: ThreadItem, projectID?: string | null) => void;
  onArchiveThread: (thread: ThreadItem) => void;
  onUnarchiveThread: (thread: ThreadItem) => void;
  onDeleteThreadPermanently: (thread: ThreadItem) => void;
}) {
  const [threadLimit, setThreadLimit] = useState(28);
  const [isCreatingProject, setIsCreatingProject] = useState(false);
  const [projectsCollapsed, setProjectsCollapsed] = useState(false);
  const [threadsCollapsed, setThreadsCollapsed] = useState(false);
  const [notesCollapsed, setNotesCollapsed] = useState(false);
  const [collapsedProjectIDs, setCollapsedProjectIDs] = useState<Set<string>>(() => new Set());
  const [projectDraftKind, setProjectDraftKind] = useState<"project" | "folder">("project");
  const [projectDraftName, setProjectDraftName] = useState("");
  const [contextMenu, setContextMenu] = useState<SidebarContextMenuState | null>(null);
  const visibleThreads = useMemo(() => {
    const firstPage = threads.slice(0, threadLimit);
    const selected = selectedThreadID ? threads.find((thread) => thread.id === selectedThreadID) : undefined;
    if (!selected || firstPage.some((thread) => thread.id === selected.id)) return firstPage;
    return [selected, ...firstPage.slice(0, Math.max(0, threadLimit - 1))];
  }, [selectedThreadID, threadLimit, threads]);
  const hasMoreThreads = visibleThreads.length < threads.length;
  const selectedProject = projects.find((project) => project.id === selectedProjectID);
  const createParentID = projectDraftKind === "project" && selectedProject?.kind === "folder" ? selectedProject.id : undefined;
  const showThreadSection = activeView === "threads";
  const showNotesSection = activeView === "notes";
  const projectIDKey = (id?: string | null) => (id ?? "").trim().toLowerCase();
  const noteCountByProjectID = useMemo(() => {
    const counts = new Map<string, number>();
    for (const note of notes) {
      const key = projectIDKey(note.projectID);
      if (!key) continue;
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
    return counts;
  }, [notes]);
  const projectChildrenByParentID = useMemo(() => {
    const projectsByID = new Map(projects.map((project) => [projectIDKey(project.id), project]));
    const childrenByParent = new Map<string, ProjectItem[]>();
    for (const project of projects) {
      const parentKey = projectIDKey(project.parentID);
      if (!parentKey || !projectsByID.has(parentKey)) continue;
      childrenByParent.set(parentKey, [...(childrenByParent.get(parentKey) ?? []), project]);
    }
    return childrenByParent;
  }, [projects]);
  const projectNoteCount = (project: ProjectItem): number => {
    const key = projectIDKey(project.id);
    if (!key) return 0;
    if (project.kind !== "folder") return noteCountByProjectID.get(key) ?? 0;
    const children = projectChildrenByParentID.get(key) ?? [];
    return children.reduce((sum, child) => sum + projectNoteCount(child), 0);
  };
  const projectSidebarSubtitle = (project: ProjectItem) => {
    if (!showNotesSection) return project.subtitle;
    const count = projectNoteCount(project);
    if (project.kind === "folder") {
      const childCount = projectChildrenByParentID.get(projectIDKey(project.id))?.filter((child) => child.kind !== "folder").length ?? 0;
      const projectLabel = `${childCount || 0} ${childCount === 1 ? "project" : "projects"}`;
      return `${projectLabel} · ${count ? `${count} ${count === 1 ? "note" : "notes"}` : "no notes"}`;
    }
    return count ? `${count} ${count === 1 ? "note" : "notes"} here` : "No notes yet";
  };
  const visibleProjectRows = useMemo(() => {
    const projectsByID = new Map(projects.map((project) => [projectIDKey(project.id), project]));
    const rows: Array<{ project: ProjectItem; depth: number; hasChildren: boolean; collapsed: boolean }> = [];
    const visited = new Set<string>();
    const appendProject = (project: ProjectItem, depth: number) => {
      const key = projectIDKey(project.id);
      if (!key || visited.has(key)) return;
      visited.add(key);
      const children = projectChildrenByParentID.get(key) ?? [];
      const collapsed = collapsedProjectIDs.has(key);
      rows.push({ project, depth, hasChildren: children.length > 0, collapsed });
      if (!collapsed) {
        for (const child of children) appendProject(child, depth + 1);
      }
    };
    for (const project of projects) {
      const parentKey = projectIDKey(project.parentID);
      if (!parentKey || !projectsByID.has(parentKey)) appendProject(project, 0);
    }
    for (const project of projects) appendProject(project, 0);
    return rows;
  }, [collapsedProjectIDs, projectChildrenByParentID, projects]);
  const saveProjectDraft = async () => {
    const name = projectDraftName.trim();
    if (!name) return;
    await onCreateProject(name, projectDraftKind, createParentID);
    setProjectDraftName("");
    setProjectDraftKind("project");
    setIsCreatingProject(false);
  };
  const toggleProjectDisclosure = (projectID: string) => {
    const key = projectIDKey(projectID);
    if (!key) return;
    setCollapsedProjectIDs((current) => {
      const next = new Set(current);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };
  useEffect(() => {
    if (!selectedProjectID) return;
    const projectsByID = new Map(projects.map((project) => [projectIDKey(project.id), project]));
    const parentKeys = new Set<string>();
    let current = projectsByID.get(projectIDKey(selectedProjectID));
    while (current?.parentID) {
      const parentKey = projectIDKey(current.parentID);
      if (!parentKey || parentKeys.has(parentKey)) break;
      parentKeys.add(parentKey);
      current = projectsByID.get(parentKey);
    }
    if (!parentKeys.size) return;
    setCollapsedProjectIDs((collapsed) => {
      if (![...parentKeys].some((key) => collapsed.has(key))) return collapsed;
      const next = new Set(collapsed);
      for (const key of parentKeys) next.delete(key);
      return next;
    });
  }, [projects, selectedProjectID]);
  useEffect(() => {
    if (!contextMenu) return undefined;
    const close = () => setContextMenu(null);
    const onScroll = (event: Event) => {
      const target = event.target;
      if (target instanceof Node) {
        const activeMenu = document.querySelector('[data-sidebar-context-menu="true"]');
        if (activeMenu?.contains(target)) return;
      }
      close();
    };
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") close();
    };
    window.addEventListener("scroll", onScroll, true);
    window.addEventListener("resize", close);
    window.addEventListener("keydown", onKeyDown);
    return () => {
      window.removeEventListener("scroll", onScroll, true);
      window.removeEventListener("resize", close);
      window.removeEventListener("keydown", onKeyDown);
    };
  }, [contextMenu]);
  const openProjectsContextMenu = (event: React.MouseEvent) => {
    event.preventDefault();
    event.stopPropagation();
    setContextMenu({ kind: "projects", ...menuPosition(event) });
  };
  const openProjectsMenuFromButton = (event: React.MouseEvent<HTMLElement>) => {
    event.preventDefault();
    event.stopPropagation();
    const rect = event.currentTarget.getBoundingClientRect();
    setContextMenu({
      kind: "projects",
      x: Math.min(rect.left, Math.max(12, window.innerWidth - 312)),
      y: Math.min(rect.bottom + 6, Math.max(12, window.innerHeight - 360))
    });
  };

  return (
    <aside className={cx("app-sidebar", showNotesSection && "sidebar-notes-mode", !(showThreadSection || showNotesSection) && "sidebar-projects-only")}>
      <div className="traffic-spacer" />
      <div className="nav-block">
        {viewItems.map((item) => {
          const Icon = item.icon;
          return (
            <button
              key={item.key}
              className={cx("nav-item", activeView === item.key && "active")}
              onClick={() => onChangeView(item.key)}
            >
              <Icon size={19} strokeWidth={2} />
              <span>{item.label}</span>
              {item.key === "threads" && !compact && (
                <span
                  role="button"
                  tabIndex={0}
                  aria-label="Hide sidebar"
                  title="Hide sidebar"
                  className="sidebar-collapse-button"
                  onClick={(event) => {
                    event.stopPropagation();
                    onHideSidebar();
                  }}
                  onKeyDown={(event) => {
                    if (event.key === "Enter" || event.key === " ") {
                      event.preventDefault();
                      event.stopPropagation();
                      onHideSidebar();
                    }
                  }}
                >
                  <PanelLeftClose size={15} strokeWidth={2} />
                </span>
              )}
            </button>
          );
        })}
        {compact && (
          <button className="nav-item sidebar-hide-action" onClick={onCollapseSidebar}>
            <ChevronRight size={19} strokeWidth={1.9} />
            <span>Hide sidebar</span>
          </button>
        )}
      </div>

      <div className="sidebar-section-heading" onContextMenu={openProjectsContextMenu}>
        <button
          className="section-heading-toggle"
          aria-expanded={!projectsCollapsed}
          onClick={() => setProjectsCollapsed((value) => !value)}
        >
          <span>Projects</span>
          {projectsCollapsed ? <ChevronRight size={13} /> : <ChevronDown size={13} />}
        </button>
        <span className="section-heading-spacer" />
        {showThreadSection && selectedProjectID && (
          <button
            className="project-filter-clear"
            aria-label="Show all threads"
            title="Show all threads"
            onClick={onClearProjectFilter}
          >
            All
          </button>
        )}
        <button
          className="mini-add"
          aria-label="Create group or project"
          onClick={() => {
            setProjectsCollapsed(false);
            setIsCreatingProject((value) => !value);
          }}
        >
          <FolderPlus size={16} strokeWidth={1.9} />
        </button>
        {hiddenProjects.length > 0 && (
          <button
            className="mini-add"
            aria-label="Show hidden projects"
            title="Show hidden projects"
            onClick={openProjectsMenuFromButton}
          >
            <EyeOff size={15} strokeWidth={1.9} />
          </button>
        )}
      </div>

      {showNotesSection && (
        <p className="sidebar-section-helper project-helper">Choose which project's notes you want to browse.</p>
      )}

      {!projectsCollapsed && isCreatingProject && (
        <div className="project-create-panel">
          <div className="segmented compact-segmented">
            <button className={cx(projectDraftKind === "project" && "selected")} onClick={() => setProjectDraftKind("project")}>Project</button>
            <button className={cx(projectDraftKind === "folder" && "selected")} onClick={() => setProjectDraftKind("folder")}>Group</button>
          </div>
          <input
            value={projectDraftName}
            onChange={(event) => setProjectDraftName(event.target.value)}
            placeholder={projectDraftKind === "folder" ? "Group name" : "Project name"}
            onKeyDown={(event) => {
              if (event.key === "Enter") void saveProjectDraft();
              if (event.key === "Escape") setIsCreatingProject(false);
            }}
          />
          {createParentID && <small>Inside {selectedProject?.title}</small>}
          <div className="project-create-actions">
            <button onClick={() => setIsCreatingProject(false)}>Cancel</button>
            <button disabled={!projectDraftName.trim()} onClick={() => void saveProjectDraft()}>Create</button>
          </div>
        </div>
      )}

      {!projectsCollapsed && (
      <div className="project-list">
        {visibleProjectRows.map(({ project, depth, hasChildren, collapsed }) => (
          <button
            key={project.id}
            className={cx("project-row", sameID(project.id, selectedProjectID) && "expanded")}
            style={{ paddingLeft: 8 + depth * 24 }}
            onClick={() => onSelectProject(project.id)}
            onContextMenu={(event) => {
              event.preventDefault();
              event.stopPropagation();
              setContextMenu({ kind: "project", projectID: project.id, ...menuPosition(event) });
            }}
          >
            <span className="project-indent">
              {hasChildren && (
                <span
                  role="button"
                  tabIndex={0}
                  className="project-disclosure"
                  aria-label={collapsed ? `Expand ${project.title}` : `Collapse ${project.title}`}
                  aria-expanded={!collapsed}
                  onClick={(event) => {
                    event.preventDefault();
                    event.stopPropagation();
                    toggleProjectDisclosure(project.id);
                  }}
                  onKeyDown={(event) => {
                    if (event.key === "Enter" || event.key === " ") {
                      event.preventDefault();
                      event.stopPropagation();
                      toggleProjectDisclosure(project.id);
                    }
                  }}
                >
                  {collapsed ? <ChevronRight size={14} /> : <ChevronDown size={14} />}
                </span>
              )}
            </span>
            <span className="project-icon">{projectIcon(project)}</span>
            <span className="project-copy">
              <strong>{project.title}</strong>
              <small>{projectSidebarSubtitle(project)}</small>
            </span>
          </button>
        ))}
      </div>
      )}

      {showThreadSection && (
        <>
          <div className="sidebar-section-heading threads-heading">
            <button
              className="section-heading-toggle"
              aria-expanded={!threadsCollapsed}
              onClick={() => setThreadsCollapsed((value) => !value)}
            >
              <span>{showArchivedThreads ? "Archived" : "Threads"}</span>
              {threadsCollapsed ? <ChevronRight size={13} /> : <ChevronDown size={13} />}
            </button>
            <span className="section-heading-spacer" />
            <button
              className="mini-add"
              aria-label="New thread"
            onClick={() => {
              setThreadsCollapsed(false);
              onCreateThread();
            }}
          >
              <MessageSquarePlus size={16} strokeWidth={1.9} />
            </button>
            <button
              className="mini-add"
              aria-label="New temporary chat"
              title="New temporary chat"
              onClick={() => {
                setThreadsCollapsed(false);
                onCreateTemporaryThread();
              }}
            >
              <ShieldPlus size={15} strokeWidth={1.85} />
            </button>
          </div>
          {!threadsCollapsed && (
          <div className="thread-list">
            {visibleThreads.map((thread) => (
              <button
                key={thread.id}
                className={cx(
                  "thread-row",
                  `thread-row-provider-${runtimeProviderKey(thread.activeProvider)}`,
                  (selectedThreadID ? thread.id === selectedThreadID : thread.active) && "active"
                )}
                onClick={() => onSelectThread(thread.id)}
                onContextMenu={(event) => {
                  event.preventDefault();
                  event.stopPropagation();
                  setContextMenu({ kind: "thread", threadID: thread.id, ...menuPosition(event) });
                }}
              >
                <span className="thread-title">{thread.title}</span>
                <span className="thread-age">{thread.age}</span>
                {(thread.isTemporary || thread.project) && <small>{thread.isTemporary ? "Temporary" : thread.project}</small>}
              </button>
            ))}
            {hasMoreThreads && (
              <button className="thread-row show-more-row" onClick={() => setThreadLimit((value) => Math.min(value + 28, threads.length))}>
                <span className="thread-title">Show more threads</span>
                <span className="thread-age">{visibleThreads.length}/{threads.length}</span>
                <small>Load the next page</small>
              </button>
            )}
          </div>
          )}
        </>
      )}

      {showNotesSection && (
        <>
          <div className="sidebar-section-heading threads-heading notes-heading">
            <button
              className="section-heading-toggle"
              aria-expanded={!notesCollapsed}
              onClick={() => setNotesCollapsed((value) => !value)}
            >
              <span>Notes</span>
              {notesCollapsed ? <ChevronRight size={13} /> : <ChevronDown size={13} />}
            </button>
            <span className="section-heading-spacer" />
            <button
              className="mini-add"
              aria-label="New project note"
              title="New project note"
              onClick={() => {
                setNotesCollapsed(false);
                onCreateNote();
              }}
        >
          <Plus size={16} strokeWidth={1.9} />
        </button>
      </div>
          {!notesCollapsed && (
            <SidebarNotesSection
              projects={projects}
              selectedProjectID={selectedProjectID}
              notesScope={notesScope}
              notes={notes}
              threadNotes={threadNotes}
              noteFolders={noteFolders}
              activeNoteTarget={activeNoteTarget}
              onSelectScope={onSelectNotesScope}
              onSelectNote={onSelectNote}
              onSelectThreadNoteItem={onSelectThreadNoteItem}
              onOpenThreadFromNote={onOpenThreadFromNote}
            />
          )}
        </>
      )}

      <div className="sidebar-bottom">
        <button className="nav-item" onClick={onOpenSettings}>
          <Settings size={19} />
          <span>Settings</span>
        </button>
        <button className={cx("nav-item", showArchivedThreads && "active")} onClick={onToggleArchivedThreads}>
          <Archive size={19} />
          <span>Archived</span>
          {archivedCount > 0 && <small className="nav-count">{archivedCount}</small>}
        </button>
      </div>
      {!compact && (
        <SidebarResizeHandle
          width={sidebarWidth}
          onResize={onResizeSidebar}
          onResizingChange={onResizingSidebarChange}
        />
      )}
      <SidebarContextMenu
        state={contextMenu}
        projects={projects}
        hiddenProjects={hiddenProjects}
        threads={threads}
        selectedThreadID={selectedThreadID}
        onClose={() => setContextMenu(null)}
        onCreateProject={onCreateProject}
        onOpenProjectNotes={onOpenProjectNotes}
        onOpenProjectMemory={onOpenProjectMemory}
        onOpenThreadNote={onOpenThreadNote}
        onCreateThreadNote={onCreateThreadNote}
        onOpenThreadMemory={onOpenThreadMemory}
        onOpenThreadInstructions={onOpenThreadInstructions}
        onRenameProject={onRenameProject}
        onUpdateProjectIcon={onUpdateProjectIcon}
        onLinkProjectFolder={onLinkProjectFolder}
        onRemoveProjectFolderLink={onRemoveProjectFolderLink}
        onMoveProjectToFolder={onMoveProjectToFolder}
        onHideProject={onHideProject}
        onUnhideProject={onUnhideProject}
        onDeleteProject={onDeleteProject}
        onRenameThread={onRenameThread}
        onPromoteTemporaryThread={onPromoteTemporaryThread}
        onAssignThreadToProject={onAssignThreadToProject}
        onArchiveThread={onArchiveThread}
        onUnarchiveThread={onUnarchiveThread}
        onDeleteThreadPermanently={onDeleteThreadPermanently}
      />
    </aside>
  );
}

function TopBar({
  title,
  subtitle,
  compact,
  onToggleCompact,
  onHideWindow,
  onOpenInstructions,
  onOpenMemory,
  workspaceRootPath
}: {
  title: string;
  subtitle?: string;
  compact: boolean;
  onToggleCompact: () => void;
  onHideWindow: () => void;
  onOpenInstructions: () => void;
  onOpenMemory: () => void;
  workspaceRootPath?: string | null;
}) {
  const [editorOpen, setEditorOpen] = useState(false);
  const editorMenuRef = useRef<HTMLDivElement | null>(null);
  const [workspaceTargets, setWorkspaceTargets] = useState<WorkspaceLaunchTargetSnapshot[]>(fallbackWorkspaceTargets);
  const [preferredWorkspaceTargetID, setPreferredWorkspaceTargetID] = useState(() =>
    window.localStorage.getItem("openassist.workspaceLaunchTargetID") || "vscode"
  );
  const [sidebarPinned, setSidebarPinned] = useState(
    () => window.localStorage.getItem("openassist.sidebarPinned") !== "false"
  );
  useEffect(() => {
    if (!compact) return;
    void window.openAssistElectron?.setSidebarPinned?.(sidebarPinned);
  }, [compact, sidebarPinned]);
  const toggleSidebarPinned = () => {
    setSidebarPinned((current) => {
      const next = !current;
      window.localStorage.setItem("openassist.sidebarPinned", next ? "true" : "false");
      return next;
    });
  };
  const closeMenus = () => {
    setEditorOpen(false);
  };
  useEffect(() => {
    let cancelled = false;
    void window.openAssistElectron?.workspaceLaunchTargets?.().then((targets) => {
      if (!cancelled && Array.isArray(targets) && targets.length) setWorkspaceTargets(targets);
    });
    return () => {
      cancelled = true;
    };
  }, []);
  const primaryWorkspaceTarget =
    workspaceTargets.find((target) => target.id === preferredWorkspaceTargetID && target.isInstalled)
    ?? workspaceTargets.find((target) => target.id === "vscode" && target.isInstalled)
    ?? workspaceTargets.find((target) => target.isInstalled)
    ?? workspaceTargets[0]
    ?? fallbackWorkspaceTargets[0];
  const openWorkspaceTarget = (target: WorkspaceLaunchTargetSnapshot) => {
    if (!target.isInstalled) return;
    if (target.remembersAsPreferred) {
      setPreferredWorkspaceTargetID(target.id);
      window.localStorage.setItem("openassist.workspaceLaunchTargetID", target.id);
    }
    closeMenus();
    void window.openAssistElectron?.openTarget(`workspace:${target.id}`, workspaceRootPath);
  };
  useOutsideDismiss(editorOpen, editorMenuRef, () => setEditorOpen(false));

  return (
    <header className="topbar">
      <div className="topbar-title">
        <strong>{title}</strong>
        {subtitle && <span>{subtitle}</span>}
      </div>
      <div className="topbar-actions">
        <div className="topbar-menu-wrap" ref={editorMenuRef}>
          <div className="workspace-launch-control" title={`Open workspace in ${primaryWorkspaceTarget.title}`}>
            <button
              className="workspace-launch-primary"
              aria-label={`Open workspace in ${primaryWorkspaceTarget.title}`}
              disabled={!primaryWorkspaceTarget.isInstalled}
              onClick={() => openWorkspaceTarget(primaryWorkspaceTarget)}
            >
              <WorkspaceTargetIcon target={primaryWorkspaceTarget} size={20} />
            </button>
            <button
              className="editor-picker workspace-launch-chevron"
              aria-label="Choose workspace editor"
              onClick={() => setEditorOpen((value) => !value)}
            >
              <ChevronDown size={13} />
            </button>
          </div>
          <AnimatePresence>
            {editorOpen && (
              <motion.div {...popoverMotion} className="topbar-popover editor-popover">
                <div className="popover-kicker">Open workspace</div>
                {workspaceTargets.map((target) => {
                  const active = target.id === primaryWorkspaceTarget.id;
                  return (
                    <button
                      key={target.id}
                      className={cx(active && "active")}
                      disabled={!target.isInstalled}
                      onClick={() => openWorkspaceTarget(target)}
                    >
                      <WorkspaceTargetIcon target={target} size={22} />
                      <span>
                        <strong>{target.title}</strong>
                        {!target.isInstalled && <small>Not installed</small>}
                      </span>
                      {active && <Check size={14} />}
                    </button>
                  );
                })}
              </motion.div>
            )}
          </AnimatePresence>
        </div>
        <IconButton label="Session instructions" onClick={() => { closeMenus(); onOpenInstructions(); }}>
          <Tasks size={16} />
        </IconButton>
        <IconButton label="Open memory" onClick={() => { closeMenus(); onOpenMemory(); }}>
          <Brain size={15} strokeWidth={1.8} />
        </IconButton>
        {compact && (
          <IconButton
            label={sidebarPinned ? "Unpin sidebar so it can go behind other windows" : "Pin sidebar so it stays on top"}
            onClick={() => { closeMenus(); toggleSidebarPinned(); }}
          >
            {sidebarPinned ? <Pin size={16} /> : <PinOff size={16} />}
          </IconButton>
        )}
        <IconButton label={compact ? "Open full assistant" : "Back to sidebar view"} onClick={() => { closeMenus(); onToggleCompact(); }}>
          {compact ? <PanelRightClose size={16} strokeWidth={1.8} /> : <SidebarOpen size={16} />}
        </IconButton>
      </div>
    </header>
  );
}

function ComposerContextBar({
  usage,
  providerName,
  providerKey,
  providerOptions,
  providerStatus,
  onSelectProvider
}: {
  usage?: ProviderUsageSnapshot | null;
  providerName: string;
  providerKey: ProviderKey;
  providerOptions: RuntimeProviderOption[];
  providerStatus?: string | null;
  onSelectProvider: (provider: ProviderKey) => void;
}) {
  const windows = [usage?.primary, usage?.secondary].filter(Boolean) as NonNullable<ProviderUsageSnapshot["primary"]>[];
  const context = usage?.context ?? null;
  const [showRemaining, setShowRemaining] = useState(false);
  const [providerOpen, setProviderOpen] = useState(false);
  const providerMenuRef = useRef<HTMLDivElement | null>(null);
  useOutsideDismiss(providerOpen, providerMenuRef, () => setProviderOpen(false));

  return (
    <div className={cx("composer-context-bar usage-footer", `composer-provider-${providerKey}`)}>
      <div className="composer-usage-group composer-usage-group--left" role="status" aria-label="Agent usage">
        <div className="composer-provider-picker" ref={providerMenuRef}>
          <button
            type="button"
            className={cx("profile-pill composer-provider-trigger", providerOpen && "active")}
            title={providerStatus || `Choose assistant provider. Current: ${providerName}`}
            aria-label={`Choose assistant provider. Current: ${providerName}`}
            onClick={() => setProviderOpen((value) => !value)}
          >
            <ProviderMark provider={providerName} />
            <span>{providerName}</span>
            <ChevronDown size={11} />
          </button>
          <AnimatePresence>
            {providerOpen && (
              <motion.div {...popoverMotion} className="composer-popover composer-provider-popover">
                <div className="popover-kicker">Provider</div>
                {providerOptions.map((option) => {
                  const isSelected = option.key === providerKey;
                  return (
                    <button
                      key={option.key}
                      type="button"
                      className={cx("composer-provider-option", `composer-provider-option-${option.key}`, isSelected && "active")}
                      onClick={() => {
                        if (!isSelected) onSelectProvider(option.key);
                        setProviderOpen(false);
                      }}
                    >
                      <ProviderMark provider={option.label} />
                      <span>
                        <strong>{option.label}</strong>
                        <small>{option.detail}</small>
                      </span>
                      {isSelected && <Check size={14} />}
                    </button>
                  );
                })}
                {providerStatus && <p className="composer-provider-status">{providerStatus}</p>}
              </motion.div>
            )}
          </AnimatePresence>
        </div>
        {windows.map((window, index) => {
          const label = window.label || "Usage";
          const usedPercent = Math.round(window.usedPercent);
          const remainingPercent = Math.max(0, 100 - usedPercent);
          const displayPercent = showRemaining ? remainingPercent : usedPercent;
          const value = `${displayPercent}%`;
          const resetText = usageWindowResetText(window);
          const modeLabel = showRemaining ? "left" : "used";
          const title = `${label} ${value} ${modeLabel} · ${resetText} · Double-click to toggle`;
          return (
            <button
              key={`${label}-${index}`}
              type="button"
              className="composer-usage-pill"
              title={title}
              aria-label={title}
              onDoubleClick={() => setShowRemaining((value) => !value)}
            >
              <span className="composer-usage-label">{label}</span>
              <span className="composer-usage-value">{value}</span>
              <span className="composer-usage-tooltip">{`${modeLabel} · ${resetText}`}</span>
            </button>
          );
        })}
        {!windows.length && !context && (
          <span className="composer-usage-pending">
            <Gauge size={13} /> Usage pending
          </span>
        )}
      </div>
      <div className="composer-usage-group composer-usage-group--right" role="status" aria-label="Context usage">
        <ComposerUsageRing
          label="Context"
          percent={context?.usedPercent ?? 0}
          title={context ? contextTooltip(context) : "Context window size will appear after Codex reports this thread usage."}
          muted={!context}
        />
      </div>
    </div>
  );
}

function LiveVoiceStatusPanel({
  status,
  text,
  onOpenSettings
}: {
  status: LiveVoiceStatus;
  text?: string;
  onOpenSettings: () => void;
}) {
  const needsSetup = status === "error" && /openai.*key|realtime.*api key|settings/i.test(text ?? "");
  const rawDisplayText = needsSetup ? "Add an OpenAI API key to use Live Voice" : text;
  const heardUserSpeech = /^heard:\s*/i.test(rawDisplayText ?? "");
  const displayText = heardUserSpeech ? rawDisplayText?.replace(/^heard:\s*/i, "") : rawDisplayText;
  if (status === "idle" || !displayText) return null;

  const labelByStatus: Record<LiveVoiceStatus, string> = {
    idle: "Live Voice",
    connecting: "Connecting",
    listening: heardUserSpeech ? "Heard" : "Listening",
    speaking: "Speaking",
    delegating: "Codex working",
    error: needsSetup ? "Setup needed" : "Needs attention"
  };
  const isActive = status === "listening" || status === "speaking" || status === "delegating";
  const content = (
    <>
      <span className="composer-live-voice-panel-icon" aria-hidden="true">
        <RealtimeVoiceMark size={18} active={isActive} />
      </span>
      <span className="composer-live-voice-panel-copy">
        <span className="composer-live-voice-panel-label">{labelByStatus[status]}</span>
        <span className="composer-live-voice-panel-text">{displayText}</span>
      </span>
    </>
  );

  if (needsSetup) {
    return (
      <button
        type="button"
        className={cx("composer-live-voice-panel", "actionable", `state-${status}`)}
        title="Open Voice settings to add the OpenAI API key"
        aria-label="Open Voice settings to add the OpenAI API key"
        onClick={onOpenSettings}
      >
        <span className="composer-live-voice-panel-main">{content}</span>
        <ChevronRight size={15} />
      </button>
    );
  }

  return (
    <div className={cx("composer-live-voice-panel", `state-${status}`)} role="status" title={displayText}>
      <span className="composer-live-voice-panel-main">{content}</span>
    </div>
  );
}

function shouldShowLiveVoiceStatusPanel(status: LiveVoiceStatus, text?: string) {
  const value = (text || "").trim();
  if (status === "idle" || !value) return false;
  if (status === "error") return true;
  if (/^heard:/i.test(value)) return true;
  if (/^(live voice listening|live voice speaking|ready for your voice|codex is working|codex finished|codex task stopped)$/i.test(value)) {
    return false;
  }
  return status === "listening" || status === "speaking" || status === "delegating";
}

function usageWindowResetText(window: NonNullable<ProviderUsageSnapshot["primary"]>) {
  const resetDate = window.resetsAt ? new Date(window.resetsAt) : null;
  const hasResetDate = resetDate && Number.isFinite(resetDate.getTime());
  const exactReset = hasResetDate
    ? new Intl.DateTimeFormat(undefined, {
        weekday: "short",
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
        timeZoneName: "short"
      }).format(resetDate)
    : null;
  if (exactReset && window.resetsInLabel) return `Resets ${exactReset} (${window.resetsInLabel})`;
  if (exactReset) return `Resets ${exactReset}`;
  if (window.resetsInLabel) return `Resets ${window.resetsInLabel}`;
  return "Reset time unavailable";
}

function contextTooltip(context: NonNullable<ProviderUsageSnapshot["context"]>) {
  return context.summary || context.detail || "";
}

function ComposerUsageRing({
  label,
  percent,
  title,
  muted
}: {
  label: string;
  percent: number;
  title?: string | null;
  muted?: boolean;
}) {
  const clamped = Math.max(0, Math.min(100, percent));
  const rounded = Math.round(clamped);
  const radius = 7;
  const circumference = 2 * Math.PI * radius;
  const offset = circumference * (1 - clamped / 100);
  const compactLabel = muted ? `${label} pending` : `${label} ${rounded}%`;
  const tooltip = title && title !== compactLabel ? `${compactLabel} · ${title}` : compactLabel;

  return (
    <button
      type="button"
      className={cx("composer-usage-ring", muted && "composer-usage-ring-muted")}
      aria-label={tooltip}
    >
      <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
        <circle cx="9" cy="9" r={radius} fill="none" stroke="currentColor" strokeWidth="2" opacity="0.22" />
        <circle
          cx="9"
          cy="9"
          r={radius}
          fill="none"
          stroke="currentColor"
          strokeDasharray={circumference}
          strokeDashoffset={offset}
          strokeLinecap="round"
          strokeWidth="2"
          transform="rotate(-90 9 9)"
        />
      </svg>
      <span className="composer-usage-tooltip">{tooltip}</span>
    </button>
  );
}

function MessageBubble({
  message,
  mentionCatalog,
  onAddTextToThreadNote,
  onUseTextInComposer,
  onOpenThreadNote,
  onSpeakText,
  onRespondToApproval,
  embedded = false
}: {
  message: ChatMessage;
  mentionCatalog: Record<string, ComposerMentionEntry>;
  onAddTextToThreadNote?: (text: string) => void;
  onUseTextInComposer?: (text: string) => void;
  onOpenThreadNote?: () => void;
  onSpeakText?: (text: string) => void | Promise<void>;
  onRespondToApproval?: ApprovalResponder;
  embedded?: boolean;
}) {
  const isRunningAssistant = message.role === "assistant" && message.status === "running";
  const motionProps = embedded ? {} : messageMotion;
  const layoutProps = embedded ? {} : { layout: true as const };
  const [messageContextMenu, setMessageContextMenu] = useState<FloatingContextMenuState | null>(null);
  const [activityExpanded, setActivityExpanded] = useState(false);
  const [elapsedSeconds, setElapsedSeconds] = useState(0);
  const [voiceLoading, setVoiceLoading] = useState(false);
  useEffect(() => {
    if (message.role === "activity") setActivityExpanded(message.activityStatus === "failed");
  }, [message.activityStatus, message.id, message.role]);
  useEffect(() => {
    if (!isRunningAssistant) return undefined;
    const startedAt = Date.now();
    setElapsedSeconds(0);
    const interval = window.setInterval(() => {
      setElapsedSeconds(Math.max(0, Math.floor((Date.now() - startedAt) / 1000)));
    }, 1000);
    return () => window.clearInterval(interval);
  }, [isRunningAssistant, message.id]);

  const copyMessage = () => {
    writeTextToClipboard(message.text.replace(/^Command\n/, ""));
  };
  const saveGeneratedImage = () => {
    if (!message.imageDataURL) return;
    void window.openAssistElectron?.saveImage?.(message.imageDataURL, message.imageName || "openassist-generated-image.png");
  };
  const cleanMessageText = () => message.text.replace(/^Command\n/, "").trim();
  const speakMessage = async (text = cleanMessageText()) => {
    const trimmed = text.trim();
    if (!trimmed || voiceLoading) return;
    setVoiceLoading(true);
    try {
      await onSpeakText?.(trimmed);
    } finally {
      setVoiceLoading(false);
    }
  };
  const selectedTextFromWindow = () => window.getSelection()?.toString().trim() ?? "";
  const openMessageContextMenu = (event: React.MouseEvent) => {
    if (message.role === "activity" || isRunningAssistant) return;
    event.preventDefault();
    event.stopPropagation();
    const selectedText = selectedTextFromWindow();
    const wholeMessage = cleanMessageText();
    setMessageContextMenu({
      ...menuPosition(event),
      title: selectedText ? "Selection" : message.role === "user" ? "Your message" : "Assistant message",
      items: [
        {
          id: "copy-selection",
          label: "Copy Selection",
          icon: <Copy size={14} />,
          disabled: !selectedText,
          onSelect: () => writeTextToClipboard(selectedText)
        },
        {
          id: "copy-message",
          label: "Copy Message",
          icon: <Copy size={14} />,
          onSelect: () => writeTextToClipboard(wholeMessage)
        },
        {
          id: "listen-message",
          label: "Listen",
          icon: voiceLoading ? <span className="voice-loading-spinner menu-spinner" /> : <Volume2 size={14} />,
          disabled: message.role !== "assistant" || !wholeMessage || voiceLoading,
          onSelect: () => { void speakMessage(wholeMessage); }
        },
        { id: "divider-note-actions", label: "" },
        {
          id: "add-selection-thread-note",
          label: "Add Selection to Thread Note",
          icon: <NotebookTabs size={14} />,
          disabled: !selectedText,
          onSelect: () => onAddTextToThreadNote?.(selectedText)
        },
        {
          id: "add-message-thread-note",
          label: "Add Message to Thread Note",
          icon: <FilePlus2 size={14} />,
          disabled: !wholeMessage,
          onSelect: () => onAddTextToThreadNote?.(wholeMessage)
        },
        {
          id: "open-thread-note-side",
          label: "Open Thread Notes",
          icon: <PanelLeftOpen size={14} />,
          onSelect: () => onOpenThreadNote?.()
        },
        { id: "divider-assistant-actions", label: "" },
        {
          id: "ask-about-selection",
          label: selectedText ? "Ask About Selection" : "Ask About Message",
          icon: <Sparkles size={14} />,
          onSelect: () => onUseTextInComposer?.(`Can you help me with this?\n\n${selectedText || wholeMessage}`)
        }
      ]
    });
  };

  if (isRunningAssistant) {
    const provider = message.provider || "Assistant";
    return (
      <motion.div {...layoutProps} {...motionProps} className="message-row assistant-working-message">
        <div
          className={cx("assistant-working-row", `assistant-working-row-${cssKey(providerKey(provider))}`)}
          role="status"
          aria-live="polite"
        >
          <ProviderMark provider={provider} className="provider-mark-inline assistant-working-provider-mark" />
          <span className="assistant-working-text">{provider} is working</span>
        </div>
      </motion.div>
    );
  }

  if (message.role === "activity") {
    const activityTitle = message.activityTitle || "Provider Activity";
    const activityDetail = message.activityDetail || message.text.replace(/^Command\n/, "");
    const activityStatus = message.activityStatus || (message.status === "running" ? "running" : "completed");
    const presentation = activityPresentation(activityTitle, activityDetail);
    const isImageGeneration = message.activityKind === "imageGeneration";
    const generatedImageURL = isImageGeneration ? message.imageDataURL : undefined;
    const toolImageURL = isImageGeneration ? "" : activityPreviewURL(message);
    const hasExpandableDetail = !isImageGeneration && Boolean(presentation.detail.trim());
    const summaryText = isImageGeneration
      ? generatedImageURL ? "Generated image is ready." : "Generating image..."
      : presentation.summary;
    const statusLabel = activityStatusLabel(activityStatus);
    const ActivityIcon = message.activityKind === "webSearch"
      ? Search
      : message.activityKind === "imageGeneration"
        ? Paintbrush
        : message.activityKind === "browserAutomation"
          ? Monitor
          : message.activityKind === "fileChange"
            ? FileText
            : message.activityKind === "mcpToolCall"
              ? Plug
              : message.activityKind === "plan"
                ? ListTodo
                : Terminal;
    return (
      <motion.div
        {...layoutProps}
        {...motionProps}
        className={cx(
          "activity-card",
          `activity-card-${providerKey(message.provider)}`,
          activityExpanded && "expanded",
          activityStatus === "running" && "running",
          activityStatus === "waiting" && "waiting",
          activityStatus === "failed" && "failed"
        )}
      >
        <button
          className="activity-summary-toggle"
          aria-expanded={activityExpanded}
          onClick={() => setActivityExpanded((value) => !value)}
          title={activityExpanded ? "Collapse tool call" : "Expand tool call"}
        >
          <span className="activity-icon">
            <ActivityIcon size={15} />
          </span>
          <span className="activity-copy">
            <span className="activity-head">
              <strong>{activityTitle}</strong>
              <span className="activity-status">{statusLabel}</span>
            </span>
            {summaryText && <span className="activity-summary">{summaryText}</span>}
          </span>
          <ChevronRight className="activity-chevron" size={15} />
        </button>
        <ApprovalActions activity={message} onRespondToApproval={onRespondToApproval} />
        {toolImageURL && (
          <div className="activity-preview-row">
            <ActivityImageThumbnail activity={message} label="Open image in Preview" />
          </div>
        )}
        {generatedImageURL && (
          <div
            className="activity-generated-image"
            title="Double-click to open in Preview"
            onDoubleClick={(event) => {
              event.preventDefault();
              event.stopPropagation();
              openImagePreviewDataURL(generatedImageURL);
            }}
          >
            <img src={generatedImageURL} alt={message.imagePrompt || "Generated image"} draggable={false} />
            <div className="activity-generated-image-footer">
              <span>{message.imagePrompt || "Generated image"}</span>
              <button
                type="button"
                onClick={(event) => {
                  event.stopPropagation();
                  saveGeneratedImage();
                }}
              >
                <Save size={13} />
                Download
              </button>
            </div>
          </div>
        )}
        <AnimatePresence initial={false}>
          {activityExpanded && hasExpandableDetail && (
            <motion.div
              className="activity-detail"
              initial={{ height: 0, opacity: 0 }}
              animate={{ height: "auto", opacity: 1 }}
              exit={{ height: 0, opacity: 0 }}
              transition={{ duration: 0.14, ease: [0.22, 1, 0.36, 1] }}
            >
              <pre>{presentation.detail}</pre>
            </motion.div>
          )}
        </AnimatePresence>
      </motion.div>
    );
  }

  if (message.role === "user") {
    return (
      <motion.div {...layoutProps} {...motionProps} className="message-row user-message" onContextMenu={openMessageContextMenu}>
        <button className="copy-button" aria-label="Copy message" onClick={copyMessage}>
          <Copy size={14} />
        </button>
        <div className="user-bubble">
          <UserMessageMentionText text={message.text} catalog={mentionCatalog} />
        </div>
        <FloatingContextMenu menu={messageContextMenu} onClose={() => setMessageContextMenu(null)} />
      </motion.div>
    );
  }

  const assistantProvider = message.provider || "Assistant";
  return (
    <motion.div {...layoutProps} {...motionProps} className="message-row assistant-message" onContextMenu={openMessageContextMenu}>
      <button className="copy-button" aria-label="Copy message" onClick={copyMessage}>
        <Copy size={14} />
      </button>
      <button
        className={cx("copy-button speak-button", voiceLoading && "loading")}
        aria-label={voiceLoading ? "Generating voice" : "Listen to response"}
        title={voiceLoading ? "Generating voice..." : "Listen to response"}
        disabled={voiceLoading}
        onClick={() => { void speakMessage(); }}
      >
        {voiceLoading ? <span className="voice-loading-spinner" aria-hidden="true" /> : <Volume2 size={14} />}
      </button>
      <div className={cx("assistant-copy", `assistant-copy-${providerKey(assistantProvider)}`)}>
        <MarkdownPreview markdown={message.text} className="assistant-markdown-shell" emptyText="" />
        {message.provider && (
          <small className={cx("provider-tag", `provider-tag-${providerKey(message.provider)}`)}>
            <ProviderMark provider={message.provider} className="provider-mark-inline" />
            {message.provider}
          </small>
        )}
      </div>
      <FloatingContextMenu menu={messageContextMenu} onClose={() => setMessageContextMenu(null)} />
    </motion.div>
  );
}

type ChatTimelineItem =
  | { kind: "message"; message: ChatMessage }
  | { kind: "thinking"; id: string; messages: ChatMessage[] }
  | { kind: "delegated"; id: string; activity: ChatMessage }
  | { kind: "work"; id: string; activities: ChatMessage[] }
  | { kind: "turn"; id: string; items: ChatTimelineItem[]; toolStepCount: number };

function buildChatTimeline(messages: ChatMessage[]): ChatTimelineItem[] {
  const items: ChatTimelineItem[] = [];

  const appendLiveTurnItems = (turnMessages: ChatMessage[]) => {
    let activityBuffer: ChatMessage[] = [];
    let thinkingBuffer: ChatMessage[] = [];

    const flushActivities = () => {
      if (!activityBuffer.length) return;
      const visibleCandidates = activityBuffer.filter((activity) => !isGenericWorkActivity(activity));
      if (!visibleCandidates.length) {
        activityBuffer = [];
        return;
      }
      items.push({
        kind: "work",
        id: `work-${visibleCandidates[0].id}`,
        activities: visibleCandidates
      });
      activityBuffer = [];
    };
    const flushThinking = () => {
      if (!thinkingBuffer.length) return;
      items.push({
        kind: "thinking",
        id: `thinking-${thinkingBuffer[0].id}`,
        messages: thinkingBuffer
      });
      thinkingBuffer = [];
    };

    for (const message of turnMessages) {
      if (message.role === "activity") {
        if (message.activityKind === "reasoning") {
          if (!reasoningActivityText(message)) {
            continue;
          }
          flushActivities();
          thinkingBuffer.push(message);
          continue;
        }
        if (isCommentaryActivity(message)) {
          if (!commentaryActivityText(message)) {
            continue;
          }
          flushActivities();
          thinkingBuffer.push(message);
          continue;
        }
        if (isImageGenerationActivity(message)) {
          if (!activityPreviewURL(message)) {
            continue;
          }
          flushThinking();
          flushActivities();
          items.push({ kind: "message", message });
          continue;
        }
        if (isRealtimeDelegationActivity(message)) {
          flushThinking();
          activityBuffer.push(message);
          continue;
        }
        flushThinking();
        activityBuffer.push(message);
        continue;
      }
      flushThinking();
      if (message.role === "assistant" && message.status === "running" && activityBuffer.length) {
        items.push({ kind: "message", message });
        flushActivities();
        continue;
      }
      flushActivities();
      items.push({ kind: "message", message });
    }
    flushThinking();
    flushActivities();
  };

  let turnBuffer: ChatMessage[] = [];

  const toolStepCountForItems = (innerItems: ChatTimelineItem[]) => innerItems.reduce(
    (sum, item) => sum + (item.kind === "work" ? item.activities.length : 0),
    0
  );

  const hasRealtimeDelegationInItems = (innerItems: ChatTimelineItem[]) => innerItems.some(
    (item) => item.kind === "work" && item.activities.some(isRealtimeDelegationActivity)
  );

  const appendCollapsedTurn = (turnMessages: ChatMessage[], idPrefix: string) => {
    const innerItems = buildCompletedTurnInnerItems(turnMessages);
    const toolStepCount = toolStepCountForItems(innerItems);
    if (!innerItems.length || toolStepCount <= 0) return false;
    items.push({
      kind: "turn",
      id: `${idPrefix}-${turnMessages[0]?.id ?? `turn-${items.length}`}`,
      items: innerItems,
      toolStepCount
    });
    return true;
  };

  const flushTurn = (isTail = false) => {
    if (!turnBuffer.length) return;
    const finalIndex = findFinalAssistantMessageIndex(turnBuffer);
    if (finalIndex >= 0) {
      const finalMessage = turnBuffer[finalIndex];
      const messagesBeforeFinal = turnBuffer.slice(0, finalIndex);
      const messagesAfterFinal = turnBuffer.slice(finalIndex + 1);
      if (appendCollapsedTurn(messagesBeforeFinal, "turn-completed")) {
      } else {
        const innerItems = buildCompletedTurnInnerItems(messagesBeforeFinal);
        // Nothing interesting collapsed — just emit the inner items inline.
        innerItems.forEach((item) => items.push(item));
      }
      if (finalMessage) items.push({ kind: "message", message: finalMessage });
      if (messagesAfterFinal.length) appendLiveTurnItems(messagesAfterFinal);
      turnBuffer = [];
      return;
    }

    const liveVoiceInnerItems = buildCompletedTurnInnerItems(turnBuffer);
    const shouldCollapseLiveVoiceTurn = !isTail
      && hasRealtimeDelegationInItems(liveVoiceInnerItems)
      && toolStepCountForItems(liveVoiceInnerItems) > 0;
    if (shouldCollapseLiveVoiceTurn) {
      appendCollapsedTurn(turnBuffer, "turn-realtime");
      turnBuffer = [];
      return;
    }

    appendLiveTurnItems(turnBuffer);
    turnBuffer = [];
  };

  function buildCompletedTurnInnerItems(messagesBeforeFinal: ChatMessage[]): ChatTimelineItem[] {
    const innerItems: ChatTimelineItem[] = [];
    let workBuffer: ChatMessage[] = [];
    let thinkingBuffer: ChatMessage[] = [];

    const flushWork = () => {
      if (!workBuffer.length) return;
      const visibleCandidates = workBuffer.filter((activity) => !isGenericWorkActivity(activity));
      workBuffer = [];
      if (!visibleCandidates.length) return;
      innerItems.push({
        kind: "work",
        id: `work-completed-${visibleCandidates[0].id}`,
        activities: visibleCandidates
      });
    };
    const flushThinking = () => {
      if (!thinkingBuffer.length) return;
      innerItems.push({
        kind: "thinking",
        id: `thinking-completed-${thinkingBuffer[0].id}`,
        messages: thinkingBuffer
      });
      thinkingBuffer = [];
    };

    for (const message of messagesBeforeFinal) {
      if (message.role !== "activity") {
        flushWork();
        flushThinking();
        innerItems.push({ kind: "message", message });
        continue;
      }
      if (isImageGenerationActivity(message)) {
        if (!activityPreviewURL(message)) continue;
        flushWork();
        flushThinking();
        innerItems.push({ kind: "message", message });
        continue;
      }
      if (isCommentaryActivity(message)) {
        if (!commentaryActivityText(message)) continue;
        flushWork();
        thinkingBuffer.push(message);
        continue;
      }
      flushThinking();
      workBuffer.push(message);
    }
    flushThinking();
    flushWork();
    return innerItems;
  }


  for (const message of messages) {
    if (message.role === "user") {
      flushTurn(false);
      items.push({ kind: "message", message });
      continue;
    }
    turnBuffer.push(message);
  }
  flushTurn(true);
  return items;
}

function findFinalAssistantMessageIndex(messages: ChatMessage[]) {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (
      message?.role === "assistant"
      && message.status !== "running"
      && message.text.trim().length > 0
    ) {
      return index;
    }
  }
  return -1;
}

function reasoningActivityText(message: ChatMessage) {
  const text = (message.activityDetail || message.text || "").trim();
  if (!text) return "";
  if (/^(reasoning|thinking|\[\]|\{\}|null|undefined|"")$/i.test(text)) return "";
  return text;
}

function commentaryActivityText(message: ChatMessage) {
  const text = (message.activityDetail || message.text || "").trim();
  if (!text) return "";
  if (/^(agent message|assistant message|\[\]|\{\}|null|undefined|"")$/i.test(text)) return "";
  return text;
}

function isCommentaryActivity(message: ChatMessage) {
  if (message.role !== "activity") return false;
  return normalizedActivityKind(message.activityKind) === "assistantprogress";
}

function workGroupStatus(activities: ChatMessage[]): ChatMessage["activityStatus"] {
  if (activities.some((activity) =>
    activity.activityStatus === "running"
    || activity.activityStatus === "pending"
    || activity.activityStatus === "waiting"
  )) {
    return "running";
  }
  if (activities.some((activity) => activity.activityStatus === "failed")) return "failed";
  return "completed";
}

function activityTimeRange(activities: ChatMessage[]) {
  const times = activities.flatMap((activity) => [activity.createdAt, activity.updatedAt])
    .filter((value): value is number => typeof value === "number" && Number.isFinite(value) && value > 0);
  if (!times.length) return null;
  return { start: Math.min(...times), end: Math.max(...times) };
}

function completedWorkTitle(activities: ChatMessage[]) {
  const count = Math.max(activities.length, 1);
  if (count === 1) {
    const only = activities[0];
    const name = (workStepTitle(only) || "").trim();
    if (name) return name;
  }
  return `Worked through ${count} ${count === 1 ? "step" : "steps"}`;
}

function normalizedActivityKind(kind?: string) {
  return String(kind ?? "").replace(/[_\s-]+/g, "").toLowerCase();
}

function isRealtimeDelegationActivity(activity: ChatMessage) {
  const kind = normalizedActivityKind(activity.activityKind);
  const title = (activity.activityTitle || "").replace(/\s+/g, " ").trim().toLowerCase();
  return kind === "realtimedelegation"
    || (kind === "subagent" && title.includes("realtime"))
    || activity.id.includes("realtime-delegation");
}

function realtimeDelegationSummary(activity: ChatMessage) {
  const raw = (activity.activityDetail || activity.text || "").replace(/^Command\n/, "").trim();
  const cleaned = raw
    .replace(/Codex (?:finished|completed) (?:the )?(?:voice|realtime) task\.?/gi, "")
    .replace(/Codex completed this realtime task\.?/gi, "")
    .replace(/\s+/g, " ")
    .trim();
  if (cleaned) return cleaned.length > 180 ? `${cleaned.slice(0, 177)}...` : cleaned;
  if (activity.activityStatus === "failed") return "Codex could not finish the delegated task.";
  if (activity.activityStatus === "running" || activity.activityStatus === "pending" || activity.activityStatus === "waiting") {
    return "Codex is working on the delegated voice task.";
  }
  return "Codex handled this from Live Voice.";
}

function isGenericWorkActivity(activity: ChatMessage) {
  const kind = normalizedActivityKind(activity.activityKind);
  const detail = (activity.activityDetail || activity.text || "").replace(/^Command\n/, "").replace(/\s+/g, " ").trim().toLowerCase();
  const title = (activity.activityTitle || "").replace(/\s+/g, " ").trim().toLowerCase();
  const label = detail || title;
  const emptyLabel = !label || /^(reasoning|thinking|\[\]|\{\}|null|undefined|"")$/.test(label);
  if (title === "user message") return true;
  if (kind === "usermessage" || kind === "agentmessage" || kind === "assistantmessage" || kind === "message") return true;
  if (!label && (kind === "reasoning" || kind === "usermessage" || kind === "agentmessage" || kind === "assistantmessage")) return true;
  if ((kind === "reasoning" || title === "reasoning") && emptyLabel) return true;
  if (title === "agent message" && emptyLabel) return true;
  if ((kind === "usermessage" || kind === "agentmessage" || kind === "assistantmessage" || kind === "message")
    && /^(user message|agent message|assistant message)$/.test(label)) {
    return true;
  }
  if (kind === "assistantprogress" && /^(agent message|assistant message)$/.test(label)) return true;
  return false;
}

function mergeActivityText(existing: ChatMessage, next: ChatMessage) {
  const previousText = (existing.activityDetail || existing.text || "").trim();
  const nextText = (next.activityDetail || next.text || "").trim();
  const mergedText = !previousText
    ? nextText
    : !nextText || previousText.includes(nextText)
      ? previousText
      : nextText.includes(previousText)
        ? nextText
        : `${previousText}${nextText}`;
  return {
    ...existing,
    ...next,
    text: mergedText || next.text,
    activityDetail: mergedText || next.activityDetail
  };
}

function isRunningAssistantMessage(message: ChatMessage) {
  return message.role === "assistant" && message.status === "running";
}

function upsertChatActivity(messages: ChatMessage[], activity: ChatMessage, fallbackProvider = "Codex") {
  const normalizedActivity: ChatMessage = {
    ...activity,
    provider: activity.provider || fallbackProvider,
    role: "activity"
  };
  // Pull any running-assistant placeholder out so we can always re-append it last.
  const pending = messages.find(isRunningAssistantMessage);
  const base = pending ? messages.filter((message) => message.id !== pending.id) : messages;
  if (isGenericWorkActivity(normalizedActivity)) {
    const filtered = base.filter((message) => message.id !== normalizedActivity.id);
    return pending ? [...filtered, pending] : filtered;
  }
  const existingIndex = base.findIndex((message) => message.id === normalizedActivity.id);
  const next = existingIndex < 0
    ? [...base, normalizedActivity]
    : base.map((message, index) => index === existingIndex
      ? normalizedActivity.activityKind === "reasoning" || normalizedActivity.activityKind === "assistantProgress"
        ? mergeActivityText(message, normalizedActivity)
        : { ...message, ...normalizedActivity }
      : message);
  return pending ? [...next, pending] : next;
}

function cleanRealtimePrompt(value?: string) {
  const text = (value || "").replace(/\s+/g, " ").trim();
  if (!text) return "";
  const lower = text.toLowerCase();
  if (
    lower === "live voice request"
    || lower.startsWith("codex is starting")
    || lower.startsWith("codex is working")
    || lower.startsWith("codex handled")
    || lower.startsWith("codex completed")
    || lower.startsWith("codex delegated task was stopped")
    || lower.startsWith("now you should be able to assign the task")
  ) {
    return "";
  }
  return text.length > 320 ? `${text.slice(0, 317)}...` : text;
}

function realtimeDelegationUserText(prompt?: string, activity?: ChatMessage) {
  return cleanRealtimePrompt(prompt)
    || cleanRealtimePrompt(activity ? realtimeDelegationSummary(activity) : "")
    || "Live Voice request";
}

function upsertRealtimeDelegationUserTurn(
  messages: ChatMessage[],
  providerTurnID?: string,
  prompt?: string,
  activity?: ChatMessage
) {
  const turnID = providerTurnID?.trim();
  if (!turnID) return messages;
  const id = `user-realtime-${turnID}`;
  const existingIndex = messages.findIndex((message) => message.id === id);
  const existing = existingIndex >= 0 ? messages[existingIndex] : undefined;
  const nextText = realtimeDelegationUserText(prompt, activity);
  const existingText = existing?.text || "";
  const text = existingText && existingText !== "Live Voice request" && nextText === "Live Voice request"
    ? existingText
    : nextText;
  const now = Date.now();
  const message: ChatMessage = {
    ...existing,
    id,
    role: "user",
    text,
    createdAt: existing?.createdAt ?? Math.max(0, (activity?.createdAt ?? now) - 1),
    updatedAt: activity?.updatedAt ?? now
  };
  if (!activity && existingIndex >= 0) {
    return messages.map((item, index) => index === existingIndex ? message : item);
  }
  const nextMessages = messages.filter((item) => item.id !== id);
  const pending = nextMessages.find(isRunningAssistantMessage);
  const baseMessages = pending ? nextMessages.filter((item) => item.id !== pending.id) : nextMessages;
  const activityIndex = activity ? baseMessages.findIndex((item) => item.id === activity.id) : -1;
  const merged = activityIndex >= 0
    ? [
        ...baseMessages.slice(0, activityIndex),
        message,
        ...baseMessages.slice(activityIndex)
      ]
    : [...baseMessages, message];
  return pending ? [...merged, pending] : merged;
}

function isImageGenerationActivity(activity: ChatMessage) {
  return normalizedActivityKind(activity.activityKind) === "imagegeneration";
}

function hasPendingApproval(activity: ChatMessage) {
  return Boolean(activity.approvalRequestID != null && activity.approvalOptions?.length && !activity.approvalResolved && activity.activityStatus === "waiting");
}

function workStepTitle(activity: ChatMessage) {
  const kind = normalizedActivityKind(activity.activityKind);
  if (kind === "reasoning") return "Reasoning";
  if (kind === "assistantprogress") return "Agent Message";
  if (kind === "imagegeneration") return "Image Generation";
  return activity.activityTitle || "Tool";
}

function ApprovalActions({
  activity,
  onRespondToApproval
}: {
  activity: ChatMessage;
  onRespondToApproval?: ApprovalResponder;
}) {
  if (!hasPendingApproval(activity) || !onRespondToApproval) return null;
  return (
    <div className="approval-actions" onClick={(event) => event.stopPropagation()}>
      <span className="approval-actions-label">
        <Shield size={13} />
        Approval needed
      </span>
      <span className="approval-actions-buttons">
        {activity.approvalOptions?.map((option) => (
          <button
            key={option.id}
            type="button"
            className={cx("approval-action-button", option.tone === "approve" && "approve", option.tone === "danger" && "danger")}
            title={option.description || option.label}
            onClick={() => onRespondToApproval(activity, option)}
          >
            {option.label}
          </button>
        ))}
      </span>
    </div>
  );
}

function DelegatedTaskCard({ activity, embedded = false }: { activity: ChatMessage; embedded?: boolean }) {
  const status = activity.activityStatus || (activity.status === "running" ? "running" : "completed");
  const isRunning = status === "running" || status === "pending" || status === "waiting";
  const isFailed = status === "failed";
  const statusLabel = isFailed ? "Failed" : isRunning ? "Running" : "Completed";
  const summary = realtimeDelegationSummary(activity);
  const motionProps = embedded ? {} : messageMotion;
  const layoutProps = embedded ? {} : { layout: true as const };

  return (
    <motion.div
      {...layoutProps}
      {...motionProps}
      className={cx("delegated-task-card", isRunning && "running", isFailed && "failed")}
      role="status"
      aria-label={`Realtime delegated task ${statusLabel.toLowerCase()}`}
    >
      <span className="delegated-task-icon">
        <Workflow size={16} />
      </span>
      <span className="delegated-task-copy">
        <span className="delegated-task-head">
          <strong>Delegated from Live Voice</strong>
          <span className="delegated-task-status">{statusLabel}</span>
        </span>
        <span className="delegated-task-summary">{summary}</span>
      </span>
    </motion.div>
  );
}

function WorkSummaryStep({
  activity,
  onRespondToApproval,
  approvalsEnabled = true
}: {
  activity: ChatMessage;
  onRespondToApproval?: ApprovalResponder;
  approvalsEnabled?: boolean;
}) {
  const kind = normalizedActivityKind(activity.activityKind);
  const title = workStepTitle(activity);
  const rawDetail = (activity.activityDetail || activity.text || "").replace(/^Command\n/, "").trim();
  const presentation = activityPresentation(title, rawDetail);
  const genericSummary = /^(reasoning|thinking|user message|agent message|assistant message|\[\]|\{\}|null|undefined|"")$/i.test(presentation.summary.trim());
  const summary = genericSummary || presentation.summary.trim() === title.trim() ? "" : presentation.summary.trim();
  const hasPreview = Boolean(activityPreviewURL(activity));
  const ActivityIcon = kind === "websearch"
    ? Search
    : kind === "imagegeneration"
      ? Paintbrush
      : kind === "browserautomation"
        ? Monitor
        : kind === "filechange"
          ? FileText
          : kind === "mcptoolcall"
            ? Plug
            : kind === "plan"
              ? ListTodo
              : kind === "reasoning"
                ? Brain
                : kind === "assistantprogress"
                  ? MessageSquare
                  : kind === "subagent"
                    ? Workflow
                    : Terminal;

  return (
    <div className={cx("work-summary-step", activity.activityStatus === "failed" && "failed", hasPreview && "has-preview")}>
      <ActivityIcon size={14} />
      <span className="work-summary-step-copy">
        <span className="work-summary-step-title">{title}</span>
        {summary && <span className="work-summary-step-detail">{summary}</span>}
        <ApprovalActions activity={activity} onRespondToApproval={approvalsEnabled ? onRespondToApproval : undefined} />
      </span>
      {hasPreview && <ActivityImageThumbnail activity={activity} className="work-summary-step-preview" label="Open image in Preview" />}
    </div>
  );
}

function ThinkingGroup({ messages, embedded = false }: { messages: ChatMessage[]; embedded?: boolean }) {
  const text = messages
    .map((message) => (message.activityDetail || message.text || "").trim())
    .filter(Boolean)
    .join("\n\n");
  if (!text) return null;
  const provider = messages.find((message) => message.provider)?.provider || "Codex";
  const motionProps = embedded ? {} : messageMotion;
  const layoutProps = embedded ? {} : { layout: true as const };
  return (
    <motion.div {...layoutProps} {...motionProps} className="message-row assistant-message thinking-message">
      <div className={cx("assistant-copy", "thinking-copy", `assistant-copy-${providerKey(provider)}`)}>
        <MarkdownPreview markdown={text} className="assistant-markdown-shell thinking-markdown-shell" emptyText="" />
      </div>
    </motion.div>
  );
}

function WorkActivityGroup({
  activities,
  onRespondToApproval,
  onStopWork,
  active = false,
  embedded = false
}: {
  activities: ChatMessage[];
  onRespondToApproval?: ApprovalResponder;
  onStopWork?: () => void;
  active?: boolean;
  embedded?: boolean;
}) {
  const status = workGroupStatus(activities);
  const visibleActivities = activities.filter((activity) => !isGenericWorkActivity(activity));
  const hasRealtimeDelegation = visibleActivities.some(isRealtimeDelegationActivity);
  const toolActivities = visibleActivities.filter((activity) => !isRealtimeDelegationActivity(activity));
  const displayActivities = toolActivities.length ? toolActivities : visibleActivities;
  const canExpand = displayActivities.length > 0;
  const approvalActivity = displayActivities.find(hasPendingApproval);
  const activeApprovalActivity = active ? approvalActivity : undefined;
  const pausedHistory = status === "running" && !active && !activeApprovalActivity;
  const [expanded, setExpanded] = useState(() => status !== "completed" && !pausedHistory);
  const previewActivities = displayActivities.filter(activityPreviewURL).slice(-4);
  const statusLabel = status === "failed" ? "Needs review" : activeApprovalActivity ? "Needs approval" : status === "running" ? active ? "Running" : "Paused" : "Done";
  const provider = activities.find((activity) => activity.provider)?.provider;
  const failedCount = activities.filter((activity) => activity.activityStatus === "failed").length;
  const runningCount = activities.filter((activity) =>
    activity.activityStatus === "running"
    || activity.activityStatus === "pending"
    || activity.activityStatus === "waiting"
  ).length;
  const title = activeApprovalActivity
    ? "Tool work"
    : runningCount
      ? active ? `Tool work · ${runningCount} active` : "Tool work · paused"
    : failedCount
      ? `Tool work · ${failedCount} failed`
      : `Tool work · ${Math.max(displayActivities.length, 1)} ${displayActivities.length === 1 ? "step" : "steps"}`;
  const latest = [...displayActivities].reverse().find((activity) => activity.activityTitle || activity.activityDetail || activity.text);
  const latestTitle = latest?.activityTitle || "Tool activity";
  const latestSummary = latest ? activityPresentation(latestTitle, latest.activityDetail || latest.text).summary : "";
  const canStopWork = active && status === "running" && Boolean(onStopWork);
  const motionProps = embedded ? {} : messageMotion;
  const layoutProps = embedded ? {} : { layout: true as const };

  useEffect(() => {
    if (status === "completed" || pausedHistory) setExpanded(false);
  }, [activities[0]?.id, pausedHistory, status]);

  if (status === "completed" || pausedHistory) {
    const summaryTitle = pausedHistory
      ? (hasRealtimeDelegation ? "Paused Live Voice work" : "Paused tool work")
      : completedWorkTitle(displayActivities);
    return (
      <motion.div {...layoutProps} {...motionProps} className={cx("work-summary-line", `work-summary-line-${providerKey(provider)}`, expanded && "expanded")}>
        <button
          className="work-summary-toggle"
          aria-expanded={expanded}
          disabled={!canExpand}
          onClick={() => {
            if (canExpand) setExpanded((value) => !value);
          }}
        >
          <span>{summaryTitle}</span>
          {hasRealtimeDelegation && <small className="work-source-pill">Live Voice</small>}
          {canExpand && <ChevronRight size={15} />}
        </button>
        {!expanded && <ActivityPreviewStrip activities={previewActivities} className="work-summary-preview-strip" />}
        <AnimatePresence initial={false}>
          {expanded && canExpand && (
            <motion.div
              className="work-summary-details"
              initial={{ height: 0, opacity: 0 }}
              animate={{ height: "auto", opacity: 1 }}
              exit={{ height: 0, opacity: 0 }}
              transition={{ duration: 0.16, ease: [0.22, 1, 0.36, 1] }}
            >
              {displayActivities.map((activity) => (
                <WorkSummaryStep
                  key={activity.id}
                  activity={activity}
                  onRespondToApproval={onRespondToApproval}
                  approvalsEnabled={false}
                />
              ))}
            </motion.div>
          )}
        </AnimatePresence>
      </motion.div>
    );
  }

  return (
    <motion.div
      {...layoutProps}
      {...motionProps}
      className={cx(
        "work-card",
        `work-card-${providerKey(provider)}`,
        expanded && "expanded",
        status === "running" && "running",
        status === "failed" && "failed"
      )}
    >
      <button
        className="work-card-toggle"
        aria-expanded={expanded}
        disabled={!canExpand}
        onClick={() => {
          if (canExpand) setExpanded((value) => !value);
        }}
      >
        <span className="work-card-icon">
          <Workflow size={15} />
        </span>
        <span className="work-card-copy">
          <span className="work-card-head">
            <strong>{title}</strong>
            {hasRealtimeDelegation && <span className="work-source-pill">Live Voice</span>}
            <span>{statusLabel}</span>
          </span>
          <small>{latestSummary || "Tool calls are hidden here to keep the chat clean."}</small>
        </span>
        {canExpand && <ChevronRight className="work-card-chevron" size={16} />}
      </button>
      {!expanded && <ActivityPreviewStrip activities={previewActivities} className="work-card-preview-strip" />}
      {activeApprovalActivity && !expanded && (
        <div className="work-card-approval">
          <ApprovalActions activity={activeApprovalActivity} onRespondToApproval={onRespondToApproval} />
        </div>
      )}
      <AnimatePresence initial={false}>
        {expanded && canExpand && (
          <motion.div
            className="work-card-body"
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: "auto", opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={{ duration: 0.16, ease: [0.22, 1, 0.36, 1] }}
          >
            {displayActivities.map((activity) => (
              <WorkSummaryStep
                key={activity.id}
                activity={activity}
                onRespondToApproval={onRespondToApproval}
                approvalsEnabled={active && hasPendingApproval(activity)}
              />
            ))}
          </motion.div>
        )}
      </AnimatePresence>
    </motion.div>
  );
}

function CompletedTurnGroup({
  innerItems,
  toolStepCount,
  activeWorkGroupID,
  onRespondToApproval,
  onStop,
  messageMentionCatalog,
  onAddTextToThreadNote,
  onComposerText,
  onOpenThreadNote,
  onSpeakText
}: {
  innerItems: ChatTimelineItem[];
  toolStepCount: number;
  activeWorkGroupID?: string | null;
  onRespondToApproval?: ApprovalResponder;
  onStop?: () => void;
  messageMentionCatalog: Record<string, ComposerMentionEntry>;
  onAddTextToThreadNote?: (text: string) => void;
  onComposerText?: (text: string) => void;
  onOpenThreadNote?: () => void;
  onSpeakText?: (text: string) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const stepLabel = `Worked through ${toolStepCount} ${toolStepCount === 1 ? "step" : "steps"}`;
  const previewActivities = innerItems.flatMap((inner) => {
    if (inner.kind === "work") return inner.activities;
    if (inner.kind === "delegated") return [inner.activity];
    if (inner.kind === "thinking") return inner.messages;
    if (inner.kind === "message") return [inner.message];
    return [];
  }).filter(activityPreviewURL).slice(-4);
  const provider = innerItems.flatMap((inner) => {
    if (inner.kind === "work") return inner.activities;
    if (inner.kind === "delegated") return [inner.activity];
    if (inner.kind === "thinking") return inner.messages;
    if (inner.kind === "message") return [inner.message];
    return [];
  }).find((entry) => entry?.provider)?.provider;
  return (
    <motion.div {...messageMotion} className={cx("work-summary-line", "completed-turn-group", `work-summary-line-${providerKey(provider)}`, expanded && "expanded")}>
      <button
        className="work-summary-toggle"
        aria-expanded={expanded}
        onClick={() => setExpanded((value) => !value)}
      >
        <span>{stepLabel}</span>
        <ChevronRight size={15} />
      </button>
      {!expanded && <ActivityPreviewStrip activities={previewActivities} className="work-summary-preview-strip completed-turn-preview-strip" />}
      <AnimatePresence initial={false}>
        {expanded && (
          <motion.div
            className="work-summary-details completed-turn-details"
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: "auto", opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={{ duration: 0.16, ease: [0.22, 1, 0.36, 1] }}
          >
            {innerItems.map((inner) => inner.kind === "work" ? (
              <WorkActivityGroup
                key={inner.id}
                activities={inner.activities}
                onRespondToApproval={onRespondToApproval}
                onStopWork={inner.id === activeWorkGroupID ? onStop : undefined}
                active={inner.id === activeWorkGroupID}
                embedded
              />
            ) : inner.kind === "thinking" ? (
              <ThinkingGroup key={inner.id} messages={inner.messages} embedded />
            ) : inner.kind === "delegated" ? (
              <DelegatedTaskCard key={inner.id} activity={inner.activity} embedded />
            ) : inner.kind === "message" ? (
              <MessageBubble
                key={inner.message.id}
                message={inner.message}
                mentionCatalog={messageMentionCatalog}
                onAddTextToThreadNote={onAddTextToThreadNote}
                onUseTextInComposer={onComposerText}
                onOpenThreadNote={onOpenThreadNote}
                onSpeakText={onSpeakText}
                onRespondToApproval={onRespondToApproval}
                embedded
              />
            ) : null)}
          </motion.div>
        )}
      </AnimatePresence>
    </motion.div>
  );
}

type ComposerMentionKind = "plugin" | "skill";

type ComposerMentionEntry = {
  id: string;
  kind: ComposerMentionKind;
  slug: string;
  label: string;
  description: string;
  iconPath?: string | null;
  insertText: string;
};

type ComposerMentionSection = {
  label: string;
  items: ComposerMentionEntry[];
};

function CatalogIcon({
  src,
  kind,
  fallback,
  fallbackSize = 14
}: {
  src?: string | null;
  kind: ComposerMentionKind;
  fallback?: ReactNode;
  fallbackSize?: number;
}) {
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    setFailed(false);
  }, [src]);

  if (src && !failed) {
    return <img alt="" src={src} onError={() => setFailed(true)} />;
  }

  if (fallback) return <>{fallback}</>;
  return kind === "plugin" ? <Plug size={fallbackSize} /> : <Sparkles size={fallbackSize} />;
}

function normalizeComposerMentionSlug(value?: string | null) {
  return (value ?? "")
    .trim()
    .replace(/^@+/, "")
    .replace(/[^A-Za-z0-9._:-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .toLowerCase();
}

function pluginComposerSlug(plugin: PluginItem) {
  return normalizeComposerMentionSlug(plugin.pluginName ?? plugin.id.split("@")[0] ?? plugin.title);
}

function skillComposerSlug(skill: SkillItem) {
  return normalizeComposerMentionSlug(skill.id || skill.title);
}

function buildComposerMentionCatalog(plugins: PluginItem[], skills: SkillItem[]) {
  const catalog: Record<string, ComposerMentionEntry> = {};
  plugins
    .filter((plugin) => plugin.status === "Installed")
    .forEach((plugin) => {
      const slug = pluginComposerSlug(plugin);
      if (!slug) return;
      catalog[slug] = {
        id: plugin.id,
        kind: "plugin",
        slug,
        label: plugin.title,
        description: plugin.description,
        iconPath: plugin.logoPath,
        insertText: `@${slug} `
      };
    });
  skills.forEach((skill) => {
    const slug = skillComposerSlug(skill);
    if (!slug || catalog[slug]) return;
    catalog[slug] = {
      id: skill.id,
      kind: "skill",
      slug,
      label: skill.title,
      description: skill.description,
      iconPath: skill.iconPath,
      insertText: `@${slug} `
    };
  });
  return catalog;
}

function getActiveComposerMention(value: string, cursor: number) {
  const safeCursor = Math.max(0, Math.min(value.length, cursor));
  const beforeCursor = value.slice(0, safeCursor);
  const match = /(^|\s)@([A-Za-z0-9._:-]*)$/.exec(beforeCursor);
  if (!match) return null;
  return {
    query: match[2] ?? "",
    start: match.index + (match[1]?.length ?? 0),
    end: safeCursor
  };
}

function replaceActiveComposerMention(value: string, cursor: number, insertText: string) {
  const mention = getActiveComposerMention(value, cursor);
  if (!mention) {
    const trimmed = value.replace(/\s+$/, "");
    const nextValue = trimmed ? `${trimmed} ${insertText}` : insertText;
    return { value: nextValue, cursor: nextValue.length };
  }
  const nextValue = `${value.slice(0, mention.start)}${insertText}${value.slice(mention.end)}`;
  return { value: nextValue, cursor: mention.start + insertText.length };
}

function mentionMatches(values: Array<string | null | undefined>, query: string) {
  if (!query) return true;
  const lowered = query.toLowerCase();
  return values.some((value) => value?.toLowerCase().includes(lowered));
}

function buildComposerMentionSections(
  query: string | null,
  plugins: PluginItem[],
  skills: SkillItem[]
): ComposerMentionSection[] {
  if (query === null) return [];
  const pluginItems = plugins
    .filter((plugin) => plugin.status === "Installed")
    .map((plugin) => {
      const slug = pluginComposerSlug(plugin);
      if (!slug || !mentionMatches([slug, plugin.title, plugin.description], query)) return null;
      return {
        id: plugin.id,
        kind: "plugin" as const,
        slug,
        label: plugin.title,
        description: plugin.description,
        iconPath: plugin.logoPath,
        insertText: `@${slug} `
      };
    })
    .filter((item): item is ComposerMentionEntry => Boolean(item))
    .slice(0, 8);
  const skillItems = skills
    .map((skill) => {
      const slug = skillComposerSlug(skill);
      if (!slug || !mentionMatches([slug, skill.title, skill.description], query)) return null;
      return {
        id: skill.id,
        kind: "skill" as const,
        slug,
        label: skill.title,
        description: skill.description,
        iconPath: skill.iconPath,
        insertText: `@${slug} `
      };
    })
    .filter((item): item is ComposerMentionEntry => Boolean(item))
    .slice(0, 8);
  return [
    { label: "Plugins", items: pluginItems },
    { label: "Skills", items: skillItems }
  ];
}

function composerMentionEntries(sections: ComposerMentionSection[]) {
  return sections.flatMap((section) => section.items);
}

function composerMentionsFromText(value: string, catalog: Record<string, ComposerMentionEntry>) {
  const seen = new Set<string>();
  const mentions: ComposerMentionEntry[] = [];
  for (const match of value.matchAll(/@([A-Za-z0-9._:-]+)/g)) {
    const slug = normalizeComposerMentionSlug(match[1]);
    const mention = catalog[slug];
    if (!mention || seen.has(`${mention.kind}:${mention.id}`)) continue;
    seen.add(`${mention.kind}:${mention.id}`);
    mentions.push(mention);
  }
  return mentions;
}

function composerMentionIDs(value: string, plugins: PluginItem[], skills: SkillItem[]) {
  const mentions = composerMentionsFromText(value, buildComposerMentionCatalog(plugins, skills));
  return {
    pluginIDs: mentions.filter((mention) => mention.kind === "plugin").map((mention) => mention.id),
    skillIDs: mentions.filter((mention) => mention.kind === "skill").map((mention) => mention.id)
  };
}

type ComposerDraftToken =
  | { type: "text"; text: string; start: number; end: number }
  | { type: "mention"; mention: ComposerMentionEntry; start: number; end: number };

function tokenizeComposerDraft(value: string, catalog: Record<string, ComposerMentionEntry>) {
  const tokens: ComposerDraftToken[] = [];
  let cursor = 0;
  for (const match of value.matchAll(/@([A-Za-z0-9._:-]+)/g)) {
    const raw = match[0] ?? "";
    const slug = normalizeComposerMentionSlug(match[1]);
    const mention = catalog[slug];
    const start = match.index ?? 0;
    if (!mention) continue;
    if (start > cursor) {
      tokens.push({ type: "text", text: value.slice(cursor, start), start: cursor, end: start });
    }
    tokens.push({ type: "mention", mention, start, end: start + raw.length });
    cursor = start + raw.length;
  }
  if (cursor < value.length) {
    tokens.push({ type: "text", text: value.slice(cursor), start: cursor, end: value.length });
  }
  return tokens.length ? tokens : [{ type: "text" as const, text: value, start: 0, end: value.length }];
}

function UserMessageMentionText({
  catalog,
  text
}: {
  catalog: Record<string, ComposerMentionEntry>;
  text: string;
}) {
  const tokens = useMemo(() => tokenizeComposerDraft(text, catalog), [catalog, text]);
  const hasMention = tokens.some((token) => token.type === "mention");
  if (!hasMention) return <>{text}</>;
  return (
    <span className="user-bubble-rich">
      {tokens.map((token, index) =>
        token.type === "mention" ? (
          <span className="user-message-mention" key={`${token.mention.kind}:${token.mention.id}:${token.start}:${index}`}>
            <CatalogIcon src={token.mention.iconPath} kind={token.mention.kind} fallbackSize={13} />
            <span>{token.mention.label}</span>
          </span>
        ) : (
          <span className="user-bubble-token" key={`text:${token.start}:${index}`}>
            {token.text}
          </span>
        )
      )}
    </span>
  );
}

function mentionRanges(value: string, catalog: Record<string, ComposerMentionEntry>) {
  return tokenizeComposerDraft(value, catalog).flatMap((token) => (token.type === "mention" ? [token] : []));
}

function mentionRangeEndingAt(value: string, cursor: number, catalog: Record<string, ComposerMentionEntry>) {
  return mentionRanges(value, catalog).find((range) => range.end === cursor || range.end + 1 === cursor);
}

function changedRange(previousValue: string, nextValue: string) {
  let start = 0;
  while (start < previousValue.length && start < nextValue.length && previousValue[start] === nextValue[start]) {
    start += 1;
  }
  let endPrevious = previousValue.length;
  let endNext = nextValue.length;
  while (endPrevious > start && endNext > start && previousValue[endPrevious - 1] === nextValue[endNext - 1]) {
    endPrevious -= 1;
    endNext -= 1;
  }
  return { start, endPrevious, endNext };
}

function removeMentionRange(value: string, range: { start: number; end: number }) {
  let start = range.start;
  let end = range.end;
  if (value[start - 1] === " " && value[end] === " ") {
    start -= 1;
  } else if (value[end] === " ") {
    end += 1;
  } else if (value[start - 1] === " ") {
    start -= 1;
  }
  return `${value.slice(0, start)}${value.slice(end)}`;
}

function removeWholeMentionOnDelete(
  previousValue: string,
  nextValue: string,
  catalog: Record<string, ComposerMentionEntry>
) {
  if (nextValue.length >= previousValue.length) return nextValue;
  const deletedRange = changedRange(previousValue, nextValue);
  const deletedLength = deletedRange.endPrevious - deletedRange.start;
  if (deletedRange.start === 0 && deletedRange.endPrevious === previousValue.length) return nextValue;
  if (deletedLength > 1) return nextValue;
  const mention = mentionRanges(previousValue, catalog).find(
    (range) => deletedRange.start < range.end && deletedRange.endPrevious > range.start
  );
  return mention ? removeMentionRange(previousValue, mention) : nextValue;
}

function ComposerRichDraftPreview({
  cursor,
  tokens
}: {
  cursor: number;
  tokens: ComposerDraftToken[];
}) {
  const renderCaret = (key: string) => <span className="composer-rich-caret" key={key} />;
  const rendered: ReactNode[] = [];
  let insertedCaret = false;
  tokens.forEach((token, index) => {
    if (!insertedCaret && cursor <= token.start) {
      rendered.push(renderCaret(`caret-before:${token.start}:${index}`));
      insertedCaret = true;
    }
    if (token.type === "mention") {
      rendered.push(
        <span className="inline-composer-mention" key={`${token.mention.kind}:${token.mention.id}:${token.start}:${index}`}>
          <CatalogIcon src={token.mention.iconPath} kind={token.mention.kind} fallbackSize={13} />
          <span>{token.mention.label}</span>
        </span>
      );
      if (!insertedCaret && cursor > token.start && cursor <= token.end) {
        rendered.push(renderCaret(`caret-after-mention:${token.end}:${index}`));
        insertedCaret = true;
      }
      return;
    }
    if (!insertedCaret && cursor > token.start && cursor <= token.end) {
      const offset = cursor - token.start;
      const before = token.text.slice(0, offset);
      const after = token.text.slice(offset);
      if (before) {
        rendered.push(
          <span className="composer-input-token" key={`text-before:${token.start}:${index}`}>
            {before}
          </span>
        );
      }
      rendered.push(renderCaret(`caret-text:${cursor}:${index}`));
      insertedCaret = true;
      if (after) {
        rendered.push(
          <span className="composer-input-token" key={`text-after:${cursor}:${index}`}>
            {after}
          </span>
        );
      }
      return;
    }
    rendered.push(
      <span className="composer-input-token" key={`text:${token.start}:${index}`}>
        {token.text}
      </span>
    );
  });
  if (!insertedCaret) {
    rendered.push(renderCaret("caret-end"));
  }
  return (
    <div className="composer-input-rich-preview" aria-hidden="true">
      {rendered}
    </div>
  );
}

function ComposerMentionPicker({
  activeKey,
  onActiveChange,
  onSelect,
  query,
  sections
}: {
  activeKey?: string;
  onActiveChange: (entry: ComposerMentionEntry) => void;
  onSelect: (entry: ComposerMentionEntry) => void;
  query: string;
  sections: ComposerMentionSection[];
}) {
  const hasItems = sections.some((section) => section.items.length > 0);
  return (
    <motion.div {...popoverMotion} className="composer-mention-popover">
      <div className="composer-mention-heading">
        <strong>@{query}</strong>
        <span>Plugins and skills</span>
      </div>
      {hasItems ? (
        <div className="composer-mention-scroll">
          {sections.map((section) =>
            section.items.length > 0 ? (
              <div className="composer-mention-section" key={section.label}>
                <div className="composer-mention-section-title">{section.label}</div>
                {section.items.map((item) => (
                  <button
                    className={cx("composer-mention-item", activeKey === `${item.kind}:${item.id}` && "active")}
                    key={`${item.kind}:${item.id}`}
                    onMouseEnter={() => onActiveChange(item)}
                    onClick={() => onSelect(item)}
                    role="option"
                    aria-selected={activeKey === `${item.kind}:${item.id}`}
                    type="button"
                  >
                    <span className="composer-mention-icon">
                      <CatalogIcon src={item.iconPath} kind={item.kind} fallbackSize={14} />
                    </span>
                    <span>
                      <strong>{item.label}</strong>
                      {item.description ? <small>{item.description}</small> : null}
                    </span>
                    <em>@{item.slug}</em>
                  </button>
                ))}
              </div>
            ) : null
          )}
        </div>
      ) : (
        <p className="composer-mention-empty">No matching plugin or skill.</p>
      )}
    </motion.div>
  );
}

function Composer({
  value,
  disabled,
  providerKey: activeProviderKey,
  providerName,
  providerOptions,
  providerStatus,
  usage,
  modelName,
  modelOptions,
  interactionMode,
  permissionMode,
  reasoningEffort,
  showStopButton,
  voiceStatus,
  voiceStatusText,
  voiceError,
  liveVoiceStatus,
  liveVoiceStatusText,
  liveVoiceEnabled,
  plugins,
  skills,
  onChange,
  onSend,
  onStop,
  onVoiceInput,
  onLiveVoice,
  onOpenRealtimeSettings,
  onOpenSkills,
  onOpenPlugins,
  onCreateTemporaryThread,
  onToggleAgentic,
  onCycleReasoning,
  onSelectPermissionMode,
  onSelectProvider,
  onSelectModel
}: {
  value: string;
  disabled?: boolean;
  providerKey: ProviderKey;
  providerName: string;
  providerOptions: RuntimeProviderOption[];
  providerStatus?: string | null;
  usage?: ProviderUsageSnapshot | null;
  modelName: string;
  modelOptions?: ProviderModelOption[];
  interactionMode: string;
  permissionMode: CodexPermissionMode;
  reasoningEffort: string;
  showStopButton?: boolean;
  voiceStatus: VoiceInputStatus;
  voiceStatusText?: string;
  voiceError?: string;
  liveVoiceStatus: LiveVoiceStatus;
  liveVoiceStatusText?: string;
  liveVoiceEnabled: boolean;
  plugins: PluginItem[];
  skills: SkillItem[];
  onChange: (value: string) => void;
  onSend: () => void;
  onStop?: () => void;
  onVoiceInput: () => void;
  onLiveVoice: () => void;
  onOpenRealtimeSettings: () => void;
  onOpenSkills: () => void;
  onOpenPlugins: () => void;
  onCreateTemporaryThread: () => void;
  onToggleAgentic: () => void;
  onCycleReasoning: () => void;
  onSelectPermissionMode: (mode: CodexPermissionMode) => void;
  onSelectProvider: (provider: ProviderKey) => void;
  onSelectModel: (model: string) => void;
}) {
  const [showActions, setShowActions] = useState(false);
  const [modelOpen, setModelOpen] = useState(false);
  const [permissionOpen, setPermissionOpen] = useState(false);
  const [mentionCursor, setMentionCursor] = useState(value.length);
  const [activeMentionIndex, setActiveMentionIndex] = useState(0);
  const [dismissedMentionKey, setDismissedMentionKey] = useState<string | null>(null);
  const [voiceMenuOpen, setVoiceMenuOpen] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const pendingSelectionRef = useRef<number | null>(null);
  const handledMentionDeleteRef = useRef(false);
  const actionsMenuRef = useRef<HTMLDivElement | null>(null);
  const modelMenuRef = useRef<HTMLDivElement | null>(null);
  const permissionMenuRef = useRef<HTMLDivElement | null>(null);
  const voiceMenuRef = useRef<HTMLDivElement | null>(null);
  const isListening = voiceStatus === "listening" || voiceStatus === "processing";
  const isProcessingVoice = voiceStatus === "processing";
  const voiceLabel = isProcessingVoice ? "Transcribing voice" : isListening ? "Stop voice input" : "Voice input";
  const liveVoiceActive = liveVoiceStatus !== "idle" && liveVoiceStatus !== "error";
  const liveVoiceLabel = !liveVoiceEnabled
    ? "Live Voice is only available with Codex"
    : liveVoiceActive
      ? "Stop Live Voice"
      : liveVoiceStatus === "error"
        ? "Restart Live Voice"
        : "Start Codex Live Voice";
  const voiceControlActive = liveVoiceActive || isListening || voiceMenuOpen;
  const voiceControlLabel = liveVoiceActive ? liveVoiceLabel : isListening ? voiceLabel : "Voice input options";
  const voiceControlStatus = liveVoiceActive
    ? liveVoiceStatus
    : isListening
      ? "listening"
      : liveVoiceStatus === "error"
        ? "error"
        : "idle";
  const activePermissionOption = codexPermissionOptions.find((option) => option.value === permissionMode) ?? codexPermissionOptions[0];
  const ActivePermissionIcon = activePermissionOption.Icon;
  const modelSections = modelFamilySections(activeProviderKey, modelName, modelOptions);
  const selectedModelSection = modelSections.find((section) =>
    section.models.some((model) => model.id.toLowerCase() === modelName.trim().toLowerCase())
  )?.key;
  const [expandedModelSections, setExpandedModelSections] = useState<string[]>([]);
  const compactModelName = compactComposerModelName(modelName);
  const hasText = value.trim().length > 0;
  const mentionPlugins = useMemo(() => (activeProviderKey === "codex" ? plugins : []), [activeProviderKey, plugins]);
  const mentionSkills = useMemo(() => (activeProviderKey === "codex" ? skills : []), [activeProviderKey, skills]);
  const mentionCatalog = useMemo(
    () => buildComposerMentionCatalog(mentionPlugins, mentionSkills),
    [mentionPlugins, mentionSkills]
  );
  const activeMention = useMemo(
    () => getActiveComposerMention(value, mentionCursor),
    [mentionCursor, value]
  );
  const mentionSections = useMemo(
    () => buildComposerMentionSections(activeMention?.query ?? null, mentionPlugins, mentionSkills),
    [activeMention?.query, mentionPlugins, mentionSkills]
  );
  const mentionEntries = useMemo(() => composerMentionEntries(mentionSections), [mentionSections]);
  const activeMentionKey = activeMention ? `${activeMention.start}:${activeMention.end}:${activeMention.query}:${value}` : null;
  const composerDraftTokens = useMemo(() => tokenizeComposerDraft(value, mentionCatalog), [mentionCatalog, value]);
  const hasRichMentions = useMemo(() => composerDraftTokens.some((token) => token.type === "mention"), [composerDraftTokens]);
  const showMentionPicker = activeProviderKey === "codex" && Boolean(activeMention) && dismissedMentionKey !== activeMentionKey && !showActions && !modelOpen && !permissionOpen && !voiceMenuOpen;
  const activeMentionEntry = mentionEntries[Math.min(activeMentionIndex, Math.max(0, mentionEntries.length - 1))];
  const updateMentionCursor = () => {
    const textarea = textareaRef.current;
    if (!textarea) return;
    const nextCursor = textarea.selectionStart ?? value.length;
    setMentionCursor((current) => (current === nextCursor ? current : nextCursor));
  };
  const clearComposerText = () => {
    handledMentionDeleteRef.current = false;
    pendingSelectionRef.current = 0;
    setMentionCursor(0);
    setDismissedMentionKey(null);
    onChange("");
  };
  const insertMention = (entry: ComposerMentionEntry) => {
    const next = replaceActiveComposerMention(value, textareaRef.current?.selectionStart ?? mentionCursor, entry.insertText);
    pendingSelectionRef.current = next.cursor;
    setDismissedMentionKey(null);
    onChange(next.value);
    setMentionCursor(next.cursor);
  };

  useEffect(() => {
    if (modelOpen) setExpandedModelSections(selectedModelSection ? [selectedModelSection] : modelSections.slice(0, 1).map((section) => section.key));
  }, [activeProviderKey, modelOpen, selectedModelSection]);

  useEffect(() => {
    setActiveMentionIndex(0);
  }, [activeMentionKey]);

  useEffect(() => {
    if (activeMentionIndex > Math.max(0, mentionEntries.length - 1)) {
      setActiveMentionIndex(Math.max(0, mentionEntries.length - 1));
    }
  }, [activeMentionIndex, mentionEntries.length]);

  useEffect(() => {
    const textarea = textareaRef.current;
    if (!textarea) return;
    textarea.style.height = "auto";
    const nextHeight = Math.min(176, Math.max(42, textarea.scrollHeight));
    textarea.style.height = `${nextHeight}px`;
    textarea.style.overflowY = textarea.scrollHeight > 176 ? "auto" : "hidden";
  }, [value]);
  useLayoutEffect(() => {
    const cursor = pendingSelectionRef.current;
    if (cursor === null) return;
    pendingSelectionRef.current = null;
    requestAnimationFrame(() => {
      textareaRef.current?.focus();
      textareaRef.current?.setSelectionRange(cursor, cursor);
      setMentionCursor(cursor);
    });
  }, [value]);
  useOutsideDismiss(showActions, actionsMenuRef, () => setShowActions(false));
  useOutsideDismiss(modelOpen, modelMenuRef, () => setModelOpen(false));
  useOutsideDismiss(permissionOpen, permissionMenuRef, () => setPermissionOpen(false));
  useOutsideDismiss(voiceMenuOpen, voiceMenuRef, () => setVoiceMenuOpen(false));

  return (
    <div className="composer-wrap">
      <div className="composer-stack">
        <AnimatePresence initial={false}>
          {shouldShowLiveVoiceStatusPanel(liveVoiceStatus, liveVoiceStatusText) && (
            <motion.div
              className="composer-live-voice-panel-motion"
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: 4 }}
              transition={{ duration: 0.16, ease: [0.22, 1, 0.36, 1] }}
            >
              <LiveVoiceStatusPanel
                status={liveVoiceStatus}
                text={liveVoiceStatusText}
                onOpenSettings={onOpenRealtimeSettings}
              />
            </motion.div>
          )}
        </AnimatePresence>
      <motion.div layout className={cx("composer", isListening && "is-listening", hasText && "has-text")}>
        <div className={cx("composer-input-shell", hasRichMentions && "has-rich-mentions")}>
          {hasRichMentions && <ComposerRichDraftPreview cursor={mentionCursor} tokens={composerDraftTokens} />}
          <textarea
            ref={textareaRef}
            className={cx("composer-input", hasRichMentions && "rich-mention-input")}
            value={value}
            onChange={(event) => {
              const cursor = event.currentTarget.selectionStart ?? event.currentTarget.value.length;
              setMentionCursor(cursor);
              setDismissedMentionKey(null);
              if (handledMentionDeleteRef.current) {
                handledMentionDeleteRef.current = false;
                return;
              }
              onChange(hasRichMentions ? removeWholeMentionOnDelete(value, event.target.value, mentionCatalog) : event.target.value);
            }}
            placeholder="What would you like to do?"
            onClick={updateMentionCursor}
            onKeyDown={(event) => {
              const cursor = event.currentTarget.selectionStart ?? mentionCursor;
              const selectionEnd = event.currentTarget.selectionEnd ?? cursor;
              const hasFullSelection = value.length > 0 && cursor === 0 && selectionEnd === value.length;
              if (hasFullSelection && (event.key === "Backspace" || event.key === "Delete" || event.key === "Escape")) {
                event.preventDefault();
                clearComposerText();
                return;
              }
              if (showMentionPicker && mentionEntries.length > 0 && event.key === "ArrowDown") {
                event.preventDefault();
                setActiveMentionIndex((current) => (current + 1) % mentionEntries.length);
                return;
              }
              if (showMentionPicker && mentionEntries.length > 0 && event.key === "ArrowUp") {
                event.preventDefault();
                setActiveMentionIndex((current) => (current - 1 + mentionEntries.length) % mentionEntries.length);
                return;
              }
              if ((event.key === "Enter" || event.key === "Tab") && showMentionPicker && activeMentionEntry) {
                event.preventDefault();
                insertMention(activeMentionEntry);
                return;
              }
              if (event.key === "Escape" && showMentionPicker && activeMentionKey) {
                event.preventDefault();
                setDismissedMentionKey(activeMentionKey);
                return;
              }
              if (event.key === "Backspace" && cursor === selectionEnd && hasRichMentions) {
                const range = mentionRangeEndingAt(value, cursor, mentionCatalog);
                if (range) {
                  event.preventDefault();
                  handledMentionDeleteRef.current = true;
                  const nextValue = removeMentionRange(value, range);
                  const nextCursor = Math.min(range.start, nextValue.length);
                  pendingSelectionRef.current = nextCursor;
                  setMentionCursor(nextCursor);
                  onChange(nextValue);
                  return;
                }
              }
              if (event.key === "Enter" && !event.shiftKey) {
                event.preventDefault();
                if (!disabled && hasText) onSend();
              }
            }}
            onKeyUp={updateMentionCursor}
            onSelect={updateMentionCursor}
          />
        </div>
        <AnimatePresence>
          {showMentionPicker && (
            <ComposerMentionPicker
              activeKey={activeMentionEntry ? `${activeMentionEntry.kind}:${activeMentionEntry.id}` : undefined}
              onActiveChange={(entry) => {
                const index = mentionEntries.findIndex((item) => item.id === entry.id && item.kind === entry.kind);
                if (index >= 0) setActiveMentionIndex(index);
              }}
              onSelect={insertMention}
              query={activeMention?.query ?? ""}
              sections={mentionSections}
            />
          )}
        </AnimatePresence>
        <div className="composer-tools">
          <div className="quick-actions" ref={actionsMenuRef}>
            <IconButton
              label="More actions"
              active={showActions}
	              onClick={() => {
	                setShowActions((value) => !value);
	                setModelOpen(false);
	                setPermissionOpen(false);
	                setVoiceMenuOpen(false);
	              }}
            >
              <Plus size={20} />
            </IconButton>
            <AnimatePresence>
              {showActions && (
                <motion.div {...popoverMotion} className="quick-actions-menu">
                  <button onClick={() => { setShowActions(false); onOpenSkills(); }}>
                    <Sparkles size={15} />
                    <span>
                      Use skills
                      <small>Attach reusable instructions to this thread</small>
                    </span>
                  </button>
                  <button onClick={() => { setShowActions(false); onOpenPlugins(); }}>
                    <Plug size={15} />
                    <span>
                      Use plugins
                      <small>Select installed Codex plugins for this message</small>
                    </span>
                  </button>
                  <button onClick={() => { setShowActions(false); onCreateTemporaryThread(); }}>
                    <Shield size={15} />
                    <span>
                      New temporary chat
                      <small>Disposable local chat that is cleaned up when you leave it</small>
                    </span>
                  </button>
                  <button onClick={() => { setShowActions(false); onToggleAgentic(); }}>
                    <Bot size={15} />
                    <span>
                      Toggle agent mode
                      <small>{interactionMode === "Agentic" ? "Switch to direct chat" : "Switch to agentic work"}</small>
                    </span>
                  </button>
                </motion.div>
              )}
            </AnimatePresence>
          </div>
          {activeProviderKey === "codex" && (
            <div className="composer-menu-wrap composer-permission-wrap" ref={permissionMenuRef}>
              <PillButton
                className="permission-pill"
                active={permissionOpen || permissionMode === "fullAccess"}
                icon={<ActivePermissionIcon size={15} />}
	                onClick={() => {
	                  setPermissionOpen((value) => !value);
	                  setShowActions(false);
	                  setModelOpen(false);
	                  setVoiceMenuOpen(false);
	                }}
              >
                {activePermissionOption.shortLabel}
                <ChevronDown size={12} />
              </PillButton>
              <AnimatePresence>
                {permissionOpen && (
                  <motion.div {...popoverMotion} className="composer-popover permission-popover">
                    {codexPermissionOptions.map((option) => {
                      const isSelected = option.value === permissionMode;
                      const OptionIcon = option.Icon;
                      return (
                        <button
                          key={option.value}
                          type="button"
                          className={cx("permission-option", isSelected && "active")}
                          onClick={() => {
                            onSelectPermissionMode(option.value);
                            setPermissionOpen(false);
                          }}
                        >
                          <OptionIcon size={16} />
                          <span>
                            <strong>{option.label}</strong>
                            <small>{option.detail}</small>
                          </span>
                          {isSelected && <Check size={14} />}
                        </button>
                      );
                    })}
                  </motion.div>
                )}
              </AnimatePresence>
            </div>
          )}
          <span className="composer-spacer" />
          <div className="composer-menu-wrap composer-model-wrap" ref={modelMenuRef}>
            <div className={cx("composer-model-cluster", modelOpen && "active")}>
              <button
                type="button"
                className="composer-model-main"
	                onClick={() => {
	                  setModelOpen((value) => !value);
	                  setShowActions(false);
	                  setPermissionOpen(false);
	                  setVoiceMenuOpen(false);
	                }}
              >
                <span className="composer-model-name">{compactModelName}</span>
              </button>
              <button
                type="button"
                className="composer-effort-button"
                aria-label={`Cycle reasoning effort. Current: ${reasoningEffort}`}
                onClick={onCycleReasoning}
              >
                <span className="composer-effort-label">{reasoningEffort}</span>
              </button>
            </div>
            <AnimatePresence>
              {modelOpen && (
                <motion.div {...popoverMotion} className="composer-popover model-popover">
                  <div className="popover-kicker">Model</div>
                  <div className="model-family-sections">
                    {modelSections.map((section) => {
                      const isExpanded = expandedModelSections.includes(section.key);
                      return (
                        <div
                          key={section.key}
                          className={cx(
                            "model-family-section",
                            `model-family-section-${section.key}`,
                            isExpanded && "expanded"
                          )}
                        >
                          <button
                            type="button"
                            className="model-family-heading"
                            onClick={() => {
                              setExpandedModelSections((current) =>
                                current.includes(section.key)
                                  ? current.filter((key) => key !== section.key)
                                  : [...current, section.key]
                              );
                            }}
                          >
                            <span>
                              <strong>{section.label}</strong>
                            </span>
                            <ChevronDown size={14} />
                          </button>
                          <AnimatePresence initial={false}>
                            {isExpanded && (
                              <motion.div
                                className="model-family-models"
                                initial={{ height: 0, opacity: 0 }}
                                animate={{ height: "auto", opacity: 1 }}
                                exit={{ height: 0, opacity: 0 }}
                                transition={{ duration: 0.16, ease: [0.22, 1, 0.36, 1] }}
                              >
                                {section.models.map((model) => {
                                  const isSelected = model.id.toLowerCase() === modelName.trim().toLowerCase();
                                  return (
                                    <button
                                      key={`${section.key}-${model.id}`}
                                      type="button"
                                      disabled={model.disabled}
                                      className={cx("model-option", isSelected && "active", model.disabled && "disabled")}
                                      onClick={() => {
                                        if (model.disabled) return;
                                        setModelOpen(false);
                                        onSelectModel(model.id);
                                      }}
                                    >
                                      <span>
                                        <strong>{model.displayName || model.id}</strong>
                                      </span>
                                      {isSelected && <Check size={14} />}
                                    </button>
                                  );
                                })}
                              </motion.div>
                            )}
                          </AnimatePresence>
                        </div>
                      );
                    })}
                  </div>
                </motion.div>
              )}
            </AnimatePresence>
          </div>
	          <div className="composer-menu-wrap composer-voice-wrap" ref={voiceMenuRef}>
	            <IconButton
	              label={voiceControlLabel}
	              active={voiceControlActive}
	              className={cx("composer-live-voice-button", `state-${voiceControlStatus}`)}
	              tone={voiceControlActive ? "blue" : "subtle"}
	              onClick={() => {
	                setVoiceMenuOpen((value) => !value);
	                setShowActions(false);
	                setModelOpen(false);
	                setPermissionOpen(false);
	              }}
	            >
	              <RealtimeVoiceMark size={18} active={liveVoiceActive || isListening} />
	            </IconButton>
	            <AnimatePresence>
	              {voiceMenuOpen && (
	                <motion.div {...popoverMotion} className="composer-popover voice-popover">
	                  <div className="popover-kicker">Voice</div>
	                  <button
	                    type="button"
	                    className={cx("voice-option", liveVoiceActive && "active")}
	                    disabled={!liveVoiceEnabled || liveVoiceStatus === "connecting"}
	                    onClick={() => {
	                      if (!liveVoiceEnabled || liveVoiceStatus === "connecting") return;
	                      setVoiceMenuOpen(false);
	                      onLiveVoice();
	                    }}
	                  >
	                    <span className="voice-option-icon">
	                      <RealtimeVoiceMark size={16} active={liveVoiceActive} />
	                    </span>
	                    <span className="voice-option-copy">
	                      <strong>{liveVoiceActive ? "Stop Live Voice" : liveVoiceStatus === "error" ? "Restart Live Voice" : "Live Voice"}</strong>
	                      <small>{liveVoiceEnabled ? "Realtime conversation with Codex" : "Only available with Codex provider"}</small>
	                    </span>
	                    {liveVoiceActive && <Check size={14} />}
	                  </button>
	                  <button
	                    type="button"
	                    className={cx("voice-option", isListening && "active")}
	                    disabled={isProcessingVoice}
	                    onClick={() => {
	                      if (isProcessingVoice) return;
	                      setVoiceMenuOpen(false);
	                      onVoiceInput();
	                    }}
	                  >
	                    <Mic size={16} />
	                    <span className="voice-option-copy">
	                      <strong>{isProcessingVoice ? "Transcribing..." : isListening ? "Stop dictation" : "Dictate message"}</strong>
	                      <small>Speech to text in the composer</small>
	                    </span>
	                    {isListening && <Check size={14} />}
	                  </button>
	                </motion.div>
	              )}
	            </AnimatePresence>
	          </div>
          {showStopButton ? (
            <IconButton label="Stop response" tone="danger" onClick={onStop}>
              <Square size={13} fill="currentColor" strokeWidth={2.4} />
            </IconButton>
          ) : (
            <IconButton label="Send message" tone="gold" onClick={onSend} disabled={!hasText}>
              <ArrowUp size={18} />
            </IconButton>
          )}
        </div>
        <ComposerContextBar
          usage={usage}
          providerName={providerName}
          providerKey={activeProviderKey}
          providerOptions={providerOptions}
          providerStatus={providerStatus}
          onSelectProvider={onSelectProvider}
        />
      </motion.div>
      </div>
    </div>
  );
}

function ThreadsView({
  compact,
  onToggleCompact,
  onHideWindow,
  onOpenThreadNote,
  onOpenInstructions,
  onOpenMemory,
  onOpenSkills,
  onOpenPlugins,
  onCloseThreadNotePanel,
  title,
  providerName,
  providerKey,
  providerOptions,
  modelName,
  modelOptions,
  workspaceRootPath,
  providerStatus,
  usage,
  interactionMode,
  permissionMode,
  reasoningEffort,
  messages,
  composerText,
  isSending,
  voiceStatus,
  voiceStatusText,
  voiceError,
  liveVoiceStatus,
  liveVoiceStatusText,
  plugins,
  skills,
  onComposerText,
  onSend,
  onStop,
  onVoiceInput,
  onLiveVoice,
  onOpenRealtimeSettings,
  onToggleAgentic,
  onCycleReasoning,
  onSelectPermissionMode,
  onCreateTemporaryThread,
  onAddTextToThreadNote,
  onSpeakText,
  onRespondToApproval,
  onSelectProvider,
  onSelectModel
}: {
  compact: boolean;
  onToggleCompact: () => void;
  onHideWindow: () => void;
  onOpenThreadNote: () => void;
  onOpenInstructions: () => void;
  onOpenMemory: () => void;
  onOpenSkills: () => void;
  onOpenPlugins: () => void;
  onCloseThreadNotePanel: () => void;
  title: string;
  providerName: string;
  providerKey: ProviderKey;
  providerOptions: RuntimeProviderOption[];
  modelName: string;
  modelOptions?: ProviderModelOption[];
  workspaceRootPath?: string | null;
  providerStatus?: string | null;
  usage?: ProviderUsageSnapshot | null;
  interactionMode: string;
  permissionMode: CodexPermissionMode;
  reasoningEffort: string;
  messages: ChatMessage[];
  composerText: string;
  isSending: boolean;
  voiceStatus: VoiceInputStatus;
  voiceStatusText?: string;
  voiceError?: string;
  liveVoiceStatus: LiveVoiceStatus;
  liveVoiceStatusText?: string;
  plugins: PluginItem[];
  skills: SkillItem[];
  onComposerText: (value: string) => void;
  onSend: () => void;
  onStop: () => void;
  onVoiceInput: () => void;
  onLiveVoice: () => void;
  onOpenRealtimeSettings: () => void;
  onToggleAgentic: () => void;
  onCycleReasoning: () => void;
  onSelectPermissionMode: (mode: CodexPermissionMode) => void;
  onCreateTemporaryThread: () => void;
  onAddTextToThreadNote: (text: string) => void;
  onSpeakText: (text: string) => void | Promise<void>;
  onRespondToApproval: ApprovalResponder;
  onSelectProvider: (provider: ProviderKey) => void;
  onSelectModel: (model: string) => void;
}) {
  const timelineItems = useMemo(() => buildChatTimeline(messages), [messages]);
  const messageMentionCatalog = useMemo(() => buildComposerMentionCatalog(plugins, skills), [plugins, skills]);
  const activeWorkControls = isSending || liveVoiceStatus === "delegating";
  const activeWorkGroupID = useMemo(() => {
    if (!activeWorkControls) return null;
    let lastUserIndex = -1;
    timelineItems.forEach((item, index) => {
      if (item.kind === "message" && item.message.role === "user") {
        lastUserIndex = index;
      }
    });
    let activeGroupID: string | null = null;
    for (let index = lastUserIndex + 1; index < timelineItems.length; index += 1) {
      const item = timelineItems[index];
      if (item.kind === "work" && workGroupStatus(item.activities) === "running") {
        activeGroupID = item.id;
      }
    }
    return activeGroupID;
  }, [activeWorkControls, timelineItems]);
  return (
    <main className="assistant-main">
      <TopBar
        title={title}
        workspaceRootPath={workspaceRootPath}
        compact={compact}
        onToggleCompact={onToggleCompact}
        onHideWindow={onHideWindow}
        onOpenInstructions={onOpenInstructions}
        onOpenMemory={onOpenMemory}
      />
      <section
        className="chat-scroll"
        onClick={onCloseThreadNotePanel}
        onDoubleClick={onCloseThreadNotePanel}
      >
        <div className="chat-stack">
          {timelineItems.map((item) => item.kind === "work" ? (
            <WorkActivityGroup
              key={item.id}
              activities={item.activities}
              onRespondToApproval={onRespondToApproval}
              onStopWork={item.id === activeWorkGroupID ? onStop : undefined}
              active={item.id === activeWorkGroupID}
            />
          ) : item.kind === "thinking" ? (
            <ThinkingGroup key={item.id} messages={item.messages} />
          ) : item.kind === "delegated" ? (
            <DelegatedTaskCard key={item.id} activity={item.activity} />
          ) : item.kind === "turn" ? (
            <CompletedTurnGroup
              key={item.id}
              innerItems={item.items}
              toolStepCount={item.toolStepCount}
              activeWorkGroupID={activeWorkGroupID}
              onRespondToApproval={onRespondToApproval}
              onStop={onStop}
              messageMentionCatalog={messageMentionCatalog}
              onAddTextToThreadNote={onAddTextToThreadNote}
              onComposerText={onComposerText}
              onOpenThreadNote={onOpenThreadNote}
              onSpeakText={onSpeakText}
            />
          ) : (
            <MessageBubble
              key={item.message.id}
              message={item.message}
              mentionCatalog={messageMentionCatalog}
              onAddTextToThreadNote={onAddTextToThreadNote}
              onUseTextInComposer={onComposerText}
              onOpenThreadNote={onOpenThreadNote}
              onSpeakText={onSpeakText}
              onRespondToApproval={onRespondToApproval}
            />
          ))}
          {!messages.length && (
            <div className="empty-feature chat-empty">
              <MessageSquare size={34} />
              <h2>No messages in this chat yet</h2>
              <p>Send a message to start a real Codex turn.</p>
            </div>
          )}
        </div>
      </section>
      <Composer
        value={composerText}
        disabled={isSending}
        providerKey={providerKey}
        providerName={providerName}
        providerOptions={providerOptions}
        providerStatus={providerStatus}
        usage={usage}
        modelName={modelName}
        modelOptions={modelOptions}
        interactionMode={interactionMode}
        permissionMode={permissionMode}
        reasoningEffort={reasoningEffort}
        showStopButton={activeWorkControls}
        voiceStatus={voiceStatus}
        voiceStatusText={voiceStatusText}
        voiceError={voiceError}
        liveVoiceStatus={liveVoiceStatus}
        liveVoiceStatusText={liveVoiceStatusText}
        liveVoiceEnabled={providerKey === "codex"}
        plugins={plugins}
        skills={skills}
        onChange={onComposerText}
        onSend={onSend}
        onStop={onStop}
        onVoiceInput={onVoiceInput}
        onLiveVoice={onLiveVoice}
        onOpenRealtimeSettings={onOpenRealtimeSettings}
        onOpenSkills={onOpenSkills}
        onOpenPlugins={onOpenPlugins}
        onCreateTemporaryThread={onCreateTemporaryThread}
        onToggleAgentic={onToggleAgentic}
        onCycleReasoning={onCycleReasoning}
        onSelectPermissionMode={onSelectPermissionMode}
        onSelectProvider={onSelectProvider}
        onSelectModel={onSelectModel}
      />
    </main>
  );
}

function AssistantInspectorPanel({
  panel,
  sessionInstructions,
  threadNoteWorkspace,
  threadNoteDraft,
  threadMemory,
  onClose,
  onSessionInstructions,
  onClearSessionInstructions,
  onThreadNoteDraft,
  onSaveThreadNote,
  onCreateThreadNote,
  onSelectThreadNote,
  onRefreshMemory
}: {
  panel: AssistantPanelKey;
  sessionInstructions: string;
  threadNoteWorkspace: ThreadNoteWorkspace | null;
  threadNoteDraft: string;
  threadMemory: ThreadMemorySnapshot | null;
  onClose: () => void;
  onSessionInstructions: (value: string) => void;
  onClearSessionInstructions: () => void;
  onThreadNoteDraft: (value: string) => void;
  onSaveThreadNote: () => void;
  onCreateThreadNote: () => void;
  onSelectThreadNote: (noteID: string) => void;
  onRefreshMemory: () => void;
}) {
  const threadNoteTextareaRef = useRef<HTMLTextAreaElement | null>(null);
  const threadNoteActionsRef = useRef<HTMLDivElement | null>(null);
  const threadNoteSwitchRef = useRef<HTMLDivElement | null>(null);
  const [noteSwitchOpen, setNoteSwitchOpen] = useState(false);
  const [threadNoteActionsOpen, setThreadNoteActionsOpen] = useState(false);
  const threadNotes = threadNoteWorkspace?.notes ?? [];
  const selectedThreadNote = threadNoteWorkspace?.selectedNote ?? null;

  useEffect(() => {
    setNoteSwitchOpen(false);
    setThreadNoteActionsOpen(false);
  }, [panel, threadNoteWorkspace?.selectedNoteID]);
  useOutsideDismiss(threadNoteActionsOpen, threadNoteActionsRef, () => setThreadNoteActionsOpen(false));
  useOutsideDismiss(noteSwitchOpen, threadNoteSwitchRef, () => setNoteSwitchOpen(false));

  if (!panel) return null;

  const title = panel === "thread-note"
    ? "Thread Note"
    : panel === "memory"
      ? "Memory"
      : "Session Instructions";
  const icon = panel === "thread-note"
    ? <FileText size={17} />
    : panel === "memory"
      ? <Brain size={17} />
      : <ListTodo size={17} />;

  return (
    <motion.aside
      {...popoverMotion}
      className={cx("assistant-inspector", panel === "thread-note" && "thread-note-inspector")}
      style={{ transformOrigin: "top right" }}
    >
      {panel !== "thread-note" && (
        <div className="inspector-header">
          <div>
            {icon}
            <strong>{title}</strong>
          </div>
          <IconButton label="Close panel" onClick={onClose}>
            <X size={17} />
          </IconButton>
        </div>
      )}

      {panel === "session-instructions" && (
        <div className="inspector-stack">
          <p className="inspector-help">
            These instructions apply only to this chat and are sent with the next assistant turn.
          </p>
          <textarea
            className="inspector-textarea monospace"
            value={sessionInstructions}
            onChange={(event) => onSessionInstructions(event.target.value)}
            placeholder="Add one-time rules for this chat..."
          />
          <div className="inspector-footer">
            <span className={cx("status-dot-line", sessionInstructions.trim() && "active")}>
              <CheckCircle2 size={14} />
              {sessionInstructions.trim() ? "Active for this chat" : "No session instructions"}
            </span>
            <button className="soft-button" onClick={onClearSessionInstructions}>Clear</button>
          </div>
        </div>
      )}

      {panel === "thread-note" && (
        <div className="thread-note-panel">
          <div className="thread-note-side-top inspector-header">
            <div>
              <FileText size={16} />
              <strong>Thread Note</strong>
            </div>
            <div className="thread-note-side-actions">
              <IconButton label="New thread note" onClick={onCreateThreadNote}>
                <FilePlus2 size={16} />
              </IconButton>
              <div className="thread-note-action-wrap" ref={threadNoteActionsRef}>
                <IconButton label="Thread note actions" active={threadNoteActionsOpen} onClick={() => setThreadNoteActionsOpen((open) => !open)}>
                  <MoreHorizontalIcon size={16} />
                </IconButton>
                {threadNoteActionsOpen && (
                  <div className="thread-note-popover thread-note-actions-menu">
                    <button onClick={() => { setThreadNoteActionsOpen(false); onCreateThreadNote(); }}>
                      <FilePlus2 size={14} />
                      New thread note
                    </button>
                    <button disabled={!selectedThreadNote} onClick={() => { setThreadNoteActionsOpen(false); onSaveThreadNote(); }}>
                      <Save size={14} />
                      Save current note
                    </button>
                    <button onClick={() => { setThreadNoteActionsOpen(false); onClose(); }}>
                      <X size={14} />
                      Close panel
                    </button>
                  </div>
                )}
              </div>
              <IconButton label="Close panel" onClick={onClose}>
                <X size={16} />
              </IconButton>
            </div>
          </div>

          {threadNotes.length > 0 && selectedThreadNote ? (
            <>
              <div className="thread-note-current-card" ref={threadNoteSwitchRef}>
                <span>
                  <small>Current</small>
                  <small>Note</small>
                </span>
                <strong>{selectedThreadNote.title || "Untitled note"}</strong>
                <button type="button" className="thread-note-switch-button" onClick={() => setNoteSwitchOpen((open) => !open)}>
                  Switch
                  <ChevronDown size={12} />
                </button>
                {noteSwitchOpen && (
                  <div className="thread-note-popover thread-note-switch-menu">
                    {threadNotes.map((note) => (
                      <button
                        key={note.id}
                        className={cx(note.id === threadNoteWorkspace?.selectedNoteID && "active")}
                        onClick={() => {
                          setNoteSwitchOpen(false);
                          onSelectThreadNote(note.id);
                        }}
                      >
                        <FileText size={14} />
                        <span>{note.title || "Untitled note"}</span>
                      </button>
                    ))}
                  </div>
                )}
              </div>

              <div className="thread-note-editor-card thread-note-editor">
                <MarkdownEditorSurface
                  textareaRef={threadNoteTextareaRef}
                  value={threadNoteDraft}
                  onChange={onThreadNoteDraft}
                  placeholder="Write your thread note..."
                  sourcePath={selectedThreadNote.path}
                  compact
                />
              </div>

              <div className="thread-note-side-footer">
                <small>{selectedThreadNote.path ?? "Stored in OpenAssist thread notes"}</small>
                <button className="gold-soft-button" onClick={onSaveThreadNote}>
                  <Save size={15} />
                  Save
                </button>
              </div>
            </>
          ) : (
            <div className="thread-note-empty-card">
              <h3>No thread notes yet</h3>
              <p>Create a note for this thread and start collecting key points.</p>
              <button type="button" onClick={onCreateThreadNote}>
                New thread note
              </button>
            </div>
          )}
        </div>
      )}

      {panel === "memory" && (
        <div className="inspector-stack">
          <div className="inspector-footer">
            <span className={cx("status-dot-line", threadMemory?.exists && "active")}>
              <Brain size={14} />
              {threadMemory?.exists ? "Memory file found" : "No memory file yet"}
            </span>
            <button className="soft-button" onClick={onRefreshMemory}>
              <RefreshCw size={14} />
              Refresh
            </button>
          </div>
          <textarea
            className="inspector-textarea monospace readonly"
            value={threadMemory?.markdown || ""}
            readOnly
            placeholder="No saved memory for this chat yet."
          />
          {threadMemory?.path && <small className="path-line">{threadMemory.path}</small>}
        </div>
      )}
    </motion.aside>
  );
}

function NotesView({
  compact,
  onToggleCompact,
  onHideWindow,
  onOpenInstructions,
  onOpenMemory,
  workspaceRootPath,
  projects,
  selectedProjectID,
  notesScope,
  notes,
  threadNotes,
  noteFolders,
  activeNoteTarget,
  noteDetail,
  noteDraft,
  noteSaveStatus,
  onSelectProject,
  onSelectScope,
  onSelectNote,
  onSelectThreadNoteItem,
  onCreateNote,
  onNoteDraft,
  onSaveNote
}: {
  compact: boolean;
  onToggleCompact: () => void;
  onHideWindow: () => void;
  onOpenInstructions: () => void;
  onOpenMemory: () => void;
  workspaceRootPath?: string | null;
  projects: ProjectItem[];
  selectedProjectID?: string;
  notesScope: NotesScope;
  notes: NoteItem[];
  threadNotes: ThreadNoteListItem[];
  noteFolders: NoteFolderItem[];
  activeNoteTarget?: SelectedNoteTarget | null;
  noteDetail?: NoteDetail | null;
  noteDraft: string;
  noteSaveStatus: NoteSaveStatus;
  onSelectProject: (projectID: string) => void;
  onSelectScope: (scope: NotesScope) => void;
  onSelectNote: (note: NoteItem) => void;
  onSelectThreadNoteItem: (note: ThreadNoteListItem) => void;
  onCreateNote: () => void;
  onNoteDraft: (value: string) => void;
  onSaveNote: () => void;
}) {
  const [selectedFolderID, setSelectedFolderID] = useState<string | null>(null);
  const [noteSearch, setNoteSearch] = useState("");
  const noteTextareaRef = useRef<HTMLTextAreaElement | null>(null);
  const visibleProjects = useMemo(
    () => projects.filter((project) => project.kind !== "folder"),
    [projects]
  );
  const selectedProject =
    visibleProjects.find((project) => sameID(project.id, selectedProjectID))
    ?? visibleProjects[0];
  const projectNotes = useMemo(
    () => notes.filter((note) => selectedProject && sameID(note.projectID, selectedProject.id)),
    [notes, selectedProject]
  );
  const projectThreadNotes = useMemo(
    () => threadNotes.filter((note) => selectedProject && sameID(note.projectID, selectedProject.id)),
    [threadNotes, selectedProject]
  );
  const projectFolders = useMemo(
    () => noteFolders.filter((folder) => selectedProject && sameID(folder.projectID, selectedProject.id)),
    [noteFolders, selectedProject]
  );
  useEffect(() => {
    setSelectedFolderID(null);
  }, [selectedProject?.id, notesScope]);
  const filteredProjectNotes = useMemo(() => {
    const query = noteSearch.trim().toLowerCase();
    return projectNotes
      .filter((note) => !selectedFolderID || note.folderID === selectedFolderID)
      .filter((note) => {
        if (!query) return true;
        return [note.title, note.subtitle, note.projectName]
          .filter(Boolean)
          .some((value) => String(value).toLowerCase().includes(query));
      })
      .slice(0, 32);
  }, [noteSearch, projectNotes, selectedFolderID]);
  const filteredThreadNotes = useMemo(() => {
    const query = noteSearch.trim().toLowerCase();
    return projectThreadNotes
      .filter((note) => {
        if (!query) return true;
        return [note.title, note.subtitle, note.threadTitle, note.projectName]
          .filter(Boolean)
          .some((value) => String(value).toLowerCase().includes(query));
      })
      .slice(0, 32);
  }, [noteSearch, projectThreadNotes]);
  const activeFolder = selectedFolderID
    ? projectFolders.find((folder) => folder.id === selectedFolderID)
    : null;
  const activeProjectNote = activeNoteTarget?.scope === "project"
    ? projectNotes.find((note) => sameID(note.id, activeNoteTarget.noteID))
    : undefined;
  const activeThreadNote = activeNoteTarget?.scope === "thread"
    ? projectThreadNotes.find((note) => sameID(note.id, activeNoteTarget.noteID) && sameID(note.threadID, activeNoteTarget.threadID))
    : undefined;
  const activeSourceLabel = activeNoteTarget?.scope === "thread"
    ? activeThreadNote?.threadTitle ?? "Thread notes"
    : activeProjectNote?.projectName ?? selectedProject?.title ?? "Project notes";
  const projectNoteCountLabel = `${projectNotes.length} ${projectNotes.length === 1 ? "note" : "notes"}`;
  const threadNoteCountLabel = `${projectThreadNotes.length} ${projectThreadNotes.length === 1 ? "note" : "notes"}`;
  const activeFolderCountLabel = activeFolder
    ? `${activeFolder.noteCount} ${activeFolder.noteCount === 1 ? "note" : "notes"}`
    : "";
  const notesSubtitle = activeFolder
    ? `${activeFolder.name} · ${activeFolderCountLabel}`
    : selectedProject
      ? `${selectedProject.title} · ${notesScope === "project" ? "Project notes" : "Thread notes"}`
      : "Choose a project";
  const notesLead = activeFolder
    ? `${activeFolderCountLabel} in ${activeFolder.name}.`
    : selectedProject
      ? notesScope === "project"
        ? projectNotes.length
          ? `Shared notes for ${selectedProject.title}.`
          : `Shared notes for ${selectedProject.title} will show here.`
        : projectThreadNotes.length
          ? `Thread notes from chats that belong to ${selectedProject.title}.`
          : `No thread notes yet for ${selectedProject.title}.`
      : "Pick a project to see its notes.";
  const saveStatusLabel =
    noteSaveStatus.kind === "saving" ? "Saving..."
      : noteSaveStatus.kind === "dirty" ? "Unsaved"
        : noteSaveStatus.kind === "error" ? noteSaveStatus.message ?? "Not saved"
          : noteSaveStatus.kind === "saved" ? "Saved"
            : "";
  return (
    <main className="feature-main">
      <TopBar
        title="Notes"
        subtitle={notesSubtitle}
        workspaceRootPath={workspaceRootPath}
        compact={compact}
        onToggleCompact={onToggleCompact}
        onHideWindow={onHideWindow}
        onOpenInstructions={onOpenInstructions}
        onOpenMemory={onOpenMemory}
      />
      <div className="notes-layout">
        <aside className="notes-list-panel">
          <div className="subhead-row">
            <div>
              <strong>Notes</strong>
              <p className="muted">{notesLead}</p>
            </div>
            <IconButton label="New project note" tone="gold" onClick={onCreateNote}>
              <Plus size={17} />
            </IconButton>
          </div>
          <div className="note-project-strip" aria-label="Note projects">
            {visibleProjects.slice(0, 12).map((project) => (
              <button
                key={project.id}
                type="button"
                className={cx(selectedProject && sameID(project.id, selectedProject.id) && "active")}
                onClick={() => onSelectProject(project.id)}
              >
                {projectIcon(project)}
                <span>{project.title}</span>
              </button>
            ))}
          </div>
          <div className="sidebar-note-scope segmented">
            <button className={cx(notesScope === "project" && "selected")} onClick={() => onSelectScope("project")}>
              Project notes
            </button>
            <button className={cx(notesScope === "thread" && "selected")} onClick={() => onSelectScope("thread")}>
              Thread notes
            </button>
          </div>
          <label className="search-field">
            <Search size={15} />
            <input
              placeholder={notesScope === "project" ? "Search notes" : "Search thread notes"}
              value={noteSearch}
              onChange={(event) => setNoteSearch(event.target.value)}
            />
          </label>
          {notesScope === "project" && (
            <>
              {selectedFolderID && (
                <button className="note-row" onClick={() => setSelectedFolderID(null)}>
                  <NotebookTabs size={16} />
                  <span>
                    All project notes
                    <small>{projectNoteCountLabel}</small>
                  </span>
                </button>
              )}
              {activeFolder && (
                <button className="note-row active" onClick={() => setSelectedFolderID(null)}>
                  <Folder size={16} />
                  <span>
                    {activeFolder.name}
                    <small>{activeFolderCountLabel}</small>
                  </span>
                </button>
              )}
              {!activeFolder && projectFolders.slice(0, 8).map((folder) => (
                <button key={`${folder.projectID}-${folder.id}`} className="note-row" onClick={() => setSelectedFolderID(folder.id)}>
                  <Folder size={16} />
                  <span>
                    {folder.name}
                    <small>{folder.noteCount} notes</small>
                  </span>
                </button>
              ))}
              {filteredProjectNotes.map((note) => (
                <button
                  key={`${note.projectID}-${note.id}`}
                  className={cx("note-row", activeNoteTarget?.scope === "project" && sameID(note.id, activeNoteTarget.noteID) && "active")}
                  onClick={() => onSelectNote(note)}
                >
                  <BookOpen size={16} />
                  <span>
                    {note.title}
                    <small>{note.subtitle}</small>
                  </span>
                </button>
              ))}
              {filteredProjectNotes.length === 0 && <p className="empty-inline">No project notes match this view.</p>}
            </>
          )}
          {notesScope === "thread" && (
            <>
              <div className="notes-scope-summary">
                <MessageSquare size={15} />
                <span>{threadNoteCountLabel}</span>
              </div>
              {filteredThreadNotes.map((note) => (
                <button
                  key={`${note.threadID}-${note.id}`}
                  className={cx("note-row", activeNoteTarget?.scope === "thread" && sameID(note.id, activeNoteTarget.noteID) && sameID(note.threadID, activeNoteTarget.threadID) && "active")}
                  onClick={() => onSelectThreadNoteItem(note)}
                >
                  <MessageSquare size={16} />
                  <span>
                    {note.title}
                    <small>{note.subtitle}</small>
                  </span>
                </button>
              ))}
              {filteredThreadNotes.length === 0 && <p className="empty-inline">No thread notes match this view.</p>}
            </>
          )}
        </aside>
        <section className="note-editor">
          {noteDetail ? (
            <article className="note-preview">
              <div className="note-preview-head">
                <div>
                  <h1>{noteDetail.title}</h1>
                  <small>{activeSourceLabel}</small>
                </div>
              </div>
              <MarkdownEditorSurface
                textareaRef={noteTextareaRef}
                value={noteDraft}
                onChange={onNoteDraft}
                placeholder={notesScope === "project" ? "Write your project note..." : "Write your thread note..."}
                sourcePath={noteDetail.path}
                saveStatusLabel={saveStatusLabel}
                saveStatusKind={noteSaveStatus.kind}
                onSave={onSaveNote}
                showSaveButton={noteSaveStatus.kind === "dirty" || noteSaveStatus.kind === "error"}
              />
            </article>
          ) : (
            <div className="empty-feature">
              <BookOpen size={34} />
              <h2>{notesScope === "project" ? "Project notes" : "Thread notes"}</h2>
              <p>{selectedProject ? "Select a note to browse or start a new project note." : "Choose a project first."}</p>
            </div>
          )}
        </section>
      </div>
    </main>
  );
}

function formatTranscriptTimestamp(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Saved transcript";
  return date.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit"
  });
}

function formatTranscriptRelative(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Saved";
  const diffSeconds = Math.round((date.getTime() - Date.now()) / 1000);
  const absolute = Math.abs(diffSeconds);
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: "auto", style: "short" });
  const units: Array<[Intl.RelativeTimeFormatUnit, number]> = [
    ["year", 60 * 60 * 24 * 365],
    ["month", 60 * 60 * 24 * 30],
    ["week", 60 * 60 * 24 * 7],
    ["day", 60 * 60 * 24],
    ["hour", 60 * 60],
    ["minute", 60],
    ["second", 1]
  ];
  const [unit, seconds] = units.find(([, seconds]) => absolute >= seconds) ?? ["second", 1];
  return formatter.format(Math.round(diffSeconds / seconds), unit);
}

function TranscriptHistoryView() {
  const [entries, setEntries] = useState<TranscriptHistoryEntry[]>([]);
  const [query, setQuery] = useState("");
  const [actionMessage, setActionMessage] = useState<string | null>(null);
  const [expandedIDs, setExpandedIDs] = useState<Set<string>>(() => new Set());
  const refreshHistory = async () => {
    const next = await window.openAssistElectron?.loadTranscriptHistory?.();
    setEntries(next ?? []);
  };
  useEffect(() => {
    void refreshHistory();
  }, []);
  const filteredEntries = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return entries;
    return entries.filter((entry) => entry.text.toLowerCase().includes(needle));
  }, [entries, query]);
  const copyEntry = async (entry: TranscriptHistoryEntry) => {
    await window.openAssistElectron?.writeClipboardText(entry.text);
    setActionMessage("Copied transcript.");
  };
  const pasteEntry = async (entry?: TranscriptHistoryEntry) => {
    const result = await window.openAssistElectron?.pasteTranscriptHistoryEntry?.(entry?.id);
    setActionMessage(result?.ok ? "Inserted transcript." : result?.error ?? "Could not insert transcript.");
  };
  const deleteEntry = async (entry: TranscriptHistoryEntry) => {
    const next = await window.openAssistElectron?.deleteTranscriptHistoryEntry?.(entry.id);
    setEntries(next ?? []);
    setExpandedIDs((current) => {
      const updated = new Set(current);
      updated.delete(entry.id);
      return updated;
    });
    setActionMessage("Deleted transcript.");
  };
  const clearAll = async () => {
    const next = await window.openAssistElectron?.clearTranscriptHistory?.();
    setEntries(next ?? []);
    setExpandedIDs(new Set());
    setActionMessage("History cleared.");
  };
  const toggleEntry = (id: string) => {
    setExpandedIDs((current) => {
      const updated = new Set(current);
      if (updated.has(id)) {
        updated.delete(id);
      } else {
        updated.add(id);
      }
      return updated;
    });
  };
  const hasEntries = entries.length > 0;
  const hasQuery = query.trim().length > 0;
  return (
    <main className="transcript-history-main">
      <section className="transcript-history-panel">
        <header className="transcript-history-header">
          <div className="transcript-history-title">
            <div className="feature-glyph gold">
              <HistoryIcon size={24} />
            </div>
            <div>
              <h1>Transcript History</h1>
              <p>Re-use recent voice capture without recording again.</p>
            </div>
          </div>
          <span className="transcript-history-count">
            {filteredEntries.length} of {entries.length}
          </span>
        </header>
        <div className="transcript-history-controls">
          <label className="search-field transcript-history-search">
            <Search size={16} />
            <input
              placeholder="Search transcripts"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
          </label>
          <button className="transcript-clear-button" disabled={!hasEntries} onClick={() => void clearAll()}>
            Clear All
          </button>
        </div>
        <p className={cx("transcript-action-message", !actionMessage && "empty")}>{actionMessage ?? ""}</p>

        {!hasEntries ? (
          <div className="transcript-history-empty">
            <HistoryIcon size={24} />
            <h2>No transcripts yet</h2>
            <p>Your recent voice captures will appear here automatically.</p>
          </div>
        ) : filteredEntries.length === 0 ? (
          <div className="transcript-history-empty">
            <Search size={24} />
            <h2>No matches found</h2>
            <p>{hasQuery ? "Try a different search phrase." : "Recent voice captures will appear here."}</p>
          </div>
        ) : (
          <div className="transcript-history-feed">
            {filteredEntries.map((entry, index) => {
              const expanded = expandedIDs.has(entry.id);
              const canExpand = entry.text.length > 220 || entry.text.includes("\n");
              return (
                <article className="transcript-history-card" key={entry.id}>
                  <div className="transcript-history-card-head">
                    <div className="transcript-history-card-time">
                      <strong>{formatTranscriptRelative(entry.createdAt)}</strong>
                      <span>{formatTranscriptTimestamp(entry.createdAt)}</span>
                    </div>
                    <div className="transcript-history-card-actions">
                      <IconButton label="Copy transcript" onClick={() => void copyEntry(entry)}>
                        <Copy size={15} />
                      </IconButton>
                      <IconButton label="Insert transcript" tone="gold" onClick={() => void pasteEntry(entry)}>
                        <ClipboardPaste size={15} />
                      </IconButton>
                      <IconButton label="Delete transcript" tone="danger" onClick={() => void deleteEntry(entry)}>
                        <Trash2 size={15} />
                      </IconButton>
                    </div>
                  </div>
                  <p className={cx("transcript-history-card-text", expanded && "expanded")}>
                    {entry.text}
                  </p>
                  {canExpand && (
                    <button className="transcript-expand-button" onClick={() => toggleEntry(entry.id)}>
                      {expanded ? "Show less" : "Show more"}
                    </button>
                  )}
                  {index < filteredEntries.length - 1 && <div className="transcript-history-divider" />}
                </article>
              );
            })}
          </div>
        )}
      </section>
    </main>
  );
}
function TranscriptHistoryWindow() {
  return (
    <div className="app-shell mode-dark theme-ocean chrome-glass-high-contrast transcript-history-window-shell">
      <div className="window-drag-strip" aria-hidden="true" />
      <TranscriptHistoryView />
    </div>
  );
}

function AutomationsView({
  automations,
  onToggle,
  onCreate
}: {
  automations: AutomationItem[];
  onToggle: (job: AutomationItem) => void;
  onCreate: (name: string, prompt: string) => Promise<void>;
}) {
  const [isCreating, setIsCreating] = useState(false);
  const [draftName, setDraftName] = useState("New scheduled job");
  const [draftPrompt, setDraftPrompt] = useState("");
  const canSave = draftName.trim().length > 0 && draftPrompt.trim().length > 0;
  const saveDraft = async () => {
    if (!canSave) return;
    await onCreate(draftName, draftPrompt);
    setDraftName("New scheduled job");
    setDraftPrompt("");
    setIsCreating(false);
  };

  return (
    <main className="split-feature-main">
      <section className="feature-list-column">
        <div className="feature-title-row">
          <div className="feature-glyph green">
            <CalendarClock size={24} />
          </div>
          <div>
            <h1>Automations</h1>
            <p>Create and manage recurring assistant jobs</p>
          </div>
        </div>
        <div className="list-label">
          <span>Jobs</span>
          <strong>{automations.length}</strong>
          <IconButton label="New scheduled job" tone="gold" onClick={() => setIsCreating(true)}>
            <Plus size={17} />
          </IconButton>
        </div>
        {automations.map((job) => (
          <button key={job.id} className="automation-row" onClick={() => onToggle(job)}>
            <span className="automation-icon">
              <Settings size={17} />
            </span>
            <span>
              {job.title}
              <small>{job.schedule}</small>
            </span>
            <span className={cx("toggle", job.enabled && "on")} />
          </button>
        ))}
      </section>
      <section className="feature-empty-column">
        {isCreating ? (
          <div className="automation-edit-panel">
            <div className="card-heading">
              <CalendarClock size={22} />
              <span>
                <strong>New scheduled job</strong>
                <small>Creates a real daily job in the native OpenAssist scheduled job store.</small>
              </span>
            </div>
            <label>
              Name
              <input value={draftName} onChange={(event) => setDraftName(event.target.value)} />
            </label>
            <label>
              Prompt
              <textarea
                value={draftPrompt}
                onChange={(event) => setDraftPrompt(event.target.value)}
                placeholder="What should Open Assist do on each run?"
              />
            </label>
            <div className="automation-edit-actions">
              <button onClick={() => setIsCreating(false)}>Cancel</button>
              <button className="primary-action" disabled={!canSave} onClick={() => void saveDraft()}>
                Save Job
              </button>
            </div>
            <p className="muted">Default schedule: daily at 9:00 AM. You can fine-tune it in the native scheduler.</p>
          </div>
        ) : (
          <div className="empty-feature">
            <CalendarClock size={42} />
            <h2>Select a job to edit</h2>
            <p>or tap + to create a new one</p>
          </div>
        )}
      </section>
    </main>
  );
}

function SkillsView({
  skills,
  onToggleSkill,
  onBack,
  onRefresh,
  onImportFolder,
  onImportGitHub,
  onCreateSkill
}: {
  skills: SkillItem[];
  onToggleSkill: (skill: SkillItem) => void;
  onBack: () => void;
  onRefresh: () => void;
  onImportFolder: () => Promise<void>;
  onImportGitHub: (reference: string) => Promise<void>;
  onCreateSkill: (name: string, description: string) => Promise<void>;
}) {
  const builtIn = skills.filter((skill) => skill.group === "built-in");
  const mine = skills.filter((skill) => skill.group === "my-skills");
  const imported = skills.filter((skill) => skill.group === "imported");
  const active = skills.filter((skill) => skill.attached);
  const [skillPanel, setSkillPanel] = useState<"github" | "new" | null>(null);
  const [githubReference, setGithubReference] = useState("");
  const [skillName, setSkillName] = useState("");
  const [skillDescription, setSkillDescription] = useState("");
  const canCreateSkill = skillName.trim().length > 0 && skillDescription.trim().length > 0;
  const importGitHub = async () => {
    const reference = githubReference.trim();
    if (!reference) return;
    await onImportGitHub(reference);
    setGithubReference("");
    setSkillPanel(null);
  };
  const createSkill = async () => {
    if (!canCreateSkill) return;
    await onCreateSkill(skillName, skillDescription);
    setSkillName("");
    setSkillDescription("");
    setSkillPanel(null);
  };
  return (
    <main className="catalog-main">
      <div className="catalog-header">
        <button className="back-button" onClick={onBack}>
          <ArrowLeft size={17} />
          Back
        </button>
        <div className="feature-glyph gold">
          <PackageCheck size={23} />
        </div>
        <div>
          <h1>Skills</h1>
          <p>Manage reusable skills for your threads</p>
        </div>
        <span className="flex-spacer" />
        <IconButton label="Refresh skills" onClick={onRefresh}>
          <RefreshCw size={17} />
        </IconButton>
      </div>
      <div className="catalog-actions">
        <button onClick={() => void onImportFolder()}>
          <Folder size={16} />
          Import Folder
        </button>
        <button onClick={() => setSkillPanel((value) => (value === "github" ? null : "github"))}>
          <GitBranch size={16} />
          Import GitHub
        </button>
        <button className="primary-action" onClick={() => setSkillPanel((value) => (value === "new" ? null : "new"))}>
          <Plus size={17} />
          New Skill
        </button>
      </div>
      {skillPanel === "github" && (
        <div className="skill-action-panel">
          <label>
            GitHub skill reference
            <input
              value={githubReference}
              onChange={(event) => setGithubReference(event.target.value)}
              placeholder="owner/repo/path or GitHub tree URL"
            />
          </label>
          <div className="automation-edit-actions">
            <button onClick={() => setSkillPanel(null)}>Cancel</button>
            <button className="primary-action" disabled={!githubReference.trim()} onClick={() => void importGitHub()}>
              Import
            </button>
          </div>
        </div>
      )}
      {skillPanel === "new" && (
        <div className="skill-action-panel">
          <label>
            Skill name
            <input value={skillName} onChange={(event) => setSkillName(event.target.value)} placeholder="my-repeatable-workflow" />
          </label>
          <label>
            Description
            <textarea
              value={skillDescription}
              onChange={(event) => setSkillDescription(event.target.value)}
              placeholder="When should Open Assist use this skill?"
            />
          </label>
          <div className="automation-edit-actions">
            <button onClick={() => setSkillPanel(null)}>Cancel</button>
            <button className="primary-action" disabled={!canCreateSkill} onClick={() => void createSkill()}>
              Create
            </button>
          </div>
        </div>
      )}
      <CatalogSkillGroup title="Active on this thread" countLabel={String(active.length)} items={active} empty="No skills attached to this thread yet." onToggleSkill={onToggleSkill} />
      <CatalogSkillGroup title="Built-in" countLabel={String(builtIn.length)} items={builtIn} onToggleSkill={onToggleSkill} />
      <CatalogSkillGroup title="My Skills" countLabel={String(mine.length)} items={mine} onToggleSkill={onToggleSkill} />
      <CatalogSkillGroup title="Plugin Skills" countLabel={String(imported.length)} items={imported} onToggleSkill={onToggleSkill} />
    </main>
  );
}

function CatalogSkillGroup({
  title,
  countLabel,
  items,
  empty,
  onToggleSkill
}: {
  title: string;
  countLabel: string;
  items: SkillItem[];
  empty?: string;
  onToggleSkill: (skill: SkillItem) => void;
}) {
  return (
    <section className="catalog-group">
      <h2>
        {title} <span>{countLabel}</span>
      </h2>
      {items.length === 0 && empty ? (
        <p className="empty-inline">{empty}</p>
      ) : (
        items.map((skill) => (
          <div key={skill.id} className="skill-row">
            <SkillTile skill={skill} />
            <div className="skill-row-copy">
              <strong>{skill.title}</strong>
              <p>{skill.description}</p>
            </div>
            <button className={cx("attach-button", skill.attached && "is-attached")} onClick={() => onToggleSkill(skill)}>
              {skill.attached ? "Attached" : "Attach"}
            </button>
          </div>
        ))
      )}
    </section>
  );
}

const skillTilePalette = [
  { background: "linear-gradient(135deg, #4f6bff, #7a93ff)", color: "#eaf0ff" },
  { background: "linear-gradient(135deg, #ff6b6b, #ff9b6b)", color: "#fff2e8" },
  { background: "linear-gradient(135deg, #34c38f, #5cd6b0)", color: "#e6fbf3" },
  { background: "linear-gradient(135deg, #d27dff, #b15cff)", color: "#f7eaff" },
  { background: "linear-gradient(135deg, #ffba47, #ff8a3d)", color: "#fff3df" },
  { background: "linear-gradient(135deg, #1ea8c1, #45c8d8)", color: "#e6fafd" },
  { background: "linear-gradient(135deg, #e25c8a, #ff8db3)", color: "#ffe9f1" },
  { background: "linear-gradient(135deg, #6a8eff, #4f6bff)", color: "#e9efff" },
  { background: "linear-gradient(135deg, #ffce4d, #ffb422)", color: "#3a2902" }
];

function pickSkillPaletteIndex(seed: string) {
  let hash = 0;
  for (let i = 0; i < seed.length; i += 1) {
    hash = (hash * 31 + seed.charCodeAt(i)) | 0;
  }
  return Math.abs(hash) % skillTilePalette.length;
}

function SkillTile({ skill }: { skill: SkillItem }) {
  if (skill.iconPath) {
    return (
      <div className="skill-icon has-image">
        <CatalogIcon src={skill.iconPath} kind="skill" fallback={<Sparkles size={20} />} />
      </div>
    );
  }
  const seed = (skill.id || skill.title || "skill").toLowerCase();
  const letter = ((skill.title || skill.id || "S").trim()[0] || "S").toUpperCase();
  const palette = skillTilePalette[pickSkillPaletteIndex(seed)];
  return (
    <div
      className="skill-icon skill-icon-letter"
      style={{ background: palette.background, color: palette.color }}
    >
      <span>{letter}</span>
    </div>
  );
}

function PluginLogo({ plugin, large = false }: { plugin: PluginItem; large?: boolean }) {
  const fallbackLetter = (plugin.title || plugin.pluginName || "P").trim().slice(0, 1).toUpperCase() || "P";
  return (
    <span className={cx("plugin-logo", large && "large", plugin.logoPath && "has-image", plugin.id)}>
      <CatalogIcon
        src={plugin.logoPath}
        kind="plugin"
        fallback={<span className="plugin-logo-letter">{fallbackLetter}</span>}
        fallbackSize={large ? 24 : 17}
      />
    </span>
  );
}

function PluginsView({
  plugins,
  selectedPluginID,
  selectedPluginIDs,
  onSelectPlugin,
  onTogglePluginUse,
  onUseStarterPrompt,
  onOpenChat,
  onBack,
  onRefresh
}: {
  plugins: PluginItem[];
  selectedPluginID?: string;
  selectedPluginIDs: string[];
  onSelectPlugin: (pluginID: string) => void;
  onTogglePluginUse: (pluginID: string) => void;
  onUseStarterPrompt: (pluginID: string, prompt: string) => void;
  onOpenChat: () => void;
  onBack: () => void;
  onRefresh: () => void;
}) {
  const [pluginFilter, setPluginFilter] = useState<"All" | PluginItem["status"]>("All");
  const [pluginSearch, setPluginSearch] = useState("");
  const selected = plugins.find((plugin) => plugin.id === selectedPluginID) ?? plugins.find((plugin) => plugin.selected) ?? plugins[0];
  const [pluginLimit, setPluginLimit] = useState(48);
  const filteredPlugins = useMemo(() => {
    const query = pluginSearch.trim().toLowerCase();
    return plugins.filter((plugin) => {
      const matchesFilter = pluginFilter === "All" || plugin.status === pluginFilter;
      if (!matchesFilter) return false;
      if (!query) return true;
      return [
        plugin.title,
        plugin.description,
        plugin.pluginName,
        plugin.marketplaceName,
        plugin.marketplacePath,
        ...(plugin.appNames ?? [])
      ].filter(Boolean).some((value) => String(value).toLowerCase().includes(query));
    });
  }, [pluginFilter, pluginSearch, plugins]);
  const visiblePlugins = useMemo(() => {
    const firstPage = filteredPlugins.slice(0, pluginLimit);
    if (!selected || firstPage.some((plugin) => plugin.id === selected.id)) return firstPage;
    if (pluginFilter !== "All" && selected.status !== pluginFilter) return firstPage;
    return [selected, ...firstPage.slice(0, Math.max(0, pluginLimit - 1))];
  }, [filteredPlugins, pluginFilter, pluginLimit, selected]);
  const hasMorePlugins = visiblePlugins.length < filteredPlugins.length;
  const choosePluginFilter = (filter: "All" | PluginItem["status"]) => {
    setPluginFilter(filter);
    setPluginLimit(48);
  };

  if (!selected) {
    return (
      <main className="plugins-main">
        <section className="plugin-browser">
          <div className="catalog-header compact-header">
            <div>
              <h1>Plugins</h1>
              <p>No Codex plugins were found on this Mac.</p>
            </div>
          </div>
        </section>
      </main>
    );
  }
  return (
    <main className="plugins-main">
      <section className="plugin-browser">
        <div className="catalog-header compact-header">
          <button className="back-button" onClick={onBack}>
            <ArrowLeft size={17} />
            Back
          </button>
          <div>
            <h1>Plugins</h1>
            <p>Browse Codex plugins, install them, and check what still needs setup.</p>
          </div>
          <span className="flex-spacer" />
          <IconButton label="Refresh plugins" onClick={onRefresh}>
            <RefreshCw size={17} />
          </IconButton>
        </div>
        <label className="search-field wide">
          <Search size={16} />
          <input
            placeholder="Search plugins"
            value={pluginSearch}
            onChange={(event) => {
              setPluginSearch(event.target.value);
              setPluginLimit(48);
            }}
          />
        </label>
        <div className="segmented plugin-filter">
          {(["All", "Installed", "Available", "Needs Setup"] as const).map((filter) => (
            <button
              key={filter}
              className={cx(pluginFilter === filter && "selected")}
              onClick={() => choosePluginFilter(filter)}
            >
              {filter}
            </button>
          ))}
        </div>
        <div className="plugin-list">
          {visiblePlugins.map((plugin) => (
            <button
              key={plugin.id}
              className={cx("plugin-row", (plugin.id === selected.id || selectedPluginIDs.includes(plugin.id)) && "active")}
              onClick={() => onSelectPlugin(plugin.id)}
            >
              <PluginLogo plugin={plugin} />
              <span>
                <strong>{plugin.title}</strong>
                <small>{plugin.marketplaceName || "Codex official"}</small>
                <em>{plugin.description}</em>
              </span>
              <b>{selectedPluginIDs.includes(plugin.id) ? "In Chat" : plugin.status}</b>
            </button>
          ))}
          {hasMorePlugins && (
            <button className="plugin-row show-more-row" onClick={() => setPluginLimit((value) => Math.min(value + 48, filteredPlugins.length))}>
              <span className="plugin-logo more">+</span>
              <span>
                <strong>Show more plugins</strong>
                <small>{visiblePlugins.length}/{filteredPlugins.length}</small>
                <em>Load the next page</em>
              </span>
              <b>More</b>
            </button>
          )}
          {filteredPlugins.length === 0 && (
            <div className="empty-inline">No plugins match this filter.</div>
          )}
        </div>
      </section>
      <section className="plugin-detail">
        <header className="plugin-detail-head">
          <PluginLogo plugin={selected} large />
          <div className="plugin-detail-head-copy">
            <h1>{selected.title}</h1>
            <p className="plugin-detail-tagline">{selected.description}</p>
            <small>Codex official</small>
          </div>
          <div className="detail-actions">
            <button className="primary-action" onClick={() => onTogglePluginUse(selected.id)}>
              {selectedPluginIDs.includes(selected.id) ? "Remove from Chat" : "Use in Chat"}
            </button>
            <button onClick={onOpenChat}>Open Chat</button>
          </div>
        </header>
        <span className="status-badge">{selected.status}</span>
        <div className="plugin-detail-body">
          <section className="plugin-detail-section">
            <h2>Description</h2>
            <p>{selected.description}</p>
          </section>
          <section className="plugin-detail-section">
            <h2>Apps</h2>
            <p>
              {selected.title}
              <br />
              <span className="muted">Ready</span>
            </p>
          </section>
          <section className="plugin-detail-section">
            <h2>Starter Prompts</h2>
            <button className="prompt-button" onClick={() => onUseStarterPrompt(selected.id, `Use ${selected.title} to help with this task`)}>
              Use {selected.title} to help with this task
            </button>
          </section>
        </div>
      </section>
    </main>
  );
}

function SettingsView({
  initialSection,
  onOpenAssistant,
  onOpenTarget,
  onRefresh,
  onSaveTelegramBotToken,
  onClearTelegramBotToken,
  onApproveTelegramPairing,
  onDeclineTelegramPairing,
  onForgetTelegramPairing,
  onTestTelegramConnection,
  onSavePromptRewriteAPIKey,
  onClearPromptRewriteAPIKey,
  onSaveCloudTranscriptionAPIKey,
  onClearCloudTranscriptionAPIKey,
  onSaveRealtimeOpenAIAPIKey,
  onClearRealtimeOpenAIAPIKey,
  onUpdateSetting,
  onUpdateShortcut,
  settings
}: {
  initialSection?: SettingsKey;
  onOpenAssistant: () => void;
  onOpenTarget: (target: string) => Promise<{ ok: boolean; path?: string; error?: string } | undefined>;
  onRefresh: () => void;
  onSaveTelegramBotToken: (token: string) => Promise<SettingsSnapshot | undefined>;
  onClearTelegramBotToken: () => Promise<SettingsSnapshot | undefined>;
  onApproveTelegramPairing: () => Promise<SettingsSnapshot | undefined>;
  onDeclineTelegramPairing: () => Promise<SettingsSnapshot | undefined>;
  onForgetTelegramPairing: () => Promise<SettingsSnapshot | undefined>;
  onTestTelegramConnection: (token?: string) => Promise<{ ok: boolean; username?: string; message: string } | undefined>;
  onSavePromptRewriteAPIKey: (provider: string, token: string) => Promise<SettingsSnapshot | undefined>;
  onClearPromptRewriteAPIKey: (provider: string) => Promise<SettingsSnapshot | undefined>;
  onSaveCloudTranscriptionAPIKey: (provider: string, token: string) => Promise<SettingsSnapshot | undefined>;
  onClearCloudTranscriptionAPIKey: (provider: string) => Promise<SettingsSnapshot | undefined>;
  onSaveRealtimeOpenAIAPIKey: (token: string) => Promise<SettingsSnapshot | undefined>;
  onClearRealtimeOpenAIAPIKey: () => Promise<SettingsSnapshot | undefined>;
  onUpdateSetting: (key: SettingsUpdateKey, value: SettingsUpdateValue) => void;
  onUpdateShortcut: (target: ShortcutTarget, keyCode: number, modifiers: number) => Promise<SettingsSnapshot | undefined>;
  settings?: SettingsSnapshot;
}) {
  const [section, setSection] = useState<SettingsKey>(initialSection ?? "assistant");
  const [settingsSearch, setSettingsSearch] = useState("");
  useEffect(() => {
    if (initialSection) setSection(initialSection);
  }, [initialSection]);
  const filteredSections = useMemo(() => {
    const query = settingsSearch.trim().toLowerCase();
    if (!query) return settingsSections;
    return settingsSections.filter((item) =>
      [item.title, item.subtitle].some((value) => value.toLowerCase().includes(query))
    );
  }, [settingsSearch]);
  const current = settingsSections.find((item) => item.id === section) ?? settingsSections[0];
  const versionLabel = `Version ${settings?.appVersion || "1.0.7"} (${settings?.buildNumber || "69"})`;
  return (
    <main className="settings-window">
      <aside className="settings-sidebar">
        <div className="traffic-spacer" />
        <div className="settings-brand">
          <AppMark />
          <span>
            Open Assist
            <small>Settings</small>
          </span>
        </div>
        <label className="search-field settings-search">
          <Search size={16} />
          <input
            placeholder="Search settings"
            value={settingsSearch}
            onChange={(event) => setSettingsSearch(event.target.value)}
          />
        </label>
        <nav className="settings-nav">
          {filteredSections.map((item) => (
            <button key={item.id} className={cx(section === item.id && "active")} onClick={() => setSection(item.id)}>
              {item.title}
            </button>
          ))}
          {filteredSections.length === 0 && <span className="settings-empty">No settings match</span>}
        </nav>
        <div className="status-card settings-update">
          <CheckCircle2 size={18} />
          <span>
            App Is Up to Date
            <small>{versionLabel}</small>
          </span>
          <button onClick={onRefresh}>Check Now</button>
        </div>
      </aside>
      <section className="settings-content">
        <header>
          <h1>{current.title}</h1>
          <p>{current.subtitle}</p>
        </header>
        <SettingsContent
          section={section}
          onOpenAssistant={onOpenAssistant}
          onOpenTarget={onOpenTarget}
          onSaveTelegramBotToken={onSaveTelegramBotToken}
          onClearTelegramBotToken={onClearTelegramBotToken}
          onApproveTelegramPairing={onApproveTelegramPairing}
          onDeclineTelegramPairing={onDeclineTelegramPairing}
          onForgetTelegramPairing={onForgetTelegramPairing}
          onTestTelegramConnection={onTestTelegramConnection}
          onSavePromptRewriteAPIKey={onSavePromptRewriteAPIKey}
          onClearPromptRewriteAPIKey={onClearPromptRewriteAPIKey}
          onSaveCloudTranscriptionAPIKey={onSaveCloudTranscriptionAPIKey}
          onClearCloudTranscriptionAPIKey={onClearCloudTranscriptionAPIKey}
          onSaveRealtimeOpenAIAPIKey={onSaveRealtimeOpenAIAPIKey}
          onClearRealtimeOpenAIAPIKey={onClearRealtimeOpenAIAPIKey}
          onRefresh={onRefresh}
          onUpdateSetting={onUpdateSetting}
          onUpdateShortcut={onUpdateShortcut}
          settings={settings}
        />
      </section>
    </main>
  );
}

function SettingsContent({
  section,
  onOpenAssistant,
  onOpenTarget,
  onSaveTelegramBotToken,
  onClearTelegramBotToken,
  onApproveTelegramPairing,
  onDeclineTelegramPairing,
  onForgetTelegramPairing,
  onTestTelegramConnection,
  onSavePromptRewriteAPIKey,
  onClearPromptRewriteAPIKey,
  onSaveCloudTranscriptionAPIKey,
  onClearCloudTranscriptionAPIKey,
  onSaveRealtimeOpenAIAPIKey,
  onClearRealtimeOpenAIAPIKey,
  onRefresh,
  onUpdateSetting,
  onUpdateShortcut,
  settings
}: {
  section: SettingsKey;
  onOpenAssistant: () => void;
  onOpenTarget: (target: string) => Promise<{ ok: boolean; path?: string; error?: string } | undefined>;
  onSaveTelegramBotToken: (token: string) => Promise<SettingsSnapshot | undefined>;
  onClearTelegramBotToken: () => Promise<SettingsSnapshot | undefined>;
  onApproveTelegramPairing: () => Promise<SettingsSnapshot | undefined>;
  onDeclineTelegramPairing: () => Promise<SettingsSnapshot | undefined>;
  onForgetTelegramPairing: () => Promise<SettingsSnapshot | undefined>;
  onTestTelegramConnection: (token?: string) => Promise<{ ok: boolean; username?: string; message: string } | undefined>;
  onSavePromptRewriteAPIKey: (provider: string, token: string) => Promise<SettingsSnapshot | undefined>;
  onClearPromptRewriteAPIKey: (provider: string) => Promise<SettingsSnapshot | undefined>;
  onSaveCloudTranscriptionAPIKey: (provider: string, token: string) => Promise<SettingsSnapshot | undefined>;
  onClearCloudTranscriptionAPIKey: (provider: string) => Promise<SettingsSnapshot | undefined>;
  onSaveRealtimeOpenAIAPIKey: (token: string) => Promise<SettingsSnapshot | undefined>;
  onClearRealtimeOpenAIAPIKey: () => Promise<SettingsSnapshot | undefined>;
  onRefresh: () => void;
  onUpdateSetting: (key: SettingsUpdateKey, value: SettingsUpdateValue) => void;
  onUpdateShortcut: (target: ShortcutTarget, keyCode: number, modifiers: number) => Promise<SettingsSnapshot | undefined>;
  settings?: SettingsSnapshot;
}) {
  const [telegramBotTokenDraft, setTelegramBotTokenDraft] = useState(settings?.telegramBotToken ?? "");
  const [promptRewriteAPIKeyDraft, setPromptRewriteAPIKeyDraft] = useState("");
  const [cloudTranscriptionAPIKeyDraft, setCloudTranscriptionAPIKeyDraft] = useState("");
  const [realtimeAPIKeyDraft, setRealtimeAPIKeyDraft] = useState("");
  const [providerActionMessage, setProviderActionMessage] = useState<string | undefined>(undefined);
  const [telegramActionMessage, setTelegramActionMessage] = useState<string | undefined>(undefined);
  const [appearanceStatus, setAppearanceStatus] = useState("");
  const [pendingColorTheme, setPendingColorTheme] = useState<string | null>(null);
  const [isSavingTheme, setIsSavingTheme] = useState(false);
  const [assistantVoiceActionMessage, setAssistantVoiceActionMessage] = useState<string | undefined>(undefined);
  const [installingKokoroVoice, setInstallingKokoroVoice] = useState(false);
  const [screenSnipPresets, setScreenSnipPresets] = useState<Array<{ key: string; label: string; colors: string[] }>>([]);
  const [screenSnipTheme, setScreenSnipTheme] = useState<string>("prism");

  useEffect(() => {
    const electron = (window as any).openAssistElectron;
    if (!electron?.listScreenSnipPresets) return;
    let cancelled = false;
    electron.listScreenSnipPresets().then((response: { presets?: Array<{ key: string; label: string; colors: string[] }>; selected?: string }) => {
      if (cancelled) return;
      if (response?.presets) setScreenSnipPresets(response.presets);
      if (response?.selected) setScreenSnipTheme(response.selected);
    }).catch(() => {});
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    setTelegramBotTokenDraft(settings?.telegramBotToken ?? "");
  }, [settings?.telegramBotToken]);

  useEffect(() => {
    setPromptRewriteAPIKeyDraft("");
  }, [settings?.promptRewriteProvider]);

  useEffect(() => {
    setCloudTranscriptionAPIKeyDraft("");
  }, [settings?.cloudTranscriptionProvider]);

  useEffect(() => {
    setProviderActionMessage(undefined);
    setTelegramActionMessage(undefined);
    setAppearanceStatus("");
    setAssistantVoiceActionMessage(undefined);
  }, [section]);

  const microphones = settings?.availableMicrophones ?? [];
  const defaultMicrophone = microphones.find((microphone) => microphone.isDefault);
  const microphoneOptions = [
    {
      value: "",
      label: defaultMicrophone ? `System Default (${defaultMicrophone.name})` : "System Default"
    },
    ...microphones.map((microphone) => ({
      value: microphone.uid,
      label: microphone.isDefault ? `${microphone.name} (current default)` : microphone.name
    }))
  ];

  const pasteProviderKey = async (setter: (value: string) => void) => {
    const text = (await window.openAssistElectron?.readClipboardText?.())?.trim() ?? "";
    if (!text) {
      setProviderActionMessage("Clipboard is empty.");
      return;
    }
    setter(text);
    setProviderActionMessage("Key pasted. Click Save Key.");
  };

  const playSoundPreview = (cue: "startListening" | "stopListening" | "processing" | "pasted" | "correctionLearned") => {
    void window.openAssistElectron?.playDictationFeedbackSound?.(cue);
  };

  const installKokoroVoice = async () => {
    if (installingKokoroVoice) return;
    setInstallingKokoroVoice(true);
    setAssistantVoiceActionMessage("Installing Kokoro locally. The first download can take a little while.");
    try {
      await window.openAssistElectron?.installKokoroVoiceModel?.(settings?.kokoroVoice || "af_heart");
      setAssistantVoiceActionMessage("Kokoro Local Voice is installed and ready.");
      onRefresh();
    } catch (error) {
      setAssistantVoiceActionMessage(error instanceof Error ? error.message : "Could not install Kokoro Local Voice.");
    } finally {
      setInstallingKokoroVoice(false);
    }
  };

  const testAssistantVoiceOutput = async () => {
    setAssistantVoiceActionMessage("Testing assistant voice output...");
    try {
      const result = await window.openAssistElectron?.speakAssistantResponse?.(
        "Open Assist voice output is ready.",
        { force: true }
      );
      if (result?.ok) {
        setAssistantVoiceActionMessage(result.skipped ? result.reason : "Voice output played.");
      } else {
        setAssistantVoiceActionMessage(result?.error || "Voice output failed.");
      }
    } catch (error) {
      setAssistantVoiceActionMessage(error instanceof Error ? error.message : "Voice output failed.");
    }
  };

  if (section === "assistant") {
    return (
      <div className="settings-stack single" key="assistant">
        <div className="settings-card">
          <div className="card-heading">
            <Bot size={22} />
            <span>
              <strong>Assistant Status</strong>
              <small>Main assistant switch and current runtime summary.</small>
            </span>
          </div>
          <p className="account-line">
            <UserCircle size={15} /> {providerLabel(settings?.assistantBackend || "codex")} · {settings?.model || "Default model"}
          </p>
          <Checkbox
            checked={settings?.assistantEnabled ?? true}
            label="Enable assistant"
            onToggle={() => onUpdateSetting("assistantEnabled", !(settings?.assistantEnabled ?? true))}
          />
          <button className="gold-action" onClick={onOpenAssistant}>
            Open Assistant
          </button>
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <PanelLeftClose size={22} />
            <span>
              <strong>Sidebar Mode & Style</strong>
              <small>Controls for the compact assistant window layout.</small>
            </span>
          </div>
          <FieldLabel label="Compact assistant style">
            <div className="segmented">
              <button disabled title="Orb mode is still handled by native OpenAssist.">Orb</button>
              <button disabled title="Notch mode is still handled by native OpenAssist.">Notch</button>
              <button className={cx((settings?.compactStyle ?? "sidebar") === "sidebar" && "selected")} onClick={() => onUpdateSetting("compactStyle", "sidebar")}>Sidebar</button>
            </div>
          </FieldLabel>
          <FieldLabel label="Sidebar edge">
            <div className="segmented narrow">
              <button className={cx(settings?.compactEdge === "left" && "selected")} onClick={() => onUpdateSetting("compactEdge", "left")}>Left</button>
              <button className={cx((settings?.compactEdge ?? "right") === "right" && "selected")} onClick={() => onUpdateSetting("compactEdge", "right")}>Right</button>
            </div>
          </FieldLabel>
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <GitBranch size={22} />
            <span>
              <strong>Code Tracking</strong>
              <small>Watch local repositories for changed files while the assistant works.</small>
            </span>
          </div>
          <Checkbox
            checked={settings?.assistantTrackCodeChangesInGitRepos ?? true}
            label="Track code changes in Git repositories"
            onToggle={() => onUpdateSetting("assistantTrackCodeChangesInGitRepos", !(settings?.assistantTrackCodeChangesInGitRepos ?? true))}
          />
        </div>
      </div>
    );
  }

  if (section === "voice") {
    const cloudTranscriptionProvider = settings?.cloudTranscriptionProvider || "OpenAI";
    const cloudTranscriptionNeedsKey = cloudTranscriptionProvider !== "ChatGPT / Codex Session";
    const installedWhisperModels = settings?.whisperInstalledModels ?? [];
    const installedWhisperModelsLabel = installedWhisperModels.length
      ? installedWhisperModels.join(", ")
      : "No local model installed";

    return (
      <div className="settings-stack single" key="voice">
        <div className="settings-card">
          <div className="card-heading">
            <Mic size={22} />
            <span>
              <strong>Microphone & Voice Input</strong>
              <small>Control microphone input, dictation entry, and continuous voice behavior.</small>
            </span>
          </div>
          <Checkbox
            checked={settings?.voiceEnabled ?? true}
            label="Enable voice task entry"
            onToggle={() => onUpdateSetting("voiceEnabled", !(settings?.voiceEnabled ?? true))}
          />
          <Checkbox
            checked={settings?.assistantFloatingHUDEnabled ?? true}
            label="Show waveform while listening"
            onToggle={() => onUpdateSetting("assistantFloatingHUDEnabled", !(settings?.assistantFloatingHUDEnabled ?? true))}
          />
          <Checkbox
            checked={settings?.autoDetectMicrophone ?? true}
            label="Auto-detect microphone"
            onToggle={() => onUpdateSetting("autoDetectMicrophone", !(settings?.autoDetectMicrophone ?? true))}
          />
          <SettingsSelect
            label="Input device"
            value={(settings?.autoDetectMicrophone ?? true) ? "" : settings?.selectedMicrophoneUID || ""}
            options={microphoneOptions}
            disabled={settings?.autoDetectMicrophone ?? true}
            onChange={(value) => onUpdateSetting("selectedMicrophoneUID", value)}
          />
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <RealtimeVoiceMark size={23} />
            <span>
              <strong>Codex Realtime Voice</strong>
              <small>Uses your saved OpenAI key, with an optional realtime override.</small>
            </span>
          </div>
          <Checkbox
            checked={settings?.realtimeVoiceEnabled ?? true}
            label="Enable Codex Live Realtime Voice"
            onToggle={() => onUpdateSetting("realtimeVoiceEnabled", !(settings?.realtimeVoiceEnabled ?? true))}
          />
          <SettingsSelect
            label="Realtime model"
            value={settings?.realtimeOpenAIModel || "gpt-realtime-mini"}
            options={realtimeOpenAIModelOptions}
            onChange={(value) => onUpdateSetting("realtimeOpenAIModel", value || "gpt-realtime-mini")}
          />
          <SettingsSelect
            label="Realtime voice"
            value={settings?.realtimeOpenAIVoice || "marin"}
            options={realtimeOpenAIVoiceOptions}
            onChange={(value) => onUpdateSetting("realtimeOpenAIVoice", value || "marin")}
          />
          <div className="secure-field provider-credential-box">
            <span>
              <strong>Optional realtime override key</strong>
              <small>{settings?.realtimeMaskedOpenAIAPIKey || "Not configured"}</small>
            </span>
            <input
              type="password"
              value={realtimeAPIKeyDraft}
              placeholder="Paste only if realtime should use a different OpenAI key"
              autoComplete="off"
              spellCheck={false}
              onChange={(event) => setRealtimeAPIKeyDraft(event.target.value)}
            />
            <div className="inline-actions">
              <button onClick={() => void pasteProviderKey(setRealtimeAPIKeyDraft)}>
                Paste
              </button>
              <button
                className="gold-action"
                disabled={!realtimeAPIKeyDraft.trim()}
                onClick={() => {
                  void onSaveRealtimeOpenAIAPIKey(realtimeAPIKeyDraft).then(() => {
                    setRealtimeAPIKeyDraft("");
                    setProviderActionMessage("Realtime key saved.");
                  });
                }}
              >
                Save Key
              </button>
              <button
                disabled={!(settings?.realtimeDedicatedOpenAIAPIKeyConfigured ?? false)}
                onClick={() => {
                  void onClearRealtimeOpenAIAPIKey().then(() => {
                    setRealtimeAPIKeyDraft("");
                    setProviderActionMessage("Realtime override key cleared.");
                  });
                }}
              >
                Clear
              </button>
            </div>
          </div>
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <Volume2 size={22} />
            <span>
              <strong>Dictation Audio Feedback</strong>
              <small>Configure sound cues when starting, stopping, or finishing voice tasks.</small>
            </span>
          </div>
          {dictationSoundRows.map((row) => (
            <div className="sound-setting-row" key={row.key}>
              <SettingsSelect
                label={row.label}
                value={String(settings?.[row.key as keyof SettingsSnapshot] ?? "None")}
                options={dictationSoundOptions}
                onChange={(value) => onUpdateSetting(row.key, value)}
              />
              <button type="button" onClick={() => playSoundPreview(row.cue)}>
                Test
              </button>
            </div>
          ))}
          <SettingsVolumeRow
            label="Feedback volume"
            value={settings?.dictationFeedbackVolume ?? 0.10}
            onChange={(value) => onUpdateSetting("dictationFeedbackVolume", Number(value.toFixed(2)))}
          />
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <WandSparkles size={22} />
            <span>
              <strong>Speech-to-Text Transcription</strong>
              <small>Configure the model and API endpoint for transcribing your voice.</small>
            </span>
          </div>
          <SettingsSelect
            label="Transcription engine"
            value={settings?.transcriptionEngine || "Apple Speech"}
            options={transcriptionEngineOptions}
            onChange={(value) => onUpdateSetting("transcriptionEngine", value)}
          />
          <SettingsSelect
            label="Cloud provider"
            value={cloudTranscriptionProvider}
            options={cloudTranscriptionProviderOptions}
            onChange={(value) => onUpdateSetting("cloudTranscriptionProvider", value)}
          />
          <SettingsTextInput
            label="Cloud model"
            value={settings?.cloudTranscriptionModel || ""}
            onCommit={(value) => onUpdateSetting("cloudTranscriptionModel", value)}
          />
          <SettingsTextInput
            label="Cloud base URL"
            value={settings?.cloudTranscriptionBaseURL || ""}
            onCommit={(value) => onUpdateSetting("cloudTranscriptionBaseURL", value)}
          />
          <div className="secure-field provider-credential-box">
            <span>
              <strong>Cloud transcription API key</strong>
              <small>{settings?.cloudTranscriptionMaskedAPIKey || "Not configured"}</small>
            </span>
            <input
              type="password"
              value={cloudTranscriptionAPIKeyDraft}
              disabled={!cloudTranscriptionNeedsKey}
              placeholder={cloudTranscriptionNeedsKey ? `Paste ${cloudTranscriptionProvider} key` : "Uses your Codex session"}
              autoComplete="off"
              spellCheck={false}
              onChange={(event) => setCloudTranscriptionAPIKeyDraft(event.target.value)}
            />
            <div className="inline-actions">
              <button
                disabled={!cloudTranscriptionNeedsKey}
                onClick={() => void pasteProviderKey(setCloudTranscriptionAPIKeyDraft)}
              >
                Paste
              </button>
              <button
                className="gold-action"
                disabled={!cloudTranscriptionNeedsKey || !cloudTranscriptionAPIKeyDraft.trim()}
                onClick={() => {
                  void onSaveCloudTranscriptionAPIKey(cloudTranscriptionProvider, cloudTranscriptionAPIKeyDraft).then(() => {
                    setCloudTranscriptionAPIKeyDraft("");
                    setProviderActionMessage("Cloud transcription key saved.");
                  });
                }}
              >
                Save Key
              </button>
              <button
                disabled={!cloudTranscriptionNeedsKey || !(settings?.cloudTranscriptionAPIKeyConfigured ?? false)}
                onClick={() => {
                  void onClearCloudTranscriptionAPIKey(cloudTranscriptionProvider).then(() => {
                    setCloudTranscriptionAPIKeyDraft("");
                    setProviderActionMessage("Cloud transcription key cleared.");
                  });
                }}
              >
                Clear
              </button>
            </div>
            {providerActionMessage && <p className="ready-line">{providerActionMessage}</p>}
          </div>
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <Cpu size={22} />
            <span>
              <strong>Whisper Local Model</strong>
              <small>Options for offline local speech-to-text processing.</small>
            </span>
          </div>
          <SettingsSelect
            label="Whisper model"
            value={settings?.whisperModel || "base.en"}
            options={whisperModelOptions}
            onChange={(value) => onUpdateSetting("whisperModel", value)}
          />
          <SelectRow
            label="Installed whisper models"
            value={installedWhisperModelsLabel}
            tone={settings?.whisperModelInstalled ? "ready" : "muted"}
          />
          <Checkbox
            checked={settings?.whisperUseCoreML ?? true}
            label="Use Core ML encoder when available"
            onToggle={() => onUpdateSetting("whisperUseCoreML", !(settings?.whisperUseCoreML ?? true))}
          />
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <WandSparkles size={22} />
            <span>
              <strong>Text Correction Quality</strong>
              <small>Learn corrections and clean filler words during speech entry.</small>
            </span>
          </div>
          <Checkbox checked label="Clean up filler words" />
          <Checkbox checked label="Learn adaptive corrections" />
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <Volume2 size={22} />
            <span>
              <strong>Voice Reply Output</strong>
              <small>Dictation output and synthesized speech configuration.</small>
            </span>
          </div>
          <Checkbox
            checked={settings?.assistantVoiceOutputEnabled ?? false}
            label="Enable assistant reply voice output"
            onToggle={() => onUpdateSetting("assistantVoiceOutputEnabled", !(settings?.assistantVoiceOutputEnabled ?? false))}
          />
          <SettingsSelect
            label="Voice engine"
            value={settings?.voiceEngine || "humeOctave"}
            options={assistantVoiceEngineOptions}
            onChange={(value) => onUpdateSetting("voiceEngine", value)}
          />
          {(settings?.voiceEngine || "humeOctave") === "kokoroLocal" && (
            <>
              <SettingsSelect
                label="Kokoro voice"
                value={settings?.kokoroVoice || "af_heart"}
                options={kokoroVoiceOptions}
                onChange={(value) => onUpdateSetting("kokoroVoice", value)}
              />
              <SelectRow
                label="Kokoro local model"
                value={settings?.kokoroModelInstalled ? "Installed" : "Not installed"}
                tone={settings?.kokoroModelInstalled ? "ready" : "muted"}
              />
              <small>{settings?.kokoroModelDetail || "Install the local model before using Kokoro reply voice."}</small>
              <div className="settings-action-row">
                <button
                  className="gold-action"
                  disabled={installingKokoroVoice}
                  onClick={() => void installKokoroVoice()}
                >
                  {installingKokoroVoice ? "Installing..." : settings?.kokoroModelInstalled ? "Reinstall Kokoro" : "Install Kokoro"}
                </button>
                <button
                  disabled={installingKokoroVoice || !(settings?.kokoroModelInstalled ?? false)}
                  onClick={() => void testAssistantVoiceOutput()}
                >
                  Test Voice
                </button>
              </div>
            </>
          )}
          {(settings?.voiceEngine || "humeOctave") === "macos" && (
            <div className="settings-action-row">
              <button onClick={() => void testAssistantVoiceOutput()}>
                Test Voice
              </button>
            </div>
          )}
          {(settings?.voiceEngine || "humeOctave") === "humeOctave" && (
            <p className="muted">Hume Octave is still a cloud voice option. Pick Kokoro Local for offline reply speech.</p>
          )}
          {assistantVoiceActionMessage && <p className="ready-line">{assistantVoiceActionMessage}</p>}
          <button className="gold-action" onClick={() => void onOpenTarget("voiceData")}>
            Open Voice Data
          </button>
        </div>
      </div>
    );
  }

  if (section === "shortcuts") {
    return (
      <div className="settings-stack single" key="shortcuts">
        {shortcutSettingGroups.map((group) => (
          <div className="settings-card" key={group.id}>
            <div className="card-heading">
              <Keyboard size={22} />
              <span>
                <strong>{group.title}</strong>
                <small>{group.subtitle}</small>
              </span>
            </div>
            {group.targets.map((target) => {
              const row = shortcutRows.find((item) => item.target === target);
              if (!row) return null;
              return (
                <ShortcutRecorderRow
                  key={row.target}
                  id={`shortcut-${group.id}-${row.target}`}
                  label={row.label}
                  target={row.target}
                  settings={settings}
                  onUpdateShortcut={onUpdateShortcut}
                />
              );
            })}
          </div>
        ))}
      </div>
    );
  }

  if (section === "models") {
    const promptRewriteProvider = settings?.promptRewriteProvider || "Ollama (Local)";
    const promptRewriteNeedsKey = promptRewriteProvider !== "Ollama (Local)";
    return (
      <div className="settings-stack single" key="models">
        <div className="settings-card">
          <div className="card-heading">
            <Cpu size={22} />
            <span>
              <strong>Chat Runtime Providers</strong>
              <small>Runtimes and models used by the main assistant composer.</small>
            </span>
          </div>
          <SelectRow label="Main chat runtime" value={providerLabel(settings?.assistantBackend || "codex")} />
          <SelectRow
            label="Runtime status"
            value={settings?.assistantRuntimeStatus || "Checking"}
            tone={settings?.assistantRuntimeStatusTone || "muted"}
          />
          {settings?.assistantRuntimeDetail && <p className="runtime-detail-line">{settings.assistantRuntimeDetail}</p>}
          <SelectRow label="Runtime account" value={settings?.assistantRuntimeAccount || "Not connected"} />
          <SelectRow label="Authentication" value={settings?.assistantRuntimeAuthMode || "Not connected"} />
          <SelectRow label="Setup command" value={settings?.assistantRuntimeLoginCommand || "No extra setup"} tone="muted" />
          <SelectRow label="Available runtimes" value={availableRuntimeProviderOptions(settings).map((option) => option.label).join(", ")} />
          <SelectRow label="Active chat model" value={settings?.model || "Default model"} />
          <SelectRow label="Sub-agent model" value={settings?.subAgentModel || "Same as main model"} />
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <PackageCheck size={22} />
            <span>
              <strong>Prompt Rewrite</strong>
              <small>Provider used to clean or improve prompts before sending.</small>
            </span>
          </div>
          <SettingsSelect
            label="Prompt rewrite provider"
            value={settings?.promptRewriteProvider || "Ollama (Local)"}
            options={promptRewriteProviderOptions}
            onChange={(value) => onUpdateSetting("promptRewriteProvider", value)}
          />
          <SettingsTextInput
            label="Prompt rewrite model"
            value={settings?.promptRewriteModel || ""}
            onCommit={(value) => onUpdateSetting("promptRewriteModel", value)}
          />
          <SettingsTextInput
            label="Prompt rewrite base URL"
            value={settings?.promptRewriteBaseURL || ""}
            onCommit={(value) => onUpdateSetting("promptRewriteBaseURL", value)}
          />
          <div className="secure-field provider-credential-box">
            <span>
              <strong>Prompt rewrite API key</strong>
              <small>{settings?.promptRewriteMaskedAPIKey || "Not configured"}</small>
            </span>
            <input
              type="password"
              value={promptRewriteAPIKeyDraft}
              disabled={!promptRewriteNeedsKey}
              placeholder={promptRewriteNeedsKey ? `Paste ${promptRewriteProvider} key` : "No key needed for Ollama"}
              autoComplete="off"
              spellCheck={false}
              onChange={(event) => setPromptRewriteAPIKeyDraft(event.target.value)}
            />
            <div className="inline-actions">
              <button
                disabled={!promptRewriteNeedsKey}
                onClick={() => void pasteProviderKey(setPromptRewriteAPIKeyDraft)}
              >
                Paste
              </button>
              <button
                className="gold-action"
                disabled={!promptRewriteNeedsKey || !promptRewriteAPIKeyDraft.trim()}
                onClick={() => {
                  void onSavePromptRewriteAPIKey(promptRewriteProvider, promptRewriteAPIKeyDraft).then(() => {
                    setPromptRewriteAPIKeyDraft("");
                    setProviderActionMessage("Prompt rewrite key saved.");
                  });
                }}
              >
                Save Key
              </button>
              <button
                disabled={!promptRewriteNeedsKey || !(settings?.promptRewriteAPIKeyConfigured ?? false)}
                onClick={() => {
                  void onClearPromptRewriteAPIKey(promptRewriteProvider).then(() => {
                    setPromptRewriteAPIKeyDraft("");
                    setProviderActionMessage("Prompt rewrite key cleared.");
                  });
                }}
              >
                Clear
              </button>
            </div>
            {providerActionMessage && <p className="ready-line">{providerActionMessage}</p>}
          </div>
        </div>
      </div>
    );
  }

  if (section === "automation") {
    const hasTelegramOwner = Boolean(settings?.telegramOwnerUserID?.trim() && settings.telegramOwnerChatID?.trim());
    const hasTelegramPending = Boolean(settings?.telegramPendingUserID?.trim() && settings.telegramPendingChatID?.trim());
    const telegramBotChatURL = settings?.telegramBotUsername
      ? `https://t.me/${settings.telegramBotUsername.replace(/^@/, "")}`
      : undefined;
    return (
      <div className="settings-stack single" key="automation">
        <div className="settings-card">
          <div className="card-heading">
            <Workflow size={22} />
            <span>
              <strong>Browser & App Control</strong>
              <small>Reuse the right browser profile and let agents operate local apps.</small>
            </span>
          </div>
          <SelectRow label="Browser profile" value={settings?.browserProfile || "System Default"} />
          <Checkbox
            checked={settings?.computerUseEnabled ?? false}
            label="Allow Computer Use when requested"
            onToggle={() => onUpdateSetting("computerUseEnabled", !(settings?.computerUseEnabled ?? false))}
          />
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <Bot size={22} />
            <span>
              <strong>Local API Helper</strong>
              <small>Expose a local control API for trusted clients and scheduled jobs.</small>
            </span>
          </div>
          <p className="ready-line">Helper running · Port {settings?.automationAPIPort || "45831"}</p>
          <button className="gold-action" onClick={() => void onOpenTarget("helperLogs")}>
            Open Helper Logs
          </button>
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <Send size={22} />
            <span>
              <strong>Telegram Remote Control</strong>
              <small>Control sessions, models, and remote chat from Telegram.</small>
            </span>
          </div>
          <Checkbox
            checked={settings?.telegramEnabled ?? false}
            label="Enable Telegram remote"
            onToggle={() => onUpdateSetting("telegramEnabled", !(settings?.telegramEnabled ?? false))}
          />
          <label className="field-label">
            <span>Bot token</span>
            <input
              type="password"
              value={telegramBotTokenDraft}
              onChange={(event) => setTelegramBotTokenDraft(event.target.value)}
              placeholder="Paste your Telegram bot token"
            />
          </label>
          <div className="inline-actions">
            <button
              className="gold-action"
              onClick={() => {
                void onSaveTelegramBotToken(telegramBotTokenDraft).then(() => setTelegramActionMessage("Telegram bot token saved."));
              }}
            >
              Save Token
            </button>
            <button
              onClick={() => {
                void onClearTelegramBotToken().then(() => {
                  setTelegramBotTokenDraft("");
                  setTelegramActionMessage("Telegram bot token cleared.");
                });
              }}
            >
              Clear Token
            </button>
            <button
              onClick={() => {
                void onTestTelegramConnection(telegramBotTokenDraft).then((result) => {
                  if (result?.message) setTelegramActionMessage(result.message);
                });
              }}
            >
              Test Bot Connection
            </button>
          </div>
          <p className="token-line">{settings?.telegramMaskedToken || "Not configured"}</p>
          <div className="inline-actions">
            <button onClick={() => void window.openAssistElectron?.openExternal("https://t.me/BotFather")}>
              Open BotFather
            </button>
            {telegramBotChatURL && (
              <button onClick={() => void window.openAssistElectron?.openExternal(telegramBotChatURL)}>
                Open Bot Chat
              </button>
            )}
          </div>
          <SelectRow label="Default session" value={settings?.telegramSelectedSessionID || "Last Telegram-selected session"} />
          <p className="ready-line">
            {settings?.telegramTokenConfigured ? "Bot token configured" : "Missing bot token"} · {hasTelegramOwner ? "Paired" : hasTelegramPending ? "Pairing pending" : "No paired chat"}
          </p>
          <div className="telegram-pairing-box">
            {hasTelegramOwner ? (
              <>
                <strong>Paired Telegram user ID: {settings?.telegramOwnerUserID}</strong>
                <small>Chat ID: {settings?.telegramOwnerChatID}</small>
                <button onClick={() => void onForgetTelegramPairing().then(() => setTelegramActionMessage("Removed the paired Telegram chat."))}>
                  Forget Paired Chat
                </button>
              </>
            ) : (
              <span>No Telegram chat is paired yet.</span>
            )}
            {hasTelegramPending && (
              <>
                <strong>
                  {settings?.telegramPendingDisplayName
                    ? `Pending pairing request from ${settings.telegramPendingDisplayName}.`
                    : "Pending pairing request."}
                </strong>
                <div className="inline-actions">
                  <button className="gold-action" onClick={() => void onApproveTelegramPairing().then(() => setTelegramActionMessage("Telegram pairing approved."))}>
                    Approve Pairing
                  </button>
                  <button onClick={() => void onDeclineTelegramPairing().then(() => setTelegramActionMessage("Telegram pairing declined."))}>
                    Decline
                  </button>
                </div>
              </>
            )}
          </div>
          {telegramActionMessage && <p className="ready-line">{telegramActionMessage}</p>}
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <ExternalLink size={22} />
            <span>
              <strong>Remote Access</strong>
              <small>Pair devices and expose the assistant through a secure remote page.</small>
            </span>
          </div>
          <Checkbox
            checked={settings?.remoteAccessEnabled ?? false}
            label="Enable local remote page"
            onToggle={() => onUpdateSetting("remoteAccessEnabled", !(settings?.remoteAccessEnabled ?? false))}
          />
          <SelectRow label="Pairing mode" value="Require one-time code" />
          <SelectRow label="Local helper URL" value={`http://127.0.0.1:${settings?.remoteAccessPort || "45831"}`} />
          {settings?.remoteAccessPublicURL && <SelectRow label="Public URL" value={settings.remoteAccessPublicURL} />}
          <div className="inline-actions">
            <button
              className="gold-action"
              onClick={() => void window.openAssistElectron?.openExternal(`http://127.0.0.1:${settings?.remoteAccessPort || "45831"}`)}
            >
              Open Remote Page
            </button>
            <button onClick={() => void onOpenTarget("remoteAccess")}>
              Open Remote Files
            </button>
          </div>
        </div>
      </div>
    );
  }

  if (section === "app") {
    const themeMode = settings?.themeMode || "System";
    const savedColorTheme = settings?.colorTheme || "Ocean";
    const colorTheme = pendingColorTheme ?? savedColorTheme;
    const hasPendingTheme = pendingColorTheme !== null && pendingColorTheme !== savedColorTheme;
    const appChromeStyle = settings?.appChromeStyle || "Glass (High Contrast)";
    const waveformTheme = settings?.waveformTheme || "Vibrant Spectrum";
    const activeThemeMeta = colorThemeMeta[colorTheme] ?? colorThemeMeta.Ocean;
    const appearanceSettings = settings ?? ({} as SettingsSnapshot);
    const resolvedAppearanceTone = resolveThemeMode(themeMode, readSystemThemeMode());
    const appearancePrefix = resolvedAppearanceTone === "light" ? "lightTheme" : "darkTheme";
    const updateAppearanceSetting = (key: SettingsUpdateKey, value: SettingsUpdateValue, message = "Changed.") => {
      onUpdateSetting(key, value);
      setAppearanceStatus(message);
    };
    // Picking a swatch just stages the choice locally — no IPC round-trips until Save is clicked.
    const previewColorTheme = (theme: string) => {
      setPendingColorTheme(theme);
      if (theme === savedColorTheme) {
        setAppearanceStatus("");
      } else {
        setAppearanceStatus(`Preview: ${theme}. Click Save theme to apply.`);
      }
    };
    const saveColorTheme = () => {
      if (!hasPendingTheme || !pendingColorTheme) return;
      const theme = pendingColorTheme;
      const patch = codexThemePresetPatch(theme, resolvedAppearanceTone);
      setIsSavingTheme(true);
      // Fire all updates in a single tick so React batches the state changes
      // and the chat view re-renders in one frame instead of seven.
      onUpdateSetting("colorTheme", theme);
      onUpdateSetting(`${appearancePrefix}Accent` as SettingsUpdateKey, patch.accent);
      onUpdateSetting(`${appearancePrefix}Background` as SettingsUpdateKey, patch.background);
      onUpdateSetting(`${appearancePrefix}Foreground` as SettingsUpdateKey, patch.foreground);
      onUpdateSetting(`${appearancePrefix}Skill` as SettingsUpdateKey, patch.skill);
      onUpdateSetting(`${appearancePrefix}DiffAdded` as SettingsUpdateKey, patch.diffAdded);
      onUpdateSetting(`${appearancePrefix}DiffRemoved` as SettingsUpdateKey, patch.diffRemoved);
      setAppearanceStatus(`Saved ${theme} for the active ${resolvedAppearanceTone} theme.`);
      setPendingColorTheme(null);
      window.setTimeout(() => setIsSavingTheme(false), 220);
    };
    const discardThemePreview = () => {
      setPendingColorTheme(null);
      setAppearanceStatus("");
    };
    const versionLabel = `Version ${settings?.appVersion || "1.0.7"} (${settings?.buildNumber || "69"})`;
    const openPrivacySettings = () =>
      window.openAssistElectron?.openExternal("x-apple.systempreferences:com.apple.preference.security");
    return (
      <div className="settings-stack single" key="app">
        <div className="settings-card expanded">
          <div className="card-heading">
            <Paintbrush size={22} />
            <span>
              <strong>Appearance & Visual Feedback</strong>
              <small>Theme mode, interface style, fonts, and motion.</small>
            </span>
          </div>
          <ThemeSegmentedControl
            label="Theme"
            description="Use light, dark, or match your system"
            value={themeMode}
            options={themeModeOptions}
            icons={{
              Light: <Sun size={15} />,
              Dark: <Moon size={15} />,
              System: <Monitor size={15} />
            }}
            onChange={(value) => updateAppearanceSetting("themeMode", value, `Theme mode changed to ${value}.`)}
          />
          <ThemeToggleRow
            label="Use pointer cursors"
            checked={settings?.pointerCursors ?? false}
            onToggle={() => updateAppearanceSetting("pointerCursors", !(settings?.pointerCursors ?? false))}
          />
          <ThemeSegmentedControl
            label="Reduce motion"
            description="Reduce animations or match your system"
            value={settings?.reduceMotionMode || "System"}
            options={reduceMotionOptions}
            onChange={(value) => updateAppearanceSetting("reduceMotionMode", value, `Reduce motion changed to ${value}.`)}
          />
          <ThemeRangeRow
            label="UI font size"
            value={settings?.uiFontSize || "13"}
            min={12}
            max={18}
            onChange={(value) => updateAppearanceSetting("uiFontSize", value)}
          />
          <ThemeRangeRow
            label="Code font size"
            value={settings?.codeFontSize || "12"}
            min={11}
            max={16}
            onChange={(value) => updateAppearanceSetting("codeFontSize", value)}
          />
          {appearanceStatus && <p className="theme-status-line appearance-status-line">{appearanceStatus}</p>}
          <div className="theme-picker">
            <div className="theme-picker-head">
              <strong>Color Theme</strong>
              <small>{activeThemeMeta.description}</small>
            </div>
            <div className="theme-swatch-grid" aria-label="Color theme options">
              {colorThemeOptions.map((theme) => {
                const meta = colorThemeMeta[theme] ?? colorThemeMeta.Ocean;
                const isSelected = theme === colorTheme;
                const isPending = hasPendingTheme && theme === pendingColorTheme;
                return (
                  <button
                    key={theme}
                    type="button"
                    className={cx(isSelected && "selected", isPending && "pending")}
                    onClick={() => previewColorTheme(theme)}
                    style={{
                      "--theme-a": meta.swatches[0],
                      "--theme-b": meta.swatches[1],
                      "--theme-c": meta.swatches[2]
                    } as CSSProperties}
                    title={meta.description}
                  >
                    <span />
                    <strong>{theme}</strong>
                  </button>
                );
              })}
            </div>
            <div className="theme-picker-actions">
              <span className="theme-picker-hint">
                {hasPendingTheme
                  ? `Preview only — click Save theme to apply ${pendingColorTheme} everywhere.`
                  : `Active: ${savedColorTheme}.`}
              </span>
              <span className="theme-picker-buttons">
                <button
                  type="button"
                  onClick={discardThemePreview}
                  disabled={!hasPendingTheme || isSavingTheme}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  className="primary-action"
                  onClick={saveColorTheme}
                  disabled={!hasPendingTheme || isSavingTheme}
                >
                  {isSavingTheme ? "Saving…" : "Save theme"}
                </button>
              </span>
            </div>
          </div>
          <SettingsSelect
            label="Interface Style"
            value={appChromeStyle}
            options={appChromeStyleOptions}
            onChange={(value) => onUpdateSetting("appChromeStyle", value)}
          />
          <SettingsSelect
            label="Waveform Theme"
            value={waveformTheme}
            options={waveformThemeOptions}
            onChange={(value) => onUpdateSetting("waveformTheme", value)}
          />
          <div className={cx("waveform", `waveform-${cssKey(waveformTheme)}`)}>
            {Array.from({ length: 12 }).map((_, index) => (
              <i key={index} style={{ height: `${8 + ((index * 7) % 24)}px` }} />
            ))}
          </div>
          {screenSnipPresets.length > 0 && (
            <>
              <SettingsSelect
                label="Screen Snip Color"
                value={screenSnipTheme}
                options={screenSnipPresets.map((preset) => ({ value: preset.key, label: preset.label }))}
                onChange={(value) => {
                  setScreenSnipTheme(value);
                  const electron = (window as any).openAssistElectron;
                  if (electron?.setScreenSnipTheme) {
                    electron.setScreenSnipTheme(value).catch(() => {});
                  }
                  setAppearanceStatus(`Screen snip color updated.`);
                }}
              />
              <div className="screen-snip-swatch-grid" aria-label="Screen snip palette options">
                {screenSnipPresets.map((preset) => (
                  <button
                    key={preset.key}
                    type="button"
                    className={cx("screen-snip-swatch", preset.key === screenSnipTheme && "selected")}
                    onClick={() => {
                      setScreenSnipTheme(preset.key);
                      const electron = (window as any).openAssistElectron;
                      if (electron?.setScreenSnipTheme) {
                        electron.setScreenSnipTheme(preset.key).catch(() => {});
                      }
                      setAppearanceStatus(`Screen snip color updated.`);
                    }}
                    title={preset.label}
                  >
                    <span
                      className="screen-snip-swatch-strip"
                      style={{
                        background: preset.colors.length
                          ? `linear-gradient(90deg, ${preset.colors.join(", ")})`
                          : "linear-gradient(90deg, #4f8fe8, #a363b7, #df4546, #ddb52d)"
                      }}
                    />
                    <strong>{preset.label}</strong>
                  </button>
                ))}
              </div>
            </>
          )}
        </div>

        <CustomThemeDisclosure
          resolvedAppearanceTone={resolvedAppearanceTone}
          appearanceSettings={appearanceSettings}
          onUpdateSetting={onUpdateSetting}
        />

        <div className="settings-card">
          <div className="card-heading">
            <Shield size={22} />
            <span>
              <strong>macOS Permissions</strong>
              <small>Open system preference shortcuts to grant system API access.</small>
            </span>
          </div>
          <div className="inline-actions">
            <button onClick={openPrivacySettings}>Open Accessibility</button>
            <button onClick={openPrivacySettings}>Open Microphone</button>
            <button onClick={openPrivacySettings}>Open Speech Recognition</button>
            <button onClick={openPrivacySettings}>Open Screen Recording</button>
          </div>
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <Terminal size={22} />
            <span>
              <strong>Diagnostics Logs</strong>
              <small>Inspect system crash files, helper processes, or telemetry folders.</small>
            </span>
          </div>
          <div className="inline-actions">
            <button onClick={() => void onOpenTarget("logs")}>Open Crash Logs</button>
            <button onClick={() => void onOpenTarget("helperLogs")}>Open Helper Logs</button>
            <button onClick={() => void onOpenTarget("insertionDiagnostics")}>Open Insertion Diagnostics</button>
            <button onClick={() => void onOpenTarget("support")}>Open App Data</button>
          </div>
        </div>

        <div className="settings-card">
          <div className="card-heading">
            <RefreshCw size={22} />
            <span>
              <strong>App Info</strong>
              <small>{versionLabel} is up to date.</small>
            </span>
          </div>
          <button className="gold-action" onClick={() => void onOpenTarget("support")}>
            Open Local Data Folder
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="settings-stack single">
      <DisclosureCard icon={<Settings size={22} />} title={`${settingsSections.find((item) => item.id === section)?.title} Overview`} subtitle={settingsSections.find((item) => item.id === section)?.subtitle ?? ""} />
      <div className="settings-card">
        <Checkbox checked label="Enable recommended defaults" />
        <Checkbox label="Show advanced controls" />
      </div>
    </div>
  );
}

function Subnav({
  title,
  items,
  activeIndex = 0,
  onSelect
}: {
  title: string;
  items: string[];
  activeIndex?: number;
  onSelect?: (index: number) => void;
}) {
  return (
    <nav className="settings-subnav">
      <h2>{title}</h2>
      {items.map((item, index) => (
        <button
          key={item}
          type="button"
          className={cx(index === activeIndex && "active")}
          onClick={() => onSelect?.(index)}
        >
          {item}
        </button>
      ))}
    </nav>
  );
}

function Checkbox({ checked, label, onToggle }: { checked?: boolean; label: string; onToggle?: () => void }) {
  const content = (
    <>
      <span className={cx("checkbox", checked && "checked")}>{checked && <Check size={14} />}</span>
      {label}
    </>
  );
  if (onToggle) {
    return (
      <button className="checkbox-row checkbox-button" aria-label={label} onClick={onToggle}>
        {content}
      </button>
    );
  }
  return (
    <span className="checkbox-row checkbox-static" aria-disabled="true" title="Managed by native OpenAssist settings">
      {content}
    </span>
  );
}

function FieldLabel({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="field-label">
      <span>{label}</span>
      {children}
    </label>
  );
}

function SettingsTextInput({
  label,
  value,
  onCommit
}: {
  label: string;
  value: string;
  onCommit: (value: string) => void;
}) {
  const [draft, setDraft] = useState(value);

  useEffect(() => {
    setDraft(value);
  }, [value]);

  const commit = () => {
    const next = draft.trim();
    if (next !== value) onCommit(next);
  };

  return (
    <FieldLabel label={label}>
      <input
        value={draft}
        onBlur={commit}
        onChange={(event) => setDraft(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter") {
            event.currentTarget.blur();
          }
        }}
      />
    </FieldLabel>
  );
}

function SettingsSelect({
  label,
  value,
  options,
  disabled = false,
  onChange
}: {
  label: string;
  value: string;
  options: Array<string | { value: string; label: string }>;
  disabled?: boolean;
  onChange: (value: string) => void;
}) {
  const baseOptions = options.map((option) => (
    typeof option === "string" ? { value: option, label: option } : option
  ));
  const normalizedOptions = value && !baseOptions.some((option) => option.value === value)
    ? [{ value, label: `Custom: ${value}` }, ...baseOptions]
    : baseOptions;
  return (
    <FieldLabel label={label}>
      <select value={value} disabled={disabled} onChange={(event) => onChange(event.target.value)}>
        {normalizedOptions.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </FieldLabel>
  );
}

function ThemeSegmentedControl({
  label,
  description,
  value,
  options,
  icons,
  onChange
}: {
  label: string;
  description?: string;
  value: string;
  options: string[];
  icons?: Partial<Record<string, React.ReactNode>>;
  onChange: (value: string) => void;
}) {
  return (
    <div className="theme-mode-row">
      <span>
        <strong>{label}</strong>
        {description && <small>{description}</small>}
      </span>
      <div className="theme-mode-control" role="group" aria-label={label}>
        {options.map((option) => (
          <button
            key={option}
            className={cx(value === option && "selected")}
            onClick={() => onChange(option)}
          >
            {icons?.[option]}
            <span>{option}</span>
          </button>
        ))}
      </div>
    </div>
  );
}

function ThemeValueInput({
  label,
  value,
  swatch,
  disabled,
  onCommit
}: {
  label: string;
  value: string;
  swatch?: boolean;
  disabled?: boolean;
  onCommit: (value: string) => void;
}) {
  const [draft, setDraft] = useState(value);
  const lastCommittedColorRef = useRef(value);
  useEffect(() => {
    setDraft(value);
    lastCommittedColorRef.current = value;
  }, [value]);
  const commit = () => {
    const next = draft.trim();
    if (next && next !== value) onCommit(next);
  };
  const commitColor = (rawValue: string) => {
    const next = rawValue.toUpperCase();
    setDraft(next);
    if (next !== lastCommittedColorRef.current) {
      lastCommittedColorRef.current = next;
      onCommit(next);
    }
  };
  const colorValue = isHexColor(draft) ? draft : "#000000";
  return (
    <label className="theme-config-row">
      <span>{label}</span>
      <span className="theme-value-input">
        {swatch && (
          <input
            className="theme-color-picker"
            type="color"
            aria-label={`${label} color picker`}
            value={colorValue}
            disabled={disabled}
            onChange={(event) => commitColor(event.target.value)}
            onInput={(event) => commitColor(event.currentTarget.value)}
          />
        )}
        <input
          value={draft}
          disabled={disabled}
          onChange={(event) => setDraft(event.target.value)}
          onBlur={commit}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              event.preventDefault();
              commit();
            }
          }}
        />
      </span>
    </label>
  );
}

function ThemeFontInput({
  label,
  value,
  presets,
  disabled,
  onCommit
}: {
  label: string;
  value: string;
  presets: Array<{ label: string; value: string }>;
  disabled?: boolean;
  onCommit: (value: string) => void;
}) {
  const [draft, setDraft] = useState(value);
  useEffect(() => {
    setDraft(value);
  }, [value]);
  const commit = () => {
    const next = draft.trim();
    if (next && next !== value) onCommit(next);
  };
  const matchingPreset = presets.find((preset) => preset.value === value);
  return (
    <label className="theme-config-row">
      <span>{label}</span>
      <span className="theme-value-input">
        <select
          className="theme-font-picker"
          aria-label={`${label} preset`}
          value={matchingPreset?.value ?? "__custom"}
          disabled={disabled}
          onChange={(event) => {
            const next = event.target.value;
            if (next === "__custom") return;
            setDraft(next);
            onCommit(next);
          }}
        >
          {presets.map((preset) => (
            <option key={preset.label} value={preset.value} style={{ fontFamily: preset.value }}>
              {preset.label}
            </option>
          ))}
          {!matchingPreset && <option value="__custom">Custom</option>}
        </select>
        <input
          value={draft}
          disabled={disabled}
          spellCheck={false}
          style={{ fontFamily: draft || value }}
          onChange={(event) => setDraft(event.target.value)}
          onBlur={commit}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              event.preventDefault();
              commit();
            }
          }}
        />
      </span>
    </label>
  );
}

function ThemeToggleRow({ label, checked, onToggle }: { label: string; checked: boolean; onToggle: () => void }) {
  return (
    <button className="theme-config-row theme-toggle-row" onClick={onToggle}>
      <span>{label}</span>
      <span className={cx("toggle", checked && "on")} />
    </button>
  );
}

function ThemeRangeRow({
  label,
  value,
  min,
  max,
  onChange
}: {
  label: string;
  value: string;
  min: number;
  max: number;
  onChange: (value: string) => void;
}) {
  const numeric = Number(value) || min;
  return (
    <label className="theme-config-row theme-range-row">
      <span>{label}</span>
      <input
        type="range"
        min={min}
        max={max}
        value={numeric}
        onChange={(event) => onChange(event.target.value)}
      />
      <strong>{numeric}</strong>
    </label>
  );
}

function SettingsVolumeRow({
  label,
  value,
  onChange
}: {
  label: string;
  value: number;
  onChange: (value: number) => void;
}) {
  const percent = Math.min(100, Math.max(0, Math.round((Number.isFinite(value) ? value : 0.10) * 100)));
  return (
    <label className="theme-config-row theme-range-row settings-volume-row">
      <span>{label}</span>
      <input
        type="range"
        min={0}
        max={100}
        value={percent}
        onChange={(event) => onChange(Number(event.target.value) / 100)}
      />
      <strong>{percent}%</strong>
    </label>
  );
}

function ThemeConfigCard({
  title,
  tone,
  activeTone,
  settings,
  onUpdateSetting
}: {
  title: string;
  tone: "light" | "dark";
  activeTone: "light" | "dark";
  settings: SettingsSnapshot;
  onUpdateSetting: (key: SettingsUpdateKey, value: SettingsUpdateValue) => void;
}) {
  const prefix = tone === "light" ? "lightTheme" : "darkTheme";
  const accentKey = `${prefix}Accent` as SettingsUpdateKey;
  const backgroundKey = `${prefix}Background` as SettingsUpdateKey;
  const foregroundKey = `${prefix}Foreground` as SettingsUpdateKey;
  const uiFontKey = `${prefix}UIFont` as SettingsUpdateKey;
  const codeFontKey = `${prefix}CodeFont` as SettingsUpdateKey;
  const sidebarKey = `${prefix}TranslucentSidebar` as SettingsUpdateKey;
  const contrastKey = `${prefix}Contrast` as SettingsUpdateKey;
  const codeThemeKey = `${prefix}CodeThemeID` as SettingsUpdateKey;
  const diffAddedKey = `${prefix}DiffAdded` as SettingsUpdateKey;
  const diffRemovedKey = `${prefix}DiffRemoved` as SettingsUpdateKey;
  const skillKey = `${prefix}Skill` as SettingsUpdateKey;
  const accent = String(settings[accentKey as keyof SettingsSnapshot] || "");
  const background = String(settings[backgroundKey as keyof SettingsSnapshot] || "");
  const foreground = String(settings[foregroundKey as keyof SettingsSnapshot] || "");
  const uiFont = String(settings[uiFontKey as keyof SettingsSnapshot] || "");
  const codeFont = String(settings[codeFontKey as keyof SettingsSnapshot] || "");
  const translucentSidebar = Boolean(settings[sidebarKey as keyof SettingsSnapshot]);
  const contrast = String(settings[contrastKey as keyof SettingsSnapshot] || "50");
  const codeThemeID = String(settings[codeThemeKey as keyof SettingsSnapshot] || codexThemeDefaults[tone].codeThemeId);
  const [importOpen, setImportOpen] = useState(false);
  const [importDraft, setImportDraft] = useState("");
  const [themeStatus, setThemeStatus] = useState("");
  const modeForTone = tone === "light" ? "Light" : "Dark";
  const applyToneIfNeeded = () => {
    if (tone !== activeTone) onUpdateSetting("themeMode", modeForTone);
  };
  const updateThemeSetting = (key: SettingsUpdateKey, value: SettingsUpdateValue, message = "Changed.") => {
    onUpdateSetting(key, value);
    applyToneIfNeeded();
    setThemeStatus(message);
  };

  const applyCodeTheme = (nextCodeThemeID: string) => {
    const seed = codexSeedFor(nextCodeThemeID, tone);
    onUpdateSetting(codeThemeKey, nextCodeThemeID);
    onUpdateSetting(accentKey, seed.accent);
    onUpdateSetting(backgroundKey, seed.surface);
    onUpdateSetting(foregroundKey, seed.ink);
    onUpdateSetting(diffAddedKey, seed.diffAdded);
    onUpdateSetting(diffRemovedKey, seed.diffRemoved);
    onUpdateSetting(skillKey, seed.skill);
    onUpdateSetting(sidebarKey, !(seed.opaqueWindows ?? false));
    if (typeof seed.contrast === "number") {
      onUpdateSetting(contrastKey, String(seed.contrast));
    }
    applyToneIfNeeded();
    setThemeStatus(`Applied ${codexThemePresets[nextCodeThemeID] ?? nextCodeThemeID} ${tone} theme.`);
  };

  const applyShare = (share: CodexThemeShare) => {
    if (share.variant !== tone) {
      setThemeStatus(`This is a ${share.variant} theme. Use the ${share.variant} card to import it.`);
      return;
    }
    const defaults = codexThemeDefaults[tone];
    onUpdateSetting(accentKey, share.theme.accent);
    onUpdateSetting(backgroundKey, share.theme.surface);
    onUpdateSetting(foregroundKey, share.theme.ink);
    onUpdateSetting(uiFontKey, share.theme.fonts.ui ?? defaults.fonts.ui);
    onUpdateSetting(codeFontKey, share.theme.fonts.code ?? defaults.fonts.code);
    onUpdateSetting(sidebarKey, !share.theme.opaqueWindows);
    onUpdateSetting(contrastKey, String(share.theme.contrast));
    onUpdateSetting(codeThemeKey, share.codeThemeId);
    onUpdateSetting(diffAddedKey, share.theme.semanticColors.diffAdded);
    onUpdateSetting(diffRemovedKey, share.theme.semanticColors.diffRemoved);
    onUpdateSetting(skillKey, share.theme.semanticColors.skill);
    onUpdateSetting("themeMode", tone === "light" ? "Light" : "Dark");
    setImportOpen(false);
    setImportDraft("");
    setThemeStatus("Imported and applied Codex theme.");
  };

  const importTheme = () => {
    try {
      applyShare(parseCodexThemeShare(importDraft));
    } catch (error) {
      setThemeStatus(error instanceof Error ? error.message : "Could not import theme.");
    }
  };

  const pasteTheme = async () => {
    const pasted = (await window.openAssistElectron?.readClipboardText?.().catch(() => ""))
      || (await navigator.clipboard?.readText?.().catch(() => ""))
      || "";
    setImportDraft(pasted);
    setThemeStatus(pasted ? "" : "Clipboard is empty.");
  };

  const copyTheme = async () => {
    const share = codexThemeShareString(settings, tone);
    try {
      if (window.openAssistElectron?.writeClipboardText) {
        await window.openAssistElectron.writeClipboardText(share);
      } else {
        await navigator.clipboard?.writeText(share);
      }
      setThemeStatus("Copied Codex theme string.");
    } catch {
      setImportDraft(share);
      setImportOpen(true);
      setThemeStatus("Copy failed, so the theme string is shown below.");
    }
  };

  return (
    <section className="theme-config-card">
      <div className="theme-config-card-header">
        <strong>{title}</strong>
        <button type="button" onClick={() => {
          setImportOpen((current) => !current);
          setThemeStatus("");
        }}>
          Import
        </button>
        <button type="button" onClick={() => void copyTheme()}>Copy theme</button>
        <label className="theme-preset-pill">
          <span>Aa</span>
          <select
            aria-label={`${title} code theme`}
            value={codeThemeID}
            onChange={(event) => applyCodeTheme(event.target.value)}
          >
            {codexCodeThemeOptions.map((option) => (
              <option key={option.value} value={option.value}>{option.label}</option>
            ))}
          </select>
          <ChevronDown size={14} />
        </label>
      </div>
      {importOpen && (
        <div className="theme-import-row">
          <input
            value={importDraft}
            placeholder={`${codexThemeSharePrefix}{...}`}
            spellCheck={false}
            onChange={(event) => setImportDraft(event.target.value)}
          />
          <button type="button" onClick={() => void pasteTheme()}>Paste</button>
          <button type="button" className="theme-import-submit" disabled={!importDraft.trim()} onClick={importTheme}>
            Import
          </button>
        </div>
      )}
      <ThemeValueInput label="Accent" value={accent} swatch onCommit={(value) => updateThemeSetting(accentKey, value)} />
      <ThemeValueInput label="Background" value={background} swatch onCommit={(value) => updateThemeSetting(backgroundKey, value)} />
      <ThemeValueInput label="Foreground" value={foreground} swatch onCommit={(value) => updateThemeSetting(foregroundKey, value)} />
      <ThemeFontInput label="UI font" value={uiFont} presets={uiFontPresets} onCommit={(value) => updateThemeSetting(uiFontKey, value)} />
      <ThemeFontInput label="Code font" value={codeFont} presets={codeFontPresets} onCommit={(value) => updateThemeSetting(codeFontKey, value)} />
      <ThemeToggleRow label="Translucent sidebar" checked={translucentSidebar} onToggle={() => updateThemeSetting(sidebarKey, !translucentSidebar)} />
      <ThemeRangeRow label="Contrast" value={contrast} min={30} max={100} onChange={(value) => updateThemeSetting(contrastKey, value)} />
      {themeStatus && <p className="theme-status-line">{themeStatus}</p>}
    </section>
  );
}

function CustomThemeDisclosure({
  resolvedAppearanceTone,
  appearanceSettings,
  onUpdateSetting
}: {
  resolvedAppearanceTone: "light" | "dark";
  appearanceSettings: SettingsSnapshot;
  onUpdateSetting: (key: SettingsUpdateKey, value: SettingsUpdateValue) => void;
}) {
  const [open, setOpen] = useState(false);
  return (
    <div className={cx("settings-card", "custom-theme-card", open && "expanded")}>
      <button
        type="button"
        className="custom-theme-toggle"
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
      >
        <Paintbrush size={20} />
        <span>
          <strong>Custom theme colors</strong>
          <small>Override accent, background, fonts, and contrast for the active mode.</small>
        </span>
        <ChevronRight size={16} className="custom-theme-chevron" />
      </button>
      {open && (
        <div className="custom-theme-body">
          <ThemeConfigCard title="Light theme" tone="light" activeTone={resolvedAppearanceTone} settings={appearanceSettings} onUpdateSetting={onUpdateSetting} />
          <ThemeConfigCard title="Dark theme" tone="dark" activeTone={resolvedAppearanceTone} settings={appearanceSettings} onUpdateSetting={onUpdateSetting} />
        </div>
      )}
    </div>
  );
}

function SelectRow({
  id,
  label,
  value,
  tone = "default"
}: {
  id?: string;
  label: string;
  value: string;
  tone?: "default" | "ready" | "warning" | "muted";
}) {
  return (
    <label id={id} className="select-row">
      <span>{label}</span>
      <span className={cx("select-value", tone !== "default" && `select-value-${tone}`)}>{value}</span>
    </label>
  );
}

function ShortcutRecorderRow({
  id,
  label,
  target,
  settings,
  onUpdateShortcut
}: {
  id?: string;
  label: string;
  target: ShortcutTarget;
  settings?: SettingsSnapshot;
  onUpdateShortcut: (target: ShortcutTarget, keyCode: number, modifiers: number) => Promise<SettingsSnapshot | undefined>;
}) {
  const [isRecording, setIsRecording] = useState(false);
  const [message, setMessage] = useState<string | undefined>(undefined);
  const shortcut = shortcutValueFor(settings, target);
  const segments = shortcutSegments(shortcut.keyCode, shortcut.modifiers);

  useEffect(() => {
    if (!isRecording) return;

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.repeat) return;
      event.preventDefault();
      event.stopPropagation();

      const rawModifiers = eventModifierRaw(event);
      if (event.code === "Escape" && rawModifiers === 0) {
        setIsRecording(false);
        setMessage("Cancelled.");
        return;
      }

      const captured = shortcutFromKeyboardEvent(event);
      if (!captured || !isValidShortcut(captured.keyCode, captured.modifiers)) {
        setMessage("Use 1-3 modifiers with a key, or 2-4 modifiers only.");
        return;
      }

      const conflict = shortcutConflictMessage(target, captured, settings);
      if (conflict) {
        setMessage(conflict);
        return;
      }

      setMessage("Saving...");
      void onUpdateShortcut(target, captured.keyCode, captured.modifiers)
        .then((updatedSettings) => {
          setIsRecording(false);
          setMessage(updatedSettings ? "Saved." : "Could not save shortcut.");
        })
        .catch((error) => {
          setIsRecording(false);
          setMessage(error instanceof Error ? error.message : "Could not save shortcut.");
        });
    };

    window.addEventListener("keydown", onKeyDown, true);
    return () => window.removeEventListener("keydown", onKeyDown, true);
  }, [isRecording, onUpdateShortcut, settings, target]);

  return (
    <div id={id} className={cx("shortcut-recorder-row", isRecording && "recording")}>
      <span className="shortcut-recorder-label">{label}</span>
      <button
        type="button"
        className="shortcut-capture-button"
        data-shortcut-target={target}
        aria-label={`Choose ${label}`}
        onClick={() => {
          setIsRecording(true);
          setMessage("Press shortcut now. Esc cancels.");
        }}
      >
        <span className="shortcut-key-chips" aria-label={shortcutLabel(shortcut.keyCode, shortcut.modifiers)}>
          {segments.map((segment) => (
            <span className="shortcut-key-chip" key={`${target}-${segment}`}>
              {segment}
            </span>
          ))}
        </span>
        <small>{isRecording ? "Listening..." : "Choose Shortcut"}</small>
      </button>
      {message && <small className="shortcut-message">{message}</small>}
    </div>
  );
}

function DisclosureCard({ icon, title, subtitle }: { icon: React.ReactNode; title: string; subtitle: string }) {
  return (
    <div className="disclosure-card">
      <span className="disclosure-icon">{icon}</span>
      <span>
        <strong>{title}</strong>
        <small>{subtitle}</small>
      </span>
      <span className="open-pill">
        Ready <Check size={14} />
      </span>
    </div>
  );
}

function providerLabel(raw: string) {
  const key = providerKey(raw);
  const runtimeOption = runtimeProviderOptions.find((item) => item.key === key);
  if (runtimeOption) return runtimeOption.label;
  if (raw === "githubCopilot") return "Copilot";
  return raw;
}

function FeatureRouter({
  activeView,
  settingsInitialSection,
  compact,
  onToggleCompact,
  onHideWindow,
  onOpenThreadNote,
  onOpenInstructions,
  onOpenMemory,
  onOpenSkills,
  onOpenPlugins,
  onCloseThreadNotePanel,
  onBackToThreads,
  onRefreshAppState,
  onOpenAssistant,
  appState,
  providerModelOptionsByBackend,
  selectedThreadID,
  selectedProjectID,
  threadDetail,
  selectedNoteID,
  selectedNoteTarget,
  notesScope,
  noteDetail,
  noteDraft,
  noteSaveStatus,
  composerText,
  isSending,
  interactionMode,
  permissionMode,
  reasoningEffort,
  voiceStatus,
  voiceStatusText,
  voiceError,
  liveVoiceStatus,
  liveVoiceStatusText,
  providerStatus,
  selectedPluginID,
  selectedPluginIDs,
  onComposerText,
  onSend,
  onStop,
  onVoiceInput,
  onLiveVoice,
  onOpenRealtimeSettings,
  onToggleAgentic,
  onCycleReasoning,
  onSelectPermissionMode,
  onCreateTemporaryThread,
  onAddTextToThreadNote,
  onSpeakText,
  onRespondToApproval,
  onSelectProvider,
  onSelectModel,
  onSelectNotesProject,
  onSelectNotesScope,
  onSelectNote,
  onSelectThreadNoteItem,
  onCreateNote,
  onNoteDraft,
  onSaveNote,
  onToggleAutomation,
  onCreateAutomation,
  onToggleSkill,
  onImportSkillFolder,
  onImportSkillFromGitHub,
  onCreateSkill,
  onSavePromptRewriteAPIKey,
  onClearPromptRewriteAPIKey,
  onSaveCloudTranscriptionAPIKey,
  onClearCloudTranscriptionAPIKey,
  onUpdateSetting,
  onUpdateShortcut,
  onSelectPlugin,
  onTogglePluginUse,
  onUseStarterPrompt
}: {
  activeView: ViewKey;
  settingsInitialSection: SettingsKey;
  compact: boolean;
  onToggleCompact: () => void;
  onHideWindow: () => void;
  onOpenThreadNote: () => void;
  onOpenInstructions: () => void;
  onOpenMemory: () => void;
  onOpenSkills: () => void;
  onOpenPlugins: () => void;
  onCloseThreadNotePanel: () => void;
  onBackToThreads: () => void;
  onRefreshAppState: () => void;
  onOpenAssistant: () => void;
  appState: OpenAssistAppState;
  providerModelOptionsByBackend: Partial<Record<ProviderKey, ProviderModelOption[]>>;
  selectedThreadID?: string;
  selectedProjectID?: string;
  threadDetail: ThreadDetail | null;
  selectedNoteID?: string;
  selectedNoteTarget?: SelectedNoteTarget | null;
  notesScope: NotesScope;
  noteDetail: NoteDetail | null;
  noteDraft: string;
  noteSaveStatus: NoteSaveStatus;
  composerText: string;
  isSending: boolean;
  interactionMode: string;
  permissionMode: CodexPermissionMode;
  reasoningEffort: string;
  voiceStatus: VoiceInputStatus;
  voiceStatusText?: string;
  voiceError?: string;
  liveVoiceStatus: LiveVoiceStatus;
  liveVoiceStatusText?: string;
  providerStatus?: string | null;
  selectedPluginID?: string;
  selectedPluginIDs: string[];
  onComposerText: (value: string) => void;
  onSend: () => void;
  onStop: () => void;
  onVoiceInput: () => void;
  onLiveVoice: () => void;
  onOpenRealtimeSettings: () => void;
  onToggleAgentic: () => void;
  onCycleReasoning: () => void;
  onSelectPermissionMode: (mode: CodexPermissionMode) => void;
  onCreateTemporaryThread: () => void;
  onAddTextToThreadNote: (text: string) => void;
  onSpeakText: (text: string) => void | Promise<void>;
  onRespondToApproval: ApprovalResponder;
  onSelectProvider: (provider: ProviderKey) => void;
  onSelectModel: (model: string) => void;
  onSelectNotesProject: (projectID: string) => void;
  onSelectNotesScope: (scope: NotesScope) => void;
  onSelectNote: (note: NoteItem) => void;
  onSelectThreadNoteItem: (note: ThreadNoteListItem) => void;
  onCreateNote: () => void;
  onNoteDraft: (value: string) => void;
  onSaveNote: () => void;
  onToggleAutomation: (job: AutomationItem) => void;
  onCreateAutomation: (name: string, prompt: string) => Promise<void>;
  onToggleSkill: (skill: SkillItem) => void;
  onImportSkillFolder: () => Promise<void>;
  onImportSkillFromGitHub: (reference: string) => Promise<void>;
  onCreateSkill: (name: string, description: string) => Promise<void>;
  onSavePromptRewriteAPIKey: (provider: string, token: string) => Promise<SettingsSnapshot | undefined>;
  onClearPromptRewriteAPIKey: (provider: string) => Promise<SettingsSnapshot | undefined>;
  onSaveCloudTranscriptionAPIKey: (provider: string, token: string) => Promise<SettingsSnapshot | undefined>;
  onClearCloudTranscriptionAPIKey: (provider: string) => Promise<SettingsSnapshot | undefined>;
  onUpdateSetting: (key: SettingsUpdateKey, value: SettingsUpdateValue) => void;
  onUpdateShortcut: (target: ShortcutTarget, keyCode: number, modifiers: number) => Promise<SettingsSnapshot | undefined>;
  onSelectPlugin: (pluginID: string) => void;
  onTogglePluginUse: (pluginID: string) => void;
  onUseStarterPrompt: (pluginID: string, prompt: string) => void;
}) {
  const providerOptions = availableRuntimeProviderOptions(appState.settings);
  const selectedThread = appState.threads.find((thread) => thread.id === selectedThreadID);
  const activeProviderKey = runtimeProviderKey(selectedThread?.activeProvider || appState.settings.assistantBackend || "codex");
  const activeProviderName = providerLabel(activeProviderKey);
  const activeModelOptions = providerModelOptionsByBackend[activeProviderKey];
  const activeModelName = displayModelForProvider(activeProviderKey, selectedThread, appState.settings, activeModelOptions);
  const activeUsage = usageForProvider(appState, activeProviderKey);
  const activeThreadWorkspacePath = linkedFolderPathForProject(appState.projects, selectedThread?.projectID ?? selectedProjectID);
  const activeNotesWorkspacePath = linkedFolderPathForProject(appState.projects, selectedProjectID ?? appState.activeProjectID);
  switch (activeView) {
    case "notes":
      return (
        <NotesView
          compact={compact}
          onToggleCompact={onToggleCompact}
          onHideWindow={onHideWindow}
          onOpenInstructions={onOpenInstructions}
          onOpenMemory={onOpenMemory}
          workspaceRootPath={activeNotesWorkspacePath}
          projects={appState.projects}
          selectedProjectID={selectedProjectID}
          notesScope={notesScope}
          notes={appState.notes}
          threadNotes={appState.threadNotes}
          noteFolders={appState.noteFolders}
          activeNoteTarget={selectedNoteTarget ?? (selectedNoteID ? { scope: "project", projectID: appState.activeProjectID ?? "", noteID: selectedNoteID } : null)}
          noteDetail={noteDetail}
          noteDraft={noteDraft}
          noteSaveStatus={noteSaveStatus}
          onSelectProject={onSelectNotesProject}
          onSelectScope={onSelectNotesScope}
          onSelectNote={onSelectNote}
          onSelectThreadNoteItem={onSelectThreadNoteItem}
          onCreateNote={onCreateNote}
          onNoteDraft={onNoteDraft}
          onSaveNote={onSaveNote}
        />
      );
    case "history":
      return <TranscriptHistoryView />;
    case "automations":
      return <AutomationsView automations={appState.automations} onToggle={onToggleAutomation} onCreate={onCreateAutomation} />;
    case "skills":
      return (
        <SkillsView
          skills={appState.skills}
          onToggleSkill={onToggleSkill}
          onBack={onBackToThreads}
          onRefresh={onRefreshAppState}
          onImportFolder={onImportSkillFolder}
          onImportGitHub={onImportSkillFromGitHub}
          onCreateSkill={onCreateSkill}
        />
      );
    case "plugins":
      return (
        <PluginsView
          plugins={appState.plugins}
          selectedPluginID={selectedPluginID}
          selectedPluginIDs={selectedPluginIDs}
          onSelectPlugin={onSelectPlugin}
          onTogglePluginUse={onTogglePluginUse}
          onUseStarterPrompt={onUseStarterPrompt}
          onOpenChat={onOpenAssistant}
          onBack={onBackToThreads}
          onRefresh={onRefreshAppState}
        />
      );
    case "settings":
      return (
        <SettingsView
          initialSection={settingsInitialSection}
          onOpenAssistant={onOpenAssistant}
          onRefresh={onRefreshAppState}
          onOpenTarget={async () => ({ ok: false, error: "Open target is unavailable from this view." })}
          onSaveTelegramBotToken={async () => undefined}
          onClearTelegramBotToken={async () => undefined}
          onApproveTelegramPairing={async () => undefined}
          onDeclineTelegramPairing={async () => undefined}
          onForgetTelegramPairing={async () => undefined}
          onTestTelegramConnection={async () => undefined}
          onSavePromptRewriteAPIKey={onSavePromptRewriteAPIKey}
          onClearPromptRewriteAPIKey={onClearPromptRewriteAPIKey}
          onSaveCloudTranscriptionAPIKey={onSaveCloudTranscriptionAPIKey}
          onClearCloudTranscriptionAPIKey={onClearCloudTranscriptionAPIKey}
          onSaveRealtimeOpenAIAPIKey={async () => undefined}
          onClearRealtimeOpenAIAPIKey={async () => undefined}
          onUpdateSetting={onUpdateSetting}
          onUpdateShortcut={onUpdateShortcut}
          settings={appState.settings}
        />
      );
    case "threads":
    default:
      return (
        <ThreadsView
          compact={compact}
          onToggleCompact={onToggleCompact}
          onHideWindow={onHideWindow}
          onOpenThreadNote={onOpenThreadNote}
          onOpenInstructions={onOpenInstructions}
          onOpenMemory={onOpenMemory}
          onOpenSkills={onOpenSkills}
          onOpenPlugins={onOpenPlugins}
          onCloseThreadNotePanel={onCloseThreadNotePanel}
          title={threadDetail?.title || appState.threads.find((thread) => thread.id === selectedThreadID)?.title || "Ok"}
          providerName={activeProviderName}
          providerKey={activeProviderKey}
          providerOptions={providerOptions}
          modelName={activeModelName}
          modelOptions={activeModelOptions}
          workspaceRootPath={activeThreadWorkspacePath}
          providerStatus={providerStatus}
          usage={activeUsage}
          interactionMode={interactionMode}
          permissionMode={permissionMode}
          reasoningEffort={reasoningEffort}
          messages={threadDetail?.messages ?? []}
          composerText={composerText}
          isSending={isSending}
          voiceStatus={voiceStatus}
          voiceStatusText={voiceStatusText}
          voiceError={voiceError}
          liveVoiceStatus={liveVoiceStatus}
          liveVoiceStatusText={liveVoiceStatusText}
          plugins={appState.plugins}
          skills={appState.skills}
          onComposerText={onComposerText}
          onSend={onSend}
          onStop={onStop}
          onVoiceInput={onVoiceInput}
          onLiveVoice={onLiveVoice}
          onOpenRealtimeSettings={onOpenRealtimeSettings}
          onToggleAgentic={onToggleAgentic}
          onCycleReasoning={onCycleReasoning}
          onSelectPermissionMode={onSelectPermissionMode}
          onCreateTemporaryThread={onCreateTemporaryThread}
          onAddTextToThreadNote={onAddTextToThreadNote}
          onSpeakText={onSpeakText}
          onRespondToApproval={onRespondToApproval}
          onSelectProvider={onSelectProvider}
          onSelectModel={onSelectModel}
        />
      );
  }
}

const SIDEBAR_WIDTH_KEY = "openassist.sidebarWidth";
const SIDEBAR_HIDDEN_KEY = "openassist.sidebarHidden";
const SIDEBAR_MIN_WIDTH = 220;
const SIDEBAR_MAX_WIDTH = 480;
const SIDEBAR_DEFAULT_WIDTH = 298;

function readStoredSidebarWidth(): number {
  if (typeof window === "undefined") return SIDEBAR_DEFAULT_WIDTH;
  const stored = window.localStorage.getItem(SIDEBAR_WIDTH_KEY);
  const parsed = stored ? Number.parseInt(stored, 10) : Number.NaN;
  if (!Number.isFinite(parsed)) return SIDEBAR_DEFAULT_WIDTH;
  return Math.min(SIDEBAR_MAX_WIDTH, Math.max(SIDEBAR_MIN_WIDTH, parsed));
}

function SidebarResizeHandle({
  width,
  onResize,
  onResizingChange
}: {
  width: number;
  onResize: (next: number) => void;
  onResizingChange: (resizing: boolean) => void;
}) {
  const [dragging, setDragging] = useState(false);

  const onPointerDown = (event: React.PointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return;
    event.preventDefault();
    setDragging(true);
    onResizingChange(true);
    const startX = event.clientX;
    const startWidth = width;
    const previousCursor = document.body.style.cursor;
    document.body.style.cursor = "col-resize";

    const onMove = (ev: PointerEvent) => {
      const delta = ev.clientX - startX;
      const next = Math.min(SIDEBAR_MAX_WIDTH, Math.max(SIDEBAR_MIN_WIDTH, startWidth + delta));
      onResize(next);
    };

    const onUp = () => {
      setDragging(false);
      onResizingChange(false);
      document.body.style.cursor = previousCursor;
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
    };

    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  };

  return (
    <div
      className={cx("sidebar-resize-handle", dragging && "is-dragging")}
      onPointerDown={onPointerDown}
      role="separator"
      aria-orientation="vertical"
      aria-label="Resize sidebar"
    />
  );
}

export function App() {
  const standaloneWindow = typeof window !== "undefined"
    ? new URLSearchParams(window.location.search).get("window")
    : null;
  const initialSettingsSection = typeof window !== "undefined"
    ? settingsKeyFromString(new URLSearchParams(window.location.search).get("section"))
    : undefined;
  if (standaloneWindow === "history") return <TranscriptHistoryWindow />;
  const isSettingsWindow = standaloneWindow === "settings";

  const [activeView, setActiveView] = useState<ViewKey>(isSettingsWindow ? "settings" : "threads");
  const [settingsInitialSection, setSettingsInitialSection] = useState<SettingsKey>(initialSettingsSection ?? "assistant");
  const [compact, setCompact] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [sidebarWidth, setSidebarWidth] = useState<number>(readStoredSidebarWidth);
  const [isResizingSidebar, setIsResizingSidebar] = useState(false);
  const [sidebarHidden, setSidebarHidden] = useState<boolean>(
    () => typeof window !== "undefined" && window.localStorage.getItem(SIDEBAR_HIDDEN_KEY) === "1"
  );
  const [systemThemeMode, setSystemThemeMode] = useState<"dark" | "light">(readSystemThemeMode);

  useEffect(() => {
    window.localStorage.setItem(SIDEBAR_WIDTH_KEY, String(sidebarWidth));
  }, [sidebarWidth]);

  useEffect(() => {
    window.localStorage.setItem(SIDEBAR_HIDDEN_KEY, sidebarHidden ? "1" : "0");
  }, [sidebarHidden]);

  useEffect(() => {
    return window.openAssistElectron?.onSettingsSection?.((section) => {
      const nextSection = settingsKeyFromString(section);
      if (!nextSection) return;
      setSettingsInitialSection(nextSection);
      setActiveView("settings");
    });
  }, []);

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return undefined;
    const query = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => setSystemThemeMode(query.matches ? "dark" : "light");
    onChange();
    query.addEventListener?.("change", onChange);
    return () => query.removeEventListener?.("change", onChange);
  }, []);
  const [appState, setAppState] = useState<OpenAssistAppState>(() => ({
    projects: [],
    hiddenProjects: [],
    threads: [],
    notes: [],
    threadNotes: [],
    noteFolders: [],
    automations: [],
    skills: [],
    plugins: [],
    usage: null,
    settings: {
      appVersion: "1.0.7",
      buildNumber: "69",
      assistantBackend: "codex",
      availableAssistantBackends: ["codex", "copilot", "claudeCode", "ollamaLocal"],
      assistantRuntimeStatus: "Checking",
      assistantRuntimeDetail: "Reading the selected runtime status.",
      assistantRuntimeAccount: "Not connected",
      assistantRuntimeAuthMode: "Not connected",
      assistantRuntimeLoginCommand: "codex login",
      assistantRuntimeStatusTone: "muted",
      model: "GPT-5.5",
      subAgentModel: "Same as main model",
      compactStyle: "sidebar",
      compactEdge: "right",
      themeMode: "System",
      colorTheme: "Ocean",
      appChromeStyle: "Glass (High Contrast)",
      lightThemeAccent: "#0169CC",
      lightThemeBackground: "#FFFFFF",
      lightThemeForeground: "#0D0D0D",
      lightThemeUIFont: systemUIFontStack,
      lightThemeCodeFont: "ui-monospace, SFMono-Regular, Menlo, monospace",
      lightThemeTranslucentSidebar: false,
      lightThemeContrast: "45",
      lightThemeCodeThemeID: "codex",
      lightThemeDiffAdded: "#00a240",
      lightThemeDiffRemoved: "#ba2623",
      lightThemeSkill: "#924ff7",
      darkThemeAccent: "#1F6FEB",
      darkThemeBackground: "#0D1117",
      darkThemeForeground: "#E6EDF3",
      darkThemeUIFont: systemUIFontStack,
      darkThemeCodeFont: "ui-monospace, SFMono-Regular, Menlo, monospace",
      darkThemeTranslucentSidebar: true,
      darkThemeContrast: "89",
      darkThemeCodeThemeID: "github",
      darkThemeDiffAdded: "#40c977",
      darkThemeDiffRemoved: "#fa423e",
      darkThemeSkill: "#ad7bf9",
      pointerCursors: false,
      reduceMotionMode: "System",
      uiFontSize: "13",
      codeFontSize: "12",
      assistantEnabled: false,
      assistantFloatingHUDEnabled: true,
      voiceEnabled: true,
      realtimeVoiceEnabled: true,
      realtimeOpenAIAPIKeyConfigured: false,
      realtimeDedicatedOpenAIAPIKeyConfigured: false,
      realtimeOpenAIAPIKeySource: "missing",
      realtimeMaskedOpenAIAPIKey: "Not configured",
      realtimeOpenAIModel: "gpt-realtime-mini",
      realtimeOpenAIVoice: "marin",
      assistantVoiceOutputEnabled: false,
      computerUseEnabled: false,
      memoryEnabled: true,
      assistantTrackCodeChangesInGitRepos: true,
      automationAPIPort: "45831",
      browserProfile: "Default",
      holdToTalkShortcut: "Control Option Command Space",
      holdToTalkShortcutKeyCode: 49,
      holdToTalkShortcutModifiers: modifierFlags.control | modifierFlags.shift,
      continuousToggleShortcut: "Control Option Command Space",
      continuousToggleShortcutKeyCode: 49,
      continuousToggleShortcutModifiers: modifierFlags.control | modifierFlags.option | modifierFlags.command,
      assistantLiveVoiceShortcut: "Control Option Command L",
      assistantLiveVoiceShortcutKeyCode: 37,
      assistantLiveVoiceShortcutModifiers: modifierFlags.control | modifierFlags.option | modifierFlags.command,
      assistantCompactShortcut: "Control Option Command S",
	      assistantCompactShortcutKeyCode: 1,
	      assistantCompactShortcutModifiers: modifierFlags.control | modifierFlags.option | modifierFlags.command,
	      transcriptionEngine: "Apple Speech",
	      autoDetectMicrophone: true,
	      selectedMicrophoneUID: "",
	      availableMicrophones: [],
	      whisperModel: "base.en",
      whisperUseCoreML: true,
      whisperInstalledModels: [],
      whisperModelInstalled: false,
      voiceEngine: "humeOctave",
      waveformTheme: "Vibrant Spectrum",
      telegramEnabled: false,
      telegramBotToken: "",
      telegramMaskedToken: "Not configured",
      telegramTokenConfigured: false,
      telegramOwnerUserID: "",
      telegramOwnerChatID: "",
      telegramPendingUserID: "",
      telegramPendingChatID: "",
      telegramPendingDisplayName: "",
      telegramSelectedSessionID: "",
      telegramBotUsername: "",
      remoteAccessEnabled: false,
      remoteAccessPort: "45831",
      remoteAccessPublicURL: "",
      localAIRuntimeVersion: "Unknown",
      promptRewriteProvider: "Ollama (Local)",
      promptRewriteModel: "llama3.1",
      promptRewriteBaseURL: "http://localhost:11434/v1",
      promptRewriteAPIKeyConfigured: false,
      promptRewriteMaskedAPIKey: "Not required",
      cloudTranscriptionProvider: "OpenAI",
      cloudTranscriptionModel: "gpt-4o-mini-transcribe",
      cloudTranscriptionBaseURL: "https://api.openai.com/v1",
      cloudTranscriptionAPIKeyConfigured: false,
      cloudTranscriptionMaskedAPIKey: "Not configured",
      dictationStartSoundName: "Ping",
      dictationStopSoundName: "Glass",
      dictationProcessingSoundName: "Ping",
      dictationPastedSoundName: "Pop",
      dictationCorrectionLearnedSoundName: "Purr",
      dictationFeedbackVolume: 0.10,
      assistantTextScale: "1.0"
    }
  }));
  const [providerModelOptionsByBackend, setProviderModelOptionsByBackend] = useState<Partial<Record<ProviderKey, ProviderModelOption[]>>>({});
  const [selectedThreadID, setSelectedThreadID] = useState<string | undefined>(undefined);
  const [selectedProjectID, setSelectedProjectID] = useState<string | undefined>(undefined);
  const [showArchivedThreads, setShowArchivedThreads] = useState(false);
  const [threadDetail, setThreadDetail] = useState<ThreadDetail | null>(null);
  const [selectedNoteID, setSelectedNoteID] = useState<string | undefined>(undefined);
  const [selectedNoteTarget, setSelectedNoteTarget] = useState<SelectedNoteTarget | null>(null);
  const [notesScope, setNotesScope] = useState<NotesScope>("project");
  const [noteDetail, setNoteDetail] = useState<NoteDetail | null>(null);
  const [noteDraft, setNoteDraft] = useState("");
  const [noteSaveStatus, setNoteSaveStatus] = useState<NoteSaveStatus>({ kind: "idle" });
  const [selectedPluginID, setSelectedPluginID] = useState<string | undefined>(undefined);
  const [selectedPluginIDs, setSelectedPluginIDs] = useState<string[]>([]);
  const [composerText, setComposerText] = useState("");
  const [isSending, setIsSending] = useState(false);
  const activeProviderRunIDRef = useRef<string | null>(null);
  const stopRequestedRef = useRef(false);
  const [interactionMode, setInteractionMode] = useState("Agentic");
  const [permissionMode, setPermissionMode] = useState<CodexPermissionMode>("fullAccess");
  const [reasoningEffort, setReasoningEffort] = useState("High");
  const [voiceStatus, setVoiceStatus] = useState<VoiceInputStatus>("idle");
  const [voiceStatusText, setVoiceStatusText] = useState<string | undefined>(undefined);
  const [voiceError, setVoiceError] = useState<string | undefined>(undefined);
  const [liveVoiceStatus, setLiveVoiceStatus] = useState<LiveVoiceStatus>("idle");
  const [liveVoiceStatusText, setLiveVoiceStatusText] = useState<string | undefined>(undefined);
  const [appWindowFocused, setAppWindowFocused] = useState(() =>
    typeof document !== "undefined" ? document.hasFocus() : true
  );
  const [providerStatus, setProviderStatus] = useState<string | null>(null);
  const [assistantPanel, setAssistantPanel] = useState<AssistantPanelKey>(null);
  const [sessionInstructions, setSessionInstructions] = useState("");
  const [threadNoteWorkspace, setThreadNoteWorkspace] = useState<ThreadNoteWorkspace | null>(null);
  const [threadNoteDraft, setThreadNoteDraft] = useState("");
  const [threadMemory, setThreadMemory] = useState<ThreadMemorySnapshot | null>(null);
  const recognitionRef = useRef<SpeechRecognitionLike | null>(null);
  const selectThreadRequestRef = useRef(0);
  const nativeVoiceActiveRef = useRef(false);
  const nativeVoiceOperationRef = useRef(false);
  const nativeVoiceStopAfterStartRef = useRef(false);
  const voiceBaseTextRef = useRef("");
  const voiceFinalTextRef = useRef("");
  const liveVoiceStreamRef = useRef<MediaStream | null>(null);
  const liveVoiceInputContextRef = useRef<AudioContext | null>(null);
  const liveVoiceOutputContextRef = useRef<AudioContext | null>(null);
  const liveVoiceProcessorRef = useRef<ScriptProcessorNode | null>(null);
  const liveVoiceSourceRef = useRef<MediaStreamAudioSourceNode | null>(null);
  const liveVoiceChunkTimerRef = useRef<number | null>(null);
  const liveVoiceInputChunksRef = useRef<Float32Array[]>([]);
  const liveVoiceActiveRef = useRef(false);
  const liveVoiceStatusRef = useRef<LiveVoiceStatus>("idle");
  const liveVoiceExpectedStopRef = useRef(false);
  const liveVoiceOutputSourcesRef = useRef<Set<AudioBufferSourceNode>>(new Set());
  const liveVoicePlaybackTimeRef = useRef(0);
  const liveVoiceScopeRef = useRef("");
  const noteDraftRef = useRef("");
  const noteDetailRef = useRef<NoteDetail | null>(null);
  const selectedNoteTargetRef = useRef<SelectedNoteTarget | null>(null);
  const activeViewRef = useRef<ViewKey>(activeView);
  const selectedThreadIDRef = useRef<string | undefined>(undefined);
  const noteAutosaveTimerRef = useRef<number | null>(null);
  const noteSaveRequestRef = useRef(0);
  const lastSavedNoteKeyRef = useRef<string | null>(null);
  const lastSavedNoteDraftRef = useRef("");

  const shellClass = useMemo(
    () => {
      const resolvedMode = resolveThemeMode(appState.settings.themeMode, systemThemeMode);
      const prefix = resolvedMode === "light" ? "lightTheme" : "darkTheme";
      const translucentSidebar = Boolean(appState.settings[`${prefix}TranslucentSidebar` as keyof SettingsSnapshot]);
      return cx(
        "app-shell",
        `mode-${resolvedMode}`,
        translucentSidebar ? "sidebar-translucent" : "sidebar-solid",
        `theme-mode-${normalizeThemeMode(appState.settings.themeMode)}`,
        `theme-${cssKey(appState.settings.colorTheme || "Ocean")}`,
        `chrome-${cssKey(appState.settings.appChromeStyle || "Glass (High Contrast)")}`,
        `reduce-motion-${cssKey(appState.settings.reduceMotionMode || "System")}`,
        appState.settings.pointerCursors && "pointer-cursors",
        compact && "compact-mode",
        compact && appState.settings.compactEdge === "left" && "sidebar-left",
        compact && !sidebarOpen && "sidebar-collapsed",
        !compact && sidebarHidden && "sidebar-hidden",
        activeView === "settings" && "settings-mode",
        isResizingSidebar && "sidebar-resizing"
      );
    },
    [
      activeView,
      appState.settings.appChromeStyle,
      appState.settings.colorTheme,
      appState.settings.compactEdge,
      appState.settings.pointerCursors,
      appState.settings.reduceMotionMode,
      appState.settings.themeMode,
      compact,
      isResizingSidebar,
      sidebarHidden,
      sidebarOpen,
      systemThemeMode
    ]
  );
  const shellStyle = useMemo<CSSProperties | undefined>(
    () => {
      const resolvedMode = resolveThemeMode(appState.settings.themeMode, systemThemeMode);
      const prefix = resolvedMode === "light" ? "lightTheme" : "darkTheme";
      const accent = String(appState.settings[`${prefix}Accent` as keyof SettingsSnapshot] || (resolvedMode === "light" ? "#0169CC" : "#1F6FEB"));
      const background = String(appState.settings[`${prefix}Background` as keyof SettingsSnapshot] || (resolvedMode === "light" ? "#FFFFFF" : "#0D1117"));
      const foreground = String(appState.settings[`${prefix}Foreground` as keyof SettingsSnapshot] || (resolvedMode === "light" ? "#0D0D0D" : "#E6EDF3"));
      const uiFont = normalizeUIFontValue(appState.settings[`${prefix}UIFont` as keyof SettingsSnapshot]);
      const codeFont = String(appState.settings[`${prefix}CodeFont` as keyof SettingsSnapshot] || "ui-monospace, SFMono-Regular, Menlo, monospace");
      const contrast = String(appState.settings[`${prefix}Contrast` as keyof SettingsSnapshot] || "70");
      const contrastNumber = Math.min(100, Math.max(0, Number(contrast) || 70));
      const diffAdded = String(appState.settings[`${prefix}DiffAdded` as keyof SettingsSnapshot] || (resolvedMode === "light" ? "#00a240" : "#40c977"));
      const diffRemoved = String(appState.settings[`${prefix}DiffRemoved` as keyof SettingsSnapshot] || (resolvedMode === "light" ? "#ba2623" : "#fa423e"));
      const skill = String(appState.settings[`${prefix}Skill` as keyof SettingsSnapshot] || (resolvedMode === "light" ? "#924ff7" : "#ad7bf9"));
      const codeThemeID = String(appState.settings[`${prefix}CodeThemeID` as keyof SettingsSnapshot] || codexThemeDefaults[resolvedMode].codeThemeId);
      const codePalette = codexSeedFor(codeThemeID, resolvedMode);
      const translucentSidebar = Boolean(appState.settings[`${prefix}TranslucentSidebar` as keyof SettingsSnapshot]);
      const percent = (value: number) => `${Math.round(value)}%`;
      const style = {
        "--theme-accent": accent,
        "--theme-background": background,
        "--theme-foreground": foreground,
        "--theme-ui-font": uiFont,
        "--theme-code-font": codeFont,
        "--theme-contrast": contrast,
        "--theme-diff-added": diffAdded,
        "--theme-diff-removed": diffRemoved,
        "--theme-skill": skill,
        "--theme-surface-mix": percent(2 + contrastNumber * 0.09),
        "--theme-surface-strong-mix": percent(4 + contrastNumber * 0.11),
        "--theme-surface-hover-mix": percent(7 + contrastNumber * 0.11),
        "--theme-line-mix": percent(5 + contrastNumber * 0.11),
        "--theme-line-strong-mix": percent(8 + contrastNumber * 0.13),
        "--theme-chrome-mix": translucentSidebar ? (resolvedMode === "light" ? "64%" : "48%") : (resolvedMode === "light" ? "94%" : "92%"),
        "--theme-sidebar-base-mix": translucentSidebar
          ? (resolvedMode === "light" ? "38%" : "30%")
          : (resolvedMode === "light" ? "94%" : "92%"),
        "--theme-sidebar-highlight-mix": translucentSidebar
          ? (resolvedMode === "light" ? "9%" : "8%")
          : (resolvedMode === "light" ? "5%" : "3%"),
        "--theme-sidebar-shadow-alpha": translucentSidebar
          ? (resolvedMode === "light" ? "0" : "0.05")
          : (resolvedMode === "light" ? "0" : "0.18"),
        "--theme-sidebar-shadow-strong-alpha": translucentSidebar
          ? (resolvedMode === "light" ? "0" : "0.11")
          : (resolvedMode === "light" ? "0" : "0.32"),
        "--theme-sidebar-blur": translucentSidebar ? "56px" : "18px",
        "--note-code-keyword": codePalette.keyword,
        "--note-code-builtin": codePalette.builtin,
        "--note-code-function": codePalette.function,
        "--note-code-class": codePalette.builtin,
        "--note-code-number": codePalette.number,
        "--note-code-string": codePalette.string,
        "--note-code-comment": codePalette.comment,
        "--note-code-property": codePalette.builtin,
        "--note-code-tag": codePalette.keyword,
        "--note-code-attr-name": codePalette.function,
        "--note-code-attr-value": codePalette.string,
        "--note-code-selector": codePalette.builtin,
        "--note-code-variable": codePalette.keyword,
        "--note-code-inserted": diffAdded,
        "--note-code-deleted": diffRemoved,
        "--ui-font-size": `${Number(normalizeUIFontSize(appState.settings.uiFontSize)) || 13}px`,
        "--code-font-size": `${Number(appState.settings.codeFontSize) || 12}px`
      } as CSSProperties & Record<string, string>;
      if (!compact) {
        style["--sidebar-width"] = `${sidebarHidden ? 0 : sidebarWidth}px`;
      }
      return style;
    },
    [
	      appState.settings.codeFontSize,
	      appState.settings.darkThemeAccent,
	      appState.settings.darkThemeBackground,
	      appState.settings.darkThemeCodeFont,
	      appState.settings.darkThemeCodeThemeID,
	      appState.settings.darkThemeContrast,
	      appState.settings.darkThemeDiffAdded,
	      appState.settings.darkThemeDiffRemoved,
	      appState.settings.darkThemeForeground,
	      appState.settings.darkThemeSkill,
	      appState.settings.darkThemeTranslucentSidebar,
	      appState.settings.darkThemeUIFont,
	      appState.settings.lightThemeAccent,
	      appState.settings.lightThemeBackground,
	      appState.settings.lightThemeCodeFont,
	      appState.settings.lightThemeCodeThemeID,
	      appState.settings.lightThemeContrast,
	      appState.settings.lightThemeDiffAdded,
	      appState.settings.lightThemeDiffRemoved,
	      appState.settings.lightThemeForeground,
	      appState.settings.lightThemeSkill,
	      appState.settings.lightThemeTranslucentSidebar,
	      appState.settings.lightThemeUIFont,
      appState.settings.themeMode,
      appState.settings.uiFontSize,
      compact,
      sidebarHidden,
      sidebarWidth,
      systemThemeMode
    ]
  );
  const selectedThread = appState.threads.find((thread) => thread.id === selectedThreadID);
  const activeProviderKey = runtimeProviderKey(selectedThread?.activeProvider || appState.settings.assistantBackend || "codex");
  const activeProviderName = providerLabel(activeProviderKey);

  useEffect(() => {
    noteDraftRef.current = noteDraft;
  }, [noteDraft]);

  useEffect(() => {
    noteDetailRef.current = noteDetail;
  }, [noteDetail]);

  useEffect(() => {
    selectedNoteTargetRef.current = selectedNoteTarget;
  }, [selectedNoteTarget]);

  useEffect(() => {
    selectedThreadIDRef.current = selectedThreadID;
  }, [selectedThreadID]);

  useEffect(() => {
    liveVoiceStatusRef.current = liveVoiceStatus;
  }, [liveVoiceStatus]);

  useEffect(() => {
    const key = noteTargetKey(selectedNoteTarget);
    if (!key || !noteDetail) {
      lastSavedNoteKeyRef.current = null;
      lastSavedNoteDraftRef.current = "";
      setNoteSaveStatus({ kind: "idle" });
      return;
    }
    if (lastSavedNoteKeyRef.current !== key) {
      lastSavedNoteKeyRef.current = key;
      lastSavedNoteDraftRef.current = noteDetail.markdown;
      setNoteSaveStatus({ kind: "saved", at: Date.now() });
    }
  }, [noteDetail, selectedNoteTarget]);

  function clearNoteAutosaveTimer() {
    if (noteAutosaveTimerRef.current !== null) {
      window.clearTimeout(noteAutosaveTimerRef.current);
      noteAutosaveTimerRef.current = null;
    }
  }

  async function persistNoteDraft(reason = "autosave") {
    const target = selectedNoteTargetRef.current;
    const detail = noteDetailRef.current;
    const key = noteTargetKey(target);
    if (!target || !detail || !key) return true;

    const draft = noteDraftRef.current.replace(/\r\n/g, "\n");
    if (lastSavedNoteKeyRef.current === key && lastSavedNoteDraftRef.current === draft) {
      return true;
    }

    const requestID = ++noteSaveRequestRef.current;
    setNoteSaveStatus({ kind: "saving", message: reason === "manual" ? "Saving..." : "Autosaving..." });
    try {
      if (target.scope === "thread") {
        const workspace = await window.openAssistElectron?.saveThreadNote(
          target.threadID,
          target.noteID,
          draft
        );
        if (!workspace?.selectedNote) throw new Error("Thread note did not save.");
        const savedNote = workspace.selectedNote;
        if (noteTargetKey(selectedNoteTargetRef.current) === key) {
          setThreadNoteWorkspace(workspace);
          setThreadNoteDraft(savedNote.markdown);
          setNoteDetail({
            id: savedNote.id,
            title: savedNote.title,
            markdown: savedNote.markdown,
            path: savedNote.path
          });
          const savedAt = Date.now();
          setAppState((current) => ({
            ...current,
            threadNotes: current.threadNotes.map((item) =>
              sameID(item.id, savedNote.id) && sameID(item.threadID, target.threadID)
                ? { ...item, subtitle: `${item.threadTitle} · Saved just now`, updatedAt: savedAt }
                : item
            )
          }));
        }
      } else {
        const savedDetail = await window.openAssistElectron?.saveNote(target.projectID, target.noteID, draft);
        if (!savedDetail) throw new Error("Project note did not save.");
        if (noteTargetKey(selectedNoteTargetRef.current) === key) {
          setNoteDetail(savedDetail);
          setAppState((current) => ({
            ...current,
            notes: current.notes.map((item) =>
              sameID(item.id, savedDetail.id) && sameID(item.projectID, target.projectID)
                ? { ...item, subtitle: "Saved just now", updatedAt: Date.now() }
                : item
            )
          }));
        }
      }

      lastSavedNoteKeyRef.current = key;
      lastSavedNoteDraftRef.current = draft;
      if (requestID === noteSaveRequestRef.current && noteTargetKey(selectedNoteTargetRef.current) === key) {
        if (noteDraftRef.current.replace(/\r\n/g, "\n") === draft) {
          setNoteSaveStatus({ kind: "saved", at: Date.now() });
        } else {
          setNoteSaveStatus({ kind: "dirty", message: "Unsaved changes" });
          clearNoteAutosaveTimer();
          noteAutosaveTimerRef.current = window.setTimeout(() => {
            noteAutosaveTimerRef.current = null;
            void persistNoteDraft();
          }, 700);
        }
      }
      return true;
    } catch (error) {
      if (requestID === noteSaveRequestRef.current && noteTargetKey(selectedNoteTargetRef.current) === key) {
        setNoteSaveStatus({
          kind: "error",
          message: error instanceof Error ? error.message : "Could not save note"
        });
      }
      return false;
    }
  }

  async function flushNoteDraftBeforeNavigation() {
    clearNoteAutosaveTimer();
    return persistNoteDraft("navigation");
  }

  useEffect(() => {
    const key = noteTargetKey(selectedNoteTarget);
    if (!key || !noteDetail) return;
    if (lastSavedNoteKeyRef.current === key && lastSavedNoteDraftRef.current === noteDraft.replace(/\r\n/g, "\n")) {
      return;
    }
    setNoteSaveStatus({ kind: "dirty", message: "Unsaved changes" });
    clearNoteAutosaveTimer();
    noteAutosaveTimerRef.current = window.setTimeout(() => {
      noteAutosaveTimerRef.current = null;
      void persistNoteDraft();
    }, 900);
    return clearNoteAutosaveTimer;
  }, [noteDraft, noteDetail, selectedNoteTarget]);

  useEffect(() => {
    const previousView = activeViewRef.current;
    activeViewRef.current = activeView;
    if (previousView === "notes" && activeView !== "notes") {
      void flushNoteDraftBeforeNavigation();
    }
  }, [activeView]);

  useEffect(() => {
    const flushIfNeeded = () => {
      void flushNoteDraftBeforeNavigation();
    };
    const flushOnHidden = () => {
      if (document.visibilityState === "hidden") flushIfNeeded();
    };
    window.addEventListener("pagehide", flushIfNeeded);
    window.addEventListener("beforeunload", flushIfNeeded);
    document.addEventListener("visibilitychange", flushOnHidden);
    return () => {
      window.removeEventListener("pagehide", flushIfNeeded);
      window.removeEventListener("beforeunload", flushIfNeeded);
      document.removeEventListener("visibilitychange", flushOnHidden);
      clearNoteAutosaveTimer();
    };
  }, []);

  const refreshMicrophoneList = async () => {
    const microphones = await window.openAssistElectron?.listMicrophones?.();
    if (!microphones) return;
    setAppState((current) => ({
      ...current,
      settings: {
        ...current.settings,
        availableMicrophones: microphones
      }
    }));
  };

  useEffect(() => {
    let cancelled = false;
    async function load() {
      const nextState = await window.openAssistElectron?.loadAppState();
      if (!nextState || cancelled) return;
      const normalizedState = normalizeRendererAppState(nextState);
      setAppState(normalizedState);
      void refreshMicrophoneList();
      setSelectedProjectID(undefined);
      const threadID = normalizedState.activeThreadID ?? normalizedState.threads[0]?.id;
      if (threadID) {
        setSelectedThreadID(threadID);
        const detail = await window.openAssistElectron?.loadThread(threadID);
        if (!cancelled && detail) setThreadDetail(detail);
      }
      const note = normalizedState.notes.find((item) => item.id === normalizedState.activeNoteID) ?? normalizedState.notes[0];
      if (note) {
        setSelectedNoteID(note.id);
        setSelectedNoteTarget({ scope: "project", projectID: note.projectID, noteID: note.id });
        setNotesScope("project");
        const detail = await window.openAssistElectron?.loadNote(note.projectID, note.id);
        if (!cancelled && detail) {
          setNoteDetail(detail);
          setNoteDraft(detail.markdown);
        }
      }
      setSelectedPluginID(normalizedState.plugins[0]?.id);
    }
    load().catch(console.error);
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    const selectedThread = appState.threads.find((thread) => thread.id === selectedThreadID);
    const provider = runtimeProviderKey(selectedThread?.activeProvider || appState.settings.assistantBackend || "codex");
    if (providerModelOptionsByBackend[provider]?.length) return undefined;
    let cancelled = false;
    void window.openAssistElectron?.listProviderModels?.(provider)
      .then((models) => {
        if (cancelled || !Array.isArray(models) || !models.length) return;
        setProviderModelOptionsByBackend((current) => ({ ...current, [provider]: models }));
      })
      .catch(console.error);
    return () => {
      cancelled = true;
    };
  }, [appState.settings.assistantBackend, appState.threads, providerModelOptionsByBackend, selectedThreadID]);

  const refreshAppState = async () => {
    const nextState = await window.openAssistElectron?.loadAppState();
    if (!nextState) return;
    const normalizedState = normalizeRendererAppState(nextState);
    setAppState(normalizedState);
    setSelectedProjectID((current) =>
      current && normalizedState.projects.some((project) => sameID(project.id, current)) ? current : undefined
    );
    const threadID = selectedThreadID && normalizedState.threads.some((thread) => thread.id === selectedThreadID)
      ? selectedThreadID
      : normalizedState.activeThreadID ?? normalizedState.threads[0]?.id;
    if (threadID) {
      setSelectedThreadID(threadID);
      const detail = await window.openAssistElectron?.loadThread(threadID);
      if (detail) setThreadDetail(detail);
    } else {
      setSelectedThreadID(undefined);
      setThreadDetail(null);
    }
    if (selectedNoteTarget?.scope === "thread") {
      const note = normalizedState.threadNotes.find((item) =>
        sameID(item.id, selectedNoteTarget.noteID) && sameID(item.threadID, selectedNoteTarget.threadID)
      );
      if (note) {
        setSelectedNoteID(note.id);
        setSelectedProjectID((current) => note.projectID ?? current);
        const workspace = await window.openAssistElectron?.selectThreadNote(note.threadID, note.id);
        if (workspace?.selectedNote) {
          setThreadNoteWorkspace(workspace);
          setThreadNoteDraft(workspace.selectedNote.markdown);
          setNoteDetail({
            id: workspace.selectedNote.id,
            title: workspace.selectedNote.title,
            markdown: workspace.selectedNote.markdown,
            path: workspace.selectedNote.path
          });
          setNoteDraft(workspace.selectedNote.markdown);
        }
      }
    } else {
      const note = normalizedState.notes.find((item) => item.id === selectedNoteID) ?? normalizedState.notes[0];
      if (note) {
        setSelectedNoteID(note.id);
        setSelectedNoteTarget({ scope: "project", projectID: note.projectID, noteID: note.id });
        const detail = await window.openAssistElectron?.loadNote(note.projectID, note.id);
        if (detail) {
          setNoteDetail(detail);
          setNoteDraft(detail.markdown);
        }
      }
    }
    setSelectedPluginID((current) => current ?? normalizedState.plugins[0]?.id);
  };

  const setAssistantWindowMode = (nextCompact: boolean, nextSidebarOpen = true) => {
    setCompact(nextCompact);
    setSidebarOpen(nextCompact ? nextSidebarOpen : true);
    const sidebarEdge = appState.settings.compactEdge === "left" ? "left" : "right";
    void window.openAssistElectron?.setWindowMode(nextCompact ? "sidebar" : "full", nextCompact ? nextSidebarOpen : true, sidebarEdge);
  };

  const openSidebarAssistant = () => {
    setAssistantWindowMode(true, true);
  };

  const openFullAssistant = () => {
    setAssistantWindowMode(false, true);
  };

  const collapseSidebar = () => {
    setAssistantWindowMode(true, false);
  };

  const toggleSidebarPull = () => {
    if (!compact) {
      openSidebarAssistant();
      return;
    }
    setAssistantWindowMode(true, !sidebarOpen);
  };

  const toggleCompact = () => {
    if (compact) {
      openFullAssistant();
      return;
    }
    openSidebarAssistant();
  };

  const hideWindow = () => {
    void window.openAssistElectron?.hideWindow();
  };

  const openAssistant = () => {
    if (isSettingsWindow) {
      void window.openAssistElectron?.menuBarAction("open-assistant");
      return;
    }
    setActiveView("threads");
    openFullAssistant();
  };

  const openSettings = () => {
    setSettingsInitialSection("assistant");
    if (typeof window !== "undefined" && window.sessionStorage.getItem("openassist.verifyInlineSettings") === "1") {
      setActiveView("settings");
      return;
    }
    void window.openAssistElectron?.openSettingsWindow?.("assistant");
  };

  const openRealtimeSettings = () => {
    setSettingsInitialSection("voice");
    if (isSettingsWindow || (typeof window !== "undefined" && window.sessionStorage.getItem("openassist.verifyInlineSettings") === "1")) {
      setActiveView("settings");
      return;
    }
    void window.openAssistElectron?.openSettingsWindow?.("voice");
  };

  const currentThreadID = () => threadDetail?.threadID ?? selectedThreadID;

  const openThreadNoteForThread = async (threadID?: string) => {
    if (!threadID) return;
    setActiveView("threads");
    if (compact && !sidebarOpen) openSidebarAssistant();
    if (threadID !== selectedThreadID) {
      await selectThread(threadID, { syncProjectFilter: false });
    }
    if (assistantPanel === "thread-note" && threadNoteWorkspace?.threadID === threadID) {
      return;
    }
    setAssistantPanel("thread-note");
    const workspace = await window.openAssistElectron?.loadThreadNote(threadID);
    if (workspace) {
      setThreadNoteWorkspace(workspace);
      setThreadNoteDraft(workspace.selectedNote?.markdown ?? "");
    }
  };

  const openThreadNote = async () => {
    await openThreadNoteForThread(currentThreadID());
  };

  const closeThreadNotePanel = () => {
    if (assistantPanel !== "thread-note") return;
    const selectedNoteIDForPanel = threadNoteWorkspace?.selectedNoteID;
    const savedMarkdown = threadNoteWorkspace?.selectedNote?.markdown ?? "";
    const hasUnsavedDraft = Boolean(selectedNoteIDForPanel) && threadNoteDraft !== savedMarkdown;
    setAssistantPanel(null);
    if (hasUnsavedDraft) {
      void saveCurrentThreadNote();
    }
  };

  const createThreadNoteForThread = async (threadID?: string) => {
    if (!threadID) return;
    setActiveView("threads");
    if (compact && !sidebarOpen) openSidebarAssistant();
    if (threadID !== selectedThreadID) {
      await selectThread(threadID, { syncProjectFilter: false });
    }
    setAssistantPanel("thread-note");
    const workspace = await window.openAssistElectron?.createThreadNote(threadID);
    if (workspace) {
      setThreadNoteWorkspace(workspace);
      setThreadNoteDraft(workspace.selectedNote?.markdown ?? "");
    }
  };

  const createCurrentThreadNote = async () => {
    await createThreadNoteForThread(currentThreadID());
  };

  const appendTextToThreadNote = async (rawText: string) => {
    const threadID = currentThreadID();
    const text = rawText.trim();
    if (!threadID || !text) return;
    setActiveView("threads");
    if (compact && !sidebarOpen) openSidebarAssistant();
    setAssistantPanel("thread-note");
    let workspace = threadNoteWorkspace?.threadID === threadID
      ? threadNoteWorkspace
      : await window.openAssistElectron?.loadThreadNote(threadID);
    if (!workspace?.selectedNote) {
      workspace = await window.openAssistElectron?.createThreadNote(threadID);
    }
    const noteID = workspace?.selectedNote?.id;
    if (!workspace || !noteID) return;
    const currentMarkdown = workspace.selectedNote?.markdown ?? "";
    const quoted = text
      .split("\n")
      .map((line) => `> ${line}`)
      .join("\n");
    const nextMarkdown = `${currentMarkdown.trimEnd()}${currentMarkdown.trim() ? "\n\n" : ""}${quoted}\n`;
    const saved = await window.openAssistElectron?.saveThreadNote(threadID, noteID, nextMarkdown);
    if (saved) {
      setThreadNoteWorkspace(saved);
      setThreadNoteDraft(saved.selectedNote?.markdown ?? nextMarkdown);
    }
  };

  const selectCurrentThreadNote = async (noteID: string) => {
    const threadID = threadNoteWorkspace?.threadID ?? currentThreadID();
    if (!threadID) return;
    const workspace = await window.openAssistElectron?.selectThreadNote(threadID, noteID);
    if (workspace) {
      setThreadNoteWorkspace(workspace);
      setThreadNoteDraft(workspace.selectedNote?.markdown ?? "");
    }
  };

  const saveCurrentThreadNote = async () => {
    const threadID = threadNoteWorkspace?.threadID ?? currentThreadID();
    if (!threadID) return;
    const workspace = await window.openAssistElectron?.saveThreadNote(
      threadID,
      threadNoteWorkspace?.selectedNoteID,
      threadNoteDraft
    );
    if (workspace) {
      setThreadNoteWorkspace(workspace);
      setThreadNoteDraft(workspace.selectedNote?.markdown ?? "");
    }
  };

  const openInstructionsForThread = async (threadID?: string) => {
    if (threadID && threadID !== selectedThreadID) {
      await selectThread(threadID, { syncProjectFilter: false });
    }
    setActiveView("threads");
    if (compact && !sidebarOpen) openSidebarAssistant();
    setAssistantPanel("session-instructions");
  };

  const openInstructions = () => {
    void openInstructionsForThread(currentThreadID());
  };

  const openMemoryForThread = async (threadID?: string) => {
    if (!threadID) return;
    setActiveView("threads");
    if (compact && !sidebarOpen) openSidebarAssistant();
    if (threadID !== selectedThreadID) {
      await selectThread(threadID, { syncProjectFilter: false });
    }
    const memory = await window.openAssistElectron?.loadThreadMemory(threadID);
    if (memory) setThreadMemory(memory);
    setAssistantPanel("memory");
  };

  const openMemory = async () => {
    await openMemoryForThread(currentThreadID());
  };

  const openSkills = () => {
    setActiveView("skills");
    if (compact) openSidebarAssistant();
  };

  const openPlugins = () => {
    setActiveView("plugins");
    if (compact) openSidebarAssistant();
  };

  const backToThreads = () => {
    void flushNoteDraftBeforeNavigation();
    setActiveView("threads");
  };

  const toggleAgenticMode = () => {
    setInteractionMode((current) => (current === "Agentic" ? "Chat" : "Agentic"));
  };

  const cycleReasoning = () => {
    setReasoningEffort((current) => {
      if (current === "High") return "Extra High";
      if (current === "Extra High") return "Medium";
      if (current === "Medium") return "Low";
      return "High";
    });
  };

  const hideFloatingVoiceHUDForAppFocus = () => {
    void window.openAssistElectron?.updateVoiceHUD?.({
      visible: false,
      status: "idle",
      suppressForAppFocus: true
    });
  };

  const showVoiceHUDImmediately = (payload: {
    status: "listening" | "processing" | "unsupported" | "error" | "message" | "correction";
    text?: string;
  }) => {
    if (!appState.settings.assistantFloatingHUDEnabled) return;
    if (appWindowFocused) {
      hideFloatingVoiceHUDForAppFocus();
      return;
    }
    void window.openAssistElectron?.updateVoiceHUD?.({
      visible: true,
      theme: appState.settings.waveformTheme,
      colorTheme: appState.settings.colorTheme,
      chromeStyle: appState.settings.appChromeStyle,
      ...payload
    });
  };

  const playDictationSound = (cue: "startListening" | "stopListening" | "processing" | "pasted" | "correctionLearned") => {
    void window.openAssistElectron?.playDictationFeedbackSound?.(cue);
  };

  const stopVoiceInput = async () => {
    if (nativeVoiceActiveRef.current) {
      const engine = appState.settings.transcriptionEngine || "Apple Speech";
      const provider = appState.settings.cloudTranscriptionProvider || "OpenAI";
      if (nativeVoiceOperationRef.current) {
        nativeVoiceStopAfterStartRef.current = true;
        return;
      }
      nativeVoiceStopAfterStartRef.current = false;
      nativeVoiceOperationRef.current = true;
      setVoiceStatus("processing");
      showVoiceHUDImmediately({ status: "processing" });
      setVoiceStatusText(
        engine === "Cloud Providers"
          ? `Sending voice to ${provider}...`
          : engine === "whisper.cpp"
            ? "Transcribing with local whisper.cpp..."
            : "Finishing Apple Speech..."
      );
      try {
        const result = await withTimeout(
          window.openAssistElectron?.stopVoiceInput(),
          55_000,
          "Voice transcription timed out. Please try again."
        );
        nativeVoiceActiveRef.current = false;
        nativeVoiceStopAfterStartRef.current = false;
        if (result?.text?.trim()) {
          const transcript = result.text.trim();
          try {
            await window.openAssistElectron?.addTranscriptHistory?.(transcript);
          } catch (error) {
            console.error("Could not save transcript history", error);
          }
          const insertedInFocusedAppField = document.hasFocus() && insertTextIntoFocusedAppField(transcript);
          if (insertedInFocusedAppField) {
            playDictationSound("pasted");
            setVoiceError(undefined);
            setVoiceStatus("idle");
            setVoiceStatusText(undefined);
            hideFloatingVoiceHUDForAppFocus();
            return;
          }
          let insertionError: string | undefined;
          let insertionResult: Awaited<ReturnType<NonNullable<typeof window.openAssistElectron>["insertTranscriptText"]>> | undefined;
          try {
            insertionResult = await withTimeout(
              window.openAssistElectron?.insertTranscriptText?.(transcript),
              8_000,
              "Transcript was created, but Open Assist could not paste it into the focused app."
            );
          } catch (error) {
            insertionError = error instanceof Error ? error.message : "Could not paste into the focused app.";
          }
          if (insertionResult?.ok) {
            playDictationSound("pasted");
            setVoiceError(undefined);
            setVoiceStatus("idle");
            setVoiceStatusText(undefined);
            return;
          }
          setComposerText((current) => appendVoiceDraft(current, transcript));
          playDictationSound("pasted");
          setVoiceStatus("error");
          setVoiceError(
            insertionResult?.error || insertionError || "Could not paste into the focused app. The transcript was added to the composer."
          );
          setVoiceStatusText(undefined);
          return;
        }
        if (result?.error) {
          setVoiceStatus("error");
          setVoiceError(result.error);
          setVoiceStatusText(undefined);
          return;
        }
        if (engine === "Cloud Providers" || engine === "whisper.cpp") {
          setVoiceStatus("error");
          setVoiceError("No speech was transcribed. Try speaking closer to the microphone.");
          setVoiceStatusText(undefined);
          return;
        }
        setVoiceError(undefined);
        setVoiceStatus("idle");
        setVoiceStatusText(undefined);
        return;
      } catch (error) {
        nativeVoiceActiveRef.current = false;
        nativeVoiceStopAfterStartRef.current = false;
        setVoiceStatus("error");
        setVoiceError(error instanceof Error ? error.message : "Voice transcription failed.");
        setVoiceStatusText(undefined);
        return;
      } finally {
        nativeVoiceOperationRef.current = false;
      }
    }

    const recognition = recognitionRef.current;
    if (!recognition) return;
    setVoiceStatus("processing");
    playDictationSound("stopListening");
    window.setTimeout(() => playDictationSound("processing"), 180);
    recognition.stop();
  };

  const startBrowserVoiceInput = () => {
    if (!(appState.settings.voiceEnabled ?? true)) {
      setVoiceStatus("error");
      setVoiceError("Voice task entry is turned off in Settings.");
      setVoiceStatusText(undefined);
      showVoiceHUDImmediately({ status: "error", text: "Voice task entry is turned off in Settings." });
      return;
    }

    const Recognition = speechRecognitionConstructor();
    if (!Recognition) {
      setVoiceStatus("unsupported");
      setVoiceError("Voice input is not available in this Electron runtime.");
      setVoiceStatusText(undefined);
      return;
    }

    try {
      recognitionRef.current?.abort();
      const recognition = new Recognition();
      recognitionRef.current = recognition;
      voiceBaseTextRef.current = composerText;
      voiceFinalTextRef.current = "";
      recognition.continuous = true;
      recognition.interimResults = true;
      recognition.lang = navigator.language || "en-US";
      recognition.onstart = () => {
        setVoiceError(undefined);
        setVoiceStatus("listening");
        playDictationSound("startListening");
      };
      recognition.onerror = (event) => {
        const reason = event.error || event.message || "unknown error";
        setVoiceStatus("error");
        setVoiceError(`Browser voice input stopped: ${reason}`);
        setVoiceStatusText(undefined);
      };
      recognition.onend = () => {
        recognitionRef.current = null;
        setVoiceStatusText(undefined);
        setVoiceStatus((current) => (current === "listening" || current === "processing" ? "idle" : current));
      };
      recognition.onresult = (event) => {
        let interimText = "";
        for (let index = event.resultIndex; index < event.results.length; index += 1) {
          const result = event.results[index];
          const transcript = result?.[0]?.transcript ?? "";
          if (result?.isFinal) {
            voiceFinalTextRef.current = `${voiceFinalTextRef.current} ${transcript}`.trim();
          } else {
            interimText = `${interimText} ${transcript}`.trim();
          }
        }
        const voiceText = `${voiceFinalTextRef.current} ${interimText}`.trim();
        setComposerText(appendVoiceDraft(voiceBaseTextRef.current, voiceText));
      };
      recognition.start();
    } catch (error) {
      recognitionRef.current = null;
      setVoiceStatus("error");
      setVoiceError(error instanceof Error ? error.message : "Could not start voice input.");
      setVoiceStatusText(undefined);
    }
  };

  const startVoiceInput = async (mode: "toggle" | "hold" = "toggle") => {
    if (!(appState.settings.voiceEnabled ?? true)) {
      setVoiceStatus("error");
      setVoiceError("Voice task entry is turned off in Settings.");
      setVoiceStatusText(undefined);
      showVoiceHUDImmediately({ status: "error", text: "Voice task entry is turned off in Settings." });
      return;
    }
    if (mode !== "hold") nativeVoiceStopAfterStartRef.current = false;

    if (window.openAssistElectron?.platform === "darwin" && window.openAssistElectron.startVoiceInput) {
      if (nativeVoiceOperationRef.current) return;
      const engine = appState.settings.transcriptionEngine || "Apple Speech";
      const provider = appState.settings.cloudTranscriptionProvider || "OpenAI";
      const cloudProviderNeedsKey = engine === "Cloud Providers" && provider !== "ChatGPT / Codex Session";
      if (cloudProviderNeedsKey && !(appState.settings.cloudTranscriptionAPIKeyConfigured ?? false)) {
        setVoiceStatus("error");
        const message = `${provider} transcription needs an API key in Settings > Voice & Dictation.`;
        setVoiceError(message);
        setVoiceStatusText(undefined);
        showVoiceHUDImmediately({ status: "error", text: message });
        return;
      }
      setVoiceError(undefined);
      setVoiceStatus("listening");
      showVoiceHUDImmediately({ status: "listening" });
      setVoiceStatusText(
        engine === "Cloud Providers"
          ? `Recording for ${provider}. Tap the mic again to transcribe.`
          : engine === "whisper.cpp"
            ? "Recording for local whisper.cpp. Tap the mic again to transcribe."
            : "Listening with Apple Speech. Tap the mic again to finish."
      );
      nativeVoiceOperationRef.current = true;
      try {
        const result = await withTimeout(
          window.openAssistElectron.startVoiceInput({
            transcriptionEngine: engine,
            cloudTranscriptionProvider: provider,
            cloudTranscriptionAPIKeyConfigured: appState.settings.cloudTranscriptionAPIKeyConfigured,
            autoDetectMicrophone: appState.settings.autoDetectMicrophone,
            selectedMicrophoneUID: appState.settings.selectedMicrophoneUID,
            whisperModel: appState.settings.whisperModel,
            whisperUseCoreML: appState.settings.whisperUseCoreML,
            dictationStartSoundName: appState.settings.dictationStartSoundName,
            dictationStopSoundName: appState.settings.dictationStopSoundName,
            dictationProcessingSoundName: appState.settings.dictationProcessingSoundName,
            dictationPastedSoundName: appState.settings.dictationPastedSoundName,
            dictationCorrectionLearnedSoundName: appState.settings.dictationCorrectionLearnedSoundName,
            dictationFeedbackVolume: appState.settings.dictationFeedbackVolume
          }),
          18_000,
          "Voice input did not start in time. Check Microphone and Speech Recognition permissions."
        );
        if (result?.ok) {
          nativeVoiceActiveRef.current = true;
          setVoiceStatus("listening");
          setVoiceStatusText(
            engine === "Cloud Providers"
              ? `Recording for ${provider}. Tap the mic again to transcribe.`
              : engine === "whisper.cpp"
                ? `Recording for local whisper.cpp${result.modelID ? ` (${result.modelID})` : ""}. Tap the mic again to transcribe.`
                : "Listening with Apple Speech. Tap the mic again to finish."
          );
          if (nativeVoiceStopAfterStartRef.current) {
            window.setTimeout(() => {
              void stopVoiceInput();
            }, 0);
          }
          return;
        }
        nativeVoiceActiveRef.current = false;
        nativeVoiceStopAfterStartRef.current = false;
        setVoiceStatus("error");
        const message = result?.error ?? "Could not start native voice input.";
        setVoiceError(message);
        setVoiceStatusText(undefined);
        showVoiceHUDImmediately({ status: "error", text: message });
        return;
      } catch (error) {
        nativeVoiceActiveRef.current = false;
        nativeVoiceStopAfterStartRef.current = false;
        setVoiceStatus("error");
        const message = error instanceof Error ? error.message : "Could not start native voice input.";
        setVoiceError(message);
        setVoiceStatusText(undefined);
        showVoiceHUDImmediately({ status: "error", text: message });
        return;
      } finally {
        nativeVoiceOperationRef.current = false;
      }
    }

    startBrowserVoiceInput();
  };

  const toggleVoiceInput = () => {
    if (voiceStatus === "processing" || nativeVoiceOperationRef.current) return;
    if (recognitionRef.current || nativeVoiceActiveRef.current) {
      void stopVoiceInput();
      return;
    }
    void startVoiceInput("toggle");
  };

  const playRealtimeAudio = async (payload: any) => {
    const audio = realtimePayloadAudio(payload);
    if (!audio) return;
    const context = liveVoiceOutputContextRef.current ?? new AudioContext({ sampleRate: audio.sampleRate });
    liveVoiceOutputContextRef.current = context;
    if (context.state === "suspended") await context.resume();
    const pcm = base64ToPCM16(audio.data);
    const channels = Math.max(1, audio.numChannels);
    const frames = Math.max(1, Math.floor(pcm.length / channels));
    const buffer = context.createBuffer(channels, frames, audio.sampleRate);
    for (let channel = 0; channel < channels; channel += 1) {
      const output = buffer.getChannelData(channel);
      for (let index = 0; index < frames; index += 1) {
        output[index] = (pcm[index * channels + channel] ?? 0) / 0x8000;
      }
    }
    const source = context.createBufferSource();
    source.buffer = buffer;
    source.connect(context.destination);
    liveVoiceOutputSourcesRef.current.add(source);
    source.onended = () => {
      liveVoiceOutputSourcesRef.current.delete(source);
    };
    const startAt = Math.max(context.currentTime, liveVoicePlaybackTimeRef.current);
    source.start(startAt);
    liveVoicePlaybackTimeRef.current = startAt + buffer.duration;
  };

  const interruptLiveVoicePlayback = () => {
    const context = liveVoiceOutputContextRef.current;
    for (const source of liveVoiceOutputSourcesRef.current) {
      try {
        source.stop();
      } catch {
        // Already stopped or not yet started.
      }
      try {
        source.disconnect();
      } catch {
        // Ignore cleanup errors from already-disconnected audio nodes.
      }
    }
    liveVoiceOutputSourcesRef.current.clear();
    liveVoicePlaybackTimeRef.current = context ? context.currentTime : 0;
  };

  const stopLiveVoice = async (nextStatus: LiveVoiceStatus = "idle", nextText?: string) => {
    liveVoiceExpectedStopRef.current = nextStatus !== "error";
    const clearExpectedStop = () => {
      window.setTimeout(() => {
        liveVoiceExpectedStopRef.current = false;
      }, 250);
    };
    liveVoiceActiveRef.current = false;
    if (liveVoiceChunkTimerRef.current !== null) {
      window.clearInterval(liveVoiceChunkTimerRef.current);
      liveVoiceChunkTimerRef.current = null;
    }
    liveVoiceInputChunksRef.current = [];
    liveVoiceProcessorRef.current?.disconnect();
    liveVoiceSourceRef.current?.disconnect();
    liveVoiceProcessorRef.current = null;
    liveVoiceSourceRef.current = null;
    liveVoiceStreamRef.current?.getTracks().forEach((track) => track.stop());
    liveVoiceStreamRef.current = null;
    const inputContext = liveVoiceInputContextRef.current;
    liveVoiceInputContextRef.current = null;
    void inputContext?.close();
    interruptLiveVoicePlayback();
    const outputContext = liveVoiceOutputContextRef.current;
    liveVoiceOutputContextRef.current = null;
    liveVoicePlaybackTimeRef.current = 0;
    void outputContext?.close();
    try {
      const result = await openAssistRealtimeAPI()?.stop();
      if (result && !result.ok && nextStatus !== "error") {
        setLiveVoiceStatus("error");
        setLiveVoiceStatusText(result.error || "Live Voice stopped with an error.");
        clearExpectedStop();
        return;
      }
    } catch (error) {
      if (nextStatus !== "error") {
        setLiveVoiceStatus("error");
        setLiveVoiceStatusText(error instanceof Error ? error.message : "Could not stop Live Voice.");
        clearExpectedStop();
        return;
      }
    }
    setLiveVoiceStatus(nextStatus);
    setLiveVoiceStatusText(nextText);
    clearExpectedStop();
  };

  const flushLiveVoiceChunk = () => {
    if (!liveVoiceActiveRef.current) return;
    const context = liveVoiceInputContextRef.current;
    const api = openAssistRealtimeAPI();
    if (!context || !api || !liveVoiceInputChunksRef.current.length) return;
    const merged = mergeFloatChunks(liveVoiceInputChunksRef.current.splice(0));
    const pcm = downsampleToPCM16(merged, context.sampleRate);
    if (!pcm.length) return;
    void api.appendAudio({
      data: pcm16ToBase64(pcm),
      sampleRate: realtimeSampleRate,
      numChannels: 1,
      samplesPerChannel: pcm.length,
      itemId: null
    }).then((result) => {
      if (!result.ok) {
        liveVoiceActiveRef.current = false;
        setLiveVoiceStatus("error");
        setLiveVoiceStatusText(result.error || "Live Voice audio failed.");
      }
    }).catch((error) => {
      liveVoiceActiveRef.current = false;
      setLiveVoiceStatus("error");
      setLiveVoiceStatusText(error instanceof Error ? error.message : "Live Voice audio failed.");
    });
  };

  const startLiveVoice = async () => {
    if (activeProviderKey !== "codex") return;
    const api = openAssistRealtimeAPI();
    if (!api) {
      setLiveVoiceStatus("error");
      setLiveVoiceStatusText("Live Voice is not ready in this build.");
      return;
    }
    if (!navigator.mediaDevices?.getUserMedia) {
      setLiveVoiceStatus("error");
      setLiveVoiceStatusText("Microphone access is not available here.");
      return;
    }
    if (!(appState.settings.realtimeVoiceEnabled ?? true)) {
      setLiveVoiceStatus("error");
      setLiveVoiceStatusText("Turn on Codex Live Realtime Voice in Settings.");
      return;
    }
    if (!(appState.settings.realtimeOpenAIAPIKeyConfigured ?? false)) {
      setLiveVoiceStatus("error");
      setLiveVoiceStatusText("Add an OpenAI API key in Settings.");
      return;
    }
    if (nativeVoiceActiveRef.current) await stopVoiceInput();
    recognitionRef.current?.abort();
    await stopLiveVoice("connecting", "Connecting Live Voice...");
    setLiveVoiceStatus("connecting");
    setLiveVoiceStatusText("Connecting to OpenAI Realtime...");
    try {
      const targetThreadID = currentThreadID();
      console.debug("[OpenAssist Live Voice] start requested", {
        threadId: targetThreadID,
        provider: activeProviderKey
      });
      const result = await withTimeout(
        api.start({
          threadId: targetThreadID,
          provider: "codex",
          interactionMode,
          permissionMode,
          reasoningEffort
        }),
        liveVoiceConnectTimeoutMs,
        "Live Voice did not connect. Check the OpenAI API key and realtime model in Settings."
      );
      console.debug("[OpenAssist Live Voice] start result", result);
      if (!result) throw new Error("Live Voice is not ready in this build.");
      if (!result.ok) throw new Error(result.error || "Could not start Live Voice.");
      const selectedMicrophoneUID = appState.settings.autoDetectMicrophone === false
        ? appState.settings.selectedMicrophoneUID?.trim()
        : "";
      let stream: MediaStream;
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          audio: selectedMicrophoneUID
            ? { deviceId: { exact: selectedMicrophoneUID } }
            : true
        });
      } catch (microphoneError) {
        if (!selectedMicrophoneUID || (mediaErrorName(microphoneError) !== "OverconstrainedError" && mediaErrorName(microphoneError) !== "NotFoundError")) {
          throw new Error(mediaErrorMessage(microphoneError));
        }
        console.warn("[OpenAssist Live Voice] selected microphone unavailable, using system default", microphoneError);
        setLiveVoiceStatusText("Selected microphone was unavailable; using System Default.");
        stream = await navigator.mediaDevices.getUserMedia({ audio: true }).catch((fallbackError) => {
          throw new Error(mediaErrorMessage(fallbackError));
        });
      }
      const context = new AudioContext();
      const source = context.createMediaStreamSource(stream);
      const processor = context.createScriptProcessor(4096, 1, 1);
      processor.onaudioprocess = (event) => {
        if (!liveVoiceActiveRef.current) return;
        liveVoiceInputChunksRef.current.push(new Float32Array(event.inputBuffer.getChannelData(0)));
      };
      source.connect(processor);
      processor.connect(context.destination);
      liveVoiceStreamRef.current = stream;
      liveVoiceInputContextRef.current = context;
      liveVoiceSourceRef.current = source;
      liveVoiceProcessorRef.current = processor;
      liveVoiceInputChunksRef.current = [];
      liveVoiceActiveRef.current = true;
      liveVoicePlaybackTimeRef.current = 0;
      liveVoiceChunkTimerRef.current = window.setInterval(flushLiveVoiceChunk, 100);
      setLiveVoiceStatus("listening");
      setLiveVoiceStatusText("Live Voice listening");
    } catch (error) {
      const message = error instanceof Error ? error.message : "Could not start Live Voice.";
      console.error("[OpenAssist Live Voice] start failed", error);
      await stopLiveVoice("error", message);
    }
  };

  const toggleLiveVoice = () => {
    if (liveVoiceActiveRef.current || liveVoiceStatus === "connecting") {
      void stopLiveVoice("idle", undefined);
      return;
    }
    void startLiveVoice();
  };

  useEffect(() => {
    const updateFocusState = () => {
      setAppWindowFocused(document.hasFocus());
    };
    updateFocusState();
    window.addEventListener("focus", updateFocusState);
    window.addEventListener("blur", updateFocusState);
    document.addEventListener("visibilitychange", updateFocusState);
    return () => {
      window.removeEventListener("focus", updateFocusState);
      window.removeEventListener("blur", updateFocusState);
      document.removeEventListener("visibilitychange", updateFocusState);
    };
  }, []);

  useEffect(() => {
    return openAssistRealtimeAPI()?.onEvent((event) => {
      const type = event.type || "";
      const eventNames = realtimeEventNames(event);
      const lowerType = eventNames.join(" ").toLowerCase();
      if (type === "thread/realtime/activity") {
        const payload = event.payload && typeof event.payload === "object" ? event.payload as Record<string, unknown> : {};
        const activity = payload.activity && typeof payload.activity === "object" ? payload.activity as ChatMessage : null;
        const delegatedThreadID = typeof payload.threadId === "string" ? payload.threadId : selectedThreadIDRef.current;
        const providerTurnID = typeof payload.providerTurnId === "string" ? payload.providerTurnId : "";
        const prompt = typeof payload.prompt === "string" ? payload.prompt : "";
        if (activity?.role === "activity" && delegatedThreadID) {
          setThreadDetail((current) => {
            const currentThreadID = current?.threadID ?? selectedThreadIDRef.current;
            if (currentThreadID && currentThreadID !== delegatedThreadID) return current;
            const currentMessages = current?.messages ?? [];
            const messagesWithRealtimeTurn = isRealtimeDelegationActivity(activity)
              ? upsertRealtimeDelegationUserTurn(currentMessages, providerTurnID, prompt, activity)
              : currentMessages;
            return {
              threadID: delegatedThreadID,
              title: current?.title ?? "Live Voice",
              messages: upsertChatActivity(messagesWithRealtimeTurn, activity, "Codex")
            };
          });
        }
        return;
      }
      if (lowerType.includes("delegation")) {
        const payload = event.payload && typeof event.payload === "object" ? event.payload as Record<string, unknown> : {};
        const delegatedThreadID = typeof payload.threadId === "string" ? payload.threadId : selectedThreadIDRef.current;
        if (lowerType.includes("started")) {
          const prompt = typeof payload.prompt === "string" ? payload.prompt.trim() : "";
          const providerTurnID = typeof payload.providerTurnId === "string" ? payload.providerTurnId : "";
          if (delegatedThreadID && providerTurnID) {
            setThreadDetail((current) => {
              const currentThreadID = current?.threadID ?? selectedThreadIDRef.current;
              if (currentThreadID && currentThreadID !== delegatedThreadID) return current;
              return {
                threadID: delegatedThreadID,
                title: current?.title ?? "Live Voice",
                messages: upsertRealtimeDelegationUserTurn(current?.messages ?? [], providerTurnID, prompt)
              };
            });
          }
          setLiveVoiceStatus("delegating");
          setLiveVoiceStatusText(prompt ? `Heard: ${prompt}` : "Codex is working");
          return;
        }
        if (lowerType.includes("stopped")) {
          setLiveVoiceStatus("listening");
          setLiveVoiceStatusText("Codex task stopped");
          if (delegatedThreadID) {
            window.setTimeout(() => {
              void window.openAssistElectron?.loadThread(delegatedThreadID).then((detail) => {
                if (!detail) return;
                setSelectedThreadID(delegatedThreadID);
                setThreadDetail(detail);
                void refreshAppState();
              });
            }, 250);
          }
          return;
        }
        if (lowerType.includes("completed") || lowerType.includes("failed")) {
          setLiveVoiceStatus(lowerType.includes("failed") ? "error" : "listening");
          setLiveVoiceStatusText((current) => {
            if (lowerType.includes("failed")) return "Codex delegation failed.";
            return current && /^heard:/i.test(current) ? current : "Codex finished";
          });
          if (delegatedThreadID) {
            void window.openAssistElectron?.loadThread(delegatedThreadID).then((detail) => {
              if (!detail) return;
              setSelectedThreadID(delegatedThreadID);
              setThreadDetail(detail);
              void refreshAppState();
            });
          } else {
            void refreshAppState();
          }
          return;
        }
      }
      if (!liveVoiceActiveRef.current && liveVoiceStatusRef.current !== "connecting") return;
      if (lowerType.includes("speech_started") || lowerType.includes("speechstarted")) {
        interruptLiveVoicePlayback();
        setLiveVoiceStatus("listening");
        setLiveVoiceStatusText((current) => current && /^heard:/i.test(current) ? current : "Live Voice listening");
        return;
      }
      if (type === "thread/realtime/outputAudio/delta" || lowerType.includes("outputaudio")) {
        setLiveVoiceStatus("speaking");
        setLiveVoiceStatusText((current) => current && /^heard:/i.test(current) ? current : "Live Voice speaking");
        void playRealtimeAudio(event.payload).catch((error) => {
          setLiveVoiceStatus("error");
          setLiveVoiceStatusText(error instanceof Error ? error.message : "Could not play Live Voice audio.");
        });
        return;
      }
      if (lowerType.includes("delegate")) {
        setLiveVoiceStatus("delegating");
        setLiveVoiceStatusText((current) => current && /^heard:/i.test(current) ? current : "Codex is working");
        return;
      }
      if (lowerType.includes("transcript")) {
        const role = realtimePayloadRole(event.payload);
        if (role && role !== "user") {
          if (lowerType.includes("done")) {
            setLiveVoiceStatus("listening");
            setLiveVoiceStatusText((current) => current && /^heard:/i.test(current) ? current : "Ready for your voice");
          }
          return;
        }
        const text = realtimePayloadText(event.payload).trim();
        if (text) {
          setLiveVoiceStatusText(lowerType.includes("done") ? `Heard: ${text}` : text);
        }
        if (lowerType.includes("done")) setLiveVoiceStatus("listening");
        return;
      }
      if (lowerType.includes("closed")) {
        const payload = event.payload && typeof event.payload === "object" ? event.payload as Record<string, unknown> : {};
        const reason = typeof payload.reason === "string" ? payload.reason : "";
        liveVoiceActiveRef.current = false;
        if (liveVoiceExpectedStopRef.current || reason === "stopped" || reason === "replaced") {
          setLiveVoiceStatus("idle");
          setLiveVoiceStatusText(undefined);
          return;
        }
        setLiveVoiceStatus("error");
        setLiveVoiceStatusText(reason ? `Live Voice disconnected: ${reason}` : "Live Voice disconnected before it was ready.");
        return;
      }
      if (lowerType.includes("error")) {
        void stopLiveVoice("error", realtimePayloadText(event.payload) || "Live Voice failed.");
        return;
      }
      if (lowerType.includes("done") || lowerType.includes("completed")) {
        setLiveVoiceStatus("listening");
        setLiveVoiceStatusText((current) => current && /^heard:/i.test(current) ? current : "Live Voice listening");
      }
    });
  }, [selectedThreadID]);

  useEffect(() => {
    const scope = `${activeProviderKey}:${selectedThreadID ?? "none"}`;
    if (!liveVoiceScopeRef.current) {
      liveVoiceScopeRef.current = scope;
      return;
    }
    if (liveVoiceScopeRef.current === scope) return;
    liveVoiceScopeRef.current = scope;
    if (liveVoiceActiveRef.current || liveVoiceStatus !== "idle") {
      void stopLiveVoice("idle", undefined);
    }
  }, [activeProviderKey, selectedThreadID, liveVoiceStatus]);

  useEffect(() => {
    const voiceHUDStateActive = (
      voiceStatus === "listening"
      || voiceStatus === "processing"
      || voiceStatus === "error"
      || voiceStatus === "unsupported"
    );
    const visible = appState.settings.assistantFloatingHUDEnabled
      && !appWindowFocused
      && voiceHUDStateActive;
    if (appWindowFocused && voiceHUDStateActive) {
      hideFloatingVoiceHUDForAppFocus();
      return;
    }
    void window.openAssistElectron?.updateVoiceHUD?.({
      visible,
      status: visible ? voiceStatus : "idle",
      text: voiceStatus === "error" || voiceStatus === "unsupported" ? voiceError || "Voice input failed." : voiceStatusText,
      theme: appState.settings.waveformTheme,
      colorTheme: appState.settings.colorTheme,
      chromeStyle: appState.settings.appChromeStyle
    });
  }, [
    appState.settings.appChromeStyle,
    appState.settings.assistantFloatingHUDEnabled,
    appState.settings.colorTheme,
    appState.settings.waveformTheme,
    appWindowFocused,
    voiceError,
    voiceStatus,
    voiceStatusText
  ]);

  useEffect(() => {
    return () => {
      void window.openAssistElectron?.updateVoiceHUD?.({ visible: false, status: "idle" });
    };
  }, []);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.shiftKey && event.code === "Space") {
        event.preventDefault();
        if (compact && sidebarOpen) {
          collapseSidebar();
        } else {
          openSidebarAssistant();
        }
      }
      if (event.key === "Escape" && compact) {
        event.preventDefault();
        collapseSidebar();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [compact, sidebarOpen]);

  useEffect(() => {
    return window.openAssistElectron?.onSidebarShortcutToggle?.(() => {
      if (compact && sidebarOpen) {
        collapseSidebar();
      } else {
        openSidebarAssistant();
      }
    });
  }, [compact, sidebarOpen, appState.settings.compactEdge]);

  useEffect(() => {
    return window.openAssistElectron?.onSidebarBlurCollapse?.((state) => {
      if (state?.sidebarOpen === false) {
        const sidebarEdge = state.sidebarEdge ?? (appState.settings.compactEdge === "left" ? "left" : "right");
        setCompact(true);
        setSidebarOpen(false);
        void window.openAssistElectron?.setWindowMode("sidebar", false, sidebarEdge);
        return;
      }
      if (compact && sidebarOpen) collapseSidebar();
    });
  }, [compact, sidebarOpen, appState.settings.compactEdge]);

  useEffect(() => {
    return window.openAssistElectron?.onVoiceShortcut?.((target, phase: ShortcutPhase = "trigger") => {
      if (target === "assistantCompact") return;
      setActiveView("threads");
      if (target === "assistantLiveVoice" && compact && !sidebarOpen) openSidebarAssistant();
      const isHoldStyleShortcut = target === "holdToTalk" || target === "assistantLiveVoice";
      if (isHoldStyleShortcut && phase === "down") {
        nativeVoiceStopAfterStartRef.current = false;
        if (!recognitionRef.current && !nativeVoiceActiveRef.current) void startVoiceInput("hold");
        return;
      }
      if (isHoldStyleShortcut && phase === "up") {
        nativeVoiceStopAfterStartRef.current = true;
        void stopVoiceInput();
        return;
      }
      toggleVoiceInput();
    });
  }, [
    compact,
    sidebarOpen,
    appState.settings.compactEdge,
    appState.settings.transcriptionEngine,
    appState.settings.cloudTranscriptionProvider,
    appState.settings.voiceEnabled,
    appState.settings.dictationStartSoundName,
    appState.settings.dictationStopSoundName,
    appState.settings.dictationProcessingSoundName,
    appState.settings.dictationPastedSoundName,
    appState.settings.dictationCorrectionLearnedSoundName,
    appState.settings.dictationFeedbackVolume,
    composerText
  ]);

  useEffect(() => {
    return window.openAssistElectron?.onMenuBarCommand?.((command) => {
      if (command === "open-assistant") {
        openAssistant();
        return;
      }
      if (command === "open-history") {
        void window.openAssistElectron?.openTranscriptHistoryWindow?.();
        return;
      }
      if (command === "open-models" || command === "open-settings") {
        openSettings();
        return;
      }
      if (command === "speak-assistant-task") {
        openAssistant();
        toggleVoiceInput();
        return;
      }
      if (command === "toggle-dictation") {
        toggleVoiceInput();
      }
    });
  }, [
    compact,
    sidebarOpen,
    appState.settings.compactEdge,
    appState.settings.transcriptionEngine,
    appState.settings.cloudTranscriptionProvider,
    appState.settings.voiceEnabled,
    appState.settings.dictationStartSoundName,
    appState.settings.dictationStopSoundName,
    appState.settings.dictationProcessingSoundName,
    appState.settings.dictationPastedSoundName,
    appState.settings.dictationCorrectionLearnedSoundName,
    appState.settings.dictationFeedbackVolume,
    composerText,
    voiceStatus
  ]);

  useEffect(() => {
    return () => {
      recognitionRef.current?.abort();
      if (nativeVoiceActiveRef.current) {
        void window.openAssistElectron?.stopVoiceInput();
      }
      void stopLiveVoice("idle", undefined);
    };
  }, []);

  const cleanupTemporaryThread = async (threadID?: string) => {
    if (!threadID) return;
    const thread = appState.threads.find((item) => item.id === threadID);
    if (!thread?.isTemporary) return;
    await window.openAssistElectron?.destroyTemporaryThread(threadID);
    setAppState((current) => ({
      ...current,
      threads: current.threads.filter((item) => item.id !== threadID)
    }));
  };

  const selectThread = async (threadID: string, options: { syncProjectFilter?: boolean } = {}) => {
    const requestID = selectThreadRequestRef.current + 1;
    selectThreadRequestRef.current = requestID;
    if (selectedThreadID && selectedThreadID !== threadID) {
      await cleanupTemporaryThread(selectedThreadID);
    }
    setSelectedThreadID(threadID);
    const thread = appState.threads.find((item) => item.id === threadID);
    if (options.syncProjectFilter === true && thread?.projectID) setSelectedProjectID(thread.projectID);
    setAssistantPanel(null);
    const detail = await window.openAssistElectron?.loadThread(threadID);
    if (detail && selectThreadRequestRef.current === requestID) setThreadDetail(detail);
  };

  const clearProjectFilter = async () => {
    const currentThread = appState.threads.find((item) => item.id === selectedThreadID);
    await cleanupTemporaryThread(selectedThreadID);
    setSelectedProjectID(undefined);
    setShowArchivedThreads(false);
    setActiveView("threads");
    setAssistantPanel(null);
    if (currentThread && !currentThread.isArchived && !currentThread.isTemporary) return;

    const nextThread = appState.threads.find((thread) => !thread.isArchived && !thread.isTemporary);
    if (!nextThread) {
      selectThreadRequestRef.current += 1;
      setSelectedThreadID(undefined);
      setThreadDetail(null);
      return;
    }
    await selectThread(nextThread.id, { syncProjectFilter: false });
  };

  const selectProject = async (projectID: string) => {
    if (selectedProjectID?.toLowerCase() === projectID.toLowerCase()) {
      await clearProjectFilter();
      return;
    }
    await cleanupTemporaryThread(selectedThreadID);
    setSelectedProjectID(projectID);
    setShowArchivedThreads(false);
    setActiveView("threads");
    const nextThread = appState.threads.find((thread) => thread.projectID === projectID && !thread.isArchived && !thread.isTemporary);
    if (!nextThread) {
      selectThreadRequestRef.current += 1;
      setSelectedThreadID(undefined);
      setThreadDetail(null);
      setAssistantPanel(null);
      return;
    }
    await selectThread(nextThread.id, { syncProjectFilter: true });
  };

  const createThread = async () => {
    await createThreadWithMode(false);
  };

  const createTemporaryThread = async () => {
    await createThreadWithMode(true);
  };

  const createThreadWithMode = async (isTemporary: boolean) => {
    await cleanupTemporaryThread(selectedThreadID);
    const selectedProject = appState.projects.find((project) => sameID(project.id, selectedProjectID));
    const targetProjectID = selectedProject?.kind === "folder" ? undefined : selectedProjectID;
    const result = await window.openAssistElectron?.createThread(targetProjectID, isTemporary);
    if (!result) return;
    setShowArchivedThreads(false);
    setSelectedThreadID(result.thread.id);
    setSelectedProjectID(result.thread.projectID);
    setThreadDetail(result.detail);
    setAssistantPanel(null);
    setAppState((current) => ({
      ...current,
      threads: [result.thread, ...current.threads.filter((thread) => thread.id !== result.thread.id)]
    }));
    setActiveView("threads");
  };

  const createProject = async (name: string, kind: "project" | "folder", parentID?: string) => {
    const project = await window.openAssistElectron?.createProject(name, kind, parentID);
    if (!project) return;
    setAppState((current) => ({
      ...current,
      projects: [...current.projects, project],
      activeProjectID: project.id
    }));
    setSelectedProjectID(project.id);
    setShowArchivedThreads(false);
    setActiveView("threads");
    setSelectedThreadID(undefined);
    setThreadDetail(null);
    setAssistantPanel(null);
  };

  const selectNote = async (note: NoteItem) => {
    await flushNoteDraftBeforeNavigation();
    setSelectedNoteID(note.id);
    setSelectedNoteTarget({ scope: "project", projectID: note.projectID, noteID: note.id });
    setNotesScope("project");
    setSelectedProjectID(note.projectID);
    setAppState((current) => ({ ...current, activeProjectID: note.projectID, activeNoteID: note.id }));
    const detail = await window.openAssistElectron?.loadNote(note.projectID, note.id);
    if (detail) {
      setNoteDetail(detail);
      setNoteDraft(detail.markdown);
    }
  };

  const selectThreadNoteForNotes = async (note: ThreadNoteListItem) => {
    await flushNoteDraftBeforeNavigation();
    setSelectedNoteID(note.id);
    setSelectedNoteTarget({ scope: "thread", threadID: note.threadID, noteID: note.id, projectID: note.projectID });
    setNotesScope("thread");
    if (note.projectID) setSelectedProjectID(note.projectID);
    const workspace = await window.openAssistElectron?.selectThreadNote(note.threadID, note.id);
    if (workspace?.selectedNote) {
      setThreadNoteWorkspace(workspace);
      setThreadNoteDraft(workspace.selectedNote.markdown);
      setNoteDetail({
        id: workspace.selectedNote.id,
        title: workspace.selectedNote.title,
        markdown: workspace.selectedNote.markdown,
        path: workspace.selectedNote.path
      });
      setNoteDraft(workspace.selectedNote.markdown);
    }
  };

  const clearNotesEditor = async () => {
    await flushNoteDraftBeforeNavigation();
    setSelectedNoteID(undefined);
    setSelectedNoteTarget(null);
    setNoteDetail(null);
    setNoteDraft("");
  };

  const selectNotesProject = async (projectID: string) => {
    setSelectedProjectID(projectID);
    setShowArchivedThreads(false);
    setActiveView("notes");
    setAppState((current) => ({ ...current, activeProjectID: projectID }));
    if (notesScope === "thread") {
      const existingThreadNote = appState.threadNotes.find((note) => sameID(note.projectID, projectID));
      if (existingThreadNote) {
        await selectThreadNoteForNotes(existingThreadNote);
        return;
      }
      await clearNotesEditor();
      return;
    }
    const existingProjectNote = appState.notes.find((note) => sameID(note.projectID, projectID));
    if (existingProjectNote) {
      await selectNote(existingProjectNote);
      return;
    }
    await clearNotesEditor();
  };

  const selectNotesScope = async (scope: NotesScope) => {
    setNotesScope(scope);
    setActiveView("notes");
    const projectID = selectedProjectID
      ?? appState.activeProjectID
      ?? appState.projects.find((project) => project.kind !== "folder")?.id;
    if (!projectID) {
      await clearNotesEditor();
      return;
    }
    setSelectedProjectID(projectID);
    if (scope === "thread") {
      const existingThreadNote = appState.threadNotes.find((note) => sameID(note.projectID, projectID));
      if (existingThreadNote) {
        await selectThreadNoteForNotes(existingThreadNote);
        return;
      }
      await clearNotesEditor();
      return;
    }
    const existingProjectNote = appState.notes.find((note) => sameID(note.projectID, projectID));
    if (existingProjectNote) {
      await selectNote(existingProjectNote);
      return;
    }
    await clearNotesEditor();
  };

  const createNote = async () => {
    await flushNoteDraftBeforeNavigation();
    const projectID = selectedProjectID ?? appState.activeProjectID ?? appState.projects.find((project) => project.kind !== "folder")?.id;
    if (!projectID) return;
    const result = await window.openAssistElectron?.createNote(projectID);
    if (!result) return;
    setSelectedNoteID(result.note.id);
    setSelectedNoteTarget({ scope: "project", projectID: result.note.projectID, noteID: result.note.id });
    setNotesScope("project");
    setSelectedProjectID(result.note.projectID);
    setNoteDetail(result.detail);
    setNoteDraft(result.detail.markdown);
    setAppState((current) => ({
      ...current,
      notes: [result.note, ...current.notes.filter((note) => note.id !== result.note.id)],
      activeProjectID: result.note.projectID,
      activeNoteID: result.note.id
    }));
  };

  const saveNote = async () => {
    clearNoteAutosaveTimer();
    await persistNoteDraft("manual");
  };

  const openProjectNotes = async (projectID: string) => {
    await flushNoteDraftBeforeNavigation();
    setSelectedProjectID(projectID);
    setShowArchivedThreads(false);
    setActiveView("notes");
    setNotesScope("project");
    const existing = appState.notes.find((note) => sameID(note.projectID, projectID));
    if (existing) {
      await selectNote(existing);
      return;
    }
    const result = await window.openAssistElectron?.createNote(projectID);
    if (!result) return;
    setSelectedNoteID(result.note.id);
    setSelectedNoteTarget({ scope: "project", projectID: result.note.projectID, noteID: result.note.id });
    setNoteDetail(result.detail);
    setNoteDraft(result.detail.markdown);
    setAppState((current) => ({
      ...current,
      notes: [result.note, ...current.notes.filter((note) => note.id !== result.note.id)],
      activeProjectID: projectID
    }));
  };

  const openProjectMemory = async (projectID: string) => {
    const memory = await window.openAssistElectron?.loadProjectMemory(projectID);
    if (!memory) return;
    setActiveView("threads");
    setThreadMemory(memory);
    setAssistantPanel("memory");
    if (compact && !sidebarOpen) openSidebarAssistant();
  };

  const renameProjectFromMenu = async (project: ProjectItem) => {
    const name = window.prompt(project.kind === "folder" ? "Rename group" : "Rename project", project.title);
    if (!name?.trim() || name.trim() === project.title) return;
    await window.openAssistElectron?.renameProject(project.id, name.trim());
    await refreshAppState();
  };

  const updateProjectIconFromMenu = async (project: ProjectItem, symbol?: string | null) => {
    await window.openAssistElectron?.updateProjectIcon(project.id, symbol);
    await refreshAppState();
  };

  const linkProjectFolderFromMenu = async (project: ProjectItem) => {
    await window.openAssistElectron?.chooseProjectFolder(project.id);
    await refreshAppState();
  };

  const removeProjectFolderLinkFromMenu = async (project: ProjectItem) => {
    await window.openAssistElectron?.removeProjectFolderLink(project.id);
    await refreshAppState();
  };

  const moveProjectToFolderFromMenu = async (project: ProjectItem, folderID?: string | null) => {
    await window.openAssistElectron?.moveProjectToFolder(project.id, folderID);
    await refreshAppState();
  };

  const hideProjectFromMenu = async (project: ProjectItem) => {
    if (!window.confirm(`Hide "${project.title}" from the sidebar?`)) return;
    await window.openAssistElectron?.hideProject(project.id);
    if (selectedProjectID === project.id) setSelectedProjectID(undefined);
    const selectedHiddenThread = appState.threads.some((thread) =>
      thread.id === selectedThreadID && sameID(thread.projectID, project.id)
    );
    if (selectedHiddenThread) {
      setSelectedThreadID(undefined);
      setThreadDetail(null);
    }
    await refreshAppState();
  };

  const unhideProjectFromMenu = async (project: ProjectItem) => {
    await window.openAssistElectron?.unhideProject(project.id);
    await refreshAppState();
  };

  const deleteProjectFromMenu = async (project: ProjectItem) => {
    const label = project.kind === "folder" ? "group" : "project";
    if (!window.confirm(`Delete ${label} "${project.title}"? This cannot be undone.`)) return;
    await window.openAssistElectron?.deleteProject(project.id);
    if (selectedProjectID === project.id) {
      setSelectedProjectID(undefined);
      setSelectedThreadID(undefined);
      setThreadDetail(null);
    }
    await refreshAppState();
  };

  const renameThreadFromMenu = async (thread: ThreadItem) => {
    const title = window.prompt("Rename session", thread.title);
    if (!title?.trim() || title.trim() === thread.title) return;
    const updated = await window.openAssistElectron?.renameSession(thread.id, title.trim());
    if (updated) {
      setAppState((current) => ({
        ...current,
        threads: current.threads.map((item) => (item.id === updated.id ? { ...item, ...updated } : item))
      }));
      if (selectedThreadID === updated.id) {
        setThreadDetail((current) => current ? { ...current, title: updated.title } : current);
      }
    }
  };

  const promoteTemporaryThreadFromMenu = async (thread: ThreadItem) => {
    const updated = await window.openAssistElectron?.promoteTemporarySession(thread.id);
    if (!updated) return;
    setAppState((current) => ({
      ...current,
      threads: current.threads.map((item) => (item.id === updated.id ? { ...item, ...updated, isTemporary: false } : item))
    }));
  };

  const assignThreadToProjectFromMenu = async (thread: ThreadItem, projectID?: string | null) => {
    const updated = await window.openAssistElectron?.assignSessionToProject(thread.id, projectID);
    if (!updated) return;
    setAppState((current) => ({
      ...current,
      threads: current.threads.map((item) => (item.id === updated.id ? { ...item, ...updated } : item))
    }));
    if (selectedThreadID === updated.id) setSelectedProjectID(updated.projectID);
  };

  const archiveThreadFromMenu = async (thread: ThreadItem) => {
    const updated = await window.openAssistElectron?.archiveSession(thread.id);
    if (!updated) return;
    await refreshAppState();
    if (selectedThreadID === thread.id) {
      setSelectedThreadID(undefined);
      setThreadDetail(null);
    }
  };

  const unarchiveThreadFromMenu = async (thread: ThreadItem) => {
    await window.openAssistElectron?.unarchiveSession(thread.id);
    await refreshAppState();
  };

  const deleteThreadPermanentlyFromMenu = async (thread: ThreadItem) => {
    if (!window.confirm(`Delete "${thread.title}" permanently? This cannot be undone.`)) return;
    await window.openAssistElectron?.deleteSessionPermanently(thread.id);
    if (selectedThreadID === thread.id) {
      setSelectedThreadID(undefined);
      setThreadDetail(null);
    }
    await refreshAppState();
  };

  const toggleSkill = async (skill: SkillItem) => {
    if (!selectedThreadID) return;
    const attached = !skill.attached;
    const result = await window.openAssistElectron?.toggleSkill(selectedThreadID, skill.id, attached);
    if (result?.ok) {
      setAppState((current) => ({
        ...current,
        skills: current.skills.map((item) => (item.id === skill.id ? { ...item, attached } : item))
      }));
    }
  };

  const addSkillToState = (skill?: SkillItem | null) => {
    if (!skill) return;
    setAppState((current) => ({
      ...current,
      skills: [skill, ...current.skills.filter((item) => item.id !== skill.id)]
    }));
  };

  const importSkillFolder = async () => {
    const skill = await window.openAssistElectron?.importSkillFolder();
    addSkillToState(skill);
  };

  const importSkillFromGitHub = async (reference: string) => {
    const skill = await window.openAssistElectron?.importSkillFromGitHub(reference);
    addSkillToState(skill);
  };

  const createSkill = async (name: string, description: string) => {
    const skill = await window.openAssistElectron?.createSkill(name, description);
    addSkillToState(skill);
  };

  const togglePluginUse = (pluginID: string) => {
    setSelectedPluginID(pluginID);
    setSelectedPluginIDs((current) =>
      current.includes(pluginID) ? current.filter((item) => item !== pluginID) : [...current, pluginID]
    );
  };

  const useStarterPrompt = (pluginID: string, prompt: string) => {
    setSelectedPluginID(pluginID);
    setSelectedPluginIDs((current) => (current.includes(pluginID) ? current : [...current, pluginID]));
    setComposerText(prompt);
    setActiveView("threads");
    if (compact && !sidebarOpen) openSidebarAssistant();
  };

  const toggleAutomation = async (job: AutomationItem) => {
    const enabled = !job.enabled;
    const result = await window.openAssistElectron?.toggleScheduledJob(job.id, enabled);
    if (result?.ok) {
      setAppState((current) => ({
        ...current,
        automations: current.automations.map((item) => (item.id === job.id ? { ...item, enabled } : item))
      }));
    }
  };

  const createAutomation = async (name: string, prompt: string) => {
    const job = await window.openAssistElectron?.createScheduledJob(name, prompt);
    if (!job) return;
    setAppState((current) => ({
      ...current,
      automations: [...current.automations, job]
    }));
  };

	  const updateSettingValue = async (key: SettingsUpdateKey, value: SettingsUpdateValue) => {
    const previousSettings = appState.settings;
    const optimisticSettings = { ...previousSettings, [key]: value } as SettingsSnapshot;
    setAppState((current) => ({ ...current, settings: { ...current.settings, [key]: value } as SettingsSnapshot }));
    try {
	      const nextSettings = await window.openAssistElectron?.updateSetting(key, value);
	      if (nextSettings) {
        const normalizedSettings = normalizeRendererSettings(nextSettings);
        const confirmedValue = normalizedSettings[key as keyof SettingsSnapshot] ?? value;
	        setAppState((current) => ({
	          ...current,
	          settings: {
	            ...normalizedSettings,
              ...current.settings,
              [key]: confirmedValue,
	            availableMicrophones: current.settings.availableMicrophones
	          } as SettingsSnapshot
	        }));
        if (key === "compactEdge" && compact) {
          void window.openAssistElectron?.setWindowMode("sidebar", sidebarOpen, nextSettings.compactEdge === "left" ? "left" : "right");
        }
      }
    } catch (error) {
      setAppState((current) => ({ ...current, settings: previousSettings }));
      console.error(error);
    }
    if (key === "compactEdge" && compact) {
      void window.openAssistElectron?.setWindowMode("sidebar", sidebarOpen, String(value) === "left" ? "left" : "right");
    }
    if (key === "compactStyle" && value === "sidebar" && !compact) {
      openSidebarAssistant();
    }
  };

	  const updateShortcutValue = async (target: ShortcutTarget, keyCode: number, modifiers: number) => {
	    const nextSettings = await window.openAssistElectron?.updateShortcut(target, keyCode, modifiers);
	    if (nextSettings) {
        const normalizedSettings = normalizeRendererSettings(nextSettings);
	      setAppState((current) => ({
	        ...current,
	        settings: {
	          ...normalizedSettings,
	          availableMicrophones: current.settings.availableMicrophones
	        }
	      }));
	    }
	    return nextSettings;
	  };

	  const applySettingsSnapshot = (settings?: SettingsSnapshot) => {
	    if (!settings) return;
      const normalizedSettings = normalizeRendererSettings(settings);
	    setAppState((current) => ({
	      ...current,
	      settings: {
	        ...normalizedSettings,
	        availableMicrophones: current.settings.availableMicrophones
	      }
	    }));
	  };

  const openTarget = async (target: string) => window.openAssistElectron?.openTarget(target);

  const saveTelegramBotToken = async (token: string) => {
    const settings = await window.openAssistElectron?.saveTelegramBotToken(token);
    applySettingsSnapshot(settings);
    return settings;
  };

  const clearTelegramBotToken = async () => {
    const settings = await window.openAssistElectron?.clearTelegramBotToken();
    applySettingsSnapshot(settings);
    return settings;
  };

  const savePromptRewriteAPIKey = async (provider: string, token: string) => {
    const settings = await window.openAssistElectron?.savePromptRewriteAPIKey(provider, token);
    applySettingsSnapshot(settings);
    return settings;
  };

  const clearPromptRewriteAPIKey = async (provider: string) => {
    const settings = await window.openAssistElectron?.clearPromptRewriteAPIKey(provider);
    applySettingsSnapshot(settings);
    return settings;
  };

  const saveCloudTranscriptionAPIKey = async (provider: string, token: string) => {
    const settings = await window.openAssistElectron?.saveCloudTranscriptionAPIKey(provider, token);
    applySettingsSnapshot(settings);
    return settings;
  };

  const clearCloudTranscriptionAPIKey = async (provider: string) => {
    const settings = await window.openAssistElectron?.clearCloudTranscriptionAPIKey(provider);
    applySettingsSnapshot(settings);
    return settings;
  };

  const saveRealtimeOpenAIAPIKey = async (token: string) => {
    const settings = await window.openAssistElectron?.saveRealtimeOpenAIAPIKey(token);
    applySettingsSnapshot(settings);
    return settings;
  };

  const clearRealtimeOpenAIAPIKey = async () => {
    const settings = await window.openAssistElectron?.clearRealtimeOpenAIAPIKey();
    applySettingsSnapshot(settings);
    return settings;
  };

  const approveTelegramPairing = async () => {
    const settings = await window.openAssistElectron?.approveTelegramPairing();
    applySettingsSnapshot(settings);
    return settings;
  };

  const declineTelegramPairing = async () => {
    const settings = await window.openAssistElectron?.declineTelegramPairing();
    applySettingsSnapshot(settings);
    return settings;
  };

  const forgetTelegramPairing = async () => {
    const settings = await window.openAssistElectron?.forgetTelegramPairing();
    applySettingsSnapshot(settings);
    return settings;
  };

  const testTelegramConnection = async (token?: string) => {
    const result = await window.openAssistElectron?.testTelegramConnection(token);
    if (result?.ok) void refreshAppState();
    return result;
  };

  const refreshUsageSnapshot = async (provider: ProviderKey) => {
    const nextState = await window.openAssistElectron?.loadAppState();
    if (!nextState) return;
    setAppState((current) => ({
      ...current,
      usage: usageForProvider(nextState, provider),
      usageByBackend: nextState.usageByBackend
    }));
  };

  const selectProvider = (provider: ProviderKey) => {
    const threadID = currentThreadID();
    const providerName = providerLabel(provider);
    const nextModel = defaultModelForProvider(provider, appState.settings, providerModelOptionsByBackend[provider]);
    setProviderStatus(`Loading ${providerName} provider...`);
    setAppState((current) => ({
      ...current,
      settings: { ...current.settings, assistantBackend: provider, model: nextModel },
      usage: usageForProvider(current, provider),
      threads: current.threads.map((thread) =>
        thread.id === threadID ? { ...thread, activeProvider: provider, modelID: nextModel } : thread
      )
    }));
    void (async () => {
      try {
        let updatedThread: ThreadItem | null | undefined;
        if (threadID) {
          updatedThread = await window.openAssistElectron?.setThreadProvider(threadID, provider, nextModel);
        }
        const persistedModel = updatedThread?.modelID || nextModel;
        await window.openAssistElectron?.updateSetting("assistantBackend", provider);
        const nextSettings = await window.openAssistElectron?.updateSetting("model", persistedModel);
        setAppState((current) => ({
          ...current,
          settings: nextSettings
            ? {
                ...nextSettings,
                availableMicrophones: current.settings.availableMicrophones
              }
            : { ...current.settings, assistantBackend: provider, model: persistedModel },
          usage: usageForProvider(current, provider),
          threads: current.threads.map((thread) =>
            thread.id === (updatedThread?.id ?? threadID)
              ? { ...(updatedThread ?? thread), activeProvider: provider, modelID: persistedModel }
              : thread
          )
        }));
        await refreshUsageSnapshot(provider);
        setProviderStatus(`${providerName} ready`);
        window.setTimeout(() => setProviderStatus((current) => current === `${providerName} ready` ? null : current), 1800);
      } catch (error) {
        console.error(error);
        setProviderStatus(`Could not load ${providerName}`);
      }
    })();
  };

  const selectModel = (model: string) => {
    const threadID = currentThreadID();
    const targetProvider = activeProviderKey;
    setAppState((current) => ({
      ...current,
      settings: { ...current.settings, model },
      usage: usageForProvider(current, targetProvider),
      threads: current.threads.map((thread) =>
        thread.id === threadID ? { ...thread, modelID: model } : thread
      )
    }));
    void (async () => {
      try {
        let updatedThread: ThreadItem | null | undefined;
        if (threadID) {
          updatedThread = await window.openAssistElectron?.setThreadProvider(threadID, targetProvider, model);
        }
        const nextSettings = await window.openAssistElectron?.updateSetting("model", model);
        setAppState((current) => ({
          ...current,
          settings: nextSettings
            ? {
                ...nextSettings,
                availableMicrophones: current.settings.availableMicrophones
              }
            : { ...current.settings, model },
          usage: usageForProvider(current, targetProvider),
          threads: current.threads.map((thread) =>
            thread.id === (updatedThread?.id ?? threadID)
              ? { ...(updatedThread ?? thread), modelID: model }
              : thread
          )
        }));
        await refreshUsageSnapshot(targetProvider);
      } catch (error) {
        console.error(error);
      }
    })();
  };

  const speakAssistantText = async (text: string, force = false) => {
    const trimmed = text.trim();
    if (!trimmed) return;
    try {
      const result = await window.openAssistElectron?.speakAssistantResponse?.(trimmed, { force });
      if (result && !result.ok) {
        setProviderStatus(result.error || "Assistant voice output failed.");
        window.setTimeout(() => setProviderStatus(null), 2800);
      }
    } catch (error) {
      setProviderStatus(error instanceof Error ? error.message : "Assistant voice output failed.");
      window.setTimeout(() => setProviderStatus(null), 2800);
    }
  };

  const respondToApproval: ApprovalResponder = async (message, option) => {
    if (message.approvalRequestID == null) return;
    const sentLabel = `${option.label} sent`;
    const markApproval = (resolved: boolean) => {
      setThreadDetail((current) => current
        ? {
            ...current,
            messages: current.messages.map((existing) =>
              existing.id === message.id
                ? {
                    ...existing,
                    approvalResolved: resolved,
                    status: resolved ? "running" : existing.status,
                    activityStatus: resolved && existing.activityStatus === "waiting" ? "running" : existing.activityStatus,
                    updatedAt: Date.now()
                  }
                : existing
            )
          }
        : current);
    };
    markApproval(true);
    setProviderStatus(sentLabel);
    try {
      const result = await window.openAssistElectron?.respondProviderRequest?.(message.approvalRequestID, option.result);
      if (!result?.ok) {
        markApproval(false);
        setProviderStatus(result?.error || "Could not send approval.");
        return;
      }
      window.setTimeout(() => setProviderStatus((current) => current === sentLabel ? null : current), 1500);
    } catch (error) {
      markApproval(false);
      setProviderStatus(error instanceof Error ? error.message : "Could not send approval.");
    }
  };

  const sendMessage = async () => {
    if (isSending) return;
    if (nativeVoiceActiveRef.current) {
      await stopVoiceInput();
    } else if (recognitionRef.current) {
      recognitionRef.current.stop();
    }
    const prompt = composerText.trim();
    if (!prompt) return;
    const candidateThreadID = threadDetail?.threadID ?? selectedThreadID;
    const targetThreadID = candidateThreadID && appState.threads.some((thread) => thread.id === candidateThreadID)
      ? candidateThreadID
      : undefined;
    const fallbackProject = appState.projects.find((project) => selectedProjectID && sameID(project.id, selectedProjectID));
    const optimisticTitle = targetThreadID
      ? usableThreadTitle(threadDetail?.title) ?? usableThreadTitle(selectedThread?.title) ?? chatTitleForPrompt(prompt)
      : chatTitleForPrompt(prompt);
    const titleForDetail = (current?: ThreadDetail | null) =>
      targetThreadID ? usableThreadTitle(current?.title) ?? optimisticTitle : optimisticTitle;
    const composerMentions = composerMentionIDs(prompt, appState.plugins, appState.skills);
    const turnPluginIDs = Array.from(new Set([...selectedPluginIDs, ...composerMentions.pluginIDs]));
    setComposerText("");
    setIsSending(true);
    const turnStartedAt = Date.now();
    const providerRunID = `provider-run-${turnStartedAt}-${Math.random().toString(16).slice(2)}`;
    activeProviderRunIDRef.current = providerRunID;
    stopRequestedRef.current = false;
    const optimisticUser: ChatMessage = { id: `local-user-${turnStartedAt}`, role: "user", text: prompt };
    const pendingAssistant: ChatMessage = {
      id: `local-assistant-streaming-${turnStartedAt}`,
      role: "assistant",
      provider: activeProviderName,
      status: "running",
      text: ""
    };
    const removeOptimisticTurn = (messages: ChatMessage[]) =>
      messages.filter((message) => message.id !== optimisticUser.id && message.id !== pendingAssistant.id);
    const isCurrentTurnActivity = (message: ChatMessage) =>
      message.role === "activity" && (message.createdAt ?? turnStartedAt) >= turnStartedAt - 250;
    const messagesWithoutCurrentTurn = (messages: ChatMessage[]) =>
      removeOptimisticTurn(messages).filter((message) => !isCurrentTurnActivity(message));
    const activeTurnActivities = (messages: ChatMessage[]) =>
      removeOptimisticTurn(messages).filter(isCurrentTurnActivity);
    const finalizedActiveTurnActivities = (
      messages: ChatMessage[],
      finalStatus: ChatMessage["activityStatus"] = "completed"
    ) => activeTurnActivities(messages)
      .filter((activity) => !isGenericWorkActivity(activity))
      .map((activity) => ({
        ...activity,
        status: "completed" as const,
        activityStatus: activity.activityStatus === "failed" ? "failed" : finalStatus,
        updatedAt: Date.now()
      }));
    const mergeReasoningActivity = (existing: ChatMessage, next: ChatMessage) => {
      const previousText = (existing.activityDetail || existing.text || "").trim();
      const nextText = (next.activityDetail || next.text || "").trim();
      const mergedText = !previousText
        ? nextText
        : !nextText || previousText.includes(nextText)
          ? previousText
          : nextText.includes(previousText)
            ? nextText
            : `${previousText}${nextText}`;
      return {
        ...existing,
        ...next,
        text: mergedText || next.text,
        activityDetail: mergedText || next.activityDetail
      };
    };
    const putPendingLast = (messages: ChatMessage[], pending: ChatMessage) => [
      ...messages.filter((message) => message.id !== pending.id),
      pending
    ];
    const upsertActivityMessage = (messages: ChatMessage[], activity: ChatMessage) => {
      const pending = messages.find((message) => message.id === pendingAssistant.id);
      const base = messages.filter((message) => message.id !== pendingAssistant.id);
      const existingIndex = base.findIndex((message) => message.id === activity.id);
      const normalizedActivity = {
        ...activity,
        provider: activity.provider || activeProviderName,
        role: "activity" as const
      };
      if (isGenericWorkActivity(normalizedActivity)) {
        const nextBase = base.filter((message) => message.id !== activity.id);
        return pending ? [...nextBase, pending] : nextBase;
      }
      const nextBase = existingIndex >= 0
        ? base.map((message, index) => index === existingIndex
          ? normalizedActivity.activityKind === "reasoning"
            ? mergeReasoningActivity(message, normalizedActivity)
            : { ...message, ...normalizedActivity }
          : message)
        : [...base, normalizedActivity];
      return pending ? [...nextBase, pending] : nextBase;
    };
    const unsubscribeProviderEvents = window.openAssistElectron?.onProviderEvent?.((event: ProviderRunEvent) => {
      if (event.runID !== providerRunID) return;
      if (event.type === "status") {
        setProviderStatus(event.text);
        return;
      }
      if (event.type === "assistant-delta") {
        setThreadDetail((current) => {
          const messages = current?.messages ?? [];
          const pending = messages.find((message) => message.id === pendingAssistant.id) ?? pendingAssistant;
          const nextPending = {
            ...pending,
            provider: event.provider || pending.provider,
            status: "running" as const,
            text: `${pending.text ?? ""}${event.delta}`
          };
          return {
            threadID: event.threadID,
            title: titleForDetail(current),
            messages: putPendingLast(messages, nextPending)
          };
        });
        return;
      }
      if (event.type === "activity") {
        setThreadDetail((current) => ({
          threadID: event.threadID,
          title: titleForDetail(current),
          messages: upsertActivityMessage(current?.messages ?? [optimisticUser, pendingAssistant], event.activity)
        }));
        return;
      }
      if (event.type === "failed") {
        setProviderStatus(`${event.provider} failed`);
        return;
      }
      if (event.type === "completed") {
        setProviderStatus(`${event.provider} completed`);
        window.setTimeout(() => setProviderStatus((current) => current === `${event.provider} completed` ? null : current), 1500);
      }
    });
    setThreadDetail((current) => ({
      threadID: targetThreadID ?? "new",
      title: titleForDetail(current),
      messages: [...(targetThreadID ? current?.messages ?? [] : []), optimisticUser, pendingAssistant]
    }));
    try {
      const result = await window.openAssistElectron?.sendMessage(
        prompt,
        targetThreadID,
        turnPluginIDs,
        sessionInstructions,
        reasoningEffort,
        interactionMode,
        permissionMode,
        composerMentions.skillIDs,
        providerRunID
      );
      if (result) {
        const completedTitle =
          usableThreadTitle(result.thread?.title) ??
          usableThreadTitle(result.title) ??
          optimisticTitle;
        const completedAt = Date.now();
        setSelectedThreadID(result.threadID);
        setThreadDetail((current) => {
          const currentMessages = current?.messages ?? [];
          return {
            threadID: result.threadID,
            title: completedTitle,
            messages: [
              ...(targetThreadID ? messagesWithoutCurrentTurn(currentMessages) : []),
              result.user,
              ...finalizedActiveTurnActivities(currentMessages),
              result.assistant
            ]
          };
        });
        setAppState((current) => {
          const fallbackThread: ThreadItem = {
            id: result.threadID,
            title: completedTitle,
            projectID: result.thread?.projectID ?? selectedThread?.projectID ?? selectedProjectID,
            project: result.thread?.project ?? selectedThread?.project ?? fallbackProject?.title,
            activeProvider: result.thread?.activeProvider ?? selectedThread?.activeProvider ?? activeProviderKey,
            modelID: result.thread?.modelID ?? selectedThread?.modelID ?? current.settings.model,
            age: result.thread?.age ?? "1m",
            updatedAt: result.thread?.updatedAt ?? completedAt,
            isArchived: result.thread?.isArchived ?? selectedThread?.isArchived,
            isTemporary: result.thread?.isTemporary ?? selectedThread?.isTemporary,
            active: true
          };
          let foundThread = false;
          const threads = current.threads.map((thread) => {
            if (thread.id !== result.threadID) return thread;
            foundThread = true;
            return {
              ...thread,
              ...result.thread,
              title: completedTitle,
              age: result.thread?.age ?? "1m",
              updatedAt: result.thread?.updatedAt ?? completedAt,
              activeProvider: result.thread?.activeProvider ?? thread.activeProvider ?? activeProviderKey,
              modelID: result.thread?.modelID ?? thread.modelID,
              active: true
            };
          });
          return {
            ...current,
            threads: foundThread ? threads : [fallbackThread, ...threads]
          };
        });
        void refreshAppState();
      }
    } catch (error) {
      const message = readableProviderError(error);
      const provider = activeProviderName;
      const wasStopped = stopRequestedRef.current || /stopp?ed|cancelled|canceled|interrupt/i.test(message);
      setThreadDetail((current) => {
        const currentMessages = current?.messages ?? [];
        return {
          threadID: targetThreadID ?? "new",
          title: titleForDetail(current),
          messages: [
            ...(targetThreadID ? messagesWithoutCurrentTurn(currentMessages) : []),
            optimisticUser,
            ...finalizedActiveTurnActivities(currentMessages, wasStopped ? "completed" : "failed"),
            {
              id: `assistant-error-${Date.now()}`,
              role: "assistant",
              provider,
              text: wasStopped ? `${provider} was stopped.` : `${provider} could not finish this turn: ${message}`
            }
          ]
        };
      });
    } finally {
      unsubscribeProviderEvents?.();
      if (activeProviderRunIDRef.current === providerRunID) activeProviderRunIDRef.current = null;
      stopRequestedRef.current = false;
      setIsSending(false);
    }
  };

  const stopMessage = async () => {
    const runID = activeProviderRunIDRef.current;
    if (!isSending || !runID) {
      if (liveVoiceStatus !== "delegating") return;
      setProviderStatus("Stopping Codex task...");
      try {
        const result = await openAssistRealtimeAPI()?.stopDelegation?.();
        if (result && !result.ok && result.error) {
          setProviderStatus(result.error);
          return;
        }
        setProviderStatus("Codex task stop requested.");
      } catch (error) {
        const message = error instanceof Error ? error.message : "Could not stop the delegated Codex task.";
        setProviderStatus(message);
      }
      return;
    }
    stopRequestedRef.current = true;
    setProviderStatus("Stopping Codex...");
    try {
      const result = await window.openAssistElectron?.stopMessage(runID);
      if (result && !result.ok && result.error) setProviderStatus(result.error);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Could not stop the current turn.";
      setProviderStatus(message);
    }
  };

  if (activeView === "settings") {
    return (
      <div className={shellClass} style={shellStyle}>
        <div className="window-drag-strip" aria-hidden="true" />
        <SettingsView
          initialSection={settingsInitialSection}
          onOpenAssistant={openAssistant}
          onOpenTarget={openTarget}
          onRefresh={() => void refreshAppState()}
          onSaveTelegramBotToken={saveTelegramBotToken}
          onClearTelegramBotToken={clearTelegramBotToken}
          onApproveTelegramPairing={approveTelegramPairing}
          onDeclineTelegramPairing={declineTelegramPairing}
          onForgetTelegramPairing={forgetTelegramPairing}
          onTestTelegramConnection={testTelegramConnection}
          onSavePromptRewriteAPIKey={savePromptRewriteAPIKey}
          onClearPromptRewriteAPIKey={clearPromptRewriteAPIKey}
          onSaveCloudTranscriptionAPIKey={saveCloudTranscriptionAPIKey}
          onClearCloudTranscriptionAPIKey={clearCloudTranscriptionAPIKey}
          onSaveRealtimeOpenAIAPIKey={saveRealtimeOpenAIAPIKey}
          onClearRealtimeOpenAIAPIKey={clearRealtimeOpenAIAPIKey}
          onUpdateSetting={updateSettingValue}
          onUpdateShortcut={updateShortcutValue}
          settings={appState.settings}
        />
      </div>
    );
  }

  const isLeftSidebar = compact && appState.settings.compactEdge === "left";
  const archivedCount = appState.threads.filter((thread) => thread.isArchived).length;
  const sidebarThreads = appState.threads.filter((thread) => {
    if (Boolean(thread.isArchived) !== showArchivedThreads) return false;
    if (!selectedProjectID) return true;
    return thread.projectID
      ? thread.projectID.toLowerCase() === selectedProjectID.toLowerCase()
      : false;
  }).sort((left, right) => (right.updatedAt ?? 0) - (left.updatedAt ?? 0));
  const toggleArchivedThreads = () => {
    setShowArchivedThreads((current) => !current);
    setActiveView("threads");
    setSelectedProjectID(undefined);
    setAssistantPanel(null);
  };
  const edgeHandleIcon = compact && sidebarOpen
    ? isLeftSidebar
      ? <ChevronLeft size={18} strokeWidth={2.15} />
      : <ChevronRight size={18} strokeWidth={2.15} />
    : isLeftSidebar
      ? <ChevronRight size={19} strokeWidth={2.15} />
      : <ChevronLeft size={19} strokeWidth={2.15} />;

  return (
    <div className={shellClass} style={shellStyle}>
      <Sidebar
        activeView={activeView}
        onChangeView={setActiveView}
        onOpenSettings={openSettings}
        compact={compact}
        onCollapseSidebar={collapseSidebar}
        projects={appState.projects}
        hiddenProjects={appState.hiddenProjects ?? []}
        threads={sidebarThreads}
        notes={appState.notes}
        threadNotes={appState.threadNotes}
        noteFolders={appState.noteFolders}
        selectedProjectID={selectedProjectID}
        selectedThreadID={selectedThreadID}
        activeNoteTarget={selectedNoteTarget}
        notesScope={notesScope}
        showArchivedThreads={showArchivedThreads}
        archivedCount={archivedCount}
        onSelectProject={(projectID) => {
          if (activeView === "notes") void selectNotesProject(projectID);
          else void selectProject(projectID);
        }}
        onClearProjectFilter={() => { void clearProjectFilter(); }}
        onSelectThread={selectThread}
        onSelectNotesScope={(scope) => { void selectNotesScope(scope); }}
        onSelectNote={(note) => { void selectNote(note); }}
        onSelectThreadNoteItem={(note) => { void selectThreadNoteForNotes(note); }}
        onOpenThreadFromNote={(note) => {
          setActiveView("threads");
          void selectThread(note.threadID, { syncProjectFilter: false });
        }}
        onToggleArchivedThreads={toggleArchivedThreads}
        onCreateProject={createProject}
        onCreateThread={createThread}
        onCreateTemporaryThread={createTemporaryThread}
        onCreateNote={() => { void createNote(); }}
        sidebarWidth={sidebarWidth}
        onResizeSidebar={setSidebarWidth}
        onResizingSidebarChange={setIsResizingSidebar}
        onHideSidebar={() => setSidebarHidden(true)}
        onOpenProjectNotes={(projectID) => { void openProjectNotes(projectID); }}
        onOpenProjectMemory={(projectID) => { void openProjectMemory(projectID); }}
        onOpenThreadNote={(thread) => { void openThreadNoteForThread(thread.id); }}
        onCreateThreadNote={(thread) => { void createThreadNoteForThread(thread.id); }}
        onOpenThreadMemory={(thread) => { void openMemoryForThread(thread.id); }}
        onOpenThreadInstructions={(thread) => { void openInstructionsForThread(thread.id); }}
        onRenameProject={(project) => { void renameProjectFromMenu(project); }}
        onUpdateProjectIcon={(project, symbol) => { void updateProjectIconFromMenu(project, symbol); }}
        onLinkProjectFolder={(project) => { void linkProjectFolderFromMenu(project); }}
        onRemoveProjectFolderLink={(project) => { void removeProjectFolderLinkFromMenu(project); }}
        onMoveProjectToFolder={(project, folderID) => { void moveProjectToFolderFromMenu(project, folderID); }}
        onHideProject={(project) => { void hideProjectFromMenu(project); }}
        onUnhideProject={(project) => { void unhideProjectFromMenu(project); }}
        onDeleteProject={(project) => { void deleteProjectFromMenu(project); }}
        onRenameThread={(thread) => { void renameThreadFromMenu(thread); }}
        onPromoteTemporaryThread={(thread) => { void promoteTemporaryThreadFromMenu(thread); }}
        onAssignThreadToProject={(thread, projectID) => { void assignThreadToProjectFromMenu(thread, projectID); }}
        onArchiveThread={(thread) => { void archiveThreadFromMenu(thread); }}
        onUnarchiveThread={(thread) => { void unarchiveThreadFromMenu(thread); }}
        onDeleteThreadPermanently={(thread) => { void deleteThreadPermanentlyFromMenu(thread); }}
      />
      {!compact && sidebarHidden && (
        <button
          type="button"
          className="sidebar-expand-button"
          onClick={() => setSidebarHidden(false)}
          aria-label="Show sidebar"
          title="Show sidebar"
        >
          <PanelLeftOpen size={15} strokeWidth={2} />
        </button>
      )}
      <FeatureRouter
        activeView={activeView}
        settingsInitialSection={settingsInitialSection}
        compact={compact}
        onToggleCompact={toggleCompact}
        onHideWindow={compact ? collapseSidebar : hideWindow}
        onOpenThreadNote={openThreadNote}
        onOpenInstructions={openInstructions}
        onOpenMemory={openMemory}
        onOpenSkills={openSkills}
        onOpenPlugins={openPlugins}
        onCloseThreadNotePanel={closeThreadNotePanel}
        onBackToThreads={backToThreads}
        onRefreshAppState={() => void refreshAppState()}
        onOpenAssistant={openAssistant}
        appState={appState}
        providerModelOptionsByBackend={providerModelOptionsByBackend}
        selectedThreadID={selectedThreadID}
        selectedProjectID={selectedProjectID}
        threadDetail={threadDetail}
        selectedNoteID={selectedNoteID}
        selectedNoteTarget={selectedNoteTarget}
        notesScope={notesScope}
        noteDetail={noteDetail}
        noteDraft={noteDraft}
        noteSaveStatus={noteSaveStatus}
        composerText={composerText}
        isSending={isSending}
        interactionMode={interactionMode}
        permissionMode={permissionMode}
        reasoningEffort={reasoningEffort}
        voiceStatus={voiceStatus}
        voiceStatusText={voiceStatusText}
        voiceError={voiceError}
        liveVoiceStatus={liveVoiceStatus}
        liveVoiceStatusText={liveVoiceStatusText}
        providerStatus={providerStatus}
        selectedPluginID={selectedPluginID}
        selectedPluginIDs={selectedPluginIDs}
        onComposerText={setComposerText}
        onSend={sendMessage}
        onStop={stopMessage}
        onVoiceInput={toggleVoiceInput}
        onLiveVoice={toggleLiveVoice}
        onOpenRealtimeSettings={openRealtimeSettings}
        onToggleAgentic={toggleAgenticMode}
        onCycleReasoning={cycleReasoning}
        onSelectPermissionMode={setPermissionMode}
        onCreateTemporaryThread={createTemporaryThread}
        onAddTextToThreadNote={(text) => { void appendTextToThreadNote(text); }}
        onSpeakText={(text) => { void speakAssistantText(text, true); }}
        onRespondToApproval={respondToApproval}
        onSelectProvider={selectProvider}
        onSelectModel={selectModel}
        onSelectNotesProject={(projectID) => { void selectNotesProject(projectID); }}
        onSelectNotesScope={(scope) => { void selectNotesScope(scope); }}
        onSelectNote={selectNote}
        onSelectThreadNoteItem={(note) => { void selectThreadNoteForNotes(note); }}
        onCreateNote={createNote}
        onNoteDraft={setNoteDraft}
        onSaveNote={saveNote}
        onToggleAutomation={toggleAutomation}
        onCreateAutomation={createAutomation}
        onToggleSkill={toggleSkill}
        onImportSkillFolder={importSkillFolder}
        onImportSkillFromGitHub={importSkillFromGitHub}
        onCreateSkill={createSkill}
        onSavePromptRewriteAPIKey={savePromptRewriteAPIKey}
        onClearPromptRewriteAPIKey={clearPromptRewriteAPIKey}
        onSaveCloudTranscriptionAPIKey={saveCloudTranscriptionAPIKey}
        onClearCloudTranscriptionAPIKey={clearCloudTranscriptionAPIKey}
        onUpdateSetting={updateSettingValue}
        onUpdateShortcut={updateShortcutValue}
        onSelectPlugin={setSelectedPluginID}
        onTogglePluginUse={togglePluginUse}
        onUseStarterPrompt={useStarterPrompt}
      />
      {activeView === "threads" && currentThreadID() && assistantPanel !== "thread-note" && (
        <button
          className="thread-note-side-handle"
          aria-label="Open thread note"
          title="Open thread note"
          aria-expanded={false}
          onClick={() => { void openThreadNote(); }}
        >
          <span aria-hidden="true">‹</span>
        </button>
      )}
      <AssistantInspectorPanel
        panel={assistantPanel}
        sessionInstructions={sessionInstructions}
        threadNoteWorkspace={threadNoteWorkspace}
        threadNoteDraft={threadNoteDraft}
        threadMemory={threadMemory}
        onClose={() => setAssistantPanel(null)}
        onSessionInstructions={setSessionInstructions}
        onClearSessionInstructions={() => setSessionInstructions("")}
        onThreadNoteDraft={setThreadNoteDraft}
        onSaveThreadNote={saveCurrentThreadNote}
        onCreateThreadNote={createCurrentThreadNote}
        onSelectThreadNote={selectCurrentThreadNote}
        onRefreshMemory={() => void openMemory()}
      />
      <button
        className="edge-handle"
        aria-label={compact && sidebarOpen ? "Close sidebar assistant" : "Open sidebar assistant"}
        title={compact && sidebarOpen ? "Close sidebar assistant" : "Open sidebar assistant"}
        onClick={toggleSidebarPull}
      >
        {edgeHandleIcon}
      </button>
    </div>
  );
}
