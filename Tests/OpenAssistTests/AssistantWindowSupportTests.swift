import XCTest
@testable import OpenAssist

final class AssistantWindowSupportTests: XCTestCase {
    func testActiveWorkStateRequiresStructuredItemsToBeVisible() {
        let thinkingOnly = AssistantChatWebActiveWorkState(
            title: "Thinking",
            detail: "Working on your message",
            activeCalls: [],
            recentCalls: [],
            subagents: []
        )
        XCTAssertFalse(thinkingOnly.hasVisibleContent)

        let withToolCall = AssistantChatWebActiveWorkState(
            title: "Thinking",
            detail: "Working on your message",
            activeCalls: [
                AssistantChatWebActiveWorkItem(
                    id: "tool-1",
                    title: "Browser",
                    kind: "browserAutomation",
                    status: "running",
                    statusLabel: "Running",
                    detail: "Opening page"
                )
            ],
            recentCalls: [],
            subagents: []
        )
        XCTAssertTrue(withToolCall.hasVisibleContent)
    }

    func testPendingPlaceholderOnlyShowsForOwningThread() {
        XCTAssertTrue(
            assistantShouldShowPendingAssistantPlaceholder(
                selectedSessionID: "thread-a",
                activeRuntimeSessionID: "thread-a",
                hasPendingPermissionRequest: false,
                hasVisibleStreamingAssistantMessage: false,
                hudPhase: .thinking
            )
        )

        XCTAssertFalse(
            assistantShouldShowPendingAssistantPlaceholder(
                selectedSessionID: "thread-b",
                activeRuntimeSessionID: "thread-a",
                hasPendingPermissionRequest: false,
                hasVisibleStreamingAssistantMessage: false,
                hudPhase: .thinking
            )
        )
    }

    func testSelectedSessionToolActivityIsHiddenWhenAnotherThreadOwnsRuntime() {
        let activeCalls = [
            AssistantToolCallState(
                id: "tool-active",
                title: "Command",
                kind: "commandExecution",
                status: "running",
                detail: "swift test",
                hudDetail: nil
            )
        ]
        let recentCalls = [
            AssistantToolCallState(
                id: "tool-recent",
                title: "Web Search",
                kind: "webSearch",
                status: "completed",
                detail: "thread routing bug",
                hudDetail: nil
            )
        ]

        let hiddenActivity = assistantSelectedSessionToolActivity(
            selectedSessionID: "thread-b",
            activeRuntimeSessionID: "thread-a",
            hasActiveTurn: true,
            toolCalls: activeCalls,
            recentToolCalls: recentCalls
        )
        XCTAssertEqual(hiddenActivity, .empty)

        let visibleActivity = assistantSelectedSessionToolActivity(
            selectedSessionID: "THREAD-A",
            activeRuntimeSessionID: "thread-a",
            hasActiveTurn: true,
            toolCalls: activeCalls,
            recentToolCalls: recentCalls
        )
        XCTAssertEqual(visibleActivity.activeCalls, activeCalls)
        XCTAssertEqual(visibleActivity.recentCalls, recentCalls)
    }

    func testSidebarActivityFollowsRuntimeOwnerInsteadOfSelectedThread() {
        let owningThreadState = assistantSidebarActivityState(
            forSessionID: "thread-a",
            selectedSessionID: "thread-b",
            activeRuntimeSessionID: "thread-a",
            sessionStatus: .idle,
            hasPendingPermissionRequest: false,
            hudPhase: .streaming,
            isTransitioningSession: false,
            isLiveVoiceSessionActive: false,
            hasActiveTurn: true
        )
        XCTAssertEqual(owningThreadState, .running)

        let selectedOtherThreadState = assistantSidebarActivityState(
            forSessionID: "thread-b",
            selectedSessionID: "thread-b",
            activeRuntimeSessionID: "thread-a",
            sessionStatus: .idle,
            hasPendingPermissionRequest: false,
            hudPhase: .streaming,
            isTransitioningSession: false,
            isLiveVoiceSessionActive: false,
            hasActiveTurn: true
        )
        XCTAssertEqual(selectedOtherThreadState, .idle)
    }

    func testSelectedSessionActiveWorkSnapshotAppearsForParentThreadWithSubagents() {
        let planEntries = [
            AssistantPlanEntry(content: "Inspect runtime flow", status: "completed"),
            AssistantPlanEntry(content: "Implement UI", status: "in_progress")
        ]
        let subagents = [
            SubagentState(
                id: "agent-1",
                parentThreadID: "thread-a",
                threadID: "child-1",
                nickname: "Harvey",
                role: "worker",
                status: .running,
                prompt: "Implement the card",
                startedAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 20),
                endedAt: nil
            )
        ]
        let toolCalls = [
            AssistantToolCallState(
                id: "tool-1",
                title: "File Changes",
                kind: "fileChange",
                status: "completed",
                detail: "3 file changes",
                hudDetail: nil
            )
        ]

        let visibleSnapshot = assistantSelectedSessionActiveWorkSnapshot(
            selectedSessionID: "thread-a",
            activeRuntimeSessionID: "thread-a",
            planEntries: planEntries,
            subagents: subagents,
            toolCalls: toolCalls,
            recentToolCalls: []
        )
        XCTAssertEqual(visibleSnapshot?.sessionID, "thread-a")
        XCTAssertEqual(visibleSnapshot?.completedTaskCount, 1)
        XCTAssertEqual(visibleSnapshot?.totalTaskCount, 2)
        XCTAssertEqual(visibleSnapshot?.fileChangeCount, 3)
        XCTAssertEqual(visibleSnapshot?.subagents.count, 1)

        let hiddenSnapshot = assistantSelectedSessionActiveWorkSnapshot(
            selectedSessionID: "thread-b",
            activeRuntimeSessionID: "thread-a",
            planEntries: planEntries,
            subagents: subagents,
            toolCalls: toolCalls,
            recentToolCalls: []
        )
        XCTAssertNil(hiddenSnapshot)
    }

    func testSelectedSessionActiveWorkSnapshotIgnoresFinishedChildAgents() {
        let completedSubagent = SubagentState(
            id: "agent-1",
            parentThreadID: "thread-a",
            threadID: "child-1",
            nickname: "Harvey",
            role: "worker",
            status: .completed,
            prompt: "Implement the card",
            startedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            endedAt: Date(timeIntervalSince1970: 30)
        )

        let snapshot = assistantSelectedSessionActiveWorkSnapshot(
            selectedSessionID: "thread-a",
            activeRuntimeSessionID: "thread-a",
            planEntries: [],
            subagents: [completedSubagent],
            toolCalls: [],
            recentToolCalls: []
        )

        XCTAssertNil(snapshot)
    }

    func testHistoricalTurnSummariesOnlyCollapseWhenTurnIsFullySettled() {
        XCTAssertFalse(
            assistantCanCollapseHistoricalTurnSummaries(
                hasActiveTurn: true,
                activeWorkSnapshot: nil
            )
        )

        let activeWorkSnapshot = AssistantSessionActiveWorkSnapshot(
            sessionID: "thread-a",
            planEntries: [],
            subagents: [],
            fileChangeCount: 0
        )
        XCTAssertFalse(
            assistantCanCollapseHistoricalTurnSummaries(
                hasActiveTurn: false,
                activeWorkSnapshot: activeWorkSnapshot
            )
        )

        XCTAssertTrue(
            assistantCanCollapseHistoricalTurnSummaries(
                hasActiveTurn: false,
                activeWorkSnapshot: nil
            )
        )
    }

    func testThreadNoteAIDraftStateSerializesChartPreviewFields() {
        let state = AssistantChatWebThreadNoteState(
            threadID: "thread-1",
            ownerKind: "project",
            ownerID: "project-1",
            ownerTitle: "Alpha",
            presentation: "projectFullScreen",
            availableSources: [
                AssistantChatWebThreadNoteSource(
                    ownerKind: "thread",
                    ownerID: "thread-1",
                    ownerTitle: "Thread A",
                    sourceLabel: "Thread notes"
                ),
                AssistantChatWebThreadNoteSource(
                    ownerKind: "project",
                    ownerID: "project-1",
                    ownerTitle: "Alpha",
                    sourceLabel: "Project notes"
                ),
            ],
            notes: [
                AssistantChatWebThreadNoteItem(
                    id: "note-1",
                    title: "Main note",
                    updatedAtLabel: "Saved now",
                    ownerKind: "project",
                    ownerID: "project-1",
                    sourceLabel: "Project notes"
                )
            ],
            selectedNoteID: "note-1",
            selectedNoteTitle: "Main note",
            text: "Draft note",
            isOpen: true,
            isExpanded: false,
            viewMode: "edit",
            hasAnyNotes: true,
            isSaving: false,
            isGeneratingAIDraft: true,
            aiDraftMode: "chart",
            lastSavedAtLabel: "Saved now",
            canEdit: true,
            placeholder: "Write note",
            aiDraftPreview: AssistantChatWebThreadNoteAIPreview(
                mode: "chart",
                sourceKind: "chatSelection",
                markdown: "## Stack\n\n```mermaid\nmindmap\n  root((SaaS))\n```",
                isError: false
            )
        )

        let json = state.toJSON()

        XCTAssertEqual(json["ownerKind"] as? String, "project")
        XCTAssertEqual(json["ownerId"] as? String, "project-1")
        XCTAssertEqual(json["presentation"] as? String, "projectFullScreen")
        XCTAssertEqual(json["isGeneratingAIDraft"] as? Bool, true)
        XCTAssertEqual(json["aiDraftMode"] as? String, "chart")
        let sources = json["availableSources"] as? [[String: Any]]
        XCTAssertEqual(sources?.count, 2)
        let preview = json["aiDraftPreview"] as? [String: Any]
        XCTAssertEqual(preview?["mode"] as? String, "chart")
        XCTAssertEqual(preview?["sourceKind"] as? String, "chatSelection")
        XCTAssertEqual(preview?["isError"] as? Bool, false)
    }

    func testCollapsedConversationHiddenIndicesIncludeProtectedRecentToolTurn() {
        let baseDate = Date(timeIntervalSince1970: 1_741_500_000)
        let renderItems = buildAssistantTimelineRenderItems(
            from: [
                .userMessage(
                    id: "user-1",
                    sessionID: "session-1",
                    turnID: "turn-1",
                    text: "Check the workspace",
                    createdAt: baseDate,
                    source: .runtime
                ),
                .assistantProgress(
                    id: "progress-1",
                    sessionID: "session-1",
                    turnID: "turn-1",
                    text: "I found the right project.",
                    createdAt: baseDate.addingTimeInterval(1),
                    updatedAt: baseDate.addingTimeInterval(1),
                    isStreaming: false,
                    source: .runtime
                ),
                .activity(
                    AssistantActivityItem(
                        id: "activity-1",
                        sessionID: "session-1",
                        turnID: "turn-1",
                        kind: .commandExecution,
                        title: "Command",
                        status: .completed,
                        friendlySummary: "Ran a command.",
                        rawDetails: "pwd",
                        startedAt: baseDate.addingTimeInterval(2),
                        updatedAt: baseDate.addingTimeInterval(2),
                        source: .runtime
                    )
                ),
                .assistantProgress(
                    id: "progress-2",
                    sessionID: "session-1",
                    turnID: "turn-1",
                    text: "I am checking the dashboard files now.",
                    createdAt: baseDate.addingTimeInterval(3),
                    updatedAt: baseDate.addingTimeInterval(3),
                    isStreaming: false,
                    source: .runtime
                ),
                .activity(
                    AssistantActivityItem(
                        id: "activity-2",
                        sessionID: "session-1",
                        turnID: "turn-1",
                        kind: .webSearch,
                        title: "Web Search",
                        status: .completed,
                        friendlySummary: "Searched the web.",
                        rawDetails: "nail salon dashboard",
                        startedAt: baseDate.addingTimeInterval(4),
                        updatedAt: baseDate.addingTimeInterval(4),
                        source: .runtime
                    )
                ),
                .assistantFinal(
                    id: "final-1",
                    sessionID: "session-1",
                    turnID: "turn-1",
                    text: "I found the renderer and the right files.",
                    createdAt: baseDate.addingTimeInterval(6),
                    updatedAt: baseDate.addingTimeInterval(6),
                    isStreaming: false,
                    source: .runtime
                ),
            ]
        )

        let hiddenIndices = assistantTimelineCollapsedConversationHiddenIndices(
            in: renderItems,
            segmentIndices: Array(renderItems.indices),
            protectedRecentConversationStartIndex: 0
        )

        XCTAssertEqual(hiddenIndices, [1, 2, 3, 4])
    }

    func testCollapsedConversationHiddenIndicesKeepProtectedRecentPlainTextTurnVisible() {
        let baseDate = Date(timeIntervalSince1970: 1_741_500_100)
        let renderItems = buildAssistantTimelineRenderItems(
            from: [
                .userMessage(
                    id: "user-1",
                    sessionID: "session-1",
                    turnID: "turn-1",
                    text: "Explain the result",
                    createdAt: baseDate,
                    source: .runtime
                ),
                .assistantProgress(
                    id: "progress-1",
                    sessionID: "session-1",
                    turnID: "turn-1",
                    text: "I am summarizing what changed.",
                    createdAt: baseDate.addingTimeInterval(1),
                    updatedAt: baseDate.addingTimeInterval(1),
                    isStreaming: false,
                    source: .runtime
                ),
                .assistantFinal(
                    id: "final-1",
                    sessionID: "session-1",
                    turnID: "turn-1",
                    text: "Here is the summary.",
                    createdAt: baseDate.addingTimeInterval(3),
                    updatedAt: baseDate.addingTimeInterval(3),
                    isStreaming: false,
                    source: .runtime
                ),
            ]
        )

        let hiddenIndices = assistantTimelineCollapsedConversationHiddenIndices(
            in: renderItems,
            segmentIndices: Array(renderItems.indices),
            protectedRecentConversationStartIndex: 0
        )

        XCTAssertEqual(hiddenIndices, [])
    }

    func testSidebarChildSubagentsAppearForMatchingParentThread() {
        let subagents = [
            SubagentState(
                id: "agent-1",
                parentThreadID: "thread-a",
                threadID: "child-1",
                nickname: "Kant",
                role: "explorer",
                status: .waiting,
                prompt: "Inspect the provider flow",
                startedAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 40),
                endedAt: nil
            ),
            SubagentState(
                id: "agent-2",
                parentThreadID: "thread-b",
                threadID: "child-2",
                nickname: "Harvey",
                role: "worker",
                status: .running,
                prompt: "Patch the UI",
                startedAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 50),
                endedAt: nil
            )
        ]

        let visibleChildren = assistantSidebarChildSubagents(
            parentSessionID: "thread-a",
            selectedSessionID: "thread-b",
            activeRuntimeSessionID: "another-thread",
            subagents: subagents
        )
        XCTAssertEqual(visibleChildren.map(\.id), ["agent-1"])

        let hiddenChildren = assistantSidebarChildSubagents(
            parentSessionID: "thread-c",
            selectedSessionID: "thread-b",
            activeRuntimeSessionID: "thread-a",
            subagents: subagents
        )
        XCTAssertTrue(hiddenChildren.isEmpty)
    }

    func testParentThreadLinkStateUsesInMemorySubagentRelationship() {
        let subagents = [
            SubagentState(
                id: "agent-1",
                parentThreadID: "parent-thread",
                threadID: "child-thread",
                nickname: "Kant",
                role: "explorer",
                status: .completed,
                prompt: "Inspect the runtime",
                startedAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 30),
                endedAt: Date(timeIntervalSince1970: 30)
            )
        ]

        let linkState = assistantParentThreadLinkState(
            selectedSessionID: "child-thread",
            activeRuntimeSessionID: "another-thread",
            subagents: subagents
        )
        XCTAssertEqual(linkState?.parentThreadID, "parent-thread")
        XCTAssertEqual(linkState?.childAgent.id, "agent-1")

        XCTAssertNil(
            assistantParentThreadLinkState(
                selectedSessionID: "missing-child-thread",
                activeRuntimeSessionID: "another-thread",
                subagents: subagents
            )
        )
    }

    func testSidebarHidesStandaloneSubagentThreadsUnlessSelected() {
        let parent = AssistantSessionSummary(
            id: "parent-thread",
            title: "Parent",
            source: .appServer,
            status: .completed
        )
        let child = AssistantSessionSummary(
            id: "child-thread",
            title: "Child",
            source: .appServer,
            status: .completed,
            parentThreadID: "parent-thread"
        )

        XCTAssertTrue(assistantShouldShowSessionInSidebar(parent, selectedSessionID: nil))
        XCTAssertFalse(assistantShouldShowSessionInSidebar(child, selectedSessionID: nil))
        XCTAssertTrue(assistantShouldShowSessionInSidebar(child, selectedSessionID: "child-thread"))
    }

    func testEffectiveTemporarySessionIDsIncludeSubagentDescendants() {
        let sessions = [
            AssistantSessionSummary(
                id: "parent-thread",
                title: "Parent",
                source: .appServer,
                status: .completed
            ),
            AssistantSessionSummary(
                id: "child-thread",
                title: "Child",
                source: .appServer,
                status: .completed,
                parentThreadID: "parent-thread"
            ),
            AssistantSessionSummary(
                id: "grandchild-thread",
                title: "Grandchild",
                source: .appServer,
                status: .completed,
                parentThreadID: "child-thread"
            )
        ]

        let effective = assistantEffectiveTemporarySessionIDs(
            storedTemporaryIDs: Set(["parent-thread"]),
            sessions: sessions
        )

        XCTAssertEqual(
            effective,
            Set(["parent-thread", "child-thread", "grandchild-thread"])
        )
    }

    func testChildSessionIDsReturnNestedDescendants() {
        let sessions = [
            AssistantSessionSummary(
                id: "parent-thread",
                title: "Parent",
                source: .appServer,
                status: .completed
            ),
            AssistantSessionSummary(
                id: "child-a",
                title: "Child A",
                source: .appServer,
                status: .completed,
                parentThreadID: "parent-thread"
            ),
            AssistantSessionSummary(
                id: "child-b",
                title: "Child B",
                source: .appServer,
                status: .completed,
                parentThreadID: "parent-thread"
            ),
            AssistantSessionSummary(
                id: "grandchild",
                title: "Grandchild",
                source: .appServer,
                status: .completed,
                parentThreadID: "child-a"
            )
        ]

        XCTAssertEqual(
            Set(assistantChildSessionIDs(parentSessionID: "parent-thread", sessions: sessions)),
            Set(["child-a", "child-b", "grandchild"])
        )
    }
}
