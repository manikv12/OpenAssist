import XCTest
@testable import OpenAssist

private struct StubAssistantNotesAIProvider: AssistantNotesToolAIProviding {
    var placementResult: AssistantNotesPlacementResult = .success(
        ProjectNoteTransferSuggestion(
            headingPath: nil,
            insertedMarkdown: "Stub content",
            reason: "Stub placement."
        )
    )
    var organizeResult: AssistantNotesOrganizeResult = .success("# Organized\n\nStub")

    func suggestPlacement(
        content _: String,
        sourceLabel _: String,
        targetNoteTitle _: String,
        targetNoteText _: String,
        targetHeadingOutline _: String
    ) async -> AssistantNotesPlacementResult {
        placementResult
    }

    func organizeNote(
        noteText _: String,
        selectedText _: String?
    ) async -> AssistantNotesOrganizeResult {
        organizeResult
    }
}

@MainActor
final class AssistantNotesToolServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testListNotesUsesCurrentProjectScopeAndExcludesOtherProjects() async throws {
        let fixture = try makeFixture()
        let projectA = try fixture.projectStore.createProject(name: "Project A")
        let projectB = try fixture.projectStore.createProject(name: "Project B")

        try fixture.projectStore.assignThread("thread-1", toProjectID: projectA.id)
        try fixture.projectStore.assignThread("thread-2", toProjectID: projectA.id)
        try fixture.projectStore.assignThread("thread-3", toProjectID: projectB.id)

        _ = try createProjectNote(
            projectID: projectA.id,
            title: "Master",
            text: "# Project A Master\n\nOverview",
            noteType: .master,
            store: fixture.projectStore
        )
        _ = try createThreadNote(
            threadID: "thread-1",
            title: "Thread One",
            text: "Thread one note",
            store: fixture.conversationStore
        )
        _ = try createThreadNote(
            threadID: "thread-2",
            title: "Thread Two",
            text: "Thread two note",
            store: fixture.conversationStore
        )
        _ = try createProjectNote(
            projectID: projectB.id,
            title: "Other Project",
            text: "Should not appear",
            store: fixture.projectStore
        )
        _ = try createThreadNote(
            threadID: "thread-3",
            title: "Other Thread",
            text: "Should not appear",
            store: fixture.conversationStore
        )

        let result = await fixture.service.run(
            arguments: ["action": "list_notes"],
            sessionID: "thread-1",
            runtimeContext: nil,
            preferredModelID: nil,
            interactionMode: .plan
        )

        XCTAssertTrue(result.success)
        let response: AssistantNotesToolService.ListResponse = try decodeResult(result)
        XCTAssertEqual(response.noteCount, 3)
        XCTAssertEqual(
            Set(response.notes.map(\.title)),
            Set(["Master", "Thread One", "Thread Two"])
        )
    }

    func testPrepareAddUsesStrongExistingMatch() async throws {
        let fixture = try makeFixture()
        let project = try fixture.projectStore.createProject(name: "Docs")
        try fixture.projectStore.assignThread("thread-1", toProjectID: project.id)

        let onboarding = try createProjectNote(
            projectID: project.id,
            title: "Onboarding",
            text: "# Onboarding\n\n## Checklist\n\nExisting item",
            store: fixture.projectStore
        )
        _ = try createProjectNote(
            projectID: project.id,
            title: "Release Notes",
            text: "# Release Notes\n\nNothing here",
            store: fixture.projectStore
        )

        let result = await fixture.service.run(
            arguments: [
                "action": "prepare_add",
                "query": "onboarding",
                "content": "- Add buddy system"
            ],
            sessionID: "thread-1",
            runtimeContext: nil,
            preferredModelID: nil,
            interactionMode: .plan
        )

        XCTAssertTrue(result.success)
        let response: AssistantNotesToolService.PreparedChangeResponse = try decodeResult(result)
        XCTAssertFalse(response.target.isNewNote)
        XCTAssertEqual(response.target.noteID, onboarding.noteID)
        XCTAssertEqual(response.target.ownerKind, AssistantNoteOwnerKind.project.rawValue)
    }

    func testPrepareAddCreatesNewProjectNoteWhenMatchIsUnclear() async throws {
        let fixture = try makeFixture()
        let project = try fixture.projectStore.createProject(name: "Docs")
        try fixture.projectStore.assignThread("thread-1", toProjectID: project.id)

        _ = try createProjectNote(
            projectID: project.id,
            title: "Onboarding",
            text: "# Onboarding\n\nExisting",
            store: fixture.projectStore
        )
        _ = try createProjectNote(
            projectID: project.id,
            title: "Release Notes",
            text: "# Release\n\nExisting",
            store: fixture.projectStore
        )

        let result = await fixture.service.run(
            arguments: [
                "action": "prepare_add",
                "query": "Quarterly budget review",
                "content": "Budget decisions for the next quarter."
            ],
            sessionID: "thread-1",
            runtimeContext: nil,
            preferredModelID: nil,
            interactionMode: .plan
        )

        XCTAssertTrue(result.success)
        let response: AssistantNotesToolService.PreparedChangeResponse = try decodeResult(result)
        XCTAssertTrue(response.target.isNewNote)
        XCTAssertEqual(response.target.ownerKind, AssistantNoteOwnerKind.project.rawValue)
        XCTAssertNil(response.target.noteID)
    }

    func testPrepareAddReturnsPlacementPreviewWithoutSaving() async throws {
        let fixture = try makeFixture(
            aiProvider: StubAssistantNotesAIProvider(
                placementResult: .success(
                    ProjectNoteTransferSuggestion(
                        headingPath: ["Overview", "Details"],
                        insertedMarkdown: "- Added detail",
                        reason: "Details is the best section."
                    )
                ),
                organizeResult: .success("# Organized\n\nStub")
            )
        )
        let project = try fixture.projectStore.createProject(name: "Docs")
        try fixture.projectStore.assignThread("thread-1", toProjectID: project.id)

        let target = try createProjectNote(
            projectID: project.id,
            title: "Onboarding",
            text: "# Overview\n\nIntro\n\n## Details\n\nOld detail",
            store: fixture.projectStore
        )

        let originalText = try XCTUnwrap(
            try fixture.projectStore.loadProjectStoredNotes(projectID: project.id).first(where: {
                $0.noteID == target.noteID
            })?.text
        )

        let result = await fixture.service.run(
            arguments: [
                "action": "prepare_add",
                "noteId": target.noteID,
                "content": "- Added detail"
            ],
            sessionID: "thread-1",
            runtimeContext: nil,
            preferredModelID: nil,
            interactionMode: .plan
        )

        XCTAssertTrue(result.success)
        let response: AssistantNotesToolService.PreparedChangeResponse = try decodeResult(result)
        XCTAssertEqual(response.placement, "Overview > Details")
        let storedTextAfterPreview = try XCTUnwrap(
            try fixture.projectStore.loadProjectStoredNotes(projectID: project.id).first(where: {
                $0.noteID == target.noteID
            })?.text
        )
        XCTAssertEqual(storedTextAfterPreview, originalText)
    }

    func testApplyPreviewRejectsStalePreview() async throws {
        let fixture = try makeFixture()
        let project = try fixture.projectStore.createProject(name: "Docs")
        try fixture.projectStore.assignThread("thread-1", toProjectID: project.id)

        let target = try createProjectNote(
            projectID: project.id,
            title: "Onboarding",
            text: "# Onboarding\n\nOriginal",
            store: fixture.projectStore
        )

        let prepareResult = await fixture.service.run(
            arguments: [
                "action": "prepare_add",
                "noteId": target.noteID,
                "content": "- Added detail"
            ],
            sessionID: "thread-1",
            runtimeContext: nil,
            preferredModelID: nil,
            interactionMode: .plan
        )
        let preview: AssistantNotesToolService.PreparedChangeResponse = try decodeResult(prepareResult)

        _ = try fixture.projectStore.saveProjectNote(
            projectID: project.id,
            noteID: target.noteID,
            text: "# Onboarding\n\nChanged after preview"
        )

        let applyResult = await fixture.service.run(
            arguments: [
                "action": "apply_preview",
                "previewId": preview.previewId
            ],
            sessionID: "thread-1",
            runtimeContext: nil,
            preferredModelID: nil,
            interactionMode: .agentic
        )

        XCTAssertFalse(applyResult.success)
        XCTAssertTrue(
            applyResult.contentItems.first?.text?.contains("changed after this preview") == true
        )
    }

    func testPrepareOrganizePreviewAppliesAndPreservesSelectedNote() async throws {
        let fixture = try makeFixture(
            aiProvider: StubAssistantNotesAIProvider(
                placementResult: .success(
                    ProjectNoteTransferSuggestion(
                        headingPath: nil,
                        insertedMarkdown: "Stub content",
                        reason: "Stub placement."
                    )
                ),
                organizeResult: .success("# Organized\n\n- Clean list")
            )
        )
        let project = try fixture.projectStore.createProject(name: "Docs")
        try fixture.projectStore.assignThread("thread-1", toProjectID: project.id)

        let selectedNote = try createProjectNote(
            projectID: project.id,
            title: "Master",
            text: "# Master\n\nKeep selected",
            store: fixture.projectStore
        )
        let targetNote = try createProjectNote(
            projectID: project.id,
            title: "Messy",
            text: "messy text",
            store: fixture.projectStore
        )
        _ = try fixture.projectStore.selectProjectNote(
            projectID: project.id,
            noteID: selectedNote.noteID
        )

        let prepareResult = await fixture.service.run(
            arguments: [
                "action": "prepare_organize",
                "noteId": targetNote.noteID
            ],
            sessionID: "thread-1",
            runtimeContext: nil,
            preferredModelID: nil,
            interactionMode: .plan
        )

        XCTAssertTrue(prepareResult.success)
        let preview: AssistantNotesToolService.PreparedChangeResponse = try decodeResult(prepareResult)
        let beforeApplyText = try XCTUnwrap(
            try fixture.projectStore.loadProjectStoredNotes(projectID: project.id).first(where: {
                $0.noteID == targetNote.noteID
            })?.text
        )
        XCTAssertEqual(beforeApplyText, "messy text")

        let applyResult = await fixture.service.run(
            arguments: [
                "action": "apply_preview",
                "previewId": preview.previewId
            ],
            sessionID: "thread-1",
            runtimeContext: nil,
            preferredModelID: nil,
            interactionMode: .agentic
        )

        XCTAssertTrue(applyResult.success)
        let updatedText = try XCTUnwrap(
            try fixture.projectStore.loadProjectStoredNotes(projectID: project.id).first(where: {
                $0.noteID == targetNote.noteID
            })?.text
        )
        XCTAssertEqual(updatedText, "# Organized\n\n- Clean list")

        let finalWorkspace = try fixture.projectStore.loadProjectNotesWorkspace(projectID: project.id)
        XCTAssertEqual(finalWorkspace.selectedNote?.id, selectedNote.noteID)
    }

    func testListNotesUsesRuntimeContextProjectScopeWhenNoLinkedThreadExists() async throws {
        let fixture = try makeFixture()
        let projectA = try fixture.projectStore.createProject(name: "Project A")
        let projectB = try fixture.projectStore.createProject(name: "Project B")

        _ = try createProjectNote(
            projectID: projectA.id,
            title: "Project A Master",
            text: "# Project A\n\nShared note",
            noteType: .master,
            store: fixture.projectStore
        )
        _ = try createProjectNote(
            projectID: projectB.id,
            title: "Project B Master",
            text: "# Project B\n\nShould stay hidden",
            noteType: .master,
            store: fixture.projectStore
        )
        try fixture.projectStore.assignThread("thread-a", toProjectID: projectA.id)
        try fixture.projectStore.assignThread("thread-b", toProjectID: projectB.id)
        _ = try createThreadNote(
            threadID: "thread-a",
            title: "Project A Thread",
            text: "Belongs to project A",
            store: fixture.conversationStore
        )
        _ = try createThreadNote(
            threadID: "thread-b",
            title: "Project B Thread",
            text: "Belongs to project B",
            store: fixture.conversationStore
        )

        let runtimeContext = AssistantNotesRuntimeContext(
            source: .notesWorkspace,
            projectID: projectA.id,
            projectName: projectA.name,
            selectedNoteTarget: nil,
            selectedNoteTitle: nil,
            defaultScopeDescription: "the whole current project"
        )

        let result = await fixture.service.run(
            arguments: ["action": "list_notes"],
            sessionID: nil,
            runtimeContext: runtimeContext,
            preferredModelID: nil,
            interactionMode: .plan
        )

        XCTAssertTrue(result.success)
        let response: AssistantNotesToolService.ListResponse = try decodeResult(result)
        XCTAssertEqual(response.noteCount, 2)
        XCTAssertEqual(
            Set(response.notes.map(\.title)),
            Set(["Project A Master", "Project A Thread"])
        )
    }

    func testPrepareOrganizePrefersSelectedWorkspaceNoteForThisNoteQuery() async throws {
        let fixture = try makeFixture(
            aiProvider: StubAssistantNotesAIProvider(
                placementResult: .success(
                    ProjectNoteTransferSuggestion(
                        headingPath: nil,
                        insertedMarkdown: "Stub content",
                        reason: "Stub placement."
                    )
                ),
                organizeResult: .success("# Selected Note\n\nOrganized from workspace context")
            )
        )
        let project = try fixture.projectStore.createProject(name: "Docs")
        try fixture.projectStore.assignThread("thread-1", toProjectID: project.id)

        let selectedNote = try createProjectNote(
            projectID: project.id,
            title: "Current Note",
            text: "# Current Note\n\nMessy selected text",
            store: fixture.projectStore
        )
        _ = try createProjectNote(
            projectID: project.id,
            title: "Other Note",
            text: "# Other Note\n\nDifferent text",
            store: fixture.projectStore
        )

        let runtimeContext = AssistantNotesRuntimeContext(
            source: .notesWorkspace,
            projectID: project.id,
            projectName: project.name,
            selectedNoteTarget: AssistantNoteLinkTarget(
                ownerKind: .project,
                ownerID: project.id,
                noteID: selectedNote.noteID
            ),
            selectedNoteTitle: selectedNote.title,
            defaultScopeDescription: "the whole current project"
        )

        let result = await fixture.service.run(
            arguments: [
                "action": "prepare_organize",
                "query": "organize this note"
            ],
            sessionID: "thread-1",
            runtimeContext: runtimeContext,
            preferredModelID: nil,
            interactionMode: .plan
        )

        XCTAssertTrue(result.success)
        let preview: AssistantNotesToolService.PreparedChangeResponse = try decodeResult(result)
        XCTAssertEqual(preview.target.noteID, selectedNote.noteID)
        XCTAssertEqual(preview.target.title, selectedNote.title)
    }

    func testPrepareAddInNotesWorkspaceDoesNotAutoTargetOpenNoteWithoutExplicitReference() async throws {
        let fixture = try makeFixture()
        let project = try fixture.projectStore.createProject(name: "Docs")
        try fixture.projectStore.assignThread("thread-1", toProjectID: project.id)

        let selectedNote = try createProjectNote(
            projectID: project.id,
            title: "Questions",
            text: """
            # Questions

            Migration notes and repo findings live here for open questions.
            """,
            store: fixture.projectStore
        )
        _ = try createProjectNote(
            projectID: project.id,
            title: "Roadmap",
            text: "# Roadmap\n\nUnrelated planning note",
            store: fixture.projectStore
        )

        let runtimeContext = AssistantNotesRuntimeContext(
            source: .notesWorkspace,
            projectID: project.id,
            projectName: project.name,
            selectedNoteTarget: AssistantNoteLinkTarget(
                ownerKind: .project,
                ownerID: project.id,
                noteID: selectedNote.noteID
            ),
            selectedNoteTitle: selectedNote.title,
            defaultScopeDescription: "the whole current project"
        )

        let result = await fixture.service.run(
            arguments: [
                "action": "prepare_add",
                "query": "Add this to the most applicable note or create a new note.",
                "content": """
                # Migration Toolkit - Key Notes

                Repo migration checklist and script differences.
                """
            ],
            sessionID: "thread-1",
            runtimeContext: runtimeContext,
            preferredModelID: nil,
            interactionMode: .plan
        )

        XCTAssertTrue(result.success)
        let response: AssistantNotesToolService.PreparedChangeResponse = try decodeResult(result)
        XCTAssertTrue(response.target.isNewNote)
        XCTAssertNotEqual(response.target.noteID, selectedNote.noteID)
    }

    func testPrepareAddInNotesWorkspaceStillUsesOpenNoteWhenExplicitlyRequested() async throws {
        let fixture = try makeFixture()
        let project = try fixture.projectStore.createProject(name: "Docs")
        try fixture.projectStore.assignThread("thread-1", toProjectID: project.id)

        let selectedNote = try createProjectNote(
            projectID: project.id,
            title: "Questions",
            text: "# Questions\n\nExisting text",
            store: fixture.projectStore
        )

        let runtimeContext = AssistantNotesRuntimeContext(
            source: .notesWorkspace,
            projectID: project.id,
            projectName: project.name,
            selectedNoteTarget: AssistantNoteLinkTarget(
                ownerKind: .project,
                ownerID: project.id,
                noteID: selectedNote.noteID
            ),
            selectedNoteTitle: selectedNote.title,
            defaultScopeDescription: "the whole current project"
        )

        let result = await fixture.service.run(
            arguments: [
                "action": "prepare_add",
                "query": "Add this to this note.",
                "content": "- Added detail"
            ],
            sessionID: "thread-1",
            runtimeContext: runtimeContext,
            preferredModelID: nil,
            interactionMode: .plan
        )

        XCTAssertTrue(result.success)
        let response: AssistantNotesToolService.PreparedChangeResponse = try decodeResult(result)
        XCTAssertFalse(response.target.isNewNote)
        XCTAssertEqual(response.target.noteID, selectedNote.noteID)
    }

    func testPrepareAddUsesContentHeadingToFindBestExistingNote() async throws {
        let fixture = try makeFixture()
        let project = try fixture.projectStore.createProject(name: "Docs")
        try fixture.projectStore.assignThread("thread-1", toProjectID: project.id)

        let migrationToolkit = try createProjectNote(
            projectID: project.id,
            title: "Migration Toolkit",
            text: """
            # Migration Toolkit

            Existing migration reference note.
            """,
            store: fixture.projectStore
        )
        _ = try createProjectNote(
            projectID: project.id,
            title: "Questions",
            text: "# Questions\n\nOpen items live here.",
            store: fixture.projectStore
        )

        let result = await fixture.service.run(
            arguments: [
                "action": "prepare_add",
                "query": "Add this to the most applicable note or create a new note.",
                "content": """
                # Migration Toolkit

                Repo migration checklist and script differences.
                """
            ],
            sessionID: "thread-1",
            runtimeContext: nil,
            preferredModelID: nil,
            interactionMode: .plan
        )

        XCTAssertTrue(result.success)
        let response: AssistantNotesToolService.PreparedChangeResponse = try decodeResult(result)
        XCTAssertFalse(response.target.isNewNote)
        XCTAssertEqual(response.target.noteID, migrationToolkit.noteID)
    }

    func testListAndSearchNotesIncludeProjectFolderPathMetadata() async throws {
        let fixture = try makeFixture()
        let project = try fixture.projectStore.createProject(name: "Docs")
        try fixture.projectStore.assignThread("thread-1", toProjectID: project.id)

        let planningWorkspace = try fixture.projectStore.createProjectNoteFolder(
            projectID: project.id,
            name: "Planning"
        )
        let planningFolderID = try XCTUnwrap(planningWorkspace.manifest.folders.first?.id)
        let q2Workspace = try fixture.projectStore.createProjectNoteFolder(
            projectID: project.id,
            parentFolderID: planningFolderID,
            name: "Q2"
        )
        let q2FolderID = try XCTUnwrap(
            q2Workspace.manifest.folders.first(where: { $0.name == "Q2" })?.id
        )
        _ = try createProjectNote(
            projectID: project.id,
            title: "Roadmap",
            text: "# Roadmap\n\nQuarter goals",
            folderID: q2FolderID,
            store: fixture.projectStore
        )

        let listResult = await fixture.service.run(
            arguments: ["action": "list_notes"],
            sessionID: "thread-1",
            runtimeContext: nil,
            preferredModelID: nil,
            interactionMode: .plan
        )

        XCTAssertTrue(listResult.success)
        let listResponse: AssistantNotesToolService.ListResponse = try decodeResult(listResult)
        XCTAssertEqual(
            listResponse.notes.first(where: { $0.title == "Roadmap" })?.folderPath,
            ["Planning", "Q2"]
        )

        let searchResult = await fixture.service.run(
            arguments: [
                "action": "search_notes",
                "query": "planning"
            ],
            sessionID: "thread-1",
            runtimeContext: nil,
            preferredModelID: nil,
            interactionMode: .plan
        )

        XCTAssertTrue(searchResult.success)
        let searchResponse: AssistantNotesToolService.SearchResponse = try decodeResult(
            searchResult
        )
        XCTAssertEqual(searchResponse.noteCount, 1)
        XCTAssertEqual(searchResponse.notes.first?.title, "Roadmap")
        XCTAssertEqual(searchResponse.notes.first?.folderPath, ["Planning", "Q2"])
    }

    private func makeFixture(
        aiProvider: any AssistantNotesToolAIProviding = StubAssistantNotesAIProvider()
    ) throws -> (
        service: AssistantNotesToolService,
        projectStore: AssistantProjectStore,
        conversationStore: AssistantConversationStore
    ) {
        let directory = try makeTemporaryDirectory(named: "assistant-notes-tool-service")
        let projectStore = AssistantProjectStore(baseDirectoryURL: directory.appendingPathComponent("projects", isDirectory: true))
        let conversationStore = AssistantConversationStore(
            fileManager: .default,
            baseDirectoryURL: directory.appendingPathComponent("threads", isDirectory: true)
        )
        let service = AssistantNotesToolService(
            projectStore: projectStore,
            conversationStore: conversationStore,
            aiProvider: aiProvider
        )
        service.setSessionSummaryProvider { threadID in
            AssistantSessionSummary(
                id: threadID,
                title: "Session \(threadID)",
                source: .openAssist,
                threadArchitectureVersion: .providerIndependentV2,
                status: .idle
            )
        }
        return (service, projectStore, conversationStore)
    }

    private func decodeResult<T: Decodable>(_ result: AssistantToolExecutionResult) throws -> T {
        let text = try XCTUnwrap(result.contentItems.first?.text)
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    private func makeTemporaryDirectory(named prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func createProjectNote(
        projectID: String,
        title: String,
        text: String,
        noteType: AssistantNoteType = .note,
        folderID: String? = nil,
        store: AssistantProjectStore
    ) throws -> AssistantStoredNote {
        let workspace = try store.createProjectNote(
            projectID: projectID,
            title: title,
            noteType: noteType,
            selectNewNote: true,
            folderID: folderID
        )
        let noteID = try XCTUnwrap(workspace.selectedNote?.id)
        _ = try store.saveProjectNote(
            projectID: projectID,
            noteID: noteID,
            text: text
        )
        return try XCTUnwrap(
            try store.loadProjectStoredNotes(projectID: projectID).first(where: { $0.noteID == noteID })
        )
    }

    private func createThreadNote(
        threadID: String,
        title: String,
        text: String,
        store: AssistantConversationStore
    ) throws -> AssistantStoredNote {
        let workspace = try store.createThreadNote(
            threadID: threadID,
            title: title,
            noteType: .note,
            selectNewNote: true
        )
        let noteID = try XCTUnwrap(workspace.selectedNote?.id)
        _ = try store.saveThreadNote(
            threadID: threadID,
            noteID: noteID,
            text: text
        )
        return try XCTUnwrap(
            store.loadThreadStoredNotes(threadID: threadID).first(where: { $0.noteID == noteID })
        )
    }
}
