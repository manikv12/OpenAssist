# OpenAssist Mac-to-Mac Sync Plan

Created: 2026-07-04

## Goal

Keep notes, daily planner, and backlog the same across two (or more) Macs that run OpenAssist.

Threads are NOT synced. Each Mac keeps its own threads.

The phone is out of scope for now. Later, the phone can reuse the same sync
endpoint for offline sync, and can connect to whichever Mac is awake.

## Main Idea

```text
Mac A  <-->  /remote/v1/sync/*  <-->  Mac B
```

Both Macs already run the Remote Access server (`http://127.0.0.1:45831+`).
Mac B pairs with Mac A the same way a phone does today (QR code / pairing code),
but the paired record is marked as a **peer machine**, not a phone.

Each Mac then pulls the other's changes and pushes its own. Both directions,
so it does not matter which Mac you edit on.

Important reconnect rule:

```text
Pair once -> save the peer -> reconnect automatically later.
```

After the first pairing, the user should not need to scan the QR code again
unless the peer was revoked or every saved URL fails.

## Connection Modes

Sync must work when the Macs are close AND when they are apart:

1. **Same network**: talk to the peer's local address directly.
2. **Apart**: fall back to the peer's Cloudflare tunnel URL.

Each Mac stores the other Mac in `SyncPeers.json` with:

- peer `machineID`
- peer name
- bearer token
- saved local URL
- saved tunnel URL
- last successful URL
- last sync cursor
- last synced time
- last error

Reconnect order:

1. Try the last successful URL first, if it exists.
2. Try the saved local URL.
3. Try the saved tunnel URL.
4. Call `/remote/v1/health`.
5. Only sync if the returned `machineID` matches the saved peer.

This prevents the app from accidentally syncing with the wrong tunnel or wrong
Mac.

Important: the Quick Tunnel URL changes on every restart. For Mac-to-Mac sync
over the internet, at least one Mac should use a **Named Tunnel** (stable URL).
Setup UI should say this clearly.

If the saved Quick Tunnel URL fails while the Macs are apart, the app may not
be able to rediscover the peer automatically. If the Macs later reconnect on
the same network, the local URL can work again and `/remote/v1/health` can
refresh the saved tunnel URL.

If both Macs host tunnels, that is allowed. Each Mac stores the other Mac's URL.
The sync engine uses a per-peer lock so only one sync run for the same peer is
active at a time.

## What Syncs And What Does Not

| Data | Synced? | Notes |
|---|---|---|
| Notes (`ProjectNotes/<projectUUID>/notes/`) | Yes, full | Markdown + `.assets/` images |
| Note folders (in-app folders) | Yes | IDs in the note manifest, no disk paths |
| Planner days (`Planner/Daily/*.md`) | Yes, full | |
| Backlog (`Planner/Backlog.md`) | Yes, full | |
| Planner categories (`Planner/Categories.json`) | Yes | Items reference category IDs |
| Project identity (UUID, name, icon, parent, hidden, planner-only, area, color) | Yes | Needed so notes have a home; same UUID = same project on both Macs |
| Project `linkedFolderPath` | **No** | Per-machine. Paths differ across Macs |
| Threads / conversation store | **No** | ~378 MB, stays local |
| Thread notes | **No** (for now) | They belong to threads |
| Settings, models, credentials | **No** | |

## Per-Machine Folder Link

`linkedFolderPath` never syncs. Each Mac links its own folder (or none).

But sync DOES carry a hint: each project records which peer machines have a
folder linked and what path (`peerLinkedFolders: { machineID, machineName, path }[]`).
This is display-only metadata.

### Thread-start warning (required)

When the user starts a thread in a project where:

- this Mac has NO `linkedFolderPath`, and
- a peer Mac DOES have one,

show a warning before starting:

```text
This project has no folder linked on this Mac.
On "Manik's MacBook" it is linked to /Users/.../NLSProjects/Amwins.

[ Link a folder… ]  [ Start without folder ]  [ Cancel ]
```

The user must not silently start a stale no-folder chat when the project
clearly has a folder on the other machine.

## Sync And Overwrite Safety

- Every synced item has `updatedAt` (its version).
- Newest edit wins (last-writer-wins per item).
- If BOTH Macs edited the same note while apart: keep both. The losing version
  is saved as a conflict copy ("Note title (conflict from Mac B, Jul 4)").
  Planner items are line-level and small; last-writer-wins per item is enough.
- Deletes need **tombstones**: a small deletion log (`SyncTombstones.json`)
  with `{ kind, id, deletedAt }`, kept ~90 days. Without it, a deleted note
  would just come back on the next sync.
- **Planner day files always merge item-by-item.** Notes have unique UUIDs,
  but `Daily/<date>.md` is keyed by date — both Macs always have their own
  copy of "today". Never copy a day file whole: take the union of items and
  let the newest version win per item. The first-ever sync also unions both
  sides; one Mac's file must never wipe the other's.
- **Clock skew guard.** "Newest wins" trusts both clocks. `/remote/v1/health`
  should return the peer's current time; if the clocks differ by more than
  ~2 minutes, warn and pause sync instead of picking wrong winners.

## Project Delete Rule (safe default)

Deleting a project on Mac A does NOT delete it on Mac B (Mac B may have live
threads in it). Instead Mac B marks it "removed on peer" and keeps it hidden
or asks the user. Notes in it stay until the user confirms.

## Sync Engine

- On each Mac: a `SyncPeers.json` with paired peers, tokens, saved URLs,
  last successful URL, last sync cursor, last synced time, and last error.
- Also keep a small journal of local changes, or use an `updatedAt` scan over
  the manifests, which is fine at this data size (~21 MB total).
- Triggers: on local change (debounced), when the peer pings via SSE, and a
  periodic timer (e.g. every 5 min) as a catch-up when they were apart.
- Per-peer lock: if sync with the same peer is already running, do not start a
  second sync run.
- Before each sync, call `/remote/v1/health` and confirm the saved `machineID`.
- Endpoints (auth = existing bearer token):
  - `GET  /remote/v1/sync/changes?since=<cursor>` → changed items with full
    content + tombstones + new cursor
  - `POST /remote/v1/sync/push` → apply items (each carries the base
    `updatedAt` the sender saw; server rejects stale writes → sender re-pulls)
- Note assets: images referenced by changed notes are included (base64 or a
  follow-up `GET /remote/v1/sync/asset?…`), same trick as the phone's
  `inlineNoteMarkdownImages`.
- After applying remote changes, the app must refresh the UI (notify renderer
  the same way local edits do) — the Electron main process does not hot-reload
  state on its own.

## Security

- Reuse Remote Access pairing, bearer tokens, device revoke.
- Peer records are visible in Settings → Remote Access with a "peer Mac" badge.
- Either Mac can revoke the other; sync stops immediately.
- Same network rules as today (loopback / private IPv4 / tunnel).
- Verify peer identity by saved `machineID` before syncing.

## Build Phases

### Phase 1: Peer pairing

- New paired-device kind: `peer-mac` (claim includes machineID + name)
- Settings UI: "Sync with another Mac" — show QR on Mac A, paste/scan on Mac B
- Store peer in `SyncPeers.json` with machineID, name, token, local URL, tunnel
  URL, last successful URL, cursor, last synced time, and last error.

### Phase 2: Read side

- `GET /remote/v1/sync/changes?since=` serving notes, note folders, project
  identity (+ peer folder hints), planner days, backlog, categories, tombstones
- Cursor = server timestamp of the snapshot

### Phase 3: Apply + push (two-way sync)

- Apply engine: write pulled items to disk atomically, refresh UI
- `POST /remote/v1/sync/push` with stale-write rejection
- Change journal + tombstones on delete paths
- Triggers: debounced local-change push, periodic pull, reconnect pull

### Phase 4: Conflicts

- Conflict copies for double-edited notes
- Project delete = "removed on peer" state, never cascade-delete
- Sync status UI: last synced time, per-peer errors

### Phase 5: Folder hints + thread-start warning

- Sync `peerLinkedFolders` metadata
- Warning dialog when starting a thread in a project with no local folder but
  a peer folder ("Link a folder… / Start without folder / Cancel")

### Phase 6: Apart mode hardening

- Reconnect order: last successful URL, local URL, then tunnel URL
- `/remote/v1/health` machineID check before sync
- Refresh saved tunnel URL after a successful local reconnect
- Named Tunnel recommendation in setup UI
- Clear Quick Tunnel warning: if the URL changes while Macs are apart, automatic
  reconnect may fail until local network reconnect or re-pairing
- Recover cleanly when peer is offline for days (cursor catch-up)

## Test Plan

- Run `npm run build` in `electron-react`.
- Add `scripts/verify-mac-sync.mjs` for:
  - `peer-mac` pairing is stored
  - reconnect verifies saved `machineID`
  - local/tunnel URL fallback order works
  - saved tunnel URL refreshes after local reconnect
  - changes endpoint returns projects, notes, planner, categories, and tombstones
  - push applies newer changes and rejects stale changes
  - `linkedFolderPath` is not overwritten
  - note conflict copy is created for double edits
  - same planner day on both sides merges item-by-item (no wholesale overwrite)
  - big clock skew pauses sync with a warning
  - project delete does not cascade-delete on the peer
- Manual two-profile test:
  - run two OpenAssist data roots on different ports
  - pair once
  - restart both apps and confirm no re-pair is needed
  - edit note/planner/backlog on each side and confirm sync
  - test Quick Tunnel failure case and Named Tunnel success case

### Later (out of scope now)

- Phone offline sync reusing `/remote/v1/sync/changes`
- Thread notes sync
- Read-only thread view on the other Mac
