import { memo, useCallback } from "react";
import type { ChatMessage, MessageCheckpointInfo } from "../types";
import { copyPlainText } from "../clipboard";
import { AppIcon } from "./AppIcon";
import { MarkdownContent } from "./MarkdownContent";
import { CollapsibleImageGallery } from "./CollapsibleImageGallery";
import { MessageCheckpointCard } from "./MessageCheckpointCard";
import { useSmoothTextStream } from "../hooks/useSmoothTextStream";

function providerTheme(label?: string): "codex" | "copilot" | "claude" | "default" {
  const normalized = (label || "").trim().toLowerCase();
  if (normalized.includes("copilot")) return "copilot";
  if (normalized.includes("codex")) return "codex";
  if (normalized.includes("claude") || normalized.includes("anthropic")) return "claude";
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
            <AppIcon symbol="copy" size={13} strokeWidth={2} />
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
