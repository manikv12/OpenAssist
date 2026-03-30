import { memo, useCallback, useMemo } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { Components } from "react-markdown";
import { CodeBlock } from "./CodeBlock";
import { MermaidDiagram } from "./MermaidDiagram";
import { normalizeMermaidSource } from "./mermaidUtils";

const codeTheme: Record<string, React.CSSProperties> = {
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

function MarkdownContentInner({
  markdown,
  mermaidDisplayMode = "default",
}: {
  markdown: string;
  mermaidDisplayMode?: "default" | "noteCompact";
}) {
  const renderedMarkdown = useMemo(
    () => normalizeMarkdownStructure(markdown),
    [markdown]
  );

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
          return (
            <MermaidDiagram
              code={normalizeMermaidSource(language, codeString)}
              displayMode={mermaidDisplayMode}
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
  };

  return (
    <ReactMarkdown remarkPlugins={remarkPlugins} components={components}>
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
