import Foundation

struct AssistantTemporarySessionStoreSnapshot: Codable {
    var version: Int
    var temporarySessionIDs: [String]

    static let empty = AssistantTemporarySessionStoreSnapshot(
        version: 1,
        temporarySessionIDs: []
    )
}

final class AssistantTemporarySessionStore {
    private static let currentSnapshotVersion = 1

    private let fileManager: FileManager
    private let fileURL: URL
    private var cachedSnapshot: AssistantTemporarySessionStoreSnapshot?

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        if let baseDirectoryURL {
            self.fileURL = baseDirectoryURL
                .appendingPathComponent("temporary-sessions.json", isDirectory: false)
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = applicationSupport
                .appendingPathComponent("OpenAssist", isDirectory: true)
                .appendingPathComponent("AssistantTemporarySessions", isDirectory: true)
                .appendingPathComponent("temporary-sessions.json", isDirectory: false)
        }
    }

    var storageURL: URL {
        fileURL
    }

    func temporarySessionIDs() -> Set<String> {
        Set(loadSnapshot().temporarySessionIDs)
    }

    func contains(_ sessionID: String?) -> Bool {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            return false
        }
        return loadSnapshot().temporarySessionIDs.contains(normalizedSessionID)
    }

    func markTemporary(_ sessionID: String) throws {
        let normalizedSessionID = try validatedSessionID(sessionID)
        var snapshot = loadSnapshot()
        if !snapshot.temporarySessionIDs.contains(normalizedSessionID) {
            snapshot.temporarySessionIDs.append(normalizedSessionID)
        }
        try saveSnapshot(snapshot)
    }

    func removeTemporaryFlag(_ sessionID: String?) throws {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            return
        }
        var snapshot = loadSnapshot()
        snapshot.temporarySessionIDs.removeAll { $0 == normalizedSessionID }
        try saveSnapshot(snapshot)
    }

    private func loadSnapshot() -> AssistantTemporarySessionStoreSnapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }

        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              var snapshot = try? JSONDecoder().decode(AssistantTemporarySessionStoreSnapshot.self, from: data) else {
            cachedSnapshot = .empty
            return .empty
        }

        snapshot.version = max(snapshot.version, Self.currentSnapshotVersion)
        snapshot.temporarySessionIDs = Array(
            Set(snapshot.temporarySessionIDs.compactMap { normalizedSessionID($0) })
        ).sorted()
        cachedSnapshot = snapshot
        return snapshot
    }

    private func saveSnapshot(_ snapshot: AssistantTemporarySessionStoreSnapshot) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        cachedSnapshot = snapshot
    }

    private func normalizedSessionID(_ sessionID: String?) -> String? {
        sessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .lowercased()
    }

    private func validatedSessionID(_ sessionID: String) throws -> String {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return normalizedSessionID
    }
}
