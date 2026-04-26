import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

private enum AssistantSidebarPane {
    case threads
    case notes
    case archived
    case automations
    case skills
    case plugins
}

private enum AssistantNotesScope: String {
    case project
    case thread
}

private enum AssistantThreadsDetailMode: Equatable {
    case chat
    case projectNotes(String)
}

private enum AssistantChatHistoryDisplayMode: String {
    case timeline
    case messagesFirst
}

struct AssistantProjectNotesChromeState: Equatable {
    let isFocusModeActive: Bool
    let persistedSidebarCollapsed: Bool

    var effectiveSidebarCollapsed: Bool {
        isFocusModeActive ? true : persistedSidebarCollapsed
    }

    var showsExpandedSidebar: Bool {
        !isFocusModeActive && !persistedSidebarCollapsed
    }

    var showsCollapsedSidebarOverlay: Bool {
        !isFocusModeActive && persistedSidebarCollapsed
    }

    var showsResizeHandle: Bool {
        !isFocusModeActive
    }
}

func assistantProjectNotesRememberedSidebarCollapsed(
    currentRestoreState: Bool?,
    persistedSidebarCollapsed: Bool
) -> Bool {
    currentRestoreState ?? persistedSidebarCollapsed
}

func assistantProjectNotesRestoredSidebarCollapsed(
    persistedSidebarCollapsed: Bool,
    restoreState: Bool?
) -> Bool {
    restoreState ?? persistedSidebarCollapsed
}

struct AssistantNotesProjectSessionRegistry: Codable, Equatable, Sendable {
    var sessionIDs: [String]
    var lastUsedSessionID: String?

    init(sessionIDs: [String] = [], lastUsedSessionID: String? = nil) {
        let normalizedSessionIDs = Self.normalizedSessionIDs(from: sessionIDs)
        let normalizedLastUsedSessionID = assistantNormalizedNotesSessionID(lastUsedSessionID)

        self.sessionIDs = normalizedSessionIDs
        self.lastUsedSessionID =
            normalizedSessionIDs.contains(where: {
                assistantTimelineSessionIDsMatch($0, normalizedLastUsedSessionID)
            })
            ? normalizedLastUsedSessionID
            : nil
    }

    var isEmpty: Bool { sessionIDs.isEmpty }

    private static func normalizedSessionIDs(from sessionIDs: [String]) -> [String] {
        var normalized: [String] = []

        for sessionID in sessionIDs {
            guard let normalizedSessionID = assistantNormalizedNotesSessionID(sessionID),
                !normalized.contains(where: {
                    assistantTimelineSessionIDsMatch($0, normalizedSessionID)
                })
            else {
                continue
            }
            normalized.append(normalizedSessionID)
        }

        return normalized
    }
}

func assistantNormalizedNotesProjectID(_ projectID: String?) -> String? {
    projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty?.lowercased()
}

func assistantNormalizedNotesSessionID(_ sessionID: String?) -> String? {
    sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
}

func assistantDecodeNotesAssistantSessionRegistries(
    from jsonString: String
) -> [String: AssistantNotesProjectSessionRegistry] {
    guard let data = jsonString.data(using: .utf8) else { return [:] }

    if let decoded = try? JSONDecoder().decode(
        [String: AssistantNotesProjectSessionRegistry].self,
        from: data
    ) {
        return decoded.reduce(into: [:]) { result, pair in
            guard let projectID = assistantNormalizedNotesProjectID(pair.key) else { return }
            let normalizedRegistry = AssistantNotesProjectSessionRegistry(
                sessionIDs: pair.value.sessionIDs,
                lastUsedSessionID: pair.value.lastUsedSessionID
            )
            guard !normalizedRegistry.isEmpty else { return }
            result[projectID] = normalizedRegistry
        }
    }

    if let legacyDecoded = try? JSONDecoder().decode([String: String].self, from: data) {
        return legacyDecoded.reduce(into: [:]) { result, pair in
            guard let projectID = assistantNormalizedNotesProjectID(pair.key),
                let sessionID = assistantNormalizedNotesSessionID(pair.value)
            else {
                return
            }
            result[projectID] = AssistantNotesProjectSessionRegistry(
                sessionIDs: [sessionID],
                lastUsedSessionID: sessionID
            )
        }
    }

    return [:]
}

func assistantEncodeNotesAssistantSessionRegistries(
    _ registries: [String: AssistantNotesProjectSessionRegistry]
) -> String? {
    let normalized = registries.reduce(into: [String: AssistantNotesProjectSessionRegistry]()) {
        result,
        pair in
        guard let projectID = assistantNormalizedNotesProjectID(pair.key) else { return }
        let normalizedRegistry = AssistantNotesProjectSessionRegistry(
            sessionIDs: pair.value.sessionIDs,
            lastUsedSessionID: pair.value.lastUsedSessionID
        )
        guard !normalizedRegistry.isEmpty else { return }
        result[projectID] = normalizedRegistry
    }

    guard !normalized.isEmpty,
        let data = try? JSONEncoder().encode(normalized)
    else {
        return nil
    }

    return String(data: data, encoding: .utf8)
}

func assistantNotesSessionRecencyDate(_ session: AssistantSessionSummary) -> Date {
    session.updatedAt ?? session.createdAt ?? .distantPast
}

func assistantResolvedNotesAssistantSessionID(
    projectID: String?,
    registries: [String: AssistantNotesProjectSessionRegistry],
    sessions: [AssistantSessionSummary]
) -> String? {
    guard let normalizedProjectID = assistantNormalizedNotesProjectID(projectID),
        let registry = registries[normalizedProjectID],
        !registry.sessionIDs.isEmpty
    else {
        return nil
    }

    let validSessions = registry.sessionIDs.compactMap { registeredSessionID in
        sessions.first(where: {
            assistantTimelineSessionIDsMatch($0.id, registeredSessionID)
        })
    }
    .filter { !$0.isArchived }

    guard !validSessions.isEmpty else { return nil }

    if let lastUsedSessionID = assistantNormalizedNotesSessionID(registry.lastUsedSessionID),
        let matchedSession = validSessions.first(where: {
            assistantTimelineSessionIDsMatch($0.id, lastUsedSessionID)
        })
    {
        return matchedSession.id
    }

    return validSessions.max(by: {
        assistantNotesSessionRecencyDate($0) < assistantNotesSessionRecencyDate($1)
    })?.id
}

func assistantNotesAssistantSessionTitle(
    projectName: String,
    existingRegistry: AssistantNotesProjectSessionRegistry,
    createdAt: Date
) -> String {
    let baseTitle = "Notes Assistant · \(projectName)"
    guard !existingRegistry.sessionIDs.isEmpty else { return baseTitle }
    return "\(baseTitle) · \(createdAt.formatted(date: .abbreviated, time: .shortened))"
}

enum AssistantWindowPresentationStyle {
    case window
    case compactSidebar
}

private struct AssistantNoteOwnerKey: Hashable {
    let kind: AssistantNoteOwnerKind
    let id: String

    var storageKey: String {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(kind.rawValue)::\(normalizedID)"
    }

    var displaySourceLabel: String {
        switch kind {
        case .thread:
            return "Thread notes"
        case .project:
            return "Project notes"
        }
    }
}

private struct ProjectNoteHeadingSection {
    let title: String
    let normalizedTitle: String
    let level: Int
    let lineStartUTF16: Int
    let contentStartUTF16: Int
    let sectionEndUTF16: Int
    let path: [String]
    let normalizedPath: [String]
}

private struct AssistantNoteNavigationEntry: Hashable {
    let owner: AssistantNoteOwnerKey
    let noteID: String
    let title: String
}

private struct AssistantNotesUniverseThreadSource {
    let session: AssistantSessionSummary
    let owner: AssistantNoteOwnerKey
    let notes: [AssistantStoredNote]
}

private struct AssistantNotesUniverse {
    let project: AssistantProject
    let projectOwner: AssistantNoteOwnerKey
    let projectNotes: [AssistantStoredNote]
    let projectFolders: [AssistantNoteFolderSummary]
    let projectFolderPathByID: [String: [String]]
    let threadSources: [AssistantNotesUniverseThreadSource]

    var threadNotes: [AssistantStoredNote] {
        threadSources.flatMap(\.notes)
    }

    var allNotes: [AssistantStoredNote] {
        projectNotes + threadNotes
    }
}

private struct AssistantSidebarNoteRowModel: Identifiable {
    let target: AssistantNoteLinkTarget
    let title: String
    let subtitle: String
    let sourceLabel: String
    let updatedAt: Date
    let folderID: String?
    let folderPath: [String]
    let isArchivedThread: Bool
    let threadID: String?

    var id: String { target.storageKey }
}

private struct AssistantSidebarNoteFolderRowModel: Identifiable {
    let id: String
    let name: String
    let parentFolderID: String?
    let path: [String]
    let isExpanded: Bool
    let childFolderCount: Int
    let noteCount: Int
}

extension AssistantSidebarPane {
    fileprivate var shellID: String {
        switch self {
        case .threads:
            return "threads"
        case .notes:
            return "notes"
        case .archived:
            return "archived"
        case .automations:
            return "automations"
        case .skills:
            return "skills"
        case .plugins:
            return "plugins"
        }
    }

    fileprivate init?(shellID: String) {
        switch shellID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "threads":
            self = .threads
        case "notes":
            self = .notes
        case "archived":
            self = .archived
        case "automations":
            self = .automations
        case "skills":
            self = .skills
        case "plugins":
            self = .plugins
        default:
            return nil
        }
    }
}

private struct AssistantProjectIconOption: Identifiable {
    let title: String
    let symbol: String

    var id: String { symbol }
}

private struct AssistantWorkspaceLaunchTarget: Identifiable {
    enum LaunchStyle {
        case openDocuments
        case revealInFinder
    }

    let title: String
    let bundleIdentifiers: [String]
    let fallbackSymbol: String
    let launchStyle: LaunchStyle
    let remembersAsPreferred: Bool

    var id: String { title }

    @MainActor
    var applicationURL: URL? {
        for bundleIdentifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier)
            {
                return url
            }
        }
        return nil
    }

    @MainActor
    var isInstalled: Bool {
        switch launchStyle {
        case .openDocuments:
            return applicationURL != nil
        case .revealInFinder:
            return true
        }
    }
}

func assistantTimelineItemLooksLikeVisibleError(_ item: AssistantTimelineItem) -> Bool {
    guard item.kind == .system,
        let cleanedText = AssistantVisibleTextSanitizer.clean(item.text)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .lowercased()
    else {
        return false
    }

    return cleanedText.contains("error")
        || cleanedText.contains("failed")
        || cleanedText.contains("could not")
        || cleanedText.contains("unable")
}

func assistantMessagesFirstVisibleRenderItems(
    from renderItems: [AssistantTimelineRenderItem],
    pendingPermissionSessionID: String? = nil,
    preferLiveActivityCard: Bool = false
) -> [AssistantTimelineRenderItem] {
    let latestConversationTurnID = renderItems.reversed().compactMap { renderItem -> String? in
        switch renderItem {
        case .timeline(let item):
            switch item.kind {
            case .assistantProgress, .assistantFinal, .plan, .activity:
                return item.turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? item.activity?.turnID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            case .userMessage, .permission, .system:
                return nil
            }
        case .activityGroup(let group):
            return group.items.reversed().compactMap { item in
                item.turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? item.activity?.turnID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            }.first
        }
    }.first

    let latestUserIndex = renderItems.lastIndex { renderItem in
        if case .timeline(let item) = renderItem {
            return item.kind == .userMessage
        }
        return false
    }

    func shouldKeepLatestActivity(
        _ renderItem: AssistantTimelineRenderItem,
        index: Int
    ) -> Bool {
        let candidateTurnIDs: [String] = {
            switch renderItem {
            case .timeline(let item):
                return [
                    item.turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                    item.activity?.turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                ].compactMap { $0 }
            case .activityGroup(let group):
                return group.items.compactMap { item in
                    item.turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                        ?? item.activity?.turnID?.trimmingCharacters(in: .whitespacesAndNewlines)
                        .nonEmpty
                }
            }
        }()

        if let latestConversationTurnID,
            candidateTurnIDs.contains(where: {
                $0.caseInsensitiveCompare(latestConversationTurnID) == .orderedSame
            })
        {
            return true
        }

        if let latestUserIndex {
            return index > latestUserIndex
        }

        switch renderItem {
        case .timeline(let item):
            return item.activity?.status.isActive == true
        case .activityGroup(let group):
            return group.activities.contains(where: \.status.isActive)
        }
    }

    return renderItems.enumerated().compactMap { index, renderItem in
        switch renderItem {
        case .activityGroup:
            if preferLiveActivityCard {
                return nil
            }
            return shouldKeepLatestActivity(renderItem, index: index) ? renderItem : nil

        case .timeline(let item):
            switch item.kind {
            case .userMessage, .assistantProgress, .assistantFinal, .plan:
                return renderItem
            case .permission:
                guard let pendingPermissionSessionID = pendingPermissionSessionID?.nonEmpty else {
                    return nil
                }
                return item.permissionRequest?.sessionID.caseInsensitiveCompare(
                    pendingPermissionSessionID
                ) == .orderedSame ? renderItem : nil
            case .system:
                return assistantTimelineItemLooksLikeVisibleError(item) ? renderItem : nil
            case .activity:
                if preferLiveActivityCard {
                    return nil
                }
                return shouldKeepLatestActivity(renderItem, index: index) ? renderItem : nil
            }
        }
    }
}

@MainActor
private final class AssistantThreadNoteMenuSelectionHandler: NSObject {
    let onSelect: (String) -> Void

    init(onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
    }

    @objc func handleSelect(_ sender: NSMenuItem) {
        guard let noteID = sender.representedObject as? String else { return }
        onSelect(noteID)
    }
}

@MainActor
/// In-memory draft cache plus a debounced disk mirror. The disk mirror
/// exists so that if the app is hard-killed (crash, force quit, power
/// loss) between the last keystroke and the next successful save, we
/// can recover the unsaved text on relaunch.
///
/// Layout on disk:
///   ~/Library/Application Support/OpenAssist/note-drafts/
///       <urlEncoded ownerKey>/<noteID>.draft.md
///
/// Draft files are deleted after a successful save via
/// `clearPersistedDraft(ownerKey:noteID:)`.
private final class AssistantThreadNoteDraftStore {
    private var draftsByOwnerKey: [String: [String: String]] = [:]
    private var revisionsByOwnerKey: [String: [String: Int]] = [:]
    private var pendingDiskWrites: [String: DispatchWorkItem] = [:]
    private let diskWriteQueue = DispatchQueue(
        label: "OpenAssist.threadNoteDraftStore.disk",
        qos: .utility
    )
    private let diskWriteDebounce: TimeInterval = 0.25

    init() {
        // Best-effort load of any surviving drafts from a prior session.
        restorePersistedDrafts()
    }

    func draft(ownerKey: String, noteID: String) -> String? {
        draftsByOwnerKey[ownerKey]?[noteID]
    }

    func draftRevision(ownerKey: String, noteID: String) -> Int? {
        revisionsByOwnerKey[ownerKey]?[noteID]
    }

    func drafts(ownerKey: String) -> [String: String] {
        draftsByOwnerKey[ownerKey] ?? [:]
    }

    func setDraft(_ text: String, ownerKey: String, noteID: String, revision: Int? = nil) {
        if let revision,
           let currentRevision = revisionsByOwnerKey[ownerKey]?[noteID],
           revision < currentRevision
        {
            return
        }

        var drafts = draftsByOwnerKey[ownerKey] ?? [:]
        drafts[noteID] = text
        draftsByOwnerKey[ownerKey] = drafts

        if let revision {
            var revisions = revisionsByOwnerKey[ownerKey] ?? [:]
            revisions[noteID] = revision
            revisionsByOwnerKey[ownerKey] = revisions
        }
        schedulePersist(ownerKey: ownerKey, noteID: noteID, text: text)
    }

    func replaceDrafts(_ drafts: [String: String], ownerKey: String) {
        draftsByOwnerKey[ownerKey] = drafts
        if var revisions = revisionsByOwnerKey[ownerKey] {
            let validNoteIDs = Set(drafts.keys)
            revisions = revisions.filter { validNoteIDs.contains($0.key) }
            revisionsByOwnerKey[ownerKey] = revisions
        }
        for (noteID, text) in drafts {
            schedulePersist(ownerKey: ownerKey, noteID: noteID, text: text)
        }
    }

    /// Call after a successful persisted save so the draft backup can
    /// be cleaned up. The in-memory cache stays in place; only the
    /// disk mirror is removed.
    func clearPersistedDraft(ownerKey: String, noteID: String) {
        let key = diskKey(ownerKey: ownerKey, noteID: noteID)
        pendingDiskWrites.removeValue(forKey: key)?.cancel()
        guard let url = Self.draftFileURL(ownerKey: ownerKey, noteID: noteID) else {
            return
        }
        diskWriteQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func discardDraft(ownerKey: String, noteID: String) {
        draftsByOwnerKey[ownerKey]?[noteID] = nil
        revisionsByOwnerKey[ownerKey]?[noteID] = nil
        clearPersistedDraft(ownerKey: ownerKey, noteID: noteID)
    }

    func clearPersistedDraftIfCurrent(
        ownerKey: String,
        noteID: String,
        expectedText: String,
        savedRevision: Int?
    ) {
        if let currentDraft = draft(ownerKey: ownerKey, noteID: noteID),
           currentDraft != expectedText
        {
            return
        }
        if let savedRevision,
           let currentRevision = draftRevision(ownerKey: ownerKey, noteID: noteID),
           currentRevision > savedRevision
        {
            return
        }
        clearPersistedDraft(ownerKey: ownerKey, noteID: noteID)
    }

    // MARK: - Disk persistence

    private func schedulePersist(ownerKey: String, noteID: String, text: String) {
        let key = diskKey(ownerKey: ownerKey, noteID: noteID)
        pendingDiskWrites.removeValue(forKey: key)?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.persist(ownerKey: ownerKey, noteID: noteID, text: text)
        }
        pendingDiskWrites[key] = work
        diskWriteQueue.asyncAfter(deadline: .now() + diskWriteDebounce, execute: work)
    }

    private func persist(ownerKey: String, noteID: String, text: String) {
        guard let url = Self.draftFileURL(ownerKey: ownerKey, noteID: noteID) else {
            return
        }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            CrashReporter.logError(
                "Failed to persist note draft (\(ownerKey)/\(noteID)): \(error.localizedDescription)"
            )
        }
    }

    private func restorePersistedDrafts() {
        guard let rootURL = Self.draftsRootURL() else { return }
        guard let ownerDirs = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for ownerDir in ownerDirs {
            let ownerKey = Self.decodeOwnerKeySegment(ownerDir.lastPathComponent)
            guard let draftFiles = try? FileManager.default.contentsOfDirectory(
                at: ownerDir,
                includingPropertiesForKeys: nil
            ) else {
                continue
            }
            var drafts: [String: String] = [:]
            for file in draftFiles {
                let name = file.lastPathComponent
                guard name.hasSuffix(".draft.md") else { continue }
                let noteID = String(name.dropLast(".draft.md".count))
                guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                    continue
                }
                drafts[noteID] = text
            }
            if !drafts.isEmpty {
                draftsByOwnerKey[ownerKey] = drafts
            }
        }
    }

    private func diskKey(ownerKey: String, noteID: String) -> String {
        "\(ownerKey)\u{001F}\(noteID)"
    }

    private static func draftsRootURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("OpenAssist", isDirectory: true)
            .appendingPathComponent("note-drafts", isDirectory: true)
    }

    private static func draftFileURL(ownerKey: String, noteID: String) -> URL? {
        guard let root = draftsRootURL() else { return nil }
        let encodedOwner = encodeOwnerKeySegment(ownerKey)
        let safeNoteID = noteID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? noteID
        return root
            .appendingPathComponent(encodedOwner, isDirectory: true)
            .appendingPathComponent("\(safeNoteID).draft.md")
    }

    private static func encodeOwnerKeySegment(_ ownerKey: String) -> String {
        ownerKey.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? ownerKey
    }

    private static func decodeOwnerKeySegment(_ segment: String) -> String {
        segment.removingPercentEncoding ?? segment
    }
}

struct AssistantWindowView: View {
    static let initialVisibleHistoryLimit = 24
    static let historyBatchSize = 24
    static let minimumVisibleChatMessagesBeforeLoadMore = 10
    static let initialSidebarVisibleSessionsLimit = 30
    private static let autoScrollThreshold: CGFloat = 24
    private static let manualScrollFollowPause: TimeInterval = 0.85
    private static let manualLoadOlderPause: TimeInterval = 0.75
    private static let nearBottomThreshold: CGFloat = 80
    private static let loadOlderThreshold: CGFloat = 140
    private static let projectIconOptions: [AssistantProjectIconOption] = [
        .init(title: "Folder", symbol: "folder.fill"),
        .init(title: "Stack", symbol: "square.stack.3d.up.fill"),
        .init(title: "Briefcase", symbol: "briefcase.fill"),
        .init(title: "Book", symbol: "book.closed.fill"),
        .init(title: "Terminal", symbol: "terminal.fill"),
        .init(title: "Sparkles", symbol: "sparkles"),
        .init(title: "Star", symbol: "star.fill"),
        .init(title: "Brain", symbol: "brain"),
    ]
    private static let workspaceLaunchTargets: [AssistantWorkspaceLaunchTarget] = [
        .init(
            title: "VS Code",
            bundleIdentifiers: ["com.microsoft.VSCode"],
            fallbackSymbol: "chevron.left.forwardslash.chevron.right",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "VS Code Insiders",
            bundleIdentifiers: ["com.microsoft.VSCodeInsiders"],
            fallbackSymbol: "chevron.left.forwardslash.chevron.right",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Cursor",
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            fallbackSymbol: "command.square",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Windsurf",
            bundleIdentifiers: ["com.exafunction.windsurf"],
            fallbackSymbol: "wind",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Antigravity",
            bundleIdentifiers: ["com.google.antigravity"],
            fallbackSymbol: "sparkles",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Finder",
            bundleIdentifiers: ["com.apple.finder"],
            fallbackSymbol: "folder.fill",
            launchStyle: .revealInFinder,
            remembersAsPreferred: false
        ),
        .init(
            title: "Terminal",
            bundleIdentifiers: ["com.apple.Terminal"],
            fallbackSymbol: "terminal.fill",
            launchStyle: .openDocuments,
            remembersAsPreferred: false
        ),
        .init(
            title: "Xcode",
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            fallbackSymbol: "hammer.fill",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Android Studio",
            bundleIdentifiers: ["com.google.android.studio"],
            fallbackSymbol: "curlybraces.square.fill",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
    ]
    private static let sidebarRelativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private struct ChatLayoutMetrics {
        let windowWidth: CGFloat
        let windowHeight: CGFloat
        let sidebarWidth: CGFloat
        let collapsedSidebarWidth: CGFloat
        let collapsedSidebarPreviewWidth: CGFloat
        let visibleSidebarWidth: CGFloat
        let detailWidth: CGFloat
        let outerPadding: CGFloat
        let timelineHorizontalPadding: CGFloat
        let contentMaxWidth: CGFloat
        let topBarMaxWidth: CGFloat
        let composerMaxWidth: CGFloat
        let userBubbleMaxWidth: CGFloat
        let userMediaMaxWidth: CGFloat
        let assistantMediaMaxWidth: CGFloat
        let leadingReserve: CGFloat
        let assistantTrailingPaddingRegular: CGFloat
        let assistantTrailingPaddingCompact: CGFloat
        let assistantTrailingPaddingStatus: CGFloat
        let activityLeadingPadding: CGFloat
        let activityTrailingPadding: CGFloat
        let jumpButtonTrailing: CGFloat
        let emptyStateCardWidth: CGFloat
        let emptyStateTextWidth: CGFloat
        let isNarrow: Bool
    }

    private struct SelectionAskConversationSession: Equatable {
        struct Key: Hashable {
            let sessionID: String
        }

        let key: Key
        let agentSessionID: String
        var preferredBackend: AssistantRuntimeBackend
        var preferredModelID: String?
        var isLoadingModels: Bool
        var isRequestInFlight: Bool
        var mainChatSummaryFingerprint: String?
        var mainChatSummary: String?
        var turns: [SelectionAskConversationTurn]
    }

    private struct ThreadNoteChartContext: Equatable {
        let selectedText: String
        let parentMessageText: String
        let sourceKind: String
    }

    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var assistant: AssistantStore
    let presentationStyle: AssistantWindowPresentationStyle
    @ObservedObject private var jobQueue = JobQueueCoordinator.shared

    @State private var isRefreshing = false
    @State private var toolCallsExpanded = false
    @State private var expandedActivityIDs: Set<String> = []
    @State private var pendingPermanentDeleteSession: AssistantSessionSummary?
    @State private var pendingDeleteNotesAssistantSession: AssistantSessionSummary?
    @State private var pendingDeleteProject: AssistantProject?
    @State private var showSessionInstructions = false
    @State private var showProviderPicker = false
    @State private var userHasScrolledUp = false
    @State private var autoScrollPinnedToBottom = true
    @State private var visibleHistoryLimit = Self.initialVisibleHistoryLimit
    @State private var chatViewportHeight: CGFloat = 0
    @State private var composerMeasuredHeight: CGFloat?
    @State private var notesAssistantComposerMeasuredHeight: CGFloat?
    @State private var isComposerQuickActionsMenuPresented = false
    @State private var isLoadingOlderHistory = false
    @State private var hoveredInlineCopyMessageID: String?
    @State private var inlineCopyHideWorkItem: DispatchWorkItem?
    @State private var previewAttachment: AssistantAttachment?
    @State private var expandedHistoricalActivityRenderItemIDs: Set<String> = []
    @State private var expandedHistoricalConversationBlockIDs: Set<String> = []
    @State private var chatScrollTracking = AssistantChatScrollTracking()
    @AppStorage("assistantSelectedSidebarPane") private var selectedSidebarPaneRawValue =
        AssistantSidebarPane.threads.shellID

    private var selectedSidebarPane: AssistantSidebarPane {
        get { AssistantSidebarPane(shellID: selectedSidebarPaneRawValue) ?? .threads }
        nonmutating set { selectedSidebarPaneRawValue = newValue.shellID }
    }
    @State private var lastNonSkillsSidebarPane: AssistantSidebarPane = .threads
    @State private var showSkillWizardSheet = false
    @State private var showGitHubSkillImportSheet = false
    @State private var pendingScrollToLatestWorkItem: DispatchWorkItem?
    @State private var suppressNextTimelineAutoScrollAnimation = true
    @State private var isLiveVoicePanelCollapsed = false
    @State private var isPreservingHistoryScrollPosition = false
    @State private var isProviderSelectorHovered = false
    @State private var hoveredProviderOptionID: String?
    @State private var isWorkspaceLaunchPrimaryHovered = false
    @State private var isWorkspaceLaunchChevronHovered = false
    @State private var hoveredWorkspaceLaunchTargetID: String?
    @State private var showWorkspaceLaunchMenu = false
    @State private var cachedVisibleRenderItems: [AssistantTimelineRenderItem] = []
    @State private var cachedChatWebMessages: [AssistantChatWebMessage] = []
    @State private var chatTimelineWebContainer: AssistantChatWebContainerView?
    @State private var threadNoteWebContainer: AssistantChatWebContainerView?
    @State private var isThreadNoteOpen = false
    @State private var isThreadNoteExpanded = false
    @State private var threadNoteViewMode = "edit"
    @State private var activeThreadNoteThreadID: String?
    @State private var selectedNoteOwnerByThreadID: [String: AssistantNoteOwnerKey] = [:]
    @State private var selectedNotesProjectID: String?
    @State private var selectedNotesScope: AssistantNotesScope = .project
    @AppStorage("assistantNotesAssistantOverlayOpen") private var isNotesAssistantPanelOpen = false
    @AppStorage("assistantNotesAssistantOverlayExpanded") private
        var isNotesAssistantPanelExpanded =
        false
    @AppStorage("assistantNotesAssistantSessionMap") private var notesAssistantSessionMapJSON = ""
    @State private var notesAssistantReturnSessionID: String?
    @State private var notesAssistantSessionTask: Task<Void, Never>?
    @State private var selectedNotesTargetByContextKey: [String: AssistantNoteLinkTarget] = [:]
    @State private var threadsDetailMode: AssistantThreadsDetailMode = .chat
    @State private var noteManifestByOwnerKey: [String: AssistantNoteManifest] = [:]
    @State private var noteDraftStore = AssistantThreadNoteDraftStore()
    @State private var noteLastSavedAtByOwnerKey: [String: [String: Date]] = [:]
    @State private var notesWorkspaceExternalMarkdownFile: AssistantExternalMarkdownFileState?
    @State private var isSavingExternalMarkdownFile = false
    @State private var threadNoteNavigationStackByContextKey:
        [String: [AssistantNoteNavigationEntry]] = [:]
    @State private var threadNoteSavingNoteKeys: Set<String> = []
    @State private var composerNoteContextDismissedKeys: Set<String> = []
    @State private var composerNoteContextIncludeContentKeys: Set<String> = []
    @State private var threadNoteAIDraftPreviewByOwnerKey:
        [String: AssistantChatWebThreadNoteAIPreview] = [:]
    @State private var threadNoteGeneratingAIDraftOwnerKeys: Set<String> = []
    @State private var threadNoteAIDraftModeByOwnerKey: [String: String] = [:]
    @State private var threadNoteAIDraftRequestIDByOwnerKey: [String: UUID] = [:]
    @State private var threadNoteChartContextByOwnerKey: [String: ThreadNoteChartContext] = [:]
    @State private var threadNoteProjectTransferPreviewByOwnerKey:
        [String: AssistantChatWebProjectNoteTransferPreview] = [:]
    @State private var threadNoteGeneratingProjectTransferOwnerKeys: Set<String> = []
    @State private var threadNoteProjectTransferRequestIDByOwnerKey: [String: UUID] = [:]
    @State private var threadNoteProjectTransferOutcomeByOwnerKey:
        [String: AssistantChatWebProjectNoteTransferOutcome] = [:]
    @State private var batchNotePlanPreviewByProjectID:
        [String: AssistantChatWebBatchNotePlanPreview] = [:]
    @State private var batchNotePlanGeneratingProjectIDs: Set<String> = []
    @State private var batchNotePlanRequestIDByProjectID: [String: UUID] = [:]
    @State private var projectNotesSidebarRestoreState: Bool?
    @State private var selectionAskConversationsByKey:
        [SelectionAskConversationSession.Key: SelectionAskConversationSession] = [:]
    @State private var historyBranchBannerPulse = false
    @State private var historyBranchBannerSettled = true
    @StateObject private var selectionTracker = AssistantTextSelectionTracker.shared
    @AppStorage("assistantSidebarVisibleSessionsLimit") private var sidebarVisibleSessionsLimit =
        Self.initialSidebarVisibleSessionsLimit
    @AppStorage("assistantChatHistoryDisplayMode") private var chatHistoryDisplayModeRawValue =
        AssistantChatHistoryDisplayMode.messagesFirst.rawValue

    init(
        assistant: AssistantStore,
        presentationStyle: AssistantWindowPresentationStyle = .window
    ) {
        self.assistant = assistant
        self.presentationStyle = presentationStyle
    }
    @AppStorage("assistantSidebarCollapsed") private var isSidebarCollapsed = false
    @AppStorage("assistantSidebarCustomWidth") private var sidebarCustomWidth: Double = 0
    @AppStorage("assistantCompactSidebarInnerWidth") private var compactSidebarInnerWidth: Double =
        0
    @State private var collapsedSidebarPreviewPane: String?
    @State private var sidebarDragStartWidth: CGFloat = 0
    /// Transient width used while the resize handle is being dragged.
    /// Kept as `@State` so we avoid writing to `@AppStorage` (UserDefaults)
    /// on every frame, which causes synchronous I/O and laggy resizing.
    /// The value is flushed to `@AppStorage` once on drag end.
    @State private var sidebarDragLiveWidth: CGFloat = 0
    @State private var isSidebarResizeHandleHovered = false
    @AppStorage("assistantSidebarProjectsExpanded") private var areProjectsExpanded = true
    @AppStorage("assistantSidebarExpandedFolderIDs") private var expandedFolderIDsRaw = ""
    @AppStorage("assistantSidebarExpandedNoteFolderIDs") private var expandedNoteFolderIDsRaw = ""
    @AppStorage("assistantSidebarThreadsExpanded") private var areThreadsExpanded = true
    @AppStorage("assistantSidebarArchivedExpanded") private var areArchivedExpanded = true
    @AppStorage("assistantSidebarNotesExpanded") private var areNotesExpanded = true
    @AppStorage("assistantChatTextScale") private var chatTextScale: Double = 1.0
    @AppStorage("assistantPreferredWorkspaceLaunchTargetID") private
        var preferredWorkspaceLaunchTargetID = ""

    /// Uses the pre-computed render items from AssistantStore (rebuilt only when
    /// timelineItems changes, not on every @Published update).
    private var allRenderItems: [AssistantTimelineRenderItem] {
        assistant.cachedRenderItems
    }

    private var visibleRenderItems: [AssistantTimelineRenderItem] {
        cachedVisibleRenderItems
    }

    private var chatHistoryDisplayMode: AssistantChatHistoryDisplayMode {
        AssistantChatHistoryDisplayMode(rawValue: chatHistoryDisplayModeRawValue) ?? .messagesFirst
    }

    private func recomputeVisibleRenderItems() {
        cachedVisibleRenderItems = assistantTimelineVisibleWindow(
            from: allRenderItems,
            visibleLimit: visibleHistoryLimit,
            minimumVisibleChatMessages: Self.minimumVisibleChatMessagesBeforeLoadMore
        )
        cachedChatWebMessages = computeChatWebMessages()
    }

    private var chatWebMessages: [AssistantChatWebMessage] {
        cachedChatWebMessages
    }

    private func computeChatWebMessages() -> [AssistantChatWebMessage] {
        let _ = assistant.historyActionsRevision
        let sessionActivity = selectedSessionActivitySnapshot
        let messagesFirstMode = chatHistoryDisplayMode == .messagesFirst
        let preferLiveActivityCard =
            messagesFirstMode
            && chatWebActiveWorkState != nil
            && (sessionActivity.hasActiveTurn || sessionActivity.awaitingAssistantStart)
        let renderItems =
            messagesFirstMode
            ? assistantMessagesFirstVisibleRenderItems(
                from: visibleRenderItems,
                pendingPermissionSessionID: assistant.pendingPermissionRequest?.sessionID,
                preferLiveActivityCard: preferLiveActivityCard
            )
            : visibleRenderItems
        let historyActions = assistant.historyActionMetadata(for: renderItems)
        let renderContext = AssistantChatWebRenderContext(
            pendingPermissionRequest: assistant.pendingPermissionRequest,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID,
            hasActiveTurn: assistant.hasActiveTurn,
            sessionStatusByNormalizedID: sessionStatusByNormalizedID,
            sessionWorkingDirectoryByNormalizedID: sessionWorkingDirectoryByNormalizedID
        )
        let canCollapseHistoricalTurnSummaries =
            !messagesFirstMode
            && assistantCanCollapseHistoricalTurnSummaries(
                hasActiveTurn: assistant.hasActiveTurn,
                activeWorkSnapshot: selectedSessionActiveWorkSnapshot
            )
        let collapsedConversationGroups =
            canCollapseHistoricalTurnSummaries
            ? collapsedHistoricalConversationGroups(in: renderItems)
            : []
        let collapsedConversationGroupByFirstHiddenIndex = Dictionary(
            uniqueKeysWithValues: collapsedConversationGroups.map { ($0.firstHiddenIndex, $0) }
        )
        let collapsedConversationGroupByHiddenIndex = Dictionary(
            uniqueKeysWithValues: collapsedConversationGroups.flatMap { group in
                group.hiddenIndices.map { ($0, group) }
            }
        )
        var messages: [AssistantChatWebMessage] = []

        for (index, renderItem) in renderItems.enumerated() {
            let expandedConversationGroup = collapsedConversationGroupByHiddenIndex[index].flatMap {
                expandedHistoricalConversationBlockIDs.contains($0.id) ? $0 : nil
            }

            if let group = collapsedConversationGroupByFirstHiddenIndex[index],
                let summary = AssistantChatWebMessage.collapsedConversationSummary(
                    hiddenRenderItems: group.hiddenRenderItems,
                    terminalRenderItem: group.terminalRenderItem,
                    blockID: group.id,
                    expanded: expandedHistoricalConversationBlockIDs.contains(group.id)
                )
            {
                messages.append(summary)
                if !expandedHistoricalConversationBlockIDs.contains(group.id) {
                    continue
                }
            } else if let group = collapsedConversationGroupByHiddenIndex[index],
                !expandedHistoricalConversationBlockIDs.contains(group.id)
            {
                continue
            }

            if expandedConversationGroup == nil,
                canCollapseHistoricalTurnSummaries,
                shouldCollapseHistoricalActivityRenderItem(
                    renderItem,
                    at: index,
                    in: renderItems
                ),
                let summary = AssistantChatWebMessage.collapsedActivitySummary(
                    renderItem: renderItem
                )
            {
                messages.append(summary)
                continue
            }

            if expandedHistoricalActivityRenderItemIDs.contains(renderItem.id),
                let summary = AssistantChatWebMessage.expandedActivitySummary(
                    renderItem: renderItem
                )
            {
                messages.append(summary)
            }

            messages.append(
                contentsOf: AssistantChatWebMessage.from(
                    renderItem: renderItem,
                    historyActions: historyActions,
                    renderContext: renderContext
                )
            )
        }

        if let pendingMessage = sessionActivity.pendingOutgoingMessage {
            messages.append(pendingOutgoingChatWebMessage(from: pendingMessage))
        }

        return messages
    }

    private func pendingOutgoingChatWebMessage(
        from pendingMessage: AssistantPendingOutgoingMessage
    ) -> AssistantChatWebMessage {
        AssistantChatWebMessage(
            id: "pending-user-\(Int(pendingMessage.createdAt.timeIntervalSince1970 * 1000))",
            type: "user",
            text: pendingMessage.text,
            isStreaming: false,
            timestamp: pendingMessage.createdAt,
            turnID: nil,
            images: AssistantChatWebInlineImage.payloads(from: pendingMessage.imageAttachments),
            emphasis: false,
            canUndo: false,
            canEdit: false,
            rewriteAnchorID: nil,
            providerLabel: nil,
            selectedPlugins: nil,
            activityIcon: nil,
            activityTitle: nil,
            activityDetail: nil,
            activityStatus: nil,
            activityStatusLabel: nil,
            detailSections: nil,
            activityTargets: nil,
            groupItems: nil,
            loadActivityDetailsID: nil,
            collapseActivityDetailsID: nil
        )
    }

    private var chatWebRewindState: AssistantChatWebRewindState? {
        guard let branch = assistant.historyBranchState,
            assistant.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                == branch.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else {
            return nil
        }

        let redoHostMessageID = chatWebMessages.reversed().first(where: {
            $0.type == "assistant"
        })?.id

        return AssistantChatWebRewindState(
            kind: branch.kind.rawValue,
            canStepBackward: assistant.canStepHistoryBranchBackward,
            redoHostMessageID: redoHostMessageID
        )
    }

    private var selectedThreadNoteID: String? {
        assistant.selectedSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .lowercased()
    }

    private func sessionSummary(forThreadID threadID: String?) -> AssistantSessionSummary? {
        guard let threadID else { return nil }
        return assistant.sessions.first(where: {
            assistantTimelineSessionIDsMatch($0.id, threadID)
        })
    }

    private func projectForThreadNotes(threadID: String?) -> AssistantProject? {
        guard
            let projectID = sessionSummary(forThreadID: threadID)?.projectID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        else {
            return nil
        }
        return assistant.projects.first(where: {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(projectID) == .orderedSame
        })
    }

    private var currentProjectNotesProject: AssistantProject? {
        guard case .projectNotes(let projectID) = threadsDetailMode else {
            return nil
        }
        guard
            let project = assistant.visibleLeafProjects.first(where: {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(projectID) == .orderedSame
            })
        else {
            return nil
        }
        return project
    }

    private var selectedNotesProject: AssistantProject? {
        let normalizedSelection = selectedNotesProjectID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let fallbackProjectID = assistant.selectedProject?.id
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let candidateIDs = [normalizedSelection, fallbackProjectID].compactMap { $0 }

        for candidateID in candidateIDs {
            if let match = assistant.visibleLeafProjects.first(where: {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(candidateID) == .orderedSame
            }) {
                return match
            }
        }

        return assistant.visibleLeafProjects.first
    }

    private var notesAssistantSessionRegistriesByProjectID:
        [String: AssistantNotesProjectSessionRegistry]
    {
        get {
            assistantDecodeNotesAssistantSessionRegistries(from: notesAssistantSessionMapJSON)
        }
        nonmutating set {
            guard let encoded = assistantEncodeNotesAssistantSessionRegistries(newValue) else {
                notesAssistantSessionMapJSON = ""
                return
            }
            notesAssistantSessionMapJSON = encoded
        }
    }

    private var hiddenNotesAssistantSessionIDs: Set<String> {
        Set(
            notesAssistantSessionRegistriesByProjectID.values
                .flatMap(\.sessionIDs)
                .compactMap { assistantNormalizedNotesSessionID($0)?.lowercased() }
        )
    }

    private func notesAssistantSessionRegistry(for projectID: String?)
        -> AssistantNotesProjectSessionRegistry?
    {
        guard let normalizedProjectID = assistantNormalizedNotesProjectID(projectID) else {
            return nil
        }
        return notesAssistantSessionRegistriesByProjectID[normalizedProjectID]
    }

    private func notesAssistantAllSessionSummaries(
        for project: AssistantProject
    ) -> [AssistantSessionSummary] {
        guard let registry = notesAssistantSessionRegistry(for: project.id) else { return [] }

        return registry.sessionIDs.compactMap { sessionID in
            assistant.sessions.first(where: {
                assistantTimelineSessionIDsMatch($0.id, sessionID)
            })
        }
        .sorted {
            assistantNotesSessionRecencyDate($0) > assistantNotesSessionRecencyDate($1)
        }
    }

    private func notesAssistantSessionSummaries(
        for project: AssistantProject
    ) -> [AssistantSessionSummary] {
        notesAssistantAllSessionSummaries(for: project).filter { !$0.isArchived }
    }

    private func archivedNotesAssistantSessionSummaries(
        for project: AssistantProject
    ) -> [AssistantSessionSummary] {
        notesAssistantAllSessionSummaries(for: project).filter(\.isArchived)
    }

    private func notesAssistantResolvedSessionID(for project: AssistantProject) -> String? {
        assistantResolvedNotesAssistantSessionID(
            projectID: project.id,
            registries: notesAssistantSessionRegistriesByProjectID,
            sessions: assistant.sessions
        )
    }

    private func setNotesAssistantSessionRegistry(
        _ registry: AssistantNotesProjectSessionRegistry,
        for projectID: String
    ) {
        guard let normalizedProjectID = assistantNormalizedNotesProjectID(projectID) else { return }

        var mappings = notesAssistantSessionRegistriesByProjectID
        if registry.isEmpty {
            mappings.removeValue(forKey: normalizedProjectID)
        } else {
            mappings[normalizedProjectID] = AssistantNotesProjectSessionRegistry(
                sessionIDs: registry.sessionIDs,
                lastUsedSessionID: registry.lastUsedSessionID
            )
        }
        notesAssistantSessionRegistriesByProjectID = mappings
    }

    private func rememberNotesAssistantSessionID(
        _ sessionID: String,
        for projectID: String,
        makeLastUsed: Bool = true
    ) {
        guard let normalizedSessionID = assistantNormalizedNotesSessionID(sessionID),
            let normalizedProjectID = assistantNormalizedNotesProjectID(projectID)
        else {
            return
        }

        var registry =
            notesAssistantSessionRegistriesByProjectID[normalizedProjectID]
            ?? AssistantNotesProjectSessionRegistry()

        if !registry.sessionIDs.contains(where: {
            assistantTimelineSessionIDsMatch($0, normalizedSessionID)
        }) {
            registry.sessionIDs.append(normalizedSessionID)
        }
        if makeLastUsed {
            registry.lastUsedSessionID = normalizedSessionID
        }

        setNotesAssistantSessionRegistry(registry, for: normalizedProjectID)
    }

    private func pruneNotesAssistantSessionRegistry(
        for project: AssistantProject
    ) {
        guard var registry = notesAssistantSessionRegistry(for: project.id) else { return }

        registry = AssistantNotesProjectSessionRegistry(
            sessionIDs: registry.sessionIDs.filter { registeredSessionID in
                assistant.sessions.contains(where: {
                    assistantTimelineSessionIDsMatch($0.id, registeredSessionID)
                })
            },
            lastUsedSessionID: registry.lastUsedSessionID
        )

        setNotesAssistantSessionRegistry(registry, for: project.id)
    }

    private func forgetNotesAssistantSessionID(
        _ sessionID: String,
        for projectID: String
    ) {
        guard let normalizedSessionID = assistantNormalizedNotesSessionID(sessionID),
            var registry = notesAssistantSessionRegistry(for: projectID)
        else {
            return
        }

        registry.sessionIDs.removeAll(where: {
            assistantTimelineSessionIDsMatch($0, normalizedSessionID)
        })
        if assistantTimelineSessionIDsMatch(registry.lastUsedSessionID, normalizedSessionID) {
            registry.lastUsedSessionID = nil
        }

        setNotesAssistantSessionRegistry(registry, for: projectID)
    }

    private func notesAssistantSessionID(for projectID: String?) -> String? {
        guard let normalizedProjectID = assistantNormalizedNotesProjectID(projectID) else {
            return nil
        }

        if let selectedNotesProject,
            assistantNormalizedNotesProjectID(selectedNotesProject.id) == normalizedProjectID
        {
            return notesAssistantResolvedSessionID(for: selectedNotesProject)
        }

        return assistantResolvedNotesAssistantSessionID(
            projectID: normalizedProjectID,
            registries: notesAssistantSessionRegistriesByProjectID,
            sessions: assistant.sessions
        )
    }

    private func notesAssistantSessionTitle(
        for project: AssistantProject,
        existingRegistry: AssistantNotesProjectSessionRegistry
    ) -> String {
        assistantNotesAssistantSessionTitle(
            projectName: project.name,
            existingRegistry: existingRegistry,
            createdAt: Date()
        )
    }

    private func notesAssistantSessionDisplayTitle(
        for session: AssistantSessionSummary,
        project: AssistantProject
    ) -> String {
        session.title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? assistantNotesAssistantSessionTitle(
                projectName: project.name,
                existingRegistry: AssistantNotesProjectSessionRegistry(),
                createdAt: assistantNotesSessionRecencyDate(session)
            )
    }

    private func notesAssistantSessionSwitcherLabel(
        for session: AssistantSessionSummary?,
        project: AssistantProject
    ) -> String {
        guard let session else { return "Chats" }
        guard let registry = notesAssistantSessionRegistry(for: project.id) else {
            return "Chats"
        }

        if let primarySessionID = registry.sessionIDs.first,
            assistantTimelineSessionIDsMatch(primarySessionID, session.id)
        {
            return "Main chat"
        }

        if let timestamp = session.updatedAt ?? session.createdAt {
            return timestamp.formatted(date: .abbreviated, time: .shortened)
        }

        return "Chat"
    }

    @MainActor
    private func archiveNotesAssistantSession(
        _ session: AssistantSessionSummary,
        in project: AssistantProject
    ) async {
        await assistant.archiveSession(
            session.id,
            retentionHours: settings.assistantArchiveDefaultRetentionHours,
            updateDefaultRetention: false
        )
        pruneNotesAssistantSessionRegistry(for: project)

        if assistantTimelineSessionIDsMatch(assistant.selectedSessionID, session.id) {
            await activateNotesAssistantSession(for: project)
        }
    }

    @MainActor
    private func unarchiveNotesAssistantSession(
        _ session: AssistantSessionSummary,
        in project: AssistantProject
    ) async {
        await assistant.unarchiveSession(session.id)
        rememberNotesAssistantSessionID(session.id, for: project.id, makeLastUsed: true)
        await activateNotesAssistantSession(for: project, preferredSessionID: session.id)
    }

    @MainActor
    private func deleteNotesAssistantSession(
        _ session: AssistantSessionSummary,
        in project: AssistantProject
    ) async {
        await assistant.deleteSession(session.id)
        forgetNotesAssistantSessionID(session.id, for: project.id)
        pruneNotesAssistantSessionRegistry(for: project)
        await activateNotesAssistantSession(for: project)
    }

    private func setNotesAssistantSessionID(_ sessionID: String, for projectID: String) {
        let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedProjectID.isEmpty else { return }

        rememberNotesAssistantSessionID(sessionID, for: normalizedProjectID, makeLastUsed: true)
    }

    private func isNotesAssistantSession(_ sessionID: String?) -> Bool {
        guard
            let normalizedSessionID = sessionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty?
                .lowercased()
        else {
            return false
        }

        return hiddenNotesAssistantSessionIDs.contains(normalizedSessionID)
    }

    private func notesAssistantSessionTitle(for project: AssistantProject) -> String {
        "Notes Assistant · \(project.name)"
    }

    private var isNotesPaneActive: Bool {
        selectedSidebarPane == .notes
    }

    private var isProjectNotesFocusMode: Bool {
        selectedSidebarPane == .threads && currentProjectNotesProject != nil
    }

    private var projectNotesChromeState: AssistantProjectNotesChromeState {
        AssistantProjectNotesChromeState(
            isFocusModeActive: isProjectNotesFocusMode,
            persistedSidebarCollapsed: isSidebarCollapsed
        )
    }

    private func notesSelectionContextKey(
        projectID: String,
        scope: AssistantNotesScope
    ) -> String {
        let normalizedProjectID =
            projectID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(normalizedProjectID)::\(scope.rawValue)"
    }

    private func rememberNotesSelectionTarget(
        _ target: AssistantNoteLinkTarget?,
        projectID: String,
        scope: AssistantNotesScope
    ) {
        let key = notesSelectionContextKey(projectID: projectID, scope: scope)
        if let target {
            selectedNotesTargetByContextKey[key] = target
        } else {
            selectedNotesTargetByContextKey.removeValue(forKey: key)
        }
    }

    private func assistantProject(for projectID: String?) -> AssistantProject? {
        guard let projectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        else {
            return nil
        }
        return assistant.projects.first(where: {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(projectID) == .orderedSame
        })
    }

    private func notesProject(for owner: AssistantNoteOwnerKey) -> AssistantProject? {
        switch owner.kind {
        case .project:
            return assistantProject(for: owner.id)
        case .thread:
            return projectForThreadNotes(threadID: owner.id)
        }
    }

    private func notesUniverse(for project: AssistantProject) -> AssistantNotesUniverse {
        let projectOwner = AssistantNoteOwnerKey(kind: .project, id: project.id)
        let projectFolders = assistant.projectNoteFolders(projectID: project.id)
        let projectFolderPathByID = assistant.projectNoteFolderPathMap(projectID: project.id)
        let projectNotes = loadStoredNotes(for: projectOwner)
            .sorted { $0.updatedAt > $1.updatedAt }

        let threadSources = assistant.sessions
            .filter { session in
                session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(project.id) == .orderedSame
            }
            .map { session -> AssistantNotesUniverseThreadSource in
                let owner = AssistantNoteOwnerKey(kind: .thread, id: session.id)
                let notes = loadStoredNotes(for: owner)
                    .sorted { $0.updatedAt > $1.updatedAt }
                return AssistantNotesUniverseThreadSource(
                    session: session,
                    owner: owner,
                    notes: notes
                )
            }

        return AssistantNotesUniverse(
            project: project,
            projectOwner: projectOwner,
            projectNotes: projectNotes,
            projectFolders: projectFolders,
            projectFolderPathByID: projectFolderPathByID,
            threadSources: threadSources
        )
    }

    private func sidebarNoteRows(
        for project: AssistantProject,
        scope: AssistantNotesScope
    ) -> [AssistantSidebarNoteRowModel] {
        let universe = notesUniverse(for: project)

        switch scope {
        case .project:
            return universe.projectNotes.map { note in
                let updatedLabel = threadNoteSavedLabel(for: note.updatedAt) ?? "Saved recently"
                return AssistantSidebarNoteRowModel(
                    target: note.target,
                    title: note.title,
                    subtitle: updatedLabel,
                    sourceLabel: "Project notes",
                    updatedAt: note.updatedAt,
                    folderID: note.folderID,
                    folderPath: note.folderID.flatMap { universe.projectFolderPathByID[$0] } ?? [],
                    isArchivedThread: false,
                    threadID: nil
                )
            }

        case .thread:
            return universe.threadSources.flatMap { source in
                let sessionTitle =
                    source.session.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty ?? "Thread"
                return source.notes.map { note in
                    let updatedLabel = threadNoteSavedLabel(for: note.updatedAt) ?? "Saved recently"
                    let archivedLabel = source.session.isArchived ? " · Archived" : ""
                    return AssistantSidebarNoteRowModel(
                        target: note.target,
                        title: note.title,
                        subtitle: "\(sessionTitle)\(archivedLabel) · \(updatedLabel)",
                        sourceLabel: "Thread notes",
                        updatedAt: note.updatedAt,
                        folderID: nil,
                        folderPath: [],
                        isArchivedThread: source.session.isArchived,
                        threadID: source.session.id
                    )
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private func sidebarNoteFolderRows(
        for project: AssistantProject,
        scope: AssistantNotesScope
    ) -> [AssistantSidebarNoteFolderRowModel] {
        guard scope == .project else { return [] }
        let universe = notesUniverse(for: project)
        let expandedFolderIDs = storedExpandedNoteFolderIDs
        let childFolderCountByParentID = Dictionary(
            universe.projectFolders.map { ($0.parentFolderID?.lowercased() ?? "", 1) },
            uniquingKeysWith: +
        )
        let noteCountByFolderID = universe.projectNotes.reduce(into: [String: Int]()) {
            result, note in
            guard let folderID = note.folderID?.lowercased() else { return }
            result[folderID, default: 0] += 1
        }
        return universe.projectFolders.map { folder in
            AssistantSidebarNoteFolderRowModel(
                id: folder.id,
                name: folder.name,
                parentFolderID: folder.parentFolderID,
                path: universe.projectFolderPathByID[folder.id] ?? [folder.name],
                isExpanded: expandedFolderIDs.contains(folder.id.lowercased()),
                childFolderCount: childFolderCountByParentID[folder.id.lowercased(), default: 0],
                noteCount: noteCountByFolderID[folder.id.lowercased(), default: 0]
            )
        }
    }

    private func noteFolderDescendantIDs(
        folderID: String,
        folders: [AssistantNoteFolderSummary]
    ) -> Set<String> {
        let rootFolderID = folderID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !rootFolderID.isEmpty else { return [] }
        let childrenByParentID = Dictionary(grouping: folders) { folder in
            folder.parentFolderID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ?? ""
        }
        var descendants: Set<String> = []
        var stack = childrenByParentID[rootFolderID, default: []]
        while let folder = stack.popLast() {
            let folderKey = folder.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard descendants.insert(folderKey).inserted else { continue }
            stack.append(contentsOf: childrenByParentID[folderKey, default: []])
        }
        return descendants
    }

    private func currentNotesSelectionTarget(
        project: AssistantProject,
        scope: AssistantNotesScope
    ) -> AssistantNoteLinkTarget? {
        let rows = sidebarNoteRows(for: project, scope: scope)
        let key = notesSelectionContextKey(projectID: project.id, scope: scope)
        if let storedTarget = selectedNotesTargetByContextKey[key],
            rows.contains(where: { $0.target == storedTarget })
        {
            return storedTarget
        }
        return rows.first?.target
    }

    private func availableNoteOwners(for threadID: String?) -> [AssistantNoteOwnerKey] {
        if let project = currentProjectNotesProject {
            return [.init(kind: .project, id: project.id)]
        }

        guard let threadID else { return [] }
        var owners: [AssistantNoteOwnerKey] = [
            .init(kind: .thread, id: threadID)
        ]
        if let project = projectForThreadNotes(threadID: threadID) {
            owners.append(.init(kind: .project, id: project.id))

            let siblingThreadOwners = notesUniverse(for: project).threadSources.compactMap {
                source -> AssistantNoteOwnerKey? in
                guard !assistantTimelineSessionIDsMatch(source.owner.id, threadID),
                    !source.notes.isEmpty
                else {
                    return nil
                }
                return source.owner
            }
            owners.append(contentsOf: siblingThreadOwners)
        }
        return owners
    }

    private var currentThreadNoteOwner: AssistantNoteOwnerKey? {
        if isNotesPaneActive,
            let project = selectedNotesProject,
            let currentTarget = currentNotesSelectionTarget(
                project: project, scope: selectedNotesScope)
        {
            return .init(kind: currentTarget.ownerKind, id: currentTarget.ownerID)
        }

        if isNotesPaneActive,
            selectedNotesScope == .project,
            let project = selectedNotesProject
        {
            return .init(kind: .project, id: project.id)
        }

        if let project = currentProjectNotesProject {
            return .init(kind: .project, id: project.id)
        }

        guard let threadID = selectedThreadNoteID else { return nil }
        let availableOwners = availableNoteOwners(for: threadID)
        if let selectedOwner = selectedNoteOwnerByThreadID[threadID],
            availableOwners.contains(selectedOwner)
        {
            return selectedOwner
        }
        return availableOwners.first
    }

    private func noteOwnerTitle(for owner: AssistantNoteOwnerKey) -> String {
        switch owner.kind {
        case .thread:
            return sessionSummary(forThreadID: owner.id)?.title ?? activeSessionTitle
        case .project:
            return assistant.projects.first(where: {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(owner.id) == .orderedSame
            })?.name ?? "Project"
        }
    }

    private func notePlaceholder(for owner: AssistantNoteOwnerKey?) -> String {
        switch owner?.kind {
        case .project:
            return
                "Write shared decisions, constraints, architecture notes, and next steps for this project. Type / for Markdown blocks."
        case .thread, .none:
            return
                "Write decisions, next steps, constraints, and follow-ups for this thread. Type / for Markdown blocks."
        }
    }

    private func noteNavigationContextKey(for threadID: String?) -> String? {
        if isNotesPaneActive,
            let project = selectedNotesProject
        {
            return
                "notes::\(project.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }

        if let project = currentProjectNotesProject {
            return
                "project::\(project.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }

        guard
            let normalizedThreadID = threadID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty?
                .lowercased()
        else {
            return nil
        }
        return "thread::\(normalizedThreadID)"
    }

    private func clearThreadNoteNavigationStack(for threadID: String?) {
        guard let contextKey = noteNavigationContextKey(for: threadID) else {
            return
        }
        threadNoteNavigationStackByContextKey[contextKey] = []
    }

    private func currentThreadNoteNavigationStack() -> [AssistantNoteNavigationEntry] {
        guard let contextKey = noteNavigationContextKey(for: selectedThreadNoteID) else {
            return []
        }
        return threadNoteNavigationStackByContextKey[contextKey] ?? []
    }

    private func pushCurrentNoteOntoNavigationStack(for threadID: String?) {
        guard let contextKey = noteNavigationContextKey(for: threadID),
            let currentTarget = currentDisplayedNoteTarget,
            let owner = currentThreadNoteOwner,
            let title = currentDisplayedNoteTitle
        else {
            return
        }

        let entry = AssistantNoteNavigationEntry(
            owner: owner,
            noteID: currentTarget.noteID,
            title: title
        )
        var stack = threadNoteNavigationStackByContextKey[contextKey] ?? []
        if stack.last == entry {
            return
        }
        stack.append(entry)
        threadNoteNavigationStackByContextKey[contextKey] = stack
    }

    private func popThreadNoteNavigationEntry(for threadID: String?)
        -> AssistantNoteNavigationEntry?
    {
        guard let contextKey = noteNavigationContextKey(for: threadID) else {
            return nil
        }

        var stack = threadNoteNavigationStackByContextKey[contextKey] ?? []
        guard let entry = stack.popLast() else {
            return nil
        }
        threadNoteNavigationStackByContextKey[contextKey] = stack
        return entry
    }

    private func removeNoteFromNavigationStacks(owner: AssistantNoteOwnerKey, noteID: String) {
        for (contextKey, stack) in threadNoteNavigationStackByContextKey {
            let filtered = stack.filter { entry in
                !(entry.owner == owner && entry.noteID == noteID)
            }
            if filtered.count != stack.count {
                threadNoteNavigationStackByContextKey[contextKey] = filtered
            }
        }
    }

    private func loadStoredNotes(for owner: AssistantNoteOwnerKey) -> [AssistantStoredNote] {
        switch owner.kind {
        case .thread:
            return assistant.loadThreadStoredNotes(threadID: owner.id)
        case .project:
            return assistant.loadProjectStoredNotes(projectID: owner.id)
        }
    }

    private func sourceLabel(for ownerKind: AssistantNoteOwnerKind, ownerID: String) -> String {
        AssistantNoteOwnerKey(kind: ownerKind, id: ownerID).displaySourceLabel
    }

    private func currentThreadNoteRelationshipSnapshot() -> AssistantNoteRelationshipSnapshot {
        guard let currentTarget = currentDisplayedNoteTarget else {
            return .empty
        }

        let storedNotes: [AssistantStoredNote]
        if isNotesPaneActive,
            let project = selectedNotesProject
        {
            storedNotes = notesUniverse(for: project).allNotes
        } else {
            let availableOwners = availableNoteOwners(for: selectedThreadNoteID)
            storedNotes = availableOwners.flatMap(loadStoredNotes(for:))
        }

        return AssistantNoteRelationshipBuilder.buildSnapshot(
            currentTarget: currentTarget,
            notes: storedNotes,
            sourceLabelForOwner: sourceLabel(for:ownerID:)
        )
    }

    private func chatWebRelationshipItems(
        from items: [AssistantNoteRelationshipItem]
    ) -> [AssistantChatWebThreadNoteRelationshipItem] {
        items.map { item in
            AssistantChatWebThreadNoteRelationshipItem(
                ownerKind: item.target.ownerKind.rawValue,
                ownerID: item.target.ownerID,
                noteID: item.target.noteID,
                title: item.title,
                sourceLabel: item.sourceLabel,
                isMissing: item.isMissing,
                occurrenceCount: item.occurrenceCount
            )
        }
    }

    private func chatWebHistoryItems(
        for owner: AssistantNoteOwnerKey?,
        noteID: String?
    ) -> [AssistantChatWebThreadNoteHistoryItem] {
        guard let owner,
            let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        else {
            return []
        }

        let versions: [AssistantNoteHistoryVersion]
        switch owner.kind {
        case .thread:
            versions = assistant.threadNoteHistoryVersions(threadID: owner.id, noteID: noteID)
        case .project:
            versions = assistant.projectNoteHistoryVersions(projectID: owner.id, noteID: noteID)
        }

        return versions.map {
            AssistantChatWebThreadNoteHistoryItem(
                id: $0.id,
                title: $0.title,
                savedAtLabel: threadNoteSavedLabel(for: $0.savedAt) ?? "Saved recently",
                preview: $0.preview,
                markdown: $0.markdown
            )
        }
    }

    private func chatWebDeletedNoteItems(
        for owner: AssistantNoteOwnerKey?
    ) -> [AssistantChatWebThreadDeletedNoteItem] {
        guard let owner else { return [] }

        let deletedNotes: [AssistantDeletedNoteSnapshot]
        switch owner.kind {
        case .thread:
            deletedNotes = assistant.recentlyDeletedThreadNotes(threadID: owner.id)
        case .project:
            deletedNotes = assistant.recentlyDeletedProjectNotes(projectID: owner.id)
        }

        return deletedNotes.map {
            AssistantChatWebThreadDeletedNoteItem(
                id: $0.id,
                title: $0.title,
                deletedAtLabel: threadNoteSavedLabel(for: $0.deletedAt)?
                    .replacingOccurrences(of: "Saved", with: "Deleted")
                    ?? "Deleted recently",
                preview: $0.preview,
                markdown: $0.markdown
            )
        }
    }

    private func loadNotesWorkspace(for owner: AssistantNoteOwnerKey) -> AssistantNotesWorkspace? {
        switch owner.kind {
        case .thread:
            return assistant.loadThreadNotesWorkspace(threadID: owner.id)
        case .project:
            return assistant.loadProjectNotesWorkspace(projectID: owner.id)
        }
    }

    private func noteManifest(for owner: AssistantNoteOwnerKey) -> AssistantNoteManifest {
        if let manifest = noteManifestByOwnerKey[owner.storageKey] {
            return manifest
        }
        return loadNotesWorkspace(for: owner)?.manifest ?? AssistantNoteManifest()
    }

    private func noteMarkdownForDisplay(
        owner: AssistantNoteOwnerKey,
        noteID: String,
        text: String
    ) -> String {
        AssistantNoteAssetSupport.rewriteMarkdownForDisplay(
            text,
            ownerKind: owner.kind,
            ownerID: owner.id,
            noteID: noteID
        )
    }

    private func noteMarkdownForPersistence(
        owner: AssistantNoteOwnerKey,
        noteID: String,
        text: String
    ) -> String {
        AssistantNoteAssetSupport.rewriteMarkdownForPersistence(
            text,
            ownerKind: owner.kind,
            ownerID: owner.id,
            noteID: noteID
        )
    }

    private func resolveNoteAssetFileURL(
        owner: AssistantNoteOwnerKey,
        noteID: String,
        relativePath: String
    ) -> URL? {
        switch owner.kind {
        case .thread:
            return assistant.resolveThreadNoteImageAssetURL(
                threadID: owner.id,
                noteID: noteID,
                relativePath: relativePath
            )
        case .project:
            return assistant.resolveProjectNoteImageAssetURL(
                projectID: owner.id,
                noteID: noteID,
                relativePath: relativePath
            )
        }
    }

    private func resolveWebNoteAssetURL(
        _ reference: AssistantResolvedNoteAssetReference
    ) -> URL? {
        resolveNoteAssetFileURL(
            owner: AssistantNoteOwnerKey(kind: reference.ownerKind, id: reference.ownerID),
            noteID: reference.noteID,
            relativePath: reference.relativePath
        )
    }

    private func noteDraftText(for owner: AssistantNoteOwnerKey, noteID: String) -> String {
        if let draft = noteDraftStore.draft(ownerKey: owner.storageKey, noteID: noteID) {
            return draft
        }

        if let workspace = loadNotesWorkspace(for: owner),
            workspace.manifest.selectedNote?.id == noteID
        {
            return noteMarkdownForDisplay(
                owner: owner, noteID: noteID, text: workspace.selectedNoteText)
        }

        return loadStoredNotes(for: owner)
            .first(where: { $0.noteID.caseInsensitiveCompare(noteID) == .orderedSame })
            .map { noteMarkdownForDisplay(owner: owner, noteID: noteID, text: $0.text) } ?? ""
    }

    private func externalMarkdownSourceDescriptor(
        for file: AssistantExternalMarkdownFileState?
    ) -> AssistantChatWebThreadNoteSourceDescriptor? {
        guard let file else { return nil }
        return AssistantChatWebThreadNoteSourceDescriptor(
            sourceKind: "externalMarkdownFile",
            filePath: file.filePath,
            fileName: file.fileName,
            isDirty: file.isDirty,
            canSave: file.canSave
        )
    }

    private func presentOpenMarkdownFilePanel() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Markdown file to open in Notes mode."
        panel.prompt = "Open Markdown File"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText,
        ]

        if let workspaceURL = currentWorkspaceURL {
            let directoryURL =
                FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: nil)
                ? (workspaceURL.hasDirectoryPath
                    ? workspaceURL
                    : workspaceURL.deletingLastPathComponent())
                : workspaceURL.deletingLastPathComponent()
            panel.directoryURL = directoryURL
        }

        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        confirmExternalMarkdownDiscardIfNeeded {
            openExternalMarkdownFile(at: fileURL)
        }
    }

    private func openExternalMarkdownFile(at fileURL: URL) {
        do {
            notesWorkspaceExternalMarkdownFile = try AssistantExternalMarkdownFileState.load(
                from: fileURL)
            isSavingExternalMarkdownFile = false
        } catch {
            let message =
                (error as? LocalizedError)?.errorDescription
                ?? "Open Assist could not open that Markdown file."
            assistant.lastStatusMessage = message
        }
    }

    private func updateExternalMarkdownDraft(_ text: String) {
        guard let current = notesWorkspaceExternalMarkdownFile else { return }
        notesWorkspaceExternalMarkdownFile = current.updatingDraft(text)
    }

    private func saveExternalMarkdownFile(
        requestID: String?,
        draftRevision: Int? = nil,
        text: String?,
        sourceContainer: AssistantChatWebContainerView?
    ) {
        guard var current = notesWorkspaceExternalMarkdownFile else {
            if let requestID {
                sendThreadNoteSaveAck(
                    AssistantChatWebThreadNoteSaveAck(
                        requestID: requestID,
                        ownerKind: nil,
                        ownerID: nil,
                        noteID: nil,
                        draftRevision: draftRevision,
                        status: "error",
                        errorMessage: "Open Assist could not find the open Markdown file."
                    ),
                    sourceContainer: sourceContainer
                )
            }
            return
        }

        if let text {
            current = current.updatingDraft(text)
        }

        isSavingExternalMarkdownFile = true
        do {
            let saved = try current.saving()
            notesWorkspaceExternalMarkdownFile = saved
            if let requestID {
                sendThreadNoteSaveAck(
                    AssistantChatWebThreadNoteSaveAck(
                        requestID: requestID,
                        ownerKind: nil,
                        ownerID: nil,
                        noteID: nil,
                        draftRevision: draftRevision,
                        status: "ok",
                        errorMessage: nil
                    ),
                    sourceContainer: sourceContainer
                )
            }
        } catch {
            notesWorkspaceExternalMarkdownFile = current
            let message =
                (error as? LocalizedError)?.errorDescription
                ?? "Open Assist could not save that Markdown file."
            assistant.lastStatusMessage = message
            if let requestID {
                sendThreadNoteSaveAck(
                    AssistantChatWebThreadNoteSaveAck(
                        requestID: requestID,
                        ownerKind: nil,
                        ownerID: nil,
                        noteID: nil,
                        draftRevision: draftRevision,
                        status: "error",
                        errorMessage: message
                    ),
                    sourceContainer: sourceContainer
                )
            }
        }
        isSavingExternalMarkdownFile = false
    }

    private func closeExternalMarkdownFile() {
        confirmExternalMarkdownDiscardIfNeeded {
            discardExternalMarkdownFileSession()
        }
    }

    private func switchAwayFromExternalMarkdownFileIfNeeded(
        continueAction: () -> Void
    ) {
        guard isNotesPaneActive, notesWorkspaceExternalMarkdownFile != nil else {
            continueAction()
            return
        }

        confirmExternalMarkdownDiscardIfNeeded {
            discardExternalMarkdownFileSession()
            continueAction()
        }
    }

    private func discardExternalMarkdownFileSession() {
        notesWorkspaceExternalMarkdownFile = nil
        isSavingExternalMarkdownFile = false
    }

    private func confirmExternalMarkdownDiscardIfNeeded(
        continueAction: () -> Void
    ) {
        guard let externalFile = notesWorkspaceExternalMarkdownFile, externalFile.isDirty else {
            continueAction()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to \(externalFile.fileName)?"
        alert.informativeText =
            "You have unsaved Markdown changes. Save them before switching away, discard them, or cancel."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveExternalMarkdownFile(requestID: nil, text: nil, sourceContainer: nil)
            if notesWorkspaceExternalMarkdownFile?.isDirty == false {
                continueAction()
            }
        case .alertSecondButtonReturn:
            continueAction()
        default:
            return
        }
    }

    private func confirmManagedThreadNoteLeaveAfterSaveFailure(
        reason: String,
        retrySave: () -> Bool
    ) -> Bool {
        while true {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Save changes first?"
            alert.informativeText =
                "Open Assist could not save this note. Save again before you \(reason), leave without saving, or stay here."
            alert.addButton(withTitle: "Save again")
            alert.addButton(withTitle: "Leave without saving")
            alert.addButton(withTitle: "Stay")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if retrySave() {
                    return true
                }
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        }
    }

    private func storedNotePersistenceText(
        owner: AssistantNoteOwnerKey,
        noteID: String
    ) -> String? {
        loadStoredNotes(for: owner)
            .first(where: { $0.noteID.caseInsensitiveCompare(noteID) == .orderedSame })?
            .text
    }

    private func managedThreadNoteUnsavedDraft(
        owner: AssistantNoteOwnerKey,
        noteID: String
    ) -> (title: String, draftText: String)? {
        guard let draftText = noteDraftStore.draft(
            ownerKey: owner.storageKey,
            noteID: noteID
        ) else {
            return nil
        }

        let persistedDraftText = noteMarkdownForPersistence(
            owner: owner,
            noteID: noteID,
            text: draftText
        )
        let storedText = storedNotePersistenceText(owner: owner, noteID: noteID) ?? ""
        guard persistedDraftText != storedText else {
            return nil
        }

        let title =
            noteManifest(for: owner).notes.first(where: {
                $0.id.caseInsensitiveCompare(noteID) == .orderedSame
            })?.title.nonEmpty
            ?? loadStoredNotes(for: owner).first(where: {
                $0.noteID.caseInsensitiveCompare(noteID) == .orderedSame
            })?.title.nonEmpty
            ?? "Untitled note"
        return (title, draftText)
    }

    private func confirmManagedThreadNoteDiscardIfNeeded(
        owner: AssistantNoteOwnerKey,
        noteID: String?,
        reason: String,
        retrySave: () -> Bool
    ) -> Bool {
        guard let noteID,
            let dirtyDraft = managedThreadNoteUnsavedDraft(owner: owner, noteID: noteID)
        else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to \(dirtyDraft.title)?"
        alert.informativeText =
            "This note has unsaved changes. Save them before you \(reason), discard them, or stay here."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if retrySave() {
                return true
            }
            return confirmManagedThreadNoteLeaveAfterSaveFailure(
                reason: reason,
                retrySave: retrySave
            )
        case .alertSecondButtonReturn:
            noteDraftStore.discardDraft(ownerKey: owner.storageKey, noteID: noteID)
            return true
        default:
            return false
        }
    }

    private func flushCurrentThreadNoteDraftFromWeb() async {
        guard let snapshot = await threadNoteWebContainer?.flushThreadNoteDraftSnapshot(),
            (snapshot["ok"] as? Bool) == true,
            let text = snapshot["text"] as? String
        else {
            return
        }

        if snapshot["sourceKind"] as? String == "externalMarkdownFile" {
            updateExternalMarkdownDraft(text)
            return
        }

        guard let ownerKindRaw = snapshot["ownerKind"] as? String,
            let ownerKind = AssistantNoteOwnerKind(rawValue: ownerKindRaw),
            let ownerID = (snapshot["ownerId"] as? String)?.nonEmpty,
            let noteID = (snapshot["noteId"] as? String)?.nonEmpty
        else {
            return
        }

        let revision: Int?
        if let number = snapshot["draftRevision"] as? NSNumber {
            revision = number.intValue
        } else {
            revision = snapshot["draftRevision"] as? Int
        }

        let owner = AssistantNoteOwnerKey(kind: ownerKind, id: ownerID)
        noteDraftStore.setDraft(
            text,
            ownerKey: owner.storageKey,
            noteID: noteID,
            revision: revision
        )
    }

    private func saveManagedThreadNoteBeforeNavigation(reason: String) -> Bool {
        guard let owner = currentThreadNoteOwner else { return true }
        let noteID = currentSelectedThreadNoteNoteID
        let retrySave = {
            persistThreadNoteIfNeeded(for: owner, noteID: noteID)
        }
        if let noteID,
            managedThreadNoteUnsavedDraft(owner: owner, noteID: noteID) != nil
        {
            return confirmManagedThreadNoteDiscardIfNeeded(
                owner: owner,
                noteID: noteID,
                reason: reason,
                retrySave: retrySave
            )
        }
        if retrySave() {
            return true
        }
        return confirmManagedThreadNoteLeaveAfterSaveFailure(
            reason: reason,
            retrySave: retrySave
        )
    }

    private func prepareToLeaveCurrentNoteScreen(reason: String) -> Bool {
        if isNotesPaneActive, notesWorkspaceExternalMarkdownFile != nil {
            var shouldContinue = false
            switchAwayFromExternalMarkdownFileIfNeeded {
                shouldContinue = true
            }
            return shouldContinue
        }

        return saveManagedThreadNoteBeforeNavigation(reason: reason)
    }

    private var currentThreadNoteManifest: AssistantNoteManifest {
        guard let owner = currentThreadNoteOwner else { return AssistantNoteManifest() }
        return noteManifest(for: owner)
    }

    private var currentDisplayedNoteTarget: AssistantNoteLinkTarget? {
        if isNotesPaneActive, notesWorkspaceExternalMarkdownFile != nil {
            return nil
        }
        if isNotesPaneActive,
            let project = selectedNotesProject
        {
            return currentNotesSelectionTarget(project: project, scope: selectedNotesScope)
        }

        guard let owner = currentThreadNoteOwner,
            let noteID = currentThreadNoteManifest.selectedNote?.id
        else {
            return nil
        }
        return AssistantNoteLinkTarget(
            ownerKind: owner.kind,
            ownerID: owner.id,
            noteID: noteID
        )
    }

    private var currentDisplayedNoteTitle: String? {
        if let externalFile = isNotesPaneActive ? notesWorkspaceExternalMarkdownFile : nil {
            return externalFile.fileName
        }
        if isNotesPaneActive,
            let project = selectedNotesProject,
            let currentTarget = currentNotesSelectionTarget(
                project: project, scope: selectedNotesScope)
        {
            return sidebarNoteRows(for: project, scope: selectedNotesScope)
                .first(where: { $0.target == currentTarget })?
                .title
        }

        return currentThreadNoteManifest.selectedNote?.title
    }

    private func notesAssistantWorkspaceScopeLabel(for scope: AssistantNotesScope) -> String {
        switch scope {
        case .project:
            return "the current project notes list"
        case .thread:
            return "the current thread notes list"
        }
    }

    private func notesAssistantWorkspaceNoteReferences(
        project: AssistantProject,
        scope: AssistantNotesScope
    ) -> [AssistantNotesRuntimeContext.WorkspaceNoteReference] {
        let rows = sidebarNoteRows(for: project, scope: scope)
        guard !rows.isEmpty else { return [] }

        let notesByTarget = Dictionary(
            uniqueKeysWithValues: notesUniverse(for: project).allNotes.map { ($0.target, $0) }
        )
        let selectedTarget = currentNotesSelectionTarget(project: project, scope: scope)
        let references = rows.map { row in
            AssistantNotesRuntimeContext.WorkspaceNoteReference(
                target: row.target,
                title: row.title,
                sourceLabel: row.sourceLabel,
                folderPath: row.folderPath,
                fileName: notesByTarget[row.target]?.fileName,
                isSelected: row.target == selectedTarget
            )
        }

        return references.filter(\.isSelected) + references.filter { !$0.isSelected }
    }

    private var notesAssistantScopeLabel: String {
        if let noteTitle = currentDisplayedNoteTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        .nonEmpty {
            return "Open note: \(noteTitle)"
        }

        if let projectName = selectedNotesProject?.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        .nonEmpty {
            return "Whole project: \(projectName)"
        }

        return "Whole project note scope"
    }

    private var notesAssistantRuntimeContext: AssistantNotesRuntimeContext? {
        guard isNotesPaneActive,
            isNotesAssistantPanelOpen,
            let project = selectedNotesProject
        else {
            return nil
        }

        return AssistantNotesRuntimeContext(
            source: .notesWorkspace,
            projectID: project.id,
            projectName: project.name,
            selectedNoteTarget: currentDisplayedNoteTarget,
            selectedNoteTitle: currentDisplayedNoteTitle,
            defaultScopeDescription:
                "the whole current project (`\(project.name)`) including project notes and linked thread notes",
            workspaceScopeLabel: notesAssistantWorkspaceScopeLabel(for: selectedNotesScope),
            workspaceNotes: notesAssistantWorkspaceNoteReferences(
                project: project,
                scope: selectedNotesScope
            )
        )
    }

    private var activeNotesAssistantSessionID: String? {
        guard let project = selectedNotesProject else { return nil }

        if let selectedSessionID = assistant.selectedSessionID,
            notesAssistantAllSessionSummaries(for: project).contains(where: {
                assistantTimelineSessionIDsMatch($0.id, selectedSessionID)
            })
        {
            return selectedSessionID
        }

        return notesAssistantResolvedSessionID(for: project)
    }

    private var currentNotesAssistantSessionSummary: AssistantSessionSummary? {
        guard let activeNotesAssistantSessionID else { return nil }
        return assistant.sessions.first(where: {
            assistantTimelineSessionIDsMatch($0.id, activeNotesAssistantSessionID)
        })
    }

    private var isShowingNotesAssistantConversation: Bool {
        guard isNotesPaneActive,
            isNotesAssistantPanelOpen,
            let activeNotesAssistantSessionID
        else {
            return false
        }

        return assistantTimelineSessionIDsMatch(
            assistant.selectedSessionID,
            activeNotesAssistantSessionID
        )
    }

    private var notesAssistantChatMessages: [AssistantChatWebMessage] {
        isShowingNotesAssistantConversation ? chatWebMessages : []
    }

    private var notesAssistantActiveWorkState: AssistantChatWebActiveWorkState? {
        isShowingNotesAssistantConversation ? chatWebActiveWorkState : nil
    }

    private var notesAssistantActiveTurnState: AssistantChatWebActiveTurnState? {
        isShowingNotesAssistantConversation ? chatWebActiveTurnState : nil
    }

    private var notesAssistantRuntimePanel: AssistantChatWebRuntimePanel? {
        isShowingNotesAssistantConversation ? chatWebRuntimePanel : nil
    }

    private var notesAssistantRewindState: AssistantChatWebRewindState? {
        isShowingNotesAssistantConversation ? chatWebRewindState : nil
    }

    private var notesAssistantReviewPanel: AssistantChatWebCodeReviewPanel? {
        isShowingNotesAssistantConversation ? inlineTrackedCodePanel : nil
    }

    private var notesAssistantShouldShowPendingPlaceholder: Bool {
        isShowingNotesAssistantConversation && shouldShowPendingAssistantPlaceholder
    }

    private var notesAssistantTypingIndicatorTitle: String {
        isShowingNotesAssistantConversation ? typingIndicatorTitle : ""
    }

    private var notesAssistantTypingIndicatorDetail: String {
        isShowingNotesAssistantConversation ? typingIndicatorDetail : ""
    }

    private var notesAssistantCanLoadOlderHistory: Bool {
        isShowingNotesAssistantConversation && canLoadOlderHistory
    }

    private var notesAssistantHasVisibleConversationContent: Bool {
        !notesAssistantChatMessages.isEmpty
            || notesAssistantActiveWorkState != nil
            || notesAssistantActiveTurnState != nil
            || notesAssistantShouldShowPendingPlaceholder
            || notesAssistantCanLoadOlderHistory
    }

    private var currentSelectedThreadNoteItem: AssistantNoteSummary? {
        currentThreadNoteManifest.selectedNote
    }

    private var currentSelectedThreadNoteNoteID: String? {
        currentDisplayedNoteTarget?.noteID
    }

    private var currentThreadNoteDraftText: String {
        guard let owner = currentThreadNoteOwner,
            let noteID = currentSelectedThreadNoteNoteID
        else { return "" }
        return noteDraftText(for: owner, noteID: noteID)
    }

    private func composerNoteContextKey(ownerKind: String, ownerID: String, noteID: String)
        -> String
    {
        "\(ownerKind)|\(ownerID)|\(noteID)"
    }

    private func externalMarkdownComposerNoteContextKey(filePath: String) -> String {
        "externalMarkdownFile|\(filePath)"
    }

    private var composerNoteContextForState: AssistantComposerWebNoteContext? {
        if isNotesPaneActive, let externalFile = notesWorkspaceExternalMarkdownFile {
            let key = externalMarkdownComposerNoteContextKey(filePath: externalFile.filePath)
            if composerNoteContextDismissedKeys.contains(key) { return nil }

            return AssistantComposerWebNoteContext(
                noteTitle: externalFile.fileName,
                projectTitle: selectedNotesProject?.name,
                ownerKind: nil,
                ownerID: nil,
                noteID: nil,
                contextKey: key,
                sourceLabel: "Markdown file",
                filePath: externalFile.filePath,
                includeContent: composerNoteContextIncludeContentKeys.contains(key)
            )
        }

        guard let target = currentDisplayedNoteTarget,
            let noteTitle = currentDisplayedNoteTitle?.nonEmpty
        else {
            return nil
        }

        let key = composerNoteContextKey(
            ownerKind: target.ownerKind.rawValue, ownerID: target.ownerID, noteID: target.noteID)
        if composerNoteContextDismissedKeys.contains(key) { return nil }

        return AssistantComposerWebNoteContext(
            noteTitle: noteTitle,
            projectTitle: isNotesPaneActive ? selectedNotesProject?.name : currentProjectNotesProject?.name,
            ownerKind: target.ownerKind.rawValue,
            ownerID: target.ownerID,
            noteID: target.noteID,
            contextKey: key,
            sourceLabel: sourceLabel(for: target.ownerKind, ownerID: target.ownerID),
            filePath: nil,
            includeContent: composerNoteContextIncludeContentKeys.contains(key)
        )
    }

    private var chatWebThreadNoteState: AssistantChatWebThreadNoteState {
        if isNotesPaneActive {
            return notesWorkspaceThreadNoteState(for: selectedNotesProject)
        }

        let threadID = currentProjectNotesProject == nil ? selectedThreadNoteID : nil
        let owner = currentThreadNoteOwner
        let manifest = currentThreadNoteManifest
        let selectedNote = manifest.selectedNote
        let selectedNoteID = selectedNote?.id
        let text = currentThreadNoteDraftText
        let relationships = currentThreadNoteRelationshipSnapshot()
        let navigationStack = currentThreadNoteNavigationStack()
        let historyVersions = chatWebHistoryItems(for: owner, noteID: selectedNoteID)
        let recentlyDeletedNotes = chatWebDeletedNoteItems(for: owner)
        let savedAt: Date?
        if let owner, let selectedNoteID {
            savedAt =
                noteLastSavedAtByOwnerKey[owner.storageKey]?[selectedNoteID]
                ?? selectedNote?.updatedAt
        } else {
            savedAt = nil
        }
        let isSaving =
            owner.flatMap { owner in
                selectedNoteID.map {
                    threadNoteSavingNoteKeys.contains(
                        threadNoteStorageKey(owner: owner, noteID: $0))
                }
            } ?? false
        let availableOwners = availableNoteOwners(for: selectedThreadNoteID)
        let presentation = currentProjectNotesProject == nil ? "drawer" : "projectFullScreen"

        let availableSources = availableOwners.map { source in
            AssistantChatWebThreadNoteSource(
                ownerKind: source.kind.rawValue,
                ownerID: source.id,
                ownerTitle: noteOwnerTitle(for: source),
                sourceLabel: source.displaySourceLabel
            )
        }

        let notes = availableOwners.flatMap { source in
            noteManifest(for: source).orderedNotes.map { note in
                AssistantChatWebThreadNoteItem(
                    id: note.id,
                    title: note.title,
                    noteType: note.noteType.rawValue,
                    updatedAtLabel: threadNoteSavedLabel(
                        for: noteLastSavedAtByOwnerKey[source.storageKey]?[note.id]
                            ?? note.updatedAt
                    ),
                    ownerKind: source.kind.rawValue,
                    ownerID: source.id,
                    sourceLabel: source.displaySourceLabel
                )
            }
        }

        return AssistantChatWebThreadNoteState(
            threadID: threadID,
            ownerKind: owner?.kind.rawValue,
            ownerID: owner?.id,
            ownerTitle: owner.map(noteOwnerTitle(for:)) ?? "",
            presentation: presentation,
            notesScope: nil,
            workspaceProjectID: nil,
            workspaceProjectTitle: nil,
            workspaceOwnerSubtitle: nil,
            canCreateNote: true,
            owningThreadID: nil,
            owningThreadTitle: nil,
            availableSources: availableSources,
            notes: notes,
            selectedNoteID: selectedNoteID,
            selectedNoteTitle: selectedNote?.title ?? "Untitled note",
            text: text,
            isOpen: owner == nil
                ? false : (presentation == "projectFullScreen" ? true : isThreadNoteOpen),
            isExpanded: presentation == "projectFullScreen" ? true : isThreadNoteExpanded,
            viewMode: threadNoteViewMode,
            hasAnyNotes: !manifest.notes.isEmpty,
            isSaving: isSaving,
            isGeneratingAIDraft: owner.map {
                threadNoteGeneratingAIDraftOwnerKeys.contains($0.storageKey)
            } ?? false,
            isGeneratingProjectTransferPreview: owner.map {
                threadNoteGeneratingProjectTransferOwnerKeys.contains($0.storageKey)
            } ?? false,
            isGeneratingBatchNotePlanPreview: false,
            aiDraftMode: owner.flatMap { threadNoteAIDraftModeByOwnerKey[$0.storageKey] },
            lastSavedAtLabel: threadNoteSavedLabel(for: savedAt),
            canEdit: owner != nil,
            placeholder: notePlaceholder(for: owner),
            sourceDescriptor: nil,
            aiDraftPreview: owner.flatMap { threadNoteAIDraftPreviewByOwnerKey[$0.storageKey] },
            projectNoteTransferPreview: owner.flatMap {
                threadNoteProjectTransferPreviewByOwnerKey[$0.storageKey]
            },
            projectNoteTransferOutcome: owner.flatMap {
                threadNoteProjectTransferOutcomeByOwnerKey[$0.storageKey]
            },
            batchNotePlanPreview: nil,
            outgoingLinks: chatWebRelationshipItems(from: relationships.outgoingLinks),
            backlinks: chatWebRelationshipItems(from: relationships.backlinks),
            graph: relationships.graph.map {
                AssistantChatWebThreadNoteGraph(
                    mermaidCode: $0.mermaidCode,
                    nodeCount: $0.nodeCount,
                    edgeCount: $0.edgeCount
                )
            },
            canNavigateBack: !navigationStack.isEmpty,
            previousLinkedNoteTitle: navigationStack.last?.title,
            historyVersions: historyVersions,
            recentlyDeletedNotes: recentlyDeletedNotes
        )
    }

    private func notesWorkspaceThreadNoteState(
        for project: AssistantProject?
    ) -> AssistantChatWebThreadNoteState {
        if let externalFile = notesWorkspaceExternalMarkdownFile {
            let availableSources: [AssistantChatWebThreadNoteSource]
            let notes: [AssistantChatWebThreadNoteItem]
            if let project {
                let universe = notesUniverse(for: project)
                availableSources =
                    [
                        AssistantChatWebThreadNoteSource(
                            ownerKind: universe.projectOwner.kind.rawValue,
                            ownerID: universe.projectOwner.id,
                            ownerTitle: project.name,
                            sourceLabel: universe.projectOwner.displaySourceLabel
                        )
                    ]
                    + universe.threadSources
                    .filter { !$0.notes.isEmpty }
                    .map { source in
                        AssistantChatWebThreadNoteSource(
                            ownerKind: source.owner.kind.rawValue,
                            ownerID: source.owner.id,
                            ownerTitle: source.session.title,
                            sourceLabel: source.owner.displaySourceLabel
                        )
                    }

                notes =
                    universe.projectNotes.map { note in
                        AssistantChatWebThreadNoteItem(
                            id: note.noteID,
                            title: note.title,
                            noteType: note.noteType.rawValue,
                            updatedAtLabel: threadNoteSavedLabel(for: note.updatedAt),
                            ownerKind: note.ownerKind.rawValue,
                            ownerID: note.ownerID,
                            sourceLabel: "Project notes"
                        )
                    }
                    + universe.threadNotes.map { note in
                        AssistantChatWebThreadNoteItem(
                            id: note.noteID,
                            title: note.title,
                            noteType: note.noteType.rawValue,
                            updatedAtLabel: threadNoteSavedLabel(for: note.updatedAt),
                            ownerKind: note.ownerKind.rawValue,
                            ownerID: note.ownerID,
                            sourceLabel: "Thread notes"
                        )
                    }
            } else {
                availableSources = []
                notes = []
            }

            return AssistantChatWebThreadNoteState(
                threadID: nil,
                ownerKind: nil,
                ownerID: nil,
                ownerTitle: "Markdown file",
                presentation: "notesWorkspace",
                notesScope: selectedNotesScope.rawValue,
                workspaceProjectID: project?.id,
                workspaceProjectTitle: project?.name,
                workspaceOwnerSubtitle: externalFile.directoryPath,
                canCreateNote: false,
                owningThreadID: nil,
                owningThreadTitle: nil,
                availableSources: availableSources,
                notes: notes,
                selectedNoteID: nil,
                selectedNoteTitle: externalFile.fileName,
                text: externalFile.draftText,
                isOpen: true,
                isExpanded: true,
                viewMode: threadNoteViewMode,
                hasAnyNotes: true,
                isSaving: isSavingExternalMarkdownFile,
                isGeneratingAIDraft: false,
                isGeneratingProjectTransferPreview: false,
                isGeneratingBatchNotePlanPreview: false,
                aiDraftMode: nil,
                lastSavedAtLabel: threadNoteSavedLabel(for: externalFile.lastSavedAt),
                canEdit: true,
                placeholder: "Edit the opened Markdown file or switch to Preview.",
                sourceDescriptor: externalMarkdownSourceDescriptor(for: externalFile),
                aiDraftPreview: nil,
                projectNoteTransferPreview: nil,
                projectNoteTransferOutcome: nil,
                batchNotePlanPreview: nil,
                outgoingLinks: [],
                backlinks: [],
                graph: nil,
                canNavigateBack: false,
                previousLinkedNoteTitle: nil,
                historyVersions: [],
                recentlyDeletedNotes: []
            )
        }

        guard let project else {
            return AssistantChatWebThreadNoteState(
                threadID: nil,
                ownerKind: nil,
                ownerID: nil,
                ownerTitle: "",
                presentation: "notesWorkspace",
                notesScope: selectedNotesScope.rawValue,
                workspaceProjectID: nil,
                workspaceProjectTitle: nil,
                workspaceOwnerSubtitle: nil,
                canCreateNote: selectedNotesScope == .project,
                owningThreadID: nil,
                owningThreadTitle: nil,
                availableSources: [],
                notes: [],
                selectedNoteID: nil,
                selectedNoteTitle: selectedNotesScope == .project
                    ? "Project notes" : "Thread notes",
                text: "",
                isOpen: true,
                isExpanded: true,
                viewMode: threadNoteViewMode,
                hasAnyNotes: false,
                isSaving: false,
                isGeneratingAIDraft: false,
                isGeneratingProjectTransferPreview: false,
                isGeneratingBatchNotePlanPreview: false,
                aiDraftMode: nil,
                lastSavedAtLabel: nil,
                canEdit: true,
                placeholder: notePlaceholder(for: nil),
                sourceDescriptor: nil,
                aiDraftPreview: nil,
                projectNoteTransferPreview: nil,
                projectNoteTransferOutcome: nil,
                batchNotePlanPreview: nil,
                outgoingLinks: [],
                backlinks: [],
                graph: nil,
                canNavigateBack: false,
                previousLinkedNoteTitle: nil,
                historyVersions: [],
                recentlyDeletedNotes: []
            )
        }

        let universe = notesUniverse(for: project)
        let selectedTarget = currentNotesSelectionTarget(
            project: project, scope: selectedNotesScope)
        let selectedOwner =
            selectedTarget.map {
                AssistantNoteOwnerKey(kind: $0.ownerKind, id: $0.ownerID)
            }
            ?? (selectedNotesScope == .project
                ? AssistantNoteOwnerKey(kind: .project, id: project.id)
                : nil)
        let scopeRows = sidebarNoteRows(for: project, scope: selectedNotesScope)
        let selectedRow = selectedTarget.flatMap { target in
            scopeRows.first(where: { $0.target == target })
        }
        let selectedNoteID = selectedTarget?.noteID
        let relationships = currentThreadNoteRelationshipSnapshot()
        let navigationStack = currentThreadNoteNavigationStack()
        let historyVersions = chatWebHistoryItems(for: selectedOwner, noteID: selectedNoteID)
        let recentlyDeletedNotes = chatWebDeletedNoteItems(for: selectedOwner)
        let text =
            selectedOwner.flatMap { owner in
                selectedNoteID.map { noteDraftText(for: owner, noteID: $0) }
            } ?? ""
        let isSaving =
            selectedOwner.flatMap { owner in
                selectedNoteID.map {
                    threadNoteSavingNoteKeys.contains(
                        threadNoteStorageKey(owner: owner, noteID: $0))
                }
            } ?? false

        let availableSources =
            [
                AssistantChatWebThreadNoteSource(
                    ownerKind: universe.projectOwner.kind.rawValue,
                    ownerID: universe.projectOwner.id,
                    ownerTitle: project.name,
                    sourceLabel: universe.projectOwner.displaySourceLabel
                )
            ]
            + universe.threadSources
            .filter { !$0.notes.isEmpty }
            .map { source in
                AssistantChatWebThreadNoteSource(
                    ownerKind: source.owner.kind.rawValue,
                    ownerID: source.owner.id,
                    ownerTitle: source.session.title,
                    sourceLabel: source.owner.displaySourceLabel
                )
            }

        let notes =
            universe.projectNotes.map { note in
                AssistantChatWebThreadNoteItem(
                    id: note.noteID,
                    title: note.title,
                    noteType: note.noteType.rawValue,
                    updatedAtLabel: threadNoteSavedLabel(for: note.updatedAt),
                    ownerKind: note.ownerKind.rawValue,
                    ownerID: note.ownerID,
                    sourceLabel: "Project notes"
                )
            }
            + universe.threadNotes.map { note in
                AssistantChatWebThreadNoteItem(
                    id: note.noteID,
                    title: note.title,
                    noteType: note.noteType.rawValue,
                    updatedAtLabel: threadNoteSavedLabel(for: note.updatedAt),
                    ownerKind: note.ownerKind.rawValue,
                    ownerID: note.ownerID,
                    sourceLabel: "Thread notes"
                )
            }

        let owningThread =
            selectedOwner?.kind == .thread
            ? sessionSummary(forThreadID: selectedOwner?.id)
            : nil
        let ownerSubtitle: String?
        if let owningThread {
            ownerSubtitle =
                owningThread.isArchived
                ? "\(owningThread.title) • Archived chat"
                : owningThread.title
        } else if selectedOwner?.kind == .project {
            ownerSubtitle = "Shared note for this project"
        } else {
            ownerSubtitle = nil
        }

        let savedAt =
            selectedOwner.flatMap { owner in
                selectedNoteID.flatMap { noteLastSavedAtByOwnerKey[owner.storageKey]?[$0] }
            } ?? selectedRow?.updatedAt

        return AssistantChatWebThreadNoteState(
            threadID: nil,
            ownerKind: selectedOwner?.kind.rawValue,
            ownerID: selectedOwner?.id,
            ownerTitle: selectedOwner.map(noteOwnerTitle(for:)) ?? project.name,
            presentation: "notesWorkspace",
            notesScope: selectedNotesScope.rawValue,
            workspaceProjectID: project.id,
            workspaceProjectTitle: project.name,
            workspaceOwnerSubtitle: ownerSubtitle,
            canCreateNote: selectedNotesScope == .project,
            owningThreadID: owningThread?.id,
            owningThreadTitle: owningThread?.title,
            availableSources: availableSources,
            notes: notes,
            selectedNoteID: selectedNoteID,
            selectedNoteTitle: selectedRow?.title
                ?? (selectedNotesScope == .project ? "Project notes" : "Thread notes"),
            text: text,
            isOpen: true,
            isExpanded: true,
            viewMode: threadNoteViewMode,
            hasAnyNotes: !scopeRows.isEmpty,
            isSaving: isSaving,
            isGeneratingAIDraft: selectedOwner.map {
                threadNoteGeneratingAIDraftOwnerKeys.contains($0.storageKey)
            } ?? false,
            isGeneratingProjectTransferPreview: selectedOwner.map {
                threadNoteGeneratingProjectTransferOwnerKeys.contains($0.storageKey)
            } ?? false,
            isGeneratingBatchNotePlanPreview: batchNotePlanGeneratingProjectIDs.contains(
                project.id),
            aiDraftMode: selectedOwner.flatMap { threadNoteAIDraftModeByOwnerKey[$0.storageKey] },
            lastSavedAtLabel: threadNoteSavedLabel(for: savedAt),
            canEdit: true,
            placeholder: notePlaceholder(for: selectedOwner),
            sourceDescriptor: nil,
            aiDraftPreview: selectedOwner.flatMap {
                threadNoteAIDraftPreviewByOwnerKey[$0.storageKey]
            },
            projectNoteTransferPreview: selectedOwner.flatMap {
                threadNoteProjectTransferPreviewByOwnerKey[$0.storageKey]
            },
            projectNoteTransferOutcome: selectedOwner.flatMap {
                threadNoteProjectTransferOutcomeByOwnerKey[$0.storageKey]
            },
            batchNotePlanPreview: batchNotePlanPreviewByProjectID[project.id],
            outgoingLinks: chatWebRelationshipItems(from: relationships.outgoingLinks),
            backlinks: chatWebRelationshipItems(from: relationships.backlinks),
            graph: relationships.graph.map {
                AssistantChatWebThreadNoteGraph(
                    mermaidCode: $0.mermaidCode,
                    nodeCount: $0.nodeCount,
                    edgeCount: $0.edgeCount
                )
            },
            canNavigateBack: !navigationStack.isEmpty,
            previousLinkedNoteTitle: navigationStack.last?.title,
            historyVersions: historyVersions,
            recentlyDeletedNotes: recentlyDeletedNotes
        )
    }

    private func threadNoteSavedLabel(for date: Date?) -> String? {
        guard let date else { return nil }
        let relative = Self.sidebarRelativeDateFormatter.localizedString(
            for: date, relativeTo: Date())
        return relative == "now" ? "Saved now" : "Saved \(relative)"
    }

    static func mergedNoteDrafts(
        existingDrafts: [String: String],
        workspace: AssistantNotesWorkspace
    ) -> [String: String] {
        let validNoteIDs = Set(workspace.notes.map(\.id))
        var drafts = existingDrafts.filter { validNoteIDs.contains($0.key) }
        if let selectedNote = workspace.selectedNote {
            drafts[selectedNote.id] = workspace.selectedNoteText
        }
        return drafts
    }

    private func threadNoteStorageKey(owner: AssistantNoteOwnerKey, noteID: String) -> String {
        "\(owner.storageKey)::\(noteID)"
    }

    private func applyThreadNoteWorkspace(_ workspace: AssistantNotesWorkspace) {
        let owner = AssistantNoteOwnerKey(kind: workspace.ownerKind, id: workspace.ownerID)
        noteManifestByOwnerKey[owner.storageKey] = workspace.manifest

        let validNoteIDs = Set(workspace.notes.map(\.id))
        var drafts = noteDraftStore.drafts(ownerKey: owner.storageKey)
            .filter { validNoteIDs.contains($0.key) }
        if let selectedNote = workspace.selectedNote {
            let workspaceText = noteMarkdownForDisplay(
                owner: owner,
                noteID: selectedNote.id,
                text: workspace.selectedNoteText
            )
            // Preserve the in-memory draft if it differs from the
            // workspace's saved text. A difference means JS pushed a
            // newer `updateDraft` that hasn't been persisted yet — and
            // blindly overwriting it here would silently lose those
            // in-flight edits. This was the root cause of the
            // "sometimes loses what I wrote" bug: an unrelated workspace
            // refresh (sidebar, backlink, mutation) would stomp the
            // unsaved draft between keystroke and save.
            //
            // Only update this entry if there's no existing draft yet,
            // or if the workspace text already matches what we have —
            // i.e. the workspace itself is the authoritative source
            // because a save just completed.
            let currentDraft = drafts[selectedNote.id]
            if currentDraft == nil || currentDraft == workspaceText {
                drafts[selectedNote.id] = workspaceText
            }
            // For all OTHER notes we still prefer the workspace's
            // on-disk text — those aren't being actively edited.
        }
        // For the non-selected notes, let the workspace's manifest drive
        // the cache: drop any stale entries (handled by the filter
        // above) but don't try to eagerly populate (noteDraftText falls
        // back to disk for notes with no draft entry).
        noteDraftStore.replaceDrafts(drafts, ownerKey: owner.storageKey)

        var savedAt = noteLastSavedAtByOwnerKey[owner.storageKey] ?? [:]
        savedAt = savedAt.filter { validNoteIDs.contains($0.key) }
        for note in workspace.notes {
            savedAt[note.id] = note.updatedAt
        }
        noteLastSavedAtByOwnerKey[owner.storageKey] = savedAt
    }

    private func refreshNotesAfterAssistantMutation(_ mutation: AssistantNotesMutationEvent?) {
        guard let mutation else { return }

        let owner = AssistantNoteOwnerKey(kind: mutation.ownerKind, id: mutation.ownerID)
        guard let workspace = loadNotesWorkspace(for: owner) else {
            return
        }

        noteManifestByOwnerKey[owner.storageKey] = workspace.manifest

        let validNoteIDs = Set(workspace.notes.map(\.id))
        var drafts = noteDraftStore.drafts(ownerKey: owner.storageKey)
            .filter { validNoteIDs.contains($0.key) }
        let storedNotesByID = Dictionary(
            uniqueKeysWithValues: loadStoredNotes(for: owner).map { note in
                (note.noteID, note)
            })
        if let changedNote = storedNotesByID[mutation.noteID] {
            drafts[changedNote.noteID] = noteMarkdownForDisplay(
                owner: owner,
                noteID: changedNote.noteID,
                text: changedNote.text
            )
        } else {
            drafts.removeValue(forKey: mutation.noteID)
        }
        noteDraftStore.replaceDrafts(drafts, ownerKey: owner.storageKey)

        var savedAt = noteLastSavedAtByOwnerKey[owner.storageKey] ?? [:]
        savedAt = savedAt.filter { validNoteIDs.contains($0.key) }
        for note in workspace.notes {
            savedAt[note.id] = note.updatedAt
        }
        noteLastSavedAtByOwnerKey[owner.storageKey] = savedAt
    }

    private func clearThreadNoteAIDraftState(for owner: AssistantNoteOwnerKey) {
        let storageKey = owner.storageKey
        threadNoteAIDraftPreviewByOwnerKey.removeValue(forKey: storageKey)
        threadNoteGeneratingAIDraftOwnerKeys.remove(storageKey)
        threadNoteAIDraftModeByOwnerKey.removeValue(forKey: storageKey)
        threadNoteAIDraftRequestIDByOwnerKey.removeValue(forKey: storageKey)
        threadNoteChartContextByOwnerKey.removeValue(forKey: storageKey)
    }

    private func clearThreadNoteProjectTransferState(for owner: AssistantNoteOwnerKey) {
        let storageKey = owner.storageKey
        threadNoteProjectTransferPreviewByOwnerKey.removeValue(forKey: storageKey)
        threadNoteGeneratingProjectTransferOwnerKeys.remove(storageKey)
        threadNoteProjectTransferRequestIDByOwnerKey.removeValue(forKey: storageKey)
    }

    private func clearThreadNoteProjectTransferOutcome(for owner: AssistantNoteOwnerKey) {
        threadNoteProjectTransferOutcomeByOwnerKey.removeValue(forKey: owner.storageKey)
    }

    @discardableResult
    private func beginThreadNoteProjectTransferRequest(
        for owner: AssistantNoteOwnerKey
    ) -> UUID {
        let requestID = UUID()
        let storageKey = owner.storageKey
        threadNoteGeneratingProjectTransferOwnerKeys.insert(storageKey)
        threadNoteProjectTransferRequestIDByOwnerKey[storageKey] = requestID
        threadNoteProjectTransferPreviewByOwnerKey.removeValue(forKey: storageKey)
        return requestID
    }

    private func finishThreadNoteProjectTransferRequest(
        for owner: AssistantNoteOwnerKey,
        requestID: UUID,
        preview: AssistantChatWebProjectNoteTransferPreview
    ) {
        let storageKey = owner.storageKey
        guard threadNoteProjectTransferRequestIDByOwnerKey[storageKey] == requestID else {
            return
        }
        threadNoteProjectTransferPreviewByOwnerKey[storageKey] = preview
        threadNoteGeneratingProjectTransferOwnerKeys.remove(storageKey)
    }

    private func failThreadNoteProjectTransferRequest(
        for owner: AssistantNoteOwnerKey,
        requestID: UUID,
        preview: AssistantChatWebProjectNoteTransferPreview
    ) {
        let storageKey = owner.storageKey
        guard threadNoteProjectTransferRequestIDByOwnerKey[storageKey] == requestID else {
            return
        }
        threadNoteProjectTransferPreviewByOwnerKey[storageKey] = preview
        threadNoteGeneratingProjectTransferOwnerKeys.remove(storageKey)
    }

    private func setThreadNoteProjectTransferOutcome(
        for owner: AssistantNoteOwnerKey,
        kind: String,
        message: String
    ) {
        threadNoteProjectTransferOutcomeByOwnerKey[owner.storageKey] =
            AssistantChatWebProjectNoteTransferOutcome(
                id: UUID().uuidString.lowercased(),
                kind: kind,
                message: message
            )
    }

    private func stableNoteFingerprint(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    @discardableResult
    private func beginBatchNotePlanRequest(for projectID: String) -> UUID {
        let requestID = UUID()
        batchNotePlanGeneratingProjectIDs.insert(projectID)
        batchNotePlanRequestIDByProjectID[projectID] = requestID
        return requestID
    }

    private func finishBatchNotePlanRequest(
        for projectID: String,
        requestID: UUID,
        preview: AssistantChatWebBatchNotePlanPreview
    ) {
        guard batchNotePlanRequestIDByProjectID[projectID] == requestID else {
            return
        }
        batchNotePlanPreviewByProjectID[projectID] = preview
        batchNotePlanGeneratingProjectIDs.remove(projectID)
        batchNotePlanRequestIDByProjectID.removeValue(forKey: projectID)
    }

    private func clearBatchNotePlanState(for projectID: String) {
        batchNotePlanPreviewByProjectID.removeValue(forKey: projectID)
        batchNotePlanGeneratingProjectIDs.remove(projectID)
        batchNotePlanRequestIDByProjectID.removeValue(forKey: projectID)
    }

    private func stableBatchSourceFingerprint(
        _ sourceNotes: [AssistantBatchNotePlanSourceContext]
    ) -> String {
        let fingerprintSource = sourceNotes.map { source in
            [
                source.target.storageKey,
                source.title,
                source.noteType.rawValue,
                source.markdown.replacingOccurrences(of: "\r\n", with: "\n"),
            ]
            .joined(separator: "\n")
        }
        .joined(separator: "\n---\n")
        return stableNoteFingerprint(fingerprintSource)
    }

    private func stableBatchTargetManifestFingerprint(projectID: String) -> String {
        let owner = AssistantNoteOwnerKey(kind: .project, id: projectID)
        let manifest = noteManifest(for: owner)
        let payload = manifest.orderedNotes.map { note in
            [
                note.id,
                note.title,
                note.noteType.rawValue,
                note.fileName,
                String(note.order),
                String(note.updatedAt.timeIntervalSince1970),
            ]
            .joined(separator: "|")
        }
        .joined(separator: "\n")
        return stableNoteFingerprint(payload)
    }

    private func resolveBatchNotePlanSourceContexts(
        projectID: String,
        selections: [AssistantChatWebBatchSourceNoteSelection]
    ) -> [AssistantBatchNotePlanSourceContext] {
        guard let project = sidebarProject(for: projectID) else {
            return []
        }

        let notesByStorageKey = Dictionary(
            uniqueKeysWithValues: notesUniverse(for: project).allNotes.map {
                ($0.target.storageKey, $0)
            })
        var resolved: [AssistantBatchNotePlanSourceContext] = []
        var seen = Set<String>()

        for selection in selections {
            guard let ownerKind = AssistantNoteOwnerKind(rawValue: selection.ownerKind) else {
                continue
            }
            let target = AssistantNoteLinkTarget(
                ownerKind: ownerKind,
                ownerID: selection.ownerID,
                noteID: selection.noteID
            )
            guard seen.insert(target.storageKey).inserted,
                let storedNote = notesByStorageKey[target.storageKey]
            else {
                continue
            }

            let owner = AssistantNoteOwnerKey(kind: storedNote.ownerKind, id: storedNote.ownerID)
            resolved.append(
                AssistantBatchNotePlanSourceContext(
                    ref: "S\(resolved.count + 1)",
                    target: target,
                    title: storedNote.title,
                    noteType: storedNote.noteType,
                    sourceLabel: sourceLabel(
                        for: storedNote.ownerKind, ownerID: storedNote.ownerID),
                    markdown: noteDraftText(for: owner, noteID: storedNote.noteID)
                )
            )
        }

        return resolved
    }

    private func makeBatchSourceResolvedTarget(
        from source: AssistantBatchNotePlanSourceContext
    ) -> AssistantChatWebBatchNotePlanResolvedTarget {
        AssistantChatWebBatchNotePlanResolvedTarget(
            kind: AssistantBatchNotePlanLinkTargetKind.source.rawValue,
            tempID: nil,
            ownerKind: source.target.ownerKind.rawValue,
            ownerID: source.target.ownerID,
            noteID: source.target.noteID,
            title: source.title,
            sourceLabel: source.sourceLabel
        )
    }

    private func makeBatchProposedResolvedTarget(
        tempID: String,
        title: String
    ) -> AssistantChatWebBatchNotePlanResolvedTarget {
        AssistantChatWebBatchNotePlanResolvedTarget(
            kind: AssistantBatchNotePlanLinkTargetKind.proposed.rawValue,
            tempID: tempID,
            ownerKind: nil,
            ownerID: nil,
            noteID: nil,
            title: title,
            sourceLabel: nil
        )
    }

    private func batchPlanLinkKey(
        fromTempID: String,
        toTarget: AssistantChatWebBatchNotePlanResolvedTarget
    ) -> String {
        [
            fromTempID.lowercased(),
            toTarget.kind.lowercased(),
            (toTarget.tempID ?? "").lowercased(),
            (toTarget.ownerKind ?? "").lowercased(),
            (toTarget.ownerID ?? "").lowercased(),
            (toTarget.noteID ?? "").lowercased(),
        ]
        .joined(separator: "::")
    }

    private func buildBatchNotePlanPreview(
        projectID: String,
        sourceNotes: [AssistantBatchNotePlanSourceContext],
        draft: AssistantBatchNotePlanDraftOutput
    ) -> AssistantChatWebBatchNotePlanPreview {
        let reservedTitles = Set(
            loadStoredNotes(for: AssistantNoteOwnerKey(kind: .project, id: projectID)).map(\.title)
        )
        let deduplicatedTitles = AssistantBatchNotePlanComposer.deduplicatedTitles(
            draft.notes.map(\.title),
            reservedTitles: reservedTitles
        )

        var warnings: [String] = []
        if draft.notes.map(\.title) != deduplicatedTitles {
            warnings.append("Some generated note titles were adjusted to keep them unique.")
        }

        let sourceTargetsByRef = Dictionary(uniqueKeysWithValues: sourceNotes.map { ($0.ref, $0) })
        let proposedNotes = zip(draft.notes, deduplicatedTitles).map { draftNote, title in
            let sourceTargets = draftNote.sourceNoteRefs.compactMap {
                ref -> AssistantChatWebBatchNotePlanResolvedTarget? in
                guard let source = sourceTargetsByRef[ref] else { return nil }
                return makeBatchSourceResolvedTarget(from: source)
            }
            return AssistantChatWebBatchNotePlanProposedNote(
                tempID: draftNote.tempID,
                title: title,
                noteType: draftNote.noteType.rawValue,
                markdown: draftNote.markdown,
                sourceNoteTargets: sourceTargets,
                accepted: true
            )
        }

        let proposedTargetsByTempID = Dictionary(
            uniqueKeysWithValues: proposedNotes.map {
                (
                    $0.tempID.lowercased(),
                    makeBatchProposedResolvedTarget(tempID: $0.tempID, title: $0.title)
                )
            })
        let sourceNoteRows = sourceNotes.map { source in
            AssistantChatWebBatchNotePlanSourceNote(
                ownerKind: source.target.ownerKind.rawValue,
                ownerID: source.target.ownerID,
                noteID: source.target.noteID,
                title: source.title,
                noteType: source.noteType.rawValue,
                sourceLabel: source.sourceLabel,
                markdown: source.markdown
            )
        }

        var proposedLinks: [AssistantChatWebBatchNotePlanProposedLink] = []
        var seenLinkKeys = Set<String>()
        func appendLink(from tempID: String, to target: AssistantChatWebBatchNotePlanResolvedTarget)
        {
            let key = batchPlanLinkKey(fromTempID: tempID, toTarget: target)
            guard seenLinkKeys.insert(key).inserted else { return }
            proposedLinks.append(
                AssistantChatWebBatchNotePlanProposedLink(
                    fromTempID: tempID,
                    toTarget: target,
                    accepted: true
                )
            )
        }

        for link in draft.links {
            switch link.toTarget.kind {
            case .proposed:
                if let target = proposedTargetsByTempID[link.toTarget.ref.lowercased()] {
                    appendLink(from: link.fromTempID, to: target)
                }
            case .source:
                if let source = sourceTargetsByRef[link.toTarget.ref] {
                    appendLink(
                        from: link.fromTempID, to: makeBatchSourceResolvedTarget(from: source))
                }
            }
        }

        if let masterNote = proposedNotes.first(where: {
            $0.noteType == AssistantNoteType.master.rawValue
        }) {
            for note in proposedNotes where note.tempID != masterNote.tempID {
                appendLink(
                    from: masterNote.tempID,
                    to: makeBatchProposedResolvedTarget(tempID: note.tempID, title: note.title)
                )
            }
        }

        for note in proposedNotes {
            for sourceTarget in note.sourceNoteTargets {
                appendLink(from: note.tempID, to: sourceTarget)
            }
        }

        let graph = AssistantBatchNotePlanComposer.buildPreviewGraph(
            nodes: sourceNotes.map {
                AssistantBatchNotePlanGraphNode(
                    id: $0.target.storageKey,
                    title: $0.title,
                    kind: .source,
                    noteType: $0.noteType
                )
            }
                + proposedNotes.map {
                    AssistantBatchNotePlanGraphNode(
                        id: $0.tempID,
                        title: $0.title,
                        kind: .proposed,
                        noteType: AssistantNoteType.normalized($0.noteType)
                    )
                },
            edges: proposedLinks.compactMap { link in
                let toNodeID: String
                if link.toTarget.kind == AssistantBatchNotePlanLinkTargetKind.proposed.rawValue,
                    let tempID = link.toTarget.tempID
                {
                    toNodeID = tempID
                } else if let ownerKind = link.toTarget.ownerKind,
                    let ownerID = link.toTarget.ownerID,
                    let noteID = link.toTarget.noteID,
                    let kind = AssistantNoteOwnerKind(rawValue: ownerKind)
                {
                    toNodeID =
                        AssistantNoteLinkTarget(
                            ownerKind: kind,
                            ownerID: ownerID,
                            noteID: noteID
                        ).storageKey
                } else {
                    return nil
                }
                return AssistantBatchNotePlanGraphEdge(
                    fromNodeID: link.fromTempID, toNodeID: toNodeID)
            }
        )

        return AssistantChatWebBatchNotePlanPreview(
            previewID: UUID().uuidString.lowercased(),
            sourceNotes: sourceNoteRows,
            proposedNotes: proposedNotes,
            proposedLinks: proposedLinks,
            graph: graph.map {
                AssistantChatWebThreadNoteGraph(
                    mermaidCode: $0.mermaidCode,
                    nodeCount: $0.nodeCount,
                    edgeCount: $0.edgeCount
                )
            },
            warnings: warnings,
            sourceFingerprint: stableBatchSourceFingerprint(sourceNotes),
            targetFingerprint: stableBatchTargetManifestFingerprint(projectID: projectID),
            isError: false
        )
    }

    private func batchPreviewWithError(
        _ preview: AssistantChatWebBatchNotePlanPreview,
        message: String
    ) -> AssistantChatWebBatchNotePlanPreview {
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedWarnings = Array(
            Set((preview.warnings + [normalizedMessage]).filter { !$0.isEmpty })
        )
        return AssistantChatWebBatchNotePlanPreview(
            previewID: preview.previewID,
            sourceNotes: preview.sourceNotes,
            proposedNotes: preview.proposedNotes,
            proposedLinks: preview.proposedLinks,
            graph: preview.graph,
            warnings: mergedWarnings,
            sourceFingerprint: preview.sourceFingerprint,
            targetFingerprint: preview.targetFingerprint,
            isError: true
        )
    }

    private func requestBatchNotePlanPreview(
        projectID: String,
        sourceSelections: [AssistantChatWebBatchSourceNoteSelection]
    ) {
        let sourceNotes = resolveBatchNotePlanSourceContexts(
            projectID: projectID,
            selections: sourceSelections
        )
        guard !sourceNotes.isEmpty else {
            batchNotePlanPreviewByProjectID[projectID] = AssistantChatWebBatchNotePlanPreview(
                previewID: UUID().uuidString.lowercased(),
                sourceNotes: [],
                proposedNotes: [],
                proposedLinks: [],
                graph: nil,
                warnings: ["Select at least one source note first."],
                sourceFingerprint: "",
                targetFingerprint: stableBatchTargetManifestFingerprint(projectID: projectID),
                isError: true
            )
            return
        }

        let requestID = beginBatchNotePlanRequest(for: projectID)
        batchNotePlanPreviewByProjectID.removeValue(forKey: projectID)

        Task {
            let result = await MemoryEntryExplanationService.shared.generateBatchNotePlan(
                sourceNotes: sourceNotes
            )

            await MainActor.run {
                switch result {
                case .success(let draft):
                    let preview = buildBatchNotePlanPreview(
                        projectID: projectID,
                        sourceNotes: sourceNotes,
                        draft: draft
                    )
                    finishBatchNotePlanRequest(
                        for: projectID,
                        requestID: requestID,
                        preview: preview
                    )
                case .failure(let message):
                    finishBatchNotePlanRequest(
                        for: projectID,
                        requestID: requestID,
                        preview: AssistantChatWebBatchNotePlanPreview(
                            previewID: UUID().uuidString.lowercased(),
                            sourceNotes: sourceNotes.map { source in
                                AssistantChatWebBatchNotePlanSourceNote(
                                    ownerKind: source.target.ownerKind.rawValue,
                                    ownerID: source.target.ownerID,
                                    noteID: source.target.noteID,
                                    title: source.title,
                                    noteType: source.noteType.rawValue,
                                    sourceLabel: source.sourceLabel,
                                    markdown: source.markdown
                                )
                            },
                            proposedNotes: [],
                            proposedLinks: [],
                            graph: nil,
                            warnings: [message],
                            sourceFingerprint: stableBatchSourceFingerprint(sourceNotes),
                            targetFingerprint: stableBatchTargetManifestFingerprint(
                                projectID: projectID),
                            isError: true
                        )
                    )
                }
            }
        }
    }

    private func applyBatchNotePlanPreview(
        projectID: String,
        previewID: String,
        proposedNotes: [AssistantChatWebBatchNotePlanProposedNote],
        proposedLinks: [AssistantChatWebBatchNotePlanProposedLink]
    ) {
        guard let preview = batchNotePlanPreviewByProjectID[projectID],
            preview.previewID == previewID
        else {
            return
        }

        let currentSourceSelections = preview.sourceNotes.map {
            AssistantChatWebBatchSourceNoteSelection(
                ownerKind: $0.ownerKind,
                ownerID: $0.ownerID,
                noteID: $0.noteID
            )
        }
        let currentSourceNotes = resolveBatchNotePlanSourceContexts(
            projectID: projectID,
            selections: currentSourceSelections
        )
        guard stableBatchSourceFingerprint(currentSourceNotes) == preview.sourceFingerprint else {
            batchNotePlanPreviewByProjectID[projectID] = batchPreviewWithError(
                preview,
                message:
                    "One of the selected source notes changed after the preview. Refresh the preview and try again."
            )
            return
        }

        let currentTargetFingerprint = stableBatchTargetManifestFingerprint(projectID: projectID)
        guard currentTargetFingerprint == preview.targetFingerprint else {
            batchNotePlanPreviewByProjectID[projectID] = batchPreviewWithError(
                preview,
                message:
                    "The target project notes changed after the preview. Refresh the preview and try again."
            )
            return
        }

        let payloadNotesByTempID = Dictionary(
            uniqueKeysWithValues: proposedNotes.map {
                ($0.tempID.lowercased(), $0)
            })
        let mergedNotes = preview.proposedNotes.map {
            note -> AssistantChatWebBatchNotePlanProposedNote in
            let payload = payloadNotesByTempID[note.tempID.lowercased()]
            return AssistantChatWebBatchNotePlanProposedNote(
                tempID: note.tempID,
                title: payload?.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    .assistantNonEmpty ?? note.title,
                noteType: payload?.noteType ?? note.noteType,
                markdown: payload?.markdown ?? note.markdown,
                sourceNoteTargets: note.sourceNoteTargets,
                accepted: payload?.accepted ?? note.accepted
            )
        }

        let acceptedMasters = mergedNotes.filter {
            $0.accepted && $0.noteType == AssistantNoteType.master.rawValue
        }
        guard acceptedMasters.count == 1 else {
            batchNotePlanPreviewByProjectID[projectID] = batchPreviewWithError(
                preview,
                message: "Keep exactly one accepted master note before applying this plan."
            )
            return
        }

        for note in mergedNotes where AssistantNoteType.normalized(note.noteType) == nil {
            batchNotePlanPreviewByProjectID[projectID] = batchPreviewWithError(
                preview,
                message: "One of the proposed notes has an unsupported note type."
            )
            return
        }

        let payloadLinksByKey = Dictionary(
            uniqueKeysWithValues: proposedLinks.map {
                (batchPlanLinkKey(fromTempID: $0.fromTempID, toTarget: $0.toTarget), $0)
            })
        let mergedLinks = preview.proposedLinks.map {
            link -> AssistantChatWebBatchNotePlanProposedLink in
            let mergedTarget: AssistantChatWebBatchNotePlanResolvedTarget
            if link.toTarget.kind == AssistantBatchNotePlanLinkTargetKind.proposed.rawValue,
                let tempID = link.toTarget.tempID,
                let updatedNote = mergedNotes.first(where: {
                    $0.tempID.caseInsensitiveCompare(tempID) == .orderedSame
                })
            {
                mergedTarget = makeBatchProposedResolvedTarget(
                    tempID: updatedNote.tempID, title: updatedNote.title)
            } else {
                mergedTarget = link.toTarget
            }

            return AssistantChatWebBatchNotePlanProposedLink(
                fromTempID: link.fromTempID,
                toTarget: mergedTarget,
                accepted: payloadLinksByKey[
                    batchPlanLinkKey(fromTempID: link.fromTempID, toTarget: link.toTarget)]?
                    .accepted
                    ?? link.accepted
            )
        }

        let acceptedNotes = mergedNotes.filter(\.accepted)
        guard !acceptedNotes.isEmpty else {
            batchNotePlanPreviewByProjectID[projectID] = batchPreviewWithError(
                preview,
                message: "Accept at least one generated note before applying the plan."
            )
            return
        }

        let reservedTitles = Set(
            loadStoredNotes(for: AssistantNoteOwnerKey(kind: .project, id: projectID)).map(\.title)
        )
        let deduplicatedTitles = AssistantBatchNotePlanComposer.deduplicatedTitles(
            acceptedNotes.map(\.title),
            reservedTitles: reservedTitles
        )

        var finalTargetByTempID: [String: AssistantNoteLinkTarget] = [:]
        var finalTitleByTempID: [String: String] = [:]

        for (index, note) in acceptedNotes.enumerated() {
            guard let noteType = AssistantNoteType.normalized(note.noteType),
                let workspace = assistant.createProjectNote(
                    projectID: projectID,
                    title: deduplicatedTitles[index],
                    noteType: noteType,
                    selectNewNote: true
                ),
                let createdNote = workspace.selectedNote
            else {
                batchNotePlanPreviewByProjectID[projectID] = batchPreviewWithError(
                    preview,
                    message:
                        "Could not create one of the generated project notes. Please try again."
                )
                return
            }

            finalTargetByTempID[note.tempID.lowercased()] = AssistantNoteLinkTarget(
                ownerKind: .project,
                ownerID: projectID,
                noteID: createdNote.id
            )
            finalTitleByTempID[note.tempID.lowercased()] = deduplicatedTitles[index]
        }

        for note in acceptedNotes {
            guard let noteTarget = finalTargetByTempID[note.tempID.lowercased()] else {
                continue
            }

            let outgoingLinks = mergedLinks.filter {
                $0.accepted && $0.fromTempID.caseInsensitiveCompare(note.tempID) == .orderedSame
            }

            let sourceLinks = outgoingLinks.compactMap {
                link -> AssistantBatchNotePlanComposedLink? in
                guard link.toTarget.kind == AssistantBatchNotePlanLinkTargetKind.source.rawValue,
                    let ownerKindRaw = link.toTarget.ownerKind,
                    let ownerKind = AssistantNoteOwnerKind(rawValue: ownerKindRaw),
                    let ownerID = link.toTarget.ownerID,
                    let noteID = link.toTarget.noteID
                else {
                    return nil
                }
                let target = AssistantNoteLinkTarget(
                    ownerKind: ownerKind, ownerID: ownerID, noteID: noteID)
                return AssistantBatchNotePlanComposedLink(
                    title: link.toTarget.title,
                    href: AssistantNoteLinkCodec.urlString(for: target)
                )
            }

            let relatedLinks = outgoingLinks.compactMap {
                link -> AssistantBatchNotePlanComposedLink? in
                guard link.toTarget.kind == AssistantBatchNotePlanLinkTargetKind.proposed.rawValue,
                    let tempID = link.toTarget.tempID,
                    let target = finalTargetByTempID[tempID.lowercased()]
                else {
                    return nil
                }
                return AssistantBatchNotePlanComposedLink(
                    title: finalTitleByTempID[tempID.lowercased()] ?? link.toTarget.title,
                    href: AssistantNoteLinkCodec.urlString(for: target)
                )
            }

            let finalMarkdown = AssistantBatchNotePlanComposer.composeMarkdown(
                baseMarkdown: note.markdown,
                sourceLinks: sourceLinks,
                relatedLinks: relatedLinks
            )

            guard
                assistant.saveProjectNote(
                    projectID: projectID,
                    noteID: noteTarget.noteID,
                    text: finalMarkdown
                ) != nil
            else {
                batchNotePlanPreviewByProjectID[projectID] = batchPreviewWithError(
                    preview,
                    message: "Could not save one of the generated project notes. Please try again."
                )
                return
            }
        }

        let masterNote = acceptedMasters[0]
        let finalWorkspace =
            finalTargetByTempID[masterNote.tempID.lowercased()]
            .flatMap { assistant.selectProjectNote(projectID: projectID, noteID: $0.noteID) }
            ?? assistant.loadProjectNotesWorkspace(projectID: projectID)
        if let finalWorkspace {
            applyThreadNoteWorkspace(finalWorkspace)
        }
        clearBatchNotePlanState(for: projectID)
    }

    private func normalizeProjectNoteHeadingTitle(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"<!--[\s\S]*?-->"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedProjectNoteHeadingKey(_ value: String) -> String {
        normalizeProjectNoteHeadingTitle(value).lowercased()
    }

    private func projectNoteHeadingSections(in markdown: String) -> [ProjectNoteHeadingSection] {
        let normalizedMarkdown = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedMarkdown.components(separatedBy: "\n")
        let headingPattern = try? NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.+?)\s*$"#)
        struct PendingHeading {
            let title: String
            let normalizedTitle: String
            let level: Int
            let lineStartUTF16: Int
            let contentStartUTF16: Int
            let path: [String]
            let normalizedPath: [String]
        }

        var headings: [PendingHeading] = []
        var utf16Offset = 0
        var stack: [(level: Int, title: String, normalizedTitle: String)] = []

        for (index, line) in lines.enumerated() {
            let nsLine = line as NSString
            if let headingPattern,
                let match = headingPattern.firstMatch(
                    in: line,
                    range: NSRange(location: 0, length: nsLine.length)
                )
            {
                let hashes = nsLine.substring(with: match.range(at: 1))
                let rawTitle = nsLine.substring(with: match.range(at: 2))
                let title = normalizeProjectNoteHeadingTitle(rawTitle)
                if !title.isEmpty {
                    let normalizedTitle = normalizedProjectNoteHeadingKey(title)
                    while let last = stack.last, last.level >= hashes.count {
                        stack.removeLast()
                    }
                    let path = stack.map { $0.title } + [title]
                    let normalizedPath = stack.map { $0.normalizedTitle } + [normalizedTitle]
                    let newlineLength = index < lines.count - 1 ? 1 : 0
                    headings.append(
                        PendingHeading(
                            title: title,
                            normalizedTitle: normalizedTitle,
                            level: hashes.count,
                            lineStartUTF16: utf16Offset,
                            contentStartUTF16: utf16Offset + nsLine.length + newlineLength,
                            path: path,
                            normalizedPath: normalizedPath
                        )
                    )
                    stack.append(
                        (level: hashes.count, title: title, normalizedTitle: normalizedTitle))
                }
            }

            utf16Offset += nsLine.length
            if index < lines.count - 1 {
                utf16Offset += 1
            }
        }

        let textLength = (normalizedMarkdown as NSString).length
        return headings.enumerated().map { index, heading in
            let nextBoundary =
                headings.dropFirst(index + 1)
                .first(where: { $0.level <= heading.level })?
                .lineStartUTF16
                ?? textLength
            return ProjectNoteHeadingSection(
                title: heading.title,
                normalizedTitle: heading.normalizedTitle,
                level: heading.level,
                lineStartUTF16: heading.lineStartUTF16,
                contentStartUTF16: heading.contentStartUTF16,
                sectionEndUTF16: nextBoundary,
                path: heading.path,
                normalizedPath: heading.normalizedPath
            )
        }
    }

    private func projectNoteHeadingOutline(from sections: [ProjectNoteHeadingSection]) -> String {
        sections.map { section in
            let indent = String(repeating: "  ", count: max(0, section.path.count - 1))
            return "\(indent)- \(section.title)"
        }
        .joined(separator: "\n")
    }

    private func resolveProjectNoteHeadingSection(
        matching path: [String]?,
        in sections: [ProjectNoteHeadingSection]
    ) -> ProjectNoteHeadingSection? {
        let normalizedPath = path?
            .map(normalizedProjectNoteHeadingKey(_:))
            .filter { !$0.isEmpty }
        guard let normalizedPath, !normalizedPath.isEmpty else {
            return nil
        }

        let matches = sections.filter { $0.normalizedPath == normalizedPath }
        return matches.count == 1 ? matches[0] : nil
    }

    private func insertMarkdownBlock(
        into markdown: String,
        block: String,
        atUTF16Offset offset: Int
    ) -> String {
        let normalizedMarkdown = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmedBlock = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBlock.isEmpty else {
            return normalizedMarkdown
        }

        let nsMarkdown = normalizedMarkdown as NSString
        let safeOffset = max(0, min(offset, nsMarkdown.length))
        let prefix = nsMarkdown.substring(to: safeOffset)
        let suffix = nsMarkdown.substring(from: safeOffset)

        let leadingGap: String
        if prefix.isEmpty {
            leadingGap = ""
        } else if prefix.hasSuffix("\n\n") {
            leadingGap = ""
        } else if prefix.hasSuffix("\n") {
            leadingGap = "\n"
        } else {
            leadingGap = "\n\n"
        }

        let trailingGap: String
        if suffix.isEmpty {
            trailingGap = ""
        } else if suffix.hasPrefix("\n\n") {
            trailingGap = ""
        } else if suffix.hasPrefix("\n") {
            trailingGap = "\n"
        } else {
            trailingGap = "\n\n"
        }

        return prefix + leadingGap + trimmedBlock + trailingGap + suffix
    }

    private func mergedProjectNoteTransferText(
        currentText: String,
        preview: AssistantChatWebProjectNoteTransferPreview,
        placementChoice: String
    ) -> String {
        let normalizedCurrentText = currentText.replacingOccurrences(of: "\r\n", with: "\n")
        let sections = projectNoteHeadingSections(in: normalizedCurrentText)
        let shouldUseSuggestedPlacement = placementChoice == "suggested" && !preview.fallbackToEnd
        let targetSection =
            shouldUseSuggestedPlacement
            ? resolveProjectNoteHeadingSection(
                matching: preview.suggestedHeadingPath,
                in: sections
            )
            : nil
        let insertionOffset =
            targetSection?.sectionEndUTF16 ?? (normalizedCurrentText as NSString).length
        return insertMarkdownBlock(
            into: normalizedCurrentText,
            block: preview.insertedMarkdown,
            atUTF16Offset: insertionOffset
        )
    }

    private func threadNoteProjectTransferDestinationLabel(
        preview: AssistantChatWebProjectNoteTransferPreview,
        placementChoice: String
    ) -> String {
        if placementChoice == "suggested",
            !preview.fallbackToEnd,
            !preview.suggestedHeadingPath.isEmpty
        {
            return
                "\(preview.targetNoteTitle) → \(preview.suggestedHeadingPath.joined(separator: " / "))"
        }

        return "\(preview.targetNoteTitle) → end"
    }

    private func makeProjectNoteTransferPreview(
        targetProjectID: String,
        targetNote: AssistantStoredNote,
        suggestion: ProjectNoteTransferSuggestion?,
        selectedMarkdown: String,
        sourceFingerprint: String,
        targetFingerprint: String,
        blockingMessage: String? = nil,
        warningMessage: String? = nil
    ) -> AssistantChatWebProjectNoteTransferPreview {
        let insertedMarkdown =
            suggestion?.insertedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? selectedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let headingPath = suggestion?.headingPath ?? []
        let reason =
            blockingMessage
            ?? suggestion?.reason
            ?? "This content will be added to the end of the project note."

        return AssistantChatWebProjectNoteTransferPreview(
            targetProjectID: targetProjectID,
            targetNoteID: targetNote.noteID,
            targetNoteTitle: targetNote.title,
            suggestedHeadingPath: headingPath,
            insertedMarkdown: insertedMarkdown,
            reason: reason,
            fallbackToEnd: headingPath.isEmpty,
            sourceFingerprint: sourceFingerprint,
            targetFingerprint: targetFingerprint,
            isError: blockingMessage != nil,
            warningMessage: warningMessage
        )
    }

    private func requestProjectNoteTransferPreview(
        owner: AssistantNoteOwnerKey,
        sourceNoteID: String,
        sourceNoteTitle: String?,
        noteText: String,
        selectedMarkdown: String,
        targetProjectID: String,
        targetNoteID: String
    ) {
        guard owner.kind == .thread else {
            return
        }

        let normalizedSelectedMarkdown = selectedMarkdown.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !normalizedSelectedMarkdown.isEmpty else {
            let requestID = beginThreadNoteProjectTransferRequest(for: owner)
            let preview = AssistantChatWebProjectNoteTransferPreview(
                targetProjectID: targetProjectID,
                targetNoteID: targetNoteID,
                targetNoteTitle: "Project note",
                suggestedHeadingPath: [],
                insertedMarkdown: "",
                reason: "Select some note content first.",
                fallbackToEnd: true,
                sourceFingerprint: "",
                targetFingerprint: "",
                isError: true,
                warningMessage: nil
            )
            failThreadNoteProjectTransferRequest(for: owner, requestID: requestID, preview: preview)
            return
        }

        clearThreadNoteProjectTransferOutcome(for: owner)
        let requestID = beginThreadNoteProjectTransferRequest(for: owner)
        let targetOwner = AssistantNoteOwnerKey(kind: .project, id: targetProjectID)
        let targetNotes = assistant.loadProjectStoredNotes(projectID: targetProjectID)
        guard let targetNote = targetNotes.first(where: { $0.noteID == targetNoteID }) else {
            let preview = AssistantChatWebProjectNoteTransferPreview(
                targetProjectID: targetProjectID,
                targetNoteID: targetNoteID,
                targetNoteTitle: "Project note",
                suggestedHeadingPath: [],
                insertedMarkdown: "",
                reason: "That project note is no longer available.",
                fallbackToEnd: true,
                sourceFingerprint: "",
                targetFingerprint: "",
                isError: true,
                warningMessage: nil
            )
            failThreadNoteProjectTransferRequest(for: owner, requestID: requestID, preview: preview)
            return
        }

        let normalizedSourceText = noteText.replacingOccurrences(of: "\r\n", with: "\n")
        let targetNoteText = noteDraftText(for: targetOwner, noteID: targetNoteID)
        let sourceFingerprint = stableNoteFingerprint(normalizedSourceText)
        let targetFingerprint = stableNoteFingerprint(targetNoteText)
        let sections = projectNoteHeadingSections(in: targetNoteText)
        let headingOutline = projectNoteHeadingOutline(from: sections)

        Task {
            let result = await MemoryEntryExplanationService.shared.suggestProjectNoteTransfer(
                selectedMarkdown: normalizedSelectedMarkdown,
                sourceNoteTitle: sourceNoteTitle ?? "Untitled note",
                targetNoteTitle: targetNote.title,
                targetHeadingOutline: headingOutline,
                targetNoteText: targetNoteText
            )

            await MainActor.run {
                switch result {
                case .success(let suggestion):
                    let matchedSection = resolveProjectNoteHeadingSection(
                        matching: suggestion.headingPath,
                        in: sections
                    )
                    let preview = makeProjectNoteTransferPreview(
                        targetProjectID: targetProjectID,
                        targetNote: targetNote,
                        suggestion: ProjectNoteTransferSuggestion(
                            headingPath: matchedSection?.path,
                            insertedMarkdown: suggestion.insertedMarkdown,
                            reason: suggestion.reason
                        ),
                        selectedMarkdown: normalizedSelectedMarkdown,
                        sourceFingerprint: sourceFingerprint,
                        targetFingerprint: targetFingerprint,
                        warningMessage: matchedSection == nil
                            ? "AI could not find a safe section, so this will be added at the end."
                            : nil
                    )
                    finishThreadNoteProjectTransferRequest(
                        for: owner,
                        requestID: requestID,
                        preview: preview
                    )
                case .failure(let message):
                    let preview = makeProjectNoteTransferPreview(
                        targetProjectID: targetProjectID,
                        targetNote: targetNote,
                        suggestion: nil,
                        selectedMarkdown: normalizedSelectedMarkdown,
                        sourceFingerprint: sourceFingerprint,
                        targetFingerprint: targetFingerprint,
                        warningMessage: message
                    )
                    finishThreadNoteProjectTransferRequest(
                        for: owner,
                        requestID: requestID,
                        preview: preview
                    )
                }
            }
        }
    }

    private func applyProjectNoteTransfer(
        owner: AssistantNoteOwnerKey,
        sourceNoteID: String,
        transferMode: String,
        placementChoice: String,
        sourceFingerprint: String,
        targetFingerprint: String,
        sourceTextAfterMove: String?
    ) {
        let storageKey = owner.storageKey
        guard owner.kind == .thread,
            let preview = threadNoteProjectTransferPreviewByOwnerKey[storageKey]
        else {
            return
        }

        let currentSourceText = noteDraftText(for: owner, noteID: sourceNoteID)
        guard stableNoteFingerprint(currentSourceText) == sourceFingerprint,
            preview.sourceFingerprint == sourceFingerprint
        else {
            threadNoteProjectTransferPreviewByOwnerKey[storageKey] =
                AssistantChatWebProjectNoteTransferPreview(
                    targetProjectID: preview.targetProjectID,
                    targetNoteID: preview.targetNoteID,
                    targetNoteTitle: preview.targetNoteTitle,
                    suggestedHeadingPath: preview.suggestedHeadingPath,
                    insertedMarkdown: preview.insertedMarkdown,
                    reason:
                        "This thread note changed after the preview. Refresh the preview and try again.",
                    fallbackToEnd: preview.fallbackToEnd,
                    sourceFingerprint: preview.sourceFingerprint,
                    targetFingerprint: preview.targetFingerprint,
                    isError: true,
                    warningMessage: nil
                )
            return
        }

        let targetOwner = AssistantNoteOwnerKey(kind: .project, id: preview.targetProjectID)
        let currentTargetText = noteDraftText(for: targetOwner, noteID: preview.targetNoteID)
        guard stableNoteFingerprint(currentTargetText) == targetFingerprint,
            preview.targetFingerprint == targetFingerprint
        else {
            threadNoteProjectTransferPreviewByOwnerKey[storageKey] =
                AssistantChatWebProjectNoteTransferPreview(
                    targetProjectID: preview.targetProjectID,
                    targetNoteID: preview.targetNoteID,
                    targetNoteTitle: preview.targetNoteTitle,
                    suggestedHeadingPath: preview.suggestedHeadingPath,
                    insertedMarkdown: preview.insertedMarkdown,
                    reason:
                        "That project note changed after the preview. Refresh the preview and try again.",
                    fallbackToEnd: preview.fallbackToEnd,
                    sourceFingerprint: preview.sourceFingerprint,
                    targetFingerprint: preview.targetFingerprint,
                    isError: true,
                    warningMessage: nil
                )
            return
        }

        let mergedTargetText = mergedProjectNoteTransferText(
            currentText: currentTargetText,
            preview: preview,
            placementChoice: placementChoice
        )
        let persistedTargetText = noteMarkdownForPersistence(
            owner: targetOwner,
            noteID: preview.targetNoteID,
            text: mergedTargetText
        )
        guard
            let targetWorkspace = assistant.saveProjectNote(
                projectID: preview.targetProjectID,
                noteID: preview.targetNoteID,
                text: persistedTargetText
            )
        else {
            threadNoteProjectTransferPreviewByOwnerKey[storageKey] =
                AssistantChatWebProjectNoteTransferPreview(
                    targetProjectID: preview.targetProjectID,
                    targetNoteID: preview.targetNoteID,
                    targetNoteTitle: preview.targetNoteTitle,
                    suggestedHeadingPath: preview.suggestedHeadingPath,
                    insertedMarkdown: preview.insertedMarkdown,
                    reason: "Could not save the target project note. Please try again.",
                    fallbackToEnd: preview.fallbackToEnd,
                    sourceFingerprint: preview.sourceFingerprint,
                    targetFingerprint: preview.targetFingerprint,
                    isError: true,
                    warningMessage: nil
                )
            return
        }
        applyThreadNoteWorkspace(targetWorkspace)

        let destinationLabel = threadNoteProjectTransferDestinationLabel(
            preview: preview,
            placementChoice: placementChoice
        )

        if transferMode == "move" {
            let nextSourceText = sourceTextAfterMove?
                .replacingOccurrences(of: "\r\n", with: "\n")
            let persistedSourceText = nextSourceText.map {
                noteMarkdownForPersistence(
                    owner: owner,
                    noteID: sourceNoteID,
                    text: $0
                )
            }
            guard let persistedSourceText,
                let sourceWorkspace = assistant.saveThreadNote(
                    threadID: owner.id,
                    noteID: sourceNoteID,
                    text: persistedSourceText
                )
            else {
                clearThreadNoteProjectTransferState(for: owner)
                setThreadNoteProjectTransferOutcome(
                    for: owner,
                    kind: "warning",
                    message:
                        "Added this content to \(destinationLabel), but the original text is still in the thread note because saving the source note failed."
                )
                return
            }
            applyThreadNoteWorkspace(sourceWorkspace)
            clearThreadNoteProjectTransferState(for: owner)
            setThreadNoteProjectTransferOutcome(
                for: owner,
                kind: "success",
                message: "Moved this note content to \(destinationLabel)."
            )
            return
        }

        clearThreadNoteProjectTransferState(for: owner)
        setThreadNoteProjectTransferOutcome(
            for: owner,
            kind: "success",
            message: "Copied this note content to \(destinationLabel)."
        )
    }

    @discardableResult
    private func beginThreadNoteAIDraftRequest(
        for owner: AssistantNoteOwnerKey,
        mode: String,
        clearsChartContext: Bool = false
    ) -> UUID {
        let requestID = UUID()
        let storageKey = owner.storageKey
        threadNoteGeneratingAIDraftOwnerKeys.insert(storageKey)
        threadNoteAIDraftModeByOwnerKey[storageKey] = mode
        threadNoteAIDraftRequestIDByOwnerKey[storageKey] = requestID
        if clearsChartContext {
            threadNoteChartContextByOwnerKey.removeValue(forKey: storageKey)
        }
        return requestID
    }

    private func finishThreadNoteAIDraftRequest(
        for owner: AssistantNoteOwnerKey,
        requestID: UUID,
        preview: AssistantChatWebThreadNoteAIPreview
    ) {
        let storageKey = owner.storageKey
        guard threadNoteAIDraftRequestIDByOwnerKey[storageKey] == requestID else {
            return
        }
        threadNoteAIDraftPreviewByOwnerKey[storageKey] = preview
        threadNoteGeneratingAIDraftOwnerKeys.remove(storageKey)
    }

    private func failThreadNoteAIDraftRequest(
        for owner: AssistantNoteOwnerKey,
        requestID: UUID,
        mode: String,
        sourceKind: String,
        message: String
    ) {
        let storageKey = owner.storageKey
        guard threadNoteAIDraftRequestIDByOwnerKey[storageKey] == requestID else {
            return
        }
        threadNoteAIDraftPreviewByOwnerKey[storageKey] = AssistantChatWebThreadNoteAIPreview(
            mode: mode,
            sourceKind: sourceKind,
            markdown: message,
            isError: true
        )
        threadNoteGeneratingAIDraftOwnerKeys.remove(storageKey)
    }

    @discardableResult
    private func ensureSelectedNotesWorkspace(
        for owner: AssistantNoteOwnerKey
    ) -> AssistantNotesWorkspace? {
        let existingWorkspace = loadNotesWorkspace(for: owner)
        if existingWorkspace?.selectedNote != nil {
            if let existingWorkspace {
                applyThreadNoteWorkspace(existingWorkspace)
            }
            return existingWorkspace
        }

        let createdWorkspace: AssistantNotesWorkspace?
        switch owner.kind {
        case .thread:
            createdWorkspace = assistant.createThreadNote(threadID: owner.id)
        case .project:
            createdWorkspace = assistant.createProjectNote(projectID: owner.id, title: nil)
        }
        guard let createdWorkspace else {
            return existingWorkspace
        }
        applyThreadNoteWorkspace(createdWorkspace)
        return createdWorkspace
    }

    private func prepareProjectNotesWorkspace(for project: AssistantProject) {
        let owner = AssistantNoteOwnerKey(kind: .project, id: project.id)
        threadNoteViewMode = "edit"
        isThreadNoteOpen = true
        _ = ensureSelectedNotesWorkspace(for: owner)
    }

    private func resolvedThreadNoteOwner(
        from command: AssistantChatWebThreadNoteCommand,
        resolvedThreadID: String?
    ) -> AssistantNoteOwnerKey? {
        if let ownerKind = command.ownerKind.flatMap(AssistantNoteOwnerKind.init(rawValue:)),
            let ownerID = command.ownerID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        {
            return AssistantNoteOwnerKey(kind: ownerKind, id: ownerID)
        }

        if isNotesPaneActive,
            let project = selectedNotesProject,
            let currentTarget = currentNotesSelectionTarget(
                project: project, scope: selectedNotesScope)
        {
            return AssistantNoteOwnerKey(kind: currentTarget.ownerKind, id: currentTarget.ownerID)
        }

        if isNotesPaneActive,
            selectedNotesScope == .project,
            let project = selectedNotesProject
        {
            return AssistantNoteOwnerKey(kind: .project, id: project.id)
        }

        if let project = currentProjectNotesProject {
            return AssistantNoteOwnerKey(kind: .project, id: project.id)
        }

        guard let resolvedThreadID else {
            return nil
        }

        let availableOwners = availableNoteOwners(for: resolvedThreadID)
        if let selectedOwner = selectedNoteOwnerByThreadID[resolvedThreadID],
            availableOwners.contains(selectedOwner)
        {
            return selectedOwner
        }
        return availableOwners.first
    }

    private func updateSelectedNoteOwner(
        _ owner: AssistantNoteOwnerKey,
        threadID: String?
    ) {
        guard !isNotesPaneActive else {
            return
        }

        guard let threadID,
            currentProjectNotesProject == nil
        else {
            return
        }
        selectedNoteOwnerByThreadID[threadID] = owner
    }

    private func syncThreadNoteSelection(_ sessionID: String?, persistCurrent: Bool) {
        if persistCurrent {
            persistThreadNoteIfNeeded(for: currentThreadNoteOwner)
        }

        let nextThreadID = sessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .lowercased()
        activeThreadNoteThreadID = nextThreadID

        guard let nextThreadID else {
            isThreadNoteOpen = false
            return
        }

        let defaultOwner = AssistantNoteOwnerKey(kind: .thread, id: nextThreadID)
        let availableOwners = availableNoteOwners(for: nextThreadID)
        if let selectedOwner = selectedNoteOwnerByThreadID[nextThreadID],
            availableOwners.contains(selectedOwner)
        {
            // Keep the user's last note source for this thread.
        } else {
            selectedNoteOwnerByThreadID[nextThreadID] = defaultOwner
        }

        if noteManifestByOwnerKey[defaultOwner.storageKey] == nil,
            let workspace = assistant.loadThreadNotesWorkspace(threadID: nextThreadID)
        {
            applyThreadNoteWorkspace(workspace)
        }
    }

    @discardableResult
    private func persistThreadNoteIfNeeded(
        for owner: AssistantNoteOwnerKey?,
        noteID: String? = nil,
        forceHistorySnapshot: Bool = true,
        requestID: String? = nil,
        draftRevision: Int? = nil,
        explicitText: String? = nil,
        sourceContainer: AssistantChatWebContainerView? = nil
    ) -> Bool {
        guard let owner else {
            if let requestID {
                // We can't resolve an owner, so there's nothing to
                // persist — but we still need to ack so the JS side
                // doesn't time out.
                sendThreadNoteSaveAck(
                    AssistantChatWebThreadNoteSaveAck(
                        requestID: requestID,
                        ownerKind: nil,
                        ownerID: nil,
                        noteID: nil,
                        draftRevision: draftRevision,
                        status: "error",
                        errorMessage: "Open Assist could not find the note owner for this save."
                    ),
                    sourceContainer: sourceContainer
                )
                return false
            }
            return true
        }

        let manifest = noteManifest(for: owner)
        let resolvedNoteID = noteID ?? currentSelectedThreadNoteNoteID ?? manifest.selectedNote?.id
        guard let resolvedNoteID else {
            if let requestID {
                sendThreadNoteSaveAck(
                    AssistantChatWebThreadNoteSaveAck(
                        requestID: requestID,
                        ownerKind: owner.kind.rawValue,
                        ownerID: owner.id,
                        noteID: nil,
                        draftRevision: draftRevision,
                        status: "error",
                        errorMessage: "Open Assist could not find a note to save."
                    ),
                    sourceContainer: sourceContainer
                )
                return false
            }
            return true
        }

        let draftText: String
        if let explicitText {
            draftText = explicitText
        } else if let storedDraft = noteDraftStore.draft(
            ownerKey: owner.storageKey,
            noteID: resolvedNoteID
        ) {
            draftText = storedDraft
        } else {
            if let requestID {
                sendThreadNoteSaveAck(
                    AssistantChatWebThreadNoteSaveAck(
                        requestID: requestID,
                        ownerKind: owner.kind.rawValue,
                        ownerID: owner.id,
                        noteID: resolvedNoteID,
                        draftRevision: draftRevision,
                        status: "error",
                        errorMessage:
                            "Open Assist could not find a draft to save for this note."
                    ),
                    sourceContainer: sourceContainer
                )
                return false
            }
            return true
        }

        let persistedDraftText = noteMarkdownForPersistence(
            owner: owner,
            noteID: resolvedNoteID,
            text: draftText
        )

        let storageKey = threadNoteStorageKey(owner: owner, noteID: resolvedNoteID)
        threadNoteSavingNoteKeys.insert(storageKey)
        defer {
            DispatchQueue.main.async {
                threadNoteSavingNoteKeys.remove(storageKey)
            }
        }

        let saveResult: Result<AssistantNotesWorkspace, AssistantNoteSaveError>
        switch owner.kind {
        case .thread:
            saveResult = assistant.saveThreadNoteResult(
                threadID: owner.id,
                noteID: resolvedNoteID,
                text: persistedDraftText,
                forceHistorySnapshot: forceHistorySnapshot
            )
        case .project:
            saveResult = assistant.saveProjectNoteResult(
                projectID: owner.id,
                noteID: resolvedNoteID,
                text: persistedDraftText,
                forceHistorySnapshot: forceHistorySnapshot
            )
        }

        switch saveResult {
        case .success(let workspace):
            applyThreadNoteWorkspace(workspace)
            // Step 5: the content is now safely on disk in the real
            // notes store. Delete the draft backup so we don't offer
            // stale recovery on next relaunch.
            noteDraftStore.clearPersistedDraftIfCurrent(
                ownerKey: owner.storageKey,
                noteID: resolvedNoteID,
                expectedText: draftText,
                savedRevision: draftRevision
            )
            if let requestID {
                sendThreadNoteSaveAck(
                    AssistantChatWebThreadNoteSaveAck(
                        requestID: requestID,
                        ownerKind: owner.kind.rawValue,
                        ownerID: owner.id,
                        noteID: resolvedNoteID,
                        draftRevision: draftRevision,
                        status: "ok",
                        errorMessage: nil
                    ),
                    sourceContainer: sourceContainer
                )
            }
            return true
        case .failure(let error):
            if let requestID {
                sendThreadNoteSaveAck(
                    AssistantChatWebThreadNoteSaveAck(
                        requestID: requestID,
                        ownerKind: owner.kind.rawValue,
                        ownerID: owner.id,
                        noteID: resolvedNoteID,
                        draftRevision: draftRevision,
                        status: "error",
                        errorMessage: error.errorDescription
                            ?? "Open Assist could not save this note."
                    ),
                    sourceContainer: sourceContainer
                )
            }
            return false
        }

    }

    /// Route a save-ack to all live web containers (so both the chat
    /// timeline and the drawer, if separately mounted, get the result).
    private func sendThreadNoteSaveAck(
        _ ack: AssistantChatWebThreadNoteSaveAck,
        sourceContainer: AssistantChatWebContainerView?
    ) {
        let candidateContainers = [
            sourceContainer, threadNoteWebContainer, chatTimelineWebContainer,
        ]
        var delivered = Set<ObjectIdentifier>()
        for container in candidateContainers {
            guard let container else { continue }
            let identity = ObjectIdentifier(container)
            guard delivered.insert(identity).inserted else { continue }
            container.applyThreadNoteSaveAck(ack)
        }
    }

    private func selectNotesWorkspace(
        for owner: AssistantNoteOwnerKey,
        noteID: String
    ) -> AssistantNotesWorkspace? {
        switch owner.kind {
        case .thread:
            return assistant.selectThreadNote(
                threadID: owner.id,
                noteID: noteID
            )
        case .project:
            return assistant.selectProjectNote(
                projectID: owner.id,
                noteID: noteID
            )
        }
    }

    private func openLinkedNote(
        owner: AssistantNoteOwnerKey,
        noteID: String,
        resolvedThreadID: String?
    ) {
        if currentDisplayedNoteTarget
            == AssistantNoteLinkTarget(
                ownerKind: owner.kind,
                ownerID: owner.id,
                noteID: noteID
            )
        {
            return
        }
        persistThreadNoteIfNeeded(for: currentThreadNoteOwner)
        pushCurrentNoteOntoNavigationStack(for: resolvedThreadID)
        guard let workspace = selectNotesWorkspace(for: owner, noteID: noteID) else {
            return
        }
        applyThreadNoteWorkspace(workspace)
        clearThreadNoteAIDraftState(for: owner)
        if isNotesPaneActive,
            let project = notesProject(for: owner)
        {
            selectedNotesProjectID = project.id
            selectedNotesScope = owner.kind == .project ? .project : .thread
            rememberNotesSelectionTarget(
                AssistantNoteLinkTarget(ownerKind: owner.kind, ownerID: owner.id, noteID: noteID),
                projectID: project.id,
                scope: selectedNotesScope
            )
        } else {
            updateSelectedNoteOwner(owner, threadID: resolvedThreadID)
        }
        isThreadNoteOpen = true
    }

    private func navigateBackToLinkedNote(resolvedThreadID: String?) {
        persistThreadNoteIfNeeded(for: currentThreadNoteOwner)
        while let entry = popThreadNoteNavigationEntry(for: resolvedThreadID) {
            guard let workspace = selectNotesWorkspace(for: entry.owner, noteID: entry.noteID)
            else {
                continue
            }
            applyThreadNoteWorkspace(workspace)
            clearThreadNoteAIDraftState(for: entry.owner)
            if isNotesPaneActive,
                let project = notesProject(for: entry.owner)
            {
                selectedNotesProjectID = project.id
                selectedNotesScope = entry.owner.kind == .project ? .project : .thread
                rememberNotesSelectionTarget(
                    AssistantNoteLinkTarget(
                        ownerKind: entry.owner.kind,
                        ownerID: entry.owner.id,
                        noteID: entry.noteID
                    ),
                    projectID: project.id,
                    scope: selectedNotesScope
                )
            } else {
                updateSelectedNoteOwner(entry.owner, threadID: resolvedThreadID)
            }
            isThreadNoteOpen = true
            return
        }
    }

    private func toggleThreadNoteDrawer() {
        if isThreadNoteOpen {
            persistThreadNoteIfNeeded(for: currentThreadNoteOwner)
        } else {
            syncThreadNoteSelection(assistant.selectedSessionID, persistCurrent: false)
            isThreadNoteExpanded = false
        }
        isThreadNoteOpen.toggle()
    }

    private func sendThreadNoteImageUploadResult(
        _ result: AssistantChatWebThreadNoteImageUploadResult,
        sourceContainer: AssistantChatWebContainerView?
    ) {
        let candidateContainers = [
            sourceContainer, threadNoteWebContainer, chatTimelineWebContainer,
        ]
        var delivered = Set<ObjectIdentifier>()

        for container in candidateContainers {
            guard let container else { continue }
            let identity = ObjectIdentifier(container)
            guard delivered.insert(identity).inserted else { continue }
            container.applyThreadNoteImageUploadResult(result)
        }
    }

    private func sendThreadNoteScreenshotCaptureResult(
        _ result: AssistantChatWebThreadNoteScreenshotCaptureResult,
        sourceContainer: AssistantChatWebContainerView?
    ) {
        let candidateContainers = [
            sourceContainer, threadNoteWebContainer, chatTimelineWebContainer,
        ]
        var delivered = Set<ObjectIdentifier>()

        for container in candidateContainers {
            guard let container else { continue }
            let identity = ObjectIdentifier(container)
            guard delivered.insert(identity).inserted else { continue }
            container.applyThreadNoteScreenshotCaptureResult(result)
        }
    }

    private func sendThreadNoteScreenshotProcessingResult(
        _ result: AssistantChatWebThreadNoteScreenshotProcessingResult,
        sourceContainer: AssistantChatWebContainerView?
    ) {
        let candidateContainers = [
            sourceContainer, threadNoteWebContainer, chatTimelineWebContainer,
        ]
        var delivered = Set<ObjectIdentifier>()

        for container in candidateContainers {
            guard let container else { continue }
            let identity = ObjectIdentifier(container)
            guard delivered.insert(identity).inserted else { continue }
            container.applyThreadNoteScreenshotProcessingResult(result)
        }
    }

    private func handleThreadNoteCommand(
        _ command: AssistantChatWebThreadNoteCommand,
        sourceContainer: AssistantChatWebContainerView? = nil
    ) {
        let resolvedThreadID =
            command.threadID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .lowercased() ?? selectedThreadNoteID
        let resolvedOwner = resolvedThreadNoteOwner(
            from: command, resolvedThreadID: resolvedThreadID)
        let resolvedNoteID =
            command.noteID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? currentSelectedThreadNoteNoteID
            ?? resolvedOwner.flatMap { noteManifest(for: $0).selectedNote?.id }

        if let resolvedOwner {
            updateSelectedNoteOwner(resolvedOwner, threadID: resolvedThreadID)
        }

        switch command.type {
        case "pasteImageFromClipboard":
            let requestID = command.requestID ?? UUID().uuidString.lowercased()
            let sendImageUploadResult = { (result: AssistantChatWebThreadNoteImageUploadResult) in
                sendThreadNoteImageUploadResult(result, sourceContainer: sourceContainer)
            }

            guard let resolvedOwner,
                let resolvedNoteID
            else {
                sendImageUploadResult(
                    AssistantChatWebThreadNoteImageUploadResult(
                        requestID: requestID,
                        ok: false,
                        message: "Open a note before adding an image.",
                        url: nil,
                        relativePath: nil
                    )
                )
                return
            }

            guard let attachment = AssistantAttachmentSupport.attachment(
                fromPasteboard: NSPasteboard.general
            ) else {
                sendImageUploadResult(
                    AssistantChatWebThreadNoteImageUploadResult(
                        requestID: requestID,
                        ok: false,
                        message: "I could not find an image on the clipboard.",
                        url: nil,
                        relativePath: nil
                    )
                )
                return
            }

            let savedAsset: AssistantSavedNoteAsset?
            switch resolvedOwner.kind {
            case .thread:
                savedAsset = assistant.saveThreadNoteImageAsset(
                    threadID: resolvedOwner.id,
                    noteID: resolvedNoteID,
                    attachment: attachment
                )
            case .project:
                savedAsset = assistant.saveProjectNoteImageAsset(
                    projectID: resolvedOwner.id,
                    noteID: resolvedNoteID,
                    attachment: attachment
                )
            }

            guard let savedAsset,
                let displayURL = AssistantNoteAssetSupport.displayURL(
                    ownerKind: resolvedOwner.kind,
                    ownerID: resolvedOwner.id,
                    noteID: resolvedNoteID,
                    relativePath: savedAsset.relativePath
                )?.absoluteString
            else {
                sendImageUploadResult(
                    AssistantChatWebThreadNoteImageUploadResult(
                        requestID: requestID,
                        ok: false,
                        message: "Open Assist could not save that clipboard image.",
                        url: nil,
                        relativePath: nil
                    )
                )
                return
            }

            sendImageUploadResult(
                AssistantChatWebThreadNoteImageUploadResult(
                    requestID: requestID,
                    ok: true,
                    message: nil,
                    url: displayURL,
                    relativePath: savedAsset.relativePath
                )
            )
        case "saveImageAsset":
            let requestID = command.requestID ?? UUID().uuidString.lowercased()
            let sendImageUploadResult = { (result: AssistantChatWebThreadNoteImageUploadResult) in
                sendThreadNoteImageUploadResult(result, sourceContainer: sourceContainer)
            }

            guard let resolvedOwner,
                let resolvedNoteID
            else {
                sendImageUploadResult(
                    AssistantChatWebThreadNoteImageUploadResult(
                        requestID: requestID,
                        ok: false,
                        message: "Open a note before adding an image.",
                        url: nil,
                        relativePath: nil
                    )
                )
                return
            }

            guard let dataURL = command.dataURL,
                let attachment = AssistantAttachmentSupport.attachment(
                    fromDataURL: dataURL,
                    suggestedFilename: command.filename
                )
            else {
                sendImageUploadResult(
                    AssistantChatWebThreadNoteImageUploadResult(
                        requestID: requestID,
                        ok: false,
                        message: "Open Assist could not read that image file.",
                        url: nil,
                        relativePath: nil
                    )
                )
                return
            }

            let resolvedMimeType = command.mimeType ?? attachment.mimeType
            guard AssistantNoteAssetSupport.isSupportedImageMimeType(resolvedMimeType) else {
                sendImageUploadResult(
                    AssistantChatWebThreadNoteImageUploadResult(
                        requestID: requestID,
                        ok: false,
                        message: "Use PNG, JPG, GIF, WebP, or TIFF images here.",
                        url: nil,
                        relativePath: nil
                    )
                )
                return
            }

            let savedAsset: AssistantSavedNoteAsset?
            switch resolvedOwner.kind {
            case .thread:
                savedAsset = assistant.saveThreadNoteImageAsset(
                    threadID: resolvedOwner.id,
                    noteID: resolvedNoteID,
                    attachment: attachment
                )
            case .project:
                savedAsset = assistant.saveProjectNoteImageAsset(
                    projectID: resolvedOwner.id,
                    noteID: resolvedNoteID,
                    attachment: attachment
                )
            }

            guard let savedAsset,
                let displayURL = AssistantNoteAssetSupport.displayURL(
                    ownerKind: resolvedOwner.kind,
                    ownerID: resolvedOwner.id,
                    noteID: resolvedNoteID,
                    relativePath: savedAsset.relativePath
                )?.absoluteString
            else {
                sendImageUploadResult(
                    AssistantChatWebThreadNoteImageUploadResult(
                        requestID: requestID,
                        ok: false,
                        message: "Open Assist could not save that note image.",
                        url: nil,
                        relativePath: nil
                    )
                )
                return
            }

            sendImageUploadResult(
                AssistantChatWebThreadNoteImageUploadResult(
                    requestID: requestID,
                    ok: true,
                    message: nil,
                    url: displayURL,
                    relativePath: savedAsset.relativePath
                )
            )
        case "captureScreenshotImport":
            let requestID = command.requestID ?? UUID().uuidString.lowercased()
            let captureMode = ThreadNoteScreenshotCaptureMode(rawValue: command.captureMode ?? "")
                ?? .area
            let sendCaptureResult = { (result: AssistantChatWebThreadNoteScreenshotCaptureResult) in
                sendThreadNoteScreenshotCaptureResult(result, sourceContainer: sourceContainer)
            }

            guard resolvedOwner != nil, resolvedNoteID != nil else {
                sendCaptureResult(
                    AssistantChatWebThreadNoteScreenshotCaptureResult(
                        requestID: requestID,
                        ok: false,
                        cancelled: false,
                        message: "Open a note before adding a screenshot.",
                        captureMode: captureMode.rawValue,
                        segmentCount: nil,
                        filename: nil,
                        mimeType: nil,
                        dataURL: nil
                    )
                )
                return
            }

            Task { @MainActor in
                let result = await captureThreadNoteScreenshotImport(
                    requestID: requestID,
                    captureMode: captureMode
                )
                sendCaptureResult(result)
            }
        case "processScreenshotImport":
            let requestID = command.requestID ?? UUID().uuidString.lowercased()
            let captureMode = ThreadNoteScreenshotCaptureMode(rawValue: command.captureMode ?? "")
                ?? .area
            let captureSegmentCount = max(1, command.captureSegmentCount ?? 1)
            let sendProcessingResult = {
                (result: AssistantChatWebThreadNoteScreenshotProcessingResult) in
                sendThreadNoteScreenshotProcessingResult(result, sourceContainer: sourceContainer)
            }

            guard resolvedOwner != nil, resolvedNoteID != nil else {
                sendProcessingResult(
                    AssistantChatWebThreadNoteScreenshotProcessingResult(
                            requestID: requestID,
                            ok: false,
                            message: "Open a note before adding a screenshot.",
                            outputMode: command.outputMode,
                            markdown: nil,
                        rawText: nil,
                        usedVision: false
                    )
                )
                return
            }

            guard let dataURL = command.dataURL,
                  let attachment = AssistantAttachmentSupport.attachment(
                    fromDataURL: dataURL,
                    suggestedFilename: command.filename
                  ) else {
                sendProcessingResult(
                    AssistantChatWebThreadNoteScreenshotProcessingResult(
                        requestID: requestID,
                        ok: false,
                        message: "Open Assist could not read the captured screenshot.",
                        outputMode: command.outputMode,
                        markdown: nil,
                        rawText: nil,
                        usedVision: false
                    )
                )
                return
            }

            guard let outputModeRaw = command.outputMode,
                  let outputMode = ThreadNoteScreenshotImportMode(rawValue: outputModeRaw) else {
                sendProcessingResult(
                    AssistantChatWebThreadNoteScreenshotProcessingResult(
                        requestID: requestID,
                        ok: false,
                        message: "Choose how the screenshot should be imported first.",
                        outputMode: command.outputMode,
                        markdown: nil,
                        rawText: nil,
                        usedVision: false
                    )
                )
                return
            }

            Task { @MainActor in
                let result = await MemoryEntryExplanationService.shared.prepareThreadNoteScreenshotImport(
                    attachment: attachment,
                    outputMode: outputMode,
                    styleInstruction: command.styleInstruction,
                    captureMode: captureMode,
                    segmentCount: captureSegmentCount
                )

                switch result {
                case .success(let preparation):
                    sendProcessingResult(
                        AssistantChatWebThreadNoteScreenshotProcessingResult(
                            requestID: requestID,
                            ok: true,
                            message: nil,
                            outputMode: outputMode.rawValue,
                            markdown: preparation.markdown,
                            rawText: preparation.rawText,
                            usedVision: preparation.usedVision
                        )
                    )
                case .failure(let message):
                    sendProcessingResult(
                        AssistantChatWebThreadNoteScreenshotProcessingResult(
                            requestID: requestID,
                            ok: false,
                            message: message,
                            outputMode: outputMode.rawValue,
                            markdown: nil,
                            rawText: nil,
                            usedVision: false
                        )
                    )
                }
            }
        case "setOpen":
            if isNotesPaneActive {
                return
            }
            guard let isOpen = command.isOpen else { return }
            if !isOpen, currentProjectNotesProject != nil {
                closeProjectNotesIfNeeded()
                return
            }
            if !isOpen {
                persistThreadNoteIfNeeded(for: resolvedOwner)
            } else {
                syncThreadNoteSelection(resolvedThreadID, persistCurrent: false)
            }
            isThreadNoteOpen = isOpen
        case "setExpanded":
            guard let isExpanded = command.isExpanded else { return }
            isThreadNoteExpanded = isExpanded
        case "setViewMode":
            guard
                let viewMode = command.viewMode?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else { return }
            threadNoteViewMode = viewMode
        case "selectNote":
            if isNotesPaneActive, notesWorkspaceExternalMarkdownFile != nil {
                switchAwayFromExternalMarkdownFileIfNeeded {
                    handleThreadNoteCommand(command, sourceContainer: sourceContainer)
                }
                return
            }
            persistThreadNoteIfNeeded(for: currentThreadNoteOwner)
            guard let resolvedOwner,
                let resolvedNoteID
            else { return }
            clearThreadNoteNavigationStack(for: resolvedThreadID)
            let workspace = selectNotesWorkspace(for: resolvedOwner, noteID: resolvedNoteID)
            guard let workspace else { return }
            applyThreadNoteWorkspace(workspace)
            clearThreadNoteAIDraftState(for: resolvedOwner)
            clearThreadNoteProjectTransferState(for: resolvedOwner)
            clearThreadNoteProjectTransferOutcome(for: resolvedOwner)
            if isNotesPaneActive,
                let project = notesProject(for: resolvedOwner)
            {
                let scope: AssistantNotesScope = resolvedOwner.kind == .project ? .project : .thread
                selectedNotesProjectID = project.id
                selectedNotesScope = scope
                rememberNotesSelectionTarget(
                    AssistantNoteLinkTarget(
                        ownerKind: resolvedOwner.kind,
                        ownerID: resolvedOwner.id,
                        noteID: resolvedNoteID
                    ),
                    projectID: project.id,
                    scope: scope
                )
            }
        case "openLinkedNote":
            guard let resolvedOwner,
                let resolvedNoteID
            else {
                return
            }
            openLinkedNote(
                owner: resolvedOwner,
                noteID: resolvedNoteID,
                resolvedThreadID: resolvedThreadID
            )
            clearThreadNoteProjectTransferState(for: resolvedOwner)
            clearThreadNoteProjectTransferOutcome(for: resolvedOwner)
        case "goBackLinkedNote":
            navigateBackToLinkedNote(resolvedThreadID: resolvedThreadID)
        case "showNoteMenu":
            guard let resolvedThreadID,
                let anchorRect = command.viewportRect
            else { return }
            presentThreadNoteMenu(threadID: resolvedThreadID, anchorRect: anchorRect)
        case "openMarkdownFile":
            presentOpenMarkdownFilePanel()
        case "closeMarkdownFile":
            closeExternalMarkdownFile()
        case "createNote":
            if isNotesPaneActive, notesWorkspaceExternalMarkdownFile != nil {
                switchAwayFromExternalMarkdownFileIfNeeded {
                    handleThreadNoteCommand(command, sourceContainer: sourceContainer)
                }
                return
            }
            persistThreadNoteIfNeeded(for: currentThreadNoteOwner)
            guard let resolvedOwner else { return }
            if isNotesPaneActive,
                selectedNotesScope == .thread,
                resolvedOwner.kind == .thread
            {
                return
            }
            let workspace: AssistantNotesWorkspace?
            switch resolvedOwner.kind {
            case .thread:
                workspace = assistant.createThreadNote(threadID: resolvedOwner.id)
            case .project:
                workspace = assistant.createProjectNote(projectID: resolvedOwner.id, title: nil)
            }
            guard let workspace else { return }
            applyThreadNoteWorkspace(workspace)
            isThreadNoteOpen = true
            clearThreadNoteAIDraftState(for: resolvedOwner)
            clearThreadNoteProjectTransferState(for: resolvedOwner)
            clearThreadNoteProjectTransferOutcome(for: resolvedOwner)
            if isNotesPaneActive,
                let project = notesProject(for: resolvedOwner),
                let createdNoteID = workspace.selectedNote?.id
            {
                rememberNotesSelectionTarget(
                    AssistantNoteLinkTarget(
                        ownerKind: resolvedOwner.kind,
                        ownerID: resolvedOwner.id,
                        noteID: createdNoteID
                    ),
                    projectID: project.id,
                    scope: resolvedOwner.kind == .project ? .project : .thread
                )
            }
        case "renameNote":
            guard let resolvedOwner,
                let resolvedNoteID,
                let title = command.title
            else { return }
            let workspace: AssistantNotesWorkspace?
            switch resolvedOwner.kind {
            case .thread:
                workspace = assistant.renameThreadNote(
                    threadID: resolvedOwner.id,
                    noteID: resolvedNoteID,
                    title: title
                )
            case .project:
                workspace = assistant.renameProjectNote(
                    projectID: resolvedOwner.id,
                    noteID: resolvedNoteID,
                    title: title
                )
            }
            guard let workspace else { return }
            applyThreadNoteWorkspace(workspace)
            if isNotesPaneActive,
                let project = notesProject(for: resolvedOwner)
            {
                rememberNotesSelectionTarget(
                    AssistantNoteLinkTarget(
                        ownerKind: resolvedOwner.kind,
                        ownerID: resolvedOwner.id,
                        noteID: resolvedNoteID
                    ),
                    projectID: project.id,
                    scope: resolvedOwner.kind == .project ? .project : .thread
                )
            }
        case "deleteNote":
            guard let resolvedOwner,
                let resolvedNoteID
            else { return }
            let workspace: AssistantNotesWorkspace?
            switch resolvedOwner.kind {
            case .thread:
                workspace = assistant.deleteThreadNote(
                    threadID: resolvedOwner.id,
                    noteID: resolvedNoteID
                )
            case .project:
                workspace = assistant.deleteProjectNote(
                    projectID: resolvedOwner.id,
                    noteID: resolvedNoteID
                )
            }
            guard let workspace else { return }
            removeNoteFromNavigationStacks(owner: resolvedOwner, noteID: resolvedNoteID)
            applyThreadNoteWorkspace(workspace)
            clearThreadNoteAIDraftState(for: resolvedOwner)
            clearThreadNoteProjectTransferState(for: resolvedOwner)
            clearThreadNoteProjectTransferOutcome(for: resolvedOwner)
            if isNotesPaneActive,
                let project = notesProject(for: resolvedOwner)
            {
                let scope: AssistantNotesScope = resolvedOwner.kind == .project ? .project : .thread
                rememberNotesSelectionTarget(
                    currentNotesSelectionTarget(project: project, scope: scope),
                    projectID: project.id,
                    scope: scope
                )
            }
        case "updateDraft":
            if isNotesPaneActive, notesWorkspaceExternalMarkdownFile != nil,
                let text = command.text
            {
                updateExternalMarkdownDraft(text)
                return
            }
            guard let resolvedOwner,
                let resolvedNoteID,
                let text = command.text
            else { return }
            noteDraftStore.setDraft(
                text,
                ownerKey: resolvedOwner.storageKey,
                noteID: resolvedNoteID,
                revision: command.draftRevision
            )
        case "save":
            if isNotesPaneActive, notesWorkspaceExternalMarkdownFile != nil {
                saveExternalMarkdownFile(
                    requestID: command.requestID,
                    draftRevision: command.draftRevision,
                    text: command.text,
                    sourceContainer: sourceContainer
                )
                return
            }
            guard let resolvedOwner,
                let resolvedNoteID
            else {
                // Still ack so JS doesn't time out on a save it issued
                // for an owner we can no longer resolve.
                if let requestID = command.requestID {
                    sendThreadNoteSaveAck(
                        AssistantChatWebThreadNoteSaveAck(
                            requestID: requestID,
                            ownerKind: command.ownerKind,
                            ownerID: command.ownerID,
                            noteID: command.noteID,
                            draftRevision: command.draftRevision,
                            status: "error",
                            errorMessage:
                                "Open Assist could not find this note anymore. Please reopen it."
                        ),
                        sourceContainer: sourceContainer
                    )
                }
                return
            }
            if let text = command.text {
                noteDraftStore.setDraft(
                    text,
                    ownerKey: resolvedOwner.storageKey,
                    noteID: resolvedNoteID,
                    revision: command.draftRevision
                )
            }
            persistThreadNoteIfNeeded(
                for: resolvedOwner,
                noteID: resolvedNoteID,
                forceHistorySnapshot: false,
                requestID: command.requestID,
                draftRevision: command.draftRevision,
                explicitText: command.text,
                sourceContainer: sourceContainer
            )
        case "restoreHistoryVersion":
            guard let resolvedOwner,
                let resolvedNoteID,
                let historyVersionID = command.historyVersionID
            else { return }
            let workspace: AssistantNotesWorkspace?
            switch resolvedOwner.kind {
            case .thread:
                workspace = assistant.restoreThreadNoteHistoryVersion(
                    threadID: resolvedOwner.id,
                    noteID: resolvedNoteID,
                    versionID: historyVersionID
                )
            case .project:
                workspace = assistant.restoreProjectNoteHistoryVersion(
                    projectID: resolvedOwner.id,
                    noteID: resolvedNoteID,
                    versionID: historyVersionID
                )
            }
            guard let workspace else { return }
            applyThreadNoteWorkspace(workspace)
            clearThreadNoteAIDraftState(for: resolvedOwner)
            clearThreadNoteProjectTransferState(for: resolvedOwner)
            clearThreadNoteProjectTransferOutcome(for: resolvedOwner)
        case "deleteHistoryVersion":
            guard let resolvedOwner,
                let resolvedNoteID,
                let historyVersionID = command.historyVersionID
            else { return }
            let workspace: AssistantNotesWorkspace?
            switch resolvedOwner.kind {
            case .thread:
                workspace = assistant.deleteThreadNoteHistoryVersion(
                    threadID: resolvedOwner.id,
                    noteID: resolvedNoteID,
                    versionID: historyVersionID
                )
            case .project:
                workspace = assistant.deleteProjectNoteHistoryVersion(
                    projectID: resolvedOwner.id,
                    noteID: resolvedNoteID,
                    versionID: historyVersionID
                )
            }
            guard let workspace else { return }
            applyThreadNoteWorkspace(workspace)
        case "restoreDeletedNote":
            guard let resolvedOwner,
                let deletedNoteID = command.deletedNoteID
            else { return }
            let workspace: AssistantNotesWorkspace?
            switch resolvedOwner.kind {
            case .thread:
                workspace = assistant.restoreDeletedThreadNote(
                    threadID: resolvedOwner.id,
                    deletedNoteID: deletedNoteID
                )
            case .project:
                workspace = assistant.restoreDeletedProjectNote(
                    projectID: resolvedOwner.id,
                    deletedNoteID: deletedNoteID
                )
            }
            guard let workspace else { return }
            applyThreadNoteWorkspace(workspace)
            clearThreadNoteAIDraftState(for: resolvedOwner)
            clearThreadNoteProjectTransferState(for: resolvedOwner)
            clearThreadNoteProjectTransferOutcome(for: resolvedOwner)
        case "deleteDeletedNote":
            guard let resolvedOwner,
                let deletedNoteID = command.deletedNoteID
            else { return }
            switch resolvedOwner.kind {
            case .thread:
                assistant.permanentlyDeleteDeletedThreadNote(
                    threadID: resolvedOwner.id,
                    deletedNoteID: deletedNoteID
                )
            case .project:
                assistant.permanentlyDeleteDeletedProjectNote(
                    projectID: resolvedOwner.id,
                    deletedNoteID: deletedNoteID
                )
            }
        case "appendSelection":
            guard let resolvedOwner,
                let text = command.text
            else { return }
            let workspace: AssistantNotesWorkspace?
            switch resolvedOwner.kind {
            case .thread:
                workspace = assistant.appendToSelectedThreadNote(
                    threadID: resolvedOwner.id,
                    text: text
                )
            case .project:
                workspace = assistant.appendToSelectedProjectNote(
                    projectID: resolvedOwner.id,
                    text: text
                )
            }
            guard let workspace else { return }
            applyThreadNoteWorkspace(workspace)
            isThreadNoteOpen = true
        case "showSelectionAssistantActions":
            guard let resolvedOwner,
                let resolvedNoteID
            else {
                hideThreadNoteSelectionAssistantActionsIfNeeded()
                return
            }
            presentThreadNoteSelectionAssistantActions(
                owner: resolvedOwner,
                noteID: resolvedNoteID,
                selectedText: command.selectedText,
                anchorRect: command.viewportRect
            )
        case "openSelectionAssistantQuestionComposer":
            guard let resolvedOwner,
                let resolvedNoteID,
                let selection = threadNoteSelectionContext(
                    owner: resolvedOwner,
                    noteID: resolvedNoteID,
                    selectedText: command.selectedText,
                    anchorRect: command.viewportRect
                )
            else {
                hideThreadNoteSelectionAssistantActionsIfNeeded()
                return
            }
            askQuestionAboutSelection(using: selection)
        case "hideSelectionAssistantActions":
            hideThreadNoteSelectionAssistantActionsIfNeeded()
        case "requestAIDraftPreview":
            guard let resolvedOwner,
                let noteText = command.text
            else { return }
            requestThreadNoteAIDraftPreview(
                owner: resolvedOwner,
                noteText: noteText,
                selectedText: command.selectedText,
                requestKind: command.requestKind,
                draftMode: command.draftMode,
                styleInstruction: command.styleInstruction
            )
        case "regenerateAIDraftPreview":
            guard let resolvedOwner else { return }
            regenerateThreadNoteChartDraft(
                owner: resolvedOwner,
                currentDraftMarkdown: command.currentDraftMarkdown,
                styleInstruction: command.styleInstruction,
                renderError: command.renderError
            )
        case "applyAIDraftPreview", "cancelAIDraftPreview", "clearAIDraftPreview":
            guard let resolvedOwner else { return }
            clearThreadNoteAIDraftState(for: resolvedOwner)
        case "requestProjectNoteTransferPreview":
            guard let resolvedOwner,
                let resolvedNoteID,
                let noteText = command.text,
                let targetProjectID = command.targetProjectID,
                let targetNoteID = command.targetNoteID,
                let selectedText = command.selectedText
            else {
                return
            }
            requestProjectNoteTransferPreview(
                owner: resolvedOwner,
                sourceNoteID: resolvedNoteID,
                sourceNoteTitle: command.sourceNoteTitle,
                noteText: noteText,
                selectedMarkdown: selectedText,
                targetProjectID: targetProjectID,
                targetNoteID: targetNoteID
            )
        case "applyProjectNoteTransfer":
            guard let resolvedOwner,
                let resolvedNoteID,
                let placementChoice = command.placementChoice,
                let transferMode = command.transferMode,
                let sourceFingerprint = command.sourceFingerprint,
                let targetFingerprint = command.targetFingerprint
            else {
                return
            }
            applyProjectNoteTransfer(
                owner: resolvedOwner,
                sourceNoteID: resolvedNoteID,
                transferMode: transferMode,
                placementChoice: placementChoice,
                sourceFingerprint: sourceFingerprint,
                targetFingerprint: targetFingerprint,
                sourceTextAfterMove: command.sourceTextAfterMove
            )
        case "cancelProjectNoteTransferPreview":
            guard let resolvedOwner else { return }
            clearThreadNoteProjectTransferState(for: resolvedOwner)
        case "requestBatchNotePlanPreview":
            guard
                let projectID = command.targetProjectID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                !command.sourceNotes.isEmpty
            else {
                return
            }
            requestBatchNotePlanPreview(
                projectID: projectID,
                sourceSelections: command.sourceNotes
            )
        case "applyBatchNotePlanPreview":
            guard
                let projectID = command.targetProjectID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let previewID = command.previewID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            applyBatchNotePlanPreview(
                projectID: projectID,
                previewID: previewID,
                proposedNotes: command.proposedNotes,
                proposedLinks: command.proposedLinks
            )
        case "cancelBatchNotePlanPreview":
            guard
                let projectID = command.targetProjectID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            clearBatchNotePlanState(for: projectID)
        case "openProjectNotes":
            let projectID =
                command.targetProjectID
                ?? command.ownerID
                ?? resolvedOwner?.id
            guard let projectID,
                let project = sidebarProject(for: projectID),
                project.isProject
            else {
                return
            }
            openProjectNotes(for: project)
        case "openSettings":
                NotificationCenter.default.post(
                    name: .openAssistOpenSettings,
                    object: SettingsRoute(section: .general, subsection: .generalNotesBackup)
                )
        case "openOwningThread":
            guard
                let threadID = command.threadID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
                    ?? resolvedOwner?.id
                    ?? command.ownerID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                resolvedOwner?.kind == .thread
                    || command.ownerKind == AssistantNoteOwnerKind.thread.rawValue
            else {
                return
            }
            guard prepareToLeaveCurrentNoteScreen(reason: "open the owning thread") else { return }
            selectedSidebarPane = .threads
            openThread(threadID)
        default:
            break
        }
    }

    private func captureThreadNoteScreenshotImport(
        requestID: String,
        captureMode: ThreadNoteScreenshotCaptureMode
    ) async -> AssistantChatWebThreadNoteScreenshotCaptureResult {
        guard CGPreflightScreenCaptureAccess() else {
            return AssistantChatWebThreadNoteScreenshotCaptureResult(
                requestID: requestID,
                ok: false,
                cancelled: false,
                message: "Grant Screen Recording in macOS Settings so Open Assist can capture screenshots.",
                captureMode: captureMode.rawValue,
                segmentCount: nil,
                filename: nil,
                mimeType: nil,
                dataURL: nil
            )
        }

        do {
            guard let data = try await captureInteractiveScreenshotData() else {
                return AssistantChatWebThreadNoteScreenshotCaptureResult(
                    requestID: requestID,
                    ok: false,
                    cancelled: true,
                    message: nil,
                    captureMode: captureMode.rawValue,
                    segmentCount: nil,
                    filename: nil,
                    mimeType: nil,
                    dataURL: nil
                )
            }

            return AssistantChatWebThreadNoteScreenshotCaptureResult(
                requestID: requestID,
                ok: true,
                cancelled: false,
                message: nil,
                captureMode: captureMode.rawValue,
                segmentCount: 1,
                filename: screenshotCaptureFilename(for: captureMode, segmentCount: 1),
                mimeType: "image/png",
                dataURL: "data:image/png;base64,\(data.base64EncodedString())"
            )
        } catch {
            return AssistantChatWebThreadNoteScreenshotCaptureResult(
                requestID: requestID,
                ok: false,
                cancelled: false,
                message: "Open Assist could not capture the screenshot: \(error.localizedDescription)",
                captureMode: captureMode.rawValue,
                segmentCount: nil,
                filename: nil,
                mimeType: nil,
                dataURL: nil
            )
        }
    }

    private func captureInteractiveScreenshotData() async throws -> Data? {
        let fileManager = FileManager.default
        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("openassist-thread-note-screenshot-\(UUID().uuidString)")
            .appendingPathExtension("png")

        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        let terminationStatus = try await runInteractiveScreenshot(to: temporaryURL)
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            if terminationStatus != 0 {
                return nil
            }

            throw NSError(
                domain: "OpenAssist.ThreadNoteScreenshot",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Open Assist could not find the captured screenshot."
                ]
            )
        }

        let data = try Data(contentsOf: temporaryURL)
        guard !data.isEmpty else {
            throw NSError(
                domain: "OpenAssist.ThreadNoteScreenshot",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "The captured screenshot was empty. Please try again."
                ]
            )
        }

        return data
    }

    private func screenshotCaptureFilename(
        for captureMode: ThreadNoteScreenshotCaptureMode,
        segmentCount: Int
    ) -> String {
        let dateStamp = Date.now.formatted(.iso8601.year().month().day())
        switch captureMode {
        case .area:
            return "Screenshot-\(dateStamp).png"
        case .scrolling:
            return "Scrolling-Screenshot-\(dateStamp)-\(max(1, segmentCount)).png"
        case .multiple:
            return "Screenshots-\(dateStamp)-\(max(1, segmentCount)).png"
        }
    }

    private func runInteractiveScreenshot(to fileURL: URL) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-x", fileURL.path]

                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func requestThreadNoteAIDraftPreview(
        owner: AssistantNoteOwnerKey,
        noteText: String,
        selectedText: String?,
        requestKind: String?,
        draftMode: String?,
        styleInstruction: String?
    ) {
        let resolvedDraftMode = draftMode?.isEmpty == false ? draftMode ?? "organize" : "organize"
        guard resolvedDraftMode == "organize" || resolvedDraftMode == "chart" else {
            return
        }

        let normalizedSelectedText = selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let normalizedStyleInstruction = styleInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let resolvedSourceKind =
            (requestKind == "selection" && normalizedSelectedText != nil)
            ? "selection"
            : "whole"

        if resolvedDraftMode == "chart" {
            let chartSelection =
                normalizedSelectedText
                ?? noteText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            guard let chartSelection else {
                threadNoteAIDraftPreviewByOwnerKey[owner.storageKey] =
                    AssistantChatWebThreadNoteAIPreview(
                        mode: "chart",
                        sourceKind: resolvedSourceKind,
                        markdown: "Select or right-click some note text first.",
                        isError: true
                    )
                threadNoteAIDraftModeByOwnerKey[owner.storageKey] = "chart"
                threadNoteGeneratingAIDraftOwnerKeys.remove(owner.storageKey)
                threadNoteAIDraftRequestIDByOwnerKey.removeValue(forKey: owner.storageKey)
                return
            }

            threadNoteChartContextByOwnerKey[owner.storageKey] = ThreadNoteChartContext(
                selectedText: chartSelection,
                parentMessageText: noteText,
                sourceKind: resolvedSourceKind
            )
            threadNoteAIDraftPreviewByOwnerKey.removeValue(forKey: owner.storageKey)
            let requestID = beginThreadNoteAIDraftRequest(for: owner, mode: "chart")

            Task {
                let result = await MemoryEntryExplanationService.shared.generateThreadNoteChart(
                    selectedText: chartSelection,
                    parentMessageText: noteText,
                    styleInstruction: normalizedStyleInstruction
                )

                await MainActor.run {
                    switch result {
                    case .success(let markdown):
                        finishThreadNoteAIDraftRequest(
                            for: owner,
                            requestID: requestID,
                            preview: AssistantChatWebThreadNoteAIPreview(
                                mode: "chart",
                                sourceKind: resolvedSourceKind,
                                markdown: markdown,
                                isError: false
                            )
                        )
                    case .failure(let message):
                        failThreadNoteAIDraftRequest(
                            for: owner,
                            requestID: requestID,
                            mode: "chart",
                            sourceKind: resolvedSourceKind,
                            message: message
                        )
                    }
                }
            }
            return
        }

        let requestID = beginThreadNoteAIDraftRequest(
            for: owner,
            mode: "organize",
            clearsChartContext: true
        )
        threadNoteAIDraftPreviewByOwnerKey.removeValue(forKey: owner.storageKey)

        Task {
            let result = await MemoryEntryExplanationService.shared.organizeThreadNote(
                noteText: noteText,
                selectedText: resolvedSourceKind == "selection" ? normalizedSelectedText : nil,
                styleInstruction: normalizedStyleInstruction,
                onPartialText: { partialText in
                    Task { @MainActor in
                        guard
                            self.threadNoteAIDraftRequestIDByOwnerKey[owner.storageKey] == requestID
                        else {
                            return
                        }
                        self.threadNoteAIDraftPreviewByOwnerKey[owner.storageKey] =
                            AssistantChatWebThreadNoteAIPreview(
                                mode: "organize",
                                sourceKind: resolvedSourceKind,
                                markdown: partialText,
                                isError: false
                            )
                    }
                }
            )

            await MainActor.run {
                switch result {
                case .success(let markdown):
                    finishThreadNoteAIDraftRequest(
                        for: owner,
                        requestID: requestID,
                        preview: AssistantChatWebThreadNoteAIPreview(
                            mode: "organize",
                            sourceKind: resolvedSourceKind,
                            markdown: markdown,
                            isError: false
                        )
                    )
                case .failure(let message):
                    failThreadNoteAIDraftRequest(
                        for: owner,
                        requestID: requestID,
                        mode: "organize",
                        sourceKind: resolvedSourceKind,
                        message: message
                    )
                }
            }
        }
    }

    private func presentThreadNoteMenu(threadID: String, anchorRect: CGRect) {
        let availableOwners = availableNoteOwners(for: threadID)
        guard
            let owner = selectedNoteOwnerByThreadID[threadID].flatMap({ selectedOwner in
                availableOwners.contains(selectedOwner) ? selectedOwner : nil
            }) ?? availableOwners.first
        else { return }

        persistThreadNoteIfNeeded(for: owner)

        let workspace = loadNotesWorkspace(for: owner)
        let manifest =
            noteManifestByOwnerKey[owner.storageKey]
            ?? workspace?.manifest
            ?? AssistantNoteManifest()
        let notes = manifest.orderedNotes

        guard let container = threadNoteWebContainer else {
            return
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        if notes.isEmpty {
            let emptyItem = NSMenuItem(title: "No notes yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            let selectionHandler = AssistantThreadNoteMenuSelectionHandler { selectedNoteID in
                let updatedWorkspace: AssistantNotesWorkspace?
                switch owner.kind {
                case .thread:
                    updatedWorkspace = assistant.selectThreadNote(
                        threadID: owner.id,
                        noteID: selectedNoteID
                    )
                case .project:
                    updatedWorkspace = assistant.selectProjectNote(
                        projectID: owner.id,
                        noteID: selectedNoteID
                    )
                }
                guard let updatedWorkspace else { return }
                updateSelectedNoteOwner(owner, threadID: threadID)
                applyThreadNoteWorkspace(updatedWorkspace)
                clearThreadNoteAIDraftState(for: owner)
            }

            for note in notes {
                let trimmedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let item = NSMenuItem(
                    title: trimmedTitle.isEmpty ? "Untitled note" : trimmedTitle,
                    action: #selector(AssistantThreadNoteMenuSelectionHandler.handleSelect(_:)),
                    keyEquivalent: ""
                )
                item.target = selectionHandler
                item.representedObject = note.id
                item.state = note.id == manifest.selectedNoteID ? .on : .off
                menu.addItem(item)
            }
        }

        let menuOrigin = NSPoint(
            x: min(max(anchorRect.minX, 12), max(12, container.bounds.width - 44)),
            y: min(max(anchorRect.maxY + 6, 12), max(12, container.bounds.height - 12))
        )
        menu.popUp(positioning: nil, at: menuOrigin, in: container)
    }

    private func loadOlderHistoryBatchWeb() {
        guard !isLoadingOlderHistory else { return }

        if hiddenRenderItemCount > 0 {
            visibleHistoryLimit += Self.historyBatchSize
            recomputeVisibleRenderItems()
        } else {
            isLoadingOlderHistory = true
            Task {
                _ = await assistant.loadMoreHistoryForSelectedSession()
                await MainActor.run {
                    visibleHistoryLimit += Self.historyBatchSize
                    recomputeVisibleRenderItems()
                    isLoadingOlderHistory = false
                }
            }
        }
    }

    private var hiddenRenderItemCount: Int {
        max(0, allRenderItems.count - visibleRenderItems.count)
    }

    private var chatViewportContentMinHeight: CGFloat {
        max(260, chatViewportHeight - 24)
    }

    private var canScrollToLatestVisibleContent: Bool {
        !visibleRenderItems.isEmpty || shouldShowPendingAssistantPlaceholder
    }

    private var hasVisibleStreamingAssistantMessage: Bool {
        assistantTimelineHasVisibleStreamingAssistantContent(visibleRenderItems.last)
    }

    private var selectedSessionActivitySnapshot: AssistantSessionActivitySnapshot {
        assistant.sessionActivitySnapshot(for: assistant.selectedSessionID)
    }

    private var shouldShowPendingAssistantPlaceholder: Bool {
        return assistantShouldShowPendingAssistantPlaceholder(
            selectedSessionID: assistant.selectedSessionID,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID,
            awaitingAssistantStart: selectedSessionActivitySnapshot.awaitingAssistantStart,
            hasActiveTurn: selectedSessionActivitySnapshot.hasActiveTurn,
            hasPendingPermissionRequest: assistant.pendingPermissionRequest != nil,
            hasVisibleStreamingAssistantMessage: hasVisibleStreamingAssistantMessage,
            hudPhase: selectedSessionActivitySnapshot.hudState?.phase ?? assistant.hudState.phase
        )
    }

    private var typingIndicatorTitle: String {
        let hudState = selectedSessionActivitySnapshot.hudState ?? assistant.hudState
        let normalizedTitle = hudState.title.trimmingCharacters(in: .whitespacesAndNewlines)

        if hudState.phase.isActive, !normalizedTitle.isEmpty {
            return normalizedTitle
        }

        if selectedSessionActivitySnapshot.pendingOutgoingMessage != nil
            || selectedSessionActivitySnapshot.awaitingAssistantStart
        {
            return "Thinking"
        }

        if selectedSessionActivitySnapshot.hasActiveTurn {
            return "Working"
        }

        return normalizedTitle.isEmpty ? "Thinking" : normalizedTitle
    }

    private var typingIndicatorDetail: String {
        let hudState = selectedSessionActivitySnapshot.hudState ?? assistant.hudState
        if let detail = hudState.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
            !detail.isEmpty,
            hudState.phase.isActive
        {
            return detail
        }

        if selectedSessionActivitySnapshot.pendingOutgoingMessage != nil
            || selectedSessionActivitySnapshot.awaitingAssistantStart
        {
            return "Sending your message"
        }

        if selectedSessionActivitySnapshot.hasActiveTurn {
            return "Still working on your message"
        }

        return "Working on your message"
    }

    private var canLoadOlderHistory: Bool {
        hiddenRenderItemCount > 0 || assistant.selectedSessionCanLoadMoreHistory
    }

    private var timelineLastUpdatedAt: Date {
        allRenderItems.last?.lastUpdatedAt ?? .distantPast
    }

    /// Pre-built lookup from lowercased-trimmed session ID → session status,
    /// avoiding O(n) linear scan with string trimming per permission card.
    private var sessionStatusByNormalizedID: [String: AssistantSessionStatus] {
        var dict = [String: AssistantSessionStatus]()
        dict.reserveCapacity(assistant.sessions.count)
        for session in assistant.sessions {
            let threadKey = session.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !threadKey.isEmpty {
                dict[threadKey] = session.status
            }

            let providerKeys =
                ([session.providerSessionID, session.activeProviderSessionID]
                + session.providerBindingsByBackend.map(\.providerSessionID))
                .compactMap {
                    $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty?.lowercased()
                }

            for providerKey in providerKeys where !providerKey.isEmpty {
                dict[providerKey] = session.status
            }
        }
        return dict
    }

    private var sessionWorkingDirectoryByNormalizedID: [String: String] {
        var dict = [String: String]()
        dict.reserveCapacity(assistant.sessions.count)
        for session in assistant.sessions {
            let cwd = session.effectiveCWD?.assistantNonEmpty ?? session.cwd?.assistantNonEmpty
            guard let cwd else { continue }

            let threadKey = session.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !threadKey.isEmpty {
                dict[threadKey] = cwd
            }

            let providerKeys =
                ([session.providerSessionID, session.activeProviderSessionID]
                + session.providerBindingsByBackend.map(\.providerSessionID))
                .compactMap {
                    $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty?.lowercased()
                }

            for providerKey in providerKeys where !providerKey.isEmpty {
                dict[providerKey] = cwd
            }
        }
        return dict
    }

    private func sessionStatus(forSessionID sessionID: String?) -> AssistantSessionStatus? {
        guard let sid = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !sid.isEmpty
        else { return nil }
        return sessionStatusByNormalizedID[sid]
    }

    private var shouldAutoFollowLatestMessage: Bool {
        autoScrollPinnedToBottom
            && !userHasScrolledUp
            && !isPreservingHistoryScrollPosition
            && Date().timeIntervalSince(chatScrollTracking.lastManualScrollAt)
                >= Self.manualScrollFollowPause
    }

    private var isAgentBusy: Bool {
        let phase = assistant.hudState.phase
        return phase == .acting || phase == .thinking || phase == .streaming
    }

    private var composerHasPendingInput: Bool {
        selectedSessionActivitySnapshot.pendingPermissionRequest?.toolKind == "userInput"
    }

    private var composerHasPendingToolApproval: Bool {
        selectedSessionActivitySnapshot.pendingPermissionRequest != nil && !composerHasPendingInput
    }

    private var composerCanCancelActiveTurn: Bool {
        let snapshot = selectedSessionActivitySnapshot
        return snapshot.hasActiveTurn
            || snapshot.pendingPermissionRequest != nil
            || snapshot.awaitingAssistantStart
    }

    private var composerCanSteerActiveTurn: Bool {
        let snapshot = selectedSessionActivitySnapshot
        return snapshot.canSteerActiveTurn
            && snapshot.pendingPermissionRequest == nil
    }

    private var composerActiveTurnPhase: String {
        let snapshot = selectedSessionActivitySnapshot
        if composerHasPendingInput || composerHasPendingToolApproval {
            return "needsInput"
        }

        let phase = snapshot.hudState?.phase ?? assistant.hudState.phase
        switch phase {
        case .thinking:
            return composerCanCancelActiveTurn ? "thinking" : "idle"
        case .streaming:
            return composerCanCancelActiveTurn ? "streaming" : "idle"
        case .acting, .listening:
            return composerCanCancelActiveTurn ? "acting" : "idle"
        case .waitingForPermission:
            return "needsInput"
        case .idle, .success, .failed:
            return composerCanCancelActiveTurn ? "acting" : "idle"
        }
    }

    private var isVoiceCapturing: Bool {
        assistant.hudState.phase == .listening
    }

    private var canChat: Bool {
        assistant.isRuntimeReadyForConversation
    }

    private var canStartConversation: Bool {
        settings.assistantBetaEnabled && assistant.canStartConversation
    }

    private var sidebarTextScale: CGFloat {
        // Sidebar scales at one-third the rate of the chat window
        let delta = CGFloat(chatTextScale) - 1.0
        return max(0.80, 1.0 + delta / 3.0)
    }

    private var isCompactSidebarPresentation: Bool {
        presentationStyle == .compactSidebar
    }

    private var sidebarToggleAnimation: Animation {
        .timingCurve(0.22, 0.84, 0.24, 1.0, duration: 0.16)
    }

    private var sidebarDisclosureAnimation: Animation {
        .timingCurve(0.24, 0.82, 0.26, 1.0, duration: 0.13)
    }

    private var sidebarListAnimation: Animation {
        .easeOut(duration: 0.12)
    }

    private var sidebarRowTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.997, anchor: .top)),
            removal: .opacity
        )
    }

    private func sidebarScaled(_ value: CGFloat) -> CGFloat {
        value * sidebarTextScale
    }

    private func scaledSidebarWidth(for safeWindowWidth: CGFloat, outerPadding: CGFloat) -> CGFloat
    {
        // While dragging, the live width is already clamped — return it
        // directly to avoid reading @AppStorage on every frame.
        if sidebarDragLiveWidth > 0 {
            return sidebarDragLiveWidth
        }
        let maxSidebarWidth = max(210.0, safeWindowWidth - (outerPadding * 2) - 320.0 - 0.5)
        if isCompactSidebarPresentation {
            let compactMaxSidebarWidth = min(280.0, maxSidebarWidth)
            if compactSidebarInnerWidth > 0 {
                return min(max(200.0, CGFloat(compactSidebarInnerWidth)), compactMaxSidebarWidth)
            }
            let compactSidebarWidth = min(248.0, max(216.0, safeWindowWidth * 0.30))
            return min(compactSidebarWidth, compactMaxSidebarWidth)
        }
        if sidebarCustomWidth > 0 {
            return min(max(180.0, CGFloat(sidebarCustomWidth)), maxSidebarWidth)
        }
        let baseSidebarWidth = min(260.0, max(210.0, safeWindowWidth * 0.22))
        let expandedSidebarWidth = baseSidebarWidth * max(1.0, sidebarTextScale)
        return min(expandedSidebarWidth, maxSidebarWidth)
    }

    private func sidebarResizeHandle(layout: ChatLayoutMetrics) -> some View {
        Color.clear
            .frame(width: 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(
                Rectangle()
                    .fill(AppVisualTheme.surfaceFill(sidebarDragStartWidth > 0 ? 0.14 : 0.10))
                    .frame(width: 1)
                    .opacity((isSidebarResizeHandleHovered || sidebarDragStartWidth > 0) ? 1 : 0)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if sidebarDragStartWidth == 0 {
                            sidebarDragStartWidth = layout.sidebarWidth
                            NSCursor.resizeLeftRight.push()
                        }
                        let newWidth = sidebarDragStartWidth + value.translation.width
                        let maxWidth = max(
                            210.0, layout.windowWidth - (layout.outerPadding * 2) - 320.0 - 0.5)
                        let minWidth = isCompactSidebarPresentation ? 200.0 : 180.0
                        // Snap to the exact pixel to avoid sub-pixel jitter, and
                        // kill any implicit SwiftUI animation so the sidebar
                        // tracks the cursor immediately instead of interpolating.
                        let clamped = min(max(minWidth, newWidth), maxWidth).rounded()
                        withTransaction(Transaction(animation: nil)) {
                            sidebarDragLiveWidth = clamped
                        }
                    }
                    .onEnded { _ in
                        // Persist the final width to AppStorage. Keep the
                        // live width set until the next render so the
                        // AppStorage → body propagation doesn't produce a
                        // transient flash where the sidebar snaps to the
                        // previously stored value.
                        let finalWidth = sidebarDragLiveWidth > 0
                            ? Double(sidebarDragLiveWidth)
                            : Double(sidebarDragStartWidth)
                        if finalWidth > 0 {
                            if isCompactSidebarPresentation {
                                compactSidebarInnerWidth = finalWidth
                            } else {
                                sidebarCustomWidth = finalWidth
                            }
                        }
                        withTransaction(Transaction(animation: nil)) {
                            sidebarDragLiveWidth = 0
                            sidebarDragStartWidth = 0
                        }
                        NSCursor.pop()
                    }
            )
            .onHover { hovering in
                isSidebarResizeHandleHovered = hovering
                if hovering && sidebarDragStartWidth == 0 {
                    NSCursor.resizeLeftRight.push()
                } else if !hovering && sidebarDragStartWidth == 0 {
                    NSCursor.pop()
                }
            }
    }

    private func sidebarActivityState(for session: AssistantSessionSummary)
        -> AssistantSessionRow.ActivityState
    {
        let activity = assistant.sessionActivitySnapshot(for: session.id)
        return assistantSidebarActivityState(
            forSessionID: session.id,
            selectedSessionID: assistant.selectedSessionID,
            activeRuntimeSessionID: activity.hasActiveTurn ? session.id : nil,
            sessionStatus: session.status,
            hasPendingPermissionRequest: activity.pendingPermissionRequest != nil,
            hudPhase: activity.hudState?.phase ?? .idle,
            isTransitioningSession: assistant.isTransitioningSession
                && assistant.selectedSessionID == session.id,
            isLiveVoiceSessionActive: assistant.isLiveVoiceSessionActive
                && assistant.selectedSessionID == session.id,
            hasActiveTurn: activity.hasActiveTurn
        )
    }

    private func sidebarChildSubagents(for session: AssistantSessionSummary) -> [SubagentState] {
        assistantSidebarChildSubagents(
            parentSessionID: session.id,
            selectedSessionID: assistant.selectedSessionID,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID,
            subagents: assistant.subagents
        )
    }

    private func ensureNotesProjectSelectionIfNeeded() {
        guard selectedNotesProject == nil,
            let fallbackProject = assistant.selectedProject ?? assistant.visibleLeafProjects.first
        else {
            return
        }
        selectedNotesProjectID = fallbackProject.id
        if let parentID = fallbackProject.parentID {
            setFolderExpanded(parentID, expanded: true)
        }
    }

    private func syncAssistantNotesRuntimeContext() {
        assistant.setNotesWorkspaceRuntimeContext(notesAssistantRuntimeContext)
    }

    private func syncNotesAssistantConversationBinding() {
        notesAssistantSessionTask?.cancel()
        notesAssistantSessionTask = Task { @MainActor in
            if selectedSidebarPane == .notes,
                isNotesAssistantPanelOpen,
                let project = selectedNotesProject
            {
                await activateNotesAssistantSession(for: project)
            } else {
                await restorePrimaryAssistantSessionAfterNotesIfNeeded()
            }
        }
    }

    @MainActor
    private func activateNotesAssistantSession(for project: AssistantProject) async {
        await activateNotesAssistantSession(for: project, preferredSessionID: nil)
    }

    @MainActor
    private func activateNotesAssistantSession(
        for project: AssistantProject,
        preferredSessionID: String?
    ) async {
        if notesAssistantReturnSessionID == nil,
            !isNotesAssistantSession(assistant.selectedSessionID)
        {
            notesAssistantReturnSessionID = assistant.selectedSessionID
        }

        guard
            let targetSessionID = await ensureNotesAssistantSession(
                for: project,
                preferredSessionID: preferredSessionID
            )
        else {
            return
        }

        guard !assistantTimelineSessionIDsMatch(assistant.selectedSessionID, targetSessionID) else {
            rememberNotesAssistantSessionID(targetSessionID, for: project.id, makeLastUsed: true)
            syncAssistantNotesRuntimeContext()
            return
        }

        if let session = assistant.sessions.first(where: {
            assistantTimelineSessionIDsMatch($0.id, targetSessionID)
        }) {
            await assistant.openSession(session)
        } else {
            assistant.selectedSessionID = targetSessionID
        }

        rememberNotesAssistantSessionID(targetSessionID, for: project.id, makeLastUsed: true)
        syncAssistantNotesRuntimeContext()
    }

    @MainActor
    private func ensureNotesAssistantSession(
        for project: AssistantProject,
        preferredSessionID: String? = nil
    ) async -> String? {
        if let preferredSessionID = assistantNormalizedNotesSessionID(preferredSessionID),
            let matchedPreferredSession = assistant.sessions.first(where: {
                assistantTimelineSessionIDsMatch($0.id, preferredSessionID)
            }),
            !matchedPreferredSession.isArchived
        {
            assistant.assignSessionToProject(matchedPreferredSession.id, projectID: project.id)
            rememberNotesAssistantSessionID(
                matchedPreferredSession.id,
                for: project.id,
                makeLastUsed: true
            )
            return matchedPreferredSession.id
        }

        if let existingSessionID = notesAssistantResolvedSessionID(for: project),
            let existingSession = assistant.sessions.first(where: {
                assistantTimelineSessionIDsMatch($0.id, existingSessionID)
            })
        {
            assistant.assignSessionToProject(existingSession.id, projectID: project.id)
            rememberNotesAssistantSessionID(existingSession.id, for: project.id, makeLastUsed: true)
            return existingSession.id
        }

        if notesAssistantSessionRegistry(for: project.id) != nil {
            await assistant.refreshSessions(limit: max(200, assistant.visibleSessionsLimit + 20))
            pruneNotesAssistantSessionRegistry(for: project)

            if let recoveredSessionID = notesAssistantResolvedSessionID(for: project),
                let recoveredSession = assistant.sessions.first(where: {
                    assistantTimelineSessionIDsMatch($0.id, recoveredSessionID)
                })
            {
                assistant.assignSessionToProject(recoveredSession.id, projectID: project.id)
                rememberNotesAssistantSessionID(
                    recoveredSession.id,
                    for: project.id,
                    makeLastUsed: true
                )
                return recoveredSession.id
            }
        }

        return await createNotesAssistantSession(for: project)
    }

    @MainActor
    private func createNotesAssistantSession(for project: AssistantProject) async -> String? {
        let previousReturnSessionID = notesAssistantReturnSessionID
        await assistant.startNewSession(cwd: project.linkedFolderPath)
        guard
            let createdSessionID = assistant.selectedSessionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        else {
            return nil
        }

        assistant.assignSessionToProject(createdSessionID, projectID: project.id)
        let existingRegistry =
            notesAssistantSessionRegistry(for: project.id)
            ?? AssistantNotesProjectSessionRegistry()
        await assistant.renameSession(
            createdSessionID,
            to: notesAssistantSessionTitle(for: project, existingRegistry: existingRegistry)
        )
        rememberNotesAssistantSessionID(createdSessionID, for: project.id, makeLastUsed: true)
        notesAssistantReturnSessionID = previousReturnSessionID
        syncAssistantNotesRuntimeContext()
        return createdSessionID
    }

    @MainActor
    private func restorePrimaryAssistantSessionAfterNotesIfNeeded() async {
        guard isNotesAssistantSession(assistant.selectedSessionID) else { return }

        let targetSessionID = notesAssistantReturnSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        defer {
            notesAssistantReturnSessionID = nil
            syncAssistantNotesRuntimeContext()
        }

        if let targetSessionID,
            let session = assistant.sessions.first(where: {
                assistantTimelineSessionIDsMatch($0.id, targetSessionID)
            })
        {
            await assistant.openSession(session)
            return
        }

        if let fallbackSession = sidebarVisibleSessions.first {
            await assistant.openSession(fallbackSession)
            return
        }

        assistant.selectedSessionID = nil
    }

    private func selectNotesProject(_ project: AssistantProject?) {
        guard prepareToLeaveCurrentNoteScreen(reason: "switch note projects") else { return }
        selectedNotesProjectID = project?.id
        if let project,
            let parentID = project.parentID
        {
            setFolderExpanded(parentID, expanded: true)
        }
        selectedSidebarPane = .notes
        ensureNotesProjectSelectionIfNeeded()
    }

    private func setNotesScope(_ scope: AssistantNotesScope) {
        guard prepareToLeaveCurrentNoteScreen(reason: "switch note sections") else { return }
        selectedNotesScope = scope
        selectedSidebarPane = .notes
    }

    private func selectSidebarNote(
        owner: AssistantNoteOwnerKey,
        noteID: String
    ) {
        Task { @MainActor in
            await selectSidebarNoteAfterFlushing(owner: owner, noteID: noteID)
        }
    }

    private func selectSidebarNoteAfterFlushing(
        owner: AssistantNoteOwnerKey,
        noteID: String
    ) async {
        await flushCurrentThreadNoteDraftFromWeb()

        if isNotesPaneActive, notesWorkspaceExternalMarkdownFile != nil {
            switchAwayFromExternalMarkdownFileIfNeeded {
                selectSidebarNote(owner: owner, noteID: noteID)
            }
            return
        }

        guard let project = selectedNotesProject else { return }
        let target = AssistantNoteLinkTarget(ownerKind: owner.kind, ownerID: owner.id, noteID: noteID)
        if currentDisplayedNoteTarget == target {
            return
        }
        guard saveManagedThreadNoteBeforeNavigation(reason: "switch notes") else { return }
        let previousOwner = currentThreadNoteOwner
        let previousNoteID = currentSelectedThreadNoteNoteID
        let scope: AssistantNotesScope = owner.kind == .project ? .project : .thread
        let selectedRow = sidebarNoteRows(for: project, scope: scope).first(where: {
            $0.target.ownerKind == owner.kind
                && $0.target.ownerID.caseInsensitiveCompare(owner.id) == .orderedSame
                && $0.target.noteID.caseInsensitiveCompare(noteID) == .orderedSame
        })
        persistThreadNoteIfNeeded(for: previousOwner, noteID: previousNoteID)
        selectedSidebarPane = .notes
        selectedNotesScope = scope
        rememberNotesSelectionTarget(
            target,
            projectID: project.id,
            scope: scope
        )
        if scope == .project {
            setNoteFolderPathExpanded(
                folderID: selectedRow?.folderID,
                folders: noteManifest(for: AssistantNoteOwnerKey(kind: .project, id: project.id)).folders
            )
        }
        clearThreadNoteNavigationStack(for: nil)
        if let workspace = selectNotesWorkspace(for: owner, noteID: noteID) {
            applyThreadNoteWorkspace(workspace)
            clearThreadNoteAIDraftState(for: owner)
        }
    }

    private func createSidebarProjectNote(
        project: AssistantProject,
        folderID: String?
    ) {
        switchAwayFromExternalMarkdownFileIfNeeded {
            persistThreadNoteIfNeeded(
                for: currentThreadNoteOwner,
                noteID: currentSelectedThreadNoteNoteID
            )
            guard let workspace = assistant.createProjectNote(
                projectID: project.id,
                title: nil,
                folderID: folderID
            ),
                let noteID = workspace.selectedNote?.id
            else {
                return
            }
            applyThreadNoteWorkspace(workspace)
            clearThreadNoteAIDraftState(for: AssistantNoteOwnerKey(kind: .project, id: project.id))
            if let folderID {
                setNoteFolderPathExpanded(
                    folderID: folderID,
                    folders: workspace.manifest.folders
                )
            }
            rememberNotesSelectionTarget(
                AssistantNoteLinkTarget(ownerKind: .project, ownerID: project.id, noteID: noteID),
                projectID: project.id,
                scope: .project
            )
            selectedSidebarPane = .notes
        }
    }

    private func openThread(_ threadID: String) {
        closeProjectNotesIfNeeded()
        threadsDetailMode = .chat
        Task { await assistant.openSession(threadID: threadID) }
    }

    private func openProjectNotes(for project: AssistantProject) {
        closeProjectNotesIfNeeded()
        selectedNotesScope = .project
        selectNotesProject(project)
    }

    private func revealLatestFileChangeActivity() {
        guard let latestFileChangeMessageID else { return }
        chatTimelineWebContainer?.revealMessage(
            id: latestFileChangeMessageID, animated: true, expand: true)
    }

    private var shouldShowLiveVoicePanel: Bool {
        settings.assistantBetaEnabled
    }

    private var liveVoiceStatusText: String {
        assistant.liveVoiceSessionSnapshot.displayText
    }

    private var liveVoiceTranscriptStatusText: String? {
        switch assistant.liveVoiceSessionSnapshot.phase {
        case .sending, .waitingForPermission, .speaking, .paused, .ended:
            return assistant.liveVoiceSessionSnapshot.transcriptStatusText
        case .idle, .listening, .transcribing:
            return nil
        }
    }

    private var liveVoiceStatusSymbol: String {
        switch assistant.liveVoiceSessionSnapshot.phase {
        case .idle, .ended:
            return "person.wave.2.fill"
        case .listening:
            return "mic.fill"
        case .transcribing, .sending:
            return "waveform"
        case .waitingForPermission:
            return "hand.raised.fill"
        case .speaking:
            return "speaker.wave.2.fill"
        case .paused:
            return "pause.circle.fill"
        }
    }

    private var liveVoiceStatusTint: Color {
        switch assistant.liveVoiceSessionSnapshot.phase {
        case .waitingForPermission:
            return .orange
        case .speaking:
            return .purple
        case .listening:
            return .green
        case .transcribing, .sending:
            return .cyan
        case .paused:
            return .yellow
        case .idle, .ended:
            return .cyan
        }
    }

    private var composerVoiceBanner: (symbol: String, text: String, tint: Color)? {
        let liveVoiceSnapshot = assistant.liveVoiceSessionSnapshot

        switch liveVoiceSnapshot.phase {
        case .listening:
            return ("mic.fill", "Live voice is listening. Keep speaking.", .green)
        case .transcribing:
            return ("waveform", "Live voice is turning your speech into text.", .cyan)
        case .sending:
            return (
                "paperplane.fill", "Live voice is sending your request.", AppVisualTheme.accentTint
            )
        case .waitingForPermission:
            return ("hand.raised.fill", "Live voice is waiting for approval.", .orange)
        case .speaking:
            return ("speaker.wave.2.fill", "Live voice is speaking back.", .purple)
        case .paused:
            return (
                "pause.circle.fill", "Live voice is paused. Start again when you are ready.",
                .yellow
            )
        case .idle, .ended:
            break
        }

        if isVoiceCapturing {
            return ("mic.fill", "Listening now. Speak your message, then release.", .green)
        }

        if assistant.assistantVoicePlaybackActive {
            return (
                "speaker.wave.2.fill",
                "The assistant is speaking its reply.",
                AppVisualTheme.accentTint
            )
        }

        return nil
    }

    private func composerPlaceholder(
        isNoteModeActive: Bool,
        isNotesWorkspaceAssistant: Bool
    ) -> String {
        if !settings.assistantBetaEnabled {
            return "Enable assistant in Settings to chat."
        }
        if isVoiceCapturing {
            return "Listening... release to paste."
        }
        if let composerPendingPermissionHelperText {
            return composerPendingPermissionHelperText
        }
        if isNotesWorkspaceAssistant && shouldDeferNotesAssistantSetupState {
            return "Ask about this note."
        }
        if assistant.isLoadingModels {
            return "Loading models..."
        }
        if assistant.selectedModel == nil {
            return assistant.visibleModels.isEmpty
                ? "Models will appear here when \(assistant.visibleAssistantBackendName) is ready."
                : "Select a model to start chatting..."
        }
        if isNotesWorkspaceAssistant {
            return "Ask about this note."
        }
        if isNoteModeActive {
            return "Ask about project notes, add to the best note, or organize a note."
        }
        return "What would you like to do?"
    }

    private var composerPendingPermissionHelperText: String? {
        guard selectedSessionActivitySnapshot.pendingPermissionRequest != nil else {
            return nil
        }
        return "Answer or approve the card above to continue this turn."
    }

    private var shouldDeferNotesAssistantSetupState: Bool {
        isNotesPaneActive
            && isNotesAssistantPanelOpen
            && trimmedPromptDraft.isEmpty
            && assistant.attachments.isEmpty
            && assistant.pendingPermissionRequest == nil
            && !assistant.hasActiveTurn
    }

    private var notesAssistantPreflightStatusMessage: String? {
        guard isNotesPaneActive, isNotesAssistantPanelOpen else { return nil }
        guard !trimmedPromptDraft.isEmpty || !assistant.attachments.isEmpty else { return nil }

        if !settings.assistantBetaEnabled {
            return "Enable the assistant in Settings before sending note requests."
        }

        if !canChat {
            return
                "Use the provider menu to connect \(assistant.visibleAssistantBackendName), then try again."
        }

        if let composerPendingPermissionHelperText {
            return composerPendingPermissionHelperText
        }

        return assistant.conversationBlockedReason
    }

    private var emptyStateMessage: String {
        if !settings.assistantBetaEnabled {
            return "Enable the assistant in Settings, then come back here."
        }
        if !canChat {
            return
                "Use the provider menu to connect \(assistant.visibleAssistantBackendName), then come back to chat."
        }
        return assistant.conversationBlockedReason
            ?? "Send a message to start a conversation with the assistant."
    }

    private var activeSessionSummary: AssistantSessionSummary? {
        guard let selectedSessionID = assistant.selectedSessionID else { return nil }
        return assistant.sessions.first(where: {
            assistantTimelineSessionIDsMatch($0.id, selectedSessionID)
        })
    }

    private var activeSessionProject: AssistantProject? {
        guard
            let projectID = activeSessionSummary?.projectID?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nonEmpty
        else {
            return nil
        }
        return assistant.projects.first(where: {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(projectID) == .orderedSame
        })
    }

    private var activeSessionTitle: String {
        guard let activeSessionSummary else { return "No session selected" }
        if activeSessionSummary.isTemporary,
            activeSessionSummary.title.caseInsensitiveCompare("New Assistant Session")
                == .orderedSame
        {
            return "Temporary Chat"
        }
        return activeSessionSummary.title
    }

    private var activeSessionHeaderTitle: String {
        shortHeaderTitle(activeSessionTitle, maxWords: 5)
    }

    private var activeSessionWorkspaceURL: URL? {
        existingDirectoryURL(for: activeSessionSummary?.linkedProjectFolderPath)
            ?? existingDirectoryURL(for: activeSessionSummary?.effectiveCWD)
            ?? existingDirectoryURL(for: activeSessionSummary?.cwd)
    }

    private var currentProjectWorkspaceURL: URL? {
        let notesProjectURL = existingDirectoryURL(for: selectedNotesProject?.linkedFolderPath)
        let focusedProjectURL = existingDirectoryURL(
            for: currentProjectNotesProject?.linkedFolderPath)
        return (isNotesPaneActive ? notesProjectURL : nil) ?? focusedProjectURL
    }

    private var currentWorkspaceURL: URL? {
        currentProjectWorkspaceURL ?? activeSessionWorkspaceURL
    }

    /// On-disk URL of the markdown file for the currently displayed note, if any.
    /// Returns `nil` when no note is focused or the note has no saved file yet.
    private var currentNoteMarkdownFileURL: URL? {
        if let externalFile = isNotesPaneActive ? notesWorkspaceExternalMarkdownFile : nil {
            return externalFile.fileURL
        }
        guard let target = currentDisplayedNoteTarget else { return nil }
        return assistant.noteMarkdownFileURL(
            ownerKind: target.ownerKind,
            ownerID: target.ownerID,
            noteID: target.noteID
        )
    }

    private var currentWorkspaceSubjectLabel: String {
        (isNotesPaneActive || currentProjectNotesProject != nil) ? "project" : "chat"
    }

    private var primaryWorkspaceLaunchTarget: AssistantWorkspaceLaunchTarget {
        if let preferred = Self.workspaceLaunchTargets.first(where: {
            $0.id == preferredWorkspaceLaunchTargetID && $0.remembersAsPreferred && $0.isInstalled
        }) {
            return preferred
        }

        return Self.workspaceLaunchTargets.first(where: {
            $0.remembersAsPreferred && $0.isInstalled
        })
            ?? Self.workspaceLaunchTargets.first(where: { $0.isInstalled })
            ?? Self.workspaceLaunchTargets.first
            ?? AssistantWorkspaceLaunchTarget(
                title: "Finder",
                bundleIdentifiers: ["com.apple.finder"],
                fallbackSymbol: "folder.fill",
                launchStyle: .revealInFinder,
                remembersAsPreferred: false
            )
    }

    private func existingDirectoryURL(for path: String?) -> URL? {
        guard let normalizedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        else {
            return nil
        }

        let candidateURL = URL(fileURLWithPath: normalizedPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory)
        else {
            return nil
        }

        if isDirectory.boolValue {
            return candidateURL
        }

        let parentURL = candidateURL.deletingLastPathComponent()
        guard parentURL.path != candidateURL.path else { return nil }
        return parentURL
    }

    private func shortHeaderTitle(_ title: String, maxWords: Int) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxWords > 0 else { return trimmed }

        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count > maxWords else { return words.joined(separator: " ") }

        return words.prefix(maxWords).joined(separator: " ") + "..."
    }

    private var sidebarVisibleSessionsIgnoringProjectFilter: [AssistantSessionSummary] {
        assistant.visibleSidebarSessionsIgnoringProjectFilter.filter { session in
            !isNotesAssistantSession(session.id)
        }
    }

    private var sidebarVisibleSessions: [AssistantSessionSummary] {
        assistant.visibleSidebarSessions.filter { session in
            !isNotesAssistantSession(session.id)
        }
    }

    private var sidebarVisibleArchivedSessions: [AssistantSessionSummary] {
        assistant.visibleArchivedSidebarSessions.filter { session in
            !isNotesAssistantSession(session.id)
        }
    }

    private var visibleSidebarSessionCount: Int {
        sidebarVisibleSessions.count
    }

    private var visibleArchivedSessionCount: Int {
        sidebarVisibleArchivedSessions.count
    }

    private func syncSidebarVisibleSessionsLimitIfNeeded(newValue: Int? = nil) {
        let normalizedValue = max(
            Self.initialSidebarVisibleSessionsLimit,
            newValue ?? sidebarVisibleSessionsLimit
        )

        if sidebarVisibleSessionsLimit != normalizedValue {
            sidebarVisibleSessionsLimit = normalizedValue
        }

        if assistant.visibleSessionsLimit != normalizedValue {
            assistant.visibleSessionsLimit = normalizedValue
        }
    }

    private func composerFallbackHeight(
        for layout: ChatLayoutMetrics,
        compact: Bool
    ) -> CGFloat {
        let accessoryRowCount =
            (assistant.activeThreadSkills.isEmpty ? 0 : 1)
            + (assistant.attachments.isEmpty ? 0 : 1)

        if compact {
            return 82 + (CGFloat(accessoryRowCount) * 18)
        }

        return 136 + (CGFloat(accessoryRowCount) * 28)
    }

    private func composerWebHeight(
        for layout: ChatLayoutMetrics,
        compact: Bool,
        measuredHeight: CGFloat?
    ) -> CGFloat {
        let minHeight: CGFloat = compact ? 76 : 120
        let maxHeight: CGFloat = compact ? 180 : 420
        let proposedHeight =
            measuredHeight
            ?? composerFallbackHeight(for: layout, compact: compact)
        return min(max(proposedHeight, minHeight), maxHeight)
    }

    private func updateComposerMeasuredHeight(_ height: CGFloat, compact: Bool = false) {
        guard height.isFinite else { return }

        let boundedHeight =
            compact
            ? min(max(ceil(height), 70), 180)
            : min(max(ceil(height), 112), 420)

        if compact {
            guard
                notesAssistantComposerMeasuredHeight == nil
                    || abs((notesAssistantComposerMeasuredHeight ?? 0) - boundedHeight) > 1
            else {
                return
            }

            notesAssistantComposerMeasuredHeight = boundedHeight
        } else {
            guard
                composerMeasuredHeight == nil
                    || abs((composerMeasuredHeight ?? 0) - boundedHeight) > 1
            else {
                return
            }

            withAnimation(.easeInOut(duration: 0.18)) {
                composerMeasuredHeight = boundedHeight
            }
        }
    }

    private var sidebarWebState: AssistantSidebarWebState {
        let notesRows = notesSidebarRows
        let noteFolderRows = notesSidebarFolderRows
        return AssistantSidebarWebState(
            projectFilterKind: currentProjectFilterKind,
            projectFilterID: assistant.selectedProjectFilterID,
            selectedPane: selectedSidebarPane.shellID,
            isCollapsed: isSidebarCollapsed,
            collapsedPreviewPane: collapsedSidebarPreviewPane,
            canCreateThread: assistant.canCreateThread,
            canCollapse: true,
            projectsTitle: projectSectionTitle,
            projectsHelperText: selectedSidebarPane == .notes
                ? "Choose which project's notes you want to browse." : nil,
            threadsTitle: "Threads",
            threadsHelperText: nil,
            archivedTitle: "Archived",
            archivedHelperText: visibleArchivedSessionCount == 0
                ? nil : "Older chats you saved for later.",
            notesTitle: "Notes",
            notesHelperText: notesSidebarHelperText,
            projectsExpanded: areProjectsExpanded,
            threadsExpanded: areThreadsExpanded,
            archivedExpanded: areArchivedExpanded,
            notesExpanded: areNotesExpanded,
            canLoadMoreThreads: visibleSidebarSessionCount > assistant.visibleSessionsLimit,
            canLoadMoreArchived: visibleArchivedSessionCount > assistant.visibleSessionsLimit,
            archivedCount: visibleArchivedSessionCount,
            hiddenProjectCount: assistant.hiddenProjects.count,
            selectedNotesProjectID: selectedNotesProject?.id,
            notesScope: selectedNotesScope.rawValue,
            canCreateProjectNote: selectedNotesProject != nil && selectedNotesScope == .project,
            navItems: [
                .init(
                    id: AssistantSidebarPane.threads.shellID, label: "Threads",
                    symbol: "bubble.left.and.bubble.right"),
                .init(
                    id: AssistantSidebarPane.notes.shellID, label: "Notes",
                    symbol: "note.text"),
                .init(
                    id: AssistantSidebarPane.automations.shellID, label: "Automations",
                    symbol: "clock"),
                .init(id: AssistantSidebarPane.skills.shellID, label: "Skills", symbol: "sparkles"),
                .init(id: AssistantSidebarPane.plugins.shellID, label: "Plugins", symbol: "shippingbox"),
            ],
            allProjects: assistant.visibleProjects.map {
                sidebarWebProject(for: $0, selectedProjectID: sidebarSelectedProjectID)
            },
            hiddenProjects: assistant.hiddenProjects.map { project in
                AssistantSidebarWebHiddenProject(
                    id: project.id,
                    name: project.name,
                    symbol: project.displayIconSymbolName
                )
            },
            projects: displayedSidebarProjects.map {
                sidebarWebProject(for: $0, selectedProjectID: sidebarSelectedProjectID)
            },
            threads:
                sidebarVisibleSessions
                .prefix(assistant.visibleSessionsLimit)
                .map { sidebarWebSession(for: $0) },
            archived:
                sidebarVisibleArchivedSessions
                .prefix(assistant.visibleSessionsLimit)
                .map { sidebarWebSession(for: $0) },
            noteFolders: noteFolderRows.map(sidebarWebNoteFolder(for:)),
            notes: notesRows.map(sidebarWebNote(for:))
        )
    }

    private var sidebarSelectedProjectID: String? {
        switch selectedSidebarPane {
        case .notes:
            return selectedNotesProject?.id
        default:
            return assistant.selectedProjectFilterID
        }
    }

    private var notesSidebarRows: [AssistantSidebarNoteRowModel] {
        guard let project = selectedNotesProject else { return [] }
        return sidebarNoteRows(for: project, scope: selectedNotesScope)
    }

    private var notesSidebarFolderRows: [AssistantSidebarNoteFolderRowModel] {
        guard let project = selectedNotesProject else { return [] }
        return sidebarNoteFolderRows(for: project, scope: selectedNotesScope)
    }

    private var notesSidebarHelperText: String? {
        guard let project = selectedNotesProject else {
            return assistant.visibleLeafProjects.isEmpty
                ? "Create a project first, then your notes can live there."
                : "Pick a project above to see its notes."
        }

        switch selectedNotesScope {
        case .project:
            return notesSidebarRows.isEmpty
                ? "Shared notes for \(project.name) will show here. Use New note to start one."
                : "Shared notes for \(project.name)."
        case .thread:
            return notesSidebarRows.isEmpty
                ? "No thread notes yet for \(project.name). Start a thread note from the chat view first."
                : "Thread notes from chats that belong to \(project.name)."
        }
    }

    private func makeComposerWebState(
        isNotesWorkspaceAssistant: Bool
    ) -> AssistantComposerWebState {
        let localBackendNeedsSetup =
            assistant.visibleAssistantBackend == .ollamaLocal
            && !assistant.isLoadingModels
            && !assistant.visibleModels.contains(where: \.isInstalled)
        let isCompactComposer = isNotesWorkspaceAssistant
        let isNoteModeActive = isNotesWorkspaceAssistant || assistant.taskMode == .note
        let runtimeControlsState = assistant.runtimeControlsState(
            for: assistant.visibleAssistantBackend,
            availableModels: assistant.visibleModels,
            isLoadingModels: assistant.isLoadingModels,
            isBusy: composerCanCancelActiveTurn
        )
        let noteModeLabel: String?
        let noteModeHelperText: String?

        if isNotesWorkspaceAssistant {
            noteModeLabel = nil
            noteModeHelperText = nil
        } else if assistant.taskMode == .note {
            noteModeLabel = "Note Mode"
            noteModeHelperText =
                activeSessionProject.map {
                    "Whole project scope: \($0.name)"
                } ?? assistant.selectedProject.map {
                    "Whole project scope: \($0.name)"
                } ?? "The assistant will prefer project notes and thread notes."
        } else {
            noteModeLabel = nil
            noteModeHelperText = nil
        }

        return AssistantComposerWebState(
            base: AssistantComposerWebBaseState(
                draftText: assistant.promptDraft,
                placeholder: composerPlaceholder(
                    isNoteModeActive: isNoteModeActive,
                    isNotesWorkspaceAssistant: isNotesWorkspaceAssistant
                ),
                isCompactComposer: isCompactComposer,
                isEnabled: settings.assistantBetaEnabled && !isVoiceCapturing,
                canSend: canSendMessage && !isVoiceCapturing,
                isNoteModeActive: isNoteModeActive,
                noteModeLabel: noteModeLabel,
                noteModeHelperText: noteModeHelperText,
                showNoteModeButton: !isNotesWorkspaceAssistant,
                canOpenSkills: isCompactComposer
                    ? false : assistant.canAttachSkillsToSelectedThread,
                canOpenPlugins: !isCompactComposer && assistant.canUseCodexPlugins,
                preflightStatusMessage: isCompactComposer
                    ? notesAssistantPreflightStatusMessage : nil,
                activeSkills: assistant.activeThreadSkills.map {
                    AssistantComposerWebSkill(
                        skillName: $0.skillName,
                        displayName: $0.displayName,
                        isMissing: $0.isMissing
                    )
                },
                selectedPlugins: assistant.visibleSelectedComposerPlugins.map {
                    AssistantComposerWebPlugin(
                        pluginID: $0.pluginID,
                        displayName: $0.displayName,
                        summary: $0.summary,
                        needsSetup: $0.needsSetup,
                        iconDataURL: $0.iconDataURL
                    )
                },
                availablePlugins: assistant.installedCodexPluginSelections.map {
                    AssistantComposerWebPlugin(
                        pluginID: $0.pluginID,
                        displayName: $0.displayName,
                        summary: $0.summary,
                        needsSetup: $0.needsSetup,
                        iconDataURL: nil
                    )
                },
                attachments: assistant.attachments.map {
                    AssistantComposerWebAttachment(
                        id: $0.id.uuidString,
                        filename: $0.filename,
                        kind: $0.isImage ? "image" : "file",
                        previewDataURL: $0.previewDataURL
                    )
                },
                activeProviderID: assistant.visibleAssistantBackend.rawValue,
                slashCommands: AssistantSlashCommandCatalog.composerCommands(
                    for: assistant.visibleAssistantBackend
                ).map(AssistantComposerWebSlashCommand.init(descriptor:)),
                noteContext: composerNoteContextForState
            ),
            controls: AssistantComposerWebControlsState(
                availability: runtimeControlsState.availability,
                availabilityStatusText: runtimeControlsState.statusText.nonEmpty,
                showsInteractionModeControl: !isCompactComposer,
                showsModelControls: !isCompactComposer,
                showsReasoningControls: !isCompactComposer,
                selectedInteractionMode: assistant.interactionMode.normalizedForActiveUse.rawValue,
                interactionModes: AssistantInteractionMode.allCases.map {
                    AssistantComposerWebOption(id: $0.rawValue, label: $0.label)
                },
                selectedModelID: assistant.selectedModelID,
                modelOptions: assistant.visibleModels.map {
                    AssistantComposerWebOption(id: $0.id, label: $0.displayName)
                },
                modelPlaceholder: localBackendNeedsSetup ? "Install model" : "Select model",
                opensModelSetupWhenUnavailable: localBackendNeedsSetup,
                selectedReasoningID: assistant.reasoningEffort.rawValue,
                reasoningOptions: supportedEfforts.map {
                    AssistantComposerWebOption(id: $0.rawValue, label: $0.label)
                }
            ),
            activity: AssistantComposerWebActivityState(
                isBusy: composerCanCancelActiveTurn,
                activeTurnPhase: composerActiveTurnPhase,
                canCancelActiveTurn: composerCanCancelActiveTurn,
                canSteerActiveTurn: composerCanSteerActiveTurn,
                activeTurnProviderLabel: assistant.visibleAssistantBackend.shortDisplayName,
                hasPendingToolApproval: composerHasPendingToolApproval,
                hasPendingInput: composerHasPendingInput,
                isVoiceCapturing: isVoiceCapturing,
                canUseVoiceInput: settings.assistantVoiceTaskEntryEnabled,
                showStopVoicePlayback: assistant.assistantVoicePlaybackActive
                    && !composerCanCancelActiveTurn
            )
        )
    }

    private var composerWebState: AssistantComposerWebState {
        makeComposerWebState(isNotesWorkspaceAssistant: false)
    }

    private var notesAssistantComposerWebState: AssistantComposerWebState {
        makeComposerWebState(isNotesWorkspaceAssistant: true)
    }

    private var sidebarSessionAnimationKey: String {
        (assistant.visibleSidebarSessions + assistant.visibleArchivedSidebarSessions).map {
            session in
            let updatedAt = session.updatedAt ?? session.createdAt ?? .distantPast
            return
                "\(session.id)|\(session.title)|\(session.isArchived)|\(updatedAt.timeIntervalSince1970)"
        }
        .joined(separator: "||")
    }

    private var archiveRetentionOptions: [Int] {
        Array(Set([24, 24 * 7, 24 * 30, settings.assistantArchiveDefaultRetentionHours])).sorted()
    }

    private var projectThreadCountByProjectID: [String: Int] {
        sidebarVisibleSessionsIgnoringProjectFilter.reduce(into: [:]) { result, session in
            guard
                let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            else {
                return
            }
            result[projectID, default: 0] += 1
        }
    }

    private func normalizedSidebarProjectID(_ projectID: String?) -> String? {
        projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty?.lowercased()
    }

    private var storedExpandedFolderIDs: Set<String> {
        Set(
            expandedFolderIDsRaw
                .split(separator: ",")
                .compactMap { normalizedSidebarProjectID(String($0)) }
        )
    }

    private func persistExpandedFolderIDs(_ folderIDs: Set<String>) {
        expandedFolderIDsRaw = folderIDs.sorted().joined(separator: ",")
    }

    private func setFolderExpanded(_ folderID: String, expanded: Bool) {
        guard let normalizedFolderID = normalizedSidebarProjectID(folderID) else { return }
        var folderIDs = storedExpandedFolderIDs
        if expanded {
            folderIDs.insert(normalizedFolderID)
        } else {
            folderIDs.remove(normalizedFolderID)
        }
        persistExpandedFolderIDs(folderIDs)
    }

    private var effectiveExpandedFolderIDs: Set<String> {
        let visibleFolderIDs = Set(
            assistant.visibleFolders.compactMap { normalizedSidebarProjectID($0.id) })
        var folderIDs = storedExpandedFolderIDs.intersection(visibleFolderIDs)
        if let selectedProjectParentID = normalizedSidebarProjectID(
            assistant.selectedProject?.parentID)
        {
            folderIDs.insert(selectedProjectParentID)
        }
        return folderIDs
    }

    private var storedExpandedNoteFolderIDs: Set<String> {
        Set(
            expandedNoteFolderIDsRaw
                .split(separator: ",")
                .compactMap { normalizedSidebarProjectID(String($0)) }
        )
    }

    private func persistExpandedNoteFolderIDs(_ folderIDs: Set<String>) {
        expandedNoteFolderIDsRaw = folderIDs.sorted().joined(separator: ",")
    }

    private func setNoteFolderExpanded(_ folderID: String, expanded: Bool) {
        guard let normalizedFolderID = normalizedSidebarProjectID(folderID) else { return }
        var folderIDs = storedExpandedNoteFolderIDs
        if expanded {
            folderIDs.insert(normalizedFolderID)
        } else {
            folderIDs.remove(normalizedFolderID)
        }
        persistExpandedNoteFolderIDs(folderIDs)
    }

    private func setNoteFolderPathExpanded(
        folderID: String?,
        folders: [AssistantNoteFolderSummary]
    ) {
        guard let normalizedFolderID = normalizedSidebarProjectID(folderID) else { return }
        let foldersByID = Dictionary(
            uniqueKeysWithValues: folders.compactMap { folder in
                normalizedSidebarProjectID(folder.id).map { ($0, folder) }
            }
        )
        var folderIDs = storedExpandedNoteFolderIDs
        var cursor = normalizedFolderID
        while let folder = foldersByID[cursor] {
            folderIDs.insert(cursor)
            guard let parentFolderID = normalizedSidebarProjectID(folder.parentFolderID) else { break }
            cursor = parentFolderID
        }
        persistExpandedNoteFolderIDs(folderIDs)
    }

    private var visibleRootFolders: [AssistantProject] {
        assistant.visibleFolders.filter { $0.parentID == nil }
    }

    private var visibleRootStandaloneProjects: [AssistantProject] {
        assistant.visibleLeafProjects.filter { $0.parentID == nil }
    }

    private func visibleChildProjects(for folder: AssistantProject) -> [AssistantProject] {
        assistant.visibleLeafProjects.filter {
            $0.parentID?.caseInsensitiveCompare(folder.id) == .orderedSame
        }
    }

    private var displayedSidebarProjects: [AssistantProject] {
        var items: [AssistantProject] = []
        for folder in visibleRootFolders {
            items.append(folder)
            if effectiveExpandedFolderIDs.contains(folder.id.lowercased()) {
                items.append(contentsOf: visibleChildProjects(for: folder))
            }
        }
        items.append(contentsOf: visibleRootStandaloneProjects)
        return items
    }

    private var isProjectFocusModeActive: Bool {
        assistant.selectedProjectFilter != nil
    }

    private var currentProjectFilterKind: String {
        switch assistant.selectedProjectFilter {
        case .folder:
            return "folder"
        case .project:
            return "project"
        case nil:
            return "all"
        }
    }

    private var projectSectionTitle: String {
        "Projects"
    }

    private var sidebarProjectsHelperText: String? {
        switch assistant.selectedProjectFilter {
        case .folder(let folderID):
            let folderName = assistant.selectedFolder?.name ?? "this group"
            let childCount = projectCount(inFolderID: folderID)
            if childCount == 0 {
                return "Only chats from \(folderName) are shown. This group has no projects yet."
            }
            return
                "Showing chats from all \(childCount) project\(childCount == 1 ? "" : "s") inside \(folderName). Click it again to go back."
        case .project:
            return "Click the current project again to go back to all projects."
        case nil:
            break
        }

        let hiddenProjectCount = assistant.hiddenProjects.count
        guard hiddenProjectCount > 0 else {
            return nil
        }
        return hiddenProjectCount == 1
            ? "1 group or project is hidden right now."
            : "\(hiddenProjectCount) groups or projects are hidden right now."
    }

    private var threadsFilterHelperText: String? {
        if let folder = assistant.selectedFolder {
            return
                "Only chats inside the group \(folder.name) are shown. New chats start ungrouped until you move them into a project."
        }
        guard let project = assistant.selectedProject else { return nil }
        return "Only \(project.name) chats are shown. New chats stay here."
    }

    private func projectThreadSubtitle(for project: AssistantProject, focused: Bool) -> String {
        if project.isFolder {
            let childCount = visibleChildProjects(for: project).count
            let threadCount = threadCount(inFolder: project)
            if childCount == 0 {
                return "No projects yet"
            }
            let projectLabel = "\(childCount) project\(childCount == 1 ? "" : "s")"
            let threadLabel: String
            switch threadCount {
            case 0:
                threadLabel = "no chats"
            case 1:
                threadLabel = "1 chat"
            default:
                threadLabel = "\(threadCount) chats"
            }
            return focused
                ? "\(projectLabel) · \(threadLabel) here" : "\(projectLabel) · \(threadLabel)"
        }

        let count = projectThreadCountByProjectID[project.id.lowercased(), default: 0]

        switch count {
        case 0:
            return focused ? "No chats here yet" : "No chats yet"
        case 1:
            return focused ? "1 chat here" : "1 chat"
        default:
            return focused ? "\(count) chats here" : "\(count) chats"
        }
    }

    private func noteCount(
        in project: AssistantProject,
        scope: AssistantNotesScope
    ) -> Int {
        let universe = notesUniverse(for: project)
        switch scope {
        case .project:
            return universe.projectNotes.count
        case .thread:
            return universe.threadSources.reduce(into: 0) { count, source in
                count += source.notes.count
            }
        }
    }

    private func noteCount(
        inFolder folder: AssistantProject,
        scope: AssistantNotesScope
    ) -> Int {
        visibleChildProjects(for: folder).reduce(into: 0) { count, project in
            guard project.isProject else { return }
            count += noteCount(in: project, scope: scope)
        }
    }

    private func projectNotesSubtitle(for project: AssistantProject, focused: Bool) -> String {
        let scope = selectedNotesScope
        if project.isFolder {
            let childCount = visibleChildProjects(for: project).count
            let totalNotes = noteCount(inFolder: project, scope: scope)
            if childCount == 0 {
                return "No projects yet"
            }
            let projectLabel = "\(childCount) project\(childCount == 1 ? "" : "s")"
            let notesLabel: String
            switch totalNotes {
            case 0:
                notesLabel = "no notes"
            case 1:
                notesLabel = "1 note"
            default:
                notesLabel = "\(totalNotes) notes"
            }
            return focused
                ? "\(projectLabel) · \(notesLabel) here" : "\(projectLabel) · \(notesLabel)"
        }

        let count = noteCount(in: project, scope: scope)
        switch count {
        case 0:
            return focused ? "No notes here yet" : "No notes yet"
        case 1:
            return focused ? "1 note here" : "1 note"
        default:
            return focused ? "\(count) notes here" : "\(count) notes"
        }
    }

    private func projectCount(inFolderID folderID: String) -> Int {
        assistant.visibleLeafProjects.filter {
            $0.parentID?.caseInsensitiveCompare(folderID) == .orderedSame
        }.count
    }

    private func threadCount(inFolder folder: AssistantProject) -> Int {
        let projectIDs = Set(
            visibleChildProjects(for: folder).map {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        )
        guard !projectIDs.isEmpty else { return 0 }
        return sidebarVisibleSessionsIgnoringProjectFilter.reduce(into: 0) { count, session in
            guard
                let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty?.lowercased(),
                projectIDs.contains(projectID)
            else {
                return
            }
            count += 1
        }
    }

    private func sidebarProjectMenuTitle(for project: AssistantProject) -> String {
        guard let parentID = project.parentID,
            let parent = assistant.visibleFolders.first(where: {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(parentID) == .orderedSame
            })
        else {
            return project.name
        }
        return "\(parent.name) / \(project.name)"
    }

    private func sidebarProjectDepth(for project: AssistantProject) -> Int {
        project.parentID == nil ? 0 : 1
    }

    private func sidebarWebProject(
        for project: AssistantProject,
        selectedProjectID: String?
    ) -> AssistantSidebarWebProject {
        let isSelected = selectedProjectID?.caseInsensitiveCompare(project.id) == .orderedSame
        let linkedFolderPath = project.linkedFolderPath?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nonEmpty
        let subtitle =
            selectedSidebarPane == .notes
            ? projectNotesSubtitle(for: project, focused: isSelected)
            : projectThreadSubtitle(for: project, focused: isSelected)
        return AssistantSidebarWebProject(
            id: project.id,
            name: project.name,
            symbol: project.displayIconSymbolName,
            subtitle: subtitle,
            kind: project.kind.rawValue,
            depth: sidebarProjectDepth(for: project),
            isSelected: isSelected,
            isExpanded: project.isFolder
                && effectiveExpandedFolderIDs.contains(project.id.lowercased()),
            parentID: project.parentID,
            menuTitle: sidebarProjectMenuTitle(for: project),
            hasLinkedFolder: linkedFolderPath != nil,
            hasCustomIcon: project.iconSymbolName?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty != nil,
            folderMissing: project.isProject && linkedFolderPath != nil
                && assistant.sessions.contains(where: {
                    $0.projectID?.caseInsensitiveCompare(project.id) == .orderedSame
                        && $0.projectFolderMissing
                })
        )
    }

    private func showArchivedSidebar() {
        closeProjectNotesIfNeeded()
        selectedSidebarPane = .archived
        guard let firstArchivedSession = assistant.visibleArchivedSidebarSessions.first else {
            return
        }
        let isAlreadySelected =
            assistant.selectedSessionID?.caseInsensitiveCompare(firstArchivedSession.id)
            == .orderedSame
        guard !isAlreadySelected else { return }
        Task { await assistant.openSession(firstArchivedSession) }
    }

    private func sidebarWebSession(for session: AssistantSessionSummary)
        -> AssistantSidebarWebSession
    {
        AssistantSidebarWebSession(
            id: session.id,
            title: session.title,
            subtitle: session.subtitle,
            timeLabel: sidebarTimeLabel(for: session),
            activityState: sidebarActivityStateLabel(for: session),
            isSelected: assistant.selectedSessionID.map {
                assistantTimelineSessionIDsMatch(session.id, $0)
            } ?? false,
            isTemporary: session.isTemporary,
            projectID: session.projectID
        )
    }

    private func sidebarWebNote(for row: AssistantSidebarNoteRowModel) -> AssistantSidebarWebNote {
        AssistantSidebarWebNote(
            id: row.id,
            noteID: row.target.noteID,
            ownerKind: row.target.ownerKind.rawValue,
            ownerID: row.target.ownerID,
            title: row.title,
            subtitle: row.subtitle,
            sourceLabel: row.sourceLabel,
            folderID: row.folderID,
            folderPath: row.folderPath,
            isSelected: currentDisplayedNoteTarget == row.target,
            isArchivedThread: row.isArchivedThread,
            threadID: row.threadID
        )
    }

    private func sidebarWebNoteFolder(
        for row: AssistantSidebarNoteFolderRowModel
    ) -> AssistantSidebarWebNoteFolder {
        AssistantSidebarWebNoteFolder(
            id: row.id,
            name: row.name,
            parentID: row.parentFolderID,
            path: row.path,
            isExpanded: row.isExpanded,
            childFolderCount: row.childFolderCount,
            noteCount: row.noteCount
        )
    }

    private func sidebarTimeLabel(for session: AssistantSessionSummary) -> String? {
        guard let referenceDate = session.updatedAt ?? session.createdAt else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(referenceDate)))

        switch seconds {
        case 0..<(60 * 60):
            return "\(max(1, seconds / 60))m"
        case (60 * 60)..<(60 * 60 * 24):
            return "\(max(1, seconds / (60 * 60)))h"
        default:
            return "\(max(1, seconds / (60 * 60 * 24)))d"
        }
    }

    private func sidebarActivityStateLabel(for session: AssistantSessionSummary) -> String? {
        switch sidebarActivityState(for: session) {
        case .idle:
            return nil
        case .running:
            return "running"
        case .waiting:
            return "waiting"
        case .failed:
            return "failed"
        }
    }

    private func setSidebarCollapsed(_ collapsed: Bool) {
        withAnimation(sidebarToggleAnimation) {
            isSidebarCollapsed = collapsed
            collapsedSidebarPreviewPane = nil
        }
    }

    private func prepareProjectNotesFocusMode() {
        projectNotesSidebarRestoreState = assistantProjectNotesRememberedSidebarCollapsed(
            currentRestoreState: projectNotesSidebarRestoreState,
            persistedSidebarCollapsed: isSidebarCollapsed
        )
        withAnimation(sidebarToggleAnimation) {
            collapsedSidebarPreviewPane = nil
        }
        dismissTopBarDropdowns()
    }

    private func restoreProjectNotesSidebarStateIfNeeded() {
        let restoredSidebarCollapsed = assistantProjectNotesRestoredSidebarCollapsed(
            persistedSidebarCollapsed: isSidebarCollapsed,
            restoreState: projectNotesSidebarRestoreState
        )
        withAnimation(sidebarToggleAnimation) {
            isSidebarCollapsed = restoredSidebarCollapsed
            collapsedSidebarPreviewPane = nil
        }
        projectNotesSidebarRestoreState = nil
    }

    private func closeProjectNotesIfNeeded() {
        guard currentProjectNotesProject != nil || projectNotesSidebarRestoreState != nil else {
            return
        }
        persistThreadNoteIfNeeded(for: currentThreadNoteOwner)
        threadsDetailMode = .chat
        restoreProjectNotesSidebarStateIfNeeded()
        dismissTopBarDropdowns()
    }

    private func sidebarProject(for projectID: String) -> AssistantProject? {
        let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProjectID.isEmpty else { return nil }
        return assistant.projects.first {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }
    }

    private func sidebarSession(for sessionID: String) -> AssistantSessionSummary? {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }
        return assistant.sessions.first {
            assistantTimelineSessionIDsMatch($0.id, normalizedSessionID)
        }
    }

    private func archiveRetentionLabel(for hours: Int) -> String {
        if hours % (24 * 30) == 0 {
            let months = max(1, hours / (24 * 30))
            return months == 1 ? "1 month" : "\(months) months"
        }
        if hours % (24 * 7) == 0 {
            let weeks = max(1, hours / (24 * 7))
            return weeks == 1 ? "1 week" : "\(weeks) weeks"
        }
        if hours % 24 == 0 {
            let days = max(1, hours / 24)
            return days == 1 ? "24 hours" : "\(days) days"
        }
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    private func startNewThreadFromSidebar() {
        guard prepareToLeaveCurrentNoteScreen(reason: "start a new thread") else { return }
        selectedSidebarPane = .threads
        closeProjectNotesIfNeeded()
        threadsDetailMode = .chat
        if !areThreadsExpanded {
            withAnimation(sidebarDisclosureAnimation) {
                areThreadsExpanded = true
            }
        }
        Task { await assistant.startNewSession() }
    }

    private func startNewTemporaryThreadFromSidebar() {
        guard prepareToLeaveCurrentNoteScreen(reason: "start a temporary thread") else { return }
        selectedSidebarPane = .threads
        closeProjectNotesIfNeeded()
        threadsDetailMode = .chat
        if !areThreadsExpanded {
            withAnimation(sidebarDisclosureAnimation) {
                areThreadsExpanded = true
            }
        }
        Task { await assistant.startNewTemporarySession() }
    }

    private func handleSidebarWebCommand(type: String, payload: [String: Any]?) {
        switch type {
        case "newThread":
            startNewThreadFromSidebar()
        case "newTemporaryThread":
            startNewTemporaryThreadFromSidebar()
        case "setSidebarCollapsed":
            guard let collapsed = payload?["collapsed"] as? Bool else { return }
            setSidebarCollapsed(collapsed)
        case "setSelectedPane":
            guard let paneID = payload?["pane"] as? String,
                let pane = AssistantSidebarPane(shellID: paneID)
            else {
                return
            }
            guard pane == selectedSidebarPane || prepareToLeaveCurrentNoteScreen(reason: "switch screens") else {
                return
            }
            if pane == .archived {
                showArchivedSidebar()
            } else {
                if pane != .threads {
                    closeProjectNotesIfNeeded()
                }
                selectedSidebarPane = pane
                if pane == .notes {
                    ensureNotesProjectSelectionIfNeeded()
                }
            }
        case "setCollapsedPreviewPane":
            let isOpen = payload?["open"] as? Bool ?? false
            let paneID = (payload?["pane"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            withAnimation(sidebarToggleAnimation) {
                collapsedSidebarPreviewPane = isOpen ? paneID : nil
            }
        case "toggleProjectsExpanded":
            withAnimation(sidebarDisclosureAnimation) {
                areProjectsExpanded.toggle()
            }
        case "toggleThreadsExpanded":
            withAnimation(sidebarDisclosureAnimation) {
                areThreadsExpanded.toggle()
            }
        case "toggleArchivedExpanded":
            withAnimation(sidebarDisclosureAnimation) {
                areArchivedExpanded.toggle()
            }
        case "toggleNotesExpanded":
            withAnimation(sidebarDisclosureAnimation) {
                areNotesExpanded.toggle()
            }
        case "selectProjectFilter":
            guard prepareToLeaveCurrentNoteScreen(reason: "switch screens") else { return }
            selectedSidebarPane = .threads
            let projectID = (payload?["projectId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            if let projectID,
                let project = sidebarProject(for: projectID),
                let parentID = project.parentID
            {
                setFolderExpanded(parentID, expanded: true)
            }
            if let projectID,
                let project = sidebarProject(for: projectID)
            {
                closeProjectNotesIfNeeded()
                threadsDetailMode = .chat
                Task { await assistant.selectProjectFilter(project.id) }
            } else {
                closeProjectNotesIfNeeded()
                threadsDetailMode = .chat
                Task { await assistant.selectProjectFilter(nil) }
            }
        case "selectNotesProject":
            let projectID = (payload?["projectId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            if let projectID,
                let project = sidebarProject(for: projectID)
            {
                guard project.isProject else { return }
                selectNotesProject(project)
            } else {
                selectedNotesProjectID = nil
                ensureNotesProjectSelectionIfNeeded()
                selectedSidebarPane = .notes
            }
        case "setNotesScope":
            guard
                let scopeRawValue = (payload?["scope"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let scope = AssistantNotesScope(rawValue: scopeRawValue)
            else {
                return
            }
            setNotesScope(scope)
        case "selectSidebarNote":
            guard
                let ownerKindRawValue = (payload?["ownerKind"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let ownerKind = AssistantNoteOwnerKind(rawValue: ownerKindRawValue),
                let ownerID = (payload?["ownerId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let noteID = (payload?["noteId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            selectSidebarNote(owner: .init(kind: ownerKind, id: ownerID), noteID: noteID)
        case "toggleNoteFolderExpanded":
            guard
                let folderID = (payload?["folderId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let expanded = payload?["expanded"] as? Bool
            else {
                return
            }
            setNoteFolderExpanded(folderID, expanded: expanded)
        case "createSidebarNote":
            guard let project = selectedNotesProject,
                selectedNotesScope == .project
            else {
                return
            }
            let folderID = (payload?["folderId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            createSidebarProjectNote(project: project, folderID: folderID)
        case "createNoteFolderPrompt":
            guard let project = selectedNotesProject,
                selectedNotesScope == .project
            else {
                return
            }
            let parentFolderID = (payload?["parentFolderId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            presentCreateNoteFolderPrompt(for: project, parentFolderID: parentFolderID)
        case "renameNoteFolderPrompt":
            guard let project = selectedNotesProject,
                selectedNotesScope == .project,
                let folderID = (payload?["folderId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            presentRenameNoteFolderPrompt(for: project, folderID: folderID)
        case "moveNoteFolderPrompt":
            guard let project = selectedNotesProject,
                selectedNotesScope == .project,
                let folderID = (payload?["folderId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            presentMoveNoteFolderPrompt(for: project, folderID: folderID)
        case "moveNoteFolder":
            guard let project = selectedNotesProject,
                selectedNotesScope == .project,
                let folderID = (payload?["folderId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            let parentFolderID = (payload?["parentFolderId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            guard let workspace = assistant.moveProjectNoteFolder(
                projectID: project.id,
                folderID: folderID,
                parentFolderID: parentFolderID
            ) else {
                return
            }
            let targetFolderID = parentFolderID ?? folderID
            setNoteFolderPathExpanded(
                folderID: targetFolderID,
                folders: workspace.manifest.folders
            )
            applyThreadNoteWorkspace(workspace)
        case "deleteNoteFolder":
            guard let project = selectedNotesProject,
                selectedNotesScope == .project,
                let folderID = (payload?["folderId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let workspace = assistant.deleteProjectNoteFolder(
                    projectID: project.id,
                    folderID: folderID
                )
            else {
                return
            }
            setNoteFolderExpanded(folderID, expanded: false)
            applyThreadNoteWorkspace(workspace)
        case "deleteSidebarProjectNote":
            guard let project = selectedNotesProject,
                selectedNotesScope == .project,
                let noteID = (payload?["noteId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            let owner = AssistantNoteOwnerKey(kind: .project, id: project.id)
            guard let workspace = assistant.deleteProjectNote(
                projectID: project.id,
                noteID: noteID
            ) else {
                return
            }
            removeNoteFromNavigationStacks(owner: owner, noteID: noteID)
            applyThreadNoteWorkspace(workspace)
            clearThreadNoteAIDraftState(for: owner)
            clearThreadNoteProjectTransferState(for: owner)
            clearThreadNoteProjectTransferOutcome(for: owner)
        case "moveSidebarProjectNote":
            guard let project = selectedNotesProject,
                selectedNotesScope == .project,
                let noteID = (payload?["noteId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            let folderID = (payload?["folderId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            guard let workspace = assistant.moveProjectNote(
                projectID: project.id,
                noteID: noteID,
                folderID: folderID
            ) else {
                return
            }
            if let folderID {
                setNoteFolderPathExpanded(
                    folderID: folderID,
                    folders: workspace.manifest.folders
                )
            }
            rememberNotesSelectionTarget(
                AssistantNoteLinkTarget(ownerKind: .project, ownerID: project.id, noteID: noteID),
                projectID: project.id,
                scope: .project
            )
            applyThreadNoteWorkspace(workspace)
        case "toggleProjectExpanded":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let project = sidebarProject(for: projectID),
                project.isFolder
            else {
                return
            }
            let expanded =
                payload?["expanded"] as? Bool
                ?? !effectiveExpandedFolderIDs.contains(project.id.lowercased())
            setFolderExpanded(project.id, expanded: expanded)
        case "openSession":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            guard prepareToLeaveCurrentNoteScreen(reason: "open another thread") else { return }
            if let paneID = payload?["pane"] as? String,
                paneID.caseInsensitiveCompare(AssistantSidebarPane.archived.shellID) == .orderedSame
            {
                selectedSidebarPane = .archived
            } else {
                selectedSidebarPane = .threads
            }
            openThread(sessionID)
        case "loadMoreSessions":
            assistant.loadMoreSessions()
        case "createProjectPrompt":
            presentCreateProjectPrompt(parentFolder: assistant.selectedFolder)
        case "createFolderPrompt":
            presentCreateFolderPrompt()
        case "createProjectFromFolderPrompt":
            presentCreateProjectFromFolderPrompt(parentFolder: nil)
        case "createNamedProjectPrompt":
            presentNamedProjectPrompt(parentFolder: nil)
        case "createProjectInFolderPrompt":
            guard
                let folderID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let folder = sidebarProject(for: folderID),
                folder.isFolder
            else {
                return
            }
            presentNamedProjectPrompt(parentFolder: folder)
        case "moveProjectToFolderPrompt":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let project = sidebarProject(for: projectID)
            else {
                return
            }
            presentMoveProjectPrompt(for: project)
        case "moveProjectToFolder":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let folderID = (payload?["folderId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let folder = sidebarProject(for: folderID),
                folder.isFolder
            else {
                return
            }
            setFolderExpanded(folder.id, expanded: true)
            assistant.moveProject(projectID, toFolderID: folder.id)
        case "moveProjectToRoot":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            assistant.moveProject(projectID, toFolderID: nil)
        case "unhideProject":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            Task { await assistant.unhideProject(projectID) }
        case "openProjectNotes", "inspectProjectMemory":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let project = sidebarProject(for: projectID)
            else {
                return
            }
            guard project.isProject else { return }
            openProjectNotes(for: project)
        case "renameProjectPrompt":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let project = sidebarProject(for: projectID)
            else {
                return
            }
            presentRenameProjectPrompt(for: project)
        case "changeProjectIconPrompt":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let project = sidebarProject(for: projectID)
            else {
                return
            }
            presentProjectIconPrompt(for: project)
        case "setProjectIcon":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            let symbol = (payload?["symbol"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            assistant.updateProjectIcon(projectID, symbol: symbol)
        case "linkProjectFolder":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let project = sidebarProject(for: projectID)
            else {
                return
            }
            guard project.isProject else { return }
            presentProjectFolderPicker(for: project)
        case "removeProjectFolderLink":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            assistant.updateProjectLinkedFolder(projectID, path: nil)
        case "hideProject":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            Task { await assistant.hideProject(projectID) }
        case "deleteProject":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let project = sidebarProject(for: projectID)
            else {
                return
            }
            pendingDeleteProject = project
        case "renameSessionPrompt":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let session = sidebarSession(for: sessionID)
            else {
                return
            }
            presentRenameSessionPrompt(for: session)
        case "promoteTemporarySession":
            let sessionID = (payload?["sessionId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            assistant.promoteTemporarySession(sessionID)
        case "assignSessionToProject":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            let projectID = (payload?["projectId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            assistant.assignSessionToProject(sessionID, projectID: projectID)
        case "removeSessionFromProject":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            assistant.assignSessionToProject(sessionID, projectID: nil)
        case "archiveSession":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            Task {
                await assistant.archiveSession(
                    sessionID,
                    retentionHours: settings.assistantArchiveDefaultRetentionHours,
                    updateDefaultRetention: false
                )
            }
        case "unarchiveSession":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            Task {
                await assistant.unarchiveSession(sessionID)
                guard selectedSidebarPane == .archived else { return }
                await MainActor.run {
                    showArchivedSidebar()
                }
            }
        case "deleteSessionPermanently":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let session = sidebarSession(for: sessionID)
            else {
                return
            }
            pendingPermanentDeleteSession = session
        case "openAssistantSetup":
            if presentationStyle == .compactSidebar {
                NotificationCenter.default.post(
                    name: .openAssistOpenSettings,
                    object: SettingsRoute(section: .assistant, subsection: .assistantSetup)
                )
            } else {
                NotificationCenter.default.post(name: .openAssistOpenAssistantSetup, object: nil)
            }
        default:
            break
        }
    }

    private func handleComposerWebCommand(type: String, payload: [String: Any]?) {
        switch type {
        case "updatePromptDraft":
            assistant.promptDraft = (payload?["text"] as? String) ?? ""
        case "sendPrompt":
            sendCurrentPrompt()
            dismissComposerQuickActionsMenu()
        case "openFilePicker":
            openFilePicker()
            dismissComposerQuickActionsMenu()
        case "captureScreenshotAttachment":
            dismissComposerQuickActionsMenu()
            captureComposerScreenshotAttachment()
        case "openSkillsPane":
            dismissComposerQuickActionsMenu()
            guard prepareToLeaveCurrentNoteScreen(reason: "open Skills") else { return }
            selectedSidebarPane = .skills
        case "openPluginsPane":
            dismissComposerQuickActionsMenu()
            guard prepareToLeaveCurrentNoteScreen(reason: "open Plugins") else { return }
            selectedSidebarPane = .plugins
            Task { await assistant.refreshCodexPluginCatalogIfNeeded() }
        case "toggleQuickActionsMenu":
            toggleComposerQuickActionsMenu()
        case "dismissNoteContext":
            if let ctx = composerNoteContextForState {
                composerNoteContextDismissedKeys.insert(ctx.contextKey)
                composerNoteContextIncludeContentKeys.remove(ctx.contextKey)
            }
        case "toggleNoteContextContent":
            if let ctx = composerNoteContextForState {
                if composerNoteContextIncludeContentKeys.contains(ctx.contextKey) {
                    composerNoteContextIncludeContentKeys.remove(ctx.contextKey)
                } else {
                    composerNoteContextIncludeContentKeys.insert(ctx.contextKey)
                }
            }
        case "removeAttachment":
            guard
                let attachmentID = (payload?["attachmentId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            assistant.attachments.removeAll {
                $0.id.uuidString.caseInsensitiveCompare(attachmentID) == .orderedSame
            }
        case "addAttachments":
            guard let rawAttachments = payload?["attachments"] as? [[String: Any]] else {
                return
            }

            let attachments = rawAttachments.compactMap { item -> AssistantAttachment? in
                let filename = (item["filename"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let dataURL = item["dataUrl"] as? String {
                    return AssistantAttachmentSupport.attachment(
                        fromDataURL: dataURL,
                        suggestedFilename: filename
                    )
                }
                return nil
            }

            guard !attachments.isEmpty else { return }
            assistant.attachments.append(contentsOf: attachments)
        case "detachSkill":
            guard
                let skillName = (payload?["skillName"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            assistant.detachSkill(skillName)
        case "repairMissingSkillBindings":
            assistant.repairMissingSkillBindings()
        case "selectComposerPlugin":
            guard
                let pluginID = (payload?["pluginId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            if let updatedDraft = payload?["draftText"] as? String {
                assistant.promptDraft = updatedDraft
            }
            assistant.selectComposerPlugin(pluginID: pluginID)
        case "removeComposerPlugin":
            guard
                let pluginID = (payload?["pluginId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            assistant.removeComposerPlugin(pluginID: pluginID)
        case "setInteractionMode":
            guard let rawMode = payload?["mode"] as? String,
                let mode = AssistantInteractionMode(rawValue: rawMode)
            else {
                return
            }
            assistant.interactionMode = mode
        case "setNoteMode":
            guard let isActive = payload?["active"] as? Bool else {
                return
            }
            assistant.taskMode = isActive ? .note : .chat
        case "setModel":
            guard
                let modelID = (payload?["modelId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            assistant.chooseModel(modelID)
        case "openModelSetup":
            assistant.runPreferredInstallCommand()
        case "setReasoningEffort":
            guard let effortID = payload?["effort"] as? String,
                let effort = AssistantReasoningEffort(rawValue: effortID)
            else {
                return
            }
            assistant.reasoningEffort = effort
        case "cancelActiveTurn":
            Task { await assistant.cancelActiveTurn() }
        case "startVoiceCapture":
            NotificationCenter.default.post(
                name: isCompactSidebarPresentation
                    ? .openAssistStartCompactVoiceCapture
                    : .openAssistStartAssistantVoiceCapture,
                object: nil
            )
        case "stopVoiceCapture":
            NotificationCenter.default.post(
                name: isCompactSidebarPresentation
                    ? .openAssistStopCompactVoiceCapture
                    : .openAssistStopAssistantVoiceCapture,
                object: nil
            )
        case "stopVoicePlayback":
            assistant.stopAssistantVoicePlayback()
        default:
            break
        }
    }

    private func chatLayoutMetrics(
        for windowWidth: CGFloat,
        windowHeight: CGFloat
    ) -> ChatLayoutMetrics {
        let safeWindowWidth = max(windowWidth, 640)
        let safeWindowHeight = max(windowHeight, 420)
        let outerPadding = safeWindowWidth < 900 ? 2.0 : 4.0
        let chromeState = projectNotesChromeState
        let sidebarWidth = scaledSidebarWidth(for: safeWindowWidth, outerPadding: outerPadding)
        let collapsedSidebarWidth = safeWindowWidth < 900 ? 60.0 : 64.0
        let collapsedSidebarPreviewWidth = min(sidebarWidth, max(248.0, safeWindowWidth * 0.28))
        let visibleSidebarWidth =
            chromeState.effectiveSidebarCollapsed && !chromeState.isFocusModeActive
            ? collapsedSidebarWidth
            : (chromeState.isFocusModeActive ? 0 : sidebarWidth)
        let detailWidth = max(
            320.0,
            safeWindowWidth - visibleSidebarWidth - (outerPadding * 2) - 0.5)
        let isNarrow = detailWidth < 760
        let isMedium = detailWidth < 1080
        let timelineHorizontalPadding =
            isCompactSidebarPresentation
            ? (isNarrow ? 10.0 : 16.0)
            : (isNarrow ? 16.0 : (isMedium ? 24.0 : 32.0))
        let maxColumnWidth =
            isNarrow
            ? detailWidth - (timelineHorizontalPadding * 2) : min(780.0, detailWidth * 0.82)
        let contentMaxWidth = max(
            280.0, min(detailWidth - (timelineHorizontalPadding * 2), maxColumnWidth))
        let topBarMaxWidth = min(detailWidth - 16, contentMaxWidth + (isNarrow ? 8 : 28))
        let composerMaxWidth = min(detailWidth - 16, contentMaxWidth + (isNarrow ? 0 : 18))
        let userBubbleMaxWidth = min(
            contentMaxWidth * (isNarrow ? 0.96 : 0.80), isNarrow ? 540.0 : 640.0)
        let userMediaMaxWidth = min(userBubbleMaxWidth, isNarrow ? 320.0 : 420.0)
        let assistantMediaMaxWidth = min(contentMaxWidth, isNarrow ? 440.0 : 660.0)
        let leadingReserve =
            isCompactSidebarPresentation
            ? (isNarrow ? 18.0 : 30.0)
            : (isNarrow ? 36.0 : (isMedium ? 56.0 : 80.0))
        let assistantTrailingPaddingRegular = isNarrow ? 8.0 : (isMedium ? 16.0 : 24.0)
        let assistantTrailingPaddingCompact = isNarrow ? 8.0 : (isMedium ? 12.0 : 20.0)
        let assistantTrailingPaddingStatus = isNarrow ? 8.0 : (isMedium ? 14.0 : 20.0)
        let activityLeadingPadding = isNarrow ? 10.0 : (isMedium ? 18.0 : 44.0)
        let activityTrailingPadding = isNarrow ? 10.0 : (isMedium ? 22.0 : 60.0)
        let jumpButtonTrailing = isNarrow ? 12.0 : 24.0
        let emptyStateCardWidth = min(contentMaxWidth, isNarrow ? 420.0 : 520.0)
        let emptyStateTextWidth = min(contentMaxWidth - 48, isNarrow ? 320.0 : 440.0)

        return ChatLayoutMetrics(
            windowWidth: safeWindowWidth,
            windowHeight: safeWindowHeight,
            sidebarWidth: sidebarWidth,
            collapsedSidebarWidth: collapsedSidebarWidth,
            collapsedSidebarPreviewWidth: collapsedSidebarPreviewWidth,
            visibleSidebarWidth: visibleSidebarWidth,
            detailWidth: detailWidth,
            outerPadding: outerPadding,
            timelineHorizontalPadding: timelineHorizontalPadding,
            contentMaxWidth: contentMaxWidth,
            topBarMaxWidth: topBarMaxWidth,
            composerMaxWidth: composerMaxWidth,
            userBubbleMaxWidth: userBubbleMaxWidth,
            userMediaMaxWidth: userMediaMaxWidth,
            assistantMediaMaxWidth: assistantMediaMaxWidth,
            leadingReserve: leadingReserve,
            assistantTrailingPaddingRegular: assistantTrailingPaddingRegular,
            assistantTrailingPaddingCompact: assistantTrailingPaddingCompact,
            assistantTrailingPaddingStatus: assistantTrailingPaddingStatus,
            activityLeadingPadding: activityLeadingPadding,
            activityTrailingPadding: activityTrailingPadding,
            jumpButtonTrailing: jumpButtonTrailing,
            emptyStateCardWidth: emptyStateCardWidth,
            emptyStateTextWidth: emptyStateTextWidth,
            isNarrow: isNarrow
        )
    }

    private func centeredDetailColumn<Content: View>(
        maxWidth: CGFloat,
        alignment: Alignment = .leading,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: maxWidth, alignment: alignment)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func assistantSplitBackground(layout: ChatLayoutMetrics) -> some View {
        return AppSplitChromeBackground(
            leadingPaneFraction: layout.visibleSidebarWidth > 0
                ? min(
                    0.32, max(0.12, layout.visibleSidebarWidth / max(layout.windowWidth, 1)))
                : 0,
            leadingPaneMaxWidth: isCompactSidebarPresentation ? 240 : 280,
            leadingPaneWidth: layout.visibleSidebarWidth,
            leadingTint: AppVisualTheme.sidebarTint,
            trailingTint: AppVisualTheme.assistantWindowBackgroundTint,
            accent: AppVisualTheme.assistantWindowChromeAccent,
            glowWarm: AppVisualTheme.assistantWindowGlowWarm,
            glowCool: AppVisualTheme.assistantWindowGlowCool,
            trailingMaterialOpacity: AppVisualTheme.isDarkAppearance ? 0.98 : 0.88,
            trailingTintOpacityWhenMaterial: AppVisualTheme.isDarkAppearance ? 0.40 : 0.18,
            trailingOverlayColor: AppVisualTheme.isDarkAppearance ? .black : .clear,
            trailingOverlayOpacity: AppVisualTheme.isDarkAppearance ? 0.28 : 0,
            leadingPaneTransparent: projectNotesChromeState.effectiveSidebarCollapsed,
            showsLeadingDivider: false
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = chatLayoutMetrics(
                for: proxy.size.width,
                windowHeight: proxy.size.height
            )
            let chromeState = projectNotesChromeState
            let collapsedOverlayWidth =
                collapsedSidebarPreviewPane == nil
                ? layout.collapsedSidebarWidth
                : layout.collapsedSidebarPreviewWidth

            ZStack(alignment: .leading) {
                assistantSplitBackground(layout: layout)

                HStack(spacing: 0) {
                    if chromeState.showsExpandedSidebar {
                        sidebar(layout: layout, width: layout.sidebarWidth)
                            .overlay(alignment: .trailing) {
                                if chromeState.showsResizeHandle {
                                    sidebarResizeHandle(layout: layout)
                                        .offset(x: 5)
                                        .zIndex(1)
                                }
                            }
                    } else if chromeState.showsCollapsedSidebarOverlay {
                        Color.clear
                            .frame(width: layout.collapsedSidebarWidth)
                    }

                    detailPane(layout: layout)
                }
                .padding(.horizontal, 0)
                .padding(.bottom, 0)

                if chromeState.showsCollapsedSidebarOverlay {
                    sidebar(layout: layout, width: collapsedOverlayWidth)
                        .padding(.leading, 0)
                        .padding(.bottom, 0)
                }
            }
        }
        .onAppear {
            recomputeVisibleRenderItems()
            syncSidebarVisibleSessionsLimitIfNeeded()
            syncAssistantNotesRuntimeContext()
            syncNotesAssistantConversationBinding()
            Task { await refreshEverything(refreshPermissions: true) }
        }
        .onChange(of: allRenderItems) { _ in
            recomputeVisibleRenderItems()
        }
        .onChange(of: visibleHistoryLimit) { _ in
            recomputeVisibleRenderItems()
        }
        .onChange(of: assistant.visibleSessionsLimit) { newValue in
            syncSidebarVisibleSessionsLimitIfNeeded(newValue: newValue)
        }
        .onChange(of: assistant.selectedSessionID) { _ in
            recomputeVisibleRenderItems()
        }
        .onChange(of: assistant.historyActionsRevision) { _ in
            cachedChatWebMessages = computeChatWebMessages()
        }
        .onChange(of: assistant.hasActiveTurn) { _ in
            cachedChatWebMessages = computeChatWebMessages()
        }
        .onChange(of: assistant.pendingPermissionRequest?.id) { _ in
            cachedChatWebMessages = computeChatWebMessages()
        }
        .onChange(of: assistant.lastAssistantNotesMutation?.id) { _ in
            refreshNotesAfterAssistantMutation(assistant.lastAssistantNotesMutation)
        }
        .alert(
            "Delete this archived chat forever?",
            isPresented: Binding(
                get: { pendingPermanentDeleteSession != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingPermanentDeleteSession = nil
                    }
                }
            ),
            presenting: pendingPermanentDeleteSession
        ) { session in
            Button("Delete Forever", role: .destructive) {
                pendingPermanentDeleteSession = nil
                Task {
                    await assistant.deleteSession(session.id)
                    guard selectedSidebarPane == .archived else { return }
                    await MainActor.run {
                        showArchivedSidebar()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPermanentDeleteSession = nil
            }
        } message: { session in
            Text("This permanently removes the archived chat “\(session.title)”.")
        }
        .alert(
            "Delete this notes chat forever?",
            isPresented: Binding(
                get: { pendingDeleteNotesAssistantSession != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteNotesAssistantSession = nil
                    }
                }
            ),
            presenting: pendingDeleteNotesAssistantSession
        ) { session in
            Button("Delete Forever", role: .destructive) {
                let selectedProject = selectedNotesProject
                pendingDeleteNotesAssistantSession = nil
                Task {
                    let resolvedProject =
                        selectedProject.flatMap { project in
                            assistantNormalizedNotesProjectID(project.id)
                                == assistantNormalizedNotesProjectID(session.projectID)
                                ? project : nil
                        }
                        ?? assistant.visibleLeafProjects.first(where: {
                            assistantNormalizedNotesProjectID($0.id)
                                == assistantNormalizedNotesProjectID(session.projectID)
                        })

                    guard let resolvedProject else {
                        await assistant.deleteSession(session.id)
                        return
                    }

                    await deleteNotesAssistantSession(session, in: resolvedProject)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteNotesAssistantSession = nil
            }
        } message: { session in
            Text("This permanently removes the saved notes chat “\(session.title)”.")
        }
        .alert(
            "Delete this item?",
            isPresented: Binding(
                get: { pendingDeleteProject != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteProject = nil
                    }
                }
            ),
            presenting: pendingDeleteProject
        ) { project in
            Button("Delete", role: .destructive) {
                Task { await assistant.deleteProject(project.id) }
                pendingDeleteProject = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteProject = nil
            }
        } message: { project in
            Text(
                project.isFolder
                    ? "This removes the Open Assist group “\(project.name)”. Projects inside it will move back to the top level."
                    : "This removes the Open Assist project “\(project.name)”. Chats will stay saved, but they will no longer belong to this project."
            )
        }
        .sheet(isPresented: $assistant.showBrowserProfilePicker) {
            BrowserProfilePickerSheet(
                onSelect: { profile in
                    assistant.selectBrowserProfile(profile)
                },
                onCancel: {
                    assistant.showBrowserProfilePicker = false
                }
            )
        }
        .sheet(isPresented: $assistant.showMemorySuggestionReview) {
            AssistantMemorySuggestionReviewSheet(assistant: assistant)
        }
        .sheet(
            isPresented: $assistant.showMemoryInspector,
            onDismiss: {
                assistant.dismissMemoryInspector()
            }
        ) {
            AssistantMemoryInspectorSheet(assistant: assistant)
        }
        .sheet(isPresented: $showGitHubSkillImportSheet) {
            AssistantGitHubSkillImportSheet { reference in
                Task { await assistant.importSkill(fromGitHubReference: reference) }
            }
        }
        .sheet(isPresented: $showSkillWizardSheet) {
            AssistantSkillWizardSheet { draft in
                assistant.createSkill(from: draft)
            }
        }
        .popover(item: $previewAttachment, attachmentAnchor: .point(.center)) { attachment in
            if let nsImage = NSImage(data: attachment.data) {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            previewAttachment = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(AppVisualTheme.foreground(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 800, maxHeight: 600)
                        .padding([.bottom, .horizontal])
                }
                .frame(minWidth: 400, minHeight: 300)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAssistAssistantZoomIn)) { _ in
            chatTextScale = min(2.0, chatTextScale + 0.1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAssistAssistantZoomOut)) { _ in
            chatTextScale = max(0.6, chatTextScale - 0.1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAssistAssistantZoomReset)) { _ in
            chatTextScale = 1.0
        }
        .onExitCommand {
            if isProjectNotesFocusMode {
                closeProjectNotesIfNeeded()
            } else {
                dismissTopBarDropdowns()
            }
        }
        .onAppear {
            if selectedSidebarPane != .skills && selectedSidebarPane != .plugins {
                lastNonSkillsSidebarPane = selectedSidebarPane
            }
            Task {
                if assistant.canUseCodexPlugins {
                    await assistant.refreshCodexPluginCatalogIfNeeded()
                } else {
                    assistant.clearComposerPlugins()
                }
            }
        }
        .onChange(of: selectedSidebarPane) { pane in
            if pane != .skills && pane != .plugins {
                lastNonSkillsSidebarPane = pane
            }
            if pane != .threads, currentProjectNotesProject != nil {
                closeProjectNotesIfNeeded()
            }
            if pane == .notes {
                ensureNotesProjectSelectionIfNeeded()
            }
            syncAssistantNotesRuntimeContext()
            syncNotesAssistantConversationBinding()
        }
        .onChange(of: selectedNotesProjectID) { _ in
            syncAssistantNotesRuntimeContext()
            syncNotesAssistantConversationBinding()
        }
        .onChange(of: assistant.visibleAssistantBackend) { backend in
            Task {
                if backend == .codex {
                    await assistant.refreshCodexPluginCatalogIfNeeded()
                } else {
                    assistant.clearComposerPlugins()
                }
            }
        }
        .onChange(of: selectedNotesProject?.id) { _ in
            syncAssistantNotesRuntimeContext()
            syncNotesAssistantConversationBinding()
        }
        .onChange(of: selectedNotesScope) { _ in
            syncAssistantNotesRuntimeContext()
        }
        .onChange(of: isNotesAssistantPanelOpen) { _ in
            syncAssistantNotesRuntimeContext()
            syncNotesAssistantConversationBinding()
        }
        .onChange(of: currentDisplayedNoteTarget) { _ in
            syncAssistantNotesRuntimeContext()
        }
        .onChange(of: currentDisplayedNoteTitle) { _ in
            syncAssistantNotesRuntimeContext()
        }
        .onChange(of: currentProjectNotesProject?.id) { projectID in
            if projectID == nil, projectNotesSidebarRestoreState != nil {
                threadsDetailMode = .chat
                restoreProjectNotesSidebarStateIfNeeded()
            }
        }
        .onChange(of: selectionTracker.selectionContext) { context in
            guard let context else {
                guard !AssistantSelectionActionHUDManager.shared.retainsPresentationWithoutSelection
                else {
                    return
                }
                AssistantSelectionActionHUDManager.shared.hide()
                return
            }

            presentSelectionActions(for: context)
        }
        .onChange(of: assistant.selectedSessionID) { newSessionID in
            guard newSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                return
            }
            selectionTracker.clearSelection()
            AssistantSelectionActionHUDManager.shared.hide()
            if selectedSidebarPane != .archived && selectedSidebarPane != .notes {
                selectedSidebarPane = .threads
            }
            resetVisibleHistoryWindow()
            suppressNextTimelineAutoScrollAnimation = true
        }
    }

    private func sidebar(layout: ChatLayoutMetrics, width: CGFloat) -> some View {
        AssistantSidebarWebView(
            state: sidebarWebState,
            textScale: sidebarTextScale,
            accentColor: AppVisualTheme.assistantWebAccentTint,
            onCommand: handleSidebarWebCommand
        )
        .background(sidebarTranslucentBackground)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        // Disable implicit frame animations during drag for snappier tracking.
        .animation(nil, value: width)
    }

    private var sidebarTranslucentBackground: some View {
        Color.clear
    }

    @ViewBuilder
    private func detailPane(layout: ChatLayoutMetrics) -> some View {
        switch selectedSidebarPane {
        case .threads:
            if let project = currentProjectNotesProject {
                projectNotesDetail(project: project, layout: layout)
            } else {
                chatDetail(layout: layout)
            }
        case .notes:
            notesWorkspaceDetail(layout: layout)
        case .archived:
            archivedDetail(layout: layout)
        case .automations:
            automationDetail
        case .skills:
            skillsDetail
        case .plugins:
            pluginsDetail
        }
    }

    @ViewBuilder
    private func archivedDetail(layout: ChatLayoutMetrics) -> some View {
        let hasArchivedSelection = assistant.visibleArchivedSidebarSessions.contains { session in
            assistant.selectedSessionID?.caseInsensitiveCompare(session.id) == .orderedSame
        }

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Archived Settings")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.88))

                Text(
                    "New archives will use this cleanup time automatically. Change it here only when you want a different default."
                )
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.50))
                .fixedSize(horizontal: false, vertical: true)

                Picker(
                    "Default cleanup time",
                    selection: Binding(
                        get: { settings.assistantArchiveDefaultRetentionHours },
                        set: { settings.assistantArchiveDefaultRetentionHours = $0 }
                    )
                ) {
                    ForEach(archiveRetentionOptions, id: \.self) { hours in
                        Text(archiveRetentionLabel(for: hours)).tag(hours)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.7)
                    )
            )
            .padding(.horizontal, layout.outerPadding)
            .padding(.top, 8)
            .padding(.bottom, 10)

            if assistant.visibleArchivedSidebarSessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.34))
                    Text("No archived chats")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.72))
                    Text(
                        "Archived chats will appear here. You can unarchive them or delete them forever from the right-click menu."
                    )
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.44))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasArchivedSelection {
                chatDetail(layout: layout)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.34))
                    Text("Select an archived chat")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.72))
                    Text("Choose a chat from the Archived list to view it.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.44))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func sidebarNavItem(symbol: String, label: String) -> some View {
        HStack(spacing: sidebarScaled(8)) {
            Image(systemName: symbol)
                .font(.system(size: sidebarScaled(11), weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.44))
                .frame(width: sidebarScaled(16))
            Text(label)
                .font(.system(size: sidebarScaled(13), weight: .regular))
                .foregroundStyle(AppVisualTheme.foreground(0.60))
            Spacer()
        }
        .padding(.horizontal, sidebarScaled(10))
        .padding(.vertical, sidebarScaled(6))
    }

    private func sidebarNavButton(
        symbol: String,
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: sidebarScaled(8)) {
                Image(systemName: symbol)
                    .font(.system(size: sidebarScaled(11), weight: .medium))
                    .foregroundStyle(
                        isSelected ? AppVisualTheme.accentTint : AppVisualTheme.foreground(0.44)
                    )
                    .frame(width: sidebarScaled(16))
                Text(label)
                    .font(.system(size: sidebarScaled(13), weight: .regular))
                    .foregroundStyle(
                        isSelected
                            ? AppVisualTheme.foreground(0.88) : AppVisualTheme.foreground(0.60))
                Spacer()
            }
            .padding(.horizontal, sidebarScaled(10))
            .padding(.vertical, sidebarScaled(6))
            .background(
                RoundedRectangle(cornerRadius: sidebarScaled(8), style: .continuous)
                    .fill(isSelected ? AppVisualTheme.foreground(0.06) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: sidebarScaled(8), style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func projectContextMenu(for project: AssistantProject) -> some View {
        if project.isProject {
            Button {
                openProjectNotes(for: project)
            } label: {
                Label("Project Notes", systemImage: "note.text")
            }

            Button {
                assistant.inspectMemory(for: project)
            } label: {
                Label("View Memory", systemImage: "brain")
            }

            if let selectedSession = activeSessionSummary,
                selectedSession.projectID?.caseInsensitiveCompare(project.id) != .orderedSame
            {
                Divider()

                Button {
                    assistant.assignSessionToProject(selectedSession.id, projectID: project.id)
                } label: {
                    Label(
                        "Move \"\(selectedSession.title)\" Here", systemImage: "arrow.down.circle")
                }
            }

            Divider()
        }

        Button {
            presentRenameProjectPrompt(for: project)
        } label: {
            Label(project.isFolder ? "Rename Group" : "Rename Project", systemImage: "pencil")
        }

        Menu {
            Button {
                assistant.updateProjectIcon(project.id, symbol: nil)
            } label: {
                Label("Use Default Icon", systemImage: "arrow.counterclockwise")
            }
            .disabled(project.iconSymbolName == nil)

            Divider()

            ForEach(Self.projectIconOptions) { option in
                Button {
                    assistant.updateProjectIcon(project.id, symbol: option.symbol)
                } label: {
                    Label(option.title, systemImage: option.symbol)
                }
            }

            Divider()

            Button {
                presentProjectIconPrompt(for: project)
            } label: {
                Label("Custom Symbol...", systemImage: "pencil")
            }
        } label: {
            Label("Change Icon", systemImage: project.displayIconSymbolName)
        }

        if project.isProject {
            Button {
                presentProjectFolderPicker(for: project)
            } label: {
                Label(
                    project.linkedFolderPath == nil ? "Link Folder" : "Change Folder",
                    systemImage: "folder")
            }

            Button {
                presentMoveProjectPrompt(for: project)
            } label: {
                Label("Move to Group", systemImage: "square.grid.2x2")
            }

            if project.linkedFolderPath != nil {
                Button {
                    assistant.updateProjectLinkedFolder(project.id, path: nil)
                } label: {
                    Label("Remove Folder Link", systemImage: "folder.badge.minus")
                }
            }
        } else {
            Button {
                presentNamedProjectPrompt(parentFolder: project)
            } label: {
                Label("Create Project Inside Group", systemImage: "plus")
            }
        }

        Divider()

        Button {
            Task { await assistant.hideProject(project.id) }
        } label: {
            Label(project.isFolder ? "Hide Group" : "Hide Project", systemImage: "eye.slash")
        }

        Button(role: .destructive) {
            pendingDeleteProject = project
        } label: {
            Label(project.isFolder ? "Delete Group" : "Delete Project", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func threadContextMenu(for session: AssistantSessionSummary) -> some View {
        if session.isArchived {
            Button {
                Task {
                    await assistant.unarchiveSession(session.id)
                    guard selectedSidebarPane == .archived else { return }
                    await MainActor.run {
                        showArchivedSidebar()
                    }
                }
            } label: {
                Label("Unarchive Session", systemImage: "tray.and.arrow.up")
            }

            Divider()

            Button(role: .destructive) {
                pendingPermanentDeleteSession = session
            } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        } else {
            Button {
                presentRenameSessionPrompt(for: session)
            } label: {
                Label("Rename Session", systemImage: "pencil")
            }

            if session.isTemporary {
                Button {
                    assistant.promoteTemporarySession(session.id)
                } label: {
                    Label("Keep as Regular Chat", systemImage: "pin")
                }
            }

            Divider()

            if !assistant.visibleLeafProjects.isEmpty {
                Menu {
                    ForEach(assistant.visibleLeafProjects) { project in
                        let isCurrentProject =
                            session.projectID?.caseInsensitiveCompare(project.id) == .orderedSame
                        Button {
                            assistant.assignSessionToProject(session.id, projectID: project.id)
                        } label: {
                            Label(
                                sidebarProjectMenuTitle(for: project),
                                systemImage: project.displayIconSymbolName)
                        }
                        .disabled(isCurrentProject)
                    }
                } label: {
                    Label(
                        session.projectID == nil ? "Add to Project" : "Move to Project",
                        systemImage: "folder.badge.plus"
                    )
                }

            } else {
                Button {
                    presentCreateProjectPrompt(parentFolder: assistant.selectedFolder)
                } label: {
                    Label("Create Project", systemImage: "plus")
                }
            }

            if session.projectID != nil {
                Button {
                    assistant.assignSessionToProject(session.id, projectID: nil)
                } label: {
                    Label("Remove from Project", systemImage: "minus.circle")
                }
            }

            Divider()

            Button {
                Task {
                    await assistant.archiveSession(
                        session.id,
                        retentionHours: settings.assistantArchiveDefaultRetentionHours,
                        updateDefaultRetention: false
                    )
                }
            } label: {
                Label("Archive Session", systemImage: "archivebox")
            }
        }
    }

    private func chatDetail(layout: ChatLayoutMetrics) -> some View {
        let isTransitioningChat = assistant.isTransitioningSession
        let webMessages = isTransitioningChat ? [] : chatWebMessages
        let webRuntimePanel = isTransitioningChat ? nil : chatWebRuntimePanel
        let webReviewPanel = isTransitioningChat ? nil : inlineTrackedCodePanel
        let webRewindState = isTransitioningChat ? nil : chatWebRewindState
        let webActiveWorkState = isTransitioningChat ? nil : chatWebActiveWorkState
        let webActiveTurnState = isTransitioningChat ? nil : chatWebActiveTurnState
        let webCanLoadOlderHistory = !isTransitioningChat && canLoadOlderHistory
        let showsTransitionPlaceholder = isTransitioningChat && webMessages.isEmpty

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                chatTopBar(layout: layout)
                    .zIndex(showProviderPicker || showWorkspaceLaunchMenu ? 20 : 1)

                ZStack {
                    VStack(spacing: 0) {
                        ZStack(alignment: .top) {
                            AssistantChatWebView(
                                messages: webMessages,
                                runtimePanel: webRuntimePanel,
                                reviewPanel: webReviewPanel,
                                rewindState: webRewindState,
                                threadNoteState: chatWebThreadNoteState,
                                activeWorkState: webActiveWorkState,
                                activeTurnState: webActiveTurnState,
                                showTypingIndicator: !isTransitioningChat
                                    && shouldShowPendingAssistantPlaceholder,
                                typingTitle: isTransitioningChat ? "" : typingIndicatorTitle,
                                typingDetail: isTransitioningChat ? "" : typingIndicatorDetail,
                                textScale: CGFloat(chatTextScale),
                                canLoadOlderHistory: webCanLoadOlderHistory,
                                accentColor: AppVisualTheme.assistantWebAccentTint,
                                onScrollStateChanged: { isPinned, isScrolledUp in
                                    autoScrollPinnedToBottom = isPinned
                                    userHasScrolledUp = isScrolledUp
                                },
                                onLoadOlderHistory: {
                                    guard webCanLoadOlderHistory, !isLoadingOlderHistory else {
                                        return
                                    }
                                    loadOlderHistoryBatchWeb()
                                },
                                onLoadActivityDetails: { renderItemID in
                                    if renderItemID.hasPrefix("collapsed-conversation-") {
                                        expandedHistoricalConversationBlockIDs.insert(renderItemID)
                                    } else {
                                        expandedHistoricalActivityRenderItemIDs.insert(renderItemID)
                                    }
                                },
                                onCollapseActivityDetails: { renderItemID in
                                    if renderItemID.hasPrefix("collapsed-conversation-") {
                                        expandedHistoricalConversationBlockIDs.remove(renderItemID)
                                    } else {
                                        expandedHistoricalActivityRenderItemIDs.remove(renderItemID)
                                    }
                                },
                                onSelectRuntimeBackend: { backendID in
                                    guard let backend = AssistantRuntimeBackend(rawValue: backendID)
                                    else { return }
                                    assistant.selectAssistantBackend(backend)
                                },
                                onOpenRuntimeSettings: {
                                    NotificationCenter.default.post(
                                        name: .openAssistOpenSettings,
                                        object: SettingsRoute(section: .assistant, subsection: .assistantSetup))
                                },
                                onUndoMessage: { anchorID in
                                    Task { await assistant.undoUserMessage(anchorID: anchorID) }
                                },
                                onEditMessage: { anchorID in
                                    Task {
                                        await assistant.beginEditLastUserMessage(anchorID: anchorID)
                                    }
                                },
                                onUndoCodeCheckpoint: {
                                    Task { await assistant.undoTrackedCodeCheckpoint() }
                                },
                                onRedoHistoryMutation: {
                                    Task { await assistant.redoUndoneUserMessage() }
                                },
                                onRestoreCodeCheckpoint: { checkpointID in
                                    Task {
                                        await assistant.restoreTrackedCodeCheckpoint(
                                            checkpointID: checkpointID)
                                    }
                                },
                                onCloseCodeReviewPanel: {
                                    // Inline tracked coding does not need a separate native close action.
                                },
                                onThreadNoteCommand: { command, sourceContainer in
                                    handleThreadNoteCommand(
                                        command, sourceContainer: sourceContainer)
                                },
                                noteAssetResolver: resolveWebNoteAssetURL,
                                onTextSelected: { selectedText, messageID, parentText, screenRect in
                                    handleWebViewTextSelection(
                                        selectedText: selectedText,
                                        messageID: messageID,
                                        parentText: parentText,
                                        screenRect: screenRect
                                    )
                                },
                                onContainerReady: { container in
                                    if chatTimelineWebContainer !== container {
                                        chatTimelineWebContainer = container
                                    }
                                    if threadNoteWebContainer !== container {
                                        threadNoteWebContainer = container
                                    }
                                }
                            )

                            if showsTransitionPlaceholder {
                                sessionTransitionPlaceholder
                                    .background(
                                        Color(red: 0.051, green: 0.067, blue: 0.090)
                                            .opacity(0.96)
                                    )
                            }

                            if isTransitioningChat {
                                VStack(spacing: 0) {
                                    sessionTransitionOverlay
                                        .padding(.top, 16)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .onAppear {
                            resetVisibleHistoryWindow()
                            syncThreadNoteSelection(
                                assistant.selectedSessionID, persistCurrent: false)
                            dismissComposerQuickActionsMenu(animated: false)
                        }
                        .onChange(of: assistant.selectedSessionID) { newSessionID in
                            syncThreadNoteSelection(newSessionID, persistCurrent: true)
                            dismissComposerQuickActionsMenu(animated: false)
                            guard
                                newSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty == false
                            else {
                                return
                            }
                            resetVisibleHistoryWindow()
                        }
                        .onChange(of: assistant.selectedCodeTrackingState) { _ in
                            chatTimelineWebContainer?.applyReviewPanel(inlineTrackedCodePanel)
                            // Auto-scroll so the checkpoint card is visible
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                chatTimelineWebContainer?.scrollToBottom(animated: true)
                            }
                        }
                        .onChange(of: assistant.hasActiveTurn) { _ in
                            chatTimelineWebContainer?.applyReviewPanel(inlineTrackedCodePanel)
                        }

                        chatBottomDock(layout: layout, composerState: composerWebState)
                    }

                    if showProviderPicker || showWorkspaceLaunchMenu {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissTopBarDropdowns()
                            }
                    }
                }
                .zIndex(0)
            }
        }  // end ZStack
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .ignoresSafeArea(edges: .top)
    }

    private func projectNotesDetail(
        project: AssistantProject,
        layout: ChatLayoutMetrics
    ) -> some View {
        VStack(spacing: 0) {
            projectNotesFocusHeader(project: project, layout: layout)
                .zIndex(1)

            AssistantChatWebView(
                messages: [],
                runtimePanel: nil,
                reviewPanel: nil,
                rewindState: nil,
                threadNoteState: chatWebThreadNoteState,
                activeWorkState: nil,
                activeTurnState: nil,
                showTypingIndicator: false,
                typingTitle: "",
                typingDetail: "",
                textScale: CGFloat(chatTextScale),
                canLoadOlderHistory: false,
                accentColor: AppVisualTheme.assistantWebAccentTint,
                onScrollStateChanged: { isPinned, isScrolledUp in
                    autoScrollPinnedToBottom = isPinned
                    userHasScrolledUp = isScrolledUp
                },
                onLoadOlderHistory: {},
                onLoadActivityDetails: { renderItemID in
                    if renderItemID.hasPrefix("collapsed-conversation-") {
                        expandedHistoricalConversationBlockIDs.insert(renderItemID)
                    } else {
                        expandedHistoricalActivityRenderItemIDs.insert(renderItemID)
                    }
                },
                onCollapseActivityDetails: { renderItemID in
                    if renderItemID.hasPrefix("collapsed-conversation-") {
                        expandedHistoricalConversationBlockIDs.remove(renderItemID)
                    } else {
                        expandedHistoricalActivityRenderItemIDs.remove(renderItemID)
                    }
                },
                onSelectRuntimeBackend: { backendID in
                    guard let backend = AssistantRuntimeBackend(rawValue: backendID) else { return }
                    assistant.selectAssistantBackend(backend)
                },
                onOpenRuntimeSettings: {
                    NotificationCenter.default.post(
                        name: .openAssistOpenSettings, object: SettingsRoute(section: .assistant, subsection: .assistantSetup))
                },
                onUndoMessage: { anchorID in
                    Task { await assistant.undoUserMessage(anchorID: anchorID) }
                },
                onEditMessage: { anchorID in
                    Task { await assistant.beginEditLastUserMessage(anchorID: anchorID) }
                },
                onUndoCodeCheckpoint: {
                    Task { await assistant.undoTrackedCodeCheckpoint() }
                },
                onRedoHistoryMutation: {
                    Task { await assistant.redoUndoneUserMessage() }
                },
                onRestoreCodeCheckpoint: { checkpointID in
                    Task {
                        await assistant.restoreTrackedCodeCheckpoint(checkpointID: checkpointID)
                    }
                },
                onCloseCodeReviewPanel: {},
                onThreadNoteCommand: { command, sourceContainer in
                    handleThreadNoteCommand(command, sourceContainer: sourceContainer)
                },
                noteAssetResolver: resolveWebNoteAssetURL,
                onTextSelected: { selectedText, messageID, parentText, screenRect in
                    handleWebViewTextSelection(
                        selectedText: selectedText,
                        messageID: messageID,
                        parentText: parentText,
                        screenRect: screenRect
                    )
                },
                onContainerReady: { container in
                    if threadNoteWebContainer !== container {
                        threadNoteWebContainer = container
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .onAppear {
            prepareProjectNotesWorkspace(for: project)
        }
        .onChange(of: project.id) { _ in
            prepareProjectNotesWorkspace(for: project)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .ignoresSafeArea(edges: .top)
    }

    private func notesWorkspaceDetail(layout: ChatLayoutMetrics) -> some View {
        let usesDockedRail = notesAssistantUsesDockedRail(for: layout)

        return VStack(spacing: 0) {
            notesTopBar(layout: layout)
                .zIndex(showWorkspaceLaunchMenu ? 20 : 1)

            if usesDockedRail {
                HStack(spacing: 18) {
                    notesWorkspaceEditorCanvas()

                    notesAssistantDockedRail(layout: layout)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 16)
            } else {
                ZStack {
                    notesWorkspaceEditorCanvas()
                    notesAssistantOverlayLayer(layout: layout)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .ignoresSafeArea(edges: .top)
    }

    private func notesWorkspaceEditorCanvas() -> some View {
        ZStack {
            AssistantChatWebView(
                messages: [],
                runtimePanel: nil,
                reviewPanel: nil,
                rewindState: nil,
                threadNoteState: chatWebThreadNoteState,
                activeWorkState: nil,
                activeTurnState: nil,
                showTypingIndicator: false,
                typingTitle: "",
                typingDetail: "",
                textScale: CGFloat(chatTextScale),
                canLoadOlderHistory: false,
                accentColor: AppVisualTheme.assistantWebAccentTint,
                onScrollStateChanged: { isPinned, isScrolledUp in
                    autoScrollPinnedToBottom = isPinned
                    userHasScrolledUp = isScrolledUp
                },
                onLoadOlderHistory: {},
                onLoadActivityDetails: { _ in },
                onCollapseActivityDetails: { _ in },
                onSelectRuntimeBackend: { backendID in
                    guard let backend = AssistantRuntimeBackend(rawValue: backendID) else { return }
                    assistant.selectAssistantBackend(backend)
                },
                onOpenRuntimeSettings: {
                    NotificationCenter.default.post(
                        name: .openAssistOpenSettings, object: SettingsRoute(section: .assistant, subsection: .assistantSetup))
                },
                onUndoMessage: { _ in },
                onEditMessage: { _ in },
                onUndoCodeCheckpoint: {},
                onRedoHistoryMutation: {},
                onRestoreCodeCheckpoint: { _ in },
                onCloseCodeReviewPanel: {},
                onThreadNoteCommand: { command, sourceContainer in
                    handleThreadNoteCommand(command, sourceContainer: sourceContainer)
                },
                noteAssetResolver: resolveWebNoteAssetURL,
                onTextSelected: { selectedText, messageID, parentText, screenRect in
                    handleWebViewTextSelection(
                        selectedText: selectedText,
                        messageID: messageID,
                        parentText: parentText,
                        screenRect: screenRect
                    )
                },
                onContainerReady: { container in
                    if threadNoteWebContainer !== container {
                        threadNoteWebContainer = container
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()

            if showWorkspaceLaunchMenu {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissTopBarDropdowns()
                    }
            }
        }
    }

    @ViewBuilder
    private func notesAssistantDockedRail(layout: ChatLayoutMetrics) -> some View {
        if isNotesAssistantPanelOpen {
            notesAssistantOverlayCard(layout: layout, docked: true)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if !showWorkspaceLaunchMenu && !showProviderPicker {
            VStack {
                Spacer(minLength: 0)
                notesAssistantOverlayHandle
                Spacer(minLength: 0)
            }
            .frame(minWidth: 30, idealWidth: 30, maxWidth: 30)
            .frame(maxHeight: .infinity, alignment: .center)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func notesAssistantOverlayLayer(layout: ChatLayoutMetrics) -> some View {
        if isNotesAssistantPanelOpen {
            notesAssistantOverlayCard(layout: layout)
                .padding(.trailing, layout.isNarrow ? 12 : 16)
                .padding(.bottom, layout.isNarrow ? 12 : 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if !showWorkspaceLaunchMenu && !showProviderPicker {
            notesAssistantOverlayHandle
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private func notesAssistantOverlayCard(
        layout: ChatLayoutMetrics,
        docked: Bool = false
    ) -> some View {
        let overlayWidth =
            docked
            ? notesAssistantDockedRailWidth(for: layout)
            : notesAssistantOverlayWidth(for: layout)
        let overlayHeight = docked ? nil : notesAssistantOverlayHeight(for: layout)
        let usesCondensedLayout =
            docked ? false : notesAssistantOverlayUsesCondensedLayout(for: layout)
        let panelCornerRadius: CGFloat = docked ? 26 : 22

        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: usesCondensedLayout ? 5 : 7) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(AppVisualTheme.accentTint.opacity(0.92))
                            .frame(width: 6, height: 6)

                        Text("NOTES ASSISTANT")
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(0.9)
                            .foregroundStyle(AppVisualTheme.foreground(0.48))
                    }

                    Text(notesAssistantScopeLabel)
                        .font(.system(size: usesCondensedLayout ? 12.5 : 13.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.92))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    notesAssistantSessionSwitcherMenu

                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            isNotesAssistantPanelExpanded.toggle()
                        }
                    } label: {
                        notesAssistantOverlayIconButton(
                            symbol: isNotesAssistantPanelExpanded
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right"
                        )
                    }
                    .buttonStyle(.plain)
                    .help(
                        isNotesAssistantPanelExpanded
                            ? "Restore compact notes assistant"
                            : "Maximize notes assistant"
                    )

                    notesAssistantOverlayMenu

                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            isNotesAssistantPanelOpen = false
                        }
                        syncAssistantNotesRuntimeContext()
                    } label: {
                        notesAssistantOverlayIconButton(symbol: "sidebar.right", emphasized: true)
                    }
                    .buttonStyle(.plain)
                    .help("Collapse notes assistant")
                }
                .padding(3)
                .background(
                    Capsule(style: .continuous)
                        .fill(AppVisualTheme.surfaceFill(0.05))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.7)
                        )
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, usesCondensedLayout ? 11 : 13)
            .padding(.bottom, usesCondensedLayout ? 9 : 11)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            AppVisualTheme.surfaceFill(0.0),
                            AppVisualTheme.surfaceFill(0.12),
                            AppVisualTheme.surfaceFill(0.0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)

            ZStack {
                RoundedRectangle(cornerRadius: docked ? 20 : 18, style: .continuous)
                    .fill(Color(red: 0.045, green: 0.055, blue: 0.075))
                    .overlay(
                        RoundedRectangle(cornerRadius: docked ? 20 : 18, style: .continuous)
                            .stroke(Color.white.opacity(0.05), lineWidth: 0.7)
                    )

                Group {
                    if notesAssistantHasVisibleConversationContent {
                        AssistantChatWebView(
                            messages: notesAssistantChatMessages,
                            runtimePanel: nil,
                            reviewPanel: nil,
                            rewindState: nil,
                            threadNoteState: nil,
                            activeWorkState: notesAssistantActiveWorkState,
                            activeTurnState: notesAssistantActiveTurnState,
                            showTypingIndicator: notesAssistantShouldShowPendingPlaceholder,
                            typingTitle: notesAssistantTypingIndicatorTitle,
                            typingDetail: notesAssistantTypingIndicatorDetail,
                            textScale: CGFloat(chatTextScale),
                            canLoadOlderHistory: notesAssistantCanLoadOlderHistory,
                            accentColor: AppVisualTheme.assistantWebAccentTint,
                            onScrollStateChanged: { isPinned, isScrolledUp in
                                autoScrollPinnedToBottom = isPinned
                                userHasScrolledUp = isScrolledUp
                            },
                            onLoadOlderHistory: {
                                guard notesAssistantCanLoadOlderHistory, !isLoadingOlderHistory
                                else {
                                    return
                                }
                                loadOlderHistoryBatchWeb()
                            },
                            onLoadActivityDetails: { renderItemID in
                                if renderItemID.hasPrefix("collapsed-conversation-") {
                                    expandedHistoricalConversationBlockIDs.insert(renderItemID)
                                } else {
                                    expandedHistoricalActivityRenderItemIDs.insert(renderItemID)
                                }
                            },
                            onCollapseActivityDetails: { renderItemID in
                                if renderItemID.hasPrefix("collapsed-conversation-") {
                                    expandedHistoricalConversationBlockIDs.remove(renderItemID)
                                } else {
                                    expandedHistoricalActivityRenderItemIDs.remove(renderItemID)
                                }
                            },
                            onSelectRuntimeBackend: { backendID in
                                guard let backend = AssistantRuntimeBackend(rawValue: backendID)
                                else {
                                    return
                                }
                                assistant.selectAssistantBackend(backend)
                            },
                            onOpenRuntimeSettings: {
                                NotificationCenter.default.post(
                                    name: .openAssistOpenSettings,
                                    object: SettingsRoute(section: .assistant, subsection: .assistantSetup)
                                )
                            },
                            onUndoMessage: { anchorID in
                                Task { await assistant.undoUserMessage(anchorID: anchorID) }
                            },
                            onEditMessage: { anchorID in
                                Task {
                                    await assistant.beginEditLastUserMessage(anchorID: anchorID)
                                }
                            },
                            onUndoCodeCheckpoint: {
                                Task { await assistant.undoTrackedCodeCheckpoint() }
                            },
                            onRedoHistoryMutation: {
                                Task { await assistant.redoUndoneUserMessage() }
                            },
                            onRestoreCodeCheckpoint: { checkpointID in
                                Task {
                                    await assistant.restoreTrackedCodeCheckpoint(
                                        checkpointID: checkpointID
                                    )
                                }
                            },
                            onCloseCodeReviewPanel: {},
                            onThreadNoteCommand: { command, sourceContainer in
                                handleThreadNoteCommand(command, sourceContainer: sourceContainer)
                            },
                            noteAssetResolver: resolveWebNoteAssetURL,
                            onTextSelected: { selectedText, messageID, parentText, screenRect in
                                handleWebViewTextSelection(
                                    selectedText: selectedText,
                                    messageID: messageID,
                                    parentText: parentText,
                                    screenRect: screenRect
                                )
                            },
                            onContainerReady: { container in
                                if chatTimelineWebContainer !== container {
                                    chatTimelineWebContainer = container
                                }
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                    } else {
                        notesAssistantOverlayEmptyState
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(0)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)

            chatBottomDock(
                layout: layout,
                composerState: notesAssistantComposerWebState,
                maxWidth: overlayWidth - 28,
                showsStatusBar: false,
                isCompact: true
            )
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .frame(width: overlayWidth, height: overlayHeight, alignment: .top)
        .frame(maxHeight: docked ? .infinity : nil, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.084, green: 0.097, blue: 0.125),
                            Color(red: 0.067, green: 0.079, blue: 0.103),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.035),
                            Color.clear,
                            AppVisualTheme.accentTint.opacity(0.03),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.11),
                            AppVisualTheme.surfaceStroke(0.10),
                            Color.black.opacity(0.05),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
        )
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.04), lineWidth: 0.7)
                .blur(radius: 0.4)
                .padding(1)
        }
        .shadow(color: Color.black.opacity(0.24), radius: docked ? 18 : 22, x: 0, y: docked ? 6 : 9)
    }

    private var notesAssistantOverlayEmptyState: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("START HERE")
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(AppVisualTheme.foreground(0.40))

                    Text("Ask about this note")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.92))

                    Text("Search the project or focus on the open note.")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.54))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    notesAssistantQuickPromptButton(
                        title: "What is already covered here?",
                        prompt: currentDisplayedNoteTitle.map {
                            "What is already covered in the note '\($0)'?"
                        } ?? "What is already covered in these project notes?"
                    )

                    Rectangle()
                        .fill(AppVisualTheme.surfaceFill(0.06))
                        .frame(height: 0.5)

                    notesAssistantQuickPromptButton(
                        title: "Summarize the open note",
                        prompt: currentDisplayedNoteTitle.map {
                            "Summarize the note '\($0)' and call out the key decisions."
                        } ?? "Summarize the key decisions in these project notes."
                    )

                    Rectangle()
                        .fill(AppVisualTheme.surfaceFill(0.06))
                        .frame(height: 0.5)

                    notesAssistantQuickPromptButton(
                        title: "Find the best note to update",
                        prompt: "Which note should I update for this work, and why?"
                    )
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppVisualTheme.surfaceFill(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AppVisualTheme.surfaceStroke(0.07), lineWidth: 0.7)
                        )
                )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var notesAssistantOverlayHandle: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                isNotesAssistantPanelOpen = true
            }
            syncAssistantNotesRuntimeContext()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(notesAssistantOverlayHandleTint.opacity(0.94))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open notes assistant")
    }

    private var notesAssistantOverlayHandleTint: Color {
        let accent = NSColor(AppVisualTheme.accentTint).usingColorSpace(.sRGB)
            ?? NSColor(AppVisualTheme.accentTint)
        let mixed = accent.blended(withFraction: 0.24, of: .white) ?? accent
        return Color(nsColor: mixed)
    }

    private func notesAssistantOverlayIconButton(
        symbol: String,
        emphasized: Bool = false
    ) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(
                emphasized ? AppVisualTheme.accentTint : AppVisualTheme.foreground(0.60)
            )
            .frame(width: 27, height: 27)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(emphasized ? 0.10 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                emphasized
                                    ? AppVisualTheme.accentTint.opacity(0.20)
                                    : AppVisualTheme.surfaceStroke(0.08),
                                lineWidth: 0.7
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var notesAssistantOverlayMenu: some View {
        Menu {
            Section("View") {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        isNotesAssistantPanelExpanded.toggle()
                    }
                } label: {
                    Label(
                        isNotesAssistantPanelExpanded
                            ? "Restore Compact Size"
                            : "Maximize Assistant",
                        systemImage: isNotesAssistantPanelExpanded
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                }
            }

            Section("Interaction Mode") {
                ForEach(AssistantInteractionMode.allCases, id: \.rawValue) { mode in
                    Button {
                        assistant.interactionMode = mode
                    } label: {
                        notesAssistantMenuRowLabel(
                            title: mode.label,
                            isSelected: assistant.interactionMode.normalizedForActiveUse == mode
                        )
                    }
                }
            }

            Section("Backend") {
                ForEach(AssistantRuntimeBackend.allCases, id: \.rawValue) { backend in
                    Button {
                        assistant.selectAssistantBackend(backend)
                    } label: {
                        notesAssistantMenuRowLabel(
                            title: backend.shortDisplayName,
                            isSelected: assistant.visibleAssistantBackend == backend
                        )
                    }
                }
            }

            Section("Model") {
                if assistant.visibleModels.isEmpty {
                    Text("No models available")
                } else {
                    ForEach(assistant.visibleModels, id: \.id) { model in
                        Button {
                            assistant.chooseModel(model.id)
                        } label: {
                            notesAssistantMenuRowLabel(
                                title: model.displayName,
                                isSelected: assistant.selectedModelID == model.id
                            )
                        }
                    }
                }
            }

            Section("Reasoning") {
                ForEach(supportedEfforts, id: \.rawValue) { effort in
                    Button {
                        assistant.reasoningEffort = effort
                    } label: {
                        notesAssistantMenuRowLabel(
                            title: effort.label,
                            isSelected: assistant.reasoningEffort == effort
                        )
                    }
                }
            }

            Divider()

            Button {
                NotificationCenter.default.post(
                    name: .openAssistOpenSettings,
                    object: SettingsRoute(section: .modelsConnections, subsection: .modelsConnections)
                )
            } label: {
                Label("Open Assistant Setup", systemImage: "gearshape")
            }
        } label: {
            notesAssistantOverlayIconButton(symbol: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Notes assistant options")
    }

    @ViewBuilder
    private var notesAssistantSessionSwitcherMenu: some View {
        if let project = selectedNotesProject {
            let sessionSummaries = notesAssistantSessionSummaries(for: project)
            let archivedSessionSummaries = archivedNotesAssistantSessionSummaries(for: project)
            let currentLabel = notesAssistantSessionSwitcherLabel(
                for: currentNotesAssistantSessionSummary,
                project: project
            )

            Menu {
                if sessionSummaries.isEmpty && archivedSessionSummaries.isEmpty {
                    Text("No saved chats yet")
                }

                if !sessionSummaries.isEmpty {
                    Section("Saved notes chats") {
                        ForEach(sessionSummaries) { session in
                            Button {
                                Task { @MainActor in
                                    await activateNotesAssistantSession(
                                        for: project,
                                        preferredSessionID: session.id
                                    )
                                }
                            } label: {
                                notesAssistantMenuRowLabel(
                                    title: notesAssistantSessionDisplayTitle(
                                        for: session,
                                        project: project
                                    ),
                                    isSelected: assistantTimelineSessionIDsMatch(
                                        currentNotesAssistantSessionSummary?.id,
                                        session.id
                                    )
                                )
                            }
                        }
                    }
                }

                if !archivedSessionSummaries.isEmpty {
                    Section("Archived notes chats") {
                        ForEach(archivedSessionSummaries) { session in
                            Button {
                                Task { @MainActor in
                                    await activateNotesAssistantSession(
                                        for: project,
                                        preferredSessionID: session.id
                                    )
                                }
                            } label: {
                                notesAssistantMenuRowLabel(
                                    title: notesAssistantSessionDisplayTitle(
                                        for: session,
                                        project: project
                                    ),
                                    isSelected: assistantTimelineSessionIDsMatch(
                                        currentNotesAssistantSessionSummary?.id,
                                        session.id
                                    )
                                )
                            }
                        }
                    }
                }

                Divider()

                Button {
                    Task { @MainActor in
                        _ = await createNotesAssistantSession(for: project)
                    }
                } label: {
                    Label("New Chat", systemImage: "plus")
                }

                if let currentSession = currentNotesAssistantSessionSummary {
                    Divider()

                    Menu("Current Chat") {
                        Button {
                            presentRenameSessionPrompt(for: currentSession)
                        } label: {
                            Label("Rename Chat", systemImage: "pencil")
                        }

                        if currentSession.isArchived {
                            Button {
                                Task { @MainActor in
                                    await unarchiveNotesAssistantSession(
                                        currentSession, in: project)
                                }
                            } label: {
                                Label("Unarchive Chat", systemImage: "tray.and.arrow.up")
                            }
                        } else {
                            Button {
                                Task { @MainActor in
                                    await archiveNotesAssistantSession(currentSession, in: project)
                                }
                            } label: {
                                Label("Archive Chat", systemImage: "archivebox")
                            }
                        }

                        Divider()

                        Button(role: .destructive) {
                            pendingDeleteNotesAssistantSession = currentSession
                        } label: {
                            Label("Delete Chat", systemImage: "trash")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.74))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.42))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(AppVisualTheme.surfaceFill(0.05))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.7)
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Switch saved notes chats")
        }
    }

    private func notesAssistantMenuRowLabel(
        title: String,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func notesAssistantQuickPromptButton(
        title: String,
        prompt: String
    ) -> some View {
        Button {
            assistant.promptDraft = prompt
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.84))

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.34))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func notesAssistantOverlayUsesCondensedLayout(
        for layout: ChatLayoutMetrics
    ) -> Bool {
        layout.detailWidth < 760 || layout.windowHeight < 720
    }

    private func notesAssistantUsesDockedRail(for layout: ChatLayoutMetrics) -> Bool {
        !layout.isNarrow && layout.detailWidth >= 1100 && layout.windowHeight >= 720
    }

    private func notesAssistantDockedRailWidth(for layout: ChatLayoutMetrics) -> CGFloat {
        let minimumWidth: CGFloat = isNotesAssistantPanelExpanded ? 360 : 282
        let maximumWidth: CGFloat = min(
            isNotesAssistantPanelExpanded ? 560 : 332,
            layout.detailWidth * (isNotesAssistantPanelExpanded ? 0.46 : 0.34)
        )
        let preferredWidth =
            isNotesAssistantPanelExpanded
            ? layout.detailWidth * 0.40
            : layout.detailWidth * 0.24
        return min(max(preferredWidth, minimumWidth), maximumWidth)
    }

    private func notesAssistantOverlayWidth(for layout: ChatLayoutMetrics) -> CGFloat {
        if notesAssistantOverlayUsesCondensedLayout(for: layout) {
            let minimumWidth: CGFloat = isNotesAssistantPanelExpanded ? 300 : 220
            let maximumWidth: CGFloat = min(
                isNotesAssistantPanelExpanded ? layout.detailWidth - 20 : 286,
                layout.detailWidth - 18
            )
            let preferredWidth =
                isNotesAssistantPanelExpanded
                ? layout.detailWidth * 0.78
                : layout.detailWidth * 0.36
            return min(max(preferredWidth, minimumWidth), maximumWidth)
        }

        let minimumWidth: CGFloat = isNotesAssistantPanelExpanded ? 420 : 248
        let maximumWidth: CGFloat = min(
            isNotesAssistantPanelExpanded ? 640 : 292,
            layout.detailWidth - 28
        )
        let preferredWidth =
            isNotesAssistantPanelExpanded
            ? layout.detailWidth * 0.52
            : layout.detailWidth * 0.22
        return min(max(preferredWidth, minimumWidth), maximumWidth)
    }

    private func notesAssistantOverlayHeight(for layout: ChatLayoutMetrics) -> CGFloat {
        let availableHeight = max(220, layout.windowHeight - 168)

        if notesAssistantOverlayUsesCondensedLayout(for: layout) {
            let minimumHeight: CGFloat = isNotesAssistantPanelExpanded ? 316 : 272
            let maximumHeight: CGFloat = min(
                isNotesAssistantPanelExpanded ? availableHeight : 332,
                availableHeight
            )
            let preferredHeight: CGFloat = min(
                isNotesAssistantPanelExpanded ? availableHeight * 0.88 : 304,
                availableHeight
            )
            return min(max(preferredHeight, minimumHeight), maximumHeight)
        }

        let minimumHeight: CGFloat = isNotesAssistantPanelExpanded ? 404 : 298
        let maximumHeight: CGFloat = min(
            isNotesAssistantPanelExpanded ? availableHeight : 352, availableHeight)
        let preferredHeight: CGFloat = isNotesAssistantPanelExpanded ? availableHeight * 0.86 : 316
        return min(max(preferredHeight, minimumHeight), maximumHeight)
    }

    private func notesTopBarTitleCluster(layout: ChatLayoutMetrics) -> some View {
        HStack(spacing: 10) {
            Text("Notes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.88))

            if let project = selectedNotesProject {
                HStack(spacing: 6) {
                    Image(systemName: project.displayIconSymbolName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.accentTint)
                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.72))
                        .lineLimit(1)
                }
                .help(project.linkedFolderPath ?? project.name)

                Text(selectedNotesScope == .project ? "Project notes" : "Thread notes")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.42))
                    .lineLimit(1)
            } else {
                Text("Choose a project from the sidebar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.48))
                    .lineLimit(1)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: layout.topBarMaxWidth, alignment: .center)
    }

    private func notesTopBar(layout: ChatLayoutMetrics) -> some View {
        let sideControlWidth: CGFloat = isCompactSidebarPresentation ? 164 : 176
        let titleHorizontalPadding: CGFloat = isCompactSidebarPresentation ? 10 : 16
        let notesAssistantTriggerSymbol = "bubble.left.and.text.bubble.right"

        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                workspaceLaunchControl
            }
            .frame(width: sideControlWidth, alignment: .leading)

            Spacer(minLength: 0)

            notesTopBarTitleCluster(layout: layout)
                .padding(.horizontal, titleHorizontalPadding)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        isNotesAssistantPanelOpen.toggle()
                    }
                    syncAssistantNotesRuntimeContext()
                } label: {
                    topBarIconButton(
                        symbol: isNotesAssistantPanelOpen
                            ? "sidebar.right" : notesAssistantTriggerSymbol,
                        emphasized: isNotesAssistantPanelOpen,
                        tint: .orange
                    )
                }
                .buttonStyle(.plain)
                .help(
                    isNotesAssistantPanelOpen
                        ? "Collapse notes assistant"
                        : "Open notes assistant"
                )

                if presentationStyle == .compactSidebar {
                    Button {
                        settings.assistantCompactSidebarPinned.toggle()
                    } label: {
                        topBarIconButton(
                            symbol: settings.assistantCompactSidebarPinned ? "pin.fill" : "pin",
                            emphasized: settings.assistantCompactSidebarPinned
                        )
                    }
                    .buttonStyle(.plain)
                    .help(
                        settings.assistantCompactSidebarPinned
                            ? "Unpin sidebar so it can auto-hide again"
                            : "Pin sidebar so it stays open"
                    )

                    Button {
                        NotificationCenter.default.post(name: .openAssistOpenAssistant, object: nil)
                    } label: {
                        topBarIconButton(symbol: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .help("Open the full assistant window")
                } else {
                    Button {
                        minimizeToCompact()
                    } label: {
                        topBarIconButton(symbol: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .help("Back to compact assistant")
                }
            }
            .frame(width: sideControlWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, titleHorizontalPadding)
        .padding(.vertical, 5)
        .overlay(
            Rectangle()
                .fill(AppVisualTheme.surfaceFill(0.06))
                .frame(height: 0.5),
            alignment: .bottom
        )
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: toggleKeyWindowFullScreen)
        }
    }

    private func projectNotesFocusHeader(
        project: AssistantProject,
        layout: ChatLayoutMetrics
    ) -> some View {
        let outerHorizontalPadding: CGFloat = layout.isNarrow ? 14 : 18
        let headerContentMaxWidth = min(
            1180, max(320, layout.windowWidth - (outerHorizontalPadding * 2)))
        let centeredInset = max((layout.windowWidth - headerContentMaxWidth) / 2, 0)
        let backButtonLeadingInset = max(0, layout.leadingReserve - centeredInset)

        return centeredDetailColumn(maxWidth: headerContentMaxWidth, alignment: .leading) {
            HStack(spacing: layout.isNarrow ? 12 : 16) {
                Button {
                    closeProjectNotesIfNeeded()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(AppVisualTheme.foreground(0.78))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppVisualTheme.surfaceFill(0.05))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.7)
                            )
                    )
                }
                .buttonStyle(.plain)
                .help("Return to the normal chat view.")

                HStack(spacing: 10) {
                    Image(systemName: project.displayIconSymbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.accentTint)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(AppVisualTheme.accentTint.opacity(0.10))
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(shortHeaderTitle(project.name, maxWords: 6))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.foreground(0.92))
                            .lineLimit(1)

                        Text("Project notes")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.46))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(currentWorkspaceURL?.path ?? project.name)

                Button {
                    openCurrentWorkspace(in: primaryWorkspaceLaunchTarget)
                } label: {
                    HStack(spacing: 7) {
                        Image(
                            systemName: currentWorkspaceURL == nil
                                ? "folder.badge.questionmark" : "folder"
                        )
                        .font(.system(size: 11.5, weight: .semibold))
                        if !layout.isNarrow {
                            Text("Open Folder")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .foregroundStyle(
                        AppVisualTheme.foreground(currentWorkspaceURL == nil ? 0.40 : 0.76)
                    )
                    .padding(.horizontal, layout.isNarrow ? 11 : 13)
                    .frame(height: 34)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppVisualTheme.surfaceFill(0.04))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.7)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(currentWorkspaceURL == nil)
                .help(
                    currentWorkspaceURL == nil
                        ? "This project does not have a linked folder yet."
                        : "Open this project folder in \(primaryWorkspaceLaunchTarget.title)."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, backButtonLeadingInset)
        }
        .padding(.horizontal, outerHorizontalPadding)
        .padding(.vertical, layout.isNarrow ? 10 : 12)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.060, green: 0.078, blue: 0.106),
                    Color(red: 0.049, green: 0.064, blue: 0.088),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            Rectangle()
                .fill(AppVisualTheme.surfaceStroke(0.08))
                .frame(height: 0.6),
            alignment: .bottom
        )
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: toggleKeyWindowFullScreen)
        }
    }

    private var automationDetail: some View {
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.46, green: 0.79, blue: 0.66).opacity(0.14))
                        .frame(width: 34, height: 34)
                    Image(systemName: "clock.badge.checkmark.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(red: 0.46, green: 0.79, blue: 0.66))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Automations")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.92))
                    Text("Create and manage recurring assistant jobs")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.44))
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                AppVisualTheme.surfaceFill(0.03)
            )
            .overlay(
                Rectangle()
                    .fill(AppVisualTheme.surfaceStroke(0.08))
                    .frame(height: 0.5),
                alignment: .bottom
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: toggleKeyWindowFullScreen)

            ScheduledJobsView(showsHeader: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    AssistantWindowChrome.contentTop,
                    AssistantWindowChrome.contentBottom,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppVisualTheme.surfaceStroke(0.05), lineWidth: 0.5)
        )
        .padding(.top, 10)
        .padding(.leading, 4)
        .ignoresSafeArea(edges: .top)
    }

    private var skillsDetail: some View {
        return VStack(spacing: 0) {
            AssistantSkillsPane(
                assistant: assistant,
                onBack: navigateBackFromSkillsPane,
                onImportFolder: openSkillFolderImportPanel,
                onImportGitHub: { showGitHubSkillImportSheet = true },
                onCreateSkill: { showSkillWizardSheet = true },
                onDeleteSkill: confirmDeleteSkill,
                onTrySkill: trySkillFromLibrary
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    AssistantWindowChrome.contentTop,
                    AssistantWindowChrome.contentBottom,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppVisualTheme.surfaceStroke(0.05), lineWidth: 0.5)
        )
        .padding(.top, 10)
        .padding(.leading, 4)
        .ignoresSafeArea(edges: .top)
    }

    private var pluginsDetail: some View {
        VStack(spacing: 0) {
            AssistantPluginsPane(
                assistant: assistant,
                onBack: navigateBackFromPluginsPane
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    AssistantWindowChrome.contentTop,
                    AssistantWindowChrome.contentBottom,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppVisualTheme.surfaceStroke(0.05), lineWidth: 0.5)
        )
        .padding(.top, 10)
        .padding(.leading, 4)
        .ignoresSafeArea(edges: .top)
    }

    private var hasToolActivity: Bool {
        selectedSessionToolActivity.hasActivity
    }

    private var selectedSessionActiveWorkSnapshot: AssistantSessionActiveWorkSnapshot? {
        assistantSelectedSessionActiveWorkSnapshot(
            selectedSessionID: assistant.selectedSessionID,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID,
            planEntries: assistant.planEntries,
            subagents: assistant.subagents,
            toolCalls: assistant.toolCalls,
            recentToolCalls: assistant.recentToolCalls
        )
    }

    private var hasSelectedSessionActiveWork: Bool {
        selectedSessionActiveWorkSnapshot != nil
    }

    private var chatWebActiveWorkState: AssistantChatWebActiveWorkState? {
        guard
            let selectedSessionID = assistant.selectedSessionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        else {
            return nil
        }

        let snapshot = selectedSessionActivitySnapshot
        let ownsLiveRuntime = assistantSessionOwnsLiveRuntimeState(
            sessionID: selectedSessionID,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID
        )
        guard snapshot.pendingPermissionRequest == nil else {
            return nil
        }

        let activeWorkSnapshot = selectedSessionActiveWorkSnapshot
        let activeCalls = selectedSessionToolActivity.activeCalls
            .map(AssistantChatWebActiveWorkItem.init(toolCall:))
        let recentCalls = Array(
            selectedSessionToolActivity.recentCalls
                .prefix(activeCalls.isEmpty ? 3 : 2)
                .map(AssistantChatWebActiveWorkItem.init(toolCall:))
        )
        let subagents = Array(
            (activeWorkSnapshot?.subagents ?? [])
                .filter { $0.status.isActive }
                .prefix(3)
                .map(AssistantChatWebActiveWorkSubagent.init(subagent:))
        )
        let hasStructuredActivity =
            !activeCalls.isEmpty || !recentCalls.isEmpty || !subagents.isEmpty
        guard hasStructuredActivity else {
            return nil
        }

        let shouldShowStructuredActivity =
            ownsLiveRuntime
            || snapshot.hasActiveTurn
            || snapshot.awaitingAssistantStart
            || selectedSessionToolActivity.hasActivity
            || activeWorkSnapshot != nil
        guard shouldShowStructuredActivity else {
            return nil
        }

        let effectiveHUD = snapshot.hudState ?? assistant.hudState
        let hasPhantomPermissionState =
            effectiveHUD.phase == .waitingForPermission
            && snapshot.pendingPermissionRequest == nil
        let fallbackActivity = activeCalls.first ?? recentCalls.first
        let title =
            (hasPhantomPermissionState
                ? fallbackActivity?.title
                : effectiveHUD.title
            )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "Working"
        let detail =
            (hasPhantomPermissionState
                ? fallbackActivity?.detail
                : effectiveHUD.detail
            )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        return AssistantChatWebActiveWorkState(
            title: title,
            detail: detail,
            activeCalls: activeCalls,
            recentCalls: recentCalls,
            subagents: subagents
        )
    }

    private var chatWebActiveTurnState: AssistantChatWebActiveTurnState? {
        guard
            let selectedSessionID = assistant.selectedSessionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        else {
            return nil
        }

        let snapshot = selectedSessionActivitySnapshot
        let hasPendingInput = snapshot.pendingPermissionRequest?.toolKind == "userInput"
        let hasPendingToolApproval = snapshot.pendingPermissionRequest != nil && !hasPendingInput
        let ownsLiveRuntime = assistantSessionOwnsLiveRuntimeState(
            sessionID: selectedSessionID,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID
        )
        let isActive =
            snapshot.hasActiveTurn
            || snapshot.awaitingAssistantStart
            || hasPendingToolApproval
            || hasPendingInput

        guard ownsLiveRuntime || isActive else {
            return nil
        }

        let hudPhase = snapshot.hudState?.phase ?? assistant.hudState.phase
        let hasPhantomPermissionState =
            hudPhase == .waitingForPermission
            && !hasPendingInput
            && !hasPendingToolApproval
        let phase: String
        if hasPendingInput || hasPendingToolApproval {
            phase = "needsInput"
        } else {
            switch hudPhase {
            case .thinking:
                phase = "thinking"
            case .streaming:
                phase = "streaming"
            case .acting, .listening:
                phase = "acting"
            case .waitingForPermission:
                phase = hasPhantomPermissionState ? "acting" : "needsInput"
            case .idle, .success, .failed:
                phase = isActive ? "acting" : "idle"
            }
        }

        return AssistantChatWebActiveTurnState(
            phase: phase,
            canCancel: isActive,
            providerLabel: assistant.visibleAssistantBackend.shortDisplayName,
            hasPendingToolApproval: hasPendingToolApproval,
            hasPendingInput: hasPendingInput
        )
    }

    private var selectedChildParentLinkState: AssistantParentThreadLinkState? {
        assistantParentThreadLinkState(
            selectedSessionID: assistant.selectedSessionID,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID,
            subagents: assistant.subagents
        )
    }

    private var latestFileChangeMessageID: String? {
        chatWebMessages.reversed().first { message in
            if message.activityIcon == "fileChange" {
                return true
            }
            return message.groupItems?.contains(where: { $0.icon == "fileChange" }) == true
        }?.id
    }

    private var inlineTrackedCodePanel: AssistantChatWebCodeReviewPanel? {
        assistant.selectedCodeTrackingState.flatMap {
            AssistantChatWebCodeReviewPanel(
                trackingState: $0,
                hasActiveTurn: assistant.hasActiveTurn,
                actionsLocked: assistant.isRestoringHistoryBranch,
                embedded: true
            )
        }
    }

    private var selectedSessionToolActivity: AssistantSessionToolActivitySnapshot {
        assistantSelectedSessionToolActivity(
            selectedSessionID: assistant.selectedSessionID,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID,
            hasActiveTurn: assistant.hasActiveTurn,
            toolCalls: assistant.toolCalls,
            recentToolCalls: assistant.recentToolCalls
        )
    }

    private func chatBottomDock(
        layout: ChatLayoutMetrics,
        composerState: AssistantComposerWebState,
        maxWidth: CGFloat? = nil,
        showsStatusBar: Bool = true,
        isCompact: Bool = false
    ) -> some View {
        let resolvedMaxWidth = maxWidth ?? layout.composerMaxWidth
        return VStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                if let request = assistant.pendingPermissionRequest {
                    HStack(alignment: .top, spacing: 0) {
                        permissionCard(
                            request,
                            state: request.toolKind == "userInput"
                                ? .waitingForInput
                                : .waitingForApproval
                        )
                        Spacer(minLength: layout.leadingReserve)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                } else if let workSnapshot = selectedSessionActiveWorkSnapshot {
                    AssistantParentWorkCard(
                        snapshot: workSnapshot,
                        onOpenThread: openThread,
                        onReviewChanges: latestFileChangeMessageID == nil
                            ? nil : revealLatestFileChangeActivity
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }

                if let composerPendingPermissionHelperText {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.message")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.accentTint)
                        Text(composerPendingPermissionHelperText)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.56))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }

                chatComposer(layout: layout, state: composerState)
            }
            .frame(maxWidth: resolvedMaxWidth, alignment: .leading)
            .overlay(alignment: .bottomLeading) {
                if isComposerQuickActionsMenuPresented && !composerState.base.isCompactComposer {
                    composerQuickActionsMenu(state: composerState)
                        .padding(.leading, 18)
                        .padding(.bottom, 60)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            )
                        )
                }
            }

            if showsStatusBar {
                // Integrated status bar
                HStack(spacing: 6) {
                    if !assistant.rateLimits.isEmpty {
                        statusBarRateLimits
                    }

                    Spacer(minLength: 4)

                    if assistant.accountSnapshot.isLoggedIn {
                        AccountBadgeCircle(snapshot: assistant.accountSnapshot)
                    }

                    ContextUsageCircle(usage: assistant.tokenUsage)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: resolvedMaxWidth)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: hasToolActivity)
        .animation(.easeInOut(duration: 0.25), value: hasSelectedSessionActiveWork)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, isCompact ? 0 : layout.timelineHorizontalPadding)
        .padding(.top, isCompact ? 0 : 4)
        .padding(.bottom, isCompact ? 0 : 4)
        .zIndex(isComposerQuickActionsMenuPresented ? 60 : 0)
    }

    private func chatTopBarTitleCluster(layout: ChatLayoutMetrics) -> some View {
        HStack(spacing: 10) {
            Text(activeSessionHeaderTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.88))
                .lineLimit(1)
                .help(activeSessionTitle)

            if activeSessionSummary?.isTemporary == true {
                AssistantStatusBadge(
                    title: "Temporary",
                    tint: .orange,
                    symbol: "clock.badge.exclamationmark"
                )
            }

            if let project = activeSessionProject {
                AssistantStatusBadge(
                    title: project.name,
                    tint: AppVisualTheme.accentTint,
                    symbol: project.displayIconSymbolName
                )
                .help(activeSessionWorkspaceURL?.path ?? project.name)
            } else if activeSessionSummary?.projectID == nil,
                let projectName = activeSessionSummary?.projectName?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).nonEmpty
            {
                AssistantStatusBadge(
                    title: projectName,
                    tint: AppVisualTheme.accentTint,
                    symbol: "folder"
                )
                .help(activeSessionWorkspaceURL?.path ?? projectName)
            }

            if activeSessionSummary?.projectFolderMissing == true {
                AssistantStatusBadge(
                    title: "Missing folder",
                    tint: .orange,
                    symbol: "exclamationmark.triangle.fill"
                )
            }
        }
        .lineLimit(1)
        .frame(maxWidth: layout.topBarMaxWidth, alignment: .center)
    }

    private func chatTopBar(layout: ChatLayoutMetrics) -> some View {
        let sideControlWidth: CGFloat = isCompactSidebarPresentation ? 158 : 176
        let titleHorizontalPadding: CGFloat = isCompactSidebarPresentation ? 10 : 16
        let hasThreadNote = !currentThreadNoteManifest.notes.isEmpty

        return HStack(spacing: 0) {
            // Provider picker on the left
            if assistant.selectedSessionID != nil {
                topBarProviderDropdown
                    .padding(.leading, 4)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if let selectedChildParentLinkState {
                    Button {
                        openThread(selectedChildParentLinkState.parentThreadID)
                    } label: {
                        AssistantTopBarActionButton(
                            title: "Parent thread",
                            symbol: "bubble.left.and.bubble.right",
                            tint: AppVisualTheme.foreground(0.86)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Open the parent thread for this sub-agent")
                }

                if activeSessionSummary?.isTemporary == true {
                    Button {
                        assistant.promoteTemporarySession()
                    } label: {
                        topBarTextActionButton(title: "Keep Chat", tint: AppVisualTheme.accentTint)
                    }
                    .buttonStyle(.plain)
                    .help("Keep this temporary chat as a regular thread")
                }

                workspaceLaunchControl
                topBarSeparator()

                if isCompactSidebarPresentation {
                    compactSidebarOverflowMenu(hasThreadNote: hasThreadNote)
                } else {
                    if assistant.selectedSessionID != nil {
                        Button {
                            toggleThreadNoteDrawer()
                        } label: {
                            topBarIconButton(
                                symbol: "note.text",
                                emphasized: isThreadNoteOpen || hasThreadNote
                            )
                        }
                        .buttonStyle(.plain)
                        .help(isThreadNoteOpen ? "Close thread note" : "Open thread note")
                    }

                    Button {
                        showSessionInstructions.toggle()
                    } label: {
                        topBarIconButton(symbol: "text.quote")
                    }
                    .buttonStyle(.plain)
                    .help("Session instructions")
                    .popover(isPresented: $showSessionInstructions, arrowEdge: .bottom) {
                        SessionInstructionsPopover(instructions: $assistant.sessionInstructions)
                    }
                }

                // Memory indicator — icon color alone shows on/off
                if !isCompactSidebarPresentation {
                    Button {
                        assistant.inspectCurrentMemory()
                    } label: {
                        Image(systemName: "brain")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(
                                sessionMemoryIsActive
                                    ? Color.green.opacity(0.85) : AppVisualTheme.foreground(0.28)
                            )
                            .padding(5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(AppVisualTheme.surfaceFill(0.04))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Open memory for this chat")
                }

                if presentationStyle == .compactSidebar {
                    Button {
                        settings.assistantCompactSidebarPinned.toggle()
                    } label: {
                        topBarIconButton(
                            symbol: settings.assistantCompactSidebarPinned ? "pin.fill" : "pin",
                            emphasized: settings.assistantCompactSidebarPinned
                        )
                    }
                    .buttonStyle(.plain)
                    .help(
                        settings.assistantCompactSidebarPinned
                            ? "Unpin sidebar so it can auto-hide again"
                            : "Pin sidebar so it stays open"
                    )

                    Button {
                        NotificationCenter.default.post(name: .openAssistOpenAssistant, object: nil)
                    } label: {
                        topBarIconButton(symbol: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .help("Open the full assistant window")
                } else if assistant.selectedSessionID != nil {
                    Button {
                        minimizeToCompact()
                    } label: {
                        topBarIconButton(symbol: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .help("Back to compact assistant")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .overlay(alignment: .center) {
            chatTopBarTitleCluster(layout: layout)
                .padding(.horizontal, titleHorizontalPadding)
                .padding(.horizontal, sideControlWidth)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, titleHorizontalPadding)
        .padding(.vertical, 5)
        .overlay(
            Rectangle()
                .fill(AppVisualTheme.surfaceFill(0.06))
                .frame(height: 0.5),
            alignment: .bottom
        )
        .background {
            // Double-tap the title bar background to toggle full-screen.
            // Using a background overlay keeps it behind the dropdown overlays
            // so it does not steal hits from dropdown items.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: toggleKeyWindowFullScreen)
        }
    }

    private var workspaceLaunchControl: some View {
        let isPrimaryHighlighted = isWorkspaceLaunchPrimaryHovered
        let isChevronHighlighted = isWorkspaceLaunchChevronHovered || showWorkspaceLaunchMenu
        let isContainerHighlighted = isPrimaryHighlighted || isChevronHighlighted

        return HStack(spacing: 0) {
            Button {
                openCurrentWorkspace(in: primaryWorkspaceLaunchTarget)
            } label: {
                workspaceLaunchTargetIcon(primaryWorkspaceLaunchTarget, size: 18)
                    .frame(width: 32, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                isPrimaryHighlighted
                                    ? AppVisualTheme.foreground(0.07)
                                    : .clear
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        isPrimaryHighlighted
                                            ? AppVisualTheme.surfaceStroke(0.10)
                                            : .clear,
                                        lineWidth: 0.6
                                    )
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isWorkspaceLaunchPrimaryHovered = hovering
            }
            .disabled(currentWorkspaceURL == nil || !primaryWorkspaceLaunchTarget.isInstalled)
            .help(
                currentWorkspaceURL == nil
                    ? "This \(currentWorkspaceSubjectLabel) does not have a usable folder yet."
                    : "Open this \(currentWorkspaceSubjectLabel) folder in \(primaryWorkspaceLaunchTarget.title)."
            )

            Rectangle()
                .fill(AppVisualTheme.surfaceStroke(isContainerHighlighted ? 0.16 : 0.12))
                .frame(width: 0.6, height: 16)
                .padding(.vertical, 4)

            Button {
                toggleWorkspaceLaunchMenu()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(
                        AppVisualTheme.foreground(isChevronHighlighted ? 0.78 : 0.46)
                    )
                    .frame(width: 26, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                isChevronHighlighted
                                    ? AppVisualTheme.foreground(0.07)
                                    : .clear
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        isChevronHighlighted
                                            ? AppVisualTheme.surfaceStroke(0.10)
                                            : .clear,
                                        lineWidth: 0.6
                                    )
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isWorkspaceLaunchChevronHovered = hovering
            }
            .help("Choose your default editor.")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeInOut(duration: 0.14), value: isPrimaryHighlighted)
        .animation(.easeInOut(duration: 0.14), value: isChevronHighlighted)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    isContainerHighlighted
                        ? AssistantWindowChrome.buttonEmphasis.opacity(0.72)
                        : AssistantWindowChrome.buttonFill.opacity(0.86)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isContainerHighlighted
                                ? AssistantWindowChrome.strongBorder.opacity(0.88)
                                : AssistantWindowChrome.border.opacity(0.66),
                            lineWidth: 0.7
                        )
                )
                .shadow(
                    color: Color.black.opacity(isContainerHighlighted ? 0.20 : 0.14),
                    radius: isContainerHighlighted ? 10 : 8,
                    x: 0,
                    y: 5
                )
        )
        .overlay(alignment: .topTrailing) {
            if showWorkspaceLaunchMenu {
                workspaceLaunchDropdownOverlay
                    .offset(y: 34)
                    .zIndex(40)
            }
        }
    }

    private var workspaceLaunchDropdownOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            if currentWorkspaceURL == nil {
                Text(
                    "Choose a default editor now. Open a project with a folder link to launch it there."
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.45))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider().padding(.horizontal, 6)
            }

            ForEach(Self.workspaceLaunchTargets) { target in
                let isActive = target.id == primaryWorkspaceLaunchTarget.id
                let isEnabled = canUseWorkspaceLaunchTarget(target)
                let isHovered = hoveredWorkspaceLaunchTargetID == target.id
                let isHighlighted = isActive || isHovered

                Button {
                    selectWorkspaceLaunchTarget(target)
                } label: {
                    HStack(spacing: 8) {
                        workspaceLaunchTargetIcon(target, size: 16)

                        Text(target.title)
                            .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                            .foregroundStyle(
                                AppVisualTheme.foreground(
                                    isEnabled ? (isHighlighted ? 0.95 : 0.86) : 0.34
                                )
                            )

                        Spacer(minLength: 0)

                        if isActive {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AppVisualTheme.foreground(0.5))
                        }

                        if !target.isInstalled {
                            Text("N/A")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(AppVisualTheme.foreground(0.28))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                isActive
                                    ? AppVisualTheme.accentTint.opacity(0.12)
                                    : (isHovered ? AppVisualTheme.foreground(0.07) : .clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(
                                        isHovered && !isActive
                                            ? AppVisualTheme.surfaceStroke(0.10)
                                            : .clear,
                                        lineWidth: 0.6
                                    )
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .onHover { hovering in
                    hoveredWorkspaceLaunchTargetID =
                        hovering
                        ? target.id
                        : (hoveredWorkspaceLaunchTargetID == target.id
                            ? nil : hoveredWorkspaceLaunchTargetID)
                }
            }
        }
        .padding(6)
        .frame(width: 210)
        .background(
            topBarDropdownPanelBackground(cornerRadius: 10)
        )
        .compositingGroup()
    }

    @ViewBuilder
    private func workspaceLaunchTargetIcon(
        _ target: AssistantWorkspaceLaunchTarget,
        size: CGFloat
    ) -> some View {
        if let applicationURL = target.applicationURL {
            let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.24), style: .continuous))
        } else {
            Image(systemName: target.fallbackSymbol)
                .font(.system(size: max(10, size * 0.72), weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.62))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: max(4, size * 0.24), style: .continuous)
                        .fill(AppVisualTheme.surfaceFill(0.05))
                )
        }
    }

    private func topBarSeparator(height: CGFloat = 22) -> some View {
        Rectangle()
            .fill(AppVisualTheme.surfaceStroke(0.18))
            .frame(width: 0.8, height: height)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }

    private func openCurrentWorkspace(in target: AssistantWorkspaceLaunchTarget) {
        guard let workspaceURL = currentWorkspaceURL else {
            assistant.lastStatusMessage =
                "This \(currentWorkspaceSubjectLabel) does not have a usable folder yet."
            return
        }

        switch target.launchStyle {
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
            assistant.lastStatusMessage = "Opened this folder in Finder."

        case .openDocuments:
            guard let applicationURL = target.applicationURL else {
                assistant.lastStatusMessage = "\(target.title) is not installed on this Mac."
                return
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.promptsUserIfNeeded = false

            // When the user is viewing a note, also pass the note's markdown
            // file so the editor opens the folder as the workspace AND a loose
            // tab for the note. Folder must come first so the editor uses it
            // as the workspace root.
            let noteURL = currentNoteMarkdownFileURL
            var urlsToOpen: [URL] = [workspaceURL]
            if let noteURL {
                urlsToOpen.append(noteURL)
            }

            NSWorkspace.shared.open(
                urlsToOpen,
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { _, error in
                Task { @MainActor in
                    if let error {
                        CrashReporter.logError(
                            "Workspace launch failed target=\(target.title) path=\(workspaceURL.path) error=\(error.localizedDescription)"
                        )
                        assistant.lastStatusMessage =
                            "Could not open this folder in \(target.title)."
                    } else if noteURL != nil {
                        assistant.lastStatusMessage =
                            "Opened this folder and note in \(target.title)."
                    } else {
                        assistant.lastStatusMessage = "Opened this folder in \(target.title)."
                    }
                }
            }
        }
    }

    private func canUseWorkspaceLaunchTarget(_ target: AssistantWorkspaceLaunchTarget) -> Bool {
        guard target.isInstalled else { return false }
        return currentWorkspaceURL != nil || target.remembersAsPreferred
    }

    private func selectWorkspaceLaunchTarget(_ target: AssistantWorkspaceLaunchTarget) {
        guard canUseWorkspaceLaunchTarget(target) else { return }

        if target.remembersAsPreferred {
            preferredWorkspaceLaunchTargetID = target.id
        }

        if currentWorkspaceURL != nil {
            openCurrentWorkspace(in: target)
        } else if target.remembersAsPreferred {
            assistant.lastStatusMessage =
                "Default editor set to \(target.title). Open a project with a linked folder to launch it there."
        }

        dismissTopBarDropdowns()
    }

    private func topBarIconButton(symbol: String, emphasized: Bool = false, tint: Color? = nil) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(
                emphasized ? AppVisualTheme.accentTint : (tint ?? AppVisualTheme.foreground(0.52))
            )
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AssistantWindowChrome.buttonFill.opacity(emphasized ? 0.98 : 0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(
                                emphasized
                                    ? AppVisualTheme.accentTint.opacity(0.22)
                                    : AssistantWindowChrome.border.opacity(0.62),
                                lineWidth: 0.6
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func compactSidebarOverflowMenu(hasThreadNote: Bool) -> some View {
        Menu {
            if assistant.selectedSessionID != nil {
                Button {
                    toggleThreadNoteDrawer()
                } label: {
                    Label(
                        isThreadNoteOpen ? "Close Thread Note" : "Open Thread Note",
                        systemImage: "note.text"
                    )
                }
            }

            Button {
                showSessionInstructions = true
            } label: {
                Label("Session Instructions", systemImage: "text.quote")
            }
        } label: {
            topBarIconButton(
                symbol: "ellipsis",
                emphasized: isThreadNoteOpen || hasThreadNote || showSessionInstructions
            )
        }
        .menuStyle(.borderlessButton)
        .help("More chat tools")
        .popover(isPresented: $showSessionInstructions, arrowEdge: .bottom) {
            SessionInstructionsPopover(instructions: $assistant.sessionInstructions)
        }
    }

    private func toggleKeyWindowFullScreen() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.zoom(nil)
    }

    private var chatStatusBar: some View {
        HStack(spacing: 10) {
            AssistantModePicker(selection: assistant.interactionMode) { mode in
                assistant.interactionMode = mode
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(runtimeDotColor)
                    .frame(width: 5, height: 5)
                Text(runtimeStatusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.45))
            }

            if !assistant.rateLimits.isEmpty {
                statusBarRateLimits
            }

            Spacer()

            if assistant.accountSnapshot.isLoggedIn {
                Text(assistant.accountSnapshot.summary)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(AppVisualTheme.foreground(0.34))
                    .lineLimit(1)
            }

            ContextUsageCircle(usage: assistant.tokenUsage)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBarRateLimits: some View {
        if let bucket = assistant.selectedRateLimitBucket {
            let bucketLabel = assistant.selectedRateLimitBucketLabel
            let entries = bucket.statusBarEntries(bucketLabel: bucketLabel)
            HStack(spacing: 10) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    statusBarRateLimitInline(
                        window: entry.window,
                        bucketLabel: bucketLabel,
                        showsResetInline: entry.showsResetInline
                    )
                }
            }
        }
    }

    private func statusBarRateLimitInline(
        window: RateLimitWindow,
        bucketLabel: String?,
        showsResetInline: Bool = false
    )
        -> some View
    {
        let isHigh = window.usedPercent > 80
        let percentColor: Color =
            isHigh ? .red.opacity(0.85) : AppVisualTheme.accentTint.opacity(0.75)
        let compactBucketLabel = bucketLabel?
            .replacingOccurrences(of: "Claude ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let baseLabel = window.windowLabel.isEmpty ? "Usage" : window.windowLabel
        let label = [compactBucketLabel, baseLabel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            .joined(separator: " ")
        let resetLabel = showsResetInline ? window.compactResetsInLabel : nil

        return HStack(spacing: 4) {
            Image(systemName: "gauge.low")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.30))
            Text(label.isEmpty ? baseLabel : label)
                .font(.system(size: 9.5, weight: .regular))
                .foregroundStyle(AppVisualTheme.foreground(0.36))
            Text("\(window.usedPercent)%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(percentColor)
            if let resetLabel {
                Text("resets \(resetLabel)")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(AppVisualTheme.foreground(0.32))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(AssistantWindowChrome.buttonFill)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AssistantWindowChrome.border, lineWidth: 0.55)
                )
        )
        .help(window.resetsInLabel.map { "Resets \($0)" } ?? "")
    }

    private var runtimeStatusLabel: String {
        switch assistant.runtimeHealth.availability {
        case .ready, .active: return "Connected"
        case .checking: return "Checking..."
        case .connecting: return "Connecting..."
        case .failed: return "Failed"
        case .installRequired: return "Install Required"
        case .loginRequired: return "Login Required"
        case .idle: return "Idle"
        case .unavailable: return "Unavailable"
        }
    }

    private var runtimeStatusSymbol: String {
        switch assistant.runtimeHealth.availability {
        case .ready, .active:
            return "checkmark.circle.fill"
        case .checking, .connecting:
            return "arrow.triangle.2.circlepath"
        case .installRequired:
            return "arrow.down.circle.fill"
        case .loginRequired:
            return "person.crop.circle.badge.exclamationmark"
        case .failed:
            return "xmark.circle.fill"
        case .idle:
            return "moon.fill"
        case .unavailable:
            return "slash.circle.fill"
        }
    }

    private func historyWindowNotice(action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.message")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AssistantWindowChrome.neutralAccent.opacity(0.92))

            Text("Older chat history is hidden for speed. Use Load more to show older messages.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.72))

            Button(action: action) {
                Text("Load more")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AssistantWindowChrome.buttonEmphasis.opacity(0.68))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(AppVisualTheme.surfaceStroke(0.10), lineWidth: 0.55)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(AssistantWindowChrome.buttonFill)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AssistantWindowChrome.border, lineWidth: 0.6)
                )
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func jumpToLatestButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("Latest")
                    .font(.system(size: 12, weight: .semibold))

                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(AppVisualTheme.foreground(0.95))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(AssistantWindowChrome.elevatedPanel)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(AssistantWindowChrome.border, lineWidth: 0.55)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Jump to the newest message")
    }

    private func presentRenameSessionPrompt(for session: AssistantSessionSummary) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = session.title
        field.placeholderString = "Session name"
        field.selectText(nil)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Rename Session"
        alert.informativeText =
            "Choose a friendly name for this thread. It will stay the same until you rename it again."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let proposedTitle = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await assistant.renameSession(session.id, to: proposedTitle) }
    }

    private func presentCreateProjectPrompt(parentFolder: AssistantProject?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        if let parentFolder {
            alert.messageText = "Add to Group"
            alert.informativeText =
                "Create a new project inside \(parentFolder.name), or add a local folder as one project inside it."
            alert.addButton(withTitle: "New Project")
            alert.addButton(withTitle: "Open Folder")
        } else {
            alert.messageText = "Add Item"
            alert.informativeText =
                "Create a new group, create a project by name, or use the right-click menu on + for more project actions."
            alert.addButton(withTitle: "New Project")
            alert.addButton(withTitle: "New Group")
        }
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            presentNamedProjectPrompt(parentFolder: parentFolder)
        case .alertSecondButtonReturn:
            if let parentFolder {
                presentCreateProjectFromFolderPrompt(parentFolder: parentFolder)
            } else {
                presentCreateFolderPrompt()
            }
        default:
            return
        }
    }

    private func presentCreateFolderPrompt() {
        presentProjectNamePrompt(
            title: "Create Group",
            message: "Give this group a simple name. You will be able to place projects inside it.",
            confirmTitle: "Create",
            initialValue: ""
        ) { proposedName in
            assistant.createFolder(name: proposedName)
        }
    }

    private func presentCreateNoteFolderPrompt(
        for project: AssistantProject,
        parentFolderID: String?
    ) {
        let folderRows = sidebarNoteFolderRows(for: project, scope: .project)
        let parentFolder = folderRows.first(where: {
            $0.id.caseInsensitiveCompare(parentFolderID ?? "") == .orderedSame
        })
        let folderSuffix = parentFolder.map { " inside \($0.path.joined(separator: " / "))" } ?? ""
        let existingFolderIDs = Set(folderRows.map { $0.id.lowercased() })
        presentProjectNamePrompt(
            title: "Create Note Folder",
            message: "Give this note folder a simple name\(folderSuffix).",
            confirmTitle: "Create",
            initialValue: ""
        ) { proposedName in
            guard let workspace = assistant.createProjectNoteFolder(
                projectID: project.id,
                parentFolderID: parentFolderID,
                name: proposedName
            ) else {
                return
            }
            if let newFolder = workspace.manifest.folders.first(where: {
                !existingFolderIDs.contains($0.id.lowercased())
            }) {
                setNoteFolderPathExpanded(
                    folderID: newFolder.id,
                    folders: workspace.manifest.folders
                )
            } else if let parentFolderID {
                setNoteFolderPathExpanded(
                    folderID: parentFolderID,
                    folders: workspace.manifest.folders
                )
            }
            applyThreadNoteWorkspace(workspace)
        }
    }

    private func presentRenameNoteFolderPrompt(
        for project: AssistantProject,
        folderID: String
    ) {
        let folderRows = sidebarNoteFolderRows(for: project, scope: .project)
        guard let folder = folderRows.first(where: {
            $0.id.caseInsensitiveCompare(folderID) == .orderedSame
        }) else {
            return
        }
        presentProjectNamePrompt(
            title: "Rename Note Folder",
            message: "Choose the new name for this note folder. Notes inside it will stay attached.",
            confirmTitle: "Rename",
            initialValue: folder.name
        ) { proposedName in
            guard let workspace = assistant.renameProjectNoteFolder(
                projectID: project.id,
                folderID: folderID,
                name: proposedName
            ) else {
                return
            }
            setNoteFolderPathExpanded(folderID: folderID, folders: workspace.manifest.folders)
            applyThreadNoteWorkspace(workspace)
        }
    }

    private func presentMoveNoteFolderPrompt(
        for project: AssistantProject,
        folderID: String
    ) {
        let folderRows = sidebarNoteFolderRows(for: project, scope: .project)
        guard let folder = folderRows.first(where: {
            $0.id.caseInsensitiveCompare(folderID) == .orderedSame
        }) else {
            return
        }

        let allFolders = assistant.projectNoteFolders(projectID: project.id)
        let descendantIDs = noteFolderDescendantIDs(folderID: folderID, folders: allFolders)
        let availableFolders = folderRows.filter {
            $0.id.caseInsensitiveCompare(folderID) != .orderedSame
                && !descendantIDs.contains($0.id.lowercased())
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Move Note Folder"
        alert.informativeText =
            availableFolders.isEmpty
            ? "There are no other note folders yet. You can still move this folder to the top level."
            : "Choose where to place \(folder.path.joined(separator: " / "))."

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        popup.addItem(withTitle: "Top level")
        availableFolders.forEach { popup.addItem(withTitle: $0.path.joined(separator: " / ")) }
        if let currentParentID = folder.parentFolderID,
            let currentIndex = availableFolders.firstIndex(where: {
                $0.id.caseInsensitiveCompare(currentParentID) == .orderedSame
            })
        {
            popup.selectItem(at: currentIndex + 1)
        } else {
            popup.selectItem(at: 0)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let targetFolderID =
            popup.indexOfSelectedItem <= 0 ? nil : availableFolders[popup.indexOfSelectedItem - 1].id
        guard let workspace = assistant.moveProjectNoteFolder(
            projectID: project.id,
            folderID: folderID,
            parentFolderID: targetFolderID
        ) else {
            return
        }
        setNoteFolderPathExpanded(
            folderID: targetFolderID ?? folderID,
            folders: workspace.manifest.folders
        )
        applyThreadNoteWorkspace(workspace)
    }

    private func presentNamedProjectPrompt(parentFolder: AssistantProject?) {
        let folderSuffix = parentFolder.map { " inside the group \($0.name)" } ?? ""
        presentProjectNamePrompt(
            title: "Create Project",
            message:
                "Give this project a simple name\(folderSuffix). You can add chats to it now and link a local folder later.",
            confirmTitle: "Create",
            initialValue: ""
        ) { proposedName in
            assistant.createProject(name: proposedName, parentID: parentFolder?.id)
        }
    }

    private func presentCreateProjectFromFolderPrompt(parentFolder: AssistantProject?) {
        let panel = NSOpenPanel()
        panel.message =
            parentFolder == nil
            ? "Choose the local folder to add as a project."
            : "Choose the local folder to add as a project inside the group \(parentFolder?.name ?? "this group")."
        panel.prompt = "Open Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK,
            let folderURL = panel.url
        else {
            return
        }

        presentProjectNamePrompt(
            title: "Add Project From Folder",
            message:
                "We used the folder name as the project name. You can keep it or type a different name.",
            confirmTitle: "Add Project",
            initialValue: AssistantProject.suggestedName(forLinkedFolderPath: folderURL.path)
        ) { proposedName in
            assistant.createProject(
                name: proposedName,
                linkedFolderPath: folderURL.path,
                parentID: parentFolder?.id
            )
        }
    }

    private func presentRenameProjectPrompt(for project: AssistantProject) {
        presentProjectNamePrompt(
            title: project.isFolder ? "Rename Group" : "Rename Project",
            message:
                project.isFolder
                ? "Choose the new name for this group. The projects inside it will stay attached."
                : "Choose the new name for this project. Its chats and memory will stay attached.",
            confirmTitle: "Rename",
            initialValue: project.name
        ) { proposedName in
            assistant.renameProject(project.id, to: proposedName)
        }
    }

    private func presentMoveProjectPrompt(for project: AssistantProject) {
        guard project.isProject else { return }
        let folders = visibleRootFolders.filter {
            $0.id.caseInsensitiveCompare(project.parentID ?? "") != .orderedSame
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Move Project to Group"
        alert.informativeText =
            folders.isEmpty
            ? "There are no groups yet. Create a group first, or move this project back to the top level."
            : "Choose where to place \(project.name)."

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        popup.addItem(withTitle: "Top level")
        folders.forEach { popup.addItem(withTitle: $0.name) }
        if let currentParentID = project.parentID,
            let currentIndex = folders.firstIndex(where: {
                $0.id.caseInsensitiveCompare(currentParentID) == .orderedSame
            })
        {
            popup.selectItem(at: currentIndex + 1)
        } else {
            popup.selectItem(at: 0)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let targetFolder =
            popup.indexOfSelectedItem <= 0 ? nil : folders[popup.indexOfSelectedItem - 1]
        assistant.moveProject(project.id, toFolderID: targetFolder?.id)
    }

    private func presentProjectIconPrompt(for project: AssistantProject) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = project.iconSymbolName ?? ""
        field.placeholderString = "folder.fill"
        field.selectText(nil)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Change Project Icon"
        alert.informativeText =
            "Type an SF Symbol name, like folder.fill or star.fill. Leave it blank to use the default icon."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let proposedSymbol = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if proposedSymbol.isEmpty {
            assistant.updateProjectIcon(project.id, symbol: nil)
            return
        }

        guard AssistantProject.isValidIconSymbolName(proposedSymbol) else {
            let errorAlert = NSAlert()
            errorAlert.alertStyle = .warning
            errorAlert.messageText = "Unknown Icon"
            errorAlert.informativeText =
                "That symbol name was not found. Try folder.fill, star.fill, or pick one of the preset icons."
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
            return
        }

        assistant.updateProjectIcon(project.id, symbol: proposedSymbol)
    }

    private func presentProjectFolderPicker(for project: AssistantProject) {
        let panel = NSOpenPanel()
        panel.message = "Choose the local folder for this project."
        panel.prompt = project.linkedFolderPath == nil ? "Link Folder" : "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if let linkedFolderPath = project.linkedFolderPath?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nonEmpty {
            let existingURL = URL(fileURLWithPath: linkedFolderPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: existingURL.path) {
                panel.directoryURL = existingURL
            }
        }

        guard panel.runModal() == .OK else { return }
        assistant.updateProjectLinkedFolder(project.id, path: panel.url?.path)
    }

    private func presentProjectNamePrompt(
        title: String,
        message: String,
        confirmTitle: String,
        initialValue: String,
        onSubmit: @escaping (String) -> Void
    ) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = initialValue
        field.placeholderString = "Project name"
        field.selectText(nil)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let proposedName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposedName.isEmpty else { return }
        onSubmit(proposedName)
    }

    private func copyMessageButton(text: String, helpText: String, isVisible: Bool = true)
        -> some View
    {
        Button {
            copyAssistantTextToPasteboard(text)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(isVisible ? 0.56 : 0.22))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(AppVisualTheme.surfaceFill(isVisible ? 0.045 : 0.001))
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.12), value: isVisible)
    }

    private func resetVisibleHistoryWindow() {
        pendingScrollToLatestWorkItem?.cancel()
        visibleHistoryLimit = Self.initialVisibleHistoryLimit
        userHasScrolledUp = false
        autoScrollPinnedToBottom = true
        isLoadingOlderHistory = false
        isPreservingHistoryScrollPosition = false
        chatScrollTracking.lastManualScrollAt = .distantPast
        expandedActivityIDs.removeAll()
        expandedHistoricalActivityRenderItemIDs.removeAll()
        expandedHistoricalConversationBlockIDs.removeAll()
    }

    private func shouldCollapseHistoricalActivityRenderItem(
        _ renderItem: AssistantTimelineRenderItem,
        at index: Int,
        in renderItems: [AssistantTimelineRenderItem]
    ) -> Bool {
        guard !expandedHistoricalActivityRenderItemIDs.contains(renderItem.id) else {
            return false
        }

        let activities = activityItems(for: renderItem)
        guard !activities.isEmpty else { return false }
        guard activities.allSatisfy({ !$0.status.isActive }) else { return false }

        let laterItems = renderItems.dropFirst(index + 1)
        return laterItems.contains(where: { activityItems(for: $0).isEmpty })
    }

    private func activityItems(for renderItem: AssistantTimelineRenderItem)
        -> [AssistantActivityItem]
    {
        assistantTimelineActivityItems(for: renderItem)
    }

    private struct CollapsedHistoricalConversationGroup {
        let id: String
        let firstHiddenIndex: Int
        let hiddenIndices: [Int]
        let hiddenRenderItems: [AssistantTimelineRenderItem]
        let terminalRenderItem: AssistantTimelineRenderItem
    }

    private func collapsedHistoricalConversationGroups(
        in renderItems: [AssistantTimelineRenderItem]
    ) -> [CollapsedHistoricalConversationGroup] {
        guard !renderItems.isEmpty else { return [] }

        let protectedRecentConversationStartIndex =
            assistantTimelineProtectedRecentConversationStartIndex(
                in: renderItems,
                preservingRecentChatMessages: Self.minimumVisibleChatMessagesBeforeLoadMore
            )
        var groups: [CollapsedHistoricalConversationGroup] = []
        var segmentStart = 0

        func flushSegment(endExclusive: Int) {
            guard segmentStart < endExclusive else { return }

            let indices = Array(segmentStart..<endExclusive)
            guard
                let lastAssistantIndex = indices.last(where: {
                    assistantTimelineIsCollapsibleAssistantResponseRenderItem(renderItems[$0])
                })
            else {
                return
            }

            let hiddenIndices = assistantTimelineCollapsedConversationHiddenIndices(
                in: renderItems,
                segmentIndices: indices,
                protectedRecentConversationStartIndex: protectedRecentConversationStartIndex
            )
            guard !hiddenIndices.isEmpty else { return }

            let hiddenRenderItems = hiddenIndices.map { renderItems[$0] }
            let firstHiddenID = hiddenRenderItems.first?.id ?? UUID().uuidString
            let lastVisibleID = renderItems[lastAssistantIndex].id
            groups.append(
                CollapsedHistoricalConversationGroup(
                    id: "collapsed-conversation-\(firstHiddenID)-\(lastVisibleID)",
                    firstHiddenIndex: hiddenIndices[0],
                    hiddenIndices: hiddenIndices,
                    hiddenRenderItems: hiddenRenderItems,
                    terminalRenderItem: renderItems[lastAssistantIndex]
                )
            )
        }

        for index in renderItems.indices {
            if isUserRenderItem(renderItems[index]) {
                flushSegment(endExclusive: index)
                segmentStart = index + 1
            }
        }

        flushSegment(endExclusive: renderItems.count)
        return groups
    }

    private func isUserRenderItem(_ renderItem: AssistantTimelineRenderItem) -> Bool {
        assistantTimelineIsUserRenderItem(renderItem)
    }

    private func isCollapsibleAssistantResponseRenderItem(
        _ renderItem: AssistantTimelineRenderItem
    ) -> Bool {
        assistantTimelineIsCollapsibleAssistantResponseRenderItem(renderItem)
    }

    private func isHistoricalConversationRenderItem(
        _ renderItem: AssistantTimelineRenderItem
    ) -> Bool {
        assistantTimelineIsHistoricalConversationRenderItem(renderItem)
    }

    private func handleUserScrollInteraction() {
        pendingScrollToLatestWorkItem?.cancel()
        chatScrollTracking.lastManualScrollAt = Date()
        userHasScrolledUp = true
        autoScrollPinnedToBottom = false
        AssistantSelectionActionHUDManager.shared.hide()
    }

    private func updateUserScrollState(bottomOffset: CGFloat) {
        guard !assistant.isTransitioningSession, chatViewportHeight > 0 else { return }

        let distanceFromBottom = max(0, bottomOffset - chatViewportHeight)
        let isPinnedToBottom = distanceFromBottom <= Self.autoScrollThreshold
        let hasScrolledUp = distanceFromBottom > Self.nearBottomThreshold

        if autoScrollPinnedToBottom != isPinnedToBottom {
            autoScrollPinnedToBottom = isPinnedToBottom
        }
        if userHasScrolledUp != hasScrolledUp {
            userHasScrolledUp = hasScrolledUp
        }
    }

    private func loadOlderHistoryIfNeeded(topOffset: CGFloat, with proxy: ScrollViewProxy) {
        let hasRecentManualScrollIntent =
            Date().timeIntervalSince(chatScrollTracking.lastManualScrollAt)
            <= Self.manualLoadOlderPause
        guard !assistant.isTransitioningSession,
            hasRecentManualScrollIntent,
            canLoadOlderHistory,
            topOffset > -Self.loadOlderThreshold,
            !isLoadingOlderHistory
        else {
            return
        }

        loadOlderHistoryBatch(with: proxy)
    }

    private func loadOlderHistoryBatch(with proxy: ScrollViewProxy) {
        guard !assistant.isTransitioningSession,
            !isLoadingOlderHistory,
            let anchorID = visibleRenderItems.first.flatMap(historyPreservationAnchorID(for:))
        else {
            return
        }

        if hiddenRenderItemCount > 0 {
            let nextLimit = assistantTimelineNextVisibleLimit(
                currentLimit: visibleHistoryLimit,
                totalCount: allRenderItems.count,
                batchSize: Self.historyBatchSize
            )
            guard nextLimit > visibleHistoryLimit else { return }

            pendingScrollToLatestWorkItem?.cancel()
            userHasScrolledUp = true
            autoScrollPinnedToBottom = false
            isPreservingHistoryScrollPosition = true
            isLoadingOlderHistory = true
            visibleHistoryLimit = nextLimit
            DispatchQueue.main.async {
                proxy.scrollTo(anchorID, anchor: .top)
                DispatchQueue.main.async {
                    isLoadingOlderHistory = false
                    isPreservingHistoryScrollPosition = false
                }
            }
            return
        }

        guard assistant.selectedSessionCanLoadMoreHistory else { return }

        let previousVisibleLimit = visibleHistoryLimit
        pendingScrollToLatestWorkItem?.cancel()
        userHasScrolledUp = true
        autoScrollPinnedToBottom = false
        isPreservingHistoryScrollPosition = true
        isLoadingOlderHistory = true
        Task { @MainActor in
            let didGrow = await assistant.loadMoreHistoryForSelectedSession()
            if didGrow {
                let nextLimit = assistantTimelineNextVisibleLimit(
                    currentLimit: previousVisibleLimit,
                    totalCount: allRenderItems.count,
                    batchSize: Self.historyBatchSize
                )
                if nextLimit > visibleHistoryLimit {
                    visibleHistoryLimit = nextLimit
                }
            }

            DispatchQueue.main.async {
                proxy.scrollTo(anchorID, anchor: .top)
                DispatchQueue.main.async {
                    isLoadingOlderHistory = false
                    isPreservingHistoryScrollPosition = false
                }
            }
        }
    }

    private func jumpToLatestMessage(with proxy: ScrollViewProxy) {
        userHasScrolledUp = false
        autoScrollPinnedToBottom = true
        isPreservingHistoryScrollPosition = false
        scrollToLatestMessage(with: proxy)
    }

    private func chatEmptyState(layout: ChatLayoutMetrics) -> some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 16) {
                AppIconBadge(
                    symbol: "sparkles",
                    tint: AppVisualTheme.accentTint,
                    size: 54,
                    symbolSize: 20,
                    isEmphasized: true
                )

                Text("How can I help?")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))

                Text(emptyStateMessage)
                    .font(.system(size: 14.5, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppVisualTheme.foreground(0.56))
                    .frame(maxWidth: layout.emptyStateTextWidth)

                if !canChat {
                    Button("Open Settings") {
                        NotificationCenter.default.post(
                            name: .openAssistOpenSettings, object: SettingsRoute(section: .modelsConnections, subsection: .modelsConnections))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 36)
            .frame(maxWidth: layout.emptyStateCardWidth)
            .appThemedSurface(
                cornerRadius: 14,
                tint: AppVisualTheme.baseTint,
                strokeOpacity: 0.13,
                tintOpacity: 0.02
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: chatViewportContentMinHeight)
        .padding(.vertical, 48)
    }

    private var sessionTransitionPlaceholder: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .tint(AppVisualTheme.foreground(0.5))
            Text("Loading chat…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: chatViewportContentMinHeight)
    }

    private var sessionTransitionOverlay: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(AppVisualTheme.foreground(0.72))

            Text("Loading this chat…")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.80))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(AssistantWindowChrome.toolbarFill.opacity(0.96))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AssistantWindowChrome.border, lineWidth: 0.6)
                )
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func renderTimelineRow(_ item: AssistantTimelineRenderItem, layout: ChatLayoutMetrics)
        -> some View
    {
        switch item {
        case .timeline(let timelineItem):
            timelineRow(timelineItem, layout: layout)
        case .activityGroup(let group):
            timelineActivityGroupRow(group, layout: layout)
        }
    }

    @ViewBuilder
    private func renderTimelineRowWithScrollAnchors(
        _ item: AssistantTimelineRenderItem,
        layout: ChatLayoutMetrics
    ) -> some View {
        VStack(spacing: 0) {
            if case .activityGroup(let group) = item {
                ForEach(group.items.map(\.id), id: \.self) { anchorID in
                    Color.clear
                        .frame(height: 0)
                        .id(anchorID)
                }
            }

            renderTimelineRow(item, layout: layout)
        }
    }

    private func historyPreservationAnchorID(for item: AssistantTimelineRenderItem) -> String? {
        switch item {
        case .timeline(let timelineItem):
            return timelineItem.id
        case .activityGroup(let group):
            return group.items.first?.id ?? group.id
        }
    }

    @ViewBuilder
    private func timelineRow(_ item: AssistantTimelineItem, layout: ChatLayoutMetrics) -> some View
    {
        switch item.kind {
        case .userMessage:
            timelineUserBubble(
                text: item.text ?? "",
                imageAttachments: item.imageAttachments,
                messageID: item.id,
                layout: layout
            )

        case .assistantProgress:
            timelineAssistantRow(
                messageID: item.id,
                sessionID: item.sessionID,
                turnID: item.turnID,
                text: AssistantVisibleTextSanitizer.clean(item.text) ?? "",
                timestamp: item.sortDate,
                title: "Assistant",
                isStreaming: item.isStreaming,
                imageAttachments: item.imageAttachments,
                compact: true,
                showsInlineCopyButton: true,
                showsMemoryActions: false,
                layout: layout
            )

        case .assistantFinal:
            timelineAssistantRow(
                messageID: item.id,
                sessionID: item.sessionID,
                turnID: item.turnID,
                text: AssistantVisibleTextSanitizer.clean(item.text) ?? "",
                timestamp: item.sortDate,
                title: "Assistant",
                isStreaming: item.isStreaming,
                imageAttachments: item.imageAttachments,
                compact: false,
                showsInlineCopyButton: true,
                showsMemoryActions: settings.assistantMemoryEnabled && !item.isStreaming,
                layout: layout
            )

        case .system:
            let isSelectionInsight = isSelectionInsightTimelineItem(item)
            timelineAssistantRow(
                messageID: item.id,
                sessionID: item.sessionID,
                turnID: item.turnID,
                text: item.text ?? "",
                timestamp: item.sortDate,
                title: item.emphasis
                    ? "Needs Attention"
                    : (isSelectionInsight ? "Selection Insight" : "System"),
                isStreaming: item.isStreaming,
                imageAttachments: item.imageAttachments,
                compact: !isSelectionInsight,
                showsInlineCopyButton: true,
                showsMemoryActions: false,
                layout: layout
            )

        case .activity:
            if let activity = item.activity {
                timelineActivityRow(activity, layout: layout)
            }

        case .permission:
            if let request = item.permissionRequest {
                let cardState = assistantPermissionCardState(
                    for: request,
                    pendingRequest: assistant.pendingPermissionRequest,
                    sessionStatus: sessionStatus(forSessionID: request.sessionID)
                )
                HStack(alignment: .top, spacing: 0) {
                    permissionCard(request, state: cardState)
                    Spacer(minLength: layout.leadingReserve)
                }
                .padding(.vertical, 2)
            }

        case .plan:
            if let plan = item.planText {
                HStack(alignment: .top, spacing: 0) {
                    proposedPlanCard(
                        plan,
                        isStreaming: item.isStreaming,
                        showsActions: assistant.proposedPlan == plan
                    )
                    Spacer(minLength: layout.leadingReserve)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func timelineUserBubble(
        text: String,
        imageAttachments: [Data]? = nil,
        messageID: String,
        layout: ChatLayoutMetrics
    ) -> some View {
        HStack {
            Spacer(minLength: layout.leadingReserve)

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    copyMessageButton(
                        text: text,
                        helpText: "Copy user message",
                        isVisible: inlineCopyButtonIsVisible(for: messageID)
                    )
                }

                if let images = imageAttachments, !images.isEmpty {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, imageData in
                        if let nsImage = NSImage(data: imageData) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: layout.userMediaMaxWidth, maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.5)
                                )
                        }
                    }
                }

                Text(verbatim: text)
                    .font(.system(size: 13.8 * CGFloat(chatTextScale), weight: .regular))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))
                    .lineSpacing(2.0)
                    .frame(maxWidth: layout.userBubbleMaxWidth, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(AppVisualTheme.surfaceFill(0.14))
                    )
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .padding(.vertical, 10)
        .onHover { hovering in
            updateInlineCopyHoverState(for: messageID, hovering: hovering)
        }
        .contextMenu {
            Button("Copy Message") {
                copyAssistantTextToPasteboard(text)
            }
        }
    }

    private func pendingAssistantResponseRow(layout: ChatLayoutMetrics) -> some View {
        let detail =
            assistant.hudState.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "Working on your message"

        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    AppIconBadge(
                        symbol: "sparkles",
                        tint: AssistantWindowChrome.neutralAccent,
                        size: 28,
                        symbolSize: 11,
                        isEmphasized: true
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            assistant.hudState.title.isEmpty ? "Thinking" : assistant.hudState.title
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.82))

                        Text(detail)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.46))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                AssistantTypingDots()
                    .padding(.leading, 38)
            }

            Spacer(minLength: layout.isNarrow ? 8 : 40)
        }
        .padding(.leading, 4)
        .padding(.trailing, layout.assistantTrailingPaddingRegular)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    private func timelineAssistantRow(
        messageID: String,
        sessionID: String?,
        turnID: String?,
        text: String,
        timestamp: Date,
        title: String,
        isStreaming: Bool,
        imageAttachments: [Data]?,
        compact: Bool,
        showsInlineCopyButton: Bool,
        showsMemoryActions: Bool,
        layout: ChatLayoutMetrics
    ) -> some View {
        let isStandardAssistant = title == "Assistant"
        let isCompactStatusRow = compact && !isStandardAssistant
        let roleTint = assistantRowTint(for: title)
        let roleIcon = assistantRowIcon(for: title)

        let rowContent = HStack(alignment: .top, spacing: isStandardAssistant ? 0 : 10) {
            if !isStandardAssistant {
                if isCompactStatusRow {
                    compactAssistantStatusIcon(symbol: roleIcon, tint: roleTint)
                } else {
                    AppIconBadge(
                        symbol: roleIcon,
                        tint: roleTint,
                        size: compact ? 24 : 28,
                        symbolSize: compact ? 10 : 11,
                        isEmphasized: isStreaming
                    )
                }
            }

            VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !isStandardAssistant {
                        Text(title)
                            .font(
                                .system(
                                    size: compact ? 11 : 11.5,
                                    weight: isCompactStatusRow ? .medium : .semibold)
                            )
                            .foregroundStyle(
                                AppVisualTheme.foreground(
                                    isCompactStatusRow ? 0.50 : (compact ? 0.62 : 0.72)))

                        Text(timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundStyle(
                                AppVisualTheme.foreground(
                                    isCompactStatusRow ? 0.20 : (compact ? 0.26 : 0.32)))
                    }

                    Spacer(minLength: 8)

                    if showsInlineCopyButton {
                        copyMessageButton(
                            text: text,
                            helpText: title == "Assistant"
                                ? "Copy assistant message" : "Copy message",
                            isVisible: inlineCopyButtonIsVisible(for: messageID)
                        )
                    }
                }

                AssistantMarkdownText(
                    contentID: messageID,
                    text: text,
                    role: .assistant,
                    isStreaming: isStreaming,
                    preferredMaxWidth: layout.contentMaxWidth,
                    selectionMessageID: text.isEmpty ? nil : messageID,
                    selectionMessageText: text.isEmpty ? nil : text,
                    selectionTracker: text.isEmpty ? nil : selectionTracker
                )
                .opacity(isCompactStatusRow ? 0.76 : (compact ? 0.84 : 1.0))
                .textSelection(.enabled)

                if let imageAttachments, !imageAttachments.isEmpty {
                    CollapsibleImageAttachments(
                        imageAttachments: imageAttachments,
                        maxWidth: min(layout.assistantMediaMaxWidth, compact ? 320 : 520),
                        maxHeight: compact ? 220 : 320
                    )
                }
            }

            Spacer(minLength: 0)
        }

        return
            rowContent
            .padding(.horizontal, isStandardAssistant ? 0 : (compact ? 10 : 14))
            .padding(.vertical, isStandardAssistant ? (compact ? 6 : 10) : (compact ? 6 : 12))
            .background {
                if isStandardAssistant {
                    EmptyView()
                } else if isCompactStatusRow {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppVisualTheme.surfaceFill(0.012))
                        .overlay(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(roleTint.opacity(title == "Needs Attention" ? 0.50 : 0.24))
                                .frame(width: 2)
                                .padding(.vertical, 6)
                                .padding(.leading, 1)
                        }
                } else if compact {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(roleTint.opacity(0.025))
                        .overlay(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(roleTint.opacity(0.45))
                                .frame(width: 2)
                                .padding(.vertical, 6)
                                .padding(.leading, 1)
                        }
                } else {
                    EmptyView()
                }
            }
            .padding(.leading, isStandardAssistant ? 0 : 0)
            .padding(
                .trailing,
                isStandardAssistant
                    ? (compact
                        ? layout.assistantTrailingPaddingCompact
                        : layout.assistantTrailingPaddingRegular)
                    : layout.assistantTrailingPaddingStatus
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, compact ? 2 : 8)
            .onHover { hovering in
                guard showsInlineCopyButton else { return }
                updateInlineCopyHoverState(for: messageID, hovering: hovering)
            }
            .contextMenu {
                Button("Copy Message") {
                    copyAssistantTextToPasteboard(text)
                }
                if title == "Assistant", !isStreaming {
                    Button("Play Again") {
                        assistant.replayAssistantVoice(
                            text: text,
                            sessionID: sessionID,
                            turnID: turnID,
                            timelineItemID: messageID
                        )
                    }
                }
                if showsMemoryActions {
                    Button("Save as Memory") {
                        assistant.saveAssistantMessageAsMemory(text)
                    }
                    Button("Mark as Unhelpful") {
                        assistant.markAssistantMessageUnhelpful(text)
                    }
                }
            }
    }

    private func isSelectionInsightTimelineItem(_ item: AssistantTimelineItem) -> Bool {
        guard item.kind == .system,
            let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }

        return text.hasPrefix("### Selection Insight")
            || text.hasPrefix("### Selection Q&A")
    }

    private func threadNoteSelectionContext(
        owner: AssistantNoteOwnerKey,
        noteID: String,
        selectedText: String?,
        anchorRect: CGRect?
    ) -> AssistantTextSelectionTracker.SelectionContext? {
        guard
            let selectedText = selectedText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            let anchorRect,
            let screenRect = threadNoteSelectionScreenRect(from: anchorRect)
        else {
            return nil
        }

        let noteText = noteDraftText(for: owner, noteID: noteID)
        return AssistantTextSelectionTracker.SelectionContext(
            messageID: "note-selection-\(owner.storageKey)-\(noteID.lowercased())",
            selectedText: selectedText,
            parentMessageText: noteText,
            anchorRectOnScreen: screenRect
        )
    }

    private func threadNoteSelectionScreenRect(from anchorRect: CGRect) -> CGRect? {
        guard let container = threadNoteWebContainer,
            let window = container.window
        else {
            return nil
        }

        let localRect = CGRect(
            x: max(0, anchorRect.origin.x),
            y: max(0, anchorRect.origin.y),
            width: max(anchorRect.width, 2),
            height: max(anchorRect.height, 2)
        )
        let windowRect = container.convert(localRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    private func presentThreadNoteSelectionAssistantActions(
        owner: AssistantNoteOwnerKey,
        noteID: String,
        selectedText: String?,
        anchorRect: CGRect?
    ) {
        guard !AssistantSelectionActionHUDManager.shared.retainsPresentationWithoutSelection else {
            return
        }

        guard
            let selection = threadNoteSelectionContext(
                owner: owner,
                noteID: noteID,
                selectedText: selectedText,
                anchorRect: anchorRect
            )
        else {
            hideThreadNoteSelectionAssistantActionsIfNeeded()
            return
        }

        presentSelectionActions(for: selection, allowsNoteActions: false)
    }

    private func hideThreadNoteSelectionAssistantActionsIfNeeded() {
        guard !AssistantSelectionActionHUDManager.shared.retainsPresentationWithoutSelection else {
            return
        }
        AssistantSelectionActionHUDManager.shared.hide()
    }

    private func handleWebViewTextSelection(
        selectedText: String,
        messageID: String,
        parentText: String,
        screenRect: CGRect
    ) {
        guard !selectedText.isEmpty else {
            guard !AssistantSelectionActionHUDManager.shared.retainsPresentationWithoutSelection
            else { return }
            AssistantSelectionActionHUDManager.shared.hide()
            return
        }

        let context = AssistantTextSelectionTracker.SelectionContext(
            messageID: messageID,
            selectedText: selectedText,
            parentMessageText: parentText,
            anchorRectOnScreen: screenRect
        )
        presentSelectionActions(for: context)
    }

    private func presentSelectionActions(
        for selection: AssistantTextSelectionTracker.SelectionContext,
        allowsNoteActions: Bool = true
    ) {
        AssistantSelectionActionHUDManager.shared.show(
            anchorRect: selection.anchorRectOnScreen,
            onExplain: {
                explainSelectedText(using: selection)
            },
            onAsk: {
                askQuestionAboutSelection(using: selection)
            },
            onAddToNote: allowsNoteActions
                ? {
                    addSelectionToCurrentThreadNote(using: selection)
                } : nil,
            onGenerateChart: allowsNoteActions
                ? {
                    generateChartForSelection(using: selection)
                } : nil
        )
    }

    private func addSelectionToCurrentThreadNote(
        using selection: AssistantTextSelectionTracker.SelectionContext
    ) {
        let textToAppend = selection.selectedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textToAppend.isEmpty,
            let owner = currentThreadNoteOwner
                ?? selectedThreadNoteID.map({
                    AssistantNoteOwnerKey(kind: .thread, id: $0)
                })
        else { return }

        _ = ensureSelectedNotesWorkspace(for: owner)

        let workspace: AssistantNotesWorkspace?
        switch owner.kind {
        case .thread:
            workspace = assistant.appendToSelectedThreadNote(
                threadID: owner.id,
                text: textToAppend
            )
        case .project:
            workspace = assistant.appendToSelectedProjectNote(
                projectID: owner.id,
                text: textToAppend
            )
        }
        guard let workspace else { return }

        applyThreadNoteWorkspace(workspace)
        isThreadNoteOpen = true
        AssistantSelectionActionHUDManager.shared.hide()
    }

    private func generateChartForSelection(
        using selection: AssistantTextSelectionTracker.SelectionContext
    ) {
        let normalizedSelectedText = selection.selectedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedParentMessageText = selection.parentMessageText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSelectedText.isEmpty,
            !normalizedParentMessageText.isEmpty,
            let owner = currentThreadNoteOwner
                ?? selectedThreadNoteID.map({
                    AssistantNoteOwnerKey(kind: .thread, id: $0)
                })
        else {
            return
        }

        _ = ensureSelectedNotesWorkspace(for: owner)
        threadNoteChartContextByOwnerKey[owner.storageKey] = ThreadNoteChartContext(
            selectedText: normalizedSelectedText,
            parentMessageText: normalizedParentMessageText,
            sourceKind: "chatSelection"
        )
        threadNoteAIDraftPreviewByOwnerKey.removeValue(forKey: owner.storageKey)
        let requestID = beginThreadNoteAIDraftRequest(for: owner, mode: "chart")
        isThreadNoteOpen = true
        AssistantSelectionActionHUDManager.shared.hide()

        Task {
            let result = await MemoryEntryExplanationService.shared.generateThreadNoteChart(
                selectedText: normalizedSelectedText,
                parentMessageText: normalizedParentMessageText
            )

            await MainActor.run {
                switch result {
                case .success(let markdown):
                    finishThreadNoteAIDraftRequest(
                        for: owner,
                        requestID: requestID,
                        preview: AssistantChatWebThreadNoteAIPreview(
                            mode: "chart",
                            sourceKind: "chatSelection",
                            markdown: markdown,
                            isError: false
                        )
                    )
                case .failure(let message):
                    failThreadNoteAIDraftRequest(
                        for: owner,
                        requestID: requestID,
                        mode: "chart",
                        sourceKind: "chatSelection",
                        message: message
                    )
                }
            }
        }
    }

    private func regenerateThreadNoteChartDraft(
        owner: AssistantNoteOwnerKey,
        currentDraftMarkdown: String?,
        styleInstruction: String?,
        renderError: String?
    ) {
        guard let context = threadNoteChartContextByOwnerKey[owner.storageKey] else {
            threadNoteAIDraftPreviewByOwnerKey[owner.storageKey] =
                AssistantChatWebThreadNoteAIPreview(
                    mode: "chart",
                    sourceKind: "chatSelection",
                    markdown:
                        "The original chart context is no longer available. Select the source text again and choose Generate Chart one more time.",
                    isError: true
                )
            threadNoteAIDraftModeByOwnerKey[owner.storageKey] = "chart"
            threadNoteGeneratingAIDraftOwnerKeys.remove(owner.storageKey)
            return
        }

        let normalizedStyleInstruction = styleInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let normalizedRenderError = renderError?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let hasCurrentDraft =
            currentDraftMarkdown?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        guard hasCurrentDraft || normalizedStyleInstruction != nil || normalizedRenderError != nil
        else {
            return
        }

        let requestID = beginThreadNoteAIDraftRequest(for: owner, mode: "chart")

        Task {
            let result = await MemoryEntryExplanationService.shared.generateThreadNoteChart(
                selectedText: context.selectedText,
                parentMessageText: context.parentMessageText,
                currentDraft: currentDraftMarkdown,
                styleInstruction: normalizedStyleInstruction,
                validationError: normalizedRenderError
            )

            await MainActor.run {
                switch result {
                case .success(let markdown):
                    finishThreadNoteAIDraftRequest(
                        for: owner,
                        requestID: requestID,
                        preview: AssistantChatWebThreadNoteAIPreview(
                            mode: "chart",
                            sourceKind: context.sourceKind,
                            markdown: markdown,
                            isError: false
                        )
                    )
                case .failure(let message):
                    failThreadNoteAIDraftRequest(
                        for: owner,
                        requestID: requestID,
                        mode: "chart",
                        sourceKind: context.sourceKind,
                        message: message
                    )
                }
            }
        }
    }

    private func explainSelectedText(
        using selection: AssistantTextSelectionTracker.SelectionContext
    ) {
        let preview = selectionPreview(for: selection.selectedText)
        AssistantSelectionActionHUDManager.shared.showLoading(
            anchorRect: selection.anchorRectOnScreen,
            selectedPreview: preview,
            title: "Explain Selection"
        )

        Task {
            let result = await MemoryEntryExplanationService.shared.explainSelectedText(
                selection.selectedText,
                parentMessageText: selection.parentMessageText,
                onPartialText: { partialText in
                    Task { @MainActor in
                        self.showSelectionExplanationResult(
                            partialText,
                            for: selection,
                            title: "Explain Selection",
                            preview: preview,
                            isError: false,
                            isStreaming: true
                        )
                    }
                }
            )

            await MainActor.run {
                switch result {
                case .success(let bodyText):
                    showSelectionExplanationResult(
                        bodyText,
                        for: selection,
                        title: "Explain Selection",
                        preview: preview,
                        isError: false,
                        isStreaming: false
                    )
                case .failure(let message):
                    showSelectionExplanationResult(
                        message,
                        for: selection,
                        title: "Explain Selection",
                        preview: preview,
                        isError: true,
                        isStreaming: false
                    )
                }
            }
        }
    }

    private func askQuestionAboutSelection(
        using selection: AssistantTextSelectionTracker.SelectionContext
    ) {
        prepareSelectionAskConversation(for: selection)
        let preview = selectionPreview(for: selection.selectedText)
        let metaText = selectionAssistantMetaText(for: selection)
        AssistantSelectionActionHUDManager.shared.showQuestionComposer(
            anchorRect: selection.anchorRectOnScreen,
            selectedPreview: preview,
            metaText: metaText,
            conversationTurns: selectionAskConversationHistory(for: selection),
            runtimeControls: selectionAssistantRuntimeControls(for: selection),
            onChooseProvider: { backend in
                Task { @MainActor in
                    await self.selectSelectionAssistantProvider(backend, for: selection)
                }
            },
            onChooseModel: { modelID in
                self.selectSelectionAssistantModel(modelID, for: selection)
            },
            onSubmit: { question in
                submitSelectionQuestion(question, using: selection, preview: preview)
            },
            onCancel: {
                presentSelectionActions(for: selection)
            }
        )
    }

    private func submitSelectionQuestion(
        _ question: String,
        using selection: AssistantTextSelectionTracker.SelectionContext,
        preview: String
    ) {
        prepareSelectionAskConversation(for: selection)
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationHistory = selectionAskConversationHistory(for: selection)
        let selectedBackend = selectionAssistantPreferredBackend(for: selection)
        let selectedModelID = selectionAssistantPreferredModelID(for: selection)
        let mainChatSummary = selectionAssistantMainChatSummary(for: selection)
        let metaText = selectionAssistantMetaText(for: selection)
        let pendingConversationTurns = selectionAskTurns(
            from: conversationHistory,
            question: trimmedQuestion
        )

        guard !selectionAssistantRequestInFlight(for: selection) else {
            showSelectionExplanationResult(
                "The side assistant is still working on your last Ask message. Please wait a moment and try again.",
                for: selection,
                title: "Side Assistant",
                preview: preview,
                metaText: metaText,
                conversationTurns: selectionAskConversationHistory(for: selection),
                isError: true,
                isStreaming: false
            )
            return
        }

        setSelectionAssistantRequestInFlight(true, for: selection)

        AssistantSelectionActionHUDManager.shared.showLoading(
            anchorRect: selection.anchorRectOnScreen,
            selectedPreview: preview,
            title: "Side Assistant",
            metaText: metaText,
            conversationTurns: pendingConversationTurns
        )

        Task {
            let result = await assistant.requestSelectionSideAssistantReply(
                selection.selectedText,
                in: selection.parentMessageText,
                question: trimmedQuestion,
                backend: selectedBackend,
                preferredModelID: selectedModelID,
                mainChatSummary: mainChatSummary,
                conversationHistory: conversationHistory,
                onPartialText: { partialText in
                    Task { @MainActor in
                        self.showSelectionExplanationResult(
                            partialText,
                            for: selection,
                            title: "Side Assistant",
                            preview: preview,
                            metaText: metaText,
                            conversationTurns: selectionAskTurns(
                                from: conversationHistory,
                                question: trimmedQuestion,
                                answer: partialText
                            ),
                            isError: false,
                            isStreaming: true
                        )
                    }
                }
            )

            await MainActor.run {
                setSelectionAssistantRequestInFlight(false, for: selection)
                switch result {
                case .success(let bodyText):
                    appendSelectionAskExchange(
                        question: trimmedQuestion,
                        answer: bodyText,
                        for: selection
                    )
                    showSelectionExplanationResult(
                        bodyText,
                        for: selection,
                        title: "Side Assistant",
                        preview: preview,
                        metaText: metaText,
                        conversationTurns: selectionAskConversationHistory(for: selection),
                        isError: false,
                        isStreaming: false
                    )
                case .failure(let message):
                    showSelectionExplanationResult(
                        message,
                        for: selection,
                        title: "Side Assistant",
                        preview: preview,
                        metaText: metaText,
                        conversationTurns: pendingConversationTurns,
                        isError: true,
                        isStreaming: false
                    )
                }
            }
        }
    }

    private func selectionAskConversationKey(
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) -> SelectionAskConversationSession.Key {
        let sessionID =
            (assistant.selectedSessionID ?? assistant.activeRuntimeSessionID
            ?? "selection-message-\(selection.messageID)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? "selection-message-\(selection.messageID)"

        return SelectionAskConversationSession.Key(
            sessionID: sessionID
        )
    }

    private func selectionAskConversation(
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) -> SelectionAskConversationSession? {
        selectionAskConversationsByKey[selectionAskConversationKey(for: selection)]
    }

    private func prepareSelectionAskConversation(
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) {
        let key = selectionAskConversationKey(for: selection)
        guard selectionAskConversationsByKey[key] == nil else { return }
        let initialBackend = assistant.visibleAssistantBackend
        selectionAskConversationsByKey[key] = SelectionAskConversationSession(
            key: key,
            agentSessionID: UUID().uuidString,
            preferredBackend: initialBackend,
            preferredModelID: defaultSelectionAssistantModelID(for: initialBackend),
            isLoadingModels: false,
            isRequestInFlight: false,
            mainChatSummaryFingerprint: nil,
            mainChatSummary: nil,
            turns: []
        )
    }

    private func defaultSelectionAssistantModelID(
        for backend: AssistantRuntimeBackend
    ) -> String? {
        let visibleModels = assistant.selectionSideAssistantVisibleModels(for: backend)
        if backend == .codex,
            let miniModel = visibleModels.first(where: { model in
                model.id.lowercased().contains("mini")
            })
        {
            return miniModel.id
        }
        return assistant.selectionSideAssistantResolvedModelID(
            for: backend,
            preferredModelID: assistant.selectedModelID
        )
    }

    private func updateSelectionAskConversation(
        for selection: AssistantTextSelectionTracker.SelectionContext,
        _ mutate: (inout SelectionAskConversationSession) -> Void
    ) {
        prepareSelectionAskConversation(for: selection)
        let key = selectionAskConversationKey(for: selection)
        guard var conversation = selectionAskConversationsByKey[key] else { return }
        mutate(&conversation)
        selectionAskConversationsByKey[key] = conversation
    }

    private func selectionAskConversationHistory(
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) -> [SelectionAskConversationTurn] {
        selectionAskConversation(for: selection)?.turns ?? []
    }

    private func appendSelectionAskExchange(
        question: String,
        answer: String,
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !trimmedAnswer.isEmpty else { return }

        updateSelectionAskConversation(for: selection) { conversation in
            conversation.turns.append(
                SelectionAskConversationTurn(role: .user, text: trimmedQuestion)
            )
            conversation.turns.append(
                SelectionAskConversationTurn(role: .assistant, text: trimmedAnswer)
            )
        }
    }

    private func selectionAskTurns(
        from existingTurns: [SelectionAskConversationTurn],
        question: String? = nil,
        answer: String? = nil
    ) -> [SelectionAskConversationTurn] {
        var turns = existingTurns

        if let question = question?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            turns.append(
                SelectionAskConversationTurn(role: .user, text: question)
            )
        }

        if let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            turns.append(
                SelectionAskConversationTurn(role: .assistant, text: answer)
            )
        }

        return turns
    }

    private func selectionAssistantPreferredBackend(
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) -> AssistantRuntimeBackend {
        selectionAskConversation(for: selection)?.preferredBackend
            ?? assistant.visibleAssistantBackend
    }

    private func selectionAssistantPreferredModelID(
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) -> String? {
        guard let conversation = selectionAskConversation(for: selection) else {
            return assistant.selectedModelID
        }
        let backend = conversation.preferredBackend
        if let preferredModelID = conversation.preferredModelID {
            return preferredModelID
        }
        if backend == assistant.visibleAssistantBackend {
            return assistant.selectedModelID
        }
        return assistant.selectionSideAssistantResolvedModelID(
            for: backend,
            preferredModelID: nil
        )
    }

    private func setSelectionAssistantRuntimeState(
        for selection: AssistantTextSelectionTracker.SelectionContext,
        backend: AssistantRuntimeBackend,
        modelID: String?,
        isLoadingModels: Bool
    ) {
        updateSelectionAskConversation(for: selection) { conversation in
            conversation.preferredBackend = backend
            conversation.preferredModelID = modelID
            conversation.isLoadingModels = isLoadingModels
        }
    }

    private func selectionAssistantRequestInFlight(
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) -> Bool {
        selectionAskConversation(for: selection)?.isRequestInFlight ?? false
    }

    private func setSelectionAssistantRequestInFlight(
        _ isRequestInFlight: Bool,
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) {
        updateSelectionAskConversation(for: selection) { conversation in
            conversation.isRequestInFlight = isRequestInFlight
        }
    }

    private func selectionAssistantMainChatSummary(
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) -> String? {
        let latestSnapshot = assistant.selectionSideAssistantChatSummarySnapshot()
        guard let latestSnapshot else {
            return selectionAskConversation(for: selection)?.mainChatSummary
        }

        if let conversation = selectionAskConversation(for: selection),
            conversation.mainChatSummaryFingerprint == latestSnapshot.fingerprint,
            conversation.mainChatSummary == latestSnapshot.summary
        {
            return conversation.mainChatSummary
        }

        updateSelectionAskConversation(for: selection) { conversation in
            conversation.mainChatSummaryFingerprint = latestSnapshot.fingerprint
            conversation.mainChatSummary = latestSnapshot.summary
        }
        return latestSnapshot.summary
    }

    private func selectSelectionAssistantProvider(
        _ backend: AssistantRuntimeBackend,
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) async {
        let currentBackend = selectionAssistantPreferredBackend(for: selection)
        let currentModelID =
            currentBackend == backend
            ? selectionAssistantPreferredModelID(for: selection)
            : nil
        setSelectionAssistantRuntimeState(
            for: selection,
            backend: backend,
            modelID: nil,
            isLoadingModels: true
        )
        refreshSelectionAssistantRuntimeControls(for: selection)

        let loadedModels = await assistant.loadSelectionSideAssistantVisibleModels(for: backend)
        let resolvedModelID =
            AssistantStore.resolvedModelSelection(
                from: nil,
                backend: backend,
                availableModels: loadedModels,
                preferredModelID: currentModelID
            )
            ?? {
                if let currentModelID {
                    return assistant.selectionSideAssistantResolvedModelID(
                        for: backend,
                        preferredModelID: currentModelID
                    )
                }
                return defaultSelectionAssistantModelID(for: backend)
            }()

        setSelectionAssistantRuntimeState(
            for: selection,
            backend: backend,
            modelID: resolvedModelID,
            isLoadingModels: false
        )
        refreshSelectionAssistantRuntimeControls(for: selection)
    }

    private func selectSelectionAssistantModel(
        _ modelID: String,
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) {
        let backend = selectionAssistantPreferredBackend(for: selection)
        setSelectionAssistantRuntimeState(
            for: selection,
            backend: backend,
            modelID: modelID,
            isLoadingModels: false
        )
        refreshSelectionAssistantRuntimeControls(for: selection)
    }

    private func selectionPreview(for selectedText: String) -> String {
        let normalized = selectedText.replacingOccurrences(of: "\r\n", with: "\n")
        let cleanedLines =
            normalized
            .components(separatedBy: "\n")
            .map {
                $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        let previewLines = Array(cleanedLines.prefix(4))
        var preview = previewLines.joined(separator: "\n")

        if preview.count > 220 {
            preview = String(preview.prefix(217)) + "..."
        } else if cleanedLines.count > previewLines.count {
            preview += "\n..."
        }

        return preview
    }

    private func showSelectionExplanationResult(
        _ bodyText: String,
        for selection: AssistantTextSelectionTracker.SelectionContext,
        title: String,
        preview: String,
        metaText: String = "",
        conversationTurns: [SelectionAskConversationTurn] = [],
        isError: Bool,
        isStreaming: Bool
    ) {
        let openSettingsAction: (() -> Void)?
        if isError,
            bodyText.localizedCaseInsensitiveContains("connect a provider")
                || bodyText.localizedCaseInsensitiveContains("api key")
                || bodyText.localizedCaseInsensitiveContains("oauth")
        {
            openSettingsAction = {
                NotificationCenter.default.post(
                    name: .openAssistOpenSettings, object: SettingsRoute(section: .assistant, subsection: .assistantSetup))
            }
        } else {
            openSettingsAction = nil
        }

        AssistantSelectionActionHUDManager.shared.showResult(
            anchorRect: selection.anchorRectOnScreen,
            selectedPreview: preview,
            title: title,
            bodyText: bodyText,
            metaText: metaText,
            conversationTurns: conversationTurns,
            isError: isError,
            isStreaming: isStreaming,
            onAsk: isError
                ? nil
                : {
                    askQuestionAboutSelection(using: selection)
                },
            onClose: {
                AssistantSelectionActionHUDManager.shared.hide()
            },
            onOpenSettings: openSettingsAction
        )
    }

    private func selectionAssistantMetaText(
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) -> String {
        let backend = selectionAssistantPreferredBackend(for: selection)
        let modelID = selectionAssistantPreferredModelID(for: selection)
        let modelSummary = selectionAssistantModelSummary(
            backend: backend,
            selectedModelID: modelID,
            for: selection
        )
        return "\(backend.shortDisplayName) • \(modelSummary)"
    }

    private func selectionAssistantRuntimeControls(
        for selection: AssistantTextSelectionTracker.SelectionContext
    )
        -> AssistantSelectionActionHUDManager.RuntimeControls
    {
        let backend = selectionAssistantPreferredBackend(for: selection)
        let modelOptions = assistant.selectionSideAssistantVisibleModels(for: backend)
        let isLoadingModels = selectionAskConversation(for: selection)?.isLoadingModels ?? false
        let isBusy = selectionAskConversation(for: selection)?.isRequestInFlight ?? false
        let runtimeState = assistant.runtimeControlsState(
            for: backend,
            availableModels: modelOptions,
            isLoadingModels: isLoadingModels,
            isBusy: isBusy
        )
        let inheritedModelID =
            backend == assistant.visibleAssistantBackend ? assistant.selectedModelID : nil
        let selectedModelID =
            selectionAskConversation(for: selection)?.preferredModelID
            ?? assistant.selectionSideAssistantResolvedModelID(
                for: backend,
                preferredModelID: inheritedModelID
            )
        return AssistantSelectionActionHUDManager.RuntimeControls(
            availability: runtimeState.availability,
            statusText: runtimeState.statusText.nonEmpty,
            providerOptions: assistant.selectableAssistantBackends,
            selectedProvider: backend,
            isProviderSelectionDisabled: !runtimeState.availability.isReady,
            modelOptions: modelOptions,
            selectedModelID: selectedModelID,
            selectedModelSummary: selectionAssistantModelSummary(
                backend: backend,
                selectedModelID: selectedModelID,
                for: selection
            ),
            isModelLoading: isLoadingModels
        )
    }

    private func refreshSelectionAssistantRuntimeControls(
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) {
        AssistantSelectionActionHUDManager.shared.updateQuestionComposerRuntimeControls(
            selectionAssistantRuntimeControls(for: selection),
            metaText: selectionAssistantMetaText(for: selection)
        )
    }

    private func selectionAssistantModelSummary(
        backend: AssistantRuntimeBackend,
        selectedModelID: String?,
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) -> String {
        let visibleModels = assistant.selectionSideAssistantVisibleModels(for: backend)
        let isLoadingModels = selectionAskConversation(for: selection)?.isLoadingModels ?? false
        let isBusy = selectionAskConversation(for: selection)?.isRequestInFlight ?? false
        let runtimeState = assistant.runtimeControlsState(
            for: backend,
            availableModels: visibleModels,
            isLoadingModels: isLoadingModels,
            isBusy: isBusy
        )
        if !runtimeState.availability.isReady {
            return runtimeState.statusText
        }

        if let selectedModelID,
            let selectedModel = visibleModels.first(where: { $0.id == selectedModelID })
        {
            return selectedModel.displayName
        }

        let fallbackModelID = assistant.selectionSideAssistantResolvedModelID(
            for: backend,
            preferredModelID: selectedModelID ?? assistant.selectedModelID
        )
        if let fallbackModelID,
            let fallbackModel = visibleModels.first(where: { $0.id == fallbackModelID })
        {
            return fallbackModel.displayName
        }

        return visibleModels.isEmpty ? "No models" : "Select model"
    }

    private func compactAssistantStatusIcon(symbol: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(tint.opacity(0.18), lineWidth: 0.55)
                )

            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.92))
        }
        .frame(width: 22, height: 22)
    }

    private func assistantRowTint(for title: String) -> Color {
        switch title {
        case "Needs Attention":
            return .orange
        case "System":
            return AssistantWindowChrome.systemTint
        default:
            return AssistantWindowChrome.neutralAccent
        }
    }

    private func assistantRowIcon(for title: String) -> String {
        switch title {
        case "Needs Attention":
            return "exclamationmark.triangle.fill"
        case "System":
            return "server.rack"
        default:
            return "sparkles"
        }
    }

    private func inlineCopyButtonIsVisible(for messageID: String) -> Bool {
        hoveredInlineCopyMessageID == messageID
    }

    private func updateInlineCopyHoverState(for messageID: String, hovering: Bool) {
        if hovering {
            inlineCopyHideWorkItem?.cancel()
            hoveredInlineCopyMessageID = messageID
        } else if hoveredInlineCopyMessageID == messageID {
            inlineCopyHideWorkItem?.cancel()
            let workItem = DispatchWorkItem {
                if hoveredInlineCopyMessageID == messageID {
                    hoveredInlineCopyMessageID = nil
                }
            }
            inlineCopyHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
        }
    }

    private func timelineActivityRow(_ activity: AssistantActivityItem, layout: ChatLayoutMetrics)
        -> some View
    {
        let openTargets = activityOpenTargets(for: activity)
        let imagePreviews = assistantImagePreviews(from: openTargets)
        let detailSections = activityDetailSections(from: activity.rawDetails)
        let isExpanded = expandedActivityIDs.contains(activity.id)
        let canExpand = !detailSections.isEmpty || !openTargets.isEmpty

        return VStack(alignment: .leading, spacing: isExpanded ? 8 : 2) {
            timelineActivitySummaryLine(
                iconName: activityIconName(activity),
                iconTint: activityIconTint(activity),
                title: activityHeadline(activity, openTargetCount: openTargets.count),
                subtitle: canExpand && !isExpanded
                    ? activitySecondaryText(activity, openTargets: openTargets) : nil,
                statusLabel: activityStatusLabel(activity),
                statusTint: activityStatusTint(activity),
                timestamp: activity.updatedAt,
                disclosureState: canExpand ? (isExpanded ? .expanded : .collapsed) : nil
            ) {
                toggleExpandedActivity(activity.id)
            }

            if isExpanded {
                timelineActivityExpandedDetails(
                    detailSections: detailSections,
                    openTargets: openTargets,
                    imagePreviews: imagePreviews
                )
                .padding(.leading, 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, layout.activityLeadingPadding)
        .padding(.trailing, layout.activityTrailingPadding)
        .padding(.vertical, 4)
    }

    private func timelineActivityGroupRow(
        _ group: AssistantTimelineActivityGroup, layout: ChatLayoutMetrics
    ) -> some View {
        let openTargets = activityOpenTargets(for: group)
        let imagePreviews = assistantImagePreviews(from: openTargets)
        let isExpanded = expandedActivityIDs.contains(group.id)
        let canExpand = !group.activities.isEmpty || !openTargets.isEmpty

        return VStack(alignment: .leading, spacing: isExpanded ? 8 : 2) {
            timelineActivitySummaryLine(
                iconName: activityGroupIconName(group),
                iconTint: activityGroupIconTint(group),
                title: activityGroupHeadline(group),
                subtitle: canExpand && !isExpanded
                    ? activityGroupSecondaryText(group, openTargets: openTargets) : nil,
                statusLabel: activityGroupStatusLabel(group),
                statusTint: activityGroupStatusTint(group),
                timestamp: group.lastUpdatedAt,
                disclosureState: canExpand ? (isExpanded ? .expanded : .collapsed) : nil
            ) {
                toggleExpandedActivity(group.id)
            }

            if isExpanded {
                timelineActivityGroupExpandedDetails(
                    group,
                    openTargets: openTargets,
                    imagePreviews: imagePreviews
                )
                .padding(.leading, 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, layout.activityLeadingPadding)
        .padding(.trailing, layout.activityTrailingPadding)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func timelineActivitySummaryLine(
        iconName: String,
        iconTint: Color,
        title: String,
        subtitle: String?,
        statusLabel: String,
        statusTint: Color,
        timestamp: Date,
        disclosureState: TimelineDisclosureState? = nil,
        onTap: (() -> Void)? = nil
    ) -> some View {
        let line = HStack(alignment: .center, spacing: 8) {
            if let disclosureState {
                timelineDisclosureChevron(expanded: disclosureState == .expanded)
                    .frame(width: 12, height: 12)
            }

            Image(systemName: iconName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 14, height: 14)

            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.72))
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.42))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Circle()
                .fill(statusTint)
                .frame(width: 5, height: 5)

            Text(statusLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusTint.opacity(0.92))

            Text(timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10))
                .foregroundStyle(AppVisualTheme.foreground(0.26))
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if let onTap, disclosureState != nil {
            Button(action: onTap) {
                line
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            line
        }
    }

    private func timelineDisclosureChevron(expanded: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AppVisualTheme.foreground(0.4))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(.spring(response: 0.24, dampingFraction: 0.88), value: expanded)
    }

    private func timelineActivityOpenTargetsList(_ targets: [AssistantActivityOpenTarget])
        -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(targets.prefix(6))) { target in
                Button {
                    openActivityTarget(target)
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: activityOpenTargetIconName(target))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AssistantWindowChrome.neutralAccent.opacity(0.94))
                            .frame(width: 14, height: 14)

                        Text(target.label)
                            .font(.system(size: 10.8, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.foreground(0.78))
                            .lineLimit(1)

                        if let detail = target.detail {
                            Text(detail)
                                .font(.system(size: 10.2, weight: .medium))
                                .foregroundStyle(AppVisualTheme.foreground(0.34))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppVisualTheme.foreground(0.32))
                    }
                    .padding(.vertical, 1)
                }
                .buttonStyle(.plain)
                .help("Open \(target.label)")
            }

            if targets.count > 6 {
                Text("+ \(targets.count - 6) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.28))
                    .padding(.leading, 22)
            }
        }
    }

    private func activityOpenTargets(for activity: AssistantActivityItem)
        -> [AssistantActivityOpenTarget]
    {
        assistantActivityOpenTargets(
            for: activity,
            sessionCWD: sessionWorkingDirectory(for: activity.sessionID)
        )
    }

    private func activityOpenTargets(for group: AssistantTimelineActivityGroup)
        -> [AssistantActivityOpenTarget]
    {
        var results: [AssistantActivityOpenTarget] = []
        var seen = Set<String>()

        for activity in group.activities {
            for target in activityOpenTargets(for: activity) {
                guard seen.insert(target.id).inserted else { continue }
                results.append(target)
            }
        }

        return results
    }

    private func sessionWorkingDirectory(for sessionID: String?) -> String? {
        if let sessionID,
            let cwd = assistant.sessions.first(where: {
                assistantTimelineSessionIDsMatch($0.id, sessionID)
            })?.effectiveCWD?.assistantNonEmpty
                ?? assistant.sessions.first(where: {
                    assistantTimelineSessionIDsMatch($0.id, sessionID)
                })?.cwd?.assistantNonEmpty
        {
            return cwd
        }

        if let selectedSessionID = assistant.selectedSessionID,
            let cwd = assistant.sessions.first(where: {
                assistantTimelineSessionIDsMatch($0.id, selectedSessionID)
            })?.effectiveCWD?.assistantNonEmpty
                ?? assistant.sessions.first(where: {
                    assistantTimelineSessionIDsMatch($0.id, selectedSessionID)
                })?.cwd?.assistantNonEmpty
        {
            return cwd
        }

        return nil
    }

    private func toggleExpandedActivity(_ id: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedActivityIDs.contains(id) {
                expandedActivityIDs.remove(id)
            } else {
                expandedActivityIDs.insert(id)
            }
        }
    }

    private func activityDetailSections(from rawDetails: String?)
        -> [TimelineActivityDetailSectionData]
    {
        guard
            let trimmed = rawDetails?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .assistantNonEmpty
        else {
            return []
        }

        guard let separatorRange = trimmed.range(of: "\n\n") else {
            return [TimelineActivityDetailSectionData(title: "Details", text: trimmed)]
        }

        let request = String(trimmed[..<separatorRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let response = String(trimmed[separatorRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [TimelineActivityDetailSectionData] = []
        if let request = request.assistantNonEmpty {
            sections.append(TimelineActivityDetailSectionData(title: "Request", text: request))
        }
        if let response = response.assistantNonEmpty {
            sections.append(TimelineActivityDetailSectionData(title: "Response", text: response))
        }

        return sections
    }

    @ViewBuilder
    private func timelineActivityExpandedDetails(
        detailSections: [TimelineActivityDetailSectionData],
        openTargets: [AssistantActivityOpenTarget],
        imagePreviews: [AssistantTimelineImagePreview]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(detailSections.enumerated()), id: \.offset) { _, section in
                timelineActivityDetailSection(section)
            }

            if !openTargets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.34))
                        .textCase(.uppercase)

                    timelineActivityOpenTargetsList(openTargets)
                }
            }

            if !imagePreviews.isEmpty {
                timelineActivityImagePreviewSection(imagePreviews)
            }
        }
    }

    private func timelineActivityGroupExpandedDetails(
        _ group: AssistantTimelineActivityGroup,
        openTargets: [AssistantActivityOpenTarget],
        imagePreviews: [AssistantTimelineImagePreview]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !openTargets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.34))
                        .textCase(.uppercase)

                    timelineActivityOpenTargetsList(openTargets)
                }
            }

            if !imagePreviews.isEmpty {
                timelineActivityImagePreviewSection(imagePreviews)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Steps")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.34))
                    .textCase(.uppercase)

                ForEach(Array(group.activities.prefix(6).enumerated()), id: \.element.id) {
                    _, activity in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Image(systemName: activityIconName(activity))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(activityIconTint(activity))
                                .frame(width: 14, height: 14)

                            Text(activity.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppVisualTheme.foreground(0.66))

                            Text(activityStatusLabel(activity))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(activityStatusTint(activity).opacity(0.88))

                            Spacer(minLength: 0)
                        }

                        Text(
                            activity.rawDetails?
                                .replacingOccurrences(of: "\n", with: " ")
                                .assistantNonEmpty
                                ?? activity.friendlySummary
                        )
                        .font(.system(size: 10.2, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.42))
                        .lineLimit(2)
                        .padding(.leading, 22)
                    }
                }

                if group.activities.count > 6 {
                    Text("+ \(group.activities.count - 6) more steps")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.28))
                        .padding(.leading, 22)
                }
            }
        }
    }

    private func timelineActivityImagePreviewSection(
        _ previews: [AssistantTimelineImagePreview]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Screenshots")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(AppVisualTheme.foreground(0.34))
                .textCase(.uppercase)

            ForEach(previews) { preview in
                Button {
                    openActivityTarget(
                        AssistantActivityOpenTarget(
                            kind: .file,
                            label: preview.label,
                            url: preview.url,
                            detail: preview.detail
                        )
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let nsImage = NSImage(data: preview.data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 320, maxHeight: 220, alignment: .leading)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.5)
                                )
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(preview.label)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(AppVisualTheme.foreground(0.72))
                                .lineLimit(1)

                            if let detail = preview.detail {
                                Text(detail)
                                    .font(.system(size: 9.8, weight: .medium))
                                    .foregroundStyle(AppVisualTheme.foreground(0.34))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Open \(preview.label)")
            }
        }
    }

    private func timelineActivityDetailSection(_ section: TimelineActivityDetailSectionData)
        -> some View
    {
        let formattedText = assistantFormattedActivityDetailText(section.text)
        let shouldScroll =
            formattedText.count > 420 || formattedText.filter(\.isNewline).count >= 10

        return VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(AppVisualTheme.foreground(0.34))
                .textCase(.uppercase)

            if shouldScroll {
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    Text(formattedText)
                        .font(.system(size: 10.3, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppVisualTheme.foreground(0.62))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AssistantWindowChrome.editorFill.opacity(0.88))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.55)
                        )
                )
                .appScrollbars()
            } else {
                Text(formattedText)
                    .font(.system(size: 10.3, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppVisualTheme.foreground(0.62))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AssistantWindowChrome.editorFill.opacity(0.88))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.55)
                            )
                    )
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.09))
                .frame(width: 2)
        }
    }

    private func openActivityTarget(_ target: AssistantActivityOpenTarget) {
        if target.kind == .file || target.url.isFileURL {
            let fileURL = target.url.isFileURL ? target.url : URL(fileURLWithPath: target.url.path)
            AssistantWorkspaceFileOpener.openFileURL(fileURL)
            return
        }

        NSWorkspace.shared.open(target.url)
    }

    private func activityHeadline(_ activity: AssistantActivityItem, openTargetCount: Int) -> String
    {
        switch activity.kind {
        case .commandExecution:
            return openTargetCount > 0
                ? "Explored \(openTargetCount) file\(openTargetCount == 1 ? "" : "s")"
                : "Explored the workspace"
        case .fileChange:
            return openTargetCount > 0
                ? "Edited \(openTargetCount) file\(openTargetCount == 1 ? "" : "s")"
                : "Edited the workspace"
        case .webSearch:
            return "Searched the web"
        case .browserAutomation:
            return openTargetCount > 0
                ? "Opened \(openTargetCount) link\(openTargetCount == 1 ? "" : "s")"
                : "Used the browser"
        case .mcpToolCall:
            return activity.title
        case .dynamicToolCall:
            return activity.title
        case .subagent:
            return activity.title
        case .reasoning:
            return "Reasoned through the task"
        case .other:
            return activity.title
        }
    }

    private func activitySecondaryText(
        _ activity: AssistantActivityItem,
        openTargets: [AssistantActivityOpenTarget]
    ) -> String? {
        if !openTargets.isEmpty {
            return nil
        }

        if let rawDetails = activity.rawDetails?.assistantNonEmpty {
            return rawDetails.replacingOccurrences(of: "\n", with: " ")
        }

        return activity.friendlySummary
    }

    private func activityGroupHeadline(_ group: AssistantTimelineActivityGroup) -> String {
        let exploredFiles = group.activities
            .filter { $0.kind == .commandExecution }
            .flatMap { activityOpenTargets(for: $0) }
            .filter { $0.kind == .file }
        let editedFiles = group.activities
            .filter { $0.kind == .fileChange }
            .flatMap { activityOpenTargets(for: $0) }
            .filter { $0.kind == .file }
        let searches = group.activities.filter { $0.kind == .webSearch }.count

        var fragments: [String] = []
        if !exploredFiles.isEmpty {
            fragments.append(
                "explored \(exploredFiles.count) file\(exploredFiles.count == 1 ? "" : "s")")
        }
        if !editedFiles.isEmpty {
            fragments.append("edited \(editedFiles.count) file\(editedFiles.count == 1 ? "" : "s")")
        }
        if searches > 0 {
            fragments.append("ran \(searches) search\(searches == 1 ? "" : "es")")
        }

        if fragments.isEmpty {
            return activityGroupTitle(group)
        }

        let joined = fragments.joined(separator: ", ")
        return joined.prefix(1).uppercased() + String(joined.dropFirst())
    }

    private func activityGroupSecondaryText(
        _ group: AssistantTimelineActivityGroup,
        openTargets: [AssistantActivityOpenTarget]
    ) -> String? {
        openTargets.isEmpty ? activityGroupSummary(group) : nil
    }

    private func activityOpenTargetIconName(_ target: AssistantActivityOpenTarget) -> String {
        switch target.kind {
        case .file:
            return "doc.text"
        case .webSearch:
            return "magnifyingglass"
        case .url:
            return "link"
        }
    }

    private var toolActivityStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    toolCallsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    timelineDisclosureChevron(expanded: toolCallsExpanded)
                        .frame(width: 12, height: 12)

                    Image(systemName: "bolt.horizontal.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.4))

                    Text(toolActivitySummary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.5))

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            if toolCallsExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !selectedSessionToolActivity.activeCalls.isEmpty {
                            toolActivitySection(
                                title: "Active", calls: selectedSessionToolActivity.activeCalls)
                        }
                        if !selectedSessionToolActivity.recentCalls.isEmpty {
                            toolActivitySection(
                                title: "Recent", calls: selectedSessionToolActivity.recentCalls)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.leading, 18)
                }
                .frame(maxHeight: 200)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    )
                )
            }
        }
        .clipped()
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func toolActivitySection(title: String, calls: [AssistantToolCallState]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AppVisualTheme.foreground(0.35))
                .textCase(.uppercase)

            ForEach(calls) { call in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: iconName(for: call))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(iconTint(for: call))
                        .frame(width: 14, height: 14)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(call.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.foreground(0.72))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let detail = call.detail?.trimmingCharacters(
                            in: .whitespacesAndNewlines),
                            !detail.isEmpty
                        {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(AppVisualTheme.foreground(0.48))
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }

                    Text(statusLabel(for: call))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(statusTint(for: call))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(statusTint(for: call).opacity(0.12))
                        )
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var toolActivitySummary: String {
        switch (
            selectedSessionToolActivity.activeCalls.count,
            selectedSessionToolActivity.recentCalls.count
        ) {
        case (let active, let recent) where active > 0 && recent > 0:
            return "\(active) active, \(recent) recent activities"
        case (let active, _) where active > 0:
            return "\(active) active tool\(active == 1 ? "" : "s")"
        case (_, let recent):
            return "\(recent) recent activit\(recent == 1 ? "y" : "ies")"
        }
    }

    private func iconName(for call: AssistantToolCallState) -> String {
        switch call.kind {
        case "webSearch":
            return "globe"
        case "commandExecution":
            return "terminal"
        case "mcpToolCall":
            return "shippingbox"
        case "browserAutomation":
            return "safari"
        case "fileChange":
            return "doc.badge.gearshape"
        case "reasoning":
            return "brain"
        case "dynamicToolCall":
            return "wrench.and.screwdriver"
        default:
            return "gearshape.fill"
        }
    }

    private func statusLabel(for call: AssistantToolCallState) -> String {
        let normalized = call.status.replacingOccurrences(
            of: "([A-Z])", with: " $1", options: .regularExpression)
        return normalized.capitalized
    }

    private func iconTint(for call: AssistantToolCallState) -> Color {
        switch call.kind {
        case "webSearch":
            return .cyan.opacity(0.8)
        case "commandExecution":
            return .green.opacity(0.8)
        case "fileChange":
            return .orange.opacity(0.85)
        default:
            return AppVisualTheme.foreground(0.5)
        }
    }

    private func statusTint(for call: AssistantToolCallState) -> Color {
        switch call.status.lowercased() {
        case "completed":
            return Color.green.opacity(0.78)
        case "failed", "errored":
            return Color.red.opacity(0.78)
        default:
            return AppVisualTheme.accentTint.opacity(0.75)
        }
    }

    private func activityIconName(_ activity: AssistantActivityItem) -> String {
        switch activity.kind {
        case .webSearch:
            return "globe"
        case .commandExecution:
            return "terminal"
        case .mcpToolCall:
            return "shippingbox"
        case .browserAutomation:
            return "safari"
        case .fileChange:
            return "doc.badge.gearshape"
        case .subagent:
            return "person.2.fill"
        case .reasoning:
            return "brain"
        case .dynamicToolCall:
            return "wrench.and.screwdriver"
        case .other:
            return "gearshape.fill"
        }
    }

    private func activityIconTint(_ activity: AssistantActivityItem) -> Color {
        switch activity.kind {
        case .webSearch:
            return .cyan.opacity(0.8)
        case .commandExecution:
            return .green.opacity(0.8)
        case .fileChange:
            return .orange.opacity(0.85)
        case .subagent:
            return .blue.opacity(0.8)
        default:
            return AppVisualTheme.foreground(0.5)
        }
    }

    private func activityStatusLabel(_ activity: AssistantActivityItem) -> String {
        activity.status.rawValue.capitalized
    }

    private func activityStatusTint(_ activity: AssistantActivityItem) -> Color {
        switch activity.status {
        case .completed:
            return Color.green.opacity(0.78)
        case .failed:
            return Color.red.opacity(0.78)
        case .interrupted:
            return Color.orange.opacity(0.78)
        case .waiting:
            return Color.yellow.opacity(0.78)
        case .pending, .running:
            return AppVisualTheme.accentTint.opacity(0.75)
        }
    }

    private func activityGroupTitle(_ group: AssistantTimelineActivityGroup) -> String {
        let activities = group.activities
        guard let first = activities.first else { return "Activity" }

        let uniqueKinds = Set(activities.map(\.kind))
        if uniqueKinds.count == 1 {
            switch first.kind {
            case .commandExecution:
                return activities.count == 1 ? "Command" : "Commands"
            case .fileChange:
                return activities.count == 1 ? "File Change" : "File Changes"
            case .webSearch:
                return activities.count == 1 ? "Search" : "Searches"
            case .browserAutomation:
                return activities.count == 1 ? "Browser Step" : "Browser Steps"
            case .subagent:
                return activities.count == 1 ? "Subagent Step" : "Subagent Steps"
            case .mcpToolCall, .dynamicToolCall:
                return activities.count == 1 ? "Tool Use" : "Tool Uses"
            case .reasoning:
                return "Reasoning"
            case .other:
                return activities.count == 1 ? "Activity" : "Activities"
            }
        }

        return "Activity"
    }

    private func activityGroupSummary(_ group: AssistantTimelineActivityGroup) -> String {
        let activities = group.activities
        guard !activities.isEmpty else { return "No activity details available." }

        let counts = Dictionary(grouping: activities, by: \.kind).mapValues(\.count)
        var fragments: [String] = []

        if let commands = counts[.commandExecution], commands > 0 {
            fragments.append("\(commands) command\(commands == 1 ? "" : "s")")
        }
        if let fileChanges = counts[.fileChange], fileChanges > 0 {
            fragments.append("\(fileChanges) file change\(fileChanges == 1 ? "" : "s")")
        }
        if let searches = counts[.webSearch], searches > 0 {
            fragments.append("\(searches) search\(searches == 1 ? "" : "es")")
        }
        if let browserSteps = counts[.browserAutomation], browserSteps > 0 {
            fragments.append("\(browserSteps) browser step\(browserSteps == 1 ? "" : "s")")
        }
        if let subagentSteps = counts[.subagent], subagentSteps > 0 {
            fragments.append("\(subagentSteps) subagent step\(subagentSteps == 1 ? "" : "s")")
        }

        let toolUses = (counts[.mcpToolCall] ?? 0) + (counts[.dynamicToolCall] ?? 0)
        if toolUses > 0 {
            fragments.append("\(toolUses) tool use\(toolUses == 1 ? "" : "s")")
        }

        let otherCount = counts[.other] ?? 0
        if otherCount > 0 {
            fragments.append("\(otherCount) other activit\(otherCount == 1 ? "y" : "ies")")
        }

        if fragments.isEmpty {
            return "\(activities.count) activit\(activities.count == 1 ? "y" : "ies")"
        }

        return fragments.prefix(3).joined(separator: ", ")
    }

    private func activityGroupStatusLabel(_ group: AssistantTimelineActivityGroup) -> String {
        if group.activities.contains(where: { $0.status == .failed }) {
            return "Failed"
        }
        if group.activities.contains(where: { $0.status == .interrupted }) {
            return "Interrupted"
        }
        if group.activities.contains(where: { $0.status == .waiting }) {
            return "Waiting"
        }
        if group.activities.contains(where: { $0.status == .running || $0.status == .pending }) {
            return "Running"
        }
        return "Completed"
    }

    private func activityGroupStatusTint(_ group: AssistantTimelineActivityGroup) -> Color {
        switch activityGroupStatusLabel(group) {
        case "Completed":
            return Color.green.opacity(0.78)
        case "Failed":
            return Color.red.opacity(0.78)
        case "Interrupted":
            return Color.orange.opacity(0.82)
        default:
            return AppVisualTheme.accentTint.opacity(0.75)
        }
    }

    private func activityGroupIconName(_ group: AssistantTimelineActivityGroup) -> String {
        let activities = group.activities
        guard let first = activities.first else { return "square.stack.3d.up" }
        let uniqueKinds = Set(activities.map(\.kind))
        return uniqueKinds.count == 1 ? activityIconName(first) : "square.stack.3d.up"
    }

    private func activityGroupIconTint(_ group: AssistantTimelineActivityGroup) -> Color {
        let activities = group.activities
        guard let first = activities.first else { return AppVisualTheme.foreground(0.5) }
        let uniqueKinds = Set(activities.map(\.kind))
        return uniqueKinds.count == 1 ? activityIconTint(first) : AppVisualTheme.foreground(0.5)
    }

    private func sendCurrentPrompt() {
        userHasScrolledUp = false
        let prompt = assistant.promptDraft
        let contextInstructions = buildNoteContextInstructions()
        if let appDelegate = AppDelegate.shared {
            appDelegate.sendAssistantTypedPrompt(
                prompt, oneShotInstructions: contextInstructions)
        } else {
            Task {
                await assistant.sendPrompt(
                    prompt,
                    selectedPluginIDs: nil,
                    automationJob: nil,
                    oneShotInstructions: contextInstructions
                )
            }
        }
    }

    private func buildNoteContextInstructions() -> String? {
        guard let ctx = composerNoteContextForState else { return nil }

        var lines: [String] = []
        let projectPart: String
        if let projectTitle = ctx.projectTitle, !projectTitle.isEmpty {
            projectPart = " in project \"\(projectTitle)\""
        } else {
            projectPart = ""
        }
        lines.append(
            "The user is currently viewing the note \"\(ctx.noteTitle)\"\(projectPart). "
                + "When they refer to \"this note\", \"the note\", \"here\", or similar, they mean this note. "
                + "If the user's question is clearly unrelated to the note, ignore this context."
        )
        if let sourceLabel = ctx.sourceLabel, !sourceLabel.isEmpty {
            lines.append("Open note source: \(sourceLabel).")
        }
        if let filePath = ctx.filePath, !filePath.isEmpty {
            lines.append("Open note file path: \(filePath).")
        }

        let shouldAttachContent =
            ctx.includeContent
            || AssistantComposerNoteContentPolicy.shouldAutoAttachContent(prompt: assistant.promptDraft)
        if shouldAttachContent,
            let raw = noteContentText(for: ctx)
        {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let cap = 6000
                let clipped =
                    trimmed.count > cap
                    ? String(trimmed.prefix(cap)) + "\n\n…[note truncated]" : trimmed
                lines.append("Note content:\n\(clipped)")
            }
        }

        return lines.joined(separator: "\n\n")
    }

    private func noteContentText(for ctx: AssistantComposerWebNoteContext) -> String? {
        if let ownerKindRaw = ctx.ownerKind,
            let ownerKind = AssistantNoteOwnerKind(rawValue: ownerKindRaw),
            let ownerID = ctx.ownerID,
            let noteID = ctx.noteID
        {
            return noteDraftText(
                for: AssistantNoteOwnerKey(kind: ownerKind, id: ownerID),
                noteID: noteID
            )
        }

        if let filePath = ctx.filePath,
            notesWorkspaceExternalMarkdownFile?.filePath == filePath
        {
            return notesWorkspaceExternalMarkdownFile?.draftText
        }

        return nil
    }

    private func toggleInteractionMode() {
        assistant.interactionMode = assistant.interactionMode.nextMode
    }

    private func minimizeToCompact() {
        NotificationCenter.default.post(
            name: .openAssistMinimizeAssistantToCompact,
            object: nil
        )
    }

    @ViewBuilder
    private var chatComposerBanners: some View {
        if let voiceBanner = composerVoiceBanner {
            composerStatusBanner(
                symbol: voiceBanner.symbol,
                text: voiceBanner.text,
                tint: voiceBanner.tint
            )
            .padding(.bottom, 6)
        }

        if let blockedReason = assistant.conversationBlockedReason {
            composerStatusBanner(
                symbol: assistant.isLoadingModels ? "hourglass" : "exclamationmark.circle",
                text: blockedReason,
                tint: assistant.isLoadingModels ? AppVisualTheme.foreground(0.50) : .orange
            )
            .padding(.bottom, 6)
        }

        if let suggestion = assistant.modeSwitchSuggestion {
            composerStatusBanner(
                symbol: suggestion.source == .blocked ? "arrow.triangle.branch" : "lightbulb",
                text: suggestion.message,
                tint: suggestion.source == .blocked ? .orange : AppVisualTheme.foreground(0.50)
            ) {
                modeSwitchSuggestionButtons(suggestion)
            }
            .padding(.bottom, 6)
        }

        if let branch = assistant.historyBranchState,
            let bannerText = branch.bannerText
        {
            historyBranchBanner(branch: branch, bannerText: bannerText)
                .padding(.bottom, 6)
        }
    }

    private func chatComposer(
        layout: ChatLayoutMetrics,
        state: AssistantComposerWebState
    ) -> some View {
        let isCompactComposer = state.base.isCompactComposer
        let measuredHeight =
            isCompactComposer
            ? notesAssistantComposerMeasuredHeight
            : composerMeasuredHeight

        return VStack(alignment: .leading, spacing: isCompactComposer ? 6 : 8) {
            if isCompactComposer {
                if let preflightStatusMessage = state.base.preflightStatusMessage {
                    composerStatusBanner(
                        symbol: assistant.isLoadingModels
                            ? "hourglass"
                            : "exclamationmark.circle",
                        text: preflightStatusMessage,
                        tint: assistant.isLoadingModels
                            ? AppVisualTheme.foreground(0.50)
                            : .orange
                    )
                    .padding(.bottom, 4)
                }
            } else {
                chatComposerBanners
            }

            AssistantComposerWebView(
                state: state,
                accentColor: AppVisualTheme.assistantWebAccentTint,
                onHeightChange: { height in
                    updateComposerMeasuredHeight(height, compact: isCompactComposer)
                },
                onCommand: handleComposerWebCommand
            )
            .frame(
                height: composerWebHeight(
                    for: layout,
                    compact: isCompactComposer,
                    measuredHeight: measuredHeight
                )
            )
            .onDrop(of: [.fileURL, .image, .png, .jpeg], isTargeted: nil) { providers in
                handleDrop(providers)
                return true
            }
        }
        // Background provided by unified chatBottomDock container
    }

    private var canSendMessage: Bool {
        canStartConversation
            && composerPendingPermissionHelperText == nil
            && (!trimmedPromptDraft.isEmpty || !assistant.attachments.isEmpty)
    }

    private var trimmedPromptDraft: String {
        assistant.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sessionMemoryIsActive: Bool {
        guard settings.assistantMemoryEnabled else { return false }
        guard
            let message = assistant.memoryStatusMessage?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !message.isEmpty
        else {
            return false
        }
        return message.lowercased().contains("using")
    }

    private var sessionMemoryStatusLabel: String {
        sessionMemoryIsActive ? "Session memory on" : "Session memory off"
    }

    private func toggleComposerQuickActionsMenu() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            isComposerQuickActionsMenuPresented.toggle()
        }
    }

    private func dismissComposerQuickActionsMenu(animated: Bool = true) {
        guard isComposerQuickActionsMenuPresented else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.16)) {
                isComposerQuickActionsMenuPresented = false
            }
        } else {
            isComposerQuickActionsMenuPresented = false
        }
    }

    @ViewBuilder
    private func composerQuickActionsMenu(state: AssistantComposerWebState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ComposerQuickActionItemView(
                title: "Upload image or file",
                subtitle: "Add a picture, file, or folder.",
                symbol: "plus"
            ) {
                dismissComposerQuickActionsMenu()
                openFilePicker()
            }

            ComposerQuickActionItemView(
                title: "Snipping tool",
                subtitle: "Take a screenshot and attach it to this chat.",
                symbol: "camera.viewfinder"
            ) {
                dismissComposerQuickActionsMenu()
                captureComposerScreenshotAttachment()
            }

            if state.base.canOpenSkills {
                ComposerQuickActionItemView(
                    title: "Use skills",
                    subtitle: state.base.activeSkills.isEmpty
                        ? "Browse skills and attach one to this thread."
                        : "\(state.base.activeSkills.count) skill\(state.base.activeSkills.count == 1 ? "" : "s") attached to this thread.",
                    symbol: "sparkles"
                ) {
                    dismissComposerQuickActionsMenu()
                    guard prepareToLeaveCurrentNoteScreen(reason: "open Skills") else { return }
                    selectedSidebarPane = .skills
                }
            }

            if state.base.canOpenPlugins {
                ComposerQuickActionItemView(
                    title: "Use plugins",
                    subtitle: state.base.selectedPlugins.isEmpty
                        ? "Browse plugins and use installed ones with @."
                        : "\(state.base.selectedPlugins.count) plugin\(state.base.selectedPlugins.count == 1 ? "" : "s") selected for this message.",
                    symbol: "shippingbox",
                    isActive: !state.base.selectedPlugins.isEmpty
                ) {
                    dismissComposerQuickActionsMenu()
                    guard prepareToLeaveCurrentNoteScreen(reason: "open Plugins") else { return }
                    selectedSidebarPane = .plugins
                    Task { await assistant.refreshCodexPluginCatalogIfNeeded() }
                }
            }

            if state.base.showNoteModeButton {
                ComposerQuickActionItemView(
                    title: state.base.isNoteModeActive ? "Turn off Note Mode" : "Turn on Note Mode",
                    subtitle: state.base.isNoteModeActive
                        ? "Go back to normal chat."
                        : "Keep this chat focused on notes.",
                    symbol: "note.text",
                    isActive: state.base.isNoteModeActive
                ) {
                    dismissComposerQuickActionsMenu()
                    assistant.taskMode = state.base.isNoteModeActive ? .chat : .note
                }
            }
        }
        .padding(6)
        .frame(width: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.12), lineWidth: 0.5)
                )
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
        .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
    }

    private struct ComposerQuickActionItemView: View {
        let title: String
        let subtitle: String
        let symbol: String
        var isActive: Bool = false
        let action: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            isActive
                                ? AppVisualTheme.accentTint
                                : AppVisualTheme.foreground(0.7)
                        )
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(
                                    isActive
                                        ? AppVisualTheme.accentTint.opacity(0.15)
                                        : AppVisualTheme.surfaceFill(0.06)
                                )
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.foreground(0.9))

                        Text(subtitle)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(AppVisualTheme.foreground(0.55))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isActive
                                ? AppVisualTheme.accentTint.opacity(isHovered ? 0.12 : 0.05)
                                : AppVisualTheme.surfaceFill(isHovered ? 0.06 : 0.0)
                        )
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }

    private var liveVoicePanel: some View {
        VStack(spacing: 0) {
            // Collapsed header – always visible
            HStack(spacing: 8) {
                AssistantStatusBadge(
                    title: "Live Voice Agent",
                    tint: liveVoiceStatusTint,
                    symbol: liveVoiceStatusSymbol
                )

                Text(liveVoiceStatusText)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(AppVisualTheme.foreground(0.45))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isLiveVoicePanelCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isLiveVoicePanelCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.4))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    isLiveVoicePanelCollapsed ? "Expand voice controls" : "Collapse voice controls")
            }

            // Expanded controls
            if !isLiveVoicePanelCollapsed {
                HStack(spacing: 8) {
                    if let transcriptStatus = liveVoiceTranscriptStatusText {
                        Text(transcriptStatus)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(AppVisualTheme.foreground(0.34))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if assistant.isLiveVoiceSessionActive {
                        if assistant.liveVoiceSessionSnapshot.isSpeaking {
                            Button("Stop") {
                                assistant.stopSpeakingAndResumeListening()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }

                        Button("End") {
                            assistant.endLiveVoiceSession()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .foregroundStyle(.red.opacity(0.8))
                    } else {
                        Button(
                            assistant.liveVoiceSessionSnapshot.phase == .paused
                                ? "Resume"
                                : "Start"
                        ) {
                            assistant.startLiveVoiceSession()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(!assistant.canStartLiveVoiceSession)
                    }
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.5)
                )
        )
    }

    private func topBarTextActionButton(title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint.opacity(0.96))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(0.18), lineWidth: 0.55)
                    )
            )
    }

    @ViewBuilder
    private func composerToolbarGroup<Content: View>(@ViewBuilder content: () -> Content)
        -> some View
    {
        HStack(spacing: 6) {
            content()
        }
    }

    @ViewBuilder
    private func composerStatusBanner<Accessory: View>(
        symbol: String,
        text: String,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.9))

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.64))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(tint.opacity(0.12), lineWidth: 0.6)
                )
        )
    }

    @ViewBuilder
    private func historyBranchBanner(
        branch: AssistantHistoryBranchState,
        bannerText: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: historyBranchBannerSymbol(for: branch.kind))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppVisualTheme.accentTint.opacity(0.92))
                .frame(width: 20, height: 20)
                .scaleEffect(historyBranchBannerPulse ? 1.03 : 0.98)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(historyBranchCompactSummary(for: branch))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.90))
                    .lineLimit(1)

                Text(historyBranchCompactDetail(for: branch, bannerText: bannerText))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.52))
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            if branch.canRedo {
                historyBranchActionButton(
                    title: historyBranchCompactActionTitle(for: branch),
                    symbol: "arrow.uturn.forward"
                ) {
                    Task { await assistant.redoUndoneUserMessage() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    AppVisualTheme.surfaceFill(0.085)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppVisualTheme.accentTint.opacity(
                                        historyBranchBannerPulse ? 0.06 : 0.02),
                                    Color.clear,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.12), lineWidth: 0.75)
                )
        )
        .shadow(color: Color.black.opacity(0.07), radius: 10, x: 0, y: 3)
        .scaleEffect(historyBranchBannerSettled ? 1 : 0.994)
        .opacity(historyBranchBannerSettled ? 1 : 0.84)
        .offset(y: historyBranchBannerSettled ? 0 : -2)
        .onAppear {
            triggerHistoryBranchBannerEntrance()
            if !historyBranchBannerPulse {
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    historyBranchBannerPulse = true
                }
            }
        }
        .onChange(of: branch.currentAnchorID) { _ in
            triggerHistoryBranchBannerEntrance()
        }
        .onChange(of: branch.futureStates.first?.id) { _ in
            triggerHistoryBranchBannerEntrance()
        }
        .onDisappear {
            historyBranchBannerPulse = false
        }
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity
            )
        )
    }

    private func historyBranchBannerSymbol(
        for kind: AssistantHistoryMutationKind
    ) -> String {
        switch kind {
        case .undo, .checkpoint:
            return "arrow.uturn.backward.circle.fill"
        case .edit:
            return "pencil.circle.fill"
        }
    }

    private func historyBranchCompactSummary(
        for branch: AssistantHistoryBranchState
    ) -> String {
        switch branch.kind {
        case .undo:
            return "Last message restored"
        case .edit:
            return "Message ready to edit"
        case .checkpoint:
            return "Code rewind ready"
        }
    }

    private func historyBranchCompactDetail(
        for branch: AssistantHistoryBranchState,
        bannerText: String
    ) -> String {
        switch branch.kind {
        case .undo:
            return "Edit below and send"
        case .edit:
            return "Update below and send"
        case .checkpoint:
            return "Review the restored request below"
        }
    }

    private func historyBranchCompactActionTitle(
        for branch: AssistantHistoryBranchState
    ) -> String {
        switch branch.kind {
        case .undo, .checkpoint:
            return "Redo original"
        case .edit:
            return "Restore original"
        }
    }

    private func historyBranchBannerTitle(
        for kind: AssistantHistoryMutationKind
    ) -> String {
        switch kind {
        case .undo:
            return "Message Rewind"
        case .edit:
            return "Message Edit"
        case .checkpoint:
            return "Code Rewind"
        }
    }

    private func historyBranchActionButton(
        title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .bold))

                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(AppVisualTheme.foreground(0.96))
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .background(
                Capsule(style: .continuous)
                    .fill(AppVisualTheme.accentTint.opacity(0.12))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(AppVisualTheme.surfaceStroke(0.10), lineWidth: 0.65)
                    )
            )
        }
        .buttonStyle(.plain)
        .shadow(color: AppVisualTheme.accentTint.opacity(0.05), radius: 4, x: 0, y: 1)
    }

    private func triggerHistoryBranchBannerEntrance() {
        historyBranchBannerSettled = false
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                historyBranchBannerSettled = true
            }
        }
    }

    @ViewBuilder
    private func modeSwitchSuggestionButtons(_ suggestion: AssistantModeSwitchSuggestion)
        -> some View
    {
        HStack(spacing: 6) {
            ForEach(suggestion.choices) { choice in
                Button(choice.title) {
                    Task { await assistant.applyModeSwitchSuggestion(choice) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.92))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            AppVisualTheme.accentTint.opacity(
                                suggestion.source == .blocked ? 0.24 : 0.18)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(AppVisualTheme.surfaceStroke(0.10), lineWidth: 0.5)
                        )
                )
            }
        }
    }

    private func providerBrandColor(for backend: AssistantRuntimeBackend) -> Color {
        Color(red: backend.brandHue.red, green: backend.brandHue.green, blue: backend.brandHue.blue)
    }

    private func providerPickerStatus(
        for backend: AssistantRuntimeBackend
    ) -> (
        title: String,
        color: Color,
        detail: String?,
        requiresSetup: Bool,
        canSelect: Bool
    ) {
        let guidance = assistant.guidance(for: backend)
        let canSelect = assistant.selectableAssistantBackends.contains(backend)
        let isSelected = backend == assistant.visibleAssistantBackend
        let availableModels =
            isSelected
            ? assistant.visibleModels
            : assistant.selectionSideAssistantVisibleModels(for: backend)
        let runtimeState = assistant.runtimeControlsState(
            for: backend,
            availableModels: availableModels,
            isLoadingModels: isSelected ? assistant.isLoadingModels : false,
            isBusy: isSelected ? assistant.hasActiveTurn : false
        )

        let readyColor = Color.green.opacity(0.92)
        let workingColor = Color.orange.opacity(0.92)
        let actionColor = providerBrandColor(for: backend).opacity(0.92)
        let guidanceDetail = guidance.primaryDetail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty

        if isSelected {
            switch runtimeState.availability {
            case .ready:
                return ("Ready", readyColor, nil, false, true)
            case .busy:
                return (
                    "Working",
                    workingColor,
                    assistant.runtimeHealth.summary
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .assistantNonEmpty,
                    false,
                    true
                )
            case .switchingProvider, .loadingModels:
                return (
                    "Loading",
                    workingColor,
                    runtimeState.statusText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .assistantNonEmpty,
                    false,
                    false
                )
            case .unavailable:
                if !guidance.codexDetected {
                    return ("Install", actionColor, guidanceDetail, true, false)
                }
                if backend == .ollamaLocal {
                    return (
                        "Choose Model",
                        actionColor,
                        assistant.runtimeHealth.detail?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .assistantNonEmpty
                            ?? guidanceDetail,
                        true,
                        canSelect
                    )
                }
                return (
                    "Sign In",
                    actionColor,
                    assistant.runtimeHealth.detail?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .assistantNonEmpty
                        ?? backend.signInPromptSummary,
                    true,
                    canSelect
                )
            }
        }

        if !guidance.codexDetected {
            return ("Install", actionColor, guidanceDetail, true, false)
        }

        if backend == .ollamaLocal && availableModels.isEmpty {
            return ("Choose Model", actionColor, guidanceDetail, true, canSelect)
        }

        if backend.requiresLogin && availableModels.isEmpty {
            return ("Sign In", actionColor, backend.signInPromptSummary, true, canSelect)
        }

        return ("Ready", readyColor, nil, false, canSelect)
    }

    private func openSetupForProvider(_ backend: AssistantRuntimeBackend) {
        let guidance = assistant.guidance(for: backend)
        if !guidance.codexDetected || backend == .ollamaLocal {
            assistant.runPreferredInstallCommand(for: backend)
            return
        }

        Task { @MainActor in
            if assistant.visibleAssistantBackend != backend {
                _ = await assistant.switchAssistantBackend(backend)
            }
            assistant.runLoginCommand()
        }
    }

    private func handleProviderPickerSelection(_ backend: AssistantRuntimeBackend) {
        let status = providerPickerStatus(for: backend)
        let isSelected = backend == assistant.visibleAssistantBackend

        dismissTopBarDropdowns()

        if status.requiresSetup {
            openSetupForProvider(backend)
            return
        }

        guard !isSelected else { return }
        guard status.canSelect else { return }
        guard !assistant.isSelectedSessionBackendPinned else { return }
        assistant.selectAssistantBackend(backend)
    }

    private func dismissTopBarDropdowns() {
        withAnimation(.none) {
            showProviderPicker = false
            showWorkspaceLaunchMenu = false
            hoveredProviderOptionID = nil
            hoveredWorkspaceLaunchTargetID = nil
            isWorkspaceLaunchChevronHovered = false
        }
    }

    private func toggleProviderPicker() {
        withAnimation(.none) {
            showWorkspaceLaunchMenu = false
            showProviderPicker.toggle()
        }
    }

    private func toggleWorkspaceLaunchMenu() {
        withAnimation(.none) {
            showProviderPicker = false
            showWorkspaceLaunchMenu.toggle()
        }
    }

    private func topBarDropdownPanelBackground(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let topGlow =
            AppVisualTheme.isDarkAppearance
            ? Color.white.opacity(0.045)
            : Color.white.opacity(0.18)
        let bottomShade =
            AppVisualTheme.isDarkAppearance
            ? Color.black.opacity(0.14)
            : Color.black.opacity(0.05)

        return
            shape
            .fill(AssistantWindowChrome.elevatedPanel.opacity(0.985))
            .overlay {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                topGlow,
                                Color.clear,
                                bottomShade,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay {
                shape
                    .stroke(AssistantWindowChrome.strongBorder.opacity(0.78), lineWidth: 0.8)
            }
            .shadow(color: Color.black.opacity(0.30), radius: 24, x: 0, y: 14)
            .compositingGroup()
    }

    private var topBarProviderDropdown: some View {
        let selected = assistant.visibleAssistantBackend
        let brandColor = providerBrandColor(for: selected)
        let isPinned = assistant.isSelectedSessionBackendPinned
        let isHighlighted = isProviderSelectorHovered || showProviderPicker

        return Button {
            toggleProviderPicker()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(brandColor.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .shadow(color: brandColor.opacity(0.34), radius: 4, x: 0, y: 0)

                Text(selected.shortDisplayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(isHighlighted ? 0.98 : 0.94))

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(isHighlighted ? 0.74 : 0.54))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(AssistantWindowChrome.elevatedPanel.opacity(isHighlighted ? 0.99 : 0.96))
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(brandColor.opacity(isHighlighted ? 0.16 : 0.10))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(brandColor.opacity(isHighlighted ? 0.34 : 0.24), lineWidth: 0.7)
                    )
                    .shadow(
                        color: Color.black.opacity(isHighlighted ? 0.18 : 0.12),
                        radius: isHighlighted ? 10 : 8, x: 0, y: 4)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering in
            isProviderSelectorHovered = hovering
        }
        .help(
            isPinned
                ? "This thread is locked to \(selected.shortDisplayName). You can still open this menu to set up other providers."
                : "Switch providers or finish provider setup here."
        )
        .overlay(alignment: .topLeading) {
            if showProviderPicker {
                providerPickerDropdownOverlay
                    .offset(y: 32)
                    .zIndex(40)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selected)
        .animation(.easeInOut(duration: 0.14), value: isHighlighted)
    }

    private var providerPickerDropdownOverlay: some View {
        let selected = assistant.visibleAssistantBackend

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(AssistantRuntimeBackend.allCases, id: \.self) { backend in
                let backendColor = providerBrandColor(for: backend)
                let status = providerPickerStatus(for: backend)
                let isActive = backend == selected
                let isHovered = hoveredProviderOptionID == backend.rawValue
                let isHighlighted = isActive || isHovered
                let isTemporarilyLocked =
                    assistant.isSelectedSessionBackendPinned
                    && backend != selected
                    && !status.requiresSetup
                Button {
                    handleProviderPickerSelection(backend)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(backendColor.opacity(0.9))
                                .frame(width: 5, height: 5)

                            Text(backend.shortDisplayName)
                                .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                                .foregroundStyle(
                                    AppVisualTheme.foreground(isHighlighted ? 0.95 : 0.84)
                                )

                            Spacer(minLength: 0)

                            Text(status.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(status.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(status.color.opacity(isActive ? 0.18 : 0.12))
                                )

                            if isActive {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(backendColor.opacity(0.8))
                            }
                        }

                        if let detail = status.detail {
                            Text(detail)
                                .font(.system(size: 10.5, weight: .regular))
                                .foregroundStyle(AppVisualTheme.foreground(0.60))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 13)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                isActive
                                    ? backendColor.opacity(0.14)
                                    : (isHovered ? AppVisualTheme.foreground(0.07) : .clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(
                                        isHovered && !isActive
                                            ? AppVisualTheme.surfaceStroke(0.10)
                                            : .clear,
                                        lineWidth: 0.6
                                    )
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isTemporarilyLocked ? 0.58 : 1)
                .onHover { hovering in
                    hoveredProviderOptionID =
                        hovering
                        ? backend.rawValue
                        : (hoveredProviderOptionID == backend.rawValue
                            ? nil : hoveredProviderOptionID)
                }
            }

            Divider()
                .overlay(AppVisualTheme.surfaceStroke(0.08))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)

            Text(
                assistant.isSelectedSessionBackendPinned
                    ? "This thread is locked to \(selected.shortDisplayName). Install and sign-in actions still work here, but switching providers requires a new thread."
                    : "Click a provider to switch. Install, sign in, and local model setup all happen from this menu."
            )
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(AppVisualTheme.foreground(0.58))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .padding(6)
        .frame(width: 280)
        .background(
            topBarDropdownPanelBackground(cornerRadius: 10)
        )
        .compositingGroup()
        .onExitCommand { dismissTopBarDropdowns() }
    }

    private var compactRuntimeProviderPicker: some View {
        let helpText = assistant.selectedSessionBackendHelpText?.assistantNonEmpty
        let picker = HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(assistant.selectableAssistantBackends, id: \.self) { backend in
                    compactRuntimeProviderButton(for: backend)
                }
            }
            .padding(2)
            .background(
                Capsule(style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.04))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(AppVisualTheme.surfaceStroke(0.07), lineWidth: 0.55)
                    )
            )
            .opacity(assistant.isSelectedSessionBackendPinned ? 0.72 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .animation(
            .spring(response: 0.22, dampingFraction: 0.86), value: assistant.visibleAssistantBackend
        )
        .animation(.easeInOut(duration: 0.18), value: assistant.isSelectedSessionBackendPinned)

        return Group {
            if let helpText {
                picker.help(helpText)
            } else {
                picker
            }
        }
    }

    private func compactRuntimeProviderButton(
        for backend: AssistantRuntimeBackend
    ) -> some View {
        let isSelected = backend == assistant.visibleAssistantBackend
        let selectedTint = AppVisualTheme.accentTint

        return Button {
            assistant.selectAssistantBackend(backend)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isSelected ? selectedTint.opacity(0.9) : AppVisualTheme.foreground(0.20))
                    .frame(width: 4, height: 4)
                    .shadow(
                        color: isSelected ? selectedTint.opacity(0.22) : .clear,
                        radius: 4,
                        x: 0,
                        y: 0
                    )

                Text(backend.shortDisplayName)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(
                        isSelected
                            ? AppVisualTheme.foreground(0.9)
                            : AppVisualTheme.foreground(0.42)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? AppVisualTheme.surfaceFill(0.10) : .clear)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                isSelected
                                    ? selectedTint.opacity(0.16)
                                    : AppVisualTheme.surfaceStroke(0.0),
                                lineWidth: 0.55
                            )
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(assistant.isSelectedSessionBackendPinned)
    }

    private var supportedEfforts: [AssistantReasoningEffort] {
        guard let selectedModel = assistant.selectedModel else {
            return AssistantReasoningEffort.allCases
        }
        let efforts = selectedModel.supportedReasoningEfforts.compactMap {
            AssistantReasoningEffort(rawValue: $0)
        }
        if efforts.isEmpty, assistant.visibleAssistantBackend == .copilot {
            return [assistant.reasoningEffort]
        }
        return efforts.isEmpty ? AssistantReasoningEffort.allCases : efforts
    }

    private var reasoningSelectionDisabled: Bool {
        guard let selectedModel = assistant.selectedModel else { return true }
        return assistant.visibleAssistantBackend == .copilot
            && selectedModel.supportedReasoningEfforts.isEmpty
    }

    private var runtimeDotColor: Color {
        switch assistant.runtimeHealth.availability {
        case .ready, .active: return .green
        case .checking, .connecting: return .orange
        case .failed: return .red
        default: return .gray
        }
    }

    private var chatWebRuntimePanel: AssistantChatWebRuntimePanel? {
        let detail = assistant.runtimeHealth.detail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        let filteredDetail: String?
        if let detail, !detail.lowercased().contains("failed to load rollout") {
            filteredDetail = detail
        } else {
            filteredDetail = nil
        }

        return AssistantChatWebRuntimePanel(
            tone: runtimePanelTone,
            statusSummary: assistant.runtimeHealth.summary,
            statusDetail: filteredDetail,
            accountSummary: assistant.accountSnapshot.isLoggedIn
                ? assistant.accountSnapshot.summary : nil,
            backendHelpText: assistant.selectedSessionBackendHelpText,
            backends: assistant.selectableAssistantBackends.map { backend in
                AssistantChatWebRuntimeBackendOption(
                    id: backend.rawValue,
                    label: backend.shortDisplayName,
                    isSelected: backend == assistant.visibleAssistantBackend,
                    isDisabled: assistant.isSelectedSessionBackendPinned
                )
            },
            setupButtonTitle: canChat ? nil : "Open Setup"
        )
    }

    private var runtimePanelTone: String {
        switch assistant.runtimeHealth.availability {
        case .ready, .active:
            return "ready"
        case .checking, .connecting:
            return "connecting"
        case .failed:
            return "failed"
        default:
            return "idle"
        }
    }

    private var runtimeIndicatorColor: Color {
        switch assistant.runtimeHealth.availability {
        case .ready, .active:
            return Color.green.opacity(0.92)
        case .checking, .connecting:
            return Color.orange.opacity(0.92)
        case .failed:
            return Color.red.opacity(0.92)
        default:
            return AppVisualTheme.foreground(0.42)
        }
    }

    private func permissionCard(
        _ request: AssistantPermissionRequest, state: AssistantPermissionCardState
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(state.cardTitle)
                    .font(.headline)
                Spacer()
                AssistantStatusBadge(title: state.badgeTitle, tint: permissionBadgeTint(for: state))
            }

            Text(request.toolTitle)
                .font(.callout.weight(.semibold))
            if let rationale = request.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.caption)
                    .foregroundStyle(AppVisualTheme.mutedText)
            }

            if let summary = request.displayRawPayloadSummary {
                Text(summary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(AppVisualTheme.mutedText)
                    .lineLimit(4)
            }

            switch state {
            case .waitingForInput where request.isStructuredApprovalPrompt:
                AssistantStructuredApprovalView(
                    accent: .orange,
                    secondaryText: AppVisualTheme.mutedText,
                    approveTitle: "Approve",
                    rejectTitle: "Reject",
                    cancelTitle: "Cancel Request"
                ) {
                    Task {
                        await assistant.resolvePermission(
                            answers: request.structuredApprovalAnswers(approved: true)
                        )
                    }
                } onReject: {
                    Task {
                        await assistant.resolvePermission(
                            answers: request.structuredApprovalAnswers(approved: false)
                        )
                    }
                } onCancel: {
                    Task { await assistant.cancelPermissionRequest() }
                }

            case .waitingForInput where request.hasStructuredUserInput:
                AssistantStructuredUserInputView(
                    request: request,
                    accent: .orange,
                    secondaryText: AppVisualTheme.mutedText,
                    fieldBackground: AppVisualTheme.foreground(0.04),
                    submitTitle: "Submit Answers",
                    cancelTitle: "Cancel Request"
                ) { answers in
                    Task { await assistant.resolvePermission(answers: answers) }
                } onCancel: {
                    Task { await assistant.cancelPermissionRequest() }
                }

            case .waitingForApproval, .waitingForInput:
                ForEach(request.options) { option in
                    if option.isDefault {
                        Button(option.title) {
                            Task { await assistant.resolvePermission(optionID: option.id) }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(option.title) {
                            Task { await assistant.resolvePermission(optionID: option.id) }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let toolKind = request.toolKind, !toolKind.isEmpty, toolKind != "modeSwitch",
                    toolKind != "userInput", toolKind != "browserLogin"
                {
                    Button("Always Allow") {
                        assistant.alwaysAllowToolKind(toolKind)
                        let sessionOption =
                            request.options.first(where: { $0.id == "acceptForSession" })
                            ?? request.options.first(where: { $0.isDefault })
                        if let optionID = sessionOption?.id {
                            Task { await assistant.resolvePermission(optionID: optionID) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }

                Button("Cancel Request") {
                    Task { await assistant.cancelPermissionRequest() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            case .completed:
                Text(
                    "This approval prompt is part of the session history. It only means the request flow finished, not that the tool succeeded."
                )
                .font(.caption)
                .foregroundStyle(AppVisualTheme.mutedText)

            case .notActive:
                Text("This request is no longer active in the live session.")
                    .font(.caption)
                    .foregroundStyle(AppVisualTheme.mutedText)
            }
        }
        .padding(16)
        .appThemedSurface(
            cornerRadius: 10,
            tint: permissionSurfaceTint(for: state),
            strokeOpacity: 0.16,
            tintOpacity: 0.045
        )
    }

    private func permissionBadgeTint(for state: AssistantPermissionCardState) -> Color {
        switch state {
        case .waitingForApproval, .waitingForInput:
            return .orange
        case .completed:
            return AppVisualTheme.foreground(0.45)
        case .notActive:
            return AppVisualTheme.foreground(0.45)
        }
    }

    private func permissionSurfaceTint(for state: AssistantPermissionCardState) -> Color {
        switch state {
        case .waitingForApproval, .waitingForInput:
            return .orange
        case .completed:
            return .green
        case .notActive:
            return AppVisualTheme.primaryText
        }
    }

    private func proposedPlanCard(_ plan: String, isStreaming: Bool, showsActions: Bool)
        -> some View
    {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.55))
                Text("Proposed Plan")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.94))
                Spacer()
                if showsActions {
                    Button {
                        assistant.dismissPlan()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppVisualTheme.foreground(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                AssistantMarkdownText(
                    contentID:
                        "proposed-plan-\(assistant.selectedSessionID ?? "session")-\(plan.hashValue)",
                    text: plan,
                    role: .assistant,
                    isStreaming: isStreaming,
                    selectionMessageID: "proposed-plan-\(assistant.selectedSessionID ?? "session")",
                    selectionMessageText: plan,
                    selectionTracker: selectionTracker
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)

            if plan.count > 400 {
                Text("Scroll to view the full plan")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.3))
            }

            HStack(spacing: 10) {
                Button {
                    copyAssistantTextToPasteboard(plan)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Copy Plan")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(AppVisualTheme.foreground(0.86))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppVisualTheme.surfaceFill(0.08))
                    )
                }
                .buttonStyle(.plain)

                if showsActions {
                    Button {
                        Task { await assistant.executePlan() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Execute Plan")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(AppVisualTheme.primaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(AppVisualTheme.accentTint)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(assistant.hasActiveTurn)
                    .opacity(assistant.hasActiveTurn ? 0.55 : 1.0)

                    Button {
                        assistant.dismissPlan()
                    } label: {
                        Text("Dismiss")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            if assistant.hasActiveTurn && showsActions {
                Text("Wait for the plan to finish before executing it.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.45))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.5)
                )
        )
    }

    private func badgeTint(for availability: AssistantRuntimeAvailability) -> Color {
        switch availability {
        case .ready, .active:
            return .green
        case .checking, .connecting:
            return AppVisualTheme.accentTint
        case .installRequired, .loginRequired:
            return .orange
        case .failed:
            return .red
        case .idle, .unavailable:
            return .secondary
        }
    }

    private func refreshEverything(refreshPermissions: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let permissions = refreshPermissions ? currentPermissionSnapshot() : assistant.permissions
        await assistant.refreshEnvironment(permissions: permissions)
        await assistant.refreshSessions()
    }

    private func currentPermissionSnapshot() -> AssistantPermissionSnapshot {
        let snapshot = PermissionCenter.snapshot(using: settings)
        return AssistantPermissionSnapshot(
            accessibility: snapshot.accessibilityGranted ? .granted : .missing,
            screenRecording: snapshot.screenRecordingGranted ? .granted : .missing,
            microphone: snapshot.microphoneGranted ? .granted : .missing,
            speechRecognition: snapshot.speechRecognitionGranted
                || !snapshot.speechRecognitionRequired ? .granted : .missing,
            appleEvents: snapshot.appleEventsKnown
                ? (snapshot.appleEventsGranted ? .granted : .missing)
                : .unknown,
            fullDiskAccess: snapshot.fullDiskAccessKnown
                ? (snapshot.fullDiskAccessGranted ? .granted : .missing)
                : .unknown
        )
    }

    private func scrollToLatestMessage(with proxy: ScrollViewProxy, animated: Bool = true) {
        guard canScrollToLatestVisibleContent else {
            pendingScrollToLatestWorkItem?.cancel()
            return
        }
        pendingScrollToLatestWorkItem?.cancel()
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem {
            guard let workItem, !workItem.isCancelled else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
        }
        guard let workItem else { return }
        pendingScrollToLatestWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    // MARK: - Attachments

    private func threadSkillChip(_ state: AssistantThreadSkillState) -> some View {
        AssistantThreadSkillChip(
            state: state,
            onRemove: {
                assistant.detachSkill(state.skillName)
            },
            onRepair: {
                assistant.repairMissingSkillBindings()
                guard prepareToLeaveCurrentNoteScreen(reason: "open Skills") else { return }
                selectedSidebarPane = .skills
            }
        )
    }

    private func attachmentChip(_ attachment: AssistantAttachment) -> some View {
        HStack(spacing: 8) {
            if attachment.isImage, let nsImage = NSImage(data: attachment.data) {
                Button {
                    previewAttachment = attachment
                } label: {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppVisualTheme.accentTint.opacity(0.16))
                        .frame(width: 24, height: 24)
                    Image(systemName: "doc.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.accentTint.opacity(0.95))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.76))
                    .lineLimit(1)
                Text(attachment.isImage ? "Image attachment" : "File attachment")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.42))
            }
            Button {
                assistant.attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.45))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(AppVisualTheme.surfaceFill(0.06))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.07), lineWidth: 0.6)
                )
        )
    }

    private func openFilePicker() {
        AssistantAttachmentSupport.openFilePicker { attachments in
            guard !attachments.isEmpty else { return }
            assistant.attachments.append(contentsOf: attachments)
        }
    }

    private func openImagePicker() {
        AssistantAttachmentSupport.openFilePicker(
            allowedContentTypes: AssistantAttachmentSupport.imageContentTypes
        ) { attachments in
            guard !attachments.isEmpty else { return }
            assistant.attachments.append(contentsOf: attachments)
        }
    }

    private func captureComposerScreenshotAttachment() {
        Task { @MainActor in
            guard CGPreflightScreenCaptureAccess() else {
                presentComposerScreenshotAlert(
                    messageText: "Allow Screen Recording",
                    informativeText:
                        "Grant Screen Recording in macOS Settings so Open Assist can capture a screenshot for chat."
                )
                return
            }

            do {
                guard let data = try await captureInteractiveScreenshotData() else {
                    return
                }

                assistant.attachments.append(
                    AssistantAttachment(
                        filename: composerScreenshotAttachmentFilename(),
                        data: data,
                        mimeType: "image/png"
                    )
                )
            } catch {
                presentComposerScreenshotAlert(
                    messageText: "Could not capture screenshot",
                    informativeText:
                        "Open Assist could not capture that screenshot. \(error.localizedDescription)"
                )
            }
        }
    }

    private func composerScreenshotAttachmentFilename() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Screenshot-\(formatter.string(from: Date())).png"
    }

    private func presentComposerScreenshotAlert(
        messageText: String,
        informativeText: String
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openSkillFolderImportPanel() {
        let panel = NSOpenPanel()
        panel.prompt = "Import Skill"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose the folder that contains SKILL.md."

        if panel.runModal() == .OK, let url = panel.url {
            assistant.importSkill(fromFolderURL: url)
        }
    }

    private func confirmDeleteSkill(_ skill: AssistantSkillDescriptor) {
        let alert = NSAlert()
        alert.messageText = "Delete skill?"
        alert.informativeText =
            "This removes “\(skill.displayName)” from ~/.codex/skills. Thread bindings will stay, but they will show as missing."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            assistant.deleteSkill(skill)
        }
    }

    private func navigateBackFromSkillsPane() {
        selectedSidebarPane = lastNonSkillsSidebarPane
    }

    private func navigateBackFromPluginsPane() {
        selectedSidebarPane = lastNonSkillsSidebarPane
    }

    private func trySkillFromLibrary(_ skill: AssistantSkillDescriptor, prompt: String) {
        Task { @MainActor in
            // Always start a fresh thread so the user's current conversation is preserved.
            await assistant.startNewSession()

            if assistant.canAttachSkillsToSelectedThread,
                !assistant.isSkillAttachedToSelectedThread(skill)
            {
                assistant.attachSkill(skill)
            }

            assistant.promptDraft = prompt
            selectedSidebarPane = .threads
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        AssistantAttachmentSupport.handleDrop(providers) { attachment in
            assistant.attachments.append(attachment)
        }
    }
}

// MARK: - Collapsible Image Attachments

private struct CollapsibleImageAttachments: View {
    let imageAttachments: [Data]
    let maxWidth: CGFloat
    let maxHeight: CGFloat

    @State private var isExpanded = false

    private var label: String {
        imageAttachments.count == 1
            ? "Show screenshot" : "Show \(imageAttachments.count) screenshots"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.40))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isExpanded)
                        .frame(width: 10)

                    Image(systemName: "photo")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.40))

                    Text(label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.50))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(Array(imageAttachments.enumerated()), id: \.offset) { _, imageData in
                    if let nsImage = NSImage(data: imageData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.5)
                            )
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
    }
}
