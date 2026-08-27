# OpenAssist Daily Workspace Site

This ChatGPT Site provides a polished WebMCP dashboard for the existing OpenAssist Workspace MCP.

## Demo and Live data

- **Demo mode** gives every visitor a separate synthetic workspace in Cloudflare D1. Judges can create and update demo tasks, calendar events, notes, and memory without touching Google.
- The demo workspace expires after 24 hours. **Reset demo** immediately deletes it and creates a clean copy.
- **Live mode** is owner-only and continues to use the existing Workspace MCP and Composio-managed Google connections.
- Demo and Live routes are separate. Private Google content is never copied into the demo database.

## Local checks

```bash
npm install
npm run verify
```

Run locally with:

```bash
npm run dev
```

## Required bindings and secrets

- D1 binding: `DB`
- R2 binding: `FILES`
- `SITE_PUBLIC_ORIGIN`
- `TOKEN_ENCRYPTION_KEY`
- `ACTION_SIGNING_KEY`
- `OWNER_BOOTSTRAP_CODE`
- `WORKSPACE_MCP_URL`
- `WORKSPACE_OAUTH_ISSUER`
- `WORKSPACE_OAUTH_CLIENT_ID`
- Optional confidential-client secret: `WORKSPACE_OAUTH_CLIENT_SECRET`
- `VOICE_GATEWAY_URL`
- `VOICE_GATEWAY_SHARED_SECRET`

The Workspace OAuth client must allow exactly:

```text
https://YOUR_SITE_ORIGIN/api/workspace/callback
```

## Owner bootstrap

After signing in with the intended ChatGPT account, send the one-time bootstrap code to `/api/owner/bootstrap`. The first successful bootstrap permanently binds the owner role. A second user cannot replace it.

Before sharing the Site, verify synthetic demo isolation and owner binding in a private stage. Public visitors should open in Demo mode and must never be able to enter owner Live mode.
