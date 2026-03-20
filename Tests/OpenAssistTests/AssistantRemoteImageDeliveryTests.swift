import Foundation
import XCTest
@testable import OpenAssist

final class AssistantRemoteImageDeliveryTests: XCTestCase {
    @MainActor
    func testLatestRemoteImageItemPrefersNewestImageInCurrentTurn() {
        let firstImage = Data([0x01, 0x02, 0x03])
        let secondImage = Data([0x04, 0x05, 0x06])

        let items: [AssistantTimelineItem] = [
            .userMessage(
                sessionID: "session-1",
                text: "Show me the screen",
                source: .runtime
            ),
            .assistantProgress(
                id: "progress-1",
                sessionID: "session-1",
                text: "Taking a screenshot",
                createdAt: Date(timeIntervalSince1970: 1_000),
                isStreaming: false,
                source: .runtime
            ),
            AssistantTimelineItem(
                id: "image-1",
                sessionID: "session-1",
                turnID: "turn-1",
                kind: .assistantProgress,
                createdAt: Date(timeIntervalSince1970: 1_010),
                updatedAt: Date(timeIntervalSince1970: 1_010),
                text: "First image",
                isStreaming: false,
                emphasis: false,
                activity: nil,
                permissionRequest: nil,
                planText: nil,
                planEntries: nil,
                imageAttachments: [firstImage],
                source: .runtime
            ),
            AssistantTimelineItem(
                id: "image-2",
                sessionID: "session-1",
                turnID: "turn-1",
                kind: .assistantFinal,
                createdAt: Date(timeIntervalSince1970: 1_020),
                updatedAt: Date(timeIntervalSince1970: 1_020),
                text: "Latest image",
                isStreaming: false,
                emphasis: false,
                activity: nil,
                permissionRequest: nil,
                planText: nil,
                planEntries: nil,
                imageAttachments: [secondImage],
                source: .runtime
            )
        ]

        let imageItem = AssistantStore.shared.latestRemoteImageItem(in: items)

        XCTAssertEqual(imageItem?.id, "image-2")
        XCTAssertEqual(imageItem?.text, "Latest image")
    }
}
