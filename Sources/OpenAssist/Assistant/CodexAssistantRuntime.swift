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

struct CodexResponsePayload: @unchecked Sendable {
    let raw: Any
}

struct ClaudeCodeInvocationResult: Equatable, Sendable {
    let sessionID: String?
    let responseText: String
    let usage: TokenUsageBreakdown?
    let modelContextWindow: Int?
    let stopReason: String?
}

private struct CLIAttachmentMaterialization: Sendable {
    let directoryURL: URL
    let promptContext: String
}

private enum CopilotBackgroundTaskTool: String, Sendable {
    case task
    case readAgent = "read_agent"
    case writeAgent = "write_agent"
    case listAgents = "list_agents"
}

private struct CopilotBackgroundTaskRecord: Equatable, Sendable {
    let id: String
    var sessionID: String?
    var toolCallID: String?
    var description: String
    var statusLabel: String
    var agentType: String?
    var prompt: String?
    var latestIntent: String?
    var recentActivity: [String]
    var result: String?
    var error: String?
    var startedAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var sourceSlashCommand: String?

    var detailText: String? {
        Self.firstNonEmpty(
            latestIntent,
            recentActivity.first,
            prompt,
            result,
            error
        )
    }

    var subagentStatus: SubagentStatus {
        switch Self.normalizedTaskStatus(statusLabel) {
        case "completed", "success", "succeeded":
            return .completed
        case "failed", "error", "errored", "cancelled", "canceled", "killed":
            return .errored
        case "waiting", "pending":
            return .waiting
        default:
            return .running
        }
    }

    private static func normalizedTaskStatus(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

private struct ClaudeQueuedPromptContext: Sendable {
    let attachments: [AssistantAttachment]
    let includesImageAttachments: Bool
    let modelSupportsImageInput: Bool
    let allowsProposedPlan: Bool
}

private struct ClaudeCodePermissionDenial: @unchecked Sendable {
    let requestID: String
    let sessionID: String
    let toolName: String
    let toolUseID: String?
    let toolInput: [String: Any]
    let summary: String?
}

private final class ClaudeCodeCommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let newlineData = Data([UInt8(ascii: "\n")])
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutLineBuffer = Data()
    private var stderrLineBuffer = Data()

    func appendStdout(_ data: Data) -> [String] {
        append(data, into: \.stdout, lineBuffer: \.stdoutLineBuffer)
    }

    func appendStderr(_ data: Data) -> [String] {
        append(data, into: \.stderr, lineBuffer: \.stderrLineBuffer)
    }

    func finalize(
        remainingStdout: Data,
        remainingStderr: Data
    ) -> (stdout: String, stderr: String, stdoutLines: [String], stderrLines: [String]) {
        lock.lock()
        defer { lock.unlock() }

        let stdoutLines = Self.appendChunk(
            remainingStdout,
            newlineData: newlineData,
            accumulator: &stdout,
            lineBuffer: &stdoutLineBuffer
        ) + Self.flushPartialLine(from: &stdoutLineBuffer)

        let stderrLines = Self.appendChunk(
            remainingStderr,
            newlineData: newlineData,
            accumulator: &stderr,
            lineBuffer: &stderrLineBuffer
        ) + Self.flushPartialLine(from: &stderrLineBuffer)

        return (
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            stdoutLines: stdoutLines,
            stderrLines: stderrLines
        )
    }

    private func append(
        _ data: Data,
        into accumulatorKeyPath: ReferenceWritableKeyPath<ClaudeCodeCommandCapture, Data>,
        lineBuffer lineBufferKeyPath: ReferenceWritableKeyPath<ClaudeCodeCommandCapture, Data>
    ) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Self.appendChunk(
            data,
            newlineData: newlineData,
            accumulator: &self[keyPath: accumulatorKeyPath],
            lineBuffer: &self[keyPath: lineBufferKeyPath]
        )
    }

    private static func appendChunk(
        _ data: Data,
        newlineData: Data,
        accumulator: inout Data,
        lineBuffer: inout Data
    ) -> [String] {
        guard !data.isEmpty else { return [] }
        accumulator.append(data)
        lineBuffer.append(data)

        var lines: [String] = []
        while let range = lineBuffer.firstRange(of: newlineData) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<range.lowerBound)
            lineBuffer.removeSubrange(lineBuffer.startIndex...range.lowerBound)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    private static func flushPartialLine(from lineBuffer: inout Data) -> [String] {
        guard !lineBuffer.isEmpty else { return [] }
        defer { lineBuffer.removeAll(keepingCapacity: false) }
        let line = String(decoding: lineBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? [] : [line]
    }
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
    case processExited(message: String?, expected: Bool)
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
    var onActivityItemUpdate: (@Sendable (AssistantActivityItem) -> Void)?
    var onHUDUpdate: (@Sendable (AssistantHUDState) -> Void)?
    var onPlanUpdate: (@Sendable (_ sessionID: String?, _ entries: [AssistantPlanEntry]) -> Void)?
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
    var onExecutionStateUpdate: (@Sendable (_ hasActiveTurn: Bool, _ hasLiveClaudeProcess: Bool) -> Void)?
    /// Fired after the first successful turn of a new session with (sessionID, userPrompt, assistantResponse).
    var onTitleRequest: (@Sendable (_ sessionID: String, _ userPrompt: String, _ assistantResponse: String) -> Void)?

    private var transport: CodexAppServerTransport?
    private var mcpToolBridge: AssistantMCPToolBridge?
    private var mcpConfigFilePath: String?
    private var activeClaudeProcess: Process?
    private var activeClaudeStdinHandle: FileHandle?
    private var activeClaudeProcessSessionID: String?
    private var activeClaudeProcessWorkingDirectory: String?
    private var activeClaudeProcessModelID: String?
    private var activeClaudeProcessPermissionMode: String?
    private var activeClaudeProcessAllowedTools: [String] = []
    private var activeClaudeTurnContinuations: [CheckedContinuation<AssistantTurnCompletionStatus, Error>] = []
    private var activeClaudeQueuedPromptContexts: [ClaudeQueuedPromptContext] = []
    private var claudeCodeIdleTimeoutTask: Task<Void, Never>?
    private var lastClaudeCodeActivityAt: Date?
    private var activeSessionID: String?
    private var activeSessionCWD: String?
    private var activeTurnID: String?
    private var currentTurnAttachments: [AssistantAttachment] = []
    private var selectedCodexPluginIDs: Set<String> = []
    private var preferredModelID: String?
    private var preferredSubagentModelID: String?
    private var currentCodexPath: String?
    private var currentTransportWorkingDirectory: String?
    private var transportSessionID: String?
    private var bootstrapSessionID: String?
    private var currentAccountSnapshot: AssistantAccountSnapshot = .signedOut
    private var currentRateLimits: AccountRateLimits = .empty
    private var currentTokenUsageSnapshot: TokenUsageSnapshot = .empty
    private var currentModels: [AssistantModelOption] = []
    private var toolCalls: [String: AssistantToolCallState] = [:]
    private var liveActivities: [String: AssistantActivityItem] = [:]
    private var locallySuccessfulDynamicToolCallIDs: Set<String> = []
    private var pendingPermissionContext: PendingPermissionContext?
    private var loginRefreshTask: Task<Void, Never>?
    private var metadataRefreshTask: Task<Void, Never>?
    private var rateLimitRefreshTask: Task<Void, Never>?
    private var rateLimitRefreshTaskID = UUID()
    private var transportStartupTask: Task<Void, Error>?
    private var turnToolCallCount = 0
    private var repeatedCommandTracker = AssistantRepeatedCommandTracker()
    private var sessionTurnCount = 0
    private var firstTurnUserPrompt: String?
    var maxToolCallsPerTurn: Int = 75
    var maxRepeatedCommandAttemptsPerTurn: Int = 3
    private static let claudeCodeRateLimitRefreshIntervalNanoseconds: UInt64 = 20_000_000_000
    private static let claudeCodeIdleRateLimitRefreshIntervalNanoseconds: UInt64 = 90_000_000_000
    private var idleRateLimitRefreshTask: Task<Void, Never>?
    private static let claudeCodeLiveProcessIdleTimeoutNanoseconds: UInt64 = 900_000_000_000
    private static let claudeCodeDeferredCompletionGracePeriodNanoseconds: UInt64 = 1_200_000_000
    private static let copilotCompletionQuietPeriodNanoseconds: UInt64 = 2_000_000_000
    private static let copilotCompletionActivityGracePeriodNanoseconds: UInt64 = 6_000_000_000
    private static let copilotCompletionHardTimeoutNanoseconds: UInt64 = 15_000_000_000

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
    private var pendingCopilotCompletionParams: [String: Any]?
    private var pendingCopilotCompletionEmit: DispatchWorkItem?
    private var pendingCopilotSlashCommand: AssistantSubmittedSlashCommand?
    private var pendingCopilotSlashCommandActivityID: String?
    private var pendingCopilotSessionTransitionCommand: AssistantSubmittedSlashCommand?
    private var pendingClaudeCompletionEmit: DispatchWorkItem?
    private var lastCopilotSessionUpdateTime: CFAbsoluteTime = 0
    private var planTimelineID: String?
    private var planStartedAt: Date?
    private var persistedCLIAttachmentSessionID: String?
    private var persistedCLIAttachmentMaterialization: CLIAttachmentMaterialization?
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
    private var copilotBackgroundTasksByID: [String: CopilotBackgroundTaskRecord] = [:]
    private var copilotBackgroundTaskIDByToolCallID: [String: String] = [:]
    private let browserUseService: AssistantBrowserUseService
    private let appActionService: AssistantAppActionService
    private let computerUseService: AssistantComputerUseService
    private let imageGenerationService: AssistantImageGenerationService
    private let shellExecutionService: AssistantShellExecutionService
    private let windowAutomationService: AssistantWindowAutomationService
    private let accessibilityAutomationService: AssistantAccessibilityAutomationService
    private let toolExecutor: AssistantToolExecutor
    private let localRuntimeManager: LocalAIRuntimeManaging
    private let ollamaChatService: AssistantOllamaChatServing
    private var approvedDynamicToolKindsBySessionID: [String: Set<String>] = [:]
    private var approvedClaudeToolNamesBySessionID: [String: Set<String>] = [:]
    private var activeOllamaTurnTask: Task<Void, Never>?
    private var ollamaMessageHistoryBySessionID: [String: [AssistantOllamaChatMessage]] = [:]
    private var ollamaModelIDBySessionID: [String: String] = [:]

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

    var hasLiveClaudeProcess: Bool {
        backend == .claudeCode
            && activeClaudeProcess?.isRunning == true
            && activeClaudeStdinHandle != nil
    }

    var canSteerActiveTurn: Bool {
        backend != .claudeCode
            && backend != .copilot
            && backend != .ollamaLocal
            && activeTurnID != nil
    }

    init(
        preferredModelID: String? = nil,
        preferredSubagentModelID: String? = nil,
        assistantNotesService: AssistantNotesToolService? = nil,
        browserUseService: AssistantBrowserUseService? = nil,
        appActionService: AssistantAppActionService? = nil,
        computerUseService: AssistantComputerUseService? = nil,
        imageGenerationService: AssistantImageGenerationService? = nil,
        shellExecutionService: AssistantShellExecutionService? = nil,
        windowAutomationService: AssistantWindowAutomationService? = nil,
        accessibilityAutomationService: AssistantAccessibilityAutomationService? = nil,
        installSupport: CodexInstallSupport = CodexInstallSupport(),
        localRuntimeManager: LocalAIRuntimeManaging = LocalAIRuntimeManager.shared,
        ollamaChatService: AssistantOllamaChatServing = AssistantOllamaChatService.shared
    ) {
        self.preferredModelID = preferredModelID?.nonEmpty
        self.preferredSubagentModelID = preferredSubagentModelID?.nonEmpty
        self.browserUseService = browserUseService ?? AssistantBrowserUseService(
            settings: .shared
        )
        self.appActionService = appActionService ?? AssistantAppActionService()
        self.computerUseService = computerUseService ?? AssistantComputerUseService()
        self.imageGenerationService = imageGenerationService ?? AssistantImageGenerationService()
        self.shellExecutionService = shellExecutionService ?? AssistantShellExecutionService()
        self.windowAutomationService = windowAutomationService ?? AssistantWindowAutomationService()
        self.accessibilityAutomationService = accessibilityAutomationService ?? AssistantAccessibilityAutomationService()
        let resolvedAssistantNotesService = assistantNotesService ?? AssistantNotesToolService()
        self.toolExecutor = AssistantToolExecutor(
            assistantNotesService: resolvedAssistantNotesService,
            browserUseService: self.browserUseService,
            appActionService: self.appActionService,
            computerUseService: self.computerUseService,
            imageGenerationService: self.imageGenerationService,
            shellExecutionService: self.shellExecutionService,
            windowAutomationService: self.windowAutomationService,
            accessibilityAutomationService: self.accessibilityAutomationService,
            surfaceCompiler: AssistantToolSurfaceCompiler()
        )
        self.installSupport = installSupport
        self.localRuntimeManager = localRuntimeManager
        self.ollamaChatService = ollamaChatService
    }

    func setPreferredModelID(_ modelID: String?) {
        let changed = preferredModelID != modelID?.nonEmpty
        preferredModelID = modelID?.nonEmpty
        let healthSummary = backend.requiresLogin
            ? (currentAccountSnapshot.isLoggedIn ? backend.connectedSummary : backend.signInPromptSummary)
            : backend.connectedSummary
        let health = makeHealth(
            availability: activeTurnID == nil ? .ready : .active,
            summary: healthSummary
        )
        onHealthUpdate?(health)

        // Refresh rate limits when the selected model can change the visible bucket.
        if (backend == .codex || backend == .claudeCode), changed, currentAccountSnapshot.isLoggedIn {
            Task { await refreshRateLimits() }
        }
    }

    func setPreferredSubagentModelID(_ modelID: String?) {
        preferredSubagentModelID = modelID?.nonEmpty
    }

    func clearCachedEnvironmentState() {
        cancelRateLimitRefreshLoop()
        cancelIdleRateLimitRefresh()
        resolveAllActiveClaudeTurnContinuations(status: .interrupted)
        activeClaudeQueuedPromptContexts.removeAll()
        terminateActiveClaudeProcess()
        activeOllamaTurnTask?.cancel()
        activeOllamaTurnTask = nil
        ollamaMessageHistoryBySessionID.removeAll()
        ollamaModelIDBySessionID.removeAll()
        currentAccountSnapshot = .signedOut
        currentRateLimits = .empty
        currentTokenUsageSnapshot = .empty
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
        case .claudeCode:
            return try await refreshClaudeCodeEnvironment(cwd: activeSessionCWD)
        case .ollamaLocal:
            return try await refreshOllamaEnvironment()
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
        case .claudeCode:
            guard await resolvedExecutablePath() != nil else {
                throw CodexAssistantRuntimeError.runtimeUnavailable("Claude Code is not installed on this Mac.")
            }
            onStatusMessage?("Run `claude auth login` in Terminal, then return to Open Assist.")
            onHealthUpdate?(makeHealth(availability: .loginRequired, summary: backend.loginRequiredSummary))
            return .runCommand(backend.loginCommands.first ?? "claude auth login")
        case .ollamaLocal:
            onStatusMessage?("Ollama uses local setup instead of sign-in. Open Local AI Setup to install Ollama or download Gemma 4.")
            return .none
        }
    }

    func logout() async throws {
        if backend == .ollamaLocal {
            currentAccountSnapshot = .signedOut
            currentRateLimits = .empty
            onAccountUpdate?(currentAccountSnapshot)
            onRateLimitsUpdate?(currentRateLimits)
            onHealthUpdate?(makeHealth(availability: .ready, summary: backend.connectedSummary))
            return
        }
        guard backend == .codex else {
            cancelRateLimitRefreshLoop()
            currentAccountSnapshot = .signedOut
            currentRateLimits = .empty
            currentTokenUsageSnapshot = .empty
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
        if backend == .ollamaLocal {
            let sessionID = "ollama-\(UUID().uuidString.lowercased())"
            toolCalls.removeAll()
            liveActivities.removeAll()
            clearSubagents(publish: false)
            repeatedCommandTracker.reset()
            resetStreamingTimelineState()
            clearPersistedCLIAttachmentMaterialization()
            onToolCallUpdate?([])
            onPlanUpdate?(activeSessionID, [])
            onSubagentUpdate?([])
            onTimelineMutation?(.reset(sessionID: nil))
            onPermissionRequest?(nil)
            sessionTurnCount = 0
            firstTurnUserPrompt = nil
            activeSessionID = sessionID
            activeSessionCWD = cwd?.nonEmpty
            ollamaMessageHistoryBySessionID[sessionID] = []
            onSessionChange?(sessionID)
            onTranscript?(AssistantTranscriptEntry(role: .system, text: backend.startedSessionMessage, emphasis: true))
            onHealthUpdate?(makeHealth(availability: .active, summary: backend.connectedSummary))
            updateHUD(phase: .idle, title: "Assistant is ready", detail: nil)
            return sessionID
        }
        if backend == .copilot {
            return try await startCopilotSession(
                cwd: cwd,
                preferredModelID: preferredModelID ?? self.preferredModelID,
                announce: true
            )
        }
        if backend == .claudeCode {
            return try await startClaudeCodeSession(
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
        clearPersistedCLIAttachmentMaterialization()
        onToolCallUpdate?([])
        onPlanUpdate?(activeSessionID, [])
        onSubagentUpdate?([])
        onTimelineMutation?(.reset(sessionID: nil))
        onPermissionRequest?(nil)
        sessionTurnCount = 0
        firstTurnUserPrompt = nil

        let requestedModelID = preferredModelID ?? self.preferredModelID
        let loggedCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "none"
        let threadStartParameters = await threadStartParams(cwd: cwd, modelID: requestedModelID)
        let instructionChars = (threadStartParameters["instructions"] as? String)?.count ?? 0
        CrashReporter.logInfo(
            "Assistant runtime requesting thread/start model=\(requestedModelID ?? "server-default") cwd=\(loggedCWD) instructionChars=\(instructionChars) activeSkills=\(activeSkills.count)"
        )

        let response = try await sendRequest(
            method: "thread/start",
            params: threadStartParameters
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
        if backend == .ollamaLocal {
            activeSessionID = sessionID
            activeSessionCWD = cwd?.nonEmpty
            sessionTurnCount = 1
            if ollamaMessageHistoryBySessionID[sessionID] == nil {
                ollamaMessageHistoryBySessionID[sessionID] = []
            }
            onSessionChange?(sessionID)
            onTranscript?(AssistantTranscriptEntry(role: .system, text: backend.loadedSessionMessage(sessionID), emphasis: true))
            onHealthUpdate?(makeHealth(availability: .active, summary: backend.connectedSummary))
            updateHUD(phase: .idle, title: "Thread ready", detail: nil)
            return
        }
        if backend == .copilot {
            try await resumeCopilotSession(
                sessionID,
                cwd: cwd,
                preferredModelID: preferredModelID ?? self.preferredModelID,
                announce: true
            )
            return
        }
        if backend == .claudeCode {
            try await resumeClaudeCodeSession(
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
        if backend == .ollamaLocal {
            activeSessionID = sessionID
            activeSessionCWD = cwd?.nonEmpty
            sessionTurnCount = 1
            if ollamaMessageHistoryBySessionID[sessionID] == nil {
                ollamaMessageHistoryBySessionID[sessionID] = []
            }
            onSessionChange?(sessionID)
            onHealthUpdate?(makeHealth(
                availability: activeTurnID == nil ? .ready : .active,
                summary: backend.connectedSummary
            ))
            updateHUD(phase: .idle, title: "Thread ready", detail: nil)
            return
        }
        if backend == .copilot {
            try await resumeCopilotSession(
                sessionID,
                cwd: cwd,
                preferredModelID: preferredModelID ?? self.preferredModelID,
                announce: false
            )
            return
        }
        if backend == .claudeCode {
            try await resumeClaudeCodeSession(
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
        if backend == .ollamaLocal {
            activeSessionCWD = cwd?.nonEmpty
            self.preferredModelID = preferredModelID ?? self.preferredModelID
            onHealthUpdate?(makeHealth(
                availability: activeTurnID == nil ? .ready : .active,
                summary: backend.connectedSummary
            ))
            return
        }
        if backend == .copilot {
            try await refreshCopilotCurrentSessionConfiguration(
                sessionID: activeSessionID,
                cwd: cwd,
                preferredModelID: preferredModelID ?? self.preferredModelID
            )
            return
        }
        if backend == .claudeCode {
            try await refreshClaudeCodeCurrentSessionConfiguration(
                sessionID: activeSessionID,
                cwd: cwd,
                preferredModelID: preferredModelID ?? self.preferredModelID
            )
            return
        }
        try await ensureTransport()
        let requestedModelID = preferredModelID ?? self.preferredModelID
        let loggedCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "none"
        let threadResumeParameters = await threadResumeParams(
            threadID: activeSessionID,
            cwd: cwd,
            modelID: requestedModelID
        )
        let instructionChars = (threadResumeParameters["instructions"] as? String)?.count ?? 0
        CrashReporter.logInfo(
            "Assistant runtime requesting thread/resume threadID=\(activeSessionID) model=\(requestedModelID ?? "server-default") cwd=\(loggedCWD) instructionChars=\(instructionChars) activeSkills=\(activeSkills.count)"
        )
        _ = try await sendRequest(
            method: "thread/resume",
            params: threadResumeParameters
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
        memoryContext: String? = nil,
        submittedSlashCommand: AssistantSubmittedSlashCommand? = nil,
        structuredInputItems: [AssistantCodexPromptInputItem] = []
    ) async throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        if backend != .claudeCode {
            // Reset plan buffer for the new turn
            proposedPlanBuffer = ""
            allowsProposedPlanForActiveTurn = interactionMode == .plan
            blockedToolUseHandledForActiveTurn = false
            blockedToolUseInterruptionMessage = nil
            currentTurnAttachments = attachments
            currentTurnIncludesImageAttachments = attachments.contains(where: \.isImage)
            currentTurnModelSupportsImageInput = modelSupportsImageInput
            currentTurnHadSuccessfulImageGeneration = false
            redirectedImageToolCallForActiveTurn = false
        }

        // Track the first user prompt for title generation
        if sessionTurnCount == 0, firstTurnUserPrompt == nil {
            firstTurnUserPrompt = trimmed
        }

        if activeSessionID == nil {
            _ = try await startNewSession(preferredModelID: preferredModelID ?? self.preferredModelID)
        }

        guard let activeSessionID else {
            throw CodexAssistantRuntimeError.sessionUnavailable
        }

        if backend == .ollamaLocal {
            try await sendOllamaPrompt(
                sessionID: activeSessionID,
                prompt: trimmed,
                attachments: attachments,
                preferredModelID: preferredModelID ?? self.preferredModelID,
                modelSupportsImageInput: modelSupportsImageInput,
                resumeContext: resumeContext,
                memoryContext: memoryContext
            )
            return
        }
        if backend == .copilot {
            try await sendCopilotPrompt(
                sessionID: activeSessionID,
                prompt: trimmed,
                attachments: attachments,
                preferredModelID: preferredModelID ?? self.preferredModelID,
                resumeContext: resumeContext,
                memoryContext: memoryContext,
                submittedSlashCommand: submittedSlashCommand
            )
            return
        }
        if backend == .claudeCode {
            try await sendClaudeCodePrompt(
                sessionID: activeSessionID,
                prompt: trimmed,
                attachments: attachments,
                preferredModelID: preferredModelID ?? self.preferredModelID,
                modelSupportsImageInput: modelSupportsImageInput,
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
        let inlineAttachments = attachments.filter(\.isImage)
        let attachmentContext = try resolvedCLIAttachmentContext(
            sessionID: activeSessionID,
            attachments: attachments.filter { !$0.isImage }
        )

        let response = try await sendRequest(
            method: "turn/start",
            params: turnStartParams(
                threadID: activeSessionID,
                prompt: trimmed,
                attachments: inlineAttachments,
                attachmentContext: attachmentContext,
                modelID: requestedModelID,
                resumeContext: resumeContext,
                memoryContext: memoryContext,
                structuredInputItems: structuredInputItems
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
        cancelPendingCopilotPromptCompletion()

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
            finalizeActiveActivities(with: .interrupted)
            self.activeTurnID = nil
            allowsProposedPlanForActiveTurn = false
            updateHUD(phase: .idle, title: "Cancelled", detail: nil)
            if hadActiveTurn {
                onTurnCompletion?(.interrupted)
            }
            onHealthUpdate?(makeHealth(availability: .ready, summary: backend.connectedSummary))
            return
        }
        if backend == .claudeCode {
            let hadActiveTurn = activeTurnID != nil
            resolveAllActiveClaudeTurnContinuations(status: .interrupted)
            finalizeActiveActivities(with: .interrupted)
            self.activeTurnID = nil
            terminateActiveClaudeProcess()
            allowsProposedPlanForActiveTurn = false
            updateHUD(phase: .idle, title: "Cancelled", detail: nil)
            if hadActiveTurn {
                onTurnCompletion?(.interrupted)
            }
            onHealthUpdate?(makeHealth(availability: .ready, summary: backend.connectedSummary))
            return
        }
        if backend == .ollamaLocal {
            let hadActiveTurn = activeTurnID != nil
            activeOllamaTurnTask?.cancel()
            activeOllamaTurnTask = nil
            await unloadTrackedOllamaModels()
            finalizeActiveActivities(with: .interrupted)
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

        finalizeActiveActivities(with: .interrupted)
        self.activeTurnID = nil
        allowsProposedPlanForActiveTurn = false
        updateHUD(phase: .idle, title: "Cancelled", detail: nil)
        onTurnCompletion?(.interrupted)
    }

    func steerActiveTurn(
        prompt: String,
        attachments: [AssistantAttachment] = []
    ) async throws {
        guard let activeSessionID, let activeTurnID else {
            throw CodexAssistantRuntimeError.sessionUnavailable
        }

        var inputItems: [[String: Any]] = []
        for attachment in attachments.filter(\.isImage) {
            inputItems.append(attachment.toInputItem())
        }
        if !prompt.isEmpty {
            inputItems.append(["type": "text", "text": prompt])
        }

        CrashReporter.logInfo("Assistant runtime requesting turn/steer threadID=\(activeSessionID) turnID=\(activeTurnID) promptChars=\(prompt.count)")

        _ = try await sendRequest(
            method: "turn/steer",
            params: [
                "threadId": activeSessionID,
                "input": inputItems,
                "expectedTurnId": activeTurnID
            ]
        )

        CrashReporter.logInfo("Assistant runtime turn/steer accepted turnID=\(activeTurnID)")
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
        if backend == .claudeCode {
            resolveAllActiveClaudeTurnContinuations(status: .interrupted)
            activeClaudeQueuedPromptContexts.removeAll()
            terminateActiveClaudeProcess(expected: true)
        }
        if backend == .ollamaLocal {
            activeOllamaTurnTask?.cancel()
            activeOllamaTurnTask = nil
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
        clearPersistedCLIAttachmentMaterialization()
        onToolCallUpdate?([])
        onPlanUpdate?(activeSessionID, [])
        onSubagentUpdate?([])
        onTimelineMutation?(.reset(sessionID: nil))
    }

    func listSessions(limit: Int = 40) async throws -> [AssistantSessionSummary] {
        switch backend {
        case .codex:
            return []
        case .copilot:
            return try await listCopilotSessions(limit: limit)
        case .claudeCode:
            return []
        case .ollamaLocal:
            return []
        }
    }

    func stop() async {
        loginRefreshTask?.cancel()
        loginRefreshTask = nil
        metadataRefreshTask?.cancel()
        metadataRefreshTask = nil
        cancelRateLimitRefreshLoop()
        transportStartupTask?.cancel()
        transportStartupTask = nil
        resolveAllActiveClaudeTurnContinuations(status: .interrupted)
        terminateActiveClaudeProcess()
        activeOllamaTurnTask?.cancel()
        activeOllamaTurnTask = nil
        if backend == .ollamaLocal {
            await unloadTrackedOllamaModels()
        }
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
        onPlanUpdate?(activeSessionID, [])
        onSubagentUpdate?([])
        onTimelineMutation?(.reset(sessionID: nil))
        onSessionChange?(nil)
        currentTokenUsageSnapshot = .empty
        onTokenUsageUpdate?(currentTokenUsageSnapshot)
        ollamaMessageHistoryBySessionID.removeAll()
        ollamaModelIDBySessionID.removeAll()
        await transport?.stop()
        transport = nil
        onHealthUpdate?(makeHealth(availability: .idle, summary: "Assistant is idle"))
        updateHUD(phase: .idle, title: "Assistant is ready", detail: nil)

        // Clean up lingering AppleScript processes
        Self.cleanupAppleScriptProcesses()
    }

    private func rememberOllamaModelID(_ modelID: String?, for sessionID: String) {
        guard let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }

        guard let normalizedModelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            ollamaModelIDBySessionID.removeValue(forKey: normalizedSessionID)
            return
        }

        ollamaModelIDBySessionID[normalizedSessionID] = normalizedModelID
    }

    private func trackedOllamaModelIDs() -> [String] {
        var orderedModelIDs: [String] = []
        var seenModelIDs = Set<String>()

        if let activeSessionID = activeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
           let activeModelID = ollamaModelIDBySessionID[activeSessionID],
           seenModelIDs.insert(activeModelID.lowercased()).inserted {
            orderedModelIDs.append(activeModelID)
        }

        for modelID in ollamaModelIDBySessionID.values {
            let normalizedKey = modelID.lowercased()
            guard seenModelIDs.insert(normalizedKey).inserted else { continue }
            orderedModelIDs.append(modelID)
        }

        return orderedModelIDs
    }

    private func unloadTrackedOllamaModels() async {
        for modelID in trackedOllamaModelIDs() {
            await unloadOllamaModelIfNeeded(named: modelID)
        }
    }

    private func unloadOllamaModelIfNeeded(named modelID: String?) async {
        guard let normalizedModelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }

        do {
            try await ollamaChatService.unloadModel(named: normalizedModelID)
        } catch {
            CrashReporter.logWarning(
                "Assistant runtime could not unload Ollama model model=\(normalizedModelID) error=\(error.localizedDescription)"
            )
        }
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

    func ensureTransport(cwd: String? = nil) async throws {
        if backend == .claudeCode {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Claude Code uses the headless CLI flow, not the ACP transport.")
        }
        if backend == .ollamaLocal {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Ollama (Local) uses the native local chat API, not the ACP transport.")
        }
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
            case .claudeCode:
                throw CodexAssistantRuntimeError.runtimeUnavailable("Claude Code is not installed on this Mac.")
            case .ollamaLocal:
                throw CodexAssistantRuntimeError.runtimeUnavailable("Ollama is not installed on this Mac.")
            }
        }

        onHealthUpdate?(makeHealth(availability: .connecting, summary: backend.startupSummary))
        CrashReporter.logInfo("Assistant runtime connecting backend=\(backend.rawValue) path=\(codexPath)")
        let startupTask = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { return }

            let transport = CodexAppServerTransport { [weak self] event in
                await self?.handleIncomingEvent(event)
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
                case .claudeCode:
                    throw CodexAssistantRuntimeError.runtimeUnavailable("Claude Code does not use the ACP transport.")
                case .ollamaLocal:
                    throw CodexAssistantRuntimeError.runtimeUnavailable("Ollama (Local) does not use the ACP transport.")
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
        switch backend {
        case .codex:
            CrashReporter.logInfo("Assistant runtime requesting account/read")
            let response = try await requestWithTimeout(method: "account/read", params: ["refreshToken": false])
            let account = parseAccountSnapshot(from: response.raw)
            currentAccountSnapshot = account
            onAccountUpdate?(account)
            CrashReporter.logInfo("Assistant runtime account/read finished loggedIn=\(account.isLoggedIn) authMode=\(account.authMode.rawValue)")
            return account
        case .copilot:
            let account = signedInCopilotAccountSnapshot()
            currentAccountSnapshot = account
            onAccountUpdate?(account)
            return account
        case .claudeCode:
            let account = try await refreshClaudeCodeAccountState()
            currentAccountSnapshot = account
            onAccountUpdate?(account)
            return account
        case .ollamaLocal:
            let account = AssistantAccountSnapshot.signedOut
            currentAccountSnapshot = account
            onAccountUpdate?(account)
            return account
        }
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
        case .claudeCode:
            guard currentAccountSnapshot.isLoggedIn else {
                currentRateLimits = .empty
                onRateLimitsUpdate?(currentRateLimits)
                return
            }

            let credentialsResolver = ClaudeCodeOAuthCredentialResolver(
                fileManager: installSupport.fileManager,
                homeDirectory: installSupport.homeDirectory
            )

            do {
                guard let snapshot = try await ClaudeCodeUsageFetcher().fetchUsage(
                    resolver: credentialsResolver
                ) else {
                    CrashReporter.logInfo("Claude Code usage refresh skipped because no OAuth credentials could be resolved.")
                    return
                }
                currentRateLimits = snapshot.rateLimits
                onRateLimitsUpdate?(currentRateLimits)

                if let planType = snapshot.planType, currentAccountSnapshot.planType != planType {
                    currentAccountSnapshot.planType = planType
                    onAccountUpdate?(currentAccountSnapshot)
                }
            } catch {
                CrashReporter.logInfo("Claude Code usage refresh failed: \(error.localizedDescription)")
            }
        case .ollamaLocal:
            currentRateLimits = .empty
            onRateLimitsUpdate?(currentRateLimits)
        }
    }

    private func refreshModels() async throws -> [AssistantModelOption] {
        if backend == .ollamaLocal {
            let models = await ollamaModelOptions()
            currentModels = models
            onModelsUpdate?(models)
            return models
        }
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
        if backend == .claudeCode {
            let models = staticClaudeCodeModels()
            currentModels = models
            onModelsUpdate?(models)
            return models
        }

        CrashReporter.logInfo("Assistant runtime requesting model/list")
        let response = try await requestWithTimeout(method: "model/list", params: [:])
        let models = parseModels(from: response.raw)
        currentModels = models
        onModelsUpdate?(models)
        CrashReporter.logInfo("Assistant runtime model/list finished count=\(models.count)")
        return models
    }

    private func refreshOllamaEnvironment() async throws -> AssistantEnvironmentDetails {
        var detection = await localRuntimeManager.detect()
        currentCodexPath = (detection.executableURL?.path)?.nonEmpty ?? currentCodexPath

        if detection.installed && !detection.isHealthy {
            detection = try await localRuntimeManager.start()
            currentCodexPath = (detection.executableURL?.path)?.nonEmpty ?? currentCodexPath
        }

        guard detection.installed else {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Ollama is not installed on this Mac.")
        }

        let models = await ollamaModelOptions()
        currentModels = models
        currentAccountSnapshot = .signedOut
        currentRateLimits = .empty
        onAccountUpdate?(currentAccountSnapshot)
        onRateLimitsUpdate?(currentRateLimits)
        onModelsUpdate?(models)

        let selectedModel = resolvedOllamaSelectedModel(from: models)
        let selectedModelInstalled = selectedModel?.isInstalled ?? false
        let health = AssistantRuntimeHealth(
            availability: selectedModelInstalled ? (activeTurnID == nil ? .ready : .active) : .installRequired,
            summary: selectedModelInstalled ? backend.connectedSummary : backend.missingInstallSummary,
            detail: selectedModelInstalled ? nil : ollamaMissingModelDetail(for: selectedModel),
            runtimePath: currentCodexPath,
            selectedModelID: selectedModel?.id ?? preferredModelID,
            accountEmail: nil,
            accountPlan: nil
        )
        onHealthUpdate?(health)
        return AssistantEnvironmentDetails(
            health: health,
            account: currentAccountSnapshot,
            models: models
        )
    }

    private func ollamaModelOptions() async -> [AssistantModelOption] {
        let installedModelIDs = await localRuntimeManager.installedModels()
        let normalizedInstalledModelIDs = installedModelIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let reasoningEfforts = AssistantReasoningEffort.allCases.map(\.wireValue)
        var options: [AssistantModelOption] = []
        var seenModelIDs: [String] = []

        for model in AssistantGemma4ModelCatalog.catalog() {
            let isInstalled = normalizedInstalledModelIDs.contains { Self.ollamaModelIDsEquivalent($0, model.id) }
            options.append(
                AssistantModelOption(
                    id: model.id,
                    displayName: model.displayName,
                    description: model.summary,
                    isDefault: model.isRecommended,
                    hidden: false,
                    supportedReasoningEfforts: reasoningEfforts,
                    defaultReasoningEffort: AssistantReasoningEffort.high.wireValue,
                    inputModalities: ["text", "image"],
                    isInstalled: isInstalled
                )
            )
            seenModelIDs.append(model.id)
        }

        for installedModelID in normalizedInstalledModelIDs {
            guard !seenModelIDs.contains(where: { Self.ollamaModelIDsEquivalent($0, installedModelID) }) else {
                continue
            }
            let supportsImageInput = Self.ollamaModelSupportsImageInput(installedModelID)
            options.append(
                AssistantModelOption(
                    id: installedModelID,
                    displayName: installedModelID,
                    description: "Installed local Ollama model.",
                    isDefault: false,
                    hidden: false,
                    supportedReasoningEfforts: reasoningEfforts,
                    defaultReasoningEffort: AssistantReasoningEffort.high.wireValue,
                    inputModalities: supportsImageInput ? ["text", "image"] : ["text"],
                    isInstalled: true
                )
            )
            seenModelIDs.append(installedModelID)
        }

        return options
    }

    private func resolvedOllamaSelectedModel(
        from models: [AssistantModelOption]
    ) -> AssistantModelOption? {
        if let preferredModelID = preferredModelID?.nonEmpty,
           let preferredModel = models.first(where: { Self.ollamaModelIDsEquivalent($0.id, preferredModelID) }) {
            return preferredModel
        }

        if let recommendedModel = models.first(where: \.isDefault) {
            return recommendedModel
        }

        return models.first
    }

    private func ollamaMissingModelDetail(for model: AssistantModelOption?) -> String {
        if let model {
            return "\(model.displayName) is not installed yet. Open Local AI Setup to download it, or choose a model that is already installed."
        }
        return "Open Local AI Setup to download a Gemma 4 model for Ollama."
    }

    private static func ollamaModelIDsEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let normalizedLHS = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedRHS = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedLHS.isEmpty, !normalizedRHS.isEmpty else { return false }
        return normalizedLHS == normalizedRHS
            || normalizedLHS.hasPrefix(normalizedRHS + ":")
            || normalizedRHS.hasPrefix(normalizedLHS + ":")
    }

    private static func ollamaModelSupportsImageInput(_ modelID: String) -> Bool {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visionSignals = [
            "gemma4",
            "gemma3",
            "llava",
            "vision",
            "minicpm-v",
            "qwen2.5vl",
            "qwen2-vl"
        ]
        return visionSignals.contains(where: normalized.contains)
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

    private func sendOllamaPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AssistantAttachment],
        preferredModelID: String?,
        modelSupportsImageInput: Bool,
        resumeContext: String?,
        memoryContext: String?
    ) async throws {
        turnToolCallCount = 0
        repeatedCommandTracker.reset()
        updateHUD(phase: .streaming, title: "Starting", detail: nil)

        let turnID = activeTurnID?.nonEmpty ?? "ollama-turn-\(UUID().uuidString)"
        activeTurnID = turnID
        let requestedModelID = preferredModelID?.nonEmpty
            ?? self.preferredModelID?.nonEmpty
            ?? AssistantGemma4ModelCatalog.recommendedModelID()
        rememberOllamaModelID(requestedModelID, for: sessionID)

        let turnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runOllamaTurn(
                    sessionID: sessionID,
                    modelID: requestedModelID,
                    prompt: prompt,
                    attachments: attachments,
                    modelSupportsImageInput: modelSupportsImageInput,
                    resumeContext: resumeContext,
                    memoryContext: memoryContext
                )
            } catch is CancellationError {
                // `cancelActiveTurn()` already updates HUD and completion state.
            } catch {
                guard self.activeTurnID == turnID else { return }
                self.handleTurnCompleted([
                    "turn": [
                        "status": "failed",
                        "error": [
                            "message": error.localizedDescription
                        ]
                    ]
                ])
            }
        }

        activeOllamaTurnTask = turnTask
        await turnTask.value
        if activeOllamaTurnTask?.isCancelled != false || activeTurnID != turnID {
            activeOllamaTurnTask = nil
            return
        }
        activeOllamaTurnTask = nil
    }

    private func runOllamaTurn(
        sessionID: String,
        modelID: String,
        prompt: String,
        attachments: [AssistantAttachment],
        modelSupportsImageInput: Bool,
        resumeContext: String?,
        memoryContext: String?
    ) async throws {
        var messages = ollamaMessageHistoryBySessionID[sessionID] ?? []
        if messages.isEmpty {
            let instructions = await buildInstructions()
            if let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                messages.append(
                    AssistantOllamaChatMessage(
                        role: .system,
                        content: instructions
                    )
                )
            }
        }

        let userMessage = ollamaUserMessage(
            prompt: prompt,
            attachments: attachments,
            modelSupportsImageInput: modelSupportsImageInput,
            resumeContext: resumeContext,
            memoryContext: memoryContext
        )
        if userMessage.content.nonEmpty != nil || !userMessage.images.isEmpty {
            messages.append(userMessage)
        }
        ollamaMessageHistoryBySessionID[sessionID] = messages

        do {
            while true {
                let response = try await ollamaChatService.streamChat(
                    request: AssistantOllamaChatRequest(
                        model: modelID,
                        messages: messages,
                        tools: ollamaToolSpecs(for: interactionMode)
                    ),
                    onEvent: { [weak self] event in
                        guard let self else { return }
                        await self.handleOllamaStreamEvent(event)
                    }
                )

                if Task.isCancelled {
                    throw CancellationError()
                }

                messages.append(response.message)
                ollamaMessageHistoryBySessionID[sessionID] = messages

                if response.message.toolCalls.isEmpty {
                    await unloadOllamaModelIfNeeded(named: modelID)
                    handleTurnCompleted(["turn": ["status": "completed"]])
                    return
                }

                let toolMessages = try await executeOllamaToolCalls(
                    response.message.toolCalls,
                    sessionID: sessionID
                )
                messages.append(contentsOf: toolMessages)
                ollamaMessageHistoryBySessionID[sessionID] = messages
            }
        } catch {
            await unloadOllamaModelIfNeeded(named: modelID)
            throw error
        }
    }

    private func ollamaUserMessage(
        prompt: String,
        attachments: [AssistantAttachment],
        modelSupportsImageInput: Bool,
        resumeContext: String?,
        memoryContext: String?
    ) -> AssistantOllamaChatMessage {
        var parts: [String] = []

        if let resumeContext = resumeContext?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            parts.append(resumeContext)
        }
        if let memoryContext = memoryContext?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            parts.append(memoryContext)
        }

        let nonImageAttachments = attachments.filter { !$0.isImage }
        if !nonImageAttachments.isEmpty {
            let attachmentLines = nonImageAttachments.map { attachment in
                "[Attached file: \(attachment.filename) (\(attachment.mimeType))]"
            }
            parts.append(attachmentLines.joined(separator: "\n"))
        }

        if let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            parts.append(prompt)
        }

        let imagePayloads = attachments.filter(\.isImage).compactMap { attachment in
            Self.ollamaImagePayload(from: attachment)
        }
        if !imagePayloads.isEmpty && modelSupportsImageInput {
            parts.append("If images are attached, analyze those images directly before using tools.")
        }

        return AssistantOllamaChatMessage(
            role: .user,
            content: parts.joined(separator: "\n\n"),
            images: imagePayloads
        )
    }

    private func handleOllamaStreamEvent(_ event: AssistantOllamaStreamEvent) {
        switch event {
        case .assistantTextDelta(let delta):
            ensureStreamingIdentifiers()
            streamingBuffer += delta
            pendingStreamingDeltaBuffer += delta
            emitStreamingAssistantDelta(force: shouldForceStreamingDeltaFlush(for: delta))
        case .toolCalls:
            updateHUD(phase: .acting, title: "Working", detail: "Ollama requested a tool.")
        }
    }

    private func ollamaToolSpecs(for mode: AssistantInteractionMode) -> [[String: Any]] {
        dynamicToolSpecs(for: mode).map { spec in
            [
                "type": "function",
                "function": [
                    "name": spec["name"] as? String ?? "",
                    "description": spec["description"] as? String ?? "",
                    "parameters": spec["inputSchema"] as? [String: Any] ?? [:]
                ]
            ]
        }
    }

    private func executeOllamaToolCalls(
        _ toolCalls: [AssistantOllamaToolCall],
        sessionID: String
    ) async throws -> [AssistantOllamaChatMessage] {
        var toolMessages: [AssistantOllamaChatMessage] = []
        for toolCall in toolCalls {
            if Task.isCancelled {
                throw CancellationError()
            }
            let toolMessage = try await executeOllamaToolCall(
                toolCall,
                sessionID: sessionID
            )
            toolMessages.append(toolMessage)
        }
        return toolMessages
    }

    private func executeOllamaToolCall(
        _ toolCall: AssistantOllamaToolCall,
        sessionID: String
    ) async throws -> AssistantOllamaChatMessage {
        let toolName = toolCall.name
        let arguments = toolCall.arguments
        let displayName = dynamicToolDisplayName(toolName)
        let taskSummary = dynamicToolTaskSummary(for: toolName, arguments: arguments)
        let activityID = toolCall.id

        let state = AssistantToolCallState(
            id: activityID,
            title: displayName,
            kind: "dynamicToolCall",
            status: "inProgress",
            detail: compactDetail(taskSummary),
            hudDetail: compactDetail(taskSummary)
        )
        toolCalls[activityID] = state
        publishToolCallsSnapshot()

        let activity = AssistantActivityItem(
            id: activityID,
            sessionID: sessionID,
            turnID: activeTurnID,
            kind: .dynamicToolCall,
            title: displayName,
            status: .running,
            friendlySummary: activitySummary(kind: .dynamicToolCall, title: displayName),
            rawDetails: compactDetail(taskSummary),
            startedAt: Date(),
            updatedAt: Date(),
            source: .runtime
        )
        liveActivities[activityID] = activity
        emitActivityTimelineUpdate(activity, force: true)

        turnToolCallCount += 1
        if let repeatedCommandLimitHit = ollamaRepeatedCommandLimitHit(
            toolName: toolName,
            arguments: arguments
        ) {
            let repeatedCommand = compactDetail(repeatedCommandLimitHit.command) ?? "Command"
            let message = "Stopped this turn because the same command repeated \(repeatedCommandLimitHit.attemptCount) times in a row: \(repeatedCommand)"
            onTranscript?(AssistantTranscriptEntry(role: .system, text: message, emphasis: true))
            emitTimelineSystemMessage(message, emphasis: true)
            toolCalls.removeValue(forKey: activityID)
            liveActivities.removeValue(forKey: activityID)
            publishToolCallsSnapshot()
            handleTurnCompleted(["turn": ["status": "interrupted"]])
            throw CancellationError()
        }

        if maxToolCallsPerTurn > 0 && turnToolCallCount >= maxToolCallsPerTurn {
            let message = "Reached the tool call limit (\(maxToolCallsPerTurn)). Turn was automatically stopped."
            onTranscript?(AssistantTranscriptEntry(role: .system, text: message, emphasis: true))
            emitTimelineSystemMessage(message, emphasis: true)
            toolCalls.removeValue(forKey: activityID)
            liveActivities.removeValue(forKey: activityID)
            publishToolCallsSnapshot()
            handleTurnCompleted(["turn": ["status": "interrupted"]])
            throw CancellationError()
        }

        let result = try await resolveOllamaToolResult(
            toolName: toolName,
            arguments: arguments,
            sessionID: sessionID,
            taskSummary: taskSummary
        )

        applyToolResultToLiveActivity(activityID: activityID, result: result)
        toolCalls.removeValue(forKey: activityID)
        publishToolCallsSnapshot()

        if var completedActivity = liveActivities.removeValue(forKey: activityID) {
            completedActivity.status = result.success ? .completed : .failed
            completedActivity.updatedAt = Date()
            emitActivityTimelineUpdate(completedActivity, force: true)
            if !result.success {
                emitActivityImageTimelineUpdateIfNeeded(for: completedActivity)
            }
        }

        let screenshotDataItems = Self.imageDataItems(in: result.contentItems)
        if !screenshotDataItems.isEmpty {
            let imageTitle = result.success
                ? "Screenshot from \(displayName)"
                : "Last screenshot before \(displayName) failed"
            // Use the activityID as a stable identifier so re-emitting for the same
            // tool call upserts (replaces) the existing timeline item instead of
            // creating duplicates.
            onTimelineMutation?(
                .upsert(
                    .system(
                        id: "tool-screenshot-\(activityID)",
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

        return AssistantOllamaChatMessage(
            role: .tool,
            content: ollamaToolMessageContent(from: result),
            toolName: toolName
        )
    }

    private func resolveOllamaToolResult(
        toolName: String,
        arguments: Any,
        sessionID: String,
        taskSummary: String
    ) async throws -> AssistantToolExecutionResult {
        guard let descriptor = toolExecutor.descriptor(for: toolName),
              let toolKind = dynamicToolKind(for: toolName) else {
            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: "Open Assist does not support the dynamic tool `\(toolName)` yet.", imageURL: nil)],
                success: false,
                summary: "Unsupported dynamic tool."
            )
        }

        let requiresExplicitConfirmation = descriptor.requiresExplicitConfirmation(arguments)
        let approvalContextDisplayName: String?
        let approvalKind: String
        if toolName == AssistantComputerUseToolDefinition.name {
            let appContext = await computerUseService.frontmostAppContext()
            approvalContextDisplayName = appContext.displayName
            approvalKind = requiresExplicitConfirmation
                ? toolKind
                : AssistantComputerUseService.sessionApprovalKey(for: appContext)
        } else {
            approvalContextDisplayName = nil
            approvalKind = toolKind
        }

        if toolName == AssistantAppActionToolDefinition.name,
           let parsed = try? AssistantAppActionService.parseRequest(from: arguments),
           let app = parsed.app,
           app.usesNativeAccess {
            return try await runOllamaToolExecution(
                toolName: toolName,
                arguments: arguments,
                sessionID: sessionID,
                taskSummary: taskSummary
            )
        }

        if toolName != AssistantImageGenerationToolDefinition.name {
            if requiresExplicitConfirmation
                || !isDynamicToolApproved(toolKind: approvalKind, for: sessionID) {
                let decision = await presentOllamaToolPermissionRequest(
                    toolName: toolName,
                    arguments: arguments,
                    sessionID: sessionID,
                    taskSummary: taskSummary,
                    approvalKind: approvalKind,
                    requiresExplicitConfirmation: requiresExplicitConfirmation,
                    approvalContextDisplayName: approvalContextDisplayName
                )

                switch decision {
                case .allowForSession:
                    rememberDynamicToolApproval(toolKind: approvalKind, for: sessionID)
                case .allowOnce:
                    break
                case .decline(let message):
                    return AssistantToolExecutionResult(
                        contentItems: [.init(type: "inputText", text: message, imageURL: nil)],
                        success: false,
                        summary: message
                    )
                case .cancel(let message):
                    onStatusMessage?(message)
                    await cancelActiveTurn()
                    throw CancellationError()
                }
            }
        }

        return try await runOllamaToolExecution(
            toolName: toolName,
            arguments: arguments,
            sessionID: sessionID,
            taskSummary: taskSummary
        )
    }

    private enum OllamaToolPermissionDecision {
        case allowForSession
        case allowOnce
        case decline(String)
        case cancel(String)
    }

    private func presentOllamaToolPermissionRequest(
        toolName: String,
        arguments: Any,
        sessionID: String,
        taskSummary: String,
        approvalKind: String,
        requiresExplicitConfirmation: Bool,
        approvalContextDisplayName: String?
    ) async -> OllamaToolPermissionDecision {
        let displayName = dynamicToolDisplayName(toolName)
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
        options.append(AssistantPermissionOption(id: "decline", title: "Decline", kind: approvalKind, isDefault: false))
        options.append(AssistantPermissionOption(id: "cancel", title: "Cancel Turn", kind: approvalKind, isDefault: false))

        let request = AssistantPermissionRequest(
            id: Int.random(in: 1...(Int.max / 4)),
            sessionID: sessionID,
            toolTitle: displayName,
            toolKind: approvalKind,
            rationale: dynamicToolPermissionRationale(
                toolName: toolName,
                taskSummary: taskSummary,
                requiresExplicitConfirmation: requiresExplicitConfirmation,
                targetDisplayName: approvalContextDisplayName
            ),
            options: options,
            rawPayloadSummary: taskSummary
        )

        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<OllamaToolPermissionDecision, Never>) in
            pendingPermissionContext = PendingPermissionContext(
                request: request,
                selectHandler: { optionID in
                    switch optionID {
                    case "acceptForSession":
                        continuation.resume(returning: .allowForSession)
                    case "accept":
                        continuation.resume(returning: .allowOnce)
                    case "cancel":
                        continuation.resume(returning: .cancel("\(displayName) was canceled for this turn."))
                    default:
                        continuation.resume(returning: .decline("\(displayName) was declined for this request."))
                    }
                },
                cancelHandler: {
                    continuation.resume(returning: .cancel("\(displayName) was canceled for this turn."))
                }
            )
            onPermissionRequest?(request)
            onTranscript?(AssistantTranscriptEntry(role: .permission, text: "Ollama wants to use \(displayName).", emphasis: true))
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

        pendingPermissionContext = nil
        onPermissionRequest?(nil)
        return decision
    }

    private func runOllamaToolExecution(
        toolName: String,
        arguments: Any,
        sessionID: String,
        taskSummary: String
    ) async throws -> AssistantToolExecutionResult {
        var browserLoginResume = false

        while true {
            let verdict = await preflightPermissionCheck(toolName: toolName, arguments: arguments)
            if !verdict.satisfied {
                return AssistantToolExecutionResult(
                    contentItems: [.init(type: "inputText", text: verdict.message, imageURL: nil)],
                    success: false,
                    summary: verdict.message
                )
            }

            let workingDetail = toolExecutor.workingDetail(for: toolName, browserLoginResume: browserLoginResume)
            updateHUD(phase: .acting, title: dynamicToolDisplayName(toolName), detail: workingDetail)

            let result = await toolExecutor.execute(
                AssistantToolExecutionContext(
                    toolName: toolName,
                    arguments: arguments,
                    attachments: currentTurnAttachments,
                    sessionID: sessionID,
                    assistantNotesContext: assistantNotesContext,
                    preferredModelID: preferredModelID,
                    browserLoginResume: browserLoginResume,
                    interactionMode: interactionMode
                )
            )

            guard let loginPrompt = result.loginPrompt else {
                return result
            }

            let loginDecision = await presentOllamaBrowserLoginRequest(
                prompt: loginPrompt,
                taskSummary: taskSummary
            )
            switch loginDecision {
            case .proceed:
                browserLoginResume = true
                continue
            case .cancel(let message):
                return AssistantToolExecutionResult(
                    contentItems: [.init(type: "inputText", text: message, imageURL: nil)],
                    success: false,
                    summary: message
                )
            }
        }
    }

    private enum OllamaBrowserLoginDecision {
        case proceed
        case cancel(String)
    }

    private func presentOllamaBrowserLoginRequest(
        prompt: AssistantBrowserLoginPrompt,
        taskSummary: String
    ) async -> OllamaBrowserLoginDecision {
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
            id: Int.random(in: 1...(Int.max / 4)),
            sessionID: activeSessionID ?? "",
            toolTitle: prompt.requestTitle,
            toolKind: "browserLogin",
            rationale: prompt.requestRationale,
            options: [proceedOption, cancelOption],
            rawPayloadSummary: prompt.requestSummary
        )

        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<OllamaBrowserLoginDecision, Never>) in
            pendingPermissionContext = PendingPermissionContext(
                request: request,
                selectHandler: { optionID in
                    if optionID == "proceed" {
                        continuation.resume(returning: .proceed)
                    } else {
                        continuation.resume(returning: .cancel("Browser sign-in was canceled for this turn."))
                    }
                },
                cancelHandler: {
                    continuation.resume(returning: .cancel("Browser sign-in was canceled for this turn."))
                }
            )
            onPermissionRequest?(request)
            onTranscript?(AssistantTranscriptEntry(role: .permission, text: prompt.requestRationale, emphasis: true))
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

        pendingPermissionContext = nil
        onPermissionRequest?(nil)
        return decision
    }

    private func ollamaRepeatedCommandLimitHit(
        toolName: String,
        arguments: Any
    ) -> AssistantRepeatedCommandLimitHit? {
        guard toolName == AssistantExecCommandToolDefinition.name,
              let request = try? AssistantShellExecutionService.parseExecCommandRequest(from: arguments) else {
            return nil
        }

        return repeatedCommandTracker.record(
            command: request.command,
            maxAttempts: maxRepeatedCommandAttemptsPerTurn
        )
    }

    private func ollamaToolMessageContent(from result: AssistantToolExecutionResult) -> String {
        let parts = result.contentItems.compactMap { item -> String? in
            if let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                return text
            }
            if item.type == "inputImage", item.imageURL != nil {
                return "[Image output omitted]"
            }
            return nil
        }

        if !parts.isEmpty {
            return parts.joined(separator: "\n")
        }
        if let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return summary
        }
        return result.success ? "Tool completed successfully." : "Tool failed."
    }

    private static func ollamaImagePayload(from attachment: AssistantAttachment) -> String? {
        guard attachment.isImage else { return nil }
        let dataURL = attachment.dataURL
        guard let commaIndex = dataURL.firstIndex(of: ",") else {
            return attachment.data.base64EncodedString()
        }
        let metadata = dataURL[..<commaIndex]
        guard metadata.localizedCaseInsensitiveContains("base64") else {
            return attachment.data.base64EncodedString()
        }
        return String(dataURL[dataURL.index(after: commaIndex)...])
    }

    private func copilotRequestWithTimeout(
        method: String,
        params: [String: Any],
        timeoutNanoseconds: UInt64
    ) async throws -> CodexResponsePayload {
        try await requestWithTimeout(
            method: method,
            params: params,
            timeoutNanoseconds: timeoutNanoseconds
        )
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

    func sendRequest(method: String, params: [String: Any]) async throws -> CodexResponsePayload {
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
        case .processExited(let message, let expected):
            guard !expected else { return }
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
            claudeStreamingToolUseInputs.removeAll()
            claudeStreamingAwaitingToolExecution = false
            onPlanUpdate?(firstNonEmptyString(params["threadId"] as? String, activeSessionID), [])
            resetStreamingTimelineState()
            updateHUD(phase: .thinking, title: "Thinking", detail: nil)
            onHealthUpdate?(makeHealth(availability: .active, summary: "Codex is working"))
        case "turn/plan/updated":
            onPlanUpdate?(firstNonEmptyString(params["threadId"] as? String, activeSessionID), parsePlanEntries(from: params["plan"]))
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
        let hadPublishedAgents = !activeSubagents.isEmpty || !copilotBackgroundTasksByID.isEmpty
        guard hadPublishedAgents else {
            if publish {
                onSubagentUpdate?([])
            }
            return
        }

        activeSubagents.removeAll()
        copilotBackgroundTasksByID.removeAll()
        copilotBackgroundTaskIDByToolCallID.removeAll()
        if publish {
            onSubagentUpdate?([])
        }
    }

    private func publishSubagents() {
        let publishedBackgroundTasks = copilotBackgroundTasksByID.values.map {
            subagentState(from: $0)
        }
        let sorted = (Array(activeSubagents.values) + publishedBackgroundTasks).sorted { a, b in
            if a.status.isActive != b.status.isActive { return a.status.isActive }
            let lhsDate = a.lastEventAt ?? .distantPast
            let rhsDate = b.lastEventAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return a.id < b.id
        }
        onSubagentUpdate?(Array(sorted))
    }

    private func subagentState(from task: CopilotBackgroundTaskRecord) -> SubagentState {
        let detail = task.detailText
        return SubagentState(
            id: "copilot-task-\(task.id)",
            parentThreadID: task.sessionID ?? activeSessionID,
            threadID: nil,
            nickname: task.description,
            role: task.agentType,
            status: task.subagentStatus,
            prompt: detail,
            startedAt: task.startedAt,
            updatedAt: task.updatedAt,
            endedAt: task.completedAt
        )
    }

    private func handleRateLimitsUpdated(_ params: [String: Any]) {
        guard let limits = AccountRateLimits.fromPayload(params, preserving: currentRateLimits) else { return }
        currentRateLimits = limits
        onRateLimitsUpdate?(limits)
    }

    private func startRateLimitRefreshLoopIfNeeded() {
        cancelRateLimitRefreshLoop()
        guard backend == .claudeCode,
              activeTurnID != nil,
              currentAccountSnapshot.isLoggedIn else {
            return
        }

        let refreshTaskID = UUID()
        rateLimitRefreshTaskID = refreshTaskID
        rateLimitRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.refreshRateLimits()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.claudeCodeRateLimitRefreshIntervalNanoseconds)
                } catch {
                    break
                }

                guard !Task.isCancelled,
                      self.backend == .claudeCode,
                      self.activeTurnID != nil,
                      self.currentAccountSnapshot.isLoggedIn else {
                    break
                }

                await self.refreshRateLimits()
            }

            guard self.rateLimitRefreshTaskID == refreshTaskID else { return }
            self.rateLimitRefreshTask = nil
        }
    }

    private func cancelRateLimitRefreshLoop() {
        rateLimitRefreshTaskID = UUID()
        rateLimitRefreshTask?.cancel()
        rateLimitRefreshTask = nil
    }

    /// Lightweight background refresh that keeps the usage display current even
    /// when no turn is active. Runs every 90 seconds.
    private func startIdleRateLimitRefreshIfNeeded() {
        idleRateLimitRefreshTask?.cancel()
        idleRateLimitRefreshTask = nil

        guard backend == .claudeCode, currentAccountSnapshot.isLoggedIn else { return }

        idleRateLimitRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.claudeCodeIdleRateLimitRefreshIntervalNanoseconds)
                } catch {
                    break
                }

                guard let self,
                      !Task.isCancelled,
                      self.backend == .claudeCode,
                      self.activeTurnID == nil,
                      self.currentAccountSnapshot.isLoggedIn else {
                    break
                }

                await self.refreshRateLimits()
            }
        }
    }

    private func cancelIdleRateLimitRefresh() {
        idleRateLimitRefreshTask?.cancel()
        idleRateLimitRefreshTask = nil
    }

    private func publishExecutionStateSnapshot() {
        onExecutionStateUpdate?(hasActiveTurn, hasLiveClaudeProcess)
    }

    private func enqueueClaudeQueuedPromptContext(
        attachments: [AssistantAttachment],
        modelSupportsImageInput: Bool
    ) {
        activeClaudeQueuedPromptContexts.append(
            ClaudeQueuedPromptContext(
                attachments: attachments,
                includesImageAttachments: attachments.contains(where: \.isImage),
                modelSupportsImageInput: modelSupportsImageInput,
                allowsProposedPlan: interactionMode == .plan
            )
        )
    }

    private func activateCurrentClaudeQueuedPromptContextIfNeeded() {
        guard let context = activeClaudeQueuedPromptContexts.first else {
            currentTurnAttachments = []
            currentTurnIncludesImageAttachments = false
            currentTurnModelSupportsImageInput = false
            currentTurnHadSuccessfulImageGeneration = false
            redirectedImageToolCallForActiveTurn = false
            blockedToolUseHandledForActiveTurn = false
            blockedToolUseInterruptionMessage = nil
            proposedPlanBuffer = ""
            allowsProposedPlanForActiveTurn = false
            claudeStreamingToolUseInputs.removeAll()
            claudeStreamingAwaitingToolExecution = false
            return
        }

        currentTurnAttachments = context.attachments
        currentTurnIncludesImageAttachments = context.includesImageAttachments
        currentTurnModelSupportsImageInput = context.modelSupportsImageInput
        currentTurnHadSuccessfulImageGeneration = false
        redirectedImageToolCallForActiveTurn = false
        blockedToolUseHandledForActiveTurn = false
        blockedToolUseInterruptionMessage = nil
        proposedPlanBuffer = ""
        allowsProposedPlanForActiveTurn = context.allowsProposedPlan
        claudeStreamingToolUseInputs.removeAll()
        claudeStreamingAwaitingToolExecution = false
        turnToolCallCount = 0
        repeatedCommandTracker.reset()
    }

    @discardableResult
    private func dequeueCurrentClaudeQueuedPromptContext() -> ClaudeQueuedPromptContext? {
        guard !activeClaudeQueuedPromptContexts.isEmpty else { return nil }
        return activeClaudeQueuedPromptContexts.removeFirst()
    }

    private func cancelClaudeCodeIdleTimeoutTask() {
        claudeCodeIdleTimeoutTask?.cancel()
        claudeCodeIdleTimeoutTask = nil
    }

    private func recordClaudeCodeActivity() {
        lastClaudeCodeActivityAt = Date()
        scheduleClaudeCodeIdleTimeoutIfNeeded()
    }

    private func scheduleClaudeCodeIdleTimeoutIfNeeded() {
        cancelClaudeCodeIdleTimeoutTask()
        guard hasLiveClaudeProcess,
              activeTurnID == nil,
              pendingPermissionContext == nil else {
            return
        }

        claudeCodeIdleTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: Self.claudeCodeLiveProcessIdleTimeoutNanoseconds)
            } catch {
                return
            }

            guard self.hasLiveClaudeProcess,
                  self.activeTurnID == nil,
                  self.pendingPermissionContext == nil else {
                return
            }

            self.terminateActiveClaudeProcess(expected: true)
            self.updateHUD(phase: .idle, title: "Session ready", detail: nil)
            self.publishExecutionStateSnapshot()
            self.onHealthUpdate?(self.makeHealth(
                availability: .ready,
                summary: self.backend.connectedSummary
            ))
        }
    }

    private func waitForActiveClaudeTurnCompletion() async throws -> AssistantTurnCompletionStatus {
        return try await withCheckedThrowingContinuation { continuation in
            activeClaudeTurnContinuations.append(continuation)
        }
    }

    private func resolveNextActiveClaudeTurnContinuation(
        status: AssistantTurnCompletionStatus,
        error: Error? = nil
    ) {
        guard !activeClaudeTurnContinuations.isEmpty else { return }
        let continuation = activeClaudeTurnContinuations.removeFirst()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: status)
        }
    }

    private func resolveAllActiveClaudeTurnContinuations(
        status: AssistantTurnCompletionStatus,
        error: Error? = nil
    ) {
        guard !activeClaudeTurnContinuations.isEmpty else { return }
        let continuations = activeClaudeTurnContinuations
        activeClaudeTurnContinuations.removeAll()
        for continuation in continuations {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: status)
            }
        }
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
            await presentMCPElicitationRequest(id: id, params: params)
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

    private func presentMCPElicitationRequest(
        id: JSONRPCRequestID,
        params: [String: Any]
    ) async {
        let requestID = approvalRequestID(from: id)
        if pendingPermissionContext?.request.id == requestID {
            return
        }

        let rawMessage = firstNonEmptyString(
            params["message"] as? String,
            params["prompt"] as? String,
            "Codex needs more information."
        ) ?? "Codex needs more information."
        let message = Self.sanitizedMCPElicitationText(rawMessage)
        let sessionID = params["threadId"] as? String ?? activeSessionID ?? ""
        let requestedSchema = (params["requestedSchema"] as? [String: Any])
            ?? (params["requested_schema"] as? [String: Any])
        let mode = firstNonEmptyString(params["mode"] as? String)?.lowercased()
        let url = firstNonEmptyString(params["url"] as? String)
        let title = Self.mcpElicitationTitle(for: message)

        if mode == "url", let url {
            let options = [
                AssistantPermissionOption(id: "accept", title: "I Opened It", kind: "userInput", isDefault: true),
                AssistantPermissionOption(id: "decline", title: "Decline", kind: "userInput", isDefault: false),
                AssistantPermissionOption(id: "cancel", title: "Cancel Request", kind: "userInput", isDefault: false)
            ]
            let request = AssistantPermissionRequest(
                id: requestID,
                sessionID: sessionID,
                toolTitle: title,
                toolKind: "userInput",
                rationale: "\(message)\n\(url)",
                options: options,
                rawPayloadSummary: url
            )

            pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
                guard let self else { return }
                let action: String
                switch optionID {
                case "accept":
                    action = "accept"
                case "decline":
                    action = "decline"
                default:
                    action = "cancel"
                }

                do {
                    try await self.transport?.sendResponse(
                        id: id,
                        result: Self.simpleMCPElicitationConfirmationResponse(
                            action: action,
                            requestedSchema: requestedSchema
                        )
                    )
                } catch {
                    await MainActor.run {
                        self.onStatusMessage?(error.localizedDescription)
                    }
                }
            } cancelHandler: { [weak self] in
                guard let self else { return }
                do {
                    try await self.transport?.sendResponse(id: id, result: ["action": "cancel"])
                } catch {
                    await MainActor.run {
                        self.onStatusMessage?(error.localizedDescription)
                    }
                }
            }

            onPermissionRequest?(request)
            onTranscript?(AssistantTranscriptEntry(role: .permission, text: message, emphasis: true))
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
            onStatusMessage?(message)
            updateHUD(phase: .waitingForPermission, title: "Input Needed", detail: url)
            return
        }

        if Self.isSimpleMCPElicitationConfirmation(
            message: message,
            requestedSchema: requestedSchema
        ) {
            let options = [
                AssistantPermissionOption(id: "accept", title: "Allow", kind: "userInput", isDefault: true),
                AssistantPermissionOption(id: "decline", title: "Decline", kind: "userInput", isDefault: false),
                AssistantPermissionOption(id: "cancel", title: "Cancel", kind: "userInput", isDefault: false)
            ]
            let request = AssistantPermissionRequest(
                id: requestID,
                sessionID: sessionID,
                toolTitle: title,
                toolKind: "userInput",
                rationale: message,
                options: options,
                rawPayloadSummary: compactDetail(message)
            )

            pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
                guard let self else { return }
                let action: String
                switch optionID {
                case "accept":
                    action = "accept"
                case "decline":
                    action = "decline"
                default:
                    action = "cancel"
                }

                do {
                    try await self.transport?.sendResponse(id: id, result: ["action": action])
                } catch {
                    await MainActor.run {
                        self.onStatusMessage?(error.localizedDescription)
                    }
                }
            } cancelHandler: { [weak self] in
                guard let self else { return }
                do {
                    try await self.transport?.sendResponse(id: id, result: ["action": "cancel"])
                } catch {
                    await MainActor.run {
                        self.onStatusMessage?(error.localizedDescription)
                    }
                }
            }

            onPermissionRequest?(request)
            onTranscript?(AssistantTranscriptEntry(role: .permission, text: message, emphasis: true))
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
            onStatusMessage?(message)
            updateHUD(phase: .waitingForPermission, title: "Approve Access", detail: title)
            return
        }

        let questions = Self.parseClaudeCodeElicitationQuestions(
            message: message,
            requestedSchema: requestedSchema
        )
        let request = AssistantPermissionRequest(
            id: requestID,
            sessionID: sessionID,
            toolTitle: title,
            toolKind: "userInput",
            rationale: message,
            options: [],
            userInputQuestions: questions,
            rawPayloadSummary: compactDetail(message)
        )

        pendingPermissionContext = PendingPermissionContext(request: request) { _ in
        } submitAnswersHandler: { [weak self] answers in
            guard let self else { return }
            var response: [String: Any] = ["action": "accept"]
            let content = Self.buildClaudeCodeElicitationContent(
                from: answers,
                requestedSchema: requestedSchema
            )
            if !content.isEmpty {
                response["content"] = content
            }

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
                try await self.transport?.sendResponse(id: id, result: ["action": "cancel"])
            } catch {
                await MainActor.run {
                    self.onStatusMessage?(error.localizedDescription)
                }
            }
        }

        onPermissionRequest?(request)
        onTranscript?(AssistantTranscriptEntry(role: .permission, text: message, emphasis: true))
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
        onStatusMessage?(message)
        updateHUD(phase: .waitingForPermission, title: "Input Needed", detail: title)
    }

    private func handleDynamicToolCall(id: JSONRPCRequestID, params: [String: Any]) async {
        let tool = dynamicToolName(from: params) ?? "Tool"
        let activityID = dynamicToolRequestActivityID(from: params)

        guard let descriptor = toolExecutor.descriptor(for: tool),
              let toolKind = dynamicToolKind(for: tool) else {
            do {
                try await transport?.sendResponse(
                    id: id,
                    result: dynamicToolResponseResult(
                        contentItems: [[
                            "type": "input_text",
                            "text": "Open Assist does not support the dynamic tool `\(tool)` yet."
                        ]],
                        success: false
                    )
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
        let taskSummary = descriptor.summaryProvider(arguments)
        let displayName = descriptor.displayName
        let requiresExplicitConfirmation = descriptor.requiresExplicitConfirmation(arguments)
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
                arguments: arguments,
                activityID: activityID
            )
            return
        }

        if tool == AssistantImageGenerationToolDefinition.name {
            await executeDynamicToolCall(
                toolName: tool,
                requestID: id,
                arguments: arguments,
                activityID: activityID,
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
                activityID: activityID,
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
                    activityID: activityID,
                    sessionID: sessionID
                )
            case "accept":
                await self.executeDynamicToolCall(
                    toolName: tool,
                    requestID: id,
                    arguments: arguments,
                    activityID: activityID,
                    sessionID: sessionID
                )
            case "cancel":
                let message = "\(displayName) was canceled for this turn."
                do {
                    try await self.transport?.sendResponse(
                        id: id,
                        result: self.dynamicToolResponseResult(
                            contentItems: [["type": "input_text", "text": message]],
                            success: false
                        )
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
                        result: self.dynamicToolResponseResult(
                            contentItems: [["type": "input_text", "text": message]],
                            success: false
                        )
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
                    result: self.dynamicToolResponseResult(
                        contentItems: [["type": "input_text", "text": message]],
                        success: false
                    )
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
        activityID: String? = nil,
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
                    result: dynamicToolResponseResult(
                        contentItems: failedResult.contentItems.map { $0.dictionaryRepresentation() },
                        success: false
                    )
                )
            } catch {
                await MainActor.run { self.onStatusMessage?(error.localizedDescription) }
            }
            onStatusMessage?(verdict.message)
            updateHUD(phase: .failed, title: "\(displayName) failed", detail: verdict.message)
            return
        }

        let workingDetail: String
        let result: AssistantToolExecutionResult
        workingDetail = toolExecutor.workingDetail(for: toolName, browserLoginResume: browserLoginResume)
        updateHUD(phase: .acting, title: displayName, detail: workingDetail)
        result = await toolExecutor.execute(
            AssistantToolExecutionContext(
                toolName: toolName,
                arguments: arguments,
                attachments: currentTurnAttachments,
                sessionID: sessionID ?? activeSessionID ?? "",
                assistantNotesContext: assistantNotesContext,
                preferredModelID: preferredModelID,
                browserLoginResume: browserLoginResume,
                interactionMode: interactionMode
            )
        )
        applyToolResultToLiveActivity(activityID: activityID, result: result)
        if let prompt = result.loginPrompt {
            await presentBrowserLoginRequest(
                id: requestID,
                arguments: arguments,
                prompt: prompt,
                taskSummary: dynamicToolTaskSummary(for: toolName, arguments: arguments)
            )
            return
        }

        do {
            try await transport?.sendResponse(
                id: requestID,
                result: dynamicToolResponseResult(
                    contentItems: result.contentItems.map { $0.dictionaryRepresentation() },
                    success: result.success
                )
            )
            let markerIDs = dynamicToolSuccessMarkerIDs(
                activityID: activityID,
                requestID: requestID
            )
            if result.success {
                markerIDs.forEach { locallySuccessfulDynamicToolCallIDs.insert($0) }
            } else {
                markerIDs.forEach { locallySuccessfulDynamicToolCallIDs.remove($0) }
            }
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
        if result.success, toolName == AssistantImageGenerationToolDefinition.name {
            currentTurnHadSuccessfulImageGeneration = true
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
                if pendingPermissionContext != nil {
                    updateHUD(phase: .waitingForPermission, title: "Waiting for approval", detail: nil)
                } else {
                    updateHUD(phase: .acting, title: "Working", detail: nil)
                }
            } else if flags.contains("waitingOnUserInput") {
                if pendingPermissionContext?.request.toolKind == "userInput" {
                    updateHUD(phase: .waitingForPermission, title: "Waiting for input", detail: nil)
                } else {
                    updateHUD(phase: .acting, title: "Working", detail: nil)
                }
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
                result: dynamicToolResponseResult(
                    contentItems: [["type": "input_text", "text": message]],
                    success: false
                )
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
        let finalizedStreamingText = correctedAssistantImageFailureFallbackIfNeeded(streamingBuffer)
        onTranscriptMutation?(
            .upsert(
                AssistantTranscriptEntry(
                    id: entryID,
                    role: .assistant,
                    text: finalizedStreamingText,
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
                        text: finalizedStreamingText,
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
           finalizedStreamingText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil {
            proposedPlanBuffer = finalizedStreamingText
            onProposedPlan?(finalizedStreamingText)
            emitPlanTimeline(text: finalizedStreamingText, isStreaming: false)
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
            let locallySucceeded = locallySuccessfulDynamicToolCallIDs.contains(activity.id)
            let imageToolSucceeded = imageToolCompletionLooksSuccessful(item)

            if let existing = liveActivities[activity.id] {
                if activity.rawDetails?.nonEmpty == nil {
                    activity.rawDetails = existing.rawDetails
                }
                if activity.automationMetadata == nil {
                    activity.automationMetadata = existing.automationMetadata
                }
                if activity.updatedAt < existing.updatedAt {
                    activity.updatedAt = existing.updatedAt
                }
            }

            if isCompleted {
                if locallySucceeded || imageToolSucceeded || activity.status.isActive {
                    activity.status = .completed
                }
                if dynamicToolName(from: item) == AssistantImageGenerationToolDefinition.name,
                   activity.status == .completed {
                    currentTurnHadSuccessfulImageGeneration = true
                }
                locallySuccessfulDynamicToolCallIDs.remove(activity.id)
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
        cancelPendingCopilotPromptCompletion()
        cancelPendingClaudeCompletion()
        materializeCopilotFallbackReplyIfNeeded()
        let completedTurnResponse = correctedAssistantImageFailureFallbackIfNeeded(streamingBuffer)
        let responsePreview = completedTurnResponse.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        flushStreamingBuffer()
        flushCommentaryBuffer()
        cancelRateLimitRefreshLoop()
        var completionStatus = AssistantTurnCompletionStatus.completed
        defer {
            allowsProposedPlanForActiveTurn = false
            activeTurnID = nil
            pendingCopilotFallbackReply = nil
            pendingCopilotSlashCommand = nil
            pendingCopilotSlashCommandActivityID = nil
            pendingCopilotSessionTransitionCommand = nil
            activeClaudeQueuedPromptContexts.removeAll()
            currentTurnAttachments = []
            currentTurnHadSuccessfulImageGeneration = false
            publishExecutionStateSnapshot()
            scheduleClaudeCodeIdleTimeoutIfNeeded()
        }

        guard let turn = params["turn"] as? [String: Any] else {
            resolveNextActiveClaudeTurnContinuation(status: completionStatus)
            updateHUD(phase: .success, title: "Finished", detail: responsePreview)
            return
        }

        let status = turn["status"] as? String ?? "completed"
        switch status {
        case "completed":
            completionStatus = .completed
            finalizeActiveActivities(with: .completed)
            onTurnCompletion?(.completed)
            // Turn completion is shown via HUD phase, no transcript status needed.
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
            completionStatus = .interrupted
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
            completionStatus = .failed(message: errorText)
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

        switch completionStatus {
        case .failed(let message):
            resolveAllActiveClaudeTurnContinuations(
                status: completionStatus,
                error: CodexAssistantRuntimeError.requestFailed(message)
            )
        case .interrupted:
            resolveAllActiveClaudeTurnContinuations(status: completionStatus)
        default:
            resolveNextActiveClaudeTurnContinuation(status: completionStatus)
        }

        if backend == .claudeCode, currentAccountSnapshot.isLoggedIn {
            Task { await refreshRateLimits() }
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
        delta.contains("\n\n")
            || delta.contains("\r\n\r\n")
            || delta.contains("```")
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
              !pendingStreamingDeltaBuffer.isEmpty else {
            if force {
                pendingStreamingTranscriptEmit?.cancel()
                pendingStreamingTranscriptEmit = nil
                pendingAssistantTimelineEmit?.cancel()
                pendingAssistantTimelineEmit = nil
            }
            return
        }

        // Keep a tiny coalescing window so streamed text feels live without
        // flooding persistence and UI observers on every token-sized update.
        let minimumInterval: CFAbsoluteTime = 1.0 / 60.0
        let emit = { [weak self] in
            guard let self,
                  let entryID = self.streamingEntryID,
                  let timelineID = self.streamingTimelineID,
                  !self.pendingStreamingDeltaBuffer.isEmpty else { return }
            let delta = self.pendingStreamingDeltaBuffer
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

        let minimumInterval: CFAbsoluteTime = 1.0 / 30.0
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
        let minimumInterval: CFAbsoluteTime = 1.0 / 30.0

        let emit = { [weak self] in
            guard let self else { return }
            let latestActivity = force ? activity : (self.liveActivities[activityID] ?? activity)
            self.onTimelineMutation?(.upsert(.activity(latestActivity)))
            self.onActivityItemUpdate?(latestActivity)
            Task { await AssistantTaskProgressStore.shared.upsert(latestActivity) }
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

    private func applyToolResultToLiveActivity(
        activityID: String?,
        result: AssistantToolExecutionResult
    ) {
        guard let activityID,
              var activity = liveActivities[activityID] else {
            return
        }

        if let metadata = result.activityMetadata {
            activity.automationMetadata = metadata
        }

        if let plannerLine = automationPlannerLine(from: result.activityMetadata) {
            let summaryLine = compactDetail(result.summary)
            let mergedDetail = [plannerLine, summaryLine]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
                .joined(separator: "\n")
            if !mergedDetail.isEmpty {
                activity.rawDetails = mergedDetail
            }
        } else if let summaryLine = compactDetail(result.summary) {
            activity.rawDetails = summaryLine
        }

        if let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            activity.friendlySummary = summary
        }

        activity.updatedAt = Date()
        liveActivities[activityID] = activity
        emitActivityTimelineUpdate(activity, force: true)
    }

    private func automationPlannerLine(
        from metadata: AssistantAutomationActivityMetadata?
    ) -> String? {
        guard let metadata else { return nil }
        var parts: [String] = []
        if let stage = metadata.stage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            parts.append(stage)
        }
        if let actuator = metadata.actuator?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            parts.append(actuator)
        }
        if let target = metadata.target?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            parts.append(target)
        }
        if let verification = metadata.verificationResult?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            parts.append("verification: \(verification)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " • ")
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

    private func emitTimelineSystemMessage(
        _ text: String,
        sessionID: String? = nil,
        turnID: String? = nil,
        emphasis: Bool = false
    ) {
        guard let text = text.nonEmpty else { return }
        onTimelineMutation?(
            .upsert(
                .system(
                    sessionID: sessionID ?? activeSessionID,
                    turnID: turnID ?? activeTurnID,
                    text: text,
                    createdAt: Date(),
                    emphasis: emphasis,
                    providerBackend: backend,
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
        locallySuccessfulDynamicToolCallIDs.removeAll()
        toolCalls.removeAll()
        pendingToolCallEmit?.cancel()
        pendingToolCallEmit = nil
        if hadVisibleActivity {
            onToolCallUpdate?([])
        }
    }

    private func resetStreamingTimelineState() {
        cancelPendingCopilotPromptCompletion()
        cancelPendingClaudeCompletion()
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
        locallySuccessfulDynamicToolCallIDs.removeAll()
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
        pendingCopilotSlashCommand = nil
        pendingCopilotSlashCommandActivityID = nil
        pendingCopilotSessionTransitionCommand = nil
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
            return "Used \(title)."
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

    func cliAttachmentContextForTesting(
        sessionID: String,
        attachments: [AssistantAttachment]
    ) throws -> String? {
        try resolvedCLIAttachmentContext(sessionID: sessionID, attachments: attachments)
    }

    func clearCLIAttachmentsForTesting() {
        clearPersistedCLIAttachmentMaterialization()
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

    func recordSuccessfulDynamicToolCallForTesting(id: String) {
        locallySuccessfulDynamicToolCallIDs.insert(id)
    }

    func recordSuccessfulDynamicToolCallForTesting(
        requestID: String,
        params: [String: Any],
        success: Bool = true
    ) {
        let markerIDs = dynamicToolSuccessMarkerIDs(
            activityID: dynamicToolRequestActivityID(from: params),
            requestID: .string(requestID)
        )
        if success {
            markerIDs.forEach { locallySuccessfulDynamicToolCallIDs.insert($0) }
        } else {
            markerIDs.forEach { locallySuccessfulDynamicToolCallIDs.remove($0) }
        }
    }

    func dynamicToolRequestActivityIDForTesting(from params: [String: Any]) -> String? {
        dynamicToolRequestActivityID(from: params)
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

    func setCurrentTurnHadSuccessfulImageGenerationForTesting(_ value: Bool) {
        currentTurnHadSuccessfulImageGeneration = value
    }

    func shouldRedirectBlockedImageToolRequestForTesting(method: String) -> Bool {
        interactionMode != .agentic
            && method == "item/tool/call"
            && currentTurnIncludesImageAttachments
            && currentTurnModelSupportsImageInput
            && !redirectedImageToolCallForActiveTurn
    }

    func dynamicToolNamesForTesting(mode: AssistantInteractionMode) -> [String] {
        dynamicToolSpecs(for: mode).compactMap { spec in
            spec["name"] as? String
        }
    }

    func setSelectedCodexPluginIDsForTesting(_ pluginIDs: [String]) {
        setSelectedCodexPluginIDs(pluginIDs)
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
        attachments: [AssistantAttachment] = [],
        attachmentContext: String? = nil,
        modelID: String? = "gpt-5.4"
    ) -> [String: Any] {
        let previousMode = interactionMode
        interactionMode = mode
        defer { interactionMode = previousMode }
        return turnStartParams(
            threadID: threadID,
            prompt: prompt,
            attachments: attachments,
            attachmentContext: attachmentContext,
            modelID: modelID
        )
    }

    func threadStartParamsForTesting(
        mode: AssistantInteractionMode = .agentic,
        cwd: String? = nil,
        modelID: String? = "gpt-5.4"
    ) async -> [String: Any] {
        let previousMode = interactionMode
        interactionMode = mode
        defer { interactionMode = previousMode }
        return await threadStartParams(cwd: cwd, modelID: modelID)
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
        turnID: String? = nil,
        cwd: String? = nil
    ) {
        activeSessionID = sessionID
        activeTurnID = turnID
        activeSessionCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
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
        await handleIncomingEvent(.processExited(message: message, expected: false))
    }

    func processServerRequestForTesting(
        method: String,
        params: [String: Any]
    ) async {
        await handleServerRequest(id: .string("test-request"), method: method, params: params)
    }

    func processCopilotSessionUpdateForTesting(
        _ update: [String: Any],
        forceBackend: Bool = true
    ) async {
        if forceBackend {
            backend = .copilot
        }
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

    func processCopilotPromptCompletionForTesting(
        raw: [String: Any] = [:],
        stopReason: String? = nil,
        finalizePendingCompletion: Bool = true
    ) {
        backend = .copilot
        var payload = raw
        if let stopReason {
            payload["stopReason"] = stopReason
        }
        handleCopilotPromptCompletion(from: payload)
        if finalizePendingCompletion {
            flushPendingCopilotPromptCompletionForTesting()
        }
    }

    func flushPendingCopilotPromptCompletionForTesting() {
        guard let pendingParams = pendingCopilotCompletionParams else { return }
        pendingCopilotCompletionEmit?.cancel()
        pendingCopilotCompletionEmit = nil
        pendingCopilotCompletionParams = nil
        handleTurnCompleted(pendingParams)
    }

    static func shouldDeferCopilotPromptCompletion(
        elapsedSinceLastUpdate: Double,
        hasLiveActivity: Bool,
        hasVisibleAssistantOutput: Bool,
        hasPendingPermissionRequest: Bool
    ) -> Bool {
        let quietPeriodSeconds = Double(copilotCompletionQuietPeriodNanoseconds) / 1_000_000_000
        guard elapsedSinceLastUpdate >= quietPeriodSeconds else {
            return true
        }

        if hasPendingPermissionRequest {
            return true
        }

        guard hasLiveActivity else {
            return false
        }

        if hasVisibleAssistantOutput {
            let activityGraceSeconds = Double(copilotCompletionActivityGracePeriodNanoseconds) / 1_000_000_000
            return elapsedSinceLastUpdate < activityGraceSeconds
        }

        let hardTimeoutSeconds = Double(copilotCompletionHardTimeoutNanoseconds) / 1_000_000_000
        return elapsedSinceLastUpdate < hardTimeoutSeconds
    }

    static func shouldAcceptCopilotLiveUpdate(
        updateTurnID: String?,
        activeTurnID: String?
    ) -> Bool {
        guard let activeTurnID = activeTurnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return false
        }

        guard let updateTurnID = updateTurnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return true
        }

        return updateTurnID.caseInsensitiveCompare(activeTurnID) == .orderedSame
    }

    func resolvedCopilotRequestedModelIDForTesting(_ preferredModelID: String?) -> String? {
        backend = .copilot
        return resolvedCopilotRequestedModelID(preferredModelID)
    }

    func processClaudeCodeOutputLineForTesting(_ line: String) {
        backend = .claudeCode
        handleClaudeCodeOutputLine(line)
    }

    func flushPendingClaudeCompletionForTesting() {
        guard let pendingClaudeCompletionEmit else { return }
        pendingClaudeCompletionEmit.cancel()
        self.pendingClaudeCompletionEmit = nil
        if activeTurnID == nil || pendingPermissionContext != nil {
            return
        }

        if activeClaudeQueuedPromptContexts.count > 1 {
            handleClaudeCodeIntermediateCompletion()
        } else {
            handleTurnCompleted(["turn": ["status": "completed"]])
        }
    }

    func claudeCodeUserMessagePayloadForTesting(content: String) -> [String: Any] {
        Self.claudeCodeUserMessagePayload(content: content, sessionID: activeSessionID)
    }

    func claudeCodeElicitationContentForTesting(
        answers: [String: [String]],
        requestedSchema: [String: Any]?
    ) -> [String: Any] {
        Self.buildClaudeCodeElicitationContent(
            from: answers,
            requestedSchema: requestedSchema
        )
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
                result: dynamicToolResponseResult(
                    contentItems: [["type": "input_text", "text": message]],
                    success: false
                )
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
            return mcpToolCallPresentation(
                server: server,
                tool: tool,
                arguments: item["arguments"]
            ).title
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

    private func mcpToolCallPresentation(
        server rawServer: String,
        tool rawTool: String,
        arguments: Any?
    ) -> (title: String, detail: String?, hudDetail: String?) {
        let server = rawServer.trimmingCharacters(in: .whitespacesAndNewlines)
        let tool = rawTool.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedServer = server.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let normalizedTool = tool.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        if normalizedServer.contains("computer-use") {
            let appName = mcpToolArgumentString(arguments, key: "app")
            switch normalizedTool {
            case "list_apps":
                return (
                    title: "Computer Use",
                    detail: "Checking which Mac apps are available",
                    hudDetail: "Checking your apps"
                )
            case "get_app_state":
                if let appName {
                    return (
                        title: appName,
                        detail: "Checking \(appName)",
                        hudDetail: "Looking at \(appName)"
                    )
                }
                return (
                    title: "Computer Use",
                    detail: "Checking the current app",
                    hudDetail: "Looking at the app"
                )
            default:
                if let appName {
                    return (
                        title: appName,
                        detail: "Using Computer Use in \(appName)",
                        hudDetail: "Working in \(appName)"
                    )
                }
                return (
                    title: "Computer Use",
                    detail: humanizedClaudeStreamingToolFragment(tool) ?? tool,
                    hudDetail: "Using Computer Use"
                )
            }
        }

        let serverDisplay = humanizedClaudeStreamingToolFragment(server)
            ?? assistantDisplayPluginName(pluginName: server)
        let toolDisplay = humanizedClaudeStreamingToolFragment(tool)
            ?? assistantDisplayPluginName(pluginName: tool)
        return (
            title: "\(serverDisplay): \(toolDisplay)",
            detail: compactDetail(extractString(arguments)),
            hudDetail: "Using \(toolDisplay)"
        )
    }

    private func mcpToolArgumentString(
        _ arguments: Any?,
        key: String
    ) -> String? {
        if let dictionary = arguments as? [String: Any] {
            return extractString(dictionary[key])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        }

        if let rawString = arguments as? String,
           let data = rawString.data(using: .utf8),
           let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return extractString(dictionary[key])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        }

        return nil
    }

    private func dynamicToolDisplayName(_ rawTool: String?) -> String {
        toolExecutor.descriptor(for: rawTool)?.displayName ?? rawTool ?? "Tool"
    }

    private func dynamicToolKind(for rawTool: String?) -> String? {
        toolExecutor.descriptor(for: rawTool)?.toolKind
    }

    private func dynamicToolTaskSummary(for toolName: String, arguments: Any) -> String {
        toolExecutor.descriptor(for: toolName)?.summaryProvider(arguments) ?? "Use a dynamic tool"
    }

    private func dynamicToolResponseResult(
        contentItems: [[String: Any]],
        success: Bool
    ) -> [String: Any] {
        [
            "content": contentItems,
            "contentItems": contentItems,
            "success": success,
            "isError": !success
        ]
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
        let lead = toolExecutor.descriptor(for: toolName)?.permissionLeadText
            ?? "This tool can control parts of your Mac."

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
        guard let descriptor = toolExecutor.descriptor(for: toolName) else { return false }
        return descriptor.requiresExplicitConfirmation(arguments)
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
                    result: dynamicToolResponseResult(
                        contentItems: [["type": "input_text", "text": message]],
                        success: false
                    )
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

    private nonisolated static func serializedClaudeToolInput(_ raw: Any?) -> String {
        if let text = raw as? String {
            return text
        }
        guard let raw else { return "" }
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    private nonisolated static func parseClaudeCodePlanEntriesFromToolUse(
        name: String?,
        input: Any?
    ) -> [AssistantPlanEntry]? {
        guard let normalizedName = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return nil
        }

        func parseJSONObject(_ raw: Any?) -> [String: Any]? {
            if let dictionary = raw as? [String: Any] {
                return dictionary
            }
            guard let text = raw as? String,
                  let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json
        }

        func parseRows(
            _ rows: [[String: Any]],
            contentKeys: [String],
            statusKey: String = "status"
        ) -> [AssistantPlanEntry] {
            rows.compactMap { row in
                let content = contentKeys
                    .compactMap { key in row[key] as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? "Plan step"
                let status = (row[statusKey] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty ?? "pending"
                return AssistantPlanEntry(content: content, status: status)
            }
        }

        switch normalizedName {
        case "update_plan":
            if let rows = input as? [[String: Any]] {
                return parseRows(rows, contentKeys: ["step", "content"])
            }
            guard let inputObject = parseJSONObject(input) else { return [] }
            if let rows = inputObject["plan"] as? [[String: Any]] {
                return parseRows(rows, contentKeys: ["step", "content"])
            }
            if let rows = inputObject["items"] as? [[String: Any]] {
                return parseRows(rows, contentKeys: ["step", "content"])
            }
            return []
        case "todowrite":
            guard let inputObject = parseJSONObject(input),
                  let rows = inputObject["todos"] as? [[String: Any]] else {
                return []
            }
            return parseRows(rows, contentKeys: ["content", "activeForm"])
        default:
            return nil
        }
    }

    private func publishToolCallsSnapshot() {
        onToolCallUpdate?(toolCalls.values.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        })
    }

    private func parsedClaudeStreamingToolInput(_ inputJSON: String) -> [String: Any]? {
        guard let data = inputJSON.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else {
            return nil
        }
        return object
    }

    private func humanizedClaudeStreamingToolFragment(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        let spaced = trimmed
            .replacingOccurrences(of: "__", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(
                of: #"([a-z0-9])([A-Z])"#,
                with: "$1 $2",
                options: .regularExpression
            )
        return spaced
            .split(whereSeparator: \.isWhitespace)
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
            .nonEmpty
    }

    private func claudeStreamingToolPathSummary(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }

        if let path = firstNonEmptyString(
            extractString(input["file_path"]),
            extractString(input["path"]),
            extractString(input["filepath"]),
            extractString(input["target_file"]),
            extractString(input["target_path"])
        ) {
            return compactDetail(path)
        }

        if let paths = input["paths"] as? [Any] {
            let rendered = paths.compactMap { extractString($0) }
            if let firstPath = rendered.first, rendered.count == 1 {
                return compactDetail(firstPath)
            }
            if rendered.count > 1 {
                return "\(rendered.count) paths"
            }
        }

        return nil
    }

    private func claudeStreamingToolCallState(
        id: String,
        rawName: String,
        inputJSON: String
    ) -> AssistantToolCallState {
        let normalizedName = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let input = parsedClaudeStreamingToolInput(inputJSON)
        let serializedDetail = compactDetail(inputJSON)

        if normalizedName.hasPrefix("mcp__") {
            let parts = rawName.split(separator: "__", omittingEmptySubsequences: false)
            let serverName = parts.count > 1
                ? humanizedClaudeStreamingToolFragment(String(parts[1])) ?? "MCP"
                : "MCP"
            let toolName = parts.count > 2
                ? humanizedClaudeStreamingToolFragment(String(parts[2])) ?? "Tool"
                : humanizedClaudeStreamingToolFragment(rawName) ?? "Tool"
            let presentation = mcpToolCallPresentation(
                server: serverName,
                tool: toolName,
                arguments: input ?? [:]
            )
            return AssistantToolCallState(
                id: id,
                title: presentation.title,
                kind: "mcpToolCall",
                status: "inProgress",
                detail: presentation.detail ?? serializedDetail,
                hudDetail: presentation.hudDetail ?? "Using \(toolName)"
            )
        }

        switch normalizedName {
        case "bash", "localbash", "powershell", "sandboxnetworkaccess":
            let command = firstNonEmptyString(
                extractString(input?["command"]),
                extractString(input?["cmd"]),
                extractString(input?["script"]),
                serializedDetail
            )
            let hudDetail = command.map { friendlyCommandSummary($0) } ?? "Running command"
            return AssistantToolCallState(
                id: id,
                title: "Command",
                kind: "commandExecution",
                status: "inProgress",
                detail: compactDetail(command),
                hudDetail: hudDetail
            )
        case "edit", "multiedit", "write":
            let detail = firstNonEmptyString(
                claudeStreamingToolPathSummary(input),
                serializedDetail
            )
            let title = normalizedName == "write" ? "Write File" : "File Changes"
            return AssistantToolCallState(
                id: id,
                title: title,
                kind: "fileChange",
                status: "inProgress",
                detail: detail,
                hudDetail: detail.map { "Editing \($0)" } ?? "Editing files"
            )
        case "read":
            let detail = firstNonEmptyString(
                claudeStreamingToolPathSummary(input),
                serializedDetail
            )
            return AssistantToolCallState(
                id: id,
                title: "Read File",
                kind: "tool",
                status: "inProgress",
                detail: detail,
                hudDetail: detail.map { "Reading \($0)" } ?? "Reading file"
            )
        case "glob", "grep", "search", "find":
            let detail = firstNonEmptyString(
                extractString(input?["pattern"]),
                extractString(input?["query"]),
                claudeStreamingToolPathSummary(input),
                serializedDetail
            )
            return AssistantToolCallState(
                id: id,
                title: humanizedClaudeStreamingToolFragment(rawName) ?? "Search Files",
                kind: "tool",
                status: "inProgress",
                detail: detail,
                hudDetail: detail.map { "Searching \($0)" } ?? "Searching files"
            )
        case "ls":
            let detail = firstNonEmptyString(
                claudeStreamingToolPathSummary(input),
                serializedDetail
            )
            return AssistantToolCallState(
                id: id,
                title: "List Files",
                kind: "tool",
                status: "inProgress",
                detail: detail,
                hudDetail: detail.map { "Listing \($0)" } ?? "Listing files"
            )
        case "webfetch", "web_fetch":
            let detail = firstNonEmptyString(
                extractString(input?["url"]),
                serializedDetail
            )
            return AssistantToolCallState(
                id: id,
                title: "Web Fetch",
                kind: "webSearch",
                status: "inProgress",
                detail: detail,
                hudDetail: detail.map { "Fetching \($0)" } ?? "Fetching web page"
            )
        case "websearch", "web_search":
            let detail = firstNonEmptyString(
                extractString(input?["query"]),
                serializedDetail
            )
            return AssistantToolCallState(
                id: id,
                title: "Web Search",
                kind: "webSearch",
                status: "inProgress",
                detail: detail,
                hudDetail: detail.map { "Searching \($0)" } ?? "Searching the web"
            )
        case let value where value.contains("browser"):
            return AssistantToolCallState(
                id: id,
                title: "Browser",
                kind: "browserAutomation",
                status: "inProgress",
                detail: serializedDetail,
                hudDetail: "Browsing"
            )
        case "task":
            let detail = firstNonEmptyString(
                extractString(input?["description"]),
                extractString(input?["prompt"]),
                extractString(input?["task"]),
                serializedDetail
            )
            return AssistantToolCallState(
                id: id,
                title: "Subagent",
                kind: "collabAgentToolCall",
                status: "inProgress",
                detail: detail,
                hudDetail: "Delegating"
            )
        case "update_plan", "todowrite":
            return AssistantToolCallState(
                id: id,
                title: normalizedName == "todowrite" ? "Todo Write" : "Plan Update",
                kind: "tool",
                status: "inProgress",
                detail: serializedDetail,
                hudDetail: "Updating plan"
            )
        default:
            let displayName = humanizedClaudeStreamingToolFragment(rawName) ?? "Tool"
            return AssistantToolCallState(
                id: id,
                title: displayName,
                kind: "tool",
                status: "inProgress",
                detail: serializedDetail,
                hudDetail: "Using \(displayName)"
            )
        }
    }

    private func upsertClaudeStreamingToolUse(
        id: String,
        name: String,
        inputJSON: String
    ) {
        let state = claudeStreamingToolCallState(id: id, rawName: name, inputJSON: inputJSON)
        toolCalls[id] = state
        let activityKind = activityKind(from: state.kind)
        let activity = AssistantActivityItem(
            id: id,
            sessionID: activeSessionID,
            turnID: activeTurnID,
            kind: activityKind,
            title: state.title,
            status: parsedActivityStatus(from: state.status, fallback: .running),
            friendlySummary: activitySummary(kind: activityKind, title: state.title),
            rawDetails: compactDetail(state.detail),
            startedAt: liveActivities[id]?.startedAt ?? Date(),
            updatedAt: Date(),
            source: .runtime
        )
        liveActivities[id] = activity
        emitActivityTimelineUpdate(activity)
        publishToolCallsSnapshot()
    }

    private func removeClaudeStreamingToolUse(forIndex index: Int) -> (id: String, name: String, inputJSON: String)? {
        guard let toolUse = claudeStreamingToolUseInputs.removeValue(forKey: index) else {
            return nil
        }
        toolCalls.removeValue(forKey: toolUse.id)
        if var activity = liveActivities.removeValue(forKey: toolUse.id) {
            activity.status = .completed
            activity.updatedAt = Date()
            emitActivityTimelineUpdate(activity, force: true)
        }
        publishToolCallsSnapshot()
        return toolUse
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
            let presentation = mcpToolCallPresentation(
                server: item["server"] as? String ?? "MCP",
                tool: item["tool"] as? String ?? "tool",
                arguments: item["arguments"]
            )
            return AssistantToolCallState(
                id: id,
                title: presentation.title,
                kind: type,
                status: status,
                detail: presentation.detail ?? compactDetail(extractString(item["arguments"])),
                hudDetail: presentation.hudDetail ?? "Using \(presentation.title)"
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
    var assistantNotesContext: AssistantNotesRuntimeContext?
    var activeSkills: [AssistantSkillDescriptor] = []
    var reasoningEffort: String?
    var serviceTier: String?
    var interactionMode: AssistantInteractionMode = .agentic
    private var currentTurnIncludesImageAttachments = false
    private var currentTurnModelSupportsImageInput = false
    private var currentTurnHadSuccessfulImageGeneration = false
    private var redirectedImageToolCallForActiveTurn = false
    private var blockedToolUseHandledForActiveTurn = false
    private var blockedToolUseInterruptionMessage: String?

    // Proposed plan streaming: accumulates item/plan/delta content
    private var proposedPlanBuffer: String = ""
    private var allowsProposedPlanForActiveTurn = false
    private var claudeStreamingToolUseInputs: [Int: (id: String, name: String, inputJSON: String)] = [:]
    /// When true, the most recent message_delta had stop_reason "tool_use",
    /// meaning the CLI will execute tools before producing the next assistant
    /// message.  While this flag is set, message_stop must NOT schedule a
    /// deferred completion because the turn is still in progress.
    private var claudeStreamingAwaitingToolExecution = false

    /// Session IDs that have been detached. Notifications from these sessions are dropped.
    private var detachedSessionIDs: Set<String> = []

    private static let codexComputerUsePluginIDs: Set<String> = [
        "computer-use@openai-bundled",
        "computer-use@openai-curated"
    ]

    private static let localDesktopAutomationToolNames: Set<String> = [
        AssistantAppActionToolDefinition.name,
        AssistantBrowserUseToolDefinition.name,
        AssistantComputerUseToolDefinition.name,
        AssistantComputerBatchToolDefinition.name,
        "screen_capture",
        "window_list",
        "window_capture",
        "list_displays",
        "ui_inspect",
        "ui_click",
        "ui_type",
        "ui_press_key"
    ]

    func setSelectedCodexPluginIDs(_ pluginIDs: [String]) {
        selectedCodexPluginIDs = Set(
            pluginIDs.compactMap(Self.normalizedCodexPluginID)
        )
    }

    private static func normalizedCodexPluginID(_ rawValue: String?) -> String? {
        rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nonEmpty
    }

    private var shouldPreferCodexComputerUsePlugin: Bool {
        backend == .codex
            && !selectedCodexPluginIDs.isDisjoint(with: Self.codexComputerUsePluginIDs)
    }

    private func dynamicToolSpecs(for mode: AssistantInteractionMode) -> [[String: Any]] {
        var specs = toolExecutor.dynamicToolSpecs(for: mode, backend: backend)
        guard shouldPreferCodexComputerUsePlugin else {
            return specs
        }

        specs.removeAll { spec in
            guard let name = (spec["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty else {
                return false
            }
            return Self.localDesktopAutomationToolNames.contains(name)
        }
        return specs
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

    private func dynamicToolRequestActivityID(from payload: [String: Any]) -> String? {
        let candidatePayloads: [[String: Any]] = [
            payload,
            payload["item"] as? [String: Any],
            payload["toolCall"] as? [String: Any],
            payload["tool_call"] as? [String: Any]
        ].compactMap { $0 }

        for candidate in candidatePayloads {
            if let activityID = firstNonEmptyString(
                candidate["itemId"] as? String,
                candidate["item_id"] as? String,
                candidate["callId"] as? String,
                candidate["call_id"] as? String,
                candidate["id"] as? String
            ) {
                return activityID
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
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            params["cwd"] = cwd
        }
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
            Use the provider's native plan behavior when available.
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

        sections.append(workspaceBoundaryInstructions())

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

    private func workspaceBoundaryInstructions() -> String {
        if let workspacePath = activeSessionCWD?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return """
            # Workspace Boundary

            This thread is attached to the workspace `\(workspacePath)`.
            Stay inside this workspace unless the user clearly asks you to inspect somewhere else.
            Do NOT search parent folders, sibling projects, or the user's home directory just to find a likely app, repo, or file.
            You may still read thread-attached skills, direct attachments, or files the user explicitly points you to.
            If the needed files appear to be outside this workspace, pause and ask the user to attach the right project or explicitly allow broader exploration.
            """
        }

        return """
        # Workspace Boundary

        This thread does not have an attached workspace folder.
        Do NOT scan the user's home directory or unrelated folders trying to guess where the project lives.
        Work only with the files already provided in the thread, thread-attached skills, or paths the user explicitly names.
        If you need project files that are not already attached, ask the user to attach a project folder or explicitly allow exploration outside the current thread context.
        """
    }

    private func activeSkillInstructionsBlock() -> String? {
        let resolvedSkills = activeSkills
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

        guard !resolvedSkills.isEmpty else { return nil }

        struct ActiveSkillInstructionEntry {
            let skill: AssistantSkillDescriptor
            let fullMarkdown: String
        }

        let entries = resolvedSkills.map { skill in
            ActiveSkillInstructionEntry(
                skill: skill,
                fullMarkdown: (try? String(contentsOf: skill.skillFileURL, encoding: .utf8)) ?? ""
            )
        }

        let lines = entries.map { entry in
            let skill = entry.skill
            let summary = skill.summaryText
                .replacingOccurrences(
                    of: #"\s+"#,
                    with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suggestedPrompt = skill.defaultPrompt?
                .replacingOccurrences(
                    of: #"\s+"#,
                    with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            let promptLine = suggestedPrompt.map { prompt in
                "\n  Suggested prompt: \(prompt)"
            } ?? ""
            return """
            - `\(skill.name)`: \(summary)
              Skill file: `\(skill.skillFilePath)`\(promptLine)
            """
        }

        let skillBlocks = entries.map { entry in
            let loadedMarkdown = entry.fullMarkdown
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
                ?? "SKILL.md could not be loaded from disk for this attached skill."
            return """
            <skill>
            Name: \(entry.skill.name)
            Path: \(entry.skill.skillFilePath)

            \(loadedMarkdown)
            </skill>
            """
        }

        return """
        # Active Skills

        These skills are attached to the current thread. Treat a thread-attached skill as explicit user intent, not a weak hint.
        If the user asks to use "this skill" or clearly points at an attached skill, open that local `SKILL.md` file before answering in depth.
        If exactly one skill is attached and the request could reasonably match it, prefer that skill before taking a generic path.
        If an attached skill looks unrelated, say that plainly and ask a short clarifying question instead of silently ignoring it.
        The full attached skill files are injected below in `<skill>` blocks. Follow those injected instructions the same way you would follow an explicitly selected skill.

        ## Attached Skill List

        \(lines.joined(separator: "\n"))

        ## Injected Skill Files

        \(skillBlocks.joined(separator: "\n\n"))
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

        Keep the work in the same signed-in browser session. Use `browser_use` first for opening sites, activating the browser, reading the current tab, and detecting when a manual login is needed. If the visible browser chrome or page controls are exposed through macOS Accessibility, prefer `ui_inspect`, `ui_click`, `ui_type`, and `ui_press_key` before pixel-based control. Use `osascript` against "\(appName)" only for simple reads or navigation that stay in the same browser window.

        \(computerUseEnabled
            ? "Use `computer_use` only as a last resort when the task truly depends on visible pixels in the already-open browser window and cannot be completed with `browser_use`, the Accessibility UI tools, or simple browser scripting in that same session."
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
        attachmentContext: String? = nil,
        modelID: String?,
        resumeContext: String? = nil,
        memoryContext: String? = nil,
        structuredInputItems: [AssistantCodexPromptInputItem] = []
    ) -> [String: Any] {
        var inputItems: [[String: Any]] = []
        // Add attachment items first so the model sees them before the prompt text
        for attachment in attachments {
            inputItems.append(attachment.toInputItem())
        }
        if let attachmentContext = attachmentContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !attachmentContext.isEmpty {
            inputItems.append(["type": "text", "text": attachmentContext])
        }
        if let resumeContext = resumeContext?.trimmingCharacters(in: .whitespacesAndNewlines), !resumeContext.isEmpty {
            inputItems.append(["type": "text", "text": resumeContext])
        }
        if let memoryContext = memoryContext?.trimmingCharacters(in: .whitespacesAndNewlines), !memoryContext.isEmpty {
            inputItems.append(["type": "text", "text": memoryContext])
        }
        inputItems.append(contentsOf: structuredInputItems.map { $0.toJSON() })
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

    private func dynamicToolActivityID(for id: JSONRPCRequestID) -> String {
        switch id {
        case .int(let value):
            return String(value)
        case .string(let value):
            return value
        }
    }

    private func dynamicToolSuccessMarkerIDs(
        activityID: String?,
        requestID: JSONRPCRequestID
    ) -> [String] {
        let fallbackID = dynamicToolActivityID(for: requestID)
        var ids: [String] = []

        if let normalizedActivityID = activityID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !normalizedActivityID.isEmpty {
            ids.append(normalizedActivityID)
        }

        if !ids.contains(fallbackID) {
            ids.append(fallbackID)
        }

        return ids
    }

    private func correctedAssistantImageFailureFallbackIfNeeded(_ text: String) -> String {
        guard currentTurnHadSuccessfulImageGeneration else { return text }

        let replacements: [(String, String)] = [
            (
                "The image tool failed again, so I’m making",
                "I already generated an image above, and I’m also making"
            ),
            (
                "The image tool failed again, so I'm making",
                "I already generated an image above, and I’m also making"
            ),
            (
                "The image tool failed, so I’m making",
                "I already generated an image above, and I’m also making"
            ),
            (
                "The image tool failed, so I'm making",
                "I already generated an image above, and I’m also making"
            ),
            (
                "Image generation failed again, so I’m making",
                "I already generated an image above, and I’m also making"
            ),
            (
                "Image generation failed again, so I'm making",
                "I already generated an image above, and I’m also making"
            ),
            (
                "Image generation failed, so I’m making",
                "I already generated an image above, and I’m also making"
            ),
            (
                "Image generation failed, so I'm making",
                "I already generated an image above, and I’m also making"
            )
        ]

        for (source, replacement) in replacements {
            if text.range(of: source, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return text.replacingOccurrences(
                    of: source,
                    with: replacement,
                    options: [.caseInsensitive, .diacriticInsensitive]
                )
            }
        }

        return text
    }

    private func imageToolCompletionLooksSuccessful(_ item: [String: Any]) -> Bool {
        guard normalizedActivityType(item["type"] as? String) == "dynamicToolCall",
              dynamicToolName(from: item) == AssistantImageGenerationToolDefinition.name else {
            return false
        }

        if rawContainsGeneratedImageContent(item["result"]) || rawContainsGeneratedImageContent(item["output"]) {
            return true
        }

        let summary = firstNonEmptyString(
            extractString(item["result"]),
            extractString(item["output"]),
            item["summary"] as? String
        )?.lowercased()

        guard let summary else { return false }
        return summary.contains("generated an image")
            || summary.contains("generated images")
            || summary.contains("here is your generated image")
    }

    private func rawContainsGeneratedImageContent(_ raw: Any?) -> Bool {
        switch raw {
        case let text as String:
            let normalized = text.lowercased()
            return normalized.contains("data:image/")
                || normalized.contains("generated an image")
                || normalized.contains("generated images")
        case let dictionary as [String: Any]:
            if let type = dictionary["type"] as? String,
               type == "inputImage" {
                return true
            }

            if let imageURL = dictionary["image_url"] as? String,
               imageURL.lowercased().contains("data:image/") {
                return true
            }

            if let imageURL = dictionary["imageURL"] as? String,
               imageURL.lowercased().contains("data:image/") {
                return true
            }

            if rawContainsGeneratedImageContent(dictionary["image_url"])
                || rawContainsGeneratedImageContent(dictionary["imageURL"])
                || rawContainsGeneratedImageContent(dictionary["url"]) {
                return true
            }

            for value in dictionary.values {
                if rawContainsGeneratedImageContent(value) {
                    return true
                }
            }

            return false
        case let array as [Any]:
            return array.contains { rawContainsGeneratedImageContent($0) }
        default:
            return false
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

    private func refreshClaudeCodeEnvironment(cwd: String?) async throws -> AssistantEnvironmentDetails {
        guard await resolvedExecutablePath() != nil else {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Claude Code is not installed on this Mac.")
        }

        let account = try await refreshAccountState()
        let models = try await refreshModels()
        await refreshRateLimits()
        startIdleRateLimitRefreshIfNeeded()

        let health = makeHealth(
            availability: account.isLoggedIn
                ? (activeTurnID == nil ? .ready : .active)
                : .loginRequired,
            summary: account.isLoggedIn ? backend.connectedSummary : backend.loginRequiredSummary,
            detail: account.isLoggedIn ? nil : "Run `claude auth login` in Terminal, then return to Open Assist."
        )
        onHealthUpdate?(health)
        return AssistantEnvironmentDetails(health: health, account: account, models: models)
    }

    private func resolvedClaudeCodeWorkingDirectory(_ cwd: String?) -> String {
        resolvedCopilotWorkingDirectory(cwd)
    }

    private func signedInClaudeCodeAccountSnapshot(email: String?, planType: String?) -> AssistantAccountSnapshot {
        AssistantAccountSnapshot(
            authMode: .chatGPT,
            email: email?.nonEmpty ?? "Claude Code",
            planType: planType?.nonEmpty,
            requiresOpenAIAuth: false,
            loginInProgress: false,
            pendingLoginURL: nil,
            pendingLoginID: nil
        )
    }

    private func refreshClaudeCodeAccountState() async throws -> AssistantAccountSnapshot {
        guard let executablePath = await resolvedExecutablePath() else {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Claude Code is not installed on this Mac.")
        }
        let result = try await runClaudeCodeCommand(
            executablePath: executablePath,
            arguments: ["auth", "status", "--json"],
            workingDirectory: nil,
            trackAsActiveTurn: false
        )
        guard result.exitCode == 0 else {
            throw CodexAssistantRuntimeError.requestFailed(
                Self.commandFailureMessage(
                    stdout: result.stdout,
                    stderr: result.stderr,
                    fallback: "Claude Code auth status failed."
                )
            )
        }
        return try Self.parseClaudeCodeAccountSnapshot(from: result.stdout)
    }

    private func staticClaudeCodeModels() -> [AssistantModelOption] {
        [
            AssistantModelOption(
                id: "sonnet",
                displayName: "Claude Sonnet",
                description: "Balanced Claude Code model alias.",
                isDefault: false,
                hidden: false,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            ),
            AssistantModelOption(
                id: "opus",
                displayName: "Claude Opus",
                description: "Higher-capability Claude Code model alias.",
                isDefault: true,
                hidden: false,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            )
        ]
    }

    private func startClaudeCodeSession(
        cwd: String?,
        preferredModelID: String?,
        announce: Bool
    ) async throws -> String {
        guard await resolvedExecutablePath() != nil else {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Claude Code is not installed on this Mac.")
        }

        let resolvedCWD = resolvedClaudeCodeWorkingDirectory(cwd)
        if announce {
            toolCalls.removeAll()
            liveActivities.removeAll()
            clearSubagents(publish: false)
            repeatedCommandTracker.reset()
            resetStreamingTimelineState()
            onToolCallUpdate?([])
            onPlanUpdate?(activeSessionID, [])
            onSubagentUpdate?([])
            onTimelineMutation?(.reset(sessionID: nil))
            onPermissionRequest?(nil)
            sessionTurnCount = 0
            firstTurnUserPrompt = nil
        }

        terminateActiveClaudeProcess(expected: true)
        let sessionID = UUID().uuidString.lowercased()
        activeSessionID = sessionID
        activeSessionCWD = resolvedCWD
        currentTokenUsageSnapshot = .empty
        onTokenUsageUpdate?(currentTokenUsageSnapshot)
        if let requestedModelID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            self.preferredModelID = requestedModelID
        }

        if announce {
            onSessionChange?(sessionID)
            onTranscript?(AssistantTranscriptEntry(role: .system, text: backend.startedSessionMessage, emphasis: true))
        }

        onHealthUpdate?(makeHealth(availability: .ready, summary: backend.connectedSummary))
        updateHUD(phase: .idle, title: "Assistant is ready", detail: nil)
        return sessionID
    }

    private func resumeClaudeCodeSession(
        _ sessionID: String,
        cwd: String?,
        preferredModelID: String?,
        announce: Bool
    ) async throws {
        guard await resolvedExecutablePath() != nil else {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Claude Code is not installed on this Mac.")
        }

        let resolvedCWD = resolvedClaudeCodeWorkingDirectory(cwd)
        if activeClaudeProcessSessionID?.caseInsensitiveCompare(sessionID) != .orderedSame {
            terminateActiveClaudeProcess(expected: true)
        }
        activeSessionID = sessionID
        activeSessionCWD = resolvedCWD
        sessionTurnCount = 1
        currentTokenUsageSnapshot = .empty
        onTokenUsageUpdate?(currentTokenUsageSnapshot)
        if let requestedModelID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            self.preferredModelID = requestedModelID
        }

        onSessionChange?(sessionID)
        if announce {
            onTranscript?(AssistantTranscriptEntry(role: .system, text: backend.loadedSessionMessage(sessionID), emphasis: true))
        }
        onHealthUpdate?(makeHealth(availability: .ready, summary: backend.connectedSummary))
        updateHUD(phase: .idle, title: "Session ready", detail: nil)
    }

    private func refreshClaudeCodeCurrentSessionConfiguration(
        sessionID: String,
        cwd: String?,
        preferredModelID: String?
    ) async throws {
        guard await resolvedExecutablePath() != nil else {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Claude Code is not installed on this Mac.")
        }

        activeSessionID = sessionID
        activeSessionCWD = resolvedClaudeCodeWorkingDirectory(cwd)
        let requestedModelID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        if let requestedModelID {
            self.preferredModelID = requestedModelID
        }
        let resolvedPermissionMode = Self.claudeCodePermissionMode(for: interactionMode)
        if hasLiveClaudeProcess,
           activeTurnID == nil,
           pendingPermissionContext == nil,
           (
                activeClaudeProcessSessionID?.caseInsensitiveCompare(sessionID) != .orderedSame
                || activeClaudeProcessWorkingDirectory != activeSessionCWD
                || activeClaudeProcessModelID != requestedModelID
                || activeClaudeProcessPermissionMode != resolvedPermissionMode
           ) {
            terminateActiveClaudeProcess(expected: true)
        }
        onHealthUpdate?(makeHealth(
            availability: activeTurnID == nil ? .ready : .active,
            summary: activeTurnID == nil ? backend.connectedSummary : backend.activeSummary
        ))
    }

    private func sendClaudeCodePrompt(
        sessionID: String,
        prompt: String,
        attachments: [AssistantAttachment],
        preferredModelID: String?,
        modelSupportsImageInput: Bool,
        resumeContext: String?,
        memoryContext: String?
    ) async throws {
        guard let executablePath = await resolvedExecutablePath() else {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Claude Code is not installed on this Mac.")
        }

        if !currentAccountSnapshot.isLoggedIn {
            let account = try await refreshClaudeCodeAccountState()
            guard account.isLoggedIn else {
                throw CodexAssistantRuntimeError.runtimeUnavailable("Run `claude auth login` in Terminal before chatting with Claude Code.")
            }
        }

        let resolvedCWD = resolvedClaudeCodeWorkingDirectory(activeSessionCWD)
        try await refreshClaudeCodeCurrentSessionConfiguration(
            sessionID: sessionID,
            cwd: resolvedCWD,
            preferredModelID: preferredModelID
        )

        let attachmentContext = try resolvedCLIAttachmentContext(
            sessionID: sessionID,
            attachments: attachments
        )
        let fullPrompt = buildClaudeCodePrompt(
            prompt: prompt,
            resumeContext: resumeContext,
            memoryContext: memoryContext,
            attachmentContext: attachmentContext
        )

        let canInjectFollowUpIntoActiveClaudeProcess =
            activeTurnID != nil
            && hasLiveClaudeProcess
            && pendingPermissionContext == nil
            && attachments.isEmpty

        enqueueClaudeQueuedPromptContext(
            attachments: attachments,
            modelSupportsImageInput: modelSupportsImageInput
        )
        if !canInjectFollowUpIntoActiveClaudeProcess {
            activateCurrentClaudeQueuedPromptContextIfNeeded()
            activeTurnID = activeTurnID ?? "claude-turn-\(UUID().uuidString)"
            publishExecutionStateSnapshot()
            updateHUD(phase: .streaming, title: "Starting", detail: nil)
            onHealthUpdate?(makeHealth(availability: .active, summary: backend.activeSummary))
            startRateLimitRefreshLoopIfNeeded()
        } else {
            updateHUD(
                phase: .thinking,
                title: "Queued Follow-Up",
                detail: "Claude will continue with your next message after this reply."
            )
        }

        do {
            try await ensureClaudeCodeLiveProcess(
                executablePath: executablePath,
                sessionID: sessionID,
                workingDirectory: resolvedCWD,
                preferredModelID: preferredModelID
            )

            let payload = Self.claudeCodeUserMessagePayload(
                content: fullPrompt,
                sessionID: sessionID
            )
            recordClaudeCodeActivity()
            try writeClaudeCodeInputMessage(payload)

            let status = try await waitForActiveClaudeTurnCompletion()
            switch status {
            case .completed, .interrupted:
                return
            case .failed(let message):
                throw CodexAssistantRuntimeError.requestFailed(message)
            }
        } catch {
            if activeTurnID != nil {
                handleTurnCompleted([
                    "turn": [
                        "status": "failed",
                        "error": ["message": error.localizedDescription]
                    ]
                ])
            }
            throw error
        }
    }

    private func buildClaudeCodePrompt(
        prompt: String,
        resumeContext: String?,
        memoryContext: String?,
        attachmentContext: String?
    ) -> String {
        var sections: [String] = []
        if let attachmentContext = attachmentContext?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            sections.append(attachmentContext)
        }
        if let memoryContext = memoryContext?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            sections.append("Relevant memory:\n\(memoryContext)")
        }
        if let resumeContext = resumeContext?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            sections.append("Conversation context:\n\(resumeContext)")
        }
        sections.append(prompt)
        return sections.joined(separator: "\n\n")
    }

    private func applyClaudeCodeTokenUsage(
        _ usage: TokenUsageBreakdown,
        modelContextWindow: Int?
    ) {
        let total = Self.addTokenUsageBreakdowns(currentTokenUsageSnapshot.total, usage)
        currentTokenUsageSnapshot = TokenUsageSnapshot(
            last: usage,
            total: total,
            modelContextWindow: modelContextWindow ?? currentTokenUsageSnapshot.modelContextWindow
        )
        onTokenUsageUpdate?(currentTokenUsageSnapshot)
    }

    private func handleClaudeCodeOutputLine(_ line: String) {
        guard let payload = try? Self.parseClaudeCodeJSONObject(from: line) else { return }
        handleClaudeCodeStreamPayload(payload)
    }

    private func handleClaudeCodeStreamPayload(_ payload: [String: Any]) {
        recordClaudeCodeActivity()
        let payloadSessionID = firstNonEmptyString(
            payload["session_id"] as? String,
            payload["sessionId"] as? String,
            activeSessionID
        )
        let payloadType = (payload["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Any incoming payload except "result" (which handles its own
        // completion flow) means the CLI is still producing output and a
        // previously scheduled deferred completion must be invalidated.
        if payloadType != "result" {
            cancelPendingClaudeCompletion()
        }

        switch payloadType {
        case "system":
            updateHUD(
                phase: .thinking,
                title: interactionMode.normalizedForActiveUse == .plan ? "Planning" : "Thinking",
                detail: nil
            )
        case "user":
            updateHUD(
                phase: .thinking,
                title: interactionMode.normalizedForActiveUse == .plan ? "Planning" : "Thinking",
                detail: nil
            )
        case "control_request":
            handleClaudeCodeControlRequest(payload)
        case "control_cancel_request":
            handleClaudeCodeControlCancelRequest(payload)
        case "assistant":
            guard let message = payload["message"] as? [String: Any] else {
                return
            }

            applyClaudeCodePlanEntriesIfNeeded(from: message, sessionID: payloadSessionID)

            guard let text = Self.extractClaudeCodeMessageText(from: message) else {
                return
            }
            guard acceptAssistantMessageDelta(
                threadID: activeSessionID,
                turnID: nil,
                source: "claude.stream.assistant"
            ) else {
                return
            }
            switch applyClaudeSettledReplyCandidate(
                text,
                emitLiveDeltaWhenInstallingInitial: true
            ) {
            case .ignored:
                return
            case .installedAsInitial:
                emitStreamingAssistantDelta(force: true)
            case .replacedExisting:
                break
            }
            updateHUD(
                phase: .streaming,
                title: interactionMode.normalizedForActiveUse == .plan ? "Planning" : "Responding",
                detail: nil
            )
        case "stream_event":
            guard let event = payload["event"] as? [String: Any] else { return }
            handleClaudeCodeStreamEvent(event, sessionID: payloadSessionID)
        case "rate_limit_event":
            Task { await refreshRateLimits() }
        case "result":
            handleClaudeCodeResultPayload(payload)
        default:
            return
        }
    }

    private func applyClaudeCodePlanEntriesIfNeeded(
        from message: [String: Any],
        sessionID: String?
    ) {
        guard let content = message["content"] as? [[String: Any]] else { return }

        for block in content {
            guard (block["type"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "tool_use" else {
                continue
            }

            guard let entries = Self.parseClaudeCodePlanEntriesFromToolUse(
                name: firstNonEmptyString(
                    block["name"] as? String,
                    block["tool_name"] as? String
                ),
                input: block["input"]
            ) else {
                continue
            }

            onPlanUpdate?(sessionID, entries)
        }
    }

    private func handleClaudeCodeControlRequest(_ payload: [String: Any]) {
        guard let requestID = firstNonEmptyString(
                payload["request_id"] as? String,
                payload["requestId"] as? String
              ),
              let request = payload["request"] as? [String: Any],
              let subtype = firstNonEmptyString(request["subtype"] as? String)?.lowercased() else {
            return
        }

        guard !(activeClaudeProcess != nil && activeClaudeStdinHandle == nil) else {
            presentClaudeCodeOneShotControlRequest(subtype: subtype, payload: request)
            return
        }

        switch subtype {
        case "can_use_tool":
            presentClaudeCodePermissionRequest(requestID: requestID, payload: request)
        case "elicitation":
            presentClaudeCodeElicitationRequest(requestID: requestID, payload: request)
        default:
            sendClaudeCodeControlError(
                requestID: requestID,
                error: "Unsupported Claude Code control request subtype: \(subtype)"
            )
        }
    }

    private func presentClaudeCodeOneShotControlRequest(
        subtype: String,
        payload: [String: Any]
    ) {
        switch subtype {
        case "elicitation":
            let message = firstNonEmptyString(
                payload["message"] as? String,
                "Claude needs more information."
            ) ?? "Claude needs more information."
            let url = firstNonEmptyString(payload["url"] as? String)
            let detail = [message, url, "Please answer in a new chat message to continue."]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
                .joined(separator: "\n\n")
            onTranscript?(AssistantTranscriptEntry(role: .assistant, text: detail, emphasis: true))
            onStatusMessage?("Claude needs more information. Reply in a new message to continue.")
            updateHUD(
                phase: .streaming,
                title: "Waiting for your reply",
                detail: compactDetail(message)
            )
            completeClaudeOneShotTurnForFollowUpIfNeeded()
        case "can_use_tool":
            let toolName = firstNonEmptyString(
                payload["display_name"] as? String,
                payload["tool_name"] as? String,
                "a tool"
            ) ?? "a tool"
            let detail = firstNonEmptyString(
                payload["description"] as? String,
                compactDetail(extractString(payload["input"]))
            )
            let message = [
                "Claude asked to use \(toolName), but this turn is running in one-shot Claude mode for reliability.",
                detail,
                "Please try again or send a smaller follow-up if Claude still needs that action."
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
                .joined(separator: "\n\n")
            onTranscript?(AssistantTranscriptEntry(role: .assistant, text: message, emphasis: true))
            onStatusMessage?("Claude requested interactive tool approval, which is not available for this one-shot turn.")
            updateHUD(
                phase: .acting,
                title: "Action Needed",
                detail: detail ?? toolName
            )
            completeClaudeOneShotTurnForFollowUpIfNeeded()
        default:
            onStatusMessage?("Claude asked for extra input, but this turn cannot accept live follow-up data.")
            completeClaudeOneShotTurnForFollowUpIfNeeded()
        }
    }

    private func completeClaudeOneShotTurnForFollowUpIfNeeded() {
        guard activeTurnID != nil else { return }
        terminateActiveClaudeProcess()
        handleTurnCompleted(["turn": ["status": "completed"]])
    }

    private func handleClaudeCodeControlCancelRequest(_ payload: [String: Any]) {
        guard let requestID = firstNonEmptyString(
                payload["request_id"] as? String,
                payload["requestId"] as? String
              ),
              pendingPermissionContext?.request.id == approvalRequestID(from: .string(requestID)) else {
            return
        }

        pendingPermissionContext = nil
        onPermissionRequest?(nil)
        updateHUD(
            phase: .thinking,
            title: interactionMode.normalizedForActiveUse == .plan ? "Planning" : "Thinking",
            detail: nil
        )
    }

    private func presentClaudeCodePermissionRequest(
        requestID: String,
        payload: [String: Any]
    ) {
        let toolName = firstNonEmptyString(
            payload["display_name"] as? String,
            payload["title"] as? String,
            payload["tool_name"] as? String,
            "Approval Needed"
        ) ?? "Approval Needed"
        let toolUseID = firstNonEmptyString(payload["tool_use_id"] as? String)
        let toolKind = claudeCodePermissionToolKind(for: payload["tool_name"] as? String)
        let input = payload["input"] as? [String: Any] ?? [:]
        let rationale = firstNonEmptyString(
            payload["description"] as? String,
            payload["decision_reason"] as? String,
            payload["blocked_path"] as? String
        )
        let summary = firstNonEmptyString(
            payload["description"] as? String,
            compactDetail(extractString(input)),
            payload["tool_name"] as? String
        )
        let options = [
            AssistantPermissionOption(id: "accept", title: "Allow Once", kind: toolKind, isDefault: true),
            AssistantPermissionOption(id: "decline", title: "Decline", kind: toolKind, isDefault: false),
            AssistantPermissionOption(id: "cancel", title: "Cancel Turn", kind: toolKind, isDefault: false)
        ]
        let request = AssistantPermissionRequest(
            id: approvalRequestID(from: .string(requestID)),
            sessionID: activeSessionID ?? "",
            toolTitle: toolName,
            toolKind: toolKind,
            rationale: rationale,
            options: options,
            rawPayloadSummary: summary
        )

        pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
            guard let self else { return }

            let response: [String: Any]
            switch optionID {
            case "accept":
                var payload: [String: Any] = [
                    "behavior": "allow",
                    "updatedInput": input
                ]
                if let toolUseID {
                    payload["toolUseID"] = toolUseID
                }
                response = payload
            case "cancel":
                var payload: [String: Any] = [
                    "behavior": "deny",
                    "message": "The user canceled this turn.",
                    "interrupt": true
                ]
                if let toolUseID {
                    payload["toolUseID"] = toolUseID
                }
                response = payload
            default:
                var payload: [String: Any] = [
                    "behavior": "deny",
                    "message": "The user declined this request."
                ]
                if let toolUseID {
                    payload["toolUseID"] = toolUseID
                }
                response = payload
            }
            let finalizedResponse = response

            await MainActor.run {
                self.sendClaudeCodeControlSuccess(requestID: requestID, response: finalizedResponse)
            }
        } cancelHandler: { [weak self] in
            guard let self else { return }
            var response: [String: Any] = [
                "behavior": "deny",
                "message": "The user canceled this turn.",
                "interrupt": true
            ]
            if let toolUseID {
                response["toolUseID"] = toolUseID
            }
            let finalizedResponse = response
            await MainActor.run {
                self.sendClaudeCodeControlSuccess(requestID: requestID, response: finalizedResponse)
            }
        }

        onPermissionRequest?(request)
        let transcriptText = summary ?? toolName
        onTranscript?(AssistantTranscriptEntry(
            role: .permission,
            text: "Claude needs approval for: \(transcriptText)",
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
            title: "Approve \(toolName)",
            detail: summary ?? rationale
        )
    }

    private func presentClaudeCodeElicitationRequest(
        requestID: String,
        payload: [String: Any]
    ) {
        let message = firstNonEmptyString(
            payload["message"] as? String,
            "Claude needs more information."
        ) ?? "Claude needs more information."
        let sessionID = activeSessionID ?? ""
        let requestedSchema = payload["requested_schema"] as? [String: Any]
        let mode = firstNonEmptyString(payload["mode"] as? String)?.lowercased()
        let url = firstNonEmptyString(payload["url"] as? String)

        if mode == "url", let url {
            let options = [
                AssistantPermissionOption(id: "accept", title: "I Opened It", kind: "userInput", isDefault: true),
                AssistantPermissionOption(id: "decline", title: "Decline", kind: "userInput", isDefault: false),
                AssistantPermissionOption(id: "cancel", title: "Cancel Request", kind: "userInput", isDefault: false)
            ]
            let request = AssistantPermissionRequest(
                id: approvalRequestID(from: .string(requestID)),
                sessionID: sessionID,
                toolTitle: "Claude needs your input",
                toolKind: "userInput",
                rationale: "\(message)\n\(url)",
                options: options,
                rawPayloadSummary: url
            )

            pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
                guard let self else { return }
                let action: String
                switch optionID {
                case "accept":
                    action = "accept"
                case "decline":
                    action = "decline"
                default:
                    action = "cancel"
                }
                await MainActor.run {
                    self.sendClaudeCodeControlSuccess(
                        requestID: requestID,
                        response: ["action": action]
                    )
                }
            } cancelHandler: { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.sendClaudeCodeControlSuccess(
                        requestID: requestID,
                        response: ["action": "cancel"]
                    )
                }
            }

            onPermissionRequest?(request)
            onTranscript?(AssistantTranscriptEntry(role: .permission, text: message, emphasis: true))
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
            updateHUD(phase: .waitingForPermission, title: "Input Needed", detail: url)
            return
        }

        let questions = Self.parseClaudeCodeElicitationQuestions(
            message: message,
            requestedSchema: requestedSchema
        )
        let request = AssistantPermissionRequest(
            id: approvalRequestID(from: .string(requestID)),
            sessionID: sessionID,
            toolTitle: "Claude needs input",
            toolKind: "userInput",
            rationale: message,
            options: [],
            userInputQuestions: questions,
            rawPayloadSummary: compactDetail(message)
        )

        pendingPermissionContext = PendingPermissionContext(request: request) { _ in
        } submitAnswersHandler: { [weak self] answers in
            guard let self else { return }
            var response: [String: Any] = ["action": "accept"]
            let content = Self.buildClaudeCodeElicitationContent(
                from: answers,
                requestedSchema: requestedSchema
            )
            if !content.isEmpty {
                response["content"] = content
            }
            let finalizedResponse = response
            await MainActor.run {
                self.sendClaudeCodeControlSuccess(requestID: requestID, response: finalizedResponse)
            }
        } cancelHandler: { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.sendClaudeCodeControlSuccess(
                    requestID: requestID,
                    response: ["action": "cancel"]
                )
            }
        }

        onPermissionRequest?(request)
        onTranscript?(AssistantTranscriptEntry(
            role: .permission,
            text: "Claude needs your answer to continue.",
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
        updateHUD(phase: .waitingForPermission, title: "Input Needed", detail: compactDetail(message))
    }

    private func claudeCodePermissionToolKind(for toolName: String?) -> String? {
        switch toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bash", "localbash", "powershell", "sandboxnetworkaccess":
            return "commandExecution"
        case "edit", "multiedit", "write":
            return "fileChange"
        case let value? where value.contains("browser"):
            return "browserUse"
        default:
            return "tool"
        }
    }

    private func rememberClaudeToolApproval(toolName: String, for sessionID: String) {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToolName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty, !normalizedToolName.isEmpty else { return }
        var approvals = approvedClaudeToolNamesBySessionID[normalizedSessionID] ?? []
        approvals.insert(normalizedToolName)
        approvedClaudeToolNamesBySessionID[normalizedSessionID] = approvals
    }

    private func approvedClaudeToolNames(for sessionID: String) -> [String] {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return [] }
        return (approvedClaudeToolNamesBySessionID[normalizedSessionID] ?? [])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func parseClaudeCodePermissionDenial(
        from payload: [String: Any],
        sessionID: String?
    ) -> ClaudeCodePermissionDenial? {
        guard let denial = (payload["permission_denials"] as? [[String: Any]])?.first else {
            return nil
        }

        let toolName = firstNonEmptyString(
            denial["tool_name"] as? String,
            denial["toolName"] as? String
        )
        guard let toolName, !toolName.isEmpty else { return nil }

        let resolvedSessionID = firstNonEmptyString(
            sessionID,
            payload["session_id"] as? String,
            payload["sessionId"] as? String,
            activeSessionID
        ) ?? ""
        guard !resolvedSessionID.isEmpty else { return nil }

        let toolUseID = firstNonEmptyString(
            denial["tool_use_id"] as? String,
            denial["toolUseId"] as? String
        )
        let toolInput = denial["tool_input"] as? [String: Any] ?? [:]
        let requestSeed = toolUseID ?? "\(toolName)-\(UUID().uuidString)"
        let summary = firstNonEmptyString(
            compactDetail(
                firstNonEmptyString(
                    toolInput["command"] as? String,
                    toolInput["cmd"] as? String,
                    toolInput["script"] as? String
                )
            ),
            compactDetail(toolInput["description"] as? String),
            compactDetail(extractString(toolInput)),
            compactDetail(extractString(payload["result"]))
        )

        return ClaudeCodePermissionDenial(
            requestID: "claude-denied-\(requestSeed)",
            sessionID: resolvedSessionID,
            toolName: toolName,
            toolUseID: toolUseID,
            toolInput: toolInput,
            summary: summary
        )
    }

    private func presentSyntheticClaudePermissionRequest(
        _ denial: ClaudeCodePermissionDenial
    ) {
        cancelClaudeCodeIdleTimeoutTask()
        let toolKind = claudeCodePermissionToolKind(for: denial.toolName)
        let request = AssistantPermissionRequest(
            id: approvalRequestID(from: .string(denial.requestID)),
            sessionID: denial.sessionID,
            toolTitle: denial.toolName,
            toolKind: toolKind,
            rationale: "Claude tried to use \(denial.toolName), but Claude Code blocked it until you approve it.",
            options: [
                AssistantPermissionOption(
                    id: "acceptForSession",
                    title: "Allow for Session",
                    kind: toolKind,
                    isDefault: true
                ),
                AssistantPermissionOption(
                    id: "decline",
                    title: "Decline",
                    kind: toolKind,
                    isDefault: false
                ),
                AssistantPermissionOption(
                    id: "cancel",
                    title: "Cancel",
                    kind: toolKind,
                    isDefault: false
                )
            ],
            rawPayloadSummary: denial.summary
        )

        pendingPermissionContext = PendingPermissionContext(request: request) { [weak self] optionID in
            guard let self else { return }

            switch optionID {
            case "acceptForSession":
                await self.continueClaudeAfterPermissionApproval(denial, persistForSession: true)
            case "cancel":
                await MainActor.run {
                    self.onStatusMessage?("Canceled the blocked Claude action.")
                    self.updateHUD(phase: .idle, title: "Cancelled", detail: nil)
                }
            default:
                await MainActor.run {
                    self.onStatusMessage?("Declined the blocked Claude action.")
                    self.updateHUD(phase: .idle, title: "Permission declined", detail: nil)
                }
            }
        } cancelHandler: { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.onStatusMessage?("Canceled the blocked Claude action.")
                self.updateHUD(phase: .idle, title: "Cancelled", detail: nil)
            }
        }

        onPermissionRequest?(request)
        onTranscript?(AssistantTranscriptEntry(
            role: .permission,
            text: "Claude needs approval for: \(denial.toolName).",
            emphasis: true
        ))
        onTimelineMutation?(
            .upsert(
                .permission(
                    id: "permission-\(request.id)",
                    sessionID: request.sessionID,
                    turnID: nil,
                    request: request,
                    createdAt: Date(),
                    source: .runtime
                )
            )
        )
        updateHUD(
            phase: .waitingForPermission,
            title: "Approve \(denial.toolName)",
            detail: denial.summary
        )
    }

    private func continueClaudeAfterPermissionApproval(
        _ denial: ClaudeCodePermissionDenial,
        persistForSession: Bool
    ) async {
        if persistForSession {
            rememberClaudeToolApproval(toolName: denial.toolName, for: denial.sessionID)
        }

        terminateActiveClaudeProcess(expected: true)

        let serializedInput = Self.serializedClaudeToolInput(denial.toolInput)
        let continuationPrompt = [
            "The user approved using the Claude Code tool `\(denial.toolName)` for this thread.",
            "Continue the previously blocked work.",
            serializedInput.nonEmpty.map {
                "If needed, re-run the blocked tool with this exact input:\n\($0)"
            },
            "Do not ask for approval again for this same tool unless a different action now needs approval."
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            .joined(separator: "\n\n")

        do {
            try await sendClaudeCodePrompt(
                sessionID: denial.sessionID,
                prompt: continuationPrompt,
                attachments: [],
                preferredModelID: preferredModelID,
                modelSupportsImageInput: false,
                resumeContext: nil,
                memoryContext: nil
            )
        } catch {
            await MainActor.run {
                self.onStatusMessage?(error.localizedDescription)
            }
        }
    }

    private func sendClaudeCodeControlSuccess(
        requestID: String,
        response: [String: Any]
    ) {
        var payload: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestID
            ]
        ]
        if !response.isEmpty {
            payload["response"] = [
                "subtype": "success",
                "request_id": requestID,
                "response": response
            ]
        }

        do {
            try writeClaudeCodeInputMessage(payload)
        } catch {
            onStatusMessage?(error.localizedDescription)
        }
    }

    private func sendClaudeCodeControlError(
        requestID: String,
        error: String
    ) {
        do {
            try writeClaudeCodeInputMessage([
                "type": "control_response",
                "response": [
                    "subtype": "error",
                    "request_id": requestID,
                    "error": error
                ]
            ])
        } catch {
            onStatusMessage?(error.localizedDescription)
        }
    }

    private func handleClaudeCodeResultPayload(_ payload: [String: Any]) {
        guard activeTurnID != nil else { return }
        cancelPendingClaudeCompletion()
        let permissionDenial = parseClaudeCodePermissionDenial(
            from: payload,
            sessionID: activeSessionID
        )

        if payload["is_error"] as? Bool == true {
            let message = Self.extractClaudeCodeResponseText(from: payload)
                ?? Self.commandFailureMessage(
                    stdout: nil,
                    stderr: nil,
                    fallback: "Claude Code reported an error."
                )
            handleTurnCompleted([
                "turn": [
                    "status": "failed",
                    "error": ["message": message]
                ]
            ])
            return
        }

        if let responseText = Self.extractClaudeCodeResponseText(from: payload)?.nonEmpty {
            _ = applyClaudeSettledReplyCandidate(
                responseText,
                emitLiveDeltaWhenInstallingInitial: false
            )
        }
        let (usage, modelContextWindow) = Self.parseClaudeCodeUsage(from: payload)
        if let usage {
            applyClaudeCodeTokenUsage(usage, modelContextWindow: modelContextWindow)
        }

        let stopReason = firstNonEmptyString(
            payload["stop_reason"] as? String,
            payload["stopReason"] as? String
        )?.lowercased()
        let hasQueuedClaudeFollowUps = activeClaudeQueuedPromptContexts.count > 1
        switch stopReason {
        case "cancelled", "canceled", "interrupted":
            handleTurnCompleted(["turn": ["status": "interrupted"]])
        default:
            if hasQueuedClaudeFollowUps {
                handleClaudeCodeIntermediateCompletion()
            } else {
                handleTurnCompleted(["turn": ["status": "completed"]])
            }
        }

        if let permissionDenial, pendingPermissionContext == nil {
            presentSyntheticClaudePermissionRequest(permissionDenial)
        }
    }

    private func handleClaudeCodeIntermediateCompletion() {
        let completedTurnResponse = correctedAssistantImageFailureFallbackIfNeeded(streamingBuffer)
        let responsePreview = completedTurnResponse.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        flushStreamingBuffer()
        flushCommentaryBuffer()
        finalizeActiveActivities(with: .completed)

        if sessionTurnCount == 0,
           let sessionID = activeSessionID,
           let userPrompt = firstTurnUserPrompt,
           completedTurnResponse.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil {
            onTitleRequest?(sessionID, userPrompt, completedTurnResponse)
        }
        sessionTurnCount += 1

        _ = dequeueCurrentClaudeQueuedPromptContext()
        activateCurrentClaudeQueuedPromptContextIfNeeded()
        pendingCopilotFallbackReply = nil
        currentTurnHadSuccessfulImageGeneration = false
        resolveNextActiveClaudeTurnContinuation(status: .completed)
        updateHUD(
            phase: .thinking,
            title: "Queued Follow-Up",
            detail: responsePreview ?? "Claude is continuing with your next message."
        )
        publishExecutionStateSnapshot()

        if backend == .claudeCode, currentAccountSnapshot.isLoggedIn {
            Task { await refreshRateLimits() }
        }
    }

    private enum ClaudeReplySettlement {
        case ignored
        case installedAsInitial
        case replacedExisting
    }

    @discardableResult
    private func applyClaudeSettledReplyCandidate(
        _ text: String,
        emitLiveDeltaWhenInstallingInitial: Bool
    ) -> ClaudeReplySettlement {
        guard let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return .ignored
        }

        let current = streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            ensureStreamingIdentifiers()
            streamingBuffer = candidate
            pendingStreamingDeltaBuffer = emitLiveDeltaWhenInstallingInitial ? candidate : ""
            return .installedAsInitial
        }

        guard Self.shouldPreferClaudeSettledReply(candidate, over: current) else {
            return .ignored
        }

        ensureStreamingIdentifiers()
        streamingBuffer = candidate
        pendingStreamingDeltaBuffer = ""
        return .replacedExisting
    }

    private func handleClaudeCodeStreamEvent(_ event: [String: Any], sessionID: String?) {
        switch (event["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "message_start":
            claudeStreamingAwaitingToolExecution = false
            updateHUD(
                phase: .thinking,
                title: interactionMode.normalizedForActiveUse == .plan ? "Planning" : "Thinking",
                detail: nil
            )
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any] else { return }
            let blockType = (block["type"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if blockType == "tool_use" {
                let title = firstNonEmptyString(block["name"] as? String, "Using tool") ?? "Using tool"
                if let index = event["index"] as? Int {
                    let toolID = firstNonEmptyString(
                        block["id"] as? String,
                        "claude-tool-\(index)"
                    ) ?? "claude-tool-\(index)"
                    let inputJSON = Self.serializedClaudeToolInput(block["input"])
                    claudeStreamingToolUseInputs[index] = (
                        id: toolID,
                        name: title,
                        inputJSON: inputJSON
                    )
                    upsertClaudeStreamingToolUse(id: toolID, name: title, inputJSON: inputJSON)
                    if let entries = Self.parseClaudeCodePlanEntriesFromToolUse(name: title, input: inputJSON) {
                        onPlanUpdate?(sessionID, entries)
                    }
                }
                updateHUD(phase: .acting, title: title, detail: compactDetail(extractString(block["input"])))
            } else if blockType == "text" {
                updateHUD(
                    phase: .streaming,
                    title: interactionMode.normalizedForActiveUse == .plan ? "Planning" : "Responding",
                    detail: nil
                )
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return }
            switch (delta["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "input_json_delta":
                guard let index = event["index"] as? Int,
                      var toolUse = claudeStreamingToolUseInputs[index] else {
                    return
                }
                toolUse.inputJSON += delta["partial_json"] as? String ?? ""
                claudeStreamingToolUseInputs[index] = toolUse
                upsertClaudeStreamingToolUse(
                    id: toolUse.id,
                    name: toolUse.name,
                    inputJSON: toolUse.inputJSON
                )
                if let entries = Self.parseClaudeCodePlanEntriesFromToolUse(
                    name: toolUse.name,
                    input: toolUse.inputJSON
                ) {
                    onPlanUpdate?(sessionID, entries)
                }
            case "text_delta":
                guard let rawText = delta["text"] as? String else {
                    return
                }
                let text = normalizedClaudeStreamingTextDelta(rawText)
                guard !text.isEmpty else {
                    return
                }
                guard acceptAssistantMessageDelta(
                    threadID: activeSessionID,
                    turnID: nil,
                    source: "claude.stream.content_block_delta"
                ) else {
                    return
                }
                ensureStreamingIdentifiers()
                streamingBuffer += text
                pendingStreamingDeltaBuffer += text
                emitStreamingAssistantDelta(force: shouldForceStreamingDeltaFlush(for: text))
                updateHUD(
                    phase: .streaming,
                    title: interactionMode.normalizedForActiveUse == .plan ? "Planning" : "Responding",
                    detail: nil
                )
            default:
                return
            }
        case "content_block_stop":
            guard let index = event["index"] as? Int,
                  let toolUse = removeClaudeStreamingToolUse(forIndex: index) else {
                return
            }
            if let entries = Self.parseClaudeCodePlanEntriesFromToolUse(
                name: toolUse.name,
                input: toolUse.inputJSON
            ) {
                onPlanUpdate?(sessionID, entries)
            }
        case "message_delta":
            if let delta = event["delta"] as? [String: Any],
               let stopReason = firstNonEmptyString(
                    delta["stop_reason"] as? String,
                    delta["stopReason"] as? String
               )?.lowercased() {
                if stopReason == "tool_use" {
                    claudeStreamingAwaitingToolExecution = true
                    updateHUD(phase: .acting, title: "Using tools", detail: nil)
                } else if ["end_turn", "stop_sequence", "max_tokens"].contains(stopReason) {
                    claudeStreamingAwaitingToolExecution = false
                    scheduleClaudeDeferredCompletion()
                }
            }
        case "message_stop":
            // Only schedule deferred completion when the message ended
            // naturally (end_turn / max_tokens).  When the CLI is about to
            // execute tools (stop_reason was "tool_use"), more events will
            // follow — scheduling a completion here would kill the turn
            // before the tool results and follow-up response arrive.
            if !claudeStreamingAwaitingToolExecution {
                scheduleClaudeDeferredCompletion()
            }
        default:
            return
        }
    }

    private func ensureClaudeCodeLiveProcess(
        executablePath: String,
        sessionID: String,
        workingDirectory: String?,
        preferredModelID: String?
    ) async throws {
        let normalizedModelID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let permissionMode = Self.claudeCodePermissionMode(for: interactionMode)
        let allowedTools = approvedClaudeToolNames(for: sessionID)
        let requiresRestart =
            !hasLiveClaudeProcess
            || activeClaudeProcessSessionID?.caseInsensitiveCompare(sessionID) != .orderedSame
            || activeClaudeProcessWorkingDirectory != workingDirectory
            || activeClaudeProcessModelID != normalizedModelID
            || activeClaudeProcessPermissionMode != permissionMode
            || activeClaudeProcessAllowedTools != allowedTools

        guard requiresRestart else {
            recordClaudeCodeActivity()
            publishExecutionStateSnapshot()
            return
        }

        terminateActiveClaudeProcess(expected: true)

        var arguments = [
            "-p",
            "--output-format",
            "stream-json",
            "--input-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--replay-user-messages",
            "--permission-mode",
            permissionMode
        ]
        if !allowedTools.isEmpty {
            arguments.append(contentsOf: ["--allowedTools", allowedTools.joined(separator: ",")])
        }
        if let normalizedModelID {
            arguments.append(contentsOf: ["--model", normalizedModelID])
        }
        if sessionTurnCount == 0 {
            arguments.append(contentsOf: ["--session-id", sessionID])
        } else {
            arguments.append(contentsOf: ["--resume", sessionID])
        }

        await ensureMCPToolBridge()
        if let mcpConfigPath = await writeMCPConfigFile() {
            arguments.append(contentsOf: ["--mcp-config", mcpConfigPath])
        }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let capture = ClaudeCodeCommandCapture()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = AssistantCommandEnvironment.mergedEnvironment()
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let lines = capture.appendStdout(data)
            guard !lines.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in lines {
                    self.handleClaudeCodeOutputLine(line)
                }
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let lines = capture.appendStderr(data)
            guard !lines.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in lines {
                    self.onStatusMessage?(line)
                }
            }
        }

        process.terminationHandler = { [weak self] completed in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil

            let snapshot = capture.finalize(
                remainingStdout: stdout.fileHandleForReading.readDataToEndOfFile(),
                remainingStderr: stderr.fileHandleForReading.readDataToEndOfFile()
            )

            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in snapshot.stdoutLines {
                    self.handleClaudeCodeOutputLine(line)
                }
                self.handleClaudeCodeLiveProcessTermination(
                    completed,
                    snapshot: snapshot
                )
            }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            stdin.fileHandleForWriting.closeFile()
            throw CodexAssistantRuntimeError.runtimeUnavailable(
                "Could not launch Claude Code: \(error.localizedDescription)"
            )
        }

        activeClaudeProcess = process
        activeClaudeStdinHandle = stdin.fileHandleForWriting
        activeClaudeProcessSessionID = sessionID
        activeClaudeProcessWorkingDirectory = workingDirectory
        activeClaudeProcessModelID = normalizedModelID
        activeClaudeProcessPermissionMode = permissionMode
        activeClaudeProcessAllowedTools = allowedTools
        recordClaudeCodeActivity()
        publishExecutionStateSnapshot()
    }

    private func handleClaudeCodeLiveProcessTermination(
        _ completed: Process,
        snapshot: (stdout: String, stderr: String, stdoutLines: [String], stderrLines: [String])
    ) {
        let wasCurrentProcess = activeClaudeProcess === completed
        let hadLiveProcess = hasLiveClaudeProcess
        if wasCurrentProcess {
            activeClaudeStdinHandle?.closeFile()
            activeClaudeStdinHandle = nil
            activeClaudeProcess = nil
            activeClaudeProcessSessionID = nil
            activeClaudeProcessWorkingDirectory = nil
            activeClaudeProcessModelID = nil
            activeClaudeProcessPermissionMode = nil
            activeClaudeProcessAllowedTools = []
        }
        cancelClaudeCodeIdleTimeoutTask()
        if wasCurrentProcess || hadLiveProcess {
            publishExecutionStateSnapshot()
        }

        guard wasCurrentProcess else { return }

        let exitCode = Int(completed.terminationStatus)
        guard activeTurnID != nil else {
            if exitCode != 0 {
                let message = Self.commandFailureMessage(
                    stdout: snapshot.stdout,
                    stderr: snapshot.stderr,
                    fallback: "Claude Code stopped unexpectedly."
                )
                onStatusMessage?(message)
                updateHUD(phase: .idle, title: "Session ready", detail: nil)
            }
            return
        }

        if exitCode == 0 {
            handleTurnCompleted(["turn": ["status": "interrupted"]])
            return
        }

        let message = Self.commandFailureMessage(
            stdout: snapshot.stdout,
            stderr: snapshot.stderr,
            fallback: "Claude Code stopped unexpectedly."
        )
        handleTurnCompleted([
            "turn": [
                "status": "failed",
                "error": ["message": message]
            ]
        ])
    }

    private func runClaudeCodeCommand(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        trackAsActiveTurn: Bool
    ) async throws -> CommandExecutionResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.environment = AssistantCommandEnvironment.mergedEnvironment()
            if let workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            }
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { [weak self] completed in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                Task { @MainActor [weak self] in
                    if trackAsActiveTurn, self?.activeClaudeProcess === completed {
                        self?.activeClaudeProcess = nil
                    }
                    continuation.resume(
                        returning: CommandExecutionResult(
                            exitCode: completed.terminationStatus,
                            stdout: String(decoding: outData, as: UTF8.self),
                            stderr: String(decoding: errData, as: UTF8.self)
                        )
                    )
                }
            }

            do {
                if trackAsActiveTurn {
                    activeClaudeProcess = process
                }
                try process.run()
            } catch {
                if trackAsActiveTurn {
                    activeClaudeProcess = nil
                }
                continuation.resume(
                    throwing: CodexAssistantRuntimeError.runtimeUnavailable(
                        "Could not launch Claude Code: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    private func terminateActiveClaudeProcess(expected _: Bool = true) {
        cancelClaudeCodeIdleTimeoutTask()
        guard let activeClaudeProcess else {
            publishExecutionStateSnapshot()
            return
        }
        if activeClaudeProcess.isRunning {
            activeClaudeProcess.terminate()
        }
        activeClaudeStdinHandle?.closeFile()
        activeClaudeStdinHandle = nil
        self.activeClaudeProcess = nil
        activeClaudeProcessSessionID = nil
        activeClaudeProcessWorkingDirectory = nil
        activeClaudeProcessModelID = nil
        activeClaudeProcessPermissionMode = nil
        activeClaudeProcessAllowedTools = []
        publishExecutionStateSnapshot()
    }

    private func writeClaudeCodeInputMessage(_ payload: [String: Any]) throws {
        guard let activeClaudeStdinHandle else {
            throw CodexAssistantRuntimeError.runtimeUnavailable(
                "This Claude turn is not waiting for live input anymore. Please answer in a new chat message."
            )
        }
        let data = try Self.serializeClaudeCodeJSONObjectLine(payload)
        try activeClaudeStdinHandle.write(contentsOf: data)
        recordClaudeCodeActivity()
    }

    nonisolated static func parseClaudeCodeAccountSnapshot(from output: String) throws -> AssistantAccountSnapshot {
        let payload = try parseClaudeCodeJSONObject(from: output)
        let loggedIn = payload["loggedIn"] as? Bool ?? false
        guard loggedIn else { return .signedOut }
        return AssistantAccountSnapshot(
            authMode: .chatGPT,
            email: firstNonEmptyClaudeString(
                payload["email"] as? String,
                payload["orgName"] as? String,
                "Claude Code"
            ),
            planType: firstNonEmptyClaudeString(
                payload["subscriptionType"] as? String,
                payload["apiProvider"] as? String
            ),
            requiresOpenAIAuth: false,
            loginInProgress: false,
            pendingLoginURL: nil,
            pendingLoginID: nil
        )
    }

    nonisolated static func claudeCodePermissionMode(for mode: AssistantInteractionMode) -> String {
        switch mode.normalizedForActiveUse {
        case .plan:
            return "plan"
        case .agentic, .conversational:
            return "default"
        }
    }

    nonisolated static func parseClaudeCodeInvocationResult(from output: String) throws -> ClaudeCodeInvocationResult {
        let payload = try parseClaudeCodeInvocationPayload(from: output)
        if payload["is_error"] as? Bool == true {
            let message = extractClaudeCodeResponseText(from: payload)
                ?? commandFailureMessage(
                    stdout: output,
                    stderr: nil,
                    fallback: "Claude Code reported an error."
                )
            throw CodexAssistantRuntimeError.requestFailed(
                message
            )
        }

        let responseText = extractClaudeCodeResponseText(from: payload) ?? ""
        let (usage, modelContextWindow) = parseClaudeCodeUsage(from: payload)
        return ClaudeCodeInvocationResult(
            sessionID: firstNonEmptyClaudeString(payload["session_id"] as? String),
            responseText: responseText,
            usage: usage,
            modelContextWindow: modelContextWindow,
            stopReason: firstNonEmptyClaudeString(payload["stop_reason"] as? String)
        )
    }

    private nonisolated static func parseClaudeCodeInvocationPayload(from output: String) throws -> [String: Any] {
        if let payload = try? parseClaudeCodeJSONObject(from: output) {
            return payload
        }

        let payloads = output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> [String: Any]? in
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return try? parseClaudeCodeJSONObject(from: trimmed)
            }

        guard !payloads.isEmpty else {
            throw CodexAssistantRuntimeError.invalidResponse("Claude Code did not return valid JSON.")
        }

        return payloads.reversed().first(where: {
            (($0["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == "result"
        }) ?? payloads.last!
    }

    private nonisolated static func parseClaudeCodeJSONObject(from output: String) throws -> [String: Any] {
        guard let data = output.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAssistantRuntimeError.invalidResponse("Claude Code did not return valid JSON.")
        }
        return payload
    }

    private nonisolated static func extractClaudeCodeResponseText(from payload: [String: Any]) -> String? {
        if let errors = payload["errors"] as? [String] {
            let joined = errors
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if let text = joined.nonEmpty {
                return normalizedClaudeCodeDisplayText(text)
            }
        }
        if let text = (payload["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return normalizedClaudeCodeDisplayText(text)
        }
        if let result = payload["result"] as? [String: Any] {
            if let text = (result["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                return normalizedClaudeCodeDisplayText(text)
            }
            if let content = result["content"] as? [[String: Any]] {
                return extractClaudeCodeContentText(from: content)
            }
        }
        if let message = payload["message"] as? [String: Any] {
            return extractClaudeCodeMessageText(from: message)
        }
        return nil
    }

    private nonisolated static func extractClaudeCodeMessageText(from message: [String: Any]) -> String? {
        if let text = (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return normalizedClaudeCodeDisplayText(text)
        }
        if let content = message["content"] as? [[String: Any]] {
            return extractClaudeCodeContentText(from: content)
        }
        return nil
    }

    private nonisolated static func extractClaudeCodeContentText(from content: [[String: Any]]) -> String? {
        let joined = content.compactMap { item -> String? in
            if (item["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "tool_use" {
                return nil
            }
            if let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                return normalizedClaudeCodeDisplayText(text)
            }
            if let nested = item["content"] as? [String: Any] {
                return extractClaudeCodeMessageText(from: nested)
            }
            return nil
        }
        .joined(separator: "\n")
        return joined.nonEmpty
    }

    private nonisolated static func shouldPreferClaudeSettledReply(
        _ candidate: String,
        over current: String
    ) -> Bool {
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedCandidate.isEmpty else { return false }
        guard !normalizedCurrent.isEmpty else { return true }
        guard normalizedCandidate != normalizedCurrent else { return false }

        let candidateWords = normalizedCandidate.split(whereSeparator: \.isWhitespace).count
        let currentWords = normalizedCurrent.split(whereSeparator: \.isWhitespace).count
        let candidateRichness = claudeReplyRichnessScore(normalizedCandidate)
        let currentRichness = claudeReplyRichnessScore(normalizedCurrent)

        if looksLikeClaudeProvisionalReply(normalizedCurrent) {
            if candidateRichness > currentRichness {
                return true
            }
            if candidateWords >= max(currentWords + 6, currentWords * 2) {
                return true
            }
            if normalizedCandidate.count >= normalizedCurrent.count + 80 {
                return true
            }
        }

        if candidateRichness >= currentRichness + 2,
           normalizedCandidate.count >= normalizedCurrent.count {
            return true
        }

        if candidateRichness > currentRichness,
           candidateWords > currentWords,
           normalizedCandidate.count >= normalizedCurrent.count + 24 {
            return true
        }

        if normalizedCandidate.count >= max(normalizedCurrent.count + 120, Int(Double(normalizedCurrent.count) * 1.6)),
           candidateWords >= currentWords + 10 {
            return true
        }

        return false
    }

    private nonisolated static func claudeReplyRichnessScore(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        let bulletLines = lines.filter { line in
            let normalized = line.trimmingCharacters(in: .whitespaces)
            return normalized.hasPrefix("- ")
                || normalized.hasPrefix("* ")
                || normalized.hasPrefix("• ")
                || normalized.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
        }.count
        let headingLines = lines.filter { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }.count
        let paragraphBreaks = trimmed.components(separatedBy: "\n\n").count - 1
        let sentenceEndings = trimmed.filter { ".!?".contains($0) }.count

        var score = 0
        score += min(paragraphBreaks, 3) * 2
        score += min(bulletLines, 4) * 2
        score += min(headingLines, 2) * 2
        if trimmed.contains("```") {
            score += 3
        }
        if trimmed.contains("](") {
            score += 1
        }
        if sentenceEndings >= 2 {
            score += 1
        }
        return score
    }

    private nonisolated static func looksLikeClaudeProvisionalReply(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        let wordCount = lowered.split(whereSeparator: \.isWhitespace).count
        guard wordCount <= 24 else { return false }

        let provisionalPrefixes = [
            "let me ",
            "i'll ",
            "i will ",
            "i’m ",
            "i'm ",
            "give me a moment",
            "one moment",
            "let's ",
            "first, i'll ",
            "first, i’ll ",
            "i need to "
        ]
        if provisionalPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return true
        }

        let actionWords = [
            "read",
            "check",
            "look",
            "find",
            "review",
            "inspect",
            "explore",
            "scan",
            "search",
            "analyze"
        ]
        let hasIntentLeadIn = lowered.contains("let me")
            || lowered.contains("i'll")
            || lowered.contains("i will")
            || lowered.contains("i'm going to")
            || lowered.contains("i’m going to")
        return hasIntentLeadIn && actionWords.contains(where: { lowered.contains($0) })
    }

    private nonisolated static func parseClaudeCodeUsage(from payload: [String: Any]) -> (TokenUsageBreakdown?, Int?) {
        let usage = payload["usage"] as? [String: Any]
        let modelUsage = (payload["modelUsage"] as? [String: Any])?.values.first as? [String: Any]

        let directInput = intValue(
            usage?["input_tokens"],
            modelUsage?["inputTokens"]
        )
        let cacheCreation = intValue(
            usage?["cache_creation_input_tokens"],
            modelUsage?["cacheCreationInputTokens"]
        )
        let cacheRead = intValue(
            usage?["cache_read_input_tokens"],
            modelUsage?["cacheReadInputTokens"]
        )
        let outputTokens = intValue(
            usage?["output_tokens"],
            modelUsage?["outputTokens"]
        )
        let reasoningOutputTokens = intValue(
            usage?["reasoning_output_tokens"],
            modelUsage?["reasoningOutputTokens"]
        )
        let contextWindow = intValue(modelUsage?["contextWindow"])

        let effectiveInputTokens = directInput + cacheCreation + cacheRead
        guard effectiveInputTokens > 0 || outputTokens > 0 || reasoningOutputTokens > 0 else {
            return (nil, contextWindow > 0 ? contextWindow : nil)
        }

        let breakdown = TokenUsageBreakdown(
            inputTokens: effectiveInputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cacheRead,
            reasoningOutputTokens: reasoningOutputTokens,
            totalTokens: effectiveInputTokens + outputTokens + reasoningOutputTokens
        )
        return (breakdown, contextWindow > 0 ? contextWindow : nil)
    }

    private nonisolated static func claudeCodeUserMessagePayload(
        content: String,
        sessionID: String?
    ) -> [String: Any] {
        [
            "type": "user",
            "session_id": sessionID ?? "",
            "message": [
                "role": "user",
                "content": [[
                    "type": "text",
                    "text": content
                ]]
            ],
            "parent_tool_use_id": NSNull()
        ]
    }

    private nonisolated static func serializeClaudeCodeJSONObjectLine(
        _ payload: [String: Any]
    ) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var line = data
        line.append(Data([UInt8(ascii: "\n")]))
        return line
    }

    private nonisolated static func mcpElicitationTitle(for message: String) -> String {
        let trimmed = sanitizedMCPElicitationText(message)
        guard !trimmed.isEmpty else { return "Codex needs input" }

        if let match = trimmed.range(
            of: #"(?i)^allow codex to use (.+?)\?$"#,
            options: .regularExpression
        ) {
            let matched = String(trimmed[match])
            if let prefixRange = matched.range(
                of: #"(?i)^allow codex to use "#,
                options: .regularExpression
            ) {
                let remainder = matched[prefixRange.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "?").union(.whitespacesAndNewlines))
                if !remainder.isEmpty {
                    return sanitizedMCPElicitationText(remainder)
                }
            }
        }

        return "Codex needs input"
    }

    private nonisolated static func isSimpleMCPElicitationConfirmation(
        message: String,
        requestedSchema: [String: Any]?
    ) -> Bool {
        let normalized = sanitizedMCPElicitationText(message)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.hasSuffix("?") else { return false }
        guard requestedSchema == nil || isTrivialMCPElicitationConfirmationSchema(requestedSchema) else {
            return false
        }

        return normalized.hasPrefix("allow ")
            || normalized.hasPrefix("do you want ")
            || normalized.hasPrefix("would you like ")
            || normalized.hasPrefix("can i ")
            || normalized.hasPrefix("can codex ")
            || normalized.hasPrefix("should i ")
    }

    private nonisolated static func isTrivialMCPElicitationConfirmationSchema(
        _ requestedSchema: [String: Any]?
    ) -> Bool {
        guard let requestedSchema else { return true }

        if let properties = requestedSchema["properties"] as? [String: Any], !properties.isEmpty {
            guard properties.count == 1, let (key, rawSchema) = properties.first else {
                return false
            }
            let schema = rawSchema as? [String: Any] ?? [:]
            let normalizedKey = key
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
            let optionValues = claudeCodeElicitationOptionValues(for: schema)
            let type = firstNonEmptyClaudeString(schema["type"] as? String)?.lowercased()

            if type == "boolean" {
                return true
            }
            if !optionValues.isEmpty {
                return optionValues.count <= 2
            }

            return [
                "response",
                "answer",
                "approval",
                "approve",
                "confirmation",
                "confirm",
                "decision",
                "choice",
                "action"
            ].contains(normalizedKey)
        }

        let type = firstNonEmptyClaudeString(requestedSchema["type"] as? String)?.lowercased()
        return type == nil || type == "object" || type == "boolean" || type == "string"
    }

    private nonisolated static func simpleMCPElicitationConfirmationResponse(
        action: String,
        requestedSchema: [String: Any]?
    ) -> [String: Any] {
        var response: [String: Any] = ["action": action]
        guard action != "cancel" else { return response }
        if let content = simpleMCPElicitationConfirmationContent(
            action: action,
            requestedSchema: requestedSchema
        ), !content.isEmpty {
            response["content"] = content
        }
        return response
    }

    private nonisolated static func simpleMCPElicitationConfirmationContent(
        action: String,
        requestedSchema: [String: Any]?
    ) -> [String: Any]? {
        guard let requestedSchema else { return nil }

        let fallbackValue = action == "accept" ? "Allow" : "Decline"
        guard let properties = requestedSchema["properties"] as? [String: Any], !properties.isEmpty else {
            return ["response": fallbackValue]
        }
        guard properties.count == 1, let (key, rawSchema) = properties.first else {
            return nil
        }

        let schema = rawSchema as? [String: Any] ?? [:]
        let answerValue = simpleMCPElicitationConfirmationAnswerValue(
            action: action,
            schema: schema,
            fallback: fallbackValue
        )
        return [key: coerceClaudeCodeScalarValue(answerValue, schema: schema)]
    }

    private nonisolated static func simpleMCPElicitationConfirmationAnswerValue(
        action: String,
        schema: [String: Any],
        fallback: String
    ) -> String {
        let optionValues = claudeCodeElicitationOptionValues(for: schema)
        guard !optionValues.isEmpty else { return fallback }

        let positiveTerms = ["allow", "accept", "approved", "approve", "yes", "true", "ok"]
        let negativeTerms = ["decline", "deny", "denied", "reject", "rejected", "no", "false", "cancel"]
        let preferredTerms = action == "accept" ? positiveTerms : negativeTerms

        for option in optionValues {
            let normalized = option
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if preferredTerms.contains(where: { normalized == $0 || normalized.contains($0) }) {
                return option
            }
        }

        if optionValues.count == 2 {
            return action == "accept" ? optionValues[0] : optionValues[1]
        }

        return fallback
    }

    private nonisolated static func sanitizedMCPElicitationText(_ text: String) -> String {
        let directionalMarks = CharacterSet(charactersIn:
            "\u{061C}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
        )
        let filteredScalars = text.unicodeScalars.filter { !directionalMarks.contains($0) }
        return String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func parseClaudeCodeElicitationQuestions(
        message: String,
        requestedSchema: [String: Any]?
    ) -> [AssistantUserInputQuestion] {
        guard let properties = requestedSchema?["properties"] as? [String: Any],
              !properties.isEmpty else {
            return [
                AssistantUserInputQuestion(
                    id: "response",
                    header: "Response",
                    prompt: message,
                    options: [],
                    allowsCustomAnswer: true
                )
            ]
        }

        let required = Set((requestedSchema?["required"] as? [String]) ?? [])
        let orderedKeys: [String]
        if !required.isEmpty {
            orderedKeys = properties.keys
                .filter { required.contains($0) }
                .sorted()
        } else {
            orderedKeys = properties.keys.sorted()
        }

        return orderedKeys.map { key in
            let schema = properties[key] as? [String: Any] ?? [:]
            let title = firstNonEmptyClaudeString(schema["title"] as? String)
            let description = firstNonEmptyClaudeString(schema["description"] as? String)
            let header = firstNonEmptyClaudeString(
                title,
                prettifyClaudeCodeFieldName(key),
                "Answer"
            ) ?? "Answer"
            let optionValues = claudeCodeElicitationOptionValues(for: schema)
            let allowsCustomAnswer = claudeCodeElicitationAllowsCustomAnswer(
                for: schema,
                optionValues: optionValues
            )
            var prompt = firstNonEmptyClaudeString(description, title, header) ?? header
            if let guidance = claudeCodeElicitationInputGuidance(for: schema) {
                prompt = "\(prompt)\n\(guidance)"
            }

            return AssistantUserInputQuestion(
                id: key,
                header: header,
                prompt: prompt,
                options: optionValues.enumerated().map { index, value in
                    AssistantUserInputQuestionOption(
                        id: "\(key)-option-\(index)",
                        label: value,
                        detail: nil
                    )
                },
                allowsCustomAnswer: allowsCustomAnswer
            )
        }
    }

    private nonisolated static func buildClaudeCodeElicitationContent(
        from answers: [String: [String]],
        requestedSchema: [String: Any]?
    ) -> [String: Any] {
        guard let properties = requestedSchema?["properties"] as? [String: Any],
              !properties.isEmpty else {
            guard let first = answers.first else { return [:] }
            if first.value.count <= 1 {
                return [first.key: first.value.first ?? ""]
            }
            return [first.key: first.value]
        }

        var content: [String: Any] = [:]
        for (key, values) in answers {
            let schema = properties[key] as? [String: Any] ?? [:]
            content[key] = coerceClaudeCodeElicitationValue(values, schema: schema)
        }
        return content
    }

    private nonisolated static func coerceClaudeCodeElicitationValue(
        _ values: [String],
        schema: [String: Any]
    ) -> Any {
        let normalizedValues = values
            .flatMap { value -> [String] in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return [] }
                return [trimmed]
            }
        let type = firstNonEmptyClaudeString(schema["type"] as? String)?.lowercased()

        if type == "array" {
            let itemSchema = schema["items"] as? [String: Any] ?? [:]
            let arrayValues = normalizedValues.flatMap { value in
                value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            return arrayValues.map { coerceClaudeCodeScalarValue($0, schema: itemSchema) }
        }

        let scalar = normalizedValues.first ?? ""
        return coerceClaudeCodeScalarValue(scalar, schema: schema)
    }

    private nonisolated static func coerceClaudeCodeScalarValue(
        _ value: String,
        schema: [String: Any]
    ) -> Any {
        switch firstNonEmptyClaudeString(schema["type"] as? String)?.lowercased() {
        case "boolean":
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "y", "1", "on"].contains(normalized) {
                return true
            }
            if ["false", "no", "n", "0", "off"].contains(normalized) {
                return false
            }
            return value
        case "integer":
            return Int(value) ?? value
        case "number":
            return Double(value) ?? value
        default:
            return value
        }
    }

    private nonisolated static func claudeCodeElicitationOptionValues(
        for schema: [String: Any]
    ) -> [String] {
        if let options = schema["enum"] as? [String], !options.isEmpty {
            return options
        }
        let type = firstNonEmptyClaudeString(schema["type"] as? String)?.lowercased()
        if type == "boolean" {
            return ["Yes", "No"]
        }
        if type == "array",
           let items = schema["items"] as? [String: Any],
           let options = items["enum"] as? [String],
           !options.isEmpty {
            return options
        }
        return []
    }

    private nonisolated static func claudeCodeElicitationAllowsCustomAnswer(
        for schema: [String: Any],
        optionValues: [String]
    ) -> Bool {
        let type = firstNonEmptyClaudeString(schema["type"] as? String)?.lowercased()
        if optionValues.isEmpty {
            return true
        }
        return type == "array"
    }

    private nonisolated static func claudeCodeElicitationInputGuidance(
        for schema: [String: Any]
    ) -> String? {
        let type = firstNonEmptyClaudeString(schema["type"] as? String)?.lowercased()
        if type == "array" {
            return "If you want multiple values, type them separated by commas."
        }
        if type == "boolean" {
            return "Choose Yes or No."
        }
        return nil
    }

    private nonisolated static func prettifyClaudeCodeFieldName(_ key: String) -> String {
        key
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { component in
                component.prefix(1).uppercased() + component.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private nonisolated static func addTokenUsageBreakdowns(
        _ lhs: TokenUsageBreakdown,
        _ rhs: TokenUsageBreakdown
    ) -> TokenUsageBreakdown {
        TokenUsageBreakdown(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens
        )
    }

    private nonisolated static func intValue(_ values: Any?...) -> Int {
        for value in values {
            if let intValue = value as? Int {
                return intValue
            }
            if let number = value as? NSNumber {
                return number.intValue
            }
            if let string = value as? String, let intValue = Int(string) {
                return intValue
            }
        }
        return 0
    }

    private nonisolated static func commandFailureMessage(
        stdout: String?,
        stderr: String?,
        fallback: String
    ) -> String {
        let message = firstNonEmptyClaudeString(
            stderr?.trimmingCharacters(in: .whitespacesAndNewlines),
            stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
            fallback
        ) ?? fallback
        return normalizedClaudeCodeDisplayText(message)
    }

    private nonisolated static func normalizedClaudeCodeDisplayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let formatted = formattedClaudeCodeAPIError(from: trimmed) else {
            return trimmed
        }
        return formatted
    }

    private nonisolated static func formattedClaudeCodeAPIError(from text: String) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.localizedCaseInsensitiveContains("API Error:") else { return nil }

        let statusCode = parseClaudeCodeAPIStatusCode(from: normalized)
        let jsonPayload: [String: Any]? = {
            guard let braceIndex = normalized.firstIndex(of: "{") else { return nil }
            let jsonString = String(normalized[braceIndex...])
            guard let data = jsonString.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return payload
        }()

        let errorPayload = jsonPayload?["error"] as? [String: Any]
        let requestID = firstNonEmptyClaudeString(jsonPayload?["request_id"] as? String)
        let errorType = firstNonEmptyClaudeString(errorPayload?["type"] as? String)?.lowercased()
        let apiMessage = firstNonEmptyClaudeString(errorPayload?["message"] as? String)

        var lines: [String]
        switch (statusCode, errorType) {
        case (529, _), (_, "overloaded_error"):
            lines = [
                "Claude is overloaded right now.",
                "Please wait a little and try again."
            ]
        case (500, _):
            lines = [
                "Claude had a temporary server error.",
                "Please try again in a moment."
            ]
        default:
            let fallback = apiMessage ?? normalized
            lines = ["Claude returned an API error: \(fallback)"]
        }

        if let requestID {
            lines.append("Request ID: \(requestID)")
        }

        return lines.joined(separator: "\n")
    }

    private nonisolated static func parseClaudeCodeAPIStatusCode(from text: String) -> Int? {
        guard let range = text.range(
            of: #"API Error:\s*(\d{3})"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let match = String(text[range])
        return match
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
            .nonEmpty
            .flatMap(Int.init)
    }

    private nonisolated static func firstNonEmptyClaudeString(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                return value
            }
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

    // MARK: - MCP Tool Bridge

    private func ensureMCPToolBridge() async {
        if mcpToolBridge != nil { return }
        guard SettingsStore.shared.assistantComputerUseEnabled else { return }
        let bridge = AssistantMCPToolBridge()
        await bridge.setDelegate(self)
        do {
            try await bridge.start()
            // Wait briefly for the port to resolve
            try await Task.sleep(nanoseconds: 100_000_000)
            mcpToolBridge = bridge
        } catch {
            CrashReporter.logInfo("MCP tool bridge failed to start: \(error.localizedDescription)")
        }
    }

    private func stopMCPToolBridge() async {
        await mcpToolBridge?.stop()
        mcpToolBridge = nil
        if let path = mcpConfigFilePath {
            try? FileManager.default.removeItem(atPath: path)
            mcpConfigFilePath = nil
        }
    }

    private func mcpServerConfigs() async -> [[String: Any]] {
        guard let bridge = mcpToolBridge,
              let bridgePort = await bridge.port,
              let execPath = Bundle.main.executablePath else {
            return []
        }
        return [[
            "name": MCPProtocol.serverName,
            "command": execPath,
            "args": ["--mcp-server", "--port", String(bridgePort)]
        ]]
    }

    private func writeMCPConfigFile() async -> String? {
        guard let bridge = mcpToolBridge,
              let bridgePort = await bridge.port,
              let execPath = Bundle.main.executablePath else {
            return nil
        }
        let config: [String: Any] = [
            "mcpServers": [
                MCPProtocol.serverName: [
                    "command": execPath,
                    "args": ["--mcp-server", "--port", String(bridgePort)]
                ]
            ]
        ]
        let path = NSTemporaryDirectory() + "openassist-mcp-config-\(ProcessInfo.processInfo.processIdentifier).json"
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) else {
            return nil
        }
        FileManager.default.createFile(atPath: path, contents: data)
        mcpConfigFilePath = path
        return path
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
            onPlanUpdate?(activeSessionID, [])
            onSubagentUpdate?([])
            onTimelineMutation?(.reset(sessionID: nil))
            onPermissionRequest?(nil)
            sessionTurnCount = 0
            firstTurnUserPrompt = nil
        }

        try await ensureTransport(cwd: resolvedCWD)
        let response = try await copilotRequestWithTimeout(
            method: "session/new",
            params: [
                "cwd": resolvedCWD,
                "mcpServers": []
            ],
            timeoutNanoseconds: 20_000_000_000
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
            emitPendingCopilotSessionTransitionLandingIfNeeded(sessionID: sessionID)
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
                let response = try await copilotRequestWithTimeout(
                    method: "session/load",
                    params: [
                        "sessionId": sessionID,
                        "cwd": resolvedCWD,
                        "mcpServers": []
                    ],
                    timeoutNanoseconds: 20_000_000_000
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
                        emitPendingCopilotSessionTransitionLandingIfNeeded(sessionID: sessionID)
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
            emitPendingCopilotSessionTransitionLandingIfNeeded(sessionID: sessionID)
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
                let response = try await copilotRequestWithTimeout(
                    method: "session/load",
                    params: [
                        "sessionId": sessionID,
                        "cwd": resolvedCWD,
                        "mcpServers": []
                    ],
                    timeoutNanoseconds: 20_000_000_000
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
        _ = try await copilotRequestWithTimeout(
            method: "session/set_mode",
            params: [
                "sessionId": sessionID,
                "modeId": copilotModeID(for: interactionMode)
            ],
            timeoutNanoseconds: 12_000_000_000
        )

        if let requestedModelID = resolvedCopilotRequestedModelID(preferredModelID),
           currentCopilotModelID() != requestedModelID {
            let response = try await copilotRequestWithTimeout(
                method: "session/set_config_option",
                params: [
                    "sessionId": sessionID,
                    "configId": "model",
                    "value": requestedModelID
                ],
                timeoutNanoseconds: 12_000_000_000
            )
            applyCopilotConfiguration(from: response.raw)
        }

        if let reasoningEffort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            do {
                let response = try await copilotRequestWithTimeout(
                    method: "session/set_config_option",
                    params: [
                        "sessionId": sessionID,
                        "configId": "reasoning_effort",
                        "value": reasoningEffort
                    ],
                    timeoutNanoseconds: 12_000_000_000
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
        memoryContext: String?,
        submittedSlashCommand: AssistantSubmittedSlashCommand?
    ) async throws {
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
        prepareCopilotSlashCommandTracking(
            submittedSlashCommand,
            sessionID: sessionID
        )
        updateHUD(phase: .streaming, title: "Starting", detail: nil)
        onHealthUpdate?(makeHealth(availability: .active, summary: backend.activeSummary))

        let attachmentContext = try resolvedCLIAttachmentContext(
            sessionID: sessionID,
            attachments: attachments
        )

        do {
            let response = try await copilotRequestWithTimeout(
                method: "session/prompt",
                params: [
                    "sessionId": sessionID,
                    "prompt": buildCopilotPromptContent(
                        prompt: prompt,
                        resumeContext: resumeContext,
                        memoryContext: memoryContext,
                        attachmentContext: attachmentContext
                    )
                ],
                timeoutNanoseconds: 120_000_000_000
            )
            guard activeTurnID != nil else { return }
            await waitForCopilotResponseMaterializationIfNeeded()
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
        memoryContext: String?,
        attachmentContext: String?
    ) -> [[String: Any]] {
        let combined = [attachmentContext, resumeContext, memoryContext, prompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            .joined(separator: "\n\n")
        return [["type": "text", "text": combined]]
    }

    private func prepareCopilotSlashCommandTracking(
        _ submission: AssistantSubmittedSlashCommand?,
        sessionID: String
    ) {
        pendingCopilotSlashCommand = submission
        pendingCopilotSlashCommandActivityID = nil
        pendingCopilotSessionTransitionCommand = nil

        guard let submission, submission.isTrackable else { return }

        switch submission.trackingMode {
        case .state:
            emitTimelineSystemMessage(
                "Submitted `\(submission.submittedText)`.",
                sessionID: sessionID
            )
            if copilotCommandMayChangeSession(submission.id) {
                pendingCopilotSessionTransitionCommand = submission
            }

        case .work:
            emitTimelineSystemMessage(
                "Started `\(submission.submittedText)`.",
                sessionID: sessionID
            )
            startCopilotSlashCommandActivity(
                submission,
                sessionID: sessionID
            )

        case .localMode, .ignored:
            break
        }
    }

    private func startCopilotSlashCommandActivity(
        _ submission: AssistantSubmittedSlashCommand,
        sessionID: String
    ) {
        let activityID = "copilot-slash-\(UUID().uuidString)"
        pendingCopilotSlashCommandActivityID = activityID
        let detail = compactDetail(
            firstNonEmptyString(
                submission.remainderText,
                submission.descriptor.subtitle
            )
        )
        let title = "Copilot \(submission.label)"

        toolCalls[activityID] = AssistantToolCallState(
            id: activityID,
            title: title,
            kind: "dynamicToolCall",
            status: "running",
            detail: detail,
            hudDetail: "Running \(submission.label)"
        )
        publishToolCallsSnapshot()

        let activity = AssistantActivityItem(
            id: activityID,
            sessionID: sessionID,
            turnID: activeTurnID,
            kind: .dynamicToolCall,
            title: title,
            status: .running,
            friendlySummary: "Started \(submission.label).",
            rawDetails: detail,
            startedAt: Date(),
            updatedAt: Date(),
            source: .runtime
        )
        liveActivities[activityID] = activity
        emitActivityTimelineUpdate(activity, force: true)
    }

    private func copilotCommandMayChangeSession(_ commandID: String) -> Bool {
        switch commandID {
        case "new", "clear", "restart", "resume":
            return true
        default:
            return false
        }
    }

    private func emitPendingCopilotSessionTransitionLandingIfNeeded(
        sessionID: String
    ) {
        guard let submission = pendingCopilotSessionTransitionCommand else { return }
        emitTimelineSystemMessage(
            "Copilot continued `\(submission.commandOnlyText)` in this session.",
            sessionID: sessionID
        )
        pendingCopilotSessionTransitionCommand = nil
    }

    private func updatePendingCopilotSlashCommandActivityDetail(
        _ detail: String?
    ) {
        guard let activityID = pendingCopilotSlashCommandActivityID else { return }
        let compacted = compactDetail(detail)

        if var state = toolCalls[activityID] {
            state.detail = compacted ?? state.detail
            if let compacted {
                state.hudDetail = compacted
            }
            toolCalls[activityID] = state
            publishToolCallsSnapshot()
        }

        if var activity = liveActivities[activityID] {
            activity.rawDetails = compacted ?? activity.rawDetails
            activity.updatedAt = Date()
            liveActivities[activityID] = activity
            emitActivityTimelineUpdate(activity, force: true)
        }
    }

    private func copilotBackgroundTaskTool(
        from update: [String: Any]
    ) -> CopilotBackgroundTaskTool? {
        let rawInput = update["rawInput"] as? [String: Any] ?? [:]
        let candidates = [
            update["title"] as? String,
            rawInput["tool"] as? String,
            rawInput["name"] as? String,
            rawInput["agentTool"] as? String,
            rawInput["taskTool"] as? String
        ]

        for candidate in candidates {
            switch normalizedCopilotTaskToolName(candidate) {
            case CopilotBackgroundTaskTool.task.rawValue:
                return .task
            case CopilotBackgroundTaskTool.readAgent.rawValue:
                return .readAgent
            case CopilotBackgroundTaskTool.writeAgent.rawValue:
                return .writeAgent
            case CopilotBackgroundTaskTool.listAgents.rawValue:
                return .listAgents
            default:
                continue
            }
        }

        return nil
    }

    private func normalizedCopilotTaskToolName(_ rawValue: String?) -> String? {
        rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
            .nonEmpty
    }

    private func handleCopilotBackgroundTaskToolUpdate(
        _ update: [String: Any],
        sessionID: String?,
        isInitial _: Bool
    ) -> Bool {
        guard let tool = copilotBackgroundTaskTool(from: update) else { return false }

        let records = copilotBackgroundTaskRecords(
            from: update,
            tool: tool,
            sessionID: sessionID
        )

        if records.isEmpty {
            updatePendingCopilotSlashCommandActivityDetail(
                firstNonEmptyString(
                    copilotOutputText(from: update),
                    extractString((update["rawInput"] as? [String: Any])?["description"]),
                    extractString(update["rawInput"])
                )
            )
            return true
        }

        for record in records {
            upsertCopilotBackgroundTask(
                record,
                sourceTool: tool
            )
        }

        if let summary = copilotBackgroundTaskSummary() {
            updatePendingCopilotSlashCommandActivityDetail(summary)
        }
        publishSubagents()
        return true
    }

    private func upsertCopilotBackgroundTask(
        _ incoming: CopilotBackgroundTaskRecord,
        sourceTool: CopilotBackgroundTaskTool
    ) {
        let previous = copilotBackgroundTasksByID[incoming.id]
        var merged = previous ?? incoming

        merged.sessionID = incoming.sessionID ?? merged.sessionID ?? activeSessionID
        merged.toolCallID = incoming.toolCallID ?? merged.toolCallID
        merged.description = firstNonEmptyString(incoming.description, merged.description) ?? merged.description
        merged.statusLabel = firstNonEmptyString(incoming.statusLabel, merged.statusLabel) ?? merged.statusLabel
        merged.agentType = firstNonEmptyString(incoming.agentType, merged.agentType)
        merged.prompt = firstNonEmptyString(incoming.prompt, merged.prompt)
        merged.latestIntent = firstNonEmptyString(incoming.latestIntent, merged.latestIntent)
        merged.result = firstNonEmptyString(incoming.result, merged.result)
        merged.error = firstNonEmptyString(incoming.error, merged.error)
        merged.updatedAt = incoming.updatedAt
        merged.sourceSlashCommand = incoming.sourceSlashCommand ?? merged.sourceSlashCommand

        if previous == nil {
            merged.startedAt = incoming.startedAt
        }
        if let completedAt = incoming.completedAt {
            merged.completedAt = completedAt
        }

        if !incoming.recentActivity.isEmpty {
            var seen = Set<String>()
            merged.recentActivity = (incoming.recentActivity + merged.recentActivity)
                .compactMap { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    let normalized = trimmed.lowercased()
                    guard seen.insert(normalized).inserted else { return nil }
                    return trimmed
                }
                .prefix(6)
                .map { $0 }
        }

        copilotBackgroundTasksByID[merged.id] = merged
        if let toolCallID = merged.toolCallID?.nonEmpty {
            copilotBackgroundTaskIDByToolCallID[toolCallID] = merged.id
        }

        emitCopilotBackgroundTaskTimelineMessageIfNeeded(
            previous: previous,
            current: merged,
            sourceTool: sourceTool
        )
    }

    private func emitCopilotBackgroundTaskTimelineMessageIfNeeded(
        previous: CopilotBackgroundTaskRecord?,
        current: CopilotBackgroundTaskRecord,
        sourceTool: CopilotBackgroundTaskTool
    ) {
        let previousStatus = previous?.subagentStatus
        let currentStatus = current.subagentStatus
        let description = current.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskTitle = description.isEmpty ? "Background agent" : description

        if previous == nil {
            emitTimelineSystemMessage(
                "Copilot started background agent: \(taskTitle).",
                sessionID: current.sessionID
            )
            return
        }

        guard previousStatus != currentStatus else {
            if sourceTool == .writeAgent,
               let latestIntent = current.latestIntent,
               latestIntent != previous?.latestIntent {
                emitTimelineSystemMessage(
                    "Copilot sent follow-up instructions to \(taskTitle).",
                    sessionID: current.sessionID
                )
            }
            return
        }

        let message: String
        switch currentStatus {
        case .completed:
            message = "Copilot completed background agent: \(taskTitle)."
        case .errored:
            message = "Copilot background agent needs attention: \(taskTitle)."
        case .waiting:
            message = "Copilot background agent is waiting: \(taskTitle)."
        case .spawning, .running:
            message = "Copilot resumed background agent: \(taskTitle)."
        case .closed:
            message = "Copilot closed background agent: \(taskTitle)."
        }

        emitTimelineSystemMessage(
            message,
            sessionID: current.sessionID
        )
    }

    private func copilotBackgroundTaskSummary() -> String? {
        let activeCount = copilotBackgroundTasksByID.values.filter {
            $0.subagentStatus.isActive
        }.count
        guard activeCount > 0 else { return nil }
        return activeCount == 1
            ? "1 background agent running"
            : "\(activeCount) background agents running"
    }

    private func copilotBackgroundTaskRecords(
        from update: [String: Any],
        tool: CopilotBackgroundTaskTool,
        sessionID: String?
    ) -> [CopilotBackgroundTaskRecord] {
        let rawInput = update["rawInput"] as? [String: Any] ?? [:]
        let rawOutput = update["rawOutput"] as? [String: Any] ?? [:]
        let toolCallID = firstNonEmptyString(update["toolCallId"] as? String)
        let candidateDictionaries = copilotBackgroundTaskCandidateDictionaries(
            output: rawOutput,
            input: rawInput,
            tool: tool
        )
        let fallbackTaskID = firstNonEmptyString(
            copilotBackgroundTaskIdentifier(from: rawInput),
            toolCallID.flatMap { copilotBackgroundTaskIDByToolCallID[$0] },
            toolCallID
        )
        let fallbackDescription = firstNonEmptyString(
            rawInput["description"] as? String,
            rawInput["task"] as? String,
            rawInput["title"] as? String,
            pendingCopilotSlashCommand?.remainderText,
            pendingCopilotSlashCommand?.label,
            "Background agent"
        ) ?? "Background agent"
        let defaultStatus = firstNonEmptyString(
            rawOutput["status"] as? String,
            update["status"] as? String,
            "running"
        ) ?? "running"
        let outputText = copilotOutputText(from: update)

        var results: [CopilotBackgroundTaskRecord] = []
        var seenIDs = Set<String>()
        for candidate in candidateDictionaries {
            guard let taskID = firstNonEmptyString(
                copilotBackgroundTaskIdentifier(from: candidate),
                fallbackTaskID
            ) else {
                continue
            }
            guard seenIDs.insert(taskID).inserted else { continue }

            let statusLabel = firstNonEmptyString(
                candidate["status"] as? String,
                defaultStatus
            ) ?? defaultStatus
            let normalizedStatus = normalizedCopilotTaskStatus(statusLabel)
            let resultText = firstNonEmptyString(
                extractString(candidate["result"]),
                normalizedStatus == "completed" ? outputText : nil
            )
            let errorText = firstNonEmptyString(
                extractString(candidate["error"]),
                normalizedStatus == "failed" ? outputText : nil
            )

            results.append(
                CopilotBackgroundTaskRecord(
                    id: taskID,
                    sessionID: sessionID ?? activeSessionID,
                    toolCallID: toolCallID,
                    description: firstNonEmptyString(
                        candidate["description"] as? String,
                        candidate["title"] as? String,
                        fallbackDescription
                    ) ?? fallbackDescription,
                    statusLabel: statusLabel,
                    agentType: cleanedCopilotAgentType(
                        firstNonEmptyString(
                            candidate["agentType"] as? String,
                            candidate["agent_type"] as? String,
                            rawInput["agentType"] as? String,
                            rawInput["agent_type"] as? String,
                            candidate["agent"] as? String,
                            rawInput["agent"] as? String
                        )
                    ),
                    prompt: firstNonEmptyString(
                        candidate["prompt"] as? String,
                        rawInput["prompt"] as? String,
                        rawInput["instructions"] as? String,
                        rawInput["message"] as? String
                    ),
                    latestIntent: firstNonEmptyString(
                        candidate["latestIntent"] as? String,
                        candidate["latest_intent"] as? String,
                        extractString(candidate["intent"])
                    ),
                    recentActivity: copilotBackgroundTaskRecentActivity(from: candidate),
                    result: resultText,
                    error: errorText,
                    startedAt: previousBackgroundTaskStartDate(
                        taskID: taskID,
                        candidate: candidate
                    ) ?? Date(),
                    updatedAt: Date(),
                    completedAt: normalizedStatus == "completed"
                        || normalizedStatus == "failed"
                        || normalizedStatus == "cancelled"
                        || normalizedStatus == "killed"
                        ? Date() : nil,
                    sourceSlashCommand: pendingCopilotSlashCommand?.label
                )
            )
        }

        if results.isEmpty, let fallbackTaskID {
            let statusLabel = defaultStatus
            let normalizedStatus = normalizedCopilotTaskStatus(statusLabel)
            results.append(
                CopilotBackgroundTaskRecord(
                    id: fallbackTaskID,
                    sessionID: sessionID ?? activeSessionID,
                    toolCallID: toolCallID,
                    description: fallbackDescription,
                    statusLabel: statusLabel,
                    agentType: cleanedCopilotAgentType(
                        firstNonEmptyString(
                            rawInput["agentType"] as? String,
                            rawInput["agent_type"] as? String,
                            rawInput["agent"] as? String
                        )
                    ),
                    prompt: firstNonEmptyString(
                        rawInput["prompt"] as? String,
                        rawInput["instructions"] as? String,
                        rawInput["message"] as? String
                    ),
                    latestIntent: firstNonEmptyString(extractString(rawOutput["latestIntent"])),
                    recentActivity: copilotBackgroundTaskRecentActivity(from: rawOutput),
                    result: normalizedStatus == "completed" ? outputText : nil,
                    error: normalizedStatus == "failed" ? outputText : nil,
                    startedAt: previousBackgroundTaskStartDate(
                        taskID: fallbackTaskID,
                        candidate: rawOutput
                    ) ?? Date(),
                    updatedAt: Date(),
                    completedAt: normalizedStatus == "completed"
                        || normalizedStatus == "failed"
                        || normalizedStatus == "cancelled"
                        || normalizedStatus == "killed"
                        ? Date() : nil,
                    sourceSlashCommand: pendingCopilotSlashCommand?.label
                )
            )
        }

        return results
    }

    private func copilotBackgroundTaskCandidateDictionaries(
        output: [String: Any],
        input: [String: Any],
        tool: CopilotBackgroundTaskTool
    ) -> [[String: Any]] {
        let arrayKeys = ["tasks", "agents", "items", "list", "data", "results"]
        for key in arrayKeys {
            if let rows = output[key] as? [[String: Any]], !rows.isEmpty {
                return rows
            }
            if let values = output[key] as? [Any] {
                let rows = values.compactMap { $0 as? [String: Any] }
                if !rows.isEmpty {
                    return rows
                }
            }
        }

        switch tool {
        case .task, .readAgent, .writeAgent:
            if !output.isEmpty {
                return [output]
            }
            if !input.isEmpty {
                return [input]
            }
            return []
        case .listAgents:
            if !output.isEmpty {
                return [output]
            }
            return []
        }
    }

    private func copilotBackgroundTaskIdentifier(
        from dictionary: [String: Any]
    ) -> String? {
        firstNonEmptyString(
            dictionary["taskId"] as? String,
            dictionary["task_id"] as? String,
            dictionary["agentId"] as? String,
            dictionary["agent_id"] as? String,
            dictionary["id"] as? String,
            (dictionary["task"] as? [String: Any]).flatMap {
                firstNonEmptyString(
                    $0["id"] as? String,
                    $0["taskId"] as? String,
                    $0["agentId"] as? String
                )
            }
        )
    }

    private func previousBackgroundTaskStartDate(
        taskID: String,
        candidate: [String: Any]
    ) -> Date? {
        if let existing = copilotBackgroundTasksByID[taskID] {
            return existing.startedAt
        }

        let timestamp = (candidate["startedAt"] as? TimeInterval)
            ?? (candidate["started_at"] as? TimeInterval)
            ?? (candidate["timestamp"] as? TimeInterval)
        guard let timestamp else { return nil }
        return dateFromPossiblyMilliseconds(timestamp)
    }

    private func dateFromPossiblyMilliseconds(_ value: TimeInterval) -> Date {
        if value > 10_000_000_000 {
            return Date(timeIntervalSince1970: value / 1000)
        }
        return Date(timeIntervalSince1970: value)
    }

    private func copilotBackgroundTaskRecentActivity(
        from dictionary: [String: Any]
    ) -> [String] {
        if let lines = dictionary["recentActivity"] as? [[String: Any]] {
            return lines.compactMap {
                firstNonEmptyString(
                    $0["message"] as? String,
                    $0["text"] as? String,
                    extractString($0["content"])
                )
            }
        }
        if let lines = dictionary["recent_activity"] as? [[String: Any]] {
            return lines.compactMap {
                firstNonEmptyString(
                    $0["message"] as? String,
                    $0["text"] as? String
                )
            }
        }
        if let lines = dictionary["recentActivity"] as? [String] {
            return lines.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        }
        if let lines = dictionary["recent_activity"] as? [String] {
            return lines.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        }
        if let output = firstNonEmptyString(
            dictionary["recentOutput"] as? String,
            dictionary["recent_output"] as? String
        ) {
            return output
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap(\.nonEmpty)
                .prefix(6)
                .map { $0 }
        }
        return []
    }

    private func normalizedCopilotTaskStatus(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    private func cleanedCopilotAgentType(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        let normalized = rawValue.lowercased()
        if normalized == "agent" || normalized == "shell" {
            return nil
        }
        return rawValue
    }

    private func materializeCLIFileAttachments(
        _ attachments: [AssistantAttachment]
    ) throws -> CLIAttachmentMaterialization? {
        guard !attachments.isEmpty else { return nil }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openassist-cli-attachments-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            var usedNames: Set<String> = []
            var lines = [
                "Local attachment files are available on disk for this session.",
                "If the user's request depends on an attachment, inspect the relevant file directly from these paths before answering:"
            ]

            for (index, attachment) in attachments.enumerated() {
                let filename = uniqueCLIAttachmentFilename(
                    attachment.filename,
                    fallbackIndex: index + 1,
                    usedNames: &usedNames
                )
                let fileURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
                try attachment.data.write(to: fileURL, options: .atomic)
                lines.append("- \(attachment.filename) [\(attachment.mimeType)]: \(fileURL.path)")
            }

            lines.append("These attachment paths stay available for follow-up turns in this session until new attachments replace them.")
            return CLIAttachmentMaterialization(
                directoryURL: directoryURL,
                promptContext: lines.joined(separator: "\n")
            )
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw CodexAssistantRuntimeError.requestFailed(
                "Could not prepare local attachment files: \(error.localizedDescription)"
            )
        }
    }

    private func cleanupCLIFileAttachments(_ materialization: CLIAttachmentMaterialization?) {
        guard let directoryURL = materialization?.directoryURL else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func resolvedCLIAttachmentContext(
        sessionID: String,
        attachments: [AssistantAttachment]
    ) throws -> String? {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if persistedCLIAttachmentSessionID != normalizedSessionID {
            clearPersistedCLIAttachmentMaterialization()
        }

        if !attachments.isEmpty {
            clearPersistedCLIAttachmentMaterialization()
            persistedCLIAttachmentMaterialization = try materializeCLIFileAttachments(attachments)
            persistedCLIAttachmentSessionID = normalizedSessionID
        }

        return persistedCLIAttachmentMaterialization?.promptContext
    }

    private func clearPersistedCLIAttachmentMaterialization() {
        cleanupCLIFileAttachments(persistedCLIAttachmentMaterialization)
        persistedCLIAttachmentMaterialization = nil
        persistedCLIAttachmentSessionID = nil
    }

    private func uniqueCLIAttachmentFilename(
        _ filename: String,
        fallbackIndex: Int,
        usedNames: inout Set<String>
    ) -> String {
        let sanitized = sanitizedCLIAttachmentFilename(filename, fallbackIndex: fallbackIndex)
        let normalizedSanitized = sanitized.lowercased()
        if usedNames.insert(normalizedSanitized).inserted {
            return sanitized
        }

        let url = URL(fileURLWithPath: sanitized)
        let stem = url.deletingPathExtension().lastPathComponent.nonEmpty ?? "attachment-\(fallbackIndex)"
        let ext = url.pathExtension

        var suffix = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            if usedNames.insert(candidate.lowercased()).inserted {
                return candidate
            }
            suffix += 1
        }
    }

    private func sanitizedCLIAttachmentFilename(_ filename: String, fallbackIndex: Int) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = URL(fileURLWithPath: trimmed.isEmpty ? "attachment-\(fallbackIndex)" : trimmed)
            .lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return candidate.nonEmpty ?? "attachment-\(fallbackIndex)"
    }

    private func handleCopilotPromptCompletion(from raw: Any) {
        if let directReply = copilotPromptCompletionReply(from: raw) {
            storeCopilotFallbackReply(directReply)
        }
        let stopReason = ((raw as? [String: Any])?["stopReason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch stopReason {
        case "cancelled", "canceled", "interrupted":
            cancelPendingCopilotPromptCompletion()
            handleTurnCompleted(["turn": ["status": "interrupted"]])
        default:
            scheduleCopilotPromptCompletion(["turn": ["status": "completed"]])
        }

        Task { await refreshRateLimits() }
    }

    private func scheduleCopilotPromptCompletion(_ params: [String: Any]) {
        guard backend == .copilot, activeTurnID != nil else {
            cancelPendingCopilotPromptCompletion()
            handleTurnCompleted(params)
            return
        }

        pendingCopilotCompletionParams = params
        pendingCopilotCompletionEmit?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCopilotCompletionEmit = nil

            guard let pendingParams = self.pendingCopilotCompletionParams else { return }

            let elapsed = CFAbsoluteTimeGetCurrent() - self.lastCopilotSessionUpdateTime
            let hasLiveCopilotActivity = !self.liveActivities.isEmpty || !self.toolCalls.isEmpty
            let hasVisibleAssistantOutput =
                self.streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
                || self.pendingCopilotFallbackReply?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
            if Self.shouldDeferCopilotPromptCompletion(
                elapsedSinceLastUpdate: elapsed,
                hasLiveActivity: hasLiveCopilotActivity,
                hasVisibleAssistantOutput: hasVisibleAssistantOutput,
                hasPendingPermissionRequest: self.pendingPermissionContext != nil
            ) {
                self.scheduleCopilotPromptCompletion(pendingParams)
                return
            }

            if hasLiveCopilotActivity {
                let detail = hasVisibleAssistantOutput ? "reply already visible" : "no fresh assistant output"
                CrashReporter.logWarning(
                    "Forcing Copilot turn completion after stale live activity elapsed=\(elapsed)s (\(detail))."
                )
            }

            self.pendingCopilotCompletionParams = nil
            self.handleTurnCompleted(pendingParams)
        }

        pendingCopilotCompletionEmit = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(Self.copilotCompletionQuietPeriodNanoseconds)),
            execute: item
        )
    }

    private func cancelPendingCopilotPromptCompletion() {
        pendingCopilotCompletionEmit?.cancel()
        pendingCopilotCompletionEmit = nil
        pendingCopilotCompletionParams = nil
    }

    private func scheduleClaudeDeferredCompletion() {
        guard backend == .claudeCode, activeTurnID != nil else {
            cancelPendingClaudeCompletion()
            return
        }

        pendingClaudeCompletionEmit?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClaudeCompletionEmit = nil

            guard self.backend == .claudeCode,
                  self.activeTurnID != nil,
                  self.pendingPermissionContext == nil else {
                return
            }

            if self.activeClaudeQueuedPromptContexts.count > 1 {
                self.handleClaudeCodeIntermediateCompletion()
            } else {
                self.handleTurnCompleted(["turn": ["status": "completed"]])
            }
        }

        pendingClaudeCompletionEmit = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(Self.claudeCodeDeferredCompletionGracePeriodNanoseconds)),
            execute: item
        )
    }

    private func cancelPendingClaudeCompletion() {
        pendingClaudeCompletionEmit?.cancel()
        pendingClaudeCompletionEmit = nil
    }

    private func waitForCopilotResponseMaterializationIfNeeded(
        maxWaitNanoseconds: UInt64 = 250_000_000
    ) async {
        guard backend == .copilot,
              activeTurnID != nil,
              streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil,
              pendingCopilotFallbackReply?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil else {
            return
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + maxWaitNanoseconds
        while activeTurnID != nil,
              streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil,
              pendingCopilotFallbackReply?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil,
              DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func listCopilotSessions(limit: Int) async throws -> [AssistantSessionSummary] {
        try await ensureTransport(cwd: currentTransportWorkingDirectory ?? activeSessionCWD)
        let response = try await copilotRequestWithTimeout(
            method: "session/list",
            params: [:],
            timeoutNanoseconds: 15_000_000_000
        )
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

    private func shouldAcceptBackendScopedUpdate(
        expectedBackend: AssistantRuntimeBackend,
        source: String
    ) -> Bool {
        guard backend == expectedBackend else {
            CrashReporter.logInfo(
                "Ignoring \(source) because runtime backend is \(backend.rawValue), expected \(expectedBackend.rawValue)"
            )
            return false
        }
        return true
    }

    private func applyCopilotConfiguration(from raw: Any) {
        guard shouldAcceptBackendScopedUpdate(
            expectedBackend: .copilot,
            source: "copilot.configuration"
        ) else {
            return
        }
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
        let availableRows = flattenedCopilotConfigOptions(
            from: (payload["models"] as? [String: Any])?["availableModels"]
        )
        if !availableRows.isEmpty {
            rows = availableRows
        } else {
            rows = flattenedCopilotConfigOptions(from: modelConfig?["options"])
        }

        guard !rows.isEmpty else { return currentModels }

        let supportedEfforts = flattenedCopilotConfigOptions(from: reasoningConfig?["options"])
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

    private func flattenedCopilotConfigOptions(from rawOptions: Any?) -> [[String: Any]] {
        guard let rawItems = rawOptions as? [Any] else { return [] }

        var flattened: [[String: Any]] = []
        for item in rawItems {
            guard let dictionary = item as? [String: Any] else { continue }

            if dictionary["value"] != nil || dictionary["modelId"] != nil {
                flattened.append(dictionary)
                continue
            }

            if dictionary["group"] != nil || dictionary["options"] != nil {
                flattened.append(contentsOf: flattenedCopilotConfigOptions(from: dictionary["options"]))
            }
        }

        return flattened
    }

    private func normalizedCopilotModelSearchKey(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nonEmpty else {
            return nil
        }

        let tokens = rawValue
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.joined()
    }

    private func copilotModelSearchTokens(_ rawValue: String?) -> [String] {
        guard let rawValue = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nonEmpty else {
            return []
        }

        return rawValue
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func looksLikeSpecificCopilotModelID(_ rawValue: String) -> Bool {
        rawValue.rangeOfCharacter(from: .decimalDigits) != nil
            || rawValue.contains("-")
            || rawValue.contains(".")
            || rawValue.contains("/")
    }

    private func resolvedCopilotRequestedModelID(_ preferredModelID: String?) -> String? {
        guard let requestedModelID = preferredModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty else {
            return nil
        }

        if let exactMatch = currentModels.first(where: {
            $0.id.caseInsensitiveCompare(requestedModelID) == .orderedSame
        }) {
            return exactMatch.id
        }

        let normalizedRequested = normalizedCopilotModelSearchKey(requestedModelID)
        if let normalizedRequested,
           let displayMatch = currentModels.first(where: { model in
               normalizedCopilotModelSearchKey(model.id) == normalizedRequested
                   || normalizedCopilotModelSearchKey(model.displayName) == normalizedRequested
           }) {
            return displayMatch.id
        }

        let requestedTokens = copilotModelSearchTokens(requestedModelID)
        if !requestedTokens.isEmpty,
           let partialMatch = currentModels.first(where: { model in
               let haystacks = [
                   model.id.lowercased(),
                   model.displayName.lowercased(),
                   model.description.lowercased()
               ]
               return requestedTokens.allSatisfy { token in
                   haystacks.contains(where: { $0.contains(token) })
               }
           }) {
            return partialMatch.id
        }

        if currentModels.isEmpty {
            return looksLikeSpecificCopilotModelID(requestedModelID) ? requestedModelID : nil
        }

        return nil
    }

    private func currentCopilotModelID() -> String? {
        currentModels.first(where: \.isDefault)?.id
    }

    private func normalizedClaudeStreamingTextDelta(_ text: String) -> String {
        guard text.count > 1,
              text.hasSuffix("\n") else {
            return text
        }

        let body = text.dropLast()
        guard !body.contains(where: \.isNewline) else {
            return text
        }

        return String(body)
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
        guard shouldAcceptBackendScopedUpdate(
            expectedBackend: .copilot,
            source: "copilot.notification.\(method)"
        ) else {
            return
        }
        guard let sessionID = params["sessionId"] as? String else { return }
        if detachedSessionIDs.contains(sessionID) {
            return
        }
        if let currentActive = activeSessionID, sessionID != currentActive {
            return
        }
        lastCopilotSessionUpdateTime = CFAbsoluteTimeGetCurrent()
        handleCopilotSessionUpdate(params)
    }

    private func handleCopilotServerRequest(
        id: JSONRPCRequestID,
        method: String,
        params: [String: Any]
    ) async {
        guard shouldAcceptBackendScopedUpdate(
            expectedBackend: .copilot,
            source: "copilot.serverRequest.\(method)"
        ) else {
            return
        }
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
            guard Self.shouldAcceptCopilotLiveUpdate(
                updateTurnID: assistantMessageTurnID(from: ["update": update]),
                activeTurnID: activeTurnID
            ) else {
                return
            }
            if shouldSurfaceCopilotThought(delta) {
                appendCommentaryDelta(delta)
            }
            updateHUD(phase: .thinking, title: "Reasoning", detail: nil)
        case "tool_call":
            handleCopilotToolCallUpdate(
                update,
                sessionID: params["sessionId"] as? String,
                isInitial: true
            )
        case "tool_call_update":
            handleCopilotToolCallUpdate(
                update,
                sessionID: params["sessionId"] as? String,
                isInitial: false
            )
        case "config_option_update":
            applyCopilotConfiguration(from: update)
            onHealthUpdate?(connectedHealthForCurrentState())
        default:
            break
        }
    }

    private func handleCopilotToolCallUpdate(
        _ update: [String: Any],
        sessionID: String?,
        isInitial: Bool
    ) {
        let updateTurnID = assistantMessageTurnID(
            from: [
                "sessionId": sessionID as Any,
                "update": update
            ]
        )
        guard Self.shouldAcceptCopilotLiveUpdate(
            updateTurnID: updateTurnID,
            activeTurnID: activeTurnID
        ) else {
            CrashReporter.logInfo(
                "Ignoring late Copilot tool update session=\(sessionID ?? activeSessionID ?? "unknown") turn=\(updateTurnID ?? "missing") activeTurn=\(activeTurnID ?? "none")"
            )
            return
        }

        if handleCopilotBackgroundTaskToolUpdate(
            update,
            sessionID: sessionID,
            isInitial: isInitial
        ) {
            return
        }

        // When the Copilot model uses `task_complete` to deliver its final
        // response, the actual answer lives inside the tool's summary argument
        // or output — not in a streamed `agent_message_chunk`.  Surface it as
        // normal assistant text instead of rendering a tool-activity card.
        if isCopilotTaskCompleteTool(update: update),
           let summary = copilotTaskCompleteSummary(from: update) {
            ensureStreamingIdentifiers()
            let separator = streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil ? "\n\n" : ""
            streamingBuffer += separator + summary
            pendingStreamingDeltaBuffer += separator + summary
            emitStreamingAssistantDelta(force: true)
            updateHUD(phase: .streaming, title: "Responding", detail: nil)
            return
        }

        guard let item = copilotSyntheticItem(from: update) else { return }
        let status = (item["status"] as? String)?.lowercased() ?? "running"
        let isCompleted = !["pending", "running", "waiting", "inprogress", "in_progress"].contains(status)
        let toolOutput = copilotOutputText(from: update)

        if shouldHideCopilotToolActivity(update: update, item: item) {
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
        case "webSearch":
            item["tool"] = title
            item["query"] = firstNonEmptyString(
                rawInput["query"] as? String,
                rawInput["search"] as? String,
                rawInput["text"] as? String
            )
            item["arguments"] = rawInput
        case "browserAutomation":
            item["tool"] = title
            item["action"] = firstNonEmptyString(
                rawInput["action"] as? String,
                rawInput["url"] as? String,
                title
            )
            item["arguments"] = rawInput
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
        let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if rawInput["command"] != nil || rawInput["commands"] != nil || kind == "execute" {
            return "commandExecution"
        }
        if rawInput["files"] != nil || kind == "edit" || title?.localizedCaseInsensitiveContains("edit") == true {
            return "fileChange"
        }
        if rawInput["query"] != nil
            || normalizedKind?.contains("search") == true
            || normalizedTitle?.contains("search") == true {
            return "webSearch"
        }
        if rawInput["url"] != nil
            || normalizedKind?.contains("browser") == true
            || normalizedTitle?.contains("browser") == true {
            return "browserAutomation"
        }
        if normalizedKind?.contains("mcp") == true {
            return "mcpToolCall"
        }
        if normalizedKind == "internal" {
            return "other"
        }
        if normalizedKind != nil || !(rawInput.isEmpty) || title?.nonEmpty != nil {
            return "dynamicToolCall"
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

    private func shouldHideCopilotToolActivity(update: [String: Any], item: [String: Any]) -> Bool {
        let normalizedKind = (update["kind"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedKind == "internal" {
            return true
        }

        let normalizedTitle = firstNonEmptyString(
            update["title"] as? String,
            item["tool"] as? String
        )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalizedTitle?.contains("internal completion") == true {
            return true
        }

        return false
    }

    // MARK: - Copilot task_complete extraction

    /// Returns `true` when the Copilot tool update represents a `task_complete`
    /// call — the mechanism the model uses to deliver its final answer as a
    /// tool argument instead of a streamed assistant message.
    private func isCopilotTaskCompleteTool(update: [String: Any]) -> Bool {
        let normalizedTitle = (update["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedTitle == "task complete" || normalizedTitle == "task_complete" {
            return true
        }
        // Fall back to checking whether rawInput carries a `summary` key,
        // which is the distinctive shape of a task_complete invocation.
        if let rawInput = update["rawInput"] as? [String: Any],
           rawInput["summary"] is String {
            return true
        }
        return false
    }

    /// Extracts the assistant-facing summary text from a `task_complete` tool
    /// update, preferring `rawInput.summary` (the model's own output) and
    /// falling back to the tool result returned by the CLI.
    private func copilotTaskCompleteSummary(from update: [String: Any]) -> String? {
        if let rawInput = update["rawInput"] as? [String: Any],
           let summary = (rawInput["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return summary
        }
        if let output = copilotOutputText(from: update)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            // The tool result often arrives with a "✓ Task completed:" prefix
            // added by the CLI — strip it so the user sees clean prose.
            let prefixes = [
                "\u{2713} task completed:",
                "task completed:",
                "\u{2713} completed:",
                "completed:"
            ]
            let lowered = output.lowercased()
            for prefix in prefixes {
                if lowered.hasPrefix(prefix) {
                    let stripped = String(output.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !stripped.isEmpty { return stripped }
                }
            }
            return output
        }
        return nil
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

    private func copilotPromptCompletionReply(from raw: Any) -> String? {
        guard let payload = raw as? [String: Any] else { return nil }

        if let messages = payload["messages"] as? [Any] {
            for message in messages.reversed() {
                if let text = copilotVisibleMessageText(from: message),
                   let reply = copilotFallbackReplyCandidate(from: text) {
                    return reply
                }
            }
        }

        for key in ["assistantMessage", "assistant_message", "message", "response", "output", "content", "result"] {
            if let text = copilotVisibleMessageText(from: payload[key]),
               let reply = copilotFallbackReplyCandidate(from: text) {
                return reply
            }
        }

        return nil
    }

    private func copilotVisibleMessageText(from raw: Any?) -> String? {
        if let text = raw as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }

        if let array = raw as? [Any] {
            let assistantOnly = array.compactMap { element -> String? in
                guard let dictionary = element as? [String: Any] else {
                    return nil
                }
                if let role = (dictionary["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                   role != "assistant",
                   role != "model" {
                    return nil
                }
                return copilotVisibleMessageText(from: dictionary)
            }
            .joined(separator: "\n")

            if let text = assistantOnly.nonEmpty {
                return text
            }

            let merged = array.compactMap { copilotVisibleMessageText(from: $0) }.joined(separator: "\n")
            return merged.nonEmpty
        }

        guard let dictionary = raw as? [String: Any] else {
            return nil
        }

        if let role = (dictionary["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           role != "assistant",
           role != "model" {
            return nil
        }

        if let content = dictionary["content"] as? [[String: Any]] {
            let joined = content.compactMap { item -> String? in
                if let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    return text
                }
                if let nested = item["content"] as? [String: Any] {
                    return copilotVisibleMessageText(from: nested)
                }
                return nil
            }
            .joined(separator: "\n")

            if let text = joined.nonEmpty {
                return text
            }
        }

        if let content = dictionary["content"] {
            if let text = copilotVisibleMessageText(from: content) {
                return text
            }
        }

        if let message = dictionary["message"] {
            if let text = copilotVisibleMessageText(from: message) {
                return text
            }
        }

        return firstNonEmptyString(
            (dictionary["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            extractString(dictionary["output"]),
            extractString(dictionary["result"]),
            extractString(dictionary["response"])
        )
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
    private let incoming: @Sendable (CodexIncomingEvent) async -> Void
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextClientRequestID = 1
    private var responseContinuations: [JSONRPCRequestID: CheckedContinuation<CodexResponsePayload, Error>] = [:]
    private var bufferedResponses: [JSONRPCRequestID: Result<CodexResponsePayload, Error>] = [:]
    private var expectedTermination = false

    init(incoming: @escaping @Sendable (CodexIncomingEvent) async -> Void) {
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
        process.terminationHandler = { [weak self] process in
            Task {
                await self?.handleProcessTermination(process, launchLabel: launchLabel)
            }
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
        expectedTermination = true
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

    private func handleProcessTermination(_ terminatedProcess: Process, launchLabel: String) async {
        let wasExpected = expectedTermination || process == nil || process !== terminatedProcess
        expectedTermination = false
        guard !wasExpected else { return }

        let message: String?
        if terminatedProcess.terminationReason == .uncaughtSignal {
            message = "\(launchLabel) exited because of a signal."
        } else if terminatedProcess.terminationStatus != 0 {
            message = "\(launchLabel) exited with code \(terminatedProcess.terminationStatus)."
        } else {
            message = nil
        }

        await incoming(.processExited(message: message, expected: false))
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
                    await incoming(.statusMessage(line))
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
            await incoming(.statusMessage("Received non-JSON output from Codex App Server."))
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
            await incoming(.serverRequest(id: requestID, method: method, params: params))
        } else {
            await incoming(.notification(method: method, params: params))
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

// MARK: - MCP Tool Bridge Delegate

extension CodexAssistantRuntime: AssistantMCPToolBridgeDelegate {
    nonisolated func mcpBridgeExecute(
        toolName: String,
        arguments: Any,
        sessionID: String
    ) async -> AssistantToolExecutionResult {
        let resolvedSessionID: String = await MainActor.run {
            sessionID.isEmpty ? (self.activeSessionID ?? "") : sessionID
        }
        let resolvedModelID: String? = await MainActor.run {
            self.preferredModelID
        }
        let resolvedInteractionMode: AssistantInteractionMode = await MainActor.run {
            self.interactionMode
        }
        let resolvedAssistantNotesContext: AssistantNotesRuntimeContext? = await MainActor.run {
            self.assistantNotesContext
        }
        let context = AssistantToolExecutionContext(
            toolName: toolName,
            arguments: arguments,
            attachments: [],
            sessionID: resolvedSessionID,
            assistantNotesContext: resolvedAssistantNotesContext,
            preferredModelID: resolvedModelID,
            browserLoginResume: false,
            interactionMode: resolvedInteractionMode
        )
        return await self.toolExecutor.execute(context)
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var merged = lhs
        merged.append(rhs)
        return merged
    }
}
