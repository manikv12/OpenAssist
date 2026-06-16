# OpenAssist — Idle RAM/CPU Audit

This document records the idle-scenario performance audit of the Electron+React
app (`electron-react/`) and is updated after every fix PR so the wins are
visible.

## TL;DR — what shipped 2026-05-28

| Metric | Before | After | Change |
|---|---:|---:|---:|
| **Cold start → DOM stable** | **~20 s** | **~3 s** | **-85 %** |
| Cold start → React mounted | 2.1 s | 1.9 s | -10 % |
| `loadAppState` IPC | 17.2 s | **134 ms** | -99 % |
| Initial JS chunk | 2 409 KB | **473 KB** | **-80 %** |
| Main process CPU at idle | 0.35 % | **0.05 %** | -86 % |
| Main process wakeups/s | 23.9 | **3.4** | -86 % |
| GPU process wakeups/s | 57.7 | **0.7** | -99 % |
| Renderer wakeups/s | 13.6 | **0.8** | -94 % |
| Combined wakeups/s | 95.2 | **4.9** | **-95 %** |

Two big wins:

- **Cold-start time dropped from ~20 s to ~3 s.** The 17-second `loadAppState`
  IPC at startup turned out to be doing 4 expensive things serially: a
  cloud-API usage refresh (5-7 s), plugin discovery via the Codex transport
  (5-10 s for 152 plugins), 102 sequential `defaults read` shell processes
  (1.3 s), and per-thread JSON reads for all 81 threads (430 ms). The fix
  was a staged loader (see PR 11 below): the renderer gets a fast "shell"
  snapshot in ~150 ms (settings + 10 most-recent thread headers), and the
  rest streams in via an IPC event.
- **Idle wakeups dropped from 95/s to 5/s** — that's what keeps macOS from
  clocking the CPU up, lets the fans stay quiet, and makes the app feel
  light.

Wins came from five PRs:

1. **PR 11** (staged `loadOpenAssistAppState`) — biggest single win on
   start-up. Returns a fast shell immediately (settings + 10 most-recent
   thread headers, sorted by file mtime + capped before reading bodies),
   then streams plugins / automations / the full thread list / usage refresh
   via a new `openassist:app-state-background-update` IPC event the renderer
   merges into `appState`. Also adds a bulk-cache for `defaults` reads
   (parses one `defaults export DOMAIN -` plist into a `Map<string,string>`
   so 102 serial `readDefault` calls become in-memory lookups) and a 2 s
   in-flight dedupe on `loadAppState` to absorb React StrictMode double-mounts.
2. **PR 3** (Vite `manualChunks`) — splits the 2.4 MB monolithic JS bundle
   into vendor chunks so the initial parse drops from 2 409 KB → 473 KB.
3. **PR 1** (Electron main quick wins) — stops the AppleScript frontmost
   poll when our window is focused, evicts screenshot buffers 30 s after
   screen analysis, and enables `backgroundThrottling: true` on the 7
   pre-warmed background windows.
4. **PR 2** (async batched `debugLog`) — replaces 95 `fs.appendFileSync`
   callers with a 250 ms batched async writer. No measurable idle delta,
   but removes a synchronous-I/O footgun from hot paths.
5. **PR 7** (shared `useNowSecond` ticker) — removes per-message
   `setInterval(1000)` in the chat list in favor of a single ref-counted
   shared ticker.

**PR 4** (lazy `react-syntax-highlighter`) was tried and reverted —
duplicating `highlight.js` across an eager chunk (lowlight) and a lazy chunk
(refractor) made the total bundle bigger, with no idle-parse savings.

**Still in the plan but not yet shipped:** PR 5 (lazy RichNoteEditor — bigger
refactor), PR 6 (App.tsx component split — large), PR 8 (event-driven
knowledge approvals — needs `fs.watch` plumbing), PR 9 (split `styles.css`
per feature), PR 10 (re-enable `--asar`).


**Scope:** idle = app launched, main window visible & focused, no thread
active, no note open, no voice. 30 s warm-up before sampling. 60 s sampling
window at 1 Hz + a 30 s CDP tracing burst.

**How to re-run:** see [Methodology](#methodology) below. TL;DR:

```sh
npm run build
pkill -f "Open Assist"; pkill -f "/electron-react/node_modules/electron"
OPENASSIST_ELECTRON_REMOTE_DEBUG=1 ./node_modules/.bin/electron .
# wait ~30 s for warm-up, then in another shell:
node scripts/measure-idle-electron.mjs --duration 60 --label <pr-id-or-baseline>
```

Artifacts go to `verification/perf/<label>-<timestamp>/` (gitignored). One
folder per run.

---

## Baseline (2026-05-28, before any fix PR)

Measured against the current `main` head with the dev-only perf IPC patched
in. Launched via `./node_modules/.bin/electron .` against the built
`dist-renderer/` (production renderer, dev-mode Electron framework).

**Raw artifacts:** `verification/perf/baseline-2026-05-28T03-39-22-030Z/`

### Per-process averages over a 60 s idle window

Source: `app.getAppMetrics()` sampled 1×/s.

| Process | RSS avg | RSS p95 | CPU avg | CPU p95 | Wakeups avg | Wakeups p95 |
|---|---:|---:|---:|---:|---:|---:|
| **Browser (main)** | 234.5 MB | 244.9 MB | 0.35 % | 0.98 % | **23.9 /s** | 49.0 /s |
| **GPU** | 112.4 MB | 117.5 MB | 0.28 % | 0.95 % | **57.7 /s** | 106.0 /s |
| **Tab (renderer)** | 227.9 MB | **383.7 MB** | 0.31 % | 1.36 % | 13.6 /s | 56.0 /s |
| Utility (Network Service) | 47.6 MB | 47.6 MB | 0 % | 0 % | 0.4 /s | 1.0 /s |
| Utility (Tracing Service) | 74.3 MB | 111.0 MB | 0.05 % | 0.01 % | 1.0 /s | 2.0 /s |

### Renderer-side snapshot

| Metric | Value | Target | Status |
|---|---:|---:|---|
| DOM nodes | 1 866 | < 4 000 | ✅ |
| JS heap (used) | 73.1 MB | < 80 MB | ✅ (barely) |
| JS heap (total allocated) | 77.6 MB | — | — |
| Inner window | 1220 × 770 | — | — |

### Initial JS bundle (production build)

| File | Size | Notes |
|---|---:|---|
| `index-*.js` (initial chunk) | **2 409 KB** | Everything eagerly imported by `src/App.tsx` ends up here |
| `mermaid.core-*.js` | 607 KB | Lazy ✅ |
| `wardley-*.js` | 613 KB | Mermaid sub-chunk, lazy ✅ |
| `cytoscape.esm-*.js` | 442 KB | Mermaid sub-chunk, lazy ✅ |
| `index-*.css` | 320 KB | Eagerly loaded |
| Many small mermaid diagram chunks | < 150 KB each | Lazy ✅ |

Vite's own warning fires on the initial chunk being > 500 KB.

### How we score against the plan's "good enough" targets

| Metric | Target | Measured | Gap |
|---|---:|---:|---:|
| Main RSS | < 120 MB | **234.5 MB** | +114 MB |
| Renderer RSS (median) | < 250 MB | 227.9 MB | OK ✅ |
| Renderer RSS (p95) | — | 383.7 MB | spike worth investigating |
| GPU RSS | < 100 MB | 112.4 MB | +12 MB |
| Main CPU | < 0.3 % | 0.35 % | very close |
| Renderer CPU | < 0.5 % | 0.31 % | OK ✅ |
| DOM nodes | < 4 000 | 1 866 | OK ✅ |
| Renderer JS heap | < 80 MB | 73.1 MB | OK ✅ |
| **Idle wakeups (main + GPU)** | low | **81 /s combined** | high — strongest signal |

**Headline finding:** the renderer and DOM/heap are actually reasonable at idle.
The pain is on the **main process side**: 234 MB RSS at idle plus **23.9
wakeups/s on the Browser process** and **57.7 wakeups/s on the GPU process**
mean macOS keeps the CPU clocked up. That matches the static finding — the
1.2 s AppleScript poll for the frontmost app is the biggest single contributor
([Finding #1](#findings--top-10-idle-scenario)).

The renderer's p95 RSS spike to 383.7 MB also lines up with the static
predictions: huge eager bundle (2.4 MB JS + 320 KB CSS + framer-motion +
prism + tiptap all parsed at startup) → big initial alloc, GC settles down,
but the high-water mark stays in the process heap.

---

## Findings — Top 10 (idle scenario)

(Reproduced from the plan; line numbers verified against current HEAD on
2026-05-28.)

| # | File:line | Why it costs at idle | Est savings | PR |
|---|---|---|---|---|
| 1 | `electron/main.ts:5699-5705` `startFrontmostApplicationTracker` | `osascript` every 1.2 s, always | -0.5 % main CPU, -0.8 wakeups/s | PR 1 |
| 2 | `electron/main.ts:342-348` `debugLog → fs.appendFileSync` | Sync I/O on hot paths (95 callers) | Latency safety | PR 2 |
| 3 | `electron/main.ts:3180, 3183` screen-capture buffers | Up to 200 MB held forever after screen analysis | -20…-200 MB main RSS | PR 1 |
| 4 | `src/App.tsx:34` `react-syntax-highlighter` (Prism) | 250-400 KB eager, ~50-150 ms parse | -250-400 KB bundle | PR 4 |
| 5 | `src/App.tsx:4-29` all of TipTap + lowlight + highlight.js eager | 400-600 KB eager, editor not even open at idle | -400-600 KB bundle | PR 5 |
| 6 | `src/App.tsx:2` `framer-motion` eager | ~120 KB; CSS would do | -50-120 KB bundle | (deferred) |
| 7 | `src/App.tsx:10432-10442` per-message `setInterval(1000)` | O(n) timers when threads mid-run | -1 timer/msg | PR 7 |
| 8 | `src/App.tsx:18483-18488` knowledge approval poll 1.6-5 s | Always-on interval + IPC + re-render | -1 timer, -0.2 wakeups/s | PR 8 |
| 9 | `src/styles.css` 15 981 lines / 380 KB eager | 89 keyframes/transitions, many for hidden UI | -150-250 KB CSS | PR 9 |
| 10 | `index.html:38-104` splash CSS animations | 3 keyframes stay registered after `data-hidden=true` | Minor GPU | PR 9 |

Bonus (cheap wins, folded into PR 1 or PR 10):

- `electron/main.ts:1584` `sidebarScreenFollowTimer` every 120 ms → bump to 500 ms.
- Add `backgroundThrottling: true` to non-main `webPreferences`.
- Re-enable `--asar` packaging (`package.json:17`).

---

## Methodology

### Launching the app for measurement

```sh
# 1. Build the renderer + electron main with the dev-only perf IPC patched in.
npm run build

# 2. Make sure no stale Electron is running.
pkill -f "Open Assist"; pkill -f "/electron-react/node_modules/electron"

# 3. Launch with CDP enabled (8315) and DevTools closed (realistic renderer cost).
OPENASSIST_ELECTRON_REMOTE_DEBUG=1 ./node_modules/.bin/electron .

# 4. Wait 30 s after first paint for renderer warm-up.
```

### Running the measurement script

`scripts/measure-idle-electron.mjs` reuses the CDP scaffolding pattern from
`scripts/verify-running-electron.mjs:13-83`. It:

1. Connects to `http://127.0.0.1:8315/json/list`, picks the main renderer.
2. Calls the dev-only IPC `openassist:__perf-snapshot` (added in
   `electron/main.ts` next to `open-external`, gated on the same
   `OPENASSIST_ELECTRON_REMOTE_DEBUG=1` flag) once at start, then every 1 s.
3. Captures renderer `performance.memory` + `document.*` element count.
4. Runs `ps -axo pid,rss,vsz,pcpu,comm=` every 2 s in parallel.
5. Records a 30 s CDP `Tracing` burst with timeline + V8 categories
   (`tracing.json`, loadable in Chrome DevTools → Performance → Load).
6. After tracing finishes, forces a GC and takes a renderer heap snapshot
   (`renderer-heap.heapsnapshot`, loadable in Chrome DevTools → Memory → Load).

Outputs to `verification/perf/<label>-<timestamp>/`:

- `perf-summary.json` — high-level summary
- `app-metrics-samples.json` — one Electron snapshot/second (sized correctly
  to get a meaningful 60-s CPU avg)
- `perf-snapshot.json` — initial main-process snapshot
- `renderer-metrics.json` — DOM nodes + perf.memory
- `ps-samples.tsv`, `ps-summary.json`
- `tracing.json` — load in DevTools to find unexpected idle work
- `renderer-heap.heapsnapshot` — load in DevTools to find retained objects

### Dev-only perf IPC (internal)

Two small read-only additions:

- `electron/main.ts` — `ipcMain.handle("openassist:__perf-snapshot", …)` next
  to `"open-external"`. Returns `{ error: "disabled" }` when the debug flag
  is off, so it's safe to expose unconditionally.
- `electron/preload.ts` — `__perfSnapshot()` in the `openAssistElectron`
  contextBridge object.

Both gated on `process.env.OPENASSIST_ELECTRON_REMOTE_DEBUG === "1"`, which is
the same flag that opens CDP — meaning it cannot be triggered against a
production launch.

---

## Results after each PR

| PR | Date | Main RSS avg | Renderer RSS avg | Main CPU avg | Main wakeups avg | GPU wakeups avg | Initial JS | Notes |
|---|---|---:|---:|---:|---:|---:|---:|---|
| baseline | 2026-05-28 | 234.5 MB | 227.9 MB | 0.35 % | 23.9 /s | 57.7 /s | 2 409 KB | — |
| **+ PR 3** (Vite splits) | 2026-05-28 | — | — | — | — | — | **473 KB** | -80 % initial JS; vendor chunks split off |
| **+ PR 1** (main.ts quick wins) | 2026-05-28 | **226.4 MB** | 241.0 MB | **0.05 %** | **3.4 /s** | **0.7 /s** | 473 KB | **-86 % main CPU, -86 % main wakeups, -99 % GPU wakeups.** Renderer wakeups -94 % too. Combined Browser+GPU+Renderer wakeups dropped from 95/s → 5/s. |
| **+ PR 2** (async debugLog) | 2026-05-28 | — | — | — | — | — | 473 KB | Replaces 95 callers' `fs.appendFileSync` with a 250 ms-batched async writer. Latency win on bursty paths; no measurable RSS/CPU delta at idle (the log barely fires). |
| **+ PR 7** (shared ticker) | 2026-05-28 | 225.8 MB | 213.2 MB | 0.05 % | 4.7 /s | 0.9 /s | 473 KB | Per-message `setInterval(1000)` replaced with a single ref-counted ticker (`useNowSecond`). At idle no running runs → 0 active timers (the old code already cleared them, but this also prevents N-message storms). Numbers within noise of PR 1, as expected. |
| **PR 4 reverted** | 2026-05-28 | — | — | — | — | — | 473 KB | Lazy-loading `react-syntax-highlighter` would have duplicated `highlight.js` (lowlight is eagerly used by TipTap's CodeBlockLowlight). Net total bundle would have grown by ~270 KB for no idle-parse savings. Decided not worth it. |
| **+ PR 11** (staged loadAppState) | 2026-05-28 | — | — | — | — | — | 473 KB | **Cold start: 19.9 s → 2.8 s (-86 %).** `loadAppState` IPC: 17 224 ms → 134 ms. The renderer now gets the initial shell (settings + 10 most-recent thread headers, sorted by file mtime so we only `readJSON` the 10 we'll show) in one fast call, then merges plugins / automations / full thread list / usage via the new `openassist:app-state-background-update` IPC event. Defaults bulk-cache shaves another 1.2 s off `loadSettings`. |

### PR 1 detail (combined CPU + wakeups view)

| Process | CPU avg | wakeups avg |
|---|---:|---:|
| Browser (main) | 0.35 % → **0.05 %** | 23.9 /s → **3.4 /s** |
| GPU | 0.28 % → **0.00 %** | 57.7 /s → **0.7 /s** |
| Renderer | 0.31 % → 0.14 % | 13.6 /s → **0.8 /s** |
| **Total** | **0.94 % → 0.19 %** | **95.2 /s → 4.9 /s** |

Artifacts: `verification/perf/after-pr1-rehydrated-2026-05-28T04-30-21-269Z/`.

Three things changed in PR 1:

1. **Frontmost-app tracker only runs when our window is visible + blurred**
   (`electron/main.ts:5699-5736`). When the user is in OpenAssist, it stops
   completely — the `osascript` poll only happens when another app is in
   front, which is the only case where the result is useful.
2. **`backgroundThrottling: true` on all 7 non-main windows**
   (`electron/main.ts:1366, 2657, 4794, 4845, 4990, 5553, 5598`). The
   pre-warmed Voice HUD and other hidden background windows now stop spending
   GPU/CPU cycles when not visible.
3. **Screen-capture buffers evict 30 s after the analysis session goes idle**
   (`electron/main.ts:3187-3219` + 3 transition call sites). A 4 K screenshot
   is 10-20 MB and the previous code kept it forever. Eviction is debounced
   and cancels itself if the user starts a new capture in time.
4. Sidebar follow-display timer bumped from 120 ms → 500 ms
   (`electron/main.ts:1605`). Imperceptible to the user.
