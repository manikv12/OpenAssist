import Foundation
import XCTest
@testable import OpenAssist

final class AssistantMemorySuggestionServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testAcceptSuggestionPromotesAssistantOnlyMemory() throws {
        let memoryRoot = try makeTemporaryDirectory(named: "assistant-memory")
        let databaseURL = try makeDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let threadMemoryService = AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: threadMemoryService,
            store: store
        )

        let scope = MemoryScopeContext(
            appName: "Open Assist",
            bundleID: "com.manikvashith.OpenAssist",
            surfaceLabel: "Assistant",
            projectName: "OpenAssist",
            repositoryName: "OpenAssist",
            identityKey: "assistant-session:thread-1",
            identityType: "assistant-session",
            identityLabel: "thread-1",
            scopeKey: "scope|assistant|thread-1",
            isCodingContext: true
        )

        let created = try suggestionService.createManualSuggestions(
            from: "Avoid long step-by-step narration for simple tasks.",
            threadID: "thread-1",
            scope: scope
        )
        XCTAssertEqual(created.count, 1)

        try suggestionService.acceptSuggestion(id: try XCTUnwrap(created.first?.id))

        let suggestions = try suggestionService.suggestions(for: "thread-1")
        XCTAssertTrue(suggestions.isEmpty)

        let entries = try store.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            state: .active,
            limit: 10
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].provider, .codex)
        XCTAssertEqual(entries[0].metadata["memory_domain"], "assistant")
        XCTAssertEqual(entries[0].summary, "Avoid long step-by-step narration for simple tasks")

        let document = try threadMemoryService.loadTrackedDocument(for: "thread-1").document
        XCTAssertTrue(document.candidateLessons.isEmpty)
    }

    func testIgnoreSuggestionRemovesPendingLessonWithoutSaving() throws {
        let memoryRoot = try makeTemporaryDirectory(named: "assistant-memory")
        let databaseURL = try makeDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let threadMemoryService = AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: threadMemoryService,
            store: store
        )

        let scope = MemoryScopeContext(
            appName: "Open Assist",
            bundleID: "com.manikvashith.OpenAssist",
            surfaceLabel: "Assistant",
            projectName: nil,
            repositoryName: nil,
            identityKey: "assistant-session:thread-2",
            identityType: "assistant-session",
            identityLabel: "thread-2",
            scopeKey: "scope|assistant|thread-2",
            isCodingContext: false
        )

        let created = try suggestionService.createManualSuggestions(
            from: "Ask for missing permission earlier instead of spending time on workarounds.",
            threadID: "thread-2",
            scope: scope
        )
        XCTAssertEqual(created.count, 1)

        try suggestionService.ignoreSuggestion(id: try XCTUnwrap(created.first?.id))

        let entries = try store.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            state: .active,
            limit: 10
        )
        XCTAssertTrue(entries.isEmpty)

        let document = try threadMemoryService.loadTrackedDocument(for: "thread-2").document
        XCTAssertTrue(document.candidateLessons.isEmpty)
    }

    func testManualSuggestionsSkipTemporaryOneOffFacts() throws {
        let memoryRoot = try makeTemporaryDirectory(named: "assistant-memory")
        let databaseURL = try makeDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: AssistantThreadMemoryService(baseDirectoryURL: memoryRoot),
            store: store
        )

        let scope = MemoryScopeContext(
            appName: "Open Assist",
            bundleID: "com.manikvashith.OpenAssist",
            surfaceLabel: "Assistant",
            projectName: nil,
            repositoryName: nil,
            identityKey: "assistant-session:thread-3",
            identityType: "assistant-session",
            identityLabel: "thread-3",
            scopeKey: "scope|assistant|thread-3",
            isCodingContext: false
        )

        let created = try suggestionService.createManualSuggestions(
            from: """
            The front tab was x.com at 6:59 PM.
            Check whether Square is already open before starting a new login flow.
            """,
            threadID: "thread-3",
            scope: scope
        )

        XCTAssertEqual(created.count, 1)
        XCTAssertFalse(created[0].summary.lowercased().contains("x.com"))
    }

    func testAutomaticFailureSuggestionsSkipNormalCompletedAnswer() throws {
        let memoryRoot = try makeTemporaryDirectory(named: "assistant-memory")
        let databaseURL = try makeDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: AssistantThreadMemoryService(baseDirectoryURL: memoryRoot),
            store: store
        )

        let scope = MemoryScopeContext(
            appName: "Open Assist",
            bundleID: "com.manikvashith.OpenAssist",
            surfaceLabel: "Assistant",
            projectName: nil,
            repositoryName: nil,
            identityKey: "assistant-session:thread-4",
            identityType: "assistant-session",
            identityLabel: "thread-4",
            scopeKey: "scope|assistant|thread-4",
            isCodingContext: false
        )

        let created = try suggestionService.createAutomaticFailureSuggestions(
            from: """
            Yes — I checked now. Your Obsidian vault has updates. As of March 8, 2026, the files changed in the last 24 hours were Project memories/AssistantPlanCopilot.md and Personal Projects/OpenAssist/07 - Documentation/OpenAssist - GitHub Snapshot (Latest).md.
            """,
            toolCount: 7,
            threadID: "thread-4",
            scope: scope
        )

        XCTAssertTrue(created.isEmpty)
        XCTAssertTrue(try suggestionService.suggestions(for: "thread-4").isEmpty)
    }

    func testAutomaticFailureSuggestionsCaptureNoisyBrowserDetour() throws {
        let memoryRoot = try makeTemporaryDirectory(named: "assistant-memory")
        let databaseURL = try makeDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: AssistantThreadMemoryService(baseDirectoryURL: memoryRoot),
            store: store
        )

        let scope = MemoryScopeContext(
            appName: "Open Assist",
            bundleID: "com.manikvashith.OpenAssist",
            surfaceLabel: "Assistant",
            projectName: "OpenAssist",
            repositoryName: "OpenAssist",
            identityKey: "assistant-session:thread-5",
            identityType: "assistant-session",
            identityLabel: "thread-5",
            scopeKey: "scope|assistant|thread-5",
            isCodingContext: true
        )

        let created = try suggestionService.createAutomaticFailureSuggestions(
            from: """
            I'm trying the real browser flow now. First I'll open Brave and check whether I can drive Square there. Next I'm checking all open tabs. I found Brave is open, but the front tab is on x.com. Now I'm switching to another path and checking whether JavaScript from Apple Events is enabled. If it is blocked, I'm trying a workaround before I ask for permission.
            """,
            toolCount: 22,
            threadID: "thread-5",
            scope: scope
        )

        XCTAssertFalse(created.isEmpty)
        XCTAssertTrue(created.contains(where: { $0.summary.contains("keep updates short") }))
        XCTAssertTrue(created.contains(where: { $0.summary.contains("Apple Events") }))
    }

    func testSuggestionsSkipExistingLongTermAssistantLesson() throws {
        let memoryRoot = try makeTemporaryDirectory(named: "assistant-memory")
        let databaseURL = try makeDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: AssistantThreadMemoryService(baseDirectoryURL: memoryRoot),
            store: store
        )

        let scope = MemoryScopeContext(
            appName: "Open Assist",
            bundleID: "com.manikvashith.OpenAssist",
            surfaceLabel: "Assistant",
            projectName: "OpenAssist",
            repositoryName: "OpenAssist",
            identityKey: "assistant-session:thread-6",
            identityType: "assistant-session",
            identityLabel: "thread-6",
            scopeKey: "scope|assistant|thread-6",
            isCodingContext: true
        )

        try store.upsertAssistantMemoryEntry(
            AssistantMemoryEntry(
                provider: .codex,
                scopeKey: scope.scopeKey,
                bundleID: scope.bundleID,
                projectKey: scope.projectKey,
                identityKey: scope.identityKey,
                threadID: "thread-6",
                memoryType: .lesson,
                title: "Short updates",
                summary: "For simple requests, keep updates short and move to the answer faster instead of narrating every step.",
                detail: "For simple requests, keep updates short and move to the answer faster instead of narrating every step.",
                keywords: ["simple", "updates", "short"],
                confidence: 0.9,
                metadata: ["memory_domain": "assistant"]
            )
        )

        let created = try suggestionService.createManualSuggestions(
            from: "For simple requests, keep updates short and move to the answer faster instead of narrating every step.",
            threadID: "thread-6",
            scope: scope
        )

        XCTAssertTrue(created.isEmpty)
        XCTAssertTrue(try suggestionService.suggestions(for: "thread-6").isEmpty)
    }

    func testAcceptSuggestionDoesNotDuplicateExistingLongTermAssistantLesson() throws {
        let memoryRoot = try makeTemporaryDirectory(named: "assistant-memory")
        let databaseURL = try makeDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let threadMemoryService = AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: threadMemoryService,
            store: store
        )

        let scope = MemoryScopeContext(
            appName: "Open Assist",
            bundleID: "com.manikvashith.OpenAssist",
            surfaceLabel: "Assistant",
            projectName: "OpenAssist",
            repositoryName: "OpenAssist",
            identityKey: "assistant-session:thread-7",
            identityType: "assistant-session",
            identityLabel: "thread-7",
            scopeKey: "scope|assistant|thread-7",
            isCodingContext: true
        )

        let summary = "For simple requests, keep updates short and move to the answer faster instead of narrating every step."
        try store.upsertAssistantMemoryEntry(
            AssistantMemoryEntry(
                provider: .codex,
                scopeKey: scope.scopeKey,
                bundleID: scope.bundleID,
                projectKey: scope.projectKey,
                identityKey: scope.identityKey,
                threadID: "thread-7",
                memoryType: .lesson,
                title: "Short updates",
                summary: summary,
                detail: summary,
                keywords: ["simple", "updates", "short"],
                confidence: 0.9,
                metadata: ["memory_domain": "assistant"]
            )
        )

        let duplicateSuggestion = AssistantMemorySuggestion(
            threadID: "thread-7",
            kind: .reviewedFailure,
            memoryType: .lesson,
            title: "Short updates",
            summary: summary,
            detail: summary,
            scopeKey: scope.scopeKey,
            bundleID: scope.bundleID,
            projectKey: scope.projectKey,
            identityKey: scope.identityKey,
            keywords: ["simple", "updates", "short"],
            confidence: 0.76,
            sourceExcerpt: "Repeated assistant narration"
        )

        let suggestionsURL = memoryRoot.appendingPathComponent("pending-suggestions.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode([duplicateSuggestion]).write(to: suggestionsURL, options: .atomic)
        try threadMemoryService.addCandidateLesson(summary, for: "thread-7")

        try suggestionService.acceptSuggestion(id: duplicateSuggestion.id)

        let entries = try store.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            state: .active,
            limit: 10
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.summary, summary)
        XCTAssertTrue(try suggestionService.suggestions(for: "thread-7").isEmpty)
        XCTAssertTrue(try threadMemoryService.loadTrackedDocument(for: "thread-7").document.candidateLessons.isEmpty)
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
