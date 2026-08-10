import type { AssistantDelegateArguments, DelegatedWorkExecutionProfile, JsonObject } from "./contracts.js";
import { normalizeDelegatedWorkExecutionProfile } from "./workerModelPolicy.js";

export const preferredComputerUsePluginID = "computer-use@openai-bundled";

const computerUsePluginIDs = new Set([
  preferredComputerUsePluginID,
  "computer-use@openai-curated"
]);

export function explicitlyRequestsComputerUse(text: string): boolean {
  const value = String(text ?? "").trim();
  if (!value) return false;
  return /(?:^|\b|@)computer[\s-]*use\b/i.test(value)
    || /\b(?:control|use|operate)\s+(?:my|the)\s+(?:mac|computer|screen)\b/i.test(value);
}

export function hasComputerUsePlugin(pluginIDs: string[] = []): boolean {
  return pluginIDs.some((pluginID) => computerUsePluginIDs.has(String(pluginID ?? "").trim().toLowerCase()));
}

export type DelegatedWorkerToolSelection =
  | { ok: true; pluginIDs: string[]; computerUseSelected: boolean }
  | { ok: false; error: string };

export function delegatedWorkerToolSelection(input: {
  prompt: string;
  userText?: string;
  pluginIDs?: string[];
  computerUseEnabled: boolean;
}): DelegatedWorkerToolSelection {
  const pluginIDs = [...(input.pluginIDs ?? [])];
  const alreadySelected = hasComputerUsePlugin(pluginIDs);
  const explicitlyRequested = explicitlyRequestsComputerUse(`${input.userText ?? ""}\n${input.prompt}`);
  if (!explicitlyRequested) {
    return { ok: true, pluginIDs, computerUseSelected: alreadySelected };
  }
  if (!alreadySelected && !input.computerUseEnabled) {
    // Name the exact setting and its location. A vague refusal here was being
    // paraphrased by the voice model into unrelated causes ("no Live Voice
    // work model selected"), sending the user to the wrong setting.
    return {
      ok: false,
      error: "Computer Use is turned off in OpenAssist, so this task was not started. "
        + "This is NOT a model or Live Voice worker-model problem — do not mention worker models. "
        + "Tell the user to open OpenAssist Settings > Automation & Remote and turn on "
        + "\"Allow Computer Use when requested\", then ask again."
    };
  }
  if (!alreadySelected) pluginIDs.push(preferredComputerUsePluginID);
  return { ok: true, pluginIDs, computerUseSelected: true };
}

function objectValue(value: unknown): JsonObject | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : undefined;
}

function textValue(...values: unknown[]): string {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
}

export function delegatedWorkArgumentsFromToolArgs(
  args: JsonObject,
  finalizedUserText: string
): AssistantDelegateArguments {
  const userText = textValue(finalizedUserText);
  const goal = textValue(args.goal, userText);
  const tasks = Array.isArray(args.tasks)
    ? args.tasks.flatMap((rawTask) => {
        const task = objectValue(rawTask);
        const prompt = textValue(task?.prompt);
        if (!prompt) return [];
        return [{
          prompt,
          userText,
          provider: textValue(task?.provider) || undefined,
          project: textValue(task?.project) || undefined,
          executionProfile: normalizeDelegatedWorkExecutionProfile(
            objectValue(task?.executionProfile) as DelegatedWorkExecutionProfile | undefined
          ),
          freshThread: task?.freshThread === true
        }];
      })
    : undefined;
  return {
    goal,
    userText,
    tasks,
    provider: textValue(args.provider) || undefined,
    project: textValue(args.project) || undefined,
    executionProfile: normalizeDelegatedWorkExecutionProfile(
      objectValue(args.executionProfile) as DelegatedWorkExecutionProfile | undefined
    ),
    freshThread: args.freshThread === true,
    mode: args.mode === "follow_up" || args.mode === "rerun" ? args.mode : "new",
    taskID: textValue(args.taskID) || undefined
  };
}
