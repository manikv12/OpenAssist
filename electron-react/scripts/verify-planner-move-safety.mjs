import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const bridgePath = path.resolve("electron/openassistBridge.ts");
const bridgeText = fs.readFileSync(bridgePath, "utf8");

function functionBody(name) {
  const start = bridgeText.indexOf(`function ${name}`);
  assert.ok(start >= 0, `${name} must exist`);
  const next = bridgeText.indexOf("\nfunction ", start + 1);
  return bridgeText.slice(start, next >= 0 ? next : bridgeText.length);
}

function assertIncludes(text, needle, label) {
  assert.ok(text.includes(needle), `${label} must include: ${needle}`);
}

function assertRegex(pattern, label) {
  assert.ok(pattern.test(bridgeText), `${label} missing`);
}

const appendDay = functionBody("appendMovedDailyItemToDay");
assertIncludes(appendDay, "id: undefined", "moved day append helper");
assertIncludes(appendDay, "order: existingItems.length", "moved day append helper");
assertIncludes(appendDay, "replaceStructuredDailyItem(day.markdown, item)", "moved day append helper");

const appendBacklog = functionBody("appendMovedDailyItemToBacklog");
assertIncludes(appendBacklog, "id: undefined", "moved backlog append helper");
assertIncludes(appendBacklog, "order: existingItems.length", "moved backlog append helper");
assertIncludes(appendBacklog, "replaceStructuredDailyItem(backlog.markdown, item)", "moved backlog append helper");

const updateByText = functionBody("updateDailyItemByText");
assertIncludes(updateByText, "appendMovedDailyItemToDay(item, targetDayID)", "cross-day text move");
assertIncludes(updateByText, "removeStructuredDailyItem(sourceDay.markdown, match.id)", "cross-day text move");
assertIncludes(updateByText, "removePlainDailyItemLine(sourceDay.markdown, match.id)", "cross-day text move");

const moveToBacklog = functionBody("moveDailyItemToBacklog");
assertIncludes(moveToBacklog, "appendMovedDailyItemToBacklog", "move to backlog");
assertIncludes(moveToBacklog, "removePlainDailyItemLine(day.markdown, existing.id)", "move to backlog");
assertIncludes(moveToBacklog, "removeStructuredDailyItem(day.markdown, existing.id)", "move to backlog");

const scheduleBacklog = functionBody("scheduleBacklogItem");
assertIncludes(scheduleBacklog, "appendMovedDailyItemToDay", "schedule backlog item");
assertIncludes(scheduleBacklog, "removePlainDailyItemLine(backlog.markdown, existing.id)", "schedule backlog item");
assertIncludes(scheduleBacklog, "removeStructuredDailyItem(backlog.markdown, existing.id)", "schedule backlog item");

assertRegex(
  /request\.preview\.kind === "planner_move"[\s\S]*?appendMovedDailyItemToDay[\s\S]*?removePlannerTasksByText[\s\S]*?request\.preview\.kind === "planner_backlog_move"/,
  "approved planner move must append to target before removing source"
);

assertRegex(
  /request\.preview\.kind === "planner_backlog_move"[\s\S]*?appendMovedDailyItemToBacklog[\s\S]*?removePlannerTasksByText[\s\S]*?request\.preview\.kind === "daily_item_upsert"/,
  "approved backlog move must append to backlog before removing source"
);

assertRegex(
  /case "move_planner_item":[\s\S]*?appendMovedDailyItemToDay[\s\S]*?deleteDailyItem\(fromDayID, existing\.id\)/,
  "Live voice planner move must append to target then delete source"
);

assertRegex(
  /type === "moveDailyItemToDay"[\s\S]*?moveDailyItemToDay\(dayID, itemID, targetDayID\)/,
  "phone remote planner move must use shared safe move helper"
);

// --- July 2026 hardening: leftovers, wrong targets, structure corruption ---

// plain: line-number ids must never persist into structured blocks.
const mergeFn = functionBody("mergedDuplicateDailyInput");
assertIncludes(mergeFn, 'existing.id.startsWith("plain:") ? undefined : existing.id', "duplicate merge must drop plain ids");
const normalizeFn = functionBody("normalizeDailyItemInput");
assertIncludes(normalizeFn, '!rawID.startsWith("plain:")', "normalize must refuse plain ids");

// Existing category must beat keyword inference on updates.
assertRegex(
  /normalizeDailyArea\(existing\?\.area\)\s*\n\s*\|\| inferDailyArea\(/,
  "existing area must be checked before inferDailyArea"
);

// Count-aware source removal: duplicate titles each get removed.
const removeFn = functionBody("removePlannerTasksByText");
assertIncludes(removeFn, "new Map<string, number>", "source removal must be count-aware");

// Carry-forward: strict dates, no same-day duplication, deduped texts.
assertRegex(
  /request_carry_forward[\s\S]{0,900}resolvePlannerDayIDForWrite\(String\(payload\.fromDayID/,
  "carry-forward must resolve days strictly"
);
assertRegex(
  /fromDayID === targetDayID[\s\S]{0,120}nothing to move/,
  "carry-forward must refuse same-day moves"
);

// Move apply collects EVERY exact-title occurrence and logs shortfalls.
assertRegex(
  /wantedKeys\.has\(dailyItemVisibleTitle\(item\)\.toLowerCase\(\)\)/,
  "planner_move must collect all matching open items"
);
assertRegex(
  /planner_move removed \$\{removed\.length\}\/\$\{removalTexts\.length\}/,
  "planner_move must log incomplete source removal"
);

// Backlog move resolves all entries before mutating anything.
assertRegex(/resolvedBacklogMoves/, "backlog move must resolve entries up front");

// Update/move target day is strict and cannot silently become today.
assertRegex(
  /resolvePlannerDayIDForWrite\(String\(raw\.targetDayID \?\? raw\.newDayID \?\? raw\.moveToDayID \?\? ""\), sourceDayID\)/,
  "updateDailyItemByText must resolve the target day strictly"
);

// Steps inside a task block are not standalone tasks.
const openTasksFn = functionBody("listOpenKnowledgeTasks");
assertIncludes(openTasksFn, "/^[-*]\\s+\\[\\s\\]\\s+(.+?)\\s*$/", "open tasks must match top-level checkboxes only");

// A block with a lost closer must stop at the next opener (no swallowing).
assertRegex(
  /dailyItemBlockPattern = \/<!--\\s\*oa-daily-item[\s\S]{0,200}\(\?!<!--/,
  "daily item block pattern must not swallow the next block"
);

// Category change relocates the block under the new heading.
const replaceFn = functionBody("replaceStructuredDailyItem");
assertIncludes(replaceFn, "needsRelocation", "category change must relocate the block");
assertIncludes(replaceFn, "plannerTaskSubheadingAtOffset", "relocation must compare the actual heading");

console.log("Planner move safety verification passed.");
