import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), "..");
const sourcePath = path.join(projectRoot, "electron", "helpers", "apple-eventkit-helper.swift");
const plistPath = path.join(projectRoot, "electron", "helpers", "apple-eventkit-helper-info.plist");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    ...options
  });
  if (result.status !== 0) {
    throw new Error([
      `${path.basename(command)} failed with code ${result.status}`,
      result.stdout?.trim(),
      result.stderr?.trim()
    ].filter(Boolean).join("\n"));
  }
  return result.stdout ?? "";
}

function helperCommand(helperPath, payload) {
  const stdout = run(helperPath, ["--json", JSON.stringify(payload)], { timeout: 90_000 });
  const line = stdout.trim().split(/\r?\n/).filter(Boolean).pop();
  if (!line) throw new Error("Helper returned no JSON.");
  const parsed = JSON.parse(line);
  if (parsed.ok !== true) throw new Error(parsed.error || "Helper returned ok=false.");
  return parsed.data;
}

if (process.platform !== "darwin") {
  console.log("Apple EventKit verification skipped: macOS only.");
  process.exit(0);
}

if (!fs.existsSync(sourcePath)) throw new Error(`Missing helper source: ${sourcePath}`);
if (!fs.existsSync(plistPath)) throw new Error(`Missing helper Info.plist: ${plistPath}`);
const helperSource = fs.readFileSync(sourcePath, "utf8");
const requestAccessSource = helperSource.match(/private func requestAccess[\s\S]*?\n}\n/)?.[0] ?? "";
if (!requestAccessSource.includes("RunLoop.current.run")) throw new Error("Permission request must keep the helper run loop alive.");
if (!requestAccessSource.includes("timedOut")) throw new Error("Permission request must report timeout state.");
if (requestAccessSource.includes("DispatchSemaphore")) throw new Error("Permission request must not block EventKit with DispatchSemaphore.");
if (!helperSource.includes('case "update-reminder"')) throw new Error("Apple EventKit helper must expose reminder updates.");
if (!helperSource.includes("private func updateReminder")) throw new Error("Apple EventKit helper must update reminders without completing them.");
if (!helperSource.includes("responsibility_spawnattrs_setdisclaim")) {
  throw new Error("Helper must disclaim TCC responsibility so permission prompts attribute to the helper, not the parent Electron process.");
}
if (!helperSource.includes("reexecDisclaimedIfNeeded()")) throw new Error("Helper must invoke the disclaim re-exec before handling commands.");
const entitlementsPath = path.join(projectRoot, "electron", "helpers", "apple-eventkit-helper-entitlements.plist");
if (!fs.existsSync(entitlementsPath)) throw new Error(`Missing helper entitlements: ${entitlementsPath}`);
const entitlementsSource = fs.readFileSync(entitlementsPath, "utf8");
if (!entitlementsSource.includes("com.apple.security.personal-information.calendars")) {
  throw new Error("Helper entitlements must include calendars (hardened runtime silently denies calendar access without it).");
}
if (!helperSource.includes('case "search-reminders"')) throw new Error("Apple EventKit helper must expose reminder title search.");
if (!helperSource.includes("private func searchReminders")) throw new Error("Apple EventKit helper must filter reminder titles before applying the result limit.");
if (!helperSource.includes("private func recurrenceRule")) throw new Error("Apple EventKit helper must parse recurrence rules.");
if (!helperSource.includes('payload["recurrence"]')) throw new Error("Reminder payloads must report the repeat schedule.");
if (!helperSource.includes("removeRecurrenceRule")) throw new Error("update-reminder must be able to replace/clear recurrence rules.");
if (!helperSource.includes('case "delete-reminder"')) throw new Error("Apple EventKit helper must expose delete-reminder for verification cleanup.");
const nativeAccessSource = fs.readFileSync(path.join(projectRoot, "electron", "nativeAccess.ts"), "utf8");
if (!nativeAccessSource.includes('/^(list|search)-/')) {
  throw new Error("nativeAccess must classify search- commands as read access (else search prompts for write permission).");
}
const bridgeSource = fs.readFileSync(path.join(projectRoot, "electron", "openassistBridge.ts"), "utf8");
if (!bridgeSource.includes("oa_apple_search_reminders")) throw new Error("Bridge must expose the oa_apple_search_reminders tool.");
if (!bridgeSource.includes("parseAppleRemindersQuickReadTarget")) {
  throw new Error("quick_read must route Apple Reminders targets to the real Reminders store.");
}
const realtimeSource = fs.readFileSync(path.join(projectRoot, "electron", "realtimeProxy.ts"), "utf8");
if (!realtimeSource.includes("knowledge_apple_search_reminders")) {
  throw new Error("Live Voice must expose the Apple Reminders search capability.");
}
if (!realtimeSource.includes("clearRecurrence")) {
  throw new Error("Live Voice update-reminder spec must expose recurrence editing.");
}
const buildScriptSource = fs.readFileSync(path.join(projectRoot, "scripts", "build-native-helpers.sh"), "utf8");
if (!buildScriptSource.includes("apple-eventkit-helper-entitlements.plist")) {
  throw new Error("build-native-helpers.sh must sign the EventKit helper with its entitlements file.");
}
const mainSource = fs.readFileSync(path.join(projectRoot, "electron", "main.ts"), "utf8");
if (!mainSource.includes("appleEventKitHelperEntitlementsPath")) {
  throw new Error("Dev helper build in main.ts must sign with the EventKit entitlements file.");
}

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-eventkit-verify-"));
// Compile into a minimal .app bundle (like build-native-helpers.sh) so codesigning
// and TCC treat it as the EventKit helper app rather than an anonymous binary.
const helperAppPath = path.join(tempRoot, "Open Assist Apple EventKit Helper.app");
const helperMacOSPath = path.join(helperAppPath, "Contents", "MacOS");
fs.mkdirSync(helperMacOSPath, { recursive: true });
fs.copyFileSync(plistPath, path.join(helperAppPath, "Contents", "Info.plist"));
const helperPath = path.join(helperMacOSPath, "apple-eventkit-helper");

try {
  run("/usr/bin/swiftc", [
    "-framework",
    "EventKit",
    "-framework",
    "AppKit",
    "-Xlinker",
    "-sectcreate",
    "-Xlinker",
    "__TEXT",
    "-Xlinker",
    "__info_plist",
    "-Xlinker",
    plistPath,
    sourcePath,
    "-o",
    helperPath
  ], { timeout: 120_000 });
  fs.chmodSync(helperPath, 0o755);

  // Sign the bundle like the dev helper build in main.ts (same identity + bundle
  // identifier + entitlements) so the temp helper shares the existing TCC
  // Reminders grant; unsigned, its access is notDetermined and the write
  // round-trip cannot run.
  try {
    const identities = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]);
    const identity = identities.match(/"(Developer ID Application:[^"]+)"/)?.[1]
      || identities.match(/"(Apple Development:[^"]+)"/)?.[1];
    if (identity) {
      run("/usr/bin/codesign", [
        "--force",
        "--options",
        "runtime",
        "--entitlements",
        entitlementsPath,
        "--sign",
        identity,
        "--identifier",
        "com.developingadventures.OpenAssist.ElectronAppleEventKitHelper",
        helperAppPath
      ]);
    }
  } catch (error) {
    console.warn(`Helper signing skipped: ${error instanceof Error ? error.message : error}`);
  }

  const status = helperCommand(helperPath, { command: "status" });
  console.log(`Apple EventKit helper compiled. Reminders=${status.reminders} Calendar=${status.calendar}`);

  if (process.env.OPENASSIST_VERIFY_APPLE_EVENTKIT_WRITE === "1") {
    const token = `oa-verify-${Date.now()}`;
    const title = `OpenAssist EventKit Verify ${token}`;
    const isoDay = (daysFromNow) => new Date(Date.now() + daysFromNow * 86_400_000).toISOString().slice(0, 10);
    const createdIDs = [];
    try {
      // Plain reminder: rename, complete, search filters, un-complete.
      const reminderData = helperCommand(helperPath, {
        command: "add-reminder",
        title,
        notes: "Created by OpenAssist verification."
      });
      const reminderID = reminderData.reminder?.id;
      if (!reminderID) throw new Error("Created reminder did not include an id.");
      createdIDs.push(reminderID);
      const updatedTitle = `${title} Updated`;
      const updatedData = helperCommand(helperPath, { command: "update-reminder", id: reminderID, title: updatedTitle });
      if (updatedData.reminder?.title !== updatedTitle) throw new Error("Updated reminder did not return the new title.");
      if (updatedData.reminder?.completed !== false) throw new Error("Renaming a reminder must not complete it.");

      const foundOpen = helperCommand(helperPath, { command: "search-reminders", query: token });
      if (foundOpen.totalMatches !== 1 || foundOpen.reminders?.[0]?.id !== reminderID) {
        throw new Error("search-reminders must find the reminder by title token.");
      }

      const completedData = helperCommand(helperPath, { command: "complete-reminder", id: reminderID, completed: true });
      if (completedData.reminder?.completed !== true || !completedData.reminder?.completionDate) {
        throw new Error("Completing a reminder must set completed and completionDate.");
      }
      if (helperCommand(helperPath, { command: "search-reminders", query: token }).completedMatches !== 1) {
        throw new Error("search-reminders must include completed reminders by default.");
      }
      if (helperCommand(helperPath, { command: "search-reminders", query: token, completedOnly: true }).totalMatches !== 1) {
        throw new Error("search-reminders completedOnly must find the completed reminder.");
      }
      if (helperCommand(helperPath, { command: "search-reminders", query: token, includeCompleted: false }).totalMatches !== 0) {
        throw new Error("search-reminders includeCompleted:false must exclude completed reminders.");
      }

      const reopened = helperCommand(helperPath, { command: "complete-reminder", id: reminderID, completed: false });
      if (reopened.reminder?.completed !== false || reopened.reminder?.completionDate) {
        throw new Error("Un-completing must clear completed and completionDate.");
      }

      // Recurring reminder: add with rule, extend endDate (frequency inherited), clear.
      const recurringData = helperCommand(helperPath, {
        command: "add-reminder",
        title: `${title} Recurring`,
        dueDate: `${isoDay(1)}T10:00:00Z`,
        recurrence: { frequency: "weekly", endDate: isoDay(30) }
      });
      const recurringID = recurringData.reminder?.id;
      if (!recurringID) throw new Error("Created recurring reminder did not include an id.");
      createdIDs.push(recurringID);
      const rule = recurringData.reminder?.recurrence;
      if (rule?.frequency !== "weekly" || !rule?.endDate) {
        throw new Error("add-reminder must persist and report the recurrence rule.");
      }
      const extended = helperCommand(helperPath, {
        command: "update-reminder",
        id: recurringID,
        recurrence: { endDate: isoDay(60) }
      });
      const extendedRule = extended.reminder?.recurrence;
      if (extendedRule?.frequency !== "weekly") throw new Error("Extending endDate must inherit the existing frequency.");
      if (!(extendedRule?.endDate > rule.endDate)) throw new Error("recurrence.endDate must move later when extended.");
      const cleared = helperCommand(helperPath, { command: "update-reminder", id: recurringID, clearRecurrence: true });
      if (cleared.reminder?.recurrence) throw new Error("clearRecurrence must remove the repeat rule.");
      console.log(`Apple Reminders search/complete/un-complete/recurrence round-trip succeeded: ${title}`);
    } finally {
      // Delete everything the round-trip created, including any rolled-forward
      // instances a recurring completion may have spawned.
      for (const id of createdIDs) {
        try { helperCommand(helperPath, { command: "delete-reminder", id }); } catch { /* already gone */ }
      }
      try {
        const leftovers = helperCommand(helperPath, { command: "search-reminders", query: token, limit: 100 });
        for (const reminder of leftovers.reminders ?? []) {
          try { helperCommand(helperPath, { command: "delete-reminder", id: reminder.id }); } catch { /* already gone */ }
        }
        const remaining = helperCommand(helperPath, { command: "search-reminders", query: token });
        if (remaining.totalMatches !== 0) throw new Error("Verification reminders were not fully cleaned up.");
      } catch (error) {
        console.warn(`Cleanup warning: ${error instanceof Error ? error.message : error}`);
      }
    }
  } else {
    console.log("Write round-trip skipped. Set OPENASSIST_VERIFY_APPLE_EVENTKIT_WRITE=1 to test add/update/complete.");
  }
} finally {
  fs.rmSync(tempRoot, { recursive: true, force: true });
}
