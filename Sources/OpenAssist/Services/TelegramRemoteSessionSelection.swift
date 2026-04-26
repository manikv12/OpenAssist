import Foundation

struct TelegramRemoteSessionSelection {
    static func restoredSessionID(
        preferredSessionID: String?,
        visibleSessions: [AssistantSessionSummary]
    ) -> String? {
        if let normalizedPreferredSessionID = normalizedSessionID(preferredSessionID),
           let preferredSession = visibleSessions.first(where: {
               normalizedSessionID($0.id) == normalizedPreferredSessionID
           }) {
            return preferredSession.id
        }

        return visibleSessions.first?.id
    }

    static func outgoingTargetSessionID(
        currentSessionID: String?,
        createdSessionID: String?
    ) -> String? {
        normalizedSessionID(currentSessionID) != nil ? currentSessionID : createdSessionID
    }

    private static func normalizedSessionID(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty?.lowercased()
    }
}
