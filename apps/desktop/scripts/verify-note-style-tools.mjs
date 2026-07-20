/**
 * Verifies that the note style guide tools and organize-preview changes are
 * correctly wired across realtimeProxy and openassistBridge.
 *
 * - Runtime checks use dist-electron/realtimeProxy.js (no Electron dep).
 * - Source checks read the TypeScript source text for the bridge (which links
 *   to Electron and cannot be dynamically imported outside an Electron process).
 */
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const proxyPath = path.resolve("dist-electron/realtimeProxy.js");
const bridgeSrc = path.resolve("electron/openassistBridge.ts");

if (!fs.existsSync(proxyPath)) {
  console.error("Missing dist-electron/realtimeProxy.js. Run npm run build first.");
  process.exit(1);
}
if (!fs.existsSync(bridgeSrc)) {
  console.error("Missing electron/openassistBridge.ts.");
  process.exit(1);
}

// ── Runtime checks: realtimeProxy (no Electron dep) ────────────────────────

const { __realtimeProtocolTestHooks } = await import(path.toNamespacedPath(proxyPath));
const realtimeVoiceKnowledgeToolSpecs = __realtimeProtocolTestHooks
  .liveVoiceCapabilityDescriptors(() => ({ knowledge: { enabled: true } }))
  .filter((descriptor) => descriptor.id.startsWith("knowledge_"))
  .map((descriptor) => ({
    name: descriptor.id,
    description: descriptor.description,
    parameters: descriptor.inputSchema
  }));

assert.ok(Array.isArray(realtimeVoiceKnowledgeToolSpecs), "Live Voice note capabilities must be available in the hidden registry");

// Realtime agent must be able to read a full note by itemID before organizing it
const rtReadTool = realtimeVoiceKnowledgeToolSpecs.find((t) => t.name === "knowledge_read");
assert.ok(rtReadTool, "knowledge_read must be in realtimeVoiceKnowledgeToolSpecs");
assert.ok(
  rtReadTool.parameters?.properties?.itemID,
  "knowledge_read must accept an itemID parameter"
);

const rtStyleTool = realtimeVoiceKnowledgeToolSpecs.find((t) => t.name === "knowledge_note_style_guide");
assert.ok(rtStyleTool, "knowledge_note_style_guide must be in realtimeVoiceKnowledgeToolSpecs");
assert.ok(
  rtStyleTool.description.toLowerCase().includes("callout"),
  "knowledge_note_style_guide description must mention callout"
);
assert.ok(
  rtStyleTool.parameters?.properties != null,
  "knowledge_note_style_guide must have a parameters block"
);

const rtOrganizeTool = realtimeVoiceKnowledgeToolSpecs.find((t) => t.name === "knowledge_request_organize");
assert.ok(rtOrganizeTool, "knowledge_request_organize must be in realtimeVoiceKnowledgeToolSpecs");
assert.ok(
  rtOrganizeTool.parameters?.properties?.itemID,
  "knowledge_request_organize must include itemID in its parameters"
);
assert.ok(
  rtOrganizeTool.parameters?.properties?.markdown,
  "knowledge_request_organize must include markdown in its parameters"
);
assert.ok(
  rtOrganizeTool.description.includes("knowledge_note_style_guide"),
  "knowledge_request_organize description must reference knowledge_note_style_guide"
);

// ── Source checks: openassistBridge.ts ─────────────────────────────────────
// The bridge cannot be dynamically imported in plain Node.js (Electron dep),
// so we verify by inspecting the TypeScript source text.

const bridgeText = fs.readFileSync(bridgeSrc, "utf8");

// Style guide function exists and covers required callout kinds
assert.ok(
  bridgeText.includes("function openAssistNoteStyleGuide"),
  "openAssistNoteStyleGuide function must exist in openassistBridge.ts"
);
assert.ok(
  bridgeText.includes("::: decision") && bridgeText.includes("::: warning"),
  "openAssistNoteStyleGuide must include decision and warning callout examples"
);
assert.ok(
  bridgeText.includes("| Main | Details |") && bridgeText.includes("| Now | Next | Later |"),
  "openAssistNoteStyleGuide must include 2-column and 3-column layout examples"
);

// MCP tool oa_note_style_guide exists
assert.ok(
  bridgeText.includes('"oa_note_style_guide"'),
  "oa_note_style_guide must be defined in knowledgeMCPTools"
);

// oa_request_organize schema includes itemID and markdown
// Find the MCP tool definition (search for name: "oa_request_organize" with surrounding whitespace)
const organizeToolIdx = bridgeText.indexOf('name: "oa_request_organize"');
assert.ok(organizeToolIdx >= 0, "oa_request_organize must be defined in knowledgeMCPTools");
const organizeWindow = bridgeText.slice(organizeToolIdx, organizeToolIdx + 1200);
assert.ok(
  organizeWindow.includes("itemID") && organizeWindow.includes("markdown"),
  "oa_request_organize must include itemID and markdown in its schema (within 1200 chars of its name)"
);

// knowledgePreviewForRequest handles request_organize with itemID + markdown → replace_markdown
assert.ok(
  bridgeText.includes('"request_organize"') &&
    bridgeText.includes("replace_markdown") &&
    /request_add.*request_patch.*request_organize/s.test(bridgeText),
  "knowledgePreviewForRequest must handle request_organize alongside request_add and request_patch"
);
assert.ok(
  bridgeText.includes('previousMarkdown?: string; title?: string') &&
    bridgeText.includes("preview.previousMarkdown = item.markdown") &&
    bridgeText.includes("preview.title = item.title"),
  "replace_markdown previews must carry previousMarkdown/title snapshots for approval diffs"
);

// Handler for knowledge_read alias in knowledgeToolResult (maps to readKnowledgeItem)
assert.ok(
  bridgeText.includes('case "knowledge_read":'),
  "knowledgeToolResult must handle knowledge_read so the realtime agent can read full notes"
);

// Handler for oa_note_style_guide / knowledge_note_style_guide in knowledgeToolResult
assert.ok(
  bridgeText.includes('case "oa_note_style_guide":') &&
    bridgeText.includes('case "knowledge_note_style_guide":') &&
    bridgeText.includes("openAssistNoteStyleGuide()"),
  "knowledgeToolResult must handle oa_note_style_guide and knowledge_note_style_guide"
);

// Knowledge agent instructions mention the two-step organize pattern
assert.ok(
  bridgeText.includes("oa_note_style_guide") && bridgeText.includes("oa_request_organize"),
  "openAssistKnowledgeAgentInstructions must reference oa_note_style_guide and oa_request_organize"
);
assert.ok(
  bridgeText.includes("approval preview") && bridgeText.includes("Review Inbox"),
  "agent instructions must point users to the approval preview"
);

// Helpful error message for organize without markdown
assert.ok(
  bridgeText.includes("oa_request_organize requires itemID and markdown"),
  "createKnowledgeWriteRequest must emit a specific error when request_organize lacks markdown"
);

console.log("Note style tools checks passed.");
