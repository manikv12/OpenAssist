# Devpost Submission Draft

## Project name

OpenAssist Daily Workspace

## One-line description

A visible daily workspace where people and agents safely handle mail attention, tasks, calendar, notes, memory, and supplies together through 29 WebMCP tools.

## Project description

### Why I built it

Daily information is spread across inboxes, task lists, calendars, notes, and shopping sites. A chat agent can summarize those systems, but people can easily lose track of what it read, which item it means, or what it is about to change.

I built OpenAssist Daily Workspace so the person and the agent share one visible place. The agent can understand and navigate the workspace while the person sees the exact card, preview, approval, and verified result.

### What it does

The Site brings together unread attention mail, tasks, calendar events, notes, memory, accounts, activity, and a synthetic Shopify supply catalog. ChatGPT can use 29 page-registered WebMCP tools to:

- build a daily brief and focus the item being discussed;
- search and read synthetic mail, attachments, tasks, calendar, notes, and memory;
- search a live synthetic Shopify development-store catalog and return product images;
- propose tasks, events, notes, memory updates, mail read-state changes, and cart updates; and
- navigate the visible interface so the person always sees where the agent is working.

Reads run immediately. Every write opens an exact, signed two-minute preview. Destructive actions always require an on-screen tap. Approved changes execute once, are read back, highlighted, and recorded in Activity.

### Why this is a strong WebMCP use case

Without WebMCP, an agent must guess through changing layouts or work invisibly through a separate backend. Here, the Site describes the actions directly with structured schemas and safety annotations. The same action changes the visible page, so the agent and person stay in the same context.

This makes the app meaningfully better for both sides: the agent is faster and more reliable, while the person keeps orientation and control. The Shopify story also shows cross-context reasoning: an urgent security item can lead to a product search, but the cart cannot change until the person approves the exact proposal.

### How I built it

The ChatGPT Site calls `document.modelContext.registerTool` for every tool. One registry defines the schema, description, safety flags, Demo executor, and owner Live mapping. Read tools use `readOnlyHint`; tools returning mail, attachments, Drive, or website text use `untrustedContentHint`.

Cloudflare D1 stores each judge's isolated synthetic workspace for 24 hours. A Cloudflare Worker handles signed approvals, duplicate protection, and the optional voice gateway. The synthetic Shopify catalog returns real development-store product data and images, but no checkout, payment, or order tool exists.

Owner Live mode maps the same visible actions to the existing OpenAssist Workspace MCP and Composio-managed Google connections. Real Google content is never copied into the judge database.

### What is new for this challenge

OpenAssist existed before August 25, 2026. The Daily Workspace is the new challenge extension: the ChatGPT Site, 29 WebMCP tools, isolated judge data, visible approval system, Shopify catalog/cart scenario, Activity audit view, and voice-to-visible-tool bridge were all added during the submission period. The repository history and readiness document show the dated boundary.

### Challenges and lessons

The hardest part was not registering tools; it was keeping the human-agent boundary clear. External content must be useful without becoming instructions. Writes must be easy to approve without being easy to spoof or replay. Demo and Live data must never mix. Building one shared registry for browser and voice tools made those rules consistent.

### What is next

After the challenge, I want to add more owner-controlled integrations while keeping the same visible focus, untrusted-content handling, exact previews, and verified results.

## Links

- Live Site: <https://openassist-daily-workspace.developingadventures.chatgpt.site/>
- Public source: <https://github.com/manikv12/OpenAssist>
- License: MIT
- Judge guide: <https://github.com/manikv12/OpenAssist/blob/main/docs/webmcp-judge-guide.md>
- Architecture: <https://github.com/manikv12/OpenAssist/blob/main/docs/workspace-architecture.md>
- Test report: <https://github.com/manikv12/OpenAssist/blob/main/docs/webmcp-test-report.md>

## Built with

WebMCP, ChatGPT Sites, React, TypeScript, Cloudflare Workers, D1, R2, Containers, OpenAI Realtime, Codex App Server, Shopify, MCP, Composio, Gmail, Google Tasks, Google Calendar, and Google Drive.

## Private testing instructions for Devpost

Paste the following into Devpost's private credential/testing field. Replace the two placeholders there; never commit the real access code.

```text
Open the live URL in ChatGPT's in-app browser, or Chrome 149+ with chrome://flags/#enable-webmcp-testing enabled.

Username: JUDGE_USERNAME
Access code: JUDGE_ACCESS_CODE

No Google login, API key, payment method, or Shopify checkout is required. This account opens only an isolated synthetic Demo workspace.

Recommended test:
1. Ask: “Show my daily brief and focus the most urgent unread message.”
2. Ask: “Find a USB-C Security Key and prepare one in the cart.”
3. Review and approve the visible preview.
4. Open Activity and confirm the verified result appears once.
5. Use Reset demo when finished.

Funded voice is optional. If the UI says it is unavailable, use ChatGPT's browser agent; all 29 WebMCP tools remain testable.
```

## Screenshot list

1. Private access screen with no workspace data visible.
2. Today view with the WebMCP quick start and focused urgent message.
3. Shopify result showing the USB-C Security Key image and price.
4. Exact approval preview over the still-visible workspace.
5. Verified cart result and Activity entry.
6. Optional floating voice agent with visible transcript and workspace navigation.
