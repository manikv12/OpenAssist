import assert from "node:assert/strict";
import {
  decideWorkerModelRole,
  resolveWorkerModel
} from "../dist-electron/liveVoice/workerModelPolicy.js";
import {
  delegatedWorkArgumentsFromToolArgs,
  delegatedWorkerToolSelection,
  explicitlyRequestsComputerUse,
  preferredComputerUsePluginID
} from "../dist-electron/liveVoice/workerToolPolicy.js";
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

assert.equal(explicitlyRequestsComputerUse("Ask Codex to use Computer Use in Reminders."), true);
const disabledComputerUse = delegatedWorkerToolSelection({
  prompt: "Create the reminder.",
  userText: "Use Computer Use for this.",
  computerUseEnabled: false
});
assert.equal(
  disabledComputerUse.ok,
  false,
  "A disabled Computer Use request must fail before a worker can pretend it ran."
);
// Assert the message's meaning, not its exact wording: it must name the real
// setting and explicitly rule out worker models, because the voice model was
// paraphrasing a vague refusal into "no Live Voice work model selected".
assert.match(disabledComputerUse.error ?? "", /Computer Use is turned off/i);
assert.match(disabledComputerUse.error ?? "", /Allow Computer Use when requested/i);
assert.match(disabledComputerUse.error ?? "", /Automation & Remote/i);
assert.match(disabledComputerUse.error ?? "", /not a model or Live Voice worker-model problem/i);
const computerUseSelection = delegatedWorkerToolSelection({
  prompt: "Create the reminder.",
  userText: "Use Computer Use for this.",
  computerUseEnabled: true
});
assert.equal(computerUseSelection.ok, true);
if (!computerUseSelection.ok) throw new Error("Computer Use selection failed.");
assert.deepEqual(computerUseSelection.pluginIDs, [preferredComputerUsePluginID]);
assert.equal(computerUseSelection.computerUseSelected, true);
assert.deepEqual(
  delegatedWorkerToolSelection({
    prompt: "Check the current documentation.",
    computerUseEnabled: true
  }),
  { ok: true, pluginIDs: [], computerUseSelected: false },
  "Unrelated delegated work must not receive Computer Use."
);

const parsedDelegation = delegatedWorkArgumentsFromToolArgs({
  goal: "Create the reminder using the requested worker.",
  mode: "rerun",
  taskID: "task-finished",
  tasks: [{
    prompt: "Create the repeating reminder.",
    executionProfile: {
      depth: "auto",
      complexity: "simple",
      impact: "reversible_write",
      stakes: "normal",
      modelPreference: "sol"
    }
  }],
  executionProfile: {
    depth: "auto",
    complexity: "simple",
    impact: "reversible_write",
    stakes: "normal",
    modelPreference: "sol"
  }
}, "Please use Sol and Computer Use for this reminder.");
assert.equal(parsedDelegation.userText, "Please use Sol and Computer Use for this reminder.");
assert.equal(parsedDelegation.mode, "rerun");
assert.equal(parsedDelegation.taskID, "task-finished");
assert.equal(parsedDelegation.executionProfile?.modelPreference, "sol");
assert.equal(parsedDelegation.tasks?.[0]?.executionProfile?.modelPreference, "sol");
assert.equal(
  decideWorkerModelRole({
    userText: parsedDelegation.userText ?? "",
    profile: parsedDelegation.tasks?.[0]?.executionProfile
  }).role,
  "deep",
  "The exact finalized model request and execution profile must survive tool parsing."
);

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
