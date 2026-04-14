import { memo } from "react";
import type { ProviderTone } from "../types";

interface Props {
  title?: string;
  detail?: string;
  providerTone?: ProviderTone;
}

function TypingIndicatorInner({ title, detail, providerTone = "default" }: Props) {
  const resolvedTitle = title?.trim() || detail?.trim() || "Thinking";
  const resolvedDetail =
    detail?.trim() && detail.trim() !== resolvedTitle ? detail.trim() : null;

  return (
    <div className="message-row typing-row">
      <div className="typing-copy" data-provider={providerTone}>
        <div className="typing-status-line">
          <span className="typing-orb" data-provider={providerTone} aria-hidden="true" />
          <span className="typing-title" data-provider={providerTone}>
            {resolvedTitle}
          </span>
        </div>
        {resolvedDetail ? <span className="typing-detail">{resolvedDetail}</span> : null}
      </div>
    </div>
  );
}

export const TypingIndicator = memo(TypingIndicatorInner);
