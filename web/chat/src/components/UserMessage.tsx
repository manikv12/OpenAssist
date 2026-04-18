import { memo, useCallback } from "react";
import type { ChatMessage } from "../types";
import { copyPlainText } from "../clipboard";
import { AppIcon } from "./AppIcon";
import { CollapsibleImageGallery } from "./CollapsibleImageGallery";
import { PluginIcon } from "./PluginIcon";

function UserMessageInner({ message }: { message: ChatMessage }) {
  const text = message.text || "";
  const showText = text.trim().length > 0;
  const selectedPlugins = message.selectedPlugins || [];
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
              title="Undo the latest message"
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
          inline
        />

        {(showText || selectedPlugins.length > 0) && (
          <div className="user-bubble">
            <div className="user-bubble-body">
              {showText ? <span className="user-bubble-text">{text}</span> : null}
              {selectedPlugins.length ? (
                <span className="user-plugin-chip-row">
                  {selectedPlugins.map((plugin) => (
                    <span
                      key={plugin.pluginId}
                      className={`user-plugin-chip${plugin.needsSetup ? " is-warning" : ""}`}
                    >
                      <PluginIcon
                        iconDataUrl={plugin.iconDataUrl}
                        displayName={plugin.displayName}
                        className="user-plugin-chip-icon"
                        size={12}
                        strokeWidth={2.1}
                      />
                      <span>{plugin.displayName}</span>
                    </span>
                  ))}
                </span>
              ) : null}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

export const UserMessage = memo(UserMessageInner);
