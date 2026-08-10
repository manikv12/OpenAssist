// Verifies the Side Chat feature: pure helpers in dist-electron/sideChatCore.js
// plus source wiring across the bridge, driver, main, preload, renderer, and CSS.
// Run via: npm run verify:side-chat  (compiles electron TS first)
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");
const includes = (source, needle, label) => {
  assert.ok(source.includes(needle), `${label}: expected to find ${JSON.stringify(needle)}`);
};

const {
  sideChatLimits,
  buildSideChatSeedContext,
  buildSideChatSyncContext,
  composeSideChatFirstTurnPrompt,
  composeSideChatSyncPrompt,
  sideChatIdleExpired
} = await import(`file://${path.join(root, "dist-electron", "sideChatCore.js")}`);

// --- buildSideChatSeedContext -------------------------------------------------
{
  const transcript = [];
  for (let index = 0; index < 60; index += 1) {
    transcript.push({ role: index % 2 === 0 ? "user" : "assistant", text: `message ${index} ${"x".repeat(2000)}` });
  }
  const context = buildSideChatSeedContext(transcript);
  const lines = context.split("\n\n");
  assert.ok(lines.length <= sideChatLimits.maxMessages, "seed context respects maxMessages");
  assert.ok(context.length <= sideChatLimits.totalBudgetChars + sideChatLimits.maxCharsPerMessage, "seed context respects total budget");
  for (const line of lines) {
    assert.ok(line.length <= sideChatLimits.maxCharsPerMessage + 12, "per-message cap respected");
  }
  // Newest-biased: the last transcript message must be kept, and order must be
  // chronological (oldest kept first, newest last).
  assert.ok(lines[lines.length - 1].includes("message 59"), "newest message kept last");
  const keptIndexes = lines.map((line) => Number(line.match(/message (\d+)/)?.[1] ?? -1));
  const sorted = [...keptIndexes].sort((a, b) => a - b);
  assert.deepEqual(keptIndexes, sorted, "kept messages are chronological");
}
{
  const context = buildSideChatSeedContext([
    { role: "system", text: "hidden" },
    { role: "user", text: "  " },
    { role: "user", text: "real question" },
    { role: "assistant", text: "real answer" }
  ]);
  assert.ok(!context.includes("hidden"), "non user/assistant roles skipped");
  assert.equal(context, "User: real question\n\nAssistant: real answer");
  assert.equal(buildSideChatSeedContext([]), "", "empty transcript gives empty context");
  assert.equal(buildSideChatSeedContext(undefined), "", "missing transcript gives empty context");
}

// --- composeSideChatFirstTurnPrompt ------------------------------------------
{
  const composed = composeSideChatFirstTurnPrompt("User: hi\n\nAssistant: hello", "What did we decide?");
  includes(composed, "side chat forked from an Open Assist conversation", "compose wrapper");
  includes(composed, "User: hi", "compose context");
  includes(composed, "Current user task:", "compose task label");
  includes(composed, "What did we decide?", "compose prompt");
  includes(composed, "Answer only the Current user task", "compose independence rule");
  includes(composed, "generate an image", "compose direct-output rule");
  assert.equal(composeSideChatFirstTurnPrompt("", "plain"), "plain", "empty context passes prompt through");
  assert.equal(composeSideChatFirstTurnPrompt("   ", "plain"), "plain", "blank context passes prompt through");
}

// --- buildSideChatSyncContext / composeSideChatSyncPrompt --------------------
{
  const transcript = [
    { role: "user", text: "old question" },
    { role: "assistant", text: "old answer" },
    { role: "user", text: "new question" },
    { role: "assistant", text: "new answer" }
  ];
  const synced = buildSideChatSyncContext(transcript, 2);
  assert.equal(synced.context, "User: new question\n\nAssistant: new answer", "sync copies only entries past the watermark");
  assert.equal(synced.nextWatermark, 4, "sync advances watermark to transcript length");
  const upToDate = buildSideChatSyncContext(transcript, 4);
  assert.equal(upToDate.context, "", "no new entries gives empty context");
  assert.equal(upToDate.nextWatermark, 4, "watermark unchanged when up to date");
  const clamped = buildSideChatSyncContext(transcript, 99);
  assert.equal(clamped.context, "", "out-of-range watermark clamps safely");
  const syncPrompt = composeSideChatSyncPrompt("User: new question", "What changed?");
  includes(syncPrompt, "new messages in the main Open Assist chat", "sync prompt wrapper");
  includes(syncPrompt, "Current user task:", "sync prompt task label");
  assert.equal(composeSideChatSyncPrompt("", "plain"), "plain", "empty sync context passes prompt through");
}

// --- sideChatIdleExpired ------------------------------------------------------
{
  const now = Date.now();
  assert.equal(sideChatIdleExpired(now - 29 * 60 * 1000, now), false, "29 minutes is not expired");
  assert.equal(sideChatIdleExpired(now - 31 * 60 * 1000, now), true, "31 minutes is expired");
  assert.equal(sideChatIdleExpired(undefined, now), true, "missing timestamp counts as expired");
  assert.equal(sideChatIdleExpired(now - 2000, now, 1000), true, "custom idle limit honored");
  assert.equal(sideChatIdleExpired(now - 500, now, 1000), false, "custom idle limit not yet reached");
}

// --- Source wiring ------------------------------------------------------------
const bridge = read("electron/openassistBridge.ts");
includes(bridge, 'if (registrySession?.kind === "sideChat") continue;', "bridge loadThreads side-chat filter");
const loadThreadsSlice = bridge.slice(bridge.indexOf("function loadThreads("), bridge.indexOf("function loadThreads(") + 6000);
includes(loadThreadsSlice, "registryByID.get(threadID.toLowerCase())", "filter sits inside loadThreads");
includes(loadThreadsSlice, 'kind === "sideChat"', "filter checks kind inside loadThreads");
includes(bridge, "export async function openSideChat", "bridge openSideChat");
includes(bridge, "export function touchSideChat", "bridge touchSideChat");
includes(bridge, "export function destroySideChat", "bridge destroySideChat");
includes(bridge, "export function setSideChatDestroyedListener", "bridge destroyed listener");
includes(bridge, "A side chat cannot be promoted to a saved chat.", "bridge promote guard");
includes(bridge, "claudeSideChatForkFromSessionID", "bridge fork plumb");
includes(bridge, "forkFromSessionID: options?.forkFromSessionID", "bridge fork passed to driver");
includes(bridge, 'session?.kind === "sideChat"', "bridge providerWorkingDirectory parent redirect");
includes(bridge, "session.sideChatSeeded = true;", "bridge persistCompletedTurn marks seeded");
includes(bridge, "sweepIdleSideChats", "bridge idle sweeper");
includes(bridge, "export function sideChatContextStatus", "bridge context status");
includes(bridge, "export function syncSideChatContext", "bridge context sync");
includes(bridge, "session.sideChatSyncedCount = parentTranscript.length", "bridge seed sets watermark");
includes(bridge, "delete session.sideChatPendingContext", "bridge consumes pending context on send");

const driver = read("electron/claudeAgentDriver.ts");
includes(driver, "forkFromSessionID?: string;", "driver fork input field");
includes(driver, "forkSession: true", "driver forkSession option");

const main = read("electron/main.ts");
includes(main, '"openassist:side-chat-context-status"', "main context-status IPC");
includes(main, '"openassist:sync-side-chat-context"', "main sync IPC");
includes(main, '"openassist:open-side-chat"', "main open IPC");
includes(main, '"openassist:touch-side-chat"', "main touch IPC");
includes(main, '"openassist:destroy-side-chat"', "main destroy IPC");
includes(main, "setSideChatDestroyedListener", "main destroyed broadcast");
const willQuitSlice = main.slice(main.indexOf('app.on("will-quit"'), main.indexOf('app.on("will-quit"') + 900);
includes(willQuitSlice, "purgeTemporaryThreadsOnStartup", "main will-quit purge");

const preload = read("electron/preload.ts");
includes(preload, "openSideChat:", "preload openSideChat");
includes(preload, '"openassist:side-chat-destroyed"', "preload destroyed channel");

const app = read("src/App.tsx");
includes(app, "onSideChatDestroyed", "renderer destroyed subscription");
includes(app, "function SideChatDock", "renderer dock component");
includes(app, "sideChatThreadIDsRef", "renderer side-chat run guards");
includes(app, "askSelectionInSideChat", "renderer ask-selection handler");
includes(app, "chat-selection-popover", "renderer selection popover");
includes(app, "About this selected part of the main chat:", "renderer selection quoted into prompt");
includes(app, "1 selection", "renderer selection chip");
// Side chat renders as a TAB inside the assistant inspector panel (shared with
// Thread Note), not as a separate dock.
includes(app, '"thread-note" | "side-chat" | "session-instructions"', "renderer side-chat panel key");
includes(app, "onSwitchPanel", "renderer inspector tab switching");
includes(app, "inspector-tabs", "renderer inspector tab bar");
includes(app, "sideChatContent", "renderer side chat mounted in inspector");
includes(app, "side-chat-sync-row", "renderer sync bar");
includes(app, "syncSideChatContextNow", "renderer sync handler");
includes(app, "refreshSideChatContextStatus", "renderer sync hint refresh");
assert.ok(!app.includes("side-chat-dock-motion"), "old separate dock removed from renderer");

const css = read("src/styles.css");
includes(css, ".assistant-inspector.thread-note-inspector.side-chat-inspector", "css side-chat inspector variant");
includes(css, ".inspector-tabs", "css inspector tabs");
includes(css, ".chat-selection-popover", "css selection popover");
includes(css, ".side-chat-selection-chip", "css selection chip");
assert.ok(!css.includes(".side-chat-dock-motion"), "old dock css removed");

console.log("verify-side-chat passed.");
