import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

// Guards for the chat-engine fixes (2026-07-02):
// 1. A message sent to an existing thread must never be silently moved to a
//    brand-new thread (routing).
// 2. Temporary threads stay temporary through turns, are destroyed on leave,
//    and leftovers are purged at startup (persistence).
// 3. A finished turn replaces its optimistic messages IN PLACE, so responses
//    stay next to the message that produced them (ordering).
// 4. Chat components are memoized so a streaming token does not re-render the
//    entire thread (performance).
// 5. A brand-new chat appears in the sidebar while its first turn is still
//    running: the pending run adopts the real thread id from provider events
//    and inserts an optimistic sidebar entry (visibility).

const bridge = fs.readFileSync(path.resolve("electron/openassistBridge.ts"), "utf8");
const main = fs.readFileSync(path.resolve("electron/main.ts"), "utf8");
const app = fs.readFileSync(path.resolve("src/App.tsx"), "utf8");

// --- Routing ---
assert.match(
  bridge,
  /Recreated missing session record for requested thread=/,
  "A requested thread with a missing session record must be recreated under the SAME id, not moved to a new thread."
);
assert.doesNotMatch(
  bridge,
  /const \{ projectID \} = projectContextForThread\(openAssistThreadID\);\s*\n\s*session = createOpenAssistThread\(projectID, true\)\.session;\s*\n\s*openAssistThreadID = session\.id;/,
  "sendCodexMessage must not replace a requested thread id with a freshly created one."
);
assert.match(
  app,
  /stayOnCurrentThreadID/,
  "refreshAppState must keep the user's current thread instead of yanking selection to the top of the list."
);

// --- Temporary threads ---
assert.doesNotMatch(
  bridge,
  /Promoted temporary thread before starting provider turn/,
  "Provider turns must not auto-promote temporary threads to permanent."
);
assert.match(
  bridge,
  /export function purgeTemporaryThreadsOnStartup\(/,
  "Leftover temporary threads must be purged at startup."
);
assert.match(
  main,
  /purgeTemporaryThreadsOnStartup\(\)/,
  "main.ts must call the startup temporary-thread purge."
);
const destroyBlock = bridge.slice(
  bridge.indexOf("export function destroyTemporaryThread"),
  bridge.indexOf("export function purgeTemporaryThreadsOnStartup")
);
assert.doesNotMatch(
  destroyBlock,
  /promoteTemporarySession/,
  "destroyTemporaryThread must delete temporary threads, not promote/keep them."
);

// --- Ordering ---
assert.match(
  app,
  /const replaceCurrentTurnInPlace = /,
  "Turn completion must replace optimistic messages in place."
);
assert.ok(
  (app.match(/replaceCurrentTurnInPlace\(currentMessages/g) || []).length >= 2,
  "Both the success and error merge paths must use in-place replacement."
);
assert.match(
  app,
  /id: `local-user-\$\{turnStartedAt\}`,\s*\n\s*role: "user",[\s\S]{0,220}createdAt: turnStartedAt/,
  "The optimistic user message must carry a createdAt timestamp."
);
assert.ok(
  (bridge.match(/user: \{ id: `user-\$\{Date\.now\(\)\}`, role: "user", text: visibleUserText, attachments: imageAttachments, createdAt: Date\.now\(\) \}/g) || []).length >= 4,
  "Bridge result user messages must carry createdAt."
);

// --- Performance ---
for (const name of ["MessageBubble", "DelegatedTaskCard", "ThinkingGroup", "WorkActivityGroup", "CompletedTurnGroup"]) {
  assert.match(
    app,
    new RegExp(`const ${name} = memo\\(${name}Base`),
    `${name} must be memoized so streaming tokens do not re-render the whole thread.`
  );
}
assert.match(
  app,
  /scrollStateFrameRef\.current = window\.requestAnimationFrame\(\(\) => \{\s*\n\s*scrollStateFrameRef\.current = null;\s*\n\s*const element = chatScrollRef\.current;/,
  "The chat scroll handler must coalesce its layout reads into one animation frame."
);
assert.doesNotMatch(
  app,
  /const layoutProps = embedded \? \{\} : \{ layout: true as const \};/,
  "Chat rows must not use Framer Motion layout animations (they re-measure every sibling per token)."
);

// --- New-thread sidebar visibility ---
assert.match(
  app,
  /const adoptRealRunThreadID = \(reportedThreadID\?: string\) => \{/,
  "A pending first-turn run must adopt the real thread id reported by provider events."
);
assert.match(
  app,
  /adoptRealRunThreadID\(event\.threadID\);/,
  "Provider events must feed the real thread id to the pending run so the sidebar entry appears mid-run."
);
assert.match(
  app,
  /const missingRunningThreads = /,
  "refreshAppState must keep optimistic sidebar entries for threads whose first turn is still running."
);
assert.match(
  app,
  /clearActiveThreadRun\(liveRunThreadID, providerRunID\);/,
  "Run cleanup must use the adopted (live) thread id or re-keyed runs leak forever."
);

console.log("Chat engine guards verified.");
