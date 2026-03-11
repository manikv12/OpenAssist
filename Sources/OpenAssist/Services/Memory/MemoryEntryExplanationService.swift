import Foundation
import Security

enum MemoryEntryExplanationResult {
    case success(String)
    case failure(String)
}

actor MemoryEntryExplanationService {
    static let shared = MemoryEntryExplanationService()

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
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func explain(entry: MemoryIndexedEntry) async -> MemoryEntryExplanationResult {
        guard let configuration = liveConfiguration() else {
            return .failure("Connect a provider first to explain memories with AI.")
        }

        let credential: ProviderCredential
        do {
            credential = try await resolveCredential(for: configuration)
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return .failure("Could not refresh provider authentication.")
            }
            return .failure("Could not refresh provider authentication: \(detail)")
        }

        if configuration.providerMode.requiresAPIKey {
            if case .none = credential {
                return .failure("No provider credentials available. Connect OAuth or add an API key.")
            }
        }

        let request: URLRequest
        do {
            request = try buildRequest(
                configuration: configuration,
                credential: credential,
                entry: entry
            )
        } catch {
            return .failure("Could not build explanation request. Check provider base URL.")
        }

        let isStreamingCodex = configuration.providerMode == .openAI && isOAuth(credential)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return .failure("Provider request failed.")
            }
            return .failure("Provider request failed: \(detail)")
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure("Provider returned an invalid response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = providerErrorDetail(from: data) ?? "HTTP \(http.statusCode)"
            return .failure("Provider request failed (\(http.statusCode)): \(detail)")
        }

        let content: String
        if isStreamingCodex {
            content = decodeSSEContent(data: data)
        } else if configuration.providerMode == .anthropic {
            content = decodeAnthropicContent(data: data)
        } else {
            content = decodeOpenAICompatibleContent(data: data)
        }
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return .failure("Provider returned an empty explanation.")
        }
        return .success(normalized)
    }

    private func buildRequest(
        configuration: LiveConfiguration,
        credential: ProviderCredential,
        entry: MemoryIndexedEntry
    ) throws -> URLRequest {
        let memoryInstructionSummary = summarizeMemoryInstruction(for: entry)
        let systemPrompt = """
        You explain a saved AI memory entry in simple terms for a non-technical user.
        Output plain text only.
        Include:
        1) what this memory is
        2) why it was saved
        3) when it should influence prompt rewriting
        Keep it concise and actionable.
        """

        let userPrompt = """
        Memory entry:
        - title: \(snippet(entry.title, limit: 220))
        - summary: \(snippet(entry.summary, limit: 400))
        - detail: \(snippet(entry.detail, limit: 3000))
        - provider: \(entry.provider.displayName)
        - source: \(snippet(entry.sourceRootPath, limit: 260))
        - source_file: \(snippet(entry.sourceFileRelativePath, limit: 260))
        - project: \(snippet(entry.projectName ?? "", limit: 160))
        - repository: \(snippet(entry.repositoryName ?? "", limit: 160))
        - updated_at: \(entry.updatedAt.formatted(date: .abbreviated, time: .standard))
        - is_plan_content: \(entry.isPlanContent ? "true" : "false")
        """

        let endpoint: URL?
        let payload: [String: Any]
        switch configuration.providerMode {
        case .openAI where isOAuth(credential):
            endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")
            payload = [
                "model": configuration.model,
                "store": false,
                "stream": true,
                "instructions": """
                \(systemPrompt)
                Memory summary instruction:
                \(memoryInstructionSummary)
                """,
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
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ]
            ]
        }

        guard let endpoint else {
            throw NSError(domain: "MemoryEntryExplanation", code: 1)
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            throw NSError(domain: "MemoryEntryExplanation", code: 2)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
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

    private func summarizeMemoryInstruction(for entry: MemoryIndexedEntry) -> String {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = entry.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            return "\(title.isEmpty ? "Untitled memory" : title): \(snippet(summary, limit: 220))"
        }
        if !detail.isEmpty {
            return "\(title.isEmpty ? "Untitled memory" : title): \(snippet(detail, limit: 220))"
        }
        return title.isEmpty ? "No memory content available." : title
    }

    private func resolveCredential(for configuration: LiveConfiguration) async throws -> ProviderCredential {
        if let oauthSession = configuration.oauthSession, configuration.providerMode.supportsOAuthSignIn {
            let refreshed = try await PromptRewriteProviderOAuthService.shared.refreshSessionIfNeeded(
                oauthSession,
                providerMode: configuration.providerMode
            )
            return .oauth(refreshed)
        }

        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            return .apiKey(apiKey)
        }
        return .none
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
        let hasCredentials = oauthSession != nil || !apiKey.isEmpty || !providerMode.requiresAPIKey
        guard hasCredentials else { return nil }

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

        if let contentString = message["content"] as? String {
            return contentString
        }
        if let contentArray = message["content"] as? [[String: Any]] {
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

    private func providerErrorDetail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let dictionary = object as? [String: Any] {
            if let detail = dictionary["error_description"] as? String {
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let detail = dictionary["error"] as? String {
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let error = dictionary["error"] as? [String: Any],
               let detail = error["message"] as? String {
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let message = dictionary["message"] as? String {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func snippet(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }
}
