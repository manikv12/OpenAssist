import Foundation
import XCTest
@testable import OpenAssist

final class AssistantProjectMemoryServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testProcessCheckpointBuildsDigestAndSkipsUnchangedCheckpoint() throws {
        let projectDirectory = try makeTemporaryDirectory(named: "assistant-projects")
        let memoryRoot = try makeTemporaryDirectory(named: "assistant-thread-memory")
        let databaseURL = try makeDatabaseURL()

        let projectStore = AssistantProjectStore(baseDirectoryURL: projectDirectory)
        let memoryStore = try MemorySQLiteStore(databaseURL: databaseURL)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: AssistantThreadMemoryService(baseDirectoryURL: memoryRoot),
            store: memoryStore
        )
        let service = AssistantProjectMemoryService(
            projectStore: projectStore,
            memoryStore: memoryStore,
            memorySuggestionService: suggestionService
        )

        let project = try projectStore.createProject(
            name: "Website App",
            linkedFolderPath: "/tmp/website-app"
        )
        try projectStore.assignThread("thread-1", toProjectID: project.id)

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
            latestAssistantMessage: "I updated the auth flow and removed the broken redirect.",
            projectID: project.id,
            projectName: project.name,
            linkedProjectFolderPath: "/tmp/website-app"
        )
        let transcript = [
            AssistantTranscriptEntry(
                role: .user,
                text: "Fix the login redirect bug",
                createdAt: Date(timeIntervalSince1970: 1_010)
            ),
            AssistantTranscriptEntry(
                role: .assistant,
                text: "I updated the auth flow and removed the broken redirect.",
                createdAt: Date(timeIntervalSince1970: 1_040)
            )
        ]

        let first = try service.processCheckpoint(
            session: session,
            transcript: transcript,
            timeline: []
        )
        XCTAssertTrue(first.didChange)

        let brain = projectStore.brainState(forProjectID: project.id)
        XCTAssertEqual(brain.threadDigestsByThreadID.count, 1)
        XCTAssertTrue(brain.projectSummary?.contains("Website App") == true)
        XCTAssertTrue(brain.projectSummary?.contains("Fix login") == true)

        let second = try service.processCheckpoint(
            session: session,
            transcript: transcript,
            timeline: []
        )
        XCTAssertFalse(second.didChange)
    }

    func testTurnContextUsesStableProjectIdentityAndSummary() throws {
        let projectDirectory = try makeTemporaryDirectory(named: "assistant-project-context")
        let memoryRoot = try makeTemporaryDirectory(named: "assistant-thread-memory")
        let databaseURL = try makeDatabaseURL()

        let projectStore = AssistantProjectStore(baseDirectoryURL: projectDirectory)
        let memoryStore = try MemorySQLiteStore(databaseURL: databaseURL)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: AssistantThreadMemoryService(baseDirectoryURL: memoryRoot),
            store: memoryStore
        )
        let service = AssistantProjectMemoryService(
            projectStore: projectStore,
            memoryStore: memoryStore,
            memorySuggestionService: suggestionService
        )

        let project = try projectStore.createProject(name: "Mac Client", linkedFolderPath: "/tmp/mac-client")
        try projectStore.assignThread("thread-7", toProjectID: project.id)
        try projectStore.updateThreadDigest(
            projectID: project.id,
            threadID: "thread-7",
            threadTitle: "Refine sidebar",
            summary: "Assistant: Added a project sidebar.",
            fingerprint: "sidebar-1"
        )
        try projectStore.setProjectSummary(
            "Project: Mac Client\nRecent thread digests:\n- Refine sidebar: Added a project sidebar.",
            forProjectID: project.id
        )

        let context = try XCTUnwrap(
            service.turnContext(
                forThreadID: "thread-7",
                fallbackCWD: "/tmp/mac-client"
            )
        )

        XCTAssertEqual(context.scope.identityKey, "assistant-project:\(project.id.lowercased())")
        XCTAssertEqual(context.scope.identityType, "assistant-project")
        XCTAssertEqual(context.scope.projectName, "Mac Client")
        XCTAssertTrue(context.projectContextBlock?.contains("Project memory summary") == true)
        XCTAssertTrue(context.projectContextBlock?.contains("Mac Client") == true)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = try makeTemporaryDirectory(named: "assistant-project-memory-db")
        return directory.appendingPathComponent("memory.sqlite", isDirectory: false)
    }
}
