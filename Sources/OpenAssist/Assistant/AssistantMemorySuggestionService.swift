import Foundation

final class AssistantMemorySuggestionService {
    private let fileManager: FileManager
    private let threadMemoryService: AssistantThreadMemoryService
    private let store: MemorySQLiteStore
    private let suggestionsFileURL: URL
    private var cachedSuggestions: [AssistantMemorySuggestion]?

    init(
        fileManager: FileManager = .default,
        threadMemoryService: AssistantThreadMemoryService = AssistantThreadMemoryService(),
        store: MemorySQLiteStore? = nil
    ) {
        self.fileManager = fileManager
        self.threadMemoryService = threadMemoryService
        self.store = store ?? (try? MemorySQLiteStore()) ?? MemorySQLiteStore.fallback()
        self.suggestionsFileURL = threadMemoryService.rootDirectoryURL
            .appendingPathComponent("pending-suggestions.json", isDirectory: false)
    }

    func suggestions(for threadID: String? = nil) throws -> [AssistantMemorySuggestion] {
        let all = try loadSuggestions()
        guard let threadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines), !threadID.isEmpty else {
            return all.sorted(by: { $0.createdAt > $1.createdAt })
        }
        return all
            .filter { $0.threadID.caseInsensitiveCompare(threadID) == .orderedSame }
            .sorted(by: { $0.createdAt > $1.createdAt })
    }

    @discardableResult
    func createManualSuggestions(
        from assistantText: String,
        threadID: String,
        scope: MemoryScopeContext,
        metadata extraMetadata: [String: String] = [:]
    ) throws -> [AssistantMemorySuggestion] {
        let lessons = distilledLessons(from: assistantText, fallbackKind: .manualSave)
        return try persistSuggestions(
            lessons.map {
                makeSuggestion(
                    threadID: threadID,
                    scope: scope,
                    kind: .manualSave,
                    detail: $0,
                    sourceExcerpt: assistantText,
                    metadata: extraMetadata
                )
            }
        )
    }

    @discardableResult
    func createFailureSuggestions(
        from assistantText: String,
        threadID: String,
        scope: MemoryScopeContext,
        metadata extraMetadata: [String: String] = [:]
    ) throws -> [AssistantMemorySuggestion] {
        let lessons = failureLessons(from: assistantText)
        return try persistSuggestions(
            lessons.map {
                makeSuggestion(
                    threadID: threadID,
                    scope: scope,
                    kind: .reviewedFailure,
                    detail: $0,
                    sourceExcerpt: assistantText,
                    metadata: extraMetadata
                )
            }
        )
    }

    @discardableResult
    func createAutomaticFailureSuggestions(
        from assistantText: String,
        toolCount: Int,
        threadID: String,
        scope: MemoryScopeContext,
        metadata extraMetadata: [String: String] = [:]
    ) throws -> [AssistantMemorySuggestion] {
        let lessons = automaticFailureLessons(from: assistantText, toolCount: toolCount)
        return try persistSuggestions(
            lessons.map {
                makeSuggestion(
                    threadID: threadID,
                    scope: scope,
                    kind: .reviewedFailure,
                    detail: $0,
                    sourceExcerpt: assistantText,
                    metadata: extraMetadata
                )
            }
        )
    }

    @discardableResult
    func createStaleLessonSuggestion(
        target: AssistantMemoryEntry,
        threadID: String,
        scope: MemoryScopeContext,
        reason: String,
        sourceExcerpt: String?
    ) throws -> [AssistantMemorySuggestion] {
        guard target.state == .active else { return [] }
        guard target.metadata["memory_domain"]?.lowercased() == "assistant" else { return [] }

        let detail = """
        Review whether this saved project lesson is still correct.

        Current lesson:
        \(target.detail)

        Why it may be stale:
        \(MemoryTextNormalizer.normalizedBody(reason))
        """
        let metadata: [String: String] = [
            "memory_domain": "assistant",
            "target_memory_id": target.id.uuidString,
            "action": "invalidate",
            "lesson_key": target.metadata["lesson_key"] ?? normalizedDuplicateKey(target.summary),
            "invalidation_reason": MemoryTextNormalizer.normalizedSummary(reason, limit: 240)
        ]

        let suggestion = makeSuggestion(
            threadID: threadID,
            scope: scope,
            kind: .staleLesson,
            detail: detail,
            sourceExcerpt: sourceExcerpt ?? target.summary,
            metadata: metadata,
            titleOverride: "Review stale project memory",
            summaryOverride: "Review whether this project memory is stale: \(target.summary)"
        )
        return try persistSuggestions([suggestion])
    }

    func acceptSuggestion(id: UUID) throws {
        guard let suggestion = try loadSuggestions().first(where: { $0.id == id }) else {
            return
        }
        if suggestion.kind == .staleLesson,
           let targetMemoryID = suggestion.metadata["target_memory_id"].flatMap(UUID.init(uuidString:)) {
            try store.invalidateAssistantMemoryEntry(
                id: targetMemoryID,
                reason: suggestion.metadata["invalidation_reason"] ?? suggestion.detail
            )
        } else if try !containsExistingLongTermDuplicate(for: suggestion) {
            try invalidateConflictingActiveEntries(for: suggestion)
            try store.upsertAssistantMemoryEntry(suggestion.asEntry(updatedAt: Date()))
        }
        try threadMemoryService.removeCandidateLesson(suggestion.summary, for: suggestion.threadID)
        try removeSuggestions(ids: [id])
    }

    func ignoreSuggestion(id: UUID) throws {
        guard let suggestion = try loadSuggestions().first(where: { $0.id == id }) else {
            return
        }
        try threadMemoryService.removeCandidateLesson(suggestion.summary, for: suggestion.threadID)
        try removeSuggestions(ids: [id])
    }

    func clearSuggestions(for threadID: String) throws {
        let suggestionsToRemove = try loadSuggestions()
            .filter { $0.threadID.caseInsensitiveCompare(threadID) == .orderedSame }
            .map(\.id)
        try removeSuggestions(ids: suggestionsToRemove)
    }

    func purgeHistoryArtifacts(
        for threadID: String,
        sourceTurnAnchorIDs: Set<String>
    ) throws -> (removedSuggestions: [AssistantMemorySuggestion], removedEntries: [AssistantMemoryEntry]) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty, !sourceTurnAnchorIDs.isEmpty else {
            return ([], [])
        }

        let normalizedAnchorIDs = Set(sourceTurnAnchorIDs.map { $0.lowercased() })
        let allSuggestions = try loadSuggestions()
        let removedSuggestions = allSuggestions.filter {
            $0.threadID.caseInsensitiveCompare(normalizedThreadID) == .orderedSame
                && normalizedAnchorIDs.contains(($0.metadata["source_turn_anchor_id"] ?? "").lowercased())
        }

        if !removedSuggestions.isEmpty {
            for suggestion in removedSuggestions {
                try threadMemoryService.removeCandidateLesson(suggestion.summary, for: suggestion.threadID)
            }
            try saveSuggestions(
                allSuggestions.filter { candidate in
                    !removedSuggestions.contains(where: { $0.id == candidate.id })
                }
            )
        }

        let removedEntries = try store.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            threadID: normalizedThreadID,
            state: nil,
            limit: 1000
        ).filter {
            normalizedAnchorIDs.contains(($0.metadata["source_turn_anchor_id"] ?? "").lowercased())
        }

        if !removedEntries.isEmpty {
            try store.deleteAssistantMemoryEntries(ids: removedEntries.map(\.id))
        }

        return (removedSuggestions, removedEntries)
    }

    func restoreHistoryArtifacts(
        suggestions: [AssistantMemorySuggestion],
        acceptedEntries: [AssistantMemoryEntry]
    ) throws {
        guard !suggestions.isEmpty || !acceptedEntries.isEmpty else { return }

        if !suggestions.isEmpty {
            let existingSuggestions = try loadSuggestions()
            var merged = existingSuggestions
            let existingIDs = Set(existingSuggestions.map(\.id))
            for suggestion in suggestions where !existingIDs.contains(suggestion.id) {
                merged.insert(suggestion, at: 0)
                try threadMemoryService.addCandidateLesson(suggestion.summary, for: suggestion.threadID)
            }
            try saveSuggestions(merged)
        }

        for entry in acceptedEntries {
            try store.upsertAssistantMemoryEntry(entry)
        }
    }

    private func persistSuggestions(_ suggestions: [AssistantMemorySuggestion]) throws -> [AssistantMemorySuggestion] {
        guard !suggestions.isEmpty else { return [] }

        var existing = try loadSuggestions()
        var inserted: [AssistantMemorySuggestion] = []

        for suggestion in suggestions {
            let duplicateInQueue = existing.contains {
                $0.threadID.caseInsensitiveCompare(suggestion.threadID) == .orderedSame
                    && $0.summary.caseInsensitiveCompare(suggestion.summary) == .orderedSame
            }
            let duplicateInStore = try containsExistingLongTermDuplicate(for: suggestion)
            guard !duplicateInQueue, !duplicateInStore else { continue }
            existing.insert(suggestion, at: 0)
            inserted.append(suggestion)
            try threadMemoryService.addCandidateLesson(suggestion.summary, for: suggestion.threadID)
        }

        try saveSuggestions(existing)
        return inserted
    }

    private func removeSuggestions(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let filtered = try loadSuggestions().filter { !idSet.contains($0.id) }
        try saveSuggestions(filtered)
    }

    private func loadSuggestions() throws -> [AssistantMemorySuggestion] {
        if let cachedSuggestions {
            return cachedSuggestions
        }

        guard fileManager.fileExists(atPath: suggestionsFileURL.path) else {
            cachedSuggestions = []
            return []
        }

        let data = try Data(contentsOf: suggestionsFileURL)
        let decoded = try JSONDecoder().decode([AssistantMemorySuggestion].self, from: data)
        cachedSuggestions = decoded
        return decoded
    }

    private func saveSuggestions(_ suggestions: [AssistantMemorySuggestion]) throws {
        let directory = suggestionsFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(suggestions)
        try data.write(to: suggestionsFileURL, options: .atomic)
        cachedSuggestions = suggestions
    }

    private func makeSuggestion(
        threadID: String,
        scope: MemoryScopeContext,
        kind: AssistantMemorySuggestionKind,
        detail: String,
        sourceExcerpt: String?,
        metadata extraMetadata: [String: String] = [:],
        titleOverride: String? = nil,
        summaryOverride: String? = nil
    ) -> AssistantMemorySuggestion {
        let normalizedDetail = MemoryTextNormalizer.normalizedBody(detail)
        let summary = summaryOverride.flatMap {
            MemoryTextNormalizer.normalizedSummary($0, limit: 180).nonEmpty
        } ?? MemoryTextNormalizer.normalizedSummary(normalizedDetail, limit: 180)
        let title = titleOverride.flatMap {
            MemoryTextNormalizer.normalizedTitle($0, fallback: "Assistant Memory").nonEmpty
        } ?? MemoryTextNormalizer.normalizedTitle(summary, fallback: "Assistant Memory")
        let keywords = MemoryTextNormalizer.keywords(from: normalizedDetail, limit: 12)
        var metadata = extraMetadata
        metadata["memory_domain"] = "assistant"
        metadata["surface_label"] = scope.surfaceLabel
        metadata["scope_key"] = scope.scopeKey
        metadata["lesson_key"] = metadata["lesson_key"] ?? normalizedDuplicateKey(summary)

        return AssistantMemorySuggestion(
            threadID: threadID,
            kind: kind,
            memoryType: .lesson,
            title: title,
            summary: summary,
            detail: normalizedDetail,
            scopeKey: scope.scopeKey,
            bundleID: scope.bundleID,
            projectKey: scope.projectKey,
            identityKey: scope.identityKey,
            keywords: keywords,
            confidence: kind == .reviewedFailure ? 0.76 : (kind == .staleLesson ? 0.72 : 0.66),
            sourceExcerpt: sourceExcerpt.flatMap { MemoryTextNormalizer.normalizedSummary($0, limit: 280).nonEmpty },
            metadata: metadata
        )
    }

    private func distilledLessons(
        from assistantText: String,
        fallbackKind: AssistantMemorySuggestionKind
    ) -> [String] {
        let sentences = assistantText
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { MemoryTextNormalizer.collapsedWhitespace($0) }
            .filter { !$0.isEmpty }

        let rulePrefixes = [
            "if ", "when ", "prefer ", "use ", "avoid ", "do not ",
            "don't ", "always ", "check "
        ]

        var results = sentences.filter { sentence in
            let lower = sentence.lowercased()
            return rulePrefixes.contains(where: { lower.hasPrefix($0) })
                && !looksTemporary(sentence)
        }

        if results.isEmpty && fallbackKind == .manualSave {
            let fallback = MemoryTextNormalizer.normalizedSummary(assistantText, limit: 220)
            if !fallback.isEmpty && !looksTemporary(fallback) {
                results = [fallback]
            }
        }

        return Array(results.prefix(3))
    }

    private func automaticFailureLessons(from assistantText: String, toolCount: Int) -> [String] {
        let lower = assistantText.lowercased()
        let progressVerbCount = countMatches(
            pattern: "\\b(checking|trying|switching|looking|opening|reading|found|next|now|inspecting|confirming)\\b",
            in: lower
        )
        let firstPersonCount = countMatches(
            pattern: "\\b(i'm|i am|i'll|i will)\\b",
            in: lower
        )
        let sentenceCount = assistantText
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { MemoryTextNormalizer.collapsedWhitespace($0) }
            .filter { !$0.isEmpty }
            .count

        let hasBrowserAutomationBlock = lower.contains("brave")
            && lower.contains("apple events")
            && lower.contains("javascript")
        let hasDetourSignal = containsDetourSignal(in: lower)
        let hasPermissionSignal = lower.contains("permission")
            || lower.contains("approve")
            || lower.contains("user input")

        let narrationHeavy = progressVerbCount >= 6
            && firstPersonCount >= 3
            && (assistantText.count >= 700 || sentenceCount >= 6)
        let toolHeavyNarration = toolCount >= 18 && progressVerbCount >= 4

        var lessons: [String] = []
        if narrationHeavy || toolHeavyNarration {
            lessons.append("For simple requests, keep updates short and move to the answer faster instead of narrating every step.")
        }
        if hasBrowserAutomationBlock && progressVerbCount >= 3 {
            lessons.append("For browser tasks in Brave, check whether 'Allow JavaScript from Apple Events' is enabled before relying on page scripting.")
        }
        if hasDetourSignal && ((progressVerbCount >= 4 && toolCount >= 8) || progressVerbCount >= 6) {
            lessons.append("When the current path looks blocked, ask earlier instead of trying many detours.")
        }
        if hasPermissionSignal && (progressVerbCount >= 4 || toolCount >= 14) {
            lessons.append("Ask for missing permission or user input earlier, before spending many tool calls on uncertain workarounds.")
        }

        return Array(lessons.prefix(3))
    }

    private func failureLessons(from assistantText: String) -> [String] {
        let lower = assistantText.lowercased()
        var lessons: [String] = []

        let progressVerbCount = countMatches(
            pattern: "\\b(checking|trying|switching|looking|opening|reading|found|next|now)\\b",
            in: lower
        )
        if progressVerbCount >= 5 || assistantText.count > 800 {
            lessons.append("For simple requests, keep updates short and move to the answer faster instead of narrating every step.")
        }
        if lower.contains("brave") && lower.contains("apple events") && lower.contains("javascript") {
            lessons.append("For browser tasks in Brave, check whether 'Allow JavaScript from Apple Events' is enabled before relying on page scripting.")
        }
        if lower.contains("switching") || lower.contains("detour") || progressVerbCount >= 7 {
            lessons.append("When the current path looks blocked, ask earlier instead of trying many detours.")
        }
        if lower.contains("permission") && progressVerbCount >= 4 {
            lessons.append("Ask for missing permission or user input earlier, before spending many tool calls on uncertain workarounds.")
        }

        if lessons.isEmpty {
            lessons.append("When a task starts to loop or stall, ask earlier for the best next step instead of continuing with low-confidence retries.")
        }
        return Array(lessons.prefix(3))
    }

    private func containsExistingLongTermDuplicate(for suggestion: AssistantMemorySuggestion) throws -> Bool {
        let threadIDFilter = shouldUseThreadFilter(for: suggestion) ? suggestion.threadID : nil
        let matches = try store.fetchAssistantMemoryEntries(
            query: suggestion.summary,
            provider: .codex,
            scopeKey: suggestion.scopeKey,
            projectKey: suggestion.projectKey,
            identityKey: suggestion.identityKey,
            threadID: threadIDFilter,
            state: .active,
            limit: 50
        )
        let normalizedSummary = normalizedDuplicateKey(suggestion.summary)
        return matches.contains {
            $0.metadata["memory_domain"]?.lowercased() == "assistant"
                && normalizedDuplicateKey($0.summary) == normalizedSummary
        }
    }

    private func invalidateConflictingActiveEntries(for suggestion: AssistantMemorySuggestion) throws {
        guard suggestion.kind != .staleLesson else { return }
        let lessonKey = suggestion.metadata["lesson_key"] ?? normalizedDuplicateKey(suggestion.summary)
        let threadIDFilter = shouldUseThreadFilter(for: suggestion) ? suggestion.threadID : nil
        let matches = try store.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            scopeKey: suggestion.scopeKey,
            projectKey: suggestion.projectKey,
            identityKey: suggestion.identityKey,
            threadID: threadIDFilter,
            state: .active,
            limit: 200
        )

        for match in matches where match.metadata["lesson_key"] == lessonKey {
            try store.invalidateAssistantMemoryEntry(
                id: match.id,
                reason: "Replaced by a newer assistant memory suggestion."
            )
        }
    }

    private func shouldUseThreadFilter(for suggestion: AssistantMemorySuggestion) -> Bool {
        guard let identityKey = suggestion.identityKey?.lowercased() else {
            return true
        }
        return !identityKey.hasPrefix("assistant-project:")
    }

    private func countMatches(pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }

    private func looksTemporary(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        let temporaryMarkers = [
            "today", "tomorrow", "yesterday", "at ", "x.com", "front tab",
            "6:", "7:", "8:", "9:", "10:", "11:", "12:"
        ]
        return temporaryMarkers.contains(where: { lower.contains($0) })
    }

    private func normalizedDuplicateKey(_ value: String) -> String {
        MemoryTextNormalizer.collapsedWhitespace(value).lowercased()
    }

    private func containsDetourSignal(in lowercasedText: String) -> Bool {
        let explicitSignals = [
            "switching to another path",
            "switching to a different path",
            "switching approaches",
            "switching to a fallback",
            "trying another path",
            "trying a different path",
            "trying a workaround",
            "using a workaround",
            "detour",
            "workaround",
            "another path",
            "different path",
            "alternate path",
            "fallback path",
            "low-confidence path"
        ]
        return explicitSignals.contains(where: lowercasedText.contains)
    }
}
