import { memo, useCallback, useEffect, useRef, useState } from "react";
import type { ChatMessage } from "../types";
import { MarkdownContent } from "./MarkdownContent";
import { CollapsibleImageGallery } from "./CollapsibleImageGallery";

function AssistantMessageInner({ message }: { message: ChatMessage }) {
  const text = message.text || "";
  const renderedText = useStreamingText(text, message.isStreaming);
  const showRevealPulse = useStreamingRevealPulse(
    renderedText,
    message.isStreaming
  );
  const transitionClass = message.transitionState
    ? ` is-${message.transitionState}`
    : "";
  const copyText = message.isStreaming ? renderedText : text;

  const handleCopy = useCallback(() => {
    navigator.clipboard.writeText(copyText).catch(() => {
      try {
        window.webkit?.messageHandlers?.copyText?.postMessage(copyText);
      } catch {}
    });
  }, [copyText]);

  return (
    <div
      className={`message-row assistant-row${message.isStreaming ? " streaming" : ""}${transitionClass}`}
      data-message-id={message.id}
      data-message-text={copyText}
    >
      <div className="assistant-content">
        {copyText && (
          <button
            className="copy-btn copy-btn-float"
            onClick={handleCopy}
            title="Copy message"
          >
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
              <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
            </svg>
          </button>
        )}

        {copyText && (
          <div
            className={`assistant-markdown-shell${showRevealPulse ? " reveal-pulse" : ""}`}
          >
            <MarkdownContent
              markdown={renderedText}
              isStreaming={message.isStreaming}
            />
          </div>
        )}

        <CollapsibleImageGallery
          images={message.images || []}
          itemName="image"
          className="assistant-images"
          imageClassName="assistant-image"
        />

      </div>
    </div>
  );
}

export const AssistantMessage = memo(AssistantMessageInner);

function useStreamingRevealPulse(text: string, isStreaming: boolean): boolean {
  const [isPulsing, setIsPulsing] = useState(false);
  const previousTextRef = useRef(text);

  useEffect(() => {
    if (!isStreaming) {
      previousTextRef.current = text;
      setIsPulsing(false);
      return;
    }

    if (text === previousTextRef.current) {
      return;
    }

    previousTextRef.current = text;
    setIsPulsing(true);
    const timeoutID = window.setTimeout(() => {
      setIsPulsing(false);
    }, 150);

    return () => window.clearTimeout(timeoutID);
  }, [isStreaming, text]);

  return isPulsing;
}

function useStreamingText(text: string, isStreaming: boolean): string {
  const [displayedText, setDisplayedText] = useState(text);
  const targetTextRef = useRef(text);
  const frameRef = useRef<number | null>(null);

  useEffect(() => {
    targetTextRef.current = text;

    if (!isStreaming) {
      if (frameRef.current !== null) {
        window.cancelAnimationFrame(frameRef.current);
        frameRef.current = null;
      }
      setDisplayedText(text);
      return;
    }

    setDisplayedText((current) => {
      if (current === text) {
        return current;
      }
      if (current.length > text.length || !text.startsWith(current)) {
        return text;
      }
      return current;
    });

    if (frameRef.current !== null || displayedText === text) {
      return;
    }

    const step = () => {
      frameRef.current = null;
      let shouldContinue = false;

      setDisplayedText((current) => {
        const target = targetTextRef.current;

        if (current === target) {
          return current;
        }

        if (current.length > target.length || !target.startsWith(current)) {
          return target;
        }

        const remaining = target.length - current.length;
        const chunkSize =
          remaining > 220
            ? 34
            : remaining > 120
              ? 24
              : remaining > 48
                ? 14
                : 6;
        const next = target.slice(0, current.length + chunkSize);
        shouldContinue = next.length < target.length;
        return next;
      });

      if (shouldContinue) {
        frameRef.current = window.requestAnimationFrame(step);
      }
    };

    frameRef.current = window.requestAnimationFrame(step);
  }, [displayedText, isStreaming, text]);

  useEffect(() => {
    return () => {
      if (frameRef.current !== null) {
        window.cancelAnimationFrame(frameRef.current);
      }
    };
  }, []);

  return displayedText;
}
