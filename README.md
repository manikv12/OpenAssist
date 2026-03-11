<p align="center">
  <img src="Assets/AppLogo.png" alt="Open Assist" width="120" />
</p>

<h1 align="center">Open Assist</h1>

<p align="center">
  A macOS menu-bar dictation app that inserts text into your current app.<br/>
  Local-first speech, optional AI help, and simple setup.
</p>

<p align="center">
  <a href="https://github.com/manikv12/OpenAssist/releases"><img alt="Download" src="https://img.shields.io/github/v/release/manikv12/OpenAssist?label=Download&color=0f172a&style=flat-square" /></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-13.3%2B-blue?style=flat-square" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square" />
  <img alt="License" src="https://img.shields.io/github/license/manikv12/OpenAssist?style=flat-square" />
</p>

---

## What Open Assist Is

Open Assist is a menu-bar app for macOS.

You press a shortcut, speak, and Open Assist inserts the text into the app you are using right now. It is built for fast dictation, low friction, and local-first use.

Important behavior today:

- It runs as a menu-bar utility with no Dock icon.
- The menu-bar popover gives quick actions for dictation, history, AI Studio, and Settings.
- It can insert text directly, paste through a temporary clipboard, or fall back to typed keystrokes.
- It keeps recent transcript history on your Mac.
- It can learn from quick fixes you make after insertion.
- It supports both local and cloud-based speech/AI flows.

---

## Current Features

### Dictation

- **Apple Speech** with selectable recognition mode (`Local Only`, `Cloud Only`, `Automatic`)
- **Local `whisper.cpp`** with curated model downloads, Core ML support, and idle unload controls
- **Cloud transcription providers**:
  - OpenAI
  - Groq
  - Deepgram
  - Google Gemini (AI Studio)

### Text Insertion

- Direct Accessibility-based insertion when possible
- Privacy-friendly transient clipboard fallback when clipboard copy is off
- Optional "also copy transcript to system clipboard" mode
- Hold-to-talk and continuous dictation modes
- Paste last transcript shortcut
- Transcript history window with search, copy, delete, and reinsert actions

### AI Prompt Assistant

- Optional AI prompt correction before insertion
- Suggestion preview when auto-insert is not used
- Optional auto-insert for high-confidence suggestions
- Optional Markdown-preserving output for structured suggestions
- Rewrite provider options:
  - Ollama (local)
  - OpenAI
  - Anthropic
  - Google AI Studio (Gemini)
  - Groq
  - OpenRouter
- Built-in **AI Studio** for provider setup, model selection, timeouts, and conversation controls
- Rewrite style presets such as `Balanced`, `Formal`, `Casual`, `Architect`, and more
- OpenAI and Anthropic OAuth support, plus API-key support where needed

### Conversation and Memory Tools

- Optional conversation-aware rewrite history with timeout and turn-limit controls
- Pinned or automatic rewrite context selection in AI Studio
- Cross-IDE conversation sharing for matching coding contexts
- Context mappings and conversation inspection are available in AI Studio
- External memory indexing exists, but it is still behind the `OPENASSIST_FEATURE_AI_MEMORY=1` feature flag

### Quality-of-Life Features

- Adaptive corrections that learn from your edits
- Custom correction management
- Configurable sounds, waveform themes, and app chrome themes
- Sparkle-based update checks from the app

---

## Privacy Notes

- No account is required for local dictation
- No telemetry is enabled by default
- Settings, transcript history, and learned corrections stay on your Mac
- API keys and OAuth sessions are stored in macOS Keychain
- If you choose cloud transcription or cloud rewrite providers, your audio/text is sent to that provider
- Clipboard copying is off by default, so Open Assist tries to avoid leaving dictation in clipboard history
- Local crash logs stay on disk in `~/Library/Logs/OpenAssist/`

---

## Requirements

- macOS 13.3 or newer
- **Microphone** permission
- **Accessibility** permission for reliable insertion and global shortcuts
- **Speech Recognition** permission when using the Apple Speech engine

You may also need internet access for:

- cloud transcription
- cloud rewrite providers
- downloading `whisper.cpp` models
- local AI runtime/model setup
- app update checks

---

## Default Shortcuts

| Action | Default shortcut |
|---|---|
| Hold-to-talk | `⌥⌘Space` |
| Toggle continuous dictation | `⌃⌥⌘Space` |
| Paste last transcript | `⌥⌘V` |

All shortcuts can be changed in Settings.

---

## Quick Start

1. Download the latest release from [GitHub Releases](https://github.com/manikv12/OpenAssist/releases).
2. Open `Open Assist.app`.
3. Grant **Accessibility** and **Microphone** access when prompted.
4. If you use **Apple Speech**, also grant **Speech Recognition**.
5. Open **Settings** from the menu bar.
6. Choose your transcription engine:
   - `Apple Speech` for built-in system speech
   - `whisper.cpp` for fully local speech after model install
   - `Cloud Providers` for OpenAI/Groq/Deepgram/Gemini transcription
7. If you only want plain dictation, you can turn off **AI prompt correction** in **Settings -> AI & Models**.
8. If you want AI rewrite, open **AI Studio** and either:
   - connect a cloud provider, or
   - install local AI with the built-in Ollama setup flow

For a step-by-step walkthrough, see the [User Guide](Docs/User-Guide.md).

---

## Build From Source

### Prerequisites

- This repo is a **Swift Package Manager** macOS app
- Xcode 15+ or Apple developer tools with Swift 5.9 support
- Node/npm only if you want to create a DMG with `--make-dmg`
- A Developer ID certificate plus Apple notarization credentials only if you want a public signed release

### Main build

```bash
./build.sh
```

This creates:

- `dist/Open Assist.app`

What `build.sh` does today:

- Downloads `Vendor/Whisper/whisper.xcframework` automatically if it is missing
- Runs `swift build -c release`
- Bundles the app into `dist/Open Assist.app`
- Uses ad-hoc signing by default unless `DEVELOPER_ID` is set

### Useful build options

```bash
./build.sh --install
./build.sh --make-dmg
```

- `--install` copies the app to `/Applications/Open Assist.app`
- `--make-dmg` also creates `dist/Open Assist.dmg`
- `--install` also resets Accessibility permission, so you will need to grant it again after install

### Signed / distribution builds

```bash
export DEVELOPER_ID="Your Name (TEAMID)"
./build.sh --make-dmg
Scripts/notarize.sh
```

There is also a project-specific helper:

```bash
./build-local.sh --make-dmg
```

`Scripts/notarize.sh` notarizes `dist/Open Assist.dmg` and expects these environment variables:

- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

---

## Tests

Run package tests with:

```bash
swift test
```

Run the smoke/regression suite with:

```bash
Scripts/run-tests.sh
```

Run insertion reliability checks directly with:

```bash
Scripts/run-insertion-reliability.sh --regression
```

The repo also contains `XCTest` coverage for some conversation and settings behavior in `Tests/OpenAssistTests/`.

---

## Diagnostics

If insertion is not behaving the way you expect, you can enable insertion diagnostics:

- Turn it on in app settings, or set `OPENASSIST_INSERTION_DIAGNOSTICS=1`
- Default log path: `/tmp/openassist-insertion-diagnostics.log`
- You can override the log path with `OPENASSIST_INSERTION_DIAGNOSTICS_PATH`

Crash logs, when present, are stored locally at `~/Library/Logs/OpenAssist/crash.log`.

---

## Repo Layout

```text
Sources/OpenAssist/      App code
Resources/              Info.plist, icons, entitlements
Scripts/                Build, test, release, and utility scripts
Tests/OpenAssistTests/   XCTest coverage
Docs/                   User-facing docs
Wiki/                   Extra product notes
Vendor/Whisper/         Bundled whisper.cpp XCFramework
```

Main app areas:

- `Sources/OpenAssist/App.swift` wires the app lifecycle, menu bar, settings, and windows.
- `Sources/OpenAssist/Services/` contains transcription, insertion, AI, memory, and settings logic.
- `Sources/OpenAssist/Views/` contains SwiftUI screens such as the status popover and AI Studio.
- `Sources/OpenAssist/Support/` contains feature flags, permissions, and window helpers.

---

## Docs

- [User Guide](Docs/User-Guide.md)
- [Wiki Home](Wiki/Home.md)
- [Quick Start Wiki](Wiki/Quick-Start.md)
- [Privacy-First Design](Wiki/Privacy-First-Design.md)

---

## Current State Notes

- The app currently supports three speech paths: Apple Speech, local `whisper.cpp`, and cloud providers.
- AI Studio is already integrated and is the main place for rewrite provider setup and local AI setup.
- The advanced external memory-indexing workflow is present in the codebase, but it is still gated behind `OPENASSIST_FEATURE_AI_MEMORY=1`.
- The old README said the default build created both `.app` and `.dmg`; today, the default build creates the `.app`, and DMG creation is opt-in with `--make-dmg`.
