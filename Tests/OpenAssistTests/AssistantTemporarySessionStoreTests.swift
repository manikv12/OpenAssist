import Foundation
import XCTest
@testable import OpenAssist

final class AssistantTemporarySessionStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testTemporarySessionStorePersistsMarkedSessionIDs() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-temporary-store")
        let store = AssistantTemporarySessionStore(baseDirectoryURL: directory)

        try store.markTemporary("Thread-A")
        try store.markTemporary("thread-b")

        let reloadedStore = AssistantTemporarySessionStore(baseDirectoryURL: directory)
        XCTAssertTrue(reloadedStore.contains("thread-a"))
        XCTAssertTrue(reloadedStore.contains("THREAD-B"))
        XCTAssertEqual(reloadedStore.temporarySessionIDs(), Set(["thread-a", "thread-b"]))
    }

    func testRemovingTemporaryFlagClearsStoredSessionID() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-temporary-remove")
        let store = AssistantTemporarySessionStore(baseDirectoryURL: directory)

        try store.markTemporary("thread-a")
        try store.markTemporary("thread-b")
        try store.removeTemporaryFlag("THREAD-A")

        XCTAssertFalse(store.contains("thread-a"))
        XCTAssertTrue(store.contains("thread-b"))
        XCTAssertEqual(store.temporarySessionIDs(), Set(["thread-b"]))
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
