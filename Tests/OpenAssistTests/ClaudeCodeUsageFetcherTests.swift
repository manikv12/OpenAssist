import Foundation
import XCTest
@testable import OpenAssist

final class ClaudeCodeUsageFetcherTests: XCTestCase {
    override func tearDown() {
        ClaudeCodeUsageURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testFetcherMapsClaudeUsageResponseIntoRateLimits() async throws {
        let session = makeStubbedSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer claude-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "claude-code/2.1.0")

            let body = #"""
            {
              "five_hour": {
                "utilization": 12,
                "resets_at": "2026-04-01T12:00:00.000Z"
              },
              "seven_day": {
                "utilization": 30,
                "resets_at": "2026-04-05T00:00:00.000Z"
              },
              "seven_day_sonnet": {
                "utilization": 5
              },
              "seven_day_opus": {
                "utilization": 42
              }
            }
            """#

            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }

        let snapshot = try await ClaudeCodeUsageFetcher(session: session).fetchUsage(
            credentials: ClaudeCodeOAuthCredentials(
                accessToken: "claude-token",
                refreshToken: nil,
                expiresAt: nil,
                rateLimitTier: "team",
                subscriptionType: "team"
            )
        )

        XCTAssertEqual(snapshot.planType, "team")
        XCTAssertEqual(snapshot.rateLimits.planType, "team")
        XCTAssertEqual(snapshot.rateLimits.limitID, "claude")
        XCTAssertEqual(snapshot.rateLimits.primary?.usedPercent, 12)
        XCTAssertEqual(snapshot.rateLimits.primary?.windowDurationMins, 300)
        XCTAssertEqual(snapshot.rateLimits.secondary?.usedPercent, 30)
        XCTAssertEqual(snapshot.rateLimits.secondary?.windowDurationMins, 10_080)
        XCTAssertEqual(snapshot.rateLimits.bucket(for: "sonnet")?.secondary?.usedPercent, 5)
        XCTAssertEqual(snapshot.rateLimits.bucket(for: "opus")?.secondary?.usedPercent, 42)
        XCTAssertEqual(
            snapshot.rateLimits.bucket(for: "opus")?.secondary?.resetsAt,
            snapshot.rateLimits.secondary?.resetsAt
        )
    }

    func testFetcherFallsBackToGenericWeeklyWindowWhenModelSpecificWeeklyIsMissing() async throws {
        let session = makeStubbedSession { request in
            let body = #"""
            {
              "five_hour": {
                "utilization": 4,
                "resets_at": "2026-04-01T12:00:00.000Z"
              },
              "seven_day": {
                "utilization": 61,
                "resets_at": "2026-04-05T00:00:00.000Z"
              }
            }
            """#

            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }

        let snapshot = try await ClaudeCodeUsageFetcher(session: session).fetchUsage(
            credentials: ClaudeCodeOAuthCredentials(
                accessToken: "claude-token",
                refreshToken: nil,
                expiresAt: nil,
                rateLimitTier: "team",
                subscriptionType: "team"
            )
        )

        let opusBucket = try XCTUnwrap(snapshot.rateLimits.bucket(for: "opus"))
        XCTAssertEqual(opusBucket.primary?.usedPercent, 4)
        XCTAssertEqual(opusBucket.secondary?.usedPercent, 61)
        XCTAssertEqual(opusBucket.secondary?.windowDurationMins, 10_080)
        XCTAssertEqual(opusBucket.secondary?.resetsAt, snapshot.rateLimits.secondary?.resetsAt)
    }

    func testCredentialResolverReadsClaudeCredentialsFromConfig() throws {
        let tempHome = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let claudeDirectory = tempHome.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let configURL = claudeDirectory.appendingPathComponent(".credentials.json")
        try Data(
            #"""
            {
              "claudeAiOauth": {
                "accessToken": "config-token",
                "expiresAt": 4102444800000,
                "rateLimitTier": "default_claude_team",
                "subscriptionType": "team"
              }
            }
            """#.utf8
        ).write(to: configURL)

        let resolver = ClaudeCodeOAuthCredentialResolver(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome,
            keychain: StubClaudeKeychainReader(),
            applicationSupportDirectory: tempHome.appendingPathComponent("Application Support", isDirectory: true)
        )

        let credentials = resolver.resolveCredentials()

        XCTAssertEqual(credentials?.accessToken, "config-token")
        XCTAssertEqual(credentials?.rateLimitTier, "default_claude_team")
        XCTAssertEqual(credentials?.subscriptionType, "team")
    }

    func testCredentialResolverFallsBackToKeychain() {
        let resolver = ClaudeCodeOAuthCredentialResolver(
            environment: [:],
            fileManager: .default,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            keychain: StubClaudeKeychainReader(tokens: [
                "Claude Code-credentials|*": #"""
                {
                  "claudeAiOauth": {
                    "accessToken": "keychain-token",
                    "expiresAt": 4102444800000,
                    "rateLimitTier": "default_claude_max",
                    "subscriptionType": "max"
                  }
                }
                """#
            ]),
            applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        let credentials = resolver.resolveCredentials()

        XCTAssertEqual(credentials?.accessToken, "keychain-token")
        XCTAssertEqual(credentials?.rateLimitTier, "default_claude_max")
        XCTAssertEqual(credentials?.subscriptionType, "max")
    }

    func testCredentialResolverPersistsKeychainBootstrapIntoOpenAssistCache() throws {
        let tempHome = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: tempHome) }
        let appSupport = tempHome.appendingPathComponent("Application Support", isDirectory: true)

        let resolver = ClaudeCodeOAuthCredentialResolver(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome,
            keychain: StubClaudeKeychainReader(tokens: [
                "Claude Code-credentials|*": #"""
                {
                  "claudeAiOauth": {
                    "accessToken": "keychain-token",
                    "refreshToken": "refresh-token",
                    "expiresAt": 4102444800000,
                    "rateLimitTier": "default_claude_max",
                    "subscriptionType": "max"
                  }
                }
                """#
            ]),
            applicationSupportDirectory: appSupport
        )

        let firstCredentials = resolver.resolveCredentials()
        XCTAssertEqual(firstCredentials?.accessToken, "keychain-token")
        XCTAssertEqual(firstCredentials?.refreshToken, "refresh-token")

        let cacheOnlyResolver = ClaudeCodeOAuthCredentialResolver(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome,
            keychain: StubClaudeKeychainReader(),
            applicationSupportDirectory: appSupport
        )

        let cachedCredentials = cacheOnlyResolver.resolveCredentials()
        XCTAssertEqual(cachedCredentials?.accessToken, "keychain-token")
        XCTAssertEqual(cachedCredentials?.refreshToken, "refresh-token")
    }

    func testFetcherRefreshesExpiredCachedCredentialsWithoutKeychain() async throws {
        let tempHome = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: tempHome) }
        let appSupport = tempHome.appendingPathComponent("Application Support", isDirectory: true)

        let resolver = ClaudeCodeOAuthCredentialResolver(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome,
            keychain: StubClaudeKeychainReader(tokens: [
                "Claude Code-credentials|*": #"""
                {
                  "claudeAiOauth": {
                    "accessToken": "expired-token",
                    "refreshToken": "refresh-token",
                    "expiresAt": 946684800000,
                    "rateLimitTier": "default_claude_team",
                    "subscriptionType": "team"
                  }
                }
                """#
            ]),
            applicationSupportDirectory: appSupport
        )

        let sequence = ClaudeCodeRequestSequence(steps: [
            { request in
                XCTAssertEqual(request.url?.absoluteString, "https://console.anthropic.com/v1/oauth/token")
                let body = #"""
                {
                  "access_token": "refreshed-token",
                  "refresh_token": "new-refresh-token",
                  "expires_in": 3600
                }
                """#
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(body.utf8)
                )
            },
            { request in
                XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-token")
                let body = #"""
                {
                  "five_hour": {
                    "utilization": 12,
                    "resets_at": "2026-04-01T12:00:00.000Z"
                  }
                }
                """#
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(body.utf8)
                )
            }
        ])

        let snapshot = try await ClaudeCodeUsageFetcher(session: makeStubbedSession { request in
            try sequence.handle(request)
        }).fetchUsage(resolver: resolver)

        XCTAssertEqual(snapshot?.rateLimits.primary?.usedPercent, 12)

        let cachedResolver = ClaudeCodeOAuthCredentialResolver(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome,
            keychain: StubClaudeKeychainReader(),
            applicationSupportDirectory: appSupport
        )

        let cachedCredentials = cachedResolver.resolveCredentials()
        XCTAssertEqual(cachedCredentials?.accessToken, "refreshed-token")
        XCTAssertEqual(cachedCredentials?.refreshToken, "new-refresh-token")
    }

    private func makeStubbedSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        ClaudeCodeUsageURLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeCodeUsageURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func makeTemporaryHomeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class ClaudeCodeRequestSequence: @unchecked Sendable {
    typealias Step = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private let lock = NSLock()
    private var steps: [Step]

    init(steps: [Step]) {
        self.steps = steps
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !steps.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return try steps.removeFirst()(request)
    }
}

private struct StubClaudeKeychainReader: CopilotKeychainReading {
    var tokens: [String: String] = [:]

    func loadToken(service: String, account: String?) -> String? {
        let key = "\(service)|\(account ?? "*")"
        return tokens[key] ?? tokens["\(service)|*"]
    }
}

private final class ClaudeCodeUsageURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
