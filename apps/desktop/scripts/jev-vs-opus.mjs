// Head-to-head: Opus 5 vs Jev on the same routing questions.
//
// FAIRNESS NOTE: these 12 utterances are NOT in routing-golden-set.mjs and have
// no pre-existing labels. My answers below were written and committed BEFORE
// Jev ran even once. Neither side is ground truth — where we disagree, Manik
// decides who is right.
//
//   TYPESAFE_API_KEY=$(op read "op://Personal/jev_apiKey/credential") \
//     node scripts/jev-vs-opus.mjs

const API_KEY = process.env.TYPESAFE_API_KEY;
if (!API_KEY) {
  console.error('Set TYPESAFE_API_KEY. With 1Password:');
  console.error('  TYPESAFE_API_KEY=$(op read "op://Personal/jev_apiKey/credential") node scripts/jev-vs-opus.mjs');
  process.exit(1);
}

// The menu — your 7 route kinds, plus the escape hatch so neither of us is
// forced into a wrong answer when the utterance fits nothing.
const routeCriteria = {
  control: "Controls the voice session itself: stop listening, be quiet, pause, cancel.",
  ignore: "Filler or acknowledgement with no request: okay thanks, never mind, cool.",
  recall: "Asks what was previously said, decided, found, or saved in past sessions.",
  read: "Asks to read something that already exists locally: today's list, a note, reminders, backlog.",
  write: "Asks to change local data: add, complete, re-open, move, rename a task, reminder, or note.",
  delegate: "Needs an agent to execute work: search the live web, run a terminal command, review code.",
  parallel: "Explicitly asks for two or more separate tasks handled at the same time.",
  other: "None of the above, or too unclear to place."
};

// ---- MY ANSWERS, LOCKED IN BEFORE SEEING JEV'S ----
// confidence is my own honest 0-1, so my calibration gets tested too.
const cases = [
  { utterance: "Did I already add milk to the list?",              opus: "read",     conf: 0.92, why: "question about existing state; 'add' is a decoy" },
  { utterance: "Remind me what I said about the tax deadline.",     opus: "recall",   conf: 0.90, why: "'remind me what I said' = memory, not creating a reminder" },
  { utterance: "Search my notes for the wifi password.",            opus: "read",     conf: 0.88, why: "local search; 'search' does not imply web" },
  { utterance: "Look up the latest router firmware online.",        opus: "delegate", conf: 0.94, why: "explicit live web lookup" },
  { utterance: "Never mind.",                                       opus: "ignore",   conf: 0.95, why: "cancellation filler, no task" },
  { utterance: "Actually make that tomorrow instead.",              opus: "write",    conf: 0.72, why: "follow-up edit, but depends on prior context" },
  { utterance: "What did Codex find yesterday?",                    opus: "recall",   conf: 0.89, why: "asks about a past session result" },
  { utterance: "Check my email and also add a task to call mom.",   opus: "parallel", conf: 0.85, why: "two distinct tasks joined by 'and also'" },
  { utterance: "Mark it done.",                                     opus: "write",    conf: 0.88, why: "mutation verb, vague target but still a write" },
  { utterance: "Are you still there?",                              opus: "ignore",   conf: 0.61, why: "genuinely unsure — could be control" },
  { utterance: "Can you stop adding things to my Today list?",      opus: "control",  conf: 0.44, why: "LOW: a standing behaviour instruction, fits no kind well" },
  { utterance: "Put the dentist thing somewhere I'll see it.",      opus: "write",    conf: 0.70, why: "vague, but it asks for a change" }
];

async function askJev(utterance) {
  const started = Date.now();
  const response = await fetch("https://api.typesafe.ai/v1/systemone", {
    method: "POST",
    headers: { Authorization: `Bearer ${API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "jev-latest",
      state: { utterance },
      questions: {
        route: {
          type: "choice",
          instructions: "A voice assistant heard this utterance. Which single route should handle it?",
          criteria: routeCriteria
        }
      }
    })
  });
  if (!response.ok) throw new Error(`${response.status} ${await response.text()}`);
  const body = await response.json();
  return { body, ms: Date.now() - started };
}

const pad = (s, n) => String(s).padEnd(n);
let agreed = 0;
let inputTokens = 0;
let totalMs = 0;
const disagreements = [];

console.log(`\n${pad("utterance", 46)} ${pad("OPUS", 16)} ${pad("JEV", 16)}`);
console.log("-".repeat(80));

for (const testCase of cases) {
  let jevPick = "ERROR";
  let jevConf = null;
  try {
    const { body, ms } = await askJev(testCase.utterance);
    const answer = body.answers?.route ?? {};
    jevPick = answer.choice ?? "?";
    jevConf = answer.confidence;
    inputTokens += body.usage?.input_tokens ?? 0;
    totalMs += ms;
  } catch (error) {
    console.error(`  ! ${testCase.utterance} -> ${error.message}`);
  }

  const same = jevPick === testCase.opus;
  if (same) agreed += 1;
  else disagreements.push({ ...testCase, jevPick, jevConf });

  const fmt = (kind, conf) =>
    `${kind}${typeof conf === "number" ? ` ${conf.toFixed(2)}` : ""}`;

  console.log(
    `${same ? " " : "≠"}${pad(testCase.utterance.slice(0, 44), 45)} ${pad(fmt(testCase.opus, testCase.conf), 16)} ${pad(fmt(jevPick, jevConf), 16)}`
  );
}

console.log("-".repeat(80));
console.log(`Agreed on ${agreed}/${cases.length}`);
console.log(`Jev total time: ${(totalMs / 1000).toFixed(1)}s  (${Math.round(totalMs / cases.length)}ms each)`);
console.log(`Jev input tokens: ${inputTokens}  ->  $${((inputTokens / 1e9) * 42).toFixed(8)}`);

if (disagreements.length) {
  console.log(`\nWHERE WE DISAGREE — you decide who is right:\n`);
  for (const d of disagreements) {
    const jc = typeof d.jevConf === "number" ? d.jevConf.toFixed(2) : "?";
    console.log(`  "${d.utterance}"`);
    console.log(`     Opus: ${d.opus} (${d.conf.toFixed(2)}) — ${d.why}`);
    console.log(`     Jev:  ${d.jevPick} (${jc})\n`);
  }
}

console.log(`THE REAL QUESTION: on the ones Jev got wrong, was its confidence LOW?`);
console.log(`If yes, its confidence is honest and you can trust a threshold.`);
console.log(`If it was confidently wrong, do not use it for routing.\n`);
