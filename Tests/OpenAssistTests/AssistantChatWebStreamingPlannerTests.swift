import XCTest
@testable import OpenAssist

final class AssistantChatWebStreamingPlannerTests: XCTestCase {
    func testDetectsStreamingWhenStreamingMessageIsNotLast() {
        let messages = [
            makeMessage(id: "user-1", type: "user", text: "Hello", isStreaming: false),
            makeMessage(id: "assistant-1", type: "assistant", text: "Working", isStreaming: true),
            makeMessage(
                id: "activity-1",
                type: "activity",
                text: nil,
                isStreaming: false,
                activityTitle: "Running tool"
            ),
        ]

        XCTAssertTrue(AssistantChatWebStreamingUpdatePlanner.hasStreamingMessages(messages))
    }

    func testBuildsIncrementalEventsForMiddleStreamingAssistantMessage() {
        let previous = [
            makeMessage(id: "user-1", type: "user", text: "Hello", isStreaming: false),
            makeMessage(id: "assistant-1", type: "assistant", text: "Work", isStreaming: true),
            makeMessage(
                id: "activity-1",
                type: "activity",
                text: nil,
                isStreaming: false,
                activityTitle: "Running tool",
                activityDetail: "Step 1"
            ),
        ]

        let next = [
            makeMessage(id: "user-1", type: "user", text: "Hello", isStreaming: false),
            makeMessage(id: "assistant-1", type: "assistant", text: "Working", isStreaming: true),
            makeMessage(
                id: "activity-1",
                type: "activity",
                text: nil,
                isStreaming: false,
                activityTitle: "Running tool",
                activityDetail: "Step 1"
            ),
        ]

        XCTAssertEqual(
            AssistantChatWebStreamingUpdatePlanner.incrementalEvents(
                from: previous,
                to: next,
                previousActiveWorkState: nil,
                nextActiveWorkState: nil,
                previousTyping: (false, "", ""),
                nextTyping: (false, "", ""),
                previousActiveTurnState: nil,
                nextActiveTurnState: nil
            ),
            [
                .responseTextDelta(
                    messageID: "assistant-1",
                    text: "Working",
                    isStreaming: true
                )
            ]
        )
    }

    func testFallsBackToMessageUpsertWhenNonTextFieldsChange() {
        let previous = [
            makeMessage(id: "user-1", type: "user", text: "Hello", isStreaming: false),
            makeMessage(
                id: "activity-1",
                type: "activity",
                text: nil,
                isStreaming: false,
                activityTitle: "Running tool",
                activityDetail: "Step 1"
            ),
        ]

        let next = [
            makeMessage(id: "user-1", type: "user", text: "Hello", isStreaming: false),
            makeMessage(
                id: "activity-1",
                type: "activity",
                text: nil,
                isStreaming: false,
                activityTitle: "Running tool",
                activityDetail: "Step 2"
            ),
        ]

        XCTAssertEqual(
            AssistantChatWebStreamingUpdatePlanner.incrementalEvents(
                from: previous,
                to: next,
                previousActiveWorkState: nil,
                nextActiveWorkState: nil,
                previousTyping: (false, "", ""),
                nextTyping: (false, "", ""),
                previousActiveTurnState: nil,
                nextActiveTurnState: nil
            ),
            [
                .upsertMessage(message: next[1], afterMessageID: "user-1")
            ]
        )
    }

    private func makeMessage(
        id: String,
        type: String,
        text: String?,
        isStreaming: Bool,
        activityTitle: String? = nil,
        activityDetail: String? = nil
    ) -> AssistantChatWebMessage {
        AssistantChatWebMessage(
            id: id,
            type: type,
            text: text,
            isStreaming: isStreaming,
            timestamp: Date(timeIntervalSince1970: 1),
            turnID: nil,
            images: nil,
            emphasis: false,
            canUndo: false,
            canEdit: false,
            rewriteAnchorID: nil,
            providerLabel: "Codex",
            selectedPlugins: nil,
            activityIcon: nil,
            activityTitle: activityTitle,
            activityDetail: activityDetail,
            activityStatus: activityTitle == nil ? nil : "running",
            activityStatusLabel: activityTitle == nil ? nil : "Running",
            detailSections: nil,
            activityTargets: nil,
            groupItems: nil,
            loadActivityDetailsID: nil,
            collapseActivityDetailsID: nil
        )
    }
}
