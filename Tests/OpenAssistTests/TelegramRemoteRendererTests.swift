import XCTest
@testable import OpenAssist

final class TelegramRemoteRendererTests: XCTestCase {
    func testChunkTextSplitsLongMessageWithoutDroppingContent() {
        let text = Array(repeating: "alpha beta gamma delta", count: 20).joined(separator: "\n")

        let chunks = TelegramRemoteRenderer.chunkText(text, limit: 60)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 60 })
        XCTAssertEqual(chunks.joined(separator: " ").replacingOccurrences(of: "\n", with: " "), text.replacingOccurrences(of: "\n", with: " "))
    }

    func testTranscriptPreviewShowsSessionTitleAndRecentMessages() {
        let entries = [
            AssistantTranscriptEntry(role: .user, text: "First question"),
            AssistantTranscriptEntry(role: .assistant, text: "First answer"),
            AssistantTranscriptEntry(role: .user, text: "Second question")
        ]

        let preview = TelegramRemoteRenderer.transcriptPreviewText(
            sessionTitle: "Build Fix",
            entries: entries
        )

        XCTAssertTrue(preview.contains("Session: Build Fix"))
        XCTAssertTrue(preview.contains("You: First question"))
        XCTAssertTrue(preview.contains("Assistant: First answer"))
        XCTAssertTrue(preview.contains("You: Second question"))
    }

    func testStreamMessageUsesAssistantReplyInsteadOfToolNoise() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-1",
                title: "Bug Hunt",
                source: .appServer,
                status: .active
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "Please inspect the logs."),
                AssistantTranscriptEntry(role: .assistant, text: "I am checking the logs now.", isStreaming: true),
                AssistantTranscriptEntry(role: .tool, text: "Ran rg error logs")
            ],
            pendingPermissionRequest: nil,
            hudState: AssistantHUDState(
                phase: .streaming,
                title: "Streaming",
                detail: "Reading new output"
            ),
            hasActiveTurn: true,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil
        )

        let streamText = TelegramRemoteRenderer.streamMessageText(snapshot: snapshot)

        XCTAssertNotNil(streamText)
        XCTAssertEqual(streamText, "I am checking the logs now.")
    }

    func testStreamMessageKeepsActiveReplyWhenNextPromptIsQueued() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-queued",
                title: "Queued Follow Up",
                source: .appServer,
                status: .active
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "Check the logs."),
                AssistantTranscriptEntry(role: .assistant, text: "I am still checking the logs now.", isStreaming: true),
                AssistantTranscriptEntry(role: .user, text: "Also check the cache after that.")
            ],
            pendingPermissionRequest: nil,
            hudState: AssistantHUDState(
                phase: .streaming,
                title: "Streaming",
                detail: "Reading new output"
            ),
            hasActiveTurn: true,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil,
            queuedPromptCount: 1
        )

        let streamText = TelegramRemoteRenderer.streamMessageText(snapshot: snapshot)

        XCTAssertEqual(streamText, "I am still checking the logs now.")
    }

    func testStreamMessageClampsQueuedPromptAnchorWhenQueuedCountExceedsVisibleTurns() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-overflow-queued",
                title: "Queued Overflow",
                source: .appServer,
                status: .active
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "Check the logs."),
                AssistantTranscriptEntry(role: .assistant, text: "I am still checking the logs now.", isStreaming: true),
                AssistantTranscriptEntry(role: .user, text: "Also check the cache after that.")
            ],
            pendingPermissionRequest: nil,
            hudState: AssistantHUDState(
                phase: .streaming,
                title: "Streaming",
                detail: "Reading new output"
            ),
            hasActiveTurn: true,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil,
            queuedPromptCount: 3
        )

        XCTAssertEqual(
            TelegramRemoteRenderer.streamMessageText(snapshot: snapshot),
            "I am still checking the logs now."
        )
    }

    func testStreamMessagePrefersAssistantReplyOverTrailingStatus() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-2",
                title: "Screenshot Review",
                source: .appServer,
                status: .completed
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "What is on the screen?"),
                AssistantTranscriptEntry(role: .assistant, text: "I can see Telegram and Codex open on the screen."),
                AssistantTranscriptEntry(role: .status, text: "This turn was interrupted.")
            ],
            pendingPermissionRequest: nil,
            hudState: .idle,
            hasActiveTurn: false,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil
        )

        let streamText = TelegramRemoteRenderer.completedAttentionText(snapshot: snapshot)

        XCTAssertEqual(streamText, "I can see Telegram and Codex open on the screen.")
    }

    func testCatchUpSkipsInternalStatusNoise() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-3",
                title: "Quiet Chat",
                source: .appServer,
                status: .completed
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "Show me the latest screenshot"),
                AssistantTranscriptEntry(role: .status, text: "This turn was interrupted."),
                AssistantTranscriptEntry(role: .assistant, text: "Here is the latest screenshot.")
            ],
            pendingPermissionRequest: nil,
            hudState: .idle,
            hasActiveTurn: false,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil
        )

        let catchUp = TelegramRemoteRenderer.catchUpText(snapshot: snapshot)

        XCTAssertNotNil(catchUp)
        XCTAssertFalse(catchUp?.contains("This turn was interrupted.") == true)
        XCTAssertTrue(catchUp?.contains("Here is the latest screenshot.") == true)
    }

    func testSessionHeaderTextMarksTemporaryChat() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-temp",
                title: "",
                source: .appServer,
                status: .active,
                isTemporary: true,
                projectName: "RAPID"
            ),
            transcriptEntries: [],
            pendingPermissionRequest: nil,
            hudState: .idle,
            hasActiveTurn: false,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil
        )

        let header = TelegramRemoteRenderer.sessionHeaderText(snapshot: snapshot)

        XCTAssertTrue(header.contains("Session: Temporary Chat"))
        XCTAssertTrue(header.contains("Type: Temporary chat"))
        XCTAssertTrue(header.contains("Project: RAPID"))
    }

    func testSessionMenuLabelPrefixesTemporarySessions() {
        let session = AssistantSessionSummary(
            id: "session-temp",
            title: "Scratchpad",
            source: .appServer,
            status: .active,
            isTemporary: true
        )

        let label = TelegramRemoteRenderer.sessionMenuLabel(session, isSelected: true)

        XCTAssertEqual(label, "• [Temp] Scratchpad")
    }

    func testProviderUsageTextUsesSelectedModelBucketAndShowsWindows() throws {
        let status = AssistantRemoteStatusSnapshot(
            runtimeHealth: .idle,
            assistantBackend: .copilot,
            selectedSessionID: "session-5",
            selectedSessionTitle: "Build Fix",
            selectedSessionIsTemporary: false,
            selectedModelID: "gpt-5.3-codex-spark",
            selectedModelSummary: "gpt-5.3-codex-spark",
            interactionMode: .agentic,
            reasoningEffort: .high,
            supportedReasoningEfforts: [.medium, .high],
            canAdjustReasoningEffort: true,
            fastModeEnabled: false,
            tokenUsage: .empty,
            lastStatusMessage: nil
        )
        let fiveHour = try XCTUnwrap(
            RateLimitWindow(from: [
                "usedPercent": 77,
                "windowDurationMins": 300
            ])
        )
        let weekly = try XCTUnwrap(
            RateLimitWindow(from: [
                "usedPercent": 8,
                "windowDurationMins": 10_080
            ])
        )
        let limits = AccountRateLimits(
            planType: nil,
            primary: try XCTUnwrap(
                RateLimitWindow(from: [
                    "usedPercent": 12,
                    "windowDurationMins": 300
                ])
            ),
            secondary: try XCTUnwrap(
                RateLimitWindow(from: [
                    "usedPercent": 24,
                    "windowDurationMins": 10_080
                ])
            ),
            hasCredits: true,
            unlimited: false,
            limitID: "codex",
            limitName: nil,
            additionalBuckets: [
                AccountRateLimitBucket(
                    limitID: "codex_other",
                    limitName: "spark",
                    primary: fiveHour,
                    secondary: weekly
                )
            ]
        )

        let summary = TelegramRemoteRenderer.providerUsageText(status: status, rateLimits: limits)

        XCTAssertTrue(summary.contains("Provider Usage"))
        XCTAssertTrue(summary.contains("Session: Build Fix"))
        XCTAssertTrue(summary.contains("Backend: GitHub Copilot"))
        XCTAssertTrue(summary.contains("Model: gpt-5.3-codex-spark"))
        XCTAssertTrue(summary.contains("Provider: spark"))
        XCTAssertTrue(summary.contains("5-hour: 77% used (23% left)"))
        XCTAssertTrue(summary.contains("Weekly: 8% used (92% left)"))
    }

    func testProviderUsageTextHandlesMissingProviderWindows() {
        let status = AssistantRemoteStatusSnapshot(
            runtimeHealth: .idle,
            assistantBackend: .codex,
            selectedSessionID: "session-6",
            selectedSessionTitle: "Temporary Scratch",
            selectedSessionIsTemporary: true,
            selectedModelID: "gpt-5.4",
            selectedModelSummary: "gpt-5.4",
            interactionMode: .agentic,
            reasoningEffort: .high,
            supportedReasoningEfforts: [.low, .medium, .high],
            canAdjustReasoningEffort: true,
            fastModeEnabled: false,
            tokenUsage: .empty,
            lastStatusMessage: nil
        )

        let summary = TelegramRemoteRenderer.providerUsageText(status: status, rateLimits: .empty)

        XCTAssertTrue(summary.contains("Provider Usage"))
        XCTAssertTrue(summary.contains("Type: Temporary chat"))
        XCTAssertTrue(summary.contains("Backend: Codex"))
        XCTAssertTrue(summary.contains("Provider: No provider usage reported yet for the selected model."))
    }

    func testStreamMessageDoesNotEmitThinkingBubbleWithoutAssistantText() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-4",
                title: "Typing Only",
                source: .appServer,
                status: .active
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "Check my screen")
            ],
            pendingPermissionRequest: nil,
            hudState: AssistantHUDState(
                phase: .streaming,
                title: "Streaming",
                detail: "Thinking..."
            ),
            hasActiveTurn: true,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil
        )

        let streamText = TelegramRemoteRenderer.streamMessageText(snapshot: snapshot)

        XCTAssertNil(streamText)
    }

    func testCompactStatusTextShowsQueuedWorkSubtly() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-status",
                title: "Queued Work",
                source: .appServer,
                status: .active
            ),
            transcriptEntries: [],
            pendingPermissionRequest: nil,
            hudState: AssistantHUDState(
                phase: .acting,
                title: "Working",
                detail: nil
            ),
            hasActiveTurn: true,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil,
            queuedPromptCount: 2
        )

        XCTAssertEqual(
            TelegramRemoteRenderer.compactStatusText(snapshot: snapshot),
            "Working (2 queued)"
        )
    }

    func testCompactStatusTextShowsSendingBeforeAssistantStarts() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-pending",
                title: "Pending Send",
                source: .appServer,
                status: .active
            ),
            transcriptEntries: [],
            pendingPermissionRequest: nil,
            hudState: AssistantHUDState(
                phase: .thinking,
                title: "Thinking",
                detail: "Sending your message"
            ),
            hasActiveTurn: false,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil,
            pendingOutgoingMessage: AssistantPendingOutgoingMessage(
                text: "Please check this.",
                imageAttachments: [],
                createdAt: Date()
            ),
            awaitingAssistantStart: true
        )

        XCTAssertEqual(
            TelegramRemoteRenderer.compactStatusText(snapshot: snapshot),
            "Sending your message"
        )
    }

    func testCompletedAttentionTextPrefersLatestCompletedAssistantReply() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-complete",
                title: "Completed Turn",
                source: .appServer,
                status: .completed
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "What happened?"),
                AssistantTranscriptEntry(role: .assistant, text: "Short"),
                AssistantTranscriptEntry(role: .assistant, text: "This is the final answer that should be sent to Telegram.")
            ],
            pendingPermissionRequest: nil,
            latestRemoteAttentionEvent: AssistantRemoteAttentionEvent(
                id: "completed:turn-1",
                kind: .completed,
                createdAt: Date(),
                turnID: "turn-1",
                permissionRequestID: nil,
                failureText: nil
            ),
            hudState: .idle,
            hasActiveTurn: false,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil
        )

        XCTAssertEqual(
            TelegramRemoteRenderer.completedAttentionText(snapshot: snapshot),
            "This is the final answer that should be sent to Telegram."
        )
    }

    func testFailureAttentionTextUsesErrorTranscriptBeforeFallback() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-failed",
                title: "Failed Turn",
                source: .appServer,
                status: .active
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "Try it."),
                AssistantTranscriptEntry(role: .error, text: "The command failed because access was denied.")
            ],
            pendingPermissionRequest: nil,
            latestRemoteAttentionEvent: AssistantRemoteAttentionEvent(
                id: "failed:turn-2",
                kind: .failed,
                createdAt: Date(),
                turnID: "turn-2",
                permissionRequestID: nil,
                failureText: "Fallback failure text"
            ),
            hudState: .idle,
            hasActiveTurn: false,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil
        )

        XCTAssertEqual(
            TelegramRemoteRenderer.failureAttentionText(
                snapshot: snapshot,
                fallback: "Fallback failure text"
            ),
            "The command failed because access was denied."
        )
    }

    func testFreshAttentionDeliveryReturnsCompletionForNewEvent() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-complete",
                title: "Completed Turn",
                source: .appServer,
                status: .completed
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "Summarize it."),
                AssistantTranscriptEntry(role: .assistant, text: "Here is the final summary.")
            ],
            pendingPermissionRequest: nil,
            latestRemoteAttentionEvent: AssistantRemoteAttentionEvent(
                id: "completed:turn-3",
                kind: .completed,
                createdAt: Date(),
                turnID: "turn-3",
                permissionRequestID: nil,
                failureText: nil
            ),
            hudState: .idle,
            hasActiveTurn: false,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil
        )

        XCTAssertEqual(
            TelegramRemoteCoordinator.freshAttentionDelivery(
                snapshot: snapshot,
                baselineAttentionEventID: "completed:older-turn",
                lastDeliveredEventID: nil
            ),
            .init(
                eventID: "completed:turn-3",
                kind: .completion(text: "Here is the final summary.")
            )
        )
    }

    func testCompletedAttentionTextUsesAttentionEventScopeInsteadOfNewerTurn() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let event = AssistantRemoteAttentionEvent(
            id: "completed:turn-1",
            kind: .completed,
            createdAt: startedAt.addingTimeInterval(3),
            turnID: "turn-1",
            permissionRequestID: nil,
            failureText: nil
        )
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-turn-scope",
                title: "Turn Scope",
                source: .appServer,
                status: .active
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "Turn one", createdAt: startedAt),
                AssistantTranscriptEntry(role: .assistant, text: "Final answer for turn one.", createdAt: startedAt.addingTimeInterval(1.5)),
                AssistantTranscriptEntry(role: .user, text: "Turn two", createdAt: startedAt.addingTimeInterval(2)),
                AssistantTranscriptEntry(role: .assistant, text: "Streaming turn two", createdAt: startedAt.addingTimeInterval(4), isStreaming: true)
            ],
            pendingPermissionRequest: nil,
            latestRemoteAttentionEvent: event,
            hudState: AssistantHUDState(
                phase: .streaming,
                title: "Streaming",
                detail: "Turn two is still running"
            ),
            hasActiveTurn: true,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil,
            activeTurnID: "turn-2"
        )

        XCTAssertEqual(
            TelegramRemoteRenderer.completedAttentionText(snapshot: snapshot, event: event),
            "Final answer for turn one."
        )
    }

    func testFreshAttentionDeliverySkipsBaselineEvent() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-complete",
                title: "Completed Turn",
                source: .appServer,
                status: .completed
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "Summarize it."),
                AssistantTranscriptEntry(role: .assistant, text: "Here is the final summary.")
            ],
            pendingPermissionRequest: nil,
            latestRemoteAttentionEvent: AssistantRemoteAttentionEvent(
                id: "completed:turn-3",
                kind: .completed,
                createdAt: Date(),
                turnID: "turn-3",
                permissionRequestID: nil,
                failureText: nil
            ),
            hudState: .idle,
            hasActiveTurn: false,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil
        )

        XCTAssertNil(
            TelegramRemoteCoordinator.freshAttentionDelivery(
                snapshot: snapshot,
                baselineAttentionEventID: "completed:turn-3",
                lastDeliveredEventID: nil
            )
        )
    }

    func testHasUndeliveredTerminalAttentionSkipsCompletionWithoutRenderableText() {
        let event = AssistantRemoteAttentionEvent(
            id: "completed:turn-9",
            kind: .completed,
            createdAt: Date(),
            turnID: "turn-9",
            permissionRequestID: nil,
            failureText: nil
        )
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-empty-complete",
                title: "Empty Completion",
                source: .appServer,
                status: .completed
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "Hello")
            ],
            pendingPermissionRequest: nil,
            latestRemoteAttentionEvent: event,
            hudState: .idle,
            hasActiveTurn: false,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil
        )

        XCTAssertFalse(
            TelegramRemoteCoordinator.hasUndeliveredTerminalAttention(
                snapshot: snapshot,
                baselineAttentionEventID: nil,
                lastDeliveredEventID: nil
            )
        )
    }

    func testFreshAttentionDeliveryReturnsPermissionRequestForNewApproval() {
        let request = AssistantPermissionRequest(
            id: 44,
            sessionID: "session-permission",
            toolTitle: "Use Browser",
            toolKind: "computer",
            rationale: "Need to inspect the page",
            options: [
                AssistantPermissionOption(id: "accept", title: "Approve", kind: nil, isDefault: true)
            ],
            rawPayloadSummary: nil
        )
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-permission",
                title: "Approval Needed",
                source: .appServer,
                status: .active
            ),
            transcriptEntries: [],
            pendingPermissionRequest: request,
            latestRemoteAttentionEvent: AssistantRemoteAttentionEvent(
                id: "permission:44",
                kind: .permissionRequired,
                createdAt: Date(),
                turnID: nil,
                permissionRequestID: 44,
                failureText: nil
            ),
            hudState: .idle,
            hasActiveTurn: true,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil
        )

        XCTAssertEqual(
            TelegramRemoteCoordinator.freshAttentionDelivery(
                snapshot: snapshot,
                baselineAttentionEventID: nil,
                lastDeliveredEventID: nil
            ),
            .init(
                eventID: "permission:44",
                kind: .permission(requestID: 44)
            )
        )
    }

    func testRenderMessageConvertsMarkdownToTelegramHTML() {
        let rendered = TelegramRemoteRenderer.renderSingleMessage("""
        **Story Summary**

        Visit [OpenAI](https://openai.com) and check `main.swift`.
        """)

        XCTAssertNotNil(rendered)
        XCTAssertTrue(rendered?.html.contains("<b>Story Summary</b>") == true)
        XCTAssertTrue(rendered?.html.contains("<a href=\"https://openai.com\">OpenAI</a>") == true)
        XCTAssertTrue(rendered?.html.contains("<code>main.swift</code>") == true)
        XCTAssertEqual(
            rendered?.plainText,
            """
            Story Summary

            Visit OpenAI and check main.swift.
            """
        )
    }

    func testRenderMessageUsesPreformattedHTMLForCodeBlocks() {
        let rendered = TelegramRemoteRenderer.renderSingleMessage("""
        ```swift
        let value = 42
        print(value)
        ```
        """)

        XCTAssertNotNil(rendered)
        XCTAssertEqual(
            rendered?.html,
            "<pre><code class=\"language-swift\">let value = 42\nprint(value)</code></pre>"
        )
        XCTAssertEqual(rendered?.plainText, "let value = 42\nprint(value)")
    }

    func testRenderMessageFormatsHeadingsQuotesAndLists() {
        let rendered = TelegramRemoteRenderer.renderSingleMessage("""
        ## Summary

        > Check the logs

        - First item
        - Second **item**
        """)

        XCTAssertNotNil(rendered)
        XCTAssertTrue(rendered?.html.contains("<b>Summary</b>") == true)
        XCTAssertTrue(rendered?.html.contains("<blockquote>Check the logs</blockquote>") == true)
        XCTAssertTrue(rendered?.html.contains("• First item") == true)
        XCTAssertTrue(rendered?.html.contains("• Second <b>item</b>") == true)
    }

    func testRenderMessageKeepsLocalFileLinksReadableWithoutMakingHTMLLink() {
        let rendered = TelegramRemoteRenderer.renderSingleMessage(
            "[Open file](/Users/manikvashith/tmp/example.swift)"
        )

        XCTAssertNotNil(rendered)
        XCTAssertEqual(
            rendered?.html,
            "Open file (/Users/manikvashith/tmp/example.swift)"
        )
        XCTAssertEqual(
            rendered?.plainText,
            "Open file (/Users/manikvashith/tmp/example.swift)"
        )
    }

    func testRenderMessageEscapesRawHTMLInsteadOfPassingItThrough() {
        let rendered = TelegramRemoteRenderer.renderSingleMessage("<script>alert('x')</script>")

        XCTAssertNotNil(rendered)
        XCTAssertEqual(rendered?.html, "<pre>&lt;script&gt;alert('x')&lt;/script&gt;</pre>")
        XCTAssertEqual(rendered?.plainText, "<script>alert('x')</script>")
    }

    func testRenderMessageUsesPreformattedFallbackForMarkdownTables() {
        let rendered = TelegramRemoteRenderer.renderSingleMessage("""
        | Name | Status |
        | --- | --- |
        | Build | Ready |
        """)

        XCTAssertNotNil(rendered)
        XCTAssertEqual(
            rendered?.html,
            "<pre>| Name | Status |\n| --- | --- |\n| Build | Ready |</pre>"
        )
        XCTAssertEqual(
            rendered?.plainText,
            """
            | Name | Status |
            | --- | --- |
            | Build | Ready |
            """
        )
    }

    func testRenderMessageSplitsLongCodeBlocksIntoBalancedHTMLChunks() {
        let renderedChunks = TelegramRemoteRenderer.renderMessage(
            """
            ```swift
            \(Array(repeating: "let value = 42", count: 20).joined(separator: "\n"))
            ```
            """,
            limit: 120
        )

        XCTAssertGreaterThan(renderedChunks.count, 1)
        XCTAssertTrue(renderedChunks.allSatisfy { $0.html.hasPrefix("<pre") && $0.html.hasSuffix("</pre>") })
        XCTAssertTrue(renderedChunks.allSatisfy { max($0.html.count, $0.plainText.count) <= 120 })
    }

    func testTelegramPlainTextStripsMarkdownMarkers() {
        let cleaned = TelegramRemoteRenderer.telegramPlainText("""
        **Story Summary**

        Azure DevOps story `65358`

        [Open file](/tmp/example.swift)
        """)

        XCTAssertEqual(
            cleaned,
            """
            Story Summary

            Azure DevOps story 65358

            Open file (/tmp/example.swift)
            """
        )
    }
}
