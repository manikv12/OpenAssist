import Foundation

@inline(__always)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct MemoryIndexingSmokeTests {
    static func main() async {
        do {
            let sandboxRoot = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: sandboxRoot) }

            let discoveryService = MemoryProviderDiscoveryService(homeURL: sandboxRoot, fileManager: .default)
            let discovery = discoveryService.discover()

            check(!discovery.providers.isEmpty, "Expected provider discovery to find at least one provider")
            check(
                discovery.providers.contains(where: { $0.kind == .codex }),
                "Expected codex provider to be discovered"
            )
            check(
                discovery.providers.contains(where: { $0.kind == .opencode }),
                "Expected opencode provider to be discovered"
            )

            try await runNonAIFallbackScenario(discovery: discovery, sandboxRoot: sandboxRoot)
            try await runAIBackedScenario(discovery: discovery, sandboxRoot: sandboxRoot)
            try await runPatternAndRetentionScenario(sandboxRoot: sandboxRoot)

            print("PASS: Memory indexing smoke tests passed")
        } catch {
            fputs("FAIL: Memory indexing smoke test threw error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func runNonAIFallbackScenario(
        discovery: MemoryProviderDiscoveryResult,
        sandboxRoot: URL
    ) async throws {
        let store = try MemorySQLiteStore(databaseURL: makeDatabaseURL(sandboxRoot, fileName: "memory-non-ai.sqlite3"))
        let indexingService = MemoryIndexingService(
            fileManager: .default,
            adapterRegistry: MemorySourceAdapterRegistry(),
            rewriteProvider: NonAIMemoryRewriteProvider(),
            maxFilesPerSource: 100,
            maxEventsPerFile: 50,
            apiThrottleDelay: 0
        )

        let report = await indexingService.indexSources(discovery.sources, store: store)
        check(report.indexedFiles > 0, "Expected non-AI pass to parse at least one source file")
        check(report.indexedEvents == 0, "Expected non-AI fallback to avoid indexing memory events")
        check(report.indexedCards == 0, "Expected non-AI fallback to avoid indexing memory cards")
        check(report.indexedLessons == 0, "Expected non-AI fallback to avoid indexing lessons")
        check(report.indexedRewriteSuggestions == 0, "Expected non-AI fallback to avoid rewrite suggestions")

        let cards = try store.fetchCardsForRewrite(
            query: "",
            options: MemoryRewriteLookupOptions(provider: nil, includePlanContent: false, limit: 20)
        )
        check(cards.isEmpty, "Expected no persisted cards when only non-AI fallback provider is used")

        let lessons = try store.fetchLessonsForRewrite(
            query: "",
            provider: nil,
            limit: 20
        )
        check(lessons.isEmpty, "Expected no persisted lessons from non-AI fallback pass")

        let unchangedReindexReport = await indexingService.rebuildIndex(from: discovery.sources, store: store)
        check(
            unchangedReindexReport.indexedFiles == 0,
            "Expected unchanged non-AI rebuild to skip file re-indexing"
        )
        check(
            unchangedReindexReport.skippedFiles > 0,
            "Expected unchanged non-AI rebuild to report skipped files"
        )

        let transitionedAIService = MemoryIndexingService(
            fileManager: .default,
            adapterRegistry: MemorySourceAdapterRegistry(),
            rewriteProvider: MockAILessonRewriteProvider(),
            maxFilesPerSource: 100,
            maxEventsPerFile: 50,
            apiThrottleDelay: 0
        )

        let aiTransitionReport = await transitionedAIService.rebuildIndex(from: discovery.sources, store: store)
        check(
            aiTransitionReport.indexedEvents > 0,
            "Expected enabling AI-backed extraction to index events even when file hashes are unchanged"
        )
        check(
            aiTransitionReport.indexedCards > 0,
            "Expected enabling AI-backed extraction to index cards even when file hashes are unchanged"
        )

        let transitionedSuggestions = try store.fetchRewriteSuggestions(
            query: "teh",
            provider: .codex,
            limit: 10
        )
        check(
            transitionedSuggestions.contains(where: {
                $0.originalText.localizedCaseInsensitiveContains("teh")
                    && $0.suggestedText.localizedCaseInsensitiveContains("the")
            }),
            "Expected AI transition pass to produce rewrite suggestions"
        )
    }

    private static func runAIBackedScenario(
        discovery: MemoryProviderDiscoveryResult,
        sandboxRoot: URL
    ) async throws {
        let store = try MemorySQLiteStore(databaseURL: makeDatabaseURL(sandboxRoot, fileName: "memory-ai.sqlite3"))
        let indexingService = MemoryIndexingService(
            fileManager: .default,
            adapterRegistry: MemorySourceAdapterRegistry(),
            rewriteProvider: MockAILessonRewriteProvider(),
            maxFilesPerSource: 100,
            maxEventsPerFile: 50,
            apiThrottleDelay: 0
        )

        let report = await indexingService.indexSources(discovery.sources, store: store)
        check(report.indexedFiles > 0, "Expected AI-backed pass to parse at least one source file")
        check(report.indexedEvents > 0, "Expected AI-backed pass to persist indexed events")
        check(report.indexedCards > 0, "Expected AI-backed pass to persist indexed memory cards")
        check(report.indexedLessons > 0, "Expected AI-backed pass to persist indexed lessons")
        check(report.indexedRewriteSuggestions > 0, "Expected AI-backed pass to persist rewrite suggestions")

        let unchangedReindexReport = await indexingService.rebuildIndex(from: discovery.sources, store: store)
        check(
            unchangedReindexReport.indexedFiles == 0,
            "Expected unchanged AI-backed rebuild to skip file re-indexing"
        )
        check(
            unchangedReindexReport.skippedFiles > 0,
            "Expected unchanged AI-backed rebuild to report skipped files"
        )

        let rewriteCards = try store.fetchCardsForRewrite(
            query: "teh",
            options: MemoryRewriteLookupOptions(provider: .codex, includePlanContent: false, limit: 10)
        )
        check(!rewriteCards.isEmpty, "Expected codex rewrite memory card query to return results")

        let conversationCards = try store.fetchCardsForRewrite(
            query: "acceptance criteria",
            options: MemoryRewriteLookupOptions(provider: .codex, includePlanContent: false, limit: 10)
        )
        check(
            conversationCards.allSatisfy { card in
                let combined = "\(card.title) \(card.summary) \(card.detail)".lowercased()
                return !combined.contains("internal reasoning")
                    && !combined.contains("tool_call")
                    && !combined.contains("tool result")
            },
            "Expected conversation query results to exclude noisy tool/thought artifacts"
        )

        let noisyCards = try store.fetchCardsForRewrite(
            query: "internal reasoning",
            options: MemoryRewriteLookupOptions(provider: .codex, includePlanContent: false, limit: 10)
        )
        check(noisyCards.isEmpty, "Expected tool/thought artifacts to be excluded from indexing")

        let lessons = try store.fetchLessonsForRewrite(
            query: "teh",
            provider: .codex,
            limit: 10
        )
        check(
            lessons.contains(where: {
                $0.mistakePattern.localizedCaseInsensitiveContains("teh")
                    && $0.improvedPrompt.localizedCaseInsensitiveContains("the")
                    && ($0.sourceMetadata["extraction_method"]?.lowercased() == "ai")
            }),
            "Expected AI-backed lesson metadata to include extraction_method=ai for teh -> the"
        )

        let rewriteSuggestions = try store.fetchRewriteSuggestions(
            query: "teh",
            provider: .codex,
            limit: 10
        )
        check(
            rewriteSuggestions.contains(where: {
                $0.originalText.localizedCaseInsensitiveContains("teh")
                    && $0.suggestedText.localizedCaseInsensitiveContains("the")
            }),
            "Expected rewrite suggestion to include teh -> the correction"
        )

        try write(
            """
            {"type":"rewrite","title":"Fix locale spelling","content":"colour -> color","original":"colour","suggested":"color","timestamp":"2026-02-01T10:10:00Z"}
            """,
            to: sandboxRoot.appendingPathComponent(".codex/archived_sessions/session-1.jsonl")
        )

        let reindexReport = await indexingService.indexSources(discovery.sources, store: store)
        check(reindexReport.indexedFiles > 0, "Expected AI-backed reindex to process modified files")

        let staleSuggestions = try store.fetchRewriteSuggestions(
            query: "teh",
            provider: .codex,
            limit: 10
        )
        check(
            staleSuggestions.isEmpty,
            "Expected stale rewrite suggestions to be removed after file changes"
        )

        let updatedSuggestions = try store.fetchRewriteSuggestions(
            query: "colour",
            provider: .codex,
            limit: 10
        )
        check(
            updatedSuggestions.contains(where: {
                $0.originalText.localizedCaseInsensitiveContains("colour")
                    && $0.suggestedText.localizedCaseInsensitiveContains("color")
            }),
            "Expected updated rewrite suggestion after reindex"
        )

        let fullRebuildReport = await indexingService.rebuildFromScratch(from: discovery.sources, store: store)
        check(
            fullRebuildReport.indexedFiles > 0,
            "Expected clear + rebuild from scratch to re-index files"
        )
        check(
            fullRebuildReport.indexedCards > 0,
            "Expected clear + rebuild from scratch to restore AI-backed cards"
        )
    }

    private static func runPatternAndRetentionScenario(
        sandboxRoot: URL
    ) async throws {
        let store = try MemorySQLiteStore(databaseURL: makeDatabaseURL(sandboxRoot, fileName: "memory-pattern.sqlite3"))
        let hasPatternStatsTable = try store.hasTable(named: "memory_pattern_stats")
        let hasPatternOccurrencesTable = try store.hasTable(named: "memory_pattern_occurrences")
        check(hasPatternStatsTable, "Expected schema v4 to include memory_pattern_stats table")
        check(hasPatternOccurrencesTable, "Expected schema v4 to include memory_pattern_occurrences table")

        let oldTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let scope = MemoryScopeContext(
            appName: "Codex",
            bundleID: "com.openai.codex",
            surfaceLabel: "Editor • Prompt",
            projectName: "alpha",
            repositoryName: "alpha-repo",
            isCodingContext: true
        )

        try store.recordPatternOccurrence(
            patternKey: "pattern-alpha-teh-the",
            scope: scope,
            cardID: nil,
            lessonID: nil,
            trigger: .autoCompaction,
            outcome: .neutral,
            confidence: 0.75,
            metadata: ["origin": "smoke-test"],
            timestamp: oldTimestamp
        )
        try store.recordPatternOccurrence(
            patternKey: "pattern-alpha-teh-the",
            scope: scope,
            cardID: nil,
            lessonID: nil,
            trigger: .manualCompaction,
            outcome: .good,
            confidence: 0.9,
            metadata: ["origin": "smoke-test"],
            timestamp: oldTimestamp.addingTimeInterval(10)
        )

        let stats = try store.fetchPatternStats(patternKey: "pattern-alpha-teh-the")
        check(stats != nil, "Expected recorded pattern stats to be queryable")
        check(stats?.occurrenceCount == 2, "Expected pattern occurrence count to increment")
        check(stats?.goodRepeatCount == 1, "Expected good repeat count to increment")
        check(stats?.badRepeatCount == 0, "Expected bad repeat count to remain zero")
        check(stats?.isRepeating == true, "Expected repeating flag once occurrence count reaches two")

        let occurrences = try store.fetchPatternOccurrences(patternKey: "pattern-alpha-teh-the", limit: 10)
        check(occurrences.count == 2, "Expected two persisted pattern occurrences")

        try seedRetentionFixture(
            store: store,
            seedKey: "raw-card",
            timestamp: oldTimestamp,
            score: 0.2,
            metadata: [
                "origin": "conversation-history",
                "validation_state": MemoryRewriteLessonValidationState.unvalidated.rawValue
            ]
        )
        try seedRetentionFixture(
            store: store,
            seedKey: "unvalidated-lesson",
            timestamp: oldTimestamp,
            score: 0.95,
            metadata: [
                "origin": "manual-entry",
                "validation_state": MemoryRewriteLessonValidationState.unvalidated.rawValue
            ]
        )

        let futureNow = oldTimestamp.addingTimeInterval(400 * 86_400)
        let purge = try store.purgeByTieredRetention(
            rawEvidenceDays: 30,
            unvalidatedLessonDays: 60,
            validatedDays: 365,
            now: futureNow
        )
        check(purge.cardsDeleted >= 1, "Expected tiered retention to purge stale low-signal raw cards")
        check(purge.lessonsDeleted >= 1, "Expected tiered retention to purge stale unvalidated lessons")
        check(purge.patternsDeleted >= 1, "Expected tiered retention to purge stale pattern stats")
        let remainingOccurrences = try store.fetchPatternOccurrences(patternKey: "pattern-alpha-teh-the", limit: 10)
        check(remainingOccurrences.isEmpty, "Expected stale pattern occurrences to be absent after purge")
    }

    private static func seedRetentionFixture(
        store: MemorySQLiteStore,
        seedKey: String,
        timestamp: Date,
        score: Double,
        metadata: [String: String]
    ) throws {
        let sourceID = MemoryIdentifier.stableUUID(for: "source|retention|\(seedKey)")
        let sourceFileID = MemoryIdentifier.stableUUID(for: "file|retention|\(seedKey)")
        let eventID = MemoryIdentifier.stableUUID(for: "event|retention|\(seedKey)")
        let cardID = MemoryIdentifier.stableUUID(for: "card|retention|\(seedKey)")
        let lessonID = MemoryIdentifier.stableUUID(for: "lesson|retention|\(seedKey)")

        try store.upsertSource(
            MemorySource(
                id: sourceID,
                provider: .unknown,
                rootPath: "internal://retention/\(seedKey)",
                displayName: "Retention \(seedKey)",
                discoveredAt: timestamp,
                metadata: metadata
            )
        )
        try store.upsertSourceFile(
            MemorySourceFile(
                id: sourceFileID,
                sourceID: sourceID,
                absolutePath: "retention/\(seedKey).jsonl",
                relativePath: "retention/\(seedKey).jsonl",
                fileHash: MemoryIdentifier.stableHexDigest(for: seedKey),
                fileSizeBytes: 120,
                modifiedAt: timestamp,
                indexedAt: timestamp,
                parseError: nil
            )
        )
        try store.upsertEvent(
            MemoryEvent(
                id: eventID,
                sourceID: sourceID,
                sourceFileID: sourceFileID,
                provider: .unknown,
                kind: .summary,
                title: "Retention \(seedKey)",
                body: "teh -> the",
                timestamp: timestamp,
                nativeSummary: "teh -> the",
                keywords: ["teh", "the"],
                isPlanContent: false,
                metadata: metadata,
                rawPayload: nil
            )
        )
        try store.upsertCard(
            MemoryCard(
                id: cardID,
                sourceID: sourceID,
                sourceFileID: sourceFileID,
                eventID: eventID,
                provider: .unknown,
                title: "Retention Card \(seedKey)",
                summary: "teh -> the",
                detail: "teh -> the",
                keywords: ["teh", "the"],
                score: score,
                createdAt: timestamp,
                updatedAt: timestamp,
                isPlanContent: false,
                metadata: metadata
            )
        )
        try store.upsertLesson(
            MemoryLesson(
                id: lessonID,
                sourceID: sourceID,
                sourceFileID: sourceFileID,
                eventID: eventID,
                cardID: cardID,
                provider: .unknown,
                mistakePattern: "teh",
                improvedPrompt: "the",
                rationale: "Retention test fixture",
                validationConfidence: 0.4,
                sourceMetadata: metadata,
                createdAt: timestamp,
                updatedAt: timestamp
            )
        )
    }

    private static func makeDatabaseURL(_ sandboxRoot: URL, fileName: String) -> URL {
        sandboxRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("OpenAssist", isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openassist-memory-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try write(
            """
            {"type":"rewrite","title":"Fix typo","content":"teh -> the","original":"teh","suggested":"the","timestamp":"2026-02-01T10:00:00Z"}
            {"type":"conversation","title":"Chat","content":"Remember to ask for acceptance criteria","timestamp":"2026-02-01T10:01:00Z"}
            {"type":"tool","role":"tool","content":"tool_call: grep -R TODO","timestamp":"2026-02-01T10:02:00Z"}
            {"type":"analysis","role":"thinking","content":"internal reasoning: maybe this","timestamp":"2026-02-01T10:03:00Z"}
            """,
            to: root.appendingPathComponent(".codex/archived_sessions/session-1.jsonl")
        )

        try write(
            """
            {"input":"please summarize this bug and include root cause","mode":"chat","parts":["summary","root cause"]}
            """,
            to: root.appendingPathComponent(".local/state/opencode/prompt-history.jsonl")
        )

        try write(
            """
            {"type":"message","title":"Claude Note","message":"Do not skip edge-case tests","timestamp":"2026-02-01T11:05:00Z"}
            """,
            to: root.appendingPathComponent(".claude/projects/sample/chat.jsonl")
        )

        try write(
            """
            {"title":"Bug triage","conversation":[{"role":"user","content":"Please include repro steps and expected behavior"},{"role":"assistant","content":"Absolutely—capture logs and compare expected behavior."},{"role":"tool","content":"tool result: 80 files scanned"}]}
            """,
            to: root.appendingPathComponent(".cursor/chats/session-2.jsonl")
        )

        return root
    }

    private static func write(_ value: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try value.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private struct NonAIMemoryRewriteProvider: MemoryRewriteExtractionProviding {
        func summary(
            for draft: MemoryEventDraft,
            provider: MemoryProviderKind
        ) async -> String? {
            _ = provider
            if let nativeSummary = draft.nativeSummary,
               !nativeSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return MemoryTextNormalizer.normalizedSummary(nativeSummary)
            }
            return MemoryTextNormalizer.normalizedSummary(draft.body, limit: 200)
        }

        func rewriteSuggestion(
            for draft: MemoryEventDraft,
            card: MemoryCard,
            provider: MemoryProviderKind
        ) async -> RewriteSuggestion? {
            _ = draft
            _ = card
            _ = provider
            return nil
        }

        func lesson(
            for draft: MemoryEventDraft,
            card: MemoryCard,
            provider: MemoryProviderKind
        ) async -> MemoryLessonDraft? {
            _ = draft
            _ = card
            _ = provider
            return nil
        }

        func hasAIBackedIndexingAccess(for provider: MemoryProviderKind) async -> Bool {
            _ = provider
            return false
        }
    }

    private struct MockAILessonRewriteProvider: MemoryRewriteExtractionProviding {
        func summary(
            for draft: MemoryEventDraft,
            provider: MemoryProviderKind
        ) async -> String? {
            _ = provider
            if let nativeSummary = draft.nativeSummary, !nativeSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return MemoryTextNormalizer.normalizedSummary(nativeSummary)
            }
            return MemoryTextNormalizer.normalizedSummary(draft.body, limit: 200)
        }

        func rewriteSuggestion(
            for draft: MemoryEventDraft,
            card: MemoryCard,
            provider: MemoryProviderKind
        ) async -> RewriteSuggestion? {
            _ = draft
            _ = card
            _ = provider
            return nil
        }

        func lesson(
            for draft: MemoryEventDraft,
            card: MemoryCard,
            provider: MemoryProviderKind
        ) async -> MemoryLessonDraft? {
            _ = card
            _ = provider
            guard !draft.isPlanContent else { return nil }
            guard let pair = rewritePair(for: draft) else { return nil }
            guard pair.original.caseInsensitiveCompare(pair.suggested) != .orderedSame else { return nil }

            return MemoryLessonDraft(
                mistakePattern: pair.original,
                improvedPrompt: pair.suggested,
                rationale: "AI synthesized lesson (smoke-test mock)",
                validationConfidence: 0.92,
                sourceMetadata: [
                    "extraction_method": "ai",
                    "provider_mode": "openai",
                    "test_provider": "mock-ai"
                ]
            )
        }

        func hasAIBackedIndexingAccess(for provider: MemoryProviderKind) async -> Bool {
            _ = provider
            return true
        }

        private func rewritePair(for draft: MemoryEventDraft) -> (original: String, suggested: String)? {
            let metadata = draft.metadata
            if let original = firstNonEmpty(
                metadata["original_text"],
                metadata["original"],
                metadata["input"],
                metadata["prompt"]
            ),
               let suggested = firstNonEmpty(
                metadata["suggested_text"],
                metadata["suggested"],
                metadata["rewrite"],
                metadata["response"],
                metadata["completion"],
                metadata["output"]
               ) {
                return (original, suggested)
            }

            return splitArrowRewrite(MemoryTextNormalizer.normalizedBody(draft.body))
        }

        private func splitArrowRewrite(_ body: String) -> (original: String, suggested: String)? {
            for marker in ["->", "=>", "→"] {
                let parts = body.components(separatedBy: marker)
                guard parts.count == 2 else { continue }
                let lhs = MemoryTextNormalizer.normalizedBody(parts[0])
                let rhs = MemoryTextNormalizer.normalizedBody(parts[1])
                guard !lhs.isEmpty, !rhs.isEmpty else { continue }
                return (lhs, rhs)
            }
            return nil
        }

        private func firstNonEmpty(_ values: String?...) -> String? {
            for value in values {
                guard let value else { continue }
                let normalized = MemoryTextNormalizer.normalizedBody(value)
                if !normalized.isEmpty {
                    return normalized
                }
            }
            return nil
        }
    }
}
