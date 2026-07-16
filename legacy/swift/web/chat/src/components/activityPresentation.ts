import type { ActivityGroupItem, ActivityTarget } from "../types";

export interface ActivityTrailEntry {
  id: string;
  label: string;
  status: ActivityGroupItem["status"];
}

export interface ActivityTrailModel {
  title: string;
  entries: ActivityTrailEntry[];
}

function firstRelevantTarget(targets?: ActivityTarget[]): ActivityTarget | undefined {
  if (!targets || targets.length === 0) {
    return undefined;
  }

  return targets.find((target) => target.kind === "file") || targets[0];
}

function firstFileTarget(targets?: ActivityTarget[]): ActivityTarget | undefined {
  return targets?.find((target) => target.kind === "file");
}

function looksLikeFilePath(value: string): boolean {
  return /[\\/]/.test(value) || /\.[a-z0-9]{1,8}$/i.test(value);
}

function lastPathComponent(path: string): string {
  const normalized = path.replace(/\\/g, "/");
  const parts = normalized.split("/");
  return parts[parts.length - 1] || path;
}

export function resolveActivityPrimaryTarget(
  targets?: ActivityTarget[],
  fallbackDetail?: string
): ActivityTarget | undefined {
  const explicitTarget = firstRelevantTarget(targets);
  if (explicitTarget) {
    return explicitTarget;
  }

  const trimmedDetail = fallbackDetail?.trim();
  if (!trimmedDetail) {
    return undefined;
  }

  if (/^https?:\/\//i.test(trimmedDetail)) {
    return {
      kind: "url",
      label: trimmedDetail,
    };
  }

  if (looksLikeFilePath(trimmedDetail)) {
    return {
      kind: "file",
      label: lastPathComponent(trimmedDetail),
      detail: trimmedDetail,
    };
  }

  return undefined;
}

export function compactActivityTargetLabel(target?: ActivityTarget): string | undefined {
  if (!target) {
    return undefined;
  }

  if (target.kind === "file") {
    return lastPathComponent(target.label);
  }

  return target.label;
}

export function splitActivityLabelLead(
  label?: string,
  targetLabel?: string
): string | undefined {
  const trimmedLabel = label?.trim();
  const trimmedTarget = targetLabel?.trim();

  if (!trimmedLabel) {
    return undefined;
  }

  if (!trimmedTarget) {
    return trimmedLabel;
  }

  if (trimmedLabel === trimmedTarget) {
    return undefined;
  }

  if (trimmedLabel.endsWith(` ${trimmedTarget}`)) {
    return trimmedLabel.slice(0, -trimmedTarget.length).trim();
  }

  return trimmedLabel;
}

export function buildActivityActionLabel(
  icon?: string,
  targets?: ActivityTarget[],
  fallbackTitle?: string
): string | undefined {
  const target = firstRelevantTarget(targets);
  if (!target) {
    return fallbackTitle;
  }

  switch (icon) {
    case "commandExecution":
      return target.kind === "file" ? `Read ${target.label}` : `Opened ${target.label}`;
    case "fileChange":
      return target.kind === "file" ? `Edited ${target.label}` : `Updated ${target.label}`;
    case "webSearch":
      return `Searched ${target.label}`;
    case "browserAutomation":
      return `Opened ${target.label}`;
    default:
      return fallbackTitle;
  }
}

export function buildActivityActionDetail(
  targets?: ActivityTarget[],
  fallbackDetail?: string
): string | undefined {
  const target = firstRelevantTarget(targets);
  if (!target) {
    return fallbackDetail;
  }

  return target.detail || fallbackDetail;
}

export function buildActivityTrailModel(
  items: ActivityGroupItem[],
  running: boolean
): ActivityTrailModel | null {
  if (items.length === 0) {
    return null;
  }

  const entries = items.map((item) => {
    const label = buildActivityActionLabel(item.icon, item.activityTargets, item.title);
    return label
      ? {
          id: item.id,
          label,
          status: item.status,
        }
      : null;
  });

  if (entries.some((entry) => entry === null)) {
    return null;
  }

  const fileTargets = items.map((item) => firstFileTarget(item.activityTargets));
  if (fileTargets.some((target) => !target)) {
    return null;
  }

  const allCommands = items.every((item) => item.icon === "commandExecution");
  const allFileChanges = items.every((item) => item.icon === "fileChange");
  const allFileActions = items.every(
    (item) => item.icon === "commandExecution" || item.icon === "fileChange"
  );

  if (!allFileActions) {
    return null;
  }

  const count = fileTargets.length;
  let title: string;

  if (allCommands) {
    title = `${running ? "Exploring" : "Explored"} ${count} file${count === 1 ? "" : "s"}`;
  } else if (allFileChanges) {
    title = `${running ? "Editing" : "Edited"} ${count} file${count === 1 ? "" : "s"}`;
  } else {
    title = `${running ? "Working across" : "Worked across"} ${count} file${count === 1 ? "" : "s"}`;
  }

  return {
    title,
    entries: entries as ActivityTrailEntry[],
  };
}
