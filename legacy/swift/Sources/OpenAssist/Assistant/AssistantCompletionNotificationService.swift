import Foundation
import UserNotifications

struct AssistantCompletionNotificationEvent: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case completed
        case failed(reason: String?)
    }

    let sessionID: String
    let sessionTitle: String?
    let turnID: String?
    let outcome: Outcome
    let isBackground: Bool
    let dedupeKey: String?
    let dedupeWindow: TimeInterval

    init(
        sessionID: String,
        sessionTitle: String? = nil,
        turnID: String? = nil,
        outcome: Outcome,
        isBackground: Bool,
        dedupeKey: String? = nil,
        dedupeWindow: TimeInterval = 30
    ) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.turnID = turnID
        self.outcome = outcome
        self.isBackground = isBackground
        self.dedupeKey = dedupeKey
        self.dedupeWindow = dedupeWindow
    }
}

struct AssistantCompletionNotificationPreview: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let subtitle: String?
    let threadIdentifier: String
    let userInfo: [String: String]
}

protocol AssistantCompletionNotificationDelivering {
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
final class AssistantCompletionNotificationService {
    private static let categoryIdentifier = "openassist.assistant.completion"
    private let deliveryCenter: AssistantCompletionNotificationDelivering
    private var lastDeliveredAtByKey: [String: Date] = [:]

    init(
        deliveryCenter: AssistantCompletionNotificationDelivering = AssistantCompletionUserNotificationCenter()
    ) {
        self.deliveryCenter = deliveryCenter
    }

    func preview(for event: AssistantCompletionNotificationEvent) -> AssistantCompletionNotificationPreview? {
        guard event.isBackground else { return nil }

        let sessionID = event.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return nil }

        let title = normalizedTitle(for: event.sessionTitle)
        let body = bodyText(for: event.outcome)
        let subtitle = subtitleText(for: event.outcome)
        let dedupeKey = normalizedDedupeKey(for: event, title: title)

        return AssistantCompletionNotificationPreview(
            identifier: notificationIdentifier(for: dedupeKey),
            title: title,
            body: body,
            subtitle: subtitle,
            threadIdentifier: sessionID,
            userInfo: userInfo(
                sessionID: sessionID,
                turnID: event.turnID,
                outcome: event.outcome,
                dedupeKey: dedupeKey
            )
        )
    }

    func notify(
        for event: AssistantCompletionNotificationEvent,
        now: Date = .now
    ) async -> Bool {
        guard let preview = preview(for: event) else { return false }
        let dedupeKey = preview.userInfo["dedupeKey"] ?? preview.identifier

        if shouldDedupe(key: dedupeKey, now: now, window: event.dedupeWindow) {
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = preview.title
        content.body = preview.body
        content.subtitle = preview.subtitle ?? ""
        content.threadIdentifier = preview.threadIdentifier
        content.categoryIdentifier = Self.categoryIdentifier
        content.sound = .default
        content.userInfo = preview.userInfo

        let request = UNNotificationRequest(
            identifier: preview.identifier,
            content: content,
            trigger: nil
        )

        do {
            try await deliveryCenter.add(request)
            lastDeliveredAtByKey[dedupeKey] = now
            return true
        } catch {
            return false
        }
    }

    func resetDedupe() {
        lastDeliveredAtByKey.removeAll()
    }

    private func shouldDedupe(key: String, now: Date, window: TimeInterval) -> Bool {
        guard window > 0, let lastDeliveredAt = lastDeliveredAtByKey[key] else {
            return false
        }

        return now.timeIntervalSince(lastDeliveredAt) < window
    }

    private func normalizedTitle(for sessionTitle: String?) -> String {
        let trimmed = normalizedText(sessionTitle)
        return trimmed.isEmpty ? "Open Assist" : trimmed
    }

    private func bodyText(for outcome: AssistantCompletionNotificationEvent.Outcome) -> String {
        switch outcome {
        case .completed:
            return "Background chat finished."
        case .failed:
            return "Background chat failed."
        }
    }

    private func subtitleText(for outcome: AssistantCompletionNotificationEvent.Outcome) -> String? {
        switch outcome {
        case .completed:
            return nil
        case .failed(let reason):
            let normalizedReason = normalizedText(reason)
            return normalizedReason.isEmpty ? nil : normalizedReason
        }
    }

    private func normalizedDedupeKey(
        for event: AssistantCompletionNotificationEvent,
        title: String
    ) -> String {
        let explicit = normalizedText(event.dedupeKey)
        if !explicit.isEmpty {
            return explicit
        }

        let turnID = normalizedText(event.turnID)
        let outcomeKey: String
        switch event.outcome {
        case .completed:
            outcomeKey = "completed"
        case .failed:
            outcomeKey = "failed"
        }

        return [
            "assistant-completion",
            normalizedText(event.sessionID).lowercased(),
            turnID.lowercased(),
            outcomeKey,
            title.lowercased()
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    private func notificationIdentifier(for dedupeKey: String) -> String {
        let sanitized = dedupeKey
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return "openassist-assistant-completion-\(sanitized)"
    }

    private func userInfo(
        sessionID: String,
        turnID: String?,
        outcome: AssistantCompletionNotificationEvent.Outcome,
        dedupeKey: String
    ) -> [String: String] {
        var info: [String: String] = [
            "sessionID": sessionID,
            "dedupeKey": dedupeKey
        ]

        let normalizedTurnID = normalizedText(turnID)
        if !normalizedTurnID.isEmpty {
            info["turnID"] = normalizedTurnID
        }

        switch outcome {
        case .completed:
            info["outcome"] = "completed"
        case .failed(let reason):
            info["outcome"] = "failed"
            let normalizedReason = normalizedText(reason)
            if !normalizedReason.isEmpty {
                info["reason"] = normalizedReason
            }
        }

        return info
    }

    private func normalizedText(_ text: String?) -> String {
        guard let text else { return "" }
        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AssistantCompletionUserNotificationCenter: AssistantCompletionNotificationDelivering {
    func add(_ request: UNNotificationRequest) async throws {
        let center = UNUserNotificationCenter.current()
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        try await center.add(request)
    }
}
