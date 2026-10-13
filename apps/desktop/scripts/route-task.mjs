#!/usr/bin/env node
// route-task: scout (Qwen on Cerebras) -> Jev routes model+effort -> claude -p runs
//             -> verify claim vs evidence (git diff + tools + Jev) -> escalate once -> log.
//
//   CEREBRAS_API_KEY=$(op read "op://Personal/cerebras_APIKey/notesPlain") \
//   TYPESAFE_API_KEY=$(op read "op://Personal/jev_apiKey/notesPlain") \
//     node scripts/route-task.mjs --repo /path/to/repo [--dry] [--model X] [--effort Y] "fix the failing test"

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execSync, spawn } from "node:child_process";

// ---------- args ----------
const argv = process.argv.slice(2);
const opt = { repo: process.cwd(), dry: false, model: null, effort: null, maxTurns: 25 };
const taskParts = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--repo") opt.repo = path.resolve(argv[++i]);
  else if (a === "--dry") opt.dry = true;
  else if (a === "--model") opt.model = argv[++i];
  else if (a === "--effort") opt.effort = argv[++i];
  else if (a === "--max-turns") opt.maxTurns = Number(argv[++i]);
  else taskParts.push(a);
}
const task = taskParts.join(" ").trim();
if (!task) { console.error("usage: route-task.mjs [--repo dir] [--dry] [--model m] [--effort e] \"task\""); process.exit(1); }
const CB = process.env.CEREBRAS_API_KEY, JV = process.env.TYPESAFE_API_KEY;
if (!JV) { console.error("TYPESAFE_API_KEY required"); process.exit(1); }
if (!CB) console.log("(no CEREBRAS_API_KEY — skipping scout, routing on structural facts only)");

const ROOT = opt.repo;
const sh = (c, cwd = ROOT) => { try { return execSync(c, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch { return ""; } };
const section = (t) => console.log(`\n${"─".repeat(78)}\n${t}\n${"─".repeat(78)}`);

// ---------- policy (the only place model names live) ----------
const CAP_TO_MODEL = { "fast-cheap": "haiku", coding: "sonnet", deep: "opus", big: "opus" };
const EFFORT_TIERS = ["low", "high", "max"];
const MODEL_TIERS = ["haiku", "sonnet", "opus"];
const CONFIDENT = 0.8;               // only downgrade with confidence >= this
const SAFE_EFFORT = "high", SAFE_CAP = "coding";

// ---------- 1. deterministic facts ----------
const tree = sh("git ls-files | grep -E '\\.(ts|tsx|js|jsx|mjs|py|go|rs|swift|json|md)$' | grep -v node_modules").split("\n").filter(Boolean).slice(0, 350);
const keywords = [...new Set(task.toLowerCase().match(/[a-z][a-z0-9_-]{3,}/g) ?? [])].filter((w) => !["make","with","from","that","this","when","then","into","fix","the","and","for"].includes(w)).slice(0, 4);
const grepHits = keywords.length ? sh(`git grep -il ${keywords.map((k) => `-e '${k}'`).join(" ")} -- 2>/dev/null | head -20`).split("\n").filter(Boolean) : [];
const gitFacts = {
  repo: path.basename(ROOT),
  files_in_tree: tree.length,
  modified_files: Number(sh("git status --porcelain | wc -l") || 0),
  recent_commits: sh("git log -5 --pretty=%s").split("\n").filter(Boolean),
  test_command: fs.existsSync(path.join(ROOT, "package.json")) ? (JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8")).scripts?.test ?? null) : null,
  keyword_hits: grepHits
};
const testStatus = gitFacts.test_command ? (() => { const out = sh("npm test 2>&1 | grep -E '^(ℹ|#) (pass|fail)'") + "\n" + sh("npm test 2>&1 | tail -12"); const f = out.match(/(?:#|ℹ) fail (\d+)/), p = out.match(/(?:#|ℹ) pass (\d+)/); return { pass: p ? +p[1] : null, fail: f ? +f[1] : null, tail: out.slice(-600) }; })() : null;
if (testStatus) gitFacts.tests_before = { pass: testStatus.pass, fail: testStatus.fail };

// ---------- 2. scout (Qwen on Cerebras) ----------
const cb = { in: 0, out: 0, ms: 0 };
async function qwen(messages, maxTokens) {
  const t0 = Date.now();
  const r = await fetch("https://api.cerebras.ai/v1/chat/completions", { method: "POST", headers: { Authorization: `Bearer ${CB}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: "qwen-3.8-27b", messages, temperature: 0.2, max_tokens: maxTokens, reasoning_effort: "none" }) });
  if (!r.ok) throw new Error(`cerebras ${r.status} ${await r.text()}`);
  const j = await r.json(); cb.in += j.usage?.prompt_tokens ?? 0; cb.out += j.usage?.completion_tokens ?? 0; cb.ms += Date.now() - t0;
  return String(j.choices?.[0]?.message?.content ?? "").trim();
}
const parseJSON = (t) => { const m = t.match(/\{[\s\S]*\}/); try { return JSON.parse(m ? m[0] : t); } catch { return null; } };
async function scout() {
  if (!CB) return { triage: null, facts: null, files: grepHits.slice(0, 5) };
  const pickText = await qwen([
    { role: "system", content: "You are a code scout. Given a request and a file list, pick the files most likely relevant. Reply with JSON only: {\"files\": [...], \"why\": \"one sentence\"}. At most 5 files." },
    { role: "user", content: `Request: ${task}\nRepo facts: ${JSON.stringify(gitFacts)}\nFiles:\n${tree.join("\n")}` }
  ], 1200);
  let pick = parseJSON(pickText);
  if (!pick || !Array.isArray(pick.files) || !pick.files.length) pick = { files: tree.filter((f) => pickText.includes(f)).slice(0, 5), why: "(recovered)" };
  pick.files = [...new Set([...pick.files.filter((f) => tree.includes(f)), ...grepHits])].slice(0, 5);
  const excerpts = pick.files.map((rel) => { const p = path.join(ROOT, rel); if (!fs.existsSync(p)) return null; const lines = fs.readFileSync(p, "utf8").split("\n");
    return { rel, total: lines.length, recent: sh(`git log -3 --pretty=%s -- "${rel}"`).split("\n").filter(Boolean), head: lines.slice(0, 120).join("\n").slice(0, 6000) }; }).filter(Boolean);
  const triage = await qwen([
    { role: "system", content: "You are a code scout writing a triage for a router. Do NOT propose a fix. Separate what the code ALREADY does from what must CHANGE; never restate existing behaviour as new work. If the request is already implemented, say so and keep estimated_diff_lines small. Output exactly:\nFILES: <list>\nEXISTING: <one line>\nCHANGE: <one line>\nRISK: <one line>\nSUMMARY: <one paragraph>\nFACTS: {\"files_involved\": n, \"estimated_diff_lines\": n, \"touches\": \"...\", \"needs_tests\": bool, \"crosses_process_boundary\": bool}" },
    { role: "user", content: `Request: ${task}\nRepo facts: ${JSON.stringify(gitFacts)}\n${testStatus ? `Test output tail:\n${testStatus.tail}\n` : ""}\n` + excerpts.map((e) => `--- ${e.rel} (first ${Math.min(120, e.total)} of ${e.total} lines) | recent: ${e.recent.join(" | ") || "none"}\n${e.head}`).join("\n\n") }
  ], 2500);
  const fm = triage.match(/FACTS:\s*(\{[\s\S]*)/); let facts = null;
  if (fm) for (const c of [fm[1].trim(), fm[1].trim() + "}", fm[1].trim().replace(/,\s*$/, "") + "}"]) { facts = parseJSON(c); if (facts) break; }
  return { triage: triage || null, facts, files: pick.files, why: pick.why };
}

// ---------- 3. Jev ----------
const jv = { in: 0, ms: 0 };
async function jev(state, questions) {
  const t0 = Date.now();
  const r = await fetch("https://api.typesafe.ai/v1/systemone", { method: "POST", headers: { Authorization: `Bearer ${JV}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: "jev-latest", state, questions }) });
  if (!r.ok) throw new Error(`jev ${r.status} ${await r.text()}`);
  const j = await r.json(); jv.in += j.usage?.input_tokens ?? 0; jv.ms += Date.now() - t0; return j.answers ?? {};
}
const effortMenu = { low: "Mechanical. One obvious correct answer. No analysis needed.", high: "Needs real analysis: several factors to weigh, or a cause to track down.", max: "Correctness matters more than cost: subtle, wide blast radius, expensive to get wrong." };
const capMenu = { "fast-cheap": "Small fast model. Trivial or mechanical work where any model gets it right.", coding: "Coding specialist. Multi-file edits, builds, tests, scripts, terminal work.", deep: "Frontier reasoning model. Open-ended analysis, judgement calls, root-cause thinking.", big: "Must read a very large amount of material in one go, or look at images.", local: "Must run on the user's machine; data may not leave the computer." };

async function route(state) {
  const e = await jev(state, { pick: { type: "choice", instructions: "How much reasoning effort should the coding model spend on this task?", criteria: effortMenu } });
  const c = await jev(state, { pick: { type: "choice", instructions: "Which kind of model should handle this task?", criteria: capMenu } });
  const eff = e.pick ?? {}, cap = c.pick ?? {};
  // Downgrade only with confidence; unsure -> safe default. Jev can veto, never authorize.
  let effort = eff.choice ?? SAFE_EFFORT; if (effort === "low" && (eff.confidence ?? 0) < CONFIDENT) effort = SAFE_EFFORT;
  let capability = cap.choice ?? SAFE_CAP; if ((cap.confidence ?? 0) < CONFIDENT && capability !== "local") capability = capability === "fast-cheap" ? SAFE_CAP : capability;
  return { effort, capability, raw: { effort: eff, capability: cap } };
}

// ---------- 4. run claude -p ----------
function runClaude(model, effort, prompt) {
  return new Promise((resolve) => {
    const args = ["-p", "--model", model, "--effort", effort, "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits", "--max-turns", String(opt.maxTurns), prompt];
    const t0 = Date.now(); const child = spawn("claude", args, { cwd: ROOT, stdio: ["ignore", "pipe", "pipe"] });
    let buf = "", result = null; const tools = [];
    const handle = (line) => { let ev; try { ev = JSON.parse(line); } catch { return; }
      if (ev.type === "assistant") for (const b of ev.message?.content ?? []) if (b.type === "tool_use") tools.push({ name: b.name, path: b.input?.file_path ?? b.input?.path ?? b.input?.command?.slice(0, 60) ?? null });
      if (ev.type === "result") result = ev; };
    child.stdout.on("data", (d) => { buf += d; let i; while ((i = buf.indexOf("\n")) >= 0) { handle(buf.slice(0, i)); buf = buf.slice(i + 1); } });
    let err = ""; child.stderr.on("data", (d) => { err += d; });
    child.on("close", () => { if (buf.trim()) handle(buf); resolve({ result, tools, ms: Date.now() - t0, stderr: err.slice(-400) }); });
  });
}

// ---------- 5. verify ----------
async function verify(text, tools, diffStat, testsAfter) {
  const writeTools = tools.filter((t) => /write|edit|multiedit|notebookedit/i.test(t.name) || /^(sed|perl|cat >|tee|mv|rm|git (apply|checkout))/i.test(t.path ?? "")).length;
  const a = await jev({ task, claim: text.slice(0, 3000), tools_used: tools.map((t) => `${t.name}${t.path ? `:${t.path}` : ""}`), git_diff_stat: diffStat || "(no changes)", tests_after: testsAfter },
    { claims_change: { type: "noul", instructions: "Does `claim` say something was created, changed, fixed, or deleted?" },
      backed_by_evidence: { type: "noul", instructions: "Do `tools_used` and `git_diff_stat` support that claim?", criteria: { true: "A listed tool or the diff could really have made the claimed change.", false: "No tool or diff supports it; an empty diff never supports a change claim." } },
      finished_task: { type: "noul", instructions: "Given `task`, `claim`, `git_diff_stat` and `tests_after`, was the task actually completed?" } });
  const claims = a.claims_change?.noul ?? 0, backed = a.backed_by_evidence?.noul ?? 0, done = a.finished_task?.noul ?? 0;
  const reasons = [];
  if (claims > 0.7 && !diffStat && writeTools === 0) reasons.push("claims a change but no diff and no write tools");
  if (claims > 0.7 && backed < 0.3) reasons.push(`Jev: change claim not backed by evidence (${backed.toFixed(2)})`);
  if (testsAfter && testsAfter.fail > 0) reasons.push(`${testsAfter.fail} test(s) still failing`);
  if (done < 0.5) reasons.push(`Jev: task not finished (${done.toFixed(2)})`);
  return { ok: reasons.length === 0, reasons, claims, backed, done, writeTools };
}

// ---------- main ----------
const t00 = Date.now();
section(`TASK: ${task}\nREPO: ${ROOT}`);
console.log(`facts: ${JSON.stringify(gitFacts)}`);
const sc = await scout();
if (sc.triage) { console.log(`\nscout files: ${sc.files.join(", ")}\n${sc.triage}`); } else console.log(`\nscout: none (files by grep: ${sc.files.join(", ") || "-"})`);
const state = { task, facts: gitFacts, triage: sc.triage, triage_facts: sc.facts, tests_before: testStatus ? { pass: testStatus.pass, fail: testStatus.fail } : null };
const r = await route(state);
const fmt = (p = {}) => Object.entries(p).map(([k, v]) => `${k}:${(+v).toFixed(2)}`).join(" ");
section("ROUTE");
console.log(`Jev effort:     ${r.raw.effort.choice} (${(r.raw.effort.confidence ?? 0).toFixed(2)})  [${fmt(r.raw.effort.probabilities)}]`);
console.log(`Jev capability: ${r.raw.capability.choice} (${(r.raw.capability.confidence ?? 0).toFixed(2)})  [${fmt(r.raw.capability.probabilities)}]`);
let effort = opt.effort ?? r.effort, capability = r.capability;
if (capability === "local") { console.log("Route = local: data must not leave the machine. Not wired to a local model yet — stopping."); process.exit(2); }
let model = opt.model ?? CAP_TO_MODEL[capability] ?? "sonnet";
console.log(`=> model ${model}, effort ${effort}${(opt.model || opt.effort) ? " (overridden)" : ""}`);
console.log(`scout: ${cb.in}/${cb.out} tokens, ${(cb.ms / 1000).toFixed(1)}s, $${((cb.in * 0.99 + cb.out * 1.49) / 1e6).toFixed(4)}   jev: ${jv.in} tokens, $${((jv.in / 1e9) * 42).toFixed(5)}`);
if (opt.dry) { console.log("\n--dry: not running claude."); process.exit(0); }

const attempts = [];
let prevFindings = null;
for (let attempt = 0; attempt < 2; attempt++) {
  section(`RUN ${attempt + 1}: claude --model ${model} --effort ${effort}`);
  const before = sh("git diff --stat | tail -1");
  const prompt = (prevFindings ? `A previous attempt at lower effort reported:\n${prevFindings}\n\nIt did not verify. Re-check its work and complete the task properly.\n\n` : "") + (sc.triage ? `A fast scout already looked at this repo and reported:\n${sc.triage}\n\nUse it as a starting point but verify it.\n\n` : "") + `${task}\n\nWork in this repository. When done, state clearly what you changed and why.`;
  const run = await runClaude(model, effort, prompt);
  const text = run.result?.result ?? "(no result)";
  const diffStat = sh("git diff --stat");
  const testsAfter = gitFacts.test_command ? (() => { const out = sh("npm test 2>&1 | grep -E '^(ℹ|#) (pass|fail)'") + "\n" + sh("npm test 2>&1 | tail -12"); const f = out.match(/(?:#|ℹ) fail (\d+)/), p = out.match(/(?:#|ℹ) pass (\d+)/); return { pass: p ? +p[1] : null, fail: f ? +f[1] : null }; })() : null;
  console.log(`claude: ${run.tools.length} tool calls, ${run.result?.num_turns ?? "?"} turns, ${(run.ms / 1000).toFixed(1)}s, $${(run.result?.total_cost_usd ?? 0).toFixed(4)}${run.result?.is_error ? "  [ERROR]" : ""}`);
  console.log(`tools: ${run.tools.map((t) => t.name + (t.path ? `(${path.basename(String(t.path))})` : "")).join(", ") || "-"}`);
  console.log(`diff:  ${diffStat.split("\n").pop() || "(none)"}`);
  if (testsAfter) console.log(`tests: pass ${testsAfter.pass ?? "?"}, fail ${testsAfter.fail ?? "?"}`);
  console.log(`claim: ${text.replace(/\s+/g, " ").slice(0, 300)}`);
  const v = await verify(text, run.tools, diffStat, testsAfter);
  section(`VERIFY ${attempt + 1}: ${v.ok ? "PASS" : "FAIL"}`);
  console.log(`claims_change ${v.claims.toFixed(2)}  backed_by_evidence ${v.backed.toFixed(2)}  finished_task ${v.done.toFixed(2)}  write tools ${v.writeTools}`);
  if (!v.ok) console.log(`reasons: ${v.reasons.join("; ")}`);
  attempts.push({ model, effort, ok: v.ok, reasons: v.reasons, cost: run.result?.total_cost_usd ?? null, ms: run.ms, turns: run.result?.num_turns ?? null, tools: run.tools.length, diff: diffStat.split("\n").pop() || null, tests: testsAfter, verdict: { claims: v.claims, backed: v.backed, done: v.done } });
  if (v.ok || attempt === 1) break;
  // escalate once: effort first (free on the same model), then model.
  const ei = EFFORT_TIERS.indexOf(effort), mi = MODEL_TIERS.indexOf(model);
  if (ei < EFFORT_TIERS.length - 1) effort = EFFORT_TIERS[ei + 1]; else if (mi < MODEL_TIERS.length - 1) model = MODEL_TIERS[mi + 1]; else break;
  prevFindings = `${text.slice(0, 1500)}\n(diff at that point: ${diffStat.split("\n").pop() || "none"})`;
  console.log(`\n→ escalating to model ${model}, effort ${effort}`);
}

// ---------- 6. log ----------
const logDir = path.join(os.homedir(), ".cache", "openassist-router"); fs.mkdirSync(logDir, { recursive: true });
const row = { ts: new Date().toISOString(), repo: path.basename(ROOT), task, facts: gitFacts, triage_facts: sc.facts, jev: r.raw, route: { model: opt.model ?? CAP_TO_MODEL[r.capability], effort: opt.effort ?? r.effort }, attempts, scout: { in: cb.in, out: cb.out, ms: cb.ms }, jev_tokens: jv.in, total_ms: Date.now() - t00 };
fs.appendFileSync(path.join(logDir, "log.jsonl"), JSON.stringify(row) + "\n");
section("SUMMARY");
const total = attempts.reduce((n, a) => n + (a.cost ?? 0), 0);
console.log(`${attempts.length} attempt(s), final ${attempts.at(-1).ok ? "PASS" : "FAIL"}, claude $${total.toFixed(4)}, router $${((cb.in * 0.99 + cb.out * 1.49) / 1e6 + (jv.in / 1e9) * 42).toFixed(4)}, ${((Date.now() - t00) / 1000).toFixed(1)}s total`);
console.log(`logged → ${path.join(logDir, "log.jsonl")}`);
