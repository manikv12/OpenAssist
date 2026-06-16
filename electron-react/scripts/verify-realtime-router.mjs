import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const proxyPath = path.resolve("dist-electron/realtimeProxy.js");

if (!fs.existsSync(proxyPath)) {
  console.error("Missing dist-electron/realtimeProxy.js. Run npm run build first.");
  process.exit(1);
}

const { __realtimeRouterTestHooks } = await import(path.toNamespacedPath(proxyPath));
const { decideRealtimeDelegation, isHighConfidenceRealtimeDelegation } = __realtimeRouterTestHooks;

function assertBlocked(prompt, expectedReason) {
  const decision = decideRealtimeDelegation(prompt, false, "");
  assert.equal(decision.allow, false, `${prompt} should not delegate`);
  if (expectedReason) assert.equal(decision.reason, expectedReason);
  return decision;
}

function assertBlockedWhileBusy(prompt, expectedReason) {
  const decision = decideRealtimeDelegation(prompt, true, "Search Messages for the mortgage prepayment thread.");
  assert.equal(decision.allow, false, `${prompt} should not delegate while busy`);
  if (expectedReason) assert.equal(decision.reason, expectedReason);
  return decision;
}

function assertDelegates(prompt) {
  const decision = decideRealtimeDelegation(prompt, false, "");
  assert.equal(decision.allow, true, `${prompt} should delegate`);
  return decision;
}

assertBlocked("Can you help me with something?", "vague help request");
assertBlocked("Okay thanks.", "short acknowledgement");

assertBlocked(
  "Find if there is any logo file for Masala Theory in the Downloads folder. The user wants to know if you already figured this out. Check the Downloads folder again.",
  "conversation recall"
);

assertBlockedWhileBusy("Why is it stuck?", "delegated status question");
assertBlockedWhileBusy("Can we check where it is at right now?", "delegated status question");

assertBlocked("Add buy milk to my Today list.", "realtime knowledge tool");

const noteOrganizeTask = assertDelegates("Organize my Calculations note using OpenAssist style with decision and warning callouts.");
assert.equal(
  isHighConfidenceRealtimeDelegation(noteOrganizeTask.prompt, "tool_call"),
  true,
  "note organization should delegate directly without the router"
);

const obviousTask = assertDelegates("Search the Downloads folder for a logo file.");
assert.equal(
  isHighConfidenceRealtimeDelegation(obviousTask.prompt, "tool_call"),
  true,
  "obvious file/tool task should skip the Gemma router"
);
assert.equal(
  isHighConfidenceRealtimeDelegation(obviousTask.prompt, "auto_transcript"),
  true,
  "obvious transcript task should not be dropped if the realtime router is slow"
);

console.log("Realtime delegation router checks passed.");
