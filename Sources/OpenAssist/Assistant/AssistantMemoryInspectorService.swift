import Foundation

enum AssistantMemoryInspectorTarget: Equatable, Sendable {
    case thread(String)
    case project(String)

    var id: String {
        switch self {
        case .thread(let threadID):
            return "thread:\(threadID.lowercased())"
        case .project(let projectID):
            return "project:\(projectID.lowercased())"
        }
    }
}

struct AssistantMemoryInspectorSnapshot: Sendable {
    enum Kind: Sendable, Equatable {
        case thread
        case project
    }

    let target: AssistantMemoryInspectorTarget
    let kind: Kind
    let title: String
    let subtitle: String?
    let linkedFolderPath: String?
    let memoryFileURL: URL?
    let threadDocument: AssistantThreadMemoryDocument?
    let projectSummary: String?
    let threadDigests: [AssistantProjectThreadDigest]
    let threadActiveEntries: [AssistantMemoryEntry]
    let threadInvalidatedEntries: [AssistantMemoryEntry]
    let projectActiveEntries: [AssistantMemoryEntry]
    let projectInvalidatedEntries: [AssistantMemoryEntry]
    let pendingSuggestions: [AssistantMemorySuggestion]
}

final class AssistantMemoryInspectorService {
    private let projectStore: AssistantProjectStore
    private let projectMemoryService: AssistantProjectMemoryService
    private let threadMemoryService: AssistantThreadMemoryService
    private let memoryRetrievalService: AssistantMemoryRetrievalService
    private let memorySuggestionService: AssistantMemorySuggestionService
    private let memoryStore: MemorySQLiteStore

    init(
        projectStore: AssistantProjectStore,
        projectMemoryService: AssistantProjectMemoryService,
        threadMemoryService: AssistantThreadMemoryService,
        memoryRetrievalService: AssistantMemoryRetrievalService,
        memorySuggestionService: AssistantMemorySuggestionService,
        memoryStore: MemorySQLiteStore
    ) {
        self.projectStore = projectStore
        self.projectMemoryService = projectMemoryService
        self.threadMemoryService = threadMemoryService
        self.memoryRetrievalService = memoryRetrievalService
        self.memorySuggestionService = memorySuggestionService
        self.memoryStore = memoryStore
    }

    func snapshot(for session: AssistantSessionSummary) throws -> AssistantMemoryInspectorSnapshot {
        let threadTarget = AssistantMemoryInspectorTarget.thread(session.id)
        let resolvedCWD = session.effectiveCWD ?? session.cwd
        let threadScope = memoryRetrievalService.makeScopeContext(
            threadID: session.id,
            cwd: resolvedCWD
        )
        let threadMemoryFileURL = threadMemoryService.memoryFileIfExists(for: session.id)
        let threadDocument = try loadThreadDocumentIfExists(from: threadMemoryFileURL)
        let threadActiveEntries = try fetchEntries(
            scope: threadScope,
            threadID: session.id,
            state: .active
        )
        let threadInvalidatedEntries = try fetchEntries(
            scope: threadScope,
            threadID: session.id,
            state: .invalidated
        )

        let projectContext = projectStore.context(forThreadID: session.id)
        let projectActiveEntries: [AssistantMemoryEntry]
        let projectInvalidatedEntries: [AssistantMemoryEntry]
        let projectSummary: String?
        let linkedFolderPath: String?

        if let project = projectContext?.project {
            let projectScope = projectMemoryService.projectScopeContext(
                for: project,
                cwd: project.linkedFolderPath ?? resolvedCWD
            )
            projectActiveEntries = try fetchEntries(scope: projectScope, state: .active)
            projectInvalidatedEntries = try fetchEntries(scope: projectScope, state: .invalidated)
            projectSummary = projectContext?.brainState.projectSummary
            linkedFolderPath = project.linkedFolderPath
        } else {
            projectActiveEntries = []
            projectInvalidatedEntries = []
            projectSummary = nil
            linkedFolderPath = nil
        }

        return AssistantMemoryInspectorSnapshot(
            target: threadTarget,
            kind: .thread,
            title: session.title,
            subtitle: session.projectName ?? session.effectiveCWD ?? session.cwd,
            linkedFolderPath: linkedFolderPath,
            memoryFileURL: threadMemoryFileURL,
            threadDocument: threadDocument,
            projectSummary: projectSummary,
            threadDigests: [],
            threadActiveEntries: threadActiveEntries,
            threadInvalidatedEntries: threadInvalidatedEntries,
            projectActiveEntries: projectActiveEntries,
            projectInvalidatedEntries: projectInvalidatedEntries,
            pendingSuggestions: try memorySuggestionService.suggestions(for: session.id)
        )
    }

    func snapshot(
        for project: AssistantProject,
        sessions: [AssistantSessionSummary]
    ) throws -> AssistantMemoryInspectorSnapshot {
        let projectTarget = AssistantMemoryInspectorTarget.project(project.id)
        let projectScope = projectMemoryService.projectScopeContext(
            for: project,
            cwd: project.linkedFolderPath
        )
        let projectActiveEntries = try fetchEntries(scope: projectScope, state: .active)
        let projectInvalidatedEntries = try fetchEntries(scope: projectScope, state: .invalidated)
        let projectThreadIDs = Set(
            sessions.compactMap { session in
                session.projectID?.caseInsensitiveCompare(project.id) == .orderedSame ? session.id.lowercased() : nil
            }
        )
        let brain = projectStore.brainState(forProjectID: project.id)
        let projectSuggestions = try memorySuggestionService.suggestions().filter { suggestion in
            if let projectKey = suggestion.projectKey,
               let scopeProjectKey = projectScope.projectKey,
               projectKey.caseInsensitiveCompare(scopeProjectKey) == .orderedSame {
                return true
            }
            if let identityKey = suggestion.identityKey,
               let scopeIdentityKey = projectScope.identityKey,
               identityKey.caseInsensitiveCompare(scopeIdentityKey) == .orderedSame {
                return true
            }
            if let projectID = suggestion.metadata["project_id"],
               projectID.caseInsensitiveCompare(project.id) == .orderedSame {
                return true
            }
            return projectThreadIDs.contains(suggestion.threadID.lowercased())
        }

        let sortedDigests = brain.threadDigestsByThreadID.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.threadTitle.localizedCaseInsensitiveCompare(rhs.threadTitle) == .orderedAscending
        }

        return AssistantMemoryInspectorSnapshot(
            target: projectTarget,
            kind: .project,
            title: project.name,
            subtitle: "\(projectThreadIDs.count) thread\(projectThreadIDs.count == 1 ? "" : "s")",
            linkedFolderPath: project.linkedFolderPath,
            memoryFileURL: nil,
            threadDocument: nil,
            projectSummary: brain.projectSummary,
            threadDigests: sortedDigests,
            threadActiveEntries: [],
            threadInvalidatedEntries: [],
            projectActiveEntries: projectActiveEntries,
            projectInvalidatedEntries: projectInvalidatedEntries,
            pendingSuggestions: projectSuggestions.sorted(by: { $0.createdAt > $1.createdAt })
        )
    }

    private func loadThreadDocumentIfExists(from fileURL: URL?) throws -> AssistantThreadMemoryDocument? {
        guard let fileURL else { return nil }
        let markdown = try String(contentsOf: fileURL, encoding: .utf8)
        return AssistantThreadMemoryDocument.parse(markdown: markdown)
    }

    private func fetchEntries(
        scope: MemoryScopeContext,
        threadID: String? = nil,
        state: AssistantMemoryEntryState
    ) throws -> [AssistantMemoryEntry] {
        try memoryStore.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            scopeKey: scope.scopeKey,
            projectKey: scope.projectKey,
            identityKey: scope.identityKey,
            threadID: threadID,
            state: state,
            limit: 200
        ).sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.confidence > rhs.confidence
        }
    }
}
