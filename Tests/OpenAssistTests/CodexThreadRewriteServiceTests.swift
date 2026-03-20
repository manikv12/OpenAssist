import Foundation
import XCTest
@testable import OpenAssist

final class CodexThreadRewriteServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testEditableTurnsGroupPreludeAndPairedUserRecords() throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        let imageDataURL = try makeImageDataURL()
        try writeSession(
            id: "rewrite-parse",
            dayPath: "2026/03/18",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "rewrite-parse",
                    timestamp: "2026-03-18T10:00:00Z",
                    cwd: "/Users/test/OpenAssist",
                    source: "exec"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-18T10:00:01Z",
                    role: "user",
                    text: "<environment_context>\n  <cwd>/Users/test/OpenAssist</cwd>\n</environment_context>"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-18T10:00:02Z",
                    role: "user",
                    text: "## My request for Codex:\nFirst request",
                    imageDataURLs: [imageDataURL]
                ),
                try eventLine(
                    timestamp: "2026-03-18T10:00:03Z",
                    eventType: "user_message",
                    payload: [
                        "message": "## My request for Codex:\nFirst request",
                        "images": [imageDataURL]
                    ]
                ),
                try responseMessageLine(
                    timestamp: "2026-03-18T10:00:04Z",
                    role: "assistant",
                    text: "Handled the first request."
                ),
                try responseMessageLine(
                    timestamp: "2026-03-18T10:00:05Z",
                    role: "user",
                    text: "## My request for Codex:\nSecond request"
                ),
                try eventLine(
                    timestamp: "2026-03-18T10:00:06Z",
                    eventType: "user_message",
                    payload: [
                        "message": "## My request for Codex:\nSecond request",
                        "images": []
                    ]
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let service = CodexThreadRewriteService(sessionCatalog: catalog)
        let turns = try service.editableTurns(sessionID: "rewrite-parse")

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].text, "First request")
        XCTAssertEqual(turns[0].startLineIndex, 2)
        XCTAssertEqual(turns[0].endLineIndex, 4)
        XCTAssertEqual(turns[0].imageAttachments.count, 1)
        XCTAssertTrue(turns[0].supportsEdit)
        XCTAssertEqual(turns[1].text, "Second request")
        XCTAssertEqual(turns[1].startLineIndex, 5)
        XCTAssertEqual(turns[1].endLineIndex, 6)
    }

    func testTruncateBeforeTurnRemovesTargetTurnAndLaterHistory() throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        try writeSession(
            id: "rewrite-truncate",
            dayPath: "2026/03/18",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "rewrite-truncate",
                    timestamp: "2026-03-18T11:00:00Z",
                    cwd: "/Users/test/OpenAssist",
                    source: "exec"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-18T11:00:01Z",
                    role: "user",
                    text: "## My request for Codex:\nTurn one"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-18T11:00:02Z",
                    role: "assistant",
                    text: "Answer one"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-18T11:00:03Z",
                    role: "user",
                    text: "## My request for Codex:\nTurn two"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-18T11:00:04Z",
                    role: "assistant",
                    text: "Answer two"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-18T11:00:05Z",
                    role: "user",
                    text: "## My request for Codex:\nTurn three"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-18T11:00:06Z",
                    role: "assistant",
                    text: "Answer three"
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let service = CodexThreadRewriteService(sessionCatalog: catalog)
        let turns = try service.editableTurns(sessionID: "rewrite-truncate")
        let outcome = try service.truncateBeforeTurn(
            sessionID: "rewrite-truncate",
            turnAnchorID: turns[1].anchorID
        )

        XCTAssertEqual(outcome.retainedTurns.map(\.text), ["Turn one"])
        XCTAssertEqual(outcome.removedTurns.map(\.text), ["Turn two", "Turn three"])

        let timeline = awaitValue {
            await catalog.loadMergedTimeline(sessionID: "rewrite-truncate", limit: 20)
        }
        let userTexts = timeline
            .filter { $0.kind == .userMessage }
            .compactMap(\.text)
        XCTAssertEqual(userTexts, ["Turn one"])
    }

    func testBeginEditLastTurnCanBeCanceledAndRestoresOriginalSession() throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        try writeSession(
            id: "rewrite-edit",
            dayPath: "2026/03/18",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "rewrite-edit",
                    timestamp: "2026-03-18T12:00:00Z",
                    cwd: "/Users/test/OpenAssist",
                    source: "exec"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-18T12:00:01Z",
                    role: "user",
                    text: "## My request for Codex:\nOriginal first"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-18T12:00:02Z",
                    role: "assistant",
                    text: "Answer first"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-18T12:00:03Z",
                    role: "user",
                    text: "## My request for Codex:\nEditable last"
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let service = CodexThreadRewriteService(sessionCatalog: catalog)
        let turns = try service.editableTurns(sessionID: "rewrite-edit")
        let outcome = try service.beginEditLastTurn(
            sessionID: "rewrite-edit",
            turnAnchorID: try XCTUnwrap(turns.last?.anchorID)
        )

        XCTAssertEqual(outcome.retainedTurns.map(\.text), ["Original first"])
        XCTAssertEqual(outcome.editedTurn?.text, "Editable last")

        var timeline = awaitValue {
            await catalog.loadMergedTimeline(sessionID: "rewrite-edit", limit: 20)
        }
        XCTAssertEqual(
            timeline.filter { $0.kind == .userMessage }.compactMap(\.text),
            ["Original first"]
        )

        _ = try service.cancelPendingEdit(sessionID: "rewrite-edit")
        timeline = awaitValue {
            await catalog.loadMergedTimeline(sessionID: "rewrite-edit", limit: 20)
        }
        XCTAssertEqual(
            timeline.filter { $0.kind == .userMessage }.compactMap(\.text),
            ["Original first", "Editable last"]
        )
    }

    private func makeTemporaryHomeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexThreadRewriteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeImageDataURL() throws -> String {
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        return "data:image/png;base64,\(imageBytes.base64EncodedString())"
    }

    private func awaitValue<T>(_ operation: @escaping () async -> T) -> T {
        let expectation = expectation(description: "await-value")
        var result: T?
        Task {
            result = await operation()
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
        return result!
    }

    private func writeSession(
        id: String,
        dayPath: String,
        in homeDirectory: URL,
        lines: [String]
    ) throws {
        let sessionDirectory = homeDirectory
            .appendingPathComponent(".codex/sessions", isDirectory: true)
            .appendingPathComponent(dayPath, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let filename = "rollout-\(dayPath.replacingOccurrences(of: "/", with: "-"))-\(id).jsonl"
        let fileURL = sessionDirectory.appendingPathComponent(filename)
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func sessionMetaLine(
        id: String,
        timestamp: String,
        cwd: String,
        source: Any
    ) throws -> String {
        try jsonLine([
            "timestamp": timestamp,
            "type": "session_meta",
            "payload": [
                "id": id,
                "timestamp": timestamp,
                "cwd": cwd,
                "source": source
            ]
        ])
    }

    private func responseMessageLine(
        timestamp: String,
        role: String,
        text: String,
        imageDataURLs: [String] = []
    ) throws -> String {
        var content: [[String: Any]] = [[
            "type": role == "assistant" ? "output_text" : "input_text",
            "text": text
        ]]
        for imageDataURL in imageDataURLs {
            content.append([
                "type": "input_image",
                "image_url": imageDataURL
            ])
        }

        return try jsonLine([
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": role,
                "content": content
            ]
        ])
    }

    private func eventLine(
        timestamp: String,
        eventType: String,
        payload: [String: Any]
    ) throws -> String {
        var wrappedPayload = payload
        wrappedPayload["type"] = eventType
        return try jsonLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": wrappedPayload
        ])
    }

    private func jsonLine(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
