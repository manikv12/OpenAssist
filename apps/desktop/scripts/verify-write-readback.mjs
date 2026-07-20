import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const bridge = await readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");

// Planner mutation results must report the item as re-derived from the freshly
// saved markdown, not the in-memory object the write path constructed.
assert.match(bridge, /function readBackMutatedItem/);

const daily = bridge.match(/function dailyMutationResult[\s\S]*?\n}\n/)?.[0] ?? "";
assert.ok(daily, "dailyMutationResult must exist");
assert.match(daily, /const items = parseDailyItemsFromMarkdown\(day\.id, day\.markdown\);/);
assert.match(daily, /item: readBackMutatedItem\(item, items\)/);

const backlog = bridge.match(/function backlogMutationResult[\s\S]*?\n}\n/)?.[0] ?? "";
assert.ok(backlog, "backlogMutationResult must exist");
assert.match(backlog, /item: readBackMutatedItem\(item, items, scheduledItems\)/, "backlog read-back must also search the scheduled day's items");

// Fallbacks: positional plain: ids fall back to exact-title match; a total miss
// is flagged (readBack:false) instead of silently trusting the in-memory item.
const readBackFn = bridge.match(/function readBackMutatedItem[\s\S]*?\n}\n/)?.[0] ?? "";
assert.match(readBackFn, /candidate\.id === item\.id/);
assert.match(readBackFn, /dailyItemVisibleTitle\(candidate\)/);
assert.match(readBackFn, /readBack: false/);

// Regression: the explicit un-complete path exists and mutation results flow
// through the read-back builder, so checked:false must round-trip from disk.
assert.match(bridge, /explicitlyUnchecked/, "un-complete handling (explicitlyUnchecked) must remain in normalizeDailyItemInput");
assert.match(bridge, /readBack\?: boolean;/, "DailyItem must carry the readBack flag");

console.log("Planner write read-back checks passed.");
