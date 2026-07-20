import { readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, resolve, sep } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import {
  getDefaultEnvironment,
  StdioClientTransport
} from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { parse as parseTOML } from "smol-toml";

type JsonObject = Record<string, unknown>;

type MCPServerConfig = {
  command?: string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string>;
  url?: string;
  enabled?: boolean;
  disabled?: boolean;
  startup_timeout_sec?: number;
  tool_timeout_sec?: number;
};

type MCPConnection = {
  client: Client;
  close: () => Promise<void>;
};

type MCPToolRecord = {
  toolID: string;
  server: string;
  name: string;
  title: string;
  description: string;
  inputSchema: JsonObject;
  required: string[];
  readOnly: boolean;
  destructive: boolean;
  requiresConfirmation: boolean;
  client: Client;
};

export type RealtimeMCPServerSummary = {
  name: string;
  enabled: boolean;
  allowed: boolean;
  transport: "stdio" | "localhost" | "unsupported";
  status: "ready" | "available" | "disabled" | "blocked" | "error";
  toolCount: number;
  error?: string;
};

export type RealtimeMCPHarnessOptions = {
  enabled: boolean;
  allowedServers?: string[];
  autoAllowLocalPackages?: boolean;
  configPath?: string;
  log?: (message: string) => void;
};

const defaultConfigPath = resolve(homedir(), ".codex", "config.toml");
const localPackageRoot = resolve(homedir(), ".codex", "mcp-packages");
const deniedServerNames = new Set([
  "computer-use",
  "node_repl",
  "openassist_knowledge",
  "playwright"
]);
const writeNamePattern = /(?:^|_)(?:add|append|approve|assign|cancel|complete|create|delete|download|edit|execute|import|link|merge|move|patch|publish|reject|remove|reply|run|set|start|stop|trigger|unlink|update|upload|vote|write)(?:_|$)/i;
const readNamePattern = /(?:^|_)(?:check|find|get|list|lookup|query|read|search|show|status|view)(?:_|$)/i;
const maxToolResultChars = 28_000;
const maxToolsPerServer = 250;
const toolSearchStopWords = new Set([
  "a", "an", "and", "any", "are", "can", "check", "could", "do", "does", "for", "from", "have",
  "if", "in", "is", "it", "of", "on", "or", "please", "the", "to", "was", "were", "what", "when",
  "where", "whether", "which", "with", "would", "you", "your"
]);

function asObject(value: unknown): JsonObject | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : undefined;
}

function asStringArray(value: unknown) {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string" && Boolean(item.trim())).map((item) => item.trim())
    : [];
}

function asStringMap(value: unknown) {
  const object = asObject(value);
  if (!object) return undefined;
  const entries = Object.entries(object).filter((entry): entry is [string, string] => typeof entry[1] === "string");
  return Object.fromEntries(entries);
}

function boundedTimeout(value: unknown, fallbackMs: number, maximumMs: number) {
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds <= 0) return fallbackMs;
  return Math.min(maximumMs, Math.max(1_000, Math.round(seconds * 1_000)));
}

function isPathInside(candidate: string, root: string) {
  const normalizedCandidate = resolve(candidate);
  const normalizedRoot = resolve(root);
  return normalizedCandidate === normalizedRoot || normalizedCandidate.startsWith(`${normalizedRoot}${sep}`);
}

function localPackageServer(config: MCPServerConfig) {
  const candidates = [config.command, ...(config.args || [])]
    .filter((value): value is string => Boolean(value && isAbsolute(value)));
  return candidates.some((candidate) => isPathInside(candidate, localPackageRoot));
}

function localhostURL(rawURL: string) {
  try {
    const url = new URL(rawURL);
    return ["127.0.0.1", "::1", "localhost"].includes(url.hostname) ? url : null;
  } catch {
    return null;
  }
}

function serverTransport(config: MCPServerConfig): RealtimeMCPServerSummary["transport"] {
  if (config.command) return "stdio";
  if (config.url && localhostURL(config.url)) return "localhost";
  return "unsupported";
}

function cleanError(error: unknown) {
  const message = error instanceof Error ? error.message : String(error || "Unknown MCP error");
  return message.replace(/\s+/g, " ").trim().slice(0, 500);
}

function normalizedWords(value: string) {
  const normalized = value
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .toLowerCase()
    .replace(/azure devops/g, "ado azure devops")
    .replace(/work[\s_-]*items?/g, "work item wit")
    .replace(/pull[\s_-]*requests?/g, "pull request pr git")
    .replace(/test[\s_-]*plans?/g, "test plan")
    .replace(/\bbuilds?\b/g, "build pipeline")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
  return [...new Set(
    normalized.split(/\s+/).filter((word) => word.length > 1 && !toolSearchStopWords.has(word))
  )];
}

function schemaSearchText(schema: JsonObject) {
  const properties = asObject(schema.properties) || {};
  return Object.entries(properties).map(([name, rawProperty]) => {
    const property = asObject(rawProperty) || {};
    const enumValues = Array.isArray(property.enum) ? property.enum.join(" ") : "";
    return `${name} ${String(property.description || "")} ${enumValues}`;
  }).join(" ");
}

function missingRequiredArguments(tool: MCPToolRecord, args: JsonObject) {
  return tool.required.filter((name) => {
    if (!Object.prototype.hasOwnProperty.call(args, name)) return true;
    const value = args[name];
    if (value === undefined || value === null) return true;
    if (typeof value === "string" && !value.trim()) return true;
    if (Array.isArray(value) && !value.length) return true;
    return false;
  });
}

function schemaSummary(schema: JsonObject) {
  const properties = asObject(schema.properties) || {};
  const required = new Set(asStringArray(schema.required));
  return Object.entries(properties).slice(0, 30).map(([name, rawProperty]) => {
    const property = asObject(rawProperty) || {};
    return {
      name,
      type: typeof property.type === "string" ? property.type : "unknown",
      required: required.has(name),
      description: typeof property.description === "string" ? property.description.slice(0, 300) : "",
      enum: Array.isArray(property.enum) ? property.enum.slice(0, 20) : undefined
    };
  });
}

function outputText(result: unknown) {
  const object = asObject(result);
  if (!object) return String(result || "").slice(0, maxToolResultChars);
  const chunks: string[] = [];
  const content = Array.isArray(object.content) ? object.content : [];
  for (const rawItem of content) {
    const item = asObject(rawItem);
    if (!item) continue;
    if (item.type === "text" && typeof item.text === "string") chunks.push(item.text);
    if (item.type === "resource") {
      const resource = asObject(item.resource);
      if (resource && typeof resource.text === "string") chunks.push(resource.text);
    }
    if (item.type === "image") chunks.push(`[Image returned: ${String(item.mimeType || "image")}]`);
    if (item.type === "audio") chunks.push(`[Audio returned: ${String(item.mimeType || "audio")}]`);
    if (item.type === "resource_link") chunks.push(`[Resource: ${String(item.name || item.uri || "link")}]`);
  }
  if (object.structuredContent) {
    try {
      chunks.push(JSON.stringify(object.structuredContent));
    } catch {
      // Ignore non-serializable structured content and keep the readable text.
    }
  }
  if (!chunks.length && "toolResult" in object) {
    try {
      chunks.push(JSON.stringify(object.toolResult));
    } catch {
      chunks.push(String(object.toolResult || ""));
    }
  }
  return chunks.join("\n").trim().slice(0, maxToolResultChars);
}

function toolSafety(name: string, description: string, annotations: JsonObject | undefined) {
  const declaredReadOnly = annotations?.readOnlyHint === true;
  const declaredDestructive = annotations?.destructiveHint === true;
  const inferredWrite = writeNamePattern.test(name);
  const inferredRead = readNamePattern.test(name)
    || /^(?:check|fetch|find|get|list|look up|query|read|retrieve|return|search|show|view)\b/i.test(description.trim());
  const readOnly = declaredReadOnly || (!declaredDestructive && !inferredWrite && inferredRead);
  return {
    readOnly,
    destructive: declaredDestructive || inferredWrite,
    requiresConfirmation: !readOnly
  };
}

export class LocalMCPHarness {
  private options: RealtimeMCPHarnessOptions = { enabled: false };
  private signature = "";
  private configMtimeMs = 0;
  private configServers = new Map<string, MCPServerConfig>();
  private connections = new Map<string, MCPConnection>();
  private tools = new Map<string, MCPToolRecord>();
  private summaries = new Map<string, RealtimeMCPServerSummary>();
  private discoveryPromise?: Promise<void>;

  configure(options: RealtimeMCPHarnessOptions) {
    const next: RealtimeMCPHarnessOptions = {
      ...options,
      allowedServers: [...new Set((options.allowedServers || []).map((name) => name.trim()).filter(Boolean))],
      configPath: options.configPath || defaultConfigPath
    };
    const nextSignature = JSON.stringify({
      enabled: next.enabled,
      allowedServers: next.allowedServers,
      autoAllowLocalPackages: next.autoAllowLocalPackages !== false,
      configPath: next.configPath
    });
    this.options = next;
    if (nextSignature === this.signature) return;
    this.signature = nextSignature;
    this.reset();
  }

  async serverSummaries() {
    await this.loadConfig();
    return [...this.summaries.values()].sort((left, right) => left.name.localeCompare(right.name));
  }

  async findTools(rawArgs: JsonObject) {
    const startedAt = Date.now();
    const query = String(rawArgs.query || rawArgs.prompt || "").trim();
    const serverHint = String(rawArgs.server || "").trim().toLowerCase();
    const limit = Math.min(8, Math.max(1, Number(rawArgs.limit) || 5));
    if (!this.options.enabled) {
      return { ok: false, error: "Local MCP tools are disabled in OpenAssist settings.", matches: [] };
    }
    if (!query) return { ok: false, error: "A tool search query is required.", matches: [] };
    await this.ensureDiscovered();
    const queryWords = normalizedWords(query);
    const queryAsToolName = query.toLowerCase().replace(/[^a-z0-9]+/g, "_");
    const queryLooksReadOnly = readNamePattern.test(queryAsToolName) && !writeNamePattern.test(queryAsToolName);
    const queryLooksLikeWrite = writeNamePattern.test(queryAsToolName);
    const hasNumericID = /\b\d{2,}\b/.test(query);
    const candidateTools = [...this.tools.values()].filter(
      (tool) => !serverHint || tool.server.toLowerCase() === serverHint
    );
    const searchWords = new Map(candidateTools.map((tool) => [
      tool.toolID,
      normalizedWords(`${tool.server} ${tool.name} ${tool.title} ${tool.description} ${schemaSearchText(tool.inputSchema)}`)
    ]));
    const documentFrequency = new Map<string, number>();
    for (const words of searchWords.values()) {
      for (const word of words) documentFrequency.set(word, (documentFrequency.get(word) || 0) + 1);
    }
    const searchableQueryWords = queryWords.filter((word) => documentFrequency.has(word));
    const inverseFrequency = (word: string) => (
      Math.log((candidateTools.length + 1) / ((documentFrequency.get(word) || 0) + 1)) + 0.25
    );
    const totalQueryWeight = searchableQueryWords.reduce((total, word) => total + inverseFrequency(word), 0);
    const scored = candidateTools.map((tool) => {
      const nameText = tool.name.replace(/_/g, " ").toLowerCase();
      const haystack = searchWords.get(tool.toolID) || [];
      const haystackSet = new Set(haystack);
      const matchedWeight = searchableQueryWords.reduce(
        (total, word) => total + (haystackSet.has(word) ? inverseFrequency(word) : 0),
        0
      );
      const coverage = totalQueryWeight > 0 ? matchedWeight / totalQueryWeight : 0;
      let score = coverage * 0.72;
      if (serverHint && tool.server.toLowerCase() === serverHint) score += 0.25;
      if (query.toLowerCase().includes(tool.server.toLowerCase())) score += 0.12;
      if (nameText.includes(query.toLowerCase())) score += 0.2;
      if (hasNumericID && /(?:^|_)get_work_item$/i.test(tool.name)) score += 0.2;
      if (/\bstatus\b/i.test(query) && /(?:status|get|show|list)/i.test(tool.name)) score += 0.08;
      if (/\b(comment|comments)\b/i.test(query) && /comment/i.test(tool.name)) score += 0.12;
      if (queryLooksReadOnly && tool.readOnly) score += 0.08;
      if (queryLooksReadOnly && tool.requiresConfirmation) score -= 0.12;
      if (queryLooksLikeWrite && tool.requiresConfirmation) score += 0.06;
      return { tool, score: Math.min(0.99, score) };
    }).filter(({ score }) => score >= 0.12);
    scored.sort((left, right) => right.score - left.score || Number(right.tool.readOnly) - Number(left.tool.readOnly));
    const matches = scored.slice(0, limit).map(({ tool, score }) => ({
      toolID: tool.toolID,
      server: tool.server,
      name: tool.name,
      title: tool.title,
      description: tool.description,
      confidence: Number(score.toFixed(2)),
      readOnly: tool.readOnly,
      requiresConfirmation: tool.requiresConfirmation,
      required: tool.required,
      arguments: schemaSummary(tool.inputSchema)
    }));
    return {
      ok: true,
      query,
      matches,
      searchedServers: [...this.connections.keys()],
      serverErrors: [...this.summaries.values()].filter((server) => server.status === "error").map((server) => ({
        server: server.name,
        error: server.error
      })),
      elapsedMs: Date.now() - startedAt
    };
  }

  async callTool(rawArgs: JsonObject) {
    const startedAt = Date.now();
    if (!this.options.enabled) return { ok: false, error: "Local MCP tools are disabled in OpenAssist settings." };
    await this.ensureDiscovered();
    const toolID = String(rawArgs.toolID || rawArgs.tool_id || "").trim();
    const tool = this.tools.get(toolID);
    if (!tool) {
      return { ok: false, error: "That local MCP tool is not available. Search for the tool again.", toolID };
    }
    const argumentsValue = asObject(rawArgs.arguments) || {};
    const missingArguments = missingRequiredArguments(tool, argumentsValue);
    if (missingArguments.length) {
      return {
        ok: false,
        clarificationRequired: true,
        toolID: tool.toolID,
        server: tool.server,
        tool: tool.name,
        missingArguments,
        arguments: schemaSummary(tool.inputSchema),
        prompt: `The selected tool still needs: ${missingArguments.join(", ")}. Ask the user only for values that cannot be safely inferred from the request.`
      };
    }
    const confirmed = rawArgs.confirmed === true;
    if (tool.requiresConfirmation && !confirmed) {
      return {
        ok: false,
        confirmationRequired: true,
        toolID: tool.toolID,
        server: tool.server,
        tool: tool.name,
        prompt: `This will run the ${tool.title || tool.name} write action in ${tool.server}. Ask the user to confirm before calling it again with confirmed=true.`
      };
    }
    const config = this.configServers.get(tool.server) || {};
    const timeout = boundedTimeout(config.tool_timeout_sec, 30_000, 60_000);
    try {
      const result = await tool.client.callTool(
        { name: tool.name, arguments: argumentsValue },
        undefined,
        { timeout }
      );
      const object = asObject(result);
      const text = outputText(result) || (object?.isError ? "The MCP tool returned an error without details." : "The MCP tool completed without text output.");
      return {
        ok: object?.isError !== true,
        server: tool.server,
        tool: tool.name,
        toolID: tool.toolID,
        resultText: text,
        isError: object?.isError === true,
        elapsedMs: Date.now() - startedAt
      };
    } catch (error) {
      const message = cleanError(error);
      this.options.log?.(`[realtime.mcp] call failed server=${tool.server} tool=${tool.name} error=${message}`);
      return {
        ok: false,
        server: tool.server,
        tool: tool.name,
        toolID: tool.toolID,
        error: message,
        elapsedMs: Date.now() - startedAt
      };
    }
  }

  async close() {
    const connections = [...this.connections.values()];
    this.connections.clear();
    this.tools.clear();
    this.discoveryPromise = undefined;
    await Promise.allSettled(connections.map((connection) => connection.close()));
  }

  private reset() {
    this.configMtimeMs = 0;
    this.configServers.clear();
    this.summaries.clear();
    void this.close();
  }

  private serverAllowed(name: string, config: MCPServerConfig) {
    if (!this.options.enabled || config.enabled === false || config.disabled === true) return false;
    if (deniedServerNames.has(name.toLowerCase())) return false;
    if ((this.options.allowedServers || []).some((allowedName) => allowedName.toLowerCase() === name.toLowerCase())) return true;
    return this.options.autoAllowLocalPackages !== false && localPackageServer(config);
  }

  private async loadConfig() {
    const configPath = this.options.configPath || defaultConfigPath;
    try {
      const info = await stat(configPath);
      if (info.mtimeMs === this.configMtimeMs && this.configServers.size) return;
      if (this.configMtimeMs && info.mtimeMs !== this.configMtimeMs) await this.close();
      const parsed = asObject(parseTOML(await readFile(configPath, "utf8"))) || {};
      const rawServers = asObject(parsed.mcp_servers) || {};
      this.configServers.clear();
      this.summaries.clear();
      for (const [name, rawConfig] of Object.entries(rawServers)) {
        const object = asObject(rawConfig) || {};
        const config: MCPServerConfig = {
          command: typeof object.command === "string" ? object.command : undefined,
          args: asStringArray(object.args),
          cwd: typeof object.cwd === "string" ? object.cwd : undefined,
          env: asStringMap(object.env),
          url: typeof object.url === "string" ? object.url : undefined,
          enabled: typeof object.enabled === "boolean" ? object.enabled : undefined,
          disabled: typeof object.disabled === "boolean" ? object.disabled : undefined,
          startup_timeout_sec: Number(object.startup_timeout_sec),
          tool_timeout_sec: Number(object.tool_timeout_sec)
        };
        const transport = serverTransport(config);
        const configuredEnabled = config.enabled !== false && config.disabled !== true;
        const allowed = this.serverAllowed(name, config);
        this.configServers.set(name, config);
        this.summaries.set(name, {
          name,
          enabled: configuredEnabled,
          allowed,
          transport,
          status: !configuredEnabled ? "disabled" : allowed ? "available" : "blocked",
          toolCount: 0
        });
      }
      this.configMtimeMs = info.mtimeMs;
    } catch (error) {
      this.configServers.clear();
      this.summaries.clear();
      this.summaries.set("Codex MCP config", {
        name: "Codex MCP config",
        enabled: false,
        allowed: false,
        transport: "unsupported",
        status: "error",
        toolCount: 0,
        error: cleanError(error)
      });
    }
  }

  private async ensureDiscovered() {
    await this.loadConfig();
    if (this.discoveryPromise) return this.discoveryPromise;
    this.discoveryPromise = this.discoverTools().finally(() => {
      this.discoveryPromise = undefined;
    });
    return this.discoveryPromise;
  }

  private async discoverTools() {
    const candidates = [...this.configServers.entries()].filter(([name, config]) => this.serverAllowed(name, config));
    await Promise.all(candidates.map(async ([name, config]) => {
      if (this.connections.has(name)) return;
      const summary = this.summaries.get(name);
      try {
        const connection = await this.connectServer(name, config);
        this.connections.set(name, connection);
        let cursor: string | undefined;
        let count = 0;
        do {
          const listed = await connection.client.listTools(cursor ? { cursor } : undefined, {
            timeout: boundedTimeout(config.startup_timeout_sec, 15_000, 30_000)
          });
          for (const rawTool of listed.tools) {
            if (count >= maxToolsPerServer) break;
            const annotations = asObject(rawTool.annotations);
            const description = String(rawTool.description || "").slice(0, 2_000);
            const safety = toolSafety(rawTool.name, description, annotations);
            const inputSchema = asObject(rawTool.inputSchema) || { type: "object" };
            const toolID = `${name}::${rawTool.name}`;
            this.tools.set(toolID, {
              toolID,
              server: name,
              name: rawTool.name,
              title: String(rawTool.title || annotations?.title || rawTool.name),
              description,
              inputSchema,
              required: asStringArray(inputSchema.required),
              ...safety,
              client: connection.client
            });
            count += 1;
          }
          cursor = count < maxToolsPerServer ? listed.nextCursor : undefined;
        } while (cursor);
        if (summary) {
          summary.status = "ready";
          summary.toolCount = count;
          delete summary.error;
        }
        this.options.log?.(`[realtime.mcp] ready server=${name} tools=${count}`);
      } catch (error) {
        const message = cleanError(error);
        if (summary) {
          summary.status = "error";
          summary.error = message;
        }
        this.options.log?.(`[realtime.mcp] unavailable server=${name} error=${message}`);
      }
    }));
  }

  private async connectServer(name: string, config: MCPServerConfig): Promise<MCPConnection> {
    const client = new Client({ name: "OpenAssist Realtime MCP", version: "1.0.0" });
    const timeout = boundedTimeout(config.startup_timeout_sec, 15_000, 30_000);
    if (config.command) {
      const transport = new StdioClientTransport({
        command: config.command,
        args: config.args,
        cwd: config.cwd,
        env: { ...getDefaultEnvironment(), ...(config.env || {}) },
        stderr: "pipe"
      });
      transport.stderr?.on("data", (chunk) => {
        const message = String(chunk || "").replace(/\s+/g, " ").trim();
        if (message) this.options.log?.(`[realtime.mcp] ${name}: ${message.slice(0, 500)}`);
      });
      await client.connect(transport, { timeout });
      return { client, close: () => client.close() };
    }
    const url = config.url ? localhostURL(config.url) : null;
    if (url) {
      const transport = new StreamableHTTPClientTransport(url);
      await client.connect(transport, { timeout });
      return { client, close: () => client.close() };
    }
    throw new Error(`MCP server ${name} does not use an approved local transport.`);
  }
}
