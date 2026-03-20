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
}
