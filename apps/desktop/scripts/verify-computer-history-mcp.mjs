import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { searchComputerHistoryLocally } from "../dist-electron/computerHistoryLocalSearch.js";

const bridge = await readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");

const requestToolIndex = bridge.indexOf('name: "oa_request_computer_history_search"');
assert.ok(requestToolIndex >= 0, "Knowledge MCP must advertise Computer History search.");
const requestTool = bridge.slice(requestToolIndex, requestToolIndex + 4_000);
assert.match(requestTool, /What did I work on for this project\?/);
assert.match(requestTool, /Which meetings did I attend yesterday\?/);
assert.match(requestTool, /required:\s*\["query"\]/);
assert.match(requestTool, /fromDate/);
assert.match(requestTool, /toDate/);
assert.match(requestTool, /app/);
assert.match(requestTool, /project/);
assert.match(requestTool, /readOnlyHint:\s*true/);
assert.match(requestTool, /openWorldHint:\s*false/);

const statusToolIndex = bridge.indexOf('name: "oa_get_computer_history_search"');
assert.ok(statusToolIndex >= 0, "Knowledge MCP must advertise Computer History job status.");
const statusTool = bridge.slice(statusToolIndex, statusToolIndex + 2_000);
assert.match(statusTool, /required:\s*\["jobID"\]/);
assert.match(statusTool, /maximum:\s*15/);

assert.match(bridge, /case "oa_request_computer_history_search":\s*\n\s*case "knowledge_request_computer_history_search":\s*\n\s*return startComputerHistorySearchForExternalMCP\(args\)/);
assert.match(bridge, /case "oa_get_computer_history_search":\s*\n\s*case "knowledge_get_computer_history_search":\s*\n\s*return getComputerHistorySearchForExternalMCP\(args\)/);
assert.match(bridge, /computer-history@openai-bundled/);
assert.match(bridge, /codexDaemonTransport\.request\("mcpServerStatus\/list"/);
assert.match(bridge, /codexDaemonTransport\.request\("mcpServer\/tool\/call"/);
assert.match(bridge, /tool:\s*"computer_history_status"/);
assert.match(bridge, /findNestedRuntimeString\(payload, "eventStreamRootPath"\)/);
assert.match(bridge, /serviceName:\s*"OpenAssist Computer History Authorization"/);
assert.match(bridge, /codexDaemonTransport\.request\("thread\/delete"/);
assert.match(bridge, /path\.join\(supportRoot\(\), "Knowledge", "Computer History Jobs"\)/);
assert.match(bridge, /externalMCPComputerHistoryPipelineVersion = 5/);
assert.match(bridge, /pipelineVersion: externalMCPComputerHistoryPipelineVersion/);
assert.match(bridge, /This is not an empty-history result/);
assert.match(bridge, /\["app-server", "daemon", "start"\]/);
assert.match(bridge, /\["app-server", "proxy", "--sock", socketPath\]/);
assert.match(bridge, /perMessageDeflate:\s*false/);
assert.match(bridge, /path\.join\(codexRoot\(\), "packages", "standalone", "current", "codex"\)/);
assert.doesNotMatch(bridge, /2DC432GLL2\.com\.openai\.sky\.CUAService/);

const historySearchStart = bridge.indexOf("async function runComputerHistorySearchForExternalMCP");
const historySearchEnd = bridge.indexOf("async function startComputerHistorySearchForExternalMCP", historySearchStart);
const historySearch = bridge.slice(historySearchStart, historySearchEnd);
assert.match(historySearch, /await installedComputerHistoryPlugin\(\)/);
assert.match(historySearch, /await authenticatedComputerHistoryRoot\(\)/);
assert.match(historySearch, /Connecting to Computer History through Codex/);
assert.match(historySearch, /searchComputerHistoryLocally\(eventStreamRootPath, request/);
assert.doesNotMatch(historySearch, /trustedLocalComputerHistoryRoot|Group Containers|Skysight/);
assert.doesNotMatch(historySearch, /thread\/start|turn\/start|Evidence root:|outputSchema/);

const recordStart = bridge.indexOf("type ExternalMCPComputerHistoryJobRecord");
const recordDefinition = bridge.slice(recordStart, recordStart + 1_200);
assert.doesNotMatch(recordDefinition, /rawEvents|providerPayload|audio|accessToken|credentials/);

const fixtureRoot = await mkdtemp(path.join(os.tmpdir(), "openassist-history-search-"));
try {
  const segments = path.join(fixtureRoot, "segments");
  await mkdir(segments);
  const nowMs = new Date(2026, 7, 20, 18, 0, 0).getTime();
  const event = (localHour, localMinute, payload) => ({
    id: `${localHour}-${localMinute}-${payload.window?.title ?? "activity"}`,
    kind: "window.focused",
    timestamp: new Date(2026, 7, 20, localHour, localMinute, 0).toISOString(),
    ...payload
  });
  const historyEvents = [
    event(14, 50, {
      app: { name: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode" },
      window: { title: "Innovate 2.0 - NLS auth gateway" },
      ax: { text: "Reviewed Azure Easy Auth callback behavior and PR 1969 migration notes." }
    }),
    event(15, 35, {
      app: { name: "Microsoft Teams", bundleIdentifier: "com.microsoft.teams2" },
      window: { title: "NLS Architecture Review | Microsoft Teams" },
      ax: { text: "Meeting with the platform team about the NLS shared gateway." }
    }),
    event(15, 45, {
      app: { name: "Microsoft Teams", bundleIdentifier: "com.microsoft.teams2" },
      window: { title: "NLS Architecture Review | Microsoft Teams" },
      ax: { text: "The same meeting window was still active." }
    }),
    event(15, 55, {
      app: { name: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode" },
      window: { title: "Innovate 2.0 - NLS auth gateway" },
      ax: { text: "Microsoft Teams shortcut in sidebar\nContinued reviewing the NLS gateway implementation." }
    }),
    event(16, 10, {
      app: { name: "Brave Browser", bundleIdentifier: "com.brave.Browser" },
      window: { title: "Weather", url: "https://weather.example.test" },
      ax: { text: "Unrelated personal browsing." }
    }),
    event(17, 30, {
      app: { name: "Codex", bundleIdentifier: "com.openai.codex" },
      window: { title: "OpenAssist MCP debugging" },
      ax: { text: "What did I work on for NLS today and which meetings did I attend?" }
    }),
    event(17, 59, {
      app: { name: "Codex", bundleIdentifier: "com.openai.codex" },
      window: { title: "OpenAssist MCP debugging" },
      ax: { text: "Selected installed plugins for this turn: Computer History. NLS today." }
    })
  ];

  for (const historyEvent of historyEvents) {
    const segmentName = historyEvent.timestamp
      .replace(/\.\d{3}Z$/, "Z")
      .replace(/:/g, "-");
    const segment = path.join(segments, segmentName);
    await mkdir(segment);
    await writeFile(path.join(segment, "events.jsonl"), `${JSON.stringify(historyEvent)}\n`, "utf8");
  }

  const result = await searchComputerHistoryLocally(fixtureRoot, {
    query: "What did I work on for NLS today and which meetings did I attend?",
    fromDate: "2026-08-20",
    toDate: "2026-08-20",
    project: "NLS"
  }, { nowMs });

  assert.equal(result.confidence, "medium");
  assert.equal(result.sources.length, 2);
  assert.match(result.answer, /NLS/i);
  assert.match(result.answer, /possible meeting/i);
  assert.match(result.answer, /1 possible meeting/i);
  assert.match(result.answer, /not guaranteed attendance/i);
  assert.ok(result.sources.some((source) => /Innovate 2\.0 - NLS auth gateway/.test(source.title ?? "")));
  assert.ok(result.sources.some((source) => /NLS Architecture Review/.test(source.title ?? "")));
  assert.doesNotMatch(JSON.stringify(result), /weather\.example|Selected installed plugins|What did I work on for NLS/);
  assert.doesNotMatch(JSON.stringify(result), /\/Users\/|file:\/\//);

  const missing = await searchComputerHistoryLocally(fixtureRoot, {
    query: "Worked on the moon landing budget today",
    fromDate: "2026-08-20",
    toDate: "2026-08-20",
    project: "Moonshot"
  }, { nowMs });
  assert.equal(missing.confidence, "low");
  assert.deepEqual(missing.sources, []);
  assert.match(missing.answer, /did not find matching/i);
} finally {
  await rm(fixtureRoot, { recursive: true, force: true });
}

console.log("OpenAssist Computer History MCP direct-search checks passed.");
