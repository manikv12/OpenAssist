import Foundation

enum AssistantExecCommandToolDefinition {
    static let name = "exec_command"
    static let toolKind = "commandExecution"

    static let description = """
    Run a local shell command on this Mac in the current workspace. Use this for workspace inspection, validation, build/test commands, or interactive shell work that may need follow-up input.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "cmd": [
                "type": "string",
                "description": "Shell command to execute."
            ],
            "workdir": [
                "type": "string",
                "description": "Optional working directory. Defaults to the active thread workspace."
            ],
            "shell": [
                "type": "string",
                "description": "Optional shell executable such as /bin/zsh."
            ],
            "login": [
                "type": "boolean",
                "description": "When true, run the shell as a login shell."
            ],
            "tty": [
                "type": "boolean",
                "description": "When true, keep the command open as an interactive shell session."
            ],
            "yield_time_ms": [
                "type": "integer",
                "description": "How long to wait for output before returning."
            ],
            "max_output_tokens": [
                "type": "integer",
                "description": "Optional soft limit for returned output."
            ]
        ],
        "required": ["cmd"],
        "additionalProperties": true
    ]
}

enum AssistantWriteStdinToolDefinition {
    static let name = "write_stdin"
    static let toolKind = "commandExecution"

    static let description = """
    Send text into an already-running shell session that was started with exec_command.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "session_id": [
                "type": "integer",
                "description": "Optional shell session id. Defaults to the latest shell session in the current thread."
            ],
            "chars": [
                "type": "string",
                "description": "Text to write to stdin. Can be empty when you only want to poll for more output."
            ],
            "yield_time_ms": [
                "type": "integer",
                "description": "How long to wait for new output before returning."
            ],
            "max_output_tokens": [
                "type": "integer",
                "description": "Optional soft limit for returned output."
            ]
        ],
        "additionalProperties": true
    ]
}

enum AssistantReadTerminalToolDefinition {
    static let name = "read_terminal"
    static let toolKind = "commandExecution"

    static let description = """
    Read the latest output from a running shell session in this thread.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "session_id": [
                "type": "integer",
                "description": "Optional shell session id. Defaults to the latest shell session in the current thread."
            ],
            "yield_time_ms": [
                "type": "integer",
                "description": "Optional delay before reading more output."
            ],
            "max_output_tokens": [
                "type": "integer",
                "description": "Optional soft limit for returned output."
            ]
        ],
        "additionalProperties": true
    ]
}

enum AssistantShellExecutionServiceError: LocalizedError {
    case invalidArguments(String)
    case failedToLaunch(String)
    case sessionNotFound
    case sessionNotRunning

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message),
             .failedToLaunch(let message):
            return message
        case .sessionNotFound:
            return "Open Assist could not find that shell session."
        case .sessionNotRunning:
            return "That shell session is no longer running."
        }
    }
}

actor AssistantShellExecutionService {
    struct ExecCommandRequest: Equatable, Sendable {
        let command: String
        let workingDirectory: String?
        let shellPath: String?
        let loginShell: Bool
        let interactive: Bool
        let yieldTimeMs: Int
        let maxOutputCharacters: Int

        var summaryLine: String {
            let collapsed = command
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard collapsed.count > 120 else { return collapsed }
            return String(collapsed.prefix(117)) + "..."
        }
    }

    struct WriteStdinRequest: Equatable, Sendable {
        let sessionID: Int?
        let characters: String
        let yieldTimeMs: Int
        let maxOutputCharacters: Int

        var summaryLine: String {
            if let sessionID {
                return "Continue shell session \(sessionID)"
            }
            return "Continue the latest shell session"
        }
    }

    struct ReadTerminalRequest: Equatable, Sendable {
        let sessionID: Int?
        let yieldTimeMs: Int
        let maxOutputCharacters: Int

        var summaryLine: String {
            if let sessionID {
                return "Read shell session \(sessionID)"
            }
            return "Read the latest shell session"
        }
    }

    private let sessionStore: ToolSessionStore

    init(sessionStore: ToolSessionStore = ToolSessionStore()) {
        self.sessionStore = sessionStore
    }

    static func parseExecCommandRequest(from arguments: Any) throws -> ExecCommandRequest {
        guard let dictionary = normalizedDictionary(from: arguments) else {
            throw AssistantShellExecutionServiceError.invalidArguments("Command requests need a JSON object.")
        }
        guard let command = (dictionary["cmd"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty else {
            throw AssistantShellExecutionServiceError.invalidArguments("Command requests need a non-empty `cmd`.")
        }

        let yieldTimeMs = max(0, Int((dictionary["yield_time_ms"] as? NSNumber)?.doubleValue ?? 1000))
        let maxOutputCharacters = normalizedLimit(from: dictionary["max_output_tokens"], defaultValue: 4000)
        return ExecCommandRequest(
            command: command,
            workingDirectory: (dictionary["workdir"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            shellPath: (dictionary["shell"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            loginShell: dictionary["login"] as? Bool ?? true,
            interactive: dictionary["tty"] as? Bool ?? false,
            yieldTimeMs: yieldTimeMs,
            maxOutputCharacters: maxOutputCharacters
        )
    }

    static func parseWriteStdinRequest(from arguments: Any) throws -> WriteStdinRequest {
        guard let dictionary = normalizedDictionary(from: arguments) else {
            throw AssistantShellExecutionServiceError.invalidArguments("write_stdin requests need a JSON object.")
        }
        let yieldTimeMs = max(0, Int((dictionary["yield_time_ms"] as? NSNumber)?.doubleValue ?? 1000))
        let maxOutputCharacters = normalizedLimit(from: dictionary["max_output_tokens"], defaultValue: 4000)
        return WriteStdinRequest(
            sessionID: integer(from: dictionary["session_id"]),
            characters: dictionary["chars"] as? String ?? "",
            yieldTimeMs: yieldTimeMs,
            maxOutputCharacters: maxOutputCharacters
        )
    }

    static func parseReadTerminalRequest(from arguments: Any) throws -> ReadTerminalRequest {
        guard let dictionary = normalizedDictionary(from: arguments) else {
            throw AssistantShellExecutionServiceError.invalidArguments("read_terminal requests need a JSON object.")
        }
        let yieldTimeMs = max(0, Int((dictionary["yield_time_ms"] as? NSNumber)?.doubleValue ?? 0))
        let maxOutputCharacters = normalizedLimit(from: dictionary["max_output_tokens"], defaultValue: 4000)
        return ReadTerminalRequest(
            sessionID: integer(from: dictionary["session_id"]),
            yieldTimeMs: yieldTimeMs,
            maxOutputCharacters: maxOutputCharacters
        )
    }

    func runCommand(
        threadID: String?,
        arguments: Any,
        preferredModelID: String?
    ) async -> AssistantToolExecutionResult {
        _ = preferredModelID
        do {
            let request = try Self.parseExecCommandRequest(from: arguments)
            let shellPath = request.shellPath ?? "/bin/zsh"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: shellPath)
            process.arguments = [request.loginShell ? "-lc" : "-c", request.command]
            if let workingDirectory = request.workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            }

            let outputPipe = Pipe()
            let inputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            process.standardInput = inputPipe

            let sessionID = await sessionStore.registerShellSession(
                threadID: threadID,
                command: request.command,
                workingDirectory: request.workingDirectory,
                process: process,
                stdinHandle: inputPipe.fileHandleForWriting
            )

            outputPipe.fileHandleForReading.readabilityHandler = { [sessionStore] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task {
                    await sessionStore.appendShellOutput(data, to: sessionID)
                }
            }

            process.terminationHandler = { [sessionStore] terminatedProcess in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                Task {
                    await sessionStore.markShellSessionExited(
                        sessionID,
                        terminationStatus: terminatedProcess.terminationStatus
                    )
                }
            }

            do {
                try process.run()
            } catch {
                await sessionStore.closeShellSession(sessionID)
                throw AssistantShellExecutionServiceError.failedToLaunch(
                    "Open Assist could not start the shell command: \(error.localizedDescription)"
                )
            }

            if request.yieldTimeMs > 0 {
                try await Task.sleep(nanoseconds: UInt64(request.yieldTimeMs) * 1_000_000)
            }
            let snapshot = await sessionStore.shellSnapshot(sessionID: sessionID, consumeUnread: true)
            let output = Self.compactOutput(snapshot?.fullOutput ?? "", limit: request.maxOutputCharacters)

            let summary: String
            if snapshot?.isRunning == true || request.interactive {
                summary = "Started shell session \(sessionID)."
            } else {
                summary = "Command finished."
            }

            var lines = [summary]
            lines.append("Session id: \(sessionID)")
            if let terminationStatus = snapshot?.terminationStatus, snapshot?.isRunning == false {
                lines.append("Exit status: \(terminationStatus)")
            }
            if !output.isEmpty {
                lines.append("")
                lines.append("Output:")
                lines.append(output)
            }

            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: lines.joined(separator: "\n"), imageURL: nil)],
                success: true,
                summary: summary
            )
        } catch {
            let message = error.localizedDescription
            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: message, imageURL: nil)],
                success: false,
                summary: message
            )
        }
    }

    func writeStdin(
        threadID: String?,
        arguments: Any,
        preferredModelID: String?
    ) async -> AssistantToolExecutionResult {
        _ = preferredModelID
        do {
            let request = try Self.parseWriteStdinRequest(from: arguments)
            guard let resolvedSessionID = await sessionStore.resolveShellSessionID(
                sessionID: request.sessionID,
                threadID: threadID
            ) else {
                throw AssistantShellExecutionServiceError.sessionNotFound
            }

            if !request.characters.isEmpty {
                try await sessionStore.writeToShell(sessionID: resolvedSessionID, text: request.characters)
            }
            if request.yieldTimeMs > 0 {
                try await Task.sleep(nanoseconds: UInt64(request.yieldTimeMs) * 1_000_000)
            }
            let snapshot = await sessionStore.shellSnapshot(sessionID: resolvedSessionID, consumeUnread: true)
            let output = Self.compactOutput(snapshot?.unreadOutput ?? snapshot?.fullOutput ?? "", limit: request.maxOutputCharacters)
            let summary = snapshot?.isRunning == true
                ? "Shell session \(resolvedSessionID) is still running."
                : "Shell session \(resolvedSessionID) finished."

            var lines = [summary]
            if !output.isEmpty {
                lines.append("")
                lines.append("Latest output:")
                lines.append(output)
            }

            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: lines.joined(separator: "\n"), imageURL: nil)],
                success: true,
                summary: summary
            )
        } catch {
            let message = error.localizedDescription
            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: message, imageURL: nil)],
                success: false,
                summary: message
            )
        }
    }

    func readTerminal(
        threadID: String?,
        arguments: Any,
        preferredModelID: String?
    ) async -> AssistantToolExecutionResult {
        _ = preferredModelID
        do {
            let request = try Self.parseReadTerminalRequest(from: arguments)
            guard let resolvedSessionID = await sessionStore.resolveShellSessionID(
                sessionID: request.sessionID,
                threadID: threadID
            ) else {
                throw AssistantShellExecutionServiceError.sessionNotFound
            }
            if request.yieldTimeMs > 0 {
                try await Task.sleep(nanoseconds: UInt64(request.yieldTimeMs) * 1_000_000)
            }
            let snapshot = await sessionStore.shellSnapshot(sessionID: resolvedSessionID, consumeUnread: true)
            let output = Self.compactOutput(snapshot?.unreadOutput ?? snapshot?.fullOutput ?? "", limit: request.maxOutputCharacters)
            let summary = snapshot?.isRunning == true
                ? "Read shell session \(resolvedSessionID)."
                : "Read finished shell session \(resolvedSessionID)."

            var lines = [summary]
            if !output.isEmpty {
                lines.append("")
                lines.append("Terminal output:")
                lines.append(output)
            }

            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: lines.joined(separator: "\n"), imageURL: nil)],
                success: true,
                summary: summary
            )
        } catch {
            let message = error.localizedDescription
            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: message, imageURL: nil)],
                success: false,
                summary: message
            )
        }
    }

    private static func normalizedDictionary(from arguments: Any) -> [String: Any]? {
        if let dictionary = arguments as? [String: Any] {
            return dictionary
        }
        if let json = arguments as? String,
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        return nil
    }

    private static func integer(from value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func normalizedLimit(from value: Any?, defaultValue: Int) -> Int {
        let raw = integer(from: value) ?? defaultValue
        return min(max(raw, 256), 12_000)
    }

    private static func compactOutput(_ output: String, limit: Int) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let prefix = trimmed.prefix(limit)
        return String(prefix) + "\n...[output truncated]"
    }
}
