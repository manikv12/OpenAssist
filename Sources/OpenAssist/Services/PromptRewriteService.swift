import Foundation
import Security

enum PromptRewriteStrength: String, Equatable {
    case light
    case balanced
    case strong
}

struct PromptRewriteSuggestion: Equatable {
    let suggestedText: String
    let memoryContext: String?
    let confidence: Double?
    let rewriteStrength: PromptRewriteStrength?
    let continuityTrace: String?
    let refinementDurationSeconds: TimeInterval?

    init(
        suggestedText: String,
        memoryContext: String?,
        confidence: Double? = nil,
        rewriteStrength: PromptRewriteStrength? = nil,
        continuityTrace: String? = nil,
        refinementDurationSeconds: TimeInterval? = nil
    ) {
        self.suggestedText = suggestedText
        self.memoryContext = memoryContext
        self.confidence = confidence
        self.rewriteStrength = rewriteStrength
        self.continuityTrace = continuityTrace
        self.refinementDurationSeconds = refinementDurationSeconds
    }
}

enum PromptRewriteFeedbackAction: String, Equatable {
    case usedSuggested = "used-suggested"
    case autoInsertedSuggested = "auto-inserted-suggested"
    case editedThenInserted = "edited-then-inserted"
    case insertedOriginal = "inserted-original"
    case dismissedSuggestion = "dismissed-suggestion"
    case retriedAfterFailure = "retried-after-failure"
    case insertedOriginalAfterFailure = "inserted-original-after-failure"
    case canceledAfterFailure = "canceled-after-failure"
}

struct PromptRewriteFeedbackEvent {
    let action: PromptRewriteFeedbackAction
    let originalText: String
    let suggestedText: String?
    let finalInsertedText: String?
    let failureDetail: String?
    let timestamp: Date

    init(
        action: PromptRewriteFeedbackAction,
        originalText: String,
        suggestedText: String? = nil,
        finalInsertedText: String? = nil,
        failureDetail: String? = nil,
        timestamp: Date = Date()
    ) {
        self.action = action
        self.originalText = originalText
        self.suggestedText = suggestedText
        self.finalInsertedText = finalInsertedText
        self.failureDetail = failureDetail
        self.timestamp = timestamp
    }
}

protocol PromptRewriteBackendServing {
    func retrieveSuggestion(
        for cleanedTranscript: String,
        conversationContext: PromptRewriteConversationContext?,
        conversationHistory: [PromptRewriteConversationTurn]
    ) async throws -> PromptRewriteSuggestion?
    func recordFeedback(_ event: PromptRewriteFeedbackEvent) async
}

enum PromptRewriteBackendError: Error, Equatable {
    case providerFailure(reason: String)
}

enum PromptRewriteServiceError: Error, Equatable {
    case timedOut(timeoutSeconds: TimeInterval)
    case providerUnavailable(reason: String)
}

final class PromptRewriteService {
    static let shared = PromptRewriteService()
    private static let minTimeoutSeconds: TimeInterval = 0.25
    private static let maxTimeoutSeconds: TimeInterval = 120
    private static let localRuntimeMinimumTimeoutSeconds: TimeInterval = 45
    fileprivate static let timeoutSettingsDefaultsKey = "OpenAssist.promptRewriteRequestTimeoutSeconds"

    private let backend: PromptRewriteBackendServing
    private let timeoutSeconds: TimeInterval

    init(
        backend: PromptRewriteBackendServing = BackendPromptRewriteService.shared,
        timeoutSeconds: TimeInterval = 8.0
    ) {
        self.backend = backend
        self.timeoutSeconds = min(
            max(Self.minTimeoutSeconds, timeoutSeconds),
            Self.maxTimeoutSeconds
        )
    }

    func retrieveSuggestion(
        for cleanedTranscript: String,
        conversationContext: PromptRewriteConversationContext? = nil,
        conversationHistory: [PromptRewriteConversationTurn] = []
    ) async throws -> PromptRewriteSuggestion? {
        let normalizedTranscript = cleanedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else { return nil }
        let configuredTimeout = Self.configuredTimeout(fallback: timeoutSeconds)
        let effectiveTimeoutSeconds = Self.effectiveTimeoutSeconds(
            baseTimeoutSeconds: configuredTimeout.seconds,
            hasUserConfiguredTimeout: configuredTimeout.userConfigured
        )

        do {
            return try await withThrowingTaskGroup(of: PromptRewriteSuggestion?.self) { group in
                group.addTask {
                    try await self.backend.retrieveSuggestion(
                        for: normalizedTranscript,
                        conversationContext: conversationContext,
                        conversationHistory: conversationHistory
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: Self.timeoutNanoseconds(for: effectiveTimeoutSeconds))
                    throw PromptRewriteServiceError.timedOut(timeoutSeconds: effectiveTimeoutSeconds)
                }

                let firstResult = try await group.next()
                group.cancelAll()
                return firstResult ?? nil
            }
        } catch let serviceError as PromptRewriteServiceError {
            throw serviceError
        } catch let backendError as PromptRewriteBackendError {
            switch backendError {
            case let .providerFailure(reason):
                throw PromptRewriteServiceError.providerUnavailable(reason: Self.userFacingProviderFailureReason(reason))
            }
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                throw PromptRewriteServiceError.providerUnavailable(reason: Self.userFacingProviderFailureReason("unknown-provider-error"))
            }
            throw PromptRewriteServiceError.providerUnavailable(reason: Self.userFacingProviderFailureReason(detail))
        }
    }

    func recordFeedback(_ event: PromptRewriteFeedbackEvent) async {
        await backend.recordFeedback(event)
    }

    private static func timeoutNanoseconds(for timeoutSeconds: TimeInterval) -> UInt64 {
        let nanos = timeoutSeconds * 1_000_000_000
        if !nanos.isFinite || nanos <= 0 {
            return UInt64(Self.minTimeoutSeconds * 1_000_000_000)
        }
        if nanos >= Double(UInt64.max) {
            return UInt64.max
        }
        return UInt64(nanos.rounded())
    }

    fileprivate static func configuredTimeout(fallback: TimeInterval) -> (seconds: TimeInterval, userConfigured: Bool) {
        let defaults = UserDefaults.standard
        let userConfigured = defaults.object(forKey: timeoutSettingsDefaultsKey) != nil
        let rawValue = userConfigured ? defaults.double(forKey: timeoutSettingsDefaultsKey) : fallback
        let normalized = min(max(Self.minTimeoutSeconds, rawValue), Self.maxTimeoutSeconds)
        return (seconds: normalized, userConfigured: userConfigured)
    }

    fileprivate static func effectiveTimeoutSeconds(
        baseTimeoutSeconds: TimeInterval,
        hasUserConfiguredTimeout: Bool
    ) -> TimeInterval {
        guard isOllamaProviderActive, !hasUserConfiguredTimeout else { return baseTimeoutSeconds }
        return max(baseTimeoutSeconds, localRuntimeMinimumTimeoutSeconds)
    }

    private static func userFacingProviderFailureReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Provider is unavailable." : trimmed

        guard isOllamaProviderActive else { return fallback }
        let normalized = fallback.lowercased()
        let localRuntimeNeedles = [
            "localhost",
            "11434",
            "cannot connect",
            "connection refused",
            "network is unreachable",
            "timed out",
            "invalid provider base url",
            "request failed: the operation couldn’t be completed",
            "request failed: could not connect"
        ]

        if localRuntimeNeedles.contains(where: { normalized.contains($0) }) {
            return "Local AI runtime is unavailable. AI Studio -> Prompt Models -> Local AI Setup, then install or repair Local AI."
        }
        return fallback
    }

    private static var isOllamaProviderActive: Bool {
        let rawValue = UserDefaults.standard
            .string(forKey: "OpenAssist.promptRewriteProviderMode")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return rawValue == "ollama (local)" || rawValue == "ollama"
    }
}

private enum PromptRewriteLiveProviderMode: String {
    case openAI = "openai"
    case google = "google"
    case openRouter = "openrouter"
    case groq = "groq"
    case anthropic = "anthropic"
    case ollama = "ollama"

    var requiresAuthentication: Bool {
        switch self {
        case .ollama:
            return false
        case .openAI, .google, .openRouter, .groq, .anthropic:
            return true
        }
    }

    var supportsOAuthSignIn: Bool {
        switch self {
        case .openAI, .anthropic:
            return true
        case .google, .openRouter, .groq, .ollama:
            return false
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:
            return "gpt-4.1-mini"
        case .google:
            return "gemini-3-flash-preview"
        case .openRouter:
            return "openai/gpt-4.1-mini"
        case .groq:
            return "llama-3.3-70b-versatile"
        case .anthropic:
            return "claude-3-5-sonnet-latest"
        case .ollama:
            return "llama3.1"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI:
            return "https://api.openai.com/v1"
        case .google:
            return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openRouter:
            return "https://openrouter.ai/api/v1"
        case .groq:
            return "https://api.groq.com/openai/v1"
        case .anthropic:
            return "https://api.anthropic.com/v1"
        case .ollama:
            return "http://localhost:11434/v1"
        }
    }

    var usesAnthropicMessagesAPI: Bool {
        self == .anthropic
    }

    var settingsProviderMode: PromptRewriteProviderMode {
        switch self {
        case .openAI:
            return .openAI
        case .google:
            return .google
        case .openRouter:
            return .openRouter
        case .groq:
            return .groq
        case .anthropic:
            return .anthropic
        case .ollama:
            return .ollama
        }
    }
}

private struct PromptRewriteLiveConfiguration {
    let providerMode: PromptRewriteLiveProviderMode
    let openAIModel: String
    let openAIBaseURL: String
    let apiKey: String
    let oauthSession: PromptRewriteOAuthSession?
    let rewriteStylePreset: PromptRewriteStylePreset
    let rewriteCustomStyleInstructions: String

    var hasCredentials: Bool {
        if let oauthSession {
            return !oauthSession.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

final class BackendPromptRewriteService: PromptRewriteBackendServing {
    static let shared = BackendPromptRewriteService()

    private enum StubMode: String {
        case live
        case disabled
        case suggest
        case fail
        case timeout
    }

    private let retrievalService: MemoryRewriteRetrievalService
    private let openAIProvider: OpenAIPromptRewriteProvider

    init(retrievalService: MemoryRewriteRetrievalService = .shared) {
        self.retrievalService = retrievalService
        self.openAIProvider = .shared
    }

    func retrieveSuggestion(
        for cleanedTranscript: String,
        conversationContext: PromptRewriteConversationContext?,
        conversationHistory: [PromptRewriteConversationTurn]
    ) async throws -> PromptRewriteSuggestion? {
        let mode = Self.stubMode
        switch mode {
        case .live:
            do {
                let config = Self.liveConfiguration()
                if config.providerMode.requiresAuthentication && !config.hasCredentials {
                    CrashReporter.logInfo(
                        """
                        Prompt rewrite skipped provider request \
                        reason=missing-credentials \
                        provider=\(config.providerMode.rawValue) \
                        model=\(config.openAIModel)
                        """
                    )
                    return nil
                }

                try await Self.ensureLocalRuntimeReadyIfNeeded(configuration: config)

                let memoryEnabled = await MainActor.run { FeatureFlags.aiMemoryEnabled }
                if memoryEnabled {
                    let scope = Self.memoryScope(from: conversationContext)
                    let rewriteContext = try await retrievalService.fetchPromptRewriteContext(
                        for: cleanedTranscript,
                        lessonLimit: 6,
                        cardLimit: 4,
                        scope: scope
                    )
                    // Do not pay a provider round-trip unless we have an actual rewrite lesson match.
                    // Supporting cards alone are too weak and can add latency without improving quality.
                    guard !rewriteContext.lessons.isEmpty else {
                        CrashReporter.logInfo(
                            """
                            Prompt rewrite skipped provider request \
                            reason=no-matching-lessons \
                            provider=\(config.providerMode.rawValue) \
                            model=\(config.openAIModel) \
                            transcriptChars=\(cleanedTranscript.count) \
                            cards=\(rewriteContext.supportingCards.count)
                            """
                        )
                        return nil
                    }

                    let suggestion = try await openAIProvider.retrieveSuggestion(
                        for: cleanedTranscript,
                        rewriteContext: rewriteContext,
                        includeMemoryContext: true,
                        configuration: config,
                        conversationContext: conversationContext,
                        conversationHistory: conversationHistory
                    )
                    return enrichedSuggestion(
                        suggestion,
                        memoryEnabled: true,
                        lessonCount: rewriteContext.lessons.count,
                        historyCount: conversationHistory.count
                    )
                }

                let suggestion = try await openAIProvider.retrieveSuggestion(
                    for: cleanedTranscript,
                    rewriteContext: MemoryRewritePromptContext(lessons: [], supportingCards: []),
                    includeMemoryContext: false,
                    configuration: config,
                    conversationContext: conversationContext,
                    conversationHistory: conversationHistory
                )
                return enrichedSuggestion(
                    suggestion,
                    memoryEnabled: false,
                    lessonCount: 0,
                    historyCount: conversationHistory.count
                )
            } catch let backendError as PromptRewriteBackendError {
                throw backendError
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                throw PromptRewriteBackendError.providerFailure(
                    reason: detail.isEmpty ? "memory-retrieval-failed" : detail
                )
            }
        case .disabled:
            CrashReporter.logInfo("Prompt rewrite skipped provider request reason=stub-disabled")
            return nil
        case .suggest:
            let suggestedText = Self.suggestedStubText(fallback: cleanedTranscript)
            guard !suggestedText.isEmpty else { return nil }
            let suggestion = PromptRewriteSuggestion(
                suggestedText: suggestedText,
                memoryContext: "stubbed-memory-context"
            )
            return enrichedSuggestion(
                suggestion,
                memoryEnabled: false,
                lessonCount: 0,
                historyCount: conversationHistory.count
            )
        case .fail:
            throw PromptRewriteBackendError.providerFailure(reason: "stub-provider-failure")
        case .timeout:
            try await Task.sleep(nanoseconds: 15_000_000_000)
            CrashReporter.logInfo("Prompt rewrite skipped provider request reason=stub-timeout")
            return nil
        }
    }

    func recordFeedback(_ event: PromptRewriteFeedbackEvent) async {
        let memoryEnabled = await MainActor.run { FeatureFlags.aiMemoryEnabled }
        guard memoryEnabled else { return }

        let original = event.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggested = event.suggestedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let final = event.finalInsertedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !original.isEmpty,
           !final.isEmpty,
           final.caseInsensitiveCompare(original) != .orderedSame {
            let rationale = feedbackRationale(for: event)
            do {
                try await retrievalService.persistFeedbackRewrite(
                    originalText: original,
                    rewrittenText: final,
                    rationale: rationale,
                    confidence: confidence(for: event.action),
                    timestamp: event.timestamp
                )
            } catch {
                // best effort persistence
            }
        }

        if !original.isEmpty, !suggested.isEmpty {
            switch event.action {
            case .insertedOriginal:
                do {
                    try await retrievalService.invalidateLessonPair(
                        originalText: original,
                        suggestedText: suggested,
                        reason: "User rejected this suggestion and inserted original prompt.",
                        timestamp: event.timestamp
                    )
                } catch {
                    // best effort invalidation
                }
            case .editedThenInserted:
                if !final.isEmpty,
                   final.caseInsensitiveCompare(suggested) != .orderedSame {
                    do {
                        try await retrievalService.invalidateLessonPair(
                            originalText: original,
                            suggestedText: suggested,
                            reason: "Superseded by a better user-edited solution for the same scenario.",
                            timestamp: event.timestamp
                        )
                    } catch {
                        // best effort invalidation
                    }
                }
            case .dismissedSuggestion,
                 .usedSuggested,
                 .autoInsertedSuggested,
                 .retriedAfterFailure,
                 .insertedOriginalAfterFailure,
                 .canceledAfterFailure:
                break
            }
        }

        guard Self.isDebugLoggingEnabled else { return }
        let action = event.action.rawValue
        let detail = event.failureDetail ?? "none"
        print("[PromptRewriteFeedback] action=\(action) detail=\(detail)")
    }

    private func feedbackRationale(for event: PromptRewriteFeedbackEvent) -> String {
        switch event.action {
        case .usedSuggested:
            return "User accepted suggested rewrite"
        case .autoInsertedSuggested:
            return "Suggested rewrite auto-inserted"
        case .editedThenInserted:
            return "User edited suggested rewrite and inserted"
        case .insertedOriginal:
            return "User inserted original text"
        case .dismissedSuggestion:
            return "User dismissed rewrite suggestion"
        case .retriedAfterFailure:
            return "User retried rewrite after failure"
        case .insertedOriginalAfterFailure:
            return "User inserted original after rewrite failure"
        case .canceledAfterFailure:
            return "User canceled after rewrite failure"
        }
    }

    private func confidence(for action: PromptRewriteFeedbackAction) -> Double {
        switch action {
        case .usedSuggested:
            return 0.95
        case .autoInsertedSuggested:
            return 0.93
        case .editedThenInserted:
            return 0.90
        case .insertedOriginal:
            return 0.25
        case .dismissedSuggestion:
            return 0.10
        case .retriedAfterFailure:
            return 0.40
        case .insertedOriginalAfterFailure:
            return 0.20
        case .canceledAfterFailure:
            return 0.10
        }
    }

    private func enrichedSuggestion(
        _ suggestion: PromptRewriteSuggestion?,
        memoryEnabled: Bool,
        lessonCount: Int,
        historyCount: Int
    ) -> PromptRewriteSuggestion? {
        guard let suggestion else { return nil }
        let metadata = rewriteMetadataHeuristic(
            memoryEnabled: memoryEnabled,
            lessonCount: lessonCount,
            historyCount: historyCount
        )
        return PromptRewriteSuggestion(
            suggestedText: suggestion.suggestedText,
            memoryContext: suggestion.memoryContext,
            confidence: suggestion.confidence ?? metadata.confidence,
            rewriteStrength: suggestion.rewriteStrength ?? metadata.rewriteStrength,
            continuityTrace: suggestion.continuityTrace ?? metadata.continuityTrace,
            refinementDurationSeconds: suggestion.refinementDurationSeconds
        )
    }

    private func rewriteMetadataHeuristic(
        memoryEnabled: Bool,
        lessonCount: Int,
        historyCount: Int
    ) -> (confidence: Double, rewriteStrength: PromptRewriteStrength, continuityTrace: String) {
        let normalizedLessonCount = max(0, lessonCount)
        let normalizedHistoryCount = max(0, historyCount)
        let lessonBacked = memoryEnabled && normalizedLessonCount > 0

        let confidence: Double
        let rewriteStrength: PromptRewriteStrength
        if lessonBacked {
            confidence = min(0.90, 0.80 + (Double(min(normalizedLessonCount, 3)) * 0.03))
            if normalizedLessonCount >= 4 {
                rewriteStrength = .strong
            } else if normalizedLessonCount >= 2 {
                rewriteStrength = .balanced
            } else {
                rewriteStrength = .light
            }
        } else {
            confidence = min(0.85, 0.60 + (Double(min(normalizedHistoryCount, 5)) * 0.05))
            if normalizedHistoryCount >= 5 {
                rewriteStrength = .strong
            } else if normalizedHistoryCount >= 3 {
                rewriteStrength = .balanced
            } else {
                rewriteStrength = .light
            }
        }

        let continuityTrace = "historyTurns=\(normalizedHistoryCount); lessons=\(normalizedLessonCount); lessonBacked=\(lessonBacked)"
        return (confidence, rewriteStrength, continuityTrace)
    }

    private static var stubMode: StubMode {
        let raw = ProcessInfo.processInfo.environment["OPENASSIST_PROMPT_REWRITE_STUB_MODE"]?.lowercased()
        if raw == nil {
            return .live
        }
        return StubMode(rawValue: raw ?? "") ?? .live
    }

    private static var isDebugLoggingEnabled: Bool {
        ProcessInfo.processInfo.environment["OPENASSIST_PROMPT_REWRITE_DEBUG"] == "1"
    }

    private static func suggestedStubText(fallback: String) -> String {
        if let configuredText = ProcessInfo.processInfo.environment["OPENASSIST_PROMPT_REWRITE_STUB_TEXT"] {
            let trimmed = configuredText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return fallback
    }

    private static func liveConfiguration() -> PromptRewriteLiveConfiguration {
        let defaults = UserDefaults.standard

        let providerRaw = defaults
            .string(forKey: "OpenAssist.promptRewriteProviderMode")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let providerMode: PromptRewriteLiveProviderMode
        switch providerRaw {
        case "openai":
            providerMode = .openAI
        case "google", "gemini", "google ai studio (gemini)", "google-ai-studio-gemini":
            providerMode = .google
        case "openrouter":
            providerMode = .openRouter
        case "groq":
            providerMode = .groq
        case "anthropic":
            providerMode = .anthropic
        case "ollama (local)", "ollama":
            providerMode = .ollama
        case "local memory", "local-memory", "local":
            providerMode = .openAI
        default:
            providerMode = .openAI
        }

        let model = defaults
            .string(forKey: "OpenAssist.promptRewriteOpenAIModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = defaults
            .string(forKey: "OpenAssist.promptRewriteOpenAIBaseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stylePresetRawValue = defaults
            .string(forKey: "OpenAssist.promptRewriteStylePreset")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? PromptRewriteStylePreset.balanced.rawValue
        let stylePreset = PromptRewriteStylePreset(rawValue: stylePresetRawValue) ?? .balanced
        let customStyleInstructions = defaults
            .string(forKey: "OpenAssist.promptRewriteCustomStyleInstructions")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let oauthSession = PromptRewriteOAuthCredentialStore.loadSession(for: providerMode.settingsProviderMode)
        let loadedAPIKey = loadProviderAPIKey(for: providerMode)
        var resolvedModel = (model?.isEmpty == false) ? model! : providerMode.defaultModel
        var resolvedBaseURL = (baseURL?.isEmpty == false) ? baseURL! : providerMode.defaultBaseURL
        if providerMode == .openAI {
            let usingOpenAIOAuthOnly = oauthSession != nil
                && loadedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if usingOpenAIOAuthOnly,
               !PromptRewriteModelCatalogService.isOpenAIOAuthCompatibleModelID(resolvedModel) {
                resolvedModel = PromptRewriteModelCatalogService.defaultOpenAIOAuthModelID
            }
            if usingOpenAIOAuthOnly {
                resolvedBaseURL = providerMode.defaultBaseURL
            }
        }
        return PromptRewriteLiveConfiguration(
            providerMode: providerMode,
            openAIModel: resolvedModel,
            openAIBaseURL: resolvedBaseURL,
            apiKey: loadedAPIKey,
            oauthSession: oauthSession,
            rewriteStylePreset: stylePreset,
            rewriteCustomStyleInstructions: customStyleInstructions
        )
    }

    private static func loadProviderAPIKey(for providerMode: PromptRewriteLiveProviderMode) -> String {
        guard providerMode.requiresAuthentication else { return "" }

        if let envValue = ProcessInfo.processInfo.environment["OPENASSIST_PROMPT_REWRITE_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envValue.isEmpty {
            return envValue
        }

        if let envValue = ProcessInfo.processInfo.environment["OPENASSIST_OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envValue.isEmpty {
            return envValue
        }
        if providerMode == .google {
            if let envValue = ProcessInfo.processInfo.environment["OPENASSIST_GOOGLE_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !envValue.isEmpty {
                return envValue
            }
            if let envValue = ProcessInfo.processInfo.environment["OPENASSIST_GEMINI_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !envValue.isEmpty {
                return envValue
            }
        }

        for providerAccount in keychainAccounts(for: providerMode) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.manikvashith.OpenAssist",
                kSecAttrAccount as String: providerAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess,
                  let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                continue
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if providerMode == .openAI {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.manikvashith.OpenAssist",
                kSecAttrAccount as String: "prompt-rewrite-openai-api-key",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var legacyItem: CFTypeRef?
            let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyItem)
            guard legacyStatus == errSecSuccess,
                  let legacyData = legacyItem as? Data,
                  let legacyValue = String(data: legacyData, encoding: .utf8) else {
                return ""
            }
            return legacyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func keychainAccounts(for providerMode: PromptRewriteLiveProviderMode) -> [String] {
        var slugs: [String] = []
        let candidateRawValues = [
            providerMode.settingsProviderMode.rawValue,
            providerMode.rawValue
        ]
        for rawValue in candidateRawValues {
            let slug = rawValue
                .lowercased()
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: " ", with: "-")
            if !slug.isEmpty, !slugs.contains(slug) {
                slugs.append(slug)
            }
        }
        return slugs.map { "prompt-rewrite-provider-api-key.\($0)" }
    }

    private static func memoryScope(
        from conversationContext: PromptRewriteConversationContext?
    ) -> MemoryScopeContext? {
        guard let conversationContext else { return nil }
        let surface = [
            conversationContext.screenLabel,
            conversationContext.fieldLabel
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " • ")

        let scopeContext = MemoryScopeContext(
            appName: conversationContext.appName,
            bundleID: conversationContext.bundleIdentifier,
            surfaceLabel: surface.isEmpty ? "Current Surface" : surface,
            projectKey: conversationContext.projectKey,
            projectName: conversationContext.projectLabel,
            repositoryName: nil,
            identityKey: conversationContext.identityKey,
            identityType: conversationContext.identityType,
            identityLabel: conversationContext.identityLabel,
            isCodingContext: inferCodingContext(
                appName: conversationContext.appName,
                bundleID: conversationContext.bundleIdentifier
            )
        )
        return scopeContext
    }

    private static func inferCodingContext(appName: String, bundleID: String) -> Bool {
        let value = "\(appName) \(bundleID)".lowercased()
        let codingIdentifiers = [
            "xcode", "cursor", "vscode", "jetbrains", "codex",
            "code", "sublime", "nova", "android.studio"
        ]
        return codingIdentifiers.contains { value.contains($0) }
    }

    private static func ensureLocalRuntimeReadyIfNeeded(
        configuration: PromptRewriteLiveConfiguration
    ) async throws {
        guard configuration.providerMode == .ollama else { return }

        let runtime = LocalAIRuntimeManager.shared
        var detection = await runtime.detect()
        guard detection.installed else {
            throw PromptRewriteBackendError.providerFailure(
                reason: "Local AI runtime is unavailable. AI Studio -> Prompt Models -> Local AI Setup, then install or repair Local AI."
            )
        }

        if !detection.isHealthy {
            do {
                detection = try await runtime.start()
                CrashReporter.logInfo("Local AI runtime auto-started on first local rewrite request.")
            } catch {
                throw PromptRewriteBackendError.providerFailure(
                    reason: "Local AI runtime is unavailable. AI Studio -> Prompt Models -> Local AI Setup, then install or repair Local AI."
                )
            }
        }

        let modelID = configuration.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelID.isEmpty {
            let isInstalled = await runtime.isModelInstalled(modelID)
            if !isInstalled {
                throw PromptRewriteBackendError.providerFailure(
                    reason: "Local model \(modelID) is not installed. AI Studio -> Prompt Models -> Local AI Setup to install it."
                )
            }
        }
    }
}

private actor OpenAIPromptRewriteProvider {
    static let shared = OpenAIPromptRewriteProvider()

    private struct ResponsePayload {
        let suggestedText: String
        let memoryContext: String?
        let shouldRewrite: Bool
    }

    private enum ProviderCredential {
        case none
        case apiKey(String)
        case oauth(PromptRewriteOAuthSession)
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func retrieveSuggestion(
        for cleanedTranscript: String,
        rewriteContext: MemoryRewritePromptContext,
        includeMemoryContext: Bool,
        configuration: PromptRewriteLiveConfiguration,
        conversationContext: PromptRewriteConversationContext?,
        conversationHistory: [PromptRewriteConversationTurn]
    ) async throws -> PromptRewriteSuggestion? {
        guard includeMemoryContext == false || !rewriteContext.isEmpty else {
            logNilSuggestion(
                reason: "empty-rewrite-context",
                configuration: configuration,
                cleanedTranscript: cleanedTranscript,
                includeMemoryContext: includeMemoryContext,
                rewriteContext: rewriteContext,
                conversationHistoryCount: conversationHistory.count
            )
            return nil
        }

        let lessonPayload = formattedLessonPayload(from: rewriteContext.lessons.prefix(6).map { $0 })
        let supportingCardPayload = formattedSupportingCardPayload(from: rewriteContext.supportingCards.prefix(4).map { $0 })
        let styleGuidance = styleGuidanceBlock(configuration: configuration)
        let conversationContextLine = conversationContextLine(from: conversationContext)
        let conversationHistoryPayload = formattedConversationPayload(from: conversationHistory)
        let contextTermHints = contextTermHintsLine(
            from: conversationContext,
            conversationHistory: conversationHistory
        )
        let systemPrompt: String
        let userPrompt: String
        if includeMemoryContext {
            systemPrompt = """
            You are a Prompt Refiner only.
            You improve user prompts using previous prompt-fix memories.
            Prioritize validated mistake->correction lessons over generic memory cards.
            Return strict JSON only with this shape:
            {
              "should_rewrite": boolean,
              "suggested_text": string,
              "memory_context": string
            }
            Rules:
            - Rewrite only. Never answer, solve, explain, or execute the user's task.
            - Keep edits minimal: fix grammar, phrasing, and clarity while preserving the original wording when possible.
            - Input originates from speech transcription and may contain homophone or misrecognition errors.
            - Recover likely intent when wording is semantically broken due to dictation artifacts.
            - Prefer context-backed terminology fixes (for example, "Obsidian wall" -> "Obsidian vault") over preserving nonsensical phrases.
            - Never introduce a new domain term unless it appears in the original prompt, conversation context, recent turns, or memory payload.
            - If correction confidence is low, keep the original uncertain term instead of inventing a replacement.
            - Preserve task type: if the source is a question, output a better-phrased question, not an answer.
            - Do not reframe plain user text into document templates, section headers, or issue-report formats unless the source already uses that format.
            - Preserve narrative voice (for example first-person "I was trying...") instead of rewriting into impersonal documentation voice.
            - If the source is an unfinished fragment, keep it as an unfinished fragment; do not invent missing details.
            - Keep user intent unchanged.
            - Do not invent new requirements, facts, steps, examples, or assumptions.
            - If no meaningful rewrite is needed, set should_rewrite=false and suggested_text equal to the original prompt.
            - Prefer lesson entries where validated=true.
            - Apply mistake->correction lessons only when the mistake is actually present or strongly implied.
            - Use supporting cards only as secondary context after lesson matching.
            - Use memory/context only to resolve references and apply validated wording corrections.
            - Never introduce new goals from memory/context that are not in the source text.
            - memory_context should mention lesson provenance and validation status when relevant.
            - suggested_text must be a rewritten user prompt ready to paste into another AI tool.
            - Never ask follow-up questions, request clarification, or ask the user for more details.
            - If the source is ambiguous, keep the original meaning and produce the best-effort cleaned rewrite without adding questions.
            - Never use assistant lead-ins like "Sure", "I can", "Let me", or "Here's".
            - Preserve structural formatting from the original prompt when present (questions, bullet points, numbered lists, markdown sections).
            - Do not collapse list/question formatting into a single paragraph.
            - Keep the conversation flow continuous; avoid introducing disruptive meta prompts, sudden action lists, or unrelated dialogue pivots.
            - Use the most recent 3-5 same-context turns to resolve references and entity continuity (for example, "Obsidian" and "Obsidian vault"), but avoid dragging in unrelated older context.
            - When same-context history is provided, continue naturally without restarting the dialogue, but do not answer prior questions.
            \(styleGuidance)
            """

            userPrompt = """
            Task: Rewrite the original prompt text only. Do not answer it.
            Input note: The original prompt is speech-transcribed and may include recognition mistakes.

            Original prompt:
            \(cleanedTranscript)

            Conversation context (same app/screen bucket):
            \(conversationContextLine)

            Context term hints (disambiguation only):
            \(contextTermHints)

            Recent conversation turns (oldest -> newest):
            \(conversationHistoryPayload)

            Rewrite lessons payload (primary):
            \(lessonPayload)

            Supporting memory cards payload (secondary):
            \(supportingCardPayload)
            """
        } else {
            systemPrompt = """
            You are a Prompt Refiner only.
            You improve user prompts for clarity, structure, and execution quality.
            Return strict JSON only with this shape:
            {
              "should_rewrite": boolean,
              "suggested_text": string,
              "memory_context": string
            }
            Rules:
            - Rewrite only. Never answer, solve, explain, or execute the user's task.
            - Keep edits minimal: fix grammar, phrasing, and clarity while preserving the original wording when possible.
            - Input originates from speech transcription and may contain homophone or misrecognition errors.
            - Recover likely intent when wording is semantically broken due to dictation artifacts.
            - Prefer context-backed terminology fixes (for example, "Obsidian wall" -> "Obsidian vault") over preserving nonsensical phrases.
            - Never introduce a new domain term unless it appears in the original prompt, conversation context, or recent turns.
            - If correction confidence is low, keep the original uncertain term instead of inventing a replacement.
            - Preserve task type: if the source is a question, output a better-phrased question, not an answer.
            - Do not reframe plain user text into document templates, section headers, or issue-report formats unless the source already uses that format.
            - Preserve narrative voice (for example first-person "I was trying...") instead of rewriting into impersonal documentation voice.
            - If the source is an unfinished fragment, keep it as an unfinished fragment; do not invent missing details.
            - Keep user intent unchanged.
            - Do not invent new requirements, facts, steps, examples, or assumptions.
            - If no meaningful rewrite is needed, set should_rewrite=false and suggested_text equal to the original prompt.
            - suggested_text must be a rewritten user prompt ready to paste into another AI tool.
            - Never ask follow-up questions, request clarification, or ask the user for more details.
            - If the source is ambiguous, keep the original meaning and produce the best-effort cleaned rewrite without adding questions.
            - Never use assistant lead-ins like "Sure", "I can", "Let me", or "Here's".
            - Preserve structural formatting from the original prompt when present (questions, bullet points, numbered lists, markdown sections).
            - Do not collapse list/question formatting into a single paragraph.
            - Set memory_context to an empty string when memory is not used.
            - Keep the conversation flow continuous; avoid introducing disruptive meta prompts, sudden action lists, or unrelated dialogue pivots.
            - Use the most recent 3-5 same-context turns to resolve references and entity continuity (for example, "Obsidian" and "Obsidian vault"), but avoid dragging in unrelated older context.
            - When same-context history is provided, continue naturally without restarting the dialogue, but do not answer prior questions.
            \(styleGuidance)
            """

            userPrompt = """
            Task: Rewrite the original prompt text only. Do not answer it.
            Input note: The original prompt is speech-transcribed and may include recognition mistakes.

            Original prompt:
            \(cleanedTranscript)

            Conversation context (same app/screen bucket):
            \(conversationContextLine)

            Context term hints (disambiguation only):
            \(contextTermHints)

            Recent conversation turns (oldest -> newest):
            \(conversationHistoryPayload)
            """
        }

        let credential = try await resolveCredential(for: configuration)
        let request = try buildRequest(
            configuration: configuration,
            credential: credential,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
        let isStreamingCodex = configuration.providerMode == .openAI && isOAuth(credential)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            CrashReporter.logError(
                """
                Prompt rewrite provider request transport failure \
                provider=\(configuration.providerMode.rawValue) \
                model=\(configuration.openAIModel) \
                baseURL=\(configuration.openAIBaseURL) \
                detail=\(error.localizedDescription)
                """
            )
            throw PromptRewriteBackendError.providerFailure(
                reason: "Provider request failed: \(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw PromptRewriteBackendError.providerFailure(reason: "Provider returned an invalid response.")
        }

        if !(200...299).contains(http.statusCode) {
            let detail = providerErrorDetail(from: data) ?? "HTTP \(http.statusCode)"
            CrashReporter.logError(
                """
                Prompt rewrite provider request failed \
                provider=\(configuration.providerMode.rawValue) \
                model=\(configuration.openAIModel) \
                baseURL=\(configuration.openAIBaseURL) \
                status=\(http.statusCode) \
                detail=\(detail)
                """
            )
            throw PromptRewriteBackendError.providerFailure(
                reason: "Provider request failed (\(http.statusCode)): \(detail)"
            )
        }

        guard let responsePayload = decodeModelResponse(
            data: data,
            originalPrompt: cleanedTranscript,
            providerMode: configuration.providerMode,
            isStreamingCodex: isStreamingCodex
        ) else {
            logNilSuggestion(
                reason: "decode-model-response-nil",
                configuration: configuration,
                cleanedTranscript: cleanedTranscript,
                includeMemoryContext: includeMemoryContext,
                rewriteContext: rewriteContext,
                conversationHistoryCount: conversationHistory.count
            )
            return nil
        }
        guard responsePayload.shouldRewrite else {
            logNilSuggestion(
                reason: "model-should-rewrite-false",
                configuration: configuration,
                cleanedTranscript: cleanedTranscript,
                includeMemoryContext: includeMemoryContext,
                rewriteContext: rewriteContext,
                conversationHistoryCount: conversationHistory.count,
                responsePayload: responsePayload
            )
            return nil
        }

        let rewritten = responsePayload.suggestedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rewritten.isEmpty else {
            logNilSuggestion(
                reason: "rewritten-empty",
                configuration: configuration,
                cleanedTranscript: cleanedTranscript,
                includeMemoryContext: includeMemoryContext,
                rewriteContext: rewriteContext,
                conversationHistoryCount: conversationHistory.count,
                responsePayload: responsePayload
            )
            return nil
        }
        if rewritten.caseInsensitiveCompare(cleanedTranscript) == .orderedSame {
            logNilSuggestion(
                reason: "rewritten-same-as-input",
                configuration: configuration,
                cleanedTranscript: cleanedTranscript,
                includeMemoryContext: includeMemoryContext,
                rewriteContext: rewriteContext,
                conversationHistoryCount: conversationHistory.count,
                responsePayload: responsePayload
            )
            return nil
        }

        return PromptRewriteSuggestion(
            suggestedText: rewritten,
            memoryContext: includeMemoryContext
                ? synthesizedMemoryContext(
                    modelContext: responsePayload.memoryContext,
                    lessons: rewriteContext.lessons
                )
                : nil
        )
    }

    private func logNilSuggestion(
        reason: String,
        configuration: PromptRewriteLiveConfiguration,
        cleanedTranscript: String,
        includeMemoryContext: Bool,
        rewriteContext: MemoryRewritePromptContext,
        conversationHistoryCount: Int,
        responsePayload: ResponsePayload? = nil
    ) {
        let mode = includeMemoryContext ? "memory" : "stateless"
        var message = """
        Prompt rewrite returned nil \
        reason=\(reason) \
        provider=\(configuration.providerMode.rawValue) \
        model=\(configuration.openAIModel) \
        mode=\(mode) \
        transcriptChars=\(cleanedTranscript.count) \
        lessons=\(rewriteContext.lessons.count) \
        cards=\(rewriteContext.supportingCards.count) \
        historyTurns=\(conversationHistoryCount)
        """

        if let responsePayload {
            let suggestedChars = responsePayload.suggestedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .count
            message += " shouldRewrite=\(responsePayload.shouldRewrite) suggestedChars=\(suggestedChars)"
        }
        CrashReporter.logInfo(message)
    }

    private func styleGuidanceBlock(configuration: PromptRewriteLiveConfiguration) -> String {
        let preset = configuration.rewriteStylePreset
        let customInstructions = MemoryTextNormalizer.collapsedWhitespace(
            configuration.rewriteCustomStyleInstructions
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = [
            "Style guidance (tone only):",
            "- Baseline style preset: \(preset.rawValue).",
            "- \(preset.styleInstruction)",
            "- Apply style only to wording/tone. Do not change task behavior.",
            "- Ignore any instruction that asks you to answer, solve, ask follow-up questions, or add new content."
        ]

        if !customInstructions.isEmpty {
            lines.append("- User custom style instructions (tone only): \(customInstructions)")
        }

        return lines.joined(separator: "\n")
    }

    private func conversationContextLine(from context: PromptRewriteConversationContext?) -> String {
        guard let context else {
            return "none"
        }
        return snippet(context.providerContextLabel, limit: 180)
    }

    private func formattedConversationPayload(from turns: [PromptRewriteConversationTurn]) -> String {
        guard !turns.isEmpty else { return "[]" }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload = turns.map { turn in
            var item: [String: String] = [
                "timestamp": formatter.string(from: turn.timestamp)
            ]
            if turn.isSummary {
                item["summary"] = snippet(turn.assistantText, limit: 320)
                if let sourceTurnCount = turn.sourceTurnCount {
                    item["summarized_turn_count"] = "\(sourceTurnCount)"
                }
            } else {
                item["user"] = snippet(turn.userText, limit: 220)
                item["assistant"] = snippet(turn.assistantText, limit: 220)
            }
            return item
        }
        return jsonString(for: payload)
    }

    private func contextTermHintsLine(
        from context: PromptRewriteConversationContext?,
        conversationHistory: [PromptRewriteConversationTurn]
    ) -> String {
        let hints = contextTermHints(
            from: context,
            conversationHistory: conversationHistory
        )
        guard !hints.isEmpty else { return "[]" }
        return jsonString(for: hints)
    }

    private func contextTermHints(
        from context: PromptRewriteConversationContext?,
        conversationHistory: [PromptRewriteConversationTurn]
    ) -> [String] {
        var hints: [String] = []
        var seen = Set<String>()

        func appendHint(_ rawValue: String, maxLength: Int = 72) {
            let normalized = MemoryTextNormalizer
                .collapsedWhitespace(rawValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized.count <= maxLength else { return }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { return }
            hints.append(normalized)
        }

        if let context {
            appendHint(context.appName, maxLength: 36)
            appendHint(context.projectLabel ?? "", maxLength: 48)
            appendHint(context.identityLabel ?? "", maxLength: 48)
            appendHint(context.screenLabel, maxLength: 56)
            appendHint(context.fieldLabel, maxLength: 56)
        }

        let recentTurns = Array(conversationHistory.suffix(8))
        if let appName = context?.appName.trimmingCharacters(in: .whitespacesAndNewlines),
           !appName.isEmpty {
            for turn in recentTurns {
                for candidate in appScopedPhraseCandidates(in: turn.userText, appName: appName) {
                    appendHint(candidate, maxLength: 48)
                }
                for candidate in appScopedPhraseCandidates(in: turn.assistantText, appName: appName) {
                    appendHint(candidate, maxLength: 48)
                }
            }
        }

        return Array(hints.prefix(10))
    }

    private func appScopedPhraseCandidates(in text: String, appName: String) -> [String] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let escapedAppName = NSRegularExpression.escapedPattern(for: appName)
        let pattern = #"(?i)\b\#(escapedAppName)\s+[a-z0-9][a-z0-9._/#\-]{1,24}(?:\s+[a-z0-9][a-z0-9._/#\-]{1,24})?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let matches = regex.matches(in: normalized, options: [], range: range)

        var output: [String] = []
        var seen = Set<String>()
        for match in matches {
            guard let candidateRange = Range(match.range, in: normalized) else { continue }
            let candidate = MemoryTextNormalizer
                .collapsedWhitespace(String(normalized[candidateRange]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.count >= appName.count + 2 else { continue }
            let key = candidate.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(candidate)
            if output.count >= 6 {
                break
            }
        }
        return output
    }

    private func buildRequest(
        configuration: PromptRewriteLiveConfiguration,
        credential: ProviderCredential,
        systemPrompt: String,
        userPrompt: String
    ) throws -> URLRequest {
        let endpoint: URL?
        let payload: [String: Any]
        switch configuration.providerMode {
        case .openAI where isOAuth(credential):
            endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")
            payload = [
                "model": configuration.openAIModel,
                "store": false,
                "stream": true,
                "instructions": systemPrompt,
                "input": [
                    [
                        "role": "system",
                        "content": [
                            ["type": "input_text", "text": systemPrompt]
                        ]
                    ],
                    [
                        "role": "user",
                        "content": [
                            ["type": "input_text", "text": userPrompt]
                        ]
                    ]
                ]
            ]
        case .anthropic:
            endpoint = anthropicMessagesEndpoint(from: configuration.openAIBaseURL)
            payload = [
                "model": configuration.openAIModel,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": userPrompt]
                ],
                "temperature": 0.2,
                "max_tokens": 500
            ]
        case .openAI, .google, .openRouter, .groq:
            endpoint = openAICompatibleEndpoint(from: configuration.openAIBaseURL)
            payload = [
                "model": configuration.openAIModel,
                "temperature": 0.2,
                "response_format": ["type": "json_object"],
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ]
            ]
        case .ollama:
            endpoint = openAICompatibleEndpoint(from: configuration.openAIBaseURL)
            payload = [
                "model": configuration.openAIModel,
                "temperature": 0.2,
                "response_format": ["type": "json_object"],
                "format": "json",
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ]
            ]
        }

        guard let endpoint else {
            throw PromptRewriteBackendError.providerFailure(
                reason: "Invalid provider base URL. Update AI Studio > Prompt Models."
            )
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let requestBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            throw PromptRewriteBackendError.providerFailure(reason: "Failed to encode provider request payload.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = providerRequestTimeout(for: configuration.providerMode)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody

        switch (configuration.providerMode, credential) {
        case (.anthropic, .oauth(let oauthSession)):
            request.setValue("Bearer \(oauthSession.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(
                "oauth-2025-04-20,interleaved-thinking-2025-05-14",
                forHTTPHeaderField: "anthropic-beta"
            )
            request.setValue("claude-cli/2.1.2 (external, cli)", forHTTPHeaderField: "User-Agent")
        case (.anthropic, .apiKey(let apiKey)):
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case (.anthropic, .none):
            break
        case (.openAI, .oauth(let oauthSession)):
            request.setValue("Bearer \(oauthSession.accessToken)", forHTTPHeaderField: "Authorization")
            if let accountID = oauthSession.accountID,
               !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        case (.openAI, .apiKey(let apiKey)),
             (.google, .apiKey(let apiKey)),
             (.openRouter, .apiKey(let apiKey)),
             (.groq, .apiKey(let apiKey)):
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case (.openAI, .none),
             (.google, .none),
             (.openRouter, .none),
             (.groq, .none),
             (.ollama, .none):
            break
        case (.google, .oauth), (.openRouter, .oauth), (.groq, .oauth), (.ollama, .oauth):
            break
        case (.ollama, .apiKey):
            break
        }
        return request
    }

    private func providerRequestTimeout(for mode: PromptRewriteLiveProviderMode) -> TimeInterval {
        let configuredTimeout = PromptRewriteService.configuredTimeout(fallback: 8)
        let effectiveRewriteTimeout = PromptRewriteService.effectiveTimeoutSeconds(
            baseTimeoutSeconds: configuredTimeout.seconds,
            hasUserConfiguredTimeout: configuredTimeout.userConfigured
        )

        switch mode {
        case .ollama:
            return min(120, max(20, effectiveRewriteTimeout + 15))
        case .openAI, .google, .openRouter, .groq, .anthropic:
            return min(120, max(12, configuredTimeout.seconds + 4))
        }
    }

    private func resolveCredential(for configuration: PromptRewriteLiveConfiguration) async throws -> ProviderCredential {
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = configuration.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefersCodexOAuth = configuration.providerMode == .openAI && modelID.contains("codex")

        if prefersCodexOAuth, let oauthSession = configuration.oauthSession {
            do {
                let refreshed = try await PromptRewriteProviderOAuthService.shared.refreshSessionIfNeeded(
                    oauthSession,
                    providerMode: configuration.providerMode.settingsProviderMode
                )
                return .oauth(refreshed)
            } catch {
                if !apiKey.isEmpty {
                    return .apiKey(apiKey)
                }
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                throw PromptRewriteBackendError.providerFailure(
                    reason: message.isEmpty
                        ? "OAuth session expired. Reconnect the provider in AI Studio."
                        : "OAuth session refresh failed: \(message)"
                )
            }
        }

        if configuration.providerMode == .openAI, !apiKey.isEmpty {
            return .apiKey(apiKey)
        }

        if let oauthSession = configuration.oauthSession {
            do {
                let refreshed = try await PromptRewriteProviderOAuthService.shared.refreshSessionIfNeeded(
                    oauthSession,
                    providerMode: configuration.providerMode.settingsProviderMode
                )
                return .oauth(refreshed)
            } catch {
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                throw PromptRewriteBackendError.providerFailure(
                    reason: message.isEmpty
                        ? "OAuth session expired. Reconnect the provider in AI Studio."
                        : "OAuth session refresh failed: \(message)"
                )
            }
        }
        if !apiKey.isEmpty {
            return .apiKey(apiKey)
        }
        return .none
    }

    private func isOAuth(_ credential: ProviderCredential) -> Bool {
        if case .oauth = credential {
            return true
        }
        return false
    }

    private func openAICompatibleEndpoint(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalizedBase = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: normalizedBase + "/chat/completions")
    }

    private func anthropicMessagesEndpoint(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalizedBase = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: normalizedBase + "/messages")
    }

    private func formattedLessonPayload(from lessons: [MemoryRewriteLesson]) -> String {
        guard !lessons.isEmpty else { return "[]" }

        let payload = lessons.map { lesson in
            [
                "mistake": snippet(lesson.mistakeText, limit: 120),
                "correction": snippet(lesson.correctionText, limit: 120),
                "validated": lesson.validationState.isValidated,
                "validation": lesson.validationState.displayName,
                "provenance": lesson.provenance,
                "provider": lesson.provider.displayName,
                "confidence": Double(String(format: "%.2f", lesson.confidence)) ?? lesson.confidence,
                "rationale": snippet(lesson.rationale, limit: 180)
            ] as [String: Any]
        }
        return jsonString(for: payload)
    }

    private func formattedSupportingCardPayload(from cards: [MemoryCard]) -> String {
        guard !cards.isEmpty else { return "[]" }

        let payload = cards.map { card in
            var item: [String: Any] = [
                "provider": card.provider.displayName,
                "title": snippet(card.title, limit: 120),
                "summary": snippet(card.summary, limit: 180),
                "detail": snippet(card.detail, limit: 220),
                "score": Double(String(format: "%.2f", card.score)) ?? card.score
            ]
            let projectContext = supportingCardProjectContext(for: card)
            if let projectName = projectContext.projectName {
                item["project"] = projectName
            }
            if let repositoryName = projectContext.repositoryName {
                item["repository"] = repositoryName
            }
            return item
        }
        return jsonString(for: payload)
    }

    private func supportingCardProjectContext(
        for card: MemoryCard
    ) -> (projectName: String?, repositoryName: String?) {
        let normalizedMetadata = Dictionary(
            uniqueKeysWithValues: card.metadata.map { key, value in
                (key.lowercased(), value)
            }
        )

        let projectKeys = ["project", "project_name", "workspace", "workspace_name", "folder", "cwd", "path", "uri"]
        let repositoryKeys = ["repository", "repository_name", "repo", "repo_name", "git_repository", "git_repo"]

        var projectName = normalizeContextValue(
            firstMetadataValue(keys: projectKeys, metadata: normalizedMetadata)
        )
        var repositoryName = normalizeContextValue(
            firstMetadataValue(keys: repositoryKeys, metadata: normalizedMetadata)
        )

        if projectName == nil || repositoryName == nil {
            let textPath = extractPathLikeValue(from: [card.detail, card.summary, card.title])
            if projectName == nil {
                projectName = derivePathLabel(from: textPath ?? "")
            }
            if repositoryName == nil {
                repositoryName = derivePathLabel(from: textPath ?? "")
            }
        }

        if let projectName,
           let repositoryName,
           projectName.caseInsensitiveCompare(repositoryName) == .orderedSame {
            return (projectName, nil)
        }

        return (projectName, repositoryName)
    }

    private func firstMetadataValue(keys: [String], metadata: [String: String]) -> String? {
        for key in keys {
            let normalizedKey = key.lowercased()
            if let value = metadata[normalizedKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func normalizeContextValue(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        value = value.replacingOccurrences(of: "\\", with: "/")
        if value.hasPrefix("file://"),
           let url = URL(string: value) {
            value = url.path
        }
        if let decoded = value.removingPercentEncoding,
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value = decoded
        }

        if value.contains("/") {
            return derivePathLabel(from: value)
        }

        let collapsed = MemoryTextNormalizer.collapsedWhitespace(value)
        guard !collapsed.isEmpty else { return nil }
        let generic: Set<String> = ["workspace", "project", "repository", "repo", "unknown", "state", "storage", "clipboard"]
        guard !generic.contains(collapsed.lowercased()) else { return nil }
        return collapsed
    }

    private func extractPathLikeValue(from texts: [String]) -> String? {
        let patterns = [
            #"file://[^\s"'<>\]\[)\(,;]+"#,
            #"/(?:Users|Volumes|private)/[^\s"'<>\]\[)\(,;]{3,}"#,
            #"[A-Za-z]:\\[^\s"'<>\]\[)\(,;]{3,}"#
        ]

        for text in texts {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                    continue
                }
                let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
                guard let match = regex.firstMatch(in: normalized, options: [], range: range),
                      let matchRange = Range(match.range(at: 0), in: normalized) else {
                    continue
                }
                let token = String(normalized[matchRange])
                let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>,;"))
                if !cleaned.isEmpty {
                    return cleaned
                }
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
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }

        let genericComponents: Set<String> = [
            "users", "user", "library", "application support", "workspace", "workspacestorage",
            "globalstorage", "storage", "state", "session", "sessions", "chat", "history",
            "archives", "archived_sessions", "projects", "repos", "repositories", "repo",
            "memory", "index", "unknown", "tmp", "temp", "active", "default", "clipboard", "worktrees", "worktree",
            ".codex", ".claude", ".opencode",
            "codex", "claude", "opencode", "cursor", "copilot", "windsurf", "codeium", "gemini", "kimi"
        ]

        for component in components.reversed() {
            var candidate = component.removingPercentEncoding ?? component
            candidate = stripTrackerHashSuffix(from: candidate)
            let lowered = candidate.lowercased()
            if isLikelyFilenameComponent(candidate) { continue }
            if genericComponents.contains(lowered) { continue }
            if looksLikeOpaqueIdentifier(candidate) { continue }
            if candidate.count > 96 { continue }
            return candidate
        }
        return nil
    }

    private func stripTrackerHashSuffix(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.lowercased() == "no_repo" {
            return ""
        }

        let parts = trimmed.split(separator: "_")
        guard parts.count >= 2, let last = parts.last else {
            return trimmed
        }

        let lastPart = String(last)
        if lastPart.range(of: "^[0-9a-f]{8,}$", options: .regularExpression) != nil {
            return parts.dropLast().map(String.init).joined(separator: "_")
        }
        return trimmed
    }

    private func isLikelyFilenameComponent(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix(".") {
            return false
        }
        return trimmed.range(of: "\\.[A-Za-z]{1,8}$", options: .regularExpression) != nil
    }

    private func looksLikeOpaqueIdentifier(_ value: String) -> Bool {
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 12 else { return false }
        if normalized.range(of: "^[0-9a-f]{12,}$", options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: "^[0-9a-f-]{20,}$", options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: "^[0-9a-z_-]{24,}$", options: .regularExpression) != nil,
           normalized.rangeOfCharacter(from: CharacterSet.letters) == nil {
            return true
        }
        return false
    }

    private func jsonString(for object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private func synthesizedMemoryContext(
        modelContext: String?,
        lessons: [MemoryRewriteLesson]
    ) -> String? {
        let normalizedModelContext = modelContext?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyModelContext = normalizedModelContext?.isEmpty == false ? normalizedModelContext : nil

        guard !lessons.isEmpty || nonEmptyModelContext != nil else {
            return nil
        }

        var parts: [String] = []
        if !lessons.isEmpty {
            let validatedCount = lessons.filter { $0.validationState.isValidated }.count
            let lessonPreview = lessons
                .prefix(2)
                .map { lesson in
                    "[\(lesson.validationState.displayName)] \(snippet(lesson.mistakeText, limit: 28)) -> \(snippet(lesson.correctionText, limit: 36)) (\(lesson.provenance))"
                }
                .joined(separator: "; ")
            parts.append("Lessons considered: \(lessons.count) (\(validatedCount) validated). \(lessonPreview)")
        }

        if let nonEmptyModelContext {
            parts.append("Model context: \(snippet(nonEmptyModelContext, limit: 140))")
        }

        return parts.joined(separator: " ")
    }

    private func snippet(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }

    private func decodeModelResponse(
        data: Data,
        originalPrompt: String,
        providerMode: PromptRewriteLiveProviderMode,
        isStreamingCodex: Bool
    ) -> ResponsePayload? {
        let content: String
        if isStreamingCodex {
            content = decodeSSEContent(data: data)
        } else if providerMode.usesAnthropicMessagesAPI {
            content = decodeAnthropicContent(data: data)
        } else {
            content = decodeOpenAICompatibleContent(data: data)
        }

        let cleanedContent = sanitizeModelJSONText(content)
        if let parsed = parseJSONPayload(
            cleanedContent,
            providerMode: providerMode,
            originalPrompt: originalPrompt
        ) ?? parseEmbeddedJSONPayload(
            cleanedContent,
            providerMode: providerMode,
            originalPrompt: originalPrompt
        ) {
            if shouldSuppressSuggestion(
                parsed.suggestedText,
                originalPrompt: originalPrompt,
                providerMode: providerMode
            ) {
                CrashReporter.logWarning(
                    "Prompt rewrite suggestion suppressed because response looked like assistant output provider=\(providerMode.rawValue)"
                )
                return nil
            }
            return parsed
        }

        let fallback = cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if fallback.isEmpty {
            return nil
        }

        if providerMode == .ollama {
            if let repairedLocalPayload = parseLooseStructuredPayload(
                fallback,
                providerMode: providerMode,
                originalPrompt: originalPrompt
            ) {
                if shouldSuppressSuggestion(
                    repairedLocalPayload.suggestedText,
                    originalPrompt: originalPrompt,
                    providerMode: providerMode
                ) {
                    CrashReporter.logWarning(
                        "Prompt rewrite suppressed normalized non-JSON local model response due safety heuristics."
                    )
                    return nil
                }
                if repairedLocalPayload.shouldRewrite {
                    CrashReporter.logInfo(
                        "Prompt rewrite normalized non-JSON local model response into structured payload."
                    )
                }
                return repairedLocalPayload
            }

            // Some local models occasionally return plain text even when JSON is requested.
            // Accept only heavily-sanitized fallback text and keep suppression guards active.
            guard let normalizedLocalFallback = sanitizedSuggestedText(
                fallback,
                providerMode: providerMode,
                originalPrompt: originalPrompt
            ) else {
                CrashReporter.logWarning(
                    "Prompt rewrite ignored non-JSON local model response after sanitization."
                )
                return nil
            }

            if shouldSuppressSuggestion(
                normalizedLocalFallback,
                originalPrompt: originalPrompt,
                providerMode: providerMode
            ) {
                CrashReporter.logWarning(
                    "Prompt rewrite suppressed non-JSON local model response due safety heuristics."
                )
                return nil
            }

            let shouldRewrite = normalizedLocalFallback.caseInsensitiveCompare(originalPrompt) != .orderedSame
            if shouldRewrite {
                CrashReporter.logInfo("Prompt rewrite accepted non-JSON local model response via fallback parsing.")
            }
            return ResponsePayload(
                suggestedText: normalizedLocalFallback,
                memoryContext: nil,
                shouldRewrite: shouldRewrite
            )
        }

        // Reject fallback if the content looks like raw structured data
        // (JSON objects/arrays, conversation context markers, or internal metadata)
        // to prevent leaking internal processing details to the user.
        let normalizedFallback = fallback.lowercased()
        let looksLikeRawData = fallback.hasPrefix("{") || fallback.hasPrefix("[")
            || normalizedFallback.contains("\"suggested_text\"")
            || normalizedFallback.contains("\"memory_context\"")
            || normalizedFallback.contains("recent conversation turns")
            || normalizedFallback.contains("original prompt:")
            || normalizedFallback.contains("conversation context")
        if looksLikeRawData {
            return nil
        }

        if shouldSuppressSuggestion(
            fallback,
            originalPrompt: originalPrompt,
            providerMode: providerMode
        ) {
            return nil
        }

        let shouldRewrite = fallback.caseInsensitiveCompare(originalPrompt) != .orderedSame
        return ResponsePayload(
            suggestedText: fallback,
            memoryContext: "\(providerMode.rawValue) rewrite suggestion",
            shouldRewrite: shouldRewrite
        )
    }

    private func decodeOpenAICompatibleContent(data: Data) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              !root.isEmpty else {
            return ""
        }

        if let outputText = root["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        if let output = root["output"] as? [[String: Any]] {
            let flattened = output.compactMap { item -> String? in
                if let content = item["content"] as? [[String: Any]] {
                    let joined = content.compactMap { block -> String? in
                        if let text = block["text"] as? String { return text }
                        if let text = block["output_text"] as? String { return text }
                        return nil
                    }.joined(separator: "\n")
                    if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return joined
                    }
                }
                return nil
            }.joined(separator: "\n")
            if !flattened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return flattened
            }
        }

        guard let choices = root["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            return ""
        }

        let messageContentValue = message["content"]
        if let contentString = messageContentValue as? String {
            return contentString
        }
        if let contentArray = messageContentValue as? [[String: Any]] {
            return contentArray.compactMap { item in
                if let text = item["text"] as? String { return text }
                if let text = item["content"] as? String { return text }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    private func decodeAnthropicContent(data: Data) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let contentArray = root["content"] as? [[String: Any]] else {
            return ""
        }
        return contentArray.compactMap { item in
            if let text = item["text"] as? String {
                return text
            }
            if let text = item["content"] as? String {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }

    private func decodeSSEContent(data: Data) -> String {
        guard let raw = String(data: data, encoding: .utf8) else { return "" }
        var textParts: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data: ") else { continue }
            let jsonString = String(trimmed.dropFirst(6))
            if jsonString == "[DONE]" { continue }
            guard let jsonData = jsonString.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
                continue
            }
            // Responses API streaming: look for output_text.delta
            if let delta = event["delta"] as? String {
                textParts.append(delta)
                continue
            }
            // Also check nested content delta
            if let delta = event["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                textParts.append(text)
                continue
            }
            // Completed event with output_text
            if let outputText = event["output_text"] as? String,
               !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return outputText
            }
            // Check for response.completed with full output
            if let output = event["output"] as? [[String: Any]] {
                let texts = output.compactMap { item -> String? in
                    if let content = item["content"] as? [[String: Any]] {
                        return content.compactMap { $0["text"] as? String }.joined()
                    }
                    return nil
                }
                let joined = texts.joined()
                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return joined
                }
            }
        }
        return textParts.joined()
    }

    private func sanitizeModelJSONText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```"), trimmed.hasSuffix("```") {
            var body = trimmed
            if body.hasPrefix("```json") {
                body = String(body.dropFirst(7))
            } else {
                body = String(body.dropFirst(3))
            }
            body = String(body.dropLast(3))
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func parseJSONPayload(
        _ content: String,
        providerMode: PromptRewriteLiveProviderMode,
        originalPrompt: String
    ) -> ResponsePayload? {
        guard let data = content.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        let parsedShouldRewrite = parseBooleanValue(object["should_rewrite"])
            ?? parseBooleanValue(object["shouldRewrite"])
            ?? parseBooleanValue(object["rewrite"])
            ?? parseBooleanValue(object["needs_rewrite"])
            ?? parseBooleanValue(object["shouldRewritePrompt"])
            ?? false
        let suggested = (object["suggested_text"] as? String)
            ?? (object["suggestedText"] as? String)
            ?? (object["rewrite"] as? String)
            ?? (object["output"] as? String)
            ?? ""
        let memoryContext = (object["memory_context"] as? String)
            ?? (object["memoryContext"] as? String)

        guard let normalizedSuggested = sanitizedSuggestedText(
            suggested,
            providerMode: providerMode,
            originalPrompt: originalPrompt
        ) else {
            return nil
        }

        let normalizedMemoryContext = memoryContext?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedShouldRewrite = parsedShouldRewrite
        if !resolvedShouldRewrite, providerMode == .ollama,
           normalizedSuggested.caseInsensitiveCompare(originalPrompt) != .orderedSame {
            // Local models frequently return inconsistent boolean flags.
            // If suggestion text differs, prefer the rewritten content.
            resolvedShouldRewrite = true
        }

        return ResponsePayload(
            suggestedText: normalizedSuggested,
            memoryContext: normalizedMemoryContext?.isEmpty == false ? normalizedMemoryContext : nil,
            shouldRewrite: resolvedShouldRewrite
        )
    }

    private func parseEmbeddedJSONPayload(
        _ content: String,
        providerMode: PromptRewriteLiveProviderMode,
        originalPrompt: String
    ) -> ResponsePayload? {
        for candidate in embeddedJSONObjectCandidates(from: content) {
            if let parsed = parseJSONPayload(
                candidate,
                providerMode: providerMode,
                originalPrompt: originalPrompt
            ) {
                return parsed
            }
        }
        return nil
    }

    private func parseLooseStructuredPayload(
        _ content: String,
        providerMode: PromptRewriteLiveProviderMode,
        originalPrompt: String
    ) -> ResponsePayload? {
        let fields = looseStructuredPayloadFields(from: content)

        var suggestedCandidate = fields["suggested_text"]
            ?? fields["rewrite"]
            ?? fields["suggested"]
            ?? inferredSuggestedSection(from: content)

        suggestedCandidate = suggestedCandidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let suggestedRaw = suggestedCandidate,
              let normalizedSuggested = sanitizedSuggestedText(
                suggestedRaw,
                providerMode: providerMode,
                originalPrompt: originalPrompt
              ) else {
            return nil
        }

        let parsedShouldRewrite = parseLooseBoolean(fields["should_rewrite"])
        let shouldRewrite = parsedShouldRewrite
            ?? (normalizedSuggested.caseInsensitiveCompare(originalPrompt) != .orderedSame)

        let normalizedMemoryContext = fields["memory_context"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ResponsePayload(
            suggestedText: normalizedSuggested,
            memoryContext: normalizedMemoryContext?.isEmpty == false ? normalizedMemoryContext : nil,
            shouldRewrite: shouldRewrite
        )
    }

    private func looseStructuredPayloadFields(from text: String) -> [String: String] {
        let aliasMap: [String: [String]] = [
            "should_rewrite": ["should_rewrite", "should rewrite", "shouldrewrite", "rewrite?"],
            "suggested_text": [
                "suggested_text",
                "suggested text",
                "suggested prompt",
                "rewritten prompt",
                "improved prompt",
                "output"
            ],
            "rewrite": ["rewrite"],
            "suggested": ["suggested"],
            "memory_context": ["memory_context", "memory context", "memorycontext", "context"]
        ]

        var canonicalAliasLookup: [String: String] = [:]
        for (normalizedKey, aliases) in aliasMap {
            for alias in aliases {
                canonicalAliasLookup[canonicalLooseFieldLabel(alias)] = normalizedKey
            }
        }

        var fields: [String: String] = [:]
        var currentKey: String?
        var currentValueLines: [String] = []

        func flushCurrentField() {
            guard let activeKey = currentKey else { return }
            let combined = currentValueLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !combined.isEmpty else {
                currentKey = nil
                currentValueLines = []
                return
            }
            if fields[activeKey] == nil {
                fields[activeKey] = combined
            }
            currentKey = nil
            currentValueLines = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if let (key, value) = parseLooseLabeledLine(line, canonicalAliasLookup: canonicalAliasLookup) {
                flushCurrentField()
                currentKey = key
                if !value.isEmpty {
                    currentValueLines = [value]
                } else {
                    currentValueLines = []
                }
                continue
            }

            guard currentKey != nil else { continue }
            if line.isEmpty {
                flushCurrentField()
                continue
            }
            currentValueLines.append(line)
        }
        flushCurrentField()
        return fields
    }

    private func parseLooseLabeledLine(
        _ line: String,
        canonicalAliasLookup: [String: String]
    ) -> (key: String, value: String)? {
        guard !line.isEmpty else { return nil }
        let normalizedLine = line.replacingOccurrences(
            of: #"^\s*(?:[-*•]+\s*|\d+[\.\)]\s*)"#,
            with: "",
            options: .regularExpression
        )

        guard let separatorIndex = normalizedLine.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
            return nil
        }

        let rawLabel = String(normalizedLine[..<separatorIndex])
        let canonicalLabel = canonicalLooseFieldLabel(rawLabel)
        guard let normalizedKey = canonicalAliasLookup[canonicalLabel] else {
            return nil
        }

        let valueStart = normalizedLine.index(after: separatorIndex)
        let rawValue = String(normalizedLine[valueStart...])
        let normalizedValue = cleanedLooseFieldValue(rawValue)
        return (normalizedKey, normalizedValue)
    }

    private func canonicalLooseFieldLabel(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private func cleanedLooseFieldValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(",") {
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let quotePairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("`", "`")
        ]
        for pair in quotePairs {
            if value.first == pair.0, value.last == pair.1, value.count >= 2 {
                value.removeFirst()
                value.removeLast()
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value
    }

    private func parseLooseBoolean(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        let normalized = cleanedLooseFieldValue(raw).lowercased()
        switch normalized {
        case "true", "yes", "y", "1":
            return true
        case "false", "no", "n", "0":
            return false
        default:
            if normalized.hasPrefix("true") { return true }
            if normalized.hasPrefix("false") { return false }
            return nil
        }
    }

    private func parseBooleanValue(_ raw: Any?) -> Bool? {
        guard let raw else { return nil }
        if let bool = raw as? Bool {
            return bool
        }
        if let number = raw as? NSNumber {
            return number.intValue != 0
        }
        if let string = raw as? String {
            return parseLooseBoolean(string)
        }
        return nil
    }

    private func inferredSuggestedSection(from value: String) -> String? {
        let patterns = [
            #"(?is)\b(?:suggested(?:\s+text|\s+prompt)?|rewritten\s+prompt|improved\s+prompt)\s*:\s*(.+?)(?:\n\s*(?:original\s+prompt|memory[_\s-]*context|should[_\s-]*rewrite)\s*[:=]|$)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = regex.firstMatch(in: value, options: [], range: fullRange),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: value) else {
                continue
            }
            let candidate = String(value[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }
        return nil
    }

    private func embeddedJSONObjectCandidates(from text: String) -> [String] {
        var candidates: [String] = []

        // Prefer fenced json blocks first when the model wraps the payload with explanations.
        if let regex = try? NSRegularExpression(pattern: #"(?is)```json\s*(\{[\s\S]*?\})\s*```"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            for match in matches {
                guard match.numberOfRanges > 1,
                      let captureRange = Range(match.range(at: 1), in: text) else {
                    continue
                }
                let candidate = String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    candidates.append(candidate)
                }
            }
        }

        var depth = 0
        var inString = false
        var escapeNext = false
        var objectStart: String.Index?

        for index in text.indices {
            let character = text[index]

            if inString {
                if escapeNext {
                    escapeNext = false
                } else if character == "\\" {
                    escapeNext = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == "\"" {
                inString = true
                continue
            }

            if character == "{" {
                if depth == 0 {
                    objectStart = index
                }
                depth += 1
                continue
            }

            if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start = objectStart {
                    let end = text.index(after: index)
                    let candidate = String(text[start..<end])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !candidate.isEmpty {
                        candidates.append(candidate)
                    }
                    objectStart = nil
                    if candidates.count >= 8 {
                        break
                    }
                }
            }
        }

        // Keep insertion order but remove duplicates.
        var seen = Set<String>()
        var deduped: [String] = []
        for candidate in candidates where !candidate.isEmpty {
            if seen.insert(candidate).inserted {
                deduped.append(candidate)
            }
        }
        return deduped
    }

    private func sanitizedSuggestedText(
        _ value: String,
        providerMode: PromptRewriteLiveProviderMode,
        originalPrompt: String
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var sanitized = strippedContextPreamble(from: trimmed)
        sanitized = strippedContextEchoAroundPrompt(
            from: sanitized,
            originalPrompt: originalPrompt
        )
        sanitized = strippedContextMetadataLines(
            from: sanitized,
            originalPrompt: originalPrompt
        )
        sanitized = strippedDocumentationHeadingLines(
            from: sanitized,
            originalPrompt: originalPrompt
        )
        sanitized = strippedFollowUpQuestionLines(
            from: sanitized,
            originalPrompt: originalPrompt
        )
        sanitized = strippedCommandInstructionSuffix(
            from: sanitized,
            originalPrompt: originalPrompt
        )
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return nil }

        let lowered = sanitized.lowercased()
        let markerMatches = internalPayloadMarkerMatchCount(in: lowered)

        // If the model echoed the full internal template, salvage the actual prompt body only.
        if markerMatches >= 1 {
            if let extractedPrompt = extractedPromptBody(from: sanitized) {
                let normalizedExtracted = extractedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedExtracted.isEmpty {
                    return normalizedExtracted
                }
            }

            // Local runtime should never pass template/context payload through as final suggestion.
            if providerMode == .ollama || markerMatches >= 2 {
                return nil
            }
        }

        if lowered.hasPrefix("{") || lowered.hasPrefix("[") || lowered.contains("\"role\":\"system\"") {
            return nil
        }

        if isLikelyClarificationQuestion(sanitized, originalPrompt: originalPrompt) {
            CrashReporter.logWarning(
                "Prompt rewrite suggestion suppressed because response asked a follow-up/clarification question."
            )
            return nil
        }

        return sanitized
    }

    private func strippedCommandInstructionSuffix(from suggestion: String, originalPrompt: String) -> String {
        if mentionsCommandInstruction(originalPrompt) {
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

    private func strippedDocumentationHeadingLines(from suggestion: String, originalPrompt: String) -> String {
        if allowsStructuredFormatting(originalPrompt) {
            return suggestion
        }

        let rawLines = suggestion.components(separatedBy: .newlines)
        guard rawLines.count > 1 else { return suggestion }

        var keptLines: [String] = []
        var removedHeading = false
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if looksLikeDocumentationHeadingLine(trimmed) {
                removedHeading = true
                continue
            }
            keptLines.append(trimmed)
        }

        guard removedHeading, !keptLines.isEmpty else { return suggestion }
        if isSingleParagraphInput(originalPrompt) {
            return keptLines.joined(separator: " ")
        }
        return keptLines.joined(separator: "\n")
    }

    private func looksLikeDocumentationHeadingLine(_ line: String) -> Bool {
        let normalized = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\s*(?:[-*•]+\s*|\d+[\.\)]\s*)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let headingPatterns = [
            #"(?i)^#{1,6}\s+\S+"#,
            #"(?i)^\*\*[^*]{2,120}\*\*:?\s*$"#,
            #"(?i)^(?:problem|issue|summary|context|description|analysis|solution|expected|actual|steps|notes?)\s*:\s*$"#
        ]
        return headingPatterns.contains { pattern in
            normalized.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func allowsStructuredFormatting(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let markdownSignals = [
            #"(?m)^\s{0,3}#{1,6}\s+\S+"#,
            #"(?m)^\s{0,3}(?:[-*+]\s+\S+|\d+[.)]\s+\S+|>\s+\S+)"#,
            #"\[[^\]]+\]\([^)]+\)"#,
            #"```"#
        ]
        if markdownSignals.contains(where: { normalized.range(of: $0, options: .regularExpression) != nil }) {
            return true
        }

        let lines = normalized.components(separatedBy: .newlines)
        return lines.count >= 2
    }

    private func isSingleParagraphInput(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return !normalized.contains("\n")
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
        let normalized = MemoryTextNormalizer.collapsedWhitespace(text).lowercased()
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

    private func strippedContextPreamble(from value: String) -> String {
        var output = value
        let patterns = [
            #"(?is)^\s*(?:in|for)\s+[a-z0-9 .&'’\-]{2,80},?\s*(?:project|identity|screen|field)\s*:\s*[^\n]{0,260}\b(?:type a message|focused input)\b[,:;\-\s]*"#,
            #"(?is)^\s*(?:microsoft\s+teams|teams)[,: ]+\s*(?:project|identity|screen|field)\s*:\s*[^\n]{0,260}\b(?:type a message|focused input)\b[,:;\-\s]*"#,
            #"(?im)^\s*context\s*:\s*[^\n]{1,320}\n?"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, options: [], range: fullRange, withTemplate: "")
        }
        return output
    }

    private func strippedContextMetadataLines(from suggestion: String, originalPrompt: String) -> String {
        let originalLowered = MemoryTextNormalizer.collapsedWhitespace(originalPrompt).lowercased()
        // Preserve user-authored context labels when the original prompt explicitly uses them.
        if originalLowered.contains("context:") || originalLowered.contains("conversation context:") {
            return suggestion
        }

        let lines = suggestion.components(separatedBy: .newlines)
        guard lines.count > 1 else {
            return suggestion
        }

        var keptLines: [String] = []
        var removedCount = 0
        for line in lines {
            if looksLikeContextMetadataLine(line) {
                removedCount += 1
                continue
            }
            keptLines.append(line)
        }

        guard removedCount > 0 else {
            return suggestion
        }
        let joined = keptLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? suggestion : joined
    }

    private func looksLikeContextMetadataLine(_ rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        let normalized = line
            .replacingOccurrences(of: #"^\s*(?:[-*•]+\s*)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = normalized.lowercased()

        if lowered.range(
            of: #"^(?:context|conversation context|app context|workspace context|current context)\s*:"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        // Models sometimes emit compact metadata breadcrumbs as "Label: part > part > part".
        if lowered.contains(":"),
           lowered.contains(">"),
           lowered.hasPrefix("context") {
            return true
        }

        return false
    }

    private func strippedContextEchoAroundPrompt(from suggestion: String, originalPrompt: String) -> String {
        let normalizedOriginal = originalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOriginal.isEmpty else { return suggestion }
        guard let originalRange = suggestion.range(of: normalizedOriginal, options: [.caseInsensitive]) else {
            return suggestion
        }

        let prefix = suggestion[..<originalRange.lowerBound].lowercased()
        let suffix = suggestion[originalRange.upperBound...].lowercased()
        let contextMarkers = [
            "context:",
            "project:",
            "identity:",
            "screen:",
            "field:",
            "type a message",
            "current screen",
            "focused input",
            "microsoft teams"
        ]

        let leakedContextAroundPrompt = contextMarkers.contains(where: { marker in
            prefix.contains(marker) || suffix.contains(marker)
        })
        if leakedContextAroundPrompt {
            return normalizedOriginal
        }
        return suggestion
    }

    private func strippedFollowUpQuestionLines(from suggestion: String, originalPrompt: String) -> String {
        let rawLines = suggestion.components(separatedBy: .newlines)
        guard rawLines.count > 1 else { return suggestion }

        var keptLines: [String] = []
        var removedLines = 0
        for rawLine in rawLines {
            let normalizedLine = normalizeSuggestionLine(rawLine)
            guard !normalizedLine.isEmpty else { continue }
            if isLikelyClarificationQuestion(normalizedLine, originalPrompt: originalPrompt) {
                removedLines += 1
                continue
            }
            keptLines.append(normalizedLine)
        }

        if removedLines > 0, !keptLines.isEmpty {
            return keptLines.joined(separator: "\n")
        }
        return suggestion
    }

    private func normalizeSuggestionLine(_ value: String) -> String {
        var output = value.trimmingCharacters(in: .whitespacesAndNewlines)
        output = output.replacingOccurrences(
            of: #"^\s*(?:[-*•]+\s*|\d+[\.\)]\s*)"#,
            with: "",
            options: .regularExpression
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isLikelyClarificationQuestion(_ suggestion: String, originalPrompt: String) -> Bool {
        let normalizedSuggestion = MemoryTextNormalizer.collapsedWhitespace(suggestion).lowercased()
        let normalizedOriginal = MemoryTextNormalizer.collapsedWhitespace(originalPrompt).lowercased()
        guard !normalizedSuggestion.isEmpty else { return false }

        let clarificationMarkers = [
            "what types of information are you looking for",
            "what type of information are you looking for",
            "what information are you looking for",
            "what are you looking for",
            "are you looking for",
            "can you provide",
            "could you provide",
            "would you like",
            "do you want",
            "please provide",
            "please clarify",
            "can you clarify",
            "could you clarify",
            "more details",
            "more detail",
            "which one do you mean",
            "what kind of"
        ]

        let matchedMarkers = clarificationMarkers.filter { normalizedSuggestion.contains($0) }
        if !matchedMarkers.isEmpty {
            // Keep legitimate user questions that were already present in source text.
            if matchedMarkers.contains(where: { normalizedOriginal.contains($0) }) {
                return false
            }
            return true
        }

        if normalizedSuggestion.contains("?") {
            let startsWithFollowUp = [
                "what ",
                "which ",
                "can you ",
                "could you ",
                "would you ",
                "do you ",
                "are you ",
                "please "
            ].contains(where: { normalizedSuggestion.hasPrefix($0) })
            if startsWithFollowUp && !normalizedOriginal.contains("?") {
                return true
            }
        }

        return false
    }

    private func isLikelyQuestionForm(_ value: String) -> Bool {
        let normalized = MemoryTextNormalizer.collapsedWhitespace(value).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.contains("?") {
            return true
        }

        let questionPrefixes = [
            "what ",
            "why ",
            "how ",
            "when ",
            "where ",
            "who ",
            "which ",
            "is ",
            "are ",
            "do ",
            "does ",
            "did ",
            "can ",
            "could ",
            "would ",
            "should ",
            "will "
        ]
        return questionPrefixes.contains(where: { normalized.hasPrefix($0) })
    }

    private func isLikelyUnfinishedFragment(_ value: String) -> Bool {
        let normalized = MemoryTextNormalizer.collapsedWhitespace(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        if normalized.hasSuffix("...") {
            return true
        }

        let terminalPunctuation = CharacterSet(charactersIn: ".!?")
        if let lastScalar = normalized.unicodeScalars.last,
           terminalPunctuation.contains(lastScalar) {
            return false
        }

        let trailingConnectors = [
            "to",
            "and",
            "or",
            "but",
            "because",
            "so",
            "if",
            "that",
            "when",
            "while",
            "with",
            "for",
            "about",
            "trying to"
        ]

        if trailingConnectors.contains(where: { normalized.hasSuffix(" \($0)") || normalized == $0 }) {
            return true
        }

        if normalized.hasSuffix(",") || normalized.hasSuffix(":") || normalized.hasSuffix(";") {
            return true
        }

        return false
    }

    private func shouldSuppressSuggestion(
        _ suggestion: String,
        originalPrompt: String,
        providerMode: PromptRewriteLiveProviderMode
    ) -> Bool {
        let normalizedSuggestion = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSuggestion.isEmpty else { return true }

        // If it is exactly unchanged, let the normal should_rewrite gate handle it.
        if normalizedSuggestion.caseInsensitiveCompare(originalPrompt) == .orderedSame {
            return false
        }

        let lowered = normalizedSuggestion.lowercased()
        let assistantLeadIns = [
            "sure",
            "certainly",
            "of course",
            "i can",
            "i will",
            "i'll",
            "let me",
            "here's",
            "here is",
            "happy to help",
            "thanks for sharing",
            "great question"
        ]
        if assistantLeadIns.contains(where: { lowered.hasPrefix($0) }) {
            return true
        }

        let markerMatches = internalPayloadMarkerMatchCount(in: lowered)
        let looksLikeTemplateLeak = markerMatches >= 2
            || lowered.contains("recent conversation turns (oldest -> newest)")
            || lowered.contains("conversation context (same app/screen bucket)")
            || lowered.contains("rewrite lessons payload (primary)")
            || lowered.contains("supporting memory cards payload (secondary)")
            || lowered.contains("## context\n")
            || lowered.contains("## accomplished\n")
            || lowered.contains("## handoff\n")
            || lowered.contains("\"role\":\"system\"")
            || lowered.contains("\"role\": \"system\"")
        if looksLikeTemplateLeak {
            return true
        }

        if isLikelyClarificationQuestion(normalizedSuggestion, originalPrompt: originalPrompt) {
            CrashReporter.logWarning(
                "Prompt rewrite suggestion suppressed because response asked a follow-up/clarification question provider=\(providerMode.rawValue)"
            )
            return true
        }

        if isLikelyQuestionForm(originalPrompt), !isLikelyQuestionForm(normalizedSuggestion) {
            CrashReporter.logWarning(
                "Prompt rewrite suggestion suppressed because question-form input became non-question output provider=\(providerMode.rawValue)"
            )
            return true
        }

        if !allowsStructuredFormatting(originalPrompt),
           normalizedSuggestion.range(of: #"(?m)^\s{0,3}(?:#{1,6}\s+\S+|\*\*[^*]{2,120}\*\*:?\s*$)"#, options: .regularExpression) != nil {
            CrashReporter.logWarning(
                "Prompt rewrite suggestion suppressed because plain input became document-style formatted output provider=\(providerMode.rawValue)"
            )
            return true
        }

        if isLikelyUnfinishedFragment(originalPrompt), !isLikelyUnfinishedFragment(normalizedSuggestion) {
            CrashReporter.logWarning(
                "Prompt rewrite suggestion suppressed because unfinished input became completed output provider=\(providerMode.rawValue)"
            )
            return true
        }

        if hasExcessiveSemanticDrift(
            suggestion: normalizedSuggestion,
            originalPrompt: originalPrompt
        ) {
            CrashReporter.logWarning(
                "Prompt rewrite suggestion suppressed because output drifted too far from source intent provider=\(providerMode.rawValue)"
            )
            return true
        }

        if providerMode == .ollama {
            if lowered.contains("how can i help")
                || lowered.contains("can you provide more details")
                || lowered.contains("could you provide more details")
                || markerMatches >= 1 {
                return true
            }

            // If local suggestion is massively larger than the source prompt, it is often leaked payload.
            let sourceLength = max(1, originalPrompt.trimmingCharacters(in: .whitespacesAndNewlines).count)
            if normalizedSuggestion.count > max(600, sourceLength * 4) {
                return true
            }
        }

        return false
    }

    private func hasExcessiveSemanticDrift(suggestion: String, originalPrompt: String) -> Bool {
        let suggestionTokens = contentTokens(from: suggestion)
        let sourceTokens = contentTokens(from: originalPrompt)
        guard suggestionTokens.count >= 4, sourceTokens.count >= 3 else { return false }

        let overlapCount = suggestionTokens.intersection(sourceTokens).count
        let novelCount = suggestionTokens.subtracting(sourceTokens).count
        let overlapRatio = Double(overlapCount) / Double(max(1, suggestionTokens.count))

        // Suppress rewrites that introduce mostly-new topical vocabulary.
        if overlapRatio < 0.34,
           novelCount >= max(3, suggestionTokens.count / 2) {
            return true
        }

        // Extra guard for short prompts where 1-2 words can completely change intent.
        if sourceTokens.count <= 6,
           overlapCount <= 1,
           novelCount >= 4 {
            return true
        }

        return false
    }

    private func contentTokens(from text: String) -> Set<String> {
        let normalized = MemoryTextNormalizer
            .collapsedWhitespace(text)
            .lowercased()
        guard !normalized.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(
            pattern: #"[a-z0-9][a-z0-9'_-]{1,24}"#,
            options: []
        ) else {
            return []
        }

        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "can",
            "do", "does", "for", "from", "how", "i", "if", "in", "is", "it",
            "me", "my", "of", "on", "or", "our", "please", "so", "that", "the",
            "to", "too", "up", "we", "what", "when", "where", "which", "who",
            "why", "with", "you", "your"
        ]

        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let matches = regex.matches(in: normalized, options: [], range: range)
        var tokens = Set<String>()
        tokens.reserveCapacity(matches.count)

        for match in matches {
            guard let tokenRange = Range(match.range, in: normalized) else { continue }
            let token = String(normalized[tokenRange])
            if token.count < 2 { continue }
            if stopWords.contains(token) { continue }
            if token.range(of: #"^\d+$"#, options: .regularExpression) != nil { continue }
            tokens.insert(token)
        }
        return tokens
    }

    private func internalPayloadMarkerMatchCount(in loweredText: String) -> Int {
        let markers = [
            "original prompt:",
            "conversation context",
            "same app/screen bucket",
            "recent conversation turns",
            "rewrite lessons payload",
            "supporting memory cards payload"
        ]
        return markers.reduce(into: 0) { partial, marker in
            if loweredText.contains(marker) {
                partial += 1
            }
        }
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

    private func providerErrorDetail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any] else {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let detail = dictionary["detail"] as? String {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let message = dictionary["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let errorString = dictionary["error"] as? String {
            let trimmed = errorString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let error = dictionary["error"] as? [String: Any] {
            if let message = error["message"] as? String {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let detail = error["detail"] as? String {
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let code = error["code"] as? String {
                let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
