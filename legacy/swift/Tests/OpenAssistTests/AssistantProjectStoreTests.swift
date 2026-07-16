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

    func testFolderHierarchyRoundTripPersistsKindsAndParentIDs() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-folder-roundtrip")
        let store = AssistantProjectStore(baseDirectoryURL: directory)

        let folder = try store.createFolder(name: "Amwins")
        let childProject = try store.createProject(name: "NLS", parentID: folder.id)
        let rootProject = try store.createProject(name: "OpenAssist")

        let reloadedStore = AssistantProjectStore(baseDirectoryURL: directory)
        let reloadedFolder = try XCTUnwrap(reloadedStore.project(forProjectID: folder.id))
        let reloadedChild = try XCTUnwrap(reloadedStore.project(forProjectID: childProject.id))
        let reloadedRootProject = try XCTUnwrap(reloadedStore.project(forProjectID: rootProject.id))

        XCTAssertEqual(reloadedFolder.kind, .folder)
        XCTAssertNil(reloadedFolder.parentID)
        XCTAssertEqual(reloadedChild.kind, .project)
        XCTAssertEqual(reloadedChild.parentID, folder.id)
        XCTAssertEqual(reloadedRootProject.kind, .project)
        XCTAssertNil(reloadedRootProject.parentID)
        XCTAssertEqual(
            reloadedStore.descendantProjectIDs(ofFolderID: folder.id),
            Set([childProject.id])
        )
    }

    func testProjectNamesAreUniqueWithinSameParentButCanRepeatAcrossFolders() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-sibling-names")
        let store = AssistantProjectStore(baseDirectoryURL: directory)

        let folderA = try store.createFolder(name: "Amwins")
        let folderB = try store.createFolder(name: "Rapid")
        _ = try store.createProject(name: "NLS", parentID: folderA.id)
        _ = try store.createProject(name: "NLS", parentID: folderB.id)

        XCTAssertThrowsError(try store.createProject(name: "NLS", parentID: folderA.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }
        XCTAssertThrowsError(try store.createFolder(name: "amwins")) { error in
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }
    }

    func testAssignThreadRejectsFolders() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-folder-assignment")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let folder = try store.createFolder(name: "Amwins")

        XCTAssertThrowsError(try store.assignThread("thread-1", toProjectID: folder.id)) { error in
            guard let storeError = error as? AssistantProjectStoreError else {
                return XCTFail("Unexpected error type: \(error)")
            }
            if case .cannotAssignThreadToFolder = storeError {
                // expected
            } else {
                XCTFail("Expected cannotAssignThreadToFolder, got \(storeError)")
            }
        }
    }

    func testDeleteFolderMovesChildProjectsToRootAndKeepsAssignments() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-delete-folder")
        let store = AssistantProjectStore(baseDirectoryURL: directory)

        let folder = try store.createFolder(name: "Amwins")
        let project = try store.createProject(name: "NLS", parentID: folder.id)
        try store.assignThread("thread-1", toProjectID: project.id)

        let deletion = try store.deleteProjectResult(id: folder.id)

        XCTAssertEqual(deletion.project.id, folder.id)
        XCTAssertTrue(deletion.removedThreadIDs.isEmpty)
        XCTAssertNil(store.project(forProjectID: folder.id))

        let rehomedProject = try XCTUnwrap(store.project(forProjectID: project.id))
        XCTAssertNil(rehomedProject.parentID)
        XCTAssertEqual(store.assignedProjectID(forThreadID: "thread-1"), project.id)
        XCTAssertEqual(store.descendantProjectIDs(ofFolderID: folder.id), [])
    }

    func testDeleteFolderRejectsDuplicateRootNameWhenChildWouldMoveToTopLevel() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-delete-folder-duplicate")
        let store = AssistantProjectStore(baseDirectoryURL: directory)

        let folder = try store.createFolder(name: "Amwins")
        _ = try store.createProject(name: "NLS")
        let childProject = try store.createProject(name: "NLS", parentID: folder.id)

        XCTAssertThrowsError(try store.deleteProjectResult(id: folder.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }

        let unchangedChild = try XCTUnwrap(store.project(forProjectID: childProject.id))
        XCTAssertEqual(unchangedChild.parentID, folder.id)
    }

    func testHiddenFolderHidesChildrenButKeepsAssignments() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-hidden-folder")
        let store = AssistantProjectStore(baseDirectoryURL: directory)

        let folder = try store.createFolder(name: "Amwins")
        let project = try store.createProject(name: "NLS", parentID: folder.id)
        try store.assignThread("thread-1", toProjectID: project.id)

        _ = try store.hideProject(id: folder.id)

        XCTAssertEqual(store.visibleProjects().count, 0)
        XCTAssertEqual(store.hiddenProjects().map(\.id), [folder.id])
        XCTAssertEqual(store.assignedProjectID(forThreadID: "thread-1"), project.id)

        let reloadedStore = AssistantProjectStore(baseDirectoryURL: directory)
        XCTAssertEqual(reloadedStore.visibleProjects().count, 0)
        XCTAssertEqual(reloadedStore.assignedProjectID(forThreadID: "thread-1"), project.id)
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
        XCTAssertEqual(project.kind, .project)
        XCTAssertNil(project.parentID)
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

    func testProjectNotesRoundTripPersistsSelectionOrderingAndText() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-notes")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "OpenAssist")

        let emptyWorkspace = try store.loadProjectNotesWorkspace(projectID: project.id)
        XCTAssertTrue(emptyWorkspace.notes.isEmpty)
        XCTAssertNil(emptyWorkspace.selectedNote)

        let firstWorkspace = try store.createProjectNote(projectID: project.id, title: "Architecture")
        let firstNote = try XCTUnwrap(firstWorkspace.selectedNote)
        XCTAssertEqual(firstNote.title, "Architecture")

        let savedFirst = try store.saveProjectNote(
            projectID: project.id,
            noteID: firstNote.id,
            text: "Initial architecture note"
        )
        XCTAssertEqual(savedFirst.selectedNoteText, "Initial architecture note")

        let secondWorkspace = try store.createProjectNote(projectID: project.id, title: "Release Plan")
        let secondNote = try XCTUnwrap(secondWorkspace.selectedNote)
        XCTAssertEqual(secondWorkspace.notes.map(\.title), ["Architecture", "Release Plan"])

        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: secondNote.id,
            text: "Version 1 release plan"
        )

        let reselectedFirst = try store.selectProjectNote(projectID: project.id, noteID: firstNote.id)
        XCTAssertEqual(reselectedFirst.selectedNote?.id, firstNote.id)

        let appended = try store.appendToSelectedProjectNote(
            projectID: project.id,
            text: "Captured from chat"
        )
        XCTAssertEqual(
            appended.selectedNoteText,
            "Initial architecture note\n\nCaptured from chat"
        )

        let renamed = try store.renameProjectNote(
            projectID: project.id,
            noteID: secondNote.id,
            title: "Release Notes"
        )
        XCTAssertEqual(renamed.notes.map(\.title), ["Architecture", "Release Notes"])
        XCTAssertEqual(renamed.selectedNote?.id, firstNote.id)

        let reloadedStore = AssistantProjectStore(baseDirectoryURL: directory)
        let reloadedWorkspace = try reloadedStore.loadProjectNotesWorkspace(projectID: project.id)
        XCTAssertEqual(reloadedWorkspace.selectedNote?.id, firstNote.id)
        XCTAssertEqual(reloadedWorkspace.selectedNoteText, "Initial architecture note\n\nCaptured from chat")
        XCTAssertEqual(reloadedWorkspace.notes.map(\.title), ["Architecture", "Release Notes"])
    }

    func testSavingUnchangedProjectNoteDoesNotUpdateTimestampOrReorder() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-note-noop-save")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Stable Notes")

        let firstWorkspace = try store.createProjectNote(projectID: project.id, title: "First")
        let firstNote = try XCTUnwrap(firstWorkspace.selectedNote)
        let firstSavedAt = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: firstNote.id,
            text: "First body",
            now: firstSavedAt
        )

        let secondWorkspace = try store.createProjectNote(projectID: project.id, title: "Second")
        let secondNote = try XCTUnwrap(secondWorkspace.selectedNote)
        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: secondNote.id,
            text: "Second body",
            now: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let unchanged = try store.saveProjectNote(
            projectID: project.id,
            noteID: firstNote.id,
            text: "First body",
            now: Date(timeIntervalSince1970: 1_700_001_000)
        )

        XCTAssertEqual(unchanged.notes.map(\.id), [firstNote.id, secondNote.id])
        XCTAssertEqual(unchanged.selectedNote?.id, firstNote.id)
        XCTAssertEqual(
            unchanged.notes.first(where: { $0.id == firstNote.id })?.updatedAt,
            firstSavedAt
        )
    }

    func testSavingEmptyProjectNoteRemovesNoteFileAndDeleteProjectCleansProjectNotesDirectory() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-note-cleanup")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Cleanup Project")

        let createdWorkspace = try store.createProjectNote(projectID: project.id, title: "Scratchpad")
        let note = try XCTUnwrap(createdWorkspace.selectedNote)

        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "Temporary text"
        )

        let projectNotesDirectory = directory
            .appendingPathComponent("ProjectNotes", isDirectory: true)
            .appendingPathComponent(project.id.lowercased(), isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        let noteFileURL = projectNotesDirectory.appendingPathComponent(note.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteFileURL.path))

        _ = try store.saveProjectNote(projectID: project.id, noteID: note.id, text: "   ")
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteFileURL.path))

        let historyVersions = try store.projectNoteHistoryVersions(
            projectID: project.id,
            noteID: note.id
        )
        XCTAssertEqual(historyVersions.map(\.preview), ["Temporary text"])

        let restoredWorkspace = try store.restoreProjectNoteHistoryVersion(
            projectID: project.id,
            noteID: note.id,
            versionID: try XCTUnwrap(historyVersions.first?.id)
        )
        XCTAssertEqual(restoredWorkspace.selectedNoteText, "Temporary text")

        _ = try store.deleteProjectResult(id: project.id)

        let projectNoteOwnerDirectory = directory
            .appendingPathComponent("ProjectNotes", isDirectory: true)
            .appendingPathComponent(project.id.lowercased(), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectNoteOwnerDirectory.path))

        let projectRecoveryOwnerDirectory = directory
            .appendingPathComponent("ProjectNotesRecovery", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent("project", isDirectory: true)
            .appendingPathComponent(project.id.lowercased(), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectRecoveryOwnerDirectory.path))
    }

    func testProjectNoteHistorySkipsRapidSnapshotsAndPrunesToFourVersions() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-note-history")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Recovery Project")
        let createdWorkspace = try store.createProjectNote(projectID: project.id, title: "Architecture")
        let note = try XCTUnwrap(createdWorkspace.selectedNote)
        let baseDate = Date(timeIntervalSince1970: 1_000)

        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "v1",
            now: baseDate
        )
        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "v2",
            now: baseDate.addingTimeInterval(60)
        )
        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "v3",
            now: baseDate.addingTimeInterval(120)
        )
        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "v4",
            now: baseDate.addingTimeInterval(420)
        )
        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "v5",
            now: baseDate.addingTimeInterval(780)
        )
        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "v6",
            now: baseDate.addingTimeInterval(1_140)
        )
        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "v7",
            now: baseDate.addingTimeInterval(1_500)
        )

        let historyVersions = try store.projectNoteHistoryVersions(
            projectID: project.id,
            noteID: note.id
        )

        XCTAssertEqual(historyVersions.count, 4)
        XCTAssertEqual(historyVersions.map(\.preview), ["v6", "v5", "v4", "v3"])
    }

    func testDeletingProjectNoteMovesItToRecentlyDeletedAndRestoreWorks() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-note-delete-restore")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Restore Project")
        let createdWorkspace = try store.createProjectNote(projectID: project.id, title: "Runbook")
        let note = try XCTUnwrap(createdWorkspace.selectedNote)
        let baseDate = Date(timeIntervalSince1970: 5_000)

        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "Recovery text",
            now: baseDate
        )

        let deletedWorkspace = try store.deleteProjectNote(
            projectID: project.id,
            noteID: note.id,
            now: baseDate.addingTimeInterval(60)
        )
        XCTAssertTrue(deletedWorkspace.notes.isEmpty)

        let deletedNotes = try store.recentlyDeletedProjectNotes(
            projectID: project.id,
            referenceDate: baseDate.addingTimeInterval(120)
        )
        XCTAssertEqual(deletedNotes.count, 1)
        XCTAssertEqual(deletedNotes.first?.preview, "Recovery text")

        let restoredWorkspace = try store.restoreDeletedProjectNote(
            projectID: project.id,
            deletedNoteID: try XCTUnwrap(deletedNotes.first?.id),
            now: baseDate.addingTimeInterval(180)
        )
        XCTAssertEqual(restoredWorkspace.notes.count, 1)
        XCTAssertEqual(restoredWorkspace.selectedNoteText, "Recovery text")
        XCTAssertTrue(
            try store.recentlyDeletedProjectNotes(
                projectID: project.id,
                referenceDate: baseDate.addingTimeInterval(240)
            ).isEmpty
        )
    }

    func testProjectNoteImageAssetsRestoreWithDeletedNote() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-note-images")
        let fileManager = FileManager.default
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Image Project")
        let createdWorkspace = try store.createProjectNote(projectID: project.id, title: "Runbook")
        let note = try XCTUnwrap(createdWorkspace.selectedNote)
        let attachmentData = Data("fake-project-png".utf8)
        let attachment = AssistantAttachment(
            filename: "Architecture.webp",
            data: attachmentData,
            mimeType: "image/webp"
        )

        let savedAsset = try store.saveProjectNoteImageAsset(
            projectID: project.id,
            noteID: note.id,
            attachment: attachment
        )
        let assetDirectoryName = "\(URL(fileURLWithPath: note.fileName).deletingPathExtension().lastPathComponent).assets"
        XCTAssertTrue(savedAsset.relativePath.hasPrefix("./\(assetDirectoryName)/"))
        XCTAssertTrue(fileManager.fileExists(atPath: savedAsset.fileURL.path))
        XCTAssertEqual(
            try store.resolveProjectNoteImageAssetURL(
                projectID: project.id,
                noteID: note.id,
                relativePath: savedAsset.relativePath
            )?.path,
            savedAsset.fileURL.path
        )

        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "![Architecture](\(savedAsset.relativePath))"
        )

        _ = try store.deleteProjectNote(projectID: project.id, noteID: note.id)
        XCTAssertFalse(fileManager.fileExists(atPath: savedAsset.fileURL.path))

        let deletedSnapshot = try XCTUnwrap(
            store.recentlyDeletedProjectNotes(projectID: project.id).first
        )
        let restoredWorkspace = try store.restoreDeletedProjectNote(
            projectID: project.id,
            deletedNoteID: deletedSnapshot.id
        )
        let restoredNote = try XCTUnwrap(restoredWorkspace.selectedNote)
        let restoredAssetURL = try XCTUnwrap(
            store.resolveProjectNoteImageAssetURL(
                projectID: project.id,
                noteID: restoredNote.id,
                relativePath: savedAsset.relativePath
            )
        )

        XCTAssertEqual(restoredWorkspace.selectedNoteText, "![Architecture](\(savedAsset.relativePath))")
        XCTAssertTrue(fileManager.fileExists(atPath: restoredAssetURL.path))
        XCTAssertEqual(try Data(contentsOf: restoredAssetURL), attachmentData)
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

    func testProjectNoteFoldersRoundTripAndMoveNotesBetweenFoldersAndRoot() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-note-folders")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Notes")

        let planningWorkspace = try store.createProjectNoteFolder(
            projectID: project.id,
            name: "Planning"
        )
        let planningFolder = try XCTUnwrap(
            planningWorkspace.manifest.folders.first(where: { $0.name == "Planning" })
        )
        let q2Workspace = try store.createProjectNoteFolder(
            projectID: project.id,
            parentFolderID: planningFolder.id,
            name: "Q2"
        )
        let q2Folder = try XCTUnwrap(
            q2Workspace.manifest.folders.first(where: { $0.name == "Q2" })
        )

        let noteWorkspace = try store.createProjectNote(
            projectID: project.id,
            title: "Roadmap",
            folderID: q2Folder.id
        )
        let noteID = try XCTUnwrap(noteWorkspace.selectedNote?.id)

        let reloadedStore = AssistantProjectStore(baseDirectoryURL: directory)
        let reloadedFolders = try reloadedStore.projectNoteFolders(projectID: project.id)
        XCTAssertEqual(reloadedFolders.map(\.name), ["Planning", "Q2"])
        XCTAssertEqual(
            try reloadedStore.projectNoteFolderPathMap(projectID: project.id)[q2Folder.id],
            ["Planning", "Q2"]
        )
        XCTAssertEqual(
            try reloadedStore.loadProjectStoredNotes(projectID: project.id).first(where: {
                $0.noteID == noteID
            })?.folderID,
            q2Folder.id
        )

        _ = try reloadedStore.moveProjectNote(
            projectID: project.id,
            noteID: noteID,
            folderID: planningFolder.id
        )
        XCTAssertEqual(
            try reloadedStore.loadProjectStoredNotes(projectID: project.id).first(where: {
                $0.noteID == noteID
            })?.folderID,
            planningFolder.id
        )

        _ = try reloadedStore.moveProjectNote(
            projectID: project.id,
            noteID: noteID,
            folderID: nil
        )
        XCTAssertNil(
            try reloadedStore.loadProjectStoredNotes(projectID: project.id).first(where: {
                $0.noteID == noteID
            })?.folderID
        )
    }

    func testProjectNoteFolderPersistsEvenBeforeAnyNotesExist() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-note-folder-empty")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Notes")

        _ = try store.createProjectNoteFolder(projectID: project.id, name: "Planning")

        let reloadedStore = AssistantProjectStore(baseDirectoryURL: directory)
        XCTAssertEqual(
            try reloadedStore.projectNoteFolders(projectID: project.id).map(\.name),
            ["Planning"]
        )
        XCTAssertTrue(try reloadedStore.loadProjectStoredNotes(projectID: project.id).isEmpty)
    }

    func testProjectNoteFolderDeleteRejectsNonEmptyFolder() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-note-folder-delete")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Notes")

        let folderWorkspace = try store.createProjectNoteFolder(
            projectID: project.id,
            name: "Planning"
        )
        let folderID = try XCTUnwrap(folderWorkspace.manifest.folders.first?.id)
        _ = try store.createProjectNote(
            projectID: project.id,
            title: "Roadmap",
            folderID: folderID
        )

        XCTAssertThrowsError(
            try store.deleteProjectNoteFolder(projectID: project.id, folderID: folderID)
        ) { error in
            guard let storeError = error as? AssistantProjectStoreError else {
                return XCTFail("Unexpected error type: \(error)")
            }
            guard case .noteFolderNotEmpty = storeError else {
                return XCTFail("Expected noteFolderNotEmpty, got \(storeError)")
            }
        }
    }

    func testLegacyProjectNoteManifestMigrationKeepsNotesAtRoot() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-note-manifest-legacy")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Notes")

        let manifestDirectory = directory
            .appendingPathComponent("ProjectNotes", isDirectory: true)
            .appendingPathComponent(project.id, isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: manifestDirectory,
            withIntermediateDirectories: true
        )

        let createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 1_100)
        let legacyManifest: [String: Any] = [
            "version": 2,
            "selectedNoteID": "note-1",
            "notes": [[
                "id": "note-1",
                "title": "Legacy Note",
                "fileName": "note-1.md",
                "order": 0,
                "createdAt": createdAt.timeIntervalSinceReferenceDate,
                "updatedAt": updatedAt.timeIntervalSinceReferenceDate
            ]]
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: legacyManifest,
            options: [.sortedKeys, .prettyPrinted]
        )
        try manifestData.write(
            to: manifestDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        )

        let reloadedStore = AssistantProjectStore(baseDirectoryURL: directory)
        let workspace = try reloadedStore.loadProjectNotesWorkspace(projectID: project.id)
        XCTAssertTrue(workspace.manifest.folders.isEmpty)
        XCTAssertNil(workspace.manifest.notes.first?.folderID)
    }

    func testProjectNoteFoldersRejectDuplicateSiblingNamesAndCycles() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-project-note-folder-validation")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Notes")

        let parentWorkspace = try store.createProjectNoteFolder(
            projectID: project.id,
            name: "Planning"
        )
        let parentFolderID = try XCTUnwrap(parentWorkspace.manifest.folders.first?.id)
        let childWorkspace = try store.createProjectNoteFolder(
            projectID: project.id,
            parentFolderID: parentFolderID,
            name: "Q2"
        )
        let childFolderID = try XCTUnwrap(
            childWorkspace.manifest.folders.first(where: { $0.name == "Q2" })?.id
        )

        XCTAssertThrowsError(
            try store.createProjectNoteFolder(projectID: project.id, name: "planning")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }

        XCTAssertThrowsError(
            try store.moveProjectNoteFolder(
                projectID: project.id,
                folderID: parentFolderID,
                parentFolderID: childFolderID
            )
        ) { error in
            guard let storeError = error as? AssistantProjectStoreError else {
                return XCTFail("Unexpected error type: \(error)")
            }
            guard case .cannotMoveNoteFolderIntoDescendant = storeError else {
                return XCTFail("Expected cannotMoveNoteFolderIntoDescendant, got \(storeError)")
            }
        }
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    // MARK: - Save-reliability regression tests (issue: notes sometimes
    // lost content after the UI said "saved"). These assert the invariant
    // that once `saveProjectNote` returns without throwing, the written
    // text survives a fresh `AssistantProjectStore` load from the same
    // directory.

    func testRapidSequentialSavesPersistTheLatestText() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-rapid-saves")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Rapid")
        let createdWorkspace = try store.createProjectNote(projectID: project.id, title: "Log")
        let note = try XCTUnwrap(createdWorkspace.selectedNote)

        let snapshots = [
            "Version 1",
            "Version 1 with more content",
            "Version 1 with more content\n\nAnd a final paragraph.",
        ]

        for text in snapshots {
            _ = try store.saveProjectNote(
                projectID: project.id,
                noteID: note.id,
                text: text
            )
        }

        // In-memory state must match the last write.
        let loaded = try store.loadProjectNotesWorkspace(projectID: project.id)
        XCTAssertEqual(loaded.selectedNoteText, snapshots.last)

        // A fresh store (simulating app restart) must also see the last
        // write — not a stale snapshot from before the last save.
        let reloaded = AssistantProjectStore(baseDirectoryURL: directory)
        let reloadedWorkspace = try reloaded.loadProjectNotesWorkspace(projectID: project.id)
        XCTAssertEqual(reloadedWorkspace.selectedNoteText, snapshots.last)
    }

    func testSaveNonEmptyAfterClearRoundTripsThroughDiskCorrectly() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-save-after-clear")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Round trip")
        let createdWorkspace = try store.createProjectNote(projectID: project.id, title: "Log")
        let note = try XCTUnwrap(createdWorkspace.selectedNote)

        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "First"
        )
        // Empty save (without force) intentionally keeps prior content
        // — this is a safety guard we documented in the save pipeline.
        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: ""
        )
        // The follow-up non-empty save must replace the content, not be
        // shadowed by the ignored empty save.
        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "Replacement"
        )

        let reloaded = AssistantProjectStore(baseDirectoryURL: directory)
        let workspace = try reloaded.loadProjectNotesWorkspace(projectID: project.id)
        XCTAssertEqual(workspace.selectedNoteText, "Replacement")
    }

    /// Regression test for the specific user-reported bug:
    /// "I delete a line, the save indicator fires, but when I navigate
    /// away and come back the deleted line is still there."
    ///
    /// The root cause was `applyThreadNoteWorkspace` in the UI layer
    /// overwriting the in-memory draft cache with whatever the latest
    /// workspace snapshot said — even when that snapshot was stale
    /// relative to the user's in-flight edit. This test exercises the
    /// store directly; the UI-layer fix is asserted separately via
    /// `AssistantThreadNoteDraftPreservationTests` below.
    func testLaterSaveOverwritesEarlierSaveAndSurvivesStoreReload() throws {
        let directory = try makeTemporaryDirectory(named: "assistant-save-overwrite")
        let store = AssistantProjectStore(baseDirectoryURL: directory)
        let project = try store.createProject(name: "Overwrite")
        let createdWorkspace = try store.createProjectNote(projectID: project.id, title: "Log")
        let note = try XCTUnwrap(createdWorkspace.selectedNote)

        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "Line one\nLine two"
        )
        // User deletes "Line two" and saves again.
        _ = try store.saveProjectNote(
            projectID: project.id,
            noteID: note.id,
            text: "Line one"
        )

        // Simulate relaunch / sidebar-navigation-reload.
        let reloaded = AssistantProjectStore(baseDirectoryURL: directory)
        let workspace = try reloaded.loadProjectNotesWorkspace(projectID: project.id)
        XCTAssertEqual(workspace.selectedNoteText, "Line one")
    }
}
