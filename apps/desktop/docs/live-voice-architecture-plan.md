# Live Voice Architecture

Status: implemented on 2026-07-17.

This architecture is shared by OpenAI Realtime and Gemini Live. The providers still own audio transport, VAD, playback, and reconnect behavior. OpenAssist owns every decision after a user utterance is final.

## Invariants

1. Every finalized utterance has one `turnID` and one coordinator owner.
2. A turn can claim no more than one final delivery.
3. OpenAI Realtime and Gemini Live receive the same four public tools.
4. Capability discovery never counts as the user's answer.
5. A failed source, provider, capability, or worker is reported as-is. The coordinator does not switch to another one.
6. Only explicit cancel language cancels background work.
7. Result delivery is FIFO. A later utterance cannot discard an earlier completed result.

## Runtime Flow

```text
microphone or typed Live input
  -> OpenAI Realtime or Gemini Live adapter
  -> finalized transcript + provider event
  -> LiveVoiceCoordinator
       -> direct conversation, or
       -> assistant_capability -> hidden capability registry, or
       -> assistant_delegate_work -> genuine agent work
  -> task coordinator result outbox
  -> one spoken result, or Voice Log when the session is closed
```

`electron/realtimeProxy.ts` composes the system and handles WebSockets. It does not classify user intent with a second router. `electron/openassistBridge.ts` supplies storage, recall, MCP, image, and worker implementations without deciding where a request should go.

## Public Tool Surface

Both realtime providers receive only:

- `assistant_capability`: discover or execute local data, notes, planner, task, recall, MCP, and image capabilities.
- `assistant_delegate_work`: run genuine code, terminal, browser, Computer Use, file, or Codex skill work.
- `assistant_task_status`: inspect pending work.
- `assistant_cancel_task`: cancel explicitly requested work.

OpenAI receives capability results as `function_call_output`. Gemini receives the same result as `FunctionResponse`. Provider-specific code does not choose capabilities.

## Hidden Capabilities

The private registry stores `CapabilityDescriptor` records with an ID, description, operations, source, schema, risk, execution mode, timeout, and idempotency policy.

The model supplies the user's full goal and may name a source. If one exact capability matches, the coordinator runs it. If several match, it returns `selection_required`; the model must select one exact `capabilityID`. If information is missing, it returns `clarification_required` and the assistant asks one short question.

Built-in sources include OpenAssist notes, planner, projects, aggregated tasks, Apple data, personal recall, local MCP, and Codex image generation. Explicit source names win. General to-do questions use the aggregate capability and label each source.

Capabilities may declare typed output resources. The coordinator keeps the stable IDs from recent read results and returns matching resources during later capability selection. This lets follow-up turns update the item that was actually read instead of trying to recover identity from a spoken summary. Argument binding is automatic only when exactly one resource matches; multiple matches require an exact ID or clarification.

Operations remain separate contracts. Apple Reminder add, update, and complete are different capabilities, so a rename cannot be implemented by completing the reminder.

Personal recall keeps its own Spark memory-first, session-second implementation. A recall failure is returned directly and cannot become local search or regular agent work.

## Codex Worker Models

`assistant_delegate_work` carries a structured execution profile. The coordinator first decides that delegation is needed; only then does `liveVoice/workerModelPolicy.ts` choose the worker role. This policy never competes with capability selection.

Normal research, browser work, skills, Computer Use, small edits, and reversible writes use the newest available Codex Spark model with medium reasoning. Deep, complex, high-stakes, or sensitive-write work uses the newest available Sol model with high reasoning. An explicit user request for Spark or Sol wins after the backend confirms that request appears in the finalized transcript.

Both roles resolve from the Codex app-server `model/list` catalog before the hidden worker thread starts. Advanced settings may provide an exact model override. A missing role or unavailable override fails the task directly; there is no model substitution, provider switch, or mid-task escalation. OpenAI Realtime does not use Responses web search, and Gemini Live does not enable native Google Search. Current web research is delegated to the selected Codex worker.

Agent Work and `assistant_task_status` expose compact worker metadata: role, model ID, reasoning effort, selection reason, and whether the user explicitly chose the model. Hidden worker conversations remain temporary and are not shown as normal threads.

## Native Permissions

`electron/nativeAccess.ts` owns the single `NativePermissionBroker` used by Settings, connectors, and Live Voice. Each permission records the real process that performs the work, its bundle identity, read/write access, restart requirement, and exact macOS Settings page.

Capabilities declare `permissionRequirements`. The coordinator checks them before execution and returns `permission_required` when access is missing. It may request one promptable read permission and retry the same capability once. It never changes source or delegates the request after a permission failure.

Apple Reminders and Calendar are checked and used by the same signed EventKit helper. Apple Speech and Computer Use are shown under their own helper identities rather than inheriting Electron's permission state. Settings receives broker change events and refreshes on focus; it does not maintain a polling-based permission cache.

EventKit and Speech helpers are compiled into `Contents/Resources/native-helpers` during packaging. Packaged builds never compile or re-sign these helpers at runtime. A development helper without a stable Apple signing identity is reported as `devUnsigned`, not as granted.

## State And Delivery

`liveVoice/state.ts` is the only state reducer. Session lifecycle, voice phase, turn phase, and background task state are separate fields in one `VoiceSnapshot`.

OpenAI and Gemini events normalize to transcript finalized, tool requested, audio started, response completed, interrupted, connection closed, and connection restored. Late provider events cannot reopen a terminal turn.

The existing `RealtimeTaskCoordinator` owns the sole `VoiceResultOutbox`. Results are narrated one at a time in creation order. Barge-in can stop current audio without deleting capability work, delegated work, or a queued result. Closing Live Voice stops listening and playback but leaves background tasks alive.

## Safety

- A turn may use at most four tool steps.
- Reads may retry once with the same turn and capability.
- Writes have an idempotency key and are not blindly retried after an unknown result.
- Approval tokens are bound to the exact turn, capability, and arguments.
- A provider cannot replace an unavailable update with a different write operation.
- Single reversible changes may run directly. Sensitive or batch changes require approval.
- Structured traces store IDs, timing, lengths, hashes, stages, and error codes. They do not store raw audio or duplicate transcript text.
- Trace files rotate at a bounded size.

Transport reconnects are allowed because they restore the same request. Gemini session resumption stays inside its provider adapter. These are transport recovery, not semantic fallbacks.

## Main Files

- `electron/liveVoice/contracts.ts`: shared contracts.
- `electron/liveVoice/state.ts`: event reducer.
- `electron/liveVoice/capabilityRegistry.ts`: hidden capability selection.
- `electron/liveVoice/coordinator.ts`: turn ownership, safety, and execution policy.
- `electron/liveVoice/workerModelPolicy.ts`: Spark/Sol role and catalog selection after delegation.
- `electron/liveVoice/providerAdapters.ts`: shared tool schemas and normalized events.
- `electron/liveVoice/resultOutbox.ts`: FIFO final-result delivery.
- `electron/liveVoice/trace.ts`: bounded structured trace.
- `electron/nativeAccess.ts`: native permission ownership and EventKit execution gate.
- `electron/realtimeProxy.ts`: provider transport and composition.
- `electron/realtimeTaskCoordinator.ts`: background task tracking and sole outbox owner.

## Verification

Run from the repository root:

```bash
npm run verify:live-voice
npm --prefix apps/desktop run verify:native-permissions
npm run build
```

The architecture tests cover legal reducer transitions, explicit cancellation, reconnect, interruption, delayed and duplicate events, exactly-one delivery, four-step limits, read/write retry rules, approvals, FIFO results, identical provider tools, local MCP, recall isolation, planner move safety, Apple permission errors, and idle CPU guards.

Protocol references:

- [OpenAI Realtime conversations](https://developers.openai.com/api/docs/guides/realtime-conversations)
- [Gemini Live tools](https://ai.google.dev/gemini-api/docs/live-api/tools)
- [Gemini Live session management](https://ai.google.dev/gemini-api/docs/live-api/session-management)
- [LiveKit tool design](https://docs.livekit.io/agents/logic/tools/design/)
- [LiveKit observability](https://docs.livekit.io/deploy/observability/insights/)
