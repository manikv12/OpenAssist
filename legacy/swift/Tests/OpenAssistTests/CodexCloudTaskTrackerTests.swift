import Foundation
import XCTest
@testable import OpenAssist

final class CodexCloudTaskTrackerTests: XCTestCase {
    func testInitialSeedDoesNotEmitEvents() {
        let tracker = CodexCloudTaskTracker()

        let events = tracker.ingest([
            makeTask(id: "task-1", status: "running", updatedAt: "2026-03-06T10:00:00Z")
        ])

        XCTAssertTrue(events.isEmpty)
    }

    func testReadyTransitionEmitsSingleReadyEvent() {
        let tracker = CodexCloudTaskTracker()
        _ = tracker.ingest([
            makeTask(id: "task-1", status: "running", updatedAt: "2026-03-06T10:00:00Z")
        ])

        let events = tracker.ingest([
            makeTask(id: "task-1", status: "ready", updatedAt: "2026-03-06T10:05:00Z")
        ])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.task.id, "task-1")
        XCTAssertEqual(events.first?.outcome, .ready)
    }

    func testFailureTransitionEmitsSingleFailedEvent() {
        let tracker = CodexCloudTaskTracker()
        _ = tracker.ingest([
            makeTask(id: "task-2", status: "running", updatedAt: "2026-03-06T10:00:00Z")
        ])

        let events = tracker.ingest([
            makeTask(
                id: "task-2",
                status: "failed",
                updatedAt: "2026-03-06T10:06:00Z",
                errorMessage: "Task crashed"
            )
        ])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.task.id, "task-2")
        XCTAssertEqual(events.first?.outcome, .failed)
    }

    func testSameTerminalStateIsNotReplayed() {
        let tracker = CodexCloudTaskTracker()
        _ = tracker.ingest([
            makeTask(id: "task-3", status: "running", updatedAt: "2026-03-06T10:00:00Z")
        ])
        _ = tracker.ingest([
            makeTask(id: "task-3", status: "ready", updatedAt: "2026-03-06T10:05:00Z")
        ])

        let repeatedEvents = tracker.ingest([
            makeTask(id: "task-3", status: "ready", updatedAt: "2026-03-06T10:06:00Z")
        ])

        XCTAssertTrue(repeatedEvents.isEmpty)
    }

    private func makeTask(
        id: String,
        status: String,
        updatedAt: String,
        errorMessage: String? = nil
    ) -> CodexCloudTask {
        CodexCloudTask(
            id: id,
            title: "Test task",
            status: status,
            updatedAt: updatedAt,
            completedAt: nil,
            environmentLabel: "workspace",
            description: nil,
            errorMessage: errorMessage,
            summary: CodexCloudTaskSummary(
                filesChanged: 0,
                linesAdded: 0,
                linesRemoved: 0
            )
        )
    }
}
