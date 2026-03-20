import { memo, useCallback, useEffect, useRef, useState } from "react";

interface Props {
  visible: boolean;
  onClose: () => void;
}

function FindBarInner({ visible, onClose }: Props) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [query, setQuery] = useState("");
  const [matchCount, setMatchCount] = useState(0);
  const [currentMatch, setCurrentMatch] = useState(0);

  // Focus input when shown
  useEffect(() => {
    if (visible) {
      setTimeout(() => inputRef.current?.focus(), 50);
    } else {
      // Clear highlights when hiding
      clearHighlights();
      setQuery("");
      setMatchCount(0);
      setCurrentMatch(0);
    }
  }, [visible]);

  const doSearch = useCallback(
    (searchQuery: string) => {
      clearHighlights();
      if (!searchQuery.trim()) {
        setMatchCount(0);
        setCurrentMatch(0);
        return;
      }

      const container = document.querySelector(".chat-messages");
      if (!container) return;

      const walker = document.createTreeWalker(
        container,
        NodeFilter.SHOW_TEXT,
        null
      );

      const matches: Range[] = [];
      const lowerQuery = searchQuery.toLowerCase();

      let node: Text | null;
      while ((node = walker.nextText())) {
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

      // Highlight all matches using CSS Highlight API or mark elements
      matches.forEach((range, i) => {
        const mark = document.createElement("mark");
        mark.className = "find-highlight";
        mark.dataset.findIndex = String(i);
        range.surroundContents(mark);
      });

      setMatchCount(matches.length);
      if (matches.length > 0) {
        setCurrentMatch(1);
        scrollToMatch(0);
      } else {
        setCurrentMatch(0);
      }
    },
    []
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
      if (matchCount === 0) return;
      let next =
        direction === "next" ? currentMatch + 1 : currentMatch - 1;
      if (next > matchCount) next = 1;
      if (next < 1) next = matchCount;
      setCurrentMatch(next);
      scrollToMatch(next - 1);
    },
    [currentMatch, matchCount]
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
        placeholder="Find in chat…"
        value={query}
        onChange={handleChange}
        onKeyDown={handleKeyDown}
      />
      <span className="find-count">
        {matchCount > 0 ? `${currentMatch}/${matchCount}` : query ? "No results" : ""}
      </span>
      <button className="find-nav-btn" onClick={() => navigateMatch("prev")} title="Previous (Shift+Enter)">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><polyline points="18 15 12 9 6 15"/></svg>
      </button>
      <button className="find-nav-btn" onClick={() => navigateMatch("next")} title="Next (Enter)">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><polyline points="6 9 12 15 18 9"/></svg>
      </button>
      <button className="find-close-btn" onClick={onClose} title="Close (Esc)">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
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
