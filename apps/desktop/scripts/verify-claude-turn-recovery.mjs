import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const bridge = fs.readFileSync(path.resolve("electron/openassistBridge.ts"), "utf8");

// Quit must abort in-flight provider runs (the SDK's own exit hook only
// covers clean exits; orphaned claude children keep working invisibly).
assert.ok(
  /app\.on\("will-quit", \(\) => \{[\s\S]{0,400}terminateProcess/.test(bridge),
  "will-quit must terminate active provider runs"
);

// Every SDK turn must be recorded in the on-disk ledger and cleared when the
// turn settles — entries left at startup are how a restart knows a turn died.
assert.ok(bridge.includes("registerClaudeTurnInLedger(turnLedgerKey"), "SDK turns must register in the ledger");
assert.ok(
  /\.finally\(\(\) => \{\s*clearClaudeTurnFromLedger\(turnLedgerKey\);\s*\}\)/.test(bridge),
  "SDK turns must clear the ledger in a finally block (success, failure, and stop)"
);

// Startup recovery: sweep orphans (PPID 1 + ledger cwd match only) and leave
// a visible note in the interrupted thread.
assert.ok(bridge.includes("recoverInterruptedClaudeTurns()"), "startup must run interrupted-turn recovery");
assert.ok(bridge.includes('ppid !== "1"'), "orphan sweep must only match parent-lost processes");
assert.ok(bridge.includes("cwds.has(cwd)"), "orphan sweep must only match ledger working directories");
assert.ok(bridge.includes("appendInterruptedTurnNotice"), "interrupted threads must get a visible notice");

console.log("verify:claude-turn-recovery passed");
