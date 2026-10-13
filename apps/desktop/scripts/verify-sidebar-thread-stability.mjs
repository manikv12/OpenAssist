import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bridge = fs.readFileSync(path.join(root, "electron/openassistBridge.ts"), "utf8");
const app = fs.readFileSync(path.join(root, "src/App.tsx"), "utf8");

assert.match(
  bridge,
  /threadListComplete:\s*false/,
  "The fast initial thread page must be marked incomplete."
);
assert.match(
  bridge,
  /type:\s*"threads",\s*threads:\s*fullThreads,\s*complete:\s*true/,
  "The background thread refresh must be marked complete."
);
assert.match(
  app,
  /loadedState\.threadListComplete\s*===\s*false[\s\S]*mergePartialThreadList/,
  "An incomplete refresh must merge with the threads already visible."
);
assert.match(
  app,
  /threadListComplete:\s*update\.complete/,
  "The renderer must remember when the full thread list arrives."
);

console.log("Sidebar thread stability verification passed.");
