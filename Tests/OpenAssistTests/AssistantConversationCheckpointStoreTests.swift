import Foundation
import XCTest
@testable import OpenAssist

final class AssistantConversationCheckpointStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testTrackingStateCanRoundTripAndDelete() throws {
        let homeDirectory = try makeTemporaryDirectory(named: "ConversationCheckpointHome")
        let trackingDirectory = try makeTemporaryDirectory(named: "ConversationCheckpointTracking")
        let memoryRoot = try makeTemporaryDirectory(named: "ConversationCheckpointMemory")
        let databaseURL = try makeTemporaryDirectory(named: "ConversationCheckpointDB")
            .appendingPathComponent("memory.sqlite3", isDirectory: false)

        let sessionCatalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let threadMemoryService = AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        let memoryStore = try MemorySQLiteStore(databaseURL: databaseURL)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: threadMemoryService,
            store: memoryStore
        )
        let agentStateService = ConversationAgentStateService(storeFactory: { memoryStore })
        let checkpointStore = AssistantConversationCheckpointStore(
            sessionCatalog: sessionCatalog,
            threadMemoryService: threadMemoryService,
            memorySuggestionService: suggestionService,
            memoryStore: memoryStore,
            agentStateService: agentStateService,
            baseDirectoryURL: trackingDirectory
        )

        let file = AssistantCodeCheckpointFile(
            path: "tracked.txt",
            changeKind: .modified,
            beforeWorktree: GitCheckpointPathState(blobID: "blob-1", mode: "100644", objectType: "blob"),
            afterWorktree: GitCheckpointPathState(blobID: "blob-2", mode: "100644", objectType: "blob"),
            beforeIndex: GitCheckpointPathState(blobID: "blob-1", mode: "100644", objectType: "blob"),
            afterIndex: GitCheckpointPathState(blobID: "blob-2", mode: "100644", objectType: "blob"),
            isBinary: false
        )
        let snapshotBefore = GitCheckpointSnapshot(
            worktreeRef: "refs/openassist/checkpoints/thread/one/before-worktree",
            worktreeCommit: "before-worktree",
            worktreeTree: "before-worktree-tree",
            indexRef: "refs/openassist/checkpoints/thread/one/before-index",
            indexCommit: "before-index",
            indexTree: "before-index-tree",
            ignoredFingerprints: [:]
        )
        let snapshotAfter = GitCheckpointSnapshot(
            worktreeRef: "refs/openassist/checkpoints/thread/one/after-worktree",
            worktreeCommit: "after-worktree",
            worktreeTree: "after-worktree-tree",
            indexRef: "refs/openassist/checkpoints/thread/one/after-index",
            indexCommit: "after-index",
            indexTree: "after-index-tree",
            ignoredFingerprints: [:]
        )
        let checkpoint = AssistantCodeCheckpointSummary(
            id: "checkpoint-1",
            checkpointNumber: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            turnStatus: .completed,
            summary: "Saved a checkpoint that updated 1 file.",
            patch: "diff --git a/tracked.txt b/tracked.txt",
            changedFiles: [file],
            ignoredTouchedPaths: [],
            beforeSnapshot: snapshotBefore,
            afterSnapshot: snapshotAfter
        )
        let state = AssistantCodeTrackingState(
            sessionID: "thread-1",
            availability: .available,
            repoRootPath: "/tmp/repo",
            repoLabel: "repo",
            checkpoints: [checkpoint],
            currentCheckpointPosition: 0
        )

        try checkpointStore.saveTrackingState(state)
        XCTAssertEqual(checkpointStore.loadTrackingState(for: "thread-1"), state)

        checkpointStore.deleteTrackingState(for: "thread-1")
        XCTAssertNil(checkpointStore.loadTrackingState(for: "thread-1"))
    }

    func testCaptureAndRestoreSnapshotRestoresThreadArtifacts() async throws {
        let homeDirectory = try makeTemporaryDirectory(named: "ConversationCheckpointHome")
        let trackingDirectory = try makeTemporaryDirectory(named: "ConversationCheckpointTracking")
        let memoryRoot = try makeTemporaryDirectory(named: "ConversationCheckpointMemory")
        let databaseURL = try makeTemporaryDirectory(named: "ConversationCheckpointDB")
            .appendingPathComponent("memory.sqlite3", isDirectory: false)
        let sessionID = "thread-restore"
        let checkpointID = "checkpoint-a"

        try writeSessionFile(
            sessionID: sessionID,
            dayPath: "2026/03/21",
            homeDirectory: homeDirectory,
            contents: """
            {\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-restore\"}}
            {\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\"}}
            """
        )

        let sessionCatalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let threadMemoryService = AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        let memoryStore = try MemorySQLiteStore(databaseURL: databaseURL)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: threadMemoryService,
            store: memoryStore
        )
        let agentStateService = ConversationAgentStateService(storeFactory: { memoryStore })
        let checkpointStore = AssistantConversationCheckpointStore(
            sessionCatalog: sessionCatalog,
            threadMemoryService: threadMemoryService,
            memorySuggestionService: suggestionService,
            memoryStore: memoryStore,
            agentStateService: agentStateService,
            baseDirectoryURL: trackingDirectory
        )

        var originalDocument = AssistantThreadMemoryDocument.empty
        originalDocument.currentTask = "Before task"
        originalDocument.activeFacts = ["Important fact"]
        _ = try threadMemoryService.saveDocument(originalDocument, for: sessionID)

        let scope = MemoryScopeContext(
            appName: "Open Assist",
            bundleID: "com.developingadventures.OpenAssist",
            surfaceLabel: "Assistant",
            projectName: "OpenAssist",
            repositoryName: "OpenAssist",
            identityKey: "assistant-session:\(sessionID)",
            identityType: "assistant-session",
            identityLabel: sessionID,
            scopeKey: "scope|assistant|\(sessionID)",
            isCodingContext: true
        )

        let createdSuggestions = try suggestionService.createManualSuggestions(
            from: "Prefer a short explanation when the user asks for a quick answer.",
            threadID: sessionID,
            scope: scope
        )
        let rememberedEntry = AssistantMemoryEntry(
            scopeKey: scope.scopeKey,
            bundleID: scope.bundleID,
            projectKey: scope.projectKey,
            identityKey: scope.identityKey,
            threadID: sessionID,
            memoryType: .lesson,
            title: "Keep short answers short",
            summary: "Keep short answers short",
            detail: "Use shorter explanations when the user asks for a quick answer.",
            keywords: ["short", "answers"],
            metadata: ["memory_domain": "assistant"]
        )
        try memoryStore.upsertAssistantMemoryEntry(rememberedEntry)

        let originalProfile = ConversationAgentProfileRecord(
            threadID: sessionID,
            profileJSON: #"{"tone":"brief"}"#
        )
        let originalEntities = ConversationAgentEntitiesRecord(
            threadID: sessionID,
            entitiesJSON: #"[{"name":"OpenAssist"}]"#
        )
        let originalPreferences = ConversationAgentPreferencesRecord(
            threadID: sessionID,
            preferencesJSON: #"{"language":"simple"}"#
        )
        try memoryStore.upsertConversationThread(
            ConversationThreadRecord(
                id: sessionID,
                appName: "Open Assist",
                bundleID: "com.developingadventures.OpenAssist",
                logicalSurfaceKey: "assistant",
                screenLabel: "Assistant",
                fieldLabel: "Prompt",
                projectKey: "openassist",
                projectLabel: "OpenAssist",
                identityKey: "assistant-session:\(sessionID)",
                identityType: "assistant-session",
                identityLabel: sessionID,
                nativeThreadKey: sessionID,
                people: [],
                runningSummary: "",
                totalExchangeTurns: 0,
                createdAt: Date(),
                lastActivityAt: Date(),
                updatedAt: Date()
            )
        )
        try await agentStateService.upsertProfile(originalProfile)
        try await agentStateService.upsertEntities(originalEntities)
        try await agentStateService.upsertPreferences(originalPreferences)

        let originalSessionURL = try XCTUnwrap(sessionCatalog.sessionFileURL(for: sessionID))
        let originalSessionContents = try String(contentsOf: originalSessionURL, encoding: .utf8)

        try await checkpointStore.captureSnapshot(
            sessionID: sessionID,
            checkpointID: checkpointID,
            phase: .before
        )

        try "mutated session".write(to: originalSessionURL, atomically: true, encoding: .utf8)

        var mutatedDocument = AssistantThreadMemoryDocument.empty
        mutatedDocument.currentTask = "After task"
        _ = try threadMemoryService.saveDocument(mutatedDocument, for: sessionID)
        try suggestionService.clearSuggestions(for: sessionID)
        try memoryStore.deleteAssistantMemoryEntries(threadID: sessionID)
        try await agentStateService.clearProfile(threadID: sessionID)
        try await agentStateService.clearEntities(threadID: sessionID)
        try await agentStateService.clearPreferences(threadID: sessionID)

        try await checkpointStore.restoreSnapshot(
            sessionID: sessionID,
            checkpointID: checkpointID,
            phase: .before
        )

        XCTAssertEqual(
            try String(contentsOf: originalSessionURL, encoding: .utf8),
            originalSessionContents
        )

        let restoredDocument = try threadMemoryService.loadTrackedDocument(for: sessionID).document
        XCTAssertEqual(restoredDocument.currentTask, "Before task")
        XCTAssertEqual(restoredDocument.activeFacts, ["Important fact"])

        XCTAssertEqual(
            try suggestionService.suggestions(for: sessionID).map(\.summary),
            createdSuggestions.map(\.summary)
        )

        let restoredEntries = try memoryStore.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            threadID: sessionID,
            state: .active,
            limit: 20
        )
        XCTAssertEqual(restoredEntries.map(\.summary), [rememberedEntry.summary])

        let restoredProfile = try await agentStateService.fetchProfile(threadID: sessionID)
        let restoredEntities = try await agentStateService.fetchEntities(threadID: sessionID)
        let restoredPreferences = try await agentStateService.fetchPreferences(threadID: sessionID)

        XCTAssertEqual(restoredProfile?.threadID, originalProfile.threadID)
        XCTAssertEqual(restoredProfile?.profileJSON, originalProfile.profileJSON)
        XCTAssertEqual(restoredEntities?.threadID, originalEntities.threadID)
        XCTAssertEqual(restoredEntities?.entitiesJSON, originalEntities.entitiesJSON)
        XCTAssertEqual(restoredPreferences?.threadID, originalPreferences.threadID)
        XCTAssertEqual(restoredPreferences?.preferencesJSON, originalPreferences.preferencesJSON)
    }

    func testHasSnapshotRequiresPayloadAndConversationArtifacts() async throws {
        let homeDirectory = try makeTemporaryDirectory(named: "ConversationCheckpointHome")
        let trackingDirectory = try makeTemporaryDirectory(named: "ConversationCheckpointTracking")
        let memoryRoot = try makeTemporaryDirectory(named: "ConversationCheckpointMemory")
        let databaseURL = try makeTemporaryDirectory(named: "ConversationCheckpointDB")
            .appendingPathComponent("memory.sqlite3", isDirectory: false)
        let sessionID = "thread-has-snapshot"
        let checkpointID = "checkpoint-has-snapshot"

        try writeSessionFile(
            sessionID: sessionID,
            dayPath: "2026/04/01",
            homeDirectory: homeDirectory,
            contents: """
            {\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-has-snapshot\"}}
            """
        )

        let sessionCatalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let threadMemoryService = AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        let memoryStore = try MemorySQLiteStore(databaseURL: databaseURL)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: threadMemoryService,
            store: memoryStore
        )
        let agentStateService = ConversationAgentStateService(storeFactory: { memoryStore })
        let checkpointStore = AssistantConversationCheckpointStore(
            sessionCatalog: sessionCatalog,
            threadMemoryService: threadMemoryService,
            memorySuggestionService: suggestionService,
            memoryStore: memoryStore,
            agentStateService: agentStateService,
            baseDirectoryURL: trackingDirectory
        )

        XCTAssertFalse(
            checkpointStore.hasSnapshot(
                sessionID: sessionID,
                checkpointID: checkpointID,
                phase: .after
            )
        )

        try await checkpointStore.captureSnapshot(
            sessionID: sessionID,
            checkpointID: checkpointID,
            phase: .after
        )

        XCTAssertTrue(
            checkpointStore.hasSnapshot(
                sessionID: sessionID,
                checkpointID: checkpointID,
                phase: .after
            )
        )

        checkpointStore.deleteCheckpoints(sessionID: sessionID, checkpointIDs: [checkpointID])

        XCTAssertFalse(
            checkpointStore.hasSnapshot(
                sessionID: sessionID,
                checkpointID: checkpointID,
                phase: .after
            )
        )
    }

    func testCaptureAndRestoreSnapshotRestoresHybridConversationEventLog() async throws {
        let trackingDirectory = try makeTemporaryDirectory(named: "ConversationCheckpointTracking")
        let conversationDirectory = try makeTemporaryDirectory(named: "ConversationCheckpointConversation")
        let memoryRoot = try makeTemporaryDirectory(named: "ConversationCheckpointMemory")
        let databaseURL = try makeTemporaryDirectory(named: "ConversationCheckpointDB")
            .appendingPathComponent("memory.sqlite3", isDirectory: false)
        let sessionCatalog = CodexSessionCatalog(homeDirectory: try makeTemporaryDirectory(named: "ConversationCheckpointHome"))
        let threadMemoryService = AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        let memoryStore = try MemorySQLiteStore(databaseURL: databaseURL)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: threadMemoryService,
            store: memoryStore
        )
        let agentStateService = ConversationAgentStateService(storeFactory: { memoryStore })
        let conversationStore = AssistantConversationStore(baseDirectoryURL: conversationDirectory)
        let checkpointStore = AssistantConversationCheckpointStore(
            sessionCatalog: sessionCatalog,
            conversationStore: conversationStore,
            threadMemoryService: threadMemoryService,
            memorySuggestionService: suggestionService,
            memoryStore: memoryStore,
            agentStateService: agentStateService,
            baseDirectoryURL: trackingDirectory
        )

        let sessionID = "hybrid-thread"
        let checkpointID = "checkpoint-hybrid"
        let originalSnapshot = AssistantConversationSnapshot(
            version: 2,
            threadID: sessionID,
            timeline: [
                .userMessage(
                    id: "user-1",
                    sessionID: sessionID,
                    text: "hello",
                    createdAt: Date(timeIntervalSince1970: 10),
                    source: .runtime
                ),
                .assistantFinal(
                    id: "assistant-1",
                    sessionID: sessionID,
                    turnID: "turn-1",
                    text: "done",
                    createdAt: Date(timeIntervalSince1970: 11),
                    updatedAt: Date(timeIntervalSince1970: 11),
                    isStreaming: false,
                    providerBackend: .codex,
                    providerModelID: "gpt-5.4",
                    source: .runtime
                )
            ],
            transcript: [
                AssistantTranscriptEntry(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
                    role: .user,
                    text: "hello",
                    createdAt: Date(timeIntervalSince1970: 10)
                ),
                AssistantTranscriptEntry(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
                    role: .assistant,
                    text: "done",
                    createdAt: Date(timeIntervalSince1970: 11),
                    providerBackend: .codex,
                    providerModelID: "gpt-5.4"
                )
            ],
            turns: [],
            updatedAt: Date(timeIntervalSince1970: 12)
        )
        try conversationStore.rewriteHybridSnapshotAndEventLog(originalSnapshot)

        let snapshotURL = try XCTUnwrap(conversationStore.snapshotFileURL(for: sessionID))
        let eventLogURL = try XCTUnwrap(conversationStore.eventLogFileURL(for: sessionID))
        let originalSnapshotData = try Data(contentsOf: snapshotURL)
        let originalEventLogData = try Data(contentsOf: eventLogURL)

        try await checkpointStore.captureSnapshot(
            sessionID: sessionID,
            checkpointID: checkpointID,
            phase: .before
        )

        try conversationStore.storeSnapshot(
            AssistantConversationSnapshot(
                version: 2,
                threadID: sessionID,
                timeline: [],
                transcript: [],
                turns: [],
                updatedAt: Date(),
                lastAppliedEventSequence: 99
            )
        )
        try XCTUnwrap("corrupted\n".data(using: .utf8)).write(to: eventLogURL, options: .atomic)

        try await checkpointStore.restoreSnapshot(
            sessionID: sessionID,
            checkpointID: checkpointID,
            phase: .before
        )

        XCTAssertEqual(try Data(contentsOf: snapshotURL), originalSnapshotData)
        XCTAssertEqual(try Data(contentsOf: eventLogURL), originalEventLogData)
        XCTAssertEqual(
            try XCTUnwrap(conversationStore.loadSnapshot(threadID: sessionID)).transcript.map(\.text),
            ["hello", "done"]
        )
    }

    func testTrackingStateCanPersistHistoryBranchState() throws {
        let homeDirectory = try makeTemporaryDirectory(named: "ConversationCheckpointHome")
        let trackingDirectory = try makeTemporaryDirectory(named: "ConversationCheckpointTracking")
        let memoryRoot = try makeTemporaryDirectory(named: "ConversationCheckpointMemory")
        let databaseURL = try makeTemporaryDirectory(named: "ConversationCheckpointDB")
            .appendingPathComponent("memory.sqlite3", isDirectory: false)

        let sessionCatalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let threadMemoryService = AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        let memoryStore = try MemorySQLiteStore(databaseURL: databaseURL)
        let suggestionService = AssistantMemorySuggestionService(
            threadMemoryService: threadMemoryService,
            store: memoryStore
        )
        let agentStateService = ConversationAgentStateService(storeFactory: { memoryStore })
        let checkpointStore = AssistantConversationCheckpointStore(
            sessionCatalog: sessionCatalog,
            threadMemoryService: threadMemoryService,
            memorySuggestionService: suggestionService,
            memoryStore: memoryStore,
            agentStateService: agentStateService,
            baseDirectoryURL: trackingDirectory
        )

        let attachment = AssistantAttachment(
            filename: "note.txt",
            data: Data("draft".utf8),
            mimeType: "text/plain"
        )
        let branchState = AssistantHistoryBranchState(
            kind: .undo,
            sessionID: "thread-branch",
            currentAnchorID: "anchor-a",
            currentCheckpointPosition: 1,
            currentPrompt: "restore this draft",
            currentAttachments: [attachment],
            futureStates: [
                AssistantHistoryFutureState(
                    restoreAnchorID: "anchor-b",
                    title: "Second message",
                    snapshotID: "history-snapshot-b",
                    checkpointPosition: 2,
                    currentAnchorIDAfterRestore: nil,
                    composerPrompt: "",
                    composerAttachments: []
                )
            ]
        )
        let state = AssistantCodeTrackingState(
            sessionID: "thread-branch",
            availability: .unavailable,
            repoRootPath: nil,
            repoLabel: nil,
            checkpoints: [],
            currentCheckpointPosition: 1,
            historyBranchState: branchState
        )

        try checkpointStore.saveTrackingState(state)

        let loadedState = try XCTUnwrap(checkpointStore.loadTrackingState(for: "thread-branch"))
        XCTAssertEqual(loadedState.sessionID, state.sessionID)
        XCTAssertEqual(loadedState.availability, state.availability)
        XCTAssertEqual(loadedState.currentCheckpointPosition, state.currentCheckpointPosition)

        let loadedBranchState = try XCTUnwrap(loadedState.historyBranchState)
        XCTAssertEqual(loadedBranchState.kind, branchState.kind)
        XCTAssertEqual(loadedBranchState.sessionID, branchState.sessionID)
        XCTAssertEqual(loadedBranchState.currentAnchorID, branchState.currentAnchorID)
        XCTAssertEqual(loadedBranchState.currentCheckpointPosition, branchState.currentCheckpointPosition)
        XCTAssertEqual(loadedBranchState.currentPrompt, branchState.currentPrompt)
        XCTAssertEqual(loadedBranchState.currentAttachments.map(\.filename), branchState.currentAttachments.map(\.filename))
        XCTAssertEqual(loadedBranchState.currentAttachments.map(\.data), branchState.currentAttachments.map(\.data))
        XCTAssertEqual(loadedBranchState.currentAttachments.map(\.mimeType), branchState.currentAttachments.map(\.mimeType))
        XCTAssertEqual(loadedBranchState.futureStates, branchState.futureStates)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func writeSessionFile(
        sessionID: String,
        dayPath: String,
        homeDirectory: URL,
        contents: String
    ) throws {
        let sessionDirectory = homeDirectory
            .appendingPathComponent(".codex/sessions", isDirectory: true)
            .appendingPathComponent(dayPath, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let filename = "rollout-\(dayPath.replacingOccurrences(of: "/", with: "-"))-\(sessionID).jsonl"
        let fileURL = sessionDirectory.appendingPathComponent(filename, isDirectory: false)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
