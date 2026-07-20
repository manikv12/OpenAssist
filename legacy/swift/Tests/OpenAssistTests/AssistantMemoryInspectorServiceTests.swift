import Foundation
import XCTest
@testable import OpenAssist

final class AssistantMemoryInspectorServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testThreadSnapshotIncludesScratchpadThreadMemoryAndProjectMemory() throws {
        let projectDirectory = try makeTemporaryDirectory(named: "assistant-project-store")
        let memoryDirectory = try makeTemporaryDirectory(named: "assistant-thread-memory")
        let databaseURL = try makeDatabaseURL()

        let projectStore = AssistantProjectStore(baseDirectoryURL: projectDirectory)
        let threadMemoryService = AssistantThreadMemoryService(baseDirectoryURL: memoryDirectory)
        let memoryStore = try MemorySQLiteStore(databaseURL: databaseURL)
        let retrievalService = AssistantMemoryRetrievalService(
            store: memoryStore,
            threadMemoryService: threadMemoryService
        )
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: threadMemoryService,
            store: memoryStore
        )
        let projectMemoryService = AssistantProjectMemoryService(
            projectStore: projectStore,
            memoryStore: memoryStore,
            memorySuggestionService: suggestionService
        )
        let inspectorService = AssistantMemoryInspectorService(
            projectStore: projectStore,
            projectMemoryService: projectMemoryService,
            threadMemoryService: threadMemoryService,
            memoryRetrievalService: retrievalService,
            memorySuggestionService: suggestionService,
            memoryStore: memoryStore
        )

        let project = try projectStore.createProject(
            name: "Website App",
            linkedFolderPath: "/tmp/website-app"
        )
        try projectStore.assignThread("thread-1", toProjectID: project.id)
        try projectStore.updateThreadDigest(
            projectID: project.id,
            threadID: "thread-1",
            threadTitle: "Fix login",
            summary: "Assistant: Updated the login flow.",
            fingerprint: "digest-1"
        )
        try projectStore.setProjectSummary(
            "Project: Website App\nRecent thread digests:\n- Fix login: Updated the login flow.",
            forProjectID: project.id
        )

        let scratchpad = AssistantThreadMemoryDocument(
            currentTask: "Tighten the login flow",
            activeFacts: ["Auth now uses Clerk."],
            importantReferences: ["AuthService.swift"],
            sessionPreferences: ["Keep changes small."],
            staleNotes: ["Previous task: investigate SSO"],
            candidateLessons: ["Login redirects should be covered by a regression test."]
        )
        _ = try threadMemoryService.saveDocument(scratchpad, for: "thread-1")

        let threadScope = retrievalService.makeScopeContext(
            threadID: "thread-1",
            cwd: "/tmp/website-app"
        )
        try memoryStore.upsertAssistantMemoryEntry(
            AssistantMemoryEntry(
                scopeKey: threadScope.scopeKey,
                bundleID: threadScope.bundleID,
                projectKey: threadScope.projectKey,
                identityKey: threadScope.identityKey,
                threadID: "thread-1",
                memoryType: .lesson,
                title: "Login flow lesson",
                summary: "Check the redirect after auth changes.",
                detail: "Every login refactor should verify the final redirect path."
            )
        )

        let projectScope = projectMemoryService.projectScopeContext(
            for: project,
            cwd: project.linkedFolderPath
        )
        try memoryStore.upsertAssistantMemoryEntry(
            AssistantMemoryEntry(
                scopeKey: projectScope.scopeKey,
                bundleID: projectScope.bundleID,
                projectKey: projectScope.projectKey,
                identityKey: projectScope.identityKey,
                memoryType: .preference,
                title: "Package manager",
                summary: "Use pnpm in this repo.",
                detail: "Do not switch to npm for quick fixes.",
                metadata: ["project_id": project.id]
            )
        )

        try writeSuggestions(
            [
                AssistantMemorySuggestion(
                    threadID: "thread-1",
                    kind: .manualSave,
                    memoryType: .lesson,
                    title: "Login redirect review",
                    summary: "Re-check the redirect after auth changes.",
                    detail: "Make sure login still lands on the expected screen after auth refactors.",
                    scopeKey: threadScope.scopeKey,
                    bundleID: threadScope.bundleID,
                    projectKey: threadScope.projectKey,
                    identityKey: threadScope.identityKey,
                    metadata: ["project_id": project.id]
                )
            ],
            rootDirectory: threadMemoryService.rootDirectoryURL
        )

        let session = AssistantSessionSummary(
            id: "thread-1",
            title: "Fix login",
            source: .appServer,
            status: .completed,
            cwd: "/tmp/website-app",
            effectiveCWD: "/tmp/website-app",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_050),
            latestUserMessage: "Fix the login redirect bug",
            latestAssistantMessage: "I updated the auth flow and cleaned up the redirect.",
            projectID: project.id,
            projectName: project.name,
            linkedProjectFolderPath: project.linkedFolderPath
        )

        let snapshot = try inspectorService.snapshot(for: session)

        XCTAssertEqual(snapshot.kind, .thread)
        XCTAssertEqual(snapshot.title, "Fix login")
        XCTAssertEqual(snapshot.linkedFolderPath, "/tmp/website-app")
        XCTAssertEqual(snapshot.threadDocument?.currentTask, "Tighten the login flow")
        XCTAssertEqual(snapshot.threadActiveEntries.map(\.title), ["Login flow lesson"])
        XCTAssertEqual(snapshot.projectActiveEntries.map(\.title), ["Package manager"])
        XCTAssertTrue(snapshot.projectSummary?.contains("Website App") == true)
        XCTAssertGreaterThanOrEqual(snapshot.pendingSuggestions.count, 1)
        XCTAssertNotNil(snapshot.memoryFileURL)
    }

    func testProjectSnapshotIncludesDigestsProjectLessonsAndPendingSuggestions() throws {
        let projectDirectory = try makeTemporaryDirectory(named: "assistant-project-store")
        let memoryDirectory = try makeTemporaryDirectory(named: "assistant-thread-memory")
        let databaseURL = try makeDatabaseURL()

        let projectStore = AssistantProjectStore(baseDirectoryURL: projectDirectory)
        let threadMemoryService = AssistantThreadMemoryService(baseDirectoryURL: memoryDirectory)
        let memoryStore = try MemorySQLiteStore(databaseURL: databaseURL)
        let retrievalService = AssistantMemoryRetrievalService(
            store: memoryStore,
            threadMemoryService: threadMemoryService
        )
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: threadMemoryService,
            store: memoryStore
        )
        let projectMemoryService = AssistantProjectMemoryService(
            projectStore: projectStore,
            memoryStore: memoryStore,
            memorySuggestionService: suggestionService
        )
        let inspectorService = AssistantMemoryInspectorService(
            projectStore: projectStore,
            projectMemoryService: projectMemoryService,
            threadMemoryService: threadMemoryService,
            memoryRetrievalService: retrievalService,
            memorySuggestionService: suggestionService,
            memoryStore: memoryStore
        )

        let project = try projectStore.createProject(
            name: "Mac Client",
            linkedFolderPath: "/tmp/mac-client"
        )
        try projectStore.assignThread("thread-a", toProjectID: project.id)
        try projectStore.updateThreadDigest(
            projectID: project.id,
            threadID: "thread-a",
            threadTitle: "Refine sidebar",
            summary: "Assistant: Reduced sidebar spacing and added fold controls.",
            fingerprint: "sidebar-1",
            processedAt: Date(timeIntervalSince1970: 1_100)
        )
        try projectStore.setProjectSummary(
            "Project: Mac Client\nRecent thread digests:\n- Refine sidebar: Reduced spacing and added fold controls.",
            forProjectID: project.id,
            processedAt: Date(timeIntervalSince1970: 1_120)
        )

        let projectScope = projectMemoryService.projectScopeContext(
            for: project,
            cwd: project.linkedFolderPath
        )
        try memoryStore.upsertAssistantMemoryEntry(
            AssistantMemoryEntry(
                scopeKey: projectScope.scopeKey,
                bundleID: projectScope.bundleID,
                projectKey: projectScope.projectKey,
                identityKey: projectScope.identityKey,
                memoryType: .constraint,
                title: "Use SwiftUI",
                summary: "Keep sidebar changes in SwiftUI.",
                detail: "Avoid AppKit rewrites for this surface.",
                metadata: ["project_id": project.id]
            )
        )
        try memoryStore.upsertAssistantMemoryEntry(
            AssistantMemoryEntry(
                scopeKey: projectScope.scopeKey,
                bundleID: projectScope.bundleID,
                projectKey: projectScope.projectKey,
                identityKey: projectScope.identityKey,
                memoryType: .lesson,
                title: "Old sidebar rule",
                summary: "Previous spacing rule",
                detail: "Old spacing values kept rows too airy.",
                state: .invalidated,
                metadata: [
                    "project_id": project.id,
                    "invalidation_reason": "Spacing was tightened in a later change."
                ]
            )
        )

        try writeSuggestions(
            [
                AssistantMemorySuggestion(
                    threadID: "thread-a",
                    kind: .manualSave,
                    memoryType: .constraint,
                    title: "Sidebar stack",
                    summary: "Keep sidebar work in SwiftUI.",
                    detail: "Use the SwiftUI sidebar instead of replacing it with custom AppKit views.",
                    scopeKey: projectScope.scopeKey,
                    bundleID: projectScope.bundleID,
                    projectKey: projectScope.projectKey,
                    identityKey: projectScope.identityKey,
                    metadata: ["project_id": project.id]
                )
            ],
            rootDirectory: threadMemoryService.rootDirectoryURL
        )

        let sessions = [
            AssistantSessionSummary(
                id: "thread-a",
                title: "Refine sidebar",
                source: .appServer,
                status: .completed,
                cwd: "/tmp/mac-client",
                effectiveCWD: "/tmp/mac-client",
                createdAt: Date(timeIntervalSince1970: 1_000),
                updatedAt: Date(timeIntervalSince1970: 1_050),
                latestUserMessage: "Make the sidebar tighter",
                latestAssistantMessage: "I reduced the spacing and added section folding.",
                projectID: project.id,
                projectName: project.name,
                linkedProjectFolderPath: project.linkedFolderPath
            )
        ]

        let snapshot = try inspectorService.snapshot(for: project, sessions: sessions)

        XCTAssertEqual(snapshot.kind, .project)
        XCTAssertEqual(snapshot.title, "Mac Client")
        XCTAssertEqual(snapshot.linkedFolderPath, "/tmp/mac-client")
        XCTAssertEqual(snapshot.threadDigests.map(\.threadTitle), ["Refine sidebar"])
        XCTAssertEqual(snapshot.projectActiveEntries.map(\.title), ["Use SwiftUI"])
        XCTAssertEqual(snapshot.projectInvalidatedEntries.map(\.title), ["Old sidebar rule"])
        XCTAssertTrue(snapshot.projectSummary?.contains("Mac Client") == true)
        XCTAssertGreaterThanOrEqual(snapshot.pendingSuggestions.count, 1)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = try makeTemporaryDirectory(named: "assistant-memory-inspector-db")
        return directory.appendingPathComponent("memory.sqlite", isDirectory: false)
    }

    private func writeSuggestions(
        _ suggestions: [AssistantMemorySuggestion],
        rootDirectory: URL
    ) throws {
        let fileURL = rootDirectory.appendingPathComponent("pending-suggestions.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(suggestions)
        try data.write(to: fileURL, options: .atomic)
    }
}
