import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const styles = fs.readFileSync(path.join(root, "src/styles.css"), "utf8");

const rules = (selector) => {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const matches = [...styles.matchAll(new RegExp(`${escaped}\\s*\\{([\\s\\S]*?)\\}`, "g"))];
  assert.ok(matches.length > 0, `Missing CSS rule for ${selector}.`);
  return matches.map((match) => match[1]).join("\n");
};

assert.match(
  rules(".app-shell"),
  /grid-template-columns:\s*var\(--sidebar-width\)\s+minmax\(0,\s*1fr\)/,
  "The main content grid must remain shrinkable inside the Electron window."
);
assert.match(rules(".app-shell > *"), /min-width:\s*0/, "Every main grid child must allow shrinking.");
assert.match(rules(".assistant-markdown-shell"), /overflow-wrap:\s*anywhere/, "Long assistant text must wrap.");
assert.match(rules(".activity-detail pre"), /overflow:\s*auto/, "Expanded tool output must scroll inside its card.");
assert.match(rules(".message-artifact-card"), /min-width:\s*0/, "Generated-file cards must not widen the chat.");
assert.match(
  rules(".markdown-preview-surface .markdown-table-wrap"),
  /overflow-x:\s*auto/,
  "Wide tables must scroll inside their own wrapper instead of being clipped."
);

console.log("Chat width containment verification passed.");
