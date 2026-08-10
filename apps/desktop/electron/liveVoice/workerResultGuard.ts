// Deterministic guard between a delegated worker's final text and the user.
// Root cause this protects against (seen in production): a fast worker model
// echoed the tail of its execution brief as its "answer" and fabricated an
// action claim ("Added to Monday, July 20 ...") without making a single tool
// call — and the task was narrated to the user as Completed. A worker answer
// is only trusted when its claims are consistent with the tool activity we
// actually observed during the turn.

// Activity kinds that represent real tool work (not reasoning/plan chatter).
const workerToolActivityKinds = new Set([
  "commandExecution",
  "mcpToolCall",
  "fileChange",
  "browserAutomation",
  "webSearch",
  "subagent",
  "imageGeneration"
]);

export function isWorkerToolActivityKind(kind: unknown): boolean {
  return typeof kind === "string" && workerToolActivityKinds.has(kind);
}

// Sentences from the execution brief that must never appear in a final answer.
// A hit means the model parroted its instructions instead of doing the task.
const briefEchoFragments = [
  "include open questions only if any exist",
  "do not include internal progress messages",
  "return one clear, user-facing final answer",
  "structure the final answer with these plain-text headings",
  "never quote or repeat these instructions"
];

export function workerResultEchoesBrief(text: string): boolean {
  const lowered = String(text ?? "").toLowerCase();
  if (!lowered) return false;
  return briefEchoFragments.some((fragment) => lowered.includes(fragment));
}

// First-person / sentence-initial claims that a state-changing action was
// performed. Deliberately narrow so read-only answers that merely mention a
// task "is already completed" do not match.
const actionClaimPattern =
  /(^|\n)\s*(added|created|scheduled|updated|deleted|removed|moved|renamed|saved|done)\b|\bi\s+(have\s+|just\s+|)(added|created|scheduled|updated|deleted|removed|moved|renamed|saved|set)\b|\bi['’]ve\s+(added|created|scheduled|updated|deleted|removed|moved|renamed|saved|set)\b/i;

export function workerResultClaimsAction(text: string): boolean {
  return actionClaimPattern.test(String(text ?? ""));
}

export type WorkerResultVerdict =
  | { ok: true }
  | { ok: false; reason: "echoed-brief" | "unverified-action-claim"; message: string };

export function validateWorkerResult(input: { text: string; toolActivityCount: number }): WorkerResultVerdict {
  const text = String(input.text ?? "");
  if (workerResultEchoesBrief(text)) {
    return {
      ok: false,
      reason: "echoed-brief",
      message: "The worker repeated its instructions instead of doing the task. Nothing was changed — please try again."
    };
  }
  if (input.toolActivityCount === 0 && workerResultClaimsAction(text)) {
    return {
      ok: false,
      reason: "unverified-action-claim",
      message: "The worker claimed it made a change but never ran any tool, so nothing was actually done. Please try again."
    };
  }
  return { ok: true };
}
