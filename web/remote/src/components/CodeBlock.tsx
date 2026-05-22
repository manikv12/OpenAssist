import { memo, useCallback, useState, type CSSProperties } from "react";
import { Prism as SyntaxHighlighter } from "react-syntax-highlighter";

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

export { codeTheme };

interface Props {
  code: string;
  language: string;
}

async function copyText(text: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }
  throw new Error("Clipboard unavailable");
}

function CopyIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="9" y="9" width="13" height="13" rx="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M20 6L9 17l-5-5" />
    </svg>
  );
}

function CodeBlockInner({ code, language }: Props) {
  const [copied, setCopied] = useState(false);

  const handleCopy = useCallback(() => {
    void copyText(code).catch(() => {});
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [code]);

  return (
    <div className="code-block-wrapper">
      <div className="code-block-header">
        <span className="code-block-lang">{language}</span>
        <button type="button" className="code-block-copy" onClick={handleCopy}>
          {copied ? (
            <>
              <CheckIcon />
              <span>Copied</span>
            </>
          ) : (
            <>
              <CopyIcon />
              <span>Copy</span>
            </>
          )}
        </button>
      </div>
      <SyntaxHighlighter
        style={codeTheme}
        language={language}
        PreTag="div"
        customStyle={{
          margin: 0,
          borderRadius: "0 0 14px 14px",
          padding: "16px 18px",
          background: "transparent",
        }}
        codeTagProps={{
          style: {
            fontFamily:
              '"SF Mono", SFMono-Regular, Menlo, Monaco, Consolas, monospace',
            fontSize: "12.2px",
            lineHeight: "1.6",
          },
        }}
      >
        {code}
      </SyntaxHighlighter>
    </div>
  );
}

export const CodeBlock = memo(CodeBlockInner);
