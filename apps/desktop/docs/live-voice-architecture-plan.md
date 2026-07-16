# Live Voice Architecture Improvement Plan

Status: implemented (2026-07-08). Scope: `electron/realtimeProxy.ts`, `electron/openassistBridge.ts`, renderer voice capture in `src/App.tsx`.

Implementation note: Phases 1-5 landed with static guards for tool-call speech gating, handoff narration, shared routing, proxy state events, and the optional echo guard setting.

## Why

The current pipeline works, but three structural choices generate most Live Voice bugs:

1. **Behavior is enforced by prompts, not by the protocol.** "Wait for the tool result", "don't read `[BACKEND]` messages", "only speak on `[Agent task finished]`" are all instructions the model can ignore. Every drift becomes a user-visible bug (e.g. answering "no pending tasks" before checking).
2. **Four layers each keep their own session state** (renderer → bridge → Codex app-server → proxy → OpenAI/Gemini). The stuck-`openAIResponseActive` silence bug and its 12s watchdog are symptoms: state desync is possible by construction.
3. **Two brains route utterances.** A regex fast-path (`createDirectKnowledgeVoiceResponse`, `decideRealtimeDelegation`, `tryDirectKnowledgeRequest`) intercepts speech before the model. It has repeatedly disagreed with user intent ("add a thing in my home list" answered as a read; recall questions vetoed).

Each phase below is independently shippable and ends with a verify script (repo convention: `scripts/verify-*.mjs`).

## Phase 1 — Make "wait for the tool result" mechanical (highest payoff, small)

Today: the model can stream a spoken guess AND a `function_call` in the same response. The proxy only handles the call at `response.output_item.done` / `response.done` (realtimeProxy.ts ~3687-3712) — after the guess has already played.

Change (proxy only):

- On `response.output_item.added` (and `.done`) with `item.type === "function_call"` for **answer-bearing tools** (`background_agent`, `delegate_parallel_tasks`, `knowledge_*`, `get_delegated_task_status`, `knowledge_personal_recall`), immediately:
  - truncate any audio already streaming for that response (reuse the barge-in truncation used by `handleStopCommand`),
  - drop remaining audio deltas for that response id.
- Exempt control tools (`wait_for_user`, `set_listening_mode`) — they are not answers.
- Keep the acknowledgment UX deterministic: after truncation, speak a short proxy-chosen filler ("Checking…") via the existing `directSpeechInstructions` response path (~4491) instead of hoping the model words it well.
- After `sendFunctionOutput`, exactly one `response.create` produces the real answer.

Result: the model *cannot* answer before the tool result, regardless of instructions. The Phase-0 instruction rules (added 2026-07-07) stay as belt-and-braces.

Guard: `verify:realtime-tool-gate` — feed a synthetic response containing audio deltas + a `function_call`; assert truncation is sent and only one post-tool `response.create` fires. Cover the Gemini tool-call path too.

## Phase 2 — Retire the magic-string handoff protocol

Today: agent results are injected into the model's conversation as text starting with `[Agent task finished]` / `[Codex task finished]`, progress as `[BACKEND]`/`[Codex progress]`, and ~6 instruction lines teach the model what to read or ignore.

Change:

- Progress messages never enter the model conversation. They already render in the app's work card; the proxy filter (`isBackendProgressMessage`) becomes a hard drop instead of "inject + instruct to ignore".
- On handoff completion, do NOT append the result as a user-visible conversation item. Instead issue `response.create` with per-response instructions: "Narrate this result to the user: …" (same mechanism as `directSpeechInstructions`).
- The existing FIFO (`pendingHandoffs`, `drainParallelResults`, `onParallelNarrationEnded`) stays, but becomes a proxy-owned narration queue feeding those response.creates one at a time.
- Delete the now-dead instruction lines (realtimeProxy.ts ~2026-2027, 2070) once verified.

Result: no string-prefix contract between layers; the model can't read progress aloud or "contradict the result" because it never sees raw injected text.

Guard: `verify:realtime-handoff-narration` — simulate two parallel task completions; assert results are narrated sequentially via instruction-bearing response.creates and no `[Agent task finished]` text reaches the conversation.

## Phase 3 — One router, with a golden test corpus

Today routing decisions are split across the bridge regex router (`createDirectKnowledgeVoiceResponse`, openassistBridge.ts ~13775), `decideRealtimeDelegation`, and `tryDirectKnowledgeRequest` call sites (~3442, 3933, 4022), each patched independently after bugs.

Change:

- Extract one `voiceRouting.ts` module that owns the full decision table: stop/dismissal → recall → mutation verbs (write handlers) → explicit read questions → otherwise defer to the model. Every past routing bug becomes a fixture.
- Policy simplification: the regex layer may only (a) handle hard control phrases (stop/quiet), (b) fast-path unambiguous writes/reads. Anything ambiguous defers to the model — the regex must never *answer* a question the model would have answered differently.
- Promote `scratchpad/voice-routing-check.mjs` into `scripts/verify-voice-routing.mjs` with a golden corpus: "add a thing in my home list", "what memory do I have", "is there any pending task", "can you stop", "do A and B at the same time", etc.

Guard: `verify:voice-routing` in package.json.

## Phase 4 — Explicit session state machine

Today: booleans and maps (`openAIResponseActive`, `quiet`, `pendingHandoffs`, `activeParallelDelegations`) spread across the proxy, with a 12s watchdog as the safety net.

Change:

- One `RealtimeSessionState` enum: `idle | listening | speaking | toolPending | delegating | narrating | quiet`, with a single `transition(to, reason)` method that logs every change (`[realtime.proxy] state: speaking -> toolPending (function_call)`).
- Derive the current booleans from the state instead of mutating them independently; the watchdog stays but becomes an invariant checker ("in `speaking` for >12s without audio deltas → force `listening`").
- Emit state snapshots to the bridge/renderer so the HUD reflects proxy truth instead of inferring its own.

Guard: extend `verify:realtime-protocol` to assert legal transitions for the common flows (barge-in, tool call, parallel delegation, quiet mode).

## Phase 5 (optional, larger) — Shorten the audio path; echo hygiene

- **Direct audio lane:** investigate renderer → proxy WebSocket for PCM frames, keeping Codex only for delegation/thread persistence. Removes two hops and decouples voice availability from Codex health ("Transport closed" class of failures). Requires auth + lifecycle design; do only after Phases 1-4 stabilize.
- **Echo:** assistant playback goes through Web Audio, which Chromium's AEC may not cancel; current mitigation is getUserMedia AEC flags. Experiment: half-duplex mic gating while assistant audio plays (weakens barge-in — measure), or route playback through a media element. Keep behind a setting.

## Order and effort

| Phase | Effort | Risk | Payoff |
|---|---|---|---|
| 1 Tool-call speech gate | ~1 day | low (scoped to proxy) | kills the "answers before checking" class |
| 2 Handoff narration | ~1 day | low-medium | kills the magic-string class |
| 3 Unified router | ~1-2 days | medium (behavior parity) | kills the misroute class |
| 4 State machine | ~1-2 days | medium (touch many sites) | kills the stuck/silent class |
| 5 Direct lane + echo | ~3-5 days | high | reliability + latency |

Phases 1 and 2 are the recommended immediate work; 3 and 4 next; 5 only if the failure classes it targets still hurt afterwards.
