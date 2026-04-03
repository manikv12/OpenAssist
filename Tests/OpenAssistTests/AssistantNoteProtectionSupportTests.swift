import Foundation
import XCTest
@testable import OpenAssist

final class AssistantNoteProtectionSupportTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testRecoveryStorePurgesDeletedNotesAfterThirtyDays() throws {
        let recoveryRoot = try makeTemporaryDirectory(named: "assistant-note-recovery-store")
        let store = AssistantNoteRecoveryStore(recoveryRootURL: recoveryRoot)
        let baseDate = Date(timeIntervalSince1970: 10_000)
        let note = AssistantNoteSummary(
            id: "note-1",
            title: "Runbook",
            fileName: "note-1.md",
            order: 0,
            createdAt: baseDate,
            updatedAt: baseDate
        )

        store.captureDeletedNote(
            note: note,
            ownerKind: .project,
            ownerID: "project-1",
            text: "Keep this around",
            at: baseDate
        )

        XCTAssertEqual(
            store.recentlyDeletedNotes(
                ownerKind: .project,
                ownerID: "project-1",
                referenceDate: baseDate.addingTimeInterval(29 * 24 * 60 * 60)
            ).count,
            1
        )
        XCTAssertTrue(
            store.recentlyDeletedNotes(
                ownerKind: .project,
                ownerID: "project-1",
                referenceDate: baseDate.addingTimeInterval(31 * 24 * 60 * 60)
            ).isEmpty
        )
    }

    @MainActor
    func testBackupControllerSkipsUnchangedBackupsAndRestoresPreviousSet() throws {
        let projectRoot = try makeTemporaryDirectory(named: "assistant-notes-backup-project-root")
        let conversationRoot = try makeTemporaryDirectory(named: "assistant-notes-backup-thread-root")
        let backupRoot = try makeTemporaryDirectory(named: "assistant-notes-backup-target")
        let settings = SettingsStore.shared
        let originalFolderPath = settings.assistantNotesBackupFolderPath
        let originalLastSuccessfulBackupEpoch = settings.assistantNotesLastSuccessfulBackupEpoch
        defer {
            settings.assistantNotesBackupFolderPath = originalFolderPath
            settings.assistantNotesLastSuccessfulBackupEpoch = originalLastSuccessfulBackupEpoch
        }

        settings.assistantNotesBackupFolderPath = backupRoot.path
        settings.assistantNotesLastSuccessfulBackupEpoch = 0

        let projectNoteURL = projectRoot
            .appendingPathComponent("ProjectNotes", isDirectory: true)
            .appendingPathComponent("project-1", isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
            .appendingPathComponent("note.md", isDirectory: false)
        let threadNoteURL = conversationRoot
            .appendingPathComponent("thread-1", isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
            .appendingPathComponent("note.md", isDirectory: false)
        let projectRecoveryURL = projectRoot
            .appendingPathComponent("ProjectNotesRecovery", isDirectory: true)
            .appendingPathComponent("deleted", isDirectory: true)
            .appendingPathComponent("project", isDirectory: true)
            .appendingPathComponent("project-1", isDirectory: true)
            .appendingPathComponent("index.json", isDirectory: false)
        let threadRecoveryURL = conversationRoot
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent("thread", isDirectory: true)
            .appendingPathComponent("thread-1", isDirectory: true)
            .appendingPathComponent("note-1", isDirectory: true)
            .appendingPathComponent("index.json", isDirectory: false)

        try writeFile("project-v1", to: projectNoteURL)
        try writeFile("thread-v1", to: threadNoteURL)
        try writeFile("project-recovery-v1", to: projectRecoveryURL)
        try writeFile("thread-recovery-v1", to: threadRecoveryURL)

        let controller = AssistantNotesBackupController(
            fileManager: .default,
            settings: settings,
            projectRootURL: projectRoot,
            conversationRootURL: conversationRoot
        )
        let firstDate = Date(timeIntervalSince1970: 20_000)

        let firstBackup = try XCTUnwrap(controller.runManualBackup(referenceDate: firstDate))
        XCTAssertNil(
            try controller.runManualBackup(referenceDate: firstDate.addingTimeInterval(60 * 60))
        )

        try writeFile("project-v2", to: projectNoteURL)
        try writeFile("thread-v2", to: threadNoteURL)
        let secondBackup = try XCTUnwrap(
            controller.runManualBackup(referenceDate: firstDate.addingTimeInterval(2 * 60 * 60))
        )

        try writeFile("project-live", to: projectNoteURL)
        try writeFile("thread-live", to: threadNoteURL)
        try writeFile("project-recovery-live", to: projectRecoveryURL)
        try writeFile("thread-recovery-live", to: threadRecoveryURL)

        _ = try controller.restoreBackupSet(
            id: firstBackup.id,
            referenceDate: firstDate.addingTimeInterval(3 * 60 * 60)
        )

        XCTAssertEqual(try String(contentsOf: projectNoteURL, encoding: .utf8), "project-v1")
        XCTAssertEqual(try String(contentsOf: threadNoteURL, encoding: .utf8), "thread-v1")
        XCTAssertEqual(try String(contentsOf: projectRecoveryURL, encoding: .utf8), "project-recovery-v1")
        XCTAssertEqual(try String(contentsOf: threadRecoveryURL, encoding: .utf8), "thread-recovery-v1")
        XCTAssertTrue(
            controller.status.backupSets.contains(where: { $0.id == firstBackup.id })
        )
        XCTAssertTrue(
            controller.status.backupSets.contains(where: { $0.id == secondBackup.id })
        )
        XCTAssertTrue(
            controller.status.backupSets.contains(where: { $0.id.hasPrefix("safety-restore-") })
        )
    }

    @MainActor
    func testBackupControllerPrunesBackupSetsUsingDailyAndWeeklyRetention() throws {
        let projectRoot = try makeTemporaryDirectory(named: "assistant-notes-backup-prune-project-root")
        let conversationRoot = try makeTemporaryDirectory(named: "assistant-notes-backup-prune-thread-root")
        let backupRoot = try makeTemporaryDirectory(named: "assistant-notes-backup-prune-target")
        let settings = SettingsStore.shared
        let originalFolderPath = settings.assistantNotesBackupFolderPath
        let originalLastSuccessfulBackupEpoch = settings.assistantNotesLastSuccessfulBackupEpoch
        defer {
            settings.assistantNotesBackupFolderPath = originalFolderPath
            settings.assistantNotesLastSuccessfulBackupEpoch = originalLastSuccessfulBackupEpoch
        }

        settings.assistantNotesBackupFolderPath = backupRoot.path
        settings.assistantNotesLastSuccessfulBackupEpoch = 0

        let projectNoteURL = projectRoot
            .appendingPathComponent("ProjectNotes", isDirectory: true)
            .appendingPathComponent("project-1", isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
            .appendingPathComponent("note.md", isDirectory: false)
        try writeFile("seed", to: projectNoteURL)

        let controller = AssistantNotesBackupController(
            fileManager: .default,
            settings: settings,
            projectRootURL: projectRoot,
            conversationRootURL: conversationRoot
        )
        let calendar = Calendar(identifier: .gregorian)
        let baseDate = calendar.date(
            from: DateComponents(
                timeZone: TimeZone(secondsFromGMT: 0),
                year: 2026,
                month: 1,
                day: 5,
                hour: 12
            )
        )!

        var createdSummaries: [AssistantNotesBackupSetSummary] = []
        for dayOffset in 0..<21 {
            try writeFile("snapshot-\(dayOffset)", to: projectNoteURL)
            let referenceDate = baseDate.addingTimeInterval(TimeInterval(dayOffset) * 24 * 60 * 60)
            createdSummaries.append(try XCTUnwrap(controller.runManualBackup(referenceDate: referenceDate)))
        }

        let keptIDs = Set(controller.status.backupSets.map(\.id))
        let newestSevenIDs = Set(createdSummaries.suffix(AssistantNoteProtectionDefaults.dailyBackupRetentionCount).map(\.id))

        XCTAssertTrue(newestSevenIDs.isSubset(of: keptIDs))
        XCTAssertGreaterThan(keptIDs.count, newestSevenIDs.count)
        XCTAssertLessThan(keptIDs.count, createdSummaries.count)
        XCTAssertLessThanOrEqual(
            keptIDs.count,
            AssistantNoteProtectionDefaults.dailyBackupRetentionCount
                + AssistantNoteProtectionDefaults.weeklyBackupRetentionCount
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func writeFile(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
