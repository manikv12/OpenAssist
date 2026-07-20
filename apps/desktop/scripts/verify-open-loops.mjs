import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const bridge = await readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");
const app = await readFile(new URL("../src/App.tsx", import.meta.url), "utf8");

// Ledger home: "Open Loops" project note under the "Assistant" planner list,
// created through the internal (approval-free) note APIs.
assert.match(bridge, /openLoopsLedgerListTitle = "Assistant"/);
assert.match(bridge, /openLoopsLedgerNoteTitle = "Open Loops"/);
assert.match(bridge, /function ensureOpenLoopsLedger[\s\S]{0,400}?createPlannerList\(\{ name: openLoopsLedgerListTitle \}\)/);
assert.match(bridge, /resolveCanonicalReferenceNote\(list\.id, openLoopsLedgerNoteTitle\)/);

// Entries are checkable, dated, dedupe-safe, and deep-link to the day log.
assert.match(bridge, /appendReferenceLinesToMarkdown\(note\.markdown, "Open", \[line\]\)/);
assert.match(bridge, /- \[ \] \$\{description\}/);
assert.match(bridge, /buildThreadURL\(entry\.voiceThreadID\)/);
assert.match(bridge, /oa-thread:\/\/open\?id=/);

// Every finished delegated turn passes through onCompletedTurn; unresolved ones
// are recorded before the turn persists.
assert.match(bridge, /turn\.source === "delegated" && \(turn\.taskState === "failed" \|\| turn\.taskState === "cancelled"\)[\s\S]{0,300}?appendOpenLoopEntry/);

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

console.log("Open Loops ledger checks passed.");
