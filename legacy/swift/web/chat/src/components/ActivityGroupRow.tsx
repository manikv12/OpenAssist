import { memo, useEffect, useMemo, useState, type CSSProperties } from "react";
import type { ActivityGroupItem, ChatMessage } from "../types";
import { ActivityIcon } from "./ActivityIcon";
import { ActivityDetailSections } from "./ActivityDetailSections";
import { ChevronIcon } from "./ChevronIcon";
import { FileChangeSummary } from "./FileChangeSummary";
import {
  buildActivityActionDetail,
  buildActivityActionLabel,
  buildActivityTrailModel,
  compactActivityTargetLabel,
  resolveActivityPrimaryTarget,
  splitActivityLabelLead,
} from "./activityPresentation";

function ActivityGroupItemRow({
  item,
  highlightRunning = false,
}: {
  item: ActivityGroupItem;
  highlightRunning?: boolean;
}) {
  const [expanded, setExpanded] = useState(false);
  const detailSections = item.detailSections || [];
  const canExpand = detailSections.length > 0;
  const isRunning = item.status === "running";
  const shouldAnimateRunning = isRunning && highlightRunning;
  const statusClass =
    item.status === "completed"
      ? "status-completed"
      : item.status === "failed"
        ? "status-failed"
        : "status-running";
  const actionTitle =
    buildActivityActionLabel(item.icon, item.activityTargets, item.title) ||
    item.title;
  const actionDetail = buildActivityActionDetail(item.activityTargets, item.detail);
  const primaryTarget = resolveActivityPrimaryTarget(item.activityTargets, actionDetail);
  const targetPillLabel = compactActivityTargetLabel(primaryTarget);
  const titleLead =
    splitActivityLabelLead(actionTitle, primaryTarget?.label) ||
    splitActivityLabelLead(actionTitle, targetPillLabel) ||
    actionTitle;
  const detailLine =
    actionDetail && actionDetail !== primaryTarget?.detail && actionDetail !== primaryTarget?.label
      ? actionDetail
      : primaryTarget?.detail && primaryTarget.detail !== targetPillLabel
        ? primaryTarget.detail
        : undefined;

  const summaryContent = (
    <>
      <ActivityIcon kind={item.icon} status={item.status} />
      <div className="activity-group-item-copy">
        <span className="activity-title-line">
          {titleLead ? <span className="activity-title">{titleLead}</span> : null}
          {targetPillLabel ? (
            <span className="activity-target-pill" title={primaryTarget?.detail || primaryTarget?.label}>
              {targetPillLabel}
            </span>
          ) : null}
        </span>
        {detailLine && <span className="activity-detail">{detailLine}</span>}
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
          className={`activity-group-item-summary activity-group-item-summary-button${shouldAnimateRunning ? " activity-card-running" : ""}`}
          onClick={() => setExpanded((current) => !current)}
          aria-expanded={expanded}
        >
          {summaryContent}
        </button>
      ) : (
        <div className={`activity-group-item-summary${shouldAnimateRunning ? " activity-card-running" : ""}`}>
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

function ActivityTrail({
  title,
  items,
  running,
}: {
  title: string;
  items: ActivityGroupItem[];
  running: boolean;
}) {
  const trail = buildActivityTrailModel(items, running);
  if (!trail) {
    return null;
  }

  const latestActiveIndex = (() => {
    for (let index = trail.entries.length - 1; index >= 0; index -= 1) {
      if (trail.entries[index].status === "running") {
        return index;
      }
    }

    return running ? trail.entries.length - 1 : -1;
  })();

  return (
    <div className="activity-trail">
      <span className="activity-trail-title">{title}</span>
      <div className="activity-trail-list">
        {trail.entries.map((entry, index) => {
          const isActive = index === latestActiveIndex;
          const style = {
            "--activity-trail-delay": `${index * 70}ms`,
          } as CSSProperties;

          return (
            <div
              key={entry.id}
              className={`activity-trail-item${isActive ? " is-running" : ""}`}
              style={style}
            >
              <span className="activity-trail-item-label">{entry.label}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function ActivityGroupRowInner({
  message,
  isLatestRunningActivity = false,
}: {
  message: ChatMessage;
  isLatestRunningActivity?: boolean;
}) {
  const items = message.groupItems || [];
  const completedCount = items.filter((i) => i.status === "completed").length;
  const runningCount = items.filter((i) => i.status === "running").length;
  const isRunning = runningCount > 0;
  const latestRunningItemID = useMemo(() => {
    for (let index = items.length - 1; index >= 0; index -= 1) {
      if (items[index].status === "running") {
        return items[index].id;
      }
    }

    return undefined;
  }, [items]);
  const trail = buildActivityTrailModel(items, isRunning);
  const [expanded, setExpanded] = useState(() => Boolean(trail) && isRunning);
  const transitionClass = message.transitionState
    ? ` is-${message.transitionState}`
    : "";
  const title = trail?.title || buildActivityGroupTitle(items);
  const shouldAnimateRunning = isRunning && isLatestRunningActivity;

  useEffect(() => {
    if (trail && isRunning) {
      setExpanded(true);
    }
  }, [trail, isRunning]);

  return (
    <div
      className={`message-row activity-group-row${transitionClass}`}
      data-message-id={message.id}
    >
      <button
        type="button"
        className={`activity-group-toggle active-work-summary-toggle${shouldAnimateRunning ? " activity-card-running" : ""}`}
        onClick={() => setExpanded((current) => !current)}
        aria-expanded={expanded}
        data-activity-toggle="true"
      >
        <ChevronIcon expanded={expanded} className="active-work-summary-chevron" />
        <span
          className={`active-work-summary-text${shouldAnimateRunning ? " active-work-summary-text--live" : " active-work-summary-text--static"}`}
        >
          {title}
        </span>
      </button>

      {expanded && (
        <div className="activity-group-items">
          {trail ? (
            <ActivityTrail title={title} items={items} running={shouldAnimateRunning} />
          ) : (
            items.map((item) => (
              <ActivityGroupItemRow
                key={item.id}
                item={item}
                highlightRunning={shouldAnimateRunning && item.id === latestRunningItemID}
              />
            ))
          )}
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

function countKinds(items: ActivityGroupItem[]): Record<string, number> {
  const counts: Record<string, number> = {};

  for (const item of items) {
    const kind = item.icon || "other";
    counts[kind] = (counts[kind] || 0) + 1;
  }

  return counts;
}
