import { memo } from "react";
import type { ProviderTone } from "../types";

interface Props {
  title?: string;
  detail?: string;
  providerTone?: ProviderTone;
}

function TypingIndicatorInner({ title, detail, providerTone = "default" }: Props) {
  const resolvedTitle = title || "Thinking";
  const resolvedDetail = detail?.trim();

  return (
    <div className="message-row typing-row">
      <div className="typing-copy">
        <span className="typing-title" data-provider={providerTone}>{resolvedTitle}</span>
      </div>
    </div>
  );
}

export const TypingIndicator = memo(TypingIndicatorInner);
