# Open Assist User Guide

This guide is for end users who want to install Open Assist, configure it quickly, and use its core features with confidence.

## 1. What Open Assist Does

Open Assist is a macOS menu-bar assistant with built-in voice capture and dictation. You can open the assistant for typed or spoken tasks, or use a shortcut to speak and insert text into your active app.

Core capabilities:

- Assistant window for typed or spoken tasks
- Fast voice capture and dictation with Apple Speech or local `whisper.cpp`
- Hold-to-talk and continuous dictation modes
- Optional AI rewrite before insertion
- Conversation-aware rewrite and assistant context
- Local transcript history and adaptive corrections

## 2. Requirements

- macOS 13.3 or newer
- Microphone permission
- Accessibility permission (for direct text insertion and global shortcuts)
- Speech Recognition permission (only when using Apple Speech engine)

## 3. Install and Launch

1. Download the latest release from GitHub Releases.
2. Open `Open Assist.app`.
3. Approve requested permissions when prompted.
4. You should now see the Open Assist icon in the macOS menu bar.

## 4. First-Run Setup Checklist

Open **Settings** from the menu bar and confirm:

1. **About & Permissions**
2. Accessibility = Granted
3. Microphone = Granted
4. Speech Recognition = Granted (if using Apple Speech)
5. Verify your shortcut settings in **Shortcuts**

## 5. Daily Assistant and Voice Workflows

### Assistant tasks

1. Open the menu bar popover.
2. Choose **Open Assistant** for typed work, or **Speak Assistant Task** for voice-first requests.
3. Continue in the assistant window and review the result before using it elsewhere.

### Hold-to-talk (default)

1. Focus your target app and place the text cursor.
2. Hold `⌥⌘Space`.
3. Speak naturally.
4. Release to finalize and insert text.

### Continuous dictation

1. Press `⌃⌥⌘Space` once to start.
2. Speak in multiple phrases.
3. Press the same shortcut again to stop and finalize.

### Paste last transcript

- Press `⌥⌘V` to insert your most recent transcript.

## 6. Choose Your Speech Engine

Go to **Settings → Speech & Input → Speech Engine**:

- **Apple Speech**
  - Works immediately with system speech APIs
  - Requires Speech Recognition permission
- **Whisper.cpp**
  - Fully local once model files are installed
  - Supports Core ML acceleration when available

### Whisper model management

Use **Settings → Speech & Input → Whisper Model Install** to:

- Download/remove models (`tiny`, `base`, `small`, etc.)
- Pick active model
- Enable/disable Core ML encoder use
- Configure idle context unload behavior

## 7. Assistant Drafting and AI Rewrite (Optional)

Enable from **Settings → AI & Models**:

1. Turn on AI rewrite.
2. Configure provider (local Ollama or cloud provider).
3. Choose rewrite strength (`Light`, `Balanced`, `Strong`).
4. Optionally enable auto-insert for high-confidence suggestions.

Provider options include:

- Ollama (local)
- OpenAI
- Anthropic
- Google Gemini
- Groq
- OpenRouter

## 8. AI Studio and Local AI Setup

Open **Settings → AI & Models → AI Studio**.

For local AI with no API key:

1. Go to **Prompt Models**
2. Use **Local AI Setup**
3. Select a model and run install
4. Verify runtime and model status

If local AI fails later, use **Repair Local AI** in AI Studio.

## 9. Settings Overview

### Essentials

- Voice capture output behavior
- Sound cues and feedback volume
- App appearance and waveform theme

### Shortcuts

- Hold-to-talk shortcut
- Continuous mode shortcut
- Manual shortcut mapping

### Speech & Input

- Microphone source
- Engine selection
- Recognition tuning
- Whisper model setup

### AI & Models

- Rewrite toggle and style controls
- Provider keys/OAuth status
- AI Studio entry point

### Corrections

- Adaptive correction learning
- Correction sounds
- Manage learned corrections

### About & Permissions

- Permission health
- App version
- Check for updates
- Uninstall options

## 10. Updates and Version Info

In **Settings → About & Permissions → App Info**:

- You can view the current app version/build.
- Click **Check for Updates…** to run a manual Sparkle update check.
- The UI now shows status messages (checking, up to date, update available, or error).

If update checks fail, confirm the appcast feed is published and reachable by the app.

## 11. Privacy and Local Data

Open Assist is local-first:

- No account required
- No telemetry by default
- Data is stored locally on your Mac

Stored data may include:

- App settings
- Recent transcript history
- Learned adaptive corrections
- Conversation context used for assistant and rewrite assistance

## 12. Troubleshooting

### No text is inserted

1. Re-check Accessibility permission in Settings.
2. Ensure the cursor is active in an editable text field.
3. Try clipboard insertion fallback mode in Essentials.

### No audio input

1. Confirm microphone permission.
2. Pick the correct microphone in Speech & Input.
3. Try auto-detect microphone mode.

### Poor recognition quality

1. Add domain-specific words in custom phrases.
2. Increase finalize delay for better stability.
3. Switch to a larger Whisper model if your hardware allows.

### AI rewrite not working

1. Verify provider credentials/OAuth status.
2. Confirm model/provider selection in AI settings.
3. For local AI, run **Repair Local AI** in AI Studio.

### Update check shows error

1. Check internet connectivity.
2. Verify the appcast feed URL configured in the app build.
3. If you are the maintainer, publish/update the appcast feed.

## 13. Keyboard Shortcuts Reference

| Action | Default |
|---|---|
| Hold-to-talk | `⌥⌘Space` |
| Toggle continuous mode | `⌃⌥⌘Space` |
| Paste last transcript | `⌥⌘V` |

## 14. Support and Contribution

- User-facing overview and quick setup: `README.md`
- Code and issue tracking: GitHub repository
- If you file a bug, include your macOS version, whether you were using the assistant or dictation flow, and a short reproduction flow.
