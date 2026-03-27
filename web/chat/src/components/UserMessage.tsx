import { memo, useCallback } from "react";
import type { ChatMessage } from "../types";
import { copyPlainText } from "../clipboard";
import { AppIcon } from "./AppIcon";
import { CollapsibleImageGallery } from "./CollapsibleImageGallery";

function UserMessageInner({ message }: { message: ChatMessage }) {
  const text = message.text || "";
  const showText = text.trim().length > 0;
  const transitionClass = message.transitionState
    ? ` is-${message.transitionState}`
    : "";

  const handleCopy = useCallback(() => {
    void copyPlainText(text).catch(() => {});
  }, [text]);

  const handleUndo = useCallback(() => {
    if (!message.rewriteAnchorID) return;
    try {
      window.webkit?.messageHandlers?.undoMessage?.postMessage(message.rewriteAnchorID);
    } catch {}
  }, [message.rewriteAnchorID]);

  const handleEdit = useCallback(() => {
    if (!message.rewriteAnchorID) return;
    try {
      window.webkit?.messageHandlers?.editMessage?.postMessage(message.rewriteAnchorID);
    } catch {}
  }, [message.rewriteAnchorID]);

  return (
    <div className={`message-row user-row${transitionClass}`}>
      <div className="user-content">
        <div className="user-actions">
          {message.canUndo && (
            <button
              type="button"
              className="user-action-pill"
              onClick={handleUndo}
              title="Undo this message and everything after it"
            >
              Undo
            </button>
          )}
          {message.canEdit && (
            <button
              type="button"
              className="user-action-pill"
              onClick={handleEdit}
              title="Edit the last message"
            >
              Edit
            </button>
          )}
          <button
            type="button"
            className="copy-btn copy-btn-float-user"
            onClick={handleCopy}
            title="Copy message"
          >
            <AppIcon symbol="copy" size={13} strokeWidth={2} />
          </button>
        </div>

        <CollapsibleImageGallery
          images={message.images || []}
          itemName="image"
          className="user-images"
          imageClassName="user-image"
          defaultExpanded
        />

        {showText && <div className="user-bubble">{text}</div>}
      </div>
    </div>
  );
}

export const UserMessage = memo(UserMessageInner);
