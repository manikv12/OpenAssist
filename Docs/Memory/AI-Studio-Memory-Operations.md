# AI Studio Memory Operations

## Purpose
Provide operator visibility and controls for conversation memory promotion, repeat patterns, and retention lifecycle.

## Conversation Memory Page Additions
- Long-term pattern summary metrics:
  - pattern count
  - repeating count
  - good repeat count
  - bad repeat count
- Pattern list with scope labels and timestamps.
- Occurrence inspection for selected pattern.

## Actions
- `Refresh Patterns`: reload stats from SQLite.
- `Inspect`: load recent occurrences for a pattern.
- `Mark Good`: append a manual good outcome occurrence.
- `Mark Bad`: append a manual bad outcome occurrence.
- `Delete Pattern`: remove pattern aggregate and related occurrences.
- `Purge Expired`: run tiered retention purge.

## Operational Notes
- Actions are best-effort and non-blocking.
- Pattern rows and occurrences are source-of-truth in SQLite.
- Marking good/bad updates repeat counters immediately via occurrence recording.

## Debug Checklist
1. Confirm feature flags are enabled.
2. Confirm pattern tables exist in schema v4.
3. Trigger compaction and verify a promotion-created card/event exists.
4. Check pattern stats/occurrences update after actions.
5. Run purge and verify stale counts decrement.
