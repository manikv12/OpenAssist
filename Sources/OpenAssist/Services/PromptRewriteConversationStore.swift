import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import Vision

struct PromptRewriteConversationTurn: Codable, Equatable {
    let userText: String
    let assistantText: String
    let timestamp: Date
    let isSummary: Bool
    let sourceTurnCount: Int?
    let compactionVersion: Int?

    init(
        userText: String,
        assistantText: String,
        timestamp: Date = Date(),
        isSummary: Bool = false,
        sourceTurnCount: Int? = nil,
        compactionVersion: Int? = nil
    ) {
        self.userText = userText
        self.assistantText = assistantText
        self.timestamp = timestamp
        self.isSummary = isSummary
        self.sourceTurnCount = sourceTurnCount
        self.compactionVersion = compactionVersion
    }

    private enum CodingKeys: String, CodingKey {
        case userText
        case assistantText
        case timestamp
        case isSummary
        case sourceTurnCount
        case compactionVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userText = try container.decodeIfPresent(String.self, forKey: .userText) ?? ""
        assistantText = try container.decodeIfPresent(String.self, forKey: .assistantText) ?? ""
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        isSummary = try container.decodeIfPresent(Bool.self, forKey: .isSummary) ?? false
        sourceTurnCount = try container.decodeIfPresent(Int.self, forKey: .sourceTurnCount)
        compactionVersion = try container.decodeIfPresent(Int.self, forKey: .compactionVersion)
    }
}

struct PromptRewriteConversationContext: Codable, Equatable, Identifiable {
    let id: String
    let appName: String
    let bundleIdentifier: String
    let screenLabel: String
    let fieldLabel: String
    let logicalSurfaceKey: String
    let projectKey: String?
    let projectLabel: String?
    let identityKey: String?
    let identityType: String?
    let identityLabel: String?
    let nativeThreadKey: String?
    let people: [String]

    init(
        id: String,
        appName: String,
        bundleIdentifier: String,
        screenLabel: String,
        fieldLabel: String,
        logicalSurfaceKey: String = "",
        projectKey: String? = nil,
        projectLabel: String? = nil,
        identityKey: String? = nil,
        identityType: String? = nil,
        identityLabel: String? = nil,
        nativeThreadKey: String? = nil,
        people: [String] = []
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.screenLabel = screenLabel
        self.fieldLabel = fieldLabel
        self.logicalSurfaceKey = logicalSurfaceKey
        self.projectKey = projectKey
        self.projectLabel = projectLabel
        self.identityKey = identityKey
        self.identityType = identityType
        self.identityLabel = identityLabel
        self.nativeThreadKey = nativeThreadKey
        self.people = people
    }

    var displayName: String {
        if Self.isCodexConversation(appName: appName, bundleIdentifier: bundleIdentifier) {
            return appName
        }
        let normalizedProject = projectLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedIdentity = identityLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedScreen = Self.displayScreenLabel(
            screenLabel,
            projectLabel: normalizedProject,
            identityLabel: normalizedIdentity
        )
        let normalizedField = fieldLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        var segments: [String] = [appName]
        if Self.isMeaningfulProjectLabel(normalizedProject) {
            segments.append(normalizedProject)
        }
        if Self.isMeaningfulIdentityLabel(normalizedIdentity) {
            segments.append(normalizedIdentity)
        }
        if Self.isMeaningfulScreenLabel(normalizedScreen) {
            segments.append(normalizedScreen)
        }
        if Self.isMeaningfulFieldLabel(normalizedField) {
            segments.append(normalizedField)
        }
        return segments.joined(separator: " - ")
    }

    var providerContextLabel: String {
        if Self.isCodexConversation(appName: appName, bundleIdentifier: bundleIdentifier) {
            return appName
        }
        let normalizedProject = projectLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedIdentity = identityLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedScreen = screenLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedField = fieldLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        var segments: [String] = [appName]
        if Self.isMeaningfulProjectLabel(normalizedProject) {
            segments.append("project: \(normalizedProject)")
        }
        if Self.isMeaningfulIdentityLabel(normalizedIdentity) {
            segments.append("identity: \(normalizedIdentity)")
        }
        if Self.isMeaningfulScreenLabel(normalizedScreen) {
            segments.append("screen: \(normalizedScreen)")
        }
        if Self.isMeaningfulFieldLabel(normalizedField) {
            segments.append("field: \(normalizedField)")
        }
        return segments.joined(separator: ", ")
    }

    private static func isCodexConversation(appName: String, bundleIdentifier: String) -> Bool {
        let normalizedBundle = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedBundle == "com.openai.codex" {
            return true
        }
        return appName.localizedCaseInsensitiveContains("codex")
    }

    private static func isMeaningfulProjectLabel(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let lowered = normalized.lowercased()
        if lowered == "unknown project" || lowered == "current screen" || lowered == "focused input" {
            return false
        }
        if normalized.count > 96 {
            return false
        }
        return true
    }

    private static func isMeaningfulIdentityLabel(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let lowered = normalized.lowercased()
        if lowered == "unknown identity" || lowered == "unknown channel" || lowered == "unknown chat" {
            return false
        }
        return true
    }

    private static func isMeaningfulScreenLabel(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let lowered = normalized.lowercased()
        if lowered == "current screen" {
            return false
        }
        return true
    }

    private static func isMeaningfulFieldLabel(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let lowered = normalized.lowercased()
        let genericFields: Set<String> = [
            "focused input",
            "type a message",
            "message",
            "input"
        ]
        return !genericFields.contains(lowered)
    }

    private static func displayScreenLabel(
        _ value: String,
        projectLabel: String,
        identityLabel: String
    ) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        let lowered = normalized.lowercased()
        let loweredProject = projectLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let loweredIdentity = identityLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !loweredProject.isEmpty {
            let duplicateProjectPrefix = "project: \(loweredProject)"
            if lowered == duplicateProjectPrefix {
                return ""
            }
            if lowered.hasPrefix(duplicateProjectPrefix + " |"),
               let threadSegment = normalized
                .components(separatedBy: "|")
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { $0.lowercased().hasPrefix("thread:") }) {
                return threadSegment
            }
        }

        if !loweredIdentity.isEmpty {
            let duplicateIdentityPrefix = "identity: \(loweredIdentity)"
            if lowered == duplicateIdentityPrefix {
                return ""
            }
        }

        return normalized
    }
}

struct PromptRewriteConversationContextSummary: Identifiable, Equatable {
    let id: String
    let displayName: String
    let appName: String
    let screenLabel: String
    let fieldLabel: String
    let projectLabel: String?
    let identityLabel: String?
    let lastUpdatedAt: Date
    let turnCount: Int
}

struct PromptRewriteConversationContextDetail: Identifiable, Equatable {
    let context: PromptRewriteConversationContext
    let turns: [PromptRewriteConversationTurn]
    let lastUpdatedAt: Date

    var id: String { context.id }

    var totalTurnCount: Int {
        turns.count
    }

    var summaryTurnCount: Int {
        turns.filter(\.isSummary).count
    }

    var exchangeTurnCount: Int {
        turns.filter { !$0.isSummary }.count
    }

    var estimatedCharacterCount: Int {
        turns.reduce(into: 0) { partial, turn in
            partial += turn.userText.count
            partial += turn.assistantText.count
        }
    }

    var estimatedTokenCount: Int {
        max(0, Int((Double(estimatedCharacterCount) / 4).rounded()))
    }
}

struct PromptRewriteConversationCompactionReport: Equatable {
    let contextID: String
    let previousTurnCount: Int
    let compactedTurnCount: Int
    let newTurnCount: Int
}

enum ConversationClarificationKind: String, Codable, Equatable {
    case projectExact
    case projectAmbiguous
    case personExact
    case personAmbiguous

    var isExact: Bool {
        switch self {
        case .projectExact, .personExact:
            return true
        case .projectAmbiguous, .personAmbiguous:
            return false
        }
    }
}

struct ConversationClarificationCandidate: Equatable, Identifiable {
    let canonicalKey: String
    let label: String
    let appName: String
    let bundleIdentifier: String
    let similarity: Double
    let lastActivityAt: Date

    var id: String { canonicalKey }
}

struct ConversationClarificationPrompt: Equatable, Identifiable {
    let kind: ConversationClarificationKind
    let currentKey: String
    let currentLabel: String
    let currentBundleIdentifier: String
    let subjectKey: String
    let candidates: [ConversationClarificationCandidate]

    var id: String {
        let candidateSeed = candidates.map(\.canonicalKey).joined(separator: ",")
        return "\(kind.rawValue)|\(currentBundleIdentifier)|\(currentKey)|\(subjectKey)|\(candidateSeed)"
    }

    var primaryCandidate: ConversationClarificationCandidate? {
        candidates.first
    }
}

enum ConversationClarificationDecision: String, Codable, Equatable {
    case link
    case keepSeparate
    case dismiss
}

struct DeterministicConversationMappingCandidate: Equatable {
    enum MatchAxis: String {
        case project
        case person
    }

    enum MatchType: String {
        case exact
        case highSimilar = "high-similar"
    }

    let prompt: ConversationClarificationPrompt
    let candidateKey: String
    let candidateLabel: String
    let candidateBundleIdentifier: String
    let confidence: Double
    let matchAxis: MatchAxis
    let matchType: MatchType
}

@MainActor
final class PromptRewriteConversationStore: ObservableObject {
    static let shared = PromptRewriteConversationStore()

    struct RequestContext {
        let context: PromptRewriteConversationContext
        let history: [PromptRewriteConversationTurn]
        let usesPinnedContext: Bool
    }

    private struct StoredContext {
        var context: PromptRewriteConversationContext
        var turns: [PromptRewriteConversationTurn]
        var lastUpdatedAt: Date
        var tupleKey: ConversationThreadTupleKey
        var totalExchangeTurns: Int
    }

    @Published private(set) var contextSummaries: [PromptRewriteConversationContextSummary] = []

    private let maxStoredContexts = 24
    private let maxStoredTurnsPerContext = 120
    private let maxRelevantExchangeTurnsForPrompt = 5
    private let minRecentExchangeTurnsForPrompt = 3
    private let maxRecentExchangeTurnsForPrompt = 5
    private let primaryPromptHistoryTurnBudget = 3
    private let linkedPromptHistoryTurnBudget = 2
    private let browserHistoryPinnedRecentTurns = 2
    private let browserHistoryMinimumContextTurns = 3
    private let browserHistoryKeywordLimit = 24
    private let autoCompactionExchangeThreshold = 40
    private let autoCompactionRetainedExchangeTurns = 8
    private let maxPromptContextCharacters = 1_800
    private let expiredHandoffNoAnchorMaxAgeSeconds: TimeInterval = 6 * 60 * 60
    private let expiredSummaryMergeNoAnchorMaxAgeSeconds: TimeInterval = 2 * 60 * 60
    private let compactionVersion = 1
    private let expiredSummaryAITimeoutSeconds = 60
    private let expiredSummaryRetentionDays = 30
    private let sqliteStartupThreadScanMultiplier = 4
    private let sqliteStartupThreadScanHardLimit = 120
    private let duplicateMergeThreadScanMultiplier = 4
    private let duplicateMergeThreadScanHardLimit = 120
    private let codexProjectCorrectionMaxAgeSeconds: TimeInterval = 6 * 60 * 60
    private let codexConversationScreenLabel = "Current Screen"
    private let codexConversationProjectKey = "project:codex-app"
    private let codexConversationProjectLabel = "Unknown Project"
    private let codexConversationIdentityKey = "identity:codex-app"
    private let codexConversationIdentityType = "unknown"
    private let codexConversationIdentityLabel = "Unknown Identity"
    private let codexConversationNativeThreadKey = "thread:codex-app"
    private let clarificationSimilarityThreshold = 0.92
    private let deterministicMappingSimilarityThreshold = 0.94
    private let clarificationCandidateLimit = 3
    private let mappingRuleIDPrefixManual = "map-manual-"
    private let mappingRuleIDPrefixAI = "map-ai-"
    private let mappingRuleIDPrefixDeterministic = "map-deterministic-"
    private let mappingRuleIDPrefixLegacy = "disambiguation-"
    private let aliasMappingIDPrefix = "tag-alias|"
    private let redirectWriteFlagUserDefaultsKey = "feature.conversation.redirectWrites.enabled"
    private let redirectWriteFlagEnvironmentKey = "OPENASSIST_CONVERSATION_REDIRECT_WRITES_ENABLED"
    private let expiredHandoffTopicAnchorNoiseTokens: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into",
        "about", "what", "when", "where", "which", "while", "just",
        "only", "page", "screen", "project", "context", "goal",
        "accomplished", "handoff", "user", "users", "app", "issue",
        "fix", "check", "make", "using", "should", "would", "could",
        "can", "not", "too", "very", "more", "less", "same",
        "conversation", "history", "recent", "turns", "summary"
    ]
    private let sqliteStoreFactory: () throws -> MemorySQLiteStore
    private let tagInferenceService: ConversationTagInferenceService

    private var contextsByID: [String: StoredContext] = [:]
    private var contextIDByTuple: [ConversationThreadTupleKey: String] = [:]
    private var sqliteStore: MemorySQLiteStore?
    private var pendingDuplicateMergeContextIDs: Set<String> = []

    private enum ClarificationAxis {
        case project
        case person

        var aliasType: String {
            switch self {
            case .project:
                return "project"
            case .person:
                return "identity"
            }
        }
    }

    private enum ClarificationRuleResolution {
        case link(canonicalKey: String?)
        case keepSeparate
    }

    private struct ClarificationRankedCandidate {
        let candidate: ConversationClarificationCandidate
        let isExact: Bool
    }

    private init(
        sqliteStoreFactory: @escaping () throws -> MemorySQLiteStore = { try MemorySQLiteStore() },
        tagInferenceService: ConversationTagInferenceService = .shared
    ) {
        self.sqliteStoreFactory = sqliteStoreFactory
        self.tagInferenceService = tagInferenceService
        loadFromSQLite()
        refreshSummaries()
    }

    static func makeForTesting(
        sqliteStoreFactory: @escaping () throws -> MemorySQLiteStore,
        tagInferenceService: ConversationTagInferenceService = .shared
    ) -> PromptRewriteConversationStore {
        PromptRewriteConversationStore(
            sqliteStoreFactory: sqliteStoreFactory,
            tagInferenceService: tagInferenceService
        )
    }

    func prepareRequestContext(
        capturedContext: PromptRewriteConversationContext,
        userText: String = "",
        timeoutMinutes: Double,
        turnLimit: Int,
        pinnedContextID: String?
    ) -> RequestContext {
        pruneStaleContexts(timeoutMinutes: timeoutMinutes)
        let store = resolvedSQLiteStore()
        let normalizedRequestTurnLimit = normalizedTurnLimit(turnLimit)

        let normalizedPinnedID = pinnedContextID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPinnedID: String?
        if let normalizedPinnedID, !normalizedPinnedID.isEmpty {
            resolvedPinnedID = resolvedConversationThreadIDWithRedirect(
                normalizedPinnedID,
                store: store
            )
        } else {
            resolvedPinnedID = nil
        }
        let pinnedContext: StoredContext?
        if let resolvedPinnedID, !resolvedPinnedID.isEmpty {
            if let inMemoryPinned = contextsByID[resolvedPinnedID] {
                pinnedContext = inMemoryPinned
            } else if let store {
                pinnedContext = loadStoredContextFromSQLite(
                    threadID: resolvedPinnedID,
                    store: store
                )
            } else {
                pinnedContext = nil
            }
        } else {
            pinnedContext = nil
        }

        let resolvedContext: PromptRewriteConversationContext
        let usesPinnedContext: Bool
        var history: [PromptRewriteConversationTurn]
        var resolutionSource: String
        var expiredHandoffRecordToConsume: ExpiredConversationContextRecord?
        let resolvedTupleKey: ConversationThreadTupleKey
        var codexProjectCorrectionApplied = false
        if let pinnedContext {
            resolvedContext = pinnedContext.context
            usesPinnedContext = true
            history = mergedRequestHistory(
                for: resolvedContext,
                limit: normalizedRequestTurnLimit,
                userText: userText
            )
            resolutionSource = "pinned"
            resolvedTupleKey = pinnedContext.tupleKey
        } else {
            var inferred = canonicalizedTags(
                tagInferenceService.inferTags(
                    capturedContext: capturedContext,
                    userText: ""
                )
            )
            if let store {
                inferred = reuseKnownCodexProjectIfNeeded(
                    capturedContext: capturedContext,
                    tags: inferred,
                    store: store
                )
            }
            let tupleKey = tagInferenceService.tupleKey(
                capturedContext: capturedContext,
                tags: inferred
            )
            if let store {
                codexProjectCorrectionApplied = attemptCodexProjectCorrectionIfNeeded(
                    capturedContext: capturedContext,
                    tags: inferred,
                    tupleKey: tupleKey,
                    store: store
                )
            }
            let resolvedExistingID = contextIDByTuple[tupleKey].map {
                resolvedConversationThreadIDWithRedirect(
                    $0,
                    store: store
                )
            }
            if let resolvedExistingID, !resolvedExistingID.isEmpty,
               var existing = contextsByID[resolvedExistingID] {
                contextIDByTuple[tupleKey] = resolvedExistingID
                let refreshedContext = tupleContext(
                    baseContext: capturedContext,
                    tupleKey: tupleKey,
                    tags: inferred,
                    threadID: existing.context.id
                )
                existing.context = refreshedContext
                existing.tupleKey = tupleKey
                contextsByID[resolvedExistingID] = existing
                resolvedContext = refreshedContext
                history = mergedRequestHistory(
                    for: resolvedContext,
                    limit: normalizedRequestTurnLimit,
                    userText: userText
                )
                resolutionSource = "in-memory"
                resolvedTupleKey = tupleKey
            } else if let store,
                      let thread = try? store.fetchConversationThread(
                          bundleID: tupleKey.bundleID,
                          logicalSurfaceKey: tupleKey.logicalSurfaceKey,
                          projectKey: tupleKey.projectKey,
                          identityKey: tupleKey.identityKey,
                          nativeThreadKey: tupleKey.nativeThreadKey
                      ) {
                let redirectedThreadID = resolvedConversationThreadIDWithRedirect(
                    thread.id,
                    store: store
                )
                let resolvedThread = (redirectedThreadID.caseInsensitiveCompare(thread.id) == .orderedSame)
                    ? thread
                    : ((try? store.fetchConversationThread(id: redirectedThreadID)) ?? thread)
                let resolvedLoadedContext = tupleContext(
                    baseContext: capturedContext,
                    tupleKey: tupleKey,
                    tags: inferred,
                    threadID: resolvedThread.id
                )
                let loadedTurns = ((try? store.fetchConversationTurns(threadID: resolvedThread.id, limit: maxStoredTurnsPerContext)) ?? [])
                    .compactMap(conversationTurn(from:))
                let loaded = StoredContext(
                    context: resolvedLoadedContext,
                    turns: Array(loadedTurns.suffix(maxStoredTurnsPerContext)),
                    lastUpdatedAt: resolvedThread.lastActivityAt,
                    tupleKey: tupleKey,
                    totalExchangeTurns: max(
                        resolvedThread.totalExchangeTurns,
                        loadedTurns.filter { !$0.isSummary }.count
                    )
                )
                contextsByID[resolvedThread.id] = loaded
                contextIDByTuple[tupleKey] = resolvedThread.id
                resolvedContext = resolvedLoadedContext
                history = mergedRequestHistory(
                    for: resolvedContext,
                    limit: normalizedRequestTurnLimit,
                    userText: userText
                )
                resolutionSource = (resolvedThread.id == thread.id) ? "sqlite" : "sqlite-redirect"
                resolvedTupleKey = tupleKey
            } else {
                let threadID = tagInferenceService.threadID(for: tupleKey)
                resolvedContext = tupleContext(
                    baseContext: capturedContext,
                    tupleKey: tupleKey,
                    tags: inferred,
                    threadID: threadID
                )
                history = []
                resolutionSource = "new"
                resolvedTupleKey = tupleKey
            }
            usesPinnedContext = false
        }

        if codexProjectCorrectionApplied {
            resolutionSource += "+codex-project-corrected"
        }

        if promptRewriteConversationHistoryEnabled,
           let store {
            let crossIDESharingEnabled = promptRewriteCrossIDEConversationSharingEnabled
            let scopeKeys = scopeKeysForExpiredHandoffLookup(
                context: resolvedContext,
                crossIDESharingEnabled: crossIDESharingEnabled
            )
            let bundleIDConstraint = crossIDESharingEnabled
                ? nil
                : resolvedContext.bundleIdentifier
            var expiredRecord: ExpiredConversationContextRecord?
            for scopeKey in scopeKeys {
                guard let candidate = try? store.fetchLatestExpiredConversationContext(
                    scopeKey: scopeKey,
                    bundleIDConstraint: bundleIDConstraint,
                    includeConsumed: true
                ) else {
                    continue
                }
                if let existing = expiredRecord {
                    if candidate.expiredAt > existing.expiredAt {
                        expiredRecord = candidate
                    }
                } else {
                    expiredRecord = candidate
                }
            }

            if let expiredRecord {
                let reuseDecision = expiredHandoffReuseDecision(
                    for: expiredRecord,
                    userText: userText,
                    hasActiveHistory: !history.isEmpty
                )
                if reuseDecision.shouldUse {
                    if history.isEmpty {
                        let handoffHistory = expiredHandoffHistory(
                            from: expiredRecord,
                            limit: normalizedRequestTurnLimit
                        )
                        if !handoffHistory.isEmpty {
                            history = handoffHistory
                            resolutionSource += "+expired-handoff"
                            expiredHandoffRecordToConsume = expiredRecord
                        }
                    } else {
                        let mergedWithSummary = historyWithPreviousSummary(
                            history,
                            from: expiredRecord,
                            limit: normalizedRequestTurnLimit
                        )
                        if mergedWithSummary.count != history.count || mergedWithSummary != history {
                            history = mergedWithSummary
                            resolutionSource += "+expired-summary"
                        }
                    }
                } else {
                    resolutionSource += "+expired-skipped"
                    CrashReporter.logInfo(
                        """
                        Prompt rewrite expired handoff skipped \
                        reason=\(reuseDecision.reason) \
                        age_seconds=\(reuseDecision.ageSeconds) \
                        topic_anchor=\(reuseDecision.hasTopicAnchor)
                        """
                    )
                }
            }
        }

        if !usesPinnedContext,
           tagInferenceService.shouldSuppressUnknownCodingHistory(
               bundleID: capturedContext.bundleIdentifier,
               appName: capturedContext.appName,
               projectKey: resolvedTupleKey.projectKey,
               identityKey: resolvedTupleKey.identityKey
           ),
           !history.isEmpty {
            history = []
            resolutionSource += "+suppressed-unknown-coding-history"
            CrashReporter.logInfo(
                """
                Prompt rewrite history suppressed \
                bundle=\(resolvedTupleKey.bundleID) \
                project=\(resolvedTupleKey.projectKey) \
                identity=\(resolvedTupleKey.identityKey)
                """
            )
        }

        if let expiredHandoffRecordToConsume,
           !history.isEmpty,
           let store {
            _ = try? store.markExpiredConversationContextConsumed(
                id: expiredHandoffRecordToConsume.id,
                consumedByThreadID: resolvedContext.id,
                at: Date()
            )
        }

        CrashReporter.logInfo(
            """
            Prompt rewrite context resolved \
            source=\(resolutionSource) \
            contextID=\(resolvedContext.id) \
            app=\(resolvedContext.appName) \
            bundle=\(resolvedTupleKey.bundleID) \
            project=\(resolvedTupleKey.projectKey) \
            identity=\(resolvedTupleKey.identityKey) \
            historyTurns=\(history.count)
            """
        )

        return RequestContext(
            context: resolvedContext,
            history: history,
            usesPinnedContext: usesPinnedContext
        )
    }

    func nextClarificationPrompt(
        capturedContext: PromptRewriteConversationContext,
        userText: String
    ) -> ConversationClarificationPrompt? {
        guard FeatureFlags.conversationTupleSQLiteEnabled else {
            return nil
        }
        guard let store = resolvedSQLiteStore() else {
            return nil
        }

        let inferredTags = canonicalizedTags(
            tagInferenceService.inferTags(
                capturedContext: capturedContext,
                userText: userText
            )
        )
        let currentTupleKey = tagInferenceService.tupleKey(
            capturedContext: capturedContext,
            tags: inferredTags
        )
        let normalizedCurrentBundle = normalizedClarificationBundle(currentTupleKey.bundleID)
        guard !normalizedCurrentBundle.isEmpty else {
            return nil
        }

        let scanLimit = min(
            sqliteStartupThreadScanHardLimit,
            max(maxStoredContexts, maxStoredContexts * sqliteStartupThreadScanMultiplier)
        )
        let allThreads = (try? store.fetchConversationThreads(limit: scanLimit)) ?? []
        guard !allThreads.isEmpty else {
            return nil
        }

        let crossAppThreads = allThreads.filter { thread in
            normalizedClarificationBundle(thread.bundleID) != normalizedCurrentBundle
        }
        guard !crossAppThreads.isEmpty else {
            return nil
        }

        let currentIdentityType = normalizedClarificationIdentityType(inferredTags.identityType)
        if currentIdentityType == "person",
           let personPrompt = clarificationPrompt(
               axis: .person,
               currentKey: inferredTags.identityKey,
               currentLabel: inferredTags.identityLabel,
               currentBundleIdentifier: normalizedCurrentBundle,
               threads: crossAppThreads,
               store: store
           ) {
            return personPrompt
        }

        if isMeaningfulProjectClarificationKey(inferredTags.projectKey),
           let projectPrompt = clarificationPrompt(
               axis: .project,
               currentKey: inferredTags.projectKey,
               currentLabel: inferredTags.projectLabel,
               currentBundleIdentifier: normalizedCurrentBundle,
               threads: crossAppThreads,
               store: store
           ) {
            return projectPrompt
        }

        return nil
    }

    func nextDeterministicMappingCandidate(
        capturedContext: PromptRewriteConversationContext,
        userText: String
    ) -> DeterministicConversationMappingCandidate? {
        guard FeatureFlags.conversationTupleSQLiteEnabled else {
            return nil
        }
        guard let store = resolvedSQLiteStore() else {
            return nil
        }

        let inferredTags = canonicalizedTags(
            tagInferenceService.inferTags(
                capturedContext: capturedContext,
                userText: userText
            )
        )
        let currentTupleKey = tagInferenceService.tupleKey(
            capturedContext: capturedContext,
            tags: inferredTags
        )
        let normalizedCurrentBundle = normalizedClarificationBundle(currentTupleKey.bundleID)
        guard !normalizedCurrentBundle.isEmpty else {
            return nil
        }

        let scanLimit = min(
            sqliteStartupThreadScanHardLimit,
            max(maxStoredContexts, maxStoredContexts * sqliteStartupThreadScanMultiplier)
        )
        let allThreads = (try? store.fetchConversationThreads(limit: scanLimit)) ?? []
        guard !allThreads.isEmpty else {
            return nil
        }

        let crossAppThreads = allThreads.filter { thread in
            normalizedClarificationBundle(thread.bundleID) != normalizedCurrentBundle
        }
        guard !crossAppThreads.isEmpty else {
            return nil
        }

        let currentIdentityType = normalizedClarificationIdentityType(inferredTags.identityType)
        let personPrompt: ConversationClarificationPrompt?
        if currentIdentityType == "person" {
            personPrompt = clarificationPrompt(
                axis: .person,
                currentKey: inferredTags.identityKey,
                currentLabel: inferredTags.identityLabel,
                currentBundleIdentifier: normalizedCurrentBundle,
                threads: crossAppThreads,
                store: store
            )
        } else {
            personPrompt = nil
        }

        let projectPrompt: ConversationClarificationPrompt?
        if isMeaningfulProjectClarificationKey(inferredTags.projectKey) {
            projectPrompt = clarificationPrompt(
                axis: .project,
                currentKey: inferredTags.projectKey,
                currentLabel: inferredTags.projectLabel,
                currentBundleIdentifier: normalizedCurrentBundle,
                threads: crossAppThreads,
                store: store
            )
        } else {
            projectPrompt = nil
        }

        if deterministicPromptsConflict(
            personPrompt: personPrompt,
            projectPrompt: projectPrompt
        ) {
            return nil
        }

        let personCandidate = personPrompt.flatMap { prompt in
            deterministicMappingCandidate(from: prompt, axis: .person)
        }
        let projectCandidate = projectPrompt.flatMap { prompt in
            deterministicMappingCandidate(from: prompt, axis: .project)
        }

        switch (personCandidate, projectCandidate) {
        case let (lhs?, rhs?):
            return shouldPreferDeterministicCandidate(lhs, over: rhs) ? lhs : rhs
        case let (candidate?, nil), let (nil, candidate?):
            return candidate
        case (nil, nil):
            return nil
        }
    }

    func applyClarificationDecision(
        _ decision: ConversationClarificationDecision,
        for prompt: ConversationClarificationPrompt,
        source: ConversationContextMappingSource = .manual
    ) {
        guard decision != .dismiss else {
            return
        }
        guard let candidate = prompt.primaryCandidate else {
            return
        }
        guard let store = resolvedSQLiteStore() else {
            return
        }

        let axis = clarificationAxis(for: prompt.kind)
        let normalizedCurrentKey = normalizedClarificationKey(prompt.currentKey)
        let normalizedCandidateKey = normalizedClarificationKey(candidate.canonicalKey)
        guard !normalizedCurrentKey.isEmpty, !normalizedCandidateKey.isEmpty else {
            return
        }
        let normalizedCurrentBundle = normalizedClarificationBundle(prompt.currentBundleIdentifier)
        let normalizedCandidateBundle = normalizedClarificationBundle(candidate.bundleIdentifier)
        let subjectKey = normalizedClarificationKey(prompt.subjectKey)
        guard !normalizedCurrentBundle.isEmpty,
              !normalizedCandidateBundle.isEmpty,
              !subjectKey.isEmpty else {
            return
        }

        let appPairKey = store.conversationDisambiguationAppPairKey(
            normalizedCurrentBundle,
            normalizedCandidateBundle
        )
        let contextScopeKey = prompt.kind.isExact ? nil : normalizedCandidateKey
        let ruleType = clarificationRuleType(for: axis)

        switch decision {
        case .dismiss:
            return
        case .keepSeparate:
            upsertContextMappingDecision(
                mappingType: ruleType,
                appPairKey: appPairKey,
                subjectKey: subjectKey,
                contextScopeKey: contextScopeKey,
                decision: .separate,
                canonicalKey: nil,
                source: source
            )
        case .link:
            upsertContextMappingDecision(
                mappingType: ruleType,
                appPairKey: appPairKey,
                subjectKey: subjectKey,
                contextScopeKey: contextScopeKey,
                decision: .link,
                canonicalKey: normalizedCandidateKey,
                source: source
            )
            try? store.upsertConversationTagAlias(
                aliasType: axis.aliasType,
                aliasKey: normalizedCurrentKey,
                canonicalKey: normalizedCandidateKey
            )
        }
    }

    func fetchContextMappings(limit: Int = 400) -> [ConversationContextMappingRow] {
        guard let store = resolvedSQLiteStore() else {
            return []
        }

        let normalizedLimit = max(1, min(limit, 2_000))
        let rules = (try? store.fetchConversationDisambiguationRules(limit: normalizedLimit)) ?? []
        let aliases = (try? store.fetchConversationTagAliases(limit: normalizedLimit)) ?? []

        var rows = rules.map { rule in
            ConversationContextMappingRow(
                id: rule.id,
                mappingType: rule.ruleType.rawValue,
                appPairKey: rule.appPairKey,
                subjectKey: rule.subjectKey,
                contextScopeKey: rule.contextScopeKey,
                decision: rule.decision,
                canonicalKey: rule.canonicalKey,
                source: mappingSource(forRuleID: rule.id),
                updatedAt: rule.updatedAt
            )
        }

        rows.append(contentsOf: aliases.map { alias in
            ConversationContextMappingRow(
                id: tagAliasMappingID(aliasType: alias.aliasType, aliasKey: alias.aliasKey),
                mappingType: "alias:\(alias.aliasType)",
                appPairKey: "global",
                subjectKey: alias.aliasKey,
                contextScopeKey: nil,
                decision: .link,
                canonicalKey: alias.canonicalKey,
                source: .legacy,
                updatedAt: alias.updatedAt
            )
        })

        rows.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
        if rows.count > normalizedLimit {
            rows = Array(rows.prefix(normalizedLimit))
        }
        return rows
    }

    func upsertContextMappingDecision(
        mappingType: ConversationDisambiguationRuleType,
        appPairKey: String,
        subjectKey: String,
        contextScopeKey: String?,
        decision: ConversationDisambiguationDecision,
        canonicalKey: String?,
        source: ConversationContextMappingSource
    ) {
        guard let store = resolvedSQLiteStore() else {
            return
        }

        let normalizedAppPairKey = normalizedDisambiguationAppPairKey(appPairKey)
        let normalizedSubjectKey = normalizedClarificationKey(subjectKey)
        let normalizedScopeKey = normalizedClarificationOptionalKey(contextScopeKey)
        let normalizedCanonicalKey = normalizedClarificationOptionalKey(canonicalKey)
        let resolvedCanonicalKey = (decision == .link) ? normalizedCanonicalKey : nil

        guard !normalizedAppPairKey.isEmpty, !normalizedSubjectKey.isEmpty else {
            return
        }

        let ruleID = disambiguationRuleID(
            ruleType: mappingType,
            appPairKey: normalizedAppPairKey,
            subjectKey: normalizedSubjectKey,
            contextScopeKey: normalizedScopeKey,
            source: source
        )
        let existing = try? store.fetchConversationDisambiguationRule(
            ruleType: mappingType,
            appPairKey: normalizedAppPairKey,
            subjectKey: normalizedSubjectKey,
            contextScopeKey: normalizedScopeKey
        )
        if let existing,
           existing.id.caseInsensitiveCompare(ruleID) != .orderedSame {
            try? store.deleteConversationDisambiguationRule(id: existing.id)
        }

        let now = Date()
        try? store.upsertConversationDisambiguationRule(
            ConversationDisambiguationRuleRecord(
                id: ruleID,
                ruleType: mappingType,
                appPairKey: normalizedAppPairKey,
                subjectKey: normalizedSubjectKey,
                contextScopeKey: normalizedScopeKey,
                decision: decision,
                canonicalKey: resolvedCanonicalKey,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
        )
    }

    func removeContextMapping(id: String) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            return
        }
        guard let store = resolvedSQLiteStore() else {
            return
        }

        if let aliasComponents = decodeTagAliasMappingID(normalizedID) {
            try? store.deleteConversationTagAlias(
                aliasType: aliasComponents.aliasType,
                aliasKey: aliasComponents.aliasKey
            )
            return
        }

        try? store.deleteConversationDisambiguationRule(id: normalizedID)
    }

    func resolveLinkedContextIDs(for context: PromptRewriteConversationContext) -> [String] {
        if contextsByID[context.id] == nil,
           let store = resolvedSQLiteStore() {
            _ = loadStoredContextFromSQLite(threadID: context.id, store: store)
        }
        return linkedContextIDs(
            for: context,
            excludingContextID: context.id
        )
    }

    func activePromptHistory(
        for contextID: String,
        userText: String,
        limit: Int
    ) -> [PromptRewriteConversationTurn] {
        let normalizedContextID = contextID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContextID.isEmpty else {
            return []
        }

        if contextsByID[normalizedContextID] == nil,
           let store = resolvedSQLiteStore() {
            _ = loadStoredContextFromSQLite(threadID: normalizedContextID, store: store)
        }
        return promptHistory(
            for: normalizedContextID,
            limit: normalizedTurnLimit(limit),
            userText: userText
        )
    }

    func recordTurn(
        originalText: String,
        finalText: String,
        context: PromptRewriteConversationContext,
        timeoutMinutes: Double,
        maxTurns: Int
    ) {
        let normalizedOriginal = collapsedWhitespace(originalText)
        let normalizedFinal = sanitizedAssistantTurnText(
            finalText,
            originalUserText: normalizedOriginal
        )
        guard !normalizedOriginal.isEmpty, !normalizedFinal.isEmpty else {
            return
        }

        pruneStaleContexts(timeoutMinutes: timeoutMinutes)

        let now = Date()
        let inferredTags = resolvedTags(
            from: context,
            originalText: normalizedOriginal,
            finalText: normalizedFinal
        )
        let tupleKey = tagInferenceService.tupleKey(
            capturedContext: context,
            tags: inferredTags
        )
        let threadID = tagInferenceService.threadID(for: tupleKey)
        let resolvedContext = tupleContext(
            baseContext: context,
            tupleKey: tupleKey,
            tags: inferredTags,
            threadID: threadID
        )
        let isNewContext = contextsByID[threadID] == nil

        var stored = contextsByID[threadID] ?? StoredContext(
            context: resolvedContext,
            turns: [],
            lastUpdatedAt: now,
            tupleKey: tupleKey,
            totalExchangeTurns: 0
        )

        stored.context = resolvedContext
        stored.tupleKey = tupleKey
        stored.lastUpdatedAt = now
        let userSnippet = snippet(normalizedOriginal, limit: 420)
        let assistantSnippet = snippet(normalizedFinal, limit: 420)
        if let last = stored.turns.last,
           !last.isSummary,
           last.userText == userSnippet,
           last.assistantText == assistantSnippet {
            return
        }

        stored.turns.append(
            PromptRewriteConversationTurn(
                userText: userSnippet,
                assistantText: assistantSnippet,
                timestamp: now
            )
        )
        stored.totalExchangeTurns += 1

        let keepRecentTurns = normalizedTurnLimit(maxTurns)
        autoCompactContextIfNeeded(&stored)
        enforceHardTurnCap(&stored, keepRecentTurns: keepRecentTurns)

        contextsByID[threadID] = stored
        contextIDByTuple[tupleKey] = threadID
        if isNewContext {
            pendingDuplicateMergeContextIDs.insert(threadID)
        }
        let removedContextIDs = trimStoredContextsIfNeeded()
        persistContext(stored)
        for removedID in removedContextIDs {
            deleteContextFromSQLite(id: removedID)
        }
        refreshSummaries()
    }

    func clearContext(id: String) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        guard let removed = contextsByID.removeValue(forKey: normalizedID) else { return }
        contextIDByTuple.removeValue(forKey: removed.tupleKey)
        pendingDuplicateMergeContextIDs.remove(normalizedID)
        deleteContextFromSQLite(id: normalizedID)
        refreshSummaries()
    }

    func clearAll() {
        guard !contextsByID.isEmpty else { return }
        contextsByID.removeAll()
        contextIDByTuple.removeAll()
        pendingDuplicateMergeContextIDs.removeAll()
        clearAllContextsInSQLite()
        refreshSummaries()
    }

    func trimMemoryUsage(aggressive: Bool) {
        guard !contextsByID.isEmpty else { return }

        let keepContextCount = aggressive ? 6 : 12
        let keepTurnCount = aggressive ? 24 : 60

        let rankedIDs = contextsByID
            .sorted { lhs, rhs in
                lhs.value.lastUpdatedAt > rhs.value.lastUpdatedAt
            }
            .map(\.key)
        let keepIDs = Set(rankedIDs.prefix(keepContextCount))

        for id in rankedIDs where !keepIDs.contains(id) {
            if let removed = contextsByID.removeValue(forKey: id) {
                contextIDByTuple.removeValue(forKey: removed.tupleKey)
            }
            pendingDuplicateMergeContextIDs.remove(id)
        }

        for id in keepIDs {
            guard var stored = contextsByID[id],
                  stored.turns.count > keepTurnCount else {
                continue
            }
            stored.turns = Array(stored.turns.suffix(keepTurnCount))
            contextsByID[id] = stored
        }

        refreshSummaries()
    }

    func hasContext(id: String) -> Bool {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return false }
        return contextsByID[normalizedID] != nil
    }

    func contextDetails(timeoutMinutes: Double? = nil) -> [PromptRewriteConversationContextDetail] {
        if let timeoutMinutes {
            pruneStaleContexts(timeoutMinutes: timeoutMinutes)
        }

        return contextsByID
            .values
            .sorted { lhs, rhs in
                lhs.lastUpdatedAt > rhs.lastUpdatedAt
            }
            .map { stored in
                PromptRewriteConversationContextDetail(
                    context: stored.context,
                    turns: stored.turns,
                    lastUpdatedAt: stored.lastUpdatedAt
                )
            }
    }

    func contextDetail(id: String, timeoutMinutes: Double? = nil) -> PromptRewriteConversationContextDetail? {
        if let timeoutMinutes {
            pruneStaleContexts(timeoutMinutes: timeoutMinutes)
        }

        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
              let stored = contextsByID[normalizedID] else {
            return nil
        }

        return PromptRewriteConversationContextDetail(
            context: stored.context,
            turns: stored.turns,
            lastUpdatedAt: stored.lastUpdatedAt
        )
    }

    func serializedContextJSON(id: String) -> String? {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
              let stored = contextsByID[normalizedID] else {
            return nil
        }

        struct SerializedContextPayload: Codable {
            let context: PromptRewriteConversationContext
            let turns: [PromptRewriteConversationTurn]
            let lastUpdatedAt: Date
            let totalExchangeTurns: Int
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = SerializedContextPayload(
            context: stored.context,
            turns: stored.turns,
            lastUpdatedAt: stored.lastUpdatedAt,
            totalExchangeTurns: stored.totalExchangeTurns
        )
        guard let data = try? encoder.encode(payload),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    func compactContext(id: String, keepRecentTurns: Int) -> PromptRewriteConversationCompactionReport? {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
              var stored = contextsByID[normalizedID] else {
            return nil
        }

        guard let report = compactStoredContext(
            &stored,
            keepRecentTurns: keepRecentTurns,
            force: true,
            trigger: .manualCompaction
        ) else {
            return nil
        }

        contextsByID[normalizedID] = stored
        persistContext(stored)
        refreshSummaries()
        return report
    }

    func compactAllContexts(keepRecentTurns: Int) -> [PromptRewriteConversationCompactionReport] {
        var reports: [PromptRewriteConversationCompactionReport] = []
        let normalizedKeepRecentTurns = normalizedTurnLimit(keepRecentTurns)

        for contextID in contextsByID.keys.sorted() {
            guard var stored = contextsByID[contextID] else { continue }
            guard let report = compactStoredContext(
                &stored,
                keepRecentTurns: normalizedKeepRecentTurns,
                force: true,
                trigger: .manualCompaction
            ) else {
                continue
            }
            contextsByID[contextID] = stored
            reports.append(report)
        }

        guard !reports.isEmpty else { return [] }
        for report in reports {
            if let stored = contextsByID[report.contextID] {
                persistContext(stored)
            }
        }
        refreshSummaries()
        return reports
    }

    private func tupleContext(
        baseContext: PromptRewriteConversationContext,
        tupleKey: ConversationThreadTupleKey,
        tags: ConversationTupleTags,
        threadID: String
    ) -> PromptRewriteConversationContext {
        let normalizedValues = sanitizedCodexStoredContextValues(
            appName: baseContext.appName,
            screenLabel: baseContext.screenLabel,
            projectKey: tags.projectKey,
            projectLabel: tags.projectLabel,
            identityKey: tags.identityKey,
            identityType: tags.identityType,
            identityLabel: tags.identityLabel,
            nativeThreadKey: tags.nativeThreadKey
        )
        return PromptRewriteConversationContext(
            id: threadID,
            appName: baseContext.appName,
            bundleIdentifier: baseContext.bundleIdentifier,
            screenLabel: normalizedValues.screenLabel,
            fieldLabel: baseContext.fieldLabel,
            logicalSurfaceKey: tupleKey.logicalSurfaceKey,
            projectKey: normalizedValues.projectKey,
            projectLabel: normalizedValues.projectLabel,
            identityKey: normalizedValues.identityKey,
            identityType: normalizedValues.identityType,
            identityLabel: normalizedValues.identityLabel,
            nativeThreadKey: normalizedValues.nativeThreadKey,
            people: isCodexContext(baseContext) ? [] : tags.people
        )
    }

    private func canonicalizedTags(_ tags: ConversationTupleTags) -> ConversationTupleTags {
        guard let store = resolvedSQLiteStore() else {
            return tags
        }
        let normalizedProjectKey = tags.projectKey.lowercased()
        let normalizedIdentityKey = tags.identityKey.lowercased()
        var canonicalProject = normalizedProjectKey
        if let resolved = try? store.resolveConversationTagAlias(aliasType: "project", aliasKey: normalizedProjectKey),
           !resolved.isEmpty {
            canonicalProject = resolved
        }
        var canonicalIdentity = normalizedIdentityKey
        if let resolved = try? store.resolveConversationTagAlias(aliasType: "identity", aliasKey: normalizedIdentityKey),
           !resolved.isEmpty {
            canonicalIdentity = resolved
        }
        if canonicalProject != normalizedProjectKey {
            try? store.upsertConversationTagAlias(
                aliasType: "project",
                aliasKey: normalizedProjectKey,
                canonicalKey: canonicalProject
            )
        }
        if canonicalIdentity != normalizedIdentityKey {
            try? store.upsertConversationTagAlias(
                aliasType: "identity",
                aliasKey: normalizedIdentityKey,
                canonicalKey: canonicalIdentity
            )
        }
        return ConversationTupleTags(
            projectKey: canonicalProject,
            projectLabel: tags.projectLabel,
            identityKey: canonicalIdentity,
            identityType: tags.identityType,
            identityLabel: tags.identityLabel,
            people: tags.people,
            nativeThreadKey: tags.nativeThreadKey
        )
    }

    private func resolvedTags(
        from context: PromptRewriteConversationContext,
        originalText: String,
        finalText: String
    ) -> ConversationTupleTags {
        if let projectKey = context.projectKey,
           let projectLabel = context.projectLabel,
           let identityKey = context.identityKey,
           let identityType = context.identityType,
           let identityLabel = context.identityLabel {
            return canonicalizedTags(
                ConversationTupleTags(
                    projectKey: projectKey,
                    projectLabel: projectLabel,
                    identityKey: identityKey,
                    identityType: identityType,
                    identityLabel: identityLabel,
                    people: context.people,
                    nativeThreadKey: context.nativeThreadKey ?? ""
                )
            )
        }

        return canonicalizedTags(
            tagInferenceService.inferTags(
                capturedContext: context,
                userText: ""
            )
        )
    }

    private func clarificationPrompt(
        axis: ClarificationAxis,
        currentKey: String,
        currentLabel: String,
        currentBundleIdentifier: String,
        threads: [ConversationThreadRecord],
        store: MemorySQLiteStore
    ) -> ConversationClarificationPrompt? {
        let normalizedCurrentKey = normalizedClarificationKey(currentKey)
        guard !normalizedCurrentKey.isEmpty else {
            return nil
        }
        let normalizedCurrentLabel = comparableClarificationLabel(
            label: currentLabel,
            fallbackKey: normalizedCurrentKey
        )
        guard !normalizedCurrentLabel.isEmpty else {
            return nil
        }
        let subjectKey = normalizedClarificationKey(normalizedCurrentLabel)
        guard !subjectKey.isEmpty else {
            return nil
        }

        var rankedByCanonicalKey: [String: ClarificationRankedCandidate] = [:]
        var shouldSuppressPrompt = false

        for thread in threads {
            guard let (candidateKey, candidateLabel) = clarificationCandidateParts(for: axis, thread: thread) else {
                continue
            }

            let normalizedCandidateKey = normalizedClarificationKey(candidateKey)
            guard !normalizedCandidateKey.isEmpty else {
                continue
            }
            let canonicalCandidateKey = resolvedClarificationAliasKey(
                aliasType: axis.aliasType,
                key: normalizedCandidateKey,
                store: store
            )
            guard !canonicalCandidateKey.isEmpty,
                  canonicalCandidateKey != normalizedCurrentKey else {
                continue
            }

            if let existingRule = clarificationRuleResolution(
                axis: axis,
                currentBundleIdentifier: currentBundleIdentifier,
                subjectKey: subjectKey,
                currentKey: normalizedCurrentKey,
                candidateKey: canonicalCandidateKey,
                candidateBundleIdentifier: thread.bundleID,
                store: store
            ) {
                switch existingRule {
                case .keepSeparate:
                    continue
                case let .link(canonicalKey):
                    let resolvedCanonicalKey = normalizedClarificationKey(canonicalKey ?? canonicalCandidateKey)
                    guard !resolvedCanonicalKey.isEmpty else {
                        continue
                    }
                    try? store.upsertConversationTagAlias(
                        aliasType: axis.aliasType,
                        aliasKey: normalizedCurrentKey,
                        canonicalKey: resolvedCanonicalKey
                    )
                    shouldSuppressPrompt = true
                    continue
                }
            }

            let normalizedCandidateLabel = comparableClarificationLabel(
                label: candidateLabel,
                fallbackKey: canonicalCandidateKey
            )
            guard !normalizedCandidateLabel.isEmpty else {
                continue
            }

            let isExact = normalizedCandidateLabel == normalizedCurrentLabel
            let similarity = isExact
                ? 1
                : normalizedClarificationSimilarity(
                    normalizedCurrentLabel,
                    normalizedCandidateLabel
                )
            guard isExact || similarity >= clarificationSimilarityThreshold else {
                continue
            }

            let rankedCandidate = ClarificationRankedCandidate(
                candidate: ConversationClarificationCandidate(
                    canonicalKey: canonicalCandidateKey,
                    label: collapsedWhitespace(candidateLabel),
                    appName: collapsedWhitespace(thread.appName),
                    bundleIdentifier: normalizedClarificationBundle(thread.bundleID),
                    similarity: similarity,
                    lastActivityAt: thread.lastActivityAt
                ),
                isExact: isExact
            )

            if let existing = rankedByCanonicalKey[canonicalCandidateKey] {
                if shouldReplaceClarificationCandidate(existing, with: rankedCandidate) {
                    rankedByCanonicalKey[canonicalCandidateKey] = rankedCandidate
                }
            } else {
                rankedByCanonicalKey[canonicalCandidateKey] = rankedCandidate
            }
        }

        if shouldSuppressPrompt {
            return nil
        }

        let ranked = rankedByCanonicalKey.values.sorted { lhs, rhs in
            if lhs.isExact != rhs.isExact {
                return lhs.isExact && !rhs.isExact
            }
            if lhs.candidate.similarity != rhs.candidate.similarity {
                return lhs.candidate.similarity > rhs.candidate.similarity
            }
            if lhs.candidate.lastActivityAt != rhs.candidate.lastActivityAt {
                return lhs.candidate.lastActivityAt > rhs.candidate.lastActivityAt
            }
            return lhs.candidate.label.localizedCaseInsensitiveCompare(rhs.candidate.label) == .orderedAscending
        }
        guard !ranked.isEmpty else {
            return nil
        }

        let exactMatches = ranked.filter(\.isExact)
        let selected: [ClarificationRankedCandidate]
        let kind: ConversationClarificationKind
        if !exactMatches.isEmpty {
            selected = Array(exactMatches.prefix(clarificationCandidateLimit))
            kind = axis == .project ? .projectExact : .personExact
        } else {
            selected = Array(ranked.prefix(clarificationCandidateLimit))
            kind = axis == .project ? .projectAmbiguous : .personAmbiguous
        }

        let displayLabel = collapsedWhitespace(currentLabel)

        return ConversationClarificationPrompt(
            kind: kind,
            currentKey: normalizedCurrentKey,
            currentLabel: displayLabel.isEmpty
                ? readableClarificationLabel(from: normalizedCurrentKey)
                : displayLabel,
            currentBundleIdentifier: currentBundleIdentifier,
            subjectKey: subjectKey,
            candidates: selected.map(\.candidate)
        )
    }

    private func clarificationCandidateParts(
        for axis: ClarificationAxis,
        thread: ConversationThreadRecord
    ) -> (key: String, label: String)? {
        switch axis {
        case .project:
            guard isMeaningfulProjectClarificationKey(thread.projectKey) else {
                return nil
            }
            return (thread.projectKey, thread.projectLabel)
        case .person:
            guard normalizedClarificationIdentityType(thread.identityType) == "person" else {
                return nil
            }
            guard isMeaningfulPersonClarificationKey(thread.identityKey) else {
                return nil
            }
            return (thread.identityKey, thread.identityLabel)
        }
    }

    private func shouldReplaceClarificationCandidate(
        _ existing: ClarificationRankedCandidate,
        with candidate: ClarificationRankedCandidate
    ) -> Bool {
        if existing.isExact != candidate.isExact {
            return candidate.isExact
        }
        if existing.candidate.similarity != candidate.candidate.similarity {
            return candidate.candidate.similarity > existing.candidate.similarity
        }
        return candidate.candidate.lastActivityAt > existing.candidate.lastActivityAt
    }

    private func deterministicMappingCandidate(
        from prompt: ConversationClarificationPrompt,
        axis: ClarificationAxis
    ) -> DeterministicConversationMappingCandidate? {
        guard let primary = prompt.primaryCandidate else {
            return nil
        }
        let boundedConfidence = max(0, min(1, primary.similarity))
        let isExact = prompt.kind.isExact || boundedConfidence >= 0.999
        if !isExact && boundedConfidence < deterministicMappingSimilarityThreshold {
            return nil
        }
        return DeterministicConversationMappingCandidate(
            prompt: prompt,
            candidateKey: primary.canonicalKey,
            candidateLabel: primary.label,
            candidateBundleIdentifier: primary.bundleIdentifier,
            confidence: boundedConfidence,
            matchAxis: axis == .project ? .project : .person,
            matchType: isExact ? .exact : .highSimilar
        )
    }

    private func deterministicPromptsConflict(
        personPrompt: ConversationClarificationPrompt?,
        projectPrompt: ConversationClarificationPrompt?
    ) -> Bool {
        guard let personPrompt, let projectPrompt else {
            return false
        }
        let personBundles = deterministicHighConfidenceCandidateBundles(from: personPrompt)
        let projectBundles = deterministicHighConfidenceCandidateBundles(from: projectPrompt)
        guard !personBundles.isEmpty, !projectBundles.isEmpty else {
            return false
        }
        return personBundles.intersection(projectBundles).isEmpty
    }

    private func deterministicHighConfidenceCandidateBundles(
        from prompt: ConversationClarificationPrompt
    ) -> Set<String> {
        Set(
            prompt.candidates
                .filter { candidate in
                    let bounded = max(0, min(1, candidate.similarity))
                    return bounded >= deterministicMappingSimilarityThreshold || bounded >= 0.999
                }
                .map { normalizedClarificationBundle($0.bundleIdentifier) }
                .filter { !$0.isEmpty }
        )
    }

    private func shouldPreferDeterministicCandidate(
        _ lhs: DeterministicConversationMappingCandidate,
        over rhs: DeterministicConversationMappingCandidate
    ) -> Bool {
        if lhs.matchType != rhs.matchType {
            return lhs.matchType == .exact
        }
        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence
        }
        if lhs.matchAxis != rhs.matchAxis {
            return lhs.matchAxis == .person
        }
        return lhs.candidateLabel.localizedCaseInsensitiveCompare(rhs.candidateLabel) == .orderedAscending
    }

    private func clarificationRuleResolution(
        axis: ClarificationAxis,
        currentBundleIdentifier: String,
        subjectKey: String,
        currentKey: String,
        candidateKey: String,
        candidateBundleIdentifier: String,
        store: MemorySQLiteStore
    ) -> ClarificationRuleResolution? {
        let appPairKey = store.conversationDisambiguationAppPairKey(
            normalizedClarificationBundle(currentBundleIdentifier),
            normalizedClarificationBundle(candidateBundleIdentifier)
        )
        let normalizedSubjectKey = normalizedClarificationKey(subjectKey)
        let normalizedCandidateKey = normalizedClarificationKey(candidateKey)
        guard !appPairKey.isEmpty, !normalizedSubjectKey.isEmpty else {
            return nil
        }

        let scopedRule = try? store.fetchConversationDisambiguationRule(
            ruleType: clarificationRuleType(for: axis),
            appPairKey: appPairKey,
            subjectKey: normalizedSubjectKey,
            contextScopeKey: normalizedCandidateKey
        )
        if let scopedRule {
            switch scopedRule.decision {
            case .separate:
                return .keepSeparate
            case .link:
                return .link(canonicalKey: scopedRule.canonicalKey)
            }
        }

        let broadRule = try? store.fetchConversationDisambiguationRule(
            ruleType: clarificationRuleType(for: axis),
            appPairKey: appPairKey,
            subjectKey: normalizedSubjectKey,
            contextScopeKey: nil
        )
        if let broadRule {
            switch broadRule.decision {
            case .separate:
                return .keepSeparate
            case .link:
                return .link(canonicalKey: broadRule.canonicalKey)
            }
        }

        if let resolvedAlias = try? store.resolveConversationTagAlias(
            aliasType: axis.aliasType,
            aliasKey: currentKey
        ),
           normalizedClarificationKey(resolvedAlias) == candidateKey {
            return .link(canonicalKey: candidateKey)
        }

        return nil
    }

    private func clarificationAxis(for kind: ConversationClarificationKind) -> ClarificationAxis {
        switch kind {
        case .projectExact, .projectAmbiguous:
            return .project
        case .personExact, .personAmbiguous:
            return .person
        }
    }

    private func clarificationRuleType(for axis: ClarificationAxis) -> ConversationDisambiguationRuleType {
        switch axis {
        case .project:
            return .project
        case .person:
            return .person
        }
    }

    private func disambiguationRuleID(
        ruleType: ConversationDisambiguationRuleType,
        appPairKey: String,
        subjectKey: String,
        contextScopeKey: String?,
        source: ConversationContextMappingSource
    ) -> String {
        let seed = [
            ruleType.rawValue,
            appPairKey,
            subjectKey,
            contextScopeKey ?? "-"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(seed.utf8))
        let digestPrefix = digest.map { String(format: "%02x", $0) }.joined().prefix(24)
        return "\(mappingSourceRuleIDPrefix(source))\(digestPrefix)"
    }

    private func mappingSourceRuleIDPrefix(_ source: ConversationContextMappingSource) -> String {
        switch source {
        case .manual:
            return mappingRuleIDPrefixManual
        case .ai:
            return mappingRuleIDPrefixAI
        case .deterministic:
            return mappingRuleIDPrefixDeterministic
        case .legacy:
            return mappingRuleIDPrefixLegacy
        }
    }

    private func mappingSource(forRuleID ruleID: String) -> ConversationContextMappingSource {
        let normalizedID = ruleID.lowercased()
        if normalizedID.hasPrefix(mappingRuleIDPrefixManual) {
            return .manual
        }
        if normalizedID.hasPrefix(mappingRuleIDPrefixAI) {
            return .ai
        }
        if normalizedID.hasPrefix(mappingRuleIDPrefixDeterministic) {
            return .deterministic
        }
        return .legacy
    }

    private func normalizedDisambiguationAppPairKey(_ value: String) -> String {
        let normalized = value
            .split(separator: "|")
            .map { normalizedClarificationBundle(String($0)) }
            .filter { !$0.isEmpty }
            .sorted()
        if normalized.count >= 2 {
            return normalized.joined(separator: "|")
        }
        return normalizedClarificationBundle(value)
    }

    private func normalizedClarificationOptionalKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalizedClarificationKey(value)
        return normalized.isEmpty ? nil : normalized
    }

    private func tagAliasMappingID(aliasType: String, aliasKey: String) -> String {
        let encodedAliasType = Data(aliasType.utf8).base64EncodedString()
        let encodedAliasKey = Data(aliasKey.utf8).base64EncodedString()
        return "\(aliasMappingIDPrefix)\(encodedAliasType)|\(encodedAliasKey)"
    }

    private func decodeTagAliasMappingID(_ value: String) -> (aliasType: String, aliasKey: String)? {
        guard value.hasPrefix(aliasMappingIDPrefix) else {
            return nil
        }
        let encodedPayload = String(value.dropFirst(aliasMappingIDPrefix.count))
        let parts = encodedPayload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let aliasTypeData = Data(base64Encoded: String(parts[0])),
              let aliasKeyData = Data(base64Encoded: String(parts[1])),
              let aliasType = String(data: aliasTypeData, encoding: .utf8),
              let aliasKey = String(data: aliasKeyData, encoding: .utf8) else {
            return nil
        }
        return (aliasType, aliasKey)
    }

    private func resolvedClarificationAliasKey(
        aliasType: String,
        key: String,
        store: MemorySQLiteStore
    ) -> String {
        let normalized = normalizedClarificationKey(key)
        guard !normalized.isEmpty else {
            return ""
        }
        if let resolved = try? store.resolveConversationTagAlias(
            aliasType: aliasType,
            aliasKey: normalized
        ),
           !resolved.isEmpty {
            return normalizedClarificationKey(resolved)
        }
        return normalized
    }

    private func normalizedClarificationKey(_ value: String) -> String {
        collapsedWhitespace(value).lowercased()
    }

    private func normalizedClarificationBundle(_ value: String) -> String {
        collapsedWhitespace(value).lowercased()
    }

    private func normalizedClarificationIdentityType(_ value: String) -> String {
        collapsedWhitespace(value).lowercased()
    }

    private func comparableClarificationLabel(label: String, fallbackKey: String) -> String {
        let fromLabel = normalizedClarificationLabel(label)
        if !fromLabel.isEmpty {
            return fromLabel
        }
        return normalizedClarificationLabel(readableClarificationLabel(from: fallbackKey))
    }

    private func normalizedClarificationLabel(_ value: String) -> String {
        let collapsed = collapsedWhitespace(value).lowercased()
        guard !collapsed.isEmpty else {
            return ""
        }
        let alphanumericOnly = collapsed.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: " ",
            options: .regularExpression
        )
        return collapsedWhitespace(alphanumericOnly)
    }

    private func readableClarificationLabel(from key: String) -> String {
        let split = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        let fallback = split.count == 2 ? String(split[1]) : key
        let separated = fallback
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let normalized = collapsedWhitespace(separated)
        return normalized.isEmpty ? key : normalized
    }

    private func isMeaningfulProjectClarificationKey(_ projectKey: String) -> Bool {
        let normalized = normalizedClarificationKey(projectKey)
        guard normalized.hasPrefix("project:") else {
            return false
        }
        let value = String(normalized.dropFirst("project:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return false
        }
        let blockedValues: Set<String> = [
            "unknown",
            "unknown-project",
            "current-screen",
            "focused-input",
            "automation-folder",
            "automation-folders"
        ]
        if blockedValues.contains(value) || value.hasPrefix("unknown-") {
            return false
        }
        return true
    }

    private func isMeaningfulPersonClarificationKey(_ identityKey: String) -> Bool {
        let normalized = normalizedClarificationKey(identityKey)
        guard normalized.hasPrefix("person:") else {
            return false
        }
        let value = String(normalized.dropFirst("person:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "unknown" {
            return false
        }
        return true
    }

    private func normalizedClarificationSimilarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return 0
        }
        if lhs == rhs {
            return 1
        }
        let editDistanceSimilarity = normalizedLevenshteinSimilarity(lhs, rhs)
        let tokenSimilarity = tokenOverlapSimilarity(lhs, rhs)
        return max(editDistanceSimilarity, tokenSimilarity)
    }

    private func normalizedLevenshteinSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        guard !lhsCharacters.isEmpty, !rhsCharacters.isEmpty else {
            return 0
        }

        var previous = Array(0...rhsCharacters.count)
        var current = Array(repeating: 0, count: rhsCharacters.count + 1)

        for lhsIndex in 1...lhsCharacters.count {
            current[0] = lhsIndex
            for rhsIndex in 1...rhsCharacters.count {
                let substitutionCost = lhsCharacters[lhsIndex - 1] == rhsCharacters[rhsIndex - 1] ? 0 : 1
                current[rhsIndex] = Swift.min(
                    previous[rhsIndex] + 1,
                    current[rhsIndex - 1] + 1,
                    previous[rhsIndex - 1] + substitutionCost
                )
            }
            swap(&previous, &current)
        }

        let maxLength = max(lhsCharacters.count, rhsCharacters.count)
        guard maxLength > 0 else {
            return 0
        }
        let distance = previous[rhsCharacters.count]
        return max(0, 1 - (Double(distance) / Double(maxLength)))
    }

    private func tokenOverlapSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init))
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init))
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else {
            return 0
        }
        let unionCount = lhsTokens.union(rhsTokens).count
        guard unionCount > 0 else {
            return 0
        }
        return Double(lhsTokens.intersection(rhsTokens).count) / Double(unionCount)
    }

    private func mergedRequestHistory(
        for context: PromptRewriteConversationContext,
        limit: Int,
        userText: String
    ) -> [PromptRewriteConversationTurn] {
        let normalizedLimit = normalizedTurnLimit(limit)
        guard normalizedLimit > 0 else { return [] }

        let activeOnlyHistory = promptHistory(
            for: context.id,
            limit: normalizedLimit,
            userText: userText
        )
        let linkedBudget = min(
            linkedPromptHistoryTurnBudget,
            max(0, normalizedLimit - 1)
        )
        guard linkedBudget > 0 else {
            return activeOnlyHistory
        }

        let linkedTurns = linkedContextTurnCandidates(
            for: context,
            excludingContextID: context.id,
            userText: userText,
            limit: linkedBudget
        )
        guard !linkedTurns.isEmpty else {
            return activeOnlyHistory
        }

        let activeBudget = min(
            primaryPromptHistoryTurnBudget,
            max(1, normalizedLimit - linkedTurns.count)
        )
        let prioritizedActive = promptHistory(
            for: context.id,
            limit: activeBudget,
            userText: userText
        )

        var merged = prioritizedActive + linkedTurns
        if merged.count < normalizedLimit {
            for turn in activeOnlyHistory where !merged.contains(turn) {
                merged.append(turn)
                if merged.count >= normalizedLimit {
                    break
                }
            }
        }

        let deduped = dedupedMergedPromptHistory(
            merged,
            limit: normalizedLimit
        )
        return deduped.isEmpty ? activeOnlyHistory : deduped
    }

    private func linkedContextTurnCandidates(
        for context: PromptRewriteConversationContext,
        excludingContextID: String,
        userText: String,
        limit: Int
    ) -> [PromptRewriteConversationTurn] {
        let normalizedLimit = max(0, min(linkedPromptHistoryTurnBudget, limit))
        guard normalizedLimit > 0 else { return [] }

        let linkedIDs = linkedContextIDs(
            for: context,
            excludingContextID: excludingContextID
        )
        guard !linkedIDs.isEmpty else { return [] }

        var primaries: [PromptRewriteConversationTurn] = []
        var secondaries: [PromptRewriteConversationTurn] = []

        for contextID in linkedIDs {
            let selected = promptHistory(
                for: contextID,
                limit: linkedPromptHistoryTurnBudget,
                userText: userText
            )
            let exchangeTurns = selected.filter { !$0.isSummary }
            guard let latest = exchangeTurns.last else {
                continue
            }
            primaries.append(latest)
            if exchangeTurns.count > 1 {
                secondaries.append(exchangeTurns[exchangeTurns.count - 2])
            }
        }

        var output = primaries
            .sorted { lhs, rhs in lhs.timestamp > rhs.timestamp }
        if output.count < normalizedLimit {
            let remainder = secondaries
                .sorted { lhs, rhs in lhs.timestamp > rhs.timestamp }
            for candidate in remainder {
                output.append(candidate)
                if output.count >= normalizedLimit {
                    break
                }
            }
        }

        if output.count > normalizedLimit {
            output = Array(output.prefix(normalizedLimit))
        }
        return output.sorted { lhs, rhs in
            lhs.timestamp < rhs.timestamp
        }
    }

    private func linkedContextIDs(
        for context: PromptRewriteConversationContext,
        excludingContextID: String
    ) -> [String] {
        if isBrowserContext(context) {
            // Browser tabs/windows are now consolidated into one thread.
            return []
        }
        let projectKey = contextLinkingKey(context.projectKey, aliasTypeHint: "project")
        let identityKey = contextLinkingKey(context.identityKey, aliasTypeHint: "identity")
        guard projectKey != nil || identityKey != nil else {
            return []
        }

        let candidates = contextsByID.values
            .filter { stored in
                stored.context.id != excludingContextID
                    && contextMatchesLinkingKeys(
                        stored.context,
                        projectKey: projectKey,
                        identityKey: identityKey
                    )
            }
            .sorted { lhs, rhs in
                let lhsCrossApp = lhs.context.bundleIdentifier.caseInsensitiveCompare(context.bundleIdentifier) != .orderedSame
                let rhsCrossApp = rhs.context.bundleIdentifier.caseInsensitiveCompare(context.bundleIdentifier) != .orderedSame
                if lhsCrossApp != rhsCrossApp {
                    return lhsCrossApp && !rhsCrossApp
                }
                if lhs.lastUpdatedAt != rhs.lastUpdatedAt {
                    return lhs.lastUpdatedAt > rhs.lastUpdatedAt
                }
                return lhs.context.id < rhs.context.id
            }
            .map { $0.context.id }

        return Array(candidates.prefix(linkedPromptHistoryTurnBudget))
    }

    private func contextMatchesLinkingKeys(
        _ candidate: PromptRewriteConversationContext,
        projectKey: String?,
        identityKey: String?
    ) -> Bool {
        let candidateProject = contextLinkingKey(candidate.projectKey, aliasTypeHint: "project")
        let candidateIdentity = contextLinkingKey(candidate.identityKey, aliasTypeHint: "identity")
        let projectMatches = (projectKey != nil && candidateProject == projectKey)
        let identityMatches = (identityKey != nil && candidateIdentity == identityKey)
        return projectMatches || identityMatches
    }

    private func contextLinkingKey(
        _ value: String?,
        aliasTypeHint: String? = nil
    ) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        if isUnknownContextLinkingKey(normalized) {
            return nil
        }
        guard let store = resolvedSQLiteStore() else {
            return normalized
        }
        let aliasType = clarificationAliasType(for: normalized, hint: aliasTypeHint)
        let cacheKey = "\(aliasType)|\(normalized)"
        if let cached = ContextLinkingKeyCache.get(for: cacheKey) {
            return cached
        }
        if let resolvedAlias = try? store.resolveConversationTagAlias(
            aliasType: aliasType,
            aliasKey: normalized
        ) {
            let canonical = normalizedClarificationKey(resolvedAlias)
            if !canonical.isEmpty, !isUnknownContextLinkingKey(canonical) {
                ContextLinkingKeyCache.set(canonical, for: cacheKey)
                return canonical
            }
        }
        ContextLinkingKeyCache.set(normalized, for: cacheKey)
        return normalized
    }

    private enum ContextLinkingKeyCache {
        private static var cache: [String: String] = [:]
        private static let lock = NSLock()

        static func get(for key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return cache[key]
        }

        static func set(_ value: String, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            cache[key] = value
        }
    }
    private func clarificationAliasType(for normalizedKey: String, hint: String?) -> String {
        if let hint {
            let normalizedHint = normalizedClarificationKey(hint)
            if normalizedHint == "project" {
                return "project"
            }
            if normalizedHint == "identity" {
                return "identity"
            }
        }
        if normalizedKey.hasPrefix("project:") {
            return "project"
        }
        return "identity"
    }

    private func isUnknownContextLinkingKey(_ normalizedKey: String) -> Bool {
        normalizedKey == "project:unknown"
            || normalizedKey == "identity:unknown"
            || normalizedKey == "person:unknown"
            || normalizedKey == "unknown"
    }

    private func dedupedMergedPromptHistory(
        _ turns: [PromptRewriteConversationTurn],
        limit: Int
    ) -> [PromptRewriteConversationTurn] {
        let normalizedLimit = normalizedTurnLimit(limit)
        guard normalizedLimit > 0 else { return [] }

        var seenKeys = Set<String>()
        var deduped: [PromptRewriteConversationTurn] = []
        deduped.reserveCapacity(turns.count)
        for turn in turns {
            let key = mergedPromptHistoryDedupeKey(for: turn)
            if seenKeys.contains(key) {
                continue
            }
            seenKeys.insert(key)
            deduped.append(turn)
        }

        if deduped.count > normalizedLimit {
            deduped = Array(deduped.suffix(normalizedLimit))
        }
        return deduped.sorted { lhs, rhs in
            lhs.timestamp < rhs.timestamp
        }
    }

    private func mergedPromptHistoryDedupeKey(for turn: PromptRewriteConversationTurn) -> String {
        let timestampKey = Int((turn.timestamp.timeIntervalSince1970 * 1_000).rounded())
        let normalizedUser = collapsedWhitespace(turn.userText).lowercased()
        let normalizedAssistant = collapsedWhitespace(turn.assistantText).lowercased()
        return "\(timestampKey)|\(normalizedUser)|\(normalizedAssistant)"
    }

    private func promptHistory(
        for contextID: String,
        limit: Int,
        userText: String
    ) -> [PromptRewriteConversationTurn] {
        guard let stored = contextsByID[contextID] else { return [] }
        return selectedTurnsForPrompt(
            from: stored.turns,
            context: stored.context,
            limit: limit,
            userText: userText
        )
    }

    private func selectedTurnsForPrompt(
        from turns: [PromptRewriteConversationTurn],
        context: PromptRewriteConversationContext,
        limit: Int,
        userText: String
    ) -> [PromptRewriteConversationTurn] {
        let normalizedLimit = min(
            normalizedTurnLimit(limit),
            maxRelevantExchangeTurnsForPrompt + 1
        )
        guard turns.count > normalizedLimit else {
            if isBrowserContext(context) {
                return filteredBrowserPromptHistory(
                    turns,
                    context: context,
                    userText: userText,
                    limit: normalizedLimit
                )
            }
            return turns
        }

        if normalizedLimit <= 1 {
            return Array(turns.filter { !$0.isSummary }.suffix(1))
        }

        let nonSummaryTurns = turns.filter { !$0.isSummary }
        guard !nonSummaryTurns.isEmpty else {
            return Array(turns.suffix(normalizedLimit))
        }

        let normalizedUserText = collapsedWhitespace(userText).lowercased()
        let queryTokens = Set(
            MemoryTextNormalizer.keywords(
                from: normalizedUserText,
                limit: 16
            )
        )
        let shortOrAmbiguousInput = normalizedUserText.count < 56 || queryTokens.count <= 4

        let latestSummary = turns.reversed().first(where: \.isSummary)
        let minimumRecentTurns = min(minRecentExchangeTurnsForPrompt, nonSummaryTurns.count)
        let canIncludeSummary = latestSummary != nil && (normalizedLimit - 1) >= minimumRecentTurns
        let summaryTurn = canIncludeSummary ? latestSummary : nil
        let nonSummaryBudget = max(1, normalizedLimit - (summaryTurn == nil ? 0 : 1))

        var selectedNonSummary: [PromptRewriteConversationTurn]
        var protectedRecentTurns: [PromptRewriteConversationTurn]

        if nonSummaryTurns.count <= nonSummaryBudget {
            selectedNonSummary = nonSummaryTurns
            protectedRecentTurns = Array(
                nonSummaryTurns.suffix(
                    min(maxRecentExchangeTurnsForPrompt, nonSummaryTurns.count)
                )
            )
        } else {
            let cappedRecentWindow = min(
                maxRecentExchangeTurnsForPrompt,
                nonSummaryBudget,
                nonSummaryTurns.count
            )
            let minimumRecentWindow = min(minRecentExchangeTurnsForPrompt, cappedRecentWindow)
            let preferredRecentWindow = shortOrAmbiguousInput
                ? cappedRecentWindow
                : max(minimumRecentWindow, min(cappedRecentWindow, 4))
            let indexedTurns = Array(nonSummaryTurns.enumerated())
            let recentIndexed = Array(indexedTurns.suffix(preferredRecentWindow))
            let recentIndices = Set(recentIndexed.map(\.offset))
            let recentTurns = recentIndexed.map(\.element)
            let additionalBudget = max(0, nonSummaryBudget - recentTurns.count)

            let additionalTurns = indexedTurns
                .filter { !recentIndices.contains($0.offset) }
                .map { index, turn -> (turn: PromptRewriteConversationTurn, score: Double) in
                    let recencyScore = Double(index + 1) / Double(max(1, nonSummaryTurns.count))
                    let turnTokens = Set(
                        MemoryTextNormalizer.keywords(
                            from: "\(turn.userText) \(turn.assistantText)".lowercased(),
                            limit: 24
                        )
                    )
                    let overlapScore: Double
                    if queryTokens.isEmpty {
                        overlapScore = 0
                    } else {
                        let shared = queryTokens.intersection(turnTokens).count
                        overlapScore = Double(shared) / Double(max(1, queryTokens.count))
                    }
                    // Keep continuity first, then fill older context using relevance and recency.
                    return (turn: turn, score: (overlapScore * 0.6) + (recencyScore * 0.4))
                }
                .sorted {
                    if $0.score == $1.score {
                        return $0.turn.timestamp < $1.turn.timestamp
                    }
                    return $0.score > $1.score
                }
                .prefix(additionalBudget)
                .map(\.turn)

            selectedNonSummary = (recentTurns + additionalTurns).sorted { lhs, rhs in
                lhs.timestamp < rhs.timestamp
            }
            if selectedNonSummary.count > nonSummaryBudget {
                selectedNonSummary = Array(selectedNonSummary.suffix(nonSummaryBudget))
            }
            protectedRecentTurns = recentTurns
        }

        var output: [PromptRewriteConversationTurn] = []
        if let summaryTurn {
            output.append(summaryTurn)
        }
        output.append(contentsOf: selectedNonSummary)

        if output.count > normalizedLimit {
            output = Array(output.suffix(normalizedLimit))
        }

        while estimatedContextCharacters(output) > maxPromptContextCharacters,
              output.count > 1 {
            if let index = output.firstIndex(where: { candidate in
                guard !candidate.isSummary else { return false }
                return !protectedRecentTurns.contains(candidate)
            }) {
                output.remove(at: index)
            } else if let index = output.firstIndex(where: { !$0.isSummary }) {
                output.remove(at: index)
            } else {
                break
            }
        }

        if isBrowserContext(context) {
            return filteredBrowserPromptHistory(
                output,
                context: context,
                userText: userText,
                limit: normalizedLimit
            )
        }
        return output
    }

    private func filteredBrowserPromptHistory(
        _ turns: [PromptRewriteConversationTurn],
        context: PromptRewriteConversationContext,
        userText: String,
        limit: Int
    ) -> [PromptRewriteConversationTurn] {
        let normalizedLimit = normalizedTurnLimit(limit)
        guard normalizedLimit > 0, !turns.isEmpty else {
            return []
        }

        let exchangeTurns = turns.filter { !$0.isSummary }
        guard !exchangeTurns.isEmpty else {
            return Array(turns.suffix(normalizedLimit))
        }

        let latestSummary = turns.reversed().first(where: \.isSummary)
        let normalizedUserText = collapsedWhitespace(userText).lowercased()
        let queryTokens = Set(
            MemoryTextNormalizer.keywords(
                from: normalizedUserText,
                limit: browserHistoryKeywordLimit
            )
        )
        let contextDescriptor = [
            context.projectLabel ?? "",
            context.identityLabel ?? "",
            context.screenLabel,
            context.fieldLabel
        ]
            .map(collapsedWhitespace)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        let contextTokens = Set(
            MemoryTextNormalizer.keywords(
                from: contextDescriptor,
                limit: browserHistoryKeywordLimit
            )
        )

        let pinnedCount = min(browserHistoryPinnedRecentTurns, exchangeTurns.count)
        let pinnedRecent = Array(exchangeTurns.suffix(pinnedCount))
        var selected = pinnedRecent
        var selectedKeys = Set(selected.map(mergedPromptHistoryDedupeKey(for:)))
        let includeSummary = latestSummary != nil && queryTokens.count <= 2
        let exchangeBudget = max(1, normalizedLimit - (includeSummary ? 1 : 0))

        if selected.count < exchangeBudget {
            let candidatePool = exchangeTurns.dropLast(pinnedCount)
                .enumerated()
                .map { offset, turn -> (turn: PromptRewriteConversationTurn, queryOverlap: Double, contextOverlap: Double, recency: Double, score: Double) in
                    let turnTokens = Set(
                        MemoryTextNormalizer.keywords(
                            from: "\(turn.userText) \(turn.assistantText)".lowercased(),
                            limit: browserHistoryKeywordLimit
                        )
                    )
                    let queryOverlap = tokenOverlapRatio(queryTokens, turnTokens)
                    let contextOverlap = tokenOverlapRatio(contextTokens, turnTokens)
                    let recency = Double(offset + 1) / Double(max(1, exchangeTurns.count))
                    let score = (queryOverlap * 0.7) + (contextOverlap * 0.2) + (recency * 0.1)
                    return (
                        turn: turn,
                        queryOverlap: queryOverlap,
                        contextOverlap: contextOverlap,
                        recency: recency,
                        score: score
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.score == rhs.score {
                        return lhs.turn.timestamp > rhs.turn.timestamp
                    }
                    return lhs.score > rhs.score
                }

            for candidate in candidatePool {
                guard selected.count < exchangeBudget else { break }
                if queryTokens.isEmpty {
                    // Without a query anchor, prefer very recent browser turns and
                    // turns that share screen/domain keywords with the active page.
                    if candidate.contextOverlap == 0, candidate.recency < 0.8 {
                        continue
                    }
                } else if candidate.queryOverlap == 0, candidate.contextOverlap == 0 {
                    continue
                }

                let dedupeKey = mergedPromptHistoryDedupeKey(for: candidate.turn)
                if selectedKeys.insert(dedupeKey).inserted {
                    selected.append(candidate.turn)
                }
            }
        }

        let minimumExchangeTurns = min(exchangeBudget, browserHistoryMinimumContextTurns)
        if selected.count < minimumExchangeTurns {
            for turn in exchangeTurns.reversed() {
                guard selected.count < minimumExchangeTurns else { break }
                let dedupeKey = mergedPromptHistoryDedupeKey(for: turn)
                if selectedKeys.insert(dedupeKey).inserted {
                    selected.append(turn)
                }
            }
        }

        selected.sort { lhs, rhs in lhs.timestamp < rhs.timestamp }
        if selected.count > exchangeBudget {
            selected = Array(selected.suffix(exchangeBudget))
        }

        var output: [PromptRewriteConversationTurn] = selected
        if includeSummary, let latestSummary, output.count < normalizedLimit {
            output.insert(latestSummary, at: 0)
        }
        if output.count > normalizedLimit {
            output = Array(output.suffix(normalizedLimit))
        }
        return output
    }

    private func tokenOverlapRatio(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return 0
        }
        let shared = lhs.intersection(rhs).count
        return Double(shared) / Double(max(1, lhs.count))
    }

    private func isBrowserContext(_ context: PromptRewriteConversationContext) -> Bool {
        tagInferenceService.isBrowserContext(
            bundleID: context.bundleIdentifier,
            appName: context.appName
        )
    }

    private func autoCompactContextIfNeeded(_ stored: inout StoredContext) {
        let exchangeTurns = stored.turns.filter { !$0.isSummary }.count
        guard exchangeTurns > autoCompactionExchangeThreshold else { return }
        _ = compactStoredContext(
            &stored,
            keepRecentTurns: autoCompactionRetainedExchangeTurns,
            force: false,
            trigger: .autoCompaction
        )
    }

    private func enforceHardTurnCap(_ stored: inout StoredContext, keepRecentTurns: Int) {
        guard stored.turns.count > maxStoredTurnsPerContext else { return }
        if compactStoredContext(
            &stored,
            keepRecentTurns: max(2, keepRecentTurns),
            force: true,
            trigger: .autoCompaction
        ) != nil,
           stored.turns.count <= maxStoredTurnsPerContext {
            return
        }

        let overflow = max(0, stored.turns.count - maxStoredTurnsPerContext)
        guard overflow > 0 else { return }
        stored.turns = Array(stored.turns.dropFirst(overflow))
    }

    private func compactStoredContext(
        _ stored: inout StoredContext,
        keepRecentTurns: Int,
        force: Bool,
        trigger: MemoryPromotionTrigger = .autoCompaction
    ) -> PromptRewriteConversationCompactionReport? {
        let normalizedKeepRecentTurns = normalizedTurnLimit(keepRecentTurns)
        let previousTurnCount = stored.turns.count
        guard previousTurnCount > normalizedKeepRecentTurns else { return nil }

        let turnIndexesToKeep = recentExchangeTurnIndexes(
            in: stored.turns,
            keepRecentTurns: normalizedKeepRecentTurns
        )
        guard !turnIndexesToKeep.isEmpty else { return nil }

        let olderTurns = stored.turns.enumerated()
            .filter { !turnIndexesToKeep.contains($0.offset) }
            .map(\.element)
        var recentTurns = stored.turns.enumerated()
            .filter { turnIndexesToKeep.contains($0.offset) }
            .map(\.element)
        recentTurns = recentTurns.filter { !$0.isSummary }

        let olderExchangeCount = olderTurns.filter { !$0.isSummary }.count
        if !force && olderExchangeCount == 0 {
            return nil
        }

        guard !olderTurns.isEmpty else { return nil }
        let summaryText = compactionSummary(for: olderTurns, context: stored.context)
        guard !summaryText.isEmpty else { return nil }

        let compactedTurnCount = olderTurns.reduce(into: 0) { partial, turn in
            if turn.isSummary {
                partial += max(1, turn.sourceTurnCount ?? 1)
            } else {
                partial += 1
            }
        }

        let summaryTurn = PromptRewriteConversationTurn(
            userText: "Compacted conversation summary",
            assistantText: summaryText,
            timestamp: Date(),
            isSummary: true,
            sourceTurnCount: compactedTurnCount,
            compactionVersion: compactionVersion
        )
        stored.turns = [summaryTurn] + recentTurns
        stored.lastUpdatedAt = Date()
        stored.totalExchangeTurns = max(
            stored.totalExchangeTurns,
            compactedTurnCount + recentTurns.count
        )

        enqueueConversationPromotion(
            context: stored.context,
            summaryText: summaryText,
            sourceTurnCount: compactedTurnCount,
            compactionVersion: summaryTurn.compactionVersion,
            trigger: trigger,
            recentTurns: recentTurns,
            timestamp: summaryTurn.timestamp
        )

        return PromptRewriteConversationCompactionReport(
            contextID: stored.context.id,
            previousTurnCount: previousTurnCount,
            compactedTurnCount: compactedTurnCount,
            newTurnCount: stored.turns.count
        )
    }

    private func recentExchangeTurnIndexes(
        in turns: [PromptRewriteConversationTurn],
        keepRecentTurns: Int
    ) -> Set<Int> {
        var indexes: Set<Int> = []
        var remaining = max(1, keepRecentTurns)

        for index in stride(from: turns.count - 1, through: 0, by: -1) {
            let turn = turns[index]
            if turn.isSummary {
                continue
            }
            indexes.insert(index)
            remaining -= 1
            if remaining == 0 {
                break
            }
        }

        return indexes
    }

    private func compactionSummary(
        for olderTurns: [PromptRewriteConversationTurn],
        context: PromptRewriteConversationContext
    ) -> String {
        let priorSummarySnippets = olderTurns
            .filter(\.isSummary)
            .map(\.assistantText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let userSnippets = olderTurns
            .filter { !$0.isSummary }
            .map(\.userText)
        let assistantSnippets = olderTurns
            .filter { !$0.isSummary }
            .map(\.assistantText)

        let goalLines = distinctSnippets(from: userSnippets, limit: 3, snippetLimit: 180)
        let accomplishmentLines = distinctSnippets(from: assistantSnippets, limit: 4, snippetLimit: 200)
        let priorSummaryLines = distinctSnippets(from: priorSummarySnippets, limit: 2, snippetLimit: 220)

        var sections: [String] = []
        sections.append("## Context")
        sections.append("- \(context.providerContextLabel)")
        sections.append("")
        sections.append("## Goal")
        if goalLines.isEmpty {
            sections.append("- Continue the same user intent and style from prior turns.")
        } else {
            sections.append(contentsOf: goalLines.map { "- \($0)" })
        }
        sections.append("")
        sections.append("## Accomplished")
        if accomplishmentLines.isEmpty {
            sections.append("- Prior responses and revisions were exchanged in this context.")
        } else {
            sections.append(contentsOf: accomplishmentLines.map { "- \($0)" })
        }
        if !priorSummaryLines.isEmpty {
            sections.append("")
            sections.append("## Prior Summary Signals")
            sections.append(contentsOf: priorSummaryLines.map { "- \($0)" })
        }
        sections.append("")
        sections.append("## Handoff")
        sections.append("- Use this summary with the most recent turns to continue naturally.")
        sections.append("- Preserve the user's intent, tone, and any explicit constraints from this context.")

        return snippet(sections.joined(separator: "\n"), limit: 1_800)
    }

    private func distinctSnippets(
        from values: [String],
        limit: Int,
        snippetLimit: Int
    ) -> [String] {
        guard limit > 0, !values.isEmpty else {
            return []
        }

        struct RankedSnippet {
            let text: String
            let index: Int
            let score: Double
        }

        let normalizedCount = max(1, values.count)
        let rankedCandidates: [RankedSnippet] = values.enumerated().compactMap { index, value in
            let normalized = collapsedWhitespace(value)
            guard !normalized.isEmpty else { return nil }
            let concise = snippet(normalized, limit: snippetLimit)
            let keywords = MemoryTextNormalizer.keywords(
                from: concise.lowercased(),
                limit: 16
            )
            guard concise.count >= 6,
                  concise.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }),
                  keywords.count >= 2 else { return nil }
            let keywordCount = min(10, keywords.count)
            let recencyWeight = Double(index + 1) / Double(normalizedCount)
            let keywordWeight = Double(keywordCount) / 10.0
            let score = (recencyWeight * 0.75) + (keywordWeight * 0.25)
            return RankedSnippet(text: concise, index: index, score: score)
        }

        let ranked = rankedCandidates.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.index > rhs.index
            }
            return lhs.score > rhs.score
        }

        var output: [String] = []
        var seen: Set<String> = []
        for candidate in ranked {
            let key = candidate.text.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(candidate.text)
            if output.count >= limit {
                break
            }
        }

        return output
    }

    private func isMeaningfulCompactionSnippet(_ value: String) -> Bool {
        let normalized = collapsedWhitespace(value)
        guard normalized.count >= 6 else { return false }
        guard normalized.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return false
        }
        let tokenCount = MemoryTextNormalizer.keywords(
            from: normalized.lowercased(),
            limit: 12
        ).count
        return tokenCount >= 2
    }

    private func normalizedTurnLimit(_ value: Int) -> Int {
        min(50, max(1, value))
    }

    private func normalizedTimeoutMinutes(_ value: Double) -> Double {
        let fallback = 25.0
        guard value.isFinite else { return fallback }
        return min(240, max(2, value))
    }

    private var promptRewriteConversationHistoryEnabled: Bool {
        SettingsStore.shared.promptRewriteConversationHistoryEnabled
    }

    private var promptRewriteCrossIDEConversationSharingEnabled: Bool {
        SettingsStore.shared.promptRewriteCrossIDEConversationSharingEnabled
    }

    private var promptRewriteEnabled: Bool {
        SettingsStore.shared.promptRewriteEnabled
    }

    private var canRunExpiredSummaryAIEnrichment: Bool {
        FeatureFlags.aiMemoryEnabled
            && FeatureFlags.conversationLongTermMemoryEnabled
            && FeatureFlags.conversationAutoPromotionEnabled
            && promptRewriteEnabled
            && promptRewriteConversationHistoryEnabled
    }

    private func scopeKeyForExpiredHandoff(
        context: PromptRewriteConversationContext,
        crossIDESharingEnabled: Bool
    ) -> String {
        let normalizedBundleID = collapsedWhitespace(context.bundleIdentifier).lowercased()
        let normalizedSurfaceKey = normalizedExpiredHandoffSurfaceKey(
            context: context,
            normalizedBundleID: normalizedBundleID
        )

        let projectKey = contextLinkingKey(context.projectKey, aliasTypeHint: "project")
        let identityKey = contextLinkingKey(context.identityKey, aliasTypeHint: "identity")

        if let projectKey, let identityKey {
            if crossIDESharingEnabled {
                return "expired-scope|project=\(projectKey)|identity=\(identityKey)"
            }
            return "expired-scope|bundle=\(normalizedBundleID)|project=\(projectKey)|identity=\(identityKey)"
        }

        if let projectKey {
            if crossIDESharingEnabled {
                return "expired-scope|project=\(projectKey)|identity=unknown"
            }
            return "expired-scope|bundle=\(normalizedBundleID)|project=\(projectKey)|identity=unknown"
        }

        if let identityKey {
            if crossIDESharingEnabled {
                return "expired-scope|project=unknown|identity=\(identityKey)"
            }
            return "expired-scope|bundle=\(normalizedBundleID)|project=unknown|identity=\(identityKey)"
        }

        return "expired-scope|bundle=\(normalizedBundleID)|surface=\(normalizedSurfaceKey)"
    }

    private func scopeKeysForExpiredHandoffLookup(
        context: PromptRewriteConversationContext,
        crossIDESharingEnabled: Bool
    ) -> [String] {
        let primary = scopeKeyForExpiredHandoff(
            context: context,
            crossIDESharingEnabled: crossIDESharingEnabled
        )
        let legacy = legacyScopeKeyForExpiredHandoff(
            context: context,
            crossIDESharingEnabled: crossIDESharingEnabled
        )
        if legacy.caseInsensitiveCompare(primary) == .orderedSame {
            return [primary]
        }
        return [primary, legacy]
    }

    private func legacyScopeKeyForExpiredHandoff(
        context: PromptRewriteConversationContext,
        crossIDESharingEnabled: Bool
    ) -> String {
        let normalizedBundleID = collapsedWhitespace(context.bundleIdentifier).lowercased()
        let normalizedSurfaceKey = normalizedExpiredHandoffSurfaceKey(
            context: context,
            normalizedBundleID: normalizedBundleID
        )
        let projectKey = contextLinkingKey(context.projectKey, aliasTypeHint: "project")
        let identityKey = contextLinkingKey(context.identityKey, aliasTypeHint: "identity")
        if let projectKey, let identityKey {
            if crossIDESharingEnabled {
                return "expired-scope|project=\(projectKey)|identity=\(identityKey)"
            }
            return "expired-scope|bundle=\(normalizedBundleID)|project=\(projectKey)|identity=\(identityKey)"
        }
        return "expired-scope|bundle=\(normalizedBundleID)|surface=\(normalizedSurfaceKey)"
    }

    private func normalizedExpiredHandoffSurfaceKey(
        context: PromptRewriteConversationContext,
        normalizedBundleID: String
    ) -> String {
        let logicalSurface = collapsedWhitespace(context.logicalSurfaceKey).lowercased()
        if !logicalSurface.isEmpty {
            return logicalSurface
        }
        let fallbackSeed = "\(context.screenLabel)|\(context.fieldLabel)|\(normalizedBundleID)"
        return "surface-\(MemoryIdentifier.stableHexDigest(for: fallbackSeed).prefix(24))"
    }

    private func expiredHandoffHistory(
        from record: ExpiredConversationContextRecord,
        limit: Int
    ) -> [PromptRewriteConversationTurn] {
        let normalizedLimit = normalizedTurnLimit(limit)
        guard normalizedLimit > 0 else { return [] }

        let normalizedSummary = collapsedWhitespace(record.summaryText)
        guard !normalizedSummary.isEmpty else { return [] }

        let summaryTurn = PromptRewriteConversationTurn(
            userText: "Compacted conversation summary",
            assistantText: normalizedSummary,
            timestamp: record.expiredAt,
            isSummary: true,
            sourceTurnCount: max(1, record.sourceTurnCount),
            compactionVersion: compactionVersion
        )

        let recentArchiveTurns = decodedArchivedTurns(from: record.recentTurnsJSON)
        let archiveTurns = recentArchiveTurns.isEmpty
            ? decodedArchivedTurns(from: record.rawTurnsJSON)
            : recentArchiveTurns
        let exchangeBudget = max(0, normalizedLimit - 1)
        let selectedArchiveTurns = exchangeBudget == 0
            ? []
            : Array(
                archiveTurns
                    .filter { !$0.isSummary }
                    .suffix(min(2, exchangeBudget))
            )

        var output = [summaryTurn]
        output.append(contentsOf: selectedArchiveTurns)
        if output.count > normalizedLimit {
            output = Array(output.suffix(normalizedLimit))
        }

        while estimatedContextCharacters(output) > maxPromptContextCharacters,
              output.count > 1 {
            if let dropIndex = output.firstIndex(where: { !$0.isSummary }) {
                output.remove(at: dropIndex)
            } else {
                break
            }
        }

        return output
    }

    private func expiredHandoffReuseDecision(
        for record: ExpiredConversationContextRecord,
        userText: String,
        hasActiveHistory: Bool
    ) -> (shouldUse: Bool, reason: String, ageSeconds: Int, hasTopicAnchor: Bool) {
        let ageSeconds = max(0, Int(Date().timeIntervalSince(record.expiredAt).rounded()))
        let hasTopicAnchor = hasExplicitExpiredTopicAnchor(
            userText: userText,
            record: record
        )
        if hasTopicAnchor {
            return (true, "explicit-topic-anchor", ageSeconds, true)
        }

        let freshnessThreshold = hasActiveHistory
            ? expiredSummaryMergeNoAnchorMaxAgeSeconds
            : expiredHandoffNoAnchorMaxAgeSeconds
        if Double(ageSeconds) <= freshnessThreshold {
            return (true, "fresh", ageSeconds, false)
        }

        return (false, "stale-without-anchor", ageSeconds, false)
    }

    private func hasExplicitExpiredTopicAnchor(
        userText: String,
        record: ExpiredConversationContextRecord
    ) -> Bool {
        let userTokenSet = expiredHandoffTopicAnchorTokenSet(from: userText, limit: 28)
        guard userTokenSet.count >= 2 else {
            return false
        }

        let archiveCorpus = expiredHandoffTopicAnchorCorpus(record: record)
        let archiveTokenSet = expiredHandoffTopicAnchorTokenSet(
            from: archiveCorpus,
            limit: 120
        )
        guard !archiveTokenSet.isEmpty else {
            return false
        }

        let sharedTokens = userTokenSet.intersection(archiveTokenSet)
        if sharedTokens.count >= 2 {
            return true
        }
        if sharedTokens.contains(where: { $0.count >= 9 }) {
            return true
        }

        let overlapRatio = Double(sharedTokens.count) / Double(max(1, userTokenSet.count))
        return overlapRatio >= 0.35
    }

    private func expiredHandoffTopicAnchorCorpus(record: ExpiredConversationContextRecord) -> String {
        let normalizedSummary = collapsedWhitespace(record.summaryText)
        let recentArchiveTurns = decodedArchivedTurns(from: record.recentTurnsJSON)
        let archiveTurns = recentArchiveTurns.isEmpty
            ? decodedArchivedTurns(from: record.rawTurnsJSON)
            : recentArchiveTurns

        var segments: [String] = []
        if !normalizedSummary.isEmpty {
            segments.append(normalizedSummary)
        }
        for turn in archiveTurns.suffix(8) {
            if !turn.userText.isEmpty {
                segments.append(turn.userText)
            }
            if !turn.assistantText.isEmpty {
                segments.append(turn.assistantText)
            }
        }
        return segments.joined(separator: " ")
    }

    private func expiredHandoffTopicAnchorTokenSet(from text: String, limit: Int) -> Set<String> {
        let normalized = collapsedWhitespace(text).lowercased()
        guard !normalized.isEmpty else {
            return []
        }

        let rawTokens = MemoryTextNormalizer.keywords(
            from: normalized,
            limit: max(limit * 2, limit)
        )
        let filtered = rawTokens.filter { token in
            guard token.count >= 3 else { return false }
            if expiredHandoffTopicAnchorNoiseTokens.contains(token) {
                return false
            }
            return !token.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
        }
        return Set(filtered.prefix(limit))
    }

    private func historyWithPreviousSummary(
        _ history: [PromptRewriteConversationTurn],
        from record: ExpiredConversationContextRecord,
        limit: Int
    ) -> [PromptRewriteConversationTurn] {
        let normalizedLimit = normalizedTurnLimit(limit)
        guard normalizedLimit > 1 else { return history }

        let summaryCandidate = expiredHandoffHistory(from: record, limit: 1).first
        guard let summaryTurn = summaryCandidate,
              summaryTurn.isSummary else {
            return history
        }

        let normalizedSummaryText = collapsedWhitespace(summaryTurn.assistantText).lowercased()
        guard !normalizedSummaryText.isEmpty else { return history }

        if history.contains(where: { turn in
            guard turn.isSummary else { return false }
            return collapsedWhitespace(turn.assistantText).lowercased() == normalizedSummaryText
        }) {
            return history
        }

        var output = history
        output.insert(summaryTurn, at: 0)

        while output.count > normalizedLimit {
            if let dropIndex = output.firstIndex(where: { !$0.isSummary }) {
                output.remove(at: dropIndex)
            } else {
                output.removeFirst()
            }
        }

        while estimatedContextCharacters(output) > maxPromptContextCharacters,
              output.count > 1 {
            if let dropIndex = output.firstIndex(where: { !$0.isSummary }) {
                output.remove(at: dropIndex)
            } else {
                output.removeFirst()
            }
        }

        return output
    }

    private func decodedArchivedTurns(from rawJSON: String) -> [PromptRewriteConversationTurn] {
        let normalizedJSON = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedJSON.isEmpty,
              let data = normalizedJSON.data(using: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let turns = try? decoder.decode([PromptRewriteConversationTurn].self, from: data) else {
            return []
        }

        return turns
            .compactMap(sanitizedStoredTurn)
            .sorted { lhs, rhs in lhs.timestamp < rhs.timestamp }
    }

    private func encodedArchivedTurnsJSON(_ turns: [PromptRewriteConversationTurn]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(turns),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private func expiredContextRecordID(
        scopeKey: String,
        threadID: String,
        expiredAt: Date
    ) -> String {
        let epoch = Int(expiredAt.timeIntervalSince1970)
        let seed = "\(scopeKey)|\(threadID)|\(epoch)"
        let digest = MemoryIdentifier.stableHexDigest(for: seed).prefix(24)
        return "expired-\(digest)-\(epoch)"
    }

    private func expiredContextDeleteAfterDate(from date: Date) -> Date {
        if let value = Calendar.current.date(
            byAdding: .day,
            value: expiredSummaryRetentionDays,
            to: date
        ) {
            return value
        }
        return date.addingTimeInterval(Double(expiredSummaryRetentionDays * 24 * 60 * 60))
    }

    private func memoryProviderKindForExpiredHandoff(_ record: ExpiredConversationContextRecord) -> MemoryProviderKind {
        let appName = record.metadata["app_name"] ?? ""
        let combined = "\(record.bundleID) \(appName)".lowercased()
        if combined.contains("codex") { return .codex }
        if combined.contains("opencode") { return .opencode }
        if combined.contains("claude") || combined.contains("anthropic") { return .claude }
        if combined.contains("copilot") || combined.contains("github") { return .copilot }
        if combined.contains("cursor") { return .cursor }
        if combined.contains("kimi") { return .kimi }
        if combined.contains("gemini") || combined.contains("google") { return .gemini }
        if combined.contains("windsurf") { return .windsurf }
        if combined.contains("codeium") { return .codeium }
        return .unknown
    }

    private func enqueueExpiredSummaryAIEnrichment(record: ExpiredConversationContextRecord) {
        guard canRunExpiredSummaryAIEnrichment else { return }
        let timeoutSeconds = max(1, expiredSummaryAITimeoutSeconds)
        let providerKind = memoryProviderKindForExpiredHandoff(record)
        let recordID = record.id
        let fallbackSummary = record.summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackSummary.isEmpty else { return }
        let candidateTurns = decodedArchivedTurns(from: record.recentTurnsJSON)
        let enrichmentTurns = candidateTurns.isEmpty
            ? decodedArchivedTurns(from: record.rawTurnsJSON)
            : candidateTurns
        let enrichmentContext = expiredHandoffEnrichmentContext(for: record)
        let metadata = record.metadata

        Task.detached(priority: .utility) {
            let hasAIAccess = await StubMemoryRewriteExtractionProvider.shared.hasAIBackedIndexingAccess(
                for: providerKind
            )
            guard hasAIAccess else { return }

            let enriched = await StubMemoryRewriteExtractionProvider.shared.summarizeConversationHandoff(
                summarySeed: fallbackSummary,
                recentTurns: enrichmentTurns,
                context: enrichmentContext,
                timeoutSeconds: timeoutSeconds
            )
            let normalizedMethod = enriched.method
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let isAIMethod = normalizedMethod == "ai" || normalizedMethod.hasPrefix("ai-")
            guard isAIMethod else { return }

            let normalizedAISummary = enriched.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedAISummary.isEmpty,
                  normalizedAISummary.caseInsensitiveCompare(fallbackSummary) != .orderedSame else {
                return
            }

            var updatedMetadata = metadata
            updatedMetadata["ai_summary_enriched"] = "true"
            updatedMetadata["ai_summary_timeout_seconds"] = "\(timeoutSeconds)"
            updatedMetadata["ai_summary_updated_at"] = ISO8601DateFormatter().string(from: Date())
            updatedMetadata["summary_method"] = "ai"
            updatedMetadata["summary_method_detail"] = normalizedMethod
            if let confidence = enriched.confidence {
                updatedMetadata["summary_confidence"] = String(format: "%.3f", max(0, min(1, confidence)))
            }

            guard let store = try? MemorySQLiteStore() else { return }
            _ = try? store.updateExpiredConversationContextSummary(
                id: recordID,
                summaryText: normalizedAISummary,
                method: .ai,
                confidence: enriched.confidence,
                metadata: updatedMetadata
            )
        }
    }

    private func expiredHandoffEnrichmentContext(
        for record: ExpiredConversationContextRecord
    ) -> PromptRewriteConversationContext {
        let appName = collapsedWhitespace(record.metadata["app_name"] ?? "Unknown App")
        let screenLabel = collapsedWhitespace(record.metadata["screen_label"] ?? "Current Screen")
        let fieldLabel = collapsedWhitespace(record.metadata["field_label"] ?? "Focused Input")
        let logicalSurfaceKey = collapsedWhitespace(
            record.metadata["logical_surface_key"] ?? "expired-\(record.scopeKey)"
        )
        let projectLabel = collapsedWhitespace(record.metadata["project_label"] ?? "")
        let identityLabel = collapsedWhitespace(record.metadata["identity_label"] ?? "")
        let identityType = collapsedWhitespace(record.metadata["identity_type"] ?? "")
        let nativeThreadKey = collapsedWhitespace(record.metadata["native_thread_key"] ?? "")

        return PromptRewriteConversationContext(
            id: record.threadID,
            appName: appName.isEmpty ? "Unknown App" : appName,
            bundleIdentifier: record.bundleID,
            screenLabel: screenLabel.isEmpty ? "Current Screen" : screenLabel,
            fieldLabel: fieldLabel.isEmpty ? "Focused Input" : fieldLabel,
            logicalSurfaceKey: logicalSurfaceKey,
            projectKey: record.projectKey,
            projectLabel: projectLabel.isEmpty ? nil : projectLabel,
            identityKey: record.identityKey,
            identityType: identityType.isEmpty ? nil : identityType,
            identityLabel: identityLabel.isEmpty ? nil : identityLabel,
            nativeThreadKey: nativeThreadKey.isEmpty ? nil : nativeThreadKey,
            people: []
        )
    }

    private func pruneStaleContexts(timeoutMinutes: Double) {
        guard !contextsByID.isEmpty else { return }

        let timeout = normalizedTimeoutMinutes(timeoutMinutes) * 60
        let now = Date()
        let shouldPersistExpiredHandoff = promptRewriteConversationHistoryEnabled
        let crossIDESharingEnabled = promptRewriteCrossIDEConversationSharingEnabled
        let staleIDs = contextsByID.compactMap { (id, stored) in
            now.timeIntervalSince(stored.lastUpdatedAt) > timeout ? id : nil
        }

        guard !staleIDs.isEmpty else { return }
        for id in staleIDs {
            if let stored = contextsByID[id], !stored.turns.isEmpty {
                let summaryText = compactionSummary(for: stored.turns, context: stored.context)
                if !summaryText.isEmpty {
                    let sourceTurnCount = stored.turns.reduce(into: 0) { partial, turn in
                        if turn.isSummary {
                            partial += max(1, turn.sourceTurnCount ?? 1)
                        } else {
                            partial += 1
                        }
                    }
                    let recentTurns = Array(
                        stored.turns
                            .filter { !$0.isSummary }
                            .suffix(autoCompactionRetainedExchangeTurns)
                    )
                    var expiredScopeKey: String?
                    if shouldPersistExpiredHandoff,
                       let store = resolvedSQLiteStore() {
                        let scopeKey = scopeKeyForExpiredHandoff(
                            context: stored.context,
                            crossIDESharingEnabled: crossIDESharingEnabled
                        )
                        expiredScopeKey = scopeKey
                        var expiredMetadata: [String: String] = [
                            "app_name": stored.context.appName,
                            "screen_label": stored.context.screenLabel,
                            "field_label": stored.context.fieldLabel,
                            "logical_surface_key": stored.context.logicalSurfaceKey,
                            "ai_summary_timeout_seconds": "\(expiredSummaryAITimeoutSeconds)",
                            "retention_days": "\(expiredSummaryRetentionDays)"
                        ]
                        if let projectLabel = stored.context.projectLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !projectLabel.isEmpty {
                            expiredMetadata["project_label"] = projectLabel
                        }
                        if let identityLabel = stored.context.identityLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !identityLabel.isEmpty {
                            expiredMetadata["identity_label"] = identityLabel
                        }
                        if let identityType = stored.context.identityType?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !identityType.isEmpty {
                            expiredMetadata["identity_type"] = identityType
                        }
                        if let nativeThreadKey = stored.context.nativeThreadKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !nativeThreadKey.isEmpty {
                            expiredMetadata["native_thread_key"] = nativeThreadKey
                        }
                        let expiredRecord = ExpiredConversationContextRecord(
                            id: expiredContextRecordID(
                                scopeKey: scopeKey,
                                threadID: stored.context.id,
                                expiredAt: now
                            ),
                            scopeKey: scopeKey,
                            threadID: stored.context.id,
                            bundleID: stored.context.bundleIdentifier,
                            projectKey: contextLinkingKey(stored.context.projectKey, aliasTypeHint: "project"),
                            identityKey: contextLinkingKey(stored.context.identityKey, aliasTypeHint: "identity"),
                            summaryText: summaryText,
                            summaryMethod: .fallback,
                            summaryConfidence: nil,
                            sourceTurnCount: max(1, sourceTurnCount),
                            recentTurnsJSON: encodedArchivedTurnsJSON(recentTurns),
                            rawTurnsJSON: encodedArchivedTurnsJSON(stored.turns),
                            trigger: MemoryPromotionTrigger.timeout.rawValue,
                            expiredAt: now,
                            deleteAfterAt: expiredContextDeleteAfterDate(from: now),
                            consumedAt: nil,
                            consumedByThreadID: nil,
                            metadata: expiredMetadata
                        )
                        try? store.upsertExpiredConversationContext(expiredRecord)
                        enqueueExpiredSummaryAIEnrichment(record: expiredRecord)
                    }
                    enqueueConversationPromotion(
                        context: stored.context,
                        summaryText: summaryText,
                        sourceTurnCount: max(1, sourceTurnCount),
                        compactionVersion: compactionVersion,
                        trigger: .timeout,
                        recentTurns: recentTurns,
                        rawTurns: stored.turns,
                        fallbackSummaryText: summaryText,
                        promotionScopeKey: expiredScopeKey,
                        summaryGenerationMetadata: [
                            "summary_method": "fallback",
                            "ai_timeout_seconds": "\(expiredSummaryAITimeoutSeconds)"
                        ],
                        timestamp: now
                    )
                }
                contextIDByTuple.removeValue(forKey: stored.tupleKey)
            }
            contextsByID.removeValue(forKey: id)
            pendingDuplicateMergeContextIDs.remove(id)
            deleteContextFromSQLite(id: id)
        }
        refreshSummaries()
    }

    private func trimStoredContextsIfNeeded() -> [String] {
        guard contextsByID.count > maxStoredContexts else { return [] }

        let sortedIDs = contextsByID
            .sorted { lhs, rhs in
                lhs.value.lastUpdatedAt > rhs.value.lastUpdatedAt
            }
            .map(\.key)

        var removed: [String] = []
        for id in sortedIDs.dropFirst(maxStoredContexts) {
            if let stored = contextsByID[id] {
                contextIDByTuple.removeValue(forKey: stored.tupleKey)
            }
            contextsByID.removeValue(forKey: id)
            pendingDuplicateMergeContextIDs.remove(id)
            removed.append(id)
        }
        return removed
    }

    private func refreshSummaries() {
        contextSummaries = contextsByID
            .values
            .sorted { lhs, rhs in
                lhs.lastUpdatedAt > rhs.lastUpdatedAt
            }
            .map { stored in
                PromptRewriteConversationContextSummary(
                    id: stored.context.id,
                    displayName: stored.context.displayName,
                    appName: stored.context.appName,
                    screenLabel: stored.context.screenLabel,
                    fieldLabel: stored.context.fieldLabel,
                    projectLabel: stored.context.projectLabel,
                    identityLabel: stored.context.identityLabel,
                    lastUpdatedAt: stored.lastUpdatedAt,
                    turnCount: stored.turns.count
                )
            }
    }

    private func loadFromSQLite() {
        guard FeatureFlags.conversationTupleSQLiteEnabled else {
            contextsByID = [:]
            contextIDByTuple = [:]
            pendingDuplicateMergeContextIDs = []
            return
        }
        guard let store = resolvedSQLiteStore() else {
            contextsByID = [:]
            contextIDByTuple = [:]
            pendingDuplicateMergeContextIDs = []
            return
        }

        let threadRows: [ConversationThreadRecord]
        if let allThreads = try? store.fetchAllConversationThreads() {
            threadRows = allThreads
        } else {
            let startupThreadLimit = min(
                sqliteStartupThreadScanHardLimit,
                max(maxStoredContexts, maxStoredContexts * sqliteStartupThreadScanMultiplier)
            )
            threadRows = (try? store.fetchConversationThreads(limit: startupThreadLimit)) ?? []
        }
        var nextContexts: [String: StoredContext] = [:]
        var nextTupleMap: [ConversationThreadTupleKey: String] = [:]

        for thread in threadRows {
            let sanitizedContext = sanitizedCodexStoredContextValues(
                appName: thread.appName,
                screenLabel: thread.screenLabel,
                projectKey: thread.projectKey,
                projectLabel: thread.projectLabel,
                identityKey: thread.identityKey,
                identityType: thread.identityType,
                identityLabel: thread.identityLabel,
                nativeThreadKey: thread.nativeThreadKey
            )
            if sanitizedContext.screenLabel != thread.screenLabel
                || sanitizedContext.projectKey != thread.projectKey
                || sanitizedContext.projectLabel != thread.projectLabel
                || sanitizedContext.identityKey != thread.identityKey
                || sanitizedContext.identityType != thread.identityType
                || sanitizedContext.identityLabel != thread.identityLabel
                || sanitizedContext.nativeThreadKey != thread.nativeThreadKey {
                var repairedThread = thread
                repairedThread.screenLabel = sanitizedContext.screenLabel
                repairedThread.projectKey = sanitizedContext.projectKey
                repairedThread.projectLabel = sanitizedContext.projectLabel
                repairedThread.identityKey = sanitizedContext.identityKey
                repairedThread.identityType = sanitizedContext.identityType
                repairedThread.identityLabel = sanitizedContext.identityLabel
                repairedThread.nativeThreadKey = sanitizedContext.nativeThreadKey
                repairedThread.people = isCodexConversationApp(thread.appName) ? [] : thread.people
                repairedThread.updatedAt = Date()
                try? store.upsertConversationThread(repairedThread)
            }
            let turns = ((try? store.fetchConversationTurns(threadID: thread.id, limit: maxStoredTurnsPerContext)) ?? [])
                .compactMap(conversationTurn(from:))
            let tags = ConversationTupleTags(
                projectKey: sanitizedContext.projectKey,
                projectLabel: sanitizedContext.projectLabel,
                identityKey: sanitizedContext.identityKey,
                identityType: sanitizedContext.identityType,
                identityLabel: sanitizedContext.identityLabel,
                people: isCodexConversationApp(thread.appName) ? [] : thread.people,
                nativeThreadKey: sanitizedContext.nativeThreadKey
            )
            let context = PromptRewriteConversationContext(
                id: thread.id,
                appName: thread.appName,
                bundleIdentifier: thread.bundleID,
                screenLabel: sanitizedContext.screenLabel,
                fieldLabel: thread.fieldLabel,
                logicalSurfaceKey: thread.logicalSurfaceKey,
                projectKey: sanitizedContext.projectKey,
                projectLabel: sanitizedContext.projectLabel,
                identityKey: sanitizedContext.identityKey,
                identityType: sanitizedContext.identityType,
                identityLabel: sanitizedContext.identityLabel,
                nativeThreadKey: sanitizedContext.nativeThreadKey,
                people: isCodexConversationApp(thread.appName) ? [] : thread.people
            )
            let tupleKey = tagInferenceService.tupleKey(
                capturedContext: context,
                tags: tags
            )
            if let canonicalThreadID = nextTupleMap[tupleKey],
               var canonical = nextContexts[canonicalThreadID] {
                var seenTurnKeys = Set<String>()
                let mergedTurns = (canonical.turns + turns)
                    .sorted { lhs, rhs in
                        lhs.timestamp < rhs.timestamp
                    }
                    .filter { turn in
                        let dedupeKey = [
                            "\(Int((turn.timestamp.timeIntervalSince1970 * 1_000).rounded()))",
                            turn.isSummary ? "1" : "0",
                            turn.userText.lowercased(),
                            turn.assistantText.lowercased()
                        ].joined(separator: "|")
                        if seenTurnKeys.contains(dedupeKey) {
                            return false
                        }
                        seenTurnKeys.insert(dedupeKey)
                        return true
                    }
                canonical.turns = Array(mergedTurns.suffix(maxStoredTurnsPerContext))
                if thread.lastActivityAt > canonical.lastUpdatedAt {
                    canonical.lastUpdatedAt = thread.lastActivityAt
                }
                canonical.totalExchangeTurns = max(
                    canonical.totalExchangeTurns,
                    thread.totalExchangeTurns,
                    canonical.turns.filter { !$0.isSummary }.count
                )
                nextContexts[canonicalThreadID] = canonical
                continue
            }
            let canonicalContext = PromptRewriteConversationContext(
                id: thread.id,
                appName: thread.appName,
                bundleIdentifier: tupleKey.bundleID,
                screenLabel: sanitizedContext.screenLabel,
                fieldLabel: thread.fieldLabel,
                logicalSurfaceKey: tupleKey.logicalSurfaceKey,
                projectKey: sanitizedContext.projectKey,
                projectLabel: sanitizedContext.projectLabel,
                identityKey: sanitizedContext.identityKey,
                identityType: sanitizedContext.identityType,
                identityLabel: sanitizedContext.identityLabel,
                nativeThreadKey: sanitizedContext.nativeThreadKey,
                people: isCodexConversationApp(thread.appName) ? [] : thread.people
            )
            nextContexts[thread.id] = StoredContext(
                context: canonicalContext,
                turns: Array(turns.suffix(maxStoredTurnsPerContext)),
                lastUpdatedAt: thread.lastActivityAt,
                tupleKey: tupleKey,
                totalExchangeTurns: max(
                    thread.totalExchangeTurns,
                    turns.filter { !$0.isSummary }.count
                )
            )
            nextTupleMap[tupleKey] = thread.id
        }

        if nextContexts.count > maxStoredContexts {
            let keepIDs = Set(
                nextContexts.values
                    .sorted { lhs, rhs in lhs.lastUpdatedAt > rhs.lastUpdatedAt }
                    .prefix(maxStoredContexts)
                    .map { $0.context.id }
            )
            nextContexts = nextContexts.filter { keepIDs.contains($0.key) }
            nextTupleMap = nextTupleMap.filter { keepIDs.contains($0.value) }
        }

        contextsByID = nextContexts
        contextIDByTuple = nextTupleMap
        pendingDuplicateMergeContextIDs = []
    }

    private func persistContext(_ stored: StoredContext) {
        guard FeatureFlags.conversationTupleSQLiteEnabled else { return }
        guard let store = resolvedSQLiteStore() else { return }
        let shouldCheckForDuplicateThreads = pendingDuplicateMergeContextIDs.contains(stored.context.id)

        let sanitizedContext = sanitizedCodexStoredContextValues(
            appName: stored.context.appName,
            screenLabel: stored.context.screenLabel,
            projectKey: stored.context.projectKey,
            projectLabel: stored.context.projectLabel,
            identityKey: stored.context.identityKey,
            identityType: stored.context.identityType,
            identityLabel: stored.context.identityLabel,
            nativeThreadKey: stored.context.nativeThreadKey
        )
        let runningSummary = stored.turns.reversed().first(where: \.isSummary)?.assistantText ?? ""
        let exchangeTurnCount = max(stored.totalExchangeTurns, stored.turns.filter { !$0.isSummary }.count)
        let thread = ConversationThreadRecord(
            id: stored.context.id,
            appName: stored.context.appName,
            bundleID: stored.tupleKey.bundleID,
            logicalSurfaceKey: stored.tupleKey.logicalSurfaceKey,
            screenLabel: sanitizedContext.screenLabel,
            fieldLabel: stored.context.fieldLabel,
            projectKey: sanitizedContext.projectKey,
            projectLabel: sanitizedContext.projectLabel,
            identityKey: sanitizedContext.identityKey,
            identityType: sanitizedContext.identityType,
            identityLabel: sanitizedContext.identityLabel,
            nativeThreadKey: sanitizedContext.nativeThreadKey,
            people: isCodexContext(stored.context) ? [] : stored.context.people,
            runningSummary: runningSummary,
            totalExchangeTurns: exchangeTurnCount,
            createdAt: stored.turns.first?.timestamp ?? stored.lastUpdatedAt,
            lastActivityAt: stored.lastUpdatedAt,
            updatedAt: Date()
        )

        let turnRecords = stored.turns.map { turn in
            conversationTurnRecord(
                turn,
                threadID: stored.context.id
            )
        }

        do {
            try store.upsertConversationThread(thread)
            try store.replaceConversationTurns(
                threadID: stored.context.id,
                turns: turnRecords,
                runningSummary: runningSummary,
                totalExchangeTurns: exchangeTurnCount,
                lastActivityAt: stored.lastUpdatedAt,
                updatedAt: Date()
            )
            if shouldCheckForDuplicateThreads {
                try mergeDuplicateThreadsIfNeeded(for: stored.context.id, tupleKey: stored.tupleKey)
                pendingDuplicateMergeContextIDs.remove(stored.context.id)
            }
        } catch {
            // Best-effort persistence to avoid blocking rewrite flow.
        }
    }

    private func sanitizedCodexStoredContextValues(
        appName: String,
        screenLabel: String,
        projectKey: String?,
        projectLabel: String?,
        identityKey: String?,
        identityType: String?,
        identityLabel: String?,
        nativeThreadKey: String?
    ) -> (
        screenLabel: String,
        projectKey: String,
        projectLabel: String,
        identityKey: String,
        identityType: String,
        identityLabel: String,
        nativeThreadKey: String
    ) {
        if isCodexConversationApp(appName) {
            return (
                screenLabel: codexConversationScreenLabel,
                projectKey: codexConversationProjectKey,
                projectLabel: codexConversationProjectLabel,
                identityKey: codexConversationIdentityKey,
                identityType: codexConversationIdentityType,
                identityLabel: codexConversationIdentityLabel,
                nativeThreadKey: codexConversationNativeThreadKey
            )
        }
        let resolvedProjectKey = projectKey ?? "project:unknown"
        let resolvedProjectLabel = projectLabel ?? "Unknown Project"
        let resolvedIdentityKey = identityKey ?? "identity:unknown"
        let resolvedIdentityType = identityType ?? "unknown"
        let resolvedIdentityLabel = identityLabel ?? "Unknown Identity"
        let resolvedNativeThreadKey = nativeThreadKey ?? ""
        return (
            screenLabel: screenLabel,
            projectKey: resolvedProjectKey,
            projectLabel: resolvedProjectLabel,
            identityKey: resolvedIdentityKey,
            identityType: resolvedIdentityType,
            identityLabel: resolvedIdentityLabel,
            nativeThreadKey: resolvedNativeThreadKey
        )
    }

    private func isCodexConversationApp(_ appName: String) -> Bool {
        appName.localizedCaseInsensitiveContains("codex")
    }

    private func deleteContextFromSQLite(id: String) {
        guard FeatureFlags.conversationTupleSQLiteEnabled else { return }
        guard let store = resolvedSQLiteStore() else { return }
        try? store.deleteConversationThread(id: id)
    }

    private func clearAllContextsInSQLite() {
        guard FeatureFlags.conversationTupleSQLiteEnabled else { return }
        guard let store = resolvedSQLiteStore() else { return }
        try? store.clearAllConversationThreads()
    }

    private func resolvedSQLiteStore() -> MemorySQLiteStore? {
        if let sqliteStore {
            return sqliteStore
        }
        guard let created = try? sqliteStoreFactory() else {
            return nil
        }
        sqliteStore = created
        return created
    }

    private var isConversationRedirectWriteEnabled: Bool {
        if UserDefaults.standard.object(forKey: redirectWriteFlagUserDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: redirectWriteFlagUserDefaultsKey)
        }
        if let rawValue = ProcessInfo.processInfo.environment[redirectWriteFlagEnvironmentKey],
           let parsed = parsedFeatureFlagBoolean(rawValue) {
            return parsed
        }
        return true
    }

    private func parsedFeatureFlagBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled":
            return true
        case "0", "false", "no", "off", "disabled":
            return false
        default:
            return nil
        }
    }

    private func resolvedConversationThreadIDWithRedirect(
        _ threadID: String,
        store: MemorySQLiteStore?
    ) -> String {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return "" }
        guard let store else { return normalizedThreadID }

        var resolvedThreadID = normalizedThreadID
        var visited = Set<String>()
        for _ in 0..<6 {
            guard !visited.contains(resolvedThreadID) else {
                break
            }
            visited.insert(resolvedThreadID)
            guard let redirectedID = (try? store.resolveConversationThreadRedirect(resolvedThreadID))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !redirectedID.isEmpty,
                  redirectedID.caseInsensitiveCompare(resolvedThreadID) != .orderedSame else {
                break
            }
            resolvedThreadID = redirectedID
        }
        return resolvedThreadID
    }

    private func loadStoredContextFromSQLite(
        threadID: String,
        store: MemorySQLiteStore
    ) -> StoredContext? {
        let resolvedThreadID = resolvedConversationThreadIDWithRedirect(
            threadID,
            store: store
        )
        guard !resolvedThreadID.isEmpty,
              let thread = try? store.fetchConversationThread(id: resolvedThreadID) else {
            return nil
        }

        let context = PromptRewriteConversationContext(
            id: thread.id,
            appName: thread.appName,
            bundleIdentifier: thread.bundleID,
            screenLabel: thread.screenLabel,
            fieldLabel: thread.fieldLabel,
            logicalSurfaceKey: thread.logicalSurfaceKey,
            projectKey: thread.projectKey,
            projectLabel: thread.projectLabel,
            identityKey: thread.identityKey,
            identityType: thread.identityType,
            identityLabel: thread.identityLabel,
            nativeThreadKey: thread.nativeThreadKey,
            people: thread.people
        )
        let tags = ConversationTupleTags(
            projectKey: thread.projectKey,
            projectLabel: thread.projectLabel,
            identityKey: thread.identityKey,
            identityType: thread.identityType,
            identityLabel: thread.identityLabel,
            people: thread.people,
            nativeThreadKey: thread.nativeThreadKey
        )
        let tupleKey = tagInferenceService.tupleKey(
            capturedContext: context,
            tags: tags
        )
        let loadedTurns = ((try? store.fetchConversationTurns(threadID: thread.id, limit: maxStoredTurnsPerContext)) ?? [])
            .compactMap(conversationTurn(from:))
        let loaded = StoredContext(
            context: PromptRewriteConversationContext(
                id: thread.id,
                appName: thread.appName,
                bundleIdentifier: tupleKey.bundleID,
                screenLabel: thread.screenLabel,
                fieldLabel: thread.fieldLabel,
                logicalSurfaceKey: tupleKey.logicalSurfaceKey,
                projectKey: thread.projectKey,
                projectLabel: thread.projectLabel,
                identityKey: thread.identityKey,
                identityType: thread.identityType,
                identityLabel: thread.identityLabel,
                nativeThreadKey: thread.nativeThreadKey,
                people: thread.people
            ),
            turns: Array(loadedTurns.suffix(maxStoredTurnsPerContext)),
            lastUpdatedAt: thread.lastActivityAt,
            tupleKey: tupleKey,
            totalExchangeTurns: max(
                thread.totalExchangeTurns,
                loadedTurns.filter { !$0.isSummary }.count
            )
        )
        contextsByID[thread.id] = loaded
        contextIDByTuple[tupleKey] = thread.id
        return loaded
    }

    private func attemptCodexProjectCorrectionIfNeeded(
        capturedContext: PromptRewriteConversationContext,
        tags: ConversationTupleTags,
        tupleKey: ConversationThreadTupleKey,
        store: MemorySQLiteStore
    ) -> Bool {
        return false
    }

    private func isCodexContext(_ context: PromptRewriteConversationContext) -> Bool {
        let normalizedBundle = context.bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedBundle == "com.openai.codex" {
            return true
        }
        return context.appName.localizedCaseInsensitiveContains("codex")
    }

    private func isMeaningfulCodexProjectKey(_ projectKey: String) -> Bool {
        let normalized = projectKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.hasPrefix("project:")
            && normalized != "project:unknown"
    }

    private func hasMeaningfulCodexCorrectionIdentity(_ tags: ConversationTupleTags) -> Bool {
        let normalizedIdentity = tags.identityKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedNativeThread = tags.nativeThreadKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !normalizedNativeThread.isEmpty
            || (normalizedIdentity != "identity:unknown" && !normalizedIdentity.isEmpty)
    }

    private func reuseKnownCodexProjectIfNeeded(
        capturedContext: PromptRewriteConversationContext,
        tags: ConversationTupleTags,
        store: MemorySQLiteStore
    ) -> ConversationTupleTags {
        return tags
    }

    private func isCodexKnownProjectReuseCandidate(
        _ thread: ConversationThreadRecord,
        nativeThreadKey: String,
        now: Date
    ) -> Bool {
        guard thread.appName.localizedCaseInsensitiveContains("codex") else {
            return false
        }
        guard isMeaningfulCodexProjectKey(thread.projectKey) else {
            return false
        }
        guard now.timeIntervalSince(thread.lastActivityAt) <= codexProjectCorrectionMaxAgeSeconds else {
            return false
        }

        let candidateNativeThread = thread.nativeThreadKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !candidateNativeThread.isEmpty
            && candidateNativeThread == nativeThreadKey
    }

    private func isCodexUnknownProjectCorrectionCandidate(
        _ thread: ConversationThreadRecord,
        tags: ConversationTupleTags,
        targetThreadID: String,
        now: Date
    ) -> Bool {
        guard thread.id.caseInsensitiveCompare(targetThreadID) != .orderedSame else {
            return false
        }
        guard thread.appName.localizedCaseInsensitiveContains("codex") else {
            return false
        }
        guard thread.projectKey.caseInsensitiveCompare("project:unknown") == .orderedSame else {
            return false
        }
        guard now.timeIntervalSince(thread.lastActivityAt) <= codexProjectCorrectionMaxAgeSeconds else {
            return false
        }

        let normalizedNativeThread = tags.nativeThreadKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let candidateNativeThread = thread.nativeThreadKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !normalizedNativeThread.isEmpty {
            if candidateNativeThread == normalizedNativeThread {
                return true
            }
        }

        let normalizedIdentity = tags.identityKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let candidateIdentity = thread.identityKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedIdentity != "identity:unknown" else {
            return false
        }
        return candidateIdentity == normalizedIdentity
    }

    private func mergedConversationTurns(
        _ turnGroups: [[PromptRewriteConversationTurn]]
    ) -> [PromptRewriteConversationTurn] {
        var seenTurnKeys = Set<String>()
        return turnGroups
            .flatMap { $0 }
            .sorted { lhs, rhs in
                lhs.timestamp < rhs.timestamp
            }
            .filter { turn in
                let dedupeKey = [
                    "\(Int((turn.timestamp.timeIntervalSince1970 * 1_000).rounded()))",
                    turn.isSummary ? "1" : "0",
                    turn.userText.lowercased(),
                    turn.assistantText.lowercased(),
                    "\(turn.sourceTurnCount ?? 0)",
                    "\(turn.compactionVersion ?? -1)"
                ].joined(separator: "|")
                if seenTurnKeys.contains(dedupeKey) {
                    return false
                }
                seenTurnKeys.insert(dedupeKey)
                return true
            }
    }

    private func mergeDuplicateThreadsIfNeeded(
        for canonicalThreadID: String,
        tupleKey: ConversationThreadTupleKey
    ) throws {
        guard let store = resolvedSQLiteStore() else { return }
        let threads: [ConversationThreadRecord]
        if let allThreads = try? store.fetchAllConversationThreads() {
            threads = allThreads
        } else {
            let duplicateMergeScanLimit = min(
                duplicateMergeThreadScanHardLimit,
                max(maxStoredContexts, maxStoredContexts * duplicateMergeThreadScanMultiplier)
            )
            threads = try store.fetchConversationThreads(limit: duplicateMergeScanLimit)
        }
        let duplicates = threads.filter {
            $0.id != canonicalThreadID
                && $0.bundleID.caseInsensitiveCompare(tupleKey.bundleID) == .orderedSame
                && $0.logicalSurfaceKey.caseInsensitiveCompare(tupleKey.logicalSurfaceKey) == .orderedSame
                && $0.projectKey.caseInsensitiveCompare(tupleKey.projectKey) == .orderedSame
                && $0.identityKey.caseInsensitiveCompare(tupleKey.identityKey) == .orderedSame
                && $0.nativeThreadKey.caseInsensitiveCompare(tupleKey.nativeThreadKey) == .orderedSame
        }
        guard !duplicates.isEmpty else { return }
        guard isConversationRedirectWriteEnabled else { return }
        for duplicate in duplicates {
            try store.upsertConversationThreadRedirect(
                oldThreadID: duplicate.id,
                newThreadID: canonicalThreadID,
                reason: "Merged duplicate tuple thread."
            )
            try store.deleteConversationThread(
                id: duplicate.id,
                preserveRedirects: true
            )
            contextsByID.removeValue(forKey: duplicate.id)
            pendingDuplicateMergeContextIDs.remove(duplicate.id)
        }
    }

    private func collapsedWhitespace(_ value: String) -> String {
        let parts = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    private func conversationTurn(from record: ConversationTurnRecord) -> PromptRewriteConversationTurn? {
        if record.isSummary {
            return PromptRewriteConversationTurn(
                userText: "Compacted conversation summary",
                assistantText: record.assistantText,
                timestamp: record.createdAt,
                isSummary: true,
                sourceTurnCount: max(1, record.sourceTurnCount),
                compactionVersion: record.compactionVersion
            )
        }
        let normalizedUser = collapsedWhitespace(record.userText)
        let normalizedAssistant = sanitizedAssistantTurnText(
            record.assistantText,
            originalUserText: normalizedUser
        )
        guard !normalizedUser.isEmpty, !normalizedAssistant.isEmpty else {
            return nil
        }
        return PromptRewriteConversationTurn(
            userText: normalizedUser,
            assistantText: normalizedAssistant,
            timestamp: record.createdAt,
            isSummary: false
        )
    }

    private func conversationTurnRecord(
        _ turn: PromptRewriteConversationTurn,
        threadID: String
    ) -> ConversationTurnRecord {
        let turnRole = turn.isSummary ? "summary" : "assistant"
        let normalized = collapsedWhitespace("\(turn.userText) \(turn.assistantText)")
        let dedupeSeed = [
            threadID,
            turnRole,
            normalized.lowercased(),
            turn.isSummary ? "1" : "0",
            "\(max(1, turn.sourceTurnCount ?? 1))",
            "\(Int((turn.timestamp.timeIntervalSince1970 * 1_000).rounded()))"
        ].joined(separator: "|")
        let dedupeKey = MemoryIdentifier.stableHexDigest(for: dedupeSeed)
        let turnID = "turn-\(dedupeKey.prefix(24))-\(Int(turn.timestamp.timeIntervalSince1970))"
        return ConversationTurnRecord(
            id: turnID,
            threadID: threadID,
            role: turnRole,
            userText: turn.userText,
            assistantText: turn.assistantText,
            normalizedText: normalized,
            isSummary: turn.isSummary,
            sourceTurnCount: max(1, turn.sourceTurnCount ?? 1),
            compactionVersion: turn.compactionVersion,
            metadata: [:],
            createdAt: turn.timestamp,
            turnDedupeKey: dedupeKey
        )
    }

    private func estimatedContextCharacters(_ turns: [PromptRewriteConversationTurn]) -> Int {
        turns.reduce(into: 0) { partial, turn in
            partial += turn.userText.count
            partial += turn.assistantText.count
        }
    }

    private func sanitizedStoredTurn(_ turn: PromptRewriteConversationTurn) -> PromptRewriteConversationTurn? {
        if turn.isSummary {
            let normalizedSummary = collapsedWhitespace(turn.assistantText)
            guard !normalizedSummary.isEmpty else { return nil }
            return PromptRewriteConversationTurn(
                userText: "Compacted conversation summary",
                assistantText: normalizedSummary,
                timestamp: turn.timestamp,
                isSummary: true,
                sourceTurnCount: turn.sourceTurnCount,
                compactionVersion: turn.compactionVersion
            )
        }

        let normalizedUser = collapsedWhitespace(turn.userText)
        let normalizedAssistant = sanitizedAssistantTurnText(
            turn.assistantText,
            originalUserText: normalizedUser
        )
        guard !normalizedUser.isEmpty, !normalizedAssistant.isEmpty else {
            return nil
        }
        return PromptRewriteConversationTurn(
            userText: normalizedUser,
            assistantText: normalizedAssistant,
            timestamp: turn.timestamp,
            isSummary: false
        )
    }

    private func sanitizedAssistantTurnText(_ value: String, originalUserText: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let strippedContextLeak = strippedTeamsContextLeak(from: trimmed)
        let strippedCommandSuffix = strippedCommandInstructionSuffix(
            from: strippedContextLeak,
            originalUserText: originalUserText
        )
        let normalizedCandidate = strippedCommandSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCandidate.isEmpty else { return "" }

        let lowered = normalizedCandidate.lowercased()
        let metadataMarkers = [
            "original prompt:",
            "conversation context",
            "recent conversation turns",
            "rewrite lessons payload",
            "supporting memory cards payload"
        ]
        let markerMatches = metadataMarkers.reduce(into: 0) { partial, marker in
            if lowered.contains(marker) {
                partial += 1
            }
        }

        if markerMatches >= 2,
           let extracted = extractedPromptBody(from: normalizedCandidate) {
            return collapsedWhitespace(extracted)
        }

        return collapsedWhitespace(normalizedCandidate)
    }

    private func strippedCommandInstructionSuffix(from suggestion: String, originalUserText: String) -> String {
        if mentionsCommandInstruction(originalUserText) {
            return suggestion
        }

        var lines = suggestion.components(separatedBy: .newlines)
        while let last = lines.last,
              looksLikeCommandInstructionLine(last) {
            lines.removeLast()
        }
        let output = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return suggestion }

        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)^(.*?)(?:[\s\n\r]+|[.!?]\s+)\s*>?\s*(?:run|execute|use)\s+(?:the\s+)?command\s*:\s*[^\n]{1,220}\s*$"#,
            options: []
        ) else {
            return output
        }
        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let keptRange = Range(match.range(at: 1), in: output) else {
            return output
        }

        let kept = String(output[keptRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if kept.count >= 12 {
            return kept
        }
        return output
    }

    private func looksLikeCommandInstructionLine(_ line: String) -> Bool {
        let normalized = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\s*>+\s*"#, with: "", options: .regularExpression)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        if normalized.range(
            of: #"^(?:run|execute|use)\s+(?:the\s+)?command\s*:"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if normalized.hasPrefix("open command palette")
            || normalized.hasPrefix("in command palette")
            || normalized.hasPrefix("press cmd+shift+p")
            || normalized.hasPrefix("press command+shift+p") {
            return true
        }

        return false
    }

    private func mentionsCommandInstruction(_ text: String) -> Bool {
        let normalized = collapsedWhitespace(text).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.contains("run the command:")
            || normalized.contains("execute the command:")
            || normalized.contains("use the command:")
            || normalized.contains("command palette")
            || normalized.contains("cmd+shift+p")
            || normalized.contains("command+shift+p") {
            return true
        }
        return false
    }

    private func strippedTeamsContextLeak(from value: String) -> String {
        var output = value

        if let prefixRegex = try? NSRegularExpression(
            pattern: #"(?is)^\s*(?:in|for)\s+microsoft\s+teams,\s*project:\s*[^\n]{0,260}\b(?:type a message|focused input)\b[,:;\-\s]*"#,
            options: []
        ) {
            let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
            output = prefixRegex.stringByReplacingMatches(in: output, options: [], range: fullRange, withTemplate: "")
        }

        if let suffixRegex = try? NSRegularExpression(
            pattern: #"(?is)\s+in\s+microsoft\s+teams,\s*project:\s*[^\n]{0,260}$"#,
            options: []
        ) {
            let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
            output = suffixRegex.stringByReplacingMatches(in: output, options: [], range: fullRange, withTemplate: "")
        }

        return output
    }

    private func extractedPromptBody(from value: String) -> String? {
        let pattern = #"(?is)Original\s*prompt\s*:\s*(.+?)(?:\n\s*Conversation\s*context|\n\s*Recent\s*conversation\s*turns|\n\s*Rewrite\s*lessons\s*payload|\n\s*Supporting\s*memory\s*cards\s*payload|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func snippet(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 3))) + "..."
    }

    private func enqueueConversationPromotion(
        context: PromptRewriteConversationContext,
        summaryText: String,
        sourceTurnCount: Int,
        compactionVersion: Int?,
        trigger: MemoryPromotionTrigger,
        recentTurns: [PromptRewriteConversationTurn],
        rawTurns: [PromptRewriteConversationTurn]? = nil,
        fallbackSummaryText: String? = nil,
        promotionScopeKey: String? = nil,
        summaryGenerationMetadata: [String: String] = [:],
        timestamp: Date
    ) {
        let tupleTags: ConversationTupleTags?
        if let projectKey = context.projectKey,
           let projectLabel = context.projectLabel,
           let identityKey = context.identityKey,
           let identityType = context.identityType,
           let identityLabel = context.identityLabel {
            tupleTags = ConversationTupleTags(
                projectKey: projectKey,
                projectLabel: projectLabel,
                identityKey: identityKey,
                identityType: identityType,
                identityLabel: identityLabel,
                people: context.people,
                nativeThreadKey: context.nativeThreadKey ?? ""
            )
        } else {
            tupleTags = nil
        }

        let payload = ConversationMemoryPromotionPayload(
            threadID: context.id,
            tupleTags: tupleTags,
            context: context,
            summaryText: summaryText,
            fallbackSummaryText: fallbackSummaryText,
            rawTurns: rawTurns,
            promotionScopeKey: promotionScopeKey,
            summaryGenerationMetadata: summaryGenerationMetadata,
            sourceTurnCount: max(1, sourceTurnCount),
            compactionVersion: compactionVersion,
            trigger: trigger,
            recentTurns: recentTurns,
            timestamp: timestamp
        )
        Task {
            await ConversationMemoryPromotionService.shared.promote(payload)
        }
    }
}

enum PromptRewriteConversationContextResolver {
    private static let antigravityTextNodeScanLimit = 480
    private static let codexTextNodeScanLimit = 480
    private static let codexTopBarTraversalLimit = 1200
    private static let codexSidebarTraversalLimit = 1200
    private static let codexVisualSidebarAncestorDepth = 8
    private static let codexVisualMainContentMinXFraction: CGFloat = 0.30
    private static let codexVisualSidebarMaxXFraction: CGFloat = 0.34
    private static let codexVisualSidebarMinHighlightScore = 0.035
    private static let codexVisualSidebarMinHighlightGap = 0.012
    private static let codexVisualOCRMinimumTextHeight: Float = 0.009
    private static let telegramTextNodeScanLimit = 900
    private static let genericFocusedFieldRoles: Set<String> = [
        "axtextarea",
        "axtextfield",
        "axsearchfield",
        "axcombobox"
    ]
    private static let heavyAXValueRoles: Set<String> = [
        "axtextarea",
        "axtextfield",
        "axsearchfield",
        "axcombobox",
        "axwebarea",
        "axdocument",
        "axscrollarea"
    ]

    static func captureCurrentContext(
        fallbackApp: NSRunningApplication?,
        screenLabel: String? = nil
    ) -> PromptRewriteConversationContext {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app: NSRunningApplication?
        if let frontmost,
           frontmost.processIdentifier != selfPID {
            app = frontmost
        } else if let fallbackApp,
           fallbackApp.processIdentifier != selfPID,
           !fallbackApp.isTerminated {
            app = fallbackApp
        } else {
            app = nil
        }

        let appName = normalizedLabel(app?.localizedName) ?? "Current App"
        let bundleID = normalizedLabel(app?.bundleIdentifier) ?? "unknown.app"

        let metadata = focusedElementMetadata(app: app)
        let preferredScreenLabel = normalizedLabel(screenLabel)
        let inferredScreenLabel = normalizedLabel(metadata.windowTitle) ?? normalizedLabel(metadata.documentLabel)
        let screenLabel: String
        if let preferredScreenLabel,
           preferredScreenLabel.caseInsensitiveCompare("Current Screen") != .orderedSame,
           !preferredScreenLabel.isEmpty {
            screenLabel = preferredScreenLabel
        } else {
            screenLabel = inferredScreenLabel ?? "Current Screen"
        }
        let fieldLabel = metadata.fieldLabel ?? "Focused Input"

        let signature = [
            bundleID.lowercased(),
            collapsedWhitespace(screenLabel).lowercased(),
            collapsedWhitespace(fieldLabel).lowercased()
        ].joined(separator: "|")

        let digest = SHA256.hash(data: Data(signature.utf8))
        let digestPrefix = digest.map { String(format: "%02x", $0) }.joined().prefix(20)
        let logicalSurfaceKey = "surface-\(digestPrefix)"
        let contextID = "ctx-\(digestPrefix)"

        return PromptRewriteConversationContext(
            id: contextID,
            appName: appName,
            bundleIdentifier: bundleID,
            screenLabel: snippet(screenLabel, limit: 56),
            fieldLabel: snippet(fieldLabel, limit: 48),
            logicalSurfaceKey: logicalSurfaceKey
        )
    }

    private struct FocusMetadata {
        let windowTitle: String?
        let documentLabel: String?
        let fieldLabel: String?
    }

    private static func focusedElementMetadata(app: NSRunningApplication?) -> FocusMetadata {
        guard AXIsProcessTrusted() else {
            return FocusMetadata(windowTitle: nil, documentLabel: nil, fieldLabel: nil)
        }

        let fallbackWindowElement = frontmostFocusedWindowElement()

        let systemWide = AXUIElementCreateSystemWide()
        guard let focusedElement = axElementAttribute(kAXFocusedUIElementAttribute as CFString, from: systemWide) else {
            let windowTitle = fallbackWindowElement
                .flatMap { axStringAttribute(kAXTitleAttribute as CFString, from: $0) }
                ?? frontmostFocusedWindowTitle()
            let documentPath = fallbackWindowElement
                .flatMap { axStringAttribute(kAXDocumentAttribute as CFString, from: $0) }
            let documentLabel = documentPath.flatMap(deriveDocumentLabel)
            let appSpecificContextLabel = codexContextLabel(
                app: app,
                windowElement: fallbackWindowElement,
                fallbackWindowTitle: windowTitle
            ) ?? antigravityContextLabel(
                app: app,
                windowElement: fallbackWindowElement,
                fallbackWindowTitle: windowTitle
            ) ?? telegramContextLabel(
                app: app,
                windowElement: fallbackWindowElement,
                fallbackWindowTitle: windowTitle
            )
            let resolvedWindowTitle = appSpecificContextLabel ?? windowTitle
            return FocusMetadata(
                windowTitle: normalizedLabel(resolvedWindowTitle),
                documentLabel: documentLabel,
                fieldLabel: nil
            )
        }

        let role = axStringAttribute(kAXRoleAttribute as CFString, from: focusedElement)
        let subrole = axStringAttribute(kAXSubroleAttribute as CFString, from: focusedElement)
        let title = axStringAttribute(kAXTitleAttribute as CFString, from: focusedElement)
        let identifier = axStringAttribute(kAXIdentifierAttribute as CFString, from: focusedElement)
        let description = axStringAttribute(kAXDescriptionAttribute as CFString, from: focusedElement)
        let placeholder = axStringAttribute(kAXPlaceholderValueAttribute as CFString, from: focusedElement)
        let normalizedRole = normalizedAXRole(role)

        var fieldCandidates: [String?] = [title, placeholder, identifier]
        if !isGenericFocusedFieldRole(normalizedRole) {
            fieldCandidates.append(description)
            fieldCandidates.append(role)
        }
        let fieldComponents = fieldCandidates
            .compactMap(normalizedLabel)
            .filter { !$0.isEmpty }
        let resolvedFieldLabel: String?
        if let first = fieldComponents.first {
            if let subrole = normalizedLabel(subrole), !subrole.isEmpty,
               !first.localizedCaseInsensitiveContains(subrole) {
                resolvedFieldLabel = "\(first) (\(subrole))"
            } else {
                resolvedFieldLabel = first
            }
        } else if !isGenericFocusedFieldRole(normalizedRole),
                  let role = normalizedLabel(role),
                  !role.isEmpty {
            if let subrole = normalizedLabel(subrole), !subrole.isEmpty {
                resolvedFieldLabel = "\(role) (\(subrole))"
            } else {
                resolvedFieldLabel = role
            }
        } else {
            resolvedFieldLabel = nil
        }

        let fieldLabel: String?
        if let resolvedFieldLabel,
           isGenericAXRoleLabel(resolvedFieldLabel) {
            fieldLabel = nil
        } else {
            fieldLabel = resolvedFieldLabel
        }

        let windowElement = axElementAttribute(kAXWindowAttribute as CFString, from: focusedElement)
            ?? fallbackWindowElement
        let windowTitle = windowElement.flatMap { axStringAttribute(kAXTitleAttribute as CFString, from: $0) }
            ?? frontmostFocusedWindowTitle()
        let documentPath = windowElement.flatMap { axStringAttribute(kAXDocumentAttribute as CFString, from: $0) }
        let documentLabel = documentPath.flatMap(deriveDocumentLabel)
        let appSpecificContextLabel = codexContextLabel(
            app: app,
            windowElement: windowElement,
            fallbackWindowTitle: windowTitle
        ) ?? antigravityContextLabel(
            app: app,
            windowElement: windowElement,
            fallbackWindowTitle: windowTitle
        ) ?? telegramContextLabel(
            app: app,
            windowElement: windowElement,
            fallbackWindowTitle: windowTitle
        )
        let resolvedWindowTitle = appSpecificContextLabel ?? windowTitle

        return FocusMetadata(
            windowTitle: normalizedLabel(resolvedWindowTitle),
            documentLabel: documentLabel,
            fieldLabel: fieldLabel
        )
    }

    private struct AXTextNode {
        let text: String
        let role: String
        let selected: Bool
        let element: AXUIElement?
    }

    private struct AXLabelEntry {
        let label: String
        let role: String
        let element: AXUIElement
    }

    private struct CodexWindowScreenshot {
        let image: CGImage
        let windowFrame: CGRect
        let imageSize: CGSize
    }

    struct CodexVisualTextObservationCandidate {
        let text: String
        let bounds: CGRect

        init(text: String, bounds: CGRect) {
            self.text = text
            self.bounds = bounds
        }
    }

    private struct CodexVisualInference {
        let mainContentProject: String?
        let sidebarProject: String?
    }

    private struct CodexSidebarVisualCandidate {
        let project: String
        let frame: CGRect
    }

    private struct CodexVisualRegionStats {
        let luminance: Double
        let saturation: Double
    }

    private static func codexContextLabel(
        app: NSRunningApplication?,
        windowElement: AXUIElement?,
        fallbackWindowTitle: String?
    ) -> String? {
        guard isCodexApp(app) else { return nil }
        return "Current Screen"
    }

    private static func antigravityContextLabel(
        app: NSRunningApplication?,
        windowElement: AXUIElement?,
        fallbackWindowTitle: String?
    ) -> String? {
        guard isAntigravityApp(app), let windowElement else { return nil }
        let inferred = inferAntigravityProjectAndThread(
            from: windowElement,
            fallbackWindowTitle: fallbackWindowTitle
        )
        var segments: [String] = []
        if let project = inferred.project,
           !project.isEmpty {
            segments.append("Project: \(project)")
        }
        if let thread = inferred.thread,
           !thread.isEmpty {
            segments.append("Thread: \(thread)")
        }
        guard !segments.isEmpty else { return nil }
        CrashReporter.logInfo(
            """
            Antigravity context inferred \
            project=\(inferred.project ?? "nil") \
            thread=\(inferred.thread ?? "nil")
            """
        )
        return segments.joined(separator: " | ")
    }

    private static func telegramContextLabel(
        app: NSRunningApplication?,
        windowElement: AXUIElement?,
        fallbackWindowTitle: String?
    ) -> String? {
        guard isTelegramApp(app), let windowElement else { return nil }
        guard let chat = inferTelegramChatName(
            from: windowElement,
            fallbackWindowTitle: fallbackWindowTitle
        ) else {
            return nil
        }
        CrashReporter.logInfo("Telegram context inferred chat=\(chat)")
        return "Chat: \(chat)"
    }

    private static func inferAntigravityProjectAndThread(
        from windowElement: AXUIElement,
        fallbackWindowTitle: String?
    ) -> (project: String?, thread: String?) {
        let textNodes = collectTextNodes(from: windowElement, limit: antigravityTextNodeScanLimit)
        let allTexts = textNodes.map(\.text)

        var project = antigravityProjectFromWindowTitle(fallbackWindowTitle)
        if project == nil {
            project = allTexts.compactMap(antigravityProjectFromWindowTitle).first
        }

        let headingThread = textNodes.first {
            $0.role.caseInsensitiveCompare("AXHeading") == .orderedSame &&
                looksLikeAntigravityThreadTitle($0.text, project: project)
        }?.text
        let fallbackThread = textNodes.first {
            ($0.role.caseInsensitiveCompare("AXStaticText") == .orderedSame ||
                $0.role.caseInsensitiveCompare("AXHeading") == .orderedSame) &&
                looksLikeAntigravityThreadTitle($0.text, project: project)
        }?.text

        return (project, headingThread ?? fallbackThread)
    }

    private static func antigravityProjectFromWindowTitle(_ value: String?) -> String? {
        guard let normalizedValue = normalizedLabel(value) else { return nil }
        let separators = [" — ", " – "]
        for separator in separators where normalizedValue.contains(separator) {
            let segments = normalizedValue
                .components(separatedBy: separator)
                .map {
                    $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                }
                .filter { !$0.isEmpty }
            guard segments.count >= 2 else { continue }
            let candidate = segments[0]
            guard !isAntigravityControlLabel(candidate) else { continue }
            if let normalized = normalizedProjectName(candidate) {
                return normalized
            }
        }
        return nil
    }

    private static func looksLikeAntigravityThreadTitle(_ value: String, project: String?) -> Bool {
        let normalized = collapsedWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !normalized.isEmpty else { return false }
        guard normalized.count >= 4, normalized.count <= 110 else { return false }

        let lowered = normalized.lowercased()
        if let project, normalized.caseInsensitiveCompare(project) == .orderedSame {
            return false
        }
        if isAntigravityControlLabel(normalized) {
            return false
        }
        if lowered.hasPrefix("openassist (git)") {
            return false
        }
        if lowered.hasPrefix("the editor is not accessible") || lowered.hasPrefix("warning:") {
            return false
        }
        if lowered.range(of: #"^[a-z0-9._-]+\.(md|txt|swift|json|yaml|yml)$"#, options: .regularExpression) != nil {
            return false
        }
        if lowered.range(of: #".+[—–-].+[—–-].+"#, options: .regularExpression) != nil {
            return false
        }
        if lowered.contains("documents/personalprojects/") || lowered.contains("/") || lowered.contains("~") {
            return false
        }
        return true
    }

    private static func isAntigravityControlLabel(_ value: String) -> Bool {
        let lowered = value.lowercased()
        let blockedExact: Set<String> = [
            "antigravity",
            "open agent manager",
            "folders",
            "agent",
            "new thread",
            "threads",
            "skills",
            "automations",
            "switch to agent manager",
            "code with agent",
            "edit code inline",
            "task.md",
            "unknown project",
            "unknown identity"
        ]
        if blockedExact.contains(lowered) {
            return true
        }
        if lowered.hasPrefix("project:")
            || lowered.hasPrefix("thread:")
            || lowered.hasPrefix("worked for ")
            || lowered.hasPrefix("toggle ")
            || lowered.hasPrefix("start new thread") {
            return true
        }
        return false
    }

    private static func inferCodexProjectAndThread(
        from windowElement: AXUIElement,
        fallbackWindowTitle: String?
    ) -> (project: String?, thread: String?) {
        let topBarSelection = inferCodexTopBarSelection(from: windowElement)
        let sidebarSelection = inferCodexSidebarSelection(from: windowElement)
        var project = codexTrustedProjectCandidate(
            topBarProject: topBarSelection?.project,
            sidebarProject: sidebarSelection?.project
        )
        var thread = topBarSelection?.thread ?? sidebarSelection?.thread

        var cachedTextNodes: [AXTextNode]?
        func textNodes() -> [AXTextNode] {
            if let cachedTextNodes {
                return cachedTextNodes
            }
            let fetched = collectTextNodes(from: windowElement, limit: codexTextNodeScanLimit)
            cachedTextNodes = fetched
            return fetched
        }

        func bestProjectFromVisibleText() -> String? {
            let allTexts = textNodes().map(\.text)
            let controlCandidates = allTexts.compactMap {
                codexProjectFromControlLabel($0, includeProjectSectionLabels: false)
            }
            if let candidate = controlCandidates.first(where: { !isLikelyVersionControlReferenceLabel($0) }) {
                return candidate
            }
            let pathCandidates = allTexts.compactMap(codexProjectFromPathLikeLabel)
            if let candidate = pathCandidates.first(where: { !isLikelyVersionControlReferenceLabel($0) }) {
                return candidate
            }
            let genericCandidates = allTexts.compactMap(projectName(fromCodexText:))
            if let candidate = genericCandidates.first(where: { !isLikelyVersionControlReferenceLabel($0) }) {
                return candidate
            }
            return controlCandidates.first ?? pathCandidates.first ?? genericCandidates.first
        }

        func bestProjectFromThreadContext(_ threadCandidate: String?) -> String? {
            codexSidebarProjectFromThreadContext(
                from: windowElement,
                thread: threadCandidate
            )
        }

        if let currentProject = project,
           isLikelyVersionControlReferenceLabel(currentProject),
           let replacement = bestProjectFromThreadContext(thread)
            ?? bestProjectFromVisibleText() {
            project = replacement
        }

        if project == nil {
            project = bestProjectFromThreadContext(thread)
                ?? bestProjectFromVisibleText()
        }

        if thread == nil {
            let selectedTexts = textNodes()
                .filter { $0.selected }
                .map(\.text)
            thread = selectedTexts.first {
                looksLikeCodexThreadTitle($0, project: project)
            }
        }
        if project == nil {
            project = bestProjectFromThreadContext(thread)
        }

        if let fallbackWindowTitle = normalizedLabel(fallbackWindowTitle),
           let fromWindow = codexThreadFromWindowTitle(
               fallbackWindowTitle,
               project: project
           ) {
            thread = thread ?? fromWindow
            if project == nil {
                project = codexProjectFromWindowTitle(fallbackWindowTitle, thread: fromWindow)
            }
        }
        if project == nil,
           let fallbackWindowTitle = normalizedLabel(fallbackWindowTitle) {
            project = projectName(fromCodexText: fallbackWindowTitle)
        }

        return (project, thread)
    }

    static func codexTrustedProjectCandidate(
        visualProject: String? = nil,
        topBarProject: String?,
        sidebarProject: String?
    ) -> String? {
        let candidates = [topBarProject, sidebarProject]
            .compactMap(normalizedLabel)
            .compactMap(normalizedProjectName)
        if let bestNonVCS = candidates.first(where: { !isLikelyVersionControlReferenceLabel($0) }) {
            return bestNonVCS
        }
        return candidates.first
    }

    private static func inferCodexVisualSelection(
        from windowElement: AXUIElement
    ) -> CodexVisualInference? {
        guard let screenshot = captureCodexWindowScreenshot(from: windowElement) else {
            return nil
        }

        let textObservations = recognizeCodexScreenshotText(in: screenshot.image)
        let mainContentProject = codexMainContentProjectFromScreenshot(
            textObservations,
            imageSize: screenshot.imageSize
        )
        let sidebarProject = codexSidebarProjectFromScreenshot(
            screenshot,
            candidates: codexSidebarVisualCandidates(from: windowElement)
        )

        if mainContentProject == nil, sidebarProject == nil {
            return nil
        }
        return CodexVisualInference(
            mainContentProject: mainContentProject,
            sidebarProject: sidebarProject
        )
    }

    private static func captureCodexWindowScreenshot(
        from windowElement: AXUIElement
    ) -> CodexWindowScreenshot? {
        guard let windowFrame = axFrame(of: windowElement),
              windowFrame.width >= 240,
              windowFrame.height >= 240 else {
            return nil
        }
        guard CGPreflightScreenCaptureAccess() else {
            return nil
        }

        let captureRect = CGRect(
            x: floor(windowFrame.minX),
            y: floor(windowFrame.minY),
            width: ceil(windowFrame.width),
            height: ceil(windowFrame.height)
        )
        guard let image = CGWindowListCreateImage(
            captureRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return nil
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        return CodexWindowScreenshot(
            image: image,
            windowFrame: captureRect,
            imageSize: imageSize
        )
    }

    private static func recognizeCodexScreenshotText(
        in image: CGImage
    ) -> [CodexVisualTextObservationCandidate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = codexVisualOCRMinimumTextHeight

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { observation in
            guard let topCandidate = observation.topCandidates(1).first,
                  let normalizedText = normalizedLabel(topCandidate.string) else {
                return nil
            }
            return CodexVisualTextObservationCandidate(
                text: normalizedText,
                bounds: visionImageRect(
                    from: observation.boundingBox,
                    imageSize: imageSize
                )
            )
        }
    }

    static func codexMainContentProjectFromScreenshot(
        _ observations: [CodexVisualTextObservationCandidate],
        imageSize: CGSize
    ) -> String? {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let mainContentMinX = imageSize.width * codexVisualMainContentMinXFraction
        let mainContentObservations = observations
            .filter { $0.bounds.midX >= mainContentMinX }
            .sorted { lhs, rhs in
                if abs(lhs.bounds.minY - rhs.bounds.minY) < 4 {
                    return lhs.bounds.minX < rhs.bounds.minX
                }
                return lhs.bounds.minY < rhs.bounds.minY
            }

        for observation in mainContentObservations {
            if let project = codexProjectFromInlineMainContentLabel(observation.text) {
                return project
            }
        }

        let buildLabels = mainContentObservations.filter {
            $0.text.range(
                of: #"(?i)^let['’]s\s+build$"#,
                options: .regularExpression
            ) != nil
        }
        guard !buildLabels.isEmpty else {
            return nil
        }

        let maxVerticalGap = max(52.0, imageSize.height * 0.13)
        let maxHorizontalDrift = max(120.0, imageSize.width * 0.16)

        for buildLabel in buildLabels {
            let candidates = mainContentObservations
                .filter { observation in
                    guard observation.bounds.minY >= buildLabel.bounds.maxY - 8 else {
                        return false
                    }
                    let verticalGap = observation.bounds.minY - buildLabel.bounds.maxY
                    guard verticalGap <= maxVerticalGap else {
                        return false
                    }
                    let horizontalDrift = abs(observation.bounds.midX - buildLabel.bounds.midX)
                    return horizontalDrift <= maxHorizontalDrift
                }
                .sorted { lhs, rhs in
                    let lhsGap = lhs.bounds.minY - buildLabel.bounds.maxY
                    let rhsGap = rhs.bounds.minY - buildLabel.bounds.maxY
                    if abs(lhsGap - rhsGap) < 3 {
                        return lhs.bounds.minX < rhs.bounds.minX
                    }
                    return lhsGap < rhsGap
                }

            for candidate in candidates {
                if let project = codexProjectFromStandaloneMainContentLabel(candidate.text) {
                    return project
                }
            }
        }

        return nil
    }

    private static func codexProjectFromInlineMainContentLabel(_ value: String) -> String? {
        if let captured = firstRegexCapture(
            pattern: #"(?i)\blet['’]s\s+build\s+([a-z0-9][a-z0-9 ._()\-]{1,80})\b"#,
            in: value
        ),
           let normalized = normalizedProjectName(captured),
           !shouldTreatCodexProjectLabelAsUnknown(normalized),
           !isLikelyVersionControlReferenceLabel(normalized) {
            return normalized
        }

        if let captured = firstRegexCapture(
            pattern: #"(?i)\b(?:project|workspace)\s*[:\-]\s*([a-z0-9][a-z0-9 ._()\-]{1,80})\b"#,
            in: value
        ),
           let normalized = normalizedProjectName(captured),
           !shouldTreatCodexProjectLabelAsUnknown(normalized),
           !isLikelyVersionControlReferenceLabel(normalized) {
            return normalized
        }

        return nil
    }

    private static func codexProjectFromStandaloneMainContentLabel(_ value: String) -> String? {
        guard let normalized = normalizedProjectName(value),
              !shouldTreatCodexProjectLabelAsUnknown(normalized),
              !isLikelyVersionControlReferenceLabel(normalized),
              looksLikeLooseCodexProjectLabel(normalized) else {
            return nil
        }
        return normalized
    }

    private static func codexSidebarProjectFromScreenshot(
        _ screenshot: CodexWindowScreenshot,
        candidates: [CodexSidebarVisualCandidate]
    ) -> String? {
        guard !candidates.isEmpty else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: screenshot.image)
        let imageBounds = CGRect(origin: .zero, size: screenshot.imageSize)
        let sidebarMaxX = screenshot.imageSize.width * codexVisualSidebarMaxXFraction

        let scoredCandidates = candidates.compactMap { candidate -> (project: String, score: Double)? in
            guard let localRect = localImageRect(for: candidate.frame, screenshot: screenshot) else {
                return nil
            }
            let expandedRect = localRect
                .insetBy(dx: -8, dy: -4)
                .intersection(imageBounds)
            guard expandedRect.width >= 60,
                  expandedRect.height >= 20,
                  expandedRect.minX <= sidebarMaxX else {
                return nil
            }

            let outerRect = expandedRect
                .insetBy(dx: -10, dy: -6)
                .intersection(imageBounds)
            let innerStats = averageVisualStats(
                in: expandedRect,
                bitmap: bitmap,
                excluding: nil
            )
            let outerStats = averageVisualStats(
                in: outerRect,
                bitmap: bitmap,
                excluding: expandedRect
            )
            let score = max(0, innerStats.luminance - outerStats.luminance) * 1.35
                + max(0, innerStats.saturation - outerStats.saturation) * 0.75
            return (candidate.project, score)
        }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.project.lowercased() < rhs.project.lowercased()
                }
                return lhs.score > rhs.score
            }

        guard let best = scoredCandidates.first,
              best.score >= codexVisualSidebarMinHighlightScore else {
            return nil
        }
        if let runnerUp = scoredCandidates.dropFirst().first,
           (best.score - runnerUp.score) < codexVisualSidebarMinHighlightGap {
            return nil
        }
        return best.project
    }

    private static func codexSidebarVisualCandidates(
        from windowElement: AXUIElement
    ) -> [CodexSidebarVisualCandidate] {
        var queue: [AXUIElement] = [windowElement]
        var cursor = 0
        var bestByProject: [String: CodexSidebarVisualCandidate] = [:]

        while cursor < queue.count, cursor < codexSidebarTraversalLimit {
            let element = queue[cursor]
            cursor += 1

            let labels = [
                axStringAttribute(kAXTitleAttribute as CFString, from: element),
                axStringValueAttribute(kAXValueAttribute as CFString, from: element),
                axStringAttribute(kAXDescriptionAttribute as CFString, from: element),
                axStringAttribute(kAXHelpAttribute as CFString, from: element)
            ]
                .compactMap(normalizedLabel)

            for label in labels {
                guard let project = codexProjectSectionCandidate(from: label) else { continue }
                let container = codexSidebarContainer(for: element)
                guard let frame = container.flatMap(axFrame(of:)) ?? axFrame(of: element) else {
                    continue
                }
                guard frame.width >= 80,
                      frame.height >= 18,
                      frame.height <= 90 else {
                    continue
                }

                let candidate = CodexSidebarVisualCandidate(project: project, frame: frame)
                let key = project.lowercased()
                if let existing = bestByProject[key] {
                    if frame.height < existing.frame.height
                        || (abs(frame.height - existing.frame.height) < 1 && frame.width > existing.frame.width) {
                        bestByProject[key] = candidate
                    }
                } else {
                    bestByProject[key] = candidate
                }
            }

            let children = axElementsAttribute(kAXChildrenAttribute as CFString, from: element)
            if !children.isEmpty, queue.count < codexSidebarTraversalLimit {
                queue.append(contentsOf: children.prefix(max(0, codexSidebarTraversalLimit - queue.count)))
            }
        }

        return bestByProject.values.sorted { lhs, rhs in
            if lhs.frame.minY == rhs.frame.minY {
                return lhs.project.lowercased() < rhs.project.lowercased()
            }
            return lhs.frame.minY < rhs.frame.minY
        }
    }

    private static func visionImageRect(
        from normalizedRect: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        CGRect(
            x: normalizedRect.minX * imageSize.width,
            y: (1.0 - normalizedRect.maxY) * imageSize.height,
            width: normalizedRect.width * imageSize.width,
            height: normalizedRect.height * imageSize.height
        )
    }

    private static func localImageRect(
        for screenRect: CGRect,
        screenshot: CodexWindowScreenshot
    ) -> CGRect? {
        guard screenshot.windowFrame.width > 0,
              screenshot.windowFrame.height > 0 else {
            return nil
        }

        let scaleX = screenshot.imageSize.width / screenshot.windowFrame.width
        let scaleY = screenshot.imageSize.height / screenshot.windowFrame.height
        let localRect = CGRect(
            x: (screenRect.minX - screenshot.windowFrame.minX) * scaleX,
            y: (screenRect.minY - screenshot.windowFrame.minY) * scaleY,
            width: screenRect.width * scaleX,
            height: screenRect.height * scaleY
        )
        guard localRect.width > 0, localRect.height > 0 else {
            return nil
        }
        return localRect
    }

    private static func averageVisualStats(
        in rect: CGRect,
        bitmap: NSBitmapImageRep,
        excluding excludedRect: CGRect?
    ) -> CodexVisualRegionStats {
        guard rect.width > 1, rect.height > 1 else {
            return CodexVisualRegionStats(luminance: 0, saturation: 0)
        }

        let sampleColumns = max(5, min(18, Int(rect.width / 14)))
        let sampleRows = max(5, min(12, Int(rect.height / 10)))
        let clippedExcludedRect = excludedRect?.intersection(rect)

        var luminanceTotal = 0.0
        var saturationTotal = 0.0
        var sampleCount = 0.0

        for row in 0..<sampleRows {
            for column in 0..<sampleColumns {
                let samplePoint = CGPoint(
                    x: rect.minX + (CGFloat(column) + 0.5) * rect.width / CGFloat(sampleColumns),
                    y: rect.minY + (CGFloat(row) + 0.5) * rect.height / CGFloat(sampleRows)
                )
                if let clippedExcludedRect,
                   clippedExcludedRect.contains(samplePoint) {
                    continue
                }

                let pixelX = max(0, min(bitmap.pixelsWide - 1, Int(samplePoint.x.rounded(.down))))
                let pixelYFromTop = Int(samplePoint.y.rounded(.down))
                let pixelY = max(0, min(bitmap.pixelsHigh - 1, bitmap.pixelsHigh - 1 - pixelYFromTop))

                guard let color = bitmap.colorAt(x: pixelX, y: pixelY)?
                    .usingColorSpace(.deviceRGB) else {
                    continue
                }
                let red = Double(color.redComponent)
                let green = Double(color.greenComponent)
                let blue = Double(color.blueComponent)
                let alpha = Double(color.alphaComponent)
                guard alpha > 0.08 else { continue }

                let maxChannel = max(red, green, blue)
                let minChannel = min(red, green, blue)
                let saturation = maxChannel <= 0.0001 ? 0 : (maxChannel - minChannel) / maxChannel
                let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)

                luminanceTotal += luminance
                saturationTotal += saturation
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else {
            return CodexVisualRegionStats(luminance: 0, saturation: 0)
        }
        return CodexVisualRegionStats(
            luminance: luminanceTotal / sampleCount,
            saturation: saturationTotal / sampleCount
        )
    }

    private static func inferCodexTopBarSelection(
        from windowElement: AXUIElement
    ) -> (project: String?, thread: String?)? {
        guard let controlsGroup = codexTopBarControlsGroup(from: windowElement) else {
            return nil
        }
        let entries = codexDirectChildLabels(of: controlsGroup)
        let thread = codexThreadNearTopBarControls(controlsGroup, project: nil)
        let project = codexTrustedProjectCandidate(
            topBarProject: codexProjectFromTopBarControls(entries),
            sidebarProject: codexProjectNearTopBarControls(
                from: windowElement,
                controlsGroup,
                thread: thread
            )
        )
        if project == nil, thread == nil {
            return nil
        }
        return (project, thread)
    }

    private static func codexTopBarControlsGroup(from windowElement: AXUIElement) -> AXUIElement? {
        let traversalLimit = codexTopBarTraversalLimit
        var queue: [AXUIElement] = [windowElement]
        var cursor = 0

        while cursor < queue.count, cursor < traversalLimit {
            let element = queue[cursor]
            cursor += 1

            let role = axStringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if role.caseInsensitiveCompare("AXGroup") == .orderedSame {
                let entries = codexDirectChildLabels(of: element)
                let hasThreadActions = entries.contains {
                    $0.role.caseInsensitiveCompare("AXPopUpButton") == .orderedSame &&
                        $0.label.caseInsensitiveCompare("Thread actions") == .orderedSame
                }
                let hasOpen = entries.contains {
                    $0.role.caseInsensitiveCompare("AXButton") == .orderedSame &&
                        $0.label.caseInsensitiveCompare("Open") == .orderedSame
                }
                let hasCommit = entries.contains {
                    $0.role.caseInsensitiveCompare("AXButton") == .orderedSame &&
                        $0.label.caseInsensitiveCompare("Commit") == .orderedSame
                }
                let hasSecondaryAction = entries.contains {
                    $0.label.caseInsensitiveCompare("Secondary action") == .orderedSame
                }
                let controlSignalCount = entries.reduce(0) { partialResult, entry in
                    partialResult + (isCodexToolbarControlLabel(entry.label) ? 1 : 0)
                }
                let hasProjectCandidate = entries.contains {
                    codexNormalizedTopBarProjectCandidate($0.label) != nil
                }
                if hasThreadActions && (hasOpen || hasCommit || hasSecondaryAction) {
                    return element
                }
                if hasProjectCandidate && controlSignalCount >= 2 {
                    return element
                }
            }

            let children = axElementsAttribute(kAXChildrenAttribute as CFString, from: element)
            if !children.isEmpty, queue.count < traversalLimit {
                queue.append(contentsOf: children.prefix(max(0, traversalLimit - queue.count)))
            }
        }

        return nil
    }

    private static func codexDirectChildLabels(of element: AXUIElement) -> [AXLabelEntry] {
        let children = axElementsAttribute(kAXChildrenAttribute as CFString, from: element)
        var entries: [AXLabelEntry] = []
        entries.reserveCapacity(children.count * 2)

        for child in children {
            let role = axStringAttribute(kAXRoleAttribute as CFString, from: child) ?? ""
            let value = shouldReadAXValueAttribute(forRole: role)
                ? axStringValueAttribute(kAXValueAttribute as CFString, from: child)
                : nil
            let labels = [
                axStringAttribute(kAXTitleAttribute as CFString, from: child),
                value,
                axStringAttribute(kAXDescriptionAttribute as CFString, from: child)
            ]
                .compactMap(normalizedLabel)
            var seen = Set<String>()
            for label in labels {
                let key = label.lowercased()
                if seen.insert(key).inserted {
                    entries.append(AXLabelEntry(label: label, role: role, element: child))
                }
            }
        }

        return entries
    }

    private static func codexProjectFromTopBarControls(_ entries: [AXLabelEntry]) -> String? {
        if let threadActionsIndex = entries.firstIndex(where: {
            $0.label.caseInsensitiveCompare("Thread actions") == .orderedSame
        }), threadActionsIndex > 0 {
            for index in stride(from: threadActionsIndex - 1, through: 0, by: -1) {
                let entry = entries[index]
                guard codexRoleSupportsProjectSelection(entry.role) else { continue }
                if let candidate = codexNormalizedTopBarProjectCandidate(entry.label) {
                    return candidate
                }
            }

            // Some Codex builds expose the workspace label as static text
            // near "Thread actions"; fall back to non-control labels.
            for index in stride(from: threadActionsIndex - 1, through: 0, by: -1) {
                let entry = entries[index]
                if isCodexToolbarControlLabel(entry.label) {
                    continue
                }
                guard let candidate = codexNormalizedTopBarProjectCandidate(entry.label) else { continue }
                guard looksLikeLooseCodexProjectLabel(candidate) else { continue }
                return candidate
            }
        }

        for entry in entries where codexRoleSupportsProjectSelection(entry.role) {
            if let candidate = codexNormalizedTopBarProjectCandidate(entry.label) {
                return candidate
            }
        }

        for entry in entries {
            if let candidate = codexProjectFromControlLabel(
                entry.label,
                includeProjectSectionLabels: false
            ) {
                return candidate
            }
        }

        return nil
    }

    private static func looksLikeLooseCodexProjectLabel(_ value: String) -> Bool {
        let normalized = collapsedWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !normalized.isEmpty else { return false }
        guard !isLikelyVersionControlReferenceLabel(normalized) else { return false }

        let lowered = normalized.lowercased()
        if lowered.contains("http://") || lowered.contains("https://") {
            return false
        }
        if lowered.contains("axtextarea")
            || lowered.contains("axtextfield")
            || lowered.contains("axbutton")
            || lowered.contains("axgroup")
            || lowered.contains("axscrollarea") {
            return false
        }

        let words = normalized.split(whereSeparator: \.isWhitespace).count
        if words > 4 || normalized.count > 40 {
            return false
        }
        return true
    }

    private static func codexRoleSupportsProjectSelection(_ role: String) -> Bool {
        let normalized = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "axbutton"
            || normalized == "axpopupbutton"
            || normalized == "axmenubutton"
            || normalized == "axcombobox"
    }

    static func codexNormalizedTopBarProjectCandidate(_ value: String) -> String? {
        if let fromControl = codexProjectFromControlLabel(
            value,
            includeProjectSectionLabels: false
        ) {
            return fromControl
        }
        if isCodexToolbarControlLabel(value) {
            return nil
        }
        if let fromPath = codexProjectFromPathLikeLabel(value) {
            return fromPath
        }
        return normalizedProjectName(value)
    }

    static func codexProjectFromControlLabel(
        _ value: String,
        includeProjectSectionLabels: Bool = false
    ) -> String? {
        var controlPatterns = [
            #"(?i)\b(?:working directory|cwd|folder)\s*[:\-]\s*([^\n]{2,180})$"#
        ]
        if includeProjectSectionLabels {
            controlPatterns.insert(
                #"(?i)\b(?:start new thread in|project actions for|automations in)\s+([a-z0-9][a-z0-9 ._()\-]{1,80})\b"#,
                at: 0
            )
        }
        for pattern in controlPatterns {
            guard let captured = firstRegexCapture(pattern: pattern, in: value) else { continue }
            if let fromPath = codexProjectFromPathLikeLabel(captured) {
                return fromPath
            }
            if let normalized = normalizedProjectName(captured) {
                return normalized
            }
        }
        return nil
    }

    private static func codexProjectFromPathLikeLabel(_ value: String) -> String? {
        let normalized = collapsedWhitespace(value)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !normalized.isEmpty else { return nil }
        let looksLikePath = normalized.hasPrefix("/")
            || normalized.hasPrefix("~")
            || normalized.hasPrefix("file://")
            || normalized.range(of: #"^[A-Za-z]:\\\\"#, options: .regularExpression) != nil
        guard looksLikePath else { return nil }
        guard let label = deriveDocumentLabel(from: normalized) else { return nil }
        return normalizedProjectName(label)
    }

    private static func codexProjectNearTopBarControls(
        from windowElement: AXUIElement,
        _ controlsGroup: AXUIElement,
        thread: String?
    ) -> String? {
        let anchor = axCenterPoint(of: controlsGroup)
        let nodes = collectTextNodes(from: windowElement, limit: codexTextNodeScanLimit)
        var bestCandidates: [String: (label: String, score: Double)] = [:]

        for node in nodes {
            if isCodexToolbarControlLabel(node.text) {
                continue
            }
            guard let candidate = codexNormalizedTopBarProjectCandidate(node.text) else {
                continue
            }
            guard looksLikeLooseCodexProjectLabel(candidate) else {
                continue
            }
            if let thread,
               candidate.caseInsensitiveCompare(thread) == .orderedSame {
                continue
            }

            var score = codexRoleSupportsProjectSelection(node.role) ? 0.0 : 90.0
            if let anchor,
               let element = node.element,
               let center = axCenterPoint(of: element) {
                let verticalGap = abs(Double(center.y - anchor.y))
                let horizontalGap = abs(Double(center.x - anchor.x))
                score += verticalGap * 5.0 + horizontalGap * 0.12
                if center.y > anchor.y + 120 {
                    score += 700 // Sidebar rows are typically far below top-bar controls.
                }
            } else {
                score += 450
            }
            if isLikelyVersionControlReferenceLabel(candidate) {
                score += 900
            }

            let key = candidate.lowercased()
            let existing = bestCandidates[key]?.score ?? .greatestFiniteMagnitude
            if score < existing {
                bestCandidates[key] = (candidate, score)
            }
        }

        let ranked = bestCandidates.values
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.label.lowercased() < rhs.label.lowercased()
                }
                return lhs.score < rhs.score
            }
            .map(\.label)
        if let bestNonVCS = ranked.first(where: { !isLikelyVersionControlReferenceLabel($0) }) {
            return bestNonVCS
        }
        return ranked.first
    }

    private static func codexThreadNearTopBarControls(
        _ controlsGroup: AXUIElement,
        project: String?
    ) -> String? {
        guard let parent = axElementAttribute(kAXParentAttribute as CFString, from: controlsGroup) else {
            return nil
        }
        let siblings = axElementsAttribute(kAXChildrenAttribute as CFString, from: parent)
        for sibling in siblings where !CFEqual(sibling, controlsGroup) {
            let nodes = collectTextNodes(from: sibling, limit: 120)
            for node in nodes {
                if isCodexToolbarControlLabel(node.text) {
                    continue
                }
                if looksLikeCodexThreadTitle(node.text, project: project) {
                    return node.text
                }
            }
        }
        return nil
    }

    private static func inferCodexSidebarSelection(
        from windowElement: AXUIElement
    ) -> (project: String?, thread: String?)? {
        let traversalLimit = codexSidebarTraversalLimit
        var queue: [AXUIElement] = [windowElement]
        var cursor = 0
        var bestProject: String?

        while cursor < queue.count, cursor < traversalLimit {
            let element = queue[cursor]
            cursor += 1

            if isCodexActiveSidebarRow(element) {
                let inferredProject = codexProjectFromActiveSidebarRow(element)
                let inferredThread = codexThreadFromActiveSidebarRow(element, project: inferredProject)
                if let inferredProject {
                    bestProject = bestProject ?? inferredProject
                }
                if let inferredThread {
                    return (inferredProject ?? bestProject, inferredThread)
                }
            }

            let children = axElementsAttribute(kAXChildrenAttribute as CFString, from: element)
            if !children.isEmpty, queue.count < traversalLimit {
                queue.append(contentsOf: children.prefix(max(0, traversalLimit - queue.count)))
            }
        }

        if let bestProject {
            return (bestProject, nil)
        }
        return nil
    }

    private static func isCodexActiveSidebarRow(_ element: AXUIElement) -> Bool {
        let classList = axStringAttribute("AXDOMClassList" as CFString, from: element)?
            .lowercased() ?? ""
        guard classList.contains("active-selection-background") else {
            return false
        }
        return classList.contains("cursor-interaction")
    }

    private static func codexThreadFromActiveSidebarRow(
        _ activeRow: AXUIElement,
        project: String?
    ) -> String? {
        let rowTexts = collectTextNodes(from: activeRow, limit: 180).map(\.text)
        for text in rowTexts {
            let lowered = text.lowercased()
            if lowered == "archive thread"
                || lowered == "pin thread"
                || lowered == "unpin thread"
                || lowered.hasPrefix("archive thread")
                || lowered.hasPrefix("project actions for")
                || lowered.hasPrefix("start new thread in")
                || lowered.range(of: #"^\d+\s*[smhdw]$"#, options: .regularExpression) != nil {
                continue
            }
            if looksLikeCodexThreadTitle(text, project: project) {
                return text
            }
        }
        return nil
    }

    private static func codexProjectFromActiveSidebarRow(_ activeRow: AXUIElement) -> String? {
        var node: AXUIElement? = activeRow
        var depth = 0

        while depth < 12, let current = node,
              let parent = axElementAttribute(kAXParentAttribute as CFString, from: current) {
            let parentDescription = normalizedLabel(
                axStringAttribute(kAXDescriptionAttribute as CFString, from: parent)
            )
            if let parentDescription,
               let fromAutomationsLabel = firstRegexCapture(
                   pattern: #"(?i)\bautomations\s+in\s+([a-z0-9][a-z0-9 ._()\-]{1,80})\b"#,
                   in: parentDescription
               ),
               let normalized = normalizedProjectName(fromAutomationsLabel) {
                return normalized
            }

            let classList = axStringAttribute("AXDOMClassList" as CFString, from: parent)?
                .lowercased() ?? ""
            if classList.contains("group/cwd") {
                let candidateValues = [
                    axStringAttribute(kAXDescriptionAttribute as CFString, from: parent),
                    axStringAttribute(kAXTitleAttribute as CFString, from: parent)
                ]
                    .compactMap(normalizedLabel)
                for candidate in candidateValues {
                    let lowered = candidate.lowercased()
                    if lowered == "automation folders" || lowered == "threads" || lowered == "pinned threads" {
                        continue
                    }
                    if let normalized = codexProjectFromControlLabel(
                        candidate,
                        includeProjectSectionLabels: true
                    )
                        ?? codexProjectFromPathLikeLabel(candidate)
                        ?? normalizedProjectName(candidate) {
                        return normalized
                    }
                }
            }

            node = parent
            depth += 1
        }

        return nil
    }

    private static func codexSidebarContainer(for element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0

        while depth < codexVisualSidebarAncestorDepth, let node = current {
            let classList = axStringAttribute("AXDOMClassList" as CFString, from: node)?
                .lowercased() ?? ""
            if classList.contains("cursor-interaction")
                || classList.contains("active-selection-background")
                || classList.contains("group/cwd")
                || classList.contains("nav-section")
                || classList.contains("truncate")
                || classList.contains("rounded-lg") {
                return node
            }
            current = axElementAttribute(kAXParentAttribute as CFString, from: node)
            depth += 1
        }

        return nil
    }

    private static func codexActiveSidebarRows(from windowElement: AXUIElement) -> [AXUIElement] {
        let traversalLimit = codexSidebarTraversalLimit
        var queue: [AXUIElement] = [windowElement]
        var cursor = 0
        var rows: [AXUIElement] = []

        while cursor < queue.count, cursor < traversalLimit {
            let element = queue[cursor]
            cursor += 1

            if isCodexActiveSidebarRow(element) {
                rows.append(element)
            }

            let children = axElementsAttribute(kAXChildrenAttribute as CFString, from: element)
            if !children.isEmpty, queue.count < traversalLimit {
                queue.append(contentsOf: children.prefix(max(0, traversalLimit - queue.count)))
            }
        }

        return rows
    }

    private static func collectTextNodes(from root: AXUIElement, limit: Int) -> [AXTextNode] {
        var queue: [AXUIElement] = [root]
        var cursor = 0
        var nodes: [AXTextNode] = []
        var seen = Set<String>()

        while cursor < queue.count, cursor < limit {
            let element = queue[cursor]
            cursor += 1

            let role = axStringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            let selected = axBoolAttribute(kAXSelectedAttribute as CFString, from: element) ?? false
            let value = shouldReadAXValueAttribute(forRole: role)
                ? axStringValueAttribute(kAXValueAttribute as CFString, from: element)
                : nil
            let values = [
                axStringAttribute(kAXTitleAttribute as CFString, from: element),
                value,
                axStringAttribute(kAXDescriptionAttribute as CFString, from: element),
                axStringAttribute(kAXHelpAttribute as CFString, from: element)
            ]
                .compactMap(normalizedLabel)

            for value in values where isLikelyCodexContextText(value) {
                let key = "\(value.lowercased())|\(role.lowercased())|\(selected)"
                if seen.insert(key).inserted {
                    nodes.append(AXTextNode(text: value, role: role, selected: selected, element: element))
                }
            }

            let children = axElementsAttribute(kAXChildrenAttribute as CFString, from: element)
            if !children.isEmpty, queue.count < limit {
                queue.append(contentsOf: children.prefix(max(0, limit - queue.count)))
            }
        }

        return nodes
    }

    private static func codexProjectSectionCandidate(from value: String) -> String? {
        let lowered = value.lowercased()
        guard lowered.contains("start new thread in")
            || lowered.contains("project actions for")
            || lowered.contains("automations in") else {
            return nil
        }
        return codexProjectFromControlLabel(value, includeProjectSectionLabels: true)
    }

    private static func isLikelyCodexContextText(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if normalized.count < 3 || normalized.count > 140 {
            return false
        }

        let lowered = normalized.lowercased()
        let blocked: Set<String> = [
            "codex",
            "new thread",
            "threads",
            "automations",
            "skills",
            "settings",
            "open",
            "commit",
            "local",
            "full access",
            "show more",
            "gpt-5.3-codex",
            "extra high"
        ]
        if blocked.contains(lowered) {
            return false
        }
        if lowered == "hide sidebar"
            || lowered == "show sidebar"
            || lowered == "toggle sidebar"
            || lowered == "toggle terminal"
            || lowered == "toggle diff panel" {
            return false
        }
        if lowered.hasPrefix("ask for follow-up changes") {
            return false
        }
        return true
    }

    private static func projectName(fromCodexText text: String) -> String? {
        if let fromControl = codexProjectFromControlLabel(
            text,
            includeProjectSectionLabels: false
        ) {
            return fromControl
        }
        if let fromPath = codexProjectFromPathLikeLabel(text) {
            return fromPath
        }
        if let captured = firstRegexCapture(
            pattern: #"(?i)\blet['’]s\s+build\s+([a-z0-9][a-z0-9 ._()\-]{1,80})\b"#,
            in: text
        ) {
            return normalizedProjectName(captured)
        }
        if let captured = firstRegexCapture(
            pattern: #"(?i)\b(?:project|workspace)\s*[:\-]\s*([a-z0-9][a-z0-9 ._()\-]{1,80})\b"#,
            in: text
        ) {
            return normalizedProjectName(captured)
        }
        return nil
    }

    private static func codexSidebarProjectFromThreadContext(
        from windowElement: AXUIElement,
        thread: String?
    ) -> String? {
        guard let normalizedThread = normalizedLabel(thread),
              !normalizedThread.isEmpty else {
            return nil
        }
        let textNodes = collectTextNodes(from: windowElement, limit: codexTextNodeScanLimit)
        let threadIndices = textNodes.enumerated().compactMap { index, node -> Int? in
            guard node.text.caseInsensitiveCompare(normalizedThread) == .orderedSame else {
                return nil
            }
            guard looksLikeCodexThreadTitle(node.text, project: nil) else {
                return nil
            }
            return index
        }
        guard !threadIndices.isEmpty else { return nil }

        for index in threadIndices {
            let lowerBound = max(0, index - 80)
            guard index > lowerBound else { continue }
            for cursor in stride(from: index - 1, through: lowerBound, by: -1) {
                let text = textNodes[cursor].text
                if let candidate = codexProjectFromControlLabel(
                    text,
                    includeProjectSectionLabels: true
                ), !isLikelyVersionControlReferenceLabel(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func normalizedProjectName(_ value: String) -> String? {
        let normalized = collapsedWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !normalized.isEmpty else { return nil }
        if let captured = firstRegexCapture(
            pattern: #"(?i)^(?:project|workspace)\s*[:\-]\s*([a-z0-9][a-z0-9 ._()\-]{1,80})$"#,
            in: normalized
        ) {
            return normalizedProjectName(captured)
        }
        let lowered = normalized.lowercased()
        let blocked: Set<String> = [
            "thread",
            "new thread",
            "current thread",
            "codex",
            "unknown",
            "unknown project",
            "unknown workspace",
            "unknown identity",
            "add new project"
        ]
        if blocked.contains(lowered) {
            return nil
        }
        if isLikelyVersionControlReferenceLabel(normalized) {
            return nil
        }
        return normalized
    }

    private static func isCodexNonProjectPlaceholderLabel(_ value: String) -> Bool {
        let normalized = collapsedWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        guard !normalized.isEmpty else { return true }

        let blocked: Set<String> = [
            "automation folder",
            "automation folders",
            "automations",
            "threads",
            "pinned threads",
            "user attachment",
            "user attachments",
            "unknown project",
            "unknown workspace",
            "unknown identity"
        ]
        if blocked.contains(normalized) {
            return true
        }
        if normalized.range(of: #"^(?:automations?|threads?|skills?)\s+\d+$"#, options: .regularExpression) != nil {
            return true
        }
        if normalized.range(
            of: #"^worked\s+for\s+\d+\s*[smhdw](?:\s+\d+\s*[smhdw])*$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return false
    }

    static func shouldTreatCodexProjectLabelAsUnknown(_ value: String) -> Bool {
        let normalized = collapsedWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !normalized.isEmpty else { return true }
        if isCodexNonProjectPlaceholderLabel(normalized) {
            return true
        }
        return isLikelyCodexActionLabel(normalized)
    }

    static func sanitizedCodexScreenLabel(_ screenLabel: String) -> String {
        let normalized = collapsedWhitespace(screenLabel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Current Screen" }

        if let project = firstRegexCapture(
            pattern: #"(?i)\bproject\s*:\s*([^\|]+)"#,
            in: normalized
        ),
           shouldTreatCodexProjectLabelAsUnknown(project) {
            if let thread = firstRegexCapture(
                pattern: #"(?i)\bthread\s*:\s*([^\|]+)$"#,
                in: normalized
            ) {
                return "Thread: \(thread)"
            }
            return "Current Screen"
        }

        if shouldTreatCodexProjectLabelAsUnknown(normalized) {
            return "Current Screen"
        }

        return normalized
    }

    private static func isLikelyCodexActionLabel(_ value: String) -> Bool {
        let normalized = collapsedWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        guard !normalized.isEmpty else { return true }

        let blockedExact: Set<String> = [
            "open in popout window",
            "open in pop-up window",
            "open in new window",
            "open in browser",
            "edit message",
            "run",
            "handoff",
            "hand off",
            "secondary action",
            "copy link",
            "share",
            "undo",
            "redo",
            "copy",
            "paste",
            "cut",
            "delete",
            "select all"
        ]
        if blockedExact.contains(normalized) {
            return true
        }
        if normalized.range(of: #"^(?:automations?|threads?|skills?)\s+\d+$"#, options: .regularExpression) != nil {
            return true
        }

        let actionPattern = #"^(?:open|close|show|hide|toggle|copy|share|inspect|compact|clear|edit(?:\s+message)?|pop(?:[- ]?out)?|run|commit|handoff|hand off|undo|redo|paste|cut|delete|select all)\b"#
        return normalized.range(of: actionPattern, options: .regularExpression) != nil
    }

    private static func isLikelyVersionControlReferenceLabel(_ value: String) -> Bool {
        let normalized = collapsedWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        guard !normalized.isEmpty else { return false }

        // Pull request / issue style badges.
        if normalized.range(
            of: #"^(?:pr|pull request)\s*#?\d+\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if normalized.range(of: #"^#\d+$"#, options: .regularExpression) != nil {
            return true
        }

        // Branch/ref selectors and commit hashes that are not stable project names.
        if normalized.range(
            of: #"^(?:refs/(?:heads|tags|pull)/|origin/|upstream/|branch\s*:|tag\s*:)"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if normalized.range(
            of: #"^(?:main|master|develop|development|dev)$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if normalized.range(
            of: #"^(?:feature|bugfix|hotfix|release|chore|fix|refactor|test|docs|ci|perf)/[a-z0-9._\-\/]{2,}$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if normalized.range(of: #"^[a-f0-9]{7,40}$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func looksLikeCodexThreadTitle(_ value: String, project: String?) -> Bool {
        let normalized = collapsedWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !normalized.isEmpty else { return false }
        let lowered = normalized.lowercased()
        if lowered.hasPrefix("project:") || lowered.hasPrefix("workspace:") {
            return false
        }
        if let project, normalized.caseInsensitiveCompare(project) == .orderedSame {
            return false
        }
        if lowered == "archive thread"
            || lowered == "pin thread"
            || lowered == "unpin thread"
            || lowered.hasPrefix("archive thread")
            || lowered.hasPrefix("project actions for")
            || lowered.hasPrefix("start new thread in")
            || lowered.range(of: #"^\d+\s*[smhdw]$"#, options: .regularExpression) != nil {
            return false
        }
        let codexControlCommandPattern = #"^(?:hide|show|toggle|open|close|collapse|expand)\s+(?:sidebar|terminal|panel|diff(?:\s+panel)?|files?|explorer|settings|menu|chat|thread|threads)\b"#
        if lowered.range(of: codexControlCommandPattern, options: .regularExpression) != nil {
            return false
        }
        if lowered.contains("axtextarea")
            || lowered.contains("axtextfield")
            || lowered.contains("axbutton")
            || lowered.contains("axgroup")
            || lowered.contains("axscrollarea") {
            return false
        }
        let blocked: Set<String> = [
            "new thread",
            "threads",
            "settings",
            "automations",
            "skills",
            "show more",
            "open",
            "commit",
            "hide sidebar",
            "show sidebar",
            "toggle sidebar",
            "toggle terminal",
            "toggle diff panel",
            "thread actions"
        ]
        if blocked.contains(lowered) {
            return false
        }
        return normalized.count >= 4
    }

    private static func isCodexToolbarControlLabel(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if isLikelyVersionControlReferenceLabel(lowered) {
            return true
        }
        let blocked: Set<String> = [
            "codex",
            "thread actions",
            "set up a run action",
            "open",
            "commit",
            "secondary action",
            "toggle terminal",
            "toggle diff panel",
            "pop out",
            "new thread",
            "automations",
            "skills",
            "settings"
        ]
        if blocked.contains(lowered) {
            return true
        }
        if lowered.hasPrefix("toggle ")
            || lowered.hasPrefix("project actions for")
            || lowered.hasPrefix("start new thread in") {
            return true
        }
        if lowered.range(of: #"^[+\-]?\d+$"#, options: .regularExpression) != nil {
            return true
        }
        if lowered.range(of: #"^\d+\s*[smhdw]$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func codexThreadFromWindowTitle(_ title: String, project: String?) -> String? {
        let normalizedTitle = collapsedWhitespace(title)
        guard !normalizedTitle.isEmpty else { return nil }
        let cleaned = normalizedTitle
            .replacingOccurrences(of: #"(?i)\bcodex\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !cleaned.isEmpty else { return nil }

        if let project {
            let loweredCleaned = cleaned.lowercased()
            let loweredProject = project.lowercased()
            if loweredCleaned.hasSuffix(loweredProject) {
                let cutoff = cleaned.index(cleaned.endIndex, offsetBy: -project.count)
                var prefix = String(cleaned[..<cutoff])
                prefix = prefix.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                if looksLikeCodexThreadTitle(prefix, project: project) {
                    return prefix
                }
            }
        }

        if looksLikeCodexThreadTitle(cleaned, project: project) {
            return cleaned
        }
        return nil
    }

    private static func codexProjectFromWindowTitle(_ title: String, thread: String) -> String? {
        let normalizedTitle = collapsedWhitespace(title)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !normalizedTitle.isEmpty, !thread.isEmpty else { return nil }
        if normalizedTitle.caseInsensitiveCompare(thread) == .orderedSame {
            return nil
        }
        let loweredTitle = normalizedTitle.lowercased()
        let loweredThread = thread.lowercased()
        if loweredTitle.hasPrefix(loweredThread) {
            let suffixStart = normalizedTitle.index(normalizedTitle.startIndex, offsetBy: thread.count)
            let suffix = String(normalizedTitle[suffixStart...])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            return normalizedProjectName(suffix)
        }
        return nil
    }

    private static func firstRegexCapture(pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        let captured = String(value[captureRange])
        return normalizedLabel(captured)
    }

    private static func inferTelegramChatName(
        from windowElement: AXUIElement,
        fallbackWindowTitle: String?
    ) -> String? {
        if let fromWindowTitle = telegramChatFromWindowTitle(fallbackWindowTitle) {
            return fromWindowTitle
        }

        let textNodes = collectTextNodes(from: windowElement, limit: telegramTextNodeScanLimit)
        if textNodes.isEmpty {
            return nil
        }

        let selectedCandidates = textNodes
            .filter(\.selected)
            .map(\.text)
            .compactMap(telegramNormalizedChatCandidate)
        if let selected = selectedCandidates.first {
            return selected
        }

        let headingCandidates = textNodes
            .filter { $0.role.caseInsensitiveCompare("AXHeading") == .orderedSame }
            .map(\.text)
            .compactMap(telegramNormalizedChatCandidate)
        if let heading = headingCandidates.first {
            return heading
        }

        let topCandidates = Array(textNodes.prefix(220))
            .map(\.text)
            .compactMap(telegramNormalizedChatCandidate)
        return topCandidates.first
    }

    private static func telegramChatFromWindowTitle(_ value: String?) -> String? {
        guard let normalizedValue = normalizedLabel(value) else { return nil }
        let loweredFull = normalizedValue.lowercased()
        let appSuffixes = ["telegram @ mac", "telegram desktop", "telegram"]

        for suffix in appSuffixes where loweredFull.hasSuffix(suffix) {
            let cut = normalizedValue.index(normalizedValue.endIndex, offsetBy: -suffix.count)
            let candidate = String(normalizedValue[..<cut])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            if let normalized = telegramNormalizedChatCandidate(candidate) {
                return normalized
            }
        }

        let separators = [" — ", " – ", " - ", " | "]
        for separator in separators where normalizedValue.contains(separator) {
            let segments = normalizedValue
                .components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)) }
                .filter { !$0.isEmpty }
            for segment in segments {
                let lowered = segment.lowercased()
                if lowered.contains("telegram") {
                    continue
                }
                if let normalized = telegramNormalizedChatCandidate(segment) {
                    return normalized
                }
            }
        }

        return nil
    }

    private static func telegramNormalizedChatCandidate(_ value: String) -> String? {
        let normalized = collapsedWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard looksLikeTelegramChatLabel(normalized) else { return nil }
        return normalized
    }

    private static func looksLikeTelegramChatLabel(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard value.count >= 2, value.count <= 84 else { return false }

        let lowered = value.lowercased()
        let blockedExact: Set<String> = [
            "telegram",
            "telegram @ mac",
            "chats",
            "all chats",
            "archived chats",
            "saved messages",
            "search",
            "settings",
            "contacts",
            "calls",
            "new message",
            "compose",
            "attach",
            "message",
            "chat",
            "type a message",
            "forwarded message",
            "unknown chat"
        ]
        if blockedExact.contains(lowered) {
            return false
        }

        if lowered.contains("axtextarea")
            || lowered.contains("axtextfield")
            || lowered.contains("axbutton")
            || lowered.contains("axgroup")
            || lowered.contains("telegram @ mac") {
            return false
        }

        if lowered.hasPrefix("last seen")
            || lowered.hasPrefix("typing")
            || lowered.hasPrefix("online")
            || lowered.hasPrefix("mute")
            || lowered.hasPrefix("unmute")
            || lowered.hasPrefix("mark as")
            || lowered.hasPrefix("delete")
            || lowered.hasPrefix("pin")
            || lowered.hasPrefix("unpin")
            || lowered.hasPrefix("archive")
            || lowered.hasPrefix("edit")
            || lowered.hasPrefix("reply") {
            return false
        }

        if lowered.range(of: #"^\d+\s+(?:unread|message|messages|members|member)$"#, options: .regularExpression) != nil {
            return false
        }

        if lowered.contains("http://") || lowered.contains("https://") {
            return false
        }

        let words = value.split(separator: " ").count
        if words > 8 {
            return false
        }

        return true
    }

    private static func isCodexApp(_ app: NSRunningApplication?) -> Bool {
        let bundleID = app?.bundleIdentifier?.lowercased() ?? ""
        let appName = app?.localizedName?.lowercased() ?? ""
        if bundleID == "com.openai.codex" {
            return true
        }
        return appName == "codex" || appName.contains("codex")
    }

    private static func isAntigravityApp(_ app: NSRunningApplication?) -> Bool {
        let bundleID = app?.bundleIdentifier?.lowercased() ?? ""
        let appName = app?.localizedName?.lowercased() ?? ""
        if bundleID == "com.google.antigravity" {
            return true
        }
        return appName == "antigravity" || appName.contains("antigravity") || bundleID.contains("antigravity")
    }

    private static func isTelegramApp(_ app: NSRunningApplication?) -> Bool {
        let bundleID = app?.bundleIdentifier?.lowercased() ?? ""
        let appName = app?.localizedName?.lowercased() ?? ""
        if bundleID == "ru.keepcoder.telegram" || bundleID.hasPrefix("ru.keepcoder.telegram.") {
            return true
        }
        return appName == "telegram" || appName.contains("telegram") || bundleID.contains("telegram")
    }

    private static func frontmostFocusedWindowElement() -> AXUIElement? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.processIdentifier != selfPID else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        if let focusedWindow = axElementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement) {
            return focusedWindow
        }

        if let firstWindow = axElementFromArrayAttribute(kAXWindowsAttribute as CFString, from: appElement) {
            return firstWindow
        }

        return nil
    }

    private static func frontmostFocusedWindowTitle() -> String? {
        guard let window = frontmostFocusedWindowElement(),
              let title = axStringAttribute(kAXTitleAttribute as CFString, from: window),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return title
    }

    private static func axElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(valueRef, to: AXUIElement.self)
    }

    private static func axElementFromArrayAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              let array = valueRef as? [Any] else {
            return nil
        }
        for item in array {
            guard CFGetTypeID(item as CFTypeRef) == AXUIElementGetTypeID() else { continue }
            return unsafeBitCast(item as CFTypeRef, to: AXUIElement.self)
        }
        return nil
    }

    private static func axElementsAttribute(_ attribute: CFString, from element: AXUIElement) -> [AXUIElement] {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              let array = valueRef as? [Any] else {
            return []
        }

        var elements: [AXUIElement] = []
        elements.reserveCapacity(array.count)
        for item in array {
            let cf = item as CFTypeRef
            guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { continue }
            elements.append(unsafeBitCast(cf, to: AXUIElement.self))
        }
        return elements
    }

    private static func axStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success else {
            return nil
        }
        return valueRef as? String
    }

    private static func axStringValueAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef else {
            return nil
        }
        if let stringValue = valueRef as? String {
            return stringValue
        }
        if let attributed = valueRef as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    private static func normalizedAXRole(_ role: String?) -> String {
        role?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func isGenericFocusedFieldRole(_ role: String) -> Bool {
        genericFocusedFieldRoles.contains(role)
    }

    private static func isGenericAXRoleLabel(_ label: String) -> Bool {
        let normalized = label
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
        let compact = collapsedWhitespace(normalized).lowercased()
        if genericFocusedFieldRoles.contains(compact) {
            return true
        }
        return genericFocusedFieldRoles.contains { role in
            compact.hasPrefix("\(role) ")
        }
    }

    private static func shouldReadAXValueAttribute(forRole role: String) -> Bool {
        let normalizedRole = normalizedAXRole(role)
        guard !normalizedRole.isEmpty else {
            return true
        }
        return !heavyAXValueRoles.contains(normalizedRole)
    }

    private static func axBoolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef else {
            return nil
        }
        if let boolValue = valueRef as? Bool {
            return boolValue
        }
        if let number = valueRef as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private static func axCGPointAttribute(_ attribute: CFString, from element: AXUIElement) -> CGPoint? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(valueRef, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func axCGSizeAttribute(_ attribute: CFString, from element: AXUIElement) -> CGSize? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(valueRef, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private static func axCenterPoint(of element: AXUIElement) -> CGPoint? {
        guard let position = axCGPointAttribute(kAXPositionAttribute as CFString, from: element),
              let size = axCGSizeAttribute(kAXSizeAttribute as CFString, from: element) else {
            return nil
        }
        return CGPoint(
            x: position.x + (size.width / 2.0),
            y: position.y + (size.height / 2.0)
        )
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        guard let position = axCGPointAttribute(kAXPositionAttribute as CFString, from: element),
              let size = axCGSizeAttribute(kAXSizeAttribute as CFString, from: element),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func normalizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = collapsedWhitespace(raw)
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func deriveDocumentLabel(from rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            if url.isFileURL {
                let name = url.deletingPathExtension().lastPathComponent
                return normalizedLabel(name)
            }
            if let host = url.host, !host.isEmpty {
                return normalizedLabel(host)
            }
            return normalizedLabel(url.lastPathComponent)
        }

        let fileURL = URL(fileURLWithPath: trimmed)
        let name = fileURL.deletingPathExtension().lastPathComponent
        return normalizedLabel(name)
    }

    private static func snippet(_ value: String, limit: Int) -> String {
        let normalized = collapsedWhitespace(value)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }
}
