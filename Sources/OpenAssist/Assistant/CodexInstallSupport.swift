import Foundation

enum AssistantCommandEnvironment {
    static func searchPaths(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        var paths: [String] = [
            homeDirectory.appendingPathComponent(".npm-global/bin", isDirectory: true).path,
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true).path,
            homeDirectory.appendingPathComponent(".bun/bin", isDirectory: true).path,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/Library/Apple/usr/bin"
        ]

        if let existing = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) {
            paths.append(contentsOf: existing)
        }

        var seen: Set<String> = []
        return paths.filter { path in
            !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert(path).inserted
        }
    }

    static func mergedEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = searchPaths(homeDirectory: homeDirectory).joined(separator: ":")
        return environment
    }
}

struct CommandExecutionResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

struct CommandExecutionError: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

protocol CommandRunning: Sendable {
    func run(_ launchPath: String, arguments: [String]) async throws -> CommandExecutionResult
}

struct ProcessCommandRunner: CommandRunning {
    func run(_ launchPath: String, arguments: [String]) async throws -> CommandExecutionResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            process.environment = AssistantCommandEnvironment.mergedEnvironment()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { completed in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: CommandExecutionResult(
                        exitCode: completed.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self)
                    )
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(
                    throwing: CommandExecutionError(
                        message: "Could not run \(launchPath): \(error.localizedDescription)"
                    )
                )
            }
        }
    }
}

struct CodexInstallSupport {
    let runner: CommandRunning
    let fileManager: FileManager
    let homeDirectory: URL
    let searchPathsOverride: [String]?
    let allowShellLookup: Bool

    init(
        runner: CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchPathsOverride: [String]? = nil,
        allowShellLookup: Bool = true
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.searchPathsOverride = searchPathsOverride
        self.allowShellLookup = allowShellLookup
    }

    func inspect(backend: AssistantRuntimeBackend = .codex) async -> AssistantInstallGuidance {
        async let runtimePath = which(backend.executableName)
        async let brewPath = which("brew")
        async let npmPath = which("npm")

        let resolvedRuntime = await runtimePath
        let resolvedBrew = await brewPath
        let resolvedNPM = await npmPath
        let commands = backend.installCommands

        let primaryTitle: String
        let primaryDetail: String
        switch backend {
        case .codex:
            if resolvedRuntime != nil {
                primaryTitle = "Codex is installed"
                primaryDetail = "Codex App Server is available on this Mac. Open Assist can sign in with ChatGPT, browse saved threads, and stream live assistant progress."
            } else {
                primaryTitle = "Install Codex"
                primaryDetail = "Open Assist needs Codex before the assistant can run."
            }
        case .copilot:
            if resolvedRuntime != nil {
                primaryTitle = "GitHub Copilot is installed"
                primaryDetail = "GitHub Copilot CLI is available on this Mac. Open Assist can connect over ACP, browse Copilot sessions, and stream live assistant progress."
            } else {
                primaryTitle = "Install Copilot CLI"
                primaryDetail = "Open Assist needs GitHub Copilot CLI before the assistant can use Copilot."
            }
        }

        return AssistantInstallGuidance(
            backend: backend,
            codexDetected: resolvedRuntime != nil,
            brewDetected: resolvedBrew != nil,
            npmDetected: resolvedNPM != nil,
            codexPath: resolvedRuntime,
            brewPath: resolvedBrew,
            npmPath: resolvedNPM,
            primaryTitle: primaryTitle,
            primaryDetail: primaryDetail,
            installCommands: commands,
            loginCommands: backend.loginCommands,
            docsURL: backend.docsURL
        )
    }

    private func which(_ binary: String) async -> String? {
        if let directPath = commonCandidatePath(for: binary) {
            return directPath
        }

        do {
            let result = try await runner.run("/usr/bin/which", arguments: [binary])
            guard result.exitCode == 0 else {
                return allowShellLookup ? await shellLookup(binary) : nil
            }
            return result.stdout.assistantNonEmpty
        } catch {
            return allowShellLookup ? await shellLookup(binary) : nil
        }
    }

    private func shellLookup(_ binary: String) async -> String? {
        do {
            let result = try await runner.run(
                "/bin/zsh",
                arguments: ["-lc", "command -v \(binary) 2>/dev/null || true"]
            )
            return result.exitCode == 0 ? result.stdout.assistantNonEmpty : nil
        } catch {
            return nil
        }
    }

    private func commonCandidatePath(for binary: String) -> String? {
        let searchPaths = searchPathsOverride ?? AssistantCommandEnvironment.searchPaths(homeDirectory: homeDirectory)
        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(binary)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate).standardizedFileURL.path
            }
        }
        return nil
    }
}
