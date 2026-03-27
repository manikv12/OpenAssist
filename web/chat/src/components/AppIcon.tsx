import {
  Archive,
  ArrowDown,
  ArrowUp,
  Bot,
  BrainCircuit,
  BriefcaseBusiness,
  BookOpen,
  Check,
  CircleArrowDown,
  CircleArrowUp,
  CircleMinus,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  ChevronUp,
  Circle,
  Clock3,
  Copy,
  EyeOff,
  FileText,
  Folder,
  FolderMinus,
  FolderPlus,
  Globe,
  Layers3,
  Lock,
  MessageSquareText,
  Mic,
  PanelLeftClose,
  PanelLeftOpen,
  Pencil,
  Pin,
  Play,
  Plus,
  RotateCcw,
  Search,
  Settings,
  Sparkles,
  Star,
  TerminalSquare,
  Trash2,
  Undo2,
  VolumeX,
  Wrench,
  X,
  type LucideIcon,
} from "lucide-react";

interface AppIconProps {
  symbol: string;
  className?: string;
  size?: number;
  strokeWidth?: number;
}

const symbolIconMap: Record<string, LucideIcon> = {
  "bubble.left.and.bubble.right": MessageSquareText,
  "doc.text": FileText,
  "folder.badge.plus": FolderPlus,
  folder: Folder,
  "folder.fill": Folder,
  "square.stack.3d.up.fill": Layers3,
  "briefcase.fill": BriefcaseBusiness,
  "book.closed.fill": BookOpen,
  "terminal.fill": TerminalSquare,
  sparkles: Sparkles,
  "star.fill": Star,
  brain: BrainCircuit,
  "clock.badge.checkmark.fill": Clock3,
  clock: Clock3,
  archivebox: Archive,
  gearshape: Settings,
  "sidebar.left": PanelLeftClose,
  "sidebar.right": PanelLeftOpen,
  "chevron.down": ChevronDown,
  "chevron.left": ChevronLeft,
  "chevron.up": ChevronUp,
  "chevron.right": ChevronRight,
  plus: Plus,
  "mic.fill": Mic,
  "speaker.slash.fill": VolumeX,
  "arrow.up": ArrowUp,
  "arrow.down": ArrowDown,
  copy: Copy,
  check: Check,
  undo: Undo2,
  search: Search,
  globe: Globe,
  wrench: Wrench,
  bot: Bot,
  play: Play,
  lock: Lock,
  xmark: X,
  pencil: Pencil,
  "folder.badge.minus": FolderMinus,
  "eye.slash": EyeOff,
  trash: Trash2,
  pin: Pin,
  "minus.circle": CircleMinus,
  "tray.and.arrow.up": CircleArrowUp,
  "arrow.counterclockwise": RotateCcw,
  "arrow.down.circle": CircleArrowDown,
};

function resolveIcon(symbol: string): LucideIcon {
  const directIcon = symbolIconMap[symbol];
  if (directIcon) {
    return directIcon;
  }

  if (symbol.includes("folder")) return Folder;
  if (symbol.includes("archive")) return Archive;
  if (symbol.includes("clock")) return Clock3;
  if (symbol.includes("trash")) return Trash2;
  if (symbol.includes("pencil")) return Pencil;
  if (symbol.includes("pin")) return Pin;
  if (symbol.includes("sparkle")) return Sparkles;
  if (symbol.includes("brain")) return BrainCircuit;
  if (symbol.includes("book")) return BookOpen;
  if (symbol.includes("briefcase")) return BriefcaseBusiness;
  if (symbol.includes("terminal")) return TerminalSquare;
  if (symbol.includes("bubble") || symbol.includes("message")) return MessageSquareText;
  if (symbol.includes("gear") || symbol.includes("slider")) return Settings;
  if (symbol.includes("globe") || symbol.includes("browser")) return Globe;
  if (symbol.includes("lock") || symbol.includes("permission")) return Lock;
  if (symbol.includes("wrench") || symbol.includes("tool")) return Wrench;
  if (symbol.includes("bot") || symbol.includes("agent")) return Bot;
  if (symbol.includes("play")) return Play;
  if (symbol.includes("copy")) return Copy;
  if (symbol.includes("check")) return Check;
  if (symbol.includes("undo")) return Undo2;
  if (symbol.includes("eye")) return EyeOff;
  if (symbol.includes("xmark") || symbol.includes("close")) return X;
  if (symbol.includes("chevron")) {
    if (symbol.includes("up")) return ChevronUp;
    if (symbol.includes("left")) return ChevronLeft;
    if (symbol.includes("right")) return ChevronRight;
    return ChevronDown;
  }
  if (symbol.includes("counterclockwise")) return RotateCcw;
  if (symbol.includes("minus")) return CircleMinus;
  if (symbol.includes("arrow.up")) return ArrowUp;
  if (symbol.includes("arrow.down")) return ArrowDown;
  if (symbol.includes("mic")) return Mic;

  return Circle;
}

export function AppIcon({
  symbol,
  className,
  size,
  strokeWidth = 1.9,
}: AppIconProps) {
  const Icon = resolveIcon(symbol);

  return (
    <Icon
      aria-hidden="true"
      className={className}
      size={size}
      strokeWidth={strokeWidth}
    />
  );
}
