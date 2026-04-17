import Foundation

enum AssistantListActivitiesToolDefinition {
    static let name = "list_activities"
    static let toolKind = "activityInspection"

    static let description = """
    Return a snapshot of recent assistant activity items — tool calls, shell commands, browser actions, and subagent steps — across all active sessions. Use this to check what the assistant is currently doing or recently did. Pass active_only=true to see only in-progress steps.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "session_id": [
                "type": "string",
                "description": "Optional session ID filter. Omit to see activities from all sessions."
            ],
            "active_only": [
                "type": "boolean",
                "description": "When true, return only in-progress activities (pending, running, or waiting). Default false."
            ],
            "limit": [
                "type": "integer",
                "description": "Maximum number of activities to return. Default 20, max 100."
            ]
        ],
        "additionalProperties": true
    ]
}

enum AssistantListActivitiesService {
    struct Request: Equatable, Sendable {
        let sessionID: String?
        let activeOnly: Bool
        let limit: Int

        var summaryLine: String { "List recent activities" }
    }

    static func parseRequest(from arguments: Any) throws -> Request {
        let dict = normalizedDictionary(from: arguments) ?? [:]
        let limit = min(max(integer(from: dict["limit"]) ?? 20, 1), 100)
        return Request(
            sessionID: (dict["session_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            activeOnly: boolean(from: dict["active_only"]) ?? false,
            limit: limit
        )
    }

    static func run(arguments: Any) async -> AssistantToolExecutionResult {
        let request: Request
        do {
            request = try parseRequest(from: arguments)
        } catch {
            let msg = error.localizedDescription
            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: msg, imageURL: nil)],
                success: false,
                summary: msg
            )
        }

        let items = await AssistantTaskProgressStore.shared.snapshot(
            sessionID: request.sessionID,
            activeOnly: request.activeOnly
        )

        if items.isEmpty {
            let message = request.activeOnly
                ? "No active activities right now."
                : "No recent activities found."
            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: message, imageURL: nil)],
                success: true,
                summary: message
            )
        }

        let limited = Array(items.suffix(request.limit))
        let lines: [String] = limited.map { activity in
            let sessionLabel = activity.sessionID.map { "[\($0.prefix(8))] " } ?? ""
            let elapsed = Int(activity.updatedAt.timeIntervalSince(activity.startedAt))
            let durationStr = elapsed >= 1 ? " +\(elapsed)s" : ""
            return "\(activity.status.rawValue.uppercased())\(durationStr)  \(sessionLabel)\(activity.title): \(activity.friendlySummary)"
        }
        let message = (["Activities (\(limited.count)):"] + lines).joined(separator: "\n")
        return AssistantToolExecutionResult(
            contentItems: [.init(type: "inputText", text: message, imageURL: nil)],
            success: true,
            summary: "Listed \(limited.count) activit\(limited.count == 1 ? "y" : "ies")."
        )
    }

    // MARK: - Helpers

    private static func normalizedDictionary(from arguments: Any) -> [String: Any]? {
        if let dictionary = arguments as? [String: Any] { return dictionary }
        if let json = arguments as? String,
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        return nil
    }

    private static func integer(from value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func boolean(from value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }
}
