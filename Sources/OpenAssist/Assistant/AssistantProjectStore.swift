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
    var isHidden: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        linkedFolderPath: String? = nil,
        iconSymbolName: String? = nil,
        isHidden: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.linkedFolderPath = linkedFolderPath
        self.iconSymbolName = Self.normalizedIconSymbolName(iconSymbolName)
        self.isHidden = isHidden
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case linkedFolderPath
        case iconSymbolName
        case isHidden
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        linkedFolderPath = try container.decodeIfPresent(String.self, forKey: .linkedFolderPath)
        iconSymbolName = Self.normalizedIconSymbolName(try container.decodeIfPresent(String.self, forKey: .iconSymbolName))
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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

    static func suggestedName(forLinkedFolderPath linkedFolderPath: String?) -> String {
        guard let normalizedPath = normalizedLinkedFolderPath(linkedFolderPath) else {
            return "Project"
        }

        let folderURL = URL(fileURLWithPath: normalizedPath, isDirectory: true)
        let suggestedName = folderURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !suggestedName.isEmpty, suggestedName != "/" {
            return suggestedName
        }

        return "Project"
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
        version: 3,
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
    private static let currentSnapshotVersion = 4
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

    func visibleProjects() -> [AssistantProject] {
        loadSnapshot().projects.filter { !$0.isHidden }
    }

    func hiddenProjects() -> [AssistantProject] {
        loadSnapshot().projects.filter { $0.isHidden }
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
        var snapshot = loadSnapshot()
        let normalizedFolderPath = normalizedLinkedFolderPath(linkedFolderPath)
        if let existingIndex = projectIndex(
            forLinkedFolderPath: normalizedFolderPath,
            excludingProjectID: nil,
            in: snapshot
        ) {
            snapshot.projects[existingIndex].isHidden = false
            snapshot.projects[existingIndex].updatedAt = now
            try saveSnapshot(snapshot)
            return snapshot.projects[existingIndex]
        }

        let normalizedName = try validatedUniqueName(name, excludingProjectID: nil)
        let project = AssistantProject(
            name: normalizedName,
            linkedFolderPath: normalizedFolderPath,
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

        let normalizedFolderPath = normalizedLinkedFolderPath(linkedFolderPath)
        if let duplicateIndex = projectIndex(
            forLinkedFolderPath: normalizedFolderPath,
            excludingProjectID: normalizedProjectID,
            in: snapshot
        ) {
            let currentProject = snapshot.projects[index]
            let duplicateProject = snapshot.projects[duplicateIndex]
            let survivingProjectID =
                preferredProjectIDForSharedLinkedFolder(
                    currentProject: currentProject,
                    existingProject: duplicateProject
                )
            let removedProjectID =
                survivingProjectID.caseInsensitiveCompare(currentProject.id) == .orderedSame
                ? duplicateProject.id
                : currentProject.id
            let mergedProject = mergeProjects(
                keepingProjectID: survivingProjectID,
                removingProjectID: removedProjectID,
                now: now,
                into: &snapshot
            )
            try saveSnapshot(snapshot)
            return mergedProject
        }

        snapshot.projects[index].linkedFolderPath = normalizedFolderPath
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
    func hideProject(id projectID: String, now: Date = Date()) throws -> AssistantProject {
        try setProjectHidden(projectID, isHidden: true, now: now)
    }

    @discardableResult
    func unhideProject(id projectID: String, now: Date = Date()) throws -> AssistantProject {
        try setProjectHidden(projectID, isHidden: false, now: now)
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

    private func setProjectHidden(
        _ projectID: String,
        isHidden: Bool,
        now: Date = Date()
    ) throws -> AssistantProject {
        let normalizedProjectID = try requiredProjectID(projectID)
        var snapshot = loadSnapshot()
        guard let index = snapshot.projects.firstIndex(where: {
            $0.id.caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.projectNotFound
        }

        snapshot.projects[index].isHidden = isHidden
        snapshot.projects[index].updatedAt = now
        try saveSnapshot(snapshot)
        return snapshot.projects[index]
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
        let normalized = normalizeDuplicateLinkedFolderProjects(in: snapshot)
        if normalized.changed {
            try? saveSnapshot(normalized.snapshot)
        } else {
            cachedSnapshot = normalized.snapshot
        }
        return normalized.snapshot
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

    private func projectIndex(
        forLinkedFolderPath linkedFolderPath: String?,
        excludingProjectID projectID: String?,
        in snapshot: AssistantProjectStoreSnapshot
    ) -> Int? {
        guard let normalizedFolderPath = normalizedLinkedFolderPath(linkedFolderPath) else {
            return nil
        }
        let excludedProjectID = normalizedProjectID(projectID)
        return snapshot.projects.firstIndex { project in
            guard let projectPath = normalizedLinkedFolderPath(project.linkedFolderPath) else {
                return false
            }
            guard projectPath.caseInsensitiveCompare(normalizedFolderPath) == .orderedSame else {
                return false
            }
            guard let excludedProjectID else { return true }
            return project.id.caseInsensitiveCompare(excludedProjectID) != .orderedSame
        }
    }

    private func preferredProjectIDForSharedLinkedFolder(
        currentProject: AssistantProject,
        existingProject: AssistantProject
    ) -> String {
        if currentProject.isHidden != existingProject.isHidden {
            return currentProject.isHidden ? existingProject.id : currentProject.id
        }

        let currentHasCustomIcon = currentProject.iconSymbolName != nil
        let existingHasCustomIcon = existingProject.iconSymbolName != nil
        if currentHasCustomIcon != existingHasCustomIcon {
            return currentHasCustomIcon ? currentProject.id : existingProject.id
        }

        if currentProject.updatedAt != existingProject.updatedAt {
            return currentProject.updatedAt > existingProject.updatedAt
                ? currentProject.id
                : existingProject.id
        }

        return currentProject.createdAt <= existingProject.createdAt
            ? currentProject.id
            : existingProject.id
    }

    private func mergeProjects(
        keepingProjectID: String,
        removingProjectID: String,
        now: Date,
        into snapshot: inout AssistantProjectStoreSnapshot
    ) -> AssistantProject {
        guard
            let keepingIndex = snapshot.projects.firstIndex(where: {
                $0.id.caseInsensitiveCompare(keepingProjectID) == .orderedSame
            }),
            let removingIndex = snapshot.projects.firstIndex(where: {
                $0.id.caseInsensitiveCompare(removingProjectID) == .orderedSame
            })
        else {
            return snapshot.projects.first { project in
                project.id.caseInsensitiveCompare(keepingProjectID) == .orderedSame
            } ?? AssistantProject(name: "Project")
        }

        let keepingProject = snapshot.projects[keepingIndex]
        let removingProject = snapshot.projects[removingIndex]
        let mergedBrain = mergeBrainState(
            primary: snapshot.brainByProjectID[keepingProject.id] ?? AssistantProjectBrainState(),
            secondary: snapshot.brainByProjectID[removingProject.id] ?? AssistantProjectBrainState()
        )

        snapshot.threadAssignments = snapshot.threadAssignments.mapValues { assignedProjectID in
            assignedProjectID.caseInsensitiveCompare(removingProject.id) == .orderedSame
                ? keepingProject.id
                : assignedProjectID
        }

        var mergedProject = keepingProject
        mergedProject.linkedFolderPath = keepingProject.linkedFolderPath ?? removingProject.linkedFolderPath
        mergedProject.iconSymbolName = keepingProject.iconSymbolName ?? removingProject.iconSymbolName
        mergedProject.isHidden = keepingProject.isHidden && removingProject.isHidden
        mergedProject.updatedAt = max(max(keepingProject.updatedAt, removingProject.updatedAt), now)

        snapshot.projects[keepingIndex] = mergedProject
        snapshot.brainByProjectID[keepingProject.id] = mergedBrain
        snapshot.brainByProjectID.removeValue(forKey: removingProject.id)
        snapshot.projects.remove(at: removingIndex)

        return snapshot.projects.first(where: {
            $0.id.caseInsensitiveCompare(keepingProject.id) == .orderedSame
        }) ?? mergedProject
    }

    private func mergeBrainState(
        primary: AssistantProjectBrainState,
        secondary: AssistantProjectBrainState
    ) -> AssistantProjectBrainState {
        var merged = primary

        if merged.projectSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            merged.projectSummary = secondary.projectSummary
        }

        for (threadID, digest) in secondary.threadDigestsByThreadID {
            if let existing = merged.threadDigestsByThreadID[threadID] {
                if digest.updatedAt > existing.updatedAt {
                    merged.threadDigestsByThreadID[threadID] = digest
                    if let fingerprint = secondary.lastProcessedTranscriptFingerprintByThreadID[threadID] {
                        merged.lastProcessedTranscriptFingerprintByThreadID[threadID] = fingerprint
                    }
                } else if merged.lastProcessedTranscriptFingerprintByThreadID[threadID] == nil,
                          let fingerprint = secondary.lastProcessedTranscriptFingerprintByThreadID[threadID] {
                    merged.lastProcessedTranscriptFingerprintByThreadID[threadID] = fingerprint
                }
            } else {
                merged.threadDigestsByThreadID[threadID] = digest
                if let fingerprint = secondary.lastProcessedTranscriptFingerprintByThreadID[threadID] {
                    merged.lastProcessedTranscriptFingerprintByThreadID[threadID] = fingerprint
                }
            }
        }

        for (threadID, fingerprint) in secondary.lastProcessedTranscriptFingerprintByThreadID
        where merged.lastProcessedTranscriptFingerprintByThreadID[threadID] == nil {
            merged.lastProcessedTranscriptFingerprintByThreadID[threadID] = fingerprint
        }

        switch (merged.lastProcessedAt, secondary.lastProcessedAt) {
        case (.some(let current), .some(let incoming)):
            merged.lastProcessedAt = max(current, incoming)
        case (.none, .some(let incoming)):
            merged.lastProcessedAt = incoming
        default:
            break
        }

        return merged
    }

    private func normalizeDuplicateLinkedFolderProjects(
        in snapshot: AssistantProjectStoreSnapshot
    ) -> (snapshot: AssistantProjectStoreSnapshot, changed: Bool) {
        var normalizedSnapshot = snapshot
        var changed = false

        let groupedProjects = Dictionary(
            grouping: normalizedSnapshot.projects.compactMap { project -> (String, AssistantProject)? in
                guard let linkedFolderPath = normalizedLinkedFolderPath(project.linkedFolderPath) else {
                    return nil
                }
                return (linkedFolderPath, project)
            },
            by: { $0.0 }
        )

        for group in groupedProjects.values where group.count > 1 {
            let projects = group.map(\.1)
            guard var survivingProject = projects.first else { continue }

            for candidate in projects.dropFirst() {
                let preferredProjectID = preferredProjectIDForSharedLinkedFolder(
                    currentProject: candidate,
                    existingProject: survivingProject
                )
                let removingProjectID =
                    preferredProjectID.caseInsensitiveCompare(candidate.id) == .orderedSame
                    ? survivingProject.id
                    : candidate.id
                survivingProject = mergeProjects(
                    keepingProjectID: preferredProjectID,
                    removingProjectID: removingProjectID,
                    now: max(candidate.updatedAt, survivingProject.updatedAt),
                    into: &normalizedSnapshot
                )
                changed = true
            }
        }

        return (normalizedSnapshot, changed)
    }
}
