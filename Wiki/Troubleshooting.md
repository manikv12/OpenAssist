# Troubleshooting

## No text gets inserted

1. Re-check Accessibility permission in Open Assist settings.
2. Confirm your cursor is in an editable text field.
3. Try fallback insertion mode in settings.

## No microphone input

1. Verify microphone permission.
2. Select the correct input device.
3. Try auto-detect microphone mode.

## Recognition quality is poor

1. Add custom phrases or vocabulary.
2. Increase finalize delay if speech gets cut off.
3. Switch to a larger Whisper model if your hardware can handle it.

## AI rewrite is not working

1. Validate provider credentials/OAuth status.
2. Confirm selected model/provider in AI settings.
3. For local AI, use `Repair Local AI` in AI Studio.

## Update check errors

1. Check internet connectivity.
2. Retry from `Settings -> About and Permissions -> Check for Updates`.
3. If you are building from source, verify your appcast/release setup.

## Still stuck?

Open an issue with:

- macOS version
- speech engine in use
- expected behavior vs actual behavior
- short reproduction steps

File issues here: [Open Assist Issues](https://github.com/manikv12/OpenAssist/issues)
