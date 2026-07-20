# OpenAssist Mac-to-Mac Sync Plan

Created: 2026-07-04
Updated: 2026-07-14

## Current Status

| Stage | Status | Meaning |
|---|---|---|
| Implemented | Yes | Protocol v2 and the safety repairs are implemented in the current working tree. |
| Verified | Automated checks passed | `npm run verify:mac-sync` and `npm run build` pass locally. A real two-Mac test is still required. |
| Released | No | Do not call this hardening shipped until a release build is installed and tested on both Macs. |

## Goal

Keep project notes, daily planner, backlog, and planner categories the same on
two or more Macs running OpenAssist.

Threads, settings, model credentials, linked folder paths, and thread notes stay
local to each Mac. Phone offline sync is not part of this version.

## Pair Once And Reconnect

```text
Mac A  <-->  /remote/v1/sync/*  <-->  Mac B
```

One Mac displays the normal Remote Access pairing code. The other Mac pairs as
a `peer-mac`. The pairing claim gives both Macs the information needed to save
each other, so one pairing creates a two-way connection.

After pairing, each Mac remembers the peer by its stable `machineID`. The
computer name is only a label. Two computers both named "MacBook Pro" remain
separate peers.

Reconnect order:

1. Try the last successful URL.
2. Try the saved local-network URL.
3. Try the saved tunnel URL.
4. Call `/remote/v1/health` and verify the saved `machineID`.
5. Sync only when the identity and protocol version are correct.

If one Mac is already hosting a tunnel, the other Mac stores that tunnel URL
during pairing and reconnects to the same peer later. Both Macs may host
tunnels, but that is not required. A Named Tunnel has a stable URL and is the
reliable choice when the Macs are apart. A Quick Tunnel URL changes after a
restart and may require a same-network reconnect or re-pairing.

Every sync request includes the caller's local server port. The receiving Mac
can learn a usable same-network callback address from the connection itself.
Loopback addresses such as `127.0.0.1` are never stored as peer addresses.

## Protocol V2

Both Macs must run protocol v2. `/remote/v1/health` returns:

- `macSyncProtocolVersion: 2`
- supported Mac Sync capabilities
- stable `machineID`
- current server time

`/remote/v1/sync/changes` and `/remote/v1/sync/push` reject older clients with:

```text
Update OpenAssist on both Macs before syncing.
```

This fails before any v2 changes are applied, so mixed v1/v2 peers pause instead
of partially syncing.

## What Syncs

| Data | Behavior |
|---|---|
| Project notes | Markdown, note metadata, and each note's `.assets/` folder |
| Note folders | Folder IDs and metadata; no local disk paths |
| Project identity | UUID, name, icon, parent, hidden state, planner-only state, area, and color |
| Planner tasks | Individual structured tasks with stable IDs and versions |
| Planner text | Text outside task blocks, merged separately per day/backlog document |
| Planner categories | Individual categories by stable category ID |
| Project `linkedFolderPath` | Not synced; it stays local to each Mac |
| Threads and thread notes | Not synced |
| Settings and other credentials | Not synced |

Projects may carry display-only `peerLinkedFolders` hints. These hints allow the
app to warn when a project has a folder on another Mac but not on this one. The
thread-start warning uses an in-app dialog with Link Folder, Start Without
Folder, and Cancel actions.

## Secure Storage

`SyncPeers.json` contains only peer metadata and a `tokenRef`. It never stores a
plaintext bearer token.

- Peer tokens are encrypted through Electron `safeStorage`.
- Existing plaintext peer tokens migrate automatically on first read.
- Pairing and sync fail closed if secure storage is unavailable.
- Revoking a peer removes its encrypted token and its paired-device auth token.
- The Remote Access storage directory uses `0700` permissions.
- Mac Sync JSON files use `0600` permissions and atomic writes.

Mac Sync keeps conflict state separate from credentials:

- `SyncItemVersions.json`: the current version of each local sync item.
- `SyncPeerState/<machineID>.json`: exact item versions last seen from one peer.
- `SyncTombstones.json`: saved deletions, retained indefinitely for now.

## Version And Cursor Rules

Each item carries:

- `updatedAt`
- origin `machineID`
- `contentHash`
- `version`
- `baseVersion`, when the sender has seen an earlier peer version

The newest timestamp wins. If timestamps match, the origin `machineID` breaks
the tie deterministically. The content hash provides a final stable comparison.

The change cursor is the timestamp captured at the start of a scan. It never
moves forward using file timestamps discovered during the scan. The next scan
includes a one-millisecond boundary overlap, so a save that happens during a
scan cannot be skipped forever.

`/remote/v1/health` also exposes server time. Sync pauses when the peer clock is
far enough away to make timestamp-based decisions unsafe.

## Note Safety

- Note IDs, project IDs, filenames, and asset paths are checked before joining
  them to a local path.
- Sync endpoints require a paired device whose kind is `peer-mac`. A phone token
  cannot read or push the Mac note corpus.
- Identical notes with the same ID deduplicate during first pairing.
- Different notes with the same ID create one deterministic conflict copy.
- A conflict copy includes all assets and rewrites image paths to its own asset
  directory.
- Concurrent edits preserve the losing version as a conflict copy.
- A delete does not beat a newer edit. The newer edit remains available.
- Deleting a note also removes that note's asset directory.
- Auto-purged archived notes create tombstones, so they do not return later.
- Conflict-note manifest changes are re-read before the winning note is saved,
  preventing an invisible conflict note.

Project deletion remains conservative: the peer marks the project as removed
or hidden instead of cascading through notes or local threads.

## Planner Safety

Plain Markdown checklist tasks are converted automatically into structured task
blocks while preserving their visible Markdown, headings, details, steps, and
order.

- Legacy tasks get deterministic IDs so the same task matches on both Macs.
- New tasks get UUIDs.
- Moving a task preserves its ID.
- Copying a task creates a new ID.
- Additions, title edits, details, checkbox changes, moves, copies, and deletes
  sync independently by task ID and version.
- Task deletions create `plannerItem` tombstones containing the day or backlog
  container.
- Categories merge by category ID and version.
- Category deletions create `plannerCategory` tombstones.

Planner text outside task blocks is versioned separately. Deterministic
last-writer-wins chooses the displayed text. If both Macs changed it, the losing
document is written to planner recovery history and the sync result reports a
conflict.

Remote planner changes go through the normal planner save functions. This keeps
recovery history, item parsing, and live UI updates working.

## Tombstones And Full Re-sync

Tombstones currently have no time limit. This protects a Mac that reconnects
after being offline for more than 90 days. A future design may compact them only
after every known peer has acknowledged the deletion.

Full Re-sync clears transport cursors only. It keeps item-version history,
rechecks all current content, and sends saved tombstones again. Therefore, a
Full Re-sync may apply a saved deletion. The confirmation dialog says this
clearly and explains that note conflicts and planner recovery copies are kept.

## Sync Triggers And Status

Sync runs after local changes with a short delay, on manual Sync or Full
Re-sync, and periodically for catch-up. A per-peer lock prevents two sync runs
for the same peer at the same time.

Settings shows both directions separately:

- this Mac to the peer
- the peer to this Mac
- last successful time
- pulled, sent, applied, failed, stale, and conflict counts
- a plain-English action when an address or connection is missing

Failed items keep the old cursor and retry. Applied note and planner changes
emit the normal UI refresh events, so an app restart is not required.

## Verification

Run from `apps/desktop`:

```bash
npm run verify:mac-sync
npm run build
```

`verify:mac-sync` compiles the Electron core first. It then creates two
temporary Mac data roots and runs repeated pull/push-style cycles. Coverage
includes:

- stable hashes, machine-ID tie-breaks, scan-start cursors, and overlap
- identical-note deduplication and first-pairing note collisions
- conflict assets and rewritten image paths
- concurrent note edits and delete-versus-newer-edit
- planner add, edit, checkbox, move, copy, and delete
- deterministic legacy task IDs
- planner category edit/delete and planner text recovery
- tombstones older than 90 days, Full Re-sync behavior, and convergence
- same-name Macs and private test-state permissions

Source wiring checks cover Electron-only behavior: `safeStorage`, plaintext
token migration, `0600`/`0700` permissions, revoke cleanup, peer-only endpoints,
protocol mismatch handling, safe note paths, UI refresh, and the Full Re-sync
warning.

Before release, manually test two real Macs:

1. Install the same v2 build on both Macs.
2. Pair once and restart both apps; confirm no second pairing is needed.
3. Edit notes and planner items on both Macs while disconnected, then reconnect.
4. Confirm conflicts, task moves, task deletes, assets, and recovery history.
5. Test on the same network and through a stable tunnel.
6. Revoke one Mac and confirm both sync endpoints immediately reject its token.
7. Run Full Re-sync and confirm the deletion warning matches what happens.

## Earlier Reliability Work

The earlier two-Mac field test found and fixed loopback peer URLs, missing live
UI refreshes, wrong note-asset lookup, failed items being hidden behind an
advanced cursor, and unclear one-way connection status. Those repairs remain in
v2. This section records prior testing only; it does not mean the current v2
safety release has shipped.

## Later Work

- Acknowledged tombstone compaction
- Phone offline sync using protocol v2
- Thread-note sync
- Read-only thread view on another Mac
