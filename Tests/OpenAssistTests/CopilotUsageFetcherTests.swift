import Foundation
import XCTest
@testable import OpenAssist

final class CopilotUsageFetcherTests: XCTestCase {
    override func tearDown() {
        CopilotUsageURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testFetcherMapsCopilotUsageResponseIntoRateLimits() async throws {
        let session = makeStubbedSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/copilot_internal/user")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token github-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Editor-Version"), "vscode/1.96.2")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Editor-Plugin-Version"), "copilot-chat/0.26.7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GitHubCopilotChat/0.26.7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Github-Api-Version"), "2025-04-01")

            let body = #"""
            {
              "copilot_plan": "individual",
              "quota_snapshots": {
                "premium_interactions": {
                  "entitlement": 300,
                  "remaining": 96,
                  "percent_remaining": 32.2,
                  "quota_id": "premium_interactions",
                  "unlimited": false
                },
                "chat": {
                  "entitlement": 0,
                  "remaining": 0,
                  "percent_remaining": 100,
                  "quota_id": "chat",
                  "unlimited": true
                }
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

        let snapshot = try await CopilotUsageFetcher(session: session).fetchUsage(token: "github-token")

        XCTAssertEqual(snapshot.planType, "individual")
        XCTAssertEqual(snapshot.rateLimits.planType, "individual")
        XCTAssertEqual(snapshot.rateLimits.limitID, "copilot")
        XCTAssertEqual(snapshot.rateLimits.primary?.usedPercent, 68)
        XCTAssertEqual(snapshot.rateLimits.secondary?.usedPercent, 0)
    }

    func testTokenResolverPrefersEnvironmentToken() async {
        let resolver = CopilotTokenResolver(
            environment: ["GH_TOKEN": "env-token"],
            runner: StubCommandRunner(),
            fileManager: .default,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            keychain: StubCopilotKeychainReader()
        )

        let token = await resolver.resolveGitHubToken()

        XCTAssertEqual(token, "env-token")
    }

    func testTokenResolverReadsPlaintextCopilotConfig() async throws {
        let tempHome = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        try writeCopilotConfig(
            to: tempHome,
            json: #"""
            {
              "store_token_plaintext": true,
              "last_logged_in_user": {
                "host": "https://github.com",
                "login": "monalisa"
              },
              "copilot_tokens": {
                "https://github.com:monalisa": "config-token"
              }
            }
            """#
        )

        let resolver = CopilotTokenResolver(
            environment: [:],
            runner: StubCommandRunner(),
            fileManager: .default,
            homeDirectory: tempHome,
            keychain: StubCopilotKeychainReader()
        )

        let token = await resolver.resolveGitHubToken()

        XCTAssertEqual(token, "config-token")
    }

    func testTokenResolverReadsCopilotKeychainTokenBeforeGhFallback() async throws {
        let tempHome = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        try writeCopilotConfig(
            to: tempHome,
            json: #"""
            {
              "last_logged_in_user": {
                "host": "https://github.com",
                "login": "monalisa"
              }
            }
            """#
        )

        let resolver = CopilotTokenResolver(
            environment: [:],
            runner: StubCommandRunner(stdout: "gh-token\n"),
            fileManager: .default,
            homeDirectory: tempHome,
            keychain: StubCopilotKeychainReader(tokens: [
                "copilot-cli|https://github.com:monalisa": "keychain-token"
            ])
        )

        let token = await resolver.resolveGitHubToken()

        XCTAssertEqual(token, "keychain-token")
    }

    func testTokenResolverFallsBackToGitHubCLI() async throws {
        let tempHome = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let resolver = CopilotTokenResolver(
            environment: [:],
            runner: StubCommandRunner(stdout: "gh-token\n"),
            fileManager: .default,
            homeDirectory: tempHome,
            keychain: StubCopilotKeychainReader()
        )

        let token = await resolver.resolveGitHubToken()

        XCTAssertEqual(token, "gh-token")
    }

    private func makeStubbedSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        CopilotUsageURLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CopilotUsageURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func makeTemporaryHomeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCopilotConfig(to homeDirectory: URL, json: String) throws {
        let copilotDirectory = homeDirectory.appendingPathComponent(".copilot", isDirectory: true)
        try FileManager.default.createDirectory(at: copilotDirectory, withIntermediateDirectories: true)
        let configURL = copilotDirectory.appendingPathComponent("config.json")
        try Data(json.utf8).write(to: configURL)
    }
}

private struct StubCommandRunner: CommandRunning {
    var stdout: String = ""
    var stderr: String = ""
    var exitCode: Int32 = 0

    func run(_ launchPath: String, arguments: [String]) async throws -> CommandExecutionResult {
        CommandExecutionResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}

private struct StubCopilotKeychainReader: CopilotKeychainReading {
    var tokens: [String: String] = [:]

    func loadToken(service: String, account: String?) -> String? {
        let key = "\(service)|\(account ?? "*")"
        return tokens[key] ?? tokens["\(service)|*"]
    }
}

private final class CopilotUsageURLProtocolStub: URLProtocol, @unchecked Sendable {
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
