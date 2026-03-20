import Foundation
import XCTest
@testable import OpenAssist

final class AssistantMemoryRetrievalServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testPrepareTurnContextUsesThreadFileAndAssistantOnlyLongTermMemory() throws {
        let memoryRoot = try makeTemporaryDirectory(named: "assistant-memory")
        let databaseURL = try makeDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let threadMemoryService = AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        let retrievalService = AssistantMemoryRetrievalService(
            store: store,
            threadMemoryService: threadMemoryService
        )
        let scope = retrievalService.makeScopeContext(threadID: "thread-1", cwd: "/tmp/OpenAssist")

        try store.upsertConversationThread(
            ConversationThreadRecord(
                id: "thread-1",
                appName: "Open Assist",
                bundleID: "com.developingadventures.OpenAssist",
                logicalSurfaceKey: "assistant-thread-1",
                screenLabel: "Assistant",
                fieldLabel: "Chat",
                projectKey: "project:openassist",
                projectLabel: "Open Assist",
                identityKey: "assistant-session:thread-1",
                identityType: "assistant-session",
                identityLabel: "thread-1",
                nativeThreadKey: "thread-1",
                people: [],
                runningSummary: "",
                totalExchangeTurns: 0,
                createdAt: Date(),
                lastActivityAt: Date(),
                updatedAt: Date()
            )
        )

        var document = AssistantThreadMemoryDocument.empty
        document.currentTask = "Export Square sales report from Brave safely"
        document.activeFacts = ["Square is already open in Brave"]
        document.importantReferences = ["Brave", "Square Dashboard"]
        document.sessionPreferences = ["Keep the answer short"]
        _ = try threadMemoryService.saveDocument(document, for: "thread-1")

        try store.upsertConversationAgentProfile(
            ConversationAgentProfileRecord(
                threadID: "thread-1",
                profileJSON: #"{"tone":"brief"}"#,
                updatedAt: Date()
            )
        )
        try store.upsertAssistantMemoryEntry(
            AssistantMemoryEntry(
                provider: .codex,
                scopeKey: scope.scopeKey,
                bundleID: scope.bundleID,
                projectKey: scope.projectKey,
                identityKey: scope.identityKey,
                threadID: "thread-1",
                memoryType: .constraint,
                title: "Brave Apple Events",
                summary: "Export Square sales report from Brave safely",
                detail: "Brave may block Apple Events JavaScript until the developer setting is enabled.",
                keywords: ["brave", "apple", "events", "javascript"],
                confidence: 0.91,
                metadata: ["memory_domain": "assistant"]
            )
        )

        let built = try retrievalService.prepareTurnContext(
            threadID: "thread-1",
            prompt: "Export Square sales report from Brave safely",
            cwd: "/tmp/OpenAssist",
            summaryMaxChars: 1400
        )

        let summary = try XCTUnwrap(built.summary)
        XCTAssertTrue(summary.contains("Current task: Export Square sales report from Brave safely"))
        XCTAssertTrue(summary.contains("Square is already open in Brave"))
        XCTAssertTrue(summary.contains("Keep the answer short"))
        XCTAssertTrue(summary.contains("[Constraint] Export Square sales report from Brave safely"))
        XCTAssertTrue(
            ["Using session memory", "Using updated session memory"].contains(built.statusMessage ?? "")
        )
        XCTAssertNotNil(built.fileURL)
    }

    func testAssistantLongTermMemoryDoesNotLeakIntoRewriteRetrieval() async throws {
        let memoryRoot = try makeTemporaryDirectory(named: "assistant-memory")
        let databaseURL = try makeDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let threadMemoryService = AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        let retrievalService = AssistantMemoryRetrievalService(
            store: store,
            threadMemoryService: threadMemoryService
        )
        let rewriteService = MemoryRewriteRetrievalService(
            storeFactory: { try MemorySQLiteStore(databaseURL: databaseURL) }
        )

        let built = try retrievalService.prepareTurnContext(
            threadID: "thread-2",
            prompt: "Use Brave for Square export",
            cwd: "/tmp/OpenAssist",
            summaryMaxChars: 1000
        )
        XCTAssertNotNil(built.fileURL)

        try store.upsertAssistantMemoryEntry(
            AssistantMemoryEntry(
                provider: .codex,
                scopeKey: built.scope.scopeKey,
                bundleID: built.scope.bundleID,
                projectKey: built.scope.projectKey,
                identityKey: built.scope.identityKey,
                threadID: "thread-2",
                memoryType: .lesson,
                title: "Square in Brave",
                summary: "Check whether Square is already open before starting a new login flow.",
                detail: "Reuse the already logged-in Square tab when possible.",
                keywords: ["square", "brave", "login"],
                confidence: 0.88,
                metadata: ["memory_domain": "assistant"]
            )
        )

        let rewriteSuggestion = try await rewriteService.retrieveSuggestion(
            for: "check whether square is already open",
            scope: built.scope
        )
        XCTAssertNil(rewriteSuggestion)
    }

    func testAssistantTurnSummaryIgnoresRewriteOnlyMemory() throws {
        let memoryRoot = try makeTemporaryDirectory(named: "assistant-memory")
        let databaseURL = try makeDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let retrievalService = AssistantMemoryRetrievalService(
            store: store,
            threadMemoryService: AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        )

        try store.upsertFeedbackRewriteMemory(
            originalText: "please chek invoices",
            rewrittenText: "please check invoices",
            rationale: "A normal rewrite correction",
            confidence: 0.93
        )

        let built = try retrievalService.prepareTurnContext(
            threadID: "thread-3",
            prompt: "Check invoices in the assistant",
            cwd: "/tmp/OpenAssist",
            summaryMaxChars: 1000
        )

        let summary = built.summary ?? ""
        XCTAssertFalse(summary.contains("please check invoices"))
        XCTAssertFalse(summary.contains("A normal rewrite correction"))
    }

    func testPrepareTurnContextIncludesProjectScopeLessonsAndProjectBlock() throws {
        let memoryRoot = try makeTemporaryDirectory(named: "assistant-memory")
        let databaseURL = try makeDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let threadMemoryService = AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        let retrievalService = AssistantMemoryRetrievalService(
            store: store,
            threadMemoryService: threadMemoryService
        )

        let projectScope = retrievalService.makeScopeContext(
            threadID: "thread-project",
            cwd: "/tmp/website-app",
            projectIdentityKey: "assistant-project:proj-1",
            projectNameOverride: "Website App",
            repositoryNameOverride: "website-app"
        )

        try store.upsertAssistantMemoryEntry(
            AssistantMemoryEntry(
                provider: .codex,
                scopeKey: projectScope.scopeKey,
                bundleID: projectScope.bundleID,
                projectKey: projectScope.projectKey,
                identityKey: projectScope.identityKey,
                threadID: nil,
                memoryType: .lesson,
                title: "Package manager",
                summary: "Update project dependencies with pnpm, not npm.",
                detail: "When you update project dependencies here, use pnpm instead of npm.",
                keywords: ["pnpm", "project", "dependencies", "npm"],
                confidence: 0.9,
                metadata: ["memory_domain": "assistant"]
            )
        )

        let built = try retrievalService.prepareTurnContext(
            threadID: "thread-project",
            prompt: "Update the project dependencies with pnpm",
            cwd: "/tmp/website-app",
            summaryMaxChars: 1400,
            longTermScope: projectScope,
            projectContextBlock: "Project context:\n- Project name: Website App\n- Project memory summary: Shared notes"
        )

        let summary = try XCTUnwrap(built.summary)
        XCTAssertTrue(summary.contains("Project context:"))
        XCTAssertTrue(summary.contains("Website App"))
        XCTAssertTrue(summary.contains("dependencies with pnpm"))
        XCTAssertEqual(built.statusMessage, "Using automation memory")
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = try makeTemporaryDirectory(named: "assistant-memory-db")
        return directory.appendingPathComponent("memory.sqlite", isDirectory: false)
    }
}
