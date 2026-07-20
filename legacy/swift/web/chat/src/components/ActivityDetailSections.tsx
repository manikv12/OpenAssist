import { memo } from "react";
import type { ActivityDetailSection } from "../types";

interface ActivityDetailSectionsProps {
  sections: ActivityDetailSection[];
}

function ActivityDetailSectionsInner({
  sections,
}: ActivityDetailSectionsProps) {
  if (sections.length === 0) {
    return null;
  }

  return (
    <div className="activity-detail-sections">
      {sections.map((section, index) => {
        const normalizedText = section.text.replace(/\r\n/g, "\n");
        const newlineCount = (normalizedText.match(/\n/g) || []).length;
        const shouldScroll =
          normalizedText.length > 420 || newlineCount >= 10;

        return (
          <div
            key={`${section.title}-${index}`}
            className="activity-detail-section"
          >
            <span className="activity-detail-heading">{section.title}</span>
            <div
              className={`activity-detail-panel${shouldScroll ? " scrollable" : ""}`}
            >
              <pre>{normalizedText}</pre>
            </div>
          </div>
        );
      })}
    </div>
  );
}

export const ActivityDetailSections = memo(ActivityDetailSectionsInner);
