import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bridge = fs.readFileSync(path.join(root, "electron/openassistBridge.ts"), "utf8");

assert.match(
  bridge,
  /const titleWasGeneric = isGenericThreadTitle\(session\.title\);/,
  "persistCompletedTurn must remember whether the title was still generic before the prompt-echo title is applied."
);
assert.match(
  bridge,
  /if \(titleWasGeneric\) queueAutoThreadTitle\(threadID, prompt, responseText\);/,
  "The first completed turn must queue AI title generation."
);
assert.match(
  bridge,
  /session\.titleSource = "user";/,
  "A manual rename must stamp titleSource so auto-titling never overwrites it."
);
assert.match(
  bridge,
  /if \(session\.titleSource === "user" \|\| session\.titleSource === "ai"\) return;/,
  "Auto-titling must run at most once and never fight a manual rename."
);
assert.match(
  bridge,
  /if \(!current \|\| current\.titleSource === "user"\) return;[\s\S]{0,200}current\.titleSource = "ai";/,
  "The generated title must re-check for a mid-flight manual rename before saving."
);
assert.match(
  bridge,
  /queueAutoThreadTitle[\s\S]{0,400}session\.kind === "liveVoice" \|\| session\.kind === "sideChat"/,
  "Live Voice day logs and side chats must never be auto-titled."
);
assert.match(
  bridge,
  /Codex thread title request timed out\./,
  "The title request must have its own timeout so a hung request cannot leak."
);

assert.doesNotMatch(
  bridge,
  /Codex thread title request timed out[\s\S]{0,600}effort: "minimal"|effort: "minimal"[\s\S]{0,600}Codex thread title request timed out/,
  "Title generation must not use reasoning effort 'minimal' — Codex models reject it with a 400."
);

assert.match(
  bridge,
  /const sessionTitle = normalizeTitle\(findSession\(threadID\)\?\.title, ""\);\s*const detailTitle = !isGenericThreadTitle\(sessionTitle\) \? sessionTitle : page\.title;/,
  "Thread detail must prefer the registry title (AI/user) over the first-message fallback."
);

const appSource = fs.readFileSync(path.join(root, "src/App.tsx"), "utf8");
assert.match(
  appSource,
  /usableThreadTitle\(appState\.threads\.find\(\(thread\) => thread\.id === selectedThreadID\)\?\.title\)\s*\|\| threadDetail\?\.title/,
  "The chat top bar must prefer the live thread-list title over the cached thread detail."
);

const main = fs.readFileSync(path.join(root, "electron/main.ts"), "utf8");
assert.match(
  main,
  /bridge\.backfillThreadTitlesOnStartup\(\)/,
  "Startup must kick off the old-thread title backfill."
);
assert.match(
  bridge,
  /function updateSessionKeepingTimestamps[\s\S]{0,300}saveSessionRegistry/,
  "The backfill must write sessions without bumping updatedAt (no sidebar reorder)."
);
assert.match(
  bridge,
  /backfillThreadTitlesOnStartup[\s\S]{0,2500}!isGenericThreadTitle\(currentTitle\) && !promptEchoTitles\.has\(currentTitle\)/,
  "The backfill must only retitle prompt-echo titles and leave manual renames alone."
);
assert.match(
  bridge,
  /updateSessionKeepingTimestamps\(\{ \.\.\.current, title, titleSource: "ai" \}\);\s*retitled \+= 1;/,
  "Backfilled titles must be stamped 'ai' and must NOT notify the renderer per item."
);
assert.match(
  bridge,
  /if \(retitled\) \{\s*notifyThreadsChanged\(\);/,
  "The backfill must refresh the renderer exactly once, after the whole batch."
);

console.log("Auto thread title verification passed.");
