import AppKit
import Combine
import Foundation
import SwiftUI

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

    /// Whether the assistant is actively processing (as opposed to idle/done/failed).
    var isActive: Bool {
        switch self {
        case .listening, .thinking, .acting, .waitingForPermission, .streaming:
            return true
        case .idle, .success, .failed:
            return false
        }
    }
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

private func normalizedRateLimitSearchText(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }

    let lowered = value.lowercased()
    let normalizedScalars = lowered.unicodeScalars.map { scalar -> Character in
        if CharacterSet.alphanumerics.contains(scalar) {
            return Character(scalar)
        }
        return " "
    }
    let normalized = String(normalizedScalars)
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    return normalized.isEmpty ? nil : normalized
}

struct AccountRateLimitBucket: Identifiable, Equatable, Sendable {
    var limitID: String
    var limitName: String?
    var primary: RateLimitWindow?
    var secondary: RateLimitWindow?
    var hasCredits: Bool
    var unlimited: Bool

    var id: String { limitID }

    var isDefaultCodex: Bool {
        limitID.caseInsensitiveCompare("codex") == .orderedSame
    }

    var displayName: String {
        if let trimmed = limitName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        return limitID.replacingOccurrences(of: "_", with: "-")
    }

    var mostUsedWindow: RateLimitWindow? {
        switch (primary, secondary) {
        case let (p?, s?): return p.usedPercent >= s.usedPercent ? p : s
        case let (p?, nil): return p
        case let (nil, s?): return s
        case (nil, nil): return nil
        }
    }

    fileprivate var searchText: String {
        normalizedRateLimitSearchText([limitID, limitName].compactMap { $0 }.joined(separator: " ")) ?? ""
    }

    init(
        limitID: String,
        limitName: String? = nil,
        primary: RateLimitWindow? = nil,
        secondary: RateLimitWindow? = nil,
        hasCredits: Bool = true,
        unlimited: Bool = false
    ) {
        self.limitID = limitID
        self.limitName = limitName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.primary = primary
        self.secondary = secondary
        self.hasCredits = hasCredits
        self.unlimited = unlimited
    }

    init?(from dict: [String: Any], fallbackLimitID: String? = nil) {
        let resolvedLimitID = (dict["limitId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? fallbackLimitID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let primary = RateLimitWindow(from: dict["primary"] as? [String: Any])
        let secondary = RateLimitWindow(from: dict["secondary"] as? [String: Any])
        let creditsDict = dict["credits"] as? [String: Any]

        guard let limitID = resolvedLimitID ?? ((primary != nil || secondary != nil || creditsDict != nil) ? "codex" : nil) else {
            return nil
        }

        self.init(
            limitID: limitID,
            limitName: dict["limitName"] as? String,
            primary: primary,
            secondary: secondary,
            hasCredits: creditsDict?["hasCredits"] as? Bool ?? true,
            unlimited: creditsDict?["unlimited"] as? Bool ?? false
        )
    }
}

struct AccountRateLimits: Equatable, Sendable {
    var planType: String?
    var primary: RateLimitWindow?
    var secondary: RateLimitWindow?
    var hasCredits: Bool
    var unlimited: Bool
    var limitID: String? = nil
    var limitName: String? = nil
    var additionalBuckets: [AccountRateLimitBucket] = []

    static let empty = AccountRateLimits(
        planType: nil, primary: nil, secondary: nil,
        hasCredits: true, unlimited: false,
        limitID: nil, limitName: nil, additionalBuckets: []
    )

    var isEmpty: Bool {
        allBuckets.allSatisfy { $0.primary == nil && $0.secondary == nil }
    }

    /// Returns the window with the highest usage percent, for compact display.
    var mostUsedWindow: RateLimitWindow? {
        bucket(for: nil)?.mostUsedWindow
    }

    var defaultBucket: AccountRateLimitBucket? {
        guard let limitID = limitID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? ((primary != nil || secondary != nil) ? "codex" : nil) else {
            return nil
        }

        return AccountRateLimitBucket(
            limitID: limitID,
            limitName: limitName,
            primary: primary,
            secondary: secondary,
            hasCredits: hasCredits,
            unlimited: unlimited
        )
    }

    var allBuckets: [AccountRateLimitBucket] {
        var ordered: [AccountRateLimitBucket] = []
        var seen: Set<String> = []

        func appendBucket(_ bucket: AccountRateLimitBucket?) {
            guard let bucket else { return }
            let normalizedID = normalizedRateLimitSearchText(bucket.limitID) ?? bucket.limitID.lowercased()
            guard seen.insert(normalizedID).inserted else { return }
            ordered.append(bucket)
        }

        appendBucket(defaultBucket)
        additionalBuckets.forEach(appendBucket)

        let defaultBuckets = ordered.filter(\.isDefaultCodex)
        let nonDefaultBuckets = ordered
            .filter { !$0.isDefaultCodex }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        return defaultBuckets + nonDefaultBuckets
    }

    func bucket(for modelID: String?) -> AccountRateLimitBucket? {
        let buckets = allBuckets.filter { $0.primary != nil || $0.secondary != nil }
        guard !buckets.isEmpty else { return nil }

        let defaultBucket = buckets.first(where: \.isDefaultCodex) ?? buckets.first
        let nonDefaultBuckets = buckets.filter { !$0.isDefaultCodex }
        guard let normalizedModelID = normalizedRateLimitSearchText(modelID) else {
            return defaultBucket
        }

        if normalizedModelID.contains("spark") {
            if let sparkBucket = nonDefaultBuckets.first(where: { $0.searchText.contains("spark") }) {
                return sparkBucket
            }

            if nonDefaultBuckets.count == 1 {
                return nonDefaultBuckets[0]
            }
        }

        if let matchingBucket = nonDefaultBuckets.first(where: { bucket in
            let searchText = bucket.searchText
            return !searchText.isEmpty
                && (searchText.contains(normalizedModelID) || normalizedModelID.contains(searchText))
        }) {
            return matchingBucket
        }

        return defaultBucket
    }

    static func fromPayload(
        _ payload: [String: Any],
        preserving existing: AccountRateLimits = .empty
    ) -> AccountRateLimits? {
        let defaultDict = (payload["rateLimits"] as? [String: Any]) ?? payload
        let defaultBucket = AccountRateLimitBucket(from: defaultDict, fallbackLimitID: "codex")
            ?? existing.defaultBucket

        guard let resolvedDefaultBucket = defaultBucket else {
            return nil
        }

        let parsedAdditionalBuckets: [AccountRateLimitBucket]
        if let bucketsByLimitID = payload["rateLimitsByLimitId"] as? [String: Any] {
            parsedAdditionalBuckets = bucketsByLimitID.compactMap { key, value in
                guard let dict = value as? [String: Any] else { return nil }
                let bucket = AccountRateLimitBucket(from: dict, fallbackLimitID: key)
                if bucket?.limitID.caseInsensitiveCompare(resolvedDefaultBucket.limitID) == .orderedSame {
                    return nil
                }
                return bucket
            }
        } else {
            parsedAdditionalBuckets = existing.additionalBuckets
        }

        return AccountRateLimits(
            planType: (defaultDict["planType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? existing.planType,
            primary: resolvedDefaultBucket.primary,
            secondary: resolvedDefaultBucket.secondary,
            hasCredits: resolvedDefaultBucket.hasCredits,
            unlimited: resolvedDefaultBucket.unlimited,
            limitID: resolvedDefaultBucket.limitID,
            limitName: resolvedDefaultBucket.limitName,
            additionalBuckets: parsedAdditionalBuckets
        )
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

    var exactContextSummary: String {
        let used = formatExactTokenCount(currentContextTokens)
        if let window = modelContextWindow, window > 0 {
            return "\(used) of \(formatExactTokenCount(window)) tokens"
        }
        return "\(used) tokens"
    }

    var contextTooltipDetail: String {
        if let window = modelContextWindow, window > 0 {
            let usedPercent = Int(round((contextUsageFraction ?? 0) * 100))
            let remaining = max(window - currentContextTokens, 0)
            return "\(usedPercent)% of context used - \(formatExactTokenCount(remaining)) left"
        }
        return "Current context in this chat"
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func formatExactTokenCount(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
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

enum AssistantTranscriptMutation: Equatable, Sendable {
    case reset(sessionID: String?)
    case upsert(AssistantTranscriptEntry, sessionID: String?)
    case appendDelta(
        id: UUID,
        sessionID: String?,
        role: AssistantTranscriptRole,
        delta: String,
        createdAt: Date,
        emphasis: Bool,
        isStreaming: Bool
    )
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
    var effectiveCWD: String?
    var createdAt: Date?
    var updatedAt: Date?
    var summary: String?
    var latestModel: String?
    var latestInteractionMode: AssistantInteractionMode?
    var latestReasoningEffort: AssistantReasoningEffort?
    var latestServiceTier: String?
    var latestUserMessage: String?
    var latestAssistantMessage: String?
    var projectID: String?
    var projectName: String?
    var linkedProjectFolderPath: String?
    var projectFolderMissing: Bool

    init(
        id: String,
        title: String,
        source: AssistantSessionSource,
        status: AssistantSessionStatus,
        cwd: String? = nil,
        effectiveCWD: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        summary: String? = nil,
        latestModel: String? = nil,
        latestInteractionMode: AssistantInteractionMode? = nil,
        latestReasoningEffort: AssistantReasoningEffort? = nil,
        latestServiceTier: String? = nil,
        latestUserMessage: String? = nil,
        latestAssistantMessage: String? = nil,
        projectID: String? = nil,
        projectName: String? = nil,
        linkedProjectFolderPath: String? = nil,
        projectFolderMissing: Bool = false
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.status = status
        self.cwd = cwd
        self.effectiveCWD = effectiveCWD
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.summary = summary
        self.latestModel = latestModel
        self.latestInteractionMode = latestInteractionMode
        self.latestReasoningEffort = latestReasoningEffort
        self.latestServiceTier = latestServiceTier
        self.latestUserMessage = latestUserMessage
        self.latestAssistantMessage = latestAssistantMessage
        self.projectID = projectID
        self.projectName = projectName
        self.linkedProjectFolderPath = linkedProjectFolderPath
        self.projectFolderMissing = projectFolderMissing
    }

    var subtitle: String {
        if let latestAssistantMessage, !latestAssistantMessage.isEmpty { return latestAssistantMessage }
        if let summary, !summary.isEmpty { return summary }
        if let latestUserMessage, !latestUserMessage.isEmpty { return latestUserMessage }
        if let effectiveCWD, !effectiveCWD.isEmpty { return effectiveCWD }
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
/// - `conversational`: Legacy chat-only mode kept only for backward compatibility with saved sessions.
/// - `plan`: Planning mode that proposes a plan without executing work.
/// - `agentic`: The agent has full tool access to execute work (Codex Default mode).
enum AssistantInteractionMode: String, CaseIterable, Codable, Sendable {
    case conversational
    case plan
    case agentic

    static let allCases: [AssistantInteractionMode] = [.plan, .agentic]

    var normalizedForActiveUse: AssistantInteractionMode {
        switch self {
        case .conversational:
            return .agentic
        case .plan, .agentic:
            return self
        }
    }

    var label: String {
        switch normalizedForActiveUse {
        case .plan: return "Plan"
        case .agentic: return "Agentic"
        case .conversational: return "Agentic"
        }
    }

    var icon: String {
        switch normalizedForActiveUse {
        case .plan: return "checklist"
        case .agentic: return AssistantChromeSymbol.action
        case .conversational: return AssistantChromeSymbol.action
        }
    }

    var hint: String {
        switch normalizedForActiveUse {
        case .plan: return "Use Codex plan mode and ask for approval when execution is needed"
        case .agentic: return "Full tool access to inspect and make changes"
        case .conversational: return "Full tool access to inspect and make changes"
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

struct AssistantRemoteSessionSnapshot: Sendable {
    let session: AssistantSessionSummary
    let transcriptEntries: [AssistantTranscriptEntry]
    let pendingPermissionRequest: AssistantPermissionRequest?
    let hudState: AssistantHUDState?
    let hasActiveTurn: Bool
    let imageDelivery: AssistantRemoteImageDelivery?
}

struct AssistantRemoteImageAttachment: Equatable, Sendable {
    let id: String
    let filename: String
    let mimeType: String
    let data: Data
}

struct AssistantRemoteImageDelivery: Equatable, Sendable {
    let signature: String
    let caption: String
    let attachments: [AssistantRemoteImageAttachment]
}

enum AssistantHistoryMutationKind: String, Equatable {
    case undo
    case edit
}

struct AssistantHistoryRollbackSnapshot: Equatable {
    let memoryDocument: AssistantThreadMemoryDocument?
    let removedSuggestions: [AssistantMemorySuggestion]
    let removedAcceptedEntries: [AssistantMemoryEntry]
    let agentProfile: ConversationAgentProfileRecord?
    let agentEntities: ConversationAgentEntitiesRecord?
    let agentPreferences: ConversationAgentPreferencesRecord?
}

struct AssistantHistoryMutationState: Equatable {
    let kind: AssistantHistoryMutationKind
    let sessionID: String
    let anchorID: String
    let isPendingComposerEdit: Bool
    let rewriteBackup: CodexRewriteBackup?
    let previousDraft: String
    let previousAttachments: [AssistantAttachment]
    let restoredPrompt: String
    let restoredAttachments: [AssistantAttachment]
    let removedAnchorIDs: [String]
    let retainedAnchorIDs: [String]
    let rollbackSnapshot: AssistantHistoryRollbackSnapshot?

    var bannerText: String? {
        guard isPendingComposerEdit else { return nil }
        return "Editing your last message. Update it, then press Send."
    }
}

struct AssistantHistoryActionAvailability: Equatable {
    let anchorID: String
    let canUndo: Bool
    let canEdit: Bool
}

typealias AssistantFeatureController = AssistantStore

@MainActor
final class AssistantStore: ObservableObject {
    static let shared = AssistantStore()
    private static let timelineCacheSaveDebounceInterval: TimeInterval = 0.35
    private enum HistoryLoading {
        static let initialTimelineLimit = 32
        static let initialTranscriptLimit = 24
        static let timelineBatchSize = 48
        static let transcriptBatchSize = 36
        static let recentTimelineChunkLimit = 14
        static let recentTranscriptChunkLimit = 12
    }

    @Published private(set) var runtimeHealth: AssistantRuntimeHealth = .idle
    @Published private(set) var installGuidance: AssistantInstallGuidance = .placeholder
    @Published private(set) var permissions: AssistantPermissionSnapshot = .unknown
    @Published private(set) var sessions: [AssistantSessionSummary] = []
    @Published private(set) var projects: [AssistantProject] = []
    @Published var visibleSessionsLimit: Int = 10
    
    func loadMoreSessions() {
        visibleSessionsLimit += 10
    }

    var selectedProjectFilter: AssistantProject? {
        guard let selectedProjectFilterID = selectedProjectFilterID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        return projects.first(where: {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(selectedProjectFilterID) == .orderedSame
        })
    }

    var visibleSidebarSessions: [AssistantSessionSummary] {
        guard let selectedProjectFilterID = selectedProjectFilterID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return sessions
        }
        return sessions.filter {
            $0.projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(selectedProjectFilterID) == .orderedSame
        }
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
    @Published private(set) var selectedProjectFilterID: String?
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
    @Published var interactionMode: AssistantInteractionMode = .agentic {
        didSet {
            let normalizedMode = interactionMode.normalizedForActiveUse
            if interactionMode != normalizedMode {
                interactionMode = normalizedMode
                return
            }
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
    @Published private(set) var historyMutationState: AssistantHistoryMutationState?
    @Published private(set) var historyActionsRevision: Int = 0
    @Published private(set) var memoryInspectorSnapshot: AssistantMemoryInspectorSnapshot?
    @Published private(set) var assistantVoiceHealth: AssistantSpeechHealth = .unknown
    @Published private(set) var assistantVoiceStatusMessage: String?
    @Published private(set) var isRefreshingAssistantVoiceHealth = false
    @Published private(set) var isRefreshingAssistantHumeVoices = false
    @Published private(set) var isTestingAssistantVoice = false
    @Published private(set) var isRemovingAssistantVoiceInstallation = false
    @Published private(set) var assistantVoicePlaybackActive = false
    @Published private(set) var assistantHumeVoiceOptions: [AssistantHumeVoiceOption] = []
    @Published private(set) var liveVoiceSessionSnapshot = AssistantLiveVoiceSessionSnapshot()
    @Published var showMemorySuggestionReview = false
    @Published var showMemoryInspector = false

    let installSupport: CodexInstallSupport
    let sessionCatalog: CodexSessionCatalog
    let runtime: CodexAssistantRuntime
    private let settings: SettingsStore
    private let projectStore: AssistantProjectStore
    private let projectMemoryService: AssistantProjectMemoryService
    private let threadMemoryService: AssistantThreadMemoryService
    private let memoryRetrievalService: AssistantMemoryRetrievalService
    private let memorySuggestionService: AssistantMemorySuggestionService
    private let memoryInspectorService: AssistantMemoryInspectorService
    private let automationMemoryService: AutomationMemoryService
    private let threadRewriteService: CodexThreadRewriteService
    private let assistantSpeechPlaybackService: AssistantSpeechPlaybackService
    private let assistantLegacyTADACleanupSupport: AssistantLegacyTADACleanupSupport
    private let humeVoiceCatalogService: HumeVoiceCatalogService
    private let humeConversationService: HumeConversationService
    private var lastSubmittedPrompt: String?
    private var transcriptSessionID: String?
    private var timelineSessionID: String?
    private var transcriptEntriesBySessionID: [String: [AssistantTranscriptEntry]] = [:]
    private var timelineItemsBySessionID: [String: [AssistantTimelineItem]] = [:]
    private var requestedTimelineHistoryLimitBySessionID: [String: Int] = [:]
    private var requestedTranscriptHistoryLimitBySessionID: [String: Int] = [:]
    private var canLoadMoreHistoryBySessionID: [String: Bool] = [:]
    private var editableTurnsBySessionID: [String: [CodexEditableTurn]] = [:]
    private var sessionLoadRequestID = UUID()
    private var deferredSessionHistoryReloadTask: Task<Void, Never>?
    private var isSendingPrompt = false
    private var isRefreshingEnvironment = false
    private var isRefreshingSessions = false
    private var isRestoringSessionConfiguration = false
    private var oneShotSessionInstructions: String?
    private var blockedModeSwitchSuggestion: AssistantModeSwitchSuggestion?
    private var proposedPlanSessionID: String?
    private var memoryScopeBySessionID: [String: MemoryScopeContext] = [:]
    private var pendingResumeContextSessionIDs: Set<String> = []
    private var pendingResumeContextSnapshotsBySessionID: [String: String] = [:]
    private var pendingFreshSessionIDs: Set<String> = []
    private var lastSubmittedAttachments: [AssistantAttachment] = []
    private var lastSpokenAssistantTimelineItemID: String?
    private var lastSpokenAssistantTurnID: String?
    private var pendingTimelineCacheSaveWorkItems: [String: DispatchWorkItem] = [:]
    private var isRefreshingProjectMemory = false
    private var projectMemoryCatchUpTask: Task<Void, Never>?
    private var activeMemoryInspectorTarget: AssistantMemoryInspectorTarget?
    var onStartLiveVoiceSession: ((AssistantLiveVoiceSessionSurface) -> Void)?
    var onEndLiveVoiceSession: (() -> Void)?
    var onStopLiveVoiceSpeaking: (() -> Void)?
    var onTurnCompletion: ((AssistantTurnCompletionStatus) -> Void)?

    private init(
        installSupport: CodexInstallSupport = CodexInstallSupport(),
        sessionCatalog: CodexSessionCatalog = CodexSessionCatalog(),
        runtime: CodexAssistantRuntime? = nil,
        settings: SettingsStore? = nil,
        memoryStore: MemorySQLiteStore? = nil,
        projectStore: AssistantProjectStore? = nil,
        threadMemoryService: AssistantThreadMemoryService? = nil,
        memoryRetrievalService: AssistantMemoryRetrievalService? = nil,
        memorySuggestionService: AssistantMemorySuggestionService? = nil,
        threadRewriteService: CodexThreadRewriteService? = nil,
        automationMemoryService: AutomationMemoryService = .shared,
        assistantSpeechPlaybackService: AssistantSpeechPlaybackService? = nil,
        assistantLegacyTADACleanupSupport: AssistantLegacyTADACleanupSupport = AssistantLegacyTADACleanupSupport()
    ) {
        self.installSupport = installSupport
        self.sessionCatalog = sessionCatalog
        self.settings = settings ?? .shared
        self.selectedModelID = self.settings.assistantPreferredModelID.nonEmpty
        self.runtime = runtime ?? CodexAssistantRuntime(preferredModelID: self.settings.assistantPreferredModelID.nonEmpty)
        let resolvedMemoryStore = memoryStore ?? (try? MemorySQLiteStore()) ?? MemorySQLiteStore.fallback()
        let resolvedProjectStore = projectStore ?? AssistantProjectStore()
        self.projectStore = resolvedProjectStore
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
        self.projectMemoryService = AssistantProjectMemoryService(
            projectStore: resolvedProjectStore,
            memoryStore: resolvedMemoryStore,
            memorySuggestionService: self.memorySuggestionService
        )
        self.memoryInspectorService = AssistantMemoryInspectorService(
            projectStore: resolvedProjectStore,
            projectMemoryService: self.projectMemoryService,
            threadMemoryService: resolvedThreadMemoryService,
            memoryRetrievalService: self.memoryRetrievalService,
            memorySuggestionService: self.memorySuggestionService,
            memoryStore: resolvedMemoryStore
        )
        self.automationMemoryService = automationMemoryService
        self.threadRewriteService = threadRewriteService ?? CodexThreadRewriteService(sessionCatalog: self.sessionCatalog)
        let humeTokenService = HumeAccessTokenService(settings: self.settings)
        let humeConversationConfigService = HumeConversationConfigService(settings: self.settings)
        self.assistantSpeechPlaybackService = assistantSpeechPlaybackService
            ?? AssistantSpeechPlaybackService(settings: self.settings)
        self.assistantLegacyTADACleanupSupport = assistantLegacyTADACleanupSupport
        self.humeVoiceCatalogService = HumeVoiceCatalogService(settings: self.settings)
        self.humeConversationService = HumeConversationService(
            settings: self.settings,
            tokenService: humeTokenService,
            configService: humeConversationConfigService
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
        self.runtime.onTranscriptMutation = { [weak self] mutation in
            Task { @MainActor in
                self?.applyTranscriptMutation(mutation)
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
        self.runtime.onTurnCompletion = { [weak self] status in
            Task { @MainActor in
                await self?.handleProjectMemoryCheckpoint(for: self?.runtime.currentSessionID ?? self?.selectedSessionID)
                await self?.handleThreadMemoryCheckpoint(
                    for: self?.runtime.currentSessionID ?? self?.selectedSessionID,
                    status: status
                )
                self?.onTurnCompletion?(status)
            }
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
        self.assistantSpeechPlaybackService.onPlaybackStateChange = { [weak self] isPlaying in
            Task { @MainActor in
                self?.assistantVoicePlaybackActive = isPlaying
            }
        }
        reloadProjectsFromStore()
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

    var selectedRateLimitBucket: AccountRateLimitBucket? {
        rateLimits.bucket(for: selectedModelID)
    }

    var selectedRateLimitBucketLabel: String? {
        guard let bucket = selectedRateLimitBucket, !bucket.isDefaultCodex else { return nil }

        if selectedModelID?.localizedCaseInsensitiveContains("spark") == true {
            return "Spark"
        }

        let displayName = bucket.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? nil : displayName
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

        return "The selected model \(selectedModel.displayName) cannot read image attachments. Choose a model that supports image input and try again. Attached images can still be analyzed directly when the model supports them, but live browser or app automation needs Agentic mode."
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

    var selectedSessionCanLoadMoreHistory: Bool {
        guard let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return false
        }
        return canLoadMoreHistoryBySessionID[sessionID] ?? false
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
        reloadProjectsFromStore()

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

            let persistedSessionIDs = Set(merged.compactMap { normalizedSessionID($0.id) })
            pendingFreshSessionIDs.subtract(persistedSessionIDs)
            merged = mergePendingFreshSessions(into: merged)
            merged = applyProjectMetadata(to: merged)

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

            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                sessions = Array(merged.prefix(limit))
            }
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
            refreshMemoryState(for: selectedSessionID)
            reloadMemoryInspectorSnapshot(closeIfMissing: true)
            scheduleSelectedSessionHistoryReload(force: transcript.isEmpty || timelineItems.isEmpty)
            scheduleProjectMemoryCatchUp()
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

    func remoteSessionSnapshot(
        sessionID: String,
        transcriptLimit: Int = 12
    ) async -> AssistantRemoteSessionSnapshot? {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }

        let sessionSummary: AssistantSessionSummary?
        if let cachedSession = sessions.first(where: { sessionsMatch($0.id, normalizedSessionID) }) {
            sessionSummary = cachedSession
        } else {
            let loaded = try? await sessionCatalog.loadSessions(
                limit: 1,
                preferredThreadID: normalizedSessionID,
                preferredCWD: nil,
                sessionIDs: [normalizedSessionID]
            )
            sessionSummary = loaded?.first
        }

        guard let session = sessionSummary else { return nil }

        let transcriptEntries: [AssistantTranscriptEntry]
        if sessionsMatch(transcriptSessionID, normalizedSessionID) {
            transcriptEntries = Array(transcript.suffix(transcriptLimit))
        } else if let cachedEntries = transcriptEntriesBySessionID[normalizedSessionID],
                  !cachedEntries.isEmpty {
            transcriptEntries = Array(cachedEntries.suffix(transcriptLimit))
        } else {
            transcriptEntries = await sessionCatalog.loadTranscript(
                sessionID: normalizedSessionID,
                limit: transcriptLimit
            )
        }

        let pendingPermission = pendingPermissionRequest.flatMap { request in
            sessionsMatch(request.sessionID, normalizedSessionID) ? request : nil
        }
        let isActiveSession = sessionsMatch(runtime.currentSessionID, normalizedSessionID)
            || sessionsMatch(selectedSessionID, normalizedSessionID)
        let imageDelivery = await latestRemoteImageDelivery(
            for: normalizedSessionID,
            sessionTitle: session.title
        )
        return AssistantRemoteSessionSnapshot(
            session: session,
            transcriptEntries: transcriptEntries,
            pendingPermissionRequest: pendingPermission,
            hudState: isActiveSession ? hudState : nil,
            hasActiveTurn: runtime.hasActiveTurn && isActiveSession,
            imageDelivery: imageDelivery
        )
    }

    private func latestRemoteImageDelivery(
        for sessionID: String,
        sessionTitle: String,
        limit: Int = 3
    ) async -> AssistantRemoteImageDelivery? {
        let timelineItems: [AssistantTimelineItem]
        if sessionsMatch(timelineSessionID, sessionID) {
            timelineItems = self.timelineItems
        } else if let cachedItems = timelineItemsBySessionID[sessionID], !cachedItems.isEmpty {
            timelineItems = cachedItems
        } else {
            let (loadedTimeline, _) = await loadSessionHistoryForAutomationSummary(sessionID: sessionID)
            timelineItems = loadedTimeline
        }

        let currentTurnItems: ArraySlice<AssistantTimelineItem>
        if let lastUserIndex = timelineItems.lastIndex(where: { $0.kind == .userMessage }) {
            let nextIndex = timelineItems.index(after: lastUserIndex)
            currentTurnItems = timelineItems[nextIndex...]
        } else {
            currentTurnItems = timelineItems[...]
        }

        let imageItem = currentTurnItems.first(where: { item in
            guard let images = item.imageAttachments, !images.isEmpty else {
                return false
            }
            switch item.kind {
            case .userMessage:
                return false
            case .assistantProgress, .assistantFinal, .activity, .permission, .plan, .system:
                return true
            }
        }) ?? timelineItems.reversed().first(where: { item in
            guard let images = item.imageAttachments, !images.isEmpty else {
                return false
            }
            switch item.kind {
            case .userMessage:
                return false
            case .assistantProgress, .assistantFinal, .activity, .permission, .plan, .system:
                return true
            }
        })

        guard let imageItem else {
            return nil
        }

        let imageData = Array((imageItem.imageAttachments ?? []).prefix(max(1, limit)))
        guard !imageData.isEmpty else { return nil }

        let caption = imageItem.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "Image from \(sessionTitle)"

        let attachments = imageData.enumerated().map { index, data in
            let mimeType = Self.remoteImageMimeType(for: data)
            let fileExtension = Self.remoteImageFileExtension(for: mimeType)
            let digest = String(MemoryIdentifier.stableHexDigest(data: data).prefix(16))
            return AssistantRemoteImageAttachment(
                id: digest,
                filename: "openassist-image-\(index + 1).\(fileExtension)",
                mimeType: mimeType,
                data: data
            )
        }

        let signatureSeed = attachments.map(\.id).joined(separator: "|")
        return AssistantRemoteImageDelivery(
            signature: MemoryIdentifier.stableHexDigest(for: signatureSeed),
            caption: caption,
            attachments: attachments
        )
    }

    private static func remoteImageMimeType(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if data.starts(with: Array("GIF8".utf8)) {
            return "image/gif"
        }
        if data.starts(with: Array("RIFF".utf8)), data.count >= 12 {
            let header = data.subdata(in: 8..<12)
            if header == Data("WEBP".utf8) {
                return "image/webp"
            }
        }
        return "image/png"
    }

    private static func remoteImageFileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg":
            return "jpg"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        default:
            return "png"
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
        if let mutation = historyMutationState, mutation.isPendingComposerEdit {
            lastStatusMessage = "Finish or cancel the current edit before starting a new thread."
            return
        }
        guard await ensureConversationCanStart() else { return }
        let interruptedActiveTurn = runtime.hasActiveTurn
        let targetProjectID = selectedProjectFilterID
        let requestedCWD = cwd ?? selectedProjectLinkedFolderPathIfUsable()
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
            let sessionID = try await runtime.startNewSession(cwd: requestedCWD, preferredModelID: selectedModelID)
            markPendingFreshSession(sessionID)
            recordOwnedSessionID(sessionID)
            if let targetProjectID {
                try? updateSessionProjectAssignment(sessionID: sessionID, projectID: targetProjectID)
            }
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

    /// Resumes an existing Codex thread for a scheduled job, or starts a fresh one if none exists.
    /// Returns the session ID that was activated, or nil on failure.
    func resumeOrStartScheduledJobSession(existingID: String?) async -> String? {
        syncRuntimeContext()
        do {
            if let existingID = existingID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                do {
                    try await runtime.resumeSession(existingID, cwd: nil, preferredModelID: selectedModelID)
                    return await activateScheduledJobSession(existingID, isFreshSession: false)
                } catch {
                    guard isMissingRolloutError(error) else {
                        throw error
                    }
                    CrashReporter.logWarning(
                        "Scheduled job session \(existingID) could not be resumed; starting a fresh session instead. error=\(error)"
                    )
                    let recoveredSessionID = try await recoverMissingRollout(for: existingID)
                    return await activateScheduledJobSession(recoveredSessionID, isFreshSession: true)
                }
            } else {
                let sessionID = try await runtime.startNewSession(cwd: nil, preferredModelID: selectedModelID)
                return await activateScheduledJobSession(sessionID, isFreshSession: true)
            }
        } catch {
            CrashReporter.logError("Scheduled job session setup failed: \(error)")
            return nil
        }
    }

    private func activateScheduledJobSession(
        _ sessionID: String,
        isFreshSession: Bool
    ) async -> String {
        let cachedTimeline = timelineItemsBySessionID[sessionID] ?? []
        let cachedTranscript = transcriptEntriesBySessionID[sessionID] ?? []
        let hasRenderableCachedTimeline = hasRenderableTimelineHistory(cachedTimeline)

        deferredSessionHistoryReloadTask?.cancel()
        deferredSessionHistoryReloadTask = nil

        switch Self.scheduledJobVisibleHistoryState(
            isFreshSession: isFreshSession,
            hasCachedTimeline: hasRenderableCachedTimeline,
            hasCachedTranscript: !cachedTranscript.isEmpty
        ) {
        case .cached:
            setVisibleTimeline(cachedTimeline, for: sessionID)
            setVisibleTranscript(cachedTranscript, for: sessionID)
            refreshEditableTurns(for: sessionID)
            isTransitioningSession = false
        case .loading:
            setVisibleHistoryLoadingState(for: sessionID)
            isTransitioningSession = true
        case .empty:
            setVisibleHistoryLoadingState(for: sessionID)
            isTransitioningSession = false
        }

        if isFreshSession {
            markPendingFreshSession(sessionID)
            recordOwnedSessionID(sessionID)
        }

        selectedSessionID = sessionID
        transcriptSessionID = sessionID
        timelineSessionID = sessionID
        clearActiveProposedPlanIfNeeded(for: sessionID)
        ensureSessionVisible(sessionID)
        if isFreshSession, settings.assistantMemoryEnabled {
            _ = try? threadMemoryService.ensureMemoryFile(for: sessionID)
        }
        refreshMemoryState(for: sessionID)
        await refreshSessions()
        ensureSessionVisible(sessionID)
        return sessionID
    }

    func openSession(_ session: AssistantSessionSummary) async {
        let normalizedSessionID = session.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }
        if let mutation = historyMutationState,
           mutation.isPendingComposerEdit,
           !sessionsMatch(mutation.sessionID, normalizedSessionID) {
            lastStatusMessage = "Finish or cancel the current edit before switching threads."
            return
        }

        deferredSessionHistoryReloadTask?.cancel()
        deferredSessionHistoryReloadTask = nil
        clearActiveProposedPlanIfNeeded(for: normalizedSessionID)

        let cachedTimeline = timelineItemsBySessionID[normalizedSessionID] ?? []
        let cachedTranscript = transcriptEntriesBySessionID[normalizedSessionID] ?? []
        let hasUsableCachedHistory = hasRenderableTimelineHistory(cachedTimeline)
        let hasVisibleSelectedSessionHistory = sessionsMatch(timelineSessionID, normalizedSessionID)
            && sessionsMatch(transcriptSessionID, normalizedSessionID)
            && !cachedRenderItems.isEmpty

        if sessionsMatch(selectedSessionID, normalizedSessionID),
           sessionsMatch(transcriptSessionID, normalizedSessionID),
           sessionsMatch(timelineSessionID, normalizedSessionID),
           !isTransitioningSession,
           (hasVisibleSelectedSessionHistory || hasUsableCachedHistory) {
            restoreSessionConfiguration(from: session)
            refreshMemoryState(for: normalizedSessionID)
            refreshEditableTurns(for: normalizedSessionID)
            return
        }

        let requestID = UUID()
        sessionLoadRequestID = requestID
        selectedSessionID = normalizedSessionID
        restoreSessionConfiguration(from: session)

        if hasUsableCachedHistory {
            setVisibleTimeline(cachedTimeline, for: normalizedSessionID)
            setVisibleTranscript(cachedTranscript, for: normalizedSessionID)
            refreshEditableTurns(for: normalizedSessionID)
            isTransitioningSession = false
        } else {
            setVisibleHistoryLoadingState(for: normalizedSessionID)
            isTransitioningSession = true

            let recentChunk = await sessionCatalog.loadRecentHistoryChunk(
                sessionID: normalizedSessionID,
                timelineLimit: min(
                    currentTimelineHistoryLimit(
                        for: normalizedSessionID,
                        minimum: Self.HistoryLoading.initialTimelineLimit
                    ),
                    Self.HistoryLoading.recentTimelineChunkLimit
                ),
                transcriptLimit: min(
                    currentTranscriptHistoryLimit(
                        for: normalizedSessionID,
                        minimum: Self.HistoryLoading.initialTranscriptLimit
                    ),
                    Self.HistoryLoading.recentTranscriptChunkLimit
                )
            )

            guard sessionLoadRequestID == requestID,
                  sessionsMatch(selectedSessionID, normalizedSessionID) else {
                return
            }

            if hasRenderableTimelineHistory(recentChunk.timeline) {
                setVisibleTimeline(recentChunk.timeline, for: normalizedSessionID)
                setVisibleTranscript(recentChunk.transcript, for: normalizedSessionID)
                timelineItemsBySessionID[normalizedSessionID] = recentChunk.timeline
                transcriptEntriesBySessionID[normalizedSessionID] = recentChunk.transcript
                canLoadMoreHistoryBySessionID[normalizedSessionID] = recentChunk.hasMore
                refreshEditableTurns(for: normalizedSessionID)
                isTransitioningSession = false
                scheduleSelectedSessionHistoryReload(force: true)
                refreshMemoryState(for: normalizedSessionID)
                return
            }
        }

        let loadedHistory = await loadSessionHistorySlice(
            sessionID: normalizedSessionID,
            timelineLimit: currentTimelineHistoryLimit(
                for: normalizedSessionID,
                minimum: Self.HistoryLoading.initialTimelineLimit
            ),
            transcriptLimit: currentTranscriptHistoryLimit(
                for: normalizedSessionID,
                minimum: Self.HistoryLoading.initialTranscriptLimit
            )
        )

        guard sessionLoadRequestID == requestID,
              sessionsMatch(selectedSessionID, normalizedSessionID) else {
            return
        }

        let mergedTimeline = mergeTimelineHistory(
            loadedHistory.timeline,
            with: timelineItemsBySessionID[normalizedSessionID] ?? []
        )
        let mergedTranscript = mergeTranscriptHistory(
            loadedHistory.transcript,
            with: transcriptEntriesBySessionID[normalizedSessionID] ?? []
        )

        setVisibleTimeline(mergedTimeline, for: normalizedSessionID)
        setVisibleTranscript(mergedTranscript, for: normalizedSessionID)
        refreshEditableTurns(for: normalizedSessionID)
        refreshMemoryState(for: normalizedSessionID)
        isTransitioningSession = false
    }

    func sendPrompt(_ prompt: String) async {
        await sendPrompt(prompt, automationJob: nil)
    }

    func sendPrompt(_ prompt: String, automationJob: ScheduledJob? = nil) async {
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
        hudState = AssistantHUDState(
            phase: .thinking,
            title: "Thinking",
            detail: "Sending your message"
        )
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
                let builtMemory: AssistantBuiltMemoryContext
                if let automationJob {
                    builtMemory = try automationMemoryService.prepareAutomationTurnContext(
                        job: automationJob,
                        threadID: sessionID,
                        prompt: trimmed,
                        cwd: resolvedSessionCWD(for: sessionID),
                        summaryMaxChars: settings.assistantMemorySummaryMaxChars
                    )
                } else {
                    let projectTurnContext = try projectMemoryService.turnContext(
                        forThreadID: sessionID,
                        fallbackCWD: resolvedSessionCWD(for: sessionID)
                    )
                    builtMemory = try memoryRetrievalService.prepareTurnContext(
                        threadID: sessionID,
                        prompt: trimmed,
                        cwd: resolvedSessionCWD(for: sessionID),
                        summaryMaxChars: settings.assistantMemorySummaryMaxChars
                        ,
                        longTermScope: projectTurnContext?.scope,
                        projectContextBlock: projectTurnContext?.projectContextBlock,
                        statusBase: projectTurnContext == nil ? "Using session memory" : "Using thread + project memory"
                    )
                }
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
            commitPendingHistoryEditIfNeeded(for: sessionID)
            pendingResumeContextSessionIDs.remove(sessionID)
            pendingResumeContextSnapshotsBySessionID.removeValue(forKey: sessionID)
            ensureSessionVisible(sessionID)
        } catch {
            hudState = AssistantHUDState(
                phase: .failed,
                title: "Send failed",
                detail: error.localizedDescription
            )
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

    func loadSessionHistoryForAutomationSummary(sessionID: String) async -> ([AssistantTimelineItem], [AssistantTranscriptEntry]) {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return ([], []) }
        let timeline = await sessionCatalog.loadMergedTimeline(sessionID: normalizedSessionID, limit: 400)
        let transcript = await sessionCatalog.loadTranscript(sessionID: normalizedSessionID, limit: 200)
        return (timeline, transcript)
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

    func undoUserMessage(anchorID: String) async {
        let normalizedAnchorID = anchorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAnchorID.isEmpty else { return }
        guard let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            lastStatusMessage = "Open the thread first, then try Undo."
            return
        }
        guard historyMutationState == nil else {
            lastStatusMessage = "Finish or cancel the current history change before starting another one."
            return
        }
        guard !runtime.hasActiveTurn else {
            lastStatusMessage = "Wait for the current Codex task to finish before undoing a message."
            return
        }

        historyMutationState = AssistantHistoryMutationState(
            kind: .undo,
            sessionID: sessionID,
            anchorID: normalizedAnchorID,
            isPendingComposerEdit: false,
            rewriteBackup: nil,
            previousDraft: "",
            previousAttachments: [],
            restoredPrompt: "",
            restoredAttachments: [],
            removedAnchorIDs: [],
            retainedAnchorIDs: [],
            rollbackSnapshot: nil
        )

        var rewriteBackup: CodexRewriteBackup?
        var rollbackSnapshot: AssistantHistoryRollbackSnapshot?
        do {
            let outcome = try threadRewriteService.truncateBeforeTurn(
                sessionID: sessionID,
                turnAnchorID: normalizedAnchorID
            )
            rewriteBackup = outcome.backup
            try await runtime.resumeSessionSilently(
                sessionID,
                cwd: resolvedSessionCWD(for: sessionID),
                preferredModelID: selectedModelID
            )

            rollbackSnapshot = try await applyHistoryRewriteRollback(
                for: sessionID,
                retainedAnchorIDs: outcome.retainedTurns.map(\.anchorID),
                removedAnchorIDs: outcome.removedTurns.map(\.anchorID),
                captureSnapshot: true,
                keepRemovedCheckpoints: false
            )

            await reloadAfterHistoryRewrite(for: sessionID)
            await reconcileProjectDigest(for: sessionID)
            threadRewriteService.deleteBackup(outcome.backup)
            historyMutationState = nil
            refreshEditableTurns(for: sessionID)
            lastStatusMessage = "Undid that message and everything after it."
        } catch {
            if let rewriteBackup {
                try? threadRewriteService.restoreBackup(rewriteBackup)
                try? await restoreHistoryRollback(for: sessionID, snapshot: rollbackSnapshot)
                await reloadAfterHistoryRewrite(for: sessionID)
                await reconcileProjectDigest(for: sessionID)
                threadRewriteService.deleteBackup(rewriteBackup)
            }
            historyMutationState = nil
            refreshEditableTurns(for: sessionID)
            lastStatusMessage = error.localizedDescription
        }
    }

    func beginEditLastUserMessage(anchorID: String) async {
        let normalizedAnchorID = anchorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAnchorID.isEmpty else { return }
        guard let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            lastStatusMessage = "Open the thread first, then try Edit."
            return
        }
        guard historyMutationState == nil else {
            lastStatusMessage = "Finish or cancel the current history change before starting another one."
            return
        }
        guard !runtime.hasActiveTurn else {
            lastStatusMessage = "Wait for the current Codex task to finish before editing a message."
            return
        }

        let previousDraft = promptDraft
        let previousAttachments = attachments

        historyMutationState = AssistantHistoryMutationState(
            kind: .edit,
            sessionID: sessionID,
            anchorID: normalizedAnchorID,
            isPendingComposerEdit: false,
            rewriteBackup: nil,
            previousDraft: previousDraft,
            previousAttachments: previousAttachments,
            restoredPrompt: "",
            restoredAttachments: [],
            removedAnchorIDs: [],
            retainedAnchorIDs: [],
            rollbackSnapshot: nil
        )

        var rewriteBackup: CodexRewriteBackup?
        var rollbackSnapshot: AssistantHistoryRollbackSnapshot?
        do {
            let outcome = try threadRewriteService.beginEditLastTurn(
                sessionID: sessionID,
                turnAnchorID: normalizedAnchorID
            )
            rewriteBackup = outcome.backup
            try await runtime.resumeSessionSilently(
                sessionID,
                cwd: resolvedSessionCWD(for: sessionID),
                preferredModelID: selectedModelID
            )

            rollbackSnapshot = try await applyHistoryRewriteRollback(
                for: sessionID,
                retainedAnchorIDs: outcome.retainedTurns.map(\.anchorID),
                removedAnchorIDs: outcome.removedTurns.map(\.anchorID),
                captureSnapshot: true,
                keepRemovedCheckpoints: true
            )

            let restoredPrompt = outcome.editedTurn?.text ?? ""
            let restoredAttachments = (outcome.editedTurn?.imageAttachments ?? []).map(assistantAttachment(from:))

            promptDraft = restoredPrompt
            attachments = restoredAttachments

            historyMutationState = AssistantHistoryMutationState(
                kind: .edit,
                sessionID: sessionID,
                anchorID: normalizedAnchorID,
                isPendingComposerEdit: true,
                rewriteBackup: outcome.backup,
                previousDraft: previousDraft,
                previousAttachments: previousAttachments,
                restoredPrompt: restoredPrompt,
                restoredAttachments: restoredAttachments,
                removedAnchorIDs: outcome.removedTurns.map(\.anchorID),
                retainedAnchorIDs: outcome.retainedTurns.map(\.anchorID),
                rollbackSnapshot: rollbackSnapshot
            )

            await reloadAfterHistoryRewrite(for: sessionID)
            await reconcileProjectDigest(for: sessionID)
            lastStatusMessage = "Editing your last message. Update it, then press Send."
        } catch {
            if let rewriteBackup {
                try? threadRewriteService.restoreBackup(rewriteBackup)
                try? await restoreHistoryRollback(for: sessionID, snapshot: rollbackSnapshot)
                await reloadAfterHistoryRewrite(for: sessionID)
                await reconcileProjectDigest(for: sessionID)
                threadRewriteService.deleteBackup(rewriteBackup)
            }
            promptDraft = previousDraft
            attachments = previousAttachments
            historyMutationState = nil
            lastStatusMessage = error.localizedDescription
        }
    }

    func cancelPendingHistoryEdit() async {
        guard let mutation = historyMutationState,
              mutation.kind == .edit,
              mutation.isPendingComposerEdit,
              let backup = mutation.rewriteBackup else {
            return
        }

        do {
            _ = try threadRewriteService.cancelPendingEdit(sessionID: mutation.sessionID)
            try await restoreHistoryRollback(
                for: mutation.sessionID,
                snapshot: mutation.rollbackSnapshot
            )
            promptDraft = mutation.previousDraft
            attachments = mutation.previousAttachments
            historyMutationState = nil
            await reloadAfterHistoryRewrite(for: mutation.sessionID)
            await reconcileProjectDigest(for: mutation.sessionID)
            threadRewriteService.deleteBackup(backup)
            lastStatusMessage = "Canceled the edit and restored the original message."
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func deleteSession(_ sessionID: String) async {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }
        if let mutation = historyMutationState,
           sessionsMatch(mutation.sessionID, normalizedSessionID) {
            if mutation.kind == .edit {
                threadRewriteService.discardPendingEditBackup(sessionID: normalizedSessionID)
            }
            historyMutationState = nil
        }

        do {
            if runtime.currentSessionID == normalizedSessionID {
                await runtime.stop()
            }

            let previousProjectID = projectStore.context(forThreadID: normalizedSessionID)?.project.id
            let deleted = try await sessionCatalog.deleteSession(sessionID: normalizedSessionID)
            try? threadMemoryService.clearMemory(for: normalizedSessionID)
            try? memorySuggestionService.clearSuggestions(for: normalizedSessionID)
            _ = try? projectStore.removeThreadAssignment(normalizedSessionID)
            if let previousProjectID {
                try? projectStore.removeThreadState(normalizedSessionID, from: previousProjectID)
                _ = try? projectMemoryService.rebuildProjectSummary(for: previousProjectID, sessionSummaries: sessions)
            }

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

            pendingTimelineCacheSaveWorkItems[normalizedSessionID]?.cancel()
            pendingTimelineCacheSaveWorkItems.removeValue(forKey: normalizedSessionID)
            pendingResumeContextSnapshotsBySessionID.removeValue(forKey: normalizedSessionID)
            transcriptEntriesBySessionID.removeValue(forKey: normalizedSessionID)
            timelineItemsBySessionID.removeValue(forKey: normalizedSessionID)
            requestedTimelineHistoryLimitBySessionID.removeValue(forKey: normalizedSessionID)
            requestedTranscriptHistoryLimitBySessionID.removeValue(forKey: normalizedSessionID)
            canLoadMoreHistoryBySessionID.removeValue(forKey: normalizedSessionID)
            editableTurnsBySessionID.removeValue(forKey: normalizedSessionID)
            sessions.removeAll { $0.id == normalizedSessionID }
            reloadProjectsFromStore()
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
        if let mutation = historyMutationState,
           mutation.kind == .edit {
            threadRewriteService.discardPendingEditBackup(sessionID: mutation.sessionID)
        }
        historyMutationState = nil

        do {
            if let currentSessionID = runtime.currentSessionID,
               ownedSessionIDs.contains(where: { $0.caseInsensitiveCompare(currentSessionID) == .orderedSame }) {
                await runtime.stop()
            }

            let sessionProjectPairs = ownedSessionIDs.map { sessionID in
                (sessionID, projectStore.context(forThreadID: sessionID)?.project.id)
            }
            let affectedProjectIDs = Set(sessionProjectPairs.compactMap(\.1))
            let deletedCount = try await sessionCatalog.deleteSessions(sessionIDs: ownedSessionIDs)
            for (sessionID, projectID) in sessionProjectPairs {
                try? threadMemoryService.clearMemory(for: sessionID)
                try? memorySuggestionService.clearSuggestions(for: sessionID)
                _ = try? projectStore.removeThreadAssignment(sessionID)
                if let projectID {
                    try? projectStore.removeThreadState(sessionID, from: projectID)
                }
            }
            for projectID in affectedProjectIDs {
                _ = try? projectMemoryService.rebuildProjectSummary(for: projectID, sessionSummaries: sessions)
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
            editableTurnsBySessionID = [:]
            reloadProjectsFromStore()
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

    func inspectMemory(for session: AssistantSessionSummary) {
        do {
            memoryInspectorSnapshot = try memoryInspectorService.snapshot(for: session)
            activeMemoryInspectorTarget = .thread(session.id)
            showMemoryInspector = true
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func inspectMemory(for project: AssistantProject) {
        do {
            memoryInspectorSnapshot = try memoryInspectorService.snapshot(for: project, sessions: sessions)
            activeMemoryInspectorTarget = .project(project.id)
            showMemoryInspector = true
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func dismissMemoryInspector() {
        showMemoryInspector = false
        activeMemoryInspectorTarget = nil
        memoryInspectorSnapshot = nil
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
            let scope = resolvedAssistantMemoryScope(for: sessionID)
            let created = try memorySuggestionService.createManualSuggestions(
                from: assistantText,
                threadID: sessionID,
                scope: scope,
                metadata: projectMemorySuggestionMetadata(for: sessionID)
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
            let scope = resolvedAssistantMemoryScope(for: sessionID)
            let created = try memorySuggestionService.createFailureSuggestions(
                from: assistantText,
                threadID: sessionID,
                scope: scope,
                metadata: projectMemorySuggestionMetadata(for: sessionID)
            )
            try handleCreatedSuggestions(created, sessionID: sessionID, directSaveWhenReviewDisabled: false)
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func explainSelectedText(
        _ selectedText: String,
        in parentMessageText: String,
        question: String? = nil
    ) async {
        let normalizedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSelection.isEmpty else {
            lastStatusMessage = "Select some text first."
            return
        }
        let normalizedParentMessage = parentMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedParentMessage.isEmpty else {
            lastStatusMessage = "Could not find the full message for this selection."
            return
        }

        guard let sessionID = selectedSessionID ?? runtime.currentSessionID else {
            lastStatusMessage = "Open an Open Assist session first."
            return
        }

        let explanationID = "selection-insight-\(UUID().uuidString)"
        let createdAt = Date()
        let normalizedQuestion = question?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty

        appendTimelineItem(
            selectionInsightTimelineItem(
                id: explanationID,
                sessionID: sessionID,
                selectedText: normalizedSelection,
                question: normalizedQuestion,
                body: normalizedQuestion == nil
                    ? "Explaining the selected text..."
                    : "Thinking about your question...",
                createdAt: createdAt,
                updatedAt: createdAt,
                isStreaming: true,
                emphasis: false
            )
        )

        let result = await MemoryEntryExplanationService.shared.explainSelectedText(
            normalizedSelection,
            parentMessageText: normalizedParentMessage,
            question: normalizedQuestion,
            onPartialText: { [weak self] partialText in
                Task { @MainActor in
                    guard let self else { return }
                    let normalizedPartial = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalizedPartial.isEmpty else { return }

                    self.appendTimelineItem(
                        self.selectionInsightTimelineItem(
                            id: explanationID,
                            sessionID: sessionID,
                            selectedText: normalizedSelection,
                            question: normalizedQuestion,
                            body: normalizedPartial,
                            createdAt: createdAt,
                            updatedAt: Date(),
                            isStreaming: true,
                            emphasis: false
                        )
                    )
                }
            }
        )

        switch result {
        case .success(let explanation):
            appendTimelineItem(
                selectionInsightTimelineItem(
                    id: explanationID,
                    sessionID: sessionID,
                    selectedText: normalizedSelection,
                    question: normalizedQuestion,
                    body: explanation,
                    createdAt: createdAt,
                    updatedAt: Date(),
                    isStreaming: false,
                    emphasis: false
                )
            )
            lastStatusMessage = normalizedQuestion == nil
                ? "Added an explanation for the selected text."
                : "Answered your question about the selected text."

        case .failure(let detail):
            appendTimelineItem(
                selectionInsightTimelineItem(
                    id: explanationID,
                    sessionID: sessionID,
                    selectedText: normalizedSelection,
                    question: normalizedQuestion,
                    body: "Could not explain the selected text.\n\n\(detail)",
                    createdAt: createdAt,
                    updatedAt: Date(),
                    isStreaming: false,
                    emphasis: true
                )
            )
            lastStatusMessage = detail
        }
    }

    func acceptMemorySuggestion(_ suggestion: AssistantMemorySuggestion) {
        do {
            try memorySuggestionService.acceptSuggestion(id: suggestion.id)
            refreshMemoryState(for: suggestion.threadID)
            updateMemoryStatus(base: "Saved lesson to long-term assistant memory")
            refreshMemoryInspectorIfNeeded(
                affectedThreadIDs: [suggestion.threadID],
                affectedProjectIDs: [suggestion.metadata["project_id"]].compactMap { $0 }
            )
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func ignoreMemorySuggestion(_ suggestion: AssistantMemorySuggestion) {
        do {
            try memorySuggestionService.ignoreSuggestion(id: suggestion.id)
            refreshMemoryState(for: suggestion.threadID)
            updateMemoryStatus(base: "Ignored that memory suggestion")
            refreshMemoryInspectorIfNeeded(
                affectedThreadIDs: [suggestion.threadID],
                affectedProjectIDs: [suggestion.metadata["project_id"]].compactMap { $0 }
            )
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

    func showTransientHUDState(_ state: AssistantHUDState) {
        hudState = state
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

    var assistantFallbackVoiceOptions: [AssistantSpeechVoiceOption] {
        assistantSpeechPlaybackService.availableMacOSVoices()
    }

    var assistantVoiceLegacyCleanupAvailable: Bool {
        assistantLegacyTADACleanupSupport.hasLegacyArtifacts()
    }

    var assistantSelectedHumeVoiceSummary: String {
        if let selectedVoice = assistantHumeVoiceOptions.first(where: { $0.id == settings.assistantHumeVoiceID }) {
            return selectedVoice.displayLabel
        }
        if let selectedVoiceName = settings.assistantHumeVoiceName.nonEmpty {
            return "\(selectedVoiceName) (\(settings.assistantHumeVoiceSource.displayName))"
        }
        return "No Hume voice selected"
    }

    var canStartLiveVoiceSession: Bool {
        canStartConversation
    }

    var isLiveVoiceSessionActive: Bool {
        liveVoiceSessionSnapshot.isActive
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

        guard !isPendingFreshSession(sessionID) else {
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

        var errorDict: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        appleScript?.executeAndReturnError(&errorDict)
        if errorDict != nil {
            lastStatusMessage = "Could not open Terminal automatically. Run this command yourself: \(command)"
        }
    }

    func refreshAssistantVoiceHealth() async {
        isRefreshingAssistantVoiceHealth = true
        assistantVoiceHealth = await assistantSpeechPlaybackService.healthStatus()
        isRefreshingAssistantVoiceHealth = false
    }

    func refreshAssistantHumeVoices() async {
        guard settings.assistantHumeAPIKey.nonEmpty != nil else {
            assistantHumeVoiceOptions = []
            assistantVoiceStatusMessage = "Add your Hume API key first, then refresh voices."
            return
        }

        isRefreshingAssistantHumeVoices = true
        defer { isRefreshingAssistantHumeVoices = false }

        do {
            let voices = try await humeVoiceCatalogService.listVoices(source: settings.assistantHumeVoiceSource)
            assistantHumeVoiceOptions = voices
            if let selectedVoice = voices.first(where: { $0.id == settings.assistantHumeVoiceID }) {
                settings.assistantHumeVoiceName = selectedVoice.name
            } else if let firstVoice = voices.first, settings.assistantHumeVoiceID.isEmpty {
                settings.assistantHumeVoiceID = firstVoice.id
                settings.assistantHumeVoiceName = firstVoice.name
            }
            assistantVoiceStatusMessage = voices.isEmpty
                ? "No Hume voices were available for the selected source."
                : "Loaded \(voices.count) Hume voice\(voices.count == 1 ? "" : "s")."
        } catch {
            assistantHumeVoiceOptions = []
            assistantVoiceStatusMessage = error.localizedDescription
        }
    }

    func testAssistantVoiceOutput() async {
        isTestingAssistantVoice = true
        defer { isTestingAssistantVoice = false }

        do {
            try await assistantSpeechPlaybackService.speak(
                text: "This is an Open Assist voice test.",
                    request: assistantSpeechRequest(
                        text: "This is an Open Assist voice test.",
                        sessionID: selectedSessionID,
                        turnID: nil,
                        timelineItemID: "assistant-voice-test"
                    )
                )
            assistantVoiceStatusMessage = "Played the assistant voice test."
        } catch {
            assistantVoiceStatusMessage = error.localizedDescription
        }

        await refreshAssistantVoiceHealth()
    }

    func stopAssistantVoicePlayback() {
        assistantSpeechPlaybackService.stopCurrentPlayback()
        assistantVoiceStatusMessage = "Assistant speech stopped."
    }

    func removeLegacyAssistantVoiceData() async {
        isRemovingAssistantVoiceInstallation = true
        defer { isRemovingAssistantVoiceInstallation = false }

        do {
            assistantSpeechPlaybackService.stopCurrentPlayback()
            if liveVoiceSessionSnapshot.isActive {
                onEndLiveVoiceSession?()
            }
            await humeConversationService.endConversation()
            assistantVoiceStatusMessage = try assistantLegacyTADACleanupSupport.removeLegacyArtifacts()
        } catch {
            assistantVoiceStatusMessage = error.localizedDescription
        }

        await refreshAssistantVoiceHealth()
    }

    func startLiveVoiceSession(surface: AssistantLiveVoiceSessionSurface = .mainWindow) {
        onStartLiveVoiceSession?(surface)
    }

    func endLiveVoiceSession() {
        onEndLiveVoiceSession?()
    }

    func stopSpeakingAndResumeListening() {
        onStopLiveVoiceSpeaking?()
    }

    func selectAssistantHumeVoice(_ voice: AssistantHumeVoiceOption) {
        settings.assistantHumeVoiceID = voice.id
        settings.assistantHumeVoiceName = voice.name
        settings.assistantHumeVoiceSource = voice.source
        assistantVoiceStatusMessage = "Selected \(voice.displayLabel) for Hume voice."
    }

    func replayAssistantVoice(text: String, sessionID: String?, turnID: String?, timelineItemID: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.assistantSpeechPlaybackService.speak(
                    text: text,
                    request: self.assistantSpeechRequest(
                        text: text,
                        sessionID: sessionID,
                        turnID: turnID,
                        timelineItemID: timelineItemID
                    )
                )
                self.assistantVoiceStatusMessage = "Played the assistant reply again."
            } catch {
                self.assistantVoiceStatusMessage = error.localizedDescription
            }
        }
    }

    private func ensureSessionVisible(_ sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty else { return }
        if let existingIndex = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[existingIndex].status = Self.normalizedFreshSessionStatus(
                currentStatus: sessions[existingIndex].status,
                hasConversationContent: sessions[existingIndex].hasConversationContent,
                hasActiveTurn: runtime.hasActiveTurn
            )
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
            status: Self.normalizedFreshSessionStatus(
                currentStatus: .active,
                hasConversationContent: lastSubmittedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil,
                hasActiveTurn: runtime.hasActiveTurn
            ),
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

    static func shouldSkipPendingFreshSessionResume(
        _ sessionID: String?,
        pendingSessionIDs: Set<String>
    ) -> Bool {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return false
        }
        let normalizedPendingSessionIDs = Set(
            pendingSessionIDs.compactMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty?.lowercased()
            }
        )
        return normalizedPendingSessionIDs.contains(sessionID.lowercased())
    }

    static func pendingFreshSessionInsertionOrder(
        loadedSessionIDs: [String],
        existingSessionIDs: [String],
        preferredSessionIDs: [String],
        pendingSessionIDs: Set<String>
    ) -> [String] {
        let normalizedPendingSessionIDs = Set(
            pendingSessionIDs.compactMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty?.lowercased()
            }
        )
        let loaded = Set(
            loadedSessionIDs.compactMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty?.lowercased()
            }
        )

        var ordered: [String] = []
        var seen = loaded

        for sessionID in preferredSessionIDs + existingSessionIDs {
            let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSessionID.isEmpty else { continue }
            let normalizedSessionID = trimmedSessionID.lowercased()
            guard normalizedPendingSessionIDs.contains(normalizedSessionID),
                  seen.insert(normalizedSessionID).inserted else {
                continue
            }
            ordered.append(trimmedSessionID)
        }

        return ordered
    }

    static func normalizedFreshSessionStatus(
        currentStatus: AssistantSessionStatus,
        hasConversationContent: Bool,
        hasActiveTurn: Bool
    ) -> AssistantSessionStatus {
        guard currentStatus == .active,
              !hasConversationContent,
              !hasActiveTurn else {
            return currentStatus
        }

        return .idle
    }

    enum ScheduledJobVisibleHistoryState: Equatable {
        case cached
        case loading
        case empty
    }

    static func scheduledJobVisibleHistoryState(
        isFreshSession: Bool,
        hasCachedTimeline: Bool,
        hasCachedTranscript: Bool
    ) -> ScheduledJobVisibleHistoryState {
        if hasCachedTimeline {
            return .cached
        }

        if hasCachedTranscript {
            return .loading
        }

        return isFreshSession ? .empty : .loading
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
        clearPendingFreshSession(sessionID)
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

    private func applyTranscriptMutation(_ mutation: AssistantTranscriptMutation) {
        switch mutation {
        case .reset(let sessionID):
            guard let normalizedSessionID = sessionID?.nonEmpty else {
                if selectedSessionID == nil {
                    setVisibleTranscript([], for: nil)
                }
                return
            }

            transcriptEntriesBySessionID[normalizedSessionID] = []
            if sessionsMatch(transcriptSessionID, normalizedSessionID) || sessionsMatch(selectedSessionID, normalizedSessionID) {
                setVisibleTranscript([], for: normalizedSessionID)
            }

        case .upsert(let entry, let sessionID):
            appendTranscriptEntry(entry, sessionID: sessionID)

        case .appendDelta(let id, let sessionID, let role, let delta, let createdAt, let emphasis, let isStreaming):
            guard let normalizedDelta = delta.nonEmpty else { return }
            let targetSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? selectedSessionID

            guard sessionsMatch(targetSessionID, selectedSessionID) || transcriptSessionID == nil else {
                appendTranscriptDeltaToCache(
                    id: id,
                    sessionID: targetSessionID,
                    role: role,
                    delta: normalizedDelta,
                    createdAt: createdAt,
                    emphasis: emphasis,
                    isStreaming: isStreaming
                )
                return
            }

            if transcriptSessionID == nil {
                transcriptSessionID = targetSessionID
            }

            if let existingIndex = transcript.lastIndex(where: { $0.id == id }) {
                let existingEntry = transcript[existingIndex]
                transcript[existingIndex] = AssistantTranscriptEntry(
                    id: existingEntry.id,
                    role: existingEntry.role,
                    text: existingEntry.text + normalizedDelta,
                    createdAt: existingEntry.createdAt,
                    emphasis: existingEntry.emphasis || emphasis,
                    isStreaming: isStreaming
                )
            } else {
                transcript.append(
                    AssistantTranscriptEntry(
                        id: id,
                        role: role,
                        text: normalizedDelta,
                        createdAt: createdAt,
                        emphasis: emphasis,
                        isStreaming: isStreaming
                    )
                )
            }

            if let targetSessionID {
                transcriptEntriesBySessionID[targetSessionID] = transcript
            }

            if let latestEntry = transcript.last {
                updateVisibleSessionPreview(with: latestEntry, sessionID: targetSessionID)
            }
        }
    }

    private func appendTimelineItem(_ item: AssistantTimelineItem) {
        applyTimelineMutation(.upsert(item))
    }

    private func selectionInsightTimelineItem(
        id: String,
        sessionID: String,
        selectedText: String,
        question: String?,
        body: String,
        createdAt: Date,
        updatedAt: Date,
        isStreaming: Bool,
        emphasis: Bool
    ) -> AssistantTimelineItem {
        let selectionPreview = Self.normalizedResumeContextSnippet(selectedText, limit: 180)
        let title = question == nil ? "### Selection Insight" : "### Selection Q&A"

        var sections = [title]
        if !selectionPreview.isEmpty {
            sections.append("> \(selectionPreview)")
        }
        if let question {
            sections.append("Question: \(question)")
        }
        sections.append(body.trimmingCharacters(in: .whitespacesAndNewlines))

        return AssistantTimelineItem(
            id: id,
            sessionID: sessionID,
            turnID: nil,
            kind: .system,
            createdAt: createdAt,
            updatedAt: updatedAt,
            text: sections.joined(separator: "\n\n"),
            isStreaming: isStreaming,
            emphasis: emphasis,
            activity: nil,
            permissionRequest: nil,
            planText: nil,
            planEntries: nil,
            imageAttachments: nil,
            source: .runtime
        )
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
            persistTimelineCacheIfNeeded(sessionID: normalizedSessionID, items: [], force: true)

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
            persistTimelineCacheIfNeeded(sessionID: targetSessionID, items: items, force: true)

        case .upsert(let item):
            let targetSessionID = item.sessionID?.nonEmpty
                ?? runtime.currentSessionID?.nonEmpty
                ?? selectedSessionID?.nonEmpty

            let previousVisibleItems = timelineItems
            var items = targetSessionID.flatMap { timelineItemsBySessionID[$0] }
                ?? (sessionsMatch(timelineSessionID, targetSessionID) ? timelineItems : [])
            let existingItem = items.first(where: { $0.id == item.id })

            if let existingIndex = items.firstIndex(where: { $0.id == item.id }) {
                items[existingIndex] = item
            } else {
                items.append(item)
            }

            sortTimelineItems(&items)

            if let targetSessionID {
                timelineItemsBySessionID[targetSessionID] = items
                if sessionsMatch(selectedSessionID, targetSessionID) || sessionsMatch(timelineSessionID, targetSessionID) {
                    if !applyVisibleTimelineTailUpdateIfPossible(
                        previousItems: previousVisibleItems,
                        updatedItems: items,
                        updatedItem: item,
                        sessionID: targetSessionID
                    ) {
                        setVisibleTimeline(items, for: targetSessionID)
                    }
                }
                if item.cacheable || existingItem?.cacheable == true {
                    persistTimelineCacheIfNeeded(
                        sessionID: targetSessionID,
                        items: items,
                        force: shouldForceTimelineCachePersistence(for: item)
                    )
                }
            } else {
                timelineItems = items
                rebuildRenderItemsCache()
            }

            maybeSpeakAssistantFinal(item, existingItem: existingItem)

        case .appendTextDelta(
            let id,
            let sessionID,
            let turnID,
            let kind,
            let delta,
            let createdAt,
            let updatedAt,
            let isStreaming,
            let emphasis,
            let source
        ):
            guard let normalizedDelta = delta.nonEmpty else { return }
            let targetSessionID = sessionID?.nonEmpty
                ?? runtime.currentSessionID?.nonEmpty
                ?? selectedSessionID?.nonEmpty

            let previousVisibleItems = timelineItems
            var items = targetSessionID.flatMap { timelineItemsBySessionID[$0] }
                ?? (sessionsMatch(timelineSessionID, targetSessionID) ? timelineItems : [])

            if let existingIndex = items.firstIndex(where: { $0.id == id }) {
                items[existingIndex].updatedAt = updatedAt
                items[existingIndex].isStreaming = isStreaming
                items[existingIndex].emphasis = items[existingIndex].emphasis || emphasis

                switch kind {
                case .plan:
                    let previousText = items[existingIndex].planText ?? ""
                    items[existingIndex].planText = previousText + normalizedDelta
                default:
                    items[existingIndex].text = (items[existingIndex].text ?? "") + normalizedDelta
                }
            } else {
                let newItem: AssistantTimelineItem
                switch kind {
                case .assistantProgress:
                    newItem = .assistantProgress(
                        id: id,
                        sessionID: targetSessionID,
                        turnID: turnID,
                        text: normalizedDelta,
                        createdAt: createdAt,
                        updatedAt: updatedAt,
                        isStreaming: isStreaming,
                        source: source
                    )
                case .assistantFinal:
                    newItem = .assistantFinal(
                        id: id,
                        sessionID: targetSessionID,
                        turnID: turnID,
                        text: normalizedDelta,
                        createdAt: createdAt,
                        updatedAt: updatedAt,
                        isStreaming: isStreaming,
                        source: source
                    )
                case .plan:
                    newItem = .plan(
                        id: id,
                        sessionID: targetSessionID,
                        turnID: turnID,
                        text: normalizedDelta,
                        entries: nil,
                        createdAt: createdAt,
                        updatedAt: updatedAt,
                        isStreaming: isStreaming,
                        source: source
                    )
                case .system:
                    newItem = .system(
                        id: id,
                        sessionID: targetSessionID,
                        turnID: turnID,
                        text: normalizedDelta,
                        createdAt: createdAt,
                        emphasis: emphasis,
                        source: source
                    )
                case .userMessage:
                    newItem = .userMessage(
                        id: id,
                        sessionID: targetSessionID,
                        turnID: turnID,
                        text: normalizedDelta,
                        createdAt: createdAt,
                        source: source
                    )
                case .activity, .permission:
                    return
                }

                items.append(newItem)
            }

            sortTimelineItems(&items)

            if let targetSessionID {
                timelineItemsBySessionID[targetSessionID] = items
                let updatedItem = items.first(where: { $0.id == id })
                if let updatedItem,
                   sessionsMatch(selectedSessionID, targetSessionID) || sessionsMatch(timelineSessionID, targetSessionID) {
                    if !applyVisibleTimelineTailUpdateIfPossible(
                        previousItems: previousVisibleItems,
                        updatedItems: items,
                        updatedItem: updatedItem,
                        sessionID: targetSessionID
                    ) {
                        setVisibleTimeline(items, for: targetSessionID)
                    }
                }
            } else {
                timelineItems = items
                rebuildRenderItemsCache()
            }
        }
    }

    private func maybeSpeakAssistantFinal(_ item: AssistantTimelineItem, existingItem: AssistantTimelineItem?) {
        guard AssistantSpeechTrigger.shouldAutoSpeak(
            incoming: item,
            existingItem: existingItem,
            featureEnabled: settings.assistantVoiceOutputEnabled || liveVoiceSessionSnapshot.isActive,
            lastSpokenTimelineItemID: lastSpokenAssistantTimelineItemID
        ) else {
            return
        }

        let speechText = AssistantVisibleTextSanitizer.clean(item.text) ?? item.text ?? ""
        lastSpokenAssistantTimelineItemID = item.id
        lastSpokenAssistantTurnID = item.turnID

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.assistantSpeechPlaybackService.speak(
                    text: speechText,
                    request: self.assistantSpeechRequest(
                        text: speechText,
                        sessionID: item.sessionID,
                        turnID: item.turnID,
                        timelineItemID: item.id
                    )
                )
            } catch {
                self.assistantVoiceStatusMessage = error.localizedDescription
            }
        }
    }

    private func assistantSpeechRequest(
        text: String,
        sessionID: String?,
        turnID: String?,
        timelineItemID: String?
    ) -> AssistantSpeechRequest {
        AssistantSpeechRequest(
            text: text,
            sessionID: sessionID,
            turnID: turnID,
            timelineItemID: timelineItemID,
            preferredEngine: settings.assistantVoiceEngine,
            fallbackPolicy: settings.assistantTTSFallbackToMacOS ? .macOS : .disabled,
            timeout: AssistantHumeDefaults.ttsTimeout,
            voicePromptReference: nil,
            promptText: nil
        )
    }

    func updateLiveVoiceSessionSnapshot(_ snapshot: AssistantLiveVoiceSessionSnapshot) {
        liveVoiceSessionSnapshot = snapshot
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
            updateMemoryStatus(base: currentMemoryFileURL != nil ? memoryStatusBase(for: sessionID) : nil)
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

    private func reloadProjectsFromStore() {
        projects = projectStore.projects()
        if let selectedProjectFilterID,
           !projects.contains(where: {
               $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                   .caseInsensitiveCompare(selectedProjectFilterID) == .orderedSame
           }) {
            self.selectedProjectFilterID = nil
        }
    }

    func selectProjectFilter(_ projectID: String?) async {
        let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        if let normalizedProjectID,
           selectedProjectFilterID?.caseInsensitiveCompare(normalizedProjectID) == .orderedSame {
            selectedProjectFilterID = nil
            return
        }

        selectedProjectFilterID = normalizedProjectID

        guard let normalizedProjectID else { return }
        let selectedSessionStillVisible = selectedSessionID.flatMap { currentSelectedSessionID in
            visibleSidebarSessions.first(where: { sessionsMatch($0.id, currentSelectedSessionID) })
        } != nil
        if !selectedSessionStillVisible,
           let firstVisibleSession = visibleSidebarSessions.first(where: {
               $0.projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
                   .caseInsensitiveCompare(normalizedProjectID) == .orderedSame
           }) {
            await openSession(firstVisibleSession)
        }
    }

    func createProject(name: String, linkedFolderPath: String? = nil) {
        do {
            let project = try projectStore.createProject(name: name, linkedFolderPath: linkedFolderPath)
            reloadProjectsFromStore()
            sessions = applyProjectMetadata(to: sessions)
            refreshMemoryInspectorIfNeeded(affectedProjectIDs: [project.id])
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func renameProject(_ projectID: String, to newName: String) {
        do {
            let updatedProject = try projectStore.renameProject(id: projectID, to: newName)
            reloadProjectsFromStore()
            sessions = applyProjectMetadata(to: sessions)
            refreshMemoryState(for: selectedSessionID)
            refreshMemoryInspectorIfNeeded(affectedProjectIDs: [updatedProject.id])
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func updateProjectLinkedFolder(_ projectID: String, path: String?) {
        do {
            let previousProject = projectStore.project(forProjectID: projectID)
            let previousFolderPath = previousProject?.linkedFolderPath
            let updatedProject = try projectStore.updateLinkedFolderPath(for: projectID, path: path)
            reloadProjectsFromStore()
            sessions = applyProjectMetadata(to: sessions)

            if previousFolderPath != updatedProject.linkedFolderPath,
               let representativeThreadID = representativeThreadID(forProjectID: projectID) {
                _ = try? projectMemoryService.createFolderChangeStaleSuggestions(
                    project: updatedProject,
                    fallbackCWD: updatedProject.linkedFolderPath,
                    threadID: representativeThreadID,
                    previousFolderPath: previousFolderPath
                )
            }

            refreshMemoryState(for: selectedSessionID)
            refreshMemoryInspectorIfNeeded(
                affectedThreadIDs: representativeThreadID(forProjectID: projectID).map { [$0] } ?? [],
                affectedProjectIDs: [projectID]
            )
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func updateProjectIcon(_ projectID: String, symbol: String?) {
        do {
            _ = try projectStore.setIconSymbol(symbol, forProjectID: projectID)
            reloadProjectsFromStore()
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func deleteProject(_ projectID: String) {
        do {
            guard let project = projectStore.project(forProjectID: projectID) else { return }
            let deletion = try projectStore.deleteProjectResult(id: projectID)
            try projectMemoryService.invalidateAllProjectLessons(
                project: project,
                fallbackCWD: project.linkedFolderPath,
                reason: "The project was deleted from Open Assist."
            )

            reloadProjectsFromStore()
            sessions = applyProjectMetadata(to: sessions)

            if selectedProjectFilterID?.caseInsensitiveCompare(projectID) == .orderedSame {
                selectedProjectFilterID = nil
            }

            for threadID in deletion.removedThreadIDs where sessionsMatch(threadID, selectedSessionID) {
                refreshMemoryState(for: threadID)
            }
            refreshMemoryInspectorIfNeeded(
                affectedThreadIDs: deletion.removedThreadIDs,
                affectedProjectIDs: [projectID],
                closeIfMissing: true
            )
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func assignSessionToProject(_ sessionID: String, projectID: String?) {
        do {
            try updateSessionProjectAssignment(sessionID: sessionID, projectID: projectID)
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    private func updateSessionProjectAssignment(sessionID: String, projectID: String?) throws {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard !normalizedSessionID.isEmpty else { return }

        let previousContext = projectStore.context(forThreadID: normalizedSessionID)
        if let previousProjectID = previousContext?.project.id,
           let normalizedProjectID,
           previousProjectID.caseInsensitiveCompare(normalizedProjectID) == .orderedSame {
            return
        }

        if let previousProjectID = previousContext?.project.id {
            try projectStore.removeThreadState(normalizedSessionID, from: previousProjectID)
            _ = try projectStore.removeThreadAssignment(normalizedSessionID)
            _ = try? projectMemoryService.rebuildProjectSummary(for: previousProjectID, sessionSummaries: sessions)
        }

        if let normalizedProjectID {
            try projectStore.assignThread(normalizedSessionID, toProjectID: normalizedProjectID)
            _ = try? projectMemoryService.rebuildProjectSummary(for: normalizedProjectID, sessionSummaries: sessions)
        }

        let sessionTitle = sessions.first(where: { sessionsMatch($0.id, normalizedSessionID) })?.title ?? "Thread"
        let assignedProjectName = normalizedProjectID.flatMap { projectStore.project(forProjectID: $0)?.name }

        reloadProjectsFromStore()
        sessions = applyProjectMetadata(to: sessions)
        refreshMemoryState(for: normalizedSessionID)
        refreshMemoryInspectorIfNeeded(
            affectedThreadIDs: [normalizedSessionID],
            affectedProjectIDs: [previousContext?.project.id, normalizedProjectID].compactMap { $0 }
        )

        if let assignedProjectName {
            let action = previousContext == nil ? "Assigned" : "Moved"
            lastStatusMessage = "\(action) “\(sessionTitle)” to project “\(assignedProjectName)”."
        } else if previousContext != nil {
            lastStatusMessage = "Removed “\(sessionTitle)” from its project."
        }

        Task { @MainActor [weak self] in
            await self?.handleProjectMemoryCheckpoint(for: normalizedSessionID)
        }
    }

    private func applyProjectMetadata(to sessions: [AssistantSessionSummary]) -> [AssistantSessionSummary] {
        let snapshot = projectStore.snapshot()

        let projectsByID = Dictionary(
            uniqueKeysWithValues: snapshot.projects.map {
                ($0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0)
            }
        )

        return sessions.map { session in
            var updated = session
            let normalizedSessionID = session.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let projectID = snapshot.threadAssignments[normalizedSessionID],
               let project = projectsByID[projectID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] {
                let effectiveFolder = resolvedProjectLinkedFolderPath(project.linkedFolderPath)
                updated.projectID = project.id
                updated.projectName = project.name
                updated.linkedProjectFolderPath = project.linkedFolderPath
                updated.projectFolderMissing = project.linkedFolderPath != nil && effectiveFolder == nil
                updated.effectiveCWD = effectiveFolder ?? session.cwd
            } else {
                updated.projectID = nil
                updated.projectName = nil
                updated.linkedProjectFolderPath = nil
                updated.projectFolderMissing = false
                updated.effectiveCWD = session.cwd
            }
            return updated
        }
    }

    private func resolvedProjectLinkedFolderPath(_ path: String?) -> String? {
        guard let normalizedPath = AssistantProject.normalizedLinkedFolderPath(path),
              fileManagerDirectoryExists(atPath: normalizedPath) else {
            return nil
        }
        return normalizedPath
    }

    private func selectedProjectLinkedFolderPathIfUsable() -> String? {
        guard let linkedFolderPath = selectedProjectFilter?.linkedFolderPath else {
            return nil
        }
        return resolvedProjectLinkedFolderPath(linkedFolderPath)
    }

    private func representativeThreadID(forProjectID projectID: String) -> String? {
        let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sessions.first(where: {
            $0.projectID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedProjectID
        })?.id
    }

    private func resolvedAssistantMemoryScope(for sessionID: String) -> MemoryScopeContext {
        if let projectTurnContext = try? projectMemoryService.turnContext(
            forThreadID: sessionID,
            fallbackCWD: resolvedSessionCWD(for: sessionID)
        ) {
            return projectTurnContext.scope
        }
        return memoryRetrievalService.makeScopeContext(
            threadID: sessionID,
            cwd: resolvedSessionCWD(for: sessionID)
        )
    }

    private func projectMemorySuggestionMetadata(for sessionID: String) -> [String: String] {
        var metadata: [String: String] = [
            "source_session_id": sessionID
        ]

        if let anchorID = latestEditableTurnAnchorID(for: sessionID) {
            metadata["source_turn_anchor_id"] = anchorID
        }

        if let project = projectStore.context(forThreadID: sessionID)?.project {
            metadata["project_memory"] = "true"
            metadata["project_id"] = project.id
            if let linkedFolderPath = project.linkedFolderPath {
                metadata["folder_path"] = linkedFolderPath
            }
        }
        return metadata
    }

    private func memoryStatusBase(for sessionID: String?) -> String? {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return "Using session memory"
        }
        if projectStore.context(forThreadID: sessionID) != nil {
            return "Using thread + project memory"
        }
        return "Using session memory"
    }

    private func fileManagerDirectoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func refreshMemoryInspectorIfNeeded(
        affectedThreadIDs: [String] = [],
        affectedProjectIDs: [String] = [],
        closeIfMissing: Bool = false
    ) {
        guard showMemoryInspector,
              let target = activeMemoryInspectorTarget else {
            return
        }

        let normalizedThreadIDs = Set(
            affectedThreadIDs.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty?.lowercased() }
        )
        let normalizedProjectIDs = Set(
            affectedProjectIDs.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty?.lowercased() }
        )

        let shouldRefresh: Bool
        switch target {
        case .thread(let threadID):
            let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            shouldRefresh = normalizedThreadIDs.isEmpty || normalizedThreadIDs.contains(normalizedThreadID)
        case .project(let projectID):
            let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            shouldRefresh = normalizedProjectIDs.isEmpty || normalizedProjectIDs.contains(normalizedProjectID)
        }

        guard shouldRefresh else { return }
        reloadMemoryInspectorSnapshot(closeIfMissing: closeIfMissing)
    }

    private func reloadMemoryInspectorSnapshot(closeIfMissing: Bool = false) {
        guard showMemoryInspector,
              let target = activeMemoryInspectorTarget else {
            return
        }

        do {
            switch target {
            case .thread(let threadID):
                guard let session = sessions.first(where: { sessionsMatch($0.id, threadID) }) else {
                    if closeIfMissing {
                        dismissMemoryInspector()
                    }
                    return
                }
                memoryInspectorSnapshot = try memoryInspectorService.snapshot(for: session)
            case .project(let projectID):
                guard let project = projects.first(where: {
                    $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(projectID) == .orderedSame
                }) else {
                    if closeIfMissing {
                        dismissMemoryInspector()
                    }
                    return
                }
                memoryInspectorSnapshot = try memoryInspectorService.snapshot(for: project, sessions: sessions)
            }
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    private func scheduleProjectMemoryCatchUp() {
        projectMemoryCatchUpTask?.cancel()
        let projectLinkedSessions = sessions.filter { $0.projectID != nil }
        guard !projectLinkedSessions.isEmpty else { return }

        projectMemoryCatchUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runProjectMemoryCatchUp(for: projectLinkedSessions)
        }
    }

    private func runProjectMemoryCatchUp(for sessions: [AssistantSessionSummary]) async {
        guard !isRefreshingProjectMemory else { return }
        isRefreshingProjectMemory = true
        defer { isRefreshingProjectMemory = false }

        for session in sessions {
            if Task.isCancelled { return }
            guard shouldProcessProjectMemoryCatchUp(session) else { continue }
            await handleProjectMemoryCheckpoint(for: session.id)
        }

        self.sessions = applyProjectMetadata(to: self.sessions)
        refreshMemoryState(for: selectedSessionID)
    }

    private func shouldProcessProjectMemoryCatchUp(_ session: AssistantSessionSummary) -> Bool {
        guard let context = projectStore.context(forThreadID: session.id) else {
            return false
        }
        let threadID = session.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !threadID.isEmpty else { return false }
        guard let updatedAt = session.updatedAt ?? session.createdAt else { return true }
        guard let lastProcessedAt = context.brainState.lastProcessedAt else { return true }
        if lastProcessedAt < updatedAt {
            return true
        }
        return context.brainState.lastProcessedTranscriptFingerprintByThreadID[threadID] == nil
    }

    private func handleProjectMemoryCheckpoint(for sessionID: String?) async {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let session = sessions.first(where: { sessionsMatch($0.id, sessionID) }),
              session.projectID != nil else {
            return
        }

        let history = await loadSessionHistoryForAutomationSummary(sessionID: sessionID)
        do {
            let result = try projectMemoryService.processCheckpoint(
                session: session,
                transcript: history.1,
                timeline: history.0
            )
            if result.didChange {
                let affectedProjectID = session.projectID
                reloadProjectsFromStore()
                sessions = applyProjectMetadata(to: sessions)
                refreshMemoryState(for: sessionID)
                refreshMemoryInspectorIfNeeded(
                    affectedThreadIDs: [sessionID],
                    affectedProjectIDs: affectedProjectID.map { [$0] } ?? []
                )
            }
        } catch {
            CrashReporter.logError("Project memory checkpoint failed: \(error.localizedDescription)")
        }
    }

    private func handleThreadMemoryCheckpoint(
        for sessionID: String?,
        status: AssistantTurnCompletionStatus
    ) async {
        guard status == .completed,
              settings.assistantMemoryEnabled,
              let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }

        do {
            let turns = try threadRewriteService.editableTurns(sessionID: sessionID)
            setEditableTurns(turns, for: sessionID)

            guard let latestAnchorID = turns.last?.anchorID else { return }
            _ = try threadMemoryService.captureCheckpoint(for: sessionID, anchorID: latestAnchorID)
        } catch {
            CrashReporter.logError("Thread memory checkpoint failed: \(error.localizedDescription)")
        }
    }

    private func refreshEditableTurns(for sessionID: String?) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }

        do {
            setEditableTurns(try threadRewriteService.editableTurns(sessionID: sessionID), for: sessionID)
        } catch {
            editableTurnsBySessionID[sessionID] = []
            historyActionsRevision &+= 1
        }
    }

    private func setEditableTurns(_ turns: [CodexEditableTurn], for sessionID: String) {
        editableTurnsBySessionID[sessionID] = turns
        historyActionsRevision &+= 1
    }

    private func clearEditableTurns(for sessionID: String?) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { return }
        editableTurnsBySessionID.removeValue(forKey: sessionID)
        historyActionsRevision &+= 1
    }

    private func latestEditableTurnAnchorID(for sessionID: String) -> String? {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }

        if let cached = editableTurnsBySessionID[normalizedSessionID]?.last?.anchorID {
            return cached
        }

        if let turns = try? threadRewriteService.editableTurns(sessionID: normalizedSessionID) {
            setEditableTurns(turns, for: normalizedSessionID)
            return turns.last?.anchorID
        }

        return nil
    }

    func historyActionMetadata(
        for renderItems: [AssistantTimelineRenderItem]
    ) -> [String: AssistantHistoryActionAvailability] {
        guard let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return [:]
        }

        let editableTurns = editableTurnsBySessionID[sessionID] ?? []
        guard !editableTurns.isEmpty else { return [:] }

        let visibleUserItems = renderItems.compactMap { renderItem -> AssistantTimelineItem? in
            guard case .timeline(let item) = renderItem,
                  item.kind == .userMessage else {
                return nil
            }

            if item.source == .runtime && item.turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil {
                return nil
            }
            return item
        }
        guard !visibleUserItems.isEmpty else { return [:] }

        let mappedCount = min(visibleUserItems.count, editableTurns.count)
        guard mappedCount > 0 else { return [:] }

        let itemTail = Array(visibleUserItems.suffix(mappedCount))
        let turnTail = Array(editableTurns.suffix(mappedCount))
        let latestEditableAnchorID = editableTurns.last?.anchorID
        let canMutate = !runtime.hasActiveTurn && historyMutationState == nil

        var metadata: [String: AssistantHistoryActionAvailability] = [:]
        for (item, turn) in zip(itemTail, turnTail) {
            metadata[item.id] = AssistantHistoryActionAvailability(
                anchorID: turn.anchorID,
                canUndo: canMutate,
                canEdit: canMutate && turn.supportsEdit && turn.anchorID == latestEditableAnchorID
            )
        }

        return metadata
    }

    private func applyHistoryRewriteRollback(
        for sessionID: String,
        retainedAnchorIDs: [String],
        removedAnchorIDs: [String],
        captureSnapshot: Bool,
        keepRemovedCheckpoints: Bool
    ) async throws -> AssistantHistoryRollbackSnapshot? {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let removedAnchorSet = Set(removedAnchorIDs)
        guard !normalizedSessionID.isEmpty else { return nil }

        let memoryDocument = captureSnapshot
            ? (try? threadMemoryService.loadTrackedDocument(for: normalizedSessionID).document)
            : nil
        let removedArtifacts = try memorySuggestionService.purgeHistoryArtifacts(
            for: normalizedSessionID,
            sourceTurnAnchorIDs: removedAnchorSet
        )

        let agentService = ConversationAgentStateService.shared
        let profile = captureSnapshot ? (try? await agentService.fetchProfile(threadID: normalizedSessionID)) : nil
        let entities = captureSnapshot ? (try? await agentService.fetchEntities(threadID: normalizedSessionID)) : nil
        let preferences = captureSnapshot ? (try? await agentService.fetchPreferences(threadID: normalizedSessionID)) : nil

        try? await agentService.clearProfile(threadID: normalizedSessionID)
        try? await agentService.clearEntities(threadID: normalizedSessionID)
        try? await agentService.clearPreferences(threadID: normalizedSessionID)

        if let latestRetainedAnchorID = retainedAnchorIDs.last,
           threadMemoryService.hasCheckpoint(for: normalizedSessionID, anchorID: latestRetainedAnchorID) {
            _ = try threadMemoryService.restoreCheckpoint(for: normalizedSessionID, anchorID: latestRetainedAnchorID)
        } else if threadMemoryService.memoryFileIfExists(for: normalizedSessionID) != nil || captureSnapshot {
            _ = try threadMemoryService.clearThreadMemoryDocument(for: normalizedSessionID)
        }

        if !keepRemovedCheckpoints {
            try? threadMemoryService.deleteCheckpoints(
                for: normalizedSessionID,
                retaining: Set(retainedAnchorIDs)
            )
        }

        guard captureSnapshot else { return nil }
        return AssistantHistoryRollbackSnapshot(
            memoryDocument: memoryDocument,
            removedSuggestions: removedArtifacts.removedSuggestions,
            removedAcceptedEntries: removedArtifacts.removedEntries,
            agentProfile: profile,
            agentEntities: entities,
            agentPreferences: preferences
        )
    }

    private func restoreHistoryRollback(
        for sessionID: String,
        snapshot: AssistantHistoryRollbackSnapshot?
    ) async throws {
        guard let snapshot else { return }

        if let memoryDocument = snapshot.memoryDocument {
            _ = try threadMemoryService.saveDocument(memoryDocument, for: sessionID)
        }

        try memorySuggestionService.restoreHistoryArtifacts(
            suggestions: snapshot.removedSuggestions,
            acceptedEntries: snapshot.removedAcceptedEntries
        )

        let agentService = ConversationAgentStateService.shared
        if let profile = snapshot.agentProfile {
            try? await agentService.upsertProfile(profile)
        }
        if let entities = snapshot.agentEntities {
            try? await agentService.upsertEntities(entities)
        }
        if let preferences = snapshot.agentPreferences {
            try? await agentService.upsertPreferences(preferences)
        }
    }

    private func assistantAttachment(from editableAttachment: CodexEditableAttachment) -> AssistantAttachment {
        AssistantAttachment(
            filename: editableAttachment.filename,
            data: editableAttachment.data,
            mimeType: editableAttachment.mimeType
        )
    }

    private func invalidateSessionHistoryCaches(for sessionID: String) {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }

        pendingTimelineCacheSaveWorkItems[normalizedSessionID]?.cancel()
        pendingTimelineCacheSaveWorkItems.removeValue(forKey: normalizedSessionID)
        sessionCatalog.saveNormalizedTimeline([], for: normalizedSessionID)
        pendingResumeContextSnapshotsBySessionID.removeValue(forKey: normalizedSessionID)
        pendingResumeContextSessionIDs.remove(normalizedSessionID)
        transcriptEntriesBySessionID.removeValue(forKey: normalizedSessionID)
        timelineItemsBySessionID.removeValue(forKey: normalizedSessionID)
        requestedTimelineHistoryLimitBySessionID.removeValue(forKey: normalizedSessionID)
        requestedTranscriptHistoryLimitBySessionID.removeValue(forKey: normalizedSessionID)
        canLoadMoreHistoryBySessionID.removeValue(forKey: normalizedSessionID)
        clearEditableTurns(for: normalizedSessionID)
    }

    private func reloadAfterHistoryRewrite(for sessionID: String) async {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }

        invalidateSessionHistoryCaches(for: normalizedSessionID)
        await refreshSessions(limit: max(40, sessions.count))
        if sessionsMatch(selectedSessionID, normalizedSessionID) {
            await reloadSelectedSessionHistoryIfNeeded(force: true)
        }
        refreshEditableTurns(for: normalizedSessionID)
        refreshMemoryState(for: normalizedSessionID)
        reloadMemoryInspectorSnapshot(closeIfMissing: true)
    }

    private func reconcileProjectDigest(for sessionID: String) async {
        guard let session = sessions.first(where: { sessionsMatch($0.id, sessionID) }),
              let projectID = session.projectID,
              let project = projectStore.project(forProjectID: projectID) else {
            return
        }

        let history = await loadSessionHistoryForAutomationSummary(sessionID: sessionID)
        do {
            if history.1.isEmpty {
                try projectMemoryService.removeThread(sessionID, fromProjectID: project.id)
            } else {
                _ = try projectMemoryService.processCheckpoint(
                    project: project,
                    sessionSummary: session,
                    transcript: history.1,
                    cwd: resolvedSessionCWD(for: sessionID)
                )
            }
            reloadProjectsFromStore()
            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                sessions = applyProjectMetadata(to: sessions)
            }
            refreshMemoryInspectorIfNeeded(
                affectedThreadIDs: [sessionID],
                affectedProjectIDs: [project.id]
            )
        } catch {
            CrashReporter.logError("Project digest reconciliation failed: \(error.localizedDescription)")
        }
    }

    private func commitPendingHistoryEditIfNeeded(for sessionID: String) {
        guard let mutation = historyMutationState,
              mutation.kind == .edit,
              mutation.isPendingComposerEdit,
              sessionsMatch(mutation.sessionID, sessionID) else {
            return
        }

        try? threadMemoryService.deleteCheckpoints(
            for: mutation.sessionID,
            retaining: Set(mutation.retainedAnchorIDs)
        )
        threadRewriteService.discardPendingEditBackup(sessionID: mutation.sessionID)
        historyMutationState = nil
        refreshEditableTurns(for: mutation.sessionID)
    }

    private func resolvedSessionCWD(for sessionID: String) -> String? {
        if let projectContext = projectStore.context(forThreadID: sessionID),
           let linkedFolderPath = projectContext.project.linkedFolderPath,
           fileManagerDirectoryExists(atPath: linkedFolderPath) {
            return linkedFolderPath
        }
        if let matchingSession = sessions.first(where: { sessionsMatch($0.id, sessionID) }) {
            return matchingSession.effectiveCWD ?? matchingSession.cwd
        }
        return selectedSession?.effectiveCWD ?? selectedSession?.cwd
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

        if ["browser", "browser use", "app action"].contains(normalizedTitle ?? "") {
            return AssistantModeSwitchSuggestion(
                source: .blocked,
                originMode: event.mode,
                message: "Chat mode stopped because this needs live browser or app automation. You can retry it in Agentic mode.",
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
            let scope = resolvedAssistantMemoryScope(for: sessionID)
            let created = try memorySuggestionService.createAutomaticFailureSuggestions(
                from: text,
                toolCount: toolCount,
                threadID: sessionID,
                scope: scope,
                metadata: projectMemorySuggestionMetadata(for: sessionID)
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
            interactionMode: (session?.latestInteractionMode ?? .agentic).normalizedForActiveUse,
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
        let sourceSessions = visibleSidebarSessions
        if preferConversationContent,
           let session = sourceSessions.first(where: { $0.hasConversationContent }) {
            return session.id
        }
        return sourceSessions.first?.id ?? sessions.first?.id
    }

    private func prepareSessionForPrompt() async throws -> String {
        if let selectedSessionID = selectedSessionID?.nonEmpty {
            if let currentSessionID = runtime.currentSessionID?.nonEmpty {
                if sessionsMatch(currentSessionID, selectedSessionID) {
                    if !isPendingFreshSession(currentSessionID) {
                        do {
                            try await runtime.refreshCurrentSessionConfiguration(
                                cwd: resolvedSessionCWD(for: currentSessionID),
                                preferredModelID: selectedModelID
                            )
                        } catch {
                            if isMissingRolloutError(error) {
                                return try await recoverMissingRollout(for: selectedSessionID)
                            }
                            throw error
                        }
                    }
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

            if isPendingFreshSession(selectedSessionID) {
                let replacementSessionID = try await runtime.startNewSession(
                    cwd: resolvedSessionCWD(for: selectedSessionID),
                    preferredModelID: selectedModelID
                )
                discardPendingFreshSession(selectedSessionID)
                markPendingFreshSession(replacementSessionID)
                return replacementSessionID
            }

            if let selectedSession = sessions.first(where: { sessionsMatch($0.id, selectedSessionID) }) {
                do {
                    try await runtime.resumeSession(
                        selectedSession.id,
                        cwd: resolvedSessionCWD(for: selectedSession.id),
                        preferredModelID: selectedModelID
                    )
                    pendingResumeContextSessionIDs.insert(selectedSession.id)
                    return selectedSession.id
                } catch {
                    if isMissingRolloutError(error) {
                        return try await recoverMissingRollout(for: selectedSession.id)
                    }
                    throw error
                }
            }
        }

        if let currentSessionID = runtime.currentSessionID?.nonEmpty {
            if !isPendingFreshSession(currentSessionID) {
                do {
                    try await runtime.refreshCurrentSessionConfiguration(
                        cwd: resolvedSessionCWD(for: currentSessionID),
                        preferredModelID: selectedModelID
                    )
                } catch {
                    if isMissingRolloutError(error) {
                        return try await recoverMissingRollout(for: currentSessionID)
                    }
                    throw error
                }
            }
            return currentSessionID
        }

        let sessionID = try await runtime.startNewSession(preferredModelID: selectedModelID)
        markPendingFreshSession(sessionID)
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
        let hasRenderableCachedTimeline = hasRenderableTimelineHistory(cachedTimeline)
        let hasVisibleSelectedSessionHistory = sessionsMatch(timelineSessionID, selectedSessionID)
            && !cachedRenderItems.isEmpty

        if hasRenderableCachedTimeline,
           (!sessionsMatch(timelineSessionID, selectedSessionID) || timelineItems.isEmpty) {
            setVisibleTimeline(cachedTimeline, for: selectedSessionID)
        }
        if !cachedTranscript.isEmpty,
           (!sessionsMatch(transcriptSessionID, selectedSessionID) || transcript.isEmpty) {
            setVisibleTranscript(cachedTranscript, for: selectedSessionID)
        }

        let needsFreshVisibleHistory = !hasRenderableCachedTimeline
            && (force || !hasVisibleSelectedSessionHistory || transcriptSessionID != selectedSessionID)
        if needsFreshVisibleHistory {
            isTransitioningSession = true

            let requestID = UUID()
            sessionLoadRequestID = requestID
            let recentChunk = await sessionCatalog.loadRecentHistoryChunk(
                sessionID: selectedSessionID,
                timelineLimit: min(
                    currentTimelineHistoryLimit(
                        for: selectedSessionID,
                        minimum: Self.HistoryLoading.initialTimelineLimit
                    ),
                    Self.HistoryLoading.recentTimelineChunkLimit
                ),
                transcriptLimit: min(
                    currentTranscriptHistoryLimit(
                        for: selectedSessionID,
                        minimum: Self.HistoryLoading.initialTranscriptLimit
                    ),
                    Self.HistoryLoading.recentTranscriptChunkLimit
                )
            )

            guard sessionLoadRequestID == requestID,
                  sessionsMatch(self.selectedSessionID, selectedSessionID) else {
                return
            }

            if hasRenderableTimelineHistory(recentChunk.timeline) {
                setVisibleTimeline(recentChunk.timeline, for: selectedSessionID)
                setVisibleTranscript(recentChunk.transcript, for: selectedSessionID)
                canLoadMoreHistoryBySessionID[selectedSessionID] = recentChunk.hasMore
                refreshEditableTurns(for: selectedSessionID)
                isTransitioningSession = false
            }
        }

        guard force
            || transcriptSessionID != selectedSessionID
            || timelineSessionID != selectedSessionID else {
            return
        }

        let requestID = UUID()
        sessionLoadRequestID = requestID
        let loadedHistory = await loadSessionHistorySlice(
            sessionID: selectedSessionID,
            timelineLimit: currentTimelineHistoryLimit(
                for: selectedSessionID,
                minimum: Self.HistoryLoading.initialTimelineLimit
            ),
            transcriptLimit: currentTranscriptHistoryLimit(
                for: selectedSessionID,
                minimum: Self.HistoryLoading.initialTranscriptLimit
            )
        )

        guard sessionLoadRequestID == requestID,
              sessionsMatch(self.selectedSessionID, selectedSessionID) else {
            return
        }

        let mergedTimeline = mergeTimelineHistory(
            loadedHistory.timeline,
            with: timelineItemsBySessionID[selectedSessionID] ?? []
        )
        let mergedTranscript = mergeTranscriptHistory(
            loadedHistory.transcript,
            with: transcriptEntriesBySessionID[selectedSessionID] ?? []
        )
        if !mergedTimeline.isEmpty || timelineItems.isEmpty || timelineSessionID != selectedSessionID {
            setVisibleTimeline(mergedTimeline, for: selectedSessionID)
        }
        if !mergedTranscript.isEmpty || transcript.isEmpty || transcriptSessionID != selectedSessionID {
            setVisibleTranscript(mergedTranscript, for: selectedSessionID)
        }
        refreshEditableTurns(for: selectedSessionID)
        isTransitioningSession = false
    }

    private func scheduleSelectedSessionHistoryReload(force: Bool) {
        deferredSessionHistoryReloadTask?.cancel()
        deferredSessionHistoryReloadTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            await self?.reloadSelectedSessionHistoryIfNeeded(force: force)
            guard !Task.isCancelled else { return }
            self?.deferredSessionHistoryReloadTask = nil
        }
    }

    func loadMoreHistoryForSelectedSession() async -> Bool {
        guard let selectedSessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let selectedSession,
              selectedSession.isLocalSession else {
            return false
        }

        let previousTimelineCount = timelineItemsBySessionID[selectedSessionID]?.count ?? 0
        let previousTranscriptCount = transcriptEntriesBySessionID[selectedSessionID]?.count ?? 0
        let requestID = UUID()
        sessionLoadRequestID = requestID

        let loadedHistory = await loadSessionHistorySlice(
            sessionID: selectedSessionID,
            timelineLimit: currentTimelineHistoryLimit(
                for: selectedSessionID,
                minimum: Self.HistoryLoading.initialTimelineLimit
            ) + Self.HistoryLoading.timelineBatchSize,
            transcriptLimit: currentTranscriptHistoryLimit(
                for: selectedSessionID,
                minimum: Self.HistoryLoading.initialTranscriptLimit
            ) + Self.HistoryLoading.transcriptBatchSize,
            previousTimelineCount: previousTimelineCount,
            previousTranscriptCount: previousTranscriptCount
        )

        guard sessionLoadRequestID == requestID,
              sessionsMatch(self.selectedSessionID, selectedSessionID) else {
            return false
        }

        let mergedTimeline = mergeTimelineHistory(
            loadedHistory.timeline,
            with: timelineItemsBySessionID[selectedSessionID] ?? []
        )
        let mergedTranscript = mergeTranscriptHistory(
            loadedHistory.transcript,
            with: transcriptEntriesBySessionID[selectedSessionID] ?? []
        )
        let didGrow = mergedTimeline.count > previousTimelineCount || mergedTranscript.count > previousTranscriptCount
        if didGrow {
            setVisibleTimeline(mergedTimeline, for: selectedSessionID)
            setVisibleTranscript(mergedTranscript, for: selectedSessionID)
            refreshEditableTurns(for: selectedSessionID)
        } else {
            canLoadMoreHistoryBySessionID[selectedSessionID] = false
        }
        isTransitioningSession = false
        return didGrow
    }

    private func resumeContextIfNeeded(for sessionID: String) -> String? {
        if let snapshot = pendingResumeContextSnapshotsBySessionID[sessionID]?.nonEmpty {
            return snapshot
        }

        guard pendingResumeContextSessionIDs.contains(sessionID) else { return nil }

        let sessionTranscript: [AssistantTranscriptEntry]
        if sessionsMatch(transcriptSessionID, sessionID) {
            sessionTranscript = transcript
        } else {
            sessionTranscript = transcriptEntriesBySessionID[sessionID] ?? []
        }

        let summary = sessions.first(where: { sessionsMatch($0.id, sessionID) })
        return Self.buildResumeContext(
            transcriptEntries: sessionTranscript,
            sessionSummary: summary
        )
    }

    private func buildResumeContextSnapshot(for sessionID: String?) -> String? {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        let sessionTranscript: [AssistantTranscriptEntry]
        if sessionsMatch(transcriptSessionID, sessionID) {
            sessionTranscript = transcript
        } else {
            sessionTranscript = transcriptEntriesBySessionID[sessionID] ?? []
        }

        let summary = sessions.first(where: { sessionsMatch($0.id, sessionID) })
        return Self.buildResumeContext(
            transcriptEntries: sessionTranscript,
            sessionSummary: summary
        )
    }

    private func recoverMissingRollout(for sessionID: String?) async throws -> String {
        let sourceSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let recoveredContext = buildResumeContextSnapshot(for: sessionID)
        let replacementSessionID = try await runtime.startNewSession(
            cwd: sourceSessionID.flatMap { resolvedSessionCWD(for: $0) },
            preferredModelID: selectedModelID
        )
        markPendingFreshSession(replacementSessionID)
        recordOwnedSessionID(replacementSessionID)
        if let recoveredContext {
            pendingResumeContextSnapshotsBySessionID[replacementSessionID] = recoveredContext
        }
        lastStatusMessage = "That saved thread could not be reopened, so Open Assist started a new thread with a short recovered summary."
        return replacementSessionID
    }

    private func isMissingRolloutError(_ error: Error) -> Bool {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !message.isEmpty else { return false }
        return message.contains("no rollout found for thread id")
            || message.contains("failed to load rollout")
    }

    private struct SessionHistorySlice {
        let timeline: [AssistantTimelineItem]
        let transcript: [AssistantTranscriptEntry]
    }

    private func currentTimelineHistoryLimit(for sessionID: String, minimum: Int) -> Int {
        max(
            minimum,
            max(
                requestedTimelineHistoryLimitBySessionID[sessionID] ?? 0,
                timelineItemsBySessionID[sessionID]?.count ?? 0
            )
        )
    }

    private func currentTranscriptHistoryLimit(for sessionID: String, minimum: Int) -> Int {
        max(
            minimum,
            max(
                requestedTranscriptHistoryLimitBySessionID[sessionID] ?? 0,
                transcriptEntriesBySessionID[sessionID]?.count ?? 0
            )
        )
    }

    private func loadSessionHistorySlice(
        sessionID: String,
        timelineLimit: Int,
        transcriptLimit: Int,
        previousTimelineCount: Int? = nil,
        previousTranscriptCount: Int? = nil
    ) async -> SessionHistorySlice {
        async let timelineTask = sessionCatalog.loadMergedTimeline(
            sessionID: sessionID,
            limit: timelineLimit
        )
        async let transcriptTask = sessionCatalog.loadTranscript(
            sessionID: sessionID,
            limit: transcriptLimit
        )
        let (timeline, transcript) = await (timelineTask, transcriptTask)

        requestedTimelineHistoryLimitBySessionID[sessionID] = max(
            timelineLimit,
            requestedTimelineHistoryLimitBySessionID[sessionID] ?? 0
        )
        requestedTranscriptHistoryLimitBySessionID[sessionID] = max(
            transcriptLimit,
            requestedTranscriptHistoryLimitBySessionID[sessionID] ?? 0
        )

        let maybeHasMore = timeline.count >= timelineLimit || transcript.count >= transcriptLimit
        let didGrowTimeline = previousTimelineCount.map { timeline.count > $0 } ?? true
        let didGrowTranscript = previousTranscriptCount.map { transcript.count > $0 } ?? true
        canLoadMoreHistoryBySessionID[sessionID] = maybeHasMore && (didGrowTimeline || didGrowTranscript)

        return SessionHistorySlice(
            timeline: timeline,
            transcript: transcript
        )
    }

    private func applyVisibleTimelineTailUpdateIfPossible(
        previousItems: [AssistantTimelineItem],
        updatedItems: [AssistantTimelineItem],
        updatedItem: AssistantTimelineItem,
        sessionID: String
    ) -> Bool {
        guard !updatedItems.isEmpty,
              previousItems.count == updatedItems.count,
              previousItems.last?.id == updatedItem.id,
              updatedItems.last?.id == updatedItem.id,
              updatedItem.kind != .activity,
              !cachedRenderItems.isEmpty,
              case .timeline(let previousRenderItem) = cachedRenderItems[cachedRenderItems.count - 1],
              previousRenderItem.id == updatedItem.id,
              shouldRenderTimelineItem(
                updatedItem,
                planTurnIDs: planTurnIDsForVisibleTimeline(in: updatedItems)
              ) else {
            return false
        }

        timelineItems = updatedItems
        timelineSessionID = sessionID
        cachedRenderItems[cachedRenderItems.count - 1] = .timeline(updatedItem)
        return true
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

    private func setVisibleHistoryLoadingState(for sessionID: String?) {
        setVisibleTimeline([], for: sessionID)
        setVisibleTranscript([], for: sessionID)
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

    private func appendTranscriptDeltaToCache(
        id: UUID,
        sessionID: String?,
        role: AssistantTranscriptRole,
        delta: String,
        createdAt: Date,
        emphasis: Bool,
        isStreaming: Bool
    ) {
        guard let sessionID = sessionID?.nonEmpty else { return }
        var entries = transcriptEntriesBySessionID[sessionID] ?? []
        if let existingIndex = entries.lastIndex(where: { $0.id == id }) {
            let existingEntry = entries[existingIndex]
            entries[existingIndex] = AssistantTranscriptEntry(
                id: existingEntry.id,
                role: existingEntry.role,
                text: existingEntry.text + delta,
                createdAt: existingEntry.createdAt,
                emphasis: existingEntry.emphasis || emphasis,
                isStreaming: isStreaming
            )
        } else {
            entries.append(
                AssistantTranscriptEntry(
                    id: id,
                    role: role,
                    text: delta,
                    createdAt: createdAt,
                    emphasis: emphasis,
                    isStreaming: isStreaming
                )
            )
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

    private func planTurnIDsForVisibleTimeline(in items: [AssistantTimelineItem]) -> Set<String> {
        Set(
            items.compactMap { item -> String? in
                guard item.kind == .plan else { return nil }
                return item.turnID?.assistantNonEmpty
            }
        )
    }

    private func shouldRenderTimelineItem(
        _ item: AssistantTimelineItem,
        planTurnIDs: Set<String>
    ) -> Bool {
        switch item.kind {
        case .userMessage:
            return item.text?.assistantNonEmpty != nil
                || (item.imageAttachments?.isEmpty == false)
        case .system:
            return item.text?.assistantNonEmpty != nil
                || (item.imageAttachments?.isEmpty == false)
        case .assistantProgress, .assistantFinal:
            if let turnID = item.turnID?.assistantNonEmpty,
               planTurnIDs.contains(turnID) {
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

    private func visibleTimelineItemsForRendering(
        from items: [AssistantTimelineItem]
    ) -> [AssistantTimelineItem] {
        let planTurnIDs = planTurnIDsForVisibleTimeline(in: items)
        return items.filter { item in
            shouldRenderTimelineItem(item, planTurnIDs: planTurnIDs)
        }
    }

    private func hasRenderableTimelineHistory(_ items: [AssistantTimelineItem]) -> Bool {
        !visibleTimelineItemsForRendering(from: items).isEmpty
    }

    /// Rebuilds the cached render items from the current timeline items.
    /// Called only when timeline data actually changes, avoiding the expensive
    /// recomputation that previously happened on every @Published update.
    private func rebuildRenderItemsCache() {
        cachedRenderItems = buildAssistantTimelineRenderItems(
            from: visibleTimelineItemsForRendering(from: timelineItems)
        )
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

        // Turn-based dedup: items from the same turn with the same kind are
        // always duplicates regardless of timestamps. This handles cases where
        // loaded history (JSONL) and runtime items have different IDs and
        // createdAt timestamps that diverge beyond the text-based window
        // (e.g., long-running agent tasks).
        if let lhsTurnID = lhs.turnID?.nonEmpty,
           let rhsTurnID = rhs.turnID?.nonEmpty,
           lhsTurnID.caseInsensitiveCompare(rhsTurnID) == .orderedSame {
            switch (lhs.kind, rhs.kind) {
            case (.assistantProgress, .assistantProgress),
                 (.assistantFinal, .assistantFinal),
                 (.assistantProgress, .assistantFinal),
                 (.assistantFinal, .assistantProgress):
                return true
            case (.userMessage, .userMessage):
                return true
            case (.plan, .plan):
                return true
            default:
                break
            }
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
                && abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) < 120

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

    private func normalizedSessionID(_ sessionID: String?) -> String? {
        sessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .lowercased()
    }

    private func isPendingFreshSession(_ sessionID: String?) -> Bool {
        Self.shouldSkipPendingFreshSessionResume(
            sessionID,
            pendingSessionIDs: pendingFreshSessionIDs
        )
    }

    private func markPendingFreshSession(_ sessionID: String?) {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            return
        }
        pendingFreshSessionIDs.insert(normalizedSessionID)
    }

    private func clearPendingFreshSession(_ sessionID: String?) {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            return
        }
        pendingFreshSessionIDs.remove(normalizedSessionID)
    }

    private func discardPendingFreshSession(_ sessionID: String?) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }
        clearPendingFreshSession(sessionID)
        settings.assistantOwnedThreadIDs.removeAll {
            $0.caseInsensitiveCompare(sessionID) == .orderedSame
        }
        sessions.removeAll {
            sessionsMatch($0.id, sessionID) && !$0.hasConversationContent
        }
    }

    private func mergePendingFreshSessions(into loadedSessions: [AssistantSessionSummary]) -> [AssistantSessionSummary] {
        var merged = loadedSessions
        var seen = Set(loadedSessions.compactMap { normalizedSessionID($0.id) })

        let existingPendingSessions = sessions.filter { isPendingFreshSession($0.id) }
        let orderedPendingIDs = Self.pendingFreshSessionInsertionOrder(
            loadedSessionIDs: loadedSessions.map(\.id),
            existingSessionIDs: existingPendingSessions.map(\.id),
            preferredSessionIDs: [selectedSessionID, runtime.currentSessionID]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty },
            pendingSessionIDs: pendingFreshSessionIDs
        )

        for sessionID in orderedPendingIDs.reversed() {
            guard let normalizedSessionID = normalizedSessionID(sessionID),
                  !seen.contains(normalizedSessionID) else {
                continue
            }

            let placeholder = existingPendingSessions.first(where: { sessionsMatch($0.id, sessionID) })
                .map { existing in
                    var normalized = existing
                    normalized.status = Self.normalizedFreshSessionStatus(
                        currentStatus: existing.status,
                        hasConversationContent: existing.hasConversationContent,
                        hasActiveTurn: runtime.hasActiveTurn
                    )
                    return normalized
                }
                ?? AssistantSessionSummary(
                    id: sessionID,
                    title: "New Assistant Session",
                    source: .appServer,
                    status: Self.normalizedFreshSessionStatus(
                        currentStatus: .active,
                        hasConversationContent: false,
                        hasActiveTurn: runtime.hasActiveTurn
                    ),
                    cwd: resolvedSessionCWD(for: sessionID) ?? FileManager.default.homeDirectoryForCurrentUser.path,
                    createdAt: Date(),
                    updatedAt: Date(),
                    summary: nil,
                    latestModel: selectedModelID,
                    latestInteractionMode: interactionMode,
                    latestReasoningEffort: reasoningEffort,
                    latestServiceTier: fastModeEnabled ? "fast" : nil,
                    latestUserMessage: nil,
                    latestAssistantMessage: nil
                )

            merged.insert(placeholder, at: 0)
            seen.insert(normalizedSessionID)
        }

        return merged
    }

    private func shouldForceTimelineCachePersistence(for item: AssistantTimelineItem) -> Bool {
        guard item.cacheable else { return false }

        switch item.kind {
        case .assistantProgress, .plan:
            return !item.isStreaming
        case .activity:
            return item.activity?.isActive != true
        case .permission, .system:
            return true
        case .userMessage, .assistantFinal:
            return false
        }
    }

    private func persistTimelineCacheIfNeeded(
        sessionID: String?,
        items: [AssistantTimelineItem]? = nil,
        force: Bool = false
    ) {
        guard let sessionID = sessionID?.nonEmpty else { return }
        let ownedSessionIDs = Set(settings.assistantOwnedThreadIDs.map { $0.lowercased() })
        guard ownedSessionIDs.contains(sessionID.lowercased()) else { return }
        let itemsToSave = items
            ?? timelineItemsBySessionID[sessionID]
            ?? (sessionsMatch(timelineSessionID, sessionID) ? timelineItems : [])

        if force {
            pendingTimelineCacheSaveWorkItems[sessionID]?.cancel()
            pendingTimelineCacheSaveWorkItems[sessionID] = nil
            sessionCatalog.saveNormalizedTimeline(itemsToSave, for: sessionID)
            return
        }

        pendingTimelineCacheSaveWorkItems[sessionID]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sessionCatalog.saveNormalizedTimeline(itemsToSave, for: sessionID)
                self.pendingTimelineCacheSaveWorkItems[sessionID] = nil
            }
        }
        pendingTimelineCacheSaveWorkItems[sessionID] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.timelineCacheSaveDebounceInterval,
            execute: workItem
        )
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
