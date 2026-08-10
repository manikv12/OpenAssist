import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const bridgePath = path.resolve("electron/openassistBridge.ts");
const storePath = path.resolve("electron/plannerStore.ts");
const preloadPath = path.resolve("electron/preload.ts");
const appPath = path.resolve("src/App.tsx");
const bridgeText = fs.readFileSync(bridgePath, "utf8");
const storeText = fs.readFileSync(storePath, "utf8");
const preloadText = fs.readFileSync(preloadPath, "utf8");
const appText = fs.readFileSync(appPath, "utf8");

function functionBody(source, name) {
  const start = source.indexOf(`function ${name}`);
  assert.ok(start >= 0, `${name} must exist`);
  const next = source.indexOf("\nfunction ", start + 1);
  return source.slice(start, next >= 0 ? next : source.length);
}

function assertIncludes(text, needle, label) {
  assert.ok(text.includes(needle), `${label} must include: ${needle}`);
}

function assertMissing(text, needle, label) {
  assert.equal(text.includes(needle), false, `${label} must not include: ${needle}`);
}

const itemUpsert = functionBody(bridgeText, "applyPlannerItemUpsert");
assertIncludes(itemUpsert, "plannerItemUpdateOperations", "item updates");
assertIncludes(itemUpsert, "plannerStore().applyOperations", "item updates");
assertIncludes(itemUpsert, 'type: "create_item"', "item creation");

const itemDelete = functionBody(bridgeText, "applyPlannerItemDelete");
assertIncludes(itemDelete, 'type: "delete_item"', "item deletion");
assertIncludes(itemDelete, "previousItem: item", "delete-versus-edit protection");

const updateOperations = functionBody(bridgeText, "plannerItemUpdateOperations");
for (const type of ["update_item", "create_step", "update_step", "delete_step", "reorder_steps"]) {
  assertIncludes(updateOperations, `type: "${type}"`, "field-level item operation builder");
}
assertIncludes(updateOperations, "previousValue", "same-field conflict detection");
assertIncludes(updateOperations, "previousStep", "step delete conflict detection");

const updateByText = functionBody(bridgeText, "updateDailyItemByText");
assertIncludes(updateByText, "locatePlannerTask(raw)", "natural-language task lookup");
assertIncludes(updateByText, "applyPlannerItemUpsert(sourceDayID, match, item)", "same-container update");
assertIncludes(updateByText, "applyPlannerMoveBatch(targetDayID", "cross-container update");
assertIncludes(updateByText, 'type: "move_item"', "cross-container update");

const locateTask = functionBody(bridgeText, "locatePlannerTask");
assertIncludes(locateTask, "candidate.item.id === itemID", "task locator converts exact IDs");
assertIncludes(locateTask, "matches more than one task", "task locator rejects ambiguity");

for (const name of ["upsertDailyItem", "upsertBacklogItem"]) {
  const body = functionBody(bridgeText, name);
  assertIncludes(body, "const existing = existingByID", `${name} ID-only updates`);
  assertMissing(body, "findSimilarDailyItem", `${name} title matching`);
  assertMissing(body, "mergedDuplicateDailyInput", `${name} fuzzy merge`);
}
assertMissing(bridgeText, "function findSimilarDailyItem", "title-based create reconciliation");
assertMissing(bridgeText, "function mergedDuplicateDailyInput", "title-based create reconciliation");

for (const name of ["moveDailyItemToBacklog", "scheduleBacklogItem"]) {
  const body = functionBody(bridgeText, name);
  assertIncludes(body, "applyPlannerMoveBatch", `${name} shared move path`);
  assertIncludes(body, 'type: "move_item"', `${name} typed move operation`);
}
assertIncludes(preloadText, "moveDailyItemToDay:", "renderer day-to-day move API");
assertIncludes(preloadText, 'openassist:move-daily-item-to-day', "renderer day-to-day move IPC");

const canvasMoveStart = appText.indexOf("const movePlannerTaskToDay");
assert.ok(canvasMoveStart >= 0, "Canvas task-ID move must exist");
const canvasMove = appText.slice(canvasMoveStart, appText.indexOf("const plannerContextMenuItems", canvasMoveStart));
assertIncludes(canvasMove, "onMovePlannerTaskToDay(plannerBaseDayID, item.id, pickedDayID)", "Canvas task-ID move");
assertIncludes(appText, "plannerContextMenuItems(plannerText || text, plannerTask)", "Canvas context task identity");
assertIncludes(appText, "plannerContextMenuItems(text, plannerTask)", "Markdown context task identity");

const rendererMoveStart = appText.lastIndexOf("const moveDailyItemToDay");
assert.ok(rendererMoveStart >= 0, "renderer shared move path must exist");
const rendererMove = appText.slice(rendererMoveStart, appText.indexOf("const scheduleBacklogItem", rendererMoveStart));
assertIncludes(rendererMove, "openAssistElectron?.moveDailyItemToDay", "renderer shared move path");
assertIncludes(rendererMove, "loadPlannerDay?.(dayID)", "renderer source refresh after move");

const saveMovedDraft = appText.slice(
  appText.indexOf("const saveMovedDraft"),
  appText.indexOf("const renderItemCard", appText.indexOf("const saveMovedDraft"))
);
assertIncludes(saveMovedDraft, "onMoveItemToDay?.(editDraft.dayID, editDraft.id, targetDayID)", "date picker task-ID move");
assertMissing(saveMovedDraft, "onUpsertItem", "date picker append-then-delete move");
assertMissing(saveMovedDraft, "onDeleteItem", "date picker append-then-delete move");

const moveBatch = functionBody(bridgeText, "applyPlannerMoveBatch");
assertIncludes(moveBatch, "baseRevisions", "move batch revision contract");
assertIncludes(moveBatch, "plannerStore().applyOperations", "move batch store path");
assertIncludes(moveBatch, "assertPlannerContainersWritable", "read-only migration guard");

assert.match(
  bridgeText,
  /request\.preview\.kind === "planner_move"[\s\S]*?type:\s*"move_item"[\s\S]*?applyPlannerMoveBatch\(/,
  "approved planner moves must use one typed transaction"
);
assert.match(
  bridgeText,
  /request\.preview\.kind === "planner_backlog_move"[\s\S]*?type:\s*"move_item"[\s\S]*?applyPlannerMoveBatch\(/,
  "approved backlog moves must use one typed transaction"
);
assert.match(
  bridgeText,
  /case "move_planner_item":[\s\S]*?moveDailyItemToDay\(/,
  "Live Voice planner moves must use the shared move path"
);
assert.match(
  bridgeText,
  /type === "moveDailyItemToDay"[\s\S]*?moveDailyItemToDay\(dayID, itemID, targetDayID\)/,
  "mobile planner moves must use the shared move path"
);

assertMissing(bridgeText, "appendMovedDailyItemToDay", "legacy append-then-delete move helper");
assertMissing(bridgeText, "appendMovedDailyItemToBacklog", "legacy append-then-delete move helper");
assertMissing(bridgeText, "preserveDailyStepIDsAfterEditorRoundTrip", "title-based step reconciliation");
assertMissing(bridgeText, "removePlannerTasksByText", "title-based task deletion");
assertMissing(preloadText, "savePlannerDay:", "renderer planner API");
assertMissing(appText, "openAssistElectron?.savePlannerDay", "renderer planner writes");

const macSyncTask = functionBody(bridgeText, "applyMacSyncPlannerTask");
assertIncludes(macSyncTask, "applyPlannerItemUpsert", "Mac sync item updates");
assertIncludes(macSyncTask, "applyPlannerMoveBatch", "Mac sync item moves");
assertMissing(macSyncTask, "replaceStructuredDailyItem", "Mac sync whole-document rewrite");

const macSyncDelete = functionBody(bridgeText, "applyMacSyncTombstone");
assertIncludes(macSyncDelete, "applyPlannerItemDelete", "Mac sync item deletes");
assertMissing(macSyncDelete, "removeStructuredDailyItem", "Mac sync delete rewrite");

const categoryRename = functionBody(bridgeText, "renamePlannerCategoryAreaReferences");
assertIncludes(categoryRename, "applyPlannerItemUpsert", "category rename item updates");
assertMissing(categoryRename, "replaceStructuredDailyItem", "category rename whole-document rewrite");

assertIncludes(storeText, "lockedContainers", "per-container write locks");
assertIncludes(storeText, "commitTransactionUnlocked", "multi-container transaction");
assertIncludes(storeText, 'state: "prepared"', "prepared transaction journal");
assertIncludes(storeText, 'state = "committed"', "committed transaction journal");
assertIncludes(storeText, "this.atomicWrite", "atomic temporary writes");
assertIncludes(storeText, "this.adapter.snapshot", "recovery snapshots");
assertIncludes(storeText, "this.mutationResults.get", "idempotent mutation IDs");

const saveDay = functionBody(bridgeText, "savePlannerDay");
const saveBacklog = functionBody(bridgeText, "savePlannerBacklog");
assertIncludes(saveDay, "plannerStore().applyEditorMutation", "planner day saves");
assertIncludes(saveBacklog, "plannerStore().applyEditorMutation", "backlog saves");
assertIncludes(saveDay, "plannerMarkdownForValidatedSave", "strict planner day saves");
assertIncludes(saveBacklog, "plannerMarkdownForValidatedSave", "strict backlog saves");

const sourceValidation = functionBody(bridgeText, "plannerSourceValidationIssues");
assertIncludes(sourceValidation, 'code: "missing_schema_marker"', "schema marker validation");
assertIncludes(sourceValidation, 'code: "missing_item_id"', "permanent item IDs");
assertIncludes(sourceValidation, 'code: "missing_step_id"', "permanent step IDs");

const migration = functionBody(bridgeText, "migratePlannerDocumentOnLoad");
assertIncludes(migration, "allowMissingMarker: true", "one-time legacy import");
assertIncludes(migration, "sameScaffold", "migration scaffold round trip");
assertIncludes(migration, "plannerMigrationWarnings.set", "read-only migration failure");

const sharedStore = functionBody(bridgeText, "plannerStore");
assertIncludes(sharedStore, "plannerMarkdownForValidatedSave", "no runtime legacy canonicalization");
assertMissing(sharedStore, "canonicalize: canonicalPlannerMarkdown", "runtime legacy fallback");

const editorIdentity = functionBody(bridgeText, "canonicalizeNewPlannerEditorItems");
assertIncludes(editorIdentity, "input.baseRevision", "stable identity seed for new Markdown tasks");
assertIncludes(editorIdentity, "plannerGeneratedID", "permanent IDs for new Markdown tasks");
assertIncludes(editorIdentity, "replacePlainDailyItemBlock", "canonical annotated task insertion");
assertMissing(editorIdentity, "findSimilarDailyItem", "new task identity must not use title matching");

const editorMutation = functionBody(bridgeText, "applyPlannerEditorMutation");
const conflictResolution = functionBody(bridgeText, "resolvePlannerEditorConflicts");
assertIncludes(editorMutation, "canonicalizeNewPlannerEditorItems", "editor validation identity assignment");
assertIncludes(conflictResolution, "canonicalizeNewPlannerEditorItems", "conflict resolution identity stability");

const legacyPlainMigration = functionBody(bridgeText, "macSyncNormalizePlannerMarkdown");
assertIncludes(legacyPlainMigration, "steps: item.steps.map", "unique migrated step IDs");
const legacyStructuredMigration = functionBody(bridgeText, "migrateLegacyStructuredPlannerMetadata");
assertIncludes(legacyStructuredMigration, "visibleItem?.steps.length", "visible legacy step preservation");
assertIncludes(legacyStructuredMigration, "macSyncLegacyPlannerItemID", "stable legacy step IDs");

for (const body of [itemUpsert, itemDelete, functionBody(bridgeText, "applyPlannerOperations")]) {
  assertIncludes(body, "assertPlannerContainersWritable", "all structured mutation paths are migration-safe");
}
assertIncludes(appText, "plannerMigrationWarning", "planner migration warning UI");
assertIncludes(appText, "readOnlyMessage={plannerMigrationWarning}", "read-only planner editor");
assertIncludes(appText, "backlogMigrationWarning", "read-only backlog UI");

console.log("Planner move safety verification passed.");
