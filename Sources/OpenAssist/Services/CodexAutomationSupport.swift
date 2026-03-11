import Foundation

enum AutomationAPISource: String, CaseIterable, Codable, Hashable, Identifiable {
    case claudeCode
    case codexCLI
    case codexCloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode:
            return "Claude Code"
        case .codexCLI:
            return "Codex CLI"
        case .codexCloud:
            return "Codex Cloud (beta)"
        }
    }
}

enum AutomationAPISourceResolver {
    static func source(for sourceIdentifier: String) -> AutomationAPISource? {
        let normalized = sourceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("claude-code.") {
            return .claudeCode
        }
        if normalized.hasPrefix("codex-cli.") {
            return .codexCLI
        }
        if normalized.hasPrefix("codex-cloud.") {
            return .codexCloud
        }
        return nil
    }
}

enum AutomationAPISourceGate {
    static func validate(
        sourceIdentifier: String,
        enabledSources: Set<AutomationAPISource>
    ) throws {
        guard let source = AutomationAPISourceResolver.source(for: sourceIdentifier) else {
            return
        }
        guard enabledSources.contains(source) else {
            throw AutomationAPIRequestError.forbidden("This automation source is disabled in Settings.")
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private struct CodexNotifyHookPayload: Decodable {
    let type: String?
    let turnID: String?
    let inputMessages: [String]
    let lastAssistantMessage: String?
    let client: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        type = Self.decodeString(container, keys: ["type"])
        turnID = Self.decodeString(container, keys: ["turn-id", "turn_id"])
        inputMessages = Self.decodeStringArray(container, keys: ["input-messages", "input_messages"]) ?? []
        lastAssistantMessage = Self.decodeString(
            container,
            keys: ["last-assistant-message", "last_assistant_message"]
        )
        client = Self.decodeString(container, keys: ["client"])
    }

    private static func decodeString(
        _ container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
            if let value = try? container.decodeIfPresent(String.self, forKey: codingKey) {
                return value
            }
        }
        return nil
    }

    private static func decodeStringArray(
        _ container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]
    ) -> [String]? {
        for key in keys {
            guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
            if let value = try? container.decodeIfPresent([String].self, forKey: codingKey) {
                return value
            }
        }
        return nil
    }
}

enum CodexNotifyHookAdapter {
    static func adapt(_ data: Data) throws -> AutomationAPIAnnounceRequest {
        let decoder = JSONDecoder()
        let payload: CodexNotifyHookPayload
        do {
            payload = try decoder.decode(CodexNotifyHookPayload.self, from: data)
        } catch {
            throw AutomationAPIRequestError.invalidRequest("Invalid Codex notify JSON payload.")
        }

        let normalizedType = normalize(payload.type)
        guard normalizedType == "agent-turn-complete" else {
            throw AutomationAPIRequestError.invalidRequest("Unsupported Codex notify event.")
        }

        let message = summarizeMessage(
            payload.lastAssistantMessage,
            inputMessages: payload.inputMessages
        )
        let dedupeSeed = collapseWhitespace(payload.turnID)
        let dedupeKey = dedupeSeed.isEmpty
            ? "codex-cli:\(normalizedType):\(message.lowercased())"
            : "codex-cli:\(normalizedType):\(dedupeSeed)"

        return AutomationAPIAnnounceRequest(
            message: message,
            title: "Codex CLI",
            subtitle: "Task complete",
            channels: nil,
            voiceIdentifier: nil,
            sound: nil,
            source: "codex-cli.agent-turn-complete",
            dedupeKey: dedupeKey,
            dedupeWindowSeconds: 30
        )
    }

    private static func summarizeMessage(_ assistantMessage: String?, inputMessages: [String]) -> String {
        let collapsedAssistant = collapseWhitespace(assistantMessage)
        if !collapsedAssistant.isEmpty {
            return truncate(collapsedAssistant)
        }

        if let firstPrompt = inputMessages
            .map({ collapseWhitespace($0) })
            .first(where: { !$0.isEmpty }) {
            return truncate("Completed: \(firstPrompt)")
        }

        return "Codex finished."
    }

    private static func truncate(_ value: String) -> String {
        guard value.count > 240 else { return value }
        let index = value.index(value.startIndex, offsetBy: 237)
        return String(value[..<index]) + "..."
    }

    private static func normalize(_ value: String?) -> String {
        collapseWhitespace(value).lowercased()
    }

    private static func collapseWhitespace(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CodexCloudTaskSummary: Decodable, Equatable {
    let filesChanged: Int?
    let linesAdded: Int?
    let linesRemoved: Int?

    enum CodingKeys: String, CodingKey {
        case filesChanged = "files_changed"
        case linesAdded = "lines_added"
        case linesRemoved = "lines_removed"
    }
}

struct CodexCloudTask: Decodable, Equatable, Identifiable {
    let id: String
    let title: String?
    let status: String
    let updatedAt: String?
    let completedAt: String?
    let environmentLabel: String?
    let description: String?
    let errorMessage: String?
    let summary: CodexCloudTaskSummary?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case environmentLabel = "environment_label"
        case description
        case errorMessage = "error_message"
        case summary
    }

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var trimmedTitle: String {
        title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var trimmedEnvironmentLabel: String {
        environmentLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var trimmedDescription: String {
        description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var trimmedErrorMessage: String {
        errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct CodexCloudTaskListResponse: Decodable, Equatable {
    let tasks: [CodexCloudTask]
}

struct CodexCloudTaskStatusResponse: Decodable, Equatable {
    let id: String
    let title: String?
    let status: String
    let completedAt: String?
    let description: String?
    let errorMessage: String?
    let environmentLabel: String?
    let summary: CodexCloudTaskSummary?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case completedAt = "completed_at"
        case description
        case errorMessage = "error_message"
        case environmentLabel = "environment_label"
        case summary
    }

    var trimmedTitle: String {
        title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var trimmedDescription: String {
        description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var trimmedErrorMessage: String {
        errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var trimmedEnvironmentLabel: String {
        environmentLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum CodexCloudTaskOutcome: String, Equatable {
    case ready
    case failed
}

struct CodexCloudAnnouncementEvent: Equatable {
    let task: CodexCloudTask
    let outcome: CodexCloudTaskOutcome
}

final class CodexCloudTaskTracker {
    private var seenStatuses: [String: String] = [:]
    private var hasSeededInitialSnapshot = false

    func reset() {
        seenStatuses = [:]
        hasSeededInitialSnapshot = false
    }

    func ingest(_ tasks: [CodexCloudTask]) -> [CodexCloudAnnouncementEvent] {
        let sortedTasks = tasks.sorted { lhs, rhs in
            (lhs.updatedAt ?? lhs.id) < (rhs.updatedAt ?? rhs.id)
        }

        if !hasSeededInitialSnapshot {
            for task in sortedTasks {
                seenStatuses[task.id] = task.normalizedStatus
            }
            hasSeededInitialSnapshot = true
            return []
        }

        var events: [CodexCloudAnnouncementEvent] = []
        for task in sortedTasks {
            let normalizedStatus = task.normalizedStatus
            let previousStatus = seenStatuses[task.id]
            seenStatuses[task.id] = normalizedStatus

            guard previousStatus != normalizedStatus else {
                continue
            }

            if Self.isReadyStatus(normalizedStatus) {
                events.append(CodexCloudAnnouncementEvent(task: task, outcome: .ready))
            } else if Self.isFailureStatus(status: normalizedStatus, errorMessage: task.trimmedErrorMessage) {
                events.append(CodexCloudAnnouncementEvent(task: task, outcome: .failed))
            }
        }

        return events
    }

    static func isReadyStatus(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "ready" || normalized == "completed"
    }

    static func isFailureStatus(status: String, errorMessage: String?) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let errorMessage, !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return [
            "failed",
            "error",
            "errored",
            "cancelled",
            "canceled",
            "timed_out"
        ].contains(normalized)
    }
}

enum CodexCommandError: LocalizedError, Equatable {
    case cliNotInstalled
    case notAuthenticated
    case commandFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .cliNotInstalled:
            return "Codex CLI is not installed."
        case .notAuthenticated:
            return "Codex CLI needs login before cloud monitoring can run."
        case .commandFailed(let message):
            return message
        case .invalidResponse(let message):
            return message
        }
    }
}

protocol CodexCommandRunning {
    func codexVersion() async throws -> String
    func listCloudTasks(limit: Int) async throws -> [CodexCloudTask]
    func cloudTaskStatus(taskID: String) async throws -> CodexCloudTaskStatusResponse
}

struct CodexCommandRunResult {
    let terminationStatus: Int32
    let output: Data
}

private final class CodexCommandOutputBox: @unchecked Sendable {
    var data = Data()
}

struct CodexCommandRunner: CodexCommandRunning {
    func codexVersion() async throws -> String {
        let data = try await run(arguments: ["--version"])
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw CodexCommandError.invalidResponse("Codex CLI version output was empty.")
        }
        return text
    }

    func listCloudTasks(limit: Int) async throws -> [CodexCloudTask] {
        let data = try await run(
            arguments: ["cloud", "list", "--json", "--limit", String(limit)]
        )
        do {
            let response = try JSONDecoder().decode(CodexCloudTaskListResponse.self, from: data)
            return response.tasks
        } catch {
            throw CodexCommandError.invalidResponse("Could not read Codex Cloud task list.")
        }
    }

    func cloudTaskStatus(taskID: String) async throws -> CodexCloudTaskStatusResponse {
        let data = try await run(arguments: ["cloud", "status", taskID, "--json"])
        do {
            return try JSONDecoder().decode(CodexCloudTaskStatusResponse.self, from: data)
        } catch {
            throw CodexCommandError.invalidResponse("Could not read Codex Cloud task status.")
        }
    }

    private func run(arguments: [String]) async throws -> Data {
        let result = try await Self.runProcess(
            commandName: "codex",
            arguments: arguments
        )

        guard result.terminationStatus == 0 else {
            let message = String(data: result.output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw classifyError(message)
        }

        return result.output
    }

    static func runProcess(
        commandName: String,
        arguments: [String]
    ) async throws -> CodexCommandRunResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [commandName] + arguments

                let output = Pipe()
                process.standardOutput = output
                process.standardError = output

                let outputBox = CodexCommandOutputBox()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    outputBox.data = output.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                    output.fileHandleForWriting.closeFile()
                    readGroup.wait()
                    continuation.resume(
                        returning: CodexCommandRunResult(
                            terminationStatus: process.terminationStatus,
                            output: outputBox.data
                        )
                    )
                } catch {
                    output.fileHandleForWriting.closeFile()
                    output.fileHandleForReading.closeFile()
                    readGroup.wait()
                    continuation.resume(throwing: CodexCommandError.cliNotInstalled)
                }
            }
        }
    }

    private func classifyError(_ output: String) -> CodexCommandError {
        let normalized = output.lowercased()
        if normalized.contains("no such file or directory")
            || normalized.contains("command not found")
            || normalized.contains("not found") {
            return .cliNotInstalled
        }
        if normalized.contains("login")
            || normalized.contains("not logged in")
            || normalized.contains("authenticate")
            || normalized.contains("auth") {
            return .notAuthenticated
        }
        return .commandFailed(output.isEmpty ? "Codex command failed." : output)
    }
}
