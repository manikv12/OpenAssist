import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const appPath = path.resolve("src/App.tsx");
const source = fs.readFileSync(appPath, "utf8");

assert.ok(
  source.includes('const remainingLines = lines.slice(1).join("\\n").trim();'),
  "heading conversion must keep the lines after the title"
);
assert.ok(
  source.includes('return remainingLines ? `${heading}\\n\\n${remainingLines}` : heading;'),
  "heading conversion must place the preserved body below the heading"
);
assert.ok(
  source.includes("const handleRichEditorDoubleClick"),
  "rich note headings must have a double-click rename handler"
);
assert.ok(
  source.includes('event.target.closest<HTMLElement>("h1, h2, h3, h4, h5, h6")'),
  "double-click rename must target heading nodes"
);
assert.ok(
  source.includes("onDoubleClickCapture={handleRichEditorDoubleClick}"),
  "the heading rename handler must be connected to the editor"
);

console.log("Note node editing checks passed.");
