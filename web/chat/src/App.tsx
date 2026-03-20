import { startTransition, useCallback, useEffect, useRef, useState } from "react";
import { ChatView } from "./components/ChatView";
import { FindBar } from "./components/FindBar";
import { useTextSelection } from "./hooks/useTextSelection";
import type { ChatMessage, TypingState } from "./types";

const HISTORY_TRUNCATE_TRANSITION_MS = 180;

function clearMessageTransitionState(message: ChatMessage): ChatMessage {
  if (!message.transitionState) {
    return message;
  }
  const { transitionState, ...stableMessage } = message;
  return stableMessage;
}

function stableMessages(messages: ChatMessage[]): ChatMessage[] {
  return messages
    .filter((message) => message.transitionState !== "removing")
    .map(clearMessageTransitionState);
}

function dedupeMessages(messages: ChatMessage[]): ChatMessage[] {
  const seen = new Set<string>();
  const deduped: ChatMessage[] = [];

  for (let i = messages.length - 1; i >= 0; i--) {
    if (!seen.has(messages[i].id)) {
      seen.add(messages[i].id);
      deduped.unshift(clearMessageTransitionState(messages[i]));
    }
  }

  return deduped;
}

function buildTruncationTransition(
  previous: ChatMessage[],
  next: ChatMessage[]
): ChatMessage[] | null {
  if (next.length >= previous.length) {
    return null;
  }

  const keepsPrefix = next.every((message, index) => previous[index]?.id === message.id);
  if (!keepsPrefix) {
    return null;
  }

  const removedTail = previous.slice(next.length).map((message) => ({
    ...clearMessageTransitionState(message),
    transitionState: "removing" as const,
  }));

  if (removedTail.length === 0) {
    return null;
  }

  return [...next.map(clearMessageTransitionState), ...removedTail];
}

export function App() {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [typing, setTyping] = useState<TypingState>({ visible: false });
  const [textScale, setTextScaleState] = useState(1.0);
  const [isPinnedToBottom, setIsPinnedToBottom] = useState(true);
  const [canLoadOlder, setCanLoadOlder] = useState(false);
  const [findVisible, setFindVisible] = useState(false);
  const pendingTruncationTimeoutRef = useRef<number | null>(null);
  const chatViewRef = useRef<{ scrollToBottom: (animated: boolean) => void }>(
    null
  );

  const handleScrollState = useCallback(
    (pinned: boolean, scrolledUp: boolean, distFromTop: number) => {
      setIsPinnedToBottom(pinned);
      try {
        window.webkit?.messageHandlers?.scrollState?.postMessage({
          isPinned: pinned,
          isScrolledUp: scrolledUp,
          distanceFromTop: distFromTop,
        });
      } catch {}
    },
    []
  );

  const handleLoadOlder = useCallback(() => {
    try {
      window.webkit?.messageHandlers?.loadOlderHistory?.postMessage(true);
    } catch {}
  }, []);

  const handleJumpToLatest = useCallback(() => {
    chatViewRef.current?.scrollToBottom(true);
    setIsPinnedToBottom(true);
    try {
      window.webkit?.messageHandlers?.scrollState?.postMessage({
        isPinned: true,
        isScrolledUp: false,
        distanceFromTop: 999,
      });
    } catch {}
  }, []);

  // Text selection tracking for Ask/Explain feature
  useTextSelection();

  // Expose bridge API to Swift
  useEffect(() => {
    const clearPendingTruncationTransition = () => {
      if (pendingTruncationTimeoutRef.current !== null) {
        window.clearTimeout(pendingTruncationTimeoutRef.current);
        pendingTruncationTimeoutRef.current = null;
      }
    };

    const bridge = {
      setMessages: (msgs: ChatMessage[]) => {
        const deduped = dedupeMessages(msgs);
        const applyUpdate = () =>
          setMessages((prev) => {
            clearPendingTruncationTransition();

            const stablePrevious = stableMessages(prev);
            const truncationTransition = buildTruncationTransition(
              stablePrevious,
              deduped
            );

            if (!truncationTransition) {
              return deduped;
            }

            pendingTruncationTimeoutRef.current = window.setTimeout(() => {
              startTransition(() => {
                setMessages(deduped);
              });
              pendingTruncationTimeoutRef.current = null;
            }, HISTORY_TRUNCATE_TRANSITION_MS);

            return truncationTransition;
          });

        if (deduped[deduped.length - 1]?.isStreaming) {
          startTransition(applyUpdate);
          return;
        }

        applyUpdate();
      },

      updateLastMessage: (
        messageID: string,
        text: string,
        isStreaming: boolean
      ) => {
        clearPendingTruncationTransition();
        startTransition(() => {
          setMessages((prev) => {
            const stablePrevious = stableMessages(prev);
            if (stablePrevious.length === 0) return stablePrevious;
            const last = stablePrevious[stablePrevious.length - 1];
            if (last.id !== messageID) {
              return stablePrevious;
            }
            if (last.text === text && last.isStreaming === isStreaming) {
              return stablePrevious;
            }
            const updated = [...stablePrevious];
            updated[updated.length - 1] = { ...last, text, isStreaming };
            return updated;
          });
        });
      },

      appendMessage: (msg: ChatMessage) => {
        clearPendingTruncationTransition();
        setMessages((prev) => [...stableMessages(prev), clearMessageTransitionState(msg)]);
      },

      setTypingIndicator: (
        visible: boolean,
        title?: string,
        detail?: string
      ) => {
        setTyping({ visible, title, detail });
      },

      scrollToBottom: (animated: boolean) => {
        chatViewRef.current?.scrollToBottom(animated);
      },

      setTextScale: (scale: number) => {
        setTextScaleState(Math.max(0.8, scale));
      },

      setCanLoadOlder: (can: boolean) => {
        setCanLoadOlder(can);
      },

      toggleFind: () => {
        setFindVisible((v) => !v);
      },

      closeFind: () => {
        setFindVisible(false);
      },
    };

    (window as any).chatBridge = bridge;

    // Signal ready
    try {
      window.webkit?.messageHandlers?.ready?.postMessage(true);
    } catch {}

    return () => {
      clearPendingTruncationTransition();
      delete (window as any).chatBridge;
    };
  }, []);

  return (
    <>
      <FindBar visible={findVisible} onClose={() => setFindVisible(false)} />
      <ChatView
        ref={chatViewRef}
        messages={messages}
        typing={typing}
        textScale={textScale}
        isPinnedToBottom={isPinnedToBottom}
        canLoadOlder={canLoadOlder}
        onScrollState={handleScrollState}
        onLoadOlder={handleLoadOlder}
        onJumpToLatest={handleJumpToLatest}
      />
    </>
  );
}

// Type declarations for webkit bridge
declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        ready?: { postMessage: (v: boolean) => void };
        scrollState?: { postMessage: (v: any) => void };
        loadOlderHistory?: { postMessage: (v: boolean) => void };
        linkClicked?: { postMessage: (url: string) => void };
        copyText?: { postMessage: (text: string) => void };
        undoMessage?: { postMessage: (anchorID: string) => void };
        editMessage?: { postMessage: (anchorID: string) => void };
        openImage?: {
          postMessage: (payload: { dataUrl: string; suggestedName?: string }) => void;
        };
      };
    };
  }
}
