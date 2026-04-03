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

    func testBuildsIncrementalTextUpdateForMiddleStreamingAssistantMessage() {
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
            AssistantChatWebStreamingUpdatePlanner.incrementalTextUpdate(from: previous, to: next),
            AssistantChatWebStreamingTextUpdate(
                messageID: "assistant-1",
                text: "Working",
                isStreaming: true
            )
        )
    }

    func testFallsBackWhenNonTextFieldsChange() {
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

        XCTAssertNil(
            AssistantChatWebStreamingUpdatePlanner.incrementalTextUpdate(from: previous, to: next)
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
