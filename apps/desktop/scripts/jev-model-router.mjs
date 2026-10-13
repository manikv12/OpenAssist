// Round 4: can Jev pick WHICH MODEL a task needs?
//
// Two passes over the same 12 tasks:
//   A) menu = capability profiles (how a real router would work)
//   B) menu = bare model names from OpenAssist's roster, no descriptions
//      (can it route on names alone, or does it just guess?)
//
// Prediction, committed before running: A >= 9/12. B lower, less confident.
//
//   TYPESAFE_API_KEY=$(op read "op://Personal/jev_apiKey/notesPlain") \
//     node scripts/jev-model-router.mjs

const API_KEY = process.env.TYPESAFE_API_KEY;
if (!API_KEY) { console.error("Set TYPESAFE_API_KEY."); process.exit(1); }

const capabilityMenu = {
  "fast-cheap":   "Small fast model. Trivial or mechanical work where any model gets it right.",
  "coding":       "Coding specialist. Multi-file edits, builds, tests, scripts, terminal work.",
  "deep":         "Frontier reasoning model. Open-ended analysis, judgement calls, root-cause thinking.",
  "long-context": "Must read a very large amount of material in one go (many documents, huge files).",
  "vision":       "Must look at an image, screenshot, or screen.",
  "local":        "Must run on the user's machine. Data may not leave the computer."
};

// Your real roster, names only. Deliberately no descriptions.
const brandMenu = {
  "gpt-5-mini":     "gpt-5-mini",
  "gpt-5.3-codex":  "gpt-5.3-codex",
  "claude-opus-5":  "claude-opus-5",
  "gemini-3.1-pro": "gemini-3.1-pro",
  "ollama-local":   "ollama-local"
};

// Which brand each capability maps to (this mapping lives in code, not in Jev).
const capToBrand = {
  "fast-cheap": "gpt-5-mini",
  "coding": "gpt-5.3-codex",
  "deep": "claude-opus-5",
  "long-context": "gemini-3.1-pro",
  "vision": "gemini-3.1-pro",
  "local": "ollama-local"
};

const cases = [
  { task: "Fix the typo 'recieve' -> 'receive' in README.md.",                                                  truth: "fast-cheap", opus: "fast-cheap", conf: 0.95 },
  { task: "Re-indent this JSON file with 2 spaces.",                                                           truth: "fast-cheap", opus: "fast-cheap", conf: 0.94 },
  { task: "Answer yes or no: is 17 a prime number?",                                                           truth: "fast-cheap", opus: "fast-cheap", conf: 0.96 },
  { task: "Implement rate-limiting middleware for this Express server and add tests for it.",                  truth: "coding",     opus: "coding",     conf: 0.88 },
  { task: "The TypeScript build is failing with 14 type errors across 5 files. Fix them all.",                truth: "coding",     opus: "coding",     conf: 0.90 },
  { task: "Write a bash script that rotates these log files daily and keeps the last 7.",                     truth: "coding",     opus: "coding",     conf: 0.82 },
  { task: "Checkout conversion dropped 8% after last week's release. Here is the changelog and the metrics. What is the most likely cause?", truth: "deep", opus: "deep", conf: 0.84 },
  { task: "Should we move from REST to GraphQL? Here is our architecture, traffic profile, and team size.",   truth: "deep",       opus: "deep",       conf: 0.86 },
  { task: "Read these 40 meeting transcripts and list every commitment I made.",                              truth: "long-context", opus: "long-context", conf: 0.90 },
  { task: "Here is a 900-page contract. Find every clause about termination.",                                truth: "long-context", opus: "long-context", conf: 0.92 },
  { task: "Here is a screenshot of the error dialog. What is it saying and how do I fix it?",                 truth: "vision",     opus: "vision",     conf: 0.97 },
  { task: "Summarize my therapy journal entries. This must never leave my computer.",                         truth: "local",      opus: "local",      conf: 0.97 }
];

async function ask(task, menu, instructions) {
  const started = Date.now();
  const response = await fetch("https://api.typesafe.ai/v1/systemone", {
    method: "POST",
    headers: { Authorization: `Bearer ${API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "jev-latest",
      state: { task },
      questions: { pick: { type: "choice", instructions, criteria: menu } }
    })
  });
  if (!response.ok) throw new Error(`${response.status} ${await response.text()}`);
  const body = await response.json();
  return { choice: body.answers?.pick?.choice, conf: body.answers?.pick?.confidence, ms: Date.now() - started, tokens: body.usage?.input_tokens ?? 0 };
}

const pad = (s, n) => String(s).padEnd(n);
let aRight = 0, bRight = 0, aConfSum = 0, bConfSum = 0, ms = 0, tokens = 0;
const rows = [];

for (const testCase of cases) {
  const a = await ask(testCase.task, capabilityMenu, "Which kind of model should handle this task?");
  const b = await ask(testCase.task, brandMenu, "Which model should handle this task?");
  ms += a.ms + b.ms; tokens += a.tokens + b.tokens;
  const aOk = a.choice === testCase.truth;
  const bOk = b.choice === capToBrand[testCase.truth];
  if (aOk) aRight += 1;
  if (bOk) bRight += 1;
  aConfSum += a.conf ?? 0; bConfSum += b.conf ?? 0;
  rows.push({ ...testCase, a, b, aOk, bOk });
}

console.log(`${pad("task", 44)} ${pad("TRUTH", 13)} ${pad("A: capability", 20)} B: brand name`);
console.log("-".repeat(100));
for (const r of rows) {
  const aCell = `${r.aOk ? " " : "≠"}${r.a.choice} ${(r.a.conf ?? 0).toFixed(2)}`;
  const bCell = `${r.bOk ? " " : "≠"}${r.b.choice} ${(r.b.conf ?? 0).toFixed(2)}`;
  console.log(`${pad(r.task.slice(0, 42), 44)} ${pad(r.truth, 13)} ${pad(aCell, 20)} ${bCell}`);
}
console.log("-".repeat(100));
console.log(`A (capability menu)  ${aRight}/12   avg confidence ${(aConfSum / 12).toFixed(2)}`);
console.log(`B (brand names only) ${bRight}/12   avg confidence ${(bConfSum / 12).toFixed(2)}`);
console.log(`${(ms / 1000).toFixed(1)}s for 24 calls (${Math.round(ms / 24)}ms each), ${tokens} tokens, $${((tokens / 1e9) * 42).toFixed(8)}`);

const aMiss = rows.filter((r) => !r.aOk);
const bMiss = rows.filter((r) => !r.bOk);
if (aMiss.length) {
  console.log(`\nA misses:`);
  for (const r of aMiss) console.log(`  "${r.task.slice(0, 60)}"  truth ${r.truth}, got ${r.a.choice} (${(r.a.conf ?? 0).toFixed(2)})`);
}
if (bMiss.length) {
  console.log(`\nB misses:`);
  for (const r of bMiss) console.log(`  "${r.task.slice(0, 60)}"  truth ${capToBrand[r.truth]}, got ${r.b.choice} (${(r.b.conf ?? 0).toFixed(2)})`);
}
