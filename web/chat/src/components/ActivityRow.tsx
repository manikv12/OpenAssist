import { memo, useState } from "react";
import type { ChatMessage } from "../types";
import { ActivityIcon } from "./ActivityIcon";
import { ActivityDetailSections } from "./ActivityDetailSections";
import { ChevronIcon } from "./ChevronIcon";
import { CollapsibleImageGallery } from "./CollapsibleImageGallery";
import { FileChangeSummary } from "./FileChangeSummary";

function ActivityRowInner({ message }: { message: ChatMessage }) {
  const [expanded, setExpanded] = useState(false);
  const transitionClass = message.transitionState
    ? ` is-${message.transitionState}`
    : "";
  const statusClass =
    message.activityStatus === "completed"
      ? "status-completed"
      : message.activityStatus === "failed"
        ? "status-failed"
        : "status-running";
  const detailSections = message.detailSections || [];
  const imageCount = message.images?.length || 0;
  const canExpand = detailSections.length > 0 || imageCount > 0;
  const isRunning = message.activityStatus === "running";

  const cardContent = (
    <>
      <div className="activity-icon-wrap">
        <ActivityIcon
          kind={message.activityIcon}
          status={message.activityStatus}
        />
      </div>
      <div className="activity-body">
        <span className="activity-title">
          {message.activityTitle || "Action"}
        </span>
        {message.activityDetail && (
          <span className="activity-detail">{message.activityDetail}</span>
        )}
      </div>
      <div className="activity-meta">
        {message.activityStatusLabel && (
          <span className={`activity-status-label ${statusClass}`}>
            {message.activityStatusLabel}
          </span>
        )}
        {canExpand && (
          <span className="activity-toggle-button" aria-hidden="true">
            <ChevronIcon expanded={expanded} className="expand-icon" />
          </span>
        )}
        <span className="activity-time">{formatTime(message.timestamp)}</span>
      </div>
    </>
  );

  return (
    <div className={`message-row activity-row${transitionClass}`}>
      {canExpand ? (
        <button
          type="button"
          className={`activity-card activity-card-button${isRunning ? " activity-card-running" : ""}`}
          onClick={() => setExpanded((current) => !current)}
          aria-expanded={expanded}
        >
          {cardContent}
        </button>
      ) : (
        <div className={`activity-card${isRunning ? " activity-card-running" : ""}`}>
          {cardContent}
        </div>
      )}

      {expanded && (
        <div className="activity-expanded-details">
          {message.activityIcon === "fileChange" && (
            <FileChangeSummary sections={detailSections} />
          )}
          <ActivityDetailSections sections={detailSections} />
          <CollapsibleImageGallery
            images={message.images || []}
            itemName="screenshot"
            className="activity-images"
            imageClassName="activity-image"
          />
        </div>
      )}
    </div>
  );
}

export const ActivityRow = memo(ActivityRowInner);

function formatTime(ts: number): string {
  if (!ts) return "";
  const d = new Date(ts);
  return d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}
