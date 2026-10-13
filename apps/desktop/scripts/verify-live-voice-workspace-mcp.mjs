import assert from "node:assert/strict";
import path from "node:path";

const { CodexPluginMCPBroker } = await import(path.toNamespacedPath(path.resolve("dist-electron/codexPluginMcpBroker.js")));

const requests = [];
const closedThreads = [];
const broker = new CodexPluginMCPBroker({
  openThread: async () => "voice-thread-1",
  closeThread: async (threadID) => closedThreads.push(threadID),
  request: async (method, params) => {
    requests.push({ method, params });
    if (method === "mcpServerStatus/list") {
      return {
        data: [{
          name: "google-mail-hub",
          tools: [
            {
              name: "list_google_tasks",
              description: "List Google Tasks from a connected Google account.",
              inputSchema: { type: "object", properties: { account: { type: "string" } } },
              annotations: { readOnlyHint: true }
            },
            {
              name: "create_google_task",
              description: "Create a Google Task in a connected Google account.",
              inputSchema: { type: "object", properties: { title: { type: "string" } } }
            },
            { name: "search_google_mail", description: "Search Gmail.", annotations: { readOnlyHint: true } }
          ]
        }]
      };
    }
    if (method === "mcpServer/tool/call") {
      return { content: [{ type: "text", text: JSON.stringify({ created: true, title: params.arguments.title }) }] };
    }
    throw new Error(`Unexpected request: ${method}`);
  }
});

const discovered = await broker.findTools({ query: "check my Google Tasks", limit: 3 });
assert.equal(discovered.source, "OpenAssist Workspace");
assert.equal(discovered.matches[0].name, "list_google_tasks");
assert.equal(discovered.matches[0].readOnly, true);

const createTool = discovered.matches.find((match) => match.name === "create_google_task");
assert.ok(createTool, "Expected the Google Task write tool to be discoverable.");
const approval = await broker.callTool({ toolID: createTool.toolID, arguments: { title: "Post video" } });
assert.equal(approval.confirmationRequired, true);
assert.equal(requests.filter((request) => request.method === "mcpServer/tool/call").length, 0);

const created = await broker.callTool({ toolID: createTool.toolID, arguments: { title: "Post video" }, confirmed: true });
assert.equal(created.ok, true);
assert.match(created.resultText, /Post video/);
assert.equal(requests.filter((request) => request.method === "mcpServer/tool/call").length, 1);
assert.ok(closedThreads.length >= 3, "Every temporary authorization thread should be closed.");

const namedApproval = await broker.callNamedTool("create_google_task", { title: "Named write" });
assert.equal(namedApproval.confirmationRequired, true);
const namedCreated = await broker.callNamedTool("create_google_task", { title: "Named write" }, true);
assert.equal(namedCreated.ok, true);
assert.match(namedCreated.resultText, /Named write/);
await assert.rejects(
  () => broker.callNamedTool("missing_tool", {}, true),
  /does not currently expose missing_tool/
);

await assert.rejects(
  () => broker.callTool({ toolID: "local-mcp::bad", arguments: {} }),
  /Select an exact OpenAssist Workspace tool/
);

console.log("Live Voice OpenAssist Workspace MCP checks passed.");

const hostedRequests = [];
const hostedRequest = async (method, params) => {
    hostedRequests.push({ method, params });
    if (method === "mcpServerStatus/list") {
      return {
        data: [{
          name: "codex_apps",
          tools: {
            "another_connector.search_records": {
              name: "another_connector.search_records",
              title: "search_records",
              description: "Search another connected service.",
              annotations: { readOnlyHint: true },
              _meta: {
                connector_name: "Another Connector",
                connector_id: "connector_another"
              }
            },
            "openassist_workspace.list_google_tasks": {
              name: "openassist_workspace.list_google_tasks",
              title: "list_google_tasks",
              description: "List Google Tasks. This tool is part of plugin `OpenAssist Workspace`.",
              inputSchema: { type: "object", properties: { account: { type: "string" } } },
              annotations: { readOnlyHint: true }
            },
            "openassist_workspace.create_google_task": {
              name: "openassist_workspace.create_google_task",
              title: "create_google_task",
              description: "Create a Google Task. This tool is part of plugin `OpenAssist Workspace`.",
              inputSchema: { type: "object", properties: { title: { type: "string" } } },
              annotations: { readOnlyHint: false }
            }
          }
        }]
      };
    }
    if (method === "mcpServer/tool/call") {
      return { content: [{ type: "text", text: JSON.stringify({ tasks: [] }) }] };
    }
    if (method === "app/list") {
      return {
        data: [
          {
            id: "app_spotify",
            name: "Spotify",
            installUrl: "https://chatgpt.com/connectors/spotify/setup",
            isAccessible: false,
            isEnabled: true,
            pluginDisplayNames: ["Spotify"]
          },
          {
            id: "connector_another",
            name: "Another Connector",
            installUrl: "https://chatgpt.com/connectors/another/setup",
            isAccessible: true,
            isEnabled: true,
            pluginDisplayNames: ["Another Connector"]
          }
        ],
        nextCursor: null
      };
    }
    throw new Error(`Unexpected hosted request: ${method}`);
};
const hostedBroker = new CodexPluginMCPBroker({
  openThread: async () => "voice-thread-hosted",
  closeThread: async () => undefined,
  request: hostedRequest
});

const hostedDiscovery = await hostedBroker.findTools({ query: "list my Google Tasks", limit: 5 });
assert.equal(hostedDiscovery.matches[0].name, "list_google_tasks");
assert.equal(hostedDiscovery.matches.some((match) => match.name === "create_google_task"), true);
assert.equal(hostedDiscovery.matches.some((match) => match.toolID.includes("another_connector")), false);
assert.equal(hostedDiscovery.matches[0].server, "codex_apps");
assert.equal(hostedDiscovery.matches[0].readOnly, true);

const hostedCall = await hostedBroker.callTool({
  toolID: hostedDiscovery.matches[0].toolID,
  arguments: { account: "Main" }
});
assert.equal(hostedCall.ok, true);
assert.equal(hostedCall.tool, "list_google_tasks");
assert.equal(hostedRequests.find((request) => request.method === "mcpServer/tool/call").params.tool, "openassist_workspace.list_google_tasks");

console.log("Hosted OpenAssist Workspace connector checks passed.");

const genericBroker = new CodexPluginMCPBroker({
  openThread: async () => "voice-thread-generic",
  closeThread: async () => undefined,
  serverAliases: [],
  sentinelTools: [],
  displayName: "Requested plugin",
  openExternal: async (url) => hostedRequests.push({ method: "openExternal", params: { url } }),
  request: hostedRequest
});

const genericDiscovery = await genericBroker.findTools({
  server: "Another Connector",
  query: "search records",
  limit: 5
});
assert.equal(genericDiscovery.source, "Another Connector");
assert.equal(genericDiscovery.matches.length, 1);
assert.equal(genericDiscovery.matches[0].name, "search_records");
assert.equal(genericDiscovery.matches[0].pluginName, "Another Connector");
assert.equal(genericDiscovery.matches[0].readOnly, true);

const genericCall = await genericBroker.callTool({
  toolID: genericDiscovery.matches[0].toolID,
  arguments: { query: "recent" }
});
assert.equal(genericCall.ok, true);
assert.equal(genericCall.source, "Another Connector");

const setup = await genericBroker.connectPlugin({ plugin: "Spotify" });
assert.equal(setup.ok, true);
assert.equal(setup.status, "setup_opened");
assert.equal(setup.plugin, "Spotify");
assert.equal(hostedRequests.some((request) => request.method === "openExternal" && request.params.url.includes("spotify")), true);

const alreadyConnected = await genericBroker.connectPlugin({ plugin: "Another Connector" });
assert.equal(alreadyConnected.ok, true);
assert.equal(alreadyConnected.status, "connected");
assert.equal(alreadyConnected.alreadyConnected, true);

console.log("Generic connected plugin routing checks passed.");
