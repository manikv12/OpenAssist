import { memo, useEffect, useState } from "react";
import type { ChatMessage } from "../types";
import { AppIcon } from "./AppIcon";

function ActivitySummaryRowInner({ message }: { message: ChatMessage }) {
  const [isLoading, setIsLoading] = useState(false);
  const transitionClass = message.transitionState ? ` is-${message.transitionState}` : "";
  const isCollapse = Boolean(message.collapseActivityDetailsID);
  const title = isLoading
    ? "Loading tools..."
    : isCollapse
      ? "Back to summary"
      : message.activityTitle || "Worked";

  useEffect(() => {
    setIsLoading(false);
  }, [message.id, message.loadActivityDetailsID, message.collapseActivityDetailsID]);

  const handleClick = () => {
    if (message.collapseActivityDetailsID) {
      try {
        window.webkit?.messageHandlers?.collapseActivityDetails?.postMessage(
          message.collapseActivityDetailsID
        );
      } catch {}
      return;
    }

    if (!message.loadActivityDetailsID) {
      return;
    }

    setIsLoading(true);

    try {
      window.webkit?.messageHandlers?.loadActivityDetails?.postMessage(
        message.loadActivityDetailsID
      );
    } catch {
      setIsLoading(false);
    }
  };

  return (
    <div
      className={`message-row activity-summary-row${transitionClass}`}
      data-message-id={message.id}
    >
      <button
        type="button"
        className="activity-summary-button"
        onClick={handleClick}
        disabled={!message.loadActivityDetailsID && !message.collapseActivityDetailsID}
        aria-busy={isLoading}
      >
        <span className="activity-summary-line" aria-hidden="true" />
        <span className="activity-summary-center">
          <span className="activity-summary-label">{title}</span>
          <AppIcon
            symbol={isCollapse ? "chevron.left" : "chevron.right"}
            className="activity-summary-icon"
            size={13}
            strokeWidth={2.2}
          />
        </span>
        <span className="activity-summary-line" aria-hidden="true" />
      </button>
    </div>
  );
}

export const ActivitySummaryRow = memo(ActivitySummaryRowInner);
