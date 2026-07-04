import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const bridgePath = path.resolve("electron/openassistBridge.ts");
const mainPath = path.resolve("electron/main.ts");
const knowledgeCliPath = path.resolve("bin/openassist-knowledge.mjs");

const bridge = fs.readFileSync(bridgePath, "utf8");
const main = fs.readFileSync(mainPath, "utf8");
const knowledgeCli = fs.readFileSync(knowledgeCliPath, "utf8");

assert.match(bridge, /openAssistInfoPlistCacheMs\s*=\s*5\s*\*\s*60\s*\*\s*1000/, "Info.plist reads should be cached for idle CPU safety.");
assert.match(bridge, /openAssistInfoPlistInFlight/, "Info.plist reads should coalesce in-flight plutil calls.");
assert.match(bridge, /executablePathCacheMs\s*=\s*5\s*\*\s*60\s*\*\s*1000/, "Executable lookup should be cached for idle CPU safety.");
assert.match(bridge, /executablePathInFlight/, "Executable lookup should coalesce in-flight which calls.");
assert.match(bridge, /cachedSelectableAssistantBackends\(assistantBackend\)/, "Settings snapshots should use cached backend detection.");
assert.match(bridge, /providerModelsCacheMs\s*=\s*5\s*\*\s*60\s*\*\s*1000/, "Provider model lists should not refresh on every idle snapshot.");
assert.doesNotMatch(bridge, /providerModelsCache\.set\(backend,\s*\{\s*expiresAt:\s*now\s*\+\s*60_000/, "Provider model cache should not use the old one-minute TTL.");
assert.match(bridge, /knowledgeAccessSettingsCacheMs\s*=\s*3_000/, "Knowledge MCP should use a lightweight cached settings snapshot.");
assert.match(bridge, /loadKnowledgeAccessSettings\(\)/, "Knowledge MCP should not load the full app settings snapshot per request.");
assert.match(bridge, /server\.keepAliveTimeout\s*=\s*5_000/, "Knowledge HTTP keep-alive should expire idle stale clients.");
assert.match(bridge, /server\.maxRequestsPerSocket\s*=\s*100/, "Knowledge HTTP should recycle busy keep-alive sockets.");
assert.match(bridge, /maxKnowledgeMCPRequestBytes\s*=\s*1024\s*\*\s*1024/, "Knowledge MCP request bodies should be bounded.");
assert.match(bridge, /readRequestJSON\(req,\s*maxKnowledgeMCPRequestBytes\)/, "Knowledge MCP should use the bounded JSON reader.");
assert.match(bridge, /cachedKnowledgeMCPToolsForSettings\(settings\)/, "Knowledge MCP tools/list should be cached.");
assert.match(bridge, /cachedKnowledgeMCPResources\(\)/, "Knowledge MCP resources/list should be cached.");

assert.match(main, /frontmostSnapshotInFlight/, "Frontmost-app polling should have an in-flight guard.");
assert.match(main, /frontmostTrackerIntervalMs\s*=\s*5_000/, "Frontmost-app polling should not fork osascript every 1.2 seconds.");
assert.match(main, /if\s*\(frontmostSnapshotInFlight\)\s*return frontmostSnapshotInFlight/, "Frontmost-app polling should not overlap.");
assert.doesNotMatch(
  main,
  /frontmostTrackerTimer\s*=\s*setInterval\(\(\)\s*=>\s*\{\s*void refreshFrontmostApplicationSnapshot\(\);\s*\},\s*1200\)/,
  "Frontmost-app polling should not use the old 1200ms interval."
);

assert.ok(
  (knowledgeCli.match(/connection:\s*"close"/g) || []).length >= 2,
  "Knowledge CLI should close proxy HTTP sockets instead of keeping stale idle connections."
);
assert.match(knowledgeCli, /mcpMetadataCacheMs/, "Knowledge CLI should cache MCP metadata calls locally.");
assert.match(knowledgeCli, /cachedMCPMetadataResponse\(message\)/, "Knowledge CLI should serve repeated MCP metadata calls from cache.");
assert.match(knowledgeCli, /rememberMCPMetadataResponse\(message,\s*payload\)/, "Knowledge CLI should remember successful MCP metadata responses.");

console.log("Idle CPU guards verified.");
