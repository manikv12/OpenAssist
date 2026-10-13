// Round 7: lean scout on Cerebras (qwen-3.8-27b) explores the local repo,
// then Jev picks capability + effort from the scout's triage.
//
//   CEREBRAS_API_KEY=$(op read "op://Personal/cerebras_APIKey/notesPlain") \
//   TYPESAFE_API_KEY=$(op read "op://Personal/jev_apiKey/notesPlain") \
//     node scripts/jev-cerebras-scout.mjs

import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";

const CB = process.env.CEREBRAS_API_KEY, JV = process.env.TYPESAFE_API_KEY;
if (!CB || !JV) { console.error("Need CEREBRAS_API_KEY and TYPESAFE_API_KEY."); process.exit(1); }
const ROOT = process.cwd();
const MODEL = "qwen-3.8-27b";

const requests = [
  "make the worker guard catch more fake completions",
  "make dictation paste faster"
];

// ---------- deterministic facts (no model) ----------
const sh = (c) => execSync(c, { cwd: ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
const tree = sh("git ls-files electron src scripts | grep -E '\\.(ts|tsx|mjs)$' | grep -v '\\.d\\.ts$'").split("\n").slice(0, 350);
const gitFacts = {
  modified_files: sh("git status --porcelain | wc -l").trim(),
  recent_commits: sh("git log -5 --pretty=%s").split("\n")
};

// ---------- Cerebras (OpenAI-compatible) ----------
const cb = { calls: 0, in: 0, out: 0, ms: 0 };
async function qwen(messages, maxTokens = 1200) {
  const t0 = Date.now();
  const r = await fetch("https://api.cerebras.ai/v1/chat/completions", {
    method: "POST", headers: { Authorization: `Bearer ${CB}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: MODEL, messages, temperature: 0.2, max_tokens: maxTokens, reasoning_effort: "none" })
  });
  if (!r.ok) throw new Error(`cerebras ${r.status} ${await r.text()}`);
  const j = await r.json();
  cb.calls++; cb.in += j.usage?.prompt_tokens ?? 0; cb.out += j.usage?.completion_tokens ?? 0; cb.ms += Date.now() - t0;
  const msg = j.choices?.[0]?.message ?? {};
  cb.reasoningChars = (cb.reasoningChars ?? 0) + String(msg.reasoning ?? "").length;
  const text = String(msg.content ?? "").replace(/<think>[\s\S]*?<\/think>/g, "").trim();
  if (!text) console.log(`  (cerebras returned empty content; finish=${j.choices?.[0]?.finish_reason}, out=${j.usage?.completion_tokens})`);
  return text;
}

// ---------- Jev ----------
const jv = { calls: 0, in: 0, ms: 0 };
async function jev(state, instructions, criteria) {
  const t0 = Date.now();
  const r = await fetch("https://api.typesafe.ai/v1/systemone", {
    method: "POST", headers: { Authorization: `Bearer ${JV}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: "jev-latest", state, questions: { pick: { type: "choice", instructions, criteria } } })
  });
  if (!r.ok) throw new Error(`jev ${r.status} ${await r.text()}`);
  const j = await r.json();
  jv.calls++; jv.in += j.usage?.input_tokens ?? 0; jv.ms += Date.now() - t0;
  const a = j.answers?.pick ?? {};
  return { choice: a.choice, conf: a.confidence ?? 0, probs: a.probabilities ?? {} };
}
const effortMenu = {
  low:  "Mechanical. One obvious correct answer. No analysis needed.",
  high: "Needs real analysis: several factors to weigh, or a cause to track down.",
  max:  "Correctness matters more than cost: subtle, wide blast radius, expensive to get wrong."
};
const capMenu = {
  "fast-cheap": "Small fast model. Trivial or mechanical work where any model gets it right.",
  "coding":     "Coding specialist. Multi-file edits, builds, tests, scripts, terminal work.",
  "deep":       "Frontier reasoning model. Open-ended analysis, judgement calls, root-cause thinking.",
  "big":        "Must read a very large amount of material in one go, or look at images.",
  "local":      "Must run on the user's machine; data may not leave the computer."
};

const readHead = (rel, lines = 120) => {
  try {
    const p = path.join(ROOT, rel);
    if (!fs.existsSync(p)) return null;
    const txt = fs.readFileSync(p, "utf8").split("\n");
    const total = txt.length;
    // If the file is huge, grab the head plus lines matching request keywords.
    let recent = [];
    try { recent = sh(`git log -3 --pretty=%s -- "${rel}"`).split("\n").filter(Boolean); } catch {}
    return { rel, total_lines: total, recent, head: txt.slice(0, lines).join("\n").slice(0, 6000) };
  } catch { return null; }
};

function parseJSON(text) {
  const m = text.match(/\{[\s\S]*\}/);
  try { return JSON.parse(m ? m[0] : text); } catch { return null; }
}

for (const request of requests) {
  const t0 = Date.now();
  console.log(`\n${"=".repeat(90)}\nREQUEST: "${request}"\n${"=".repeat(90)}`);

  // Round 1: pick files to read.
  const pickText = await qwen([
    { role: "system", content: "You are a code scout. You will be given a user request and a list of files in a repo. Pick the files most likely relevant. Reply with JSON only: {\"files\": [\"path\", ...], \"why\": \"one sentence\"}. At most 5 files. No prose outside the JSON." },
    { role: "user", content: `Request: ${request}\n\nRepo facts: ${JSON.stringify(gitFacts)}\n\nFiles:\n${tree.join("\n")}` }
  ], 1500);
  let pick = parseJSON(pickText);
  if (!pick || !Array.isArray(pick.files) || !pick.files.length) {
    // Recover real paths from a truncated/prose answer; only accept paths that exist in the tree.
    const found = tree.filter((f) => pickText.includes(f));
    pick = { files: found.slice(0, 5), why: (pick && pick.why) || "(recovered from truncated output)" };
  } else {
    pick.files = pick.files.filter((f) => tree.includes(f));
  }
  const chosen = (pick.files ?? []).slice(0, 5).map((f) => readHead(f)).filter(Boolean);
  console.log(`scout picked ${chosen.length} file(s): ${chosen.map((c) => `${c.rel} (${c.total_lines} lines)`).join(", ")}`);
  console.log(`why: ${pick.why}`);

  // Round 2: triage from the excerpts.
  const triageText = await qwen([
    { role: "system", content: "You are a code scout writing a triage for a router. Do NOT propose a fix. Be concrete and short. IMPORTANT: separate what the code ALREADY does (from the excerpts and recent commits) from what would have to CHANGE for this request. Never restate existing behaviour as new work. If the excerpts show the request is largely already implemented, say so and keep estimated_diff_lines small. Output exactly:\nFILES: <comma list>\nEXISTING: <one line: what the code already does about this>\nCHANGE: <one line: what must actually change>\nSCOPE: <one line>\nRISK: <one line>\nSUMMARY: <one paragraph on what the task actually involves>\nFACTS: <JSON: {\"files_involved\": n, \"estimated_diff_lines\": n, \"touches\": \"...\", \"needs_tests\": true|false, \"crosses_process_boundary\": true|false}>" },
    { role: "user", content: `Request: ${request}\n\nRepo facts: ${JSON.stringify(gitFacts)}\n\n` + chosen.map((c) => `--- ${c.rel} (first ${Math.min(120, c.total_lines)} of ${c.total_lines} lines) | recent commits: ${c.recent.join(" | ") || "none"}\n${c.head}`).join("\n\n") }
  ], 2500);
  let triageFinal = triageText;
  if (!triageFinal) {
    triageFinal = `FILES: ${chosen.map((c) => c.rel).join(", ")}\nSCOPE: (scout produced no text; deterministic fallback)\nRISK: unknown\nSUMMARY: Request touches ${chosen.length} file(s) totalling ${chosen.reduce((n, c) => n + c.total_lines, 0)} lines.\nFACTS: {"files_involved": ${chosen.length}, "estimated_diff_lines": null, "touches": "${chosen.map((c) => c.rel).join("; ")}", "needs_tests": null, "crosses_process_boundary": null}`;
  }
  const factsMatch = triageFinal.match(/FACTS:\s*(\{[\s\S]*)/);
  let facts = null;
  if (factsMatch) {
    const raw = factsMatch[1].trim();
    for (const cand of [raw, raw + "}", raw + "\"}", raw.replace(/,\s*$/, "") + "}"]) { facts = parseJSON(cand); if (facts) break; }
  }
  console.log(`\n--- triage (${MODEL}) ---\n${triageFinal.replace(/FACTS:[\s\S]*$/, "").trim()}\nFACTS: ${JSON.stringify(facts)}`);

  // Jev decisions on request + triage.
  const state = { request, triage: triageFinal, facts, repo: gitFacts };
  const eff = await jev(state, "How much reasoning effort should the coding model spend on this task?", effortMenu);
  const cap = await jev(state, "Which kind of model should handle this task?", capMenu);
  const fmt = (p) => Object.entries(p).map(([k, v]) => `${k}:${(+v).toFixed(2)}`).join(" ");
  console.log(`\n--- Jev ---\neffort:     ${eff.choice} (${eff.conf.toFixed(2)})   [${fmt(eff.probs)}]\ncapability: ${cap.choice} (${cap.conf.toFixed(2)})   [${fmt(cap.probs)}]`);
  console.log(`request wall time: ${((Date.now() - t0) / 1000).toFixed(1)}s`);
}

console.log(`\n${"=".repeat(90)}\nTOTALS`);
console.log(`Cerebras ${MODEL}: ${cb.calls} calls, ${cb.in} in / ${cb.out} out tokens, ${(cb.ms / 1000).toFixed(1)}s model time, reasoning chars: ${cb.reasoningChars ?? 0}`);
console.log(`Cerebras cost @ $0.99/M in, $1.49/M out: ${((cb.in * 0.99 + cb.out * 1.49) / 1e6).toFixed(5)}`);
console.log(`Jev: ${jv.calls} calls, ${jv.in} tokens, ${(jv.ms / 1000).toFixed(1)}s, $${((jv.in / 1e9) * 42).toFixed(6)}`);
console.log(`For comparison, the Haiku full-session scout on request #1 was: $0.065, 16.7s, 214k cached tokens.`);
