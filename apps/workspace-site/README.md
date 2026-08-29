# OpenAssist Daily Workspace Site

This ChatGPT Site provides a polished WebMCP dashboard for the existing OpenAssist Workspace MCP.

## Judge and owner access

- The Site opens on a private access screen. There is no anonymous workspace access.
- **Judge access** uses a shared username and strong access code supplied privately with the submission. It creates an expiring, signed, HttpOnly session.
- Failed judge logins are limited to five attempts per 15-minute window. Only a one-way request fingerprint and short-lived counter are stored.
- **Demo mode** gives every judge a separate synthetic workspace in Cloudflare D1. Judges can create and update demo tasks, calendar events, notes, and memory without touching Google.
- Demo mode also exposes a live synthetic Shopify dev-store catalog. Each judge gets a separate cart pointer; checkout, payment, and order tools do not exist.
- Judges can use only **Funded judge demo** voice. They never enter or see an API key and cannot access ChatGPT subscription voice, owner controls, or Live Workspace.
- **Owner access** uses the exact ChatGPT account bound to the Site. The owner can switch between Demo and Live, manage the funded key, and monitor safe usage metadata.
- The project-funded key stays encrypted in the voice gateway R2 bucket.
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
- `OWNER_ACCOUNT_USER_ID`
- `JUDGE_ACCESS_USERNAME`
- `JUDGE_ACCESS_CODE` (use at least 20 random characters)
- Optional `JUDGE_ACCESS_EXPIRES_AT` (ISO date/time; rotate the code after judging)
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

Before sharing the Site, verify judge isolation and owner binding in a private stage. Anonymous visitors should see only the access screen. Judge sessions must never be able to enter owner Live mode.

## Owner judge voice controls

In owner **Live mode**, open **Activity → Judge Voice** to:

- add or replace the funded OpenAI API key;
- enable, pause, or remove funded judge voice;
- set the daily session, per-session time, and tool-call limits; and
- monitor anonymous starts, active sessions, failures, minutes, and tool-call counts.

The key is verified server-side, encrypted with AES-GCM, and stored only in the private voice R2 bucket. It is never returned to the Site or a judge. Monitoring stores only one-way visitor hashes and session metadata—never audio, transcripts, prompts, tool arguments, or Workspace content.

## Two challenge scenarios

- **Video:** one fixed story connects the urgent Northstar security item to a Shopify search for a USB-C Security Key, then shows the exact approval and verified cart result.
- **Judge test:** an isolated sandbox lets each judge search any of six imaged products, prepare and clear their own cart, and reset the workspace.

## Challenge links

- Live demo: <https://openassist-daily-workspace.developingadventures.chatgpt.site/>
- Public repository: <https://github.com/manikv12/OpenAssist>
- Official rules: <https://webmcp.devpost.com/rules>
- Submission readiness: [`../../docs/webmcp-challenge-readiness.md`](../../docs/webmcp-challenge-readiness.md)
- Private judge testing guide: [`../../docs/webmcp-judge-guide.md`](../../docs/webmcp-judge-guide.md)
