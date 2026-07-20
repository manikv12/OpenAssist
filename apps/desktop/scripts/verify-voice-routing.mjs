import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const routingPath = path.resolve("dist-electron/voiceRouting.js");

if (!fs.existsSync(routingPath)) {
  console.error("Missing dist-electron/voiceRouting.js. Run npm run build first.");
  process.exit(1);
}

const { classifyVoiceRoute, todayTaskSourceSelection } = await import(path.toNamespacedPath(routingPath));

const cases = [
  ["Add buy milk to my Today list.", "write"],
  ["What memory do I have about the client launch plan?", "recall"],
  ["Do I have any pending task today?", "read"],
  ["Do I have anything in my to-do list for today?", "read"],
  ["Check the user's to-do list for today.", "read"],
  ["Can you stop listening?", "control"],
  ["Check downloads and summarize the note at the same time.", "parallel"],
  ["Okay thanks.", "ignore"],
  ["Can you check online for the latest Codex update?", "delegate"],
  ["Use the Acme Ledger CLI and check its logs.", "delegate"],
  // Short confirmations that CONTAIN an acknowledgement word but carry a
  // command must not be dropped as acknowledgements (regression: the first
  // classifier ignored any <=4-word utterance containing ok/yes/no/thanks).
  ["Yes run it.", "delegate"],
  ["Ok add milk.", "write"],
  ["No.", "ignore"],
  ["Yes please.", "ignore"]
];

for (const [prompt, expectedKind] of cases) {
  const decision = classifyVoiceRoute(prompt);
  assert.equal(
    decision.kind,
    expectedKind,
    `${prompt} expected ${expectedKind}, got ${decision.kind} (${decision.reason})`
  );
}

assert.deepEqual(todayTaskSourceSelection("Do I have anything in my to-do list for today?"), {
  matches: true,
  includeOpenAssist: true,
  includeAppleReminders: true
});
assert.deepEqual(todayTaskSourceSelection("Show only OpenAssist Today tasks."), {
  matches: true,
  includeOpenAssist: true,
  includeAppleReminders: false
});
assert.deepEqual(todayTaskSourceSelection("Show only Apple Reminders for today."), {
  matches: true,
  includeOpenAssist: false,
  includeAppleReminders: true
});
assert.deepEqual(todayTaskSourceSelection("Show my Apple Reminders for today."), {
  matches: true,
  includeOpenAssist: false,
  includeAppleReminders: true
});
assert.deepEqual(todayTaskSourceSelection("What is on my OpenAssist Today list?"), {
  matches: true,
  includeOpenAssist: true,
  includeAppleReminders: false
});

console.log("Voice routing checks passed.");
