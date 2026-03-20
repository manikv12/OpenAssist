import Foundation

struct AssistantRemoteStatusSnapshot: Sendable {
    let runtimeHealth: AssistantRuntimeHealth
    let selectedSessionID: String?
    let selectedSessionTitle: String?
    let selectedModelID: String?
    let selectedModelSummary: String
    let interactionMode: AssistantInteractionMode
    let reasoningEffort: AssistantReasoningEffort
    let fastModeEnabled: Bool
    let tokenUsage: TokenUsageSnapshot
    let lastStatusMessage: String?
}

struct AssistantRemoteProjectOption: Identifiable, Sendable {
    let id: String
    let name: String
    let linkedFolderPath: String?
    let sessionCount: Int
}

@MainActor
final class AssistantRemoteBridge {
    private let assistant: AssistantStore

    init(assistant: AssistantStore) {
        self.assistant = assistant
    }

    convenience init() {
        self.init(assistant: .shared)
    }

    func prime() async {
        await assistant.refreshEnvironment()
        await assistant.refreshSessions(limit: 20)
    }

    func statusSnapshot() -> AssistantRemoteStatusSnapshot {
        let selectedSession = assistant.sessions.first(where: { $0.id == assistant.selectedSessionID })
        return AssistantRemoteStatusSnapshot(
            runtimeHealth: assistant.runtimeHealth,
            selectedSessionID: assistant.selectedSessionID,
            selectedSessionTitle: selectedSession?.title,
            selectedModelID: assistant.selectedModelID,
            selectedModelSummary: assistant.selectedModelSummary,
            interactionMode: assistant.interactionMode,
            reasoningEffort: assistant.reasoningEffort,
            fastModeEnabled: assistant.fastModeEnabled,
            tokenUsage: assistant.tokenUsage,
            lastStatusMessage: assistant.lastStatusMessage
        )
    }

    func listSessions(limit: Int = 8, projectID: String? = nil) async -> [AssistantSessionSummary] {
        await assistant.refreshSessions(limit: max(limit, 20))
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedProjectID.isEmpty else {
            return Array(assistant.sessions.prefix(limit))
        }

        let matchingSessions = assistant.sessions.filter { session in
            session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }
        return Array(matchingSessions.prefix(limit))
    }

    func availableProjects() async -> [AssistantRemoteProjectOption] {
        await assistant.refreshSessions(limit: 40)
        return assistant.projects.map { project in
            let sessionCount = assistant.sessions.reduce(into: 0) { count, session in
                guard let sessionProjectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      sessionProjectID.caseInsensitiveCompare(project.id) == .orderedSame else {
                    return
                }
                count += 1
            }
            return AssistantRemoteProjectOption(
                id: project.id,
                name: project.name,
                linkedFolderPath: project.linkedFolderPath,
                sessionCount: sessionCount
            )
        }
    }

    func selectProject(_ projectID: String?) async {
        await assistant.selectProjectFilter(projectID)
    }

    func availableModels() async -> [AssistantModelOption] {
        await assistant.refreshEnvironment()
        return assistant.visibleModels
    }

    func openSession(sessionID: String) async -> AssistantRemoteSessionSnapshot? {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }

        if let session = assistant.sessions.first(where: { $0.id == normalizedSessionID }) {
            await assistant.openSession(session)
            return await assistant.remoteSessionSnapshot(sessionID: normalizedSessionID)
        }

        await assistant.refreshSessions(limit: 40)
        if let refreshedSession = assistant.sessions.first(where: { $0.id == normalizedSessionID }) {
            await assistant.openSession(refreshedSession)
            return await assistant.remoteSessionSnapshot(sessionID: normalizedSessionID)
        }

        let loadedSessions = (try? await assistant.sessionCatalog.loadSessions(
            limit: 1,
            preferredThreadID: normalizedSessionID,
            preferredCWD: nil,
            sessionIDs: [normalizedSessionID]
        )) ?? []
        guard let loadedSession = loadedSessions.first else { return nil }
        await assistant.openSession(loadedSession)
        return await assistant.remoteSessionSnapshot(sessionID: normalizedSessionID)
    }

    func startNewSession() async -> AssistantRemoteSessionSnapshot? {
        await assistant.startNewSession()
        guard let sessionID = assistant.selectedSessionID else { return nil }
        return await assistant.remoteSessionSnapshot(sessionID: sessionID)
    }

    func sendPrompt(_ prompt: String, sessionID: String?) async -> AssistantRemoteSessionSnapshot? {
        if let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            _ = await openSession(sessionID: sessionID)
        } else if assistant.selectedSessionID == nil {
            _ = await startNewSession()
        }

        await assistant.sendPrompt(prompt)
        guard let activeSessionID = assistant.selectedSessionID else { return nil }
        return await assistant.remoteSessionSnapshot(sessionID: activeSessionID)
    }

    func chooseModel(_ modelID: String, sessionID: String?) async -> Bool {
        if let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            _ = await openSession(sessionID: sessionID)
        }
        guard assistant.visibleModels.contains(where: { $0.id == modelID }) else {
            return false
        }
        assistant.chooseModel(modelID)
        return true
    }

    func setInteractionMode(_ mode: AssistantInteractionMode, sessionID: String?) async {
        if let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            _ = await openSession(sessionID: sessionID)
        }
        assistant.interactionMode = mode
    }

    func setReasoningEffort(_ effort: AssistantReasoningEffort, sessionID: String?) async {
        if let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            _ = await openSession(sessionID: sessionID)
        }
        assistant.reasoningEffort = effort
        assistant.syncRuntimeContext()
    }

    func sessionSnapshot(sessionID: String) async -> AssistantRemoteSessionSnapshot? {
        await assistant.remoteSessionSnapshot(sessionID: sessionID)
    }

    func cancelActiveTurn() async {
        await assistant.cancelActiveTurn()
    }

    func resolvePermission(optionID: String) async {
        await assistant.resolvePermission(optionID: optionID)
    }

    func resolvePermission(answers: [String: [String]]) async {
        await assistant.resolvePermission(answers: answers)
    }

    func cancelPendingPermissionRequest() async {
        await assistant.cancelPermissionRequest()
    }
}
