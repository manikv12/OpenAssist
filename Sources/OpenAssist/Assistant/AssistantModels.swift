import AppKit
import Combine
import Foundation

enum AssistantPermissionGrantState: String, Codable, Sendable {
    case granted
    case missing
    case unknown
}

struct AssistantPermissionSnapshot: Equatable, Sendable {
    var accessibility: AssistantPermissionGrantState
    var screenRecording: AssistantPermissionGrantState
    var microphone: AssistantPermissionGrantState
    var speechRecognition: AssistantPermissionGrantState
    var appleEvents: AssistantPermissionGrantState
    var fullDiskAccess: AssistantPermissionGrantState

    static let unknown = AssistantPermissionSnapshot(
        accessibility: .unknown,
        screenRecording: .unknown,
        microphone: .unknown,
        speechRecognition: .unknown,
        appleEvents: .unknown,
        fullDiskAccess: .unknown
    )
}

enum AssistantHUDPhase: String, Codable, Sendable {
    case idle
    case listening
    case thinking
    case acting
    case waitingForPermission
    case streaming
    case success
    case failed
}

struct AssistantHUDState: Equatable, Sendable {
    var phase: AssistantHUDPhase
    var title: String
    var detail: String?

    static let idle = AssistantHUDState(phase: .idle, title: "Assistant is ready", detail: nil)

    var shortLabel: String {
        switch phase {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .acting: return "Working"
        case .waitingForPermission: return "Waiting"
        case .streaming: return "Streaming"
        case .success: return "Finished"
        case .failed: return "Needs Attention"
        }
    }
}

enum AssistantRuntimeAvailability: String, Codable, Sendable {
    case idle
    case checking
    case unavailable
    case installRequired
    case loginRequired
    case ready
    case connecting
    case active
    case failed
}

struct AssistantRuntimeHealth: Equatable, Sendable {
    var availability: AssistantRuntimeAvailability
    var summary: String
    var detail: String?
    var runtimePath: String?
    var selectedModelID: String?
    var accountEmail: String?
    var accountPlan: String?

    static let idle = AssistantRuntimeHealth(
        availability: .idle,
        summary: "Assistant is idle",
        detail: nil,
        runtimePath: nil,
        selectedModelID: nil,
        accountEmail: nil,
        accountPlan: nil
    )
}

struct RateLimitWindow: Equatable, Sendable {
    var usedPercent: Int
    var resetsAt: Date?
    var windowDurationMins: Int?

    var remainingPercent: Int { max(0, 100 - usedPercent) }

    var windowLabel: String {
        guard let mins = windowDurationMins, mins > 0 else { return "" }
        if mins >= 10080 { return "Weekly" }
        if mins >= 1440 { return "Daily" }
        let hours = mins / 60
        if hours > 0 { return "\(hours)h" }
        return "\(mins)m"
    }

    var resetsInLabel: String? {
        guard let resetsAt else { return nil }
        guard resetsAt.timeIntervalSinceNow > 0 else { return "now" }
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = false
        let calendar = Calendar.current
        if calendar.isDateInToday(resetsAt) {
            formatter.dateFormat = "'today at' h:mm a"
        } else if calendar.isDateInTomorrow(resetsAt) {
            formatter.dateFormat = "'tomorrow at' h:mm a"
        } else {
            formatter.dateFormat = "EEE h:mm a"
        }
        return formatter.string(from: resetsAt)
    }

    init?(from dict: [String: Any]?) {
        guard let dict, let usedPercent = dict["usedPercent"] as? Int else { return nil }
        self.usedPercent = usedPercent
        if let resetsAt = dict["resetsAt"] as? Int {
            self.resetsAt = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        }
        self.windowDurationMins = dict["windowDurationMins"] as? Int
    }
}

struct AccountRateLimits: Equatable, Sendable {
    var planType: String?
    var primary: RateLimitWindow?
    var secondary: RateLimitWindow?
    var hasCredits: Bool
    var unlimited: Bool

    static let empty = AccountRateLimits(
        planType: nil, primary: nil, secondary: nil,
        hasCredits: true, unlimited: false
    )

    var isEmpty: Bool {
        primary == nil && secondary == nil
    }

    /// Returns the window with the highest usage percent, for compact display.
    var mostUsedWindow: RateLimitWindow? {
        switch (primary, secondary) {
        case let (p?, s?): return p.usedPercent >= s.usedPercent ? p : s
        case let (p?, nil): return p
        case let (nil, s?): return s
        case (nil, nil): return nil
        }
    }
}

struct TokenUsageBreakdown: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int
    var reasoningOutputTokens: Int
    var totalTokens: Int

    static let zero = TokenUsageBreakdown(
        inputTokens: 0, outputTokens: 0, cachedInputTokens: 0,
        reasoningOutputTokens: 0, totalTokens: 0
    )

    init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0,
         reasoningOutputTokens: Int = 0, totalTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    init?(from dict: [String: Any]) {
        guard let total = dict["totalTokens"] as? Int ?? dict["total_tokens"] as? Int else {
            return nil
        }
        self.inputTokens = dict["inputTokens"] as? Int ?? dict["input_tokens"] as? Int ?? 0
        self.outputTokens = dict["outputTokens"] as? Int ?? dict["output_tokens"] as? Int ?? 0
        self.cachedInputTokens = dict["cachedInputTokens"] as? Int ?? dict["cached_input_tokens"] as? Int ?? 0
        self.reasoningOutputTokens = dict["reasoningOutputTokens"] as? Int ?? dict["reasoning_output_tokens"] as? Int ?? 0
        self.totalTokens = total
    }
}

struct TokenUsageSnapshot: Equatable, Sendable {
    var last: TokenUsageBreakdown
    var total: TokenUsageBreakdown
    var modelContextWindow: Int?

    static let empty = TokenUsageSnapshot(last: .zero, total: .zero, modelContextWindow: nil)

    /// Current context size is the last turn's input tokens (what's actually in the context window).
    var currentContextTokens: Int {
        last.inputTokens
    }

    var contextUsageFraction: Double? {
        guard let window = modelContextWindow, window > 0 else { return nil }
        return min(Double(currentContextTokens) / Double(window), 1.0)
    }

    var contextSummary: String {
        let usedK = formatTokenCount(currentContextTokens)
        if let window = modelContextWindow, window > 0 {
            let windowK = formatTokenCount(window)
            return "\(usedK) / \(windowK)"
        }
        return usedK
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

struct SubagentState: Identifiable, Equatable, Sendable {
    let id: String
    var threadID: String?
    var nickname: String?
    var role: String?
    var status: SubagentStatus
    var prompt: String?

    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        if let role, !role.isEmpty { return role }
        return "Agent \(id.prefix(6))"
    }
}

enum SubagentStatus: String, Equatable, Sendable {
    case spawning
    case running
    case waiting
    case completed
    case errored
    case closed

    var isActive: Bool {
        switch self {
        case .spawning, .running, .waiting: return true
        case .completed, .errored, .closed: return false
        }
    }

    var icon: String {
        switch self {
        case .spawning: return "arrow.triangle.2.circlepath"
        case .running: return "play.circle.fill"
        case .waiting: return "hourglass"
        case .completed: return "checkmark.circle.fill"
        case .errored: return "exclamationmark.circle.fill"
        case .closed: return "xmark.circle"
        }
    }

    var tint: String {
        switch self {
        case .spawning, .running: return "blue"
        case .waiting: return "orange"
        case .completed: return "green"
        case .errored: return "red"
        case .closed: return "gray"
        }
    }
}

enum AssistantReasoningEffort: String, CaseIterable, Codable, Sendable {
    case low
    case medium
    case high
    case xhigh

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        }
    }

    /// Wire value sent to Codex turn/start `effort` parameter.
    var wireValue: String { rawValue }
}

enum AssistantTranscriptRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case status
    case tool
    case permission
    case error
}

/// An attachment (image or file) queued for sending with the next prompt.
struct AssistantAttachment: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    let data: Data
    let mimeType: String

    var isImage: Bool { mimeType.hasPrefix("image/") }

    /// Build the Codex input item for this attachment.
    func toInputItem() -> [String: Any] {
        if isImage {
            let base64 = data.base64EncodedString()
            return [
                "type": "image",
                "url": "data:\(mimeType);base64,\(base64)"
            ]
        } else {
            let text = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
            return [
                "type": "text",
                "text": "[\(filename)]\n\(text)"
            ]
        }
    }

    static func == (lhs: AssistantAttachment, rhs: AssistantAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

struct AssistantTranscriptEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: AssistantTranscriptRole
    let text: String
    let createdAt: Date
    let emphasis: Bool
    let isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: AssistantTranscriptRole,
        text: String,
        createdAt: Date = Date(),
        emphasis: Bool = false,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.emphasis = emphasis
        self.isStreaming = isStreaming
    }
}

enum AssistantSessionSource: String, Codable, Sendable, CaseIterable {
    case cli
    case vscode
    case appServer
    case other

    var label: String {
        switch self {
        case .cli: return "CLI"
        case .vscode: return "VS Code"
        case .appServer: return "Open Assist"
        case .other: return "Other"
        }
    }
}

enum AssistantSessionStatus: String, Codable, Sendable {
    case unknown
    case idle
    case active
    case waitingForApproval
    case waitingForInput
    case completed
    case failed
}

struct AssistantSessionSummary: Identifiable, Equatable, Codable, Sendable {
    let id: String
    var title: String
    var source: AssistantSessionSource
    var status: AssistantSessionStatus
    var cwd: String?
    var createdAt: Date?
    var updatedAt: Date?
    var summary: String?
    var latestModel: String?
    var latestInteractionMode: AssistantInteractionMode?
    var latestReasoningEffort: AssistantReasoningEffort?
    var latestServiceTier: String?
    var latestUserMessage: String?
    var latestAssistantMessage: String?

    init(
        id: String,
        title: String,
        source: AssistantSessionSource,
        status: AssistantSessionStatus,
        cwd: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        summary: String? = nil,
        latestModel: String? = nil,
        latestInteractionMode: AssistantInteractionMode? = nil,
        latestReasoningEffort: AssistantReasoningEffort? = nil,
        latestServiceTier: String? = nil,
        latestUserMessage: String? = nil,
        latestAssistantMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.status = status
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.summary = summary
        self.latestModel = latestModel
        self.latestInteractionMode = latestInteractionMode
        self.latestReasoningEffort = latestReasoningEffort
        self.latestServiceTier = latestServiceTier
        self.latestUserMessage = latestUserMessage
        self.latestAssistantMessage = latestAssistantMessage
    }

    var subtitle: String {
        if let latestAssistantMessage, !latestAssistantMessage.isEmpty { return latestAssistantMessage }
        if let summary, !summary.isEmpty { return summary }
        if let latestUserMessage, !latestUserMessage.isEmpty { return latestUserMessage }
        if let cwd, !cwd.isEmpty { return cwd }
        return "No recent summary"
    }

    var detail: String {
        if let latestAssistantMessage, !latestAssistantMessage.isEmpty { return latestAssistantMessage }
        if let summary, !summary.isEmpty { return summary }
        if let latestUserMessage, !latestUserMessage.isEmpty { return latestUserMessage }
        return ""
    }

    var isLocalSession: Bool {
        true
    }

    var modelID: String? {
        get { latestModel }
        set { latestModel = newValue }
    }

    var fastModeEnabled: Bool {
        latestServiceTier?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("fast") == .orderedSame
    }

    var latestUserSnippet: String? {
        get { latestUserMessage }
        set { latestUserMessage = newValue }
    }

    var latestAssistantSnippet: String? {
        get { latestAssistantMessage }
        set { latestAssistantMessage = newValue }
    }
}

/// The interaction mode for the assistant session.
/// - `conversational`: Chat-only mode with no execution and no structured planning flow.
/// - `plan`: Planning mode that proposes a plan without executing work.
/// - `agentic`: The agent has full tool access to execute work (Codex Default mode).
enum AssistantInteractionMode: String, CaseIterable, Codable, Sendable {
    case conversational
    case plan
    case agentic

    var label: String {
        switch self {
        case .conversational: return "Chat"
        case .plan: return "Plan"
        case .agentic: return "Agentic"
        }
    }

    var icon: String {
        switch self {
        case .conversational: return "bubble.left.and.text.bubble.right"
        case .plan: return "list.bullet.rectangle"
        case .agentic: return "hammer"
        }
    }

    var hint: String {
        switch self {
        case .conversational: return "Inspect files and search, but do not make changes"
        case .plan: return "Use Codex plan mode and ask for approval when execution is needed"
        case .agentic: return "Full tool access to inspect and make changes"
        }
    }

    /// The Codex `ModeKind` value sent in the `collaborationMode` field.
    var codexModeKind: String {
        switch self {
        case .conversational: return "default"
        case .plan: return "plan"
        case .agentic: return "default"
        }
    }
}

struct AssistantModeSwitchChoice: Identifiable, Equatable, Sendable {
    let mode: AssistantInteractionMode
    let title: String
    let resendLastRequest: Bool

    var id: String {
        "\(mode.rawValue)-\(resendLastRequest ? "retry" : "switch")"
    }
}

struct AssistantModeSwitchSuggestion: Equatable, Sendable {
    enum Source: String, Sendable {
        case draft
        case blocked
    }

    let source: Source
    let originMode: AssistantInteractionMode
    let message: String
    let choices: [AssistantModeSwitchChoice]
}

struct AssistantModeRestrictionEvent: Equatable, Sendable {
    let mode: AssistantInteractionMode
    let activityTitle: String?
    let commandClass: AssistantCommandSafetyClass?
}

struct AssistantPlanEntry: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let content: String
    let status: String
    let priority: String?

    init(id: UUID = UUID(), content: String, status: String, priority: String? = nil) {
        self.id = id
        self.content = content
        self.status = status
        self.priority = priority
    }
}

struct AssistantToolCallState: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var kind: String?
    var status: String
    var detail: String?
    /// Short, human-friendly description for the HUD orb (falls back to `detail`).
    var hudDetail: String?
}

struct AssistantPermissionOption: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let kind: String?
    let isDefault: Bool
}

struct AssistantUserInputQuestionOption: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let label: String
    let detail: String?
}

struct AssistantUserInputQuestion: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let header: String
    let prompt: String
    let options: [AssistantUserInputQuestionOption]
    let allowsCustomAnswer: Bool
}

struct AssistantPermissionRequest: Identifiable, Equatable, Codable, Sendable {
    let id: Int
    let sessionID: String
    let toolTitle: String
    let toolKind: String?
    let rationale: String?
    let options: [AssistantPermissionOption]
    let userInputQuestions: [AssistantUserInputQuestion]
    let rawPayloadSummary: String?

    var hasStructuredUserInput: Bool {
        toolKind == "userInput" && !userInputQuestions.isEmpty
    }

    init(
        id: Int,
        sessionID: String,
        toolTitle: String,
        toolKind: String?,
        rationale: String?,
        options: [AssistantPermissionOption],
        userInputQuestions: [AssistantUserInputQuestion] = [],
        rawPayloadSummary: String?
    ) {
        self.id = id
        self.sessionID = sessionID
        self.toolTitle = toolTitle
        self.toolKind = toolKind
        self.rationale = rationale
        self.options = options
        self.userInputQuestions = userInputQuestions
        self.rawPayloadSummary = rawPayloadSummary
    }
}

struct AssistantInstallGuidance: Equatable, Sendable {
    var codexDetected: Bool
    var brewDetected: Bool
    var npmDetected: Bool
    var codexPath: String?
    var brewPath: String?
    var npmPath: String?
    var primaryTitle: String
    var primaryDetail: String
    var installCommands: [String]
    var loginCommands: [String]
    var docsURL: URL?

    static let placeholder = AssistantInstallGuidance(
        codexDetected: false,
        brewDetected: false,
        npmDetected: false,
        codexPath: nil,
        brewPath: nil,
        npmPath: nil,
        primaryTitle: "Checking Codex…",
        primaryDetail: "Open Assist is looking for Codex on this Mac.",
        installCommands: [],
        loginCommands: [],
        docsURL: nil
    )
}

enum AssistantEnvironmentState {
    case missingCodex
    case needsLogin
    case ready
    case failed

    var headline: String {
        switch self {
        case .missingCodex: return "Install Codex"
        case .needsLogin: return "Sign in to Codex"
        case .ready: return "Codex is ready"
        case .failed: return "Assistant setup needs attention"
        }
    }
}

struct AssistantEnvironmentSnapshot {
    let state: AssistantEnvironmentState
    let installHelpText: String
}

enum AssistantAccountAuthMode: String, Codable, Sendable {
    case none
    case chatGPT
    case apiKey

    var label: String {
        switch self {
        case .none: return "Signed out"
        case .chatGPT: return "ChatGPT"
        case .apiKey: return "API key"
        }
    }
}

struct AssistantAccountSnapshot: Equatable, Sendable {
    var authMode: AssistantAccountAuthMode
    var email: String?
    var planType: String?
    var requiresOpenAIAuth: Bool
    var loginInProgress: Bool
    var pendingLoginURL: URL?
    var pendingLoginID: String?

    static let signedOut = AssistantAccountSnapshot(
        authMode: .none,
        email: nil,
        planType: nil,
        requiresOpenAIAuth: false,
        loginInProgress: false,
        pendingLoginURL: nil,
        pendingLoginID: nil
    )

    var isLoggedIn: Bool {
        authMode != .none
    }

    var summary: String {
        switch authMode {
        case .none:
            return requiresOpenAIAuth ? "Sign in with ChatGPT to use the assistant." : "Codex is not signed in yet."
        case .chatGPT:
            if let email, let planType {
                return "\(email) · \(planType.capitalized)"
            }
            if let email {
                return email
            }
            return "Signed in with ChatGPT"
        case .apiKey:
            return "Using an OpenAI API key"
        }
    }
}

struct AssistantModelOption: Identifiable, Equatable, Sendable {
    let id: String
    var displayName: String
    var description: String
    var isDefault: Bool
    var hidden: Bool
    var supportedReasoningEfforts: [String]
    var defaultReasoningEffort: String?
    var inputModalities: [String] = []

    var supportsImageInput: Bool {
        inputModalities.contains { modality in
            let normalized = modality.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "image" || normalized == "vision"
        }
    }

    var hasKnownInputModalities: Bool {
        !inputModalities.isEmpty
    }

    static func normalizedInputModalities(from raw: Any?) -> [String] {
        let values: [String]

        if let strings = raw as? [String] {
            values = strings
        } else if let rows = raw as? [[String: Any]] {
            values = rows.compactMap { row in
                (row["modality"] as? String)
                    ?? (row["type"] as? String)
                    ?? (row["name"] as? String)
            }
        } else if let array = raw as? [Any] {
            values = array.compactMap { value in
                if let text = value as? String {
                    return text
                }
                if let row = value as? [String: Any] {
                    return (row["modality"] as? String)
                        ?? (row["type"] as? String)
                        ?? (row["name"] as? String)
                }
                return nil
            }
        } else {
            values = []
        }

        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { return nil }
            seen.insert(normalized)
            return normalized
        }
    }
}

struct AssistantEnvironmentDetails: Sendable {
    let health: AssistantRuntimeHealth
    let account: AssistantAccountSnapshot
    let models: [AssistantModelOption]
}

typealias AssistantFeatureController = AssistantStore

@MainActor
final class AssistantStore: ObservableObject {
    static let shared = AssistantStore()

    @Published private(set) var runtimeHealth: AssistantRuntimeHealth = .idle
    @Published private(set) var installGuidance: AssistantInstallGuidance = .placeholder
    @Published private(set) var permissions: AssistantPermissionSnapshot = .unknown
    @Published private(set) var sessions: [AssistantSessionSummary] = []
    @Published var visibleSessionsLimit: Int = 10
    
    func loadMoreSessions() {
        visibleSessionsLimit += 10
    }
    @Published private(set) var timelineItems: [AssistantTimelineItem] = []
    /// Pre-computed render items, rebuilt only when `timelineItems` changes (not on every @Published update).
    @Published private(set) var cachedRenderItems: [AssistantTimelineRenderItem] = []
    @Published private(set) var transcript: [AssistantTranscriptEntry] = []
    @Published private(set) var planEntries: [AssistantPlanEntry] = []
    @Published private(set) var toolCalls: [AssistantToolCallState] = []
    @Published private(set) var recentToolCalls: [AssistantToolCallState] = []
    @Published private(set) var pendingPermissionRequest: AssistantPermissionRequest?
    @Published private(set) var hudState: AssistantHUDState = .idle
    @Published private(set) var accountSnapshot: AssistantAccountSnapshot = .signedOut
    @Published private(set) var availableModels: [AssistantModelOption] = []
    @Published private(set) var selectedModelID: String?
    @Published private(set) var isLoadingModels = false
    @Published var promptDraft = "" {
        didSet {
            if promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil {
                blockedModeSwitchSuggestion = nil
            }
            refreshModeSwitchSuggestion()
        }
    }
    @Published var selectedSessionID: String?
    @Published var assistantEnabled = false
    @Published var lastStatusMessage: String?
    @Published var showBrowserProfilePicker = false
    @Published private(set) var isTransitioningSession = false
    @Published var sessionInstructions: String = ""
    @Published private(set) var tokenUsage: TokenUsageSnapshot = .empty
    @Published private(set) var rateLimits: AccountRateLimits = .empty
    @Published private(set) var subagents: [SubagentState] = []
    @Published private(set) var voiceCaptureLevel: Float = 0
    @Published var reasoningEffort: AssistantReasoningEffort = .high
    @Published var fastModeEnabled = false {
        didSet {
            guard oldValue != fastModeEnabled else { return }
            runtime.serviceTier = fastModeEnabled ? "fast" : nil
            guard !isRestoringSessionConfiguration else { return }
            updateVisibleSessionConfiguration()
            Task { @MainActor [weak self] in
                await self?.refreshCurrentSessionConfigurationForModeChange()
            }
        }
    }
    @Published var interactionMode: AssistantInteractionMode = .conversational {
        didSet {
            refreshModeSwitchSuggestion()
            guard oldValue != interactionMode else { return }
            guard !isRestoringSessionConfiguration else { return }
            updateVisibleSessionConfiguration()
            Task { @MainActor [weak self] in
                await self?.refreshCurrentSessionConfigurationForModeChange()
            }
        }
    }
    @Published private(set) var proposedPlan: String?
    @Published var attachments: [AssistantAttachment] = []
    @Published private(set) var modeSwitchSuggestion: AssistantModeSwitchSuggestion?
    @Published private(set) var currentMemoryFileURL: URL?
    @Published private(set) var memoryStatusMessage: String?
    @Published private(set) var pendingMemorySuggestions: [AssistantMemorySuggestion] = []
    @Published var showMemorySuggestionReview = false

    let installSupport: CodexInstallSupport
    let sessionCatalog: CodexSessionCatalog
    let runtime: CodexAssistantRuntime
    private let settings: SettingsStore
    private let threadMemoryService: AssistantThreadMemoryService
    private let memoryRetrievalService: AssistantMemoryRetrievalService
    private let memorySuggestionService: AssistantMemorySuggestionService
    private var lastSubmittedPrompt: String?
    private var transcriptSessionID: String?
    private var timelineSessionID: String?
    private var transcriptEntriesBySessionID: [String: [AssistantTranscriptEntry]] = [:]
    private var timelineItemsBySessionID: [String: [AssistantTimelineItem]] = [:]
    private var sessionLoadRequestID = UUID()
    private var isSendingPrompt = false
    private var isRefreshingEnvironment = false
    private var isRefreshingSessions = false
    private var isRestoringSessionConfiguration = false
    private var oneShotSessionInstructions: String?
    private var blockedModeSwitchSuggestion: AssistantModeSwitchSuggestion?
    private var proposedPlanSessionID: String?
    private var memoryScopeBySessionID: [String: MemoryScopeContext] = [:]
    private var pendingResumeContextSessionIDs: Set<String> = []
    private var lastSubmittedAttachments: [AssistantAttachment] = []

    private init(
        installSupport: CodexInstallSupport = CodexInstallSupport(),
        sessionCatalog: CodexSessionCatalog = CodexSessionCatalog(),
        runtime: CodexAssistantRuntime? = nil,
        settings: SettingsStore? = nil,
        memoryStore: MemorySQLiteStore? = nil,
        threadMemoryService: AssistantThreadMemoryService? = nil,
        memoryRetrievalService: AssistantMemoryRetrievalService? = nil,
        memorySuggestionService: AssistantMemorySuggestionService? = nil
    ) {
        self.installSupport = installSupport
        self.sessionCatalog = sessionCatalog
        self.settings = settings ?? .shared
        self.selectedModelID = self.settings.assistantPreferredModelID.nonEmpty
        self.runtime = runtime ?? CodexAssistantRuntime(preferredModelID: self.settings.assistantPreferredModelID.nonEmpty)
        let resolvedMemoryStore = memoryStore ?? (try? MemorySQLiteStore()) ?? MemorySQLiteStore.fallback()
        let resolvedThreadMemoryService = threadMemoryService ?? AssistantThreadMemoryService()
        self.threadMemoryService = resolvedThreadMemoryService
        self.memoryRetrievalService = memoryRetrievalService ?? AssistantMemoryRetrievalService(
            store: resolvedMemoryStore,
            threadMemoryService: resolvedThreadMemoryService
        )
        self.memorySuggestionService = memorySuggestionService ?? AssistantMemorySuggestionService(
            threadMemoryService: resolvedThreadMemoryService,
            store: resolvedMemoryStore
        )

        self.runtime.onHealthUpdate = { [weak self] health in
            Task { @MainActor in
                self?.runtimeHealth = health
                switch health.availability {
                case .installRequired, .loginRequired, .failed, .unavailable:
                    self?.isLoadingModels = false
                case .ready, .active:
                    if let detail = health.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !detail.isEmpty,
                       !detail.localizedCaseInsensitiveContains("loading model") {
                        self?.isLoadingModels = false
                    }
                default:
                    break
                }
            }
        }
        self.runtime.onTranscript = { [weak self] entry in
            Task { @MainActor in
                let runtimeSessionID = self?.runtime.currentSessionID ?? self?.selectedSessionID
                self?.appendTranscriptEntry(entry, sessionID: runtimeSessionID)
            }
        }
        self.runtime.onTimelineMutation = { [weak self] mutation in
            Task { @MainActor in
                self?.applyTimelineMutation(mutation)
            }
        }
        self.runtime.onHUDUpdate = { [weak self] state in
            Task { @MainActor in self?.hudState = state }
        }
        self.runtime.onModeRestriction = { [weak self] event in
            Task { @MainActor in
                self?.blockedModeSwitchSuggestion = Self.modeSwitchSuggestion(for: event)
                self?.refreshModeSwitchSuggestion()
            }
        }
        self.runtime.onPlanUpdate = { [weak self] entries in
            Task { @MainActor in self?.planEntries = entries }
        }
        self.runtime.onToolCallUpdate = { [weak self] calls in
            Task { @MainActor in self?.updateToolCallActivity(calls) }
        }
        self.runtime.onPermissionRequest = { [weak self] request in
            Task { @MainActor in
                // Auto-approve if tool kind is in always-approved set
                if let request,
                   let toolKind = request.toolKind,
                   self?.settings.assistantAlwaysApprovedToolKinds.contains(toolKind) == true {
                    let sessionOption = request.options.first(where: { $0.id == "acceptForSession" })
                        ?? request.options.first(where: { $0.isDefault })
                    if let optionID = sessionOption?.id {
                        await self?.runtime.respondToPermissionRequest(optionID: optionID)
                        return
                    }
                }

                self?.pendingPermissionRequest = request
                if request != nil {
                    self?.hudState = AssistantHUDState(
                        phase: .waitingForPermission,
                        title: "Waiting for approval",
                        detail: request?.toolTitle
                    )
                }
            }
        }
        self.runtime.onSessionChange = { [weak self] sessionID in
            Task { @MainActor in
                self?.selectedSessionID = sessionID
                self?.transcriptSessionID = sessionID
                if self?.timelineSessionID == nil {
                    self?.timelineSessionID = sessionID
                }
                self?.clearActiveProposedPlanIfNeeded(for: sessionID)
                self?.ensureSessionVisible(sessionID)
                self?.refreshMemoryState(for: sessionID)
            }
        }
        self.runtime.onStatusMessage = { [weak self] message in
            Task { @MainActor in self?.lastStatusMessage = message }
        }
        self.runtime.onAccountUpdate = { [weak self] account in
            Task { @MainActor in self?.accountSnapshot = account }
        }
        self.runtime.onTokenUsageUpdate = { [weak self] usage in
            Task { @MainActor in self?.tokenUsage = usage }
        }
        self.runtime.onRateLimitsUpdate = { [weak self] limits in
            Task { @MainActor in self?.rateLimits = limits }
        }
        self.runtime.onSubagentUpdate = { [weak self] agents in
            Task { @MainActor in self?.subagents = agents }
        }
        self.runtime.onModelsUpdate = { [weak self] models in
            Task { @MainActor in
                guard let self else { return }
                self.availableModels = models
                self.applyPreferredModelSelection(using: models)
                self.restoreSessionConfiguration(from: self.selectedSession)
                self.isLoadingModels = false
            }
        }
        self.runtime.onProposedPlan = { [weak self] planText in
            Task { @MainActor in
                self?.proposedPlan = planText
                self?.proposedPlanSessionID = planText?.nonEmpty == nil
                    ? nil
                    : (self?.runtime.currentSessionID ?? self?.selectedSessionID)
            }
        }
        self.runtime.onTitleRequest = { [weak self] sessionID, userPrompt, assistantResponse in
            Task { @MainActor in
                self?.generateSessionTitle(
                    sessionID: sessionID,
                    userPrompt: userPrompt,
                    assistantResponse: assistantResponse
                )
            }
        }

        refreshModeSwitchSuggestion()
    }

    var composerText: String {
        get { promptDraft }
        set { promptDraft = newValue }
    }

    var environment: AssistantEnvironmentSnapshot {
        let state: AssistantEnvironmentState
        switch runtimeHealth.availability {
        case .installRequired:
            state = .missingCodex
        case .loginRequired:
            state = .needsLogin
        case .failed, .unavailable:
            state = .failed
        default:
            state = accountSnapshot.isLoggedIn ? .ready : (installGuidance.codexDetected ? .needsLogin : .missingCodex)
        }
        return AssistantEnvironmentSnapshot(
            state: state,
            installHelpText: runtimeHealth.detail ?? installGuidance.primaryDetail
        )
    }

    var selectedModelSummary: String {
        if let selectedModel {
            return selectedModel.displayName
        }
        if isLoadingModels {
            return "Loading models..."
        }
        if !visibleModels.isEmpty {
            return "Select model"
        }
        return "No models"
    }

    var visibleToolActivity: [AssistantToolCallState] {
        toolCalls + recentToolCalls
    }

    var hasToolActivity: Bool {
        !visibleToolActivity.isEmpty
    }

    var visibleModels: [AssistantModelOption] {
        availableModels.filter { !$0.hidden }
    }

    var selectedModel: AssistantModelOption? {
        guard let selectedModelID else { return nil }
        return visibleModels.first(where: { $0.id == selectedModelID })
    }

    var selectedModelSupportsImageInput: Bool {
        guard let selectedModel else { return true }
        guard selectedModel.hasKnownInputModalities else { return true }
        return selectedModel.supportsImageInput
    }

    static func unsupportedImageAttachmentMessage(
        for attachments: [AssistantAttachment],
        selectedModel: AssistantModelOption?
    ) -> String? {
        guard attachments.contains(where: \.isImage) else { return nil }
        guard let selectedModel else { return nil }
        guard selectedModel.hasKnownInputModalities else { return nil }
        guard !selectedModel.supportsImageInput else { return nil }

        return "The selected model \(selectedModel.displayName) cannot read image attachments. Choose a model that supports image input and try again. Chat mode can still analyze attached images when the model supports them, but live screen or browser inspection needs Agentic mode."
    }

    var isRuntimeReadyForConversation: Bool {
        switch runtimeHealth.availability {
        case .ready, .active:
            return true
        default:
            return false
        }
    }

    var canStartConversation: Bool {
        isRuntimeReadyForConversation && selectedModel != nil
    }

    var conversationBlockedReason: String? {
        if !isRuntimeReadyForConversation {
            switch runtimeHealth.availability {
            case .idle, .checking:
                return "Waiting for Codex to start."
            case .connecting:
                return "Connecting to Codex."
            case .installRequired:
                return "Install Codex to start the assistant."
            case .loginRequired:
                return "Sign in to Codex before starting a conversation."
            case .unavailable:
                return "Codex is not available right now."
            case .failed:
                return runtimeHealth.detail ?? "Codex needs attention. Check Setup."
            case .ready, .active:
                break // shouldn't happen, but fall through
            }
        }
        if isLoadingModels {
            return "Loading models from Codex before chat starts."
        }
        if visibleModels.isEmpty {
            return "No assistant models are available yet. Refresh or open Setup to check Codex."
        }
        if selectedModel == nil {
            return "Choose a model before starting a conversation. Then confirm the reasoning level."
        }
        if attachments.contains(where: \.isImage), !selectedModelSupportsImageInput {
            let modelName = selectedModel?.displayName ?? "The selected model"
            return "\(modelName) cannot read image attachments. Choose a model with image support, then try again."
        }
        return nil
    }

    var activeRuntimeSessionID: String? {
        runtime.currentSessionID
    }

    var hasActiveTurn: Bool {
        runtime.hasActiveTurn
    }

    private var currentBrowserAutomationSignature: String? {
        Self.browserAutomationSignature(
            browserAutomationEnabled: settings.browserAutomationEnabled,
            selectedProfileID: settings.browserSelectedProfileID
        )
    }

    enum BrowserAutomationRequirement: Equatable {
        case none
        case enableAutomation
        case selectProfile
    }

    enum ImageInputRequirement: Equatable {
        case none
        case unsupportedSelectedModel
    }

    static func shouldBlockSessionSwitch(
        activeSessionID: String?,
        hasActiveTurn: Bool,
        requestedSessionID: String
    ) -> Bool {
        guard hasActiveTurn,
              let activeSessionID = activeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return false
        }

        return activeSessionID.caseInsensitiveCompare(requestedSessionID) != .orderedSame
    }

    static func looksLikeBrowserAutomationRequest(_ prompt: String) -> Bool {
        let normalized = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        if normalized.contains("http://")
            || normalized.contains("https://")
            || normalized.contains("www.") {
            return true
        }

        let searchable = " " + normalized
            .replacingOccurrences(of: #"[^a-z0-9.]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) + " "
        func containsPhrase(_ phrase: String) -> Bool {
            let normalizedPhrase = phrase
                .lowercased()
                .replacingOccurrences(of: #"[^a-z0-9.]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedPhrase.isEmpty else { return false }
            return searchable.contains(" \(normalizedPhrase) ")
        }

        let browserSignals = [
            "browser",
            "brave",
            "chrome",
            "edge",
            "microsoft edge",
            "safari",
            "current tab",
            "front tab",
            "tab ",
            "website",
            "web site",
            "webpage",
            "url",
            "dashboard",
            "x.com",
            "twitter",
            "linkedin",
            "gmail",
            "github.com",
            "notion"
        ]
        let browserActions = [
            "open",
            "visit",
            "go to",
            "navigate",
            "check",
            "read",
            "summarize",
            "inspect",
            "extract",
            "search",
            "browse",
            "click",
            "scroll",
            "fill",
            "submit",
            "download",
            "upload",
            "log in",
            "login",
            "sign in",
            "post",
            "reply",
            "send"
        ]

        let hasSignal = browserSignals.contains(where: containsPhrase)
        let hasAction = browserActions.contains(where: containsPhrase)
        return hasSignal && hasAction
    }

    static func browserAutomationRequirement(
        for prompt: String,
        browserAutomationEnabled: Bool,
        hasSelectedBrowserProfile: Bool
    ) -> BrowserAutomationRequirement {
        guard looksLikeBrowserAutomationRequest(prompt) else { return .none }
        guard browserAutomationEnabled else { return .enableAutomation }
        return hasSelectedBrowserProfile ? .none : .selectProfile
    }

    static func browserAutomationSignature(
        browserAutomationEnabled: Bool,
        selectedProfileID: String?
    ) -> String? {
        guard browserAutomationEnabled,
              let selectedProfileID = selectedProfileID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        return selectedProfileID
    }

    static func shouldInjectBrowserContextOverride(
        for prompt: String,
        currentBrowserSignature: String?,
        primedBrowserSignature: String?
    ) -> Bool {
        guard looksLikeBrowserAutomationRequest(prompt),
              let currentBrowserSignature else {
            return false
        }
        return primedBrowserSignature != currentBrowserSignature
    }

    static func looksLikeImageReferenceRequest(_ prompt: String) -> Bool {
        let normalized = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let searchable = " " + normalized
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) + " "

        func containsPhrase(_ phrase: String) -> Bool {
            let normalizedPhrase = phrase
                .lowercased()
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedPhrase.isEmpty else { return false }
            return searchable.contains(" \(normalizedPhrase) ")
        }

        let directImageSignals = [
            "image",
            "images",
            "screenshot",
            "screen shot",
            "photo",
            "picture",
            "diagram",
            "graph",
            "chart"
        ]
        if directImageSignals.contains(where: containsPhrase) {
            return true
        }

        let deicticImageQuestions = [
            "what s going on here",
            "what is going on here",
            "what happened here",
            "what does this show",
            "what is in this",
            "what did it do",
            "describe this",
            "explain this",
            "read this"
        ]
        return deicticImageQuestions.contains(where: containsPhrase)
    }

    static func imageInputRequirement(
        for prompt: String,
        attachments: [AssistantAttachment],
        selectedModelSupportsImageInput: Bool,
        hasRecentImageContext: Bool
    ) -> ImageInputRequirement {
        guard !selectedModelSupportsImageInput else { return .none }
        if attachments.contains(where: \.isImage) {
            return .unsupportedSelectedModel
        }
        if hasRecentImageContext, looksLikeImageReferenceRequest(prompt) {
            return .unsupportedSelectedModel
        }
        return .none
    }

    var isOpenAIConnectedInAIStudio: Bool {
        settings.hasPromptRewriteOAuthSession(for: .openAI)
    }

    var aiStudioPreferredAssistantModelID: String? {
        settings.promptRewriteOpenAIModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    var ownedSessionCount: Int {
        settings.assistantOwnedThreadIDs.count
    }

    func refreshEnvironment(permissions: AssistantPermissionSnapshot = .unknown) async {
        guard !isRefreshingEnvironment else {
            self.permissions = permissions
            return
        }

        isRefreshingEnvironment = true
        defer { isRefreshingEnvironment = false }

        let guidance = await installSupport.inspect()
        installGuidance = guidance
        self.permissions = permissions

        guard guidance.codexDetected else {
            accountSnapshot = .signedOut
            availableModels = []
            selectedModelID = nil
            isLoadingModels = false
            runtime.setPreferredModelID(nil)
            runtimeHealth = AssistantRuntimeHealth(
                availability: .installRequired,
                summary: "Install Codex to start the assistant",
                detail: guidance.primaryDetail,
                runtimePath: guidance.codexPath,
                selectedModelID: nil,
                accountEmail: nil,
                accountPlan: nil
            )
            return
        }

        isLoadingModels = true
        do {
            let details = try await runtime.refreshEnvironment(codexPath: guidance.codexPath)
            accountSnapshot = details.account
            availableModels = details.models
            applyPreferredModelSelection(using: details.models)
            runtimeHealth = details.health
            if details.account.isLoggedIn && details.models.isEmpty {
                runtimeHealth.detail = "Loading models from Codex before chat starts."
            }
            if !details.models.isEmpty {
                isLoadingModels = false
            }
        } catch {
            isLoadingModels = false
            runtimeHealth = AssistantRuntimeHealth(
                availability: accountSnapshot.isLoggedIn ? .failed : .loginRequired,
                summary: accountSnapshot.isLoggedIn ? "Codex needs attention" : "Sign in to Codex",
                detail: error.localizedDescription,
                runtimePath: guidance.codexPath,
                selectedModelID: selectedModelID,
                accountEmail: accountSnapshot.email,
                accountPlan: accountSnapshot.planType
            )
            lastStatusMessage = error.localizedDescription
        }
    }

    func refreshSessions(limit: Int = 40) async {
        guard !isRefreshingSessions else { return }

        isRefreshingSessions = true
        defer { isRefreshingSessions = false }

        let ownedSessionIDs = resolvedOwnedSessionIDs()

        do {
            // Run both session queries in parallel
            let capturedSelectedSessionID = selectedSessionID
            async let byIDTask: [AssistantSessionSummary] = ownedSessionIDs.isEmpty
                ? []
                : sessionCatalog.loadSessions(
                    limit: max(limit, ownedSessionIDs.count),
                    preferredThreadID: capturedSelectedSessionID,
                    preferredCWD: nil,
                    sessionIDs: ownedSessionIDs
                )
            async let byOriginatorTask: [AssistantSessionSummary] = sessionCatalog.loadSessions(
                limit: limit,
                preferredThreadID: capturedSelectedSessionID,
                preferredCWD: nil,
                originatorFilter: "Open Assist"
            )
            let (byID, byOriginator) = try await (byIDTask, byOriginatorTask)
            var merged: [AssistantSessionSummary] = byID
            let existingIDs = Set(byID.map { $0.id.lowercased() })
            for session in byOriginator where !existingIDs.contains(session.id.lowercased()) {
                merged.append(session)
                recordOwnedSessionID(session.id)
            }

            if let currentSelectedSessionID = selectedSessionID?.nonEmpty,
               !merged.contains(where: { sessionsMatch($0.id, currentSelectedSessionID) }) {
                let selectedSessionOnly = try await sessionCatalog.loadSessions(
                    limit: 1,
                    preferredThreadID: currentSelectedSessionID,
                    preferredCWD: nil,
                    sessionIDs: [currentSelectedSessionID]
                )
                if let selectedSessionOnly = selectedSessionOnly.first {
                    merged.removeAll { sessionsMatch($0.id, selectedSessionOnly.id) }
                    merged.insert(selectedSessionOnly, at: 0)
                }
            }

            sessions = Array(merged.prefix(limit))
            ensureSessionVisible(selectedSessionID)

            if let selectedSessionID,
               !sessions.contains(where: { sessionsMatch($0.id, selectedSessionID) }) {
                self.selectedSessionID = nil
                transcriptSessionID = nil
                timelineSessionID = nil
                timelineItems = []
                clearActiveProposedPlanIfNeeded(for: nil)
            }

            if selectedSessionID == nil {
                selectedSessionID = preferredSessionID()
            }

            restoreSessionConfiguration(from: selectedSession)
            await reloadSelectedSessionHistoryIfNeeded(force: transcript.isEmpty || timelineItems.isEmpty)
            refreshMemoryState(for: selectedSessionID)
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func refreshAll() {
        Task { @MainActor in
            await refreshEnvironment()
            await refreshSessions()
            refreshMemoryState(for: selectedSessionID)
        }
    }

    func chooseModel(_ modelID: String) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              visibleModels.contains(where: { $0.id == trimmed }) else { return }
        settings.assistantPreferredModelID = trimmed
        selectedModelID = trimmed
        syncReasoningEffortWithSelectedModel(preferModelDefault: true)
        runtime.setPreferredModelID(trimmed)
        runtimeHealth.selectedModelID = trimmed
        syncRuntimeContext()
    }

    func startAccountLogin() {
        Task { @MainActor in
            if accountSnapshot.isLoggedIn {
                self.lastStatusMessage = "Codex is already signed in."
                self.runtimeHealth = AssistantRuntimeHealth(
                    availability: .ready,
                    summary: "Codex is connected",
                    detail: nil,
                    runtimePath: runtimeHealth.runtimePath,
                    selectedModelID: selectedModelID,
                    accountEmail: accountSnapshot.email,
                    accountPlan: accountSnapshot.planType
                )
                return
            }

            do {
                if let loginURL = try await runtime.startChatGPTLogin() {
                    NSWorkspace.shared.open(loginURL)
                } else {
                    await refreshEnvironment(permissions: permissions)
                }
            } catch {
                self.lastStatusMessage = error.localizedDescription
            }
        }
    }

    func startNewSession(cwd: String? = nil) async {
        guard await ensureConversationCanStart() else { return }
        let interruptedActiveTurn = runtime.hasActiveTurn
        if interruptedActiveTurn {
            lastStatusMessage = "Stopping the current task and starting a new session..."
            await runtime.cancelActiveTurn()
        }
        setVisibleTimeline([], for: nil)
        transcript = []
        transcriptSessionID = nil
        planEntries = []
        toolCalls = []
        recentToolCalls = []
        pendingPermissionRequest = nil
        lastSubmittedPrompt = nil
        sessionInstructions = ""
        oneShotSessionInstructions = nil
        proposedPlan = nil
        proposedPlanSessionID = nil
        tokenUsage = .empty
        subagents = []
        syncRuntimeContext()
        do {
            let sessionID = try await runtime.startNewSession(cwd: cwd, preferredModelID: selectedModelID)
            recordOwnedSessionID(sessionID)
            selectedSessionID = sessionID
            ensureSessionVisible(sessionID)
            if settings.assistantMemoryEnabled {
                _ = try? threadMemoryService.ensureMemoryFile(for: sessionID)
            }
            refreshMemoryState(for: sessionID)
            await refreshSessions()
            ensureSessionVisible(sessionID)
            if interruptedActiveTurn {
                lastStatusMessage = "Stopped the current task and started a new session."
            }
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func openSession(_ session: AssistantSessionSummary) async {
        let normalizedSessionID = session.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }

        clearActiveProposedPlanIfNeeded(for: normalizedSessionID)

        if sessionsMatch(selectedSessionID, normalizedSessionID),
           sessionsMatch(transcriptSessionID, normalizedSessionID),
           sessionsMatch(timelineSessionID, normalizedSessionID),
           !isTransitioningSession {
            restoreSessionConfiguration(from: session)
            refreshMemoryState(for: normalizedSessionID)
            return
        }

        let requestID = UUID()
        sessionLoadRequestID = requestID
        selectedSessionID = normalizedSessionID
        restoreSessionConfiguration(from: session)

        let cachedTimeline = timelineItemsBySessionID[normalizedSessionID] ?? []
        let cachedTranscript = transcriptEntriesBySessionID[normalizedSessionID] ?? []
        let hasCachedHistory = timelineItemsBySessionID.keys.contains(normalizedSessionID)
            || transcriptEntriesBySessionID.keys.contains(normalizedSessionID)

        if hasCachedHistory {
            setVisibleTimeline(cachedTimeline, for: normalizedSessionID)
            setVisibleTranscript(cachedTranscript, for: normalizedSessionID)
            isTransitioningSession = false
        } else {
            isTransitioningSession = true
        }

        async let timelineTask = sessionCatalog.loadMergedTimeline(sessionID: normalizedSessionID)
        async let transcriptTask = sessionCatalog.loadTranscript(sessionID: normalizedSessionID)
        let (loadedTimeline, loadedTranscript) = await (timelineTask, transcriptTask)

        guard sessionLoadRequestID == requestID,
              sessionsMatch(selectedSessionID, normalizedSessionID) else {
            return
        }

        let mergedTimeline = mergeTimelineHistory(
            loadedTimeline,
            with: timelineItemsBySessionID[normalizedSessionID] ?? []
        )
        let mergedTranscript = mergeTranscriptHistory(
            loadedTranscript,
            with: transcriptEntriesBySessionID[normalizedSessionID] ?? []
        )

        setVisibleTimeline(mergedTimeline, for: normalizedSessionID)
        setVisibleTranscript(mergedTranscript, for: normalizedSessionID)
        refreshMemoryState(for: normalizedSessionID)
        isTransitioningSession = false
    }

    func sendPrompt(_ prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard await ensureConversationCanStart() else {
            if oneShotSessionInstructions != nil {
                oneShotSessionInstructions = nil
                syncRuntimeContext()
            }
            return
        }

        lastSubmittedPrompt = trimmed
        let pendingAttachments = attachments
        lastSubmittedAttachments = pendingAttachments
        blockedModeSwitchSuggestion = nil
        refreshModeSwitchSuggestion()
        if let imageCapabilityMessage = Self.unsupportedImageAttachmentMessage(
            for: pendingAttachments,
            selectedModel: selectedModel
        ) {
            lastStatusMessage = imageCapabilityMessage
            appendTranscriptEntry(
                AssistantTranscriptEntry(
                    role: .error,
                    text: imageCapabilityMessage,
                    emphasis: true
                )
            )
            if let selectedSessionID {
                appendTimelineItem(
                    .system(
                        sessionID: selectedSessionID,
                        text: imageCapabilityMessage,
                        createdAt: Date(),
                        emphasis: true,
                        source: .runtime
                    )
                )
            }
            return
        }
        attachments = []
        promptDraft = ""
        isSendingPrompt = true
        defer {
            isSendingPrompt = false
            if oneShotSessionInstructions != nil {
                oneShotSessionInstructions = nil
                syncRuntimeContext()
            }
        }
        syncRuntimeContext()
        do {
            let sessionID = try await prepareSessionForPrompt()
            let resumeContext = resumeContextIfNeeded(for: sessionID)
            let memoryContext: String?
            if settings.assistantMemoryEnabled {
                let builtMemory = try memoryRetrievalService.prepareTurnContext(
                    threadID: sessionID,
                    prompt: trimmed,
                    cwd: resolvedSessionCWD(for: sessionID),
                    summaryMaxChars: settings.assistantMemorySummaryMaxChars
                )
                currentMemoryFileURL = builtMemory.fileURL
                updateMemoryStatus(base: builtMemory.statusMessage)
                memoryContext = builtMemory.summary
            } else {
                memoryContext = nil
                refreshMemoryState(for: sessionID)
            }

            recordOwnedSessionID(sessionID)
            selectedSessionID = sessionID
            transcriptSessionID = sessionID
            timelineSessionID = sessionID
            ensureSessionVisible(sessionID)
            toolCalls = []
            recentToolCalls = []
            appendTranscriptEntry(AssistantTranscriptEntry(role: .user, text: trimmed))
            let imageData = pendingAttachments.filter(\.isImage).map(\.data)
            appendTimelineItem(
                .userMessage(
                    sessionID: sessionID,
                    turnID: nil,
                    text: trimmed,
                    createdAt: Date(),
                    imageAttachments: imageData.isEmpty ? nil : imageData,
                    source: .runtime
                )
            )
            try await runtime.sendPrompt(
                trimmed,
                attachments: pendingAttachments,
                preferredModelID: selectedModelID,
                modelSupportsImageInput: selectedModelSupportsImageInput,
                resumeContext: resumeContext,
                memoryContext: memoryContext
            )
            pendingResumeContextSessionIDs.remove(sessionID)
            ensureSessionVisible(sessionID)
        } catch {
            lastStatusMessage = error.localizedDescription
            promptDraft = trimmed
            appendTranscriptEntry(AssistantTranscriptEntry(role: .error, text: error.localizedDescription, emphasis: true))
            appendTimelineItem(
                .system(
                    sessionID: selectedSessionID,
                    text: error.localizedDescription,
                    createdAt: Date(),
                    emphasis: true,
                    source: .runtime
                )
            )
        }
    }

    /// Switch to Agentic mode and continue execution in the exact session that created the plan.
    /// We send the agentic collaboration mode on the next turn, so the same session keeps
    /// its chat history, timeline, and memory context during the handoff.
    func executePlan() async {
        guard let plan = proposedPlan, !plan.isEmpty else { return }
        guard await ensureConversationCanStart() else { return }
        guard let executionSessionID = Self.planExecutionSessionID(planSessionID: proposedPlanSessionID) else {
            lastStatusMessage = "This plan must run in the same session that created it. Please reopen that session and try again."
            return
        }
        if runtime.hasActiveTurn {
            lastStatusMessage = "Wait for the planning turn to finish, then run the plan."
            return
        }

        if let matchingSession = sessions.first(where: { sessionsMatch($0.id, executionSessionID) }) {
            await openSession(matchingSession)
        } else if sessionsMatch(runtime.currentSessionID, executionSessionID) {
            selectedSessionID = executionSessionID
        } else {
            lastStatusMessage = "Could not reopen the session that created this plan. Please reopen that session and try again."
            return
        }

        interactionMode = .agentic
        proposedPlan = nil
        proposedPlanSessionID = nil
        planEntries = []
        pendingPermissionRequest = nil
        // Inject the plan as a one-shot hidden instruction so it applies only to the
        // execution turn and cannot leak into later chats.
        oneShotSessionInstructions = "# Plan to Execute\n\n\(plan)"
        await sendPrompt("Execute the plan.")
    }

    /// Dismiss the proposed plan without executing it.
    func dismissPlan() {
        proposedPlan = nil
        proposedPlanSessionID = nil
    }

    func applyModeSwitchSuggestion(_ choice: AssistantModeSwitchChoice) async {
        interactionMode = choice.mode
        syncRuntimeContext()

        let switchedText = "Switched to \(choice.mode.label) mode."
        blockedModeSwitchSuggestion = nil
        refreshModeSwitchSuggestion()

        guard choice.resendLastRequest else {
            lastStatusMessage = switchedText
            return
        }

        let retryPrompt = lastSubmittedPrompt ?? ""
        let retryAttachments = lastSubmittedAttachments
        guard retryPrompt.nonEmpty != nil || !retryAttachments.isEmpty else {
            lastStatusMessage = switchedText
            return
        }

        attachments = retryAttachments
        promptDraft = retryPrompt
        lastStatusMessage = "Switched to \(choice.mode.label) mode and restored your last request."
        await sendPrompt(retryPrompt)
    }

    func dismissModeSwitchSuggestion() {
        blockedModeSwitchSuggestion = nil
        refreshModeSwitchSuggestion()
    }

    func cancelActiveTurn() async {
        await runtime.cancelActiveTurn()
    }

    func deleteSession(_ sessionID: String) async {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }

        do {
            if runtime.currentSessionID == normalizedSessionID {
                await runtime.stop()
            }

            let deleted = try await sessionCatalog.deleteSession(sessionID: normalizedSessionID)
            try? threadMemoryService.clearMemory(for: normalizedSessionID)
            try? memorySuggestionService.clearSuggestions(for: normalizedSessionID)

            removeOwnedSessionID(normalizedSessionID)
            if deleted {
                lastStatusMessage = "Deleted the Open Assist session."
            } else {
                lastStatusMessage = "That Open Assist session was already gone."
            }

            if selectedSessionID == normalizedSessionID {
                sessionLoadRequestID = UUID()
                selectedSessionID = nil
                transcriptSessionID = nil
                timelineSessionID = nil
                timelineItems = []
                transcript = []
                planEntries = []
                toolCalls = []
                recentToolCalls = []
                pendingPermissionRequest = nil
            }

            transcriptEntriesBySessionID.removeValue(forKey: normalizedSessionID)
            timelineItemsBySessionID.removeValue(forKey: normalizedSessionID)
            sessions.removeAll { $0.id == normalizedSessionID }
            refreshMemoryState(for: selectedSessionID)
            await refreshSessions()
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func renameSession(_ sessionID: String, to title: String) async {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            lastStatusMessage = "Enter a session name before renaming."
            return
        }

        if let existingSession = sessions.first(where: { sessionsMatch($0.id, normalizedSessionID) }),
           existingSession.title.caseInsensitiveCompare(normalizedTitle) == .orderedSame {
            lastStatusMessage = "That session already has this name."
            return
        }

        do {
            try sessionCatalog.renameSession(sessionID: normalizedSessionID, title: normalizedTitle)
            if let sessionIndex = sessions.firstIndex(where: { sessionsMatch($0.id, normalizedSessionID) }) {
                sessions[sessionIndex].title = normalizedTitle
            }
            lastStatusMessage = "Renamed the session."
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func deleteAllOwnedSessions() async {
        let ownedSessionIDs = settings.assistantOwnedThreadIDs
        guard !ownedSessionIDs.isEmpty else {
            lastStatusMessage = "There are no Open Assist sessions to delete."
            return
        }

        do {
            if let currentSessionID = runtime.currentSessionID,
               ownedSessionIDs.contains(where: { $0.caseInsensitiveCompare(currentSessionID) == .orderedSame }) {
                await runtime.stop()
            }

            let deletedCount = try await sessionCatalog.deleteSessions(sessionIDs: ownedSessionIDs)
            for sessionID in ownedSessionIDs {
                try? threadMemoryService.clearMemory(for: sessionID)
                try? memorySuggestionService.clearSuggestions(for: sessionID)

            }
            settings.assistantOwnedThreadIDs = []
            sessionLoadRequestID = UUID()
            selectedSessionID = nil
            transcriptSessionID = nil
            timelineSessionID = nil
            timelineItems = []
            transcript = []
            planEntries = []
            toolCalls = []
            recentToolCalls = []
            pendingPermissionRequest = nil
            sessions = []
            transcriptEntriesBySessionID = [:]
            timelineItemsBySessionID = [:]
            refreshMemoryState(for: nil)
            lastStatusMessage = deletedCount == 1
                ? "Deleted 1 Open Assist session."
                : "Deleted \(deletedCount) Open Assist sessions."
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func stopRuntime() async {
        await runtime.stop()
        transcriptSessionID = nil
        timelineSessionID = nil
        refreshMemoryState(for: selectedSessionID)
    }

    func resolvePermission(optionID: String) async {
        await runtime.respondToPermissionRequest(optionID: optionID)
        pendingPermissionRequest = nil
    }

    func resolvePermission(answers: [String: [String]]) async {
        await runtime.respondToPermissionRequest(answers: answers)
        pendingPermissionRequest = nil
    }

    func cancelPermissionRequest() async {
        await runtime.cancelPendingPermissionRequest()
        pendingPermissionRequest = nil
    }

    func alwaysAllowToolKind(_ toolKind: String) {
        guard !toolKind.isEmpty else { return }
        settings.assistantAlwaysApprovedToolKinds.insert(toolKind)
    }

    func openCurrentMemoryFile() {
        guard settings.assistantMemoryEnabled else {
            lastStatusMessage = "Assistant memory is turned off."
            return
        }
        guard let sessionID = selectedSessionID ?? runtime.currentSessionID else {
            lastStatusMessage = "Start or open an Open Assist assistant session first."
            return
        }
        do {
            let fileURL = try threadMemoryService.ensureMemoryFile(for: sessionID)
            currentMemoryFileURL = fileURL
            NSWorkspace.shared.open(fileURL)
            updateMemoryStatus(base: "Opened the current memory file")
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func resetCurrentTaskMemory() {
        guard settings.assistantMemoryEnabled else {
            lastStatusMessage = "Assistant memory is turned off."
            return
        }
        guard let sessionID = selectedSessionID ?? runtime.currentSessionID else {
            lastStatusMessage = "Start or open an Open Assist assistant session first."
            return
        }
        do {
            let currentTask = latestUserMessage(for: sessionID) ?? promptDraft
            let change = try threadMemoryService.softReset(
                for: sessionID,
                reason: "Manual reset from Open Assist",
                nextTask: currentTask
            )
            currentMemoryFileURL = change.fileURL
            updateMemoryStatus(base: "Memory reset for new task")
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func clearCurrentThreadMemory() {
        guard let sessionID = selectedSessionID ?? runtime.currentSessionID else {
            lastStatusMessage = "Start or open an Open Assist assistant session first."
            return
        }
        do {
            try threadMemoryService.clearMemory(for: sessionID)
            try memorySuggestionService.clearSuggestions(for: sessionID)
            pendingMemorySuggestions = try memorySuggestionService.suggestions(for: sessionID)
            currentMemoryFileURL = nil
            updateMemoryStatus(base: "Cleared this thread's assistant memory")
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func openMemorySuggestionReview() {
        showMemorySuggestionReview = true
    }

    func saveAssistantMessageAsMemory(_ assistantText: String) {
        guard settings.assistantMemoryEnabled else {
            lastStatusMessage = "Assistant memory is turned off."
            return
        }
        guard let sessionID = selectedSessionID ?? runtime.currentSessionID else {
            lastStatusMessage = "Open an Open Assist assistant session first."
            return
        }

        do {
            let scope = memoryRetrievalService.makeScopeContext(
                threadID: sessionID,
                cwd: resolvedSessionCWD(for: sessionID)
            )
            let created = try memorySuggestionService.createManualSuggestions(
                from: assistantText,
                threadID: sessionID,
                scope: scope
            )
            try handleCreatedSuggestions(created, sessionID: sessionID, directSaveWhenReviewDisabled: true)
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func markAssistantMessageUnhelpful(_ assistantText: String) {
        guard settings.assistantMemoryEnabled else {
            lastStatusMessage = "Assistant memory is turned off."
            return
        }
        guard let sessionID = selectedSessionID ?? runtime.currentSessionID else {
            lastStatusMessage = "Open an Open Assist assistant session first."
            return
        }

        do {
            let scope = memoryRetrievalService.makeScopeContext(
                threadID: sessionID,
                cwd: resolvedSessionCWD(for: sessionID)
            )
            let created = try memorySuggestionService.createFailureSuggestions(
                from: assistantText,
                threadID: sessionID,
                scope: scope
            )
            try handleCreatedSuggestions(created, sessionID: sessionID, directSaveWhenReviewDisabled: false)
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func acceptMemorySuggestion(_ suggestion: AssistantMemorySuggestion) {
        do {
            try memorySuggestionService.acceptSuggestion(id: suggestion.id)
            refreshMemoryState(for: suggestion.threadID)
            updateMemoryStatus(base: "Saved lesson to long-term assistant memory")
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func ignoreMemorySuggestion(_ suggestion: AssistantMemorySuggestion) {
        do {
            try memorySuggestionService.ignoreSuggestion(id: suggestion.id)
            refreshMemoryState(for: suggestion.threadID)
            updateMemoryStatus(base: "Ignored that memory suggestion")
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func prepareForVoiceCapture() {
        voiceCaptureLevel = 0
        hudState = AssistantHUDState(
            phase: .listening,
            title: "Listening",
            detail: "Speak your assistant task"
        )
        lastStatusMessage = "Listening for your assistant request."
    }

    func receiveVoiceDraft(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        voiceCaptureLevel = 0

        guard !trimmed.isEmpty else {
            hudState = .idle
            return
        }

        if AssistantComposerBridge.shared.insert(trimmed) {
            hudState = .idle
            lastStatusMessage = "Voice draft pasted into the composer."
            return
        }

        promptDraft = trimmed
        hudState = AssistantHUDState(
            phase: .success,
            title: "Voice task ready",
            detail: "Review the draft in the assistant window"
        )
        if !trimmed.isEmpty {
            transcript.append(
                AssistantTranscriptEntry(
                    role: .status,
                    text: "Voice draft captured. Review it, then press Send."
                )
            )
        }
    }

    func failVoiceDraft(_ message: String) {
        voiceCaptureLevel = 0
        hudState = AssistantHUDState(
            phase: .failed,
            title: "Voice task failed",
            detail: message
        )
        lastStatusMessage = message
        transcript.append(AssistantTranscriptEntry(role: .error, text: message, emphasis: true))
    }

    func finalizingVoiceCapture() {
        voiceCaptureLevel = 0
        hudState = AssistantHUDState(
            phase: .thinking,
            title: "Processing",
            detail: "Preparing your assistant draft"
        )
    }

    func cancelVoiceDraft(_ message: String = "Assistant listening stopped.") {
        voiceCaptureLevel = 0
        hudState = .idle
        lastStatusMessage = message
        transcript.append(AssistantTranscriptEntry(role: .status, text: message))
    }

    func updateVoiceCaptureLevel(_ level: Float) {
        voiceCaptureLevel = max(0, min(1, level))
    }

    func runPreferredInstallCommand() {
        guard let command = installGuidance.installCommands.first else { return }
        runInTerminal(command)
    }

    func runLoginCommand() {
        startAccountLogin()
    }

    func openInstallDocs() {
        guard let docsURL = installGuidance.docsURL else { return }
        NSWorkspace.shared.open(docsURL)
    }

    // MARK: - Browser Automation

    var selectedBrowserProfile: BrowserProfile? {
        let profileID = settings.browserSelectedProfileID
        guard !profileID.isEmpty else { return nil }
        return BrowserProfileManager.shared.profile(withID: profileID)
    }

    var isBrowserAutomationConfigured: Bool {
        settings.browserAutomationEnabled && selectedBrowserProfile != nil
    }

    func selectBrowserProfile(_ profile: BrowserProfile) {
        settings.browserSelectedProfileID = profile.id
        showBrowserProfilePicker = false
        appendTranscriptEntry(
            AssistantTranscriptEntry(
                role: .system,
                text: "Browser profile set to \(profile.browser.displayName) - \(profile.label)."
            )
        )
    }

    func requestBrowserProfileSelection() {
        showBrowserProfilePicker = true
    }

    func syncRuntimeContext() {
        // Combine global + per-session instructions
        let global = settings.assistantCustomInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = sessionInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneShot = oneShotSessionInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        runtime.customInstructions = Self.combinedRuntimeInstructions(
            global: global,
            session: session,
            oneShot: oneShot
        )
        runtime.reasoningEffort = reasoningEffort.wireValue
        runtime.serviceTier = fastModeEnabled ? "fast" : nil
        runtime.interactionMode = interactionMode
        runtime.maxToolCallsPerTurn = settings.assistantMaxToolCallsPerTurn
        runtime.maxRepeatedCommandAttemptsPerTurn = settings.assistantMaxRepeatedCommandAttemptsPerTurn
        if !isRestoringSessionConfiguration {
            updateVisibleSessionConfiguration()
        }
    }

    private func refreshCurrentSessionConfigurationForModeChange() async {
        guard !runtime.hasActiveTurn,
              let sessionID = runtime.currentSessionID?.nonEmpty else {
            return
        }

        try? await runtime.refreshCurrentSessionConfiguration(
            cwd: resolvedSessionCWD(for: sessionID),
            preferredModelID: selectedModelID
        )
    }

    private func applyPreferredModelSelection(using models: [AssistantModelOption]) {
        let visibleModels = models.filter { !$0.hidden }
        guard !visibleModels.isEmpty else {
            selectedModelID = nil
            runtime.setPreferredModelID(nil)
            runtimeHealth.selectedModelID = nil
            return
        }

        let storedModelID = settings.assistantPreferredModelID.nonEmpty
        let resolvedModelID: String?
        if let storedModelID,
           visibleModels.contains(where: { $0.id == storedModelID }) {
            resolvedModelID = storedModelID
        } else {
            resolvedModelID = nil
        }

        if let resolvedModelID {
            if settings.assistantPreferredModelID != resolvedModelID {
                settings.assistantPreferredModelID = resolvedModelID
            }
        } else if !settings.assistantPreferredModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.assistantPreferredModelID = ""
        }
        selectedModelID = resolvedModelID
        runtime.setPreferredModelID(resolvedModelID)
        runtimeHealth.selectedModelID = resolvedModelID
        syncReasoningEffortWithSelectedModel(preferModelDefault: false)
    }

    private func syncReasoningEffortWithSelectedModel(preferModelDefault: Bool) {
        guard let selectedModel else { return }

        let supportedEfforts = selectedModel.supportedReasoningEfforts.compactMap(AssistantReasoningEffort.init(rawValue:))
        let defaultEffort = selectedModel.defaultReasoningEffort.flatMap(AssistantReasoningEffort.init(rawValue:))

        if preferModelDefault,
           let defaultEffort,
           (supportedEfforts.isEmpty || supportedEfforts.contains(defaultEffort)) {
            reasoningEffort = defaultEffort
            return
        }

        guard !supportedEfforts.isEmpty,
              !supportedEfforts.contains(reasoningEffort) else { return }

        if let defaultEffort,
           supportedEfforts.contains(defaultEffort) {
            reasoningEffort = defaultEffort
        } else if let firstSupportedEffort = supportedEfforts.first {
            reasoningEffort = firstSupportedEffort
        }
    }

    @discardableResult
    private func ensureConversationCanStart() async -> Bool {
        if canStartConversation { return true }

        // If the runtime dropped (idle/failed/connecting), attempt a transparent
        // reconnection before giving up — the user shouldn't have to manually
        // refresh just because Codex restarted between turns.
        if !isRuntimeReadyForConversation, !isRefreshingEnvironment {
            CrashReporter.logInfo("Assistant auto-recovering runtime availability=\(runtimeHealth.availability.rawValue)")
            await refreshEnvironment()
        }

        guard canStartConversation else {
            lastStatusMessage = conversationBlockedReason ?? "Choose a model before starting a conversation."
            return false
        }
        return true
    }

    private func runInTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            lastStatusMessage = "Could not open Terminal automatically. Run this command yourself: \(command)"
        }
    }

    private func ensureSessionVisible(_ sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty else { return }
        if let existingIndex = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[existingIndex].updatedAt = Date()
            sessions[existingIndex].latestModel = selectedModelID
            sessions[existingIndex].latestInteractionMode = interactionMode
            sessions[existingIndex].latestReasoningEffort = reasoningEffort
            sessions[existingIndex].latestServiceTier = fastModeEnabled ? "fast" : nil
            if let lastSubmittedPrompt {
                sessions[existingIndex].latestUserMessage = lastSubmittedPrompt
                if sessions[existingIndex].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || sessions[existingIndex].title == sessions[existingIndex].cwd {
                    sessions[existingIndex].title = Self.sessionTitle(from: lastSubmittedPrompt)
                }
            }
            return
        }

        let title = lastSubmittedPrompt.map(Self.sessionTitle(from:)) ?? "New Assistant Session"
        let summary = AssistantSessionSummary(
            id: sessionID,
            title: title,
            source: .appServer,
            status: .active,
            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            createdAt: Date(),
            updatedAt: Date(),
            summary: lastSubmittedPrompt,
            latestModel: selectedModelID,
            latestInteractionMode: interactionMode,
            latestReasoningEffort: reasoningEffort,
            latestServiceTier: fastModeEnabled ? "fast" : nil,
            latestUserMessage: lastSubmittedPrompt,
            latestAssistantMessage: nil
        )

        sessions.insert(summary, at: 0)
    }

    /// Generate a concise session title from the user's prompt.
    static func sessionTitle(from prompt: String) -> String {
        let cleaned = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        // Try to extract the first sentence
        let sentenceEnders: [Character] = [".", "?", "!"]
        if let endIndex = cleaned.firstIndex(where: { sentenceEnders.contains($0) }) {
            let sentence = String(cleaned[cleaned.startIndex...endIndex])
            if sentence.count >= 8 && sentence.count <= 80 {
                return sentence
            }
        }

        // Truncate to ~60 chars at a word boundary
        if cleaned.count <= 60 { return cleaned }
        let prefix = String(cleaned.prefix(60))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[prefix.startIndex..<lastSpace]) + "…"
        }
        return prefix + "…"
    }

    private func generateSessionTitle(
        sessionID: String,
        userPrompt: String,
        assistantResponse: String
    ) {
        Task {
            guard let title = await runtime.generateTitle(
                userPrompt: userPrompt,
                assistantResponse: assistantResponse
            ) else { return }

            await MainActor.run {
                let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedSessionID.isEmpty, !normalizedTitle.isEmpty else { return }

                let fallbackTitle = Self.sessionTitle(from: userPrompt)
                if let index = sessions.firstIndex(where: { sessionsMatch($0.id, normalizedSessionID) }) {
                    let summary = sessions[index]
                    guard Self.shouldApplyGeneratedSessionTitle(
                        existingTitle: summary.title,
                        fallbackTitle: fallbackTitle,
                        cwd: summary.cwd ?? ""
                    ) else {
                        return
                    }
                }

                do {
                    try sessionCatalog.renameSession(
                        sessionID: normalizedSessionID,
                        title: normalizedTitle
                    )
                } catch {
                    return
                }

                if let index = sessions.firstIndex(where: { sessionsMatch($0.id, normalizedSessionID) }) {
                    sessions[index].title = normalizedTitle
                }
            }
        }
    }

    static func shouldApplyGeneratedSessionTitle(
        existingTitle: String,
        fallbackTitle: String,
        cwd: String
    ) -> Bool {
        let normalizedExisting = existingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedExisting.isEmpty else { return true }

        if normalizedExisting == cwd {
            return true
        }

        if normalizedExisting == "New Assistant Session" {
            return true
        }

        return normalizedExisting.caseInsensitiveCompare(fallbackTitle) == .orderedSame
    }

    private func recordOwnedSessionID(_ sessionID: String?) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }
        var updated = settings.assistantOwnedThreadIDs
        updated.removeAll { $0.caseInsensitiveCompare(sessionID) == .orderedSame }
        updated.insert(sessionID, at: 0)
        if updated.count > 100 {
            updated = Array(updated.prefix(100))
        }
        settings.assistantOwnedThreadIDs = updated
    }

    private func removeOwnedSessionID(_ sessionID: String?) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }
        settings.assistantOwnedThreadIDs.removeAll {
            $0.caseInsensitiveCompare(sessionID) == .orderedSame
        }
    }

    private func resolvedOwnedSessionIDs() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for candidate in settings.assistantOwnedThreadIDs {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = trimmed.lowercased()
            if seen.insert(normalized).inserted {
                ordered.append(trimmed)
            }
        }

        if let currentSessionID = runtime.currentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            let normalized = currentSessionID.lowercased()
            if seen.insert(normalized).inserted {
                ordered.insert(currentSessionID, at: 0)
            }
        }

        if let selectedSessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            let normalized = selectedSessionID.lowercased()
            if seen.insert(normalized).inserted {
                ordered.insert(selectedSessionID, at: 0)
            }
        }

        return ordered
    }

    private func appendTranscriptEntry(_ entry: AssistantTranscriptEntry, sessionID: String? = nil) {
        let targetSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? selectedSessionID

        guard sessionsMatch(targetSessionID, selectedSessionID) || transcriptSessionID == nil else {
            storeTranscriptEntryInCache(entry, sessionID: targetSessionID)
            updateVisibleSessionPreview(with: entry, sessionID: targetSessionID)
            return
        }

        if transcriptSessionID == nil {
            transcriptSessionID = targetSessionID
        }

        if let existingIndex = transcript.lastIndex(where: { $0.id == entry.id }) {
            transcript[existingIndex] = entry
        } else {
            transcript.append(entry)
        }
        if let targetSessionID {
            transcriptEntriesBySessionID[targetSessionID] = transcript
        }
        updateVisibleSessionPreview(with: entry, sessionID: targetSessionID)

        if entry.role == .assistant,
           !entry.isStreaming,
           let sessionID = targetSessionID,
           let text = entry.text.assistantNonEmpty {
            maybeCreateAutomaticFailureSuggestions(text: text, sessionID: sessionID)
        }
    }

    private func appendTimelineItem(_ item: AssistantTimelineItem) {
        applyTimelineMutation(.upsert(item))
    }

    private func applyTimelineMutation(_ mutation: AssistantTimelineMutation) {
        switch mutation {
        case .reset(let sessionID):
            guard let normalizedSessionID = sessionID?.nonEmpty else {
                if selectedSessionID == nil {
                    setVisibleTimeline([], for: nil)
                }
                return
            }

            timelineItemsBySessionID[normalizedSessionID] = []
            if sessionsMatch(timelineSessionID, normalizedSessionID) || sessionsMatch(selectedSessionID, normalizedSessionID) {
                setVisibleTimeline([], for: normalizedSessionID)
            }
            persistTimelineCacheIfNeeded(sessionID: normalizedSessionID, items: [])

        case .remove(let id):
            guard let targetSessionID = (timelineSessionID ?? selectedSessionID)?.nonEmpty else {
                timelineItems.removeAll { $0.id == id }
                rebuildRenderItemsCache()
                return
            }

            var items = timelineItemsBySessionID[targetSessionID] ?? timelineItems
            items.removeAll { $0.id == id }
            timelineItemsBySessionID[targetSessionID] = items

            if sessionsMatch(timelineSessionID, targetSessionID) || sessionsMatch(selectedSessionID, targetSessionID) {
                setVisibleTimeline(items, for: targetSessionID)
            }
            persistTimelineCacheIfNeeded(sessionID: targetSessionID, items: items)

        case .upsert(let item):
            let targetSessionID = item.sessionID?.nonEmpty
                ?? runtime.currentSessionID?.nonEmpty
                ?? selectedSessionID?.nonEmpty

            var items = targetSessionID.flatMap { timelineItemsBySessionID[$0] }
                ?? (sessionsMatch(timelineSessionID, targetSessionID) ? timelineItems : [])

            if let existingIndex = items.firstIndex(where: { $0.id == item.id }) {
                items[existingIndex] = item
            } else {
                items.append(item)
            }

            sortTimelineItems(&items)

            if let targetSessionID {
                timelineItemsBySessionID[targetSessionID] = items
                if sessionsMatch(selectedSessionID, targetSessionID) || sessionsMatch(timelineSessionID, targetSessionID) {
                    setVisibleTimeline(items, for: targetSessionID)
                }
                persistTimelineCacheIfNeeded(sessionID: targetSessionID, items: items)
            } else {
                timelineItems = items
                rebuildRenderItemsCache()
            }
        }
    }

    private func updateToolCallActivity(_ calls: [AssistantToolCallState]) {
        let incomingIDs = Set(calls.map(\.id))
        let completedCalls = toolCalls
            .filter { !incomingIDs.contains($0.id) }
            .map(Self.archivedToolCall(from:))

        if !completedCalls.isEmpty {
            let completedIDs = Set(completedCalls.map(\.id))
            recentToolCalls.removeAll { completedIDs.contains($0.id) || incomingIDs.contains($0.id) }
            recentToolCalls.insert(contentsOf: completedCalls, at: 0)
            if recentToolCalls.count > 24 {
                recentToolCalls = Array(recentToolCalls.prefix(24))
            }
        } else if !incomingIDs.isEmpty {
            recentToolCalls.removeAll { incomingIDs.contains($0.id) }
        }

        toolCalls = calls
    }

    private static func archivedToolCall(from call: AssistantToolCallState) -> AssistantToolCallState {
        var archived = call
        let normalizedStatus = archived.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["inprogress", "running", "working", "active", "started", "pending"].contains(normalizedStatus) {
            archived.status = "completed"
        }
        return archived
    }

    private func updateVisibleSessionPreview(with entry: AssistantTranscriptEntry, sessionID: String? = nil) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? selectedSessionID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let text = entry.text.assistantNonEmpty else {
            return
        }

        sessions[sessionIndex].updatedAt = entry.createdAt
        switch entry.role {
        case .user:
            sessions[sessionIndex].latestUserMessage = text
            if sessions[sessionIndex].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || sessions[sessionIndex].title == sessions[sessionIndex].cwd {
                sessions[sessionIndex].title = Self.sessionTitle(from: text)
            }
        case .assistant:
            sessions[sessionIndex].latestAssistantMessage = text
        default:
            break
        }
    }

    private func refreshMemoryState(for sessionID: String?) {
        guard settings.assistantMemoryEnabled else {
            currentMemoryFileURL = nil
            pendingMemorySuggestions = []
            memoryStatusMessage = "Assistant memory is off"
            return
        }

        do {
            currentMemoryFileURL = memoryRetrievalService.currentMemoryFileURL(for: sessionID)
            pendingMemorySuggestions = try memorySuggestionService.suggestions(for: sessionID)
            updateMemoryStatus(base: currentMemoryFileURL != nil ? "Using session memory" : nil)
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    private func updateMemoryStatus(base: String?, suggestionCount: Int? = nil) {
        guard settings.assistantMemoryEnabled else {
            memoryStatusMessage = "Assistant memory is off"
            return
        }

        let count = suggestionCount ?? pendingMemorySuggestions.count
        let suggestionSuffix: String?
        if count > 0 {
            suggestionSuffix = "\(count) memory suggestion\(count == 1 ? "" : "s") waiting for review"
        } else {
            suggestionSuffix = nil
        }

        if let base = base?.nonEmpty, let suggestionSuffix {
            memoryStatusMessage = "\(base) · \(suggestionSuffix)"
        } else if let suggestionSuffix {
            memoryStatusMessage = suggestionSuffix
        } else {
            memoryStatusMessage = base?.nonEmpty
        }
    }

    private func handleCreatedSuggestions(
        _ created: [AssistantMemorySuggestion],
        sessionID: String,
        directSaveWhenReviewDisabled: Bool
    ) throws {
        guard !created.isEmpty else {
            lastStatusMessage = "That message did not create a stable long-term lesson yet."
            refreshMemoryState(for: sessionID)
            return
        }

        if directSaveWhenReviewDisabled && !settings.assistantMemoryReviewEnabled {
            for suggestion in created {
                try memorySuggestionService.acceptSuggestion(id: suggestion.id)
            }
            refreshMemoryState(for: sessionID)
            updateMemoryStatus(base: "Saved to long-term assistant memory")
            return
        }

        pendingMemorySuggestions = try memorySuggestionService.suggestions(for: sessionID)
        currentMemoryFileURL = memoryRetrievalService.currentMemoryFileURL(for: sessionID)
        updateMemoryStatus(base: nil)
        showMemorySuggestionReview = true
        lastStatusMessage = created.count == 1
            ? "Added 1 memory suggestion for review."
            : "Added \(created.count) memory suggestions for review."
    }

    private func resolvedSessionCWD(for sessionID: String) -> String? {
        if let matchingSession = sessions.first(where: { sessionsMatch($0.id, sessionID) }) {
            return matchingSession.cwd
        }
        return selectedSession?.cwd
    }

    private func latestUserMessage(for sessionID: String) -> String? {
        sessions.first(where: { sessionsMatch($0.id, sessionID) })?.latestUserMessage
    }

    private func latestAssistantMessage(for sessionID: String) -> String? {
        sessions.first(where: { sessionsMatch($0.id, sessionID) })?.latestAssistantMessage
    }

    private func refreshModeSwitchSuggestion() {
        if let blockedModeSwitchSuggestion,
           blockedModeSwitchSuggestion.originMode == interactionMode {
            modeSwitchSuggestion = blockedModeSwitchSuggestion
            return
        }

        modeSwitchSuggestion = Self.modeSwitchSuggestion(
            forDraft: promptDraft,
            currentMode: interactionMode
        )
    }

    static func modeSwitchSuggestion(
        forDraft draft: String,
        currentMode: AssistantInteractionMode
    ) -> AssistantModeSwitchSuggestion? {
        guard currentMode == .conversational else { return nil }
        guard looksLikePlanModeRequest(draft) else { return nil }

        return AssistantModeSwitchSuggestion(
            source: .draft,
            originMode: currentMode,
            message: "This request sounds like planning work. You can switch to Plan mode for a plan-first response.",
            choices: [
                AssistantModeSwitchChoice(
                    mode: .plan,
                    title: "Switch to Plan",
                    resendLastRequest: false
                )
            ]
        )
    }

    static func modeSwitchSuggestion(
        for event: AssistantModeRestrictionEvent
    ) -> AssistantModeSwitchSuggestion? {
        guard event.mode == .conversational else { return nil }

        let normalizedTitle = event.activityTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if event.commandClass == .validation {
            return AssistantModeSwitchSuggestion(
                source: .blocked,
                originMode: event.mode,
                message: "Chat mode stopped because this request needs checks. You can retry it in Plan mode or Agentic mode.",
                choices: [
                    AssistantModeSwitchChoice(
                        mode: .plan,
                        title: "Switch & Retry in Plan",
                        resendLastRequest: true
                    ),
                    AssistantModeSwitchChoice(
                        mode: .agentic,
                        title: "Switch & Retry in Agentic",
                        resendLastRequest: true
                    )
                ]
            )
        }

        if ["browser", "browser use", "computer use", "app action"].contains(normalizedTitle ?? "") {
            return AssistantModeSwitchSuggestion(
                source: .blocked,
                originMode: event.mode,
                message: "Chat mode stopped because this needs live browser or computer control. You can retry it in Agentic mode.",
                choices: [
                    AssistantModeSwitchChoice(
                        mode: .agentic,
                        title: "Switch & Retry in Agentic",
                        resendLastRequest: true
                    )
                ]
            )
        }

        return AssistantModeSwitchSuggestion(
            source: .blocked,
            originMode: event.mode,
            message: "Chat mode stopped because this request needs stronger tool access. You can retry it in Agentic mode.",
            choices: [
                AssistantModeSwitchChoice(
                    mode: .agentic,
                    title: "Switch & Retry in Agentic",
                    resendLastRequest: true
                )
            ]
        )
    }

    private static func looksLikePlanModeRequest(_ prompt: String) -> Bool {
        let normalized = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let tokens = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let tokenSet = Set(tokens)

        if tokenSet.contains("plan") || tokenSet.contains("checklist") || tokenSet.contains("roadmap") {
            return true
        }

        let phrases = [
            "make a plan",
            "give me a plan",
            "switch to plan",
            "step by step plan",
            "step-by-step plan",
            "implementation plan",
            "outline the steps",
            "brainstorm",
            "plan this"
        ]

        return phrases.contains { normalized.contains($0) }
    }

    private func maybeCreateAutomaticFailureSuggestions(
        text: String,
        sessionID: String
    ) {
        guard settings.assistantMemoryEnabled,
              settings.assistantMemoryReviewEnabled else {
            return
        }

        guard !pendingMemorySuggestions.contains(where: { sessionsMatch($0.threadID, sessionID) }) else {
            return
        }

        let toolCount = toolCalls.count + recentToolCalls.count

        do {
            let scope = memoryRetrievalService.makeScopeContext(
                threadID: sessionID,
                cwd: resolvedSessionCWD(for: sessionID)
            )
            let created = try memorySuggestionService.createAutomaticFailureSuggestions(
                from: text,
                toolCount: toolCount,
                threadID: sessionID,
                scope: scope
            )
            guard !created.isEmpty else { return }
            pendingMemorySuggestions = try memorySuggestionService.suggestions(for: sessionID)
            updateMemoryStatus(base: "Using session memory")
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    private var selectedSession: AssistantSessionSummary? {
        guard let selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    struct ResolvedSessionConfiguration: Equatable {
        let modelID: String?
        let interactionMode: AssistantInteractionMode
        let reasoningEffort: AssistantReasoningEffort
        let fastModeEnabled: Bool
    }

    static func resolvedSessionConfiguration(
        from session: AssistantSessionSummary?,
        availableModels: [AssistantModelOption],
        preferredModelID: String?
    ) -> ResolvedSessionConfiguration {
        let visibleModelIDs = Set(availableModels.filter { !$0.hidden }.map(\.id))

        let preferredModelID = preferredModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let fallbackModelID = preferredModelID.flatMap { visibleModelIDs.contains($0) ? $0 : nil }
        let restoredModelID = session?.modelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let resolvedModelID = restoredModelID.flatMap { visibleModelIDs.contains($0) ? $0 : nil }
            ?? fallbackModelID

        return ResolvedSessionConfiguration(
            modelID: resolvedModelID,
            interactionMode: session?.latestInteractionMode ?? .conversational,
            reasoningEffort: session?.latestReasoningEffort ?? .high,
            fastModeEnabled: session?.fastModeEnabled ?? false
        )
    }

    private func restoreSessionConfiguration(from session: AssistantSessionSummary?) {
        guard let session else { return }

        isRestoringSessionConfiguration = true
        defer { isRestoringSessionConfiguration = false }

        let resolvedConfiguration = Self.resolvedSessionConfiguration(
            from: session,
            availableModels: availableModels,
            preferredModelID: settings.assistantPreferredModelID.nonEmpty
        )

        selectedModelID = resolvedConfiguration.modelID
        runtime.setPreferredModelID(resolvedConfiguration.modelID)
        runtimeHealth.selectedModelID = resolvedConfiguration.modelID
        interactionMode = resolvedConfiguration.interactionMode
        reasoningEffort = resolvedConfiguration.reasoningEffort
        fastModeEnabled = resolvedConfiguration.fastModeEnabled
        syncReasoningEffortWithSelectedModel(preferModelDefault: false)
        syncRuntimeContext()
    }

    private func updateVisibleSessionConfiguration() {
        guard let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let sessionIndex = sessions.firstIndex(where: { sessionsMatch($0.id, sessionID) }) else {
            return
        }

        sessions[sessionIndex].latestModel = selectedModelID
        sessions[sessionIndex].latestInteractionMode = interactionMode
        sessions[sessionIndex].latestReasoningEffort = reasoningEffort
        sessions[sessionIndex].latestServiceTier = fastModeEnabled ? "fast" : nil
    }

    private func clearActiveProposedPlanIfNeeded(for sessionID: String?) {
        guard proposedPlan?.nonEmpty != nil else {
            proposedPlanSessionID = nil
            return
        }

        guard Self.shouldPreserveProposedPlan(
            planSessionID: proposedPlanSessionID,
            activeSessionID: sessionID
        ) else {
            proposedPlan = nil
            proposedPlanSessionID = nil
            return
        }
    }

    static func combinedRuntimeInstructions(
        global: String,
        session: String,
        oneShot: String
    ) -> String? {
        let parts = [global, session, oneShot].compactMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    static func shouldPreserveProposedPlan(
        planSessionID: String?,
        activeSessionID: String?
    ) -> Bool {
        guard let planSessionID = planSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let activeSessionID = activeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return false
        }

        return planSessionID.caseInsensitiveCompare(activeSessionID) == .orderedSame
    }

    static func planExecutionSessionID(planSessionID: String?) -> String? {
        planSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    static func buildResumeContext(
        transcriptEntries: [AssistantTranscriptEntry],
        sessionSummary: AssistantSessionSummary?,
        maxEntries: Int = 4,
        maxCharsPerEntry: Int = 220,
        maxTotalChars: Int = 900
    ) -> String? {
        var lines: [String] = []
        var seenKeys: Set<String> = []

        let meaningfulEntries = transcriptEntries
            .filter { entry in
                guard !entry.isStreaming else { return false }
                switch entry.role {
                case .user, .assistant, .error:
                    return entry.text.assistantNonEmpty != nil
                case .system, .status, .tool, .permission:
                    return false
                }
            }
            .suffix(maxEntries)

        for entry in meaningfulEntries {
            let normalized = normalizedResumeContextSnippet(entry.text, limit: maxCharsPerEntry)
            guard !normalized.isEmpty else { continue }
            let dedupeKey = entry.role.rawValue + "::" + normalized.lowercased()
            guard seenKeys.insert(dedupeKey).inserted else { continue }
            lines.append("- \(resumeContextRoleLabel(for: entry.role)): \(normalized)")
        }

        if lines.isEmpty, let sessionSummary {
            if let latestUser = sessionSummary.latestUserMessage?.assistantNonEmpty {
                lines.append("- User: \(normalizedResumeContextSnippet(latestUser, limit: maxCharsPerEntry))")
            }
            if let latestAssistant = sessionSummary.latestAssistantMessage?.assistantNonEmpty {
                lines.append("- Assistant: \(normalizedResumeContextSnippet(latestAssistant, limit: maxCharsPerEntry))")
            } else if let summary = sessionSummary.summary?.assistantNonEmpty {
                lines.append("- Assistant: \(normalizedResumeContextSnippet(summary, limit: maxCharsPerEntry))")
            }
        }

        guard !lines.isEmpty else { return nil }

        let header = """
        # Recovered Thread Context
        This session was reopened. Use these recent notes only as a short reminder if earlier thread state is missing.
        """

        let body = lines.joined(separator: "\n")
        let raw = "\(header)\n\n\(body)"
        if raw.count <= maxTotalChars {
            return raw
        }

        let availableBodyChars = max(120, maxTotalChars - header.count - 2)
        let shortenedBody = normalizedResumeContextSnippet(body, limit: availableBodyChars)
        guard !shortenedBody.isEmpty else { return header }
        return "\(header)\n\n\(shortenedBody)"
    }

    private func preferredSessionID(preferConversationContent: Bool = true) -> String? {
        if preferConversationContent,
           let session = sessions.first(where: { $0.hasConversationContent }) {
            return session.id
        }
        return sessions.first?.id
    }

    private func prepareSessionForPrompt() async throws -> String {
        if let selectedSessionID = selectedSessionID?.nonEmpty {
            if let currentSessionID = runtime.currentSessionID?.nonEmpty {
                if sessionsMatch(currentSessionID, selectedSessionID) {
                    return currentSessionID
                }

                if Self.shouldBlockSessionSwitch(
                    activeSessionID: currentSessionID,
                    hasActiveTurn: runtime.hasActiveTurn,
                    requestedSessionID: selectedSessionID
                ) {
                    throw AssistantPromptRoutingError.activeTurnInDifferentSession
                }
            }

            if let selectedSession = sessions.first(where: { sessionsMatch($0.id, selectedSessionID) }) {
                try await runtime.resumeSession(selectedSession.id, cwd: selectedSession.cwd, preferredModelID: selectedModelID)
                pendingResumeContextSessionIDs.insert(selectedSession.id)
                return selectedSession.id
            }
        }

        if let currentSessionID = runtime.currentSessionID?.nonEmpty {
            return currentSessionID
        }

        let sessionID = try await runtime.startNewSession(preferredModelID: selectedModelID)
        return sessionID
    }

    private func reloadSelectedSessionHistoryIfNeeded(force: Bool = false) async {
        guard let selectedSessionID,
              let selectedSession,
              selectedSession.isLocalSession else {
            return
        }

        let cachedTimeline = timelineItemsBySessionID[selectedSessionID] ?? []
        let cachedTranscript = transcriptEntriesBySessionID[selectedSessionID] ?? []
        if !cachedTimeline.isEmpty,
           (!sessionsMatch(timelineSessionID, selectedSessionID) || timelineItems.isEmpty) {
            setVisibleTimeline(cachedTimeline, for: selectedSessionID)
        }
        if !cachedTranscript.isEmpty,
           (!sessionsMatch(transcriptSessionID, selectedSessionID) || transcript.isEmpty) {
            setVisibleTranscript(cachedTranscript, for: selectedSessionID)
        }

        guard force
            || transcriptSessionID != selectedSessionID
            || timelineSessionID != selectedSessionID else {
            return
        }

        let requestID = UUID()
        sessionLoadRequestID = requestID
        let loadedTimeline = await sessionCatalog.loadMergedTimeline(sessionID: selectedSessionID)
        let loadedTranscript = await sessionCatalog.loadTranscript(sessionID: selectedSessionID)

        guard sessionLoadRequestID == requestID,
              sessionsMatch(self.selectedSessionID, selectedSessionID) else {
            return
        }

        let mergedTimeline = mergeTimelineHistory(
            loadedTimeline,
            with: timelineItemsBySessionID[selectedSessionID] ?? []
        )
        let mergedTranscript = mergeTranscriptHistory(
            loadedTranscript,
            with: transcriptEntriesBySessionID[selectedSessionID] ?? []
        )
        if !mergedTimeline.isEmpty || timelineItems.isEmpty || timelineSessionID != selectedSessionID {
            setVisibleTimeline(mergedTimeline, for: selectedSessionID)
        }
        if !mergedTranscript.isEmpty || transcript.isEmpty || transcriptSessionID != selectedSessionID {
            setVisibleTranscript(mergedTranscript, for: selectedSessionID)
        }
        isTransitioningSession = false
    }

    private func resumeContextIfNeeded(for sessionID: String) -> String? {
        guard pendingResumeContextSessionIDs.contains(sessionID) else { return nil }

        let sessionTranscript: [AssistantTranscriptEntry]
        if sessionsMatch(transcriptSessionID, sessionID) {
            sessionTranscript = transcript
        } else {
            sessionTranscript = []
        }

        let summary = sessions.first(where: { sessionsMatch($0.id, sessionID) })
        return Self.buildResumeContext(
            transcriptEntries: sessionTranscript,
            sessionSummary: summary
        )
    }

    private func setVisibleTimeline(_ items: [AssistantTimelineItem], for sessionID: String?) {
        timelineItems = items
        timelineSessionID = sessionID
        if let sessionID = sessionID?.nonEmpty {
            timelineItemsBySessionID[sessionID] = items
        }
        rebuildRenderItemsCache()
    }

    private func setVisibleTranscript(_ entries: [AssistantTranscriptEntry], for sessionID: String?) {
        transcript = entries
        transcriptSessionID = sessionID
        if let sessionID = sessionID?.nonEmpty {
            transcriptEntriesBySessionID[sessionID] = entries
        }
    }

    private func storeTranscriptEntryInCache(_ entry: AssistantTranscriptEntry, sessionID: String?) {
        guard let sessionID = sessionID?.nonEmpty else { return }
        var entries = transcriptEntriesBySessionID[sessionID] ?? []
        if let existingIndex = entries.lastIndex(where: { $0.id == entry.id }) {
            entries[existingIndex] = entry
        } else {
            entries.append(entry)
        }
        entries.sort {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
        transcriptEntriesBySessionID[sessionID] = entries
    }

    private func mergeTranscriptHistory(
        _ persistedEntries: [AssistantTranscriptEntry],
        with cachedEntries: [AssistantTranscriptEntry]
    ) -> [AssistantTranscriptEntry] {
        guard !persistedEntries.isEmpty || !cachedEntries.isEmpty else { return [] }

        var mergedByID: [UUID: AssistantTranscriptEntry] = [:]
        for entry in persistedEntries {
            mergedByID[entry.id] = entry
        }
        for entry in cachedEntries {
            mergedByID[entry.id] = entry
        }

        return mergedByID.values.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    /// Rebuilds the cached render items from the current timeline items.
    /// Called only when timeline data actually changes, avoiding the expensive
    /// recomputation that previously happened on every @Published update.
    private func rebuildRenderItemsCache() {
        let planIDs = Set(
            timelineItems.compactMap { item -> String? in
                guard item.kind == .plan else { return nil }
                return item.turnID?.assistantNonEmpty
            }
        )

        let visible = timelineItems.filter { item in
            switch item.kind {
            case .userMessage, .system:
                return item.text?.assistantNonEmpty != nil
            case .assistantProgress, .assistantFinal:
                if let turnID = item.turnID?.assistantNonEmpty,
                   planIDs.contains(turnID) {
                    return false
                }
                return AssistantVisibleTextSanitizer.clean(item.text)?.assistantNonEmpty != nil
            case .activity:
                return item.activity != nil
            case .permission:
                return item.permissionRequest != nil
            case .plan:
                return item.planText?.assistantNonEmpty != nil
            }
        }

        cachedRenderItems = buildAssistantTimelineRenderItems(from: visible)
    }

    private func mergeTimelineHistory(
        _ base: [AssistantTimelineItem],
        with overlay: [AssistantTimelineItem]
    ) -> [AssistantTimelineItem] {
        guard !overlay.isEmpty else { return base }

        var merged = base
        var mergedByID = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($0.element.id, $0.offset) })

        for item in overlay {
            if let existingIndex = mergedByID[item.id] {
                let mergedItem = mergeDuplicateTimelineItem(merged[existingIndex], item)
                let previousID = merged[existingIndex].id
                merged[existingIndex] = mergedItem
                if previousID != mergedItem.id {
                    mergedByID.removeValue(forKey: previousID)
                }
                mergedByID[mergedItem.id] = existingIndex
                continue
            }

            if let duplicateIndex = merged.lastIndex(where: { timelineItemsShouldDeduplicate($0, item) }) {
                let mergedItem = mergeDuplicateTimelineItem(merged[duplicateIndex], item)
                let previousID = merged[duplicateIndex].id
                merged[duplicateIndex] = mergedItem
                if previousID != mergedItem.id {
                    mergedByID.removeValue(forKey: previousID)
                }
                mergedByID[mergedItem.id] = duplicateIndex
                continue
            }

            mergedByID[item.id] = merged.count
            merged.append(item)
        }

        sortTimelineItems(&merged)
        return merged
    }

    private func mergeDuplicateTimelineItem(
        _ existing: AssistantTimelineItem,
        _ incoming: AssistantTimelineItem
    ) -> AssistantTimelineItem {
        var preferred = preferredTimelineItem(existing, incoming)
        let fallback = preferred.id == existing.id ? incoming : existing

        preferred.sessionID = preferred.sessionID?.nonEmpty ?? fallback.sessionID?.nonEmpty
        preferred.turnID = preferred.turnID?.nonEmpty ?? fallback.turnID?.nonEmpty
        preferred.createdAt = min(existing.createdAt, incoming.createdAt)
        preferred.updatedAt = max(existing.updatedAt, incoming.updatedAt)
        preferred.text = preferredTimelineText(primary: preferred.text, fallback: fallback.text)
        preferred.isStreaming = existing.isStreaming && incoming.isStreaming
        preferred.emphasis = existing.emphasis || incoming.emphasis
        preferred.activity = preferred.activity ?? fallback.activity
        preferred.permissionRequest = preferred.permissionRequest ?? fallback.permissionRequest
        preferred.planText = preferredTimelineText(primary: preferred.planText, fallback: fallback.planText)
        if preferred.planEntries?.isEmpty ?? true {
            preferred.planEntries = fallback.planEntries
        }
        if preferred.imageAttachments?.isEmpty ?? true {
            preferred.imageAttachments = fallback.imageAttachments
        }

        return preferred
    }

    private func preferredTimelineItem(
        _ lhs: AssistantTimelineItem,
        _ rhs: AssistantTimelineItem
    ) -> AssistantTimelineItem {
        if lhs.lastUpdatedAt != rhs.lastUpdatedAt {
            return lhs.lastUpdatedAt > rhs.lastUpdatedAt ? lhs : rhs
        }

        let lhsContentLength = timelineContentLength(lhs)
        let rhsContentLength = timelineContentLength(rhs)
        if lhsContentLength != rhsContentLength {
            return lhsContentLength >= rhsContentLength ? lhs : rhs
        }

        if lhs.isStreaming != rhs.isStreaming {
            return lhs.isStreaming ? rhs : lhs
        }

        let lhsSourceRank = timelineSourceRank(lhs.source)
        let rhsSourceRank = timelineSourceRank(rhs.source)
        if lhsSourceRank != rhsSourceRank {
            return lhsSourceRank >= rhsSourceRank ? lhs : rhs
        }

        return rhs
    }

    private func timelineItemsShouldDeduplicate(
        _ lhs: AssistantTimelineItem,
        _ rhs: AssistantTimelineItem
    ) -> Bool {
        if let lhsSessionID = lhs.sessionID?.nonEmpty,
           let rhsSessionID = rhs.sessionID?.nonEmpty,
           !sessionsMatch(lhsSessionID, rhsSessionID) {
            return false
        }

        switch (lhs.kind, rhs.kind) {
        case (.activity, .activity):
            return lhs.activity?.id == rhs.activity?.id

        case (.userMessage, .userMessage),
             (.system, .system):
            return normalizedTimelineDeduplicationText(lhs.text) == normalizedTimelineDeduplicationText(rhs.text)
                && timelineTurnsLikelyMatch(lhs.turnID, rhs.turnID)
                && abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) < 1

        case (.assistantProgress, .assistantProgress),
             (.assistantFinal, .assistantFinal),
             (.assistantProgress, .assistantFinal),
             (.assistantFinal, .assistantProgress):
            return normalizedTimelineDeduplicationText(lhs.text) == normalizedTimelineDeduplicationText(rhs.text)
                && timelineTurnsLikelyMatch(lhs.turnID, rhs.turnID)
                && abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) < 5

        case (.permission, .permission):
            return lhs.permissionRequest?.toolTitle == rhs.permissionRequest?.toolTitle
                && timelineTurnsLikelyMatch(lhs.turnID, rhs.turnID)
                && abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) < 3

        case (.plan, .plan):
            return normalizedTimelineDeduplicationText(lhs.planText) == normalizedTimelineDeduplicationText(rhs.planText)
                && timelineTurnsLikelyMatch(lhs.turnID, rhs.turnID)

        default:
            return false
        }
    }

    private func timelineTurnsLikelyMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.nonEmpty, let rhs = rhs?.nonEmpty else {
            return true
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func normalizedTimelineDeduplicationText(_ value: String?) -> String {
        (value ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func timelineContentLength(_ item: AssistantTimelineItem) -> Int {
        switch item.kind {
        case .userMessage, .assistantProgress, .assistantFinal, .system:
            return normalizedTimelineDeduplicationText(item.text).count
        case .permission:
            let title = item.permissionRequest?.toolTitle ?? ""
            let rationale = item.permissionRequest?.rationale ?? ""
            return normalizedTimelineDeduplicationText(title + "\n" + rationale).count
        case .plan:
            return normalizedTimelineDeduplicationText(item.planText).count
        case .activity:
            let title = item.activity?.title ?? ""
            let summary = item.activity?.friendlySummary ?? ""
            let details = item.activity?.rawDetails ?? ""
            return normalizedTimelineDeduplicationText(title + "\n" + summary + "\n" + details).count
        }
    }

    private func timelineSourceRank(_ source: AssistantTimelineSource) -> Int {
        switch source {
        case .runtime:
            return 3
        case .codexSession:
            return 2
        case .cache:
            return 1
        }
    }

    private func preferredTimelineText(primary: String?, fallback: String?) -> String? {
        let normalizedPrimary = normalizedTimelineDeduplicationText(primary)
        let normalizedFallback = normalizedTimelineDeduplicationText(fallback)

        if normalizedPrimary.isEmpty {
            return fallback?.nonEmpty
        }
        if normalizedFallback.count > normalizedPrimary.count {
            return fallback?.nonEmpty
        }
        return primary?.nonEmpty
    }

    private func sortTimelineItems(_ items: inout [AssistantTimelineItem]) {
        items.sort {
            if $0.sortDate != $1.sortDate {
                return $0.sortDate < $1.sortDate
            }
            if $0.lastUpdatedAt != $1.lastUpdatedAt {
                return $0.lastUpdatedAt < $1.lastUpdatedAt
            }
            return $0.id < $1.id
        }
    }

    private func sessionsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return false
        }

        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func persistTimelineCacheIfNeeded(sessionID: String?, items: [AssistantTimelineItem]? = nil) {
        guard let sessionID = sessionID?.nonEmpty else { return }
        let ownedSessionIDs = Set(settings.assistantOwnedThreadIDs.map { $0.lowercased() })
        guard ownedSessionIDs.contains(sessionID.lowercased()) else { return }
        let itemsToSave = items
            ?? timelineItemsBySessionID[sessionID]
            ?? (sessionsMatch(timelineSessionID, sessionID) ? timelineItems : [])
        sessionCatalog.saveNormalizedTimeline(itemsToSave, for: sessionID)
    }

    private static func resumeContextRoleLabel(for role: AssistantTranscriptRole) -> String {
        switch role {
        case .user:
            return "User"
        case .assistant:
            return "Assistant"
        case .error:
            return "Error"
        case .system, .status, .tool, .permission:
            return "Note"
        }
    }

    private static func normalizedResumeContextSnippet(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "" }
        guard collapsed.count > limit else { return collapsed }

        let cutoffIndex = collapsed.index(collapsed.startIndex, offsetBy: max(0, limit - 1))
        let prefix = String(collapsed[..<cutoffIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? "" : prefix + "..."
    }
}

private enum AssistantPromptRoutingError: LocalizedError {
    case activeTurnInDifferentSession

    var errorDescription: String? {
        switch self {
        case .activeTurnInDifferentSession:
            return "Another session is still running. Let it finish before sending a message to this session."
        }
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var assistantNonEmpty: String? {
        nonEmpty
    }

    func removingAssistantAttachmentPlaceholders() -> String {
        var text = self
        let blockPatterns = [
            #"<image\b[^>]*>[\s\S]*?</image>"#,
            #"<localimage\b[^>]*>[\s\S]*?</localimage>"#
        ]
        for pattern in blockPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
        }

        text = text.replacingOccurrences(
            of: #"</?(image|localimage)\b[^>]*>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        return text
    }
}

private extension AssistantSessionSummary {
    var hasConversationContent: Bool {
        summary?.assistantNonEmpty != nil
            || latestUserMessage?.assistantNonEmpty != nil
            || latestAssistantMessage?.assistantNonEmpty != nil
    }
}
