import CryptoKit
import Foundation

enum MemoryProviderKind: String, CaseIterable, Codable, Hashable {
    case codex
    case opencode
    case claude
    case copilot
    case cursor
    case kimi
    case gemini
    case windsurf
    case codeium
    case unknown

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .opencode:
            return "OpenCode"
        case .claude:
            return "Claude"
        case .copilot:
            return "Copilot"
        case .cursor:
            return "Cursor"
        case .kimi:
            return "Kimi"
        case .gemini:
            return "Gemini"
        case .windsurf:
            return "Windsurf"
        case .codeium:
            return "Codeium"
        case .unknown:
            return "Unknown"
        }
    }
}

enum MemoryPromotionTrigger: String, Codable, Hashable {
    case autoCompaction = "auto-compaction"
    case timeout = "timeout"
    case manualCompaction = "manual-compaction"
    case manualPin = "manual-pin"
}

enum MemoryPatternOutcome: String, Codable, Hashable {
    case good
    case bad
    case neutral
}

struct MemoryScopeContext: Codable, Hashable {
    let appName: String
    let bundleID: String
    let surfaceLabel: String
    let projectKey: String?
    let projectName: String?
    let repositoryName: String?
    let identityKey: String?
    let identityType: String?
    let identityLabel: String?
    let scopeKey: String
    let isCodingContext: Bool

    init(
        appName: String,
        bundleID: String,
        surfaceLabel: String,
        projectKey: String? = nil,
        projectName: String? = nil,
        repositoryName: String? = nil,
        identityKey: String? = nil,
        identityType: String? = nil,
        identityLabel: String? = nil,
        scopeKey: String? = nil,
        isCodingContext: Bool
    ) {
        let normalizedAppName = MemoryTextNormalizer.collapsedWhitespace(appName)
        let normalizedBundleID = MemoryTextNormalizer.collapsedWhitespace(bundleID).lowercased()
        let normalizedSurface = MemoryTextNormalizer.collapsedWhitespace(surfaceLabel)
        let normalizedProjectKey = MemoryScopeContext.normalizedScopeValue(projectKey)?.lowercased()
        let normalizedProject = MemoryScopeContext.normalizedScopeValue(projectName)
        let normalizedRepository = MemoryScopeContext.normalizedScopeValue(repositoryName)
        let normalizedIdentityKey = MemoryScopeContext.normalizedScopeValue(identityKey)?.lowercased()
        let normalizedIdentityType = MemoryScopeContext.normalizedScopeValue(identityType)?.lowercased()
        let normalizedIdentityLabel = MemoryScopeContext.normalizedScopeValue(identityLabel)

        self.appName = normalizedAppName.isEmpty ? "Unknown App" : normalizedAppName
        self.bundleID = normalizedBundleID.isEmpty ? "unknown.bundle" : normalizedBundleID
        self.surfaceLabel = normalizedSurface.isEmpty ? "Unknown Surface" : normalizedSurface
        self.projectKey = normalizedProjectKey
        self.projectName = normalizedProject
        self.repositoryName = normalizedRepository
        self.identityKey = normalizedIdentityKey
        self.identityType = normalizedIdentityType
        self.identityLabel = normalizedIdentityLabel
        self.isCodingContext = isCodingContext
        self.scopeKey = scopeKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? scopeKey!.trimmingCharacters(in: .whitespacesAndNewlines)
            : MemoryScopeContext.makeScopeKey(
                bundleID: self.bundleID,
                surfaceLabel: self.surfaceLabel,
                projectKey: self.projectKey,
                projectName: self.projectName,
                repositoryName: self.repositoryName,
                identityKey: self.identityKey,
                identityType: self.identityType
            )
    }

    static func makeScopeKey(
        bundleID: String,
        surfaceLabel: String,
        projectKey: String? = nil,
        projectName: String?,
        repositoryName: String?,
        identityKey: String? = nil,
        identityType: String? = nil
    ) -> String {
        let normalizedBundleID = MemoryTextNormalizer.collapsedWhitespace(bundleID).lowercased()
        let normalizedSurface = MemoryTextNormalizer.collapsedWhitespace(surfaceLabel).lowercased()
        let normalizedProject = normalizedScopeValue(projectKey ?? projectName)?.lowercased() ?? "-"
        let normalizedRepository = normalizedScopeValue(repositoryName)?.lowercased() ?? "-"
        let normalizedIdentityKey = normalizedScopeValue(identityKey)?.lowercased() ?? "-"
        let normalizedIdentityType = normalizedScopeValue(identityType)?.lowercased() ?? "-"
        return "scope|\(normalizedBundleID)|\(normalizedSurface)|\(normalizedProject)|\(normalizedRepository)|\(normalizedIdentityType)|\(normalizedIdentityKey)"
    }

    static func normalizedScopeValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = MemoryTextNormalizer.collapsedWhitespace(value)
        guard !normalized.isEmpty else { return nil }
        return normalized
    }
}

struct ConversationTupleTags: Codable, Hashable {
    let projectKey: String
    let projectLabel: String
    let identityKey: String
    let identityType: String
    let identityLabel: String
    let people: [String]
    let nativeThreadKey: String

    init(
        projectKey: String,
        projectLabel: String,
        identityKey: String,
        identityType: String,
        identityLabel: String,
        people: [String] = [],
        nativeThreadKey: String = ""
    ) {
        let normalizedProjectKey = MemoryTextNormalizer.collapsedWhitespace(projectKey).lowercased()
        let normalizedProjectLabel = MemoryTextNormalizer.collapsedWhitespace(projectLabel)
        let normalizedIdentityKey = MemoryTextNormalizer.collapsedWhitespace(identityKey).lowercased()
        let normalizedIdentityType = MemoryTextNormalizer.collapsedWhitespace(identityType).lowercased()
        let normalizedIdentityLabel = MemoryTextNormalizer.collapsedWhitespace(identityLabel)
        let normalizedNativeThread = MemoryTextNormalizer.collapsedWhitespace(nativeThreadKey).lowercased()

        self.projectKey = normalizedProjectKey.isEmpty ? "project:unknown" : normalizedProjectKey
        self.projectLabel = normalizedProjectLabel.isEmpty ? "Unknown Project" : normalizedProjectLabel
        self.identityKey = normalizedIdentityKey.isEmpty ? "identity:unknown" : normalizedIdentityKey
        self.identityType = normalizedIdentityType.isEmpty ? "unknown" : normalizedIdentityType
        self.identityLabel = normalizedIdentityLabel.isEmpty ? "Unknown Identity" : normalizedIdentityLabel
        self.people = people
            .map { MemoryTextNormalizer.collapsedWhitespace($0) }
            .filter { !$0.isEmpty }
        self.nativeThreadKey = normalizedNativeThread
    }
}

struct MemoryPatternStats: Codable, Hashable, Identifiable {
    let patternKey: String
    let scopeKey: String
    let appName: String
    let bundleID: String
    let surfaceLabel: String
    let projectName: String?
    let repositoryName: String?
    let occurrenceCount: Int
    let goodRepeatCount: Int
    let badRepeatCount: Int
    let firstSeenAt: Date
    let lastSeenAt: Date
    let lastOutcome: MemoryPatternOutcome
    let confidence: Double
    let metadata: [String: String]

    var id: String { patternKey }

    var isRepeating: Bool {
        occurrenceCount >= 2
    }
}

struct MemoryPatternOccurrence: Codable, Hashable, Identifiable {
    let id: UUID
    let patternKey: String
    let cardID: UUID?
    let lessonID: UUID?
    let eventTimestamp: Date
    let outcome: MemoryPatternOutcome
    let trigger: MemoryPromotionTrigger
    let metadata: [String: String]
}

enum MemoryEventKind: String, Codable, Hashable {
    case conversation
    case rewrite
    case summary
    case command
    case fileEdit
    case note
    case plan
    case unknown
}

struct MemorySource: Codable, Hashable, Identifiable {
    let id: UUID
    let provider: MemoryProviderKind
    let rootPath: String
    let displayName: String
    var discoveredAt: Date
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        provider: MemoryProviderKind,
        rootPath: String,
        displayName: String? = nil,
        discoveredAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.provider = provider
        self.rootPath = rootPath
        self.displayName = displayName ?? provider.displayName
        self.discoveredAt = discoveredAt
        self.metadata = metadata
    }
}

struct MemorySourceFile: Codable, Hashable, Identifiable {
    let id: UUID
    let sourceID: UUID
    let absolutePath: String
    let relativePath: String
    var fileHash: String
    var fileSizeBytes: Int64
    var modifiedAt: Date
    var indexedAt: Date
    var parseError: String?
}

struct MemoryEventDraft: Codable, Hashable {
    var kind: MemoryEventKind
    var title: String
    var body: String
    var timestamp: Date
    var nativeSummary: String?
    var keywords: [String]
    var isPlanContent: Bool
    var metadata: [String: String]
    var rawPayload: String?

    init(
        kind: MemoryEventKind,
        title: String,
        body: String,
        timestamp: Date = Date(),
        nativeSummary: String? = nil,
        keywords: [String] = [],
        isPlanContent: Bool = false,
        metadata: [String: String] = [:],
        rawPayload: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.timestamp = timestamp
        self.nativeSummary = nativeSummary
        self.keywords = keywords
        self.isPlanContent = isPlanContent
        self.metadata = metadata
        self.rawPayload = rawPayload
    }
}

struct MemoryEvent: Codable, Hashable, Identifiable {
    let id: UUID
    let sourceID: UUID
    let sourceFileID: UUID
    let provider: MemoryProviderKind
    let kind: MemoryEventKind
    var title: String
    var body: String
    var timestamp: Date
    var nativeSummary: String?
    var keywords: [String]
    var isPlanContent: Bool
    var metadata: [String: String]
    var rawPayload: String?
}

struct MemoryCard: Codable, Hashable, Identifiable {
    let id: UUID
    let sourceID: UUID
    let sourceFileID: UUID
    let eventID: UUID
    let provider: MemoryProviderKind
    var title: String
    var summary: String
    var detail: String
    var keywords: [String]
    var score: Double
    var createdAt: Date
    var updatedAt: Date
    var isPlanContent: Bool
    var metadata: [String: String]
}

struct MemoryLessonDraft: Codable, Hashable {
    var mistakePattern: String
    var improvedPrompt: String
    var rationale: String
    var validationConfidence: Double
    var sourceMetadata: [String: String]

    init(
        mistakePattern: String,
        improvedPrompt: String,
        rationale: String,
        validationConfidence: Double,
        sourceMetadata: [String: String] = [:]
    ) {
        self.mistakePattern = MemoryTextNormalizer.normalizedBody(mistakePattern)
        self.improvedPrompt = MemoryTextNormalizer.normalizedBody(improvedPrompt)
        self.rationale = MemoryTextNormalizer.normalizedSummary(rationale, limit: 320)
        self.validationConfidence = min(1, max(0, validationConfidence))
        self.sourceMetadata = sourceMetadata
    }
}

struct MemoryLesson: Codable, Hashable, Identifiable {
    let id: UUID
    let sourceID: UUID
    let sourceFileID: UUID
    let eventID: UUID
    let cardID: UUID
    let provider: MemoryProviderKind
    var mistakePattern: String
    var improvedPrompt: String
    var rationale: String
    var validationConfidence: Double
    var sourceMetadata: [String: String]
    var createdAt: Date
    var updatedAt: Date
}

struct MemoryIndexedEntry: Hashable, Identifiable {
    let id: UUID
    let provider: MemoryProviderKind
    let sourceRootPath: String
    let sourceFileRelativePath: String
    let projectName: String?
    let repositoryName: String?
    let title: String
    let summary: String
    let detail: String
    let eventTimestamp: Date
    let updatedAt: Date
    let isPlanContent: Bool
    let issueKey: String?
    let attemptNumber: Int?
    let attemptCount: Int?
    let outcomeStatus: String?
    let outcomeEvidence: String?
    let fixSummary: String?
    let validationState: String?
    let invalidatedByAttempt: Int?
    let relationConfidence: Double?
    let relationType: String?
}

struct ConversationThreadRecord: Codable, Hashable, Identifiable {
    let id: String
    var appName: String
    var bundleID: String
    var logicalSurfaceKey: String
    var screenLabel: String
    var fieldLabel: String
    var projectKey: String
    var projectLabel: String
    var identityKey: String
    var identityType: String
    var identityLabel: String
    var nativeThreadKey: String
    var people: [String]
    var runningSummary: String
    var totalExchangeTurns: Int
    var createdAt: Date
    var lastActivityAt: Date
    var updatedAt: Date
}

struct ConversationTurnRecord: Codable, Hashable, Identifiable {
    let id: String
    let threadID: String
    let role: String
    let userText: String
    let assistantText: String
    let normalizedText: String
    let isSummary: Bool
    let sourceTurnCount: Int
    let compactionVersion: Int?
    let metadata: [String: String]
    let createdAt: Date
    let turnDedupeKey: String
}

enum ExpiredSummaryMethod: String, Codable, Hashable {
    case fallback
    case ai
}

struct ExpiredConversationContextRecord: Codable, Hashable, Identifiable {
    let id: String
    let scopeKey: String
    let threadID: String
    let bundleID: String
    let projectKey: String?
    let identityKey: String?
    let summaryText: String
    let summaryMethod: ExpiredSummaryMethod
    let summaryConfidence: Double?
    let sourceTurnCount: Int
    let recentTurnsJSON: String
    let rawTurnsJSON: String
    let trigger: String
    let expiredAt: Date
    let deleteAfterAt: Date
    let consumedAt: Date?
    let consumedByThreadID: String?
    let metadata: [String: String]
}

struct ExpiredConversationContextDiagnostics: Codable, Hashable {
    let totalCount: Int
    let lastSummaryMethod: ExpiredSummaryMethod
    let lastPromotionDecisionSummary: String
}

struct ConversationAgentProfileRecord: Codable, Hashable {
    let threadID: String
    let profileJSON: String
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date

    init(
        threadID: String,
        profileJSON: String = "{}",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date = .distantFuture
    ) {
        let normalized = profileJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadID = threadID
        self.profileJSON = normalized.isEmpty ? "{}" : normalized
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }
}

struct ConversationAgentEntitiesRecord: Codable, Hashable {
    let threadID: String
    let entitiesJSON: String
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date

    init(
        threadID: String,
        entitiesJSON: String = "[]",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date = .distantFuture
    ) {
        let normalized = entitiesJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadID = threadID
        self.entitiesJSON = normalized.isEmpty ? "[]" : normalized
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }
}

struct ConversationAgentPreferencesRecord: Codable, Hashable {
    let threadID: String
    let preferencesJSON: String
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date

    init(
        threadID: String,
        preferencesJSON: String = "{}",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date = .distantFuture
    ) {
        let normalized = preferencesJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadID = threadID
        self.preferencesJSON = normalized.isEmpty ? "{}" : normalized
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }
}

enum ConversationDisambiguationRuleType: String, Codable, Hashable {
    case person
    case project
}

enum ConversationDisambiguationDecision: String, Codable, Hashable {
    case link
    case separate
}

enum ConversationContextMappingSource: String, Codable, Hashable {
    case manual
    case ai
    case deterministic
    case legacy
}

struct ConversationDisambiguationRuleRecord: Codable, Hashable, Identifiable {
    let id: String
    let ruleType: ConversationDisambiguationRuleType
    let appPairKey: String
    let subjectKey: String
    let contextScopeKey: String?
    let decision: ConversationDisambiguationDecision
    let canonicalKey: String?
    let createdAt: Date
    let updatedAt: Date
}

struct ConversationTagAliasRecord: Codable, Hashable, Identifiable {
    let aliasType: String
    let aliasKey: String
    let canonicalKey: String
    let updatedAt: Date

    var id: String {
        "\(aliasType)|\(aliasKey)"
    }
}

struct ConversationContextMappingRow: Codable, Hashable, Identifiable {
    let id: String
    let mappingType: String
    let appPairKey: String
    let subjectKey: String
    let contextScopeKey: String?
    let decision: ConversationDisambiguationDecision
    let canonicalKey: String?
    let source: ConversationContextMappingSource
    let updatedAt: Date
}

struct RewriteSuggestion: Codable, Hashable, Identifiable {
    let id: UUID
    let cardID: UUID
    let provider: MemoryProviderKind
    let originalText: String
    let suggestedText: String
    let rationale: String
    let confidence: Double
    let createdAt: Date
}

enum MemoryRewriteLessonValidationState: String, Codable, Hashable {
    case userConfirmed = "user-confirmed"
    case indexedValidated = "indexed-validated"
    case unvalidated = "unvalidated"
    case invalidated = "invalidated"

    var isValidated: Bool {
        switch self {
        case .userConfirmed, .indexedValidated:
            return true
        case .unvalidated, .invalidated:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .userConfirmed:
            return "User Confirmed"
        case .indexedValidated:
            return "Indexed Validated"
        case .unvalidated:
            return "Unvalidated"
        case .invalidated:
            return "Invalidated"
        }
    }
}

struct MemoryRewriteLesson: Hashable, Identifiable {
    let id: UUID
    let provider: MemoryProviderKind
    let mistakeText: String
    let correctionText: String
    let rationale: String
    let confidence: Double
    let createdAt: Date
    let provenance: String
    let validationState: MemoryRewriteLessonValidationState
}

struct MemoryRewritePromptContext: Hashable {
    let lessons: [MemoryRewriteLesson]
    let supportingCards: [MemoryCard]

    var isEmpty: Bool {
        lessons.isEmpty && supportingCards.isEmpty
    }
}

struct MemoryRewriteLookupOptions: Hashable {
    var provider: MemoryProviderKind?
    var includePlanContent: Bool
    var limit: Int

    init(provider: MemoryProviderKind? = nil, includePlanContent: Bool = false, limit: Int = 20) {
        self.provider = provider
        self.includePlanContent = includePlanContent
        self.limit = max(1, min(limit, 200))
    }
}

enum MemoryTextNormalizer {
    private static let tokenRegex = try? NSRegularExpression(
        pattern: "[A-Za-z0-9]+(?:[._'/-][A-Za-z0-9]+)*",
        options: []
    )

    static func collapsedWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalizedTitle(_ value: String, fallback: String = "Untitled Memory") -> String {
        let trimmed = collapsedWhitespace(value)
        if trimmed.isEmpty {
            return fallback
        }
        if trimmed.count <= 120 {
            return trimmed
        }
        return String(trimmed.prefix(117)) + "..."
    }

    static func normalizedBody(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return trimmed
        }
        return trimmed.replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func normalizedSummary(_ value: String, limit: Int = 240) -> String {
        let clean = collapsedWhitespace(value)
        guard clean.count > limit else { return clean }
        return String(clean.prefix(max(0, limit - 3))) + "..."
    }

    static func normalizedKeywords(_ values: [String], limit: Int = 16) -> [String] {
        guard !values.isEmpty else { return [] }
        var seen = Set<String>()
        var keywords: [String] = []
        keywords.reserveCapacity(min(limit, values.count))

        for raw in values {
            let token = collapsedWhitespace(raw).lowercased()
            guard token.count >= 2 else { continue }
            guard seen.insert(token).inserted else { continue }
            keywords.append(token)
            if keywords.count >= limit {
                break
            }
        }

        return keywords
    }

    static func keywords(from text: String, limit: Int = 16) -> [String] {
        guard limit > 0 else { return [] }
        guard let tokenRegex else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = tokenRegex.matches(in: text, options: [], range: range)

        var seen = Set<String>()
        var tokens: [String] = []
        tokens.reserveCapacity(min(limit, matches.count))

        for match in matches {
            guard let tokenRange = Range(match.range, in: text) else { continue }
            let token = text[tokenRange].lowercased()
            guard token.count >= 2 else { continue }
            guard seen.insert(token).inserted else { continue }
            tokens.append(token)
            if tokens.count == limit {
                break
            }
        }
        return tokens
    }

    static func inferPlanContent(path: String, kind: MemoryEventKind, body: String) -> Bool {
        if kind == .plan {
            return true
        }

        let normalizedPath = path.lowercased()
        if normalizedPath.contains("/plan") || normalizedPath.contains("roadmap") || normalizedPath.contains("todo") {
            return true
        }

        let text = body.lowercased()
        return text.contains("acceptance criteria:")
            || text.contains("implementation plan:")
            || text.contains("milestone")
            || text.contains("backlog")
    }
}

enum MemoryIdentifier {
    static func stableUUID(for value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8))
        let bytes = Array(digest.prefix(16))
        let uuidBytes: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuidBytes)
    }

    static func stableHexDigest(for value: String) -> String {
        stableHexDigest(data: Data(value.utf8))
    }

    static func stableHexDigest(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
