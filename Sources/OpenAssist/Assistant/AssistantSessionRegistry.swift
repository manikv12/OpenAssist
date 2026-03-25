import Foundation

struct AssistantSessionRegistrySnapshot: Codable {
    var version: Int
    var sessions: [AssistantSessionSummary]

    static let empty = AssistantSessionRegistrySnapshot(
        version: 2,
        sessions: []
    )
}

final class AssistantSessionRegistry {
    private static let currentSnapshotVersion = 2
    private static let maxStoredSessions = 200

    private let fileManager: FileManager
    private let fileURL: URL
    private var cachedSnapshot: AssistantSessionRegistrySnapshot?

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        if let baseDirectoryURL {
            self.fileURL = baseDirectoryURL
                .appendingPathComponent("session-registry.json", isDirectory: false)
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = applicationSupport
                .appendingPathComponent("OpenAssist", isDirectory: true)
                .appendingPathComponent("AssistantSessionRegistry", isDirectory: true)
                .appendingPathComponent("session-registry.json", isDirectory: false)
        }
    }

    var storageURL: URL {
        fileURL
    }

    func sessions(
        sources: Set<AssistantSessionSource>? = nil,
        sessionIDs: Set<String>? = nil
    ) -> [AssistantSessionSummary] {
        let snapshot = loadSnapshot()
        return snapshot.sessions.filter { session in
            if let sources, !sources.contains(session.source) {
                return false
            }
            if let sessionIDs {
                guard let normalizedSessionID = normalizedSessionID(session.id) else {
                    return false
                }
                return sessionIDs.contains(normalizedSessionID)
            }
            return true
        }
    }

    func replaceSessions(
        _ sessions: [AssistantSessionSummary],
        for sources: Set<AssistantSessionSource>
    ) throws {
        var snapshot = loadSnapshot()
        snapshot.sessions.removeAll { sources.contains($0.source) }
        snapshot.sessions.append(contentsOf: sessions)
        snapshot.sessions = normalizedSessions(snapshot.sessions)
        try saveSnapshot(snapshot)
    }

    func remove(sessionID: String?, source: AssistantSessionSource? = nil) throws {
        guard let targetSessionID = normalizedSessionID(sessionID) else { return }
        var snapshot = loadSnapshot()
        snapshot.sessions.removeAll { session in
            guard normalizedSessionID(session.id) == targetSessionID else {
                return false
            }
            guard let source else { return true }
            return session.source == source
        }
        try saveSnapshot(snapshot)
    }

    func setArchiveState(
        sessionIDs: [String],
        sources: Set<AssistantSessionSource>? = nil,
        isArchived: Bool,
        archivedAt: Date?,
        expiresAt: Date?,
        usesDefaultRetention: Bool?
    ) throws {
        let normalizedTargetIDs = Set(sessionIDs.compactMap { normalizedSessionID($0) })
        guard !normalizedTargetIDs.isEmpty else { return }

        var snapshot = loadSnapshot()
        var didChange = false

        for index in snapshot.sessions.indices {
            let session = snapshot.sessions[index]
            guard let normalizedID = normalizedSessionID(session.id),
                  normalizedTargetIDs.contains(normalizedID) else {
                continue
            }
            if let sources, !sources.contains(session.source) {
                continue
            }

            snapshot.sessions[index].isArchived = isArchived
            snapshot.sessions[index].archivedAt = archivedAt
            snapshot.sessions[index].archiveExpiresAt = expiresAt
            snapshot.sessions[index].archiveUsesDefaultRetention = usesDefaultRetention
            didChange = true
        }

        guard didChange else { return }
        try saveSnapshot(snapshot)
    }

    func expiredArchivedSessionIDs(
        asOf referenceDate: Date = Date(),
        sources: Set<AssistantSessionSource>? = nil
    ) -> [String] {
        let snapshot = loadSnapshot()
        var seen = Set<String>()

        return snapshot.sessions.compactMap { session in
            if let sources, !sources.contains(session.source) {
                return nil
            }
            guard session.isArchived,
                  let expiresAt = session.archiveExpiresAt,
                  expiresAt <= referenceDate,
                  let normalizedID = normalizedSessionID(session.id),
                  seen.insert(normalizedID).inserted else {
                return nil
            }
            return session.id
        }
    }

    private func loadSnapshot() -> AssistantSessionRegistrySnapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }

        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              var snapshot = try? JSONDecoder().decode(AssistantSessionRegistrySnapshot.self, from: data) else {
            cachedSnapshot = .empty
            return .empty
        }

        snapshot.version = max(snapshot.version, Self.currentSnapshotVersion)
        snapshot.sessions = normalizedSessions(snapshot.sessions)
        cachedSnapshot = snapshot
        return snapshot
    }

    private func saveSnapshot(_ snapshot: AssistantSessionRegistrySnapshot) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        cachedSnapshot = snapshot
    }

    private func normalizedSessions(_ sessions: [AssistantSessionSummary]) -> [AssistantSessionSummary] {
        var ordered: [AssistantSessionSummary] = []
        var seen = Set<String>()

        let sortedSessions = sessions.sorted {
            let lhsDate = $0.updatedAt ?? $0.createdAt ?? .distantPast
            let rhsDate = $1.updatedAt ?? $1.createdAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }

        for session in sortedSessions {
            let key = [
                session.source.rawValue.lowercased(),
                normalizedSessionID(session.id) ?? session.id.lowercased()
            ].joined(separator: "::")
            guard seen.insert(key).inserted else { continue }
            ordered.append(session)
            if ordered.count >= Self.maxStoredSessions {
                break
            }
        }

        return ordered
    }

    private func normalizedSessionID(_ sessionID: String?) -> String? {
        sessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .lowercased()
    }
}
