<p align="center">
  <img src="Assets/OpenAssistLogo.svg" alt="Open Assist" width="120" />
</p>

<h1 align="center">Open Assist</h1>

<p align="center">
  An AI assistant for macOS with voice, local-first options, and approved automation.<br/>
  Use typed or spoken prompts, connect local or cloud models in AI Studio, and optionally insert text into your current app.
</p>

<p align="center">
  <a href="https://github.com/manikv12/OpenAssist/releases"><img alt="Download" src="https://img.shields.io/github/v/release/manikv12/OpenAssist?label=Download&color=0f172a&style=flat-square" /></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-13.3%2B-blue?style=flat-square" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square" />
  <img alt="License" src="https://img.shields.io/github/license/manikv12/OpenAssist?style=flat-square" />
</p>

---

## Open Assist At A Glance

Open Assist is a personal AI assistant for macOS.

It is built to help you do real work on your Mac:

- ask questions or give tasks with text or voice
- draft, rewrite, and polish text
- keep using local models if you want more privacy
- use cloud models if you want faster setup or different capabilities
- let the assistant take approved actions in your browser or supported apps
- use voice capture and dictation when speaking is faster than typing

The menu bar is how you open it quickly. The assistant is the product.

---

## Three Ways To Use Open Assist

### 1. Ask

Use Open Assist like your everyday assistant.

You open the assistant, type or speak a request, and continue the conversation until the result is useful.

Common examples:

- "Summarize these notes."
- "Rewrite this message to sound more professional."
- "Help me plan my day."
- "Draft a reply to this email."

### 2. Speak

Use voice when talking is faster than typing.

Open Assist can:

- take a spoken assistant task
- transcribe speech into your current app
- keep recent transcript history
- let you paste your last transcript again

This is useful when you want fast text input without switching apps.

### 3. Act

Use Open Assist in agentic mode when you want it to do work on your Mac with your approval.

It can help with:

- browser tasks using your signed-in local browser profile
- direct app actions in Finder, Terminal, Calendar, System Settings, Reminders, Contacts, Notes, and Messages

Examples:

- "Open my project board in Chrome."
- "Reveal the Downloads folder in Finder."
- "Create a calendar event draft for tomorrow at 3 PM."

---

## Setup In 5 Minutes

If you want the main product experience, start here.

1. Download the latest release from [GitHub Releases](https://github.com/manikv12/OpenAssist/releases).
2. Open `Open Assist.app`.
3. Open **Settings -> AI & Models -> AI Studio**.
4. Connect a cloud provider or set up local AI.
5. Open the assistant and try a simple request.

Example first prompt:

- "Help me write a short update for my team."

### Choose the setup you need

| Goal | Open this | What to do |
|---|---|---|
| Use the assistant | `Settings -> AI & Models` and `AI Studio` | Connect a provider, choose a model, and start chatting. |
| Speak to the assistant or dictate text | `Settings -> Speech & Input` | Pick a speech engine and grant the needed permissions. |
| Let the assistant control browser or apps | `Settings -> Automation` | Allow `Automation / Apple Events` and choose a browser profile if needed. |

---

## How To Set Up Open Assist

### 1. Assistant setup

This is the most important setup.

1. Open **Settings -> AI & Models**.
2. Open **AI Studio**.
3. Choose how you want to run AI:
   - local AI through Ollama or the built-in local AI setup flow
   - or a cloud provider such as OpenAI, Anthropic, Gemini, Groq, or OpenRouter
4. Choose a model.
5. Save your API key or finish OAuth sign-in if your provider needs it.
6. Open the assistant and test a real request.

Simple examples:

- If you want local AI and no API key, start with the local AI setup in **AI Studio**.
- If you already use OpenAI or Anthropic, connect that provider and pick your preferred model.

### 2. Voice and dictation setup

Set this up if you want spoken prompts or speech-to-text.

1. Grant **Microphone** when macOS asks.
2. If you want to use **Apple Speech**, also grant **Speech Recognition**.
3. If you want direct insertion and reliable global shortcuts, grant **Accessibility**.
4. Open **Settings -> Speech & Input**.
5. Choose your speech engine:
   - `Apple Speech` for the fastest setup
   - `Whisper.cpp` for local transcription after model install
   - `Cloud Providers` for services like OpenAI, Groq, Deepgram, or Gemini
6. If you choose **Whisper.cpp**, open **Whisper Model Install** and:
   - download a model such as `tiny`, `base`, or `small`
   - pick the active model
   - optionally enable Core ML if your Mac supports it
7. Test a voice shortcut or speak a task to the assistant.

### 3. Automation setup

Set this up if you want the assistant to take actions on your Mac.

1. Open **Settings -> Automation**.
2. Allow **Automation / Apple Events** when macOS prompts you.
3. If you want browser control, choose a profile for Google Chrome, Brave, or Microsoft Edge.
4. Open the assistant in **Agentic** mode and try a simple task.

Simple examples:

- "Open Bluetooth settings."
- "Show my Downloads folder."
- "Create a reminder for tomorrow."

---

## How To Use Open Assist Day To Day

### For normal assistant tasks

1. Open Open Assist from the menu bar.
2. Choose **Open Assistant** or a voice-first entry point.
3. Type or speak your request.
4. Review the result.
5. Ask a follow-up if you want to refine it.

### For quick dictation

1. Click into any text field.
2. Hold `Option + Command + Space`.
3. Speak naturally.
4. Release to insert text.

### For automation tasks

1. Open the assistant in **Agentic** mode.
2. Ask for the task in simple words.
3. Approve the action if Open Assist asks.
4. Review the result.

---

## Default Shortcuts

| Action | Default shortcut |
|---|---|
| Hold-to-talk | `Option + Command + Space` (`⌥⌘Space`) |
| Toggle continuous dictation | `Control + Option + Command + Space` (`⌃⌥⌘Space`) |
| Paste last transcript | `Option + Command + V` (`⌥⌘V`) |

You can change all shortcuts in Settings.

---

## Requirements And Permissions

### System requirements

- macOS 13.3 or newer

### Permissions by feature

- **Microphone**: needed for spoken assistant tasks and dictation
- **Accessibility**: needed for direct insertion and reliable global shortcuts
- **Speech Recognition**: only needed for the Apple Speech engine
- **Automation / Apple Events**: needed for browser or direct app actions

Typed assistant use can work without microphone or dictation setup.

### Internet is only needed for some features

- cloud AI providers
- cloud transcription
- downloading `whisper.cpp` models
- local AI runtime/model setup
- app update checks

---

## Privacy Notes

- No account is required for local use
- No telemetry is enabled by default
- Settings, transcript history, and learned corrections stay on your Mac
- API keys and OAuth sessions are stored in macOS Keychain
- If you choose cloud providers, your audio or text is sent to that provider
- Clipboard copying is off by default to reduce clipboard history leakage

---

## Build From Source

Use this if you want to run or modify the project yourself.

### Prerequisites

- Xcode 15+ or Apple developer tools with Swift 5.9 support
- macOS 13.3 or newer
- Node/npm only if you want to make a DMG with `--make-dmg`
- A Developer ID certificate and Apple notarization credentials only if you want a public signed build

### Main build

```bash
./build.sh
```

This creates:

- `dist/Open Assist.app`

Run it with:

```bash
open "dist/Open Assist.app"
```

What `build.sh` does:

- downloads `Vendor/Whisper/whisper.xcframework` automatically if it is missing
- runs `swift build -c release`
- bundles the app into `dist/Open Assist.app`
- uses ad-hoc signing by default unless `DEVELOPER_ID` is set

### Useful build options

```bash
./build.sh --install
./build.sh --make-dmg
```

- `--install` copies the app to `/Applications/Open Assist.app`
- `--make-dmg` also creates `dist/Open Assist.dmg`
- `--install` resets Accessibility and Automation permissions, so macOS will ask again later

### Signed distribution build

If you have a Developer ID certificate and want a signed DMG:

```bash
export DEVELOPER_ID="Your Name (TEAMID)"
./build.sh --make-dmg
Scripts/notarize.sh
```

`Scripts/notarize.sh` expects these environment variables:

- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

There is also a repo-specific convenience helper:

```bash
./build-local.sh --make-dmg
```

Use that helper only if the signing identity inside the script matches your machine.

---

## Tests

Run package tests:

```bash
swift test
```

Run the smoke and regression scripts:

```bash
Scripts/run-tests.sh
```

Run insertion reliability checks directly:

```bash
Scripts/run-insertion-reliability.sh --regression
```

The repository also includes `XCTest` coverage in `Tests/OpenAssistTests/`.

---

## Diagnostics And Troubleshooting

If text insertion is not working the way you expect:

- turn on insertion diagnostics in app settings, or set `OPENASSIST_INSERTION_DIAGNOSTICS=1`
- default log path: `/tmp/openassist-insertion-diagnostics.log`
- optional custom log path: `OPENASSIST_INSERTION_DIAGNOSTICS_PATH`

Crash logs, when present, are stored at:

- `~/Library/Logs/OpenAssist/crash.log`

If you need more help:

- Start with the [User Guide](Docs/User-Guide.md)
- See the [Quick Start wiki](Wiki/Quick-Start.md)
- Check the [Troubleshooting wiki](Wiki/Troubleshooting.md)

---

## Repo Layout

```text
Sources/OpenAssist/       Main app code
Sources/OpenAssistObjCInterop/ Objective-C interop helpers
Resources/               Info.plist, icons, entitlements
Scripts/                 Build, test, release, and utility scripts
Tests/OpenAssistTests/   XCTest coverage
Docs/                    User-facing docs
Wiki/                    Extra product notes
Vendor/Whisper/          Bundled whisper.cpp XCFramework
```

Useful places to start:

- `Sources/OpenAssist/App.swift`: app lifecycle, windows, and app-level wiring
- `Sources/OpenAssist/Services/`: transcription, insertion, AI, settings, and automation logic
- `Sources/OpenAssist/Views/`: SwiftUI views such as Settings and AI Studio
- `Sources/OpenAssist/Assistant/`: assistant workflows and automation behavior

## Advanced Notes

- AI memory indexing exists, but it is still behind the `OPENASSIST_FEATURE_AI_MEMORY=1` feature flag.
- The main product story is assistant first, while voice, dictation, and automation are important supporting features.

---

## More Docs

- [User Guide](Docs/User-Guide.md)
- [Wiki Home](Wiki/Home.md)
- [Quick Start Wiki](Wiki/Quick-Start.md)
- [Why Open Assist](Wiki/Why-OpenAssist.md)
- [Privacy-First Design](Wiki/Privacy-First-Design.md)
