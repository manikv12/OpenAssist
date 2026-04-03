import XCTest
@testable import OpenAssist

final class AssistantConversationStoreTests: XCTestCase {
    func testConversationStorePersistsTimelineTranscriptAndTurnMetadata() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
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
                    backend: .copilot,
                    providerSessionID: "copilot-session-1",
                    latestModelID: "gemini-3-pro-preview"
                )
            ],
            status: .idle
        )

        let timeline = [
            AssistantTimelineItem.userMessage(
                id: "user-1",
                sessionID: thread.id,
                turnID: "turn-1",
                text: "hi",
                source: .runtime
            ),
            AssistantTimelineItem.assistantFinal(
                id: "assistant-1",
                sessionID: thread.id,
                turnID: "turn-1",
                text: "Hello there",
                createdAt: Date(timeIntervalSince1970: 10),
                isStreaming: false,
                providerBackend: .copilot,
                providerModelID: "gemini-3-pro-preview",
                source: .runtime
            )
        ]
        let transcript = [
            AssistantTranscriptEntry(
                role: .assistant,
                text: "Hello there",
                createdAt: Date(timeIntervalSince1970: 10),
                providerBackend: .copilot,
                providerModelID: "gemini-3-pro-preview"
            )
        ]

        try store.saveSnapshot(
            threadID: thread.id,
            timeline: timeline,
            transcript: transcript,
            session: thread
        )

        let loaded = try XCTUnwrap(store.loadSnapshot(threadID: thread.id))
        XCTAssertEqual(loaded.timeline.count, 2)
        XCTAssertEqual(loaded.transcript.count, 1)
        XCTAssertEqual(loaded.turns.map(\.openAssistTurnID), ["turn-1"])
        XCTAssertEqual(loaded.turns.first?.provider, .copilot)
        XCTAssertEqual(loaded.turns.first?.providerSessionID, "copilot-session-1")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.eventLogFileURL(for: thread.id)?.path ?? ""
            )
        )
    }

    func testConversationStoreRebuildsVisibleTimelineFromTranscriptWhenTimelineIsMissing() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "openassist-thread-v2"
        try store.storeSnapshot(
            AssistantConversationSnapshot(
                version: 1,
                threadID: threadID,
                timeline: [],
                transcript: [
                    AssistantTranscriptEntry(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
                        role: .user,
                        text: "hi",
                        createdAt: Date(timeIntervalSince1970: 10),
                        providerBackend: .copilot,
                        providerModelID: "gpt-5.4"
                    ),
                    AssistantTranscriptEntry(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002") ?? UUID(),
                        role: .assistant,
                        text: "hello",
                        createdAt: Date(timeIntervalSince1970: 11),
                        providerBackend: .copilot,
                        providerModelID: "gpt-5.4"
                    )
                ],
                turns: [],
                updatedAt: Date()
            )
        )

        let timeline = store.loadTimeline(threadID: threadID, limit: 20)
        XCTAssertEqual(timeline.map(\.kind), [.userMessage, .assistantFinal])
        XCTAssertEqual(timeline.map(\.text), ["hi", "hello"])
    }

    func testConversationStoreRebuildsVisibleTimelineWhenStoredTimelineDropsUserMessages() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "openassist-thread-v2"
        try store.storeSnapshot(
            AssistantConversationSnapshot(
                version: 1,
                threadID: threadID,
                timeline: [
                    AssistantTimelineItem.assistantFinal(
                        id: "assistant-only",
                        sessionID: threadID,
                        text: "hello",
                        createdAt: Date(timeIntervalSince1970: 11),
                        updatedAt: Date(timeIntervalSince1970: 11),
                        isStreaming: false,
                        source: .runtime
                    )
                ],
                transcript: [
                    AssistantTranscriptEntry(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000011") ?? UUID(),
                        role: .user,
                        text: "hi",
                        createdAt: Date(timeIntervalSince1970: 10),
                        providerBackend: .copilot,
                        providerModelID: "gpt-5.4"
                    ),
                    AssistantTranscriptEntry(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000012") ?? UUID(),
                        role: .assistant,
                        text: "hello",
                        createdAt: Date(timeIntervalSince1970: 11),
                        providerBackend: .copilot,
                        providerModelID: "gpt-5.4"
                    )
                ],
                turns: [],
                updatedAt: Date()
            )
        )

        let timeline = store.loadTimeline(threadID: threadID, limit: 20)
        XCTAssertEqual(timeline.map(\.kind), [.userMessage, .assistantFinal])
        XCTAssertEqual(timeline.map(\.text), ["hi", "hello"])
    }

    func testHybridConversationStoreRewritesSnapshotAndEventLogTogether() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "openassist-hybrid-thread"
        let snapshot = AssistantConversationSnapshot(
            version: 2,
            threadID: threadID,
            timeline: [
                .userMessage(
                    id: "user-1",
                    sessionID: threadID,
                    text: "hello",
                    createdAt: Date(timeIntervalSince1970: 10),
                    source: .runtime
                ),
                .assistantFinal(
                    id: "assistant-1",
                    sessionID: threadID,
                    turnID: "turn-1",
                    text: "hi there",
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
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                    role: .user,
                    text: "hello",
                    createdAt: Date(timeIntervalSince1970: 10)
                ),
                AssistantTranscriptEntry(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                    role: .assistant,
                    text: "hi there",
                    createdAt: Date(timeIntervalSince1970: 11),
                    providerBackend: .codex,
                    providerModelID: "gpt-5.4"
                )
            ],
            turns: [],
            updatedAt: Date(timeIntervalSince1970: 12)
        )

        try store.rewriteHybridSnapshotAndEventLog(snapshot)

        let loaded = try XCTUnwrap(store.loadSnapshot(threadID: threadID))
        let eventLogURL = try XCTUnwrap(store.eventLogFileURL(for: threadID))
        let eventLogContents = try String(contentsOf: eventLogURL, encoding: .utf8)

        XCTAssertEqual(loaded.version, 2)
        XCTAssertEqual(loaded.lastAppliedEventSequence, 4)
        XCTAssertTrue(fileManager.fileExists(atPath: eventLogURL.path))
        XCTAssertEqual(
            eventLogContents.split(whereSeparator: \.isNewline).count,
            4
        )
    }

    func testHybridConversationStoreReplaysUnappliedTailEvents() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "openassist-hybrid-tail"
        try store.storeSnapshot(
            AssistantConversationSnapshot(
                version: 2,
                threadID: threadID,
                timeline: [
                    .userMessage(
                        id: "user-1",
                        sessionID: threadID,
                        text: "hello",
                        createdAt: Date(timeIntervalSince1970: 10),
                        source: .runtime
                    )
                ],
                transcript: [
                    AssistantTranscriptEntry(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
                        role: .user,
                        text: "hello",
                        createdAt: Date(timeIntervalSince1970: 10)
                    )
                ],
                turns: [],
                updatedAt: Date(timeIntervalSince1970: 10),
                lastAppliedEventSequence: 2
            )
        )

        try store.appendTranscriptUpsertEvent(
            threadID: threadID,
            entry: AssistantTranscriptEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
                role: .assistant,
                text: "done",
                createdAt: Date(timeIntervalSince1970: 11),
                providerBackend: .codex,
                providerModelID: "gpt-5.4"
            )
        )
        try store.appendTimelineUpsertEvent(
            threadID: threadID,
            item: .assistantFinal(
                id: "assistant-1",
                sessionID: threadID,
                turnID: "turn-1",
                text: "done",
                createdAt: Date(timeIntervalSince1970: 11),
                updatedAt: Date(timeIntervalSince1970: 11),
                isStreaming: false,
                providerBackend: .codex,
                providerModelID: "gpt-5.4",
                source: .runtime
            )
        )

        let loaded = try XCTUnwrap(store.loadSnapshot(threadID: threadID))
        XCTAssertEqual(loaded.transcript.map(\.text), ["hello", "done"])
        XCTAssertEqual(
            loaded.timeline.filter { $0.kind == .assistantFinal }.compactMap(\.text),
            ["done"]
        )
        XCTAssertEqual(loaded.lastAppliedEventSequence, 4)
    }

    func testHybridConversationStoreRebuildsSnapshotFromEventLogWhenSnapshotIsMissing() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "openassist-hybrid-rebuild"
        try store.appendTranscriptUpsertEvent(
            threadID: threadID,
            entry: AssistantTranscriptEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
                role: .user,
                text: "hello",
                createdAt: Date(timeIntervalSince1970: 10)
            )
        )
        try store.appendTranscriptUpsertEvent(
            threadID: threadID,
            entry: AssistantTranscriptEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
                role: .assistant,
                text: "done",
                createdAt: Date(timeIntervalSince1970: 11),
                providerBackend: .copilot,
                providerModelID: "gemini-3-pro-preview"
            )
        )
        try store.appendTimelineUpsertEvent(
            threadID: threadID,
            item: .userMessage(
                id: "user-1",
                sessionID: threadID,
                text: "hello",
                createdAt: Date(timeIntervalSince1970: 10),
                source: .runtime
            )
        )
        try store.appendTimelineUpsertEvent(
            threadID: threadID,
            item: .assistantFinal(
                id: "assistant-1",
                sessionID: threadID,
                turnID: "turn-1",
                text: "done",
                createdAt: Date(timeIntervalSince1970: 11),
                updatedAt: Date(timeIntervalSince1970: 11),
                isStreaming: false,
                providerBackend: .copilot,
                providerModelID: "gemini-3-pro-preview",
                source: .runtime
            )
        )

        let rebuilt = try XCTUnwrap(store.loadSnapshot(threadID: threadID))
        XCTAssertEqual(rebuilt.version, 2)
        XCTAssertEqual(rebuilt.transcript.map(\.text), ["hello", "done"])
        XCTAssertEqual(
            rebuilt.timeline.filter { $0.kind == .assistantFinal }.compactMap(\.text),
            ["done"]
        )
        XCTAssertEqual(rebuilt.lastAppliedEventSequence, 4)
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: store.snapshotFileURL(for: threadID)?.path ?? ""
            )
        )
    }

    func testLoadSnapshotSanitizesOrphanStreamingAssistantDuplicates() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "openassist-duplicate-cleanup"
        let snapshot = AssistantConversationSnapshot(
            version: 2,
            threadID: threadID,
            timeline: [
                .userMessage(
                    id: "user-1",
                    sessionID: threadID,
                    text: "Should i take a jacket?",
                    createdAt: Date(timeIntervalSince1970: 10),
                    source: .runtime
                ),
                .assistantFinal(
                    id: "assistant-1",
                    sessionID: threadID,
                    turnID: "turn-1",
                    text: "Yes, bring a jacket.",
                    createdAt: Date(timeIntervalSince1970: 11),
                    updatedAt: Date(timeIntervalSince1970: 11),
                    isStreaming: false,
                    providerBackend: .copilot,
                    providerModelID: "gpt-5.4",
                    source: .runtime
                ),
                .assistantFinal(
                    id: "assistant-duplicate",
                    sessionID: threadID,
                    turnID: nil,
                    text: "Yes, bring a jacket.",
                    createdAt: Date(timeIntervalSince1970: 99),
                    updatedAt: Date(timeIntervalSince1970: 99),
                    isStreaming: true,
                    providerBackend: .copilot,
                    providerModelID: "gpt-5.4",
                    source: .runtime
                )
            ],
            transcript: [
                AssistantTranscriptEntry(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
                    role: .user,
                    text: "Should i take a jacket?",
                    createdAt: Date(timeIntervalSince1970: 10)
                ),
                AssistantTranscriptEntry(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
                    role: .assistant,
                    text: "Yes, bring a jacket.",
                    createdAt: Date(timeIntervalSince1970: 11),
                    providerBackend: .copilot,
                    providerModelID: "gpt-5.4"
                ),
                AssistantTranscriptEntry(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000403")!,
                    role: .assistant,
                    text: "Yes, bring a jacket.",
                    createdAt: Date(timeIntervalSince1970: 99),
                    emphasis: false,
                    isStreaming: true,
                    providerBackend: .copilot,
                    providerModelID: "gpt-5.4"
                )
            ],
            turns: [],
            updatedAt: Date(timeIntervalSince1970: 100),
            lastAppliedEventSequence: 3
        )

        try store.rewriteHybridSnapshotAndEventLog(snapshot)

        let loaded = try XCTUnwrap(store.loadSnapshot(threadID: threadID))
        XCTAssertEqual(loaded.transcript.count, 2)
        XCTAssertEqual(
            loaded.timeline.filter { $0.kind == .assistantFinal }.count,
            1
        )
        XCTAssertEqual(
            loaded.timeline.filter { $0.kind == .assistantFinal }.first?.text,
            "Yes, bring a jacket."
        )
        XCTAssertFalse(
            loaded.transcript.contains(where: {
                $0.role == .assistant && $0.isStreaming && $0.text == "Yes, bring a jacket."
            })
        )
    }

    func testThreadNoteRoundTripsFromNotesMarkdown() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "note-thread"
        let noteText = """
        # Decisions
        - Keep notes attached to the thread
        - Save as Markdown
        """

        try store.saveThreadNote(threadID: threadID, text: noteText)

        let workspace = store.loadThreadNotesWorkspace(threadID: threadID)
        let selectedNote = try XCTUnwrap(workspace.selectedNote)
        let manifestURL = directoryURL
            .appendingPathComponent(threadID, isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        let noteURL = directoryURL
            .appendingPathComponent(threadID, isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
            .appendingPathComponent(selectedNote.fileName, isDirectory: false)

        XCTAssertEqual(workspace.selectedNoteText, noteText)
        XCTAssertEqual(workspace.notes.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: noteURL.path))
    }

    func testThreadNotesTrackSelectionAndStableOrderAcrossMultipleNotes() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "multi-note-thread"
        let first = try store.createThreadNote(threadID: threadID, title: "First note")
        let second = try store.createThreadNote(threadID: threadID, title: "Second note")
        let secondNoteID = try XCTUnwrap(second.selectedNote?.id)
        _ = try store.saveThreadNote(threadID: threadID, noteID: secondNoteID, text: "Second body")
        let firstNoteID = try XCTUnwrap(first.selectedNote?.id)
        let selectedFirst = try store.selectThreadNote(threadID: threadID, noteID: firstNoteID)

        XCTAssertEqual(selectedFirst.notes.map(\.title), ["First note", "Second note"])
        XCTAssertEqual(selectedFirst.manifest.selectedNoteID, firstNoteID)
        XCTAssertEqual(selectedFirst.selectedNote?.order, 0)
        XCTAssertEqual(selectedFirst.notes.last?.order, 1)
    }

    func testLegacyNotesMarkdownMigratesIntoManifestBackedNote() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "legacy-note-thread"
        let legacyThreadDirectory = directoryURL.appendingPathComponent(threadID, isDirectory: true)
        try fileManager.createDirectory(at: legacyThreadDirectory, withIntermediateDirectories: true)
        let legacyURL = legacyThreadDirectory.appendingPathComponent("notes.md", isDirectory: false)
        let legacyText = """
        # Migration title
        Old note text
        """
        try legacyText.write(to: legacyURL, atomically: true, encoding: .utf8)

        let workspace = store.loadThreadNotesWorkspace(threadID: threadID)

        XCTAssertEqual(workspace.notes.count, 1)
        XCTAssertEqual(workspace.selectedNote?.title, "Migration title")
        XCTAssertEqual(workspace.selectedNoteText, legacyText)
        XCTAssertFalse(fileManager.fileExists(atPath: legacyURL.path))
    }

    func testAppendToSelectedThreadNoteCreatesDefaultNoteWhenMissing() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let workspace = try store.appendToSelectedThreadNote(
            threadID: "chart-thread",
            text: """
            ## Stack Overview

            ```mermaid
            mindmap
              root((SaaS Stack))
            ```
            """
        )

        XCTAssertEqual(workspace.notes.count, 1)
        XCTAssertEqual(workspace.selectedNote?.title, "Untitled note")
        XCTAssertTrue(workspace.selectedNoteText.contains("## Stack Overview"))
        XCTAssertTrue(workspace.selectedNoteText.contains("```mermaid"))
    }

    func testAppendToSelectedThreadNoteAddsBlankLineBetweenEntries() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "append-thread"
        try store.saveThreadNote(threadID: threadID, text: "First note block")

        let workspace = try store.appendToSelectedThreadNote(
            threadID: threadID,
            text: "## Second block"
        )

        XCTAssertEqual(
            workspace.selectedNoteText,
            """
            First note block

            ## Second block
            """
        )
    }

    func testDeleteThreadArtifactsRemovesConversationFilesAndNotesTogether() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "delete-thread"
        try store.storeSnapshot(
            AssistantConversationSnapshot(
                version: 2,
                threadID: threadID,
                timeline: [],
                transcript: [],
                turns: [],
                updatedAt: Date()
            )
        )
        try store.appendTranscriptResetEvent(threadID: threadID)
        try store.saveThreadNote(threadID: threadID, text: "Delete me too")

        let snapshotURL = try XCTUnwrap(store.snapshotFileURL(for: threadID))
        let eventLogURL = try XCTUnwrap(store.eventLogFileURL(for: threadID))
        let workspace = store.loadThreadNotesWorkspace(threadID: threadID)
        let noteID = try XCTUnwrap(workspace.selectedNote?.id)
        let noteFileName = try XCTUnwrap(workspace.selectedNote?.fileName)
        let noteDirectoryURL = directoryURL
            .appendingPathComponent(threadID, isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        let manifestURL = noteDirectoryURL.appendingPathComponent("manifest.json", isDirectory: false)
        let noteURL = noteDirectoryURL.appendingPathComponent(noteFileName, isDirectory: false)
        _ = try store.saveThreadNote(
            threadID: threadID,
            noteID: noteID,
            text: "Delete me again",
            now: Date(timeIntervalSince1970: 900)
        )
        let historyOwnerDirectoryURL = directoryURL
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent("thread", isDirectory: true)
            .appendingPathComponent(threadID, isDirectory: true)

        XCTAssertTrue(fileManager.fileExists(atPath: snapshotURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: eventLogURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: noteURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: historyOwnerDirectoryURL.path))

        store.deleteThreadArtifacts(threadID: threadID)

        XCTAssertFalse(fileManager.fileExists(atPath: snapshotURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: eventLogURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: manifestURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: noteURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: historyOwnerDirectoryURL.path))
        XCTAssertEqual(store.loadThreadNote(threadID: threadID), "")
    }

    func testRestoringThreadNoteHistoryKeepsCurrentStateRecoverable() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "history-thread"
        let createdWorkspace = try store.createThreadNote(threadID: threadID, title: "Notes")
        let noteID = try XCTUnwrap(createdWorkspace.selectedNote?.id)
        let baseDate = Date(timeIntervalSince1970: 2_000)

        _ = try store.saveThreadNote(
            threadID: threadID,
            noteID: noteID,
            text: "Draft 1",
            now: baseDate
        )
        _ = try store.saveThreadNote(
            threadID: threadID,
            noteID: noteID,
            text: "Draft 2",
            now: baseDate.addingTimeInterval(60)
        )
        _ = try store.saveThreadNote(
            threadID: threadID,
            noteID: noteID,
            text: "Draft 3",
            now: baseDate.addingTimeInterval(420)
        )

        let historyBeforeRestore = store.threadNoteHistoryVersions(threadID: threadID, noteID: noteID)
        XCTAssertEqual(historyBeforeRestore.map(\.preview), ["Draft 2", "Draft 1"])

        let restoredWorkspace = try store.restoreThreadNoteHistoryVersion(
            threadID: threadID,
            noteID: noteID,
            versionID: try XCTUnwrap(historyBeforeRestore.last?.id),
            now: baseDate.addingTimeInterval(480)
        )
        XCTAssertEqual(restoredWorkspace.selectedNoteText, "Draft 1")

        let historyAfterRestore = store.threadNoteHistoryVersions(threadID: threadID, noteID: noteID)
        XCTAssertEqual(historyAfterRestore.first?.preview, "Draft 3")
    }

    func testDeletingThreadNoteMovesItToRecentlyDeletedAndRestoreWorks() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "deleted-thread"
        let createdWorkspace = try store.createThreadNote(threadID: threadID, title: "Scratch")
        let noteID = try XCTUnwrap(createdWorkspace.selectedNote?.id)
        let baseDate = Date(timeIntervalSince1970: 3_000)

        _ = try store.saveThreadNote(
            threadID: threadID,
            noteID: noteID,
            text: "Bring this back",
            now: baseDate
        )

        let deletedWorkspace = try store.deleteThreadNote(
            threadID: threadID,
            noteID: noteID,
            now: baseDate.addingTimeInterval(60)
        )
        XCTAssertTrue(deletedWorkspace.notes.isEmpty)

        let deletedNotes = store.recentlyDeletedThreadNotes(
            threadID: threadID,
            referenceDate: baseDate.addingTimeInterval(120)
        )
        XCTAssertEqual(deletedNotes.count, 1)
        XCTAssertEqual(deletedNotes.first?.preview, "Bring this back")

        let restoredWorkspace = try store.restoreDeletedThreadNote(
            threadID: threadID,
            deletedNoteID: try XCTUnwrap(deletedNotes.first?.id),
            now: baseDate.addingTimeInterval(180)
        )
        XCTAssertEqual(restoredWorkspace.notes.count, 1)
        XCTAssertEqual(restoredWorkspace.selectedNoteText, "Bring this back")
        XCTAssertTrue(
            store.recentlyDeletedThreadNotes(
                threadID: threadID,
                referenceDate: baseDate.addingTimeInterval(240)
            ).isEmpty
        )
    }

    func testSavedConversationThreadsEnumeratesSnapshotEventLogAndLegacyNotes() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let snapshotThreadID = "snapshot-thread"
        let eventLogThreadID = "event-log-thread"
        let notesThreadID = "legacy-notes-thread"

        try store.storeSnapshot(
            AssistantConversationSnapshot(
                version: 2,
                threadID: snapshotThreadID,
                timeline: [
                    .userMessage(
                        id: "snapshot-user",
                        sessionID: snapshotThreadID,
                        text: "snapshot hello",
                        createdAt: Date(timeIntervalSince1970: 10),
                        source: .runtime
                    ),
                    .assistantFinal(
                        id: "snapshot-assistant",
                        sessionID: snapshotThreadID,
                        turnID: "snapshot-turn",
                        text: "snapshot reply",
                        createdAt: Date(timeIntervalSince1970: 11),
                        updatedAt: Date(timeIntervalSince1970: 11),
                        isStreaming: false,
                        source: .runtime
                    )
                ],
                transcript: [
                    AssistantTranscriptEntry(
                        role: .user,
                        text: "snapshot hello",
                        createdAt: Date(timeIntervalSince1970: 10)
                    ),
                    AssistantTranscriptEntry(
                        role: .assistant,
                        text: "snapshot reply",
                        createdAt: Date(timeIntervalSince1970: 11)
                    )
                ],
                turns: [],
                updatedAt: Date(timeIntervalSince1970: 10),
                lastAppliedEventSequence: 0
            )
        )

        try store.appendTranscriptUpsertEvent(
            threadID: eventLogThreadID,
            entry: AssistantTranscriptEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!,
                role: .user,
                text: "event hello",
                createdAt: Date(timeIntervalSince1970: 20)
            )
        )
        try store.appendTranscriptUpsertEvent(
            threadID: eventLogThreadID,
            entry: AssistantTranscriptEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000502")!,
                role: .assistant,
                text: "event reply",
                createdAt: Date(timeIntervalSince1970: 21)
            )
        )

        let notesDirectoryURL = directoryURL
            .appendingPathComponent(notesThreadID, isDirectory: true)
        try fileManager.createDirectory(at: notesDirectoryURL, withIntermediateDirectories: true)
        let legacyNotesURL = notesDirectoryURL.appendingPathComponent("notes.md", isDirectory: false)
        let legacyNotesText = """
        # Legacy recovery note
        Some thread notes that should still be discoverable.
        """
        try legacyNotesText.write(to: legacyNotesURL, atomically: true, encoding: .utf8)

        let junkDirectoryURL = directoryURL.appendingPathComponent("junk", isDirectory: true)
        try fileManager.createDirectory(at: junkDirectoryURL, withIntermediateDirectories: true)

        try setModificationDate(Date(timeIntervalSince1970: 10), for: try XCTUnwrap(store.snapshotFileURL(for: snapshotThreadID)))
        try setModificationDate(Date(timeIntervalSince1970: 20), for: try XCTUnwrap(store.eventLogFileURL(for: eventLogThreadID)))
        try setModificationDate(Date(timeIntervalSince1970: 30), for: legacyNotesURL)

        let summaries = store.savedConversationThreads()

        XCTAssertEqual(summaries.map(\.threadID), [
            notesThreadID,
            eventLogThreadID,
            snapshotThreadID
        ])

        let snapshotSummary = try XCTUnwrap(summaries.first { $0.threadID == snapshotThreadID })
        XCTAssertTrue(snapshotSummary.hasSnapshot)
        XCTAssertFalse(snapshotSummary.hasEventLog)
        XCTAssertTrue(snapshotSummary.hasConversationContent)
        XCTAssertEqual(snapshotSummary.latestAssistantMessage, "snapshot reply")

        let eventLogSummary = try XCTUnwrap(summaries.first { $0.threadID == eventLogThreadID })
        XCTAssertFalse(eventLogSummary.hasSnapshot)
        XCTAssertTrue(eventLogSummary.hasEventLog)
        XCTAssertTrue(eventLogSummary.hasConversationContent)
        XCTAssertEqual(eventLogSummary.latestUserMessage, "event hello")
        XCTAssertEqual(eventLogSummary.latestAssistantMessage, "event reply")
        XCTAssertFalse(fileManager.fileExists(atPath: try XCTUnwrap(store.snapshotFileURL(for: eventLogThreadID)).path))

        let notesSummary = try XCTUnwrap(summaries.first { $0.threadID == notesThreadID })
        XCTAssertTrue(notesSummary.hasNotes)
        XCTAssertFalse(notesSummary.hasConversationContent)
        XCTAssertEqual(notesSummary.noteTitle, "Legacy recovery note")
    }

    func testSavedConversationThreadsCanSkipNotesOnlyThreads() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let notesThreadID = "notes-only-thread"
        let notesDirectoryURL = directoryURL
            .appendingPathComponent(notesThreadID, isDirectory: true)
        try fileManager.createDirectory(at: notesDirectoryURL, withIntermediateDirectories: true)
        let legacyNotesURL = notesDirectoryURL.appendingPathComponent("notes.md", isDirectory: false)
        try "# Just notes".write(to: legacyNotesURL, atomically: true, encoding: .utf8)

        let allSummaries = store.savedConversationThreads()
        let conversationOnlySummaries = store.savedConversationThreads(includeNotesOnly: false)

        XCTAssertTrue(allSummaries.contains(where: { $0.threadID == notesThreadID }))
        XCTAssertFalse(conversationOnlySummaries.contains(where: { $0.threadID == notesThreadID }))
    }

    func testSavedConversationThreadsCacheInvalidatesAfterMutation() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let store = AssistantConversationStore(
            fileManager: fileManager,
            baseDirectoryURL: directoryURL
        )

        let threadID = "cached-thread"
        try store.saveSnapshot(
            threadID: threadID,
            timeline: [],
            transcript: [
                AssistantTranscriptEntry(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!,
                    role: .assistant,
                    text: "cached reply",
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            ],
            session: nil
        )

        XCTAssertTrue(store.savedConversationThreads().contains { $0.threadID == threadID })

        store.deleteSnapshot(threadID: threadID)

        XCTAssertFalse(store.savedConversationThreads().contains { $0.threadID == threadID })
    }

    private func setModificationDate(_ date: Date, for fileURL: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: fileURL.path
        )
    }
}
