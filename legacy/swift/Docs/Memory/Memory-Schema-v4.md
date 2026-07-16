# Memory Schema v5

## Version
- Previous: v4
- Current: v5
- Database file: `memory.sqlite3` (same file, in-place migration)

## Existing v4 Tables (Retained)
### `memory_pattern_stats`
Aggregate repeating-pattern counters and confidence.

### `memory_pattern_occurrences`
Event-level occurrences linked to `memory_pattern_stats`.

## New v5 Conversation Tables
### `conversation_threads`
Tuple-thread short-term memory root.

Columns:
- `id` (PK)
- `app_name`, `bundle_id`
- `logical_surface_key`, `screen_label`, `field_label`
- `project_key`, `project_label`
- `identity_key`, `identity_type`, `identity_label`
- `native_thread_key` (empty string when unavailable)
- `people_json`
- `running_summary`
- `total_exchange_turns`
- `created_at`, `last_activity_at`, `updated_at`

Indexes:
- unique tuple index:
  - `(bundle_id, logical_surface_key, project_key, identity_key, native_thread_key)`
- `idx_conversation_threads_last_activity(last_activity_at DESC)`

### `conversation_turns`
Conversation turns for each tuple thread.

Columns:
- `id` (PK)
- `thread_id` (FK -> `conversation_threads.id`, cascade delete)
- `role`
- `user_text`, `assistant_text`, `normalized_text`
- `is_summary`
- `source_turn_count`
- `compaction_version`
- `metadata_json`
- `created_at`
- `turn_dedupe_key`

Indexes:
- unique `turn_dedupe_key`
- `idx_conversation_turns_thread_created(thread_id, created_at DESC)`

### `conversation_thread_redirects`
Tracks duplicate-thread merges.

Columns:
- `old_thread_id` (PK)
- `new_thread_id`
- `reason`
- `created_at`

### `conversation_tag_aliases`
Canonical alias normalization map.

Columns:
- `alias_type`
- `alias_key`
- `canonical_key`
- `updated_at`

Primary key:
- `(alias_type, alias_key)`

## Migration Notes
- `schemaVersion` is now `5`.
- Migration is additive/idempotent via `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS`.
- Existing v4 long-term data remains intact.
- Legacy JSON short-term conversation storage is not migrated.

## Operational Notes
- Auto-compaction source for promotion comes from tuple-thread summaries + retained recent turns.
- Long-term promotion metadata includes thread and identity dimensions (`thread_id`, `identity_*`, `native_thread_key`).
