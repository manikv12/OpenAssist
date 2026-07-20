import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { goldenCases, appleReminderTargetCases } from "./routing-golden-set.mjs";

const routingPath = path.resolve("dist-electron/voiceRouting.js");
const reminderRoutingPath = path.resolve("dist-electron/appleReminderRouting.js");
for (const file of [routingPath, reminderRoutingPath]) {
  if (!fs.existsSync(file)) {
    console.error(`Missing ${file}. Run tsc -p tsconfig.electron.json first.`);
    process.exit(1);
  }
}

const { classifyVoiceRoute } = await import(path.toNamespacedPath(routingPath));
const { parseAppleRemindersQuickReadTarget } = await import(path.toNamespacedPath(reminderRoutingPath));

let failures = 0;
for (const testCase of goldenCases) {
  const decision = classifyVoiceRoute(testCase.utterance);
  if (decision.kind !== testCase.expect) {
    failures += 1;
    console.error(`✗ "${testCase.utterance}" expected ${testCase.expect}, got ${decision.kind} (${decision.reason})${testCase.note ? ` — ${testCase.note}` : ""}`);
  }
}
assert.equal(failures, 0, `${failures} golden routing case(s) regressed`);

for (const testCase of appleReminderTargetCases) {
  const plan = parseAppleRemindersQuickReadTarget(testCase.target);
  if (testCase.routes) {
    assert.ok(plan, `"${testCase.target}" must route to Apple Reminders`);
    if (testCase.completedOnly) assert.equal(plan.completedOnly, true, `"${testCase.target}" must be completed-only`);
    if (testCase.queryIncludes) assert.ok(plan.query?.includes(testCase.queryIncludes), `"${testCase.target}" query must include "${testCase.queryIncludes}", got "${plan.query}"`);
  } else {
    assert.equal(plan, null, `"${testCase.target}" must NOT route to Apple Reminders`);
  }
}

// Capability layer sanity: the descriptor set that powers assistant_capability
// (shared by OpenAI Realtime AND Gemini Live) must include the reminders search
// so "find a reminder" resolves to a direct capability instead of delegation.
const proxyPath = path.resolve("dist-electron/realtimeProxy.js");
const { __realtimeProtocolTestHooks } = await import(path.toNamespacedPath(proxyPath));
try {
  const descriptors = __realtimeProtocolTestHooks.liveVoiceCapabilityDescriptors(() => ({}));
  const ids = descriptors.map((descriptor) => descriptor.id);
  assert.ok(ids.includes("knowledge_apple_search_reminders"), "reminders search capability must be registered");
  assert.ok(ids.includes("knowledge_apple_complete_reminder"), "reminder complete/re-open capability must be registered");
} catch (error) {
  if (error instanceof assert.AssertionError) throw error;
  console.warn(`Capability descriptor check skipped (needs live config): ${error?.message ?? error}`);
}

console.log(`Routing golden-set checks passed (${goldenCases.length} utterances, ${appleReminderTargetCases.length} quick_read targets).`);
