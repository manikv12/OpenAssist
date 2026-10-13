type JsonObject = Record<string, unknown>;

export type CodexPluginMCPRequest = (
  method: string,
  params: JsonObject,
  timeoutMs?: number
) => Promise<unknown>;

export type CodexPluginMCPThreadFactory = () => Promise<string>;
export type CodexPluginMCPThreadCloser = (threadID: string) => Promise<void> | void;

type CodexPluginMCPBrokerOptions = {
  request: CodexPluginMCPRequest;
  openThread: CodexPluginMCPThreadFactory;
  closeThread: CodexPluginMCPThreadCloser;
  openExternal?: (url: string) => Promise<unknown> | unknown;
  serverAliases?: string[];
  sentinelTools?: string[];
  displayName?: string;
};

type ToolRecord = {
  server: string;
  pluginID: string;
  pluginName: string;
  name: string;
  displayName: string;
  description: string;
  inputSchema: JsonObject;
  readOnly: boolean;
};

type AppRecord = {
  id: string;
  name: string;
  installUrl: string;
  isAccessible: boolean;
  isEnabled: boolean;
  pluginDisplayNames: string[];
};

const toolIDPrefix = "codex-plugin-mcp::";

function objectValue(value: unknown): JsonObject | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : null;
}

function firstString(...values: unknown[]) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
}

function normalized(value: unknown) {
  return firstString(value).toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function encodedToolID(server: string, tool: string) {
  return `${toolIDPrefix}${encodeURIComponent(server)}::${encodeURIComponent(tool)}`;
}

function decodedToolID(value: unknown) {
  const raw = firstString(value);
  if (!raw.startsWith(toolIDPrefix)) return null;
  const [serverPart, toolPart, ...extra] = raw.slice(toolIDPrefix.length).split("::");
  if (!serverPart || !toolPart || extra.length) return null;
  try {
    return { server: decodeURIComponent(serverPart), tool: decodeURIComponent(toolPart) };
  } catch {
    return null;
  }
}

function localToolName(name: string) {
  return name.split(/[.:/]/).filter(Boolean).pop() || name;
}

function toolNamespace(name: string) {
  const [namespace] = name.split(/[.:/]/).filter(Boolean);
  return namespace || "";
}

function toolIsReadOnly(name: string, tool: JsonObject) {
  const annotations = objectValue(tool.annotations) ?? objectValue(tool.toolAnnotations) ?? {};
  if (annotations.readOnlyHint === true || annotations.readOnly === true) return true;
  if (annotations.readOnlyHint === false || annotations.readOnly === false) return false;
  const localName = localToolName(name);
  return /^(get|list|search|read|find|fetch|lookup|inspect|check)_/i.test(localName)
    && !/^(set|create|update|delete|move|rename|remember|forget|send|mark)_/i.test(localName);
}

function serverTools(serverValue: unknown): ToolRecord[] {
  const server = objectValue(serverValue);
  if (!server) return [];
  const serverName = firstString(server.name, server.id, server.serverName);
  if (!serverName) return [];
  const serverPluginID = firstString(server.pluginId, server.pluginID);
  const toolsValue = server.tools;
  const entries: Array<[string, unknown]> = Array.isArray(toolsValue)
    ? toolsValue.map((tool, index) => [firstString(objectValue(tool)?.name, `tool-${index}`), tool])
    : Object.entries(objectValue(toolsValue) ?? {});
  return entries.flatMap(([mapName, toolValue]) => {
    const tool = objectValue(toolValue) ?? {};
    const name = firstString(tool.name, mapName);
    if (!name) return [];
    const meta = objectValue(tool._meta) ?? {};
    const codexAppsMeta = objectValue(meta._codex_apps) ?? {};
    const namespace = toolNamespace(name);
    const pluginName = firstString(
      meta.connector_name,
      codexAppsMeta.connector_name,
      serverPluginID.split("@")[0],
      namespace && namespace !== name ? namespace.replace(/_/g, " ") : "",
      serverName
    );
    return [{
      server: serverName,
      pluginID: firstString(meta.connector_id, serverPluginID),
      pluginName,
      name,
      displayName: firstString(tool.title, localToolName(name)),
      description: firstString(tool.description),
      inputSchema: objectValue(tool.inputSchema) ?? objectValue(tool.input_schema) ?? objectValue(tool.parameters) ?? {},
      readOnly: toolIsReadOnly(name, tool)
    }];
  });
}

function responseText(value: unknown) {
  const response = objectValue(value) ?? {};
  const structured = response.structuredContent;
  if (structured !== undefined) {
    try {
      return JSON.stringify(structured);
    } catch {
      return String(structured);
    }
  }
  const content = Array.isArray(response.content) ? response.content : [];
  return content
    .map((item) => firstString(objectValue(item)?.text))
    .filter(Boolean)
    .join("\n")
    .trim();
}

function appRecords(value: unknown): { apps: AppRecord[]; nextCursor: string } {
  const response = objectValue(value) ?? {};
  const data = Array.isArray(response.data) ? response.data : Array.isArray(response.apps) ? response.apps : [];
  return {
    apps: data.flatMap((itemValue) => {
      const item = objectValue(itemValue);
      if (!item) return [];
      const id = firstString(item.id, item.connectorId);
      const name = firstString(item.name, item.displayName, id);
      if (!id || !name) return [];
      return [{
        id,
        name,
        installUrl: firstString(item.installUrl),
        isAccessible: item.isAccessible === true,
        isEnabled: item.isEnabled !== false,
        pluginDisplayNames: Array.isArray(item.pluginDisplayNames)
          ? item.pluginDisplayNames.map(firstString).filter(Boolean)
          : []
      }];
    }),
    nextCursor: firstString(response.nextCursor)
  };
}

function safeSetupURL(value: string) {
  try {
    const parsed = new URL(value);
    if (parsed.protocol === "https:") return parsed.toString();
    if (parsed.protocol === "http:" && ["localhost", "127.0.0.1", "::1"].includes(parsed.hostname)) return parsed.toString();
  } catch {
    // Invalid or non-web setup URLs are never opened.
  }
  return "";
}

function scoreTool(tool: ToolRecord, query: string) {
  const terms = normalized(query).split(/\s+/).filter((term) => term.length > 2);
  if (!terms.length) return 1;
  const name = `${normalized(tool.name)} ${normalized(tool.displayName)}`;
  const description = normalized(tool.description);
  return terms.reduce((score, term) => score + (name.includes(term) ? 5 : 0) + (description.includes(term) ? 2 : 0), 0);
}

export class CodexPluginMCPBroker {
  private readonly aliases: string[];
  private readonly sentinels: Set<string>;
  private readonly displayName: string;

  constructor(private readonly options: CodexPluginMCPBrokerOptions) {
    this.aliases = (options.serverAliases ?? ["google-mail-hub", "openassist workspace"]).map(normalized).filter(Boolean);
    this.sentinels = new Set((options.sentinelTools ?? ["list_google_accounts", "search_google_mail"]).map((name) => name.toLowerCase()));
    this.displayName = firstString(options.displayName, "OpenAssist Workspace");
  }

  private toolMatchesPlugin(tool: ToolRecord, hint: string) {
    const needle = normalized(hint);
    if (!needle) return true;
    const pluginName = normalized(tool.pluginName);
    const haystack = normalized([
      tool.pluginName,
      tool.pluginID,
      tool.server,
      toolNamespace(tool.name)
    ].join(" "));
    return haystack.includes(needle) || Boolean(pluginName && needle.includes(pluginName));
  }

  private async withTools<T>(run: (threadID: string, tools: ToolRecord[]) => Promise<T>, pluginHint = "") {
    const threadID = await this.options.openThread();
    try {
      const status = objectValue(await this.options.request("mcpServerStatus/list", {
        threadId: threadID,
        detail: "toolsAndAuthOnly",
        limit: 100
      }, 30_000)) ?? {};
      const servers = Array.isArray(status.data) ? status.data : [];
      const candidates = servers.flatMap((server) => {
        const tools = serverTools(server);
        const serverObject = objectValue(server) ?? {};
        const serverName = normalized(serverObject.name);
        const serverPluginID = firstString(serverObject.pluginId, serverObject.pluginID);
        const serverMatches = this.aliases.some((alias) => serverName.includes(alias));
        const sentinelMatches = tools.some((tool) => this.sentinels.has(localToolName(tool.name).toLowerCase()));
        const pluginBacked = Boolean(serverPluginID)
          || serverName === "codex apps"
          || serverMatches
          || sentinelMatches;
        if (!pluginBacked) return [];
        return tools.filter((tool) => {
          const fullName = normalized(tool.name);
          const localName = localToolName(tool.name).toLowerCase();
          const defaultScopeMatches = !this.aliases.length
            || serverMatches
            || this.aliases.some((alias) => fullName.includes(alias) || this.toolMatchesPlugin(tool, alias))
            || this.sentinels.has(localName);
          return defaultScopeMatches && this.toolMatchesPlugin(tool, pluginHint);
        });
      });
      if (!candidates.length) {
        const requested = firstString(pluginHint, this.displayName);
        throw new Error(`${requested} is not connected in Codex. Attach or reconnect that plugin first.`);
      }
      return await run(threadID, candidates);
    } finally {
      await this.options.closeThread(threadID);
    }
  }

  private async listApps() {
    const apps: AppRecord[] = [];
    const seen = new Set<string>();
    let cursor = "";
    for (let page = 0; page < 8; page += 1) {
      const response = await this.options.request("app/list", {
        ...(cursor ? { cursor } : {}),
        limit: 100,
        forceRefetch: page === 0
      }, 30_000);
      const parsed = appRecords(response);
      for (const app of parsed.apps) {
        const key = app.id.toLowerCase();
        if (seen.has(key)) continue;
        seen.add(key);
        apps.push(app);
      }
      if (!parsed.nextCursor) break;
      cursor = parsed.nextCursor;
    }
    return apps;
  }

  async connectPlugin(args: JsonObject) {
    const pluginHint = firstString(args.plugin, args.connector, args.server, args.source, args.query, args.name);
    if (!pluginHint) throw new Error("Name the plugin or connector you want to connect.");
    const needle = normalized(pluginHint);
    const apps = await this.listApps();
    const exact = apps.filter((app) => [app.id, app.name, ...app.pluginDisplayNames].some((value) => normalized(value) === needle));
    const partial = apps.filter((app) => [app.id, app.name, ...app.pluginDisplayNames].some((value) => {
      const candidate = normalized(value);
      return candidate.includes(needle) || needle.includes(candidate);
    }));
    const matches = exact.length ? exact : partial;
    if (!matches.length) {
      return {
        ok: false,
        status: "not_found",
        plugin: pluginHint,
        message: `${pluginHint} was not found in the current Codex plugin catalog.`
      };
    }
    if (matches.length > 1) {
      return {
        ok: false,
        status: "selection_required",
        plugin: pluginHint,
        candidates: matches.slice(0, 5).map((app) => ({ id: app.id, name: app.name })),
        message: `More than one plugin matched ${pluginHint}. Ask the user to choose one exact name.`
      };
    }
    const app = matches[0];
    if (app.isAccessible && app.isEnabled) {
      return {
        ok: true,
        status: "connected",
        alreadyConnected: true,
        plugin: app.name,
        appID: app.id,
        message: `${app.name} is already connected and ready.`
      };
    }
    const installUrl = safeSetupURL(app.installUrl);
    if (!installUrl) {
      return {
        ok: false,
        status: "setup_unavailable",
        plugin: app.name,
        appID: app.id,
        message: `${app.name} is available, but Codex did not provide a connection page.`
      };
    }
    if (!this.options.openExternal) {
      return {
        ok: false,
        status: "setup_required",
        plugin: app.name,
        appID: app.id,
        installUrl,
        message: `Connect ${app.name} here: ${installUrl}`
      };
    }
    await this.options.openExternal(installUrl);
    return {
      ok: true,
      status: "setup_opened",
      setupOpened: true,
      plugin: app.name,
      appID: app.id,
      installUrl,
      message: `I opened the ${app.name} connection page. Finish the sign-in and permission step there.`
    };
  }

  async findTools(args: JsonObject) {
    const query = firstString(args.query);
    const pluginHint = firstString(args.plugin, args.connector, args.server, args.source);
    const requestedLimit = Number(args.limit);
    const limit = Number.isFinite(requestedLimit) ? Math.max(1, Math.min(5, Math.floor(requestedLimit))) : 3;
    return this.withTools(async (_threadID, tools) => {
      const ranked = tools
        .map((tool) => ({ tool, score: scoreTool(tool, query) }))
        .filter(({ score }) => score > 0 || !query)
        .sort((a, b) => b.score - a.score || a.tool.name.localeCompare(b.tool.name))
        .slice(0, limit);
      return {
        ok: true,
        source: firstString(pluginHint, this.displayName),
        matches: ranked.map(({ tool }) => ({
          toolID: encodedToolID(tool.server, tool.name),
          server: tool.server,
          pluginID: tool.pluginID,
          pluginName: tool.pluginName,
          name: tool.displayName,
          description: tool.description,
          inputSchema: tool.inputSchema,
          readOnly: tool.readOnly,
          requiresConfirmation: !tool.readOnly
        }))
      };
    }, pluginHint);
  }

  async callTool(args: JsonObject) {
    const selected = decodedToolID(args.toolID);
    if (!selected) throw new Error(`Select an exact ${this.displayName} tool before running it.`);
    const toolArguments = objectValue(args.arguments) ?? {};
    return this.withTools(async (threadID, tools) => {
      const tool = tools.find((candidate) => candidate.server === selected.server && candidate.name === selected.tool);
      if (!tool) throw new Error(`That ${this.displayName} tool is no longer available. Discover the tools again.`);
      const sourceName = firstString(tool.pluginName, this.displayName);
      if (!tool.readOnly && args.confirmed !== true) {
        return {
          ok: false,
          confirmationRequired: true,
          status: "approval_required",
          toolID: firstString(args.toolID),
          message: `Confirm that you want ${sourceName} to run ${tool.displayName.replace(/_/g, " ")}.`
        };
      }
      const response = objectValue(await this.options.request("mcpServer/tool/call", {
        threadId: threadID,
        server: tool.server,
        tool: tool.name,
        arguments: toolArguments
      }, 60_000)) ?? {};
      return {
        ok: response.isError !== true,
        source: sourceName,
        server: tool.server,
        tool: tool.displayName,
        toolID: firstString(args.toolID),
        isError: response.isError === true,
        resultText: responseText(response),
        response
      };
    });
  }

  /**
   * Resolve a fixed plugin tool by its exact local name. This is intended for
   * narrow host-owned workflows whose UI already obtained explicit approval;
   * callers must still pass confirmed=true for write tools.
   */
  async callNamedTool(nameValue: string, toolArguments: JsonObject, confirmed = false) {
    const requestedName = firstString(nameValue).toLowerCase();
    if (!requestedName) throw new Error(`Name the exact ${this.displayName} tool before running it.`);
    return this.withTools(async (threadID, tools) => {
      const matches = tools.filter((tool) =>
        tool.name.toLowerCase() === requestedName
        || localToolName(tool.name).toLowerCase() === requestedName
      );
      if (matches.length !== 1) {
        throw new Error(matches.length
          ? `More than one ${this.displayName} tool matched ${nameValue}.`
          : `${this.displayName} does not currently expose ${nameValue}.`);
      }
      const tool = matches[0];
      const sourceName = firstString(tool.pluginName, this.displayName);
      if (!tool.readOnly && !confirmed) {
        return {
          ok: false,
          confirmationRequired: true,
          status: "approval_required",
          message: `Confirm that you want ${sourceName} to run ${tool.displayName.replace(/_/g, " ")}.`
        };
      }
      const response = objectValue(await this.options.request("mcpServer/tool/call", {
        threadId: threadID,
        server: tool.server,
        tool: tool.name,
        arguments: toolArguments
      }, 60_000)) ?? {};
      return {
        ok: response.isError !== true,
        source: sourceName,
        server: tool.server,
        tool: tool.displayName,
        isError: response.isError === true,
        resultText: responseText(response),
        response
      };
    });
  }
}
