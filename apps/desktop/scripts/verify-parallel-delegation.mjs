// Static wiring check for the realtime voice "delegate two tasks in parallel" feature.
// Verifies the proxy tool, shared task registry, no-overlap narration queue,
// and hidden worker threads are wired together.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");

function read(rel) {
  return fs.readFileSync(path.join(root, rel), "utf8");
}

const proxy = read("electron/realtimeProxy.ts");
const bridge = read("electron/openassistBridge.ts");

const checks = [
  ["proxy: tool spec defined", proxy, /realtimeParallelDelegationToolSpec/],
  ["proxy: tool registered in list", proxy, /realtimeParallelDelegationToolSpec\(agentLabel\)/],
  ["proxy: tool name is delegate_parallel_tasks", proxy, /name:\s*"delegate_parallel_tasks"/],
  ["proxy: OpenAI handler branch", proxy, /name === "delegate_parallel_tasks"[\s\S]{0,500}handleParallelDelegation/],
  ["proxy: Gemini handler branch", proxy, /name === "delegate_parallel_tasks"[\s\S]{0,500}startParallelDelegation/],
  ["proxy: narration FIFO queue field", proxy, /parallelResultQueue/],
  ["proxy: drain on response.done", proxy, /flushOpenAIResponseCreate\(\);\s*\n\s*this\.onParallelNarrationEnded\(\);/],
  ["proxy: drain on Gemini audio done", proxy, /finishGeminiAudio[\s\S]{0,400}onParallelNarrationEnded/],
  ["proxy: drain after leaving quiet mode", proxy, /Listening mode is on[\s\S]{0,220}drainParallelResults/],
  ["proxy: config type parallelDelegation", proxy, /parallelDelegation\?:/],
  ["proxy: maxTasks in config type", proxy, /maxTasks: number/],
  ["proxy: schema requires two tasks", proxy, /minItems:\s*2/],
  ["proxy: guard router defined", proxy, /function routeParallelDelegation\(/],
  ["proxy: start goes through guard router", proxy, /startParallelDelegation[\s\S]{0,600}routeParallelDelegation\(/],
  ["proxy: single task reuses background_agent router", proxy, /routeParallelDelegation[\s\S]{0,900}decideRealtimeDelegation\(/],
  ["proxy: recall misuse reroutes to Spark recall", proxy, /personalRecallRerouteOutput\(callID, route\.query/],
  ["proxy: guard exported for router tests", proxy, /__realtimeRouterTestHooks[\s\S]{0,200}routeParallelDelegation/],

  ["bridge: parallel delegation fn defined", bridge, /async function runRealtimeParallelDelegation/],
  ["bridge: wires parallelDelegation config", bridge, /const realtimeParallelDelegation: RealtimeProxyConfig\["parallelDelegation"\]/],
  ["bridge: passes config to proxy", bridge, /realtimeConnectionEvents, realtimeParallelDelegation(?:, [^)]+)?\)/],
  ["bridge: each task gets its own hidden child thread", bridge, /createOpenAssistThread\(projectID, true, true\)\.session\.id/],
  ["bridge: each task sets its own provider", bridge, /await setThreadProvider\(childThreadID, backend\)/],
  ["bridge: awaits all with allSettled", bridge, /Promise\.allSettled\(/],
  ["bridge: parallel cap constant", bridge, /MAX_PARALLEL_REALTIME_DELEGATION = 6/],
  ["bridge: project name resolver", bridge, /function resolveProjectIDByNameOrID/],
  ["bridge: reports each task result", bridge, /reportTaskResult\(\{/],

  // Personal-assistant mode: the shared coordinator owns all task limits,
  // duplicate checks, status, completion, and cancellation.
  ["proxy: background_agent uses the shared handoff starter", proxy, /startCodexHandoff\(callID, decision\.prompt, "message"\)/],
  ["proxy: duplicate running prompts are filtered by coordinator", proxy, /taskCoordinator\.hasActivePrompt\(task\.prompt, this\.taskScopeKey\(\)\)/],
  ["proxy: parallel tasks register with coordinator", proxy, /const started = this\.taskCoordinator\.start\(\{[\s\S]{0,500}kind: "parallel"/],
  ["proxy: completed tasks finish through coordinator", proxy, /this\.taskCoordinator\.complete\(handoff\.taskID, resultText\)/],
  ["proxy: failed tasks finish through coordinator", proxy, /this\.taskCoordinator\.fail\(handoff\.taskID, error\)/],
  ["proxy: finished result names its task when others still run", proxy, /othersStillRunning\s*\?\s*`Finished task: \$\{handoff\.prompt/],
  ["proxy: instructions allow side-by-side tasks", proxy, /tasks run side by side/],
];

let failures = 0;
for (const [label, source, re] of checks) {
  const pass = re.test(source);
  if (!pass) failures += 1;
  console.log(`${pass ? "PASS" : "FAIL"} ${label}`);
}

if (failures > 0) {
  console.error(`\nParallel delegation wiring check FAILED (${failures} missing).`);
  process.exit(1);
}
console.log("\nParallel delegation wiring check passed.");
