import XCTest
@testable import OpenAssist

private final class AssistantRuntimeEventRecorder: @unchecked Sendable {
    var toolSnapshots: [[AssistantToolCallState]] = []
    var activityTitles: [String] = []
    var systemMessages: [String] = []
    var transcriptEntries: [AssistantTranscriptEntry] = []
    var statusMessages: [String?] = []
    var hudStates: [AssistantHUDState] = []
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
        XCTAssertFalse(
            runtime.isToolActivityAllowedForTesting(
                mode: .plan,
                rawType: "fileChange"
            )
        )
        XCTAssertFalse(
            runtime.isToolActivityAllowedForTesting(
                mode: .plan,
                rawType: "browserAutomation"
            )
        )
        XCTAssertFalse(
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
    func testComputerUseDynamicToolCallUsesFriendlyTitleAndSummary() {
        let runtime = CodexAssistantRuntime()

        let state = runtime.toolCallStateForTesting(from: [
            "id": "tool-1",
            "type": "dynamicToolCall",
            "tool": "computer_use",
            "status": "running",
            "arguments": ["task": "Open Mail and read the latest message."]
        ])

        XCTAssertEqual(state?.title, "Computer Use")
        XCTAssertEqual(
            runtime.activitySummaryForTesting(kind: .dynamicToolCall, title: state?.title ?? ""),
            "Used the computer."
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
    func testComputerUseApprovalStaysScopedToTheSameSession() {
        let runtime = CodexAssistantRuntime()

        runtime.rememberComputerUseApprovalForTesting("thread-1")

        XCTAssertTrue(runtime.isComputerUseApprovedForTesting("thread-1"))
        XCTAssertFalse(runtime.isComputerUseApprovedForTesting("thread-2"))
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

        let computerUse = runtime.blockedToolUseMessage(
            for: .conversational,
            activityTitle: "Computer Use"
        )
        XCTAssertTrue(computerUse.contains("live screen or browser"))
        XCTAssertTrue(computerUse.contains("attached image"))
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
            "The selected model Text Only cannot read image attachments. Choose a model that supports image input and try again. Chat mode can still analyze attached images when the model supports them, but live screen or browser inspection needs Agentic mode."
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
            [.conversational, .plan, .agentic]
        )

        XCTAssertEqual(AssistantInteractionMode.conversational.codexModeKind, "default")
        XCTAssertEqual(AssistantInteractionMode.plan.codexModeKind, "plan")
        XCTAssertEqual(AssistantInteractionMode.agentic.codexModeKind, "default")
    }

    @MainActor
    func testChatModeDoesNotExposeComputerUseDynamicTool() {
        let runtime = CodexAssistantRuntime()

        XCTAssertEqual(runtime.dynamicToolNamesForTesting(mode: .conversational), [])
        XCTAssertEqual(runtime.dynamicToolNamesForTesting(mode: .plan), [])
        XCTAssertEqual(runtime.dynamicToolNamesForTesting(mode: .agentic), ["computer_use"])
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
    func testDynamicToolStateReadsToolNameAliases() {
        let runtime = CodexAssistantRuntime()

        let state = runtime.toolCallStateForTesting(from: [
            "id": "tool-2",
            "type": "dynamicToolCall",
            "toolName": "computer_use",
            "status": "running",
            "arguments": ["task": "Open Safari."]
        ])

        XCTAssertEqual(state?.title, "Computer Use")
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
        let reminder = CodexAssistantRuntime.browserTurnReminder(from: [
            "browser": "Brave Browser",
            "channel": "brave",
            "profileDir": "Profile 1",
            "userDataDir": "/Users/test/Library/Application Support/BraveSoftware/Brave-Browser",
            "profileName": "Personal"
        ])

        XCTAssertNotNil(reminder)
        XCTAssertTrue(reminder?.contains("Profile: Personal") == true)
        XCTAssertTrue(reminder?.contains("Brave Browser") == true)
        XCTAssertTrue(reminder?.contains("launchPersistentContext") == true)
        XCTAssertTrue(reminder?.contains("Profile 1") == true)
    }

    @MainActor
    func testBuildInstructionsIncludesBrowserTurnReminderWhenProfileIsConfigured() {
        let runtime = CodexAssistantRuntime()
        runtime.browserProfileContext = [
            "browser": "Brave Browser",
            "channel": "brave",
            "profileDir": "Profile 1",
            "userDataDir": "/Users/test/Library/Application Support/BraveSoftware/Brave-Browser",
            "profileName": "Personal"
        ]

        let instructions = runtime.buildInstructionsForTesting()

        XCTAssertTrue(instructions.contains("# Browser Task Override"))
        XCTAssertTrue(instructions.contains("Do NOT use MCP browser tools"))
        XCTAssertTrue(instructions.contains("Profile: Personal"))
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
