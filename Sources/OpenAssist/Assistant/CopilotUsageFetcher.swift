import Foundation
import Security

struct CopilotUsageSnapshot: Equatable {
    var rateLimits: AccountRateLimits
    var planType: String?
}

protocol CopilotKeychainReading {
    func loadToken(service: String, account: String?) -> String?
}

struct SystemCopilotKeychainReader: CopilotKeychainReading {
    func loadToken(service: String, account: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account, !account.isEmpty {
            query[kSecAttrAccount as String] = account
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct CopilotTokenResolver {
    private let environment: [String: String]
    private let runner: CommandRunning
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let keychain: CopilotKeychainReading

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        keychain: CopilotKeychainReading = SystemCopilotKeychainReader()
    ) {
        self.environment = environment
        self.runner = runner
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.keychain = keychain
    }

    func resolveGitHubToken() async -> String? {
        if let environmentToken = preferredEnvironmentToken() {
            return environmentToken
        }

        if let storedToken = loadStoredCopilotToken() {
            return storedToken
        }

        return await loadGitHubCLIToken()
    }

    private func preferredEnvironmentToken() -> String? {
        for key in ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func loadStoredCopilotToken() -> String? {
        let config = loadStoredConfig()
        let accounts = storedAccounts(from: config)

        if config?.storeTokenPlaintext == true {
            for account in accounts {
                if let token = config?.copilotTokens?[account.storageKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !token.isEmpty {
                    return token
                }
            }

            if let fallback = config?.copilotTokens?.values
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                return fallback
            }
        }

        for account in accounts {
            if let token = keychain.loadToken(service: Self.copilotCLIKeychainService, account: account.storageKey) {
                return token
            }
        }

        return keychain.loadToken(service: Self.copilotCLIKeychainService, account: nil)
    }

    private func loadStoredConfig() -> CopilotStoredAuthConfig? {
        for url in candidateConfigURLs() {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            if let config = try? JSONDecoder().decode(CopilotStoredAuthConfig.self, from: data) {
                return config
            }
        }
        return nil
    }

    private func candidateConfigURLs() -> [URL] {
        var urls: [URL] = []
        if let xdgConfigHome = environment["XDG_CONFIG_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty {
            let baseURL = URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
            urls.append(baseURL.appendingPathComponent("config.json"))
            urls.append(
                baseURL
                    .appendingPathComponent("copilot", isDirectory: true)
                    .appendingPathComponent("config.json")
            )
        }

        urls.append(
            homeDirectory
                .appendingPathComponent(".copilot", isDirectory: true)
                .appendingPathComponent("config.json")
        )

        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }

    private func storedAccounts(from config: CopilotStoredAuthConfig?) -> [CopilotStoredAuthUser] {
        var ordered: [CopilotStoredAuthUser] = []
        var seen: Set<String> = []

        func append(_ user: CopilotStoredAuthUser?) {
            guard let user else { return }
            let key = user.storageKey.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            ordered.append(user)
        }

        append(config?.lastLoggedInUser)
        config?.loggedInUsers?.forEach(append)
        return ordered
    }

    private func loadGitHubCLIToken() async -> String? {
        let hostname = githubCLIHostname()
        do {
            let result = try await runner.run(
                "/usr/bin/env",
                arguments: ["gh", "auth", "token", "--hostname", hostname]
            )
            guard result.exitCode == 0 else { return nil }
            let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        } catch {
            return nil
        }
    }

    private func githubCLIHostname() -> String {
        guard let raw = environment["GH_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return "github.com"
        }
        if let url = URL(string: raw), let host = url.host?.nonEmpty {
            return host
        }
        return raw
    }

    private static let copilotCLIKeychainService = "copilot-cli"
}

struct CopilotUsageFetcher {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage(token: String) async throws -> CopilotUsageSnapshot {
        guard let url = URL(string: "https://api.github.com/copilot_internal/user") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")

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

        let usage = try JSONDecoder().decode(CopilotUsageResponse.self, from: data)
        let premium = makeRateLimitWindow(from: usage.quotaSnapshots.premiumInteractions)
        let chat = makeRateLimitWindow(from: usage.quotaSnapshots.chat)

        guard premium != nil || chat != nil else {
            throw URLError(.cannotDecodeContentData)
        }

        return CopilotUsageSnapshot(
            rateLimits: AccountRateLimits(
                planType: usage.copilotPlan.nonEmpty,
                primary: premium,
                secondary: chat,
                hasCredits: true,
                unlimited: (usage.quotaSnapshots.premiumInteractions?.unlimited ?? false)
                    && (usage.quotaSnapshots.chat?.unlimited ?? false),
                limitID: "copilot",
                limitName: "Copilot",
                additionalBuckets: []
            ),
            planType: usage.copilotPlan.nonEmpty
        )
    }

    private func makeRateLimitWindow(from snapshot: CopilotUsageResponse.QuotaSnapshot?) -> RateLimitWindow? {
        guard let snapshot else { return nil }
        guard !snapshot.isPlaceholder else { return nil }
        guard snapshot.hasPercentRemaining else { return nil }
        return RateLimitWindow(from: [
            "usedPercent": Int((100 - snapshot.percentRemaining).rounded())
        ])
    }
}

private struct CopilotStoredAuthConfig: Decodable {
    let lastLoggedInUser: CopilotStoredAuthUser?
    let loggedInUsers: [CopilotStoredAuthUser]?
    let storeTokenPlaintext: Bool?
    let copilotTokens: [String: String]?

    enum CodingKeys: String, CodingKey {
        case lastLoggedInUser = "last_logged_in_user"
        case loggedInUsers = "logged_in_users"
        case storeTokenPlaintext = "store_token_plaintext"
        case copilotTokens = "copilot_tokens"
    }
}

private struct CopilotStoredAuthUser: Decodable {
    let host: String
    let login: String

    var storageKey: String {
        "\(host):\(login)"
    }
}

private struct CopilotUsageResponse: Decodable {
    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    struct QuotaSnapshot: Decodable {
        let entitlement: Double
        let remaining: Double
        let percentRemaining: Double
        let quotaID: String
        let unlimited: Bool
        let hasPercentRemaining: Bool

        var isPlaceholder: Bool {
            entitlement == 0 && remaining == 0 && percentRemaining == 0 && quotaID.isEmpty
        }

        enum CodingKeys: String, CodingKey {
            case entitlement
            case remaining
            case percentRemaining = "percent_remaining"
            case quotaID = "quota_id"
            case unlimited
        }

        init(
            entitlement: Double,
            remaining: Double,
            percentRemaining: Double,
            quotaID: String,
            unlimited: Bool,
            hasPercentRemaining: Bool = true
        ) {
            self.entitlement = entitlement
            self.remaining = remaining
            self.percentRemaining = percentRemaining
            self.quotaID = quotaID
            self.unlimited = unlimited
            self.hasPercentRemaining = hasPercentRemaining
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedEntitlement = Self.decodeNumberIfPresent(container: container, key: .entitlement)
            let decodedRemaining = Self.decodeNumberIfPresent(container: container, key: .remaining)
            entitlement = decodedEntitlement ?? 0
            remaining = decodedRemaining ?? 0

            let decodedPercent = Self.decodeNumberIfPresent(container: container, key: .percentRemaining)
            if let decodedPercent {
                percentRemaining = max(0, min(100, decodedPercent))
                hasPercentRemaining = true
            } else if let decodedEntitlement,
                      decodedEntitlement > 0,
                      let decodedRemaining {
                percentRemaining = max(0, min(100, (decodedRemaining / decodedEntitlement) * 100))
                hasPercentRemaining = true
            } else {
                percentRemaining = 0
                hasPercentRemaining = false
            }

            quotaID = try container.decodeIfPresent(String.self, forKey: .quotaID) ?? ""
            unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
        }

        private static func decodeNumberIfPresent(
            container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> Double? {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Double(value)
            }
            return nil
        }
    }

    struct QuotaCounts: Decodable {
        let chat: Double?
        let completions: Double?

        enum CodingKeys: String, CodingKey {
            case chat
            case completions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            chat = Self.decodeNumberIfPresent(container: container, key: .chat)
            completions = Self.decodeNumberIfPresent(container: container, key: .completions)
        }

        private static func decodeNumberIfPresent(
            container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> Double? {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Double(value)
            }
            return nil
        }
    }

    struct QuotaSnapshots: Decodable {
        let premiumInteractions: QuotaSnapshot?
        let chat: QuotaSnapshot?

        enum CodingKeys: String, CodingKey {
            case premiumInteractions = "premium_interactions"
            case chat
        }

        init(premiumInteractions: QuotaSnapshot?, chat: QuotaSnapshot?) {
            self.premiumInteractions = premiumInteractions
            self.chat = chat
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var premium = try container.decodeIfPresent(QuotaSnapshot.self, forKey: .premiumInteractions)
            var chat = try container.decodeIfPresent(QuotaSnapshot.self, forKey: .chat)

            if premium?.isPlaceholder == true {
                premium = nil
            }
            if chat?.isPlaceholder == true {
                chat = nil
            }

            if premium == nil || chat == nil {
                let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
                var fallbackPremium: QuotaSnapshot?
                var fallbackChat: QuotaSnapshot?
                var firstUsable: QuotaSnapshot?

                for key in dynamic.allKeys {
                    guard let snapshot = try? dynamic.decodeIfPresent(QuotaSnapshot.self, forKey: key),
                          !snapshot.isPlaceholder else {
                        continue
                    }

                    let keyName = key.stringValue.lowercased()
                    if firstUsable == nil {
                        firstUsable = snapshot
                    }

                    if fallbackChat == nil, keyName.contains("chat") {
                        fallbackChat = snapshot
                        continue
                    }

                    if fallbackPremium == nil,
                       keyName.contains("premium") || keyName.contains("completion") || keyName.contains("code") {
                        fallbackPremium = snapshot
                    }
                }

                if premium == nil {
                    premium = fallbackPremium
                }
                if chat == nil {
                    chat = fallbackChat
                }
                if premium == nil, chat == nil {
                    chat = firstUsable
                }
            }

            premiumInteractions = premium
            self.chat = chat
        }
    }

    let quotaSnapshots: QuotaSnapshots
    let copilotPlan: String

    enum CodingKeys: String, CodingKey {
        case quotaSnapshots = "quota_snapshots"
        case copilotPlan = "copilot_plan"
        case monthlyQuotas = "monthly_quotas"
        case limitedUserQuotas = "limited_user_quotas"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let directSnapshots = try container.decodeIfPresent(QuotaSnapshots.self, forKey: .quotaSnapshots)
        let monthlyQuotas = try container.decodeIfPresent(QuotaCounts.self, forKey: .monthlyQuotas)
        let limitedUserQuotas = try container.decodeIfPresent(QuotaCounts.self, forKey: .limitedUserQuotas)
        let fallbackSnapshots = Self.makeQuotaSnapshots(monthly: monthlyQuotas, limited: limitedUserQuotas)

        let premium = Self.usableQuotaSnapshot(from: directSnapshots?.premiumInteractions)
            ?? Self.usableQuotaSnapshot(from: fallbackSnapshots?.premiumInteractions)
        let chat = Self.usableQuotaSnapshot(from: directSnapshots?.chat)
            ?? Self.usableQuotaSnapshot(from: fallbackSnapshots?.chat)

        if premium != nil || chat != nil {
            quotaSnapshots = QuotaSnapshots(premiumInteractions: premium, chat: chat)
        } else {
            quotaSnapshots = directSnapshots ?? QuotaSnapshots(premiumInteractions: nil, chat: nil)
        }

        copilotPlan = try container.decodeIfPresent(String.self, forKey: .copilotPlan) ?? "unknown"
    }

    private static func makeQuotaSnapshots(
        monthly: QuotaCounts?,
        limited: QuotaCounts?
    ) -> QuotaSnapshots? {
        let premium = makeQuotaSnapshot(
            monthly: monthly?.completions,
            limited: limited?.completions,
            quotaID: "completions"
        )
        let chat = makeQuotaSnapshot(
            monthly: monthly?.chat,
            limited: limited?.chat,
            quotaID: "chat"
        )
        guard premium != nil || chat != nil else { return nil }
        return QuotaSnapshots(premiumInteractions: premium, chat: chat)
    }

    private static func makeQuotaSnapshot(
        monthly: Double?,
        limited: Double?,
        quotaID: String
    ) -> QuotaSnapshot? {
        guard let monthly, let limited else { return nil }
        guard monthly > 0 else { return nil }

        return QuotaSnapshot(
            entitlement: max(0, monthly),
            remaining: max(0, limited),
            percentRemaining: max(0, min(100, (limited / monthly) * 100)),
            quotaID: quotaID,
            unlimited: false
        )
    }

    private static func usableQuotaSnapshot(from snapshot: QuotaSnapshot?) -> QuotaSnapshot? {
        guard let snapshot, !snapshot.isPlaceholder, snapshot.hasPercentRemaining else {
            return nil
        }
        return snapshot
    }
}
