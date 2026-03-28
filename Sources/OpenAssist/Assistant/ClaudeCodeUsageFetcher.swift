import Foundation

struct ClaudeCodeUsageSnapshot: Equatable {
    var rateLimits: AccountRateLimits
    var planType: String?
}

struct ClaudeCodeOAuthCredentials: Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let rateLimitTier: String?
    let subscriptionType: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(60)
    }
}

struct ClaudeCodeOAuthCredentialResolver {
    private let environment: [String: String]
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let keychain: CopilotKeychainReading
    private let applicationSupportDirectory: URL?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        keychain: CopilotKeychainReading = SystemCopilotKeychainReader(),
        applicationSupportDirectory: URL? = nil
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.keychain = keychain
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    func resolveCredentials() -> ClaudeCodeOAuthCredentials? {
        if let cached = loadOpenAssistCachedCredentials(), !cached.isExpired {
            return cached
        }

        if let stored = loadStoredCredentials() {
            persistCredentials(stored)
            return stored
        }

        if let cached = loadOpenAssistCachedCredentials() {
            return cached
        }

        guard Self.shouldAttemptKeychainBootstrap() else {
            return nil
        }

        guard let rawValue = keychain.loadToken(service: Self.keychainService, account: nil),
              let data = rawValue.data(using: .utf8),
              let credentials = parseCredentials(from: data) else {
            Self.deferKeychainBootstrap()
            return nil
        }
        Self.clearKeychainBootstrapCooldown()
        persistCredentials(credentials)
        return credentials
    }

    func persistCredentials(_ credentials: ClaudeCodeOAuthCredentials) {
        let cacheURL = openAssistCacheURL()
        let directoryURL = cacheURL.deletingLastPathComponent()
        let envelope = ClaudeCodeStoredCredentialsEnvelope(
            claudeAiOauth: ClaudeCodeStoredOAuthCredentials(
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken,
                expiresAt: credentials.expiresAt.map { $0.timeIntervalSince1970 * 1000.0 },
                rateLimitTier: credentials.rateLimitTier,
                subscriptionType: credentials.subscriptionType
            )
        )

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: cacheURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch {
            CrashReporter.logInfo("Claude Code credential cache persist failed: \(error.localizedDescription)")
        }
    }

    func clearCachedCredentials() {
        let cacheURL = openAssistCacheURL()
        guard fileManager.fileExists(atPath: cacheURL.path) else { return }
        do {
            try fileManager.removeItem(at: cacheURL)
        } catch {
            CrashReporter.logInfo("Claude Code credential cache removal failed: \(error.localizedDescription)")
        }
    }

    private func loadStoredCredentials() -> ClaudeCodeOAuthCredentials? {
        for url in candidateConfigURLs() {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            if let credentials = parseCredentials(from: data) {
                return credentials
            }
        }
        return nil
    }

    private func loadOpenAssistCachedCredentials() -> ClaudeCodeOAuthCredentials? {
        let cacheURL = openAssistCacheURL()
        guard fileManager.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }
        return parseCredentials(from: data)
    }

    private func candidateConfigURLs() -> [URL] {
        var urls: [URL] = []

        if let configuredRoots = environment["CLAUDE_CONFIG_DIR"]?
            .split(separator: ",")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty }) {
            urls.append(
                contentsOf: configuredRoots.map {
                    URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(".credentials.json")
                }
            )
        }

        if let xdgConfigHome = environment["XDG_CONFIG_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty {
            let baseURL = URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
            urls.append(
                baseURL
                    .appendingPathComponent("claude", isDirectory: true)
                    .appendingPathComponent(".credentials.json")
            )
        }

        urls.append(
            homeDirectory
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent(".credentials.json")
        )
        urls.append(
            homeDirectory
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("claude", isDirectory: true)
                .appendingPathComponent(".credentials.json")
        )

        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }

    private func parseCredentials(from data: Data) -> ClaudeCodeOAuthCredentials? {
        guard let envelope = try? JSONDecoder().decode(ClaudeCodeStoredCredentialsEnvelope.self, from: data),
              let oauth = envelope.claudeAiOauth,
              let accessToken = oauth.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        let expiresAt = oauth.expiresAt.map { rawValue in
            Date(timeIntervalSince1970: rawValue / 1000.0)
        }

        return ClaudeCodeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: oauth.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            expiresAt: expiresAt,
            rateLimitTier: oauth.rateLimitTier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            subscriptionType: oauth.subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        )
    }

    private func openAssistCacheURL() -> URL {
        let baseURL: URL
        if let applicationSupportDirectory {
            baseURL = applicationSupportDirectory
        } else if let discovered = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            baseURL = discovered
        } else {
            baseURL = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        }

        return baseURL
            .appendingPathComponent("OpenAssist", isDirectory: true)
            .appendingPathComponent("ClaudeCodeOAuthCache.json")
    }

    private static let keychainService = "Claude Code-credentials"
    private static let keychainBootstrapCooldown: TimeInterval = 300
    private static let keychainBootstrapLock = NSLock()
    private nonisolated(unsafe) static var nextKeychainBootstrapAt: Date?

    private static func shouldAttemptKeychainBootstrap(now: Date = Date()) -> Bool {
        keychainBootstrapLock.lock()
        defer { keychainBootstrapLock.unlock() }
        if let nextKeychainBootstrapAt, nextKeychainBootstrapAt > now {
            return false
        }
        return true
    }

    private static func deferKeychainBootstrap(now: Date = Date()) {
        keychainBootstrapLock.lock()
        nextKeychainBootstrapAt = now.addingTimeInterval(keychainBootstrapCooldown)
        keychainBootstrapLock.unlock()
    }

    private static func clearKeychainBootstrapCooldown() {
        keychainBootstrapLock.lock()
        nextKeychainBootstrapAt = nil
        keychainBootstrapLock.unlock()
    }
}

struct ClaudeCodeUsageFetcher {
    private let session: URLSession
    private let userAgent: String
    private let oauthClientID: String
    private let oauthTokenEndpoint: String

    init(
        session: URLSession = .shared,
        userAgent: String = Self.defaultUserAgent,
        oauthClientID: String = Self.defaultOAuthClientID,
        oauthTokenEndpoint: String = Self.defaultOAuthTokenEndpoint
    ) {
        self.session = session
        self.userAgent = userAgent
        self.oauthClientID = oauthClientID
        self.oauthTokenEndpoint = oauthTokenEndpoint
    }

    func fetchUsage(resolver: ClaudeCodeOAuthCredentialResolver) async throws -> ClaudeCodeUsageSnapshot? {
        guard var credentials = resolver.resolveCredentials() else {
            return nil
        }

        if credentials.isExpired, credentials.refreshToken?.nonEmpty != nil {
            credentials = try await refreshCredentials(credentials: credentials)
            resolver.persistCredentials(credentials)
        }

        do {
            return try await fetchUsage(credentials: credentials)
        } catch {
            guard isAuthenticationFailure(error),
                  credentials.refreshToken?.nonEmpty != nil else {
                throw error
            }

            let refreshed = try await refreshCredentials(credentials: credentials)
            resolver.persistCredentials(refreshed)
            return try await fetchUsage(credentials: refreshed)
        }
    }

    func fetchUsage(credentials: ClaudeCodeOAuthCredentials) async throws -> ClaudeCodeUsageSnapshot {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw URLError(.userAuthenticationRequired)
        }
        guard httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let usage = try JSONDecoder().decode(ClaudeCodeOAuthUsageResponse.self, from: data)
        let snapshot = mapUsageResponse(usage, planType: credentials.subscriptionType)
        guard !snapshot.rateLimits.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }
        return snapshot
    }

    func refreshCredentials(credentials: ClaudeCodeOAuthCredentials) async throws -> ClaudeCodeOAuthCredentials {
        guard let refreshToken = credentials.refreshToken?.nonEmpty,
              let endpoint = URL(string: oauthTokenEndpoint) else {
            throw URLError(.userAuthenticationRequired)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID
        ], options: [])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }
        guard let payload = try? JSONDecoder().decode(ClaudeCodeOAuthTokenResponse.self, from: data) else {
            throw URLError(.cannotDecodeContentData)
        }

        return ClaudeCodeOAuthCredentials(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: Date().addingTimeInterval(max(60, payload.expiresIn)),
            rateLimitTier: credentials.rateLimitTier,
            subscriptionType: credentials.subscriptionType
        )
    }

    private func mapUsageResponse(
        _ response: ClaudeCodeOAuthUsageResponse,
        planType: String?
    ) -> ClaudeCodeUsageSnapshot {
        let sessionWindow = makeWindow(response.fiveHour, windowDurationMins: 300)
        let weeklyWindow = makeWindow(response.sevenDay, windowDurationMins: 10_080)
        let sonnetWindow = makeWindow(
            response.sevenDaySonnet,
            windowDurationMins: 10_080,
            fallbackResetsAt: response.sevenDay?.resetsAt
        )
        let opusWindow = makeWindow(
            response.sevenDayOpus,
            windowDurationMins: 10_080,
            fallbackResetsAt: response.sevenDay?.resetsAt
        )

        var additionalBuckets: [AccountRateLimitBucket] = []
        if sessionWindow != nil || sonnetWindow != nil || weeklyWindow != nil {
            additionalBuckets.append(
                AccountRateLimitBucket(
                    limitID: "sonnet",
                    limitName: "Claude Sonnet",
                    primary: sessionWindow,
                    secondary: sonnetWindow ?? weeklyWindow,
                    hasCredits: true,
                    unlimited: false
                )
            )
        }
        if sessionWindow != nil || opusWindow != nil || weeklyWindow != nil {
            additionalBuckets.append(
                AccountRateLimitBucket(
                    limitID: "opus",
                    limitName: "Claude Opus",
                    primary: sessionWindow,
                    secondary: opusWindow ?? weeklyWindow,
                    hasCredits: true,
                    unlimited: false
                )
            )
        }

        return ClaudeCodeUsageSnapshot(
            rateLimits: AccountRateLimits(
                planType: planType?.nonEmpty,
                primary: sessionWindow,
                secondary: weeklyWindow,
                hasCredits: true,
                unlimited: false,
                limitID: "claude",
                limitName: "Claude Code",
                additionalBuckets: additionalBuckets
            ),
            planType: planType?.nonEmpty
        )
    }

    private func makeWindow(
        _ window: ClaudeCodeOAuthUsageWindow?,
        windowDurationMins: Int,
        fallbackResetsAt: String? = nil
    ) -> RateLimitWindow? {
        guard let utilization = window?.utilization else { return nil }

        var payload: [String: Any] = [
            "usedPercent": max(0, min(100, Int(utilization.rounded()))),
            "windowDurationMins": windowDurationMins
        ]
        if let resetsAt = parseISO8601Date(window?.resetsAt ?? fallbackResetsAt) {
            payload["resetsAt"] = Int(resetsAt.timeIntervalSince1970)
        }
        return RateLimitWindow(from: payload)
    }

    private func parseISO8601Date(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .userAuthenticationRequired
    }

    private static let defaultUserAgent = "claude-code/2.1.0"
    private static let defaultOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let defaultOAuthTokenEndpoint = "https://console.anthropic.com/v1/oauth/token"
}

private struct ClaudeCodeStoredCredentialsEnvelope: Codable {
    let claudeAiOauth: ClaudeCodeStoredOAuthCredentials?
}

private struct ClaudeCodeStoredOAuthCredentials: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: TimeInterval?
    let rateLimitTier: String?
    let subscriptionType: String?
}

private struct ClaudeCodeOAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct ClaudeCodeOAuthUsageResponse: Decodable {
    let fiveHour: ClaudeCodeOAuthUsageWindow?
    let sevenDay: ClaudeCodeOAuthUsageWindow?
    let sevenDaySonnet: ClaudeCodeOAuthUsageWindow?
    let sevenDayOpus: ClaudeCodeOAuthUsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
    }
}

private struct ClaudeCodeOAuthUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
