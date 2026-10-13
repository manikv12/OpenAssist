// Round 6: real-world requests are vague. Same sentence, different reality.
//   bare     = only what the user typed
//   enriched = + cheap structural facts the harness already has (no model needed)
// Prediction: bare -> low confidence or one-size-fits-all guess;
//             enriched -> correct effort, high confidence.

const API_KEY = process.env.TYPESAFE_API_KEY;
if (!API_KEY) { console.error("Set TYPESAFE_API_KEY."); process.exit(1); }

const effortMenu = {
  low:  "Mechanical. One obvious correct answer. No analysis needed.",
  high: "Needs real analysis: several factors to weigh, or a cause to track down.",
  max:  "Correctness matters more than cost: subtle, wide blast radius, expensive to get wrong."
};

// Same words, different worlds.
const cases = [
  { said: "fix the test", truth: "low",
    facts: { files_involved: 1, diff_lines: 4, test_runs: "fails 10/10, deterministic", error: "Expected 'receive' but got 'recieve'", touches: "string literal in a test file" } },
  { said: "fix the test", truth: "max",
    facts: { files_involved: 3, diff_lines: 0, test_runs: "fails 4/10, intermittent", error: "Timeout after 5000ms waiting for worker to drain", touches: "async worker pool, shared queue" } },
  { said: "make it faster", truth: "low",
    facts: { files_involved: 1, diff_lines: 0, evidence: "EXPLAIN shows sequential scan on 2M rows; column has no index", touches: "one SQL query" } },
  { said: "make it faster", truth: "max",
    facts: { files_involved: 40, diff_lines: 0, evidence: "p99 latency 2.1s across 6 services; profiler inconclusive", touches: "request path through cache, auth, and two databases" } },
  { said: "clean this up", truth: "low",
    facts: { files_involved: 1, diff_lines: 0, evidence: "12 lint warnings: unused imports, inconsistent quotes", touches: "one 80-line utility file" } },
  { said: "clean this up", truth: "high",
    facts: { files_involved: 9, diff_lines: 0, evidence: "duplicated business logic across 3 modules with slightly different edge cases", touches: "billing calculations" } }
];

async function ask(state) {
  const r = await fetch("https://api.typesafe.ai/v1/systemone", {
    method: "POST",
    headers: { Authorization: `Bearer ${API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: "jev-latest", state,
      questions: { effort: { type: "choice", instructions: "How much reasoning effort should a coding model spend on this task?", criteria: effortMenu } } })
  });
  if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
  const b = await r.json();
  return { choice: b.answers?.effort?.choice, conf: b.answers?.effort?.confidence ?? 0 };
}

const pad = (s, n) => String(s).padEnd(n);
let bareRight = 0, richRight = 0, bareConf = 0, richConf = 0;
console.log(`${pad("user said", 16)} ${pad("TRUTH", 6)} ${pad("BARE (sentence only)", 22)} ENRICHED (+ cheap facts)`);
console.log("-".repeat(80));
for (const c of cases) {
  const bare = await ask({ request: c.said });
  const rich = await ask({ request: c.said, ...c.facts });
  const bOk = bare.choice === c.truth, rOk = rich.choice === c.truth;
  if (bOk) bareRight++; if (rOk) richRight++;
  bareConf += bare.conf; richConf += rich.conf;
  console.log(`${pad(`"${c.said}"`, 16)} ${pad(c.truth, 6)} ${pad(`${bOk ? " " : "≠"}${bare.choice} ${bare.conf.toFixed(2)}`, 22)} ${rOk ? " " : "≠"}${rich.choice} ${rich.conf.toFixed(2)}`);
}
console.log("-".repeat(80));
console.log(`BARE      ${bareRight}/6   avg confidence ${(bareConf / 6).toFixed(2)}`);
console.log(`ENRICHED  ${richRight}/6   avg confidence ${(richConf / 6).toFixed(2)}`);
