# OpenAssist Desktop

This is the primary OpenAssist desktop app. It uses React for the interface and Electron for macOS integration, local data, global shortcuts, voice, notifications, and agent workers.

## Run

From the repository root:

```bash
npm run setup
npm run dev
```

Or from this folder:

```bash
npm install
npm run dev
```

## Build And Package

```bash
npm run build
npm run package:mac
```

The packaged app is created at:

```text
out/Open Assist-darwin-arm64/Open Assist.app
```

For a signed release build:

```bash
npm run release:mac
```

## Important Parts

- `src/` - React interface
- `electron/main.ts` - Electron lifecycle and macOS helpers
- `electron/openassistBridge.ts` - OpenAssist data, Knowledge, and agent workers
- `electron/realtimeProxy.ts` - OpenAI Realtime and Gemini Live coordinator
- `electron/realtimeTaskCoordinator.ts` - shared delegated-task registry
- `electron/liveVoiceContinuity.ts` - bounded same-thread voice context
- `scripts/` - build, verification, and capture tools

## Data And Privacy

The app reuses the existing OpenAssist data at `~/Library/Application Support/OpenAssist`, macOS defaults, and Keychain entries. Live Voice stores completed text turns only. It does not store raw audio, provider events, or session handles on disk.

## Verification

From the repository root:

```bash
npm run verify:live-voice
```

For the packaged desktop checks:

```bash
npm run verify:packaged
```

Generated verification screenshots stay local and are ignored by Git.
