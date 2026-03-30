import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from "react";
import type { AssistantComposerState } from "../types";
import { AppIcon } from "./AppIcon";

interface ComposerViewProps {
  state: AssistantComposerState | null;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}

const MAX_TEXTAREA_HEIGHT = 132;

export function ComposerView({ state, onDispatchCommand }: ComposerViewProps) {
  const [draft, setDraft] = useState(state?.draftText ?? "");
  const [isDropTarget, setIsDropTarget] = useState(false);
  const composerRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const lastReportedHeightRef = useRef(0);
  const wasVoiceCapturingRef = useRef(Boolean(state?.isVoiceCapturing));
  const pendingVoiceFocusRef = useRef(false);

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
    setDraft(state?.draftText ?? "");
  }, [state?.draftText]);

  useEffect(() => {
    const wasVoiceCapturing = wasVoiceCapturingRef.current;
    const isVoiceCapturing = Boolean(state?.isVoiceCapturing);
    const hasDraftText = Boolean(state?.draftText?.trim());

    if (wasVoiceCapturing && !isVoiceCapturing && hasDraftText) {
      pendingVoiceFocusRef.current = true;
    }

    wasVoiceCapturingRef.current = isVoiceCapturing;
  }, [state?.draftText, state?.isVoiceCapturing]);

  useEffect(() => {
    if (!pendingVoiceFocusRef.current || !state?.isEnabled || state.isVoiceCapturing) {
      return;
    }

    const textarea = textareaRef.current;
    if (!textarea) return;

    pendingVoiceFocusRef.current = false;

    const frame = requestAnimationFrame(() => {
      textarea.focus();
      const end = textarea.value.length;
      textarea.setSelectionRange(end, end);
    });

    return () => cancelAnimationFrame(frame);
  }, [state?.draftText, state?.isEnabled, state?.isVoiceCapturing]);

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

  const updateDraft = (value: string) => {
    setDraft(value);
    onDispatchCommand("updatePromptDraft", { text: value });
  };

  const sendPrompt = () => {
    if (!state.canSend) return;
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
        className={`oa-react-composer__surface${isDropTarget ? " is-drop-target" : ""}`}
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
        <textarea
          ref={textareaRef}
          className={`oa-react-composer__textarea${state.isVoiceCapturing ? " is-voice-capturing" : ""}`}
          value={draft}
          disabled={!state.isEnabled}
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
