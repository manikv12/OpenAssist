import { memo } from "react";
import type { ProviderTone } from "../types";

interface Props {
  title?: string;
  detail?: string;
  providerTone?: ProviderTone;
}

function TypingIndicatorInner({ title, providerTone = "default" }: Props) {
  const resolvedTitle = title || "Thinking";

  return (
    <div className="message-row typing-row">
      <span className="typing-title" data-provider={providerTone}>{resolvedTitle}</span>
    </div>
  );
}

export const TypingIndicator = memo(TypingIndicatorInner);
