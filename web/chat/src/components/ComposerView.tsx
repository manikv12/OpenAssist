import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from "react";
import type { AssistantComposerState } from "../types";
import { AppIcon } from "./AppIcon";

interface ComposerViewProps {
  state: AssistantComposerState | null;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}

const MAX_TEXTAREA_HEIGHT = 132;
const MAX_HISTORY_SIZE = 50;

// Persistent prompt history shared across re-renders.
const promptHistory: string[] = [];

export function ComposerView({ state, onDispatchCommand }: ComposerViewProps) {
  const [draft, setDraft] = useState(state?.draftText ?? "");
  const [isDropTarget, setIsDropTarget] = useState(false);
  const [isExternalDraftReveal, setIsExternalDraftReveal] = useState(false);
  const composerRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const lastReportedHeightRef = useRef(0);
  // History navigation: -1 means "current draft" (not browsing history).
  const historyIndexRef = useRef(-1);
  const savedDraftRef = useRef("");
  const wasVoiceCapturingRef = useRef(Boolean(state?.isVoiceCapturing));
  const pendingVoiceFocusRef = useRef<boolean | "awaiting-draft">(false);
  const selectionBeforeVoiceCaptureRef = useRef<{ start: number; end: number } | null>(null);
  const hadFocusBeforeVoiceCaptureRef = useRef(false);
  const hasLoadedInitialDraftRef = useRef(false);
  const draftRef = useRef(state?.draftText ?? "");
  const lastLocalDraftRef = useRef(state?.draftText ?? "");
  const externalDraftRevealTimeoutRef = useRef<number | null>(null);

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
    const isExternalReplacement =
      nextDraft !== previousDraft && nextDraft !== lastLocalDraftRef.current;
    const shouldRevealExternalDraft = isExternalReplacement && nextDraft.length > 0;

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

  useEffect(() => {
    const wasVoiceCapturing = wasVoiceCapturingRef.current;
    const isVoiceCapturing = Boolean(state?.isVoiceCapturing);
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
  }, [state?.draftText, state?.isVoiceCapturing, state?.isEnabled]);

  useLayoutEffect(() => {
    const textarea = textareaRef.current;
    if (!textarea) return;
    textarea.style.height = "0px";
    textarea.style.height = `${Math.min(textarea.scrollHeight, MAX_TEXTAREA_HEIGHT)}px`;
  }, [draft]);

  useLayoutEffect(() => {
    reportComposerHeight();
  }, [draft, state]);

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
  }, [state]);

  if (!state) {
    return (
      <div className="oa-react-composer" ref={composerRef}>
        <div className="oa-react-composer__empty">Loading composer…</div>
      </div>
    );
  }

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

  const sendPrompt = () => {
    if (!state.canSend) return;
    const text = draft.trim();
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
    <div className="oa-react-composer" ref={composerRef}>
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

        <textarea
          ref={textareaRef}
          className={`oa-react-composer__textarea${state.isVoiceCapturing ? " is-voice-capturing" : ""}${
            isExternalDraftReveal ? " is-restored-draft" : ""
          }`}
          value={draft}
          disabled={!state.isEnabled && !state.isVoiceCapturing}
          readOnly={state.isVoiceCapturing}
          placeholder={state.placeholder}
          onChange={(event) => updateDraft(event.target.value)}
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
        />

        <div className="oa-react-composer__toolbar">
          <div className="oa-react-composer__toolbar-left">
            <button
              type="button"
              className="oa-react-composer__icon-button"
              onClick={() => onDispatchCommand("openFilePicker")}
              title="Attach file"
            >
              <ComposerIcon symbol="plus" />
            </button>

            {state.canOpenSkills ? (
              <button
                type="button"
                className="oa-react-composer__icon-button"
                onClick={() => onDispatchCommand("openSkillsPane")}
                title="Open skills"
              >
                <ComposerIcon symbol="sparkles" />
              </button>
            ) : null}

            <ComposerSelect
              value={state.selectedInteractionMode}
              options={state.interactionModes}
              onChange={(value) => onDispatchCommand("setInteractionMode", { mode: value })}
            />

            <ComposerSelect
              value={state.selectedModelId ?? ""}
              options={state.modelOptions}
              placeholder="Select model"
              onChange={(value) => onDispatchCommand("setModel", { modelId: value })}
            />

            <ComposerSelect
              value={state.selectedReasoningId}
              options={state.reasoningOptions}
              onChange={(value) => onDispatchCommand("setReasoningEffort", { effort: value })}
            />
          </div>

          <div className="oa-react-composer__toolbar-right">
            {state.isBusy ? (
              <button
                type="button"
                className="oa-react-composer__action oa-react-composer__action--danger"
                onClick={() => onDispatchCommand("cancelActiveTurn")}
              >
                Stop
              </button>
            ) : (
              <>
                {state.showStopVoicePlayback ? (
                  <button
                    type="button"
                    className="oa-react-composer__icon-button"
                    onClick={() => onDispatchCommand("stopVoicePlayback")}
                    title="Stop assistant speech"
                  >
                    <ComposerIcon symbol="speaker.slash.fill" />
                  </button>
                ) : null}

                {state.canUseVoiceInput ? (
                  <button
                    type="button"
                    className={`oa-react-composer__icon-button ${
                      state.isVoiceCapturing ? "is-active" : ""
                    }`}
                    onClick={() =>
                      onDispatchCommand(
                        state.isVoiceCapturing ? "stopVoiceCapture" : "startVoiceCapture"
                      )
                    }
                    title={state.isVoiceCapturing ? "Listening" : "Voice input"}
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

function ComposerSelect({
  value,
  options,
  placeholder,
  onChange,
}: {
  value: string;
  options: { id: string; label: string }[];
  placeholder?: string;
  onChange: (value: string) => void;
}) {
  const selectedLabel =
    options.find((option) => option.id === value)?.label ?? placeholder ?? "";
  const displayLabel = formatComposerLabel(selectedLabel);
  const contentWidth = Math.max(6.2, Math.min(18, displayLabel.length + 3.2));
  const style = {
    "--oa-composer-select-width": `${contentWidth}ch`,
  } as CSSProperties;

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
