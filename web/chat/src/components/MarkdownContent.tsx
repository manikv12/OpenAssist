import { memo, useCallback, useDeferredValue } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { Components } from "react-markdown";
import { CodeBlock } from "./CodeBlock";
import { MermaidDiagram } from "./MermaidDiagram";

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
  isStreaming = false,
}: {
  markdown: string;
  isStreaming?: boolean;
}) {
  const deferredMarkdown = useDeferredValue(markdown);
  const renderedMarkdown =
    isStreaming && markdown.length > 900 ? deferredMarkdown : markdown;

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

function normalizeMermaidSource(language: string, code: string): string {
  if (language === "mermaid") {
    return code;
  }

  const variant = language.slice("mermaid".length).toLowerCase();
  if (!variant) {
    return code;
  }

  const header = mermaidVariantHeader(variant);
  if (!header) {
    return code;
  }

  const trimmed = code.trimStart();
  const normalizedHeader = header.toLowerCase();
  if (trimmed.toLowerCase().startsWith(normalizedHeader)) {
    return code;
  }
  if (header === "flowchart" && /^graph\b/i.test(trimmed)) {
    return code;
  }

  return `${header}\n${code}`;
}

function mermaidVariantHeader(variant: string): string | null {
  const variants: Record<string, string> = {
    flowchart: "flowchart",
    graph: "graph",
    sequencediagram: "sequenceDiagram",
    classdiagram: "classDiagram",
    statediagram: "stateDiagram-v2",
    statediagramv2: "stateDiagram-v2",
    erdiagram: "erDiagram",
    journey: "journey",
    gantt: "gantt",
    pie: "pie",
    gitgraph: "gitGraph",
    mindmap: "mindmap",
    timeline: "timeline",
    requirementdiagram: "requirementDiagram",
    quadrantschart: "quadrantChart",
    quadrantchart: "quadrantChart",
    sankey: "sankey-beta",
    architecture: "architecture-beta",
    blockdiagram: "block-beta",
  };

  return variants[variant] || null;
}
