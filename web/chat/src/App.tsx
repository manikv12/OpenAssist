import { startTransition, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ChatView } from "./components/ChatView";
import { ComposerView } from "./components/ComposerView";
import { FindBar } from "./components/FindBar";
import { SidebarView } from "./components/SidebarView";
import { ThreadNoteDrawer } from "./components/ThreadNoteDrawer";
import { useTextSelection } from "./hooks/useTextSelection";
import type {
  ActiveWorkState,
  ActiveTurnState,
  AssistantComposerActivityState,
  AssistantComposerControlsState,
  AssistantComposerState,
  AssistantSidebarState,
  ChatMessage,
  ChatStreamEvent,
  CodeReviewPanelState,
  MessageCheckpointInfo,
  ProviderTone,
  RewindState,
  RuntimePanelState,
  ThreadNoteState,
  TypingState,
} from "./types";

const HISTORY_TRUNCATE_TRANSITION_MS = 110;
const SESSION_SWAP_ENTER_TAIL_COUNT = 4;
const SESSION_SWAP_ANIMATION_MESSAGE_LIMIT = 24;
type AppViewMode = "chat" | "sidebar" | "composer";

function normalizeViewMode(mode?: string | null): AppViewMode {
  if (mode === "sidebar") return "sidebar";
  if (mode === "composer") return "composer";
  return "chat";
}

function initialViewMode(): AppViewMode {
  return normalizeViewMode(window.__OPENASSIST_INITIAL_VIEW_MODE);
}

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
  if (normalized.includes("claude") || normalized.includes("anthropic")) return "claude";
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

function upsertMessageInOrder(
  messages: ChatMessage[],
  message: ChatMessage,
  afterMessageID?: string
): ChatMessage[] {
  const stable = stableMessages(messages);
  const nextMessage = clearMessageTransitionState(message);
  const withoutExisting = stable.filter((entry) => entry.id !== nextMessage.id);

  if (!afterMessageID) {
    return [...withoutExisting, nextMessage];
  }

  const anchorIndex = withoutExisting.findIndex((entry) => entry.id === afterMessageID);
  if (anchorIndex < 0) {
    return [...withoutExisting, nextMessage];
  }

  return [
    ...withoutExisting.slice(0, anchorIndex + 1),
    nextMessage,
    ...withoutExisting.slice(anchorIndex + 1),
  ];
}

function applyChatStreamEvents(
  previousMessages: ChatMessage[],
  previousActiveWork: ActiveWorkState | null,
  previousTyping: TypingState,
  previousActiveTurn: ActiveTurnState | null,
  events: ChatStreamEvent[]
): {
  messages: ChatMessage[];
  activeWork: ActiveWorkState | null;
  typing: TypingState;
  activeTurn: ActiveTurnState | null;
} {
  let messages = stableMessages(previousMessages);
  let activeWork = previousActiveWork;
  let typing = previousTyping;
  let activeTurn = previousActiveTurn;

  for (const event of events) {
    switch (event.kind) {
      case "replaceMessages":
        messages = dedupeMessages(event.messages);
        break;
      case "responseTextDelta":
        messages = messages.map((message) =>
          message.id === event.messageID
            ? { ...message, text: event.text, isStreaming: event.isStreaming }
            : message
        );
        break;
      case "upsertMessage":
        messages = upsertMessageInOrder(messages, event.message, event.afterMessageID);
        break;
      case "removeMessage":
        messages = messages.filter((message) => message.id !== event.messageID);
        break;
      case "setActiveWorkState":
        activeWork = event.state;
        break;
      case "setTypingState":
        typing = event.state;
        break;
      case "setActiveTurnState":
        activeTurn = event.state;
        break;
    }
  }

  return { messages, activeWork, typing, activeTurn };
}

function buildTruncationTransition(
  previous: ChatMessage[],
  next: ChatMessage[]
): ChatMessage[] | null {
  if (next.length === 0 || next.length >= previous.length) {
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

function buildExpansionTransition(
  previous: ChatMessage[],
  next: ChatMessage[]
): ChatMessage[] | null {
  if (previous.length === 0 || next.length <= previous.length) {
    return null;
  }

  const keepsPrefix = previous.every((message, index) => next[index]?.id === message.id);
  if (!keepsPrefix) {
    return null;
  }

  const addedTail = next.slice(previous.length).map((message) => ({
    ...clearMessageTransitionState(message),
    transitionState: "entering" as const,
  }));

  if (addedTail.length === 0) {
    return null;
  }

  return [...previous.map(clearMessageTransitionState), ...addedTail];
}

function buildSessionSwapTransition(
  previous: ChatMessage[],
  next: ChatMessage[]
): ChatMessage[] | null {
  if (next.length === 0) {
    return null;
  }

  if (previous.length > 0) {
    const nextIDs = new Set(next.map((message) => message.id));
    const sharesMessages = previous.some((message) => nextIDs.has(message.id));
    if (sharesMessages) {
      return null;
    }
  }

  if (next.length > SESSION_SWAP_ANIMATION_MESSAGE_LIMIT) {
    return next.map(clearMessageTransitionState);
  }

  const enteringStartIndex = Math.max(0, next.length - SESSION_SWAP_ENTER_TAIL_COUNT);
  return next.map((message, index) =>
    index < enteringStartIndex
      ? clearMessageTransitionState(message)
      : {
          ...clearMessageTransitionState(message),
          transitionState: "entering" as const,
        }
  );
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
  const [viewMode, setViewMode] = useState<AppViewMode>(initialViewMode);
  const [sidebarState, setSidebarState] = useState<AssistantSidebarState | null>(null);
  const [composerState, setComposerState] = useState<AssistantComposerState | null>(null);
  const [composerControlsState, setComposerControlsState] =
    useState<AssistantComposerControlsState | null>(null);
  const [composerActivityState, setComposerActivityState] =
    useState<AssistantComposerActivityState | null>(null);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [typing, setTyping] = useState<TypingState>({ visible: false });
  const [runtimePanel, setRuntimePanel] = useState<RuntimePanelState | null>(null);
  const [codeReviewPanel, setCodeReviewPanel] = useState<CodeReviewPanelState | null>(
    null
  );
  const [rewindState, setRewindState] = useState<RewindState | null>(null);
  const [threadNoteState, setThreadNoteState] = useState<ThreadNoteState | null>(null);
  const [activeWorkState, setActiveWorkState] = useState<ActiveWorkState | null>(null);
  const [activeTurnState, setActiveTurnState] = useState<ActiveTurnState | null>(null);
  const [textScale, setTextScaleState] = useState(1.0);
  const [isPinnedToBottom, setIsPinnedToBottom] = useState(true);
  const [canLoadOlder, setCanLoadOlder] = useState(false);
  const activeProviderTone = useMemo<ProviderTone>(() => {
    const selectedBackendID = runtimePanel?.backends.find((backend) => backend.isSelected)?.id;
    return providerTone(activeTurnState?.providerLabel ?? selectedBackendID);
  }, [activeTurnState, runtimePanel]);
  const [findVisible, setFindVisible] = useState(false);
  const pendingTruncationTimeoutRef = useRef<number | null>(null);
  const pendingEnterAnimationFrameRef = useRef<number | null>(null);
  const messagesRef = useRef<ChatMessage[]>([]);
  const typingRef = useRef<TypingState>({ visible: false });
  const activeWorkRef = useRef<ActiveWorkState | null>(null);
  const activeTurnRef = useRef<ActiveTurnState | null>(null);
  const chatViewRef = useRef<{
    scrollToBottom: (animated: boolean) => void;
    revealMessage: (
      messageID: string,
      animated: boolean,
      expand: boolean
    ) => void;
  }>(null);

  useEffect(() => {
    messagesRef.current = messages;
  }, [messages]);

  useEffect(() => {
    typingRef.current = typing;
  }, [typing]);

  useEffect(() => {
    activeWorkRef.current = activeWorkState;
  }, [activeWorkState]);

  useEffect(() => {
    activeTurnRef.current = activeTurnState;
  }, [activeTurnState]);

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

  const handleSidebarCommand = useCallback(
    (type: string, payload?: Record<string, unknown>) => {
      try {
        window.webkit?.messageHandlers?.sidebarCommand?.postMessage({
          type,
          payload: payload ?? null,
        });
      } catch {}
    },
    []
  );

  const handleComposerCommand = useCallback(
    (type: string, payload?: Record<string, unknown>) => {
      try {
        window.webkit?.messageHandlers?.composerCommand?.postMessage({
          type,
          payload: payload ?? null,
        });
      } catch {}
    },
    []
  );

  const handleThreadNoteCommand = useCallback(
    (type: string, payload?: Record<string, unknown>) => {
      try {
        window.webkit?.messageHandlers?.threadNoteCommand?.postMessage({
          type,
          ...(payload ?? {}),
        });
      } catch {}
    },
    []
  );

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
    const clearPendingMessageTransitions = () => {
      if (pendingTruncationTimeoutRef.current !== null) {
        window.clearTimeout(pendingTruncationTimeoutRef.current);
        pendingTruncationTimeoutRef.current = null;
      }
      if (pendingEnterAnimationFrameRef.current !== null) {
        window.cancelAnimationFrame(pendingEnterAnimationFrameRef.current);
        pendingEnterAnimationFrameRef.current = null;
      }
    };

    const settleEnteringMessages = (messages: ChatMessage[]) => {
      pendingEnterAnimationFrameRef.current = window.requestAnimationFrame(() => {
        pendingEnterAnimationFrameRef.current = window.requestAnimationFrame(() => {
          startTransition(() => {
            setMessages(messages);
          });
          pendingEnterAnimationFrameRef.current = null;
        });
      });
    };

    const bridge = {
      updateMessage: (
        messageID: string,
        text: string,
        isStreaming: boolean
      ) => {
        clearPendingMessageTransitions();
        const stablePrevious = stableMessages(messagesRef.current);
        const targetIndex = stablePrevious.findIndex((message) => message.id === messageID);
        if (targetIndex < 0) {
          return;
        }

        const targetMessage = stablePrevious[targetIndex];
        if (targetMessage.text === text && targetMessage.isStreaming === isStreaming) {
          return;
        }

        const updated = [...stablePrevious];
        updated[targetIndex] = { ...targetMessage, text, isStreaming };
        messagesRef.current = updated;

        startTransition(() => {
          setMessages(updated);
        });
      },

      setMessages: (msgs: ChatMessage[]) => {
        const deduped = dedupeMessages(msgs);
        const applyUpdate = () =>
          setMessages((prev) => {
            clearPendingMessageTransitions();

            const stablePrevious = stableMessages(prev);
            const truncationTransition = buildTruncationTransition(
              stablePrevious,
              deduped
            );
            const enteringTransition = buildSessionSwapTransition(
              stablePrevious,
              deduped
            );

            if (truncationTransition) {
              pendingTruncationTimeoutRef.current = window.setTimeout(() => {
                startTransition(() => {
                  setMessages(deduped);
                });
                pendingTruncationTimeoutRef.current = null;
              }, HISTORY_TRUNCATE_TRANSITION_MS);

              return truncationTransition;
            }

            if (enteringTransition) {
              settleEnteringMessages(deduped);
              return enteringTransition;
            }

            return deduped;
          });

        messagesRef.current = deduped;
        startTransition(applyUpdate);
      },

      applyStreamEvents: (events: ChatStreamEvent[]) => {
        if (!events.length) {
          return;
        }

        clearPendingMessageTransitions();

        const next = applyChatStreamEvents(
          messagesRef.current,
          activeWorkRef.current,
          typingRef.current,
          activeTurnRef.current,
          events
        );

        messagesRef.current = next.messages;
        activeWorkRef.current = next.activeWork;
        typingRef.current = next.typing;
        activeTurnRef.current = next.activeTurn;

        startTransition(() => {
          setMessages(next.messages);
          setActiveWorkState(next.activeWork);
          setTyping(next.typing);
          setActiveTurnState(next.activeTurn);
        });
      },

      updateLastMessage: (
        messageID: string,
        text: string,
        isStreaming: boolean
      ) => {
        bridge.updateMessage(messageID, text, isStreaming);
      },

      appendMessage: (msg: ChatMessage) => {
        clearPendingMessageTransitions();
        const nextMessages = [
          ...stableMessages(messagesRef.current),
          clearMessageTransitionState(msg),
        ];
        messagesRef.current = nextMessages;
        setMessages(nextMessages);
      },

      setTypingIndicator: (
        visible: boolean,
        title?: string,
        detail?: string
      ) => {
        const nextTyping = { visible, title, detail };
        if (
          typingRef.current.visible === visible &&
          typingRef.current.title === title &&
          typingRef.current.detail === detail
        ) {
          return;
        }
        typingRef.current = nextTyping;
        setTyping(nextTyping);
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

      setThreadNoteState: (next: ThreadNoteState | null) => {
        startTransition(() => {
          setThreadNoteState(next);
        });
      },

      handleThreadNoteImageUploadResult: (result: {
        requestId: string;
        ok: boolean;
        message?: string | null;
        url?: string | null;
        relativePath?: string | null;
      }) => {
        window.dispatchEvent(
          new CustomEvent("openassist:thread-note-image-result", {
            detail: result,
          })
        );
      },

      handleThreadNoteScreenshotCaptureResult: (result: {
        requestId: string;
        ok: boolean;
        cancelled?: boolean;
        message?: string | null;
        captureMode?: string | null;
        segmentCount?: number | null;
        filename?: string | null;
        mimeType?: string | null;
        dataUrl?: string | null;
      }) => {
        window.dispatchEvent(
          new CustomEvent("openassist:thread-note-screenshot-capture-result", {
            detail: result,
          })
        );
      },

      handleThreadNoteScreenshotProcessingResult: (result: {
        requestId: string;
        ok: boolean;
        message?: string | null;
        outputMode?: string | null;
        markdown?: string | null;
        rawText?: string | null;
        usedVision?: boolean;
      }) => {
        window.dispatchEvent(
          new CustomEvent("openassist:thread-note-screenshot-processing-result", {
            detail: result,
          })
        );
      },

      handleThreadNoteSaveAck: (result: {
        requestId: string;
        ownerKind?: string | null;
        ownerId?: string | null;
        noteId?: string | null;
        draftRevision?: number | null;
        status: "ok" | "error";
        errorMessage?: string | null;
      }) => {
        window.dispatchEvent(
          new CustomEvent("openassist:thread-note-save-ack", {
            detail: result,
          })
        );
      },

      setActiveWorkState: (next: ActiveWorkState | null) => {
        activeWorkRef.current = next;
        setActiveWorkState(next);
      },

      setActiveTurnState: (next: ActiveTurnState | null) => {
        activeTurnRef.current = next;
        setActiveTurnState(next);
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

      setViewMode: (mode: AppViewMode | string) => {
        setViewMode(normalizeViewMode(mode));
      },

      setSidebarState: (nextState: AssistantSidebarState | null) => {
        setSidebarState(nextState);
      },

      setComposerState: (nextState: AssistantComposerState | null) => {
        setComposerState(nextState);
        if (!nextState) {
          setComposerControlsState(null);
          setComposerActivityState(null);
        }
      },

      setComposerControls: (nextState: AssistantComposerControlsState | null) => {
        setComposerControlsState(nextState);
      },

      setComposerActivity: (nextState: AssistantComposerActivityState | null) => {
        setComposerActivityState(nextState);
      },
    };

    (window as any).chatBridge = bridge;

    // Signal ready
    try {
      window.webkit?.messageHandlers?.ready?.postMessage(true);
    } catch {}

    return () => {
      clearPendingMessageTransitions();
      delete (window as any).chatBridge;
    };
  }, []);

  if (viewMode === "sidebar") {
    return (
      <SidebarView
        state={sidebarState}
        textScale={textScale}
        onDispatchCommand={handleSidebarCommand}
      />
    );
  }

  if (viewMode === "composer") {
    return (
      <ComposerView
        state={composerState}
        controlsState={composerControlsState}
        activityState={composerActivityState}
        onDispatchCommand={handleComposerCommand}
      />
    );
  }

  const isProjectNotesMode = threadNoteState?.presentation === "projectFullScreen";
  const isNotesWorkspaceMode = threadNoteState?.presentation === "notesWorkspace";
  const isDedicatedNotesMode = isProjectNotesMode || isNotesWorkspaceMode;

  return (
    <>
      <FindBar visible={findVisible} onClose={() => setFindVisible(false)} />
      <div
        className={[
          "chat-stage",
          isDedicatedNotesMode ? "is-project-notes-mode" : "",
          isNotesWorkspaceMode ? "is-notes-workspace-mode" : "",
          threadNoteState?.isOpen ? "has-thread-note-open" : "",
        ]
          .filter(Boolean)
          .join(" ")}
      >
        {!isDedicatedNotesMode ? (
          <ChatView
            ref={chatViewRef}
            messages={visibleMessages}
            typing={typing}
            activeWork={activeWorkState}
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
        ) : null}

        <ThreadNoteDrawer
          state={threadNoteState}
          onDispatchCommand={handleThreadNoteCommand}
        />
      </div>
    </>
  );
}

// Type declarations for webkit bridge
declare global {
  interface Window {
    __OPENASSIST_INITIAL_VIEW_MODE?: AppViewMode;
    chatBridge?: {
      setActiveWorkState?: (next: ActiveWorkState | null) => void;
      setActiveTurnState?: (next: ActiveTurnState | null) => void;
      applyStreamEvents?: (events: ChatStreamEvent[]) => void;
      handleThreadNoteImageUploadResult?: (result: {
        requestId: string;
        ok: boolean;
        message?: string | null;
        url?: string | null;
        relativePath?: string | null;
      }) => void;
      handleThreadNoteScreenshotCaptureResult?: (result: {
        requestId: string;
        ok: boolean;
        cancelled?: boolean;
        message?: string | null;
        filename?: string | null;
        mimeType?: string | null;
        dataUrl?: string | null;
      }) => void;
      handleThreadNoteScreenshotProcessingResult?: (result: {
        requestId: string;
        ok: boolean;
        message?: string | null;
        outputMode?: string | null;
        markdown?: string | null;
        rawText?: string | null;
        usedVision?: boolean;
      }) => void;
      handleThreadNoteSaveAck?: (result: {
        requestId: string;
        ownerKind?: string | null;
        ownerId?: string | null;
        noteId?: string | null;
        draftRevision?: number | null;
        status: "ok" | "error";
        errorMessage?: string | null;
      }) => void;
      flushThreadNoteDraft?: () => {
        ok: boolean;
        ownerKind?: string | null;
        ownerId?: string | null;
        noteId?: string | null;
        sourceKind?: string | null;
        text?: string | null;
        draftRevision?: number | null;
        isDirty?: boolean;
      } | null;
      updateMessage?: (
        messageID: string,
        text: string,
        isStreaming: boolean
      ) => void;
    };
    webkit?: {
      messageHandlers?: {
        ready?: { postMessage: (v: boolean) => void };
        sidebarCommand?: {
          postMessage: (payload: { type: string; payload?: Record<string, unknown> | null }) => void;
        };
        composerCommand?: {
          postMessage: (payload: { type: string; payload?: Record<string, unknown> | null }) => void;
        };
        composerHeightDidChange?: { postMessage: (height: number) => void };
        scrollState?: { postMessage: (v: any) => void };
        loadOlderHistory?: { postMessage: (v: boolean) => void };
        loadActivityDetails?: { postMessage: (renderItemID: string) => void };
        collapseActivityDetails?: { postMessage: (renderItemID: string) => void };
        linkClicked?: { postMessage: (url: string) => void };
        copyText?: { postMessage: (text: string) => void };
        selectRuntimeBackend?: { postMessage: (backendID: string) => void };
        openRuntimeSettings?: { postMessage: (value: boolean) => void };
        undoMessage?: { postMessage: (anchorID: string) => void };
        editMessage?: { postMessage: (anchorID: string) => void };
        undoCodeCheckpoint?: { postMessage: (value: boolean) => void };
        redoHistoryMutation?: { postMessage: (value: boolean) => void };
        restoreCodeCheckpoint?: { postMessage: (checkpointID: string) => void };
        threadNoteCommand?: {
          postMessage: (payload: Record<string, unknown>) => void;
        };
        openImage?: {
          postMessage: (payload: { dataUrl: string; suggestedName?: string }) => void;
        };
      };
    };
  }
}
