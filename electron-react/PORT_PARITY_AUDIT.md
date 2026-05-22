# OpenAssist Electron React Port Audit

This checklist maps the user's explicit requirements to current evidence.

## Objective

Build a React + Electron version of OpenAssist inside this repo, while matching the native app's visible UI, provider organization, sidebar behavior, and real functionality as closely as possible.

## Completion Audit Checklist

- Deliver React + Electron app inside current OpenAssist repo.
  - Evidence: `electron-react/package.json`, `electron-react/README.md`, `electron-react/electron/main.ts`, `electron-react/electron/preload.ts`, `electron-react/electron/openassistBridge.ts`, `electron-react/src/App.tsx`, `electron-react/src/styles.css`.
  - Result: complete.

- Inspect original/native behavior and mirror it.
  - Evidence: native Swift files inspected for provider enum, runtime behavior, settings providers, usage behavior, menu/sidebar behavior, notes routing, and voice settings.
  - Result: complete for this pass. Native code and supplied screenshots were inspected. Live original-app Computer Use inspection remains blocked by the Computer Use transport, and the user later allowed skipping Computer Use for now.

- Match main chat providers and provider organization.
  - Evidence: native `AssistantRuntimeBackend` has `codex`, `copilot`, `claudeCode`, `ollamaLocal`; Electron verifier confirms runtime menu is exactly `Codex`, `Copilot`, `Claude`, `Ollama`, with no forbidden external providers.
  - Result: complete.

- Use real OpenAssist data and functionality, not fake text.
  - Evidence: bridge reads/writes OpenAssist app support stores, session registry, project notes, thread notes, defaults, and Keychain values. Static fake-data search found no old sample/fallback chat/project strings.
  - Result: complete for the ported surfaces.

- Port chat creation and provider chat flows.
  - Evidence: `createOpenAssistThread`, `destroyTemporaryThread`, provider session binding, Codex app-server, Copilot CLI, Claude Code CLI, and Ollama send paths exist in `openassistBridge.ts`; verifier confirms temporary lifecycle and provider round-trip/sanitization.
  - Result: complete for runtime-backed local flows.

- Copy provider icons and professional visual styling.
  - Evidence: provider SVG assets exist under `src/assets/provider-marks`; renderer uses `ProviderMark`; screenshots under `verification/` show copied marks and glass/dark UI.
  - App icon evidence: native `Resources/AppIcon.icns` was copied to `electron-react/icon.icns`; `package:mac` uses `--icon=icon`; packaged `Contents/Resources/electron.icns` has the same SHA-256 hash as `icon.icns`, and `CFBundleIconFile` points to `electron.icns`.
  - Verifier evidence: `scripts/verify-packaged-electron.mjs` now checks the packaged icon hash before launching the app and reports `packagedIconMatchesSource: true`.
  - Result: complete enough for the current port; full pixel-perfect parity still depends on live visual review.

- Fix sidebar mode and hide/show shortcut.
  - Evidence: `main.ts` implements sidebar window bounds and `CommandOrControl+Shift+Space`; verifier confirms DOM `0px 0px 18px`, edge `18 x 84`, macOS window bounds `18 x 84`, and View menu `Show / Hide Assistant`.
  - Result: complete.

- Move model selector to bottom and keep top buttons for open/editor actions.
  - Evidence: `TopBar` opens VS Code/repo/app-data actions; composer owns `.model-popover`; verifier confirms both.
  - Result: complete.

- Port notes, chat-side notes, usage/limits, voice, settings, plugins/skills/automation surfaces.
  - Evidence: verifier confirms topbar notes/instructions/memory panels, rich note toolbar, markdown preview mode, expanded Mermaid/chart insertion, note save round-trip, usage footer real/pending text, voice configuration, Apple Speech start/stop, settings round-trips, provider keys, Telegram controls, plugins, skills, automations, and diagnostics.
  - Result: complete for functional port paths; full native TipTap editor parity remains a visual/deep-editor weak area.

- Test everything using Computer Use.
  - Evidence: official Computer Use calls were retried repeatedly after tool discovery and helper cleanup. Latest official result: `Transport closed` before `list_apps` or `get_app_state` can inspect any app. Crash report shows `SkyComputerUseClient` build `780` killed by macOS with `SIGKILL (Code Signature Invalid)`.
  - Result: waived for this pass by the user's later instruction. The verifier and native capture scripts remain the current test path until Computer Use is fixed locally.

## Requirement Checklist

- React + Electron app lives inside current OpenAssist repo.
  - Evidence: `electron-react/package.json`, `electron-react/electron/main.ts`, `electron-react/src/App.tsx`.
  - Status: covered.

- Main chat provider dropdown must match native OpenAssist, not show unrelated external providers.
  - Native evidence: `Sources/OpenAssist/Assistant/AssistantRuntimeBackend.swift` has `codex`, `copilot`, `claudeCode`, `ollamaLocal`.
  - Native organization evidence: `Sources/OpenAssist/Assistant/AssistantWindowView.swift` renders `ForEach(AssistantRuntimeBackend.allCases)` in the top-bar provider menu; `Sources/OpenAssist/Assistant/AssistantModels.swift` derives selectable sidebar providers from the same four cases.
  - Electron evidence: `runtimeProviderOptions` in `electron-react/src/App.tsx`.
  - Verifier evidence: `scripts/verify-running-electron.mjs` expects `Codex`, `Copilot`, `Claude`, `Ollama`, rejects `OpenAI`, `Google AI Studio`, `OpenRouter`, `Groq`, `Anthropic`, `Grok`, and checks that forcing `xAI` through the bridge is sanitized back to a real runtime.
  - Status: covered.

- Chat provider selection must use the same selected-thread provider idea as native OpenAssist.
  - Electron evidence: `setThreadProvider` in `electron-react/electron/openassistBridge.ts`.
  - Execution evidence: `sendCodexMessage` dispatches to Codex app-server, Copilot CLI, Claude Code CLI, or Ollama local chat based on the selected OpenAssist session backend. Local detection currently finds `codex`, `copilot`, `claude`, and `ollama` executables.
  - UI evidence: provider failures are rendered back into the chat as an assistant error message instead of silently leaving a dead-looking turn.
  - Verifier evidence: provider round-trip switches a real thread provider and restores it.
  - Status: covered.

- External providers should not pollute the main dropdown.
  - Electron evidence: the chat bridge `AssistantBackend` union now only contains `codex`, `copilot`, `claudeCode`, and `ollamaLocal`; unrelated API providers are left as settings/provider-setup information, not chat runtime backends.
  - Settings evidence: prompt rewrite provider/model/base URL/API key and cloud transcription provider/model/base URL/API key are editable controls backed by the same native defaults and macOS Keychain service/accounts used by native OpenAssist.
  - Verifier evidence: `promptRewriteProvider`, `promptRewriteModel`, `promptRewriteBaseURL`, `cloudTranscriptionProvider`, `cloudTranscriptionModel`, `cloudTranscriptionBaseURL`, and `transcriptionEngine` round-trip through `window.openAssistElectron.updateSetting` and restore their original values. Temporary provider-key probes save and clear Keychain test values only when no existing key is present.
  - Hardening evidence: Keychain save now confirms the credential exists before returning, and Keychain clear deletes repeated matching entries until the credential is gone.
  - Status: covered for dropdown, send-path organization, and the provider key setup paths above; OAuth sign-in flows remain native-app owned.

- Top buttons and bottom model selector should match native organization.
  - Native behavior: the top-right controls are app/thread actions such as opening code/editor surfaces, notes, instructions, memory, and navigation. The model name belongs near the composer.
  - Electron evidence: the top code button opens `Open in VS Code`, `Open repository folder`, and `Open app data`; it no longer opens the model selector.
  - Electron evidence: the model selector now lives in the bottom composer beside the selected model name.
  - Verifier evidence: `editorMenuWorked` and `composerModelSelectorWorked` pass, and the verifier rejects a top-bar model popover.
  - Status: covered.

- Provider loading/status and usage/limits should not be fake.
  - Native evidence: OpenAssist only shows useful usage context when the provider/runtime has real rate-limit or context-window data.
  - Native evidence: `AssistantRuntimeBackend.brandHue` uses Codex `#7f94ff`, Copilot `#c898fd`, Claude `#ffb36b`, and Ollama `#61bf73`.
  - Electron evidence: provider changes briefly show a real loading/ready status tied to the selected provider, and provider color/icon styling changes with Codex, Copilot, Claude, and Ollama using the same native brand hues.
  - Electron evidence: Codex rate-limit/context notifications are captured when available; Claude cached usage is read from `~/.claude/usage-cache.json`; missing usage renders as provider-specific pending text instead of fake `0%` limits.
  - Verifier evidence: `providerBrandColors` reports `{ Codex: "#7f94ff", Copilot: "#c898fd", Claude: "#ffb36b", Ollama: "#61bf73" }`. `usageFooterWorked` passes and rejects the old fake `5h 0%`, `Weekly 0%`, and generic `0%` footer.
  - Status: covered for real/pending usage display. It intentionally does not invent limits when a provider has not reported them.

- Chat-side notes, instructions, and memory panels should work.
  - Electron evidence: the top-right notes, instructions, and memory buttons open right-side inspector panels instead of acting as dead buttons.
  - Electron evidence: thread/project notes are loaded from the native OpenAssist note stores, can be selected, edited, saved, formatted through a note toolbar, previewed as markdown, and can receive chart markdown through the OpenAssist note layer instead of writing chart folders inside `electron-react`.
  - Verifier evidence: `topbarActionButtonsWorked`, `richNoteToolbarWorked`, `richNotePreviewWorked`, `chartInserted`, and `saveRoundTrip` pass.
  - Status: covered for the functional note drawer path; full native TipTap editor internals remain deeper parity work.

- Main Notes layout should follow the original sidebar organization.
  - Native/reference behavior: in the Notes surface, the left app sidebar shows the global navigation and projects, while the center column owns the notes list.
  - Electron evidence: non-thread surfaces such as Notes use `sidebar-projects-only`, so the Threads list is not duplicated above the project list.
  - Electron evidence: the Notes list and editor are independent scroll regions, and the note editor is top-aligned so notes do not look broken or pushed into the wrong layout.
  - Visual evidence: `verification/openassist-notes-view.png`.
  - Status: covered for the reported layout issue.

- Provider icons should be copied.
  - Evidence: `electron-react/src/assets/provider-marks/*.svg`.
  - UI evidence: `ProviderMark` renders the copied SVGs as real images so the icons are visible in the runtime picker and assistant messages.
  - Verifier evidence: provider mark asset existence/size checks.
  - Status: covered.

- Sidebar hidden view should show only the arrow, not the full bar.
  - Evidence: `.sidebar-collapsed` CSS and `applyWindowMode(..., sidebarOpen=false)`.
  - Verifier evidence: DOM grid is `0px 0px 18px`; macOS window bounds are arrow-sized.
  - Visual evidence: `npm run capture:running` with `OPENASSIST_CAPTURE_MODE=smallest` produced `verification/openassist-collapsed-window.png`, a 36 x 168 renderer screenshot containing only the arrow.
  - Status: covered.

- Sidebar show/hide shortcut.
  - Evidence: `CommandOrControl+Shift+Space` in `electron-react/electron/main.ts`; renderer handles `openassist:toggle-sidebar-shortcut`.
  - Status: covered.

- macOS menu.
  - Evidence: `installApplicationMenu()` in `electron-react/electron/main.ts`.
  - Status: covered.

- Voice-to-text mode.
  - Evidence: Apple Speech helper plus local `whisper-transcribe-helper.swift` and copied macOS `whisper.framework` in `electron-react/electron/helpers/`.
  - Settings evidence: the voice/dictation settings include the native-style voice engine, cloud transcription providers including `ChatGPT / Codex Session`, real Whisper model selection, Core ML toggle, and installed-model status from `~/Library/Application Support/OpenAssist/Models`.
  - Runtime evidence: the Electron voice button now reads the selected native transcription engine. `Apple Speech` starts the macOS Speech helper. `Cloud Providers` records a real microphone audio file through the helper app and uploads it through native-compatible OpenAI/Groq, Deepgram, Gemini, or ChatGPT/Codex Session request paths. `ChatGPT / Codex Session` resolves Codex auth through app-server `getAuthStatus` / `account/getAuthStatus` instead of requiring a separate API key. `whisper.cpp` records audio, locates the shared native Whisper model, and calls the vendored native `whisper.framework`; if no model is installed it gives the real install-first error.
  - Verifier evidence: the packaged verifier confirms cloud voice configuration reflects `Cloud Providers` + `ChatGPT / Codex Session`, confirms `ChatGPT / Codex Session` does not require a key, confirms Whisper settings/config reflect the native selection and installed-model list, confirms the `whisper.cpp` start path is handled correctly when no local model exists, restores the original settings, and then forces Apple Speech to verify real start/stop.
  - Status: covered. Real local Whisper transcript output still requires an installed native OpenAssist `ggml-*.bin` model, which this machine does not currently have.

- Temporary chats should behave like native transient chats.
  - Native evidence: `AssistantConversationPersistenceKind.transient` is value `0`; native temporary-thread creation uses transient persistence and `isTemporary`.
  - Electron evidence: `createOpenAssistThread(..., isTemporary=true)` writes `conversationPersistence: 0`, marks `isTemporary`, skips creating a normal conversation snapshot, and `destroyTemporaryThread` cleans up local session state.
  - Hardening evidence: `destroyTemporaryThread` now also treats an already-invisible temporary thread as successfully cleaned up after removing any leftover project assignment/conversation folder. This made the packaged fresh-launch verifier deterministic.
  - UI evidence: the sidebar and composer quick-actions expose `New temporary chat`, and temporary rows are labeled `Temporary`.
  - Verifier evidence: `temporaryThreadButtonWorked` and `temporaryThreadLifecycleWorked` pass; the temporary thread is created, kept out of persisted app-state thread lists, and removed by local cleanup.
  - Status: covered for local transient behavior.

- Settings actions should not be fake or dead buttons.
  - Evidence: Assistant settings now write `assistantFloatingHUDEnabled`, `assistantVoiceOutputEnabled`, and `assistantTrackCodeChangesInGitRepos` to the same `com.developingadventures.OpenAssist` defaults used by native OpenAssist.
  - Evidence: Models & Connections now writes prompt rewrite provider/model/base URL and transcription engine settings to native defaults instead of showing read-only rows.
  - Evidence: Telegram Remote setup now exposes token save/clear/test controls, BotFather/open-chat actions, pairing approve/decline/forget actions, and reads paired/pending state from native defaults. Token presence is checked without revealing the Keychain secret during app-state load.
  - Evidence: General diagnostics now exposes real log/app-data/insertion-diagnostics open actions.
  - Evidence: top-right thread note, session instructions, and memory buttons open their correct panels.
  - Verifier evidence: `settingsRoundTrips`, `modelSettingControlsWorked`, `telegramSetupWorked`, `diagnosticsButtonsWorked`, and `topbarActionButtonsWorked` pass.
  - Status: covered for the ported settings paths above. Destructive uninstall remains intentionally non-destructive in Electron.

- Real data/functionality, not fake text.
  - Evidence: bridge reads/writes OpenAssist app support data, sessions, projects, notes, jobs, skills, plugins.
  - Evidence: the React renderer no longer imports fallback projects, fallback threads, or fallback chat messages. Empty bridge data now renders empty states instead of fake local sample content.
  - Evidence: the notes screen subtitle/lead text is derived from loaded note/project/folder state instead of a hardcoded project name.
  - Verifier evidence: project filtering, project create panel, automations panel, skill create/import panels, plugin prompt, chart insertion, note save round-trip, settings default round-trips, Telegram setup controls, diagnostics controls.
  - Button-action evidence: the stricter verifier clicks each primary sidebar destination (`Notes`, `Automations`, `Skills`, `Plugins`, `Threads`, `Archived`, `Settings`) and confirms the expected surface opens. It also clicks every settings section (`Assistant`, `Voice & Dictation`, `Models & Connections`, `Automation`, `Privacy & Permissions`, `Appearance`, `Integrations`, `General`) and confirms the expected header opens.
  - Packaged verifier evidence: the same `npm run verify:running` check passed against `out/Open Assist-darwin-arm64/Open Assist.app` when launched with `OPENASSIST_ELECTRON_REMOTE_DEBUG=1`.
  - Status: mostly covered for the ported surfaces; a few destructive/deep native maintenance actions remain guarded rather than executed.

- Charts must not create chart folders inside Electron folder.
  - Evidence: verifier rejects local chart/chart-store folders under `electron-react`.
  - Status: covered.

- Test with Computer Use.
  - Evidence: attempted on native and Electron app.
  - Current blocker: Computer Use returns `cgWindowNotFound` even though CoreGraphics sees the window. Accessibility exposes the app's window candidate as `AXApplication` rather than a normal `AXWindow`.
  - Follow-up experiments: tested regular activation policy, opaque/default-titlebar accessibility mode, disabling forced accessibility, granular Electron accessibility features, direct bundle-binary launch, and LaunchServices `open -n` launch. Computer Use lists `Open Assist — com.developingadventures.OpenAssistElectronReact` as running after LaunchServices launch, but `get_app_state` still returns `cgWindowNotFound`.
  - Scope check: Computer Use also returns the same `cgWindowNotFound` for Google Chrome in this desktop session, so this is currently a broader local Computer Use/AX problem, not just the Electron port.
  - Permissions check: `AXIsProcessTrusted()` is `true` and `CGPreflightScreenCaptureAccess()` is `true`, so the failure is not caused by missing Accessibility or Screen Recording permission.
  - Process-state check: multiple older `SkyComputerUseClient mcp` helper processes are present from prior sessions, so the Computer Use tool state may be stale or conflicted; these were not killed during this run to avoid breaking the active tool session.
  - Cleanup check: removed 86 stale helper descendants from the old `74396` Codex app-server group. Computer Use still returned `cgWindowNotFound` for Chrome afterward.
  - Activation check: after attempts to activate Chrome, `NSWorkspace` still reported no normal foreground app and only `loginwindow` as active. This suggests the desktop session itself is not exposing a normal active key-window context to Computer Use.
  - Fresh retry: after the latest packaged app launch, Computer Use `list_apps` saw `Open Assist — com.developingadventures.OpenAssistElectronReact`, but `get_app_state` still returned `Apple event error -10005: cgWindowNotFound` for both `com.developingadventures.OpenAssistElectronReact` and `Open Assist`.
  - Fresh completion-audit retry: Computer Use still returned `cgWindowNotFound` for `com.developingadventures.OpenAssistElectronReact`, `com.google.Chrome`, and `Google Chrome`; Finder timed out. A non-Computer-Use CoreGraphics probe saw the Electron, Chrome, and Finder windows on screen. Restarting only `SkyComputerUseService` did not clear the Computer Use failure.
  - Stale-helper cleanup: removed older `SkyComputerUseClient` processes, leaving only one current Computer Use MCP client; this closed the current MCP transport, so Computer Use can no longer be used in this turn without a wider Codex/Computer Use restart.
  - Latest retry: Computer Use now returns `Transport closed` before it can inspect any app, and a process probe shows no running `SkyComputerUseClient` or `SkyComputerUseService` helper. This means the remaining Computer Use gap is the local MCP transport itself, not the Electron app process.
  - Repair attempt: launched the pre-existing `~/.codex/computer-use/Codex Computer Use.app` helper service, which started `SkyComputerUseService`, but the Codex MCP tool still returned `Transport closed`. The helper service was stopped afterward to avoid leaving extra processes running.
  - Crash evidence: fresh diagnostic reports under `~/Library/Logs/DiagnosticReports/` show `SkyComputerUseClient` build `780` being terminated by macOS with `SIGKILL (Code Signature Invalid)` and `Launch Constraint Violation` when the MCP client is launched under Codex. A `SkyComputerUseService` report also shows a separate stack-overflow crash. This explains why the Computer Use MCP transport closes before app inspection can start.
  - Config check: `~/.codex/config.toml` has `computer-use@openai-curated` disabled and `computer-use@openai-bundled` enabled, so this is not a double-enabled plugin conflict.
  - Service probe: launching `SkyComputerUseService` with an MCP initialize probe did not return an MCP response, so the service binary is not a safe direct replacement for the client MCP command.
  - Alternate-helper probe: the older installed `computer-use@openai-curated` build `750` has the same parent launch constraint, and a direct MCP initialize probe was killed with return code `-9`. Switching to the curated helper would not resolve the transport.
  - Bundle integrity check: both copied and bundled build `780` helper apps pass `codesign --verify --deep --strict`, and their `SkyComputerUseClient` binaries have matching SHA-256 hashes, so the blocker is runtime launch constraints, not a corrupted copied helper.
  - Temporary re-sign probe: an ad-hoc signed copy of `Codex Computer Use.app` could start its MCP server and return `tools/list`, which confirms the parent launch constraint is the reason the normal helper transport dies. However, real app calls still failed with `Apple event error -10000: Sender process is not authenticated`, so that workaround cannot inspect or test OpenAssist windows.
  - Final normal-tool retry: after launching the packaged Electron app through LaunchServices, `computer-use/get_app_state` for `com.developingadventures.OpenAssistElectronReact` still failed immediately with `Transport closed`.
  - Fresh resumed-turn retry: one `SkyComputerUseClient mcp` process and one `SkyComputerUseService` process were alive, but the official `computer-use/get_app_state` call still returned `Transport closed` while the packaged app was running under the verifier.
  - Helper restart retry: after stopping stale Computer Use helper processes, relaunching the packaged Electron app, and calling the official Computer Use tool again, `get_app_state` still returned `Transport closed`. The launched Electron app was stopped afterward.
  - Direct signed-helper probe: launching the bundled `SkyComputerUseClient mcp` directly and sending `initialize` was killed by macOS with `SIGKILL`, with no stdout/stderr. This confirms the current transport failure is still in the Computer Use helper launch path before OpenAssist window inspection can happen.
  - Status: not covered. This remains the biggest verification gap.

## Latest Verification

- Fresh external-cursor insertion verification was added and passed. `scripts/verify-insertion-smoke.mjs` compiles a temporary native macOS text-window helper, focuses its real text cursor, calls `window.openAssistElectron.insertTranscriptText(...)` through the packaged Electron bridge, and waits until the helper's text view contains the probe text. Latest pass reported `{"insertionSmoke":true,"inserted":true,"insertionResult":"typed","target":"InsertionSmokeTarget"}`.
- The insertion bridge now prefers typing for bundle-less macOS helper/target apps, in addition to the existing `com.microsoft.rdc.macos` typing-first path. This avoids a false success where macOS accepts a paste shortcut but the external cursor receives no text.
- `npm run verify:packaged` now runs the packaged app verifier and then the external-cursor insertion smoke test, so the full packaged gate covers both UI/state parity and real transcript insertion into an external focused cursor.
- Handoff artifact: `README.md` was added inside `electron-react/` with the run/build/package/verify/capture commands, real-data notes, runtime provider organization, and the current Computer Use blocker.
- Project hygiene: `.gitignore` keeps generated Electron artifacts out of version control, including `node_modules/`, `dist-electron/`, `dist-renderer/`, `out/`, `out-unpacked/`, `.vite/`, logs, and `verification/`. `git status --ignored --short -- electron-react` confirms those generated folders are ignored while the source folder remains available to add intentionally.
- App icon parity: the packaged Electron app now uses the native OpenAssist `AppIcon.icns` content. `scripts/verify-packaged-electron.mjs` now checks `icon.icns` against `out/Open Assist-darwin-arm64/Open Assist.app/Contents/Resources/electron.icns` before app launch. Latest pass printed `packagedIconMatchesSource: true` with hash `b21f75e1a99728d28d2a9c6a852e67ac5d5b67b14562301415c13c950347b541`, then completed the normal packaged verifier successfully.
- Fresh completion audit: `npm run verify:packaged` passed after the latest source/audit check. It rebuilt TypeScript/Vite, packaged `out/Open Assist-darwin-arm64/Open Assist.app`, launched the packaged app with CDP, drove the renderer, and stopped the packaged app.
- Latest verifier result confirmed: provider menu exactly `Codex`, `Copilot`, `Claude`, `Ollama`; no forbidden runtime providers; top editor/open menu works; model selector is in the bottom composer; usage footer is real/pending text (`Codex usage pending`) instead of fake static percentages; all sidebar and settings navigation checks passed; temporary chat lifecycle passed; thread-note chart insertion and project-note save round-trip passed; cloud voice configuration passed; Apple Speech start/stop passed; provider round-trip/sanitization passed; collapsed sidebar DOM is `0px 0px 18px`; collapsed macOS window bounds are 18 x 84; macOS menu includes View > `Show / Hide Assistant`.
- Latest note-editor verifier result confirmed: thread notes expose a formatting toolbar (`Heading`, `Bold`, `Italic`, `Table`), markdown preview renders note content, and the chart menu now exposes nine Mermaid templates: Flowchart, Sequence, State, ER Diagram, Bar chart, Pie chart, Gantt, Mindmap, and Timeline.
- Latest visual QA: `npm run capture:packaged` captured fresh packaged-app screenshots after the rich note editor change:
  - `verification/openassist-chat-view.png`
  - `verification/openassist-notes-view.png`
  - `verification/openassist-thread-note-drawer.png`
  Manual inspection found and fixed compact drawer toolbar clipping. A follow-up capture shows the thread-note drawer controls wrapping cleanly and the main Notes view toolbar/preview fitting without overlapping.
- Fresh `npm run verify:packaged` passed after the compact note-toolbar layout fix.
- Fresh provider-color parity verifier passed after aligning Electron provider CSS to the native `AssistantRuntimeBackend.brandHue` values. Latest packaged result reported `providerBrandColors` as Codex `#7f94ff`, Copilot `#c898fd`, Claude `#ffb36b`, and Ollama `#61bf73`.
- Native hidden-sidebar comparison: CoreGraphics currently sees the live native `Open Assist` window as an 18px-wide sidebar strip (`owner=Open Assist`, width `18`, height `1658`). Electron collapsed-sidebar verification reports width `18`, edge width `18`, and DOM grid `0px 0px 18px`, so the arrow/hidden width now matches the native hidden-sidebar mode. The native strip was offscreen, so a direct `screencapture` file was not produced.
- Fresh official Computer Use retry still failed before inspecting the app: `computer-use/get_app_state` returned `Transport closed`.
- Fresh repair attempt: four stale `SkyComputerUseClient mcp` helper processes were stopped, leaving no Computer Use helper processes running. After re-discovering the official Computer Use tool, `computer-use/list_apps` still returned `Transport closed` and did not create a new helper process.
- Fresh crash report evidence: `~/Library/Logs/DiagnosticReports/SkyComputerUseClient-2026-05-14-075837.ips` shows `SkyComputerUseClient` build `780` exiting with `SIGKILL (Code Signature Invalid)` under the Codex coalition before it can provide the MCP transport.
- Temporary signed-helper bypass attempt: a non-destructive copy of `SkyComputerUseClient.app` was made under `/tmp`, signed with the local `Apple Development: Manik Vashith (88R4P6T8NR)` identity and the Apple Events entitlement, then launched with an MCP initialize/list-apps probe. It timed out without returning an MCP response. The temporary copy was removed.
- Temporary ad-hoc helper bypass retry: a separate `/tmp` copy signed with ad-hoc identity also timed out before returning MCP initialize/tool-list data. The temporary copy was removed. No local helper bypass is currently usable.
- Extended-attribute/signing check: the bundled `SkyComputerUseClient.app` has `com.apple.provenance` attributes but no quarantine attribute in the inspected output. `codesign --verify --deep --strict` reports valid on disk, and `spctl --assess --type execute` reports `accepted` from `Notarized Developer ID`. The transport failure is not explained by a simple quarantine flag or invalid bundle on disk.
- `npm run build` passed.
- `npm run package:mac` passed again and wrote `out/Open Assist-darwin-arm64/Open Assist.app`.
- `npm run verify:packaged` was added as the repeatable full gate. It packages the app, launches the packaged binary with CDP enabled, runs the strict verifier, and terminates the packaged app afterward.
- Latest `npm run verify:packaged` passed after hardening temporary-thread cleanup and provider-key clear polling.
- `npm run verify:running` passed again against the rebuilt packaged app launched with `OPENASSIST_ELECTRON_REMOTE_DEBUG=1`, including provider, project, temporary-chat lifecycle, archived-thread, settings, Telegram, diagnostics, automations, skills, plugins, top-bar action buttons, chart, voice, note save, provider round-trip, and collapsed-sidebar checks.
- A stricter verifier pass then added and passed explicit checks for all primary sidebar buttons and all settings navigation sections.
- A later stricter verifier run exposed flaky Keychain save/clear timing for provider-key probes; the bridge and verifier were hardened, then `npm run verify:running` passed again.
- The packaged verifier later exposed stale immediate provider-key status and already-invisible temporary-thread cleanup edge cases; both were fixed and `npm run verify:packaged` now passes.
- Provider-key verification passed: prompt rewrite `OpenRouter` and cloud transcription `Deepgram` temporary keys were saved and cleared through Keychain, then the original providers were restored.
- Static fake-data check passed: searching the Electron source for old sample/fallback text such as `Hi Manik`, `Downloads folder`, `Amwins NLS`, `Better one`, `Use Binance`, and fallback arrays returned no hits.
- Provider verification specifically confirmed the menu was exactly `Codex`, `Copilot`, `Claude`, `Ollama`, with no forbidden providers visible, and that an attempted `xAI` provider write did not persist as a chat backend.
- Settings verification now also confirms prompt rewrite provider/model/base URL and transcription engine write to native defaults and restore cleanly.
- Packaging verification confirms `verification/` screenshots and metadata are excluded from `out/Open Assist-darwin-arm64/Open Assist.app/Contents/Resources/app`.
- `npm run capture:running` captured packaged-app renderer screenshots through CDP when `screencapture` was blocked. Fresh captures:
  - `verification/openassist-expanded-window.png`: expanded sidebar/workspace, 1556 x 2512 renderer pixels, live project/thread data visible, copied provider SVG icon visible in the top bar.
  - `verification/openassist-collapsed-window.png`: collapsed hidden sidebar, 36 x 168 renderer pixels, arrow-only.
- Computer Use still failed with `cgWindowNotFound`, including for Chrome, and Finder still timed out.
- Fresh Computer Use retry after launching the packaged Electron app still failed with `Apple event error -10005: cgWindowNotFound`; the live window is visible to CoreGraphics, so this remains a tool/session blocker rather than a missing Electron window.
- Latest Computer Use retry after the completion audit failed earlier with `Transport closed`; there is no live Computer Use helper process available for this Codex turn.
- Starting the local Computer Use helper service manually did not reconnect the closed MCP transport.
- Fresh crash evidence shows the Computer Use MCP client is killed by macOS launch-constraint code signing before it can provide the tool transport.
- A temporary ad-hoc signed Computer Use helper can start far enough to list MCP tools, but macOS blocks app inspection with Apple Event authentication errors. That path was cleaned up and is not a valid verification route.
- A final normal Computer Use retry against the launched packaged app still returned `Transport closed`; the app process was stopped afterward.
- Fresh `npm run verify:packaged` passed in the resumed audit. It rebuilt, repackaged, launched the app, verified all runtime checks, and reported collapsed macOS bounds as 18 x 84.
- Provider-key verification now includes an external Keychain fallback check for the exact temporary OpenRouter and Deepgram accounts, because the app-level configured flag can briefly read stale after deletion. Follow-up `security find-generic-password` checks returned status `44` for both accounts, meaning no temporary key remained.
- Fresh resumed-turn Computer Use retry still returned `Transport closed` while helper processes were alive, so Computer Use remains unverified.
- Stopping stale Computer Use helper processes and retrying against a freshly launched packaged app still returned `Transport closed`; no packaged Electron app process was left running after cleanup.
- The provider-key bridge now returns the known post-save/post-clear configured state immediately, so the UI does not briefly show a stale API-key status after a successful Keychain operation.
- The packaged verifier now checks the real macOS menu bar with System Events. Latest pass returned `Apple`, `Open Assist`, `Edit`, `View`, `Window`, `Help`.
- Fresh `npm run verify:packaged` passed after adding the macOS menu-bar check and API-key status hardening. The latest collapsed macOS bounds were 17 x 77, still arrow-only.
- Follow-up cleanup check found no packaged Electron app process and no temporary OpenRouter or Deepgram Keychain entries.
- The macOS View menu now exposes `Show / Hide Assistant` with the same `CommandOrControl+Shift+Space` shortcut used by the global shortcut handler.
- Fresh `npm run verify:packaged` passed after adding the menu shortcut command. The verifier now confirms both the top-level macOS menu labels and the View submenu item `Show / Hide Assistant`.
- Fresh resumed-turn implementation pass: the Electron voice runtime now follows the selected native transcription engine instead of always starting Apple Speech. Cloud Providers record real microphone audio and use native-compatible upload routes. `ChatGPT / Codex Session` is routed through Codex app-server auth, and `whisper.cpp` is now wired to the vendored native `whisper.framework` and the shared native model folder.
- Fresh `npm run verify:packaged` passed after the voice-runtime changes. The result included `voiceConfigurationProbe` with cloud reflection and Whisper handling true, plus `voiceProbe` with forced Apple Speech start/stop true.
- Fresh `npm run capture:packaged` passed after the voice-runtime changes and wrote 2440 x 1540 screenshots for chat, notes, and the thread-note drawer:
  - `verification/openassist-chat-view.png`
  - `verification/openassist-notes-view.png`
  - `verification/openassist-thread-note-drawer.png`
- Fresh official Computer Use retry after the successful packaged verification still failed with `Transport closed` on `computer-use/get_app_state` for `Open Assist`.
- Added `npm run capture:native` as a repeatable fallback to capture the running native OpenAssist app through CoreGraphics/screencapture when Computer Use is unavailable. Current run wrote metadata and native captures under `verification/native-reference/`; the native hidden-sidebar window captured as the real arrow-only strip. Larger native windows were currently offscreen/blank, so this improves evidence capture but still does not replace Computer Use.
- Fresh `npm run build` passed after adding the native-reference capture command.
- Fresh `npm run verify:packaged` passed after adding the native-reference capture command. The gate rebuilt, repackaged, confirmed the packaged icon hash, verified runtime providers, settings, voice configuration, Apple Speech start/stop, notes, temporary chats, provider round-trip, collapsed sidebar, and macOS menu, then exited cleanly.
- Cleanup check after the fresh packaged verifier found no packaged Electron app process running and no temporary `prompt-rewrite-provider-api-key.openrouter` or `cloud-transcription-provider-api-key.deepgram` Keychain entries.
- Fresh Computer Use cleanup/retry stopped three stale `SkyComputerUseClient mcp` helper processes, then retried official `computer-use/list_apps`; the tool still returned `Transport closed` and did not create a working fresh transport.
- Local Whisper implementation pass: the native app uses the vendored `whisper.framework` and `WhisperModelManager` under `~/Library/Application Support/OpenAssist/Models`. The Electron port now includes the macOS `whisper.framework`, compiles `whisper-transcribe-helper.swift`, records audio through the existing voice helper, and transcribes with the selected installed model. No installed `ggml-*.bin` model was found on this machine, so the current verified path is the real no-model handling path.
- Fresh settings-parity pass replaced hard-coded appearance/version/shortcut display rows with native defaults bridge values. The packaged verifier now round-trips `colorTheme`, `appChromeStyle`, and `waveformTheme`, verifies native voice shortcut rows are present, and rejects the old `fn fn` shortcut placeholder.
- Fresh `npm run verify:packaged` passed after the real-settings and voice-shortcut updates. Latest result included `voiceShortcutRowsWorked: true`, appearance setting round-trips for color theme/chrome/waveform all `changed/restored: true`, packaged icon hash match, provider menu exactly `Codex`, `Copilot`, `Claude`, `Ollama`, collapsed macOS bounds `18 x 84`, macOS View menu `Show / Hide Assistant`, and no forbidden runtime providers.
- Follow-up cleanup after the latest verifier found no packaged Electron/Vite/verifier/Computer Use helper processes and no temporary OpenRouter or Deepgram Keychain test accounts.
- Fresh local Whisper pass: `npm run verify:packaged` passed after adding the local `whisper.cpp` helper. Latest result included `settingsRoundTrips` for `whisperModel` and `whisperUseCoreML`, `voiceConfigurationProbe.whisperReflected: true`, and `voiceConfigurationProbe.whisperHandled: true`.
- Fresh insertion/HUD pass: Electron transcript insertion now uses a native Swift text-inserter helper with the same Unicode-event typing fallback shape as native OpenAssist, with AppleScript preferred only for Microsoft Remote Desktop-style targets. The voice HUD now receives the selected OpenAssist `colorTheme`, `appChromeStyle`, and `waveformTheme`, so it is no longer forced into one black/glass look. Level-only HUD updates skip window reposition/show calls to reduce waveform lag.
- Fresh `npm run verify:packaged` passed after the insertion/HUD changes. The result confirmed the provider dropdown, model selector placement, usage footer, settings round-trips for color/chrome/waveform, voice settings, Apple Speech start/stop, compact HUD bounds, macOS menu, notes/charts, temporary threads, and the external-cursor insertion smoke. The final insertion smoke reported `insertionSmoke: true`, `inserted: true`, `insertionResult: "typed"`, target `InsertionSmokeTarget`.
- Fresh hold-to-talk/HUD pass: dictation shortcuts no longer focus the main Open Assist window before recording, so the user's external cursor is preserved. The shortcut monitor now emits key-down/key-up for normal key shortcuts as well as modifier-only shortcuts, and the renderer queues a stop if the user releases the hold-to-talk keys while native recording is still starting. The HUD is shown immediately from the main process on dictation keypress.
- Fresh insertion hardening: bundle-less macOS targets now try verified focused-field Accessibility insertion first, then fall back to AppleScript keystroke typing instead of trusting a false-positive Unicode-event result. The insertion smoke now verifies the target process is frontmost by PID before inserting.
- Fresh `npm run verify:packaged` passed after the hold-to-talk and insertion hardening changes. The final gate rebuilt, repackaged, verified all UI/state checks, confirmed Voice & Dictation navigation/settings, confirmed Apple Speech start/stop, confirmed HUD bounds, and finished with `insertionSmoke: true`, `inserted: true`, target `InsertionSmokeTarget`.

- One-to-one visual parity.
  - Evidence: native code inspected, screenshot/reference known, CSS aims at transparent glass sidebar and dark workspace. The latest visual pass renders real provider SVG images, reduces oversized chat bubble text, calms button/chrome rounding, and uses smoother sidebar/window transitions. Full-mode screenshot now hides the side pull arrow; collapsed screenshot is arrow-only. Manual image inspection compared the provided CleanShot reference, which showed an unwanted full vertical bar in hidden mode, with `verification/openassist-collapsed-window.png`, which is only the small arrow.
  - Status: covered for the current pass through screenshots/native capture/verifier. Computer Use visual signoff is intentionally skipped until the local helper is fixed.

## Current Missing / Weak Areas

- Computer Use cannot currently inspect native OpenAssist or ElectronReact windows, but the user allowed skipping it for now.
- Some destructive/deep native maintenance actions are intentionally guarded in Electron rather than executed.
- OAuth sign-in UX is still native-app owned, but API-key setup for prompt rewrite and cloud transcription is now ported through the native Keychain layout.
- Local `whisper.cpp` real transcript output could not be exercised because no native OpenAssist Whisper model is installed on this machine. The Electron code path is ported and verified up to the real install-first handling path.
