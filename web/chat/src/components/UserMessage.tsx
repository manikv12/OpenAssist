import { memo, useCallback } from "react";
import type { ChatMessage } from "../types";
import { CollapsibleImageGallery } from "./CollapsibleImageGallery";

function UserMessageInner({ message }: { message: ChatMessage }) {
  const text = message.text || "";
  const showText = text.trim().length > 0;
  const transitionClass = message.transitionState
    ? ` is-${message.transitionState}`
    : "";

  const handleCopy = useCallback(() => {
    navigator.clipboard.writeText(text).catch(() => {
      try {
        window.webkit?.messageHandlers?.copyText?.postMessage(text);
      } catch {}
    });
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
              className="user-action-pill"
              onClick={handleUndo}
              title="Undo this message and everything after it"
            >
              Undo
            </button>
          )}
          {message.canEdit && (
            <button
              className="user-action-pill"
              onClick={handleEdit}
              title="Edit the last message"
            >
              Edit
            </button>
          )}
          <button
            className="copy-btn copy-btn-float-user"
            onClick={handleCopy}
            title="Copy message"
          >
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
              <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
            </svg>
          </button>
        </div>

        <CollapsibleImageGallery
          images={message.images || []}
          itemName="image"
          className="user-images"
          imageClassName="user-image"
        />

        {showText && <div className="user-bubble">{text}</div>}
      </div>
    </div>
  );
}

export const UserMessage = memo(UserMessageInner);
