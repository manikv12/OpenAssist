import XCTest
@testable import OpenAssist

final class AssistantWindowSupportTests: XCTestCase {
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
