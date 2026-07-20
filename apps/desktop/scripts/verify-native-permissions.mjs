import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { NativePermissionBroker } from "../dist-electron/nativeAccess.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const [main, preload, app, proxy, helperBuild] = await Promise.all([
  readFile(path.join(root, "electron/main.ts"), "utf8"),
  readFile(path.join(root, "electron/preload.ts"), "utf8"),
  readFile(path.join(root, "src/App.tsx"), "utf8"),
  readFile(path.join(root, "electron/realtimeProxy.ts"), "utf8"),
  readFile(path.join(root, "scripts/build-native-helpers.sh"), "utf8")
]);

assert.match(main, /openassist:native-permissions-get/);
assert.match(main, /if \(app\.isPackaged\)[\s\S]{0,300}signed Apple EventKit helper is missing/);
assert.match(main, /Developer ID Application:[\s\S]{0,160}Apple Development:/);
assert.match(main, /runProcess\("\/usr\/bin\/open", \[url\]\)/);
assert.doesNotMatch(main, /openassist:get-macos-permissions|openassist:request-macos-permission|openassist:apple-eventkit-status/);
assert.doesNotMatch(preload, /getMacOSPermissions|requestMacOSPermission|requestAppleEventKitAccess/);
assert.match(preload, /onNativePermissionsChanged/);
assert.doesNotMatch(app, /setInterval\(refresh, 3_000\)/);
assert.match(app, /onNativePermissionsChanged/);
assert.match(app, /shouldRequest[\s\S]{0,300}openNativePermissionSettings/);
assert.match(proxy, /permissionRequirements:[\s\S]{0,250}eventkit\.reminders/);
assert.match(proxy, /A failed direct capability is the final state for that source/);
assert.match(helperBuild, /Open Assist Apple EventKit Helper/);
assert.match(helperBuild, /Open Assist Speech Helper/);

const broker = new NativePermissionBroker();
let requested = 0;
broker.register({
  id: "eventkit.reminders",
  owner: { kind: "eventkitHelper", displayName: "Test EventKit Helper", bundleID: "example.helper" },
  probe: () => ({ state: requested ? "granted" : "notDetermined" }),
  request: () => { requested += 1; }
});
assert.equal((await broker.get("eventkit.reminders")).state, "notDetermined");
assert.equal((await broker.request("eventkit.reminders")).state, "granted");
assert.equal((await broker.getSnapshot()).permissions[0].owner.bundleID, "example.helper");

console.log("Native permission architecture verification passed.");
