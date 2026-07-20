import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

// Behavioral test for the Live Voice recall router. It extracts the real,
// current routing functions from realtimeProxy.ts (so the test cannot drift
// from the source) and runs memory-question phrasings through them.

const proxyPath = path.resolve("electron/realtimeProxy.ts");
const proxyText = fs.readFileSync(proxyPath, "utf8");

function extractFunction(name) {
  const marker = `function ${name}(`;
  const start = proxyText.indexOf(marker);
  assert.ok(start >= 0, `Missing function ${name} in realtimeProxy.ts`);
  let depth = 0;
  let index = proxyText.indexOf("{", start);
  assert.ok(index >= 0, `Malformed function ${name}`);
  for (; index < proxyText.length; index += 1) {
    const char = proxyText[index];
    if (char === "{") depth += 1;
    if (char === "}") {
      depth -= 1;
      if (depth === 0) break;
    }
  }
  return proxyText.slice(start, index + 1);
}

const functionNames = [
  "normalizeRealtimeIntent",
  "hasCurrentConversationScope",
  "hasPersonalRecallSourceScope",
  "hasAgentRecallSubject",
  "looksLikeExternalLookupTask",
  "requiresAgentExecution",
  "asksForPastLookupResult",
  "hasExplicitRecallSubject",
  "isBroadWorkHistoryQuestion",
  "isExplicitRealtimeRerunRequest",
  "isMemoryWriteRequest",
  "asksAboutStoredMemories",
  "asksWhatAgentRemembers",
  "conversationRecallRoute",
  "recallRouteForToolCall"
];

const source = functionNames
  .map(extractFunction)
  .join("\n\n")
  // These helpers are plain regex functions; strip the TS annotations so the
  // extracted source runs as plain JS.
  .replace(/:\s*ConversationRecallRoute\b/g, "")
  .replace(/:\s*string\b/g, "");

const sandbox = new Function(`${source}\nreturn { conversationRecallRoute, recallRouteForToolCall };`)();
const { conversationRecallRoute, recallRouteForToolCall } = sandbox;

// 1. Possessive/state memory questions must route to personal recall.
const personalPhrases = [
  "what memory do I have from codex",
  "what memories do I have from codex",
  "what memory do you have from codex",
  "what memories are saved from codex",
  "do I have any memory from codex",
  "do you have any memories saved from codex",
  "what's in my codex memory",
  "what does codex remember about me",
  "list my saved memories",
  "show me my memories from codex",
  "what memories have been saved",
  "tell me what memory you have from codex",
  "what do you know about me from memory",
  // regressions: verb-based phrasings that already worked
  "do you remember what codex said",
  "what did codex say about the sync feature",
  "check my memory for the sync plan",
  "search my saved memories",
  "what did we decide about the planner",
  "did we talk about mac sync",
  "read my codex memory",
  "What were we working on in Codex yesterday?",
  "So, what was the note that you added last time?",
  "Last time, what note did you create?"
];
for (const phrase of personalPhrases) {
  assert.equal(conversationRecallRoute(phrase), "personal", `Expected personal: "${phrase}"`);
}

// 2. Memory writes and non-recall tasks must NOT route to recall.
const nonePhrases = [
  "save this to memory",
  "add a memory that I prefer short answers",
  "forget that memory",
  "delete the memory about my email",
  "check online for the latest memory prices",
  "check the open source project",
  "fix the session timeout bug",
  "open the browser and check the website"
];
for (const phrase of nonePhrases) {
  assert.equal(conversationRecallRoute(phrase), "none", `Expected none: "${phrase}"`);
}

// 3. Current-conversation scope still wins.
assert.equal(conversationRecallRoute("what did we decide in this chat"), "current");

// 4. Tool-call guard checks BOTH the model query and the raw utterance.
assert.equal(
  recallRouteForToolCall("saved user memories originating from codex sessions", "what memory do I have from codex"),
  "personal",
  "Utterance must rescue a rephrased model query"
);
assert.equal(
  recallRouteForToolCall("what was the note you added last time", "Hej"),
  "personal",
  "A recall tool call may arrive just before the completed transcript updates the latest utterance"
);
assert.equal(
  recallRouteForToolCall("what did we decide", "what did we decide in this chat"),
  "current",
  "User-stated current scope must win"
);
// Trust clause: model chose recall and the text plainly mentions memory.
assert.equal(recallRouteForToolCall("memories from codex", ""), "personal");
// But writes and external lookups are still vetoed.
assert.equal(recallRouteForToolCall("save this to memory", ""), "none");
assert.equal(recallRouteForToolCall("check the website for the latest news", ""), "none");

// 5. Both provider veto sites must use the two-text guard, not the raw route.
const geminiGuard = /const query = stringValue\(effectiveArgs\.query, effectiveArgs\.question, effectiveArgs\.prompt, effectiveArgs\.text\);\s*\n\s*const recallRoute = recallRouteForToolCall\(query, this\.geminiInputTranscript \|\| this\.lastUserUtterance\);/;
const openAIGuard = /const query = stringValue\(effectiveArgs\.query, effectiveArgs\.question, effectiveArgs\.prompt, effectiveArgs\.text\);\s*\n\s*const recallRoute = recallRouteForToolCall\(query, this\.lastUserUtterance\);/;
assert.ok(geminiGuard.test(proxyText), "Gemini personal-recall guard must use recallRouteForToolCall with the transcript");
assert.ok(openAIGuard.test(proxyText), "OpenAI personal-recall guard must use recallRouteForToolCall with the utterance");

console.log("verify:recall-route passed");
