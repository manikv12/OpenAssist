import { useEffect } from "react";

/**
 * Monitors text selection changes in the chat and reports them to Swift.
 * Sends: selectedText, messageID, parentMessageText, and selection bounding rect.
 */
export function useTextSelection() {
  useEffect(() => {
    let debounceTimer: number | null = null;

    function handleSelectionChange() {
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = window.setTimeout(reportSelection, 150);
    }

    function reportSelection() {
      const selection = window.getSelection();
      if (!selection || selection.isCollapsed || !selection.toString().trim()) {
        // Selection cleared
        try {
          window.webkit?.messageHandlers?.textSelected?.postMessage(null);
        } catch {}
        return;
      }

      const selectedText = selection.toString();
      if (!selectedText.trim()) return;

      // Walk up from the selection anchor to find the parent message row
      const anchorNode = selection.anchorNode;
      if (!anchorNode) return;

      const messageRow = findParentMessageRow(anchorNode);
      if (!messageRow) return;

      const messageID = messageRow.getAttribute("data-message-id") || "";
      const parentMessageText =
        messageRow.getAttribute("data-message-text") || "";

      // Get selection bounding rect (relative to viewport)
      const range = selection.getRangeAt(0);
      const rect = range.getBoundingClientRect();

      try {
        window.webkit?.messageHandlers?.textSelected?.postMessage({
          selectedText,
          messageID,
          parentMessageText,
          rect: {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
          },
        });
      } catch {}
    }

    function findParentMessageRow(node: Node): HTMLElement | null {
      let el: HTMLElement | null =
        node.nodeType === Node.ELEMENT_NODE
          ? (node as HTMLElement)
          : node.parentElement;
      while (el) {
        if (el.hasAttribute("data-message-id")) return el;
        el = el.parentElement;
      }
      return null;
    }

    document.addEventListener("selectionchange", handleSelectionChange);

    // Also handle mouseup for immediate feedback
    document.addEventListener("mouseup", () => {
      // Small delay to let selection settle
      setTimeout(reportSelection, 50);
    });

    return () => {
      document.removeEventListener("selectionchange", handleSelectionChange);
      if (debounceTimer) clearTimeout(debounceTimer);
    };
  }, []);
}

// Extend window types
declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        textSelected?: { postMessage: (v: any) => void };
        [key: string]: { postMessage: (v: any) => void } | undefined;
      };
    };
  }
}
