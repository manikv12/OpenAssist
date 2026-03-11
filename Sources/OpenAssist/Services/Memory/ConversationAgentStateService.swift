import Foundation

actor ConversationAgentStateService {
    static let shared = ConversationAgentStateService()

    private let storeFactory: @Sendable () throws -> MemorySQLiteStore
    private var store: MemorySQLiteStore?

    init(
        storeFactory: @escaping @Sendable () throws -> MemorySQLiteStore = { try MemorySQLiteStore() }
    ) {
        self.storeFactory = storeFactory
    }

    func upsertProfile(_ profile: ConversationAgentProfileRecord) throws {
        let store = try resolvedStore()
        try store.upsertConversationAgentProfile(profile)
    }

    func fetchProfile(threadID: String) throws -> ConversationAgentProfileRecord? {
        let store = try resolvedStore()
        return try store.fetchConversationAgentProfile(threadID: threadID)
    }

    func clearProfile(threadID: String) throws {
        let store = try resolvedStore()
        try store.clearConversationAgentProfile(threadID: threadID)
    }

    func upsertEntities(_ entities: ConversationAgentEntitiesRecord) throws {
        let store = try resolvedStore()
        try store.upsertConversationAgentEntities(entities)
    }

    func fetchEntities(threadID: String) throws -> ConversationAgentEntitiesRecord? {
        let store = try resolvedStore()
        return try store.fetchConversationAgentEntities(threadID: threadID)
    }

    func clearEntities(threadID: String) throws {
        let store = try resolvedStore()
        try store.clearConversationAgentEntities(threadID: threadID)
    }

    func upsertPreferences(_ preferences: ConversationAgentPreferencesRecord) throws {
        let store = try resolvedStore()
        try store.upsertConversationAgentPreferences(preferences)
    }

    func fetchPreferences(threadID: String) throws -> ConversationAgentPreferencesRecord? {
        let store = try resolvedStore()
        return try store.fetchConversationAgentPreferences(threadID: threadID)
    }

    func clearPreferences(threadID: String) throws {
        let store = try resolvedStore()
        try store.clearConversationAgentPreferences(threadID: threadID)
    }

    func clearAllAgentState() throws {
        let store = try resolvedStore()
        try store.clearAllConversationAgentState()
    }

    func purgeExpiredAgentState(
        now: Date = Date()
    ) throws -> (profilesDeleted: Int, entitiesDeleted: Int, preferencesDeleted: Int) {
        let store = try resolvedStore()
        return try store.purgeExpiredAgentState(now: now)
    }

    private func resolvedStore() throws -> MemorySQLiteStore {
        if let store {
            return store
        }
        let createdStore = try storeFactory()
        store = createdStore
        return createdStore
    }
}
