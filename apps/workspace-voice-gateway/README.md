# OpenAssist Workspace Voice Gateway

This Cloudflare Worker connects voice to the WebMCP tools in the user's current Workspace tab.

- **Quick judge demo** uses the OpenAI Realtime API only for synthetic Demo data. It stops after five minutes or 12 tool calls.
- **My ChatGPT** forces ChatGPT subscription sign-in inside a separate short-lived Codex Container for each visitor.
- **Owner voice** uses the same subscription Container path with owner-only Live tools.
- The optional OpenAI API key stays in the Worker and is never sent to a browser or Container.

## Local checks

```bash
npm install
npm run verify
```

The standard check validates types, security limits, the 23-tool contract, the pinned Codex protocol shape, WebRTC fields, and the boundary between the Worker fallback and subscription Containers.

Build and test the exact Linux/amd64 image, strict Codex config, realtime protocol, health endpoint, and authorization boundary:

```bash
npm run verify:linux
```

The subscription release check intentionally fails until the real authenticated voice canary has passed:

```bash
VOICE_AUTH_CANARY_PASSED=1 npm run verify:release
```

## Required Cloudflare resources

- Workers Paid plan with Containers.
- `basic` Containers, isolated by visitor, with a maximum of 10 active instances.
- Private R2 bucket `openassist-workspace-voice-auth`.
- Secrets:
  - `VOICE_GATEWAY_SHARED_SECRET`
  - `VOICE_AUTH_ENCRYPTION_KEY`
  - `CONTAINER_INTERNAL_TOKEN`
  - Optional `OPENAI_API_KEY` for **Quick judge demo**
- Exact variable: `SITE_ORIGIN`

All three secrets should be independent random values of at least 32 bytes.

## Saved conversations

- Every new subscription voice conversation creates a normal saved Codex thread.
- Each visitor can choose **New conversation** or resume one of their own isolated conversations.
- Before the Container sleeps or the user stops voice, only Codex `sessions` and `archived_sessions` rollout files are compressed, encrypted with AES-GCM, and saved in the private R2 bucket.
- Each visitor's ChatGPT auth and conversation history use separate encrypted R2 objects.
- Mac Codex chats, workspace files, automatic memory, raw audio, and temporary transcripts are not copied into this Container history.

## Release gate

Before deployment is considered ready:

1. Build the Docker image with pinned Codex `0.150.1`.
2. Confirm every API-key environment variable is removed from the Container. The optional fallback key may exist only in the Worker.
3. Complete ChatGPT device sign-in.
4. Verify microphone audio, transcript, one Site tool call, visible result, and spoken audio.
5. Verify the subscription Codex request does not send the rejected `session.model` field.
6. Pin the exact passing image and block upgrades until this canary passes again.

If the subscription canary fails, the Workspace Site and the synthetic Quick judge demo can still ship while subscription voice is shown as unavailable.
