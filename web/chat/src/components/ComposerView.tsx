import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import type {
  AssistantComposerActivityState,
  AssistantComposerControlsState,
  AssistantComposerState,
  AssistantRuntimeControlsAvailability,
} from "../types";
import { AppIcon } from "./AppIcon";
import { groupSlashCommands, matchesSlashCommand, type SlashCommandLike } from "./slashCommandUtils";

interface ComposerViewProps {
  state: AssistantComposerState | null;
  controlsState: AssistantComposerControlsState | null;
  activityState: AssistantComposerActivityState | null;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}

const MAX_TEXTAREA_HEIGHT = 132;
const MAX_HISTORY_SIZE = 50;

type ComposerSlashGroupTone = "mode";

interface ComposerSlashQueryState {
  query: string;
  replaceFrom: number;
  replaceTo: number;
}

interface ComposerSlashCommand extends SlashCommandLike<ComposerSlashGroupTone> {
  mode: "note" | "chat";
}

type ComposerQuickActionID = "upload" | "skills" | "note-mode";

interface ComposerQuickAction {
  id: ComposerQuickActionID;
  label: string;
  detail: string;
  symbol: string;
  isActive?: boolean;
}

const DEFAULT_COMPOSER_CONTROLS_STATE: AssistantComposerControlsState = {
  availability: "unavailable",
  availabilityStatusText: "Loading controls...",
  showsInteractionModeControl: false,
  showsModelControls: false,
  showsReasoningControls: false,
  selectedInteractionMode: "",
  interactionModes: [],
  selectedModelId: undefined,
  modelOptions: [],
  modelPlaceholder: "Select model",
  opensModelSetupWhenUnavailable: false,
  selectedReasoningId: "",
  reasoningOptions: [],
};

const DEFAULT_COMPOSER_ACTIVITY_STATE: AssistantComposerActivityState = {
  isBusy: false,
  activeTurnPhase: "idle",
  canCancelActiveTurn: false,
  activeTurnProviderLabel: undefined,
  hasPendingToolApproval: false,
  hasPendingInput: false,
  isVoiceCapturing: false,
  canUseVoiceInput: false,
  showStopVoicePlayback: false,
};

const COMPOSER_SLASH_COMMANDS: ComposerSlashCommand[] = [
  {
    id: "note",
    label: "/note",
    subtitle: "Turn on sticky Note Mode for this chat.",
    groupId: "mode",
    groupLabel: "Modes",
    groupTone: "mode",
    groupOrder: 0,
    searchKeywords: ["notes", "project notes", "thread notes", "assistant notes"],
    mode: "note",
  },
  {
    id: "chat",
    label: "/chat",
    subtitle: "Turn Note Mode off and go back to normal chat.",
    groupId: "mode",
    groupLabel: "Modes",
    groupTone: "mode",
    groupOrder: 0,
    searchKeywords: ["normal chat", "default mode", "general"],
    mode: "chat",
  },
];

// Persistent prompt history shared across re-renders.
const promptHistory: string[] = [];

function detectComposerSlashQuery(
  text: string,
  selectionStart: number,
  selectionEnd: number
): ComposerSlashQueryState | null {
  if (selectionStart !== selectionEnd) {
    return null;
  }

  const beforeCaret = text.slice(0, selectionStart);
  const match = beforeCaret.match(/(?:^|\s)\/([a-z-]*)$/i);
  if (!match) {
    return null;
  }

  const slashOffset = beforeCaret.lastIndexOf("/");
  if (slashOffset < 0) {
    return null;
  }

  return {
    query: (match[1] ?? "").toLowerCase(),
    replaceFrom: slashOffset,
    replaceTo: selectionStart,
  };
}

function consumeLeadingSlashModeCommand(text: string): {
  nextText: string;
  mode: "note" | "chat" | null;
} {
  const trimmedLeading = text.trimStart();
  if (trimmedLeading.length === 0 || !trimmedLeading.startsWith("/")) {
    return { nextText: text, mode: null };
  }

  const match = trimmedLeading.match(/^\/(note|chat)(?=$|\s)/i);
  if (!match) {
    return { nextText: text, mode: null };
  }

  const mode = match[1].toLowerCase() === "note" ? "note" : "chat";
  const consumedLength = match[0].length;
  const remaining = trimmedLeading.slice(consumedLength).trimStart();

  return {
    nextText: remaining,
    mode,
  };
}

export function ComposerView({
  state,
  controlsState,
  activityState,
  onDispatchCommand,
}: ComposerViewProps) {
  const layoutMeasurementSignature = [
    state?.isCompactComposer ? "compact" : "regular",
    state?.isNoteModeActive ? "note" : "chat",
    state?.noteModeLabel ?? "",
    state?.noteModeHelperText ?? "",
    state?.preflightStatusMessage ?? "",
    String(state?.activeSkills.length ?? 0),
    String(state?.attachments.length ?? 0),
    controlsState?.availability ?? "unavailable",
    controlsState?.selectedInteractionMode ?? "",
    controlsState?.selectedModelId ?? "",
    controlsState?.selectedReasoningId ?? "",
    String(controlsState?.showsInteractionModeControl !== false),
    String(controlsState?.showsModelControls !== false),
    String(controlsState?.showsReasoningControls !== false),
  ].join("|");

  const [draft, setDraft] = useState(state?.draftText ?? "");
  const [isDropTarget, setIsDropTarget] = useState(false);
  const [isExternalDraftReveal, setIsExternalDraftReveal] = useState(false);
  const composerRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const lastReportedHeightRef = useRef(0);
  // History navigation: -1 means "current draft" (not browsing history).
  const historyIndexRef = useRef(-1);
  const savedDraftRef = useRef("");
  const wasVoiceCapturingRef = useRef(Boolean(activityState?.isVoiceCapturing));
  const pendingVoiceFocusRef = useRef<boolean | "awaiting-draft">(false);
  const selectionBeforeVoiceCaptureRef = useRef<{ start: number; end: number } | null>(null);
  const hadFocusBeforeVoiceCaptureRef = useRef(false);
  const hasLoadedInitialDraftRef = useRef(false);
  const draftRef = useRef(state?.draftText ?? "");
  const lastLocalDraftRef = useRef(state?.draftText ?? "");
  const externalDraftRevealTimeoutRef = useRef<number | null>(null);
  const [slashQuery, setSlashQuery] = useState<ComposerSlashQueryState | null>(null);
  const [selectedSlashIndex, setSelectedSlashIndex] = useState(0);

  const reportComposerHeight = () => {
    const composer = composerRef.current;
    if (!composer) return;

    const nextHeight = Math.ceil(composer.getBoundingClientRect().height);
    if (Math.abs(nextHeight - lastReportedHeightRef.current) < 1) {
      return;
    }

    lastReportedHeightRef.current = nextHeight;

    try {
      window.webkit?.messageHandlers?.composerHeightDidChange?.postMessage(nextHeight);
    } catch {}
  };

  useEffect(() => {
    const nextDraft = state?.draftText ?? "";

    if (!hasLoadedInitialDraftRef.current) {
      hasLoadedInitialDraftRef.current = true;
      draftRef.current = nextDraft;
      lastLocalDraftRef.current = nextDraft;
      setDraft(nextDraft);
      return;
    }

    const previousDraft = draftRef.current;
    const localDraft = lastLocalDraftRef.current;
    const textareaHasFocus = document.activeElement === textareaRef.current;
    const isLikelyLaggingLocalEcho =
      textareaHasFocus &&
      nextDraft.length > 0 &&
      localDraft.length > 0 &&
      nextDraft !== localDraft &&
      (localDraft.startsWith(nextDraft) || nextDraft.startsWith(localDraft));

    if (isLikelyLaggingLocalEcho) {
      return;
    }

    const isExternalReplacement =
      nextDraft !== previousDraft && nextDraft !== localDraft;
    const shouldRevealExternalDraft =
      isExternalReplacement && nextDraft.trim().length > 0;

    draftRef.current = nextDraft;
    setDraft(nextDraft);

    if (!shouldRevealExternalDraft) {
      if (externalDraftRevealTimeoutRef.current !== null) {
        window.clearTimeout(externalDraftRevealTimeoutRef.current);
        externalDraftRevealTimeoutRef.current = null;
      }
      setIsExternalDraftReveal(false);
      return;
    }

    setIsExternalDraftReveal(false);
    window.requestAnimationFrame(() => {
      setIsExternalDraftReveal(true);
    });

    if (externalDraftRevealTimeoutRef.current !== null) {
      window.clearTimeout(externalDraftRevealTimeoutRef.current);
    }

    externalDraftRevealTimeoutRef.current = window.setTimeout(() => {
      setIsExternalDraftReveal(false);
      externalDraftRevealTimeoutRef.current = null;
    }, 560);
  }, [state?.draftText]);

  useEffect(() => {
    return () => {
      if (externalDraftRevealTimeoutRef.current !== null) {
        window.clearTimeout(externalDraftRevealTimeoutRef.current);
      }
    };
  }, []);

  const refreshSlashQuery = (nextDraft?: string) => {
    const textarea = textareaRef.current;
    const text = nextDraft ?? draftRef.current;
    const selectionStart = textarea?.selectionStart ?? text.length;
    const selectionEnd = textarea?.selectionEnd ?? text.length;
    const nextQuery = detectComposerSlashQuery(text, selectionStart, selectionEnd);
    setSlashQuery(nextQuery);
    if (!nextQuery) {
      setSelectedSlashIndex(0);
    }
  };

  const matchingSlashCommands = useMemo(() => {
    if (!slashQuery) {
      return COMPOSER_SLASH_COMMANDS;
    }
    const query = slashQuery.query.trim().toLowerCase();
    if (!query) {
      return COMPOSER_SLASH_COMMANDS;
    }
    return COMPOSER_SLASH_COMMANDS.filter((command) => matchesSlashCommand(command, query));
  }, [slashQuery]);

  const groupedSlashCommands = useMemo(
    () => groupSlashCommands(matchingSlashCommands),
    [matchingSlashCommands]
  );

  const visibleSlashCommands = useMemo(
    () => groupedSlashCommands.flatMap((group) => group.commands),
    [groupedSlashCommands]
  );

  useEffect(() => {
    refreshSlashQuery();
  }, [draft]);

  useEffect(() => {
    if (selectedSlashIndex >= visibleSlashCommands.length) {
      setSelectedSlashIndex(visibleSlashCommands.length > 0 ? visibleSlashCommands.length - 1 : 0);
    }
  }, [selectedSlashIndex, visibleSlashCommands.length]);

  useEffect(() => {
    const wasVoiceCapturing = wasVoiceCapturingRef.current;
    const isVoiceCapturing = Boolean(activityState?.isVoiceCapturing);
    const hasDraftText = Boolean(state?.draftText?.trim());
    const textarea = textareaRef.current;

    if (!wasVoiceCapturing && isVoiceCapturing && textarea) {
      const hadFocus = document.activeElement === textarea;
      hadFocusBeforeVoiceCaptureRef.current = hadFocus;
      selectionBeforeVoiceCaptureRef.current = hadFocus
        ? {
            start: textarea.selectionStart ?? textarea.value.length,
            end: textarea.selectionEnd ?? textarea.value.length,
          }
        : null;
    }

    if (wasVoiceCapturing && !isVoiceCapturing) {
      // Voice capture just ended. If draft text is already present, schedule
      // focus restoration immediately. Otherwise mark that voice recently
      // ended so focus can be restored when the draft text arrives.
      if (hasDraftText) {
        pendingVoiceFocusRef.current = true;
      } else {
        pendingVoiceFocusRef.current = "awaiting-draft";
      }
    }

    // Draft text arrived after voice capture ended — schedule focus now.
    if (
      !isVoiceCapturing &&
      pendingVoiceFocusRef.current === "awaiting-draft" &&
      hasDraftText
    ) {
      pendingVoiceFocusRef.current = true;
    }

    // Perform focus restoration directly when the flag is ready, rather
    // than deferring to a separate useLayoutEffect which would miss the
    // "awaiting-draft" → true transition (no re-render to trigger it).
    if (
      pendingVoiceFocusRef.current === true &&
      state?.isEnabled &&
      !isVoiceCapturing &&
      textarea
    ) {
      pendingVoiceFocusRef.current = false;
      const previousSelection = selectionBeforeVoiceCaptureRef.current;
      const restorePreviousFocus = hadFocusBeforeVoiceCaptureRef.current;
      selectionBeforeVoiceCaptureRef.current = null;
      hadFocusBeforeVoiceCaptureRef.current = false;

      textarea.focus();
      textarea.scrollIntoView({ block: "nearest", behavior: "smooth" });
      const end = textarea.value.length;
      if (!restorePreviousFocus || !previousSelection) {
        textarea.setSelectionRange(end, end);
      } else {
        const start = Math.max(0, Math.min(previousSelection.start, end));
        const selEnd = Math.max(start, Math.min(previousSelection.end, end));
        textarea.setSelectionRange(start, selEnd);
      }
    }

    wasVoiceCapturingRef.current = isVoiceCapturing;
  }, [activityState?.isVoiceCapturing, state?.draftText, state?.isEnabled]);

  useLayoutEffect(() => {
    const textarea = textareaRef.current;
    if (!textarea) return;
    textarea.style.height = "0px";
    textarea.style.height = `${Math.min(textarea.scrollHeight, MAX_TEXTAREA_HEIGHT)}px`;
  }, [draft]);

  useLayoutEffect(() => {
    reportComposerHeight();
  }, [layoutMeasurementSignature, draft]);

  useEffect(() => {
    const composer = composerRef.current;
    if (!composer) return;

    if (typeof ResizeObserver === "undefined") {
      reportComposerHeight();
      return;
    }

    let frame = 0;
    const observer = new ResizeObserver(() => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        reportComposerHeight();
      });
    });

    observer.observe(composer);
    const textarea = textareaRef.current;
    if (textarea) {
      observer.observe(textarea);
    }

    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
    };
  }, []);

  if (!state) {
    return (
      <div className="oa-react-composer" ref={composerRef}>
        <div className="oa-react-composer__empty">Loading composer…</div>
      </div>
    );
  }

  const controls = controlsState ?? DEFAULT_COMPOSER_CONTROLS_STATE;
  const activity = activityState ?? DEFAULT_COMPOSER_ACTIVITY_STATE;
  const activeTurnPhase = activity.activeTurnPhase ?? (activity.isBusy ? "acting" : "idle");
  const canCancelActiveTurn = activity.canCancelActiveTurn ?? activity.isBusy;
  const showStopButton = activeTurnPhase !== "idle";
  const stopButtonLabel = activeTurnPhase === "cancelling" ? "Stopping…" : "Stop";
  const hasRuntimeControls =
    controls.showsInteractionModeControl !== false ||
    controls.showsModelControls !== false ||
    controls.showsReasoningControls !== false;
  const shouldShowBusyControlSnapshots =
    hasRuntimeControls && controls.availability === "busy";
  const runtimeStatusLabel =
    controls.availabilityStatusText ||
    fallbackComposerRuntimeStatusLabel(controls.availability, activeTurnPhase);
  const showRuntimeStatus =
    hasRuntimeControls &&
    controls.availability !== "ready" &&
    controls.availability !== "busy";

  const updateDraft = (value: string, { fromHistory = false }: { fromHistory?: boolean } = {}) => {
    if (!fromHistory && historyIndexRef.current !== -1) {
      // User edited recalled text — leave history browsing mode.
      historyIndexRef.current = -1;
      savedDraftRef.current = "";
    }
    draftRef.current = value;
    lastLocalDraftRef.current = value;
    setDraft(value);
    onDispatchCommand("updatePromptDraft", { text: value });
  };

  const setNoteMode = (active: boolean) => {
    onDispatchCommand("setNoteMode", { active });
  };

  const quickActions: ComposerQuickAction[] = [
    {
      id: "upload",
      label: "Upload image or file",
      detail: "Add a picture, file, or folder.",
      symbol: "plus",
    },
    ...(state.canOpenSkills
      ? [
          {
            id: "skills" as const,
            label: "Use skills",
            detail:
              state.activeSkills.length > 0
                ? `${state.activeSkills.length} skill${
                    state.activeSkills.length === 1 ? "" : "s"
                  } already attached.`
                : "Browse skills and attach one to this thread.",
            symbol: "sparkles",
          },
        ]
      : []),
    ...(state.showNoteModeButton
      ? [
          {
            id: "note-mode" as const,
            label: state.isNoteModeActive ? "Turn off Note Mode" : "Turn on Note Mode",
            detail: state.isNoteModeActive
              ? "Go back to normal chat."
              : state.noteModeHelperText || "Keep this chat focused on notes.",
            symbol: "note.text",
            isActive: state.isNoteModeActive,
          },
        ]
      : []),
  ];

  const hasHighlightedQuickAction =
    state.isNoteModeActive || state.activeSkills.length > 0;

  const quickActionsTriggerTitle =
    quickActions.length > 1
      ? "More actions"
      : quickActions[0]?.label ?? "More actions";

  const applySlashCommand = (command: ComposerSlashCommand) => {
    const range = slashQuery;
    if (!range) return;

    const current = draftRef.current;
    const before = current.slice(0, range.replaceFrom);
    const after = current.slice(range.replaceTo);
    const nextDraft = before.endsWith(" ") && after.startsWith(" ")
      ? before + after.slice(1)
      : before + after;

    setNoteMode(command.mode === "note");
    updateDraft(nextDraft);
    setSlashQuery(null);
    setSelectedSlashIndex(0);

    requestAnimationFrame(() => {
      const textarea = textareaRef.current;
      if (!textarea) return;
      const nextCursor = Math.min(range.replaceFrom, nextDraft.length);
      textarea.focus();
      textarea.setSelectionRange(nextCursor, nextCursor);
      refreshSlashQuery(nextDraft);
    });
  };

  const sendPrompt = () => {
    const { nextText, mode } = consumeLeadingSlashModeCommand(draftRef.current);
    if (mode) {
      setNoteMode(mode === "note");
    }

    if (mode && nextText !== draftRef.current) {
      draftRef.current = nextText;
      lastLocalDraftRef.current = nextText;
      setDraft(nextText);
      onDispatchCommand("updatePromptDraft", { text: nextText });
    }

    const text = nextText.trim();
    if (mode && !text) {
      historyIndexRef.current = -1;
      savedDraftRef.current = "";
      setSlashQuery(null);
      setSelectedSlashIndex(0);
      return;
    }

    if (!state.canSend) return;
    if (text) {
      // Avoid consecutive duplicates in history.
      if (!promptHistory.length || promptHistory[promptHistory.length - 1] !== text) {
        promptHistory.push(text);
        if (promptHistory.length > MAX_HISTORY_SIZE) {
          promptHistory.shift();
        }
      }
    }
    historyIndexRef.current = -1;
    savedDraftRef.current = "";
    setSlashQuery(null);
    setSelectedSlashIndex(0);
    onDispatchCommand("sendPrompt");
  };

  const attachFiles = async (files: FileList | File[]) => {
    const normalizedFiles = Array.from(files).filter((file) => file.size > 0 || file.type.length > 0);
    if (!normalizedFiles.length) {
      return false;
    }

    const attachments = await Promise.all(
      normalizedFiles.map(
        (file) =>
          new Promise<{ filename: string; dataUrl: string } | null>((resolve) => {
            const reader = new FileReader();
            reader.onload = () => {
              const dataUrl = typeof reader.result === "string" ? reader.result : null;
              if (!dataUrl) {
                resolve(null);
                return;
              }

              resolve({
                filename: file.name || "attachment",
                dataUrl,
              });
            };
            reader.onerror = () => resolve(null);
            reader.readAsDataURL(file);
          })
      )
    );

    const readyAttachments = attachments.filter(
      (attachment): attachment is { filename: string; dataUrl: string } => attachment !== null
    );

    if (!readyAttachments.length) {
      return false;
    }

    onDispatchCommand("addAttachments", { attachments: readyAttachments });
    return true;
  };

  const hasTransferFiles = (types: readonly string[] | DOMStringList | undefined) => {
    if (!types) return false;
    return Array.from(types).includes("Files");
  };

  return (
    <div
      className={`oa-react-composer${state.isCompactComposer ? " is-compact" : ""}`}
      ref={composerRef}
    >
      {state.activeSkills.length ? (
        <div className="oa-react-composer__chip-row">
          {state.activeSkills.map((skill) => (
            <button
              key={skill.skillName}
              type="button"
              className={`oa-react-composer__chip ${skill.isMissing ? "is-warning" : ""}`}
              onClick={() =>
                onDispatchCommand(
                  skill.isMissing ? "repairMissingSkillBindings" : "detachSkill",
                  skill.isMissing ? undefined : { skillName: skill.skillName }
                )
              }
            >
              <span>{skill.displayName}</span>
              <span className="oa-react-composer__chip-meta">
                {skill.isMissing ? "Repair" : "Remove"}
              </span>
            </button>
          ))}
        </div>
      ) : null}

      {state.attachments.length ? (
        <div className="oa-react-composer__chip-row">
          {state.attachments.map((attachment) => (
            <button
              key={attachment.id}
              type="button"
              className="oa-react-composer__chip"
              onClick={() =>
                onDispatchCommand("removeAttachment", { attachmentId: attachment.id })
              }
            >
              {attachment.kind === "image" && attachment.previewDataUrl ? (
                <img
                  src={attachment.previewDataUrl}
                  alt={attachment.filename}
                  className="oa-react-composer__chip-preview"
                />
              ) : (
                <span className="oa-react-composer__chip-icon" aria-hidden="true">
                  <AppIcon symbol="doc.text" size={14} strokeWidth={2} />
                </span>
              )}
              <span className="oa-react-composer__chip-copy">
                <span className="oa-react-composer__chip-title">{attachment.filename}</span>
                <span className="oa-react-composer__chip-meta">
                  {(attachment.kind === "image" ? "Image" : "File") + " · Remove"}
                </span>
              </span>
            </button>
          ))}
        </div>
      ) : null}

      <div
        className={`oa-react-composer__surface${isDropTarget ? " is-drop-target" : ""}${
          isExternalDraftReveal ? " is-restored-draft" : ""
        }`}
        onDragEnter={(event) => {
          if (!hasTransferFiles(event.dataTransfer?.types)) return;
          event.preventDefault();
          setIsDropTarget(true);
        }}
        onDragOver={(event) => {
          if (!hasTransferFiles(event.dataTransfer?.types)) return;
          event.preventDefault();
          event.dataTransfer.dropEffect = "copy";
          if (!isDropTarget) {
            setIsDropTarget(true);
          }
        }}
        onDragLeave={(event) => {
          if (event.currentTarget.contains(event.relatedTarget as Node | null)) {
            return;
          }
          setIsDropTarget(false);
        }}
        onDrop={(event) => {
          if (!event.dataTransfer?.files?.length) return;
          event.preventDefault();
          setIsDropTarget(false);
          void attachFiles(event.dataTransfer.files);
        }}
      >
        {isExternalDraftReveal ? (
          <div className="oa-react-composer__restore-indicator">Restored draft</div>
        ) : null}

        {state.isNoteModeActive && state.noteModeLabel ? (
          <div className="oa-react-composer__mode-banner">
            <span className="oa-react-composer__mode-label">{state.noteModeLabel}</span>
            {state.noteModeHelperText ? (
              <span className="oa-react-composer__mode-helper">{state.noteModeHelperText}</span>
            ) : null}
          </div>
        ) : null}

        {state.preflightStatusMessage ? (
          <div className="oa-react-composer__preflight-banner">
            <span className="oa-react-composer__preflight-icon" aria-hidden="true">
              <ComposerIcon symbol="exclamationmark.circle" />
            </span>
            <span className="oa-react-composer__preflight-text">
              {state.preflightStatusMessage}
            </span>
          </div>
        ) : null}

        <textarea
          ref={textareaRef}
          className={`oa-react-composer__textarea${activity.isVoiceCapturing ? " is-voice-capturing" : ""}${
            isExternalDraftReveal ? " is-restored-draft" : ""
          }`}
          value={draft}
          disabled={!state.isEnabled && !activity.isVoiceCapturing}
          readOnly={activity.isVoiceCapturing}
          placeholder={state.placeholder}
          onChange={(event) => {
            const value = event.target.value;
            updateDraft(value);
            requestAnimationFrame(() => {
              refreshSlashQuery(value);
            });
          }}
          onPaste={(event) => {
            if (!event.clipboardData) return;
            if (!event.clipboardData.files.length && !hasTransferFiles(event.clipboardData.types)) {
              return;
            }

            const items = Array.from(event.clipboardData.items || []);
            const files = items
              .filter((item) => item.kind === "file")
              .map((item) => item.getAsFile())
              .filter((file): file is File => file !== null);
            const attachmentFiles = files.length ? files : Array.from(event.clipboardData.files);

            if (!attachmentFiles.length) return;

            event.preventDefault();
            void attachFiles(attachmentFiles);
          }}
          onKeyDown={(event) => {
            if (slashQuery && visibleSlashCommands.length > 0) {
              if (event.key === "ArrowDown") {
                event.preventDefault();
                setSelectedSlashIndex((current) =>
                  current >= visibleSlashCommands.length - 1 ? 0 : current + 1
                );
                return;
              }

              if (event.key === "ArrowUp") {
                event.preventDefault();
                setSelectedSlashIndex((current) =>
                  current <= 0 ? visibleSlashCommands.length - 1 : current - 1
                );
                return;
              }

              if (event.key === "Enter" || event.key === "Tab") {
                event.preventDefault();
                applySlashCommand(
                  visibleSlashCommands[selectedSlashIndex] ?? visibleSlashCommands[0]
                );
                return;
              }

              if (event.key === "Escape") {
                event.preventDefault();
                setSlashQuery(null);
                setSelectedSlashIndex(0);
                return;
              }
            }

            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault();
              sendPrompt();
              return;
            }

            // Arrow-up / arrow-down prompt history. Navigate when the cursor is
            // on the first line (for ArrowUp) or the last line (for ArrowDown),
            // regardless of whether the recalled text contains newlines.
            const textarea = textareaRef.current;
            if (textarea && (event.key === "ArrowUp" || event.key === "ArrowDown")) {
              const value = textarea.value;
              const cursorStart = textarea.selectionStart;
              const cursorEnd = textarea.selectionEnd;
              // Cursor is on the first line when there is no newline before it.
              const cursorOnFirstLine =
                cursorStart === cursorEnd && !value.slice(0, cursorStart).includes("\n");
              // Cursor is on the last line when there is no newline after it.
              const cursorOnLastLine =
                cursorStart === cursorEnd && !value.slice(cursorEnd).includes("\n");

              if (event.key === "ArrowUp" && cursorOnFirstLine) {
                if (!promptHistory.length) return;
                event.preventDefault();
                if (historyIndexRef.current === -1) {
                  // Entering history — save current draft.
                  savedDraftRef.current = value;
                  historyIndexRef.current = promptHistory.length - 1;
                } else if (historyIndexRef.current > 0) {
                  historyIndexRef.current -= 1;
                } else {
                  return; // Already at oldest entry.
                }
                updateDraft(promptHistory[historyIndexRef.current], { fromHistory: true });
              } else if (event.key === "ArrowDown" && cursorOnLastLine) {
                if (historyIndexRef.current === -1) return; // Not browsing history.
                event.preventDefault();
                if (historyIndexRef.current < promptHistory.length - 1) {
                  historyIndexRef.current += 1;
                  updateDraft(promptHistory[historyIndexRef.current], { fromHistory: true });
                } else {
                  // Past the newest entry — restore saved draft.
                  historyIndexRef.current = -1;
                  updateDraft(savedDraftRef.current, { fromHistory: true });
                }
              }
            }
          }}
          onClick={() => refreshSlashQuery()}
          onKeyUp={() => refreshSlashQuery()}
          onSelect={() => refreshSlashQuery()}
        />

        {slashQuery ? (
          <div className="oa-react-composer__slash-menu" role="listbox" aria-label="Composer commands">
            {groupedSlashCommands.length ? (
              groupedSlashCommands.map((group) => (
                <div key={group.id} className="oa-react-composer__slash-group">
                  <div className="oa-react-composer__slash-group-title">{group.label}</div>
                  {group.commands.map((command) => {
                    const index = visibleSlashCommands.findIndex((item) => item.id === command.id);
                    const isSelected = index === selectedSlashIndex;
                    return (
                      <button
                        key={command.id}
                        type="button"
                        className={`oa-react-composer__slash-item ${isSelected ? "is-selected" : ""}`}
                        onMouseEnter={() => setSelectedSlashIndex(index)}
                        onMouseDown={(event) => {
                          event.preventDefault();
                          applySlashCommand(command);
                        }}
                      >
                        <span className="oa-react-composer__slash-item-title">{command.label}</span>
                        <span className="oa-react-composer__slash-item-subtitle">
                          {command.subtitle}
                        </span>
                      </button>
                    );
                  })}
                </div>
              ))
            ) : (
              <div className="oa-react-composer__slash-empty">No commands match that search.</div>
            )}
          </div>
        ) : null}

        <div className="oa-react-composer__toolbar">
          <div className="oa-react-composer__toolbar-left">
            <div className="oa-react-composer__quick-actions">
              <button
                type="button"
                className={`oa-react-composer__icon-button oa-react-composer__quick-actions-trigger ${
                  hasHighlightedQuickAction ? "is-active" : ""
                }`}
                aria-label={quickActionsTriggerTitle}
                aria-haspopup={quickActions.length > 1 ? "menu" : undefined}
                onClick={() => {
                  if (quickActions.length <= 1) {
                    onDispatchCommand("openFilePicker");
                    return;
                  }
                  onDispatchCommand("toggleQuickActionsMenu");
                }}
                title={quickActionsTriggerTitle}
              >
                <span className="oa-react-composer__quick-actions-trigger-main">
                  <ComposerIcon symbol="plus" />
                </span>
              </button>
            </div>

            {showRuntimeStatus ? (
              <ComposerRuntimeStatus
                availability={controls.availability}
                label={runtimeStatusLabel}
              />
            ) : null}

            {shouldShowBusyControlSnapshots &&
            controls.showsInteractionModeControl !== false ? (
              <ComposerStaticPill
                label={resolveComposerOptionLabel(
                  controls.interactionModes,
                  controls.selectedInteractionMode
                )}
              />
            ) : null}

            {controls.availability === "ready" && controls.showsInteractionModeControl !== false ? (
              <ComposerSelect
                value={controls.selectedInteractionMode}
                options={controls.interactionModes}
                onChange={(value) => onDispatchCommand("setInteractionMode", { mode: value })}
              />
            ) : null}

            {shouldShowBusyControlSnapshots && controls.showsModelControls !== false ? (
              <ComposerStaticPill
                label={resolveComposerOptionLabel(
                  controls.modelOptions,
                  controls.selectedModelId,
                  controls.modelPlaceholder
                )}
              />
            ) : null}

            {controls.availability === "ready" && controls.showsModelControls !== false ? (
              <ComposerSelect
                value={controls.selectedModelId ?? ""}
                options={controls.modelOptions}
                placeholder={controls.modelPlaceholder}
                opensSetupWhenUnavailable={controls.opensModelSetupWhenUnavailable}
                onChange={(value) => onDispatchCommand("setModel", { modelId: value })}
                onOpenUnavailableSetup={() => onDispatchCommand("openModelSetup")}
              />
            ) : null}

            {shouldShowBusyControlSnapshots &&
            controls.showsReasoningControls !== false ? (
              <ComposerStaticPill
                label={resolveComposerOptionLabel(
                  controls.reasoningOptions,
                  controls.selectedReasoningId
                )}
              />
            ) : null}

            {controls.availability === "ready" && controls.showsReasoningControls !== false ? (
              <ComposerSelect
                value={controls.selectedReasoningId}
                options={controls.reasoningOptions}
                onChange={(value) => onDispatchCommand("setReasoningEffort", { effort: value })}
              />
            ) : null}
          </div>

          <div className="oa-react-composer__toolbar-right">
            {showStopButton ? (
              <button
                type="button"
                className="oa-react-composer__action oa-react-composer__action--danger"
                disabled={!canCancelActiveTurn}
                onClick={() => onDispatchCommand("cancelActiveTurn")}
              >
                {stopButtonLabel}
              </button>
            ) : (
              <>
                {activity.showStopVoicePlayback ? (
                  <button
                    type="button"
                    className="oa-react-composer__icon-button"
                    onClick={() => onDispatchCommand("stopVoicePlayback")}
                    title="Stop assistant speech"
                  >
                    <ComposerIcon symbol="speaker.slash.fill" />
                  </button>
                ) : null}

                {activity.canUseVoiceInput ? (
                  <button
                    type="button"
                    className={`oa-react-composer__icon-button ${
                      activity.isVoiceCapturing ? "is-active" : ""
                    }`}
                    onClick={() =>
                      onDispatchCommand(
                        activity.isVoiceCapturing ? "stopVoiceCapture" : "startVoiceCapture"
                      )
                    }
                    title={activity.isVoiceCapturing ? "Listening" : "Voice input"}
                  >
                    <ComposerIcon symbol="mic.fill" />
                  </button>
                ) : null}

                <button
                  type="button"
                  className={`oa-react-composer__send ${state.canSend ? "is-enabled" : ""}`}
                  onClick={sendPrompt}
                  disabled={!state.canSend}
                  title="Send message"
                >
                  <ComposerIcon symbol="arrow.up" />
                </button>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

function fallbackComposerRuntimeStatusLabel(
  availability: AssistantRuntimeControlsAvailability,
  activeTurnPhase?: string
) {
  switch (availability) {
    case "ready":
      return "";
    case "busy":
      return activeTurnPhase === "needsInput" ? "Waiting for input..." : "Responding...";
    case "loadingModels":
      return "Loading models...";
    case "switchingProvider":
      return "Starting provider...";
    case "unavailable":
      return "Runtime unavailable";
  }
}

function ComposerRuntimeStatus({
  availability,
  label,
}: {
  availability: AssistantRuntimeControlsAvailability;
  label: string;
}) {
  if (!label) {
    return null;
  }

  return (
    <div className={`oa-react-composer__runtime-status is-${availability}`}>
      <span className="oa-react-composer__runtime-status-dot" aria-hidden="true" />
      <span className="oa-react-composer__runtime-status-label">{label}</span>
    </div>
  );
}

function ComposerStaticPill({
  label,
}: {
  label: string;
}) {
  const displayLabel = formatComposerLabel(label);
  const contentWidth = Math.max(6.2, Math.min(18, displayLabel.length + 2.6));
  const style = {
    "--oa-composer-select-width": `${contentWidth}ch`,
  } as CSSProperties;

  return (
    <div className="oa-react-composer__static-pill" style={style} title={displayLabel}>
      <span>{displayLabel}</span>
    </div>
  );
}

function resolveComposerOptionLabel(
  options: { id: string; label: string }[],
  value?: string,
  fallback = ""
) {
  if (value) {
    const selected = options.find((option) => option.id === value)?.label;
    if (selected) {
      return selected;
    }
  }
  return fallback;
}

function ComposerSelect({
  value,
  options,
  placeholder,
  opensSetupWhenUnavailable,
  onChange,
  onOpenUnavailableSetup,
}: {
  value: string;
  options: { id: string; label: string }[];
  placeholder?: string;
  opensSetupWhenUnavailable?: boolean;
  onChange: (value: string) => void;
  onOpenUnavailableSetup?: () => void;
}) {
  const selectedLabel =
    options.find((option) => option.id === value)?.label ?? placeholder ?? "";
  const displayLabel = formatComposerLabel(selectedLabel);
  const contentWidth = Math.max(6.2, Math.min(18, displayLabel.length + 3.2));
  const style = {
    "--oa-composer-select-width": `${contentWidth}ch`,
  } as CSSProperties;

  if (opensSetupWhenUnavailable) {
    return (
      <button
        type="button"
        className="oa-react-composer__select-button"
        style={style}
        onClick={() => onOpenUnavailableSetup?.()}
        title={displayLabel}
      >
        <span>{displayLabel}</span>
        <ComposerIcon symbol="chevron.down" />
      </button>
    );
  }

  return (
    <label className="oa-react-composer__select-wrap" style={style}>
      <select value={value} onChange={(event) => onChange(event.target.value)}>
        {placeholder ? <option value="">{formatComposerLabel(placeholder)}</option> : null}
        {options.map((option) => (
          <option key={option.id} value={option.id}>
            {formatComposerLabel(option.label)}
          </option>
        ))}
      </select>
      <ComposerIcon symbol="chevron.down" />
    </label>
  );
}

function formatComposerLabel(label: string) {
  return label.replace(/^gpt/i, "GPT");
}

function ComposerIcon({ symbol }: { symbol: string }) {
  return (
    <AppIcon
      symbol={symbol}
      className="oa-react-composer__icon-svg"
      strokeWidth={1.9}
    />
  );
}
