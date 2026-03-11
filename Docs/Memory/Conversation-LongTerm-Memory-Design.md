# Conversation Long-Term Memory Design

## Goals
- Preserve useful conversation context after short-term compaction.
- Keep memory scoped to app/surface/project to avoid cross-context leakage.
- Learn from repeats (good and bad) and expose repeat trends.
- Keep operations visible and controllable in AI Studio.

## Non-Goals
- Storing every raw turn indefinitely.
- Replacing existing indexed memory pipelines.
- Sharing coding lessons across projects by default.

## Architecture
- Short-term memory remains in conversation history storage (rolling per app/screen context).
- Compaction emits a summary event payload.
- `ConversationMemoryPromotionService` promotes that payload into SQLite long-term memory.
- Optional extraction derives lessons and rewrite suggestions from promoted summaries.
- Pattern stats/occurrences capture repeat behavior and outcomes.

## Data Flow
1. Capture turns in short-term context bucket.
2. Compact context when threshold/timeout/manual action triggers.
3. Emit compaction payload (summary + recent turns + metadata).
4. Promote payload into long-term `memory_events` + `memory_cards`.
5. Optionally derive `memory_lessons` + `rewrite_suggestions`.
6. Upsert pattern stats and append occurrence.
7. Retrieval consumes scope-aware candidates.

## Scope Model
`MemoryScopeContext` fields:
- `appName`, `bundleID`, `surfaceLabel`
- `projectName`, `repositoryName`
- `scopeKey` (stable derived key)
- `isCodingContext`

## Promotion Triggers
- `autoCompaction`
- `timeout`
- `manualCompaction`
- `manualPin`

## Repeat Detection
- Pattern key is stable digest scoped by `scopeKey`.
- Lesson-aware key uses normalized mistake + correction.
- Summary fallback key uses normalized summary intent.
- `occurrence_count >= 2` marks repeating behavior.
- Outcomes tracked per occurrence: `good`, `bad`, `neutral`.

## Isolation Rules
Coding contexts:
1. same scope key
2. same project/repository
3. app-level fallback (no project-tagged cross-project entries)

Non-coding contexts:
1. same scope key
2. same project-like context (domain/channel if present)
3. same app fallback

## Retention
Tiered cleanup defaults:
- Raw low-signal evidence: 30 days
- Unvalidated lessons: 60 days
- Validated/confirmed and pattern aggregates: 365 days

## Feature Flags
- `OPENASSIST_FEATURE_CONVERSATION_LONG_TERM_MEMORY`
- `OPENASSIST_FEATURE_CONVERSATION_AUTO_PROMOTION`
- `OPENASSIST_FEATURE_STRICT_PROJECT_ISOLATION`
