// Round 2: coding reasoning. Real OpenAssist functions, 4 of them deliberately
// broken. Ground truth is objective — the bugs were introduced on purpose.
//
// My verdicts are committed below BEFORE Jev ran.
//
//   TYPESAFE_API_KEY=$(op read "op://Personal/jev_apiKey/notesPlain") \
//     node scripts/jev-vs-opus-code.mjs

const API_KEY = process.env.TYPESAFE_API_KEY;
if (!API_KEY) { console.error("Set TYPESAFE_API_KEY."); process.exit(1); }

const cases = [
  {
    id: "echoes-brief",
    source: "workerResultGuard.ts (unmodified)",
    truth: false, truthType: "none",
    opus: false, opusConf: 0.88, opusType: "none",
    opusWhy: "null-safe, empty guard, plain substring scan — nothing wrong",
    code: `export function workerResultEchoesBrief(text: string): boolean {
  const lowered = String(text ?? "").toLowerCase();
  if (!lowered) return false;
  return briefEchoFragments.some((fragment) => lowered.includes(fragment));
}`
  },
  {
    id: "ack-some",
    source: "voiceRouting.ts (BROKEN: every -> some)",
    truth: true, truthType: "logic",
    opus: true, opusConf: 0.93, opusType: "logic",
    opusWhy: "with some(), 'ok add milk' is silently dropped — a real command lost",
    code: `// Only pure acknowledgements are ignored.
const words = normalized.split(/\\s+/);
if (words.length <= 4 && words.some((word) => ACKNOWLEDGEMENT_WORDS.has(word))) {
  return { kind: "ignore", reason: "short acknowledgement", confidence: "high" };
}`
  },
  {
    id: "validate-clean",
    source: "workerResultGuard.ts (unmodified)",
    truth: false, truthType: "none",
    opus: false, opusConf: 0.80, opusType: "none",
    opusWhy: "correct as written; narrow by design",
    code: `export function validateWorkerResult(input: { text: string; toolActivityCount: number }) {
  const text = String(input.text ?? "");
  if (workerResultEchoesBrief(text)) {
    return { ok: false, reason: "echoed-brief" };
  }
  if (input.toolActivityCount === 0 && workerResultClaimsAction(text)) {
    return { ok: false, reason: "unverified-action-claim" };
  }
  return { ok: true };
}`
  },
  {
    id: "validate-broken",
    source: "workerResultGuard.ts (BROKEN: === 0 -> >= 0)",
    truth: true, truthType: "logic",
    opus: true, opusConf: 0.95, opusType: "logic",
    opusWhy: "count >= 0 is always true — every action claim now rejected, even honest ones",
    code: `export function validateWorkerResult(input: { text: string; toolActivityCount: number }) {
  const text = String(input.text ?? "");
  if (workerResultEchoesBrief(text)) {
    return { ok: false, reason: "echoed-brief" };
  }
  if (input.toolActivityCount >= 0 && workerResultClaimsAction(text)) {
    return { ok: false, reason: "unverified-action-claim" };
  }
  return { ok: true };
}`
  },
  {
    id: "nofollow-clean",
    source: "peerFilesCore.ts (unmodified)",
    truth: false, truthType: "none",
    opus: false, opusConf: 0.74, opusType: "none",
    opusWhy: "O_NOFOLLOW present, fstat after open, closed in finally",
    code: `const descriptor = fs.openSync(stagedPath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
let buffer: Buffer;
try {
  const stat = fs.fstatSync(descriptor);
  if (!stat.isFile()) throw new PeerFileError("not_file", "Not a regular file.");
  buffer = fs.readFileSync(descriptor);
} finally {
  fs.closeSync(descriptor);
}`
  },
  {
    id: "nofollow-broken",
    source: "peerFilesCore.ts (BROKEN: O_NOFOLLOW removed)",
    truth: true, truthType: "security",
    opus: true, opusConf: 0.83, opusType: "security",
    opusWhy: "without O_NOFOLLOW a symlink at stagedPath redirects the read outside the staging dir",
    code: `const descriptor = fs.openSync(stagedPath, fs.constants.O_RDONLY);
let buffer: Buffer;
try {
  const stat = fs.fstatSync(descriptor);
  if (!stat.isFile()) throw new PeerFileError("not_file", "Not a regular file.");
  buffer = fs.readFileSync(descriptor);
} finally {
  fs.closeSync(descriptor);
}`
  },
  {
    id: "leak-broken",
    source: "peerFilesCore.ts (BROKEN: close moved out of finally)",
    truth: true, truthType: "resource",
    opus: true, opusConf: 0.90, opusType: "resource",
    opusWhy: "if readFileSync or the size check throws, the descriptor is never closed",
    code: `const descriptor = fs.openSync(filePath, fs.constants.O_RDONLY);
const stat = fs.fstatSync(descriptor);
if (stat.size > peerFileFetchMaxBytes) {
  throw new PeerFileError("too_large", "File is too large.");
}
const buffer = fs.readFileSync(descriptor);
fs.closeSync(descriptor);
return { size: buffer.length, sha256: sha256OfBuffer(buffer) };`
  },
  {
    id: "claims-action-clean",
    source: "workerResultGuard.ts (unmodified)",
    truth: false, truthType: "none",
    opus: false, opusConf: 0.66, opusType: "none",
    opusWhy: "narrow on purpose; misses phrasings but that is a limitation, not a bug",
    code: `const actionClaimPattern =
  /(^|\\n)\\s*(added|created|scheduled|updated|deleted|removed|moved)\\b|\\bi\\s+(have\\s+|just\\s+|)(added|created|scheduled|updated)\\b/i;

export function workerResultClaimsAction(text: string): boolean {
  return actionClaimPattern.test(String(text ?? ""));
}`
  }
];

async function askJev(code) {
  const started = Date.now();
  const response = await fetch("https://api.typesafe.ai/v1/systemone", {
    method: "POST",
    headers: { Authorization: `Bearer ${API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "jev-latest",
      state: { language: "TypeScript", code },
      questions: {
        has_bug: {
          type: "noul",
          instructions: "Does `code` contain a real defect that would cause wrong behaviour, a crash, a leak, or a security hole?",
          criteria: {
            true: "There is an actual defect: wrong results, a crash, a leak, or a security hole.",
            false: "No real defect. Style, naming, missing comments, or being deliberately narrow are NOT defects."
          }
        },
        bug_type: {
          type: "choice",
          instructions: "What kind of defect, if any?",
          criteria: {
            none: "No real defect.",
            logic: "Wrong condition, operator, or control flow — produces incorrect results.",
            security: "Allows an attacker to read, write, or execute something they should not.",
            resource: "A file handle, socket, or memory is leaked on some path."
          }
        },
        severity: {
          type: "score",
          instructions: "How serious is the worst problem here?",
          criteria: ["No real problem", "Minor — rare or low impact", "Serious — wrong results, leaks, or exploitable"]
        }
      }
    })
  });
  if (!response.ok) throw new Error(`${response.status} ${await response.text()}`);
  return { body: await response.json(), ms: Date.now() - started };
}

const pad = (s, n) => String(s).padEnd(n);
let jevBugRight = 0, jevTypeRight = 0, opusBugRight = 0, totalMs = 0, inputTokens = 0;
const rows = [];

for (const testCase of cases) {
  let jevBug = null, jevConf = null, jevType = "?", jevSeverity = null;
  try {
    const { body, ms } = await askJev(testCase.code);
    const answers = body.answers ?? {};
    jevConf = answers.has_bug?.noul;
    jevBug = typeof jevConf === "number" ? jevConf > 0.5 : null;
    jevType = answers.bug_type?.choice ?? "?";
    jevSeverity = answers.severity?.score;
    totalMs += ms;
    inputTokens += body.usage?.input_tokens ?? 0;
  } catch (error) {
    console.error(`! ${testCase.id}: ${error.message}`);
  }

  if (jevBug === testCase.truth) jevBugRight += 1;
  if (jevType === testCase.truthType) jevTypeRight += 1;
  if (testCase.opus === testCase.truth) opusBugRight += 1;
  rows.push({ ...testCase, jevBug, jevConf, jevType, jevSeverity });
}

console.log(`\n${pad("case", 22)} ${pad("TRUTH", 14)} ${pad("OPUS", 14)} ${pad("JEV", 20)}`);
console.log("-".repeat(74));
for (const row of rows) {
  const truth = `${row.truth ? "BUG" : "ok"}/${row.truthType}`;
  const opus = `${row.opus ? "BUG" : "ok"} ${row.opusConf.toFixed(2)}`;
  const jev = `${row.jevBug ? "BUG" : "ok"} ${typeof row.jevConf === "number" ? row.jevConf.toFixed(2) : "?"}/${row.jevType}`;
  const mark = row.jevBug === row.truth ? " " : "≠";
  console.log(`${mark}${pad(row.id, 21)} ${pad(truth, 14)} ${pad(opus, 14)} ${pad(jev, 20)}`);
}
console.log("-".repeat(74));
console.log(`Bug detected correctly   Opus ${opusBugRight}/${cases.length}   Jev ${jevBugRight}/${cases.length}`);
console.log(`Bug TYPE correct         Jev ${jevTypeRight}/${cases.length}`);
console.log(`Jev: ${(totalMs / 1000).toFixed(1)}s total (${Math.round(totalMs / cases.length)}ms each), ${inputTokens} tokens, $${((inputTokens / 1e9) * 42).toFixed(8)}`);

const misses = rows.filter((row) => row.jevBug !== row.truth);
if (misses.length) {
  console.log(`\nJEV MISSES — was it unsure?\n`);
  for (const miss of misses) {
    console.log(`  ${miss.id} (${miss.source})`);
    console.log(`     truth: ${miss.truth ? "BUG" : "no bug"} / ${miss.truthType}`);
    console.log(`     jev:   ${typeof miss.jevConf === "number" ? miss.jevConf.toFixed(2) : "?"} -> ${miss.jevType}`);
    console.log(`     opus:  ${miss.opusWhy}\n`);
  }
} else {
  console.log(`\nJev matched ground truth on every case.\n`);
}
