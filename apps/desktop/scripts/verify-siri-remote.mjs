import assert from "node:assert/strict";
import fs from "node:fs";
import {
  SiriRequestRegistry,
  computerUsePluginID,
  openAssistWorkspacePluginID,
  routeSiriPrompt,
  siriSpeakableText
} from "../dist-electron/siriRemote.js";

const google = routeSiriPrompt("Add a task for tomorrow at 11 AM");
assert.equal(google.route, "googleWorkspace");
assert.deepEqual(google.pluginIDs, [openAssistWorkspacePluginID]);

const memory = routeSiriPrompt("Remember that my main office is in Springfield");
assert.equal(memory.route, "googleWorkspace");
assert.deepEqual(memory.pluginIDs, [openAssistWorkspacePluginID]);

const mac = routeSiriPrompt("Open Safari on my Mac and find the downloads page");
assert.equal(mac.route, "macComputerUse");
assert.deepEqual(mac.pluginIDs, [computerUsePluginID]);

const hybrid = routeSiriPrompt("Find the flight email and open it in Chrome on my Mac");
assert.equal(hybrid.route, "hybrid");
assert.deepEqual(hybrid.pluginIDs, [openAssistWorkspacePluginID, computerUsePluginID]);

const plain = routeSiriPrompt("Explain why the sky is blue");
assert.equal(plain.route, "codex");
assert.deepEqual(plain.pluginIDs, []);

assert.equal(
  siriSpeakableText("## Done\n- [Open the task](https://example.com)\n- **Saved**"),
  "Done Open the task Saved"
);

const registry = new SiriRequestRegistry();
const created = registry.create({
  requestID: "request-1",
  deviceID: "device-1",
  sessionID: "session-1",
  prompt: "List my tasks",
  route: "googleWorkspace"
});
assert.equal(created.status, "running");
assert.match(created.acknowledgement, /Workspace/);
setTimeout(() => registry.complete("request-1", "**Two** tasks are due."), 10);
const completed = await registry.wait("request-1", 500);
assert.equal(completed?.status, "completed");
assert.equal(completed?.answer, "Two tasks are due.");
assert.equal(registry.latest("device-1")?.requestID, "request-1");

const timed = registry.create({
  requestID: "request-2",
  deviceID: "device-2",
  sessionID: "session-1",
  prompt: "Open Finder",
  route: "macComputerUse"
});
const stillRunning = await registry.wait(timed.requestID, 15);
assert.equal(stillRunning?.status, "running");
registry.fail(timed.requestID, "Mac is offline.");
assert.equal(registry.latest("device-2")?.status, "failed");
assert.match(registry.latest("device-2")?.error ?? "", /offline/);

const bridgeSource = fs.readFileSync(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");
assert.match(bridgeSource, /else if \(type === "siriRequest"\)/);
assert.match(bridgeSource, /else if \(type === "siriRequestStatus"\)/);
assert.match(bridgeSource, /Math\.min\(15_000/);
assert.match(bridgeSource, /Math\.min\(2_000, normalizedSiriWaitMilliseconds\(value\)\)/);
assert.match(bridgeSource, /normalizedSiriInitialWaitMilliseconds\(payload\.waitMilliseconds\)/);
assert.match(bridgeSource, /routing\.pluginIDs/);
assert.match(bridgeSource, /"low",\s*"agentic",\s*"fullAccess"/);

console.log("Siri remote routing verification passed.");
