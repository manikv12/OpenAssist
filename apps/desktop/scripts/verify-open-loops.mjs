import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const bridge = await readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");
const app = await readFile(new URL("../src/App.tsx", import.meta.url), "utf8");

// Legacy ledgers remain readable, but worker failures must never create or
// mutate a note behind the user's back.
assert.match(bridge, /openLoopsLedgerListTitle = "Assistant"/);
assert.match(bridge, /openLoopsLedgerNoteTitle = "Open Loops"/);
assert.doesNotMatch(bridge, /function ensureOpenLoopsLedger/);
assert.doesNotMatch(bridge, /function appendOpenLoopEntry/);
assert.doesNotMatch(bridge, /open loop recorded state=/);
assert.match(bridge, /oa-thread:\/\/open\?id=/);

// Completed turns persist only in the Voice Log / Agent Work history.
assert.doesNotMatch(bridge, /taskState === "failed"[\s\S]{0,300}?appendOpenLoopEntry/);
assert.match(bridge, /onCompletedTurn: async \(turn\) => \{[\s\S]{0,600}?persistCompletedTurn\(/);

// Daily digest surfaces unchecked ledger lines read-only (never as leftovers,
// which the apply path treats as planner itemIDs).
assert.match(bridge, /openLoops: listOpenLoopEntries\(\)/);
assert.match(bridge, /function listOpenLoopEntries[\s\S]{0,600}?markdownSection\(note\.markdown, "Open"\)/);

// Renderer: oa-thread:// links open the thread via the existing selectThread
// primitive, in both markdown link interceptors.
assert.match(app, /function parseInternalThreadHref/);
assert.match(app, /requestOpenThreadLink\(threadLinkID\)/);
assert.match(app, /OPEN_THREAD_LINK_EVENT, onThreadLink/);
assert.match(app, /Unresolved agent tasks/);

console.log("Open Loops compatibility checks passed.");
