# Voice Recall Architecture — Reliable "What did I do?" Answers

**Problem (2026-08-01):** The user worked in the Codex app on the Springfield
Airbnb application ("Check Airbnb requirements" thread). Later they asked Live
Voice about it. The assistant answered "nothing was done today" — even though
the session file was sitting on disk at
`~/.codex/sessions/2026/08/01/rollout-2026-08-01T14-37-41-….jsonl`.

## Why it failed (measured, not guessed)

The recall pipeline (`runSparkPersonalRecall` → `retrievePersonalRecallEvidence`
→ `searchPersonalRecallSources` in `openassistBridge.ts`) works like this today:

1. Scan `~/.codex/sessions` + `~/.claude/projects` for the 160/220 newest
   `.jsonl` files (30-second in-memory cache, `personalRecallFileCache`).
2. For each large file, `readJSONLSamples` reads **8 blind windows totaling
   128 KB** spread evenly across the file.
3. `parseAgentSessionJSONL` + `evenlySampleMessages` keep **48 messages** per
   file.
4. Keyword-score those snippets against the question; keep top 8; hand them to
   Spark to phrase an answer.

The Airbnb session is **7.9 MB**. 128 KB of blind windows = **1.6 % of the
file**, and the word "Airbnb" appears only 13 times in it. The evidence
sampling is a lottery, and the question "what did I do today?" contains **no
content keywords at all** — scoring requires `score > 0` token matches, so a
date-shaped question matches nothing. Spark then honestly reports "nothing
found," which the voice narrates as "nothing was done today."

Two structural causes:

- **Read-time retrieval.** Every question re-scans raw multi-MB files live,
  inside the voice turn (observed 25–30 s per recall). Slow AND unreliable.
- **No activity ledger.** "What did I do today" is a *ledger* question, not a
  *search* question. Nothing in the system records "these sessions were active
  today, about these topics."

## Target architecture: ingest once, answer fast

### 1. Session Ledger (new `electron/sessionLedgerCore.ts`)

A background ingester that watches all session sources and maintains one
compact record per session in `userData/session-ledger.jsonl` (or SQLite):

```
{ sessionID, agent: codex|claude|openassist, filePath, title,
  workspacePath, projectName, dayIDs: ["2026-08-01"], firstUserPrompt,
  lastActivityAt, byteOffset, summary?, entities?: ["airbnb", "envelope"…] }
```

- **Cheap by default:** title = first user message, entities = capitalized
  nouns / repeated terms / file paths / tool names extracted with plain code.
  No model call needed for a usable record.
- **Incremental:** remember `byteOffset` per file; on mtime change re-read only
  the appended tail. Debounce ~60 s (same discipline as Memory Dream).
- **Fresh when it matters:** run ingestion at Live Voice session start
  (prewarm) and on a file-watcher tick, so "today" is always indexed before a
  question can arrive.
- **Model summaries are optional upgrades:** Memory Dream / Spark can enrich
  `summary` in the background, never on the hot path.

### 2. Route "activity" questions to the ledger (deterministic)

Classifier (extends the existing recall routing): a question with a date shape
("today", "yesterday", "this week", "this morning") + a do/work verb is an
**activity question**. Answer it straight from the ledger:

```
day=2026-08-01, agent=codex →
"You worked in Codex on 'Check Airbnb requirements' (Home) this afternoon,
 and two OpenAssist threads: …"
```

Milliseconds, no sampling, no lottery. Spark only *phrases* the ledger rows
(low effort), it never has to *find* them.

### 3. Content questions: ledger narrows, then targeted deep-read

"What were the envelope requirements?" →

1. Ledger match by entities/date/project → pick the 1–3 candidate session
   files.
2. **Read around real matches, not blind windows:** stream-scan the file for
   query tokens and read ±4 KB around the top match offsets
   (`readJSONLSamples` gains a `matchOffsets` mode). This turns 1.6 % blind
   coverage into 100 % coverage of the relevant parts.
3. Hand only those focused snippets to Spark.

### 4. Honesty contract (never fabricate "nothing")

"Nothing was done today" is only allowed when the **ledger itself** is empty
for that scope. If ledger rows exist but deep evidence is thin, the answer must
degrade gracefully: *"You worked on 'Check Airbnb requirements' in Codex this
afternoon — want me to pull up the details?"* — never a false negative.

### 5. Speed budget (voice turn hot path)

| Step | Budget |
|---|---|
| Ledger query | < 50 ms |
| Targeted deep-read (content questions only) | < 2 s |
| Spark phrasing (low effort) | provider-bound |
| Background ingestion / summaries | unlimited, off hot path |

## Decision: keep it lightweight (2026-08-01)

Per user constraint — no persistent index, no background daemons, no growing
storage. The "Session Ledger" is therefore a **live computation**, not a
database: the Codex sessions tree is already organized by date
(`sessions/YYYY/MM/DD/`), so the day's activity is just a folder listing plus
bounded head/tail reads. Nothing is written to disk, nothing has to be managed.

## Implemented (all in `openassistBridge.ts` + `personalRecallCore.ts`)

- **`personalRecallActivityDayOffset`** (pure, personalRecallCore): detects
  day-shaped activity questions ("what did I do today / yesterday?") → day
  offset.
- **`agentSessionFilesForDay` + `sessionActivityDocuments`**: list that day's
  Codex folder (+ Claude sessions by mtime), read a 512KB head + 48KB tail per
  file (max 16 files), extract the first *real* user prompt (skipping injected
  `<recommended_plugins>`-style blocks) and the latest assistant text. These
  become top-ranked evidence docs — the day's sessions are ALWAYS visible to
  Spark regardless of keywords.
- **`streamTokenMatchWindows`**: for questions with topic words, stream-scan
  candidate session files (bounded: 24MB/file, ≤6 files) and read ±3KB around
  the REAL match offsets — replacing the blind 1.6%-coverage sampling. Measured
  ~30ms on the 7.9MB Airbnb rollout.
- **Honesty rule**: a day-scoped question may only get a "nothing" answer when
  that day truly has no session files, and the answer names the day: *"I don't
  see any recorded work sessions for 2026-08-01."*

Guarded in `scripts/verify-live-voice-retrieval.mjs`.

## Later (only if ever needed, still lightweight)

- Cache the per-day activity docs in memory for the voice session (they're
  already cheap: ~12ms for 6 sessions).
- Optional Spark background summaries — explicitly deferred to avoid managed
  state.
