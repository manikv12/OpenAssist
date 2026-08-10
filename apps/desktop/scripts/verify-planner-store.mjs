import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import {
  PlannerStore,
  plannerCompletionTimestamp,
  plannerDocumentSchemaVersion
} from "../dist-electron/plannerStore.js";

const completedAt = "2026-08-08T14:30:00.000Z";
assert.equal(plannerCompletionTimestamp({ nextCompleted: false, existingCompletedAt: completedAt }), null);
assert.equal(plannerCompletionTimestamp({ nextCompleted: true, now: completedAt }), completedAt);
assert.equal(plannerCompletionTimestamp({
  nextCompleted: true,
  previouslyCompleted: true,
  existingCompletedAt: completedAt,
  now: "2026-08-09T14:30:00.000Z"
}), completedAt, "editing a completed task must preserve its audit time");
assert.equal(plannerCompletionTimestamp({
  nextCompleted: true,
  previouslyCompleted: true,
  now: "2026-08-09T14:30:00.000Z"
}), null, "legacy completed tasks must not receive an invented completion time");

const desktopRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bridgeSource = fs.readFileSync(path.join(desktopRoot, "electron", "openassistBridge.ts"), "utf8");
const rendererSource = fs.readFileSync(path.join(desktopRoot, "src", "App.tsx"), "utf8");
assert.match(bridgeSource, /completedAt:\s*item\.completedAt\s*\?\?\s*null/, "completion time must be persisted in planner metadata and sync output");
assert.match(bridgeSource, /completedAt:\s*normalizeReminderDate\(metadata\.completedAt\)/, "completion time must be restored from planner metadata");
assert.match(rendererSource, /showDoneBacklog\s*\|\|\s*backlogQueryActive/, "backlog search must reveal matching completed tasks");
assert.match(rendererSource, /Completed \$\{completedLabel\}/, "completed backlog tasks must show their completion time");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-planner-store-"));
const filesRoot = path.join(root, "files");
const journalRoot = path.join(root, "journal");
const snapshots = [];

function itemBlock(item) {
  return [
    `<!-- oa-daily-item ${JSON.stringify(item)} -->`,
    `- [${item.checked ? "x" : " "}] ${item.title}`,
    ...(item.details ? ["  - Details:", `    ${item.details}`] : []),
    ...(item.steps?.length
      ? ["  - Steps:", ...item.steps.map((step) => `    - [${step.checked ? "x" : " "}] ${step.text}`)]
      : []),
    "<!-- /oa-daily-item -->"
  ].join("\n");
}

const blockPattern = /<!--\s*oa-daily-item\s+([^\n]*?)\s*-->[\s\S]*?<!--\s*\/oa-daily-item\s*-->/g;

function parse(containerID, markdown) {
  const items = [];
  const issues = [];
  const seen = new Set();
  let match;
  while ((match = blockPattern.exec(markdown))) {
    try {
      const item = JSON.parse(match[1]);
      items.push(item);
      if (!item.id) issues.push({ code: "missing_item_id", message: "Missing item ID." });
      else if (seen.has(item.id)) issues.push({ code: "duplicate_item_id", message: "Duplicate item ID." });
      seen.add(item.id);
    } catch {
      issues.push({ code: "invalid_item_metadata", message: "Invalid item metadata." });
    }
  }
  blockPattern.lastIndex = 0;
  const scaffold = markdown.replace(blockPattern, "").replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";
  return { scaffold, items, issues };
}

function render(containerID, scaffold, items) {
  const marker = `<!-- oa-planner-document ${JSON.stringify({ schemaVersion: plannerDocumentSchemaVersion, containerID })} -->`;
  const cleanScaffold = scaffold
    .replace(/^\s*<!--\s*oa-planner-document[^\n]*-->\s*$/gm, "")
    .replace(/\n{3,}/g, "\n\n")
    .trimEnd();
  return `${cleanScaffold}\n\n${marker}\n\n${items.map(itemBlock).join("\n")}\n`;
}

const adapter = {
  filePath: (containerID) => path.join(filesRoot, `${containerID}.md`),
  read: (containerID) => fs.existsSync(adapter.filePath(containerID)) ? fs.readFileSync(adapter.filePath(containerID), "utf8") : "",
  parse,
  render,
  canonicalize: (containerID, markdown) => render(containerID, parse(containerID, markdown).scaffold, parse(containerID, markdown).items),
  snapshot: (containerID, markdown) => snapshots.push({ containerID, markdown }),
  onCommitted: () => {}
};

fs.mkdirSync(filesRoot, { recursive: true });
const first = { id: "item-a", title: "Duplicate title", details: "A", checked: false, steps: [{ id: "step-a", text: "First", checked: false }] };
const second = { id: "item-b", title: "Duplicate title", details: "B", checked: false, steps: [{ id: "step-b", text: "Second", checked: false }] };
fs.writeFileSync(adapter.filePath("day-a"), render("day-a", "# Day A\n", [first, second]));
fs.writeFileSync(adapter.filePath("day-b"), render("day-b", "# Day B\n", []));

const store = new PlannerStore(adapter, journalRoot);
let document = store.load("day-a");
assert.deepEqual(document.items.map((item) => item.id), ["item-a", "item-b"], "duplicate titles must remain separate by ID");

const renameResult = store.applyOperations({
  mutationID: "rename-once",
  containerID: "day-a",
  baseRevision: document.revision,
  operations: [
    { type: "update_item", itemID: "item-b", path: "title", previousValue: "Duplicate title", value: "Renamed item" },
    { type: "update_step", itemID: "item-b", stepID: "step-b", path: "text", previousValue: "Second", value: "Renamed step" }
  ]
});
assert.equal(renameResult.status, "applied");
assert.equal(renameResult.document.items[0].title, "Duplicate title");
assert.equal(renameResult.document.items[1].title, "Renamed item");
assert.equal(renameResult.document.items[1].steps[0].id, "step-b", "step rename must preserve its ID");
assert.equal(renameResult.document.items[1].steps[0].text, "Renamed step");
const retry = store.applyOperations({
  mutationID: "rename-once",
  containerID: "day-a",
  baseRevision: document.revision,
  operations: []
});
assert.deepEqual(retry, renameResult, "a mutation retry must return the original result");

document = store.load("day-a");
const baseMarkdown = document.markdown;
const externalItems = structuredClone(document.items);
externalItems[0].title = "External title";
const external = store.applyEditorMutation({
  mutationID: randomUUID(),
  containerID: "day-a",
  baseRevision: document.revision,
  baseMarkdown,
  markdown: render("day-a", document.scaffold, externalItems)
});
assert.equal(external.status, "applied");
const mineItems = structuredClone(document.items);
mineItems[0].details = "My details";
const merged = store.applyEditorMutation({
  mutationID: randomUUID(),
  containerID: "day-a",
  baseRevision: document.revision,
  baseMarkdown,
  markdown: render("day-a", document.scaffold, mineItems)
});
assert.equal(merged.status, "applied", "different fields must merge automatically");
assert.equal(merged.document.items[0].title, "External title");
assert.equal(merged.document.items[0].details, "My details");

document = store.load("day-a");
const conflictBase = document.markdown;
const newerItems = structuredClone(document.items);
newerItems[0].title = "Newer title";
assert.equal(store.applyEditorMutation({
  mutationID: randomUUID(), containerID: "day-a", baseRevision: document.revision,
  baseMarkdown: conflictBase, markdown: render("day-a", document.scaffold, newerItems)
}).status, "applied");
const conflictingItems = structuredClone(document.items);
conflictingItems[0].title = "My other title";
const conflict = store.applyEditorMutation({
  mutationID: randomUUID(), containerID: "day-a", baseRevision: document.revision,
  baseMarkdown: conflictBase, markdown: render("day-a", document.scaffold, conflictingItems)
});
assert.equal(conflict.status, "conflict", "same-field edits must require review");
assert.ok(conflict.conflicts.some((entry) => entry.path.endsWith(".title")));

const beforeInvalid = fs.readFileSync(adapter.filePath("day-a"), "utf8");
const invalid = store.applyOperations({
  mutationID: randomUUID(), containerID: "day-a", baseRevision: store.load("day-a").revision,
  operations: [{ type: "create_item", item: { id: "", title: "Invalid", steps: [] } }]
});
assert.equal(invalid.status, "invalid");
assert.equal(fs.readFileSync(adapter.filePath("day-a"), "utf8"), beforeInvalid, "invalid input must not change the file");

const source = store.load("day-a");
const target = store.load("day-b");
const movedItem = source.items.find((item) => item.id === "item-b");
const moveResult = store.applyOperations({
  mutationID: "move-item-b",
  containerID: "day-b",
  baseRevision: target.revision,
  baseRevisions: { "day-a": source.revision, "day-b": target.revision },
  operations: [{
    type: "move_item",
    itemID: movedItem.id,
    fromContainerID: "day-a",
    toContainerID: "day-b",
    previousItem: movedItem,
    item: { ...movedItem, dayID: "day-b" }
  }]
});
assert.equal(moveResult.status, "applied");
assert.equal(store.load("day-a").items.some((item) => item.id === "item-b"), false);
assert.equal(store.load("day-b").items.filter((item) => item.id === "item-b").length, 1, "a committed move must leave exactly one item");

const beforeStepMoveA = store.load("day-a");
const beforeStepMoveB = store.load("day-b");
const stepToMove = beforeStepMoveB.items.find((item) => item.id === "item-b").steps[0];
const stepMove = store.applyOperations({
  mutationID: randomUUID(),
  containerID: "day-a",
  baseRevision: beforeStepMoveA.revision,
  baseRevisions: { "day-a": beforeStepMoveA.revision, "day-b": beforeStepMoveB.revision },
  operations: [{
    type: "move_step",
    stepID: stepToMove.id,
    fromContainerID: "day-b",
    fromItemID: "item-b",
    toContainerID: "day-a",
    toItemID: "item-a",
    previousStep: stepToMove
  }]
});
assert.equal(stepMove.status, "applied");
assert.equal(store.load("day-b").items[0].steps.length, 0);
assert.deepEqual(store.load("day-a").items[0].steps.map((step) => step.id), ["step-a", "step-b"]);

const deleteBase = store.load("day-a");
const deleteItem = structuredClone(deleteBase.items[0]);
assert.equal(store.applyOperations({
  mutationID: randomUUID(), containerID: "day-a", baseRevision: deleteBase.revision,
  operations: [{
    type: "update_item", itemID: deleteItem.id, path: "details",
    previousValue: deleteItem.details, value: "Changed elsewhere"
  }]
}).status, "applied");
const deleteConflict = store.applyOperations({
  mutationID: randomUUID(), containerID: "day-a", baseRevision: deleteBase.revision,
  operations: [{ type: "delete_item", itemID: deleteItem.id, previousItem: deleteItem }]
});
assert.equal(deleteConflict.status, "conflict", "delete-versus-edit must require review");
assert.equal(store.load("day-a").items.some((item) => item.id === deleteItem.id), true);

const staleMoveBase = store.load("day-b");
const staleMoveItem = structuredClone(staleMoveBase.items[0]);
assert.equal(store.applyOperations({
  mutationID: randomUUID(), containerID: "day-b", baseRevision: staleMoveBase.revision,
  operations: [{
    type: "update_item", itemID: staleMoveItem.id, path: "details",
    previousValue: staleMoveItem.details, value: "Newer source details"
  }]
}).status, "applied");
const staleMove = store.applyOperations({
  mutationID: randomUUID(), containerID: "day-a", baseRevision: store.load("day-a").revision,
  operations: [{
    type: "move_item", itemID: staleMoveItem.id,
    fromContainerID: "day-b", toContainerID: "day-a",
    previousItem: staleMoveItem, item: { ...staleMoveItem, dayID: "day-a" }
  }]
});
assert.equal(staleMove.status, "applied", "move-versus-unrelated edit must merge");
assert.equal(store.load("day-a").items.find((item) => item.id === staleMoveItem.id).details, "Newer source details");

const moveConflictBase = store.load("day-a");
const moveConflictItem = structuredClone(moveConflictBase.items.find((item) => item.id === "item-b"));
assert.equal(store.applyOperations({
  mutationID: randomUUID(), containerID: "day-a", baseRevision: moveConflictBase.revision,
  operations: [{
    type: "update_item", itemID: moveConflictItem.id, path: "title",
    previousValue: moveConflictItem.title, value: "Newer source title"
  }]
}).status, "applied");
const moveConflictResult = store.applyOperations({
  mutationID: randomUUID(), containerID: "day-b", baseRevision: store.load("day-b").revision,
  operations: [{
    type: "move_item", itemID: moveConflictItem.id,
    fromContainerID: "day-a", toContainerID: "day-b",
    previousItem: moveConflictItem,
    item: { ...moveConflictItem, dayID: "day-b", title: "My source title" }
  }]
});
assert.equal(moveConflictResult.status, "conflict", "move-versus-same-field edit must require review");
assert.equal(store.load("day-a").items.some((item) => item.id === moveConflictItem.id), true);

function verifyMoveWriteFailureRollback(failingContainerID) {
  const beforeA = store.load("day-a");
  const beforeB = store.load("day-b");
  const item = structuredClone(beforeA.items.find((candidate) => candidate.id === "item-b"));
  assert.ok(item, "the rollback fixture must start in day-a");
  const originalRename = fs.renameSync;
  let injected = false;
  fs.renameSync = (source, destination) => {
    if (!injected && path.resolve(String(destination)) === path.resolve(adapter.filePath(failingContainerID))) {
      injected = true;
      throw new Error(`Injected ${failingContainerID} write failure`);
    }
    return originalRename(source, destination);
  };
  let result;
  try {
    result = store.applyOperations({
      mutationID: randomUUID(),
      containerID: "day-b",
      baseRevision: beforeB.revision,
      baseRevisions: { "day-a": beforeA.revision, "day-b": beforeB.revision },
      operations: [{
        type: "move_item", itemID: item.id,
        fromContainerID: "day-a", toContainerID: "day-b",
        previousItem: item, item: { ...item, dayID: "day-b" }
      }]
    });
  } finally {
    fs.renameSync = originalRename;
  }
  assert.equal(result.status, "failed", `${failingContainerID} write failure must fail the transaction`);
  const locations = [
    ...store.load("day-a").items.filter((candidate) => candidate.id === item.id).map(() => "day-a"),
    ...store.load("day-b").items.filter((candidate) => candidate.id === item.id).map(() => "day-b")
  ];
  assert.deepEqual(locations, ["day-a"], `${failingContainerID} failure must immediately restore exactly one source item`);
}

verifyMoveWriteFailureRollback("day-a");
verifyMoveWriteFailureRollback("day-b");

// Simulate a crash after the first side of a prepared transaction was written.
const recoveryBeforeA = fs.readFileSync(adapter.filePath("day-a"), "utf8");
const recoveryBeforeB = fs.readFileSync(adapter.filePath("day-b"), "utf8");
const recoveryAfterA = recoveryBeforeA.replace("# Day A", "# Damaged partial move");
fs.mkdirSync(journalRoot, { recursive: true });
fs.writeFileSync(path.join(journalRoot, "crash.json"), JSON.stringify({
  transactionID: "crash",
  state: "prepared",
  writes: [
    { containerID: "day-a", filePath: adapter.filePath("day-a"), before: recoveryBeforeA, after: recoveryAfterA },
    { containerID: "day-b", filePath: adapter.filePath("day-b"), before: recoveryBeforeB, after: recoveryBeforeB }
  ]
}));
fs.writeFileSync(adapter.filePath("day-a"), recoveryAfterA);
new PlannerStore(adapter, journalRoot);
assert.equal(fs.readFileSync(adapter.filePath("day-a"), "utf8"), recoveryBeforeA, "prepared transaction recovery must roll back a partial write");
assert.equal(fs.existsSync(path.join(journalRoot, "crash.json")), false);

for (let index = 0; index < 40; index += 1) {
  const current = store.load("day-a");
  const currentItem = current.items.find((item) => item.id === "item-b");
  const result = store.applyOperations({
    mutationID: randomUUID(), containerID: "day-a", baseRevision: current.revision,
    operations: [{
      type: "update_item", itemID: "item-b", path: "details",
      previousValue: currentItem.details, value: `round-${index}`
    }]
  });
  assert.equal(result.status, "applied");
  assert.equal(store.load("day-a").items.some((item) => item.id === "item-b"), true);
}

assert.ok(snapshots.length > 0, "committed writes must keep recovery snapshots");
fs.rmSync(root, { recursive: true, force: true });
console.log("Planner store verification passed.");
