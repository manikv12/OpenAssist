import CryptoKit
import Foundation

struct AssistantProjectCheckpointUpdate: Sendable {
    let didChange: Bool
    let staleSuggestionCount: Int
}

struct AssistantProjectTurnContext: Sendable {
    let project: AssistantProject
    let scope: MemoryScopeContext
    let projectContextBlock: String?
}

final class AssistantProjectMemoryService {
    private let projectStore: AssistantProjectStore
    private let memoryStore: MemorySQLiteStore
    private let memorySuggestionService: AssistantMemorySuggestionService

    init(
        projectStore: AssistantProjectStore,
        memoryStore: MemorySQLiteStore,
        memorySuggestionService: AssistantMemorySuggestionService
    ) {
        self.projectStore = projectStore
        self.memoryStore = memoryStore
        self.memorySuggestionService = memorySuggestionService
    }

    func projectScopeContext(
        for project: AssistantProject,
        cwd: String?
    ) -> MemoryScopeContext {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.developingadventures.OpenAssist"
        let stableProjectKey = "assistant-project:\(project.id.lowercased())"
        let repositoryName = cwd.flatMap { path -> String? in
            let lastComponent = URL(fileURLWithPath: path, isDirectory: true)
                .lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return lastComponent.nonEmpty
        } ?? project.name

        return MemoryScopeContext(
            appName: "Open Assist",
            bundleID: bundleID,
            surfaceLabel: "Assistant Project",
            projectKey: stableProjectKey,
            projectName: project.name,
            repositoryName: repositoryName,
            identityKey: stableProjectKey,
            identityType: "assistant-project",
            identityLabel: project.name,
            isCodingContext: repositoryName.nonEmpty != nil
        )
    }

    func activeLessons(
        for project: AssistantProject,
        cwd: String?
    ) -> [AssistantMemoryEntry] {
        let scope = projectScopeContext(for: project, cwd: cwd)
        return (try? memoryStore.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            scopeKey: scope.scopeKey,
            projectKey: scope.projectKey,
            identityKey: scope.identityKey,
            state: .active,
            limit: 24
        )) ?? []
    }

    func projectSummary(for projectID: String?) -> String? {
        guard let projectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        return projectStore.brainState(forProjectID: projectID).projectSummary
    }

    func turnContext(
        forThreadID threadID: String,
        fallbackCWD: String?,
        prompt: String? = nil
    ) throws -> AssistantProjectTurnContext? {
        guard let context = projectStore.context(forThreadID: threadID) else {
            return nil
        }

        let resolvedCWD = context.project.linkedFolderPath ?? fallbackCWD
        let scope = projectScopeContext(for: context.project, cwd: resolvedCWD)
        return AssistantProjectTurnContext(
            project: context.project,
            scope: scope,
            projectContextBlock: makeProjectContextBlock(
                project: context.project,
                brain: context.brainState,
                currentThreadID: threadID,
                prompt: prompt
            )
        )
    }

    func processCheckpoint(
        session: AssistantSessionSummary,
        transcript: [AssistantTranscriptEntry]
    ) throws -> AssistantProjectCheckpointUpdate {
        guard let context = projectStore.context(forThreadID: session.id) else {
            return AssistantProjectCheckpointUpdate(didChange: false, staleSuggestionCount: 0)
        }
        return try processCheckpoint(
            project: context.project,
            sessionSummary: session,
            transcript: transcript,
            cwd: session.effectiveCWD ?? session.cwd
        )
    }

    func rebuildProjectSummary(
        for projectID: String,
        sessionSummaries: [AssistantSessionSummary]
    ) throws -> String? {
        _ = sessionSummaries
        guard let project = projectStore.project(forProjectID: projectID) else {
            return nil
        }
        let updatedSummary = buildProjectSummary(
            project: project,
            brain: projectStore.brainState(forProjectID: projectID)
        )
        try projectStore.setProjectSummary(updatedSummary, forProjectID: projectID, processedAt: Date())
        return updatedSummary
    }

    func invalidateAllProjectLessons(
        project: AssistantProject,
        fallbackCWD: String?,
        reason: String
    ) throws {
        try invalidateAllLessons(for: project, cwd: fallbackCWD, reason: reason)
    }

    func createFolderChangeStaleSuggestions(
        project: AssistantProject,
        fallbackCWD: String?,
        threadID: String,
        previousFolderPath: String?
    ) throws -> Int {
        guard let previousFolderPath = previousFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return 0
        }

        let scope = projectScopeContext(for: project, cwd: fallbackCWD ?? previousFolderPath)
        let activeEntries = try memoryStore.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            scopeKey: scope.scopeKey,
            projectKey: scope.projectKey,
            identityKey: scope.identityKey,
            state: .active,
            limit: 100
        )

        let matchingEntries = activeEntries.filter {
            $0.metadata["folder_path"]?.caseInsensitiveCompare(previousFolderPath) == .orderedSame
        }
        guard !matchingEntries.isEmpty else { return 0 }

        var createdCount = 0
        let newFolderText = project.linkedFolderPath ?? "no linked folder"
        for entry in matchingEntries {
            let created = try memorySuggestionService.createStaleLessonSuggestion(
                target: entry,
                threadID: threadID,
                scope: scope,
                reason: "The project folder changed from \(previousFolderPath) to \(newFolderText).",
                sourceExcerpt: "Project folder changed from \(previousFolderPath) to \(newFolderText)."
            )
            createdCount += created.count
        }
        return createdCount
    }

    func processCheckpoint(
        project: AssistantProject,
        sessionSummary: AssistantSessionSummary?,
        transcript: [AssistantTranscriptEntry],
        cwd: String?
    ) throws -> AssistantProjectCheckpointUpdate {
        guard let sessionSummary,
              let digest = buildThreadDigest(sessionSummary: sessionSummary, transcript: transcript) else {
            return AssistantProjectCheckpointUpdate(didChange: false, staleSuggestionCount: 0)
        }

        let brain = projectStore.brainState(forProjectID: project.id)
        let existingFingerprint = brain.lastProcessedTranscriptFingerprintByThreadID[sessionSummary.id]
        guard existingFingerprint != digest.fingerprint else {
            return AssistantProjectCheckpointUpdate(didChange: false, staleSuggestionCount: 0)
        }

        let now = Date()
        try projectStore.updateThreadDigest(
            projectID: project.id,
            threadID: sessionSummary.id,
            threadTitle: sessionSummary.title,
            summary: digest.summary,
            fingerprint: digest.fingerprint,
            processedAt: now
        )
        let updatedBrain = projectStore.brainState(forProjectID: project.id)
        let projectSummary = buildProjectSummary(project: project, brain: updatedBrain)
        try projectStore.setProjectSummary(projectSummary, forProjectID: project.id, processedAt: now)

        let staleSuggestionCount = try enqueueStaleLessonSuggestionsIfNeeded(
            project: project,
            threadID: sessionSummary.id,
            digestSummary: digest.summary,
            cwd: cwd
        )

        return AssistantProjectCheckpointUpdate(
            didChange: true,
            staleSuggestionCount: staleSuggestionCount
        )
    }

    func removeThread(
        _ threadID: String,
        fromProjectID projectID: String
    ) throws {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return }
        try projectStore.removeThreadDigest(
            projectID: projectID,
            threadID: normalizedThreadID,
            processedAt: Date()
        )
        if let project = projectStore.project(forProjectID: projectID) {
            let updatedBrain = projectStore.brainState(forProjectID: project.id)
            let updatedSummary = buildProjectSummary(project: project, brain: updatedBrain)
            try projectStore.setProjectSummary(updatedSummary, forProjectID: project.id, processedAt: Date())
        }
    }

    func invalidateAllLessons(
        for project: AssistantProject,
        cwd: String?,
        reason: String
    ) throws {
        let scope = projectScopeContext(for: project, cwd: cwd)
        let activeEntries = try memoryStore.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            scopeKey: scope.scopeKey,
            projectKey: scope.projectKey,
            identityKey: scope.identityKey,
            state: .active,
            limit: 200
        )
        for entry in activeEntries {
            try memoryStore.invalidateAssistantMemoryEntry(
                id: entry.id,
                reason: reason
            )
        }
    }

    private func makeProjectContextBlock(
        project: AssistantProject,
        brain: AssistantProjectBrainState,
        currentThreadID: String,
        prompt: String?
    ) -> String? {
        var lines: [String] = ["Project name: \(project.name)"]

        if let linkedFolderPath = project.linkedFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            lines.append("Linked project folder: \(linkedFolderPath)")
        } else {
            lines.append("Linked project folder: none")
        }

        let relevantDigestLines = relevantProjectDigestLines(
            from: brain,
            excludingThreadID: currentThreadID,
            prompt: prompt
        )
        if !relevantDigestLines.isEmpty {
            lines.append("Relevant project notes:\n" + relevantDigestLines.joined(separator: "\n"))
        }

        guard !lines.isEmpty else { return nil }
        return "Project context:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
    }

    private func relevantProjectDigestLines(
        from brain: AssistantProjectBrainState,
        excludingThreadID currentThreadID: String,
        prompt: String?
    ) -> [String] {
        let promptKeywords = Set(
            projectMemorySignalKeywords(from: prompt, limit: 18)
        )
        guard promptKeywords.count >= 2 else {
            return []
        }
        let minimumOverlap = promptKeywords.count >= 4 ? 2 : 1

        let normalizedCurrentThreadID = currentThreadID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let rankedDigests = brain.threadDigestsByThreadID.values
            .filter { digest in
                digest.threadID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != normalizedCurrentThreadID
            }
            .compactMap { digest -> (digest: AssistantProjectThreadDigest, score: Int)? in
                let digestKeywords = Set(
                    MemoryTextNormalizer.keywords(
                        from: "\(digest.threadTitle)\n\(digest.summary)",
                        limit: 24
                    )
                )
                let overlap = digestKeywords.intersection(promptKeywords).count
                guard overlap >= minimumOverlap else {
                    return nil
                }
                return (digest, overlap)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.digest.updatedAt != rhs.digest.updatedAt {
                    return lhs.digest.updatedAt > rhs.digest.updatedAt
                }
                return lhs.digest.threadTitle.localizedCaseInsensitiveCompare(rhs.digest.threadTitle) == .orderedAscending
            }

        return rankedDigests.prefix(3).map { item in
            "- \(item.digest.threadTitle): \(item.digest.summary)"
        }
    }

    private func projectMemorySignalKeywords(from prompt: String?, limit: Int) -> [String] {
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return []
        }

        return MemoryTextNormalizer.keywords(from: prompt, limit: limit)
            .filter { token in
                token.count >= 4
                    || token.rangeOfCharacter(from: .decimalDigits) != nil
            }
    }

    private func buildThreadDigest(
        sessionSummary: AssistantSessionSummary,
        transcript: [AssistantTranscriptEntry]
    ) -> (summary: String, fingerprint: String)? {
        let meaningfulEntries = transcript
            .filter { entry in
                guard !entry.isStreaming else { return false }
                switch entry.role {
                case .user, .assistant, .error:
                    return entry.text.assistantNonEmpty != nil
                case .system, .status, .tool, .permission:
                    return false
                }
            }
            .suffix(4)

        var lines: [String] = []
        var fingerprintParts: [String] = []

        for entry in meaningfulEntries {
            let normalized = normalizedDigestText(entry.text, limit: 220)
            guard !normalized.isEmpty else { continue }
            lines.append("\(digestRoleLabel(for: entry.role)): \(normalized)")
            fingerprintParts.append("\(entry.role.rawValue)|\(normalized)")
        }

        if lines.isEmpty {
            if let latestUser = sessionSummary.latestUserMessage?.assistantNonEmpty {
                let normalized = normalizedDigestText(latestUser, limit: 220)
                if !normalized.isEmpty {
                    lines.append("User: \(normalized)")
                    fingerprintParts.append("user|\(normalized)")
                }
            }
            if let latestAssistant = sessionSummary.latestAssistantMessage?.assistantNonEmpty {
                let normalized = normalizedDigestText(latestAssistant, limit: 240)
                if !normalized.isEmpty {
                    lines.append("Assistant: \(normalized)")
                    fingerprintParts.append("assistant|\(normalized)")
                }
            } else if let summary = sessionSummary.summary?.assistantNonEmpty {
                let normalized = normalizedDigestText(summary, limit: 240)
                if !normalized.isEmpty {
                    lines.append("Summary: \(normalized)")
                    fingerprintParts.append("summary|\(normalized)")
                }
            }
        }

        guard !lines.isEmpty else { return nil }

        let digestBody = lines.joined(separator: "\n")
        let digest = MemoryTextNormalizer.normalizedSummary(digestBody, limit: 700)
        guard let normalizedDigest = digest.nonEmpty else { return nil }

        let updatedAtText = sessionSummary.updatedAt?.ISO8601Format() ?? ""
        let fingerprintInput = ([sessionSummary.id.lowercased(), sessionSummary.title.lowercased(), updatedAtText] + fingerprintParts)
            .joined(separator: "\n")
        let fingerprint = SHA256.hash(data: Data(fingerprintInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        return (normalizedDigest, fingerprint)
    }

    private func buildProjectSummary(
        project: AssistantProject,
        brain: AssistantProjectBrainState
    ) -> String? {
        let orderedDigests = brain.threadDigestsByThreadID.values
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.threadTitle.localizedCaseInsensitiveCompare(rhs.threadTitle) == .orderedAscending
            }

        guard !orderedDigests.isEmpty else { return nil }

        var sections: [String] = [
            "Project: \(project.name)"
        ]

        if let linkedFolderPath = project.linkedFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            sections.append("Linked folder: \(linkedFolderPath)")
        }

        let digestLines = orderedDigests.prefix(6).map { digest in
            "- \(digest.threadTitle): \(digest.summary)"
        }
        sections.append("Recent thread digests:\n" + digestLines.joined(separator: "\n"))

        let raw = sections.joined(separator: "\n\n")
        return MemoryTextNormalizer.normalizedSummary(raw, limit: 1_400).nonEmpty
    }

    private func enqueueStaleLessonSuggestionsIfNeeded(
        project: AssistantProject,
        threadID: String,
        digestSummary: String,
        cwd: String?
    ) throws -> Int {
        let normalizedDigest = digestSummary.lowercased()
        let changeSignals = [
            "migrated",
            "moved to",
            "now uses",
            "no longer",
            "instead of",
            "switched to",
            "replaced",
            "changed to"
        ]
        guard changeSignals.contains(where: { normalizedDigest.contains($0) }) else {
            return 0
        }

        let scope = projectScopeContext(for: project, cwd: cwd)
        let activeEntries = try memoryStore.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            scopeKey: scope.scopeKey,
            projectKey: scope.projectKey,
            identityKey: scope.identityKey,
            state: .active,
            limit: 48
        )

        let digestKeywords = Set(MemoryTextNormalizer.keywords(from: digestSummary, limit: 16))
        var createdCount = 0
        for entry in activeEntries {
            let overlap = Set(entry.keywords.map { $0.lowercased() }).intersection(digestKeywords).count
            guard overlap >= 2 else { continue }
            let created = try memorySuggestionService.createStaleLessonSuggestion(
                target: entry,
                threadID: threadID,
                scope: scope,
                reason: "A newer thread checkpoint may conflict with this saved lesson.",
                sourceExcerpt: digestSummary
            )
            createdCount += created.count
        }

        return createdCount
    }

    private func normalizedDigestText(_ text: String, limit: Int) -> String {
        MemoryTextNormalizer.normalizedSummary(text, limit: limit)
    }

    private func digestRoleLabel(for role: AssistantTranscriptRole) -> String {
        switch role {
        case .user:
            return "User"
        case .assistant:
            return "Assistant"
        case .error:
            return "Error"
        case .system:
            return "System"
        case .status:
            return "Status"
        case .tool:
            return "Tool"
        case .permission:
            return "Permission"
        }
    }
}
