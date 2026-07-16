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

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-eventkit-verify-"));
const helperPath = path.join(tempRoot, "apple-eventkit-helper");

try {
  run("/usr/bin/swiftc", [
    "-framework",
    "EventKit",
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

  const status = helperCommand(helperPath, { command: "status" });
  console.log(`Apple EventKit helper compiled. Reminders=${status.reminders} Calendar=${status.calendar}`);

  if (process.env.OPENASSIST_VERIFY_APPLE_EVENTKIT_WRITE === "1") {
    const title = `OpenAssist EventKit Verify ${new Date().toISOString()}`;
    const reminderData = helperCommand(helperPath, {
      command: "add-reminder",
      title,
      notes: "Created by OpenAssist verification."
    });
    const reminderID = reminderData.reminder?.id;
    if (!reminderID) throw new Error("Created reminder did not include an id.");
    helperCommand(helperPath, { command: "complete-reminder", id: reminderID, completed: true });
    console.log(`Apple Reminders write round-trip succeeded: ${title}`);
  } else {
    console.log("Write round-trip skipped. Set OPENASSIST_VERIFY_APPLE_EVENTKIT_WRITE=1 to test add/complete.");
  }
} finally {
  fs.rmSync(tempRoot, { recursive: true, force: true });
}
