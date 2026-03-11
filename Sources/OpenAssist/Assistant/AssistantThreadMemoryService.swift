import Foundation

struct AssistantThreadMemoryChange {
    let document: AssistantThreadMemoryDocument
    let fileURL: URL
    let didChangeExternally: Bool
}

final class AssistantThreadMemoryService {
    private let fileManager: FileManager
    private let baseDirectoryURL: URL
    private var lastObservedModifiedAtByThreadID: [String: Date] = [:]

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        if let baseDirectoryURL {
            self.baseDirectoryURL = baseDirectoryURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.baseDirectoryURL = applicationSupport
                .appendingPathComponent("OpenAssist", isDirectory: true)
                .appendingPathComponent("AssistantMemory", isDirectory: true)
        }
    }

    var rootDirectoryURL: URL {
        baseDirectoryURL
    }

    func memoryFileIfExists(for threadID: String) -> URL? {
        guard let fileURL = try? memoryFileURL(for: threadID),
              fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return fileURL
    }

    func ensureMemoryFile(for threadID: String, seedTask: String? = nil) throws -> URL {
        let directory = try threadDirectoryURL(for: threadID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("memory.md", isDirectory: false)
        guard !fileManager.fileExists(atPath: fileURL.path) else {
            return fileURL
        }

        var document = AssistantThreadMemoryDocument.empty
        if let seedTask = seedTask?.trimmingCharacters(in: .whitespacesAndNewlines), !seedTask.isEmpty {
            document.currentTask = AssistantThreadMemoryDocument.normalizedTask(seedTask)
        }
        try document.markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        try markObserved(threadID: normalizedThreadID(threadID), fileURL: fileURL)
        return fileURL
    }

    func loadTrackedDocument(for threadID: String, seedTask: String? = nil) throws -> AssistantThreadMemoryChange {
        let normalizedThreadID = normalizedThreadID(threadID)
        let fileURL = try ensureMemoryFile(for: normalizedThreadID, seedTask: seedTask)
        let resourceValues = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedAt = resourceValues.contentModificationDate ?? .distantPast
        let lastObserved = lastObservedModifiedAtByThreadID[normalizedThreadID]
        let changedExternally = lastObserved != nil && lastObserved != modifiedAt

        let markdown = try String(contentsOf: fileURL, encoding: .utf8)
        let document = AssistantThreadMemoryDocument.parse(markdown: markdown)
        lastObservedModifiedAtByThreadID[normalizedThreadID] = modifiedAt
        return AssistantThreadMemoryChange(
            document: document,
            fileURL: fileURL,
            didChangeExternally: changedExternally
        )
    }

    func saveDocument(_ document: AssistantThreadMemoryDocument, for threadID: String) throws -> URL {
        let normalizedThreadID = normalizedThreadID(threadID)
        let fileURL = try ensureMemoryFile(for: normalizedThreadID)
        try document.markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        try markObserved(threadID: normalizedThreadID, fileURL: fileURL)
        return fileURL
    }

    func softReset(
        for threadID: String,
        reason: String,
        nextTask: String
    ) throws -> AssistantThreadMemoryChange {
        let normalizedThreadID = normalizedThreadID(threadID)
        let current = try loadTrackedDocument(for: normalizedThreadID)
        try archiveCurrentDocument(current.document, for: normalizedThreadID)

        var fresh = AssistantThreadMemoryDocument.empty
        fresh.currentTask = AssistantThreadMemoryDocument.normalizedTask(nextTask)
        if !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fresh.staleNotes = ["Memory reset: \(AssistantThreadMemoryDocument.normalizedLine(reason))"]
        }

        let fileURL = try saveDocument(fresh, for: normalizedThreadID)
        return AssistantThreadMemoryChange(
            document: fresh,
            fileURL: fileURL,
            didChangeExternally: current.didChangeExternally
        )
    }

    func clearMemory(for threadID: String) throws {
        let normalizedThreadID = normalizedThreadID(threadID)
        let directory = try threadDirectoryURL(for: normalizedThreadID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        lastObservedModifiedAtByThreadID[normalizedThreadID] = nil
    }

    func addCandidateLesson(_ lesson: String, for threadID: String) throws {
        let change = try loadTrackedDocument(for: threadID)
        var document = change.document
        document.addCandidateLesson(lesson)
        _ = try saveDocument(document, for: threadID)
    }

    func removeCandidateLesson(_ lesson: String, for threadID: String) throws {
        let change = try loadTrackedDocument(for: threadID)
        var document = change.document
        document.removeCandidateLesson(lesson)
        _ = try saveDocument(document, for: threadID)
    }

    func shouldSoftReset(document: AssistantThreadMemoryDocument, nextPrompt: String) -> Bool {
        let normalizedPrompt = AssistantThreadMemoryDocument.normalizedTask(nextPrompt).lowercased()
        guard !normalizedPrompt.isEmpty else { return false }

        let explicitResetPhrases = [
            "restart", "start over", "redo", "ignore that", "do something else",
            "before that", "instead", "new task", "switch to"
        ]
        if explicitResetPhrases.contains(where: { normalizedPrompt.contains($0) }) {
            return true
        }

        if normalizedPrompt.contains("again") || normalizedPrompt.contains("retry") {
            return true
        }

        let currentTask = document.currentTask.lowercased()
        guard !currentTask.isEmpty else { return false }

        let currentKeywords = Set(MemoryTextNormalizer.keywords(from: currentTask, limit: 12))
        let promptKeywords = Set(MemoryTextNormalizer.keywords(from: normalizedPrompt, limit: 12))
        guard !currentKeywords.isEmpty, !promptKeywords.isEmpty else { return false }

        let sharedCount = currentKeywords.intersection(promptKeywords).count
        return sharedCount <= 1 && currentKeywords != promptKeywords
    }

    private func normalizedThreadID(_ threadID: String) -> String {
        threadID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func threadDirectoryURL(for threadID: String) throws -> URL {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        return baseDirectoryURL
            .appendingPathComponent(normalizedThreadID, isDirectory: true)
    }

    private func memoryFileURL(for threadID: String) throws -> URL {
        try threadDirectoryURL(for: threadID)
            .appendingPathComponent("memory.md", isDirectory: false)
    }

    private func snapshotsDirectoryURL(for threadID: String) throws -> URL {
        try threadDirectoryURL(for: threadID)
            .appendingPathComponent("snapshots", isDirectory: true)
    }

    private func archiveCurrentDocument(_ document: AssistantThreadMemoryDocument, for threadID: String) throws {
        guard document.hasMeaningfulContent else { return }
        let snapshotsDirectory = try snapshotsDirectoryURL(for: threadID)
        try fileManager.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let filename = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".md"
        let snapshotURL = snapshotsDirectory.appendingPathComponent(filename, isDirectory: false)
        try document.markdown.write(to: snapshotURL, atomically: true, encoding: .utf8)
    }

    private func markObserved(threadID: String, fileURL: URL) throws {
        let resourceValues = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        lastObservedModifiedAtByThreadID[threadID] = resourceValues.contentModificationDate ?? Date()
    }
}
