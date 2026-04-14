import Panzoom from "@panzoom/panzoom";
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { createPortal } from "react-dom";
import mermaid from "mermaid";
import {
  inspectMermaidSource,
  type MermaidRenderMode,
} from "./mermaidUtils";

interface MermaidThemeConfig {
  themeCSS: string;
  themeVariables: Record<string, boolean | string>;
}

function resolveThemeIsDark(styles: CSSStyleDeclaration): boolean {
  const bg = styles.getPropertyValue("--chat-bg").trim();
  const match = bg.match(/rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)/i);
  if (match) {
    const [, r, g, b] = match;
    const brightness =
      Number(r) * 0.299 + Number(g) * 0.587 + Number(b) * 0.114;
    return brightness < 150;
  }

  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? true;
}

function getMermaidTheme(mode: MermaidRenderMode): MermaidThemeConfig {
  const styles = getComputedStyle(document.documentElement);
  const get = (name: string, fallback: string) =>
    styles.getPropertyValue(name).trim() || fallback;
  const isDark = resolveThemeIsDark(styles);
  const text = get(
    "--chat-text",
    isDark ? "rgba(255,255,255,0.92)" : "rgba(15,23,42,0.92)"
  );
  const textStrong = get(
    "--chat-text-strong",
    isDark ? "rgba(255,255,255,0.96)" : "rgba(15,23,42,0.96)"
  );
  const textMuted = get(
    "--chat-text-muted",
    isDark ? "rgba(255,255,255,0.62)" : "rgba(15,23,42,0.62)"
  );
  const surface = get(
    "--chat-surface",
    isDark ? "rgba(40,42,54,0.95)" : "rgba(15,23,42,0.06)"
  );
  const panel = get(
    "--chat-panel",
    isDark ? "rgba(255,255,255,0.04)" : "rgba(15,23,42,0.04)"
  );
  const panelHover = get(
    "--chat-panel-hover",
    isDark ? "rgba(255,255,255,0.03)" : "rgba(15,23,42,0.06)"
  );
  const codeBg = get(
    "--chat-code-bg",
    isDark ? "rgb(26,28,36)" : "rgb(238,242,247)"
  );
  const border = get(
    "--chat-border",
    isDark ? "rgba(255,255,255,0.08)" : "rgba(15,23,42,0.10)"
  );
  const borderStrong = get(
    "--chat-border-strong",
    isDark ? "rgba(255,255,255,0.12)" : "rgba(15,23,42,0.16)"
  );
  const accent = get(
    "--chat-accent",
    get("--chat-link", isDark ? "rgb(133,194,255)" : "rgb(37,99,235)")
  );
  const textSoft = get(
    "--chat-text-soft",
    isDark ? "rgba(255,255,255,0.40)" : "rgba(15,23,42,0.42)"
  );
  const mermaidBackdrop = get(
    "--mermaid-board-bg",
    isDark ? "rgba(11, 13, 19, 0.94)" : "rgba(255,255,255,0.94)"
  );
  const clusterFill = get(
    "--mermaid-cluster-fill",
    isDark ? "rgba(255,255,255,0.03)" : "rgba(15,23,42,0.03)"
  );
  const clusterBorder = get(
    "--mermaid-cluster-border",
    isDark ? "rgba(255,255,255,0.14)" : "rgba(15,23,42,0.12)"
  );
  const clusterLabel = get(
    "--mermaid-cluster-label",
    isDark ? "rgba(255,255,255,0.60)" : "rgba(15,23,42,0.56)"
  );

  const themeVariables = {
    darkMode: isDark,
    background: "transparent",
    primaryColor: surface,
    primaryTextColor: text,
    primaryBorderColor: borderStrong,
    secondaryColor: panel,
    tertiaryColor: codeBg,
    tertiaryTextColor: textMuted,
    lineColor: accent,
    edgeLabelBackground: codeBg,
    clusterBkg: clusterFill,
    clusterBorder,
    noteBkgColor: panel,
    noteTextColor: text,
    noteBorderColor: border,
    fontFamily:
      '"SF Pro Text", -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif',
    fontSize: "14px",
    nodeBorder: borderStrong,
    mainBkg: mermaidBackdrop,
    nodeTextColor: text,
    titleColor: textStrong,
    actorBorder: border,
    actorBkg: surface,
    actorTextColor: text,
    actorLineColor: accent,
    signalColor: text,
    labelBoxBkgColor: codeBg,
    labelBoxBorderColor: border,
    labelTextColor: text,
    loopTextColor: textMuted,
  };

  return {
    themeVariables,
    themeCSS:
      mode === "default-pretty"
        ? `
          svg {
            shape-rendering: geometricPrecision;
            text-rendering: geometricPrecision;
          }

          .node rect,
          .node polygon,
          .node circle,
          .node ellipse,
          .node path {
            stroke-width: 1.15px;
            filter: drop-shadow(0 10px 24px rgba(0, 0, 0, 0.18));
          }

          .nodeLabel,
          .node text,
          .label text {
            font-weight: 650;
            letter-spacing: 0.01em;
          }

          .nodeLabel *,
          .edgeLabel *,
          .cluster-label *,
          .cluster text {
            font-family: "SF Pro Text", -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          }

          .cluster rect {
            fill: ${clusterFill};
            stroke: ${clusterBorder};
            stroke-width: 1px;
            stroke-dasharray: 7 8;
            rx: 20px;
            ry: 20px;
          }

          .cluster-label text,
          .cluster text {
            fill: ${clusterLabel};
            color: ${clusterLabel};
            font-size: 12px;
            font-weight: 700;
            letter-spacing: 0.08em;
            text-transform: uppercase;
          }

          .flowchart-link,
          .edgePath path {
            stroke: ${accent};
            stroke-width: 1.9px;
            stroke-linecap: round;
            stroke-linejoin: round;
            opacity: 0.8;
          }

          marker path {
            fill: ${accent};
            stroke: ${accent};
          }

          .edgeLabel,
          .edgeLabel rect,
          .labelBkg {
            fill: ${codeBg};
            background: ${codeBg};
            stroke: ${border};
            opacity: 0.96;
            rx: 999px;
            ry: 999px;
          }

          .edgeLabel text,
          .edgeLabel tspan,
          .edgeLabel div,
          .edgeLabel span {
            fill: ${textSoft};
            color: ${textSoft};
            font-size: 11px;
            font-weight: 600;
          }
        `
        : `
          svg {
            shape-rendering: geometricPrecision;
            text-rendering: geometricPrecision;
          }
        `,
  };
}

// Module-level state for deduplicating mermaid.initialize() calls and
// serialising mermaid.render() calls so concurrent diagram instances don't race
// on the global Mermaid singleton.
let lastMermaidConfig: string = "";
// Each render is chained onto this promise so only one runs at a time.
let mermaidRenderQueue: Promise<void> = Promise.resolve();

function configureMermaidTheme(mode: MermaidRenderMode): MermaidThemeConfig {
  const theme = getMermaidTheme(mode);
  const config = {
    startOnLoad: false,
    theme: "base",
    securityLevel: "loose",
    htmlLabels: true,
    suppressErrorRendering: true,
    themeVariables: theme.themeVariables,
    themeCSS: theme.themeCSS,
    flowchart: {
      defaultRenderer: "elk",
      curve: "monotoneX",
      nodeSpacing: 56,
      rankSpacing: 84,
      padding: 20,
    },
  };

  const serialized = JSON.stringify(config);
  if (serialized !== lastMermaidConfig) {
    lastMermaidConfig = serialized;
    mermaid.initialize(config);
  }

  return theme;
}

let mermaidCounter = 0;
const INLINE_PREVIEW_MAX_HEIGHT = 560;
const INLINE_PREVIEW_PADDING_X = 32;
const INLINE_PREVIEW_PADDING_Y = 40;
const NOTE_INLINE_COLLAPSE_HEIGHT = 250;
const FALLBACK_SVG_WIDTH = 800;
const FALLBACK_SVG_HEIGHT = 500;

function MermaidDiagramInner({
  code,
  showViewerHint = true,
  displayMode = "default",
  clickAction = "viewer",
  isStreaming = false,
  onRenderErrorChange,
}: {
  code: string;
  showViewerHint?: boolean;
  displayMode?: "default" | "noteCompact";
  clickAction?: "viewer" | "none";
  isStreaming?: boolean;
  onRenderErrorChange?: (error: string | null) => void;
}) {
  const sourceAnalysis = useMemo(() => inspectMermaidSource(code), [code]);
  const [svg, setSvg] = useState("");
  const [error, setError] = useState("");
  const [expanded, setExpanded] = useState(false);
  const [isInlineCollapsible, setIsInlineCollapsible] = useState(false);
  const [isInlineExpanded, setIsInlineExpanded] = useState(false);
  const [themeVersion, setThemeVersion] = useState(0);
  const previewRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!window.matchMedia) {
      return;
    }

    const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    const handleThemeChange = () => setThemeVersion((version) => version + 1);

    if (typeof mediaQuery.addEventListener === "function") {
      mediaQuery.addEventListener("change", handleThemeChange);
      return () => mediaQuery.removeEventListener("change", handleThemeChange);
    }

    mediaQuery.addListener(handleThemeChange);
    return () => mediaQuery.removeListener(handleThemeChange);
  }, []);

  useEffect(() => {
    // Skip expensive mermaid rendering while the message is still streaming.
    // The diagram will render once streaming completes with the final code.
    if (isStreaming) return;

    let cancelled = false;
    const id = `mermaid-${++mermaidCounter}`;

    mermaidRenderQueue = mermaidRenderQueue.then(
      () =>
        new Promise<void>((resolve) => {
          (async () => {
            try {
              configureMermaidTheme(sourceAnalysis.renderMode);
              const { svg: rendered } = await mermaid.render(id, code.trim());
              if (!cancelled) {
                setSvg(rendered);
                setError("");
              }
            } catch (err: any) {
              if (!cancelled) {
                setError(err?.message || "Render failed");
                setSvg("");
              }
              document.getElementById(`d${id}`)?.remove();
            } finally {
              resolve();
            }
          })();
        })
    );

    return () => {
      cancelled = true;
    };
  }, [code, sourceAnalysis, themeVersion, isStreaming]);

  useEffect(() => {
    onRenderErrorChange?.(error || null);
  }, [error, onRenderErrorChange]);

  useEffect(() => {
    return () => onRenderErrorChange?.(null);
  }, [onRenderErrorChange]);

  useLayoutEffect(() => {
    const preview = previewRef.current;
    if (!preview || !svg) {
      return;
    }

    const svgEl = preview.querySelector("svg") as SVGSVGElement | null;
    if (!svgEl) {
      return;
    }

    const fitInline = () => {
      const { width, height } = measureSvg(svgEl);
      const availableWidth = Math.max(180, preview.clientWidth - INLINE_PREVIEW_PADDING_X);
      const availableHeight = Math.max(
        180,
        Math.min(window.innerHeight * 0.55, INLINE_PREVIEW_MAX_HEIGHT) - INLINE_PREVIEW_PADDING_Y
      );
      const scale = Math.min(availableWidth / width, availableHeight / height, 1);

      svgEl.style.display = "block";
      svgEl.style.width = `${width * scale}px`;
      svgEl.style.height = `${height * scale}px`;
      svgEl.style.maxWidth = "none";
      svgEl.style.maxHeight = "none";

      if (displayMode === "noteCompact") {
        const nextIsCollapsible = height * scale > NOTE_INLINE_COLLAPSE_HEIGHT;
        setIsInlineCollapsible(nextIsCollapsible);
        if (!nextIsCollapsible) {
          setIsInlineExpanded(false);
        }
      } else {
        setIsInlineCollapsible(false);
        setIsInlineExpanded(false);
      }
    };

    fitInline();

    if (typeof ResizeObserver === "undefined") {
      window.addEventListener("resize", fitInline);
      return () => window.removeEventListener("resize", fitInline);
    }

    const observer = new ResizeObserver(() => fitInline());
    observer.observe(preview);
    window.addEventListener("resize", fitInline);

    return () => {
      observer.disconnect();
      window.removeEventListener("resize", fitInline);
    };
  }, [displayMode, svg]);

  if (error) {
    return (
      <div className="mermaid-error">
        <div className="mermaid-error-header">
          <span className="mermaid-error-label">Diagram error</span>
          <span className="mermaid-error-message">{error}</span>
        </div>
        <pre className="mermaid-error-code">
          <code>{code}</code>
        </pre>
      </div>
    );
  }

  if (!svg) {
    return <div className="mermaid-loading">Rendering diagram…</div>;
  }

  const isNoteCompact = displayMode === "noteCompact";

  const previewContent = (
    <div
      ref={previewRef}
      className={[
        "mermaid-inline",
        isInlineCollapsible && !isInlineExpanded ? "is-collapsed" : "",
      ]
        .filter(Boolean)
        .join(" ")}
    >
      <div dangerouslySetInnerHTML={{ __html: svg }} />
    </div>
  );

  return (
    <>
      <div
        className={[
          "mermaid-inline-card",
          isNoteCompact ? "is-note-compact" : "",
          sourceAnalysis.renderMode === "default-pretty"
            ? "mermaid-render-mode-default-pretty"
            : "mermaid-render-mode-respect-authored-style",
        ]
          .filter(Boolean)
          .join(" ")}
      >
        {showViewerHint ? (
          <div className="mermaid-inline-card-header">
            <span className="mermaid-inline-card-hint">Click to open viewer</span>
          </div>
        ) : null}
        {clickAction === "viewer" ? (
          <button
            type="button"
            className="mermaid-inline-card-preview"
            aria-label="Open diagram viewer"
            onClick={() => setExpanded(true)}
          >
            {previewContent}
          </button>
        ) : (
          <div className="mermaid-inline-card-preview is-inline-interactive">
            {previewContent}
          </div>
        )}
        {isInlineCollapsible ? (
          <div className="mermaid-inline-card-footer">
            <button
              type="button"
              className="mermaid-inline-toggle"
              onClick={() => setIsInlineExpanded((value) => !value)}
            >
              {isInlineExpanded ? "Show less" : "Show more"}
            </button>
          </div>
        ) : null}
      </div>

      {clickAction === "viewer" && expanded ? (
        <MermaidInteractiveOverlay
          svg={svg}
          renderMode={sourceAnalysis.renderMode}
          onClose={() => setExpanded(false)}
        />
      ) : null}
    </>
  );
}

function MermaidInteractiveOverlay({
  svg,
  renderMode,
  onClose,
}: {
  svg: string;
  renderMode: MermaidRenderMode;
  onClose: () => void;
}) {
  const viewportRef = useRef<HTMLDivElement>(null);
  const surfaceRef = useRef<HTMLDivElement>(null);
  const panzoomRef = useRef<ReturnType<typeof Panzoom> | null>(null);
  const [scale, setScale] = useState(1);
  const [copiedSvg, setCopiedSvg] = useState(false);

  const syncScale = useCallback(() => {
    setScale(panzoomRef.current?.getScale() ?? 1);
  }, []);

  const fit = useCallback(
    (animate = true) => {
      const viewport = viewportRef.current;
      const surface = surfaceRef.current;
      const panzoom = panzoomRef.current;
      if (!viewport || !surface || !panzoom) {
        return;
      }

      const svgEl = surface.querySelector("svg") as SVGSVGElement | null;
      if (!svgEl) {
        return;
      }

      const { width: svgWidth, height: svgHeight } = measureSvg(svgEl);
      const availableWidth = Math.max(180, viewport.clientWidth - 60);
      const availableHeight = Math.max(180, viewport.clientHeight - 60);
      const nextScale = Math.min(availableWidth / svgWidth, availableHeight / svgHeight, 1.5);

      panzoom.zoom(nextScale, { animate, force: true });
      requestAnimationFrame(() => {
        panzoom.pan(
          (viewport.clientWidth - svgWidth * nextScale) / 2,
          (viewport.clientHeight - svgHeight * nextScale) / 2,
          { animate, force: true }
        );
        syncScale();
      });
    },
    [syncScale]
  );

  useEffect(() => {
    const viewport = viewportRef.current;
    const surface = surfaceRef.current;
    if (!viewport || !surface) {
      return;
    }

    const svgEl = surface.querySelector("svg") as SVGSVGElement | null;
    if (!svgEl) {
      return;
    }

    svgEl.style.display = "block";
    svgEl.style.maxWidth = "none";
    svgEl.style.height = "auto";

    const { width, height } = measureSvg(svgEl);
    surface.style.width = `${width}px`;
    surface.style.height = `${height}px`;

    const panzoom = Panzoom(surface, {
      canvas: true,
      maxScale: 3.5,
      minScale: 0.3,
      step: 0.15,
      cursor: "grab",
      duration: 150,
      animate: true,
    });
    panzoomRef.current = panzoom;

    const handleWheel = (event: WheelEvent) => {
      panzoom.zoomWithWheel(event);
      syncScale();
    };
    const handleDoubleClick = () => fit(true);

    surface.addEventListener("panzoomchange", syncScale as EventListener);
    viewport.addEventListener("wheel", handleWheel, { passive: false });
    viewport.addEventListener("dblclick", handleDoubleClick);

    requestAnimationFrame(() => fit(false));

    return () => {
      surface.removeEventListener("panzoomchange", syncScale as EventListener);
      viewport.removeEventListener("wheel", handleWheel);
      viewport.removeEventListener("dblclick", handleDoubleClick);
      panzoom.destroy();
    };
  }, [fit, syncScale]);

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
        return;
      }
      if (event.key === "+" || event.key === "=") {
        panzoomRef.current?.zoomIn();
        requestAnimationFrame(syncScale);
        return;
      }
      if (event.key === "-") {
        panzoomRef.current?.zoomOut();
        requestAnimationFrame(syncScale);
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onClose, syncScale]);

  const handleCopySvg = useCallback(() => {
    // Crop SVG to only the diagram content, removing background and extra whitespace
    const surface = surfaceRef.current;
    const svgEl = surface?.querySelector("svg") as SVGSVGElement | null;
    if (svgEl) {
      try {
        const clone = svgEl.cloneNode(true) as SVGSVGElement;
        // Remove inline transforms/styles from panzoom
        clone.style.cssText = "";
        // Remove mermaid background rects (usually the first rect child that fills the whole SVG)
        const bgRects = clone.querySelectorAll(":scope > rect, :scope > g > rect.er");
        bgRects.forEach((rect) => {
          const w = rect.getAttribute("width");
          const h = rect.getAttribute("height");
          // Remove rects that span the full SVG (background fills)
          if (w === "100%" || h === "100%" ||
              (parseFloat(w || "0") >= parseFloat(clone.getAttribute("width") || "0") * 0.9 &&
               parseFloat(h || "0") >= parseFloat(clone.getAttribute("height") || "0") * 0.9)) {
            rect.remove();
          }
        });
        // Now get the bounding box of actual content (without the background rect)
        // We need to temporarily insert the clone to measure it
        const tempDiv = document.createElement("div");
        tempDiv.style.cssText = "position:absolute;left:-9999px;top:-9999px;visibility:hidden";
        document.body.appendChild(tempDiv);
        tempDiv.appendChild(clone);
        const contentBBox = clone.getBBox();
        tempDiv.remove();

        const pad = 20;
        const vbX = contentBBox.x - pad;
        const vbY = contentBBox.y - pad;
        const vbW = contentBBox.width + pad * 2;
        const vbH = contentBBox.height + pad * 2;
        clone.setAttribute("viewBox", `${vbX} ${vbY} ${vbW} ${vbH}`);
        clone.setAttribute("width", `${Math.round(vbW)}`);
        clone.setAttribute("height", `${Math.round(vbH)}`);
        const croppedSvg = new XMLSerializer().serializeToString(clone);
        navigator.clipboard.writeText(croppedSvg).catch(() => {});
      } catch {
        navigator.clipboard.writeText(svg).catch(() => {});
      }
    } else {
      navigator.clipboard.writeText(svg).catch(() => {});
    }
    setCopiedSvg(true);
    setTimeout(() => setCopiedSvg(false), 1600);
  }, [svg]);

  const zoomOut = () => {
    panzoomRef.current?.zoomOut();
    requestAnimationFrame(syncScale);
  };

  const zoomIn = () => {
    panzoomRef.current?.zoomIn();
    requestAnimationFrame(syncScale);
  };

  const overlay = (
    <div className="mermaid-overlay" onClick={onClose}>
      <div
        className={[
          "mermaid-overlay-shell",
          renderMode === "default-pretty"
            ? "mermaid-render-mode-default-pretty"
            : "mermaid-render-mode-respect-authored-style",
        ]
          .filter(Boolean)
          .join(" ")}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="mermaid-overlay-toolbar">
          <div className="mermaid-overlay-heading">
            <span className="mermaid-overlay-title">Diagram preview</span>
            <span className="mermaid-overlay-subtitle">
              Drag to move. Scroll to zoom.
            </span>
          </div>
          <div className="mermaid-overlay-controls">
            <div className="mermaid-zoom-cluster">
              <button className="mermaid-ctrl-btn" onClick={zoomOut} title="Zoom out">
                <MinusIcon />
              </button>
              <span className="mermaid-ctrl-scale">{Math.round(scale * 100)}%</span>
              <button className="mermaid-ctrl-btn" onClick={zoomIn} title="Zoom in">
                <PlusIcon />
              </button>
            </div>
            <button className="mermaid-ctrl-chip" onClick={() => fit(true)}>
              <FitIcon />
              <span>Fit</span>
            </button>
            <button className="mermaid-ctrl-chip" onClick={handleCopySvg}>
              <CopyIcon />
              <span>{copiedSvg ? "Copied" : "Copy SVG"}</span>
            </button>
            <button className="mermaid-ctrl-chip mermaid-ctrl-close" onClick={onClose}>
              <CloseIcon />
              <span>Close</span>
            </button>
          </div>
        </div>
        <div ref={viewportRef} className="mermaid-overlay-viewport">
          <div
            ref={surfaceRef}
            className="mermaid-overlay-surface"
            dangerouslySetInnerHTML={{ __html: svg }}
          />
        </div>
      </div>
    </div>
  );

  return createPortal(overlay, document.body);
}

function measureSvg(svgEl: SVGSVGElement) {
  try {
    const viewBox = svgEl.viewBox?.baseVal;
    if (viewBox && viewBox.width > 0 && viewBox.height > 0) {
      return { width: viewBox.width, height: viewBox.height };
    }

    const width = parseFloat(svgEl.getAttribute("width") || "0");
    const height = parseFloat(svgEl.getAttribute("height") || "0");
    if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
      return { width, height };
    }

    const box = svgEl.getBBox();
    return {
      width: Number.isFinite(box.width) && box.width > 0 ? box.width : FALLBACK_SVG_WIDTH,
      height: Number.isFinite(box.height) && box.height > 0 ? box.height : FALLBACK_SVG_HEIGHT,
    };
  } catch {
    return {
      width: FALLBACK_SVG_WIDTH,
      height: FALLBACK_SVG_HEIGHT,
    };
  }
}

function PlusIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M8 3.5v9" />
      <path d="M3.5 8h9" />
    </svg>
  );
}

function MinusIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M3.5 8h9" />
    </svg>
  );
}

function FitIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M6 3.25H3.25V6" />
      <path d="M10 3.25h2.75V6" />
      <path d="M12.75 10v2.75H10" />
      <path d="M6 12.75H3.25V10" />
    </svg>
  );
}

function CopyIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <rect x="5.25" y="3.25" width="7.5" height="9" rx="1.4" />
      <path d="M3.75 10.75H3.4A1.15 1.15 0 0 1 2.25 9.6V4.4A1.15 1.15 0 0 1 3.4 3.25H8.6" />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M4 4l8 8" />
      <path d="M12 4l-8 8" />
    </svg>
  );
}

export const MermaidDiagram = memo(MermaidDiagramInner);
