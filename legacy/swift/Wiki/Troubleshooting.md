# Troubleshooting

## Assistant will not start

1. Open `Settings -> AI & Models -> AI Studio`.
2. Finish the provider setup, install, or sign-in.
3. Make sure the assistant is enabled.

## No text gets inserted

1. Check `Accessibility` permission.
2. Make sure the cursor is in an editable text field.
3. Try clipboard insertion fallback in settings.

## No microphone input

1. Check `Microphone` permission.
2. Pick the correct input device.
3. Try auto-detect microphone mode.

## Recognition quality is poor

1. Add custom phrases if needed.
2. Increase finalize delay if speech is cut off too early.
3. Try a larger Whisper model if your Mac can handle it.

## AI rewrite is not working

1. Check provider credentials or sign-in.
2. Confirm the selected provider and model.
3. For local AI, use `Repair Local AI`.

## Browser or app control is not working

1. Open `Settings -> Automation`.
2. Check `Automation / Apple Events`.
3. Pick the correct browser profile.
4. Try again in `Agentic` mode.

## Scheduled job did not run

1. Open `Settings -> Scheduled Jobs`.
2. Make sure the job is enabled.
3. Check the schedule and prompt.
4. Keep the app running if the job depends on the local app process.

## Telegram remote is not responding

1. Open `Settings -> Telegram`.
2. Check the bot token and pairing.
3. Send `/start` again in Telegram.

## Update check errors

1. Check internet access.
2. Retry from `Settings -> About & Permissions -> Check for Updates`.
3. If you built from source, verify your appcast and release setup.

## Still stuck?

Open an issue with:

- macOS version
- feature you were using
- expected result
- actual result
- short steps to reproduce

Issues: [Open Assist Issues](https://github.com/manikv12/OpenAssist/issues)
