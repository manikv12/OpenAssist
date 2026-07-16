import { memo, useCallback, useEffect, useRef, useState } from "react";
import { AppIcon } from "./AppIcon";

interface Props {
  visible: boolean;
  onClose: () => void;
}

type ThreadNoteFindAction = "search" | "activate" | "clear";

interface ThreadNoteFindResponse {
  handled: boolean;
  matchCount: number;
  currentMatch: number;
}

interface ThreadNoteFindRequestDetail {
  action: ThreadNoteFindAction;
  query?: string;
  index?: number;
  respond: (result: ThreadNoteFindResponse) => void;
}

type FindTarget =
  | { source: "note"; index: number }
  | { source: "dom"; index: number };

const THREAD_NOTE_FIND_REQUEST_EVENT = "openassist:thread-note-find-request";

function FindBarInner({ visible, onClose }: Props) {
  const inputRef = useRef<HTMLInputElement>(null);
  const targetsRef = useRef<FindTarget[]>([]);
  const [query, setQuery] = useState("");
  const [matchCount, setMatchCount] = useState(0);
  const [currentMatch, setCurrentMatch] = useState(0);

  const requestThreadNoteFind = useCallback(
    (action: ThreadNoteFindAction, options?: { query?: string; index?: number }) => {
      let response: ThreadNoteFindResponse | null = null;
      window.dispatchEvent(
        new CustomEvent<ThreadNoteFindRequestDetail>(THREAD_NOTE_FIND_REQUEST_EVENT, {
          detail: {
            action,
            query: options?.query,
            index: options?.index,
            respond: (result) => {
              response = result;
            },
          },
        })
      );
      return response;
    },
    []
  );

  const activateTarget = useCallback(
    (target: FindTarget | undefined) => {
      if (!target) {
        return;
      }

      if (target.source === "note") {
        requestThreadNoteFind("activate", { index: target.index });
        return;
      }

      scrollToMatch(target.index);
    },
    [requestThreadNoteFind]
  );

  // Focus input when shown
  useEffect(() => {
    if (visible) {
      setTimeout(() => inputRef.current?.focus(), 50);
    } else {
      // Clear highlights when hiding
      clearHighlights();
      targetsRef.current = [];
      requestThreadNoteFind("clear");
      setQuery("");
      setMatchCount(0);
      setCurrentMatch(0);
    }
  }, [requestThreadNoteFind, visible]);

  const doSearch = useCallback(
    (searchQuery: string) => {
      clearHighlights();
      if (!searchQuery.trim()) {
        targetsRef.current = [];
        requestThreadNoteFind("clear");
        setMatchCount(0);
        setCurrentMatch(0);
        return;
      }

      const noteResult = requestThreadNoteFind("search", { query: searchQuery });
      const nextTargets: FindTarget[] = [];
      if (noteResult?.handled) {
        for (let index = 0; index < noteResult.matchCount; index += 1) {
          nextTargets.push({ source: "note", index });
        }
      }

      const matches: Range[] = [];
      const lowerQuery = searchQuery.toLowerCase();

      const containers = Array.from(
        document.querySelectorAll(
          ".chat-messages, .thread-note-rendered-markdown"
        )
      );
      containers.forEach((container) => {
        const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT, null);

        let node: Text | null;
        while ((node = walker.nextText())) {
          const parentElement = node.parentElement;
          if (
            !parentElement ||
            parentElement.closest(
              "mark.find-highlight, .find-bar, .thread-note-editor-body, button, input, textarea, select"
            )
          ) {
            continue;
          }

          const text = node.textContent || "";
          const lower = text.toLowerCase();
          let startIdx = 0;
          let idx: number;
          while ((idx = lower.indexOf(lowerQuery, startIdx)) !== -1) {
            const range = document.createRange();
            range.setStart(node, idx);
            range.setEnd(node, idx + searchQuery.length);
            matches.push(range);
            startIdx = idx + 1;
          }
        }
      });

      // Highlight all matches using CSS Highlight API or mark elements
      matches.forEach((range, i) => {
        const mark = document.createElement("mark");
        mark.className = "find-highlight";
        mark.dataset.findIndex = String(i);
        range.surroundContents(mark);
      });

      for (let index = 0; index < matches.length; index += 1) {
        nextTargets.push({ source: "dom", index });
      }

      targetsRef.current = nextTargets;
      setMatchCount(nextTargets.length);
      if (nextTargets.length > 0) {
        setCurrentMatch(1);
        activateTarget(nextTargets[0]);
      } else {
        setCurrentMatch(0);
      }
    },
    [activateTarget, requestThreadNoteFind]
  );

  const handleChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const val = e.target.value;
      setQuery(val);
      doSearch(val);
    },
    [doSearch]
  );

  const navigateMatch = useCallback(
    (direction: "next" | "prev") => {
      if (targetsRef.current.length === 0) return;
      let next =
        direction === "next" ? currentMatch + 1 : currentMatch - 1;
      if (next > targetsRef.current.length) next = 1;
      if (next < 1) next = targetsRef.current.length;
      setCurrentMatch(next);
      activateTarget(targetsRef.current[next - 1]);
    },
    [activateTarget, currentMatch]
  );

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === "Enter") {
        e.preventDefault();
        navigateMatch(e.shiftKey ? "prev" : "next");
      }
      if (e.key === "Escape") {
        e.preventDefault();
        onClose();
      }
    },
    [navigateMatch, onClose]
  );

  // Expose navigation for Cmd+G from Swift
  useEffect(() => {
    (window as any).chatBridge = {
      ...(window as any).chatBridge,
      findNavigate: (dir: "next" | "prev") => navigateMatch(dir),
    };
  }, [navigateMatch]);

  if (!visible) return null;

  return (
    <div className="find-bar">
      <input
        ref={inputRef}
        type="text"
        className="find-input"
        placeholder="Find in chat or notes…"
        value={query}
        onChange={handleChange}
        onKeyDown={handleKeyDown}
      />
      <span className="find-count">
        {matchCount > 0 ? `${currentMatch}/${matchCount}` : query ? "No results" : ""}
      </span>
      <button className="find-nav-btn" onClick={() => navigateMatch("prev")} title="Previous (Shift+Enter)">
        <AppIcon symbol="chevron.up" size={12} strokeWidth={2.5} />
      </button>
      <button className="find-nav-btn" onClick={() => navigateMatch("next")} title="Next (Enter)">
        <AppIcon symbol="chevron.down" size={12} strokeWidth={2.5} />
      </button>
      <button className="find-close-btn" onClick={onClose} title="Close (Esc)">
        <AppIcon symbol="xmark" size={12} strokeWidth={2.5} />
      </button>
    </div>
  );
}

function clearHighlights() {
  document.querySelectorAll("mark.find-highlight").forEach((mark) => {
    const parent = mark.parentNode;
    if (parent) {
      parent.replaceChild(document.createTextNode(mark.textContent || ""), mark);
      parent.normalize();
    }
  });
}

function scrollToMatch(index: number) {
  // Remove active class from all
  document.querySelectorAll("mark.find-active").forEach((m) => m.classList.remove("find-active"));
  const mark = document.querySelector(`mark.find-highlight[data-find-index="${index}"]`);
  if (mark) {
    mark.classList.add("find-active");
    mark.scrollIntoView({ behavior: "smooth", block: "center" });
  }
}

// Extend TreeWalker to have nextText helper
declare global {
  interface TreeWalker {
    nextText(): Text | null;
  }
}
TreeWalker.prototype.nextText = function (): Text | null {
  return this.nextNode() as Text | null;
};

export const FindBar = memo(FindBarInner);
