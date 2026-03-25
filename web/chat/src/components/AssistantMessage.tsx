import { memo, useCallback } from "react";
import type { ChatMessage, MessageCheckpointInfo } from "../types";
import { copyPlainText } from "../clipboard";
import { MarkdownContent } from "./MarkdownContent";
import { CollapsibleImageGallery } from "./CollapsibleImageGallery";
import { MessageCheckpointCard } from "./MessageCheckpointCard";
import { useSmoothTextStream } from "../hooks/useSmoothTextStream";

function providerTheme(label?: string): "codex" | "copilot" | "default" {
  const normalized = (label || "").trim().toLowerCase();
  if (normalized.includes("copilot")) return "copilot";
  if (normalized.includes("codex")) return "codex";
  return "default";
}

function AssistantMessageInner({
  message,
  checkpointInfo,
}: {
  message: ChatMessage;
  checkpointInfo?: MessageCheckpointInfo;
}) {
  const text = message.text || "";
  const smoothText = useSmoothTextStream(text, message.isStreaming || false);
  const transitionClass = message.transitionState
    ? ` is-${message.transitionState}`
    : "";
  const copyText = text;
  const providerTone = providerTheme(message.providerLabel);

  const handleCopy = useCallback(() => {
    void copyPlainText(copyText).catch(() => {});
  }, [copyText]);

  return (
    <div
      className={`message-row assistant-row${message.isStreaming ? " streaming" : ""}${transitionClass}`}
      data-message-id={message.id}
      data-message-text={copyText}
    >
      <div className="assistant-content">
        {copyText && (
          <button
            type="button"
            className="copy-btn copy-btn-float"
            onClick={handleCopy}
            title="Copy message"
          >
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
              <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
            </svg>
          </button>
        )}

        {copyText && (
          <div className="assistant-message-stage phase-settled">
            <div className="assistant-markdown-shell">
              <MarkdownContent markdown={smoothText} />
            </div>
            {message.providerLabel && (
              <div
                className="assistant-provider-footer"
                data-provider={providerTone}
                role="note"
                aria-label={`Runtime ${message.providerLabel}`}
              >
                <span className="assistant-provider-footer__spark" aria-hidden="true" />
                <span className="assistant-provider-footer__value">{message.providerLabel}</span>
              </div>
            )}
          </div>
        )}

        <CollapsibleImageGallery
          images={message.images || []}
          itemName="image"
          className="assistant-images"
          imageClassName="assistant-image"
          defaultExpanded
        />

        {checkpointInfo && (
          <MessageCheckpointCard info={checkpointInfo} />
        )}

      </div>
    </div>
  );
}

export const AssistantMessage = memo(AssistantMessageInner, (prev, next) => {
  return (
    prev.message === next.message &&
    prev.checkpointInfo?.checkpoint.id === next.checkpointInfo?.checkpoint.id &&
    prev.checkpointInfo?.currentCheckpointPosition === next.checkpointInfo?.currentCheckpointPosition &&
    prev.checkpointInfo?.hasActiveTurn === next.checkpointInfo?.hasActiveTurn &&
    prev.checkpointInfo?.actionsLocked === next.checkpointInfo?.actionsLocked &&
    prev.checkpointInfo?.futureTurnsHidden === next.checkpointInfo?.futureTurnsHidden
  );
});
