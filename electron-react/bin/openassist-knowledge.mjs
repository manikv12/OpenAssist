#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

const statePath = path.join(os.homedir(), "Library/Application Support/OpenAssist/Knowledge/server.json");

function readState() {
  try {
    return JSON.parse(fs.readFileSync(statePath, "utf8"));
  } catch {
    return {};
  }
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
      "content-type": "application/json"
    },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || `Knowledge request failed: ${response.status}`);
  return payload;
}

async function runMCPStdio() {
  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let message;
    try {
      message = JSON.parse(trimmed);
      const state = readState();
      const mcpURL = String(state.mcpURL || `${String(state.baseURL || "").replace(/\/$/, "")}/mcp`);
      const token = String(state.token || "");
      const response = await fetch(mcpURL, {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json"
        },
        body: JSON.stringify(message)
      });
      process.stdout.write(`${JSON.stringify(await response.json())}\n`);
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
