import type { CodexPluginMCPBroker } from "./codexPluginMcpBroker.js";
import type {
  SecondBrainArtifactPointer,
  SecondBrainBlockerCode,
  SecondBrainClaim,
  SecondBrainSourceDocument,
  SecondBrainWorkspacePort,
} from "./secondBrainAutonomousRunnerCore.js";

type JsonObject = Record<string, unknown>;

const allowedTools = new Set([
  "claim_next_second_brain_work",
  "read_second_brain_project",
  "read_second_brain_work_item",
  "search_second_brain_knowledge",
  "renew_second_brain_work_lease",
  "report_second_brain_progress",
  "submit_second_brain_result",
]);

function objectValue(value: unknown): JsonObject | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : null;
}

function exactToolName(toolID: unknown) {
  const value = typeof toolID === "string" ? toolID : "";
  const encoded = value.split("::").pop() ?? "";
  try {
    return decodeURIComponent(encoded).split(/[.:/]/).filter(Boolean).pop() ?? "";
  } catch {
    return "";
  }
}

function parsedResult(value: unknown): JsonObject {
  const response = objectValue(value);
  if (!response || response.ok !== true || response.isError === true) {
    throw new Error(typeof response?.resultText === "string" ? response.resultText : "OpenAssist Workspace tool call failed.");
  }
  const direct = objectValue(objectValue(response.response)?.structuredContent);
  if (direct) return direct;
  const text = typeof response.resultText === "string" ? response.resultText : "";
  try {
    const parsed = objectValue(JSON.parse(text));
    if (parsed) return parsed;
  } catch {
    // A structured JSON result is required for safe orchestration.
  }
  throw new Error("OpenAssist Workspace returned an invalid structured result.");
}

export class SecondBrainWorkspaceBrokerClient implements SecondBrainWorkspacePort {
  constructor(
    private readonly broker: Pick<CodexPluginMCPBroker, "findTools" | "callTool"> | {
      callNamedTool(name: string, args: JsonObject): Promise<unknown>;
    },
    private readonly pluginName = "OpenAssist Workspace",
  ) {}

  private async invoke(toolName: string, args: JsonObject) {
    if (!allowedTools.has(toolName)) throw new Error("This runner cannot call that Workspace tool.");
    if ("callNamedTool" in this.broker) {
      return parsedResult(await this.broker.callNamedTool(toolName, args));
    }
    const discovery = objectValue(await this.broker.findTools({
      plugin: this.pluginName,
      query: toolName,
      limit: 5,
    })) ?? {};
    const matches = Array.isArray(discovery.matches) ? discovery.matches : [];
    const selected = matches.map(objectValue).find((match) => exactToolName(match?.toolID) === toolName);
    if (!selected || typeof selected.toolID !== "string") {
      throw new Error(`${toolName} is not exposed by the connected OpenAssist Workspace app.`);
    }
    return parsedResult(await this.broker.callTool({
      toolID: selected.toolID,
      arguments: args,
      confirmed: true,
    }));
  }

  async claimNext(input: { agentId: string; leaseSeconds: number }): Promise<SecondBrainClaim> {
    const result = await this.invoke("claim_next_second_brain_work", input);
    if (typeof result.found !== "boolean") throw new Error("Workspace returned an invalid claim result.");
    if (result.found === true) {
      const run = objectValue(result.run);
      if (!run || typeof run.id !== "string" || typeof run.projectId !== "string"
        || typeof run.workItemId !== "string" || typeof result.leaseToken !== "string") {
        throw new Error("Workspace returned an incomplete claim result.");
      }
    }
    return result as SecondBrainClaim;
  }

  async readProject(input: { projectId: string }): Promise<SecondBrainSourceDocument> {
    const result = await this.invoke("read_second_brain_project", input);
    if (typeof result.markdown !== "string") throw new Error("Workspace returned an invalid project document.");
    return result as SecondBrainSourceDocument;
  }

  async readWorkItem(input: { workItemId: string }): Promise<SecondBrainSourceDocument> {
    const result = await this.invoke("read_second_brain_work_item", input);
    if (typeof result.markdown !== "string") throw new Error("Workspace returned an invalid work-item document.");
    return result as SecondBrainSourceDocument;
  }

  async searchKnowledge(input: {
    query: string;
    sourceKinds: readonly ["project", "work_item", "memory"];
    limit: number;
    maxScanned: number;
  }) {
    const result = await this.invoke("search_second_brain_knowledge", input);
    const directMarkdown = typeof result.markdown === "string" ? result.markdown : "";
    const entries = Array.isArray(result.results) ? result.results.slice(0, Math.min(8, input.limit)) : [];
    const entryMarkdown = entries.map((entry, index) => {
      const object = objectValue(entry) ?? {};
      const sourceKind = typeof object.sourceKind === "string" ? object.sourceKind.trim() : "unknown";
      const sourceID = typeof object.sourceId === "string" ? object.sourceId.trim() : `result-${index + 1}`;
      const revision = typeof object.revision === "string" || typeof object.revision === "number"
        ? String(object.revision).trim()
        : "unknown";
      const excerpt = typeof object.excerpt === "string" ? object.excerpt.trim() : "No excerpt returned.";
      const partial = object.partialDocumentScan === true ? "yes" : "no";
      return `## ${sourceKind}: ${sourceID}\nRevision: ${revision}\nPartial document scan: ${partial}\n\n${excerpt}`;
    }).join("\n\n");
    const warning = typeof result.warning === "string" && result.warning.trim()
      ? `> Search warning: ${result.warning.trim()}\n\n`
      : "";
    const unboundedMarkdown = `${warning}${directMarkdown || entryMarkdown || "No relevant Second Brain knowledge was found."}`;
    const markdown = unboundedMarkdown
      .replace(/\u0000/g, "")
      .slice(0, 30_000)
      .trim();
    const reportedCount = Number(result.resultCount ?? result.count);
    return {
      markdown,
      resultCount: Number.isFinite(reportedCount) ? Math.max(0, Math.trunc(reportedCount)) : entries.length,
      truncated: result.truncated === true || unboundedMarkdown.length > 30_000,
    };
  }

  renewLease(input: { runId: string; agentId: string; leaseToken: string; leaseSeconds: number }) {
    return this.invoke("renew_second_brain_work_lease", input);
  }

  reportProgress(input: {
    runId: string;
    agentId: string;
    leaseToken: string;
    idempotencyKey: string;
    markdown: string;
    artifacts?: SecondBrainArtifactPointer[];
    needsUser?: boolean;
    blockerCode?: SecondBrainBlockerCode;
  }) {
    return this.invoke("report_second_brain_progress", input);
  }

  submitResult(input: {
    runId: string;
    agentId: string;
    leaseToken: string;
    idempotencyKey: string;
    markdown: string;
    artifacts?: SecondBrainArtifactPointer[];
    acceptancePassed: true;
  }) {
    return this.invoke("submit_second_brain_result", input);
  }
}
