import { memo, useCallback, useMemo } from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import { CodeBlock } from "./CodeBlock";

const remarkPlugins = [remarkGfm];

function MarkdownContentInner({ markdown }: { markdown: string }) {
  const renderedMarkdown = useMemo(() => normalizeMarkdownStructure(markdown), [markdown]);

  const handleLinkClick = useCallback((event: React.MouseEvent<HTMLAnchorElement>) => {
    event.preventDefault();
    const href = event.currentTarget.getAttribute("href");
    if (!href) return;
    window.open(href, "_blank", "noopener,noreferrer");
  }, []);

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
        return <CodeBlock code={codeString} language={match[1]} />;
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
      if (segment.startsWith("```") || segment.startsWith("~~~")) return segment;
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
      if (!prefixMatch) return line;
      const splitStarts = [...line.matchAll(/(\s+)(\d+)\.\s/g)]
        .map((marker) => marker.index)
        .filter((index): index is number => typeof index === "number");
      if (splitStarts.length === 0) return line;
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
