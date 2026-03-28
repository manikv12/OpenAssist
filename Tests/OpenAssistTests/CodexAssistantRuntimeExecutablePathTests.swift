import XCTest
@testable import OpenAssist

final class CodexAssistantRuntimeExecutablePathTests: XCTestCase {
    @MainActor
    func testCopilotLoginRecoversExecutablePathWithoutRefresh() async throws {
        let runtime = CodexAssistantRuntime(
            installSupport: CodexInstallSupport(
                runner: RuntimePathCommandRunner(
                    locations: [
                        "copilot": "/opt/homebrew/bin/copilot"
                    ]
                ),
                searchPathsOverride: [],
                allowShellLookup: false
            )
        )
        runtime.backend = .copilot

        let action = try await runtime.startLogin()

        XCTAssertEqual(action, .runCommand("copilot login"))
        XCTAssertEqual(runtime.currentExecutablePathForTesting(), "/opt/homebrew/bin/copilot")
    }

    @MainActor
    func testClearCachedEnvironmentStateDropsExecutablePath() async throws {
        let runtime = CodexAssistantRuntime(
            installSupport: CodexInstallSupport(
                runner: RuntimePathCommandRunner(locations: [:]),
                searchPathsOverride: [],
                allowShellLookup: false
            )
        )
        runtime.backend = .copilot
        runtime.setExecutablePathForTesting("/tmp/copilot")

        runtime.clearCachedEnvironmentState()

        XCTAssertNil(runtime.currentExecutablePathForTesting())

        do {
            _ = try await runtime.startLogin()
            XCTFail("Expected Copilot login to fail when no executable can be resolved.")
        } catch let error as CodexAssistantRuntimeError {
            XCTAssertEqual(
                error.localizedDescription,
                "GitHub Copilot CLI is not installed on this Mac."
            )
        }
    }

    @MainActor
    func testClaudeCodeLoginRecoversExecutablePathWithoutRefresh() async throws {
        let runtime = CodexAssistantRuntime(
            installSupport: CodexInstallSupport(
                runner: RuntimePathCommandRunner(
                    locations: [
                        "claude": "/opt/homebrew/bin/claude"
                    ]
                ),
                searchPathsOverride: [],
                allowShellLookup: false
            )
        )
        runtime.backend = .claudeCode

        let action = try await runtime.startLogin()

        XCTAssertEqual(action, .runCommand("claude auth login"))
        XCTAssertEqual(runtime.currentExecutablePathForTesting(), "/opt/homebrew/bin/claude")
    }
}

private struct RuntimePathCommandRunner: CommandRunning {
    let locations: [String: String]

    func run(_ launchPath: String, arguments: [String]) async throws -> CommandExecutionResult {
        guard launchPath == "/usr/bin/which", let binary = arguments.first else {
            return CommandExecutionResult(exitCode: 1, stdout: "", stderr: "unsupported command")
        }

        if let path = locations[binary] {
            return CommandExecutionResult(exitCode: 0, stdout: path + "\n", stderr: "")
        }

        return CommandExecutionResult(exitCode: 1, stdout: "", stderr: "")
    }
}
