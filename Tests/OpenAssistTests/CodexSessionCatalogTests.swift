import Foundation
import XCTest
@testable import OpenAssist

final class CodexSessionCatalogTests: XCTestCase {
    func testLoadSessionsMapsSourcesAndAppliesPreferredOrdering() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "cli-session",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "cli-session",
                    timestamp: "2026-03-07T10:00:00Z",
                    cwd: "/Users/test/Newest",
                    source: "cli",
                    originator: "codex_cli_rs"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T10:00:01Z",
                    role: "user",
                    text: "<environment_context>\n  <cwd>/Users/test/Newest</cwd>\n</environment_context>"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T10:00:02Z",
                    role: "user",
                    text: "## My request for Codex:\nRefactor toolbar layout"
                ),
                try turnContextLine(
                    timestamp: "2026-03-07T10:00:03Z",
                    model: "gpt-5.4"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T10:00:04Z",
                    role: "assistant",
                    text: "Done refactoring the toolbar."
                ),
                try eventLine(
                    timestamp: "2026-03-07T10:00:05Z",
                    eventType: "task_complete",
                    payload: [
                        "turn_id": "turn-cli",
                        "last_agent_message": "Done refactoring the toolbar."
                    ]
                )
            ]
        )

        try writeSession(
            id: "preferred-cwd",
            dayPath: "2026/03/06",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "preferred-cwd",
                    timestamp: "2026-03-06T09:00:00Z",
                    cwd: "/Users/test/Preferred",
                    source: "vscode",
                    originator: "Codex Desktop"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-06T09:00:01Z",
                    role: "user",
                    text: "## My request for Codex:\nReview the memory view"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-06T09:00:02Z",
                    role: "assistant",
                    text: "I checked the memory view."
                )
            ]
        )

        try writeSession(
            id: "preferred-thread",
            dayPath: "2026/03/05",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "preferred-thread",
                    timestamp: "2026-03-05T08:00:00Z",
                    cwd: "/Users/test/App",
                    source: "exec",
                    originator: "Open Assist"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-05T08:00:01Z",
                    role: "user",
                    text: "## My request for Codex:\nSync assistant window"
                ),
                try turnContextLine(
                    timestamp: "2026-03-05T08:00:02Z",
                    model: "gpt-5.3"
                ),
                try eventLine(
                    timestamp: "2026-03-05T08:00:03Z",
                    eventType: "task_complete",
                    payload: [
                        "turn_id": "turn-app",
                        "last_agent_message": "Synced the assistant window."
                    ]
                )
            ]
        )

        try writeSession(
            id: "source-object",
            dayPath: "2026/03/04",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "source-object",
                    timestamp: "2026-03-04T07:00:00Z",
                    cwd: "/Users/test/Subagent",
                    source: [
                        "subagent": [
                            "thread_spawn": [
                                "parent_thread_id": "parent-1"
                            ]
                        ]
                    ],
                    originator: "Codex Desktop"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-04T07:00:01Z",
                    role: "user",
                    text: "## My request for Codex:\nInspect the cleanup flow"
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let sessions = try await catalog.loadSessions(
            limit: 10,
            preferredThreadID: "preferred-thread",
            preferredCWD: "/Users/test/Preferred"
        )

        XCTAssertEqual(
            sessions.map(\.id),
            ["preferred-thread", "preferred-cwd", "cli-session", "source-object"]
        )

        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        XCTAssertEqual(sessionsByID["cli-session"]?.source, .cli)
        XCTAssertEqual(sessionsByID["cli-session"]?.title, "Refactor toolbar layout")
        XCTAssertEqual(sessionsByID["cli-session"]?.status, .completed)
        XCTAssertEqual(sessionsByID["cli-session"]?.latestModel, "gpt-5.4")

        XCTAssertEqual(sessionsByID["preferred-cwd"]?.source, .vscode)
        XCTAssertEqual(sessionsByID["preferred-thread"]?.source, .appServer)
        XCTAssertEqual(sessionsByID["preferred-thread"]?.status, .completed)
        XCTAssertEqual(
            sessionsByID["preferred-thread"]?.latestAssistantSnippet,
            "Synced the assistant window."
        )
        XCTAssertEqual(sessionsByID["source-object"]?.source, .other)
        XCTAssertEqual(sessionsByID["source-object"]?.parentThreadID, "parent-1")
    }

    func testLoadSessionsRestoresLatestAgenticConfigurationFromTurnContext() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "restore-agentic",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "restore-agentic",
                    timestamp: "2026-03-07T13:00:00Z",
                    cwd: "/Users/test/OpenAssist",
                    source: "exec",
                    originator: "Open Assist"
                ),
                try turnContextLine(
                    timestamp: "2026-03-07T13:00:01Z",
                    model: "gpt-5.4",
                    approvalPolicy: "untrusted",
                    collaborationMode: "default"
                ),
                try turnContextLine(
                    timestamp: "2026-03-07T13:05:00Z",
                    model: "gpt-5.4-codex",
                    approvalPolicy: "on-request",
                    collaborationMode: "default",
                    reasoningEffort: "xhigh",
                    serviceTier: "fast"
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let sessions = try await catalog.loadSessions(limit: 5)
        let summary = try XCTUnwrap(sessions.first(where: { $0.id == "restore-agentic" }))

        XCTAssertEqual(summary.latestModel, "gpt-5.4-codex")
        XCTAssertEqual(summary.latestInteractionMode, .agentic)
        XCTAssertEqual(summary.latestReasoningEffort, .xhigh)
        XCTAssertEqual(summary.latestServiceTier, "fast")
        XCTAssertTrue(summary.fastModeEnabled)
    }

    func testLoadSessionsRestoresPlanConfigurationFromTurnContext() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "restore-plan",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "restore-plan",
                    timestamp: "2026-03-07T14:00:00Z",
                    cwd: "/Users/test/OpenAssist",
                    source: "exec",
                    originator: "Open Assist"
                ),
                try turnContextLine(
                    timestamp: "2026-03-07T14:00:01Z",
                    model: "gpt-5.4",
                    approvalPolicy: "on-request",
                    collaborationMode: "plan",
                    reasoningEffort: "high"
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let sessions = try await catalog.loadSessions(limit: 5)
        let summary = try XCTUnwrap(sessions.first(where: { $0.id == "restore-plan" }))

        XCTAssertEqual(summary.latestInteractionMode, .plan)
        XCTAssertEqual(summary.latestReasoningEffort, .high)
    }

    func testLoadSessionsCanFilterToOpenAssistOriginatorOnly() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "openassist-session",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "openassist-session",
                    timestamp: "2026-03-07T10:00:00Z",
                    cwd: "/Users/test/OpenAssist",
                    source: "vscode",
                    originator: "Open Assist"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T10:00:01Z",
                    role: "user",
                    text: "## My request for Codex:\nOpen my Open Assist assistant"
                )
            ]
        )

        try writeSession(
            id: "other-session",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "other-session",
                    timestamp: "2026-03-07T11:00:00Z",
                    cwd: "/Users/test/Other",
                    source: "vscode",
                    originator: "Codex Desktop"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T11:00:01Z",
                    role: "user",
                    text: "## My request for Codex:\nThis should stay hidden"
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let sessions = try await catalog.loadSessions(
            limit: 10,
            preferredThreadID: nil,
            preferredCWD: nil,
            originatorFilter: "Open Assist"
        )

        XCTAssertEqual(sessions.map(\.id), ["openassist-session"])
        XCTAssertEqual(sessions.first?.source, .appServer)
    }

    func testLoadSessionsCanLimitToKnownSessionIDs() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "openassist-session",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "openassist-session",
                    timestamp: "2026-03-07T10:00:00Z",
                    cwd: "/Users/test/OpenAssist",
                    source: "exec",
                    originator: "Open Assist"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T10:00:01Z",
                    role: "assistant",
                    text: "This session belongs to Open Assist."
                )
            ]
        )

        try writeSession(
            id: "other-session",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "other-session",
                    timestamp: "2026-03-07T11:00:00Z",
                    cwd: "/Users/test/Other",
                    source: "vscode",
                    originator: "Codex Desktop"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T11:00:01Z",
                    role: "assistant",
                    text: "This session should stay hidden."
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let sessions = try await catalog.loadSessions(
            limit: 10,
            preferredThreadID: nil,
            preferredCWD: nil,
            sessionIDs: ["openassist-session"]
        )

        XCTAssertEqual(sessions.map(\.id), ["openassist-session"])
        XCTAssertEqual(sessions.first?.source, .appServer)
    }

    func testLoadSessionsAndTranscriptStripInternalImagePlaceholders() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "image-session",
            dayPath: "2026/03/09",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "image-session",
                    timestamp: "2026-03-09T20:54:00Z",
                    cwd: "/Users/test/Images",
                    source: "vscode",
                    originator: "Open Assist"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-09T20:54:01Z",
                    role: "user",
                    text: "<image> </image> What does the dead letter mean here?"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-09T20:54:02Z",
                    role: "assistant",
                    text: "Dead-letter usually means messages were moved aside after repeated delivery failure."
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let sessions = try await catalog.loadSessions(limit: 10)
        let transcript = await catalog.loadTranscript(sessionID: "image-session")

        XCTAssertEqual(sessions.first?.latestUserMessage, "What does the dead letter mean here?")
        XCTAssertEqual(transcript.first(where: { $0.role == .user })?.text, "What does the dead letter mean here?")
    }

    func testLoadSessionsReadsLargeSessionWithoutFullListParse() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let largeReasoning = String(repeating: "x", count: 320_000)

        try writeSession(
            id: "large-session",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "large-session",
                    timestamp: "2026-03-07T10:00:00Z",
                    cwd: "/Users/test/Large",
                    source: "exec",
                    originator: "Open Assist"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T10:00:01Z",
                    role: "assistant",
                    text: largeReasoning
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T10:00:02Z",
                    role: "user",
                    text: "## My request for Codex:\nShip the export fix"
                ),
                try turnContextLine(
                    timestamp: "2026-03-07T10:00:03Z",
                    model: "gpt-5.4"
                ),
                try eventLine(
                    timestamp: "2026-03-07T10:00:04Z",
                    eventType: "task_complete",
                    payload: [
                        "turn_id": "turn-large",
                        "last_agent_message": "Export fix is ready."
                    ]
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let sessions = try await catalog.loadSessions(limit: 10)

        XCTAssertEqual(sessions.map(\.id), ["large-session"])
        XCTAssertEqual(sessions.first?.title, "Ship the export fix")
        XCTAssertEqual(sessions.first?.latestModel, "gpt-5.4")
        XCTAssertEqual(sessions.first?.status, .completed)
        XCTAssertEqual(sessions.first?.latestAssistantSnippet, "Export fix is ready.")
    }

    func testLoadSessionsPrefersSavedThreadNameFromSessionIndex() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "stable-title-session",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "stable-title-session",
                    timestamp: "2026-03-07T10:00:00Z",
                    cwd: "/Users/test/StableTitle",
                    source: "exec",
                    originator: "Open Assist"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T10:00:01Z",
                    role: "user",
                    text: "First task title"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T10:05:00Z",
                    role: "user",
                    text: "Later follow-up message that should not replace the saved title"
                )
            ]
        )
        try writeSessionIndex(
            entries: [
                [
                    "id": "stable-title-session",
                    "thread_name": "Friendly Stable Title",
                    "updated_at": "2026-03-07T10:06:00Z"
                ]
            ],
            in: homeDirectory
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let sessions = try await catalog.loadSessions(limit: 10)

        XCTAssertEqual(sessions.map(\.id), ["stable-title-session"])
        XCTAssertEqual(sessions.first?.title, "Friendly Stable Title")
    }

    func testRenameSessionUpdatesSessionIndexThreadName() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "rename-me",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "rename-me",
                    timestamp: "2026-03-07T10:00:00Z",
                    cwd: "/Users/test/RenameMe",
                    source: "exec",
                    originator: "Open Assist"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T10:00:01Z",
                    role: "user",
                    text: "Original name"
                )
            ]
        )
        try writeSessionIndex(
            entries: [
                [
                    "id": "rename-me",
                    "thread_name": "Old Thread Name",
                    "updated_at": "2026-03-07T10:01:00Z"
                ]
            ],
            in: homeDirectory
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        try catalog.renameSession(sessionID: "rename-me", title: "New Friendly Name")

        let sessions = try await catalog.loadSessions(limit: 10)
        XCTAssertEqual(sessions.first?.title, "New Friendly Name")

        let indexContents = try String(
            contentsOf: homeDirectory.appendingPathComponent(".codex/session_index.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(indexContents.contains("\"thread_name\":\"New Friendly Name\""))
        XCTAssertEqual(indexContents.split(whereSeparator: \.isNewline).count, 1)
        XCTAssertTrue(indexContents.hasSuffix("\n"))
    }

    func testLoadSessionsRecoversThreadNameFromConcatenatedSessionIndexLines() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "named-session",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "named-session",
                    timestamp: "2026-03-07T10:00:00Z",
                    cwd: "/Users/test/NamedSession",
                    source: "exec",
                    originator: "Open Assist"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T10:00:01Z",
                    role: "user",
                    text: "Latest follow-up that should not become the title"
                )
            ]
        )

        let codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let indexURL = codexDirectory.appendingPathComponent("session_index.jsonl")
        let corruptedContents = """
        {"id":"named-session","thread_name":"Pinned Friendly Name","updated_at":"2026-03-07T10:05:00Z"}{"id":"other-session","thread_name":"Other Name","updated_at":"2026-03-07T10:06:00Z"}
        """
        try corruptedContents.write(to: indexURL, atomically: true, encoding: .utf8)

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let sessions = try await catalog.loadSessions(limit: 10)

        XCTAssertEqual(sessions.first?.id, "named-session")
        XCTAssertEqual(sessions.first?.title, "Pinned Friendly Name")
    }

    func testRenameSessionPreservesIncompleteIndexEntries() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "rename-me",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "rename-me",
                    timestamp: "2026-03-07T10:00:00Z",
                    cwd: "/Users/test/RenameMe",
                    source: "exec",
                    originator: "Open Assist"
                )
            ]
        )
        try writeSessionIndex(
            entries: [
                [
                    "id": "rename-me",
                    "thread_name": "Old Thread Name",
                    "updated_at": "2026-03-07T10:01:00Z"
                ],
                [
                    "id": "legacy-entry",
                    "updated_at": "2026-03-07T10:02:00Z"
                ],
                [
                    "thread_name": "Untitled Legacy Entry",
                    "updated_at": "2026-03-07T10:03:00Z"
                ]
            ],
            in: homeDirectory
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        try catalog.renameSession(sessionID: "rename-me", title: "New Friendly Name")

        let indexContents = try String(
            contentsOf: homeDirectory.appendingPathComponent(".codex/session_index.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(indexContents.contains("\"thread_name\":\"New Friendly Name\""))
        XCTAssertTrue(indexContents.contains("\"id\":\"legacy-entry\""))
        XCTAssertTrue(indexContents.contains("\"thread_name\":\"Untitled Legacy Entry\""))
        XCTAssertEqual(indexContents.split(whereSeparator: \.isNewline).count, 3)
    }

    func testLoadSessionsRestoresArchiveMetadataFromSessionIndex() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "archived-session",
            dayPath: "2026/03/08",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "archived-session",
                    timestamp: "2026-03-08T08:00:00Z",
                    cwd: "/Users/test/Archived",
                    source: "exec",
                    originator: "Open Assist"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-08T08:00:01Z",
                    role: "user",
                    text: "Archive me"
                )
            ]
        )
        try writeSessionIndex(
            entries: [
                [
                    "id": "archived-session",
                    "thread_name": "Archived Friendly Name",
                    "archived": true,
                    "archived_at": "2026-03-08T09:00:00Z",
                    "archive_expires_at": "2026-03-09T09:00:00Z",
                    "archive_uses_default_retention": true
                ]
            ],
            in: homeDirectory
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let sessions = try await catalog.loadSessions(limit: 10)
        let session = try XCTUnwrap(sessions.first(where: { $0.id == "archived-session" }))

        XCTAssertEqual(session.title, "Archived Friendly Name")
        XCTAssertTrue(session.isArchived)
        XCTAssertEqual(session.archivedAt, ISO8601DateFormatter().date(from: "2026-03-08T09:00:00Z"))
        XCTAssertEqual(session.archiveExpiresAt, ISO8601DateFormatter().date(from: "2026-03-09T09:00:00Z"))
        XCTAssertEqual(session.archiveUsesDefaultRetention, true)
    }

    func testUnarchiveSessionClearsArchiveMetadataButKeepsThreadName() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "archive-clear",
            dayPath: "2026/03/08",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "archive-clear",
                    timestamp: "2026-03-08T08:00:00Z",
                    cwd: "/Users/test/ArchiveClear",
                    source: "exec",
                    originator: "Open Assist"
                )
            ]
        )
        try writeSessionIndex(
            entries: [
                [
                    "id": "archive-clear",
                    "thread_name": "Keep My Name",
                    "archived": true,
                    "archived_at": "2026-03-08T09:00:00Z",
                    "archive_expires_at": "2026-03-09T09:00:00Z"
                ]
            ],
            in: homeDirectory
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        try catalog.unarchiveSession(sessionID: "archive-clear")

        let sessions = try await catalog.loadSessions(limit: 10)
        let session = try XCTUnwrap(sessions.first(where: { $0.id == "archive-clear" }))
        XCTAssertEqual(session.title, "Keep My Name")
        XCTAssertFalse(session.isArchived)
        XCTAssertNil(session.archivedAt)
        XCTAssertNil(session.archiveExpiresAt)
        XCTAssertNil(session.archiveUsesDefaultRetention)

        let indexContents = try String(
            contentsOf: homeDirectory.appendingPathComponent(".codex/session_index.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(indexContents.contains("\"thread_name\":\"Keep My Name\""))
        XCTAssertFalse(indexContents.contains("\"archived\":true"))
        XCTAssertFalse(indexContents.contains("\"archive_expires_at\""))
    }

    func testExpiredArchivedSessionIDsReturnsOnlyExpiredEntries() throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSessionIndex(
            entries: [
                [
                    "id": "expired-session",
                    "archived": true,
                    "archive_expires_at": "2026-03-08T09:00:00Z"
                ],
                [
                    "id": "future-session",
                    "archived": true,
                    "archive_expires_at": "2026-03-12T09:00:00Z"
                ],
                [
                    "id": "active-session",
                    "thread_name": "Still active"
                ]
            ],
            in: homeDirectory
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let expired = catalog.expiredArchivedSessionIDs(
            asOf: ISO8601DateFormatter().date(from: "2026-03-10T09:00:00Z")!
        )

        XCTAssertEqual(Set(expired), Set(["expired-session"]))
    }

    func testDeleteSessionSynchronouslyRemovesMatchingSessionIndexEntry() throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "delete-me",
            dayPath: "2026/03/08",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "delete-me",
                    timestamp: "2026-03-08T08:00:00Z",
                    cwd: "/Users/test/DeleteMe",
                    source: "exec",
                    originator: "Open Assist"
                )
            ]
        )
        try writeSessionIndex(
            entries: [
                [
                    "id": "delete-me",
                    "thread_name": "Delete Me"
                ],
                [
                    "id": "keep-me",
                    "thread_name": "Keep Me"
                ]
            ],
            in: homeDirectory
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let deleted = try catalog.deleteSessionSynchronously(sessionID: "delete-me")
        XCTAssertTrue(deleted)

        let indexContents = try String(
            contentsOf: homeDirectory.appendingPathComponent(".codex/session_index.jsonl"),
            encoding: .utf8
        )
        XCTAssertFalse(indexContents.contains("\"id\":\"delete-me\""))
        XCTAssertTrue(indexContents.contains("\"id\":\"keep-me\""))
    }

    func testLoadTranscriptFiltersSetupNoiseAndDeduplicatesAgentEchoes() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "transcript-session",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "transcript-session",
                    timestamp: "2026-03-07T12:00:00Z",
                    cwd: "/Users/test/App",
                    source: "exec"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T12:00:01Z",
                    role: "user",
                    text: "<environment_context>\n  <cwd>/Users/test/App</cwd>\n</environment_context>"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T12:00:02Z",
                    role: "user",
                    text: "# Context from my IDE setup:\n\n## My request for Codex:\nPlease fix the spacing"
                ),
                try eventLine(
                    timestamp: "2026-03-07T12:00:02Z",
                    eventType: "user_message",
                    payload: [
                        "message": "# Context from my IDE setup:\n\n## My request for Codex:\nPlease fix the spacing"
                    ]
                ),
                try eventLine(
                    timestamp: "2026-03-07T12:00:03Z",
                    eventType: "agent_message",
                    payload: [
                        "message": "I'm checking the spacing now."
                    ]
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T12:00:04Z",
                    role: "assistant",
                    text: "I tightened the spacing."
                ),
                try eventLine(
                    timestamp: "2026-03-07T12:00:04Z",
                    eventType: "agent_message",
                    payload: [
                        "message": "I tightened the spacing."
                    ]
                ),
                try eventLine(
                    timestamp: "2026-03-07T12:00:05Z",
                    eventType: "turn_aborted",
                    payload: [
                        "reason": "interrupted"
                    ]
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let transcript = await catalog.loadTranscript(sessionID: "transcript-session")

        XCTAssertEqual(transcript.map(\.role), [.system, .user, .assistant, .assistant, .status])
        XCTAssertEqual(transcript.first?.text, "Started an Open Assist session.")
        XCTAssertEqual(transcript[1].text, "Please fix the spacing")
        XCTAssertEqual(transcript[2].text, "I'm checking the spacing now.")
        XCTAssertEqual(transcript[3].text, "I tightened the spacing.")
        XCTAssertEqual(transcript[4].text, "Task stopped.")
    }

    func testLoadTranscriptCollapsesInlineAttachmentPayloadsToFilenameOnly() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let responseItem = try jsonLine([
            "timestamp": "2026-03-07T12:30:00Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": "[RES Internal Charter 3.26.26.docx]\n" + String(repeating: "UEsDBBQAAAAIA", count: 40)
                    ],
                    [
                        "type": "input_text",
                        "text": "Please summarize the charter."
                    ]
                ]
            ]
        ])

        try writeSession(
            id: "attachment-collapse",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "attachment-collapse",
                    timestamp: "2026-03-07T12:29:59Z",
                    cwd: "/Users/test/App",
                    source: "exec"
                ),
                responseItem
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let transcript = await catalog.loadTranscript(sessionID: "attachment-collapse")

        XCTAssertEqual(transcript.map(\.role), [.system, .user])
        XCTAssertEqual(
            transcript[1].text,
            "[RES Internal Charter 3.26.26.docx]\n\nPlease summarize the charter."
        )
    }

    func testSessionIndexIgnoresSyntheticSessionMemoryTitle() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "memory-title",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "memory-title",
                    timestamp: "2026-03-07T10:00:00Z",
                    cwd: "/Users/test/App",
                    source: "exec"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T10:00:01Z",
                    role: "user",
                    text: "## My request for Codex:\nFix the title"
                )
            ]
        )

        let sessionIndexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionIndexDirectory, withIntermediateDirectories: true)
        let sessionIndexURL = sessionIndexDirectory.appendingPathComponent("session-index.jsonl", isDirectory: false)
        let badIndexLine = try jsonLine([
            "id": "memory-title",
            "thread_name": "# Session Memory Use this as context for the next reply.",
            "updated_at": "2026-03-07T10:00:02Z"
        ])
        try (badIndexLine + "\n").write(to: sessionIndexURL, atomically: true, encoding: .utf8)

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let sessions = try await catalog.loadSessions(limit: 5)

        XCTAssertEqual(sessions.first(where: { $0.id == "memory-title" })?.title, "Fix the title")
    }

    func testLoadMergedTimelineClassifiesSavedToolRecordsAndCache() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let sessionID = "timeline-session"
        let activityStore = AssistantSessionActivityStore(homeDirectory: homeDirectory)
        activityStore.saveTimeline(
            [
                .assistantProgress(
                    id: "cached-progress",
                    sessionID: sessionID,
                    text: "I found the assistant runtime and window views.",
                    createdAt: Date(timeIntervalSince1970: 1_741_348_001),
                    updatedAt: Date(timeIntervalSince1970: 1_741_348_001),
                    isStreaming: false,
                    source: .cache
                ),
                .assistantFinal(
                    id: "skip-final",
                    sessionID: sessionID,
                    text: "This should not be saved in the cache.",
                    createdAt: Date(),
                    updatedAt: Date(),
                    isStreaming: false,
                    source: .cache
                )
            ],
            sessionID: sessionID
        )

        try writeSession(
            id: sessionID,
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: sessionID,
                    timestamp: "2026-03-07T12:00:00Z",
                    cwd: "/Users/test/OpenAssist",
                    source: "exec",
                    originator: "Open Assist"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-07T12:00:01Z",
                    role: "user",
                    text: "## My request for Codex:\nCheck why the assistant text is flattened"
                ),
                try eventLine(
                    timestamp: "2026-03-07T12:00:02Z",
                    eventType: "agent_message",
                    payload: [
                        "message": "I’m tracing the runtime and renderer now.",
                        "phase": "commentary"
                    ]
                ),
                try functionCallLine(
                    timestamp: "2026-03-07T12:00:03Z",
                    name: "exec_command",
                    arguments: "{\"cmd\":\"rg --files Sources/OpenAssist/Assistant\"}",
                    callID: "call-command"
                ),
                try functionCallOutputLine(
                    timestamp: "2026-03-07T12:00:04Z",
                    callID: "call-command",
                    output: "Output:\nSources/OpenAssist/Assistant/AssistantWindowView.swift"
                ),
                try webSearchCallLine(
                    timestamp: "2026-03-07T12:00:05Z",
                    query: "codex app server item agentMessage delta"
                ),
                try customToolCallLine(
                    timestamp: "2026-03-07T12:00:06Z",
                    name: "apply_patch",
                    input: "*** Begin Patch\n*** Update File: Sources/OpenAssist/Assistant/AssistantWindowView.swift\n*** End Patch",
                    callID: "call-patch"
                ),
                try customToolCallOutputLine(
                    timestamp: "2026-03-07T12:00:07Z",
                    callID: "call-patch",
                    output: "{\"output\":\"Success. Updated the following files:\\nM Sources/OpenAssist/Assistant/AssistantWindowView.swift\\n\"}"
                ),
                try eventLine(
                    timestamp: "2026-03-07T12:00:08Z",
                    eventType: "agent_message",
                    payload: [
                        "message": "I separated the timeline rows and kept the final answer readable.",
                        "phase": "final_answer"
                    ]
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory, activityStore: activityStore)
        let timeline = await catalog.loadMergedTimeline(sessionID: sessionID)

        XCTAssertTrue(timeline.contains(where: { $0.kind == .userMessage }))
        XCTAssertTrue(timeline.contains(where: { $0.id == "cached-progress" && $0.kind == .assistantProgress }))
        XCTAssertTrue(timeline.contains(where: {
            $0.kind == .assistantFinal
                && $0.text == "I separated the timeline rows and kept the final answer readable."
        }))

        let activityByID = Dictionary(uniqueKeysWithValues: timeline.compactMap { item in
            item.activity.map { ($0.id, $0) }
        })

        XCTAssertEqual(activityByID["call-command"]?.kind, .commandExecution)
        XCTAssertTrue(activityByID["call-command"]?.rawDetails?.contains("rg --files") == true)

        let webSearch = try XCTUnwrap(timeline.first(where: { $0.activity?.kind == .webSearch })?.activity)
        XCTAssertEqual(webSearch.rawDetails, "codex app server item agentMessage delta")

        XCTAssertEqual(activityByID["call-patch"]?.kind, .fileChange)
        XCTAssertTrue(activityByID["call-patch"]?.rawDetails?.contains("Updated the following files") == true)
    }

    func testLoadMergedTimelineReplaysGeneratedImagesFromCustomToolOutput() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let sessionID = "timeline-generated-image"
        let pngData = Data([0x89, 0x50, 0x4E, 0x47])
        let base64 = pngData.base64EncodedString()
        let output = """
        {"content":[{"type":"inputText","text":"Generated an image with Google Gemini."},{"type":"inputImage","image_url":{"url":"data:image/png;base64,\(base64)"}}]}
        """

        try writeSession(
            id: sessionID,
            dayPath: "2026/03/09",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: sessionID,
                    timestamp: "2026-03-09T10:00:00Z",
                    cwd: "/Users/test/OpenAssist",
                    source: "exec",
                    originator: "Open Assist"
                ),
                try customToolCallLine(
                    timestamp: "2026-03-09T10:00:01Z",
                    name: "generate_image",
                    input: "{\"prompt\":\"Create a playful banana robot mascot\"}",
                    callID: "call-image"
                ),
                try customToolCallOutputLine(
                    timestamp: "2026-03-09T10:00:02Z",
                    callID: "call-image",
                    output: output
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let timeline = await catalog.loadMergedTimeline(sessionID: sessionID)

        let activity = try XCTUnwrap(
            timeline.first(where: { $0.activity?.id == "call-image" })?.activity
        )
        XCTAssertEqual(activity.kind, .dynamicToolCall)
        XCTAssertEqual(activity.title, "Image Generation")
        XCTAssertEqual(activity.friendlySummary, "Generated an image.")

        let imageItem = try XCTUnwrap(
            timeline.first(where: {
                $0.kind == .system
                    && $0.text == "Generated image"
                    && $0.imageAttachments?.isEmpty == false
            })
        )
        XCTAssertEqual(imageItem.imageAttachments, [pngData])
    }

    func testActivityStoreOnlyPersistsCacheableTimelineItems() throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let store = AssistantSessionActivityStore(homeDirectory: homeDirectory)
        store.saveTimeline(
            [
                .userMessage(sessionID: "cache-test", text: "User text", createdAt: Date(), source: .runtime),
                .assistantFinal(
                    id: "assistant-final",
                    sessionID: "cache-test",
                    text: "Final answer",
                    createdAt: Date(),
                    updatedAt: Date(),
                    isStreaming: false,
                    source: .runtime
                ),
                .assistantProgress(
                    id: "assistant-progress",
                    sessionID: "cache-test",
                    text: "Progress update",
                    createdAt: Date(),
                    updatedAt: Date(),
                    isStreaming: false,
                    source: .runtime
                ),
                .activity(
                    AssistantActivityItem(
                        id: "activity-1",
                        sessionID: "cache-test",
                        turnID: nil,
                        kind: .commandExecution,
                        title: "Command",
                        status: .completed,
                        friendlySummary: "Ran a terminal command.",
                        rawDetails: "pwd",
                        startedAt: Date(),
                        updatedAt: Date(),
                        source: .runtime
                    )
                )
            ],
            sessionID: "cache-test"
        )

        let loaded = store.loadTimeline(sessionID: "cache-test")
        XCTAssertEqual(Set(loaded.map(\.kind)), Set([.assistantProgress, .activity]))
    }

    func testLoadMergedTimelineDeduplicatesTaskCompleteEchoAfterLongRun() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let sessionID = "timeline-task-complete-echo"
        try writeSession(
            id: sessionID,
            dayPath: "2026/03/08",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: sessionID,
                    timestamp: "2026-03-08T09:00:00Z",
                    cwd: "/Users/test/OpenAssist",
                    source: "exec",
                    originator: "Open Assist"
                ),
                try responseMessageLine(
                    timestamp: "2026-03-08T09:00:01Z",
                    role: "assistant",
                    text: "I finished the cleanup and the session list now stays stable."
                ),
                try eventLine(
                    timestamp: "2026-03-08T09:01:10Z",
                    eventType: "task_complete",
                    payload: [
                        "last_agent_message": "I finished the cleanup and the session list now stays stable."
                    ]
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let timeline = await catalog.loadMergedTimeline(sessionID: sessionID)
        let matchingFinals = timeline.filter {
            $0.kind == .assistantFinal
                && $0.text == "I finished the cleanup and the session list now stays stable."
        }

        XCTAssertEqual(matchingFinals.count, 1)
    }

    func testDeleteSessionsRemovesOnlyRequestedOpenAssistFiles() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        try writeSession(
            id: "delete-me",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "delete-me",
                    timestamp: "2026-03-07T12:00:00Z",
                    cwd: "/Users/test/DeleteMe",
                    source: "exec",
                    originator: "Open Assist"
                )
            ]
        )

        try writeSession(
            id: "keep-me",
            dayPath: "2026/03/07",
            in: homeDirectory,
            lines: [
                try sessionMetaLine(
                    id: "keep-me",
                    timestamp: "2026-03-07T12:01:00Z",
                    cwd: "/Users/test/KeepMe",
                    source: "exec",
                    originator: "Open Assist"
                )
            ]
        )

        let catalog = CodexSessionCatalog(homeDirectory: homeDirectory)
        let deletedCount = try await catalog.deleteSessions(sessionIDs: ["delete-me"])

        XCTAssertEqual(deletedCount, 1)
        let sessions = try await catalog.loadSessions(
            limit: 10,
            preferredThreadID: nil,
            preferredCWD: nil,
            sessionIDs: ["delete-me", "keep-me"]
        )
        XCTAssertEqual(sessions.map(\.id), ["keep-me"])
    }

    private func makeTemporaryHomeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAssistCodexCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSession(
        id: String,
        dayPath: String,
        in homeDirectory: URL,
        lines: [String]
    ) throws {
        let sessionDirectory = homeDirectory
            .appendingPathComponent(".codex/sessions", isDirectory: true)
            .appendingPathComponent(dayPath, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let filename = "rollout-\(dayPath.replacingOccurrences(of: "/", with: "-"))-\(id).jsonl"
        let fileURL = sessionDirectory.appendingPathComponent(filename)
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func writeSessionIndex(
        entries: [[String: Any]],
        in homeDirectory: URL
    ) throws {
        let codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let indexURL = codexDirectory.appendingPathComponent("session_index.jsonl")
        let lines = try entries.map(jsonLine)
        try (lines.joined(separator: "\n") + "\n").write(to: indexURL, atomically: true, encoding: .utf8)
    }

    private func sessionMetaLine(
        id: String,
        timestamp: String,
        cwd: String,
        source: Any,
        originator: String? = nil
    ) throws -> String {
        var payload: [String: Any] = [
            "id": id,
            "timestamp": timestamp,
            "cwd": cwd,
            "source": source
        ]
        if let originator {
            payload["originator"] = originator
        }

        return try jsonLine([
            "timestamp": timestamp,
            "type": "session_meta",
            "payload": payload
        ])
    }

    private func responseMessageLine(
        timestamp: String,
        role: String,
        text: String
    ) throws -> String {
        let contentType = role == "assistant" ? "output_text" : "input_text"
        return try jsonLine([
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": role,
                "content": [
                    [
                        "type": contentType,
                        "text": text
                    ]
                ]
            ]
        ])
    }

    private func turnContextLine(
        timestamp: String,
        model: String,
        approvalPolicy: String? = nil,
        collaborationMode: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil
    ) throws -> String {
        var payload: [String: Any] = [
            "model": model
        ]
        if let approvalPolicy {
            payload["approval_policy"] = approvalPolicy
        }
        if let collaborationMode {
            var settings: [String: Any] = ["model": model]
            if let reasoningEffort {
                settings["reasoning_effort"] = reasoningEffort
            }
            if let serviceTier {
                settings["service_tier"] = serviceTier
            }
            payload["collaboration_mode"] = [
                "mode": collaborationMode,
                "settings": settings
            ]
        }
        return try jsonLine([
            "timestamp": timestamp,
            "type": "turn_context",
            "payload": payload
        ])
    }

    private func eventLine(
        timestamp: String,
        eventType: String,
        payload: [String: Any]
    ) throws -> String {
        var wrappedPayload = payload
        wrappedPayload["type"] = eventType
        return try jsonLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": wrappedPayload
        ])
    }

    private func functionCallLine(
        timestamp: String,
        name: String,
        arguments: String,
        callID: String
    ) throws -> String {
        try jsonLine([
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "function_call",
                "name": name,
                "arguments": arguments,
                "call_id": callID
            ]
        ])
    }

    private func functionCallOutputLine(
        timestamp: String,
        callID: String,
        output: String
    ) throws -> String {
        try jsonLine([
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "function_call_output",
                "call_id": callID,
                "output": output
            ]
        ])
    }

    private func webSearchCallLine(
        timestamp: String,
        query: String
    ) throws -> String {
        try jsonLine([
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "web_search_call",
                "status": "completed",
                "action": [
                    "type": "search",
                    "query": query
                ]
            ]
        ])
    }

    private func customToolCallLine(
        timestamp: String,
        name: String,
        input: String,
        callID: String
    ) throws -> String {
        try jsonLine([
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call",
                "status": "completed",
                "call_id": callID,
                "name": name,
                "input": input
            ]
        ])
    }

    private func customToolCallOutputLine(
        timestamp: String,
        callID: String,
        output: String
    ) throws -> String {
        try jsonLine([
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call_output",
                "call_id": callID,
                "output": output
            ]
        ])
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
