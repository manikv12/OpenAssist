import Foundation

struct AssistantThreadSkillStoreSnapshot: Codable {
    var version: Int
    var bindings: [AssistantThreadSkillBinding]

    static let empty = AssistantThreadSkillStoreSnapshot(
        version: 1,
        bindings: []
    )
}

final class AssistantThreadSkillStore {
    private static let currentSnapshotVersion = 1

    private let fileManager: FileManager
    private let fileURL: URL
    private var cachedSnapshot: AssistantThreadSkillStoreSnapshot?

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        if let baseDirectoryURL {
            self.fileURL = baseDirectoryURL
                .appendingPathComponent("thread-skills.json", isDirectory: false)
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = applicationSupport
                .appendingPathComponent("OpenAssist", isDirectory: true)
                .appendingPathComponent("AssistantThreadSkills", isDirectory: true)
                .appendingPathComponent("thread-skills.json", isDirectory: false)
        }
    }

    var storageURL: URL {
        fileURL
    }

    func bindings(for threadID: String?) -> [AssistantThreadSkillBinding] {
        guard let normalizedThreadID = normalizedThreadID(threadID) else {
            return []
        }

        return loadSnapshot().bindings
            .filter { $0.threadID == normalizedThreadID }
            .sorted { $0.attachedAt < $1.attachedAt }
    }

    func contains(skillName: String, for threadID: String?) -> Bool {
        guard let normalizedThreadID = normalizedThreadID(threadID),
              let normalizedSkillName = assistantNormalizedSkillIdentifier(skillName) else {
            return false
        }

        return loadSnapshot().bindings.contains {
            $0.threadID == normalizedThreadID && $0.skillName == normalizedSkillName
        }
    }

    func attach(skillName: String, to threadID: String, now: Date = Date()) throws {
        let normalizedThreadID = try validatedThreadID(threadID)
        guard let normalizedSkillName = assistantNormalizedSkillIdentifier(skillName) else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        var snapshot = loadSnapshot()
        guard !snapshot.bindings.contains(where: {
            $0.threadID == normalizedThreadID && $0.skillName == normalizedSkillName
        }) else {
            return
        }

        snapshot.bindings.append(
            AssistantThreadSkillBinding(
                threadID: normalizedThreadID,
                skillName: normalizedSkillName,
                attachedAt: now
            )
        )
        try saveSnapshot(snapshot)
    }

    func detach(skillName: String, from threadID: String?) throws {
        guard let normalizedThreadID = normalizedThreadID(threadID),
              let normalizedSkillName = assistantNormalizedSkillIdentifier(skillName) else {
            return
        }

        var snapshot = loadSnapshot()
        snapshot.bindings.removeAll {
            $0.threadID == normalizedThreadID && $0.skillName == normalizedSkillName
        }
        try saveSnapshot(snapshot)
    }

    func migrateBindings(from sourceThreadID: String?, to destinationThreadID: String?) throws {
        guard let sourceThreadID = normalizedThreadID(sourceThreadID),
              let destinationThreadID = normalizedThreadID(destinationThreadID),
              sourceThreadID != destinationThreadID else {
            return
        }

        let sourceBindings = bindings(for: sourceThreadID)
        guard !sourceBindings.isEmpty else { return }

        for binding in sourceBindings {
            try attach(skillName: binding.skillName, to: destinationThreadID, now: binding.attachedAt)
        }
    }

    private func loadSnapshot() -> AssistantThreadSkillStoreSnapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }

        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              var snapshot = try? JSONDecoder().decode(AssistantThreadSkillStoreSnapshot.self, from: data) else {
            cachedSnapshot = .empty
            return .empty
        }

        snapshot.version = max(snapshot.version, Self.currentSnapshotVersion)
        snapshot.bindings = snapshot.bindings.compactMap { binding in
            guard let normalizedThreadID = normalizedThreadID(binding.threadID),
                  let normalizedSkillName = assistantNormalizedSkillIdentifier(binding.skillName) else {
                return nil
            }

            return AssistantThreadSkillBinding(
                threadID: normalizedThreadID,
                skillName: normalizedSkillName,
                attachedAt: binding.attachedAt
            )
        }
        snapshot.bindings.sort { lhs, rhs in
            if lhs.threadID != rhs.threadID {
                return lhs.threadID < rhs.threadID
            }
            if lhs.attachedAt != rhs.attachedAt {
                return lhs.attachedAt < rhs.attachedAt
            }
            return lhs.skillName < rhs.skillName
        }
        cachedSnapshot = snapshot
        return snapshot
    }

    private func saveSnapshot(_ snapshot: AssistantThreadSkillStoreSnapshot) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        cachedSnapshot = snapshot
    }

    private func normalizedThreadID(_ threadID: String?) -> String? {
        threadID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .lowercased()
    }

    private func validatedThreadID(_ threadID: String) throws -> String {
        guard let normalizedThreadID = normalizedThreadID(threadID) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return normalizedThreadID
    }
}

