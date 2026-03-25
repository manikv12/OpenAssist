# Troubleshooting

## Assistant will not start

1. Open `Settings -> AI & Models -> AI Studio`.
2. Finish the install or sign-in steps shown there.
3. Make sure the assistant is enabled.

## No text gets inserted

1. Re-check `Accessibility` permission.
2. Confirm your cursor is in an editable text field.
3. Try the clipboard insertion fallback in settings.

## No microphone input

1. Verify `Microphone` permission.
2. Select the correct input device.
3. Try auto-detect microphone mode.

## Recognition quality is poor

1. Add custom phrases or vocabulary.
2. Increase finalize delay if speech gets cut off.
3. Switch to a larger Whisper model if your Mac can handle it.

## AI rewrite is not working

1. Check your provider credentials or sign-in status.
2. Confirm the selected model and provider in AI settings.
3. For local AI, use `Repair Local AI` in AI Studio.

## Browser or app control is not working

1. Open `Settings -> Automation`.
2. Allow `Automation / Apple Events`.
3. Pick the right browser profile for Chrome, Brave, or Edge.
4. Try the request again in `Agentic` mode.

## Scheduled job did not run

1. Open `Settings -> Scheduled Jobs`.
2. Check that the job is enabled.
3. Confirm the schedule and prompt are correct.
4. Leave the app running if the job depends on the local app process.

## Telegram remote is not responding

1. Open `Settings -> Telegram`.
2. Check the bot token and pairing.
3. Send `/start` again in Telegram.

## Update check errors

1. Check internet connectivity.
2. Retry from `Settings -> About & Permissions -> Check for Updates`.
3. If you build from source, verify the appcast and release setup.

## Still stuck?

Open an issue with:

- macOS version
- feature you were using
- expected behavior vs actual behavior
- short reproduction steps

File issues here: [Open Assist Issues](https://github.com/manikv12/OpenAssist/issues)
