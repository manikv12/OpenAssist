import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

// Guards against re-introducing the bug where OpenAssist's Computer Use helper
// cleanup killed helpers belonging to the standalone Codex.app (breaking its
// "locked use" sessions with "Transport closed"). Every automatic kill path
// must classify helper ownership first and leave foreign helpers alone.
// See docs/computer-use-troubleshooting.md.

const bridgePath = path.resolve("electron/openassistBridge.ts");
const bridge = fs.readFileSync(bridgePath, "utf8");

assert.match(
  bridge,
  /function classifyComputerUseHelperOwnership\(/,
  "Helper ownership classifier must exist."
);
assert.match(
  bridge,
  /function isAutomaticallyKillableComputerUseHelper\(/,
  "Automatic kill paths must share a single ownership gate."
);
assert.match(
  bridge,
  /if \(entry\.kind === "service"\) return false;/,
  "Automatic cleanup must never kill the shared SkyComputerUseService."
);

// cleanupStaleComputerUseHelpers must gate on ownership.
const staleCleanup = bridge.slice(
  bridge.indexOf("async function cleanupStaleComputerUseHelpers"),
  bridge.indexOf("export async function getComputerUseActivity")
);
assert.match(
  staleCleanup,
  /isAutomaticallyKillableComputerUseHelper\(entry, snapshotByPID\)/,
  "Stale helper cleanup must skip foreign (Codex.app-owned) helpers."
);

// Startup cleanup must gate on ownership (it used to kill EVERY helper).
const startupCleanup = bridge.slice(
  bridge.indexOf("export async function cleanupOrphanedComputerUseHelpersOnStartup"),
  bridge.indexOf("export async function forceStopComputerUse")
);
assert.match(
  startupCleanup,
  /isAutomaticallyKillableComputerUseHelper\(entry, snapshotByPID\)/,
  "Startup cleanup must skip foreign (Codex.app-owned) helpers."
);

// Activity report (feeds the UI and Force stop) must exclude foreign helpers.
const activity = bridge.slice(
  bridge.indexOf("export async function getComputerUseActivity"),
  bridge.indexOf("export async function cleanupOrphanedComputerUseHelpersOnStartup")
);
assert.match(
  activity,
  /classifyComputerUseHelperOwnership\(entry, snapshotByPID\) !== "foreign"/,
  "Computer Use activity must not report or force-stop foreign helpers."
);

// The post-stop sweep must gate on ownership too.
const stopSweepIndex = bridge.indexOf("async function restartCodexAfterStoppedRunIfNeeded");
const stopSweep = bridge.slice(stopSweepIndex, stopSweepIndex + 2500);
assert.match(
  stopSweep,
  /isAutomaticallyKillableComputerUseHelper\(entry, snapshotByPID\)/,
  "Stop sweep must skip foreign (Codex.app-owned) helpers."
);

console.log("Computer Use helper ownership guards verified.");
