# Retrieval Ranking And Isolation

## Short-Term Conversation Context (Tuple Threads)
Short-term history selection is strict tuple-thread scoped.

Tuple key:
- `bundle_id`
- `logical_surface_key`
- `project_key`
- `identity_key`
- `native_thread_key`

Rules:
- Exact tuple thread match only.
- No same-project/app-wide fallback for short-term conversation history.
- Missing exact tuple returns empty context pack.
- Physical monitor/screen movement does not create a new thread (logical surface keying only).

## Short-Term Context Pack Ranking
Within the resolved exact thread:
- Include latest running summary when available.
- Select up to 6 exchanges by blended recency + transcript overlap.
- Enforce payload budget around 2500 chars.

## Long-Term Retrieval Inputs
- Text relevance.
- Validation state (`user-confirmed`, `indexed-validated` preferred).
- Confidence and recency.
- Scope and identity match strength.

## Scope-Aware Long-Term Candidate Selection
Priority order:
1. same `scope_key`
2. same `identity_key`
3. same project/repository
4. same app fallback (subject to strict isolation)

## Conversation-Origin Identity Guard
For memories with `origin = conversation-history`:
- Exclude candidates whose `identity_key` conflicts with the active scope identity.
- Prevent cross-channel/cross-person bleed in the same app/project.

## Strict Coding Isolation
When strict isolation is enabled in coding contexts:
- same-scope first
- then same-identity
- then same-project
- app-level fallback only for non-project-tagged entries
- cross-project project-tagged entries are excluded from fallback
