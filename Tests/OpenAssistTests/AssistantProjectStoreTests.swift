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

    func testSuggestedProjectNameUsesLinkedFolderName() {
        XCTAssertEqual(
            AssistantProject.suggestedName(forLinkedFolderPath: "/tmp/OpenAssist"),
            "OpenAssist"
        )
    }

    func testSuggestedProjectNameFallsBackWhenFolderPathIsMissing() {
        XCTAssertEqual(
            AssistantProject.suggestedName(forLinkedFolderPath: "   "),
            "Project"
        )
    }

    func testHiddenProjectRoundTripKeepsAssignmentsAndBrainState() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-hidden")
        let store = AssistantProjectStore(baseDirectoryURL: directory)

        let project = try store.createProject(name: "Research")
        try store.assignThread("thread-1", toProjectID: project.id)
        try store.updateThreadDigest(
            projectID: project.id,
            threadID: "thread-1",
            threadTitle: "Gather notes",
            summary: "Assistant: Captured the latest notes.",
            fingerprint: "fingerprint-1",
            processedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )

        _ = try store.hideProject(id: project.id)

        let hiddenProject = try XCTUnwrap(store.project(forProjectID: project.id))
        XCTAssertTrue(hiddenProject.isHidden)
        XCTAssertEqual(store.assignedProjectID(forThreadID: "thread-1"), project.id)
        XCTAssertEqual(store.visibleProjects().count, 0)
        XCTAssertEqual(store.hiddenProjects().count, 1)

        let hiddenContext = try XCTUnwrap(store.context(forThreadID: "thread-1"))
        XCTAssertEqual(hiddenContext.project.id, project.id)
        XCTAssertTrue(hiddenContext.project.isHidden)
        XCTAssertEqual(hiddenContext.brainState.threadDigestsByThreadID["thread-1"]?.threadTitle, "Gather notes")

        let reloadedStore = AssistantProjectStore(baseDirectoryURL: directory)
        let reloadedProject = try XCTUnwrap(reloadedStore.project(forProjectID: project.id))
        XCTAssertTrue(reloadedProject.isHidden)
        XCTAssertEqual(reloadedStore.assignedProjectID(forThreadID: "thread-1"), project.id)

        _ = try reloadedStore.unhideProject(id: project.id)
        let unhiddenProject = try XCTUnwrap(reloadedStore.project(forProjectID: project.id))
        XCTAssertFalse(unhiddenProject.isHidden)
        XCTAssertEqual(reloadedStore.visibleProjects().count, 1)
        XCTAssertEqual(reloadedStore.hiddenProjects().count, 0)
    }

    func testCreateProjectWithSameLinkedFolderReusesExistingProjectAndUnhidesIt() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-shared-folder")
        let store = AssistantProjectStore(baseDirectoryURL: directory)

        let original = try store.createProject(
            name: "Workspace",
            linkedFolderPath: "/tmp/shared-workspace"
        )
        _ = try store.hideProject(id: original.id)

        let reused = try store.createProject(
            name: "Another Name",
            linkedFolderPath: "/tmp/shared-workspace"
        )

        XCTAssertEqual(reused.id, original.id)
        XCTAssertEqual(store.projects().count, 1)
        XCTAssertFalse(try XCTUnwrap(store.project(forProjectID: original.id)).isHidden)
    }

    func testLegacyProjectSnapshotWithoutHiddenFlagDefaultsToVisible() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-legacy")
        let fileURL = directory.appendingPathComponent("projects.json")

        let createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 1_100)
        let legacySnapshot: [String: Any] = [
            "version": 2,
            "projects": [[
                "id": "project-legacy",
                "name": "Legacy Project",
                "linkedFolderPath": "/tmp/legacy",
                "iconSymbolName": "briefcase.fill",
                "createdAt": createdAt.timeIntervalSinceReferenceDate,
                "updatedAt": updatedAt.timeIntervalSinceReferenceDate
            ]],
            "threadAssignments": [
                "thread-legacy": "project-legacy"
            ],
            "brainByProjectID": [
                "project-legacy": [
                    "projectSummary": "Legacy summary",
                    "threadDigestsByThreadID": [:],
                    "lastProcessedTranscriptFingerprintByThreadID": [:]
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: legacySnapshot, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: fileURL)

        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try XCTUnwrap(store.project(forProjectID: "project-legacy"))
        XCTAssertFalse(project.isHidden)
        XCTAssertEqual(store.visibleProjects().count, 1)
        XCTAssertEqual(store.hiddenProjects().count, 0)

        let context = try XCTUnwrap(store.context(forThreadID: "thread-legacy"))
        XCTAssertEqual(context.project.name, "Legacy Project")
        XCTAssertFalse(context.project.isHidden)
        XCTAssertEqual(context.brainState.projectSummary, "Legacy summary")
    }

    func testReloadMergesDuplicateProjectsThatShareLinkedFolder() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-duplicate-folder")
        let fileURL = directory.appendingPathComponent("projects.json")

        let createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 1_200)
        let duplicateSnapshot: [String: Any] = [
            "version": 3,
            "projects": [
                [
                    "id": "project-visible",
                    "name": "Visible Project",
                    "linkedFolderPath": "/tmp/shared-folder",
                    "createdAt": createdAt.timeIntervalSinceReferenceDate,
                    "updatedAt": updatedAt.timeIntervalSinceReferenceDate,
                    "isHidden": false
                ],
                [
                    "id": "project-hidden",
                    "name": "Hidden Duplicate",
                    "linkedFolderPath": "/tmp/shared-folder",
                    "iconSymbolName": "briefcase.fill",
                    "createdAt": createdAt.addingTimeInterval(20).timeIntervalSinceReferenceDate,
                    "updatedAt": updatedAt.addingTimeInterval(20).timeIntervalSinceReferenceDate,
                    "isHidden": true
                ]
            ],
            "threadAssignments": [
                "thread-visible": "project-visible",
                "thread-hidden": "project-hidden"
            ],
            "brainByProjectID": [
                "project-visible": [
                    "projectSummary": "Visible summary",
                    "threadDigestsByThreadID": [
                        "thread-visible": [
                            "threadID": "thread-visible",
                            "threadTitle": "Visible Thread",
                            "summary": "Visible digest",
                            "updatedAt": updatedAt.timeIntervalSinceReferenceDate
                        ]
                    ],
                    "lastProcessedTranscriptFingerprintByThreadID": [
                        "thread-visible": "visible-fingerprint"
                    ],
                    "lastProcessedAt": updatedAt.timeIntervalSinceReferenceDate
                ],
                "project-hidden": [
                    "projectSummary": "Hidden summary",
                    "threadDigestsByThreadID": [
                        "thread-hidden": [
                            "threadID": "thread-hidden",
                            "threadTitle": "Hidden Thread",
                            "summary": "Hidden digest",
                            "updatedAt": updatedAt.addingTimeInterval(10).timeIntervalSinceReferenceDate
                        ]
                    ],
                    "lastProcessedTranscriptFingerprintByThreadID": [
                        "thread-hidden": "hidden-fingerprint"
                    ],
                    "lastProcessedAt": updatedAt.addingTimeInterval(10).timeIntervalSinceReferenceDate
                ]
            ]
        ]

        let data = try JSONSerialization.data(
            withJSONObject: duplicateSnapshot,
            options: [.sortedKeys, .prettyPrinted]
        )
        try data.write(to: fileURL)

        let store = AssistantProjectStore(baseDirectoryURL: directory)
        XCTAssertEqual(store.projects().count, 1)

        let mergedProject = try XCTUnwrap(store.project(forProjectID: "project-visible"))
        XCTAssertFalse(mergedProject.isHidden)
        XCTAssertEqual(mergedProject.iconSymbolName, "briefcase.fill")
        XCTAssertEqual(store.assignedProjectID(forThreadID: "thread-visible"), "project-visible")
        XCTAssertEqual(store.assignedProjectID(forThreadID: "thread-hidden"), "project-visible")

        let mergedBrain = store.brainState(forProjectID: "project-visible")
        XCTAssertEqual(mergedBrain.projectSummary, "Visible summary")
        XCTAssertEqual(mergedBrain.threadDigestsByThreadID["thread-visible"]?.threadTitle, "Visible Thread")
        XCTAssertEqual(mergedBrain.threadDigestsByThreadID["thread-hidden"]?.threadTitle, "Hidden Thread")
        XCTAssertEqual(
            mergedBrain.lastProcessedTranscriptFingerprintByThreadID["thread-hidden"],
            "hidden-fingerprint"
        )
        XCTAssertNil(store.project(forProjectID: "project-hidden"))
    }

    func testReloadMergesDuplicateProjectsThatShareLinkedFolderIgnoringCase() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-duplicate-folder-case")
        let fileURL = directory.appendingPathComponent("projects.json")

        let createdAt = Date(timeIntervalSinceReferenceDate: 2_000)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 2_100)
        let duplicateSnapshot: [String: Any] = [
            "version": 3,
            "projects": [
                [
                    "id": "project-upper",
                    "name": "Upper Case",
                    "linkedFolderPath": "/tmp/Shared-Folder",
                    "createdAt": createdAt.timeIntervalSinceReferenceDate,
                    "updatedAt": updatedAt.timeIntervalSinceReferenceDate,
                    "isHidden": false
                ],
                [
                    "id": "project-lower",
                    "name": "Lower Case",
                    "linkedFolderPath": "/tmp/shared-folder",
                    "createdAt": createdAt.addingTimeInterval(20).timeIntervalSinceReferenceDate,
                    "updatedAt": updatedAt.addingTimeInterval(20).timeIntervalSinceReferenceDate,
                    "isHidden": true
                ]
            ],
            "threadAssignments": [
                "thread-upper": "project-upper",
                "thread-lower": "project-lower"
            ],
            "brainByProjectID": [:]
        ]

        let data = try JSONSerialization.data(
            withJSONObject: duplicateSnapshot,
            options: [.sortedKeys, .prettyPrinted]
        )
        try data.write(to: fileURL)

        let store = AssistantProjectStore(baseDirectoryURL: directory)
        XCTAssertEqual(store.projects().count, 1)
        XCTAssertEqual(store.assignedProjectID(forThreadID: "thread-upper"), "project-upper")
        XCTAssertEqual(store.assignedProjectID(forThreadID: "thread-lower"), "project-upper")
        XCTAssertNil(store.project(forProjectID: "project-lower"))
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

    func testAssignThreadRejectsMissingThreadID() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-thread-id")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Notes")

        XCTAssertThrowsError(try store.assignThread("   ", toProjectID: project.id)) { error in
            guard let storeError = error as? AssistantProjectStoreError else {
                return XCTFail("Unexpected error type: \(error)")
            }
            if case .invalidThreadID = storeError {
                // expected
            } else {
                XCTFail("Expected invalidThreadID, got \(storeError)")
            }
            XCTAssertEqual(storeError.localizedDescription, "Enter a thread ID first.")
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
