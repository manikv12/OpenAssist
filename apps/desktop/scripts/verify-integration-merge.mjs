import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const bridgeSource = fs.readFileSync(path.resolve("electron/openassistBridge.ts"), "utf8");
const appSource = fs.readFileSync(path.resolve("src/App.tsx"), "utf8");
const typesSource = fs.readFileSync(path.resolve("src/types.ts"), "utf8");

// --- Source guards: the provider-config merge must never regress to the lazy
// regex that once left an orphaned `args = [...]` line in ~/.codex/config.toml.
assert.ok(
  !bridgeSource.includes("[\\\\s\\\\S]*?(?=\\\\n\\\\["),
  "TOML block removal must not use the lazy multiline regex (it truncated blocks and orphaned args lines)"
);
assert.ok(
  bridgeSource.includes("function stripOpenAssistTomlEntries"),
  "Bridge must remove the OpenAssist TOML entry line-by-line via stripOpenAssistTomlEntries"
);
assert.ok(
  /function mergeTomlIntegrationConfig[\s\S]{0,300}stripOpenAssistTomlEntries\(/.test(bridgeSource),
  "mergeTomlIntegrationConfig must delegate removal to stripOpenAssistTomlEntries"
);
assert.ok(
  bridgeSource.includes("line.includes(\"openassist-knowledge.mjs\")"),
  "Strip pass must also drop orphaned proxy args/command lines from earlier broken merges"
);
assert.ok(
  bridgeSource.includes("function tomlIntegrationEntryIsCurrent"),
  "Bridge must be able to tell when the Codex entry is already correct"
);
assert.ok(
  bridgeSource.includes("\"already-connected\" as const"),
  "connectOpenAssistIntegration must short-circuit with already-connected when nothing needs to change"
);
assert.ok(
  bridgeSource.includes("hadEntry ? (\"repaired\" as const) : (\"created\" as const)"),
  "connectOpenAssistIntegration must distinguish repairs from first-time connects"
);
assert.ok(
  bridgeSource.includes("function resolveNodeBinaryPath"),
  "Codex TOML block must use an absolute node path (Codex spawns MCP servers without the shell PATH)"
);

// --- Settings UI guards: connected targets offer Repair (not Reconnect) and
// surface the already-exists case to the user.
assert.ok(!appSource.includes("\"Reconnect\""), "Settings must not label the connected action Reconnect");
assert.ok(appSource.includes("? \"Repair\""), "Settings must offer a Repair action for connected targets");
assert.ok(
  appSource.includes("already has OpenAssist set up correctly"),
  "Settings must say the MCP entry already exists when nothing changed"
);
assert.ok(appSource.includes("entry repaired"), "Settings must report repairs distinctly from fresh connects");
assert.ok(appSource.includes("\"Needs repair\""), "Status pill must flag a stale/broken entry as Needs repair");
assert.ok(
  typesSource.includes("\"created\" | \"repaired\" | \"already-connected\""),
  "Connect result type must model created/repaired/already-connected"
);

// --- Behavioral check of the exact merge semantics, mirrored from the bridge.
// Keep in sync with stripOpenAssistTomlEntries/extractOpenAssistTomlBlock.
const serverName = "openassist_knowledge";
const headerPattern = new RegExp(`^\\s*\\[mcp_servers\\.${serverName}\\]\\s*(#.*)?$`);
const desiredBlock = [
  `[mcp_servers.${serverName}]`,
  "command = \"/opt/homebrew/bin/node\"",
  "args = [\"/x/bin/openassist-knowledge.mjs\", \"mcp\", \"--stdio\"]"
].join("\n");

function refsProxy(line) {
  return /^\s*(args|command)\s*=/.test(line) && line.includes("openassist-knowledge.mjs");
}

function strip(raw) {
  const lines = raw.split(/\r?\n/);
  const segments = [[]];
  for (const line of lines) {
    if (/^\s*\[/.test(line)) segments.push([line]);
    else segments[segments.length - 1].push(line);
  }
  const kept = [];
  for (const segment of segments) {
    const header = segment[0] && /^\s*\[/.test(segment[0]) ? segment[0] : undefined;
    if (header && headerPattern.test(header)) continue;
    const referencesProxy = segment.some(refsProxy);
    if (header && /^\s*\[mcp_servers\./.test(header) && referencesProxy) {
      const isRemoteServer = segment.some((line) => /^\s*url\s*=/.test(line));
      if (!isRemoteServer) continue;
      kept.push(...segment.filter((line) => !refsProxy(line)));
      continue;
    }
    if (!header && referencesProxy) {
      kept.push(...segment.filter((line) => !refsProxy(line)));
      continue;
    }
    kept.push(...segment);
  }
  return kept.join("\n");
}

function merge(raw) {
  const without = strip(raw).trimEnd();
  return `${without}${without ? "\n\n" : ""}${desiredBlock}\n`;
}

// The real-world breakage: block header+command were removed by the old regex,
// leaving args floating under the neighboring remote server entry.
const broken = [
  "[mcp_servers.robinhood-trading]",
  "url = \"https://example.com/mcp\"",
  "args = [\"/old/electron-react/bin/openassist-knowledge.mjs\", \"mcp\", \"--stdio\"]",
  "",
  "[projects.\"/tmp\"]",
  "trust_level = \"trusted\""
].join("\n");
const repaired = merge(broken);
assert.ok(!repaired.includes("electron-react"), "Repair must remove the orphaned args line");
assert.equal((repaired.match(/args\s*=/g) || []).length, 1, "Exactly one args line after repair");
assert.ok(
  repaired.includes("[mcp_servers.robinhood-trading]\nurl = \"https://example.com/mcp\"\n"),
  "Neighboring server blocks must survive repair untouched"
);

// Re-running the merge on a healthy file must be idempotent (one block, no orphans).
const once = merge("model = \"gpt-5\"");
assert.equal(merge(once), once, "Merging twice must not duplicate or mangle the block");
assert.equal((merge(once).match(/\[mcp_servers\.openassist_knowledge\]/g) || []).length, 1);

// A block in the middle of the file must be removed whole, including args.
const middle = [
  `[mcp_servers.${serverName}]`,
  "command = \"node\"",
  "args = [\"/stale/openassist-knowledge.mjs\", \"mcp\", \"--stdio\"]",
  "",
  "[mcp_servers.robinhood-trading]",
  "url = \"https://example.com/mcp\""
].join("\n");
const moved = merge(middle);
assert.ok(!moved.includes("/stale/"), "Old block must be removed entirely, args included");
const rhStart = moved.indexOf("[mcp_servers.robinhood-trading]");
const rhEnd = moved.indexOf("[", rhStart + 1);
assert.ok(
  !moved.slice(rhStart, rhEnd === -1 ? undefined : rhEnd).includes("args"),
  "Neighboring block must not absorb an args line"
);

// A duplicate entry under a different name (hand-added dash variant) must be
// consolidated into the single canonical block on repair.
const duplicated = [
  "[mcp_servers.robinhood-trading]",
  "url = \"https://example.com/mcp\"",
  "",
  "[mcp_servers.openassist-knowledge]",
  "command = \"/opt/homebrew/bin/node\"",
  "args = [\"/x/bin/openassist-knowledge.mjs\", \"mcp\", \"--stdio\"]",
  "",
  `[mcp_servers.${serverName}]`,
  "command = \"node\"",
  "args = [\"/x/bin/openassist-knowledge.mjs\", \"mcp\", \"--stdio\"]"
].join("\n");
const consolidated = merge(duplicated);
assert.ok(!consolidated.includes("[mcp_servers.openassist-knowledge]"), "Dash-named duplicate block must be removed whole");
assert.equal(
  (consolidated.match(/openassist-knowledge\.mjs/g) || []).length, 1,
  "Exactly one proxy reference after consolidation"
);
assert.ok(consolidated.includes("[mcp_servers.robinhood-trading]\nurl = \"https://example.com/mcp\""), "Unrelated servers survive consolidation");
assert.equal(
  bridgeSource.includes("raw.split(\"openassist-knowledge.mjs\").length - 1 === 1"),
  true,
  "Health check must count proxy references so duplicates surface as Needs repair"
);

console.log("verify:integration-merge passed");
