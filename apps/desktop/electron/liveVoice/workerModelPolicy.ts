import type {
  DelegatedWorkExecutionProfile,
  DelegatedWorkModelPreference,
  WorkerModelMetadata,
  WorkerModelRole
} from "./contracts.js";

export type WorkerCatalogModel = {
  id: string;
  displayName?: string;
  supportedReasoningEfforts?: string[];
};

export type WorkerRoleDecision = {
  role: WorkerModelRole;
  reasoningEffort: WorkerModelMetadata["reasoningEffort"];
  selectionReason: string;
  explicitlySelected: boolean;
};

export type NormalizedDelegatedWorkExecutionProfile = Omit<Required<DelegatedWorkExecutionProfile>, "modelPreference"> & {
  modelPreference?: DelegatedWorkModelPreference;
};

function enumValue<T extends string>(value: unknown, allowed: readonly T[], fallback: T): T {
  return typeof value === "string" && allowed.includes(value as T) ? value as T : fallback;
}

export function normalizeDelegatedWorkExecutionProfile(raw?: DelegatedWorkExecutionProfile): NormalizedDelegatedWorkExecutionProfile {
  return {
    depth: enumValue(raw?.depth, ["auto", "fast", "deep"] as const, "auto"),
    complexity: enumValue(raw?.complexity, ["simple", "complex"] as const, "simple"),
    impact: enumValue(raw?.impact, ["read_only", "reversible_write", "sensitive_write"] as const, "read_only"),
    stakes: enumValue(raw?.stakes, ["normal", "high"] as const, "normal"),
    ...(raw?.modelPreference === "spark" || raw?.modelPreference === "sol"
      ? { modelPreference: raw.modelPreference }
      : {})
  };
}

function explicitlyRequestsModel(userText: string, preference: DelegatedWorkModelPreference) {
  const model = preference === "spark" ? "spark" : "sol";
  const escaped = model.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const patterns = [
    new RegExp(`\\b(?:use|run|route|send|ask|choose|pick|prefer|want|with|using)\\b[^.!?]{0,48}\\b${escaped}\\b`, "i"),
    new RegExp(`\\b${escaped}\\b[^.!?]{0,32}\\b(?:model|worker|agent)\\b`, "i"),
    new RegExp(`\\bgpt[- .]?[^\\s,;:!?]{0,24}${escaped}\\b`, "i")
  ];
  return patterns.some((pattern) => pattern.test(userText));
}

export function decideWorkerModelRole(input: {
  profile?: DelegatedWorkExecutionProfile;
  userText: string;
}): WorkerRoleDecision {
  const profile = normalizeDelegatedWorkExecutionProfile(input.profile);
  const requestedPreference = profile.modelPreference;
  if (requestedPreference && explicitlyRequestsModel(input.userText, requestedPreference)) {
    const role = requestedPreference === "sol" ? "deep" : "fast";
    return {
      role,
      reasoningEffort: role === "deep" ? "high" : "medium",
      selectionReason: `The user explicitly selected ${requestedPreference === "sol" ? "Sol" : "Spark"}.`,
      explicitlySelected: true
    };
  }

  // The voice model routinely over-picks depth="deep"/"complex" for ordinary
  // research, which routed everyday questions to the slow Sol worker. Those
  // model-chosen escalations now count only when the user's own words ask for
  // depth or care; safety escalations (high stakes, sensitive writes) always
  // count.
  const userSignalsDeepWork =
    /\b(deep|deeply|thorough|thoroughly|comprehensive|comprehensively|detailed|in[- ]depth|exhaustive|extensive|carefully|research (it|this) (well|properly))\b/i
      .test(input.userText);
  const deepReason = profile.depth === "deep" && userSignalsDeepWork
    ? "deep reasoning was requested"
    : profile.complexity === "complex" && userSignalsDeepWork
      ? "the task is complex"
      : profile.stakes === "high"
        ? "the task is high-stakes"
        : profile.impact === "sensitive_write"
          ? "the task includes a sensitive write"
          : "";
  if (deepReason) {
    return {
      role: "deep",
      reasoningEffort: "high",
      selectionReason: `Selected the deep worker because ${deepReason}.`,
      explicitlySelected: false
    };
  }

  return {
    role: "fast",
    reasoningEffort: "medium",
    selectionReason: profile.depth === "fast"
      ? "Selected the fast worker because fast execution was requested."
      : profile.depth === "deep" || profile.complexity === "complex"
        ? "Kept the fast Spark worker for speed — say \"deep\" or \"thorough\" when you want the Sol worker."
        : "Selected the fast worker for normal delegated work.",
    explicitlySelected: false
  };
}

function semanticVersion(modelID: string) {
  const match = /(?:^|-)gpt-(\d+(?:\.\d+)*)/i.exec(modelID);
  return match?.[1]?.split(".").map((part) => Number.parseInt(part, 10) || 0) ?? [];
}

function compareSemanticModelVersion(left: WorkerCatalogModel, right: WorkerCatalogModel) {
  const leftVersion = semanticVersion(left.id);
  const rightVersion = semanticVersion(right.id);
  const width = Math.max(leftVersion.length, rightVersion.length);
  for (let index = 0; index < width; index += 1) {
    const difference = (rightVersion[index] ?? 0) - (leftVersion[index] ?? 0);
    if (difference) return difference;
  }
  return left.id.localeCompare(right.id);
}

function automaticRoleCandidates(role: WorkerModelRole, catalog: WorkerCatalogModel[]) {
  return catalog.filter((model) => {
    const id = model.id.toLowerCase();
    return role === "fast"
      ? id.includes("spark") && id.includes("codex")
      : /(?:^|[-_.])sol(?:$|[-_.])/.test(id);
  });
}

export function resolveWorkerModel(input: {
  decision: WorkerRoleDecision;
  catalog: WorkerCatalogModel[];
  fastOverride?: string;
  deepOverride?: string;
}): WorkerModelMetadata {
  const role = input.decision.role;
  const override = (role === "fast" ? input.fastOverride : input.deepOverride)?.trim() || "auto";
  let selected: WorkerCatalogModel | undefined;
  if (override.toLowerCase() !== "auto") {
    selected = input.catalog.find((model) => model.id.toLowerCase() === override.toLowerCase());
    if (!selected) {
      throw new Error(`The configured ${role} Live Voice worker model "${override}" is not available in Codex app-server.`);
    }
  } else {
    selected = automaticRoleCandidates(role, input.catalog).sort(compareSemanticModelVersion)[0];
    if (!selected) {
      const label = role === "fast" ? "Spark" : "Sol";
      throw new Error(`No available ${label} model was found in the Codex app-server catalog.`);
    }
  }

  const supportedEfforts = selected.supportedReasoningEfforts?.map((effort) => effort.toLowerCase());
  if (supportedEfforts?.length && !supportedEfforts.includes(input.decision.reasoningEffort)) {
    throw new Error(`The selected model "${selected.id}" does not support ${input.decision.reasoningEffort} reasoning.`);
  }

  return {
    role,
    modelID: selected.id,
    reasoningEffort: input.decision.reasoningEffort,
    selectionReason: override.toLowerCase() === "auto"
      ? input.decision.selectionReason
      : `${input.decision.selectionReason} Used the configured ${role} worker override.`,
    explicitlySelected: input.decision.explicitlySelected
  };
}
