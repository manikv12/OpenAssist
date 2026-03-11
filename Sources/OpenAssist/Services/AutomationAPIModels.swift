import Foundation

enum AutomationAPIChannel: String, CaseIterable, Codable, Hashable, Identifiable {
    case notification
    case speech
    case sound

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notification:
            return "Desktop notification"
        case .speech:
            return "Speak message"
        case .sound:
            return "Play sound"
        }
    }
}

enum AutomationAPISound: String, CaseIterable, Codable, Hashable, Identifiable {
    case startListening
    case processing
    case pasted
    case correctionLearned
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .startListening:
            return "Start Listening"
        case .processing:
            return "Processing"
        case .pasted:
            return "Pasted"
        case .correctionLearned:
            return "Correction Learned"
        case .none:
            return "None"
        }
    }
}

enum AutomationAPINotificationAuthorizationState: String, Codable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown

    var displayName: String {
        switch self {
        case .notDetermined:
            return "Not Requested"
        case .denied:
            return "Denied"
        case .authorized:
            return "Allowed"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        case .unknown:
            return "Unknown"
        }
    }
}

struct AutomationAPIVoiceOption: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let language: String

    var displayLabel: String {
        if language.isEmpty {
            return name
        }
        return "\(name) (\(language))"
    }
}

struct AutomationAPIAnnounceRequest: Codable, Equatable {
    let message: String
    let title: String?
    let subtitle: String?
    let channels: [AutomationAPIChannel]?
    let voiceIdentifier: String?
    let sound: AutomationAPISound?
    let source: String?
    let dedupeKey: String?
    let dedupeWindowSeconds: Int?
}

struct AutomationAPIResolvedAnnouncement: Equatable {
    let message: String
    let title: String
    let subtitle: String?
    let channels: [AutomationAPIChannel]
    let voiceIdentifier: String?
    let sound: AutomationAPISound
    let source: String
    let dedupeKey: String?
    let dedupeWindowSeconds: Int
}

struct AutomationAPIActionResponse: Codable, Equatable {
    let requestId: String
    let accepted: Bool
    let deliveredChannels: [AutomationAPIChannel]
    let deduped: Bool
    let receivedAt: String
}

struct AutomationAPIHealthResponse: Codable, Equatable {
    let serverState: String
    let version: String
    let bindAddress: String
    let port: Int
    let enabledChannels: [AutomationAPIChannel]
    let notificationPermission: AutomationAPINotificationAuthorizationState
    let selectedVoice: AutomationAPIVoiceOption?
    let selectedSound: AutomationAPISound

    static func make(
        serverState: String,
        version: String,
        bindAddress: String,
        port: Int,
        enabledChannels: [AutomationAPIChannel],
        notificationPermission: AutomationAPINotificationAuthorizationState,
        selectedVoice: AutomationAPIVoiceOption?,
        selectedSound: AutomationAPISound
    ) -> AutomationAPIHealthResponse {
        AutomationAPIHealthResponse(
            serverState: serverState,
            version: version,
            bindAddress: bindAddress,
            port: port,
            enabledChannels: enabledChannels,
            notificationPermission: notificationPermission,
            selectedVoice: selectedVoice,
            selectedSound: selectedSound
        )
    }
}

struct AutomationAPIErrorResponse: Codable, Equatable {
    let error: String
}

struct AutomationAPIServerConfiguration: Equatable {
    let enabled: Bool
    let port: UInt16
    let token: String
    let defaultChannels: [AutomationAPIChannel]
    let defaultVoiceIdentifier: String?
    let defaultSound: AutomationAPISound
}

enum AutomationAPIRequestError: LocalizedError, Equatable {
    case unauthorized
    case forbidden(String)
    case invalidRequest(String)
    case unsupportedHookEvent(String)
    case notFound
    case methodNotAllowed

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Missing or invalid bearer token."
        case .forbidden(let message):
            return message
        case .invalidRequest(let message):
            return message
        case .unsupportedHookEvent(let event):
            return "Unsupported Claude hook event: \(event)"
        case .notFound:
            return "Endpoint not found."
        case .methodNotAllowed:
            return "Method not allowed."
        }
    }
}

enum AutomationAPIAuthorization {
    static func bearerToken(from authorizationHeader: String?) -> String? {
        guard let authorizationHeader else { return nil }
        let trimmed = authorizationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].lowercased() == "bearer" else {
            return nil
        }
        let token = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func isAuthorized(authorizationHeader: String?, expectedToken: String) -> Bool {
        let normalizedExpectedToken = expectedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedExpectedToken.isEmpty else { return false }
        return bearerToken(from: authorizationHeader) == normalizedExpectedToken
    }
}

final class AutomationAPIDedupeStore {
    private var recentDedupes: [String: Date] = [:]

    func shouldDedupe(key: String?, now: Date, windowSeconds: Int) -> Bool {
        let normalizedKey = key?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedKey.isEmpty, windowSeconds > 0 else {
            return false
        }

        cleanup(before: now.addingTimeInterval(-300))
        if let previousDate = recentDedupes[normalizedKey],
           now.timeIntervalSince(previousDate) < Double(windowSeconds) {
            return true
        }

        recentDedupes[normalizedKey] = now
        return false
    }

    func cleanup(before cutoff: Date) {
        recentDedupes = recentDedupes.filter { $0.value >= cutoff }
    }
}

enum AutomationAPIRequestResolver {
    static func resolveRequestedChannels(
        requestedChannels: [AutomationAPIChannel],
        enabledChannels: [AutomationAPIChannel]
    ) throws -> [AutomationAPIChannel] {
        let enabledSet = Set(enabledChannels)
        guard !enabledSet.isEmpty else {
            throw AutomationAPIRequestError.forbidden("No automation delivery channels are enabled.")
        }

        for channel in requestedChannels where !enabledSet.contains(channel) {
            throw AutomationAPIRequestError.forbidden("Requested automation channel is disabled in Settings.")
        }

        return requestedChannels
    }

    static func notificationPermittedChannels(
        from requestedChannels: [AutomationAPIChannel],
        notificationAuthorizationState: AutomationAPINotificationAuthorizationState
    ) -> [AutomationAPIChannel] {
        requestedChannels.filter { channel in
            switch channel {
            case .notification:
                return notificationAuthorizationState == .authorized
                    || notificationAuthorizationState == .provisional
                    || notificationAuthorizationState == .ephemeral
            case .speech, .sound:
                return true
            }
        }
    }
}

private struct ClaudeCodeHookPayload: Decodable {
    let hookEventName: String?
    let sessionID: String?
    let cwd: String?
    let transcriptPath: String?
    let title: String?
    let message: String?
    let notificationType: String?
    let lastAssistantMessage: String?
    let agentID: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case title
        case message
        case notificationType = "notification_type"
        case lastAssistantMessage = "last_assistant_message"
        case agentID = "agent_id"
    }
}

enum ClaudeCodeHookAdapter {
    static func adapt(_ data: Data) throws -> AutomationAPIAnnounceRequest {
        let decoder = JSONDecoder()
        let payload: ClaudeCodeHookPayload
        do {
            payload = try decoder.decode(ClaudeCodeHookPayload.self, from: data)
        } catch {
            throw AutomationAPIRequestError.invalidRequest("Invalid Claude hook JSON payload.")
        }

        let normalizedEvent = normalize(payload.hookEventName)

        switch normalizedEvent {
        case "notification":
            return try notificationRequest(from: payload)
        case "stop":
            return stopRequest(from: payload, isSubagent: false)
        case "subagentstop":
            return stopRequest(from: payload, isSubagent: true)
        case "":
            if payload.notificationType != nil || payload.message != nil || payload.title != nil {
                return try notificationRequest(from: payload)
            }
            throw AutomationAPIRequestError.invalidRequest("Missing Claude hook event name.")
        default:
            throw AutomationAPIRequestError.unsupportedHookEvent(normalizedEvent)
        }
    }

    private static func notificationRequest(from payload: ClaudeCodeHookPayload) throws -> AutomationAPIAnnounceRequest {
        let message = summarizeNotificationMessage(
            payload.message,
            notificationType: payload.notificationType
        )
        guard !message.isEmpty else {
            throw AutomationAPIRequestError.invalidRequest("Claude Notification payload is missing message.")
        }

        let title = collapseWhitespace(payload.title).isEmpty ? "Claude Code" : collapseWhitespace(payload.title)
        let subtitle = notificationSubtitle(for: payload.notificationType)

        return AutomationAPIAnnounceRequest(
            message: message,
            title: title,
            subtitle: subtitle,
            channels: nil,
            voiceIdentifier: nil,
            sound: nil,
            source: "claude-code.notification",
            dedupeKey: dedupeKey(
                event: "notification",
                sessionID: payload.sessionID,
                message: message
            ),
            dedupeWindowSeconds: 15
        )
    }

    private static func stopRequest(
        from payload: ClaudeCodeHookPayload,
        isSubagent: Bool
    ) -> AutomationAPIAnnounceRequest {
        let fallbackMessage = isSubagent
            ? "Claude subagent finished."
            : "Claude Code finished."
        let source = isSubagent ? "claude-code.subagent-stop" : "claude-code.stop"
        let message = summarizeStopMessage(payload.lastAssistantMessage, fallback: fallbackMessage)

        return AutomationAPIAnnounceRequest(
            message: message,
            title: "Claude Code",
            subtitle: nil,
            channels: nil,
            voiceIdentifier: nil,
            sound: nil,
            source: source,
            dedupeKey: dedupeKey(
                event: isSubagent ? "subagentstop" : "stop",
                sessionID: payload.sessionID ?? payload.agentID,
                message: message
            ),
            dedupeWindowSeconds: 30
        )
    }

    private static func summarizeStopMessage(_ rawValue: String?, fallback: String) -> String {
        let cleaned = cleanedClaudeMessage(rawValue)
        guard !cleaned.isEmpty else {
            return fallback
        }
        return cleaned
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

    private static func readableLabel(from value: String) -> String? {
        guard !value.isEmpty else { return nil }
        return value
            .split(separator: "_")
            .map { segment in
                let lower = segment.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func notificationSubtitle(for notificationType: String?) -> String? {
        switch normalize(notificationType) {
        case "idle_prompt":
            return "Ready for input"
        case "permission_prompt":
            return "Needs permission"
        case "task_complete":
            return nil
        default:
            return readableLabel(from: collapseWhitespace(notificationType))
        }
    }

    private static func summarizeNotificationMessage(
        _ rawValue: String?,
        notificationType: String?
    ) -> String {
        switch normalize(notificationType) {
        case "idle_prompt":
            return "Claude is waiting for your input."
        case "permission_prompt":
            let cleaned = cleanedClaudeMessage(rawValue)
            return cleaned.isEmpty ? "Claude needs your permission." : cleaned
        case "task_complete":
            let cleaned = cleanedClaudeMessage(rawValue)
            return cleaned.isEmpty ? "Claude finished a task." : cleaned
        default:
            return cleanedClaudeMessage(rawValue)
        }
    }

    private static func cleanedClaudeMessage(_ rawValue: String?) -> String {
        guard let rawValue else { return "" }

        let cleanedLines = rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "```", with: " ")
            .replacingOccurrences(of: "`", with: "")
            .components(separatedBy: .newlines)
            .map { cleanedClaudeLine($0) }
            .filter { !$0.isEmpty }

        let combined = stripLeadIn(
            collapseWhitespace(cleanedLines.joined(separator: " "))
        )
        guard !combined.isEmpty else {
            return ""
        }

        let summary = bestSummarySentence(from: combined)
        return truncate(summary.isEmpty ? combined : summary, limit: 160)
    }

    private static func cleanedClaudeLine(_ rawLine: String) -> String {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else {
            return ""
        }

        line = line.replacingOccurrences(
            of: #"^\s*(?:[-*•]\s+|\d+\.\s+|#+\s+|>\s+)"#,
            with: "",
            options: .regularExpression
        )
        return collapseWhitespace(line)
    }

    private static func stripLeadIn(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadIns = [
            "here's what i did:",
            "here’s what i did:",
            "here is what i did:",
            "what i changed:",
            "quick summary:",
            "summary:",
            "summary",
            "done:",
            "completed:",
            "task complete:",
            "finished:"
        ]

        let lowered = cleaned.lowercased()
        for leadIn in leadIns where lowered.hasPrefix(leadIn) {
            cleaned = String(cleaned.dropFirst(leadIn.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        return cleaned
    }

    private static func bestSummarySentence(from value: String) -> String {
        let candidates = value
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { normalizeSummarySentence($0) }
            .filter { !$0.isEmpty }

        if let candidate = candidates.first(where: { !isTrailingBoilerplate($0) }) {
            return candidate
        }

        return normalizeSummarySentence(value)
    }

    private static func normalizeSummarySentence(_ value: String) -> String {
        var cleaned = stripLeadIn(collapseWhitespace(value))
        guard !cleaned.isEmpty else {
            return ""
        }

        let firstPersonPrefixes = [
            "i've ",
            "i have ",
            "i "
        ]
        let lowercased = cleaned.lowercased()
        for prefix in firstPersonPrefixes where lowercased.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
            break
        }

        cleaned = collapseWhitespace(cleaned)
        guard !cleaned.isEmpty else {
            return ""
        }

        let firstCharacter = String(cleaned.prefix(1)).uppercased()
        return firstCharacter + cleaned.dropFirst()
    }

    private static func isTrailingBoilerplate(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered.hasPrefix("let me know")
            || lowered.hasPrefix("if you want")
            || lowered.hasPrefix("if you'd like")
            || lowered.hasPrefix("i can also")
            || lowered.hasPrefix("next steps")
            || lowered.hasPrefix("would you like")
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else {
            return value
        }

        let index = value.index(value.startIndex, offsetBy: max(0, limit - 3))
        return String(value[..<index]) + "..."
    }

    private static func dedupeKey(event: String, sessionID: String?, message: String) -> String {
        let normalizedSessionID = collapseWhitespace(sessionID)
        return "claude:\(event):\(normalizedSessionID):\(message.lowercased())"
    }
}
