import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";
import { Editor } from "@tiptap/core";
import { Markdown } from "@tiptap/markdown";
import StarterKit from "@tiptap/starter-kit";
import { TaskList } from "@tiptap/extension-task-list";
import { TaskItem } from "@tiptap/extension-task-item";
import { Fragment as ProseMirrorFragment } from "prosemirror-model";
import { EditorState, Plugin, PluginKey, TextSelection } from "prosemirror-state";

const appPath = path.resolve("src/App.tsx");
const bridgePath = path.resolve("electron/openassistBridge.ts");
const appSource = fs.readFileSync(appPath, "utf8");
const bridgeSource = fs.readFileSync(bridgePath, "utf8");

function sourceFile(source, fileName, scriptKind) {
  return ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true, scriptKind);
}

function functionDeclaration(source, fileName, name, scriptKind = ts.ScriptKind.TS) {
  const parsed = sourceFile(source, fileName, scriptKind);
  const declaration = parsed.statements.find((statement) =>
    ts.isFunctionDeclaration(statement) && statement.name?.text === name
  );
  assert.ok(declaration, `${name} must exist in ${fileName}`);
  return source.slice(declaration.getStart(parsed), declaration.end);
}

function variableStatement(source, fileName, name, scriptKind = ts.ScriptKind.TS) {
  const parsed = sourceFile(source, fileName, scriptKind);
  const statement = parsed.statements.find((candidate) =>
    ts.isVariableStatement(candidate)
    && candidate.declarationList.declarations.some((declaration) =>
      ts.isIdentifier(declaration.name) && declaration.name.text === name
    )
  );
  assert.ok(statement, `${name} must exist in ${fileName}`);
  return source.slice(statement.getStart(parsed), statement.end);
}

assert.doesNotMatch(
  functionDeclaration(appSource, "App.tsx", "buildVisiblePlannerDays", ts.ScriptKind.TSX),
  /\bnoteDetail\b/,
  "the sidebar day helper must use only its arguments; planner note state belongs in PlannerView"
);

async function executableModule(source, label) {
  const compiled = ts.transpileModule(source, {
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.ES2022
    },
    fileName: label,
    reportDiagnostics: true
  });
  const errors = (compiled.diagnostics ?? []).filter((diagnostic) =>
    diagnostic.category === ts.DiagnosticCategory.Error
  );
  assert.equal(errors.length, 0, `${label} must transpile without syntax errors`);
  return import(`data:text/javascript;base64,${Buffer.from(compiled.outputText).toString("base64")}`);
}

// Execute the exact planner controller helpers from App.tsx, then run them
// against real headless TipTap editors. This catches schema and transaction
// mistakes that a command spy cannot reproduce.
globalThis.__plannerEditorIntegrityDeps = {
  Plugin,
  PluginKey,
  ProseMirrorFragment,
  TextSelection
};
const keyboardModule = await executableModule(`
  const {
    Plugin,
    PluginKey,
    ProseMirrorFragment,
    TextSelection
  } = globalThis.__plannerEditorIntegrityDeps;
  const Extension = { create: (configuration) => configuration };
  ${functionDeclaration(appSource, "App.tsx", "plannerListContext", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "activePlannerListItemName", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "isPlannerOwnedTaskContext", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "isPlannerStepsLabel", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "plannerCheckboxMarker", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "plannerCheckboxMarkerDetails", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "isPlannerStepsListItem", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "plannerParagraphContentAfterMarker", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "plannerTasksFromMalformedListItem", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "plannerStepsItemWithTasks", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "selectPlannerTask", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "insertPlannerStepAtLabel", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "convertPlannerSiblingToStep", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "convertPlannerBulletMarker", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "hasPlannerTaskItemAncestor", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "findPlannerStepsSiblingNormalization", ts.ScriptKind.TSX)}
  ${variableStatement(appSource, "App.tsx", "openAssistPlannerListControllerKey", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "normalizePlannerStepsSiblings", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "removeEmptyPlannerStep", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "removeEmptyPlannerSibling", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "applyPlannerChecklistCommand", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "handlePlannerBackspace", ts.ScriptKind.TSX)}
  ${variableStatement(appSource, "App.tsx", "OpenAssistPlannerListController", ts.ScriptKind.TSX)}
  export {
    plannerListContext,
    activePlannerListItemName,
    isPlannerOwnedTaskContext,
    isPlannerStepsLabel,
    plannerCheckboxMarker,
    plannerCheckboxMarkerDetails,
    isPlannerStepsListItem,
    plannerParagraphContentAfterMarker,
    plannerTasksFromMalformedListItem,
    plannerStepsItemWithTasks,
    selectPlannerTask,
    insertPlannerStepAtLabel,
    convertPlannerSiblingToStep,
    convertPlannerBulletMarker,
    hasPlannerTaskItemAncestor,
    findPlannerStepsSiblingNormalization,
    openAssistPlannerListControllerKey,
    normalizePlannerStepsSiblings,
    removeEmptyPlannerStep,
    removeEmptyPlannerSibling,
    applyPlannerChecklistCommand,
    handlePlannerBackspace,
    OpenAssistPlannerListController
  };
`, "planner-list-controller-test.ts");
delete globalThis.__plannerEditorIntegrityDeps;

const plannerEditors = [];

function plannerEditor(markdown) {
  const editor = new Editor({
    content: markdown,
    contentType: "markdown",
    extensions: [StarterKit, Markdown, TaskList, TaskItem.configure({ nested: true })]
  });
  plannerEditors.push(editor);
  return editor;
}

function plannerControllerState(editor, enabled = true) {
  const plugins = keyboardModule.OpenAssistPlannerListController.addProseMirrorPlugins.call({
    options: { enabled }
  });
  return EditorState.create({
    schema: editor.schema,
    doc: editor.state.doc,
    plugins
  });
}

function applyDocumentReplacement(state, json, uiEvent) {
  const replacement = state.schema.nodeFromJSON(json);
  const transaction = state.tr
    .replaceWith(0, state.doc.content.size, replacement.content)
    .setMeta("uiEvent", uiEvent);
  return state.applyTransaction(transaction);
}

function stateEditor(state) {
  return { state };
}

function plannerShortcuts(editor, enabled = true) {
  return keyboardModule.OpenAssistPlannerListController.addKeyboardShortcuts.call({
    editor,
    options: { enabled }
  });
}

function textPosition(editor, text, { occurrence = 0, offset = text.length } = {}) {
  let matchingIndex = 0;
  let result = -1;
  editor.state.doc.descendants((node, position) => {
    if (!node.isText || typeof node.text !== "string") return result < 0;
    let searchFrom = 0;
    while (result < 0) {
      const matchIndex = node.text.indexOf(text, searchFrom);
      if (matchIndex < 0) break;
      if (matchingIndex === occurrence) {
        result = position + matchIndex + offset;
        return false;
      }
      matchingIndex += 1;
      searchFrom = matchIndex + text.length;
    }
    return result < 0;
  });
  assert.notEqual(result, -1, `expected to find text ${JSON.stringify(text)}`);
  return result;
}

function setCursor(editor, text, options) {
  assert.equal(editor.commands.setTextSelection(textPosition(editor, text, options)), true);
}

function setTextRange(editor, text, fromOffset, toOffset) {
  const start = textPosition(editor, text, { offset: 0 });
  assert.equal(editor.commands.setTextSelection({
    from: start + fromOffset,
    to: start + toOffset
  }), true);
}

function nodesNamed(node, name, result = []) {
  if (node.type?.name === name || node.type === name) result.push(node);
  for (const child of node.content?.content ?? node.content ?? []) {
    nodesNamed(child, name, result);
  }
  return result;
}

function nodeWithFirstParagraph(editor, name, text) {
  return nodesNamed(editor.state.doc, name).find((node) =>
    node.firstChild?.type.name === "paragraph" && node.firstChild.textContent === text
  ) ?? null;
}

function directChildrenNamed(node, name) {
  return Array.from({ length: node?.childCount ?? 0 }, (_, index) => node.child(index))
    .filter((child) => child.type.name === name);
}

function taskTexts(taskList) {
  return Array.from({ length: taskList?.childCount ?? 0 }, (_, index) =>
    taskList.child(index).firstChild?.textContent ?? ""
  );
}

function typeLiteral(editor, value) {
  assert.equal(editor.commands.insertContent({ type: "text", text: value }), true);
}

assert.equal(
  keyboardModule.OpenAssistPlannerListController.priority,
  1_000,
  "planner list protection must run before TipTap's default list keymap"
);
assert.equal(keyboardModule.isPlannerStepsLabel("Steps:-"), true, "legacy Steps:- labels must be recognized");
assert.equal(keyboardModule.isPlannerStepsLabel("Steps:"), true, "canonical Steps: labels must be recognized");
assert.deepEqual(
  keyboardModule.plannerCheckboxMarker("[x] Finished step"),
  { checked: true, text: "Finished step" },
  "literal checked markers must be recoverable"
);

const legacyStepsEditor = plannerEditor("- [ ] Parent\n  - Steps:-");
setCursor(legacyStepsEditor, "Steps:-");
assert.deepEqual(
  {
    itemName: keyboardModule.plannerListContext(legacyStepsEditor)?.itemName,
    insidePlannerTask: keyboardModule.plannerListContext(legacyStepsEditor)?.insidePlannerTask,
    atEnd: keyboardModule.plannerListContext(legacyStepsEditor)?.atEnd
  },
  { itemName: "listItem", insidePlannerTask: true, atEnd: true },
  "the controller must recognize a nested planner Steps label"
);
assert.equal(
  plannerShortcuts(legacyStepsEditor).Enter(),
  true,
  "Enter on Steps:- must create a checkbox instead of another bullet"
);
const normalizedStepsItem = nodeWithFirstParagraph(legacyStepsEditor, "listItem", "Steps:");
assert.ok(normalizedStepsItem, "Enter must normalize Steps:- to Steps:");
assert.deepEqual(
  directChildrenNamed(normalizedStepsItem, "taskList").map(taskTexts),
  [[""]],
  "Enter must place one empty checkbox under the Steps label"
);

const existingStepsEditor = plannerEditor("- [ ] Parent\n  - Steps:\n    - [ ] Existing step");
setCursor(existingStepsEditor, "Steps:");
assert.equal(plannerShortcuts(existingStepsEditor).Enter(), true);
const existingStepsItem = nodeWithFirstParagraph(existingStepsEditor, "listItem", "Steps:");
assert.deepEqual(
  directChildrenNamed(existingStepsItem, "taskList").map(taskTexts),
  [["", "Existing step"]],
  "Enter must add to the Steps task list without replacing its existing checkboxes"
);

// Reproduce the old broken path: TipTap's default Enter splits the Steps
// bullet, then plain text input leaves a literal [ ] marker. The controller
// must fold that item and any carried child tasks into the owned task list.
const recoveredEnterEditor = plannerEditor(
  "- [ ] Parent\n  - Steps:\n    - [x] Existing carried step"
);
setCursor(recoveredEnterEditor, "Steps:");
assert.equal(recoveredEnterEditor.commands.splitListItem("listItem"), true);
typeLiteral(recoveredEnterEditor, "[ ] New step");
assert.equal(plannerShortcuts(recoveredEnterEditor).Enter(), true);
const recoveredEnterLabel = nodeWithFirstParagraph(recoveredEnterEditor, "listItem", "Steps:");
assert.equal(
  nodesNamed(recoveredEnterEditor.state.doc, "listItem").filter((node) =>
    node.firstChild?.textContent === "[ ] New step"
  ).length,
  0,
  "recovery must remove the raw marker bullet"
);
assert.deepEqual(
  directChildrenNamed(recoveredEnterLabel, "taskList").map(taskTexts),
  [["New step", "", "Existing carried step"]],
  "Enter recovery must flatten the new step, next checkbox, and carried steps into one task list"
);

const recoveredSpaceEditor = plannerEditor("- [ ] Parent\n  - Steps:");
setCursor(recoveredSpaceEditor, "Steps:");
assert.equal(recoveredSpaceEditor.commands.splitListItem("listItem"), true);
typeLiteral(recoveredSpaceEditor, "[ ]");
assert.equal(
  plannerShortcuts(recoveredSpaceEditor).Space(),
  true,
  "Space after a literal [ ] marker must convert it to a real checkbox"
);
const recoveredSpaceLabel = nodeWithFirstParagraph(recoveredSpaceEditor, "listItem", "Steps:");
assert.deepEqual(
  directChildrenNamed(recoveredSpaceLabel, "taskList").map(taskTexts),
  [[""]],
  "Space conversion must keep one real empty task under Steps"
);

const selectedMarkerEditor = plannerEditor("- [ ] Parent\n  - Steps:");
setCursor(selectedMarkerEditor, "Steps:");
assert.equal(selectedMarkerEditor.commands.splitListItem("listItem"), true);
typeLiteral(selectedMarkerEditor, "[ ] Selected step");
setTextRange(selectedMarkerEditor, "[ ] Selected step", 4, 12);
const selectedMarkerBefore = selectedMarkerEditor.getJSON();
assert.equal(
  plannerShortcuts(selectedMarkerEditor).Enter(),
  false,
  "Enter with selected marker text must keep normal editing behavior"
);
assert.equal(
  plannerShortcuts(selectedMarkerEditor).Space(),
  false,
  "Space with selected marker text must keep normal editing behavior"
);
assert.deepEqual(
  selectedMarkerEditor.getJSON(),
  selectedMarkerBefore,
  "selected text must never be converted into a task"
);

const midLineMarkerEditor = plannerEditor("- [ ] Parent\n  - Steps:");
setCursor(midLineMarkerEditor, "Steps:");
assert.equal(midLineMarkerEditor.commands.splitListItem("listItem"), true);
typeLiteral(midLineMarkerEditor, "[ ] Mid-line step");
setCursor(midLineMarkerEditor, "[ ] Mid-line step", { offset: 7 });
const midLineMarkerBefore = midLineMarkerEditor.getJSON();
assert.equal(
  plannerShortcuts(midLineMarkerEditor).Enter(),
  false,
  "Enter in the middle of marker content must not convert it"
);
assert.equal(
  plannerShortcuts(midLineMarkerEditor).Space(),
  false,
  "Space in the middle of marker content must not convert it"
);
assert.deepEqual(
  midLineMarkerEditor.getJSON(),
  midLineMarkerBefore,
  "mid-line shortcuts must leave the malformed item untouched"
);

const markedContentEditor = plannerEditor("- [ ] Parent\n  - Steps:");
setCursor(markedContentEditor, "Steps:");
assert.equal(markedContentEditor.commands.splitListItem("listItem"), true);
assert.equal(markedContentEditor.commands.insertContent([
  { type: "text", text: "[ ] " },
  { type: "text", marks: [{ type: "bold" }], text: "Bold step" }
]), true);
assert.equal(
  plannerShortcuts(markedContentEditor).Space(),
  true,
  "a marker with formatted content must convert to a real checkbox"
);
const markedTask = nodeWithFirstParagraph(markedContentEditor, "taskItem", "Bold step");
assert.ok(markedTask, "formatted marker text must survive conversion");
assert.deepEqual(
  markedTask.firstChild.firstChild?.marks.map((mark) => mark.type.name),
  ["bold"],
  "marker conversion must preserve inline marks after the checkbox prefix"
);

const laterParagraphEditor = plannerEditor("Temporary");
assert.equal(laterParagraphEditor.commands.setContent({
  type: "doc",
  content: [{
    type: "taskList",
    content: [{
      type: "taskItem",
      attrs: { checked: false },
      content: [
        { type: "paragraph", content: [{ type: "text", text: "Parent" }] },
        {
          type: "bulletList",
          content: [
            {
              type: "listItem",
              content: [{ type: "paragraph", content: [{ type: "text", text: "Steps:" }] }]
            },
            {
              type: "listItem",
              content: [
                { type: "paragraph", content: [{ type: "text", text: "Explanation" }] },
                { type: "paragraph", content: [{ type: "text", text: "[ ] Later paragraph" }] }
              ]
            }
          ]
        }
      ]
    }]
  }]
}), true);
setCursor(laterParagraphEditor, "[ ] Later paragraph");
const laterParagraphBefore = laterParagraphEditor.getJSON();
assert.equal(
  keyboardModule.plannerListContext(laterParagraphEditor),
  null,
  "only the first paragraph of a list item may be treated as its marker"
);
assert.equal(plannerShortcuts(laterParagraphEditor).Enter(), false);
assert.equal(plannerShortcuts(laterParagraphEditor).Space(), false);
assert.deepEqual(
  laterParagraphEditor.getJSON(),
  laterParagraphBefore,
  "a marker-like later paragraph must never be converted"
);

const malformedNormalizationSource = plannerEditor([
  "- [ ] Parent",
  "  - Context before",
  "  - Steps:",
  "    - [x] Existing carried step",
  "  - Keep after",
  "- [ ] Other parent",
  "  - Other detail"
].join("\n"));
setCursor(malformedNormalizationSource, "Steps:");
assert.equal(malformedNormalizationSource.commands.splitListItem("listItem"), true);
typeLiteral(malformedNormalizationSource, "[ ] First pasted step");
assert.equal(malformedNormalizationSource.commands.splitListItem("listItem"), true);
typeLiteral(malformedNormalizationSource, "[x] Second pasted step");
assert.equal(
  nodesNamed(malformedNormalizationSource.state.doc, "listItem").filter((node) =>
    /^\[[ xX]\]/.test(node.firstChild?.textContent ?? "")
  ).length,
  2,
  "the fixture must contain the adjacent malformed bullets"
);

const pastedRepairSeed = plannerEditor("Paste target");
const pastedRepairResult = applyDocumentReplacement(
  plannerControllerState(pastedRepairSeed),
  malformedNormalizationSource.getJSON(),
  "paste"
);
assert.equal(
  pastedRepairResult.transactions.length,
  2,
  "a malformed planner paste must append exactly one normalization transaction"
);
const pastedRepairEditor = stateEditor(pastedRepairResult.state);
const pastedStepsItem = nodeWithFirstParagraph(pastedRepairEditor, "listItem", "Steps:");
assert.deepEqual(
  directChildrenNamed(pastedStepsItem, "taskList").map(taskTexts),
  [["First pasted step", "Second pasted step", "Existing carried step"]],
  "paste normalization must fold every adjacent marker and carried task into Steps"
);
for (const text of ["Context before", "Keep after", "Other parent", "Other detail"]) {
  assert.equal(
    pastedRepairEditor.state.doc.textContent.split(text).length - 1,
    1,
    `localized paste repair must preserve ${text}`
  );
}
assert.equal(
  nodesNamed(pastedRepairEditor.state.doc, "taskItem").filter((node) =>
    node.firstChild?.textContent === "Other parent"
  ).length,
  1,
  "localized repair must leave unrelated parent tasks structurally intact"
);

const programmaticRepairSeed = plannerEditor("Programmatic target");
const programmaticRepairResult = applyDocumentReplacement(
  plannerControllerState(programmaticRepairSeed),
  malformedNormalizationSource.getJSON(),
  "programmatic"
);
assert.equal(
  programmaticRepairResult.transactions.length,
  2,
  "a programmatic malformed planner update must append one normalization transaction"
);
const programmaticRepairEditor = stateEditor(programmaticRepairResult.state);
const programmaticStepsItem = nodeWithFirstParagraph(programmaticRepairEditor, "listItem", "Steps:");
assert.deepEqual(
  directChildrenNamed(programmaticStepsItem, "taskList").map(taskTexts),
  [["First pasted step", "Second pasted step", "Existing carried step"]],
  "programmatic document replacement must run the same Steps normalizer"
);

const ordinaryNoteSeed = plannerEditor("Ordinary note");
const ordinaryNoteResult = applyDocumentReplacement(
  plannerControllerState(ordinaryNoteSeed, false),
  malformedNormalizationSource.getJSON(),
  "paste"
);
assert.equal(
  ordinaryNoteResult.transactions.length,
  1,
  "ordinary notes must not append a planner normalization transaction"
);
const ordinaryNoteEditor = stateEditor(ordinaryNoteResult.state);
assert.equal(
  nodesNamed(ordinaryNoteEditor.state.doc, "listItem").filter((node) =>
    /^\[[ xX]\]/.test(node.firstChild?.textContent ?? "")
  ).length,
  2,
  "ordinary notes must not receive planner transaction normalization"
);

const unrelatedBulletSource = plannerEditor("- [ ] Parent\n  - Not steps:");
setCursor(unrelatedBulletSource, "Not steps:");
assert.equal(unrelatedBulletSource.commands.splitListItem("listItem"), true);
typeLiteral(unrelatedBulletSource, "[ ] Keep literal");
const unrelatedBulletSeed = plannerEditor("Planner target");
const unrelatedBulletResult = applyDocumentReplacement(
  plannerControllerState(unrelatedBulletSeed),
  unrelatedBulletSource.getJSON(),
  "paste"
);
assert.equal(
  unrelatedBulletResult.transactions.length,
  1,
  "an unrelated bullet marker must not append a normalization transaction"
);
const unrelatedBulletEditor = stateEditor(unrelatedBulletResult.state);
assert.equal(
  nodeWithFirstParagraph(unrelatedBulletEditor, "listItem", "[ ] Keep literal")?.firstChild?.textContent,
  "[ ] Keep literal",
  "planner normalization must not touch a marker after an unrelated bullet"
);

const recoveredBackspaceEditor = plannerEditor("- [ ] Parent\n  - Steps:");
setCursor(recoveredBackspaceEditor, "Steps:");
assert.equal(recoveredBackspaceEditor.commands.splitListItem("listItem"), true);
typeLiteral(recoveredBackspaceEditor, "[ ] Recovered step");
setCursor(recoveredBackspaceEditor, "[ ] Recovered step", { offset: 0 });
assert.equal(
  plannerShortcuts(recoveredBackspaceEditor).Backspace(),
  true,
  "Backspace at a broken marker must recover it instead of outdenting it"
);
const recoveredBackspaceLabel = nodeWithFirstParagraph(recoveredBackspaceEditor, "listItem", "Steps:");
assert.deepEqual(
  directChildrenNamed(recoveredBackspaceLabel, "taskList").map(taskTexts),
  [["Recovered step"]],
  "Backspace recovery must preserve the step text in a real checkbox"
);

const protectedTaskEditor = plannerEditor("- [ ] Parent\n  - Steps:\n    - [ ] Protected step");
setCursor(protectedTaskEditor, "Protected step", { offset: 0 });
const protectedTaskBefore = protectedTaskEditor.getJSON();
assert.equal(
  plannerShortcuts(protectedTaskEditor).Backspace(),
  true,
  "Backspace at the start of a nested planner checkbox must be consumed"
);
assert.deepEqual(
  protectedTaskEditor.getJSON(),
  protectedTaskBefore,
  "protected Backspace must not outdent or alter the checkbox"
);

const removableOnlyStepEditor = plannerEditor("- [ ] Parent\n  - Steps:");
setCursor(removableOnlyStepEditor, "Steps:");
assert.equal(plannerShortcuts(removableOnlyStepEditor).Enter(), true);
assert.equal(
  plannerShortcuts(removableOnlyStepEditor).Backspace(),
  true,
  "Backspace on the only empty planner checkbox must remove it"
);
const removableOnlyStepsLabel = nodeWithFirstParagraph(removableOnlyStepEditor, "listItem", "Steps:");
assert.deepEqual(
  directChildrenNamed(removableOnlyStepsLabel, "taskList"),
  [],
  "removing the only empty checkbox must keep Steps and remove its empty task list"
);

const removableLaterStepEditor = plannerEditor(
  "- [ ] Parent\n  - Steps:\n    - [ ] Existing step"
);
setCursor(removableLaterStepEditor, "Steps:");
assert.equal(plannerShortcuts(removableLaterStepEditor).Enter(), true);
assert.equal(
  plannerShortcuts(removableLaterStepEditor).Backspace(),
  true,
  "Backspace on a later empty planner checkbox must remove only that row"
);
const removableLaterStepsLabel = nodeWithFirstParagraph(removableLaterStepEditor, "listItem", "Steps:");
assert.deepEqual(
  directChildrenNamed(removableLaterStepsLabel, "taskList").map(taskTexts),
  [["Existing step"]],
  "removing an empty checkbox must preserve the other steps"
);

const slashChecklistEditor = plannerEditor("- [ ] Parent\n  - Steps:\n  - New slash step");
setCursor(slashChecklistEditor, "New slash step");
assert.equal(
  keyboardModule.applyPlannerChecklistCommand(slashChecklistEditor),
  true,
  "the planner checklist command must convert the bullet after Steps"
);
const slashChecklistLabel = nodeWithFirstParagraph(slashChecklistEditor, "listItem", "Steps:");
assert.deepEqual(
  directChildrenNamed(slashChecklistLabel, "taskList").map(taskTexts),
  [["New slash step"]],
  "the slash checklist path must use the same owned task list as Enter"
);

const existingChecklistEditor = plannerEditor("- [ ] Parent\n  - Steps:\n    - [ ] Existing step");
setCursor(existingChecklistEditor, "Existing step");
const existingChecklistBefore = existingChecklistEditor.getJSON();
assert.equal(
  keyboardModule.applyPlannerChecklistCommand(existingChecklistEditor),
  true,
  "the planner checklist command must recognize an existing step"
);
assert.deepEqual(
  existingChecklistEditor.getJSON(),
  existingChecklistBefore,
  "running checklist inside a real step must not toggle or outdent it"
);

const hierarchyEditor = plannerEditor("- [ ] First\n- [ ] Second");
setCursor(hierarchyEditor, "Second", { offset: 0 });
const hierarchyBefore = hierarchyEditor.getJSON();
assert.equal(plannerShortcuts(hierarchyEditor).Tab(), true, "Tab must indent the active task item");
assert.equal(
  nodesNamed(hierarchyEditor.state.doc, "taskList").length,
  2,
  "Tab must create a nested task list"
);
assert.equal(plannerShortcuts(hierarchyEditor)["Shift-Tab"](), true, "Shift-Tab must undo the explicit indent");
assert.deepEqual(hierarchyEditor.getJSON(), hierarchyBefore, "Tab then Shift-Tab must restore the task hierarchy");

const protectedStepEditor = plannerEditor("- [ ] Parent\n  - Steps:\n    - [ ] Protected step");
setCursor(protectedStepEditor, "Protected step", { offset: 0 });
const protectedStepBefore = protectedStepEditor.getJSON();
assert.equal(plannerShortcuts(protectedStepEditor).Tab(), true, "Tab inside Steps must be consumed");
assert.equal(plannerShortcuts(protectedStepEditor)["Shift-Tab"](), true, "Shift-Tab inside Steps must be consumed");
assert.deepEqual(
  protectedStepEditor.getJSON(),
  protectedStepBefore,
  "Tab and Shift-Tab must never move a step outside its planner item"
);

const disabledEditor = plannerEditor("- [ ] Parent\n  - Steps:-");
setCursor(disabledEditor, "Steps:-");
const disabledBefore = disabledEditor.getJSON();
const disabledKeys = plannerShortcuts(disabledEditor, false);
for (const key of ["Escape", "Enter", "Backspace", "Space", "Tab", "Shift-Tab"]) {
  assert.equal(disabledKeys[key](), false, `${key} must remain available when planner mode is disabled`);
}
assert.deepEqual(disabledEditor.getJSON(), disabledBefore, "disabled mode must not change the document");

const outsideListEditor = plannerEditor("Plain paragraph");
setCursor(outsideListEditor, "Plain paragraph");
const outsideKeys = plannerShortcuts(outsideListEditor);
assert.equal(outsideKeys.Escape(), false, "Escape outside a planner list must remain available to the app");
assert.equal(outsideKeys.Backspace(), false, "Backspace outside a planner list must remain normal");
assert.equal(outsideKeys.Tab(), false, "Tab outside a planner list must remain normal");

assert.match(
  appSource,
  /OpenAssistPlannerListController\.configure\(\{\s*enabled:\s*plannerSourceKind === "planner"\s*\}\)/,
  "the planner controller must be enabled only for planner surfaces"
);

for (const editor of plannerEditors) editor.destroy();

// Execute the exact bridge formatter helpers. Importing openassistBridge itself
// in Node would load Electron, so the verifier extracts only these pure helpers.
const bridgeHelperNames = [
  "cleanDailyText",
  "ensurePlannerSection",
  "isEmptyPlannerPlaceholderLine",
  "cleanPlannerSectionBody",
  "normalizePlannerStructuredTaskBoundaries",
  "cleanPlannerTaskSpacing",
  "plannerBlockSeparator",
  "appendToPlannerSection",
  "appendToPlannerSubsection"
];
const plannerMarkdown = await executableModule(`
  ${bridgeHelperNames.map((name) => functionDeclaration(bridgeSource, "openassistBridge.ts", name)).join("\n")}
  export { ${bridgeHelperNames.join(", ")} };
`, "planner-markdown-test.ts");

const unscopedBeforeCategory = plannerMarkdown.appendToPlannerSection(
  "# Planner\n\n## Tasks\n\n### Personal\n- [ ] Personal task\n",
  "Tasks",
  "- [ ] Unscoped task"
);
assert.ok(
  unscopedBeforeCategory.indexOf("- [ ] Unscoped task") < unscopedBeforeCategory.indexOf("### Personal"),
  "an unscoped task must stay before category headings instead of inheriting the last category"
);
assert.match(
  functionDeclaration(bridgeSource, "openassistBridge.ts", "migrateLegacyStructuredPlannerMetadata"),
  /order:\s*itemOrder/,
  "legacy migration must replace duplicate old order values with visible document order"
);

// Execute the bridge's editor round-trip parser with only its pure lookup
// dependencies stubbed. These fixtures protect the storage contract rather
// than merely checking what the editor renders.
const plannerRoundTrip = await executableModule(`
  ${functionDeclaration(bridgeSource, "openassistBridge.ts", "createDailyItemBlockPattern")}
  function parseStructuredDailyItem(dayID, rawJSON, block, order, line) {
    const metadata = JSON.parse(rawJSON);
    const visibleMarkdown = block
      .replace(/^\\s*<!--\\s*oa-daily-item[^\\n]*-->\\s*(?:\\n|$)/, "")
      .replace(/\\n?\\s*<!--\\s*\\/oa-daily-item\\s*-->\\s*$/, "");
    // Match the production parser's nested visible-Markdown parse. This is the
    // re-entrant call that used to reset a shared RegExp cursor forever.
    parseDailyItemsFromMarkdown(dayID, visibleMarkdown);
    return {
      id: metadata.id,
      dayID,
      title: visibleMarkdown.match(/^[-*]\\s+\\[[ xX]\\]\\s+(.+)$/m)?.[1] ?? metadata.id,
      checked: false,
      status: "todo",
      tags: [],
      scopeTags: [],
      detailsMarkdown: "",
      steps: [],
      links: [],
      order,
      line,
      structured: true
    };
  }
  const dailyItemLineNumber = () => 1;
  const plannerTaskSubheadingAtOffset = () => undefined;
  const normalizeDailyArea = (value) => cleanDailyText(value) || undefined;
  const cleanDailyTagLabel = (value) => cleanDailyText(value);
  const parseDailyTitleScope = (value) => ({ title: cleanDailyText(value), scopeTags: [] });
  const plannerListScopeTags = (value) => value;
  const projectIDFromScopeTags = () => undefined;
  const folderIDFromScopeTags = () => undefined;
  const resolveDailyProjectTitle = () => "";
  const resolveDailyFolderTitle = () => "";
  const areaFromScopeTags = () => undefined;
  const inferDailyArea = () => "Personal";
  const randomUUID = () => "generated-step-id";
  ${functionDeclaration(bridgeSource, "openassistBridge.ts", "cleanDailyText")}
  ${functionDeclaration(bridgeSource, "openassistBridge.ts", "parseDailyItemsFromMarkdown")}
  export { parseDailyItemsFromMarkdown };
`, "planner-round-trip-test.ts");

const sectionAwareItem = plannerRoundTrip.parseDailyItemsFromMarkdown("2026-01-02", [
  "## Tasks",
  "- [ ] Parent task",
  "  - Details:",
  "    Keep this detail.",
  "    -",
  "    - [x] Keep this checkbox in details",
  "  - Steps:-",
  "    - \\[ \\] Escaped step marker",
  "    - [x] Completed step",
  "  - Links:",
  "    - [Linked note](oa-note://open?id=example)"
].join("\n"))[0];
assert.ok(sectionAwareItem, "the section-aware planner fixture must parse one task");
assert.equal(
  sectionAwareItem.detailsMarkdown,
  "Keep this detail.\n- [x] Keep this checkbox in details",
  "Details must keep their own content without persisting an empty dash or absorbing Links"
);
assert.deepEqual(
  sectionAwareItem.steps.map(({ text, checked }) => ({ text, checked })),
  [
    { text: "Escaped step marker", checked: false },
    { text: "Completed step", checked: true }
  ],
  "real and escaped checkbox markers owned by Steps must parse as steps"
);

const legacyNestedItem = plannerRoundTrip.parseDailyItemsFromMarkdown("2026-01-02", [
  "## Tasks",
  "- [ ] Legacy task",
  "  - [ ] Direct nested checkbox",
  "  - Legacy detail"
].join("\n"))[0];
assert.deepEqual(
  legacyNestedItem.steps.map((step) => step.text),
  ["Direct nested checkbox"],
  "legacy direct nested checkboxes must remain steps"
);
assert.equal(legacyNestedItem.detailsMarkdown, "Legacy detail", "legacy unlabeled details must remain readable");

const reentrantStructuredItems = plannerRoundTrip.parseDailyItemsFromMarkdown("2026-01-02", [
  "## Tasks",
  "<!-- oa-daily-item {\"id\":\"first\"} -->",
  "- [ ] First structured task",
  "<!-- /oa-daily-item -->",
  "<!-- oa-daily-item {\"id\":\"second\"} -->",
  "- [ ] Second structured task",
  "<!-- /oa-daily-item -->"
].join("\n"));
assert.deepEqual(
  reentrantStructuredItems.map((item) => item.id),
  ["first", "second"],
  "nested structured-item parsing must advance instead of repeating the first item"
);

function structuredTask(id, title, details = "") {
  const detailBlock = details ? `\n  - Details:\n${details}` : "";
  return [
    `<!-- oa-daily-item {"id":"${id}"} -->`,
    `- [ ] ${title}${detailBlock}`,
    "<!-- /oa-daily-item -->"
  ].join("\n");
}

const firstTask = structuredTask("task-1", "First task");
const secondTask = structuredTask("task-2", "Second task");
const compactBoundary = `${firstTask}\n${secondTask}`;

// Planner Canvas parses the annotated source directly. Stable IDs stay inside
// custom nodes instead of being stripped and guessed again at save time.
const editorMarkdownModule = await executableModule(`
  function parseCalloutOpeningLine(line) {
    const match = line.trim().match(/^:::\\s*(decision|comment|next|warning|info|success|task)(?:\\s+(.*?))?\\s*$/i);
    return match ? { kind: match[1].toLowerCase() } : null;
  }
  ${functionDeclaration(appSource, "App.tsx", "normalizeCalloutContainerSpacing", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "normalizeEditorMarkdown", ts.ScriptKind.TSX)}
  ${functionDeclaration(appSource, "App.tsx", "plannerEditorMarkdown", ts.ScriptKind.TSX)}
  export { plannerEditorMarkdown };
`, "planner-editor-markdown-test.ts");

const projectedMarkdown = editorMarkdownModule.plannerEditorMarkdown(compactBoundary, "planner");
assert.equal(projectedMarkdown, compactBoundary, "planner Canvas must retain the annotated Markdown source");
assert.match(projectedMarkdown, /<!--\s*oa-daily-item/, "planner Canvas must keep item IDs");
assert.equal(
  editorMarkdownModule.plannerEditorMarkdown(compactBoundary, "note"),
  compactBoundary,
  "ordinary notes must not lose comments that happen to resemble planner metadata"
);

assert.match(appSource, /const OpenAssistPlannerDocument = TiptapNode\.create/, "planner document marker needs its own node");
assert.match(appSource, /const OpenAssistPlannerItem = TiptapNode\.create/, "planner items need their own node");
assert.match(appSource, /isolating:\s*true/, "planner item nodes must isolate their content");
assert.match(appSource, /draggable:\s*false/, "planner item nodes must not be split by dragging");
assert.match(appSource, /plannerStepID/, "planner steps must retain permanent IDs");
assert.match(appSource, /OpenAssistPlannerIdentity/, "new planner steps must receive IDs in the editor");
assert.match(
  appSource,
  /content:\s*plannerEditorMarkdown\(value,\s*plannerSourceKind\)/,
  "TipTap initial planner content must use the annotated planner source"
);
assert.match(
  appSource,
  /useRef\(plannerEditorMarkdown\(value,\s*plannerSourceKind\)\)/,
  "the editor comparison baseline must use the same annotated source"
);
assert.ok(
  [...appSource.matchAll(/plannerEditorMarkdown\(value,\s*plannerSourceKind\)/g)].length >= 4,
  "initial content and external-value synchronization must consistently use the planner projection"
);

assert.equal(
  plannerMarkdown.normalizePlannerStructuredTaskBoundaries(`${firstTask}\n\n\n${secondTask}`),
  compactBoundary,
  "structured planner tasks must have exactly one newline at their boundary"
);
assert.equal(
  plannerMarkdown.normalizePlannerStructuredTaskBoundaries(compactBoundary),
  compactBoundary,
  "structured task boundary normalization must be idempotent"
);

const sectionResult = plannerMarkdown.appendToPlannerSection(
  `# Planner\n\n## Tasks\n${firstTask}\n`,
  "Tasks",
  secondTask
);
assert.ok(
  sectionResult.includes(compactBoundary),
  "appending to a planner section must not create an empty row between structured tasks"
);

const subsectionResult = plannerMarkdown.appendToPlannerSubsection(
  `# Planner\n\n## Tasks\n\n### Work\n${firstTask}\n\n## Notes\nKeep this note.\n`,
  "Tasks",
  "Work",
  secondTask
);
assert.ok(
  subsectionResult.includes(`### Work\n${compactBoundary}`),
  "appending to an existing planner category must keep compact task boundaries"
);
assert.ok(subsectionResult.includes("## Notes\nKeep this note."), "content after Tasks must remain unchanged");

const detailLines = "    First detail paragraph.\n\n    Second detail paragraph.";
const detailedTask = structuredTask("task-3", "Task with details", detailLines);
const normalizedDetails = plannerMarkdown.normalizePlannerStructuredTaskBoundaries(
  `${detailedTask}\n\n${secondTask}`
);
assert.ok(
  normalizedDetails.includes(detailLines),
  "boundary cleanup must preserve intentional blank lines inside task details"
);
assert.ok(
  normalizedDetails.includes(`${detailedTask}\n${secondTask}`),
  "detail-bearing structured tasks must still use a compact outer boundary"
);

assert.equal(
  plannerMarkdown.plannerBlockSeparator(`${firstTask}\n`, secondTask),
  "",
  "already newline-terminated structured tasks need no additional separator"
);
assert.equal(
  plannerMarkdown.plannerBlockSeparator(firstTask, secondTask),
  "\n",
  "structured tasks without a trailing newline need exactly one"
);
assert.equal(
  plannerMarkdown.plannerBlockSeparator("A paragraph.\n", "Another paragraph."),
  "\n",
  "non-task blocks must retain a readable blank line"
);

console.log("Planner editor integrity verification passed.");
