# WebMCP Challenge Demo

## What the judges should see

The public URL opens in **Demo** mode with clearly labelled synthetic data. Each judge gets a separate temporary workspace, so no private Google content is present and one judge cannot change another judge's demo.

1. Open the workspace in ChatGPT's in-app browser.
2. Ask ChatGPT: “Show my daily brief and focus the most urgent unread message.”
3. The site exposes its WebMCP tools, displays the brief, and highlights the complete urgent email card.
4. Ask ChatGPT to read the attached synthetic claim document. The attachment appears as untrusted content and cannot trigger an action.
5. Ask ChatGPT to create a demo task or note. The exact proposed change appears in a locked preview.
6. Approve it on screen. The change is saved once, read back, highlighted, and recorded in Activity.
7. Show that delete, trash, and forget still require a screen tap.
8. Select **Quick judge demo**, speak a request, and show the same WebMCP tool updating the visible synthetic workspace.
9. Optionally select **My ChatGPT** to show isolated subscription sign-in and saved conversation resume.
10. Optionally switch to owner-only Live mode to demonstrate the same tools against Composio-managed Google data.

## Recording rules

- Record only the browser content needed for the demo.
- Keep browser zoom at 100% and use at least 1080p output.
- Do not show personal email, account selectors, tokens, bookmarks, or unrelated tabs.
- Use the synthetic mode for public screenshots.
- Keep the final video focused on the visible human-and-agent collaboration, not implementation details.

## Submission checklist

- Public synthetic Site URL.
- Public MIT repository URL.
- Focused demo video and screenshots.
- Architecture and security explanation.
- Confirm WebMCP discovery in ChatGPT's in-app browser.
- Confirm owner Live mode cannot be opened by another Site user.
- Confirm Quick judge demo completes microphone → tool → visible result → spoken response without exposing a key.
- Confirm the authenticated subscription voice canary passes before showing subscription voice as available.
- Submit by September 2, keeping September 3 as buffer.
