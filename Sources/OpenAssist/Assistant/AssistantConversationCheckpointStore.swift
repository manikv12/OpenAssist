import Foundation

enum AssistantConversationCheckpointStoreError: LocalizedError {
    case sessionFileMissing(String)
    case snapshotMissing(String)

    var errorDescription: String? {
        switch self {
        case .sessionFileMissing(let sessionID):
            return "Open Assist could not find the saved Codex thread for \(sessionID)."
        case .snapshotMissing(let path):
            return "Open Assist could not load the saved checkpoint snapshot at \(path)."
        }
    }
}

struct AssistantConversationCheckpointSnapshotPayload: Codable, Equatable {
    let memoryDocumentMarkdown: String?
    let suggestions: [AssistantMemorySuggestion]
    let acceptedEntries: [AssistantMemoryEntry]
    let agentProfile: ConversationAgentProfileRecord?
    let agentEntities: ConversationAgentEntitiesRecord?
    let agentPreferences: ConversationAgentPreferencesRecord?
}

final class AssistantConversationCheckpointStore {
    private let fileManager: FileManager
    private let sessionCatalog: CodexSessionCatalog
    private let conversationStore: AssistantConversationStore?
    private let threadMemoryService: AssistantThreadMemoryService
    private let memorySuggestionService: AssistantMemorySuggestionService
    private let memoryStore: MemorySQLiteStore
    private let agentStateService: ConversationAgentStateService
    let baseDirectoryURL: URL

    init(
        fileManager: FileManager = .default,
        sessionCatalog: CodexSessionCatalog,
        conversationStore: AssistantConversationStore? = nil,
        threadMemoryService: AssistantThreadMemoryService,
        memorySuggestionService: AssistantMemorySuggestionService,
        memoryStore: MemorySQLiteStore,
        agentStateService: ConversationAgentStateService = .shared,
        baseDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.sessionCatalog = sessionCatalog
        self.conversationStore = conversationStore
        self.threadMemoryService = threadMemoryService
        self.memorySuggestionService = memorySuggestionService
        self.memoryStore = memoryStore
        self.agentStateService = agentStateService
        if let baseDirectoryURL {
            self.baseDirectoryURL = baseDirectoryURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.baseDirectoryURL = applicationSupport
                .appendingPathComponent("OpenAssist", isDirectory: true)
                .appendingPathComponent("AssistantCodeTracking", isDirectory: true)
        }
    }

    func loadTrackingState(for sessionID: String) -> AssistantCodeTrackingState? {
        guard let metadataURL = metadataURL(for: sessionID),
              let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode(AssistantCodeTrackingState.self, from: data) else {
            return nil
        }
        return decoded
    }

    func saveTrackingState(_ state: AssistantCodeTrackingState) throws {
        guard let metadataURL = metadataURL(for: state.sessionID) else { return }
        try fileManager.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: metadataURL, options: .atomic)
    }

    func deleteCheckpoints(sessionID: String, checkpointIDs: [String]) {
        for checkpointID in checkpointIDs {
            guard let directoryURL = checkpointDirectoryURL(for: sessionID, checkpointID: checkpointID) else {
                continue
            }
            try? fileManager.removeItem(at: directoryURL)
        }
    }

    func deleteTrackingState(for sessionID: String) {
        guard let sessionDirectoryURL = sessionDirectoryURL(for: sessionID) else { return }
        try? fileManager.removeItem(at: sessionDirectoryURL)
    }

    func captureSnapshot(
        sessionID: String,
        checkpointID: String,
        phase: AssistantCodeCheckpointPhase
    ) async throws {
        guard let checkpointDirectoryURL = checkpointDirectoryURL(for: sessionID, checkpointID: checkpointID) else {
            throw CocoaError(.fileNoSuchFile)
        }

        try fileManager.createDirectory(at: checkpointDirectoryURL, withIntermediateDirectories: true)
        let sessionCopyURL = checkpointDirectoryURL.appendingPathComponent("\(phase.rawValue)-session.jsonl", isDirectory: false)
        let conversationCopyURL = checkpointDirectoryURL.appendingPathComponent("\(phase.rawValue)-openassist-conversation.json", isDirectory: false)
        let conversationEventLogCopyURL = checkpointDirectoryURL.appendingPathComponent(
            "\(phase.rawValue)-openassist-conversation.events.jsonl",
            isDirectory: false
        )
        let payloadURL = checkpointDirectoryURL.appendingPathComponent("\(phase.rawValue)-conversation.json", isDirectory: false)

        let sessionFileURL = sessionCatalog.sessionFileURL(for: sessionID)
        if let sessionFileURL,
           fileManager.fileExists(atPath: sessionFileURL.path) {
            let sessionData = try Data(contentsOf: sessionFileURL)
            try sessionData.write(to: sessionCopyURL, options: .atomic)
        }

        if let conversationSnapshot = conversationStore?.loadSnapshot(threadID: sessionID) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let conversationData = try encoder.encode(conversationSnapshot)
            try conversationData.write(to: conversationCopyURL, options: .atomic)
            if let eventLogURL = conversationStore?.eventLogFileURL(for: sessionID),
               fileManager.fileExists(atPath: eventLogURL.path) {
                let eventLogData = try Data(contentsOf: eventLogURL)
                try eventLogData.write(to: conversationEventLogCopyURL, options: .atomic)
            }
        } else if sessionFileURL == nil || !(fileManager.fileExists(atPath: sessionFileURL?.path ?? "")) {
            throw AssistantConversationCheckpointStoreError.sessionFileMissing(sessionID)
        }

        let payload = AssistantConversationCheckpointSnapshotPayload(
            memoryDocumentMarkdown: try? threadMemoryService.loadTrackedDocument(for: sessionID).document.markdown,
            suggestions: (try? memorySuggestionService.suggestions(for: sessionID)) ?? [],
            acceptedEntries: (try? memoryStore.fetchAssistantMemoryEntries(
                query: "",
                provider: .codex,
                threadID: sessionID,
                state: nil,
                limit: 1_000
            )) ?? [],
            agentProfile: try? await agentStateService.fetchProfile(threadID: sessionID),
            agentEntities: try? await agentStateService.fetchEntities(threadID: sessionID),
            agentPreferences: try? await agentStateService.fetchPreferences(threadID: sessionID)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payloadData = try encoder.encode(payload)
        try payloadData.write(to: payloadURL, options: .atomic)
    }

    func restoreSnapshot(
        sessionID: String,
        checkpointID: String,
        phase: AssistantCodeCheckpointPhase
    ) async throws {
        guard let checkpointDirectoryURL = checkpointDirectoryURL(for: sessionID, checkpointID: checkpointID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let sessionCopyURL = checkpointDirectoryURL.appendingPathComponent("\(phase.rawValue)-session.jsonl", isDirectory: false)
        let conversationCopyURL = checkpointDirectoryURL.appendingPathComponent("\(phase.rawValue)-openassist-conversation.json", isDirectory: false)
        let conversationEventLogCopyURL = checkpointDirectoryURL.appendingPathComponent(
            "\(phase.rawValue)-openassist-conversation.events.jsonl",
            isDirectory: false
        )
        let payloadURL = checkpointDirectoryURL.appendingPathComponent("\(phase.rawValue)-conversation.json", isDirectory: false)

        let hasSessionCopy = fileManager.fileExists(atPath: sessionCopyURL.path)
        let hasConversationCopy = fileManager.fileExists(atPath: conversationCopyURL.path)
        let hasConversationEventLogCopy = fileManager.fileExists(atPath: conversationEventLogCopyURL.path)

        guard (hasSessionCopy || hasConversationCopy),
              fileManager.fileExists(atPath: payloadURL.path) else {
            throw AssistantConversationCheckpointStoreError.snapshotMissing(checkpointDirectoryURL.path)
        }

        let payloadData = try Data(contentsOf: payloadURL)
        let payload = try JSONDecoder().decode(
            AssistantConversationCheckpointSnapshotPayload.self,
            from: payloadData
        )

        if hasSessionCopy,
           let sessionFileURL = sessionCatalog.sessionFileURL(for: sessionID) {
            let sessionData = try Data(contentsOf: sessionCopyURL)
            try sessionData.write(to: sessionFileURL, options: .atomic)
        }

        if hasConversationCopy,
           let conversationStore {
            let conversationData = try Data(contentsOf: conversationCopyURL)
            let snapshot = try JSONDecoder().decode(
                AssistantConversationSnapshot.self,
                from: conversationData
            )
            try conversationStore.storeSnapshot(snapshot)

            if hasConversationEventLogCopy,
               let eventLogURL = conversationStore.eventLogFileURL(for: sessionID) {
                try fileManager.createDirectory(
                    at: eventLogURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let eventLogData = try Data(contentsOf: conversationEventLogCopyURL)
                try eventLogData.write(to: eventLogURL, options: .atomic)
            } else {
                conversationStore.deleteEventLog(threadID: sessionID)
            }
        }

        if let markdown = payload.memoryDocumentMarkdown {
            let memoryDocument = AssistantThreadMemoryDocument.parse(markdown: markdown)
            _ = try threadMemoryService.saveDocument(memoryDocument, for: sessionID)
        } else if threadMemoryService.memoryFileIfExists(for: sessionID) != nil {
            _ = try threadMemoryService.clearThreadMemoryDocument(for: sessionID)
        }

        try memorySuggestionService.replaceSuggestions(
            for: sessionID,
            with: payload.suggestions
        )

        try memoryStore.deleteAssistantMemoryEntries(threadID: sessionID)
        for entry in payload.acceptedEntries {
            try memoryStore.upsertAssistantMemoryEntry(entry)
        }

        try? await agentStateService.clearProfile(threadID: sessionID)
        try? await agentStateService.clearEntities(threadID: sessionID)
        try? await agentStateService.clearPreferences(threadID: sessionID)

        if let profile = payload.agentProfile {
            try? await agentStateService.upsertProfile(profile)
        }
        if let entities = payload.agentEntities {
            try? await agentStateService.upsertEntities(entities)
        }
        if let preferences = payload.agentPreferences {
            try? await agentStateService.upsertPreferences(preferences)
        }
    }

    private func sessionDirectoryURL(for sessionID: String) -> URL? {
        let normalized = safePathComponent(sessionID)
        guard !normalized.isEmpty else { return nil }
        return baseDirectoryURL.appendingPathComponent(normalized, isDirectory: true)
    }

    private func metadataURL(for sessionID: String) -> URL? {
        sessionDirectoryURL(for: sessionID)?
            .appendingPathComponent("state.json", isDirectory: false)
    }

    private func checkpointDirectoryURL(for sessionID: String, checkpointID: String) -> URL? {
        guard let sessionDirectoryURL = sessionDirectoryURL(for: sessionID) else { return nil }
        let normalizedCheckpointID = safePathComponent(checkpointID)
        guard !normalizedCheckpointID.isEmpty else { return nil }
        return sessionDirectoryURL
            .appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(normalizedCheckpointID, isDirectory: true)
    }

    private func safePathComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[^A-Za-z0-9._-]+"#,
                with: "-",
                options: .regularExpression
            )
    }
}
