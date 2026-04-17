import Foundation

enum AssistantSpawnSessionToolDefinition {
    static let name = "spawn_session"
    static let toolKind = "spawnSession"

    static let description = """
    Start a new assistant session with an initial plan or task. The new session runs independently \
    in a separate thread, so the current conversation can continue while the spawned session works \
    in the background. Use this to delegate a coding task, research task, or multi-step plan to a \
    separate session that has its own execution context and tool access.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "task": [
                "type": "string",
                "description": "The task or plan for the new session. Be specific and self-contained — the new session starts with no prior context."
            ],
            "nickname": [
                "type": "string",
                "description": "Optional short name for the spawned session (e.g. 'refactor-auth', 'test-suite')."
            ],
            "role": [
                "type": "string",
                "description": "Optional role hint such as 'software_engineer', 'researcher', or 'code_reviewer'."
            ],
            "working_directory": [
                "type": "string",
                "description": "Optional working directory for the new session."
            ]
        ],
        "required": ["task"]
    ]
}

/// Notification posted when a tool requests spawning a new assistant session.
/// The userInfo dictionary contains:
///   - "task": String — the initial prompt
///   - "nickname": String? — optional short name
///   - "role": String? — optional role hint
///   - "working_directory": String? — optional working directory
///   - "parent_session_id": String? — the spawning session's ID
///   - "spawn_id": String — unique ID for tracking the spawn request
extension Notification.Name {
    static let openAssistSpawnSession = Notification.Name("openAssistSpawnSession")
}

actor AssistantSpawnSessionService {
    struct SpawnRequest: Equatable, Sendable {
        let id: String
        let task: String
        let nickname: String?
        let role: String?
        let workingDirectory: String?
        let parentSessionID: String?

        var summaryLine: String {
            let prefix = nickname ?? role ?? "session"
            let taskPreview = task.prefix(80)
            let ellipsis = task.count > 80 ? "..." : ""
            return "Spawn \(prefix): \(taskPreview)\(ellipsis)"
        }
    }

    static func parseRequest(from arguments: Any) throws -> SpawnRequest {
        guard let dictionary = arguments as? [String: Any] ?? (
            (arguments as? String).flatMap { str in
                (try? JSONSerialization.jsonObject(with: Data(str.utf8))) as? [String: Any]
            }
        ) else {
            return SpawnRequest(
                id: UUID().uuidString,
                task: (arguments as? String) ?? "",
                nickname: nil,
                role: nil,
                workingDirectory: nil,
                parentSessionID: nil
            )
        }

        let task = (dictionary["task"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !task.isEmpty else {
            throw SpawnSessionError.invalidArguments("spawn_session needs a non-empty task.")
        }

        return SpawnRequest(
            id: UUID().uuidString,
            task: task,
            nickname: (dictionary["nickname"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            role: (dictionary["role"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            workingDirectory: (dictionary["working_directory"] as? String ??
                dictionary["workdir"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            parentSessionID: nil
        )
    }

    func run(
        arguments: Any,
        parentSessionID: String?
    ) async -> AssistantToolExecutionResult {
        do {
            var request = try Self.parseRequest(from: arguments)
            request = SpawnRequest(
                id: request.id,
                task: request.task,
                nickname: request.nickname,
                role: request.role,
                workingDirectory: request.workingDirectory,
                parentSessionID: parentSessionID
            )

            // Capture as let for Sendable closure
            let finalRequest = request

            // Post notification for the app layer to create the session
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .openAssistSpawnSession,
                    object: nil,
                    userInfo: [
                        "task": finalRequest.task,
                        "nickname": finalRequest.nickname as Any,
                        "role": finalRequest.role as Any,
                        "working_directory": finalRequest.workingDirectory as Any,
                        "parent_session_id": finalRequest.parentSessionID as Any,
                        "spawn_id": finalRequest.id
                    ]
                )
            }

            let name = finalRequest.nickname ?? finalRequest.role ?? "new session"
            return AssistantToolExecutionResult(
                contentItems: [.init(
                    type: "inputText",
                    text: "Spawned \(name) with task: \(finalRequest.task.prefix(200))\(finalRequest.task.count > 200 ? "..." : "")\n\nThe session is running independently in the background. You can continue working in this conversation.",
                    imageURL: nil
                )],
                success: true,
                summary: "Spawned \(name)"
            )
        } catch {
            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: error.localizedDescription, imageURL: nil)],
                success: false,
                summary: error.localizedDescription
            )
        }
    }
}

enum SpawnSessionError: LocalizedError {
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        }
    }
}
