// Bench: can Jev (TypeSafe System One) replace the low-confidence delegate
// fallback in voiceRouting.ts:144?
//
// We already have ground truth: scripts/routing-golden-set.mjs is hand-labelled.
// This runs every golden utterance through Jev's `choice` primitive and reports
// accuracy + calibration, so we can see whether a cheap typed decision could
// catch utterances before they wake a full Codex turn.
//
//   TYPESAFE_API_KEY=sk-... node scripts/bench-jev-routing.mjs

import { goldenCases } from "./routing-golden-set.mjs";

const API_KEY = process.env.TYPESAFE_API_KEY;
if (!API_KEY) {
  console.error("Set TYPESAFE_API_KEY first (get one at typesafe.ai → API Keys).");
  process.exit(1);
}

// Mirrors VoiceRouteKind in electron/voiceRouting.ts.
const routeCriteria = {
  control: "Commands that control the voice session itself: stop listening, be quiet, pause.",
  ignore: "Acknowledgements or filler with no request in them: okay thanks, yes please, cool.",
  recall: "Asks what was previously said, decided, or saved to memory in past sessions.",
  read: "Asks to read something that already exists locally: today's list, a note, reminders, the backlog.",
  write: "Asks to change local data: add, complete, re-open, move, rename a task, reminder, or note.",
  delegate: "Needs an agent to execute work: search the live web, run a terminal command, review code.",
  parallel: "Explicitly asks for two or more separate tasks to be handled at the same time."
};

const question = {
  type: "choice",
  instructions:
    "A voice assistant heard this utterance. Which single route should handle it?",
  criteria: routeCriteria
};

async function classify(utterance) {
  const response = await fetch("https://api.typesafe.ai/v1/systemone", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${API_KEY}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      model: "jev-latest",
      state: { utterance },
      questions: { route: question }
    })
  });

  if (!response.ok) {
    throw new Error(`${response.status} ${await response.text()}`);
  }
  return response.json();
}

let correct = 0;
let inputTokens = 0;
let outputTokens = 0;
const misses = [];
const started = Date.now();

for (const testCase of goldenCases) {
  let result;
  try {
    result = await classify(testCase.utterance);
  } catch (error) {
    console.error(`! "${testCase.utterance}" → ${error.message}`);
    continue;
  }

  const answer = result.answers?.route ?? {};
  const picked = answer.choice;
  const confidence = answer.confidence;
  inputTokens += result.usage?.input_tokens ?? 0;
  outputTokens += result.usage?.output_tokens ?? 0;

  const hit = picked === testCase.expect;
  if (hit) correct += 1;
  else misses.push({ ...testCase, picked, confidence });

  const mark = hit ? "✓" : "✗";
  const conf = typeof confidence === "number" ? confidence.toFixed(2) : "?";
  console.log(`${mark} ${conf}  ${testCase.expect.padEnd(8)} ${hit ? "" : `→ got ${picked} `}${testCase.utterance}`);
}

const elapsed = ((Date.now() - started) / 1000).toFixed(1);
console.log(`\n${correct}/${goldenCases.length} correct in ${elapsed}s`);
console.log(`Tokens: ${inputTokens} in, ${outputTokens} out`);
// Published input price: $42 per billion input tokens.
console.log(`Input cost this run: $${((inputTokens / 1e9) * 42).toFixed(8)}`);

if (misses.length) {
  console.log(`\nDisagreements (check whether Jev or the golden label is wrong):`);
  for (const miss of misses) {
    const conf = typeof miss.confidence === "number" ? miss.confidence.toFixed(2) : "?";
    console.log(`  "${miss.utterance}"  expected ${miss.expect}, got ${miss.picked} (confidence ${conf})`);
  }
  console.log(`\nIf the misses are all LOW confidence, a threshold makes this safe:`);
  console.log(`  act on Jev's route when confidence is high, else fall through to Codex.`);
}
