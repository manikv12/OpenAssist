import { cloneElement, createContext, useContext, type ReactElement, type ReactNode } from "react";

const LiveVoiceSettingsLockContext = createContext(false);

export function LiveVoiceSettingsLockProvider({
  locked,
  children
}: {
  locked: boolean;
  children: ReactNode;
}) {
  return (
    <LiveVoiceSettingsLockContext.Provider value={locked}>
      {children}
    </LiveVoiceSettingsLockContext.Provider>
  );
}

export function LiveVoiceSettingsLockControl({
  children
}: {
  children: ReactElement<{ disabled?: boolean }>;
}) {
  const locked = useContext(LiveVoiceSettingsLockContext);
  return cloneElement(children, { disabled: locked || Boolean(children.props.disabled) });
}

export function LiveVoiceSettingsLockNotice() {
  const locked = useContext(LiveVoiceSettingsLockContext);
  if (!locked) return null;
  return <p className="settings-helper-line">Stop Live Voice to change the provider, model, or voice.</p>;
}
