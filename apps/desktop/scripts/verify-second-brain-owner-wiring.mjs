import assert from "node:assert/strict";
import fs from "node:fs";

const main = fs.readFileSync(new URL("../electron/main.ts", import.meta.url), "utf8");
const preload = fs.readFileSync(new URL("../electron/preload.ts", import.meta.url), "utf8");

assert.match(main, /callAuthenticatedOpenAssistWorkspaceTool\(name, args\)/);
assert.match(main, /pollIntervalMs:\s*60_000/);
// An idle queue must back off instead of claiming work every 60 seconds.
assert.match(main, /idlePollIntervalMs:\s*900_000/);
assert.match(main, /status\.poll\.nextPollMs/);
assert.match(main, /start\("app-ready"\)/);
assert.match(main, /powerMonitor\.on\("suspend"/);
assert.match(main, /powerMonitor\.on\("lock-screen"/);
assert.match(main, /powerMonitor\.on\("resume"/);
assert.match(main, /powerMonitor\.on\("unlock-screen"/);
assert.match(main, /secondBrainOwnerRunnerService\?\.stop\("app-quit"\)/);
assert.match(preload, /secondBrainOwnerRunnerStatus/);
assert.match(preload, /startSecondBrainOwnerRunner/);
assert.match(preload, /stopSecondBrainOwnerRunner/);

console.log("Second Brain owner main-process wiring verification passed.");
