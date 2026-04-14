import CryptoKit
import Foundation

enum AssistantNoteProtectionDefaults {
    static let maxHistoryVersions = 4
    static let automaticSnapshotInterval: TimeInterval = 5 * 60
    static let deletedRetention: TimeInterval = 30 * 24 * 60 * 60
    static let dailyBackupRetentionCount = 7
    static let weeklyBackupRetentionCount = 4
    static let defaultBackupFolderName = "OpenAssist Backups"
}

struct AssistantNoteHistoryVersion: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let noteID: String
    let title: String
    let ownerKind: AssistantNoteOwnerKind
    let ownerID: String
    let savedAt: Date
    let preview: String
    let markdown: String
}

struct AssistantDeletedNoteSnapshot: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let noteID: String
    let title: String
    let ownerKind: AssistantNoteOwnerKind
    let ownerID: String
    let deletedAt: Date
    let preview: String
    let markdown: String
}

struct AssistantNotesBackupSetSummary: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let createdAt: Date
}

struct AssistantNotesBackupStatus: Equatable, Sendable {
    let resolvedFolderURL: URL
    let usesCustomFolder: Bool
    let folderExists: Bool
    let lastSuccessfulBackupAt: Date?
    let backupSets: [AssistantNotesBackupSetSummary]
}

enum AssistantNotesBackupError: LocalizedError {
    case backupFolderUnavailable
    case backupSetMissing
    case invalidBackupPayload

    var errorDescription: String? {
        switch self {
        case .backupFolderUnavailable:
            return "Open Assist could not access the backup folder."
        case .backupSetMissing:
            return "That backup set could not be found."
        case .invalidBackupPayload:
            return "Open Assist could not read that backup set."
        }
    }
}

struct AssistantNoteRestorePayload: Sendable {
    let note: AssistantNoteSummary
    let text: String
    let assetDirectoryURL: URL?
}

private struct AssistantNoteHistoryRecord: Codable, Equatable, Sendable {
    let id: String
    let noteID: String
    let title: String
    let fileName: String
    let createdAt: Date
    let updatedAt: Date
    let ownerKind: AssistantNoteOwnerKind
    let ownerID: String
    let savedAt: Date
    let preview: String
    let contentHash: String
    let contentFileName: String
}

private struct AssistantDeletedNoteRecord: Codable, Equatable, Sendable {
    let id: String
    let noteID: String
    let title: String
    let fileName: String
    let createdAt: Date
    let updatedAt: Date
    let ownerKind: AssistantNoteOwnerKind
    let ownerID: String
    let deletedAt: Date
    let preview: String
    let contentHash: String
    let contentFileName: String
    let assetDirectoryName: String?
}

private struct AssistantNotesBackupManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let id: String
    let createdAt: Date
    let sourceSignature: String

    init(
        id: String,
        createdAt: Date,
        sourceSignature: String
    ) {
        self.version = Self.currentVersion
        self.id = id
        self.createdAt = createdAt
        self.sourceSignature = sourceSignature
    }
}

final class AssistantNoteRecoveryStore {
    private enum StorageNames {
        static let historyDirectory = "history"
        static let deletedDirectory = "deleted"
        static let indexFilename = "index.json"
    }

    private let fileManager: FileManager
    private let recoveryRootURL: URL

    init(
        fileManager: FileManager = .default,
        recoveryRootURL: URL
    ) {
        self.fileManager = fileManager
        self.recoveryRootURL = recoveryRootURL
    }

    func captureHistorySnapshot(
        note: AssistantNoteSummary,
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        text: String,
        at date: Date = Date(),
        force: Bool
    ) {
        let normalizedText = Self.normalizedText(text)
        guard !normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        var records = loadHistoryRecords(ownerKind: ownerKind, ownerID: ownerID, noteID: note.id)
            .sorted { $0.savedAt > $1.savedAt }
        let contentHash = Self.sha256(normalizedText)
        if let latest = records.first {
            if latest.contentHash == contentHash {
                return
            }
            if !force,
               date.timeIntervalSince(latest.savedAt) < AssistantNoteProtectionDefaults.automaticSnapshotInterval {
                return
            }
        }

        let versionID = UUID().uuidString.lowercased()
        let contentFileName = "\(versionID).md"
        guard let contentURL = historyContentFileURL(
            ownerKind: ownerKind,
            ownerID: ownerID,
            noteID: note.id,
            contentFileName: contentFileName
        ) else {
            return
        }

        do {
            try fileManager.createDirectory(
                at: contentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try normalizedText.write(to: contentURL, atomically: true, encoding: .utf8)
            let record = AssistantNoteHistoryRecord(
                id: versionID,
                noteID: note.id,
                title: note.title,
                fileName: note.fileName,
                createdAt: note.createdAt,
                updatedAt: note.updatedAt,
                ownerKind: ownerKind,
                ownerID: ownerID,
                savedAt: date,
                preview: Self.preview(for: normalizedText, fallbackTitle: note.title),
                contentHash: contentHash,
                contentFileName: contentFileName
            )
            records.insert(record, at: 0)
            try pruneHistoryRecordsIfNeeded(
                &records,
                ownerKind: ownerKind,
                ownerID: ownerID,
                noteID: note.id
            )
            try saveHistoryRecords(
                records,
                ownerKind: ownerKind,
                ownerID: ownerID,
                noteID: note.id
            )
        } catch {
            try? fileManager.removeItem(at: contentURL)
        }
    }

    func historyVersions(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String
    ) -> [AssistantNoteHistoryVersion] {
        loadHistoryRecords(ownerKind: ownerKind, ownerID: ownerID, noteID: noteID)
            .sorted { $0.savedAt > $1.savedAt }
            .map {
                AssistantNoteHistoryVersion(
                    id: $0.id,
                    noteID: $0.noteID,
                    title: $0.title,
                    ownerKind: $0.ownerKind,
                    ownerID: $0.ownerID,
                    savedAt: $0.savedAt,
                    preview: $0.preview,
                    markdown: loadHistoryContent(
                        ownerKind: $0.ownerKind,
                        ownerID: $0.ownerID,
                        noteID: $0.noteID,
                        contentFileName: $0.contentFileName
                    ) ?? $0.preview
                )
            }
    }

    func restoreHistoryVersion(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String,
        versionID: String
    ) -> AssistantNoteRestorePayload? {
        let records = loadHistoryRecords(ownerKind: ownerKind, ownerID: ownerID, noteID: noteID)
        guard let record = records.first(where: { $0.id.caseInsensitiveCompare(versionID) == .orderedSame }),
              let contentURL = historyContentFileURL(
                ownerKind: ownerKind,
                ownerID: ownerID,
                noteID: noteID,
                contentFileName: record.contentFileName
              ),
              fileManager.fileExists(atPath: contentURL.path),
              let text = try? String(contentsOf: contentURL, encoding: .utf8) else {
            return nil
        }

        return AssistantNoteRestorePayload(
            note: AssistantNoteSummary(
                id: record.noteID,
                title: record.title,
                fileName: record.fileName,
                order: 0,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            ),
            text: Self.normalizedText(text),
            assetDirectoryURL: nil
        )
    }

    func deleteHistoryVersion(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String,
        versionID: String
    ) {
        var records = loadHistoryRecords(ownerKind: ownerKind, ownerID: ownerID, noteID: noteID)
        guard let index = records.firstIndex(where: { $0.id.caseInsensitiveCompare(versionID) == .orderedSame }) else {
            return
        }
        let removed = records.remove(at: index)
        if let contentURL = historyContentFileURL(
            ownerKind: ownerKind,
            ownerID: ownerID,
            noteID: noteID,
            contentFileName: removed.contentFileName
        ) {
            try? fileManager.removeItem(at: contentURL)
        }
        try? saveHistoryRecords(records, ownerKind: ownerKind, ownerID: ownerID, noteID: noteID)
        try? removeHistoryDirectoryIfEmpty(ownerKind: ownerKind, ownerID: ownerID, noteID: noteID)
    }

    func captureDeletedNote(
        note: AssistantNoteSummary,
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        text: String,
        assetDirectoryURL: URL? = nil,
        at date: Date = Date()
    ) {
        purgeExpiredDeletedNotes(referenceDate: date, ownerKind: ownerKind, ownerID: ownerID)

        let normalizedText = Self.normalizedText(text)
        let contentHash = Self.sha256(normalizedText)
        let deletedID = UUID().uuidString.lowercased()
        let contentFileName = "\(deletedID).md"
        let assetDirectoryName = assetDirectoryURL == nil
            ? nil
            : AssistantNoteAssetSupport.deletedAssetDirectoryName(for: deletedID)
        guard let contentURL = deletedContentFileURL(
            ownerKind: ownerKind,
            ownerID: ownerID,
            contentFileName: contentFileName
        ) else {
            return
        }
        let deletedAssetURL = assetDirectoryName.flatMap {
            deletedAssetDirectoryURL(
                ownerKind: ownerKind,
                ownerID: ownerID,
                assetDirectoryName: $0
            )
        }

        do {
            var records = loadDeletedRecords(ownerKind: ownerKind, ownerID: ownerID)
            let duplicates = records.filter { $0.noteID.caseInsensitiveCompare(note.id) == .orderedSame }
            for duplicate in duplicates {
                deleteDeletedRecordFiles(ownerKind: ownerKind, ownerID: ownerID, record: duplicate)
            }
            records.removeAll { $0.noteID.caseInsensitiveCompare(note.id) == .orderedSame }

            try fileManager.createDirectory(
                at: contentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try normalizedText.write(to: contentURL, atomically: true, encoding: .utf8)
            if let assetDirectoryURL,
               fileManager.fileExists(atPath: assetDirectoryURL.path),
               let deletedAssetURL {
                try? fileManager.removeItem(at: deletedAssetURL)
                try fileManager.copyItem(at: assetDirectoryURL, to: deletedAssetURL)
            }

            let record = AssistantDeletedNoteRecord(
                id: deletedID,
                noteID: note.id,
                title: note.title,
                fileName: note.fileName,
                createdAt: note.createdAt,
                updatedAt: note.updatedAt,
                ownerKind: ownerKind,
                ownerID: ownerID,
                deletedAt: date,
                preview: Self.preview(for: normalizedText, fallbackTitle: note.title),
                contentHash: contentHash,
                contentFileName: contentFileName,
                assetDirectoryName: assetDirectoryName
            )
            records.insert(record, at: 0)
            try saveDeletedRecords(records, ownerKind: ownerKind, ownerID: ownerID)
        } catch {
            try? fileManager.removeItem(at: contentURL)
            if let deletedAssetURL {
                try? fileManager.removeItem(at: deletedAssetURL)
            }
        }
    }

    func recentlyDeletedNotes(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        referenceDate: Date = Date()
    ) -> [AssistantDeletedNoteSnapshot] {
        purgeExpiredDeletedNotes(referenceDate: referenceDate, ownerKind: ownerKind, ownerID: ownerID)
        return loadDeletedRecords(ownerKind: ownerKind, ownerID: ownerID)
            .sorted { $0.deletedAt > $1.deletedAt }
            .map {
                AssistantDeletedNoteSnapshot(
                    id: $0.id,
                    noteID: $0.noteID,
                    title: $0.title,
                    ownerKind: $0.ownerKind,
                    ownerID: $0.ownerID,
                    deletedAt: $0.deletedAt,
                    preview: $0.preview,
                    markdown: loadDeletedContent(
                        ownerKind: $0.ownerKind,
                        ownerID: $0.ownerID,
                        contentFileName: $0.contentFileName
                    ) ?? $0.preview
                )
            }
    }

    func restoreDeletedNote(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        deletedID: String,
        referenceDate: Date = Date()
    ) -> AssistantNoteRestorePayload? {
        purgeExpiredDeletedNotes(referenceDate: referenceDate, ownerKind: ownerKind, ownerID: ownerID)
        var records = loadDeletedRecords(ownerKind: ownerKind, ownerID: ownerID)
        guard let index = records.firstIndex(where: { $0.id.caseInsensitiveCompare(deletedID) == .orderedSame }) else {
            return nil
        }

        let record = records.remove(at: index)
        guard let contentURL = deletedContentFileURL(
            ownerKind: ownerKind,
            ownerID: ownerID,
            contentFileName: record.contentFileName
        ),
        fileManager.fileExists(atPath: contentURL.path),
        let text = try? String(contentsOf: contentURL, encoding: .utf8) else {
            try? saveDeletedRecords(records, ownerKind: ownerKind, ownerID: ownerID)
            return nil
        }

        try? fileManager.removeItem(at: contentURL)
        try? saveDeletedRecords(records, ownerKind: ownerKind, ownerID: ownerID)
        try? removeDeletedDirectoryIfEmpty(ownerKind: ownerKind, ownerID: ownerID)

        return AssistantNoteRestorePayload(
            note: AssistantNoteSummary(
                id: record.noteID,
                title: record.title,
                fileName: record.fileName,
                order: 0,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            ),
            text: Self.normalizedText(text),
            assetDirectoryURL: record.assetDirectoryName.flatMap {
                deletedAssetDirectoryURL(
                    ownerKind: ownerKind,
                    ownerID: ownerID,
                    assetDirectoryName: $0
                )
            }
        )
    }

    func permanentlyDeleteDeletedNote(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        deletedID: String
    ) {
        var records = loadDeletedRecords(ownerKind: ownerKind, ownerID: ownerID)
        guard let index = records.firstIndex(where: { $0.id.caseInsensitiveCompare(deletedID) == .orderedSame }) else {
            return
        }
        let removed = records.remove(at: index)
        deleteDeletedRecordFiles(ownerKind: ownerKind, ownerID: ownerID, record: removed)
        try? saveDeletedRecords(records, ownerKind: ownerKind, ownerID: ownerID)
        try? removeDeletedDirectoryIfEmpty(ownerKind: ownerKind, ownerID: ownerID)
    }

    func purgeExpiredDeletedNotes(
        referenceDate: Date = Date(),
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String
    ) {
        var records = loadDeletedRecords(ownerKind: ownerKind, ownerID: ownerID)
        let cutoff = referenceDate.addingTimeInterval(-AssistantNoteProtectionDefaults.deletedRetention)
        let expired = records.filter { $0.deletedAt < cutoff }
        guard !expired.isEmpty else { return }
        for record in expired {
            deleteDeletedRecordFiles(ownerKind: ownerKind, ownerID: ownerID, record: record)
        }
        records.removeAll { $0.deletedAt < cutoff }
        try? saveDeletedRecords(records, ownerKind: ownerKind, ownerID: ownerID)
        try? removeDeletedDirectoryIfEmpty(ownerKind: ownerKind, ownerID: ownerID)
    }

    func removeAllRecoveryData(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String
    ) {
        if let historyOwnerDirectory = historyOwnerDirectoryURL(ownerKind: ownerKind, ownerID: ownerID),
           fileManager.fileExists(atPath: historyOwnerDirectory.path) {
            try? fileManager.removeItem(at: historyOwnerDirectory)
            try? removeDirectoryIfEmpty(historyOwnerDirectory.deletingLastPathComponent())
            try? removeDirectoryIfEmpty(historyOwnerDirectory.deletingLastPathComponent().deletingLastPathComponent())
        }

        if let deletedOwnerDirectory = deletedOwnerDirectoryURL(ownerKind: ownerKind, ownerID: ownerID),
           fileManager.fileExists(atPath: deletedOwnerDirectory.path) {
            try? fileManager.removeItem(at: deletedOwnerDirectory)
            try? removeDirectoryIfEmpty(deletedOwnerDirectory.deletingLastPathComponent())
            try? removeDirectoryIfEmpty(deletedOwnerDirectory.deletingLastPathComponent().deletingLastPathComponent())
        }
    }

    private func pruneHistoryRecordsIfNeeded(
        _ records: inout [AssistantNoteHistoryRecord],
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String
    ) throws {
        guard records.count > AssistantNoteProtectionDefaults.maxHistoryVersions else {
            return
        }
        let overflow = records.suffix(from: AssistantNoteProtectionDefaults.maxHistoryVersions)
        for record in overflow {
            if let contentURL = historyContentFileURL(
                ownerKind: ownerKind,
                ownerID: ownerID,
                noteID: noteID,
                contentFileName: record.contentFileName
            ) {
                try? fileManager.removeItem(at: contentURL)
            }
        }
        records = Array(records.prefix(AssistantNoteProtectionDefaults.maxHistoryVersions))
    }

    private func loadHistoryRecords(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String
    ) -> [AssistantNoteHistoryRecord] {
        guard let indexURL = historyIndexFileURL(ownerKind: ownerKind, ownerID: ownerID, noteID: noteID),
              fileManager.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let records = try? JSONDecoder().decode([AssistantNoteHistoryRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func saveHistoryRecords(
        _ records: [AssistantNoteHistoryRecord],
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String
    ) throws {
        guard let indexURL = historyIndexFileURL(ownerKind: ownerKind, ownerID: ownerID, noteID: noteID) else {
            return
        }
        if records.isEmpty {
            try? fileManager.removeItem(at: indexURL)
            try? removeHistoryDirectoryIfEmpty(ownerKind: ownerKind, ownerID: ownerID, noteID: noteID)
            return
        }
        try fileManager.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records.sorted { $0.savedAt > $1.savedAt })
        try data.write(to: indexURL, options: .atomic)
    }

    private func loadDeletedRecords(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String
    ) -> [AssistantDeletedNoteRecord] {
        guard let indexURL = deletedIndexFileURL(ownerKind: ownerKind, ownerID: ownerID),
              fileManager.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let records = try? JSONDecoder().decode([AssistantDeletedNoteRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func loadHistoryContent(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String,
        contentFileName: String
    ) -> String? {
        guard let contentURL = historyContentFileURL(
            ownerKind: ownerKind,
            ownerID: ownerID,
            noteID: noteID,
            contentFileName: contentFileName
        ),
        fileManager.fileExists(atPath: contentURL.path),
        let text = try? String(contentsOf: contentURL, encoding: .utf8) else {
            return nil
        }

        return Self.normalizedText(text)
    }

    private func loadDeletedContent(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        contentFileName: String
    ) -> String? {
        guard let contentURL = deletedContentFileURL(
            ownerKind: ownerKind,
            ownerID: ownerID,
            contentFileName: contentFileName
        ),
        fileManager.fileExists(atPath: contentURL.path),
        let text = try? String(contentsOf: contentURL, encoding: .utf8) else {
            return nil
        }

        return Self.normalizedText(text)
    }

    private func saveDeletedRecords(
        _ records: [AssistantDeletedNoteRecord],
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String
    ) throws {
        guard let indexURL = deletedIndexFileURL(ownerKind: ownerKind, ownerID: ownerID) else {
            return
        }
        if records.isEmpty {
            try? fileManager.removeItem(at: indexURL)
            try? removeDeletedDirectoryIfEmpty(ownerKind: ownerKind, ownerID: ownerID)
            return
        }
        try fileManager.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records.sorted { $0.deletedAt > $1.deletedAt })
        try data.write(to: indexURL, options: .atomic)
    }

    private func deleteDeletedRecordFiles(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        record: AssistantDeletedNoteRecord
    ) {
        if let contentURL = deletedContentFileURL(
            ownerKind: ownerKind,
            ownerID: ownerID,
            contentFileName: record.contentFileName
        ) {
            try? fileManager.removeItem(at: contentURL)
        }
        if let assetDirectoryName = record.assetDirectoryName,
           let assetDirectoryURL = deletedAssetDirectoryURL(
            ownerKind: ownerKind,
            ownerID: ownerID,
            assetDirectoryName: assetDirectoryName
           ) {
            try? fileManager.removeItem(at: assetDirectoryURL)
        }
    }

    private func historyIndexFileURL(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String
    ) -> URL? {
        historyNoteDirectoryURL(ownerKind: ownerKind, ownerID: ownerID, noteID: noteID)?
            .appendingPathComponent(StorageNames.indexFilename, isDirectory: false)
    }

    private func historyContentFileURL(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String,
        contentFileName: String
    ) -> URL? {
        historyNoteDirectoryURL(ownerKind: ownerKind, ownerID: ownerID, noteID: noteID)?
            .appendingPathComponent(contentFileName, isDirectory: false)
    }

    private func deletedIndexFileURL(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String
    ) -> URL? {
        deletedOwnerDirectoryURL(ownerKind: ownerKind, ownerID: ownerID)?
            .appendingPathComponent(StorageNames.indexFilename, isDirectory: false)
    }

    private func deletedContentFileURL(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        contentFileName: String
    ) -> URL? {
        deletedOwnerDirectoryURL(ownerKind: ownerKind, ownerID: ownerID)?
            .appendingPathComponent(contentFileName, isDirectory: false)
    }

    private func deletedAssetDirectoryURL(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        assetDirectoryName: String
    ) -> URL? {
        deletedOwnerDirectoryURL(ownerKind: ownerKind, ownerID: ownerID)?
            .appendingPathComponent(assetDirectoryName, isDirectory: true)
    }

    private func historyNoteDirectoryURL(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String
    ) -> URL? {
        let safeNoteID = Self.safePathComponent(noteID)
        guard !safeNoteID.isEmpty,
              let ownerDirectory = historyOwnerDirectoryURL(ownerKind: ownerKind, ownerID: ownerID) else {
            return nil
        }
        return ownerDirectory
            .appendingPathComponent(safeNoteID, isDirectory: true)
    }

    private func historyOwnerDirectoryURL(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String
    ) -> URL? {
        let safeOwnerID = Self.safePathComponent(ownerID)
        guard !safeOwnerID.isEmpty else { return nil }
        return recoveryRootURL
            .appendingPathComponent(StorageNames.historyDirectory, isDirectory: true)
            .appendingPathComponent(ownerKind.rawValue, isDirectory: true)
            .appendingPathComponent(safeOwnerID, isDirectory: true)
    }

    private func deletedOwnerDirectoryURL(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String
    ) -> URL? {
        let safeOwnerID = Self.safePathComponent(ownerID)
        guard !safeOwnerID.isEmpty else { return nil }
        return recoveryRootURL
            .appendingPathComponent(StorageNames.deletedDirectory, isDirectory: true)
            .appendingPathComponent(ownerKind.rawValue, isDirectory: true)
            .appendingPathComponent(safeOwnerID, isDirectory: true)
    }

    private func removeHistoryDirectoryIfEmpty(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String
    ) throws {
        if let noteDirectory = historyNoteDirectoryURL(ownerKind: ownerKind, ownerID: ownerID, noteID: noteID) {
            try removeDirectoryIfEmpty(noteDirectory)
            try removeDirectoryIfEmpty(noteDirectory.deletingLastPathComponent())
            try removeDirectoryIfEmpty(noteDirectory.deletingLastPathComponent().deletingLastPathComponent())
        }
    }

    private func removeDeletedDirectoryIfEmpty(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String
    ) throws {
        if let ownerDirectory = deletedOwnerDirectoryURL(ownerKind: ownerKind, ownerID: ownerID) {
            try removeDirectoryIfEmpty(ownerDirectory)
            try removeDirectoryIfEmpty(ownerDirectory.deletingLastPathComponent())
            try removeDirectoryIfEmpty(ownerDirectory.deletingLastPathComponent().deletingLastPathComponent())
        }
    }

    private func removeDirectoryIfEmpty(_ directoryURL: URL) throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let contents = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        guard contents.isEmpty else { return }
        try fileManager.removeItem(at: directoryURL)
    }

    static func normalizedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func preview(for text: String, fallbackTitle: String) -> String {
        let normalizedLines = normalizedText(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let candidate = normalizedLines.first ?? fallbackTitle
        let cleaned = candidate.hasPrefix("#")
            ? String(candidate.drop(while: { $0 == "#" || $0 == " " || $0 == "\t" }))
            : candidate
        let compact = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if compact.count <= 140 {
            return compact
        }
        return String(compact.prefix(137)) + "..."
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func safePathComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[^A-Za-z0-9._-]+"#,
                with: "-",
                options: .regularExpression
            )
    }
}

@MainActor
final class AssistantNotesBackupController: ObservableObject {
    static let shared = AssistantNotesBackupController()

    private let fileManager: FileManager
    private let settings: SettingsStore
    private let projectRootURL: URL
    private let conversationRootURL: URL

    @Published private(set) var status: AssistantNotesBackupStatus

    init(
        fileManager: FileManager = .default,
        settings: SettingsStore? = nil,
        projectRootURL: URL? = nil,
        conversationRootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.settings = settings ?? SettingsStore.shared
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.projectRootURL = projectRootURL
            ?? applicationSupport
            .appendingPathComponent("OpenAssist", isDirectory: true)
            .appendingPathComponent("AssistantProjects", isDirectory: true)
        self.conversationRootURL = conversationRootURL
            ?? applicationSupport
            .appendingPathComponent("OpenAssist", isDirectory: true)
            .appendingPathComponent("AssistantConversationStore", isDirectory: true)
        let initialFolder = AssistantNotesBackupController.resolvedBackupFolderURL(
            fileManager: fileManager,
            settings: self.settings
        )
        self.status = AssistantNotesBackupStatus(
            resolvedFolderURL: initialFolder,
            usesCustomFolder: self.settings.assistantNotesBackupFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            folderExists: fileManager.fileExists(atPath: initialFolder.path),
            lastSuccessfulBackupAt: AssistantNotesBackupController.lastSuccessfulBackupDate(from: self.settings),
            backupSets: []
        )
        refreshStatus()
    }

    func refreshStatus() {
        let resolvedFolderURL = Self.resolvedBackupFolderURL(fileManager: fileManager, settings: settings)
        status = AssistantNotesBackupStatus(
            resolvedFolderURL: resolvedFolderURL,
            usesCustomFolder: settings.assistantNotesBackupFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            folderExists: fileManager.fileExists(atPath: resolvedFolderURL.path),
            lastSuccessfulBackupAt: Self.lastSuccessfulBackupDate(from: settings),
            backupSets: availableBackupSets(in: resolvedFolderURL)
        )
    }

    @discardableResult
    func maybeRunAutomaticBackupIfNeeded(referenceDate: Date = Date()) throws -> Bool {
        let lastSuccessful = Self.lastSuccessfulBackupDate(from: settings)
        if let lastSuccessful,
           referenceDate.timeIntervalSince(lastSuccessful) < 24 * 60 * 60 {
            refreshStatus()
            return false
        }
        let created = try runBackup(referenceDate: referenceDate)
        return created != nil
    }

    @discardableResult
    func runManualBackup(referenceDate: Date = Date()) throws -> AssistantNotesBackupSetSummary? {
        try runBackup(referenceDate: referenceDate)
    }

    @discardableResult
    func restoreBackupSet(id: String, referenceDate: Date = Date()) throws -> AssistantNotesBackupSetSummary {
        let backupRootURL = Self.resolvedBackupFolderURL(fileManager: fileManager, settings: settings)
        let summary = try backupSetSummary(id: id, in: backupRootURL)
        _ = try createSafetyBackupBeforeRestore(referenceDate: referenceDate)

        let backupDirectoryURL = backupRootURL.appendingPathComponent(summary.id, isDirectory: true)
        let manifestURL = backupDirectoryURL.appendingPathComponent("manifest.json", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw AssistantNotesBackupError.invalidBackupPayload
        }

        try restoreProjectPayload(from: backupDirectoryURL)
        try restoreConversationPayload(from: backupDirectoryURL)
        refreshStatus()
        return summary
    }

    private func runBackup(referenceDate: Date) throws -> AssistantNotesBackupSetSummary? {
        let backupRootURL = Self.resolvedBackupFolderURL(fileManager: fileManager, settings: settings)
        try fileManager.createDirectory(at: backupRootURL, withIntermediateDirectories: true)
        let sourceSignature = try currentSourceSignature()
        if let latest = latestBackupManifest(in: backupRootURL),
           latest.sourceSignature == sourceSignature {
            refreshStatus()
            return nil
        }

        let backupID = Self.backupIdentifier(for: referenceDate)
        let backupDirectoryURL = backupRootURL.appendingPathComponent(backupID, isDirectory: true)
        try fileManager.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)

        do {
            try writeProjectPayload(to: backupDirectoryURL)
            try writeConversationPayload(to: backupDirectoryURL)
            let manifest = AssistantNotesBackupManifest(
                id: backupID,
                createdAt: referenceDate,
                sourceSignature: sourceSignature
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(
                to: backupDirectoryURL.appendingPathComponent("manifest.json", isDirectory: false),
                options: .atomic
            )
        } catch {
            try? fileManager.removeItem(at: backupDirectoryURL)
            throw error
        }

        settings.assistantNotesLastSuccessfulBackupEpoch = referenceDate.timeIntervalSince1970
        try pruneBackups(in: backupRootURL)
        refreshStatus()
        return AssistantNotesBackupSetSummary(id: backupID, createdAt: referenceDate)
    }

    private func createSafetyBackupBeforeRestore(referenceDate: Date) throws -> AssistantNotesBackupSetSummary {
        let backupRootURL = Self.resolvedBackupFolderURL(fileManager: fileManager, settings: settings)
        try fileManager.createDirectory(at: backupRootURL, withIntermediateDirectories: true)
        let backupID = "safety-restore-\(Self.backupIdentifier(for: referenceDate))"
        let backupDirectoryURL = backupRootURL.appendingPathComponent(backupID, isDirectory: true)
        if fileManager.fileExists(atPath: backupDirectoryURL.path) {
            try? fileManager.removeItem(at: backupDirectoryURL)
        }
        try fileManager.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        try writeProjectPayload(to: backupDirectoryURL)
        try writeConversationPayload(to: backupDirectoryURL)
        let manifest = AssistantNotesBackupManifest(
            id: backupID,
            createdAt: referenceDate,
            sourceSignature: try currentSourceSignature()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: backupDirectoryURL.appendingPathComponent("manifest.json", isDirectory: false),
            options: .atomic
        )
        return AssistantNotesBackupSetSummary(id: backupID, createdAt: referenceDate)
    }

    private func writeProjectPayload(to backupDirectoryURL: URL) throws {
        let targetRoot = backupDirectoryURL.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let projectsJSONURL = projectRootURL.appendingPathComponent("projects.json", isDirectory: false)
        if fileManager.fileExists(atPath: projectsJSONURL.path) {
            try copyItemReplacingIfNeeded(
                at: projectsJSONURL,
                to: targetRoot.appendingPathComponent("projects.json", isDirectory: false)
            )
        }
        let projectNotesURL = projectRootURL.appendingPathComponent("ProjectNotes", isDirectory: true)
        if fileManager.fileExists(atPath: projectNotesURL.path) {
            try copyItemReplacingIfNeeded(
                at: projectNotesURL,
                to: targetRoot.appendingPathComponent("ProjectNotes", isDirectory: true)
            )
        }
        let recoveryURL = projectRootURL.appendingPathComponent("ProjectNotesRecovery", isDirectory: true)
        if fileManager.fileExists(atPath: recoveryURL.path) {
            try copyItemReplacingIfNeeded(
                at: recoveryURL,
                to: targetRoot.appendingPathComponent("ProjectNotesRecovery", isDirectory: true)
            )
        }
    }

    private func writeConversationPayload(to backupDirectoryURL: URL) throws {
        let targetRoot = backupDirectoryURL.appendingPathComponent("thread", isDirectory: true)
        let threadNotesRoot = targetRoot.appendingPathComponent("threads", isDirectory: true)
        try fileManager.createDirectory(at: threadNotesRoot, withIntermediateDirectories: true)

        if let conversationChildren = try? fileManager.contentsOfDirectory(
            at: conversationRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in conversationChildren where isDirectory(child) {
                let notesDirectory = child.appendingPathComponent("notes", isDirectory: true)
                guard fileManager.fileExists(atPath: notesDirectory.path) else { continue }
                let targetDirectory = threadNotesRoot
                    .appendingPathComponent(child.lastPathComponent, isDirectory: true)
                    .appendingPathComponent("notes", isDirectory: true)
                try copyItemReplacingIfNeeded(at: notesDirectory, to: targetDirectory)
            }
        }

        let recoveryURL = conversationRootURL.appendingPathComponent("Recovery", isDirectory: true)
        if fileManager.fileExists(atPath: recoveryURL.path) {
            try copyItemReplacingIfNeeded(
                at: recoveryURL,
                to: targetRoot.appendingPathComponent("Recovery", isDirectory: true)
            )
        }
    }

    private func restoreProjectPayload(from backupDirectoryURL: URL) throws {
        let sourceRoot = backupDirectoryURL.appendingPathComponent("project", isDirectory: true)
        guard fileManager.fileExists(atPath: sourceRoot.path) else {
            throw AssistantNotesBackupError.invalidBackupPayload
        }

        try fileManager.createDirectory(at: projectRootURL, withIntermediateDirectories: true)
        let projectsJSONURL = projectRootURL.appendingPathComponent("projects.json", isDirectory: false)
        try? fileManager.removeItem(at: projectsJSONURL)
        let projectNotesURL = projectRootURL.appendingPathComponent("ProjectNotes", isDirectory: true)
        try? fileManager.removeItem(at: projectNotesURL)
        let projectRecoveryURL = projectRootURL.appendingPathComponent("ProjectNotesRecovery", isDirectory: true)
        try? fileManager.removeItem(at: projectRecoveryURL)

        let backedUpProjectsJSON = sourceRoot.appendingPathComponent("projects.json", isDirectory: false)
        if fileManager.fileExists(atPath: backedUpProjectsJSON.path) {
            try copyItemReplacingIfNeeded(at: backedUpProjectsJSON, to: projectsJSONURL)
        }
        let backedUpNotes = sourceRoot.appendingPathComponent("ProjectNotes", isDirectory: true)
        if fileManager.fileExists(atPath: backedUpNotes.path) {
            try copyItemReplacingIfNeeded(at: backedUpNotes, to: projectNotesURL)
        }
        let backedUpRecovery = sourceRoot.appendingPathComponent("ProjectNotesRecovery", isDirectory: true)
        if fileManager.fileExists(atPath: backedUpRecovery.path) {
            try copyItemReplacingIfNeeded(at: backedUpRecovery, to: projectRecoveryURL)
        }
    }

    private func restoreConversationPayload(from backupDirectoryURL: URL) throws {
        let sourceRoot = backupDirectoryURL.appendingPathComponent("thread", isDirectory: true)
        guard fileManager.fileExists(atPath: sourceRoot.path) else {
            throw AssistantNotesBackupError.invalidBackupPayload
        }

        if let conversationChildren = try? fileManager.contentsOfDirectory(
            at: conversationRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in conversationChildren where isDirectory(child) {
                let notesDirectory = child.appendingPathComponent("notes", isDirectory: true)
                if fileManager.fileExists(atPath: notesDirectory.path) {
                    try? fileManager.removeItem(at: notesDirectory)
                }
            }
        } else {
            try fileManager.createDirectory(at: conversationRootURL, withIntermediateDirectories: true)
        }

        let recoveryURL = conversationRootURL.appendingPathComponent("Recovery", isDirectory: true)
        try? fileManager.removeItem(at: recoveryURL)

        let threadNotesRoot = sourceRoot.appendingPathComponent("threads", isDirectory: true)
        if let backupThreadDirectories = try? fileManager.contentsOfDirectory(
            at: threadNotesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for threadDirectory in backupThreadDirectories where isDirectory(threadDirectory) {
                let notesDirectory = threadDirectory.appendingPathComponent("notes", isDirectory: true)
                guard fileManager.fileExists(atPath: notesDirectory.path) else { continue }
                let targetDirectory = conversationRootURL
                    .appendingPathComponent(threadDirectory.lastPathComponent, isDirectory: true)
                    .appendingPathComponent("notes", isDirectory: true)
                try copyItemReplacingIfNeeded(at: notesDirectory, to: targetDirectory)
            }
        }

        let backedUpRecovery = sourceRoot.appendingPathComponent("Recovery", isDirectory: true)
        if fileManager.fileExists(atPath: backedUpRecovery.path) {
            try copyItemReplacingIfNeeded(at: backedUpRecovery, to: recoveryURL)
        }
    }

    private func currentSourceSignature() throws -> String {
        var parts: [String] = []
        parts.append(contentsOf: try fingerprintEntriesForProjectRoot())
        parts.append(contentsOf: try fingerprintEntriesForConversationRoot())
        return AssistantNoteRecoveryStore.sha256(parts.sorted().joined(separator: "\n"))
    }

    private func fingerprintEntriesForProjectRoot() throws -> [String] {
        var entries: [String] = []
        let projectsJSONURL = projectRootURL.appendingPathComponent("projects.json", isDirectory: false)
        if fileManager.fileExists(atPath: projectsJSONURL.path) {
            entries.append(try fingerprintEntry(for: projectsJSONURL, relativePath: "project/projects.json"))
        }
        let projectNotesURL = projectRootURL.appendingPathComponent("ProjectNotes", isDirectory: true)
        if fileManager.fileExists(atPath: projectNotesURL.path) {
            entries.append(contentsOf: try fingerprintDirectory(at: projectNotesURL, prefix: "project/ProjectNotes"))
        }
        let recoveryURL = projectRootURL.appendingPathComponent("ProjectNotesRecovery", isDirectory: true)
        if fileManager.fileExists(atPath: recoveryURL.path) {
            entries.append(contentsOf: try fingerprintDirectory(at: recoveryURL, prefix: "project/ProjectNotesRecovery"))
        }
        return entries
    }

    private func fingerprintEntriesForConversationRoot() throws -> [String] {
        var entries: [String] = []
        if let children = try? fileManager.contentsOfDirectory(
            at: conversationRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children where isDirectory(child) {
                let notesDirectory = child.appendingPathComponent("notes", isDirectory: true)
                if fileManager.fileExists(atPath: notesDirectory.path) {
                    entries.append(contentsOf: try fingerprintDirectory(
                        at: notesDirectory,
                        prefix: "thread/\(child.lastPathComponent)/notes"
                    ))
                }
            }
        }
        let recoveryURL = conversationRootURL.appendingPathComponent("Recovery", isDirectory: true)
        if fileManager.fileExists(atPath: recoveryURL.path) {
            entries.append(contentsOf: try fingerprintDirectory(at: recoveryURL, prefix: "thread/Recovery"))
        }
        return entries
    }

    private func fingerprintDirectory(at directoryURL: URL, prefix: String) throws -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [String] = []
        while let fileURL = enumerator.nextObject() as? URL {
            guard !isDirectory(fileURL) else { continue }
            let relativePath = prefix + "/" + fileURL.path.replacingOccurrences(of: directoryURL.path + "/", with: "")
            entries.append(try fingerprintEntry(for: fileURL, relativePath: relativePath))
        }
        return entries
    }

    private func fingerprintEntry(for fileURL: URL, relativePath: String) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(relativePath)|\(hash)|\(data.count)"
    }

    private func latestBackupManifest(in backupRootURL: URL) -> AssistantNotesBackupManifest? {
        availableBackupSets(in: backupRootURL)
            .compactMap { try? loadBackupManifest(id: $0.id, in: backupRootURL) }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    private func backupSetSummary(id: String, in backupRootURL: URL) throws -> AssistantNotesBackupSetSummary {
        let manifest = try loadBackupManifest(id: id, in: backupRootURL)
        return AssistantNotesBackupSetSummary(id: manifest.id, createdAt: manifest.createdAt)
    }

    private func loadBackupManifest(id: String, in backupRootURL: URL) throws -> AssistantNotesBackupManifest {
        let manifestURL = backupRootURL
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(AssistantNotesBackupManifest.self, from: data) else {
            throw AssistantNotesBackupError.backupSetMissing
        }
        return manifest
    }

    private func availableBackupSets(in backupRootURL: URL) -> [AssistantNotesBackupSetSummary] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: backupRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return directories.compactMap { directoryURL in
            guard isDirectory(directoryURL),
                  let manifest = try? loadBackupManifest(id: directoryURL.lastPathComponent, in: backupRootURL) else {
                return nil
            }
            return AssistantNotesBackupSetSummary(id: manifest.id, createdAt: manifest.createdAt)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private func pruneBackups(in backupRootURL: URL) throws {
        let summaries = availableBackupSets(in: backupRootURL)
        guard !summaries.isEmpty else { return }

        let calendar = Calendar(identifier: .gregorian)
        let sorted = summaries.sorted { $0.createdAt > $1.createdAt }
        var keepIDs = Set(sorted.prefix(AssistantNoteProtectionDefaults.dailyBackupRetentionCount).map(\.id))

        var keptWeeklyBuckets: Set<String> = []
        for summary in sorted {
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: summary.createdAt)
            let bucket = "\(components.yearForWeekOfYear ?? 0)-\(components.weekOfYear ?? 0)"
            if keptWeeklyBuckets.contains(bucket) {
                continue
            }
            keptWeeklyBuckets.insert(bucket)
            keepIDs.insert(summary.id)
            if keptWeeklyBuckets.count >= AssistantNoteProtectionDefaults.weeklyBackupRetentionCount {
                break
            }
        }

        for summary in summaries where !keepIDs.contains(summary.id) {
            try? fileManager.removeItem(at: backupRootURL.appendingPathComponent(summary.id, isDirectory: true))
        }
    }

    private func copyItemReplacingIfNeeded(at sourceURL: URL, to targetURL: URL) throws {
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: targetURL)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func resolvedBackupFolderURL(
        fileManager: FileManager,
        settings: SettingsStore
    ) -> URL {
        if let customPath = settings.assistantNotesBackupFolderPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty {
            return URL(fileURLWithPath: customPath, isDirectory: true).standardizedFileURL
        }
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent(
            AssistantNoteProtectionDefaults.defaultBackupFolderName,
            isDirectory: true
        )
    }

    private static func lastSuccessfulBackupDate(from settings: SettingsStore) -> Date? {
        guard settings.assistantNotesLastSuccessfulBackupEpoch > 0 else { return nil }
        return Date(timeIntervalSince1970: settings.assistantNotesLastSuccessfulBackupEpoch)
    }

    private static func backupIdentifier(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
