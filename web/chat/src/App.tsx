import { startTransition, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ChatView } from "./components/ChatView";
import { FindBar } from "./components/FindBar";
import { useTextSelection } from "./hooks/useTextSelection";
import type {
  ChatMessage,
  CodeReviewPanelState,
  MessageCheckpointInfo,
  ProviderTone,
  RewindState,
  RuntimePanelState,
  TypingState,
} from "./types";

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

function providerTone(value?: string | null): ProviderTone {
  const normalized = (value || "").trim().toLowerCase();
  if (normalized.includes("copilot")) return "copilot";
  if (normalized.includes("codex")) return "codex";
  return "default";
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

function resolveCheckpointMessageIndex(
  messages: ChatMessage[],
  checkpoint: CodeReviewPanelState["checkpoints"][number]
): number {
  if (checkpoint.associatedMessageID) {
    const exactIndex = messages.findIndex((message) => message.id === checkpoint.associatedMessageID);
    if (exactIndex >= 0) {
      return exactIndex;
    }
  }

  if (checkpoint.associatedTurnID) {
    for (let index = messages.length - 1; index >= 0; index--) {
      if (
        messages[index].type === "assistant" &&
        messages[index].turnID === checkpoint.associatedTurnID
      ) {
        return index;
      }
    }
  }

  for (let index = messages.length - 1; index >= 0; index--) {
    if (
      messages[index].type === "assistant" &&
      messages[index].timestamp <= checkpoint.createdAt
    ) {
      return index;
    }
  }

  return -1;
}

function resolveCheckpointConversationStartIndex(
  messages: ChatMessage[],
  checkpointMessageIndex: number
): number | null {
  if (checkpointMessageIndex < 0 || checkpointMessageIndex >= messages.length) {
    return null;
  }

  for (let index = checkpointMessageIndex; index >= 0; index--) {
    if (messages[index].type === "user") {
      return index;
    }
  }

  return checkpointMessageIndex;
}

function resolveVisibleCheckpointMessageIndex(
  messages: ChatMessage[],
  checkpoint: CodeReviewPanelState["checkpoints"][number]
): number {
  if (checkpoint.associatedMessageID) {
    const exactIndex = messages.findIndex((message) => message.id === checkpoint.associatedMessageID);
    if (exactIndex >= 0) {
      return exactIndex;
    }
  }

  if (checkpoint.associatedTurnID) {
    for (let index = messages.length - 1; index >= 0; index--) {
      if (
        messages[index].type === "assistant" &&
        messages[index].turnID === checkpoint.associatedTurnID
      ) {
        return index;
      }
    }
  }

  return -1;
}

export function App() {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [typing, setTyping] = useState<TypingState>({ visible: false });
  const [runtimePanel, setRuntimePanel] = useState<RuntimePanelState | null>(null);
  const [codeReviewPanel, setCodeReviewPanel] = useState<CodeReviewPanelState | null>(
    null
  );
  const [rewindState, setRewindState] = useState<RewindState | null>(null);
  const [textScale, setTextScaleState] = useState(1.0);
  const [isPinnedToBottom, setIsPinnedToBottom] = useState(true);
  const [canLoadOlder, setCanLoadOlder] = useState(false);
  const activeProviderTone = useMemo<ProviderTone>(() => {
    const selectedBackendID = runtimePanel?.backends.find((backend) => backend.isSelected)?.id;
    return providerTone(selectedBackendID);
  }, [runtimePanel]);
  const [findVisible, setFindVisible] = useState(false);
  const pendingTruncationTimeoutRef = useRef<number | null>(null);
  const chatViewRef = useRef<{
    scrollToBottom: (animated: boolean) => void;
    revealMessage: (
      messageID: string,
      animated: boolean,
      expand: boolean
    ) => void;
  }>(null);

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

  const hiddenFutureState = useMemo(() => {
    const hiddenTurnIDs = new Set<string>();
    let truncationStartIndex: number | null = null;

    if (!codeReviewPanel || codeReviewPanel.actionsLocked) {
      return {
        hiddenTurnIDs,
        truncationStartIndex,
        futureTurnsHidden: false,
      };
    }

    const firstHiddenCheckpointIndex =
      codeReviewPanel.currentCheckpointPosition < 0
        ? 1
        : codeReviewPanel.currentCheckpointPosition + 1;
    if (
      firstHiddenCheckpointIndex >= 0 &&
      firstHiddenCheckpointIndex < codeReviewPanel.checkpoints.length
    ) {
      const firstHiddenCheckpoint = codeReviewPanel.checkpoints[firstHiddenCheckpointIndex];
      const checkpointMessageIndex = resolveVisibleCheckpointMessageIndex(
        messages,
        firstHiddenCheckpoint
      );
      if (checkpointMessageIndex >= 0) {
        truncationStartIndex = resolveCheckpointConversationStartIndex(
          messages,
          checkpointMessageIndex
        );
      }
    }

    for (
      let i = Math.max(0, firstHiddenCheckpointIndex);
      i < codeReviewPanel.checkpoints.length;
      i++
    ) {
      const turnID = codeReviewPanel.checkpoints[i].associatedTurnID;
      if (turnID) {
        hiddenTurnIDs.add(turnID);
      }
    }

    return {
      hiddenTurnIDs,
      truncationStartIndex,
      futureTurnsHidden: truncationStartIndex !== null || hiddenTurnIDs.size > 0,
    };
  }, [codeReviewPanel, messages]);

  const visibleMessages = useMemo(() => {
    if (hiddenFutureState.truncationStartIndex !== null) {
      return messages.slice(0, hiddenFutureState.truncationStartIndex);
    }

    if (hiddenFutureState.hiddenTurnIDs.size === 0) {
      return messages;
    }

    return messages.filter(
      (message) =>
        !message.turnID || !hiddenFutureState.hiddenTurnIDs.has(message.turnID)
    );
  }, [hiddenFutureState, messages]);

  // Build checkpoint-to-message mapping
  const checkpointsByMessageID = useMemo(() => {
    const map = new Map<string, MessageCheckpointInfo>();
    if (!codeReviewPanel) return map;
    const currentMessageIDs = new Set(visibleMessages.map((message) => message.id));
    const currentTurnIDs = new Set(
      visibleMessages
        .map((message) => message.turnID)
        .filter((turnID): turnID is string => typeof turnID === "string" && turnID.length > 0)
    );
    for (let i = 0; i < codeReviewPanel.checkpoints.length; i++) {
      const cp = codeReviewPanel.checkpoints[i];
      if (cp.associatedMessageID && currentMessageIDs.has(cp.associatedMessageID)) {
        map.set(cp.associatedMessageID, {
          checkpoint: cp,
          checkpointIndex: i,
          currentCheckpointPosition: codeReviewPanel.currentCheckpointPosition,
          totalCheckpointCount: codeReviewPanel.checkpoints.length,
          hasActiveTurn: codeReviewPanel.hasActiveTurn,
          actionsLocked: codeReviewPanel.actionsLocked,
          futureTurnsHidden: hiddenFutureState.futureTurnsHidden,
        });
      }
    }
    // Fallback for checkpoints whose saved message ID no longer exists after a restart:
    // first try the stable turn ID, then fall back to time-based placement.
    for (let i = 0; i < codeReviewPanel.checkpoints.length; i++) {
      const cp = codeReviewPanel.checkpoints[i];
      const hasMatchingAssociatedMessage =
        !!cp.associatedMessageID && currentMessageIDs.has(cp.associatedMessageID);
      if (hasMatchingAssociatedMessage) continue;
      if (cp.associatedTurnID && currentTurnIDs.has(cp.associatedTurnID)) {
        const turnMatchedMessage = visibleMessages.find(
          (message) => message.type === "assistant" && message.turnID === cp.associatedTurnID
        );
        if (turnMatchedMessage && !map.has(turnMatchedMessage.id)) {
          map.set(turnMatchedMessage.id, {
            checkpoint: cp,
            checkpointIndex: i,
            currentCheckpointPosition: codeReviewPanel.currentCheckpointPosition,
            totalCheckpointCount: codeReviewPanel.checkpoints.length,
            hasActiveTurn: codeReviewPanel.hasActiveTurn,
            actionsLocked: codeReviewPanel.actionsLocked,
            futureTurnsHidden: hiddenFutureState.futureTurnsHidden,
          });
          continue;
        }
      }
      if (cp.associatedMessageID || cp.associatedTurnID) {
        continue;
      }
      // Find the last assistant message before this checkpoint's timestamp
      let fallbackID: string | null = null;
      for (let j = visibleMessages.length - 1; j >= 0; j--) {
        if (
          visibleMessages[j].type === "assistant" &&
          visibleMessages[j].timestamp <= cp.createdAt
        ) {
          fallbackID = visibleMessages[j].id;
          break;
        }
      }
      if (fallbackID && !map.has(fallbackID)) {
        map.set(fallbackID, {
          checkpoint: cp,
          checkpointIndex: i,
          currentCheckpointPosition: codeReviewPanel.currentCheckpointPosition,
          totalCheckpointCount: codeReviewPanel.checkpoints.length,
          hasActiveTurn: codeReviewPanel.hasActiveTurn,
          actionsLocked: codeReviewPanel.actionsLocked,
          futureTurnsHidden: hiddenFutureState.futureTurnsHidden,
        });
      }
    }
    return map;
  }, [codeReviewPanel, hiddenFutureState.futureTurnsHidden, visibleMessages, messages]);

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
        setTyping((prev) => {
          if (
            prev.visible === visible &&
            prev.title === title &&
            prev.detail === detail
          ) {
            return prev;
          }
          return { visible, title, detail };
        });
      },

      setRuntimePanel: (panel: RuntimePanelState | null) => {
        setRuntimePanel(panel);
      },

      setCodeReviewPanel: (panel: CodeReviewPanelState | null) => {
        setCodeReviewPanel(panel);
      },

      setRewindState: (next: RewindState | null) => {
        setRewindState(next);
      },

      scrollToBottom: (animated: boolean) => {
        chatViewRef.current?.scrollToBottom(animated);
      },

      revealMessage: (messageID: string, animated: boolean, expand: boolean) => {
        chatViewRef.current?.revealMessage(messageID, animated, expand);
      },

      setTextScale: (scale: number) => {
        const nextScale = Math.max(0.8, scale);
        setTextScaleState((prev) => (prev === nextScale ? prev : nextScale));
      },

      setCanLoadOlder: (can: boolean) => {
        setCanLoadOlder((prev) => (prev === can ? prev : can));
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
        messages={visibleMessages}
        typing={typing}
        activeProviderTone={activeProviderTone}
        checkpointsByMessageID={checkpointsByMessageID}
        rewindState={rewindState}
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
        selectRuntimeBackend?: { postMessage: (backendID: string) => void };
        openRuntimeSettings?: { postMessage: (value: boolean) => void };
        undoMessage?: { postMessage: (anchorID: string) => void };
        editMessage?: { postMessage: (anchorID: string) => void };
        undoCodeCheckpoint?: { postMessage: (value: boolean) => void };
        redoHistoryMutation?: { postMessage: (value: boolean) => void };
        openImage?: {
          postMessage: (payload: { dataUrl: string; suggestedName?: string }) => void;
        };
      };
    };
  }
}
