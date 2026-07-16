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
        summaryMaxChars: Int,
        longTermScope: MemoryScopeContext? = nil,
        projectContextBlock: String? = nil,
        statusBase: String? = nil,
        additionalLongTermEntries: [AssistantMemoryEntry] = []
    ) throws -> AssistantBuiltMemoryContext {
        let threadScope = makeScopeContext(threadID: threadID, cwd: cwd)
        let scope = longTermScope ?? threadScope
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
        let mergedLongTermEntries: [AssistantMemoryEntry]
        let longTermScopeIdentityKey = longTermScope?.identityKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let threadScopeIdentityKey = threadScope.identityKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let longTermScope,
           longTermScopeIdentityKey != nil,
           longTermScopeIdentityKey != threadScopeIdentityKey {
            let threadLongTermEntries = try fetchRankedLongTermEntries(
                prompt: prompt,
                threadID: threadID,
                scope: threadScope
            )
            let scopedLongTermEntries = try fetchRankedLongTermEntries(
                prompt: prompt,
                threadID: threadID,
                scope: longTermScope
            )
            let combined = mergeLongTermEntries(
                primary: threadLongTermEntries,
                additional: scopedLongTermEntries
            )
            mergedLongTermEntries = mergeLongTermEntries(
                primary: combined,
                additional: additionalLongTermEntries
            )
        } else {
            let longTermEntries = try fetchRankedLongTermEntries(
                prompt: prompt,
                threadID: threadID,
                scope: scope
            )
            mergedLongTermEntries = mergeLongTermEntries(
                primary: longTermEntries,
                additional: additionalLongTermEntries
            )
        }

        let summary = buildSummary(
            document: resolvedChange.document,
            longTermEntries: mergedLongTermEntries,
            agentStateLines: agentStateLines,
            projectContextBlock: projectContextBlock,
            maxChars: summaryMaxChars
        )

        let statusMessage: String?
        if didReset {
            statusMessage = "Memory reset for new task"
        } else if resolvedChange.didChangeExternally {
            statusMessage = "Using updated session memory"
        } else if summary?.isEmpty == false {
            statusMessage = statusBase?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? (longTermScope == nil ? "Using session memory" : "Using automation memory")
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
        let exactThreadIDFilter = scope.identityType == "assistant-project" ? nil : threadID
        var candidates = try store.fetchAssistantMemoryEntries(
            query: prompt,
            provider: .codex,
            scopeKey: scope.scopeKey,
            projectKey: scope.projectKey,
            identityKey: scope.identityKey,
            threadID: exactThreadIDFilter,
            state: .active,
            limit: 40
        )

        if let projectKey = scope.projectKey,
           candidates.count < 10 {
            let projectMatches = try store.fetchAssistantMemoryEntries(
                query: prompt,
                provider: .codex,
                projectKey: projectKey,
                state: .active,
                limit: 40
            )
            for candidate in projectMatches where !candidates.contains(where: { $0.id == candidate.id }) {
                candidates.append(candidate)
            }
        }

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
        projectContextBlock: String?,
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
        if let projectContextBlock = projectContextBlock?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            sections.append(projectContextBlock)
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

    private func mergeLongTermEntries(
        primary: [AssistantMemoryEntry],
        additional: [AssistantMemoryEntry]
    ) -> [AssistantMemoryEntry] {
        guard !additional.isEmpty else { return primary }

        var merged = primary
        var existingIDs = Set(primary.map(\.id))
        for entry in additional where !existingIDs.contains(entry.id) {
            merged.append(entry)
            existingIDs.insert(entry.id)
        }
        return merged
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

    func makeScopeContext(
        threadID: String,
        cwd: String?,
        projectIdentityKey: String? = nil,
        projectNameOverride: String? = nil,
        repositoryNameOverride: String? = nil
    ) -> MemoryScopeContext {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.developingadventures.OpenAssist"
        let normalizedCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let inferredProjectName = normalizedCWD.flatMap { path -> String? in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return last.isEmpty || last == "/" ? nil : last
        }
        let projectName = projectNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? inferredProjectName
        let projectKey = projectIdentityKey?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? projectName.map {
                "project:" + MemoryTextNormalizer.collapsedWhitespace($0).lowercased()
            }
        let repositoryName = repositoryNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? inferredProjectName
        let identityKey = projectIdentityKey?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "assistant-session:\(threadID.lowercased())"
        let identityType = projectIdentityKey == nil ? "assistant-session" : "assistant-project"
        return MemoryScopeContext(
            appName: "Open Assist",
            bundleID: bundleID,
            surfaceLabel: "Assistant",
            projectKey: projectKey,
            projectName: projectName,
            repositoryName: repositoryName,
            identityKey: identityKey,
            identityType: identityType,
            identityLabel: projectName ?? (projectIdentityKey == nil ? "Assistant Session" : "Assistant Project"),
            isCodingContext: projectKey != nil || repositoryName != nil
        )
    }
}
