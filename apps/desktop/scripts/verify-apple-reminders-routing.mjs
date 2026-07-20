import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { parseAppleRemindersQuickReadTarget } from "../dist-electron/appleReminderRouting.js";

// Targets naming Apple Reminders must route to the real Reminders store.
const completedPlan = parseAppleRemindersQuickReadTarget("check the completed reminders");
assert.ok(completedPlan, "completed reminders target must route to Apple Reminders");
assert.equal(completedPlan.includeCompleted, true);
assert.equal(completedPlan.completedOnly, true);
assert.equal(completedPlan.query, undefined);

assert.ok(parseAppleRemindersQuickReadTarget("apple reminders"), "bare apple reminders must route");
assert.ok(parseAppleRemindersQuickReadTarget("reminders"), "bare reminders must route");
assert.ok(parseAppleRemindersQuickReadTarget("my reminders list"), "reminders list must route");

const searchPlan = parseAppleRemindersQuickReadTarget("pay off the credit cards in the reminders app");
assert.ok(searchPlan, "reminders app target must route");
assert.ok(searchPlan.query?.includes("pay off"), `leftover terms become the search query, got: ${searchPlan.query}`);
assert.equal(searchPlan.completedOnly, false);

const openPlan = parseAppleRemindersQuickReadTarget("open reminders");
assert.ok(openPlan, "open reminders must route");
assert.equal(openPlan.includeCompleted, false);

// Non-reminder targets must keep their existing planner/notes routing.
for (const target of ["today", "my grocery notes", "backlog", "reminder me later plan", "planner today"]) {
  assert.equal(parseAppleRemindersQuickReadTarget(target), null, `"${target}" must NOT route to Apple Reminders`);
}

// The quick_read intercept must run before the sync knowledge fallthrough.
const bridgeSource = await readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");
const intercept = bridgeSource.indexOf("parseAppleRemindersQuickReadTarget(String(args.target");
assert.ok(intercept > -1, "knowledgeToolResultAsync must parse quick_read targets for Apple Reminders");
const asyncSwitch = bridgeSource.indexOf("async function knowledgeToolResultAsync");
assert.ok(asyncSwitch > -1 && intercept > asyncSwitch, "the intercept must live inside knowledgeToolResultAsync");

console.log("Apple Reminders quick_read routing checks passed.");
