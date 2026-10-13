# OpenAssist Workspace Interactive

A new interactive plugin package for the existing OpenAssist Workspace service.

## Status

October 3, 2026: Worker 2.12.3 adds direct checklist completion. A task checkbox
opens confirmation immediately; its title opens details. Cancel and failed saves
keep the task open. The deployed checkbox and Cancel flow were checked in ChatGPT
without completing a real task. All 271 backend tests, 35 browser checks, type
checks, and the build passed. Existing UI resource aliases remain available.

October 2, 2026 (Pacific): Worker 2.12.2 fixes "App unavailable" for cached ChatGPT
launchers. Older UI resource addresses v1 through v4 now resolve to the current
interface. The actual failed v3 request was verified returning HTTP 200 after
deployment, with `Connected · v2.12.2`, live Today data, and working navigation in
Brave. Validation passed: 271 backend tests, 31 isolated browser checks, type
checks, and the Worker build. No new package upload, connection, or permissions
were required. Deployment ID: `0be3a7e3-cf58-451a-97d8-cf34688f1e6a`.

Earlier release history:

Worker release 2.11.3 deployed on October 1, 2026. Production health confirms the version and authentication remains required. Deployment ID: `658126ef-d7e0-41d8-8a87-421ed2e0d92a`.

The existing ChatGPT app's tool catalog has been refreshed and its real interactive screen verified in Brave. ChatGPT now registers 76 tools: 35 read tools and 41 write tools, including `open_workspace`, project browsing, and both project-history tools. This change has not been submitted for public review or published as a new plugin registration.

Private package version 1.2.0 was uploaded to the existing ChatGPT plugin after its tool refresh. ChatGPT confirmed "New version uploaded" and displayed the professional description, starter prompts, full-color logo, and an "Open plugin" button. The original internal plugin name, registered app mapping, connected account, and browser extension permissions were preserved.

The menu-symbol fix was verified in the real Brave Explore menu after the 2.11.3 tool refresh. ChatGPT loaded a new cached icon asset and rendered the OpenAssist M/node symbol instead of a white square. The menu is monochrome by host design, while the directory and workspace retain the full-color logo.

After that refresh regenerated generic listing metadata, private package 1.2.1 was uploaded again. ChatGPT confirmed "New version uploaded"; the original listing logo, descriptions, developer, category, connected account and Open plugin button were restored. The menu still used the correct transparent symbol. Opening the plugin then confirmed Connected · v2.11.3 and loaded the latest Today interface. Live checks remained read-only.

The October 1 read-only live check in Brave verified the new compact interface, backend 2.11.0, current Today results with an incomplete-coverage warning, and all four existing project cards. No mail, task, calendar, project, or memory data was changed. This verifies the standalone ChatGPT app surface in Brave, not native desktop or conversation-inline rendering.

The global Explore menu alpha-masks its entrypoint tool icon. The `open_workspace` tool had no `icons`, so ChatGPT fell back to the app's opaque full-color logo and rendered a solid square. Updating the package alone did not fix that fallback. Worker 2.11.3 advertises the transparent symbol directly on `open_workspace.icons`, using the public versioned URL `/openassist-menu-icon-v1.png` and following OpenAI's documented tool-icon priority. The existing full-color server, listing and in-workspace logos remain unchanged.

Package 1.2.1 also uses the transparent `assets/openassist-menu-icon.png` for `composerIcon`, while `logo` still points to the original full-color asset. The new asset was checked at 256 by 256 pixels, with transparent corners and 43,116 fully transparent pixels. It was created with the built-in image tool by removing the dark background from the existing symbol, then resized to 256 pixels. The original logo was not overwritten. The canonical Worker embeds the same menu asset from `ui/openassist-menu-icon.png`; the build checks its RGBA format and the MCP catalog regression test verifies it is advertised on the opener.

Earlier September 30 read-only verification of backend 2.10.0: Codex Feature Research showed current revision 36 and retained revisions 35, 34, and 33. Revision 35 opened and compared with current revision 36, with a visible 60,000-character display/comparison limit. No project revision was restored or changed. Native desktop testing was unavailable because computer use was blocked for that app.

For private package 1.2.1, the ZIP contains `plugin.json`, `.app.json`, the full-color logo and the transparent menu icon. It references the existing registered app only. The standalone `mcp.json` is not included in that ZIP, to avoid adding another connection.

Verified locally on October 1, 2026: 269 backend tests, 31 isolated browser checks, TypeScript checks, and a Worker deployment dry run. Light Today and dark Accounts screenshots were inspected. These checks use synthetic data and do not replace real ChatGPT verification.

The package reuses the existing registered ChatGPT connection. It does not create a second ChatGPT registration or duplicate users' Google accounts. The production endpoint includes the new interface, and the existing ChatGPT registration now discovers it. Older conversations may need a fresh thread to pick up the refreshed tools.

## Experience

- **Today:** fresh mail attention, open tasks, calendar, source-account labels, and clear incomplete checks.
- **Projects:** readable project titles and sections, controlled section editing, separate research/task saves, and read-only revision history with current-version comparison.
- **Search:** saved knowledge with original source links.
- **Accounts:** service access and existing saved defaults, plus a link to the account manager.

The component uses the open MCP Apps bridge and optional ChatGPT compatibility features. It works inline, fullscreen, from global navigation, or beside a conversation when the host supports those surfaces. Other clients keep the existing text tools.

## Source and verification

The canonical backend is `/Users/manikvashith/plugins/google-mail-hub/worker`.

The UI source is `worker/ui/workspace.html`, embedded by `npm run build:workspace-ui`.

Before release, run in the Worker directory:

```sh
npm test
npm run check
npm run build
npm run test:workspace:browser
```

`npm run preview:workspace` opens a local sample-data host. It makes no Google requests and never changes live data. This preview tests appearance and interactions, not real ChatGPT acceptance.

## Release steps

1. Review the local interface and approve the production release.
2. Deploy the Worker after all tests pass. No new database schema or Google scopes are required.
3. Refresh the existing registered ChatGPT app's tool catalog.
4. Verify the interface in a real ChatGPT conversation and sidebar. Confirm OAuth, read calls, user-approved writes, and readback using a disposable test item.
5. Configure and verify a dedicated app UI domain before formal submission. The local release does not provision a new domain.
6. Submit or publish the plugin only with separate approval. This portable package follows the current official plugin format; local packaging alone does not publish a ChatGPT plugin.

## Safety

- Private content is received only through the authenticated host's tools. The static template has no credentials or real personal data.
- Project and research content remains Markdown in the existing project's Drive account. UI state is temporary, not another copy of the user's notes.
- Handled or ignored mail is separate from Gmail read state and task completion.
- Edits carry the current hash or attention revision. A conflicting update stops the save and preserves the draft.
- Project history shows current and retained indexed versions, not every version ever created. Deleted or unindexed older files may be absent. Changed and partly readable files are clearly marked; viewing or comparing never restores, deletes, backfills, or changes retention.
- No generic send, share, delete, purchase, external-action execution, or automatic personal-memory save is exposed to component buttons.
- Research sources stay separate from tasks. Repeated saves reuse the server's existing safeguards.

Official references: [MCP UI](https://developers.openai.com/plugins/build/chatgpt-ui), [plugin extensions](https://developers.openai.com/plugins/build/extensions), and [packaging](https://developers.openai.com/plugins/build/plugins).

Entrypoint icon requirements and priority: [OpenAI MCP extensions icon guidelines](https://github.com/openai/mcp-extensions/blob/main/docs/spec.md#icon-guidelines).
