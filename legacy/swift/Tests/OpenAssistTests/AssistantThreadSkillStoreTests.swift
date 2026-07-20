import Foundation
import XCTest
@testable import OpenAssist

final class AssistantThreadSkillStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testThreadSkillStorePersistsNormalizedBindings() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-thread-skill-store")
        let store = AssistantThreadSkillStore(baseDirectoryURL: directory)

        try store.attach(
            skillName: " Obsidian CLI ",
            to: " Thread-A ",
            now: Date(timeIntervalSince1970: 10)
        )
        try store.attach(
            skillName: "pdf",
            to: "thread-a",
            now: Date(timeIntervalSince1970: 20)
        )
        try store.attach(
            skillName: "obsidian_cli",
            to: "THREAD-A",
            now: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(store.bindings(for: "thread-a").map(\.skillName), ["obsidian-cli", "pdf"])

        let reloadedStore = AssistantThreadSkillStore(baseDirectoryURL: directory)
        XCTAssertEqual(reloadedStore.bindings(for: "THREAD-A").map(\.threadID), ["thread-a", "thread-a"])
        XCTAssertEqual(reloadedStore.bindings(for: "THREAD-A").map(\.skillName), ["obsidian-cli", "pdf"])
    }

    func testMigrateBindingsCopiesSourceBindingsWithoutDuplicates() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-thread-skill-migrate")
        let store = AssistantThreadSkillStore(baseDirectoryURL: directory)

        try store.attach(
            skillName: "obsidian-cli",
            to: "source-thread",
            now: Date(timeIntervalSince1970: 10)
        )
        try store.attach(
            skillName: "pdf",
            to: "source-thread",
            now: Date(timeIntervalSince1970: 20)
        )
        try store.attach(
            skillName: "pdf",
            to: "destination-thread",
            now: Date(timeIntervalSince1970: 30)
        )

        try store.migrateBindings(from: "SOURCE-THREAD", to: "destination-thread")

        XCTAssertEqual(
            store.bindings(for: "destination-thread").map(\.skillName),
            ["obsidian-cli", "pdf"]
        )
        XCTAssertEqual(
            store.bindings(for: "source-thread").map(\.skillName),
            ["obsidian-cli", "pdf"]
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
