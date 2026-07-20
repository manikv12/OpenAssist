import { memo } from "react";
import { AppIcon } from "./AppIcon";

interface Props {
  kind?: string;
  status?: string;
}

const activityIcons: Record<string, string> = {
  commandExecution: "terminal.fill",
  fileChange: "doc.text",
  webSearch: "search",
  browserAutomation: "globe",
  mcpToolCall: "wrench",
  dynamicToolCall: "gearshape",
  subagent: "bot",
  reasoning: "brain",
  permission: "lock",
  other: "play",
};

function ActivityIconInner({ kind, status }: Props) {
  const symbol = (kind && activityIcons[kind]) || activityIcons.other;
  const statusClass =
    status === "completed"
      ? "icon-completed"
      : status === "failed"
        ? "icon-failed"
        : "icon-running";

  return (
    <AppIcon
      symbol={symbol}
      className={`activity-svg-icon ${statusClass}`}
      size={16}
      strokeWidth={2}
    />
  );
}

export const ActivityIcon = memo(ActivityIconInner);
