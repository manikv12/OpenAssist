import type { EffortLevel, Options, PermissionMode } from "@anthropic-ai/claude-agent-sdk";

export type OpenAssistClaudePermissionMode = "default" | "autoReview" | "fullAccess" | "custom";
export type ClaudeAgentAuthProfile = "public" | "personal";

export type ClaudeScopedUsageLimit = {
  modelID?: string;
  modelName: string;
  usedPercent: number;
  resetsAt?: string;
};

export type ClaudeAgentPermissionOptions = Pick<Options,
  "permissionMode" | "allowDangerouslySkipPermissions" | "settingSources"
>;

export function claudeAgentPermissionOptions(rawMode?: string): ClaudeAgentPermissionOptions {
  const mode = (rawMode || "default") as OpenAssistClaudePermissionMode;
  const settingSources: NonNullable<Options["settingSources"]> = ["user", "project", "local"];
  if (mode === "custom") return { settingSources };
  if (mode === "autoReview") return { permissionMode: "acceptEdits", settingSources };
  if (mode === "fullAccess") {
    return {
      permissionMode: "bypassPermissions",
      allowDangerouslySkipPermissions: true,
      settingSources
    };
  }
  return { permissionMode: "default", settingSources };
}

export function claudeAgentEffort(raw?: string): EffortLevel | undefined {
  const normalized = (raw || "").trim().toLowerCase().replace(/[\s_-]+/g, "");
  if (normalized === "none" || normalized === "minimal" || normalized === "low") return "low";
  if (normalized === "medium") return "medium";
  if (normalized === "high") return "high";
  if (normalized === "xhigh" || normalized === "extrahigh") return "xhigh";
  if (normalized === "max" || normalized === "maximum") return "max";
  return undefined;
}

export function claudeAgentAuthProfile(environment: NodeJS.ProcessEnv = process.env): ClaudeAgentAuthProfile {
  // OpenAssist is a personal desktop client and reuses the user's existing local
  // Claude login. Public distributions can opt into isolated API/cloud auth.
  return environment.OPENASSIST_CLAUDE_AUTH_PROFILE?.trim().toLowerCase() === "public"
    ? "public"
    : "personal";
}

export function claudeAgentEnvironment(options: {
  environment?: NodeJS.ProcessEnv;
  authProfile: ClaudeAgentAuthProfile;
  publicConfigDirectory: string;
}) {
  const environment: NodeJS.ProcessEnv = {
    ...(options.environment ?? process.env),
    CLAUDE_AGENT_SDK_CLIENT_APP: "openassist-desktop/0.1.0"
  };
  if (options.authProfile === "public") {
    delete environment.CLAUDE_CODE_OAUTH_TOKEN;
    environment.CLAUDE_CONFIG_DIR = options.publicConfigDirectory;
  } else {
    delete environment.ANTHROPIC_API_KEY;
  }
  return environment;
}

export function claudeAgentModel(raw?: string) {
  const model = (raw || "").trim();
  return !model || model === "default" ? undefined : model;
}

export function claudeAgentToolTitle(toolName: string) {
  const compact = toolName.replace(/^mcp__[^_]+__/, "").replace(/[_-]+/g, " ").trim();
  if (!compact) return "Claude tool";
  return compact.replace(/\b\w/g, (letter) => letter.toUpperCase());
}

export function claudeAgentValuePreview(value: unknown, maxLength = 320): string {
  let text = "";
  try {
    text = typeof value === "string" ? value : JSON.stringify(value);
  } catch {
    text = String(value ?? "");
  }
  text = text.replace(/\s+/g, " ").trim();
  return text.length > maxLength ? `${text.slice(0, maxLength - 3)}...` : text;
}

export function claudeAgentPermissionModeLabel(mode?: PermissionMode) {
  if (mode === "auto") return "Auto-review";
  if (mode === "bypassPermissions") return "Full access";
  if (!mode) return "Claude settings";
  return "Ask before actions";
}

function usageRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function usageString(...values: unknown[]) {
  return values.find((value): value is string => typeof value === "string" && Boolean(value.trim()))?.trim();
}

function usageNumber(...values: unknown[]) {
  for (const value of values) {
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (typeof value === "string" && value.trim() && Number.isFinite(Number(value))) return Number(value);
  }
  return undefined;
}

export function claudeScopedUsageLimits(payload: unknown): ClaudeScopedUsageLimit[] {
  const limits = usageRecord(payload).limits;
  if (!Array.isArray(limits)) return [];
  return limits.flatMap((rawLimit) => {
    const limit = usageRecord(rawLimit);
    const scope = usageRecord(limit.scope);
    const model = usageRecord(scope.model);
    const modelName = usageString(model.display_name, model.displayName, model.name);
    const usedPercent = usageNumber(limit.percent, limit.utilization, limit.used_percent, limit.usedPercent);
    if (!modelName || usedPercent == null) return [];
    return [{
      modelID: usageString(model.id) || undefined,
      modelName,
      usedPercent,
      resetsAt: usageString(limit.resets_at, limit.resetsAt) || undefined
    }];
  });
}
