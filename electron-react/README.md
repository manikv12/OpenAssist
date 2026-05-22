# OpenAssist Electron React Port

This folder contains the React + Electron port of the OpenAssist assistant window.

It is kept inside the main OpenAssist repo so the native app and Electron port stay together.

## What It Uses

- React renderer in `src/`
- Electron main/preload code in `electron/`
- Native OpenAssist app icon copied to `icon.icns`
- Real OpenAssist data under `~/Library/Application Support/OpenAssist`
- Real macOS defaults from `com.developingadventures.OpenAssist`
- Real macOS Keychain entries for provider/API-key settings

The main chat runtime providers match the native app:

- Codex
- Copilot
- Claude
- Ollama

Other providers are kept in settings for prompt rewrite and cloud transcription, not in the main chat provider dropdown.

Voice input follows the native transcription setting:

- `Apple Speech` starts the macOS Speech helper.
- `Cloud Providers` records real microphone audio and sends it to the selected cloud provider settings.
- `ChatGPT / Codex Session` uses the Codex app-server auth path instead of a separate API key.
- `whisper.cpp` records microphone audio, uses the copied native `whisper.framework`, and reads models from the shared native OpenAssist model folder at `~/Library/Application Support/OpenAssist/Models`.

If no local Whisper model is installed, the app shows a real install-first message instead of silently using the wrong engine.

## Run

```bash
npm install
npm run dev
```

## Build

```bash
npm run build
```

## Package

```bash
npm run package:mac
```

The packaged app is written to:

```text
out/Open Assist-darwin-arm64/Open Assist.app
```

## Verify

Run the full packaged verification gate:

```bash
npm run verify:packaged
```

This builds, packages, launches, tests, and stops the packaged Electron app.

It checks provider dropdowns, provider colors, model selector placement, settings, local Whisper configuration/handling, voice configuration, Apple Speech start/stop, external-cursor transcript insertion, notes, charts, temporary chats, macOS menu, and sidebar hidden mode.

## Capture Screenshots

```bash
npm run capture:packaged
```

Screenshots are written to `verification/`.

These screenshots are ignored by the packaged app, so they are not bundled into the shipped Electron app.

To capture the currently running native OpenAssist app as a visual reference:

```bash
npm run capture:native
```

That writes native reference screenshots to `verification/native-reference/`.
It is a fallback for visual comparison when official Computer Use cannot attach.

## Known Blocker

Official Computer Use testing is currently blocked outside this Electron app.

The Computer Use tool returns:

```text
Transport closed
```

The macOS crash report shows `SkyComputerUseClient` being killed with:

```text
SIGKILL (Code Signature Invalid)
```

So the remaining Computer Use gap is the helper/transport, not the Electron renderer or packaged app.

See `COMPLETION_AUDIT.md` for the short prompt-to-artifact checklist.
See `PORT_PARITY_AUDIT.md` for the full requirement-by-requirement evidence.
