import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const { shouldSuppressLiveVoiceHUD } = await import(
  path.toNamespacedPath(path.resolve("dist-electron/voiceHUDVisibility.js"))
);

assert.equal(shouldSuppressLiveVoiceHUD({
  liveVoice: true,
  rendererRequestedSuppression: false,
  appActive: true,
  visibleOpenAssistSurface: true
}), true, "The outside orb must hide while the user can see OpenAssist.");

assert.equal(shouldSuppressLiveVoiceHUD({
  liveVoice: true,
  rendererRequestedSuppression: false,
  appActive: true,
  visibleOpenAssistSurface: true
}), true, "Settings and other visible OpenAssist surfaces must suppress the outside orb.");

assert.equal(shouldSuppressLiveVoiceHUD({
  liveVoice: true,
  rendererRequestedSuppression: true,
  appActive: false,
  visibleOpenAssistSurface: true
}), false, "A stale renderer focus hint must not hide the orb after switching to another app.");

assert.equal(shouldSuppressLiveVoiceHUD({
  liveVoice: true,
  rendererRequestedSuppression: false,
  appActive: false,
  visibleOpenAssistSurface: false
}), false, "The outside orb must stay visible while OpenAssist is hidden.");

assert.equal(shouldSuppressLiveVoiceHUD({
  liveVoice: false,
  rendererRequestedSuppression: true,
  appActive: false,
  visibleOpenAssistSurface: false
}), true, "Non-live HUD messages may still honor an explicit renderer suppression request.");

const main = fs.readFileSync(path.resolve("electron/main.ts"), "utf8");
assert.match(main, /isVisibleUserWindow\(settingsWindow\)/, "Settings must count as a visible OpenAssist surface.");
assert.match(main, /BrowserWindow\.getFocusedWindow\(\)/, "Live HUD visibility must use Electron's native focused-window state.");
assert.match(main, /browser-window-focus[\s\S]*?scheduleLiveVoiceHUDVisibilitySync/, "Window focus must reconcile the outside orb.");
assert.match(main, /browser-window-blur[\s\S]*?scheduleLiveVoiceHUDVisibilitySync/, "Leaving OpenAssist must reconcile the outside orb.");
assert.match(
  main,
  /senderWindow !== mainWindow[\s\S]*?liveVoiceHUDSessionActive\(\)[\s\S]*?!isLiveVoiceHUDStatus\(normalizedPayload\.status\)/,
  "Settings and other auxiliary renderers must not hide an active Live Voice HUD."
);
assert.match(
  main,
  /voiceHUDLiveHideTimer && isLiveVoiceHUDStatus\(payload\.status\)/,
  "Every valid live payload must cancel a pending hide timer."
);

console.log("Live Voice HUD visibility checks passed.");
