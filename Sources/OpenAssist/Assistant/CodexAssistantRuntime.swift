import Foundation

enum CodexAssistantRuntimeError: Error, LocalizedError {
    case codexMissing
    case runtimeUnavailable(String)
    case requestFailed(String)
    case sessionUnavailable
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .codexMissing:
            return "Codex is not installed on this Mac."
        case .runtimeUnavailable(let message):
            return message
        case .requestFailed(let message):
            return message
        case .sessionUnavailable:
            return "There is no active assistant session yet."
        case .invalidResponse(let message):
            return message
        }
    }
}

private struct CodexResponsePayload: @unchecked Sendable {
    let raw: Any
}

private enum JSONRPCRequestID: Hashable, Sendable {
    case int(Int)
    case string(String)

    var rawValue: Any {
        switch self {
        case .int(let value):
            return value
        case .string(let value):
            return value
        }
    }
}

private enum CodexIncomingEvent: @unchecked Sendable {
    case notification(method: String, params: [String: Any])
    case serverRequest(id: JSONRPCRequestID, method: String, params: [String: Any])
    case statusMessage(String)
    case processExited(String?)
}

struct AssistantRepeatedCommandLimitHit: Equatable, Sendable {
    let command: String
    let attemptCount: Int
}

struct AssistantRepeatedCommandTracker: Sendable {
    private(set) var lastSignature: String?
    private(set) var consecutiveCount = 0

    mutating func reset() {
        lastSignature = nil
        consecutiveCount = 0
    }

    mutating func record(
        command: String,
        maxAttempts: Int
    ) -> AssistantRepeatedCommandLimitHit? {
        guard maxAttempts > 0,
              let signature = Self.normalizedSignature(for: command) else {
            return nil
        }

        if signature == lastSignature {
            consecutiveCount += 1
        } else {
            lastSignature = signature
            consecutiveCount = 1
        }

        guard consecutiveCount >= maxAttempts else {
            return nil
        }

        return AssistantRepeatedCommandLimitHit(
            command: Self.collapsedCommandText(command),
            attemptCount: consecutiveCount
        )
    }

    static func normalizedSignature(for command: String) -> String? {
        let collapsed = collapsedCommandText(command)
        return collapsed.isEmpty ? nil : collapsed
    }

    static func collapsedCommandText(_ command: String) -> String {
        command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
    }
}

struct CodexTranscriptionAuthContext: Sendable {
    let authMode: AssistantAccountAuthMode
    let token: String

    var usesOpenAIAPI: Bool {
        authMode == .apiKey
    }
}

enum AssistantTurnCompletionStatus: Equatable {
    case completed
    case interrupted
    case failed(message: String)
}

@MainActor
final class CodexAssistantRuntime {
    var backend: AssistantRuntimeBackend = .codex
    var onHealthUpdate: (@Sendable (AssistantRuntimeHealth) -> Void)?
    var onTranscript: (@Sendable (AssistantTranscriptEntry) -> Void)?
    var onTranscriptMutation: (@Sendable (AssistantTranscriptMutation) -> Void)?
    var onTimelineMutation: (@Sendable (AssistantTimelineMutation) -> Void)?
    var onHUDUpdate: (@Sendable (AssistantHUDState) -> Void)?
    var onPlanUpdate: (@Sendable ([AssistantPlanEntry]) -> Void)?
    var onToolCallUpdate: (@Sendable ([AssistantToolCallState]) -> Void)?
    var onPermissionRequest: (@Sendable (AssistantPermissionRequest?) -> Void)?
    var onSessionChange: (@Sendable (String?) -> Void)?
    var onStatusMessage: (@Sendable (String?) -> Void)?
    var onAccountUpdate: (@Sendable (AssistantAccountSnapshot) -> Void)?
    var onModelsUpdate: (@Sendable ([AssistantModelOption]) -> Void)?
    var onTokenUsageUpdate: (@Sendable (TokenUsageSnapshot) -> Void)?
    var onRateLimitsUpdate: (@Sendable (AccountRateLimits) -> Void)?
    var onSubagentUpdate: (@Sendable ([SubagentState]) -> Void)?
    var onProposedPlan: (@Sendable (String?) -> Void)?
    var onModeRestriction: (@Sendable (AssistantModeRestrictionEvent) -> Void)?
    var onTurnCompletion: (@Sendable (AssistantTurnCompletionStatus) -> Void)?
    /// Fired after the first successful turn of a new session with (sessionID, userPrompt, assistantResponse).
    var onTitleRequest: (@Sendable (_ sessionID: String, _ userPrompt: String, _ assistantResponse: String) -> Void)?

    private var transport: CodexAppServerTransport?
    private var activeSessionID: String?
    private var activeSessionCWD: String?
    private var activeTurnID: String?
    private var preferredModelID: String?
    private var preferredSubagentModelID: String?
    private var currentCodexPath: String?
    private var currentTransportWorkingDirectory: String?
    private var transportSessionID: String?
    private var bootstrapSessionID: String?
    private var currentAccountSnapshot: AssistantAccountSnapshot = .signedOut
    private var currentRateLimits: AccountRateLimits = .empty
    private var currentModels: [AssistantModelOption] = []
    private var toolCalls: [String: AssistantToolCallState] = [:]
    private var liveActivities: [String: AssistantActivityItem] = [:]
    private var pendingPermissionContext: PendingPermissionContext?
    private var loginRefreshTask: Task<Void, Never>?
    private var metadataRefreshTask: Task<Void, Never>?
    private var transportStartupTask: Task<Void, Error>?
    private var turnToolCallCount = 0
    private var repeatedCommandTracker = AssistantRepeatedCommandTracker()
    private var sessionTurnCount = 0
    private var firstTurnUserPrompt: String?
    var maxToolCallsPerTurn: Int = 75
    var maxRepeatedCommandAttemptsPerTurn: Int = 3

    // Title generation: ephemeral thread whose notifications are filtered from the main UI
    private var titleGenThreadID: String?
    private var titleGenBuffer: String = ""
    private var titleGenContinuation: CheckedContinuation<String, Never>?

    // Streaming buffer: accumulates agentMessage deltas into a single growing entry
    private var streamingEntryID: UUID?
    private var streamingBuffer: String = ""
    private var pendingStreamingDeltaBuffer: String = ""
    private var streamingTimelineID: String?
    private var streamingStartedAt: Date?
    private var commentaryTimelineID: String?
    private var commentaryStartedAt: Date?
    private var commentaryBuffer: String = ""
    private var pendingCommentaryDeltaBuffer: String = ""
    private var pendingCopilotFallbackReply: String?
    private var planTimelineID: String?
    private var planStartedAt: Date?
    private let installSupport: CodexInstallSupport

    // Throttle state for high-frequency updates
    private var lastHUDEmitTime: CFAbsoluteTime = 0
    private var lastHUDPhase: AssistantHUDPhase?
    private var pendingHUDState: AssistantHUDState?
    private var hudThrottleItem: DispatchWorkItem?
    private var lastTimelineMutationTime: CFAbsoluteTime = 0
    private var pendingAssistantTimelineEmit: DispatchWorkItem?
    private var pendingToolCallEmit: DispatchWorkItem?
    private var lastStreamingTranscriptEmitTime: CFAbsoluteTime = 0
    private var pendingStreamingTranscriptEmit: DispatchWorkItem?
    private var lastCommentaryTimelineEmitTime: CFAbsoluteTime = 0
    private var pendingCommentaryTimelineEmit: DispatchWorkItem?
    private var lastActivityTimelineEmitTimeByID: [String: CFAbsoluteTime] = [:]
    private var pendingActivityTimelineEmitByID: [String: DispatchWorkItem] = [:]

    // Subagent tracking
    private var activeSubagents: [String: SubagentState] = [:]
    private let browserUseService: AssistantBrowserUseService
    private let appActionService: AssistantAppActionService
    private let computerUseService: AssistantComputerUseService
    private let imageGenerationService: AssistantImageGenerationService
    private var approvedDynamicToolKindsBySessionID: [String: Set<String>] = [:]

    var currentSessionID: String? {
        activeSessionID
    }

    var currentTurnID: String? {
        activeTurnID
    }

    var currentSessionCWD: String? {
        activeSessionCWD
    }

    var hasActiveTurn: Bool {
        activeTurnID != nil
    }

    init(
        preferredModelID: String? = nil,
        preferredSubagentModelID: String? = nil,
        browserUseService: AssistantBrowserUseService? = nil,
        appActionService: AssistantAppActionService? = nil,
        computerUseService: AssistantComputerUseService? = nil,
        imageGenerationService: AssistantImageGenerationService? = nil,
        installSupport: CodexInstallSupport = CodexInstallSupport()
    ) {
        self.preferredModelID = preferredModelID?.nonEmpty
        self.preferredSubagentModelID = preferredSubagentModelID?.nonEmpty
        self.browserUseService = browserUseService ?? AssistantBrowserUseService(
            settings: .shared
        )
        self.appActionService = appActionService ?? AssistantAppActionService()
        self.computerUseService = computerUseService ?? AssistantComputerUseService()
        self.imageGenerationService = imageGenerationService ?? AssistantImageGenerationService()
        self.installSupport = installSupport
    }

    func setPreferredModelID(_ modelID: String?) {
        let changed = preferredModelID != modelID?.nonEmpty
        preferredModelID = modelID?.nonEmpty
        let health = makeHealth(
            availability: activeTurnID == nil ? .ready : .active,
            summary: currentAccountSnapshot.isLoggedIn ? backend.connectedSummary : backend.signInPromptSummary
        )
        onHealthUpdate?(health)

        // Refresh rate limits for the new model (Spark has different limits)
        if backend == .codex, changed, currentAccountSnapshot.isLoggedIn {
            Task { await refreshRateLimits() }
        }
    }

    func setPreferredSubagentModelID(_ modelID: String?) {
        preferredSubagentModelID = modelID?.nonEmpty
    }

    func clearCachedEnvironmentState() {
        currentAccountSnapshot = .signedOut
        currentRateLimits = .empty
        currentModels = []
        currentCodexPath = nil
    }

    func refreshEnvironment(codexPath: String?) async throws -> AssistantEnvironmentDetails {
        currentCodexPath = codexPath?.nonEmpty
        CrashReporter.logInfo("Assistant runtime refresh started backend=\(backend.rawValue) path=\(currentCodexPath ?? "missing")")
        switch backend {
        case .codex:
            try await ensureTransport()
            let health = connectedHealthForCurrentState()
            onHealthUpdate?(health)
            scheduleMetadataRefresh()
            CrashReporter.logInfo("Assistant runtime refresh finished availability=\(health.availability.rawValue) loggedIn=\(currentAccountSnapshot.isLoggedIn) models=\(currentModels.count) deferredMetadata=true")
            return AssistantEnvironmentDetails(health: health, account: currentAccountSnapshot, models: currentModels)
        case .copilot:
            return try await refreshCopilotEnvironment(cwd: activeSessionCWD)
        }
    }

    func startLogin() async throws -> AssistantRuntimeLoginAction {
        switch backend {
        case .codex:
            try await ensureTransport()

            if currentAccountSnapshot.isLoggedIn {
                _ = try? await refreshModels()
                loginRefreshTask?.cancel()
                onStatusMessage?(backend.alreadySignedInMessage)
                onHealthUpdate?(makeHealth(availability: .ready, summary: backend.connectedSummary))
                CrashReporter.logInfo("Assistant login skipped because Codex account is already signed in")
                return .none
            }

            let response = try await sendRequest(
                method: "account/login/start",
                params: ["type": "chatgpt"]
            )

            guard let payload = response.raw as? [String: Any] else {
                throw CodexAssistantRuntimeError.invalidResponse("Codex did not return a login response.")
            }

            let loginType = payload["type"] as? String
            let loginID = payload["loginId"] as? String
            let authURL = (payload["authUrl"] as? String).flatMap(URL.init(string:))

            currentAccountSnapshot.loginInProgress = loginType == "chatgpt"
            currentAccountSnapshot.pendingLoginID = loginID
            currentAccountSnapshot.pendingLoginURL = authURL
            onAccountUpdate?(currentAccountSnapshot)
            onStatusMessage?("Finish the ChatGPT sign-in in your browser, then come back to Open Assist.")
            onHealthUpdate?(makeHealth(availability: .loginRequired, summary: "Waiting for ChatGPT sign-in"))
            CrashReporter.logInfo("Assistant login started loginID=\(loginID ?? "missing") authURLPresent=\(authURL != nil)")
            scheduleLoginRefreshFallback()
            return authURL.map(AssistantRuntimeLoginAction.openURL) ?? .none
        case .copilot:
            guard await resolvedExecutablePath() != nil else {
                throw CodexAssistantRuntimeError.runtimeUnavailable("GitHub Copilot CLI is not installed on this Mac.")
            }
            onStatusMessage?("Run `copilot login` in Terminal, then return to Open Assist.")
            onHealthUpdate?(makeHealth(availability: .loginRequired, summary: backend.loginRequiredSummary))
            return .runCommand(backend.loginCommands.first ?? "copilot login")
        }
    }

    func logout() async throws {
        guard backend == .codex else {
            currentAccountSnapshot = .signedOut
            currentRateLimits = .empty
            currentModels = []
            onAccountUpdate?(currentAccountSnapshot)
            onRateLimitsUpdate?(currentRateLimits)
            onModelsUpdate?(currentModels)
            onHealthUpdate?(makeHealth(availability: .loginRequired, summary: backend.signedOutSummary))
            return
        }
        try await ensureTransport()
        _ = try await sendRequest(method: "account/logout", params: [:])
        loginRefreshTask?.cancel()
        loginRefreshTask = nil
        currentAccountSnapshot = .signedOut
        currentRateLimits = .empty
        onAccountUpdate?(currentAccountSnapshot)
        onRateLimitsUpdate?(currentRateLimits)
        onHealthUpdate?(makeHealth(availability: .loginRequired, summary: "Signed out of Codex"))
    }

    func startNewSession(cwd: String? = nil, preferredModelID: String? = nil) async throws -> String {
        if backend == .copilot {
            return try await startCopilotSession(
                cwd: cwd,
                preferredModelID: preferredModelID ?? self.preferredModelID,
                announce: true
            )
        }
        try await ensureTransport()
        toolCalls.removeAll()
        liveActivities.removeAll()
        clearSubagents(publish: false)
        repeatedCommandTracker.reset()
        resetStreamingTimelineState()
        onToolCallUpdate?([])
        onPlanUpdate?([])
        onSubagentUpdate?([])
        onTimelineMutation?(.reset(sessionID: nil))
        onPermissionRequest?(nil)
        sessionTurnCount = 0
        firstTurnUserPrompt = nil

        let requestedModelID = preferredModelID ?? self.preferredModelID
        CrashReporter.logInfo("Assistant runtime requesting thread/start model=\(requestedModelID ?? "server-default") cwd=\((cwd ?? FileManager.default.homeDirectoryForCurrentUser.path))")

        let response = try await sendRequest(
            method: "thread/start",
            params: await threadStartParams(cwd: cwd, modelID: requestedModelID)
        )

        guard let payload = response.raw as? [String: Any],
              let thread = payload["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw CodexAssistantRuntimeError.invalidResponse("Codex did not return a thread id.")
        }

        activeSessionID = threadID
        activeSessionCWD = cwd?.nonEmpty
        onSessionChange?(threadID)
        onTranscript?(AssistantTranscriptEntry(role: .system, text: backend.startedSessionMessage, emphasis: true))
        onHealthUpdate?(makeHealth(availability: .active, summary: "Connected"))
        updateHUD(phase: .idle, title: "Assistant is ready", detail: nil)
        CrashReporter.logInfo("Assistant runtime thread/start finished threadID=\(threadID)")
        return threadID
    }

    func resumeSession(_ sessionID: String, cwd: String?, preferredModelID: String? = nil) async throws {
        if backend == .copilot {
            try await resumeCopilotSession(
                sessionID,
                cwd: cwd,
                preferredModelID: preferredModelID ?? self.preferredModelID,
                announce: true
            )
            return
        }
        try await ensureTransport()
        _ = try await sendRequest(
            method: "thread/resume",
            params: await threadResumeParams(
                threadID: sessionID,
                cwd: cwd,
                modelID: preferredModelID ?? self.preferredModelID
            )
        )

        activeSessionID = sessionID
        activeSessionCWD = cwd?.nonEmpty
        sessionTurnCount = 1 // Skip title generation for resumed sessions
        onSessionChange?(sessionID)
        onTranscript?(AssistantTranscriptEntry(role: .system, text: backend.loadedSessionMessage(sessionID), emphasis: true))
        onHealthUpdate?(makeHealth(availability: .active, summary: "Connected"))
        updateHUD(phase: .idle, title: "Thread ready", detail: nil)
    }

    func resumeSessionSilently(
        _ sessionID: String,
        cwd: String?,
        preferredModelID: String? = nil
    ) async throws {
        if backend == .copilot {
            try await resumeCopilotSession(
                sessionID,
                cwd: cwd,
                preferredModelID: preferredModelID ?? self.preferredModelID,
                announce: false
            )
            return
        }
        try await ensureTransport()
        _ = try await sendRequest(
            method: "thread/resume",
            params: await threadResumeParams(
                threadID: sessionID,
                cwd: cwd,
                modelID: preferredModelID ?? self.preferredModelID
            )
        )

        activeSessionID = sessionID
        activeSessionCWD = cwd?.nonEmpty
        sessionTurnCount = 1
        onSessionChange?(sessionID)
        onHealthUpdate?(makeHealth(
            availability: activeTurnID == nil ? .ready : .active,
            summary: "Connected"
        ))
        updateHUD(phase: .idle, title: "Thread ready", detail: nil)
    }

    func refreshCurrentSessionConfiguration(cwd: String?, preferredModelID: String? = nil) async throws {
        guard let activeSessionID else { return }
        if backend == .copilot {
            try await refreshCopilotCurrentSessionConfiguration(
                sessionID: activeSessionID,
                cwd: cwd,
                preferredModelID: preferredModelID ?? self.preferredModelID
            )
            return
        }
        try await ensureTransport()
        _ = try await sendRequest(
            method: "thread/resume",
            params: await threadResumeParams(
                threadID: activeSessionID,
                cwd: cwd,
                modelID: preferredModelID ?? self.preferredModelID
            )
        )
        activeSessionCWD = cwd?.nonEmpty
        onHealthUpdate?(makeHealth(
            availability: activeTurnID == nil ? .ready : .active,
            summary: "Connected"
        ))
    }

    func sendPrompt(
        _ prompt: String,
        attachments: [AssistantAttachment] = [],
        preferredModelID: String? = nil,
        modelSupportsImageInput: Bool = true,
        resumeContext: String? = nil,
        memoryContext: String? = nil
    ) async throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        // Reset plan buffer for the new turn
        proposedPlanBuffer = ""
        allowsProposedPlanForActiveTurn = interactionMode == .plan
        blockedToolUseHandledForActiveTurn = false
        blockedToolUseInterruptionMessage = nil
        currentTurnIncludesImageAttachments = attachments.contains(where: \.isImage)
        currentTurnModelSupportsImageInput = modelSupportsImageInput
        redirectedImageToolCallForActiveTurn = false

        // Track the first user prompt for title generation
        if sessionTurnCount == 0 {
            firstTurnUserPrompt = trimmed
        }

        if activeSessionID == nil {
            _ = try await startNewSession(preferredModelID: preferredModelID ?? self.preferredModelID)
        }

        guard let activeSessionID else {
            throw CodexAssistantRuntimeError.sessionUnavailable
        }

        if backend == .copilot {
            try await sendCopilotPrompt(
                sessionID: activeSessionID,
                prompt: trimmed,
                attachments: attachments,
                preferredModelID: preferredModelID ?? self.preferredModelID,
                resumeContext: resumeContext,
                memoryContext: memoryContext
            )
            return
        }

        turnToolCallCount = 0
        repeatedCommandTracker.reset()
        updateHUD(phase: .streaming, title: "Starting", detail: nil)
        let requestedModelID = preferredModelID ?? self.preferredModelID
        CrashReporter.logInfo("Assistant runtime requesting turn/start threadID=\(activeSessionID) model=\(requestedModelID ?? "server-default") promptChars=\(trimmed.count) attachments=\(attachments.count)")

        let response = try await sendRequest(
            method: "turn/start",
            params: turnStartParams(
                threadID: activeSessionID,
                prompt: trimmed,
                attachments: attachments,
                modelID: requestedModelID,
                resumeContext: resumeContext,
                memoryContext: memoryContext
            )
        )

        if let payload = response.raw as? [String: Any],
           let turn = payload["turn"] as? [String: Any],
           let turnID = turn["id"] as? String {
            activeTurnID = turnID
            CrashReporter.logInfo("Assistant runtime turn/start finished turnID=\(turnID)")
        } else {
            CrashReporter.logWarning("Assistant runtime turn/start finished without a turn id")
        }
    }

    func cancelActiveTurn() async {
        await pendingPermissionContext?.cancel()
        pendingPermissionContext = nil
        onPermissionRequest?(nil)

        guard let activeSessionID else {
            updateHUD(phase: .idle, title: "Cancelled", detail: nil)
            return
        }

        if backend == .copilot {
            let hadActiveTurn = activeTurnID != nil
            do {
                _ = try await sendRequest(
                    method: "session/cancel",
                    params: ["sessionId": activeSessionID]
                )
            } catch {
                onStatusMessage?(error.localizedDescription)
            }
            self.activeTurnID = nil
            allowsProposedPlanForActiveTurn = false
            updateHUD(phase: .idle, title: "Cancelled", detail: nil)
            if hadActiveTurn {
                onTurnCompletion?(.interrupted)
            }
            onHealthUpdate?(makeHealth(availability: .ready, summary: backend.connectedSummary))
            return
        }

        guard let activeTurnID else {
            updateHUD(phase: .idle, title: "Cancelled", detail: nil)
            return
        }

        do {
            _ = try await sendRequest(
                method: "turn/interrupt",
                params: [
                    "threadId": activeSessionID,
                    "turnId": activeTurnID
                ]
            )
        } catch {
            onStatusMessage?(error.localizedDescription)
        }

        self.activeTurnID = nil
        allowsProposedPlanForActiveTurn = false
        updateHUD(phase: .idle, title: "Cancelled", detail: nil)
        onTurnCompletion?(.interrupted)
    }

    func respondToPermissionRequest(optionID: String) async {
        guard let pendingPermissionContext else { return }
        await pendingPermissionContext.select(optionID: optionID)
        self.pendingPermissionContext = nil
        onPermissionRequest?(nil)
        updateHUD(phase: .acting, title: "Continuing", detail: pendingPermissionContext.request.toolTitle)
    }

    func respondToPermissionRequest(answers: [String: [String]]) async {
        guard let pendingPermissionContext else { return }
        await pendingPermissionContext.submit(answers: answers)
        self.pendingPermissionContext = nil
        onPermissionRequest?(nil)
        updateHUD(phase: .acting, title: "Continuing", detail: pendingPermissionContext.request.toolTitle)
    }

    func cancelPendingPermissionRequest() async {
        guard let pendingPermissionContext else { return }
        await pendingPermissionContext.cancel()
        self.pendingPermissionContext = nil
        onPermissionRequest?(nil)
        updateHUD(phase: .idle, title: "Request cancelled", detail: nil)
    }

    /// Detach from the current thread without stopping the transport.
    /// This is available for cases where the UI intentionally wants the next prompt
    /// to start a fresh thread instead of continuing the current one.
    func detachSession() {
        if activeTurnID != nil {
            onTurnCompletion?(.interrupted)
        }
        if let oldSessionID = activeSessionID {
            detachedSessionIDs.insert(oldSessionID)
        }
        activeTurnID = nil
        activeSessionID = nil
        activeSessionCWD = nil
        transportSessionID = nil
        toolCalls.removeAll()
        liveActivities.removeAll()
        clearSubagents(publish: false)
        repeatedCommandTracker.reset()
        resetStreamingTimelineState()
        onToolCallUpdate?([])
        onPlanUpdate?([])
        onSubagentUpdate?([])
        onTimelineMutation?(.reset(sessionID: nil))
    }

    func listSessions(limit: Int = 40) async throws -> [AssistantSessionSummary] {
        switch backend {
        case .codex:
            return []
        case .copilot:
            return try await listCopilotSessions(limit: limit)
        }
    }

    func stop() async {
        loginRefreshTask?.cancel()
        loginRefreshTask = nil
        metadataRefreshTask?.cancel()
        metadataRefreshTask = nil
        transportStartupTask?.cancel()
        transportStartupTask = nil
        await pendingPermissionContext?.cancel()
        pendingPermissionContext = nil
        if activeTurnID != nil {
            onTurnCompletion?(.interrupted)
        }
        activeTurnID = nil
        activeSessionID = nil
        activeSessionCWD = nil
        transportSessionID = nil
        currentTransportWorkingDirectory = nil
        bootstrapSessionID = nil
        toolCalls.removeAll()
        liveActivities.removeAll()
        clearSubagents(publish: false)
        repeatedCommandTracker.reset()
        resetStreamingTimelineState()
        onToolCallUpdate?([])
        onPlanUpdate?([])
        onSubagentUpdate?([])
        onTimelineMutation?(.reset(sessionID: nil))
        onSessionChange?(nil)
        await transport?.stop()
        transport = nil
        onHealthUpdate?(makeHealth(availability: .idle, summary: "Assistant is idle"))
        updateHUD(phase: .idle, title: "Assistant is ready", detail: nil)

        // Clean up lingering AppleScript processes
        Self.cleanupAppleScriptProcesses()
    }

    static func inspectCopilotSessions(
        executablePath: String,
        limit: Int,
        workingDirectory: String? = nil
    ) async throws -> [AssistantSessionSummary] {
        let transport = CodexAppServerTransport { _ in }
        try await transport.startCopilot(
            copilotExecutablePath: executablePath,
            workingDirectory: workingDirectory
        )

        do {
            let response = try await transport.sendRequest(method: "session/list", params: [:])
            let sessions = parseCopilotSessions(
                from: response.raw,
                limit: limit,
                excluding: nil
            )
            await transport.stop()
            return sessions
        } catch {
            await transport.stop()
            throw error
        }
    }

    private func ensureTransport(cwd: String? = nil) async throws {
        let desiredWorkingDirectory = backend == .copilot
            ? resolvedCopilotWorkingDirectory(cwd ?? activeSessionCWD)
            : nil

        if let transport {
            if backend == .copilot,
               currentTransportWorkingDirectory != desiredWorkingDirectory {
                await transport.stop()
                self.transport = nil
                self.transportSessionID = nil
                self.currentTransportWorkingDirectory = nil
            } else if await transport.isRunning() {
                return
            }
            self.transport = nil
            self.transportSessionID = nil
            self.currentTransportWorkingDirectory = nil
        }

        if let transportStartupTask {
            return try await transportStartupTask.value
        }

        guard let codexPath = await resolvedExecutablePath() else {
            switch backend {
            case .codex:
                throw CodexAssistantRuntimeError.codexMissing
            case .copilot:
                throw CodexAssistantRuntimeError.runtimeUnavailable("GitHub Copilot CLI is not installed on this Mac.")
            }
        }

        onHealthUpdate?(makeHealth(availability: .connecting, summary: backend.startupSummary))
        CrashReporter.logInfo("Assistant runtime connecting backend=\(backend.rawValue) path=\(codexPath)")
        let startupTask = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { return }

            let transport = CodexAppServerTransport { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.handleIncomingEvent(event)
                }
            }

            do {
                switch self.backend {
                case .codex:
                    try await transport.startCodex(codexExecutablePath: codexPath)
                case .copilot:
                    try await transport.startCopilot(
                        copilotExecutablePath: codexPath,
                        workingDirectory: desiredWorkingDirectory
                    )
                }
                self.transport = transport
                self.transportSessionID = nil
                self.currentTransportWorkingDirectory = desiredWorkingDirectory
                self.onStatusMessage?("Connected to \(self.backend.displayName)")
                CrashReporter.logInfo("Assistant runtime connected backend=\(self.backend.rawValue)")
            } catch {
                self.onHealthUpdate?(self.makeHealth(
                    availability: .failed,
                    summary: self.backend.startupFailureSummary,
                    detail: error.localizedDescription
                ))
                CrashReporter.logError("Assistant runtime failed to start backend=\(self.backend.rawValue): \(error.localizedDescription)")
                throw error
            }
        }

        transportStartupTask = startupTask

        do {
            try await startupTask.value
            transportStartupTask = nil
        } catch {
            transportStartupTask = nil
            throw error
        }
    }

    private func refreshAccountState() async throws -> AssistantAccountSnapshot {
        CrashReporter.logInfo("Assistant runtime requesting account/read")
        let response = try await requestWithTimeout(method: "account/read", params: ["refreshToken": false])
        let account = parseAccountSnapshot(from: response.raw)
        currentAccountSnapshot = account
        onAccountUpdate?(account)
        CrashReporter.logInfo("Assistant runtime account/read finished loggedIn=\(account.isLoggedIn) authMode=\(account.authMode.rawValue)")
        return account
    }

    func resolveTranscriptionAuthContext(refreshToken: Bool = true) async throws -> CodexTranscriptionAuthContext {
        guard backend == .codex else {
            throw CodexAssistantRuntimeError.runtimeUnavailable(
                "Transcription auth context is only available when Codex is the selected assistant backend."
            )
        }
        try await ensureTransport()

        let params: [String: Any] = [
            "includeToken": true,
            "refreshToken": refreshToken
        ]

        var lastError: Error?
        for method in ["getAuthStatus", "account/getAuthStatus"] {
            do {
                CrashReporter.logInfo("Assistant runtime requesting \(method) for transcription")
                let response = try await requestWithTimeout(
                    method: method,
                    params: params,
                    timeoutNanoseconds: 12_000_000_000
                )
                let context = try parseTranscriptionAuthContext(from: response.raw)
                CrashReporter.logInfo(
                    "Assistant runtime resolved transcription auth method=\(context.authMode.rawValue)"
                )
                return context
            } catch {
                lastError = error
                CrashReporter.logInfo("\(method) unavailable for transcription auth: \(error.localizedDescription)")
            }
        }

        throw lastError ?? CodexAssistantRuntimeError.invalidResponse(
            "Codex did not provide a transcription auth status response."
        )
    }

    func refreshRateLimits() async {
        switch backend {
        case .codex:
            do {
                let response = try await requestWithTimeout(method: "account/rateLimits/read", params: [:])
                guard let payload = response.raw as? [String: Any] else { return }
                handleRateLimitsUpdated(payload)
            } catch {
                CrashReporter.logInfo("account/rateLimits/read not available: \(error.localizedDescription)")
            }
        case .copilot:
            let tokenResolver = CopilotTokenResolver(
                runner: installSupport.runner,
                fileManager: installSupport.fileManager,
                homeDirectory: installSupport.homeDirectory
            )

            guard let token = await tokenResolver.resolveGitHubToken() else {
                CrashReporter.logInfo("Copilot usage refresh skipped because no GitHub auth token could be resolved.")
                return
            }

            do {
                let snapshot = try await CopilotUsageFetcher().fetchUsage(token: token)
                currentRateLimits = snapshot.rateLimits
                onRateLimitsUpdate?(currentRateLimits)

                if currentAccountSnapshot.planType != snapshot.planType {
                    currentAccountSnapshot.planType = snapshot.planType
                    onAccountUpdate?(currentAccountSnapshot)
                }
            } catch {
                CrashReporter.logInfo("Copilot usage refresh failed: \(error.localizedDescription)")
            }
        }
    }

    private func refreshModels() async throws -> [AssistantModelOption] {
        if backend == .copilot {
            let resolvedCWD = resolvedCopilotWorkingDirectory(activeSessionCWD)
            if let activeSessionID {
                try await refreshCopilotCurrentSessionConfiguration(
                    sessionID: activeSessionID,
                    cwd: activeSessionCWD ?? resolvedCWD,
                    preferredModelID: preferredModelID
                )
                return currentModels
            }

            _ = try await startCopilotSession(
                cwd: resolvedCWD,
                preferredModelID: preferredModelID,
                announce: false
            )
            return currentModels
        }

        CrashReporter.logInfo("Assistant runtime requesting model/list")
        let response = try await requestWithTimeout(method: "model/list", params: [:])
        let models = parseModels(from: response.raw)
        currentModels = models
        onModelsUpdate?(models)
        CrashReporter.logInfo("Assistant runtime model/list finished count=\(models.count)")
        return models
    }

    private func requestWithTimeout(
        method: String,
        params: [String: Any],
        timeoutNanoseconds: UInt64 = 8_000_000_000
    ) async throws -> CodexResponsePayload {
        let requestTask = Task { try await sendRequest(method: method, params: params) }
        let backendDisplayName = backend.displayName

        do {
            return try await withThrowingTaskGroup(of: CodexResponsePayload.self) { group in
                group.addTask {
                    try await requestTask.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    throw CodexAssistantRuntimeError.runtimeUnavailable("\(backendDisplayName) did not answer \(method) in time.")
                }

                let result = try await group.next()
                group.cancelAll()
                return result ?? CodexResponsePayload(raw: [:])
            }
        } catch {
            CrashReporter.logError("Assistant runtime request failed method=\(method) message=\(error.localizedDescription)")
            if case CodexAssistantRuntimeError.runtimeUnavailable = error {
                await transport?.stop()
                transport = nil
                transportStartupTask = nil
                transportSessionID = nil
                currentTransportWorkingDirectory = nil
            }
            throw error
        }
    }

    private func connectedHealthForCurrentState(detail: String? = nil) -> AssistantRuntimeHealth {
        if activeTurnID != nil {
            return makeHealth(availability: .active, summary: backend.activeSummary, detail: detail)
        }

        if currentAccountSnapshot.isLoggedIn {
            let resolvedDetail = detail ?? (currentModels.isEmpty ? "Loading model details…" : nil)
            return makeHealth(availability: .ready, summary: backend.connectedSummary, detail: resolvedDetail)
        }

        let resolvedDetail = detail ?? "Account details are still loading. You can already start chatting."
        return makeHealth(availability: .ready, summary: backend.connectedSummary, detail: resolvedDetail)
    }

    private func resolvedExecutablePath() async -> String? {
        if let existingPath = currentCodexPath?.nonEmpty {
            return existingPath
        }

        let guidance = await installSupport.inspect(backend: backend)
        let resolvedPath = guidance.codexPath?.nonEmpty
        currentCodexPath = resolvedPath
        return resolvedPath
    }

    private func scheduleMetadataRefresh() {
        metadataRefreshTask?.cancel()
        metadataRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var accountError: Error?
            var modelsError: Error?
            var refreshedAccount: AssistantAccountSnapshot?
            var refreshedModels: [AssistantModelOption]?

            do {
                refreshedAccount = try await self.refreshAccountState()
            } catch {
                accountError = error
            }

            do {
                refreshedModels = try await self.refreshModels()
            } catch {
                modelsError = error
            }

            if refreshedAccount?.isLoggedIn == true {
                await self.refreshRateLimits()
            }

            if let refreshedAccount {
                let transportRunning = await self.transport?.isRunning() ?? false
                if modelsError != nil, !transportRunning {
                    let detail = modelsError?.localizedDescription ?? "Codex App Server stopped."
                    self.onHealthUpdate?(self.makeHealth(
                        availability: .idle,
                        summary: "Codex App Server stopped",
                        detail: detail
                    ))
                    CrashReporter.logWarning("Assistant runtime metadata refresh detected stopped transport message=\(detail)")
                    self.metadataRefreshTask = nil
                    return
                }

                let availability: AssistantRuntimeAvailability = refreshedAccount.isLoggedIn
                    ? (self.activeTurnID == nil ? .ready : .active)
                    : .loginRequired
                let summary = refreshedAccount.isLoggedIn ? "Codex is connected" : "Sign in with ChatGPT to use Codex"
                let detail = modelsError?.localizedDescription
                self.onHealthUpdate?(self.makeHealth(availability: availability, summary: summary, detail: detail))
                CrashReporter.logInfo("Assistant runtime metadata refresh finished loggedIn=\(refreshedAccount.isLoggedIn) models=\(refreshedModels?.count ?? self.currentModels.count)")
            } else {
                let detail = accountError?.localizedDescription ?? modelsError?.localizedDescription ?? "Account details are still loading."
                self.onStatusMessage?(detail)
                self.onHealthUpdate?(self.connectedHealthForCurrentState(detail: "Chat is ready, but account details could not be loaded yet."))
                CrashReporter.logWarning("Assistant runtime metadata refresh fell back to transport-only readiness message=\(detail)")
            }

            self.metadataRefreshTask = nil
        }
    }

    private func sendRequest(method: String, params: [String: Any]) async throws -> CodexResponsePayload {
        guard let transport else {
            throw CodexAssistantRuntimeError.runtimeUnavailable("\(backend.displayName) is not running yet.")
        }
        return try await transport.sendRequest(method: method, params: params)
    }

    private func handleIncomingEvent(_ event: CodexIncomingEvent) async {
        switch event {
        case .statusMessage(let message):
            CrashReporter.logInfo("Assistant runtime status: \(message)")
            onStatusMessage?(message)
        case .processExited(let message):
            flushStreamingBuffer()
            flushCommentaryBuffer()
            finalizeActiveActivities(with: .interrupted)
            if activeTurnID != nil {
                onTurnCompletion?(.interrupted)
            }
            activeTurnID = nil
            activeSessionID = nil
            activeSessionCWD = nil
            transportSessionID = nil
            currentTransportWorkingDirectory = nil
            bootstrapSessionID = nil
            clearSubagents()
            transport = nil
            transportStartupTask = nil
            CrashReporter.logWarning("Assistant runtime process exited message=\(message ?? "none")")
            onHealthUpdate?(makeHealth(availability: .idle, summary: "\(backend.displayName) stopped", detail: message))
            if let message {
                onTranscript?(AssistantTranscriptEntry(role: .status, text: message))
            }
        case .notification(let method, let params):
            await handleNotification(method: method, params: params)
        case .serverRequest(let id, let method, let params):
            await handleServerRequest(id: id, method: method, params: params)
        }
    }

    private func handleNotification(method: String, params: [String: Any]) async {
        if backend == .copilot {
            await handleCopilotNotification(method: method, params: params)
            return
        }

        // Intercept notifications from the title-generation thread
        if let titleThread = titleGenThreadID,
           let notifThread = params["threadId"] as? String,
           notifThread == titleThread {
            self.handleTitleGenNotification(method: method, params: params)
            return
        }

        // Drop stale notifications from a detached or mismatched thread.
        // This prevents events from a previous session from leaking into the
        // current session's timeline (e.g. after plan execution switches threads).
        if let notifThread = params["threadId"] as? String {
            if detachedSessionIDs.contains(notifThread) {
                return
            }
            if let currentActive = activeSessionID, notifThread != currentActive {
                return
            }
        }

        switch method {
        case "account/updated":
            CrashReporter.logInfo("Assistant runtime notification account/updated")
            do {
                let account = try await refreshAccountState()
                onHealthUpdate?(makeHealth(
                    availability: account.isLoggedIn ? .ready : .loginRequired,
                    summary: account.isLoggedIn ? "Codex is connected" : "Sign in with ChatGPT to use Codex"
                ))
            } catch {
                onStatusMessage?(error.localizedDescription)
                onHealthUpdate?(makeHealth(
                    availability: .failed,
                    summary: "Codex account check failed",
                    detail: error.localizedDescription
                ))
            }
        case "account/login/completed":
            CrashReporter.logInfo("Assistant runtime notification account/login/completed success=\(params["success"] as? Bool ?? false)")
            let success = params["success"] as? Bool ?? false
            loginRefreshTask?.cancel()
            loginRefreshTask = nil
            currentAccountSnapshot.loginInProgress = false
            currentAccountSnapshot.pendingLoginID = nil
            currentAccountSnapshot.pendingLoginURL = nil
            onAccountUpdate?(currentAccountSnapshot)
            if success {
                do {
                    _ = try await refreshAccountState()
                    _ = try await refreshModels()
                    onTranscript?(AssistantTranscriptEntry(role: .system, text: "ChatGPT sign-in completed.", emphasis: true))
                    onHealthUpdate?(makeHealth(availability: .ready, summary: "Codex is connected"))
                } catch {
                    onStatusMessage?(error.localizedDescription)
                }
            } else {
                let errorText = firstNonEmptyString(params["error"] as? String, "ChatGPT sign-in did not finish.")
                onTranscript?(AssistantTranscriptEntry(role: .error, text: errorText ?? "ChatGPT sign-in did not finish.", emphasis: true))
                onHealthUpdate?(makeHealth(availability: .loginRequired, summary: "Sign in to Codex", detail: errorText))
            }
        case "thread/started":
            CrashReporter.logInfo("Assistant runtime notification thread/started")
            if let threadID = params["threadId"] as? String {
                // Only fire onSessionChange if we haven't already set this session
                // (startNewSession sets it from the response before this notification arrives).
                let alreadyCurrent = activeSessionID == threadID
                activeSessionID = threadID
                if !alreadyCurrent {
                    onSessionChange?(threadID)
                }
            }
        case "thread/status/changed":
            handleThreadStatusChanged(params)
        case "turn/started":
            CrashReporter.logInfo("Assistant runtime notification turn/started")
            if let turn = params["turn"] as? [String: Any],
               let turnID = turn["id"] as? String {
                activeTurnID = turnID
            }
            clearSubagents()
            onPlanUpdate?([])
            resetStreamingTimelineState()
            updateHUD(phase: .thinking, title: "Thinking", detail: nil)
            onHealthUpdate?(makeHealth(availability: .active, summary: "Codex is working"))
        case "turn/plan/updated":
            onPlanUpdate?(parsePlanEntries(from: params["plan"]))
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String, delta.nonEmpty != nil {
                let threadID = params["threadId"] as? String
                let turnID = assistantMessageTurnID(from: params)
                guard acceptAssistantMessageDelta(
                    threadID: threadID,
                    turnID: turnID,
                    source: method
                ) else {
                    break
                }
                let channel = (params["channel"] as? String)?.lowercased()
                if channel == "commentary" {
                    appendCommentaryDelta(delta)
                } else {
                    ensureStreamingIdentifiers()
                    streamingBuffer += delta
                    pendingStreamingDeltaBuffer += delta
                    emitStreamingAssistantDelta(force: shouldForceStreamingDeltaFlush(for: delta))
                    updateHUD(phase: .streaming, title: "Responding", detail: nil)
                }
            }
        case "item/plan/delta":
            if allowsProposedPlanForActiveTurn,
               let delta = params["delta"] as? String,
               delta.nonEmpty != nil {
                proposedPlanBuffer += delta
                onProposedPlan?(proposedPlanBuffer)
                emitPlanTimeline(text: proposedPlanBuffer, isStreaming: true)
                updateHUD(phase: .streaming, title: "Planning", detail: nil)
            }
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            if let delta = params["delta"] as? String, delta.nonEmpty != nil {
                onTranscript?(AssistantTranscriptEntry(role: .status, text: delta))
                appendCommentaryDelta(delta)
                updateHUD(phase: .thinking, title: "Reasoning", detail: nil)
            }
        case "item/started":
            handleItemStartedOrCompleted(params, isCompleted: false)
        case "item/completed":
            handleItemStartedOrCompleted(params, isCompleted: true)
        case "item/commandExecution/outputDelta":
            handleCommandOutputDelta(params)
        case "turn/completed":
            CrashReporter.logInfo("Assistant runtime notification turn/completed")
            handleTurnCompleted(params)
        case "error":
            let message = firstNonEmptyString(
                params["message"] as? String,
                extractString(params["error"]),
                "Codex reported an error."
            ) ?? "Codex reported an error."
            if let reconnectStatus = transientReconnectStatusMessage(from: message) {
                onStatusMessage?(reconnectStatus)
                onHealthUpdate?(connectedHealthForCurrentState(detail: reconnectStatus))
                updateHUD(
                    phase: activeTurnID != nil ? .streaming : .thinking,
                    title: "Reconnecting",
                    detail: reconnectStatus
                )
                CrashReporter.logWarning("Assistant runtime reconnect notice: \(reconnectStatus)")
                break
            }
            flushStreamingBuffer()
            flushCommentaryBuffer()
            onTranscript?(AssistantTranscriptEntry(role: .error, text: message, emphasis: true))
            emitTimelineSystemMessage(message, emphasis: true)
            // Keep availability as .ready so the user can retry — the transport
            // connection is still alive; only the individual operation failed.
            onHealthUpdate?(makeHealth(availability: .ready, summary: "Codex is connected", detail: message))
            updateHUD(phase: .failed, title: "Needs attention", detail: message)
            CrashReporter.logError("Assistant runtime error notification: \(message)")
        case "model/rerouted", "configWarning", "deprecationNotice":
            if let message = firstNonEmptyString(
                params["message"] as? String,
                params["warning"] as? String,
                params["title"] as? String
            ) {
                onStatusMessage?(message)
            }
        case "thread/tokenUsage/updated":
            handleTokenUsageUpdated(params)
        case "context/compacted":
            CrashReporter.logInfo("Context compaction completed")
        case "account/rateLimits/updated":
            handleRateLimitsUpdated(params)
        case "item/collabAgentSpawn/begin":
            handleCollabSpawnBegin(params)
        case "item/collabAgentSpawn/end":
            handleCollabSpawnEnd(params)
        case "item/collabAgentInteraction/begin":
            handleCollabInteractionBegin(params)
        case "item/collabAgentInteraction/end":
            handleCollabInteractionEnd(params)
        case "item/collabClose/begin":
            handleCollabClose(params)
        case "item/collabClose/end":
            handleCollabClose(params)
        case "item/collabWaiting/begin":
            handleCollabWaitingBegin(params)
        case "item/collabWaiting/end":
            handleCollabWaitingEnd(params)
        default:
            break
        }
    }

    private func handleTokenUsageUpdated(_ params: [String: Any]) {
        guard let tokenUsage = params["tokenUsage"] as? [String: Any] else { return }

        let lastDict = tokenUsage["last"] as? [String: Any] ?? [:]
        let totalDict = tokenUsage["total"] as? [String: Any] ?? [:]
        let contextWindow = tokenUsage["modelContextWindow"] as? Int

        let snapshot = TokenUsageSnapshot(
            last: TokenUsageBreakdown(from: lastDict) ?? .zero,
            total: TokenUsageBreakdown(from: totalDict) ?? .zero,
            modelContextWindow: contextWindow
        )
        onTokenUsageUpdate?(snapshot)
    }

    // MARK: - Subagent / Collaboration Handlers

    private func collabAgentMetadata(from item: [String: Any]) -> (threadID: String?, nickname: String?, role: String?) {
        let collabAgent = item["collabAgent"] as? [String: Any]
        let arguments = item["arguments"] as? [String: Any]
        let result = item["result"] as? [String: Any]

        let threadID = firstNonEmptyString(
            collabAgent?["thread_id"] as? String,
            collabAgent?["threadId"] as? String,
            item["thread_id"] as? String,
            item["threadId"] as? String,
            item["new_thread_id"] as? String,
            item["newThreadId"] as? String,
            arguments?["thread_id"] as? String,
            arguments?["threadId"] as? String,
            result?["thread_id"] as? String,
            result?["threadId"] as? String,
            result?["new_thread_id"] as? String,
            result?["newThreadId"] as? String
        )
        let nickname = firstNonEmptyString(
            collabAgent?["agent_nickname"] as? String,
            collabAgent?["agentNickname"] as? String,
            item["agent_nickname"] as? String,
            item["agentNickname"] as? String,
            item["new_agent_nickname"] as? String,
            item["newAgentNickname"] as? String,
            arguments?["agent_nickname"] as? String,
            arguments?["agentNickname"] as? String,
            result?["agent_nickname"] as? String,
            result?["agentNickname"] as? String,
            result?["new_agent_nickname"] as? String,
            result?["newAgentNickname"] as? String
        )
        let role = firstNonEmptyString(
            collabAgent?["agent_role"] as? String,
            collabAgent?["agentRole"] as? String,
            item["agent_role"] as? String,
            item["agentRole"] as? String,
            item["new_agent_role"] as? String,
            item["newAgentRole"] as? String,
            arguments?["agent_role"] as? String,
            arguments?["agentRole"] as? String,
            result?["agent_role"] as? String,
            result?["agentRole"] as? String,
            result?["new_agent_role"] as? String,
            result?["newAgentRole"] as? String
        )

        return (threadID, nickname, role)
    }

    private func handleCollabToolCall(item: [String: Any], status: String) {
        guard let callID = item["id"] as? String else { return }
        let tool = item["tool"] as? String ?? ""
        let metadata = collabAgentMetadata(from: item)
        let threadID = metadata.threadID
        let nickname = metadata.nickname
        let role = metadata.role
        let now = Date()

        switch tool {
        case "SpawnAgent":
            var subagent = activeSubagents[callID] ?? SubagentState(
                id: callID,
                parentThreadID: activeSessionID,
                threadID: threadID,
                nickname: nickname,
                role: role,
                status: .spawning,
                prompt: extractString(item["arguments"]),
                startedAt: now,
                updatedAt: now,
                endedAt: nil
            )
            if subagent.parentThreadID?.nonEmpty == nil {
                subagent.parentThreadID = activeSessionID
            }
            subagent.threadID = threadID ?? subagent.threadID
            subagent.nickname = nickname ?? subagent.nickname
            subagent.role = role ?? subagent.role
            subagent.prompt = extractString(item["arguments"]) ?? subagent.prompt
            subagent.updatedAt = now
            activeSubagents[callID] = subagent
        case "CloseAgent":
            if let threadID {
                for (key, var agent) in activeSubagents where agent.threadID == threadID {
                    applySubagentStatus(.closed, to: &agent, at: now)
                    activeSubagents[key] = agent
                }
            }
        default:
            break
        }

        if status == "completed" || status == "failed" {
            if var existing = activeSubagents[callID] {
                if status == "failed" {
                    applySubagentStatus(.errored, to: &existing, at: now)
                } else if tool == "CloseAgent" {
                    applySubagentStatus(.closed, to: &existing, at: now)
                } else {
                    existing.updatedAt = now
                }
                activeSubagents[callID] = existing
            }
        }

        publishSubagents()
    }

    private func handleCollabSpawnBegin(_ params: [String: Any]) {
        let callID = params["call_id"] as? String ?? params["callId"] as? String ?? UUID().uuidString
        let prompt = params["prompt"] as? String
        let now = Date()
        activeSubagents[callID] = SubagentState(
            id: callID,
            parentThreadID: activeSessionID,
            threadID: nil,
            nickname: nil,
            role: nil,
            status: .spawning,
            prompt: prompt,
            startedAt: now,
            updatedAt: now,
            endedAt: nil
        )
        publishSubagents()
        updateHUD(phase: .acting, title: "Spawning agent", detail: prompt)
    }

    private func handleCollabSpawnEnd(_ params: [String: Any]) {
        let callID = params["call_id"] as? String ?? params["callId"] as? String ?? ""
        let threadID = params["new_thread_id"] as? String ?? params["newThreadId"] as? String
        let nickname = params["new_agent_nickname"] as? String ?? params["newAgentNickname"] as? String
        let role = params["new_agent_role"] as? String ?? params["newAgentRole"] as? String
        let now = Date()

        if var existing = activeSubagents[callID] {
            existing.threadID = threadID
            existing.nickname = nickname
            existing.role = role
            applySubagentStatus(.running, to: &existing, at: now)
            activeSubagents[callID] = existing
        } else {
            activeSubagents[callID] = SubagentState(
                id: callID,
                parentThreadID: activeSessionID,
                threadID: threadID,
                nickname: nickname,
                role: role,
                status: .running,
                prompt: params["prompt"] as? String,
                startedAt: now,
                updatedAt: now,
                endedAt: nil
            )
        }
        publishSubagents()
    }

    private func handleCollabInteractionBegin(_ params: [String: Any]) {
        let receiverThreadID = params["receiver_thread_id"] as? String ?? params["receiverThreadId"] as? String
        if let receiverThreadID {
            updateSubagentByThread(receiverThreadID, status: .running, timestamp: Date())
        }
    }

    private func handleCollabInteractionEnd(_ params: [String: Any]) {
        let receiverThreadID = params["receiver_thread_id"] as? String ?? params["receiverThreadId"] as? String
        let statusStr = params["status"] as? String
        if let receiverThreadID {
            let status: SubagentStatus = statusStr == "errored" ? .errored : (statusStr == "completed" ? .completed : .running)
            updateSubagentByThread(receiverThreadID, status: status, timestamp: Date())
        }
    }

    private func handleCollabClose(_ params: [String: Any]) {
        let receiverThreadID = params["receiver_thread_id"] as? String ?? params["receiverThreadId"] as? String
        if let receiverThreadID {
            updateSubagentByThread(receiverThreadID, status: .closed, timestamp: Date())
        }
    }

    private func handleCollabWaitingBegin(_ params: [String: Any]) {
        let threadIDs = params["receiver_thread_ids"] as? [String] ?? params["receiverThreadIds"] as? [String] ?? []
        for threadID in threadIDs {
            updateSubagentByThread(threadID, status: .waiting, timestamp: Date())
        }
        updateHUD(phase: .acting, title: "Waiting for agents", detail: "\(threadIDs.count) agent\(threadIDs.count == 1 ? "" : "s")")
    }

    private func handleCollabWaitingEnd(_ params: [String: Any]) {
        let threadIDs = params["receiver_thread_ids"] as? [String] ?? params["receiverThreadIds"] as? [String] ?? []
        let now = Date()
        for threadID in threadIDs {
            for (key, var agent) in activeSubagents where agent.threadID == threadID && agent.status == .waiting {
                applySubagentStatus(.completed, to: &agent, at: now)
                activeSubagents[key] = agent
            }
        }
        publishSubagents()
    }

    private func updateSubagentByThread(_ threadID: String, status: SubagentStatus, timestamp: Date) {
        for (key, var agent) in activeSubagents where agent.threadID == threadID {
            applySubagentStatus(status, to: &agent, at: timestamp)
            activeSubagents[key] = agent
        }
        publishSubagents()
    }

    private func applySubagentStatus(_ status: SubagentStatus, to agent: inout SubagentState, at timestamp: Date) {
        agent.status = status
        agent.updatedAt = timestamp
        if status.isActive {
            agent.endedAt = nil
        } else {
            agent.endedAt = timestamp
        }
    }

    private func clearSubagents(publish: Bool = true) {
        guard !activeSubagents.isEmpty else {
            if publish {
                onSubagentUpdate?([])
            }
            return
        }

        activeSubagents.removeAll()
        if publish {
            onSubagentUpdate?([])
        }
    }

    private func publishSubagents() {
        let sorted = activeSubagents.values.sorted { a, b in
            if a.status.isActive != b.status.isActive { return a.status.isActive }
            let lhsDate = a.lastEventAt ?? .distantPast
            let rhsDate = b.lastEventAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return a.id < b.id
        }
        onSubagentUpdate?(Array(sorted))
    }

    private func handleRateLimitsUpdated(_ params: [String: Any]) {
        guard let limits = AccountRateLimits.fromPayload(params, preserving: currentRateLimits) else { return }
        currentRateLimits = limits
        onRateLimitsUpdate?(limits)
    }

    private func scheduleLoginRefreshFallback() {
        loginRefreshTask?.cancel()
        loginRefreshTask = Task { [weak self] in
            guard let self else { return }

            for _ in 0..<30 {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }

                do {
                    let account = try await self.refreshAccountState()
                    guard account.isLoggedIn else { continue }

                    _ = try? await self.refreshModels()
                    self.currentAccountSnapshot.loginInProgress = false
                    self.currentAccountSnapshot.pendingLoginID = nil
                    self.currentAccountSnapshot.pendingLoginURL = nil
                    self.onAccountUpdate?(self.currentAccountSnapshot)
                    self.onTranscript?(AssistantTranscriptEntry(role: .system, text: "ChatGPT sign-in completed.", emphasis: true))
                    self.onHealthUpdate?(self.makeHealth(availability: .ready, summary: "Codex is connected"))
                    self.onStatusMessage?("Codex sign-in completed.")
                    self.loginRefreshTask = nil
                    return
                } catch {
                    continue
                }
            }

            guard !Task.isCancelled else { return }
            self.currentAccountSnapshot.loginInProgress = false
            self.onAccountUpdate?(self.currentAccountSnapshot)
            self.onHealthUpdate?(self.makeHealth(
                availability: .loginRequired,
                summary: "Sign in with ChatGPT to use Codex",
                detail: "The sign-in window did not finish yet. You can try again or press Refresh in Setup."
            ))
            self.loginRefreshTask = nil
        }
    }

    private func handleServerRequest(id: JSONRPCRequestID, method: String, params: [String: Any]) async {
        if backend == .copilot {
            await handleCopilotServerRequest(id: id, method: method, params: params)
            return
        }

        // Auto-decline any tool requests from the title-generation thread
        if let titleThread = titleGenThreadID,
           let notifThread = params["threadId"] as? String,
           notifThread == titleThread {
            do {
                try await transport?.sendResponse(id: id, result: ["decision": "decline"])
            } catch {}
            return
        }

        if let blocked = blockedServerRequestContext(method: method, params: params) {
            if await redirectBlockedImageToolRequestIfPossible(id: id, method: method) {
                return
            }
            let message = blockedToolUseMessage(
                for: interactionMode,
                activityTitle: blocked.activityTitle,
                commandClass: blocked.commandClass
            )
            await declineBlockedServerRequest(id: id, method: method, message: message)
            interruptForBlockedToolUse(
                activityTitle: blocked.activityTitle,
                commandClass: blocked.commandClass
            )
            return
        }

        if await autoApproveServerRequestIfPossible(id: id, method: method, params: params) {
            return
        }

        switch method {
        case "item/commandExecution/requestApproval":
            await presentCommandApprovalRequest(id: id, params: params)
        case "item/fileChange/requestApproval":
            await presentFileChangeApprovalRequest(id: id, params: params)
        case "item/tool/requestUserInput":
            await presentToolUserInputRequest(id: id, params: params)
        case "item/tool/call":
            await handleDynamicToolCall(id: id, params: params)
        case "mcpServer/elicitation/request":
            let message = firstNonEmptyString(
                params["message"] as? String,
                params["prompt"] as? String,
                "Codex needs more information."
            ) ?? "Codex needs more information."
            onTranscript?(AssistantTranscriptEntry(role: .permission, text: message, emphasis: true))
            let request = AssistantPermissionRequest(
                id: approvalRequestID(from: id),
                sessionID: params["threadId"] as? String ?? activeSessionID ?? "",
                toolTitle: "Need more information",
                toolKind: "userInput",
                rationale: message,
                options: [],
                rawPayloadSummary: nil
            )
            onTimelineMutation?(
                .upsert(
                    .permission(
                        id: "permission-\(approvalRequestID(from: id))",
                        sessionID: request.sessionID,
                        turnID: activeTurnID,
                        request: request,
                        createdAt: Date(),
                        source: .runtime
                    )
                )
            )
            onStatusMessage?(message)
        default:
            onStatusMessage?("Codex requested an unsupported action: \(method)")
        }
    }

    private func autoApproveServerRequestIfPossible(
        id: JSONRPCRequestID,
        method: String,
        params: [String: Any]
    ) async -> Bool {
        guard method == "item/commandExecution/requestApproval",
              let command = params["command"] as? String,
              AssistantModePolicy.shouldAutoApproveCommandRequest(
                mode: interactionMode,
                command: command
              ) else {
            return false
        }

        do {
            try await transport?.sendResponse(id: id, result: ["decision": "accept"])
            return true
        } catch {
            await MainActor.run {
                onStatusMessage?(error.localizedDescription)
            }
            return false
        }
    }

    private func presentCommandApprovalRequest(id: JSONRPCRequestID, params: [String: Any]) async {
        let command = firstNonEmptyString(params["command"] as? String, "Approve command") ?? "Approve command"

        // Auto-decline osascript/AppleScript commands targeting privacy-protected apps.
        // These hang indefinitely waiting for a macOS TCC dialog that can't be dismissed.
        if let blockedApp = Self.detectPrivacyBlockedOsascript(in: command) {
            let declineMessage = "Automatically declined: osascript targeting \(blockedApp) would hang waiting for a macOS privacy dialog. Open \(blockedApp) manually instead."
            do {
                try await transport?.sendResponse(id: id, result: ["decision": "decline"])
            } catch {
                await MainActor.run { self.onStatusMessage?(error.localizedDescription) }
            }
            onStatusMessage?(declineMessage)
            onTranscript?(AssistantTranscriptEntry(role: .status, text: declineMessage, emphasis: true))
            updateHUD(phase: .acting, title: "Blocked osascript", detail: "Declined \(blockedApp) automation")
            return
        }

        let reason = firstNonEmptyString(params["reason"] as? String, params["cwd"] as? String)
        let options = [
            AssistantPermissionOption(id: "acceptForSession", title: "Allow for Session", kind: "command", isDefault: true),
            AssistantPermissionOption(id: "accept", title: "Allow Once", kind: "command", isDefault: false),
            AssistantPermissionOption(id: "decline", title: "Decline", kind: "command", isDefault: false),
            AssistantPermissionOption(id: "cancel", title: "Cancel Turn", kind: "command", isDefault: false)
        ]
        let request = AssistantPermissionRequest(
            id: approvalRequestID(from: id),
            sessionID: params["threadId"] as? String ?? activeSessionID ?? "",
            toolTitle: command,
            toolKind: "commandExecution",
            rationale: reason,
            options: options,
            rawPayloadSummary: command
        )
        pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
            guard let self else { return }
            do {
                try await self.transport?.sendResponse(
                    id: id,
                    result: ["decision": optionID]
                )
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        } cancelHandler: { [weak self] in
            guard let self else { return }
            do {
                try await self.transport?.sendResponse(
                    id: id,
                    result: ["decision": "cancel"]
                )
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        }
        onPermissionRequest?(request)
        onTranscript?(AssistantTranscriptEntry(role: .permission, text: "Codex wants to run: \(command)", emphasis: true))
        onTimelineMutation?(
            .upsert(
                .permission(
                    id: "permission-\(request.id)",
                    sessionID: request.sessionID,
                    turnID: activeTurnID,
                    request: request,
                    createdAt: Date(),
                    source: .runtime
                )
            )
        )
        updateHUD(phase: .waitingForPermission, title: "Approve Command", detail: friendlyCommandSummary(command))
    }

    private func presentFileChangeApprovalRequest(id: JSONRPCRequestID, params: [String: Any]) async {
        let reason = firstNonEmptyString(params["reason"] as? String, params["grantRoot"] as? String)
        let title = firstNonEmptyString(reason, "Approve file changes") ?? "Approve file changes"
        let options = [
            AssistantPermissionOption(id: "acceptForSession", title: "Allow for Session", kind: "fileChange", isDefault: true),
            AssistantPermissionOption(id: "accept", title: "Allow Once", kind: "fileChange", isDefault: false),
            AssistantPermissionOption(id: "decline", title: "Decline", kind: "fileChange", isDefault: false),
            AssistantPermissionOption(id: "cancel", title: "Cancel Turn", kind: "fileChange", isDefault: false)
        ]
        let request = AssistantPermissionRequest(
            id: approvalRequestID(from: id),
            sessionID: params["threadId"] as? String ?? activeSessionID ?? "",
            toolTitle: "File changes",
            toolKind: "fileChange",
            rationale: title,
            options: options,
            rawPayloadSummary: title
        )
        pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
            guard let self else { return }
            do {
                try await self.transport?.sendResponse(
                    id: id,
                    result: ["decision": optionID]
                )
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        } cancelHandler: { [weak self] in
            guard let self else { return }
            do {
                try await self.transport?.sendResponse(
                    id: id,
                    result: ["decision": "cancel"]
                )
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        }
        onPermissionRequest?(request)
        onTranscript?(AssistantTranscriptEntry(role: .permission, text: "Codex wants approval for file changes.", emphasis: true))
        onTimelineMutation?(
            .upsert(
                .permission(
                    id: "permission-\(request.id)",
                    sessionID: request.sessionID,
                    turnID: activeTurnID,
                    request: request,
                    createdAt: Date(),
                    source: .runtime
                )
            )
        )
        updateHUD(phase: .waitingForPermission, title: "Approve Edit", detail: "File changes")
    }

    private func presentToolUserInputRequest(id: JSONRPCRequestID, params: [String: Any]) async {
        let questions = params["questions"] as? [[String: Any]] ?? []
        let parsedQuestions = questions.compactMap { question -> AssistantUserInputQuestion? in
            let questionID = question["id"] as? String ?? UUID().uuidString
            let header = firstNonEmptyString(question["header"] as? String, question["question"] as? String, "Answer") ?? "Answer"
            let prompt = firstNonEmptyString(question["question"] as? String, header) ?? header
            let questionOptions = question["options"] as? [[String: Any]] ?? []
            let parsedOptions = questionOptions.enumerated().map { index, option in
                let label = option["label"] as? String ?? "Continue"
                return AssistantUserInputQuestionOption(
                    id: "\(questionID)-option-\(index)",
                    label: label,
                    detail: firstNonEmptyString(option["description"] as? String)
                )
            }
            return AssistantUserInputQuestion(
                id: questionID,
                header: header,
                prompt: prompt,
                options: parsedOptions,
                allowsCustomAnswer: true
            )
        }

        guard !parsedQuestions.isEmpty else {
            onStatusMessage?("Codex asked for input that needs a richer form than Open Assist shows today.")
            return
        }

        let request = AssistantPermissionRequest(
            id: approvalRequestID(from: id),
            sessionID: params["threadId"] as? String ?? activeSessionID ?? "",
            toolTitle: "Codex needs input",
            toolKind: "userInput",
            rationale: nil,
            options: [],
            userInputQuestions: parsedQuestions,
            rawPayloadSummary: nil
        )

        pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
            guard let self else { return }
            let parts = optionID.components(separatedBy: "||")
            guard parts.count == 2 else { return }
            let response: [String: Any] = [
                "answers": [
                    parts[0]: [
                        "answers": [parts[1]]
                    ]
                ]
            ]
            do {
                try await self.transport?.sendResponse(id: id, result: response)
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        } submitAnswersHandler: { [weak self] answers in
            guard let self else { return }
            let response: [String: Any] = [
                "answers": Dictionary(uniqueKeysWithValues: answers.map { questionID, values in
                    (
                        questionID,
                        ["answers": values]
                    )
                })
            ]
            do {
                try await self.transport?.sendResponse(id: id, result: response)
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        } cancelHandler: { [weak self] in
            guard let self else { return }
            do {
                try await self.transport?.sendResponse(id: id, result: ["answers": [:]])
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        }

        onPermissionRequest?(request)
        onTranscript?(AssistantTranscriptEntry(role: .permission, text: "Codex needs your answer to continue.", emphasis: true))
        onTimelineMutation?(
            .upsert(
                .permission(
                    id: "permission-\(request.id)",
                    sessionID: request.sessionID,
                    turnID: activeTurnID,
                    request: request,
                    createdAt: Date(),
                    source: .runtime
                )
            )
        )
        updateHUD(phase: .waitingForPermission, title: "Input Needed", detail: request.toolTitle)
    }

    private func handleDynamicToolCall(id: JSONRPCRequestID, params: [String: Any]) async {
        let tool = dynamicToolName(from: params) ?? "Tool"

        guard let toolKind = dynamicToolKind(for: tool) else {
            do {
                try await transport?.sendResponse(
                    id: id,
                    result: [
                        "contentItems": [[
                            "type": "inputText",
                            "text": "Open Assist does not support the dynamic tool `\(tool)` yet."
                        ]],
                        "success": false
                    ]
                )
            } catch {
                await MainActor.run {
                    onStatusMessage?(error.localizedDescription)
                }
            }
            return
        }

        let sessionID = params["threadId"] as? String ?? activeSessionID ?? ""
        let arguments = dynamicToolArguments(from: params)
        let taskSummary = dynamicToolTaskSummary(for: tool, arguments: arguments)
        let displayName = dynamicToolDisplayName(tool)
        let requiresExplicitConfirmation = dynamicToolRequiresExplicitConfirmation(
            toolName: tool,
            arguments: arguments
        )
        let approvalContextDisplayName: String?
        let approvalKind: String
        if tool == AssistantComputerUseToolDefinition.name {
            let appContext = await computerUseService.frontmostAppContext()
            approvalContextDisplayName = appContext.displayName
            approvalKind = requiresExplicitConfirmation
                ? toolKind
                : AssistantComputerUseService.sessionApprovalKey(for: appContext)
        } else {
            approvalContextDisplayName = nil
            approvalKind = toolKind
        }

        // Auto-approve native data access apps (Reminders, Contacts, Notes, Messages, Calendar reads).
        // These use safe, read-only framework access and don't need per-session user approval.
        if tool == AssistantAppActionToolDefinition.name,
           let parsed = try? AssistantAppActionService.parseRequest(from: arguments),
           let app = parsed.app, app.usesNativeAccess {
            await executeDynamicToolCall(
                toolName: tool,
                requestID: id,
                arguments: arguments
            )
            return
        }

        if tool == AssistantImageGenerationToolDefinition.name {
            await executeDynamicToolCall(
                toolName: tool,
                requestID: id,
                arguments: arguments,
                sessionID: sessionID
            )
            return
        }

        if !requiresExplicitConfirmation,
           isDynamicToolApproved(toolKind: approvalKind, for: sessionID) {
            await executeDynamicToolCall(
                toolName: tool,
                requestID: id,
                arguments: arguments,
                sessionID: sessionID
            )
            return
        }

        var options: [AssistantPermissionOption] = []
        if !requiresExplicitConfirmation {
            options.append(
                AssistantPermissionOption(
                    id: "acceptForSession",
                    title: "Allow for Session",
                    kind: approvalKind,
                    isDefault: true
                )
            )
        }
        options.append(
            AssistantPermissionOption(
                id: "accept",
                title: requiresExplicitConfirmation ? "Approve Once" : "Allow Once",
                kind: approvalKind,
                isDefault: requiresExplicitConfirmation
            )
        )
        options.append(
            AssistantPermissionOption(id: "decline", title: "Decline", kind: approvalKind, isDefault: false)
        )
        options.append(
            AssistantPermissionOption(id: "cancel", title: "Cancel Turn", kind: approvalKind, isDefault: false)
        )

        let request = AssistantPermissionRequest(
            id: approvalRequestID(from: id),
            sessionID: sessionID,
            toolTitle: displayName,
            toolKind: approvalKind,
            rationale: dynamicToolPermissionRationale(
                toolName: tool,
                taskSummary: taskSummary,
                requiresExplicitConfirmation: requiresExplicitConfirmation,
                targetDisplayName: approvalContextDisplayName
            ),
            options: options,
            rawPayloadSummary: taskSummary
        )

        pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
            guard let self else { return }

            switch optionID {
            case "acceptForSession":
                await self.rememberDynamicToolApproval(toolKind: approvalKind, for: sessionID)
                await self.executeDynamicToolCall(
                    toolName: tool,
                    requestID: id,
                    arguments: arguments,
                    sessionID: sessionID
                )
            case "accept":
                await self.executeDynamicToolCall(
                    toolName: tool,
                    requestID: id,
                    arguments: arguments,
                    sessionID: sessionID
                )
            case "cancel":
                let message = "\(displayName) was canceled for this turn."
                do {
                    try await self.transport?.sendResponse(
                        id: id,
                        result: [
                            "contentItems": [["type": "inputText", "text": message]],
                            "success": false
                        ]
                    )
                } catch {
                    await MainActor.run {
                        self.onStatusMessage?(error.localizedDescription)
                    }
                }
                await self.cancelActiveTurn()
            default:
                let message = "\(displayName) was declined for this request."
                do {
                    try await self.transport?.sendResponse(
                        id: id,
                        result: [
                            "contentItems": [["type": "inputText", "text": message]],
                            "success": false
                        ]
                    )
                } catch {
                    await MainActor.run {
                        self.onStatusMessage?(error.localizedDescription)
                    }
                }
            }
        } cancelHandler: { [weak self] in
            guard let self else { return }
            let message = "\(displayName) was canceled for this turn."
            do {
                try await self.transport?.sendResponse(
                    id: id,
                    result: [
                        "contentItems": [["type": "inputText", "text": message]],
                        "success": false
                    ]
                )
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        }

        onPermissionRequest?(request)
        onTranscript?(AssistantTranscriptEntry(role: .permission, text: "Codex wants to use \(displayName).", emphasis: true))
        onTimelineMutation?(
            .upsert(
                .permission(
                    id: "permission-\(request.id)",
                    sessionID: request.sessionID,
                    turnID: activeTurnID,
                    request: request,
                    createdAt: Date(),
                    source: .runtime
                )
            )
        )
        updateHUD(phase: .waitingForPermission, title: "Approve Action", detail: taskSummary)
    }

    private func executeDynamicToolCall(
        toolName: String,
        requestID: JSONRPCRequestID,
        arguments: Any,
        sessionID: String? = nil,
        browserLoginResume: Bool = false
    ) async {
        let displayName = dynamicToolDisplayName(toolName)

        // Pre-flight permission check — catch missing permissions before hitting the service layer
        let verdict = await preflightPermissionCheck(toolName: toolName, arguments: arguments)
        if !verdict.satisfied {
            let failedResult = AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: verdict.message, imageURL: nil)],
                success: false,
                summary: verdict.message
            )
            do {
                try await transport?.sendResponse(
                    id: requestID,
                    result: [
                        "contentItems": failedResult.contentItems.map { $0.dictionaryRepresentation() },
                        "success": false
                    ]
                )
            } catch {
                await MainActor.run { self.onStatusMessage?(error.localizedDescription) }
            }
            onStatusMessage?(verdict.message)
            updateHUD(phase: .failed, title: "\(displayName) failed", detail: verdict.message)
            return
        }

        let workingDetail: String
        var result: AssistantToolExecutionResult

        switch toolName {
        case AssistantBrowserUseToolDefinition.name:
            workingDetail = browserLoginResume
                ? "Checking the browser after sign-in"
                : "Using the selected browser profile"
            updateHUD(phase: .acting, title: displayName, detail: workingDetail)
            do {
                result = try await (
                    browserLoginResume
                        ? browserUseService.resumeAfterLogin(
                            arguments: arguments,
                            preferredModelID: preferredModelID
                        )
                        : browserUseService.run(
                            arguments: arguments,
                            preferredModelID: preferredModelID
                        )
                )
            } catch let error as AssistantBrowserUseServiceError {
                switch error {
                case .loginRequired(let prompt):
                    await presentBrowserLoginRequest(
                        id: requestID,
                        arguments: arguments,
                        prompt: prompt,
                        taskSummary: dynamicToolTaskSummary(for: toolName, arguments: arguments)
                    )
                    return
                }
            } catch {
                let summary = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? "Browser Use failed."
                result = AssistantToolExecutionResult(
                    contentItems: [.init(type: "inputText", text: summary, imageURL: nil)],
                    success: false,
                    summary: summary
                )
            }
        case AssistantAppActionToolDefinition.name:
            workingDetail = "Using a supported Mac app"
            updateHUD(phase: .acting, title: displayName, detail: workingDetail)
            result = await appActionService.run(
                arguments: arguments,
                preferredModelID: preferredModelID
            )
        case AssistantComputerUseToolDefinition.name:
            workingDetail = "Using screenshot-based desktop control"
            updateHUD(phase: .acting, title: displayName, detail: workingDetail)
            result = await computerUseService.run(
                sessionID: sessionID ?? activeSessionID ?? "",
                arguments: arguments,
                preferredModelID: preferredModelID
            )
        case AssistantImageGenerationToolDefinition.name:
            workingDetail = "Generating an image with Google Gemini"
            updateHUD(phase: .acting, title: displayName, detail: workingDetail)
            result = await imageGenerationService.run(
                arguments: arguments,
                preferredModelID: preferredModelID
            )
        default:
            workingDetail = "Unsupported dynamic tool"
            updateHUD(phase: .failed, title: displayName, detail: workingDetail)
            result = AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: "Open Assist does not support the dynamic tool `\(toolName)` yet.", imageURL: nil)],
                success: false,
                summary: "Unsupported dynamic tool."
            )
        }

        do {
            try await transport?.sendResponse(
                id: requestID,
                result: [
                    "contentItems": result.contentItems.map { $0.dictionaryRepresentation() },
                    "success": result.success
                ]
            )
        } catch {
            await MainActor.run {
                onStatusMessage?(error.localizedDescription)
            }
        }

        let screenshotDataItems = Self.imageDataItems(in: result.contentItems)
        if !screenshotDataItems.isEmpty {
            let imageTitle: String
            if toolName == AssistantImageGenerationToolDefinition.name {
                imageTitle = result.success
                    ? "Generated image"
                    : "Image generation failed"
            } else {
                imageTitle = result.success
                    ? "Screenshot from \(displayName)"
                    : "Last screenshot before \(displayName) failed"
            }
            onTimelineMutation?(
                .upsert(
                    .system(
                        id: "tool-screenshot-\(UUID().uuidString)",
                        sessionID: activeSessionID,
                        turnID: activeTurnID,
                        text: imageTitle,
                        createdAt: Date(),
                        imageAttachments: screenshotDataItems,
                        source: .runtime
                    )
                )
            )
        }

        if !result.summary.isEmpty {
            onStatusMessage?(result.summary)
        }
        updateHUD(
            phase: result.success ? .acting : .failed,
            title: result.success ? "\(displayName) finished" : "\(displayName) failed",
            detail: result.summary
        )
    }

    private func rememberDynamicToolApproval(toolKind: String, for sessionID: String) {
        guard !sessionID.isEmpty else { return }
        var approvals = approvedDynamicToolKindsBySessionID[sessionID] ?? []
        approvals.insert(toolKind)
        approvedDynamicToolKindsBySessionID[sessionID] = approvals
    }

    private func isDynamicToolApproved(toolKind: String, for sessionID: String) -> Bool {
        approvedDynamicToolKindsBySessionID[sessionID]?.contains(toolKind) == true
    }

    private func handleThreadStatusChanged(_ params: [String: Any]) {
        guard let status = params["status"] as? [String: Any] else { return }
        let type = status["type"] as? String ?? ""
        switch type {
        case "active":
            let flags = status["activeFlags"] as? [String] ?? []
            if flags.contains("waitingOnApproval") {
                updateHUD(phase: .waitingForPermission, title: "Waiting for approval", detail: nil)
            } else if flags.contains("waitingOnUserInput") {
                updateHUD(phase: .waitingForPermission, title: "Waiting for input", detail: nil)
            } else {
                updateHUD(phase: .thinking, title: "Working", detail: nil)
            }
        case "idle":
            updateHUD(phase: .idle, title: "Assistant is ready", detail: nil)
        case "systemError":
            updateHUD(phase: .failed, title: "Needs attention", detail: nil)
        default:
            break
        }
    }

    private func presentBrowserLoginRequest(
        id: JSONRPCRequestID,
        arguments: Any,
        prompt: AssistantBrowserLoginPrompt,
        taskSummary: String
    ) async {
        let proceedOption = AssistantPermissionOption(
            id: "proceed",
            title: "Proceed",
            kind: "browserLogin",
            isDefault: true
        )
        let cancelOption = AssistantPermissionOption(
            id: "cancel",
            title: "Cancel Request",
            kind: "browserLogin",
            isDefault: false
        )
        let request = AssistantPermissionRequest(
            id: approvalRequestID(from: id),
            sessionID: activeSessionID ?? "",
            toolTitle: prompt.requestTitle,
            toolKind: "browserLogin",
            rationale: prompt.requestRationale,
            options: [proceedOption, cancelOption],
            rawPayloadSummary: prompt.requestSummary
        )

        pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
            guard let self else { return }
            switch optionID {
            case "proceed":
                await self.executeDynamicToolCall(
                    toolName: AssistantBrowserUseToolDefinition.name,
                    requestID: id,
                    arguments: arguments,
                    browserLoginResume: true
                )
            default:
                await self.declineBrowserLoginRequest(
                    id: id,
                    message: "Browser sign-in was canceled for this turn."
                )
            }
        } cancelHandler: { [weak self] in
            guard let self else { return }
            await self.declineBrowserLoginRequest(
                id: id,
                message: "Browser sign-in was canceled for this turn."
            )
        }

        onPermissionRequest?(request)
        onTranscript?(
            AssistantTranscriptEntry(
                role: .permission,
                text: prompt.requestRationale,
                emphasis: true
            )
        )
        onTimelineMutation?(
            .upsert(
                .permission(
                    id: "permission-\(request.id)",
                    sessionID: request.sessionID,
                    turnID: activeTurnID,
                    request: request,
                    createdAt: Date(),
                    source: .runtime
                )
            )
        )
        onStatusMessage?(prompt.requestRationale)
        updateHUD(
            phase: .waitingForPermission,
            title: "Login Required",
            detail: prompt.pageTitle?.nonEmpty ?? taskSummary
        )
    }

    private func declineBrowserLoginRequest(id: JSONRPCRequestID, message: String) async {
        do {
            try await transport?.sendResponse(
                id: id,
                result: [
                    "contentItems": [["type": "inputText", "text": message]],
                    "success": false
                ]
            )
        } catch {
            await MainActor.run {
                onStatusMessage?(error.localizedDescription)
            }
        }

        onTranscript?(AssistantTranscriptEntry(role: .status, text: message, emphasis: true))
        onStatusMessage?(message)
        updateHUD(phase: .failed, title: "Browser login canceled", detail: message)
    }

    /// Finalize the streaming buffer: emit the final non-streaming entry and reset.
    private func flushStreamingBuffer() {
        emitStreamingAssistantDelta(force: true)

        guard let entryID = streamingEntryID, !streamingBuffer.isEmpty else {
            streamingEntryID = nil
            streamingBuffer = ""
            pendingStreamingDeltaBuffer = ""
            streamingTimelineID = nil
            streamingStartedAt = nil
            return
        }
        onTranscriptMutation?(
            .upsert(
                AssistantTranscriptEntry(
                    id: entryID,
                    role: .assistant,
                    text: streamingBuffer,
                    createdAt: streamingStartedAt ?? Date(),
                    emphasis: false,
                    isStreaming: false
                ),
                sessionID: activeSessionID
            )
        )
        if let timelineID = streamingTimelineID {
            onTimelineMutation?(
                .upsert(
                    .assistantFinal(
                        id: timelineID,
                        sessionID: activeSessionID,
                        turnID: activeTurnID,
                        text: streamingBuffer,
                        createdAt: streamingStartedAt ?? Date(),
                        updatedAt: Date(),
                        isStreaming: false,
                        source: .runtime
                    )
                )
            )
        }
        if allowsProposedPlanForActiveTurn,
           planTimelineID == nil,
           streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil {
            proposedPlanBuffer = streamingBuffer
            onProposedPlan?(streamingBuffer)
            emitPlanTimeline(text: streamingBuffer, isStreaming: false)
        }
        streamingEntryID = nil
        streamingBuffer = ""
        pendingStreamingDeltaBuffer = ""
        streamingTimelineID = nil
        streamingStartedAt = nil
    }

    private func handleItemStartedOrCompleted(_ params: [String: Any], isCompleted: Bool) {
        // Flush any in-progress streaming text before tool cards
        flushStreamingBuffer()
        flushCommentaryBuffer()

        // Handle plan items: finalize the proposed plan when completed
        if isCompleted,
           allowsProposedPlanForActiveTurn,
           let item = params["item"] as? [String: Any],
           let itemType = item["type"] as? String,
           itemType == "plan",
           let text = item["text"] as? String,
           !text.isEmpty {
            proposedPlanBuffer = text
            onProposedPlan?(text)
            emitPlanTimeline(text: text, isStreaming: false)
        }

        guard let item = params["item"] as? [String: Any] else {
            return
        }

        if let browserMCPTool = browserMCPToolContext(from: item) {
            interruptForBlockedBrowserMCPToolUse(activityTitle: browserMCPTool)
            return
        }

        if let blocked = blockedActivityContext(from: item) {
            interruptForBlockedToolUse(
                activityTitle: blocked.activityTitle,
                commandClass: blocked.commandClass
            )
            return
        }

        guard let state = parseToolCallState(from: item) else {
            return
        }

        if isCompleted {
            toolCalls.removeValue(forKey: state.id)
        } else {
            toolCalls[state.id] = state
        }
        onToolCallUpdate?(toolCalls.values.sorted { $0.title < $1.title })

        if var activity = parseActivityItem(from: item) {
            pendingActivityTimelineEmitByID[activity.id]?.cancel()
            pendingActivityTimelineEmitByID[activity.id] = nil
            lastActivityTimelineEmitTimeByID[activity.id] = nil

            if let existing = liveActivities[activity.id] {
                if activity.rawDetails?.nonEmpty == nil {
                    activity.rawDetails = existing.rawDetails
                }
                if activity.updatedAt < existing.updatedAt {
                    activity.updatedAt = existing.updatedAt
                }
            }

            if isCompleted {
                if activity.status.isActive {
                    activity.status = .completed
                }
                liveActivities.removeValue(forKey: activity.id)
            } else {
                liveActivities[activity.id] = activity
            }

            emitActivityTimelineUpdate(activity, force: true)

            if isCompleted {
                emitActivityImageTimelineUpdateIfNeeded(for: activity)
            }
        }

        if !isCompleted {
            turnToolCallCount += 1
            if let repeatedCommandLimitHit = repeatedCommandLimitHit(for: item) {
                let repeatedCommand = compactDetail(repeatedCommandLimitHit.command) ?? "Command"
                let message = "Stopped this turn because the same command repeated \(repeatedCommandLimitHit.attemptCount) times in a row: \(repeatedCommand)"
                CrashReporter.logInfo(
                    "Assistant runtime: repeated command limit reached (\(maxRepeatedCommandAttemptsPerTurn)) command=\(repeatedCommand)"
                )
                onTranscript?(AssistantTranscriptEntry(
                    role: .system,
                    text: message,
                    emphasis: true
                ))
                emitTimelineSystemMessage(message, emphasis: true)
                Task { [weak self] in await self?.cancelActiveTurn() }
                return
            }
            if maxToolCallsPerTurn > 0 && turnToolCallCount >= maxToolCallsPerTurn {
                CrashReporter.logInfo("Assistant runtime: tool call limit reached (\(maxToolCallsPerTurn)), auto-cancelling turn")
                onTranscript?(AssistantTranscriptEntry(
                    role: .system,
                    text: "Reached the tool call limit (\(maxToolCallsPerTurn)). Turn was automatically stopped.",
                    emphasis: true
                ))
                emitTimelineSystemMessage("Reached the tool call limit (\(maxToolCallsPerTurn)). Turn was automatically stopped.", emphasis: true)
                Task { [weak self] in await self?.cancelActiveTurn() }
                return
            }
            updateHUD(phase: .acting, title: hudLabelForToolKind(state.kind, fallback: state.title), detail: state.hudDetail ?? state.detail)
        }
    }

    private func hudLabelForToolKind(_ kind: String?, fallback: String) -> String {
        switch kind {
        case "commandExecution": return "Running"
        case "fileChange": return "Editing"
        case "webSearch": return "Searching"
        case "browserAutomation": return "Browsing"
        case "collabAgentToolCall": return "Delegating"
        default: return fallback
        }
    }

    private func handleCommandOutputDelta(_ params: [String: Any]) {
        guard let itemID = params["itemId"] as? String,
              let delta = params["delta"] as? String,
              delta.nonEmpty != nil else {
            return
        }

        if var existing = toolCalls[itemID] {
            let current = existing.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            existing.detail = current.isEmpty ? delta : "\(current)\n\(delta)"
            toolCalls[itemID] = existing
            // Throttle tool call list pushes for output deltas (arrive very rapidly)
            if pendingToolCallEmit == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.onToolCallUpdate?(self.toolCalls.values.sorted { $0.title < $1.title })
                    self.pendingToolCallEmit = nil
                }
                pendingToolCallEmit = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
            }
        }

        if var activity = liveActivities[itemID] {
            let current = activity.rawDetails?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            activity.rawDetails = current.isEmpty ? delta : "\(current)\n\(delta)"
            activity.updatedAt = Date()
            liveActivities[itemID] = activity
            emitActivityTimelineUpdate(activity)
            if mayContainImageReference(delta) {
                emitActivityImageTimelineUpdateIfNeeded(for: activity)
            }
        }
    }

    private func handleTurnCompleted(_ params: [String: Any]) {
        materializeCopilotFallbackReplyIfNeeded()
        let responsePreview = streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let completedTurnResponse = streamingBuffer
        flushStreamingBuffer()
        flushCommentaryBuffer()
        defer {
            allowsProposedPlanForActiveTurn = false
            activeTurnID = nil
            pendingCopilotFallbackReply = nil
        }

        guard let turn = params["turn"] as? [String: Any] else {
            updateHUD(phase: .success, title: "Finished", detail: responsePreview)
            return
        }

        let status = turn["status"] as? String ?? "completed"
        switch status {
        case "completed":
            finalizeActiveActivities(with: .completed)
            onTurnCompletion?(.completed)
            onTranscript?(AssistantTranscriptEntry(role: .status, text: "\(backend.shortDisplayName) finished this turn."))
            updateHUD(phase: .success, title: "Finished", detail: responsePreview)
            onHealthUpdate?(makeHealth(availability: .ready, summary: backend.connectedSummary))

            // After the first successful turn, request an AI-generated session title
            if sessionTurnCount == 0,
               let sessionID = activeSessionID,
               let userPrompt = firstTurnUserPrompt,
               completedTurnResponse.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil {
                let response = completedTurnResponse
                onTitleRequest?(sessionID, userPrompt, response)
            }
            sessionTurnCount += 1
        case "interrupted":
            finalizeActiveActivities(with: .interrupted)
            onTurnCompletion?(.interrupted)
            if blockedToolUseInterruptionMessage == nil {
                onTranscript?(AssistantTranscriptEntry(role: .status, text: "This turn was interrupted."))
                emitTimelineSystemMessage("This turn was interrupted.")
                updateHUD(phase: .idle, title: "Interrupted", detail: nil)
            } else {
                updateHUD(phase: .idle, title: "Mode restriction", detail: nil)
            }
            onHealthUpdate?(makeHealth(availability: .ready, summary: backend.connectedSummary))
        case "failed":
            finalizeActiveActivities(with: .failed)
            let errorText = extractString((turn["error"] as? [String: Any])?["message"]) ?? "\(backend.displayName) could not finish this turn."
            onTurnCompletion?(.failed(message: errorText))
            onTranscript?(AssistantTranscriptEntry(role: .error, text: errorText, emphasis: true))
            emitTimelineSystemMessage(errorText, emphasis: true)
            updateHUD(phase: .failed, title: "Needs attention", detail: errorText)
            // The turn failed but the transport is still connected — keep availability
            // as .ready so the user can send follow-up messages.
            onHealthUpdate?(makeHealth(availability: .ready, summary: backend.connectedSummary, detail: errorText))
        default:
            updateHUD(phase: .idle, title: "Assistant is ready", detail: nil)
        }

        blockedToolUseHandledForActiveTurn = false
        blockedToolUseInterruptionMessage = nil

        // Clean up any lingering AppleScript/osascript processes spawned during the turn
        Self.cleanupAppleScriptProcesses()
    }

    /// Resets `System Events` memory by sending it a quit signal (macOS relaunches
    /// it on demand). The old `killall -9 osascript` is no longer needed because
    /// `runAppleScript()` now uses in-process `NSAppleScript` — no child osascript
    /// processes are spawned by our tools.
    static func cleanupAppleScriptProcesses() {
        DispatchQueue.global(qos: .utility).async {
            // Reset System Events to reclaim memory (macOS auto-restarts it on next use)
            let resetSE = Process()
            resetSE.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            resetSE.arguments = ["System Events"]
            resetSE.standardOutput = FileHandle.nullDevice
            resetSE.standardError = FileHandle.nullDevice
            try? resetSE.run()
            resetSE.waitUntilExit()
        }
    }

    private func appendAssistantDelta() {
        emitStreamingAssistantDelta()
    }

    private func emitStreamingTranscriptUpdate(force: Bool = false) {
        emitStreamingAssistantDelta(force: force)
    }

    private func shouldForceStreamingDeltaFlush(for delta: String) -> Bool {
        delta.contains("\n\n") || delta.contains("\r\n\r\n") || delta.contains("\n")
    }

    private func assistantMessageTurnID(from params: [String: Any]) -> String? {
        let item = params["item"] as? [String: Any]
        let update = params["update"] as? [String: Any]
        return firstNonEmptyString(
            params["turnId"] as? String,
            params["turnID"] as? String,
            (params["turn"] as? [String: Any])?["id"] as? String,
            item?["turnId"] as? String,
            item?["turnID"] as? String,
            item?["turn_id"] as? String,
            update?["turnId"] as? String,
            update?["turnID"] as? String,
            update?["turn_id"] as? String
        )
    }

    private func acceptAssistantMessageDelta(
        threadID: String?,
        turnID: String?,
        source: String
    ) -> Bool {
        if let activeTurnID = activeTurnID?.nonEmpty {
            if let turnID = turnID?.nonEmpty,
               turnID.caseInsensitiveCompare(activeTurnID) != .orderedSame {
                CrashReporter.logWarning(
                    "Ignoring stray assistant delta source=\(source) thread=\(threadID ?? activeSessionID ?? "unknown") turn=\(turnID) activeTurn=\(activeTurnID)"
                )
                return false
            }
            return true
        }

        if let resolvedTurnID = turnID?.nonEmpty {
            activeTurnID = resolvedTurnID
            return true
        }

        CrashReporter.logInfo(
            "Ignoring stray assistant delta without active turn source=\(source) thread=\(threadID ?? activeSessionID ?? "unknown")"
        )
        return false
    }

    private func ensureStreamingIdentifiers() {
        if streamingEntryID == nil {
            streamingEntryID = UUID()
        }
        if streamingTimelineID == nil {
            streamingTimelineID = "assistant-final-\(UUID().uuidString)"
        }
        if streamingStartedAt == nil {
            streamingStartedAt = Date()
        }
    }

    private func emitStreamingAssistantDelta(force: Bool = false) {
        guard streamingEntryID != nil,
              streamingTimelineID != nil,
              pendingStreamingDeltaBuffer.nonEmpty != nil else {
            if force {
                pendingStreamingTranscriptEmit?.cancel()
                pendingStreamingTranscriptEmit = nil
                pendingAssistantTimelineEmit?.cancel()
                pendingAssistantTimelineEmit = nil
            }
            return
        }

        let minimumInterval: CFAbsoluteTime = 0.14
        let emit = { [weak self] in
            guard let self,
                  let entryID = self.streamingEntryID,
                  let timelineID = self.streamingTimelineID,
                  let delta = self.pendingStreamingDeltaBuffer.nonEmpty else { return }
            let createdAt = self.streamingStartedAt ?? Date()
            self.onTranscriptMutation?(
                .appendDelta(
                    id: entryID,
                    sessionID: self.activeSessionID,
                    role: .assistant,
                    delta: delta,
                    createdAt: createdAt,
                    emphasis: false,
                    isStreaming: true
                )
            )
            self.onTimelineMutation?(
                .appendTextDelta(
                    id: timelineID,
                    sessionID: self.activeSessionID,
                    turnID: self.activeTurnID,
                    kind: .assistantFinal,
                    delta: delta,
                    createdAt: createdAt,
                    updatedAt: Date(),
                    isStreaming: true,
                    emphasis: false,
                    source: .runtime
                )
            )
            self.pendingStreamingDeltaBuffer = ""
            self.lastStreamingTranscriptEmitTime = CFAbsoluteTimeGetCurrent()
            self.lastTimelineMutationTime = self.lastStreamingTranscriptEmitTime
            self.pendingStreamingTranscriptEmit = nil
            self.pendingAssistantTimelineEmit = nil
        }

        if force {
            pendingStreamingTranscriptEmit?.cancel()
            pendingAssistantTimelineEmit?.cancel()
            emit()
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - max(lastStreamingTranscriptEmitTime, lastTimelineMutationTime)
        if elapsed >= minimumInterval {
            pendingStreamingTranscriptEmit?.cancel()
            pendingAssistantTimelineEmit?.cancel()
            emit()
            return
        }

        guard pendingStreamingTranscriptEmit == nil, pendingAssistantTimelineEmit == nil else { return }
        let item = DispatchWorkItem(block: emit)
        pendingStreamingTranscriptEmit = item
        pendingAssistantTimelineEmit = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.01, minimumInterval - elapsed),
            execute: item
        )
    }

    private func appendCommentaryDelta(_ delta: String) {
        if commentaryTimelineID == nil {
            commentaryTimelineID = "assistant-progress-\(UUID().uuidString)"
            commentaryStartedAt = Date()
        }

        commentaryBuffer += delta
        pendingCommentaryDeltaBuffer += delta
        emitCommentaryTimelineUpdate(force: shouldForceStreamingDeltaFlush(for: delta))
    }

    private func emitCommentaryTimelineUpdate(force: Bool = false) {
        guard commentaryTimelineID != nil,
              pendingCommentaryDeltaBuffer.nonEmpty != nil else {
            if force {
                pendingCommentaryTimelineEmit?.cancel()
                pendingCommentaryTimelineEmit = nil
            }
            return
        }

        let minimumInterval: CFAbsoluteTime = 0.16
        let emit = { [weak self] in
            guard let self,
                  let commentaryTimelineID = self.commentaryTimelineID,
                  let delta = self.pendingCommentaryDeltaBuffer.nonEmpty else { return }
            self.onTimelineMutation?(
                .appendTextDelta(
                    id: commentaryTimelineID,
                    sessionID: self.activeSessionID,
                    turnID: self.activeTurnID,
                    kind: .assistantProgress,
                    delta: delta,
                    createdAt: self.commentaryStartedAt ?? Date(),
                    updatedAt: Date(),
                    isStreaming: true,
                    emphasis: false,
                    source: .runtime
                )
            )
            self.pendingCommentaryDeltaBuffer = ""
            self.lastCommentaryTimelineEmitTime = CFAbsoluteTimeGetCurrent()
            self.pendingCommentaryTimelineEmit = nil
        }

        if force {
            pendingCommentaryTimelineEmit?.cancel()
            emit()
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastCommentaryTimelineEmitTime
        if elapsed >= minimumInterval {
            pendingCommentaryTimelineEmit?.cancel()
            emit()
            return
        }

        guard pendingCommentaryTimelineEmit == nil else { return }
        let item = DispatchWorkItem(block: emit)
        pendingCommentaryTimelineEmit = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.01, minimumInterval - elapsed),
            execute: item
        )
    }

    private func flushCommentaryBuffer() {
        guard let commentaryTimelineID, !commentaryBuffer.isEmpty else {
            pendingCommentaryTimelineEmit?.cancel()
            pendingCommentaryTimelineEmit = nil
            commentaryTimelineID = nil
            commentaryStartedAt = nil
            commentaryBuffer = ""
            pendingCommentaryDeltaBuffer = ""
            return
        }

        emitCommentaryTimelineUpdate(force: true)
        onTimelineMutation?(
            .upsert(
                .assistantProgress(
                    id: commentaryTimelineID,
                    sessionID: activeSessionID,
                    turnID: activeTurnID,
                    text: commentaryBuffer,
                    createdAt: commentaryStartedAt ?? Date(),
                    updatedAt: Date(),
                    isStreaming: false,
                    source: .runtime
                )
            )
        )

        self.commentaryTimelineID = nil
        self.commentaryStartedAt = nil
        self.commentaryBuffer = ""
        self.pendingCommentaryDeltaBuffer = ""
    }

    private func emitActivityTimelineUpdate(
        _ activity: AssistantActivityItem,
        force: Bool = false
    ) {
        let activityID = activity.id
        let minimumInterval: CFAbsoluteTime = 0.10

        let emit = { [weak self] in
            guard let self else { return }
            let latestActivity = force ? activity : (self.liveActivities[activityID] ?? activity)
            self.onTimelineMutation?(.upsert(.activity(latestActivity)))
            self.lastActivityTimelineEmitTimeByID[activityID] = CFAbsoluteTimeGetCurrent()
            self.pendingActivityTimelineEmitByID[activityID] = nil
        }

        if force {
            pendingActivityTimelineEmitByID[activityID]?.cancel()
            pendingActivityTimelineEmitByID[activityID] = nil
            emit()
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - (lastActivityTimelineEmitTimeByID[activityID] ?? 0)
        if elapsed >= minimumInterval {
            pendingActivityTimelineEmitByID[activityID]?.cancel()
            pendingActivityTimelineEmitByID[activityID] = nil
            emit()
            return
        }

        guard pendingActivityTimelineEmitByID[activityID] == nil else { return }
        let item = DispatchWorkItem(block: emit)
        pendingActivityTimelineEmitByID[activityID] = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.01, minimumInterval - elapsed),
            execute: item
        )
    }

    private func emitPlanTimeline(text: String, isStreaming: Bool) {
        if planTimelineID == nil {
            planTimelineID = "plan-\(activeTurnID ?? UUID().uuidString)"
            planStartedAt = Date()
        }

        guard let planTimelineID else { return }
        onTimelineMutation?(
            .upsert(
                .plan(
                    id: planTimelineID,
                    sessionID: activeSessionID,
                    turnID: activeTurnID,
                    text: text,
                    entries: planEntriesSnapshot(from: text),
                    createdAt: planStartedAt ?? Date(),
                    updatedAt: Date(),
                    isStreaming: isStreaming,
                    source: .runtime
                )
            )
        )
    }

    private func emitTimelineSystemMessage(_ text: String, emphasis: Bool = false) {
        guard let text = text.nonEmpty else { return }
        onTimelineMutation?(
            .upsert(
                .system(
                    sessionID: activeSessionID,
                    turnID: activeTurnID,
                    text: text,
                    createdAt: Date(),
                    emphasis: emphasis,
                    source: .runtime
                )
            )
        )
    }

    private func finalizeActiveActivities(with status: AssistantActivityStatus) {
        let hadVisibleActivity = !liveActivities.isEmpty || !toolCalls.isEmpty
        let now = Date()
        for activity in liveActivities.values.sorted(by: { $0.startedAt < $1.startedAt }) {
            var finalized = activity
            finalized.status = status
            finalized.updatedAt = now
            emitActivityTimelineUpdate(finalized, force: true)
        }
        liveActivities.removeAll()
        toolCalls.removeAll()
        pendingToolCallEmit?.cancel()
        pendingToolCallEmit = nil
        if hadVisibleActivity {
            onToolCallUpdate?([])
        }
    }

    private func resetStreamingTimelineState() {
        pendingAssistantTimelineEmit?.cancel()
        pendingAssistantTimelineEmit = nil
        pendingStreamingTranscriptEmit?.cancel()
        pendingStreamingTranscriptEmit = nil
        pendingCommentaryTimelineEmit?.cancel()
        pendingCommentaryTimelineEmit = nil
        pendingToolCallEmit?.cancel()
        pendingToolCallEmit = nil
        pendingActivityTimelineEmitByID.values.forEach { $0.cancel() }
        pendingActivityTimelineEmitByID.removeAll()
        lastActivityTimelineEmitTimeByID.removeAll()
        streamingEntryID = nil
        streamingBuffer = ""
        pendingStreamingDeltaBuffer = ""
        streamingTimelineID = nil
        streamingStartedAt = nil
        commentaryTimelineID = nil
        commentaryStartedAt = nil
        commentaryBuffer = ""
        pendingCommentaryDeltaBuffer = ""
        pendingCopilotFallbackReply = nil
        planTimelineID = nil
        planStartedAt = nil
        proposedPlanBuffer = ""
        allowsProposedPlanForActiveTurn = false
        lastTimelineMutationTime = 0
        lastStreamingTranscriptEmitTime = 0
        lastCommentaryTimelineEmitTime = 0
    }

    private func parseActivityItem(from item: [String: Any]) -> AssistantActivityItem? {
        guard let state = parseToolCallState(from: item) else { return nil }

        let rawKind = normalizedActivityType(item["type"] as? String ?? state.kind ?? "other")
        let kind = activityKind(from: rawKind)
        let status = parsedActivityStatus(from: state.status, fallback: .running)
        let details = firstNonEmptyString(
            state.detail,
            item["command"] as? String,
            (item["action"] as? String),
            ((item["action"] as? [String: Any])?["query"] as? String),
            extractString(item["arguments"]),
            extractString(item["result"])
        )

        return AssistantActivityItem(
            id: state.id,
            sessionID: activeSessionID,
            turnID: activeTurnID,
            kind: kind,
            title: state.title,
            status: status,
            friendlySummary: activitySummary(kind: kind, title: state.title),
            rawDetails: compactDetail(details),
            startedAt: liveActivities[state.id]?.startedAt ?? Date(),
            updatedAt: Date(),
            source: .runtime
        )
    }

    private func emitActivityImageTimelineUpdateIfNeeded(for activity: AssistantActivityItem) {
        let imageAttachments = assistantActivityImageAttachments(
            for: activity,
            sessionCWD: activeSessionCWD,
            maxCount: 3
        )
        guard !imageAttachments.isEmpty else { return }

        onTimelineMutation?(
            .upsert(
                .system(
                    id: "activity-screenshot-\(activity.id)",
                    sessionID: activity.sessionID ?? activeSessionID,
                    turnID: activity.turnID ?? activeTurnID,
                    text: timelineImageTitle(for: activity),
                    createdAt: activity.updatedAt,
                    imageAttachments: imageAttachments,
                    source: .runtime
                )
            )
        )
    }

    private func timelineImageTitle(for activity: AssistantActivityItem) -> String {
        let normalizedTitle = activity.title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch activity.kind {
        case .commandExecution:
            return "Screenshot captured from \(normalizedTitle.isEmpty ? "Command" : normalizedTitle)"
        case .dynamicToolCall:
            return "Screenshot captured from \(normalizedTitle.isEmpty ? "Tool" : normalizedTitle)"
        case .browserAutomation:
            return "Screenshot captured while using the browser"
        default:
            return "Latest screenshot"
        }
    }

    private func mayContainImageReference(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains(".png")
            || lowered.contains(".jpg")
            || lowered.contains(".jpeg")
            || lowered.contains(".gif")
            || lowered.contains(".webp")
            || lowered.contains(".heic")
            || lowered.contains(".tiff")
    }

    private func normalizedActivityType(_ rawValue: String?) -> String {
        let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            ?? "other"

        switch value {
        case "command_execution":
            return "commandExecution"
        case "file_change":
            return "fileChange"
        case "web_search", "web_search_call":
            return "webSearch"
        case "browser_automation":
            return "browserAutomation"
        case "mcp_tool_call":
            return "mcpToolCall"
        case "dynamic_tool_call", "custom_tool_call", "custom_tool_call_output":
            return "dynamicToolCall"
        case "collab_agent_tool_call":
            return "collabAgentToolCall"
        case "agent_message":
            return "agentMessage"
        case "assistant_message":
            return "assistantMessage"
        case "user_message":
            return "userMessage"
        default:
            return value
        }
    }

    private func activityKind(from rawValue: String?) -> AssistantActivityKind {
        switch normalizedActivityType(rawValue) {
        case "commandExecution":
            return .commandExecution
        case "fileChange":
            return .fileChange
        case "webSearch":
            return .webSearch
        case "browserAutomation":
            return .browserAutomation
        case "mcpToolCall":
            return .mcpToolCall
        case "dynamicToolCall":
            return .dynamicToolCall
        case "collabAgentToolCall":
            return .subagent
        case "reasoning":
            return .reasoning
        default:
            return .other
        }
    }

    private func parsedActivityStatus(
        from rawValue: String?,
        fallback: AssistantActivityStatus
    ) -> AssistantActivityStatus {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return fallback
        }

        switch rawValue {
        case "pending":
            return .pending
        case "waiting":
            return .waiting
        case "completed", "complete", "succeeded", "success":
            return .completed
        case "failed", "errored", "error":
            return .failed
        case "interrupted", "cancelled", "canceled":
            return .interrupted
        case "inprogress", "in_progress", "running", "working", "active", "started":
            return .running
        default:
            return fallback
        }
    }

    private func repeatedCommandLimitHit(
        for item: [String: Any]
    ) -> AssistantRepeatedCommandLimitHit? {
        guard normalizedActivityType(item["type"] as? String) == "commandExecution",
              let command = item["command"] as? String else {
            return nil
        }

        return repeatedCommandTracker.record(
            command: command,
            maxAttempts: maxRepeatedCommandAttemptsPerTurn
        )
    }

    private func activitySummary(kind: AssistantActivityKind, title: String) -> String {
        switch kind {
        case .commandExecution:
            return "Ran a terminal command."
        case .fileChange:
            return "Edited files in the workspace."
        case .webSearch:
            return "Searched the web."
        case .browserAutomation:
            return "Used the browser."
        case .mcpToolCall:
            return "Used an MCP tool."
        case .dynamicToolCall:
            switch title {
            case "Browser Use":
                return "Used the browser."
            case "App Action":
                return "Used a Mac app."
            case "Computer Use":
                return "Controlled the visible desktop."
            case "Image Generation":
                return "Generated an image."
            default:
                return "Used \(title)."
            }
        case .subagent:
            return "Worked with a subagent."
        case .reasoning:
            return "Thought through the task."
        case .other:
            return "Ran a tool."
        }
    }

    func toolCallStateForTesting(from item: [String: Any]) -> AssistantToolCallState? {
        parseToolCallState(from: item)
    }

    func activitySummaryForTesting(kind: AssistantActivityKind, title: String) -> String {
        activitySummary(kind: kind, title: title)
    }

    func setCurrentSessionIDForTesting(_ sessionID: String?) {
        activeSessionID = sessionID
    }

    func setExecutablePathForTesting(_ path: String?) {
        currentCodexPath = path?.nonEmpty
    }

    func currentExecutablePathForTesting() -> String? {
        currentCodexPath
    }

    func pendingCopilotFallbackReplyForTesting() -> String? {
        pendingCopilotFallbackReply
    }

    func subagentsForTesting() -> [SubagentState] {
        activeSubagents.values.sorted { lhs, rhs in
            if lhs.status.isActive != rhs.status.isActive {
                return lhs.status.isActive
            }
            return lhs.id < rhs.id
        }
    }

    func processCollaborationNotificationForTesting(
        method: String,
        params: [String: Any]
    ) {
        switch method {
        case "item/collabAgentSpawn/begin":
            handleCollabSpawnBegin(params)
        case "item/collabAgentSpawn/end":
            handleCollabSpawnEnd(params)
        case "item/collabAgentInteraction/begin":
            handleCollabInteractionBegin(params)
        case "item/collabAgentInteraction/end":
            handleCollabInteractionEnd(params)
        case "item/collabClose/begin", "item/collabClose/end":
            handleCollabClose(params)
        case "item/collabWaiting/begin":
            handleCollabWaitingBegin(params)
        case "item/collabWaiting/end":
            handleCollabWaitingEnd(params)
        default:
            break
        }
    }

    func commandSafetyClassForTesting(_ command: String) -> AssistantCommandSafetyClass {
        AssistantModePolicy.commandSafetyClass(for: command)
    }

    func isToolActivityAllowedForTesting(
        mode: AssistantInteractionMode,
        rawType: String,
        command: String? = nil,
        toolName: String? = nil
    ) -> Bool {
        AssistantModePolicy.isAllowed(
            mode: mode,
            activityKind: activityKind(from: rawType),
            command: command,
            toolName: toolName
        )
    }

    func processActivityEventForTesting(
        _ item: [String: Any],
        isCompleted: Bool = false
    ) {
        handleItemStartedOrCompleted(["item": item], isCompleted: isCompleted)
    }

    func configureImageAttachmentContextForTesting(
        includesImages: Bool,
        modelSupportsImageInput: Bool,
        redirectedAlready: Bool = false
    ) {
        currentTurnIncludesImageAttachments = includesImages
        currentTurnModelSupportsImageInput = modelSupportsImageInput
        redirectedImageToolCallForActiveTurn = redirectedAlready
    }

    func shouldRedirectBlockedImageToolRequestForTesting(method: String) -> Bool {
        interactionMode != .agentic
            && method == "item/tool/call"
            && currentTurnIncludesImageAttachments
            && currentTurnModelSupportsImageInput
            && !redirectedImageToolCallForActiveTurn
    }

    func dynamicToolNamesForTesting(mode: AssistantInteractionMode) -> [String] {
        dynamicToolSpecs(for: mode).compactMap { tool in
            tool["name"] as? String
        }
    }

    func dynamicToolRequiresExplicitConfirmationForTesting(
        toolName: String,
        arguments: Any
    ) -> Bool {
        dynamicToolRequiresExplicitConfirmation(toolName: toolName, arguments: arguments)
    }

    func turnStartParamsForTesting(
        mode: AssistantInteractionMode,
        threadID: String = "thread-1",
        prompt: String = "Hello",
        modelID: String? = "gpt-5.4"
    ) -> [String: Any] {
        let previousMode = interactionMode
        interactionMode = mode
        defer { interactionMode = previousMode }
        return turnStartParams(
            threadID: threadID,
            prompt: prompt,
            attachments: [],
            modelID: modelID
        )
    }

    func buildInstructionsForTesting() async -> String {
        await buildInstructions()
    }

    func processErrorNotificationForTesting(
        _ message: String,
        activeTurnID: String? = "turn-1"
    ) async {
        let previousTurnID = self.activeTurnID
        self.activeTurnID = activeTurnID
        defer { self.activeTurnID = previousTurnID }
        await handleNotification(method: "error", params: ["message": message])
    }

    func configureStreamingTurnForTesting(
        sessionID: String = "thread-1",
        turnID: String = "turn-1",
        text: String,
        mode: AssistantInteractionMode = .plan
    ) {
        activeSessionID = sessionID
        activeTurnID = turnID
        interactionMode = mode
        allowsProposedPlanForActiveTurn = mode == .plan
        streamingEntryID = UUID()
        streamingTimelineID = "assistant-final-test"
        streamingStartedAt = Date()
        streamingBuffer = text
    }

    func configureSessionForTesting(
        sessionID: String = "thread-1",
        turnID: String? = nil
    ) {
        activeSessionID = sessionID
        activeTurnID = turnID
    }

    func processAgentMessageDeltaNotificationForTesting(
        delta: String,
        threadID: String = "thread-1",
        turnID: String? = nil,
        channel: String? = nil
    ) async {
        backend = .codex
        activeSessionID = threadID
        var params: [String: Any] = [
            "threadId": threadID,
            "delta": delta
        ]
        if let turnID {
            params["turnId"] = turnID
        }
        if let channel {
            params["channel"] = channel
        }
        await handleNotification(method: "item/agentMessage/delta", params: params)
    }

    func processTurnCompletedForTesting(status: String = "completed") async {
        await handleNotification(
            method: "turn/completed",
            params: [
                "turn": [
                    "status": status
                ]
            ]
        )
    }

    func processProcessExitedForTesting(message: String? = nil) async {
        await handleIncomingEvent(.processExited(message))
    }

    func processServerRequestForTesting(
        method: String,
        params: [String: Any]
    ) async {
        await handleServerRequest(id: .string("test-request"), method: method, params: params)
    }

    func processCopilotSessionUpdateForTesting(_ update: [String: Any]) async {
        backend = .copilot
        let sessionID = firstNonEmptyString(
            update["sessionId"] as? String,
            activeSessionID
        ) ?? "copilot-test-session"
        await handleCopilotNotification(
            method: "session/update",
            params: [
                "sessionId": sessionID,
                "update": update
            ]
        )
    }

    func processCopilotPromptCompletionForTesting(stopReason: String? = nil) {
        backend = .copilot
        let payload = stopReason.map { ["stopReason": $0] } ?? [:]
        handleCopilotPromptCompletion(from: payload)
    }

    func blockedToolUseMessage(
        for mode: AssistantInteractionMode,
        activityTitle: String? = nil,
        commandClass: AssistantCommandSafetyClass? = nil
    ) -> String {
        if mode == .conversational,
           currentTurnIncludesImageAttachments,
           let normalizedTitle = activityTitle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           normalizedTitle == "tool"
            || normalizedTitle == "browser"
            || normalizedTitle == "browser use"
            || normalizedTitle == "app action" {
            return "I stopped before using a tool because your image was already attached. Chat mode should answer directly from attached images when the selected model supports image input. Live browser or app automation still needs Agentic mode."
        }

        return AssistantModePolicy.blockedMessage(
            mode: mode,
            activityTitle: activityTitle,
            commandClass: commandClass
        )
    }

    private func interruptForBlockedToolUse(
        activityTitle: String? = nil,
        commandClass: AssistantCommandSafetyClass? = nil
    ) {
        guard interactionMode != .agentic else { return }
        guard !blockedToolUseHandledForActiveTurn else { return }

        blockedToolUseHandledForActiveTurn = true
        let message = blockedToolUseMessage(
            for: interactionMode,
            activityTitle: activityTitle,
            commandClass: commandClass
        )
        onModeRestriction?(AssistantModeRestrictionEvent(
            mode: interactionMode,
            activityTitle: activityTitle,
            commandClass: commandClass
        ))
        blockedToolUseInterruptionMessage = message
        onTranscript?(AssistantTranscriptEntry(role: .system, text: message, emphasis: true))
        emitTimelineSystemMessage(message, emphasis: true)
        onStatusMessage?(message)
        updateHUD(phase: .idle, title: "Mode restriction", detail: activityTitle)

        Task { [weak self] in
            await self?.cancelActiveTurn()
        }
    }

    private func interruptForBlockedBrowserMCPToolUse(activityTitle: String) {
        guard !blockedToolUseHandledForActiveTurn else { return }

        blockedToolUseHandledForActiveTurn = true
        let message = """
        Open Assist keeps browser work in the selected signed-in browser profile. Do not switch to a separate Playwright or MCP browser session for \(activityTitle).
        """
        blockedToolUseInterruptionMessage = message
        onTranscript?(AssistantTranscriptEntry(role: .system, text: message, emphasis: true))
        emitTimelineSystemMessage(message, emphasis: true)
        onStatusMessage?(message)
        updateHUD(phase: .idle, title: "Browser switch blocked", detail: activityTitle)

        Task { [weak self] in
            await self?.cancelActiveTurn()
        }
    }

    private func redirectBlockedImageToolRequestIfPossible(
        id: JSONRPCRequestID,
        method: String
    ) async -> Bool {
        guard interactionMode != .agentic else { return false }
        guard method == "item/tool/call" else { return false }
        guard currentTurnIncludesImageAttachments, currentTurnModelSupportsImageInput else {
            return false
        }
        guard !redirectedImageToolCallForActiveTurn else { return false }

        redirectedImageToolCallForActiveTurn = true

        let message = """
        The user already attached the image for this turn. Do not use tools or browser/app automation just to inspect it. Read the attached image directly and answer from it.
        """

        do {
            try await transport?.sendResponse(
                id: id,
                result: [
                    "contentItems": [["type": "inputText", "text": message]],
                    "success": false
                ]
            )
        } catch {
            await MainActor.run {
                onStatusMessage?(error.localizedDescription)
            }
        }

        return true
    }

    private func blockedServerRequestContext(
        method: String,
        params: [String: Any]
    ) -> (activityTitle: String, commandClass: AssistantCommandSafetyClass?)? {
        guard interactionMode != .agentic else { return nil }

        switch method {
        case "item/commandExecution/requestApproval":
            let command = params["command"] as? String ?? ""
            let commandClass = AssistantModePolicy.commandSafetyClass(for: command)
            guard !AssistantModePolicy.isAllowed(
                mode: interactionMode,
                activityKind: .commandExecution,
                command: command
            ) else {
                return nil
            }
            return (AssistantModePolicy.activityTitle(forBlockedCommand: command), commandClass)
        case "item/fileChange/requestApproval":
            guard !AssistantModePolicy.isAllowed(
                mode: interactionMode,
                activityKind: .fileChange
            ) else {
                return nil
            }
            return ("File Changes", nil)
        case "item/tool/call":
            let toolName = dynamicToolName(from: params)
            guard !AssistantModePolicy.isAllowed(
                mode: interactionMode,
                activityKind: .dynamicToolCall,
                toolName: toolName
            ) else {
                return nil
            }
            return (dynamicToolDisplayName(toolName), nil)
        default:
            return nil
        }
    }

    private func blockedActivityContext(
        from item: [String: Any]
    ) -> (activityTitle: String, commandClass: AssistantCommandSafetyClass?)? {
        guard interactionMode != .agentic else { return nil }
        let rawType = item["type"] as? String
        let kind = activityKind(from: rawType)
        let command = item["command"] as? String
        let toolName = dynamicToolName(from: item)

        guard !AssistantModePolicy.isAllowed(
            mode: interactionMode,
            activityKind: kind,
            command: command,
            toolName: toolName
        ) else {
            return nil
        }

        let title = activityTitleForPolicy(kind: kind, item: item)
        let commandClass = kind == .commandExecution
            ? AssistantModePolicy.commandSafetyClass(for: command ?? "")
            : nil
        return (title, commandClass)
    }

    private func browserMCPToolContext(from item: [String: Any]) -> String? {
        guard normalizedActivityType(item["type"] as? String) == "mcpToolCall" else {
            return nil
        }

        let server = ((item["server"] as? String) ?? "MCP").trimmingCharacters(in: .whitespacesAndNewlines)
        let tool = ((item["tool"] as? String) ?? (item["name"] as? String) ?? "tool")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = "\(server) \(tool)".lowercased()
        guard lowered.contains("playwright") || lowered.contains("browser_") else {
            return nil
        }

        return "\(server): \(tool)"
    }

    private func activityTitleForPolicy(
        kind: AssistantActivityKind,
        item: [String: Any]
    ) -> String {
        switch kind {
        case .commandExecution:
            return AssistantModePolicy.activityTitle(forBlockedCommand: item["command"] as? String)
        case .fileChange:
            return "File Changes"
        case .webSearch:
            return "Web Search"
        case .browserAutomation:
            return "Browser"
        case .mcpToolCall:
            let server = item["server"] as? String ?? "MCP"
            let tool = item["tool"] as? String ?? "tool"
            return "\(server): \(tool)"
        case .dynamicToolCall:
            return dynamicToolDisplayName(dynamicToolName(from: item))
        case .subagent:
            return "Subagent"
        case .reasoning:
            return "Reasoning"
        case .other:
            return "Tool"
        }
    }

    private func dynamicToolDisplayName(_ rawTool: String?) -> String {
        switch rawTool {
        case AssistantBrowserUseToolDefinition.name:
            return "Browser Use"
        case AssistantAppActionToolDefinition.name:
            return "App Action"
        case AssistantComputerUseToolDefinition.name:
            return "Computer Use"
        case AssistantImageGenerationToolDefinition.name:
            return "Image Generation"
        default:
            return rawTool ?? "Tool"
        }
    }

    private func dynamicToolKind(for rawTool: String?) -> String? {
        switch rawTool {
        case AssistantBrowserUseToolDefinition.name:
            return AssistantBrowserUseToolDefinition.toolKind
        case AssistantAppActionToolDefinition.name:
            return AssistantAppActionToolDefinition.toolKind
        case AssistantComputerUseToolDefinition.name:
            return AssistantComputerUseToolDefinition.toolKind
        case AssistantImageGenerationToolDefinition.name:
            return AssistantImageGenerationToolDefinition.toolKind
        default:
            return nil
        }
    }

    private func dynamicToolTaskSummary(for toolName: String, arguments: Any) -> String {
        switch toolName {
        case AssistantBrowserUseToolDefinition.name:
            return (try? AssistantBrowserUseService.parseTask(from: arguments).summaryLine) ?? "Use the selected browser profile"
        case AssistantAppActionToolDefinition.name:
            return (try? AssistantAppActionService.parseRequest(from: arguments).task) ?? "Use a supported Mac app"
        case AssistantComputerUseToolDefinition.name:
            return (try? AssistantComputerUseService.parseRequest(from: arguments).summaryLine) ?? "Use screenshot-based desktop control"
        case AssistantImageGenerationToolDefinition.name:
            return (try? AssistantImageGenerationService.parseRequest(from: arguments).summaryLine) ?? "Generate an image"
        default:
            return "Use a dynamic tool"
        }
    }

    private static func imageDataItems(
        in contentItems: [AssistantToolExecutionResult.ContentItem]
    ) -> [Data] {
        var images: [Data] = []
        for item in contentItems {
            guard item.type == "inputImage",
                  let imageURL = item.imageURL,
                  let data = dataFromDataURL(imageURL) else {
                continue
            }
            images.append(data)
        }
        return images
    }

    private static func dataFromDataURL(_ rawValue: String) -> Data? {
        guard rawValue.hasPrefix("data:"),
              let commaIndex = rawValue.firstIndex(of: ",") else {
            return nil
        }

        let metadata = rawValue[..<commaIndex]
        guard metadata.localizedCaseInsensitiveContains("base64") else {
            return nil
        }

        let encoded = String(rawValue[rawValue.index(after: commaIndex)...])
        return Data(base64Encoded: encoded)
    }

    private func dynamicToolPermissionRationale(
        toolName: String,
        taskSummary: String,
        requiresExplicitConfirmation: Bool,
        targetDisplayName: String? = nil
    ) -> String {
        let lead: String
        switch toolName {
        case AssistantBrowserUseToolDefinition.name:
            lead = "Browser Use works in the selected signed-in browser profile on this Mac and keeps you in that same browser session."
        case AssistantAppActionToolDefinition.name:
            lead = "App Action can talk to supported Mac apps like Finder, Terminal, Calendar, System Settings, Reminders, Contacts, Notes, and Messages."
        case AssistantComputerUseToolDefinition.name:
            lead = "Computer Use captures the visible screen on this Mac, then uses mouse or keyboard actions on the live desktop when browser_use and app_action are not enough."
        case AssistantImageGenerationToolDefinition.name:
            lead = "Image Generation sends the request to Google Gemini using the shared Google AI Studio API key configured in Open Assist and returns the generated image back into the conversation."
        default:
            lead = "This tool can control parts of your Mac."
        }

        let riskLine = requiresExplicitConfirmation
            ? "\n\nThis request looks higher risk, so Open Assist needs a fresh confirmation for this one."
            : ""
        let targetLine = targetDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map {
            "\n\nCurrent app: \($0)"
        } ?? ""

        return lead + targetLine + riskLine + "\n\nRequested task: \(taskSummary)"
    }

    private func dynamicToolRequiresExplicitConfirmation(
        toolName: String,
        arguments: Any
    ) -> Bool {
        guard dynamicToolKind(for: toolName) != nil else { return false }

        if toolName == AssistantAppActionToolDefinition.name,
           let request = try? AssistantAppActionService.parseRequest(from: arguments),
           (
               request.command?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
                || request.app == .terminal
                || request.commit
           ) {
            return true
        }
        if toolName == AssistantComputerUseToolDefinition.name,
           let request = try? AssistantComputerUseService.parseRequest(from: arguments) {
            return request.isHighRisk
        }

        let summary = dynamicToolTaskSummary(for: toolName, arguments: arguments).lowercased()
        let riskyKeywords = ["send", "post", "purchase", "delete", "submit"]
        return riskyKeywords.contains(where: summary.contains)
    }

    private func threadApprovalPolicy(for mode: AssistantInteractionMode) -> String {
        switch mode {
        case .conversational:
            return "untrusted"
        case .plan, .agentic:
            return "on-request"
        }
    }

    private func threadSandboxMode(for mode: AssistantInteractionMode) -> String {
        switch mode {
        case .conversational:
            return "read-only"
        case .plan, .agentic:
            return "danger-full-access"
        }
    }

    private func turnApprovalPolicy(for mode: AssistantInteractionMode) -> String {
        switch mode {
        case .conversational:
            return "untrusted"
        case .plan, .agentic:
            return "on-request"
        }
    }

    private func turnSandboxPolicy(for mode: AssistantInteractionMode) -> [String: Any]? {
        switch mode {
        case .conversational:
            return [
                "type": "readOnly",
                "networkAccess": true
            ]
        case .plan, .agentic:
            return nil
        }
    }

    private func declineBlockedServerRequest(
        id: JSONRPCRequestID,
        method: String,
        message: String
    ) async {
        do {
            switch method {
            case "item/commandExecution/requestApproval",
                 "item/fileChange/requestApproval":
                try await transport?.sendResponse(id: id, result: ["decision": "decline"])
            case "item/tool/call":
                try await transport?.sendResponse(
                    id: id,
                    result: [
                        "contentItems": [["type": "inputText", "text": message]],
                        "success": false
                    ]
                )
            default:
                break
            }
        } catch {
            await MainActor.run {
                onStatusMessage?(error.localizedDescription)
            }
        }
    }

    private func planEntriesSnapshot(from text: String) -> [AssistantPlanEntry]? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }
        return lines.map { AssistantPlanEntry(content: $0, status: "pending") }
    }

    private func parsePlanEntries(from raw: Any?) -> [AssistantPlanEntry] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.map { row in
            AssistantPlanEntry(
                content: row["step"] as? String ?? "Plan step",
                status: row["status"] as? String ?? "pending"
            )
        }
    }

    private func parseToolCallState(from item: [String: Any]) -> AssistantToolCallState? {
        guard let id = item["id"] as? String else { return nil }
        let type = normalizedActivityType(item["type"] as? String ?? "work")
        guard shouldRenderActivity(for: type) else { return nil }
        let status = item["status"] as? String ?? "inProgress"

        switch type {
        case "commandExecution":
            let command = firstNonEmptyString(item["command"] as? String, "Command") ?? "Command"
            return AssistantToolCallState(
                id: id,
                title: "Command",
                kind: type,
                status: status,
                detail: compactDetail(command),
                hudDetail: friendlyCommandSummary(command)
            )
        case "fileChange":
            let changeCount = (item["changes"] as? [[String: Any]])?.count ?? 0
            let detail = changeCount > 0 ? "\(changeCount) file change\(changeCount == 1 ? "" : "s")" : "Applying file changes"
            return AssistantToolCallState(
                id: id,
                title: "File Changes",
                kind: type,
                status: status,
                detail: detail
            )
        case "mcpToolCall":
            let server = item["server"] as? String ?? "MCP"
            let tool = item["tool"] as? String ?? "tool"
            return AssistantToolCallState(
                id: id,
                title: "\(server): \(tool)",
                kind: type,
                status: status,
                detail: compactDetail(extractString(item["arguments"])),
                hudDetail: "Using \(tool)"
            )
        case "dynamicToolCall":
            let rawTool = dynamicToolName(from: item) ?? "Tool"
            let tool = dynamicToolDisplayName(rawTool)
            return AssistantToolCallState(
                id: id,
                title: tool,
                kind: type,
                status: status,
                detail: compactDetail(extractString(item["arguments"])),
                hudDetail: "Using \(tool)"
            )
        case "webSearch":
            let query = firstNonEmptyString(
                item["query"] as? String,
                ((item["action"] as? [String: Any])?["query"] as? String)
            )
            let truncatedQuery = query.map { String($0.prefix(40)) }
            let searchHudDetail = truncatedQuery.map { "Searching: \($0)" } ?? "Searching the web"
            return AssistantToolCallState(id: id, title: "Web Search", kind: type, status: status, detail: compactDetail(query), hudDetail: searchHudDetail)
        case "browserAutomation":
            let action = item["action"] as? String ?? "Browser action"
            return AssistantToolCallState(id: id, title: "Browser", kind: type, status: status, detail: compactDetail(action), hudDetail: "Browsing")
        case "collabAgentToolCall":
            handleCollabToolCall(item: item, status: status)
            let tool = item["tool"] as? String ?? "collab"
            let nickname = (item["collabAgent"] as? [String: Any])?["agent_nickname"] as? String
            let detail = nickname ?? tool
            return AssistantToolCallState(id: id, title: "Subagent", kind: type, status: status, detail: detail)
        default:
            return AssistantToolCallState(
                id: id,
                title: type.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression).capitalized,
                kind: type,
                status: status,
                detail: compactDetail(extractString(item["result"]))
            )
        }
    }

    func shouldRenderActivity(for rawType: String) -> Bool {
        switch normalizedActivityType(rawType) {
        case "agentMessage", "assistantMessage", "message", "plan", "reasoning", "userMessage":
            return false
        default:
            return true
        }
    }

    private func parseAccountSnapshot(from raw: Any) -> AssistantAccountSnapshot {
        guard let payload = raw as? [String: Any] else {
            return .signedOut
        }

        let requiresOpenAIAuth = payload["requiresOpenaiAuth"] as? Bool ?? false
        guard let account = payload["account"] as? [String: Any],
              let type = account["type"] as? String else {
            return AssistantAccountSnapshot(
                authMode: .none,
                email: nil,
                planType: nil,
                requiresOpenAIAuth: requiresOpenAIAuth,
                loginInProgress: false,
                pendingLoginURL: nil,
                pendingLoginID: nil
            )
        }

        let authMode: AssistantAccountAuthMode
        switch type {
        case "chatgpt":
            authMode = .chatGPT
        case "apiKey":
            authMode = .apiKey
        default:
            authMode = .none
        }

        return AssistantAccountSnapshot(
            authMode: authMode,
            email: account["email"] as? String,
            planType: account["planType"] as? String,
            requiresOpenAIAuth: requiresOpenAIAuth,
            loginInProgress: currentAccountSnapshot.loginInProgress,
            pendingLoginURL: currentAccountSnapshot.pendingLoginURL,
            pendingLoginID: currentAccountSnapshot.pendingLoginID
        )
    }

    private func parseModels(from raw: Any) -> [AssistantModelOption] {
        guard let payload = raw as? [String: Any],
              let rows = payload["data"] as? [[String: Any]] else {
            return []
        }

        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let efforts: [String] = (row["supportedReasoningEfforts"] as? [[String: Any]])?.compactMap {
                $0["reasoningEffort"] as? String
            } ?? []
            return AssistantModelOption(
                id: id,
                displayName: firstNonEmptyString(row["displayName"] as? String, id) ?? id,
                description: firstNonEmptyString(row["description"] as? String, row["model"] as? String, id) ?? id,
                isDefault: row["isDefault"] as? Bool ?? false,
                hidden: row["hidden"] as? Bool ?? false,
                supportedReasoningEfforts: efforts,
                defaultReasoningEffort: row["defaultReasoningEffort"] as? String,
                inputModalities: AssistantModelOption.normalizedInputModalities(from: row["inputModalities"])
            )
        }
    }

    var browserProfileContext: [String: String]?
    var customInstructions: String?
    var activeSkills: [AssistantSkillDescriptor] = []
    var reasoningEffort: String?
    var serviceTier: String?
    var interactionMode: AssistantInteractionMode = .agentic
    private var currentTurnIncludesImageAttachments = false
    private var currentTurnModelSupportsImageInput = false
    private var redirectedImageToolCallForActiveTurn = false
    private var blockedToolUseHandledForActiveTurn = false
    private var blockedToolUseInterruptionMessage: String?

    // Proposed plan streaming: accumulates item/plan/delta content
    private var proposedPlanBuffer: String = ""
    private var allowsProposedPlanForActiveTurn = false

    /// Session IDs that have been detached. Notifications from these sessions are dropped.
    private var detachedSessionIDs: Set<String> = []

    private func dynamicToolSpecs(for mode: AssistantInteractionMode) -> [[String: Any]] {
        switch mode {
        case .conversational, .plan:
            return [
                AssistantImageGenerationToolDefinition.dynamicToolSpec()
            ]
        case .agentic:
            var tools: [[String: Any]] = [
                AssistantImageGenerationToolDefinition.dynamicToolSpec(),
                AssistantAppActionToolDefinition.dynamicToolSpec(),
                AssistantBrowserUseToolDefinition.dynamicToolSpec()
            ]
            if SettingsStore.shared.assistantComputerUseEnabled {
                tools.append(AssistantComputerUseToolDefinition.dynamicToolSpec())
            }
            return tools
        }
    }

    private func dynamicToolName(from payload: [String: Any]) -> String? {
        let candidatePayloads: [[String: Any]] = [
            payload,
            payload["item"] as? [String: Any],
            payload["toolCall"] as? [String: Any],
            payload["tool_call"] as? [String: Any]
        ].compactMap { $0 }

        for candidate in candidatePayloads {
            if let toolName = firstNonEmptyString(
                candidate["tool"] as? String,
                candidate["name"] as? String,
                candidate["toolName"] as? String,
                candidate["tool_name"] as? String
            ) {
                return toolName
            }
        }

        return nil
    }

    private func dynamicToolArguments(from payload: [String: Any]) -> Any {
        if let arguments = payload["arguments"] {
            return arguments
        }
        if let item = payload["item"] as? [String: Any],
           let arguments = item["arguments"] {
            return arguments
        }
        if let toolCall = payload["toolCall"] as? [String: Any],
           let arguments = toolCall["arguments"] {
            return arguments
        }
        if let toolCall = payload["tool_call"] as? [String: Any],
           let arguments = toolCall["arguments"] {
            return arguments
        }
        return [String: Any]()
    }

    private func threadStartParams(cwd: String?, modelID: String?) async -> [String: Any] {
        var params: [String: Any] = [
            "approvalPolicy": threadApprovalPolicy(for: interactionMode),
            "sandbox": threadSandboxMode(for: interactionMode),
            "personality": "friendly",
            "serviceName": "Open Assist",
            "ephemeral": false
        ]
        params["dynamicTools"] = dynamicToolSpecs(for: interactionMode)
        params["cwd"] = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        if let modelID = modelID?.nonEmpty {
            params["model"] = modelID
        }
        if let tier = serviceTier?.nonEmpty {
            params["serviceTier"] = tier
        }
        let instructions = await buildInstructions()
        if !instructions.isEmpty {
            params["instructions"] = instructions
        }

        // Include collaborationMode at thread start so the server knows the
        // base behavior for this thread. Turn-level overrides can still switch
        // a specific prompt into plan mode when needed.
        if let modeSettings = collaborationModeSettings(parentModelID: modelID) {
            params["collaborationMode"] = [
                "mode": interactionMode.codexModeKind,
                "settings": modeSettings
            ] as [String: Any]
        }

        return params
    }

    private func buildInstructions() async -> String {
        var sections: [String] = []

        switch interactionMode {
        case .conversational:
            sections.append("""
            # Chat Mode

            You are in Chat mode. Reply with normal helpful text.
            Do NOT propose or output a structured plan, checklist, outline, or step-by-step implementation plan in this mode.
            You may inspect the workspace, search the web, and run safe read-only commands when needed to answer accurately.
            If the user attaches images and the selected model supports image input, read those attached images directly and answer from them.
            Do NOT edit files, run validation checks like builds or tests, use browser or app automation, or use unsafe commands.
            If the task requires changes or higher-risk execution, explain that Chat mode can inspect and search but cannot make changes, and tell the user to switch to Agentic mode.
            """)
        case .plan:
            sections.append("""
            # Plan Mode

            You are in Plan mode. Produce a clear plan only.
            Use the Codex app server's native plan behavior.
            You may inspect the workspace, search the web, and use tools when needed to ground the plan.
            If the user attaches images and the selected model supports image input, read those attached images directly when they help the plan.
            Do NOT claim to have already executed the work.
            Do NOT take action or present tool results as if the work is done.
            Keep the output focused on the proposed plan so the user can review it before execution.
            """)
        case .agentic:
            let snapshot = await livePermissionSnapshot()
            sections.append(ToolPermissionRegistry.instructionBlock(snapshot: snapshot))
        }

        if let custom = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            sections.append("# Custom Instructions\n\n\(custom)")
        }
        if let skillInstructions = activeSkillInstructionsBlock() {
            sections.append(skillInstructions)
        }
        if let browserInstructions = browserTurnReminder() {
            sections.append(browserInstructions)
        }
        return sections.joined(separator: "\n\n")
    }

    private func activeSkillInstructionsBlock() -> String? {
        let resolvedSkills = activeSkills
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

        guard !resolvedSkills.isEmpty else { return nil }

        let lines = resolvedSkills.map { skill in
            let summary = skill.summaryText
                .replacingOccurrences(
                    of: #"\s+"#,
                    with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            - `\(skill.name)`: \(summary)
              Skill file: `\(skill.skillFilePath)`
            """
        }

        return """
        # Active Skills

        These skills are attached to the current thread. Use them when they fit the user's request, and read the local `SKILL.md` file before using a skill in depth.

        \(lines.joined(separator: "\n"))
        """
    }

    func browserTurnReminder() -> String? {
        Self.browserTurnReminder(
            from: browserProfileContext,
            computerUseEnabled: SettingsStore.shared.assistantComputerUseEnabled
        )
    }

    static func browserTurnReminder(
        from context: [String: String]?,
        computerUseEnabled: Bool
    ) -> String? {
        guard let ctx = context,
              let browser = ctx["browser"],
              let channel = ctx["channel"],
              let profileDir = ctx["profileDir"],
              let userDataDir = ctx["userDataDir"] else {
            return nil
        }

        let profilePath = "\(userDataDir)/\(profileDir)"
        let appName = channel == "brave" ? "Brave Browser" : "Google Chrome"

        return """
        # Browser Task Override

        If you use a browser in this turn, you MUST use the user's configured browser profile.
        - Browser: \(browser)
        - Profile: \(ctx["profileName"] ?? "Default")
        - Profile path: \(profilePath)

        Do NOT use MCP browser tools like `browser_navigate`, `browser_click`, `browser_snapshot`, or `browser_run_code`. Those tools open a separate browser without the user's signed-in session.

        Keep the work in the same signed-in browser session. Use `browser_use` first for opening sites, activating the browser, reading the current tab, and detecting when a manual login is needed. Use `osascript` against "\(appName)" only for simple reads or navigation that stay in the same browser window.

        \(computerUseEnabled
            ? "Use `computer_use` only as a last resort when the task truly depends on visible pixels in the already-open browser window and cannot be completed with `browser_use` or simple browser scripting in that same session."
            : "If the task truly needs pixel-based clicking, dragging, scrolling, or typing in the visible browser window, explain that Computer Use is currently turned off in settings instead of trying to open a separate browser context.")

        If a site asks the user to sign in, pause and ask the user to log in manually in the browser. Continue only after they press Proceed.
        Do not use `computer_use` to type passwords, OTPs, API keys, or other secrets.
        If the browser is already open, keep using that same browser window and do not open a second browser context.
        """
    }

    /// Builds a live permission snapshot by querying `PermissionCenter` and `SettingsStore`.
    private func livePermissionSnapshot() async -> ToolPermissionRegistry.PermissionSnapshot {
        await MainActor.run {
            ToolPermissionRegistry.snapshot(using: .shared)
        }
    }

    /// Pre-flight permission check for a dynamic tool call.
    private func preflightPermissionCheck(toolName: String, arguments: Any) async -> ToolPermissionVerdict {
        let snapshot = await livePermissionSnapshot()
        return ToolPermissionRegistry.verify(toolName: toolName, arguments: arguments, snapshot: snapshot)
    }

    private func threadResumeParams(threadID: String, cwd: String?, modelID: String?) async -> [String: Any] {
        var params = await threadStartParams(cwd: cwd, modelID: modelID)
        params["threadId"] = threadID
        return params
    }

    private func turnStartParams(
        threadID: String,
        prompt: String,
        attachments: [AssistantAttachment] = [],
        modelID: String?,
        resumeContext: String? = nil,
        memoryContext: String? = nil
    ) -> [String: Any] {
        var inputItems: [[String: Any]] = []
        // Add attachment items first so the model sees them before the prompt text
        for attachment in attachments {
            inputItems.append(attachment.toInputItem())
        }
        if let resumeContext = resumeContext?.trimmingCharacters(in: .whitespacesAndNewlines), !resumeContext.isEmpty {
            inputItems.append(["type": "text", "text": resumeContext])
        }
        if let memoryContext = memoryContext?.trimmingCharacters(in: .whitespacesAndNewlines), !memoryContext.isEmpty {
            inputItems.append(["type": "text", "text": memoryContext])
        }
        if !prompt.isEmpty {
            inputItems.append(["type": "text", "text": prompt])
        }
        if attachments.contains(where: \.isImage) {
            inputItems.append([
                "type": "text",
                "text": "If image attachments are present, analyze those attached images directly. Do not use tools or browser/app automation just to inspect attached images."
            ])
        }
        var params: [String: Any] = [
            "threadId": threadID,
            "input": inputItems,
            "approvalPolicy": turnApprovalPolicy(for: interactionMode)
        ]
        if let sandboxPolicy = turnSandboxPolicy(for: interactionMode) {
            params["sandboxPolicy"] = sandboxPolicy
        }
        if let modelID = modelID?.nonEmpty {
            params["model"] = modelID
        }
        if let effort = reasoningEffort?.nonEmpty {
            params["effort"] = effort
        }

        // Build collaborationMode for the turn (only when a model is known).
        // The Codex protocol requires `model` as a non-optional field in settings,
        // so we skip collaborationMode entirely when no model has been selected.
        if let modeSettings = collaborationModeSettings(parentModelID: modelID) {
            params["collaborationMode"] = [
                "mode": interactionMode.codexModeKind,
                "settings": modeSettings
            ] as [String: Any]
        }

        return params
    }

    private func collaborationModeSettings(parentModelID: String?) -> [String: Any]? {
        let effectiveParentModel = (parentModelID?.nonEmpty ?? preferredModelID)?.nonEmpty
        let collaborationModel = preferredSubagentModelID?.nonEmpty ?? effectiveParentModel
        guard let collaborationModel else { return nil }

        var settings: [String: Any] = ["model": collaborationModel]

        // When subagents use the same model as the parent, we can safely keep
        // the parent's reasoning effort. If the user picks a different
        // subagent model, let Codex choose that model's default effort.
        if preferredSubagentModelID?.nonEmpty == nil || collaborationModel == effectiveParentModel,
           let effort = reasoningEffort?.nonEmpty {
            settings["reasoningEffort"] = effort
        }

        return settings
    }

    private func makeHealth(
        availability: AssistantRuntimeAvailability,
        summary: String,
        detail: String? = nil
    ) -> AssistantRuntimeHealth {
        AssistantRuntimeHealth(
            availability: availability,
            summary: summary,
            detail: detail,
            runtimePath: currentCodexPath,
            selectedModelID: preferredModelID,
            accountEmail: currentAccountSnapshot.email,
            accountPlan: currentAccountSnapshot.planType
        )
    }

    private func updateHUD(phase: AssistantHUDPhase, title: String, detail: String?) {
        let state = AssistantHUDState(phase: phase, title: title, detail: detail)
        let now = CFAbsoluteTimeGetCurrent()

        // Always emit immediately for phase changes; throttle detail-only updates to ~10Hz
        let isPhaseChange = phase != lastHUDPhase
        if isPhaseChange || now - lastHUDEmitTime >= 0.10 {
            hudThrottleItem?.cancel()
            hudThrottleItem = nil
            pendingHUDState = nil
            onHUDUpdate?(state)
            lastHUDEmitTime = now
            lastHUDPhase = phase
        } else {
            pendingHUDState = state
            if hudThrottleItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self, let pending = self.pendingHUDState else { return }
                    self.onHUDUpdate?(pending)
                    self.lastHUDEmitTime = CFAbsoluteTimeGetCurrent()
                    self.pendingHUDState = nil
                    self.hudThrottleItem = nil
                }
                hudThrottleItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: item)
            }
        }
    }

    private func compactDetail(_ text: String?) -> String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// Detects osascript or AppleScript commands that target privacy-protected macOS apps.
    /// Returns the display name of the blocked app, or nil if the command is safe.
    static func detectPrivacyBlockedOsascript(in command: String) -> String? {
        let normalized = command.lowercased()
        // Only check commands that involve AppleScript/osascript
        guard normalized.contains("osascript") || normalized.contains("applescript")
                || normalized.contains("tell application") else {
            return nil
        }
        // Reminders, Contacts, Notes, and Messages are no longer blocked —
        // they use native framework access via app_action. But osascript against
        // them should still be blocked since the native path is preferred.
        let blockedApps: [(keyword: String, displayName: String)] = [
            ("reminders", "Reminders"),
            ("contacts", "Contacts"),
            ("mail", "Mail"),
            ("messages", "Messages"),
            ("photos", "Photos"),
            ("notes", "Notes"),
            ("safari", "Safari"),
            ("music", "Music"),
            ("podcasts", "Podcasts"),
            ("home", "Home"),
            ("health", "Health"),
        ]
        for entry in blockedApps {
            // Match "tell application \"Reminders\"" or just "Reminders" in an osascript context
            if normalized.contains("\"" + entry.keyword + "\"")
                || normalized.contains("'\(entry.keyword)'")
                || normalized.contains("application \"\(entry.keyword)\"")
                || normalized.contains("application \\\"\(entry.keyword)\\\"") {
                return entry.displayName
            }
        }
        return nil
    }

    /// Produces a short, human-readable summary of a raw shell command for the HUD.
    private func friendlyCommandSummary(_ raw: String) -> String {
        var cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip common shell wrappers:  /bin/zsh -lc '...'  /bin/bash -c '...'
        let shellPattern = #"^(/\S+/)?(bash|zsh|sh)\s+(-\S+\s+)*['\"]?"#
        if let range = cmd.range(of: shellPattern, options: .regularExpression) {
            cmd = String(cmd[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip trailing quotes / heredoc markers
        if cmd.hasSuffix("'") || cmd.hasSuffix("\"") {
            cmd = String(cmd.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let heredoc = cmd.range(of: #"<<\s*'?EOF'?"#, options: .regularExpression) {
            cmd = String(cmd[..<heredoc.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract the first meaningful token (the actual command)
        let firstLine = cmd.components(separatedBy: .newlines).first ?? cmd
        let tokens = firstLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let base = tokens.first ?? cmd
        let baseName = (base as NSString).lastPathComponent
        let sub = tokens.count > 1 ? tokens[1] : nil

        // Subcommand-specific descriptions for multi-verb CLIs
        let subcommandDescriptions: [String: [String: String]] = [
            "git": [
                "status": "Checking repo status", "diff": "Reviewing changes",
                "add": "Staging changes", "commit": "Committing changes",
                "push": "Pushing to remote", "pull": "Pulling latest",
                "clone": "Cloning repository", "checkout": "Switching branch",
                "switch": "Switching branch", "branch": "Managing branches",
                "log": "Viewing history", "stash": "Stashing changes",
                "merge": "Merging branches", "rebase": "Rebasing",
                "fetch": "Fetching remote", "reset": "Resetting changes",
                "tag": "Managing tags", "init": "Initializing repository",
                "remote": "Managing remotes", "cherry-pick": "Cherry-picking",
                "restore": "Restoring files", "clean": "Cleaning repo",
            ],
            "npm": [
                "install": "Installing dependencies", "i": "Installing dependencies",
                "ci": "Installing dependencies", "test": "Running tests",
                "t": "Running tests", "start": "Starting application",
                "build": "Building project", "publish": "Publishing package",
                "init": "Initializing project", "uninstall": "Removing package",
                "update": "Updating dependencies", "audit": "Auditing dependencies",
                "link": "Linking package", "pack": "Packing module",
            ],
            "yarn": [
                "install": "Installing dependencies", "add": "Installing dependencies",
                "test": "Running tests", "build": "Building project",
                "start": "Starting application", "remove": "Removing package",
            ],
            "pnpm": [
                "install": "Installing dependencies", "i": "Installing dependencies",
                "add": "Installing dependencies", "test": "Running tests",
                "build": "Building project", "start": "Starting application",
                "remove": "Removing package",
            ],
            "bun": [
                "install": "Installing dependencies", "i": "Installing dependencies",
                "add": "Installing dependencies", "test": "Running tests",
                "build": "Building project", "run": "Running script",
                "remove": "Removing package",
            ],
            "swift": [
                "build": "Building project", "test": "Running tests",
                "run": "Running application", "package": "Managing package",
            ],
            "cargo": [
                "build": "Building project", "test": "Running tests",
                "run": "Running application", "check": "Checking code",
                "clippy": "Linting code", "fmt": "Formatting code",
                "doc": "Building docs", "publish": "Publishing crate",
                "install": "Installing crate", "update": "Updating dependencies",
                "bench": "Running benchmarks", "clean": "Cleaning build",
            ],
            "go": [
                "build": "Building project", "test": "Running tests",
                "run": "Running application", "mod": "Managing modules",
                "fmt": "Formatting code", "vet": "Checking code",
                "get": "Installing dependencies", "install": "Installing package",
                "generate": "Generating code",
            ],
            "docker": [
                "build": "Building image", "run": "Running container",
                "compose": "Managing services", "push": "Pushing image",
                "pull": "Pulling image", "stop": "Stopping container",
                "exec": "Running in container",
            ],
            "kubectl": [
                "apply": "Applying config", "get": "Fetching resources",
                "describe": "Inspecting resource", "delete": "Deleting resource",
                "logs": "Viewing logs", "exec": "Running in pod",
            ],
            "brew": [
                "install": "Installing package", "uninstall": "Removing package",
                "update": "Updating Homebrew", "upgrade": "Upgrading packages",
                "search": "Searching packages", "info": "Package info",
            ],
        ]

        // Check for subcommand-specific descriptions first
        if let sub, let subMap = subcommandDescriptions[baseName], let desc = subMap[sub] {
            return desc
        }

        // Handle "npm/yarn/pnpm run <script>" — look up the script name
        let runScriptDescriptions: [String: String] = [
            "test": "Running tests", "build": "Building project",
            "start": "Starting application", "dev": "Starting dev server",
            "lint": "Linting code", "format": "Formatting code",
            "serve": "Starting server", "watch": "Watching for changes",
            "clean": "Cleaning build", "deploy": "Deploying",
            "typecheck": "Type-checking", "check": "Checking code",
            "preview": "Previewing",
        ]
        let npmLike: Set<String> = ["npm", "yarn", "pnpm", "bun", "npx"]
        if npmLike.contains(baseName), sub == "run", tokens.count > 2 {
            if let desc = runScriptDescriptions[tokens[2]] {
                return desc
            }
            return "Running \(tokens[2])"
        }

        // Semantic labels for single commands (no subcommand needed)
        let labels: [String: String] = [
            "node": "Executing script",
            "python": "Executing script", "python3": "Executing script",
            "pip": "Installing packages", "pip3": "Installing packages",
            "swiftc": "Compiling Swift",
            "xcodebuild": "Building with Xcode", "xcrun": "Running Xcode tool",
            "rustc": "Compiling Rust",
            "make": "Building", "cmake": "Configuring build",
            "curl": "Downloading", "wget": "Downloading",
            "cat": "Reading file", "less": "Reading file", "more": "Reading file",
            "ls": "Listing directory", "tree": "Listing directory",
            "find": "Searching filesystem",
            "grep": "Searching code", "rg": "Searching code", "ag": "Searching code",
            "sed": "Editing text", "awk": "Processing text",
            "mkdir": "Creating directory",
            "rm": "Removing files", "rmdir": "Removing directory",
            "cp": "Copying files", "mv": "Moving files",
            "chmod": "Changing permissions", "chown": "Changing ownership",
            "apt": "Installing packages", "apt-get": "Installing packages",
            "cd": "Changing directory",
            "echo": "Running shell", "env": "Running command",
            "which": "Locating command", "where": "Locating command",
            "ruby": "Executing script", "gem": "Managing gems",
            "java": "Running Java", "javac": "Compiling Java",
            "gradle": "Building project", "mvn": "Building project",
            "pytest": "Running tests", "jest": "Running tests",
            "vitest": "Running tests", "mocha": "Running tests",
            "tsc": "Type-checking", "eslint": "Linting code",
            "prettier": "Formatting code", "black": "Formatting code",
            "flake8": "Linting code", "mypy": "Type-checking",
            "tar": "Archiving files", "zip": "Compressing files",
            "unzip": "Extracting files",
        ]

        if let label = labels[baseName] {
            return label
        }

        // Fallback: show the base command name (without path)
        if baseName.count <= 24 {
            return "Running \(baseName)"
        }
        return "Running command"
    }

    private func approvalRequestID(from id: JSONRPCRequestID) -> Int {
        switch id {
        case .int(let value):
            return value
        case .string(let value):
            return abs(value.hashValue)
        }
    }

    private func firstNonEmptyString(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func parseTranscriptionAuthContext(from raw: Any) throws -> CodexTranscriptionAuthContext {
        let dictionaries = transcriptionAuthCandidateDictionaries(from: raw)
        guard !dictionaries.isEmpty else {
            throw CodexAssistantRuntimeError.invalidResponse("Codex returned an empty transcription auth response.")
        }

        if let message = dictionaries.compactMap({ dictionary in
            firstNonEmptyString(
                dictionary["error"] as? String,
                dictionary["message"] as? String,
                (dictionary["detail"] as? [String: Any]).flatMap { $0["message"] as? String },
                (dictionary["details"] as? [String: Any]).flatMap { $0["message"] as? String }
            )
        }).first {
            throw CodexAssistantRuntimeError.requestFailed(message)
        }

        let token = dictionaries.compactMap { dictionary in
            firstNonEmptyString(
                dictionary["token"] as? String,
                dictionary["accessToken"] as? String,
                dictionary["access_token"] as? String,
                dictionary["apiKey"] as? String,
                dictionary["api_key"] as? String,
                dictionary["authToken"] as? String
            )
        }.first

        guard let token else {
            throw CodexAssistantRuntimeError.invalidResponse(
                "Codex did not return a reusable transcription token."
            )
        }

        let authMode = resolvedTranscriptionAuthMode(from: dictionaries)
        guard authMode != .none else {
            throw CodexAssistantRuntimeError.invalidResponse(
                "Codex did not indicate whether transcription auth is ChatGPT or API key based."
            )
        }

        return CodexTranscriptionAuthContext(authMode: authMode, token: token)
    }

    private func transcriptionAuthCandidateDictionaries(from raw: Any) -> [[String: Any]] {
        guard let root = raw as? [String: Any] else {
            return []
        }

        var dictionaries: [[String: Any]] = [root]
        let nestedKeys = ["result", "status", "auth", "data", "credentials", "tokens", "account"]
        var index = 0
        while index < dictionaries.count {
            let dictionary = dictionaries[index]
            for key in nestedKeys {
                if let nested = dictionary[key] as? [String: Any],
                   dictionaries.contains(where: { NSDictionary(dictionary: $0).isEqual(to: nested) }) == false {
                    dictionaries.append(nested)
                }
            }
            index += 1
        }
        return dictionaries
    }

    private func resolvedTranscriptionAuthMode(from dictionaries: [[String: Any]]) -> AssistantAccountAuthMode {
        let explicitMode = dictionaries.compactMap { dictionary in
            firstNonEmptyString(
                dictionary["authMode"] as? String,
                dictionary["authMethod"] as? String,
                dictionary["method"] as? String,
                dictionary["type"] as? String,
                dictionary["provider"] as? String
            )
        }
        .compactMap(assistantAccountAuthMode(from:))
        .first

        if let explicitMode {
            return explicitMode
        }

        return currentAccountSnapshot.authMode
    }

    private func assistantAccountAuthMode(from rawValue: String) -> AssistantAccountAuthMode? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("chatgpt") || normalized.contains("chat_gpt") || normalized.contains("session") {
            return .chatGPT
        }
        if normalized.contains("api") || normalized.contains("key") {
            return .apiKey
        }
        if normalized == "none" || normalized == "signedout" || normalized == "signed_out" {
            return AssistantAccountAuthMode.none
        }
        return nil
    }

    private func transientReconnectStatusMessage(from message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let range = trimmed.range(
            of: #"(?i)^reconnecting\.\.\.\s+\d+/\d+$"#,
            options: .regularExpression
        ) else {
            return nil
        }
        guard range.lowerBound == trimmed.startIndex, range.upperBound == trimmed.endIndex else {
            return nil
        }
        return trimmed
    }

    private func extractString(_ raw: Any?) -> String? {
        if let text = raw as? String {
            return text.nonEmpty
        }
        if let dictionary = raw as? [String: Any] {
            for key in ["message", "text", "content", "output", "description", "prompt", "task", "instructions", "query"] {
                if let text = extractString(dictionary[key]) {
                    return text
                }
            }
        }
        if let array = raw as? [Any] {
            let merged = array.compactMap { extractString($0) }.joined(separator: "\n")
            return merged.nonEmpty
        }
        return nil
    }

    private func resolvedCopilotWorkingDirectory(_ cwd: String?) -> String {
        if let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory), isDirectory.boolValue {
                return trimmed
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func signedInCopilotAccountSnapshot() -> AssistantAccountSnapshot {
        AssistantAccountSnapshot(
            authMode: .chatGPT,
            email: "GitHub Copilot",
            planType: nil,
            requiresOpenAIAuth: false,
            loginInProgress: false,
            pendingLoginURL: nil,
            pendingLoginID: nil
        )
    }

    private func refreshCopilotEnvironment(cwd: String?) async throws -> AssistantEnvironmentDetails {
        let resolvedCWD = resolvedCopilotWorkingDirectory(cwd)
        try await ensureTransport(cwd: resolvedCWD)
        currentAccountSnapshot = signedInCopilotAccountSnapshot()
        onAccountUpdate?(currentAccountSnapshot)

        if currentModels.isEmpty {
            _ = try await startCopilotSession(
                cwd: resolvedCWD,
                preferredModelID: preferredModelID,
                announce: false
            )
        } else if let activeSessionID {
            try await refreshCopilotCurrentSessionConfiguration(
                sessionID: activeSessionID,
                cwd: activeSessionCWD ?? resolvedCWD,
                preferredModelID: preferredModelID
            )
        }

        await refreshRateLimits()

        let health = connectedHealthForCurrentState()
        onHealthUpdate?(health)
        return AssistantEnvironmentDetails(
            health: health,
            account: currentAccountSnapshot,
            models: currentModels
        )
    }

    private func startCopilotSession(
        cwd: String?,
        preferredModelID: String?,
        announce: Bool
    ) async throws -> String {
        let resolvedCWD = resolvedCopilotWorkingDirectory(cwd)

        if announce,
           let bootstrapSessionID,
           bootstrapSessionID == activeSessionID,
           activeSessionCWD == resolvedCWD {
            self.bootstrapSessionID = nil
            try await refreshCopilotCurrentSessionConfiguration(
                sessionID: bootstrapSessionID,
                cwd: resolvedCWD,
                preferredModelID: preferredModelID
            )
            onSessionChange?(bootstrapSessionID)
            onTranscript?(AssistantTranscriptEntry(role: .system, text: backend.startedSessionMessage, emphasis: true))
            updateHUD(phase: .idle, title: "Assistant is ready", detail: nil)
            return bootstrapSessionID
        }

        if announce {
            toolCalls.removeAll()
            liveActivities.removeAll()
            clearSubagents(publish: false)
            repeatedCommandTracker.reset()
            resetStreamingTimelineState()
            onToolCallUpdate?([])
            onPlanUpdate?([])
            onSubagentUpdate?([])
            onTimelineMutation?(.reset(sessionID: nil))
            onPermissionRequest?(nil)
            sessionTurnCount = 0
            firstTurnUserPrompt = nil
        }

        try await ensureTransport(cwd: resolvedCWD)
        let response = try await sendRequest(
            method: "session/new",
            params: [
                "cwd": resolvedCWD,
                "mcpServers": []
            ]
        )

        guard let payload = response.raw as? [String: Any],
              let sessionID = payload["sessionId"] as? String else {
            throw CodexAssistantRuntimeError.invalidResponse("GitHub Copilot did not return a session id.")
        }

        activeSessionID = sessionID
        activeSessionCWD = resolvedCWD
        transportSessionID = sessionID
        currentAccountSnapshot = signedInCopilotAccountSnapshot()
        onAccountUpdate?(currentAccountSnapshot)
        applyCopilotConfiguration(from: payload)
        try await applyCopilotSessionConfiguration(
            sessionID: sessionID,
            preferredModelID: preferredModelID
        )

        if announce {
            bootstrapSessionID = nil
            onSessionChange?(sessionID)
            onTranscript?(AssistantTranscriptEntry(role: .system, text: backend.startedSessionMessage, emphasis: true))
        } else {
            bootstrapSessionID = sessionID
        }

        onHealthUpdate?(makeHealth(availability: .ready, summary: backend.connectedSummary))
        updateHUD(phase: .idle, title: "Assistant is ready", detail: nil)
        return sessionID
    }

    private func resumeCopilotSession(
        _ sessionID: String,
        cwd: String?,
        preferredModelID: String?,
        announce: Bool
    ) async throws {
        let resolvedCWD = resolvedCopilotWorkingDirectory(cwd)
        try await ensureTransport(cwd: resolvedCWD)

        if transportSessionID != sessionID {
            do {
                let response = try await sendRequest(
                    method: "session/load",
                    params: [
                        "sessionId": sessionID,
                        "cwd": resolvedCWD,
                        "mcpServers": []
                    ]
                )
                applyCopilotConfiguration(from: response.raw)
            } catch {
                let message = error.localizedDescription.lowercased()
                guard !message.contains("already loaded") else {
                    // The session is already active in the ACP process.
                    activeSessionID = sessionID
                    activeSessionCWD = resolvedCWD
                    transportSessionID = sessionID
                    bootstrapSessionID = bootstrapSessionID == sessionID ? nil : bootstrapSessionID
                    try await applyCopilotSessionConfiguration(
                        sessionID: sessionID,
                        preferredModelID: preferredModelID
                    )
                    onSessionChange?(sessionID)
                    if announce {
                        onTranscript?(AssistantTranscriptEntry(role: .system, text: backend.loadedSessionMessage(sessionID), emphasis: true))
                    }
                    onHealthUpdate?(makeHealth(availability: .ready, summary: backend.connectedSummary))
                    updateHUD(phase: .idle, title: "Session ready", detail: nil)
                    return
                }
                throw error
            }
        }

        activeSessionID = sessionID
        activeSessionCWD = resolvedCWD
        transportSessionID = sessionID
        bootstrapSessionID = bootstrapSessionID == sessionID ? nil : bootstrapSessionID
        currentAccountSnapshot = signedInCopilotAccountSnapshot()
        onAccountUpdate?(currentAccountSnapshot)
        try await applyCopilotSessionConfiguration(
            sessionID: sessionID,
            preferredModelID: preferredModelID
        )
        sessionTurnCount = 1
        onSessionChange?(sessionID)
        if announce {
            onTranscript?(AssistantTranscriptEntry(role: .system, text: backend.loadedSessionMessage(sessionID), emphasis: true))
        }
        onHealthUpdate?(makeHealth(availability: .ready, summary: backend.connectedSummary))
        updateHUD(phase: .idle, title: "Session ready", detail: nil)
    }

    private func refreshCopilotCurrentSessionConfiguration(
        sessionID: String,
        cwd: String?,
        preferredModelID: String?
    ) async throws {
        let resolvedCWD = resolvedCopilotWorkingDirectory(cwd)
        try await ensureTransport(cwd: resolvedCWD)
        if transportSessionID != sessionID {
            do {
                let response = try await sendRequest(
                    method: "session/load",
                    params: [
                        "sessionId": sessionID,
                        "cwd": resolvedCWD,
                        "mcpServers": []
                    ]
                )
                applyCopilotConfiguration(from: response.raw)
            } catch {
                if !error.localizedDescription.lowercased().contains("already loaded") {
                    throw error
                }
            }
            transportSessionID = sessionID
        }

        activeSessionID = sessionID
        activeSessionCWD = resolvedCWD
        currentAccountSnapshot = signedInCopilotAccountSnapshot()
        onAccountUpdate?(currentAccountSnapshot)
        try await applyCopilotSessionConfiguration(
            sessionID: sessionID,
            preferredModelID: preferredModelID
        )
        onHealthUpdate?(makeHealth(
            availability: activeTurnID == nil ? .ready : .active,
            summary: activeTurnID == nil ? backend.connectedSummary : backend.activeSummary
        ))
    }

    private func applyCopilotSessionConfiguration(
        sessionID: String,
        preferredModelID: String?
    ) async throws {
        _ = try await sendRequest(
            method: "session/set_mode",
            params: [
                "sessionId": sessionID,
                "modeId": copilotModeID(for: interactionMode)
            ]
        )

        if let requestedModelID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
           currentCopilotModelID() != requestedModelID {
            let response = try await sendRequest(
                method: "session/set_config_option",
                params: [
                    "sessionId": sessionID,
                    "configId": "model",
                    "value": requestedModelID
                ]
            )
            applyCopilotConfiguration(from: response.raw)
        }

        if let reasoningEffort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            do {
                let response = try await sendRequest(
                    method: "session/set_config_option",
                    params: [
                        "sessionId": sessionID,
                        "configId": "reasoning_effort",
                        "value": reasoningEffort
                    ]
                )
                applyCopilotConfiguration(from: response.raw)
            } catch {
                guard isCopilotUnsupportedReasoningError(error) else { throw error }
            }
        }
    }

    private func sendCopilotPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AssistantAttachment],
        preferredModelID: String?,
        resumeContext: String?,
        memoryContext: String?
    ) async throws {
        guard attachments.isEmpty else {
            throw CodexAssistantRuntimeError.runtimeUnavailable(
                "Attachments are not wired through GitHub Copilot ACP in Open Assist yet."
            )
        }

        let resolvedCWD = resolvedCopilotWorkingDirectory(activeSessionCWD)
        try await refreshCopilotCurrentSessionConfiguration(
            sessionID: sessionID,
            cwd: resolvedCWD,
            preferredModelID: preferredModelID
        )

        if bootstrapSessionID == sessionID {
            bootstrapSessionID = nil
        }

        turnToolCallCount = 0
        repeatedCommandTracker.reset()
        activeTurnID = activeTurnID ?? "copilot-turn-\(UUID().uuidString)"
        updateHUD(phase: .streaming, title: "Starting", detail: nil)
        onHealthUpdate?(makeHealth(availability: .active, summary: backend.activeSummary))

        do {
            let response = try await sendRequest(
                method: "session/prompt",
                params: [
                    "sessionId": sessionID,
                    "prompt": buildCopilotPromptContent(
                        prompt: prompt,
                        resumeContext: resumeContext,
                        memoryContext: memoryContext
                    )
                ]
            )
            guard activeTurnID != nil else { return }
            handleCopilotPromptCompletion(from: response.raw)
        } catch {
            guard activeTurnID != nil else { throw error }
            handleTurnCompleted([
                "turn": [
                    "status": "failed",
                    "error": ["message": error.localizedDescription]
                ]
            ])
            throw error
        }
    }

    private func buildCopilotPromptContent(
        prompt: String,
        resumeContext: String?,
        memoryContext: String?
    ) -> [[String: Any]] {
        let combined = [resumeContext, memoryContext, prompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            .joined(separator: "\n\n")
        return [["type": "text", "text": combined]]
    }

    private func handleCopilotPromptCompletion(from raw: Any) {
        let stopReason = ((raw as? [String: Any])?["stopReason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch stopReason {
        case "cancelled", "canceled", "interrupted":
            handleTurnCompleted(["turn": ["status": "interrupted"]])
        default:
            handleTurnCompleted(["turn": ["status": "completed"]])
        }

        Task { await refreshRateLimits() }
    }

    private func listCopilotSessions(limit: Int) async throws -> [AssistantSessionSummary] {
        try await ensureTransport(cwd: currentTransportWorkingDirectory ?? activeSessionCWD)
        let response = try await sendRequest(method: "session/list", params: [:])
        return Self.parseCopilotSessions(
            from: response.raw,
            limit: limit,
            excluding: bootstrapSessionID
        )
    }

    private static func parseCopilotSessions(
        from raw: Any,
        limit: Int,
        excluding excludedSessionID: String?
    ) -> [AssistantSessionSummary] {
        guard let payload = raw as? [String: Any] else { return [] }
        let rows = payload["sessions"] as? [[String: Any]] ?? []
        func firstResolvedString(_ candidates: String?...) -> String? {
            for candidate in candidates {
                if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    return value
                }
            }
            return nil
        }
        let sessions = rows.compactMap { row -> AssistantSessionSummary? in
            guard let sessionID = row["sessionId"] as? String,
                  sessionID != excludedSessionID else {
                return nil
            }
            let cwd = firstResolvedString(row["cwd"] as? String)
            let title = firstResolvedString(row["title"] as? String, cwd, "Copilot Session") ?? "Copilot Session"
            return AssistantSessionSummary(
                id: sessionID,
                title: title,
                source: .cli,
                status: .idle,
                cwd: cwd,
                effectiveCWD: cwd,
                updatedAt: parseCopilotDate(row["updatedAt"] as? String)
            )
        }
        return Array(sessions.prefix(limit))
    }

    private static func parseCopilotDate(_ rawValue: String?) -> Date? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: rawValue) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }

    private func applyCopilotConfiguration(from raw: Any) {
        currentAccountSnapshot = signedInCopilotAccountSnapshot()
        onAccountUpdate?(currentAccountSnapshot)
        let models = parseCopilotModels(from: raw)
        guard !models.isEmpty else { return }
        currentModels = models
        onModelsUpdate?(models)
    }

    private func parseCopilotModels(from raw: Any) -> [AssistantModelOption] {
        guard let payload = raw as? [String: Any] else { return currentModels }

        let configOptions = (payload["configOptions"] as? [[String: Any]]) ?? []
        let modelConfig = configOptions.first(where: { ($0["id"] as? String) == "model" })
        let reasoningConfig = configOptions.first(where: { ($0["id"] as? String) == "reasoning_effort" })

        let currentModelID = firstNonEmptyString(
            ((payload["models"] as? [String: Any])?["currentModelId"] as? String),
            modelConfig?["currentValue"] as? String
        )

        let rows: [[String: Any]]
        if let availableRows = (payload["models"] as? [String: Any])?["availableModels"] as? [[String: Any]] {
            rows = availableRows
        } else {
            rows = modelConfig?["options"] as? [[String: Any]] ?? []
        }

        guard !rows.isEmpty else { return currentModels }

        let supportedEfforts = (reasoningConfig?["options"] as? [[String: Any]] ?? [])
            .compactMap { $0["value"] as? String }
        let currentReasoningEffort = reasoningConfig?["currentValue"] as? String

        return rows.compactMap { row in
            guard let id = firstNonEmptyString(
                row["modelId"] as? String,
                row["value"] as? String
            ) else {
                return nil
            }

            let displayName = firstNonEmptyString(
                row["name"] as? String,
                row["displayName"] as? String,
                id
            ) ?? id
            let description = firstNonEmptyString(
                row["description"] as? String,
                displayName,
                id
            ) ?? id

            let reasoningEfforts = id.lowercased().hasPrefix("gpt-") ? supportedEfforts : []
            let defaultReasoningEffort = reasoningEfforts.isEmpty ? nil : currentReasoningEffort

            return AssistantModelOption(
                id: id,
                displayName: displayName,
                description: description,
                isDefault: id == currentModelID,
                hidden: false,
                supportedReasoningEfforts: reasoningEfforts,
                defaultReasoningEffort: defaultReasoningEffort,
                inputModalities: []
            )
        }
    }

    private func currentCopilotModelID() -> String? {
        currentModels.first(where: \.isDefault)?.id
    }

    private func copilotModeID(for interactionMode: AssistantInteractionMode) -> String {
        switch interactionMode {
        case .conversational:
            return "https://agentclientprotocol.com/protocol/session-modes#agent"
        case .plan:
            return "https://agentclientprotocol.com/protocol/session-modes#plan"
        case .agentic:
            return "https://agentclientprotocol.com/protocol/session-modes#autopilot"
        }
    }

    private func isCopilotUnsupportedReasoningError(_ error: Error) -> Bool {
        error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveContains("does not support reasoning_effort configuration")
    }

    private func handleCopilotNotification(method: String, params: [String: Any]) async {
        guard method == "session/update" else { return }
        guard let sessionID = params["sessionId"] as? String else { return }
        if detachedSessionIDs.contains(sessionID) {
            return
        }
        if let currentActive = activeSessionID, sessionID != currentActive {
            return
        }
        handleCopilotSessionUpdate(params)
    }

    private func handleCopilotServerRequest(
        id: JSONRPCRequestID,
        method: String,
        params: [String: Any]
    ) async {
        switch method {
        case "session/request_permission":
            await presentCopilotPermissionRequest(id: id, params: params)
        default:
            onStatusMessage?("GitHub Copilot requested an unsupported action: \(method)")
        }
    }

    private func handleCopilotSessionUpdate(_ params: [String: Any]) {
        guard let update = params["update"] as? [String: Any] else { return }
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            guard let content = update["content"] as? [String: Any],
                  let delta = content["text"] as? String,
                  delta.nonEmpty != nil else {
                return
            }
            guard acceptAssistantMessageDelta(
                threadID: params["sessionId"] as? String,
                turnID: assistantMessageTurnID(from: update),
                source: "session/update.agent_message_chunk"
            ) else {
                return
            }
            pendingCopilotFallbackReply = nil
            ensureStreamingIdentifiers()
            streamingBuffer += delta
            pendingStreamingDeltaBuffer += delta
            emitStreamingAssistantDelta(force: shouldForceStreamingDeltaFlush(for: delta))
            updateHUD(phase: .streaming, title: "Responding", detail: nil)
        case "agent_thought_chunk":
            guard let content = update["content"] as? [String: Any],
                  let delta = content["text"] as? String,
                  delta.nonEmpty != nil else {
                return
            }
            if shouldSurfaceCopilotThought(delta) {
                appendCommentaryDelta(delta)
            }
            updateHUD(phase: .thinking, title: "Reasoning", detail: nil)
        case "tool_call":
            handleCopilotToolCallUpdate(update, isInitial: true)
        case "tool_call_update":
            handleCopilotToolCallUpdate(update, isInitial: false)
        case "config_option_update":
            applyCopilotConfiguration(from: update)
            onHealthUpdate?(connectedHealthForCurrentState())
        default:
            break
        }
    }

    private func handleCopilotToolCallUpdate(_ update: [String: Any], isInitial: Bool) {
        guard let item = copilotSyntheticItem(from: update) else { return }
        let status = (item["status"] as? String)?.lowercased() ?? "running"
        let isCompleted = !["pending", "running", "waiting", "inprogress", "in_progress"].contains(status)
        let toolOutput = copilotOutputText(from: update)

        if shouldHideCopilotToolActivity(item: item) {
            if isCompleted,
               let reply = toolOutput.flatMap(copilotFallbackReplyCandidate(from:)) {
                storeCopilotFallbackReply(reply)
            }
            return
        }

        if !isCompleted,
           let itemID = item["id"] as? String,
           let output = toolOutput,
           output.nonEmpty != nil {
            handleCommandOutputDelta([
                "itemId": itemID,
                "delta": output
            ])
        }

        handleItemStartedOrCompleted(["item": item], isCompleted: isInitial ? false : isCompleted)
    }

    private func copilotSyntheticItem(from update: [String: Any]) -> [String: Any]? {
        guard let itemID = update["toolCallId"] as? String else { return nil }
        let rawInput = update["rawInput"] as? [String: Any] ?? [:]
        let title = firstNonEmptyString(update["title"] as? String, "Tool") ?? "Tool"
        let kind = update["kind"] as? String
        let type = copilotActivityType(kind: kind, rawInput: rawInput, title: title)

        var item: [String: Any] = [
            "id": itemID,
            "type": type,
            "status": copilotToolStatus(update["status"] as? String)
        ]

        switch type {
        case "commandExecution":
            item["command"] = firstNonEmptyString(
                rawInput["command"] as? String,
                (rawInput["commands"] as? [String])?.joined(separator: " && "),
                title
            )
        case "fileChange":
            item["changes"] = rawInput["files"] as? [[String: Any]] ?? []
        case "mcpToolCall":
            item["server"] = "MCP"
            item["tool"] = title
            item["arguments"] = rawInput
        default:
            item["tool"] = title
            item["arguments"] = rawInput
        }

        if let output = copilotOutputText(from: update) {
            item["result"] = output
        }
        return item
    }

    private func copilotOutputText(from update: [String: Any]) -> String? {
        if let rawOutput = update["rawOutput"] as? [String: Any] {
            if let text = firstNonEmptyString(
                rawOutput["detailedContent"] as? String,
                rawOutput["content"] as? String,
                rawOutput["code"] as? String
            ) {
                return text
            }
        }

        let content = update["content"] as? [[String: Any]] ?? []
        let joined = content.compactMap { row -> String? in
            if let contentRow = row["content"] as? [String: Any] {
                return firstNonEmptyString(contentRow["text"] as? String)
            }
            return firstNonEmptyString(row["text"] as? String)
        }
        .joined(separator: "\n")

        return joined.nonEmpty
    }

    private func copilotActivityType(
        kind: String?,
        rawInput: [String: Any],
        title: String?
    ) -> String {
        if rawInput["command"] != nil || rawInput["commands"] != nil || kind == "execute" {
            return "commandExecution"
        }
        if rawInput["files"] != nil || kind == "edit" || title?.localizedCaseInsensitiveContains("edit") == true {
            return "fileChange"
        }
        if kind?.localizedCaseInsensitiveContains("mcp") == true {
            return "mcpToolCall"
        }
        return "other"
    }

    private func copilotToolStatus(_ rawValue: String?) -> String {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending":
            return "pending"
        case "failed":
            return "failed"
        case "completed":
            return "completed"
        default:
            return "running"
        }
    }

    private func shouldHideCopilotToolActivity(item: [String: Any]) -> Bool {
        normalizedActivityType(item["type"] as? String ?? "other") == "other"
    }

    private func shouldSurfaceCopilotThought(_ delta: String) -> Bool {
        delta.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil && backend != .copilot
    }

    private func copilotFallbackReplyCandidate(from rawOutput: String) -> String? {
        let trimmedOutput = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return nil }

        let prefixes = [
            "task completed:",
            "completed:",
            "final answer:",
            "answer:"
        ]

        var candidate = trimmedOutput
        let lowered = trimmedOutput.lowercased()
        for prefix in prefixes {
            if lowered.hasPrefix(prefix) {
                candidate = String(trimmedOutput.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        guard !candidate.isEmpty else { return nil }

        let normalizedCandidateForDiffCheck = candidate
            .replacingOccurrences(of: "```diff", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assistantLooksLikeUnifiedDiff(normalizedCandidateForDiffCheck) else {
            return nil
        }

        let normalizedCandidate = candidate.lowercased()
        let internalNotes = [
            "greeting user",
            "acknowledging the intent",
            "processing the greeting"
        ]
        if internalNotes.contains(normalizedCandidate) {
            return nil
        }

        let hasSentencePunctuation = candidate.contains(".")
            || candidate.contains("!")
            || candidate.contains("?")
        let wordCount = candidate.split(whereSeparator: \.isWhitespace).count
        guard hasSentencePunctuation || wordCount >= 8 else {
            return nil
        }

        return candidate
    }

    private func storeCopilotFallbackReply(_ reply: String) {
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReply.isEmpty else { return }
        if let existing = pendingCopilotFallbackReply?.trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count > trimmedReply.count {
            return
        }
        pendingCopilotFallbackReply = trimmedReply
    }

    private func materializeCopilotFallbackReplyIfNeeded() {
        guard backend == .copilot,
              streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil,
              let fallbackReply = pendingCopilotFallbackReply?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }

        ensureStreamingIdentifiers()
        streamingBuffer = fallbackReply
        pendingStreamingDeltaBuffer = ""
    }

    private func presentCopilotPermissionRequest(
        id: JSONRPCRequestID,
        params: [String: Any]
    ) async {
        guard let toolCall = params["toolCall"] as? [String: Any] else {
            onStatusMessage?("GitHub Copilot requested permission without a tool description.")
            return
        }

        let sessionID = firstNonEmptyString(
            params["sessionId"] as? String,
            activeSessionID
        ) ?? ""
        let toolKind = copilotPermissionToolKind(from: toolCall)
        let options = copilotPermissionOptions(
            from: params["options"] as? [[String: Any]] ?? [],
            toolKind: toolKind
        )
        let request = AssistantPermissionRequest(
            id: approvalRequestID(from: id),
            sessionID: sessionID,
            toolTitle: firstNonEmptyString(toolCall["title"] as? String, "Approval Needed") ?? "Approval Needed",
            toolKind: toolKind,
            rationale: copilotPermissionRationale(from: toolCall),
            options: options,
            rawPayloadSummary: copilotPermissionSummary(from: toolCall)
        )

        pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
            guard let self else { return }
            do {
                try await self.transport?.sendResponse(
                    id: id,
                    result: [
                        "outcome": [
                            "outcome": "selected",
                            "optionId": optionID
                        ]
                    ]
                )
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        } cancelHandler: { [weak self] in
            guard let self else { return }
            do {
                try await self.transport?.sendResponse(
                    id: id,
                    result: [
                        "outcome": [
                            "outcome": "cancelled"
                        ]
                    ]
                )
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        }

        onPermissionRequest?(request)
        let transcriptText = request.rawPayloadSummary ?? request.toolTitle
        onTranscript?(AssistantTranscriptEntry(
            role: .permission,
            text: "\(backend.shortDisplayName) wants approval for: \(transcriptText)",
            emphasis: true
        ))
        onTimelineMutation?(
            .upsert(
                .permission(
                    id: "permission-\(request.id)",
                    sessionID: request.sessionID,
                    turnID: activeTurnID,
                    request: request,
                    createdAt: Date(),
                    source: .runtime
                )
            )
        )
        updateHUD(
            phase: .waitingForPermission,
            title: "Approve \(request.toolTitle)",
            detail: request.rawPayloadSummary ?? request.rationale
        )
    }

    private func copilotPermissionToolKind(from toolCall: [String: Any]) -> String? {
        let rawInput = toolCall["rawInput"] as? [String: Any] ?? [:]
        if rawInput["command"] != nil || rawInput["commands"] != nil {
            return "commandExecution"
        }
        if rawInput["files"] != nil {
            return "fileChange"
        }
        return toolCall["kind"] as? String
    }

    private func copilotPermissionOptions(
        from rawOptions: [[String: Any]],
        toolKind: String?
    ) -> [AssistantPermissionOption] {
        rawOptions.map { option in
            let optionID = option["optionId"] as? String ?? UUID().uuidString
            return AssistantPermissionOption(
                id: optionID,
                title: option["name"] as? String ?? optionID,
                kind: toolKind ?? option["kind"] as? String ?? "permission",
                isDefault: optionID == "allow_always"
                    || (optionID == "allow_once" && !rawOptions.contains(where: { ($0["optionId"] as? String) == "allow_always" }))
            )
        }
    }

    private func copilotPermissionRationale(from toolCall: [String: Any]) -> String? {
        let rawInput = toolCall["rawInput"] as? [String: Any] ?? [:]
        return firstNonEmptyString(
            rawInput["description"] as? String,
            rawInput["command"] as? String,
            (rawInput["commands"] as? [String])?.joined(separator: "\n")
        )
    }

    private func copilotPermissionSummary(from toolCall: [String: Any]) -> String? {
        let rawInput = toolCall["rawInput"] as? [String: Any] ?? [:]
        return firstNonEmptyString(
            rawInput["command"] as? String,
            (rawInput["commands"] as? [String])?.joined(separator: "\n"),
            toolCall["title"] as? String
        )
    }

    // MARK: - AI Title Generation

    /// Generate a concise session title using a separate ephemeral Codex thread.
    /// The thread's notifications are intercepted so they don't appear in the main UI.
    func generateTitle(userPrompt: String, assistantResponse: String) async -> String? {
        guard transport != nil else { return nil }

        let responseSnippet = String(assistantResponse.prefix(500))
        let titlePrompt = """
        Generate a short title (max 6 words) for a conversation that starts with:

        User: \(userPrompt.prefix(300))

        Assistant: \(responseSnippet)

        Reply with ONLY the title text, nothing else. No quotes, no punctuation at the end, no prefix.
        """

        do {
            // Start an ephemeral thread for title generation
            let threadResponse = try await sendRequest(
                method: "thread/start",
                params: [
                    "approvalPolicy": "auto-approve",
                    "sandbox": "locked-network",
                    "ephemeral": true,
                    "instructions": "You are a title generator. Reply with only a short title, nothing else."
                ]
            )

            guard let payload = threadResponse.raw as? [String: Any],
                  let thread = payload["thread"] as? [String: Any],
                  let threadID = thread["id"] as? String else {
                return nil
            }

            titleGenThreadID = threadID
            titleGenBuffer = ""

            // Send the title-generation turn
            _ = try await sendRequest(
                method: "turn/start",
                params: [
                    "threadId": threadID,
                    "input": [["type": "text", "text": titlePrompt]],
                    "approvalPolicy": "auto-approve"
                ]
            )

            // Wait for the title-generation turn to complete (via notifications)
            let title = await withCheckedContinuation { continuation in
                titleGenContinuation = continuation
            }

            titleGenThreadID = nil
            titleGenContinuation = nil

            let cleaned = title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return cleaned.isEmpty ? nil : cleaned
        } catch {
            titleGenThreadID = nil
            titleGenContinuation = nil
            CrashReporter.logWarning("Title generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func handleTitleGenNotification(method: String, params: [String: Any]) {
        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                let channel = (params["channel"] as? String)?.lowercased()
                if channel != "commentary" {
                    titleGenBuffer += delta
                }
            }
        case "turn/completed":
            titleGenContinuation?.resume(returning: titleGenBuffer)
        case "error":
            let message = firstNonEmptyString(
                params["message"] as? String,
                extractString(params["error"])
            ) ?? ""
            CrashReporter.logWarning("Title generation thread error: \(message)")
            titleGenContinuation?.resume(returning: "")
        default:
            break
        }
    }
}

private actor CodexAppServerTransport {
    private let incoming: @Sendable (CodexIncomingEvent) -> Void
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextClientRequestID = 1
    private var responseContinuations: [JSONRPCRequestID: CheckedContinuation<CodexResponsePayload, Error>] = [:]
    private var bufferedResponses: [JSONRPCRequestID: Result<CodexResponsePayload, Error>] = [:]

    init(incoming: @escaping @Sendable (CodexIncomingEvent) -> Void) {
        self.incoming = incoming
    }

    func isRunning() -> Bool {
        process?.isRunning ?? false
    }

    func startCodex(codexExecutablePath: String) async throws {
        try await startProcess(
            executablePath: codexExecutablePath,
            arguments: ["app-server"],
            workingDirectory: nil,
            initializeParams: [
                "protocolVersion": 2,
                "clientInfo": [
                    "name": "Open Assist",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ],
            sendsInitializedNotification: true,
            launchLabel: "Codex App Server"
        )
    }

    func startCopilot(copilotExecutablePath: String, workingDirectory: String?) async throws {
        try await startProcess(
            executablePath: copilotExecutablePath,
            arguments: ["--acp", "--stdio"],
            workingDirectory: workingDirectory,
            initializeParams: [
                "protocolVersion": 1,
                "clientInfo": [
                    "name": "Open Assist",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                ],
                "capabilities": [:]
            ],
            sendsInitializedNotification: false,
            launchLabel: "GitHub Copilot"
        )
    }

    private func startProcess(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        initializeParams: [String: Any],
        sendsInitializedNotification: Bool,
        launchLabel: String
    ) async throws {
        if process != nil {
            return
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = AssistantCommandEnvironment.mergedEnvironment()
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [incoming] process in
            let message: String?
            if process.terminationReason == .uncaughtSignal {
                message = "\(launchLabel) exited because of a signal."
            } else if process.terminationStatus != 0 {
                message = "\(launchLabel) exited with code \(process.terminationStatus)."
            } else {
                message = nil
            }
            incoming(.processExited(message))
        }

        do {
            try process.run()
        } catch {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Could not launch \(launchLabel): \(error.localizedDescription)")
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        configureReadabilityHandlers()

        _ = try await sendRequest(
            id: 0,
            method: "initialize",
            params: initializeParams
        )
        if sendsInitializedNotification {
            try await sendNotification(method: "initialized", params: nil)
        }
        nextClientRequestID = 1
    }

    func stop() async {
        let continuations = responseContinuations
        responseContinuations.removeAll()
        bufferedResponses.removeAll()
        for (_, continuation) in continuations {
            continuation.resume(throwing: CodexAssistantRuntimeError.runtimeUnavailable("Codex App Server closed."))
        }
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)
        stdinHandle?.closeFile()
        stdinHandle = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    func sendRequest(method: String, params: [String: Any]) async throws -> CodexResponsePayload {
        let requestID = nextClientRequestID
        nextClientRequestID += 1
        return try await sendRequest(id: requestID, method: method, params: params)
    }

    func sendResponse(id: JSONRPCRequestID, result: [String: Any]) async throws {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.rawValue,
            "result": result
        ]
        let encoded = try JSONSerialization.data(withJSONObject: message, options: [])
        try write(data: encoded + Data("\n".utf8))
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]) async throws -> CodexResponsePayload {
        let requestID = JSONRPCRequestID.int(id)
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let encoded = try JSONSerialization.data(withJSONObject: message, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            if let buffered = bufferedResponses.removeValue(forKey: requestID) {
                continuation.resume(with: buffered)
                return
            }

            responseContinuations[requestID] = continuation
            do {
                try write(data: encoded + Data("\n".utf8))
            } catch {
                responseContinuations.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]?) async throws {
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            message["params"] = params
        }
        let encoded = try JSONSerialization.data(withJSONObject: message, options: [])
        try write(data: encoded + Data("\n".utf8))
    }

    private func configureReadabilityHandlers() {
        stdoutHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.consumeIncomingData(data, isErrorStream: false)
            }
        }

        stderrHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.consumeIncomingData(data, isErrorStream: true)
            }
        }
    }

    private func consumeIncomingData(_ data: Data, isErrorStream: Bool) async {
        if data.isEmpty {
            if isErrorStream {
                stderrHandle?.readabilityHandler = nil
            } else {
                stdoutHandle?.readabilityHandler = nil
            }
            return
        }

        if isErrorStream {
            stderrBuffer.append(data)
            await flushBufferedLines(isErrorStream: true)
        } else {
            stdoutBuffer.append(data)
            await flushBufferedLines(isErrorStream: false)
        }
    }

    private func flushBufferedLines(isErrorStream: Bool) async {
        let newline = UInt8(ascii: "\n")

        while true {
            let range: Range<Data.Index>?
            if isErrorStream {
                range = stderrBuffer.firstRange(of: Data([newline]))
            } else {
                range = stdoutBuffer.firstRange(of: Data([newline]))
            }

            guard let range else { break }

            let lineData: Data
            if isErrorStream {
                lineData = stderrBuffer.subdata(in: stderrBuffer.startIndex..<range.lowerBound)
                stderrBuffer.removeSubrange(stderrBuffer.startIndex...range.lowerBound)
            } else {
                lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...range.lowerBound)
            }

            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if isErrorStream {
                let lower = line.lowercased()
                let isNoisy = lower.contains("failed to load rollout")
                    || lower.contains("failed to parse thread id")
                    || lower.contains("deprecation")
                if !isNoisy {
                    incoming(.statusMessage(line))
                }
            } else {
                await handleOutputLine(line)
            }
        }
    }

    private func handleOutputLine(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            CrashReporter.logWarning("Assistant runtime received non-JSON output from Codex App Server")
            incoming(.statusMessage("Received non-JSON output from Codex App Server."))
            return
        }

            if json["method"] == nil, let responseID = parseRequestID(json["id"]) {
            let result: Result<CodexResponsePayload, Error>
            if let errorObject = json["error"] as? [String: Any] {
                result = .failure(
                    CodexAssistantRuntimeError.requestFailed(
                        errorObject["message"] as? String ?? "Codex App Server request failed."
                    )
                )
            } else {
                result = .success(CodexResponsePayload(raw: json["result"] as Any))
            }

            if let continuation = responseContinuations.removeValue(forKey: responseID) {
                continuation.resume(with: result)
            } else {
                bufferedResponses[responseID] = result
            }
            return
        }

        guard let method = json["method"] as? String,
              let params = json["params"] as? [String: Any] else {
            return
        }

        if let requestID = parseRequestID(json["id"]) {
            incoming(.serverRequest(id: requestID, method: method, params: params))
        } else {
            incoming(.notification(method: method, params: params))
        }
    }

    private func parseRequestID(_ raw: Any?) -> JSONRPCRequestID? {
        if let value = raw as? Int {
            return .int(value)
        }
        if let value = raw as? String {
            return .string(value)
        }
        return nil
    }

    private func write(data: Data) throws {
        guard let stdinHandle else {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Codex App Server is not running.")
        }
        try stdinHandle.write(contentsOf: data)
    }
}

@MainActor
private final class PendingPermissionContext {
    let request: AssistantPermissionRequest
    private let selectHandler: @Sendable (String) async -> Void
    private let submitAnswersHandler: (@Sendable ([String: [String]]) async -> Void)?
    private let cancelHandler: @Sendable () async -> Void

    init(
        request: AssistantPermissionRequest,
        selectHandler: @escaping @Sendable (String) async -> Void,
        submitAnswersHandler: (@Sendable ([String: [String]]) async -> Void)? = nil,
        cancelHandler: @escaping @Sendable () async -> Void
    ) {
        self.request = request
        self.selectHandler = selectHandler
        self.submitAnswersHandler = submitAnswersHandler
        self.cancelHandler = cancelHandler
    }

    func select(optionID: String) async {
        await selectHandler(optionID)
    }

    func submit(answers: [String: [String]]) async {
        guard let submitAnswersHandler else { return }
        await submitAnswersHandler(answers)
    }

    func cancel() async {
        await cancelHandler()
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var merged = lhs
        merged.append(rhs)
        return merged
    }
}
