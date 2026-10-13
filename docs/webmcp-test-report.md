# WebMCP Challenge Test Report

Checked on August 29, 2026 against the deployed Site and voice gateway.

## Passed

- Site typecheck, lint, production build, and all 26 tests.
- Voice-gateway typecheck, Codex compatibility gate, and all 12 tests.
- The Site and gateway use the same 29-tool contract.
- Anonymous visitors see only the private access screen.
- The private judge credentials open Demo mode only; owner Live mode is not available.
- Every judge receives a separate synthetic workspace and cart pointer.
- Daily brief, mail search/read, task search, calendar reads, notes, memory, visible navigation, Shopify product search, product images, and cart reads work.
- A synthetic write creates a signed preview, executes once after approval, reads the result back, and rejects a duplicate execution.
- Reset Demo removes the temporary judge change and restores the clean seed workspace.
- Owner Live mode reaches all five connected Workspace accounts.
- Live task, note, normal mail, calendar, and one explicitly selected Gmail attachment read completed without copying private content into the Site database.
- Cancelling an owner write preview creates no Google task.
- The Workspace Worker safely handles Composio rotating an opaque Gmail attachment reference.
- Public Site health, Workspace Worker health, and voice-gateway health respond successfully.
- The repository includes an MIT license and separates pre-challenge OpenAssist work from the post-August-25 WebMCP extension.

## Funded judge voice

The funded API key is not configured in the current deployment. The status endpoint reports voice unavailable, and a real session-start request returns HTTP 503 with the safe message: **“The funded judge voice demo is not enabled.”** No key is requested from or exposed to the judge.

The owner can add a project key from **Live → Activity → Judge Voice**. The gateway verifies it server-side, encrypts it in private R2, and applies the configured daily session, time, and tool-call limits. Before voice is shown in the public recording, run the microphone → transcript → WebMCP tool → visible result → spoken reply canary.

## Not run automatically

- A live microphone canary was not started without the owner's action-time permission because it would send microphone audio to OpenAI.
- A second ChatGPT account was not available for judge WebMCP discovery inside ChatGPT's in-app browser. Judge authentication and all Demo APIs were tested in a clean Brave session; the same 29 tools were separately discovered and exercised in ChatGPT's in-app browser under the owner session.
- The final YouTube upload and Devpost submission remain external publishing steps.

## Release rule

Do not claim funded voice in the video unless its live canary passes. Do not edit the Site, repository, or Devpost entry after September 3, 2026 at 1:00 PM Pacific until judging ends.
