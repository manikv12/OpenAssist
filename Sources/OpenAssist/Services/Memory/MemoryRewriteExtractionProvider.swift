import Foundation
import Security

protocol MemoryRewriteExtractionProviding {
    func summary(
        for draft: MemoryEventDraft,
        provider: MemoryProviderKind
    ) async -> String?

    func rewriteSuggestion(
        for draft: MemoryEventDraft,
        card: MemoryCard,
        provider: MemoryProviderKind
    ) async -> RewriteSuggestion?

    func lesson(
        for draft: MemoryEventDraft,
        card: MemoryCard,
        provider: MemoryProviderKind
    ) async -> MemoryLessonDraft?

    func summarizeConversationHandoff(
        summarySeed: String,
        recentTurns: [PromptRewriteConversationTurn],
        context: PromptRewriteConversationContext,
        timeoutSeconds: Int
    ) async -> (text: String, confidence: Double?, method: String)

    func hasAIBackedIndexingAccess(for provider: MemoryProviderKind) async -> Bool
}

extension MemoryRewriteExtractionProviding {
    func summarizeConversationHandoff(
        summarySeed: String,
        recentTurns: [PromptRewriteConversationTurn],
        context: PromptRewriteConversationContext,
        timeoutSeconds: Int
    ) async -> (text: String, confidence: Double?, method: String) {
        _ = recentTurns
        _ = context
        _ = timeoutSeconds
        let normalized = MemoryTextNormalizer.normalizedBody(summarySeed)
        return (normalized, nil, "deterministic-fallback")
    }

    func hasAIBackedIndexingAccess(for provider: MemoryProviderKind) async -> Bool {
        _ = provider
        return false
    }
}

final class StubMemoryRewriteExtractionProvider: MemoryRewriteExtractionProviding {
    static let shared = StubMemoryRewriteExtractionProvider()

    private let aiLessonProvider = MemoryAILessonSynthesisProvider.shared

    func summary(
        for draft: MemoryEventDraft,
        provider: MemoryProviderKind
    ) async -> String? {
        if let nativeSummary = draft.nativeSummary {
            let normalized = MemoryTextNormalizer.normalizedSummary(nativeSummary)
            if !normalized.isEmpty {
                return normalized
            }
        }

        let body = MemoryTextNormalizer.normalizedBody(draft.body)
        guard !body.isEmpty else { return nil }

        if let sentence = firstSentence(in: body), !sentence.isEmpty {
            return MemoryTextNormalizer.normalizedSummary(sentence)
        }
        return MemoryTextNormalizer.normalizedSummary(body)
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
        guard !draft.isPlanContent else { return nil }
        guard isLessonCandidate(draft: draft, card: card) else { return nil }

        if let aiLesson = await aiLessonProvider.synthesizeLesson(
            for: draft,
            card: card
        ) {
            return MemoryLessonDraft(
                mistakePattern: aiLesson.mistakePattern,
                improvedPrompt: aiLesson.improvedPrompt,
                rationale: aiLesson.rationale,
                validationConfidence: aiLesson.validationConfidence,
                sourceMetadata: sourceMetadata(
                    for: draft,
                    card: card,
                    extractionMethod: "ai",
                    providerMode: aiLesson.sourceMetadata["provider_mode"]
                ).merging(aiLesson.sourceMetadata, uniquingKeysWith: { _, new in new })
            )
        }
        return nil
    }

    func hasAIBackedIndexingAccess(for provider: MemoryProviderKind) async -> Bool {
        _ = provider
        return await aiLessonProvider.hasLiveSynthesisConfiguration()
    }

    func summarizeConversationHandoff(
        summarySeed: String,
        recentTurns: [PromptRewriteConversationTurn],
        context: PromptRewriteConversationContext,
        timeoutSeconds: Int
    ) async -> (text: String, confidence: Double?, method: String) {
        enum HandoffResult {
            case ai(text: String, confidence: Double, method: String)
            case unavailable
            case timeout
        }

        let normalizedSeed = MemoryTextNormalizer.normalizedBody(summarySeed)
        let deterministicFallback = deterministicHandoffSummary(
            summarySeed: normalizedSeed,
            recentTurns: recentTurns,
            context: context
        )
        let fallbackText = deterministicFallback.isEmpty ? normalizedSeed : deterministicFallback
        let hardTimeoutSeconds = min(60, max(1, timeoutSeconds))

        let racedResult = await withTaskGroup(of: HandoffResult.self) { group in
            group.addTask { [aiLessonProvider] in
                guard let aiSummary = await aiLessonProvider.synthesizeHandoffSummary(
                    summarySeed: normalizedSeed,
                    recentTurns: recentTurns,
                    context: context
                ) else {
                    return .unavailable
                }
                return .ai(
                    text: aiSummary.text,
                    confidence: aiSummary.confidence,
                    method: aiSummary.method
                )
            }
            group.addTask {
                let nanoseconds = UInt64(hardTimeoutSeconds) * 1_000_000_000
                try? await Task.sleep(nanoseconds: nanoseconds)
                return .timeout
            }

            let first = await group.next() ?? .unavailable
            group.cancelAll()
            return first
        }

        switch racedResult {
        case let .ai(text, confidence, method):
            let normalizedAI = MemoryTextNormalizer.normalizedBody(text)
            if normalizedAI.isEmpty {
                return (fallbackText, nil, "deterministic-fallback")
            }
            return (normalizedAI, min(1.0, max(0.0, confidence)), method)
        case .timeout:
            return (fallbackText, nil, "deterministic-timeout-fallback")
        case .unavailable:
            return (fallbackText, nil, "deterministic-fallback")
        }
    }

    private func sourceMetadata(
        for draft: MemoryEventDraft,
        card: MemoryCard,
        extractionMethod: String,
        providerMode: String? = nil
    ) -> [String: String] {
        var metadata = draft.metadata
        metadata["event_kind"] = draft.kind.rawValue
        metadata["event_title"] = MemoryTextNormalizer.normalizedTitle(draft.title)
        metadata["card_title"] = MemoryTextNormalizer.normalizedTitle(card.title)
        metadata["card_summary"] = MemoryTextNormalizer.normalizedSummary(card.summary, limit: 180)
        metadata["is_plan_content"] = draft.isPlanContent ? "true" : "false"
        metadata["extraction_method"] = extractionMethod
        if let providerMode, !providerMode.isEmpty {
            metadata["provider_mode"] = providerMode
        }

        var normalized: [String: String] = [:]
        normalized.reserveCapacity(metadata.count)
        for (key, value) in metadata {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty, !trimmedValue.isEmpty else { continue }
            normalized[trimmedKey] = trimmedValue
        }
        return normalized
    }

    private func isLessonCandidate(draft: MemoryEventDraft, card: MemoryCard) -> Bool {
        if draft.kind == .rewrite {
            return true
        }

        let lowerBody = draft.body.lowercased()
        let lowerSummary = card.summary.lowercased()
        let lowerDetail = card.detail.lowercased()
        let lowerTitle = draft.title.lowercased()

        if lowerBody.contains("->") || lowerBody.contains("=>") || lowerBody.contains("→") {
            return true
        }

        let hints = [
            "rewrite", "rephrase", "prompt fix", "improved prompt",
            "better prompt", "corrected prompt", "before", "after"
        ]
        if hints.contains(where: { lowerBody.contains($0) }) {
            return true
        }
        if hints.contains(where: { lowerSummary.contains($0) || lowerDetail.contains($0) || lowerTitle.contains($0) }) {
            return true
        }

        let metadataKeys = Set(draft.metadata.keys.map { $0.lowercased() })
        let rewriteMetadataKeys: Set<String> = [
            "original_text", "suggested_text", "rewrite", "response", "completion", "prompt", "input", "output"
        ]
        return !metadataKeys.intersection(rewriteMetadataKeys).isEmpty
    }

    private func firstSentence(in text: String) -> String? {
        let separators: Set<Character> = [".", "!", "?", "\n"]
        var sentence = ""
        for character in text {
            sentence.append(character)
            if separators.contains(character) {
                break
            }
        }
        let trimmed = MemoryTextNormalizer.normalizedBody(sentence)
        if trimmed.isEmpty {
            return nil
        }
        return trimmed
    }

    private func deterministicHandoffSummary(
        summarySeed: String,
        recentTurns: [PromptRewriteConversationTurn],
        context: PromptRewriteConversationContext
    ) -> String {
        let seed = MemoryTextNormalizer.normalizedBody(summarySeed)
        let recentWindow = Array(recentTurns.suffix(8))
        let userSignals = distinctHandoffSnippets(
            from: recentWindow.filter { !$0.isSummary }.map(\.userText),
            limit: 3,
            snippetLimit: 180
        )
        let assistantSignals = distinctHandoffSnippets(
            from: recentWindow.filter { !$0.isSummary }.map(\.assistantText),
            limit: 3,
            snippetLimit: 200
        )

        var sections: [String] = []
        sections.append("## Context")
        sections.append("- \(context.providerContextLabel)")

        if !seed.isEmpty {
            sections.append("")
            sections.append("## Prior Summary")
            sections.append("- \(MemoryTextNormalizer.normalizedSummary(seed, limit: 420))")
        }

        if !userSignals.isEmpty {
            sections.append("")
            sections.append("## User Intent Signals")
            sections.append(contentsOf: userSignals.map { "- \($0)" })
        }

        if !assistantSignals.isEmpty {
            sections.append("")
            sections.append("## Assistant Progress Signals")
            sections.append(contentsOf: assistantSignals.map { "- \($0)" })
        }

        sections.append("")
        sections.append("## Handoff")
        sections.append("- Continue from the latest user intent and explicit constraints.")
        sections.append("- Keep continuity with this app context and conversation style.")

        let built = handoffSnippet(sections.joined(separator: "\n"), limit: 1_600)
        return MemoryTextNormalizer.normalizedBody(built)
    }

    private func distinctHandoffSnippets(
        from values: [String],
        limit: Int,
        snippetLimit: Int
    ) -> [String] {
        var output: [String] = []
        var seen: Set<String> = []

        for value in values {
            let normalized = MemoryTextNormalizer.normalizedBody(value)
            guard !normalized.isEmpty else { continue }
            let concise = handoffSnippet(normalized, limit: snippetLimit)
            let key = concise.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(concise)
            if output.count >= limit {
                break
            }
        }

        return output
    }

    private func handoffSnippet(_ value: String, limit: Int) -> String {
        let normalized = MemoryTextNormalizer.normalizedBody(value)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }
}

private actor MemoryAILessonSynthesisProvider {
    static let shared = MemoryAILessonSynthesisProvider()

    private enum ProviderCredential {
        case none
        case apiKey(String)
        case oauth(PromptRewriteOAuthSession)
    }

    private struct LiveConfiguration {
        let providerMode: PromptRewriteProviderMode
        let model: String
        let baseURL: String
        let apiKey: String
        let oauthSession: PromptRewriteOAuthSession?

        var hasCredentials: Bool {
            if oauthSession != nil {
                return true
            }
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return !providerMode.requiresAPIKey
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func hasLiveSynthesisConfiguration() async -> Bool {
        guard let configuration = liveConfiguration() else { return false }
        guard configuration.hasCredentials else { return false }

        let credential: ProviderCredential
        do {
            credential = try await resolveCredential(for: configuration)
        } catch {
            return false
        }

        if configuration.providerMode.requiresAPIKey {
            if case .none = credential {
                return false
            }
        }

        if configuration.providerMode == .ollama {
            let reachable = await isOllamaReachable(baseURL: configuration.baseURL)
            if !reachable {
                CrashReporter.logWarning(
                    "Memory lesson AI check failed: local runtime unavailable. AI Studio > Prompt Models > Local AI Setup."
                )
                return false
            }
        }
        return true
    }

    func synthesizeLesson(
        for draft: MemoryEventDraft,
        card: MemoryCard
    ) async -> MemoryLessonDraft? {
        guard let configuration = liveConfiguration() else { return nil }
        guard configuration.hasCredentials else { return nil }

        let credential: ProviderCredential
        do {
            credential = try await resolveCredential(for: configuration)
        } catch {
            return nil
        }

        if configuration.providerMode.requiresAPIKey {
            if case .none = credential {
                return nil
            }
        }

        let systemPrompt = """
        You synthesize concise memory lessons from prompt rewrite traces.
        Return strict JSON only:
        {
          "mistake_pattern": string,
          "improved_prompt": string,
          "rationale": string,
          "validation_confidence": number
        }
        Rules:
        - mistake_pattern is the flawed wording or approach to avoid.
        - improved_prompt is the corrected wording preserving user intent.
        - rationale should explain why the improvement is better in one or two sentences.
        - validation_confidence must be 0.0 to 1.0.
        - If signal is weak, conversational, or non-actionable, return:
          {"mistake_pattern":"","improved_prompt":"","rationale":"NO_SIGNAL","validation_confidence":0.0}
        - Treat greetings/chitchat as NO_SIGNAL (examples: "hi", "hello", "hey", "thanks", "how are you").
        - Do not create lessons from assistant pleasantries ("How can I help?", "anything else?").
        """

        let userPrompt = """
        Event:
        - kind: \(draft.kind.rawValue)
        - title: \(snippet(draft.title, limit: 180))
        - body: \(snippet(draft.body, limit: 1500))
        - native_summary: \(snippet(draft.nativeSummary ?? "", limit: 280))

        Card:
        - title: \(snippet(card.title, limit: 180))
        - summary: \(snippet(card.summary, limit: 320))
        - detail: \(snippet(card.detail, limit: 1200))

        Metadata JSON:
        \(metadataJSON(from: draft.metadata))
        """

        let request: URLRequest
        do {
            request = try buildRequest(
                configuration: configuration,
                credential: credential,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        } catch {
            return nil
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if configuration.providerMode == .ollama {
                CrashReporter.logWarning(
                    "Memory lesson synthesis skipped because local runtime is unavailable. AI Studio > Prompt Models > Local AI Setup."
                )
            }
            return nil
        }

        guard let http = response as? HTTPURLResponse else { return nil }
        guard (200...299).contains(http.statusCode) else {
            if configuration.providerMode == .ollama {
                CrashReporter.logWarning(
                    "Memory lesson synthesis request failed for local runtime (HTTP \(http.statusCode)). Repair Local AI in AI Studio."
                )
            }
            return nil
        }

        guard let parsed = decodeResponse(
            data: data,
            providerMode: configuration.providerMode
        ) else {
            return nil
        }

        let normalizedMistake = MemoryTextNormalizer.normalizedBody(parsed.mistakePattern)
        let normalizedImproved = MemoryTextNormalizer.normalizedBody(parsed.improvedPrompt)
        let normalizedRationale = MemoryTextNormalizer.normalizedSummary(parsed.rationale, limit: 400)

        guard !normalizedMistake.isEmpty, !normalizedImproved.isEmpty else { return nil }
        guard normalizedMistake.caseInsensitiveCompare(normalizedImproved) != .orderedSame else { return nil }

        return MemoryLessonDraft(
            mistakePattern: normalizedMistake,
            improvedPrompt: normalizedImproved,
            rationale: normalizedRationale.isEmpty ? "AI synthesized memory lesson" : normalizedRationale,
            validationConfidence: min(1, max(0, parsed.validationConfidence)),
            sourceMetadata: [
                "provider_mode": configuration.providerMode.rawValue.lowercased(),
                "ai_model": configuration.model,
                "fallback_rule": "none"
            ]
        )
    }

    func synthesizeHandoffSummary(
        summarySeed: String,
        recentTurns: [PromptRewriteConversationTurn],
        context: PromptRewriteConversationContext
    ) async -> (text: String, confidence: Double, method: String)? {
        guard let configuration = liveConfiguration() else { return nil }
        guard configuration.hasCredentials else { return nil }

        let credential: ProviderCredential
        do {
            credential = try await resolveCredential(for: configuration)
        } catch {
            return nil
        }

        if configuration.providerMode.requiresAPIKey {
            if case .none = credential {
                return nil
            }
        }

        let systemPrompt = """
        You enrich conversation handoff summaries for long-term memory promotion.
        Return strict JSON only:
        {
          "summary_text": string,
          "confidence": number
        }
        Rules:
        - summary_text must be concise, specific, and carry forward intent, constraints, and recent progress.
        - confidence must be 0.0 to 1.0 and reflect summary usefulness for future continuation.
        - Avoid greetings, pleasantries, or generic filler.
        - Preserve factual context only; do not invent details.
        """

        let userPrompt = """
        Context:
        - app_name: \(snippet(context.appName, limit: 80))
        - bundle_id: \(snippet(context.bundleIdentifier, limit: 120))
        - screen_label: \(snippet(context.screenLabel, limit: 120))
        - field_label: \(snippet(context.fieldLabel, limit: 120))
        - project_label: \(snippet(context.projectLabel ?? "", limit: 120))
        - identity_label: \(snippet(context.identityLabel ?? "", limit: 120))

        Summary seed:
        \(snippet(summarySeed, limit: 1600))

        Recent turns:
        \(formattedTurnsForHandoffSummaryPrompt(recentTurns))
        """

        let request: URLRequest
        do {
            request = try buildRequest(
                configuration: configuration,
                credential: credential,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        } catch {
            return nil
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return nil
        }

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let parsed = parseHandoffSummaryResponse(
                data: data,
                providerMode: configuration.providerMode
              ) else {
            return nil
        }

        let normalizedText = MemoryTextNormalizer.normalizedBody(parsed.text)
        guard !normalizedText.isEmpty else { return nil }
        return (
            text: normalizedText,
            confidence: min(1.0, max(0.0, parsed.confidence)),
            method: "ai-\(configuration.providerMode.rawValue.lowercased())"
        )
    }

    private func buildRequest(
        configuration: LiveConfiguration,
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
                "model": configuration.model,
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
            endpoint = anthropicMessagesEndpoint(from: configuration.baseURL)
            payload = [
                "model": configuration.model,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": userPrompt]
                ],
                "temperature": 0.2,
                "max_tokens": 420
            ]
        case .openAI, .google, .openRouter, .groq, .ollama:
            endpoint = openAICompatibleEndpoint(from: configuration.baseURL)
            payload = [
                "model": configuration.model,
                "temperature": 0.2,
                "response_format": ["type": "json_object"],
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ]
            ]
        }

        guard let endpoint else {
            throw NSError(domain: "MemoryLessonAI", code: 1)
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            throw NSError(domain: "MemoryLessonAI", code: 2)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = lessonSynthesisRequestTimeout(for: configuration.providerMode)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

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
        case (.openAI, .oauth(let oauthSession)):
            request.setValue("Bearer \(oauthSession.accessToken)", forHTTPHeaderField: "Authorization")
            if let accountID = oauthSession.accountID,
               !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        case (.openAI, .apiKey(let apiKey)),
             (.google, .apiKey(let apiKey)),
             (.openRouter, .apiKey(let apiKey)),
             (.groq, .apiKey(let apiKey)),
             (.ollama, .apiKey(let apiKey)):
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case (.anthropic, .none),
             (.openAI, .none),
             (.google, .none),
             (.openRouter, .none),
             (.groq, .none),
             (.ollama, .none),
             (.google, .oauth),
             (.openRouter, .oauth),
             (.groq, .oauth),
             (.ollama, .oauth):
            break
        }

        return request
    }

    private func lessonSynthesisRequestTimeout(for providerMode: PromptRewriteProviderMode) -> TimeInterval {
        let defaults = UserDefaults.standard
        let configured = defaults.object(forKey: "OpenAssist.promptRewriteRequestTimeoutSeconds") == nil
            ? 8
            : defaults.double(forKey: "OpenAssist.promptRewriteRequestTimeoutSeconds")
        let normalized = min(120, max(3, configured))

        switch providerMode {
        case .ollama:
            return min(120, max(20, normalized + 15))
        case .openAI, .google, .openRouter, .groq, .anthropic:
            return min(120, max(12, normalized + 4))
        }
    }

    private func resolveCredential(for configuration: LiveConfiguration) async throws -> ProviderCredential {
        if let oauthSession = configuration.oauthSession, configuration.providerMode.supportsOAuthSignIn {
            do {
                let refreshed = try await PromptRewriteProviderOAuthService.shared.refreshSessionIfNeeded(
                    oauthSession,
                    providerMode: configuration.providerMode
                )
                return .oauth(refreshed)
            } catch {
                return .none
            }
        }

        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func liveConfiguration() -> LiveConfiguration? {
        let defaults = UserDefaults.standard
        let providerMode = loadProviderMode(defaults: defaults)

        let model = defaults
            .string(forKey: "OpenAssist.promptRewriteOpenAIModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = defaults
            .string(forKey: "OpenAssist.promptRewriteOpenAIBaseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let oauthSession = PromptRewriteOAuthCredentialStore.loadSession(for: providerMode)
        var resolvedModel = (model?.isEmpty == false) ? model! : providerMode.defaultModel
        if providerMode == .openAI,
           oauthSession != nil,
           resolvedModel == PromptRewriteProviderMode.openAI.defaultModel {
            resolvedModel = "gpt-5.3-codex"
        }
        let resolvedBaseURL = (baseURL?.isEmpty == false) ? baseURL! : providerMode.defaultBaseURL
        let apiKey = loadProviderAPIKey(for: providerMode)

        let hasAnyCredential = oauthSession != nil || !apiKey.isEmpty || !providerMode.requiresAPIKey
        guard hasAnyCredential else { return nil }

        return LiveConfiguration(
            providerMode: providerMode,
            model: resolvedModel,
            baseURL: resolvedBaseURL,
            apiKey: apiKey,
            oauthSession: oauthSession
        )
    }

    private func loadProviderMode(defaults: UserDefaults) -> PromptRewriteProviderMode {
        let raw = defaults
            .string(forKey: "OpenAssist.promptRewriteProviderMode")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch raw {
        case "openai":
            return .openAI
        case "google", "gemini", "google ai studio (gemini)", "google-ai-studio-gemini":
            return .google
        case "openrouter":
            return .openRouter
        case "groq":
            return .groq
        case "anthropic":
            return .anthropic
        case "ollama (local)", "ollama":
            return .ollama
        case "local memory", "local-memory", "local":
            return .openAI
        default:
            return .openAI
        }
    }

    private func loadProviderAPIKey(for providerMode: PromptRewriteProviderMode) -> String {
        guard providerMode.requiresAPIKey else { return "" }

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

        let normalizedProviderSlug = providerMode.rawValue
            .lowercased()
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "-")
        let providerAccount = "prompt-rewrite-provider-api-key.\(normalizedProviderSlug)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.developingadventures.OpenAssist",
            kSecAttrAccount as String: providerAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess, providerMode == .openAI {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.developingadventures.OpenAssist",
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
        } else if status != errSecSuccess {
            return ""
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func isOllamaReachable(baseURL: String) async -> Bool {
        guard let endpoint = ollamaTagsEndpoint(from: baseURL) else { return false }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func ollamaTagsEndpoint(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var normalizedBase = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        if normalizedBase.hasSuffix("/v1") {
            normalizedBase = String(normalizedBase.dropLast(3))
        }
        return URL(string: normalizedBase + "/api/tags")
    }

    private func decodeResponse(
        data: Data,
        providerMode: PromptRewriteProviderMode
    ) -> MemoryLessonDraft? {
        let content: String
        if providerMode == .anthropic {
            content = decodeAnthropicContent(data: data)
        } else {
            content = decodeOpenAICompatibleContent(data: data)
        }

        let cleaned = sanitizeModelJSONText(content)
        return parseJSONPayload(cleaned)
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

        let messageContent = message["content"]
        if let contentString = messageContent as? String {
            return contentString
        }
        if let contentArray = messageContent as? [[String: Any]] {
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

    private func parseJSONPayload(_ content: String) -> MemoryLessonDraft? {
        guard let data = content.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        let mistakePattern = extractString(
            from: object,
            keys: ["mistake_pattern", "mistakePattern", "bad_prompt", "badPrompt", "mistake"]
        )
        let improvedPrompt = extractString(
            from: object,
            keys: ["improved_prompt", "improvedPrompt", "rewrite", "better_prompt", "betterPrompt", "suggested_text"]
        )
        let rationale = extractString(
            from: object,
            keys: ["rationale", "reason", "explanation"]
        )

        let confidence = extractDouble(
            from: object,
            keys: ["validation_confidence", "validationConfidence", "confidence"]
        ) ?? 0.62

        guard let mistakePattern, let improvedPrompt else {
            return nil
        }

        return MemoryLessonDraft(
            mistakePattern: mistakePattern,
            improvedPrompt: improvedPrompt,
            rationale: rationale ?? "AI synthesized lesson",
            validationConfidence: confidence,
            sourceMetadata: [:]
        )
    }

    private func parseHandoffSummaryResponse(
        data: Data,
        providerMode: PromptRewriteProviderMode
    ) -> (text: String, confidence: Double)? {
        let content: String
        if providerMode == .anthropic {
            content = decodeAnthropicContent(data: data)
        } else {
            content = decodeOpenAICompatibleContent(data: data)
        }

        let cleaned = sanitizeModelJSONText(content)
        guard let payloadData = cleaned.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: payloadData, options: [])) as? [String: Any] else {
            return nil
        }

        guard let summary = extractString(
            from: object,
            keys: ["summary_text", "summary", "handoff_summary", "handoff", "text"]
        ) else {
            return nil
        }
        let confidence = extractDouble(
            from: object,
            keys: ["confidence", "summary_confidence", "score"]
        ) ?? 0.72

        return (summary, confidence)
    }

    private func extractString(from object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let raw = object[key] else { continue }
            if let string = raw as? String {
                let normalized = MemoryTextNormalizer.normalizedBody(string)
                if !normalized.isEmpty {
                    return normalized
                }
            } else if let number = raw as? NSNumber {
                let value = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func extractDouble(from object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let raw = object[key] else { continue }
            if let value = raw as? Double {
                return value
            }
            if let value = raw as? Int {
                return Double(value)
            }
            if let value = raw as? NSNumber {
                return value.doubleValue
            }
            if let value = raw as? String,
               let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }

    private func metadataJSON(from metadata: [String: String]) -> String {
        guard !metadata.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return snippet(json, limit: 2400)
    }

    private func snippet(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }

    private func formattedTurnsForHandoffSummaryPrompt(_ turns: [PromptRewriteConversationTurn]) -> String {
        let recent = turns.suffix(8)
        guard !recent.isEmpty else { return "- none" }

        var lines: [String] = []
        for turn in recent {
            if turn.isSummary {
                lines.append("- summary: \(snippet(turn.assistantText, limit: 320))")
            } else {
                lines.append("- user: \(snippet(turn.userText, limit: 260))")
                lines.append("  assistant: \(snippet(turn.assistantText, limit: 260))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
