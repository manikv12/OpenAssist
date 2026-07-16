import { memo } from "react";
import type { ChatMessage } from "../types";
import { CollapsibleImageGallery } from "./CollapsibleImageGallery";

function SystemMessageInner({ message }: { message: ChatMessage }) {
  const transitionClass = message.transitionState
    ? ` is-${message.transitionState}`
    : "";
  const images = message.images || [];
  const hasImages = images.length > 0;
  const itemName =
    (message.text || "").toLowerCase().includes("screenshot")
      ? "screenshot"
      : "image";
  const imageCountLabel = `${images.length} ${itemName}${images.length === 1 ? "" : "s"}`;

  return (
    <div
      className={`message-row system-row${hasImages ? " system-row-with-images" : ""}${transitionClass}`}
    >
      {hasImages ? (
        <CollapsibleImageGallery
          images={images}
          itemName={itemName}
          className="system-images system-image-gallery"
          headerTitle={message.text || imageCountLabel}
          collapsedDetail={`${imageCountLabel} available. Click to show.`}
        />
      ) : (
        <div className="system-content">{message.text || ""}</div>
      )}
    </div>
  );
}

export const SystemMessage = memo(SystemMessageInner);
