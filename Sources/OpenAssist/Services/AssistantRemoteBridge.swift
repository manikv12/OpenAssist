import Foundation

@MainActor
protocol RemoteAccessBridge: AnyObject {
    func prime() async
    func statusSnapshot() -> AssistantRemoteStatusSnapshot
    func listSessions(
        limit: Int,
        projectID: String?,
        selectedSessionID: String?
    ) async -> [AssistantSessionSummary]
    func availableModels() async -> [AssistantModelOption]
    func availableBackends() -> [AssistantRuntimeBackend]
    func selectBackend(
        _ backend: AssistantRuntimeBackend,
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async -> Bool
    func openSession(
        sessionID: String,
        preserveVisibleSelection: Bool
    ) async -> AssistantRemoteSessionSnapshot?
    func startNewSession(
        projectID: String?,
        preserveVisibleSelection: Bool
    ) async -> AssistantRemoteSessionSnapshot?
    func startNewTemporarySession(
        projectID: String?,
        preserveVisibleSelection: Bool
    ) async -> AssistantRemoteSessionSnapshot?
    func sendPrompt(
        _ prompt: String,
        sessionID: String?,
        projectID: String?,
        selectedPluginIDs: [String],
        oneShotInstructions: String?,
        preserveVisibleSelection: Bool
    ) async -> AssistantRemoteSessionSnapshot?
    func installedCodexPlugins() async -> [AssistantComposerPluginSelection]
    func selectedPluginIDs(
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async -> [String]
    func applyPlugins(
        _ pluginIDs: [String],
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async -> Bool
    func chooseModel(
        _ modelID: String,
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async -> Bool
    func setInteractionMode(
        _ mode: AssistantInteractionMode,
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async
    func setReasoningEffort(
        _ effort: AssistantReasoningEffort,
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async
    func sessionSnapshot(
        sessionID: String,
        projectID: String?,
        selectedSessionID: String?
    ) async -> AssistantRemoteSessionSnapshot?
    func cancelActiveTurn(
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async
    func resolvePermission(
        optionID: String,
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async
    func resolvePermission(
        answers: [String: [String]],
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async
    func cancelPendingPermissionRequest(
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async
    func archiveSession(sessionID: String) async -> Bool
    func deleteSession(sessionID: String) async -> Bool
    func availableProjects() async -> [AssistantRemoteProjectOption]
}

extension RemoteAccessBridge {
    func listSessions(
        limit: Int = 8,
        selectedSessionID: String? = nil
    ) async -> [AssistantSessionSummary] {
        await listSessions(limit: limit, projectID: nil, selectedSessionID: selectedSessionID)
    }

    func startNewSession(
        projectID: String? = nil,
        preserveVisibleSelection: Bool = false
    ) async -> AssistantRemoteSessionSnapshot? {
        await startNewSession(projectID: projectID, preserveVisibleSelection: preserveVisibleSelection)
    }

    func startNewTemporarySession(
        projectID: String? = nil,
        preserveVisibleSelection: Bool = false
    ) async -> AssistantRemoteSessionSnapshot? {
        await startNewTemporarySession(projectID: projectID, preserveVisibleSelection: preserveVisibleSelection)
    }

    func sendPrompt(
        _ prompt: String,
        sessionID: String?,
        selectedPluginIDs: [String] = [],
        oneShotInstructions: String? = nil,
        preserveVisibleSelection: Bool = false
    ) async -> AssistantRemoteSessionSnapshot? {
        await sendPrompt(
            prompt,
            sessionID: sessionID,
            projectID: nil,
            selectedPluginIDs: selectedPluginIDs,
            oneShotInstructions: oneShotInstructions,
            preserveVisibleSelection: preserveVisibleSelection
        )
    }

    func sessionSnapshot(
        sessionID: String,
        projectID: String? = nil,
        selectedSessionID: String? = nil
    ) async -> AssistantRemoteSessionSnapshot? {
        await sessionSnapshot(sessionID: sessionID, projectID: projectID, selectedSessionID: selectedSessionID)
    }
}

struct AssistantRemoteStatusSnapshot: Sendable {
    let runtimeHealth: AssistantRuntimeHealth
    let assistantBackend: AssistantRuntimeBackend
    let selectedSessionID: String?
    let selectedSessionTitle: String?
    let selectedSessionIsTemporary: Bool
    let selectedModelID: String?
    let selectedModelSummary: String
    let interactionMode: AssistantInteractionMode
    let reasoningEffort: AssistantReasoningEffort
    let supportedReasoningEfforts: [AssistantReasoningEffort]
    let canAdjustReasoningEffort: Bool
    let fastModeEnabled: Bool
    let tokenUsage: TokenUsageSnapshot
    let rateLimits: AccountRateLimits
    let lastStatusMessage: String?

    var assistantBackendName: String {
        assistantBackend.displayName
    }
}

struct AssistantRemoteReasoningEffortState: Sendable {
    let efforts: [AssistantReasoningEffort]
    let canAdjust: Bool
}

struct AssistantRemoteProjectOption: Identifiable, Sendable {
    let id: String
    let name: String
    let kind: AssistantProjectKind
    let parentID: String?
    let linkedFolderPath: String?
    let sessionCount: Int
}

@MainActor
final class AssistantRemoteBridge: RemoteAccessBridge {
    private static let passiveSessionRefreshInterval: TimeInterval = 8
    /// How long after a successful environment refresh prime() will skip
    /// re-running the refresh. Subscriber churn (e.g. an iPhone reconnecting
    /// every couple of seconds) used to retrigger refreshEnvironment on every
    /// reconnect, which made the remote runtime status flap between
    /// "Loading models..." and ready.
    private static let environmentRefreshCooldown: TimeInterval = 30

    private let assistant: AssistantStore
    private var lastVisibleSessionsRefreshAt: Date?
    private var lastVisibleSessionsRefreshLimit = 0
    private var lastEnvironmentRefreshAt: Date?

    init(assistant: AssistantStore) {
        self.assistant = assistant
    }

    convenience init() {
        self.init(assistant: .shared)
    }

    func prime() async {
        if shouldRefreshEnvironmentForPrime() {
            await assistant.refreshEnvironment()
            lastEnvironmentRefreshAt = Date()
        }
        await assistant.refreshSessions(limit: 20)
        noteVisibleSessionsRefresh(limit: 20)
    }

    private func shouldRefreshEnvironmentForPrime() -> Bool {
        // Always refresh on the first prime — we have no cached environment yet.
        guard let lastEnvironmentRefreshAt else { return true }
        // If the runtime is not currently in a ready/active state, force a
        // fresh refresh so a recovering subscriber does not stay stuck on a
        // stale "unavailable" snapshot.
        if !assistant.isRuntimeReadyForConversation { return true }
        // Otherwise, skip the costly refresh if a successful one ran recently.
        // This prevents subscriber-reconnect churn from flapping the global
        // isLoadingModels flag and the remote "Loading models..." banner.
        return Date().timeIntervalSince(lastEnvironmentRefreshAt) >= Self.environmentRefreshCooldown
    }

    func statusSnapshot() -> AssistantRemoteStatusSnapshot {
        let selectedSession = assistant.sessions.first { session in
            guard let selectedSessionID = assistant.selectedSessionID else { return false }
            return session.id.caseInsensitiveCompare(selectedSessionID) == .orderedSame
        }
        let effectiveBackend = selectedSession?.activeProviderBackend ?? assistant.visibleAssistantBackend
        let effectiveModelID = selectedSession?.modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? assistant.selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let effectiveEffort = selectedSession?.latestReasoningEffort ?? assistant.reasoningEffort
        let effortState = reasoningEffortState(
            modelID: effectiveModelID,
            currentEffort: effectiveEffort,
            backend: effectiveBackend
        )
        return AssistantRemoteStatusSnapshot(
            runtimeHealth: assistant.runtimeHealth,
            assistantBackend: effectiveBackend,
            selectedSessionID: assistant.selectedSessionID,
            selectedSessionTitle: selectedSession?.title,
            selectedSessionIsTemporary: selectedSession?.isTemporary ?? false,
            selectedModelID: effectiveModelID,
            selectedModelSummary: remoteModelSummary(for: effectiveModelID) ?? assistant.selectedModelSummary,
            interactionMode: selectedSession?.latestInteractionMode?.normalizedForActiveUse ?? assistant.interactionMode,
            reasoningEffort: effectiveEffort,
            supportedReasoningEfforts: effortState.efforts,
            canAdjustReasoningEffort: effortState.canAdjust,
            fastModeEnabled: selectedSession?.fastModeEnabled ?? assistant.fastModeEnabled,
            tokenUsage: assistant.tokenUsage,
            rateLimits: assistant.rateLimits,
            lastStatusMessage: assistant.lastStatusMessage
        )
    }

    func rateLimitsSnapshot() -> AccountRateLimits {
        assistant.rateLimits
    }

    func listSessions(
        limit: Int = 8,
        projectID: String? = nil,
        selectedSessionID: String? = nil
    ) async -> [AssistantSessionSummary] {
        let refreshLimit: Int
        if let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !normalizedProjectID.isEmpty {
            refreshLimit = max(limit * 8, 200)
        } else {
            refreshLimit = max(limit, 20)
        }

        let visibleSessions = await visibleRemoteSessions(
            projectID: projectID,
            selectedSessionID: selectedSessionID,
            refreshLimit: refreshLimit
        )
        return Array(visibleSessions.prefix(limit))
    }

    func availableProjects() async -> [AssistantRemoteProjectOption] {
        await refreshVisibleSessionsIfNeeded(limit: 40)
        return assistant.visibleProjects.map { project in
            let sessionCount = assistant.sessions.reduce(into: 0) { count, session in
                guard let sessionProjectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return
                }
                if project.isFolder {
                    guard let sessionProject = assistant.visibleLeafProjects.first(where: {
                        $0.id.caseInsensitiveCompare(sessionProjectID) == .orderedSame
                    }),
                    sessionProject.parentID?.caseInsensitiveCompare(project.id) == .orderedSame else {
                        return
                    }
                } else if sessionProjectID.caseInsensitiveCompare(project.id) != .orderedSame {
                    return
                }
                count += 1
            }
            return AssistantRemoteProjectOption(
                id: project.id,
                name: project.name,
                kind: project.kind,
                parentID: project.parentID,
                linkedFolderPath: project.linkedFolderPath,
                sessionCount: sessionCount
            )
        }
    }

    func selectProject(
        _ projectID: String?,
        autoSelectVisibleSessionIfNeeded: Bool = true,
        toggleOffIfSame: Bool = true
    ) async {
        await assistant.selectProjectFilter(
            projectID,
            autoSelectVisibleSessionIfNeeded: autoSelectVisibleSessionIfNeeded,
            toggleOffIfSame: toggleOffIfSame
        )
    }

    func availableModels() async -> [AssistantModelOption] {
        return assistant.visibleModels
    }

    func availableBackends() -> [AssistantRuntimeBackend] {
        assistant.selectableAssistantBackends
    }

    func selectBackend(
        _ backend: AssistantRuntimeBackend,
        sessionID: String?,
        preserveVisibleSelection: Bool = false
    ) async -> Bool {
        await withSessionContextReturningBool(
            sessionID: sessionID,
            preserveVisibleSelection: preserveVisibleSelection
        ) { [assistant] in
            await assistant.switchAssistantBackend(backend)
        }
    }

    func reasoningEffortState(
        modelID: String?,
        currentEffort: AssistantReasoningEffort,
        backend: AssistantRuntimeBackend? = nil
    ) -> AssistantRemoteReasoningEffortState {
        guard let trimmedModelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let model = assistant.visibleModels.first(where: {
                  $0.id.caseInsensitiveCompare(trimmedModelID) == .orderedSame
              }) else {
            return AssistantRemoteReasoningEffortState(
                efforts: [currentEffort],
                canAdjust: false
            )
        }

        let supportedEfforts = model.supportedReasoningEfforts.compactMap(AssistantReasoningEffort.init(rawValue:))
        if supportedEfforts.isEmpty {
            if (backend ?? assistant.visibleAssistantBackend) == .copilot {
                return AssistantRemoteReasoningEffortState(
                    efforts: [currentEffort],
                    canAdjust: false
                )
            }

            return AssistantRemoteReasoningEffortState(
                efforts: AssistantReasoningEffort.allCases,
                canAdjust: true
            )
        }

        return AssistantRemoteReasoningEffortState(
            efforts: supportedEfforts,
            canAdjust: true
        )
    }

    func openSession(
        sessionID: String,
        preserveVisibleSelection: Bool = false
    ) async -> AssistantRemoteSessionSnapshot? {
        let openAction: () async -> AssistantRemoteSessionSnapshot? = {
            [assistant] in
            let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSessionID.isEmpty else { return nil }

            if let session = assistant.sessions.first(where: { $0.id.caseInsensitiveCompare(normalizedSessionID) == .orderedSame }) {
                await assistant.openSession(session)
                return await assistant.remoteSessionSnapshot(sessionID: normalizedSessionID)
            }

            await assistant.refreshSessions(limit: 200)
            if let refreshedSession = assistant.sessions.first(where: { $0.id.caseInsensitiveCompare(normalizedSessionID) == .orderedSame }) {
                await assistant.openSession(refreshedSession)
                return await assistant.remoteSessionSnapshot(sessionID: normalizedSessionID)
            }

            guard let snapshot = await assistant.remoteSessionSnapshot(sessionID: normalizedSessionID) else {
                return nil
            }
            await assistant.openSession(snapshot.session)
            return await assistant.remoteSessionSnapshot(sessionID: normalizedSessionID)
        }

        if preserveVisibleSelection {
            return await withPreservedDesktopContext(
                preserveVisibleSelection: true,
                temporaryProjectID: nil,
                operation: openAction
            )
        }

        return await openAction()
    }

    func startNewSession(
        projectID: String? = nil,
        preserveVisibleSelection: Bool = false
    ) async -> AssistantRemoteSessionSnapshot? {
        let allowDraftReuse = !preserveVisibleSelection
        if preserveVisibleSelection {
            return await assistant.startRemoteBackgroundSession(
                projectID: projectID,
                isTemporary: false
            )
        }

        let startAction: () async -> AssistantRemoteSessionSnapshot? = {
            [assistant, self] in
            if allowDraftReuse,
               let reusableSessionID = self.reusableEmptyDraftSessionID(
                   isTemporary: false,
                   projectID: projectID
               ) {
                return await assistant.remoteSessionSnapshot(sessionID: reusableSessionID)
            }
            await assistant.startNewSession()
            guard let sessionID = assistant.selectedSessionID else { return nil }
            return await assistant.remoteSessionSnapshot(sessionID: sessionID)
        }

        await selectProjectContext(projectID)
        return await startAction()
    }

    func startNewTemporarySession(
        projectID: String? = nil,
        preserveVisibleSelection: Bool = false
    ) async -> AssistantRemoteSessionSnapshot? {
        let allowDraftReuse = !preserveVisibleSelection
        if preserveVisibleSelection {
            return await assistant.startRemoteBackgroundSession(
                projectID: projectID,
                isTemporary: true
            )
        }

        let startAction: () async -> AssistantRemoteSessionSnapshot? = {
            [assistant, self] in
            if allowDraftReuse,
               let reusableSessionID = self.reusableEmptyDraftSessionID(
                   isTemporary: true,
                   projectID: projectID
               ) {
                return await assistant.remoteSessionSnapshot(sessionID: reusableSessionID)
            }
            await assistant.startNewTemporarySession()
            guard let sessionID = assistant.selectedSessionID else { return nil }
            return await assistant.remoteSessionSnapshot(sessionID: sessionID)
        }

        await selectProjectContext(projectID)
        return await startAction()
    }

    func sendPrompt(
        _ prompt: String,
        sessionID: String?,
        projectID: String? = nil,
        selectedPluginIDs: [String] = [],
        oneShotInstructions: String? = nil,
        preserveVisibleSelection: Bool = false
    ) async -> AssistantRemoteSessionSnapshot? {
        if preserveVisibleSelection {
            return await assistant.sendRemotePromptInBackground(
                prompt,
                sessionID: sessionID,
                projectID: projectID,
                selectedPluginIDs: selectedPluginIDs,
                oneShotInstructions: oneShotInstructions
            )
        }

        let sendAction: () async -> AssistantRemoteSessionSnapshot? = {
            [assistant, self] in
            if let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sessionID.isEmpty,
               await self.openSession(sessionID: sessionID, preserveVisibleSelection: false) == nil {
                return nil
            }

            await assistant.sendPrompt(
                prompt,
                selectedPluginIDs: selectedPluginIDs,
                oneShotInstructions: oneShotInstructions
            )
            guard let activeSessionID = assistant.selectedSessionID else { return nil }
            return await assistant.remoteSessionSnapshot(sessionID: activeSessionID)
        }

        if preserveVisibleSelection {
            return await withPreservedDesktopContext(
                preserveVisibleSelection: preserveVisibleSelection,
                temporaryProjectID: projectID,
                operation: sendAction
            )
        }

        await selectProjectContext(projectID)
        return await sendAction()
    }

    func installedCodexPlugins() async -> [AssistantComposerPluginSelection] {
        await assistant.refreshCodexPluginCatalogIfNeeded()
        return assistant.installedCodexPluginSelections
    }

    func selectedPluginIDs(
        sessionID: String?,
        preserveVisibleSelection: Bool = false
    ) async -> [String] {
        await withSessionContextReturningValue(
            sessionID: sessionID,
            preserveVisibleSelection: preserveVisibleSelection
        ) { [assistant] in
            assistant.selectedComposerPlugins.map(\.pluginID)
        } fallback: {
            []
        }
    }

    func applyPlugins(
        _ pluginIDs: [String],
        sessionID: String?,
        preserveVisibleSelection: Bool = false
    ) async -> Bool {
        await withSessionContextReturningBool(
            sessionID: sessionID,
            preserveVisibleSelection: preserveVisibleSelection
        ) { [assistant] in
            let installedSelections = assistant.installedCodexPluginSelections
            let requestedIDs = Set(
                pluginIDs.compactMap {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                }
            )
            let selections = installedSelections.filter { requestedIDs.contains($0.pluginID) }
            guard selections.count == requestedIDs.count else {
                return false
            }
            assistant.selectedComposerPlugins = selections
            return true
        }
    }

    private func reusableEmptyDraftSessionID(isTemporary: Bool, projectID: String?) -> String? {
        guard let selectedSessionID = assistant.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let selectedSession = assistant.sessions.first(where: {
                  $0.id.caseInsensitiveCompare(selectedSessionID) == .orderedSame
              }),
              selectedSession.isProviderIndependentThreadV2,
              !selectedSession.isArchived,
              selectedSession.isTemporary == isTemporary,
              normalizedIdentifier(selectedSession.projectID) == normalizedIdentifier(projectID),
              !selectedSession.hasConversationContent else {
            return nil
        }

        return selectedSession.id
    }

    private func withPreservedDesktopContext<Result>(
        preserveVisibleSelection: Bool,
        temporaryProjectID: String?,
        operation: () async -> Result
    ) async -> Result {
        let previousSessionID = assistant.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let previousProjectFilterID = assistant.selectedProjectFilter?.id
        let needsTemporaryProjectChange = normalizedIdentifier(temporaryProjectID) != normalizedIdentifier(previousProjectFilterID)

        if needsTemporaryProjectChange {
            await assistant.selectProjectFilter(
                temporaryProjectID,
                autoSelectVisibleSessionIfNeeded: false,
                toggleOffIfSame: false
            )
        }

        let result = await operation()

        if needsTemporaryProjectChange {
            await assistant.selectProjectFilter(
                previousProjectFilterID,
                autoSelectVisibleSessionIfNeeded: false,
                toggleOffIfSame: false
            )
        }

        guard preserveVisibleSelection,
              let previousSessionID,
              previousSessionID.caseInsensitiveCompare(assistant.selectedSessionID ?? "") != .orderedSame else {
            return result
        }

        if let session = assistant.sessions.first(where: { $0.id.caseInsensitiveCompare(previousSessionID) == .orderedSame }) {
            await assistant.openSession(session)
        } else {
            await refreshVisibleSessionsIfNeeded(limit: 200, force: true)
            if let session = assistant.sessions.first(where: { $0.id.caseInsensitiveCompare(previousSessionID) == .orderedSame }) {
                await assistant.openSession(session)
            }
        }

        return result
    }

    private func selectProjectContext(_ projectID: String?) async {
        let requestedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard normalizedIdentifier(requestedProjectID) != normalizedIdentifier(assistant.selectedProjectFilter?.id) else {
            return
        }

        await assistant.selectProjectFilter(
            requestedProjectID,
            autoSelectVisibleSessionIfNeeded: false,
            toggleOffIfSame: false
        )
    }

    private func normalizedIdentifier(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty?.lowercased()
    }

    private func openRequestedSessionIfNeeded(sessionID: String?) async -> Bool {
        guard let normalizedSessionID = normalizedIdentifier(sessionID) else {
            return true
        }
        return await openSession(sessionID: normalizedSessionID, preserveVisibleSelection: false) != nil
    }

    private func withSessionContext(
        sessionID: String?,
        preserveVisibleSelection: Bool = false,
        operation: @escaping () async -> Void
    ) async {
        let action: () async -> Void = { [self] in
            guard await openRequestedSessionIfNeeded(sessionID: sessionID) else {
                return
            }
            await operation()
        }

        if preserveVisibleSelection {
            await withPreservedDesktopContext(
                preserveVisibleSelection: true,
                temporaryProjectID: nil,
                operation: action
            )
            return
        }

        await action()
    }

    private func withSessionContextReturningBool(
        sessionID: String?,
        preserveVisibleSelection: Bool = false,
        operation: @escaping () async -> Bool
    ) async -> Bool {
        let action: () async -> Bool = { [self] in
            guard await openRequestedSessionIfNeeded(sessionID: sessionID) else {
                return false
            }
            return await operation()
        }

        if preserveVisibleSelection {
            return await withPreservedDesktopContext(
                preserveVisibleSelection: true,
                temporaryProjectID: nil,
                operation: action
            )
        }

        return await action()
    }

    private func withSessionContextReturningValue<Result>(
        sessionID: String?,
        preserveVisibleSelection: Bool = false,
        operation: @escaping () async -> Result,
        fallback: @escaping () -> Result
    ) async -> Result {
        let action: () async -> Result = { [self] in
            guard await openRequestedSessionIfNeeded(sessionID: sessionID) else {
                return fallback()
            }
            return await operation()
        }

        if preserveVisibleSelection {
            return await withPreservedDesktopContext(
                preserveVisibleSelection: true,
                temporaryProjectID: nil,
                operation: action
            )
        }

        return await action()
    }

    private func remoteModelSummary(for modelID: String?) -> String? {
        guard let normalizedModelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        if let matchingModel = assistant.availableModels.first(where: {
            $0.id.caseInsensitiveCompare(normalizedModelID) == .orderedSame
        }) ?? assistant.visibleModels.first(where: {
            $0.id.caseInsensitiveCompare(normalizedModelID) == .orderedSame
        }) {
            return matchingModel.displayName
        }
        return normalizedModelID
    }

    func chooseModel(
        _ modelID: String,
        sessionID: String?,
        preserveVisibleSelection: Bool = false
    ) async -> Bool {
        await withSessionContextReturningBool(
            sessionID: sessionID,
            preserveVisibleSelection: preserveVisibleSelection
        ) { [assistant] in
            guard assistant.visibleModels.contains(where: { $0.id == modelID }) else {
                return false
            }
            assistant.applyRuntimeModelSelection(modelID, force: true)
            return true
        }
    }

    func promoteTemporarySession(
        sessionID: String?,
        preserveVisibleSelection: Bool = false
    ) async -> Bool {
        await withSessionContextReturningBool(
            sessionID: sessionID,
            preserveVisibleSelection: preserveVisibleSelection
        ) { [assistant] in
            guard let selectedSessionID = assistant.selectedSessionID else {
                return false
            }
            guard assistant.sessions.contains(where: {
                $0.id.caseInsensitiveCompare(selectedSessionID) == .orderedSame && $0.isTemporary
            }) else {
                return false
            }
            assistant.promoteTemporarySession(selectedSessionID)
            return true
        }
    }

    func setInteractionMode(
        _ mode: AssistantInteractionMode,
        sessionID: String?,
        preserveVisibleSelection: Bool = false
    ) async {
        await withSessionContext(
            sessionID: sessionID,
            preserveVisibleSelection: preserveVisibleSelection
        ) { [assistant] in
            assistant.interactionMode = mode
        }
    }

    func setReasoningEffort(
        _ effort: AssistantReasoningEffort,
        sessionID: String?,
        preserveVisibleSelection: Bool = false
    ) async {
        await withSessionContext(
            sessionID: sessionID,
            preserveVisibleSelection: preserveVisibleSelection
        ) { [assistant] in
            assistant.reasoningEffort = effort
            assistant.syncRuntimeContext()
        }
    }

    func sessionSnapshot(
        sessionID: String,
        projectID: String? = nil,
        selectedSessionID: String? = nil
    ) async -> AssistantRemoteSessionSnapshot? {
        let visibleSessions = await visibleRemoteSessions(
            projectID: projectID,
            selectedSessionID: selectedSessionID,
            refreshLimit: 200
        )
        guard visibleSessions.contains(where: {
            $0.id.caseInsensitiveCompare(sessionID) == .orderedSame
        }) else {
            return nil
        }
        return await assistant.remoteSessionSnapshot(sessionID: sessionID)
    }

    func cancelActiveTurn(
        sessionID: String? = nil,
        preserveVisibleSelection: Bool = false
    ) async {
        await withSessionContext(
            sessionID: sessionID,
            preserveVisibleSelection: preserveVisibleSelection
        ) { [assistant] in
            await assistant.cancelActiveTurn()
        }
    }

    func resolvePermission(
        optionID: String,
        sessionID: String? = nil,
        preserveVisibleSelection: Bool = false
    ) async {
        await withSessionContext(
            sessionID: sessionID,
            preserveVisibleSelection: preserveVisibleSelection
        ) { [assistant] in
            await assistant.resolvePermission(optionID: optionID)
        }
    }

    func resolvePermission(
        answers: [String: [String]],
        sessionID: String? = nil,
        preserveVisibleSelection: Bool = false
    ) async {
        await withSessionContext(
            sessionID: sessionID,
            preserveVisibleSelection: preserveVisibleSelection
        ) { [assistant] in
            await assistant.resolvePermission(answers: answers)
        }
    }

    func cancelPendingPermissionRequest(
        sessionID: String? = nil,
        preserveVisibleSelection: Bool = false
    ) async {
        await withSessionContext(
            sessionID: sessionID,
            preserveVisibleSelection: preserveVisibleSelection
        ) { [assistant] in
            await assistant.cancelPermissionRequest()
        }
    }

    func archiveSession(sessionID: String) async -> Bool {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        await assistant.archiveSession(
            trimmed,
            retentionHours: SettingsStore.shared.assistantArchiveDefaultRetentionHours,
            updateDefaultRetention: false
        )
        return true
    }

    func deleteSession(sessionID: String) async -> Bool {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        await assistant.deleteSession(trimmed)
        return true
    }

    /// Strip heavy image data from delivered screenshot timeline items to prevent
    /// screenshots from accumulating on disk in the session history.
    func clearDeliveredScreenshotData(sessionID: String? = nil) async {
        assistant.clearDeliveredScreenshotAttachments(sessionID: sessionID)
    }

    private func visibleRemoteSessions(
        projectID: String?,
        selectedSessionID: String?,
        refreshLimit: Int
    ) async -> [AssistantSessionSummary] {
        await refreshVisibleSessionsIfNeeded(limit: refreshLimit)

        let visibleProjectIDs = Set(assistant.visibleLeafProjects.map {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })

        let baseVisibleSessions = assistant.sessions.filter { session in
            guard !session.isArchived,
                  assistantSessionSupportsCurrentThreadUI(session),
                  assistantShouldListSessionInRemoteSurface(
                      session,
                      selectedSessionID: selectedSessionID,
                      canonicalThreadID: canonicalThreadID(forProviderSessionID: session.id)
                  ) else {
                return false
            }

            guard let sessionProjectID = session.projectID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty?
                .lowercased() else {
                return true
            }

            return visibleProjectIDs.contains(sessionProjectID)
        }

        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedProjectID.isEmpty else {
            return baseVisibleSessions
        }

        if let selectedFolder = assistant.visibleFolders.first(where: {
            $0.id.caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }) {
            let descendantProjectIDs = Set<String>(
                assistant.visibleLeafProjects.compactMap { project in
                    guard let parentID = project.parentID,
                          parentID.caseInsensitiveCompare(selectedFolder.id) == .orderedSame else {
                        return nil
                    }
                    return project.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            )

            return baseVisibleSessions.filter { session in
                guard let sessionProjectID = session.projectID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty?
                    .lowercased() else {
                    return false
                }

                return descendantProjectIDs.contains(sessionProjectID)
            }
        }

        return baseVisibleSessions.filter { session in
            session.projectID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }
    }

    private func canonicalThreadID(forProviderSessionID providerSessionID: String?) -> String? {
        guard let normalizedProviderSessionID = normalizedIdentifier(providerSessionID) else {
            return nil
        }

        return assistant.sessions.first(where: { session in
            normalizedIdentifier(session.activeProviderSessionID) == normalizedProviderSessionID
                || session.providerBindingsByBackend.contains(where: { binding in
                    normalizedIdentifier(binding.providerSessionID) == normalizedProviderSessionID
                })
        })?.id
    }

    private func refreshVisibleSessionsIfNeeded(limit: Int, force: Bool = false) async {
        let now = Date()
        let shouldRefresh =
            force
            || assistant.sessions.isEmpty
            || lastVisibleSessionsRefreshAt == nil
            || limit > lastVisibleSessionsRefreshLimit
            || now.timeIntervalSince(lastVisibleSessionsRefreshAt ?? .distantPast) >= Self.passiveSessionRefreshInterval

        guard shouldRefresh else { return }
        await assistant.refreshSessions(limit: limit)
        noteVisibleSessionsRefresh(limit: limit, at: now)
    }

    private func noteVisibleSessionsRefresh(limit: Int, at date: Date = Date()) {
        lastVisibleSessionsRefreshAt = date
        lastVisibleSessionsRefreshLimit = max(lastVisibleSessionsRefreshLimit, limit)
    }
}
