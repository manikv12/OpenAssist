# WebMCP Challenge Readiness

This file maps OpenAssist Daily Workspace to the [official Devpost rules](https://webmcp.devpost.com/rules) and the [OpenAI challenge description](https://openai.com/webmcp-challenge/).

## Judge path

1. Open <https://openassist-daily-workspace.developingadventures.chatgpt.site/> in ChatGPT's in-app browser or Chrome 149+ with WebMCP enabled.
2. Sign in with the private judge username and access code provided in the submission. No API key or Google connection is required.
3. Ask the browser agent to get the daily brief, focus an urgent message, open a synthetic note or attachment, search the live synthetic Shopify catalog, or prepare a cart.
4. Read actions run immediately. A write opens a locked two-minute preview. Delete, trash, and forget always need an on-screen tap.
5. Each judge receives separate synthetic data and a separate Shopify cart pointer that expire after 24 hours.
6. The owner can optionally enable a short funded voice demo. The key remains server-side; if it is disabled, the judge receives a clear unavailable message and can still test every browser WebMCP flow.

The owner-only **Live** mode is not part of judge access and contains no judge credentials.

## Existing work versus challenge work

OpenAssist existed before the challenge. The Daily Workspace/WebMCP layer is a meaningful new extension created after the August 25, 2026 start.

| Commit | Date | New challenge work |
| --- | --- | --- |
| `a175cfa` | Aug 10 | Pre-challenge OpenAssist baseline |
| `aff7044` | Aug 27 | Daily Workspace, initial WebMCP tools, Sites app, and voice gateway |
| `a553ef3` | Aug 27 | Isolated, persistent, expiring synthetic judge workspaces |
| `0816031` | Aug 27 | Secure subscription voice gateway |
| `a699ff3` | Aug 27 | Voice-to-visible-Workspace tool bridge |
| `d9fd80a` | Aug 27 | Saved and resumable voice conversations |
| `d10ddb9` | Aug 27 | Per-judge isolated voice access |
| `c30d019` | Aug 27 | Professional OpenAssist visual and voice feedback |
| `60a9587` | Aug 28 | Private, rate-limited judge sign-in and isolated access |
| `04b1e07` | Aug 28 | Shopify catalog, product images, policy reads, and approval-bound cart tools |
| `d208566` | Aug 29 | Correct live attachment and calendar routing |
| `44b759e` | Aug 29 | Safe attachment reads when Composio rotates opaque references |

The implementation uses `document.modelContext.registerTool` directly in `apps/workspace-site/app/components/workspace-app.tsx`. It is not only an MCP proxy: every tool is tied to visible UI focus, synthetic or live data, an activity record, and the same approval flow used by the voice agent.

## Rule mapping

- **Live URL:** hosted Site above, available to judges through private review credentials supplied with the submission.
- **Public source and license:** <https://github.com/manikv12/OpenAssist>, MIT license.
- **WebMCP source:** the public repository contains all tool definitions, schemas, annotations, executors, UI, and setup instructions.
- **Existing-app extension:** the dated commit table clearly separates the earlier app from the post-start WebMCP work.
- **Authorized integrations:** public judging uses owned synthetic data. Private Google access stays owner-only through existing Composio connections.
- **Privacy:** Demo and Live routes are separate. Real email, attachments, tasks, calendar text, notes, memory, audio, and transcripts are not copied into the Site database or logs.
- **Safety:** external content is marked untrusted, shown as plain text, and cannot approve or trigger another tool. Writes are exact, short-lived, idempotent, confirmed, and read back.
- **Video:** record a public YouTube video under three minutes with clear audio, a functioning WebMCP flow, no private content, and no unlicensed material.
- **Freeze after deadline:** after September 3, 2026 at 1:00 PM Pacific, do not change the Devpost entry, public repository, or live Site during judging.

## Submission text draft

### Why WebMCP fits

OpenAssist Daily Workspace is a visual daily organizer for mail attention, tasks, calendar, notes, and memory. WebMCP lets the browser agent use the same structured actions a person sees on the page instead of guessing through clicks.

### How it improves the experience

The agent can gather a daily brief, focus the exact card it is discussing, read synthetic attachments and notes, search a live synthetic Shopify catalog with product images, and prepare a task, event, or cart while the person stays oriented in the visible workspace. Every change is previewed before saving, and destructive actions need a screen tap.

### What people and agents do together

People browse, search, inspect, approve, and organize. Agents can call 29 WebMCP tools for the same workspace. The same registry also powers the optional voice agent, so a spoken request highlights or updates the same visible interface.

### How it was built

The ChatGPT Site registers the tools with `document.modelContext.registerTool`. Signed-in judges use isolated synthetic records stored in Cloudflare D1. Owner Live mode maps the same tools to the existing OpenAssist Workspace MCP and Composio. Read tools are marked read-only and external content is marked untrusted. Write requests use signed previews, a two-minute expiry, idempotency keys, and read-back verification.

## Remaining external submission items

- Record and upload the final public YouTube video under three minutes.
- Add the public Site URL, repository URL, video URL, screenshots, and submission text to Devpost.
- Make the repository license visible in GitHub's About panel.
- Put the judge username and access code only in Devpost's private testing instructions, then test them once in a clean browser session.
- Submit before September 3, 2026 at 1:00 PM Pacific.

Current validation evidence is recorded in [`webmcp-test-report.md`](webmcp-test-report.md).
