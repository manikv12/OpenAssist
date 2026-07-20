import type {
  CapabilityDescriptor,
  CapabilityOperation,
  CapabilitySelection,
  JsonObject,
  LiveVoiceContextResource
} from "./contracts.js";

export type CapabilityResolution =
  | { kind: "selected"; descriptor: CapabilityDescriptor }
  | { kind: "selection_required"; candidates: CapabilitySelection[]; message: string }
  | { kind: "clarification_required"; candidates: CapabilitySelection[]; message: string }
  | { kind: "failed"; message: string; errorCode: string };

function normalize(value: string) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, " ").replace(/\s+/g, " ").trim();
}

// Filler words score no routing points — "check my Apple Reminders" must win
// on "apple"/"reminders", not tie with a capability whose description happens
// to contain "check" and "for".
const routingStopwords = new Set([
  "the", "and", "for", "with", "from", "this", "that", "your", "you", "are",
  "was", "were", "has", "have", "had", "can", "could", "will", "would", "when",
  "what", "which", "who", "how", "use", "user", "asks", "ask", "see", "any",
  "all", "its", "out", "about", "into", "only", "also", "just", "please"
]);

function terms(value: string) {
  return new Set(normalize(value).split(" ").filter((term) => term.length > 2 && !routingStopwords.has(term)));
}

function selection(descriptor: CapabilityDescriptor): CapabilitySelection {
  return {
    id: descriptor.id,
    description: descriptor.description,
    operations: descriptor.operations,
    source: descriptor.source,
    risk: descriptor.risk,
    inputSchema: descriptor.inputSchema,
    resourceKinds: descriptor.resourceKinds
  };
}

// "read" and "search" are the same intent for routing purposes: both retrieve
// without mutating. Providers describe "check my Apple Reminders" as search
// while the reminders capability declares read — a hard operation wall here
// filtered the RIGHT capability away and let an unrelated search capability
// (e.g. Messages) win as the only remaining candidate. Mutating operations
// stay strict.
const retrievalOperations = new Set<CapabilityOperation>(["read", "search"]);

function operationCompatible(descriptor: CapabilityDescriptor, operation: CapabilityOperation) {
  if (operation === "discover") return true;
  if (descriptor.operations.includes(operation)) return true;
  return retrievalOperations.has(operation)
    && descriptor.operations.some((candidate) => retrievalOperations.has(candidate));
}

function sourceMatches(descriptor: CapabilityDescriptor, hints: string[]) {
  if (!hints.length) return false;
  const sources = [descriptor.source, ...(descriptor.sourceAliases ?? [])].map(normalize);
  return hints.some((hint) => sources.includes(normalize(hint)));
}

function resourceMatches(descriptor: CapabilityDescriptor, resources: LiveVoiceContextResource[]) {
  const supportedKinds = new Set((descriptor.resourceKinds ?? []).map(normalize));
  return supportedKinds.size > 0 && resources.some((resource) => supportedKinds.has(normalize(resource.kind)));
}

export class LiveVoiceCapabilityRegistry {
  private readonly descriptors = new Map<string, CapabilityDescriptor>();

  constructor(descriptors: CapabilityDescriptor[] = []) {
    for (const descriptor of descriptors) this.register(descriptor);
  }

  register(descriptor: CapabilityDescriptor) {
    if (!descriptor.id.trim()) throw new Error("Capability id is required.");
    if (this.descriptors.has(descriptor.id)) throw new Error(`Duplicate capability id: ${descriptor.id}`);
    this.descriptors.set(descriptor.id, descriptor);
    return descriptor;
  }

  list() {
    return [...this.descriptors.values()].filter((descriptor) => descriptor.enabled?.() !== false);
  }

  get(id: string) {
    const descriptor = this.descriptors.get(id.trim());
    return descriptor?.enabled?.() === false ? undefined : descriptor;
  }

  discover(
    goal: string,
    operation: CapabilityOperation,
    sourceHints: string[] = [],
    contextResources: LiveVoiceContextResource[] = [],
    limit = 8
  ) {
    const goalTerms = terms(goal);
    return this.list()
      .filter((descriptor) => operationCompatible(descriptor, operation))
      .map((descriptor) => {
        // Identity terms (id, source, aliases, keywords) are deliberate
        // routing signals and outweigh incidental description prose, so a
        // goal naming its source ("apple reminders") beats a capability whose
        // description merely shares generic verbs.
        const identityTerms = terms([
          descriptor.id,
          descriptor.source,
          ...(descriptor.sourceAliases ?? []),
          ...(descriptor.keywords ?? [])
        ].join(" "));
        const descriptionTerms = terms(descriptor.description);
        let score = sourceMatches(descriptor, sourceHints) ? 8 : 0;
        if (resourceMatches(descriptor, contextResources)) score += 12;
        for (const term of goalTerms) {
          if (identityTerms.has(term)) score += 3;
          else if (descriptionTerms.has(term)) score += 1;
        }
        return { descriptor, score };
      })
      .filter((candidate) => candidate.score > 0)
      .sort((left, right) => right.score - left.score || left.descriptor.id.localeCompare(right.descriptor.id))
      .slice(0, Math.max(1, limit));
  }

  resolve(input: {
    goal: string;
    operation: CapabilityOperation;
    sourceHints?: string[];
    capabilityID?: string;
    arguments?: JsonObject;
    contextResources?: LiveVoiceContextResource[];
    authorizedCapabilityIDs?: string[];
  }): CapabilityResolution {
    const capabilityID = input.capabilityID?.trim();
    const candidates = this.discover(
      input.goal,
      input.operation,
      input.sourceHints ?? [],
      input.contextResources ?? []
    );
    const bestScore = candidates[0]?.score ?? 0;
    const eligibleCandidates = candidates.filter((candidate) => candidate.score === bestScore);
    if (capabilityID) {
      const descriptor = this.get(capabilityID);
      if (!descriptor) {
        return { kind: "failed", message: `Capability ${capabilityID} is not available.`, errorCode: "capability_not_found" };
      }
      if (!operationCompatible(descriptor, input.operation)) {
        return {
          kind: "clarification_required",
          candidates: [selection(descriptor)],
          message: `${descriptor.id} does not support ${input.operation}. Choose one of its supported operations.`
        };
      }
      // A capabilityID that matches discovery for this goal is consistent —
      // accept it directly. The prior-grant handshake only guards IDs the
      // model picked that discovery did NOT surface for this goal.
      if (eligibleCandidates.some((candidate) => candidate.descriptor.id === descriptor.id)) {
        return { kind: "selected", descriptor };
      }
      if (!(input.authorizedCapabilityIDs ?? []).includes(descriptor.id)) {
        if (!eligibleCandidates.length) {
          return {
            kind: "clarification_required",
            candidates: [],
            message: "I need one more detail about which source or action you want."
          };
        }
        return {
          kind: "selection_required",
          candidates: eligibleCandidates.map((candidate) => selection(candidate.descriptor)),
          message: "Choose one coordinator-approved capability, then call assistant_capability again with that capabilityID. Candidate discovery is not a completed answer."
        };
      }
      return { kind: "selected", descriptor };
    }

    if (!eligibleCandidates.length) {
      return {
        kind: "clarification_required",
        candidates: [],
        message: "I need one more detail about which source or action you want."
      };
    }

    // Exactly one match — run it. Forcing a second assistant_capability call
    // to "confirm" a single unambiguous candidate made providers that follow
    // the protocol loosely (Gemini Live) give up and tell the user they have
    // no tool for the request. Sensitive writes still stop at the
    // approval_required gate downstream.
    if (eligibleCandidates.length === 1) {
      return { kind: "selected", descriptor: eligibleCandidates[0].descriptor };
    }

    return {
      kind: "selection_required",
      candidates: eligibleCandidates.map((candidate) => selection(candidate.descriptor)),
      message: "Choose one coordinator-approved capability, then call assistant_capability again with that capabilityID. Candidate discovery is not a completed answer."
    };
  }

  hasCompatibleDirectCapability(goal: string, operation?: CapabilityOperation, sourceHints: string[] = []) {
    const operations: CapabilityOperation[] = operation
      ? [operation]
      : ["read", "search", "create", "update", "move", "complete", "delete", "execute"];
    return operations.some((candidateOperation) =>
      this.discover(goal, candidateOperation, sourceHints, [], 3)
        .some(({ descriptor, score }) => descriptor.executionMode === "blocking" && score > 0)
    );
  }
}
