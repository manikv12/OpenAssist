export type LiveVoiceHUDVisibilityInput = {
  liveVoice: boolean;
  rendererRequestedSuppression: boolean;
  appActive: boolean;
  visibleOpenAssistSurface: boolean;
};

/**
 * The main process is the single authority for Live Voice HUD visibility.
 * Renderer focus/visibility events are only hints and can flap during macOS
 * activation, Settings navigation, Spaces changes, and HUD presentation.
 */
export function shouldSuppressLiveVoiceHUD(input: LiveVoiceHUDVisibilityInput) {
  if (!input.liveVoice) return input.rendererRequestedSuppression;
  return input.appActive && input.visibleOpenAssistSurface;
}

