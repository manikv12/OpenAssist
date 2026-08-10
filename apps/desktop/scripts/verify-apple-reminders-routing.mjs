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


// --- parseAppleReminderAddRequest: derives reminder fields from speech -----
const { parseAppleReminderAddRequest } = await import("../dist-electron/appleReminderRouting.js");
const monday = new Date("2026-07-20T10:00:00");
const trash = parseAppleReminderAddRequest("Can you add a reminder in my reminders to take out trash on Friday? Morning at 8:00 a.m.", monday);
assert.equal(trash.title, "Take out trash");
assert.equal(new Date(trash.dueDateISO).getDay(), 5, "must land on Friday");
assert.equal(new Date(trash.dueDateISO).getHours(), 8, "must use the spoken 8 a.m., not the morning default");
const weekly = parseAppleReminderAddRequest("add a reminder to take out the trash every Friday at 8am", monday);
assert.equal(weekly.recurrence?.frequency, "weekly");
assert.equal(weekly.title, "Take out the trash");
const tomorrow = parseAppleReminderAddRequest("remind me to call mom tomorrow at 5pm", monday);
assert.equal(tomorrow.title, "Call mom");
assert.equal(new Date(tomorrow.dueDateISO).getHours(), 17);
assert.equal(parseAppleReminderAddRequest("yeah", monday), null, "bare confirmations are not reminders");
assert.equal(parseAppleReminderAddRequest("add a reminder", monday), null, "no title means ask");
// The add handler must consume userIntent as its fallback source.
const addCase = bridgeSource.indexOf('case "oa_apple_add_reminder"');
const addBlock = bridgeSource.slice(addCase, addCase + 2200);
assert.ok(addBlock.includes("parseAppleReminderAddRequest"), "add handler must parse userIntent when structured fields are missing");


// --- parseAppleReminderRenameTarget: update calls with dropped fields -------
const { parseAppleReminderRenameTarget } = await import("../dist-electron/appleReminderRouting.js");
assert.equal(parseAppleReminderRenameTarget("Rename it to take out trash"), "take out trash");
assert.equal(
  parseAppleReminderRenameTarget('update the reminder with id ABC to have the title "take out the trash" (without quotes) in Apple Reminders'),
  "take out the trash"
);
assert.equal(parseAppleReminderRenameTarget("mark it complete"), null, "non-rename requests must not produce a title");
const updateCase = bridgeSource.indexOf('case "oa_apple_update_reminder"');
const updateBlock = bridgeSource.slice(updateCase, updateCase + 2600);
assert.ok(updateBlock.includes("parseAppleReminderRenameTarget"), "update handler must derive renames from userIntent");

console.log("Apple Reminders quick_read routing checks passed.");
