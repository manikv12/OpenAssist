import Foundation

struct ConversationMemoryPromotionPayload {
    let threadID: String
    let tupleTags: ConversationTupleTags?
    let context: PromptRewriteConversationContext
    let summaryText: String
    let fallbackSummaryText: String?
    let rawTurns: [PromptRewriteConversationTurn]
    let promotionScopeKey: String?
    let summaryGenerationMetadata: [String: String]
    let sourceTurnCount: Int
    let compactionVersion: Int?
    let trigger: MemoryPromotionTrigger
    let recentTurns: [PromptRewriteConversationTurn]
    let timestamp: Date

    init(
        threadID: String,
        tupleTags: ConversationTupleTags? = nil,
        context: PromptRewriteConversationContext,
        summaryText: String,
        fallbackSummaryText: String? = nil,
        rawTurns: [PromptRewriteConversationTurn]? = nil,
        promotionScopeKey: String? = nil,
        summaryGenerationMetadata: [String: String] = [:],
        sourceTurnCount: Int,
        compactionVersion: Int? = nil,
        trigger: MemoryPromotionTrigger,
        recentTurns: [PromptRewriteConversationTurn],
        timestamp: Date = Date()
    ) {
        self.threadID = threadID
        self.tupleTags = tupleTags
        self.context = context
        self.summaryText = summaryText
        self.fallbackSummaryText = fallbackSummaryText
        self.rawTurns = rawTurns ?? recentTurns
        self.promotionScopeKey = promotionScopeKey
        self.summaryGenerationMetadata = summaryGenerationMetadata
        self.sourceTurnCount = sourceTurnCount
        self.compactionVersion = compactionVersion
        self.trigger = trigger
        self.recentTurns = recentTurns
        self.timestamp = timestamp
    }
}

struct ConversationPromotionDecision {
    let score: Double
    let threshold: Double
    let signals: [String: Double]
    let weightedSignals: [String: Double]
    let triggerBoost: Double
    let forcePromote: Bool
    let shouldPromote: Bool
    let decision: String
}

actor ConversationMemoryPromotionService {
    static let shared = ConversationMemoryPromotionService()

    private let rewriteProvider: MemoryRewriteExtractionProviding
    private let storeFactory: @Sendable () throws -> MemorySQLiteStore
    private var store: MemorySQLiteStore?
    private let promotionThreshold = 0.65
    private let aiSummaryTimeoutSeconds = 60

    init(
        rewriteProvider: MemoryRewriteExtractionProviding = StubMemoryRewriteExtractionProvider.shared,
        storeFactory: @escaping @Sendable () throws -> MemorySQLiteStore = { try MemorySQLiteStore() }
    ) {
        self.rewriteProvider = rewriteProvider
        self.storeFactory = storeFactory
    }

    func promote(_ payload: ConversationMemoryPromotionPayload) async {
        guard FeatureFlags.aiMemoryEnabled,
              FeatureFlags.conversationLongTermMemoryEnabled,
              FeatureFlags.conversationAutoPromotionEnabled else {
            return
        }

        let fallbackSummarySeed = MemoryTextNormalizer.normalizedBody(
            payload.fallbackSummaryText ?? payload.summaryText
        )
        guard !fallbackSummarySeed.isEmpty else { return }

        let rawTurns = payload.rawTurns.isEmpty ? payload.recentTurns : payload.rawTurns
        let enrichedSummaryResult = await rewriteProvider.summarizeConversationHandoff(
            summarySeed: fallbackSummarySeed,
            recentTurns: rawTurns,
            context: payload.context,
            timeoutSeconds: aiSummaryTimeoutSeconds
        )
        let normalizedSummary = MemoryTextNormalizer.normalizedBody(enrichedSummaryResult.text)
        let resolvedSummary = normalizedSummary.isEmpty ? fallbackSummarySeed : normalizedSummary
        let summaryMethod = MemoryTextNormalizer.collapsedWhitespace(enrichedSummaryResult.method)
        var summaryMetadata = normalizedStringDictionary(payload.summaryGenerationMetadata)
        summaryMetadata["summary_method"] = summaryMethod
        if let confidence = enrichedSummaryResult.confidence {
            summaryMetadata["summary_confidence"] = formattedPromotionValue(confidence)
        }

        let preparedPayload = ConversationMemoryPromotionPayload(
            threadID: payload.threadID,
            tupleTags: payload.tupleTags,
            context: payload.context,
            summaryText: resolvedSummary,
            fallbackSummaryText: fallbackSummarySeed,
            rawTurns: rawTurns,
            promotionScopeKey: payload.promotionScopeKey,
            summaryGenerationMetadata: summaryMetadata,
            sourceTurnCount: payload.sourceTurnCount,
            compactionVersion: payload.compactionVersion,
            trigger: payload.trigger,
            recentTurns: payload.recentTurns,
            timestamp: payload.timestamp
        )

        guard !resolvedSummary.isEmpty else { return }
        let nativeThreadKey = MemoryTextNormalizer.collapsedWhitespace(
            preparedPayload.tupleTags?.nativeThreadKey ?? preparedPayload.context.nativeThreadKey ?? ""
        ).lowercased()

        do {
            let store = try resolvedStore()
            let promotionDecision = evaluatePromotionSignals(payload: preparedPayload, store: store)
            guard promotionDecision.shouldPromote else {
                return
            }

            let scope = inferScopeContext(from: preparedPayload)
            let promotionSignature = promotionSignature(for: preparedPayload, scope: scope)
            let promotionMetadata = promotionRecordMetadata(
                payload: preparedPayload,
                scope: scope,
                nativeThreadKey: nativeThreadKey,
                summaryMethod: summaryMethod,
                decision: promotionDecision
            )

            let sourceID = MemoryIdentifier.stableUUID(
                for: "source|conversation-history|\(scope.bundleID)"
            )
            let sourceFileID = MemoryIdentifier.stableUUID(
                for: "file|\(sourceID.uuidString)|\(scope.scopeKey)"
            )
            let eventID = MemoryIdentifier.stableUUID(
                for: "event|conversation-history|\(promotionSignature)"
            )
            let cardID = MemoryIdentifier.stableUUID(
                for: "card|conversation-history|\(promotionSignature)"
            )

            let source = MemorySource(
                id: sourceID,
                provider: .unknown,
                rootPath: "internal://conversation-history/\(scope.bundleID)",
                displayName: "\(scope.appName) Conversation Memory",
                discoveredAt: preparedPayload.timestamp,
                metadata: promotionMetadata
            )
            try store.upsertSource(source)

            let sourceFile = MemorySourceFile(
                id: sourceFileID,
                sourceID: sourceID,
                absolutePath: "conversation-history/\(scope.scopeKey).jsonl",
                relativePath: "conversation-history/\(scope.scopeKey).jsonl",
                fileHash: promotionSignature,
                fileSizeBytes: Int64(resolvedSummary.utf8.count),
                modifiedAt: preparedPayload.timestamp,
                indexedAt: preparedPayload.timestamp,
                parseError: nil
            )
            try store.upsertSourceFile(sourceFile)

            let eventBody = buildEventBody(summary: resolvedSummary, recentTurns: rawTurns)
            let eventKeywords = MemoryTextNormalizer.keywords(
                from: "\(scope.appName) \(scope.surfaceLabel) \(scope.projectName ?? "") \(scope.repositoryName ?? "") \(resolvedSummary)",
                limit: 20
            )
            let event = MemoryEvent(
                id: eventID,
                sourceID: sourceID,
                sourceFileID: sourceFileID,
                provider: .unknown,
                kind: .summary,
                title: MemoryTextNormalizer.normalizedTitle(
                    "\(scope.appName) memory: \(scope.surfaceLabel)",
                    fallback: "Conversation Memory Summary"
                ),
                body: eventBody,
                timestamp: preparedPayload.timestamp,
                nativeSummary: MemoryTextNormalizer.normalizedSummary(resolvedSummary, limit: 260),
                keywords: eventKeywords,
                isPlanContent: false,
                metadata: promotionMetadata,
                rawPayload: nil
            )
            try store.upsertEvent(event)

            let card = MemoryCard(
                id: cardID,
                sourceID: sourceID,
                sourceFileID: sourceFileID,
                eventID: eventID,
                provider: .unknown,
                title: event.title,
                summary: MemoryTextNormalizer.normalizedSummary(resolvedSummary, limit: 220),
                detail: eventBody,
                keywords: eventKeywords,
                score: promotionDecision.score,
                createdAt: preparedPayload.timestamp,
                updatedAt: preparedPayload.timestamp,
                isPlanContent: false,
                metadata: event.metadata
            )
            try store.upsertCard(card)

            let draft = MemoryEventDraft(
                kind: .summary,
                title: event.title,
                body: eventBody,
                timestamp: preparedPayload.timestamp,
                nativeSummary: card.summary,
                keywords: eventKeywords,
                isPlanContent: false,
                metadata: event.metadata,
                rawPayload: nil
            )

            var lessonID: UUID?
            var patternKey: String
            if let lessonDraft = await rewriteProvider.lesson(for: draft, card: card, provider: .unknown) {
                let lesson = MemoryLesson(
                    id: MemoryIdentifier.stableUUID(
                        for: "lesson|conversation-history|\(promotionSignature)|\(lessonDraft.mistakePattern)|\(lessonDraft.improvedPrompt)"
                    ),
                    sourceID: sourceID,
                    sourceFileID: sourceFileID,
                    eventID: eventID,
                    cardID: cardID,
                    provider: .unknown,
                    mistakePattern: lessonDraft.mistakePattern,
                    improvedPrompt: lessonDraft.improvedPrompt,
                    rationale: lessonDraft.rationale,
                    validationConfidence: lessonDraft.validationConfidence,
                    sourceMetadata: mergedMetadata(
                        payload: preparedPayload,
                        base: lessonDraft.sourceMetadata,
                        scope: scope,
                        trigger: preparedPayload.trigger,
                        contextID: preparedPayload.threadID,
                        sourceTurnCount: preparedPayload.sourceTurnCount,
                        compactionVersion: preparedPayload.compactionVersion,
                        nativeThreadKey: nativeThreadKey,
                        decision: promotionDecision,
                        summaryMethod: summaryMethod,
                        summaryGenerationMetadata: preparedPayload.summaryGenerationMetadata
                    ),
                    createdAt: preparedPayload.timestamp,
                    updatedAt: preparedPayload.timestamp
                )
                try store.upsertLesson(lesson)
                try store.supersedeCompetingLessons(
                    with: lesson,
                    reason: "Superseded by newer conversation summary lesson.",
                    timestamp: preparedPayload.timestamp
                )
                lessonID = lesson.id

                let suggestion = RewriteSuggestion(
                    id: MemoryIdentifier.stableUUID(
                        for: "rewrite|conversation-history|\(promotionSignature)|\(lessonDraft.mistakePattern)|\(lessonDraft.improvedPrompt)"
                    ),
                    cardID: cardID,
                    provider: .unknown,
                    originalText: MemoryTextNormalizer.collapsedWhitespace(lessonDraft.mistakePattern),
                    suggestedText: MemoryTextNormalizer.collapsedWhitespace(lessonDraft.improvedPrompt),
                    rationale: lessonDraft.rationale,
                    confidence: min(1.0, max(0.0, lessonDraft.validationConfidence)),
                    createdAt: preparedPayload.timestamp
                )
                try store.insertRewriteSuggestion(suggestion)

                patternKey = MemoryIdentifier.stableHexDigest(
                    for: "pattern|\(scope.scopeKey)|\(MemoryTextNormalizer.collapsedWhitespace(lessonDraft.mistakePattern).lowercased())|\(MemoryTextNormalizer.collapsedWhitespace(lessonDraft.improvedPrompt).lowercased())"
                )
            } else {
                patternKey = MemoryIdentifier.stableHexDigest(
                    for: "pattern|\(scope.scopeKey)|summary|\(MemoryTextNormalizer.collapsedWhitespace(resolvedSummary).lowercased())"
                )
            }

            try store.recordPatternOccurrence(
                patternKey: patternKey,
                scope: scope,
                cardID: cardID,
                lessonID: lessonID,
                trigger: preparedPayload.trigger,
                outcome: .neutral,
                confidence: promotionDecision.score,
                metadata: promotionMetadata,
                timestamp: preparedPayload.timestamp
            )
        } catch {
            // Best-effort promotion: never block rewrite flow.
        }
    }

    func fetchPatternStats(scopeKey: String? = nil, limit: Int = 200) async -> [MemoryPatternStats] {
        do {
            let store = try resolvedStore()
            return try store.fetchPatternStats(scopeKey: scopeKey, limit: limit)
        } catch {
            return []
        }
    }

    func fetchPatternOccurrences(patternKey: String, limit: Int = 120) async -> [MemoryPatternOccurrence] {
        do {
            let store = try resolvedStore()
            return try store.fetchPatternOccurrences(patternKey: patternKey, limit: limit)
        } catch {
            return []
        }
    }

    @discardableResult
    func markPatternOutcome(
        patternKey: String,
        outcome: MemoryPatternOutcome,
        trigger: MemoryPromotionTrigger,
        reason: String? = nil
    ) async -> Bool {
        do {
            let store = try resolvedStore()
            guard let existing = try store.fetchPatternStats(patternKey: patternKey) else {
                return false
            }
            let scope = MemoryScopeContext(
                appName: existing.appName,
                bundleID: existing.bundleID,
                surfaceLabel: existing.surfaceLabel,
                projectName: existing.projectName,
                repositoryName: existing.repositoryName,
                scopeKey: existing.scopeKey,
                isCodingContext: inferCodingContext(
                    bundleID: existing.bundleID,
                    appName: existing.appName,
                    projectName: existing.projectName,
                    repositoryName: existing.repositoryName
                )
            )
            var metadata: [String: String] = ["origin": "manual-mark"]
            if let reason {
                metadata["reason"] = MemoryTextNormalizer.normalizedSummary(reason, limit: 180)
            }
            try store.recordPatternOccurrence(
                patternKey: patternKey,
                scope: scope,
                cardID: nil,
                lessonID: nil,
                trigger: trigger,
                outcome: outcome,
                confidence: existing.confidence,
                metadata: metadata,
                timestamp: Date()
            )
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func deletePattern(patternKey: String) async -> Bool {
        do {
            let store = try resolvedStore()
            try store.deletePattern(patternKey: patternKey)
            return true
        } catch {
            return false
        }
    }

    func purgeExpiredRetention() async -> (cardsDeleted: Int, lessonsDeleted: Int, patternsDeleted: Int, occurrencesDeleted: Int) {
        do {
            let store = try resolvedStore()
            return try store.purgeByTieredRetention()
        } catch {
            return (0, 0, 0, 0)
        }
    }

    private func resolvedStore() throws -> MemorySQLiteStore {
        if let store {
            return store
        }
        let created = try storeFactory()
        store = created
        return created
    }

    private func promotionSignature(for payload: ConversationMemoryPromotionPayload, scope: MemoryScopeContext) -> String {
        let summaryDigest = MemoryIdentifier.stableHexDigest(
            for: MemoryTextNormalizer.collapsedWhitespace(payload.summaryText).lowercased()
        )

        let base = [
            payload.threadID,
            scope.scopeKey,
            summaryDigest,
            "\(max(1, payload.sourceTurnCount))",
            payload.trigger.rawValue
        ].joined(separator: "|")
        return MemoryIdentifier.stableHexDigest(for: base)
    }

    func evaluatePromotionSignals(
        payload: ConversationMemoryPromotionPayload,
        store: MemorySQLiteStore
    ) -> ConversationPromotionDecision {
        let turnDepth = turnDepthSignal(payload: payload)
        let summaryQuality = summaryQualitySignal(payload: payload)
        let contextSpecificity = contextSpecificitySignal(payload: payload)
        let recurrence = recurrenceSignal(payload: payload, store: store)
        let actionability = actionabilitySignal(payload: payload)

        let weightedTurnDepth = turnDepth * 0.30
        let weightedSummaryQuality = summaryQuality * 0.25
        let weightedContextSpecificity = contextSpecificity * 0.15
        let weightedRecurrence = recurrence * 0.20
        let weightedActionability = actionability * 0.10

        let rawScore = weightedTurnDepth
            + weightedSummaryQuality
            + weightedContextSpecificity
            + weightedRecurrence
            + weightedActionability

        let trigger = triggerAdjustment(for: payload.trigger)
        let score = min(1.0, max(0.0, rawScore + trigger.boost))
        let shouldPromote = trigger.forcePromote || score >= promotionThreshold
        let decisionLabel: String
        if trigger.forcePromote {
            decisionLabel = "force-promote"
        } else if shouldPromote {
            decisionLabel = "promote"
        } else {
            decisionLabel = "skip"
        }

        return ConversationPromotionDecision(
            score: score,
            threshold: promotionThreshold,
            signals: [
                "turn_depth": turnDepth,
                "summary_quality": summaryQuality,
                "context_specificity": contextSpecificity,
                "recurrence": recurrence,
                "actionability": actionability
            ],
            weightedSignals: [
                "turn_depth": weightedTurnDepth,
                "summary_quality": weightedSummaryQuality,
                "context_specificity": weightedContextSpecificity,
                "recurrence": weightedRecurrence,
                "actionability": weightedActionability
            ],
            triggerBoost: trigger.boost,
            forcePromote: trigger.forcePromote,
            shouldPromote: shouldPromote,
            decision: decisionLabel
        )
    }

    private func triggerAdjustment(for trigger: MemoryPromotionTrigger) -> (boost: Double, forcePromote: Bool) {
        switch trigger {
        case .manualCompaction, .manualPin:
            return (0.20, true)
        case .autoCompaction:
            return (0.05, false)
        case .timeout:
            return (0.0, false)
        }
    }

    private func turnDepthSignal(payload: ConversationMemoryPromotionPayload) -> Double {
        let effectiveTurnCount = max(
            1,
            max(payload.sourceTurnCount, max(payload.rawTurns.count, payload.recentTurns.count))
        )
        return min(1.0, Double(effectiveTurnCount) / 16.0)
    }

    private func summaryQualitySignal(payload: ConversationMemoryPromotionPayload) -> Double {
        let summary = MemoryTextNormalizer.normalizedBody(payload.summaryText)
        guard !summary.isEmpty else { return 0.0 }

        let length = summary.count
        let lengthScore: Double
        switch length {
        case 0..<36:
            lengthScore = Double(length) / 36.0
        case 36..<120:
            lengthScore = 0.55 + (Double(length - 36) / 84.0) * 0.35
        case 120...900:
            lengthScore = 0.90
        default:
            let overflow = Double(length - 900)
            lengthScore = max(0.35, 0.90 - min(0.55, overflow / 1800.0))
        }

        let structureSignal: Double
        if summary.contains("##") || summary.contains("- ") || summary.contains("\n") {
            structureSignal = 1.0
        } else {
            structureSignal = 0.55
        }

        let confidenceSignal = summaryConfidenceSignal(from: payload.summaryGenerationMetadata) ?? 0.65
        return min(
            1.0,
            max(
                0.0,
                (lengthScore * 0.65)
                    + (structureSignal * 0.15)
                    + (confidenceSignal * 0.20)
            )
        )
    }

    private func contextSpecificitySignal(payload: ConversationMemoryPromotionPayload) -> Double {
        let context = payload.context
        var score = 0.20
        if hasMeaningfulContextValue(context.projectLabel) { score += 0.22 }
        if hasMeaningfulContextValue(context.identityLabel) { score += 0.18 }
        if hasMeaningfulContextValue(context.screenLabel) { score += 0.12 }
        if hasMeaningfulContextValue(context.fieldLabel) { score += 0.08 }
        if hasMeaningfulContextValue(payload.promotionScopeKey) { score += 0.15 }
        if hasMeaningfulContextValue(payload.tupleTags?.nativeThreadKey ?? context.nativeThreadKey) { score += 0.15 }
        if !context.people.isEmpty { score += 0.10 }
        return min(1.0, max(0.0, score))
    }

    private func recurrenceSignal(
        payload: ConversationMemoryPromotionPayload,
        store: MemorySQLiteStore
    ) -> Double {
        let scope = inferScopeContext(from: payload)
        guard let stats = try? store.fetchPatternStats(scopeKey: scope.scopeKey, limit: 60),
              !stats.isEmpty else {
            return 0.25
        }

        let maxOccurrence = stats.map(\.occurrenceCount).max() ?? 1
        let repeatingCount = stats.filter { $0.occurrenceCount >= 2 }.count
        let highConfidence = stats.filter { $0.confidence >= 0.70 }.count

        let maxOccurrenceSignal = min(1.0, Double(max(0, maxOccurrence - 1)) / 5.0)
        let repeatingSignal = min(1.0, Double(repeatingCount) / 4.0)
        let confidenceSignal = min(1.0, Double(highConfidence) / Double(max(1, stats.count)))

        let blended = 0.20 + (maxOccurrenceSignal * 0.45) + (repeatingSignal * 0.25) + (confidenceSignal * 0.10)
        return min(1.0, max(0.0, blended))
    }

    private func actionabilitySignal(payload: ConversationMemoryPromotionPayload) -> Double {
        let summary = MemoryTextNormalizer.collapsedWhitespace(payload.summaryText).lowercased()
        let recentSignalText = payload.rawTurns
            .suffix(4)
            .map { "\($0.userText) \($0.assistantText)" }
            .joined(separator: "\n")
            .lowercased()
        let combined = "\(summary)\n\(recentSignalText)"

        let actionVerbs = [
            "fix", "implement", "update", "add", "remove", "refactor",
            "debug", "test", "verify", "ship", "deploy", "document"
        ]
        let constraintHints = [
            "must", "should", "need to", "exactly", "only", "do not", "without", "timeout"
        ]
        let artifactHints = [
            ".swift", ".md", ".json", "sources/", "tests/", "http", "/", "path", "file"
        ]

        let hasAction = actionVerbs.contains { combined.contains($0) }
        let hasConstraint = constraintHints.contains { combined.contains($0) }
        let hasArtifact = artifactHints.contains { combined.contains($0) }
        let hasStructuredHandoff = summary.contains("##") || summary.contains("recent turns")

        var score = 0.15
        if hasAction { score += 0.35 }
        if hasConstraint { score += 0.22 }
        if hasArtifact { score += 0.18 }
        if hasStructuredHandoff { score += 0.10 }
        return min(1.0, max(0.0, score))
    }

    private func promotionRecordMetadata(
        payload: ConversationMemoryPromotionPayload,
        scope: MemoryScopeContext,
        nativeThreadKey: String,
        summaryMethod: String,
        decision: ConversationPromotionDecision
    ) -> [String: String] {
        let canonicalKeys = resolvedCanonicalContextKeys(payload: payload, scope: scope)
        var metadata: [String: String] = [
            "origin": "conversation-history",
            "scope_key": scope.scopeKey,
            "app_name": scope.appName,
            "bundle_id": scope.bundleID,
            "surface_label": scope.surfaceLabel,
            "project_name": scope.projectName ?? "",
            "project_label": scope.projectName ?? "",
            "project_key": canonicalKeys.projectKey ?? "",
            "canonical_project_key": canonicalKeys.projectKey ?? "",
            "repository_name": scope.repositoryName ?? "",
            "identity_key": canonicalKeys.identityKey ?? scope.identityKey ?? "",
            "canonical_identity_key": canonicalKeys.identityKey ?? scope.identityKey ?? "",
            "identity_type": scope.identityType ?? "",
            "identity_label": scope.identityLabel ?? "",
            "native_thread_key": nativeThreadKey,
            "thread_id": payload.threadID,
            "trigger": payload.trigger.rawValue,
            "source_turn_count": "\(max(1, payload.sourceTurnCount))",
            "promotion_score": formattedPromotionValue(decision.score),
            "promotion_threshold": formattedPromotionValue(decision.threshold),
            "promotion_signals": promotionSignalsMetadataValue(for: decision),
            "promotion_decision": decision.decision,
            "summary_method": summaryMethod,
            "ai_timeout_seconds": "\(aiSummaryTimeoutSeconds)"
        ]
        if let source = canonicalKeys.projectKeySource {
            metadata["canonical_project_key_source"] = source
        }
        if let source = canonicalKeys.identityKeySource {
            metadata["canonical_identity_key_source"] = source
        }
        if let compactionVersion = payload.compactionVersion {
            metadata["compaction_version"] = "\(compactionVersion)"
        }
        if !payload.summaryGenerationMetadata.isEmpty {
            metadata["summary_generation_metadata"] = encodedStringMap(payload.summaryGenerationMetadata)
        }
        return normalizedStringDictionary(metadata)
    }

    private func promotionSignalsMetadataValue(for decision: ConversationPromotionDecision) -> String {
        let payload: [String: String] = [
            "turn_depth": formattedPromotionValue(decision.signals["turn_depth"] ?? 0),
            "summary_quality": formattedPromotionValue(decision.signals["summary_quality"] ?? 0),
            "context_specificity": formattedPromotionValue(decision.signals["context_specificity"] ?? 0),
            "recurrence": formattedPromotionValue(decision.signals["recurrence"] ?? 0),
            "actionability": formattedPromotionValue(decision.signals["actionability"] ?? 0),
            "weighted_turn_depth": formattedPromotionValue(decision.weightedSignals["turn_depth"] ?? 0),
            "weighted_summary_quality": formattedPromotionValue(decision.weightedSignals["summary_quality"] ?? 0),
            "weighted_context_specificity": formattedPromotionValue(decision.weightedSignals["context_specificity"] ?? 0),
            "weighted_recurrence": formattedPromotionValue(decision.weightedSignals["recurrence"] ?? 0),
            "weighted_actionability": formattedPromotionValue(decision.weightedSignals["actionability"] ?? 0),
            "trigger_boost": formattedPromotionValue(decision.triggerBoost),
            "force_promote": decision.forcePromote ? "true" : "false"
        ]
        return encodedStringMap(payload)
    }

    private func summaryConfidenceSignal(from metadata: [String: String]) -> Double? {
        let candidates = [
            metadata["summary_confidence"],
            metadata["confidence"],
            metadata["ai_confidence"]
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, let value = Double(normalized) else { continue }
            return min(1.0, max(0.0, value))
        }
        return nil
    }

    private func hasMeaningfulContextValue(_ value: String?) -> Bool {
        guard let value else { return false }
        let normalized = MemoryTextNormalizer.collapsedWhitespace(value).lowercased()
        guard !normalized.isEmpty else { return false }
        let blocked = [
            "unknown",
            "unknown project",
            "unknown identity",
            "current screen",
            "focused input",
            "unknown channel",
            "unknown chat"
        ]
        return !blocked.contains(normalized)
    }

    private func normalizedStringDictionary(_ value: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(value.count)
        for (key, rawValue) in value {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty, !normalizedValue.isEmpty else { continue }
            normalized[normalizedKey] = normalizedValue
        }
        return normalized
    }

    private func encodedStringMap(_ value: [String: String]) -> String {
        guard !value.isEmpty,
              let data = try? JSONSerialization.data(
                withJSONObject: normalizedStringDictionary(value),
                options: [.sortedKeys]
              ),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func formattedPromotionValue(_ value: Double) -> String {
        if value.isNaN || !value.isFinite {
            return "0.000"
        }
        return String(format: "%.3f", min(1.0, max(0.0, value)))
    }

    private func buildEventBody(summary: String, recentTurns: [PromptRewriteConversationTurn]) -> String {
        var lines: [String] = [
            "Conversation summary:",
            MemoryTextNormalizer.normalizedBody(summary)
        ]

        let recent = recentTurns.suffix(4)
        if !recent.isEmpty {
            lines.append("")
            lines.append("Recent turns:")
            for turn in recent {
                let timeLabel = ISO8601DateFormatter().string(from: turn.timestamp)
                if turn.isSummary {
                    lines.append("- [\(timeLabel)] Summary: \(MemoryTextNormalizer.normalizedSummary(turn.assistantText, limit: 220))")
                } else {
                    let userSnippet = MemoryTextNormalizer.normalizedSummary(turn.userText, limit: 180)
                    let assistantSnippet = MemoryTextNormalizer.normalizedSummary(turn.assistantText, limit: 180)
                    lines.append("- [\(timeLabel)] User: \(userSnippet)")
                    lines.append("  Assistant: \(assistantSnippet)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func mergedMetadata(
        payload: ConversationMemoryPromotionPayload,
        base: [String: String],
        scope: MemoryScopeContext,
        trigger: MemoryPromotionTrigger,
        contextID: String,
        sourceTurnCount: Int,
        compactionVersion: Int?,
        nativeThreadKey: String,
        decision: ConversationPromotionDecision,
        summaryMethod: String,
        summaryGenerationMetadata: [String: String]
    ) -> [String: String] {
        let canonicalKeys = resolvedCanonicalContextKeys(payload: payload, scope: scope)
        var merged = base
        merged["origin"] = "conversation-history"
        merged["scope_key"] = scope.scopeKey
        merged["app_name"] = scope.appName
        merged["bundle_id"] = scope.bundleID
        merged["surface_label"] = scope.surfaceLabel
        merged["project_name"] = scope.projectName ?? ""
        merged["project_label"] = scope.projectName ?? ""
        merged["project_key"] = canonicalKeys.projectKey ?? ""
        merged["canonical_project_key"] = canonicalKeys.projectKey ?? ""
        merged["repository_name"] = scope.repositoryName ?? ""
        merged["identity_key"] = canonicalKeys.identityKey ?? scope.identityKey ?? ""
        merged["canonical_identity_key"] = canonicalKeys.identityKey ?? scope.identityKey ?? ""
        merged["identity_type"] = scope.identityType ?? ""
        merged["identity_label"] = scope.identityLabel ?? ""
        merged["context_id"] = contextID
        merged["thread_id"] = contextID
        merged["native_thread_key"] = nativeThreadKey
        merged["trigger"] = trigger.rawValue
        merged["source_turn_count"] = "\(max(1, sourceTurnCount))"
        merged["promotion_score"] = formattedPromotionValue(decision.score)
        merged["promotion_threshold"] = formattedPromotionValue(decision.threshold)
        merged["promotion_signals"] = promotionSignalsMetadataValue(for: decision)
        merged["promotion_decision"] = decision.decision
        merged["summary_method"] = summaryMethod
        merged["ai_timeout_seconds"] = "\(aiSummaryTimeoutSeconds)"
        if let compactionVersion {
            merged["compaction_version"] = "\(compactionVersion)"
        }
        if !summaryGenerationMetadata.isEmpty {
            merged["summary_generation_metadata"] = encodedStringMap(summaryGenerationMetadata)
        }
        if let source = canonicalKeys.projectKeySource {
            merged["canonical_project_key_source"] = source
        }
        if let source = canonicalKeys.identityKeySource {
            merged["canonical_identity_key_source"] = source
        }
        if merged["validation_state"] == nil {
            merged["validation_state"] = MemoryRewriteLessonValidationState.unvalidated.rawValue
        }

        return normalizedStringDictionary(merged)
    }

    private func inferScopeContext(from payload: ConversationMemoryPromotionPayload) -> MemoryScopeContext {
        let context = payload.context

        if let tupleTags = payload.tupleTags {
            let isCoding = inferCodingContext(
                bundleID: context.bundleIdentifier,
                appName: context.appName,
                projectName: tupleTags.projectLabel,
                repositoryName: nil
            )
            let surfaceLabel = context.logicalSurfaceKey.isEmpty
                ? "\(context.screenLabel) • \(context.fieldLabel)"
                : context.logicalSurfaceKey
            return MemoryScopeContext(
                appName: context.appName,
                bundleID: context.bundleIdentifier,
                surfaceLabel: surfaceLabel,
                projectKey: tupleTags.projectKey,
                projectName: tupleTags.projectLabel,
                repositoryName: nil,
                identityKey: tupleTags.identityKey,
                identityType: tupleTags.identityType,
                identityLabel: tupleTags.identityLabel,
                scopeKey: payload.promotionScopeKey,
                isCodingContext: isCoding
            )
        }

        let combinedText = [
            context.screenLabel,
            context.fieldLabel,
            payload.summaryText,
            payload.rawTurns.map { "\($0.userText) \($0.assistantText)" }.joined(separator: "\n")
        ].joined(separator: "\n")

        let bundleID = context.bundleIdentifier
        let appName = context.appName
        let surfaceLabel = "\(context.screenLabel) • \(context.fieldLabel)"

        let pathCandidate = extractPathLikeValue(from: combinedText)
        let derivedPathLabel = pathCandidate.flatMap(derivePathLabel)
        let domainCandidate = extractDomain(from: combinedText)
        let teamsChannel = extractTeamsChannel(from: context.screenLabel)

        let isCoding = inferCodingContext(
            bundleID: bundleID,
            appName: appName,
            projectName: derivedPathLabel,
            repositoryName: nil
        )

        let projectName: String?
        let repositoryName: String?
        if isCoding {
            projectName = derivedPathLabel
            repositoryName = derivedPathLabel
        } else if isBrowser(bundleID: bundleID, appName: appName) {
            projectName = domainCandidate ?? derivedPathLabel
            repositoryName = nil
        } else if isTeams(bundleID: bundleID, appName: appName) {
            projectName = teamsChannel ?? derivedPathLabel
            repositoryName = nil
        } else {
            projectName = derivedPathLabel ?? teamsChannel ?? domainCandidate
            repositoryName = nil
        }

        return MemoryScopeContext(
            appName: appName,
            bundleID: bundleID,
            surfaceLabel: surfaceLabel,
            projectKey: context.projectKey,
            projectName: projectName,
            repositoryName: repositoryName,
            identityKey: context.identityKey,
            identityType: context.identityType,
            identityLabel: context.identityLabel,
            scopeKey: payload.promotionScopeKey,
            isCodingContext: isCoding
        )
    }

    private func resolvedCanonicalContextKeys(
        payload: ConversationMemoryPromotionPayload,
        scope: MemoryScopeContext
    ) -> (
        projectKey: String?,
        projectKeySource: String?,
        identityKey: String?,
        identityKeySource: String?
    ) {
        let projectCandidates: [(value: String?, source: String)] = [
            (payload.tupleTags?.projectKey, "tuple-tags"),
            (payload.context.projectKey, "context"),
            (scope.projectName, "scope-project")
        ]
        let identityCandidates: [(value: String?, source: String)] = [
            (payload.tupleTags?.identityKey, "tuple-tags"),
            (payload.context.identityKey, "context"),
            (scope.identityKey, "scope")
        ]

        let project = firstCanonicalContextKey(from: projectCandidates)
        let identity = firstCanonicalContextKey(from: identityCandidates)
        return (
            projectKey: project?.value,
            projectKeySource: project?.source,
            identityKey: identity?.value,
            identityKeySource: identity?.source
        )
    }

    private func firstCanonicalContextKey(
        from candidates: [(value: String?, source: String)]
    ) -> (value: String, source: String)? {
        for candidate in candidates {
            guard let normalized = normalizedCanonicalContextKey(candidate.value),
                  isCanonicalContextKey(normalized) else {
                continue
            }
            return (normalized, candidate.source)
        }
        return nil
    }

    private func normalizedCanonicalContextKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = MemoryTextNormalizer.collapsedWhitespace(value).lowercased()
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    private func isCanonicalContextKey(_ value: String) -> Bool {
        value.contains(":") && !value.contains(" ") && !value.contains("|")
    }

    private func inferCodingContext(
        bundleID: String,
        appName: String,
        projectName: String?,
        repositoryName: String?
    ) -> Bool {
        let value = "\(bundleID) \(appName)".lowercased()
        if ["xcode", "cursor", "vscode", "code", "jetbrains", "codex", "android.studio", "sublime", "nova"].contains(where: { value.contains($0) }) {
            return true
        }
        if let projectName, projectName.contains("/") {
            return true
        }
        if let repositoryName, repositoryName.contains("/") {
            return true
        }
        return false
    }

    private func isBrowser(bundleID: String, appName: String) -> Bool {
        let value = "\(bundleID) \(appName)".lowercased()
        return ["safari", "chrome", "firefox", "arc", "brave", "opera", "edge"].contains(where: { value.contains($0) })
    }

    private func isTeams(bundleID: String, appName: String) -> Bool {
        let value = "\(bundleID) \(appName)".lowercased()
        return value.contains("teams")
    }

    private func extractDomain(from value: String) -> String? {
        let pattern = #"(?i)\b(?:https?://)?([a-z0-9.-]+\.[a-z]{2,})(?:/|\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let domainRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        let domain = String(value[domainRange]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty else { return nil }
        return domain
    }

    private func extractTeamsChannel(from value: String) -> String? {
        let normalized = MemoryTextNormalizer.collapsedWhitespace(value)
        guard !normalized.isEmpty else { return nil }

        let separators = ["|", "-", "•", ":"]
        for separator in separators {
            if normalized.contains(separator) {
                let parts = normalized.split(separator: Character(separator), omittingEmptySubsequences: true)
                    .map { MemoryTextNormalizer.collapsedWhitespace(String($0)) }
                    .filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let candidate = parts.prefix(2).joined(separator: " / ")
                    return MemoryTextNormalizer.normalizedSummary(candidate, limit: 80)
                }
            }
        }

        return MemoryTextNormalizer.normalizedSummary(normalized, limit: 80)
    }

    private func extractPathLikeValue(from value: String) -> String? {
        let patterns = [
            #"file://[^\s"'<>\]\[)\(,;]+"#,
            #"/(?:Users|Volumes|private)/[^\s"'<>\]\[)\(,;]{3,}"#,
            #"[A-Za-z]:\\[^\s"'<>\]\[)\(,;]{3,}"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = regex.firstMatch(in: value, options: [], range: range),
                  let tokenRange = Range(match.range(at: 0), in: value) else {
                continue
            }
            var token = String(value[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            token = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>,;"))
            if let decoded = token.removingPercentEncoding,
               !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                token = decoded
            }
            if !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private func derivePathLabel(from rawPath: String) -> String? {
        let normalized = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else { return nil }

        let components = normalized
            .split(separator: "/")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }

        for component in components.reversed() {
            let lower = component.lowercased()
            if ["users", "library", "application support", "workspace", "storage", "state", "history", "sessions", "projects", "repos", "repositories", "repo", "tmp", "temp"].contains(lower) {
                continue
            }
            if component.range(of: #"\.[A-Za-z]{1,8}$"#, options: .regularExpression) != nil {
                continue
            }
            if component.range(of: #"^[0-9a-f-]{16,}$"#, options: .regularExpression) != nil {
                continue
            }
            return component
        }
        return nil
    }
}
