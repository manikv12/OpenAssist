import { memo, useCallback, useState } from "react";
import { Prism as SyntaxHighlighter } from "react-syntax-highlighter";
import { copyPlainText } from "../clipboard";
import { AppIcon } from "./AppIcon";
import { useIsStreaming } from "../StreamingContext";

interface Props {
  code: string;
  language: string;
  theme: Record<string, React.CSSProperties>;
}

const plainCodeStyle: React.CSSProperties = {
  margin: 0,
  borderRadius: "0 0 14px 14px",
  padding: "16px 18px",
  background: "transparent",
  color: "var(--chat-code-text)",
  fontFamily: '"SF Mono", SFMono-Regular, Menlo, Monaco, Consolas, monospace',
  fontSize: "12.2px",
  lineHeight: "1.6",
  overflow: "auto",
  whiteSpace: "pre",
};

function CodeBlockInner({ code, language, theme }: Props) {
  const [copied, setCopied] = useState(false);
  const isStreaming = useIsStreaming();

  const handleCopy = useCallback(() => {
    void copyPlainText(code).catch(() => {});
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
              <AppIcon symbol="check" size={13} strokeWidth={2.4} />
              <span>Copied</span>
            </>
          ) : (
            <>
              <AppIcon symbol="copy" size={13} strokeWidth={2} />
              <span>Copy</span>
            </>
          )}
        </button>
      </div>
      {isStreaming ? (
        <div style={plainCodeStyle}>
          <code>{code}</code>
        </div>
      ) : (
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
      )}
    </div>
  );
}

export const CodeBlock = memo(CodeBlockInner);
