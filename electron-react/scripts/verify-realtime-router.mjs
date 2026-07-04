import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const proxyPath = path.resolve("dist-electron/realtimeProxy.js");

if (!fs.existsSync(proxyPath)) {
  console.error("Missing dist-electron/realtimeProxy.js. Run npm run build first.");
  process.exit(1);
}

const { __realtimeRouterTestHooks } = await import(path.toNamespacedPath(proxyPath));
const { decideRealtimeDelegation, isHighConfidenceRealtimeDelegation, routeParallelDelegation } = __realtimeRouterTestHooks;

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

function assertDelegatesWithPrior(prompt, lastDelegationPrompt) {
  const decision = decideRealtimeDelegation(prompt, false, lastDelegationPrompt);
  assert.equal(decision.allow, true, `${prompt} should delegate with previous task context`);
  return decision;
}

assertBlocked("Can you help me with something?", "vague help request");
assertBlocked("Okay thanks.", "short acknowledgement");

assertBlocked(
  "Find if there is any logo file for Masala Theory in the Downloads folder. The user wants to know if you already figured this out. Check the Downloads folder again.",
  "conversation recall"
);
const recallDecision = assertBlocked("Where are we on the Quality Nails Google Ads plan?", "conversation recall");
assert.match(
  recallDecision.output,
  /knowledge_personal_recall/,
  "recall questions should route to the Spark personal recall tool, not background_agent"
);
const ambiguousRecallDecision = assertBlocked("What did we work on yesterday?", "ambiguous recall scope");
assert.match(
  ambiguousRecallDecision.output,
  /this thread.*all saved memory/i,
  "broad work-history questions should ask for scope before searching"
);
const currentThreadRecallDecision = assertBlocked("What did we work on yesterday in this thread?", "current conversation recall");
assert.doesNotMatch(
  currentThreadRecallDecision.output,
  /knowledge_personal_recall/,
  "current-thread questions should not route to personal recall"
);
const scopedWorkRecallDecision = assertBlocked("What did we work on yesterday for Quality Nails?", "conversation recall");
assert.match(
  scopedWorkRecallDecision.output,
  /knowledge_personal_recall/,
  "project-scoped work-history questions should route to personal recall"
);
const didWorkRecallDecision = assertBlocked("Did we work on anything for Quality Nails?", "conversation recall");
assert.match(
  didWorkRecallDecision.output,
  /knowledge_personal_recall/,
  "natural past-work questions should route to personal recall without requiring the user to say Codex thread"
);
const chatRecallDecision = assertBlocked("Check the chat that we had yesterday.", "conversation recall");
assert.match(
  chatRecallDecision.output,
  /knowledge_personal_recall/,
  "saved chat lookup requests should route to personal recall"
);
const openAssistMemoryRecallDecision = assertBlocked(
  "What did we work on yesterday on OpenAssist? Can you check through my memory?",
  "conversation recall"
);
assert.match(
  openAssistMemoryRecallDecision.output,
  /knowledge_personal_recall/,
  "memory-scoped OpenAssist work-history questions should route to Spark personal recall"
);
assert.equal(
  isHighConfidenceRealtimeDelegation("What did Spark say about the Airbnb process?", "tool_call"),
  false,
  "agent-result recall should not auto-delegate"
);

assertBlocked("Can you prompt it to check online?", "vague follow-up");
const onlineTask = assertDelegatesWithPrior(
  "Can you prompt it to check online?",
  "I want you to look into my memory. What did I work on? Open Assist."
);
assert.notStrictEqual(
  onlineTask.reason,
  "conversation recall",
  "online check requests should not route to personal recall"
);
const codexOnlineTask = assertDelegatesWithPrior(
  "Can you ask Codex to check online for it?",
  "I want you to look into my memory. What did I work on? Open Assist."
);
assert.notStrictEqual(
  codexOnlineTask.reason,
  "conversation recall",
  "mentioning Codex for a new online task should not route to personal recall"
);
const sparkLookupTask = assertDelegates(
  "Can you check using Spark if there is any marriage registered in the name of Vedika Singh in Greene County Springfield MO?"
);
assert.notStrictEqual(
  sparkLookupTask.reason,
  "conversation recall",
  "using Spark for a new lookup should not route to personal recall"
);
const backlinksOnlineTask = assertDelegates("Can you check Quality Nails backlinks online?");
assert.notStrictEqual(
  backlinksOnlineTask.reason,
  "conversation recall",
  "current online checks should not route to personal recall"
);
const plainBacklinksTask = assertDelegates("Can you check Quality Nails backlinks?");
assert.notStrictEqual(
  plainBacklinksTask.reason,
  "conversation recall",
  "current work checks should not route to personal recall just because the subject has old memories"
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

// delegate_parallel_tasks guard: it must not be a side door around the
// background_agent router.
function parallelTasks(...prompts) {
  return prompts.map((prompt) => ({ prompt }));
}

const emptyParallel = routeParallelDelegation([], false);
assert.equal(emptyParallel.action, "output", "empty parallel call should ask what to run");

const twoRealTasks = routeParallelDelegation(
  parallelTasks(
    "Search the Downloads folder for a logo file.",
    "Check the Quality Nails repo for broken links and fix them."
  ),
  false
);
assert.equal(twoRealTasks.action, "proceed", "two real tasks should delegate in parallel");
assert.equal(twoRealTasks.tasks.length, 2, "both tasks should survive the guard");

const singleRealTask = routeParallelDelegation(
  parallelTasks("Search the Downloads folder for a logo file."),
  false
);
assert.equal(singleRealTask.action, "proceed", "a single real task should still run");

const singleRecallTask = routeParallelDelegation(
  parallelTasks("Where are we on the Quality Nails Google Ads plan?"),
  false
);
assert.equal(singleRecallTask.action, "recall", "a single recall question must reroute to Spark personal recall, not delegate");

const singleVagueTask = routeParallelDelegation(parallelTasks("Can you help me with something?"), false);
assert.equal(singleVagueTask.action, "output", "a vague single task must not delegate");
assert.equal(singleVagueTask.reason, "vague help request");

const singleAckTask = routeParallelDelegation(parallelTasks("Okay thanks."), false);
assert.equal(singleAckTask.action, "output", "a short acknowledgement must not delegate");

const singleStatusTask = routeParallelDelegation(parallelTasks("Why is it stuck?"), true);
assert.equal(singleStatusTask.action, "output", "a status question while busy must not delegate");
assert.equal(singleStatusTask.reason, "delegated status question");

const singleImageTask = routeParallelDelegation(
  parallelTasks("Generate a logo image for Masala Theory."),
  false
);
assert.equal(singleImageTask.action, "image", "image requests should reroute to Codex image generation");

const splitRecallTasks = routeParallelDelegation(
  parallelTasks(
    "What did Codex say about the Airbnb process?",
    "What did we decide earlier about the Quality Nails plan?"
  ),
  false
);
assert.equal(splitRecallTasks.action, "recall", "a recall question split into fake parallel tasks must reroute to personal recall");

console.log("Realtime delegation router checks passed.");
