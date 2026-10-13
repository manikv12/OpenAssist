// Round 3: can Jev pick the right reasoning effort for a task?
//
// This is the test that decides whether the "Jev routes effort, Opus does the
// work" idea is real. Difficulty is a SURFACE property of a request — unlike
// bug-hunting, it needs no hidden scenario to be discovered. So my prediction,
// committed before this ran: Jev should do WELL here (>= 9/12).
//
//   TYPESAFE_API_KEY=$(op read "op://Personal/jev_apiKey/notesPlain") \
//     node scripts/jev-effort-router.mjs

const API_KEY = process.env.TYPESAFE_API_KEY;
if (!API_KEY) { console.error("Set TYPESAFE_API_KEY."); process.exit(1); }

const LEVELS = ["low", "high", "max"];

// Mapped to Anthropic's own guidance: low for mechanical/simple work, high for
// intelligence-sensitive work, max when correctness matters more than cost.
const levelText = [
  "Mechanical. One obvious correct answer. No analysis needed.",
  "Needs real analysis: several factors to weigh, or a cause to track down.",
  "Correctness matters more than cost: subtle, wide blast radius, expensive to get wrong."
];

const cases = [
  { task: "Rename the variable `tmp` to `buffer` throughout this file.",                  truth: "low",  opus: "low",  conf: 0.95 },
  { task: "Add a JSDoc comment describing what this function returns.",                   truth: "low",  opus: "low",  conf: 0.93 },
  { task: "What does the regex /^\\d{3}-\\d{4}$/ match?",                                 truth: "low",  opus: "low",  conf: 0.94 },
  { task: "Change the request timeout from 3500ms to 5000ms.",                            truth: "low",  opus: "low",  conf: 0.96 },
  { task: "Convert this .then() promise chain to async/await.",                           truth: "low",  opus: "low",  conf: 0.84 },
  { task: "Why does this test pass on my machine but fail in CI?",                        truth: "high", opus: "high", conf: 0.82 },
  { task: "Add pagination to this REST endpoint that currently returns all rows.",        truth: "high", opus: "high", conf: 0.79 },
  { task: "This worker leaks memory under sustained load. Find the cause and fix it.",    truth: "high", opus: "high", conf: 0.71 },
  { task: "Refactor the auth flow to support SSO without invalidating existing sessions.", truth: "max", opus: "max",  conf: 0.80 },
  { task: "Design a database migration that runs with zero downtime on a live table.",    truth: "max",  opus: "max",  conf: 0.86 },
  { task: "Our voice router misclassifies 5% of utterances. Redesign the classifier.",    truth: "max",  opus: "max",  conf: 0.68 },
  { task: "Review whether this AES encryption implementation is actually secure.",        truth: "max",  opus: "max",  conf: 0.77 }
];

async function askJev(task) {
  const started = Date.now();
  const response = await fetch("https://api.typesafe.ai/v1/systemone", {
    method: "POST",
    headers: { Authorization: `Bearer ${API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "jev-latest",
      state: { task },
      questions: {
        // Native shape for an ordered spectrum.
        difficulty: {
          type: "score",
          instructions: "How much careful reasoning does this task need before an answer can be trusted?",
          criteria: levelText
        },
        // Same judgement forced through Choice, to see which primitive fits better.
        effort: {
          type: "choice",
          instructions: "Which reasoning effort setting should a coding model use for this task?",
          criteria: { low: levelText[0], high: levelText[1], max: levelText[2] }
        }
      }
    })
  });
  if (!response.ok) throw new Error(`${response.status} ${await response.text()}`);
  return { body: await response.json(), ms: Date.now() - started };
}

const pad = (s, n) => String(s).padEnd(n);
let scoreRight = 0, choiceRight = 0, opusRight = 0, totalMs = 0, inputTokens = 0;
const rows = [];
let printedLegend = false;

for (const testCase of cases) {
  let raw = null, viaScore = "?", viaChoice = "?", choiceConf = null, scoreConf = null;
  try {
    const { body, ms } = await askJev(testCase.task);
    const answers = body.answers ?? {};
    raw = answers.difficulty?.score;
    scoreConf = answers.difficulty?.confidence;
    if (!printedLegend && answers.difficulty?.legend) {
      console.log(`score legend: ${JSON.stringify(answers.difficulty.legend)}\n`);
      printedLegend = true;
    }
    if (typeof raw === "number") {
      viaScore = LEVELS[Math.min(LEVELS.length - 1, Math.max(0, Math.round(raw)))] ?? "?";
    }
    viaChoice = answers.effort?.choice ?? "?";
    choiceConf = answers.effort?.confidence;
    totalMs += ms;
    inputTokens += body.usage?.input_tokens ?? 0;
  } catch (error) {
    console.error(`! ${testCase.task.slice(0, 40)}: ${error.message}`);
  }

  if (viaScore === testCase.truth) scoreRight += 1;
  if (viaChoice === testCase.truth) choiceRight += 1;
  if (testCase.opus === testCase.truth) opusRight += 1;
  rows.push({ ...testCase, raw, viaScore, viaChoice, choiceConf, scoreConf });
}

console.log(`${pad("task", 52)} ${pad("TRUTH", 7)} ${pad("OPUS", 7)} ${pad("JEV-score", 16)} JEV-choice`);
console.log("-".repeat(104));
for (const row of rows) {
  const scoreCell = `${row.viaScore}${typeof row.raw === "number" ? ` (${row.raw.toFixed(2)})` : ""}`;
  const choiceCell = `${row.viaChoice}${typeof row.choiceConf === "number" ? ` ${row.choiceConf.toFixed(2)}` : ""}`;
  const mark = row.viaChoice === row.truth ? " " : "≠";
  console.log(`${mark}${pad(row.task.slice(0, 50), 51)} ${pad(row.truth, 7)} ${pad(row.opus, 7)} ${pad(scoreCell, 16)} ${choiceCell}`);
}
console.log("-".repeat(104));
console.log(`Opus        ${opusRight}/${cases.length}   (I wrote the labels, so this is not a fair score for me)`);
console.log(`Jev Score   ${scoreRight}/${cases.length}`);
console.log(`Jev Choice  ${choiceRight}/${cases.length}`);
console.log(`${(totalMs / 1000).toFixed(1)}s total (${Math.round(totalMs / cases.length)}ms each), ${inputTokens} tokens, $${((inputTokens / 1e9) * 42).toFixed(8)}`);

// The money question: what would routing on Jev actually have saved?
const wouldRunLow = rows.filter((row) => row.viaChoice === "low").length;
const wrongLow = rows.filter((row) => row.viaChoice === "low" && row.truth !== "low");
console.log(`\nIf you routed on Jev's Choice:`);
console.log(`  ${wouldRunLow}/${cases.length} tasks would run at LOW effort instead of the default HIGH.`);
console.log(`  ${wrongLow.length} of those actually needed more:`);
for (const row of wrongLow) console.log(`    ! "${row.task.slice(0, 60)}" (really ${row.truth})`);
if (!wrongLow.length) console.log(`    none — no task was downgraded below what it needed.`);
