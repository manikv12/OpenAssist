import { useEffect } from "react";

/**
 * Convert a DOM tree (from selection) into rough markdown so that list items,
 * bold, italic, code, headings, etc. are preserved when pasting into a note.
 */
function htmlToMarkdown(root: HTMLElement): string {
  return convertChildren(root).replace(/\n{3,}/g, "\n\n").trim();

  function convertNode(node: Node): string {
    if (node.nodeType === Node.TEXT_NODE) {
      return node.textContent ?? "";
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return "";
    const el = node as HTMLElement;
    const tag = el.tagName.toLowerCase();
    const inner = convertChildren(el);

    switch (tag) {
      case "strong":
      case "b":
        return `**${inner}**`;
      case "em":
      case "i":
        return `*${inner}*`;
      case "code":
        if (el.parentElement?.tagName.toLowerCase() === "pre") return inner;
        return `\`${inner}\``;
      case "pre": {
        const code = el.querySelector("code");
        const lang =
          [...(code?.classList ?? [])].find((c) => c.startsWith("language-"))?.replace("language-", "") ?? "";
        const text = code?.textContent ?? inner;
        return `\n\`\`\`${lang}\n${text}\n\`\`\`\n`;
      }
      case "h1":
        return `\n# ${inner}\n`;
      case "h2":
        return `\n## ${inner}\n`;
      case "h3":
        return `\n### ${inner}\n`;
      case "h4":
        return `\n#### ${inner}\n`;
      case "h5":
        return `\n##### ${inner}\n`;
      case "h6":
        return `\n###### ${inner}\n`;
      case "blockquote":
        return `\n${inner.split("\n").map((l) => `> ${l}`).join("\n")}\n`;
      case "a":
        return `[${inner}](${el.getAttribute("href") ?? ""})`;
      case "br":
        return "\n";
      case "hr":
        return "\n---\n";
      case "p":
        return `\n${inner}\n`;
      case "ul":
      case "ol":
        return `\n${convertListItems(el, tag === "ol")}\n`;
      case "li":
        return inner;
      case "input":
        if (el.getAttribute("type") === "checkbox") {
          return (el as HTMLInputElement).checked ? "[x] " : "[ ] ";
        }
        return "";
      case "del":
      case "s":
        return `~~${inner}~~`;
      case "img":
        return `![${el.getAttribute("alt") ?? ""}](${el.getAttribute("src") ?? ""})`;
      default:
        return inner;
    }
  }

  function convertChildren(el: HTMLElement): string {
    let result = "";
    el.childNodes.forEach((child) => {
      result += convertNode(child);
    });
    return result;
  }

  function convertListItems(list: HTMLElement, ordered: boolean): string {
    const items: string[] = [];
    let index = parseInt(list.getAttribute("start") ?? "1", 10);
    list.querySelectorAll(":scope > li").forEach((li) => {
      const content = convertChildren(li as HTMLElement).replace(/^\n+|\n+$/g, "");
      const prefix = ordered ? `${index++}. ` : "- ";
      items.push(`${prefix}${content}`);
    });
    return items.join("\n");
  }
}

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

      const plainText = selection.toString();
      if (!plainText.trim()) return;

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

      // Extract markdown from the selected HTML so formatting is preserved
      const fragment = range.cloneContents();
      const container = document.createElement("div");
      container.appendChild(fragment);
      const selectedText = htmlToMarkdown(container) || plainText;

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
