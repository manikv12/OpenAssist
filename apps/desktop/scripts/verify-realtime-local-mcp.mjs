import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { __realtimeProtocolTestHooks } from "../dist-electron/realtimeProxy.js";

const descriptors = __realtimeProtocolTestHooks.liveVoiceCapabilityDescriptors(() => ({
  knowledge: { enabled: true },
  localMCP: { enabled: true }
}));
const discover = descriptors.find((item) => item.id === "local_mcp_discover");
const execute = descriptors.find((item) => item.id === "local_mcp_execute");
assert.ok(discover);
assert.ok(execute);
assert.equal(discover.risk, "read");
assert.equal(execute.idempotency, "required");

const source = await readFile(new URL("../electron/realtimeProxy.ts", import.meta.url), "utf8");
assert.match(source, /localMCP\.findTools/);
assert.match(source, /__voiceCapabilityStatus: "selection_required"/);
assert.match(source, /Select one exact MCP toolID/);
assert.match(source, /localMCP\.callTool/);
assert.match(source, /confirmationRequired === true/);
assert.doesNotMatch(source, /Found \$\{matches\.length\} matching local tools/);

console.log("Realtime local MCP capability checks passed.");
