import Foundation

/// Lightweight store that collects live activity items emitted by assistant runtimes.
/// The `list_activities` tool reads from this store to give external clients (e.g. Claude Code)
/// a snapshot of what every active session is currently doing.
actor AssistantTaskProgressStore {
    static let shared = AssistantTaskProgressStore()

    private var activitiesByID: [String: AssistantActivityItem] = [:]

    private init() {}

    // MARK: - Mutations

    func upsert(_ activity: AssistantActivityItem) {
        activitiesByID[activity.id] = activity
    }

    func remove(id: String) {
        activitiesByID.removeValue(forKey: id)
    }

    func clearSession(_ sessionID: String) {
        activitiesByID = activitiesByID.filter { $0.value.sessionID != sessionID }
    }

    func clearAll() {
        activitiesByID.removeAll()
    }

    // MARK: - Queries

    func snapshot(sessionID: String? = nil, activeOnly: Bool = false) -> [AssistantActivityItem] {
        var items = activitiesByID.values.sorted { $0.startedAt < $1.startedAt }
        if let sessionID {
            items = items.filter { $0.sessionID == sessionID }
        }
        if activeOnly {
            items = items.filter(\.isActive)
        }
        return items
    }
}
