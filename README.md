# OpenAssist

OpenAssist is a voice-first personal AI assistant for macOS and iPhone. It keeps daily tasks, reminders, notes, projects, and AI agent work in one place.

## Daily Workspace and WebMCP

The new [`apps/workspace-site`](apps/workspace-site) is a professional browser workspace for Gmail, Tasks, Calendar, notes, memory, accounts, and activity. Its public demo gives each visitor a separate 24-hour synthetic Cloudflare workspace that judges can safely edit through the UI or WebMCP. Owner-only Live mode remains connected to the existing OpenAssist Workspace MCP and Composio; private Google data is never copied into Demo mode.

It exposes 23 structured WebMCP tools that ChatGPT's in-app browser and the same-page voice agent can use. Every write opens an exact, two-minute preview; destructive actions always require an on-screen tap. Private Google content is not copied into the Site database.

The voice gateway lives in [`apps/workspace-voice-gateway`](apps/workspace-voice-gateway). In Demo mode, a judge can use a short server-funded synthetic voice session or sign in with their own ChatGPT subscription inside a separate Cloudflare Container. Live mode remains owner-only. The server API key never enters the browser or a Container.

See [the architecture and security boundaries](docs/workspace-architecture.md) and [the focused challenge demo plan](docs/webmcp-challenge-demo.md).

> **Primary app:** The supported desktop app is now the React + Electron app in [`apps/desktop`](apps/desktop). The old Swift app is archived in [`legacy/swift`](legacy/swift).

## Why I Built It

Life moves fast. I had too many things to do, lost track of why decisions were made, and sometimes forgot work that had already happened.

I built OpenAssist as a daily organizer that I can talk to. It can remember useful context, keep projects organized, manage tasks and reminders, and hand real computer work to an AI agent when a simple answer is not enough.

## What Makes It Different

- **Live Voice coordinator:** Talk naturally through OpenAI Realtime or Gemini Live.
- **Real agent delegation:** Browser, CLI, repository, logs, and computer tasks can be handed to Codex, Claude, or another selected worker.
- **Conversation during work:** Voice chat stays available while delegated tasks run in the background.
- **Reliable results:** OpenAssist tracks each task, reports progress, returns the final answer, and avoids duplicate work.
- **Personal Knowledge:** Search notes, planner items, reminders, saved memory, and project history when Knowledge access is enabled.
- **Daily organization:** Manage Today, backlog, categories, projects, tasks, due dates, and timed reminders.
- **Notes and project continuity:** Keep long-running work connected to the right project and continue from earlier context.
- **Approval controls:** Important writes and computer actions still use the existing approval rules.
- **Global Live Voice:** A macOS shortcut can start the floating Live Voice HUD from any app.
- **Phone companion:** The iPhone app can view and update the same planner, notes, reminders, and voice workflows through the desktop bridge.

## GPT-5.6 Build Week Work

The desktop app includes **GPT-5.6 Sol**, **GPT-5.6 Terra**, and **GPT-5.6 Luna** as agent model choices. GPT-5.6 Sol was the daily driver for the real sessions behind this submission, including everything shown in the demo video.

Build Week work (July 13 onward), checked against the commit history and my Codex session logs:

- Made the React + Electron app the primary product and restructured the repository into `apps/desktop`, archiving the old Swift app under `legacy/swift`. The restructure itself was carried out by a Codex agent.
- Updated Live Voice for the new layout: the global shortcut flow, the floating HUD, the Agent Work shelf, and same-thread continuity.
- Built the demo from real sessions, recorded live: voice delegation to a Codex agent, and Computer Use opening TextEdit and typing a launch checklist by itself.
- Fixed reliability bugs found through real daily use: a cleanup routine that was killing live Computer Use helpers, silent empty turns caused by an outdated Codex CLI, and streamed thinking text rendering with dropped words.
- Used it for real work all week on GPT-5.6 Sol: planning notes with diagrams, research comparisons delegated from voice, reminder and memory recall, and filling a browser form through Computer Use.

The Live Voice engineering in this build includes one-owner voice turn routing, a shared task registry with progress, cancellation and duplicate protection, same-thread continuity without saving raw audio, Knowledge routing for notes, reminders, planner data and memory, and the Live Voice HUD with task cards and completion notifications.

OpenAI Realtime or Gemini Live handles the low-latency speech connection. GPT-5.6 is the work agent that reasons over the request and completes delegated tasks.

## How Codex Powers OpenAssist

OpenAssist runs the official **Codex app server** (`codex app-server`) as its agent engine:

- Chat turns and delegated agent jobs run through the app server, with GPT-5.6 (Sol, Terra, or Luna) as the reasoning model.
- **Computer Use** comes from Codex's bundled plugin. The agent can open Mac apps and do the work directly; the demo video shows it opening TextEdit and typing a launch checklist by itself, recorded live.
- Live Voice hands bigger requests to a Codex agent, keeps the conversation going while the job runs, and speaks the finished result back in the same session.
- Approvals, sandbox modes, and per-turn plugin selection all map onto the app server's own controls.

Codex was also part of the workflow behind the code: feature work, the repository restructure, and many of the regression scripts in this repo were developed with Codex agents.

## How Live Voice Works

```text
Your voice
  -> OpenAI Realtime or Gemini Live
  -> OpenAssist coordinator
       -> direct conversation
       -> assistant_capability -> exact local capability
       -> assistant_delegate_work -> genuine agent task
  -> one clear result in Today Live Voice
```

Both providers receive the same four-tool surface and use one reducer-owned turn state. Stopping Live Voice closes the microphone and realtime connection. Background work can finish safely, save one FIFO result, and notify you without creating extra visible threads.

## Quick Start

Requirements:

- macOS 13.3 or newer
- Node.js 20.19 or newer, or Node.js 22.12 or newer
- Xcode Command Line Tools for the small macOS helper binaries

From the repository root:

```bash
npm run setup
npm run dev
```

Build the desktop app:

```bash
npm run build
```

Package a macOS app:

```bash
npm run package:mac
```

## Verify Live Voice

Run the complete Live Voice regression set:

```bash
npm run verify:live-voice
```

Run the desktop build and the Live Voice checks together:

```bash
npm run verify
```

The checks cover coordinator state, capability selection, delegation, task limits, progress, cancellation, continuity, recall, echo protection, identical provider contracts, and exactly-one final-result delivery.

## Repository Layout

```text
apps/desktop/                                  Primary React + Electron macOS app
companion-projects/OpenAssist-Mobile-Remote/   iPhone companion app
legacy/swift/                                  Deprecated Swift implementation
```

Start with:

- [`apps/desktop/src/App.tsx`](apps/desktop/src/App.tsx) for the React interface
- [`apps/desktop/electron/main.ts`](apps/desktop/electron/main.ts) for Electron and macOS integration
- [`apps/desktop/electron/openassistBridge.ts`](apps/desktop/electron/openassistBridge.ts) for app data and agent workers
- [`apps/desktop/electron/liveVoice/`](apps/desktop/electron/liveVoice/) for the shared Live Voice coordinator, reducer, capability registry, provider adapters, outbox, and trace
- [`apps/desktop/electron/realtimeProxy.ts`](apps/desktop/electron/realtimeProxy.ts) for Live Voice transport and composition
- [`apps/desktop/electron/realtimeTaskCoordinator.ts`](apps/desktop/electron/realtimeTaskCoordinator.ts) for delegated-task tracking
- [`apps/desktop/docs/live-voice-architecture-plan.md`](apps/desktop/docs/live-voice-architecture-plan.md) for the implemented architecture and invariants

## Privacy

- OpenAssist does not save raw Live Voice audio.
- Completed voice text is stored in the existing `Today Live Voice` log.
- Knowledge access remains permission-controlled and is never enabled silently.
- API keys and provider sessions use the existing macOS Keychain paths.
- Local data stays under `~/Library/Application Support/OpenAssist` unless a cloud provider is selected.

## Repository Media

Generated screenshots, capture folders, and submission videos are intentionally ignored by Git. Required app icons, provider marks, and runtime UI assets remain tracked so a fresh clone still builds.

## Deprecated Swift App

The Swift implementation is kept only as historical reference. It is not built by the main release workflow and should not be used for judging or new feature work. See [`legacy/swift/README.md`](legacy/swift/README.md).
