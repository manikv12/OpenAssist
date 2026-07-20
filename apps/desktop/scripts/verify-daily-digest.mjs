// Static wiring check for the end-of-day Daily Digest: the bridge builds the
// day payload and calls the Codex subscription endpoint (same pipeline as
// screen analysis / note cleanup), every open task is guaranteed to appear as
// a leftover, apply reuses the existing planner move/delete/upsert functions,
// and the renderer exposes the Wrap up button + review panel.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const read = (rel) => fs.readFileSync(path.join(root, rel), "utf8");

const bridge = read("electron/openassistBridge.ts");
const main = read("electron/main.ts");
const preload = read("electron/preload.ts");
const renderer = read("src/App.tsx");
const styles = read("src/styles.css");

const checks = [
  ["bridge: digest calls the Codex subscription endpoint", bridge, /generatePlannerDailyDigest[\s\S]{0,3000}chatgpt\.com\/backend-api\/codex\/responses/],
  ["bridge: digest prompt demands follow-ups from done tasks", bridge, /followUps: look at DONE tasks whose outcome implies waiting/],
  ["bridge: every open task is backfilled as a keep leftover", bridge, /anything it missed shows[\s\S]{0,120}up as a "keep"/],
  ["bridge: apply moves leftovers with existing planner functions", bridge, /applyPlannerDailyDigestPlan[\s\S]{0,1500}moveDailyItemToDay\(dayID, itemID, nextDayID\)[\s\S]{0,400}moveDailyItemToBacklog\(dayID, itemID\)[\s\S]{0,400}deleteDailyItem\(dayID, itemID\)/],
  ["bridge: accepted follow-ups become real tasks", bridge, /applyPlannerDailyDigestPlan[\s\S]{0,4000}upsertBacklogItem\(\{ dayID: plannerBacklogID, title[\s\S]{0,300}upsertDailyItem\(\{ dayID: nextDayID, title/],
  ["bridge: digest functions are exported", bridge, /generatePlannerDailyDigest,\s*\n\s*applyPlannerDailyDigestPlan,/],
  ["main: digest IPC handlers registered", main, /openassist:planner-daily-digest[\s\S]{0,300}openassist:planner-daily-digest-apply/],
  ["preload: digest APIs exposed", preload, /plannerDailyDigest: \(dayID\?: string\)[\s\S]{0,200}applyPlannerDailyDigest: \(plan: unknown\)/],
  ["renderer: Wrap up button shows on Today only", renderer, /\{!backlogOpen && currentDayID === todayID && \([\s\S]{0,300}planner-digest-button[\s\S]{0,500}Wrap up/],
  ["bridge: carry-forward target never lands in the past", bridge, /plannerNextDayID[\s\S]{0,400}candidate < today \? today : candidate/],
  ["renderer: digest applies only after user confirmation", renderer, /applyDailyDigest[\s\S]{0,600}digestLeftoverChoices\[leftover\.itemID\] \?\? "keep"/],
  ["renderer: follow-ups are opt-out checkboxes", renderer, /digestFollowUpChoices\[index\] !== false/],
  ["styles: digest panel styled", styles, /\.planner-digest-panel \{[\s\S]{0,400}max-height/]
];

let failures = 0;
for (const [label, source, re] of checks) {
  const pass = re.test(source);
  if (!pass) failures += 1;
  console.log(`${pass ? "PASS" : "FAIL"} ${label}`);
}

if (failures > 0) {
  console.error(`\nDaily digest guard check FAILED (${failures} missing).`);
  process.exit(1);
}
console.log("\nDaily digest guard check passed.");
