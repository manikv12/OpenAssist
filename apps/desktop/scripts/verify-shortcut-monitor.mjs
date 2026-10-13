import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const [main, helper, helperBuild, plist] = await Promise.all([
  readFile(path.join(root, "electron/main.ts"), "utf8"),
  readFile(path.join(root, "electron/helpers/shortcut-monitor-helper.swift"), "utf8"),
  readFile(path.join(root, "scripts/build-native-helpers.sh"), "utf8"),
  readFile(path.join(root, "electron/helpers/shortcut-monitor-helper-info.plist"), "utf8")
]);

assert.match(main, /installPackagedShortcutMonitorHelper\(\)/);
assert.match(main, /Open Assist Shortcut Monitor\.app/);
assert.match(main, /Signed shortcut monitor helper is missing from the installed app/);
assert.match(main, /path\.join\(app\.getPath\("home"\), "Applications"\)/);
assert.match(main, /lsregister/);
assert.match(main, /runProcess\("\/usr\/bin\/open"/);
assert.match(main, /"--request-permission"/);
assert.match(main, /targetApplication\?: FrontmostApplicationSnapshot/);
assert.doesNotMatch(main, /shortcutMonitorConfigPath/);
assert.doesNotMatch(main, /shortcut\.target === "assistantLiveVoice"/);
assert.match(main, /input-monitoring-required/);
assert.match(main, /Open Assist Shortcut Monitor in Input Monitoring/);
assert.match(main, /Privacy_ListenEvent/);
assert.match(main, /shortcutMonitorNeedsInputAccess && !shortcutMonitorProcess/);
assert.match(helper, /CGPreflightListenEventAccess\(\)/);
assert.match(helper, /--request-permission/);
assert.match(helper, /--parent-pid/);
assert.match(helper, /flock/);
assert.match(helper, /kill\(parentPID, 0\)/);
assert.match(helper, /"application"/);
assert.match(helper, /tapDisabledByTimeout/);
assert.match(helper, /tapDisabledByUserInput/);
assert.match(helper, /CGEvent\.tapIsEnabled/);
assert.match(helperBuild, /Open Assist Shortcut Monitor/);
assert.match(plist, /com\.developingadventures\.OpenAssist\.ShortcutMonitor/);

const typecheck = spawnSync("/usr/bin/swiftc", [
  "-typecheck",
  "-framework",
  "AppKit",
  path.join(root, "electron/helpers/shortcut-monitor-helper.swift")
], { encoding: "utf8" });
assert.equal(typecheck.status, 0, typecheck.stderr || typecheck.stdout);

console.log("Shortcut monitor verification passed.");
