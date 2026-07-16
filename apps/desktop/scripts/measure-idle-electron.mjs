#!/usr/bin/env node
// Measure idle RAM/CPU for the running OpenAssist Electron app.
//
// Prerequisites:
//   1. Launch the app with OPENASSIST_ELECTRON_REMOTE_DEBUG=1 (dev: `npm run dev`
//      with that env var set; packaged: `OPENASSIST_ELECTRON_REMOTE_DEBUG=1
//      open out/Open\ Assist-darwin-arm64/Open\ Assist.app`).
//   2. Wait ~30 s after first paint so the renderer is warm.
//
// Outputs go to verification/perf/<timestamp>/:
//   - perf-summary.json — high-level numbers
//   - app-metrics-samples.json — one snapshot per second
//   - ps-samples.tsv — ps -axo lines sampled at 2 s
//   - renderer-heap.heapsnapshot — Chrome DevTools-loadable
//   - tracing.json — 30 s CDP timeline trace (loadable in DevTools → Performance → Load)
//
// Usage:
//   node scripts/measure-idle-electron.mjs [--duration 60] [--label baseline]

import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";

const args = parseArgs(process.argv.slice(2));
const durationSeconds = Number(args.duration ?? 60);
const label = String(args.label ?? "idle");
const endpoint = process.env.OPENASSIST_ELECTRON_CDP ?? "http://127.0.0.1:8315/json/list";

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
const outDir = path.join(repoRoot, "verification", "perf", `${label}-${timestamp}`);
fs.mkdirSync(outDir, { recursive: true });
console.log(`[measure] writing to ${path.relative(repoRoot, outDir)}`);

function parseArgs(list) {
  const out = {};
  for (let i = 0; i < list.length; i++) {
    const token = list[i];
    if (!token.startsWith("--")) continue;
    const key = token.slice(2);
    const next = list[i + 1];
    if (!next || next.startsWith("--")) {
      out[key] = true;
    } else {
      out[key] = next;
      i++;
    }
  }
  return out;
}

async function fetchTargets() {
  const response = await fetch(endpoint);
  if (!response.ok) throw new Error(`CDP endpoint ${endpoint} returned ${response.status}`);
  return response.json();
}

function pickMainRenderer(targets) {
  const pages = targets.filter((t) => t.type === "page");
  // Prefer the dev URL or the loaded packaged renderer over voice HUD / popovers.
  return (
    pages.find((t) => /127\.0\.0\.1:5187/.test(t.url) && !/window=/.test(t.url)) ||
    pages.find((t) => /127\.0\.0\.1:5187/.test(t.url)) ||
    pages.find((t) => /index\.html/.test(t.url) && !/window=/.test(t.url)) ||
    pages.find((t) => !/Voice HUD/.test(t.title || "") && !/data:text\/html/.test(t.url)) ||
    pages[0]
  );
}

class CdpClient {
  constructor(target) {
    this.target = target;
    this.socket = null;
    this.pending = new Map();
    this.id = 0;
    this.eventHandlers = new Map();
  }

  async connect() {
    this.socket = new WebSocket(this.target.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      this.socket.onopen = resolve;
      this.socket.onerror = (err) => reject(err);
    });
    this.socket.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (message.id && this.pending.has(message.id)) {
        const { resolve, reject, timer } = this.pending.get(message.id);
        clearTimeout(timer);
        this.pending.delete(message.id);
        if (message.error) reject(new Error(JSON.stringify(message.error)));
        else resolve(message.result);
        return;
      }
      if (message.method && this.eventHandlers.has(message.method)) {
        for (const handler of this.eventHandlers.get(message.method)) handler(message.params);
      }
    };
    this.socket.onclose = () => this.rejectPending(new Error("CDP socket closed"));
    this.socket.onerror = () => this.rejectPending(new Error("CDP socket error"));
  }

  rejectPending(error) {
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer);
      reject(error);
    }
    this.pending.clear();
  }

  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const requestId = ++this.id;
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new Error(`${method} timed out after 120 s`));
      }, 120_000);
      this.pending.set(requestId, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id: requestId, method, params }));
    });
  }

  on(event, handler) {
    if (!this.eventHandlers.has(event)) this.eventHandlers.set(event, []);
    this.eventHandlers.get(event).push(handler);
  }

  async evaluate(expression) {
    const result = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: true
    });
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.text ?? JSON.stringify(result.exceptionDetails));
    }
    return result.result?.value;
  }

  close() {
    if (this.socket && this.socket.readyState === 1) this.socket.close();
  }
}

async function takeHeapSnapshot(client, outPath) {
  const chunks = [];
  client.on("HeapProfiler.addHeapSnapshotChunk", (params) => chunks.push(params.chunk));
  await client.send("HeapProfiler.enable");
  await client.send("HeapProfiler.collectGarbage");
  await client.send("HeapProfiler.takeHeapSnapshot", { reportProgress: false });
  fs.writeFileSync(outPath, chunks.join(""), "utf8");
  console.log(`[measure] heap snapshot saved (${(fs.statSync(outPath).size / 1_000_000).toFixed(1)} MB)`);
}

async function recordTracing(client, outPath, ms) {
  const chunks = [];
  let resolveDone;
  const done = new Promise((resolve) => { resolveDone = resolve; });
  client.on("Tracing.dataCollected", (params) => {
    if (Array.isArray(params.value)) chunks.push(...params.value);
  });
  client.on("Tracing.tracingComplete", () => resolveDone());
  await client.send("Tracing.start", {
    transferMode: "ReportEvents",
    categories: "disabled-by-default-devtools.timeline,disabled-by-default-devtools.timeline.frame,blink.user_timing,v8.execute"
  });
  await new Promise((resolve) => setTimeout(resolve, ms));
  await client.send("Tracing.end");
  await done;
  fs.writeFileSync(outPath, JSON.stringify({ traceEvents: chunks }), "utf8");
  console.log(`[measure] tracing saved (${chunks.length} events)`);
}

async function samplePs(durationMs, intervalMs, outPath) {
  // ps -axo pid,rss,vsz,pcpu,comm — sampled every intervalMs.
  const samples = [];
  const start = Date.now();
  const header = ["t_ms", "pid", "rss_kb", "vsz_kb", "pcpu", "command"].join("\t");
  fs.writeFileSync(outPath, header + "\n", "utf8");
  while (Date.now() - start < durationMs) {
    const t = Date.now() - start;
    const sample = await new Promise((resolve, reject) => {
      const proc = spawn("ps", ["-axo", "pid=,rss=,vsz=,pcpu=,comm="]);
      let stdout = "";
      proc.stdout.on("data", (chunk) => { stdout += chunk.toString("utf8"); });
      proc.on("close", (code) => {
        if (code !== 0) reject(new Error(`ps exited ${code}`));
        else resolve(stdout);
      });
    });
    for (const line of sample.split("\n")) {
      if (!/Open Assist|Electron|Chromium Helper|Code Helper/i.test(line)) continue;
      const parts = line.trim().split(/\s+/);
      if (parts.length < 5) continue;
      const pid = parts[0];
      const rss = parts[1];
      const vsz = parts[2];
      const pcpu = parts[3];
      const command = parts.slice(4).join(" ").replace(/\s+/g, " ");
      fs.appendFileSync(outPath, [t, pid, rss, vsz, pcpu, command].join("\t") + "\n", "utf8");
      samples.push({ t, pid, rss_kb: Number(rss), vsz_kb: Number(vsz), pcpu: Number(pcpu), command });
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return samples;
}

function summarize(samples) {
  // Group by command keyword and report avg/p95/max RSS + CPU.
  const groups = new Map();
  for (const s of samples) {
    const key =
      /Open Assist Helper \(GPU\)/.test(s.command) ? "GPU" :
      /Open Assist Helper \(Renderer\)/.test(s.command) ? "Renderer" :
      /Open Assist Helper \(Plugin\)/.test(s.command) ? "Plugin" :
      /Open Assist Helper$/.test(s.command) ? "Helper" :
      /Open Assist$/.test(s.command) ? "Main" :
      /Electron Helper \(GPU\)/.test(s.command) ? "GPU(dev)" :
      /Electron Helper \(Renderer\)/.test(s.command) ? "Renderer(dev)" :
      /Electron Helper$/.test(s.command) ? "Helper(dev)" :
      /Electron$/.test(s.command) ? "Main(dev)" :
      "Other";
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(s);
  }
  const summary = {};
  for (const [key, items] of groups) {
    const rss = items.map((i) => i.rss_kb).sort((a, b) => a - b);
    const cpu = items.map((i) => i.pcpu).sort((a, b) => a - b);
    const median = (arr) => arr[Math.floor(arr.length / 2)];
    const p95 = (arr) => arr[Math.min(arr.length - 1, Math.floor(arr.length * 0.95))];
    summary[key] = {
      samples: items.length,
      rss_mb: {
        median: +(median(rss) / 1024).toFixed(1),
        p95: +(p95(rss) / 1024).toFixed(1),
        max: +(rss[rss.length - 1] / 1024).toFixed(1)
      },
      cpu_percent: {
        median: median(cpu),
        p95: p95(cpu),
        max: cpu[cpu.length - 1]
      }
    };
  }
  return summary;
}

async function main() {
  console.log(`[measure] connecting to ${endpoint}…`);
  let targets;
  try {
    targets = await fetchTargets();
  } catch (error) {
    console.error(`[measure] could not reach CDP at ${endpoint}.`);
    console.error("[measure] is the app running with OPENASSIST_ELECTRON_REMOTE_DEBUG=1?");
    throw error;
  }
  const target = pickMainRenderer(targets);
  if (!target?.webSocketDebuggerUrl) throw new Error("Could not find a renderer target.");
  console.log(`[measure] target: ${target.title} (${target.url})`);

  const client = new CdpClient(target);
  await client.connect();
  await client.send("Runtime.enable");
  await client.send("Page.enable");
  await client.send("Performance.enable");

  // 1) Perf snapshot from the main process (via the dev-only IPC).
  const perfSnapshot = await client.evaluate("window.openAssistElectron.__perfSnapshot()");
  fs.writeFileSync(path.join(outDir, "perf-snapshot.json"), JSON.stringify(perfSnapshot, null, 2));
  console.log(`[measure] main-process perf snapshot captured (${perfSnapshot?.appMetrics?.length ?? 0} processes reported by Electron)`);

  // 2) Renderer-side performance.memory + DOM stats.
  const rendererMetrics = await client.evaluate(`(() => {
    const mem = performance.memory ? {
      jsHeapSizeLimit: performance.memory.jsHeapSizeLimit,
      totalJSHeapSize: performance.memory.totalJSHeapSize,
      usedJSHeapSize: performance.memory.usedJSHeapSize
    } : null;
    return {
      memory: mem,
      domNodes: document.getElementsByTagName('*').length,
      windowInnerSize: { w: window.innerWidth, h: window.innerHeight }
    };
  })()`);
  fs.writeFileSync(path.join(outDir, "renderer-metrics.json"), JSON.stringify(rendererMetrics, null, 2));

  // 3) Start ps sampling in parallel with tracing.
  const psPromise = samplePs(durationSeconds * 1000, 2000, path.join(outDir, "ps-samples.tsv"));

  // 4) Sample the dev-IPC perf snapshot every second.
  const metricSamples = [];
  const metricInterval = setInterval(async () => {
    try {
      const snap = await client.evaluate("window.openAssistElectron.__perfSnapshot()");
      metricSamples.push(snap);
    } catch (err) {
      // ignore transient errors
    }
  }, 1000);

  // 5) Tracing burst (30 s, but cap to half the total run).
  const traceMs = Math.min(30_000, durationSeconds * 500);
  await recordTracing(client, path.join(outDir, "tracing.json"), traceMs);

  // 6) Wait for ps sampler to finish.
  const psSamples = await psPromise;
  clearInterval(metricInterval);

  fs.writeFileSync(path.join(outDir, "app-metrics-samples.json"), JSON.stringify(metricSamples, null, 2));

  const psSummary = summarize(psSamples);
  fs.writeFileSync(path.join(outDir, "ps-summary.json"), JSON.stringify(psSummary, null, 2));
  console.log("[measure] ps summary:");
  for (const [key, value] of Object.entries(psSummary)) {
    console.log(`  ${key.padEnd(12)} rss median=${value.rss_mb.median} MB  p95=${value.rss_mb.p95} MB  cpu median=${value.cpu_percent.median}%  p95=${value.cpu_percent.p95}%  (${value.samples} samples)`);
  }

  // 7) Renderer heap snapshot last so GC has run after tracing.
  await takeHeapSnapshot(client, path.join(outDir, "renderer-heap.heapsnapshot"));

  const summaryDoc = {
    capturedAt: new Date().toISOString(),
    durationSeconds,
    label,
    target: { title: target.title, url: target.url },
    rendererMetrics,
    initialMainSnapshot: perfSnapshot,
    psSummary
  };
  fs.writeFileSync(path.join(outDir, "perf-summary.json"), JSON.stringify(summaryDoc, null, 2));
  console.log(`[measure] done. summary at ${path.relative(repoRoot, path.join(outDir, "perf-summary.json"))}`);

  client.close();
}

main().catch((error) => {
  console.error("[measure] failed:", error);
  process.exitCode = 1;
});
