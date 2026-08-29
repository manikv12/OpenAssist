# OpenAssist WebMCP Judge Guide

## Access

- Live Site: <https://openassist-daily-workspace.developingadventures.chatgpt.site/>
- Open it in ChatGPT's in-app browser, or Chrome 149+ with `chrome://flags/#enable-webmcp-testing` enabled.
- Use the private username and access code from the Devpost testing instructions.
- No Google account, API key, payment method, or Shopify checkout is required.

The judge account can access only an isolated synthetic Demo workspace. Owner Live mode and private Google data are not available.

## Two-minute test

1. Ask: **“Show my daily brief and focus the most urgent unread message.”**
2. Ask: **“Find a USB-C Security Key and prepare one in the cart.”**
3. Inspect the exact preview, then press **Approve**.
4. Open **Activity** and confirm the verified cart change appears once.
5. Press **Reset demo** to remove your temporary changes.

You can also open Tasks, Calendar, Notes, Memory, and Supplies manually. Items and whole cards highlight when selected so the agent's focus stays visible.

## What to expect

- Reads and navigation run immediately.
- Writes wait at a signed, two-minute preview.
- Delete, trash, and forget actions always need an on-screen tap.
- Approved actions run once and are read back before success is shown.
- Every judge receives separate synthetic data that expires after 24 hours.
- The Shopify catalog returns product images, but it has no checkout, payment, or order tool.
- Funded voice is optional. If it is paused or no project key is configured, the Site clearly says it is unavailable; all browser WebMCP tools still work.

## Privacy and safety

Synthetic email, task, calendar, note, memory, and catalog content may be stored temporarily for this demo. Real Google content is never copied into the demo database. Voice audio and transcripts are not stored by the Site. External content cannot approve actions or call more tools.

## Source

- Repository: <https://github.com/manikv12/OpenAssist>
- License: MIT
- WebMCP registry: `apps/workspace-site/lib/tool-registry.ts`
- Browser registration: `apps/workspace-site/app/components/workspace-app.tsx`
- Architecture and safety boundaries: `docs/workspace-architecture.md`
- Challenge readiness map: `docs/webmcp-challenge-readiness.md`
