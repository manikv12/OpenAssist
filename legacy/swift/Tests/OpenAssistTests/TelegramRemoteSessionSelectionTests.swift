import XCTest
@testable import OpenAssist

final class TelegramRemoteSessionSelectionTests: XCTestCase {
    func testRestoredSelectedSessionPrefersRememberedVisibleSession() {
        let visibleSessions = [
            makeSession(id: "session-1", title: "Newest"),
            makeSession(id: "session-2", title: "Remembered")
        ]

        XCTAssertEqual(
            TelegramRemoteSessionSelection.restoredSessionID(
                preferredSessionID: "session-2",
                visibleSessions: visibleSessions
            ),
            "session-2"
        )
    }

    func testRestoredSelectedSessionFallsBackToNewestVisibleSessionWhenRememberedMissing() {
        let visibleSessions = [
            makeSession(id: "session-newest", title: "Newest"),
            makeSession(id: "session-older", title: "Older")
        ]

        XCTAssertEqual(
            TelegramRemoteSessionSelection.restoredSessionID(
                preferredSessionID: "missing-session",
                visibleSessions: visibleSessions
            ),
            "session-newest"
        )
    }

    func testRestoredSelectedSessionReturnsNilWhenNoVisibleSessionsExist() {
        XCTAssertNil(
            TelegramRemoteSessionSelection.restoredSessionID(
                preferredSessionID: "missing-session",
                visibleSessions: []
            )
        )
    }

    func testOutgoingTargetSessionIDPrefersCurrentVisibleSession() {
        XCTAssertEqual(
            TelegramRemoteSessionSelection.outgoingTargetSessionID(
                currentSessionID: "session-current",
                createdSessionID: "session-created"
            ),
            "session-current"
        )
    }

    func testOutgoingTargetSessionIDUsesCreatedSessionWhenNeeded() {
        XCTAssertEqual(
            TelegramRemoteSessionSelection.outgoingTargetSessionID(
                currentSessionID: nil,
                createdSessionID: "session-created"
            ),
            "session-created"
        )
    }

    func testOutgoingTargetSessionIDReturnsNilWhenNoSessionCanBeResolved() {
        XCTAssertNil(
            TelegramRemoteSessionSelection.outgoingTargetSessionID(
                currentSessionID: nil,
                createdSessionID: nil
            )
        )
    }

    private func makeSession(id: String, title: String) -> AssistantSessionSummary {
        AssistantSessionSummary(
            id: id,
            title: title,
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            status: .idle,
            latestUserMessage: "hello"
        )
    }
}
