import CryptoKit
import Foundation
import Security

extension PromptRewriteProviderMode {
    var supportsOAuthSignIn: Bool {
        switch self {
        case .openAI, .anthropic:
            return true
        case .google, .openRouter, .groq, .ollama:
            return false
        }
    }

    var oauthPlanLabel: String? {
        switch self {
        case .openAI:
            return "ChatGPT Plus/Pro"
        case .anthropic:
            return "Claude Pro/Max"
        case .google, .openRouter, .groq, .ollama:
            return nil
        }
    }
}

struct PromptRewriteOAuthSession: Codable, Equatable {
    var providerID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: TimeInterval
    var accountID: String?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval

    var isExpired: Bool {
        expiresAt <= Date().timeIntervalSince1970 + 30
    }
}

enum PromptRewriteOAuthCredentialStore {
    private static let keychainService = "com.manikvashith.OpenAssist"
    private static let accountPrefix = "prompt-rewrite-provider-oauth"

    static func loadSession(for providerMode: PromptRewriteProviderMode) -> PromptRewriteOAuthSession? {
        guard providerMode.supportsOAuthSignIn else { return nil }
        guard let data = loadData(forAccount: account(for: providerMode)),
              var session = try? JSONDecoder().decode(PromptRewriteOAuthSession.self, from: data) else {
            return nil
        }
        let expectedProviderID = normalizedProviderID(for: providerMode)
        if session.providerID != expectedProviderID {
            session.providerID = expectedProviderID
        }
        return session
    }

    static func storeSession(_ session: PromptRewriteOAuthSession, for providerMode: PromptRewriteProviderMode) {
        guard providerMode.supportsOAuthSignIn else { return }
        guard let data = try? JSONEncoder().encode(session) else { return }
        storeData(data, forAccount: account(for: providerMode))
    }

    static func deleteSession(for providerMode: PromptRewriteProviderMode) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account(for: providerMode)
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    static func deleteAllSessions() {
        for providerMode in PromptRewriteProviderMode.allCases where providerMode.supportsOAuthSignIn {
            deleteSession(for: providerMode)
        }
    }

    private static func account(for providerMode: PromptRewriteProviderMode) -> String {
        "\(accountPrefix).\(normalizedProviderID(for: providerMode))"
    }

    private static func normalizedProviderID(for providerMode: PromptRewriteProviderMode) -> String {
        providerMode.rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }

    private static func loadData(forAccount account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func storeData(_ data: Data, forAccount account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let update = [
            kSecValueData as String: data
        ] as CFDictionary
        let updateStatus = SecItemUpdate(query as CFDictionary, update)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            _ = SecItemAdd(create as CFDictionary, nil)
        }
    }
}

enum PromptRewriteProviderOAuthError: LocalizedError {
    case unsupportedProvider
    case canceledByUser
    case invalidProviderResponse
    case invalidAuthorizationInput
    case timedOut
    case tokenExchangeFailed(message: String)
    case refreshFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "OAuth is not supported for this provider."
        case .canceledByUser:
            return "Sign-in canceled."
        case .invalidProviderResponse:
            return "Provider returned an invalid response."
        case .invalidAuthorizationInput:
            return "Authorization code is invalid."
        case .timedOut:
            return "Authorization timed out."
        case let .tokenExchangeFailed(message):
            return "Token exchange failed: \(message)"
        case let .refreshFailed(message):
            return "Token refresh failed: \(message)"
        }
    }
}

actor PromptRewriteProviderOAuthService {
    struct OpenAIDeviceAuthorizationContext {
        let verificationURL: URL
        let userCode: String
        let deviceAuthID: String
        let pollIntervalSeconds: TimeInterval
    }

    struct AnthropicAuthorizationContext {
        let authorizationURL: URL
        let verifier: String
        let instructions: String
    }

    static let shared = PromptRewriteProviderOAuthService()

    private let session: URLSession

    private init(session: URLSession = .shared) {
        self.session = session
    }

    // Mirrors OpenCode's OpenAI/Codex OAuth device flow.
    private let openAIClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let openAIIssuer = "https://auth.openai.com"
    private let openAIDeviceTimeoutSeconds: TimeInterval = 5 * 60
    private let openAIPollingSafetyMarginSeconds: TimeInterval = 3

    // Mirrors OpenCode's Anthropic OAuth plugin flow for Claude Pro/Max subscriptions.
    private let anthropicClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let anthropicTokenEndpoint = "https://console.anthropic.com/v1/oauth/token"
    private let anthropicRedirectURI = "https://console.anthropic.com/oauth/code/callback"

    func beginOpenAIDeviceAuthorization() async throws -> OpenAIDeviceAuthorizationContext {
        let endpoint = URL(string: "\(openAIIssuer)/api/accounts/deviceauth/usercode")
        guard let endpoint else { throw PromptRewriteProviderOAuthError.invalidProviderResponse }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": openAIClientID
        ], options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }
        guard (200...299).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(OpenAIDeviceAuthResponse.self, from: data) else {
            throw PromptRewriteProviderOAuthError.tokenExchangeFailed(
                message: providerErrorDetail(from: data) ?? "HTTP \(http.statusCode)"
            )
        }

        let intervalSeconds = max(1, Double(Int(payload.interval ?? "5") ?? 5))
        guard let verificationURL = URL(string: "\(openAIIssuer)/codex/device") else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }

        return OpenAIDeviceAuthorizationContext(
            verificationURL: verificationURL,
            userCode: payload.userCode,
            deviceAuthID: payload.deviceAuthID,
            pollIntervalSeconds: intervalSeconds
        )
    }

    func completeOpenAIDeviceAuthorization(
        _ context: OpenAIDeviceAuthorizationContext
    ) async throws -> PromptRewriteOAuthSession {
        let timeoutDate = Date().addingTimeInterval(openAIDeviceTimeoutSeconds)
        var interval = context.pollIntervalSeconds

        while Date() < timeoutDate {
            let result = try await pollOpenAIDeviceToken(
                deviceAuthID: context.deviceAuthID,
                userCode: context.userCode
            )
            switch result {
            case .pending:
                try await Task.sleep(
                    nanoseconds: UInt64((interval + openAIPollingSafetyMarginSeconds) * 1_000_000_000)
                )
                continue
            case let .slowDown(serverInterval):
                if let serverInterval, serverInterval > 0 {
                    interval = serverInterval
                } else {
                    interval += 5
                }
                try await Task.sleep(
                    nanoseconds: UInt64((interval + openAIPollingSafetyMarginSeconds) * 1_000_000_000)
                )
                continue
            case let .authorized(code, verifier):
                let tokenPayload = try await exchangeOpenAIAuthorizationCode(code: code, verifier: verifier)
                let accountID = extractOpenAIAccountID(from: tokenPayload)
                let now = Date().timeIntervalSince1970
                let expiresAt = now + max(60, tokenPayload.expiresIn ?? 3600)
                let auth = PromptRewriteOAuthSession(
                    providerID: "openai",
                    accessToken: tokenPayload.accessToken,
                    refreshToken: tokenPayload.refreshToken,
                    expiresAt: expiresAt,
                    accountID: accountID,
                    createdAt: now,
                    updatedAt: now
                )
                PromptRewriteOAuthCredentialStore.storeSession(auth, for: .openAI)
                return auth
            case let .failed(message):
                throw PromptRewriteProviderOAuthError.tokenExchangeFailed(message: message)
            }
        }

        throw PromptRewriteProviderOAuthError.timedOut
    }

    func beginAnthropicAuthorization() async throws -> AnthropicAuthorizationContext {
        let verifier = randomURLSafeString(length: 48)
        let challenge = base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))

        guard var components = URLComponents(string: "https://claude.ai/oauth/authorize") else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }
        components.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: anthropicClientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: anthropicRedirectURI),
            .init(name: "scope", value: "org:create_api_key user:profile user:inference"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: verifier)
        ]
        guard let authorizationURL = components.url else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }

        return AnthropicAuthorizationContext(
            authorizationURL: authorizationURL,
            verifier: verifier,
            instructions: "After approving in browser, paste the returned code."
        )
    }

    func completeAnthropicAuthorization(
        _ context: AnthropicAuthorizationContext,
        codeInput: String
    ) async throws -> PromptRewriteOAuthSession {
        let parsedInput = parseAnthropicCodeInput(codeInput, fallbackState: context.verifier)
        guard !parsedInput.code.isEmpty else {
            throw PromptRewriteProviderOAuthError.invalidAuthorizationInput
        }

        let body: [String: Any] = [
            "code": parsedInput.code,
            "state": parsedInput.state,
            "grant_type": "authorization_code",
            "client_id": anthropicClientID,
            "redirect_uri": anthropicRedirectURI,
            "code_verifier": context.verifier
        ]

        guard let endpoint = URL(string: anthropicTokenEndpoint) else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }
        guard (200...299).contains(http.statusCode),
              let tokenPayload = try? JSONDecoder().decode(AnthropicTokenResponse.self, from: data) else {
            throw PromptRewriteProviderOAuthError.tokenExchangeFailed(
                message: providerErrorDetail(from: data) ?? "HTTP \(http.statusCode)"
            )
        }

        let now = Date().timeIntervalSince1970
        let auth = PromptRewriteOAuthSession(
            providerID: "anthropic",
            accessToken: tokenPayload.accessToken,
            refreshToken: tokenPayload.refreshToken,
            expiresAt: now + max(60, tokenPayload.expiresIn),
            accountID: nil,
            createdAt: now,
            updatedAt: now
        )
        PromptRewriteOAuthCredentialStore.storeSession(auth, for: .anthropic)
        return auth
    }

    func refreshSessionIfNeeded(
        _ sessionState: PromptRewriteOAuthSession,
        providerMode: PromptRewriteProviderMode
    ) async throws -> PromptRewriteOAuthSession {
        guard providerMode.supportsOAuthSignIn else {
            throw PromptRewriteProviderOAuthError.unsupportedProvider
        }
        guard sessionState.isExpired else {
            return sessionState
        }
        switch providerMode {
        case .openAI:
            let refreshed = try await refreshOpenAISession(sessionState)
            PromptRewriteOAuthCredentialStore.storeSession(refreshed, for: .openAI)
            return refreshed
        case .anthropic:
            let refreshed = try await refreshAnthropicSession(sessionState)
            PromptRewriteOAuthCredentialStore.storeSession(refreshed, for: .anthropic)
            return refreshed
        case .google, .openRouter, .groq, .ollama:
            throw PromptRewriteProviderOAuthError.unsupportedProvider
        }
    }

    func clearSession(for providerMode: PromptRewriteProviderMode) {
        PromptRewriteOAuthCredentialStore.deleteSession(for: providerMode)
    }

    private func refreshOpenAISession(_ existing: PromptRewriteOAuthSession) async throws -> PromptRewriteOAuthSession {
        guard let endpoint = URL(string: "\(openAIIssuer)/oauth/token") else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = urlEncodedBody([
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: existing.refreshToken),
            URLQueryItem(name: "client_id", value: openAIClientID)
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }
        guard (200...299).contains(http.statusCode),
              let tokenPayload = try? JSONDecoder().decode(OpenAITokenResponse.self, from: data) else {
            throw PromptRewriteProviderOAuthError.refreshFailed(
                message: providerErrorDetail(from: data) ?? "HTTP \(http.statusCode)"
            )
        }

        let accountID = extractOpenAIAccountID(from: tokenPayload) ?? existing.accountID
        let now = Date().timeIntervalSince1970
        return PromptRewriteOAuthSession(
            providerID: existing.providerID,
            accessToken: tokenPayload.accessToken,
            refreshToken: tokenPayload.refreshToken,
            expiresAt: now + max(60, tokenPayload.expiresIn ?? 3600),
            accountID: accountID,
            createdAt: existing.createdAt,
            updatedAt: now
        )
    }

    private func refreshAnthropicSession(_ existing: PromptRewriteOAuthSession) async throws -> PromptRewriteOAuthSession {
        guard let endpoint = URL(string: anthropicTokenEndpoint) else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": existing.refreshToken,
            "client_id": anthropicClientID
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }
        guard (200...299).contains(http.statusCode),
              let tokenPayload = try? JSONDecoder().decode(AnthropicTokenResponse.self, from: data) else {
            throw PromptRewriteProviderOAuthError.refreshFailed(
                message: providerErrorDetail(from: data) ?? "HTTP \(http.statusCode)"
            )
        }

        let now = Date().timeIntervalSince1970
        return PromptRewriteOAuthSession(
            providerID: existing.providerID,
            accessToken: tokenPayload.accessToken,
            refreshToken: tokenPayload.refreshToken,
            expiresAt: now + max(60, tokenPayload.expiresIn),
            accountID: existing.accountID,
            createdAt: existing.createdAt,
            updatedAt: now
        )
    }

    private enum OpenAIDevicePollResult {
        case pending
        case slowDown(intervalSeconds: TimeInterval?)
        case authorized(code: String, verifier: String)
        case failed(message: String)
    }

    private func pollOpenAIDeviceToken(
        deviceAuthID: String,
        userCode: String
    ) async throws -> OpenAIDevicePollResult {
        guard let endpoint = URL(string: "\(openAIIssuer)/api/accounts/deviceauth/token") else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_auth_id": deviceAuthID,
            "user_code": userCode
        ], options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }

        if http.statusCode == 200,
           let payload = try? JSONDecoder().decode(OpenAIDeviceTokenResponse.self, from: data) {
            return .authorized(code: payload.authorizationCode, verifier: payload.codeVerifier)
        }

        if http.statusCode == 403 || http.statusCode == 404 {
            return .pending
        }

        if http.statusCode == 429 {
            let payload = try? JSONDecoder().decode(OpenAIPollingErrorResponse.self, from: data)
            let interval = payload?.interval.flatMap { Double($0) }
            return .slowDown(intervalSeconds: interval)
        }

        let message = providerErrorDetail(from: data) ?? "HTTP \(http.statusCode)"
        return .failed(message: message)
    }

    private func exchangeOpenAIAuthorizationCode(
        code: String,
        verifier: String
    ) async throws -> OpenAITokenResponse {
        guard let endpoint = URL(string: "\(openAIIssuer)/oauth/token") else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = urlEncodedBody([
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: "\(openAIIssuer)/deviceauth/callback"),
            URLQueryItem(name: "client_id", value: openAIClientID),
            URLQueryItem(name: "code_verifier", value: verifier)
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PromptRewriteProviderOAuthError.invalidProviderResponse
        }
        guard (200...299).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(OpenAITokenResponse.self, from: data) else {
            throw PromptRewriteProviderOAuthError.tokenExchangeFailed(
                message: providerErrorDetail(from: data) ?? "HTTP \(http.statusCode)"
            )
        }
        return payload
    }

    private func parseAnthropicCodeInput(
        _ input: String,
        fallbackState: String
    ) -> (code: String, state: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ("", fallbackState)
        }

        if let components = URLComponents(string: trimmed), let queryItems = components.queryItems {
            let code = queryItems.first(where: { $0.name == "code" })?.value ?? ""
            let state = queryItems.first(where: { $0.name == "state" })?.value ?? fallbackState
            if !code.isEmpty {
                return (code, state)
            }
        }

        if trimmed.contains("#") {
            let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let code = String(parts.first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let state = (parts.count > 1 ? String(parts[1]) : fallbackState)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (code, state.isEmpty ? fallbackState : state)
        }

        return (trimmed, fallbackState)
    }

    private func extractOpenAIAccountID(from payload: OpenAITokenResponse) -> String? {
        if let idToken = payload.idToken,
           let claims = decodeJWTPayload(token: idToken),
           let accountID = extractAccountID(from: claims) {
            return accountID
        }
        if let claims = decodeJWTPayload(token: payload.accessToken) {
            return extractAccountID(from: claims)
        }
        return nil
    }

    private func decodeJWTPayload(token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let payloadSegment = String(parts[1])
        let padded = payloadSegment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .padding(toLength: ((payloadSegment.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        guard let data = Data(base64Encoded: padded),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let claims = object as? [String: Any] else {
            return nil
        }
        return claims
    }

    private func extractAccountID(from claims: [String: Any]) -> String? {
        if let direct = claims["chatgpt_account_id"] as? String,
           !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return direct
        }
        if let authNamespace = claims["https://api.openai.com/auth"] as? [String: Any],
           let nested = authNamespace["chatgpt_account_id"] as? String,
           !nested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nested
        }
        if let organizations = claims["organizations"] as? [[String: Any]],
           let firstID = organizations.first?["id"] as? String,
           !firstID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return firstID
        }
        return nil
    }

    private func randomURLSafeString(length: Int) -> String {
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: max(1, length))
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func urlEncodedBody(_ queryItems: [URLQueryItem]) -> Data? {
        var components = URLComponents()
        components.queryItems = queryItems
        return components.query?.data(using: .utf8)
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
            if let error = dictionary["error"] as? [String: Any] {
                if let detail = error["message"] as? String {
                    let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            if let message = dictionary["message"] as? String {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct OpenAIDeviceAuthResponse: Decodable {
    let deviceAuthID: String
    let userCode: String
    let interval: String?

    enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
        case interval
    }
}

private struct OpenAIDeviceTokenResponse: Decodable {
    let authorizationCode: String
    let codeVerifier: String

    enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeVerifier = "code_verifier"
    }
}

private struct OpenAIPollingErrorResponse: Decodable {
    let interval: String?
}

private struct OpenAITokenResponse: Decodable {
    let idToken: String?
    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct AnthropicTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
