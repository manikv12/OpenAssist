import Foundation
import XCTest
@testable import OpenAssist

final class AssistantThreadMemoryServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testEnsureMemoryFileCreatesStructuredMarkdown() throws {
        let service = AssistantThreadMemoryService(baseDirectoryURL: try makeTemporaryDirectory())

        let fileURL = try service.ensureMemoryFile(for: "thread-1", seedTask: "Check new emails today")
        let markdown = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertTrue(markdown.contains("# Current task"))
        XCTAssertTrue(markdown.contains("Check new emails today"))
        XCTAssertTrue(markdown.contains("# Active facts"))
        XCTAssertTrue(markdown.contains("# Candidate lessons"))
    }

    func testSoftResetArchivesOldMemoryIntoSnapshot() throws {
        let baseDirectoryURL = try makeTemporaryDirectory()
        let service = AssistantThreadMemoryService(baseDirectoryURL: baseDirectoryURL)
        let threadID = "thread-reset"

        var document = AssistantThreadMemoryDocument.empty
        document.currentTask = "Export Square sales"
        document.activeFacts = ["Square is already open in Brave"]
        document.importantReferences = ["Brave"]
        _ = try service.saveDocument(document, for: threadID)

        let change = try service.softReset(
            for: threadID,
            reason: "User changed tasks",
            nextTask: "Check new emails"
        )

        XCTAssertEqual(change.document.currentTask, "Check new emails")
        XCTAssertEqual(change.document.staleNotes, ["Memory reset: User changed tasks"])

        let snapshotsURL = baseDirectoryURL
            .appendingPathComponent(threadID, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        let snapshots = try FileManager.default.contentsOfDirectory(
            at: snapshotsURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(snapshots.count, 1)

        let snapshotMarkdown = try String(contentsOf: snapshots[0], encoding: .utf8)
        XCTAssertTrue(snapshotMarkdown.contains("Export Square sales"))
        XCTAssertTrue(snapshotMarkdown.contains("Square is already open in Brave"))
    }

    func testLoadTrackedDocumentDetectsExternalChanges() throws {
        let service = AssistantThreadMemoryService(baseDirectoryURL: try makeTemporaryDirectory())
        let threadID = "thread-dirty"

        let fileURL = try service.ensureMemoryFile(for: threadID, seedTask: "Check invoices")
        _ = try service.loadTrackedDocument(for: threadID)
        Thread.sleep(forTimeInterval: 1.1)

        let externalMarkdown = """
        # Current task
        Updated outside OpenAssist

        # Active facts
        - File changed by hand

        # Important names / files / services
        _Add file names, services, or important names here._

        # Session preferences
        _Add preferences learned in this session._

        # Stale notes
        _Moved here when the task changes or old notes become stale._

        # Candidate lessons
        _Potential long-term lessons waiting for review._
        """
        try externalMarkdown.write(to: fileURL, atomically: true, encoding: .utf8)

        let change = try service.loadTrackedDocument(for: threadID)
        XCTAssertTrue(change.didChangeExternally)
        XCTAssertEqual(change.document.currentTask, "Updated outside OpenAssist")
        XCTAssertEqual(change.document.activeFacts, ["File changed by hand"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssistantThreadMemoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
