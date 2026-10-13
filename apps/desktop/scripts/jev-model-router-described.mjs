// Round 5: brand names WITH capability descriptions.
//   C) honest descriptions  -> does it pick correctly now?
//   D) SWAPPED descriptions -> does it follow the description or the name?
// Prediction: C >= 11/12 high conf. D >= 9/12 lower conf.

const API_KEY = process.env.TYPESAFE_API_KEY;
if (!API_KEY) { console.error("Set TYPESAFE_API_KEY."); process.exit(1); }

const D = {
  cheap:  "Small, fast, cheap model. Trivial or mechanical work where any model gets it right.",
  coding: "Coding specialist. Multi-file edits, builds, tests, scripts, terminal work.",
  deep:   "Frontier reasoning model. Open-ended analysis, judgement calls, root-cause thinking. Normal context size, no images.",
  big:    "Handles very large inputs in one go (many documents, huge files) and can look at images and screenshots.",
  local:  "Runs entirely on the user's machine. Data never leaves the computer."
};

const honest = {
  "gpt-5-mini": D.cheap, "gpt-5.3-codex": D.coding, "claude-opus-5": D.deep, "gemini-3.1-pro": D.big, "ollama-local": D.local
};
// Swap mini<->opus and codex<->ollama. gemini unchanged.
const swapped = {
  "gpt-5-mini": D.deep, "gpt-5.3-codex": D.local, "claude-opus-5": D.cheap, "gemini-3.1-pro": D.big, "ollama-local": D.coding
};
const truthHonest  = { cheap: "gpt-5-mini", coding: "gpt-5.3-codex", deep: "claude-opus-5", big: "gemini-3.1-pro", local: "ollama-local" };
const truthSwapped = { cheap: "claude-opus-5", coding: "ollama-local", deep: "gpt-5-mini", big: "gemini-3.1-pro", local: "gpt-5.3-codex" };

const cases = [
  { task: "Fix the typo 'recieve' -> 'receive' in README.md.", need: "cheap" },
  { task: "Re-indent this JSON file with 2 spaces.", need: "cheap" },
  { task: "Answer yes or no: is 17 a prime number?", need: "cheap" },
  { task: "Implement rate-limiting middleware for this Express server and add tests for it.", need: "coding" },
  { task: "The TypeScript build is failing with 14 type errors across 5 files. Fix them all.", need: "coding" },
  { task: "Write a bash script that rotates these log files daily and keeps the last 7.", need: "coding" },
  { task: "Checkout conversion dropped 8% after last week's release. Here is the changelog and the metrics. What is the most likely cause?", need: "deep" },
  { task: "Should we move from REST to GraphQL? Here is our architecture, traffic profile, and team size.", need: "deep" },
  { task: "Read these 40 meeting transcripts and list every commitment I made.", need: "big" },
  { task: "Here is a 900-page contract. Find every clause about termination.", need: "big" },
  { task: "Here is a screenshot of the error dialog. What is it saying and how do I fix it?", need: "big" },
  { task: "Summarize my therapy journal entries. This must never leave my computer.", need: "local" }
];

async function ask(task, menu) {
  const started = Date.now();
  const r = await fetch("https://api.typesafe.ai/v1/systemone", {
    method: "POST",
    headers: { Authorization: `Bearer ${API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: "jev-latest", state: { task },
      questions: { pick: { type: "choice", instructions: "Which model should handle this task? Judge by each model's description.", criteria: menu } } })
  });
  if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
  const b = await r.json();
  return { choice: b.answers?.pick?.choice, conf: b.answers?.pick?.confidence ?? 0, ms: Date.now() - started, tokens: b.usage?.input_tokens ?? 0 };
}

const pad = (s, n) => String(s).padEnd(n);
let cR = 0, dR = 0, cC = 0, dC = 0, ms = 0, tok = 0; const rows = [];
for (const t of cases) {
  const c = await ask(t.task, honest), d = await ask(t.task, swapped);
  ms += c.ms + d.ms; tok += c.tokens + d.tokens;
  const cOk = c.choice === truthHonest[t.need], dOk = d.choice === truthSwapped[t.need];
  if (cOk) cR++; if (dOk) dR++; cC += c.conf; dC += d.conf;
  rows.push({ ...t, c, d, cOk, dOk });
}
console.log(`${pad("task", 40)} ${pad("need", 7)} ${pad("C: named+described", 26)} D: descriptions SWAPPED`);
console.log("-".repeat(104));
for (const r of rows) {
  console.log(`${pad(r.task.slice(0, 38), 40)} ${pad(r.need, 7)} ${pad(`${r.cOk ? " " : "≠"}${r.c.choice} ${r.c.conf.toFixed(2)}`, 26)} ${r.dOk ? " " : "≠"}${r.d.choice} ${r.d.conf.toFixed(2)}  (should be ${truthSwapped[r.need]})`);
}
console.log("-".repeat(104));
console.log(`C  ${cR}/12   avg confidence ${(cC / 12).toFixed(2)}`);
console.log(`D  ${dR}/12   avg confidence ${(dC / 12).toFixed(2)}   <- follows description if high, follows NAME if low`);
console.log(`${(ms / 1000).toFixed(1)}s, ${tok} tokens, $${((tok / 1e9) * 42).toFixed(8)}`);
