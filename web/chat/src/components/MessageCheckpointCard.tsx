import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { MessageCheckpointInfo } from "../types";
import { AppIcon } from "./AppIcon";

interface Props {
  info: MessageCheckpointInfo;
}

// -- Diff parsing --

interface ParsedDiffFile {
  path: string;
  binary: boolean;
  hunks: ParsedDiffHunk[];
  additions: number;
  deletions: number;
}

interface ParsedDiffHunk {
  header: string;
  lines: ParsedDiffLine[];
}

interface ParsedDiffLine {
  kind: "add" | "remove" | "context" | "meta";
  text: string;
  lineNumber?: number;
}

function parseUnifiedDiff(patch: string): ParsedDiffFile[] {
  if (!patch.trim()) return [];

  const lines = patch.replace(/\r\n/g, "\n").split("\n");
  const files: ParsedDiffFile[] = [];
  let currentFile: ParsedDiffFile | null = null;
  let currentHunk: ParsedDiffHunk | null = null;
  let oldLineNumber = 0;
  let newLineNumber = 0;

  const finishHunk = () => {
    if (currentFile && currentHunk) currentFile.hunks.push(currentHunk);
    currentHunk = null;
  };

  const finishFile = () => {
    finishHunk();
    if (currentFile) files.push(currentFile);
    currentFile = null;
  };

  for (const line of lines) {
    if (line.startsWith("diff --git ")) {
      finishFile();
      const match = line.match(/^diff --git a\/(.+) b\/(.+)$/);
      const path = match?.[2] || match?.[1] || line.replace("diff --git ", "");
      currentFile = { path, binary: false, hunks: [], additions: 0, deletions: 0 };
      continue;
    }
    if (!currentFile) continue;
    if (line.startsWith("Binary files ") || line.startsWith("GIT binary patch")) {
      currentFile.binary = true;
      continue;
    }
    if (line.startsWith("@@")) {
      finishHunk();
      currentHunk = { header: line, lines: [] };
      const match = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
      oldLineNumber = Number(match?.[1] || 0);
      newLineNumber = Number(match?.[2] || 0);
      continue;
    }
    if (!currentHunk) continue;

    if (line.startsWith("+") && !line.startsWith("+++")) {
      currentHunk.lines.push({
        kind: "add",
        text: line.slice(1),
        lineNumber: newLineNumber,
      });
      currentFile.additions++;
      newLineNumber++;
    } else if (line.startsWith("-") && !line.startsWith("---")) {
      currentHunk.lines.push({
        kind: "remove",
        text: line.slice(1),
        lineNumber: oldLineNumber,
      });
      currentFile.deletions++;
      oldLineNumber++;
    } else if (line.startsWith(" ")) {
      currentHunk.lines.push({
        kind: "context",
        text: line.slice(1),
        lineNumber: newLineNumber,
      });
      oldLineNumber++;
      newLineNumber++;
    } else {
      currentHunk.lines.push({ kind: "meta", text: line });
    }
  }
  finishFile();
  return files;
}

function countPatchStats(patch: string): { additions: number; deletions: number } {
  let additions = 0;
  let deletions = 0;
  for (const line of patch.split("\n")) {
    if (line.startsWith("+") && !line.startsWith("+++")) additions++;
    else if (line.startsWith("-") && !line.startsWith("---")) deletions++;
  }
  return { additions, deletions };
}

// -- Component --

export function MessageCheckpointCard({ info }: Props) {
  const {
    checkpoint,
    checkpointIndex,
    currentCheckpointPosition,
    hasActiveTurn,
    actionsLocked,
  } = info;
  const [expandedFile, setExpandedFile] = useState<string | null>(null);
  const fileRowRefs = useRef(new Map<string, HTMLButtonElement>());

  const isCurrent = checkpointIndex === currentCheckpointPosition;
  const isUndone = checkpointIndex > currentCheckpointPosition;
  const isNextRedo = checkpointIndex === currentCheckpointPosition + 1;
  const canUndo =
    !hasActiveTurn &&
    !actionsLocked &&
    isCurrent &&
    checkpointIndex === info.totalCheckpointCount - 1;

  const parsedFiles = useMemo(
    () => parseUnifiedDiff(checkpoint.patch),
    [checkpoint.patch]
  );

  const parsedByPath = useMemo(() => {
    const map = new Map<string, ParsedDiffFile>();
    for (const f of parsedFiles) map.set(f.path, f);
    return map;
  }, [parsedFiles]);

  const stats = useMemo(
    () => countPatchStats(checkpoint.patch),
    [checkpoint.patch]
  );

  const handleUndo = useCallback(() => {
    try { window.webkit?.messageHandlers?.undoCodeCheckpoint?.postMessage(true); } catch {}
  }, []);

  const toggleFile = useCallback((path: string) => {
    setExpandedFile((prev) => (prev === path ? null : path));
  }, []);

  useEffect(() => {
    if (!expandedFile) {
      return;
    }

    const expandedRow = fileRowRefs.current.get(expandedFile);
    if (!expandedRow) {
      return;
    }

    const frameId = window.requestAnimationFrame(() => {
      expandedRow.scrollIntoView({
        behavior: "smooth",
        block: "center",
      });
    });

    return () => window.cancelAnimationFrame(frameId);
  }, [expandedFile]);

  const fileCount = checkpoint.changedFiles.length;
  const sectionTitle = fileCount === 1 ? "Edited file" : `Edited ${fileCount} files`;
  const stateLabel = isCurrent
    ? "Current checkpoint"
    : isNextRedo
      ? "Undone checkpoint"
      : isUndone
        ? "Later checkpoint"
        : "Earlier checkpoint";

  return (
    <div className={`msg-cp${isUndone ? " is-undone" : ""}${isCurrent ? " is-current" : ""}`}>
      <div className="msg-cp-header">
        <div className="msg-cp-header-copy">
          <span className="msg-cp-summary">
            {fileCount} {fileCount === 1 ? "file" : "files"} changed
            {stats.additions > 0 && <span className="msg-cp-add">+{stats.additions}</span>}
            {stats.deletions > 0 && <span className="msg-cp-del">-{stats.deletions}</span>}
          </span>
          <span className="msg-cp-state">{stateLabel}</span>
        </div>
        {canUndo && (
          <div className="msg-cp-actions">
            <button type="button" className="msg-cp-btn" onClick={handleUndo}>
              Undo
              <AppIcon symbol="undo" size={13} strokeWidth={2} />
            </button>
          </div>
        )}
      </div>

      <div className="msg-cp-section">
        <div className="msg-cp-section-header">
          <span className="msg-cp-section-title">{sectionTitle}</span>
          <span className="msg-cp-section-stats">
            <span className="msg-cp-add">+{stats.additions}</span>
            <span className="msg-cp-del">-{stats.deletions}</span>
          </span>
        </div>

        {checkpoint.changedFiles.map((file) => {
          const parsed = parsedByPath.get(file.path);
          const isOpen = expandedFile === file.path;
          const fileAdd = parsed?.additions ?? 0;
          const fileDel = parsed?.deletions ?? 0;

          return (
            <div key={file.path} className={`msg-cp-file${isOpen ? " is-open" : ""}`}>
              <button
                type="button"
                className="msg-cp-file-row"
                ref={(node) => {
                  if (node) {
                    fileRowRefs.current.set(file.path, node);
                  } else {
                    fileRowRefs.current.delete(file.path);
                  }
                }}
                onClick={() => toggleFile(file.path)}
              >
                <span className="msg-cp-file-path">{file.path}</span>
                <span className="msg-cp-file-stats">
                  {fileAdd > 0 && <span className="msg-cp-add">+{fileAdd}</span>}
                  {fileDel > 0 && <span className="msg-cp-del">-{fileDel}</span>}
                  {file.isBinary && <span className="msg-cp-bin">binary</span>}
                </span>
                <AppIcon
                  symbol="chevron.down"
                  className={`msg-cp-file-chevron${isOpen ? " is-open" : ""}`}
                  size={12}
                  strokeWidth={2}
                />
              </button>

              {isOpen && parsed && !parsed.binary && parsed.hunks.length > 0 && (
                <div className="msg-cp-diff">
                  {parsed.hunks.map((hunk, hi) => (
                    <div key={hi} className="msg-cp-hunk">
                      <div className="msg-cp-hunk-hdr">{hunk.header}</div>
                      {hunk.lines.map((line, li) => (
                        <div key={li} className={`msg-cp-line is-${line.kind}`}>
                          <span className="msg-cp-line-number">
                            {line.lineNumber ?? "\u00A0"}
                          </span>
                          <span className="msg-cp-gutter" aria-hidden="true">
                            {line.kind === "add" ? "+" : line.kind === "remove" ? "−" : " "}
                          </span>
                          <code>{line.text || "\u00A0"}</code>
                        </div>
                      ))}
                    </div>
                  ))}
                </div>
              )}

              {isOpen && parsed?.binary && (
                <div className="msg-cp-diff-empty">Binary file — no preview</div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
