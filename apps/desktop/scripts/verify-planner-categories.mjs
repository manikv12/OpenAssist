import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const bridgePath = path.resolve("electron/openassistBridge.ts");
const proxyPath = path.resolve("electron/realtimeProxy.ts");
const appPath = path.resolve("src/App.tsx");
const stylesPath = path.resolve("src/styles.css");
const typesPath = path.resolve("src/types.ts");
const preloadPath = path.resolve("electron/preload.ts");
const mainPath = path.resolve("electron/main.ts");

for (const filePath of [bridgePath, proxyPath, appPath, stylesPath, typesPath, preloadPath, mainPath]) {
  assert.ok(fs.existsSync(filePath), `Missing ${filePath}`);
}

const bridgeText = fs.readFileSync(bridgePath, "utf8");
const proxyText = fs.readFileSync(proxyPath, "utf8");
const appText = fs.readFileSync(appPath, "utf8");
const stylesText = fs.readFileSync(stylesPath, "utf8");
const typesText = fs.readFileSync(typesPath, "utf8");
const preloadText = fs.readFileSync(preloadPath, "utf8");
const mainText = fs.readFileSync(mainPath, "utf8");

assert.ok(typesText.includes("export type PlannerCategory"), "PlannerCategory type must exist");
assert.ok(typesText.includes("area?: string;"), "ProjectItem/DailyItem must support category area strings");
assert.ok(typesText.includes("plannerOnly?: boolean;"), "ProjectItem must support planner-only Lists");
assert.ok(typesText.includes("section?: string;"), "DailyItem must support Sections");
assert.ok(typesText.includes("tags?: string[];"), "DailyItem must support free-form Tags");
assert.ok(/export type NoteItem = \{[\s\S]*?area\?: string;[\s\S]*?tags\?: string\[\];[\s\S]*?\};/.test(typesText), "Notes must support Category and Tags metadata");
assert.ok(typesText.includes("PlannerSmartListSummary"), "Planner smart list type must exist");

assert.ok(bridgeText.includes("plannerCategoriesPath()"), "bridge must define plannerCategoriesPath");
assert.ok(bridgeText.includes("defaultPlannerCategoryNames"), "bridge must seed default categories");
assert.ok(bridgeText.includes("function loadPlannerCategories"), "bridge must load planner categories");
assert.ok(bridgeText.includes("function upsertPlannerCategory"), "bridge must upsert planner categories");
assert.ok(bridgeText.includes("function updateProjectArea"), "bridge must support project default categories");
assert.ok(bridgeText.includes("function createPlannerList"), "bridge must create planner-created Lists");
assert.ok(bridgeText.includes("plannerOnly: true"), "created Planner Lists must be planner-only");
assert.ok(bridgeText.includes("function listPlannerSmartLists"), "bridge must list Smart Lists");
assert.ok(bridgeText.includes("function listPlannerSmartListItems"), "bridge must list Smart List items");
assert.ok(bridgeText.includes('"shopping"') && bridgeText.includes('"work-follow-ups"'), "built-in Smart Lists must include expected ids");
assert.ok(bridgeText.includes("normalizeDailySection"), "bridge must normalize item sections");
assert.ok(bridgeText.includes("normalizeDailyTagLabels"), "bridge must normalize item tags");
assert.ok(bridgeText.includes("areaFromScopeTags"), "bridge must map #Category scope tags to item areas");
assert.ok(bridgeText.includes("plannerListScopeTags"), "bridge must keep categories separate from List scope tags");
assert.ok(bridgeText.includes("projectNotesHiddenForList"), "planner-created Lists must remain available to Notes");
assert.ok(bridgeText.includes("noteMetadataFromRecord"), "bridge must load note Category/List/Tag metadata");

assert.ok(
  /if \(\["work", "job", "office", "client"\]\.includes\(normalized\)\)/.test(bridgeText),
  "legacy Work aliases must not include business"
);
assert.ok(
  bridgeText.includes('normalized === "business"') && bridgeText.includes('category.name.toLowerCase() === "business"'),
  "Business should resolve to a Business category when it exists"
);
assert.ok(bridgeText.includes("projectAreaFromScope(input)"), "inferDailyArea must consult project/folder defaults");

assert.ok(bridgeText.includes('name: "oa_list_planner_categories"'), "MCP must expose oa_list_planner_categories");
assert.ok(bridgeText.includes('name: "oa_list_planner_lists"'), "MCP must expose oa_list_planner_lists");
assert.ok(bridgeText.includes('name: "oa_update_daily_item"'), "MCP must expose oa_update_daily_item for planner edits");
assert.ok(bridgeText.includes('name: "oa_request_tasks_from_note"'), "MCP must expose oa_request_tasks_from_note for previewed note-to-task planning");
assert.ok(bridgeText.includes("function updateDailyItemByText"), "bridge must update existing planner items without duplicating them");
assert.ok(bridgeText.includes('case "knowledge_planner_categories"'), "bridge must handle realtime category listing alias");
assert.ok(bridgeText.includes('case "knowledge_request_tasks_from_note"'), "bridge must handle realtime note-to-task preview alias");
assert.ok(bridgeText.includes('kind: "daily_items_batch"'), "bridge previews must support bulk note-to-task task batches");
assert.ok(bridgeText.includes("listID") && bridgeText.includes("section") && bridgeText.includes("tags"), "planner item schemas must accept list, section, and tags");
assert.ok(!/area:\s*\{\s*type:\s*"string",\s*enum:\s*\["Work",\s*"Personal"\]/.test(bridgeText), "bridge schemas must not restrict area to Work/Personal");
assert.ok(!/area:\s*\{\s*type:\s*"string",\s*enum:\s*\["Work",\s*"Personal"\]/.test(proxyText), "realtime schemas must not restrict area to Work/Personal");
assert.ok(proxyText.includes('name: "knowledge_planner_categories"'), "hidden Live Voice capabilities must include planner categories");
assert.ok(proxyText.includes('name: "knowledge_planner_lists"'), "hidden Live Voice capabilities must include planner lists");
assert.ok(proxyText.includes('name: "knowledge_update_daily_item"'), "hidden Live Voice capabilities must include planner edits");
assert.ok(proxyText.includes('name: "knowledge_request_tasks_from_note"'), "hidden Live Voice capabilities must include previewed note-to-task planning");
assert.ok(proxyText.includes("listID") && proxyText.includes("section") && proxyText.includes("tags"), "hidden planner capability schemas must accept list, section, and tags");
assert.ok(proxyText.includes("liveVoiceCapabilityDescriptors") && proxyText.includes("realtimeVoiceKnowledgeToolSpecs.map"), "Live Voice must keep planner tools in the hidden capability registry");
assert.ok(proxyText.includes("Call this before assigning category/list when the user has not named an exact category or list"), "planner category selection must inspect real categories before assigning one");
assert.ok(bridgeText.includes("Do not assume business-related tasks are Work"), "knowledge instructions must mention business category handling");
assert.ok(proxyText.includes("If `when` is today") && proxyText.includes("if omitted/backlog/later, adds to Backlog"), "hidden planner capabilities must keep dated and date-less task targets distinct");
assert.ok(bridgeText.includes("Do not also add Today tasks to Backlog"), "knowledge instructions must keep Today tasks out of Backlog unless requested");
assert.ok(proxyText.includes("It replaces the matched old item instead of adding a duplicate"), "hidden planner edit capability must avoid duplicate add-on-edit behavior");
assert.ok(bridgeText.includes("do not add a new item and leave the old one behind"), "knowledge instructions must avoid duplicate add-on-edit behavior");
assert.ok(bridgeText.includes("#Category") && bridgeText.includes("@List"), "knowledge instructions must document #Category and @List shorthand");
assert.ok(proxyText.includes("area/category") && proxyText.includes("listID/listName"), "hidden planner schemas must distinguish categories from lists");
assert.ok(bridgeText.includes("create tasks from a note") && bridgeText.includes("Review Inbox preview"), "knowledge instructions must require preview-first note-to-task planning");
assert.ok(proxyText.includes("Create a Review Inbox preview") && proxyText.includes("Do not claim tasks were created until approved"), "hidden note-to-task capability must require preview-first planning");
assert.ok(!bridgeText.includes("@Project and #Folder"), "bridge tool descriptions must not teach old @Project/#Folder shorthand");

assert.ok(appText.includes("PlannerCategoryManager"), "UI must include a planner category management surface");
assert.ok(appText.includes("dailyCategoryFilterID"), "UI must include category filters for daily/backlog items");
assert.ok(appText.includes("onCreatePlannerList"), "UI must allow creating Planner Lists");
assert.ok(appText.includes("plannerSmartLists"), "app state must keep Smart List data for tools");
assert.ok(appText.includes("groupDailyItemsByOrganization"), "UI must group items by Category, List, and Section");
assert.ok(appText.includes("daily-quick-section") && appText.includes("daily-quick-tags"), "UI must include Section and Tags quick controls");
assert.ok(appText.includes('list="daily-quick-category-options"'), "Today quick add must allow typing category headings");
assert.ok(appText.includes("dailyTagSuggestionsFromProjects(projects: ProjectItem[], categories"), "UI tag suggestions must include Categories and Lists");
assert.ok(appText.includes('kind: "category"'), "UI must understand #Category scope tags");
assert.ok(appText.includes("listSearch") && appText.includes("project-search-field"), "Notes sidebar Lists section must support list search");
assert.ok(appText.includes("selectedNoteTargetToKnowledgeItemID"), "Live voice must pass the active note knowledge item id");
assert.ok(appText.includes('kind === "daily_items_batch"'), "Review Inbox must render bulk note-to-task previews");
assert.ok(!appText.includes("sidebar-note-filter-row"), "Notes sidebar must not duplicate List chips below search");
assert.ok(!appText.includes("noteMetadataFilter"), "Notes sidebar must not keep removed duplicate metadata chip state");
assert.ok(!appText.includes("planner-smart-list-row"), "Today page must not show distracting Smart List chips");
assert.ok(!stylesText.includes("planner-smart-list-chip"), "Smart List chip styling must not remain in the Today UI CSS");
assert.ok(!bridgeText.includes("normal project sidebar"), "Planner List descriptions must not say Lists are hidden from Projects");
assert.ok(!proxyText.includes("normal project sidebar"), "Realtime Planner List descriptions must not say Lists are hidden from Projects");
assert.ok(
  /const renderBacklogOpenList = \(\) => \{[\s\S]*?<div className="daily-backlog-table">[\s\S]*?renderBacklogRows\(openItems\)[\s\S]*?\};/.test(appText),
  "Backlog open items must stay flat instead of grouped by category headings"
);

assert.ok(preloadText.includes("createPlannerList"), "preload must expose createPlannerList");
assert.ok(preloadText.includes("listPlannerSmartListItems"), "preload must expose Smart List items");
assert.ok(mainText.includes("openassist:create-planner-list"), "main must register create Planner List IPC");
assert.ok(mainText.includes("openassist:list-planner-smart-list-items"), "main must register Smart List IPC");

// --- July 2026 hardening: wrong category/list placement ---
const bridgeSourceText = fs.readFileSync(path.resolve("electron/openassistBridge.ts"), "utf8");

// List names match on whole words only ("work" must not match "workout").
assert.ok(bridgeSourceText.includes("candidatePadded.includes(wantedPadded)"), "list resolution must use whole-word containment");

// List inference from task text requires a placement marker, not word overlap.
assert.ok(
  /\(\?:for\|to\|in\|into\|under\|onto\|at\|my\)/.test(bridgeSourceText),
  "list inference must require placement intent markers"
);

// Custom categories get a fuzzy pass before the fixed Work/Personal aliases.
assert.ok(
  /Fuzzy pass against the user's REAL categories/.test(bridgeSourceText),
  "category resolution must fuzzy-match real categories before aliases"
);

// Trailing "#123" is an issue number, not a category heading.
assert.ok(
  /if \(!label \|\| \/\^\\d\+\$\/\.test\(label\)\) return null;/.test(bridgeSourceText),
  "numeric trailing tags must not become categories"
);

// The voice fast-path extracts the list phrase out of the title.
assert.ok(
  bridgeSourceText.includes("if (listName) payload.listName = listName;"),
  "voice fast-path must extract listName instead of leaving it in the title"
);

console.log("Planner organization verification passed.");
