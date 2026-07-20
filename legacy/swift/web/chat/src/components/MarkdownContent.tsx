import { memo, useCallback, useEffect, useMemo, type CSSProperties, type ReactNode } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { Components } from "react-markdown";
import { CodeBlock } from "./CodeBlock";
import { MermaidDiagram } from "./MermaidDiagram";
import { normalizeMermaidSource } from "./mermaidUtils";
import {
  normalizeThreadNoteMarkdownForRichText,
  resolveRenderedThreadNoteImage,
} from "./threadNoteImageMarkdown";
import { useIsStreaming } from "../StreamingContext";

const codeTheme: Record<string, CSSProperties> = {
  'code[class*="language-"]': {
    color: "var(--chat-code-text)",
    fontFamily: '"SF Mono", SFMono-Regular, Menlo, Monaco, Consolas, monospace',
    fontSize: "12.2px",
    lineHeight: "1.55",
    background: "none",
  },
  'pre[class*="language-"]': {
    color: "var(--chat-code-text)",
    fontFamily: '"SF Mono", SFMono-Regular, Menlo, Monaco, Consolas, monospace',
    fontSize: "12.2px",
    lineHeight: "1.55",
    background: "var(--chat-code-bg)",
    borderRadius: "8px",
    padding: "12px 14px",
    margin: "0",
    overflow: "auto",
  },
  keyword: { color: "var(--chat-code-keyword)" },
  builtin: { color: "var(--chat-code-builtin)" },
  function: { color: "var(--chat-code-function)" },
  "class-name": { color: "var(--chat-code-class)" },
  boolean: { color: "var(--chat-code-boolean)" },
  number: { color: "var(--chat-code-number)" },
  string: { color: "var(--chat-code-string)" },
  "template-string": { color: "var(--chat-code-string)" },
  "template-punctuation": { color: "var(--chat-code-string)" },
  char: { color: "var(--chat-code-string)" },
  regex: { color: "var(--chat-code-string)" },
  comment: { color: "var(--chat-code-comment)", fontStyle: "italic" },
  prolog: { color: "var(--chat-code-comment)", fontStyle: "italic" },
  doctype: { color: "var(--chat-code-comment)" },
  cdata: { color: "var(--chat-code-comment)" },
  punctuation: { color: "var(--chat-code-punctuation)" },
  operator: { color: "var(--chat-code-operator)" },
  property: { color: "var(--chat-code-property)" },
  tag: { color: "var(--chat-code-tag)" },
  "attr-name": { color: "var(--chat-code-attr-name)" },
  "attr-value": { color: "var(--chat-code-attr-value)" },
  selector: { color: "var(--chat-code-selector)" },
  variable: { color: "var(--chat-code-variable)" },
  constant: { color: "var(--chat-code-constant)" },
  symbol: { color: "var(--chat-code-symbol)" },
  deleted: { color: "var(--chat-code-deleted)" },
  inserted: { color: "var(--chat-code-inserted)" },
  italic: { fontStyle: "italic" },
  bold: { fontWeight: "bold" },
  important: { fontWeight: "bold", color: "var(--chat-code-important)" },
  "maybe-class-name": { color: "var(--chat-code-class)" },
  "known-class-name": { color: "var(--chat-code-class)" },
  namespace: { opacity: "var(--chat-code-namespace-opacity)" },
};

const remarkPlugins = [remarkGfm];

function plainTextFromReactNode(node: ReactNode): string {
  if (node == null || typeof node === "boolean") return "";
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(plainTextFromReactNode).join("");
  if (typeof node === "object" && "props" in node) {
    return plainTextFromReactNode((node as { props?: { children?: ReactNode } }).props?.children);
  }
  return "";
}

function noteHeadingKind(title: string) {
  const normalized = title.trim().toLowerCase();
  if (/status|progress|health|current/.test(normalized)) return "status";
  if (/goal|objective/.test(normalized)) return "goals";
  if (/branch|repo|migration|release/.test(normalized)) return "branch";
  if (/registry|container|image|artifact|package/.test(normalized)) return "package";
  if (/pipeline|agent|runner|pool|workflow/.test(normalized)) return "workflow";
  if (/role|permission|credential|identity|oidc|breach|security/.test(normalized)) return "security";
  if (/component|architecture|system|module/.test(normalized)) return "components";
  if (/to\s*do|todo|task|checklist/.test(normalized)) return "tasks";
  if (/decision|choice|tradeoff/.test(normalized)) return "decision";
  if (/example|endpoint|api|code|implementation/.test(normalized)) return "code";
  if (/response|output|result|data|table/.test(normalized)) return "table";
  if (/infra|infrastructure|deployment|environment|subscription|vmss|virtual machine|scale set/.test(normalized)) return "components";
  if (/next|done|complete|ship/.test(normalized)) return "done";
  if (/note|summary|context/.test(normalized)) return "notes";
  return "note";
}

function MarkdownContentInner({
  markdown,
  mermaidDisplayMode = "default",
  onMermaidRenderErrorChange,
}: {
  markdown: string;
  mermaidDisplayMode?: "default" | "noteCompact";
  onMermaidRenderErrorChange?: (error: string | null) => void;
}) {
  const isStreaming = useIsStreaming();
  const renderedMarkdown = useMemo(
    () =>
      normalizeThreadNoteMarkdownForRichText(
        isStreaming ? markdown : normalizeMarkdownStructure(markdown)
      ),
    [isStreaming, markdown]
  );

  useEffect(() => {
    if (!onMermaidRenderErrorChange) {
      return;
    }
    if (!/```mermaid/i.test(markdown)) {
      onMermaidRenderErrorChange(null);
    }
  }, [markdown, onMermaidRenderErrorChange]);

  const handleLinkClick = useCallback(
    (e: React.MouseEvent<HTMLAnchorElement>) => {
      e.preventDefault();
      const href = e.currentTarget.getAttribute("href");
      if (!href) return;
      try {
        window.webkit?.messageHandlers?.linkClicked?.postMessage(href);
      } catch {
        window.open(href, "_blank");
      }
    },
    []
  );

  const components: Components = {
    a: ({ href, children, ...props }) => (
      <a href={href} onClick={handleLinkClick} {...props}>
        {children}
      </a>
    ),

    code: ({ className, children, ...props }) => {
      const match = /language-(\w+)/.exec(className || "");
      const codeString = String(children).replace(/\n$/, "");

      if (match) {
        const language = match[1].toLowerCase();
        if (language === "mermaid" || language.startsWith("mermaid")) {
          if (isStreaming) {
            return (
              <pre className="streaming-mermaid-preview">
                <code>{codeString}</code>
              </pre>
            );
          }
          return (
            <MermaidDiagram
              code={normalizeMermaidSource(language, codeString)}
              displayMode={mermaidDisplayMode}
              isStreaming={isStreaming}
              onRenderErrorChange={onMermaidRenderErrorChange}
            />
          );
        }
        return (
          <CodeBlock code={codeString} language={match[1]} theme={codeTheme} />
        );
      }

      return (
        <code className="inline-code" {...props}>
          {children}
        </code>
      );
    },

    img: ({ src, alt, title, ...props }) => {
      const resolved = resolveRenderedThreadNoteImage(src ?? "");
      const maxWidthStyle =
        typeof resolved.width === "number"
          ? ({
              maxWidth: `${resolved.width}px`,
              width: "100%",
            } satisfies CSSProperties)
          : undefined;
      const normalizedTitle = title?.trim();

      if (normalizedTitle) {
        return (
          <figure className="thread-note-rendered-image" style={maxWidthStyle}>
            <img
              {...props}
              className="thread-note-rendered-image-media"
              src={resolved.src}
              alt={alt ?? ""}
              title={normalizedTitle}
            />
            <figcaption className="thread-note-rendered-image-caption">
              {normalizedTitle}
            </figcaption>
          </figure>
        );
      }

      return (
        <img
          {...props}
          className="thread-note-rendered-image-media"
          src={resolved.src}
          alt={alt ?? ""}
          title={normalizedTitle}
          style={maxWidthStyle}
        />
      );
    },

    table: ({ children, className, node: _node, ...props }) => (
      <div className="markdown-table-wrap">
        <table {...props} className={className}>
          {children}
        </table>
      </div>
    ),

    h2: ({ children, className, node: _node, ...props }) => {
      const kind = noteHeadingKind(plainTextFromReactNode(children));
      return (
        <h2
          {...props}
          className={`markdown-note-heading ${className ?? ""}`.trim()}
          data-heading-kind={kind}
        >
          <span className="markdown-note-heading-icon" aria-hidden="true" />
          <span>{children}</span>
        </h2>
      );
    },

    h3: ({ children, className, node: _node, ...props }) => {
      const kind = noteHeadingKind(plainTextFromReactNode(children));
      return (
        <h3
          {...props}
          className={`markdown-note-heading markdown-note-heading-sub ${className ?? ""}`.trim()}
          data-heading-kind={kind}
        >
          <span className="markdown-note-heading-icon" aria-hidden="true" />
          <span>{children}</span>
        </h3>
      );
    },

    li: ({ children, className, node: _node, ...props }) => {
      const emptyTask = plainTextFromReactNode(children).trim().match(/^\[( |x|X)\]$/);
      if (emptyTask) {
        return (
          <li {...props} className={`markdown-empty-task ${className ?? ""}`.trim()}>
            <input type="checkbox" checked={emptyTask[1].toLowerCase() === "x"} readOnly disabled />
            <span aria-hidden="true" />
          </li>
        );
      }

      return (
        <li {...props} className={className}>
          {children}
        </li>
      );
    },
  };

  return (
    <ReactMarkdown
      remarkPlugins={isStreaming ? [] : remarkPlugins}
      components={components}
    >
      {renderedMarkdown}
    </ReactMarkdown>
  );
}

export const MarkdownContent = memo(MarkdownContentInner);

function normalizeMarkdownStructure(markdown: string): string {
  const normalized = markdown.replace(/\r\n/g, "\n");
  const segments = normalized.split(/(```[\s\S]*?```|~~~[\s\S]*?~~~)/g);

  return segments
    .map((segment) => {
      if (segment.startsWith("```") || segment.startsWith("~~~")) {
        return segment;
      }

      return expandCompactOrderedLists(segment);
    })
    .join("");
}

function expandCompactOrderedLists(segment: string): string {
  const prepared = segment.replace(/(:)\s+(?=1\.\s)/g, "$1\n");

  return prepared
    .split("\n")
    .map((line) => {
      const prefixMatch = line.match(/^(\s*(?:>\s*)*)\d+\.\s/);
      if (!prefixMatch) {
        return line;
      }

      const splitStarts = [...line.matchAll(/(\s+)(\d+)\.\s/g)]
        .map((marker) => marker.index)
        .filter((index): index is number => typeof index === "number");

      if (splitStarts.length === 0) {
        return line;
      }

      const prefix = prefixMatch[1] || "";
      const rebuilt: string[] = [];
      let sliceStart = 0;

      for (const markerIndex of splitStarts) {
        const whitespace = line.slice(markerIndex).match(/^\s+/)?.[0] || "";
        const itemStart = markerIndex + whitespace.length;
        rebuilt.push(line.slice(sliceStart, itemStart).trimEnd());
        sliceStart = itemStart;
      }

      rebuilt.push(line.slice(sliceStart));
      return rebuilt.filter(Boolean).join(`\n${prefix}`);
    })
    .join("\n");
}
