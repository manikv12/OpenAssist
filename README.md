# Open Assist

A macOS AI assistant with chat, voice, local or cloud models, and approved automation.



---

## Product Preview



The main assistant workspace with projects, threads, and the floating HUD.



Settings and AI Studio for providers, models, memory, and advanced controls.



The voice HUD for dictation, push-to-talk, and voice-first tasks.

## What It Does

Open Assist is a personal assistant for macOS. You can type, speak, run local or cloud models, and let the assistant take actions on your Mac after approval.

Main things it can do:

- chat in a full assistant workspace with projects and threads
- use voice for dictation, push-to-talk, or live voice conversations
- connect local or cloud AI providers
- run approved actions in browsers and supported macOS apps
- save thread notes, checkpoints, and memory
- schedule recurring tasks
- control the assistant remotely from Telegram
- generate images from the assistant

## Main Features

### Assistant workspace

- project-based conversations
- thread notes and checkpoints
- attachments, tool activity, and progress in one place
- plan mode and agentic mode

### Voice and dictation

- hold-to-talk and continuous dictation
- Apple Speech, `whisper.cpp`, or cloud speech providers
- live voice conversations with the assistant
- transcript history and quick paste of the last transcript

### AI providers

- local models
- OpenAI
- Anthropic
- Gemini
- Groq
- OpenRouter
- Ollama
- GitHub Copilot backend support

### Automation

- browser control with your real signed-in browser profile
- screenshot-based computer use
- direct app actions in Finder, Terminal, Calendar, System Settings, Reminders, Contacts, Notes, and Messages
- approval flow before important actions

### Extra tools

- custom and imported skills
- image generation
- scheduled jobs
- Telegram remote control
- Sparkle app updates

## Quick Start

1. Download the latest release from [GitHub Releases](https://github.com/manikv12/OpenAssist/releases).
2. Open `Open Assist.app`.
3. Open **Settings -> AI & Models -> AI Studio**.
4. Connect a provider or set up local AI.
5. Open the assistant and try a prompt.

Example prompts:

- `Help me write a short update for my team.`
- `Summarize these notes.`
- `Open Bluetooth settings.`

## Setup Guide

### 1. Assistant setup

1. Open **Settings -> AI & Models**.
2. Open **AI Studio**.
3. Choose a local or cloud provider.
4. Pick a model.
5. Save your API key or finish sign-in if needed.

### 2. Voice setup

1. Grant **Microphone** access.
2. Grant **Speech Recognition** if you use Apple Speech.
3. Grant **Accessibility** if you want reliable shortcuts and text insertion.
4. Open **Settings -> Speech & Input** and choose a speech engine.

### 3. Automation setup

1. Open **Settings -> Automation**.
2. Allow **Automation / Apple Events** when macOS asks.
3. Grant **Screen Recording** for screenshot-based computer use.
4. Choose a browser profile if you want browser automation.

### 4. Optional setup

- **Skills**: add built-in, local, or GitHub-based skills per thread
- **Scheduled Jobs**: run recurring prompts on a cron schedule
- **Telegram**: pair a bot to use Open Assist from your phone

## Default Shortcuts


| Action                      | Default shortcut                     |
| --------------------------- | ------------------------------------ |
| Hold-to-talk                | `Option + Command + Space`           |
| Toggle continuous dictation | `Control + Option + Command + Space` |
| Paste last transcript       | `Option + Command + V`               |


You can change these in Settings.

## Requirements And Permissions

### System requirements

- macOS 13.3 or newer
- Xcode 15+ if you want to build from source

### Permissions

- **Microphone**: voice input
- **Speech Recognition**: Apple Speech engine
- **Accessibility**: global shortcuts and direct text insertion
- **Screen Recording**: screenshot-based automation
- **Automation / Apple Events**: browser and app actions

## Privacy

- local use does not require an account
- no telemetry is enabled by default
- API keys and OAuth sessions are stored in macOS Keychain
- local settings, transcript history, and memory stay on your Mac
- if you use a cloud provider, your text or audio is sent to that provider

## Build From Source

### Build the app

```bash
./build.sh
```

This creates:

- `dist/Open Assist.app`

Run it with:

```bash
open "dist/Open Assist.app"
```

### Useful build options

```bash
./build.sh --install
./build.sh --make-dmg
```

- `--install` copies the app to `/Applications/Open Assist.app`
- `--make-dmg` also creates `dist/Open Assist.dmg`

### Signed distribution build

```bash
export DEVELOPER_ID="Your Name (TEAMID)"
./build.sh --make-dmg
Scripts/notarize.sh
```

`Scripts/notarize.sh` expects:

- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

## Tests

Run package tests:

```bash
swift test
```

Run smoke and regression scripts:

```bash
Scripts/run-tests.sh
```

Run insertion reliability checks:

```bash
Scripts/run-insertion-reliability.sh --regression
```

## Troubleshooting

If text insertion is not working as expected:

- turn on insertion diagnostics in app settings, or set `OPENASSIST_INSERTION_DIAGNOSTICS=1`
- default log path: `/tmp/openassist-insertion-diagnostics.log`
- optional custom log path: `OPENASSIST_INSERTION_DIAGNOSTICS_PATH`

Crash logs, when present:

- `~/Library/Logs/OpenAssist/crash.log`

Helpful docs:

- [User Guide](Docs/User-Guide.md)
- [Quick Start Wiki](Wiki/Quick-Start.md)
- [Troubleshooting Wiki](Wiki/Troubleshooting.md)

## Repo Layout

```text
Sources/OpenAssist/              Main app code
Sources/OpenAssistObjCInterop/   Objective-C interop helpers
Resources/                       Icons, plist, entitlements, assets
Scripts/                         Build, test, release, and helper scripts
Tests/OpenAssistTests/           XCTest coverage
Docs/                            User-facing docs
Wiki/                            Product and setup notes
Vendor/Whisper/                  Bundled whisper.cpp XCFramework
web/chat/                        React chat UI inside the assistant window
```

Good places to start:

- `Sources/OpenAssist/App.swift`
- `Sources/OpenAssist/Services/`
- `Sources/OpenAssist/Views/`
- `Sources/OpenAssist/Assistant/`

## More Docs

- [User Guide](Docs/User-Guide.md)
- [Wiki Home](Wiki/Home.md)
- [Why Open Assist](Wiki/Why-OpenAssist.md)
- [Privacy-First Design](Wiki/Privacy-First-Design.md)
