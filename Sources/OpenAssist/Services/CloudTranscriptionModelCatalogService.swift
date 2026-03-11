import Foundation

struct CloudTranscriptionModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String
}

struct CloudTranscriptionModelFetchResult {
    enum Source {
        case remote
        case fallback
    }

    let models: [CloudTranscriptionModelOption]
    let source: Source
    let message: String?
}

actor CloudTranscriptionModelCatalogService {
    static let shared = CloudTranscriptionModelCatalogService()
    private static let cachePrefix = "OpenAssist.cloudTranscriptionModelCatalogCache."

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
        provider: CloudTranscriptionProvider,
        baseURL: String,
        apiKey: String
    ) async -> CloudTranscriptionModelFetchResult {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        func fallbackResult(reason: String) async -> CloudTranscriptionModelFetchResult {
            let fallbackCatalogModels = await fallbackModels(for: provider)
            return CloudTranscriptionModelFetchResult(
                models: fallbackCatalogModels,
                source: .fallback,
                message: fallbackMessage(
                    providerName: provider.displayName,
                    fallbackCount: fallbackCatalogModels.count,
                    failureReason: reason
                )
            )
        }

        switch provider {
        case .openAI, .groq:
            guard !trimmedAPIKey.isEmpty else {
                return await fallbackResult(reason: "Add API key to load live transcription models.")
            }
            guard let endpoint = openAIModelsEndpoint(from: baseURL) else {
                return await fallbackResult(reason: "Invalid provider base URL.")
            }
            do {
                let remoteModels = try await fetchModelOptions(
                    endpoint: endpoint,
                    timeout: requestTimeout(for: provider),
                    headers: [("Authorization", "Bearer \(trimmedAPIKey)")]
                )
                let filteredModels = Self.transcriptionFriendlyModels(remoteModels, provider: provider)
                if !filteredModels.isEmpty {
                    cacheModels(filteredModels, for: provider)
                    return CloudTranscriptionModelFetchResult(
                        models: filteredModels,
                        source: .remote,
                        message: "Loaded \(filteredModels.count) \(provider.displayName) transcription models."
                    )
                }
                return await fallbackResult(reason: "\(provider.displayName) returned no transcription-suitable models.")
            } catch {
                return await fallbackResult(reason: "Could not load \(provider.displayName) models: \(error.localizedDescription)")
            }

        case .deepgram:
            guard !trimmedAPIKey.isEmpty else {
                return await fallbackResult(reason: "Add API key to load live Deepgram models.")
            }
            guard let endpoint = deepgramModelsEndpoint(from: baseURL) else {
                return await fallbackResult(reason: "Invalid Deepgram base URL.")
            }
            do {
                let remoteModels = try await fetchModelOptions(
                    endpoint: endpoint,
                    timeout: requestTimeout(for: provider),
                    headers: [("Authorization", "Token \(trimmedAPIKey)")]
                )
                let filteredModels = Self.transcriptionFriendlyModels(remoteModels, provider: provider)
                if !filteredModels.isEmpty {
                    cacheModels(filteredModels, for: provider)
                    return CloudTranscriptionModelFetchResult(
                        models: filteredModels,
                        source: .remote,
                        message: "Loaded \(filteredModels.count) Deepgram transcription models."
                    )
                }
                return await fallbackResult(reason: "Deepgram returned no transcription-suitable models.")
            } catch {
                return await fallbackResult(reason: "Could not load Deepgram models: \(error.localizedDescription)")
            }

        case .gemini:
            guard !trimmedAPIKey.isEmpty else {
                return await fallbackResult(reason: "Add API key to load live Gemini models.")
            }
            guard let endpoint = geminiModelsEndpoint(from: baseURL, apiKey: trimmedAPIKey) else {
                return await fallbackResult(reason: "Invalid Gemini base URL.")
            }
            do {
                let remoteModels = try await fetchModelOptions(
                    endpoint: endpoint,
                    timeout: requestTimeout(for: provider),
                    headers: []
                )
                let filteredModels = Self.transcriptionFriendlyModels(remoteModels, provider: provider)
                if !filteredModels.isEmpty {
                    cacheModels(filteredModels, for: provider)
                    return CloudTranscriptionModelFetchResult(
                        models: filteredModels,
                        source: .remote,
                        message: "Loaded \(filteredModels.count) Gemini models."
                    )
                }
                return await fallbackResult(reason: "Gemini returned no transcription-suitable models.")
            } catch {
                return await fallbackResult(reason: "Could not load Gemini models: \(error.localizedDescription)")
            }
        }
    }

    private func fallbackModels(for provider: CloudTranscriptionProvider) async -> [CloudTranscriptionModelOption] {
        let modelsDevProvider = Self.modelsDevProviderID(for: provider)
        let modelsDevModels = await fetchModelsDevProviderModels(providerID: modelsDevProvider)
        let filteredModelsDev = Self.transcriptionFriendlyModels(modelsDevModels, provider: provider)
        if !filteredModelsDev.isEmpty {
            cacheModels(filteredModelsDev, for: provider)
        }

        let cached = cachedModels(for: provider)
        let defaults = Self.providerDefaultModels(for: provider)
        return Self.mergeModelOptions(
            primary: Self.mergeModelOptions(primary: filteredModelsDev, secondary: cached),
            secondary: defaults
        )
    }

    private func fetchModelsDevProviderModels(providerID: String) async -> [CloudTranscriptionModelOption] {
        guard let url = URL(string: "https://models.dev/api.json") else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout(for: nil)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let providerPayload = root[providerID] as? [String: Any],
                  let modelPayload = providerPayload["models"] else {
                return []
            }

            if let modelsDictionary = modelPayload as? [String: Any] {
                var options: [CloudTranscriptionModelOption] = []
                options.reserveCapacity(modelsDictionary.count)

                for (modelID, rawValue) in modelsDictionary {
                    let displayName: String
                    if let dictionary = rawValue as? [String: Any] {
                        displayName = (dictionary["displayName"] as? String)
                            ?? (dictionary["name"] as? String)
                            ?? (dictionary["label"] as? String)
                            ?? (dictionary["title"] as? String)
                            ?? modelID
                    } else if let nameString = rawValue as? String, !nameString.isEmpty {
                        displayName = nameString
                    } else {
                        displayName = modelID
                    }

                    options.append(
                        CloudTranscriptionModelOption(
                            id: Self.normalizedModelID(modelID, for: nil),
                            displayName: displayName
                        )
                    )
                }

                return Self.normalizeModelOptions(options)
            }

            let promptModels = PromptRewriteModelCatalogService.parseModelOptions(
                from: try JSONSerialization.data(withJSONObject: modelPayload)
            )
            return Self.normalizeModelOptions(
                promptModels.map {
                    CloudTranscriptionModelOption(
                        id: Self.normalizedModelID($0.id, for: nil),
                        displayName: $0.displayName
                    )
                }
            )
        } catch {
            return []
        }
    }

    private func fetchModelOptions(
        endpoint: URL,
        timeout: TimeInterval,
        headers: [(String, String)]
    ) async throws -> [CloudTranscriptionModelOption] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
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

        let promptModels = PromptRewriteModelCatalogService.parseModelOptions(from: data)
        return Self.normalizeModelOptions(
            promptModels.map { option in
                CloudTranscriptionModelOption(
                    id: Self.normalizedModelID(option.id, for: nil),
                    displayName: option.displayName
                )
            }
        )
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

    private func cacheModels(_ models: [CloudTranscriptionModelOption], for provider: CloudTranscriptionProvider) {
        guard !models.isEmpty else { return }
        let payload = models.map { ["id": $0.id, "displayName": $0.displayName] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.cachePrefix + provider.rawValue)
    }

    private func cachedModels(for provider: CloudTranscriptionProvider) -> [CloudTranscriptionModelOption] {
        let key = Self.cachePrefix + provider.rawValue
        guard let data = UserDefaults.standard.data(forKey: key),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let rows = object as? [[String: Any]] else {
            return []
        }
        let options = rows.compactMap { row -> CloudTranscriptionModelOption? in
            guard let id = row["id"] as? String else { return nil }
            let displayName = (row["displayName"] as? String) ?? id
            return CloudTranscriptionModelOption(
                id: Self.normalizedModelID(id, for: nil),
                displayName: displayName
            )
        }
        return Self.normalizeModelOptions(options)
    }

    private static func providerDefaultModels(for provider: CloudTranscriptionProvider) -> [CloudTranscriptionModelOption] {
        let ids: [String]
        switch provider {
        case .openAI:
            ids = ["gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1"]
        case .groq:
            ids = ["whisper-large-v3-turbo", "whisper-large-v3", "distil-whisper-large-v3-en"]
        case .deepgram:
            ids = ["nova-3", "nova-2", "enhanced"]
        case .gemini:
            ids = ["gemini-2.5-flash", "gemini-2.0-flash", "gemini-1.5-pro"]
        }
        return normalizeModelOptions(
            ids.map {
                CloudTranscriptionModelOption(
                    id: normalizedModelID($0, for: provider),
                    displayName: displayName(forModelID: $0)
                )
            }
        )
    }

    private static func transcriptionFriendlyModels(
        _ options: [CloudTranscriptionModelOption],
        provider: CloudTranscriptionProvider
    ) -> [CloudTranscriptionModelOption] {
        let filtered = options.filter { option in
            let normalizedID = normalizedModelID(option.id, for: provider)
            let lowercasedID = normalizedID.lowercased()
            switch provider {
            case .openAI, .groq:
                let tokens = ["transcribe", "whisper", "stt", "speech-to-text"]
                return tokens.contains { lowercasedID.contains($0) }
            case .deepgram:
                let blockedTokens = ["aura", "tts", "speak", "voice-agent", "agent"]
                return !blockedTokens.contains { lowercasedID.contains($0) }
            case .gemini:
                guard lowercasedID.hasPrefix("gemini") else { return false }
                let blockedTokens = ["embedding", "imagen", "veo", "tts"]
                return !blockedTokens.contains { lowercasedID.contains($0) }
            }
        }
        return mergeModelOptions(
            primary: normalizeModelOptions(filtered),
            secondary: providerDefaultModels(for: provider)
        )
    }

    private static func mergeModelOptions(
        primary: [CloudTranscriptionModelOption],
        secondary: [CloudTranscriptionModelOption]
    ) -> [CloudTranscriptionModelOption] {
        normalizeModelOptions(primary + secondary)
    }

    private static func normalizeModelOptions(
        _ options: [CloudTranscriptionModelOption]
    ) -> [CloudTranscriptionModelOption] {
        var seen = Set<String>()
        var cleaned: [CloudTranscriptionModelOption] = []
        cleaned.reserveCapacity(options.count)

        for option in options {
            let normalizedID = normalizedModelID(option.id, for: nil)
            guard !normalizedID.isEmpty else { continue }
            let dedupeKey = normalizedID.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }

            let normalizedDisplayName = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.append(
                CloudTranscriptionModelOption(
                    id: normalizedID,
                    displayName: normalizedDisplayName.isEmpty ? displayName(forModelID: normalizedID) : normalizedDisplayName
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

    private static func normalizedModelID(_ modelID: String, for provider: CloudTranscriptionProvider?) -> String {
        var normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("models/") {
            normalized = String(normalized.dropFirst("models/".count))
        }
        if normalized.hasPrefix("model/") {
            normalized = String(normalized.dropFirst("model/".count))
        }
        if provider == .gemini, normalized.hasPrefix("publishers/") {
            let components = normalized.split(separator: "/")
            if let last = components.last {
                normalized = String(last)
            }
        }
        return normalized
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

    private static func modelsDevProviderID(for provider: CloudTranscriptionProvider) -> String {
        switch provider {
        case .openAI:
            return "openai"
        case .groq:
            return "groq"
        case .deepgram:
            return "deepgram"
        case .gemini:
            return "google"
        }
    }

    private func fallbackMessage(
        providerName: String,
        fallbackCount: Int,
        failureReason: String
    ) -> String {
        if fallbackCount > 0 {
            return "\(failureReason) Showing \(fallbackCount) online fallback models."
        }
        return "\(failureReason) No fallback models available."
    }

    private func requestTimeout(for provider: CloudTranscriptionProvider?) -> TimeInterval {
        let defaults = UserDefaults.standard
        let rawTimeout = defaults.object(forKey: "OpenAssist.cloudTranscriptionRequestTimeoutSeconds") == nil
            ? 30
            : defaults.double(forKey: "OpenAssist.cloudTranscriptionRequestTimeoutSeconds")
        let clampedTimeout = min(180, max(5, rawTimeout))
        switch provider {
        case .gemini:
            return min(180, max(12, clampedTimeout))
        case .openAI, .groq, .deepgram:
            return min(180, max(8, clampedTimeout))
        case .none:
            return min(180, max(8, clampedTimeout))
        }
    }

    private func openAIModelsEndpoint(from baseURL: String) -> URL? {
        guard let normalizedBase = normalizedBaseURL(from: baseURL) else {
            return nil
        }
        return URL(string: "\(normalizedBase)/models")
    }

    private func deepgramModelsEndpoint(from baseURL: String) -> URL? {
        guard var components = URLComponents(string: normalizedBaseURL(from: baseURL) ?? "") else {
            return nil
        }
        var path = components.path
        if path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        if path.hasSuffix("/listen") {
            path = String(path.dropLast("/listen".count))
        }
        if !path.hasSuffix("/v1") {
            if path.isEmpty {
                path = "/v1"
            } else {
                path += "/v1"
            }
        }
        path += "/models"
        components.path = path
        components.query = nil
        return components.url
    }

    private func geminiModelsEndpoint(from baseURL: String, apiKey: String) -> URL? {
        guard var components = URLComponents(string: normalizedBaseURL(from: baseURL) ?? "") else {
            return nil
        }
        var path = components.path
        if path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        if path.hasSuffix("/openai") {
            path = String(path.dropLast("/openai".count))
        }
        if path.isEmpty {
            path = "/models"
        } else {
            path += "/models"
        }
        components.path = path
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "key", value: apiKey))
        items.append(URLQueryItem(name: "pageSize", value: "200"))
        components.queryItems = items
        return components.url
    }

    private func normalizedBaseURL(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        let allowsInsecureLocalhost = scheme == "http" && Self.isLoopbackHost(host)
        guard scheme == "https" || allowsInsecureLocalhost else {
            return nil
        }

        components.query = nil
        components.fragment = nil

        var normalized = components.string ?? trimmed
        if normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        switch host {
        case "localhost", "127.0.0.1", "::1", "[::1]":
            return true
        default:
            return false
        }
    }
}
