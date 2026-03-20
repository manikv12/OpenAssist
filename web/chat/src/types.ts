export interface ChatMessage {
  id: string;
  type: "user" | "assistant" | "activity" | "activityGroup" | "system";
  text?: string;
  isStreaming: boolean;
  timestamp: number; // Unix ms
  images?: string[]; // base64 data URIs
  emphasis?: boolean;
  canUndo?: boolean;
  canEdit?: boolean;
  rewriteAnchorID?: string;
  transitionState?: "removing";

  // Activity-specific
  activityIcon?: string;
  activityTitle?: string;
  activityDetail?: string;
  activityStatus?: "running" | "completed" | "failed";
  activityStatusLabel?: string;
  detailSections?: ActivityDetailSection[];

  // Activity group
  groupItems?: ActivityGroupItem[];
}

export interface ActivityGroupItem {
  id: string;
  icon?: string;
  title: string;
  detail?: string;
  status: "running" | "completed" | "failed";
  statusLabel?: string;
  timestamp: number;
  detailSections?: ActivityDetailSection[];
}

export interface ActivityDetailSection {
  title: string;
  text: string;
}

export interface TypingState {
  visible: boolean;
  title?: string;
  detail?: string;
}

export interface ScrollState {
  isPinned: boolean;
  isScrolledUp: boolean;
  distanceFromTop: number;
}
