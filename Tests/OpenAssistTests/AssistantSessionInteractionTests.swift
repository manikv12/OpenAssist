import XCTest
@testable import OpenAssist

private final class AssistantRuntimeEventRecorder: @unchecked Sendable {
    var toolSnapshots: [[AssistantToolCallState]] = []
    var activityTitles: [String] = []
    var systemMessages: [String] = []
    var transcriptEntries: [AssistantTranscriptEntry] = []
    var statusMessages: [String?] = []
    var hudStates: [AssistantHUDState] = []
    var timelineItems: [AssistantTimelineItem] = []
    var proposedPlans: [String?] = []
}

final class AssistantSessionInteractionTests: XCTestCase {
    @MainActor
    func testShouldBlockSessionSwitchOnlyWhenAnotherTurnIsActive() {
        XCTAssertTrue(
            AssistantStore.shouldBlockSessionSwitch(
                activeSessionID: "session-a",
                hasActiveTurn: true,
                requestedSessionID: "session-b"
            )
        )

        XCTAssertFalse(
            AssistantStore.shouldBlockSessionSwitch(
                activeSessionID: "session-a",
                hasActiveTurn: true,
                requestedSessionID: "session-a"
            )
        )

        XCTAssertFalse(
            AssistantStore.shouldBlockSessionSwitch(
                activeSessionID: "session-a",
                hasActiveTurn: false,
                requestedSessionID: "session-b"
            )
        )
    }

    @MainActor
    func testResolvedManagedSessionIDPrefersOpenAssistThreadIdentity() {
        XCTAssertEqual(
            AssistantStore.resolvedManagedSessionID(
                boundSessionID: "openassist-thread",
                canonicalThreadID: "openassist-thread",
                runtimeSessionID: "copilot-session"
            ),
            "openassist-thread"
        )

        XCTAssertEqual(
            AssistantStore.resolvedManagedSessionID(
                boundSessionID: nil,
                canonicalThreadID: "openassist-thread",
                runtimeSessionID: "copilot-session"
            ),
            "openassist-thread"
        )

        XCTAssertEqual(
            AssistantStore.resolvedManagedSessionID(
                boundSessionID: nil,
                canonicalThreadID: nil,
                runtimeSessionID: "copilot-session"
            ),
            "copilot-session"
        )
    }

    @MainActor
    func testProviderIndependentThreadOnlyPinsProviderSwitchWhileTurnIsActive() {
        let session = AssistantSessionSummary(
            id: "openassist-v2-thread",
            title: "Merged",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            status: .idle
        )

        XCTAssertFalse(
            AssistantStore.shouldPinBackendSelection(
                for: session,
                hasActiveTurn: false
            )
        )
        XCTAssertTrue(
            AssistantStore.shouldPinBackendSelection(
                for: session,
                hasActiveTurn: true
            )
        )
    }

    @MainActor
    func testCanonicalV2ThreadIgnoresNilSessionChangeFromOldProvider() {
        let session = AssistantSessionSummary(
            id: "openassist-v2-thread",
            title: "Merged",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            activeProvider: .codex,
            providerBindingsByBackend: [
                AssistantProviderBinding(
                    backend: .copilot,
                    providerSessionID: "copilot-session"
                ),
                AssistantProviderBinding(
                    backend: .codex,
                    providerSessionID: "codex-session"
                )
            ],
            status: .idle
        )

        XCTAssertFalse(
            AssistantStore.shouldApplyProviderSessionChange(
                for: session,
                runtimeBackend: .copilot,
                providerSessionID: nil
            )
        )
    }

    @MainActor
    func testCanonicalV2ThreadIgnoresStaleSessionChangeFromOldProvider() {
        let session = AssistantSessionSummary(
            id: "openassist-v2-thread",
            title: "Merged",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            activeProvider: .codex,
            providerBindingsByBackend: [
                AssistantProviderBinding(
                    backend: .copilot,
                    providerSessionID: "copilot-session"
                ),
                AssistantProviderBinding(
                    backend: .codex,
                    providerSessionID: "codex-session"
                )
            ],
            status: .idle
        )

        XCTAssertFalse(
            AssistantStore.shouldApplyProviderSessionChange(
                for: session,
                runtimeBackend: .copilot,
                providerSessionID: "copilot-session"
            )
        )
    }

    @MainActor
    func testCanonicalV2ThreadAcceptsSessionChangeForActiveProvider() {
        let session = AssistantSessionSummary(
            id: "openassist-v2-thread",
            title: "Merged",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            activeProvider: .codex,
            providerBindingsByBackend: [
                AssistantProviderBinding(
                    backend: .copilot,
                    providerSessionID: "copilot-session"
                ),
                AssistantProviderBinding(
                    backend: .codex,
                    providerSessionID: "codex-session"
                )
            ],
            status: .idle
        )

        XCTAssertTrue(
            AssistantStore.shouldApplyProviderSessionChange(
                for: session,
                runtimeBackend: .codex,
                providerSessionID: "codex-session-next"
            )
        )
    }

    @MainActor
    func testRemappedTranscriptMutationUsesCanonicalThreadID() {
        let entryID = UUID()
        let mutation = AssistantTranscriptMutation.appendDelta(
            id: entryID,
            sessionID: "copilot-session",
            role: .assistant,
            delta: "Hi",
            createdAt: Date(timeIntervalSince1970: 123),
            emphasis: false,
            isStreaming: true
        )

        let remapped = AssistantStore.remappedTranscriptMutation(
            mutation,
            sessionID: "openassist-v2-thread"
        )

        guard case let .appendDelta(id, sessionID, role, delta, _, _, isStreaming) = remapped else {
            return XCTFail("Expected appendDelta transcript mutation")
        }

        XCTAssertEqual(id, entryID)
        XCTAssertEqual(sessionID, "openassist-v2-thread")
        XCTAssertEqual(role, .assistant)
        XCTAssertEqual(delta, "Hi")
        XCTAssertTrue(isStreaming)
    }

    @MainActor
    func testRemappedTimelineMutationUsesCanonicalThreadID() {
        let createdAt = Date(timeIntervalSince1970: 456)
        let mutation = AssistantTimelineMutation.appendTextDelta(
            id: "assistant-final-1",
            sessionID: "copilot-session",
            turnID: "copilot-turn",
            kind: .assistantFinal,
            delta: "Hello",
            createdAt: createdAt,
            updatedAt: createdAt,
            isStreaming: true,
            emphasis: false,
            source: .runtime
        )

        let remapped = AssistantStore.remappedTimelineMutation(
            mutation,
            sessionID: "openassist-v2-thread"
        )

        guard case let .appendTextDelta(id, sessionID, turnID, kind, delta, _, _, isStreaming, _, source) = remapped else {
            return XCTFail("Expected appendTextDelta timeline mutation")
        }

        XCTAssertEqual(id, "assistant-final-1")
        XCTAssertEqual(sessionID, "openassist-v2-thread")
        XCTAssertEqual(turnID, "copilot-turn")
        XCTAssertEqual(kind, .assistantFinal)
        XCTAssertEqual(delta, "Hello")
        XCTAssertTrue(isStreaming)
        XCTAssertEqual(source, .runtime)
    }

    @MainActor
    func testRemappedTimelineUpsertPreservesItemButRewritesSessionID() {
        let item = AssistantTimelineItem.assistantFinal(
            id: "assistant-final-2",
            sessionID: "copilot-session",
            turnID: "copilot-turn",
            text: "Hi there",
            createdAt: Date(timeIntervalSince1970: 789),
            updatedAt: Date(timeIntervalSince1970: 790),
            isStreaming: false,
            source: .runtime
        )

        let remapped = AssistantStore.remappedTimelineMutation(
            .upsert(item),
            sessionID: "openassist-v2-thread"
        )

        guard case let .upsert(remappedItem) = remapped else {
            return XCTFail("Expected upsert timeline mutation")
        }

        XCTAssertEqual(remappedItem.sessionID, "openassist-v2-thread")
        XCTAssertEqual(remappedItem.turnID, "copilot-turn")
        XCTAssertEqual(remappedItem.text, "Hi there")
    }

    @MainActor
    func testCanonicalThreadIgnoresImplicitTimelineResetMutation() {
        let session = AssistantSessionSummary(
            id: "openassist-v2-thread",
            title: "Merged",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            activeProvider: .copilot,
            status: .idle
        )

        XCTAssertTrue(
            AssistantStore.shouldIgnoreTimelineResetMutation(
                .reset(sessionID: nil),
                session: session
            )
        )
        XCTAssertFalse(
            AssistantStore.shouldIgnoreTimelineResetMutation(
                .reset(sessionID: "copilot-session"),
                session: session
            )
        )
        XCTAssertFalse(
            AssistantStore.shouldIgnoreTimelineResetMutation(
                .reset(sessionID: nil),
                session: AssistantSessionSummary(
                    id: "copilot-session",
                    title: "CLI",
                    source: .cli,
                    status: .idle
                )
            )
        )
    }

    @MainActor
    func testRuntimeSuppressesNonToolActivityRows() {
        let runtime = CodexAssistantRuntime()

        XCTAssertFalse(runtime.shouldRenderActivity(for: "agentMessage"))
        XCTAssertFalse(runtime.shouldRenderActivity(for: "agent_message"))
        XCTAssertFalse(runtime.shouldRenderActivity(for: "userMessage"))
        XCTAssertFalse(runtime.shouldRenderActivity(for: "user_message"))
        XCTAssertFalse(runtime.shouldRenderActivity(for: "reasoning"))
        XCTAssertFalse(runtime.shouldRenderActivity(for: "plan"))
        XCTAssertTrue(runtime.shouldRenderActivity(for: "commandExecution"))
        XCTAssertTrue(runtime.shouldRenderActivity(for: "command_execution"))
        XCTAssertTrue(runtime.shouldRenderActivity(for: "webSearch"))
        XCTAssertTrue(runtime.shouldRenderActivity(for: "web_search_call"))
    }

    @MainActor
    func testModePolicyAllowsExpectedToolActivityByMode() {
        let runtime = CodexAssistantRuntime()

        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "webSearch"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "web_search_call"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .plan,
                rawType: "web_search_call"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "commandExecution",
                command: "rg --files Sources"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "commandExecution",
                command: "rg TODO Sources | head"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "commandExecution",
                command: "python3 /Users/manikvashith/.codex/skills/obsidian-cli/scripts/obsidian_cli_tool.py summarize --file OpenAssist"
            )
        )
        XCTAssertFalse(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "commandExecution",
                command: "swift test"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .plan,
                rawType: "commandExecution",
                command: "swift test"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .plan,
                rawType: "fileChange"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .plan,
                rawType: "browserAutomation"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .plan,
                rawType: "dynamicToolCall",
                toolName: "browser_use"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .plan,
                rawType: "dynamicToolCall",
                toolName: "app_action"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .plan,
                rawType: "dynamicToolCall",
                toolName: "generate_image"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .plan,
                rawType: "dynamicToolCall",
                toolName: "computer_use"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .plan,
                rawType: "mcpToolCall"
            )
        )
        XCTAssertFalse(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "browserAutomation"
            )
        )
        XCTAssertFalse(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "mcpToolCall"
            )
        )
        XCTAssertFalse(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "dynamicToolCall",
                toolName: "browser_use"
            )
        )
        XCTAssertFalse(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "dynamicToolCall",
                toolName: "app_action"
            )
        )
        XCTAssertFalse(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "dynamicToolCall",
                toolName: "computer_use"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "dynamicToolCall",
                toolName: "web_lookup"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "dynamicToolCall",
                toolName: "generate_image"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "some_new_status_type"
            )
        )
        XCTAssertFalse(
            runtime.isToolActivityAllowedForTesting(
                mode: .conversational,
                rawType: "collabAgentToolCall"
            )
        )
        XCTAssertTrue(
            runtime.isToolActivityAllowedForTesting(
                mode: .agentic,
                rawType: "fileChange"
            )
        )
    }

    @MainActor
    func testBrowserAppAndImageDynamicToolCallsUseFriendlyTitlesAndSummaries() {
        let runtime = CodexAssistantRuntime()

        let browserState = runtime.toolCallStateForTesting(from: [
            "id": "tool-browser",
            "type": "dynamicToolCall",
            "tool": "browser_use",
            "status": "running",
            "arguments": ["task": "Open the team board in Edge."]
        ])

        XCTAssertEqual(browserState?.title, "Browser Use")
        XCTAssertEqual(
            runtime.activitySummaryForTesting(kind: .dynamicToolCall, title: browserState?.title ?? ""),
            "Used the browser."
        )

        let appState = runtime.toolCallStateForTesting(from: [
            "id": "tool-app",
            "type": "dynamicToolCall",
            "tool": "app_action",
            "status": "running",
            "arguments": ["task": "Reveal ~/Downloads in Finder."]
        ])

        XCTAssertEqual(appState?.title, "App Action")
        XCTAssertEqual(
            runtime.activitySummaryForTesting(kind: .dynamicToolCall, title: appState?.title ?? ""),
            "Used a Mac app."
        )

        let imageState = runtime.toolCallStateForTesting(from: [
            "id": "tool-image",
            "type": "dynamicToolCall",
            "tool": "generate_image",
            "status": "running",
            "arguments": ["prompt": "Create a small synthwave poster."]
        ])

        XCTAssertEqual(imageState?.title, "Image Generation")
        XCTAssertEqual(
            runtime.activitySummaryForTesting(kind: .dynamicToolCall, title: imageState?.title ?? ""),
            "Generated an image."
        )

        let computerState = runtime.toolCallStateForTesting(from: [
            "id": "tool-computer",
            "type": "dynamicToolCall",
            "tool": "computer_use",
            "status": "running",
            "arguments": [
                "task": "Click the Filters button.",
                "reason": "Need generic UI interaction.",
                "action": ["type": "click", "x": 120, "y": 40]
            ]
        ])

        XCTAssertEqual(computerState?.title, "Computer Use")
        XCTAssertEqual(
            runtime.activitySummaryForTesting(kind: .dynamicToolCall, title: computerState?.title ?? ""),
            "Controlled the visible desktop."
        )
    }

    @MainActor
    func testCollaborationEventsCaptureParentThreadAndLifecycleTimestamps() {
        let runtime = CodexAssistantRuntime()
        runtime.setCurrentSessionIDForTesting("parent-thread")

        runtime.processCollaborationNotificationForTesting(
            method: "item/collabAgentSpawn/begin",
            params: [
                "call_id": "agent-1",
                "prompt": "Inspect the provider flow"
            ]
        )

        var spawnedAgent = try! XCTUnwrap(runtime.subagentsForTesting().first)
        XCTAssertEqual(spawnedAgent.parentThreadID, "parent-thread")
        XCTAssertEqual(spawnedAgent.status, .spawning)
        XCTAssertNotNil(spawnedAgent.startedAt)
        XCTAssertNotNil(spawnedAgent.updatedAt)
        XCTAssertNil(spawnedAgent.endedAt)

        runtime.processCollaborationNotificationForTesting(
            method: "item/collabAgentSpawn/end",
            params: [
                "call_id": "agent-1",
                "new_thread_id": "child-thread",
                "new_agent_nickname": "Kant",
                "new_agent_role": "explorer"
            ]
        )

        spawnedAgent = try! XCTUnwrap(runtime.subagentsForTesting().first)
        XCTAssertEqual(spawnedAgent.threadID, "child-thread")
        XCTAssertEqual(spawnedAgent.nickname, "Kant")
        XCTAssertEqual(spawnedAgent.role, "explorer")
        XCTAssertEqual(spawnedAgent.status, .running)
        XCTAssertNil(spawnedAgent.endedAt)

        runtime.processCollaborationNotificationForTesting(
            method: "item/collabWaiting/begin",
            params: [
                "receiver_thread_ids": ["child-thread"]
            ]
        )
        XCTAssertEqual(runtime.subagentsForTesting().first?.status, .waiting)

        runtime.processCollaborationNotificationForTesting(
            method: "item/collabWaiting/end",
            params: [
                "receiver_thread_ids": ["child-thread"]
            ]
        )

        let completedAgent = try! XCTUnwrap(runtime.subagentsForTesting().first)
        XCTAssertEqual(completedAgent.status, .completed)
        XCTAssertNotNil(completedAgent.endedAt)
        XCTAssertEqual(completedAgent.updatedAt, completedAgent.endedAt)
    }

    @MainActor
    func testCollabToolCallReadsChildThreadMetadataFromResultPayload() {
        let runtime = CodexAssistantRuntime()
        runtime.setCurrentSessionIDForTesting("parent-thread")

        _ = runtime.toolCallStateForTesting(from: [
            "id": "agent-tool-1",
            "type": "collabAgentToolCall",
            "tool": "SpawnAgent",
            "status": "completed",
            "arguments": [
                "prompt": "Inspect the cleanup flow"
            ],
            "result": [
                "new_thread_id": "child-thread",
                "new_agent_nickname": "Kant",
                "new_agent_role": "explorer"
            ]
        ])

        let agent = try! XCTUnwrap(runtime.subagentsForTesting().first)
        XCTAssertEqual(agent.parentThreadID, "parent-thread")
        XCTAssertEqual(agent.threadID, "child-thread")
        XCTAssertEqual(agent.nickname, "Kant")
        XCTAssertEqual(agent.role, "explorer")
        XCTAssertEqual(agent.prompt, "Inspect the cleanup flow")
    }

    @MainActor
    func testToolUserInputRequestKeepsQuestionsStructured() async {
        let runtime = CodexAssistantRuntime()
        var capturedRequest: AssistantPermissionRequest?
        runtime.onPermissionRequest = { request in
            capturedRequest = request
        }

        await runtime.processServerRequestForTesting(
            method: "item/tool/requestUserInput",
            params: [
                "threadId": "session-1",
                "questions": [
                    [
                        "id": "runtime",
                        "header": "Runtime",
                        "question": "How should the Codex backend run for version 1 of the Electron app?",
                        "options": [
                            [
                                "label": "Sidecar (Recommended)",
                                "description": "Keep the app shell simple and talk to Codex through the existing sidecar process."
                            ],
                            [
                                "label": "Local CLI",
                                "description": "Run the CLI directly inside the app."
                            ]
                        ]
                    ],
                    [
                        "id": "streaming",
                        "header": "Streaming",
                        "question": "What kind of frontend streaming do you want to preserve in the current UI?",
                        "options": [
                            [
                                "label": "Token streaming (Recommended)",
                                "description": "Keep the current gradual answer rendering."
                            ],
                            [
                                "label": "Chunk updates",
                                "description": "Only update the answer in bigger blocks."
                            ]
                        ]
                    ]
                ]
            ]
        )

        XCTAssertEqual(capturedRequest?.toolKind, "userInput")
        XCTAssertEqual(capturedRequest?.toolTitle, "Codex needs input")
        XCTAssertNil(capturedRequest?.rationale)
        XCTAssertTrue(capturedRequest?.options.isEmpty ?? false)
        XCTAssertEqual(capturedRequest?.userInputQuestions.count, 2)
        XCTAssertEqual(capturedRequest?.userInputQuestions.first?.header, "Runtime")
        XCTAssertEqual(capturedRequest?.userInputQuestions.last?.header, "Streaming")
        XCTAssertEqual(
            capturedRequest?.userInputQuestions.first?.options.map(\.label),
            ["Sidecar (Recommended)", "Local CLI"]
        )
    }

    @MainActor
    func testSnakeCaseWebSearchUsesFriendlyTitleAndSummary() {
        let runtime = CodexAssistantRuntime()

        let state = runtime.toolCallStateForTesting(from: [
            "id": "web-1",
            "type": "web_search_call",
            "status": "completed",
            "action": ["query": "SCIM duplicate user conflict"]
        ])

        XCTAssertEqual(state?.title, "Web Search")
        XCTAssertEqual(state?.detail, "SCIM duplicate user conflict")
        XCTAssertEqual(
            runtime.activitySummaryForTesting(kind: .webSearch, title: state?.title ?? ""),
            "Searched the web."
        )
    }

    @MainActor
    func testTerminalAppActionsAlwaysRequireFreshConfirmation() {
        let runtime = CodexAssistantRuntime()

        XCTAssertTrue(
            runtime.dynamicToolRequiresExplicitConfirmationForTesting(
                toolName: "app_action",
                arguments: [
                    "task": "Run git push in Terminal.",
                    "app": "Terminal",
                    "command": "git push"
                ]
            )
        )
        XCTAssertTrue(
            runtime.dynamicToolRequiresExplicitConfirmationForTesting(
                toolName: "app_action",
                arguments: [
                    "task": "Create the calendar event now.",
                    "app": "Calendar",
                    "commit": true
                ]
            )
        )
        XCTAssertFalse(
            runtime.dynamicToolRequiresExplicitConfirmationForTesting(
                toolName: "app_action",
                arguments: [
                    "task": "Reveal ~/Downloads in Finder.",
                    "app": "Finder",
                    "path": "~/Downloads"
                ]
            )
        )
        XCTAssertTrue(
            runtime.dynamicToolRequiresExplicitConfirmationForTesting(
                toolName: "computer_use",
                arguments: [
                    "task": "Type the final message, then submit it.",
                    "reason": "Need to post the reply in the live app UI.",
                    "targetLabel": "Reply field",
                    "action": [
                        "type": "type",
                        "text": "Shipping now."
                    ]
                ]
            )
        )
        XCTAssertFalse(
            runtime.dynamicToolRequiresExplicitConfirmationForTesting(
                toolName: "computer_use",
                arguments: [
                    "task": "Scroll the current page to the metrics table.",
                    "reason": "Need to reach data that is only visible in the live UI.",
                    "targetLabel": "Metrics table",
                    "action": [
                        "type": "scroll",
                        "x": 400,
                        "y": 200,
                        "scroll_y": 600
                    ]
                ]
            )
        )
    }

    @MainActor
    func testBlockedToolUseMessagesTellUserToSwitchModes() {
        let runtime = CodexAssistantRuntime()

        let conversational = runtime.blockedToolUseMessage(
            for: .conversational,
            activityTitle: "swift test",
            commandClass: .validation
        )
        XCTAssertTrue(conversational.contains("cannot run build or test checks"))
        XCTAssertTrue(conversational.contains("Plan or Agentic mode"))
        XCTAssertTrue(conversational.contains("swift test"))

        let plan = runtime.blockedToolUseMessage(
            for: .plan,
            activityTitle: "Command"
        )
        XCTAssertTrue(plan.contains("Plan mode focuses on exploration and planning"))

        let browserUse = runtime.blockedToolUseMessage(
            for: .conversational,
            activityTitle: "Browser Use"
        )
        XCTAssertTrue(browserUse.contains("Agentic mode"))

        let appAction = runtime.blockedToolUseMessage(
            for: .conversational,
            activityTitle: "App Action"
        )
        XCTAssertTrue(appAction.contains("Agentic mode"))
    }

    @MainActor
    func testAgenticModeExposesBrowserAppAndImageDynamicTools() {
        let runtime = CodexAssistantRuntime()
        let originalValue = SettingsStore.shared.assistantComputerUseEnabled
        SettingsStore.shared.assistantComputerUseEnabled = true
        defer {
            SettingsStore.shared.assistantComputerUseEnabled = originalValue
        }

        XCTAssertEqual(
            runtime.dynamicToolNamesForTesting(mode: .agentic),
            [
                "generate_image",
                "app_action",
                "browser_use",
                "exec_command",
                "write_stdin",
                "read_terminal",
                "view_image",
                "screen_capture",
                "window_list",
                "window_capture",
                "ui_inspect",
                "ui_click",
                "ui_type",
                "ui_press_key",
                "computer_use"
            ]
        )
    }

    @MainActor
    func testDraftPlanRequestSuggestsSwitchToPlanMode() {
        let suggestion = AssistantStore.modeSwitchSuggestion(
            forDraft: "Can you make a plan for this refactor first?",
            currentMode: .conversational
        )

        XCTAssertEqual(suggestion?.source, .draft)
        XCTAssertEqual(suggestion?.choices.map(\.mode), [.plan])
        XCTAssertEqual(suggestion?.choices.first?.resendLastRequest, false)
    }

    @MainActor
    func testBlockedValidationInChatSuggestsPlanAndAgenticRetry() {
        let suggestion = AssistantStore.modeSwitchSuggestion(
            for: AssistantModeRestrictionEvent(
                mode: .conversational,
                activityTitle: "Command",
                commandClass: .validation
            )
        )

        XCTAssertEqual(suggestion?.source, .blocked)
        XCTAssertEqual(suggestion?.choices.map(\.mode), [.plan, .agentic])
        XCTAssertTrue(suggestion?.choices.allSatisfy(\.resendLastRequest) == true)
    }

    @MainActor
    func testAssistantModelOptionTracksImageInputSupport() {
        let imageModel = AssistantModelOption(
            id: "gpt-5.4",
            displayName: "GPT-5.4",
            description: "Vision ready",
            isDefault: false,
            hidden: false,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: nil,
            inputModalities: ["text", "image"]
        )
        XCTAssertTrue(imageModel.supportsImageInput)

        let textOnlyModel = AssistantModelOption(
            id: "text-only",
            displayName: "Text Only",
            description: "No vision",
            isDefault: false,
            hidden: false,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: nil,
            inputModalities: ["text"]
        )
        XCTAssertFalse(textOnlyModel.supportsImageInput)
    }

    @MainActor
    func testUnsupportedImageAttachmentMessageAppearsForTextOnlyModel() {
        let attachment = AssistantAttachment(
            filename: "screen.png",
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png"
        )
        let model = AssistantModelOption(
            id: "text-only",
            displayName: "Text Only",
            description: "No vision",
            isDefault: false,
            hidden: false,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: nil,
            inputModalities: ["text"]
        )

        let message = AssistantStore.unsupportedImageAttachmentMessage(
            for: [attachment],
            selectedModel: model
        )

        XCTAssertEqual(
            message,
            "The selected model Text Only cannot read image attachments. Choose a model that supports image input and try again. Attached images can still be analyzed directly when the model supports them, but live browser or app automation needs Agentic mode."
        )
    }

    @MainActor
    func testChatModeRedirectsFirstToolAttemptBackToAttachedImageAnalysis() {
        let runtime = CodexAssistantRuntime()
        runtime.interactionMode = .conversational
        runtime.configureImageAttachmentContextForTesting(
            includesImages: true,
            modelSupportsImageInput: true
        )

        XCTAssertTrue(runtime.shouldRedirectBlockedImageToolRequestForTesting(method: "item/tool/call"))

        runtime.configureImageAttachmentContextForTesting(
            includesImages: true,
            modelSupportsImageInput: true,
            redirectedAlready: true
        )
        XCTAssertFalse(runtime.shouldRedirectBlockedImageToolRequestForTesting(method: "item/tool/call"))
    }

    @MainActor
    func testImageAttachmentUsesCodexInputImageShape() {
        let attachment = AssistantAttachment(
            filename: "screen.png",
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png"
        )

        let item = attachment.toInputItem()

        XCTAssertEqual(item["type"] as? String, "image")
        XCTAssertTrue((item["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    }

    @MainActor
    func testCLIAttachmentContextPersistsAcrossFollowUpTurnsInSameSession() throws {
        let runtime = CodexAssistantRuntime()
        let attachment = AssistantAttachment(
            filename: "plan.md",
            data: Data("hello from attachment".utf8),
            mimeType: "text/markdown"
        )

        let initialContext = try XCTUnwrap(
            runtime.cliAttachmentContextForTesting(
                sessionID: "thread-a",
                attachments: [attachment]
            )
        )
        let attachmentPath = try XCTUnwrap(cliAttachmentPath(from: initialContext))
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentPath))

        let followUpContext = try XCTUnwrap(
            runtime.cliAttachmentContextForTesting(
                sessionID: "thread-a",
                attachments: []
            )
        )
        XCTAssertEqual(followUpContext, initialContext)

        runtime.clearCLIAttachmentsForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentPath))
    }

    @MainActor
    func testCLIAttachmentContextCleansUpWhenSessionChanges() throws {
        let runtime = CodexAssistantRuntime()
        let attachment = AssistantAttachment(
            filename: "plan.md",
            data: Data("hello from attachment".utf8),
            mimeType: "text/markdown"
        )

        let initialContext = try XCTUnwrap(
            runtime.cliAttachmentContextForTesting(
                sessionID: "thread-a",
                attachments: [attachment]
            )
        )
        let attachmentPath = try XCTUnwrap(cliAttachmentPath(from: initialContext))
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentPath))

        XCTAssertNil(
            try runtime.cliAttachmentContextForTesting(
                sessionID: "thread-b",
                attachments: []
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentPath))
    }

    @MainActor
    func testCombinedRuntimeInstructionsIncludesOneShotPlanWithoutDroppingOtherInstructions() {
        let instructions = AssistantStore.combinedRuntimeInstructions(
            global: "Use simple language.",
            session: "Stay in the selected repo.",
            oneShot: "# Plan to Execute\n\nRun the cleanup flow."
        )

        XCTAssertEqual(
            instructions,
            """
            Use simple language.

            Stay in the selected repo.

            # Plan to Execute

            Run the cleanup flow.
            """
        )
    }

    @MainActor
    func testCombinedRuntimeInstructionsReturnsNilWhenEverySectionIsBlank() {
        XCTAssertNil(
            AssistantStore.combinedRuntimeInstructions(
                global: "  ",
                session: "\n",
                oneShot: ""
            )
        )
    }

    @MainActor
    func testInteractionModesUseExpectedOrderAndCodexModeKinds() {
        XCTAssertEqual(
            AssistantInteractionMode.allCases,
            [.plan, .agentic]
        )

        XCTAssertEqual(AssistantInteractionMode.conversational.codexModeKind, "default")
        XCTAssertEqual(AssistantInteractionMode.plan.codexModeKind, "plan")
        XCTAssertEqual(AssistantInteractionMode.agentic.codexModeKind, "default")
    }

    @MainActor
    func testChatAndPlanModesExposeOnlySafeImageToolOutsideAgenticAutomation() {
        let runtime = CodexAssistantRuntime()
        let originalValue = SettingsStore.shared.assistantComputerUseEnabled
        SettingsStore.shared.assistantComputerUseEnabled = false
        defer {
            SettingsStore.shared.assistantComputerUseEnabled = originalValue
        }

        XCTAssertEqual(runtime.dynamicToolNamesForTesting(mode: .conversational), ["generate_image"])
        XCTAssertEqual(runtime.dynamicToolNamesForTesting(mode: .plan), ["generate_image"])
        XCTAssertEqual(
            runtime.dynamicToolNamesForTesting(mode: .agentic),
            [
                "generate_image",
                "app_action",
                "browser_use",
                "exec_command",
                "write_stdin",
                "read_terminal",
                "view_image",
                "screen_capture",
                "window_list",
                "window_capture",
                "ui_inspect",
                "ui_click",
                "ui_type",
                "ui_press_key"
            ]
        )
    }

    @MainActor
    func testAgenticModeExposesComputerUseOnlyWhenSettingIsEnabled() {
        let runtime = CodexAssistantRuntime()
        let originalValue = SettingsStore.shared.assistantComputerUseEnabled
        defer {
            SettingsStore.shared.assistantComputerUseEnabled = originalValue
        }

        SettingsStore.shared.assistantComputerUseEnabled = false
        XCTAssertFalse(
            runtime.dynamicToolNamesForTesting(mode: .agentic).contains("computer_use")
        )

        SettingsStore.shared.assistantComputerUseEnabled = true
        XCTAssertTrue(
            runtime.dynamicToolNamesForTesting(mode: .agentic).contains("computer_use")
        )
    }

    @MainActor
    func testChatTurnStartParamsUseReadOnlySandboxAndUnlessTrustedApproval() {
        let runtime = CodexAssistantRuntime()

        let chatParams = runtime.turnStartParamsForTesting(mode: .conversational)
        XCTAssertEqual(chatParams["approvalPolicy"] as? String, "untrusted")
        XCTAssertEqual(
            (chatParams["sandboxPolicy"] as? [String: Any])?["type"] as? String,
            "readOnly"
        )
        XCTAssertEqual(
            (chatParams["sandboxPolicy"] as? [String: Any])?["networkAccess"] as? Bool,
            true
        )

        let planParams = runtime.turnStartParamsForTesting(mode: .plan)
        XCTAssertEqual(planParams["approvalPolicy"] as? String, "on-request")
        XCTAssertNil(planParams["sandboxPolicy"])
    }

    @MainActor
    func testTurnStartParamsCanUseSeparateSubagentModelOverride() {
        let runtime = CodexAssistantRuntime(preferredModelID: "gpt-5.4")
        runtime.setPreferredSubagentModelID("gpt-5.4-mini")
        runtime.reasoningEffort = "high"

        let params = runtime.turnStartParamsForTesting(mode: .agentic, modelID: "gpt-5.4")
        let collaborationMode = params["collaborationMode"] as? [String: Any]
        let settings = collaborationMode?["settings"] as? [String: Any]

        XCTAssertEqual(params["model"] as? String, "gpt-5.4")
        XCTAssertEqual(settings?["model"] as? String, "gpt-5.4-mini")
        XCTAssertNil(settings?["reasoningEffort"])
    }

    @MainActor
    func testBrowserAutomationRequirementBlocksBrowserTaskUntilSetupIsReady() {
        XCTAssertEqual(
            AssistantStore.browserAutomationRequirement(
                for: "Open https://x.com and summarize the first post.",
                browserAutomationEnabled: false,
                hasSelectedBrowserProfile: false
            ),
            .enableAutomation
        )

        XCTAssertEqual(
            AssistantStore.browserAutomationRequirement(
                for: "Open https://x.com and summarize the first post.",
                browserAutomationEnabled: true,
                hasSelectedBrowserProfile: false
            ),
            .selectProfile
        )

        XCTAssertEqual(
            AssistantStore.browserAutomationRequirement(
                for: "Open https://x.com and summarize the first post.",
                browserAutomationEnabled: true,
                hasSelectedBrowserProfile: true
            ),
            .none
        )
    }

    @MainActor
    func testBrowserContextOverrideIsOnlyInjectedWhenThreadNeedsPriming() {
        XCTAssertTrue(
            AssistantStore.shouldInjectBrowserContextOverride(
                for: "Open https://x.com and summarize the first post.",
                currentBrowserSignature: "Brave Browser|Profile 1",
                primedBrowserSignature: nil
            )
        )

        XCTAssertFalse(
            AssistantStore.shouldInjectBrowserContextOverride(
                for: "Open https://x.com and summarize the first post.",
                currentBrowserSignature: "Brave Browser|Profile 1",
                primedBrowserSignature: "Brave Browser|Profile 1"
            )
        )

        XCTAssertTrue(
            AssistantStore.shouldInjectBrowserContextOverride(
                for: "Open https://x.com and summarize the first post.",
                currentBrowserSignature: "Brave Browser|Profile 2",
                primedBrowserSignature: "Brave Browser|Profile 1"
            )
        )
    }

    @MainActor
    func testLooksLikeBrowserAutomationRequestIgnoresNonAutomationQuestion() {
        XCTAssertFalse(
            AssistantStore.looksLikeBrowserAutomationRequest(
                "Explain how browser profiles change the assistant session."
            )
        )
    }

    @MainActor
    func testBlockedCommandActivityDoesNotPublishToolRowBeforeMessage() {
        let runtime = CodexAssistantRuntime()
        runtime.interactionMode = .conversational
        let recorder = AssistantRuntimeEventRecorder()

        runtime.onToolCallUpdate = { recorder.toolSnapshots.append($0) }
        runtime.onTimelineMutation = { mutation in
            if case let .upsert(item) = mutation,
               item.kind == .activity,
               let activity = item.activity {
                recorder.activityTitles.append(activity.title)
            }
        }
        runtime.onTranscript = { entry in
            if entry.role == .system {
                recorder.systemMessages.append(entry.text)
            }
        }

        runtime.processActivityEventForTesting([
            "id": "cmd-1",
            "type": "commandExecution",
            "status": "running",
            "command": "swift test"
        ])

        XCTAssertTrue(recorder.toolSnapshots.isEmpty)
        XCTAssertTrue(recorder.activityTitles.isEmpty)
        XCTAssertEqual(recorder.systemMessages.count, 1)
        XCTAssertTrue(recorder.systemMessages[0].contains("cannot run build or test checks"))
    }

    @MainActor
    func testBlockedActivityMessageIsOnlyEmittedOnceForStartedAndCompletedEvents() {
        let runtime = CodexAssistantRuntime()
        runtime.interactionMode = .conversational
        let recorder = AssistantRuntimeEventRecorder()
        runtime.onTranscript = { entry in
            if entry.role == .system {
                recorder.systemMessages.append(entry.text)
            }
        }

        let blockedItem: [String: Any] = [
            "id": "cmd-2",
            "type": "commandExecution",
            "status": "running",
            "command": "swift test"
        ]

        runtime.processActivityEventForTesting(blockedItem)
        runtime.processActivityEventForTesting(blockedItem, isCompleted: true)

        XCTAssertEqual(recorder.systemMessages.count, 1)
        XCTAssertTrue(recorder.systemMessages[0].contains("cannot run build or test checks"))
    }

    @MainActor
    func testBrowserTurnReminderCarriesCurrentProfileDetails() {
        let reminder = CodexAssistantRuntime.browserTurnReminder(
            from: [
                "browser": "Brave Browser",
                "channel": "brave",
                "profileDir": "Profile 1",
                "userDataDir": "/Users/test/Library/Application Support/BraveSoftware/Brave-Browser",
                "profileName": "Personal"
            ],
            computerUseEnabled: true
        )

        XCTAssertNotNil(reminder)
        XCTAssertTrue(reminder?.contains("Profile: Personal") == true)
        XCTAssertTrue(reminder?.contains("Brave Browser") == true)
        XCTAssertTrue(reminder?.contains("Profile 1") == true)
        XCTAssertTrue(reminder?.contains("Do NOT use MCP browser tools") == true)
        XCTAssertTrue(reminder?.contains("Use `computer_use` only as a last resort") == true)
        XCTAssertFalse(reminder?.contains("launchPersistentContext") == true)
        XCTAssertFalse(reminder?.contains("Playwright") == true)
    }

    @MainActor
    func testBrowserTurnReminderExplainsWhenComputerUseIsDisabled() {
        let reminder = CodexAssistantRuntime.browserTurnReminder(
            from: [
                "browser": "Brave Browser",
                "channel": "brave",
                "profileDir": "Profile 1",
                "userDataDir": "/Users/test/Library/Application Support/BraveSoftware/Brave-Browser",
                "profileName": "Personal"
            ],
            computerUseEnabled: false
        )

        XCTAssertNotNil(reminder)
        XCTAssertTrue(reminder?.contains("Computer Use is currently turned off in settings") == true)
        XCTAssertFalse(reminder?.contains("switch to `computer_use` instead") == true)
    }

    @MainActor
    func testBuildInstructionsIncludesBrowserTurnReminderWhenProfileIsConfigured() async {
        let runtime = CodexAssistantRuntime()
        let originalValue = SettingsStore.shared.assistantComputerUseEnabled
        SettingsStore.shared.assistantComputerUseEnabled = true
        defer {
            SettingsStore.shared.assistantComputerUseEnabled = originalValue
        }
        runtime.browserProfileContext = [
            "browser": "Brave Browser",
            "channel": "brave",
            "profileDir": "Profile 1",
            "userDataDir": "/Users/test/Library/Application Support/BraveSoftware/Brave-Browser",
            "profileName": "Personal"
        ]

        let instructions = await runtime.buildInstructionsForTesting()

        XCTAssertTrue(instructions.contains("# Browser Task Override"))
        XCTAssertTrue(instructions.contains("Do NOT use MCP browser tools"))
        XCTAssertTrue(instructions.contains("Profile: Personal"))
    }

    @MainActor
    func testBrowserMcpToolCallsAreBlockedInAgenticMode() {
        let runtime = CodexAssistantRuntime()
        runtime.interactionMode = .agentic

        let recorder = AssistantRuntimeEventRecorder()
        runtime.onTranscript = { entry in
            if entry.role == .system {
                recorder.systemMessages.append(entry.text)
            }
        }

        runtime.processActivityEventForTesting([
            "id": "mcp-browser-1",
            "type": "mcpToolCall",
            "server": "Playwright",
            "tool": "browser_run_code",
            "status": "running"
        ])

        XCTAssertEqual(recorder.systemMessages.count, 1)
        XCTAssertTrue(recorder.systemMessages[0].contains("selected signed-in browser profile"))
        XCTAssertTrue(recorder.systemMessages[0].contains("browser_run_code"))
    }

    @MainActor
    func testBuildInstructionsIncludesActiveSkillsBlock() async {
        let runtime = CodexAssistantRuntime()
        runtime.activeSkills = [
            AssistantSkillDescriptor(
                name: "obsidian-cli",
                displayName: "Obsidian CLI",
                description: "Use the vault tools for note tasks.",
                shortDescription: "Manage notes in Obsidian",
                defaultPrompt: "Use $obsidian-cli for vault work.",
                source: .imported,
                skillDirectoryPath: "/tmp/obsidian-cli",
                skillFilePath: "/tmp/obsidian-cli/SKILL.md",
                metadataFilePath: nil
            )
        ]

        let instructions = await runtime.buildInstructionsForTesting()

        XCTAssertTrue(instructions.contains("# Active Skills"))
        XCTAssertTrue(instructions.contains("`obsidian-cli`"))
        XCTAssertTrue(instructions.contains("Manage notes in Obsidian"))
        XCTAssertTrue(instructions.contains("`/tmp/obsidian-cli/SKILL.md`"))
    }

    @MainActor
    func testShouldPreserveProposedPlanOnlyForMatchingSession() {
        XCTAssertTrue(
            AssistantStore.shouldPreserveProposedPlan(
                planSessionID: "THREAD-123",
                activeSessionID: "thread-123"
            )
        )

        XCTAssertFalse(
            AssistantStore.shouldPreserveProposedPlan(
                planSessionID: "thread-123",
                activeSessionID: "thread-456"
            )
        )

        XCTAssertFalse(
            AssistantStore.shouldPreserveProposedPlan(
                planSessionID: "thread-123",
                activeSessionID: nil
            )
        )
    }

    @MainActor
    func testPlanExecutionSessionIDUsesOnlyPlanSession() {
        XCTAssertEqual(
            AssistantStore.planExecutionSessionID(planSessionID: "plan-thread"),
            "plan-thread"
        )
    }

    @MainActor
    func testPlanExecutionSessionIDReturnsNilWhenPlanSessionMissing() {
        XCTAssertNil(
            AssistantStore.planExecutionSessionID(planSessionID: nil)
        )

        XCTAssertNil(
            AssistantStore.planExecutionSessionID(planSessionID: " \n ")
        )
    }

    @MainActor
    func testResolvedSessionConfigurationFallsBackToDefaultsForLegacySessions() {
        let legacySession = AssistantSessionSummary(
            id: "legacy-thread",
            title: "Legacy",
            source: .appServer,
            status: .completed,
            cwd: nil,
            updatedAt: Date(),
            summary: nil,
            latestModel: nil,
            latestInteractionMode: nil,
            latestReasoningEffort: nil,
            latestServiceTier: nil,
            latestUserMessage: nil,
            latestAssistantMessage: nil
        )

        let configuration = AssistantStore.resolvedSessionConfiguration(
            from: legacySession,
            backend: .codex,
            availableModels: [
                AssistantModelOption(
                    id: "gpt-5.4",
                    displayName: "GPT-5.4",
                    description: "Default",
                    isDefault: true,
                    hidden: false,
                    supportedReasoningEfforts: ["high"],
                    defaultReasoningEffort: "high"
                )
            ],
            preferredModelID: "gpt-5.4"
        )

        XCTAssertEqual(configuration.modelID, "gpt-5.4")
        XCTAssertEqual(configuration.interactionMode, AssistantInteractionMode.agentic)
        XCTAssertEqual(configuration.reasoningEffort, AssistantReasoningEffort.high)
        XCTAssertFalse(configuration.fastModeEnabled)
    }

    @MainActor
    func testResolvedModelSelectionFallsBackToProviderDefaultForV2Threads() {
        let v2Session = AssistantSessionSummary(
            id: "openassist-thread",
            title: "Merged",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            activeProvider: .copilot,
            providerBindingsByBackend: [
                AssistantProviderBinding(backend: .copilot)
            ],
            status: .idle,
            latestModel: "gpt-5.4"
        )

        let resolved = AssistantStore.resolvedModelSelection(
            from: v2Session,
            backend: .copilot,
            availableModels: [
                AssistantModelOption(
                    id: "gemini-2.5-pro",
                    displayName: "Gemini 2.5 Pro",
                    description: "Default",
                    isDefault: true,
                    hidden: false,
                    supportedReasoningEfforts: ["high"],
                    defaultReasoningEffort: "high"
                ),
                AssistantModelOption(
                    id: "gpt-4.1",
                    displayName: "GPT-4.1",
                    description: "Other",
                    isDefault: false,
                    hidden: false,
                    supportedReasoningEfforts: ["high"],
                    defaultReasoningEffort: "high"
                )
            ],
            preferredModelID: "gpt-5.4"
        )

        XCTAssertEqual(resolved, "gemini-2.5-pro")
    }

    @MainActor
    func testResolvedModelSelectionUsesBoundProviderModelForV2Threads() {
        let v2Session = AssistantSessionSummary(
            id: "openassist-thread",
            title: "Merged",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            activeProvider: .copilot,
            providerBindingsByBackend: [
                AssistantProviderBinding(
                    backend: .copilot,
                    latestModelID: "gpt-4.1"
                )
            ],
            status: .idle
        )

        let resolved = AssistantStore.resolvedModelSelection(
            from: v2Session,
            backend: .copilot,
            availableModels: [
                AssistantModelOption(
                    id: "gemini-2.5-pro",
                    displayName: "Gemini 2.5 Pro",
                    description: "Default",
                    isDefault: true,
                    hidden: false,
                    supportedReasoningEfforts: ["high"],
                    defaultReasoningEffort: "high"
                ),
                AssistantModelOption(
                    id: "gpt-4.1",
                    displayName: "GPT-4.1",
                    description: "Other",
                    isDefault: false,
                    hidden: false,
                    supportedReasoningEfforts: ["high"],
                    defaultReasoningEffort: "high"
                )
            ],
            preferredModelID: "gpt-5.4"
        )

        XCTAssertEqual(resolved, "gpt-4.1")
    }

    @MainActor
    func testPlanModePromotesPlainFinalAssistantTextIntoPlanTimelineBeforeTurnIDClears() async {
        let runtime = CodexAssistantRuntime()
        let text = """
        1. Inspect the existing speech flow.
        2. Add the Hume cloud voice path.
        3. Add a safe fallback.
        """
        let recorder = AssistantRuntimeEventRecorder()

        runtime.onTimelineMutation = { mutation in
            if case let .upsert(item) = mutation {
                recorder.timelineItems.append(item)
            }
        }
        runtime.onProposedPlan = { recorder.proposedPlans.append($0) }

        runtime.configureStreamingTurnForTesting(
            sessionID: "thread-plan",
            turnID: "turn-plan",
            text: text,
            mode: .plan
        )

        runtime.processCopilotPromptCompletionForTesting()

        let finalAssistant = recorder.timelineItems.last {
            $0.kind == .assistantFinal && $0.isStreaming == false
        }
        let promotedPlan = recorder.timelineItems.last {
            $0.kind == .plan && $0.isStreaming == false
        }

        XCTAssertEqual(finalAssistant?.turnID, "turn-plan")
        XCTAssertEqual(promotedPlan?.turnID, "turn-plan")
        XCTAssertEqual(promotedPlan?.planText, text)
        XCTAssertEqual(recorder.proposedPlans.last ?? nil, text)
    }

    @MainActor
    func testCopilotThoughtChunksDoNotCreateVisibleProgressMessages() async {
        let runtime = CodexAssistantRuntime()
        let recorder = AssistantRuntimeEventRecorder()

        runtime.onTimelineMutation = { mutation in
            if case let .upsert(item) = mutation {
                recorder.timelineItems.append(item)
            }
        }

        runtime.configureStreamingTurnForTesting(
            sessionID: "copilot-thread",
            turnID: "copilot-turn",
            text: "",
            mode: .agentic
        )

        await runtime.processCopilotSessionUpdateForTesting([
            "sessionUpdate": "agent_thought_chunk",
            "content": ["text": "Processing the Greeting"]
        ])

        XCTAssertFalse(recorder.timelineItems.contains(where: { $0.kind == .assistantProgress }))
    }

    @MainActor
    func testCodexIgnoresStrayAssistantDeltaWithoutActiveTurn() async {
        let runtime = CodexAssistantRuntime()
        let recorder = AssistantRuntimeEventRecorder()

        runtime.onTranscriptMutation = { mutation in
            if case let .appendDelta(_, _, _, delta, _, _, _) = mutation {
                recorder.systemMessages.append(delta)
            }
        }
        runtime.onTimelineMutation = { mutation in
            if case let .appendTextDelta(_, _, _, _, delta, _, _, _, _, _) = mutation {
                recorder.activityTitles.append(delta)
            }
        }

        runtime.configureSessionForTesting(sessionID: "thread-stray", turnID: nil)

        await runtime.processAgentMessageDeltaNotificationForTesting(
            delta: "Old reply that should be ignored",
            threadID: "thread-stray"
        )

        XCTAssertTrue(recorder.systemMessages.isEmpty)
        XCTAssertTrue(recorder.activityTitles.isEmpty)
    }

    @MainActor
    func testCopilotIgnoresStrayAssistantChunkWithoutActiveTurn() async {
        let runtime = CodexAssistantRuntime()
        let recorder = AssistantRuntimeEventRecorder()

        runtime.onTranscriptMutation = { mutation in
            if case let .appendDelta(_, _, _, delta, _, _, _) = mutation {
                recorder.systemMessages.append(delta)
            }
        }
        runtime.onTimelineMutation = { mutation in
            if case let .appendTextDelta(_, _, _, _, delta, _, _, _, _, _) = mutation {
                recorder.activityTitles.append(delta)
            }
        }

        runtime.configureSessionForTesting(sessionID: "copilot-thread", turnID: nil)

        await runtime.processCopilotSessionUpdateForTesting([
            "sessionId": "copilot-thread",
            "sessionUpdate": "agent_message_chunk",
            "content": ["text": "Old reply that should be ignored"]
        ])

        XCTAssertTrue(recorder.systemMessages.isEmpty)
        XCTAssertTrue(recorder.activityTitles.isEmpty)
    }

    @MainActor
    func testCopilotInternalCompletionToolPromotesCleanFinalReply() async {
        let runtime = CodexAssistantRuntime()
        let recorder = AssistantRuntimeEventRecorder()

        runtime.onToolCallUpdate = { recorder.toolSnapshots.append($0) }
        runtime.onTimelineMutation = { mutation in
            if case let .upsert(item) = mutation {
                recorder.timelineItems.append(item)
            }
        }

        runtime.configureStreamingTurnForTesting(
            sessionID: "copilot-thread",
            turnID: "copilot-turn",
            text: "",
            mode: .agentic
        )

        await runtime.processCopilotSessionUpdateForTesting([
            "sessionUpdate": "tool_call",
            "toolCallId": "tool-hidden",
            "status": "running",
            "kind": "internal"
        ])

        await runtime.processCopilotSessionUpdateForTesting([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "tool-hidden",
            "status": "completed",
            "kind": "internal",
            "rawOutput": [
                "content": "Task completed: Hi! I'm your GitHub Copilot CLI assistant."
            ]
        ])

        XCTAssertEqual(
            runtime.pendingCopilotFallbackReplyForTesting(),
            "Hi! I'm your GitHub Copilot CLI assistant."
        )

        runtime.processCopilotPromptCompletionForTesting()

        let finalAssistant = recorder.timelineItems.last {
            $0.kind == .assistantFinal && $0.isStreaming == false
        }

        XCTAssertEqual(finalAssistant?.text, "Hi! I'm your GitHub Copilot CLI assistant.")
        XCTAssertFalse(recorder.timelineItems.contains(where: { $0.kind == .activity }))
        XCTAssertTrue(recorder.toolSnapshots.isEmpty)
    }

    @MainActor
    func testClaudeCodeStreamDeltaProducesVisibleAssistantText() {
        let runtime = CodexAssistantRuntime()
        let recorder = AssistantRuntimeEventRecorder()

        runtime.onTranscriptMutation = { mutation in
            if case let .appendDelta(_, _, _, delta, _, _, _) = mutation {
                recorder.systemMessages.append(delta)
            }
        }
        runtime.onTimelineMutation = { mutation in
            if case let .appendTextDelta(_, _, _, _, delta, _, _, _, _, _) = mutation {
                recorder.activityTitles.append(delta)
            }
        }

        runtime.configureStreamingTurnForTesting(
            sessionID: "claude-thread",
            turnID: "claude-turn",
            text: "",
            mode: .agentic
        )

        runtime.processClaudeCodeOutputLineForTesting(
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello\n"}},"session_id":"claude-thread"}"#
        )

        XCTAssertEqual(recorder.systemMessages.last, "Hello")
        XCTAssertEqual(recorder.activityTitles.last, "Hello")
    }

    @MainActor
    func testCopilotPromptCompletionPromotesDirectAssistantPayloadReply() async {
        let runtime = CodexAssistantRuntime()
        let recorder = AssistantRuntimeEventRecorder()

        runtime.onTimelineMutation = { mutation in
            if case let .upsert(item) = mutation {
                recorder.timelineItems.append(item)
            }
        }

        runtime.configureStreamingTurnForTesting(
            sessionID: "copilot-thread",
            turnID: "copilot-turn",
            text: "",
            mode: .agentic
        )

        runtime.processCopilotPromptCompletionForTesting(
            raw: [
                "message": [
                    "role": "assistant",
                    "content": [
                        [
                            "type": "text",
                            "text": "Final answer: GitHub Copilot replied successfully."
                        ]
                    ]
                ]
            ]
        )

        let finalAssistant = recorder.timelineItems.last {
            $0.kind == .assistantFinal && $0.isStreaming == false
        }

        XCTAssertEqual(finalAssistant?.text, "GitHub Copilot replied successfully.")
    }

    @MainActor
    func testCopilotInternalCompletionToolIgnoresUnifiedDiffOutput() async {
        let runtime = CodexAssistantRuntime()
        let recorder = AssistantRuntimeEventRecorder()

        runtime.onTimelineMutation = { mutation in
            if case let .upsert(item) = mutation {
                recorder.timelineItems.append(item)
            }
        }

        runtime.configureStreamingTurnForTesting(
            sessionID: "copilot-thread",
            turnID: "copilot-turn",
            text: "",
            mode: .agentic
        )

        await runtime.processCopilotSessionUpdateForTesting([
            "sessionUpdate": "tool_call",
            "toolCallId": "tool-hidden",
            "status": "running",
            "kind": "internal"
        ])

        await runtime.processCopilotSessionUpdateForTesting([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "tool-hidden",
            "status": "completed",
            "kind": "internal",
            "rawOutput": [
                "content": """
                diff --git a/CLAUDE.md b/CLAUDE.md
                --- a/CLAUDE.md
                +++ b/CLAUDE.md
                @@ -1,1 +1,1 @@
                -Old text
                +New text
                """
            ]
        ])

        XCTAssertNil(runtime.pendingCopilotFallbackReplyForTesting())

        runtime.processCopilotPromptCompletionForTesting()

        let finalAssistant = recorder.timelineItems.last {
            $0.kind == .assistantFinal && $0.isStreaming == false
        }

        XCTAssertNil(finalAssistant)
    }

    @MainActor
    func testProcessExitFlushesStreamingReplyAndInterruptsLiveActivity() async {
        let runtime = CodexAssistantRuntime()
        let recorder = AssistantRuntimeEventRecorder()
        let text = """
        - first
        ```swift
        print("hello")
        """

        runtime.onTranscript = { recorder.transcriptEntries.append($0) }
        runtime.onTranscriptMutation = { mutation in
            if case let .upsert(entry, _) = mutation {
                recorder.transcriptEntries.append(entry)
            }
        }
        runtime.onTimelineMutation = { mutation in
            if case let .upsert(item) = mutation {
                recorder.timelineItems.append(item)
            }
        }

        runtime.configureStreamingTurnForTesting(
            sessionID: "thread-live",
            turnID: "turn-live",
            text: "",
            mode: .agentic
        )
        runtime.processActivityEventForTesting([
            "id": "cmd-live",
            "type": "commandExecution",
            "status": "running",
            "command": "pwd"
        ])
        runtime.configureStreamingTurnForTesting(
            sessionID: "thread-live",
            turnID: "turn-live",
            text: text,
            mode: .agentic
        )

        await runtime.processProcessExitedForTesting(message: "Codex App Server stopped")

        let finalTranscript = recorder.transcriptEntries.last {
            $0.role == .assistant && $0.text == text
        }
        let finalAssistant = recorder.timelineItems.last {
            $0.kind == .assistantFinal && $0.text == text
        }
        let interruptedActivity = recorder.timelineItems.last {
            $0.kind == .activity && $0.activity?.id == "cmd-live"
        }

        XCTAssertEqual(finalTranscript?.isStreaming, false)
        XCTAssertEqual(finalAssistant?.isStreaming, false)
        XCTAssertEqual(interruptedActivity?.activity?.status, .interrupted)
        XCTAssertEqual(interruptedActivity?.turnID, "turn-live")
        XCTAssertNil(runtime.currentSessionID)
    }

    @MainActor
    func testBuildResumeContextUsesRecentMeaningfulTranscriptEntries() {
        let transcript: [AssistantTranscriptEntry] = [
            AssistantTranscriptEntry(role: .system, text: "Loaded Codex thread thread-1.", emphasis: true),
            AssistantTranscriptEntry(role: .user, text: "Can you check my Obsidian Vault Macs?"),
            AssistantTranscriptEntry(role: .assistant, text: "I found your Macs vault at ~/Documents/Vault/Macs and the Obsidian CLI is available."),
            AssistantTranscriptEntry(role: .user, text: "What all is in my obsidian vault you said?"),
            AssistantTranscriptEntry(role: .assistant, text: "Your Macs Obsidian vault currently shows these items: 2026-02-10.md and other notes.")
        ]

        let context = AssistantStore.buildResumeContext(
            transcriptEntries: transcript,
            sessionSummary: nil
        )

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Recovered Thread Context") == true)
        XCTAssertFalse(context?.contains("Loaded Codex thread") == true)
        XCTAssertTrue(context?.contains("User: Can you check my Obsidian Vault Macs?") == true)
        XCTAssertTrue(context?.contains("Assistant: I found your Macs vault") == true)
        XCTAssertTrue(context?.contains("User: What all is in my obsidian vault you said?") == true)
    }

    @MainActor
    func testBuildResumeContextFallsBackToSessionPreviewWhenTranscriptMissing() {
        let session = AssistantSessionSummary(
            id: "thread-1",
            title: "Obsidian vault check",
            source: .appServer,
            status: .completed,
            latestUserMessage: "What all is in my obsidian vault you said?",
            latestAssistantMessage: "Your Macs Obsidian vault currently shows three items."
        )

        let context = AssistantStore.buildResumeContext(
            transcriptEntries: [],
            sessionSummary: session
        )

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("User: What all is in my obsidian vault you said?") == true)
        XCTAssertTrue(context?.contains("Assistant: Your Macs Obsidian vault currently shows three items.") == true)
    }

    @MainActor
    func testGeneratedSessionTitleOnlyReplacesFallbackStyleTitles() {
        XCTAssertTrue(
            AssistantStore.shouldApplyGeneratedSessionTitle(
                existingTitle: "Check browser profile usage",
                fallbackTitle: "Check browser profile usage",
                cwd: "/Users/test/project"
            )
        )

        XCTAssertTrue(
            AssistantStore.shouldApplyGeneratedSessionTitle(
                existingTitle: "New Assistant Session",
                fallbackTitle: "Check browser profile usage",
                cwd: "/Users/test/project"
            )
        )

        XCTAssertTrue(
            AssistantStore.shouldApplyGeneratedSessionTitle(
                existingTitle: "/Users/test/project",
                fallbackTitle: "Check browser profile usage",
                cwd: "/Users/test/project"
            )
        )

        XCTAssertFalse(
            AssistantStore.shouldApplyGeneratedSessionTitle(
                existingTitle: "My Custom Thread Name",
                fallbackTitle: "Check browser profile usage",
                cwd: "/Users/test/project"
            )
        )
    }

    @MainActor
    func testPromptDerivedSessionTitleReplacesDefaultPlaceholder() {
        XCTAssertTrue(
            AssistantStore.shouldApplyPromptDerivedSessionTitle(
                existingTitle: "New Assistant Session",
                fallbackTitle: "Fix login redirect bug",
                cwd: "/Users/test/project"
            )
        )

        XCTAssertFalse(
            AssistantStore.shouldApplyPromptDerivedSessionTitle(
                existingTitle: "My Custom Thread Name",
                fallbackTitle: "Fix login redirect bug",
                cwd: "/Users/test/project"
            )
        )
    }

    @MainActor
    func testPendingFreshSessionResumeCheckIsCaseInsensitive() {
        XCTAssertTrue(
            AssistantStore.shouldSkipPendingFreshSessionResume(
                "THREAD-123",
                pendingSessionIDs: ["thread-123"]
            )
        )

        XCTAssertFalse(
            AssistantStore.shouldSkipPendingFreshSessionResume(
                "thread-456",
                pendingSessionIDs: ["thread-123"]
            )
        )
    }

    @MainActor
    func testPendingFreshSessionInsertionOrderKeepsPreferredUnsavedSessionVisible() {
        XCTAssertEqual(
            AssistantStore.pendingFreshSessionInsertionOrder(
                loadedSessionIDs: ["older-thread"],
                existingSessionIDs: ["new-thread", "older-thread"],
                preferredSessionIDs: ["new-thread"],
                pendingSessionIDs: ["new-thread"]
            ),
            ["new-thread"]
        )
    }

    @MainActor
    func testPendingFreshSessionInsertionOrderSkipsAlreadyPersistedSessions() {
        XCTAssertEqual(
            AssistantStore.pendingFreshSessionInsertionOrder(
                loadedSessionIDs: ["new-thread", "older-thread"],
                existingSessionIDs: ["new-thread"],
                preferredSessionIDs: ["new-thread"],
                pendingSessionIDs: ["new-thread"]
            ),
            []
        )
    }

    @MainActor
    func testFreshEmptySessionStatusFallsBackToIdleWhenNoTurnIsRunning() {
        XCTAssertEqual(
            AssistantStore.normalizedFreshSessionStatus(
                currentStatus: .active,
                hasConversationContent: false,
                hasActiveTurn: false
            ),
            .idle
        )
    }

    @MainActor
    func testFreshSessionStatusStaysActiveWhenConversationOrTurnExists() {
        XCTAssertEqual(
            AssistantStore.normalizedFreshSessionStatus(
                currentStatus: .active,
                hasConversationContent: true,
                hasActiveTurn: false
            ),
            .active
        )

        XCTAssertEqual(
            AssistantStore.normalizedFreshSessionStatus(
                currentStatus: .active,
                hasConversationContent: false,
                hasActiveTurn: true
            ),
            .active
        )
    }

    @MainActor
    func testScheduledJobVisibleHistoryStateNeverKeepsUnrelatedThreadVisible() {
        XCTAssertEqual(
            AssistantStore.scheduledJobVisibleHistoryState(
                isFreshSession: true,
                hasCachedTimeline: false,
                hasCachedTranscript: false
            ),
            .empty
        )

        XCTAssertEqual(
            AssistantStore.scheduledJobVisibleHistoryState(
                isFreshSession: false,
                hasCachedTimeline: false,
                hasCachedTranscript: false
            ),
            .loading
        )

        XCTAssertEqual(
            AssistantStore.scheduledJobVisibleHistoryState(
                isFreshSession: false,
                hasCachedTimeline: true,
                hasCachedTranscript: false
            ),
            .cached
        )

        XCTAssertEqual(
            AssistantStore.scheduledJobVisibleHistoryState(
                isFreshSession: false,
                hasCachedTimeline: false,
                hasCachedTranscript: true
            ),
            .loading
        )
    }

    @MainActor
    func testRepeatedCommandTrackerStopsWhenNormalizedCommandHitsLimit() {
        var tracker = AssistantRepeatedCommandTracker()

        XCTAssertNil(tracker.record(command: "pwd", maxAttempts: 3))
        XCTAssertNil(tracker.record(command: "  pwd  ", maxAttempts: 3))

        let hit = tracker.record(command: "\npwd\n", maxAttempts: 3)
        XCTAssertEqual(
            hit,
            AssistantRepeatedCommandLimitHit(command: "pwd", attemptCount: 3)
        )
    }

    @MainActor
    func testRepeatedCommandTrackerTreatsWhitespaceOnlyDifferencesAsSameCommand() {
        XCTAssertEqual(
            AssistantRepeatedCommandTracker.normalizedSignature(for: "ls   -la\t/tmp"),
            AssistantRepeatedCommandTracker.normalizedSignature(for: "  ls -la /tmp  ")
        )
    }

    @MainActor
    func testRepeatedCommandTrackerResetsWhenDifferentCommandBreaksTheLoop() {
        var tracker = AssistantRepeatedCommandTracker()

        XCTAssertNil(tracker.record(command: "pwd", maxAttempts: 3))
        XCTAssertNil(tracker.record(command: "ls", maxAttempts: 3))
        XCTAssertNil(tracker.record(command: "pwd", maxAttempts: 3))
        XCTAssertNil(tracker.record(command: "pwd", maxAttempts: 3))

        let hit = tracker.record(command: "pwd", maxAttempts: 3)
        XCTAssertEqual(
            hit,
            AssistantRepeatedCommandLimitHit(command: "pwd", attemptCount: 3)
        )
    }

    @MainActor
    func testTransientReconnectNotificationStaysOutOfErrorTranscript() async {
        let runtime = CodexAssistantRuntime()
        let recorder = AssistantRuntimeEventRecorder()

        runtime.onTranscript = { recorder.transcriptEntries.append($0) }
        runtime.onStatusMessage = { recorder.statusMessages.append($0) }
        runtime.onHUDUpdate = { recorder.hudStates.append($0) }

        await runtime.processErrorNotificationForTesting("Reconnecting... 2/5")

        XCTAssertTrue(recorder.transcriptEntries.isEmpty)
        XCTAssertEqual(recorder.statusMessages.last ?? nil, "Reconnecting... 2/5")
        XCTAssertEqual(recorder.hudStates.last?.phase, .streaming)
        XCTAssertEqual(recorder.hudStates.last?.title, "Reconnecting")
        XCTAssertEqual(recorder.hudStates.last?.detail, "Reconnecting... 2/5")
    }

    @MainActor
    func testFinalStreamDisconnectStillAppearsAsError() async {
        let runtime = CodexAssistantRuntime()
        let recorder = AssistantRuntimeEventRecorder()

        runtime.onTranscript = { recorder.transcriptEntries.append($0) }
        runtime.onStatusMessage = { recorder.statusMessages.append($0) }
        runtime.onHUDUpdate = { recorder.hudStates.append($0) }

        let message = "stream disconnected before completion: An error occurred while processing your request. Please include the request ID 47b48761-427a-4703-95a2-fb23d4fa2dd9 in your message."
        await runtime.processErrorNotificationForTesting(message)

        XCTAssertEqual(recorder.transcriptEntries.count, 1)
        XCTAssertEqual(recorder.transcriptEntries.first?.role, .error)
        XCTAssertEqual(recorder.transcriptEntries.first?.text, message)
        XCTAssertTrue(recorder.statusMessages.isEmpty)
        XCTAssertEqual(recorder.hudStates.last?.phase, .failed)
        XCTAssertEqual(recorder.hudStates.last?.detail, message)
    }
}

private func cliAttachmentPath(from promptContext: String) -> String? {
    promptContext
        .split(separator: "\n")
        .compactMap { line -> String? in
            guard let range = line.range(of: ": ", options: .backwards) else { return nil }
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .first
}
