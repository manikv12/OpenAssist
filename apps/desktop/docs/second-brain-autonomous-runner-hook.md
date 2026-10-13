# Second Brain owner runner

The autonomous runner is wired into the Electron main process. It starts after app readiness, pauses on Mac lock/sleep, resumes on unlock/wake, and stops on quit.

Polling backs off while the queue is empty. The loop waits `pollIntervalMs` (60 seconds in the desktop wiring) after real work, and doubles that delay after each consecutive idle or failed claim up to `idlePollIntervalMs` (15 minutes by default, clamped to 1-30 minutes). So an idle run waits 60s, then 120s, 240s, and so on until it settles at the ceiling. Any non-idle outcome - work claimed, completed, `needs_user`, or incomplete - resets the delay to `pollIntervalMs` immediately. A thrown or failed claim backs off the same way, so a broken Workspace connection is not hammered. The current delay is reported as `nextPollMs` through the `onOutcome` callback, from `runner.pollingStatus()`, and in `SecondBrainOwnerRunnerService` status under `poll`. The sleep stays abortable: stop, pause, and quit interrupt it at once. The preference is stored in the desktop user-data directory and defaults to enabled.

## Host wiring

1. Reuse the signed-in exact-name Workspace caller already owned by the desktop main process. Authentication never enters the renderer.
2. Construct `SecondBrainOwnerCodexHost` with that narrow caller. By default it starts a separate signed-in Codex app-server with apps, plugins, MCP, shell, browser, computer use, memory, and multi-agent features disabled.
3. Call `host.runOnce()` for one queued assignment, or `host.runUntilStopped()` after the owner enables automation.
4. Call `host.stop()` on sign-out, lock, sleep, quit, or user pause.

```ts
const host = new SecondBrainOwnerCodexHost({
  workspaceToolCaller: {
    callNamedTool: (name, args) => callAuthenticatedOpenAssistWorkspaceTool(name, args),
  },
  model: "gpt-5.6-sol",
  reasoningEffort: "high",
});

await host.runUntilStopped({ pollIntervalMs: 60_000, idlePollIntervalMs: 900_000 });
// Later: await host.stop();
```

Before execution, the runner performs one bounded `search_second_brain_knowledge` query across project, work-item, and memory sources. The returned excerpts are marked untrusted. The executor receives project, work-item, and bounded search Markdown in memory for that run. It receives no general Workspace tool interface. The isolated Codex turn is ephemeral, read-only, has network access disabled, and starts from an empty private temporary directory. The child environment contains only the small set needed for Codex subscription authentication and basic runtime behavior; unrelated credentials are not inherited.

## Saved data

The runner does not save conversations or transcripts locally. It sends only bounded progress and a verified final result to the Workspace Second Brain tools. The Workspace stores those as project-linked Markdown revisions.

## Completion rule

A final result is submitted only when the executor returns an explicit passing verification. Otherwise the run remains incomplete. `needs_user` is used only for the fixed Workspace blocker categories.

## Desktop controls

The preload exposes status, start, and stop controls. Starting or stopping updates the persisted owner-runner preference; lifecycle pauses do not disable it. The current safe executor can complete analysis, research synthesis, planning, and Markdown work from supplied context. Repository editing needs a future explicit project-workspace grant; it must not be enabled by widening this isolated runner's access.
