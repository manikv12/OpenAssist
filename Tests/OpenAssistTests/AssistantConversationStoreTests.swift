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

        XCTAssertEqual(store.loadThreadNote(threadID: threadID), noteText)
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: try XCTUnwrap(store.threadNoteFileURL(for: threadID)).path
            )
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
        let noteURL = try XCTUnwrap(store.threadNoteFileURL(for: threadID))

        XCTAssertTrue(fileManager.fileExists(atPath: snapshotURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: eventLogURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: noteURL.path))

        store.deleteThreadArtifacts(threadID: threadID)

        XCTAssertFalse(fileManager.fileExists(atPath: snapshotURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: eventLogURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: noteURL.path))
        XCTAssertEqual(store.loadThreadNote(threadID: threadID), "")
    }
}
