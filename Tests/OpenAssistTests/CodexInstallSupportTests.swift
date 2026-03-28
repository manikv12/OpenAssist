import XCTest
@testable import OpenAssist

final class CodexInstallSupportTests: XCTestCase {
    func testInspectShowsInstallGuidanceWhenCodexIsMissing() async {
        let support = CodexInstallSupport(
            runner: WhichCommandRunner(locations: [:]),
            searchPathsOverride: [],
            allowShellLookup: false
        )

        let guidance = await support.inspect()

        XCTAssertFalse(guidance.codexDetected)
        XCTAssertNil(guidance.codexPath)
        XCTAssertEqual(guidance.primaryTitle, "Install Codex")
        XCTAssertEqual(
            guidance.primaryDetail,
            "Open Assist needs Codex before the assistant can run."
        )
        XCTAssertEqual(guidance.installCommands, ["npm install -g @openai/codex"])
        XCTAssertEqual(
            guidance.docsURL?.absoluteString,
            "https://developers.openai.com/codex/app-server"
        )
    }

    func testInspectShowsReadyGuidanceWhenCodexIsInstalled() async {
        let support = CodexInstallSupport(
            runner: WhichCommandRunner(
                locations: [
                    "codex": "/opt/homebrew/bin/codex"
                ]
            ),
            searchPathsOverride: [],
            allowShellLookup: false
        )

        let guidance = await support.inspect()

        XCTAssertTrue(guidance.codexDetected)
        XCTAssertEqual(guidance.codexPath, "/opt/homebrew/bin/codex")
        XCTAssertEqual(guidance.primaryTitle, "Codex is installed")
        XCTAssertEqual(
            guidance.primaryDetail,
            "Codex App Server is available on this Mac. Open Assist can sign in with ChatGPT, browse saved threads, and stream live assistant progress."
        )
        XCTAssertEqual(guidance.installCommands, ["npm install -g @openai/codex"])
    }

    func testInspectFindsCodexInCommonUserPathWhenPATHLookupFails() async throws {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenAssistCodexInstallSupport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: homeDirectory) }

        let binDirectory = homeDirectory.appendingPathComponent(".npm-global/bin", isDirectory: true)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        let codexPath = binDirectory.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: codexPath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexPath.path)

        let support = CodexInstallSupport(
            runner: WhichCommandRunner(locations: [:]),
            fileManager: fileManager,
            homeDirectory: homeDirectory,
            searchPathsOverride: [binDirectory.path],
            allowShellLookup: false
        )

        let guidance = await support.inspect()

        XCTAssertTrue(guidance.codexDetected)
        XCTAssertEqual(guidance.codexPath, codexPath.path)
        XCTAssertEqual(guidance.primaryTitle, "Codex is installed")
    }

    func testInspectShowsCopilotGuidanceWhenCopilotIsInstalled() async {
        let support = CodexInstallSupport(
            runner: WhichCommandRunner(
                locations: [
                    "copilot": "/opt/homebrew/bin/copilot"
                ]
            ),
            searchPathsOverride: [],
            allowShellLookup: false
        )

        let guidance = await support.inspect(backend: .copilot)

        XCTAssertEqual(guidance.backend, .copilot)
        XCTAssertTrue(guidance.codexDetected)
        XCTAssertEqual(guidance.codexPath, "/opt/homebrew/bin/copilot")
        XCTAssertEqual(guidance.primaryTitle, "GitHub Copilot is installed")
        XCTAssertEqual(
            guidance.primaryDetail,
            "GitHub Copilot CLI is available on this Mac. Open Assist can connect over ACP, browse Copilot sessions, and stream live assistant progress."
        )
        XCTAssertEqual(guidance.installCommands, ["npm install -g @github/copilot"])
        XCTAssertEqual(guidance.loginCommands, ["copilot login"])
        XCTAssertEqual(
            guidance.docsURL?.absoluteString,
            "https://docs.github.com/copilot/concepts/agents/about-copilot-cli"
        )
    }

    func testInspectShowsClaudeCodeGuidanceWhenClaudeCodeIsInstalled() async {
        let support = CodexInstallSupport(
            runner: WhichCommandRunner(
                locations: [
                    "claude": "/opt/homebrew/bin/claude"
                ]
            ),
            searchPathsOverride: [],
            allowShellLookup: false
        )

        let guidance = await support.inspect(backend: .claudeCode)

        XCTAssertEqual(guidance.backend, .claudeCode)
        XCTAssertTrue(guidance.codexDetected)
        XCTAssertEqual(guidance.codexPath, "/opt/homebrew/bin/claude")
        XCTAssertEqual(guidance.primaryTitle, "Claude Code is installed")
        XCTAssertEqual(
            guidance.primaryDetail,
            "Claude Code CLI is available on this Mac. Open Assist can run Claude Code in headless mode, reuse Claude sessions between turns, and show replies back in the assistant timeline."
        )
        XCTAssertEqual(guidance.installCommands, ["npm install -g @anthropic-ai/claude-code"])
        XCTAssertEqual(guidance.loginCommands, ["claude auth login"])
        XCTAssertEqual(
            guidance.docsURL?.absoluteString,
            "https://code.claude.com/docs/en/headless"
        )
    }
}

private struct WhichCommandRunner: CommandRunning {
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
