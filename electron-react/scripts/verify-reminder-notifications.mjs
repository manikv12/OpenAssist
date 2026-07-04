import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), "..");
const repoRoot = path.resolve(projectRoot, "..");
const mobileRoot = path.join(repoRoot, "companion-projects", "OpenAssist-Mobile-Remote");

function read(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function assertIncludes(text, needle, label) {
  if (!text.includes(needle)) throw new Error(`${label} missing: ${needle}`);
}

const bridge = read(path.join(projectRoot, "electron", "openassistBridge.ts"));
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
  "plannerReminderLedgerPath",
  "runPlannerReminderScheduler",
  "showPlannerReminderNotification",
  "new Notification",
  "schedulePlannerReminderRefresh()"
]) {
  assertIncludes(bridge, symbol, "desktop reminder scheduler");
}
assertIncludes(bridge, "emitPlannerDayChanged(dayID)", "desktop day mutation reminder refresh");
assertIncludes(bridge, "emitPlannerBacklogChanged()", "desktop backlog mutation reminder refresh");
assertIncludes(bridge, "remoteAccessDailyItem", "remote item mapper");

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
  "DateTimePicker",
  "Clear reminder",
  "reminderBadgeLabel"
]) {
  assertIncludes(`${app}\n${styles}\n${mobileItemScreen}\n${mobileRow}\n${mobileReminderSheet}\n${mobileDatePicker}`, needle, "reminder UI");
}

// The phone must receive EVERY upcoming reminder (not just the day on screen)
// and must only cancel scheduled notifications against that authoritative list.
assertIncludes(bridge, "plannerReminderItems().map(remoteAccessDailyItem)", "desktop snapshot reminder items");
assertIncludes(mobileTypes, "reminderItems?: RemoteAccessDailyItem[]", "mobile snapshot reminder items type");
assertIncludes(mobileReminderService, "add(snapshot.reminderItems);", "mobile reconcile uses snapshot reminder list");
assertIncludes(mobileReminderService, "snapshotIsAuthoritativeForCleanup", "mobile cleanup gated on authoritative list");
assertIncludes(mobileReminderService, "item.reminderDeliveredAt) continue;", "mobile skips already-delivered reminders");

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

if (packageJSON.scripts?.["verify:reminder-notifications"] !== "node scripts/verify-reminder-notifications.mjs") {
  throw new Error("package.json missing verify:reminder-notifications script.");
}

console.log("Reminder notification verification passed.");
