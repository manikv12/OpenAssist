import AppKit
import Foundation

enum AssistantProjectStoreError: LocalizedError {
    case invalidProjectName
    case invalidProjectIconName
    case duplicateProjectName(String)
    case projectNotFound
    case invalidThreadID

    var errorDescription: String? {
        switch self {
        case .invalidProjectName:
            return "Enter a project name first."
        case .invalidProjectIconName:
            return "Enter a valid SF Symbol name."
        case .duplicateProjectName(let name):
            return "A project named “\(name)” already exists."
        case .projectNotFound:
            return "That project could not be found."
        case .invalidThreadID:
            return "Enter a thread ID first."
        }
    }
}

struct AssistantProject: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var linkedFolderPath: String?
    var iconSymbolName: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        linkedFolderPath: String? = nil,
        iconSymbolName: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.linkedFolderPath = linkedFolderPath
        self.iconSymbolName = Self.normalizedIconSymbolName(iconSymbolName)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayIconSymbolName: String {
        if let iconSymbolName,
           Self.isValidIconSymbolName(iconSymbolName) {
            return iconSymbolName
        }
        return defaultIconSymbolName
    }

    var defaultIconSymbolName: String {
        linkedFolderPath == nil ? "square.stack.3d.up.fill" : "folder.fill"
    }

    static func normalizedLinkedFolderPath(_ linkedFolderPath: String?) -> String? {
        guard let linkedFolderPath = linkedFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        return URL(fileURLWithPath: linkedFolderPath, isDirectory: true).standardizedFileURL.path
    }

    static func normalizedIconSymbolName(_ iconSymbolName: String?) -> String? {
        iconSymbolName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    static func isValidIconSymbolName(_ iconSymbolName: String) -> Bool {
        NSImage(systemSymbolName: iconSymbolName, accessibilityDescription: nil) != nil
    }
}

struct AssistantProjectThreadDigest: Codable, Hashable, Sendable {
    var threadID: String
    var threadTitle: String
    var summary: String
    var updatedAt: Date
}

struct AssistantProjectBrainState: Codable, Hashable, Sendable {
    var projectSummary: String?
    var threadDigestsByThreadID: [String: AssistantProjectThreadDigest]
    var lastProcessedTranscriptFingerprintByThreadID: [String: String]
    var lastProcessedAt: Date?

    init(
        projectSummary: String? = nil,
        threadDigestsByThreadID: [String: AssistantProjectThreadDigest] = [:],
        lastProcessedTranscriptFingerprintByThreadID: [String: String] = [:],
        lastProcessedAt: Date? = nil
    ) {
        self.projectSummary = projectSummary
        self.threadDigestsByThreadID = threadDigestsByThreadID
        self.lastProcessedTranscriptFingerprintByThreadID = lastProcessedTranscriptFingerprintByThreadID
        self.lastProcessedAt = lastProcessedAt
    }
}

struct AssistantProjectStoreSnapshot: Codable {
    var version: Int
    var projects: [AssistantProject]
    var threadAssignments: [String: String]
    var brainByProjectID: [String: AssistantProjectBrainState]

    static let empty = AssistantProjectStoreSnapshot(
        version: 2,
        projects: [],
        threadAssignments: [:],
        brainByProjectID: [:]
    )
}

struct AssistantProjectContext: Sendable {
    let project: AssistantProject
    let brainState: AssistantProjectBrainState
}

struct AssistantProjectDeletionResult: Sendable {
    let project: AssistantProject
    let removedThreadIDs: [String]
}

final class AssistantProjectStore {
    private static let currentSnapshotVersion = 2
    private let fileManager: FileManager
    private let fileURL: URL
    private var cachedSnapshot: AssistantProjectStoreSnapshot?

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        if let baseDirectoryURL {
            self.fileURL = baseDirectoryURL
                .appendingPathComponent("projects.json", isDirectory: false)
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = applicationSupport
                .appendingPathComponent("OpenAssist", isDirectory: true)
                .appendingPathComponent("AssistantProjects", isDirectory: true)
                .appendingPathComponent("projects.json", isDirectory: false)
        }
    }

    var storageURL: URL {
        fileURL
    }

    func projects() -> [AssistantProject] {
        loadSnapshot().projects
    }

    func snapshot() -> AssistantProjectStoreSnapshot {
        loadSnapshot()
    }

    func brainState(forProjectID projectID: String) -> AssistantProjectBrainState {
        guard let normalizedProjectID = normalizedProjectID(projectID) else {
            return AssistantProjectBrainState()
        }
        return loadSnapshot().brainByProjectID[normalizedProjectID] ?? AssistantProjectBrainState()
    }

    func project(forProjectID projectID: String?) -> AssistantProject? {
        guard let normalizedProjectID = normalizedProjectID(projectID) else { return nil }
        return loadSnapshot().projects.first {
            $0.id.caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }
    }

    func context(forThreadID threadID: String?) -> AssistantProjectContext? {
        guard let projectID = assignedProjectID(forThreadID: threadID),
              let project = project(forProjectID: projectID) else {
            return nil
        }
        return AssistantProjectContext(
            project: project,
            brainState: brainState(forProjectID: projectID)
        )
    }

    func assignedProjectID(forThreadID threadID: String?) -> String? {
        guard let normalizedThreadID = normalizedThreadID(threadID) else { return nil }
        return loadSnapshot().threadAssignments[normalizedThreadID]
    }

    func createProject(
        name: String,
        linkedFolderPath: String? = nil,
        now: Date = Date()
    ) throws -> AssistantProject {
        let normalizedName = try validatedUniqueName(name, excludingProjectID: nil)
        var snapshot = loadSnapshot()
        let project = AssistantProject(
            name: normalizedName,
            linkedFolderPath: normalizedLinkedFolderPath(linkedFolderPath),
            createdAt: now,
            updatedAt: now
        )
        snapshot.projects.append(project)
        snapshot.brainByProjectID[project.id] = snapshot.brainByProjectID[project.id] ?? AssistantProjectBrainState()
        try saveSnapshot(snapshot)
        return project
    }

    func renameProject(
        id projectID: String,
        to newName: String,
        now: Date = Date()
    ) throws -> AssistantProject {
        let normalizedProjectID = try requiredProjectID(projectID)
        let normalizedName = try validatedUniqueName(newName, excludingProjectID: normalizedProjectID)
        var snapshot = loadSnapshot()
        guard let index = snapshot.projects.firstIndex(where: {
            $0.id.caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.projectNotFound
        }

        snapshot.projects[index].name = normalizedName
        snapshot.projects[index].updatedAt = now
        try saveSnapshot(snapshot)
        return snapshot.projects[index]
    }

    func setLinkedFolderPath(
        _ linkedFolderPath: String?,
        forProjectID projectID: String,
        now: Date = Date()
    ) throws -> AssistantProject {
        let normalizedProjectID = try requiredProjectID(projectID)
        var snapshot = loadSnapshot()
        guard let index = snapshot.projects.firstIndex(where: {
            $0.id.caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.projectNotFound
        }

        snapshot.projects[index].linkedFolderPath = normalizedLinkedFolderPath(linkedFolderPath)
        snapshot.projects[index].updatedAt = now
        try saveSnapshot(snapshot)
        return snapshot.projects[index]
    }

    func updateLinkedFolderPath(
        for projectID: String,
        path: String?,
        now: Date = Date()
    ) throws -> AssistantProject {
        try setLinkedFolderPath(path, forProjectID: projectID, now: now)
    }

    func setIconSymbol(
        _ iconSymbolName: String?,
        forProjectID projectID: String,
        now: Date = Date()
    ) throws -> AssistantProject {
        let normalizedProjectID = try requiredProjectID(projectID)
        let normalizedIconSymbolName = AssistantProject.normalizedIconSymbolName(iconSymbolName)
        if let normalizedIconSymbolName,
           !AssistantProject.isValidIconSymbolName(normalizedIconSymbolName) {
            throw AssistantProjectStoreError.invalidProjectIconName
        }

        var snapshot = loadSnapshot()
        guard let index = snapshot.projects.firstIndex(where: {
            $0.id.caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.projectNotFound
        }

        snapshot.projects[index].iconSymbolName = normalizedIconSymbolName
        snapshot.projects[index].updatedAt = now
        try saveSnapshot(snapshot)
        return snapshot.projects[index]
    }

    @discardableResult
    func deleteProject(id projectID: String) throws -> AssistantProject {
        try deleteProjectResult(id: projectID).project
    }

    @discardableResult
    func deleteProjectResult(id projectID: String) throws -> AssistantProjectDeletionResult {
        let normalizedProjectID = try requiredProjectID(projectID)
        var snapshot = loadSnapshot()
        guard let index = snapshot.projects.firstIndex(where: {
            $0.id.caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.projectNotFound
        }

        let removed = snapshot.projects.remove(at: index)
        let removedThreadIDs = snapshot.threadAssignments.compactMap { threadID, assignedProjectID in
            assignedProjectID.caseInsensitiveCompare(normalizedProjectID) == .orderedSame ? threadID : nil
        }
        snapshot.brainByProjectID.removeValue(forKey: normalizedProjectID)
        snapshot.threadAssignments = snapshot.threadAssignments.filter { _, assignedProjectID in
            assignedProjectID.caseInsensitiveCompare(normalizedProjectID) != .orderedSame
        }
        try saveSnapshot(snapshot)
        return AssistantProjectDeletionResult(
            project: removed,
            removedThreadIDs: removedThreadIDs.sorted()
        )
    }

    func assignThread(
        _ threadID: String,
        toProjectID projectID: String,
        now: Date = Date()
    ) throws {
        let normalizedThreadID = try requiredThreadID(threadID)
        let normalizedProjectID = try requiredProjectID(projectID)
        var snapshot = loadSnapshot()
        guard let index = snapshot.projects.firstIndex(where: {
            $0.id.caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.projectNotFound
        }

        snapshot.threadAssignments[normalizedThreadID] = normalizedProjectID
        snapshot.projects[index].updatedAt = now
        snapshot.brainByProjectID[normalizedProjectID] = snapshot.brainByProjectID[normalizedProjectID] ?? AssistantProjectBrainState()
        try saveSnapshot(snapshot)
    }

    func removeThreadAssignment(
        _ threadID: String,
        now: Date = Date()
    ) throws -> String? {
        guard let normalizedThreadID = normalizedThreadID(threadID) else { return nil }
        var snapshot = loadSnapshot()
        let removedProjectID = snapshot.threadAssignments.removeValue(forKey: normalizedThreadID)
        if let removedProjectID,
           let index = snapshot.projects.firstIndex(where: {
               $0.id.caseInsensitiveCompare(removedProjectID) == .orderedSame
           }) {
            snapshot.projects[index].updatedAt = now
        }
        try saveSnapshot(snapshot)
        return removedProjectID
    }

    func updateThreadDigest(
        projectID: String,
        threadID: String,
        threadTitle: String,
        summary: String,
        fingerprint: String,
        processedAt: Date = Date()
    ) throws {
        let normalizedProjectID = try requiredProjectID(projectID)
        let normalizedThreadID = try requiredThreadID(threadID)
        var snapshot = loadSnapshot()
        var brain = snapshot.brainByProjectID[normalizedProjectID] ?? AssistantProjectBrainState()
        brain.threadDigestsByThreadID[normalizedThreadID] = AssistantProjectThreadDigest(
            threadID: normalizedThreadID,
            threadTitle: MemoryTextNormalizer.collapsedWhitespace(threadTitle).nonEmpty ?? "Untitled Thread",
            summary: MemoryTextNormalizer.normalizedSummary(summary, limit: 700),
            updatedAt: processedAt
        )
        brain.lastProcessedTranscriptFingerprintByThreadID[normalizedThreadID] = fingerprint
        brain.lastProcessedAt = processedAt
        snapshot.brainByProjectID[normalizedProjectID] = brain
        try saveSnapshot(snapshot)
    }

    func removeThreadDigest(
        projectID: String,
        threadID: String,
        processedAt: Date = Date()
    ) throws {
        let normalizedProjectID = try requiredProjectID(projectID)
        guard let normalizedThreadID = normalizedThreadID(threadID) else { return }
        var snapshot = loadSnapshot()
        var brain = snapshot.brainByProjectID[normalizedProjectID] ?? AssistantProjectBrainState()
        brain.threadDigestsByThreadID.removeValue(forKey: normalizedThreadID)
        brain.lastProcessedTranscriptFingerprintByThreadID.removeValue(forKey: normalizedThreadID)
        brain.lastProcessedAt = processedAt
        snapshot.brainByProjectID[normalizedProjectID] = brain
        try saveSnapshot(snapshot)
    }

    func removeThreadState(
        _ threadID: String,
        from projectID: String,
        processedAt: Date = Date()
    ) throws {
        try removeThreadDigest(
            projectID: projectID,
            threadID: threadID,
            processedAt: processedAt
        )
    }

    func setProjectSummary(
        _ summary: String?,
        forProjectID projectID: String,
        processedAt: Date = Date()
    ) throws {
        let normalizedProjectID = try requiredProjectID(projectID)
        var snapshot = loadSnapshot()
        var brain = snapshot.brainByProjectID[normalizedProjectID] ?? AssistantProjectBrainState()
        brain.projectSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        brain.lastProcessedAt = processedAt
        snapshot.brainByProjectID[normalizedProjectID] = brain
        try saveSnapshot(snapshot)
    }

    func replaceBrainState(
        _ state: AssistantProjectBrainState,
        forProjectID projectID: String
    ) throws {
        let normalizedProjectID = try requiredProjectID(projectID)
        var snapshot = loadSnapshot()
        snapshot.brainByProjectID[normalizedProjectID] = state
        try saveSnapshot(snapshot)
    }

    private func loadSnapshot() -> AssistantProjectStoreSnapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }

        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              var snapshot = try? JSONDecoder().decode(AssistantProjectStoreSnapshot.self, from: data) else {
            cachedSnapshot = .empty
            return .empty
        }

        if snapshot.version < Self.currentSnapshotVersion {
            snapshot.version = Self.currentSnapshotVersion
        }
        cachedSnapshot = snapshot
        return snapshot
    }

    private func saveSnapshot(_ snapshot: AssistantProjectStoreSnapshot) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var snapshot = snapshot
        snapshot.version = Self.currentSnapshotVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        cachedSnapshot = snapshot
    }

    private func validatedUniqueName(
        _ name: String,
        excludingProjectID projectID: String?
    ) throws -> String {
        let normalizedName = MemoryTextNormalizer.collapsedWhitespace(name)
        guard !normalizedName.isEmpty else {
            throw AssistantProjectStoreError.invalidProjectName
        }

        let excludedProjectID = normalizedProjectID(projectID)
        if loadSnapshot().projects.contains(where: {
            $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
                && $0.id.caseInsensitiveCompare(excludedProjectID ?? "") != .orderedSame
        }) {
            throw AssistantProjectStoreError.duplicateProjectName(normalizedName)
        }

        return normalizedName
    }

    private func normalizedProjectID(_ projectID: String?) -> String? {
        projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func requiredProjectID(_ projectID: String?) throws -> String {
        guard let normalizedProjectID = normalizedProjectID(projectID) else {
            throw AssistantProjectStoreError.projectNotFound
        }
        return normalizedProjectID
    }

    private func normalizedThreadID(_ threadID: String?) -> String? {
        threadID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func requiredThreadID(_ threadID: String?) throws -> String {
        guard let normalizedThreadID = normalizedThreadID(threadID) else {
            throw AssistantProjectStoreError.invalidThreadID
        }
        return normalizedThreadID
    }

    private func normalizedLinkedFolderPath(_ linkedFolderPath: String?) -> String? {
        AssistantProject.normalizedLinkedFolderPath(linkedFolderPath)
    }
}
