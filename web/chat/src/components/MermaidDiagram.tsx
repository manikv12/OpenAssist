import Panzoom from "@panzoom/panzoom";
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import mermaid from "mermaid";

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

function getThemeVars() {
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

  return {
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
    clusterBkg: panelHover,
    clusterBorder: border,
    noteBkgColor: panel,
    noteTextColor: text,
    noteBorderColor: border,
    fontFamily:
      '"SF Pro Text", -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif',
    fontSize: "13px",
    nodeBorder: borderStrong,
    mainBkg: panel,
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
}

function configureMermaidTheme() {
  mermaid.initialize({
    startOnLoad: false,
    theme: "base",
    securityLevel: "loose",
    htmlLabels: true,
    suppressErrorRendering: true,
    themeVariables: getThemeVars(),
    flowchart: {
      defaultRenderer: "elk",
      curve: "monotoneX",
      nodeSpacing: 56,
      rankSpacing: 84,
      padding: 20,
    },
  });
}

configureMermaidTheme();

let mermaidCounter = 0;
const INLINE_PREVIEW_MAX_HEIGHT = 560;
const INLINE_PREVIEW_PADDING_X = 32;
const INLINE_PREVIEW_PADDING_Y = 40;

function MermaidDiagramInner({ code }: { code: string }) {
  const [svg, setSvg] = useState("");
  const [error, setError] = useState("");
  const [expanded, setExpanded] = useState(false);
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
    let cancelled = false;
    const id = `mermaid-${++mermaidCounter}`;

    (async () => {
      try {
        configureMermaidTheme();
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
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [code, themeVersion]);

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
  }, [svg]);

  if (error) {
    return (
      <div className="mermaid-error">
        <div className="mermaid-error-header">
          <span className="mermaid-error-label">Diagram error</span>
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

  return (
    <>
      <button
        type="button"
        className="mermaid-inline-card"
        aria-label="Open diagram viewer"
        onClick={() => setExpanded(true)}
      >
        <div className="mermaid-inline-card-header">
          <span className="mermaid-inline-card-hint">Click to open viewer</span>
        </div>
        <div ref={previewRef} className="mermaid-inline">
          <div dangerouslySetInnerHTML={{ __html: svg }} />
        </div>
      </button>

      {expanded && (
        <MermaidInteractiveOverlay svg={svg} onClose={() => setExpanded(false)} />
      )}
    </>
  );
}

function MermaidInteractiveOverlay({
  svg,
  onClose,
}: {
  svg: string;
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

  return (
    <div className="mermaid-overlay" onClick={onClose}>
      <div
        className="mermaid-overlay-shell"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="mermaid-overlay-toolbar">
          <span className="mermaid-overlay-title">Diagram preview</span>
          <div className="mermaid-overlay-controls">
            <button className="mermaid-ctrl-btn" onClick={zoomOut} title="Zoom out">
              −
            </button>
            <span className="mermaid-ctrl-scale">{Math.round(scale * 100)}%</span>
            <button className="mermaid-ctrl-btn" onClick={zoomIn} title="Zoom in">
              +
            </button>
            <button className="mermaid-ctrl-chip" onClick={() => fit(true)}>
              Fit
            </button>
            <button className="mermaid-ctrl-chip" onClick={handleCopySvg}>
              {copiedSvg ? "Copied" : "Copy SVG"}
            </button>
            <button className="mermaid-ctrl-chip mermaid-ctrl-close" onClick={onClose}>
              Close
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
}

function measureSvg(svgEl: SVGSVGElement) {
  const viewBox = svgEl.viewBox?.baseVal;
  if (viewBox && viewBox.width > 0 && viewBox.height > 0) {
    return { width: viewBox.width, height: viewBox.height };
  }

  const width = parseFloat(svgEl.getAttribute("width") || "0");
  const height = parseFloat(svgEl.getAttribute("height") || "0");
  if (width > 0 && height > 0) {
    return { width, height };
  }

  const box = svgEl.getBBox();
  return { width: box.width || 800, height: box.height || 500 };
}

export const MermaidDiagram = memo(MermaidDiagramInner);
