import { memo } from "react";

interface Props {
  title?: string;
  detail?: string;
}

function TypingIndicatorInner({ title }: Props) {
  const resolvedTitle = title || "Thinking";

  return (
    <div className="message-row typing-row">
      <span className="typing-title">{resolvedTitle}</span>
    </div>
  );
}

export const TypingIndicator = memo(TypingIndicatorInner);
