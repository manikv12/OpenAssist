import fs from "node:fs";
import path from "node:path";

const root = path.resolve(".");
const proxy = fs.readFileSync(path.join(root, "electron/realtimeProxy.ts"), "utf8");
const bridge = fs.readFileSync(path.join(root, "electron/openassistBridge.ts"), "utf8");
const renderer = fs.readFileSync(path.join(root, "src/App.tsx"), "utf8");

const checks = [
  ["proxy: answer-bearing tools are classified", proxy, /function isAnswerBearingRealtimeTool\(name: string\)[\s\S]*background_agent[\s\S]*delegate_parallel_tasks[\s\S]*knowledge_/],
  ["proxy: OpenAI gates tool-call output_item.added", proxy, /event\.type === "response\.output_item\.added"[\s\S]{0,220}gateAnswerBearingToolSpeech\(event, item\)/],
  ["proxy: OpenAI gates tool-call output_item.done", proxy, /event\.type === "response\.output_item\.done"[\s\S]{0,220}gateAnswerBearingToolSpeech\(event, item\)[\s\S]{0,160}handleFunctionCall\(item\)/],
  ["proxy: gated OpenAI audio deltas are dropped", proxy, /response\.output_audio\.delta[\s\S]{0,220}shouldDropGatedOpenAIAudio\(event\)[\s\S]{0,180}dropped gated OpenAI audio delta/],
  ["proxy: gated response clears renderer audio buffer", proxy, /gateAnswerBearingToolSpeech[\s\S]{0,500}output_audio_buffer\.cleared/],
  ["proxy: tool gate clears after response.done", proxy, /event\.type === "response\.done"[\s\S]{0,2400}clearToolGate\("response\.done"\)/],
  ["proxy: Gemini tool calls enter toolPending", proxy, /onGeminiToolCalls\(functionCalls: unknown\[\]\)[\s\S]{0,1200}toolGateDropActive = true[\s\S]{0,250}transition\("toolPending"/],
  ["proxy: Gemini gated audio is dropped", proxy, /sendGeminiAudioDelta\(audio: Buffer\)[\s\S]{0,420}if \(this\.toolGateDropActive\) return;/],
  ["bridge: realtime state snapshots reach renderer", bridge, /type: "thread\/realtime\/state"[\s\S]{0,1000}snapshot: connectionEvent\.snapshot/],
  ["renderer: voice phase and foreground work are read separately", renderer, /type === "thread\/realtime\/state"[\s\S]{0,1800}snapshot\.voicePhase[\s\S]{0,1800}snapshot\.foregroundWork/],
  // A second, DIFFERENT edit to the same task must not be vetoed as a duplicate
  // ("make them subtasks" right after "add the details" was skipped, and the
  // model then falsely claimed the subtasks were already made).
  ["proxy: targeted edits skip the task-text dedupe key", proxy, /const isTargetedEdit = name === "knowledge_update_daily_item"\s*\n\s*\|\| name === "knowledge_complete_daily_item";[\s\S]{0,120}if \(!isTargetedEdit\) \{/],
  ["proxy: duplicate veto tells the model nothing new was written", proxy, /Do NOT tell the user you just made a change — nothing new was written\./],
  ["proxy: instructions map subtasks to the steps array", proxy, /subtasks, sub-items, sub-checkboxes, or a checklist UNDER an existing task[\s\S]{0,200}`steps` array of knowledge_update_daily_item/]
];

let failures = 0;
for (const [label, source, pattern] of checks) {
  const pass = pattern.test(source);
  console.log(`${pass ? "PASS" : "FAIL"} ${label}`);
  if (!pass) failures += 1;
}

if (failures > 0) {
  console.error(`\nRealtime tool-gate check FAILED (${failures} missing).`);
  process.exit(1);
}

console.log("\nRealtime tool-gate check passed.");
