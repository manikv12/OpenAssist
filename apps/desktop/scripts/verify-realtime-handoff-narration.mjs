import fs from "node:fs";
import path from "node:path";

const root = path.resolve(".");
const proxy = fs.readFileSync(path.join(root, "electron/realtimeProxy.ts"), "utf8");

const forbiddenPromptSnippets = [
  "Only speak the delegated task result if the message starts with",
  "When you see [Agent task finished]",
  "When you see [BACKEND]"
];

const checks = [
  ["proxy: direct speech helper exists", proxy, /function directSpeechInstructions\(output: string, agentLabel: string\)[\s\S]*Answer the user with this \$\{label\} result now/],
  ["proxy: delegated function output is non-answer placeholder", proxy, /function delegatedTaskFunctionOutput\(agentLabel: string\)[\s\S]*The proxy will narrate the result separately/],
  ["proxy: agent results use direct speech narration", proxy, /sendAgentResultMessage\(output: string, agentLabel: string\)[\s\S]{0,500}directSpeechInstructions\(output, agentLabel\)/],
  ["proxy: Gemini agent results do not rely on tool output narration", proxy, /this\.isGeminiLive\(\)[\s\S]{0,220}sendGeminiText\(directSpeechInstructions\(output, agentLabel\)\)/],
  ["proxy: OpenAI agent result function output uses placeholder", proxy, /function_call_output[\s\S]{0,350}output: options\.agentResult \? delegatedTaskFunctionOutput\(agentLabel\) : output/],
  ["proxy: Gemini agent result function output uses placeholder", proxy, /const text = options\.agentResult \? delegatedTaskFunctionOutput\(agentLabel\) : output/],
  ["proxy: delegated start acknowledgement is natural and provider-neutral", proxy, /function delegatedTaskStartedText\(_agentLabel: string\)[\s\S]{0,180}I'm checking that now\. I'll let you know as soon as I have the answer\./],
  ["proxy: direct OpenAI replies claim the turn", proxy, /if \(completedTranscript\) \{[\s\S]{0,500}claimVoiceTurn\("direct"/],
  ["proxy: direct Gemini replies claim the turn", proxy, /beginContinuityUser\("geminiLive"[\s\S]{0,180}claimVoiceTurn\("direct"/],
  ["proxy: delegated OpenAI narration is not saved as a second turn", proxy, /wasDelegatedResultNarration[\s\S]{0,900}skipped continuity persistence for delegated OpenAI narration/],
  ["proxy: delegated Gemini narration is not saved as a second turn", proxy, /finishGeminiTurn\(\)[\s\S]{0,1400}skipped continuity persistence for delegated Gemini narration/],
  ["proxy: completed spoken output cancels the audio retry", proxy, /if \(completedTranscript\) \{[\s\S]{0,120}clearOpenAIDirectResultAudioRetry\(\)/],
  ["proxy: auto delegation yields to a reply already in progress", proxy, /runAutoHandoff\(transcript: string, turnID: string\)[\s\S]{0,700}openAIOutputTranscript\.trim\(\)[\s\S]{0,120}geminiOutputTranscript\.trim\(\)[\s\S]{0,220}skipped automatic delegation because the assistant already started a direct reply/]
];

let failures = 0;
for (const snippet of forbiddenPromptSnippets) {
  const pass = !proxy.includes(snippet);
  console.log(`${pass ? "PASS" : "FAIL"} proxy: no legacy magic prompt snippet "${snippet}"`);
  if (!pass) failures += 1;
}

for (const [label, source, pattern] of checks) {
  const pass = pattern.test(source);
  console.log(`${pass ? "PASS" : "FAIL"} ${label}`);
  if (!pass) failures += 1;
}

if (failures > 0) {
  console.error(`\nRealtime handoff narration check FAILED (${failures} missing).`);
  process.exit(1);
}

console.log("\nRealtime handoff narration check passed.");
