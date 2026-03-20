import { memo, useCallback, useState } from "react";
import { Prism as SyntaxHighlighter } from "react-syntax-highlighter";

interface Props {
  code: string;
  language: string;
  theme: Record<string, React.CSSProperties>;
}

function CodeBlockInner({ code, language, theme }: Props) {
  const [copied, setCopied] = useState(false);

  const handleCopy = useCallback(() => {
    navigator.clipboard.writeText(code).catch(() => {
      try {
        window.webkit?.messageHandlers?.copyText?.postMessage(code);
      } catch {}
    });
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [code]);

  return (
    <div className="code-block-wrapper">
      <div className="code-block-header">
        <span className="code-block-lang">{language}</span>
        <button className="code-block-copy" onClick={handleCopy}>
          {copied ? (
            <>
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <polyline points="20 6 9 17 4 12" />
              </svg>
              <span>Copied</span>
            </>
          ) : (
            <>
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
                <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
              </svg>
              <span>Copy</span>
            </>
          )}
        </button>
      </div>
      <SyntaxHighlighter
        style={theme}
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
