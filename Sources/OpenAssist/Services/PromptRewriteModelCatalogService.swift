import Foundation

struct PromptRewriteModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String
}

struct PromptRewriteModelFetchResult {
    enum Source {
        case remote
        case fallback
    }

    let models: [PromptRewriteModelOption]
    let source: Source
    let message: String?
}

actor PromptRewriteModelCatalogService {
    static let shared = PromptRewriteModelCatalogService()
    private static let cachePrefix = "OpenAssist.promptRewriteModelCatalogCache."

    private enum Credential {
        case none
        case apiKey(String)
        case oauth(PromptRewriteOAuthSession)
    }

    private enum ModelCatalogError: LocalizedError {
        case invalidBaseURL
        case requestFailed(statusCode: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "Invalid provider base URL."
            case let .requestFailed(statusCode, detail):
                return "Request failed (HTTP \(statusCode)): \(detail)"
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchModels(
        providerMode: PromptRewriteProviderMode,
        baseURL: String,
        apiKey: String
    ) async -> PromptRewriteModelFetchResult {
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOpenAIOAuth = providerMode == .openAI
            && PromptRewriteOAuthCredentialStore.loadSession(for: .openAI) != nil
        let hasOpenAIAPIKey = providerMode == .openAI && !normalizedAPIKey.isEmpty

        let credentialResolution = await resolveCredential(
            providerMode: providerMode,
            apiKey: apiKey
        )
        let credential = credentialResolution.credential
        let credentialMessage = credentialResolution.message
        let preferOpenAIOAuthCatalog = providerMode == .openAI && hasOpenAIOAuth && !hasOpenAIAPIKey
        let effectiveBaseURL: String
        if providerMode == .openAI && preferOpenAIOAuthCatalog {
            effectiveBaseURL = PromptRewriteProviderMode.openAI.defaultBaseURL
        } else {
            effectiveBaseURL = baseURL
        }

        let discoveredFallbackModels = await fallbackModels(
            for: providerMode,
            preferOpenAIOAuthCatalog: preferOpenAIOAuthCatalog
        )
        if !discoveredFallbackModels.isEmpty {
            cacheModels(discoveredFallbackModels, for: providerMode)
        }
        let fallbackCatalogModels = discoveredFallbackModels.isEmpty
            ? Self.providerSpecificFallbackCatalogModels(
                cachedModels(for: providerMode),
                providerMode: providerMode,
                preferOpenAIOAuthCatalog: preferOpenAIOAuthCatalog
            )
            : discoveredFallbackModels

        switch providerMode {
        case .openAI:
            guard isAPIKeyCredential(credential) || isOAuthCredential(credential) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: credentialMessage ?? "Connect OpenAI to load live models."
                )
            }
            guard let endpoint = Self.openAIModelsEndpoint(from: effectiveBaseURL) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Invalid OpenAI base URL."
                )
            }
            do {
                let remoteModels = try await fetchOpenAICompatibleModels(
                    endpoint: endpoint,
                    credential: credential,
                    providerMode: providerMode
                )
                var models = preferOpenAIOAuthCatalog
                    ? Self.openAIOAuthCompatibleModels(remoteModels)
                    : Self.rewriteFriendlyModels(remoteModels, providerMode: .openAI)
                if hasOpenAIOAuth && hasOpenAIAPIKey {
                    let oauthCompatibleFallback = await fallbackModels(for: .openAI, preferOpenAIOAuthCatalog: true)
                    models = Self.mergeModelOptions(primary: models, secondary: oauthCompatibleFallback)
                }
                if !models.isEmpty {
                    cacheModels(models, for: providerMode)
                    return PromptRewriteModelFetchResult(
                        models: models,
                        source: .remote,
                        message: "Loaded \(models.count) OpenAI models."
                    )
                }
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: fallbackMessage(
                        providerName: "OpenAI",
                        fallbackCount: fallbackCatalogModels.count,
                        failureReason: "OpenAI returned no rewrite-suitable models."
                    )
                )
            } catch {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: fallbackMessage(
                        providerName: "OpenAI",
                        fallbackCount: fallbackCatalogModels.count,
                        failureReason: "Could not load OpenAI models: \(error.localizedDescription)"
                    )
                )
            }
        case .google:
            guard isAPIKeyCredential(credential) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Add Google API key to load live Gemini models."
                )
            }
            guard let endpoint = Self.openAIModelsEndpoint(from: baseURL) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Invalid Google AI Studio base URL."
                )
            }
            do {
                let remoteModels = try await fetchOpenAICompatibleModels(
                    endpoint: endpoint,
                    credential: credential,
                    providerMode: providerMode
                )
                let models = Self.rewriteFriendlyModels(remoteModels, providerMode: .google)
                if !models.isEmpty {
                    cacheModels(models, for: providerMode)
                    return PromptRewriteModelFetchResult(
                        models: models,
                        source: .remote,
                        message: "Loaded \(models.count) Google Gemini models."
                    )
                }
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: fallbackMessage(
                        providerName: "Google Gemini",
                        fallbackCount: fallbackCatalogModels.count,
                        failureReason: "Google returned no rewrite-suitable Gemini models."
                    )
                )
            } catch {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: fallbackMessage(
                        providerName: "Google Gemini",
                        fallbackCount: fallbackCatalogModels.count,
                        failureReason: "Could not load Google Gemini models: \(error.localizedDescription)"
                    )
                )
            }
        case .openRouter:
            guard isAPIKeyCredential(credential) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Add OpenRouter API key to load live models."
                )
            }
            guard let endpoint = Self.openAIModelsEndpoint(from: baseURL) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Invalid OpenRouter base URL."
                )
            }
            do {
                let models = try await fetchOpenAICompatibleModels(
                    endpoint: endpoint,
                    credential: credential,
                    providerMode: providerMode
                )
                if !models.isEmpty {
                    cacheModels(models, for: providerMode)
                    return PromptRewriteModelFetchResult(
                        models: models,
                        source: .remote,
                        message: "Loaded \(models.count) OpenRouter models."
                    )
                }
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "OpenRouter returned no models."
                )
            } catch {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Could not load OpenRouter models: \(error.localizedDescription)"
                )
            }
        case .groq:
            guard isAPIKeyCredential(credential) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Add Groq API key to load live models."
                )
            }
            guard let endpoint = Self.openAIModelsEndpoint(from: baseURL) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Invalid Groq base URL."
                )
            }
            do {
                let models = try await fetchOpenAICompatibleModels(
                    endpoint: endpoint,
                    credential: credential,
                    providerMode: providerMode
                )
                if !models.isEmpty {
                    cacheModels(models, for: providerMode)
                    return PromptRewriteModelFetchResult(
                        models: models,
                        source: .remote,
                        message: "Loaded \(models.count) Groq models."
                    )
                }
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Groq returned no models."
                )
            } catch {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Could not load Groq models: \(error.localizedDescription)"
                )
            }
        case .anthropic:
            guard isAPIKeyCredential(credential) || isOAuthCredential(credential) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: credentialMessage ?? "Connect Anthropic to load live models."
                )
            }
            guard let endpoint = Self.anthropicModelsEndpoint(from: baseURL) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Invalid Anthropic base URL."
                )
            }
            do {
                let models = try await fetchAnthropicModels(
                    endpoint: endpoint,
                    credential: credential,
                    providerMode: providerMode
                )
                if !models.isEmpty {
                    cacheModels(models, for: providerMode)
                    return PromptRewriteModelFetchResult(
                        models: models,
                        source: .remote,
                        message: "Loaded \(models.count) Anthropic models."
                    )
                }
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Anthropic returned no models."
                )
            } catch {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Could not load Anthropic models: \(error.localizedDescription)"
                )
            }
        case .ollama:
            guard let openAIEndpoint = Self.openAIModelsEndpoint(from: baseURL) else {
                return PromptRewriteModelFetchResult(
                    models: fallbackCatalogModels,
                    source: .fallback,
                    message: "Invalid Ollama base URL."
                )
            }
            var openAIError: Error?
            do {
                let models = try await fetchOpenAICompatibleModels(
                    endpoint: openAIEndpoint,
                    credential: .none,
                    providerMode: providerMode
                )
                if !models.isEmpty {
                    cacheModels(models, for: providerMode)
                    return PromptRewriteModelFetchResult(
                        models: models,
                        source: .remote,
                        message: "Loaded \(models.count) Ollama models."
                    )
                }
            } catch {
                openAIError = error
                // Fall through to /api/tags fallback endpoint.
            }

            if let tagsEndpoint = Self.ollamaTagsEndpoint(from: baseURL) {
                do {
                    let models = try await fetchOllamaTags(endpoint: tagsEndpoint)
                    if !models.isEmpty {
                        cacheModels(models, for: providerMode)
                        return PromptRewriteModelFetchResult(
                            models: models,
                            source: .remote,
                            message: "Loaded \(models.count) Ollama models."
                        )
                    }
                } catch {
                    return PromptRewriteModelFetchResult(
                        models: fallbackCatalogModels,
                        source: .fallback,
                        message: localRuntimeCatalogFailureMessage(for: error)
                    )
                }
            }

            return PromptRewriteModelFetchResult(
                models: fallbackCatalogModels,
                source: .fallback,
                message: localRuntimeCatalogFailureMessage(for: openAIError)
            )
        }
    }

    private func fallbackModels(
        for providerMode: PromptRewriteProviderMode,
        preferOpenAIOAuthCatalog: Bool
    ) async -> [PromptRewriteModelOption] {
        let providerID: String
        switch providerMode {
        case .openAI:
            providerID = "openai"
        case .google:
            providerID = "google"
        case .openRouter:
            providerID = "openrouter"
        case .groq:
            providerID = "groq"
        case .anthropic:
            providerID = "anthropic"
        case .ollama:
            providerID = "ollama"
        }

        let models = Self.mergeModelOptions(
            primary: await fetchModelsDevProviderModels(providerID: providerID),
            secondary: Self.fallbackModels(for: providerMode)
        )
        return Self.providerSpecificFallbackCatalogModels(
            models,
            providerMode: providerMode,
            preferOpenAIOAuthCatalog: preferOpenAIOAuthCatalog
        )
    }

    private func fallbackMessage(
        providerName: String,
        fallbackCount: Int,
        failureReason: String
    ) -> String {
        if fallbackCount > 0 {
            return "\(failureReason) Showing \(fallbackCount) fallback catalog models."
        }
        return "\(failureReason) No fallback catalog models were available."
    }

    private func localRuntimeCatalogFailureMessage(for error: Error?) -> String {
        guard let error else {
            return "Could not load local models. AI Studio -> Prompt Models -> Local AI Setup and install or repair Local AI."
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let localRuntimeCodes = [
                NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorTimedOut
            ]
            if localRuntimeCodes.contains(nsError.code) {
                return "Local AI runtime is not reachable. AI Studio -> Prompt Models -> Local AI Setup and install or repair Local AI."
            }
        }

        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "Could not load local models. AI Studio -> Prompt Models -> Local AI Setup and repair Local AI."
        }
        return "Could not load local models: \(detail). AI Studio -> Prompt Models -> Local AI Setup."
    }

    private func cacheModels(_ models: [PromptRewriteModelOption], for providerMode: PromptRewriteProviderMode) {
        guard !models.isEmpty else { return }
        let payload = models.map { ["id": $0.id, "displayName": $0.displayName] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachePrefix + providerMode.rawValue)
    }

    private func cachedModels(for providerMode: PromptRewriteProviderMode) -> [PromptRewriteModelOption] {
        let key = Self.cachePrefix + providerMode.rawValue
        guard let data = UserDefaults.standard.data(forKey: key),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let rows = object as? [[String: Any]] else {
            return []
        }
        let options = rows.compactMap { row -> PromptRewriteModelOption? in
            guard let id = row["id"] as? String else { return nil }
            let displayName = (row["displayName"] as? String) ?? id
            return PromptRewriteModelOption(id: id, displayName: displayName)
        }
        return Self.normalizeModelOptions(options)
    }

    private func fetchModelsDevProviderModels(providerID: String) async -> [PromptRewriteModelOption] {
        guard let url = URL(string: "https://models.dev/api.json") else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = modelCatalogRequestTimeout(for: nil)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let provider = root[providerID] as? [String: Any],
                  let modelsDict = provider["models"] as? [String: Any] else {
                return []
            }

            var options: [PromptRewriteModelOption] = []
            options.reserveCapacity(modelsDict.count)

            for (modelID, payload) in modelsDict {
                let displayName: String
                if let payload = payload as? [String: Any],
                   let modelName = payload["name"] as? String,
                   !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    displayName = modelName
                } else {
                    displayName = modelID
                }

                options.append(
                    PromptRewriteModelOption(
                        id: modelID,
                        displayName: displayName
                    )
                )
            }

            return Self.normalizeModelOptions(options)
        } catch {
            return []
        }
    }

    static func parseModelOptions(from data: Data) -> [PromptRewriteModelOption] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        var collected: [PromptRewriteModelOption] = []
        collectModelOptions(from: object, into: &collected)
        return normalizeModelOptions(collected)
    }

    static func openAIModelsEndpoint(from baseURL: String) -> URL? {
        guard let normalizedBase = normalizedBaseURL(from: baseURL) else { return nil }
        return URL(string: "\(normalizedBase)/models")
    }

    static func anthropicModelsEndpoint(from baseURL: String) -> URL? {
        guard let normalizedBase = normalizedBaseURL(from: baseURL) else { return nil }
        return URL(string: "\(normalizedBase)/models")
    }

    static func ollamaTagsEndpoint(from baseURL: String) -> URL? {
        guard var normalizedBase = normalizedBaseURL(from: baseURL) else { return nil }
        if normalizedBase.hasSuffix("/v1") {
            normalizedBase = String(normalizedBase.dropLast(3))
        }
        return URL(string: "\(normalizedBase)/api/tags")
    }

    private func resolveCredential(
        providerMode: PromptRewriteProviderMode,
        apiKey: String
    ) async -> (credential: Credential, message: String?) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if providerMode == .openAI, !trimmedKey.isEmpty {
            return (.apiKey(trimmedKey), nil)
        }

        var message: String?
        if providerMode.supportsOAuthSignIn,
           let oauthSession = PromptRewriteOAuthCredentialStore.loadSession(for: providerMode) {
            do {
                let refreshed = try await PromptRewriteProviderOAuthService.shared.refreshSessionIfNeeded(
                    oauthSession,
                    providerMode: providerMode
                )
                return (.oauth(refreshed), nil)
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                if !detail.isEmpty {
                    message = "OAuth refresh failed: \(detail)."
                }
            }
        }

        if !trimmedKey.isEmpty {
            return (.apiKey(trimmedKey), message)
        }
        return (.none, message)
    }

    private func fetchOpenAICompatibleModels(
        endpoint: URL,
        credential: Credential,
        providerMode: PromptRewriteProviderMode
    ) async throws -> [PromptRewriteModelOption] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = modelCatalogRequestTimeout(for: providerMode)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        switch credential {
        case .apiKey(let apiKey):
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .oauth(let oauthSession):
            request.setValue("Bearer \(oauthSession.accessToken)", forHTTPHeaderField: "Authorization")
        case .none:
            break
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelCatalogError.requestFailed(statusCode: -1, detail: "invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ModelCatalogError.requestFailed(
                statusCode: http.statusCode,
                detail: providerErrorDetail(from: data) ?? "request failed"
            )
        }
        return Self.parseModelOptions(from: data)
    }

    private func fetchAnthropicModels(
        endpoint: URL,
        credential: Credential,
        providerMode: PromptRewriteProviderMode
    ) async throws -> [PromptRewriteModelOption] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = modelCatalogRequestTimeout(for: providerMode)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        switch credential {
        case .oauth(let oauthSession):
            request.setValue("Bearer \(oauthSession.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(
                "oauth-2025-04-20,interleaved-thinking-2025-05-14",
                forHTTPHeaderField: "anthropic-beta"
            )
            request.setValue("claude-cli/2.1.2 (external, cli)", forHTTPHeaderField: "User-Agent")
        case .apiKey(let apiKey):
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .none:
            break
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelCatalogError.requestFailed(statusCode: -1, detail: "invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ModelCatalogError.requestFailed(
                statusCode: http.statusCode,
                detail: providerErrorDetail(from: data) ?? "request failed"
            )
        }
        return Self.parseModelOptions(from: data)
    }

    private func fetchOllamaTags(endpoint: URL) async throws -> [PromptRewriteModelOption] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = modelCatalogRequestTimeout(for: .ollama)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelCatalogError.requestFailed(statusCode: -1, detail: "invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ModelCatalogError.requestFailed(
                statusCode: http.statusCode,
                detail: providerErrorDetail(from: data) ?? "request failed"
            )
        }
        return Self.parseModelOptions(from: data)
    }

    private func providerErrorDetail(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let dict = object as? [String: Any] {
            if let message = dict["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            if let error = dict["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            if let error = dict["error"] as? String,
               !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return error
            }
        }
        if let plainText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !plainText.isEmpty {
            return plainText
        }
        return nil
    }

    private func configuredPromptRewriteTimeoutSeconds() -> TimeInterval {
        let defaults = UserDefaults.standard
        let rawTimeout = defaults.object(forKey: "OpenAssist.promptRewriteRequestTimeoutSeconds") == nil
            ? 8
            : defaults.double(forKey: "OpenAssist.promptRewriteRequestTimeoutSeconds")
        return min(120, max(3, rawTimeout))
    }

    private func modelCatalogRequestTimeout(for providerMode: PromptRewriteProviderMode?) -> TimeInterval {
        let base = configuredPromptRewriteTimeoutSeconds()
        switch providerMode {
        case .ollama:
            return min(120, max(10, base + 2))
        case .openAI, .google, .openRouter, .groq, .anthropic:
            return min(120, max(8, base))
        case .none:
            return min(120, max(8, base))
        }
    }

    private static func normalizedBaseURL(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/") {
            return String(trimmed.dropLast())
        }
        return trimmed
    }

    private static func buildModelOptions(ids: [String]) -> [PromptRewriteModelOption] {
        normalizeModelOptions(
            ids.map { id in
                PromptRewriteModelOption(
                    id: id,
                    displayName: displayName(forModelID: id)
                )
            }
        )
    }

    private static func displayName(forModelID modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return modelID }
        let slashSplit = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        if slashSplit.count == 2 {
            return "\(slashSplit[1]) (\(slashSplit[0]))"
        }
        return trimmed
    }

    private static func collectModelOptions(
        from object: Any,
        into output: inout [PromptRewriteModelOption]
    ) {
        switch object {
        case let text as String:
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            output.append(PromptRewriteModelOption(id: normalized, displayName: normalized))
        case let array as [Any]:
            for item in array {
                collectModelOptions(from: item, into: &output)
            }
        case let dict as [String: Any]:
            let identifier = firstNonEmptyString(
                in: dict,
                keys: ["id", "model", "name", "slug"]
            )
            if let identifier {
                let label = firstNonEmptyString(
                    in: dict,
                    keys: ["display_name", "displayName", "name", "model", "id"]
                ) ?? identifier
                output.append(PromptRewriteModelOption(id: identifier, displayName: label))
            }

            let nestedKeys = ["data", "models", "items", "result"]
            for key in nestedKeys {
                if let nested = dict[key] {
                    collectModelOptions(from: nested, into: &output)
                }
            }
        default:
            break
        }
    }

    private static func firstNonEmptyString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    return normalized
                }
            }
        }
        return nil
    }

    private static func normalizeModelOptions(
        _ options: [PromptRewriteModelOption]
    ) -> [PromptRewriteModelOption] {
        var seen = Set<String>()
        var cleaned: [PromptRewriteModelOption] = []
        cleaned.reserveCapacity(options.count)

        for option in options {
            let normalizedID = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else { continue }
            let dedupeKey = normalizedID.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }

            let normalizedDisplayName = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.append(
                PromptRewriteModelOption(
                    id: normalizedID,
                    displayName: normalizedDisplayName.isEmpty ? normalizedID : normalizedDisplayName
                )
            )
        }

        return cleaned.sorted { lhs, rhs in
            let nameCompare = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameCompare == .orderedSame {
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
            return nameCompare == .orderedAscending
        }
    }

    private static func rewriteFriendlyModels(
        _ options: [PromptRewriteModelOption],
        providerMode: PromptRewriteProviderMode
    ) -> [PromptRewriteModelOption] {
        switch providerMode {
        case .openAI:
            let filtered = options.filter { option in
                isOpenAIRewriteFriendlyModelID(option.id)
            }
            return filtered.isEmpty ? options : filtered
        case .google:
            let filtered = options.filter { option in
                isGoogleRewriteFriendlyModelID(option.id)
            }
            return filtered.isEmpty ? options : filtered
        case .openRouter, .groq, .anthropic, .ollama:
            return options
        }
    }

    private static func providerSpecificFallbackCatalogModels(
        _ options: [PromptRewriteModelOption],
        providerMode: PromptRewriteProviderMode,
        preferOpenAIOAuthCatalog: Bool
    ) -> [PromptRewriteModelOption] {
        switch providerMode {
        case .openAI:
            if preferOpenAIOAuthCatalog {
                let oauthCompatible = normalizeModelOptions(
                    options.filter { isOpenAIOAuthCompatibleModelID($0.id) }
                )
                if !oauthCompatible.isEmpty {
                    return oauthCompatible
                }
                return buildModelOptions(ids: [defaultOpenAIOAuthModelID])
            }

            let rewriteFriendly = normalizeModelOptions(
                options.filter { isOpenAIRewriteFriendlyModelID($0.id) }
            )
            if !rewriteFriendly.isEmpty {
                return rewriteFriendly
            }
            return fallbackModels(for: .openAI)

        case .google:
            let rewriteFriendly = normalizeModelOptions(
                options.filter { isGoogleRewriteFriendlyModelID($0.id) }
            )
            if !rewriteFriendly.isEmpty {
                return rewriteFriendly
            }
            return fallbackModels(for: .google)

        case .openRouter, .groq, .anthropic, .ollama:
            if options.isEmpty {
                return fallbackModels(for: providerMode)
            }
            return normalizeModelOptions(options)
        }
    }

    private static func isOpenAIRewriteFriendlyModelID(_ modelID: String) -> Bool {
        let normalized = modelID.lowercased()
        if normalized.contains("codex") { return false }
        if normalized.contains("embedding") { return false }
        if normalized.contains("moderation") { return false }
        if normalized.contains("transcribe") || normalized.contains("whisper") { return false }
        if normalized.contains("tts") || normalized.contains("audio") { return false }
        return normalized.hasPrefix("gpt")
            || normalized.hasPrefix("o1")
            || normalized.hasPrefix("o3")
            || normalized.hasPrefix("o4")
    }

    private static func isGoogleRewriteFriendlyModelID(_ modelID: String) -> Bool {
        let normalized = modelID.lowercased()
        if !normalized.hasPrefix("gemini") { return false }
        if normalized.contains("embedding") { return false }
        if normalized.contains("vision") { return false }
        if normalized.contains("image") { return false }
        if normalized.contains("audio") { return false }
        if normalized.contains("tts") { return false }
        return true
    }

    private static let openAIOAuthPreferredModelIDs: [String] = [
        "gpt-5.2",
        "gpt-5.2-codex",
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark",
        "gpt-5.1-codex",
        "gpt-5.1-codex-max",
        "gpt-5.1-codex-mini"
    ]

    private static let openAIOAuthAllowedNonCodexModelIDs: Set<String> = [
        "gpt-5.2"
    ]

    static var defaultOpenAIOAuthModelID: String {
        openAIOAuthPreferredModelIDs[0]
    }

    static func isOpenAIOAuthCompatibleModelID(_ modelID: String) -> Bool {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.contains("codex") {
            return true
        }
        return openAIOAuthAllowedNonCodexModelIDs.contains(normalized)
    }

    static func preferredOpenAIOAuthModelID(in options: [PromptRewriteModelOption]) -> String? {
        guard !options.isEmpty else { return nil }

        let normalizedLookup = Dictionary(
            uniqueKeysWithValues: options.map { option in
                (option.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), option.id)
            }
        )

        for preferredID in openAIOAuthPreferredModelIDs {
            if let match = normalizedLookup[preferredID] {
                return match
            }
        }

        return options.first(where: { isOpenAIOAuthCompatibleModelID($0.id) })?.id
    }

    private static func openAIOAuthCompatibleModels(_ options: [PromptRewriteModelOption]) -> [PromptRewriteModelOption] {
        let filtered = options.filter { option in
            isOpenAIOAuthCompatibleModelID(option.id)
        }
        return filtered.isEmpty ? options : filtered
    }

    private static func mergeModelOptions(
        primary: [PromptRewriteModelOption],
        secondary: [PromptRewriteModelOption]
    ) -> [PromptRewriteModelOption] {
        normalizeModelOptions(primary + secondary)
    }

    static func fallbackModels(for providerMode: PromptRewriteProviderMode) -> [PromptRewriteModelOption] {
        let modelIDs: [String]
        switch providerMode {
        case .openAI:
            modelIDs = [
                "gpt-4.1-mini",
                "gpt-4.1",
                "gpt-4o-mini"
            ]
        case .google:
            modelIDs = [
                "gemini-3-flash-preview",
                "gemini-3-pro-preview",
                "gemini-3.1-pro-preview"
            ]
        case .openRouter:
            modelIDs = [
                "openai/gpt-4.1-mini",
                "anthropic/claude-3.5-sonnet"
            ]
        case .groq:
            modelIDs = [
                "llama-3.3-70b-versatile",
                "qwen/qwen3-32b"
            ]
        case .anthropic:
            modelIDs = [
                "claude-3-5-sonnet-latest",
                "claude-3-7-sonnet-latest"
            ]
        case .ollama:
            modelIDs = [
                "qwen2.5:3b",
                "llama3.2:3b",
                "gemma3:4b",
                "gemma2:2b",
                "llama3.1",
                "qwen2.5-coder:14b"
            ]
        }
        return buildModelOptions(ids: modelIDs)
    }

    private func isAPIKeyCredential(_ credential: Credential) -> Bool {
        if case .apiKey = credential {
            return true
        }
        return false
    }

    private func isOAuthCredential(_ credential: Credential) -> Bool {
        if case .oauth = credential {
            return true
        }
        return false
    }
}
