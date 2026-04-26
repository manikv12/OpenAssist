import Foundation

struct AssistantConversationTurnRecord: Codable, Equatable, Sendable {
    let threadID: String
    let openAssistTurnID: String
    let provider: AssistantRuntimeBackend?
    let providerSessionID: String?
    let providerTurnID: String?
    let messageIDs: [String]
    let createdAt: Date?
    let updatedAt: Date?
    let checkpointReferences: [String]
}

struct AssistantConversationSnapshot: Codable, Equatable, Sendable {
    var version: Int
    var threadID: String
    var timeline: [AssistantTimelineItem]
    var transcript: [AssistantTranscriptEntry]
    var turns: [AssistantConversationTurnRecord]
    var updatedAt: Date
    var lastAppliedEventSequence: Int

    init(
        version: Int = 1,
        threadID: String,
        timeline: [AssistantTimelineItem],
        transcript: [AssistantTranscriptEntry],
        turns: [AssistantConversationTurnRecord],
        updatedAt: Date,
        lastAppliedEventSequence: Int = 0
    ) {
        self.version = version
        self.threadID = threadID
        self.timeline = timeline
        self.transcript = transcript
        self.turns = turns
        self.updatedAt = updatedAt
        self.lastAppliedEventSequence = lastAppliedEventSequence
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case threadID
        case timeline
        case transcript
        case turns
        case updatedAt
        case lastAppliedEventSequence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.threadID = try container.decode(String.self, forKey: .threadID)
        self.timeline = try container.decodeIfPresent([AssistantTimelineItem].self, forKey: .timeline) ?? []
        self.transcript = try container.decodeIfPresent([AssistantTranscriptEntry].self, forKey: .transcript) ?? []
        self.turns = try container.decodeIfPresent([AssistantConversationTurnRecord].self, forKey: .turns) ?? []
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.lastAppliedEventSequence = try container.decodeIfPresent(Int.self, forKey: .lastAppliedEventSequence) ?? 0
    }

    static func empty(threadID: String) -> AssistantConversationSnapshot {
        AssistantConversationSnapshot(
            version: 1,
            threadID: threadID,
            timeline: [],
            transcript: [],
            turns: [],
            updatedAt: Date(),
            lastAppliedEventSequence: 0
        )
    }
}

private extension AssistantConversationSnapshot {
    var hasConversationContent: Bool {
        !timeline.isEmpty || !transcript.isEmpty
    }
}

struct AssistantConversationThreadSummary: Identifiable, Equatable, Sendable {
    let threadID: String
    let lastUpdatedAt: Date
    let hasSnapshot: Bool
    let hasEventLog: Bool
    let hasNotes: Bool
    let hasConversationContent: Bool
    let latestUserMessage: String?
    let latestAssistantMessage: String?
    let noteTitle: String?

    var id: String { threadID }
}

enum AssistantNoteOwnerKind: String, Codable, Equatable, Hashable, Sendable {
    case thread
    case project
}

struct AssistantNoteSummary: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var noteType: AssistantNoteType
    var fileName: String
    var folderID: String?
    var order: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        title: String,
        noteType: AssistantNoteType = .note,
        fileName: String,
        folderID: String? = nil,
        order: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.noteType = noteType
        self.fileName = fileName
        self.folderID = folderID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case noteType
        case fileName
        case folderID
        case order
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        noteType = try container.decodeIfPresent(AssistantNoteType.self, forKey: .noteType) ?? .note
        fileName = try container.decode(String.self, forKey: .fileName)
        folderID = try container.decodeIfPresent(String.self, forKey: .folderID)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        order = try container.decode(Int.self, forKey: .order)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

typealias AssistantThreadNoteSummary = AssistantNoteSummary

struct AssistantNoteFolderSummary: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var parentFolderID: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        name: String,
        parentFolderID: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.parentFolderID = parentFolderID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentFolderID
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        parentFolderID = try container.decodeIfPresent(String.self, forKey: .parentFolderID)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct AssistantNoteManifest: Codable, Equatable, Sendable {
    static let currentVersion = 3

    var version: Int
    var selectedNoteID: String?
    var notes: [AssistantNoteSummary]
    var folders: [AssistantNoteFolderSummary]

    init(
        version: Int = AssistantNoteManifest.currentVersion,
        selectedNoteID: String? = nil,
        notes: [AssistantNoteSummary] = [],
        folders: [AssistantNoteFolderSummary] = []
    ) {
        self.version = version
        self.selectedNoteID = selectedNoteID
        self.notes = notes
        self.folders = folders
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case selectedNoteID
        case notes
        case folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        selectedNoteID = try container.decodeIfPresent(String.self, forKey: .selectedNoteID)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        notes = try container.decodeIfPresent([AssistantNoteSummary].self, forKey: .notes) ?? []
        folders = try container.decodeIfPresent([AssistantNoteFolderSummary].self, forKey: .folders) ?? []
    }

    var orderedNotes: [AssistantNoteSummary] {
        notes.sorted {
            if $0.order == $1.order {
                return $0.createdAt < $1.createdAt
            }
            return $0.order < $1.order
        }
    }

    var orderedFolders: [AssistantNoteFolderSummary] {
        folders.sorted { lhs, rhs in
            switch (lhs.parentFolderID, rhs.parentFolderID) {
            case let (.some(left), .some(right)):
                let parentCompare = left.localizedCaseInsensitiveCompare(right)
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

    var selectedNote: AssistantNoteSummary? {
        guard let selectedNoteID else {
            return orderedNotes.first
        }
        return orderedNotes.first(where: { $0.id == selectedNoteID }) ?? orderedNotes.first
    }
}

typealias AssistantThreadNoteManifest = AssistantNoteManifest

struct AssistantNotesWorkspace: Equatable, Sendable {
    var ownerKind: AssistantNoteOwnerKind
    var ownerID: String
    var manifest: AssistantNoteManifest
    var selectedNoteText: String

    init(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        manifest: AssistantNoteManifest,
        selectedNoteText: String
    ) {
        self.ownerKind = ownerKind
        self.ownerID = ownerID
        self.manifest = manifest
        self.selectedNoteText = selectedNoteText
    }

    init(
        threadID: String,
        manifest: AssistantNoteManifest,
        selectedNoteText: String
    ) {
        self.init(
            ownerKind: .thread,
            ownerID: threadID,
            manifest: manifest,
            selectedNoteText: selectedNoteText
        )
    }

    init(
        projectID: String,
        manifest: AssistantNoteManifest,
        selectedNoteText: String
    ) {
        self.init(
            ownerKind: .project,
            ownerID: projectID,
            manifest: manifest,
            selectedNoteText: selectedNoteText
        )
    }

    var threadID: String {
        ownerKind == .thread ? ownerID : ""
    }

    var projectID: String {
        ownerKind == .project ? ownerID : ""
    }

    var notes: [AssistantNoteSummary] {
        manifest.orderedNotes
    }

    var selectedNote: AssistantNoteSummary? {
        manifest.selectedNote
    }
}

typealias AssistantThreadNotesWorkspace = AssistantNotesWorkspace

private enum AssistantConversationEventStream: String, Codable {
    case transcript
    case timeline
}

private enum AssistantConversationEventPayloadKind: String, Codable {
    case transcriptReset
    case transcriptUpsert
    case transcriptAppendDelta
    case timelineReset
    case timelineRemove
    case timelineUpsert
    case timelineAppendTextDelta
}

private struct AssistantPersistedTranscriptEntry: Codable, Equatable {
    let id: UUID
    let role: AssistantTranscriptRole
    let text: String
    let createdAt: Date
    let emphasis: Bool
    let isStreaming: Bool
    let providerBackend: AssistantRuntimeBackend?
    let providerModelID: String?

    init(_ entry: AssistantTranscriptEntry) {
        self.id = entry.id
        self.role = entry.role
        self.text = entry.text
        self.createdAt = entry.createdAt
        self.emphasis = entry.emphasis
        self.isStreaming = entry.isStreaming
        self.providerBackend = entry.providerBackend
        self.providerModelID = entry.providerModelID
    }

    func makeTranscriptEntry() -> AssistantTranscriptEntry {
        AssistantTranscriptEntry(
            id: id,
            role: role,
            text: text,
            createdAt: createdAt,
            emphasis: emphasis,
            isStreaming: isStreaming,
            providerBackend: providerBackend,
            providerModelID: providerModelID
        )
    }
}

private struct AssistantPersistedTranscriptAppendDeltaEvent: Codable, Equatable {
    let id: UUID
    let role: AssistantTranscriptRole
    let delta: String
    let createdAt: Date
    let emphasis: Bool
    let isStreaming: Bool
    let providerBackend: AssistantRuntimeBackend?
    let providerModelID: String?
}

private struct AssistantPersistedTimelineItem: Codable, Equatable {
    let id: String
    let sessionID: String?
    let turnID: String?
    let kind: AssistantTimelineItemKind
    let createdAt: Date
    let updatedAt: Date
    let text: String?
    let isStreaming: Bool
    let emphasis: Bool
    let activity: AssistantActivityItem?
    let permissionRequest: AssistantPermissionRequest?
    let planText: String?
    let planEntries: [AssistantPlanEntry]?
    let imageAttachments: [Data]?
    let providerBackend: AssistantRuntimeBackend?
    let providerModelID: String?
    let source: AssistantTimelineSource

    init(_ item: AssistantTimelineItem) {
        self.id = item.id
        self.sessionID = item.sessionID
        self.turnID = item.turnID
        self.kind = item.kind
        self.createdAt = item.createdAt
        self.updatedAt = item.updatedAt
        self.text = item.text
        self.isStreaming = item.isStreaming
        self.emphasis = item.emphasis
        self.activity = item.activity
        self.permissionRequest = item.permissionRequest
        self.planText = item.planText
        self.planEntries = item.planEntries
        self.imageAttachments = item.imageAttachments
        self.providerBackend = item.providerBackend
        self.providerModelID = item.providerModelID
        self.source = item.source
    }

    func makeTimelineItem() -> AssistantTimelineItem {
        AssistantTimelineItem(
            id: id,
            sessionID: sessionID,
            turnID: turnID,
            kind: kind,
            createdAt: createdAt,
            updatedAt: updatedAt,
            text: text,
            isStreaming: isStreaming,
            emphasis: emphasis,
            activity: activity,
            permissionRequest: permissionRequest,
            planText: planText,
            planEntries: planEntries,
            imageAttachments: imageAttachments,
            providerBackend: providerBackend,
            providerModelID: providerModelID,
            source: source
        )
    }
}

private struct AssistantPersistedTimelineAppendTextDeltaEvent: Codable, Equatable {
    let id: String
    let turnID: String?
    let kind: AssistantTimelineItemKind
    let delta: String
    let createdAt: Date
    let updatedAt: Date
    let isStreaming: Bool
    let emphasis: Bool
    let source: AssistantTimelineSource
    let providerBackend: AssistantRuntimeBackend?
    let providerModelID: String?
}

private struct AssistantConversationEventPayload: Codable, Equatable {
    let kind: AssistantConversationEventPayloadKind
    let transcriptEntry: AssistantPersistedTranscriptEntry?
    let transcriptAppendDelta: AssistantPersistedTranscriptAppendDeltaEvent?
    let timelineItem: AssistantPersistedTimelineItem?
    let timelineAppendTextDelta: AssistantPersistedTimelineAppendTextDeltaEvent?
    let removedTimelineItemID: String?

    init(
        kind: AssistantConversationEventPayloadKind,
        transcriptEntry: AssistantPersistedTranscriptEntry? = nil,
        transcriptAppendDelta: AssistantPersistedTranscriptAppendDeltaEvent? = nil,
        timelineItem: AssistantPersistedTimelineItem? = nil,
        timelineAppendTextDelta: AssistantPersistedTimelineAppendTextDeltaEvent? = nil,
        removedTimelineItemID: String? = nil
    ) {
        self.kind = kind
        self.transcriptEntry = transcriptEntry
        self.transcriptAppendDelta = transcriptAppendDelta
        self.timelineItem = timelineItem
        self.timelineAppendTextDelta = timelineAppendTextDelta
        self.removedTimelineItemID = removedTimelineItemID
    }
}

private struct AssistantConversationEventRecord: Codable, Equatable, Sendable {
    let sequence: Int
    let threadID: String
    let recordedAt: Date
    let stream: AssistantConversationEventStream
    let payload: AssistantConversationEventPayload
}

final class AssistantConversationStore {
    private static let hybridSnapshotVersion = 2
    private static let noteRecoveryDirectoryName = "Recovery"
    private static let legacyThreadNoteFilename = "notes.md"
    private static let threadNotesDirectoryName = "notes"
    private static let threadNoteManifestFilename = "manifest.json"
    private static let defaultThreadNoteTitle = "Untitled note"
    private static let snapshotFilename = "conversation.json"
    private static let eventLogFilename = "conversation.events.jsonl"

    private let fileManager: FileManager
    private let baseDirectoryURL: URL
    private let noteRecoveryStore: AssistantNoteRecoveryStore
    private let eventPersistenceQueue = DispatchQueue(
        label: "com.openassist.conversation.event-persistence",
        qos: .utility
    )
    private var nextSequenceByThreadID: [String: Int] = [:]
    private var cachedSavedConversationThreadSummaries: [Bool: [AssistantConversationThreadSummary]] = [:]
    private var cachedSavedConversationThreadSummariesStamp: Date?

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
                .appendingPathComponent("AssistantConversationStore", isDirectory: true)
        }
        self.noteRecoveryStore = AssistantNoteRecoveryStore(
            fileManager: fileManager,
            recoveryRootURL: self.baseDirectoryURL
                .appendingPathComponent(Self.noteRecoveryDirectoryName, isDirectory: true)
        )
    }

    var storageURL: URL {
        baseDirectoryURL
    }

    func loadSnapshot(threadID: String) -> AssistantConversationSnapshot? {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else { return nil }

        let storedSnapshot = readStoredSnapshot(threadID: normalizedThreadID)
        let logExists = eventLogFileURL(for: normalizedThreadID).map {
            fileManager.fileExists(atPath: $0.path)
        } ?? false

        let resolvedSnapshot: AssistantConversationSnapshot?
        if let storedSnapshot {
            guard storedSnapshot.version == Self.hybridSnapshotVersion, logExists else {
                resolvedSnapshot = storedSnapshot
                return persistSanitizedSnapshotIfNeeded(
                    snapshot: resolvedSnapshot,
                    logExists: logExists
                )
            }
            resolvedSnapshot = replayEventLog(
                threadID: normalizedThreadID,
                onto: storedSnapshot,
                rewriteSnapshot: true
            )
            return persistSanitizedSnapshotIfNeeded(
                snapshot: resolvedSnapshot,
                logExists: logExists
            )
        }

        guard logExists else { return nil }
        resolvedSnapshot = replayEventLog(
            threadID: normalizedThreadID,
            onto: nil,
            rewriteSnapshot: true
        )
        return persistSanitizedSnapshotIfNeeded(
            snapshot: resolvedSnapshot,
            logExists: logExists
        )
    }

    func loadTimeline(threadID: String, limit: Int) -> [AssistantTimelineItem] {
        let items = visibleTimeline(threadID: threadID)
        guard items.count > limit else { return items }
        return Array(items.suffix(limit))
    }

    func loadTranscript(threadID: String, limit: Int) -> [AssistantTranscriptEntry] {
        let entries = loadSnapshot(threadID: threadID)?.transcript ?? []
        guard entries.count > limit else { return entries }
        return Array(entries.suffix(limit))
    }

    func loadRecentHistoryChunk(
        threadID: String,
        timelineLimit: Int,
        transcriptLimit: Int
    ) -> CodexSessionCatalog.SessionHistoryChunk {
        let snapshot = loadSnapshot(threadID: threadID) ?? .empty(threadID: threadID)
        let resolvedTimeline = Self.visibleTimeline(from: snapshot)
        let timeline = resolvedTimeline.count > timelineLimit
            ? Array(resolvedTimeline.suffix(timelineLimit))
            : resolvedTimeline
        let transcript = snapshot.transcript.count > transcriptLimit
            ? Array(snapshot.transcript.suffix(transcriptLimit))
            : snapshot.transcript

        return CodexSessionCatalog.SessionHistoryChunk(
            timeline: timeline,
            transcript: transcript,
            hasMoreTimeline: snapshot.timeline.count > timeline.count,
            hasMoreTranscript: snapshot.transcript.count > transcript.count
        )
    }

    func savedConversationThreads(includeNotesOnly: Bool = true) -> [AssistantConversationThreadSummary] {
        let currentStamp = fileModificationDate(for: baseDirectoryURL)
        if cachedSavedConversationThreadSummariesStamp == currentStamp,
           let cachedSummaries = cachedSavedConversationThreadSummaries[includeNotesOnly] {
            return cachedSummaries
        }

        guard let directoryURLs = try? fileManager.contentsOfDirectory(
            at: baseDirectoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let summaries = directoryURLs.compactMap { directoryURL -> AssistantConversationThreadSummary? in
            guard isDirectory(at: directoryURL),
                  directoryURL.lastPathComponent.caseInsensitiveCompare(Self.noteRecoveryDirectoryName) != .orderedSame
            else { return nil }
            return summarizeConversationThread(at: directoryURL, includeNotesOnly: includeNotesOnly)
        }

        let sortedSummaries = summaries.sorted {
            if $0.lastUpdatedAt != $1.lastUpdatedAt {
                return $0.lastUpdatedAt > $1.lastUpdatedAt
            }
            return $0.threadID.localizedCaseInsensitiveCompare($1.threadID) == .orderedAscending
        }

        cachedSavedConversationThreadSummariesStamp = currentStamp
        cachedSavedConversationThreadSummaries[includeNotesOnly] = sortedSummaries
        return sortedSummaries
    }

    func saveSnapshot(
        threadID: String,
        timeline: [AssistantTimelineItem],
        transcript: [AssistantTranscriptEntry],
        session: AssistantSessionSummary?,
        persistenceKind: AssistantConversationPersistenceKind = .snapshotOnly
    ) throws {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else { return }

        let existingTurns = readStoredSnapshot(threadID: normalizedThreadID)?.turns
        let eventSequence = persistenceKind == .hybridJSONL ? highestEventSequence(for: normalizedThreadID) : 0
        let snapshot = Self.sanitizedSnapshot(
            AssistantConversationSnapshot(
            version: persistenceKind == .hybridJSONL ? Self.hybridSnapshotVersion : 1,
            threadID: normalizedThreadID,
            timeline: timeline,
            transcript: transcript,
            turns: Self.derivedTurnRecords(
                threadID: normalizedThreadID,
                timeline: timeline,
                session: session,
                existingTurns: existingTurns
            ),
            updatedAt: Date(),
            lastAppliedEventSequence: eventSequence
            )
        )
        try storeSnapshot(snapshot)
    }

    func storeSnapshot(_ snapshot: AssistantConversationSnapshot) throws {
        guard let fileURL = snapshotFileURL(for: snapshot.threadID) else { return }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        nextSequenceByThreadID[normalizedThreadID(snapshot.threadID)] = max(
            nextSequenceByThreadID[normalizedThreadID(snapshot.threadID)] ?? 1,
            snapshot.lastAppliedEventSequence + 1
        )
        invalidateSavedConversationThreadSummariesCache()
    }

    func deleteSnapshot(threadID: String) {
        guard let fileURL = snapshotFileURL(for: threadID) else { return }
        try? fileManager.removeItem(at: fileURL)
        nextSequenceByThreadID.removeValue(forKey: normalizedThreadID(threadID))
        invalidateSavedConversationThreadSummariesCache()
    }

    func snapshotFileURL(for threadID: String) -> URL? {
        threadDirectoryURL(for: threadID)?
            .appendingPathComponent(Self.snapshotFilename, isDirectory: false)
    }

    func eventLogFileURL(for threadID: String) -> URL? {
        threadDirectoryURL(for: threadID)?
            .appendingPathComponent(Self.eventLogFilename, isDirectory: false)
    }

    func threadNoteFileURL(for threadID: String) -> URL? {
        threadDirectoryURL(for: threadID)?
            .appendingPathComponent(Self.legacyThreadNoteFilename, isDirectory: false)
    }

    /// Returns the on-disk URL for the given thread note if it resolves and the
    /// underlying `.md` file currently exists.
    func threadNoteOnDiskURL(threadID: String, noteID: String) -> URL? {
        let manifest = resolvedThreadNoteManifest(threadID: threadID)
        guard
            let note = manifest.notes.first(where: {
                $0.id.caseInsensitiveCompare(noteID) == .orderedSame
            }),
            let fileURL = threadNoteFileURL(
                threadID: threadID,
                fileName: note.fileName
            ),
            fileManager.fileExists(atPath: fileURL.path)
        else {
            return nil
        }
        return fileURL
    }

    func loadThreadNote(threadID: String) -> String {
        loadThreadNotesWorkspace(threadID: threadID).selectedNoteText
    }

    func threadNoteModificationDate(threadID: String) -> Date? {
        loadThreadNotesWorkspace(threadID: threadID).selectedNote?.updatedAt
    }

    func saveThreadNote(threadID: String, text: String) throws {
        let workspace = loadThreadNotesWorkspace(threadID: threadID)
        let selectedNoteID = workspace.selectedNote?.id
        _ = try saveThreadNote(threadID: threadID, noteID: selectedNoteID, text: text)
    }

    func loadThreadNotesWorkspace(threadID: String) -> AssistantThreadNotesWorkspace {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else {
            return AssistantThreadNotesWorkspace(
                threadID: "",
                manifest: AssistantThreadNoteManifest(),
                selectedNoteText: ""
            )
        }

        let manifest = resolvedThreadNoteManifest(threadID: normalizedThreadID)
        let selectedText = manifest.selectedNote.map {
            loadThreadNoteText(threadID: normalizedThreadID, fileName: $0.fileName)
        } ?? ""

        return AssistantThreadNotesWorkspace(
            threadID: normalizedThreadID,
            manifest: manifest,
            selectedNoteText: selectedText
        )
    }

    func loadThreadStoredNotes(threadID: String) -> [AssistantStoredNote] {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else {
            return []
        }

        let manifest = resolvedThreadNoteManifest(threadID: normalizedThreadID)
        return manifest.orderedNotes.map { note in
            AssistantStoredNote(
                ownerKind: .thread,
                ownerID: normalizedThreadID,
                noteID: note.id,
                title: note.title,
                noteType: note.noteType,
                fileName: note.fileName,
                folderID: nil,
                updatedAt: note.updatedAt,
                text: loadThreadNoteText(threadID: normalizedThreadID, fileName: note.fileName)
            )
        }
    }

    func createThreadNote(
        threadID: String,
        title: String? = nil,
        noteType: AssistantNoteType = .note,
        selectNewNote: Bool = true
    ) throws -> AssistantThreadNotesWorkspace {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else {
            return AssistantThreadNotesWorkspace(
                threadID: "",
                manifest: AssistantThreadNoteManifest(),
                selectedNoteText: ""
            )
        }

        var manifest = resolvedThreadNoteManifest(threadID: normalizedThreadID)
        let noteID = UUID().uuidString.lowercased()
        let now = Date()
        let note = AssistantThreadNoteSummary(
            id: noteID,
            title: normalizedThreadNoteTitle(title),
            noteType: noteType,
            fileName: "\(safePathComponent(noteID)).md",
            folderID: nil,
            order: manifest.orderedNotes.count,
            createdAt: now,
            updatedAt: now
        )
        manifest.notes.append(note)
        manifest.notes = normalizedThreadNoteItems(manifest.notes)
        if selectNewNote || manifest.selectedNoteID == nil {
            manifest.selectedNoteID = note.id
        }
        try storeThreadNoteManifest(manifest, threadID: normalizedThreadID)

        return AssistantThreadNotesWorkspace(
            threadID: normalizedThreadID,
            manifest: manifest,
            selectedNoteText: ""
        )
    }

    func renameThreadNote(
        threadID: String,
        noteID: String,
        title: String
    ) throws -> AssistantThreadNotesWorkspace {
        let normalizedThreadID = normalizedThreadID(threadID)
        var manifest = resolvedThreadNoteManifest(threadID: normalizedThreadID)
        guard let index = manifest.notes.firstIndex(where: { $0.id == noteID }) else {
            return loadThreadNotesWorkspace(threadID: normalizedThreadID)
        }

        manifest.notes[index].title = normalizedThreadNoteTitle(title)
        manifest.notes[index].updatedAt = Date()
        manifest.notes = normalizedThreadNoteItems(manifest.notes)
        try storeThreadNoteManifest(manifest, threadID: normalizedThreadID)

        let selectedText = manifest.selectedNote.map {
            loadThreadNoteText(threadID: normalizedThreadID, fileName: $0.fileName)
        } ?? ""
        return AssistantThreadNotesWorkspace(
            threadID: normalizedThreadID,
            manifest: manifest,
            selectedNoteText: selectedText
        )
    }

    func selectThreadNote(
        threadID: String,
        noteID: String
    ) throws -> AssistantThreadNotesWorkspace {
        let normalizedThreadID = normalizedThreadID(threadID)
        var manifest = resolvedThreadNoteManifest(threadID: normalizedThreadID)
        if manifest.notes.contains(where: { $0.id == noteID }) {
            manifest.selectedNoteID = noteID
            try storeThreadNoteManifest(manifest, threadID: normalizedThreadID)
        }
        let selectedText = manifest.selectedNote.map {
            loadThreadNoteText(threadID: normalizedThreadID, fileName: $0.fileName)
        } ?? ""
        return AssistantThreadNotesWorkspace(
            threadID: normalizedThreadID,
            manifest: manifest,
            selectedNoteText: selectedText
        )
    }

    func saveThreadNoteImageAsset(
        threadID: String,
        noteID: String,
        attachment: AssistantAttachment
    ) throws -> AssistantSavedNoteAsset {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else {
            throw AssistantNoteAssetError.noteNotFound
        }

        let manifest = resolvedThreadNoteManifest(threadID: normalizedThreadID)
        guard let note = manifest.notes.first(where: { $0.id.caseInsensitiveCompare(noteID) == .orderedSame }),
              let notesDirectoryURL = threadNotesDirectoryURL(for: normalizedThreadID) else {
            throw AssistantNoteAssetError.noteNotFound
        }

        return try AssistantNoteAssetSupport.saveImageAsset(
            attachment: attachment,
            notesDirectoryURL: notesDirectoryURL,
            noteFileName: note.fileName,
            fileManager: fileManager
        )
    }

    func resolveThreadNoteImageAssetURL(
        threadID: String,
        noteID: String,
        relativePath: String
    ) -> URL? {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else {
            return nil
        }

        let manifest = resolvedThreadNoteManifest(threadID: normalizedThreadID)
        guard let note = manifest.notes.first(where: { $0.id.caseInsensitiveCompare(noteID) == .orderedSame }),
              let notesDirectoryURL = threadNotesDirectoryURL(for: normalizedThreadID) else {
            return nil
        }

        return AssistantNoteAssetSupport.resolveAssetFileURL(
            notesDirectoryURL: notesDirectoryURL,
            noteFileName: note.fileName,
            relativePath: relativePath
        )
    }

    @discardableResult
    func saveThreadNote(
        threadID: String,
        noteID: String?,
        text: String,
        forceHistorySnapshot: Bool = false,
        now: Date = Date()
    ) throws -> AssistantThreadNotesWorkspace {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else {
            return AssistantThreadNotesWorkspace(
                threadID: "",
                manifest: AssistantThreadNoteManifest(),
                selectedNoteText: ""
            )
        }

        var manifest = resolvedThreadNoteManifest(threadID: normalizedThreadID)
        let resolvedNoteID: String
        if let noteID,
           manifest.notes.contains(where: { $0.id == noteID }) {
            resolvedNoteID = noteID
        } else if let selectedNoteID = manifest.selectedNote?.id {
            resolvedNoteID = selectedNoteID
        } else {
            return try createThreadNoteAndSave(
                threadID: normalizedThreadID,
                title: Self.defaultThreadNoteTitle,
                text: text
            )
        }

        guard let index = manifest.notes.firstIndex(where: { $0.id == resolvedNoteID }) else {
            return loadThreadNotesWorkspace(threadID: normalizedThreadID)
        }

        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let note = manifest.notes[index]
        guard let fileURL = threadNoteFileURL(
            threadID: normalizedThreadID,
            fileName: note.fileName
        ) else {
            return loadThreadNotesWorkspace(threadID: normalizedThreadID)
        }

        let previousText = loadThreadNoteText(threadID: normalizedThreadID, fileName: note.fileName)
        let previousTrimmed = previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTrimmed = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)

        if previousText == normalizedText {
            if manifest.selectedNoteID != resolvedNoteID {
                manifest.selectedNoteID = resolvedNoteID
                try storeThreadNoteManifest(manifest, threadID: normalizedThreadID)
            }
            return AssistantThreadNotesWorkspace(
                threadID: normalizedThreadID,
                manifest: manifest,
                selectedNoteText: previousText
            )
        }

        if nextTrimmed.isEmpty, !previousTrimmed.isEmpty, !forceHistorySnapshot {
            return AssistantThreadNotesWorkspace(
                threadID: normalizedThreadID,
                manifest: manifest,
                selectedNoteText: previousText
            )
        }

        if previousText != normalizedText {
            noteRecoveryStore.captureHistorySnapshot(
                note: note,
                ownerKind: .thread,
                ownerID: normalizedThreadID,
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
        manifest.notes = normalizedThreadNoteItems(manifest.notes)
        try storeThreadNoteManifest(manifest, threadID: normalizedThreadID)

        return AssistantThreadNotesWorkspace(
            threadID: normalizedThreadID,
            manifest: manifest,
            selectedNoteText: normalizedText
        )
    }

    func deleteThreadNote(
        threadID: String,
        noteID: String,
        now: Date = Date()
    ) throws -> AssistantThreadNotesWorkspace {
        let normalizedThreadID = normalizedThreadID(threadID)
        var manifest = resolvedThreadNoteManifest(threadID: normalizedThreadID)
        guard let existingIndex = manifest.notes.firstIndex(where: { $0.id == noteID }) else {
            return loadThreadNotesWorkspace(threadID: normalizedThreadID)
        }

        let removed = manifest.notes.remove(at: existingIndex)
        let removedText = loadThreadNoteText(threadID: normalizedThreadID, fileName: removed.fileName)
        let removedAssetDirectoryURL = threadNoteAssetDirectoryURL(
            threadID: normalizedThreadID,
            fileName: removed.fileName
        )
        noteRecoveryStore.captureDeletedNote(
            note: removed,
            ownerKind: .thread,
            ownerID: normalizedThreadID,
            text: removedText,
            assetDirectoryURL: removedAssetDirectoryURL,
            at: now
        )
        if let fileURL = threadNoteFileURL(threadID: normalizedThreadID, fileName: removed.fileName) {
            try? fileManager.removeItem(at: fileURL)
        }
        if let removedAssetDirectoryURL {
            try? fileManager.removeItem(at: removedAssetDirectoryURL)
        }

        manifest.notes = normalizedThreadNoteItems(manifest.notes)
        if manifest.selectedNoteID == noteID {
            let fallbackIndex = min(existingIndex, max(0, manifest.notes.count - 1))
            manifest.selectedNoteID = manifest.notes.indices.contains(fallbackIndex)
                ? manifest.notes[fallbackIndex].id
                : nil
        }

        try storeThreadNoteManifest(manifest, threadID: normalizedThreadID)
        let selectedText = manifest.selectedNote.map {
            loadThreadNoteText(threadID: normalizedThreadID, fileName: $0.fileName)
        } ?? ""
        return AssistantThreadNotesWorkspace(
            threadID: normalizedThreadID,
            manifest: manifest,
            selectedNoteText: selectedText
        )
    }

    func appendToSelectedThreadNote(
        threadID: String,
        text: String
    ) throws -> AssistantThreadNotesWorkspace {
        let normalizedThreadID = normalizedThreadID(threadID)
        let trimmedAppendText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty, !trimmedAppendText.isEmpty else {
            return loadThreadNotesWorkspace(threadID: normalizedThreadID)
        }

        let workspace = loadThreadNotesWorkspace(threadID: normalizedThreadID)
        let currentText = workspace.selectedNoteText.trimmingCharacters(in: .newlines)
        let mergedText = currentText.isEmpty
            ? trimmedAppendText
            : currentText + "\n\n" + trimmedAppendText

        return try saveThreadNote(
            threadID: normalizedThreadID,
            noteID: workspace.selectedNote?.id,
            text: mergedText
        )
    }

    func threadNoteHistoryVersions(
        threadID: String,
        noteID: String
    ) -> [AssistantNoteHistoryVersion] {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else { return [] }
        return noteRecoveryStore.historyVersions(
            ownerKind: .thread,
            ownerID: normalizedThreadID,
            noteID: noteID
        )
    }

    func restoreThreadNoteHistoryVersion(
        threadID: String,
        noteID: String,
        versionID: String,
        now: Date = Date()
    ) throws -> AssistantThreadNotesWorkspace {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else {
            return loadThreadNotesWorkspace(threadID: normalizedThreadID)
        }
        var manifest = resolvedThreadNoteManifest(threadID: normalizedThreadID)
        guard let noteIndex = manifest.notes.firstIndex(where: { $0.id == noteID }),
              let payload = noteRecoveryStore.restoreHistoryVersion(
                ownerKind: .thread,
                ownerID: normalizedThreadID,
                noteID: noteID,
                versionID: versionID
              ) else {
            return loadThreadNotesWorkspace(threadID: normalizedThreadID)
        }

        let currentNote = manifest.notes[noteIndex]
        let currentText = loadThreadNoteText(threadID: normalizedThreadID, fileName: currentNote.fileName)
        if currentText != payload.text || currentNote.title != payload.note.title {
            noteRecoveryStore.captureHistorySnapshot(
                note: currentNote,
                ownerKind: .thread,
                ownerID: normalizedThreadID,
                text: currentText,
                at: now,
                force: true
            )
        }

        manifest.notes[noteIndex].title = normalizedThreadNoteTitle(payload.note.title)
        manifest.notes[noteIndex].updatedAt = now
        manifest.selectedNoteID = noteID
        try writeThreadNoteText(
            threadID: normalizedThreadID,
            fileName: currentNote.fileName,
            text: payload.text
        )
        manifest.notes = normalizedThreadNoteItems(manifest.notes)
        try storeThreadNoteManifest(manifest, threadID: normalizedThreadID)
        return AssistantThreadNotesWorkspace(
            threadID: normalizedThreadID,
            manifest: manifest,
            selectedNoteText: payload.text
        )
    }

    func deleteThreadNoteHistoryVersion(
        threadID: String,
        noteID: String,
        versionID: String
    ) -> AssistantThreadNotesWorkspace {
        let normalizedThreadID = normalizedThreadID(threadID)
        noteRecoveryStore.deleteHistoryVersion(
            ownerKind: .thread,
            ownerID: normalizedThreadID,
            noteID: noteID,
            versionID: versionID
        )
        return loadThreadNotesWorkspace(threadID: normalizedThreadID)
    }

    func recentlyDeletedThreadNotes(
        threadID: String,
        referenceDate: Date = Date()
    ) -> [AssistantDeletedNoteSnapshot] {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else { return [] }
        return noteRecoveryStore.recentlyDeletedNotes(
            ownerKind: .thread,
            ownerID: normalizedThreadID,
            referenceDate: referenceDate
        )
    }

    func restoreDeletedThreadNote(
        threadID: String,
        deletedNoteID: String,
        now: Date = Date()
    ) throws -> AssistantThreadNotesWorkspace {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty,
              let payload = noteRecoveryStore.restoreDeletedNote(
                ownerKind: .thread,
                ownerID: normalizedThreadID,
                deletedID: deletedNoteID,
                referenceDate: now
              ) else {
            return loadThreadNotesWorkspace(threadID: normalizedThreadID)
        }

        var manifest = resolvedThreadNoteManifest(threadID: normalizedThreadID)
        let restoredNoteID = manifest.notes.contains(where: {
            $0.id.caseInsensitiveCompare(payload.note.id) == .orderedSame
        }) ? UUID().uuidString.lowercased() : payload.note.id
        let restoredFileName = manifest.notes.contains(where: {
            $0.fileName.caseInsensitiveCompare(payload.note.fileName) == .orderedSame
        }) ? "\(safePathComponent(restoredNoteID)).md" : payload.note.fileName
        let restoredNote = AssistantThreadNoteSummary(
            id: restoredNoteID,
            title: normalizedThreadNoteTitle(payload.note.title),
            fileName: restoredFileName,
            folderID: nil,
            order: manifest.orderedNotes.count,
            createdAt: payload.note.createdAt,
            updatedAt: now
        )
        manifest.notes.append(restoredNote)
        manifest.selectedNoteID = restoredNote.id
        manifest.notes = normalizedThreadNoteItems(manifest.notes)
        try writeThreadNoteText(
            threadID: normalizedThreadID,
            fileName: restoredNote.fileName,
            text: payload.text
        )
        if let assetDirectoryURL = payload.assetDirectoryURL,
           fileManager.fileExists(atPath: assetDirectoryURL.path),
           let restoredAssetDirectoryURL = threadNoteAssetDirectoryURL(
            threadID: normalizedThreadID,
            fileName: restoredNote.fileName
           ) {
            try? fileManager.removeItem(at: restoredAssetDirectoryURL)
            do {
                try fileManager.copyItem(at: assetDirectoryURL, to: restoredAssetDirectoryURL)
                try? fileManager.removeItem(at: assetDirectoryURL)
            } catch {}
        }
        try storeThreadNoteManifest(manifest, threadID: normalizedThreadID)
        return AssistantThreadNotesWorkspace(
            threadID: normalizedThreadID,
            manifest: manifest,
            selectedNoteText: payload.text
        )
    }

    func permanentlyDeleteDeletedThreadNote(
        threadID: String,
        deletedNoteID: String
    ) {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else { return }
        noteRecoveryStore.permanentlyDeleteDeletedNote(
            ownerKind: .thread,
            ownerID: normalizedThreadID,
            deletedID: deletedNoteID
        )
    }

    func deleteThreadArtifacts(threadID: String) {
        let normalizedID = normalizedThreadID(threadID)
        noteRecoveryStore.removeAllRecoveryData(ownerKind: .thread, ownerID: normalizedID)
        guard let directoryURL = threadDirectoryURL(for: threadID),
              fileManager.fileExists(atPath: directoryURL.path) else {
            nextSequenceByThreadID.removeValue(forKey: normalizedID)
            invalidateSavedConversationThreadSummariesCache()
            return
        }

        try? fileManager.removeItem(at: directoryURL)
        nextSequenceByThreadID.removeValue(forKey: normalizedID)
        invalidateSavedConversationThreadSummariesCache()
    }

    func deleteEventLog(threadID: String) {
        guard let fileURL = eventLogFileURL(for: threadID) else { return }
        try? fileManager.removeItem(at: fileURL)
        nextSequenceByThreadID.removeValue(forKey: normalizedThreadID(threadID))
        invalidateSavedConversationThreadSummariesCache()
    }

    func appendTranscriptResetEvent(threadID: String) throws {
        try appendEvent(
            threadID: threadID,
            stream: .transcript,
            payload: AssistantConversationEventPayload(kind: .transcriptReset)
        )
    }

    func appendTranscriptUpsertEvent(threadID: String, entry: AssistantTranscriptEntry) throws {
        try appendEvent(
            threadID: threadID,
            stream: .transcript,
            payload: AssistantConversationEventPayload(
                kind: .transcriptUpsert,
                transcriptEntry: AssistantPersistedTranscriptEntry(entry)
            )
        )
    }

    func appendTranscriptAppendDeltaEvent(
        threadID: String,
        id: UUID,
        role: AssistantTranscriptRole,
        delta: String,
        createdAt: Date,
        emphasis: Bool,
        isStreaming: Bool,
        providerBackend: AssistantRuntimeBackend?,
        providerModelID: String?
    ) throws {
        try appendEvent(
            threadID: threadID,
            stream: .transcript,
            payload: AssistantConversationEventPayload(
                kind: .transcriptAppendDelta,
                transcriptAppendDelta: AssistantPersistedTranscriptAppendDeltaEvent(
                    id: id,
                    role: role,
                    delta: delta,
                    createdAt: createdAt,
                    emphasis: emphasis,
                    isStreaming: isStreaming,
                    providerBackend: providerBackend,
                    providerModelID: providerModelID
                )
            )
        )
    }

    func appendTimelineResetEvent(threadID: String) throws {
        try appendEvent(
            threadID: threadID,
            stream: .timeline,
            payload: AssistantConversationEventPayload(kind: .timelineReset)
        )
    }

    func appendTimelineRemoveEvent(threadID: String, id: String) throws {
        try appendEvent(
            threadID: threadID,
            stream: .timeline,
            payload: AssistantConversationEventPayload(
                kind: .timelineRemove,
                removedTimelineItemID: id
            )
        )
    }

    func appendTimelineUpsertEvent(threadID: String, item: AssistantTimelineItem) throws {
        try appendEvent(
            threadID: threadID,
            stream: .timeline,
            payload: AssistantConversationEventPayload(
                kind: .timelineUpsert,
                timelineItem: AssistantPersistedTimelineItem(item)
            )
        )
    }

    func appendTimelineAppendTextDeltaEvent(
        threadID: String,
        id: String,
        turnID: String?,
        kind: AssistantTimelineItemKind,
        delta: String,
        createdAt: Date,
        updatedAt: Date,
        isStreaming: Bool,
        emphasis: Bool,
        source: AssistantTimelineSource,
        providerBackend: AssistantRuntimeBackend?,
        providerModelID: String?
    ) throws {
        try appendEvent(
            threadID: threadID,
            stream: .timeline,
            payload: AssistantConversationEventPayload(
                kind: .timelineAppendTextDelta,
                timelineAppendTextDelta: AssistantPersistedTimelineAppendTextDeltaEvent(
                    id: id,
                    turnID: turnID,
                    kind: kind,
                    delta: delta,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    isStreaming: isStreaming,
                    emphasis: emphasis,
                    source: source,
                    providerBackend: providerBackend,
                    providerModelID: providerModelID
                )
            )
        )
    }

    func rewriteHybridSnapshotAndEventLog(_ snapshot: AssistantConversationSnapshot) throws {
        let normalizedThreadID = normalizedThreadID(snapshot.threadID)
        guard !normalizedThreadID.isEmpty,
              let logURL = eventLogFileURL(for: normalizedThreadID) else {
            return
        }

        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sortedTranscript = snapshot.transcript.sorted(by: Self.transcriptSort)
        let sortedTimeline = snapshot.timeline.sorted(by: Self.timelineSort)
        var records: [AssistantConversationEventRecord] = []
        records.reserveCapacity(sortedTranscript.count + sortedTimeline.count)
        var sequence = 0

        for entry in sortedTranscript {
            sequence += 1
            records.append(
                AssistantConversationEventRecord(
                    sequence: sequence,
                    threadID: normalizedThreadID,
                    recordedAt: entry.createdAt,
                    stream: .transcript,
                    payload: AssistantConversationEventPayload(
                        kind: .transcriptUpsert,
                        transcriptEntry: AssistantPersistedTranscriptEntry(entry)
                    )
                )
            )
        }

        for item in sortedTimeline {
            sequence += 1
            records.append(
                AssistantConversationEventRecord(
                    sequence: sequence,
                    threadID: normalizedThreadID,
                    recordedAt: item.lastUpdatedAt,
                    stream: .timeline,
                    payload: AssistantConversationEventPayload(
                        kind: .timelineUpsert,
                        timelineItem: AssistantPersistedTimelineItem(item)
                    )
                )
            )
        }

        let serializedLines = try records.map {
            String(decoding: try encoder.encode($0), as: UTF8.self)
        }
        let serialized = serializedLines.isEmpty ? "" : serializedLines.joined(separator: "\n") + "\n"
        try serialized.write(to: logURL, atomically: true, encoding: .utf8)

        var rewrittenSnapshot = snapshot
        rewrittenSnapshot.version = Self.hybridSnapshotVersion
        rewrittenSnapshot.lastAppliedEventSequence = sequence
        rewrittenSnapshot.updatedAt = max(
            snapshot.updatedAt,
            records.last?.recordedAt ?? snapshot.updatedAt
        )
        try storeSnapshot(rewrittenSnapshot)
    }

    private func normalizedThreadID(_ threadID: String) -> String {
        threadID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func threadNotesDirectoryURL(for threadID: String) -> URL? {
        threadDirectoryURL(for: threadID)?
            .appendingPathComponent(Self.threadNotesDirectoryName, isDirectory: true)
    }

    private func threadNoteManifestFileURL(for threadID: String) -> URL? {
        threadNotesDirectoryURL(for: threadID)?
            .appendingPathComponent(Self.threadNoteManifestFilename, isDirectory: false)
    }

    private func threadNoteFileURL(threadID: String, fileName: String) -> URL? {
        threadNotesDirectoryURL(for: threadID)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func threadNoteAssetDirectoryURL(threadID: String, fileName: String) -> URL? {
        guard let notesDirectoryURL = threadNotesDirectoryURL(for: threadID) else {
            return nil
        }

        return AssistantNoteAssetSupport.noteAssetDirectoryURL(
            notesDirectoryURL: notesDirectoryURL,
            noteFileName: fileName
        )
    }

    private func writeThreadNoteText(
        threadID: String,
        fileName: String,
        text: String
    ) throws {
        guard let fileURL = threadNoteFileURL(threadID: threadID, fileName: fileName) else {
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

    private func loadThreadNoteText(threadID: String, fileName: String) -> String {
        guard let fileURL = threadNoteFileURL(threadID: threadID, fileName: fileName),
              fileManager.fileExists(atPath: fileURL.path),
              let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return ""
        }
        return contents.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func resolvedThreadNoteManifest(threadID: String) -> AssistantThreadNoteManifest {
        migrateLegacyThreadNoteIfNeeded(threadID: threadID)

        guard let manifestURL = threadNoteManifestFileURL(for: threadID),
              fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode(AssistantThreadNoteManifest.self, from: data)
        else {
            return AssistantThreadNoteManifest()
        }

        return normalizedThreadNoteManifest(decoded)
    }

    private func storeThreadNoteManifest(
        _ manifest: AssistantThreadNoteManifest,
        threadID: String
    ) throws {
        let normalizedManifest = normalizedThreadNoteManifest(manifest)
        guard let manifestURL = threadNoteManifestFileURL(for: threadID) else { return }

        if normalizedManifest.notes.isEmpty {
            try? fileManager.removeItem(at: manifestURL)
            if let notesDirectoryURL = threadNotesDirectoryURL(for: threadID) {
                try? fileManager.removeItem(at: notesDirectoryURL)
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
        invalidateSavedConversationThreadSummariesCache()
    }

    private func normalizedThreadNoteManifest(
        _ manifest: AssistantThreadNoteManifest
    ) -> AssistantThreadNoteManifest {
        let normalizedNotes = normalizedThreadNoteItems(manifest.notes)
        let selectedNoteID = normalizedNotes.contains(where: { $0.id == manifest.selectedNoteID })
            ? manifest.selectedNoteID
            : normalizedNotes.first?.id
        return AssistantThreadNoteManifest(
            version: max(manifest.version, AssistantThreadNoteManifest.currentVersion),
            selectedNoteID: selectedNoteID,
            notes: normalizedNotes,
            folders: []
        )
    }

    private func normalizedThreadNoteItems(
        _ notes: [AssistantThreadNoteSummary]
    ) -> [AssistantThreadNoteSummary] {
        notes
            .sorted {
                if $0.order == $1.order {
                    return $0.createdAt < $1.createdAt
                }
                return $0.order < $1.order
            }
            .enumerated()
            .map { index, note in
                var updated = note
                updated.title = normalizedThreadNoteTitle(note.title)
                updated.folderID = nil
                updated.order = index
                return updated
            }
    }

    private func normalizedThreadNoteTitle(_ title: String?) -> String {
        title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? Self.defaultThreadNoteTitle
    }

    private func createThreadNoteAndSave(
        threadID: String,
        title: String,
        text: String,
        noteType: AssistantNoteType = .note
    ) throws -> AssistantThreadNotesWorkspace {
        let createdWorkspace = try createThreadNote(
            threadID: threadID,
            title: title,
            noteType: noteType,
            selectNewNote: true
        )
        return try saveThreadNote(
            threadID: threadID,
            noteID: createdWorkspace.selectedNote?.id,
            text: text
        )
    }

    private func migrateLegacyThreadNoteIfNeeded(threadID: String) {
        guard let legacyURL = threadNoteFileURL(for: threadID),
              fileManager.fileExists(atPath: legacyURL.path),
              let manifestURL = threadNoteManifestFileURL(for: threadID) else {
            return
        }

        guard !fileManager.fileExists(atPath: manifestURL.path) else {
            try? fileManager.removeItem(at: legacyURL)
            invalidateSavedConversationThreadSummariesCache()
            return
        }

        guard let legacyText = try? String(contentsOf: legacyURL, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n") else {
            return
        }

        let trimmedLegacyText = legacyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLegacyText.isEmpty {
            try? fileManager.removeItem(at: legacyURL)
            invalidateSavedConversationThreadSummariesCache()
            return
        }

        let noteID = UUID().uuidString.lowercased()
        let now = Date()
        let migratedNote = AssistantThreadNoteSummary(
            id: noteID,
            title: inferredLegacyThreadNoteTitle(from: legacyText),
            fileName: "\(safePathComponent(noteID)).md",
            order: 0,
            createdAt: now,
            updatedAt: now
        )
        let migratedManifest = AssistantThreadNoteManifest(
            selectedNoteID: migratedNote.id,
            notes: [migratedNote]
        )

        do {
            guard let migratedNoteURL = threadNoteFileURL(
                threadID: threadID,
                fileName: migratedNote.fileName
            ) else {
                return
            }
            try fileManager.createDirectory(
                at: migratedNoteURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try legacyText.write(to: migratedNoteURL, atomically: true, encoding: .utf8)
            try storeThreadNoteManifest(migratedManifest, threadID: threadID)
            try? fileManager.removeItem(at: legacyURL)
        } catch {
            return
        }
    }

    private func inferredLegacyThreadNoteTitle(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                let heading = String(
                    trimmed.drop(while: { $0 == "#" || $0 == " " || $0 == "\t" })
                )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !heading.isEmpty {
                    return heading
                }
            }
        }
        return Self.defaultThreadNoteTitle
    }

    private func threadDirectoryURL(for threadID: String) -> URL? {
        let safeThreadID = safePathComponent(threadID)
        guard !safeThreadID.isEmpty else { return nil }
        return baseDirectoryURL
            .appendingPathComponent(safeThreadID, isDirectory: true)
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

    private func appendEvent(
        threadID: String,
        stream: AssistantConversationEventStream,
        payload: AssistantConversationEventPayload
    ) throws {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty,
              let eventLogURL = eventLogFileURL(for: normalizedThreadID) else {
            return
        }

        let sequence = nextSequence(for: normalizedThreadID)
        let record = AssistantConversationEventRecord(
            sequence: sequence,
            threadID: normalizedThreadID,
            recordedAt: Date(),
            stream: stream,
            payload: payload
        )

        // Update in-memory state synchronously so callers see consistent sequences.
        nextSequenceByThreadID[normalizedThreadID] = sequence + 1
        invalidateSavedConversationThreadSummariesCache()

        // Encode and write to disk on a background serial queue to avoid
        // blocking the main thread on every streaming text delta.
        let fm = fileManager
        eventPersistenceQueue.async {
            do {
                try fm.createDirectory(
                    at: eventLogURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var lineData = try encoder.encode(record)
                lineData.append(0x0A)

                if fm.fileExists(atPath: eventLogURL.path) {
                    let handle = try FileHandle(forWritingTo: eventLogURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: lineData)
                } else {
                    try lineData.write(to: eventLogURL, options: .atomic)
                }
            } catch {
                // Best-effort persistence — the snapshot save acts as a
                // durable fallback that will capture the full state.
            }
        }
    }

    private func nextSequence(for threadID: String) -> Int {
        if let nextSequence = nextSequenceByThreadID[threadID] {
            return nextSequence
        }
        let nextSequence = highestEventSequence(for: threadID) + 1
        nextSequenceByThreadID[threadID] = nextSequence
        return nextSequence
    }

    private func highestEventSequence(for threadID: String) -> Int {
        let snapshotSequence = readStoredSnapshot(threadID: threadID)?.lastAppliedEventSequence ?? 0
        let logSequence = readEventRecords(threadID: threadID).last?.sequence ?? 0
        return max(snapshotSequence, logSequence)
    }

    private func readStoredSnapshot(threadID: String) -> AssistantConversationSnapshot? {
        guard let fileURL = snapshotFileURL(for: threadID),
              fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(AssistantConversationSnapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }

    private func readEventRecords(
        threadID: String,
        afterSequence: Int? = nil
    ) -> [AssistantConversationEventRecord] {
        guard let fileURL = eventLogFileURL(for: threadID),
              fileManager.fileExists(atPath: fileURL.path),
              let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        return contents
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> AssistantConversationEventRecord? in
                guard let data = line.data(using: .utf8),
                      let record = try? decoder.decode(AssistantConversationEventRecord.self, from: data) else {
                    return nil
                }
                if let afterSequence, record.sequence <= afterSequence {
                    return nil
                }
                return record
            }
            .sorted { $0.sequence < $1.sequence }
    }

    private func replayEventLog(
        threadID: String,
        onto storedSnapshot: AssistantConversationSnapshot?,
        rewriteSnapshot: Bool
    ) -> AssistantConversationSnapshot? {
        let normalizedThreadID = normalizedThreadID(threadID)
        let records = readEventRecords(
            threadID: normalizedThreadID,
            afterSequence: storedSnapshot?.lastAppliedEventSequence
        )

        if let storedSnapshot, records.isEmpty {
            nextSequenceByThreadID[normalizedThreadID] = max(
                nextSequenceByThreadID[normalizedThreadID] ?? 1,
                storedSnapshot.lastAppliedEventSequence + 1
            )
            return storedSnapshot
        }

        var snapshot = storedSnapshot ?? AssistantConversationSnapshot(
            version: Self.hybridSnapshotVersion,
            threadID: normalizedThreadID,
            timeline: [],
            transcript: [],
            turns: [],
            updatedAt: Date(),
            lastAppliedEventSequence: 0
        )

        let fallbackRecords = snapshot.lastAppliedEventSequence == 0 && storedSnapshot == nil
            ? readEventRecords(threadID: normalizedThreadID)
            : records

        guard !fallbackRecords.isEmpty else { return storedSnapshot }

        for record in fallbackRecords {
            guard record.threadID.caseInsensitiveCompare(normalizedThreadID) == .orderedSame else {
                continue
            }
            apply(record, to: &snapshot)
        }

        snapshot.version = Self.hybridSnapshotVersion
        snapshot.lastAppliedEventSequence = fallbackRecords.last?.sequence ?? snapshot.lastAppliedEventSequence
        snapshot.updatedAt = max(
            snapshot.updatedAt,
            fallbackRecords.last?.recordedAt ?? snapshot.updatedAt
        )
        snapshot.turns = Self.derivedTurnRecords(
            threadID: normalizedThreadID,
            timeline: snapshot.timeline,
            session: nil,
            existingTurns: snapshot.turns
        )

        nextSequenceByThreadID[normalizedThreadID] = snapshot.lastAppliedEventSequence + 1

        if rewriteSnapshot {
            try? storeSnapshot(snapshot)
        }

        return snapshot
    }

    private func summarizeConversationThread(
        at directoryURL: URL,
        includeNotesOnly: Bool
    ) -> AssistantConversationThreadSummary? {
        let threadID = directoryURL.lastPathComponent
        guard !threadID.isEmpty else { return nil }

        let snapshotURL = snapshotFileURL(for: threadID)
        let eventLogURL = eventLogFileURL(for: threadID)
        let hasSnapshot = snapshotURL.map {
            fileManager.fileExists(atPath: $0.path)
        } ?? false
        let hasEventLog = eventLogURL.map {
            fileManager.fileExists(atPath: $0.path)
        } ?? false
        let snapshot = resolvedSnapshotForEnumeration(threadID: threadID)
        let noteMetadata = readThreadNoteMetadata(threadID: threadID)
        let hasNotes = noteMetadata?.hasNotes ?? false

        guard hasSnapshot || hasEventLog || hasNotes else {
            return nil
        }

        guard includeNotesOnly || hasSnapshot || hasEventLog else {
            return nil
        }

        let latestUserMessage = snapshot?.transcript.reversed().first(where: { $0.role == .user })?
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let latestAssistantMessage = snapshot?.transcript.reversed().first(where: { $0.role == .assistant })?
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let lastUpdatedAt = [
            hasSnapshot ? snapshot?.updatedAt : nil,
            noteMetadata?.updatedAt,
            fileModificationDate(for: snapshotURL),
            fileModificationDate(for: eventLogURL),
            fileModificationDate(for: threadNoteManifestFileURL(for: threadID)),
            fileModificationDate(for: threadNoteFileURL(for: threadID))
        ]
        .compactMap { $0 }
        .max() ?? Date.distantPast

        return AssistantConversationThreadSummary(
            threadID: threadID,
            lastUpdatedAt: lastUpdatedAt,
            hasSnapshot: hasSnapshot,
            hasEventLog: hasEventLog,
            hasNotes: hasNotes,
            hasConversationContent: snapshot?.hasConversationContent == true,
            latestUserMessage: latestUserMessage,
            latestAssistantMessage: latestAssistantMessage,
            noteTitle: noteMetadata?.title
        )
    }

    private func resolvedSnapshotForEnumeration(threadID: String) -> AssistantConversationSnapshot? {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else { return nil }

        let storedSnapshot = readStoredSnapshot(threadID: normalizedThreadID)
        let logExists = eventLogFileURL(for: normalizedThreadID).map {
            fileManager.fileExists(atPath: $0.path)
        } ?? false

        if let storedSnapshot {
            guard storedSnapshot.version == Self.hybridSnapshotVersion, logExists else {
                return storedSnapshot
            }
            return replayEventLog(
                threadID: normalizedThreadID,
                onto: storedSnapshot,
                rewriteSnapshot: false
            )
        }

        guard logExists else { return nil }
        return replayEventLog(
            threadID: normalizedThreadID,
            onto: nil,
            rewriteSnapshot: false
        )
    }

    private func readThreadNoteMetadata(threadID: String) -> (hasNotes: Bool, title: String?, updatedAt: Date?)? {
        let normalizedThreadID = normalizedThreadID(threadID)
        guard !normalizedThreadID.isEmpty else { return nil }

        if let manifestMetadata = readManifestBackedThreadNoteMetadata(threadID: normalizedThreadID) {
            return manifestMetadata
        }

        return readLegacyThreadNoteMetadata(threadID: normalizedThreadID)
    }

    private func readManifestBackedThreadNoteMetadata(
        threadID: String
    ) -> (hasNotes: Bool, title: String?, updatedAt: Date?)? {
        guard let manifestURL = threadNoteManifestFileURL(for: threadID),
              fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode(AssistantThreadNoteManifest.self, from: data) else {
            return nil
        }

        let normalizedManifest = normalizedThreadNoteManifest(decoded)
        guard !normalizedManifest.notes.isEmpty else { return nil }

        let selectedNote = normalizedManifest.selectedNote
        let noteDates = normalizedManifest.notes.compactMap { note -> Date? in
            threadNoteFileURL(threadID: threadID, fileName: note.fileName)
                .flatMap(fileModificationDate(for:))
        }
        let updatedAt = [
            fileModificationDate(for: manifestURL),
            selectedNote.flatMap { threadNoteFileURL(threadID: threadID, fileName: $0.fileName) }
                .flatMap(fileModificationDate(for:)),
            noteDates.max()
        ]
        .compactMap { $0 }
        .max()

        return (
            hasNotes: true,
            title: selectedNote?.title,
            updatedAt: updatedAt
        )
    }

    private func readLegacyThreadNoteMetadata(
        threadID: String
    ) -> (hasNotes: Bool, title: String?, updatedAt: Date?)? {
        guard let legacyURL = threadNoteFileURL(for: threadID),
              fileManager.fileExists(atPath: legacyURL.path),
              let legacyText = try? String(contentsOf: legacyURL, encoding: .utf8)
                .replacingOccurrences(of: "\r\n", with: "\n") else {
            return nil
        }

        let trimmedLegacyText = legacyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLegacyText.isEmpty else { return nil }

        return (
            hasNotes: true,
            title: inferredLegacyThreadNoteTitle(from: legacyText),
            updatedAt: fileModificationDate(for: legacyURL)
        )
    }

    private func isDirectory(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
            return false
        }
        return values.isDirectory == true
    }

    private func fileModificationDate(for url: URL?) -> Date? {
        guard let url,
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    private func invalidateSavedConversationThreadSummariesCache() {
        cachedSavedConversationThreadSummaries.removeAll(keepingCapacity: true)
        cachedSavedConversationThreadSummariesStamp = nil
    }

    private func apply(
        _ record: AssistantConversationEventRecord,
        to snapshot: inout AssistantConversationSnapshot
    ) {
        switch record.payload.kind {
        case .transcriptReset:
            snapshot.transcript = []

        case .transcriptUpsert:
            guard let transcriptEntry = record.payload.transcriptEntry?.makeTranscriptEntry() else { return }
            upsertTranscriptEntry(transcriptEntry, entries: &snapshot.transcript)

        case .transcriptAppendDelta:
            guard let deltaEvent = record.payload.transcriptAppendDelta else { return }
            appendTranscriptDelta(deltaEvent, entries: &snapshot.transcript)

        case .timelineReset:
            snapshot.timeline = []

        case .timelineRemove:
            guard let removedTimelineItemID = record.payload.removedTimelineItemID else { return }
            snapshot.timeline.removeAll { $0.id == removedTimelineItemID }

        case .timelineUpsert:
            guard let timelineItem = record.payload.timelineItem?.makeTimelineItem() else { return }
            upsertTimelineItem(timelineItem, items: &snapshot.timeline)

        case .timelineAppendTextDelta:
            guard let deltaEvent = record.payload.timelineAppendTextDelta else { return }
            appendTimelineDelta(deltaEvent, items: &snapshot.timeline, sessionID: snapshot.threadID)
        }

        snapshot.updatedAt = max(snapshot.updatedAt, record.recordedAt)
    }

    private func upsertTranscriptEntry(
        _ entry: AssistantTranscriptEntry,
        entries: inout [AssistantTranscriptEntry]
    ) {
        if let existingIndex = entries.lastIndex(where: { $0.id == entry.id }) {
            entries[existingIndex] = entry
        } else {
            entries.append(entry)
        }
        entries.sort(by: Self.transcriptSort)
    }

    private func appendTranscriptDelta(
        _ deltaEvent: AssistantPersistedTranscriptAppendDeltaEvent,
        entries: inout [AssistantTranscriptEntry]
    ) {
        if let existingIndex = entries.lastIndex(where: { $0.id == deltaEvent.id }) {
            let existingEntry = entries[existingIndex]
            entries[existingIndex] = AssistantTranscriptEntry(
                id: existingEntry.id,
                role: existingEntry.role,
                text: existingEntry.text + deltaEvent.delta,
                createdAt: existingEntry.createdAt,
                emphasis: existingEntry.emphasis || deltaEvent.emphasis,
                isStreaming: deltaEvent.isStreaming,
                providerBackend: existingEntry.providerBackend ?? deltaEvent.providerBackend,
                providerModelID: existingEntry.providerModelID ?? deltaEvent.providerModelID
            )
        } else {
            entries.append(
                AssistantTranscriptEntry(
                    id: deltaEvent.id,
                    role: deltaEvent.role,
                    text: deltaEvent.delta,
                    createdAt: deltaEvent.createdAt,
                    emphasis: deltaEvent.emphasis,
                    isStreaming: deltaEvent.isStreaming,
                    providerBackend: deltaEvent.providerBackend,
                    providerModelID: deltaEvent.providerModelID
                )
            )
        }
        entries.sort(by: Self.transcriptSort)
    }

    private func upsertTimelineItem(
        _ item: AssistantTimelineItem,
        items: inout [AssistantTimelineItem]
    ) {
        if let existingIndex = items.firstIndex(where: { $0.id == item.id }) {
            items[existingIndex] = item
        } else {
            items.append(item)
        }
        items.sort(by: Self.timelineSort)
    }

    private func appendTimelineDelta(
        _ deltaEvent: AssistantPersistedTimelineAppendTextDeltaEvent,
        items: inout [AssistantTimelineItem],
        sessionID: String
    ) {
        if let existingIndex = items.firstIndex(where: { $0.id == deltaEvent.id }) {
            items[existingIndex].updatedAt = deltaEvent.updatedAt
            items[existingIndex].isStreaming = deltaEvent.isStreaming
            items[existingIndex].emphasis = items[existingIndex].emphasis || deltaEvent.emphasis
            if items[existingIndex].providerBackend == nil {
                items[existingIndex].providerBackend = deltaEvent.providerBackend
                items[existingIndex].providerModelID = deltaEvent.providerModelID
            }

            switch deltaEvent.kind {
            case .plan:
                let previousText = items[existingIndex].planText ?? ""
                items[existingIndex].planText = previousText + deltaEvent.delta
            default:
                items[existingIndex].text = (items[existingIndex].text ?? "") + deltaEvent.delta
            }
        } else {
            let newItem: AssistantTimelineItem
            switch deltaEvent.kind {
            case .assistantProgress:
                newItem = .assistantProgress(
                    id: deltaEvent.id,
                    sessionID: sessionID,
                    turnID: deltaEvent.turnID,
                    text: deltaEvent.delta,
                    createdAt: deltaEvent.createdAt,
                    updatedAt: deltaEvent.updatedAt,
                    isStreaming: deltaEvent.isStreaming,
                    providerBackend: deltaEvent.providerBackend,
                    providerModelID: deltaEvent.providerModelID,
                    source: deltaEvent.source
                )
            case .assistantFinal:
                newItem = .assistantFinal(
                    id: deltaEvent.id,
                    sessionID: sessionID,
                    turnID: deltaEvent.turnID,
                    text: deltaEvent.delta,
                    createdAt: deltaEvent.createdAt,
                    updatedAt: deltaEvent.updatedAt,
                    isStreaming: deltaEvent.isStreaming,
                    providerBackend: deltaEvent.providerBackend,
                    providerModelID: deltaEvent.providerModelID,
                    source: deltaEvent.source
                )
            case .plan:
                newItem = .plan(
                    id: deltaEvent.id,
                    sessionID: sessionID,
                    turnID: deltaEvent.turnID,
                    text: deltaEvent.delta,
                    entries: nil,
                    createdAt: deltaEvent.createdAt,
                    updatedAt: deltaEvent.updatedAt,
                    isStreaming: deltaEvent.isStreaming,
                    source: deltaEvent.source
                )
            case .system:
                newItem = .system(
                    id: deltaEvent.id,
                    sessionID: sessionID,
                    turnID: deltaEvent.turnID,
                    text: deltaEvent.delta,
                    createdAt: deltaEvent.createdAt,
                    emphasis: deltaEvent.emphasis,
                    source: deltaEvent.source
                )
            case .userMessage:
                newItem = .userMessage(
                    id: deltaEvent.id,
                    sessionID: sessionID,
                    turnID: deltaEvent.turnID,
                    text: deltaEvent.delta,
                    createdAt: deltaEvent.createdAt,
                    selectedPlugins: nil,
                    providerBackend: deltaEvent.providerBackend,
                    providerModelID: deltaEvent.providerModelID,
                    source: deltaEvent.source
                )
            case .activity, .permission:
                return
            }
            items.append(newItem)
        }

        items.sort(by: Self.timelineSort)
    }

    private func visibleTimeline(threadID: String) -> [AssistantTimelineItem] {
        guard let snapshot = loadSnapshot(threadID: threadID) else { return [] }
        return Self.visibleTimeline(from: snapshot)
    }

    private static func visibleTimeline(from snapshot: AssistantConversationSnapshot) -> [AssistantTimelineItem] {
        let synthesized = synthesizedTimeline(from: snapshot.transcript, threadID: snapshot.threadID)

        guard !snapshot.timeline.isEmpty else {
            return synthesized
        }

        guard shouldRebuildVisibleTimeline(
            storedTimeline: snapshot.timeline,
            transcript: snapshot.transcript
        ) else {
            return snapshot.timeline
        }

        let missingSynthesizedItems = synthesized.filter { synthesizedItem in
            !snapshot.timeline.contains { storedItem in
                visibleTimelineItemsLikelyMatch(storedItem, synthesizedItem)
            }
        }

        return (snapshot.timeline + missingSynthesizedItems).sorted(by: timelineSort)
    }

    private static func synthesizedTimeline(
        from transcript: [AssistantTranscriptEntry],
        threadID: String
    ) -> [AssistantTimelineItem] {
        transcript.compactMap { entry in
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            switch entry.role {
            case .user:
                return .userMessage(
                    id: entry.id.uuidString,
                    sessionID: threadID,
                    text: text,
                    createdAt: entry.createdAt,
                    selectedPlugins: entry.selectedPlugins,
                    providerBackend: entry.providerBackend,
                    providerModelID: entry.providerModelID,
                    source: .runtime
                )
            case .assistant:
                return .assistantFinal(
                    id: entry.id.uuidString,
                    sessionID: threadID,
                    text: text,
                    createdAt: entry.createdAt,
                    updatedAt: entry.createdAt,
                    isStreaming: entry.isStreaming,
                    providerBackend: entry.providerBackend,
                    providerModelID: entry.providerModelID,
                    source: .runtime
                )
            case .system, .status, .tool, .permission, .error:
                return .system(
                    id: entry.id.uuidString,
                    sessionID: threadID,
                    text: text,
                    createdAt: entry.createdAt,
                    emphasis: entry.emphasis || entry.role == .error,
                    source: .runtime
                )
            }
        }
    }

    private static func shouldRebuildVisibleTimeline(
        storedTimeline: [AssistantTimelineItem],
        transcript: [AssistantTranscriptEntry]
    ) -> Bool {
        let transcriptUserCount = transcript.reduce(into: 0) { count, entry in
            guard entry.role == .user,
                  entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return
            }
            count += 1
        }
        guard transcriptUserCount > 0 else { return false }

        let storedUserCount = storedTimeline.reduce(into: 0) { count, item in
            guard item.kind == .userMessage,
                  item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return
            }
            count += 1
        }

        return storedUserCount < transcriptUserCount
    }

    private static func visibleTimelineItemsLikelyMatch(
        _ lhs: AssistantTimelineItem,
        _ rhs: AssistantTimelineItem
    ) -> Bool {
        if lhs.id == rhs.id {
            return true
        }

        switch (lhs.kind, rhs.kind) {
        case (.userMessage, .userMessage),
             (.system, .system):
            return normalizedVisibleTimelineText(lhs.text) == normalizedVisibleTimelineText(rhs.text)
                && abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) < 1

        case (.assistantProgress, .assistantProgress),
             (.assistantFinal, .assistantFinal),
             (.assistantProgress, .assistantFinal),
             (.assistantFinal, .assistantProgress):
            return normalizedVisibleTimelineText(lhs.text) == normalizedVisibleTimelineText(rhs.text)
                && abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) < 120

        default:
            return false
        }
    }

    private static func normalizedVisibleTimelineText(_ value: String?) -> String {
        (value ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func persistSanitizedSnapshotIfNeeded(
        snapshot: AssistantConversationSnapshot?,
        logExists: Bool
    ) -> AssistantConversationSnapshot? {
        guard let snapshot else { return nil }
        let sanitized = Self.sanitizedSnapshot(snapshot)
        guard sanitized != snapshot else { return snapshot }

        if sanitized.version == Self.hybridSnapshotVersion, logExists {
            try? rewriteHybridSnapshotAndEventLog(sanitized)
        } else {
            try? storeSnapshot(sanitized)
        }
        return sanitized
    }

    private static func sanitizedSnapshot(
        _ snapshot: AssistantConversationSnapshot
    ) -> AssistantConversationSnapshot {
        let sanitizedTranscript = sanitizedTranscriptEntries(snapshot.transcript)
        let sanitizedTimeline = sanitizedTimelineItems(snapshot.timeline)

        guard sanitizedTranscript != snapshot.transcript || sanitizedTimeline != snapshot.timeline else {
            return snapshot
        }

        var sanitized = snapshot
        sanitized.transcript = sanitizedTranscript
        sanitized.timeline = sanitizedTimeline
        sanitized.turns = derivedTurnRecords(
            threadID: snapshot.threadID,
            timeline: sanitizedTimeline,
            session: nil,
            existingTurns: snapshot.turns
        )
        return sanitized
    }

    private static func sanitizedTranscriptEntries(
        _ entries: [AssistantTranscriptEntry]
    ) -> [AssistantTranscriptEntry] {
        var kept: [AssistantTranscriptEntry] = []
        var seenAssistantTexts = Set<String>()

        for entry in entries.sorted(by: transcriptSort) {
            let normalizedText = normalizedVisibleTimelineText(entry.text)
            let isOrphanAssistantDuplicate = entry.role == .assistant
                && entry.isStreaming
                && !normalizedText.isEmpty
                && seenAssistantTexts.contains(normalizedText)

            guard !isOrphanAssistantDuplicate else { continue }
            kept.append(entry)

            if entry.role == .assistant, !normalizedText.isEmpty {
                seenAssistantTexts.insert(normalizedText)
            }
        }

        return kept
    }

    private static func sanitizedTimelineItems(
        _ items: [AssistantTimelineItem]
    ) -> [AssistantTimelineItem] {
        var kept: [AssistantTimelineItem] = []
        var seenAssistantTexts = Set<String>()

        for item in items.sorted(by: timelineSort) {
            let normalizedText = normalizedVisibleTimelineText(item.text)
            let isAssistantMessage = item.kind == .assistantProgress || item.kind == .assistantFinal
            let hasTurnID = item.turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
            let isOrphanAssistantDuplicate = isAssistantMessage
                && item.isStreaming
                && !hasTurnID
                && !normalizedText.isEmpty
                && seenAssistantTexts.contains(normalizedText)

            guard !isOrphanAssistantDuplicate else { continue }
            kept.append(item)

            if isAssistantMessage, !normalizedText.isEmpty {
                seenAssistantTexts.insert(normalizedText)
            }
        }

        return kept
    }

    private static func derivedTurnRecords(
        threadID: String,
        timeline: [AssistantTimelineItem],
        session: AssistantSessionSummary?,
        existingTurns: [AssistantConversationTurnRecord]? = nil
    ) -> [AssistantConversationTurnRecord] {
        let existingTurnsByID = Dictionary(
            uniqueKeysWithValues: (existingTurns ?? []).map { ($0.openAssistTurnID, $0) }
        )
        let grouped = Dictionary(grouping: timeline) { item in
            item.turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? ""
        }

        return grouped
            .compactMap { turnID, items -> AssistantConversationTurnRecord? in
                guard !turnID.isEmpty else { return nil }
                let sortedItems = items.sorted(by: timelineSort)
                let provider = sortedItems.reversed().compactMap(\.providerBackend).first
                    ?? session?.activeProviderBackend
                    ?? existingTurnsByID[turnID]?.provider
                let providerSessionID = provider.flatMap { backend in
                    session?.providerBinding(for: backend)?.providerSessionID
                } ?? existingTurnsByID[turnID]?.providerSessionID
                return AssistantConversationTurnRecord(
                    threadID: threadID,
                    openAssistTurnID: turnID,
                    provider: provider,
                    providerSessionID: providerSessionID,
                    providerTurnID: turnID,
                    messageIDs: sortedItems.map(\.id),
                    createdAt: sortedItems.first?.sortDate,
                    updatedAt: sortedItems.last?.lastUpdatedAt,
                    checkpointReferences: existingTurnsByID[turnID]?.checkpointReferences ?? []
                )
            }
            .sorted {
                ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
            }
    }

    private static func timelineSort(
        _ lhs: AssistantTimelineItem,
        _ rhs: AssistantTimelineItem
    ) -> Bool {
        if lhs.sortDate != rhs.sortDate {
            return lhs.sortDate < rhs.sortDate
        }
        if lhs.lastUpdatedAt != rhs.lastUpdatedAt {
            return lhs.lastUpdatedAt < rhs.lastUpdatedAt
        }
        return lhs.id < rhs.id
    }

    private static func transcriptSort(
        _ lhs: AssistantTranscriptEntry,
        _ rhs: AssistantTranscriptEntry
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
