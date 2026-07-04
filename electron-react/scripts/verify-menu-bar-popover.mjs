// Static wiring check for the live menu bar popover (July 2026 redesign):
// the renderer mirrors app status (running chats, unread replies) to the main
// process, the popover renders it (status pill, activity cards, last
// transcript), the window hugs its content height, and the new routes
// (New Chat, Today's Planner) reach the renderer. Keeps a refactor from
// silently reverting the popover to stale, static information.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");

function read(rel) {
  return fs.readFileSync(path.join(root, rel), "utf8");
}

const main = read("electron/main.ts");
const preload = read("electron/preload.ts");
const renderer = read("src/App.tsx");

const checks = [
  // Live state pipeline: renderer -> preload -> main -> popover refresh.
  ["renderer: mirrors running chats + unread replies to the menu bar", renderer, /setMenuBarState\(snapshot\)/],
  ["renderer: snapshot sends are deduped by signature", renderer, /menuBarStateSignatureRef/],
  ["preload: exposes setMenuBarState", preload, /setMenuBarState: \(state: unknown\) => ipcRenderer\.send\("openassist:menu-bar-state"/],
  ["main: sanitizes the snapshot and refreshes the popover", main, /openassist:menu-bar-state[\s\S]{0,900}refreshMenuBarPopoverIfVisible\(\);/],
  // The popover shows live information, not a stale document.
  ["main: header pill reflects running tasks and unread replies", main, /tasks running[\s\S]{0,200}unread repl/],
  ["main: status tone drives the pulsing dot", main, /menuBarHeaderStatusTone[\s\S]{0,400}"attention"/],
  ["main: activity cards render running assistant tasks", main, /activity-card working[\s\S]{0,400}oa-elapsed/],
  ["main: dynamic refresh updates pill, activity and transcript detail", main, /oa-status-pill[\s\S]{0,900}oa-transcript-detail/],
  ["main: paste row shows the last transcript snippet + age", main, /menuBarLastTranscriptDetail\(\)[\s\S]{0,400}No transcripts yet/],
  // Window height follows the card content.
  ["main: popover reports its content height", main, /menuBarReportHeight\(Math\.ceil\(oaCard\.getBoundingClientRect\(\)\.height\)\)/],
  ["main: reported height resizes and repositions the window", main, /openassist:menu-bar-report-height[\s\S]{0,500}positionMenuBarPopoverWindow\(window\)/],
  ["preload: exposes menuBarReportHeight", preload, /menuBarReportHeight: \(height: number\) => ipcRenderer\.send\("openassist:menu-bar-report-height"/],
  // New routes reach the renderer.
  ["main: menu bar commands include new-chat and open-today", main, /\| "new-chat"[\s\S]{0,200}\| "open-today"/],
  ["renderer: new-chat opens the assistant and creates a thread", renderer, /command === "new-chat"[\s\S]{0,120}createThread\(\)/],
  ["renderer: open-today opens the planner day", renderer, /command === "open-today"[\s\S]{0,160}openPlannerDay\(/]
];

let failures = 0;
for (const [label, source, re] of checks) {
  const pass = re.test(source);
  if (!pass) failures += 1;
  console.log(`${pass ? "PASS" : "FAIL"} ${label}`);
}

if (failures > 0) {
  console.error(`\nMenu bar popover guard check FAILED (${failures} missing).`);
  process.exit(1);
}
console.log("\nMenu bar popover guard check passed.");
