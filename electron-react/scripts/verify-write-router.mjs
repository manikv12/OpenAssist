import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), "..");
const bridgePath = path.join(projectRoot, "electron", "openassistBridge.ts");
const realtimePath = path.join(projectRoot, "electron", "realtimeProxy.ts");
const appPath = path.join(projectRoot, "src", "App.tsx");
const typesPath = path.join(projectRoot, "src", "types.ts");
const phoneToolsPath = path.join(projectRoot, "..", "companion-projects", "OpenAssist-Mobile-Remote", "src", "services", "voice", "gemini-tools.ts");
const packagePath = path.join(projectRoot, "package.json");

function read(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function assertIncludes(text, needle, label) {
  if (!text.includes(needle)) throw new Error(`${label} missing: ${needle}`);
}

function assertRegex(text, pattern, label) {
  if (!pattern.test(text)) throw new Error(`${label} missing pattern: ${pattern}`);
}

const bridge = read(bridgePath);
const realtime = read(realtimePath);
const app = read(appPath);
const types = read(typesPath);
const phoneTools = read(phoneToolsPath);
const packageJSON = JSON.parse(read(packagePath));

for (const symbol of [
  "type KnowledgeWriteIntent",
  "type KnowledgeWriteDecision",
  "function classifyKnowledgeWriteIntent",
  "function resolveExistingWriteTarget",
  "function prepareSafeKnowledgeWrite",
  "function planKnowledgeWrite",
  "function assertSafeImmediateKnowledgeWrite"
]) {
  assertIncludes(bridge, symbol, "shared write router");
}

for (const phrase of [
  "New Lists are never created silently",
  "New notes are never created silently",
  "target: \"new_note_preview\"",
  "reference_note_create",
  "preview?.kind === \"reference_note_create\"",
  "resolveExistingReferenceTargetFromPayload",
  "return referenceCreatePreviewFromPayload(payload, lines)"
]) {
  assertIncludes(bridge, phrase, "approval-first note/list behavior");
}

assertIncludes(bridge, "dailyItemSimilarityScore", "token-overlap duplicate detection");
assertIncludes(bridge, "dailyItemLooksSimilar", "similar title duplicate detection");
assertRegex(bridge, /sharedTokens\.length\s*>=\s*2\s*&&\s*dailyItemSimilarityScore\(left,\s*right\)\s*>=\s*0\.8/, "similar-title threshold");
assertIncludes(bridge, "Maryland Ave", "router example guidance");
assertIncludes(bridge, "removePlainDailyItemLine(markdown: string, itemID: string)", "plain task block removal helper");
assertIncludes(bridge, "old children do not become orphan bullets above the new task", "plain task child cleanup");
assertIncludes(bridge, "scheduledBacklogDetailsForDay", "same-day moved-from cleanup");
assertIncludes(bridge, "Moved from ${normalizedTarget}.", "same-day moved-from removal");
assertIncludes(bridge, "removeLinkedNoteNameListScope", "linked note title must not become planner list scope");
assertIncludes(bridge, "not as the note name", "MCP guidance separates linked note title from list scope");
assertIncludes(bridge, "?? payload.title", "new reference notes use requested title before list title fallback");
assertIncludes(realtime, "not as the note name", "realtime guidance separates linked note title from list scope");
assertIncludes(phoneTools, "not as the note name", "phone guidance separates linked note title from list scope");
assertIncludes(bridge, "OpenAssist notes are not append-only", "MCP guidance advertises note replacement previews");
assertIncludes(bridge, "Do not answer that the MCP cannot reorganize a note", "MCP organize tool prevents append-only refusal");
assertIncludes(realtime, "OpenAssist notes are not append-only", "realtime guidance advertises note replacement previews");
assertIncludes(realtime, "do not say the MCP can only append", "realtime prevents append-only refusal");
assertIncludes(phoneTools, "OpenAssist notes are not append-only", "phone guidance advertises note replacement previews");
assertIncludes(phoneTools, "Do not say the MCP/app API cannot reorganize a note", "phone prevents append-only refusal");
assertIncludes(types, "reference_note_create", "frontend type supports new reference note preview");
assertIncludes(app, "Create new note", "approval UI shows new note action");
assertIncludes(app, "knowledgeApprovalDestination", "approval UI shows target destination");

assertIncludes(bridge, "dayID: normalizedTarget === \"backlog\"", "undated writes route to backlog");
assertIncludes(bridge, "resolvePlannerDayIDForWrite(dayID", "dated writes route to explicit planner day");
assertIncludes(bridge, "compactLinkedTaskDetails", "long task details are compacted when linked");
assertIncludes(bridge, "Save or approve the note first, then link the task", "long details without note link blocked");

for (const tool of ["oa_plan_write", "knowledge_plan_write"]) {
  assertIncludes(bridge, `case "${tool}"`, "plan write tool handler");
}
assertIncludes(bridge, 'name: "oa_plan_write"', "MCP plan write schema");
assertIncludes(realtime, 'name: "knowledge_plan_write"', "realtime plan write schema");
assertIncludes(phoneTools, "name: 'plan_write'", "phone plan write schema");
assertIncludes(phoneTools, "new notes are never created silently", "phone note creation guidance");
assertIncludes(bridge, 'case "plan_write"', "Mac voice plan_write route");

for (const guarded of [
  "directDailyItemUpsertFromPayload",
  "updateDailyItemByText(assertSafeImmediateKnowledgeWrite",
  "request_backlog_item",
  "create_project_note",
  "create_thread_note"
]) {
  assertIncludes(bridge, guarded, "existing write tool enforcement");
}

if (packageJSON.scripts?.["verify:write-router"] !== "node scripts/verify-write-router.mjs") {
  throw new Error("package.json missing verify:write-router script.");
}

console.log("Write-router verification passed.");
