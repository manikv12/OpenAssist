import XCTest
@testable import OpenAssist

final class AssistantSessionRegistryTests: XCTestCase {
    func testReplaceSessionsStoresLatestCLIRecords() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let registry = AssistantSessionRegistry(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let older = AssistantSessionSummary(
            id: "copilot-1",
            title: "Older",
            source: .cli,
            status: .idle,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = AssistantSessionSummary(
            id: "copilot-2",
            title: "Newer",
            source: .cli,
            status: .active,
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        try registry.replaceSessions([older, newer], for: Set([.cli]))

        let stored = registry.sessions(sources: Set([.cli]))
        XCTAssertEqual(stored.map(\.id), ["copilot-2", "copilot-1"])
    }

    func testRemoveDeletesOnlyMatchingSource() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let registry = AssistantSessionRegistry(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let cliSession = AssistantSessionSummary(
            id: "shared-1",
            title: "Copilot",
            source: .cli,
            status: .idle
        )
        let appServerSession = AssistantSessionSummary(
            id: "shared-1",
            title: "Codex",
            source: .appServer,
            status: .idle
        )

        try registry.replaceSessions([cliSession], for: Set([.cli]))
        try registry.replaceSessions([appServerSession], for: Set([.appServer]))
        try registry.remove(sessionID: "shared-1", source: .cli)

        XCTAssertTrue(registry.sessions(sources: Set([.cli])).isEmpty)
        XCTAssertEqual(registry.sessions(sources: Set([.appServer])).map(\.id), ["shared-1"])
    }

    func testOpenAssistSessionsRoundTripProviderLinkMetadata() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let registry = AssistantSessionRegistry(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let thread = AssistantSessionSummary(
            id: "openassist-thread-1",
            title: "Provider Independent",
            source: .openAssist,
            providerBackend: .copilot,
            providerSessionID: "copilot-linked-1",
            status: .idle,
            updatedAt: Date(timeIntervalSince1970: 30)
        )

        try registry.replaceSessions([thread], for: Set([.openAssist]))

        let reloadedRegistry = AssistantSessionRegistry(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )
        let stored = try XCTUnwrap(reloadedRegistry.sessions(sources: Set([.openAssist])).first)
        XCTAssertEqual(stored.id, "openassist-thread-1")
        XCTAssertEqual(stored.providerBackend, .copilot)
        XCTAssertEqual(stored.providerSessionID, "copilot-linked-1")
    }

    func testOpenAssistV2SessionsRoundTripActiveProviderBindings() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let registry = AssistantSessionRegistry(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let thread = AssistantSessionSummary(
            id: "openassist-thread-v2",
            title: "Merged chat",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            activeProvider: .copilot,
            providerBindingsByBackend: [
                AssistantProviderBinding(
                    backend: .codex,
                    providerSessionID: "codex-provider-1",
                    latestModelID: "gpt-5.4"
                ),
                AssistantProviderBinding(
                    backend: .copilot,
                    providerSessionID: "copilot-provider-1",
                    latestModelID: "gemini-3-pro-preview"
                )
            ],
            status: .idle,
            updatedAt: Date(timeIntervalSince1970: 40)
        )

        try registry.replaceSessions([thread], for: Set([.openAssist]))

        let reloadedRegistry = AssistantSessionRegistry(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )
        let stored = try XCTUnwrap(reloadedRegistry.sessions(sources: Set([.openAssist])).first)
        XCTAssertEqual(stored.threadArchitectureVersion, .providerIndependentV2)
        XCTAssertEqual(stored.activeProviderBackend, .copilot)
        XCTAssertEqual(stored.activeProviderSessionID, "copilot-provider-1")
        XCTAssertEqual(stored.providerBinding(for: .codex)?.providerSessionID, "codex-provider-1")
    }

    func testSetArchiveStateUpdatesManagedThreadMetadata() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let registry = AssistantSessionRegistry(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let session = AssistantSessionSummary(
            id: "openassist-thread-v2",
            title: "Merged chat",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            status: .idle
        )
        try registry.replaceSessions([session], for: Set([.openAssist]))

        let archivedAt = Date(timeIntervalSince1970: 100)
        let expiresAt = Date(timeIntervalSince1970: 200)
        try registry.setArchiveState(
            sessionIDs: ["openassist-thread-v2"],
            sources: Set([.openAssist]),
            isArchived: true,
            archivedAt: archivedAt,
            expiresAt: expiresAt,
            usesDefaultRetention: true
        )

        let stored = try XCTUnwrap(registry.sessions(sources: Set([.openAssist])).first)
        XCTAssertTrue(stored.isArchived)
        XCTAssertEqual(stored.archivedAt, archivedAt)
        XCTAssertEqual(stored.archiveExpiresAt, expiresAt)
        XCTAssertEqual(stored.archiveUsesDefaultRetention, true)
        XCTAssertEqual(
            registry.expiredArchivedSessionIDs(asOf: Date(timeIntervalSince1970: 250), sources: Set([.openAssist])),
            ["openassist-thread-v2"]
        )
    }
}
