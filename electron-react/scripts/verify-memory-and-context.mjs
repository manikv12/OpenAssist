import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

// Guards for the context-diet + memory-system work (2026-07-02):
// A. Per-turn context must stay slim — static instructions are sent once per
//    provider session (hash-gated for Codex, full-then-compact for CLI
//    providers) and the stateless replay/snapshot caps stay tight.
// B. The file-based assistant memory (Memory/ + MEMORY.md + session digests)
//    stays wired end to end: tools defined, dispatched, visible, indexed
//    into recall, and injected as a capped index at session start.

const bridge = fs.readFileSync(path.resolve("electron/openassistBridge.ts"), "utf8");

// --- A1: Codex hash-gated developer instructions ---
assert.match(
  bridge,
  /developerInstructionsHash/,
  "Codex resume must hash-gate developerInstructions (send only when changed)."
);
assert.match(
  bridge,
  /codexThreadResumeParams\(existingProviderSessionID, session, modelID, options, instructionsUnchanged\)/,
  "thread/resume must omit developerInstructions when the hash is unchanged."
);
assert.match(
  bridge,
  /function updateProviderBinding\(threadID: string, backend: AssistantBackend, providerSessionID: string, modelID\?: string, extras\?: JsonObject\)/,
  "updateProviderBinding must accept extras so the instructions hash can live on the binding."
);

// --- A2: full-then-compact instructions for CLI providers ---
assert.match(
  bridge,
  /function openAssistKnowledgeAgentInstructionsCompact\(/,
  "The compact (~1KB) knowledge instruction variant must exist."
);
assert.match(
  bridge,
  /isNewSession \? openAssistKnowledgeAgentInstructions\("Claude"\) : openAssistKnowledgeAgentInstructionsCompact\("Claude"\)/,
  "Claude Code must get the full block only on new sessions and the compact one on resumed turns."
);
assert.match(
  bridge,
  /isNewSession \? openAssistKnowledgeAgentInstructions\("Copilot"\) : openAssistKnowledgeAgentInstructionsCompact\("Copilot"\)/,
  "Copilot must get the full block only on new sessions and the compact one on resumed turns."
);
assert.match(
  bridge,
  /openAssistKnowledgeAgentInstructionsCompact\("Antigravity"\)/,
  "Antigravity's per-turn header must use the compact instruction block."
);

// --- A3: stateless replay caps ---
assert.match(bridge, /const recentContextMaxMessages = 4;/, "Stateless replay must send at most 4 recent messages.");
assert.match(bridge, /const recentContextMaxCharsPerMessage = 800;/, "Replayed messages must be capped at 800 chars.");

// --- A4: Antigravity native session resume ---
assert.match(
  bridge,
  /providerBinding\(session, "antigravityCLI"\)\?\.providerSessionID/,
  "Antigravity must read the bound native conversation id before running."
);
assert.match(
  bridge,
  /\.\.\.\(conversationID \? \["--conversation", conversationID\] : \[\]\)/,
  "Antigravity must resume its native conversation with --conversation."
);
assert.match(
  bridge,
  /if \(conversationID && conversationID !== resumeConversationID\) \{\s*\n\s*try \{\s*\n\s*updateProviderBinding\(threadID, "antigravityCLI", conversationID\);/,
  "Antigravity must store the conversation id on the provider binding after each run."
);
assert.match(
  bridge,
  /if \(resumingConversation\) \{\s*\n\s*return `\$\{header\}\\n\\nCurrent user task:\\n\$\{currentTask\}`;/,
  "Resumed Antigravity turns must not replay the transcript into the prompt."
);
assert.match(
  bridge,
  /retrying fresh/,
  "A failed Antigravity resume must retry once as a fresh conversation."
);

// --- A5: Ollama local replay depth ---
assert.match(bridge, /const ollamaRecentContextMaxMessages = 12;/, "Ollama (local) must replay a deeper history window.");
assert.match(bridge, /const ollamaRecentContextMaxCharsPerMessage = 1_500;/, "Ollama replay entries must be capped at 1500 chars.");
assert.match(
  bridge,
  /slice\(-ollamaRecentContextMaxMessages\)/,
  "The Ollama transcript replay must use its own depth constant."
);
const snapshotFn = bridge.slice(
  bridge.indexOf("function relevantKnowledgeContextForPrompt"),
  bridge.indexOf("function applyKnowledgePreview")
);
assert.doesNotMatch(
  snapshotFn,
  /JSON\.stringify\([^)]*, null, 2\)/,
  "The per-turn knowledge snapshot must use compact JSON (pretty-printing doubled its size)."
);
assert.match(snapshotFn, /slice\(0, 2000\)/, "Planner day markdown in the snapshot must be capped at 2000 chars.");

// --- B1/B2: memory store + tools ---
for (const fn of ["saveAssistantMemory", "readAssistantMemory", "listAssistantMemories", "deleteAssistantMemory", "readAssistantMemoryIndex", "rewriteAssistantMemoryIndex"]) {
  assert.match(bridge, new RegExp(`function ${fn}\\(`), `Memory store must define ${fn}.`);
}
for (const tool of ["oa_memory_save", "oa_memory_list", "oa_memory_read", "oa_memory_delete"]) {
  assert.match(bridge, new RegExp(`name: "${tool}"`), `${tool} must be defined in knowledgeMCPTools.`);
  assert.match(bridge, new RegExp(`case "${tool}":`), `${tool} must be dispatched in knowledgeToolResult.`);
  assert.match(
    bridge,
    new RegExp(`"${tool}"[,\\s]`),
    `${tool} must appear in the visible tool name lists.`
  );
}
const simpleNames = bridge.slice(
  bridge.indexOf("const simpleKnowledgeMCPToolNames"),
  bridge.indexOf("const advancedKnowledgeMCPToolNames")
);
for (const tool of ["oa_memory_save", "oa_memory_list", "oa_memory_read", "oa_memory_delete"]) {
  assert.match(simpleNames, new RegExp(`"${tool}"`), `${tool} must be in simpleKnowledgeMCPToolNames.`);
}

// --- B3: session digests ---
assert.match(bridge, /function appendSessionDigest\(/, "Automatic session digests must exist.");
assert.match(
  bridge,
  /if \(!isTransient && userSource !== "realtimeVoice"\) \{\s*\n\s*appendSessionDigest\(/,
  "Digests must be written on completed turns, skipping temporary and realtime-voice threads."
);

// --- B4: recall indexing ---
assert.match(bridge, /"assistant_memory",/, "assistant_memory must be a knowledge timeline source type.");
const memoryTypes = bridge.slice(
  bridge.indexOf("const personalRecallMemorySourceTypes"),
  bridge.indexOf("const personalRecallChatSourceTypes")
);
assert.match(memoryTypes, /"assistant_memory"/, "Personal recall phase 'memory' must include assistant memories.");
assert.match(
  bridge,
  /sourceType: "assistant_memory"/,
  "knowledgeTimelineDocuments must index Memory/ files."
);
assert.match(
  bridge,
  /sourceLabel: "Session summary"/,
  "knowledgeTimelineDocuments must index session digests."
);

// --- B5: injection ---
assert.match(
  bridge,
  /function assistantMemoryIndexInstructionSection\(/,
  "The capped memory index must be injectable into session-start instructions."
);
assert.match(
  bridge,
  /save it with `oa_memory_save`/,
  "The full knowledge instructions must tell the model when to save a memory."
);
const compactFn = bridge.slice(
  bridge.indexOf("function openAssistKnowledgeAgentInstructionsCompact"),
  bridge.indexOf("function realtimeKnowledgeProvider")
);
assert.match(
  compactFn,
  /oa_memory_save \/ oa_memory_list \/ oa_memory_read/,
  "The compact per-turn block must keep the memory tool hint."
);

console.log("Memory and context-diet guards verified.");
