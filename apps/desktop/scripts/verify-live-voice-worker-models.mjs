import assert from "node:assert/strict";
import {
  decideWorkerModelRole,
  resolveWorkerModel
} from "../dist-electron/liveVoice/workerModelPolicy.js";
import { RealtimeTaskCoordinator } from "../dist-electron/realtimeTaskCoordinator.js";

const catalog = [
  { id: "gpt-5.3-codex-spark", supportedReasoningEfforts: ["low", "medium", "high"] },
  { id: "gpt-5.6-sol", supportedReasoningEfforts: ["medium", "high"] },
  { id: "gpt-5.5-sol", supportedReasoningEfforts: ["medium", "high"] }
];

const fast = decideWorkerModelRole({
  userText: "Check the current public documentation.",
  profile: { depth: "auto", complexity: "simple", impact: "read_only", stakes: "normal" }
});
assert.equal(fast.role, "fast");
assert.equal(fast.reasoningEffort, "medium");
assert.equal(resolveWorkerModel({ decision: fast, catalog }).modelID, "gpt-5.3-codex-spark");

for (const profile of [
  { depth: "deep" },
  { complexity: "complex" },
  { stakes: "high" },
  { impact: "sensitive_write" }
]) {
  const decision = decideWorkerModelRole({ userText: "Handle this carefully.", profile });
  const resolved = resolveWorkerModel({ decision, catalog });
  assert.equal(decision.role, "deep");
  assert.equal(resolved.reasoningEffort, "high");
  assert.equal(resolved.modelID, "gpt-5.6-sol");
}

const explicitSpark = decideWorkerModelRole({
  userText: "Use Spark for this high-stakes check.",
  profile: { stakes: "high", modelPreference: "spark" }
});
assert.equal(explicitSpark.role, "fast");
assert.equal(explicitSpark.explicitlySelected, true);

const unverifiedSpark = decideWorkerModelRole({
  userText: "Handle this high-stakes check.",
  profile: { stakes: "high", modelPreference: "spark" }
});
assert.equal(unverifiedSpark.role, "deep", "A model preference not present in the finalized transcript must be ignored.");

const explicitSol = decideWorkerModelRole({
  userText: "Please run this with the Sol model.",
  profile: { complexity: "simple", modelPreference: "sol" }
});
assert.equal(explicitSol.role, "deep");
assert.equal(explicitSol.explicitlySelected, true);

assert.equal(resolveWorkerModel({
  decision: fast,
  catalog,
  fastOverride: "gpt-5.6-sol"
}).modelID, "gpt-5.6-sol", "An exact advanced override is honored without changing the role's reasoning policy.");

assert.throws(
  () => resolveWorkerModel({ decision: fast, catalog, fastOverride: "missing-model" }),
  /not available/i
);
assert.throws(
  () => resolveWorkerModel({ decision: { ...fast, role: "deep", reasoningEffort: "high" }, catalog: [catalog[0]] }),
  /No available Sol model/i
);

const coordinator = new RealtimeTaskCoordinator();
const started = coordinator.start({
  taskID: "task-fast",
  prompt: "Check current docs.",
  workerProvider: "Codex",
  executionProfile: { depth: "fast", complexity: "simple", impact: "read_only", stakes: "normal" }
});
assert.equal(started.ok, true);
if (!started.ok) throw new Error("Task did not start.");
coordinator.updateWorkerModel(started.task.taskID, resolveWorkerModel({ decision: fast, catalog }));
const task = coordinator.get(started.task.taskID);
assert.equal(task?.workerModelRole, "fast");
assert.equal(task?.workerModelID, "gpt-5.3-codex-spark");
assert.equal(task?.workerReasoningEffort, "medium");

console.log("Live Voice worker model routing verification passed.");
