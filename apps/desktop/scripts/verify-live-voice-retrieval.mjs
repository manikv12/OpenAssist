import assert from "node:assert/strict";
import { resolveKnowledgeInformation } from "../dist-electron/liveVoice/informationResolver.js";
import { LiveVoiceCoordinator } from "../dist-electron/liveVoice/coordinator.js";
import { LiveVoiceCapabilityRegistry } from "../dist-electron/liveVoice/capabilityRegistry.js";
import { __realtimeProtocolTestHooks } from "../dist-electron/realtimeProxy.js";

const notes = [
  {
    id: "project_note:project:openassist:retirement",
    title: "Wife's 401k Limits Note",
    projectID: "openassist",
    projectName: "OpenAssist",
    sourceLabel: "OpenAssist note",
    markdown: "# 401k and HSA\nThe note contains the 401k calculation and family HSA limit.",
    updatedAt: 300
  },
  {
    id: "project_note:project:openassist:launch",
    title: "Launch checklist",
    projectID: "openassist",
    projectName: "OpenAssist",
    sourceLabel: "OpenAssist note",
    markdown: "# Launch\nRecord the voice demo and publish the project page.",
    updatedAt: 200
  },
  {
    id: "project_note:project:other:retirement",
    title: "401k research",
    projectID: "other",
    projectName: "Other project",
    sourceLabel: "Other note",
    markdown: "A different retirement note.",
    updatedAt: 400
  }
];

const list = resolveKnowledgeInformation({ userIntent: "Check the notes inside OpenAssist." }, notes);
assert.equal(list.status, "selection_required");
assert.deepEqual(list.candidates.map((item) => item.title), ["Wife's 401k Limits Note", "Launch checklist"]);

const retirement = resolveKnowledgeInformation({ userIntent: "What did we write about 401k and HSA?" }, notes);
assert.equal(retirement.status, "resolved");
assert.equal(retirement.note.id, notes[0].id);
assert.match(retirement.note.markdown, /family HSA/i);

const selected = resolveKnowledgeInformation({
  userIntent: "Read the note you made before.",
  selectedNoteID: notes[1].id
}, notes);
assert.equal(selected.status, "resolved");
assert.equal(selected.note.id, notes[1].id, "selected-note context must be stable for follow-ups");

const duplicates = resolveKnowledgeInformation({ userIntent: "Read the budget note" }, [
  { id: "a", title: "Budget", projectID: "p", markdown: "Marketing budget", updatedAt: 2 },
  { id: "b", title: "Budget", projectID: "p", markdown: "Payroll budget", updatedAt: 1 }
]);
assert.equal(duplicates.status, "selection_required", "genuinely different duplicate titles require one choice");

const missing = resolveKnowledgeInformation({ userIntent: "Find the submarine warranty" }, notes);
assert.equal(missing.status, "not_found");

const enabledConfig = { knowledge: { enabled: true } };
const descriptors = __realtimeProtocolTestHooks.liveVoiceCapabilityDescriptors(() => enabledConfig);
const resolver = descriptors.find((descriptor) => descriptor.id === "knowledge_resolve_notes");
assert.ok(resolver, "the real capability registry must include coordinator-owned note resolution");
assert.equal(resolver.argumentBindings.userIntent.owner, "goal-derived");
assert.equal(resolver.argumentBindings.selectedNoteID.owner, "context-resource");
assert.equal(resolver.outputResources[0].resourceKind, "openassist_note");

const calls = [];
const coordinator = new LiveVoiceCoordinator({
  registry: new LiveVoiceCapabilityRegistry([resolver]),
  executeCapability: async (_descriptor, request) => {
    calls.push(request);
    return { ok: true, note: notes[0] };
  },
  delegateWork: async () => ({ status: "failed", error: "Note retrieval must not delegate." }),
  taskStatus: async () => ({}),
  cancelTask: async () => ({ ok: true, summary: "" })
});
coordinator.beginTurn("openaiRealtime", "What did we write about 401k and HSA?", "provider-item");
const turnID = Object.keys(coordinator.snapshot().turns)[0];
const result = await coordinator.capability(turnID, "call-1", {
  goal: "What did we write about 401k and HSA?",
  capabilityID: "knowledge_resolve_notes",
  arguments: {}
});
assert.equal(result.status, "completed");
assert.equal(calls.length, 1);
assert.equal(calls[0].arguments.userIntent, "What did we write about 401k and HSA?");

const disabledDescriptors = __realtimeProtocolTestHooks.liveVoiceCapabilityDescriptors(() => ({ knowledge: { enabled: false } }));
assert.equal(disabledDescriptors.find((descriptor) => descriptor.id === "knowledge_resolve_notes").enabled(), false);

// --- Day-scoped activity recall ("what did I do today?") ---------------------
// Activity questions carry no topic keywords, so they must route to the day's
// session files instead of keyword scoring (which once answered "nothing was
// done today" while a 7.9MB session sat on disk).
const { personalRecallActivityDayOffset } = await import("../dist-electron/personalRecallCore.js");
assert.equal(personalRecallActivityDayOffset("What did I do today with Codex?"), 0, "today question routes to today");
assert.equal(personalRecallActivityDayOffset("Did I work on the Airbnb application today?"), 0, "worked-on question routes to today");
assert.equal(personalRecallActivityDayOffset("what did we get done yesterday"), -1, "yesterday question routes to yesterday");
assert.equal(personalRecallActivityDayOffset("What were the envelope requirements?"), undefined, "content question does not route");
assert.equal(personalRecallActivityDayOffset("remind me to buy milk"), undefined, "non-recall question does not route");

// Bridge wiring: activity docs + match-window deep reads + honesty rule.
const fs = await import("node:fs");
const bridgeSource = fs.readFileSync(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");
for (const [needle, label] of [
  ["function sessionActivityDocuments(", "activity documents built from the day's session files"],
  ["function streamTokenMatchWindows(", "deep reads target real token matches, not blind samples"],
  ["personalRecallActivityDayOffset(question, context)", "evidence retrieval consults the activity-day detector"],
  ["I don't see any recorded work sessions for", "day-scoped 'nothing' answers state the day honestly"]
]) {
  assert.ok(bridgeSource.includes(needle), `${label}: expected to find ${JSON.stringify(needle)}`);
}

console.log("Live Voice retrieval checks passed.");
