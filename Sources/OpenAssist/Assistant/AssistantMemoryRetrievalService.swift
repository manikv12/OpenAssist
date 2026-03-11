import Foundation

final class AssistantMemoryRetrievalService {
    private let store: MemorySQLiteStore
    private let threadMemoryService: AssistantThreadMemoryService

    init(
        store: MemorySQLiteStore? = nil,
        threadMemoryService: AssistantThreadMemoryService = AssistantThreadMemoryService()
    ) {
        self.store = store ?? (try? MemorySQLiteStore()) ?? MemorySQLiteStore.fallback()
        self.threadMemoryService = threadMemoryService
    }

    func prepareTurnContext(
        threadID: String,
        prompt: String,
        cwd: String?,
        summaryMaxChars: Int
    ) throws -> AssistantBuiltMemoryContext {
        let scope = makeScopeContext(threadID: threadID, cwd: cwd)
        let initialChange = try threadMemoryService.loadTrackedDocument(for: threadID, seedTask: prompt)

        let resolvedChange: AssistantThreadMemoryChange
        let didReset: Bool
        if threadMemoryService.shouldSoftReset(document: initialChange.document, nextPrompt: prompt) {
            resolvedChange = try threadMemoryService.softReset(
                for: threadID,
                reason: "New task or retry detected before the next turn.",
                nextTask: prompt
            )
            didReset = true
        } else {
            var updatedDocument = initialChange.document
            if updatedDocument.currentTask.isEmpty {
                updatedDocument.currentTask = AssistantThreadMemoryDocument.normalizedTask(prompt)
            }
            let savedURL = try threadMemoryService.saveDocument(updatedDocument, for: threadID)
            resolvedChange = AssistantThreadMemoryChange(
                document: updatedDocument,
                fileURL: savedURL,
                didChangeExternally: initialChange.didChangeExternally
            )
            didReset = false
        }

        let agentStateLines = try fetchAssistantAgentStateLines(threadID: threadID)
        let longTermEntries = try fetchRankedLongTermEntries(
            prompt: prompt,
            threadID: threadID,
            scope: scope
        )

        let summary = buildSummary(
            document: resolvedChange.document,
            longTermEntries: longTermEntries,
            agentStateLines: agentStateLines,
            maxChars: summaryMaxChars
        )

        let statusMessage: String?
        if didReset {
            statusMessage = "Memory reset for new task"
        } else if resolvedChange.didChangeExternally {
            statusMessage = "Using updated session memory"
        } else if summary?.isEmpty == false {
            statusMessage = "Using session memory"
        } else {
            statusMessage = nil
        }

        return AssistantBuiltMemoryContext(
            summary: summary,
            statusMessage: statusMessage,
            fileURL: resolvedChange.fileURL,
            fileChangedExternally: resolvedChange.didChangeExternally,
            resetPerformed: didReset,
            scope: scope
        )
    }

    func currentMemoryFileURL(for threadID: String?) -> URL? {
        guard let threadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines), !threadID.isEmpty else {
            return nil
        }
        return threadMemoryService.memoryFileIfExists(for: threadID)
    }

    private func fetchAssistantAgentStateLines(threadID: String) throws -> [String] {
        var lines: [String] = []

        if let profile = try store.fetchConversationAgentProfile(threadID: threadID)?.profileJSON.nonEmpty {
            let summary = MemoryTextNormalizer.normalizedSummary(profile, limit: 180)
            if !summary.isEmpty {
                lines.append("Profile: \(summary)")
            }
        }

        if let entities = try store.fetchConversationAgentEntities(threadID: threadID)?.entitiesJSON.nonEmpty {
            let summary = MemoryTextNormalizer.normalizedSummary(entities, limit: 180)
            if !summary.isEmpty {
                lines.append("Entities: \(summary)")
            }
        }

        if let preferences = try store.fetchConversationAgentPreferences(threadID: threadID)?.preferencesJSON.nonEmpty {
            let summary = MemoryTextNormalizer.normalizedSummary(preferences, limit: 180)
            if !summary.isEmpty {
                lines.append("Stored preferences: \(summary)")
            }
        }

        return lines
    }

    private func fetchRankedLongTermEntries(
        prompt: String,
        threadID: String,
        scope: MemoryScopeContext
    ) throws -> [AssistantMemoryEntry] {
        let promptKeywords = Set(MemoryTextNormalizer.keywords(from: prompt, limit: 18))
        var candidates = try store.fetchAssistantMemoryEntries(
            query: prompt,
            provider: .codex,
            scopeKey: scope.scopeKey,
            projectKey: scope.projectKey,
            identityKey: scope.identityKey,
            threadID: threadID,
            state: .active,
            limit: 40
        )

        if candidates.count < 10 {
            let broadMatches = try store.fetchAssistantMemoryEntries(
                query: prompt,
                provider: .codex,
                state: .active,
                limit: 40
            )
            for candidate in broadMatches where !candidates.contains(where: { $0.id == candidate.id }) {
                candidates.append(candidate)
            }
        }

        return candidates
            .sorted { lhs, rhs in
                let leftScore = relevanceScore(
                    for: lhs,
                    scope: scope,
                    threadID: threadID,
                    promptKeywords: promptKeywords
                )
                let rightScore = relevanceScore(
                    for: rhs,
                    scope: scope,
                    threadID: threadID,
                    promptKeywords: promptKeywords
                )
                if leftScore == rightScore {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return leftScore > rightScore
            }
            .prefix(6)
            .map { $0 }
    }

    private func buildSummary(
        document: AssistantThreadMemoryDocument,
        longTermEntries: [AssistantMemoryEntry],
        agentStateLines: [String],
        maxChars: Int
    ) -> String? {
        var sections: [String] = []

        if !document.currentTask.isEmpty {
            sections.append("Current task: \(document.currentTask)")
        }
        if !document.activeFacts.isEmpty {
            sections.append("Active facts:\n" + document.activeFacts.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !document.importantReferences.isEmpty {
            sections.append("Important names/files/services:\n" + document.importantReferences.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !document.sessionPreferences.isEmpty {
            sections.append("Session preferences:\n" + document.sessionPreferences.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !agentStateLines.isEmpty {
            sections.append("Assistant state:\n" + agentStateLines.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !longTermEntries.isEmpty {
            let lessons = longTermEntries.map { entry in
                "- [\(entry.memoryType.label)] \(entry.summary)"
            }
            sections.append("Long-term lessons:\n" + lessons.joined(separator: "\n"))
        }

        guard !sections.isEmpty else { return nil }
        let raw = """
        # Session Memory
        Use this as context for the next reply. Follow stable rules, but prefer the latest user instruction if they conflict.

        \(sections.joined(separator: "\n\n"))
        """

        let normalizedLimit = max(400, maxChars)
        if raw.count <= normalizedLimit {
            return raw
        }

        let shortened = MemoryTextNormalizer.normalizedSummary(raw, limit: normalizedLimit)
        guard !shortened.isEmpty else { return nil }
        return """
        # Session Memory
        \(shortened)
        """
    }

    private func relevanceScore(
        for entry: AssistantMemoryEntry,
        scope: MemoryScopeContext,
        threadID: String,
        promptKeywords: Set<String>
    ) -> Double {
        var score = entry.confidence

        if entry.scopeKey == scope.scopeKey {
            score += 8
        } else if entry.projectKey == scope.projectKey, entry.projectKey != nil {
            score += 4
        } else if entry.threadID == threadID {
            score += 3
        }

        let keywordOverlap = Set(entry.keywords.map { $0.lowercased() }).intersection(promptKeywords).count
        score += Double(keywordOverlap)
        return score
    }

    func makeScopeContext(threadID: String, cwd: String?) -> MemoryScopeContext {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.developingadventures.OpenAssist"
        let normalizedCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectName = normalizedCWD.flatMap { path -> String? in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return last.isEmpty || last == "/" ? nil : last
        }
        let projectKey = projectName.map {
            "project:" + MemoryTextNormalizer.collapsedWhitespace($0).lowercased()
        }
        let identityKey = "assistant-session:\(threadID.lowercased())"
        return MemoryScopeContext(
            appName: "Open Assist",
            bundleID: bundleID,
            surfaceLabel: "Assistant",
            projectKey: projectKey,
            projectName: projectName,
            repositoryName: projectName,
            identityKey: identityKey,
            identityType: "assistant-session",
            identityLabel: projectName ?? "Assistant Session",
            isCodingContext: projectName != nil
        )
    }
}
