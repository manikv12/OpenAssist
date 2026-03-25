import type { RuntimePanelState } from "../types";

interface Props {
  panel: RuntimePanelState | null;
  onSelectBackend: (backendID: string) => void;
  onOpenSettings: () => void;
}

export function RuntimePanel({ panel, onSelectBackend, onOpenSettings }: Props) {
  if (!panel) {
    return null;
  }

  const hasSetupAction = typeof panel.setupButtonTitle === "string" && panel.setupButtonTitle.length > 0;

  return (
    <section className={`runtime-panel runtime-panel--${panel.tone}`}>
      <div className="runtime-panel__header">
        <div className="runtime-panel__title">
          <span className="runtime-panel__dot" aria-hidden="true" />
          <span>Runtime</span>
        </div>
        <div className="runtime-panel__chips" role="group" aria-label="Provider">
          {panel.backends.map((backend) => (
            <button
              key={backend.id}
              type="button"
              className={[
                "runtime-chip",
                backend.isSelected ? "is-selected" : "",
              ]
                .filter(Boolean)
                .join(" ")}
              disabled={backend.isDisabled}
              aria-pressed={backend.isSelected}
              onClick={() => onSelectBackend(backend.id)}
            >
              {backend.label}
            </button>
          ))}
        </div>
      </div>

      {panel.backendHelpText && (
        <p className="runtime-panel__helper">{panel.backendHelpText}</p>
      )}

      <div className="runtime-panel__status">
        <div className="runtime-panel__status-copy">
          <div className="runtime-panel__summary">{panel.statusSummary}</div>
          {panel.statusDetail && (
            <div className="runtime-panel__detail">{panel.statusDetail}</div>
          )}
        </div>

        {panel.accountSummary && (
          <div className="runtime-panel__account">{panel.accountSummary}</div>
        )}
      </div>

      {hasSetupAction && (
        <button
          type="button"
          className="runtime-panel__setup"
          onClick={onOpenSettings}
        >
          {panel.setupButtonTitle}
        </button>
      )}
    </section>
  );
}
