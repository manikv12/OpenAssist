import AppKit
import Foundation

enum AssistantProjectStoreError: LocalizedError {
    case invalidProjectName
    case invalidProjectIconName
    case duplicateProjectName(String)
    case invalidNoteFolderName
    case duplicateNoteFolderName(String)
    case noteFolderNotFound
    case invalidParentNoteFolder
    case noteFolderNotEmpty
    case cannotMoveNoteFolderIntoItself
    case cannotMoveNoteFolderIntoDescendant
    case projectNotFound
    case invalidParentFolder
    case cannotNestFolders
    case cannotMoveFolder
    case cannotAssignThreadToFolder
    case foldersCannotLinkFolders
    case invalidThreadID

    var errorDescription: String? {
        switch self {
        case .invalidProjectName:
            return "Enter a group or project name first."
        case .invalidProjectIconName:
            return "Enter a valid SF Symbol name."
        case .duplicateProjectName(let name):
            return "An item named “\(name)” already exists here."
        case .invalidNoteFolderName:
            return "Enter a folder name first."
        case .duplicateNoteFolderName(let name):
            return "A note folder named “\(name)” already exists here."
        case .noteFolderNotFound:
            return "That note folder could not be found."
        case .invalidParentNoteFolder:
            return "Choose a valid parent note folder first."
        case .noteFolderNotEmpty:
            return "This note folder must be empty before you delete it."
        case .cannotMoveNoteFolderIntoItself:
            return "A note folder cannot move into itself."
        case .cannotMoveNoteFolderIntoDescendant:
            return "A note folder cannot move into one of its subfolders."
        case .projectNotFound:
            return "That group or project could not be found."
        case .invalidParentFolder:
            return "Choose a valid group first."
        case .cannotNestFolders:
            return "Groups can only live at the top level."
        case .cannotMoveFolder:
            return "Only projects can move into groups."
        case .cannotAssignThreadToFolder:
            return "Chats can only be assigned to projects."
        case .foldersCannotLinkFolders:
            return "Groups cannot link to a local folder."
        case .invalidThreadID:
            return "Enter a thread ID first."
        }
    }
}

enum AssistantProjectKind: String, Codable, Hashable, Sendable {
    case folder
    case project
}

struct AssistantProject: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var kind: AssistantProjectKind
    var name: String
    var parentID: String?
    var linkedFolderPath: String?
    var iconSymbolName: String?
    var isHidden: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        kind: AssistantProjectKind = .project,
        name: String,
        parentID: String? = nil,
        linkedFolderPath: String? = nil,
        iconSymbolName: String? = nil,
        isHidden: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.parentID = parentID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.linkedFolderPath = kind == .folder ? nil : linkedFolderPath
        self.iconSymbolName = Self.normalizedIconSymbolName(iconSymbolName)
        self.isHidden = isHidden
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case parentID
        case linkedFolderPath
        case iconSymbolName
        case isHidden
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decodeIfPresent(AssistantProjectKind.self, forKey: .kind) ?? .project
        name = try container.decode(String.self, forKey: .name)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        linkedFolderPath = kind == .folder
            ? nil
            : try container.decodeIfPresent(String.self, forKey: .linkedFolderPath)
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

    var isFolder: Bool {
        kind == .folder
    }

    var isProject: Bool {
        kind == .project
    }

    var defaultIconSymbolName: String {
        if kind == .folder {
            return "square.grid.2x2.fill"
        }
        return linkedFolderPath == nil ? "square.stack.3d.up.fill" : "folder.fill"
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
        version: 5,
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
    private static let currentSnapshotVersion = 5
    private static let projectNotesRootDirectoryName = "ProjectNotes"
    private static let projectNotesRecoveryDirectoryName = "ProjectNotesRecovery"
    private static let projectNotesDirectoryName = "notes"
    private static let projectNoteManifestFilename = "manifest.json"
    private static let defaultProjectNoteTitle = "Untitled note"
    private static let defaultProjectNoteFolderName = "Untitled folder"
    private let fileManager: FileManager
    private let fileURL: URL
    private let noteRecoveryStore: AssistantNoteRecoveryStore
    private var cachedSnapshot: AssistantProjectStoreSnapshot?

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let storageRootURL: URL
        if let baseDirectoryURL {
            storageRootURL = baseDirectoryURL
            self.fileURL = baseDirectoryURL
                .appendingPathComponent("projects.json", isDirectory: false)
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            storageRootURL = applicationSupport
                .appendingPathComponent("OpenAssist", isDirectory: true)
                .appendingPathComponent("AssistantProjects", isDirectory: true)
            self.fileURL = storageRootURL
                .appendingPathComponent("projects.json", isDirectory: false)
        }
        self.noteRecoveryStore = AssistantNoteRecoveryStore(
            fileManager: fileManager,
            recoveryRootURL: storageRootURL
                .appendingPathComponent(Self.projectNotesRecoveryDirectoryName, isDirectory: true)
        )
    }

    var storageURL: URL {
        fileURL
    }

    var storageRootURL: URL {
        fileURL.deletingLastPathComponent()
    }

    func projects() -> [AssistantProject] {
        loadSnapshot().projects
    }

    func visibleProjects() -> [AssistantProject] {
        let snapshot = loadSnapshot()
        return snapshot.projects.filter { isVisible($0, in: snapshot) }
    }

    func hiddenProjects() -> [AssistantProject] {
        loadSnapshot().projects.filter { $0.isHidden }
    }

    func childProjects(of parentID: String?) -> [AssistantProject] {
        let snapshot = loadSnapshot()
        let normalizedParentID = normalizedProjectID(parentID)
        return snapshot.projects.filter { project in
            switch (project.parentID, normalizedParentID) {
            case (nil, nil):
                return true
            case let (.some(projectParentID), .some(normalizedParentID)):
                return projectParentID.caseInsensitiveCompare(normalizedParentID) == .orderedSame
            default:
                return false
            }
        }
    }

    func descendantProjectIDs(ofFolderID folderID: String) -> Set<String> {
        let snapshot = loadSnapshot()
        let normalizedFolderID = normalizedProjectID(folderID)?.lowercased() ?? ""
        guard !normalizedFolderID.isEmpty else { return [] }
        return Set(snapshot.projects.compactMap { project in
            guard project.isProject,
                  project.parentID?.lowercased() == normalizedFolderID else {
                return nil
            }
            return project.id
        })
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

    func loadProjectNote(projectID: String) throws -> String {
        try loadProjectNotesWorkspace(projectID: projectID).selectedNoteText
    }

    func projectNoteModificationDate(projectID: String) throws -> Date? {
        try loadProjectNotesWorkspace(projectID: projectID).selectedNote?.updatedAt
    }

    /// Returns the on-disk URL for the given project note if it resolves and the
    /// underlying `.md` file currently exists.
    func projectNoteOnDiskURL(projectID: String, noteID: String) -> URL? {
        guard let normalizedProjectID = try? requiredLeafProjectID(projectID) else {
            return nil
        }
        let manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        guard
            let note = manifest.notes.first(where: {
                $0.id.caseInsensitiveCompare(noteID) == .orderedSame
            }),
            let fileURL = projectNoteFileURL(
                projectID: normalizedProjectID,
                fileName: note.fileName
            ),
            fileManager.fileExists(atPath: fileURL.path)
        else {
            return nil
        }
        return fileURL
    }

    func loadProjectNotesWorkspace(projectID: String) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        let manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        let selectedText = manifest.selectedNote.map {
            loadProjectNoteText(projectID: normalizedProjectID, fileName: $0.fileName)
        } ?? ""

        return AssistantNotesWorkspace(
            projectID: normalizedProjectID,
            manifest: manifest,
            selectedNoteText: selectedText
        )
    }

    func loadProjectStoredNotes(projectID: String) throws -> [AssistantStoredNote] {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        let manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        return manifest.orderedNotes.map { note in
            AssistantStoredNote(
                ownerKind: .project,
                ownerID: normalizedProjectID,
                noteID: note.id,
                title: note.title,
                noteType: note.noteType,
                fileName: note.fileName,
                folderID: note.folderID,
                updatedAt: note.updatedAt,
                text: loadProjectNoteText(projectID: normalizedProjectID, fileName: note.fileName)
            )
        }
    }

    func projectNoteFolders(projectID: String) throws -> [AssistantNoteFolderSummary] {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        return resolvedProjectNoteManifest(projectID: normalizedProjectID).orderedFolders
    }

    func projectNoteFolderPathMap(projectID: String) throws -> [String: [String]] {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        let manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        return noteFolderPathMap(for: manifest.folders)
    }

    func createProjectNoteFolder(
        projectID: String,
        parentFolderID: String? = nil,
        name: String
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        var manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        let normalizedParentFolderID = try validatedNoteParentFolderID(
            parentFolderID,
            folders: manifest.folders
        )
        let normalizedName = try validatedUniqueNoteFolderName(
            name,
            parentFolderID: normalizedParentFolderID,
            excludingFolderID: nil,
            folders: manifest.folders
        )
        let now = Date()
        manifest.folders.append(
            AssistantNoteFolderSummary(
                id: UUID().uuidString.lowercased(),
                name: normalizedName,
                parentFolderID: normalizedParentFolderID,
                createdAt: now,
                updatedAt: now
            )
        )
        try storeProjectNoteManifest(manifest, projectID: normalizedProjectID)
        return try loadProjectNotesWorkspace(projectID: normalizedProjectID)
    }

    func renameProjectNoteFolder(
        projectID: String,
        folderID: String,
        name: String
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        var manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        let normalizedFolderID = normalizedFolderID(folderID)
        guard let folderIndex = manifest.folders.firstIndex(where: {
            $0.id.caseInsensitiveCompare(normalizedFolderID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.noteFolderNotFound
        }
        let normalizedName = try validatedUniqueNoteFolderName(
            name,
            parentFolderID: manifest.folders[folderIndex].parentFolderID,
            excludingFolderID: normalizedFolderID,
            folders: manifest.folders
        )
        manifest.folders[folderIndex].name = normalizedName
        manifest.folders[folderIndex].updatedAt = Date()
        try storeProjectNoteManifest(manifest, projectID: normalizedProjectID)
        return try loadProjectNotesWorkspace(projectID: normalizedProjectID)
    }

    func moveProjectNoteFolder(
        projectID: String,
        folderID: String,
        parentFolderID: String?
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        var manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        let normalizedFolderID = normalizedFolderID(folderID)
        guard let folderIndex = manifest.folders.firstIndex(where: {
            $0.id.caseInsensitiveCompare(normalizedFolderID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.noteFolderNotFound
        }
        let normalizedParentFolderID = try validatedNoteParentFolderID(
            parentFolderID,
            folders: manifest.folders
        )
        if normalizedParentFolderID?.caseInsensitiveCompare(normalizedFolderID) == .orderedSame {
            throw AssistantProjectStoreError.cannotMoveNoteFolderIntoItself
        }
        if let normalizedParentFolderID,
           noteFolderDescendantIDs(folderID: normalizedFolderID, folders: manifest.folders)
            .contains(where: { $0.caseInsensitiveCompare(normalizedParentFolderID) == .orderedSame }) {
            throw AssistantProjectStoreError.cannotMoveNoteFolderIntoDescendant
        }
        let normalizedName = try validatedUniqueNoteFolderName(
            manifest.folders[folderIndex].name,
            parentFolderID: normalizedParentFolderID,
            excludingFolderID: normalizedFolderID,
            folders: manifest.folders
        )
        manifest.folders[folderIndex].name = normalizedName
        manifest.folders[folderIndex].parentFolderID = normalizedParentFolderID
        manifest.folders[folderIndex].updatedAt = Date()
        try storeProjectNoteManifest(manifest, projectID: normalizedProjectID)
        return try loadProjectNotesWorkspace(projectID: normalizedProjectID)
    }

    func deleteProjectNoteFolder(
        projectID: String,
        folderID: String
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        var manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        let normalizedFolderID = normalizedFolderID(folderID)
        guard let folderIndex = manifest.folders.firstIndex(where: {
            $0.id.caseInsensitiveCompare(normalizedFolderID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.noteFolderNotFound
        }
        let hasChildFolders = manifest.folders.contains {
            $0.parentFolderID?.caseInsensitiveCompare(normalizedFolderID) == .orderedSame
        }
        let hasNotes = manifest.notes.contains {
            $0.folderID?.caseInsensitiveCompare(normalizedFolderID) == .orderedSame
        }
        guard !hasChildFolders && !hasNotes else {
            throw AssistantProjectStoreError.noteFolderNotEmpty
        }
        manifest.folders.remove(at: folderIndex)
        try storeProjectNoteManifest(manifest, projectID: normalizedProjectID)
        return try loadProjectNotesWorkspace(projectID: normalizedProjectID)
    }

    func moveProjectNote(
        projectID: String,
        noteID: String,
        folderID: String?
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        var manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        let normalizedNoteID = noteID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let noteIndex = manifest.notes.firstIndex(where: {
            $0.id.caseInsensitiveCompare(normalizedNoteID) == .orderedSame
        }) else {
            return try loadProjectNotesWorkspace(projectID: normalizedProjectID)
        }
        let normalizedFolderID = try validatedNoteParentFolderID(
            folderID,
            folders: manifest.folders
        )
        manifest.notes[noteIndex].folderID = normalizedFolderID
        manifest.notes[noteIndex].updatedAt = Date()
        manifest.notes = normalizedProjectNoteItems(manifest.notes, folders: manifest.folders)
        try storeProjectNoteManifest(manifest, projectID: normalizedProjectID)
        let selectedText = manifest.selectedNote.map {
            loadProjectNoteText(projectID: normalizedProjectID, fileName: $0.fileName)
        } ?? ""
        return AssistantNotesWorkspace(
            projectID: normalizedProjectID,
            manifest: manifest,
            selectedNoteText: selectedText
        )
    }

    func createProjectNote(
        projectID: String,
        title: String? = nil,
        noteType: AssistantNoteType = .note,
        selectNewNote: Bool = true,
        folderID: String? = nil
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        var manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        let normalizedFolderID = try validatedNoteParentFolderID(folderID, folders: manifest.folders)
        let noteID = UUID().uuidString.lowercased()
        let now = Date()
        let note = AssistantNoteSummary(
            id: noteID,
            title: normalizedProjectNoteTitle(title),
            noteType: noteType,
            fileName: "\(safePathComponent(noteID)).md",
            folderID: normalizedFolderID,
            order: manifest.orderedNotes.count,
            createdAt: now,
            updatedAt: now
        )
        manifest.notes.append(note)
        manifest.notes = normalizedProjectNoteItems(manifest.notes, folders: manifest.folders)
        if selectNewNote || manifest.selectedNoteID == nil {
            manifest.selectedNoteID = note.id
        }
        try storeProjectNoteManifest(manifest, projectID: normalizedProjectID)

        return AssistantNotesWorkspace(
            projectID: normalizedProjectID,
            manifest: manifest,
            selectedNoteText: ""
        )
    }

    func renameProjectNote(
        projectID: String,
        noteID: String,
        title: String
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        var manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        guard let index = manifest.notes.firstIndex(where: { $0.id == noteID }) else {
            return try loadProjectNotesWorkspace(projectID: normalizedProjectID)
        }

        manifest.notes[index].title = normalizedProjectNoteTitle(title)
        manifest.notes[index].updatedAt = Date()
        manifest.notes = normalizedProjectNoteItems(manifest.notes, folders: manifest.folders)
        try storeProjectNoteManifest(manifest, projectID: normalizedProjectID)

        let selectedText = manifest.selectedNote.map {
            loadProjectNoteText(projectID: normalizedProjectID, fileName: $0.fileName)
        } ?? ""
        return AssistantNotesWorkspace(
            projectID: normalizedProjectID,
            manifest: manifest,
            selectedNoteText: selectedText
        )
    }

    func selectProjectNote(
        projectID: String,
        noteID: String
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        var manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        if manifest.notes.contains(where: { $0.id == noteID }) {
            manifest.selectedNoteID = noteID
            try storeProjectNoteManifest(manifest, projectID: normalizedProjectID)
        }

        let selectedText = manifest.selectedNote.map {
            loadProjectNoteText(projectID: normalizedProjectID, fileName: $0.fileName)
        } ?? ""
        return AssistantNotesWorkspace(
            projectID: normalizedProjectID,
            manifest: manifest,
            selectedNoteText: selectedText
        )
    }

    func saveProjectNoteImageAsset(
        projectID: String,
        noteID: String,
        attachment: AssistantAttachment
    ) throws -> AssistantSavedNoteAsset {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        let manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        guard let note = manifest.notes.first(where: { $0.id.caseInsensitiveCompare(noteID) == .orderedSame }),
              let notesDirectoryURL = projectNotesDirectoryURL(for: normalizedProjectID) else {
            throw AssistantNoteAssetError.noteNotFound
        }

        return try AssistantNoteAssetSupport.saveImageAsset(
            attachment: attachment,
            notesDirectoryURL: notesDirectoryURL,
            noteFileName: note.fileName,
            fileManager: fileManager
        )
    }

    func resolveProjectNoteImageAssetURL(
        projectID: String,
        noteID: String,
        relativePath: String
    ) throws -> URL? {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        let manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        guard let note = manifest.notes.first(where: { $0.id.caseInsensitiveCompare(noteID) == .orderedSame }),
              let notesDirectoryURL = projectNotesDirectoryURL(for: normalizedProjectID) else {
            return nil
        }

        return AssistantNoteAssetSupport.resolveAssetFileURL(
            notesDirectoryURL: notesDirectoryURL,
            noteFileName: note.fileName,
            relativePath: relativePath
        )
    }

    @discardableResult
    func saveProjectNote(
        projectID: String,
        noteID: String?,
        text: String,
        forceHistorySnapshot: Bool = false,
        now: Date = Date()
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        var manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        let resolvedNoteID: String
        if let noteID,
           manifest.notes.contains(where: { $0.id == noteID }) {
            resolvedNoteID = noteID
        } else if let selectedNoteID = manifest.selectedNote?.id {
            resolvedNoteID = selectedNoteID
        } else {
            return try createProjectNoteAndSave(
                projectID: normalizedProjectID,
                title: Self.defaultProjectNoteTitle,
                text: text
            )
        }

        guard let index = manifest.notes.firstIndex(where: { $0.id == resolvedNoteID }) else {
            return try loadProjectNotesWorkspace(projectID: normalizedProjectID)
        }

        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let note = manifest.notes[index]
        guard let fileURL = projectNoteFileURL(
            projectID: normalizedProjectID,
            fileName: note.fileName
        ) else {
            return try loadProjectNotesWorkspace(projectID: normalizedProjectID)
        }

        let previousText = loadProjectNoteText(projectID: normalizedProjectID, fileName: note.fileName)
        let previousTrimmed = previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTrimmed = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)

        if previousText == normalizedText {
            if manifest.selectedNoteID != resolvedNoteID {
                manifest.selectedNoteID = resolvedNoteID
                try storeProjectNoteManifest(manifest, projectID: normalizedProjectID)
            }
            return AssistantNotesWorkspace(
                projectID: normalizedProjectID,
                manifest: manifest,
                selectedNoteText: previousText
            )
        }

        if nextTrimmed.isEmpty, !previousTrimmed.isEmpty, !forceHistorySnapshot {
            return AssistantNotesWorkspace(
                projectID: normalizedProjectID,
                manifest: manifest,
                selectedNoteText: previousText
            )
        }

        if previousText != normalizedText {
            noteRecoveryStore.captureHistorySnapshot(
                note: note,
                ownerKind: .project,
                ownerID: normalizedProjectID,
                text: previousText,
                at: now,
                force: forceHistorySnapshot || nextTrimmed.isEmpty
            )
        }

        if nextTrimmed.isEmpty {
            try? fileManager.removeItem(at: fileURL)
        } else {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try normalizedText.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        manifest.selectedNoteID = resolvedNoteID
        manifest.notes[index].updatedAt = now
        manifest.notes = normalizedProjectNoteItems(manifest.notes, folders: manifest.folders)
        try storeProjectNoteManifest(manifest, projectID: normalizedProjectID)

        return AssistantNotesWorkspace(
            projectID: normalizedProjectID,
            manifest: manifest,
            selectedNoteText: normalizedText
        )
    }

    func deleteProjectNote(
        projectID: String,
        noteID: String,
        now: Date = Date()
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        var manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        guard let existingIndex = manifest.notes.firstIndex(where: { $0.id == noteID }) else {
            return try loadProjectNotesWorkspace(projectID: normalizedProjectID)
        }

        let removed = manifest.notes.remove(at: existingIndex)
        let removedText = loadProjectNoteText(projectID: normalizedProjectID, fileName: removed.fileName)
        let removedAssetDirectoryURL = projectNoteAssetDirectoryURL(
            projectID: normalizedProjectID,
            fileName: removed.fileName
        )
        noteRecoveryStore.captureDeletedNote(
            note: removed,
            ownerKind: .project,
            ownerID: normalizedProjectID,
            text: removedText,
            assetDirectoryURL: removedAssetDirectoryURL,
            at: now
        )
        if let fileURL = projectNoteFileURL(projectID: normalizedProjectID, fileName: removed.fileName) {
            try? fileManager.removeItem(at: fileURL)
        }
        if let removedAssetDirectoryURL {
            try? fileManager.removeItem(at: removedAssetDirectoryURL)
        }

        manifest.notes = normalizedProjectNoteItems(manifest.notes, folders: manifest.folders)
        if manifest.selectedNoteID == noteID {
            let fallbackIndex = min(existingIndex, max(0, manifest.notes.count - 1))
            manifest.selectedNoteID = manifest.notes.indices.contains(fallbackIndex)
                ? manifest.notes[fallbackIndex].id
                : nil
        }

        try storeProjectNoteManifest(manifest, projectID: normalizedProjectID)
        let selectedText = manifest.selectedNote.map {
            loadProjectNoteText(projectID: normalizedProjectID, fileName: $0.fileName)
        } ?? ""
        return AssistantNotesWorkspace(
            projectID: normalizedProjectID,
            manifest: manifest,
            selectedNoteText: selectedText
        )
    }

    func appendToSelectedProjectNote(
        projectID: String,
        text: String
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        let trimmedAppendText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAppendText.isEmpty else {
            return try loadProjectNotesWorkspace(projectID: normalizedProjectID)
        }

        let workspace = try loadProjectNotesWorkspace(projectID: normalizedProjectID)
        let currentText = workspace.selectedNoteText.trimmingCharacters(in: .newlines)
        let mergedText = currentText.isEmpty
            ? trimmedAppendText
            : currentText + "\n\n" + trimmedAppendText

        return try saveProjectNote(
            projectID: normalizedProjectID,
            noteID: workspace.selectedNote?.id,
            text: mergedText
        )
    }

    func projectNoteHistoryVersions(
        projectID: String,
        noteID: String
    ) throws -> [AssistantNoteHistoryVersion] {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        return noteRecoveryStore.historyVersions(
            ownerKind: .project,
            ownerID: normalizedProjectID,
            noteID: noteID
        )
    }

    func restoreProjectNoteHistoryVersion(
        projectID: String,
        noteID: String,
        versionID: String,
        now: Date = Date()
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        var manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        guard let noteIndex = manifest.notes.firstIndex(where: { $0.id == noteID }),
              let payload = noteRecoveryStore.restoreHistoryVersion(
                ownerKind: .project,
                ownerID: normalizedProjectID,
                noteID: noteID,
                versionID: versionID
              ) else {
            return try loadProjectNotesWorkspace(projectID: normalizedProjectID)
        }

        let currentNote = manifest.notes[noteIndex]
        let currentText = loadProjectNoteText(projectID: normalizedProjectID, fileName: currentNote.fileName)
        if currentText != payload.text || currentNote.title != payload.note.title {
            noteRecoveryStore.captureHistorySnapshot(
                note: currentNote,
                ownerKind: .project,
                ownerID: normalizedProjectID,
                text: currentText,
                at: now,
                force: true
            )
        }

        manifest.notes[noteIndex].title = normalizedProjectNoteTitle(payload.note.title)
        manifest.notes[noteIndex].folderID = payload.note.folderID
        manifest.notes[noteIndex].updatedAt = now
        manifest.selectedNoteID = noteID
        try writeProjectNoteText(
            projectID: normalizedProjectID,
            fileName: currentNote.fileName,
            text: payload.text
        )
        manifest.notes = normalizedProjectNoteItems(manifest.notes, folders: manifest.folders)
        try storeProjectNoteManifest(manifest, projectID: normalizedProjectID)
        return AssistantNotesWorkspace(
            projectID: normalizedProjectID,
            manifest: manifest,
            selectedNoteText: payload.text
        )
    }

    func deleteProjectNoteHistoryVersion(
        projectID: String,
        noteID: String,
        versionID: String
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        noteRecoveryStore.deleteHistoryVersion(
            ownerKind: .project,
            ownerID: normalizedProjectID,
            noteID: noteID,
            versionID: versionID
        )
        return try loadProjectNotesWorkspace(projectID: normalizedProjectID)
    }

    func recentlyDeletedProjectNotes(
        projectID: String,
        referenceDate: Date = Date()
    ) throws -> [AssistantDeletedNoteSnapshot] {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        return noteRecoveryStore.recentlyDeletedNotes(
            ownerKind: .project,
            ownerID: normalizedProjectID,
            referenceDate: referenceDate
        )
    }

    func restoreDeletedProjectNote(
        projectID: String,
        deletedNoteID: String,
        now: Date = Date()
    ) throws -> AssistantNotesWorkspace {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        guard let payload = noteRecoveryStore.restoreDeletedNote(
            ownerKind: .project,
            ownerID: normalizedProjectID,
            deletedID: deletedNoteID,
            referenceDate: now
        ) else {
            return try loadProjectNotesWorkspace(projectID: normalizedProjectID)
        }

        var manifest = resolvedProjectNoteManifest(projectID: normalizedProjectID)
        let restoredNoteID = manifest.notes.contains(where: {
            $0.id.caseInsensitiveCompare(payload.note.id) == .orderedSame
        }) ? UUID().uuidString.lowercased() : payload.note.id
        let restoredFileName = manifest.notes.contains(where: {
            $0.fileName.caseInsensitiveCompare(payload.note.fileName) == .orderedSame
        }) ? "\(safePathComponent(restoredNoteID)).md" : payload.note.fileName

        let restoredNote = AssistantNoteSummary(
            id: restoredNoteID,
            title: normalizedProjectNoteTitle(payload.note.title),
            fileName: restoredFileName,
            folderID: payload.note.folderID,
            order: manifest.orderedNotes.count,
            createdAt: payload.note.createdAt,
            updatedAt: now
        )
        manifest.notes.append(restoredNote)
        manifest.selectedNoteID = restoredNote.id
        manifest.notes = normalizedProjectNoteItems(manifest.notes, folders: manifest.folders)
        try writeProjectNoteText(
            projectID: normalizedProjectID,
            fileName: restoredNote.fileName,
            text: payload.text
        )
        if let assetDirectoryURL = payload.assetDirectoryURL,
           fileManager.fileExists(atPath: assetDirectoryURL.path),
           let restoredAssetDirectoryURL = projectNoteAssetDirectoryURL(
            projectID: normalizedProjectID,
            fileName: restoredNote.fileName
           ) {
            try? fileManager.removeItem(at: restoredAssetDirectoryURL)
            do {
                try fileManager.copyItem(at: assetDirectoryURL, to: restoredAssetDirectoryURL)
                try? fileManager.removeItem(at: assetDirectoryURL)
            } catch {}
        }
        try storeProjectNoteManifest(manifest, projectID: normalizedProjectID)
        return AssistantNotesWorkspace(
            projectID: normalizedProjectID,
            manifest: manifest,
            selectedNoteText: payload.text
        )
    }

    func permanentlyDeleteDeletedProjectNote(
        projectID: String,
        deletedNoteID: String
    ) throws {
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        noteRecoveryStore.permanentlyDeleteDeletedNote(
            ownerKind: .project,
            ownerID: normalizedProjectID,
            deletedID: deletedNoteID
        )
    }

    func createProject(
        name: String,
        linkedFolderPath: String? = nil,
        parentID: String? = nil,
        now: Date = Date()
    ) throws -> AssistantProject {
        var snapshot = loadSnapshot()
        let normalizedParentID = try validatedParentFolderID(parentID, in: snapshot)
        let normalizedFolderPath = normalizedLinkedFolderPath(linkedFolderPath)
        if let existingIndex = projectIndex(
            forLinkedFolderPath: normalizedFolderPath,
            excludingProjectID: nil,
            in: snapshot
        ) {
            _ = try validatedUniqueName(
                snapshot.projects[existingIndex].name,
                parentID: normalizedParentID,
                excludingProjectID: snapshot.projects[existingIndex].id,
                in: snapshot
            )
            snapshot.projects[existingIndex].isHidden = false
            snapshot.projects[existingIndex].parentID = normalizedParentID
            snapshot.projects[existingIndex].updatedAt = now
            snapshot.brainByProjectID[snapshot.projects[existingIndex].id] =
                snapshot.brainByProjectID[snapshot.projects[existingIndex].id] ?? AssistantProjectBrainState()
            try saveSnapshot(snapshot)
            return snapshot.projects[existingIndex]
        }

        let normalizedName = try validatedUniqueName(
            name,
            parentID: normalizedParentID,
            excludingProjectID: nil,
            in: snapshot
        )
        let project = AssistantProject(
            kind: .project,
            name: normalizedName,
            parentID: normalizedParentID,
            linkedFolderPath: normalizedFolderPath,
            createdAt: now,
            updatedAt: now
        )
        snapshot.projects.append(project)
        snapshot.brainByProjectID[project.id] = snapshot.brainByProjectID[project.id] ?? AssistantProjectBrainState()
        try saveSnapshot(snapshot)
        return project
    }

    func createFolder(
        name: String,
        now: Date = Date()
    ) throws -> AssistantProject {
        var snapshot = loadSnapshot()
        let normalizedName = try validatedUniqueName(
            name,
            parentID: nil,
            excludingProjectID: nil,
            in: snapshot
        )
        let folder = AssistantProject(
            kind: .folder,
            name: normalizedName,
            createdAt: now,
            updatedAt: now
        )
        snapshot.projects.append(folder)
        try saveSnapshot(snapshot)
        return folder
    }

    func renameProject(
        id projectID: String,
        to newName: String,
        now: Date = Date()
    ) throws -> AssistantProject {
        let normalizedProjectID = try requiredProjectID(projectID)
        var snapshot = loadSnapshot()
        guard let index = snapshot.projects.firstIndex(where: {
            $0.id.caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.projectNotFound
        }
        let normalizedName = try validatedUniqueName(
            newName,
            parentID: snapshot.projects[index].parentID,
            excludingProjectID: normalizedProjectID,
            in: snapshot
        )

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
        guard snapshot.projects[index].isProject else {
            throw AssistantProjectStoreError.foldersCannotLinkFolders
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

    func moveProject(
        id projectID: String,
        toFolderID folderID: String?,
        now: Date = Date()
    ) throws -> AssistantProject {
        let normalizedProjectID = try requiredProjectID(projectID)
        var snapshot = loadSnapshot()
        guard let index = snapshot.projects.firstIndex(where: {
            $0.id.caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.projectNotFound
        }
        guard snapshot.projects[index].isProject else {
            throw AssistantProjectStoreError.cannotMoveFolder
        }

        let normalizedFolderID = try validatedParentFolderID(folderID, in: snapshot)
        let normalizedName = try validatedUniqueName(
            snapshot.projects[index].name,
            parentID: normalizedFolderID,
            excludingProjectID: normalizedProjectID,
            in: snapshot
        )
        snapshot.projects[index].name = normalizedName
        snapshot.projects[index].parentID = normalizedFolderID
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
    func deleteProjectResult(
        id projectID: String,
        now: Date = Date()
    ) throws -> AssistantProjectDeletionResult {
        let normalizedProjectID = try requiredProjectID(projectID)
        var snapshot = loadSnapshot()
        guard let index = snapshot.projects.firstIndex(where: {
            $0.id.caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.projectNotFound
        }

        let removed = snapshot.projects.remove(at: index)
        let removedThreadIDs: [String]
        if removed.isFolder {
            let childProjects = snapshot.projects.filter {
                $0.parentID?.caseInsensitiveCompare(normalizedProjectID) == .orderedSame
            }
            let rootSiblingNames = Set(
                snapshot.projects.compactMap { project -> String? in
                    guard project.parentID == nil else { return nil }
                    return MemoryTextNormalizer.collapsedWhitespace(project.name).lowercased()
                }
            )
            for childProject in childProjects {
                let normalizedChildName = MemoryTextNormalizer.collapsedWhitespace(childProject.name).lowercased()
                if rootSiblingNames.contains(normalizedChildName) {
                    throw AssistantProjectStoreError.duplicateProjectName(childProject.name)
                }
            }
            for childIndex in snapshot.projects.indices where
                snapshot.projects[childIndex].parentID?.caseInsensitiveCompare(normalizedProjectID) == .orderedSame {
                snapshot.projects[childIndex].parentID = nil
                snapshot.projects[childIndex].updatedAt = max(snapshot.projects[childIndex].updatedAt, now)
            }
            removedThreadIDs = []
            snapshot.brainByProjectID.removeValue(forKey: normalizedProjectID)
        } else {
            removedThreadIDs = snapshot.threadAssignments.compactMap { threadID, assignedProjectID in
                assignedProjectID.caseInsensitiveCompare(normalizedProjectID) == .orderedSame ? threadID : nil
            }
            snapshot.brainByProjectID.removeValue(forKey: normalizedProjectID)
            snapshot.threadAssignments = snapshot.threadAssignments.filter { _, assignedProjectID in
                assignedProjectID.caseInsensitiveCompare(normalizedProjectID) != .orderedSame
            }
            deleteProjectNoteArtifacts(projectID: normalizedProjectID)
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
        guard snapshot.projects[index].isProject else {
            throw AssistantProjectStoreError.cannotAssignThreadToFolder
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
        let normalizedProjectID = try requiredLeafProjectID(projectID)
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
        let normalizedProjectID = try requiredLeafProjectID(projectID)
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
        let normalizedProjectID = try requiredLeafProjectID(projectID)
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
        let normalizedProjectID = try requiredLeafProjectID(projectID)
        var snapshot = loadSnapshot()
        snapshot.brainByProjectID[normalizedProjectID] = state
        try saveSnapshot(snapshot)
    }

    private func projectNotesRootDirectoryURL() -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(Self.projectNotesRootDirectoryName, isDirectory: true)
    }

    private func projectNotesDirectoryURL(for projectID: String) -> URL? {
        let safeProjectID = safePathComponent(projectID)
        guard !safeProjectID.isEmpty else { return nil }
        return projectNotesRootDirectoryURL()
            .appendingPathComponent(safeProjectID, isDirectory: true)
            .appendingPathComponent(Self.projectNotesDirectoryName, isDirectory: true)
    }

    private func projectNoteManifestFileURL(for projectID: String) -> URL? {
        projectNotesDirectoryURL(for: projectID)?
            .appendingPathComponent(Self.projectNoteManifestFilename, isDirectory: false)
    }

    private func projectNoteFileURL(projectID: String, fileName: String) -> URL? {
        projectNotesDirectoryURL(for: projectID)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func projectNoteAssetDirectoryURL(projectID: String, fileName: String) -> URL? {
        guard let notesDirectoryURL = projectNotesDirectoryURL(for: projectID) else {
            return nil
        }

        return AssistantNoteAssetSupport.noteAssetDirectoryURL(
            notesDirectoryURL: notesDirectoryURL,
            noteFileName: fileName
        )
    }

    private func writeProjectNoteText(
        projectID: String,
        fileName: String,
        text: String
    ) throws {
        guard let fileURL = projectNoteFileURL(projectID: projectID, fileName: fileName) else {
            return
        }
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fileManager.removeItem(at: fileURL)
            return
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try normalizedText.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func loadProjectNoteText(projectID: String, fileName: String) -> String {
        guard let fileURL = projectNoteFileURL(projectID: projectID, fileName: fileName),
              fileManager.fileExists(atPath: fileURL.path),
              let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return ""
        }
        return contents.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func resolvedProjectNoteManifest(projectID: String) -> AssistantNoteManifest {
        guard let manifestURL = projectNoteManifestFileURL(for: projectID),
              fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode(AssistantNoteManifest.self, from: data) else {
            return AssistantNoteManifest()
        }

        return normalizedProjectNoteManifest(decoded)
    }

    private func storeProjectNoteManifest(
        _ manifest: AssistantNoteManifest,
        projectID: String
    ) throws {
        let normalizedManifest = normalizedProjectNoteManifest(manifest)
        guard let manifestURL = projectNoteManifestFileURL(for: projectID) else { return }

        if normalizedManifest.notes.isEmpty && normalizedManifest.folders.isEmpty {
            try? fileManager.removeItem(at: manifestURL)
            if let notesDirectoryURL = projectNotesDirectoryURL(for: projectID) {
                try? fileManager.removeItem(at: notesDirectoryURL)
                let projectNotesRoot = notesDirectoryURL.deletingLastPathComponent()
                try? removeDirectoryIfEmpty(projectNotesRoot)
                try? removeDirectoryIfEmpty(projectNotesRoot.deletingLastPathComponent())
            }
            return
        }

        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalizedManifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func normalizedProjectNoteManifest(
        _ manifest: AssistantNoteManifest
    ) -> AssistantNoteManifest {
        let normalizedFolders = normalizedProjectNoteFolders(manifest.folders)
        let normalizedNotes = normalizedProjectNoteItems(
            manifest.notes,
            folders: normalizedFolders
        )
        let selectedNoteID = normalizedNotes.contains(where: { $0.id == manifest.selectedNoteID })
            ? manifest.selectedNoteID
            : normalizedNotes.first?.id
        return AssistantNoteManifest(
            version: max(manifest.version, AssistantNoteManifest.currentVersion),
            selectedNoteID: selectedNoteID,
            notes: normalizedNotes,
            folders: normalizedFolders
        )
    }

    private func normalizedProjectNoteFolders(
        _ folders: [AssistantNoteFolderSummary]
    ) -> [AssistantNoteFolderSummary] {
        var seenFolderIDs = Set<String>()
        var normalized = folders.compactMap { folder -> AssistantNoteFolderSummary? in
            let normalizedID = normalizedFolderID(folder.id)
            guard !normalizedID.isEmpty else { return nil }
            let foldedID = normalizedID.lowercased()
            guard seenFolderIDs.insert(foldedID).inserted else { return nil }
            return AssistantNoteFolderSummary(
                id: normalizedID,
                name: normalizedProjectNoteFolderName(folder.name),
                parentFolderID: folder.parentFolderID,
                createdAt: folder.createdAt,
                updatedAt: folder.updatedAt
            )
        }

        guard !normalized.isEmpty else { return [] }

        var folderIndexByID = Dictionary(
            uniqueKeysWithValues: normalized.enumerated().map { index, folder in
                (folder.id.lowercased(), index)
            }
        )

        for index in normalized.indices {
            if let parentFolderID = normalized[index].parentFolderID {
                let normalizedParentFolderID = normalizedFolderID(parentFolderID).lowercased()
                if normalizedParentFolderID.isEmpty
                    || normalizedParentFolderID == normalized[index].id.lowercased()
                    || folderIndexByID[normalizedParentFolderID] == nil
                {
                    normalized[index].parentFolderID = nil
                } else {
                    normalized[index].parentFolderID = normalized[folderIndexByID[normalizedParentFolderID]!].id
                }
            }
        }

        var changed = true
        while changed {
            changed = false
            folderIndexByID = Dictionary(
                uniqueKeysWithValues: normalized.enumerated().map { index, folder in
                    (folder.id.lowercased(), index)
                }
            )
            for index in normalized.indices {
                guard let parentFolderID = normalized[index].parentFolderID else { continue }
                var cursor = parentFolderID.lowercased()
                var visited = Set([normalized[index].id.lowercased()])
                while let parentIndex = folderIndexByID[cursor] {
                    if !visited.insert(cursor).inserted {
                        normalized[index].parentFolderID = nil
                        changed = true
                        break
                    }
                    guard let nextParentID = normalized[parentIndex].parentFolderID else { break }
                    cursor = nextParentID.lowercased()
                }
            }
        }

        return normalized.sorted { lhs, rhs in
            switch (lhs.parentFolderID, rhs.parentFolderID) {
            case let (.some(leftParent), .some(rightParent)):
                let parentCompare = leftParent.localizedCaseInsensitiveCompare(rightParent)
                if parentCompare != .orderedSame {
                    return parentCompare == .orderedAscending
                }
            case (nil, .some):
                return true
            case (.some, nil):
                return false
            case (nil, nil):
                break
            }
            let nameCompare = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameCompare != .orderedSame {
                return nameCompare == .orderedAscending
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private func normalizedProjectNoteItems(
        _ notes: [AssistantNoteSummary],
        folders: [AssistantNoteFolderSummary]
    ) -> [AssistantNoteSummary] {
        let validFolderIDs = Set(folders.map { $0.id.lowercased() })
        return notes
            .sorted {
                if $0.order == $1.order {
                    return $0.createdAt < $1.createdAt
                }
                return $0.order < $1.order
            }
            .enumerated()
            .map { index, note in
                var updated = note
                updated.title = normalizedProjectNoteTitle(note.title)
                updated.folderID = updated.folderID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty.flatMap { validFolderIDs.contains($0.lowercased()) ? $0 : nil }
                updated.order = index
                return updated
            }
    }

    private func normalizedProjectNoteTitle(_ title: String?) -> String {
        title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? Self.defaultProjectNoteTitle
    }

    private func normalizedProjectNoteFolderName(_ title: String?) -> String {
        title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? Self.defaultProjectNoteFolderName
    }

    private func normalizedFolderID(_ folderID: String?) -> String {
        folderID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func validatedUniqueNoteFolderName(
        _ name: String,
        parentFolderID: String?,
        excludingFolderID: String?,
        folders: [AssistantNoteFolderSummary]
    ) throws -> String {
        let normalizedName = MemoryTextNormalizer.collapsedWhitespace(name)
        guard !normalizedName.isEmpty else {
            throw AssistantProjectStoreError.invalidNoteFolderName
        }
        let normalizedParentFolderID = normalizedFolderID(parentFolderID).lowercased()
        let excludedFolderID = normalizedFolderID(excludingFolderID).lowercased()
        if folders.contains(where: { folder in
            folder.name.caseInsensitiveCompare(normalizedName) == .orderedSame
                && normalizedFolderID(folder.parentFolderID).lowercased() == normalizedParentFolderID
                && folder.id.lowercased() != excludedFolderID
        }) {
            throw AssistantProjectStoreError.duplicateNoteFolderName(normalizedName)
        }
        return normalizedName
    }

    private func validatedNoteParentFolderID(
        _ folderID: String?,
        folders: [AssistantNoteFolderSummary]
    ) throws -> String? {
        let normalizedParentFolderID = normalizedFolderID(folderID)
        guard !normalizedParentFolderID.isEmpty else { return nil }
        guard let folder = folders.first(where: {
            $0.id.caseInsensitiveCompare(normalizedParentFolderID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.invalidParentNoteFolder
        }
        return folder.id
    }

    private func noteFolderDescendantIDs(
        folderID: String,
        folders: [AssistantNoteFolderSummary]
    ) -> Set<String> {
        let rootFolderID = folderID.lowercased()
        guard !rootFolderID.isEmpty else { return [] }
        let childrenByParentID = Dictionary(grouping: folders) { folder in
            normalizedFolderID(folder.parentFolderID).lowercased()
        }
        var descendants: Set<String> = []
        var stack = childrenByParentID[rootFolderID, default: []]
        while let folder = stack.popLast() {
            let foldedID = folder.id.lowercased()
            guard descendants.insert(foldedID).inserted else { continue }
            stack.append(contentsOf: childrenByParentID[foldedID, default: []])
        }
        return descendants
    }

    private func noteFolderPathMap(
        for folders: [AssistantNoteFolderSummary]
    ) -> [String: [String]] {
        let foldersByID = Dictionary(
            uniqueKeysWithValues: folders.map { ($0.id.lowercased(), $0) }
        )
        var cache: [String: [String]] = [:]

        func buildPath(for folder: AssistantNoteFolderSummary, visited: Set<String>) -> [String] {
            let foldedID = folder.id.lowercased()
            if let cached = cache[foldedID] {
                return cached
            }
            if visited.contains(foldedID) {
                return [folder.name]
            }
            let nextVisited = visited.union([foldedID])
            let path: [String]
            if let parentFolderID = folder.parentFolderID?.lowercased(),
               let parent = foldersByID[parentFolderID] {
                path = buildPath(for: parent, visited: nextVisited) + [folder.name]
            } else {
                path = [folder.name]
            }
            cache[foldedID] = path
            return path
        }

        return folders.reduce(into: [:]) { result, folder in
            result[folder.id] = buildPath(for: folder, visited: [])
        }
    }

    private func createProjectNoteAndSave(
        projectID: String,
        title: String,
        text: String,
        noteType: AssistantNoteType = .note,
        folderID: String? = nil
    ) throws -> AssistantNotesWorkspace {
        let createdWorkspace = try createProjectNote(
            projectID: projectID,
            title: title,
            noteType: noteType,
            selectNewNote: true,
            folderID: folderID
        )
        return try saveProjectNote(
            projectID: projectID,
            noteID: createdWorkspace.selectedNote?.id,
            text: text
        )
    }

    private func deleteProjectNoteArtifacts(projectID: String) {
        guard let notesDirectoryURL = projectNotesDirectoryURL(for: projectID) else { return }
        let projectDirectoryURL = notesDirectoryURL.deletingLastPathComponent()
        let projectNotesRoot = projectDirectoryURL.deletingLastPathComponent()
        try? fileManager.removeItem(at: projectDirectoryURL)
        noteRecoveryStore.removeAllRecoveryData(ownerKind: .project, ownerID: projectID)
        try? removeDirectoryIfEmpty(projectNotesRoot)
    }

    private func removeDirectoryIfEmpty(_ directoryURL: URL) throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        guard contents.isEmpty else { return }
        try fileManager.removeItem(at: directoryURL)
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
        let normalizedHierarchy = normalizeHierarchy(in: snapshot)
        let normalized = normalizeDuplicateLinkedFolderProjects(in: normalizedHierarchy.snapshot)
        let changed = normalizedHierarchy.changed || normalized.changed
        if changed {
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
        parentID: String?,
        excludingProjectID projectID: String?,
        in snapshot: AssistantProjectStoreSnapshot
    ) throws -> String {
        let normalizedName = MemoryTextNormalizer.collapsedWhitespace(name)
        guard !normalizedName.isEmpty else {
            throw AssistantProjectStoreError.invalidProjectName
        }

        let excludedProjectID = normalizedProjectID(projectID)
        let normalizedParentID = normalizedProjectID(parentID)
        if snapshot.projects.contains(where: {
            $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
                && (($0.parentID == nil && normalizedParentID == nil)
                    || $0.parentID?.caseInsensitiveCompare(normalizedParentID ?? "") == .orderedSame)
                && $0.id.caseInsensitiveCompare(excludedProjectID ?? "") != .orderedSame
        }) {
            throw AssistantProjectStoreError.duplicateProjectName(normalizedName)
        }

        return normalizedName
    }

    private func validatedParentFolderID(
        _ parentID: String?,
        in snapshot: AssistantProjectStoreSnapshot
    ) throws -> String? {
        guard let normalizedParentID = normalizedProjectID(parentID) else {
            return nil
        }
        guard let parent = snapshot.projects.first(where: {
            $0.id.caseInsensitiveCompare(normalizedParentID) == .orderedSame
        }) else {
            throw AssistantProjectStoreError.invalidParentFolder
        }
        guard parent.isFolder else {
            throw AssistantProjectStoreError.invalidParentFolder
        }
        guard parent.parentID == nil else {
            throw AssistantProjectStoreError.cannotNestFolders
        }
        return parent.id
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

    private func requiredLeafProjectID(_ projectID: String?) throws -> String {
        let normalizedProjectID = try requiredProjectID(projectID)
        guard let project = project(forProjectID: normalizedProjectID) else {
            throw AssistantProjectStoreError.projectNotFound
        }
        guard project.isProject else {
            throw AssistantProjectStoreError.cannotAssignThreadToFolder
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

    private func safePathComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[^A-Za-z0-9._-]+"#,
                with: "-",
                options: .regularExpression
            )
    }

    private func linkedFolderComparisonKey(_ linkedFolderPath: String?) -> String? {
        normalizedLinkedFolderPath(linkedFolderPath)?.lowercased()
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
            guard project.isProject else {
                return false
            }
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
        mergedProject.parentID = keepingProject.parentID ?? removingProject.parentID
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
                guard project.isProject else {
                    return nil
                }
                guard let linkedFolderPath = linkedFolderComparisonKey(project.linkedFolderPath) else {
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

    private func normalizeHierarchy(
        in snapshot: AssistantProjectStoreSnapshot
    ) -> (snapshot: AssistantProjectStoreSnapshot, changed: Bool) {
        var normalizedSnapshot = snapshot
        var changed = false

        for index in normalizedSnapshot.projects.indices {
            if normalizedSnapshot.projects[index].isFolder {
                if normalizedSnapshot.projects[index].parentID != nil {
                    normalizedSnapshot.projects[index].parentID = nil
                    changed = true
                }
                if normalizedSnapshot.projects[index].linkedFolderPath != nil {
                    normalizedSnapshot.projects[index].linkedFolderPath = nil
                    changed = true
                }
            }
        }

        let foldersByID = Dictionary(
            uniqueKeysWithValues: normalizedSnapshot.projects.filter(\.isFolder).map { ($0.id.lowercased(), $0) }
        )

        for index in normalizedSnapshot.projects.indices where normalizedSnapshot.projects[index].isProject {
            guard let parentID = normalizedSnapshot.projects[index].parentID?.lowercased() else {
                continue
            }
            guard let parent = foldersByID[parentID], parent.parentID == nil else {
                normalizedSnapshot.projects[index].parentID = nil
                changed = true
                continue
            }
        }

        let validProjectIDs = Set(
            normalizedSnapshot.projects.filter(\.isProject).map { $0.id.lowercased() }
        )
        let filteredAssignments = normalizedSnapshot.threadAssignments.filter { _, assignedProjectID in
            validProjectIDs.contains(assignedProjectID.lowercased())
        }
        if filteredAssignments.count != normalizedSnapshot.threadAssignments.count {
            normalizedSnapshot.threadAssignments = filteredAssignments
            changed = true
        }

        let filteredBrain = normalizedSnapshot.brainByProjectID.filter { projectID, _ in
            validProjectIDs.contains(projectID.lowercased())
        }
        if filteredBrain.count != normalizedSnapshot.brainByProjectID.count {
            normalizedSnapshot.brainByProjectID = filteredBrain
            changed = true
        }

        return (normalizedSnapshot, changed)
    }

    private func isVisible(
        _ project: AssistantProject,
        in snapshot: AssistantProjectStoreSnapshot
    ) -> Bool {
        guard !project.isHidden else {
            return false
        }

        let projectsByID = Dictionary(
            uniqueKeysWithValues: snapshot.projects.map { ($0.id.lowercased(), $0) }
        )
        var ancestorID = project.parentID?.lowercased()
        var visited = Set<String>()
        while let currentAncestorID = ancestorID, !currentAncestorID.isEmpty, !visited.contains(currentAncestorID) {
            visited.insert(currentAncestorID)
            guard let ancestor = projectsByID[currentAncestorID] else {
                break
            }
            if ancestor.isHidden {
                return false
            }
            ancestorID = ancestor.parentID?.lowercased()
        }

        return true
    }
}
