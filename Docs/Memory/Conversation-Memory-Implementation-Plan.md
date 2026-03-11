# Conversation Memory v2 (SQLite Tuple Threads -> Long-Term Patterns)

## Summary
Short-term conversation memory now uses SQLite tuple-thread storage and directly powers long-term memory promotion/pattern tracking.

This replaces JSON short-term dependency and prevents cross-project/cross-conversation bleed inside the same app.

## Locked Decisions
- Tagging: fully automatic.
- Isolation: strict exact tuple match for short-term conversation context selection.
- Group chats: channel-first identity, people as secondary tags.
- Surface key: logical surface only (window/document/field), not physical monitor/screen placement.
- Same app/project/person split: native thread key when available, otherwise one rolling tuple thread.
- Cutover: fresh short-term storage (no JSON migration).
- Dedup safeguards: idempotent turn keys, canonical aliases, duplicate-thread redirect support.

## End-to-End Flow
1. Capture request context.
2. Infer tuple tags (`project`, `identity`, `nativeThreadKey`, `people`).
3. Resolve exact tuple thread and build relevant context pack.
4. Rewrite using only that thread pack (no unrelated fallback thread history).
5. Persist user + assistant turn into the same tuple thread.
6. Auto-compact when thread exchange turns exceed threshold.
7. Promote compaction summary + retained turns to long-term memory.
8. Record/update pattern stats + occurrences.

## Current Short-Term Behavior
- Context key: `(bundle_id, logical_surface_key, project_key, identity_key, native_thread_key)`.
- Exact thread read only for short-term context; if not found, request gets empty history and a new thread starts on write.
- Relevant context payload:
  - latest running summary (if present),
  - up to 6 best recent exchanges (relevance + recency),
  - character budget target around 2500.
- Auto-compaction:
  - trigger: exchange turns > 40,
  - retain: summary + latest 8 exchanges.

## Schema (v5)
Stored in existing `memory.sqlite3`:
- `conversation_threads`
- `conversation_turns`
- `conversation_thread_redirects`
- `conversation_tag_aliases`

Unique/critical indexes:
- tuple unique index on `(bundle_id, logical_surface_key, project_key, identity_key, native_thread_key)`
- unique `turn_dedupe_key`
- `conversation_threads(last_activity_at DESC)`
- `conversation_turns(thread_id, created_at DESC)`

## Long-Term Promotion Payload Requirements
Promotion metadata includes:
- `thread_id`, `scope_key`
- `project_name`, `repository_name` (if present)
- `identity_key`, `identity_type`, `identity_label`
- `native_thread_key`
- `trigger`, `source_turn_count`, `compaction_version`

Promotion dedupe signature uses:
- `thread_id + scope_key + summary_digest + source_turn_count + trigger`

## Retrieval and Isolation Rules
- Short-term conversation context: exact tuple thread only.
- Long-term retrieval for conversation-origin memories: identity-aware filtering prevents cross-channel/person leakage.
- Strict coding isolation remains enabled for cross-project safety.

## Compatibility and Migration
- Existing long-term tables remain compatible.
- Short-term JSON storage is intentionally not migrated.
- Long-term memory generation now depends on tuple-thread compaction events.

## Acceptance Checklist
1. Same app, different project -> distinct threads.
2. Same project, different channel/person -> distinct threads.
3. Same tuple, different native thread IDs -> distinct threads.
4. Window moved across monitors -> same thread.
5. Missing exact tuple -> empty context pack (no unrelated thread fallback).
6. Retry of same turn write remains idempotent.
7. Compaction preserves continuity while capping context size.
8. Long-term promotion contains identity and thread metadata.
9. Pattern stats/occurrences update from tuple-based promotions.
10. Existing long-term memory remains readable after v5 schema bump.
