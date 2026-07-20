import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), "..");
const repoRoot = path.resolve(projectRoot, "..", "..");
const mobileRoot = path.join(repoRoot, "companion-projects", "OpenAssist-Mobile-Remote");

function read(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function assertIncludes(text, needle, label) {
  if (!text.includes(needle)) throw new Error(`${label} missing: ${needle}`);
}

function assertNotIncludes(text, needle, label) {
  if (text.includes(needle)) throw new Error(`${label} must not include: ${needle}`);
}

const bridge = read(path.join(projectRoot, "electron", "openassistBridge.ts"));
const main = read(path.join(projectRoot, "electron", "main.ts"));
const realtime = read(path.join(projectRoot, "electron", "realtimeProxy.ts"));
const app = read(path.join(projectRoot, "src", "App.tsx"));
const styles = read(path.join(projectRoot, "src", "styles.css"));
const types = read(path.join(projectRoot, "src", "types.ts"));
const packageJSON = JSON.parse(read(path.join(projectRoot, "package.json")));
const mobilePackageJSON = JSON.parse(read(path.join(mobileRoot, "package.json")));
const mobileAppJSON = read(path.join(mobileRoot, "app.json"));
const mobileTypes = read(path.join(mobileRoot, "src", "types", "remote.ts"));
const mobileContext = read(path.join(mobileRoot, "src", "context", "remote-context.tsx"));
const mobileReminderService = read(path.join(mobileRoot, "src", "services", "reminder-notifications.ts"));
const mobileItemScreen = read(path.join(mobileRoot, "src", "app", "(tabs)", "today", "item.tsx"));
const mobileRow = read(path.join(mobileRoot, "src", "components", "planner", "daily-item-row.tsx"));
// The reminder edit UI was refactored out of item.tsx into these components.
const mobileReminderSheet = read(path.join(mobileRoot, "src", "components", "planner", "reminder-sheet.tsx"));
const mobileDatePicker = read(path.join(mobileRoot, "src", "components", "planner", "planner-date-picker.tsx"));
const phoneTools = read(path.join(mobileRoot, "src", "services", "voice", "gemini-tools.ts"));

for (const field of ["reminderAt", "reminderTimezone", "reminderDeliveredAt"]) {
  assertIncludes(types, field, `desktop DailyItem ${field}`);
  assertIncludes(bridge, field, `bridge DailyItem ${field}`);
  assertIncludes(mobileTypes, field, `mobile remote type ${field}`);
}

for (const symbol of [
  "normalizeReminderDate",
  "preserveStructuredDailyItemsAfterEditorRoundTrip",
  "savePlannerDayFromEditor",
  "plannerReminderLedgerPath",
  "runPlannerReminderScheduler",
  "showPlannerReminderNotification",
  "canUseMacNativeReminderNotifications",
  "TeamIdentifier=",
  "notification.once(\"show\"",
  "notification.once(\"failed\"",
  "setPlannerReminderDueListener",
  "new Notification",
  "schedulePlannerReminderRefresh()"
]) {
  assertIncludes(bridge, symbol, "desktop reminder scheduler");
}
assertIncludes(bridge, "emitPlannerDayChanged(dayID)", "desktop day mutation reminder refresh");
assertIncludes(bridge, "emitPlannerBacklogChanged()", "desktop backlog mutation reminder refresh");
assertIncludes(bridge, "remoteAccessDailyItem", "remote item mapper");
assertNotIncludes(bridge, "if (item.reminderDeliveredAt || ledger[key]", "desktop per-device reminder delivery");

for (const needle of [
  "expo-notifications",
  "POST_NOTIFICATIONS",
  "reconcileReminderNotifications",
  "scheduleNotificationAsync",
  "cancelScheduledNotificationAsync",
  "addNotificationResponseReceivedListener",
  "reminderNotifications.v1"
]) {
  assertIncludes(`${mobilePackageJSON.dependencies?.["expo-notifications"] ?? ""}\n${mobileAppJSON}\n${mobileContext}\n${mobileReminderService}`, needle, "mobile local notifications");
}

for (const needle of [
  "datetime-local",
  "daily-reminder-edit",
  "Reminds",
  "daily-task-reminder-action",
  "data-planner-reminder-item",
  "DateTimePicker",
  // Clearing a reminder lives in the ReminderSheet's remove action (the extra
  // "Clear reminder" row was removed when the edit screen was decluttered).
  "onRemove",
  "reminderBadgeLabel",
  "planner-reminder-popover",
  // The reminder save must be a minimal patch — resending stale area/section
  // from the renderer made the bridge relocate tasks under other ### headings.
  "Minimal patch on purpose",
  // Desktop canvas and Markdown views expose reminders in the task menu.
  "onPlannerTaskReminder",
  "plannerTaskFromRichTarget",
  "plannerTaskAtMarkdownOffset",
  "Set reminder...",
  "Edit reminder..."
]) {
  assertIncludes(`${app}\n${styles}\n${mobileItemScreen}\n${mobileRow}\n${mobileReminderSheet}\n${mobileDatePicker}`, needle, "reminder UI");
}

assertIncludes(app, "noteDraftRef.current = update.day.markdown", "desktop planner sync updates the live draft ref");
assertIncludes(app, "clearNoteAutosaveTimer()", "desktop planner sync clears stale autosave timers");
assertIncludes(bridge, "savePlannerDayFromEditor as savePlannerDay", "desktop editor uses metadata-preserving planner saves");

// The phone must receive EVERY upcoming reminder (not just the day on screen)
// and must only cancel scheduled notifications against that authoritative list.
assertIncludes(bridge, "plannerReminderItems().map(remoteAccessDailyItem)", "desktop snapshot reminder items");
// Reminder/status-only updates must never recategorize (voice models echo a
// guessed area alongside reminderAt, which relocated tasks between headings).
assertIncludes(bridge, "ignored category", "reminder-only updates keep the existing category");
assertIncludes(realtime, "NEVER include area/category/listName on those calls", "voice instruction against category guessing");
assertIncludes(mobileTypes, "reminderItems?: RemoteAccessDailyItem[]", "mobile snapshot reminder items type");
assertIncludes(mobileReminderService, "add(snapshot.reminderItems);", "mobile reconcile uses snapshot reminder list");
assertIncludes(mobileReminderService, "snapshotIsAuthoritativeForCleanup", "mobile cleanup gated on authoritative list");
assertIncludes(mobileReminderService, "getAllScheduledNotificationsAsync", "mobile verifies OS reminder schedule");
assertNotIncludes(mobileReminderService, "item.reminderDeliveredAt) continue;", "mobile per-device reminder delivery");
assertIncludes(main, "showPlannerReminderFallback", "desktop reminder fallback panel");

for (const source of [bridge, realtime, phoneTools]) {
  assertIncludes(source, "reminderAt", "agent reminderAt schema");
  assertIncludes(source, "reminderTimezone", "agent reminderTimezone schema");
  assertIncludes(source, "ISO datetime", "agent reminder instructions");
}

// quick_add_task is the main voice path — its payload builder must carry the
// reminder fields the tool schema advertises (they were silently dropped, so
// no task ever got a reminder time saved).
const quickTaskFnStart = bridge.indexOf("function quickTaskPayload");
const quickTaskFn = bridge.slice(quickTaskFnStart, bridge.indexOf("\nfunction ", quickTaskFnStart + 1));
assertIncludes(quickTaskFn, "args.reminderAt ?? args.dueAt ?? args.notifyAt", "quickTaskPayload reminder passthrough");
assertIncludes(quickTaskFn, "reminderTimezone", "quickTaskPayload reminder timezone passthrough");

// The simple-mode (external MCP) trimmed schemas must advertise the reminder
// fields too — the handlers always accepted reminderAt, but agents whose
// client validates against the trimmed schema silently dropped it, so
// "remind me at 5" via Codex never saved a time on request/update tools.
const simpleToolFnStart = bridge.indexOf("function simpleKnowledgeMCPTool");
const simpleToolFn = bridge.slice(simpleToolFnStart, bridge.indexOf("\ntype KnowledgeAccessSettings", simpleToolFnStart));
for (const toolCase of ["oa_request_daily_item", "oa_request_backlog_item", "oa_update_daily_item"]) {
  const caseStart = simpleToolFn.indexOf(`case "${toolCase}"`);
  const caseEnd = simpleToolFn.indexOf("case \"", caseStart + 1);
  const caseBlock = simpleToolFn.slice(caseStart, caseEnd === -1 ? undefined : caseEnd);
  assertIncludes(caseBlock, "reminderAt", `simple-mode ${toolCase} reminderAt schema`);
  assertIncludes(caseBlock, "reminderTimezone", `simple-mode ${toolCase} reminderTimezone schema`);
}

if (packageJSON.scripts?.["verify:reminder-notifications"] !== "node scripts/verify-reminder-notifications.mjs") {
  throw new Error("package.json missing verify:reminder-notifications script.");
}

console.log("Reminder notification verification passed.");
