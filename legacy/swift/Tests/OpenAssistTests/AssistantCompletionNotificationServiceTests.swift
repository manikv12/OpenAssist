import Foundation
import UserNotifications
import XCTest
@testable import OpenAssist

@MainActor
final class AssistantCompletionNotificationServiceTests: XCTestCase {
    func testPreviewBuildsSuccessNotificationWithSessionTitle() throws {
        let service = AssistantCompletionNotificationService(deliveryCenter: AssistantCompletionNotificationDelivererSpy())
        let event = AssistantCompletionNotificationEvent(
            sessionID: "session-1",
            sessionTitle: "Build API",
            turnID: "turn-9",
            outcome: .completed,
            isBackground: true
        )

        let preview = try XCTUnwrap(service.preview(for: event))

        XCTAssertEqual(preview.identifier, "openassist-assistant-completion-assistant-completion|session-1|turn-9|completed|build-api")
        XCTAssertEqual(preview.title, "Build API")
        XCTAssertEqual(preview.body, "Background chat finished.")
        XCTAssertNil(preview.subtitle)
        XCTAssertEqual(preview.threadIdentifier, "session-1")
        XCTAssertEqual(preview.userInfo["sessionID"], "session-1")
        XCTAssertEqual(preview.userInfo["turnID"], "turn-9")
        XCTAssertEqual(preview.userInfo["outcome"], "completed")
        XCTAssertEqual(preview.userInfo["dedupeKey"], "assistant-completion|session-1|turn-9|completed|build api")
    }

    func testPreviewBuildsFailureNotificationWithFallbackTitleAndReason() throws {
        let service = AssistantCompletionNotificationService(deliveryCenter: AssistantCompletionNotificationDelivererSpy())
        let event = AssistantCompletionNotificationEvent(
            sessionID: "session-2",
            sessionTitle: "   ",
            turnID: "turn-12",
            outcome: .failed(reason: "Network timeout"),
            isBackground: true
        )

        let preview = try XCTUnwrap(service.preview(for: event))

        XCTAssertEqual(preview.title, "Open Assist")
        XCTAssertEqual(preview.body, "Background chat failed.")
        XCTAssertEqual(preview.subtitle, "Network timeout")
        XCTAssertEqual(preview.threadIdentifier, "session-2")
        XCTAssertEqual(preview.userInfo["outcome"], "failed")
        XCTAssertEqual(preview.userInfo["reason"], "Network timeout")
    }

    func testPreviewSkipsForegroundChats() {
        let service = AssistantCompletionNotificationService(deliveryCenter: AssistantCompletionNotificationDelivererSpy())
        let event = AssistantCompletionNotificationEvent(
            sessionID: "session-3",
            sessionTitle: "Docs",
            outcome: .completed,
            isBackground: false
        )

        XCTAssertNil(service.preview(for: event))
    }

    func testNotifyDedupesRepeatBackgroundCompletionEvents() async throws {
        let deliverer = AssistantCompletionNotificationDelivererSpy()
        let service = AssistantCompletionNotificationService(deliveryCenter: deliverer)
        let event = AssistantCompletionNotificationEvent(
            sessionID: "session-4",
            sessionTitle: "Research",
            turnID: "turn-1",
            outcome: .completed,
            isBackground: true,
            dedupeWindow: 15
        )
        let first = Date(timeIntervalSince1970: 1_000)

        let firstDelivered = await service.notify(for: event, now: first)
        XCTAssertTrue(firstDelivered)
        XCTAssertEqual(deliverer.requests.count, 1)

        let secondDelivered = await service.notify(for: event, now: first.addingTimeInterval(5))
        XCTAssertFalse(secondDelivered)
        XCTAssertEqual(deliverer.requests.count, 1)

        let thirdDelivered = await service.notify(for: event, now: first.addingTimeInterval(20))
        XCTAssertTrue(thirdDelivered)
        XCTAssertEqual(deliverer.requests.count, 2)
    }

    func testNotifyAllowsDifferentTurnsWithinWindow() async throws {
        let deliverer = AssistantCompletionNotificationDelivererSpy()
        let service = AssistantCompletionNotificationService(deliveryCenter: deliverer)
        let first = Date(timeIntervalSince1970: 2_000)

        let firstEvent = AssistantCompletionNotificationEvent(
            sessionID: "session-5",
            sessionTitle: "Fix bug",
            turnID: "turn-a",
            outcome: .failed(reason: "Denied"),
            isBackground: true,
            dedupeWindow: 30
        )
        let secondEvent = AssistantCompletionNotificationEvent(
            sessionID: "session-5",
            sessionTitle: "Fix bug",
            turnID: "turn-b",
            outcome: .failed(reason: "Denied"),
            isBackground: true,
            dedupeWindow: 30
        )

        let firstDelivered = await service.notify(for: firstEvent, now: first)
        let secondDelivered = await service.notify(for: secondEvent, now: first.addingTimeInterval(1))

        XCTAssertTrue(firstDelivered)
        XCTAssertTrue(secondDelivered)
        XCTAssertEqual(deliverer.requests.count, 2)
    }

    func testDeliveredRequestCarriesAssistantMetadata() async throws {
        let deliverer = AssistantCompletionNotificationDelivererSpy()
        let service = AssistantCompletionNotificationService(deliveryCenter: deliverer)
        let event = AssistantCompletionNotificationEvent(
            sessionID: "session-6",
            sessionTitle: "Ship it",
            turnID: "turn-77",
            outcome: .failed(reason: "Compilation failed"),
            isBackground: true
        )

        let delivered = await service.notify(for: event, now: Date(timeIntervalSince1970: 3_000))
        XCTAssertTrue(delivered)

        let request = try XCTUnwrap(deliverer.requests.first)
        let content = request.content
        XCTAssertEqual(content.title, "Ship it")
        XCTAssertEqual(content.body, "Background chat failed.")
        XCTAssertEqual(content.subtitle, "Compilation failed")
        XCTAssertEqual(content.threadIdentifier, "session-6")
        XCTAssertEqual(content.categoryIdentifier, "openassist.assistant.completion")
        XCTAssertEqual(content.userInfo["sessionID"] as? String, "session-6")
        XCTAssertEqual(content.userInfo["turnID"] as? String, "turn-77")
        XCTAssertEqual(content.userInfo["outcome"] as? String, "failed")
        XCTAssertEqual(content.userInfo["reason"] as? String, "Compilation failed")
    }
}

@MainActor
private final class AssistantCompletionNotificationDelivererSpy: AssistantCompletionNotificationDelivering {
    private(set) var requests: [UNNotificationRequest] = []

    func add(_ request: UNNotificationRequest) async throws {
        requests.append(request)
    }
}
