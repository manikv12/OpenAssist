import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), "..");
const bridgePath = path.join(projectRoot, "electron", "openassistBridge.ts");
const realtimePath = path.join(projectRoot, "electron", "realtimeProxy.ts");
const appPath = path.join(projectRoot, "src", "App.tsx");
const packagePath = path.join(projectRoot, "package.json");

function read(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function assertIncludes(text, needle, label) {
  if (!text.includes(needle)) {
    throw new Error(`${label} missing: ${needle}`);
  }
}

function assertNotIncludes(text, needle, label) {
  if (text.includes(needle)) {
    throw new Error(`${label} should not include: ${needle}`);
  }
}

function sectionBetween(text, startNeedle, endNeedle, label) {
  const start = text.indexOf(startNeedle);
  if (start < 0) throw new Error(`${label} start not found: ${startNeedle}`);
  const end = text.indexOf(endNeedle, start + startNeedle.length);
  if (end < 0) throw new Error(`${label} end not found: ${endNeedle}`);
  return text.slice(start, end);
}

const bridge = read(bridgePath);
const realtime = read(realtimePath);
const app = read(appPath);
const packageJSON = JSON.parse(read(packagePath));

for (const tool of ["oa_quick_add_task", "oa_quick_save_note", "oa_quick_read"]) {
  assertIncludes(bridge, `name: "${tool}"`, "quick tool definition");
  assertIncludes(bridge, `case "${tool}"`, "quick tool handler");
}

for (const tool of ["oa_personal_recall_search", "oa_personal_recall_read"]) {
  assertIncludes(bridge, `name: "${tool}"`, "personal recall tool definition");
  assertIncludes(bridge, `case "${tool}"`, "personal recall tool handler");
}
assertIncludes(realtime, 'name: "knowledge_personal_recall"', "realtime Spark personal recall tool");
assertIncludes(realtime, "function personalRecallRunningDetail", "realtime personal recall contextual progress helper");
assertIncludes(realtime, "function directSpeechInstructions", "OpenAI direct-result speech instructions");
assertIncludes(realtime, "Keep it short and natural", "Live direct-result natural answer instruction");
assertIncludes(realtime, "object?.spokenAnswer", "Live personal recall uses spoken answer when available");
assertIncludes(realtime, "openAIDirectResultAudioRetryMs = 9_000", "OpenAI direct-result audio retry delay");
assertIncludes(realtime, 'this.requestOpenAIResponseCreate("agent result", response)', "OpenAI direct-result response.create payload");
assertIncludes(realtime, "rerouted recall background_agent to knowledge_personal_recall", "OpenAI realtime recall handoff guard");
assertIncludes(realtime, "Gemini recall background_agent rerouted to knowledge_personal_recall", "Gemini realtime recall handoff guard");
assertIncludes(bridge, 'const defaultSparkRecallModel = "gpt-5.3-codex-spark"', "Spark recall model default");
assertIncludes(bridge, "function normalizeSparkRecallModel", "Spark recall model id normalization");
assertIncludes(bridge, 'normalized === "gpt-5.3-spark"', "Spark recall maps plain Spark id to Codex Spark id");
assertIncludes(bridge, 'codexTransport.request("model/list"', "Spark recall probes app-server model list");
assertIncludes(bridge, "function codexModelIDsForRecall", "Spark recall model-list helper");
assertIncludes(bridge, 'serviceName: "OpenAssist Spark Recall"', "Spark recall service name");
assertIncludes(bridge, "ephemeral: true", "Spark recall ephemeral thread");
assertIncludes(bridge, "function personalRecallBaseInstructions", "Spark recall minimal base instructions");
assertIncludes(bridge, "function personalRecallOutputSchema", "Spark recall structured output schema");
assertIncludes(bridge, "function retrievePersonalRecallEvidence", "Spark recall local retrieval helper");
assertIncludes(bridge, "function renderRetrievedPersonalRecallAnswer", "Spark recall retrieval-rendered answer helper");
assertIncludes(bridge, "function spokenPersonalRecallAnswer", "Spark recall short spoken answer helper");
assertIncludes(bridge, "function wantsSavedSparkRecallResult", "Spark recall records are explicit-only evidence");
assertIncludes(bridge, "function personalRecallNeedsChatSearch", "Spark recall detects latest/recent chat requests");
assertIncludes(bridge, "function personalRecallRetrievalQuery", "Spark recall combines query with recent live context");
assertIncludes(realtime, "private recentUserUtterances", "Live recall keeps short recent user context");
assertIncludes(realtime, "private personalRecallArgs", "Live recall enriches tool args with recent context");
assertIncludes(realtime, "this.personalRecallArgs(args", "Live recall tool calls use enriched args");
const sparkRunner = sectionBetween(bridge, "async function runSparkPersonalRecall", "function looksLikeSearchEverythingQuestion", "Spark recall runner");
assertNotIncludes(sparkRunner, "persistExtendedHistory", "Spark recall runner must not persist full hidden thread history");
assertIncludes(sparkRunner, 'effort: reasoningEffort', "Spark recall reasoning effort");
assertIncludes(sparkRunner, 'sandbox: "read-only"', "Spark recall thread read-only sandbox");
assertIncludes(sparkRunner, 'sandboxPolicy: { type: "readOnly", networkAccess: false }', "Spark recall turn read-only sandbox policy");
assertIncludes(sparkRunner, "outputSchema: personalRecallOutputSchema()", "Spark recall constrained JSON output");
assertIncludes(sparkRunner, "Do not use commandexecution", "Spark recall command tool block");
assertNotIncludes(sparkRunner, "personalRecallFallbackAnswer", "Spark recall must not use local fallback answer");
assertIncludes(sparkRunner, "retrievePersonalRecallEvidence(question, context)", "Spark recall retrieves fast local recall results with recent context");
assertIncludes(sparkRunner, "Spark recall retrieval memory=", "Spark recall logs retrieval counts");
assertIncludes(sparkRunner, "retrieved.context", "Spark recall supplies retrieval context to Spark");
assertIncludes(sparkRunner, "Recent live context:", "Spark recall supplies recent live context to Spark");
assertIncludes(sparkRunner, "renderRetrievedPersonalRecallAnswer(question, retrieved.results)", "Spark recall renders retrieved evidence when Spark text is weak");
assertIncludes(sparkRunner, "spokenAnswer: spokenPersonalRecallAnswer(answer)", "Spark recall returns concise spoken answer");

assertNotIncludes(bridge, "withAutoComputerUsePlugin", "Computer Use must not be auto-attached to turns");
const codexToolSelection = sectionBetween(
  bridge,
  "async function normalizeCodexToolSelection",
  "const localDesktopAutomationToolNames",
  "Codex tool selection normalizer"
);
assertIncludes(codexToolSelection, "return { pluginIDs: canonicalPluginIDs, skillIDs };", "Codex tool selection keeps explicit plugin IDs only");
assertIncludes(codexToolSelection, "pluginIDsByKey.set(pluginID.toLowerCase(), pluginID);", "Codex tool selection still maps explicit plugin-backed skills");
assertNotIncludes(codexToolSelection, "codexPreferredComputerUsePluginID", "Codex tool selection must not add Computer Use implicitly");

assertIncludes(bridge, 'name: "oa_plan_write"', "write router plan tool definition");
assertIncludes(bridge, 'case "oa_plan_write"', "write router plan tool handler");
assertIncludes(realtime, 'name: "knowledge_plan_write"', "realtime write router plan tool");
assertIncludes(bridge, 'mcp_servers.openassist_knowledge.command=\\"node\\"', "OpenAI realtime app-server stdio MCP command override");
assertIncludes(bridge, 'mcp_servers.openassist_knowledge.args=', "OpenAI realtime app-server stdio MCP args override");
assertNotIncludes(bridge, 'mcp_servers.openassist_knowledge.url=', "OpenAI realtime app-server must not mix url into stdio MCP config");

for (const tool of ["oa_list_approvals", "oa_apply_approval", "oa_reject_approval"]) {
  assertIncludes(bridge, `name: "${tool}"`, "approval tool definition");
  assertIncludes(bridge, `case "${tool}"`, "approval tool handler");
}

assertIncludes(bridge, 'action === "request_daily_item" || action === "request_reference"', "safe add auto-apply policy");
assertIncludes(bridge, "function resolveTaskLinkTargetsFromPayload", "task note-link resolver");
assertIncludes(bridge, "noteItemID", "quick task note link field");
assertIncludes(bridge, "detailsMode", "replace detail field");
assertIncludes(bridge, "replaceDetails", "replace detail flag");
assertIncludes(bridge, "resolveTaskLinkTargetsFromPayload(payload)", "daily item link resolution");
assertIncludes(bridge, "resolveTaskLinkTargetsFromPayload(preparedPayload)", "backlog item link resolution");
assertIncludes(bridge, "if (noteTitle && hasReferenceScope)", "note title scoped link resolution");
assertIncludes(bridge, "function inferredLinkedTaskNoteTitle", "linked list-name note inference");
assertIncludes(bridge, "function compactLinkedTaskDetails", "linked task detail compaction");
assertIncludes(bridge, "detailsMode === \"replace\"", "duplicate replace-detail behavior");
assertIncludes(bridge, "normalizeDailyLinks([...match.links, ...resolvedLinks])", "update link merge behavior");
assertIncludes(bridge, "compactLinkedTaskDetails(rawWithLinks, mergedLinks)", "update compact linked-note details");
assertIncludes(bridge, "Planner tasks should be short action pointers", "MCP planner-vs-note tool guidance");
assertIncludes(bridge, "detailed specs, dimensions, and long checklists belong in a linked note", "simple MCP planner-vs-note guidance");
assertIncludes(bridge, "Planner items are lightweight execution pointers", "integration planner-vs-note skill guidance");
assertIncludes(bridge, "go to Maryland Ave tomorrow and check TV/laundry fit", "integration planner-vs-note example");
assertIncludes(bridge, "## Collapsible sections", "note style guide collapsible block");
assertIncludes(bridge, "## Structuring long reference notes", "note style guide long-note structure");
assertIncludes(bridge, "oa:collapsible", "integration collapsible block syntax");

assertIncludes(realtime, "noteItemID", "realtime quick task note link field");
assertIncludes(realtime, "noteTitle", "realtime quick task note title field");
assertIncludes(realtime, "detailsMode", "realtime replace detail field");
assertIncludes(realtime, "never paste the full note body into the task", "realtime note-link guidance");
assertIncludes(realtime, "Planner tasks should be short action pointers", "realtime tool planner-vs-note guidance");
assertIncludes(realtime, "Planner items are lightweight execution pointers", "realtime planner-vs-note instruction");
assertIncludes(realtime, "collapsible sections (## Area <!-- oa:collapsible -->)", "realtime collapsible blocks guidance");
assertIncludes(realtime, "keep it scannable", "realtime long-note structure guidance");

const simpleList = sectionBetween(bridge, "const simpleKnowledgeMCPToolNames = [", "] as const;", "simple tool allowlist");
for (const tool of [
  "oa_quick_add_task",
  "oa_quick_save_note",
  "oa_quick_read",
  "oa_personal_recall_search",
  "oa_personal_recall_read",
  "oa_list_approvals",
  "oa_apply_approval",
  "oa_reject_approval",
  "oa_complete_daily_item",
  "oa_list_planner_categories"
]) {
  assertIncludes(simpleList, `"${tool}"`, "simple allowlist");
}

const dailyRequestHandler = sectionBetween(
  bridge,
  'case "oa_request_daily_item":',
  'case "oa_note_style_guide":',
  "daily item direct handler"
);
assertIncludes(dailyRequestHandler, "directDailyItemUpsertFromPayload(args)", "direct daily add routing");

const skill = sectionBetween(bridge, "function openAssistIntegrationSkillMarkdown()", "function openAssistIntegrationSkillContent", "integration skill");
for (const phrase of [
  "## Fast Path",
  "Do not search, list, or read schemas first",
  "oa_quick_add_task",
  "oa_quick_save_note",
  "oa_quick_read",
  "oa_list_approvals",
  "oa_apply_approval",
  "oa_reject_approval",
  "oa_complete_daily_item",
  "noteItemID",
  "detailsMode: \\\"replace\\\"",
  "Do not paste the full note body into task details",
  "Planner items are lightweight execution pointers",
  "TV dimensions, LG WashCombo dimensions, and measurement checklist belong inside that linked note"
]) {
  assertIncludes(skill, phrase, "integration fast-path skill");
}

assertIncludes(app, "Common fast actions", "integration UI cheat sheet");
assertIncludes(app, 'externalAccessMode === "full" ? undefined', "full mode fallback count");
assertIncludes(app, "daily-inline-linked-notes", "today inline note links UI");
assertIncludes(app, "renderLinkedNotes(\"inline\")", "today inline note link renderer");

if (packageJSON.scripts?.["verify:external-fast-path"] !== "node scripts/verify-external-fast-path.mjs") {
  throw new Error("package.json missing verify:external-fast-path script.");
}

console.log("External MCP fast-path verification passed.");
