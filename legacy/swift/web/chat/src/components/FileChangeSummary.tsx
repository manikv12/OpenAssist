import { memo } from "react";
import type { ActivityDetailSection } from "../types";

interface FileChangeSummaryProps {
  sections: ActivityDetailSection[];
}

type FileChangeKind = "modified" | "added" | "deleted" | "moved" | "changed";

interface FileChangeEntry {
  path: string;
  kind: FileChangeKind;
  preview?: string;
}

function FileChangeSummaryInner({ sections }: FileChangeSummaryProps) {
  const entries = parseFileChanges(sections);

  if (entries.length === 0) {
    return null;
  }

  return (
    <div className="file-change-summary">
      <span className="activity-detail-heading">Changed Files</span>

      <div className="file-change-list">
        {entries.map((entry) => {
          const name = lastPathComponent(entry.path);

          return (
            <div key={entry.path} className="file-change-card">
              <div className="file-change-header">
                <div className="file-change-copy">
                  <span className="file-change-name">{name}</span>
                  {name !== entry.path && (
                    <span className="file-change-path">{entry.path}</span>
                  )}
                </div>

                <span
                  className={`file-change-badge file-change-badge-${entry.kind}`}
                >
                  {labelForKind(entry.kind)}
                </span>
              </div>

              {entry.preview && (
                <pre className="file-change-preview">{entry.preview}</pre>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

export const FileChangeSummary = memo(FileChangeSummaryInner);

function parseFileChanges(sections: ActivityDetailSection[]): FileChangeEntry[] {
  const combinedText = sections.map((section) => section.text).join("\n");
  const lines = combinedText.replace(/\r\n/g, "\n").split("\n");
  const entriesByPath = new Map<string, FileChangeEntry>();
  const orderedPaths: string[] = [];
  let currentPatchPath: string | null = null;

  const ensureEntry = (path: string, kind: FileChangeKind) => {
    const trimmedPath = path.trim();
    if (!trimmedPath) {
      return null;
    }

    const existing = entriesByPath.get(trimmedPath);
    if (existing) {
      if (existing.kind === "changed" && kind !== "changed") {
        existing.kind = kind;
      }
      return existing;
    }

    const entry: FileChangeEntry = { path: trimmedPath, kind };
    entriesByPath.set(trimmedPath, entry);
    orderedPaths.push(trimmedPath);
    return entry;
  };

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }

    const statusMatch = trimmed.match(/^([MADRCU])\s+(.+)$/);
    if (statusMatch) {
      ensureEntry(statusMatch[2], kindFromSymbol(statusMatch[1]));
      currentPatchPath = null;
      continue;
    }

    const updateMatch = trimmed.match(/^\*\*\* Update File: (.+)$/);
    if (updateMatch) {
      currentPatchPath = updateMatch[1].trim();
      ensureEntry(currentPatchPath, "modified");
      continue;
    }

    const addMatch = trimmed.match(/^\*\*\* Add File: (.+)$/);
    if (addMatch) {
      currentPatchPath = addMatch[1].trim();
      ensureEntry(currentPatchPath, "added");
      continue;
    }

    const deleteMatch = trimmed.match(/^\*\*\* Delete File: (.+)$/);
    if (deleteMatch) {
      currentPatchPath = deleteMatch[1].trim();
      ensureEntry(currentPatchPath, "deleted");
      continue;
    }

    const moveMatch = trimmed.match(/^\*\*\* Move to: (.+)$/);
    if (moveMatch && currentPatchPath) {
      const movedTo = moveMatch[1].trim();
      const entry = ensureEntry(movedTo, "moved");
      if (entry && !entry.preview) {
        entry.preview = `Moved from ${currentPatchPath}`;
      }
      currentPatchPath = movedTo;
      continue;
    }

    if (!currentPatchPath) {
      continue;
    }

    if (!trimmed.startsWith("+") && !trimmed.startsWith("-")) {
      continue;
    }

    if (trimmed.startsWith("+++") || trimmed.startsWith("---")) {
      continue;
    }

    const entry = ensureEntry(currentPatchPath, "modified");
    if (!entry) {
      continue;
    }

    const previewLines = entry.preview ? entry.preview.split("\n") : [];
    if (previewLines.length >= 6) {
      continue;
    }

    previewLines.push(trimmed);
    entry.preview = previewLines.join("\n");
  }

  return orderedPaths
    .map((path) => entriesByPath.get(path))
    .filter((entry): entry is FileChangeEntry => entry !== undefined);
}

function kindFromSymbol(symbol: string): FileChangeKind {
  switch (symbol) {
    case "A":
      return "added";
    case "D":
      return "deleted";
    case "R":
      return "moved";
    case "M":
      return "modified";
    default:
      return "changed";
  }
}

function labelForKind(kind: FileChangeKind): string {
  switch (kind) {
    case "added":
      return "Added";
    case "deleted":
      return "Deleted";
    case "moved":
      return "Moved";
    case "modified":
      return "Modified";
    case "changed":
      return "Changed";
  }
}

function lastPathComponent(path: string): string {
  const normalized = path.replace(/\\/g, "/");
  const parts = normalized.split("/");
  return parts[parts.length - 1] || path;
}
