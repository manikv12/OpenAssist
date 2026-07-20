import { useState, useRef, useEffect } from "react";
import type { RuntimePanelState } from "../types";

interface Props {
  panel: RuntimePanelState | null;
  onSelectBackend: (backendID: string) => void;
  onOpenSettings: () => void;
}

export function RuntimePanel({ panel, onSelectBackend, onOpenSettings }: Props) {
  const [open, setOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    if (open) {
      document.addEventListener("mousedown", handleClickOutside);
      return () => document.removeEventListener("mousedown", handleClickOutside);
    }
  }, [open]);

  if (!panel) {
    return null;
  }

  const selected = panel.backends.find((b) => b.isSelected);
  const hasSetupAction = typeof panel.setupButtonTitle === "string" && panel.setupButtonTitle.length > 0;

  return (
    <section className={`runtime-panel runtime-panel--${panel.tone}`}>
      <div className="runtime-panel__header">
        <div className="runtime-panel__title">
          <span className="runtime-panel__dot" aria-hidden="true" />
          <span>Runtime</span>
        </div>
        <div className="runtime-dropdown" ref={dropdownRef}>
          <button
            type="button"
            className="runtime-dropdown__trigger"
            onClick={() => setOpen((v) => !v)}
            aria-haspopup="listbox"
            aria-expanded={open}
          >
            <span className="runtime-dropdown__dot" />
            <span>{selected?.label ?? "Select"}</span>
            <svg className="runtime-dropdown__chevron" width="10" height="6" viewBox="0 0 10 6" fill="none" aria-hidden="true">
              <path d="M1 1l4 4 4-4" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </button>
          {open && (
            <ul className="runtime-dropdown__menu" role="listbox">
              {panel.backends.map((backend) => (
                <li
                  key={backend.id}
                  role="option"
                  aria-selected={backend.isSelected}
                  className={[
                    "runtime-dropdown__item",
                    backend.isSelected ? "is-selected" : "",
                    backend.isDisabled ? "is-disabled" : "",
                  ].filter(Boolean).join(" ")}
                  onClick={() => {
                    if (!backend.isDisabled) {
                      onSelectBackend(backend.id);
                      setOpen(false);
                    }
                  }}
                >
                  <span className="runtime-dropdown__item-dot" />
                  {backend.label}
                </li>
              ))}
            </ul>
          )}
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
