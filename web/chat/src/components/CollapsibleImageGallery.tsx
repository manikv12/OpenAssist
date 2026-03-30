import { memo, useEffect, useId, useState } from "react";
import { ChevronIcon } from "./ChevronIcon";

interface CollapsibleImageGalleryProps {
  images: string[];
  itemName?: string;
  className?: string;
  imageClassName?: string;
  defaultExpanded?: boolean;
  inline?: boolean;
  headerTitle?: string;
  collapsedDetail?: string;
  expandedDetail?: string;
}

function CollapsibleImageGalleryInner({
  images,
  itemName = "image",
  className,
  imageClassName,
  defaultExpanded = false,
  inline = false,
  headerTitle,
  collapsedDetail,
  expandedDetail,
}: CollapsibleImageGalleryProps) {
  const [expanded, setExpanded] = useState(defaultExpanded);
  const [previewIndex, setPreviewIndex] = useState<number | null>(null);
  const [zoom, setZoom] = useState(1);
  const contentId = useId();
  const canOpenNativePreview = Boolean(
    window.webkit?.messageHandlers?.openImage
  );
  const pluralSuffix = images.length === 1 ? "" : "s";
  const label = `${images.length} ${itemName}${pluralSuffix}`;
  const previewImage = previewIndex === null ? null : images[previewIndex];

  useEffect(() => {
    if (previewIndex === null) return;

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setPreviewIndex(null);
        return;
      }

      if (images.length < 2) return;

      if (event.key === "ArrowRight") {
        setPreviewIndex((current) =>
          current === null ? 0 : (current + 1) % images.length
        );
      }

      if (event.key === "ArrowLeft") {
        setPreviewIndex((current) =>
          current === null ? 0 : (current - 1 + images.length) % images.length
        );
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [images, previewIndex]);

  useEffect(() => {
    if (previewIndex === null) return;
    if (previewIndex < images.length) return;
    setPreviewIndex(images.length > 0 ? images.length - 1 : null);
  }, [images.length, previewIndex]);

  useEffect(() => {
    if (previewIndex === null) return;
    setZoom(1);
  }, [previewIndex]);

  useEffect(() => {
    if (!defaultExpanded || images.length === 0) {
      return;
    }

    setExpanded(true);
  }, [defaultExpanded, images.length]);

  if (images.length === 0) {
    return null;
  }

  const previewTitle =
    previewIndex === null
      ? ""
      : `${itemName[0]?.toUpperCase() ?? ""}${itemName.slice(1)} ${previewIndex + 1}${images.length > 1 ? ` of ${images.length}` : ""}`;
  const zoomPercent = Math.round(zoom * 100);
  const normalizedHeaderTitle = headerTitle?.trim();
  const titleText =
    normalizedHeaderTitle && normalizedHeaderTitle.length > 0
      ? normalizedHeaderTitle
      : expanded
        ? `Hide ${label}`
        : `Show ${label}`;
  const detailText = expanded
    ? expandedDetail?.trim() ||
      (canOpenNativePreview
        ? "Click a thumbnail to open it in Quick Look."
        : "Click a thumbnail to open a larger preview.")
    : collapsedDetail?.trim() ||
      "Collapsed by default to keep the chat easier to scan.";

  const rootClassName = ["collapsible-images", className]
    .filter(Boolean)
    .join(" ");

  const imageClasses = ["message-image", imageClassName]
    .filter(Boolean)
    .join(" ");

  const openImage = (image: string, index: number) => {
    if (canOpenNativePreview) {
      const normalizedItemName =
        itemName
          .trim()
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, "-")
          .replace(/^-+|-+$/g, "") || "image";
      window.webkit?.messageHandlers?.openImage?.postMessage({
        dataUrl: image,
        suggestedName: `${normalizedItemName}-${index + 1}`,
      });
      return;
    }

    setPreviewIndex(index);
  };

  if (inline) {
    return (
      <div className={["collapsible-images inline-images", className].filter(Boolean).join(" ")}>
        <div className="image-list">
          {images.map((image, index) => (
            <button
              key={`${index}-${image.slice(0, 32)}`}
              type="button"
              className="image-thumb"
              onClick={() => openImage(image, index)}
              aria-label={`${canOpenNativePreview ? "Open" : "Preview"} ${itemName} ${index + 1}`}
            >
              <img
                src={image}
                alt={`${itemName} ${index + 1}`}
                className={imageClasses}
              />
            </button>
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className={rootClassName}>
      <button
        type="button"
        className={`image-toggle${expanded ? " expanded" : ""}`}
        onClick={() => setExpanded((current) => !current)}
        aria-expanded={expanded}
        aria-controls={contentId}
      >
        <span className="image-toggle-copy">
          <span className="image-toggle-title">{titleText}</span>
          <span className="image-toggle-detail">{detailText}</span>
        </span>
        <span className="image-toggle-action" aria-hidden="true">
          <ChevronIcon expanded={expanded} className="image-toggle-chevron" />
        </span>
      </button>

      {expanded && (
        <div id={contentId} className="image-list">
          {images.map((image, index) => (
            <button
              key={`${index}-${image.slice(0, 32)}`}
              type="button"
              className="image-thumb"
              onClick={() => openImage(image, index)}
              aria-label={`${canOpenNativePreview ? "Open" : "Preview"} ${itemName} ${index + 1}`}
            >
              <img
                src={image}
                alt={`${itemName} ${index + 1}`}
                className={imageClasses}
              />
              <span className="image-thumb-badge">
                {canOpenNativePreview ? "Quick Look" : "Preview"}
              </span>
            </button>
          ))}
        </div>
      )}

      {previewImage && (
        <div
          className="image-preview-backdrop"
          role="dialog"
          aria-modal="true"
          aria-label={`${itemName} preview`}
          onClick={() => setPreviewIndex(null)}
        >
          <div
            className="image-preview-shell"
            onClick={(event) => event.stopPropagation()}
          >
            <div className="image-preview-toolbar">
              <span className="image-preview-title">{previewTitle}</span>
              <div className="image-preview-actions">
                {images.length > 1 && (
                  <>
                    <button
                      type="button"
                      className="image-preview-btn"
                      onClick={() =>
                        setPreviewIndex((current) =>
                          current === null
                            ? 0
                            : (current - 1 + images.length) % images.length
                        )
                      }
                    >
                      Previous
                    </button>
                    <button
                      type="button"
                      className="image-preview-btn"
                      onClick={() =>
                        setPreviewIndex((current) =>
                          current === null ? 0 : (current + 1) % images.length
                        )
                      }
                    >
                      Next
                    </button>
                  </>
                )}
                <button
                  type="button"
                  className="image-preview-btn"
                  onClick={() => setZoom((current) => Math.max(0.5, current - 0.25))}
                >
                  -
                </button>
                <span className="image-preview-zoom-label">{zoomPercent}%</span>
                <button
                  type="button"
                  className="image-preview-btn"
                  onClick={() => setZoom((current) => Math.min(3, current + 0.25))}
                >
                  +
                </button>
                <button
                  type="button"
                  className="image-preview-btn"
                  onClick={() => setPreviewIndex(null)}
                >
                  Close
                </button>
              </div>
            </div>

            <div className="image-preview-stage">
              <div className="image-preview-canvas">
                <img
                  src={previewImage}
                  alt={previewTitle}
                  className="image-preview-image"
                  style={
                    zoom === 1
                      ? undefined
                      : {
                          width: `${zoom * 100}%`,
                          maxWidth: "none",
                        }
                  }
                />
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

export const CollapsibleImageGallery = memo(CollapsibleImageGalleryInner);
