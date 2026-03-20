import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
} from "react";
import type { ChatMessage, TypingState } from "../types";
import { UserMessage } from "./UserMessage";
import { AssistantMessage } from "./AssistantMessage";
import { ActivityRow } from "./ActivityRow";
import { ActivityGroupRow } from "./ActivityGroupRow";
import { SystemMessage } from "./SystemMessage";
import { TypingIndicator } from "./TypingIndicator";

interface Props {
  messages: ChatMessage[];
  typing: TypingState;
  textScale: number;
  isPinnedToBottom: boolean;
  canLoadOlder: boolean;
  onScrollState: (
    pinned: boolean,
    scrolledUp: boolean,
    distFromTop: number
  ) => void;
  onLoadOlder: () => void;
  onJumpToLatest: () => void;
}

export const ChatView = forwardRef<
  { scrollToBottom: (animated: boolean) => void },
  Props
>(function ChatView(
  {
    messages,
    typing,
    textScale,
    isPinnedToBottom,
    canLoadOlder,
    onScrollState,
    onLoadOlder,
    onJumpToLatest,
  },
  ref
) {
  const containerRef = useRef<HTMLDivElement>(null);
  const bottomRef = useRef<HTMLDivElement>(null);
  const wasAtBottom = useRef(true);
  const scrollTimeout = useRef<number>(0);
  const [isLoadingOlder, setIsLoadingOlder] = useState(false);

  const scrollToBottom = useCallback((animated: boolean) => {
    const container = containerRef.current;
    if (!container) return;

    if (animated) {
      const el = bottomRef.current;
      if (!el) return;
      el.scrollIntoView({ behavior: "smooth" });
    } else {
      container.scrollTop = container.scrollHeight;
    }
    wasAtBottom.current = true;
  }, []);

  useImperativeHandle(ref, () => ({ scrollToBottom }), [scrollToBottom]);

  // Handle scroll events — only report scroll state, no auto-loading
  const handleScroll = useCallback(() => {
    const el = containerRef.current;
    if (!el) return;

    const distFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight;
    const distFromTop = el.scrollTop;
    const pinned = distFromBottom <= 24;
    const scrolledUp = distFromBottom > 80;

    wasAtBottom.current = pinned;

    clearTimeout(scrollTimeout.current);
    scrollTimeout.current = window.setTimeout(() => {
      onScrollState(pinned, scrolledUp, distFromTop);
    }, 50);
  }, [onScrollState]);

  // Auto-scroll when new messages arrive (if pinned to bottom)
  useEffect(() => {
    if (wasAtBottom.current || isPinnedToBottom) {
      requestAnimationFrame(() => {
        scrollToBottom(false);
      });
    }
  }, [messages, typing, isPinnedToBottom, scrollToBottom]);

  // Reset loading state when messages change (older messages arrived)
  useEffect(() => {
    setIsLoadingOlder(false);
  }, [messages.length]);

  const handleLoadOlder = useCallback(() => {
    setIsLoadingOlder(true);
    onLoadOlder();
  }, [onLoadOlder]);

  const showJumpToLatest = !isPinnedToBottom && messages.length > 0;

  return (
    <div className="chat-container" ref={containerRef} onScroll={handleScroll}>
      <div className="chat-messages" style={{ fontSize: `${13.8 * textScale}px` }}>

        {canLoadOlder && (
          <div className="load-older-row">
            <button
              className="load-older-btn"
              onClick={handleLoadOlder}
              disabled={isLoadingOlder}
            >
              {isLoadingOlder ? "Loading…" : "Load older messages"}
            </button>
          </div>
        )}

        {messages.map((msg) => (
          <MessageRow key={msg.id} message={msg} />
        ))}

        {typing.visible && (
          <TypingIndicator title={typing.title} detail={typing.detail} />
        )}

        <div ref={bottomRef} className="scroll-anchor" />
      </div>

      {/* Top fade */}
      <div className="fade-top" />
      {/* Bottom fade */}
      <div className="fade-bottom" />

      {showJumpToLatest && (
        <button className="jump-to-latest" onClick={onJumpToLatest}>
          <span>Latest</span>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
            <line x1="12" y1="5" x2="12" y2="19" />
            <polyline points="19 12 12 19 5 12" />
          </svg>
        </button>
      )}
    </div>
  );
});

function MessageRow({ message }: { message: ChatMessage }) {
  switch (message.type) {
    case "user":
      return <UserMessage message={message} />;
    case "assistant":
      return <AssistantMessage message={message} />;
    case "activity":
      return <ActivityRow message={message} />;
    case "activityGroup":
      return <ActivityGroupRow message={message} />;
    case "system":
      return <SystemMessage message={message} />;
    default:
      return null;
  }
}
