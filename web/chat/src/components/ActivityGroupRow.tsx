import { memo, useState } from "react";
import type { ActivityGroupItem, ChatMessage } from "../types";
import { ActivityIcon } from "./ActivityIcon";
import { ActivityDetailSections } from "./ActivityDetailSections";
import { ChevronIcon } from "./ChevronIcon";
import { FileChangeSummary } from "./FileChangeSummary";

function ActivityGroupItemRow({ item }: { item: ActivityGroupItem }) {
  const [expanded, setExpanded] = useState(false);
  const detailSections = item.detailSections || [];
  const canExpand = detailSections.length > 0;
  const isRunning = item.status === "running";
  const statusClass =
    item.status === "completed"
      ? "status-completed"
      : item.status === "failed"
        ? "status-failed"
        : "status-running";

  const summaryContent = (
    <>
      <ActivityIcon kind={item.icon} status={item.status} />
      <div className="activity-group-item-copy">
        <span className="activity-title">{item.title}</span>
        {item.detail && <span className="activity-detail">{item.detail}</span>}
      </div>
      {item.statusLabel && (
        <span className={`activity-status-label ${statusClass}`}>
          {item.statusLabel}
        </span>
      )}
      {canExpand && (
        <span className="activity-toggle-button" aria-hidden="true">
          <ChevronIcon expanded={expanded} className="expand-icon" />
        </span>
      )}
    </>
  );

  return (
    <div className={`activity-group-item${expanded ? " expanded" : ""}`}>
      {canExpand ? (
        <button
          type="button"
          className={`activity-group-item-summary activity-group-item-summary-button${isRunning ? " activity-card-running" : ""}`}
          onClick={() => setExpanded((current) => !current)}
          aria-expanded={expanded}
        >
          {summaryContent}
        </button>
      ) : (
        <div className={`activity-group-item-summary${isRunning ? " activity-card-running" : ""}`}>
          {summaryContent}
        </div>
      )}

      {expanded && (
        <div className="activity-group-item-details">
          {item.icon === "fileChange" && (
            <FileChangeSummary sections={detailSections} />
          )}
          <ActivityDetailSections sections={detailSections} />
        </div>
      )}
    </div>
  );
}

function ActivityGroupRowInner({ message }: { message: ChatMessage }) {
  const [expanded, setExpanded] = useState(false);
  const transitionClass = message.transitionState
    ? ` is-${message.transitionState}`
    : "";
  const items = message.groupItems || [];
  const completedCount = items.filter((i) => i.status === "completed").length;
  const runningCount = items.filter((i) => i.status === "running").length;
  const title = buildActivityGroupTitle(items);
  const summary = buildActivityGroupSummary(items, runningCount, completedCount);
  const groupIcon = buildActivityGroupIcon(items);
  const isRunning = runningCount > 0;

  return (
    <div className={`message-row activity-group-row${transitionClass}`}>
      <button
        type="button"
        className={`activity-card activity-card-button activity-group-toggle${isRunning ? " activity-card-running" : ""}`}
        onClick={() => setExpanded((current) => !current)}
        aria-expanded={expanded}
      >
        <div className="activity-icon-wrap">
          {groupIcon ? (
            <ActivityIcon
              kind={groupIcon}
              status={runningCount > 0 ? "running" : "completed"}
            />
          ) : (
            <span className="activity-dot status-completed" />
          )}
        </div>
        <div className="activity-body">
          <span className="activity-title">{title}</span>
          <span className="activity-detail">{summary}</span>
        </div>
        <div className="activity-meta">
          <span className="activity-toggle-button" aria-hidden="true">
            <ChevronIcon expanded={expanded} className="expand-icon" />
          </span>
        </div>
      </button>

      {expanded && (
        <div className="activity-group-items">
          {items.map((item) => (
            <ActivityGroupItemRow key={item.id} item={item} />
          ))}
        </div>
      )}
    </div>
  );
}

export const ActivityGroupRow = memo(ActivityGroupRowInner);

function buildActivityGroupTitle(items: ActivityGroupItem[]): string {
  const counts = countKinds(items);
  const commands = counts.commandExecution || 0;
  const fileChanges = counts.fileChange || 0;
  const searches = counts.webSearch || 0;

  const fragments: string[] = [];

  if (commands > 0) {
    fragments.push("explored the workspace");
  }
  if (fileChanges > 0) {
    fragments.push(
      `edited ${fileChanges} file${fileChanges === 1 ? "" : "s"}`
    );
  }
  if (searches > 0) {
    fragments.push(`ran ${searches} search${searches === 1 ? "" : "es"}`);
  }

  if (fragments.length === 0) {
    return items.length === 1 ? "Activity" : `${items.length} activities`;
  }

  const joined = fragments.slice(0, 2).join(", ");
  return joined.charAt(0).toUpperCase() + joined.slice(1);
}

function buildActivityGroupSummary(
  items: ActivityGroupItem[],
  runningCount: number,
  completedCount: number
): string {
  const counts = countKinds(items);
  const fragments: string[] = [];

  if (counts.commandExecution) {
    fragments.push(
      `${counts.commandExecution} command${counts.commandExecution === 1 ? "" : "s"}`
    );
  }
  if (counts.fileChange) {
    fragments.push(
      `${counts.fileChange} file change${counts.fileChange === 1 ? "" : "s"}`
    );
  }
  if (counts.webSearch) {
    fragments.push(
      `${counts.webSearch} search${counts.webSearch === 1 ? "" : "es"}`
    );
  }

  const statusSummary =
    runningCount > 0
      ? `${runningCount} running, ${completedCount} completed`
      : `${completedCount} completed`;

  if (fragments.length === 0) {
    return statusSummary;
  }

  return `${fragments.slice(0, 3).join(", ")} • ${statusSummary}`;
}

function buildActivityGroupIcon(items: ActivityGroupItem[]): string | undefined {
  const icons = Array.from(new Set(items.map((item) => item.icon).filter(Boolean)));
  return icons.length === 1 ? icons[0] : undefined;
}

function countKinds(items: ActivityGroupItem[]): Record<string, number> {
  const counts: Record<string, number> = {};

  for (const item of items) {
    const kind = item.icon || "other";
    counts[kind] = (counts[kind] || 0) + 1;
  }

  return counts;
}
