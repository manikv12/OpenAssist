# OpenAssist

OpenAssist is a voice-first personal AI assistant for macOS and iPhone. It keeps daily tasks, reminders, notes, projects, and AI agent work in one place.

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

The desktop app includes **GPT-5.6 Sol**, **GPT-5.6 Terra**, and **GPT-5.6 Luna** as agent model choices.

The GPT-5.6 implementation work in this build includes:

- the Live Voice coordinator and one-owner voice turn routing
- reliable background delegation with one shared task registry
- progress, cancellation, final-result delivery, and duplicate protection
- same-thread Live Voice continuity without saving raw audio
- Knowledge routing for notes, reminders, planner data, and memory
- agent routing for browser, CLI, code, logs, and computer work
- project creation, note updates, reminders, and mobile parity improvements
- the professional Live Voice HUD, task cards, provider labels, and completion notifications

OpenAI Realtime or Gemini Live handles the low-latency speech connection. GPT-5.6 is the work agent that can reason over the request and complete delegated tasks.

## How Live Voice Works

```text
Your voice
  -> OpenAI Realtime or Gemini Live
  -> OpenAssist coordinator
       -> direct conversation
       -> OpenAssist Knowledge
       -> delegated GPT-5.6 / Codex / Claude task
  -> one clear result in Today Live Voice
```

Stopping Live Voice closes the microphone and realtime connection. Background work can finish safely, save one result, and notify you without creating extra visible threads.

## Quick Start

Requirements:

- macOS 13.3 or newer
- Node.js 22 or newer
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

The checks cover routing, delegation, task limits, progress, cancellation, continuity, recall, echo protection, provider protocol behavior, and final-result narration.

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
- [`apps/desktop/electron/realtimeProxy.ts`](apps/desktop/electron/realtimeProxy.ts) for Live Voice coordination
- [`apps/desktop/electron/realtimeTaskCoordinator.ts`](apps/desktop/electron/realtimeTaskCoordinator.ts) for delegated-task tracking
- [`apps/desktop/docs/live-voice-architecture-plan.md`](apps/desktop/docs/live-voice-architecture-plan.md) for the architecture plan

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
