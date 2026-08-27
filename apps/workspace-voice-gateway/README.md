# OpenAssist Workspace Voice Gateway

This owner-only Cloudflare Worker and Container connects ChatGPT subscription realtime voice to the WebMCP tools in the user's current Workspace tab.

## Local checks

```bash
npm install
npm run verify
```

The standard check validates types, security limits, the 23-tool contract, the pinned Codex protocol shape, WebRTC fields, and the absence of an API-key fallback.

Build and test the exact Linux/amd64 image, strict Codex config, realtime protocol, health endpoint, and authorization boundary:

```bash
npm run verify:linux
```

The release check intentionally fails until the real authenticated voice canary has passed:

```bash
VOICE_AUTH_CANARY_PASSED=1 npm run verify:release
```

## Required Cloudflare resources

- Workers Paid plan with Containers.
- One `basic` Container, maximum one instance.
- Private R2 bucket `openassist-workspace-voice-auth`.
- Secrets:
  - `VOICE_GATEWAY_SHARED_SECRET`
  - `VOICE_AUTH_ENCRYPTION_KEY`
  - `CONTAINER_INTERNAL_TOKEN`
- Exact variable: `SITE_ORIGIN`

All three secrets should be independent random values of at least 32 bytes.

## Release gate

Before deployment is considered ready:

1. Build the Docker image with pinned Codex `0.150.1`.
2. Remove every API-key environment variable.
3. Complete ChatGPT device sign-in.
4. Verify microphone audio, transcript, one Site tool call, visible result, and spoken audio.
5. Verify `session.model` and realtime `model` are absent.
6. Pin the exact passing image and block upgrades until this canary passes again.

If the canary fails, the Workspace Site still ships, but voice stays visibly unavailable.
