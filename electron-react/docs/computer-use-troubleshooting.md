# Computer Use Troubleshooting

How Computer Use works in OpenAssist, the bug that broke it, and how to diagnose
it if it stops working again.

## TL;DR

OpenAssist does **not** implement Computer Use itself. It runs the **Codex CLI**
(`/Applications/Codex.app/Contents/Resources/codex app-server`) as a backend and
uses Codex's **official bundled `computer-use` plugin** (an MCP server). That
plugin launches a helper app that reads the screen and clicks via macOS
Accessibility.

The most common failure is **self-inflicted**: OpenAssist's own pre-turn cleanup
code kills the live helper while it is working, producing `Transport closed`
errors. This is *not* a permission or signing problem.

## Architecture (who launches what)

```
OpenAssist (Electron)
  └─ spawns: codex app-server            (from /Applications/Codex.app)
        └─ spawns: SkyComputerUseClient mcp   (the Computer Use MCP helper)
              └─ XPC → SkyComputerUseService  (privileged: reads screen / AX)
```

- The helper bundle lives at:
  `~/.codex/plugins/cache/openai-bundled/computer-use/<version>/Codex Computer Use.app`
- Helper identities (used by macOS TCC permissions):
  `com.openai.sky.CUAService` and `com.openai.sky.CUAService.cli`
  (Team ID `2DC432GLL2`, signed by OpenAI — **not** OpenAssist).
- Routing/selection lives in `electron/openassistBridge.ts`. The
  `computer-use@openai-bundled` plugin must be in the turn's `pluginIDs` for
  Codex's tools (`get_app_state`, `click`, `set_value`, `type_text`, …) to be
  used instead of OpenAssist's own desktop tools.

## The bug that broke it (June 2026)

Commit `2ffb95d` (2026-05-23) added pre-turn helper cleanup. One function,
`resetCodexIfCurrentComputerUseHelperExists`, restarted the whole Codex
app-server whenever **any** Computer Use helper was attached — **with no age
check**. The Computer Use helper normally stays attached between turns and is
reused, so this killed a healthy helper that was only a few seconds old:

```
Computer Use helper already attached before turn; restarting Codex ... details=53872:mcp:3s
terminating provider helper tree ...
MCP tool call error: tool call failed for `computer-use/get_app_state`
  Caused by: Transport closed
```

Result: every Computer Use turn died mid-call. It had worked a month earlier
because this aggressive reset did not exist yet.

### The fix

In `electron/openassistBridge.ts`:

- `resetCodexIfCurrentComputerUseHelperExists` now only restarts Codex when an
  attached helper is **genuinely stuck/old**
  (`ATTACHED_HELPER_RESTART_MIN_AGE_SECONDS = 180`). A healthy, recently
  attached helper is left alone and reused.
- `cleanupStaleComputerUseHelpers` is kept — it already had age thresholds
  (60–180s) and only removes truly orphaned helpers.
- A short-lived "preflight" probe that was added during debugging was removed.
  It spawned its **own** `list_apps` call, which left an orphan helper that then
  tripped the killer on the next turn. Do **not** re-add a probe that launches a
  second helper.

## The second bug: killing Codex.app's own helpers (July 2026)

The same helper binaries (`SkyComputerUseClient` / `SkyComputerUseService`) are
also spawned by the **standalone Codex.app** for its own Computer Use sessions —
including "locked use", which keeps a helper attached for hours. OpenAssist's
cleanup matched helpers **by name only**, so:

- `cleanupOrphanedComputerUseHelpersOnStartup` killed **every** helper on the
  Mac at app launch (no age or ownership check).
- `cleanupStaleComputerUseHelpers` killed any helper older than 60–180s that
  wasn't a child of OpenAssist's own app-server — which describes **all** of
  Codex.app's helpers.

Result: Codex.app's locked use died with `Transport closed` whenever OpenAssist
started or ran its periodic cleanup, even though the toggle was on.

### The fix

`classifyComputerUseHelperOwnership` walks each helper's parent chain in the
process snapshot:

- reaches this OpenAssist process → **ours** (killable per the usual age rules);
- topmost living ancestor below launchd is itself a helper or a
  `codex app-server` → **orphaned** (its owning app died; killable);
- anything else (Codex.app, VS Code extension, …) → **foreign** (never touched).

All automatic kill paths (startup cleanup, stale cleanup, post-Stop sweep) go
through `isAutomaticallyKillableComputerUseHelper`, which also **never** kills
the shared `SkyComputerUseService` (an on-demand service reused by Codex.app —
it idles cheaply and relaunches when needed). `getComputerUseActivity` excludes
foreign helpers so the Settings "Force stop" can't kill them either.

Guarded by `npm run verify:computer-use-ownership`.

## If Computer Use stops working again — diagnosis checklist

1. **Read the debug log** (most important):
   `~/Library/Application Support/Open Assist/electron-debug.log`
   - Healthy run: `get_app_state ... status=completed`, `click ... status=completed`.
   - Self-inflicted kill: `already attached ... restarting`, `terminating provider helper tree`, `Transport closed`.
   - Real permission/hang: `timed out awaiting tools/call after ~120s`.

2. **Read the Codex transcript** for the failing turn:
   `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-*.jsonl`
   Grep for `get_app_state`, `list_apps`, `timed out`, `Invalid app`,
   `Transport closed`.

3. **Probe the helper directly** (bypasses OpenAssist entirely):
   ```bash
   CU=$(ls -d ~/.codex/plugins/cache/openai-bundled/computer-use/*/ | sort -V | tail -1)
   BIN="${CU}Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
   cd "$CU" && printf '%s\n' \
     '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"Codex","version":"1.0"}}}' \
     '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
     '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}' \
     | CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex "$BIN" mcp
   ```
   - Replies to `id:2` with an apps list → the helper is healthy; the problem is
     in OpenAssist (likely killing it again — re-check the age threshold above).
   - Replies to `id:1` only, then hangs → the helper itself can't reach its
     privileged backend. This happens when run outside the genuine Codex.app
     process context, and can also appear after a Codex.app update tightens the
     helper. Verify Computer Use still works in the **official Codex.app**; if it
     fails there too, it is a macOS permission / Codex-side issue, not ours.

4. **Check which helpers are running** (look for stuck ones):
   ```bash
   ps -axo pid=,ppid=,etime=,command= | grep -i SkyComputerUse | grep -v grep
   ```

## Computer Use on non-Codex backends (Copilot / Claude)

OpenAI's Computer Use helper only answers callers whose **responsible process**
is OpenAI-signed (`com.openai.*`, Team `2DC432GLL2`) — verified via the kernel
`audit_token`. So Copilot/Claude cannot drive the helper directly.

We work around this with an **identity proxy**: when a Copilot or Claude turn
includes the `computer-use@openai-bundled` plugin (via the `@computer-use`
composer mention), the bridge attaches **`codex mcp-server`** as an MCP server to
that backend's session. Because the OpenAI-signed `codex` binary becomes the
responsible process, Computer Use works through it. The other model gets `codex`
/ `codex-reply` tools and *delegates* the on-screen task to Codex.

Wiring (all in `electron/openassistBridge.ts`):

- `codexComputerUseProxyMCPServerConfig()` — stdio MCP entry that runs
  `codex mcp-server` with the originator + unbuffered-IO env.
- `temporaryCodexComputerUseMCPConfig()` / `codexProxyAllowedToolNames()`.
- `sendCopilotMessage` adds `--additional-mcp-config @<file> --allow-tool codex_computer_use`.
- `sendClaudeCodeMessage` merges it into the single `--mcp-config` + `--allowedTools`.

Renderer (`src/App.tsx`): `mentionPlugins` exposes the `computer-use` plugin for
the `copilot` / `claudeCode` providers (Codex still gets all plugins), so
`@computer-use` is selectable on those backends. See
`codexComputerUsePluginMentionIDs`.

Ollama is not wired — local models don't reliably drive delegated tool calls.

If it fails on Copilot/Claude: confirm `codex mcp-server` works standalone
(it exposes `codex` + `codex-reply`), that the computer-use plugin is enabled in
Codex, and that Codex's own Computer Use works (permissions OK).

**"MCP connection closed" on Copilot/Claude:** the spawned `codex mcp-server`
exited during the handshake because its env was too stripped. The proxy config
must include `PATH` and `HOME` (plus the originator/buffering vars) in the `env`
block — without `PATH`, codex can't run and the client reports the connection
closed. Do NOT dump the entire `process.env` into the temp config file (it may
contain API keys); pass only `PATH`, `HOME`, `CODEX_INTERNAL_ORIGINATOR_OVERRIDE`,
and the buffering vars.

**Permissions note for the proxy:** the responsible process for the helper is
whatever launched the chain. From a plain Terminal run, that's Terminal (usually
no Screen Recording → `list_apps` times out). From the signed OpenAssist app it
is OpenAssist — grant Accessibility + Screen Recording to the OpenAssist app
(and the helper, `com.openai.sky.CUAService`) the same way as for the Codex path.

## macOS permissions

The helper (not OpenAssist) needs **Accessibility** and **Screen Recording**.
These attach to `com.openai.sky.CUAService`. To reset and let macOS re-prompt:

```bash
tccutil reset Accessibility com.openai.sky.CUAService
tccutil reset ScreenCapture com.openai.sky.CUAService
```

> Avoid blanket `tccutil reset` loops. Resetting permissions repeatedly can
> leave TCC in a state where it won't re-prompt for a background helper, which
> looks identical to the "hang" failure above.

## Environment that must match Codex.app

`electron/openassistBridge.ts` sets these when spawning `codex app-server`
(do not remove them):

- `CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex` — makes plugins treat us as the
  Codex client.
- `NSUnbufferedIO=YES`, `PYTHONUNBUFFERED=1`, `STDBUF=L` — prevent the helper's
  stdout from being fully buffered, which would make small JSON-RPC replies
  (e.g. `get_app_state`) sit in the buffer and the parent read hang forever
  (see openai/codex#23840).

## Building a signed app (so permissions persist)

An unsigned/ad-hoc dev build (`com.github.Electron`, no Team ID) cannot reliably
hold TCC permissions; they get dropped. Build a signed app instead:

```bash
cd electron-react
export DEVELOPER_ID="Developing Adventures LLC (5S8UZ6DJNK)"
bash scripts/build-mac-release.sh
```

If `codesign --verify` reports *"code has no resources but signature indicates
they must be present"* for a framework, re-sign each framework at its versioned
path (`*.framework/Versions/A`) first, then the nested `*.app` helpers (with
`electron/release-entitlements.plist`), then deep-sign the outer `.app`.

The app is **signed but not notarized**, so the first launch needs
right-click → Open.
