import Foundation
import XCTest
@testable import OpenAssist

final class AssistantProjectStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testProjectStoreRoundTripPersistsProjectsAssignmentsAndBrainState() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-store")
        let store = AssistantProjectStore(baseDirectoryURL: directory)

        let project = try store.createProject(
            name: "Website App",
            linkedFolderPath: "/tmp/website-app"
        )
        try store.assignThread("thread-1", toProjectID: project.id)
        try store.updateThreadDigest(
            projectID: project.id,
            threadID: "thread-1",
            threadTitle: "Fix login",
            summary: "User: Fix login\nAssistant: Updated the auth flow.",
            fingerprint: "fingerprint-1",
            processedAt: Date(timeIntervalSince1970: 1_000)
        )
        try store.setProjectSummary(
            "Project: Website App\nRecent thread digests:\n- Fix login: Updated the auth flow.",
            forProjectID: project.id,
            processedAt: Date(timeIntervalSince1970: 1_100)
        )

        let reloadedStore = AssistantProjectStore(baseDirectoryURL: directory)
        XCTAssertEqual(reloadedStore.projects().count, 1)
        XCTAssertEqual(reloadedStore.assignedProjectID(forThreadID: "thread-1"), project.id)

        let context = try XCTUnwrap(reloadedStore.context(forThreadID: "thread-1"))
        XCTAssertEqual(context.project.name, "Website App")
        XCTAssertEqual(context.project.linkedFolderPath, "/tmp/website-app")
        XCTAssertEqual(
            context.brainState.threadDigestsByThreadID["thread-1"]?.threadTitle,
            "Fix login"
        )
        XCTAssertEqual(
            context.brainState.lastProcessedTranscriptFingerprintByThreadID["thread-1"],
            "fingerprint-1"
        )
        XCTAssertTrue(context.brainState.projectSummary?.contains("Website App") == true)
    }

    func testProjectIconRoundTripPersistsCustomIcon() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-icon")
        let store = AssistantProjectStore(baseDirectoryURL: directory)

        let project = try store.createProject(name: "Notes")
        _ = try store.setIconSymbol("briefcase.fill", forProjectID: project.id)

        let reloadedStore = AssistantProjectStore(baseDirectoryURL: directory)
        let reloadedProject = try XCTUnwrap(reloadedStore.project(forProjectID: project.id))
        XCTAssertEqual(reloadedProject.iconSymbolName, "briefcase.fill")
        XCTAssertEqual(reloadedProject.displayIconSymbolName, "briefcase.fill")
    }

    func testProjectIconFallsBackToFolderOrStackWhenNoCustomIconIsSet() {
        let unlinkedProject = AssistantProject(name: "Notes")
        XCTAssertEqual(unlinkedProject.displayIconSymbolName, "square.stack.3d.up.fill")

        let linkedProject = AssistantProject(name: "Notes", linkedFolderPath: "/tmp/notes")
        XCTAssertEqual(linkedProject.displayIconSymbolName, "folder.fill")
    }

    func testDeleteProjectClearsAssignmentsAndReturnsRemovedThreads() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-delete")
        let store = AssistantProjectStore(baseDirectoryURL: directory)

        let project = try store.createProject(name: "iOS App")
        try store.assignThread("thread-a", toProjectID: project.id)
        try store.assignThread("thread-b", toProjectID: project.id)
        try store.updateThreadDigest(
            projectID: project.id,
            threadID: "thread-a",
            threadTitle: "Fix build",
            summary: "Assistant: Updated signing settings.",
            fingerprint: "digest-a"
        )

        let deletion = try store.deleteProjectResult(id: project.id)

        XCTAssertEqual(deletion.project.id, project.id)
        XCTAssertEqual(Set(deletion.removedThreadIDs), Set(["thread-a", "thread-b"]))
        XCTAssertNil(store.project(forProjectID: project.id))
        XCTAssertNil(store.assignedProjectID(forThreadID: "thread-a"))
        XCTAssertNil(store.assignedProjectID(forThreadID: "thread-b"))
        XCTAssertNil(store.brainState(forProjectID: project.id).projectSummary)
        XCTAssertTrue(store.brainState(forProjectID: project.id).threadDigestsByThreadID.isEmpty)
    }

    func testProjectNamesAreCaseInsensitiveUnique() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-name")
        let store = AssistantProjectStore(baseDirectoryURL: directory)

        _ = try store.createProject(name: "OpenAssist")

        XCTAssertThrowsError(try store.createProject(name: "openassist")) { error in
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
