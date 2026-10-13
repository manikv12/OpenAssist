# Second Brain architecture

The Second Brain is OpenAssist's shared memory for projects, research, tasks, and personal facts. It is built to be read by agents (Codex, Claude, Live Voice workers) with as little noise as possible. This page defines what lives where, who owns each kind of data, and the rules that keep it compact.

## One owner per kind of data

| Kind | Owner and location | Written by | Read by |
| --- | --- | --- | --- |
| Project log | One Markdown file per project in Drive (`Projects/<title>/<title>.md`) | `append_second_brain_project_log`, `rewrite_second_brain_project_log`, `update_second_brain_project_policy` | Any agent via `read_second_brain_project` and search |
| Research sources | Separate files in the project's `Sources` folder | `create_second_brain_research_source` | Search, and links from the project log |
| Work items (tasks) | `Work items` folder or the Second Brain Inbox | `capture_second_brain_work_item`, `organize_second_brain_work_item` | Task lists, the autonomous runner |
| Personal facts | `OpenAssist Memory.md` in the user's Drive | `remember_user_fact` (explicit user approval only) | `get_user_memory_context`, search |
| Imported agent memory | Read-only mirror of the local Claude and Codex memory folders | Desktop memory sync (`bin/openassist-memory-sync.mjs`) | Search only; never edited in Drive |
| Wiki index | `OpenAssist/Second Brain/.wiki` | Server (`refresh_second_brain_wiki`, hourly cron) | Humans browsing Drive |

The hosted Workspace server (Cloudflare Worker, D1) stores only pointers: file IDs, content hashes, revision numbers, and policy metadata. All text stays in Drive. Every returned text is untrusted data.

The local OpenAssist memory store (`oa_memory_*` tools) is the desktop app's own working memory. It is not synced and is not the same thing as personal facts. Rule of thumb: a durable fact about the user goes to `remember_user_fact`; project knowledge goes to the project log; everything else stays local.

## Project logs are section-first

A log is a set of sections. Each section starts with a marker line followed by a heading:

```markdown
<!-- oa-section:terminal-voice-picker -->
## terminal-voice-picker — New capability; picker tested, audio untested
- What: ...
- Retest trigger: ...
```

Rules:

- One section per topic or feature ID. Its heading ends with the current status so a reader can skim headings for the overview.
- Updates replace the section in place with `append_second_brain_project_log` plus `sectionKey`. Never add a dated block for the same topic.
- A `changelog` section is always last and holds one line per write (bounded to 100 lines). Older revisions live in `.history`, current plus three previous.
- Research sources are not pasted into the log. Creating a source adds one dated link line under the `sources` section automatically.
- Evidence must be reachable from any device: upload it as a source, do not record local Mac paths. The server returns a warning when it sees one.
- `rewrite_second_brain_project_log` is only for consolidation. It keeps the front matter, requires a reason, and refuses a body that shrinks below 10% of the previous one.
- A stale content hash error includes the current hash and revision so the caller re-reads once and retries.

Text before the first marker is a preamble and is left alone, so older logs keep working until they are consolidated.

## Work items are not a side effect

- "Upload", "save", "store", or "document" means one project log or one research source. Plans, checklists, and next-step tables stay inside that log.
- Work items exist only when the user asks for tasks or tracking, and never more than the user named. The server warns when a project receives five or more items in an hour.
- Every item has a lifecycle: `update_second_brain_work_item` moves it to backlog, ready, done, or cancelled and can add a dated note. Listings and the daily workspace hide done and cancelled items by default.
- An item with agent work attached (assigned, in progress, needs user) is closed through the run flow, not by hand.

## Reading as an agent

- `list_second_brain_projects` returns titles, so pick the project from the list instead of opening each one.
- For long logs, call `read_second_brain_project` with `outline: true` first, then `sectionKeys` for only the sections you need.
- Search results name the matching sections (`sections[].sectionKey`), so a search can lead straight to one section.
- Front-matter `status` is lifecycle only (active or archived). Whether agents may act on their own is `autonomy_mode`.

## Noise controls

- `list_second_brain_work_items` returns tasks only by default. Pass `contentKind: "research_note"` or `"all"` to see evidence files.
- Archived projects (`update_second_brain_project_policy` with `status: "archived"`) disappear from lists, search, and the runner queue unless `includeArchived` is set.
- Search covers projects, research sources, work items, and memory. On equal scores it prefers personal memory, then project logs, then sources, then tasks, then imported memory.
- The autonomous runner backs off while idle: it starts at the poll interval and doubles up to 15 minutes, then resets as soon as work is found. Stop and lock interrupt the wait.
- The desktop memory sync reports one manifest hash per source (Claude and Codex separately), so the server can tell which one changed. The wiki refresh runs only after a sync that uploaded something, at most 20 batches of 5, and the hourly server cron covers the rest.

## Where the code lives

- Server: `~/plugins/google-mail-hub/worker` (`src/second-brain.ts`, `src/mcp.ts`, `src/wiki.ts`, `src/history-retention.ts`). Not a git repository; each change keeps a `before` copy and logs under `artifacts/`.
- Desktop: `electron/memorySourceSync*.ts`, `electron/secondBrainAutonomousRunnerCore.ts`, `electron/secondBrainOwnerRunnerService.ts`, `electron/secondBrainWorkspaceBrokerClient.ts`, `bin/openassist-memory-sync.mjs`.
- Guards: `npm run verify:memory-source-sync`, `npm run verify:second-brain-runner`; server `npm test` and `npm run check`.
