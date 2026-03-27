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
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    setDraft(state?.draftText ?? "");
  }, [state?.draftText]);

  useLayoutEffect(() => {
    const textarea = textareaRef.current;
    if (!textarea) return;
    textarea.style.height = "0px";
    textarea.style.height = `${Math.min(textarea.scrollHeight, MAX_TEXTAREA_HEIGHT)}px`;
  }, [draft]);

  if (!state) {
    return (
      <div className="oa-react-composer">
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

  return (
    <div className="oa-react-composer">
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
              <span>{attachment.filename}</span>
              <span className="oa-react-composer__chip-meta">
                {(attachment.kind === "image" ? "Image" : "File") + " · Remove"}
              </span>
            </button>
          ))}
        </div>
      ) : null}

      <div className="oa-react-composer__surface">
        <textarea
          ref={textareaRef}
          className="oa-react-composer__textarea"
          value={draft}
          disabled={!state.isEnabled}
          placeholder={state.placeholder}
          onChange={(event) => updateDraft(event.target.value)}
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
