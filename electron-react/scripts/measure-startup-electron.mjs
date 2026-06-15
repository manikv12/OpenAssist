#!/usr/bin/env node
// Measure cold-start phases for Open Assist:
//   t0    process spawn
//   t1    CDP port answers (Electron main process ready, BrowserWindow created)
//   t2    document.readyState === "complete" on the renderer
//   t3    React mounted (root has children)
//   t4    DOM stable for 1s (no new mutations) — "feels loaded"
//
// Usage:
//   node scripts/measure-startup-electron.mjs [--trials 3] [--label cold]
//
// Pre-flight: `npm run build` and ensure no Electron is running.

import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";

const args = parseArgs(process.argv.slice(2));
const trials = Number(args.trials ?? 3);
const label = String(args.label ?? "cold");

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const electronBin = path.join(repoRoot, "node_modules", ".bin", "electron");
const cdp = "http://127.0.0.1:8315";

function parseArgs(list) {
  const out = {};
  for (let i = 0; i < list.length; i++) {
    const token = list[i];
    if (!token.startsWith("--")) continue;
    const key = token.slice(2);
    const next = list[i + 1];
    if (!next || next.startsWith("--")) out[key] = true;
    else { out[key] = next; i++; }
  }
  return out;
}

async function killAll() {
  await new Promise((resolve) => {
    const k = spawn("pkill", ["-f", "/electron-react/node_modules/electron"]);
    k.on("close", () => resolve());
  });
  await new Promise((r) => setTimeout(r, 800));
}

async function waitForCDP(timeoutMs = 15_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const r = await fetch(`${cdp}/json/version`, { signal: AbortSignal.timeout(500) });
      if (r.ok) return Date.now();
    } catch {
      // not ready
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error("CDP did not become reachable in time");
}

async function waitForMainPageTarget(timeoutMs = 15_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const list = await (await fetch(`${cdp}/json/list`)).json();
      const page = list.find((t) =>
        t.type === "page" &&
        (/dist-renderer/.test(t.url) || /127\.0\.0\.1:5187/.test(t.url))
      );
      if (page?.webSocketDebuggerUrl) return { page, t: Date.now() };
    } catch {
      // not ready
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error("main page target did not appear");
}

class Cdp {
  constructor(url) {
    this.ws = new WebSocket(url);
    this.id = 0;
    this.pending = new Map();
  }
  async open() {
    await new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = reject;
    });
    this.ws.onmessage = (e) => {
      const m = JSON.parse(e.data);
      if (m.id && this.pending.has(m.id)) {
        const { resolve, reject } = this.pending.get(m.id);
        this.pending.delete(m.id);
        if (m.error) reject(new Error(JSON.stringify(m.error)));
        else resolve(m.result);
      }
    };
  }
  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      this.id++;
      this.pending.set(this.id, { resolve, reject });
      this.ws.send(JSON.stringify({ id: this.id, method, params }));
    });
  }
  async eval(expr) {
    const r = await this.send("Runtime.evaluate", {
      expression: expr,
      awaitPromise: true,
      returnByValue: true
    });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text);
    return r.result?.value;
  }
  close() { try { this.ws.close(); } catch {} }
}

async function pollUntil(fn, predicate, timeoutMs, intervalMs = 50) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const v = await fn();
      if (predicate(v)) return { value: v, t: Date.now() };
    } catch {
      // ignore, retry
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error("pollUntil timed out");
}

async function runTrial(n) {
  console.log(`\n--- trial ${n} ---`);
  await killAll();
  // Drop the OS file cache for the renderer bundle to approximate a real
  // cold start. We can't easily flush the disk cache without sudo, so this
  // is "warm disk" cold start — still useful, and what most users actually
  // experience after the first launch of the day.
  const t0 = Date.now();
  const child = spawn(electronBin, ["."], {
    cwd: repoRoot,
    env: {
      ...process.env,
      OPENASSIST_ELECTRON_REMOTE_DEBUG: "1",
      OPENASSIST_OPEN_DEVTOOLS: "0"
    },
    stdio: ["ignore", "ignore", "ignore"]
  });

  const t1 = await waitForCDP(20_000);
  const { page, t: t2pageList } = await waitForMainPageTarget(20_000);
  const client = new Cdp(page.webSocketDebuggerUrl);
  await client.open();
  await client.send("Runtime.enable");

  const t2docReady = await pollUntil(
    () => client.eval("document.readyState"),
    (v) => v === "complete",
    20_000,
    50
  );

  const t3reactMounted = await pollUntil(
    () => client.eval("(()=>{const r=document.getElementById('root'); return r ? r.children.length : 0;})()"),
    (v) => v > 0,
    20_000,
    50
  );

  // t4: DOM stable for 3 s AND we have at least 500 nodes (avoid false
  // positives during the React shell rendering before data loads).
  let lastNodeCount = 0;
  let stableSince = Date.now();
  const startStable = Date.now();
  while (true) {
    const now = await client.eval("document.getElementsByTagName('*').length");
    if (now !== lastNodeCount) {
      lastNodeCount = now;
      stableSince = Date.now();
    }
    const stableMs = Date.now() - stableSince;
    if (stableMs > 3000 && lastNodeCount > 500) break;
    if (Date.now() - startStable > 30_000) {
      console.log(`[trial] stability timeout, nodes=${lastNodeCount} stable=${stableMs}ms`);
      break;
    }
    await new Promise((r) => setTimeout(r, 150));
  }
  const t4stable = Date.now() - 3000; // subtract the stability window
  const finalDomNodes = lastNodeCount;

  client.close();
  // Kill the launched Electron
  child.kill("SIGTERM");
  await new Promise((r) => setTimeout(r, 600));

  return {
    spawnToCdp_ms: t1 - t0,
    cdpToPageTarget_ms: t2pageList - t1,
    pageTargetToDocComplete_ms: t2docReady.t - t2pageList,
    docCompleteToReactMounted_ms: t3reactMounted.t - t2docReady.t,
    reactMountedToDomStable_ms: t4stable - t3reactMounted.t,
    totalSpawnToReactMounted_ms: t3reactMounted.t - t0,
    totalSpawnToDomStable_ms: t4stable - t0,
    finalDomNodes
  };
}

async function main() {
  const results = [];
  for (let i = 1; i <= trials; i++) {
    try {
      const r = await runTrial(i);
      results.push(r);
      console.log(JSON.stringify(r, null, 2));
    } catch (error) {
      console.error(`trial ${i} failed:`, error.message);
    }
  }
  if (results.length === 0) {
    console.error("no successful trials");
    process.exit(1);
  }
  const med = (key) => {
    const arr = results.map((r) => r[key]).sort((a, b) => a - b);
    return arr[Math.floor(arr.length / 2)];
  };
  const min = (key) => Math.min(...results.map((r) => r[key]));
  const max = (key) => Math.max(...results.map((r) => r[key]));
  console.log("\n=== summary (median / min / max across trials) ===");
  for (const key of Object.keys(results[0])) {
    if (key === "finalDomNodes") {
      console.log(`  ${key.padEnd(36)} ${med(key)} / ${min(key)} / ${max(key)}`);
    } else {
      console.log(`  ${key.padEnd(36)} ${med(key)} ms / ${min(key)} ms / ${max(key)} ms`);
    }
  }
  const outDir = path.join(repoRoot, "verification", "perf", `startup-${label}-${new Date().toISOString().replace(/[:.]/g, "-")}`);
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, "trials.json"), JSON.stringify({ trials: results, median: Object.fromEntries(Object.keys(results[0]).map((k) => [k, med(k)])) }, null, 2));
  console.log(`\nartifacts: ${path.relative(repoRoot, outDir)}`);
}

main().catch((error) => {
  console.error("startup measurement failed:", error);
  process.exit(1);
});
