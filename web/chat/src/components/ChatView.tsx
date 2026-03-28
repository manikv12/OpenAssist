import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import type {
  ChatMessage,
  MessageCheckpointInfo,
  ProviderTone,
  RewindState,
  TypingState,
} from "../types";
import { AppIcon } from "./AppIcon";
import { UserMessage } from "./UserMessage";
import { AssistantMessage } from "./AssistantMessage";
import { ActivityRow } from "./ActivityRow";
import { ActivityGroupRow } from "./ActivityGroupRow";
import { ActivitySummaryRow } from "./ActivitySummaryRow";
import { SystemMessage } from "./SystemMessage";
import { TypingIndicator } from "./TypingIndicator";

interface Props {
  messages: ChatMessage[];
  typing: TypingState;
  activeProviderTone?: ProviderTone;
  checkpointsByMessageID: Map<string, MessageCheckpointInfo>;
  rewindState: RewindState | null;
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
  {
    scrollToBottom: (animated: boolean) => void;
    revealMessage: (messageID: string, animated: boolean, expand: boolean) => void;
  },
  Props
>(function ChatView(
  {
    messages,
    typing,
    activeProviderTone = "default",
    checkpointsByMessageID,
    rewindState,
    textScale,
    isPinnedToBottom,
    canLoadOlder,
    onScrollState,
    onLoadOlder,
    onJumpToLatest,
  },
  ref
) {
  const latestRunningMessageID = (() => {
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      const message = messages[index];

      if (message.type === "activity" && message.activityStatus === "running") {
        return message.id;
      }

      if (
        message.type === "activityGroup" &&
        (message.groupItems || []).some((item) => item.status === "running")
      ) {
        return message.id;
      }
    }

    return undefined;
  })();

  const containerRef = useRef<HTMLDivElement>(null);
  const bottomRef = useRef<HTMLDivElement>(null);
  const wasAtBottom = useRef(true);
  const scrollTimeout = useRef<number>(0);
  const loadOlderAnchor = useRef<null | { scrollHeight: number; scrollTop: number }>(null);
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

  const revealMessage = useCallback(
    (messageID: string, animated: boolean, expand: boolean) => {
      const container = containerRef.current;
      if (!container) return;

      const escapedMessageID =
        typeof CSS !== "undefined" && typeof CSS.escape === "function"
          ? CSS.escape(messageID)
          : messageID.replace(/"/g, '\\"');
      const messageNode = container.querySelector<HTMLElement>(
        `[data-message-id="${escapedMessageID}"]`
      );
      if (!messageNode) return;

      if (expand) {
        const toggle = messageNode.querySelector<HTMLElement>(
          "[data-activity-toggle='true']"
        );
        if (toggle?.getAttribute("aria-expanded") === "false") {
          toggle.click();
        }
      }

      messageNode.scrollIntoView({
        behavior: animated ? "smooth" : "auto",
        block: "center",
      });
    },
    []
  );

  useImperativeHandle(
    ref,
    () => ({ scrollToBottom, revealMessage }),
    [revealMessage, scrollToBottom]
  );

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

  useLayoutEffect(() => {
    const container = containerRef.current;
    const anchor = loadOlderAnchor.current;
    if (!container || !anchor) return;

    const scrollDelta = container.scrollHeight - anchor.scrollHeight;
    container.scrollTop = anchor.scrollTop + scrollDelta;
    loadOlderAnchor.current = null;
    setIsLoadingOlder(false);
  }, [messages]);

  // Auto-scroll when new messages arrive (if pinned to bottom)
  useEffect(() => {
    if (loadOlderAnchor.current) {
      return;
    }
    if (wasAtBottom.current || isPinnedToBottom) {
      requestAnimationFrame(() => {
        scrollToBottom(false);
      });
    }
  }, [messages, typing, checkpointsByMessageID, isPinnedToBottom, scrollToBottom]);

  const handleLoadOlder = useCallback(() => {
    const container = containerRef.current;
    if (container) {
      loadOlderAnchor.current = {
        scrollHeight: container.scrollHeight,
        scrollTop: container.scrollTop,
      };
    }
    setIsLoadingOlder(true);
    onLoadOlder();
  }, [onLoadOlder]);

  const showJumpToLatest = !isPinnedToBottom && messages.length > 0;

  return (
    <>
      <div className="chat-shell" data-active-provider={activeProviderTone}>
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
            <MessageRow
              key={msg.id}
              message={msg}
              checkpointsByMessageID={checkpointsByMessageID}
              latestRunningMessageID={latestRunningMessageID}
              rewindState={rewindState}
            />
          ))}

          {typing.visible && (
            <TypingIndicator
              title={typing.title}
              detail={typing.detail}
              providerTone={activeProviderTone}
            />
          )}

          <div ref={bottomRef} className="scroll-anchor" />
        </div>

        {/* Top fade */}
        <div className="fade-top" />
        {/* Bottom fade */}
        <div className="fade-bottom" />
        </div>
      </div>

      {showJumpToLatest && (
        <button className="jump-to-latest" onClick={onJumpToLatest} title="Jump to latest">
          <AppIcon symbol="arrow.down" size={14} strokeWidth={2.5} />
        </button>
      )}

    </>
  );
});

function MessageRow({
  message,
  checkpointsByMessageID,
  latestRunningMessageID,
  rewindState: _rewindState,
}: {
  message: ChatMessage;
  checkpointsByMessageID: Map<string, MessageCheckpointInfo>;
  latestRunningMessageID?: string;
  rewindState: RewindState | null;
}) {
  switch (message.type) {
    case "user":
      return <UserMessage message={message} />;
    case "assistant":
      return <AssistantMessage message={message} checkpointInfo={checkpointsByMessageID.get(message.id)} />;
    case "activity":
      return (
        <ActivityRow
          message={message}
          isLatestRunningActivity={message.id === latestRunningMessageID}
        />
      );
    case "activityGroup":
      return (
        <ActivityGroupRow
          message={message}
          isLatestRunningActivity={message.id === latestRunningMessageID}
        />
      );
    case "activitySummary":
      return <ActivitySummaryRow message={message} />;
    case "system":
      return <SystemMessage message={message} />;
    default:
      return null;
  }
}
