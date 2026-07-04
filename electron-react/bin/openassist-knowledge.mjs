#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

const statePath = path.join(os.homedir(), "Library/Application Support/OpenAssist/Knowledge/server.json");
const mcpMetadataCache = new Map();
const mcpMetadataCacheMs = new Map([
  ["tools/list", 60_000],
  ["resources/list", 30_000]
]);

let stateCache = null;
let stateCacheAt = 0;
const STATE_CACHE_MS = 1000;

function readState() {
  const now = Date.now();
  if (stateCache && now - stateCacheAt < STATE_CACHE_MS) return stateCache;
  try {
    stateCache = JSON.parse(fs.readFileSync(statePath, "utf8"));
  } catch {
    stateCache = {};
  }
  stateCacheAt = now;
  return stateCache;
}

function usage() {
  console.log([
    "Usage:",
    "  openassist-knowledge status",
    "  openassist-knowledge search <query>",
    "  openassist-knowledge read <item-id>",
    "  openassist-knowledge today [yyyy-mm-dd]",
    "  openassist-knowledge journal [yyyy-mm-dd]",
    "  openassist-knowledge tasks",
    "  openassist-knowledge mcp --stdio"
  ].join("\n"));
}

function localDayID(date = new Date()) {
  const pad = (value) => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

async function request(method, endpoint, body) {
  const state = readState();
  const baseURL = String(state.baseURL || "").replace(/\/$/, "");
  const token = String(state.token || "");
  if (!baseURL || !token) throw new Error("OpenAssist Knowledge is not running. Open the Electron app first.");
  const response = await fetch(`${baseURL}${endpoint}`, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      connection: "close"
    },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || `Knowledge request failed: ${response.status}`);
  return payload;
}

function isEmptyParams(params) {
  return params == null || (typeof params === "object" && !Array.isArray(params) && Object.keys(params).length === 0);
}

function cachedMCPMetadataResponse(message) {
  const method = typeof message?.method === "string" ? message.method : "";
  const ttl = mcpMetadataCacheMs.get(method);
  if (!ttl || !isEmptyParams(message?.params)) return null;
  const cached = mcpMetadataCache.get(method);
  if (!cached || cached.expiresAt <= Date.now()) return null;
  return { jsonrpc: "2.0", id: message?.id ?? null, result: cached.result };
}

function rememberMCPMetadataResponse(message, payload) {
  const method = typeof message?.method === "string" ? message.method : "";
  const ttl = mcpMetadataCacheMs.get(method);
  if (!ttl || !isEmptyParams(message?.params) || !payload || typeof payload !== "object" || !("result" in payload)) return;
  mcpMetadataCache.set(method, { expiresAt: Date.now() + ttl, result: payload.result });
}

async function runMCPStdio() {
  // The parent (Codex/Electron) owns this process. If the parent dies or the
  // pipe goes into a half-open/error state, exit instead of busy-spinning the
  // readline loop forever (this leaked many ~80% CPU orphan processes).
  const exitClean = () => process.exit(0);
  process.stdin.on("end", exitClean);
  process.stdin.on("close", exitClean);
  process.stdin.on("error", exitClean);
  // Belt-and-suspenders: if stdout is closed (parent gone), nothing can read
  // our replies, so there is no reason to keep running.
  process.stdout.on("error", exitClean);

  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  rl.on("close", exitClean);

  // Flood guard: a misbehaving parent (e.g. a stuck realtime session) can spam
  // identical lines on stdin, pegging this process at ~80% CPU as it parses +
  // fetches per line. Drop a line if the exact same one already arrived in the
  // last window; track lines processed in the window and skip work past a cap.
  let windowStart = Date.now();
  let windowCount = 0;
  let lastLine = "";
  const FLOOD_WINDOW_MS = 1000;
  const FLOOD_MAX_PER_WINDOW = 50;

  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    const now = Date.now();
    if (now - windowStart > FLOOD_WINDOW_MS) {
      windowStart = now;
      windowCount = 0;
    }
    windowCount += 1;
    // Identical line repeated back-to-back, or more than the cap in one window:
    // the parent is flooding. Don't do the expensive fetch, but a dropped
    // REQUEST (has an id) must still get a JSON-RPC error so the client's
    // pending call fails fast instead of hanging until its own timeout.
    if ((trimmed === lastLine && windowCount > 2) || windowCount > FLOOD_MAX_PER_WINDOW) {
      lastLine = trimmed;
      try {
        const flooded = JSON.parse(trimmed);
        if (flooded && flooded.id !== undefined && flooded.id !== null) {
          process.stdout.write(`${JSON.stringify({
            jsonrpc: "2.0",
            id: flooded.id,
            error: { code: -32000, message: "Request dropped: too many requests." }
          })}\n`);
        }
      } catch {
        // Unparseable flood line; nothing to answer.
      }
      continue;
    }
    lastLine = trimmed;

    let message;
    try {
      message = JSON.parse(trimmed);
      const cached = cachedMCPMetadataResponse(message);
      if (cached) {
        process.stdout.write(`${JSON.stringify(cached)}\n`);
        continue;
      }
      const state = readState();
      const mcpURL = String(state.mcpURL || `${String(state.baseURL || "").replace(/\/$/, "")}/mcp`);
      const token = String(state.token || "");
      const response = await fetch(mcpURL, {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
          connection: "close"
        },
        body: JSON.stringify(message)
      });
      const payload = await response.json();
      rememberMCPMetadataResponse(message, payload);
      process.stdout.write(`${JSON.stringify(payload)}\n`);
    } catch (error) {
      process.stdout.write(`${JSON.stringify({
        jsonrpc: "2.0",
        id: message?.id ?? null,
        error: { code: -32000, message: error instanceof Error ? error.message : "MCP proxy failed." }
      })}\n`);
    }
  }
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  if (!command || command === "help" || command === "--help") {
    usage();
    return;
  }
  if (command === "status") {
    console.log(JSON.stringify(readState(), null, 2));
    return;
  }
  if (command === "search") {
    console.log(JSON.stringify(await request("POST", "/v1/search", { query: args.join(" ") }), null, 2));
    return;
  }
  if (command === "read") {
    if (!args[0]) throw new Error("Missing item id.");
    console.log(JSON.stringify(await request("GET", `/v1/items/${encodeURIComponent(args[0])}`), null, 2));
    return;
  }
  if (command === "today") {
    const day = args[0] || localDayID();
    console.log(JSON.stringify(await request("GET", `/v1/planner/days/${encodeURIComponent(day)}`), null, 2));
    return;
  }
  if (command === "journal") {
    const day = args[0] || localDayID();
    console.log(JSON.stringify(await request("GET", `/v1/journal/days/${encodeURIComponent(day)}`), null, 2));
    return;
  }
  if (command === "tasks") {
    console.log(JSON.stringify(await request("GET", "/v1/tasks/open"), null, 2));
    return;
  }
  if (command === "mcp" && args[0] === "--stdio") {
    await runMCPStdio();
    return;
  }
  usage();
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
